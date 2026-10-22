/* What the GL front end needs from the GPU backend. Implemented by mac/mgl_metal.m (Metal) and
   linux/mgl_null.c (bookkeeping only, so the front end can run Minecraft in the cloud). */
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct mglb_buffer mglb_buffer;
typedef struct mglb_texture mglb_texture;
typedef struct mglb_program mglb_program;

/* ---- buffers: always CPU-visible (unified memory on Apple GPUs) ---- */
mglb_buffer *mglb_buffer_new(size_t size);
void *mglb_buffer_ptr(mglb_buffer *b);
size_t mglb_buffer_size(mglb_buffer *b);
void mglb_buffer_release(mglb_buffer *b);
/* true while work that reads the buffer has been recorded but not finished by the GPU */
int mglb_buffer_in_use(mglb_buffer *b);
/* the CPU wrote into the buffer (every glBufferData / SubData / map / copy goes through here): caches keyed on its
   contents start over */
void mglb_buffer_written(mglb_buffer *b);
/* mapped persistently: the CPU can write it at any time without telling us, so nothing may cache its contents */
void mglb_buffer_volatile(mglb_buffer *b);

/* ---- textures ---- */
enum mgl_format {
    MGLF_NONE,
    MGLF_RGBA8, MGLF_RGBA8_SNORM, MGLF_R8, MGLF_RG8, MGLF_RGBA16F, MGLF_R16F, MGLF_RG16F, MGLF_R32F, MGLF_RG32F,
    MGLF_RGBA32F, MGLF_R11G11B10F, MGLF_RGB10A2, MGLF_R16UI, MGLF_R32UI, MGLF_RGBA16, MGLF_R16, MGLF_RG16,
    MGLF_RGBA8UI, MGLF_R8UI, MGLF_RGBA16UI, MGLF_RGBA32UI, MGLF_R32I, MGLF_SRGB8_A8,
    MGLF_DEPTH32F, MGLF_DEPTH16, MGLF_DEPTH24_STENCIL8, MGLF_DEPTH32F_STENCIL8,
    MGLF_RGBA16I, MGLF_RGBA32I, MGLF_RG32UI,
    MGLF_COUNT
};
enum mgl_tex_type { MGLT_2D, MGLT_3D, MGLT_2D_ARRAY, MGLT_CUBE };

typedef struct mglb_texture_desc {
    enum mgl_tex_type type;
    enum mgl_format format;
    int width, height, depth;   /* depth = layers for arrays, 6 for cube */
    int levels;
} mglb_texture_desc;

mglb_texture *mglb_texture_new(const mglb_texture_desc *d);
void mglb_texture_release(mglb_texture *t);
/* data is tightly described by bytes_per_row / bytes_per_image, already in the texture's format */
void mglb_texture_upload(mglb_texture *t, int level, int x, int y, int z, int w, int h, int d,
                         const void *data, size_t bytes_per_row, size_t bytes_per_image);
void mglb_texture_generate_mipmaps(mglb_texture *t);
/* textures start with only render-target and sample usage (so Apple GPUs can compress them); these add image
   writes or format/swizzle views the first time a texture needs them (it is remade, contents kept) */
void mglb_texture_need_image(mglb_texture *t);
void mglb_texture_need_view(mglb_texture *t);
/* GPU buffer copy in command order (0: not possible, e.g. offsets not 4-byte aligned; copy on the CPU instead).
   Until it has run, the CPU must not read or write dst: mglb_buffer_wait_writes waits for it. */
int mglb_buffer_copy(mglb_buffer *src, size_t src_off, mglb_buffer *dst, size_t dst_off, size_t size);
int mglb_buffer_gpu_writing(mglb_buffer *b);
void mglb_buffer_wait_writes(mglb_buffer *b);

/* MGL_PROFILE: CPU-side buffer traffic in core/mgl_buffer.c, logged and reset by the backend once a second */
typedef struct {
    uint64_t renames, rename_copy_bytes, rename_ns; /* fresh memory for a buffer the GPU still reads (and bytes copied over) */
    uint64_t copies, copy_bytes, copy_ns;           /* glCopyBufferSubData on the CPU (memmove only) */
    uint64_t gpu_copies, gpu_copy_bytes, gpu_waits; /* ... as GPU copies; CPU accesses that had to wait for one */
    uint64_t datas, data_bytes;                     /* glBufferData */
} mgl_buf_stats;
extern mgl_buf_stats mgl_bstats;
/* reads w x h texels at (x, y) of a colour texture into out, tightly packed, GL row order; waits for the GPU */
void mglb_texture_read(mglb_texture *t, int level, int x, int y, int w, int h, void *out);
enum mgl_format mglb_texture_format(mglb_texture *t);
void mglb_texture_clear(mglb_texture *t, int level, const void *texel /* one texel in format, NULL = zero */);
void mglb_texture_copy(mglb_texture *src, int src_level, int sx, int sy, int sz,
                       mglb_texture *dst, int dst_level, int dx, int dy, int dz, int w, int h, int d);

