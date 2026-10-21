/* Metal backend for libmcmetal: implements mgl_backend.h, and the mgl_glfw_* entry points our patched
   GLFW calls in place of NSOpenGLContext.

   Conventions (see mgl_xlate.h): Metal row r == GL row r in every texture, because translated vertex
   shaders flip Y. Only the final present flips the image for the window. */
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>
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
   MGL_FRAME_PACING=1     wait on completion signals instead of polling, and present at an even rate
                          (120/60/40/30 fps, whichever the last frames sustain; MGL_TARGET_FPS forces one) */
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
    uint64_t wait_ns, start_ns, frames;
} prof;
static _Atomic uint64_t prof_gpu_ns;
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
static int dump_this_frame(void)
{
    static long n = -2;
    if (n == -2) {
        const char *e = getenv("MGL_FRAME_DUMP");
        n = e ? atol(e) : -1;
    }
    return n >= 0 && (long long)frames_presented == n;
}
static int opt_archive = -1, opt_async_pipes = -1, opt_pacing = -1;
static void read_options(void)
{
    if (opt_archive >= 0)
        return;
    opt_archive = opt("MGL_BINARY_ARCHIVE") && getenv("MGL_CACHE_DIR");
    opt_async_pipes = opt("MGL_ASYNC_PIPELINES");
    opt_pacing = opt("MGL_FRAME_PACING");
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
        cb = [queue commandBuffer];
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
          if (opt_profile > 0 && done.GPUEndTime > done.GPUStartTime)
              atomic_fetch_add(&prof_gpu_ns, (uint64_t)((done.GPUEndTime - done.GPUStartTime) * 1e9));
          if (done.error)
              mgl_log("GPU error in command buffer %llu: %s", serial, done.error.localizedDescription.UTF8String);
        }];
    }
    return cb;
}

static void end_encoders(void)
{
    if (renc) { [renc endEncoding]; renc = nil; }
    if (benc) { [benc endEncoding]; benc = nil; }
    if (cenc) { [cenc endEncoding]; cenc = nil; }
}

static void commit(void)
{
    end_encoders();
    pt_cur = NULL;
    if (cb) {
        [cb commit];
        last_cb = cb;
        cb = nil;
    }
}

static id<MTLBlitCommandEncoder> blit_encoder(void)
{
    if (benc)
        return benc;
    end_encoders();
    id<MTLCommandBuffer> c = current_cb();
    int k = pt_pass("blits");
    if (k >= 0) {
        MTLBlitPassDescriptor *d = [MTLBlitPassDescriptor blitPassDescriptor];
        d.sampleBufferAttachments[0].sampleBuffer = pt_cur->sb;
        d.sampleBufferAttachments[0].startOfEncoderSampleIndex = (NSUInteger)k * 2;
        d.sampleBufferAttachments[0].endOfEncoderSampleIndex = (NSUInteger)k * 2 + 1;
        benc = [c blitCommandEncoderWithDescriptor:d];
    } else {
        benc = [c blitCommandEncoder];
    }
    prof.blits++;
    return benc;
}

