/* Name tables, context state defaults, state queries, glEnable/glDisable and friends. */
#include <string.h>
#include "mgl_state.h"

static mgl_state the_state;
mgl_state *mgl = &the_state;

GLuint mgl_table_gen(mgl_table *t)
{
    if (t->next == 0)
        t->next = 1;
    while (t->next < t->cap && t->obj[t->next])
        t->next++;
    GLuint name = t->next++;
    if (name >= t->cap) {
        unsigned cap = t->cap ? t->cap * 2 : 256;
        while (cap <= name)
            cap *= 2;
        t->obj = realloc(t->obj, cap * sizeof(void *));
        memset(t->obj + t->cap, 0, (cap - t->cap) * sizeof(void *));
        t->cap = cap;
    }
    return name;
}

void mgl_table_set(mgl_table *t, GLuint name, void *obj)
{
    if (name >= t->cap) {
        unsigned cap = t->cap ? t->cap : 256;
        while (cap <= name)
            cap *= 2;
        t->obj = realloc(t->obj, cap * sizeof(void *));
        memset(t->obj + t->cap, 0, (cap - t->cap) * sizeof(void *));
        t->cap = cap;
    }
    t->obj[name] = obj;
}

void *mgl_table_get(mgl_table *t, GLuint name)
{
    return name && name < t->cap ? t->obj[name] : NULL;
}

void mgl_table_remove(mgl_table *t, GLuint name)
{
    if (name && name < t->cap) {
        t->obj[name] = NULL;
        if (name < t->next)
            t->next = name;
    }
}

void mgl_state_init(mgl_state *s)
{
    s->blend_src_rgb = s->blend_src_a = GL_ONE;
    s->blend_dst_rgb = s->blend_dst_a = GL_ZERO;
    s->blend_eq_rgb = s->blend_eq_a = GL_FUNC_ADD;
    s->depth_func = GL_LESS;
    s->cull_face = GL_BACK;
    s->front_face = GL_CCW;
    s->depth_mask = GL_TRUE;
    for (int i = 0; i < 4; i++)
        s->color_mask[i] = GL_TRUE;
    s->clear_depth = 1.0f;
    s->unpack_alignment = s->pack_alignment = 4;
}

__attribute__((constructor)) static void init_state(void)
{
    mgl_state_init(mgl);
}

/* ---- enable / disable ---- */
static int *cap_flag(GLenum cap)
{
    switch (cap) {
    case GL_BLEND: return &mgl->blend;
    case GL_DEPTH_TEST: return &mgl->depth_test;
    case GL_CULL_FACE: return &mgl->cull_face_enabled;
    case GL_SCISSOR_TEST: return &mgl->scissor_test;
    case GL_POLYGON_OFFSET_FILL: return &mgl->polygon_offset_fill;
    }
    return NULL;
}

void glEnable(GLenum cap)
{
    int *f = cap_flag(cap);
    if (f)
        *f = 1;
    if (cap == GL_BLEND)
        memset(mgl->blend_i, 1, sizeof mgl->blend_i);
    /* GL_DEBUG_OUTPUT, GL_DEBUG_OUTPUT_SYNCHRONOUS, GL_TEXTURE_CUBE_MAP_SEAMLESS, GL_PROGRAM_POINT_SIZE:
       accepted, no effect (Metal cube maps are always seamless) */
}

void glDisable(GLenum cap)
{
    int *f = cap_flag(cap);
    if (f)
        *f = 0;
    if (cap == GL_BLEND)
        memset(mgl->blend_i, 0, sizeof mgl->blend_i);
}

void glEnablei(GLenum cap, GLuint index)
{
    if (cap == GL_BLEND && index < 8)
        mgl->blend_i[index] = 1;
    else
        glEnable(cap); /* other indexed caps (scissor per viewport) only have index 0 here */
}

void glDisablei(GLenum cap, GLuint index)
{
    if (cap == GL_BLEND && index < 8)
        mgl->blend_i[index] = 0;
    else
        glDisable(cap);
}

