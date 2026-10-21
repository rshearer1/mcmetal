/* GL object model and context state. One context, used from Minecraft's render thread. */
#pragma once
#include <stdlib.h>
#include "mgl_gl.h"
#include "mgl_backend.h"
#include "mgl_xlate.h"
#include "mgl_context.h"
#include "mgl_log.h"

#define MGL_MAX_UNITS 96

/* GL 4.6 / extension enums not in the 4.5 core header */
#ifndef GL_TEXTURE_MAX_ANISOTROPY
#define GL_TEXTURE_MAX_ANISOTROPY 0x84FE
#define GL_MAX_TEXTURE_MAX_ANISOTROPY 0x84FF
#endif
#define MGL_MAX_IMAGE_UNITS 8
#define MGL_MAX_UBO_BINDINGS 36
#define MGL_MAX_SSBO_BINDINGS 16
#define MGL_GEOMETRY_SLOT 3

/* ---- name tables: GL names are small integers handed out by us ---- */
typedef struct mgl_table {
    void **obj;
    unsigned cap;
    unsigned next;
} mgl_table;

GLuint mgl_table_gen(mgl_table *t);
void mgl_table_set(mgl_table *t, GLuint name, void *obj);
void *mgl_table_get(mgl_table *t, GLuint name);
void mgl_table_remove(mgl_table *t, GLuint name);

/* ---- objects ---- */
typedef struct mgl_buffer {
    mglb_buffer *mem;
    size_t size;
    GLbitfield storage_flags;   /* 0 for glBufferData buffers */
    int immutable;
    /* mapping */
    int mapped;
    size_t map_offset, map_length;
    GLbitfield map_access;
} mgl_buffer;

typedef struct mgl_texture {
    GLenum target;              /* 0 until first bind */
    mglb_texture *mem;
    mglb_texture_desc desc;
    GLenum internal_format;
    int level_defined;          /* bitmask of levels given data/storage through glTexImage */
    int base_w, base_h, base_d;
    mgl_sampler_state sampler;
    int max_level;
    int has_swizzle, swizzle[4]; /* GL_TEXTURE_SWIZZLE_*; identity until has_swizzle */
} mgl_texture;

typedef struct mgl_sampler {
    mgl_sampler_state s;
} mgl_sampler;

typedef struct mgl_attachment {
    mgl_texture *tex;
    GLuint tex_name;
    int level, layer;
} mgl_attachment;

typedef struct mgl_framebuffer {
    mgl_attachment color[MGL_MAX_ATTACHMENTS];
    mgl_attachment depth;
    GLenum draw_buffers[MGL_MAX_ATTACHMENTS];
    int num_draw_buffers;
    GLenum read_buffer;
} mgl_framebuffer;

typedef struct mgl_vattrib {
    int enabled;
    GLuint buffer;              /* GL buffer name captured at glVertexAttribPointer */
    int size;
    GLenum type;
    int normalized, integer;
    int stride;
    size_t offset;
    GLuint divisor;             /* 0 = per vertex, n = advance every n instances */
} mgl_vattrib;

typedef struct mgl_vao {
    mgl_vattrib attr[MGL_MAX_VERTEX_ATTRIBS];
    GLuint element_buffer;
} mgl_vao;

typedef struct mgl_shader {
    GLenum type;
    char *source;
    int compiled;
    int delete_pending;
    int refs;                   /* attachments */
} mgl_shader;

typedef struct mgl_program {
    GLuint attached[4];         /* shader names by stage; [3] = geometry (MGL_GEOMETRY_SLOT) */
    int linked;
    char *info_log;
    mgl_xlate_result x;
    mglb_program *gpu;
    int rt_pos_loc, rt_ent_loc, rt_region_off, rt_mv_off, rt_proj_off; /* terrain capture (mgl_rt.c); rt_pos_loc -1 = not terrain */
    unsigned char *ublock[3];   /* default-block shadow per stage (vertex, fragment, compute) */
    int unit_of[MGL_MAX_TEXTURES * 3]; /* GL texture unit per x.textures[] entry (glUniform1i on a sampler) */
    int image_unit_of[MGL_MAX_TEXTURES * 3];
    /* glBindAttribLocation requests: name -> GL index; after link, gl_index_to_location maps to MSL attribute */
    struct { char name[96]; int index; } *bound_attribs;
    int num_bound_attribs;
    int gl_index_to_loc[MGL_MAX_VERTEX_ATTRIBS];
    int attrib_gl_index[64];    /* GL index per x.attribs[] entry (glGetAttribLocation) */
    struct mgl_link_job *job;   /* MSL emission + Metal compile still running on a worker (mgl_program.c) */
    mgl_frag_bind *bound_frag;
    int num_bound_frag;
    int ubo_binding[12];        /* GL binding point per x.ubos[] entry */
    int ssbo_binding[8];        /* GL binding point per x.ssbos[] entry */
    int delete_pending;
    char debug_name[64];        /* glObjectLabel (Iris names its programs, e.g. "gbuffers_water") */
} mgl_program;