static id<MTLComputeCommandEncoder> compute_encoder(void)
{
    if (cenc)
        return cenc;
    end_encoders();
    id<MTLCommandBuffer> c = current_cb();
    int k = pt_pass("pass compute");
    if (k >= 0) {
        MTLComputePassDescriptor *d = [MTLComputePassDescriptor computePassDescriptor];
        d.sampleBufferAttachments[0].sampleBuffer = pt_cur->sb;
        d.sampleBufferAttachments[0].startOfEncoderSampleIndex = (NSUInteger)k * 2;
        d.sampleBufferAttachments[0].endOfEncoderSampleIndex = (NSUInteger)k * 2 + 1;
        cenc = [c computeCommandEncoderWithDescriptor:d];
    } else {
        cenc = [c computeCommandEncoder];
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
    return b;
}

void *mglb_buffer_ptr(mglb_buffer *b) { return b ? b->ptr : NULL; }

void mglb_buffer_release(mglb_buffer *b)
{
    if (!b)
        return;
    int c = size_class(b->cap);
    if (pool_count[c] < (b->cap > ((size_t)16 << 20) ? 2 : 64)) { /* don't hoard big buffers */
        b->next_free = pool[c];
        pool[c] = b;
        pool_count[c]++;
        return;
    }
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

/* ================================================================ textures */

struct mglb_texture {
    void *mtl;
    mglb_texture_desc d;
    MTLPixelFormat pf;
};

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
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
    if (!is_depth_format(pf) && pf != MTLPixelFormatRGBA8Unorm_sRGB)
        td.usage |= MTLTextureUsageShaderWrite;
    if (pf == MTLPixelFormatR32Uint || pf == MTLPixelFormatR32Sint)
        td.usage |= MTLTextureUsageShaderAtomic; /* imageAtomic* on r32ui/r32i images (MSL 3.1 texture atomics) */
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    if (!t) {
        mgl_log("texture creation failed (%dx%dx%d format %d)", d->width, d->height, d->depth, d->format);
        return NULL;
    }
    struct mglb_texture *mt = calloc(1, sizeof *mt);
    mt->mtl = retain_obj(t);
    mt->d = *d;
    mt->pf = pf;
    return mt;
}

void mglb_texture_release(mglb_texture *t)
{
    if (!t)
        return;
    if (renc) {
        /* the open render pass may still reference it; Metal retains it for the command buffer */
    }
    release_obj(t->mtl);
    free(t);
}

void mglb_texture_upload(mglb_texture *t, int level, int x, int y, int z, int w, int h, int d, const void *data,
                         size_t bytes_per_row, size_t bytes_per_image)
{
    if (!t || t->pf == MTLPixelFormatDepth32Float_Stencil8)
        return;
    size_t bpt = (size_t)bytes_per_texel(t->pf), row = bpt * (size_t)w, img = row * (size_t)h;
    mglb_buffer *stage = mglb_buffer_new(img * (size_t)d);
    if (!stage)
        return;
    for (int zz = 0; zz < d; zz++)
        for (int yy = 0; yy < h; yy++)
            memcpy((char *)stage->ptr + (size_t)zz * img + (size_t)yy * row,
                   (const char *)data + (size_t)zz * bytes_per_image + (size_t)yy * bytes_per_row, row);
    id<MTLBlitCommandEncoder> e = blit_encoder();
    id<MTLTexture> tex = OBJ(id<MTLTexture>, t->mtl);
    if (t->d.type == MGLT_3D) {
        [e copyFromBuffer:OBJ(id<MTLBuffer>, stage->mtl) sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:img
                 sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, (NSUInteger)d) toTexture:tex destinationSlice:0
           destinationLevel:(NSUInteger)level destinationOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, (NSUInteger)z)];
    } else {
        for (int s = 0; s < d; s++)
            [e copyFromBuffer:OBJ(id<MTLBuffer>, stage->mtl) sourceOffset:(NSUInteger)s * img sourceBytesPerRow:row
                sourceBytesPerImage:img sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1) toTexture:tex
                   destinationSlice:(NSUInteger)(z + s) destinationLevel:(NSUInteger)level
                  destinationOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, 0)];
    }
    use_buffer(stage);
    mglb_buffer_release(stage);
}