GLboolean glIsEnabledi(GLenum cap, GLuint index)
{
    if (cap == GL_BLEND && index < 8)
        return mgl->blend_i[index];
    return glIsEnabled(cap);
}

GLboolean glIsEnabled(GLenum cap)
{
    int *f = cap_flag(cap);
    return f && *f;
}

void glBlendFunc(GLenum sfactor, GLenum dfactor)
{
    mgl->blend_src_rgb = mgl->blend_src_a = sfactor;
    mgl->blend_dst_rgb = mgl->blend_dst_a = dfactor;
}

void glBlendFuncSeparate(GLenum src_rgb, GLenum dst_rgb, GLenum src_a, GLenum dst_a)
{
    mgl->blend_src_rgb = src_rgb;
    mgl->blend_dst_rgb = dst_rgb;
    mgl->blend_src_a = src_a;
    mgl->blend_dst_a = dst_a;
}

void glBlendEquation(GLenum mode)
{
    mgl->blend_eq_rgb = mgl->blend_eq_a = mode;
}

void glBlendEquationSeparate(GLenum rgb, GLenum alpha)
{
    mgl->blend_eq_rgb = rgb;
    mgl->blend_eq_a = alpha;
}

void glDepthFunc(GLenum func) { mgl->depth_func = func; }
void glDepthMask(GLboolean flag) { mgl->depth_mask = flag; }
void glCullFace(GLenum mode) { mgl->cull_face = mode; }
void glFrontFace(GLenum mode) { mgl->front_face = mode; }
void glClearDepth(GLdouble d) { mgl->clear_depth = (float)d; }
void glClearDepthf(GLfloat d) { mgl->clear_depth = d; }

void glColorMask(GLboolean r, GLboolean g, GLboolean b, GLboolean a)
{
    mgl->color_mask[0] = r;
    mgl->color_mask[1] = g;
    mgl->color_mask[2] = b;
    mgl->color_mask[3] = a;
}

void glClearColor(GLfloat r, GLfloat g, GLfloat b, GLfloat a)
{
    mgl->clear_color[0] = r;
    mgl->clear_color[1] = g;
    mgl->clear_color[2] = b;
    mgl->clear_color[3] = a;
}

void glViewport(GLint x, GLint y, GLsizei w, GLsizei h)
{
    mgl->viewport[0] = x;
    mgl->viewport[1] = y;
    mgl->viewport[2] = w;
    mgl->viewport[3] = h;
}

void glScissor(GLint x, GLint y, GLsizei w, GLsizei h)
{
    mgl->scissor[0] = x;
    mgl->scissor[1] = y;
    mgl->scissor[2] = w;
    mgl->scissor[3] = h;
}

void glPolygonOffset(GLfloat factor, GLfloat units)
{
    mgl->polygon_offset_factor = factor;
    mgl->polygon_offset_units = units;
}

void glPixelStorei(GLenum pname, GLint v)
{
    switch (pname) {
    case GL_UNPACK_ALIGNMENT: mgl->unpack_alignment = v; break;
    case GL_UNPACK_ROW_LENGTH: mgl->unpack_row_length = v; break;
    case GL_UNPACK_SKIP_ROWS: mgl->unpack_skip_rows = v; break;
    case GL_UNPACK_SKIP_PIXELS: mgl->unpack_skip_pixels = v; break;
    case GL_UNPACK_IMAGE_HEIGHT: mgl->unpack_image_height = v; break;
    case GL_UNPACK_SKIP_IMAGES: mgl->unpack_skip_images = v; break;
    case GL_PACK_ALIGNMENT: mgl->pack_alignment = v; break;
    case GL_PACK_ROW_LENGTH: mgl->pack_row_length = v; break;
    default: break; /* swap bytes / lsb first: never used by Minecraft */
    }
}

