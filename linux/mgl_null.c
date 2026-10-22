/* Bookkeeping-only backend for Linux: lets the GL front end run Minecraft in the cloud (nothing is drawn).
   Counts work so tests can see what would have reached the GPU. */
#include <stdlib.h>
#include <string.h>
#include "mgl_backend.h"
#include "mgl_state.h" /* mgl_rt_end_frame */
#include "mgl_log.h"

struct mglb_buffer { void *mem; size_t size; };
struct mglb_texture { mglb_texture_desc d; };
struct mglb_program { int dummy; };

static unsigned long draws, clears, blits, dispatches, uploads;
static uint64_t fence_counter;

mglb_buffer *mglb_buffer_new(size_t size)
{
    mglb_buffer *b = malloc(sizeof *b);
    b->mem = calloc(1, size);
    b->size = size;
    return b;
}
void *mglb_buffer_ptr(mglb_buffer *b) { return b->mem; }
size_t mglb_buffer_size(mglb_buffer *b) { return b ? b->size : 0; }
void mglb_buffer_release(mglb_buffer *b) { if (b) { free(b->mem); free(b); } }
int mglb_buffer_in_use(mglb_buffer *b) { return 0; }
void mglb_buffer_written(mglb_buffer *b) {}
void mglb_buffer_volatile(mglb_buffer *b) {}

mglb_texture *mglb_texture_new(const mglb_texture_desc *d)
{
    mglb_texture *t = malloc(sizeof *t);
    t->d = *d;
    return t;
}
void mglb_texture_release(mglb_texture *t) { free(t); }
enum mgl_format mglb_texture_format(mglb_texture *t) { return t ? t->d.format : MGLF_COUNT; }
void mglb_texture_read(mglb_texture *t, int level, int x, int y, int w, int h, void *out)
{
    memset(out, 0x80, (size_t)w * (size_t)h * 4); /* grey: nothing is rendered here */
}
void mglb_texture_upload(mglb_texture *t, int level, int x, int y, int z, int w, int h, int d, const void *data,
                         size_t bpr, size_t bpi) { uploads++; }
void mglb_texture_generate_mipmaps(mglb_texture *t) {}
void mglb_texture_need_image(mglb_texture *t) {}
void mglb_texture_need_view(mglb_texture *t) {}
int mglb_buffer_copy(mglb_buffer *src, size_t so, mglb_buffer *dst, size_t dof, size_t n) { return 0; }
int mglb_buffer_gpu_writing(mglb_buffer *b) { return 0; }
void mglb_buffer_wait_writes(mglb_buffer *b) {}
void mglb_texture_clear(mglb_texture *t, int level, const void *texel) {}
void mglb_texture_copy(mglb_texture *s, int sl, int sx, int sy, int sz, mglb_texture *d, int dl, int dx, int dy,
                       int dz, int w, int h, int dd) {}

mglb_program *mglb_program_new(const char *v, const char *f, const char *c, char **err)
{
    return calloc(1, sizeof(mglb_program));
}
void mglb_program_release(mglb_program *p) { free(p); }
void mglb_program_label(mglb_program *p, const char *label) {}

/* GLX swaps the window, so there is no swap hook here: the first draw, clear or blit into the window after
   offscreen drawing ends the frame (for ray-tracing capture, MGL_RT_SNAPSHOT) */
static void frame_mark(int is_default)
{
    static int offscreen;
    if (!is_default)
        offscreen = 1;
    else if (offscreen) {
        offscreen = 0;
        mgl_rt_end_frame();
    }
}
void mglb_draw(const mgl_draw *d)
{
    draws += d->multi_n > 0 ? (unsigned long)d->multi_n : 1;
    frame_mark(d->target.is_default);
}
void mglb_dispatch(const mgl_draw *d, int gx, int gy, int gz) { dispatches++; }
static int gs_draws;
void mglb_draw_gs(const mgl_draw *d, int t, int mv, int r) { if (!gs_draws++) mgl_log("first geometry-shader draw: %d triangles, max_vertices %d, %d vec4s per record", t, mv, r); draws++; }
void mglb_clear(const mgl_target *t, unsigned mask, const float rgba[4], int cd, float depth, const int *sc,
                uint8_t cm) { clears++; frame_mark(t->is_default); }
void mglb_blit(const mgl_target *s, int sa, const int sr[4], const mgl_target *d, const int dr[4], int c, int dp,
               int lin) { blits++; frame_mark(d->is_default); }
void mglb_memory_barrier(void) {}
void mglb_rt_update(const mgl_rt_geom *g, int n) {}
void mglb_rt_dynamic(const float *tris, int n) {}
mglb_buffer *mglb_rt_instances(void) { return NULL; }
mglb_buffer *mglb_rt_lights(void) { return NULL; }

/* GPU chunk culling: the same box test on the CPU, so the cloud rig checks the planes and the bookkeeping */
static unsigned long cull_kept, cull_total, cull_runs;
int mglb_cull_supported(void) { return 1; }
int mglb_cull_run(const mgl_cull_pass *p, const mgl_cull_draw *dr, int n, mglb_buffer *const *ib, int nr)
{
    for (int i = 0; i < n; i++) {
        int in = 1;
        for (int k = 0; k < 6 && in; k++) {
            const float *q = p->planes[k]; /* the box corner furthest along the plane normal */
            float x = dr[i].min[0] + (q[0] > 0 ? 16 : 0), y = dr[i].min[1] + (q[1] > 0 ? 16 : 0),
                  z = dr[i].min[2] + (q[2] > 0 ? 16 : 0);
            in = q[0] * x + q[1] * y + q[2] * z + q[3] >= 0;
        }
        cull_kept += (unsigned long)in;
    }
    cull_total += (unsigned long)n;
    if (++cull_runs % 2000 == 0) {
        mgl_log("null cull: last 2000 passes kept %lu of %lu section draws", cull_kept, cull_total);
        cull_kept = cull_total = 0;
    }
    return 0;
}

void mglb_window_size(int *w, int *h) { *w = 1280; *h = 720; }
int mglb_upscaled_read(unsigned char **px, int *w, int *h) { (void)px; (void)w; (void)h; return 0; }
uint64_t mglb_fence(void) { return ++fence_counter; }
int mglb_fence_wait(uint64_t id, uint64_t timeout) { return 1; }
void mglb_flush(void) {}
void mglb_finish(void) {}

__attribute__((destructor)) static void report(void)
{
    mgl_log("null backend totals: %lu draws, %lu clears, %lu blits, %lu dispatches, %lu texture uploads",
            draws, clears, blits, dispatches, uploads);
}

const char *mgl_renderer_name(void) { return "mcmetal null backend (cloud test)"; }
