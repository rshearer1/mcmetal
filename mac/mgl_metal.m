/* Metal backend for libmcmetal: implements mgl_backend.h, and the mgl_glfw_* entry points our patched
   GLFW calls in place of NSOpenGLContext.

   Conventions (see mgl_xlate.h): Metal row r == GL row r in every texture, because translated vertex
   shaders flip Y. Only the final present flips the image for the window. */
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <MetalFX/MetalFX.h>
#import <AppKit/AppKit.h>
#include <ctype.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include "mgl_state.h"

#define MGL_EXPORT __attribute__((visibility("default")))
#define OBJ(T, p) ((__bridge T)(p))
static void *retain_obj(id o) { return (__bridge_retained void *)o; }
static void release_obj(void *p) { if (p) CFRelease(p); }

/* ================================================================ device, command buffers, encoders */

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLCommandBuffer> cb, last_cb;
static uint64_t cb_serial, submitted_serial;
static _Atomic uint64_t completed_serial;
static id<MTLRenderCommandEncoder> renc;
static mgl_target renc_target;
static id<MTLBlitCommandEncoder> benc;
static id<MTLComputeCommandEncoder> cenc;
static int cenc_concurrent; /* cenc lets its dispatches overlap (geometry-shader jobs only) */

/* Smoothness options (STEP1.md "Smoothness 2/3"), all off unless set:
   MGL_BINARY_ARCHIVE=1   keep finished GPU pipelines in MGL_CACHE_DIR/pipelines.metallib across launches
   MGL_ASYNC_PIPELINES=1  build a new pipeline in the background and skip its draws until ready (no hitch,
                          an object may be missing for a frame or two the first time it is seen)
   MGL_FRAME_PACING=0     ON BY DEFAULT (M3: SEUS 47 fps with ~75% judder -> an even 40, plain world even 120);
                          =0 turns it off. Waits on completion signals instead of polling, and presents at an even rate
                          (120/60/40/30/24/20/15 fps, 12 with interpolation, whichever the last frames' cost sustains, only rates that divide the screen's
                          refresh rate; MGL_TARGET_FPS forces one, over the power cap too: it's a test override).
                          Only with vsync on. MGL_PRESENT_STATS=1 logs how evenly frames reach the screen. */
static int opt(const char *name)
{
    const char *e = getenv(name);
    return e && *e && *e != '0';
}
static unsigned long frame_draws, frame_sections, frame_dispatches, frame_probes; /* reset at each present */

/* MGL_PROFILE=1: once a second, log where frame time goes: CPU time per frame and how much of it was spent waiting
   for the GPU, GPU busy time per frame, and per frame the draws, render passes (and how many reopened the target
   the previous pass had, i.e. a blit/compute/flush split it), blit and compute encoders, command buffers, waits. */
static int opt_profile = -1;
static struct {
    unsigned long draws, passes, reopened, dontcare, blits, computes, cbs, finishes, skipped_presents;
    unsigned long gs_draws, gs_tris, gs_bytes; /* geometry-shader draws, their input triangles and record bytes */
    unsigned long gs_spec; /* geometry-shader jobs that ran the compute made for their vertex format */
    unsigned long sh_draws, sh_tris; /* draws and triangles into square targets of 1024+ (shadow maps), as tools/glcount.c counts */
    unsigned long tex_views, pipe_lookups, big_uniforms; /* per-draw texture views made, pipeline dictionary lookups, >4 KB uniform copies */
    unsigned long rs_sets, rs_skips; /* render-encoder state calls made, and left out as repeats (MCMETAL_STATE_FILTER) */
    uint64_t wait_ns, start_ns, frames;
} prof;
static _Atomic uint64_t prof_gpu_ns;
/* Frame pacing's own cost measures (always kept, unlike prof): time the game thread spent waiting (for the GPU or
   a drawable) and GPU busy time summed over finished command buffers. A frame's real cost is the larger of its CPU
   time minus waits and its GPU time; the time between swaps can't be used once pacing holds frames back, because
   then it is the paced interval itself and the rate would ratchet down to 30. */
static uint64_t pace_wait_ns;
static _Atomic uint64_t pace_gpu_ns;
static mgl_target prof_last_target;

/* MGL_PROFILE=2 also times every render, compute and blit pass on the GPU (Metal timestamp counters at pass
   boundaries) and logs once a second the passes that took longest, by the first program they ran. */
#define PT_MAX 384
typedef struct pt_frame {
    id<MTLCounterSampleBuffer> sb;
    int n;
    char label[PT_MAX][40];
} pt_frame;
static pt_frame *pt_cur;              /* the open command buffer's passes */
static id<MTLCounterSampleBuffer> pt_pool[6];
static unsigned pt_next;
static int pt_ok = -1;
static pthread_mutex_t pt_lock = PTHREAD_MUTEX_INITIALIZER;
#define PT_SLOTS 64
static struct { char label[40]; double ns; unsigned long n; } pt_sum[PT_SLOTS];
static double pt_total_ns;
static MTLTimestamp pt_cal_cpu, pt_cal_gpu;
static double pt_ratio = 1; /* ns per GPU tick */

static void pt_begin_cb(id<MTLCommandBuffer> c)
{
    if (opt_profile < 2)
        return;
    if (pt_ok < 0) {
        pt_ok = 0;
        if ([dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary])
            for (id<MTLCounterSet> set in dev.counterSets)
                if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) {
                    MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
                    d.counterSet = set;
                    d.storageMode = MTLStorageModeShared;
                    d.sampleCount = PT_MAX * 2;
                    pt_ok = 1;
                    for (int i = 0; i < 6 && pt_ok; i++) {
                        NSError *e = nil;
                        pt_pool[i] = [dev newCounterSampleBufferWithDescriptor:d error:&e];
                        pt_ok = pt_pool[i] != nil;
                    }
                }
        mgl_log("profile: GPU pass timing %s", pt_ok ? "on"
                : opt_profile >= 3 ? "from command buffer GPU times (no timestamp counters on this GPU)"
                                   : "not supported on this GPU (MGL_PROFILE=3 times command buffers instead)");
        [dev sampleTimestamps:&pt_cal_cpu gpuTimestamp:&pt_cal_gpu];
    }
    if (!pt_ok && opt_profile < 3)
        return;
    pt_frame *f = calloc(1, sizeof *f);
    f->sb = pt_ok ? pt_pool[pt_next++ % 6] : nil;
    pt_cur = f;
    [c addCompletedHandler:^(id<MTLCommandBuffer> done) {
      if (!f->sb) { /* level 3 without counters: each pass ran in its own command buffer; its GPU time is the pass's */
          double ns = (done.GPUEndTime - done.GPUStartTime) * 1e9;
          if (f->n && ns > 0) {
              pthread_mutex_lock(&pt_lock);
              pt_total_ns += ns;
              int k = 0;
              while (k < PT_SLOTS && pt_sum[k].n && strcmp(pt_sum[k].label, f->label[0]))
                  k++;
              if (k == PT_SLOTS)
                  k = PT_SLOTS - 1;
              if (!pt_sum[k].n)
                  snprintf(pt_sum[k].label, sizeof pt_sum[k].label, "%s", f->label[0]);
              pt_sum[k].ns += ns;
              pt_sum[k].n++;
              pthread_mutex_unlock(&pt_lock);
          }
          free(f);
          return;
      }
      if (f->n) {
          NSData *data = [f->sb resolveCounterRange:NSMakeRange(0, (NSUInteger)f->n * 2)];
          const MTLCounterResultTimestamp *ts = data.bytes;
          pthread_mutex_lock(&pt_lock);
          for (int i = 0; ts && i < f->n; i++) {
              uint64_t a = ts[2 * i].timestamp, b = ts[2 * i + 1].timestamp;
              if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a)
                  continue;
              double ns = (double)(b - a) * pt_ratio;
              pt_total_ns += ns;
              int k = 0;
              while (k < PT_SLOTS && pt_sum[k].n && strcmp(pt_sum[k].label, f->label[i]))
                  k++;
              if (k == PT_SLOTS)
                  k = PT_SLOTS - 1; /* table full: lump the rest into the last slot */
              if (!pt_sum[k].n)
                  snprintf(pt_sum[k].label, sizeof pt_sum[k].label, "%s", f->label[i]);
              pt_sum[k].ns += ns;
              pt_sum[k].n++;
          }
          pthread_mutex_unlock(&pt_lock);
      }
      free(f);
    }];
}

/* the next pass's sample indices, or -1 when not timing */
static int pt_pass(const char *label)
{
    if (!pt_cur || pt_cur->n >= PT_MAX)
        return -1;
    snprintf(pt_cur->label[pt_cur->n], sizeof pt_cur->label[0], "%s", label);
    if (!pt_cur->sb) { /* command buffer timing: labels only, no sample buffer to attach */
        pt_cur->n++;
        return -1;
    }
    return pt_cur->n++;
}

static void pt_label(const char *label) /* name the current pass after the first program it runs */
{
    if (pt_cur && pt_cur->n && label && label[0] && !strncmp(pt_cur->label[pt_cur->n - 1], "pass ", 5))
        snprintf(pt_cur->label[pt_cur->n - 1], sizeof pt_cur->label[0], "%s", label);
}

static void pt_report(double frames)
{
    MTLTimestamp cpu, gpu;
    [dev sampleTimestamps:&cpu gpuTimestamp:&gpu];
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    if (gpu > pt_cal_gpu && cpu > pt_cal_cpu)
        pt_ratio = (double)(cpu - pt_cal_cpu) * tb.numer / tb.denom / (double)(gpu - pt_cal_gpu);
    pt_cal_cpu = cpu;
    pt_cal_gpu = gpu;
    pthread_mutex_lock(&pt_lock);
    int order[PT_SLOTS], m = 0;
    for (int k = 0; k < PT_SLOTS; k++)
        if (pt_sum[k].n)
            order[m++] = k;
    for (int i = 1; i < m; i++)
        for (int j = i; j > 0 && pt_sum[order[j]].ns > pt_sum[order[j - 1]].ns; j--) {
            int t = order[j]; order[j] = order[j - 1]; order[j - 1] = t;
        }
    mgl_log("profile: GPU pass time %.3g units per frame (%d kinds, tick ratio %.4g); largest shares:",
            pt_total_ns / frames, m, pt_ratio);
    for (int i = 0; i < m && i < 12; i++)
        mgl_log("profile:   %5.1f%%  %4.1fx  %s", 100.0 * pt_sum[order[i]].ns / (pt_total_ns > 0 ? pt_total_ns : 1),
                pt_sum[order[i]].n / frames, pt_sum[order[i]].label);
    memset(pt_sum, 0, sizeof pt_sum);
    pt_total_ns = 0;
    pthread_mutex_unlock(&pt_lock);
}
static unsigned long long frames_presented; /* for MGL_FRAME_DUMP */

/* The mcmetal mod writes <game>/mcmetal/starting before switching the game to us, and goes back to Apple's
   OpenGL on the next launch if it is still there. Once the game has drawn real screens (NeoForge's early
   loading window only does a few draws a frame) we remove it: this launch worked. The file sits one folder
   above this dylib (<game>/mcmetal/natives/libmcmetal.dylib). */
static void note_started(unsigned long draws)
{
    static int busy_frames, done;
    if (done || draws < 30 || ++busy_frames < 120)
        return;
    done = 1;
    Dl_info info;
    const char *slash;
    char path[4096];
    if (!dladdr((const void *)note_started, &info) || !info.dli_fname || !(slash = strrchr(info.dli_fname, '/')))
        return;
    snprintf(path, sizeof path, "%.*s/../starting", (int)(slash - info.dli_fname), info.dli_fname);
    if (unlink(path) == 0)
        mgl_log("started fine, cleared the mod's start marker");
}
/* MGL_FRAME_DUMP=N: log every clear, blit and draw of frame N (order, targets, depth state) */
/* MGL_FRAME_DUMP=n[,n2,...] (up to 8 frame numbers): log every clear, draw and blit of those frames */
static int dump_this_frame(void)
{
    static long n[8];
    static int count = -1;
    if (count < 0) {
        count = 0;
        const char *e = getenv("MGL_FRAME_DUMP");
        while (e && *e && count < 8) {
            char *end;
            n[count++] = strtol(e, &end, 10);
            e = *end == ',' ? end + 1 : "";
        }
    }
    for (int i = 0; i < count; i++)
        if ((long long)frames_presented == n[i])
            return 1;
    return 0;
}


static int opt_archive = -1, opt_async_pipes = -1, opt_pacing = -1;
static void read_options(void)
{
    if (opt_archive >= 0)
        return;
    opt_archive = opt("MGL_BINARY_ARCHIVE") && getenv("MGL_CACHE_DIR");
    opt_async_pipes = opt("MGL_ASYNC_PIPELINES");
    opt_pacing = getenv("MGL_FRAME_PACING") ? opt("MGL_FRAME_PACING") : 1; /* on unless MGL_FRAME_PACING=0 */
    opt_profile = getenv("MGL_PROFILE") ? atoi(getenv("MGL_PROFILE")) : 0;
    if (opt_archive || opt_async_pipes || opt_pacing)
        mgl_log("options: binary archive %d, async pipelines %d, frame pacing %d", opt_archive, opt_async_pipes, opt_pacing);
}

/* completion signal for mglb_fence_wait (frame pacing mode) */
static pthread_mutex_t fence_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fence_cond = PTHREAD_COND_INITIALIZER;

static void init_device(void)
{
    static dispatch_once_t once; /* link workers call in here too (mglb_program_new) */
    dispatch_once(&once, ^{
      read_options();
      dev = MTLCreateSystemDefaultDevice();
      queue = [dev newCommandQueueWithMaxCommandBufferCount:64];
    });
}

static id<MTLCommandBuffer> current_cb(void)
{
    if (!cb) {
        init_device();
        /* the game's render thread has no autorelease pool between swaps: an autoreleased command buffer (and
           every buffer it retains, e.g. one-off geometry-shader record buffers) was never freed. Same below for
           encoders and pass descriptors. */
        @autoreleasepool {
            cb = [queue commandBuffer];
        }
        prof.cbs++;
        pt_begin_cb(cb);
        uint64_t serial = cb_serial = ++submitted_serial;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
          uint64_t prev = atomic_load(&completed_serial);
          while (prev < serial && !atomic_compare_exchange_weak(&completed_serial, &prev, serial))
              ;
          if (opt_pacing > 0) {
              pthread_mutex_lock(&fence_lock);
              pthread_cond_broadcast(&fence_cond);
              pthread_mutex_unlock(&fence_lock);
          }
          if (done.GPUEndTime > done.GPUStartTime) {
              uint64_t gpu = (uint64_t)((done.GPUEndTime - done.GPUStartTime) * 1e9);
              atomic_fetch_add(&pace_gpu_ns, gpu);
              if (opt_profile > 0)
                  atomic_fetch_add(&prof_gpu_ns, gpu);
          }
          if (done.error)
              mgl_log("GPU error in command buffer %llu: %s", serial, done.error.localizedDescription.UTF8String);
        }];
    }
    return cb;
}

static void gs_flush_at(int line);
#define gs_flush() gs_flush_at(__LINE__) /* MGL_GS_FLUSH_LOG=1 counts which call sites end a batch */
static int gs_recording; /* mglb_draw_gs is opening its compute encoder: keep the pending draws pending */

/* MGL_GS_FLUSH_LOG=1 diagnostics: count events by source line, log every 600 */
typedef struct { const char *what; int lines[16], counts[16], total; } line_tally;
static int flush_log_on(void)
{
    static int on = -1;
    if (on < 0)
        on = getenv("MGL_GS_FLUSH_LOG") && atoi(getenv("MGL_GS_FLUSH_LOG"));
    return on;
}
static void tally_line(line_tally *t, int line)
{
    int k = 0;
    while (k < 15 && t->lines[k] && t->lines[k] != line)
        k++;
    t->lines[k] = line;
    t->counts[k]++;
    if (++t->total == 600) {
        char msg[512];
        int n = snprintf(msg, sizeof msg, "%s (600, by source line):", t->what);
        for (int i = 0; i < 16 && t->lines[i]; i++)
            n += snprintf(msg + n, sizeof msg - (size_t)n, " %d x%d", t->lines[i], t->counts[i]);
        mgl_log("%s", msg);
        memset(t->lines, 0, sizeof t->lines);
        memset(t->counts, 0, sizeof t->counts);
        t->total = 0;
    }
}

/* Deferred full clears (MGL_DEFER_CLEAR=0 turns them off): a glClear of a whole offscreen target opens no pass of
   its own. The next pass that renders into a cleared image clears it with its load action; anything else that
   could see the images first (another encoder, a commit, a texture release) replays the clears as passes, as
   before. Iris clears the 4096x4096 shadow map's images one framebuffer at a time, and each clear pass loaded and
   stored every attachment. */
typedef struct { mgl_target t; unsigned colors; float rgba[4]; int depth; float depth_value; } pending_clear;
static pending_clear pclear[8];
static int npclear, keep_clears;
static id<MTLRenderCommandEncoder> begin_pass_at(int line, const mgl_target *t, unsigned clear_colors, const float *rgba,
                                                 int clear_depth, float depth);

static void rs_reset(void); /* the render encoder's remembered state is unknown (MCMETAL_STATE_FILTER) */
static void mark_clean(const pending_clear *r);
static void target_dirty(const mgl_target *t);

static void materialize_clears(void)
{
    if (!npclear)
        return;
    pending_clear list[8];
    int n = npclear;
    memcpy(list, pclear, sizeof list);
    npclear = 0;
    for (int i = 0; i < n; i++)
        if (list[i].colors || list[i].depth)
        {
            begin_pass_at(__LINE__, &list[i].t, list[i].colors, list[i].rgba, list[i].depth, list[i].depth_value);
            mark_clean(&list[i]);
        }
}

/* any image of a pending clear's target, cleared or only loaded */
static int pending_clear_uses(const mglb_texture *x)
{
    for (int i = 0; i < npclear; i++) {
        for (int a = 0; a < MGL_MAX_ATTACHMENTS; a++)
            if (pclear[i].t.tex[a] == x)
                return 1;
        if (pclear[i].t.depth == x)
            return 1;
    }
    return 0;
}

/* an image a pending clear actually clears (attachments it only loads keep their contents either way) */
static int pending_clear_clears(const mglb_texture *x)
{
    for (int i = 0; i < npclear; i++) {
        for (int a = 0; a < MGL_MAX_ATTACHMENTS; a++)
            if (pclear[i].t.tex[a] == x && (pclear[i].colors & (1u << a)))
                return 1;
        if (pclear[i].t.depth == x && pclear[i].depth)
            return 1;
    }
    return 0;
}

/* GPU occlusion culling: the main view's depth texture once its opaque terrain is drawn, waiting for its render
   pass to end so its depth can be reduced into the Hi-Z pyramid (hiz_build, with the culling code) */
static mglb_texture *hiz_src;
static void hiz_build(void);

/* MGL_GS_UNTRACKED=1: the transient chunks (geometry-shader records, upload staging) are made without Metal's
   hazard tracking. With tracking, the next batch's compute job waits for the previous batch's strips pass to stop
   reading the same 32 MB chunk, even though they touch different ranges of it. The one real dependency, the strips
   reading the records their compute job wrote, is kept with a fence. Chunks are only reused once their command
   buffer has finished (last_use), so the CPU side needs nothing more. */
static int gs_untracked = -1;
static id<MTLFence> gs_fence;
static int gs_fence_due;   /* the open compute encoder wrote untracked records */
static int gs_fence_armed; /* gs_fence was updated: the next strips pass waits for it */
static void end_compute_encoder(void)
{
    if (!cenc)
        return;
    if (gs_fence_due) {
        [cenc updateFence:gs_fence];
        gs_fence_due = 0;
        gs_fence_armed = 1;
    }
    [cenc endEncoding];
    cenc = nil;
}

static void end_encoders_at(int line)
{
    if (!gs_recording)
        gs_flush_at(line);
    if (!keep_clears && npclear) {
        if (flush_log_on()) {
            static line_tally replay = {"pending clears replayed as passes"};
            tally_line(&replay, line);
        }
        materialize_clears();
    }
    if (renc && renc_target.width >= 2048 && renc_target.width == renc_target.height && flush_log_on()) {
        static line_tally big = {"square shadow-map passes ended"};
        tally_line(&big, line);
    }
    int hiz_now = renc && hiz_src && renc_target.depth == hiz_src;
    if (renc) { [renc endEncoding]; renc = nil; }
    if (benc) { [benc endEncoding]; benc = nil; }
    end_compute_encoder();
    if (hiz_now)
        hiz_build();
}
#define end_encoders() end_encoders_at(__LINE__)

static void commit(void)
{
    gs_flush();
    end_encoders();
    pt_cur = NULL;
    if (cb) {
        [cb commit];
        last_cb = cb;
        cb = nil;
    }
}

/* MGL_PROFILE=3: like 2, but every pass runs alone (its own command buffer, waited for), so the per-pass times
   don't overlap. On Apple's tile GPUs consecutive passes run concurrently and level 2's shares come out nearly
   flat. Frame rate drops a lot in this mode; only the shares mean anything. */
static void prof_serialize(void)
{
    static int busy;
    if (opt_profile < 3 || busy || !cb)
        return;
    busy = 1;
    commit();
    [last_cb waitUntilCompleted];
    busy = 0;
}

static id<MTLBlitCommandEncoder> blit_encoder_at(int line)
{
    gs_flush();
    if (benc)
        return benc;
    prof_serialize();
    end_encoders_at(line);
    id<MTLCommandBuffer> c = current_cb();
    int k = pt_pass("blits");
    @autoreleasepool {
        if (k >= 0) {
            MTLBlitPassDescriptor *d = [MTLBlitPassDescriptor blitPassDescriptor];
            d.sampleBufferAttachments[0].sampleBuffer = pt_cur->sb;
            d.sampleBufferAttachments[0].startOfEncoderSampleIndex = (NSUInteger)k * 2;
            d.sampleBufferAttachments[0].endOfEncoderSampleIndex = (NSUInteger)k * 2 + 1;
            benc = [c blitCommandEncoderWithDescriptor:d];
        } else {
            benc = [c blitCommandEncoder];
        }
    }
    prof.blits++;
    if (flush_log_on()) {
        static line_tally opened = {"blit encoders opened"};
        tally_line(&opened, line);
    }
    return benc;
}
#define blit_encoder() blit_encoder_at(__LINE__)

/* A blit that touches no image a pending clear clears leaves the clears pending, so the next pass into the
   cleared images can still take them as load actions (images the clear only loads keep whatever the blit wrote).
   One that does touch them replays the clears first. */
static void tex_dirty(mglb_texture *t);
static id<MTLBlitCommandEncoder> blit_encoder_for_at(int line, mglb_texture *a, mglb_texture *b)
{
    int touches = (a && pending_clear_clears(a)) || (b && pending_clear_clears(b));
    if (touches && benc)
        end_encoders_at(line); /* an open blit encoder would otherwise run this blit before the clears */
    keep_clears = !touches;
    id<MTLBlitCommandEncoder> e = blit_encoder_at(line);
    keep_clears = 0;
    tex_dirty(a); /* the copy source too: cheaper than telling the caller's direction apart */
    tex_dirty(b);
    return e;
}
#define blit_encoder_for(a, b) blit_encoder_for_at(__LINE__, a, b)

/* concurrent: dispatches may run at the same time. The geometry-shader jobs of one batch write their own record
   ranges and only read everything else, so they don't need each other's results; SEUS's shadow pass issues ~1700
   small ones a frame, and in a serial encoder each waits for the one before. Everything else gets a serial
   encoder, as GL ordering needs. MGL_GS_CONCURRENT=0: serial for both. */
static id<MTLComputeCommandEncoder> compute_encoder_kind(int concurrent)
{
    if (!gs_recording)
        gs_flush();
    if (cenc && cenc_concurrent == concurrent)
        return cenc;
    end_compute_encoder();
    prof_serialize();
    end_encoders();
    id<MTLCommandBuffer> c = current_cb();
    int k = pt_pass("pass compute");
    @autoreleasepool {
        if (k >= 0) {
            MTLComputePassDescriptor *d = [MTLComputePassDescriptor computePassDescriptor];
            d.sampleBufferAttachments[0].sampleBuffer = pt_cur->sb;
            d.sampleBufferAttachments[0].startOfEncoderSampleIndex = (NSUInteger)k * 2;
            d.sampleBufferAttachments[0].endOfEncoderSampleIndex = (NSUInteger)k * 2 + 1;
            if (concurrent)
                d.dispatchType = MTLDispatchTypeConcurrent;
            cenc = [c computeCommandEncoderWithDescriptor:d];
        } else {
            cenc = concurrent ? [c computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent]
                              : [c computeCommandEncoder];
        }
    }
    cenc_concurrent = concurrent;
    if (gs_fence_armed) /* a compute encoder between a GS job and its strips: keep the chain ordered */
        [cenc waitForFence:gs_fence];
    prof.computes++;
    return cenc;
}
static id<MTLComputeCommandEncoder> compute_encoder(void) { return compute_encoder_kind(0); }

/* ================================================================ buffers (pooled by size class) */

static uint64_t now_ns(void);

struct mglb_buffer {
    void *mtl;
    void *ptr;
    size_t size, cap;
    uint64_t last_use;
    uint64_t gpu_write; /* command buffer of the last GPU copy into it (mglb_buffer_copy) */
    uint64_t written; /* write_seq at the last CPU write (mglb_buffer_written) */
    struct mglb_buffer *next_free;
    /* MGL_PRIVATE_BUFFERS: a GPU-only copy that draws read instead of mtl (see draw_buf). mtl stays the real
       contents: CPU writes go there and drop the copy, GPU copies into the buffer go to both. */
    void *priv;
    int priv_ok, priv_queued, priv_keep, no_private;
    uint64_t priv_seen;              /* written when last looked at */
    unsigned long long priv_since;   /* frames_presented since when it was unchanged */
    uint64_t pooled_ns;              /* mem_trim: when it went into the pool */
    int purgeable;                   /* mem_trim: marked volatile while pooled (the system may take its pages) */
};

#define POOL_CLASSES 32
/* Freed buffers wait per size class, oldest first: buffers come back roughly in the order the GPU finishes with
   them, so only the first few need looking at (a long LIFO scan of buffers still in flight cost ~13 us per
   glBufferData when every GUI draw streamed its vertices that way, and new Metal buffers for the rest ran
   Apple's paravirtual GPU out of memory). */
static struct mglb_buffer *pool[POOL_CLASSES], *pool_tail[POOL_CLASSES];
static int pool_count[POOL_CLASSES];
#define POOL_LOOK 8

static int size_class(size_t size)
{
    int c = 0;
    size_t s = 256;
    while (s < size && c < POOL_CLASSES - 1) {
        s <<= 1;
        c++;
    }
    return c;
}

/* One write counter for all buffers (mglb_buffer.written), so a value is never repeated, even by a later buffer at
   the same address */
static uint64_t write_seq;
static size_t buf_live_bytes, buf_pooled_bytes; /* MGL_PROFILE: Metal buffer memory we hold, and of it in the pool */
static size_t buf_purgeable_bytes;              /* of the pooled: marked purgeable (mem_trim) */
static unsigned long buf_fresh;                /* MGL_PROFILE: new Metal buffers (the pool had none free) */
static size_t buf_fresh_bytes;
static unsigned long tr_oneoff, tr_waits;       /* transient allocations that fell back to their own buffer; waits for a chunk */
int mglb_fence_wait(uint64_t id, uint64_t timeout_ns);

/* MGL_MEM_TRIM=0 turns off what keeps mcmetal's own memory down (on by default; for A/B runs):
   - buffers over 1 MB get their size rounded up to 1 MB instead of to the next power of two (a 33 MB Sodium region
     buffer held 64 MB);
   - pooled buffers go back to the system after 5 s unused, and big ones are marked purgeable while they wait, so
     under memory pressure macOS can take their pages without asking (unified memory: one pool for CPU and GPU);
   - transient chunks (texture upload staging, geometry-shader records) beyond two are freed after 5 s unused: the
     resource reload at start or a SEUS turn used to leave up to 128 x 32 MB allocated for the rest of the game;
   - texture uploads bigger than a chunk are staged in bands of rows, not in one buffer of their own (the block
     atlas: one 100-300 MB staging buffer per mip level, then kept in the pool). */
static int mem_trim(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MGL_MEM_TRIM");
        on = !(e && *e == '0');
    }
    return on;
}
#define BIG_ROUND ((size_t)1 << 20)

mglb_buffer *mglb_buffer_new(size_t size)
{
    init_device();
    int c = size_class(size);
    size_t cap = (size_t)256 << c;
    if (size > BIG_ROUND && mem_trim())
        cap = (size + BIG_ROUND - 1) & ~(BIG_ROUND - 1);
    if (cap < size)
        cap = size;
    uint64_t done = atomic_load(&completed_serial);
    struct mglb_buffer *prev = NULL;
    int looked = 0;
    for (struct mglb_buffer **pp = &pool[c]; *pp && looked < POOL_LOOK; prev = *pp, pp = &(*pp)->next_free, looked++) {
        struct mglb_buffer *b = *pp;
        if (b->last_use <= done && b->gpu_write <= done && b->cap >= size) {
            *pp = b->next_free;
            if (pool_tail[c] == b)
                pool_tail[c] = prev;
            pool_count[c]--;
            buf_pooled_bytes -= b->cap;
            b->next_free = NULL;
            b->size = size;
            b->written = ++write_seq;
            b->priv_ok = b->no_private = 0;
            if (b->purgeable) {
                /* emptied by the system or not: a reused buffer's old contents don't matter */
                b->purgeable = 0;
                buf_purgeable_bytes -= b->cap;
                [OBJ(id<MTLBuffer>, b->mtl) setPurgeableState:MTLPurgeableStateNonVolatile];
            }
            return b;
        }
    }
    buf_fresh++;
    buf_fresh_bytes += cap;
    struct mglb_buffer *b = calloc(1, sizeof *b);
    id<MTLBuffer> m = [dev newBufferWithLength:cap options:MTLResourceStorageModeShared];
    if (!m) {
        mgl_log("out of GPU memory allocating %zu bytes", cap);
        free(b);
        return NULL;
    }
    b->mtl = retain_obj(m);
    b->ptr = m.contents;
    b->size = size;
    b->cap = cap;
    buf_live_bytes += cap;
    return b;
}

void *mglb_buffer_ptr(mglb_buffer *b) { return b ? b->ptr : NULL; }
size_t mglb_buffer_size(mglb_buffer *b) { return b ? b->size : 0; }

static void priv_forget(mglb_buffer *b);
static void buf_destroy(mglb_buffer *b)
{
    buf_live_bytes -= b->cap;
    if (b->last_use <= atomic_load(&completed_serial) && b->cap >= ((size_t)1 << 20))
        /* the GPU is done with it: drop its pages now. On GitHub's Mac, Metal's allocated size did not go down when
           idle 32 MB chunks were released (each one stayed counted), so don't rely on the release alone. */
        [OBJ(id<MTLBuffer>, b->mtl) setPurgeableState:MTLPurgeableStateEmpty];
    release_obj(b->mtl); /* Metal keeps it alive for command buffers still using it */
    if (b->priv)
        release_obj(b->priv);
    free(b);
}
void mglb_buffer_release(mglb_buffer *b)
{
    if (!b)
        return;
    priv_forget(b);
    int c = size_class(b->cap);
    /* Enough for a few frames in flight: a buffer renamed every frame comes back while the GPU still reads it, so the
       pool needs ~3 frames' worth before one is free again. A count cap of 64 (2 over 16 MB) made the rest new
       Metal buffers every frame (a kernel call each: ~9% of the render thread with DH + a shader pack on the M3).
       mem_sweep still frees what sits unused for 5 s, and big ones are purgeable while they wait. */
    size_t budget = (size_t)256 << 20;
    int keep = b->cap <= ((size_t)64 << 10) ? 1024 : (int)(budget / b->cap);
    if (keep < 4)
        keep = 4;
    if (keep > 1024)
        keep = 1024;
    if (pool_count[c] < keep) {
        b->next_free = NULL;
        if (pool_tail[c])
            pool_tail[c]->next_free = b;
        else
            pool[c] = b;
        pool_tail[c] = b;
        pool_count[c]++;
        buf_pooled_bytes += b->cap;
        b->pooled_ns = now_ns();
        return;
    }
    buf_destroy(b);
}

int mglb_buffer_in_use(mglb_buffer *b)
{
    return b && b->last_use > atomic_load(&completed_serial);
}

void mglb_buffer_written(mglb_buffer *b)
{
    if (!b)
        return;
    if (b->priv_keep) /* a GPU copy mglb_buffer_copy also made into the private copy */
        b->priv_keep = 0;
    else
        b->priv_ok = 0;
    if (b->written != UINT64_MAX)
        b->written = ++write_seq;
}
void mglb_buffer_volatile(mglb_buffer *b)
{
    if (b) {
        b->written = UINT64_MAX; /* until the memory goes back to the pool */
        b->priv_ok = 0;
    }
}

/* ---- MGL_PRIVATE_BUFFERS=1 (off by default until measured): big buffers that only the GPU reads (Sodium's
   region buffers, its quad index buffer) get a copy in private GPU memory once the CPU has left them unchanged
   for a couple of frames; draws then read that copy. Shared memory can be slower to read for draws that fetch the same data many times
   (mcopt measured half speed for a re-read index buffer). Sodium fills its region buffers with GPU copies
   (MGL_GPU_COPY), which mglb_buffer_copy repeats into the private copy, so they stay private while chunks load.
   The shared memory stays the real contents: the CPU (ray tracing, readbacks) still reads it. ---- */
#define PRIV_MIN ((size_t)1 << 20)
static int opt_private = -1;
static mglb_buffer **priv_queue;
static int priv_nq, priv_capq;
static unsigned long priv_made, priv_bytes, priv_refreshed;

static void priv_forget(mglb_buffer *b)
{
    b->priv_ok = 0;
    if (b->priv_queued) {
        for (int i = 0; i < priv_nq; i++)
            if (priv_queue[i] == b) {
                priv_queue[i] = priv_queue[--priv_nq];
                break;
            }
        b->priv_queued = 0;
    }
}

/* the buffer a draw reads: the private copy when it is current */
static id<MTLBuffer> draw_buf(mglb_buffer *b)
{
    if (b->priv_ok)
        return OBJ(id<MTLBuffer>, b->priv);
    if (opt_private < 0) {
        const char *e = getenv("MGL_PRIVATE_BUFFERS");
        opt_private = e && *e && *e != '0';
        mgl_log("private GPU copies of draw-only buffers %s (MGL_PRIVATE_BUFFERS)", opt_private ? "on" : "off");
    }
    if (opt_private && b->cap >= PRIV_MIN && b->written != UINT64_MAX && !b->no_private && !b->priv_queued) {
        if (b->priv_seen != b->written) {
            b->priv_seen = b->written;
            b->priv_since = frames_presented;
        } else if (frames_presented - b->priv_since >= 2) {
            if (priv_nq == priv_capq) {
                priv_capq = priv_capq ? priv_capq * 2 : 64;
                priv_queue = realloc(priv_queue, sizeof *priv_queue * (size_t)priv_capq);
            }
            priv_queue[priv_nq++] = b;
            b->priv_queued = 1;
        }
    }
    return OBJ(id<MTLBuffer>, b->mtl);
}

/* After a frame is committed: copy the queued buffers into private memory, in a command buffer of its own that
   runs after every write already submitted and before the draws that will read the copies. */
static void priv_promote(void)
{
    if (!priv_nq)
        return;
    @autoreleasepool { /* the render thread has no pool: the command buffer and encoder were never freed */
        id<MTLCommandBuffer> side = [queue commandBuffer];
        id<MTLBlitCommandEncoder> e = [side blitCommandEncoder];
        for (int i = 0; i < priv_nq; i++) {
            mglb_buffer *b = priv_queue[i];
            b->priv_queued = 0;
            if (b->written != b->priv_seen || b->written == UINT64_MAX || b->no_private)
                continue; /* written since it was queued */
            if (!b->priv) {
                id<MTLBuffer> m = [dev newBufferWithLength:b->cap options:MTLResourceStorageModePrivate];
                if (!m)
                    continue;
                b->priv = retain_obj(m);
                priv_made++;
                priv_bytes += b->cap;
            } else {
                priv_refreshed++;
            }
            [e copyFromBuffer:OBJ(id<MTLBuffer>, b->mtl) sourceOffset:0 toBuffer:OBJ(id<MTLBuffer>, b->priv)
                  destinationOffset:0 size:b->cap];
            b->priv_ok = 1;
        }
        priv_nq = 0;
        [e endEncoding];
        [side commit];
    }
    static unsigned long next_log = 1; /* at 1, 2, 4, 8, ... copies */
    if (priv_made + priv_refreshed >= next_log) {
        while (next_log <= priv_made + priv_refreshed)
            next_log *= 2;
        mgl_log("private GPU copies: %lu made (%lu MB), %lu refreshed after CPU writes", priv_made, priv_bytes >> 20,
                priv_refreshed);
    }
}

static void use_buffer(mglb_buffer *b)
{
    if (b)
        b->last_use = cb_serial;
}

/* glCopyBufferSubData as a GPU copy, in order with the draws around it. Used when the destination is still being
   read by the GPU: the CPU route then had to give the buffer fresh memory and copy all of it over first (Sodium's
   region buffers while chunks load: up to ~24 MB and 15-26 ms of CPU in one frame on GitHub's Mac). */
int mglb_buffer_copy(mglb_buffer *src, size_t src_off, mglb_buffer *dst, size_t dst_off, size_t size)
{
    if (!src || !dst || (src_off | dst_off | size) & 3)
        return 0; /* Metal on macOS wants 4-byte offsets and sizes: the caller copies on the CPU */
    id<MTLBlitCommandEncoder> e = blit_encoder_for(NULL, NULL);
    [e copyFromBuffer:OBJ(id<MTLBuffer>, src->mtl) sourceOffset:src_off toBuffer:OBJ(id<MTLBuffer>, dst->mtl)
        destinationOffset:dst_off size:size];
    if (dst->priv_ok) { /* keep the private copy current too (the caller's mglb_buffer_written then keeps it) */
        [e copyFromBuffer:OBJ(id<MTLBuffer>, src->mtl) sourceOffset:src_off toBuffer:OBJ(id<MTLBuffer>, dst->priv)
            destinationOffset:dst_off size:size];
        dst->priv_keep = 1;
    }
    use_buffer(src);
    use_buffer(dst);
    dst->gpu_write = cb_serial;
    return 1;
}

int mglb_buffer_gpu_writing(mglb_buffer *b) { return b && b->gpu_write > atomic_load(&completed_serial); }

void mglb_buffer_wait_writes(mglb_buffer *b)
{
    if (mglb_buffer_gpu_writing(b))
        mglb_fence_wait(b->gpu_write, 5000000000ull);
}

/* Transient memory for one command buffer: geometry-shader output and texture upload staging. Suballocated
   from 32 MB chunks that are reused once the GPU has finished with them. Before this, each geometry-shader draw
   allocated two fresh buffers: with ~190 of them in flight per frame the pool had nothing free, and the kernel
   call behind each new buffer grew to 88% of the render thread (SEUS at 1x slid from 49 to 15 fps in 90 s). */
#define TR_CHUNK ((size_t)32 << 20)
#define TR_MAX 128 /* SEUS while turning: ~800 MB of records per frame, 2-3 frames in flight */
static struct { mglb_buffer *b; size_t used; uint64_t picked_ns; } tr_chunk[TR_MAX];
static int tr_n, tr_cur = -1;

typedef struct { id<MTLBuffer> buf; NSUInteger off; void *ptr; } transient_t;

static mglb_buffer *tr_chunk_untracked(void)
{
    id<MTLBuffer> m = [dev newBufferWithLength:TR_CHUNK
                                       options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    if (!m)
        return mglb_buffer_new(TR_CHUNK);
    if (!gs_fence)
        gs_fence = [dev newFence];
    struct mglb_buffer *b = calloc(1, sizeof *b);
    b->mtl = retain_obj(m);
    b->ptr = m.contents;
    b->size = b->cap = TR_CHUNK;
    buf_live_bytes += TR_CHUNK;
    return b;
}

#define TRIM_IDLE_NS 5000000000ull
#define TR_KEEP 2
/* mem_trim, about twice a second: free transient chunks and pooled buffers left unused for 5 s; mark big pooled
   buffers purgeable once the GPU is done with them */
static unsigned long trim_freed_chunks, trim_freed_bufs;
static size_t trim_freed_bytes;
static void mem_sweep(void)
{
    static uint64_t last;
    uint64_t t = now_ns();
    if (!mem_trim() || t - last < 500000000ull)
        return;
    last = t;
    uint64_t done = atomic_load(&completed_serial);
    for (int i = tr_n - 1; i >= 0 && tr_n > TR_KEEP; i--) {
        if (i == tr_cur || tr_chunk[i].b->last_use > done || t - tr_chunk[i].picked_ns < TRIM_IDLE_NS)
            continue;
        trim_freed_chunks++;
        trim_freed_bytes += tr_chunk[i].b->cap;
        buf_destroy(tr_chunk[i].b);
        tr_chunk[i] = tr_chunk[--tr_n]; /* the last one fills the hole */
        tr_chunk[tr_n].b = NULL;
        if (tr_cur == tr_n)
            tr_cur = i;
    }
    for (int c = 0; c < POOL_CLASSES; c++)
        for (struct mglb_buffer **pp = &pool[c], *prev = NULL; *pp;) {
            struct mglb_buffer *b = *pp;
            if (b->last_use > done) { /* the GPU may still read it: leave it alone */
                prev = b;
                pp = &b->next_free;
                continue;
            }
            if (t - b->pooled_ns >= TRIM_IDLE_NS) {
                *pp = b->next_free;
                if (pool_tail[c] == b) /* else the next release links onto freed memory */
                    pool_tail[c] = prev;
                pool_count[c]--;
                buf_pooled_bytes -= b->cap;
                if (b->purgeable)
                    buf_purgeable_bytes -= b->cap;
                trim_freed_bufs++;
                trim_freed_bytes += b->cap;
                buf_destroy(b);
                continue;
            }
            if (!b->purgeable && b->cap >= BIG_ROUND) {
                [OBJ(id<MTLBuffer>, b->mtl) setPurgeableState:MTLPurgeableStateVolatile];
                b->purgeable = 1;
                buf_purgeable_bytes += b->cap;
            }
            prev = b;
            pp = &b->next_free;
        }
}

static transient_t transient(size_t size)
{
    current_cb(); /* cb_serial is this command buffer's */
    size = (size + 255) & ~(size_t)255;
    if (size > TR_CHUNK) {
        tr_oneoff++;
        mglb_buffer *b = mglb_buffer_new(size);
        if (!b)
            return (transient_t){nil, 0, NULL};
        transient_t t = {OBJ(id<MTLBuffer>, b->mtl), 0, b->ptr};
        use_buffer(b);
        mglb_buffer_release(b);
        return t;
    }
    int k = tr_cur;
    if (k < 0 || tr_chunk[k].b->last_use != cb_serial || tr_chunk[k].used + size > TR_CHUNK) {
        uint64_t done = atomic_load(&completed_serial);
        k = -1;
        for (int i = 0; i < tr_n && k < 0; i++)
            if (tr_chunk[i].b->last_use <= done)
                k = i;
        if (k < 0 && tr_n < TR_MAX) {
            if (gs_untracked < 0)
                gs_untracked = getenv("MGL_GS_UNTRACKED") && atoi(getenv("MGL_GS_UNTRACKED")) != 0;
            mglb_buffer *b = gs_untracked ? tr_chunk_untracked() : mglb_buffer_new(TR_CHUNK);
            if (b) {
                k = tr_n++;
                tr_chunk[k].b = b;
            }
        }
        if (k < 0 && tr_n) {
            /* all chunks busy: wait for the oldest instead of allocating. One-off buffers here (~1500 a frame
               while SEUS turns) grew the process by ~6 GB/s: Metal didn't hand their memory back. */
            int old = 0;
            for (int i = 1; i < tr_n; i++)
                if (tr_chunk[i].b->last_use < tr_chunk[old].b->last_use)
                    old = i;
            uint64_t serial = tr_chunk[old].b->last_use;
            if (serial >= cb_serial && cb)
                commit(); /* the oldest is this command buffer's own: submit it first */
            tr_waits++;
            if (mglb_fence_wait(serial, 1000000000ull)) {
                current_cb();
                k = old;
            }
        }
        if (k < 0) { /* still nothing: a one-off buffer */
            tr_oneoff++;
            mglb_buffer *b = mglb_buffer_new(size);
            if (!b)
                return (transient_t){nil, 0, NULL};
            transient_t t = {OBJ(id<MTLBuffer>, b->mtl), 0, b->ptr};
            use_buffer(b);
            mglb_buffer_release(b);
            return t;
        }
        tr_chunk[k].used = 0;
        tr_chunk[k].picked_ns = now_ns();
        tr_cur = k;
    }
    mglb_buffer *b = tr_chunk[k].b;
    transient_t t = {OBJ(id<MTLBuffer>, b->mtl), (NSUInteger)tr_chunk[k].used, (char *)b->ptr + tr_chunk[k].used};
    tr_chunk[k].used += size;
    use_buffer(b);
    return t;
}

/* ================================================================ textures */

struct mglb_texture {
    void *mtl;
    mglb_texture_desc d;
    MTLPixelFormat pf;
    /* level 0 holds only `cval` (colour, or depth in cval[0]) since a clear pass, nothing written since: a
       repeat of that clear has nothing to do (Iris clears images every frame that nothing draws into) */
    int clean;
    float cval[4];
    MTLTextureUsage usage;
    /* views made at draw time, kept for the next draws (Iris samples a swizzled shadow map ~100 times a frame) */
    void *swz_view;
    int swz[4];
    void *level_view[4]; /* image views of levels 1-4 */
    size_t bytes;        /* allocatedSize, for the memory report */
};
static size_t tex_bytes;
static long tex_count;
static void tex_drop_views(mglb_texture *t)
{
    release_obj(t->swz_view);
    t->swz_view = NULL;
    for (int i = 0; i < 4; i++) {
        release_obj(t->level_view[i]);
        t->level_view[i] = NULL;
    }
}
static void tex_dirty(mglb_texture *t) { if (t) t->clean = 0; }
static void target_dirty(const mgl_target *t)
{
    for (int a = 0; a < MGL_MAX_ATTACHMENTS; a++)
        tex_dirty(t->tex[a]);
    tex_dirty(t->depth);
}
/* after a pass that only clears: the cleared level-0 images of plain 2D textures hold just the clear value */
static void mark_clean(const pending_clear *r)
{
    for (int a = 0; a < MGL_MAX_ATTACHMENTS; a++) {
        mglb_texture *x = r->t.tex[a];
        if (x && (r->colors & (1u << a)) && x->d.type == MGLT_2D && r->t.level[a] == 0) {
            x->clean = 1;
            memcpy(x->cval, r->rgba, sizeof x->cval);
        }
    }
    mglb_texture *z = r->t.depth;
    if (z && r->depth && z->d.type == MGLT_2D && r->t.depth_level == 0) {
        z->clean = 1;
        z->cval[0] = r->depth_value;
    }
}

static MTLPixelFormat pixel_format(enum mgl_format f)
{
    switch (f) {
    case MGLF_RGBA8: return MTLPixelFormatRGBA8Unorm;
    case MGLF_SRGB8_A8: return MTLPixelFormatRGBA8Unorm_sRGB;
    case MGLF_RGBA8_SNORM: return MTLPixelFormatRGBA8Snorm;
    case MGLF_R8: return MTLPixelFormatR8Unorm;
    case MGLF_RG8: return MTLPixelFormatRG8Unorm;
    case MGLF_RGBA16F: return MTLPixelFormatRGBA16Float;
    case MGLF_R16F: return MTLPixelFormatR16Float;
    case MGLF_RG16F: return MTLPixelFormatRG16Float;
    case MGLF_R32F: return MTLPixelFormatR32Float;
    case MGLF_RG32F: return MTLPixelFormatRG32Float;
    case MGLF_RGBA32F: return MTLPixelFormatRGBA32Float;
    case MGLF_R11G11B10F: return MTLPixelFormatRG11B10Float;
    case MGLF_RGB10A2: return MTLPixelFormatRGB10A2Unorm;
    case MGLF_R16UI: return MTLPixelFormatR16Uint;
    case MGLF_R32UI: return MTLPixelFormatR32Uint;
    case MGLF_R32I: return MTLPixelFormatR32Sint;
    case MGLF_RGBA16: return MTLPixelFormatRGBA16Unorm;
    case MGLF_R16: return MTLPixelFormatR16Unorm;
    case MGLF_RG16: return MTLPixelFormatRG16Unorm;
    case MGLF_RGBA8UI: return MTLPixelFormatRGBA8Uint;
    case MGLF_R8UI: return MTLPixelFormatR8Uint;
    case MGLF_RGBA16UI: return MTLPixelFormatRGBA16Uint;
    case MGLF_RGBA16I: return MTLPixelFormatRGBA16Sint;
    case MGLF_RGBA32I: return MTLPixelFormatRGBA32Sint;
    case MGLF_RG32UI: return MTLPixelFormatRG32Uint;
    case MGLF_RGBA32UI: return MTLPixelFormatRGBA32Uint;
    case MGLF_DEPTH32F: return MTLPixelFormatDepth32Float;
    case MGLF_DEPTH16: return MTLPixelFormatDepth16Unorm;
    case MGLF_DEPTH24_STENCIL8: /* not on Apple GPUs */
    case MGLF_DEPTH32F_STENCIL8: return MTLPixelFormatDepth32Float_Stencil8;
    default: return MTLPixelFormatRGBA8Unorm;
    }
}

static int is_depth_format(MTLPixelFormat pf)
{
    return pf == MTLPixelFormatDepth32Float || pf == MTLPixelFormatDepth16Unorm || pf == MTLPixelFormatDepth32Float_Stencil8;
}

static int is_int_format(MTLPixelFormat pf)
{
    switch (pf) {
    case MTLPixelFormatR16Uint: case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatRGBA8Uint:
    case MTLPixelFormatR8Uint: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA32Uint:
    case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRG32Uint:
        return 1;
    default:
        return 0;
    }
}

static int bytes_per_texel(MTLPixelFormat pf)
{
    switch (pf) {
    case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Uint: return 1;
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatR16Float: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Unorm:
    case MTLPixelFormatDepth16Unorm: return 2;
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA16Unorm:
    case MTLPixelFormatRGBA16Uint: case MTLPixelFormatDepth32Float_Stencil8: case MTLPixelFormatRGBA16Sint:
    case MTLPixelFormatRG32Uint: return 8;
    case MTLPixelFormatRGBA32Float: case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: return 16;
    default: return 4;
    }
}

static int tex_compress(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MGL_TEX_COMPRESS");
        on = !(e && *e == '0');
    }
    return on;
}

mglb_texture *mglb_texture_new(const mglb_texture_desc *d)
{
    init_device();
    MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
    MTLPixelFormat pf = pixel_format(d->format);
    td.pixelFormat = pf;
    td.width = (NSUInteger)(d->width > 0 ? d->width : 1);
    td.height = (NSUInteger)(d->height > 0 ? d->height : 1);
    td.mipmapLevelCount = (NSUInteger)(d->levels > 0 ? d->levels : 1);
    switch (d->type) {
    case MGLT_3D:
        td.textureType = MTLTextureType3D;
        td.depth = (NSUInteger)(d->depth > 0 ? d->depth : 1);
        break;
    case MGLT_2D_ARRAY:
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = (NSUInteger)(d->depth > 0 ? d->depth : 1);
        break;
    case MGLT_CUBE:
        td.textureType = MTLTextureTypeCube;
        break;
    default:
        td.textureType = MTLTextureType2D;
    }
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    if (!tex_compress())
        td.usage |= MTLTextureUsagePixelFormatView | (!is_depth_format(pf) && pf != MTLPixelFormatRGBA8Unorm_sRGB ? MTLTextureUsageShaderWrite : 0);
    if (pf == MTLPixelFormatR32Uint || pf == MTLPixelFormatR32Sint) /* image formats: atomics and writes from the start */
        td.usage |= MTLTextureUsageShaderAtomic | MTLTextureUsageShaderWrite; /* imageAtomic* (MSL 3.1 texture atomics) */
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    if (!t) {
        mgl_log("texture creation failed (%dx%dx%d format %d)", d->width, d->height, d->depth, d->format);
        return NULL;
    }
    struct mglb_texture *mt = calloc(1, sizeof *mt);
    mt->mtl = retain_obj(t);
    mt->d = *d;
    mt->pf = pf;
    mt->usage = td.usage;
    mt->bytes = t.allocatedSize;
    tex_bytes += mt->bytes;
    tex_count++;
    /* A new Metal texture holds whatever its memory held before; GL drivers hand out zeroed storage, and packs
       can count on it: Rethinking Voxels' irradiance cache (an Iris image with clear=false) accumulates into
       its first contents.
       3D textures start zeroed; MGL_ZERO_3D=0 leaves them as Metal makes them. */
    static int zero3d = -1;
    if (zero3d < 0) {
        const char *e = getenv("MGL_ZERO_3D");
        zero3d = !(e && *e == '0');
    }
    if (zero3d && d->type == MGLT_3D)
        for (int l = 0; l < (int)td.mipmapLevelCount; l++)
            mglb_texture_clear(mt, l, NULL);
    return mt;
}

/* Lossless compression: Apple GPUs keep render targets and textures compressed in memory (less bandwidth for every
   load, store and sample), but not a texture made with ShaderWrite or PixelFormatView usage. Every texture used to
   get both, so no shader pack target or shadow map was ever compressed. Now a texture starts with only what drawing
   into it and sampling it need; the first time something needs more (bound as an image, a swizzle, a copy through
   another format's view) it is remade with the extra usage, its contents copied over on the GPU, and swapped in
   under the same mglb_texture. MGL_TEX_COMPRESS=0: every texture gets the old usage from the start. */
static unsigned long tex_upgrades; /* MGL_PROFILE: textures remade with more usage */
static void tex_need_usage(mglb_texture *t, MTLTextureUsage need)
{
    if (!t || (t->usage & need) == need)
        return;
    if (is_depth_format(t->pf) || t->pf == MTLPixelFormatRGBA8Unorm_sRGB)
        need &= ~MTLTextureUsageShaderWrite; /* never writable as images */
    if ((t->usage & need) == need)
        return;
    id<MTLTexture> old = OBJ(id<MTLTexture>, t->mtl);
    MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
    td.textureType = old.textureType;
    td.pixelFormat = old.pixelFormat;
    td.width = old.width;
    td.height = old.height;
    td.depth = old.depth;
    td.arrayLength = old.arrayLength;
    td.mipmapLevelCount = old.mipmapLevelCount;
    td.storageMode = MTLStorageModePrivate;
    td.usage = t->usage | need;
    id<MTLTexture> fresh = [dev newTextureWithDescriptor:td];
    if (!fresh) {
        mgl_log("texture usage upgrade failed (%lux%lu format %lu)", (unsigned long)old.width, (unsigned long)old.height,
                (unsigned long)old.pixelFormat);
        return;
    }
    /* keep the contents (pending clears of it are replayed into the old one first) */
    [blit_encoder_for(t, NULL) copyFromTexture:old toTexture:fresh];
    tex_drop_views(t);
    release_obj(t->mtl); /* the copy (and earlier work) keep the old one alive until the GPU is done */
    t->mtl = retain_obj(fresh);
    t->usage = td.usage;
    tex_bytes += fresh.allocatedSize - t->bytes;
    t->bytes = fresh.allocatedSize;
    tex_upgrades++;
    if (opt_profile > 0)
        mgl_log("texture %lux%lux%lu format %lu remade with usage 0x%lx (compression off for it)", (unsigned long)old.width,
                (unsigned long)old.height, (unsigned long)(old.depth > 1 ? old.depth : old.arrayLength),
                (unsigned long)old.pixelFormat, (unsigned long)td.usage);
}

void mglb_texture_need_image(mglb_texture *t) { tex_need_usage(t, MTLTextureUsageShaderWrite); }
void mglb_texture_need_view(mglb_texture *t) { tex_need_usage(t, MTLTextureUsagePixelFormatView); }

void mglb_texture_release(mglb_texture *t)
{
    if (!t)
        return;
    gs_flush(); /* a pending geometry-shader draw may still bind it */
    if (pending_clear_uses(t))
        materialize_clears();
    if (renc) {
        /* the open render pass may still reference it; Metal retains it for the command buffer */
    }
    tex_drop_views(t);
    release_obj(t->mtl);
    tex_bytes -= t->bytes;
    tex_count--;
    free(t);
}

void mglb_texture_upload(mglb_texture *t, int level, int x, int y, int z, int w, int h, int d, const void *data,
                         size_t bytes_per_row, size_t bytes_per_image)
{
    if (!t || t->pf == MTLPixelFormatDepth32Float_Stencil8)
        return;
    size_t bpt = (size_t)bytes_per_texel(t->pf), row = bpt * (size_t)w, img = row * (size_t)h;
    if (img * (size_t)d > TR_CHUNK && row <= TR_CHUNK && mem_trim()) {
        /* bigger than a transient chunk: one slice at a time, in bands of rows that fit one */
        int band = (int)(TR_CHUNK / row);
        for (int s = 0; s < d; s++)
            for (int y0 = 0; y0 < h; y0 += band)
                mglb_texture_upload(t, level, x, y + y0, z + s, w, h - y0 < band ? h - y0 : band, 1,
                                    (const char *)data + (size_t)s * bytes_per_image + (size_t)y0 * bytes_per_row,
                                    bytes_per_row, bytes_per_image);
        return;
    }
    transient_t stage = transient(img * (size_t)d);
    if (!stage.buf)
        return;
    for (int zz = 0; zz < d; zz++)
        for (int yy = 0; yy < h; yy++)
            memcpy((char *)stage.ptr + (size_t)zz * img + (size_t)yy * row,
                   (const char *)data + (size_t)zz * bytes_per_image + (size_t)yy * bytes_per_row, row);
    id<MTLBlitCommandEncoder> e = blit_encoder_for(t, NULL);
    id<MTLTexture> tex = OBJ(id<MTLTexture>, t->mtl);
    if (t->d.type == MGLT_3D) {
        [e copyFromBuffer:stage.buf sourceOffset:stage.off sourceBytesPerRow:row sourceBytesPerImage:img
                 sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, (NSUInteger)d) toTexture:tex destinationSlice:0
           destinationLevel:(NSUInteger)level destinationOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, (NSUInteger)z)];
    } else {
        for (int s = 0; s < d; s++)
            [e copyFromBuffer:stage.buf sourceOffset:stage.off + (NSUInteger)s * img sourceBytesPerRow:row
                sourceBytesPerImage:img sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1) toTexture:tex
                   destinationSlice:(NSUInteger)(z + s) destinationLevel:(NSUInteger)level
                  destinationOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, 0)];
    }
}

void mglb_texture_generate_mipmaps(mglb_texture *t)
{
    if (!t || t->d.levels < 2 || is_int_format(t->pf) || is_depth_format(t->pf))
        return;
    [blit_encoder_for(t, NULL) generateMipmapsForTexture:OBJ(id<MTLTexture>, t->mtl)];
}

/* glClearTexImage source: one GPU-only buffer holding the clear pattern, refilled on the GPU only when the pattern
   changes or it has to grow. It used to be a new shared buffer filled by the CPU on every call: Iris clears packs'
   images every frame, and Rethinking Voxels' three cleared voxel volumes (~200 MB at its default size) cost about
   600 ms of CPU per frame, 1-2 fps. */
static id<MTLBuffer> clear_src;
static size_t clear_filled;         /* bytes of clear_src holding clear_pattern */
static unsigned char clear_pattern[16];
static size_t clear_bpt;

static void clear_source(size_t bytes, const unsigned char *texel, size_t bpt)
{
    if (clear_src && bytes <= clear_filled && bpt == clear_bpt && !memcmp(texel, clear_pattern, bpt))
        return;
    if (!clear_src || clear_src.length < bytes) {
        clear_src = [dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        clear_filled = 0;
        if (!clear_src)
            return;
    }
    int same_bytes = 1;
    for (size_t i = 1; i < bpt; i++)
        same_bytes &= texel[i] == texel[0];
    end_encoders(); /* earlier clears in this command buffer read clear_src: refill it in a later encoder */
    id<MTLBlitCommandEncoder> e = blit_encoder();
    size_t n = clear_src.length;
    if (same_bytes) {
        [e fillBuffer:clear_src range:NSMakeRange(0, n) value:texel[0]];
    } else { /* one texel from the CPU, then doubled on the GPU */
        mglb_buffer *one = mglb_buffer_new(bpt);
        if (!one)
            return;
        memcpy(one->ptr, texel, bpt);
        [e copyFromBuffer:OBJ(id<MTLBuffer>, one->mtl) sourceOffset:0 toBuffer:clear_src destinationOffset:0 size:bpt];
        use_buffer(one);
        mglb_buffer_release(one);
        for (size_t have = bpt; have < n; have *= 2) {
            end_encoders(); /* each doubling reads the last one: a new encoder orders them */
            [blit_encoder() copyFromBuffer:clear_src sourceOffset:0 toBuffer:clear_src destinationOffset:have
                                      size:have * 2 <= n ? have : n - have];
        }
    }
    end_encoders(); /* the texture copies that read it go in a later encoder */
    memcpy(clear_pattern, texel, bpt);
    clear_bpt = bpt;
    clear_filled = n - n % bpt;
}

void mglb_texture_clear(mglb_texture *t, int level, const void *texel)
{
    if (!t || t->pf == MTLPixelFormatDepth32Float_Stencil8)
        return;
    int w = t->d.width >> level, h = t->d.height >> level;
    int d = t->d.type == MGLT_3D ? t->d.depth >> level : t->d.type == MGLT_2D_ARRAY ? t->d.depth : t->d.type == MGLT_CUBE ? 6 : 1;
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (d < 1) d = 1;
    size_t bpt = (size_t)bytes_per_texel(t->pf), row = bpt * (size_t)w, img = row * (size_t)h;
    static const unsigned char zero[16];
    if (bpt > 16)
        return;
    size_t bytes = t->d.type == MGLT_3D ? img * (size_t)d : img; /* layers and cube faces reuse one image */
    clear_source(bytes, texel ? texel : zero, bpt);
    if (!clear_src || clear_filled < bytes)
        return;
    id<MTLBlitCommandEncoder> e = blit_encoder_for(t, NULL);
    id<MTLTexture> tex = OBJ(id<MTLTexture>, t->mtl);
    if (t->d.type == MGLT_3D)
        [e copyFromBuffer:clear_src sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:img
                 sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, (NSUInteger)d) toTexture:tex destinationSlice:0
           destinationLevel:(NSUInteger)level destinationOrigin:MTLOriginMake(0, 0, 0)];
    else
        for (int s = 0; s < d; s++)
            [e copyFromBuffer:clear_src sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:img
                   sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1) toTexture:tex destinationSlice:(NSUInteger)s
             destinationLevel:(NSUInteger)level destinationOrigin:MTLOriginMake(0, 0, 0)];
}

enum mgl_format mglb_texture_format(mglb_texture *t) { return t ? t->d.format : MGLF_COUNT; }

/* Synchronous: waits for all recorded GPU work, then copies the rectangle out in GL row order. */
void mglb_texture_read(mglb_texture *t, int level, int x, int y, int w, int h, void *out)
{
    if (!t || w <= 0 || h <= 0 || is_depth_format(t->pf))
        return;
    size_t bpt = (size_t)bytes_per_texel(t->pf), row = bpt * (size_t)w;
    mglb_buffer *stage = mglb_buffer_new(row * (size_t)h);
    if (!stage)
        return;
    id<MTLBlitCommandEncoder> e = blit_encoder();
    [e copyFromTexture:OBJ(id<MTLTexture>, t->mtl) sourceSlice:0 sourceLevel:(NSUInteger)level
          sourceOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, 0) sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
              toBuffer:OBJ(id<MTLBuffer>, stage->mtl) destinationOffset:0 destinationBytesPerRow:row
destinationBytesPerImage:row * (size_t)h];
    use_buffer(stage);
    mglb_finish();
    memcpy(out, stage->ptr, row * (size_t)h);
    mglb_buffer_release(stage);
}

int mglb_texture_read_to_buffer(mglb_texture *t, int level, int x, int y, int w, int h, mglb_buffer *dst, size_t off,
                                size_t bytes_per_row)
{
    if (!t || !dst || w <= 0 || h <= 0 || is_depth_format(t->pf) || (off | bytes_per_row) & 3)
        return 0;
    size_t bpt = (size_t)bytes_per_texel(t->pf);
    if (bytes_per_row < bpt * (size_t)w || off + bytes_per_row * (size_t)(h - 1) + bpt * (size_t)w > dst->size)
        return 0;
    id<MTLBlitCommandEncoder> e = blit_encoder();
    [e copyFromTexture:OBJ(id<MTLTexture>, t->mtl) sourceSlice:0 sourceLevel:(NSUInteger)level
          sourceOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, 0) sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
              toBuffer:OBJ(id<MTLBuffer>, dst->mtl) destinationOffset:off destinationBytesPerRow:bytes_per_row
destinationBytesPerImage:bytes_per_row * (size_t)h];
    use_buffer(dst);
    dst->gpu_write = cb_serial;
    dst->priv_ok = 0;
    return 1;
}

void mglb_texture_copy(mglb_texture *src, int src_level, int sx, int sy, int sz, mglb_texture *dst, int dst_level,
                       int dx, int dy, int dz, int w, int h, int d)
{
    if (!src || !dst)
        return;
    if (bytes_per_texel(src->pf) != bytes_per_texel(dst->pf) || is_depth_format(src->pf) != is_depth_format(dst->pf)) {
        mgl_log("texture copy between incompatible formats (%lu -> %lu) skipped", (unsigned long)src->pf, (unsigned long)dst->pf);
        return;
    }
    int sw = src->d.width >> src_level, shh = src->d.height >> src_level;
    if (sx < 0) { w += sx; dx -= sx; sx = 0; }
    if (sy < 0) { h += sy; dy -= sy; sy = 0; }
    if (sx + w > sw) w = sw - sx;
    if (sy + h > shh) h = shh - sy;
    if (w <= 0 || h <= 0)
        return;
    /* Metal blits need identical formats; GL allows same-size formats, so read the source through a view */
    id<MTLTexture> stex = OBJ(id<MTLTexture>, src->mtl);
    if (src->pf != dst->pf) {
        if (is_depth_format(src->pf)) {
            mgl_log("depth copy between different formats skipped");
            return;
        }
        tex_need_usage(src, MTLTextureUsagePixelFormatView);
        stex = [OBJ(id<MTLTexture>, src->mtl) newTextureViewWithPixelFormat:dst->pf];
    }
    id<MTLBlitCommandEncoder> e = blit_encoder_for(src, dst);
    int s3 = src->d.type == MGLT_3D, d3 = dst->d.type == MGLT_3D;
    for (int i = 0; i < d; i++)
        [e copyFromTexture:stex sourceSlice:(NSUInteger)(s3 ? 0 : sz + i)
               sourceLevel:(NSUInteger)src_level sourceOrigin:MTLOriginMake((NSUInteger)sx, (NSUInteger)sy, (NSUInteger)(s3 ? sz + i : 0))
                sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1) toTexture:OBJ(id<MTLTexture>, dst->mtl)
          destinationSlice:(NSUInteger)(d3 ? 0 : dz + i) destinationLevel:(NSUInteger)dst_level
         destinationOrigin:MTLOriginMake((NSUInteger)dx, (NSUInteger)dy, (NSUInteger)(d3 ? dz + i : 0))];
}

/* ================================================================ programs */

struct mglb_program {
    void *vfn, *ffn;
    void *vlib;      /* MTLLibrary of the vertex stage when it has scaled-attribute constants (else NULL) */
    void *vscaled;   /* NSMutableDictionary: scale mask -> specialised vertex MTLFunction */
    void *compute;   /* MTLComputePipelineState */
    void *clib;      /* MTLLibrary of a geometry shader's compute stage (its vertex format is a function constant) */
    void *cspec;     /* NSMutableDictionary: vertex format -> compute pipeline made for it (NSNull while compiling) */
    uint32_t id;
    int discards;    /* the fragment stage can discard (so a full-screen draw may not cover every pixel) */
    char label[112]; /* "GL program N [app name]", for error reports and MGL_*_PROGRAMS */
};

void mglb_program_label(mglb_program *p, const char *label)
{
    if (p)
        snprintf(p->label, sizeof p->label, "%s", label);
}

static int debug_draws(void)
{
    static int on = -1;
    if (on < 0)
        on = opt("MGL_DEBUG_DRAWS");
    return on;
}

/* Debug: does any index (plus base vertex) point past the end of a per-vertex buffer? Reads the indices on the
   CPU (buffers are shared memory). Reports each program once. */
static void check_vertex_range(const mgl_draw *d, int count, size_t ioff, int base)
{
    if (!d->index_buf || count <= 0)
        return;
    size_t isz = d->index_type == GL_UNSIGNED_SHORT ? 2 : 4;
    if (ioff + isz * (size_t)count > d->index_buf->size) {
        mgl_log("debug: %s reads indices %zu..%zu but the index buffer holds %zu bytes", d->program->label, ioff,
                ioff + isz * (size_t)count, d->index_buf->size);
        return;
    }
    const unsigned char *ip = (const unsigned char *)d->index_buf->ptr + ioff;
    long maxi = 0;
    for (int i = 0; i < count; i++) {
        long v = isz == 2 ? ((const uint16_t *)ip)[i] : (long)((const uint32_t *)ip)[i];
        if (v > maxi)
            maxi = v;
    }
    maxi += base;
    for (int b = 0; b < d->num_vbufs; b++) {
        const mgl_vertex_buf *vb = &d->vbufs[b];
        if (vb->stride <= 0 || vb->divisor)
            continue;
        long have = vb->buf->size > vb->offset ? (long)((vb->buf->size - vb->offset) / (size_t)vb->stride) : 0;
        if (maxi >= have) {
            static uint32_t seen[64];
            static int nseen;
            for (int k = 0; k < nseen; k++)
                if (seen[k] == d->program->id)
                    return;
            if (nseen < 64)
                seen[nseen++] = d->program->id;
            mgl_log("debug: %s reads vertex %ld but vertex buffer %d (offset %zu, stride %d, %zu bytes) holds %ld vertices",
                    d->program->label, maxi, b, vb->offset, vb->stride, vb->buf->size, have);
        }
    }
}

/* After a fault: the draw's vertex layout, its first vertices and the start of its vertex-stage uniforms, so a
   bad decode (garbage positions, huge triangles) shows up in the log. */
static void describe_draw(const mgl_draw *d)
{
    static const char *tn[] = {"float", "half", "ubyte", "byte", "ushort", "short", "uint", "int"};
    for (int b = 0; b < d->num_vbufs; b++)
        mgl_log("debug: vertex buffer %d: offset %zu, stride %d, divisor %d, %zu bytes", b, d->vbufs[b].offset,
                d->vbufs[b].stride, d->vbufs[b].divisor, d->vbufs[b].buf->size);
    for (int i = 0; i < MGL_MAX_VERTEX_ATTRIBS; i++) {
        const mgl_vertex_attr *a = &d->attrs[i];
        if (!a->enabled)
            continue;
        mgl_log("debug: attribute %d: %s x%d%s%s, buffer %d, offset %zu", a->location, tn[a->type], a->size,
                a->normalized ? " normalized" : "", a->integer ? " integer" : "", a->buffer, a->offset);
        const mgl_vertex_buf *vb = &d->vbufs[a->buffer];
        if (a->type != MGLV_FLOAT || vb->stride <= 0)
            continue;
        const unsigned char *base = (const unsigned char *)vb->buf->ptr + vb->offset + a->offset;
        float lo[4] = {1e30f, 1e30f, 1e30f, 1e30f}, hi[4] = {-1e30f, -1e30f, -1e30f, -1e30f};
        size_t n = (vb->buf->size - vb->offset) / (size_t)vb->stride;
        for (size_t v = 0; v < n; v++)
            for (int c = 0; c < a->size; c++) {
                float f;
                memcpy(&f, base + v * (size_t)vb->stride + 4 * (size_t)c, 4);
                if (f < lo[c]) lo[c] = f;
                if (f > hi[c]) hi[c] = f;
            }
        float f0[4] = {0};
        memcpy(f0, base, 4 * (size_t)a->size);
        mgl_log("debug:   first %g %g %g %g; range over %zu vertices x %g..%g y %g..%g z %g..%g", f0[0], f0[1], f0[2],
                f0[3], n, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]);
    }
    if (d->uniforms[0] && d->uniform_size[0] >= 4) {
        const float *u = d->uniforms[0];
        int n = d->uniform_size[0] / 4 < 40 ? d->uniform_size[0] / 4 : 40;
        char line[1024];
        int k = snprintf(line, sizeof line, "debug: vertex uniforms (%d bytes):", d->uniform_size[0]);
        for (int i = 0; i < n && k < (int)sizeof line - 16; i++)
            k += snprintf(line + k, sizeof line - (size_t)k, " %g", u[i]);
        mgl_log("%s", line);
    }
    mgl_log("debug: blend %d, depth test %d write %d func 0x%x, cull %d, viewport %d %d %d %d", d->blend[0].enabled,
            d->depth_test, d->depth_write, d->depth_func, d->cull, d->viewport[0], d->viewport[1], d->viewport[2],
            d->viewport[3]);
}

/* MGL_SKIP_PROGRAMS=24,31: never draw with these GL programs (for bisecting a GPU fault). */
static int skip_program(const mgl_draw *d)
{
    static int n = -1;
    static unsigned ids[32];
    if (n < 0) {
        n = 0;
        const char *e = getenv("MGL_SKIP_PROGRAMS");
        while (e && *e && n < 32) {
            ids[n++] = (unsigned)strtoul(e, (char **)&e, 10);
            while (*e == ',' || *e == ' ')
                e++;
        }
    }
    unsigned gl = 0;
    if (n && d->program && sscanf(d->program->label, "GL program %u", &gl) == 1)
        for (int i = 0; i < n; i++)
            if (ids[i] == gl)
                return 1;
    return 0;
}

/* What level 0 of a plain 2D texture is known to hold: the colour of a clear still pending for it, or of the clear
   it still holds (clean). NULL: unknown. */
static const float *known_colour(const mglb_texture *x)
{
    for (int i = npclear - 1; i >= 0; i--)
        for (int a = 0; a < MGL_MAX_ATTACHMENTS; a++)
            if (pclear[i].t.tex[a] == x && (pclear[i].colors & (1u << a)))
                return pclear[i].t.level[a] == 0 ? pclear[i].rgba : NULL;
    return x->clean ? x->cval : NULL;
}

/* A draw that cannot change its target: its fragment stage passes its one texture's sample straight through
   (d->copy_fs), the texture holds only alpha 0, and every written attachment blends so that a source with alpha 0
   leaves it as it is. Minecraft blends its glowing-outline layer over the screen every frame, empty or not (a
   full-screen pass, plus a clear pass replayed for the layer, for nothing). MGL_SKIP_EMPTY_BLIT=0: draw anyway. */
static int draws_nothing(const mgl_draw *d)
{
    static int on = -1;
    if (on < 0)
        on = !getenv("MGL_SKIP_EMPTY_BLIT") || atoi(getenv("MGL_SKIP_EMPTY_BLIT")) != 0;
    if (!on || !d->copy_fs || d->num_textures[MGL_FRAGMENT] != 1 || (d->depth_test && d->depth_write && d->target.depth))
        return 0;
    const mgl_bound_texture *b = &d->textures[MGL_FRAGMENT][0];
    enum mgl_format f = b->tex ? b->tex->d.format : MGLF_NONE; /* (an alpha the image really holds) */
    if (!b->tex || b->tex->d.type != MGLT_2D || b->tex->d.levels != 1 || b->swizzle[3] || b->is_image ||
        !(f == MGLF_RGBA8 || f == MGLF_SRGB8_A8 || f == MGLF_RGBA16F || f == MGLF_RGBA32F || f == MGLF_RGBA16))
        return 0;
    const float *c = known_colour(b->tex);
    if (!c || c[3] != 0.0f)
        return 0;
    int black = c[0] == 0.0f && c[1] == 0.0f && c[2] == 0.0f && !b->swizzle[0] && !b->swizzle[1] && !b->swizzle[2];
    for (int a = 0; a < MGL_MAX_ATTACHMENTS; a++) {
        const mgl_blend *bl = &d->blend[a];
        if (!d->target.tex[a] || !(bl->color_mask & 0xF))
            continue;
        if (!bl->enabled)
            return 0;
        /* (the source side adds factor x source: 0 when either is 0; the target side must keep the target) */
        int src0 = bl->src_rgb == GL_SRC_ALPHA || bl->src_rgb == GL_ZERO || black;
        if ((bl->color_mask & 0x7) && (bl->eq_rgb != GL_FUNC_ADD || !src0 ||
                                       !(bl->dst_rgb == GL_ONE_MINUS_SRC_ALPHA || bl->dst_rgb == GL_ONE)))
            return 0;
        if ((bl->color_mask & 0x8) && (bl->eq_a != GL_FUNC_ADD || !(bl->dst_a == GL_ONE_MINUS_SRC_ALPHA || bl->dst_a == GL_ONE)))
            return 0;
    }
    if (dump_this_frame())
        mgl_log("frame dump: draw skipped: %s only blends transparent black", d->program->label);
    return 1;
}

/* MGL_DEBUG_DRAWS=1: finish the GPU after every draw and dispatch, and name the first one that faults.
   Very slow; for finding which program hangs or crashes the GPU. */
static void debug_sync(const char *what, const mgl_draw *d, long a, long b)
{
    static int reported;
    if (!debug_draws() || reported)
        return;
    commit();
    [last_cb waitUntilCompleted];
    if (last_cb.error) {
        reported = 1;
        mgl_log("GPU fault in %s with %s (count/groups %ld, %ld; instances %d; index type 0x%x; multi %d; %d vertex buffers; "
                "target %dx%d): %s", what, d->program && d->program->label[0] ? d->program->label : "unlabelled program", a, b,
                d->instances, d->index_type, d->multi_n, d->num_vbufs, d->target.width, d->target.height,
                last_cb.error.localizedDescription.UTF8String);
        describe_draw(d);
    }
}


/* GL converts integer vertex data to float when glVertexAttribPointer isn't normalising (Iris feeds Sodium's
   mid-texture coordinate as plain unsigned shorts and scales it in the shader). Metal has no such "scaled"
   formats: integer data only reaches integer inputs. So such attributes are fetched normalised (0..1) and the
   vertex function multiplies them back up: main0 starts with in.NAME *= mgl_vscale_N for every float input N, a
   function constant that defaults to 1 and is specialised per pipeline (255, 127, 65535 or 32767) when needed. */
#define MGL_VSCALE_FC 100 /* function constant index base */
static char *scale_vertex_inputs(const char *msl)
{
    const char *st = strstr(msl, "struct main0_in\n{\n");
    const char *end = st ? strstr(st, "\n};") : NULL;
    if (!end)
        return NULL;
    struct { char name[96]; int loc; } in[MGL_MAX_VERTEX_ATTRIBS];
    int n = 0;
    for (const char *l = strchr(st, '{') + 2; l < end && n < MGL_MAX_VERTEX_ATTRIBS;) {
        const char *nl = strchr(l, '\n');
        char type[32], name[96];
        int loc;
        if (sscanf(l, " %31s %95s [[attribute(%d)]];", type, name, &loc) == 3 && !strncmp(type, "float", 5) &&
            loc >= 0 && loc < MGL_MAX_VERTEX_ATTRIBS) {
            snprintf(in[n].name, sizeof in[n].name, "%s", name);
            in[n++].loc = loc;
        }
        l = nl ? nl + 1 : end;
    }
    if (!n)
        return NULL;
    size_t len = strlen(msl), cap = len * 2 + 4096, o = 0;
    char *out = malloc(cap);
    /* constants go right before the input struct */
    memcpy(out, msl, (size_t)(st - msl));
    o = (size_t)(st - msl);
    for (int i = 0; i < n; i++)
        o += (size_t)snprintf(out + o, cap - o,
                              "constant float mgl_vscale_%d_fc [[function_constant(%d)]];\n"
                              "constant float mgl_vscale_%d = is_function_constant_defined(mgl_vscale_%d_fc) ? "
                              "mgl_vscale_%d_fc : 1.0;\n",
                              in[i].loc, MGL_VSCALE_FC + in[i].loc, in[i].loc, in[i].loc, in[i].loc);
    /* the input struct is a by-value parameter: scale it in place at the top of main0, so every use (also those
       passed by reference to helper functions) sees GL's values */
    const char *fn = strstr(end, " main0(");
    const char *open = fn ? strstr(fn, "\n{\n") : NULL;
    if (!open) {
        free(out);
        return NULL;
    }
    open += 3;
    memcpy(out + o, st, (size_t)(open - st));
    o += (size_t)(open - st);
    for (int i = 0; i < n; i++)
        o += (size_t)snprintf(out + o, cap - o, "    in.%s *= mgl_vscale_%d;\n", in[i].name, in[i].loc);
    size_t rest = strlen(open);
    if (o + rest + 1 > cap)
        out = realloc(out, cap = o + rest + 1);
    memcpy(out + o, open, rest);
    o += rest;
    out[o] = 0;
    return out;
}

static id<MTLFunction> compile_fn_lib(const char *msl, NSString *what, char **err, id<MTLLibrary> *lib_out);
static id<MTLFunction> compile_fn(const char *msl, NSString *what, char **err)
{
    return compile_fn_lib(msl, what, err, NULL);
}

/* sin(, cos( and pow( calls in generated MSL -> precise:: versions (NULL if there is none); not asin, sinh
   or already-qualified calls. The rest of the maths functions stay fast. */
static char precise_names[32][16];
static int precise_count;

static void precise_init(void)
{
    /* MGL_PRECISE=sin,pow,exp,...: the functions made precise (for finding which one a pack needs) */
    const char *e = getenv("MGL_PRECISE");
    char list[256], *save = NULL;
    snprintf(list, sizeof list, "%s", e ? e : "sin,cos,pow");
    for (char *t = strtok_r(list, ", ", &save); t && precise_count < 32; t = strtok_r(NULL, ", ", &save))
        snprintf(precise_names[precise_count++], sizeof precise_names[0], "%s(", t);
    mgl_log("precise maths functions: %s", e ? e : "sin,cos,pow");
}

static int precise_at(const char *msl, const char *p, size_t *len)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, precise_init);
    const int count = precise_count;
    char (*names)[16] = precise_names;
    char c = p > msl ? p[-1] : ' ';
    if (isalnum((unsigned char)c) || c == '_' || c == ':' || c == '.')
        return 0;
    for (int i = 0; i < count; i++)
        if (!strncmp(p, names[i], strlen(names[i]))) {
            *len = strlen(names[i]);
            return 1;
        }
    return 0;
}

static char *precise_sin(const char *msl)
{
    size_t n = 0, len;
    for (const char *p = msl; *p; p++)
        n += precise_at(msl, p, &len);
    if (!n)
        return NULL;
    char *out = malloc(strlen(msl) + n * 9 + 1), *o = out;
    for (const char *p = msl; *p; p++) {
        if (precise_at(msl, p, &len)) {
            memcpy(o, "precise::", 9);
            o += 9;
        }
        *o++ = *p;
    }
    *o = 0;
    return out;
}

static id<MTLFunction> compile_fn_lib(const char *msl, NSString *what, char **err, id<MTLLibrary> *lib_out)
{
    NSError *e = nil;
    MTLCompileOptions *o = [[MTLCompileOptions alloc] init];
    o.languageVersion = MTLLanguageVersion3_1; /* 3.1: native texture atomics (Rethinking Voxels) */
    /* GLSL lets compilers reassociate and contract floating-point maths, and Apple's OpenGL compiles with fast
       maths. Safe mode cost about a quarter of the GPU time in every shader-pack pass on an M3 Max. Relaxed keeps
       NaN and infinity behaving (packs test for them); MGL_MATH=safe|relaxed|fast overrides. */
    static int math = -1;
    if (math < 0) {
        const char *m = getenv("MGL_MATH");
        math = m && !strcmp(m, "safe") ? 0 : m && !strcmp(m, "fast") ? 2 : 1;
        mgl_log("shader maths: %s", math == 0 ? "safe" : math == 2 ? "fast" : "relaxed");
    }
    if (@available(macOS 15.0, *)) {
        o.mathMode = math == 0 ? MTLMathModeSafe : math == 2 ? MTLMathModeFast : MTLMathModeRelaxed;
        /* fast exp/sqrt etc. (all-precise functions cost SEUS PTGI 16 -> 10 fps), but sin, cos and pow are made
           precise in the source (precise_sin): packs hash with fract(sin(x) * 43758.5) on large x (fast sin gave
           SEUS streaks across the sky; fast cos, found by bisecting on an M3, grain and a seam down the screen
           that SEUS's temporal buffers kept). MGL_MATH_FUNCS=precise makes them all precise. */
        o.mathFloatingPointFunctions = getenv("MGL_MATH_FUNCS") && !strcmp(getenv("MGL_MATH_FUNCS"), "precise")
                                           ? MTLMathFloatingPointFunctionsPrecise
                                           : MTLMathFloatingPointFunctionsFast;
    } else
        o.fastMathEnabled = math > 0;
    char *fixed = math > 0 && !getenv("MGL_FAST_SIN") ? precise_sin(msl) : NULL;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:fixed ? fixed : msl] options:o error:&e];
    free(fixed);
    if (!lib) {
        if (err)
            *err = strdup([NSString stringWithFormat:@"%@: %@", what, e.localizedDescription].UTF8String);
        return nil;
    }
    if (strstr(msl, "[[function_constant(")) {
        if (lib_out)
            *lib_out = lib;
        /* no constants set: every scale is 1, every attribute read the general way (a function with constants
           must come from this call) */
        return [lib newFunctionWithName:@"main0" constantValues:[[MTLFunctionConstantValues alloc] init] error:&e];
    }
    return [lib newFunctionWithName:@"main0"];
}

/* ---- binary archive: compiled GPU code for every pipeline, saved next to the translation cache ---- */
static id<MTLBinaryArchive> archive;
static NSURL *archive_url;
static pthread_mutex_t archive_lock = PTHREAD_MUTEX_INITIALIZER; /* adds come from link workers too */
static int archive_dirty;
static uint64_t archive_last_add;
static uint64_t now_ns(void);
static void save_at_exit(void);

static id<MTLBinaryArchive> get_archive(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      if (opt_archive <= 0)
          return;
      NSString *dir = [NSString stringWithUTF8String:getenv("MGL_CACHE_DIR")];
      archive_url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"pipelines.metallib"]];
      MTLBinaryArchiveDescriptor *ad = [[MTLBinaryArchiveDescriptor alloc] init];
      if ([[NSFileManager defaultManager] fileExistsAtPath:archive_url.path])
          ad.url = archive_url;
      NSError *e = nil;
      archive = [dev newBinaryArchiveWithDescriptor:ad error:&e];
      if (!archive && ad.url) { /* unreadable (older OS/driver): start a fresh one */
          mgl_log("binary archive unreadable, starting fresh: %s", e.localizedDescription.UTF8String);
          ad.url = nil;
          archive = [dev newBinaryArchiveWithDescriptor:ad error:&e];
      }
      if (!archive) {
          mgl_log("binary archive unavailable: %s", e.localizedDescription.UTF8String);
      } else {
          mgl_log("binary archive %s", ad.url ? "loaded" : "created");
          atexit(save_at_exit);
      }
    });
    return archive;
}

static void archive_add_render(MTLRenderPipelineDescriptor *pd)
{
    if (!archive)
        return;
    pthread_mutex_lock(&archive_lock);
    NSError *e = nil;
    if ([archive addRenderPipelineFunctionsWithDescriptor:pd error:&e]) {
        archive_dirty = 1;
        archive_last_add = now_ns();
    }
    pthread_mutex_unlock(&archive_lock);
}

static void archive_add_compute(MTLComputePipelineDescriptor *cpd)
{
    if (!archive)
        return;
    pthread_mutex_lock(&archive_lock);
    NSError *e = nil;
    if ([archive addComputePipelineFunctionsWithDescriptor:cpd error:&e]) {
        archive_dirty = 1;
        archive_last_add = now_ns();
    }
    pthread_mutex_unlock(&archive_lock);
}

/* Writes the archive when it has news. Called at exit, and from the frame loop (on a background queue) once
   nothing new was added for 20 s, so the write never lands in the middle of a burst of new pipelines. */
static void archive_save(void)
{
    if (!archive)
        return;
    pthread_mutex_lock(&archive_lock);
    if (archive_dirty) {
        NSError *e = nil;
        if ([archive serializeToURL:archive_url error:&e])
            archive_dirty = 0;
        else
            mgl_log("binary archive save failed: %s", e.localizedDescription.UTF8String);
    }
    pthread_mutex_unlock(&archive_lock);
}

static void save_at_exit(void)
{
    mgl_program_drain(); /* registered after the link workers' drain, so it runs first: finish their pipelines */
    archive_save();
}

static void archive_maybe_save(void)
{
    static int saving;
    if (!archive || !archive_dirty || saving || now_ns() - archive_last_add < 20000000000ull)
        return;
    saving = 1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      archive_save();
      saving = 0;
    });
}

/* Runs on the link worker threads (core/mgl_program.c), several at once: MTLDevice compiles are thread-safe. */
mglb_program *mglb_program_new(const char *msl_vertex, const char *msl_fragment, const char *msl_compute, char **err)
{
    static uint32_t next_id;
    init_device();
    struct mglb_program *p = calloc(1, sizeof *p);
    p->id = __atomic_add_fetch(&next_id, 1, __ATOMIC_RELAXED);
    @autoreleasepool {
        if (msl_compute) {
            id<MTLLibrary> clib = nil;
            id<MTLFunction> f = compile_fn_lib(msl_compute, @"compute", err, &clib);
            NSError *e = nil;
            id<MTLComputePipelineState> ps = nil;
            if (f && get_archive()) {
                MTLComputePipelineDescriptor *cpd = [[MTLComputePipelineDescriptor alloc] init];
                cpd.computeFunction = f;
                cpd.binaryArchives = @[ archive ];
                ps = [dev newComputePipelineStateWithDescriptor:cpd options:MTLPipelineOptionNone reflection:nil error:&e];
                if (ps)
                    archive_add_compute(cpd);
            } else if (f) {
                ps = [dev newComputePipelineStateWithFunction:f error:&e];
            }
            if (!ps) {
                /* the backend compiler's message is often just "Compilation failed": say which stage failed and
                   pass on whatever else the error carries */
                if (err && !*err)
                    *err = strdup([NSString stringWithFormat:@"compute pipeline: %@ (code %ld) %@", e.localizedDescription,
                                                             (long)e.code, e.userInfo ?: @{}]
                                      .UTF8String);
                free(p);
                return NULL;
            }
            p->compute = retain_obj(ps);
            if (clib) {
                p->clib = retain_obj(clib);
                p->cspec = retain_obj([NSMutableDictionary dictionary]);
            }
            if (!msl_vertex) /* geometry-shader programs carry a compute stage plus the passthrough vertex stage */
                return p;
        }
        char *scaled = msl_vertex ? scale_vertex_inputs(msl_vertex) : NULL;
        id<MTLLibrary> vlib = nil;
        id<MTLFunction> v = msl_vertex ? compile_fn_lib(scaled ? scaled : msl_vertex, @"vertex", err, &vlib) : nil;
        free(scaled);
        id<MTLFunction> f = v && msl_fragment ? compile_fn(msl_fragment, @"fragment", err) : nil;
        if (!v || (msl_fragment && !f)) {
            release_obj(p->compute);
            free(p);
            return NULL;
        }
        p->vfn = retain_obj(v);
        p->ffn = f ? retain_obj(f) : NULL;
        p->discards = msl_fragment && strstr(msl_fragment, "discard_fragment");
        if (vlib) {
            p->vlib = retain_obj(vlib);
            p->vscaled = retain_obj([NSMutableDictionary dictionary]);
        }
    }
    return p;
}

void mglb_program_release(mglb_program *p)
{
    if (!p)
        return;
    release_obj(p->vfn);
    release_obj(p->ffn);
    release_obj(p->vlib);
    release_obj(p->vscaled);
    release_obj(p->compute);
    release_obj(p->clib);
    release_obj(p->cspec);
    free(p);
}

/* ================================================================ state objects (cached) */

static MTLBlendFactor blend_factor(int f)
{
    switch (f) {
    case GL_ZERO: return MTLBlendFactorZero;
    case GL_ONE: return MTLBlendFactorOne;
    case GL_SRC_COLOR: return MTLBlendFactorSourceColor;
    case GL_ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
    case GL_DST_COLOR: return MTLBlendFactorDestinationColor;
    case GL_ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
    case GL_SRC_ALPHA: return MTLBlendFactorSourceAlpha;
    case GL_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
    case GL_DST_ALPHA: return MTLBlendFactorDestinationAlpha;
    case GL_ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
    case GL_CONSTANT_COLOR: return MTLBlendFactorBlendColor;
    case GL_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
    case GL_CONSTANT_ALPHA: return MTLBlendFactorBlendAlpha;
    case GL_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
    case GL_SRC_ALPHA_SATURATE: return MTLBlendFactorSourceAlphaSaturated;
    }
    return MTLBlendFactorOne;
}

static MTLBlendOperation blend_op(int e)
{
    switch (e) {
    case GL_FUNC_SUBTRACT: return MTLBlendOperationSubtract;
    case GL_FUNC_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
    case GL_MIN: return MTLBlendOperationMin;
    case GL_MAX: return MTLBlendOperationMax;
    }
    return MTLBlendOperationAdd;
}

static MTLCompareFunction compare_fn(int f)
{
    switch (f) {
    case GL_NEVER: return MTLCompareFunctionNever;
    case GL_LESS: return MTLCompareFunctionLess;
    case GL_EQUAL: return MTLCompareFunctionEqual;
    case GL_LEQUAL: return MTLCompareFunctionLessEqual;
    case GL_GREATER: return MTLCompareFunctionGreater;
    case GL_NOTEQUAL: return MTLCompareFunctionNotEqual;
    case GL_GEQUAL: return MTLCompareFunctionGreaterEqual;
    }
    return MTLCompareFunctionAlways;
}

/* The scale a float input needs when GL converts this attribute's integers without normalising (0 = none). */
static int vertex_scale(const mgl_vertex_attr *a)
{
    if (a->integer || a->normalized)
        return 0;
    switch (a->type) {
    case MGLV_UBYTE: return 255;
    case MGLV_BYTE: return 127;
    case MGLV_USHORT: return 65535;
    case MGLV_SHORT: return 32767;
    default: return 0;
    }
}

static MTLVertexFormat vertex_format(const mgl_vertex_attr *a)
{
    int n = a->size < 1 ? 1 : a->size > 4 ? 4 : a->size;
#define PICK(x1, x2, x3, x4) (n == 1 ? (x1) : n == 2 ? (x2) : n == 3 ? (x3) : (x4))
    switch (a->type) {
    case MGLV_FLOAT: return PICK(MTLVertexFormatFloat, MTLVertexFormatFloat2, MTLVertexFormatFloat3, MTLVertexFormatFloat4);
    case MGLV_HALF: return PICK(MTLVertexFormatHalf, MTLVertexFormatHalf2, MTLVertexFormatHalf3, MTLVertexFormatHalf4);
    case MGLV_UBYTE:
        if (a->integer)
            return PICK(MTLVertexFormatUChar, MTLVertexFormatUChar2, MTLVertexFormatUChar3, MTLVertexFormatUChar4);
        return PICK(MTLVertexFormatUCharNormalized, MTLVertexFormatUChar2Normalized, MTLVertexFormatUChar3Normalized,
                    MTLVertexFormatUChar4Normalized);
    case MGLV_BYTE:
        if (a->integer)
            return PICK(MTLVertexFormatChar, MTLVertexFormatChar2, MTLVertexFormatChar3, MTLVertexFormatChar4);
        return PICK(MTLVertexFormatCharNormalized, MTLVertexFormatChar2Normalized, MTLVertexFormatChar3Normalized,
                    MTLVertexFormatChar4Normalized);
    case MGLV_USHORT:
        if (a->integer)
            return PICK(MTLVertexFormatUShort, MTLVertexFormatUShort2, MTLVertexFormatUShort3, MTLVertexFormatUShort4);
        return PICK(MTLVertexFormatUShortNormalized, MTLVertexFormatUShort2Normalized, MTLVertexFormatUShort3Normalized,
                    MTLVertexFormatUShort4Normalized);
    case MGLV_SHORT:
        if (a->integer)
            return PICK(MTLVertexFormatShort, MTLVertexFormatShort2, MTLVertexFormatShort3, MTLVertexFormatShort4);
        return PICK(MTLVertexFormatShortNormalized, MTLVertexFormatShort2Normalized, MTLVertexFormatShort3Normalized,
                    MTLVertexFormatShort4Normalized);
    case MGLV_UINT: return PICK(MTLVertexFormatUInt, MTLVertexFormatUInt2, MTLVertexFormatUInt3, MTLVertexFormatUInt4);
    case MGLV_INT: return PICK(MTLVertexFormatInt, MTLVertexFormatInt2, MTLVertexFormatInt3, MTLVertexFormatInt4);
    }
#undef PICK
    return MTLVertexFormatFloat4;
}

/* ================================================================ GPU chunk culling (core/mgl_cull.c) */

/* One compute thread per Sodium section draw: keep it if its 16-block box is inside the pass's view, and write its
   indirect draw arguments (no instances when culled). The region's multi-draw then draws each section from those
   arguments with everything else (pipeline, vertex buffers, uniforms, textures) as usual. Indirect command buffers
   would save the per-section calls too, but Metal refuses them for fragment shaders that bind textures directly,
   which is every GL shader we translate. */
static const char *cull_msl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Draw { uint count, first_index, base_vertex, region; packed_float3 mn; float pad; };\n"
    "struct Params { float4 planes[6]; uint first, n, region_base, flags; float4x4 prev; float4 delta; uint4 hiz; };\n"
    "struct Args { uint index_count, instance_count, index_start; int base_vertex; uint base_instance; };\n"
    /* hidden behind last frame's depth: the box (moved into last frame's camera space) projected with last frame's
       matrix, its nearest depth against the farthest depth under its screen rectangle. Anything not fully on last
       frame's screen, or reaching behind its camera, is kept. */
    "static bool occluded(float3 mn, constant Params &p, texture2d<float, access::read> hiz) {\n"
    "    float zmin = 2.0; float2 lo = float2(1e9), hi = float2(-1e9);\n"
    "    for (int c = 0; c < 8; c++) {\n"
    "        float3 q = mn + p.delta.xyz + float3(c & 1 ? 16.0 : 0.0, c & 2 ? 16.0 : 0.0, c & 4 ? 16.0 : 0.0);\n"
    "        float4 h = p.prev * float4(q, 1.0);\n"
    "        if (h.w <= 1e-3) return false;\n"
    "        float3 v = h.xyz / h.w;\n"
    "        zmin = min(zmin, v.z * 0.5 + 0.5);\n"
    "        lo = min(lo, v.xy); hi = max(hi, v.xy);\n"
    "    }\n"
    "    if (any(lo < -1.0) || any(hi > 1.0)) return false;\n"
    "    float2 sz = float2(p.hiz.xy);\n"
    "    uint2 a = uint2(max((lo * 0.5 + 0.5) * sz - 1.0, float2(0.0))), b = uint2(min((hi * 0.5 + 0.5) * sz + 1.0, sz - 1.0));\n"
    "    uint l = 0;\n"
    "    while (any((b >> (l + 1u)) - (a >> (l + 1u)) > uint2(1u))) {\n"
    "        if (++l >= p.hiz.z) return false;\n"
    "    }\n"
    "    uint2 top = uint2(max(1u, (p.hiz.x / 2u) >> l), max(1u, (p.hiz.y / 2u) >> l)) - 1u;\n"
    "    uint2 t0 = min(a >> (l + 1u), top), t1 = min(b >> (l + 1u), top);\n"
    "    float m = max(max(hiz.read(t0, l).x, hiz.read(uint2(t1.x, t0.y), l).x),\n"
    "                  max(hiz.read(uint2(t0.x, t1.y), l).x, hiz.read(t1, l).x));\n"
    "    return zmin > m;\n"
    "}\n"
    "kernel void mcm_cull(device const Draw *draws [[buffer(0)]], constant Params &p [[buffer(1)]],\n"
    "                     device Args *args [[buffer(2)]], device atomic_uint *stats [[buffer(3)]],\n"
    "                     texture2d<float, access::read> hiz [[texture(0)]], uint i [[thread_position_in_grid]]) {\n"
    "    if (i >= p.n) return;\n"
    "    uint k = p.first + i;\n"
    "    Draw d = draws[k];\n"
    "    bool keep = d.count > 0;\n"
    "    for (int j = 0; j < 6; j++) {\n"
    "        float4 q = p.planes[j];\n"
    "        float3 c = float3(d.mn) + select(float3(0.0), float3(16.0), q.xyz > 0.0);\n"
    "        keep = keep && dot(q.xyz, c) + q.w >= 0.0;\n"
    "    }\n"
    "    if (keep && (p.flags & 8u)) {\n"
    "        atomic_fetch_add_explicit(&stats[0], 1u, memory_order_relaxed);\n"
    "        if (occluded(float3(d.mn), p, hiz)) {\n"
    "            keep = false;\n"
    "            atomic_fetch_add_explicit(&stats[1], 1u, memory_order_relaxed);\n"
    "        }\n"
    "    }\n"
    "    args[k] = Args{d.count, keep ? 1u : 0u, d.first_index, int(d.base_vertex), 0u};\n"
    "}\n"
    /* the Hi-Z pyramid: level 0 is half the depth image, each texel the farthest depth of the 2x2 (3 wide at an odd
       edge) below it; every level after halves again */
    "static uint2 hiz_span(uint g, uint dn, uint sn) { return uint2(2u * g, g + 1u == dn ? sn - 1u : 2u * g + 1u); }\n"
    "kernel void mcm_hiz0(depth2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],\n"
    "                     uint2 g [[thread_position_in_grid]]) {\n"
    "    uint dw = dst.get_width(), dh = dst.get_height();\n"
    "    if (g.x >= dw || g.y >= dh) return;\n"
    "    uint2 xs = hiz_span(g.x, dw, src.get_width()), ys = hiz_span(g.y, dh, src.get_height());\n"
    "    float m = 0.0;\n"
    "    for (uint y = ys.x; y <= ys.y; y++) for (uint x = xs.x; x <= xs.y; x++) m = max(m, src.read(uint2(x, y)));\n"
    "    dst.write(float4(m), g);\n"
    "}\n"
    "kernel void mcm_hizn(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],\n"
    "                     uint2 g [[thread_position_in_grid]]) {\n"
    "    uint dw = dst.get_width(), dh = dst.get_height();\n"
    "    if (g.x >= dw || g.y >= dh) return;\n"
    "    uint2 xs = hiz_span(g.x, dw, src.get_width()), ys = hiz_span(g.y, dh, src.get_height());\n"
    "    float m = 0.0;\n"
    "    for (uint y = ys.x; y <= ys.y; y++) for (uint x = xs.x; x <= xs.y; x++) m = max(m, src.read(uint2(x, y)).x);\n"
    "    dst.write(float4(m), g);\n"
    "}\n";

#define CULL_SLOTS 4          /* frames in flight that may each hold arguments */
#define CULL_MAX_CMDS 65536   /* section draws per frame, all terrain passes together */
#define CULL_SLOT_SHIFT 17    /* the slot rides above the draw index in what mglb_cull_run returns */
typedef struct { uint32_t first, n, region_base, flags; } cull_params_tail;
#define CULL_OCCLUDE 8u       /* params flag: test against the Hi-Z pyramid too */
static struct cull_slot {
    id<MTLBuffer> draws, args;
    id<MTLBuffer> stats;      /* occlusion: boxes tested, boxes hidden (shared, read once the slot comes round) */
    int used;                 /* draws handed out this frame */
    uint64_t serial;          /* last command buffer that draws from its arguments */
    unsigned long long frame;
} cslot[CULL_SLOTS];
static int cull_state = -1, cull_cur = -1;
static id<MTLComputePipelineState> cull_pso, hiz0_pso, hizn_pso;

/* GPU occlusion culling (MCMETAL_GPU_OCCLUSION): after the main view's opaque terrain, its depth is reduced into a
   pyramid of farthest depths; the next frame's main-view culls skip sections whose box lies behind it. A section
   that comes into view from behind a wall can appear one frame late. */
static struct {
    id<MTLTexture> tex;              /* R32Float, levels of half, quarter, ... the depth image */
    id<MTLTexture> view[16];
    int levels, w, h;                /* w, h: the depth image's size */
    float mvp[16];                   /* the pass it was taken from */
    double cam[3];
    unsigned long long frame;        /* frames_presented when built */
    int valid;
    mgl_cull_pass pending;           /* the pass hiz_src belongs to */
    id<MTLTexture> dummy;            /* bound when there is no pyramid */
    unsigned long built, missed, used, skipped, tested, hidden;
} hiz;

static int cull_setup(void);
int mglb_cull_supported(void)
{
    /* the game may ask from more than one thread: set up exactly once */
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cull_state = cull_setup(); });
    return cull_state;
}

static int cull_setup(void)
{
    init_device();
    /* Apple's paravirtual GPU (GitHub's Macs) mishandles large base vertices (see apply_base_vertex), which the
       arguments rely on: MGL_GPU_CULL_FORCE=1 runs it there anyway (call counts, crashes, no picture checks) */
    if (strstr(dev.name.UTF8String, "aravirtual") && !opt("MGL_GPU_CULL_FORCE")) {
        mgl_log("GPU chunk culling: off on %s (base vertices; MGL_GPU_CULL_FORCE=1 to try)", dev.name.UTF8String);
        return 0;
    }
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:cull_msl] options:nil error:&e];
    id<MTLFunction> fn = [lib newFunctionWithName:@"mcm_cull"];
    cull_pso = fn ? [dev newComputePipelineStateWithFunction:fn error:&e] : nil;
    if (!cull_pso) {
        mgl_log("GPU chunk culling: kernel failed: %s", e ? e.localizedDescription.UTF8String : "no function");
        return 0;
    }
    id<MTLFunction> f0 = [lib newFunctionWithName:@"mcm_hiz0"], fn2 = [lib newFunctionWithName:@"mcm_hizn"];
    hiz0_pso = f0 ? [dev newComputePipelineStateWithFunction:f0 error:&e] : nil;
    hizn_pso = fn2 ? [dev newComputePipelineStateWithFunction:fn2 error:&e] : nil;
    if (!hiz0_pso || !hizn_pso)
        mgl_log("GPU occlusion culling: Hi-Z kernels failed: %s", e ? e.localizedDescription.UTF8String : "no function");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                   width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    hiz.dummy = [dev newTextureWithDescriptor:td];
    for (int i = 0; i < CULL_SLOTS; i++) {
        struct cull_slot *c = &cslot[i];
        c->draws = [dev newBufferWithLength:CULL_MAX_CMDS * sizeof(mgl_cull_draw) options:MTLResourceStorageModeShared];
        c->args = [dev newBufferWithLength:CULL_MAX_CMDS * sizeof(MTLDrawIndexedPrimitivesIndirectArguments)
                                   options:MTLResourceStorageModePrivate];
        c->stats = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        if (!c->draws || !c->args || !c->stats || !hiz.dummy) {
            mgl_log("GPU chunk culling: out of memory for the draw arguments");
            return 0;
        }
        c->frame = ~0ull;
    }
    mgl_log("GPU chunk culling: kernel ready on %s", dev.name.UTF8String);
    return 1;
}

int mglb_cull_run(const mgl_cull_pass *p, const mgl_cull_draw *draws, int n, mglb_buffer *const *ibufs, int nregions)
{
    (void)ibufs, (void)nregions; /* each region's own draw binds its index buffer */
    if (mglb_cull_supported() <= 0 || n <= 0)
        return -1;
    if (cull_cur < 0 || cslot[cull_cur].frame != frames_presented) { /* first terrain pass of a frame: next slot */
        int next = (cull_cur + 1) % CULL_SLOTS;
        if (cslot[next].serial > atomic_load(&completed_serial))
            return -1; /* the GPU may still be drawing from that slot: draw normally this frame */
        cull_cur = next;
        cslot[next].frame = frames_presented;
        cslot[next].used = 0;
        uint32_t *st = (uint32_t *)cslot[next].stats.contents; /* that frame's occlusion counts, done by now */
        hiz.tested += st[0];
        hiz.hidden += st[1];
        st[0] = st[1] = 0;
        if (hiz.tested && frames_presented % 1000 == 0) {
            mgl_log("GPU occlusion culling: last 1000 frames: %lu pyramids built, %lu missed (translucent terrain "
                    "drew first), %lu main-view culls used one, %lu could not (stale, camera jumped); hid %lu of "
                    "%lu sections in view", hiz.built, hiz.missed, hiz.used, hiz.skipped, hiz.hidden, hiz.tested);
            hiz.built = hiz.missed = hiz.used = hiz.skipped = hiz.tested = hiz.hidden = 0;
        }
    }
    struct cull_slot *c = &cslot[cull_cur];
    if (c->used + n > CULL_MAX_CMDS)
        return -1;
    memcpy((mgl_cull_draw *)c->draws.contents + c->used, draws, sizeof *draws * (size_t)n);
    struct { float planes[6][4]; cull_params_tail t; float prev[16]; float delta[4]; uint32_t hiz[4]; } params;
    memset(&params, 0, sizeof params);
    memcpy(params.planes, p->planes, sizeof params.planes);
    params.t = (cull_params_tail){(uint32_t)c->used, (uint32_t)n, 0, (uint32_t)p->flags};
    if ((p->flags & MGL_CULL_OCCLUSION) && !(p->flags & MGL_CULL_SHADOW)) {
        double d[3] = {p->cam[0] - hiz.cam[0], p->cam[1] - hiz.cam[1], p->cam[2] - hiz.cam[2]};
        /* last frame's pyramid only, and not across a teleport or a respawn */
        if (hiz.valid && hiz.frame + 1 == frames_presented && fabs(d[0]) < 8 && fabs(d[1]) < 8 && fabs(d[2]) < 8) {
            params.t.flags |= CULL_OCCLUDE;
            memcpy(params.prev, hiz.mvp, sizeof params.prev);
            for (int i = 0; i < 3; i++)
                params.delta[i] = (float)d[i];
            params.hiz[0] = (uint32_t)hiz.w, params.hiz[1] = (uint32_t)hiz.h, params.hiz[2] = (uint32_t)hiz.levels;
            hiz.used++;
        } else {
            hiz.skipped++;
        }
    }
    /* its own command buffer, committed now: it runs before the frame's draws (committed later), so it never
       splits the render pass the terrain is drawn into. In a pool: the render thread has none of its own, so the
       autoreleased command buffer and encoder (one per terrain pass) were never freed. */
    @autoreleasepool {
        id<MTLCommandBuffer> side = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [side computeCommandEncoder];
        [enc setComputePipelineState:cull_pso];
        [enc setBuffer:c->draws offset:0 atIndex:0];
        [enc setBytes:&params length:sizeof params atIndex:1];
        [enc setBuffer:c->args offset:0 atIndex:2];
        [enc setBuffer:c->stats offset:0 atIndex:3];
        [enc setTexture:(params.t.flags & CULL_OCCLUDE) ? hiz.tex : hiz.dummy atIndex:0];
        NSUInteger tg = cull_pso.threadExecutionWidth;
        [enc dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        [enc endEncoding];
        [side commit];
    }
    int first = c->used | (cull_cur << CULL_SLOT_SHIFT);
    c->used += n;
    return first;
}

void mglb_cull_mark(int op, const mgl_cull_pass *p)
{
    if (!(p->flags & MGL_CULL_OCCLUSION) || (p->flags & MGL_CULL_SHADOW) || !hiz0_pso || !hizn_pso)
        return;
    if (op == 1 && (p->flags & MGL_CULL_TRANSLUCENT)) {
        /* water and glass write depth too, and would hide what is under them: too late for this frame's pyramid */
        if (hiz_src)
            hiz.missed++;
        hiz_src = NULL;
    } else if (op == 2 && !(p->flags & MGL_CULL_TRANSLUCENT)) {
        /* the opaque terrain is in this pass's depth now; reduce it when the pass ends (ending it here would split
           the render pass) */
        mglb_texture *t = renc ? renc_target.depth : NULL;
        if (t && renc_target.depth_level == 0 && t->d.type == MGLT_2D) {
            hiz_src = t;
            hiz.pending = *p;
        }
    }
}

static void hiz_build(void)
{
    mglb_texture *src = hiz_src;
    hiz_src = NULL;
    id<MTLTexture> d = OBJ(id<MTLTexture>, src->mtl);
    int w = (int)d.width, h = (int)d.height;
    if (w < 4 || h < 4)
        return;
    if (!hiz.tex || hiz.w != w || hiz.h != h) {
        int lw = w / 2, lh = h / 2, levels = 1;
        while ((lw >> levels) > 0 || (lh >> levels) > 0)
            levels++;
        if (levels > 16)
            levels = 16;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                       width:(NSUInteger)lw
                                                                                      height:(NSUInteger)lh
                                                                                   mipmapped:YES];
        td.mipmapLevelCount = (NSUInteger)levels;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModePrivate;
        hiz.tex = [dev newTextureWithDescriptor:td];
        hiz.valid = 0;
        if (!hiz.tex)
            return;
        for (int i = 0; i < levels; i++)
            hiz.view[i] = [hiz.tex newTextureViewWithPixelFormat:MTLPixelFormatR32Float
                                                     textureType:MTLTextureType2D
                                                          levels:NSMakeRange((NSUInteger)i, 1)
                                                          slices:NSMakeRange(0, 1)];
        hiz.w = w, hiz.h = h, hiz.levels = levels;
        mgl_log("GPU occlusion culling: Hi-Z pyramid %dx%d, %d levels", lw, lh, levels);
    }
    id<MTLComputeCommandEncoder> enc = [current_cb() computeCommandEncoder];
    for (int i = 0; i < hiz.levels; i++) {
        id<MTLTexture> out = hiz.view[i];
        [enc setComputePipelineState:i ? hizn_pso : hiz0_pso];
        [enc setTexture:i ? hiz.view[i - 1] : d atIndex:0];
        [enc setTexture:out atIndex:1];
        [enc dispatchThreads:MTLSizeMake(out.width, out.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    }
    [enc endEncoding];
    memcpy(hiz.mvp, hiz.pending.mvp, sizeof hiz.mvp);
    memcpy(hiz.cam, hiz.pending.cam, sizeof hiz.cam);
    hiz.frame = frames_presented;
    hiz.valid = 1;
    hiz.built++;
}

/* one multi-draw from its culled arguments: same sections, same order, culled ones draw no instances */
static void draw_culled(id<MTLRenderCommandEncoder> e, const mgl_draw *d, MTLPrimitiveType pt)
{
    int cmd = d->cull_cmd - 1;
    struct cull_slot *c = &cslot[cmd >> CULL_SLOT_SHIFT];
    NSUInteger first = (NSUInteger)(cmd & ((1 << CULL_SLOT_SHIFT) - 1));
    id<MTLBuffer> ib = draw_buf(d->index_buf);
    for (int i = 0; i < d->multi_n; i++)
        if (d->multi_count[i] > 0)
            [e drawIndexedPrimitives:pt indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0
                      indirectBuffer:c->args
                indirectBufferOffset:(first + (NSUInteger)i) * sizeof(MTLDrawIndexedPrimitivesIndirectArguments)];
    c->serial = cb_serial;
    use_buffer(d->index_buf);
}

/* Everything that decides an MTLRenderPipelineState, flattened so it can be compared byte-wise. */
typedef struct pipe_key {
    uint32_t program;
    uint32_t color[MGL_MAX_ATTACHMENTS];
    uint32_t depth, stencil;
    struct { uint16_t on, mask, eq_rgb, eq_a, src_rgb, dst_rgb, src_a, dst_a; } blend[MGL_MAX_ATTACHMENTS];
    struct { uint16_t format; uint8_t buffer, enabled; uint32_t offset; uint32_t scale; } attr[MGL_MAX_VERTEX_ATTRIBS];
    struct { uint32_t stride, divisor; uint8_t constant; } layout[MGL_MAX_VERTEX_BUFFERS];
    uint32_t probe; /* MGL_PROBE_PROGRAMS: solid magenta fragment stage */
} pipe_key;

static NSMutableDictionary<NSData *, id<MTLRenderPipelineState>> *pipelines;
static NSMutableDictionary<NSNumber *, id<MTLDepthStencilState>> *depth_states;
static NSMutableDictionary<NSData *, id<MTLSamplerState>> *samplers;

static uint16_t small_enum(int e) { return (uint16_t)e; } /* every blend enum fits in 16 bits */

/* MGL_PROBE_PROGRAMS=3,24: draw these GL programs solid magenta with no depth test, culling or blending, so a
   screenshot shows where their geometry really lands (debugging invisible draws). */
static int program_listed(const mgl_draw *d, const char *var, int *n, unsigned *ids)
{
    if (*n < 0) {
        *n = 0;
        const char *e = getenv(var);
        while (e && *e && *n < 32) {
            ids[(*n)++] = (unsigned)strtoul(e, (char **)&e, 10);
            while (*e == ',' || *e == ' ')
                e++;
        }
    }
    unsigned gl = 0;
    if (*n && d->program && sscanf(d->program->label, "GL program %u", &gl) == 1)
        for (int i = 0; i < *n; i++)
            if (ids[i] == gl)
                return 1;
    /* names also work: MGL_LOG_PROGRAMS=gbuffers_water matches "GL program 57 gbuffers_water" */
    static const char *vars[8], *vals[8]; /* getenv once per variable, not per draw */
    int vi = 0;
    while (vi < 8 && vars[vi] && vars[vi] != var)
        vi++;
    if (vi < 8 && !vars[vi]) {
        vars[vi] = var;
        vals[vi] = getenv(var);
    }
    const char *e = vi < 8 ? vals[vi] : NULL;
    if (e && d->program) {
        char want[128];
        while (*e) {
            size_t k = strcspn(e, ", ");
            if (k && k < sizeof want && !(*e >= '0' && *e <= '9')) {
                memcpy(want, e, k);
                want[k] = 0;
                const char *l = strchr(d->program->label + 11, ' ');
                if (l && !strcmp(l + 1, want))
                    return 1;
            }
            e += k;
            while (*e == ',' || *e == ' ')
                e++;
        }
    }
    return 0;
}

/* MGL_LOG_PROGRAMS=18: log these programs' draws like probes (vertices, uniforms, textures) without repainting */
static int log_program(const mgl_draw *d)
{
    static int n = -1;
    static unsigned ids[32];
    return program_listed(d, "MGL_LOG_PROGRAMS", &n, ids);
}

static int probe_program(const mgl_draw *d)
{
    static int n = -1;
    static unsigned ids[32];
    if (n < 0) {
        n = 0;
        const char *e = getenv("MGL_PROBE_PROGRAMS");
        while (e && *e && n < 32) {
            ids[n++] = (unsigned)strtoul(e, (char **)&e, 10);
            while (*e == ',' || *e == ' ')
                e++;
        }
    }
    unsigned gl = 0;
    if (n && d->program && sscanf(d->program->label, "GL program %u", &gl) == 1)
        for (int i = 0; i < n; i++)
            if (ids[i] == gl)
                return 1;
    return 0;
}

static id<MTLFunction> probe_fragment(void)
{
    static id<MTLFunction> fn;
    if (!fn) {
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
                                                        "fragment float4 probe_frag() { return float4(1.0, 0.0, 1.0, 1.0); }\n"
                                               options:nil error:&e];
        fn = [lib newFunctionWithName:@"probe_frag"];
        if (!fn)
            mgl_log("probe shader: %s", e.localizedDescription.UTF8String);
    }
    return fn;
}

/* Probe draws: log the first vertices exactly as the GPU will fetch them (indices, base vertex, raw bytes) and the
   vertex-stage uniforms, a few times per program, so their positions can be worked out by hand. */
static void log_probe_draw(const mgl_draw *d)
{
    static uint32_t seen[32];
    static int nseen[32], nprog;
    int k = 0;
    while (k < nprog && seen[k] != d->program->id)
        k++;
    if (k == nprog) {
        if (nprog == 32)
            return;
        seen[nprog++] = d->program->id;
    }
    if (nseen[k]++ >= 3)
        return;
    long count = d->multi_n > 0 ? d->multi_count[0] : d->count;
    size_t ioff = d->multi_n > 0 ? (size_t)d->multi_offset[0] : d->index_offset;
    long base = d->multi_n > 0 ? d->multi_base[0] : d->base_vertex;
    mgl_log("probe: %s multi %d count %ld index offset %zu base %ld index type 0x%x first %d; %d vbufs, %d instances, "
            "viewport %d %d %d %d, target %dx%d", d->program->label, d->multi_n, count, ioff, base, d->index_type,
            d->first, d->num_vbufs, d->instances, d->viewport[0], d->viewport[1], d->viewport[2], d->viewport[3],
            d->target.width, d->target.height);
    for (int b = 0; b < d->num_vbufs; b++)
        mgl_log("probe:   vbuf %d offset %zu stride %d, %zu bytes", b, d->vbufs[b].offset, d->vbufs[b].stride, d->vbufs[b].buf->size);
    for (int i = 0; i < MGL_MAX_VERTEX_ATTRIBS; i++)
        if (d->attrs[i].enabled)
            mgl_log("probe:   attr loc %d type %d x%d norm %d int %d buf %d offset %zu", d->attrs[i].location, d->attrs[i].type,
                    d->attrs[i].size, d->attrs[i].normalized, d->attrs[i].integer, d->attrs[i].buffer, d->attrs[i].offset);
    for (int v = 0; v < 3 && v < count; v++) {
        long idx = v;
        if (d->index_buf) {
            const unsigned char *ip = (const unsigned char *)d->index_buf->ptr + ioff;
            idx = d->index_type == GL_UNSIGNED_SHORT ? ((const uint16_t *)ip)[v] : (long)((const uint32_t *)ip)[v];
        } else
            idx = d->first + v;
        idx += base;
        const mgl_vertex_buf *vb = &d->vbufs[0];
        if (!vb->buf || vb->stride <= 0)
            break;
        const unsigned char *p = (const unsigned char *)vb->buf->ptr + vb->offset + (size_t)idx * (size_t)vb->stride;
        char hex[200];
        int n = 0;
        for (int j = 0; j < vb->stride && j < 48; j++)
            n += snprintf(hex + n, sizeof hex - (size_t)n, "%02x", p[j]);
        mgl_log("probe:   vertex %ld: %s", idx, hex);
    }
    for (int st = 0; st < 2; st++)
        for (int i = 0; i < d->num_textures[st] && i < MGL_MAX_TEXTURES; i++) {
            const mgl_bound_texture *bt = &d->textures[st][i];
            if (!bt->dim)
                continue;
            mgl_log("probe:   %s texture %d: %p %dx%d levels %d format %d; min 0x%x mag 0x%x wrap 0x%x/0x%x lod %g..%g bias %g%s",
                    st ? "fragment" : "vertex", i, (void *)bt->tex, bt->tex ? bt->tex->d.width : 0, bt->tex ? bt->tex->d.height : 0,
                    bt->tex ? bt->tex->d.levels : 0, bt->tex ? (int)bt->tex->d.format : -1, bt->sampler.min_filter,
                    bt->sampler.mag_filter, bt->sampler.wrap_s, bt->sampler.wrap_t, bt->sampler.min_lod, bt->sampler.max_lod,
                    bt->sampler.lod_bias, bt->swizzle[0] | bt->swizzle[3] ? " swizzled" : "");
        }
    if (d->uniforms[1] && d->uniform_size[1] > 0) {
        const unsigned char *u = d->uniforms[1];
        char hex[1100];
        int n = 0;
        for (int j = 0; j < d->uniform_size[1] && j < 512; j++)
            n += snprintf(hex + n, sizeof hex - (size_t)n, "%02x", u[j]);
        mgl_log("probe:   fragment uniforms %d bytes: %s", d->uniform_size[1], hex);
    }
    if (d->uniforms[0]) {
        const unsigned char *u = d->uniforms[0];
        char hex[1100];
        int n = 0;
        for (int j = 0; j < d->uniform_size[0] && j < 512; j++)
            n += snprintf(hex + n, sizeof hex - (size_t)n, "%02x", u[j]);
        mgl_log("probe:   vertex uniforms %d bytes: %s", d->uniform_size[0], hex);
    }
}

static id<MTLRenderPipelineState> get_pipeline(const mgl_draw *d, const mgl_target *t)
{
    pipe_key k;
    memset(&k, 0, sizeof k);
    k.program = d->program->id;
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++) {
        if (!t->tex[i])
            continue;
        k.color[i] = (uint32_t)t->tex[i]->pf;
        const mgl_blend *b = &d->blend[i];
        int blendable = !is_int_format(t->tex[i]->pf);
        k.blend[i].on = (uint16_t)(b->enabled && blendable);
        k.blend[i].mask = b->color_mask;
        if (k.blend[i].on) {
            k.blend[i].eq_rgb = small_enum(b->eq_rgb);
            k.blend[i].eq_a = small_enum(b->eq_a);
            k.blend[i].src_rgb = small_enum(b->src_rgb);
            k.blend[i].dst_rgb = small_enum(b->dst_rgb);
            k.blend[i].src_a = small_enum(b->src_a);
            k.blend[i].dst_a = small_enum(b->dst_a);
        }
    }
    if (t->depth) {
        k.depth = (uint32_t)t->depth->pf;
        if (t->depth->pf == MTLPixelFormatDepth32Float_Stencil8)
            k.stencil = (uint32_t)t->depth->pf;
    }
    for (int i = 0; i < MGL_MAX_VERTEX_ATTRIBS; i++)
        if (d->attrs[i].enabled) {
            k.attr[i].enabled = 1;
            k.attr[i].format = (uint16_t)vertex_format(&d->attrs[i]);
            k.attr[i].buffer = (uint8_t)d->attrs[i].buffer;
            k.attr[i].offset = (uint32_t)d->attrs[i].offset;
            k.attr[i].scale = d->program->vlib ? (uint32_t)vertex_scale(&d->attrs[i]) : 0;
        }
    for (int i = 0; i < d->num_vbufs; i++) {
        k.layout[i].stride = (uint32_t)d->vbufs[i].stride;
        k.layout[i].constant = d->vbufs[i].stride == 0;
        k.layout[i].divisor = (uint32_t)d->vbufs[i].divisor;
    }
    k.probe = (uint32_t)probe_program(d);
    /* consecutive draws usually share a pipeline: skip the dictionary (and its NSData key) for repeats */
    static pipe_key last_key;
    static id<MTLRenderPipelineState> last_ps;
    if (last_ps && !memcmp(&k, &last_key, sizeof k))
        return last_ps;
    prof.pipe_lookups++;
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    if (!pipelines)
        pipelines = [NSMutableDictionary dictionary];
    id ps_or_pending;
    @synchronized(pipelines) {
        ps_or_pending = pipelines[key];
    }
    if (ps_or_pending == (id)[NSNull null]) /* still building in the background (MGL_ASYNC_PIPELINES) */
        return nil;
    id<MTLRenderPipelineState> ps = ps_or_pending;
    if (ps) {
        last_key = k;
        last_ps = ps;
        return ps;
    }

    if (!d->program->vfn) { /* a compute-only program: GL_INVALID_OPERATION, not a Metal assertion */
        static int warned;
        if (!warned++)
            mgl_log("%s: draw with a program that has no vertex stage", d->program->label);
        return nil;
    }
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = OBJ(id<MTLFunction>, d->program->vfn);
    if (d->program->vlib) {
        NSMutableString *mask = [NSMutableString string];
        for (int i = 0; i < MGL_MAX_VERTEX_ATTRIBS; i++)
            if (k.attr[i].enabled && k.attr[i].scale)
                [mask appendFormat:@"%d:%u,", i, k.attr[i].scale];
        if (mask.length) {
            NSMutableDictionary *cache = OBJ(NSMutableDictionary *, d->program->vscaled);
            id<MTLFunction> fn;
            @synchronized(cache) {
                fn = cache[mask];
            }
            if (!fn) {
                MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
                for (int i = 0; i < MGL_MAX_VERTEX_ATTRIBS; i++)
                    if (k.attr[i].enabled && k.attr[i].scale) {
                        float sc = (float)k.attr[i].scale;
                        [cv setConstantValue:&sc type:MTLDataTypeFloat atIndex:MGL_VSCALE_FC + i];
                    }
                NSError *e = nil;
                fn = [OBJ(id<MTLLibrary>, d->program->vlib) newFunctionWithName:@"main0" constantValues:cv error:&e];
                if (!fn)
                    mgl_log("%s: scaled vertex inputs (%s) failed: %s", d->program->label, mask.UTF8String,
                            e.localizedDescription.UTF8String);
                else
                    @synchronized(cache) {
                        cache[mask] = fn;
                    }
            }
            if (fn)
                pd.vertexFunction = fn;
        }
    }
    pd.fragmentFunction = d->program->ffn ? OBJ(id<MTLFunction>, d->program->ffn) : nil;
    if (k.probe)
        pd.fragmentFunction = probe_fragment();
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++) {
        if (!k.color[i])
            continue;
        MTLRenderPipelineColorAttachmentDescriptor *c = pd.colorAttachments[i];
        c.pixelFormat = (MTLPixelFormat)k.color[i];
        const mgl_blend *b = &d->blend[i];
        c.writeMask = (b->color_mask & 1 ? MTLColorWriteMaskRed : 0) | (b->color_mask & 2 ? MTLColorWriteMaskGreen : 0) |
                      (b->color_mask & 4 ? MTLColorWriteMaskBlue : 0) | (b->color_mask & 8 ? MTLColorWriteMaskAlpha : 0);
        if (k.probe)
            c.writeMask = MTLColorWriteMaskAll;
        c.blendingEnabled = k.blend[i].on && !k.probe;
        if (k.blend[i].on) {
            c.sourceRGBBlendFactor = blend_factor(b->src_rgb);
            c.destinationRGBBlendFactor = blend_factor(b->dst_rgb);
            c.sourceAlphaBlendFactor = blend_factor(b->src_a);
            c.destinationAlphaBlendFactor = blend_factor(b->dst_a);
            c.rgbBlendOperation = blend_op(b->eq_rgb);
            c.alphaBlendOperation = blend_op(b->eq_a);
        }
    }
    pd.depthAttachmentPixelFormat = (MTLPixelFormat)k.depth;
    pd.stencilAttachmentPixelFormat = (MTLPixelFormat)k.stencil;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    for (int i = 0; i < MGL_MAX_VERTEX_ATTRIBS; i++)
        if (k.attr[i].enabled) {
            vd.attributes[i].format = (MTLVertexFormat)k.attr[i].format;
            vd.attributes[i].offset = k.attr[i].offset;
            vd.attributes[i].bufferIndex = MGL_BUF_VERTEX_BASE + k.attr[i].buffer;
        }
    for (int i = 0; i < d->num_vbufs; i++) {
        MTLVertexBufferLayoutDescriptor *l = vd.layouts[MGL_BUF_VERTEX_BASE + i];
        if (k.layout[i].constant) {
            /* one value for every vertex and instance: per-instance with a huge step rate always reads element 0.
               (MTLVertexStepFunctionConstant hung Apple's paravirtual GPU on the star field, CI run 3/4.) */
            l.stepFunction = MTLVertexStepFunctionPerInstance;
            l.stepRate = 0x7FFFFFFF;
            l.stride = 16;
        } else if (k.layout[i].divisor) {
            l.stepFunction = MTLVertexStepFunctionPerInstance;
            l.stepRate = k.layout[i].divisor;
            l.stride = k.layout[i].stride;
        } else {
            l.stepFunction = MTLVertexStepFunctionPerVertex;
            l.stride = k.layout[i].stride;
        }
    }
    pd.vertexDescriptor = vd;
    if (get_archive())
        pd.binaryArchives = @[ archive ];
    if (opt_async_pipes > 0) {
        @synchronized(pipelines) {
            pipelines[key] = (id)[NSNull null];
        }
        static _Atomic int building;
        int n = atomic_fetch_add(&building, 1) + 1;
        if (n % 64 == 0)
            mgl_log("%d pipelines building in the background", n);
        [dev newRenderPipelineStateWithDescriptor:pd
                                completionHandler:^(id<MTLRenderPipelineState> made, NSError *err) {
                                  atomic_fetch_sub(&building, 1);
                                  if (!made) {
                                      mgl_log("pipeline creation failed: %s", err.localizedDescription.UTF8String);
                                      return; /* stays pending: its draws are skipped, as a failed sync build would */
                                  }
                                  archive_add_render(pd);
                                  @synchronized(pipelines) {
                                      pipelines[key] = made;
                                  }
                                }];
        return nil; /* this draw is skipped; a later one finds the pipeline */
    }
    NSError *e = nil;
    ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) {
        mgl_log("pipeline creation failed: %s", e.localizedDescription.UTF8String);
        return nil;
    }
    archive_add_render(pd);
    @synchronized(pipelines) {
        pipelines[key] = ps;
    }
    last_key = k;
    last_ps = ps;
    return ps;
}

static id<MTLDepthStencilState> get_depth_state(int test, int write, int func)
{
    if (!depth_states)
        depth_states = [NSMutableDictionary dictionary];
    int ki = (test ? 1 : 0) | (write ? 2 : 0) | ((func & 0xF) << 2); /* GL_NEVER..GL_ALWAYS = 0x200..0x207 */
    static id<MTLDepthStencilState> fast[64];
    if (fast[ki])
        return fast[ki];
    NSNumber *key = @((test ? 1 : 0) | (write ? 2 : 0) | (func << 2));
    id<MTLDepthStencilState> s = depth_states[key];
    if (s) {
        fast[ki] = s;
        return s;
    }
    MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
    dd.depthCompareFunction = test ? compare_fn(func) : MTLCompareFunctionAlways;
    dd.depthWriteEnabled = write;
    s = [dev newDepthStencilStateWithDescriptor:dd];
    depth_states[key] = s;
    fast[ki] = s;
    return s;
}

static MTLSamplerAddressMode address_mode(int w)
{
    switch (w) {
    case GL_CLAMP_TO_EDGE: return MTLSamplerAddressModeClampToEdge;
    case GL_MIRRORED_REPEAT: return MTLSamplerAddressModeMirrorRepeat;
    case GL_CLAMP_TO_BORDER: return MTLSamplerAddressModeClampToBorderColor;
    case GL_MIRROR_CLAMP_TO_EDGE: return MTLSamplerAddressModeMirrorClampToEdge;
    }
    return MTLSamplerAddressModeRepeat;
}

static id<MTLSamplerState> get_sampler(const mgl_sampler_state *s, int force_compare)
{
    mgl_sampler_state k = *s;
    /* Metal only accepts a compare sampler with sample_compare, so follow the shader's type, not GL's compare mode */
    k.compare_mode = force_compare ? GL_COMPARE_REF_TO_TEXTURE : 0;
    if (k.compare_mode != GL_COMPARE_REF_TO_TEXTURE)
        k.compare_func = 0;
    /* small direct-mapped cache in front of the dictionary: every textured draw looks samplers up */
    static mgl_sampler_state fast_key[256];
    static __strong id<MTLSamplerState> fast_val[256];
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < sizeof k; i++)
        h = (h ^ ((const unsigned char *)&k)[i]) * 16777619u;
    h &= 255;
    if (fast_val[h] && !memcmp(&fast_key[h], &k, sizeof k))
        return fast_val[h];
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    if (!samplers)
        samplers = [NSMutableDictionary dictionary];
    id<MTLSamplerState> st = samplers[key];
    if (st) {
        fast_key[h] = k;
        fast_val[h] = st;
        return st;
    }
    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.magFilter = k.mag_filter == GL_NEAREST ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
    switch (k.min_filter) {
    case GL_NEAREST: sd.minFilter = MTLSamplerMinMagFilterNearest; sd.mipFilter = MTLSamplerMipFilterNotMipmapped; break;
    case GL_LINEAR: sd.minFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = MTLSamplerMipFilterNotMipmapped; break;
    case GL_NEAREST_MIPMAP_NEAREST: sd.minFilter = MTLSamplerMinMagFilterNearest; sd.mipFilter = MTLSamplerMipFilterNearest; break;
    case GL_LINEAR_MIPMAP_NEAREST: sd.minFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = MTLSamplerMipFilterNearest; break;
    case GL_NEAREST_MIPMAP_LINEAR: sd.minFilter = MTLSamplerMinMagFilterNearest; sd.mipFilter = MTLSamplerMipFilterLinear; break;
    default: sd.minFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = MTLSamplerMipFilterLinear; break;
    }
    sd.sAddressMode = address_mode(k.wrap_s);
    sd.tAddressMode = address_mode(k.wrap_t);
    sd.rAddressMode = address_mode(k.wrap_r);
    sd.lodMinClamp = k.min_lod < 0 ? 0 : k.min_lod;
    sd.lodMaxClamp = k.max_lod < sd.lodMinClamp ? sd.lodMinClamp : k.max_lod;
    sd.maxAnisotropy = (NSUInteger)(k.max_anisotropy < 1 ? 1 : k.max_anisotropy);
    if (k.compare_mode == GL_COMPARE_REF_TO_TEXTURE)
        sd.compareFunction = compare_fn(force_compare && !s->compare_func ? GL_LEQUAL : s->compare_func);
    st = [dev newSamplerStateWithDescriptor:sd];
    samplers[key] = st;
    fast_key[h] = k;
    fast_val[h] = st;
    return st;
}

/* 1x1 stand-ins for shader texture slots with nothing bound (Metal needs a texture of the right kind). */
static id<MTLTexture> dummy_texture(int dim, int sample_kind, int is_shadow)
{
    static id<MTLTexture> cache[4][3][2];
    int ti = dim == 3 ? 1 : dim == 12 ? 2 : dim == 6 ? 3 : 0;
    int sk = sample_kind < 0 || sample_kind > 2 ? 0 : sample_kind, sh = is_shadow ? 1 : 0;
    if (cache[ti][sk][sh])
        return cache[ti][sk][sh];
    MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
    td.textureType = ti == 1 ? MTLTextureType3D : ti == 2 ? MTLTextureType2DArray : ti == 3 ? MTLTextureTypeCube : MTLTextureType2D;
    td.pixelFormat = sh ? MTLPixelFormatDepth32Float
                     : sk == 1 ? MTLPixelFormatRGBA32Sint : sk == 2 ? MTLPixelFormatRGBA32Uint : MTLPixelFormatRGBA8Unorm;
    td.width = td.height = 1;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | (sh ? 0 : MTLTextureUsageShaderWrite);
    cache[ti][sk][sh] = [dev newTextureWithDescriptor:td];
    return cache[ti][sk][sh];
}

/* ================================================================ render passes, clears, draws */

static int same_target(const mgl_target *a, const mgl_target *b)
{
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++)
        if (a->tex[i] != b->tex[i] || (a->tex[i] && (a->level[i] != b->level[i] || a->layer[i] != b->layer[i])))
            return 0;
    return a->depth == b->depth && a->depth_level == b->depth_level && a->width == b->width && a->height == b->height;
}

static void set_attachment(MTLRenderPassAttachmentDescriptor *ad, mglb_texture *t, int level, int layer)
{
    ad.texture = OBJ(id<MTLTexture>, t->mtl);
    ad.level = (NSUInteger)level;
    if (t->d.type == MGLT_3D)
        ad.depthPlane = (NSUInteger)layer;
    else
        ad.slice = (NSUInteger)layer;
    ad.loadAction = MTLLoadActionLoad;
    ad.storeAction = MTLStoreActionStore;
}

static unsigned pass_dontcare; /* colour attachments the next begin_pass needn't load (see pass_for_draw) */

/* Open a render pass on t. clear_colors / clear_depth turn the matching load actions into clears. */
static id<MTLRenderCommandEncoder> begin_pass_at(int line, const mgl_target *t, unsigned clear_colors, const float *rgba,
                                                 int clear_depth, float depth);
#define begin_pass(...) begin_pass_at(__LINE__, __VA_ARGS__)
static id<MTLRenderCommandEncoder> begin_pass_at(int line, const mgl_target *t, unsigned clear_colors, const float *rgba,
                                                 int clear_depth, float depth)
{
    target_dirty(t);
    /* pending clears of this target's images become its load actions; other pending clears go first */
    unsigned take_colors = 0;
    float take_rgba[MGL_MAX_ATTACHMENTS][4];
    int take_depth = 0;
    float take_depth_value = 0;
    if (npclear) {
        pending_clear list[8];
        int n = npclear;
        memcpy(list, pclear, sizeof list);
        npclear = 0;
        for (int i = 0; i < n; i++) {
            pending_clear *r = &list[i];
            for (int a = 0; a < MGL_MAX_ATTACHMENTS; a++) {
                if (!(r->colors & (1u << a)))
                    continue;
                for (int j = 0; j < MGL_MAX_ATTACHMENTS; j++)
                    if (t->tex[j] == r->t.tex[a] && t->level[j] == r->t.level[a] && t->layer[j] == r->t.layer[a]) {
                        take_colors |= 1u << j;
                        memcpy(take_rgba[j], r->rgba, sizeof r->rgba);
                        r->colors &= ~(1u << a);
                        break;
                    }
            }
            if (r->depth && t->depth == r->t.depth && t->depth_level == r->t.depth_level) {
                take_depth = 1;
                take_depth_value = r->depth_value;
                r->depth = 0;
            }
        }
        for (int i = 0; i < n; i++)
            if (list[i].colors || list[i].depth)
                begin_pass_at(__LINE__, &list[i].t, list[i].colors, list[i].rgba, list[i].depth, list[i].depth_value);
    }
    if (t->width >= 2048 && t->width == t->height && flush_log_on()) {
        static line_tally big = {"square shadow-map passes opened"};
        tally_line(&big, line);
    }
    prof_serialize();
    end_encoders();
    @autoreleasepool {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++) {
            if (!t->tex[i])
                continue;
            set_attachment(rp.colorAttachments[i], t->tex[i], t->level[i], t->layer[i]);
            if (pass_dontcare & (1u << i))
                rp.colorAttachments[i].loadAction = MTLLoadActionDontCare;
            if (clear_colors & (1u << i)) {
                rp.colorAttachments[i].loadAction = MTLLoadActionClear;
                rp.colorAttachments[i].clearColor = MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
            } else if (take_colors & (1u << i)) {
                rp.colorAttachments[i].loadAction = MTLLoadActionClear;
                rp.colorAttachments[i].clearColor =
                    MTLClearColorMake(take_rgba[i][0], take_rgba[i][1], take_rgba[i][2], take_rgba[i][3]);
            }
        }
        if (t->depth) {
            set_attachment(rp.depthAttachment, t->depth, t->depth_level, 0);
            if (clear_depth || take_depth) {
                rp.depthAttachment.loadAction = MTLLoadActionClear;
                rp.depthAttachment.clearDepth = clear_depth ? depth : take_depth_value;
            }
            if (t->depth->pf == MTLPixelFormatDepth32Float_Stencil8) {
                set_attachment(rp.stencilAttachment, t->depth, t->depth_level, 0);
                if (clear_depth || take_depth)
                    rp.stencilAttachment.loadAction = MTLLoadActionClear;
            }
        }
        rp.renderTargetWidth = (NSUInteger)t->width;
        rp.renderTargetHeight = (NSUInteger)t->height;
        id<MTLCommandBuffer> c = current_cb();
        char name[40];
        snprintf(name, sizeof name, "pass %dx%d", t->width, t->height);
        int k = pt_pass(name);
        if (k >= 0) {
            rp.sampleBufferAttachments[0].sampleBuffer = pt_cur->sb;
            rp.sampleBufferAttachments[0].startOfVertexSampleIndex = (NSUInteger)k * 2;
            rp.sampleBufferAttachments[0].endOfVertexSampleIndex = MTLCounterDontSample;
            rp.sampleBufferAttachments[0].startOfFragmentSampleIndex = MTLCounterDontSample;
            rp.sampleBufferAttachments[0].endOfFragmentSampleIndex = (NSUInteger)k * 2 + 1;
        }
        renc = [c renderCommandEncoderWithDescriptor:rp];
    }
    rs_reset();
    prof.passes++;
    if (same_target(t, &prof_last_target) && !clear_colors && !clear_depth && !take_colors && !take_depth)
        prof.reopened++;
    prof_last_target = *t;
    renc_target = *t;
    return renc;
}

static id<MTLRenderCommandEncoder> pass_for(const mgl_target *t)
{
    gs_flush();
    target_dirty(t);
    if (renc && same_target(t, &renc_target))
        return renc;
    return begin_pass(t, 0, NULL, 0, 0);
}

/* MGL_SMART_LOAD=1 (off by default: a draw of six vertices need not cover the target, gl_smoke test 1 draws
   half the screen after a clear and loses the clear): a new pass whose first draw is a full-screen triangle or quad that overwrites a colour
   attachment (no blending, all channels written, no discard, no scissor) doesn't load that attachment's old
   contents from memory first. Shader packs' composite passes are made of these; on Apple GPUs each load reads
   the whole image into tile memory. */
static unsigned opt_smart_load = ~0u;
static id<MTLRenderCommandEncoder> pass_for_draw(const mgl_draw *d)
{
    gs_flush();
    const mgl_target *t = &d->target;
    target_dirty(t);
    if (renc && same_target(t, &renc_target))
        return renc;
    if (opt_smart_load == ~0u)
        opt_smart_load = opt("MGL_SMART_LOAD");
    unsigned overwrite = 0;
    if (opt_smart_load && d->instances <= 1 && d->count <= 6 && !d->multi_n && !d->program->discards &&
        (!d->depth_test || !t->depth) &&
        (d->primitive == GL_TRIANGLES || d->primitive == GL_TRIANGLE_STRIP) && d->viewport[0] <= 0 &&
        d->viewport[1] <= 0 && d->viewport[0] + d->viewport[2] >= t->width && d->viewport[1] + d->viewport[3] >= t->height &&
        (!d->scissor_enabled || (d->scissor[0] <= 0 && d->scissor[1] <= 0 && d->scissor[0] + d->scissor[2] >= t->width &&
                                 d->scissor[1] + d->scissor[3] >= t->height)))
        for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++)
            if (t->tex[i] && !d->blend[i].enabled && (d->blend[i].color_mask & 15) == 15)
                overwrite |= 1u << i;
    pass_dontcare = overwrite;
    id<MTLRenderCommandEncoder> e = begin_pass(t, 0, NULL, 0, 0);
    pass_dontcare = 0;
    prof.dontcare += (unsigned long)__builtin_popcount(overwrite);
    return e;
}

/* ---- built-in shaders: present, blit, partial clear ---- */
static const char *builtin_msl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VO { float4 pos [[position]]; float2 uv; };\n"
    /* fullscreen triangle over the viewport; rect = source uv at the viewport's top-left (xy) and bottom-right (zw) */
    "vertex VO quad_vs(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
    "  VO o; o.pos = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);\n"
    "  o.uv = mix(rect.xy, rect.zw, p); return o; }\n"
    "fragment float4 blit_fs(VO in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.sample(s, in.uv); }\n"
    "struct CO { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; float4 c2 [[color(2)]]; float4 c3 [[color(3)]];\n"
    "  float4 c4 [[color(4)]]; float4 c5 [[color(5)]]; float4 c6 [[color(6)]]; float4 c7 [[color(7)]]; };\n"
    "vertex float4 clear_vs(uint vid [[vertex_id]], constant float4 &v [[buffer(0)]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2); return float4(p.x * 2 - 1, 1 - p.y * 2, v.x, 1); }\n"
"fragment CO clear_fs(constant float4 &c [[buffer(0)]]) { CO o; o.c0 = o.c1 = o.c2 = o.c3 = o.c4 = o.c5 = o.c6 = o.c7 = c; return o; }\n"
    /* ray tracing: Sodium/Iris terrain vertices -> region-local float3 triangle list (see mgl_rt.c for the layout) */
    "struct RtInfo { uint vbase, stride, ioff, itype, count; int base_vertex; int ent_off; uint translucent;\n"
    "  int lmin, lmax; uint lcap; uint tw, th, aw, ah, split, flags; };\n"
    /* per triangle, 12 words, for mcm_trace (core/mgl_program.c reads the same layout):
         0-2 packed texture coordinates (Sodium's 15-bit u/v)   3 alpha cutoff index (0 = solid) | 0x100 translucent
         4-6 vertex colours RGBA8   7 face normal (octahedral snorm16x2)   8-10 light (block, sky bytes)
         11 Iris block id + 1 (0 = unknown)
       Iris's extended vertex format keeps no material bits, so its triangles all get the 0.1 alpha test; the
       atlas alpha map (rt_alpha_tiles) tells which of them always pass it (solid: built opaque, see RtSection).
       flags 1: write that data and the light candidates (a section's first build); 2: count solid / cutout
       triangles into cnt. split n: positions of solid triangles go to the first n, cutout ones to the next n,
       each collapsed to a point in the other list. */
    "kernel void rt_decode(device const uchar *vb [[buffer(0)]], device const uchar *ib [[buffer(1)]],\n"
    "    device packed_float3 *out [[buffer(2)]], constant RtInfo &n [[buffer(3)]], device uint *tri [[buffer(4)]],\n"
    "    device atomic_uint *lc [[buffer(5)]], device atomic_uint *cnt [[buffer(6)]],\n"
    "    device const uchar *tiles [[buffer(7)]], uint t [[thread_position_in_grid]]) {\n"
    "  if (t * 3 >= n.count) return;\n"
    "  float3 p[3]; uint r[12];\n"
    "  for (uint k = 0; k < 3; k++) {\n"
    "    uint i = t * 3 + k;\n"
    "    uint idx = n.itype == 2 ? uint(((device const ushort *)(ib + n.ioff))[i]) : ((device const uint *)(ib + n.ioff))[i];\n"
    "    device const uchar *v = vb + n.vbase + uint(int(idx) + n.base_vertex) * n.stride;\n"
    "    device const uint *w = (device const uint *)v;\n"
    "    uint hi = w[0], lo = w[1], sec = w[4] >> 24;\n"
    "    uint3 q = (((uint3(hi) >> uint3(0, 10, 20)) & 0x3FF) << 10) | ((uint3(lo) >> uint3(0, 10, 20)) & 0x3FF);\n"
    "    p[k] = float3(q) * (32.0 / 1048576.0) - 8.0 + 16.0 * float3((sec >> 5) & 7, sec & 3, (sec >> 2) & 7);\n"
    "    r[k] = w[3] & 0x7FFF7FFFu; r[4 + k] = w[2]; r[8 + k] = w[4] & 0xFFFFu;\n"
    "    if (k == 0) {\n"
    "      r[3] = (n.stride > 20 ? 1u : (w[4] >> 17) & 3u) | (n.translucent ? 0x100u : 0u);\n"
    "      r[11] = n.ent_off >= 0 ? (*(device const uint *)(v + n.ent_off)) >> 1 : 0u; }\n"
    "  }\n"
    /* solid: no cutoff, or the lowest alpha under the triangle's texture rectangle passes mcm_opaque_at's test */
    "  uint cut = r[3] & 0xFFu;\n"
    "  bool solid = false;\n"
    "  if (!n.translucent) {\n"
    "    solid = cut == 0u;\n"
    "    if (!solid && n.tw > 0u) {\n"
    "      float2 lo = float2(1e9), hi = float2(-1e9);\n"
    "      for (uint k = 0; k < 3; k++) {\n"
    "        float2 uv = float2(r[k] & 0x7FFFu, (r[k] >> 16) & 0x7FFFu) * (1.0 / 32768.0) * float2(n.aw, n.ah);\n"
    "        lo = min(lo, uv); hi = max(hi, uv); }\n"
    "      int2 t0 = int2(floor(lo + 0.01)) / 8, t1 = max(int2(ceil(hi - 0.01)) - 1, int2(0)) / 8;\n"
    "      t1 = max(t1, t0);\n"
    "      if (t1.x < int(n.tw) && t1.y < int(n.th) && t1.x - t0.x < 8 && t1.y - t0.y < 8) {\n"
    "        uint m = 255u, need = cut == 3u ? 255u : 26u;\n"
    "        for (int y = t0.y; y <= t1.y; y++) for (int x = t0.x; x <= t1.x; x++)\n"
    "          m = min(m, uint(tiles[uint(y) * n.tw + uint(x)]));\n"
    "        solid = m >= need; } } }\n"
    "  if (n.flags & 2u) atomic_fetch_add_explicit(&cnt[solid ? 0 : 1], 1u, memory_order_relaxed);\n"
    "  if (n.split > 0u) {\n"
    "    uint in = solid ? t : n.split + t, other = solid ? n.split + t : t;\n"
    "    for (uint k = 0; k < 3; k++) { out[in * 3 + k] = p[k]; out[other * 3 + k] = p[0]; }\n"
    "  } else {\n"
    "    for (uint k = 0; k < 3; k++) out[t * 3 + k] = p[k];\n"
    "  }\n"
    "  if (!(n.flags & 1u)) return;\n"
    "  float3 c = cross(p[1] - p[0], p[2] - p[0]);\n"
    "  float3 nn = length(c) > 0.0 ? c / (abs(c.x) + abs(c.y) + abs(c.z)) : float3(0, 1, 0);\n"
    "  float2 o = nn.z >= 0.0 ? nn.xy : (1.0 - abs(nn.yx)) * select(float2(-1.0), float2(1.0), nn.xy >= 0.0);\n"
    "  r[7] = pack_float_to_snorm2x16(o);\n"
    "  for (uint k = 0; k < 12; k++) tri[t * 12 + k] = r[k];\n"
    /* light candidates (MCMETAL_LIGHT_IDS): the block this face belongs to, a little inside it from the centroid
       (front faces wind counter-clockwise, so the face normal points out of the block) */
    "  int id = int(r[11]) - 1;\n"
    "  if (n.lcap > 0u && id >= n.lmin && id <= n.lmax) {\n"
    "    uint k = atomic_fetch_add_explicit(&lc[0], 1u, memory_order_relaxed);\n"
    "    if (k < n.lcap) {\n"
    "      float3 in = (p[0] + p[1] + p[2]) / 3.0 - (length(c) > 0.0 ? normalize(c) : float3(0)) * 0.01;\n"
    "      device uint *e = (device uint *)(lc + 4 + k * 4);\n"
    "      e[0] = as_type<uint>(in.x); e[1] = as_type<uint>(in.y); e[2] = as_type<uint>(in.z); e[3] = uint(id); } } }\n"
    /* lowest alpha per 8x8 atlas texels, as a byte (rt_decode's solid test) */
    "kernel void rt_alpha_tiles(texture2d<float, access::read> atlas [[texture(0)]], device uchar *out [[buffer(0)]],\n"
    "    constant uint2 &tiles [[buffer(1)]], uint2 t [[thread_position_in_grid]]) {\n"
    "  if (t.x >= tiles.x || t.y >= tiles.y) return;\n"
    "  uint w = atlas.get_width(), h = atlas.get_height();\n"
    "  float m = 1.0;\n"
    "  for (uint y = 0; y < 8; y++) for (uint x = 0; x < 8; x++) {\n"
    "    uint2 q = t * 8 + uint2(x, y);\n"
    "    if (q.x < w && q.y < h) m = min(m, atlas.read(q).a); }\n"
    "  out[t.y * tiles.x + t.x] = uchar(clamp(m, 0.0, 1.0) * 255.0 + 0.5);\n"
    "}\n"
    /* per section, per frame: light candidates -> one light per block (hash on the block position) */
    "struct RtLightSec { int3 off; float3 region; uint cap; };\n"
    "kernel void rt_lights(device const uint *lc [[buffer(0)]], constant RtLightSec &s [[buffer(1)]],\n"
    "    device atomic_uint *hash [[buffer(2)]], device atomic_uint *lights [[buffer(3)]], uint t [[thread_position_in_grid]]) {\n"
    "  if (t >= min(lc[0], s.cap)) return;\n"
    "  device const uint *e = lc + 4 + t * 4;\n"
    "  float3 in = float3(as_type<float>(e[0]), as_type<float>(e[1]), as_type<float>(e[2]));\n"
    "  int3 b = int3(floor(in)) + s.off + 512;\n"
    "  if (any(b < 0) || any(b > 1023)) return;\n"
    /* only lights that can reach the camera's grid (32 blocks each way) within 16 blocks, as rt_light_grid
       tests: far lava and fire used to fill the 2048 slots before the lights next to the camera got one */
    "  float3 lp = floor(in) + 0.5 + s.region;\n"
    "  if (distance(lp, clamp(lp, -32.0, 32.0)) > 16.0) return;\n"
    "  uint key = uint(b.x) | uint(b.y) << 10 | uint(b.z) << 20 | 0x40000000u;\n"
    "  uint h = (key * 2654435761u) >> 19;\n"
    "  for (int probe = 0; probe < 64; ) {\n"
    "    uint expected = 0u;\n"
    "    if (atomic_compare_exchange_weak_explicit(&hash[h], &expected, key, memory_order_relaxed, memory_order_relaxed)) {\n"
    "      uint i = atomic_fetch_add_explicit(&lights[0], 1u, memory_order_relaxed);\n"
    "      if (i < 2048u) {\n"
    "        device float4 *l = (device float4 *)(lights + 4) + i;\n"
    "        *l = float4(floor(in) + 0.5 + s.region, float(e[3])); }\n"
    "      return; }\n"
    "    if (expected == key) return;\n"
    "    if (expected != 0u) { h = (h + 1u) & 8191u; probe++; } }\n"
    "}\n"
    /* per light: add it to every 4-block cell of the 16^3 grid (centred on the camera) it can reach within 16 blocks */
    "kernel void rt_light_grid(device atomic_uint *lights [[buffer(0)]], uint t [[thread_position_in_grid]]) {\n"
    "  if (t >= min(atomic_load_explicit(&lights[0], memory_order_relaxed), 2048u)) return;\n"
    "  float3 p = ((device const float4 *)(lights + 4))[t].xyz;\n"
    "  device atomic_uint *cells = lights + 4 + 2048 * 4;\n"
    "  int3 c0 = max(int3(floor((p - 16.0 + 32.0) / 4.0)), 0), c1 = min(int3(floor((p + 16.0 + 32.0) / 4.0)), 15);\n"
    "  for (int z = c0.z; z <= c1.z; z++) for (int y = c0.y; y <= c1.y; y++) for (int x = c0.x; x <= c1.x; x++) {\n"
    "    float3 lo = float3(x, y, z) * 4.0 - 32.0, q = clamp(p, lo, lo + 4.0);\n"
    "    if (distance(p, q) > 16.0) continue;\n"
    "    device atomic_uint *cell = cells + ((z * 16 + y) * 16 + x) * 17;\n"
    "    uint k = atomic_fetch_add_explicit(cell, 1u, memory_order_relaxed);\n"
    "    if (k < 16u) atomic_store_explicit(cell + 1 + k, t, memory_order_relaxed); }\n"
    "}\n";

static id<MTLLibrary> builtins;

static id<MTLFunction> builtin(NSString *name)
{
    if (!builtins) {
        NSError *e = nil;
        builtins = [dev newLibraryWithSource:[NSString stringWithUTF8String:builtin_msl] options:nil error:&e];
        if (!builtins)
            mgl_log("built-in shaders failed: %s", e.localizedDescription.UTF8String);
    }
    return [builtins newFunctionWithName:name];
}

static id<MTLRenderPipelineState> blit_pipeline(MTLPixelFormat fmt)
{
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *cache;
    if (!cache)
        cache = [NSMutableDictionary dictionary];
    id<MTLRenderPipelineState> ps = cache[@(fmt)];
    if (ps)
        return ps;
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = builtin(@"quad_vs");
    pd.fragmentFunction = builtin(@"blit_fs");
    pd.colorAttachments[0].pixelFormat = fmt;
    NSError *e = nil;
    ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps)
        mgl_log("blit pipeline: %s", e.localizedDescription.UTF8String);
    else
        cache[@(fmt)] = ps;
    return ps;
}

static id<MTLSamplerState> blit_sampler(int linear)
{
    mgl_sampler_state s;
    mgl_sampler_defaults(&s);
    s.min_filter = s.mag_filter = linear ? GL_LINEAR : GL_NEAREST;
    s.wrap_s = s.wrap_t = GL_CLAMP_TO_EDGE;
    return get_sampler(&s, 0);
}

static int is_sint_format(MTLPixelFormat pf)
{
    return pf == MTLPixelFormatR32Sint || pf == MTLPixelFormatRGBA16Sint || pf == MTLPixelFormatRGBA32Sint;
}

/* Fragment function for quad clears. Its outputs must match each attachment's type (float / uint / int), so
   targets with integer attachments get a generated variant, cached by type signature. */
static id<MTLFunction> clear_fragment(const mgl_target *t)
{
    char sig[MGL_MAX_ATTACHMENTS + 1] = {0};
    int any_int = 0;
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++) {
        MTLPixelFormat pf = t->tex[i] ? t->tex[i]->pf : MTLPixelFormatInvalid;
        sig[i] = !t->tex[i] ? 'n' : is_sint_format(pf) ? 'i' : is_int_format(pf) ? 'u' : 'f';
        any_int |= sig[i] == 'i' || sig[i] == 'u';
    }
    if (!any_int)
        return builtin(@"clear_fs");
    static NSMutableDictionary<NSString *, id<MTLFunction>> *cache;
    if (!cache)
        cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:sig];
    id<MTLFunction> f = cache[key];
    if (f)
        return f;
    NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nstruct CO {\n"];
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++)
        if (sig[i] != 'n')
            [src appendFormat:@"  %s c%d [[color(%d)]];\n", sig[i] == 'i' ? "int4" : sig[i] == 'u' ? "uint4" : "float4", i, i];
    [src appendString:@"};\nfragment CO clear_fs(constant float4 &c [[buffer(0)]]) {\n  CO o;\n"];
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++)
        if (sig[i] != 'n')
            [src appendFormat:@"  o.c%d = %s(c);\n", i, sig[i] == 'i' ? "int4" : sig[i] == 'u' ? "uint4" : "float4"];
    [src appendString:@"  return o;\n}\n"];
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    f = lib ? [lib newFunctionWithName:@"clear_fs"] : nil;
    if (!f) {
        mgl_log("integer clear shader: %s", e.localizedDescription.UTF8String);
        return builtin(@"clear_fs");
    }
    cache[key] = f;
    return f;
}

static void fg_snapshot(const mgl_target *t);
static int fg_enabled(void);
static int tu_enabled(void);
/* frame dump: every colour target of a pass as "slot:texture/format", plus which slots blend */
static const char *dump_targets(const mgl_target *t, const mgl_blend *blend)
{
    static char buf[512];
    int n = 0;
    buf[0] = 0;
    for (int i = 0; i < MGL_MAX_ATTACHMENTS && n < (int)sizeof buf - 48; i++)
        if (t->tex[i])
            n += snprintf(buf + n, sizeof buf - (size_t)n, " %d:%p/%d%s", i, (void *)t->tex[i], (int)t->tex[i]->pf,
                          blend && blend[i].enabled ? "b" : "");
    return buf;
}

/* frame dump: the textures a draw's fragment stage samples */
static const char *dump_textures(const mgl_draw *d)
{
    static char buf[512];
    int n = 0;
    buf[0] = 0;
    for (int i = 0; i < d->num_textures[1] && n < (int)sizeof buf - 32; i++)
        if (d->textures[1][i].tex)
            n += snprintf(buf + n, sizeof buf - (size_t)n, " %d:%p", i, (void *)d->textures[1][i].tex);
    return buf;
}

/* frame dump: the centre texel (and one 20% above it) of each texture a full-screen draw samples, read back from
   the GPU (finishes all work so far; debug only) */
static void dump_texels(const mgl_draw *d)
{
    for (int i = 0; i < d->num_textures[1]; i++) {
        mglb_texture *t = d->textures[1][i].tex;
        if (!t || t->d.type != MGLT_2D || is_depth_format(t->pf))
            continue;
        for (int k = 0; k < 2; k++) {
            int x = t->d.width / 2, y = k ? t->d.height * 7 / 10 : t->d.height / 2;
            unsigned char px[16] = {0};
            float v[4] = {0};
            int n = 4;
            mglb_texture_read(t, 0, x, y, 1, 1, px);
            switch (t->pf) {
            case MTLPixelFormatRGBA16Unorm:
                for (int c = 0; c < 4; c++) v[c] = ((uint16_t *)px)[c] / 65535.0f;
                break;
            case MTLPixelFormatRGBA16Float:
                for (int c = 0; c < 4; c++) v[c] = (float)((_Float16 *)px)[c];
                break;
            case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatBGRA8Unorm:
                for (int c = 0; c < 4; c++) v[c] = px[c] / 255.0f;
                break;
            case MTLPixelFormatRGBA32Float:
                memcpy(v, px, 16);
                break;
            default:
                n = 0;
            }
            if (n)
                mgl_log("frame dump:   texel %d:%p at %d,%d = %.5f %.5f %.5f %.5f", i, (void *)t, x, y, v[0], v[1], v[2], v[3]);
            else
                mgl_log("frame dump:   texel %d:%p format %d not decoded", i, (void *)t, (int)t->pf);
        }
    }
}

void mglb_clear(const mgl_target *t, unsigned mask_color, const float rgba[4], int clear_depth, float depth,
                const int *scissor, uint8_t cmask)
{
    /* Minecraft clears only the depth of its main target right before drawing the HUD: keep the finished world
       picture and its depth for frame interpolation */
    if (clear_depth && !mask_color && !scissor && !t->is_default && t->tex[0] && t->depth && (fg_enabled() || tu_enabled()))
        fg_snapshot(t);
    if (dump_this_frame())
        mgl_log("frame dump: clear target%s%s depth %p, colour mask 0x%x (write 0x%x) to %g %g %g %g, depth %d (%g), scissor %d",
                dump_targets(t, NULL), t->is_default ? " (window)" : "", (void *)t->depth, mask_color, cmask,
                rgba ? rgba[0] : 0, rgba ? rgba[1] : 0, rgba ? rgba[2] : 0, rgba ? rgba[3] : 0, clear_depth, depth, scissor != NULL);
    int partial = (scissor && (scissor[0] > 0 || scissor[1] > 0 || scissor[0] + scissor[2] < t->width ||
                               scissor[1] + scissor[3] < t->height)) ||
                  (mask_color && cmask != 0xf);
    if (!partial) {
        static int defer = -1;
        if (defer < 0)
            defer = !getenv("MGL_DEFER_CLEAR") || atoi(getenv("MGL_DEFER_CLEAR")) != 0;
        if (!defer || t->is_default || (!mask_color && !clear_depth)) {
            begin_pass(t, mask_color, rgba, clear_depth, depth);
            return;
        }
        gs_flush(); /* draws issued before the clear keep their place */
        keep_clears = 1;
        end_encoders();
        keep_clears = 0;
        /* images still holding exactly this clear (and no other clear pending) need nothing */
        for (int j = 0; j < MGL_MAX_ATTACHMENTS; j++) {
            mglb_texture *x = t->tex[j];
            if ((mask_color & (1u << j)) && x && x->clean && t->level[j] == 0 && !pending_clear_clears(x) &&
                !memcmp(x->cval, rgba, sizeof x->cval))
                mask_color &= ~(1u << j);
        }
        if (clear_depth && t->depth && t->depth->clean && t->depth_level == 0 && !pending_clear_clears(t->depth) &&
            t->depth->cval[0] == depth)
            clear_depth = 0;
        if (!mask_color && !(clear_depth && t->depth)) {
            if (flush_log_on()) {
                static line_tally skipped = {"clears skipped (images still clear)"};
                tally_line(&skipped, __LINE__);
            }
            return;
        }
        /* a later clear of the same image wins */
        for (int i = 0; i < npclear; i++) {
            for (int a = 0; a < MGL_MAX_ATTACHMENTS; a++)
                for (int j = 0; j < MGL_MAX_ATTACHMENTS; j++)
                    if ((mask_color & (1u << j)) && (pclear[i].colors & (1u << a)) && pclear[i].t.tex[a] == t->tex[j] &&
                        pclear[i].t.level[a] == t->level[j] && pclear[i].t.layer[a] == t->layer[j])
                        pclear[i].colors &= ~(1u << a);
            if (clear_depth && pclear[i].t.depth == t->depth && pclear[i].t.depth_level == t->depth_level)
                pclear[i].depth = 0;
        }
        if (npclear == 8)
            materialize_clears();
        pending_clear *r = &pclear[npclear++];
        r->t = *t;
        r->colors = mask_color;
        memcpy(r->rgba, rgba, sizeof r->rgba);
        r->depth = clear_depth && t->depth;
        r->depth_value = depth;
        return;
    }
    /* scissored or masked clear: draw a quad */
    id<MTLRenderCommandEncoder> e = pass_for(t);
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = builtin(@"clear_vs");
    pd.fragmentFunction = clear_fragment(t);
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++) {
        if (!t->tex[i])
            continue;
        pd.colorAttachments[i].pixelFormat = t->tex[i]->pf;
        int on = (mask_color >> i) & 1;
        pd.colorAttachments[i].writeMask = on ? ((cmask & 1 ? MTLColorWriteMaskRed : 0) | (cmask & 2 ? MTLColorWriteMaskGreen : 0) |
                                                 (cmask & 4 ? MTLColorWriteMaskBlue : 0) | (cmask & 8 ? MTLColorWriteMaskAlpha : 0))
                                              : MTLColorWriteMaskNone;
    }
    if (t->depth) {
        pd.depthAttachmentPixelFormat = t->depth->pf;
        if (t->depth->pf == MTLPixelFormatDepth32Float_Stencil8)
            pd.stencilAttachmentPixelFormat = t->depth->pf;
    }
    static NSMutableDictionary<NSData *, id<MTLRenderPipelineState>> *clear_pipes;
    if (!clear_pipes)
        clear_pipes = [NSMutableDictionary dictionary];
    uint64_t key[MGL_MAX_ATTACHMENTS + 1];
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++)
        key[i] = t->tex[i] ? ((uint64_t)pd.colorAttachments[i].pixelFormat << 8) | pd.colorAttachments[i].writeMask : 0;
    key[MGL_MAX_ATTACHMENTS] = pd.depthAttachmentPixelFormat;
    NSData *kd = [NSData dataWithBytes:key length:sizeof key];
    id<MTLRenderPipelineState> ps = clear_pipes[kd];
    if (!ps) {
        NSError *err = nil;
        ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) {
            mgl_log("clear pipeline: %s", err.localizedDescription.UTF8String);
            return;
        }
        clear_pipes[kd] = ps;
    }
    [e setRenderPipelineState:ps];
    int cd = clear_depth && t->depth;
    [e setDepthStencilState:get_depth_state(cd, cd, GL_ALWAYS)];
    [e setCullMode:MTLCullModeNone];
    int x = 0, y = 0, w = t->width, h = t->height;
    if (scissor) {
        x = scissor[0] < 0 ? 0 : scissor[0];
        y = scissor[1] < 0 ? 0 : scissor[1];
        w = scissor[0] + scissor[2] > t->width ? t->width - x : scissor[0] + scissor[2] - x;
        h = scissor[1] + scissor[3] > t->height ? t->height - y : scissor[1] + scissor[3] - y;
    }
    if (w <= 0 || h <= 0)
        return;
    [e setViewport:(MTLViewport){x, y, w, h, 0, 1}];
    [e setScissorRect:(MTLScissorRect){(NSUInteger)x, (NSUInteger)y, (NSUInteger)w, (NSUInteger)h}];
    float dv[4] = {depth, 0, 0, 0};
    float col[4] = {rgba ? rgba[0] : 0, rgba ? rgba[1] : 0, rgba ? rgba[2] : 0, rgba ? rgba[3] : 0};
    rs_reset(); /* the open pass's state is now the clear's */
    [e setVertexBytes:dv length:sizeof dv atIndex:0];
    [e setFragmentBytes:col length:sizeof col atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

static MTLPrimitiveType prim(int mode, int *ok)
{
    *ok = 1;
    switch (mode) {
    case GL_TRIANGLES: return MTLPrimitiveTypeTriangle;
    case GL_TRIANGLE_STRIP: return MTLPrimitiveTypeTriangleStrip;
    case GL_LINES: return MTLPrimitiveTypeLine;
    case GL_LINE_STRIP: return MTLPrimitiveTypeLineStrip;
    case GL_POINTS: return MTLPrimitiveTypePoint;
    }
    *ok = 0;
    return MTLPrimitiveTypeTriangle;
}

/* MCMETAL_STATE_FILTER (on; =0 off): what the open render encoder was last given, so a draw only sends the state
   that differs from the draw before. Menus, item icons, text and particles are hundreds of small draws that differ
   in a vertex buffer and a few uniforms; each used to re-send ~25 encoder calls. The objects are held strongly, so
   an address can't be reused by a new object while it is remembered. Any code that sets encoder state behind
   mglb_draw's back (partial clears, geometry-shader replays) calls rs_reset. */
static int rs_on = -1, rs_valid;
static __strong id rs_ps, rs_ds;
static MTLViewport rs_vp;
static MTLScissorRect rs_sr;
static int rs_cull, rs_wind;
static float rs_bias[2];
static __strong id rs_vbuf[31];
static NSUInteger rs_voff[31];
static __strong id rs_buf[2][31], rs_tex[2][31], rs_smp[2][31];
static NSUInteger rs_boff[2][31];
static int rs_ulen[2];
static _Alignas(16) unsigned char rs_ubytes[2][4096];

static void rs_reset(void)
{
    if (!rs_valid)
        return;
    rs_valid = 0;
    rs_ps = rs_ds = nil;
    for (int i = 0; i < 31; i++) {
        rs_vbuf[i] = nil;
        for (int s = 0; s < 2; s++)
            rs_buf[s][i] = rs_tex[s][i] = rs_smp[s][i] = nil;
    }
    rs_ulen[0] = rs_ulen[1] = 0;
}

/* a fresh encoder knows nothing: everything is sent again */
static int rs_begin(void)
{
    if (rs_on < 0)
        rs_on = !getenv("MCMETAL_STATE_FILTER") || opt("MCMETAL_STATE_FILTER");
    if (!rs_on)
        return 0;
    if (!rs_valid) {
        rs_valid = 1;
        rs_vp.width = -1; /* no real viewport matches */
        rs_sr.width = (NSUInteger)-1;
        rs_cull = rs_wind = -1;
        rs_bias[0] = rs_bias[1] = NAN;
    }
    return 1;
}

static inline int rs_same(int filter, __strong id *slot, id v)
{
    if (filter && *slot == v) {
        prof.rs_skips++;
        return 1;
    }
    prof.rs_sets++;
    if (filter)
        *slot = v;
    return 0;
}

static void rs_vertex_buffer(id<MTLRenderCommandEncoder> e, int filter, id<MTLBuffer> b, NSUInteger off, NSUInteger at)
{
    if (filter && at < 31 && rs_vbuf[at] == b) {
        if (rs_voff[at] == off) {
            prof.rs_skips++;
            return;
        }
        [e setVertexBufferOffset:off atIndex:at]; /* same buffer: just move it */
        rs_voff[at] = off;
        prof.rs_sets++;
        return;
    }
    [e setVertexBuffer:b offset:off atIndex:at];
    prof.rs_sets++;
    if (filter && at < 31) {
        rs_vbuf[at] = b;
        rs_voff[at] = off;
    }
}

static MTLTextureSwizzle swizzle_of(int gl)
{
    switch (gl) {
    case GL_RED: return MTLTextureSwizzleRed;
    case GL_GREEN: return MTLTextureSwizzleGreen;
    case GL_BLUE: return MTLTextureSwizzleBlue;
    case GL_ALPHA: return MTLTextureSwizzleAlpha;
    case GL_ONE: return MTLTextureSwizzleOne;
    }
    return MTLTextureSwizzleZero;
}

static id<MTLTexture> swizzled_view(id<MTLTexture> t, const int sw[4])
{
    MTLTextureSwizzleChannels ch = MTLTextureSwizzleChannelsMake(swizzle_of(sw[0]), swizzle_of(sw[1]), swizzle_of(sw[2]),
                                                                 swizzle_of(sw[3]));
    NSUInteger slices = t.textureType == MTLTextureType3D ? 1 : t.textureType == MTLTextureTypeCube ? 6 : t.arrayLength;
    return [t newTextureViewWithPixelFormat:t.pixelFormat textureType:t.textureType
                                     levels:NSMakeRange(0, t.mipmapLevelCount) slices:NSMakeRange(0, slices) swizzle:ch];
}

static void bind_scene(id<MTLRenderCommandEncoder> e, id<MTLComputeCommandEncoder> c);

static void bind_stage_resources_f(id<MTLRenderCommandEncoder> e, id<MTLComputeCommandEncoder> c, const mgl_draw *d,
                                   int s, int filter)
{
    filter = filter && !c && s < 2;
    if (d->uniforms[s] && d->uniform_size[s]) {
        NSUInteger n = (NSUInteger)d->uniform_size[s];
        if (filter && n <= 4096 && rs_ulen[s] == (int)n && !memcmp(rs_ubytes[s], d->uniforms[s], n)) {
            prof.rs_skips++; /* the same uniform values as the draw before */
        } else if (n <= 4096) {
            if (filter) {
                memcpy(rs_ubytes[s], d->uniforms[s], n);
                rs_ulen[s] = (int)n;
            }
            /* MSL may pad the struct to 16 bytes; hand over a padded copy so the GPU never reads past the end */
            _Alignas(16) unsigned char pad[4096];
            const void *src = d->uniforms[s];
            if (n & 15) {
                memcpy(pad, src, n);
                memset(pad + n, 0, 16 - (n & 15));
                n = (n + 15) & ~(NSUInteger)15;
                src = pad;
            }
            if (c) [c setBytes:src length:n atIndex:MGL_BUF_DEFAULT_UNIFORMS];
            else if (s == 0) [e setVertexBytes:src length:n atIndex:MGL_BUF_DEFAULT_UNIFORMS];
            else [e setFragmentBytes:src length:n atIndex:MGL_BUF_DEFAULT_UNIFORMS];
        } else {
            prof.big_uniforms++;
            if (filter)
                rs_ulen[s] = 0;
            mglb_buffer *tmp = mglb_buffer_new(n + 16);
            memcpy(tmp->ptr, d->uniforms[s], n);
            id<MTLBuffer> b = OBJ(id<MTLBuffer>, tmp->mtl);
            if (c) [c setBuffer:b offset:0 atIndex:MGL_BUF_DEFAULT_UNIFORMS];
            else if (s == 0) [e setVertexBuffer:b offset:0 atIndex:MGL_BUF_DEFAULT_UNIFORMS];
            else [e setFragmentBuffer:b offset:0 atIndex:MGL_BUF_DEFAULT_UNIFORMS];
            use_buffer(tmp);
            mglb_buffer_release(tmp);
        }
    }
    for (int i = 0; i < 12; i++) {
        if (!d->ubo[i])
            continue;
        id<MTLBuffer> b = OBJ(id<MTLBuffer>, d->ubo[i]->mtl);
        int at = MGL_BUF_UBO_BASE + i;
        use_buffer(d->ubo[i]);
        if (filter && rs_buf[s][at] == b && rs_boff[s][at] == d->ubo_offset[i]) {
            prof.rs_skips++;
            continue;
        }
        if (filter) {
            rs_buf[s][at] = b;
            rs_boff[s][at] = d->ubo_offset[i];
        }
        if (c) [c setBuffer:b offset:d->ubo_offset[i] atIndex:(NSUInteger)(MGL_BUF_UBO_BASE + i)];
        else if (s == 0) [e setVertexBuffer:b offset:d->ubo_offset[i] atIndex:(NSUInteger)(MGL_BUF_UBO_BASE + i)];
        else [e setFragmentBuffer:b offset:d->ubo_offset[i] atIndex:(NSUInteger)(MGL_BUF_UBO_BASE + i)];
    }
    for (int i = 0; i < MGL_MAX_SSBOS; i++) {
        if (!d->ssbo[i])
            continue;
        id<MTLBuffer> b = OBJ(id<MTLBuffer>, d->ssbo[i]->mtl);
        mglb_buffer_written(d->ssbo[i]); /* the GPU may write it: nothing cached from its old contents */
        d->ssbo[i]->no_private = 1;
        NSUInteger at = (NSUInteger)(MGL_BUF_SSBO_BASE + i);
        use_buffer(d->ssbo[i]);
        if (filter && rs_buf[s][at] == b && rs_boff[s][at] == d->ssbo_offset[i]) {
            prof.rs_skips++;
            continue;
        }
        if (filter) {
            rs_buf[s][at] = b;
            rs_boff[s][at] = d->ssbo_offset[i];
        }
        if (c) [c setBuffer:b offset:d->ssbo_offset[i] atIndex:at];
        else if (s == 0) [e setVertexBuffer:b offset:d->ssbo_offset[i] atIndex:at];
        else [e setFragmentBuffer:b offset:d->ssbo_offset[i] atIndex:at];
    }
    for (int i = 0; i < d->num_textures[s] && i < MGL_MAX_TEXTURES; i++) {
        const mgl_bound_texture *bt = &d->textures[s][i];
        if (!bt->dim)
            continue; /* slot unused by this stage */
        id<MTLTexture> tex = bt->tex ? OBJ(id<MTLTexture>, bt->tex->mtl) : dummy_texture(bt->dim, bt->sample_kind, bt->is_shadow);
        if (bt->is_image)
            tex_dirty(bt->tex);
        if (bt->is_image && bt->tex && bt->image_level > 0) {
            int li = bt->image_level - 1;
            if (li < 4 && bt->tex->level_view[li])
                tex = OBJ(id<MTLTexture>, bt->tex->level_view[li]);
            else {
                prof.tex_views++;
                tex = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:tex.textureType
                                                  levels:NSMakeRange((NSUInteger)bt->image_level, 1)
                                                  slices:NSMakeRange(0, tex.textureType == MTLTextureType3D ? 1 : tex.arrayLength)];
                if (li < 4 && tex)
                    bt->tex->level_view[li] = retain_obj(tex);
            }
        }
        /* fetch-only textures past slot 15 use a constexpr sampler in the shader (see mgl_xlate.c) */
        if (bt->tex && (bt->swizzle[0] | bt->swizzle[1] | bt->swizzle[2] | bt->swizzle[3])) {
            mglb_texture *x = bt->tex;
            if (x->swz_view && !memcmp(x->swz, bt->swizzle, sizeof x->swz) && !bt->is_image)
                tex = OBJ(id<MTLTexture>, x->swz_view);
            else {
                prof.tex_views++;
                id<MTLTexture> v = swizzled_view(tex, bt->swizzle); /* nil if the view can't be made: keep the texture */
                if (v)
                    tex = v;
                if (!bt->is_image && v) {
                    release_obj(x->swz_view);
                    x->swz_view = retain_obj(v);
                    memcpy(x->swz, bt->swizzle, sizeof x->swz);
                }
            }
        }
        id<MTLSamplerState> smp = bt->is_image || i >= 16 ? nil : get_sampler(&bt->sampler, bt->is_shadow);
        if (filter) {
            if (!rs_same(1, &rs_tex[s][i], tex)) {
                if (s == 0) [e setVertexTexture:tex atIndex:(NSUInteger)i];
                else [e setFragmentTexture:tex atIndex:(NSUInteger)i];
            }
            if (smp && !rs_same(1, &rs_smp[s][i], smp)) {
                if (s == 0) [e setVertexSamplerState:smp atIndex:(NSUInteger)i];
                else [e setFragmentSamplerState:smp atIndex:(NSUInteger)i];
            }
        } else if (c) {
            [c setTexture:tex atIndex:(NSUInteger)i];
            if (smp) [c setSamplerState:smp atIndex:(NSUInteger)i];
        } else if (s == 0) {
            [e setVertexTexture:tex atIndex:(NSUInteger)i];
            if (smp) [e setVertexSamplerState:smp atIndex:(NSUInteger)i];
        } else {
            [e setFragmentTexture:tex atIndex:(NSUInteger)i];
            if (smp) [e setFragmentSamplerState:smp atIndex:(NSUInteger)i];
        }
    }
}

static void bind_stage_resources(id<MTLRenderCommandEncoder> e, id<MTLComputeCommandEncoder> c, const mgl_draw *d, int s)
{
    bind_stage_resources_f(e, c, d, s, 0);
}

/* GL's base vertex, applied as a vertex-buffer offset instead of Metal's baseVertex: with Sodium's large base
   vertices (~192000 into a 3.9 MB buffer) Apple's paravirtual GPU drew nothing (gl_smoke test 8). Returns the
   baseVertex left for Metal: 0 when every per-vertex buffer could be offset, else the GL value unchanged. */
static int apply_base_vertex(id<MTLRenderCommandEncoder> e, const mgl_draw *d, long base)
{
    static int use_metal_base = -1;
    if (use_metal_base < 0)
        use_metal_base = opt("MGL_METAL_BASE_VERTEX");
    if (use_metal_base)
        return (int)base;
    for (int i = 0; i < d->num_vbufs; i++)
        if (!d->vbufs[i].divisor && d->vbufs[i].stride > 0 && base < 0 &&
            (long)d->vbufs[i].offset + base * d->vbufs[i].stride < 0)
            return (int)base; /* would go below the buffer start: leave it to Metal */
    for (int i = 0; i < d->num_vbufs; i++)
        if (!d->vbufs[i].divisor && d->vbufs[i].stride > 0 && ((long)d->vbufs[i].offset + base * d->vbufs[i].stride) % 4)
            return (int)base; /* Metal wants 4-byte aligned buffer offsets */
    for (int i = 0; i < d->num_vbufs; i++) {
        const mgl_vertex_buf *vb = &d->vbufs[i];
        if (vb->divisor || vb->stride <= 0)
            continue; /* per-instance and constant data ignore the base vertex in GL too */
        NSUInteger off = (NSUInteger)((long)vb->offset + base * vb->stride), at = (NSUInteger)(MGL_BUF_VERTEX_BASE + i);
        [e setVertexBufferOffset:off atIndex:at];
        if (rs_valid)
            rs_voff[at] = off;
    }
    return 0;
}

void mglb_draw(const mgl_draw *d)
{
    int ok;
    MTLPrimitiveType pt = prim(d->primitive, &ok);
    if (!ok) {
        static int warned;
        if (!warned++)
            mgl_log("primitive 0x%04X not supported", d->primitive);
        return;
    }
    if (d->cull && d->cull_face == GL_FRONT_AND_BACK && d->primitive >= GL_TRIANGLES)
        return;
    if (skip_program(d) || draws_nothing(d))
        return;
    if (dump_this_frame() && getenv("MGL_FRAME_DUMP_TEXELS") && d->multi_n == 0 && d->count <= 6)
        dump_texels(d);
    id<MTLRenderPipelineState> ps = get_pipeline(d, &d->target);
    if (!ps)
        return;
    id<MTLRenderCommandEncoder> e = pass_for_draw(d);
    pt_label(d->program->label);
    int f = rs_begin();
    if (!rs_same(f, &rs_ps, ps))
        [e setRenderPipelineState:ps];
    int probe = probe_program(d);
    id<MTLDepthStencilState> ds = get_depth_state(d->depth_test && d->target.depth && !probe, /* GL: no depth writes with the test off */
                                                  d->depth_test && d->depth_write && d->target.depth && !probe, d->depth_func);
    if (!rs_same(f, &rs_ds, ds))
        [e setDepthStencilState:ds];
    MTLViewport vp = {d->viewport[0], d->viewport[1], d->viewport[2], d->viewport[3], 0, 1};
    if (f && !memcmp(&vp, &rs_vp, sizeof vp))
        prof.rs_skips++;
    else {
        [e setViewport:vp];
        rs_vp = vp;
        prof.rs_sets++;
    }
    MTLScissorRect sr = {0, 0, (NSUInteger)d->target.width, (NSUInteger)d->target.height};
    if (d->scissor_enabled) {
        int x0 = d->scissor[0] < 0 ? 0 : d->scissor[0], y0 = d->scissor[1] < 0 ? 0 : d->scissor[1];
        int x1 = d->scissor[0] + d->scissor[2], y1 = d->scissor[1] + d->scissor[3];
        if (x1 > d->target.width) x1 = d->target.width;
        if (y1 > d->target.height) y1 = d->target.height;
        if (x1 <= x0 || y1 <= y0)
            return;
        sr = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
    }
    if (f && !memcmp(&sr, &rs_sr, sizeof sr))
        prof.rs_skips++;
    else {
        [e setScissorRect:sr];
        rs_sr = sr;
        prof.rs_sets++;
    }
    MTLCullMode cm = !d->cull || probe ? MTLCullModeNone : d->cull_face == GL_FRONT ? MTLCullModeFront : MTLCullModeBack;
    /* translated vertex shaders flip Y, which flips winding */
    MTLWinding wind = d->front_face == GL_CW ? MTLWindingCounterClockwise : MTLWindingClockwise;
    if (!f || rs_cull != (int)cm) {
        [e setCullMode:cm];
        rs_cull = (int)cm;
    }
    if (!f || rs_wind != (int)wind) {
        [e setFrontFacingWinding:wind];
        rs_wind = (int)wind;
    }
    float bias[2] = {d->polygon_offset_enabled ? d->polygon_offset_units : 0, d->polygon_offset_enabled ? d->polygon_offset_factor : 0};
    if (!f || memcmp(bias, rs_bias, sizeof bias)) {
        [e setDepthBias:bias[0] slopeScale:bias[1] clamp:0];
        memcpy(rs_bias, bias, sizeof bias);
    }
    for (int i = 0; i < d->num_vbufs; i++) {
        rs_vertex_buffer(e, f, draw_buf(d->vbufs[i].buf), d->vbufs[i].offset, (NSUInteger)(MGL_BUF_VERTEX_BASE + i));
        use_buffer(d->vbufs[i].buf);
    }
    bind_stage_resources_f(e, nil, d, 0, f);
    bind_stage_resources_f(e, nil, d, 1, f);
    if (d->uses_scene)
        bind_scene(e, nil);
    if (debug_draws()) {
        if (d->multi_n > 0)
            for (int i = 0; i < d->multi_n; i++)
                check_vertex_range(d, d->multi_count[i], (size_t)d->multi_offset[i], d->multi_base[i]);
        else
            check_vertex_range(d, d->count, d->index_offset, d->base_vertex);
    }
    frame_draws++;
    frame_probes += (unsigned long)probe;
    if (dump_this_frame())
        mgl_log("frame dump: draw %lu: %s, target%s%s %dx%d depth %p, depth test %d write %d func 0x%x, cull %d, blend %d "
                "mask 0x%x, prim 0x%x, count %d multi %d", frame_draws, d->program->label, dump_targets(&d->target, d->blend),
                d->target.is_default ? " (window)" : "", d->target.width, d->target.height, (void *)d->target.depth,
                d->depth_test, d->depth_write, d->depth_func, d->cull, d->blend[0].enabled, d->blend[0].color_mask,
                d->primitive, d->count, d->multi_n);
    if (dump_this_frame())
        mgl_log("frame dump:   samples%s", dump_textures(d));
    if (probe || log_program(d))
        log_probe_draw(d);
    frame_sections += d->multi_n > 0 ? d->multi_n : 0;
    if (opt_profile > 0 && d->primitive == GL_TRIANGLES && d->viewport[2] == d->viewport[3] && d->viewport[2] >= 1024) {
        long n = 0;
        if (d->multi_n > 0)
            for (int i = 0; i < d->multi_n; i++)
                n += d->multi_count[i];
        else
            n = (long)d->count * (d->instances > 0 ? d->instances : 1);
        prof.sh_draws += d->multi_n > 0 ? (unsigned long)d->multi_n : 1;
        prof.sh_tris += (unsigned long)(n / 3);
    }
    if (d->multi_n > 0 && d->cull_cmd > 0 && cull_state > 0) {
        draw_culled(e, d, pt);
    } else if (d->multi_n > 0) {
        id<MTLBuffer> ib = draw_buf(d->index_buf);
        MTLIndexType it = d->index_type == GL_UNSIGNED_SHORT ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
        for (int i = 0; i < d->multi_n; i++)
            if (d->multi_count[i] > 0) {
                int bv = apply_base_vertex(e, d, d->multi_base[i]);
                [e drawIndexedPrimitives:pt indexCount:(NSUInteger)d->multi_count[i] indexType:it indexBuffer:ib
                       indexBufferOffset:(NSUInteger)(size_t)d->multi_offset[i] instanceCount:1
                              baseVertex:bv baseInstance:0];
            }
        use_buffer(d->index_buf);
    } else if (d->index_buf) {
        int bv = apply_base_vertex(e, d, d->base_vertex);
        [e drawIndexedPrimitives:pt indexCount:(NSUInteger)d->count
                       indexType:d->index_type == GL_UNSIGNED_SHORT ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32
                     indexBuffer:draw_buf(d->index_buf) indexBufferOffset:d->index_offset
                   instanceCount:(NSUInteger)d->instances baseVertex:bv baseInstance:0];
        use_buffer(d->index_buf);
    } else {
        [e drawPrimitives:pt vertexStart:(NSUInteger)d->first vertexCount:(NSUInteger)d->count
            instanceCount:(NSUInteger)d->instances];
    }
    debug_sync("draw", d, d->count, d->first);
}

void mglb_dispatch(const mgl_draw *d, int gx, int gy, int gz)
{
    if (!d->program->compute)
        return;
    id<MTLComputeCommandEncoder> c = compute_encoder();
    pt_label(d->program->label); /* MGL_PROFILE=2/3: name the pass after its first compute program */
    [c setComputePipelineState:OBJ(id<MTLComputePipelineState>, d->program->compute)];
    bind_stage_resources(nil, c, d, 2);
    if (d->uses_scene)
        bind_scene(nil, c);
    MTLSize tg = MTLSizeMake((NSUInteger)(d->local_size[0] > 0 ? d->local_size[0] : 1),
                             (NSUInteger)(d->local_size[1] > 0 ? d->local_size[1] : 1),
                             (NSUInteger)(d->local_size[2] > 0 ? d->local_size[2] : 1));
    [c dispatchThreadgroups:MTLSizeMake((NSUInteger)gx, (NSUInteger)gy, (NSUInteger)gz) threadsPerThreadgroup:tg];
    frame_dispatches++;
    debug_sync("dispatch", d, (long)gx * gy * gz, 0);
}

/* Geometry-shader draws are batched (MGL_GS_BATCH=0 turns it off). Each one's compute job is encoded at once,
   but its draw waits in gs_pending until something else needs the GPU. A run of them (SEUS's voxel shadow pass:
   ~190 per frame) then shares one compute encoder and one render pass. Without this, each draw split the target
   into its own pass, and each pass loaded and stored the whole 4096x4096 shadow map: 60-67% of SEUS's GPU time
   on an M3. */
typedef void (^gs_play)(id<MTLRenderCommandEncoder> e);
static NSMutableArray<gs_play> *gs_pending;
static mgl_target gs_target;
static int gs_batch = -1;

/* Geometry-shader output cache. While the camera only turns, every input of SEUS's shadow vertex and geometry
   shaders stays the same (cameraPosition and the shadow matrices move only with the camera's position or the
   sun), but Iris draws ~6x more shadow geometry than when standing still: 1786 draws, 1.24M triangles, 795 MB of
   records a frame, ~40 ms of GPU. So a draw's records are kept in GPU memory and drawn again while its inputs
   match: same program, vertex/index/uniform buffers unwritten since, same ranges, same default uniforms. A draw is
   stored the second frame running it comes with the same inputs (walking changes them every frame: those draws
   never take memory) and dropped after two frames unused. Programs whose vertex or geometry stage reads
   textures, images, storage buffers or the ray-tracing scene are never cached. MGL_GS_CACHE_MB caps the memory
   (default: a sixteenth of RAM, at most 1024; 0 = off). */
#define GSC_SLAB ((size_t)64 << 20)
#define GSC_MAX_SLABS 64
#define GSC_MAX 16384 /* entries; the table has twice as many slots */
typedef struct { uint32_t off, len; } gsc_range;
typedef struct {
    id<MTLBuffer> buf;
    gsc_range *free;
    int nfree, cap;
    uint64_t empty_since; /* frame it last became empty, 0 = in use */
} gsc_slab;
typedef struct { int slab; uint32_t off, len; uint64_t serial; } gsc_later; /* freed, but the GPU may still read it */
typedef struct {
    uint64_t k0, k1;
    int slab; /* -1: seen once, nothing stored */
    uint32_t off, len, oc_off;
    uint64_t frame, serial; /* last frame it was used in; command buffer that last read it */
} gsc_entry;
static gsc_slab gsc_slabs[GSC_MAX_SLABS];
static int gsc_nslabs;
static gsc_later *gsc_laters;
static int gsc_nlater, gsc_caplater;
static gsc_entry gsc_e[GSC_MAX];
static int gsc_n;
static int gsc_slot[GSC_MAX * 2]; /* index + 1 into gsc_e, 0 = empty */
static uint64_t gsc_frame;
static size_t gsc_limit = (size_t)-1;
static unsigned long gsc_hits, gsc_stores, gsc_misses, gsc_skips, gsc_full;
static int gsc_last_ranges; /* MGL_PROFILE: the last cached draw's uniform ranges (-1 = whole block) */

static size_t gsc_cap_bytes(void)
{
    if (gsc_limit == (size_t)-1) {
        const char *e = getenv("MGL_GS_CACHE_MB");
        size_t mb = (size_t)(NSProcessInfo.processInfo.physicalMemory >> 24); /* RAM / 16 */
        if (mb > 1024)
            mb = 1024;
        if (e)
            mb = (size_t)atol(e);
        gsc_limit = mb << 20;
        mgl_log("geometry-shader output cache: %zu MB", mb);
    }
    return gsc_limit;
}

static void gsc_free_range(gsc_slab *s, uint32_t off, uint32_t len)
{
    int i = 0;
    while (i < s->nfree && s->free[i].off < off)
        i++;
    if (i > 0 && s->free[i - 1].off + s->free[i - 1].len == off) { /* join the one before */
        s->free[i - 1].len += len;
        if (i < s->nfree && off + len == s->free[i].off) {
            s->free[i - 1].len += s->free[i].len;
            memmove(&s->free[i], &s->free[i + 1], sizeof *s->free * (size_t)(s->nfree - i - 1));
            s->nfree--;
        }
        return;
    }
    if (i < s->nfree && off + len == s->free[i].off) { /* join the one after */
        s->free[i].off = off;
        s->free[i].len += len;
        return;
    }
    if (s->nfree == s->cap) {
        s->cap = s->cap ? s->cap * 2 : 64;
        s->free = realloc(s->free, sizeof *s->free * (size_t)s->cap);
    }
    memmove(&s->free[i + 1], &s->free[i], sizeof *s->free * (size_t)(s->nfree - i));
    s->free[i] = (gsc_range){off, len};
    s->nfree++;
}

static void gsc_release(const gsc_entry *e)
{
    if (e->slab < 0)
        return;
    if (gsc_nlater == gsc_caplater) {
        gsc_caplater = gsc_caplater ? gsc_caplater * 2 : 256;
        gsc_laters = realloc(gsc_laters, sizeof *gsc_laters * (size_t)gsc_caplater);
    }
    gsc_laters[gsc_nlater++] = (gsc_later){e->slab, e->off, e->len, e->serial};
}

/* bytes from the slabs, 256-aligned; -1 when the cache is full */
static void gsc_reclaim(void)
{
    uint64_t done = atomic_load(&completed_serial);
    int n = 0;
    for (int i = 0; i < gsc_nlater; i++) /* ranges the GPU has finished with */
        if (gsc_laters[i].serial <= done)
            gsc_free_range(&gsc_slabs[gsc_laters[i].slab], gsc_laters[i].off, gsc_laters[i].len);
        else
            gsc_laters[n++] = gsc_laters[i];
    gsc_nlater = n;
}

static int gsc_alloc(uint32_t len, uint32_t *off)
{
    gsc_reclaim();
    for (int k = 0; k <= gsc_nslabs; k++) {
        if (k == gsc_nslabs) {
            if (k == GSC_MAX_SLABS || (size_t)(k + 1) * GSC_SLAB > gsc_cap_bytes())
                return -1;
            id<MTLBuffer> b = [dev newBufferWithLength:GSC_SLAB options:MTLResourceStorageModePrivate];
            if (!b)
                return -1;
            b.label = @"geometry-shader cache";
            gsc_slabs[k].buf = b;
            gsc_free_range(&gsc_slabs[k], 0, (uint32_t)GSC_SLAB);
            gsc_nslabs++;
        }
        gsc_slab *s = &gsc_slabs[k];
        for (int i = 0; i < s->nfree; i++)
            if (s->free[i].len >= len) {
                *off = s->free[i].off;
                s->free[i].off += len;
                s->free[i].len -= len;
                if (!s->free[i].len) {
                    memmove(&s->free[i], &s->free[i + 1], sizeof *s->free * (size_t)(s->nfree - i - 1));
                    s->nfree--;
                }
                return k;
            }
    }
    return -1;
}

static void gsc_rehash(void)
{
    memset(gsc_slot, 0, sizeof gsc_slot);
    for (int i = 0; i < gsc_n; i++) {
        uint32_t h = (uint32_t)gsc_e[i].k0 & (GSC_MAX * 2 - 1);
        while (gsc_slot[h])
            h = (h + 1) & (GSC_MAX * 2 - 1);
        gsc_slot[h] = i + 1;
    }
}

/* once a frame: drop what the last two frames didn't use (seen-once entries: what the last frame didn't see) */
static void gsc_end_frame(void)
{
    gsc_frame++;
    if (gsc_nslabs) { /* give back slabs at the end that stayed empty for 120 frames (walking empties them) */
        gsc_reclaim();
        for (int k = 0; k < gsc_nslabs; k++) { /* every slab's timer, so ones behind a busy slab age too */
            gsc_slab *s = &gsc_slabs[k];
            if (!(s->nfree == 1 && s->free[0].len == (uint32_t)GSC_SLAB))
                s->empty_since = 0;
            else if (!s->empty_since)
                s->empty_since = gsc_frame;
        }
        while (gsc_nslabs) {
            gsc_slab *s = &gsc_slabs[gsc_nslabs - 1];
            if (!s->empty_since || gsc_frame - s->empty_since < 120)
                break;
            s->buf = nil;
            free(s->free);
            *s = (gsc_slab){0};
            gsc_nslabs--;
        }
    }
    if (!gsc_n)
        return;
    int n = 0;
    for (int i = 0; i < gsc_n; i++) {
        gsc_entry *e = &gsc_e[i];
        if (gsc_frame - e->frame > (e->slab < 0 ? 1u : 2u)) {
            gsc_release(e);
            continue;
        }
        gsc_e[n++] = *e;
    }
    if (n != gsc_n) {
        gsc_n = n;
        gsc_rehash();
    }
}

static gsc_entry *gsc_find(uint64_t k0, uint64_t k1)
{
    for (uint32_t h = (uint32_t)k0 & (GSC_MAX * 2 - 1); gsc_slot[h]; h = (h + 1) & (GSC_MAX * 2 - 1))
        if (gsc_e[gsc_slot[h] - 1].k0 == k0 && gsc_e[gsc_slot[h] - 1].k1 == k1)
            return &gsc_e[gsc_slot[h] - 1];
    return NULL;
}

static gsc_entry *gsc_add(uint64_t k0, uint64_t k1)
{
    if (gsc_n == GSC_MAX)
        return NULL;
    gsc_entry *e = &gsc_e[gsc_n++];
    *e = (gsc_entry){k0, k1, -1, 0, 0, 0, gsc_frame, 0};
    uint32_t h = (uint32_t)k0 & (GSC_MAX * 2 - 1);
    while (gsc_slot[h])
        h = (h + 1) & (GSC_MAX * 2 - 1);
    gsc_slot[h] = gsc_n;
    return e;
}

typedef struct { uint64_t a, b; } gsc_hash;
static void gsc_mix(gsc_hash *h, const void *data, size_t n)
{
    const unsigned char *p = data;
    for (; n >= 8; n -= 8, p += 8) {
        uint64_t w;
        memcpy(&w, p, 8);
        h->a = (h->a ^ w) * 0x9E3779B97F4A7C15ull;
        h->a ^= h->a >> 29;
        h->b = (h->b + w) * 0xC2B2AE3D27D4EB4Full;
        h->b ^= h->b >> 31;
    }
    if (n) {
        uint64_t w = 0;
        memcpy(&w, p, n);
        gsc_mix(h, &w, 8);
    }
}
#define GSC_MIX(h, v) do { __typeof__(v) mix_v_ = (v); gsc_mix(h, &mix_v_, sizeof mix_v_); } while (0)

/* Why draws miss (MGL_PROFILE): per draw site (the same draw minus buffer contents and uniform values), what
   changed since the frame before */
#define GSC_SITES 16384
static struct { uint64_t site, bufs, unis, frame; } gsc_site[GSC_SITES];
static unsigned long gsc_why_bufs, gsc_why_unis, gsc_why_new;

static void gsc_note_site(uint64_t site, uint64_t bufs, uint64_t unis)
{
    unsigned h = (unsigned)(site ^ site >> 32) & (GSC_SITES - 1);
    if (gsc_site[h].site == site && gsc_site[h].frame + 1 == gsc_frame) {
        gsc_why_bufs += gsc_site[h].bufs != bufs;
        gsc_why_unis += gsc_site[h].unis != unis;
    } else if (gsc_site[h].frame != gsc_frame || gsc_site[h].site != site)
        gsc_why_new++;
    gsc_site[h].site = site;
    gsc_site[h].bufs = bufs;
    gsc_site[h].unis = unis;
    gsc_site[h].frame = gsc_frame;
}

/* the draw's inputs as a key; 0 when the draw can't be cached */
static int gsc_key(const mgl_draw *d, const int32_t desc[16][4], int triangles, uint64_t *k0, uint64_t *k1)
{
    if (!gsc_cap_bytes() || d->uses_scene) {
        gsc_skips++;
        return 0;
    }
    for (int i = 0; i < d->num_textures[2] && i < MGL_MAX_TEXTURES; i++)
        if (d->textures[2][i].dim) {
            gsc_skips++;
            return 0;
        }
    for (int i = 0; i < MGL_MAX_SSBOS; i++)
        if (d->ssbo[i]) {
            gsc_skips++;
            return 0;
        }
    /* three parts: the draw itself, its buffers' write counters, the uniform values it reads */
    gsc_hash h = {0x243F6A8885A308D3ull, 0x13198A2E03707344ull}, hb = h, hu = h;
    GSC_MIX(&h, d->program->id); /* never reused, unlike a freed program's address */
    GSC_MIX(&h, triangles);
    GSC_MIX(&h, d->gs_sec_n);
    if (d->gs_sec_n)
        gsc_mix(&h, d->gs_sec, sizeof(int32_t) * 4 * (size_t)d->gs_sec_n);
    gsc_mix(&h, desc, sizeof(int32_t) * 16 * 4);
    for (int i = 0; i < d->num_vbufs && i < 4; i++) {
        const mglb_buffer *b = d->vbufs[i].buf;
        if (b && b->written == UINT64_MAX) {
            gsc_skips++;
            return 0;
        }
        GSC_MIX(&h, (uintptr_t)b);
        GSC_MIX(&hb, b ? b->written : 0);
        GSC_MIX(&h, d->vbufs[i].offset);
    }
    if (d->index_buf) {
        if (d->index_buf->written == UINT64_MAX) {
            gsc_skips++;
            return 0;
        }
        GSC_MIX(&h, (uintptr_t)d->index_buf);
        GSC_MIX(&hb, d->index_buf->written);
    }
    for (int i = 0; i < 12; i++)
        if (d->ubo[i]) {
            if (d->ubo[i]->written == UINT64_MAX) {
                gsc_skips++;
                return 0;
            }
            GSC_MIX(&h, i);
            GSC_MIX(&h, (uintptr_t)d->ubo[i]);
            GSC_MIX(&hb, d->ubo[i]->written);
            GSC_MIX(&h, d->ubo_offset[i]);
        }
    /* the default uniforms the stages read (mgl_draw_info among them: triangles, index type, base vertex, first
       index). Only those: the block also holds every uniform the pack declares, frameTimeCounter included. */
    gsc_last_ranges = d->uniform_used ? d->num_uniform_used : -1;
    if (d->uniforms[2] && d->uniform_size[2]) {
        if (d->num_uniform_used < 0 || !d->uniform_used)
            gsc_mix(&hu, d->uniforms[2], (size_t)d->uniform_size[2]);
        else
            for (int i = 0; i < d->num_uniform_used; i++) {
                long off = d->uniform_used[i][0], len = d->uniform_used[i][1];
                if (off >= 0 && len > 0 && off + len <= (long)d->uniform_size[2])
                    gsc_mix(&hu, (const char *)d->uniforms[2] + off, (size_t)len);
            }
    }
    /* mgl_draw_info (first index, base vertex) is in the uniforms: part of the site too */
    GSC_MIX(&h, d->index_offset);
    GSC_MIX(&h, d->base_vertex);
    GSC_MIX(&h, d->first);
    gsc_note_site(h.a, hb.a, hu.a);
    gsc_mix(&h, &hb, sizeof hb);
    gsc_mix(&h, &hu, sizeof hu);
    *k0 = h.a;
    *k1 = h.b;
    return 1;
}

/* Geometry-shader emulation (mgl_gs.c). The compute stage gets: 21 attribute descriptors, 22..25 raw vertex
   buffers, 26 index buffer, 27 emitted vertex records, 28 per-primitive vertex counts. The passthrough vertex
   stage reads 27/28 and turns each strip into a triangle list. */
/* MGL_GS_PROBE=6 (timing only): no passthrough draws and no cache hits, the compute stage alone */
static int gs_probe_no_pass(void)
{
    static int on = -1;
    if (on < 0)
        on = getenv("MGL_GS_PROBE") && atoi(getenv("MGL_GS_PROBE")) == 6;
    return on;
}

/* The geometry compute made for this draw's vertex format (buffer and format word of each attribute as function
   constants, see mgl_fetchf in core/mgl_gs.c), or nil while it compiles in the background (the general one runs
   meanwhile, so a new format never stalls a frame). MGL_GS_SPEC=0: always the general one. */
static id<MTLComputePipelineState> gs_spec_pipeline(const mglb_program *p, int32_t desc[16][4])
{
    static int on = -1;
    if (on < 0)
        on = !getenv("MGL_GS_SPEC") || atoi(getenv("MGL_GS_SPEC")) != 0;
    if (!on || !p->clib)
        return nil;
    int32_t k[16][2];
    for (int i = 0; i < 16; i++) {
        k[i][0] = desc[i][0] < 0 ? -2 : desc[i][0];
        k[i][1] = desc[i][0] < 0 ? 0 : desc[i][3];
    }
    NSData *key = [NSData dataWithBytes:k length:sizeof k];
    NSMutableDictionary *cache = OBJ(NSMutableDictionary *, p->cspec);
    id got;
    @synchronized(cache) {
        got = cache[key];
        if (!got)
            cache[key] = [NSNull null];
    }
    if (got)
        return got == [NSNull null] ? nil : got;
    id<MTLLibrary> lib = OBJ(id<MTLLibrary>, p->clib);
    MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
    for (int i = 0; i < 16; i++) { /* constants the function doesn't declare are ignored */
        [cv setConstantValue:&k[i][0] type:MTLDataTypeInt atIndex:MGL_GS_FC + 2 * i];
        [cv setConstantValue:&k[i][1] type:MTLDataTypeInt atIndex:MGL_GS_FC + 2 * i + 1];
    }
    NSString *name = [NSString stringWithUTF8String:p->label]; /* the block can't capture a C array */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSError *e = nil;
      id<MTLFunction> fn = [lib newFunctionWithName:@"main0" constantValues:cv error:&e];
      id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&e] : nil;
      if (!ps) {
          static int warned;
          if (!warned++)
              mgl_log("%s: geometry compute for its vertex format failed (the general one stays): %s", name.UTF8String,
                      e.localizedDescription.UTF8String);
          return; /* the NSNull stays: never retried */
      }
      @synchronized(cache) {
          cache[key] = ps;
      }
    });
    return nil;
}

void mglb_draw_gs(const mgl_draw *d, int triangles, int max_vertices, int record_floats)
{
    if (!d->program->compute || !d->program->vfn || max_vertices < 3 || triangles <= 0)
        return;
    if (d->cull && d->cull_face == GL_FRONT_AND_BACK)
        return;
    int32_t desc[16][4];
    for (int i = 0; i < 16; i++) {
        const mgl_vertex_attr *a = &d->attrs[i];
        desc[i][0] = -1;
        desc[i][1] = desc[i][2] = desc[i][3] = 0;
        if (!a->enabled || a->buffer < 0 || a->buffer >= d->num_vbufs)
            continue;
        if (a->buffer >= 4) {
            static int warned;
            if (!warned++)
                mgl_log("geometry shader: vertex attribute %d uses buffer slot %d (max 4)", i, a->buffer);
            continue;
        }
        const mgl_vertex_buf *vb = &d->vbufs[a->buffer];
        desc[i][0] = a->buffer;
        desc[i][1] = (int32_t)(vb->offset + (size_t)a->offset);
        desc[i][2] = vb->stride;
        desc[i][3] = (int32_t)a->type | (a->size << 4) | (a->normalized ? 1 << 8 : 0);
    }
    size_t out_bytes = (size_t)triangles * (size_t)max_vertices * (size_t)record_floats * 4;
    prof.gs_draws++;
    prof.gs_tris += (unsigned long)triangles;
    id<MTLBuffer> ovb = nil, ocb = nil;
    NSUInteger ovo = 0, oco = 0;
    uint64_t k0, k1;
    int keyed = !gs_probe_no_pass() && gsc_key(d, desc, triangles, &k0, &k1);
    gsc_entry *ce = keyed ? gsc_find(k0, k1) : NULL;
    if (keyed && !ce)
        ce = gsc_add(k0, k1);
    int hit = ce && ce->slab >= 0;
    if (hit) { /* drawn before with the same inputs: its records are still in the cache */
        ovb = ocb = gsc_slabs[ce->slab].buf;
        ovo = ce->off;
        oco = ce->oc_off;
        gsc_hits++;
    } else if (ce && ce->frame + 1 == gsc_frame) { /* the same inputs two frames running: keep this one */
        uint32_t ovl = (uint32_t)((out_bytes + 255) & ~(size_t)255), ocl = (uint32_t)(((size_t)triangles * 4 + 255) & ~(size_t)255);
        uint32_t off;
        int k = out_bytes + ocl <= GSC_SLAB ? gsc_alloc(ovl + ocl, &off) : -1;
        if (k >= 0) {
            ce->slab = k;
            ce->off = off;
            ce->len = ovl + ocl;
            ce->oc_off = off + ovl;
            ovb = ocb = gsc_slabs[k].buf;
            ovo = off;
            oco = off + ovl;
            gsc_stores++;
        } else
            gsc_full++;
    } else if (keyed)
        gsc_misses++;
    if (ce) {
        current_cb();
        ce->frame = gsc_frame;
        ce->serial = cb_serial;
    }
    int rec_transient = !ovb;
    if (!ovb) {
        transient_t ov = transient(out_bytes), oc = transient((size_t)triangles * 4);
        if (!ov.buf || !oc.buf)
            return;
        ovb = ov.buf;
        ocb = oc.buf;
        ovo = ov.off;
        oco = oc.off;
    }
    if (!hit)
        prof.gs_bytes += out_bytes;

    /* 1. vertex + geometry stages as one compute job, one thread per input triangle (none for a cached draw) */
    if (gs_batch < 0)
        gs_batch = !getenv("MGL_GS_BATCH") || atoi(getenv("MGL_GS_BATCH")) != 0;
    if (!gs_batch || !same_target(&d->target, &gs_target) || gs_pending.count >= 2048)
        gs_flush();
    if (hit && npclear) { /* no compute encoder to replay them: the strips' fragment stage may read a cleared image */
        int reads = 0;
        for (int st = 0; st < 3 && !reads; st++)
            for (int i = 0; i < MGL_MAX_TEXTURES && !reads; i++)
                reads = d->textures[st][i].tex && pending_clear_uses(d->textures[st][i].tex);
        if (reads) {
            gs_flush();
            materialize_clears();
        }
    }
    if (!hit) {
        /* the vertex and geometry stages run as compute: pending clears can wait for the strips' render pass unless
           this draw also reads one of their images */
        int reads_cleared = 0;
        for (int st = 0; st < 3 && npclear && !reads_cleared; st++)
            for (int i = 0; i < MGL_MAX_TEXTURES && !reads_cleared; i++)
                reads_cleared = d->textures[st][i].tex && pending_clear_uses(d->textures[st][i].tex);
        if (reads_cleared && flush_log_on()) {
            static line_tally gs_reads = {"geometry-shader draws reading a pending clear's image"};
            tally_line(&gs_reads, __LINE__);
        }
        gs_recording = 1;
        keep_clears = !reads_cleared;
        static int gs_concurrent = -1;
        if (gs_concurrent < 0)
            gs_concurrent = !getenv("MGL_GS_CONCURRENT") || atoi(getenv("MGL_GS_CONCURRENT")) != 0;
        id<MTLComputeCommandEncoder> c = compute_encoder_kind(gs_concurrent);
        pt_label("geometry-shader compute"); /* MGL_PROFILE=2/3: name its pass (it holds every GS job until the strips) */
        keep_clears = 0;
        gs_recording = 0;
        id<MTLComputePipelineState> gps = gs_spec_pipeline(d->program, desc);
        if (gps)
            prof.gs_spec++;
        [c setComputePipelineState:gps ?: OBJ(id<MTLComputePipelineState>, d->program->compute)];
        bind_stage_resources(nil, c, d, 2);
        if (d->uses_scene)
            bind_scene(nil, c);
        [c setBytes:desc length:sizeof desc atIndex:MGL_BUF_INTERNAL_BASE];
        for (int i = 0; i < 4; i++) { /* unused slots get any valid buffer */
            mglb_buffer *b = i < d->num_vbufs ? d->vbufs[i].buf : d->num_vbufs ? d->vbufs[0].buf : NULL;
            [c setBuffer:b ? draw_buf(b) : ovb offset:0 atIndex:(NSUInteger)(MGL_BUF_INTERNAL_BASE + 1 + i)];
            use_buffer(b);
        }
        [c setBuffer:d->index_buf ? draw_buf(d->index_buf) : ovb offset:0 atIndex:MGL_BUF_INTERNAL_BASE + 5];
        use_buffer(d->index_buf);
        [c setBuffer:ovb offset:ovo atIndex:MGL_BUF_INTERNAL_BASE + 6];
        [c setBuffer:ocb offset:oco atIndex:MGL_BUF_INTERNAL_BASE + 7];
        { /* the section table (mgl_sec): [0].x = count, then 4 ints per section; a single draw gets count 0 */
            size_t tb = 16 * ((size_t)d->gs_sec_n + 1);
            if (tb <= 4096) {
                int32_t t[1024];
                memset(t, 0, 16);
                t[0] = d->gs_sec_n;
                if (d->gs_sec_n)
                    memcpy(t + 4, d->gs_sec, tb - 16);
                [c setBytes:t length:tb atIndex:MGL_BUF_INTERNAL_BASE + 8];
            } else {
                transient_t tt = transient(tb);
                if (tt.buf) {
                    int32_t head[4] = {d->gs_sec_n, 0, 0, 0};
                    memcpy(tt.ptr, head, 16);
                    memcpy((char *)tt.ptr + 16, d->gs_sec, tb - 16);
                }
                [c setBuffer:tt.buf ? tt.buf : ovb offset:tt.buf ? tt.off : 0 atIndex:MGL_BUF_INTERNAL_BASE + 8];
            }
        }
        NSUInteger lx = (NSUInteger)(d->local_size[0] > 0 ? d->local_size[0] : 64);
        [c dispatchThreadgroups:MTLSizeMake(((NSUInteger)triangles + lx - 1) / lx, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(lx, 1, 1)];
        if (rec_transient && gs_untracked > 0 && gs_fence)
            gs_fence_due = 1;
    }

    /* 2. draw the emitted strips: no vertex fetch, records come from buffers 27/28. Kept for gs_flush, with its
       own copy of the default-block uniforms (the GL side reuses that memory for the next draw). */
    mgl_draw *p = malloc(sizeof *p);
    *p = *d;
    memset(p->attrs, 0, sizeof p->attrs);
    p->num_vbufs = 0;
    id<MTLRenderPipelineState> ps = get_pipeline(p, &p->target);
    if (!ps) {
        free(p);
        return;
    }
    /* plain malloc copies, freed with p: autoreleased objects are never drained on the game's render thread */
    void *u0 = p->uniforms[0] && p->uniform_size[0] ? malloc((size_t)p->uniform_size[0]) : NULL;
    void *u1 = p->uniforms[1] && p->uniform_size[1] ? malloc((size_t)p->uniform_size[1]) : NULL;
    if (u0) memcpy(u0, p->uniforms[0], (size_t)p->uniform_size[0]);
    if (u1) memcpy(u1, p->uniforms[1], (size_t)p->uniform_size[1]);
    p->uniforms[0] = u0;
    p->uniforms[1] = u1;
    for (int i = 0; i < 12; i++) /* busy from now, so a glBufferSubData before the flush can't write in place */
        use_buffer(p->ubo[i]);
    for (int i = 0; i < MGL_MAX_SSBOS; i++)
        use_buffer(p->ssbo[i]);
    id<MTLDepthStencilState> ds = get_depth_state(p->depth_test && p->target.depth,
                                                  p->depth_test && p->depth_write && p->target.depth, p->depth_func);
    NSUInteger vertices = (NSUInteger)triangles * (NSUInteger)(max_vertices - 2) * 3;
    gs_play play = ^(id<MTLRenderCommandEncoder> e) {
        rs_reset(); /* replayed into the open pass behind mglb_draw's back */
        [e setRenderPipelineState:ps];
        [e setDepthStencilState:ds];
        [e setViewport:(MTLViewport){p->viewport[0], p->viewport[1], p->viewport[2], p->viewport[3], 0, 1}];
        MTLScissorRect sr = {0, 0, (NSUInteger)p->target.width, (NSUInteger)p->target.height};
        int visible = 1;
        if (p->scissor_enabled) {
            int x0 = p->scissor[0] < 0 ? 0 : p->scissor[0], y0 = p->scissor[1] < 0 ? 0 : p->scissor[1];
            int x1 = p->scissor[0] + p->scissor[2], y1 = p->scissor[1] + p->scissor[3];
            if (x1 > p->target.width) x1 = p->target.width;
            if (y1 > p->target.height) y1 = p->target.height;
            if (x1 <= x0 || y1 <= y0)
                visible = 0;
            else
                sr = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
        }
        if (visible && !gs_probe_no_pass()) {
            [e setScissorRect:sr];
            [e setCullMode:!p->cull ? MTLCullModeNone : p->cull_face == GL_FRONT ? MTLCullModeFront : MTLCullModeBack];
            [e setFrontFacingWinding:p->front_face == GL_CW ? MTLWindingCounterClockwise : MTLWindingClockwise];
            if (p->polygon_offset_enabled)
                [e setDepthBias:p->polygon_offset_units slopeScale:p->polygon_offset_factor clamp:0];
            else
                [e setDepthBias:0 slopeScale:0 clamp:0];
            bind_stage_resources(e, nil, p, 0);
            bind_stage_resources(e, nil, p, 1);
            if (p->uses_scene)
                bind_scene(e, nil);
            [e setVertexBuffer:ovb offset:ovo atIndex:MGL_BUF_INTERNAL_BASE + 6];
            [e setVertexBuffer:ocb offset:oco atIndex:MGL_BUF_INTERNAL_BASE + 7];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices];
        }
        free(u0);
        free(u1);
        free(p);
    };
    if (!gs_pending)
        gs_pending = [NSMutableArray new];
    gs_target = d->target;
    [gs_pending addObject:play];
    if (!gs_batch)
        gs_flush();
    debug_sync("geometry-shader draw", d, triangles, max_vertices);
}

/* Draw the pending geometry-shader draws in one render pass on their target. Called before anything else uses
   the GPU (any encoder, a commit, a barrier, a texture release), so GL's order is kept for everything that
   could see their results. */
static void gs_flush_at(int line)
{
    static int flushing;
    if (!gs_pending.count || flushing)
        return;
    static int flush_log = -1, lines[16], counts[16], total;
    if (flush_log < 0)
        flush_log = getenv("MGL_GS_FLUSH_LOG") && atoi(getenv("MGL_GS_FLUSH_LOG"));
    if (flush_log) {
        int k = 0;
        while (k < 15 && lines[k] && lines[k] != line)
            k++;
        lines[k] = line;
        counts[k]++;
        if (++total == 600) {
            char msg[512];
            int n = snprintf(msg, sizeof msg, "geometry shader batches ended (600, by source line):");
            for (int i = 0; i < 16 && lines[i]; i++)
                n += snprintf(msg + n, sizeof msg - (size_t)n, " %d x%d", lines[i], counts[i]);
            mgl_log("%s; last batch %d draws", msg, (int)gs_pending.count);
            memset(lines, 0, sizeof lines);
            memset(counts, 0, sizeof counts);
            total = 0;
        }
    }
    flushing = 1;
    NSArray<gs_play> *list = gs_pending;
    gs_pending = [NSMutableArray new];
    id<MTLRenderCommandEncoder> e = pass_for(&gs_target);
    if (gs_fence_armed) { /* the records' compute job ended when this pass began */
        [e waitForFence:gs_fence beforeStages:MTLRenderStageVertex];
        gs_fence_armed = 0;
    }
    for (gs_play f in list)
        f(e);
    flushing = 0;
}

/* ================================================================ ray tracing (step 2) */

/* One primitive acceleration structure per terrain section, cached by (buffer, range, block-id offset) until the
   bytes it was built from are written (mglb_rt_forget).

   A new section is built for a fast build (PreferFastBuild), every triangle non-opaque, so turning, which keeps
   bringing sections into view, costs as little as it can. Once a section has stayed ~1.5 s it is built again for
   fast tracing (PreferFastIntersection when built with the macOS 26 SDK), with its solid triangles in an opaque geometry: rays then
   take those hits in the ray hardware, and only cutout triangles (grass, leaves, flowers) come back to mcm_trace's
   alpha test. Solid means the triangle's whole texture rectangle passes that test, read from a map of the block
   atlas's lowest alpha per 8x8 texels (rt_alpha_tiles). Both geometries hold every triangle in the same order
   (each triangle collapsed to a point in the geometry it is not in), so primitive ids still index the per-triangle
   data. Sections that are all solid or all cutout keep one geometry. */
@interface RtSection : NSObject
@property(nonatomic, strong) id<MTLAccelerationStructure> as;
@property(nonatomic) uint64_t last_frame;
@property(nonatomic) mglb_buffer *tris; /* per-triangle texture coordinates + alpha cutoff (rt_decode); then 2 counts */
@property(nonatomic) mglb_buffer *lights; /* light candidates: count, then (position, id) per face */
@property(nonatomic) uint32_t lcap;
@property(nonatomic) int ntris;
@property(nonatomic) uint64_t built_frame;
@property(nonatomic) int state; /* 0 fast build, not counted; 1 fast build, solid/cutout counted; 2 built for tracing */
/* this frame's build, between the decode pass and the build pass */
@property(nonatomic) mglb_buffer *pos;
@property(nonatomic, strong) MTLPrimitiveAccelerationStructureDescriptor *desc;
@end
@implementation RtSection
- (void)dealloc
{
    mglb_buffer_release(_tris);
    mglb_buffer_release(_lights);
    mglb_buffer_release(_pos);
}
@end
static mglb_buffer *rt_inst;                    /* GPU address of each scene instance's triangle data */
static __unsafe_unretained id<MTLResource> *rt_tris_c;
static NSUInteger rt_tris_n;

mglb_buffer *mglb_rt_instances(void) { return rt_inst; }

typedef struct rt_key {
    void *vbuf, *ibuf;
    uint64_t vbase, ioff;
    int32_t stride, itype, count, base_vertex;
    uint32_t gen;
    int32_t ent_off;
    uint32_t translucent;
    int32_t lmin, lmax;
} rt_key;

static id<MTLAccelerationStructure> rt_scene;
static NSMutableArray<id<MTLAccelerationStructure>> *rt_scene_parts; /* must be resident wherever the scene is used */
static __unsafe_unretained id<MTLResource> *rt_parts_c;               /* same objects as a C array for useResources */
static NSUInteger rt_parts_n;
static uint64_t rt_frame;

/* Objects the last few frames' GPU work may still use (a section forgotten or rebuilt): kept 8 frames */
static NSMutableArray *rt_retired[8];
static void rt_retire(id o)
{
    if (!o)
        return;
    NSMutableArray *a = rt_retired[rt_frame % 8];
    if (!a)
        a = rt_retired[rt_frame % 8] = [NSMutableArray new]; /* no autorelease: may run outside any pool */
    [a addObject:o];
}

/* The section cache: open addressing on the key bytes (an NSDictionary with an NSData key per lookup cost
   ~0.5 us a section, every frame). Slots: h 0 = empty, sec NULL with h set = deleted. */
typedef struct rt_slot {
    rt_key k;
    uint64_t h;
    void *sec; /* RtSection, retained */
} rt_slot;
static rt_slot *rt_tab;
static size_t rt_tab_cap, rt_tab_live, rt_tab_dead;
static uint64_t rt_buf_seen[64]; /* buffers some cached section was built from (hashed bits), for mglb_rt_forget */

static uint64_t rt_key_hash(const rt_key *k)
{
    const unsigned char *p = (const unsigned char *)k;
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < sizeof *k; i++)
        h = (h ^ p[i]) * 1099511628211ull;
    return h ? h : 1;
}

static unsigned rt_buf_bit(const void *b) { return (unsigned)(((uintptr_t)b >> 4) * 2654435761u >> 20) & 4095u; }

static void rt_tab_insert(const rt_key *k, uint64_t h, RtSection *s);
static void rt_tab_grow(void)
{
    rt_slot *old = rt_tab;
    size_t oc = rt_tab_cap;
    rt_tab_cap = oc ? (rt_tab_live * 4 > oc ? oc * 2 : oc) : 4096;
    rt_tab = calloc(rt_tab_cap, sizeof *rt_tab);
    rt_tab_live = rt_tab_dead = 0;
    memset(rt_buf_seen, 0, sizeof rt_buf_seen);
    for (size_t i = 0; i < oc; i++)
        if (old[i].sec) {
            RtSection *s = (__bridge_transfer RtSection *)old[i].sec;
            rt_tab_insert(&old[i].k, old[i].h, s);
        }
    free(old);
}

static void rt_tab_insert(const rt_key *k, uint64_t h, RtSection *s)
{
    if (!rt_tab_cap || (rt_tab_live + rt_tab_dead + 1) * 10 > rt_tab_cap * 7)
        rt_tab_grow();
    size_t m = rt_tab_cap - 1, at = (size_t)h & m;
    while (rt_tab[at].h)
        at = (at + 1) & m;
    rt_tab[at].k = *k;
    rt_tab[at].h = h;
    rt_tab[at].sec = (__bridge_retained void *)s;
    rt_tab_live++;
    unsigned a = rt_buf_bit(k->vbuf), b = rt_buf_bit(k->ibuf);
    rt_buf_seen[a >> 6] |= 1ull << (a & 63);
    rt_buf_seen[b >> 6] |= 1ull << (b & 63);
}

static RtSection *rt_tab_find(const rt_key *k, uint64_t h)
{
    if (!rt_tab_cap)
        return nil;
    size_t m = rt_tab_cap - 1;
    for (size_t at = (size_t)h & m; rt_tab[at].h; at = (at + 1) & m)
        if (rt_tab[at].h == h && rt_tab[at].sec && !memcmp(&rt_tab[at].k, k, sizeof *k))
            return (__bridge RtSection *)rt_tab[at].sec;
    return nil;
}

static void rt_tab_drop(size_t at)
{
    RtSection *s = (__bridge_transfer RtSection *)rt_tab[at].sec;
    rt_tab[at].sec = NULL; /* h stays: probes keep going past it */
    rt_tab_live--;
    rt_tab_dead++;
    rt_retire(s);
}

void mglb_rt_forget(mglb_buffer *b, size_t offset, size_t size)
{
    unsigned bit = rt_buf_bit(b);
    if (!rt_tab_live || !(rt_buf_seen[bit >> 6] >> (bit & 63) & 1))
        return;
    uint64_t lo = offset, hi = size == (size_t)-1 ? UINT64_MAX : offset + size;
    for (size_t i = 0; i < rt_tab_cap; i++) {
        const rt_key *k = &rt_tab[i].k;
        if (!rt_tab[i].sec || (k->vbuf != b && k->ibuf != b))
            continue;
        int hit = 0;
        if (k->vbuf == b) { /* Sodium draws quads: 4 vertices per 6 indices, from the base vertex */
            int64_t vlo = (int64_t)k->vbase + (int64_t)k->base_vertex * k->stride;
            int64_t vhi = vlo + (int64_t)k->count * 2 / 3 * k->stride;
            hit |= (int64_t)lo < vhi && (hi == UINT64_MAX || (int64_t)hi > vlo);
        }
        if (k->ibuf == b) {
            uint64_t ilo = k->ioff, ihi = ilo + (uint64_t)k->count * (k->itype == GL_UNSIGNED_SHORT ? 2 : 4);
            hit |= lo < ihi && hi > ilo;
        }
        if (hit)
            rt_tab_drop(i);
    }
}

static id<MTLComputePipelineState> builtin_compute(NSString *name);

/* Acceleration-structure passes, timed and named for MGL_PROFILE=2/3 like the others */
static id<MTLAccelerationStructureCommandEncoder> as_encoder(const char *label)
{
    prof_serialize();
    end_encoders();
    id<MTLCommandBuffer> c = current_cb();
    int k = pt_pass(label);
    id<MTLAccelerationStructureCommandEncoder> e;
    @autoreleasepool {
        if (k >= 0) {
            MTLAccelerationStructurePassDescriptor *d = [MTLAccelerationStructurePassDescriptor accelerationStructurePassDescriptor];
            d.sampleBufferAttachments[0].sampleBuffer = pt_cur->sb;
            d.sampleBufferAttachments[0].startOfEncoderSampleIndex = (NSUInteger)k * 2;
            d.sampleBufferAttachments[0].endOfEncoderSampleIndex = (NSUInteger)k * 2 + 1;
            e = [c accelerationStructureCommandEncoderWithDescriptor:d];
        } else {
            e = [c accelerationStructureCommandEncoder];
        }
    }
    return e;
}

static id<MTLAccelerationStructure> new_as(MTLAccelerationStructureDescriptor *desc)
{
    MTLAccelerationStructureSizes sz = [dev accelerationStructureSizesWithDescriptor:desc];
    return [dev newAccelerationStructureWithSize:sz.accelerationStructureSize];
}

/* encode a build of as (made by new_as from the same descriptor) */
static void encode_build(id<MTLAccelerationStructureCommandEncoder> e, id<MTLAccelerationStructure> as,
                         MTLAccelerationStructureDescriptor *desc)
{
    MTLAccelerationStructureSizes sz = [dev accelerationStructureSizesWithDescriptor:desc];
    mglb_buffer *scratch = mglb_buffer_new(sz.buildScratchBufferSize ? sz.buildScratchBufferSize : 16);
    if (!scratch)
        return;
    [e buildAccelerationStructure:as descriptor:desc scratchBuffer:OBJ(id<MTLBuffer>, scratch->mtl) scratchBufferOffset:0];
    use_buffer(scratch);
    mglb_buffer_release(scratch);
}

static id<MTLAccelerationStructure> build_as(MTLAccelerationStructureDescriptor *desc, const char *label)
{
    id<MTLAccelerationStructure> as = new_as(desc);
    if (!as)
        return nil;
    id<MTLAccelerationStructureCommandEncoder> e = as_encoder(label);
    encode_build(e, as, desc);
    [e endEncoding];
    return as;
}

static unsigned long rt_built, rt_built_tris; /* section structures built since the last MGL_RT_DEBUG line */
static unsigned long rt_rebuilt; /* of those, ranges built before (vertex data rewritten, or another block-id offset) */
static unsigned long rt_upgraded, rt_upgraded_tris, rt_split, rt_solid; /* rebuilt for tracing; of them split / all solid */
static NSMutableSet<NSData *> *rt_ranges; /* MGL_RT_DEBUG=1: every range built, without generation and offsets */

/* Lowest atlas alpha per 8x8 texels (one byte each), for rt_decode's solid test; remade when the atlas changes */
static mglb_buffer *rt_tiles;
static uint32_t rt_tiles_w, rt_tiles_h, rt_tiles_aw, rt_tiles_ah;
static const void *rt_tiles_of; /* the MTLTexture it was made from */

static void rt_alpha_tiles(void)
{
    mglb_texture *t = mgl_rt_atlas;
    if (!t || t->d.type != MGLT_2D || is_int_format(t->pf) || is_depth_format(t->pf) || t->d.width < 8 || t->d.height < 8)
        return;
    if (rt_tiles && rt_tiles_of == t->mtl && rt_tiles_aw == (uint32_t)t->d.width && rt_tiles_ah == (uint32_t)t->d.height)
        return;
    id<MTLComputePipelineState> ps = builtin_compute(@"rt_alpha_tiles");
    uint32_t tw = ((uint32_t)t->d.width + 7) / 8, th = ((uint32_t)t->d.height + 7) / 8;
    mglb_buffer *b = ps ? mglb_buffer_new((size_t)tw * th) : NULL;
    if (!b)
        return;
    uint32_t dims[2] = {tw, th};
    id<MTLComputeCommandEncoder> c = compute_encoder();
    pt_label("rt alpha map");
    [c setComputePipelineState:ps];
    [c setTexture:OBJ(id<MTLTexture>, t->mtl) atIndex:0];
    [c setBuffer:OBJ(id<MTLBuffer>, b->mtl) offset:0 atIndex:0];
    [c setBytes:dims length:sizeof dims atIndex:1];
    [c dispatchThreads:MTLSizeMake(tw, th, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [c memoryBarrierWithScope:MTLBarrierScopeBuffers];
    use_buffer(b);
    mglb_buffer_release(rt_tiles); /* the pool keeps it until the GPU is done with it */
    rt_tiles = b;
    rt_tiles_w = tw;
    rt_tiles_h = th;
    rt_tiles_aw = (uint32_t)t->d.width;
    rt_tiles_ah = (uint32_t)t->d.height;
    rt_tiles_of = t->mtl;
    mgl_log("ray tracing: atlas %dx%d alpha map made (solid triangles become opaque for rays)", t->d.width, t->d.height);
}

/* A/B switches for the M3: MGL_RT_UPGRADE=0 builds sections once, default build, all non-opaque (as before);
   MGL_RT_OPAQUE=0 still rebuilds settled sections for tracing but keeps every triangle non-opaque */
static int rt_opt(const char *name)
{
    const char *v = getenv(name);
    return !v || atoi(v) != 0;
}
static int rt_upgrade_on(void)
{
    static int on = -1;
    if (on < 0)
        on = rt_opt("MGL_RT_UPGRADE");
    return on;
}
static int rt_opaque_on(void)
{
    static int on = -1;
    if (on < 0)
        on = rt_opt("MGL_RT_OPAQUE");
    return on;
}

static rt_key make_key(const mgl_rt_geom *g)
{
    rt_key k;
    memset(&k, 0, sizeof k);
    k.vbuf = g->vbuf;
    k.ibuf = g->ibuf;
    k.vbase = g->vbase;
    k.ioff = g->ioff;
    k.stride = g->stride;
    k.itype = g->itype;
    k.count = g->count;
    k.base_vertex = g->base_vertex;
    k.gen = g->gen;
    k.ent_off = g->ent_off;
    k.translucent = (uint32_t)g->translucent;
    k.lmin = mgl_rt_light_ids[0];
    k.lmax = mgl_rt_light_ids[1];
    return k;
}

/* rt_decode's arguments (RtInfo in the built-in MSL) */
typedef struct rt_info {
    uint32_t vbase, stride, ioff, itype, count;
    int32_t base_vertex, ent_off;
    uint32_t translucent;
    int32_t lmin, lmax;
    uint32_t lcap;
    uint32_t tw, th, aw, ah; /* alpha map (tw 0 = none) */
    uint32_t split;          /* positions: 0 one list; n = solid triangles' list, then cutout's, n each */
    uint32_t flags;          /* 1 write per-triangle data + light candidates, 2 count solid / cutout */
} rt_info;

/* decode a section's vertices into a position list for its build (and, with records, its per-triangle data) */
static void encode_decode(id<MTLComputeCommandEncoder> c, const mgl_rt_geom *g, RtSection *s, uint32_t split, int records)
{
    id<MTLComputePipelineState> ps = builtin_compute(@"rt_decode");
    int tris = s.ntris;
    uint32_t *counts = (uint32_t *)((char *)s.tris->ptr + (size_t)tris * 48);
    counts[0] = counts[1] = 0;
    rt_info info = {(uint32_t)g->vbase, (uint32_t)g->stride, (uint32_t)g->ioff, g->itype == GL_UNSIGNED_SHORT ? 2u : 4u,
                    (uint32_t)(tris * 3), g->base_vertex, g->ent_off, g->translucent ? 1u : 0u,
                    mgl_rt_light_ids[0], mgl_rt_light_ids[1], records ? s.lcap : 0,
                    rt_tiles ? rt_tiles_w : 0, rt_tiles_h, rt_tiles_aw, rt_tiles_ah, split,
                    (records ? 1u : 0u) | (rt_tiles ? 2u : 0u)};
    [c setComputePipelineState:ps];
    [c setBuffer:OBJ(id<MTLBuffer>, g->vbuf->mtl) offset:0 atIndex:0];
    [c setBuffer:OBJ(id<MTLBuffer>, g->ibuf->mtl) offset:0 atIndex:1];
    [c setBuffer:OBJ(id<MTLBuffer>, s.pos->mtl) offset:0 atIndex:2];
    [c setBytes:&info length:sizeof info atIndex:3];
    [c setBuffer:OBJ(id<MTLBuffer>, s.tris->mtl) offset:0 atIndex:4];
    [c setBuffer:OBJ(id<MTLBuffer>, (s.lights ? s.lights : s.tris)->mtl) offset:0 atIndex:5];
    [c setBuffer:OBJ(id<MTLBuffer>, s.tris->mtl) offset:(NSUInteger)tris * 48 atIndex:6];
    [c setBuffer:OBJ(id<MTLBuffer>, (rt_tiles ? rt_tiles : s.tris)->mtl) offset:0 atIndex:7];
    [c dispatchThreads:MTLSizeMake((NSUInteger)tris, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    use_buffer(s.tris);
    use_buffer(s.lights);
    use_buffer(rt_tiles);
    use_buffer(g->vbuf);
    use_buffer(g->ibuf);
    use_buffer(s.pos);
}

static MTLAccelerationStructureTriangleGeometryDescriptor *tri_geometry(mglb_buffer *pos, size_t first, int tris, BOOL opaque)
{
    MTLAccelerationStructureTriangleGeometryDescriptor *tg = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    tg.vertexBuffer = OBJ(id<MTLBuffer>, pos->mtl);
    tg.vertexBufferOffset = first * 36;
    tg.vertexStride = 12;
    tg.vertexFormat = MTLAttributeFormatFloat3;
    tg.triangleCount = (NSUInteger)tris;
    tg.opaque = opaque; /* NO: mcm_trace runs the alpha test on the hit */
    return tg;
}

/* A section seen for the first time: its structure object now (the scene this frame refers to it), its decode and
   build encoded later in this frame's batches */
static RtSection *section_new(const mgl_rt_geom *g, const rt_key *k, uint64_t h)
{
    int tris = g->count / 3;
    if (tris <= 0 || !builtin_compute(@"rt_decode"))
        return nil;
    rt_built++;
    rt_built_tris += (unsigned long)tris;
    if (getenv("MGL_RT_DEBUG") && atoi(getenv("MGL_RT_DEBUG"))) {
        rt_key r = *k;
        r.gen = 0;
        r.ent_off = 0;
        r.lmin = r.lmax = 0;
        NSData *rk = [[NSData alloc] initWithBytes:&r length:sizeof r];
        if (!rt_ranges)
            rt_ranges = [NSMutableSet set];
        if ([rt_ranges containsObject:rk])
            rt_rebuilt++;
        else
            [rt_ranges addObject:rk];
    }
    RtSection *s = [RtSection new];
    s.ntris = tris;
    s.tris = mglb_buffer_new((size_t)tris * 48 + 16); /* + solid / cutout counts */
    uint32_t lcap = mgl_rt_light_ids[0] >= 0 && g->ent_off >= 0 ? (uint32_t)(tris < 1024 ? tris : 1024) : 0;
    s.lights = lcap ? mglb_buffer_new(16 + (size_t)lcap * 16) : NULL;
    if (!s.lights)
        lcap = 0;
    else
        *(uint32_t *)s.lights->ptr = 0; /* candidate count */
    s.lcap = lcap;
    s.pos = mglb_buffer_new((size_t)tris * 36);
    if (!s.tris || !s.pos)
        return nil;
    MTLPrimitiveAccelerationStructureDescriptor *pd = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    /* placeholder buffer for the size query; the real one is set once decoded */
    pd.geometryDescriptors = @[ tri_geometry(s.tris, 0, tris, NO) ];
    pd.usage = rt_upgrade_on() ? MTLAccelerationStructureUsagePreferFastBuild : MTLAccelerationStructureUsageNone;
    s.as = new_as(pd);
    if (!s.as)
        return nil;
    s.desc = pd;
    s.last_frame = s.built_frame = rt_frame;
    s.state = rt_tiles ? 1 : 0;
    rt_tab_insert(k, h, s);
    return s;
}

/* A section kept long enough: build it again for tracing (see the top of this part) */
static void section_upgrade(RtSection *s)
{
    int tris = s.ntris;
    const uint32_t *counts = (const uint32_t *)((const char *)s.tris->ptr + (size_t)tris * 48);
    uint32_t solid = s.state == 1 ? counts[0] : 0, cut = s.state == 1 ? counts[1] : (uint32_t)tris;
    if (solid + cut != (uint32_t)tris || !rt_opaque_on()) /* not counted (no atlas map yet): all cutout */
        solid = 0, cut = (uint32_t)tris;
    MTLPrimitiveAccelerationStructureDescriptor *pd = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    int split = solid && cut;
    if (split) {
        pd.geometryDescriptors = @[ tri_geometry(s.tris, 0, tris, YES), tri_geometry(s.tris, (size_t)tris, tris, NO) ];
        rt_split++;
    } else {
        pd.geometryDescriptors = @[ tri_geometry(s.tris, 0, tris, solid ? YES : NO) ];
        rt_solid += solid ? 1 : 0;
    }
#if defined(__MAC_26_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_26_0
    if (@available(macOS 26.0, *)) /* older SDKs: the default build, already better for tracing than the first */
        pd.usage = MTLAccelerationStructureUsagePreferFastIntersection;
#endif
    id<MTLAccelerationStructure> as = new_as(pd);
    mglb_buffer *pos = as ? mglb_buffer_new((size_t)tris * 36 * (split ? 2 : 1)) : NULL;
    if (!pos)
        return;
    mglb_buffer_release(s.pos);
    s.pos = pos;
    rt_retire(s.as);
    s.as = as;
    s.desc = pd;
    /* not counted before (no alpha map at its first build) but there is one now: count while decoding, and come
       back once more for the split */
    s.state = s.state == 0 && rt_tiles && rt_opaque_on() ? 1 : 2;
    s.built_frame = rt_frame;
    rt_upgraded++;
    rt_upgraded_tris += (unsigned long)tris;
}

/* The light list for mcm_lights_near (layout in core/mgl_program.c): every section's light candidates, one light
   per block, then a grid of the lights each 4-block cell can reach. Rebuilt each frame, on the GPU. */
#define RT_LIGHTS_BYTES (16 + 2048 * 16 + 16 * 16 * 16 * 17 * 4)
static mglb_buffer *rt_lights_buf;

mglb_buffer *mglb_rt_lights(void)
{
    if (!rt_lights_buf && (rt_lights_buf = mglb_buffer_new(RT_LIGHTS_BYTES)))
        memset(rt_lights_buf->ptr, 0, RT_LIGHTS_BYTES); /* no lights yet */
    return rt_lights_buf;
}

static id<MTLComputePipelineState> builtin_compute(NSString *name)
{
    static NSMutableDictionary<NSString *, id<MTLComputePipelineState>> *cache;
    if (!cache)
        cache = [NSMutableDictionary dictionary];
    id<MTLComputePipelineState> ps = cache[name];
    if (!ps) {
        NSError *e = nil;
        id<MTLFunction> f = builtin(name);
        ps = f ? [dev newComputePipelineStateWithFunction:f error:&e] : nil;
        if (!ps) {
            mgl_log("%s pipeline: %s", name.UTF8String, e ? e.localizedDescription.UTF8String : "no function");
            return nil;
        }
        cache[name] = ps;
    }
    return ps;
}

static void rt_build_lights(const mgl_rt_geom *g, RtSection *__strong *secs, const int *sec_geom, int count)
{
    if (mgl_rt_light_ids[0] < 0)
        return;
    static int debug = -1;
    if (debug < 0)
        debug = getenv("MGL_RT_DEBUG") && atoi(getenv("MGL_RT_DEBUG"));
    if (debug && rt_frame % 120 == 0) { /* MGL_RT_DEBUG: candidates found by rt_decode, lights in the last list */
        unsigned long cand = 0, with = 0;
        for (int i = 0; i < count; i++)
            if (secs[i].lights) {
                with++;
                cand += *(const uint32_t *)secs[i].lights->ptr;
            }
        const uint32_t *l = rt_lights_buf ? (const uint32_t *)rt_lights_buf->ptr : NULL;
        const float *f = l ? (const float *)(l + 4) : NULL;
        mgl_log("rt debug: light ids %d-%d: %lu of %d sections can hold lights, %lu candidates, last list %u lights%s",
                mgl_rt_light_ids[0], mgl_rt_light_ids[1], with, count, cand, l ? l[0] : 0, l && l[0] ? ":" : "");
        for (uint32_t i = 0; l && i < l[0] && i < 4; i++)
            mgl_log("rt debug:   light %u at %.1f %.1f %.1f, id %.0f", i, f[i * 4], f[i * 4 + 1], f[i * 4 + 2], f[i * 4 + 3]);
    }
    id<MTLComputePipelineState> pl = builtin_compute(@"rt_lights"), pg = builtin_compute(@"rt_light_grid");
    mglb_buffer *lb = mglb_buffer_new(RT_LIGHTS_BYTES), *hash = mglb_buffer_new(8192 * 4);
    if (!pl || !pg || !lb || !hash) {
        mglb_buffer_release(lb);
        mglb_buffer_release(hash);
        return;
    }
    id<MTLBlitCommandEncoder> b = blit_encoder_for(NULL, NULL);
    [b fillBuffer:OBJ(id<MTLBuffer>, lb->mtl) range:NSMakeRange(0, RT_LIGHTS_BYTES) value:0];
    [b fillBuffer:OBJ(id<MTLBuffer>, hash->mtl) range:NSMakeRange(0, 8192 * 4) value:0];
    id<MTLComputeCommandEncoder> c = compute_encoder();
    [c setComputePipelineState:pl];
    [c setBuffer:OBJ(id<MTLBuffer>, hash->mtl) offset:0 atIndex:2];
    [c setBuffer:OBJ(id<MTLBuffer>, lb->mtl) offset:0 atIndex:3];
    const float *r0 = count ? g[sec_geom[0]].region : NULL;
    for (int i = 0; i < count; i++) {
        RtSection *s = secs[i];
        if (!s.lights)
            continue;
        const float *r = g[sec_geom[i]].region;
        /* sections sit on the block grid, so their offsets from the first one are whole blocks */
        struct { int32_t off[4]; float region[4]; uint32_t cap, pad[3]; } info = {
            {(int32_t)lroundf(r[0] - r0[0]), (int32_t)lroundf(r[1] - r0[1]), (int32_t)lroundf(r[2] - r0[2]), 0},
            {r[0], r[1], r[2], 0}, s.lcap, {0, 0, 0}};
        [c setBuffer:OBJ(id<MTLBuffer>, s.lights->mtl) offset:0 atIndex:0];
        [c setBytes:&info length:sizeof info atIndex:1];
        [c dispatchThreads:MTLSizeMake(s.lcap, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        use_buffer(s.lights);
    }
    [c memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [c setComputePipelineState:pg];
    [c setBuffer:OBJ(id<MTLBuffer>, lb->mtl) offset:0 atIndex:0];
    [c dispatchThreads:MTLSizeMake(2048, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    use_buffer(lb);
    use_buffer(hash);
    mglb_buffer_release(hash);
    mglb_buffer_release(rt_lights_buf); /* the pool keeps it until the GPU is done with it */
    rt_lights_buf = lb;
}

/* Entities (mgl_rt.c): one acceleration structure rebuilt every frame, since they move. Their triangles carry no
   atlas texture (entity skins live elsewhere): flag 0x200 makes mcm_trace_hit use the colour alone, a mid grey. */
static float *rt_ent;
static int rt_ent_n, rt_ent_cap;
static mglb_buffer *rt_ent_tris; /* the record buffer in use by the current scene */

void mglb_rt_dynamic(const float *tris, int n)
{
    if (n > rt_ent_cap) {
        rt_ent_cap = n * 2;
        rt_ent = realloc(rt_ent, sizeof(float) * 9 * (size_t)rt_ent_cap);
    }
    if (n)
        memcpy(rt_ent, tris, sizeof(float) * 9 * (size_t)n);
    rt_ent_n = n;
}

static id<MTLAccelerationStructure> entity_as(mglb_buffer **tris_out)
{
    int n = rt_ent_n;
    mglb_buffer *pos = mglb_buffer_new((size_t)n * 36), *rec = mglb_buffer_new((size_t)n * 48);
    if (!pos || !rec) {
        mglb_buffer_release(pos);
        mglb_buffer_release(rec);
        return nil;
    }
    memcpy(pos->ptr, rt_ent, (size_t)n * 36);
    uint32_t *r = rec->ptr;
    for (int t = 0; t < n; t++, r += 12) {
        const float *p = rt_ent + (size_t)t * 9;
        float e1[3] = {p[3] - p[0], p[4] - p[1], p[5] - p[2]}, e2[3] = {p[6] - p[0], p[7] - p[1], p[8] - p[2]};
        float c[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        float l1 = fabsf(c[0]) + fabsf(c[1]) + fabsf(c[2]), o[2];
        if (l1 > 0) {
            c[0] /= l1, c[1] /= l1, c[2] /= l1;
        } else
            c[0] = 0, c[1] = 1, c[2] = 0;
        if (c[2] >= 0)
            o[0] = c[0], o[1] = c[1];
        else
            o[0] = (1 - fabsf(c[1])) * (c[0] >= 0 ? 1 : -1), o[1] = (1 - fabsf(c[0])) * (c[1] >= 0 ? 1 : -1);
        memset(r, 0, 48);
        r[3] = 0x200; /* solid, untextured */
        r[4] = r[5] = r[6] = 0xFF999999u;
        r[7] = (uint32_t)(uint16_t)(int16_t)lrintf(o[0] * 32767.0f) | (uint32_t)(uint16_t)(int16_t)lrintf(o[1] * 32767.0f) << 16;
        r[8] = r[9] = r[10] = 0xF000u; /* full sky light, no block light */
    }
    MTLAccelerationStructureTriangleGeometryDescriptor *tg = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    tg.vertexBuffer = OBJ(id<MTLBuffer>, pos->mtl);
    tg.vertexStride = 12;
    tg.vertexFormat = MTLAttributeFormatFloat3;
    tg.triangleCount = (NSUInteger)n;
    tg.opaque = YES; /* solid (cutoff byte 0): the ray hardware takes the hit without asking mcm_trace */
    MTLPrimitiveAccelerationStructureDescriptor *pd = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    pd.geometryDescriptors = @[ tg ];
    pd.usage = MTLAccelerationStructureUsagePreferFastBuild;
    use_buffer(pos);
    id<MTLAccelerationStructure> as = build_as(pd, "rt build entities");
    mglb_buffer_release(pos);
    if (!as) {
        mglb_buffer_release(rec);
        return nil;
    }
    use_buffer(rec);
    *tris_out = rec;
    return as;
}

static void rt_update(const mgl_rt_geom *g, int n);
void mglb_rt_update(const mgl_rt_geom *g, int n)
{
    @autoreleasepool { /* the game's render thread has no pool of its own: descriptors and keys would pile up */
        rt_update(g, n);
    }
}

/* MCMETAL_RT_RADIUS: is the section's centre within the radius (plus 14 = half its diagonal) of the camera?
   Sodium's section index sits in the top byte of word 4 of every vertex; unreadable buffers count as in reach. */
static int section_in_reach(const mgl_rt_geom *g)
{
    const unsigned char *vp = mglb_buffer_ptr(g->vbuf);
    if (!vp)
        return 1;
    uint32_t sec = ((const uint32_t *)(vp + g->vbase + (size_t)g->base_vertex * (size_t)g->stride))[4] >> 24;
    float x = g->region[0] + 16.0f * (float)((sec >> 5) & 7) + 8.0f;
    float y = g->region[1] + 16.0f * (float)(sec & 3) + 8.0f;
    float z = g->region[2] + 16.0f * (float)((sec >> 2) & 7) + 8.0f;
    float r = mgl_rt_radius + 14.0f;
    return x * x + y * y + z * z <= r * r;
}

static void rt_update(const mgl_rt_geom *g, int n)
{
    if (!dev.supportsRaytracing) {
        static int said;
        if (!said++)
            mgl_log("ray tracing: this GPU (%s) has no Metal ray tracing; mcm_trace misses everything",
                    dev.name.UTF8String);
        return;
    }
    rt_frame++;
    [rt_retired[rt_frame % 8] removeAllObjects];
    rt_alpha_tiles();
    NSMutableArray<id<MTLAccelerationStructure>> *parts = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    size_t slots = (size_t)n + 1; /* + the entities */
    mglb_buffer *inst = mglb_buffer_new(sizeof(MTLAccelerationStructureUserIDInstanceDescriptor) * slots);
    if (!inst)
        return;
    MTLAccelerationStructureUserIDInstanceDescriptor *descs = inst->ptr;
    mglb_buffer *table = mglb_buffer_new(8 * slots);
    uint64_t *addr = table->ptr;
    free(rt_tris_c);
    rt_tris_c = (__unsafe_unretained id<MTLResource> *)calloc(slots, sizeof(id));
    int count = 0;
    RtSection *__strong *secs = (RtSection *__strong *)calloc((size_t)(n ? n : 1), sizeof(RtSection *));
    int *sec_geom = calloc((size_t)(n ? n : 1), sizeof(int));
    /* sections to decode and build this frame: new ones (with their per-triangle data) and ones rebuilt for tracing */
    NSMutableArray<RtSection *> *todo = [NSMutableArray array];
    int *todo_geom = calloc((size_t)(n ? n : 1), sizeof(int)), *todo_new = calloc((size_t)(n ? n : 1), sizeof(int));
    int upgrades = 0;
    long upgrade_tris = 0;
    for (int i = 0; i < n; i++) {
        if (mgl_rt_radius > 0 && !section_in_reach(&g[i]))
            continue;
        rt_key k = make_key(&g[i]);
        uint64_t h = rt_key_hash(&k);
        RtSection *sec = rt_tab_find(&k, h);
        if (!sec) {
            if (!(sec = section_new(&g[i], &k, h)))
                continue;
            todo_geom[todo.count] = i;
            todo_new[todo.count] = 1;
            [todo addObject:sec];
        } else if (sec.state < 2 && rt_upgrade_on() && rt_frame - sec.built_frame >= 90 && upgrades < 24 &&
                   upgrade_tris + sec.ntris <= 400000) { /* a few per frame, so standing still settles in ~1 s */
            section_upgrade(sec);
            if (sec.desc) {
                upgrades++;
                upgrade_tris += sec.ntris;
                todo_geom[todo.count] = i;
                todo_new[todo.count] = 0;
                [todo addObject:sec];
            }
        }
        sec.last_frame = rt_frame;
        secs[count] = sec;
        sec_geom[count] = i;
        addr[count] = OBJ(id<MTLBuffer>, sec.tris->mtl).gpuAddress;
        rt_tris_c[count] = OBJ(id<MTLBuffer>, sec.tris->mtl);
        MTLAccelerationStructureUserIDInstanceDescriptor *d = &descs[count];
        memset(d, 0, sizeof *d);
        /* column-major 4x3: identity rotation, translation = camera-relative region origin */
        d->transformationMatrix.columns[0] = MTLPackedFloat3Make(1, 0, 0);
        d->transformationMatrix.columns[1] = MTLPackedFloat3Make(0, 1, 0);
        d->transformationMatrix.columns[2] = MTLPackedFloat3Make(0, 0, 1);
        d->transformationMatrix.columns[3] = MTLPackedFloat3Make(g[i].region[0], g[i].region[1], g[i].region[2]);
        /* no instance Opaque flag: it overrides the geometries' own, so cutout triangles would never reach the
           alpha test in mcm_trace (every hit was solid; foliage cast square shadows) */
        d->options = MTLAccelerationStructureInstanceOptionNone;
        d->mask = g[i].translucent ? 0x02 : 0x01; /* mcm_trace sees solid and cutout terrain only (mask 1) */
        d->accelerationStructureIndex = (uint32_t)count;
        d->userID = (uint32_t)i;
        [parts addObject:sec.as];
        count++;
    }
    /* all decodes in one compute pass, then all builds in one pass (they overlap on the GPU; one pass pair per
       section used to cost two encoder switches each) */
    if (todo.count) {
        id<MTLComputeCommandEncoder> c = compute_encoder();
        pt_label("rt decode");
        for (NSUInteger j = 0; j < todo.count; j++) {
            RtSection *s = todo[j];
            encode_decode(c, &g[todo_geom[j]], s, s.desc.geometryDescriptors.count == 2 ? (uint32_t)s.ntris : 0,
                          todo_new[j]);
        }
        id<MTLAccelerationStructureCommandEncoder> e = as_encoder("rt build sections");
        for (RtSection *s in todo) {
            for (MTLAccelerationStructureGeometryDescriptor *gd in s.desc.geometryDescriptors)
                ((MTLAccelerationStructureTriangleGeometryDescriptor *)gd).vertexBuffer = OBJ(id<MTLBuffer>, s.pos->mtl);
            encode_build(e, s.as, s.desc);
            mglb_buffer_release(s.pos); /* the pool keeps it until the GPU is done with it */
            s.pos = NULL;
            s.desc = nil;
        }
        [e endEncoding];
    }
    free(todo_geom);
    free(todo_new);
    /* forget sections unused for ~4 s */
    if (rt_frame % 60 == 0)
        for (size_t i = 0; i < rt_tab_cap; i++)
            if (rt_tab[i].sec && rt_frame - ((__bridge RtSection *)rt_tab[i].sec).last_frame > 240)
                rt_tab_drop(i);
    rt_build_lights(g, secs, sec_geom, count);
    for (int i = 0; i < count; i++)
        secs[i] = nil;
    free(secs);
    free(sec_geom);
    mglb_buffer *ent_tris = NULL;
    id<MTLAccelerationStructure> ent = count && rt_ent_n ? entity_as(&ent_tris) : nil;
    if (ent) { /* already camera-relative: identity transform; solid, so mask 1 like opaque terrain */
        addr[count] = OBJ(id<MTLBuffer>, ent_tris->mtl).gpuAddress;
        rt_tris_c[count] = OBJ(id<MTLBuffer>, ent_tris->mtl);
        MTLAccelerationStructureUserIDInstanceDescriptor *d = &descs[count];
        memset(d, 0, sizeof *d);
        d->transformationMatrix.columns[0] = MTLPackedFloat3Make(1, 0, 0);
        d->transformationMatrix.columns[1] = MTLPackedFloat3Make(0, 1, 0);
        d->transformationMatrix.columns[2] = MTLPackedFloat3Make(0, 0, 1);
        d->mask = 0x01;
        d->accelerationStructureIndex = (uint32_t)count;
        d->userID = 0xFFFFFFFFu;
        [parts addObject:ent];
        count++;
    }
    use_buffer(rt_ent_tris); /* last frame's draws read it: the pool keeps it until they are done */
    mglb_buffer_release(rt_ent_tris);
    rt_ent_tris = ent_tris;
    if (!count) {
        mglb_buffer_release(table);
        rt_tris_n = 0;
        mglb_buffer_release(inst);
        rt_scene = nil;
        rt_parts_n = 0;
        return;
    }
    MTLInstanceAccelerationStructureDescriptor *idesc = [MTLInstanceAccelerationStructureDescriptor descriptor];
    idesc.instancedAccelerationStructures = parts;
    idesc.instanceCount = (NSUInteger)count;
    idesc.instanceDescriptorBuffer = OBJ(id<MTLBuffer>, inst->mtl);
    idesc.instanceDescriptorType = MTLAccelerationStructureInstanceDescriptorTypeUserID;
    if (rt_scene)
        rt_retire(rt_scene);
    rt_scene = build_as(idesc, "rt build scene");
    rt_scene_parts = parts;
    free(rt_parts_c);
    rt_parts_c = (__unsafe_unretained id<MTLResource> *)calloc((size_t)count, sizeof(id));
    for (int i = 0; i < count; i++)
        rt_parts_c[i] = parts[(NSUInteger)i];
    rt_parts_n = (NSUInteger)count;
    rt_tris_n = (NSUInteger)count;
    use_buffer(inst);
    mglb_buffer_release(inst);
    mglb_buffer_release(rt_inst); /* the pool keeps it until the GPU is done with it */
    rt_inst = table;
    static int logged, debug = -1;
    if (debug < 0)
        debug = getenv("MGL_RT_DEBUG") && atoi(getenv("MGL_RT_DEBUG"));
    if (!logged++ || (debug && rt_frame % 120 == 0))
    {
        mgl_log("ray tracing: scene built from %d of %d terrain sections (%lu cached), %d entity triangles; %lu section "
                "structures (%luk triangles) built in the last %d frames, %lu of them ranges built before; %lu rebuilt "
                "for tracing (%luk triangles: %lu split solid/cutout, %lu all solid)",
                count - (ent ? 1 : 0), n, (unsigned long)rt_tab_live, ent ? rt_ent_n : 0, rt_built,
                rt_built_tris / 1000, logged == 1 ? 1 : 120, rt_rebuilt, rt_upgraded, rt_upgraded_tris / 1000, rt_split,
                rt_solid);
        rt_built = rt_built_tris = rt_rebuilt = rt_upgraded = rt_upgraded_tris = rt_split = rt_solid = 0;
    }
}

static void bind_scene(id<MTLRenderCommandEncoder> e, id<MTLComputeCommandEncoder> c)
{
    if (!rt_scene)
        return;
    if (c) {
        [c setAccelerationStructure:rt_scene atBufferIndex:MGL_BUF_SCENE];
        [c useResources:rt_parts_c count:rt_parts_n usage:MTLResourceUsageRead];
        [c useResources:rt_tris_c count:rt_tris_n usage:MTLResourceUsageRead];
    } else {
        [e setVertexAccelerationStructure:rt_scene atBufferIndex:MGL_BUF_SCENE];
        [e setFragmentAccelerationStructure:rt_scene atBufferIndex:MGL_BUF_SCENE];
        [e useResources:rt_parts_c count:rt_parts_n usage:MTLResourceUsageRead
                 stages:MTLRenderStageVertex | MTLRenderStageFragment];
        [e useResources:rt_tris_c count:rt_tris_n usage:MTLResourceUsageRead
                 stages:MTLRenderStageVertex | MTLRenderStageFragment];
    }
}

void mglb_memory_barrier(void)
{
    gs_flush();
    /* In a render pass, end it: Metal orders work between encoders on the same resources, and in-pass render
       barriers are restricted on Apple GPUs. The next draw reopens the pass with Load. */
    if (renc)
        end_encoders();
    else if (cenc)
        [cenc memoryBarrierWithScope:MTLBarrierScopeTextures | MTLBarrierScopeBuffers];
}

/* Blit between framebuffers. Same size and format: plain copy; otherwise a textured quad. */
void mglb_blit(const mgl_target *src, int src_att, const int sr[4], const mgl_target *dst, const int dr[4], int color,
               int depth, int linear)
{
    if (dump_this_frame())
        mgl_log("frame dump: blit %p -> %p%s colour %d depth %d, %d,%d-%d,%d -> %d,%d-%d,%d", (void *)src->tex[src_att],
                (void *)dst->tex[0], dst->is_default ? " (window)" : "", color, depth, sr[0], sr[1], sr[2], sr[3], dr[0], dr[1],
                dr[2], dr[3]);
    int sx0 = sr[0], sy0 = sr[1], sx1 = sr[2], sy1 = sr[3], dx0 = dr[0], dy0 = dr[1], dx1 = dr[2], dy1 = dr[3];
    if (dx1 < dx0) { int t = dx0; dx0 = dx1; dx1 = t; t = sx0; sx0 = sx1; sx1 = t; }
    if (dy1 < dy0) { int t = dy0; dy0 = dy1; dy1 = t; t = sy0; sy0 = sy1; sy1 = t; }
    int dw = dx1 - dx0, dh = dy1 - dy0;
    if (dw <= 0 || dh <= 0)
        return;
    int straight = sx1 - sx0 == dw && sy1 - sy0 == dh;
    if (depth && src->depth && dst->depth) {
        if (straight && src->depth->pf == dst->depth->pf)
            mglb_texture_copy(src->depth, src->depth_level, sx0, sy0, 0, dst->depth, dst->depth_level, dx0, dy0, 0, dw, dh, 1);
        else
            mgl_log("scaled depth blit not supported");
    }
    if (!color || !src->tex[src_att])
        return;
    mglb_texture *s = src->tex[src_att];
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++) {
        mglb_texture *t = dst->tex[i];
        if (!t)
            continue;
        if (straight && t->pf == s->pf) {
            mglb_texture_copy(s, src->level[src_att], sx0, sy0, src->layer[src_att], t, dst->level[i], dx0, dy0,
                              dst->layer[i], dw, dh, 1);
            continue;
        }
        mgl_target one = {0};
        one.tex[0] = t;
        one.level[0] = dst->level[i];
        one.layer[0] = dst->layer[i];
        one.width = dst->width;
        one.height = dst->height;
        id<MTLRenderCommandEncoder> e = begin_pass(&one, 0, NULL, 0, 0);
        id<MTLRenderPipelineState> ps = blit_pipeline(t->pf);
        if (!ps)
            return;
        [e setRenderPipelineState:ps];
        [e setViewport:(MTLViewport){dx0, dy0, dw, dh, 0, 1}];
        float sw = (float)(s->d.width >> src->level[src_att]), sh = (float)(s->d.height >> src->level[src_att]);
        float rect[4] = {sx0 / sw, sy0 / sh, sx1 / sw, sy1 / sh}; /* uv at the viewport's top-left and bottom-right */
        [e setVertexBytes:rect length:sizeof rect atIndex:0];
        [e setFragmentTexture:OBJ(id<MTLTexture>, s->mtl) atIndex:0];
        [e setFragmentSamplerState:blit_sampler(linear) atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        end_encoders();
    }
}

/* ================================================================ fences and flushing */

uint64_t mglb_fence(void)
{
    return cb ? cb_serial : submitted_serial;
}

static uint64_t now_ns(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

static int wait_serial(uint64_t id, uint64_t timeout_ns, uint64_t start);

int mglb_fence_wait(uint64_t id, uint64_t timeout_ns)
{
    if (atomic_load(&completed_serial) >= id)
        return 1;
    if (!timeout_ns)
        return 0;
    if (cb && id >= cb_serial)
        commit();
    uint64_t start = now_ns();
    int r = wait_serial(id, timeout_ns, start);
    prof.wait_ns += now_ns() - start;
    pace_wait_ns += now_ns() - start;
    return r;
}

static int wait_serial(uint64_t id, uint64_t timeout_ns, uint64_t start)
{
    if (opt_pacing > 0) { /* sleep until a command buffer completes instead of spinning */
        pthread_mutex_lock(&fence_lock);
        while (atomic_load(&completed_serial) < id) {
            uint64_t t = now_ns();
            if (t - start > timeout_ns)
                break;
            struct timespec until;
            clock_gettime(CLOCK_REALTIME, &until);
            uint64_t step = timeout_ns - (t - start) < 2000000ull ? timeout_ns - (t - start) : 2000000ull;
            until.tv_nsec += (long)step;
            until.tv_sec += until.tv_nsec / 1000000000L;
            until.tv_nsec %= 1000000000L;
            pthread_cond_timedwait(&fence_cond, &fence_lock, &until);
        }
        pthread_mutex_unlock(&fence_lock);
        return atomic_load(&completed_serial) >= id;
    }
    while (atomic_load(&completed_serial) < id) {
        if (now_ns() - start > timeout_ns)
            return 0;
        usleep(20);
    }
    return 1;
}

void mglb_flush(void) { commit(); }

void mglb_finish(void)
{
    commit();
    uint64_t t = now_ns();
    [last_cb waitUntilCompleted];
    prof.wait_ns += now_ns() - t;
    pace_wait_ns += now_ns() - t;
    prof.finishes++;
}

/* ================================================================ window: GLFW glue and present */

typedef struct mgl_ctx {
    CAMetalLayer *layer;
    int w, h;
    uint64_t frames;
    int vsync;
    uint64_t last_swap_ns;
    double avg_frame_ms;    /* smoothed frame cost (max of CPU work and GPU time), for choosing the paced rate */
    uint64_t last_wait_ns, last_gpu_ns;
    int paced_fps;
    uint64_t window_start_ns, stepped_up_ns, no_up_until_ns; /* see choose_paced_fps */
    uint64_t grace_until_ns;
    int bad_windows, blocked_fps;
    unsigned up_backoff_s;
    double win_cost[64];    /* this half second's frame costs, for their median */
    int win_n;
} mgl_ctx;

/* Even frame delivery: on a 120 Hz ProMotion screen a game that makes 47 fps shows frames for 17 and 25 ms in
   turn (judder, measured 70-80% of frames for SEUS on an M3). Presenting with a minimum duration at one of
   120/60/40/30/24/20/15 keeps every frame on screen equally long. With vsync off, pacing stays off.
   The rate follows missed deadlines, not a cost estimate alone: Apple GPUs clock down when pacing leaves them idle,
   so a frame measured at 22 ms while paced at 30 still fits 40. Every half second (a window):
   - down one rate after two windows in a row where over 10% of frames stayed on screen longer than 1.25x the
     target, and only when the cost is over 60% of the budget (cheap frames that miss are hitches, e.g. chunk
     loading, which a slower rate wouldn't fix); misses in the first second after a change don't count;
   - up straight to the fastest rate the cost fits with 25% to spare, or else one rate up if it fits at all,
     unless a try at that rate failed recently (a step down within 3 s of stepping up: that rate is left alone
     for 10, 20, 40, then 80 s while tries keep failing, so a pack right at a boundary rarely hitches). */
static _Atomic double pace_target_ms;     /* read by the presented handler */
static _Atomic unsigned pace_shown, pace_missed;

static void pace_presented(double iv_ms)
{
    double target = atomic_load(&pace_target_ms);
    if (target <= 0)
        return;
    atomic_fetch_add(&pace_shown, 1);
    if (iv_ms > target * 1.25)
        atomic_fetch_add(&pace_missed, 1);
}

/* Low Power Mode and heat (MGL_POWER_ADAPT=0 turns this off): with pacing on, cap the paced rate at 60 fps in
   Low Power Mode or when macOS reports the Mac as seriously hot, and at 30 when critical, so the game backs off
   evenly instead of the system throttling the GPU under it at random. Changes are logged as they happen. */
static int power_cap_fps(void)
{
    static int adapt = -1, last_cap = -1;
    if (adapt < 0) {
        const char *e = getenv("MGL_POWER_ADAPT");
        adapt = !e || atoi(e) != 0;
    }
    if (!adapt)
        return 0;
    static unsigned calls;
    if (calls++ % 60) /* look about once a second */
        return last_cap > 0 ? last_cap : 0;
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSProcessInfoThermalState th = pi.thermalState;
    BOOL low = pi.lowPowerModeEnabled;
    int cap = th >= NSProcessInfoThermalStateCritical ? 30 : (low || th >= NSProcessInfoThermalStateSerious) ? 60 : 0;
    if (cap != last_cap) {
        static const char *names[] = {"nominal", "fair", "serious", "critical"};
        char capstr[16] = "none";
        if (cap)
            snprintf(capstr, sizeof capstr, "%d fps", cap);
        mgl_log("power: Low Power Mode %s, thermal state %s, frame rate cap %s", low ? "on" : "off",
                th >= 0 && th <= 3 ? names[th] : "?", capstr);
        last_cap = cap;
    }
    return cap;
}

/* Even presenting rates, fastest first. Down to 15: a heavy pack panning (SEUS ~20 real fps) paced at 30 got
   deadlines it never met and showed 13-16 uneven fps; 20 is even, and with interpolation 20 real shows as an even
   40 on 120 Hz. 12 only with interpolation (shown as 24): SEUS panning at 52-62 ms a frame couldn't hold 15 shown
   as 30 (every other frame held 1-2 refreshes longer); alone 12 fps is too slow to be worth evenness. */
static const int pace_rates[] = {120, 60, 40, 30, 24, 20, 15, 12};
enum { PACE_N = sizeof pace_rates / sizeof pace_rates[0] };

/* Which rates may be used with shown_per_frame frames on screen per real frame; returns the slowest one's index.
   Only rates that are a whole number of the screen's refreshes (40 on a 60 Hz screen would judder) and within the
   power cap. A screen none of them divides (e.g. 144 Hz) gets them all, as before. */
static int pace_allowed(int shown_per_frame, int allowed[PACE_N])
{
    static int hz;
    if (!hz) {
        hz = (int)[NSScreen mainScreen].maximumFramesPerSecond;
        if (hz <= 0)
            hz = 60;
        mgl_log("frame pacing: screen refreshes at %d Hz", hz);
    }
    int cap = power_cap_fps(), any = 0;
    for (int i = 0; i < PACE_N; i++)
        any |= allowed[i] = hz % (pace_rates[i] * shown_per_frame) == 0 && pace_rates[i] * shown_per_frame <= hz &&
                            (!cap || pace_rates[i] <= cap) && (shown_per_frame > 1 || pace_rates[i] >= 15);
    for (int i = 0; i < PACE_N && !any; i++)
        any |= allowed[i] = (!cap || pace_rates[i] <= cap) && (shown_per_frame > 1 || pace_rates[i] >= 15);
    if (!any)
        allowed[PACE_N - 1] = 1;
    int slowest = PACE_N - 1;
    while (!allowed[slowest])
        slowest--;
    return slowest;
}

/* The fastest allowed real rate a frame costing cost_ms keeps up with, with 10% to spare. */
static int pace_fit(double cost_ms, int shown_per_frame)
{
    int allowed[PACE_N], fit = pace_allowed(shown_per_frame, allowed);
    for (int i = fit; i >= 0; i--)
        if (allowed[i] && cost_ms * 1.1 <= 1000.0 / pace_rates[i])
            fit = i;
    return pace_rates[fit];
}

static int choose_paced_fps(mgl_ctx *c, int shown_per_frame)
{
    const int *rates = pace_rates;
    enum { N = PACE_N };
    const char *forced = getenv("MGL_TARGET_FPS");
    if (forced && atoi(forced) > 0)
        return atoi(forced);
    int allowed[N], slowest = pace_allowed(shown_per_frame, allowed);
    uint64_t t = now_ns();
    int cur = -1;
    for (int i = 0; i < N; i++)
        if (rates[i] == c->paced_fps)
            cur = i;
    if (cur < 0 || !allowed[cur]) { /* first frame, or the cap or screen changed: the fastest allowed rate the cost fits */
        int fit = slowest;
        for (int i = slowest; i >= 0; i--)
            if (allowed[i] && c->avg_frame_ms <= 1000.0 / rates[i])
                fit = i;
        c->window_start_ns = t;
        c->grace_until_ns = t + 1000000000ull;
        return rates[fit];
    }
    if (t - c->window_start_ns < 500000000ull)
        return c->paced_fps;
    c->window_start_ns = t;
    /* The half second's median frame cost and at least 3 missed deadlines: one hitch (M3 static SEUS: a 50 ms
       frame) mustn't knock interpolation from 30 shown as 60 down to 20 shown as 40 for good. */
    double cost = c->avg_frame_ms;
    if (c->win_n >= 3) {
        double v[64];
        int n = c->win_n;
        memcpy(v, c->win_cost, n * sizeof v[0]);
        for (int i = 1; i < n; i++) /* insertion sort, n <= 64 */
            for (int j = i; j > 0 && v[j - 1] > v[j]; j--) {
                double x = v[j];
                v[j] = v[j - 1];
                v[j - 1] = x;
            }
        cost = v[n / 2];
    }
    c->win_n = 0;
    unsigned shown = atomic_exchange(&pace_shown, 0), missed = atomic_exchange(&pace_missed, 0);
    double budget = 1000.0 / c->paced_fps;
    int bad = t >= c->grace_until_ns && shown >= 4 && missed >= 3 && missed * 10 > shown && cost > 0.6 * budget;
    c->bad_windows = bad ? c->bad_windows + 1 : 0;
    if (c->bad_windows >= 2 && cur < slowest) {
        if (t - c->stepped_up_ns < 3000000000ull) { /* the try at this rate failed */
            c->up_backoff_s = c->up_backoff_s ? (c->up_backoff_s < 80 ? c->up_backoff_s * 2 : 80) : 10;
            c->blocked_fps = c->paced_fps;
            c->no_up_until_ns = t + c->up_backoff_s * 1000000000ull;
        }
        c->bad_windows = 0;
        c->grace_until_ns = t + 1000000000ull;
        int down = cur + 1;
        while (!allowed[down])
            down++;
        return rates[down];
    }
    if (c->stepped_up_ns && t - c->stepped_up_ns > 10000000000ull)
        c->up_backoff_s = 0; /* the last step up held */
    int best = cur, next = -1; /* next: the first allowed rate faster than the current one */
    for (int i = cur - 1; i >= 0; i--) {
        if (!allowed[i])
            continue;
        if (t < c->no_up_until_ns && rates[i] >= c->blocked_fps)
            break;
        if (next < 0)
            next = i;
        double b = 1000.0 / rates[i];
        /* one step up needs the cost within the budget; with interpolation within 83% of it, since two presents
           per frame make a miss costlier (M3 SEUS panning at 54-61 ms kept trying 15 shown as 30, budget 66.7, and
           juddered until it fell back to 12) */
        double step_margin = shown_per_frame > 1 ? 1.2 : 1.0;
        if (cost * 1.25 <= b || (i == next && cost * step_margin <= b))
            best = i;
    }
    if (best < cur) {
        c->stepped_up_ns = t;
        c->bad_windows = 0;
        c->grace_until_ns = t + 1000000000ull;
        return rates[best];
    }
    return c->paced_fps;
}

/* MGL_PRESENT_STATS=1 (or MGL_PROFILE): once a second, log how evenly frames reached the screen, from the
   drawables' presentedTime: shown fps, mean and spread of the time each frame stayed on screen, the worst one,
   and judder = share of frames whose time on screen differs from the previous frame's by more than 2 ms.
   MGL_PRESENT_STATS=2 also logs the first 16 times on screen of each second, in ms. */
static pthread_mutex_t pstat_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    double last, sum, sum2, worst, prev_iv, seq[16];
    unsigned long n, judder, dropped;
} pstat;

static void present_stat(double when)
{
    pthread_mutex_lock(&pstat_lock);
    if (when <= 0)
        pstat.dropped++;
    else {
        if (pstat.last > 0) {
            double iv = (when - pstat.last) * 1000.0;
            if (iv > 0 && iv < 250) {
                if (pstat.n < 16)
                    pstat.seq[pstat.n] = iv;
                pstat.n++;
                pstat.sum += iv;
                pstat.sum2 += iv * iv;
                if (iv > pstat.worst)
                    pstat.worst = iv;
                if (pstat.prev_iv > 0 && fabs(iv - pstat.prev_iv) > 2.0)
                    pstat.judder++;
                pstat.prev_iv = iv;
            }
        }
        pstat.last = when;
    }
    pthread_mutex_unlock(&pstat_lock);
}

static void present_stats_report(void)
{
    static uint64_t start;
    uint64_t t = now_ns();
    if (!start)
        start = t;
    if (t - start < 1000000000ull)
        return;
    start = t;
    pthread_mutex_lock(&pstat_lock);
    if (pstat.n) {
        double mean = pstat.sum / pstat.n, var = pstat.sum2 / pstat.n - mean * mean;
        mgl_log("present stats: %.1f shown fps, on screen %.2f ms avg, %.2f ms spread, %.2f ms worst, %.1f%% judder, %lu dropped",
                1000.0 / mean, mean, var > 0 ? sqrt(var) : 0.0, pstat.worst, 100.0 * pstat.judder / pstat.n, pstat.dropped);
        static int seq = -1;
        if (seq < 0) {
            const char *e = getenv("MGL_PRESENT_STATS");
            seq = e && atoi(e) >= 2;
        }
        if (seq) {
            char line[200];
            int k = 0;
            for (unsigned long i = 0; i < pstat.n && i < 16 && k < (int)sizeof line; i++)
                k += snprintf(line + k, sizeof line - k, " %.1f", pstat.seq[i]);
            mgl_log("present stats: times on screen (ms):%s", line);
        }
    }
    double last = pstat.last, prev_iv = pstat.prev_iv;
    memset(&pstat, 0, sizeof pstat);
    pstat.last = last;
    pstat.prev_iv = prev_iv;
    pthread_mutex_unlock(&pstat_lock);
}

static mgl_ctx *current;
static char renderer[128];

const char *mgl_renderer_name(void)
{
    if (!renderer[0]) {
        init_device();
        snprintf(renderer, sizeof renderer, "%s (Metal, mcmetal)", dev ? dev.name.UTF8String : "no Metal device");
    }
    return renderer;
}

/* MCMETAL_UPSCALE=1: the game renders at the window's point size (half the pixels each way on Retina, GLFW
   reports that size, see glfw/mtl_context.m) and MetalFX's spatial upscaler sharpens it to the Retina drawable. */
static int upscale_on(void)
{
    static int on = -1;
    if (on < 0)
        on = getenv("MCMETAL_UPSCALE") && atoi(getenv("MCMETAL_UPSCALE")) > 0;
    return on;
}

/* MCMETAL_UPSCALE_SCALE=N: with the upscaler on, the game renders at N% of the Retina size each way (34-100,
   default 50 = the window's point size). The patched GLFW reports the same size (see build_mac.sh), computed the
   same way: floor(points * backing scale * N / 100). */
static int render_pct(void)
{
    static int pct;
    if (!pct) {
        const char *e = getenv("MCMETAL_UPSCALE_SCALE");
        pct = e ? atoi(e) : 50;
        pct = pct < 34 ? 34 : pct > 100 ? 100 : pct;
    }
    return pct;
}

static void update_size(mgl_ctx *c)
{
    CGSize pt = c->layer.bounds.size, px = pt;
    px.width *= c->layer.contentsScale;
    px.height *= c->layer.contentsScale;
    if (px.width < 1 || px.height < 1)
        return;
    if (!CGSizeEqualToSize(c->layer.drawableSize, px))
        c->layer.drawableSize = px;
    int up = upscale_on() && c->layer.contentsScale > 1;
    c->w = (int)(up ? floor(pt.width * c->layer.contentsScale * render_pct() / 100.0) : px.width);
    c->h = (int)(up ? floor(pt.height * c->layer.contentsScale * render_pct() / 100.0) : px.height);
}

static id<MTLTexture> upscaled; /* last MetalFX output, for test screenshots */

/* RGBA8 copy of the last upscaled frame (GL row order, like window_color), for MGL_SHOT_DIR; 0 when none. */
int mglb_upscaled_read(unsigned char **px, int *w, int *h)
{
    if (!upscaled)
        return 0;
    *w = (int)upscaled.width;
    *h = (int)upscaled.height;
    size_t row = (size_t)*w * 4;
    mglb_buffer *stage = mglb_buffer_new(row * (size_t)*h);
    if (!stage || !(*px = malloc(row * (size_t)*h))) {
        mglb_buffer_release(stage);
        return 0;
    }
    [blit_encoder() copyFromTexture:upscaled sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(upscaled.width, upscaled.height, 1) toBuffer:OBJ(id<MTLBuffer>, stage->mtl)
                  destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * (size_t)*h];
    use_buffer(stage);
    mglb_finish();
    memcpy(*px, stage->ptr, row * (size_t)*h);
    mglb_buffer_release(stage);
    return 1;
}

/* The upscaled frame, the right way down for the present blit. NULL when off or MetalFX can't. */
static id<MTLTexture> upscale(mgl_ctx *c, id<MTLTexture> in, NSUInteger ow, NSUInteger oh)
{
    static id<MTLFXSpatialScaler> fx;
    static id<MTLTexture> out;
    static int failed;
    if (failed || (in.width == ow && in.height == oh))
        return nil;
    if (!fx || fx.inputWidth != in.width || fx.inputHeight != in.height || fx.outputWidth != ow || fx.outputHeight != oh) {
        MTLFXSpatialScalerDescriptor *d = [[MTLFXSpatialScalerDescriptor alloc] init];
        d.inputWidth = in.width;
        d.inputHeight = in.height;
        d.outputWidth = ow;
        d.outputHeight = oh;
        d.colorTextureFormat = in.pixelFormat;
        d.outputTextureFormat = in.pixelFormat;
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        if (![MTLFXSpatialScalerDescriptor supportsDevice:dev] || !(fx = [d newSpatialScalerWithDevice:dev])) {
            mgl_log("MetalFX upscaler not available, drawing at %lux%lu without it", (unsigned long)in.width,
                    (unsigned long)in.height);
            failed = 1;
            return nil;
        }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:in.pixelFormat width:ow
                                                                                     height:oh mipmapped:NO];
        td.usage = fx.outputTextureUsage | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        out = [dev newTextureWithDescriptor:td];
        mgl_log("MetalFX upscaler: %lux%lu -> %lux%lu", (unsigned long)in.width, (unsigned long)in.height,
                (unsigned long)ow, (unsigned long)oh);
    }
    fx.colorTexture = in;
    fx.outputTexture = out;
    fx.inputContentWidth = in.width;
    fx.inputContentHeight = in.height;
    [fx encodeToCommandBuffer:current_cb()];
    upscaled = out;
    return out;
}


/* ================================================================ MetalFX frame interpolation (MCMETAL_FRAMEGEN=1)

   Experimental, macOS 26+. MetalFX makes an extra frame between two real ones from both pictures, motion vectors
   and depth, so ~48 real fps can show as ~96. Packs don't hand us motion vectors, so they are worked out from the
   depth and Iris's camera uniforms (current and previous view and projection, camera position): camera motion
   only, so moving mobs, water waves and particles are guessed by MetalFX from the pictures alone. The held item
   (depth below MCMETAL_FG_HAND, default 0.56 like packs use) gets no motion.
   The HUD: Minecraft clears the main target's depth just before drawing it, and there we copy the world picture
   (no HUD) and depth (fg_snapshot); MetalFX gets that and the finished frame with the HUD ("composited UI") and
   keeps the HUD from smearing. A frame without that clear (menus, loading) is shown as is and resets MetalFX.
   Each swap then presents the made-up frame, then the real one half a frame later: about half a frame more
   input lag. MCMETAL_FG_FLIP=1 flips the motion's Y for MetalFX, MCMETAL_FG_NEG=1 its sign (conventions to check
   on a real Mac). */
#if defined(__MAC_26_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_26_0
#define MGL_HAVE_FRAMEGEN 1
#endif

static int fg_enabled(void)
{
    static int on = -1;
    if (on < 0) {
        on = 0;
#ifdef MGL_HAVE_FRAMEGEN
        const char *e = getenv("MCMETAL_FRAMEGEN");
        if (e && atoi(e) > 0) {
            if (@available(macOS 26.0, *)) {
                init_device();
                on = [MTLFXFrameInterpolatorDescriptor supportsDevice:dev];
                mgl_log("frame interpolation: %s", on ? "on" : "this Mac can't (MetalFX says no)");
            } else
                mgl_log("frame interpolation needs macOS 26");
        }
#else
        if (getenv("MCMETAL_FRAMEGEN"))
            mgl_log("frame interpolation: this build has no macOS 26 SDK");
#endif
    }
    return on;
}

/* The world snapshot (picture without the HUD, depth, camera motion) is shared by frame interpolation and the
   temporal upscaler; only the interpolator itself needs the macOS 26 SDK. */
static struct {
    id<MTLTexture> color[2], depth, motion, ui, out; /* color[cur] = this frame's world picture */
    int cur, w, h;
    MTLPixelFormat fmt;
    uint64_t snap_frame;       /* frames_presented when the last snapshot was taken */
    int have_prev;             /* the previous frame had a snapshot too */
    float view[16], proj[16];  /* camera at the snapshot, for MetalFX */
    id<MTLRenderPipelineState> mv_pipe;
    id fi;                     /* id<MTLFXFrameInterpolator> */
    int failed, reset;         /* failed: the interpolator */
    int snap_failed;
    double hand;
    const mglb_texture *depth_src; /* the main target's depth at the last snapshot: draws into it are the world */
} fg;

static const char *fg_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct FgU { float4x4 inv_proj, inv_view, prev_view, prev_proj; float4 cam_delta; float2 size; float hand, flip; };\n"
    "vertex float4 fg_vs(uint v [[vertex_id]]) { float2 p = float2((v << 1) & 2, v & 2); return float4(p * 2.0 - 1.0, 0.0, 1.0); }\n"
    "struct FgOut { float2 mv [[color(0)]]; float d [[depth(any)]]; };\n"
    "fragment FgOut fg_fs(float4 pos [[position]], depth2d<float> dep [[texture(0)]], constant FgU &u [[buffer(0)]]) {\n"
    "    uint2 px = uint2(pos.xy);\n"
    "    float d = dep.read(px);\n"
    "    FgOut o; o.d = d; o.mv = float2(0.0);\n"
    "    if (d < u.hand) return o;\n"
    "    float2 uv = (float2(px) + 0.5) / u.size;\n" /* texture rows are GL rows here, so uv is GL's */
    "    float4 v = u.inv_proj * float4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);\n"
    "    v /= v.w;\n"
    "    float3 w = (u.inv_view * v).xyz + u.cam_delta.xyz;\n"
    "    float4 pc = u.prev_proj * (u.prev_view * float4(w, 1.0));\n"
    "    if (pc.w <= 0.0) return o;\n"
    "    float2 m = (pc.xy / pc.w * 0.5 + 0.5) - uv;\n"
    "    o.mv = float2(m.x, m.y * u.flip) * u.cam_delta.w;\n"
    "    return o;\n"
    "}\n";

static void mat_inverse(const float *m, float *out)
{
    float inv[16];
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    float det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    det = det != 0 ? 1.0f / det : 0.0f;
    for (int i = 0; i < 16; i++)
        out[i] = inv[i] * det;
}

static id<MTLTexture> fg_texture(MTLPixelFormat pf, int w, int h, MTLTextureUsage usage)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    td.usage = usage | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:td];
}

/* The snapshot's textures and motion shader, for a w x h main target. */
static int snap_setup(int w, int h, MTLPixelFormat fmt)
{
    if (fg.color[0] && fg.w == w && fg.h == h && fg.fmt == fmt)
        return 1;
    fg.w = w;
    fg.h = h;
    fg.fmt = fmt;
    fg.fi = nil; /* the interpolator is made for one size */
    for (int i = 0; i < 2; i++)
        fg.color[i] = fg_texture(fmt, w, h, 0);
    fg.depth = fg_texture(MTLPixelFormatDepth32Float, w, h, MTLTextureUsageRenderTarget);
    fg.motion = fg_texture(MTLPixelFormatRG16Float, w, h, MTLTextureUsageRenderTarget);
    fg.have_prev = 0;
    fg.reset = 1;
    if (!fg.mv_pipe) {
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:fg_msl] options:nil error:&e];
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = [lib newFunctionWithName:@"fg_vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fg_fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        fg.mv_pipe = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
        if (!fg.mv_pipe) {
            mgl_log("camera motion shader failed: %s", e.localizedDescription.UTF8String);
            fg.snap_failed = 1;
            return 0;
        }
    }
    const char *hand = getenv("MCMETAL_FG_HAND");
    fg.hand = hand ? atof(hand) : 0.56;
    return 1;
}

#ifdef MGL_HAVE_FRAMEGEN
API_AVAILABLE(macos(26.0)) static int fg_setup(void)
{
    if (fg.fi)
        return 1;
    MTLFXFrameInterpolatorDescriptor *d = [[MTLFXFrameInterpolatorDescriptor alloc] init];
    d.colorTextureFormat = fg.fmt;
    d.outputTextureFormat = fg.fmt;
    d.uiTextureFormat = fg.fmt;
    d.depthTextureFormat = MTLPixelFormatDepth32Float;
    d.motionTextureFormat = MTLPixelFormatRG16Float;
    d.inputWidth = fg.w;
    d.inputHeight = fg.h;
    d.outputWidth = fg.w;
    d.outputHeight = fg.h;
    id<MTLFXFrameInterpolator> fi = [d newFrameInterpolatorWithDevice:dev];
    if (!fi) {
        mgl_log("frame interpolation: MetalFX wouldn't make an interpolator for %dx%d", fg.w, fg.h);
        fg.failed = 1;
        return 0;
    }
    fg.fi = fi;
    fg.ui = fg_texture(fg.fmt, fg.w, fg.h, fi.uiTextureUsage);
    fg.out = fg_texture(fg.fmt, fg.w, fg.h, fi.outputTextureUsage | MTLTextureUsageRenderTarget);
    fg.reset = 1;
    mgl_log("frame interpolation: %dx%d ready", fg.w, fg.h);
    return 1;
}
#endif

static void fg_snapshot(const mgl_target *t)
{
    {
        if (fg.snap_failed || !mgl->window_color || t->width != mgl->window_color->d.width ||
            t->height != mgl->window_color->d.height || (mgl_cam.seen & 0x3f) != 0x3f)
            return;
        id<MTLTexture> col = OBJ(id<MTLTexture>, t->tex[0]->mtl), dep = OBJ(id<MTLTexture>, t->depth->mtl);
        if (!snap_setup(t->width, t->height, col.pixelFormat))
            return;
#ifdef MGL_HAVE_FRAMEGEN
        if (fg_enabled() && !fg.failed) {
            if (@available(macOS 26.0, *))
                fg_setup();
        }
#endif
        if (fg.snap_frame != frames_presented + 1) { /* first snapshot this frame: use the other picture slot */
            fg.have_prev = fg.snap_frame == frames_presented; /* the previous frame had one */
            fg.cur ^= 1;
        }
        fg.snap_frame = frames_presented + 1;
        fg.depth_src = t->depth;
        end_encoders();
        id<MTLBlitCommandEncoder> b = [current_cb() blitCommandEncoder];
        [b copyFromTexture:col toTexture:fg.color[fg.cur]];
        [b endEncoding];

        struct {
            float inv_proj[16], inv_view[16], prev_view[16], prev_proj[16];
            float cam_delta[4];
            float size[2], hand, flip;
        } u;
        mat_inverse(mgl_cam.mat[1], u.inv_proj);
        mat_inverse(mgl_cam.mat[0], u.inv_view);
        memcpy(u.prev_view, mgl_cam.mat[2], 64);
        memcpy(u.prev_proj, mgl_cam.mat[3], 64);
        for (int i = 0; i < 3; i++)
            u.cam_delta[i] = mgl_cam.pos[0][i] - mgl_cam.pos[1][i];
        static int neg = -1, flip = -1;
        if (neg < 0) {
            neg = opt("MCMETAL_FG_NEG");
            flip = opt("MCMETAL_FG_FLIP");
        }
        u.cam_delta[3] = neg ? -1.0f : 1.0f;
        u.size[0] = (float)t->width;
        u.size[1] = (float)t->height;
        u.hand = (float)fg.hand;
        u.flip = flip ? -1.0f : 1.0f;
        memcpy(fg.view, mgl_cam.mat[0], 64);
        memcpy(fg.proj, mgl_cam.mat[1], 64);

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = fg.motion;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.depthAttachment.texture = fg.depth;
        rp.depthAttachment.loadAction = MTLLoadActionDontCare;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [current_cb() renderCommandEncoderWithDescriptor:rp];
        static id<MTLDepthStencilState> always;
        if (!always) {
            MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
            dd.depthCompareFunction = MTLCompareFunctionAlways;
            dd.depthWriteEnabled = YES;
            always = [dev newDepthStencilStateWithDescriptor:dd];
        }
        [e setRenderPipelineState:fg.mv_pipe];
        [e setDepthStencilState:always];
        [e setFragmentTexture:dep atIndex:0];
        [e setFragmentBytes:&u length:sizeof u atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }
}

/* The made-up frame between the last two real ones, or nil (no snapshot this frame or the last, or off). Called at
   swap, with the finished frame (HUD included) in window_color. */
static id<MTLTexture> fg_interpolate(double frame_s)
{
#ifdef MGL_HAVE_FRAMEGEN
    if (@available(macOS 26.0, *)) {
        if (!fg_enabled() || fg.failed || !fg.fi)
            return nil;
        int fresh = fg.snap_frame == frames_presented + 1;
        if (!fresh || !fg.have_prev) {
            fg.reset = 1;
            return nil;
        }
        id<MTLTexture> win = OBJ(id<MTLTexture>, mgl->window_color->mtl);
        if (win.pixelFormat != fg.fmt || (int)win.width != fg.w || (int)win.height != fg.h)
            return nil;
        id<MTLBlitCommandEncoder> b = [current_cb() blitCommandEncoder];
        [b copyFromTexture:win toTexture:fg.ui];
        [b endEncoding];
        id<MTLFXFrameInterpolator> fi = fg.fi;
        fi.colorTexture = fg.color[fg.cur];
        fi.prevColorTexture = fg.color[fg.cur ^ 1];
        fi.uiTexture = fg.ui;
        fi.uiTextureComposited = YES; /* the colour texture has the HUD in it */
        fi.depthTexture = fg.depth;
        fi.motionTexture = fg.motion;
        fi.outputTexture = fg.out;
        fi.motionVectorScaleX = (float)fg.w;
        fi.motionVectorScaleY = (float)fg.h;
        fi.depthReversed = NO;
        fi.deltaTime = (float)frame_s;
        const float *p = fg.proj;
        float fov = 2.0f * atanf(1.0f / p[5]);
        fi.fieldOfView = fov * 180.0f / (float)M_PI;
        fi.aspectRatio = p[5] / p[0];
        fi.nearPlane = p[14] / (p[10] - 1.0f);
        fi.farPlane = p[14] / (p[10] + 1.0f);
        fi.shouldResetHistory = fg.reset;
        fg.reset = 0;
        [fi encodeToCommandBuffer:current_cb()];
        return fg.out;
    }
#else
    (void)frame_s;
#endif
    return nil;
}

/* MetalFX must not blend across a pause in interpolation */
static void fg_history_reset(void)
{
    fg.reset = 1;
}

/* ================================================================ MetalFX temporal upscaler (MCMETAL_UPSCALE=2)

   Like MCMETAL_UPSCALE=1 the game renders below the Retina size (MCMETAL_UPSCALE_SCALE, default half each way),
   but MetalFX's temporal upscaler rebuilds the full-size world picture from this frame and the last ones, using
   the world snapshot's depth and camera motion (the same as frame interpolation). Needs a shader pack (Iris's
   camera uniforms); without one, and in menus, frames use the spatial upscaler.
   Jitter: world draws (into the main depth, depth tested or written, before the snapshot) are moved by a sub-pixel
   offset from a Halton(2,3) sequence that changes every frame (vertex shaders get it through mcm_jitter, see
   mgl_program.c), and MetalFX is told the offset, so it gathers detail finer than the render resolution. Packs
   with their own TAA jitter too; turning the pack's TAA off lets MetalFX do it instead. MCMETAL_TU_JITTER=0 off;
   MCMETAL_TU_JX / MCMETAL_TU_JY = -1 flip the sign MetalFX is told (convention check).
   The HUD isn't in the snapshot: output pixels whose input footprint (the 2x2 input pixels around it) differs
   from the world picture are the HUD, taken from the finished frame with sharp-edged bilinear filtering (pixel
   exact at whole-number scales); everything else is MetalFX's world. That pass writes straight into the window.
   History (M3 Max, 1728x965 -> 3456x1930, 2026-10-22, no jitter, HUD via a second, spatial MetalFX pass): ~2-4 ms
   more GPU (SEUS 25.4 -> 27.2 ms, Complementary 5.4 -> 9.8) and no sharper; the jitter and the cheaper HUD pass
   are the fix for both. */
static int tu_enabled(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MCMETAL_UPSCALE");
        on = e && atoi(e) == 2;
        if (on)
            mgl_log("temporal upscaler: on (with a shader pack; spatial otherwise), render scale %d%%", render_pct());
    }
    return on;
}

static struct {
    id fx; /* id<MTLFXTemporalScaler> */
    id<MTLTexture> out, final;
    id<MTLRenderPipelineState> pipe[2]; /* by output: window (BGRA8), test-screenshot copy (fg.fmt) */
    MTLPixelFormat pipe_fmt[2];
    NSUInteger ow, oh;
    int failed, reset, logged;
    uint64_t jittered_frame; /* frame number (frames_presented + 1) whose world draws got jitter */
} tu = {.reset = 1};

/* Halton(base) for index i >= 1, in [0, 1) */
static float halton(unsigned i, unsigned base)
{
    float f = 1, r = 0;
    for (; i; i /= base) {
        f /= (float)base;
        r += f * (float)(i % base);
    }
    return r;
}

/* Frame n's jitter in input pixels, each in [-0.5, 0.5): +x = later columns, +y = later rows (GL row order, as
   the snapshot is stored). The cycle covers each output pixel ~8 times: 8 x (output / input pixels), at most 64. */
static void tu_jitter_px(uint64_t n, float j[2])
{
    double ratio = 100.0 / render_pct();
    unsigned len = (unsigned)(8.0 * ratio * ratio + 0.5);
    len = len < 8 ? 8 : len > 64 ? 64 : len;
    unsigned i = (unsigned)(n % len) + 1;
    j[0] = halton(i, 2) - 0.5f;
    j[1] = halton(i, 3) - 0.5f;
}

void mglb_tu_jitter(const mgl_target *t, float out[2])
{
    out[0] = out[1] = 0;
    /* only on frames that will use the temporal path: the last frame had a snapshot (so this one is in the world
       too), and only before this frame's snapshot (the HUD draws into the same depth afterwards) */
    if (!tu_enabled() || tu.failed || !t->depth || t->depth != fg.depth_src || fg.snap_frame != frames_presented ||
        t->width != fg.w || t->height != fg.h)
        return;
    float j[2];
    tu_jitter_px(frames_presented + 1, j);
    out[0] = 2.0f * j[0] / (float)t->width; /* clip x: +2/w moves one column */
    out[1] = 2.0f * j[1] / (float)t->height; /* GL clip y: +2/h moves one row up = one later row */
    tu.jittered_frame = frames_presented + 1;
}

static const char *tu_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct TuU { float2 in_per_out; float flip_h, sharp; };\n"
    "vertex float4 tu_vs(uint v [[vertex_id]]) { float2 p = float2((v << 1) & 2, v & 2); return float4(p * 2.0 - 1.0, 0.0, 1.0); }\n"
    /* world_up / full / world are in GL row order; flip_h > 0: the output is the window (top row first) */
    "fragment float4 tu_fs(float4 pos [[position]], texture2d<float> world_up [[texture(0)]],\n"
    "                      texture2d<float> full [[texture(1)]], texture2d<float> world [[texture(2)]], constant TuU &u [[buffer(0)]]) {\n"
    "    float2 o = pos.xy;\n"
    "    if (u.flip_h > 0.0) o.y = u.flip_h - o.y;\n"
    "    int2 isz = int2(full.get_width(), full.get_height());\n"
    "    float2 t = o * u.in_per_out - 0.5;\n"
    "    float2 b = floor(t), f = t - b;\n"
    "    int2 c0 = clamp(int2(b), int2(0), isz - 1), c1 = clamp(int2(b) + 1, int2(0), isz - 1);\n"
    "    float4 h00 = full.read(uint2(c0)), h10 = full.read(uint2(c1.x, c0.y)), h01 = full.read(uint2(c0.x, c1.y)), h11 = full.read(uint2(c1));\n"
    "    float3 d = max(max(abs(h00.rgb - world.read(uint2(c0)).rgb), abs(h10.rgb - world.read(uint2(c1.x, c0.y)).rgb)),\n"
    "                   max(abs(h01.rgb - world.read(uint2(c0.x, c1.y)).rgb), abs(h11.rgb - world.read(uint2(c1)).rgb)));\n"
    "    if (max(d.r, max(d.g, d.b)) <= 0.002) return float4(world_up.read(uint2(o)).rgb, 1.0);\n"
    "    float2 k = clamp((f - 0.5) * u.sharp + 0.5, 0.0, 1.0);\n" /* sharp bilinear: hard texel edges, 1-pixel blend */
    "    return float4(mix(mix(h00, h10, k.x), mix(h01, h11, k.x), k.y).rgb, 1.0);\n"
    "}\n";

static id<MTLRenderPipelineState> tu_pipeline(int slot, MTLPixelFormat fmt)
{
    if (tu.pipe[slot] && tu.pipe_fmt[slot] == fmt)
        return tu.pipe[slot];
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:tu_msl] options:nil error:&e];
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = [lib newFunctionWithName:@"tu_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"tu_fs"];
    pd.colorAttachments[0].pixelFormat = fmt;
    tu.pipe[slot] = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
    tu.pipe_fmt[slot] = fmt;
    if (!tu.pipe[slot])
        mgl_log("temporal upscaler: HUD shader failed: %s", e.localizedDescription.UTF8String);
    return tu.pipe[slot];
}

/* The world + HUD pass: into dst (ow x oh), the window's way up when flip */
static int tu_compose(id<MTLTexture> win, id<MTLTexture> dst, int slot, int flip)
{
    id<MTLRenderPipelineState> ps = tu_pipeline(slot, dst.pixelFormat);
    if (!ps)
        return 0;
    struct { float in_per_out[2], flip_h, sharp; } u = {
        {(float)fg.w / (float)dst.width, (float)fg.h / (float)dst.height}, flip ? (float)dst.height : 0.0f,
        (float)dst.width / (float)fg.w};
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [current_cb() renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps];
    [e setFragmentTexture:tu.out atIndex:0];
    [e setFragmentTexture:win atIndex:1];
    [e setFragmentTexture:fg.color[fg.cur] atIndex:2];
    [e setFragmentBytes:&u length:sizeof u atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    return 1;
}

/* The finished frame (window_color, HUD included) upscaled into the drawable with the world from the temporal
   upscaler. 0 (nothing drawn) when off, no fresh snapshot, or MetalFX can't: then the caller uses the spatial one. */
static int tu_frame(id<MTLTexture> win, id<MTLTexture> drawable)
{
    if (!tu_enabled() || tu.failed)
        return 0;
    NSUInteger ow = drawable.width, oh = drawable.height;
    if (fg.snap_frame != frames_presented + 1 || !fg.color[0] || (int)win.width != fg.w || (int)win.height != fg.h ||
        win.pixelFormat != fg.fmt) {
        tu.reset = 1;
        return 0;
    }
    if (!tu.fx || tu.ow != ow || tu.oh != oh || [(id<MTLFXTemporalScaler>)tu.fx colorTextureFormat] != fg.fmt ||
        [(id<MTLFXTemporalScaler>)tu.fx inputWidth] != (NSUInteger)fg.w || [(id<MTLFXTemporalScaler>)tu.fx inputHeight] != (NSUInteger)fg.h) {
        MTLFXTemporalScalerDescriptor *d = [[MTLFXTemporalScalerDescriptor alloc] init];
        d.colorTextureFormat = fg.fmt;
        d.outputTextureFormat = fg.fmt;
        d.depthTextureFormat = MTLPixelFormatDepth32Float;
        d.motionTextureFormat = MTLPixelFormatRG16Float;
        d.inputWidth = fg.w;
        d.inputHeight = fg.h;
        d.outputWidth = ow;
        d.outputHeight = oh;
        d.autoExposureEnabled = NO;
        id<MTLFXTemporalScaler> fx = [MTLFXTemporalScalerDescriptor supportsDevice:dev] ? [d newTemporalScalerWithDevice:dev] : nil;
        if (!fx) {
            mgl_log("temporal upscaler: MetalFX wouldn't make one for %dx%d -> %lux%lu, using the spatial one", fg.w, fg.h,
                    (unsigned long)ow, (unsigned long)oh);
            if (@available(macOS 14.4, *))
                mgl_log("temporal upscaler: this Mac takes %.2fx to %.2fx (output / input)",
                        [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:dev],
                        [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:dev]);
            tu.failed = 1;
            return 0;
        }
        tu.fx = fx;
        tu.ow = ow;
        tu.oh = oh;
        tu.out = fg_texture(fg.fmt, (int)ow, (int)oh, fx.outputTextureUsage);
        tu.final = nil;
        tu.reset = 1;
        mgl_log("temporal upscaler: %dx%d -> %lux%lu", fg.w, fg.h, (unsigned long)ow, (unsigned long)oh);
    }
    float j[2] = {0, 0};
    if (tu.jittered_frame == fg.snap_frame)
        tu_jitter_px(fg.snap_frame, j);
    static float sx, sy;
    if (!sx) {
        sx = getenv("MCMETAL_TU_JX") && atoi(getenv("MCMETAL_TU_JX")) < 0 ? -1.0f : 1.0f;
        sy = getenv("MCMETAL_TU_JY") && atoi(getenv("MCMETAL_TU_JY")) < 0 ? -1.0f : 1.0f;
    }
    id<MTLFXTemporalScaler> fx = tu.fx;
    fx.colorTexture = fg.color[fg.cur];
    fx.depthTexture = fg.depth;
    fx.motionTexture = fg.motion;
    fx.outputTexture = tu.out;
    fx.inputContentWidth = fg.w;
    fx.inputContentHeight = fg.h;
    fx.jitterOffsetX = sx * j[0];
    fx.jitterOffsetY = sy * j[1];
    fx.motionVectorScaleX = (float)fg.w;
    fx.motionVectorScaleY = (float)fg.h;
    fx.depthReversed = NO;
    fx.reset = tu.reset;
    tu.reset = 0;
    [fx encodeToCommandBuffer:current_cb()];

    if (!tu_compose(win, drawable, 0, 1)) {
        tu.failed = 1;
        return 0;
    }
    static int shots = -1;
    if (shots < 0)
        shots = getenv("MGL_SHOT_DIR") != NULL;
    if (shots) { /* test screenshots read the shown frame back: the window can't be read, so draw it once more */
        if (!tu.final || tu.final.width != ow || tu.final.height != oh)
            tu.final = fg_texture(fg.fmt, (int)ow, (int)oh, MTLTextureUsageRenderTarget);
        if (tu_compose(win, tu.final, 1, 0))
            upscaled = tu.final;
    }
    if (!tu.logged) {
        tu.logged = 1;
        mgl_log("temporal upscaler: first frame drawn (jitter %s)", tu.jittered_frame == fg.snap_frame ? "on" : "off");
    }
    return 1;
}

void mglb_window_size(int *w, int *h)
{
    *w = current ? current->w : 0;
    *h = current ? current->h : 0;
}

MGL_EXPORT void *mgl_glfw_create(void *metal_layer)
{
    init_device();
    if (!dev) {
        mgl_log("no Metal device");
        return NULL;
    }
    mgl_ctx *c = calloc(1, sizeof *c);
    c->layer = (__bridge CAMetalLayer *)metal_layer;
    c->layer.device = dev;
    c->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    c->layer.framebufferOnly = YES;
    c->layer.maximumDrawableCount = 3;
    update_size(c);
    mgl_log("context created on %s, %dx%d", dev.name.UTF8String, c->w, c->h);
    return c;
}

MGL_EXPORT void mgl_glfw_make_current(void *ctx)
{
    current = ctx;
    /* the thread that draws gets the scheduler's top class, so macOS keeps it on a performance core and ahead of
       chunk meshing and the integrated server (mcopt measured +17% fps, +63% 1% lows on Apple silicon). MGL_QOS=0 off. */
    static __thread int qos_set;
    if (ctx && !qos_set) {
        qos_set = 1;
        const char *e = getenv("MGL_QOS");
        if (!(e && *e == '0'))
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

MGL_EXPORT void mgl_glfw_swap_interval(void *ctx, int interval)
{
    ((mgl_ctx *)ctx)->layer.displaySyncEnabled = interval > 0;
    ((mgl_ctx *)ctx)->vsync = interval > 0;
}

MGL_EXPORT void mgl_glfw_destroy(void *ctx)
{
    mglb_finish();
    archive_save();
    if (current == ctx)
        current = NULL;
    free(ctx);
}

static void profile_frame(unsigned long draws)
{
    uint64_t t = now_ns();
    prof.draws += draws;
    if (!prof.start_ns) {
        memset(&prof, 0, sizeof prof);
        prof.start_ns = t;
        atomic_store(&prof_gpu_ns, 0);
        return;
    }
    if (++prof.frames, t - prof.start_ns < 1000000000ull)
        return;
    double f = (double)prof.frames, ms = (double)(t - prof.start_ns) * 1e-6 / f;
    mgl_log("profile: %.0f fps; per frame: cpu %.2f ms (waiting %.2f), gpu %.2f ms; %.0f draws, %.1f passes "
            "(%.1f reopened, %.1f images not loaded), %.1f blit + %.1f compute encoders, %.1f command buffers, %.2f finishes; %.0f%% presents skipped",
            f * 1000.0 / ((double)(t - prof.start_ns) * 1e-6), ms, (double)prof.wait_ns * 1e-6 / f,
            (double)atomic_load(&prof_gpu_ns) * 1e-6 / f, prof.draws / f, prof.passes / f, prof.reopened / f, prof.dontcare / f,
            prof.blits / f, prof.computes / f, prof.cbs / f, prof.finishes / f, 100.0 * prof.skipped_presents / f);
    if (prof.sh_draws)
        mgl_log("profile: shadow-sized viewports (without geometry shaders) %.0f draws, %.0fk triangles per frame",
                prof.sh_draws / f, prof.sh_tris / f * 1e-3);
    if (prof.gs_draws) {
        mgl_log("profile: geometry shaders %.0f draws (%.0f with the compute made for their vertex format), %.0fk input "
                "triangles, %.1f MB of records per frame", prof.gs_draws / f, prof.gs_spec / f, prof.gs_tris / f * 1e-3,
                prof.gs_bytes / f / 1048576.0);
        size_t held = 0;
        for (int i = 0; i < gsc_n; i++)
            held += gsc_e[i].slab >= 0 ? gsc_e[i].len : 0;
        mgl_log("profile: geometry-shader cache per frame: %.0f reused, %.0f stored, %.0f computed, %.0f not cacheable, "
                "%.0f cache full; %.0f MB held in %d slabs", gsc_hits / f, gsc_stores / f, gsc_misses / f, gsc_skips / f,
                gsc_full / f, held / 1048576.0, gsc_nslabs);
        mgl_log("profile: geometry-shader cache misses per frame: %.0f buffers rewritten, %.0f uniforms changed, "
                "%.0f draws not drawn the frame before; uniform ranges hashed: %d", gsc_why_bufs / f, gsc_why_unis / f,
                gsc_why_new / f, gsc_last_ranges);
        gsc_hits = gsc_stores = gsc_misses = gsc_skips = gsc_full = 0;
        gsc_why_bufs = gsc_why_unis = gsc_why_new = 0;
    }
    mgl_log("profile: buffers %.0f MB held (%.0f MB pooled), %.1f new Metal buffers (%.2f MB) per frame, %d of %d "
            "transient chunks, %.1f one-off transient buffers and %.1f waits for a chunk per frame",
            buf_live_bytes / 1048576.0, buf_pooled_bytes / 1048576.0, buf_fresh / f, buf_fresh_bytes / f / 1048576.0,
            tr_n, TR_MAX, tr_oneoff / f, tr_waits / f);
    tr_oneoff = tr_waits = 0;
    buf_fresh = 0;
    buf_fresh_bytes = 0;
    double lazy_renames = (double)mgl_bstats.lazy_renames, lazy_settles = (double)mgl_bstats.settles,
           lazy_scans = (double)mgl_bstats.index_scans;
    mgl_log("profile: cpu buffer traffic per frame: %.1f renames (%.2f MB copied, %.2f ms), %.1f glCopyBufferSubData "
            "(%.2f MB, %.2f ms), %.1f GPU copies (%.2f MB, %.1f CPU waits for one), %.0f glBufferData (%.2f MB); %.1f texture views made, %.1f pipeline lookups, %.1f big "
            "uniform blocks; %lu textures remade for image/view use", mgl_bstats.renames / f,
            mgl_bstats.rename_copy_bytes / f / 1048576.0, mgl_bstats.rename_ns / f * 1e-6, mgl_bstats.copies / f,
            mgl_bstats.copy_bytes / f / 1048576.0, mgl_bstats.copy_ns / f * 1e-6, mgl_bstats.gpu_copies / f,
            mgl_bstats.gpu_copy_bytes / f / 1048576.0, mgl_bstats.gpu_waits / f, mgl_bstats.datas / f,
            mgl_bstats.data_bytes / f / 1048576.0, prof.tex_views / f, prof.pipe_lookups / f, prof.big_uniforms / f,
            tex_upgrades);
    mgl_log("profile: buffer renames per frame: %.1f left the old bytes behind (%.1f of those copied over later), "
            "%.2f index buffers scanned for their highest vertex", lazy_renames / f, lazy_settles / f, lazy_scans / f);
    if (prof.rs_sets + prof.rs_skips)
        mgl_log("profile: render-encoder state per frame: %.0f calls sent, %.0f repeats left out (%.0f%%)",
                prof.rs_sets / f, prof.rs_skips / f, 100.0 * prof.rs_skips / (double)(prof.rs_sets + prof.rs_skips));
    memset(&mgl_bstats, 0, sizeof mgl_bstats);
    if (pt_ok > 0 || (pt_ok == 0 && opt_profile >= 3))
        pt_report(f);
    memset(&prof, 0, sizeof prof);
    prof.start_ns = t;
    atomic_store(&prof_gpu_ns, 0);
}

/* Each part of an interpolated frame goes in its own command buffer so the made-up frame's GPU cost is known (for
   fg_worth_it). MCMETAL_FG_TIMING=1 logs each part's GPU time and the gap before the GPU started it (a gap means
   the GPU sat waiting, e.g. for a drawable), averaged once a second. */
enum { FG_GAME, FG_MAKE, FG_SHOW_MID, FG_SHOW_REAL, FG_STAGES };
static _Atomic uint64_t fg_stage_ns[FG_STAGES], fg_stage_gap_ns[FG_STAGES], fg_stage_n[FG_STAGES];
static _Atomic uint64_t fg_last_end_ns; /* GPU end of the last timed command buffer, ns */

static int fg_timing(void)
{
    static int on = -1;
    if (on < 0)
        on = opt("MCMETAL_FG_TIMING");
    return on;
}

static _Atomic uint64_t fg_extra_ns, fg_extra_frames; /* GPU time of making + showing the made-up frames */

static void fg_time_stage(int stage)
{
    [current_cb() addCompletedHandler:^(id<MTLCommandBuffer> done) {
      if (done.GPUEndTime <= done.GPUStartTime)
          return;
      uint64_t s = (uint64_t)(done.GPUStartTime * 1e9), e = (uint64_t)(done.GPUEndTime * 1e9);
      if (stage == FG_MAKE || stage == FG_SHOW_MID)
          atomic_fetch_add(&fg_extra_ns, e - s);
      if (stage == FG_MAKE)
          atomic_fetch_add(&fg_extra_frames, 1);
      if (!fg_timing())
          return;
      uint64_t prev = atomic_exchange(&fg_last_end_ns, e);
      atomic_fetch_add(&fg_stage_ns[stage], e - s);
      if (prev && s > prev)
          atomic_fetch_add(&fg_stage_gap_ns[stage], s - prev);
      atomic_fetch_add(&fg_stage_n[stage], 1);
    }];
    commit();
}

static void fg_timing_report(void)
{
    static uint64_t last;
    uint64_t t = now_ns();
    if (!fg_timing() || t - last < 1000000000ull)
        return;
    last = t;
    static const char *names[FG_STAGES] = {"game", "interpolate", "show made-up", "show real"};
    char line[400];
    int n = snprintf(line, sizeof line, "frame interpolation timing (gpu ms / gap before ms):");
    for (int i = 0; i < FG_STAGES && n < (int)sizeof line; i++) {
        uint64_t k = atomic_exchange(&fg_stage_n[i], 0), ns = atomic_exchange(&fg_stage_ns[i], 0),
                 gap = atomic_exchange(&fg_stage_gap_ns[i], 0);
        if (k)
            n += snprintf(line + n, sizeof line - n, " %s %.2f / %.2f;", names[i], ns * 1e-6 / k, gap * 1e-6 / k);
    }
    mgl_log("%s", line);
}

/* Interpolation only pays when it shows more frames than the real ones could alone: static SEUS on an M3 makes an
   even 40 real fps, while with interpolation (~5 ms more GPU) it only held 20 real shown as 40 (more lag, same
   smoothness) or wobbled between that and 30 shown as 60. So every half second compare the two, from the frame
   cost and the made-up frames' measured GPU time, and pause or resume interpolation after 2 s of agreement and at
   least 3 s after the last switch. MCMETAL_FG_ALWAYS=1 keeps it on. */
static int fg_paused;

static void fg_decide(mgl_ctx *c)
{
    static uint64_t window_ns, switched_ns;
    static double extra_ms;
    static int votes, always = -1;
    if (always < 0)
        always = opt("MCMETAL_FG_ALWAYS");
    uint64_t t = now_ns();
    if (always || t - window_ns < 500000000ull)
        return;
    window_ns = t;
    uint64_t ns = atomic_exchange(&fg_extra_ns, 0), n = atomic_exchange(&fg_extra_frames, 0);
    if (n)
        extra_ms = ns * 1e-6 / n;
    if (extra_ms <= 0 || c->avg_frame_ms <= 0 || c->paced_fps <= 0 || (!fg_paused && !n) || t - switched_ns < 3000000000ull) {
        votes = 0;
        return;
    }
    int single, dual, vote;
    if (!fg_paused) {
        dual = c->paced_fps;
        single = pace_fit(c->avg_frame_ms - extra_ms, 1);
        vote = single >= 2 * dual;
    } else {
        single = c->paced_fps;
        dual = pace_fit(c->avg_frame_ms + extra_ms, 2);
        vote = 2 * dual > single;
    }
    votes = vote ? votes + 1 : 0;
    if (votes < 4)
        return;
    votes = 0;
    switched_ns = t;
    fg_paused = !fg_paused;
    c->paced_fps = 0; /* pick the rate afresh */
    fg_history_reset();
    if (fg_paused)
        mgl_log("frame interpolation paused: real frames alone make an even %d fps (interpolated: %d shown as %d; made-up frames cost %.1f ms)",
                single, dual, 2 * dual, extra_ms);
    else
        mgl_log("frame interpolation back on: %d real fps shown as %d beats %d real (made-up frames cost %.1f ms)", dual, 2 * dual,
                single, extra_ms);
}

static atomic_int presents_waiting; /* drawn but not yet on screen */

/* Count a drawable as waiting until it is shown, and feed pacing and MGL_PRESENT_STATS its time on screen. */
static void watch_drawable(id<CAMetalDrawable> drawable)
{
    [current_cb() addCompletedHandler:^(id<MTLCommandBuffer> done) {
      (void)done;
      atomic_fetch_add(&presents_waiting, 1);
    }];
    static int stats = -1;
    if (stats < 0)
        stats = opt_profile > 0 || opt("MGL_PRESENT_STATS");
    [drawable addPresentedHandler:^(id<MTLDrawable> d) {
      atomic_fetch_sub(&presents_waiting, 1);
      static double last_shown;
      static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER; /* handlers may run on more than one thread */
      double when = d.presentedTime, iv = 0;
      if (when > 0) {
          pthread_mutex_lock(&lock);
          if (last_shown > 0 && when > last_shown)
              iv = (when - last_shown) * 1000.0;
          if (when > last_shown)
              last_shown = when;
          pthread_mutex_unlock(&lock);
          if (iv > 0)
              pace_presented(iv);
      }
      if (stats)
          present_stat(when);
    }];
}

/* Draw a frame (GL row order) into the drawable the right way up, through MetalFX's upscaler when that's on. */
static void draw_to_drawable(mgl_ctx *c, id<MTLTexture> src, id<CAMetalDrawable> drawable)
{
    if (upscale_on()) {
        if (src == OBJ(id<MTLTexture>, mgl->window_color->mtl) && tu_frame(src, drawable.texture))
            return;
        id<MTLTexture> up = upscale(c, src, drawable.texture.width, drawable.texture.height);
        if (up)
            src = up;
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [current_cb() renderCommandEncoderWithDescriptor:rp];
    id<MTLRenderPipelineState> ps = blit_pipeline(MTLPixelFormatBGRA8Unorm);
    if (ps) {
        [e setRenderPipelineState:ps];
        [e setViewport:(MTLViewport){0, 0, (double)drawable.texture.width, (double)drawable.texture.height, 0, 1}];
        /* top of the window = last GL row */
        float rect[4] = {0, 1, 1, 0};
        [e setVertexBytes:rect length:sizeof rect atIndex:0];
        [e setFragmentTexture:src atIndex:0];
        [e setFragmentSamplerState:blit_sampler(1) atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [e endEncoding];
}

/* Copy GL framebuffer 0 into the window, flipping it the right way up. */
/* MGL_FRAME_TIMES=N: every N seconds (1 = 10 s), the spread of whole-frame times (swap to swap, waits included):
   average fps, "1% low" and "0.1% low" (the 99th and 99.9th percentile frame time, as fps), the worst frame and
   how many took over 50 ms. Long frames are counted however long they are, unlike the present stats, so this is
   the line for hitches (Distant Horizons building LODs, chunk loading). */
static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void frame_times_tick(void)
{
    static int every_s = -1;
    static uint64_t last, start;
    static double ms[16384];
    static unsigned n;
    if (every_s < 0) {
        const char *e = getenv("MGL_FRAME_TIMES");
        every_s = e && atoi(e) > 0 ? (atoi(e) == 1 ? 10 : atoi(e)) : 0;
    }
    if (!every_s)
        return;
    uint64_t t = now_ns();
    if (!last) {
        last = start = t;
        return;
    }
    if (n < sizeof ms / sizeof ms[0])
        ms[n++] = (double)(t - last) * 1e-6;
    last = t;
    if (t - start < (uint64_t)every_s * 1000000000ull || n < 10)
        return;
    double sum = 0;
    unsigned over = 0;
    for (unsigned i = 0; i < n; i++) {
        sum += ms[i];
        over += ms[i] > 50.0;
    }
    qsort(ms, n, sizeof ms[0], cmp_double);
    double p99 = ms[(unsigned)(n * 0.99)], p999 = ms[(unsigned)(n * 0.999)];
    mgl_log("frame times (%.0f s): %u frames, %.1f fps avg, 1%% low %.1f fps (%.1f ms), 0.1%% low %.1f fps (%.1f ms), "
            "worst %.1f ms, %u over 50 ms", (double)(t - start) * 1e-9, n, 1000.0 * n / sum, 1000.0 / p99, p99,
            1000.0 / p999, p999, ms[n - 1], over);
    n = 0;
    start = t;
}

/* A swap of 50 ms or more logs where its time went (at most 40 times), to tell a stall waiting for the screen
   (drawable) from one waiting for the GPU (fence) or in our own end-of-frame work. */
enum { SW_RT, SW_GSC, SW_SHOT, SW_ENCODERS, SW_DRAWABLE, SW_PRESENT, SW_COMMIT, SW_AFTER, SW_FENCE, SW_N };
static uint64_t sw_t[SW_N], sw_last;
static void sw_mark(int stage)
{
    uint64_t t = now_ns();
    sw_t[stage] += t - sw_last;
    sw_last = t;
}

static void sw_report(uint64_t start)
{
    static const char *const names[SW_N] = {"ray-tracing scene", "geometry cache", "screenshots", "ending passes",
                                            "waiting for a drawable", "presenting", "commit", "after commit", "waiting for the GPU"};
    static int logged;
    uint64_t total = now_ns() - start;
    if (total >= 50000000ull && logged < 40) {
        char buf[512];
        int n = 0;
        for (int i = 0; i < SW_N; i++)
            if (sw_t[i] >= 1000000ull)
                n += snprintf(buf + n, sizeof buf - (size_t)n, ", %s %.1f", names[i], (double)sw_t[i] * 1e-6);
        mgl_log("slow swap: %.1f ms%s (ms; %d presents waiting)", (double)total * 1e-6, n ? buf : ", no single step over 1 ms",
                atomic_load(&presents_waiting));
        if (++logged == 40)
            mgl_log("slow swap: no more of these logged");
    }
    memset(sw_t, 0, sizeof sw_t);
}

/* Memory report, every MGL_MEM_REPORT seconds (default 60, 0 = off): the whole process (phys_footprint, what
   Activity Monitor shows as Memory; it includes the Java heap) and what of it is mcmetal's Metal memory. */
static void mem_report(void)
{
    static double every = -1;
    static uint64_t last;
    if (every < 0) {
        const char *e = getenv("MGL_MEM_REPORT");
        every = e && *e ? atof(e) : 60;
    }
    uint64_t t = now_ns();
    if (every <= 0 || (last && (double)(t - last) < every * 1e9))
        return;
    last = t;
    task_vm_info_data_t vm;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    double proc = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) == KERN_SUCCESS ? vm.phys_footprint : 0;
    static double proc_peak;
    if (proc > proc_peak)
        proc_peak = proc;
    const double MB = 1048576.0;
    double metal = (double)dev.currentAllocatedSize, tr = (double)tr_n * TR_CHUNK, gsc = (double)gsc_nslabs * GSC_SLAB;
    double bufs = (double)buf_live_bytes - tr, clr = clear_src ? (double)clear_src.length : 0;
    double other = metal - tex_bytes - bufs - tr - gsc - priv_bytes - clr;
    mgl_log("memory: process %.0f MB (most so far %.0f), Metal %.0f MB: textures %.0f MB (%ld), buffers %.0f MB (%.0f "
            "pooled, %.0f of it purgeable), transient chunks %.0f MB (%d), geometry-shader cache %.0f MB, private "
            "copies %.0f MB, other %.0f MB (ray tracing, pipelines, window); freed after 5 s unused so far: %lu chunks "
            "and %lu pooled buffers, %.0f MB%s", proc / MB, proc_peak / MB, metal / MB, tex_bytes / MB, tex_count, bufs / MB,
            buf_pooled_bytes / MB, buf_purgeable_bytes / MB, tr / MB, tr_n, gsc / MB, priv_bytes / MB, other / MB,
            trim_freed_chunks, trim_freed_bufs, trim_freed_bytes / MB, mem_trim() ? "" : " (MGL_MEM_TRIM=0)");
}

MGL_EXPORT void mgl_glfw_swap(void *ctx)
{
    frame_times_tick();
    uint64_t sw_start = sw_last = now_ns();
    mgl_ctx *c = ctx;
    update_size(c);
    mgl_rt_end_frame(); /* ray tracing: rebuild the scene from this frame's terrain sections */
    sw_mark(SW_RT);
    gsc_end_frame();
    mem_sweep();
    mem_report();
    sw_mark(SW_GSC);
    if (!mgl->window_color) {
        commit();
        return;
    }
    mgl_shot_tick(); /* MGL_SHOT_DIR test screenshots */
    sw_mark(SW_SHOT);
    end_encoders();
    sw_mark(SW_ENCODERS);
    /* Vsync off: like OpenGL, don't wait for the screen. When two finished frames are already waiting to be shown,
       this frame is drawn but not presented, instead of blocking in nextDrawable (which held the game at twice the
       refresh rate, 240 fps on a 120 Hz screen). Frames the GPU is still drawing don't count: when the GPU is
       the limit every frame is shown. MGL_PRESENT_EVERY_FRAME=1: old behaviour. */
    static int every_frame = -1;
    if (every_frame < 0)
        every_frame = getenv("MGL_PRESENT_EVERY_FRAME") && atoi(getenv("MGL_PRESENT_EVERY_FRAME"));
    int skip = !c->vsync && !every_frame && atomic_load(&presents_waiting) >= 2;
    uint64_t t_draw = now_ns();
    id<CAMetalDrawable> drawable = skip ? nil : [c->layer nextDrawable];
    prof.wait_ns += now_ns() - t_draw;
    pace_wait_ns += now_ns() - t_draw;
    prof.skipped_presents += skip;
    sw_mark(SW_DRAWABLE);
    if (drawable) {
        watch_drawable(drawable);
        /* Frame interpolation: the made-up frame, then the real one half a frame after it. deltaTime is the paced
           real frame time once there is one. */
        double frame_s = c->paced_fps > 0 ? 1.0 / c->paced_fps : c->avg_frame_ms > 0 ? c->avg_frame_ms * 1e-3 : 1.0 / 60;
        if (fg_enabled())
            fg_time_stage(FG_GAME);
        id<MTLTexture> mid = fg_paused ? nil : fg_interpolate(frame_s);
        if (mid)
            fg_time_stage(FG_MAKE);
        static int fg_no_present = -1;
        if (fg_no_present < 0)
            fg_no_present = opt("MCMETAL_FG_NO_PRESENT");
        if (mid && fg_no_present) /* test: make the extra frame but don't show it (its GPU cost alone) */
            mid = nil;
        if (mid) {
            /* Real frames paced like without interpolation, at a rate whose double divides the screen's refresh
               (on 120 Hz: 60 or 30 real, shown as 120 or 60), each shown frame for exactly half a real one.
               Not from the measured frame time: the GPU time per frame grows when presents wait, so that would
               slow the game down step by step (measured: SEUS fell to 10-12 fps). */
            int fps = choose_paced_fps(c, 2);
            if (fps != c->paced_fps) {
                c->paced_fps = fps;
                atomic_store(&pace_target_ms, 500.0 / fps);
                mgl_log("frame interpolation: %d real fps shown as an even %d (frame time %.1f ms)", fps, 2 * fps, c->avg_frame_ms);
            }
            double half = 0.5 / fps;
            static int passthru = -1;
            if (passthru < 0)
                passthru = opt("MCMETAL_FG_PASSTHRU");
            /* test: MCMETAL_FG_PASSTHRU=1 shows the real frame in the made-up frame's place (same presenting, no
               made-up picture shown), to tell the interpolator's cost from the cost of showing its output */
            draw_to_drawable(c, passthru ? OBJ(id<MTLTexture>, mgl->window_color->mtl) : mid, drawable);
            static int show_mid = -1;
            if (show_mid < 0)
                show_mid = opt("MCMETAL_FG_SHOW_MID");
            if (show_mid) { /* test: show only made-up frames (test screenshots of the upscaled frame then see them) */
                [current_cb() presentDrawable:drawable afterMinimumDuration:2 * half];
                fg_time_stage(FG_SHOW_MID);
                drawable = nil;
            } else {
                [current_cb() presentDrawable:drawable afterMinimumDuration:half];
                fg_time_stage(FG_SHOW_MID);
                commit(); /* send the made-up frame on its way before waiting for the second drawable */
                uint64_t t_d2 = now_ns();
                drawable = [c->layer nextDrawable];
                prof.wait_ns += now_ns() - t_d2;
                pace_wait_ns += now_ns() - t_d2;
                if (drawable) {
                    watch_drawable(drawable);
                    draw_to_drawable(c, OBJ(id<MTLTexture>, mgl->window_color->mtl), drawable);
                    [current_cb() presentDrawable:drawable afterMinimumDuration:half];
                    fg_time_stage(FG_SHOW_REAL);
                }
            }
        } else
            draw_to_drawable(c, OBJ(id<MTLTexture>, mgl->window_color->mtl), drawable);
        uint64_t t = now_ns(), gpu = atomic_load(&pace_gpu_ns);
        if (c->last_swap_ns) {
            double cpu = (double)(t - c->last_swap_ns - (pace_wait_ns - c->last_wait_ns)) * 1e-6;
            double gms = (double)(gpu - c->last_gpu_ns) * 1e-6, ms = cpu > gms ? cpu : gms;
            if (ms > 0 && ms < 250) {
                c->avg_frame_ms = c->avg_frame_ms ? c->avg_frame_ms * 0.9 + ms * 0.1 : ms;
                if (c->win_n < 64)
                    c->win_cost[c->win_n++] = ms;
            }
        }
        c->last_swap_ns = t;
        c->last_wait_ns = pace_wait_ns;
        c->last_gpu_ns = gpu;
        if (fg_enabled() && opt_pacing > 0 && c->vsync)
            fg_decide(c);
        if (mid || !drawable) {
        } else if (opt_pacing > 0 && c->vsync && c->avg_frame_ms > 0) {
            int fps = choose_paced_fps(c, 1);
            if (fps != c->paced_fps) {
                c->paced_fps = fps;
                atomic_store(&pace_target_ms, 1000.0 / fps);
                mgl_log("frame pacing: presenting at an even %d fps (frame time %.1f ms)", fps, c->avg_frame_ms);
            }
            [current_cb() presentDrawable:drawable afterMinimumDuration:1.0 / fps];
        } else {
            [current_cb() presentDrawable:drawable];
        }
        if (!mid && fg_enabled())
            fg_time_stage(FG_SHOW_REAL);
    }
    sw_mark(SW_PRESENT);
    commit();
    sw_mark(SW_COMMIT);
    priv_promote();
    archive_maybe_save();
    frames_presented = c->frames + 1;
    note_started(frame_draws);
    if (++c->frames % 600 == 1)
        mgl_log("presented frame %llu (%dx%d), %lu pipelines; this frame: %lu draws (%lu terrain sections), %lu dispatches%s",
                c->frames, c->w, c->h, (unsigned long)pipelines.count, frame_draws, frame_sections, frame_dispatches,
                frame_probes ? [NSString stringWithFormat:@", %lu probed draws", frame_probes].UTF8String : "");
    if (opt_profile > 0)
        profile_frame(frame_draws);
    if (opt_profile > 0 || opt("MGL_PRESENT_STATS"))
        present_stats_report();
    fg_timing_report();
    frame_draws = frame_sections = frame_dispatches = frame_probes = 0;
    /* keep at most ~2 frames in flight: wait for the frame before last (by frame, not command buffer, since an
       interpolated frame commits several) */
    static uint64_t frame_end_serial[2];
    uint64_t before_last = frame_end_serial[c->frames & 1];
    frame_end_serial[c->frames & 1] = submitted_serial;
    sw_mark(SW_AFTER);
    if (before_last)
        mglb_fence_wait(before_last, 100000000ull);
    sw_mark(SW_FENCE);
    sw_report(sw_start);
}
