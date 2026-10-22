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
    unsigned long sh_draws, sh_tris; /* draws and triangles into square targets of 1024+ (shadow maps), as tools/glcount.c counts */
    unsigned long tex_views, pipe_lookups, big_uniforms; /* per-draw texture views made, pipeline dictionary lookups, >4 KB uniform copies */
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
        mgl_log("profile: GPU pass timing %s", pt_ok ? "on" : "not supported on this GPU");
        [dev sampleTimestamps:&pt_cal_cpu gpuTimestamp:&pt_cal_gpu];
    }
    if (!pt_ok)
        return;
    pt_frame *f = calloc(1, sizeof *f);
    f->sb = pt_pool[pt_next++ % 6];
    pt_cur = f;
    [c addCompletedHandler:^(id<MTLCommandBuffer> done) {
      (void)done;
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
    if (renc) { [renc endEncoding]; renc = nil; }
    if (benc) { [benc endEncoding]; benc = nil; }
    if (cenc) { [cenc endEncoding]; cenc = nil; }
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

static id<MTLComputeCommandEncoder> compute_encoder(void)
{
    if (!gs_recording)
        gs_flush();
    if (cenc)
        return cenc;
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
            cenc = [c computeCommandEncoderWithDescriptor:d];
        } else {
            cenc = [c computeCommandEncoder];
        }
    }
    prof.computes++;
    return cenc;
}

/* ================================================================ buffers (pooled by size class) */

struct mglb_buffer {
    void *mtl;
    void *ptr;
    size_t size, cap;
    uint64_t last_use;
    uint64_t gpu_write; /* command buffer of the last GPU copy into it (mglb_buffer_copy) */
    struct mglb_buffer *next_free;
};

#define POOL_CLASSES 32
static struct mglb_buffer *pool[POOL_CLASSES];
static int pool_count[POOL_CLASSES];

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

static size_t buf_live_bytes, buf_pooled_bytes; /* MGL_PROFILE: Metal buffer memory we hold, and of it in the pool */
static unsigned long tr_oneoff, tr_waits;       /* transient allocations that fell back to their own buffer; waits for a chunk */
int mglb_fence_wait(uint64_t id, uint64_t timeout_ns);
mglb_buffer *mglb_buffer_new(size_t size)
{
    init_device();
    int c = size_class(size);
    size_t cap = (size_t)256 << c;
    if (cap < size)
        cap = size;
    uint64_t done = atomic_load(&completed_serial);
    for (struct mglb_buffer **pp = &pool[c]; *pp; pp = &(*pp)->next_free) {
        struct mglb_buffer *b = *pp;
        if (b->last_use <= done && b->cap >= size) {
            *pp = b->next_free;
            pool_count[c]--;
            buf_pooled_bytes -= b->cap;
            b->next_free = NULL;
            b->size = size;
            return b;
        }
    }
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

void mglb_buffer_release(mglb_buffer *b)
{
    if (!b)
        return;
    int c = size_class(b->cap);
    if (pool_count[c] < (b->cap > ((size_t)16 << 20) ? 2 : 64)) { /* don't hoard big buffers */
        b->next_free = pool[c];
        pool[c] = b;
        pool_count[c]++;
        buf_pooled_bytes += b->cap;
        return;
    }
    buf_live_bytes -= b->cap;
    release_obj(b->mtl); /* Metal keeps it alive for command buffers still using it */
    free(b);
}

int mglb_buffer_in_use(mglb_buffer *b)
{
    return b && b->last_use > atomic_load(&completed_serial);
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
static struct { mglb_buffer *b; size_t used; } tr_chunk[TR_MAX];
static int tr_n, tr_cur = -1;

typedef struct { id<MTLBuffer> buf; NSUInteger off; void *ptr; } transient_t;

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
            mglb_buffer *b = mglb_buffer_new(TR_CHUNK);
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
};
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
    free(t);
}

