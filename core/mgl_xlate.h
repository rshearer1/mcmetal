/* GLSL program -> Metal Shading Language, with the reflection the GL front end needs.
   glslang (relaxed Vulkan rules, IO mapped across stages by name) -> SPIR-V -> SPIRV-Cross MSL.

   Conventions shared with the Metal backend:
   - Loose uniforms live in one block per stage ("gl_DefaultUniformBlock"), bound at [[buffer(MGL_BUF_DEFAULT_UNIFORMS)]].
   - Uniform blocks get [[buffer(MGL_BUF_UBO_BASE + binding)]].
   - Textures/samplers/images get consecutive [[texture(n)]] / [[sampler(n)]] per stage, listed in `textures`.
   - Vertex attributes are [[attribute(location)]]; vertex buffers use MGL_BUF_VERTEX_BASE and up.
   - Vertex output is flipped in Y and depth moved to 0..1 (SPIRV-Cross flip_vert_y + fixup_clipspace),
     so Metal row r == GL row r in every render target; the present pass flips once. */
#pragma once
#include <stddef.h>
#include <stdint.h>

#define MGL_BUF_DEFAULT_UNIFORMS 0
#define MGL_BUF_UBO_BASE 1      /* 1..12 */
#define MGL_BUF_SSBO_BASE 13    /* 13..20: shader storage blocks */
#define MGL_MAX_SSBOS 8
#define MGL_BUF_VERTEX_BASE 21  /* 21..29 */
#define MGL_BUF_SCENE 30        /* ray-tracing scene (accelerationStructureEXT), see STEP2-RAYTRACING.md */
#define MGL_MAX_STAGE_TEXTURES 31

enum mgl_stage { MGL_VERTEX, MGL_FRAGMENT, MGL_COMPUTE, MGL_NUM_STAGES };

enum mgl_uniform_kind { MGL_U_FLOAT, MGL_U_INT, MGL_U_UINT, MGL_U_BOOL };

typedef struct mgl_uniform {
    char name[96];          /* GL name, e.g. "ModelViewMat", "Light[0]" style arrays keep the base name */
    enum mgl_uniform_kind kind;
    int vecsize, columns;   /* float4x4 -> vecsize 4, columns 4 */
    int array_size;         /* 1 if not an array */
    int array_stride, matrix_stride;
    int offset[MGL_NUM_STAGES]; /* byte offset in that stage's default block, -1 if absent */
} mgl_uniform;

typedef struct mgl_texture_slot {
    char name[96];
    int is_image;           /* image load/store (no sampler) */
    int is_shadow;          /* sampler2DShadow etc. */
    int dim;                /* 1, 2, 3, or 6 for cube; +10 for arrays */
    int sample_kind;        /* 0 float, 1 int, 2 uint: what the shader reads */
    int msl_index[MGL_NUM_STAGES]; /* texture and sampler index in that stage, -1 if unused */
} mgl_texture_slot;

typedef struct mgl_ubo {
    char name[96];
    int binding;            /* default binding chosen by mapping; GL glUniformBlockBinding may override */
    int size;
} mgl_ubo;

typedef struct mgl_attrib {
    char name[96];
    int location;
    int vecsize;
    int is_int;             /* 1 ivec, 2 uvec input: must use integer vertex formats of that signedness */
} mgl_attrib;

typedef struct mgl_frag_out {
    char name[96];
    int location;
} mgl_frag_out;

typedef struct mgl_xlate_result {
    int ok;
    char *log;              /* compile/link errors, malloc'd */
    char *msl[MGL_NUM_STAGES];  /* malloc'd MSL source per present stage, entry point "main0" */
    int default_block_size[MGL_NUM_STAGES];
    int local_size[3];      /* compute only */

    mgl_uniform *uniforms; int num_uniforms;
    mgl_texture_slot *textures; int num_textures;
    mgl_ubo *ubos; int num_ubos;
    mgl_ubo *ssbos; int num_ssbos;   /* shader storage blocks; binding = layout(binding) */
    mgl_attrib *attribs; int num_attribs;
    mgl_frag_out *outs; int num_outs;

    /* Geometry-shader programs (mgl_gs.c): the compute stage runs VS + GS per input triangle and writes
       gs_max_vertices records of gs_record_vec4s vec4s each, plus a count; the vertex stage is a passthrough
       that turns those triangle strips into a triangle list. 0 when the program has no geometry shader. */
    int gs_max_vertices, gs_record_vec4s;
    int uses_scene;             /* some stage declares an accelerationStructureEXT */
    void *pending[MGL_NUM_STAGES]; /* deferred MSL emission (mgl_xlate_set_deferred), consumed by mgl_xlate_emit */
} mgl_xlate_result;

/* Sources may be NULL for absent stages (vertex+fragment, or compute alone). glBindAttribLocation is handled
   by the front end, which maps GL attribute indices onto the reflected locations. */
/* glBindFragDataLocation for the next mgl_xlate_program call on this thread (NULL/0 to clear) */
typedef struct mgl_frag_bind { char name[96]; int loc; } mgl_frag_bind;
void mgl_xlate_set_frag_binds(const mgl_frag_bind *binds, int n);
void mgl_xlate_program(const char *src[MGL_NUM_STAGES], mgl_xlate_result *out);
void mgl_xlate_free(mgl_xlate_result *r);
/* Deferred emission, so links can return as soon as reflection is known: with deferred on (this thread),
   mgl_xlate_program fills everything except msl[] and leaves r->pending[] instead. mgl_xlate_emit turns
   pending[] into MSL on any thread (one call per result), frees it, and returns 0 with *log set on failure. */
void mgl_xlate_set_deferred(int on);
int mgl_xlate_emit(void *pending[MGL_NUM_STAGES], char *msl[MGL_NUM_STAGES], char **log);
/* Programs with a geometry shader: src = {vertex, fragment, NULL} as for mgl_xlate_program. */
void mgl_gs_translate(const char *src[MGL_NUM_STAGES], const char *geometry, mgl_xlate_result *out);
/* Internal buffers for geometry emulation: GLSL storage blocks named "mgl_i<N>_" map to MSL buffer
   MGL_BUF_INTERNAL_BASE + N (only in compute and the passthrough vertex stage, where no vertex buffers are bound). */
#define MGL_BUF_INTERNAL_BASE 21