/* Debug output: Minecraft installs a callback; we have nothing to report through it yet. */
void glDebugMessageCallback(GLDEBUGPROC callback, const void *user) {}
void glDebugMessageControl(GLenum source, GLenum type, GLenum severity, GLsizei count, const GLuint *ids, GLboolean enabled) {}
void glDebugMessageInsert(GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length, const GLchar *buf) {}
void glObjectLabel(GLenum identifier, GLuint name, GLsizei length, const GLchar *label) {}
void glPushDebugGroup(GLenum source, GLuint id, GLsizei length, const GLchar *message) {}
void glPopDebugGroup(void) {}
void glHint(GLenum target, GLenum mode) {}
void glLineWidth(GLfloat width) {}
void glPolygonMode(GLenum face, GLenum mode)
{
    if (mode != GL_FILL)
        mgl_log("glPolygonMode(%s) ignored", mode == GL_LINE ? "GL_LINE" : "GL_POINT");
}

void glFlush(void) { mglb_flush(); }
void glFinish(void) { mglb_finish(); }

/* ---- queries of current state ---- */
int mgl_get_state_integer(GLenum pname, GLint *out)
{
    switch (pname) {
    case GL_ARRAY_BUFFER_BINDING: *out = (GLint)mgl->array_buffer; return 1;
    case GL_ELEMENT_ARRAY_BUFFER_BINDING: {
        mgl_vao *v = mgl->vao ? mgl_table_get(&mgl->vaos, mgl->vao) : &mgl->default_vao;
        *out = v ? (GLint)v->element_buffer : 0;
        return 1;
    }
    case GL_VERTEX_ARRAY_BINDING: *out = (GLint)mgl->vao; return 1;
    case GL_CURRENT_PROGRAM: *out = (GLint)mgl->current_program; return 1;
    case GL_ACTIVE_TEXTURE: *out = (GLint)(GL_TEXTURE0 + mgl->active_unit); return 1;
    case GL_TEXTURE_BINDING_2D: *out = (GLint)mgl->bound_tex[mgl->active_unit][0]; return 1;
    case GL_TEXTURE_BINDING_3D: *out = (GLint)mgl->bound_tex[mgl->active_unit][1]; return 1;
    case GL_TEXTURE_BINDING_2D_ARRAY: *out = (GLint)mgl->bound_tex[mgl->active_unit][2]; return 1;
    case GL_TEXTURE_BINDING_CUBE_MAP: *out = (GLint)mgl->bound_tex[mgl->active_unit][3]; return 1;
    case GL_DRAW_FRAMEBUFFER_BINDING: *out = (GLint)mgl->draw_fbo; return 1;
    case GL_READ_FRAMEBUFFER_BINDING: *out = (GLint)mgl->read_fbo; return 1;
    case GL_UNIFORM_BUFFER_BINDING: *out = (GLint)mgl->uniform_buffer; return 1;
    case GL_COPY_READ_BUFFER_BINDING: *out = (GLint)mgl->copy_read_buffer; return 1;
    case GL_COPY_WRITE_BUFFER_BINDING: *out = (GLint)mgl->copy_write_buffer; return 1;
    case GL_PIXEL_UNPACK_BUFFER_BINDING: *out = (GLint)mgl->pixel_unpack_buffer; return 1;
    case GL_VIEWPORT: memcpy(out, mgl->viewport, sizeof mgl->viewport); return 1;
    case GL_SCISSOR_BOX: memcpy(out, mgl->scissor, sizeof mgl->scissor); return 1;
    case GL_BLEND_SRC_RGB: *out = (GLint)mgl->blend_src_rgb; return 1;
    case GL_BLEND_DST_RGB: *out = (GLint)mgl->blend_dst_rgb; return 1;
    case GL_BLEND_SRC_ALPHA: *out = (GLint)mgl->blend_src_a; return 1;
    case GL_BLEND_DST_ALPHA: *out = (GLint)mgl->blend_dst_a; return 1;
    case GL_DEPTH_FUNC: *out = (GLint)mgl->depth_func; return 1;
    case GL_UNPACK_ALIGNMENT: *out = mgl->unpack_alignment; return 1;
    case GL_PACK_ALIGNMENT: *out = mgl->pack_alignment; return 1;
    case GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS:
    case GL_MAX_FRAGMENT_SHADER_STORAGE_BLOCKS:
    case GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS:
    case GL_MAX_COMBINED_SHADER_STORAGE_BLOCKS: *out = 8; return 1;
    case GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS: *out = 8; return 1;
    case GL_MAX_UNIFORM_BUFFER_BINDINGS: *out = MGL_MAX_UBO_BINDINGS; return 1;
    case GL_MAX_VERTEX_UNIFORM_BLOCKS:
    case GL_MAX_FRAGMENT_UNIFORM_BLOCKS:
    case GL_MAX_COMPUTE_UNIFORM_BLOCKS: *out = 12; return 1;
    case GL_MAX_VERTEX_UNIFORM_COMPONENTS:
    case GL_MAX_FRAGMENT_UNIFORM_COMPONENTS: *out = 4096; return 1;
    case GL_MAX_VARYING_COMPONENTS: *out = 124; return 1;
    case GL_MAX_TEXTURE_LOD_BIAS: *out = 16; return 1;
    case GL_MAX_TEXTURE_MAX_ANISOTROPY: *out = 16; return 1;
    case GL_MAX_CUBE_MAP_TEXTURE_SIZE: *out = 16384; return 1;
    case GL_MAX_COMPUTE_WORK_GROUP_COUNT: out[0] = out[1] = out[2] = 65535; return 1;
    case GL_MAX_COMPUTE_WORK_GROUP_SIZE: out[0] = out[1] = out[2] = 1024; return 1;
    case GL_MAX_FRAMEBUFFER_WIDTH:
    case GL_MAX_FRAMEBUFFER_HEIGHT: *out = 16384; return 1;
    case GL_MAX_VERTEX_ATTRIB_BINDINGS: *out = MGL_MAX_VERTEX_BUFFERS; return 1;
    case GL_MAX_VERTEX_ATTRIB_STRIDE: *out = 2048; return 1;
    case GL_MAX_DEBUG_MESSAGE_LENGTH: *out = 1024; return 1;
    }
    return 0;
}