/* ---- programs ---- */
/* msl: per stage MSL source (NULL if absent), entry point "main0". Returns NULL and fills *err on failure. */
mglb_program *mglb_program_new(const char *msl_vertex, const char *msl_fragment, const char *msl_compute, char **err);
void mglb_program_release(mglb_program *p);
void mglb_program_label(mglb_program *p, const char *label); /* shown in GPU error reports */

/* ---- render state for one draw ---- */
#define MGL_MAX_ATTACHMENTS 8
#define MGL_MAX_VERTEX_ATTRIBS 16
#define MGL_MAX_VERTEX_BUFFERS 9 /* MSL buffers 21..29; 30 is the ray-tracing scene */
#define MGL_MAX_TEXTURES 31

enum mgl_vtype { MGLV_FLOAT, MGLV_HALF, MGLV_UBYTE, MGLV_BYTE, MGLV_USHORT, MGLV_SHORT, MGLV_UINT, MGLV_INT };

typedef struct mgl_vertex_attr {
    int enabled;
    int location;          /* MSL [[attribute(n)]] */
    enum mgl_vtype type;
    int size;              /* 1..4 components */
    int normalized, integer;
    int buffer;            /* index into vbufs */
    size_t offset;
} mgl_vertex_attr;

typedef struct mgl_vertex_buf {
    mglb_buffer *buf;
    size_t offset;
    int stride;
    int divisor;           /* 0 = per vertex, else per instance (step rate) */
} mgl_vertex_buf;

typedef struct mgl_blend {
    int enabled;
    int src_rgb, dst_rgb, src_a, dst_a;   /* GL enums */
    int eq_rgb, eq_a;
    uint8_t color_mask;                   /* bit0 R .. bit3 A */
} mgl_blend;

typedef struct mgl_sampler_state {
    int min_filter, mag_filter, wrap_s, wrap_t, wrap_r;  /* GL enums */
    int compare_mode, compare_func;
    float min_lod, max_lod, lod_bias;
    int max_anisotropy;
} mgl_sampler_state;

typedef struct mgl_bound_texture {
    mglb_texture *tex;     /* NULL: nothing bound */
    mgl_sampler_state sampler;
    int image_level;       /* for image units */
    int dim, sample_kind, is_image, is_shadow; /* from the shader, so an empty slot gets a matching dummy */
    int swizzle[4];        /* GL_RED..GL_ALPHA, GL_ZERO, GL_ONE per channel; all 0 = identity (not set) */
} mgl_bound_texture;

typedef struct mgl_target {
    mglb_texture *tex[MGL_MAX_ATTACHMENTS];
    int level[MGL_MAX_ATTACHMENTS], layer[MGL_MAX_ATTACHMENTS];
    mglb_texture *depth;
    int depth_level;
    int width, height;
    int is_default;        /* the window's framebuffer 0 */
} mgl_target;

typedef struct mgl_draw {
    mglb_program *program;
    mgl_target target;
    mgl_blend blend[MGL_MAX_ATTACHMENTS];
    int depth_test, depth_write, depth_func;
    int cull, cull_face, front_face;
    int viewport[4];
    int scissor_enabled, scissor[4];
    float polygon_offset_factor, polygon_offset_units;
    int polygon_offset_enabled;

    mgl_vertex_attr attrs[MGL_MAX_VERTEX_ATTRIBS];
    mgl_vertex_buf vbufs[MGL_MAX_VERTEX_BUFFERS];
    int num_vbufs;

    const void *uniforms[3]; int uniform_size[3];   /* default block per stage (vertex, fragment, compute) */
    const int (*uniform_used)[2]; int num_uniform_used; /* compute stage: byte ranges it reads, -1 = all */
    mglb_buffer *ubo[12]; size_t ubo_offset[12]; size_t ubo_size[12];
    mglb_buffer *ssbo[8]; size_t ssbo_offset[8];   /* by x.ssbos[] index */
    mgl_bound_texture textures[3][MGL_MAX_TEXTURES]; /* per stage, by MSL index */
    int num_textures[3];

    int primitive;         /* GL_TRIANGLES etc. (fans already converted) */
    mglb_buffer *index_buf; size_t index_offset; int index_type; /* 0 = non-indexed, else GL_UNSIGNED_SHORT/INT */
    int count, first, base_vertex, instances;
    int local_size[3];     /* compute threadgroup size */
    int uses_scene;        /* bind the ray-tracing scene (MGL_BUF_SCENE) */
    /* multi-draw (Sodium terrain): when multi_n > 0, draw multi_n indexed ranges with the same state instead of
       count/index_offset/base_vertex. Bind once, then one draw call each. */
    int multi_n;
    const int *multi_count;        /* GLsizei */
    const void *const *multi_offset;
    const int *multi_base;         /* GLint */
} mgl_draw;