void mglb_texture_upload(mglb_texture *t, int level, int x, int y, int z, int w, int h, int d, const void *data,
                         size_t bytes_per_row, size_t bytes_per_image)
{
    if (!t || t->pf == MTLPixelFormatDepth32Float_Stencil8)
        return;
    size_t bpt = (size_t)bytes_per_texel(t->pf), row = bpt * (size_t)w, img = row * (size_t)h;
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
    if (strstr(msl, "mgl_vscale_")) {
        if (lib_out)
            *lib_out = lib;
        /* no constants set: every scale is 1 (a function with constants must come from this call) */
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

static void save_at_exit(void) { archive_save(); }

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
            id<MTLFunction> f = compile_fn(msl_compute, @"compute", err);
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
    "  int lmin, lmax; uint lcap; };\n"
    /* per triangle, 12 words, for mcm_trace (core/mgl_program.c reads the same layout):
         0-2 packed texture coordinates (Sodium's 15-bit u/v)   3 alpha cutoff index (0 = solid) | 0x100 translucent
         4-6 vertex colours RGBA8   7 face normal (octahedral snorm16x2)   8-10 light (block, sky bytes)
         11 Iris block id + 1 (0 = unknown)
       Iris's extended vertex format keeps no material bits, so its triangles all get the 0.1 alpha test (solid
       textures are opaque, so this only costs time). */
    "kernel void rt_decode(device const uchar *vb [[buffer(0)]], device const uchar *ib [[buffer(1)]],\n"
    "    device packed_float3 *out [[buffer(2)]], constant RtInfo &n [[buffer(3)]], device uint *tri [[buffer(4)]],\n"
    "    device atomic_uint *lc [[buffer(5)]], uint t [[thread_position_in_grid]]) {\n"
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
    "    out[i] = p[k];\n"
    "    r[k] = w[3] & 0x7FFF7FFFu; r[4 + k] = w[2]; r[8 + k] = w[4] & 0xFFFFu;\n"
    "    if (k == 0) {\n"
    "      r[3] = (n.stride > 20 ? 1u : (w[4] >> 17) & 3u) | (n.translucent ? 0x100u : 0u);\n"
    "      r[11] = n.ent_off >= 0 ? (*(device const uint *)(v + n.ent_off)) >> 1 : 0u; }\n"
    "  }\n"
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
    /* per section, per frame: light candidates -> one light per block (hash on the block position) */
    "struct RtLightSec { int3 off; float3 region; uint cap; };\n"
    "kernel void rt_lights(device const uint *lc [[buffer(0)]], constant RtLightSec &s [[buffer(1)]],\n"
    "    device atomic_uint *hash [[buffer(2)]], device atomic_uint *lights [[buffer(3)]], uint t [[thread_position_in_grid]]) {\n"
    "  if (t >= min(lc[0], s.cap)) return;\n"
    "  device const uint *e = lc + 4 + t * 4;\n"
    "  float3 in = float3(as_type<float>(e[0]), as_type<float>(e[1]), as_type<float>(e[2]));\n"
    "  int3 b = int3(floor(in)) + s.off + 512;\n"
    "  if (any(b < 0) || any(b > 1023)) return;\n"
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

static void bind_stage_resources(id<MTLRenderCommandEncoder> e, id<MTLComputeCommandEncoder> c, const mgl_draw *d, int s)
{
    if (d->uniforms[s] && d->uniform_size[s]) {
        NSUInteger n = (NSUInteger)d->uniform_size[s];
        if (n <= 4096) {
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
        if (c) [c setBuffer:b offset:d->ubo_offset[i] atIndex:(NSUInteger)(MGL_BUF_UBO_BASE + i)];
        else if (s == 0) [e setVertexBuffer:b offset:d->ubo_offset[i] atIndex:(NSUInteger)(MGL_BUF_UBO_BASE + i)];
        else [e setFragmentBuffer:b offset:d->ubo_offset[i] atIndex:(NSUInteger)(MGL_BUF_UBO_BASE + i)];
        use_buffer(d->ubo[i]);
    }
    for (int i = 0; i < MGL_MAX_SSBOS; i++) {
        if (!d->ssbo[i])
            continue;
        id<MTLBuffer> b = OBJ(id<MTLBuffer>, d->ssbo[i]->mtl);
        NSUInteger at = (NSUInteger)(MGL_BUF_SSBO_BASE + i);
        if (c) [c setBuffer:b offset:d->ssbo_offset[i] atIndex:at];
        else if (s == 0) [e setVertexBuffer:b offset:d->ssbo_offset[i] atIndex:at];
        else [e setFragmentBuffer:b offset:d->ssbo_offset[i] atIndex:at];
        use_buffer(d->ssbo[i]);
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
                tex = swizzled_view(tex, bt->swizzle);
                if (!bt->is_image && tex) {
                    release_obj(x->swz_view);
                    x->swz_view = retain_obj(tex);
                    memcpy(x->swz, bt->swizzle, sizeof x->swz);
                }
            }
        }
        id<MTLSamplerState> smp = bt->is_image || i >= 16 ? nil : get_sampler(&bt->sampler, bt->is_shadow);
        if (c) {
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
        [e setVertexBufferOffset:(NSUInteger)((long)vb->offset + base * vb->stride) atIndex:(NSUInteger)(MGL_BUF_VERTEX_BASE + i)];
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
    if (skip_program(d))
        return;
    if (dump_this_frame() && getenv("MGL_FRAME_DUMP_TEXELS") && d->multi_n == 0 && d->count <= 6)
        dump_texels(d);
    id<MTLRenderPipelineState> ps = get_pipeline(d, &d->target);
    if (!ps)
        return;
    id<MTLRenderCommandEncoder> e = pass_for_draw(d);
    pt_label(d->program->label);
    [e setRenderPipelineState:ps];
    int probe = probe_program(d);
    [e setDepthStencilState:get_depth_state(d->depth_test && d->target.depth && !probe, /* GL: no depth writes with the test off */
                                       d->depth_test && d->depth_write && d->target.depth && !probe, d->depth_func)];
    [e setViewport:(MTLViewport){d->viewport[0], d->viewport[1], d->viewport[2], d->viewport[3], 0, 1}];
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
    [e setScissorRect:sr];
    [e setCullMode:!d->cull || probe ? MTLCullModeNone : d->cull_face == GL_FRONT ? MTLCullModeFront : MTLCullModeBack];
    /* translated vertex shaders flip Y, which flips winding */
    [e setFrontFacingWinding:d->front_face == GL_CW ? MTLWindingCounterClockwise : MTLWindingClockwise];
    if (d->polygon_offset_enabled)
        [e setDepthBias:d->polygon_offset_units slopeScale:d->polygon_offset_factor clamp:0];
    else
        [e setDepthBias:0 slopeScale:0 clamp:0];
    for (int i = 0; i < d->num_vbufs; i++) {
        [e setVertexBuffer:OBJ(id<MTLBuffer>, d->vbufs[i].buf->mtl) offset:d->vbufs[i].offset
                   atIndex:(NSUInteger)(MGL_BUF_VERTEX_BASE + i)];
        use_buffer(d->vbufs[i].buf);
    }
    bind_stage_resources(e, nil, d, 0);
    bind_stage_resources(e, nil, d, 1);
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
    if (d->multi_n > 0) {
        id<MTLBuffer> ib = OBJ(id<MTLBuffer>, d->index_buf->mtl);
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
                     indexBuffer:OBJ(id<MTLBuffer>, d->index_buf->mtl) indexBufferOffset:d->index_offset
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

/* Geometry-shader emulation (mgl_gs.c). The compute stage gets: 21 attribute descriptors, 22..25 raw vertex
   buffers, 26 index buffer, 27 emitted vertex records, 28 per-primitive vertex counts. The passthrough vertex
   stage reads 27/28 and turns each strip into a triangle list. */
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
    prof.gs_bytes += out_bytes;
    transient_t ov = transient(out_bytes), oc = transient((size_t)triangles * 4);
    if (!ov.buf || !oc.buf)
        return;
    id<MTLBuffer> ovb = ov.buf, ocb = oc.buf;
    NSUInteger ovo = ov.off, oco = oc.off;

    /* 1. vertex + geometry stages as one compute job, one thread per input triangle */
    if (gs_batch < 0)
        gs_batch = !getenv("MGL_GS_BATCH") || atoi(getenv("MGL_GS_BATCH")) != 0;
    if (!gs_batch || !same_target(&d->target, &gs_target) || gs_pending.count >= 2048)
        gs_flush();
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
    id<MTLComputeCommandEncoder> c = compute_encoder();
    keep_clears = 0;
    gs_recording = 0;
    [c setComputePipelineState:OBJ(id<MTLComputePipelineState>, d->program->compute)];
    bind_stage_resources(nil, c, d, 2);
    if (d->uses_scene)
        bind_scene(nil, c);
    [c setBytes:desc length:sizeof desc atIndex:MGL_BUF_INTERNAL_BASE];
    for (int i = 0; i < 4; i++) { /* unused slots get any valid buffer */
        mglb_buffer *b = i < d->num_vbufs ? d->vbufs[i].buf : d->num_vbufs ? d->vbufs[0].buf : NULL;
        [c setBuffer:b ? OBJ(id<MTLBuffer>, b->mtl) : ovb offset:0 atIndex:(NSUInteger)(MGL_BUF_INTERNAL_BASE + 1 + i)];
        use_buffer(b);
    }
    [c setBuffer:d->index_buf ? OBJ(id<MTLBuffer>, d->index_buf->mtl) : ovb offset:0 atIndex:MGL_BUF_INTERNAL_BASE + 5];
    use_buffer(d->index_buf);
    [c setBuffer:ovb offset:ovo atIndex:MGL_BUF_INTERNAL_BASE + 6];
    [c setBuffer:ocb offset:oco atIndex:MGL_BUF_INTERNAL_BASE + 7];
    NSUInteger lx = (NSUInteger)(d->local_size[0] > 0 ? d->local_size[0] : 64);
    [c dispatchThreadgroups:MTLSizeMake(((NSUInteger)triangles + lx - 1) / lx, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(lx, 1, 1)];

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
        if (visible) {
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
    for (gs_play f in list)
        f(e);
    flushing = 0;
}

/* ================================================================ ray tracing (step 2) */

/* One primitive acceleration structure per terrain section, cached by (buffer, range, generation). */
@interface RtSection : NSObject
@property(nonatomic, strong) id<MTLAccelerationStructure> as;
@property(nonatomic) uint64_t last_frame;
@property(nonatomic) mglb_buffer *tris; /* per-triangle texture coordinates + alpha cutoff (rt_decode) */
@property(nonatomic) mglb_buffer *lights; /* light candidates: count, then (position, id) per face */
@property(nonatomic) uint32_t lcap;
@end
@implementation RtSection
- (void)dealloc
{
    mglb_buffer_release(_tris);
    mglb_buffer_release(_lights);
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

static NSMutableDictionary<NSData *, RtSection *> *rt_sections;
static id<MTLAccelerationStructure> rt_scene;
static NSMutableArray<id<MTLAccelerationStructure>> *rt_scene_parts; /* must be resident wherever the scene is used */
static __unsafe_unretained id<MTLResource> *rt_parts_c;               /* same objects as a C array for useResources */
static NSUInteger rt_parts_n;
static uint64_t rt_frame;

static id<MTLComputePipelineState> rt_decode_pipeline(void)
{
    static id<MTLComputePipelineState> ps;
    if (!ps) {
        NSError *e = nil;
        id<MTLFunction> f = builtin(@"rt_decode");
        ps = f ? [dev newComputePipelineStateWithFunction:f error:&e] : nil;
        if (!ps)
            mgl_log("rt_decode pipeline: %s", e ? e.localizedDescription.UTF8String : "no function");
    }
    return ps;
}

static id<MTLAccelerationStructure> build_as(MTLAccelerationStructureDescriptor *desc)
{
    MTLAccelerationStructureSizes sz = [dev accelerationStructureSizesWithDescriptor:desc];
    id<MTLAccelerationStructure> as = [dev newAccelerationStructureWithSize:sz.accelerationStructureSize];
    mglb_buffer *scratch = mglb_buffer_new(sz.buildScratchBufferSize ? sz.buildScratchBufferSize : 16);
    if (!as || !scratch) {
        mglb_buffer_release(scratch);
        return nil;
    }
    end_encoders();
    id<MTLAccelerationStructureCommandEncoder> e = [current_cb() accelerationStructureCommandEncoder];
    [e buildAccelerationStructure:as descriptor:desc scratchBuffer:OBJ(id<MTLBuffer>, scratch->mtl) scratchBufferOffset:0];
    [e endEncoding];
    use_buffer(scratch);
    mglb_buffer_release(scratch);
    return as;
}

static unsigned long rt_built, rt_built_tris; /* section structures built since the last MGL_RT_DEBUG line */
static unsigned long rt_rebuilt; /* of those, ranges built before (vertex data rewritten, or another block-id offset) */
static NSMutableSet<NSData *> *rt_ranges; /* MGL_RT_DEBUG=1: every range built, without generation and offsets */

static id<MTLAccelerationStructure> section_as(const mgl_rt_geom *g, mglb_buffer **tris_out, RtSection **sec_out)
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
    NSData *key = [[NSData alloc] initWithBytes:&k length:sizeof k];
    RtSection *s = rt_sections[key];
    if (s) {
        s.last_frame = rt_frame;
        *tris_out = s.tris;
        *sec_out = s;
        return s.as;
    }
    rt_built++;
    rt_built_tris += (unsigned long)(g->count / 3);
    if (getenv("MGL_RT_DEBUG") && atoi(getenv("MGL_RT_DEBUG"))) {
        rt_key r = k;
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
    id<MTLComputePipelineState> ps = rt_decode_pipeline();
    int tris = g->count / 3;
    if (!ps || tris <= 0)
        return nil;
    /* 1. decode the section's vertices into a float3 triangle list */
    mglb_buffer *pos = mglb_buffer_new((size_t)tris * 3 * 12);
    mglb_buffer *tri = mglb_buffer_new((size_t)tris * 48);
    if (!pos || !tri) {
        mglb_buffer_release(pos);
        mglb_buffer_release(tri);
        return nil;
    }
    uint32_t lcap = mgl_rt_light_ids[0] >= 0 && g->ent_off >= 0 ? (uint32_t)(tris < 1024 ? tris : 1024) : 0;
    mglb_buffer *lights = lcap ? mglb_buffer_new(16 + (size_t)lcap * 16) : NULL;
    if (!lights)
        lcap = 0;
    else
        *(uint32_t *)lights->ptr = 0; /* candidate count */
    struct { uint32_t vbase, stride, ioff, itype, count; int32_t base_vertex, ent_off; uint32_t translucent;
             int32_t lmin, lmax; uint32_t lcap; } info = {
        (uint32_t)g->vbase, (uint32_t)g->stride, (uint32_t)g->ioff, g->itype == GL_UNSIGNED_SHORT ? 2u : 4u,
        (uint32_t)(tris * 3), g->base_vertex, g->ent_off, g->translucent ? 1u : 0u,
        mgl_rt_light_ids[0], mgl_rt_light_ids[1], lcap};
    id<MTLComputeCommandEncoder> c = compute_encoder();
    [c setComputePipelineState:ps];
    [c setBuffer:OBJ(id<MTLBuffer>, g->vbuf->mtl) offset:0 atIndex:0];
    [c setBuffer:OBJ(id<MTLBuffer>, g->ibuf->mtl) offset:0 atIndex:1];
    [c setBuffer:OBJ(id<MTLBuffer>, pos->mtl) offset:0 atIndex:2];
    [c setBytes:&info length:sizeof info atIndex:3];
    [c setBuffer:OBJ(id<MTLBuffer>, tri->mtl) offset:0 atIndex:4];
    [c setBuffer:OBJ(id<MTLBuffer>, (lights ? lights : tri)->mtl) offset:0 atIndex:5];
    use_buffer(tri);
    use_buffer(lights);
    [c dispatchThreads:MTLSizeMake((NSUInteger)tris, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    use_buffer(g->vbuf);
    use_buffer(g->ibuf);
    /* 2. build its acceleration structure (the position buffer is only needed during the build) */
    MTLAccelerationStructureTriangleGeometryDescriptor *tg = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    tg.vertexBuffer = OBJ(id<MTLBuffer>, pos->mtl);
    tg.vertexStride = 12;
    tg.vertexFormat = MTLAttributeFormatFloat3;
    tg.triangleCount = (NSUInteger)tris;
    tg.opaque = NO; /* mcm_trace runs the alpha test on cutout triangles (grass, leaves) */
    MTLPrimitiveAccelerationStructureDescriptor *pd = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    pd.geometryDescriptors = @[ tg ];
    id<MTLAccelerationStructure> as = build_as(pd);
    use_buffer(pos);
    mglb_buffer_release(pos);
    if (!as) {
        mglb_buffer_release(tri);
        mglb_buffer_release(lights);
        return nil;
    }
    if (!rt_sections)
        rt_sections = [NSMutableDictionary dictionary];
    s = [RtSection new];
    s.as = as;
    s.tris = tri;
    s.lights = lights;
    s.lcap = lcap;
    s.last_frame = rt_frame;
    rt_sections[key] = s;
    *tris_out = tri;
    *sec_out = s;
    return as;
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
    tg.opaque = NO; /* the same path as terrain: mcm_opaque_at passes them at once (cutoff byte 0) */
    MTLPrimitiveAccelerationStructureDescriptor *pd = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    pd.geometryDescriptors = @[ tg ];
    pd.usage = MTLAccelerationStructureUsagePreferFastBuild;
    use_buffer(pos);
    id<MTLAccelerationStructure> as = build_as(pd);
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
    for (int i = 0; i < n; i++) {
        mglb_buffer *tris = NULL;
        RtSection *sec = nil;
        id<MTLAccelerationStructure> as = section_as(&g[i], &tris, &sec);
        if (!as)
            continue;
        secs[count] = sec;
        sec_geom[count] = i;
        addr[count] = OBJ(id<MTLBuffer>, tris->mtl).gpuAddress;
        rt_tris_c[count] = OBJ(id<MTLBuffer>, tris->mtl);
        MTLAccelerationStructureUserIDInstanceDescriptor *d = &descs[count];
        memset(d, 0, sizeof *d);
        /* column-major 4x3: identity rotation, translation = camera-relative region origin */
        d->transformationMatrix.columns[0] = MTLPackedFloat3Make(1, 0, 0);
        d->transformationMatrix.columns[1] = MTLPackedFloat3Make(0, 1, 0);
        d->transformationMatrix.columns[2] = MTLPackedFloat3Make(0, 0, 1);
        d->transformationMatrix.columns[3] = MTLPackedFloat3Make(g[i].region[0], g[i].region[1], g[i].region[2]);
        /* no instance Opaque flag: it overrides geometry opaque = NO, so cutout triangles would never reach the
           alpha test in mcm_trace (every hit was solid; foliage cast square shadows) */
        d->options = MTLAccelerationStructureInstanceOptionNone;
        d->mask = g[i].translucent ? 0x02 : 0x01; /* mcm_trace sees solid and cutout terrain only (mask 1) */
        d->accelerationStructureIndex = (uint32_t)count;
        d->userID = (uint32_t)i;
        [parts addObject:as];
        count++;
    }
    /* forget sections unused for ~4 s */
    NSMutableArray<NSData *> *old = [NSMutableArray array];
    [rt_sections enumerateKeysAndObjectsUsingBlock:^(NSData *k, RtSection *s, BOOL *stop) {
      if (rt_frame - s.last_frame > 240)
          [old addObject:k];
    }];
    [rt_sections removeObjectsForKeys:old];
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
    rt_scene = build_as(idesc);
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
                "structures (%luk triangles) built in the last %d frames, %lu of them ranges built before",
                count - (ent ? 1 : 0), n, (unsigned long)rt_sections.count, ent ? rt_ent_n : 0, rt_built,
                rt_built_tris / 1000, logged == 1 ? 1 : 120, rt_rebuilt);
        rt_built = rt_built_tris = rt_rebuilt = 0;
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
    c->w = (int)(up ? pt.width : px.width);
    c->h = (int)(up ? pt.height : px.height);
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

   Like MCMETAL_UPSCALE=1 the game renders at half the Retina size each way, but MetalFX's temporal upscaler
   rebuilds the full-size world picture from this frame and the last ones (using the world snapshot's depth and
   camera motion, the same as frame interpolation), instead of sharpening one frame on its own. The HUD isn't
   in the snapshot: pixels where the finished frame differs from the world picture (and their neighbours) come
   from the spatial upscaler instead, so text and the hotbar don't smear. Needs a shader pack (Iris's camera
   uniforms); without one, and in menus, frames use the spatial upscaler. No jitter: packs do their own TAA.
   Measured on an M3 Max (1728x965 -> 3456x1930, 2026-10-22): NOT worth it yet. ~2-4 ms more GPU (SEUS 25.4 ->
   27.2 ms, Complementary 5.4 -> 9.8), so pacing drops a step (SEUS 40 -> 30, Complementary 118 -> 59), and the
   picture is no sharper (very slightly softer on SEUS): without jitter there's no sub-pixel detail to gather.
   Kept as an experiment for a jittered path. */
static int tu_enabled(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MCMETAL_UPSCALE");
        on = e && atoi(e) == 2;
        if (on)
            mgl_log("temporal upscaler: on (with a shader pack; spatial otherwise)");
    }
    return on;
}

static struct {
    id fx; /* id<MTLFXTemporalScaler> */
    id<MTLTexture> out, final;
    id<MTLRenderPipelineState> pipe;
    MTLPixelFormat pipe_fmt;
    NSUInteger ow, oh;
    int failed, reset, logged;
} tu = {.reset = 1};

static const char *tu_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 tu_vs(uint v [[vertex_id]]) { float2 p = float2((v << 1) & 2, v & 2); return float4(p * 2.0 - 1.0, 0.0, 1.0); }\n"
    /* all textures in GL row order, the output too: row r of each is the same place */
    "fragment float4 tu_fs(float4 pos [[position]], texture2d<float> world_up [[texture(0)]], texture2d<float> full_up [[texture(1)]],\n"
    "                      texture2d<float> full [[texture(2)]], texture2d<float> world [[texture(3)]]) {\n"
    "    uint2 o = uint2(pos.xy);\n"
    "    int2 isz = int2(full.get_width(), full.get_height());\n"
    "    int2 c = int2(pos.xy / float2(world_up.get_width(), world_up.get_height()) * float2(isz));\n"
    "    float m = 0.0;\n"
    "    for (int y = -1; y <= 1; y++)\n"
    "        for (int x = -1; x <= 1; x++) {\n"
    "            uint2 q = uint2(clamp(c + int2(x, y), int2(0), isz - 1));\n"
    "            float3 d = abs(full.read(q).rgb - world.read(q).rgb);\n"
    "            m = max(m, max(d.r, max(d.g, d.b)));\n"
    "        }\n"
    "    float4 r = m > 0.002 ? full_up.read(o) : world_up.read(o);\n"
    "    return float4(r.rgb, 1.0);\n"
    "}\n";

/* The finished frame (window_color, HUD included) upscaled to ow x oh with the world from the temporal upscaler,
   or nil (off, no fresh snapshot, or MetalFX can't): then the caller uses the spatial upscaler. */
static id<MTLTexture> tu_frame(mgl_ctx *c, id<MTLTexture> win, NSUInteger ow, NSUInteger oh)
{
    if (!tu_enabled() || tu.failed)
        return nil;
    if (fg.snap_frame != frames_presented + 1 || !fg.color[0] || (int)win.width != fg.w || (int)win.height != fg.h ||
        win.pixelFormat != fg.fmt) {
        tu.reset = 1;
        return nil;
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
            tu.failed = 1;
            return nil;
        }
        tu.fx = fx;
        tu.ow = ow;
        tu.oh = oh;
        tu.out = fg_texture(fg.fmt, (int)ow, (int)oh, fx.outputTextureUsage);
        tu.final = fg_texture(fg.fmt, (int)ow, (int)oh, MTLTextureUsageRenderTarget);
        tu.reset = 1;
        mgl_log("temporal upscaler: %dx%d -> %lux%lu", fg.w, fg.h, (unsigned long)ow, (unsigned long)oh);
    }
    if (!tu.pipe || tu.pipe_fmt != fg.fmt) {
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:tu_msl] options:nil error:&e];
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = [lib newFunctionWithName:@"tu_vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"tu_fs"];
        pd.colorAttachments[0].pixelFormat = fg.fmt;
        tu.pipe = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
        tu.pipe_fmt = fg.fmt;
        if (!tu.pipe) {
            mgl_log("temporal upscaler: HUD shader failed: %s", e.localizedDescription.UTF8String);
            tu.failed = 1;
            return nil;
        }
    }
    id<MTLTexture> hud = upscale(c, win, ow, oh); /* the whole frame, spatially, for the HUD's pixels */
    if (!hud)
        return nil;
    id<MTLFXTemporalScaler> fx = tu.fx;
    fx.colorTexture = fg.color[fg.cur];
    fx.depthTexture = fg.depth;
    fx.motionTexture = fg.motion;
    fx.outputTexture = tu.out;
    fx.inputContentWidth = fg.w;
    fx.inputContentHeight = fg.h;
    fx.jitterOffsetX = 0;
    fx.jitterOffsetY = 0;
    fx.motionVectorScaleX = (float)fg.w;
    fx.motionVectorScaleY = (float)fg.h;
    fx.depthReversed = NO;
    fx.reset = tu.reset;
    tu.reset = 0;
    [fx encodeToCommandBuffer:current_cb()];

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tu.final;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [current_cb() renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:tu.pipe];
    [e setFragmentTexture:tu.out atIndex:0];
    [e setFragmentTexture:hud atIndex:1];
    [e setFragmentTexture:win atIndex:2];
    [e setFragmentTexture:fg.color[fg.cur] atIndex:3];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    upscaled = tu.final; /* test screenshots */
    if (!tu.logged) {
        tu.logged = 1;
        mgl_log("temporal upscaler: first frame drawn");
    }
    return tu.final;
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
    if (mgl_merge_stats[0]) {
        mgl_log("profile: section ranges %.0f asked, %.0f drawn after merging back-to-back ones per frame",
                mgl_merge_stats[0] / f, mgl_merge_stats[1] / f);
        mgl_merge_stats[0] = mgl_merge_stats[1] = 0;
    }
    if (prof.gs_draws)
        mgl_log("profile: geometry shaders %.0f draws, %.0fk input triangles, %.1f MB of records per frame", prof.gs_draws / f,
                prof.gs_tris / f * 1e-3, prof.gs_bytes / f / 1048576.0);
    mgl_log("profile: buffers %.0f MB held (%.0f MB pooled), %d of %d transient chunks, %.1f one-off transient "
            "buffers and %.1f waits for a chunk per frame", buf_live_bytes / 1048576.0, buf_pooled_bytes / 1048576.0, tr_n,
            TR_MAX, tr_oneoff / f, tr_waits / f);
    tr_oneoff = tr_waits = 0;
    mgl_log("profile: cpu buffer traffic per frame: %.1f renames (%.2f MB copied, %.2f ms), %.1f glCopyBufferSubData "
            "(%.2f MB, %.2f ms), %.1f GPU copies (%.2f MB, %.1f CPU waits for one), %.0f glBufferData (%.2f MB); %.1f texture views made, %.1f pipeline lookups, %.1f big "
            "uniform blocks; %lu textures remade for image/view use", mgl_bstats.renames / f,
            mgl_bstats.rename_copy_bytes / f / 1048576.0, mgl_bstats.rename_ns / f * 1e-6, mgl_bstats.copies / f,
            mgl_bstats.copy_bytes / f / 1048576.0, mgl_bstats.copy_ns / f * 1e-6, mgl_bstats.gpu_copies / f,
            mgl_bstats.gpu_copy_bytes / f / 1048576.0, mgl_bstats.gpu_waits / f, mgl_bstats.datas / f,
            mgl_bstats.data_bytes / f / 1048576.0, prof.tex_views / f, prof.pipe_lookups / f, prof.big_uniforms / f,
            tex_upgrades);
    memset(&mgl_bstats, 0, sizeof mgl_bstats);
    if (pt_ok > 0)
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
        NSUInteger ow = drawable.texture.width, oh = drawable.texture.height;
        id<MTLTexture> up = src == OBJ(id<MTLTexture>, mgl->window_color->mtl) ? tu_frame(c, src, ow, oh) : nil;
        if (!up)
            up = upscale(c, src, ow, oh);
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
MGL_EXPORT void mgl_glfw_swap(void *ctx)
{
    mgl_ctx *c = ctx;
    update_size(c);
    mgl_rt_end_frame(); /* ray tracing: rebuild the scene from this frame's terrain sections */
    if (!mgl->window_color) {
        commit();
        return;
    }
    mgl_shot_tick(); /* MGL_SHOT_DIR test screenshots */
    end_encoders();
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
    commit();
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
    if (before_last)
        mglb_fence_wait(before_last, 100000000ull);
}