typedef struct mgl_query {
    GLenum target;
    uint64_t result;
    int available;
} mgl_query;

typedef struct mgl_sync {
    uint64_t fence;
} mgl_sync;

typedef struct mgl_image_unit {
    GLuint texture;
    int level, layered, layer;
    GLenum access, format;
} mgl_image_unit;

/* ---- the context ---- */
typedef struct mgl_state {
    mgl_table buffers, textures, samplers, framebuffers, vaos, shaders, programs, queries;

    GLuint array_buffer, copy_read_buffer, copy_write_buffer, pixel_unpack_buffer, pixel_pack_buffer,
           uniform_buffer, draw_indirect_buffer, shader_storage_buffer, element_buffer_no_vao;
    struct { GLuint buffer; size_t offset, size; } ubo[MGL_MAX_UBO_BINDINGS];
    struct { GLuint buffer; size_t offset, size; } ssbo[MGL_MAX_SSBO_BINDINGS];
    GLuint vao;                 /* 0 = none bound (core profile: draws without VAO are errors, we allow) */
    mgl_vao default_vao;

    GLuint active_unit;
    GLuint bound_tex[MGL_MAX_UNITS][4];   /* per unit: 2D, 3D, 2D_ARRAY, CUBE */
    GLuint bound_sampler[MGL_MAX_UNITS];
    mgl_image_unit images[MGL_MAX_IMAGE_UNITS];

    GLuint draw_fbo, read_fbo;
    GLuint current_program;

    /* fixed-function state */
    int blend, depth_test, cull_face_enabled, scissor_test, polygon_offset_fill;
    unsigned char blend_i[8];   /* per draw buffer (glEnablei); glEnable(GL_BLEND) sets all */
    GLenum blend_src_rgb, blend_dst_rgb, blend_src_a, blend_dst_a, blend_eq_rgb, blend_eq_a;
    GLenum depth_func, cull_face, front_face;
    GLboolean depth_mask, color_mask[4];
    int viewport[4], scissor[4];
    float clear_color[4], clear_depth;
    float polygon_offset_factor, polygon_offset_units;

    /* pixel store */
    int unpack_alignment, unpack_row_length, unpack_skip_rows, unpack_skip_pixels, unpack_image_height, unpack_skip_images;
    int pack_alignment, pack_row_length;

    /* window framebuffer, provided by the backend */
    mglb_texture *window_color, *window_depth;
    int window_w, window_h;
} mgl_state;

extern mgl_state *mgl;          /* the current context's state */
void mgl_state_init(mgl_state *s);

/* helpers shared between files */
mgl_buffer *mgl_buffer_obj(GLuint name);
mgl_texture *mgl_texture_obj(GLuint name);
GLuint *mgl_bound_texture_slot(GLenum target);
int mgl_tex_target_index(GLenum target);
enum mgl_format mgl_format_from_internal(GLenum internal, int *bytes_per_texel);
void mgl_sampler_defaults(mgl_sampler_state *s);
int mgl_build_target(GLuint fbo, mgl_target *t);  /* 0 if incomplete */
void mgl_window_resize(int w, int h);

/* mgl_rt.c */
void mgl_rt_link(mgl_program *p);
void mgl_rt_record(mgl_program *p, const mgl_draw *d);
void mgl_rt_note_write(mglb_buffer *m, size_t offset, size_t size);
void mgl_rt_end_frame(void); /* called by the backend before present */
/* Waits for a program's background compile and applies it; draws and dispatches call this before using p->gpu. */
void mgl_program_wait(mgl_program *p);
/* mgl_readback.c: timed window screenshots (MGL_SHOT_DIR), called by the backend before each present */
void mgl_shot_tick(void);
int mgl_write_png(const char *path, const unsigned char *rgba_bottom_up, int w, int h);