/* ---- ray tracing (step 2, see STEP2-RAYTRACING.md and mgl_rt.c) ---- */
typedef struct mgl_rt_geom {
    mglb_buffer *vbuf, *ibuf;
    size_t vbase;          /* byte offset of vertex 0 (Sodium/Iris terrain layout) */
    int stride;
    size_t ioff;
    int itype;             /* GL_UNSIGNED_SHORT / GL_UNSIGNED_INT */
    int count, base_vertex;
    unsigned gen;          /* bumped when the vertex data may have changed */
    float region[3];       /* camera-relative region origin this frame */
    int translucent;       /* drawn with blending (Sodium's translucent pass: glass, water, ice) */
    int ent_off;           /* byte offset of Iris's block id (iris_Entity) from the position, or -1 */
} mgl_rt_geom;
/* The terrain sections live this frame; the backend keeps one acceleration structure per section (cached by
   buffer, range and gen) and rebuilds the scene from them. Bound at MGL_BUF_SCENE for programs with uses_scene. */
void mglb_rt_update(const mgl_rt_geom *g, int n);
/* This frame's entity triangles (mobs, players, item frames, chests...): camera-relative float3 corners, 9 floats
   per triangle, solid. Called just before mglb_rt_update; the backend adds them to that scene. */
void mglb_rt_dynamic(const float *tris, int n);
mglb_buffer *mglb_rt_instances(void); /* this frame's per-instance triangle-data addresses (mcm_trace's McmInstances) */
/* The block atlas the terrain was last drawn with, for mcm_trace's alpha test (mcm_atlas); set by mgl_rt.c. */
extern mglb_texture *mgl_rt_atlas;
/* Block ids the light list collects (MCMETAL_LIGHT_IDS in a pack), {-1, -1} = none; set by mgl_program.c. */
extern int mgl_rt_light_ids[2];
extern float mgl_rt_radius; /* MCMETAL_RT_RADIUS: the scene keeps only sections this close to the camera (0 = all) */
mglb_buffer *mglb_rt_lights(void); /* this frame's light list (mcm_lights_near's McmLights) */

/* Camera from Iris's uniforms, as the pack was last given them (column-major, GL conventions), for MetalFX frame
   interpolation's motion vectors (MCMETAL_FRAMEGEN): gbufferModelView, gbufferProjection,
   gbufferPreviousModelView, gbufferPreviousProjection; cameraPosition, previousCameraPosition. seen: bit per
   value set since the backend last cleared it. Filled by mgl_program.c. */
typedef struct mgl_camera {
    float mat[4][16];
    float pos[2][3];
    unsigned seen;
} mgl_camera;
extern mgl_camera mgl_cam;

/* MetalFX temporal upscaler (MCMETAL_UPSCALE=2): world geometry is drawn shifted by a sub-pixel amount that changes
   every frame, so MetalFX can gather detail finer than the render resolution. mgl_tu_jitter_on: vertex shaders get
   the shift (mgl_program.c); mglb_tu_jitter: the shift for a draw into t, in GL clip units (x, y), or 0, 0 when this
   draw isn't part of the world picture MetalFX gets. */
int mgl_tu_jitter_on(void);
void mglb_tu_jitter(const mgl_target *t, float out[2]);

void mglb_draw(const mgl_draw *d);
void mglb_dispatch(const mgl_draw *d, int gx, int gy, int gz); /* uses program, uniforms, ubo, textures[2] */
/* Geometry-shader program (see mgl_gs.c): run the compute stage over `triangles` input triangles, fetching
   vertices from d->vbufs/attrs/index_buf, then draw the emitted strips with the passthrough vertex stage. */
void mglb_draw_gs(const mgl_draw *d, int triangles, int max_vertices, int record_floats);
void mglb_clear(const mgl_target *t, unsigned mask_color /* bit per attachment */, const float rgba[4],
                int clear_depth, float depth, const int *scissor /* NULL = whole target */, uint8_t color_write_mask);
void mglb_blit(const mgl_target *src, int src_att, const int src_rect[4],
               const mgl_target *dst, const int dst_rect[4], int color, int depth, int linear);
void mglb_memory_barrier(void);

/* ---- frame and sync ---- */
void mglb_window_size(int *w, int *h);
int mglb_upscaled_read(unsigned char **px, int *w, int *h); /* MetalFX output (RGBA8, GL row order) or 0 */    /* current drawable size in pixels */
uint64_t mglb_fence(void);                /* id that completes when all work recorded so far is done */
int mglb_fence_wait(uint64_t id, uint64_t timeout_ns); /* 1 done, 0 timeout */
void mglb_flush(void);                    /* commit recorded work */
void mglb_finish(void);                   /* commit and wait */