void glGetFloatv(GLenum pname, GLfloat *data)
{
    GLint tmp[4] = {0};
    switch (pname) {
    case GL_COLOR_CLEAR_VALUE: memcpy(data, mgl->clear_color, sizeof mgl->clear_color); return;
    case GL_DEPTH_CLEAR_VALUE: *data = mgl->clear_depth; return;
    case GL_MAX_TEXTURE_MAX_ANISOTROPY: *data = 16.0f; return;
    case GL_MAX_TEXTURE_LOD_BIAS: *data = 16.0f; return;
    case GL_LINE_WIDTH: *data = 1.0f; return;
    }
    glGetIntegerv(pname, tmp);
    data[0] = (GLfloat)tmp[0];
}

void glGetBooleanv(GLenum pname, GLboolean *data)
{
    switch (pname) {
    case GL_DEPTH_WRITEMASK: *data = mgl->depth_mask; return;
    case GL_COLOR_WRITEMASK: memcpy(data, mgl->color_mask, 4); return;
    case GL_BLEND: case GL_DEPTH_TEST: case GL_CULL_FACE: case GL_SCISSOR_TEST:
        *data = glIsEnabled(pname);
        return;
    }
    GLint v = 0;
    glGetIntegerv(pname, &v);
    *data = v != 0;
}

void glGetInteger64v(GLenum pname, GLint64 *data)
{
    GLint v[4] = {0};
    glGetIntegerv(pname, v);
    *data = v[0];
}

void glGetIntegeri_v(GLenum target, GLuint index, GLint *data)
{
    switch (target) {
    case GL_MAX_COMPUTE_WORK_GROUP_COUNT: *data = 65535; return;
    case GL_MAX_COMPUTE_WORK_GROUP_SIZE: *data = index == 2 ? 64 : 1024; return;
    case GL_UNIFORM_BUFFER_BINDING: *data = index < MGL_MAX_UBO_BINDINGS ? (GLint)mgl->ubo[index].buffer : 0; return;
    }
    mgl_log("glGetIntegeri_v: unknown target 0x%04X", target);
    *data = 0;
}