void mglb_texture_generate_mipmaps(mglb_texture *t)
{
    if (!t || t->d.levels < 2 || is_int_format(t->pf) || is_depth_format(t->pf))
        return;
    [blit_encoder() generateMipmapsForTexture:OBJ(id<MTLTexture>, t->mtl)];
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
    mglb_buffer *stage = mglb_buffer_new(img * (size_t)d);
    if (!stage)
        return;
    if (!texel)
        memset(stage->ptr, 0, img * (size_t)d);
    else
        for (size_t o = 0; o < img * (size_t)d; o += bpt)
            memcpy((char *)stage->ptr + o, texel, bpt);
    id<MTLBlitCommandEncoder> e = blit_encoder();
    id<MTLTexture> tex = OBJ(id<MTLTexture>, t->mtl);
    if (t->d.type == MGLT_3D)
        [e copyFromBuffer:OBJ(id<MTLBuffer>, stage->mtl) sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:img
                 sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, (NSUInteger)d) toTexture:tex destinationSlice:0
           destinationLevel:(NSUInteger)level destinationOrigin:MTLOriginMake(0, 0, 0)];
    else
        for (int s = 0; s < d; s++)
            [e copyFromBuffer:OBJ(id<MTLBuffer>, stage->mtl) sourceOffset:(NSUInteger)s * img sourceBytesPerRow:row
                sourceBytesPerImage:img sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1) toTexture:tex
                   destinationSlice:(NSUInteger)s destinationLevel:(NSUInteger)level destinationOrigin:MTLOriginMake(0, 0, 0)];
    use_buffer(stage);
    mglb_buffer_release(stage);
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
        stex = [stex newTextureViewWithPixelFormat:dst->pf];
    }
    id<MTLBlitCommandEncoder> e = blit_encoder();
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
        /* sin/cos/pow etc. stay precise except in fast mode: packs hash with fract(sin(x) * 43758.5) on large x,
           and the fast sin there gave SEUS PTGI streaky noise across the sky and a stripe down the screen */
        o.mathFloatingPointFunctions = math == 2 ? MTLMathFloatingPointFunctionsFast : MTLMathFloatingPointFunctionsPrecise;
    } else
        o.fastMathEnabled = math > 0;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:o error:&e];
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
                if (err && !*err)
                    *err = strdup(e.localizedDescription.UTF8String);
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
static id<MTLRenderCommandEncoder> begin_pass(const mgl_target *t, unsigned clear_colors, const float *rgba,
                                              int clear_depth, float depth)
{
    end_encoders();
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
        }
    }
    if (t->depth) {
        set_attachment(rp.depthAttachment, t->depth, t->depth_level, 0);
        if (clear_depth) {
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.clearDepth = depth;
        }
        if (t->depth->pf == MTLPixelFormatDepth32Float_Stencil8) {
            set_attachment(rp.stencilAttachment, t->depth, t->depth_level, 0);
            if (clear_depth)
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
    prof.passes++;
    if (same_target(t, &prof_last_target) && !clear_colors && !clear_depth)
        prof.reopened++;
    prof_last_target = *t;
    renc_target = *t;
    return renc;
}

static id<MTLRenderCommandEncoder> pass_for(const mgl_target *t)
{
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
    const mgl_target *t = &d->target;
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
    "struct RtInfo { uint vbase, stride, ioff, itype, count; int base_vertex; int ent_off; uint translucent; };\n"
    /* per triangle, 12 words, for mcm_trace (core/mgl_program.c reads the same layout):
         0-2 packed texture coordinates (Sodium's 15-bit u/v)   3 alpha cutoff index (0 = solid) | 0x100 translucent
         4-6 vertex colours RGBA8   7 face normal (octahedral snorm16x2)   8-10 light (block, sky bytes)
         11 Iris block id + 1 (0 = unknown)
       Iris's extended vertex format keeps no material bits, so its triangles all get the 0.1 alpha test (solid
       textures are opaque, so this only costs time). */
    "kernel void rt_decode(device const uchar *vb [[buffer(0)]], device const uchar *ib [[buffer(1)]],\n"
    "    device packed_float3 *out [[buffer(2)]], constant RtInfo &n [[buffer(3)]], device uint *tri [[buffer(4)]],\n"
    "    uint t [[thread_position_in_grid]]) {\n"
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
    "  for (uint k = 0; k < 12; k++) tri[t * 12 + k] = r[k]; }\n";

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

void mglb_clear(const mgl_target *t, unsigned mask_color, const float rgba[4], int clear_depth, float depth,
                const int *scissor, uint8_t cmask)
{
    if (dump_this_frame())
        mgl_log("frame dump: clear target %p%s depth %p, colour mask 0x%x (write 0x%x), depth %d (%g), scissor %d", (void *)t->tex[0],
                t->is_default ? " (window)" : "", (void *)t->depth, mask_color, cmask, clear_depth, depth, scissor != NULL);
    int partial = (scissor && (scissor[0] > 0 || scissor[1] > 0 || scissor[0] + scissor[2] < t->width ||
                               scissor[1] + scissor[3] < t->height)) ||
                  (mask_color && cmask != 0xf);
    if (!partial) {
        begin_pass(t, mask_color, rgba, clear_depth, depth);
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
        if (bt->is_image && bt->tex && bt->image_level > 0)
            tex = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:tex.textureType
                                              levels:NSMakeRange((NSUInteger)bt->image_level, 1)
                                              slices:NSMakeRange(0, tex.textureType == MTLTextureType3D ? 1 : tex.arrayLength)];
        /* fetch-only textures past slot 15 use a constexpr sampler in the shader (see mgl_xlate.c) */
        if (bt->tex && (bt->swizzle[0] | bt->swizzle[1] | bt->swizzle[2] | bt->swizzle[3]))
            tex = swizzled_view(tex, bt->swizzle);
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
        mgl_log("frame dump: draw %lu: %s, target %p%s %dx%d depth %p, depth test %d write %d func 0x%x, cull %d, blend %d "
                "mask 0x%x, prim 0x%x, count %d multi %d", frame_draws, d->program->label, (void *)d->target.tex[0],
                d->target.is_default ? " (window)" : "", d->target.width, d->target.height, (void *)d->target.depth,
                d->depth_test, d->depth_write, d->depth_func, d->cull, d->blend[0].enabled, d->blend[0].color_mask,
                d->primitive, d->count, d->multi_n);
    if (probe || log_program(d))
        log_probe_draw(d);
    frame_sections += d->multi_n > 0 ? d->multi_n : 0;
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

/* Geometry-shader emulation (mgl_gs.c). The compute stage gets: 21 attribute descriptors, 22..25 raw vertex
   buffers, 26 index buffer, 27 emitted vertex records, 28 per-primitive vertex counts. The passthrough vertex
   stage reads 27/28 and turns each strip into a triangle list. */
void mglb_draw_gs(const mgl_draw *d, int triangles, int max_vertices, int record_vec4s)
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
    size_t out_bytes = (size_t)triangles * (size_t)max_vertices * (size_t)record_vec4s * 16;
    mglb_buffer *ov = mglb_buffer_new(out_bytes), *oc = mglb_buffer_new((size_t)triangles * 4);
    if (!ov || !oc) {
        mglb_buffer_release(ov);
        mglb_buffer_release(oc);
        return;
    }
    id<MTLBuffer> ovb = OBJ(id<MTLBuffer>, ov->mtl), ocb = OBJ(id<MTLBuffer>, oc->mtl);

    /* 1. vertex + geometry stages as one compute job, one thread per input triangle */
    id<MTLComputeCommandEncoder> c = compute_encoder();
    [c setComputePipelineState:OBJ(id<MTLComputePipelineState>, d->program->compute)];
    bind_stage_resources(nil, c, d, 2);
    if (d->uses_scene)
        bind_scene(nil, c);
    [c setBytes:desc length:sizeof desc atIndex:MGL_BUF_INTERNAL_BASE];
    for (int i = 0; i < 4; i++) {
        mglb_buffer *b = i < d->num_vbufs ? d->vbufs[i].buf : (d->num_vbufs ? d->vbufs[0].buf : ov);
        [c setBuffer:OBJ(id<MTLBuffer>, b->mtl) offset:0 atIndex:(NSUInteger)(MGL_BUF_INTERNAL_BASE + 1 + i)];
        use_buffer(b);
    }
    mglb_buffer *ib = d->index_buf ? d->index_buf : ov;
    [c setBuffer:OBJ(id<MTLBuffer>, ib->mtl) offset:0 atIndex:MGL_BUF_INTERNAL_BASE + 5];
    use_buffer(ib);
    [c setBuffer:ovb offset:0 atIndex:MGL_BUF_INTERNAL_BASE + 6];
    [c setBuffer:ocb offset:0 atIndex:MGL_BUF_INTERNAL_BASE + 7];
    NSUInteger lx = (NSUInteger)(d->local_size[0] > 0 ? d->local_size[0] : 64);
    [c dispatchThreadgroups:MTLSizeMake(((NSUInteger)triangles + lx - 1) / lx, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(lx, 1, 1)];

    /* 2. draw the emitted strips: no vertex fetch, records come from buffers 27/28 */
    mgl_draw p = *d;
    memset(p.attrs, 0, sizeof p.attrs);
    p.num_vbufs = 0;
    id<MTLRenderPipelineState> ps = get_pipeline(&p, &p.target);
    if (ps) {
        id<MTLRenderCommandEncoder> e = pass_for(&p.target);
        [e setRenderPipelineState:ps];
        [e setDepthStencilState:get_depth_state(p.depth_test && p.target.depth,
                                                p.depth_test && p.depth_write && p.target.depth, p.depth_func)];
        [e setViewport:(MTLViewport){p.viewport[0], p.viewport[1], p.viewport[2], p.viewport[3], 0, 1}];
        MTLScissorRect sr = {0, 0, (NSUInteger)p.target.width, (NSUInteger)p.target.height};
        int visible = 1;
        if (p.scissor_enabled) {
            int x0 = p.scissor[0] < 0 ? 0 : p.scissor[0], y0 = p.scissor[1] < 0 ? 0 : p.scissor[1];
            int x1 = p.scissor[0] + p.scissor[2], y1 = p.scissor[1] + p.scissor[3];
            if (x1 > p.target.width) x1 = p.target.width;
            if (y1 > p.target.height) y1 = p.target.height;
            if (x1 <= x0 || y1 <= y0)
                visible = 0;
            else
                sr = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
        }
        if (visible) {
            [e setScissorRect:sr];
            [e setCullMode:!p.cull ? MTLCullModeNone : p.cull_face == GL_FRONT ? MTLCullModeFront : MTLCullModeBack];
            [e setFrontFacingWinding:p.front_face == GL_CW ? MTLWindingCounterClockwise : MTLWindingClockwise];
            if (p.polygon_offset_enabled)
                [e setDepthBias:p.polygon_offset_units slopeScale:p.polygon_offset_factor clamp:0];
            else
                [e setDepthBias:0 slopeScale:0 clamp:0];
            bind_stage_resources(e, nil, &p, 0);
            bind_stage_resources(e, nil, &p, 1);
            if (p.uses_scene)
                bind_scene(e, nil);
            [e setVertexBuffer:ovb offset:0 atIndex:MGL_BUF_INTERNAL_BASE + 6];
            [e setVertexBuffer:ocb offset:0 atIndex:MGL_BUF_INTERNAL_BASE + 7];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                  vertexCount:(NSUInteger)triangles * (NSUInteger)(max_vertices - 2) * 3];
        }
    }
    use_buffer(ov);
    use_buffer(oc);
    mglb_buffer_release(ov);
    mglb_buffer_release(oc);    debug_sync("geometry-shader draw", d, triangles, max_vertices);
}

/* ================================================================ ray tracing (step 2) */

/* One primitive acceleration structure per terrain section, cached by (buffer, range, generation). */
@interface RtSection : NSObject
@property(nonatomic, strong) id<MTLAccelerationStructure> as;
@property(nonatomic) uint64_t last_frame;
@property(nonatomic) mglb_buffer *tris; /* per-triangle texture coordinates + alpha cutoff (rt_decode) */
@end
@implementation RtSection
- (void)dealloc
{
    mglb_buffer_release(_tris);
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
    uint32_t translucent, pad;
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

static id<MTLAccelerationStructure> section_as(const mgl_rt_geom *g, mglb_buffer **tris_out)
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
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    RtSection *s = rt_sections[key];
    if (s) {
        s.last_frame = rt_frame;
        *tris_out = s.tris;
        return s.as;
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
    struct { uint32_t vbase, stride, ioff, itype, count; int32_t base_vertex, ent_off; uint32_t translucent; } info = {
        (uint32_t)g->vbase, (uint32_t)g->stride, (uint32_t)g->ioff, g->itype == GL_UNSIGNED_SHORT ? 2u : 4u,
        (uint32_t)(tris * 3), g->base_vertex, g->ent_off, g->translucent ? 1u : 0u};
    id<MTLComputeCommandEncoder> c = compute_encoder();
    [c setComputePipelineState:ps];
    [c setBuffer:OBJ(id<MTLBuffer>, g->vbuf->mtl) offset:0 atIndex:0];
    [c setBuffer:OBJ(id<MTLBuffer>, g->ibuf->mtl) offset:0 atIndex:1];
    [c setBuffer:OBJ(id<MTLBuffer>, pos->mtl) offset:0 atIndex:2];
    [c setBytes:&info length:sizeof info atIndex:3];
    [c setBuffer:OBJ(id<MTLBuffer>, tri->mtl) offset:0 atIndex:4];
    use_buffer(tri);
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
        return nil;
    }
    if (!rt_sections)
        rt_sections = [NSMutableDictionary dictionary];
    s = [RtSection new];
    s.as = as;
    s.tris = tri;
    s.last_frame = rt_frame;
    rt_sections[key] = s;
    *tris_out = tri;
    return as;
}

void mglb_rt_update(const mgl_rt_geom *g, int n)
{
    if (!dev.supportsRaytracing)
        return;
    rt_frame++;
    NSMutableArray<id<MTLAccelerationStructure>> *parts = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    mglb_buffer *inst = mglb_buffer_new(sizeof(MTLAccelerationStructureUserIDInstanceDescriptor) * (size_t)(n ? n : 1));
    if (!inst)
        return;
    MTLAccelerationStructureUserIDInstanceDescriptor *descs = inst->ptr;
    mglb_buffer *table = mglb_buffer_new(8 * (size_t)(n ? n : 1));
    uint64_t *addr = table->ptr;
    free(rt_tris_c);
    rt_tris_c = (__unsafe_unretained id<MTLResource> *)calloc((size_t)(n ? n : 1), sizeof(id));
    int count = 0;
    for (int i = 0; i < n; i++) {
        mglb_buffer *tris = NULL;
        id<MTLAccelerationStructure> as = section_as(&g[i], &tris);
        if (!as)
            continue;
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
        mgl_log("ray tracing: scene built from %d of %d terrain sections (%lu cached)", count, n,
                (unsigned long)rt_sections.count);
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
    prof.finishes++;
}

/* ================================================================ window: GLFW glue and present */

typedef struct mgl_ctx {
    CAMetalLayer *layer;
    int w, h;
    uint64_t frames;
    int vsync;
    uint64_t last_swap_ns;
    double avg_frame_ms;    /* smoothed CPU frame time, for choosing the paced rate */
    int paced_fps;
} mgl_ctx;

/* Even frame delivery: on a 120 Hz ProMotion screen a game that makes 80 fps would show frames for 8 and
   17 ms in turn (judder). Presenting with a minimum duration at the highest of 120/60/40/30 that the recent
   frame time sustains keeps every frame on screen equally long. With vsync off, pacing stays off. */
static int choose_paced_fps(mgl_ctx *c)
{
    static const int rates[] = {120, 60, 40, 30};
    const char *forced = getenv("MGL_TARGET_FPS");
    if (forced && atoi(forced) > 0)
        return atoi(forced);
    double ms = c->avg_frame_ms * 1.1; /* 10% headroom so a single slow frame doesn't break the rhythm */
    for (int i = 0; i < 4; i++)
        if (ms <= 1000.0 / rates[i])
            return rates[i];
    return 30;
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

static void update_size(mgl_ctx *c)
{
    CGSize px = c->layer.bounds.size;
    px.width *= c->layer.contentsScale;
    px.height *= c->layer.contentsScale;
    if (px.width < 1 || px.height < 1)
        return;
    if (!CGSizeEqualToSize(c->layer.drawableSize, px))
        c->layer.drawableSize = px;
    c->w = (int)px.width;
    c->h = (int)px.height;
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
    if (pt_ok > 0)
        pt_report(f);
    memset(&prof, 0, sizeof prof);
    prof.start_ns = t;
    atomic_store(&prof_gpu_ns, 0);
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
    static atomic_int presents_waiting;
    int skip = !c->vsync && !every_frame && atomic_load(&presents_waiting) >= 2;
    uint64_t t_draw = now_ns();
    id<CAMetalDrawable> drawable = skip ? nil : [c->layer nextDrawable];
    prof.wait_ns += now_ns() - t_draw;
    prof.skipped_presents += skip;
    if (drawable) {
        [current_cb() addCompletedHandler:^(id<MTLCommandBuffer> done) {
          (void)done;
          atomic_fetch_add(&presents_waiting, 1);
        }];
        [drawable addPresentedHandler:^(id<MTLDrawable> d) {
          (void)d;
          atomic_fetch_sub(&presents_waiting, 1);
        }];
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
            [e setFragmentTexture:OBJ(id<MTLTexture>, mgl->window_color->mtl) atIndex:0];
            [e setFragmentSamplerState:blit_sampler(1) atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [e endEncoding];
        uint64_t t = now_ns();
        if (c->last_swap_ns) {
            double ms = (double)(t - c->last_swap_ns) * 1e-6;
            if (ms < 250)
                c->avg_frame_ms = c->avg_frame_ms ? c->avg_frame_ms * 0.9 + ms * 0.1 : ms;
        }
        c->last_swap_ns = t;
        if (opt_pacing > 0 && c->vsync && c->avg_frame_ms > 0) {
            int fps = choose_paced_fps(c);
            if (fps != c->paced_fps) {
                c->paced_fps = fps;
                mgl_log("frame pacing: presenting at an even %d fps (frame time %.1f ms)", fps, c->avg_frame_ms);
            }
            [current_cb() presentDrawable:drawable afterMinimumDuration:1.0 / fps];
        } else {
            [current_cb() presentDrawable:drawable];
        }
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
    frame_draws = frame_sections = frame_dispatches = frame_probes = 0;
    /* keep at most ~2 frames in flight */
    if (cb_serial > 3)
        mglb_fence_wait(submitted_serial - 2, 100000000ull);
}
