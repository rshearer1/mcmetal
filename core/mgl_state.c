/* Name tables, context state defaults, state queries, glEnable/glDisable and friends. */
#include <stdlib.h>
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

static void set_blend_i(mgl_state *s, int i, GLenum src_rgb, GLenum dst_rgb, GLenum src_a, GLenum dst_a, GLenum eq_rgb,
                        GLenum eq_a)
{
    GLenum *f = s->blend_fn_i[i];
    f[0] = src_rgb, f[1] = dst_rgb, f[2] = src_a, f[3] = dst_a, f[4] = eq_rgb, f[5] = eq_a;
}

void mgl_state_init(mgl_state *s)
{
    s->blend_src_rgb = s->blend_src_a = GL_ONE;
    s->blend_dst_rgb = s->blend_dst_a = GL_ZERO;
    s->blend_eq_rgb = s->blend_eq_a = GL_FUNC_ADD;
    for (int i = 0; i < 8; i++)
        set_blend_i(s, i, GL_ONE, GL_ZERO, GL_ONE, GL_ZERO, GL_FUNC_ADD, GL_FUNC_ADD);
    s->depth_func = GL_LESS;
    s->cull_face = GL_BACK;
    s->front_face = GL_CCW;
    s->depth_mask = GL_TRUE;
    s->stencil_func = GL_ALWAYS;
    s->stencil_fail = s->stencil_zfail = s->stencil_zpass = GL_KEEP;
    s->stencil_value_mask = s->stencil_writemask = 0xFFFFFFFFu;
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
    glBlendFuncSeparate(sfactor, dfactor, sfactor, dfactor);
}

void glBlendFuncSeparate(GLenum src_rgb, GLenum dst_rgb, GLenum src_a, GLenum dst_a)
{
    mgl->blend_src_rgb = src_rgb;
    mgl->blend_dst_rgb = dst_rgb;
    mgl->blend_src_a = src_a;
    mgl->blend_dst_a = dst_a;
    for (int i = 0; i < 8; i++)
        set_blend_i(mgl, i, src_rgb, dst_rgb, src_a, dst_a, mgl->blend_fn_i[i][4], mgl->blend_fn_i[i][5]);
}

void glBlendEquation(GLenum mode)
{
    glBlendEquationSeparate(mode, mode);
}

void glBlendEquationSeparate(GLenum rgb, GLenum alpha)
{
    mgl->blend_eq_rgb = rgb;
    mgl->blend_eq_a = alpha;
    for (int i = 0; i < 8; i++)
        mgl->blend_fn_i[i][4] = rgb, mgl->blend_fn_i[i][5] = alpha;
}

/* Per draw buffer blending (GL 4.0 / ARB_draw_buffers_blend). Iris sets it for packs' blend.<program>.<buffer>
   overrides, and calls the ARB names (Photon). */
void glBlendFuncSeparatei(GLuint buf, GLenum src_rgb, GLenum dst_rgb, GLenum src_a, GLenum dst_a)
{
    if (buf < 8)
        set_blend_i(mgl, (int)buf, src_rgb, dst_rgb, src_a, dst_a, mgl->blend_fn_i[buf][4], mgl->blend_fn_i[buf][5]);
}

void glBlendFunci(GLuint buf, GLenum src, GLenum dst) { glBlendFuncSeparatei(buf, src, dst, src, dst); }

void glBlendEquationSeparatei(GLuint buf, GLenum rgb, GLenum alpha)
{
    if (buf < 8)
        mgl->blend_fn_i[buf][4] = rgb, mgl->blend_fn_i[buf][5] = alpha;
}

void glBlendEquationi(GLuint buf, GLenum mode) { glBlendEquationSeparatei(buf, mode, mode); }

GLAPI void glBlendFuncSeparateiARB(GLuint buf, GLenum src_rgb, GLenum dst_rgb, GLenum src_a, GLenum dst_a)
{
    glBlendFuncSeparatei(buf, src_rgb, dst_rgb, src_a, dst_a);
}
GLAPI void glBlendFunciARB(GLuint buf, GLenum src, GLenum dst) { glBlendFunci(buf, src, dst); }
GLAPI void glBlendEquationSeparateiARB(GLuint buf, GLenum rgb, GLenum alpha) { glBlendEquationSeparatei(buf, rgb, alpha); }
GLAPI void glBlendEquationiARB(GLuint buf, GLenum mode) { glBlendEquationi(buf, mode); }

void glDepthFunc(GLenum func) { mgl->depth_func = func; }
void glDepthMask(GLboolean flag) { mgl->depth_mask = flag; }

static void stencil_note(void)
{
    static int said;
    if (!said++)
        mgl_log("stencil state set: kept for queries, no stencil test is done");
}
void glStencilFunc(GLenum func, GLint ref, GLuint mask)
{
    mgl->stencil_func = func, mgl->stencil_ref = ref, mgl->stencil_value_mask = mask;
    if (func != GL_ALWAYS)
        stencil_note();
}
void glStencilOp(GLenum fail, GLenum zfail, GLenum zpass)
{
    mgl->stencil_fail = fail, mgl->stencil_zfail = zfail, mgl->stencil_zpass = zpass;
}
void glStencilMask(GLuint mask) { mgl->stencil_writemask = mask; }
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
void glPushDebugGroup(GLenum source, GLuint id, GLsizei length, const GLchar *message) {}
void glPopDebugGroup(void) {}
void glHint(GLenum target, GLenum mode) {}
void glLineWidth(GLfloat width) {}
void glPolygonMode(GLenum face, GLenum mode)
{
    if (mode != GL_FILL)
        mgl_log("glPolygonMode(%s) ignored", mode == GL_LINE ? "GL_LINE" : "GL_POINT");
}

/* glFlush only promises the commands run eventually, and with one context everything is submitted at the frame's
   end (or sooner, when the CPU waits on the GPU) anyway. Submitting here ended the render pass being drawn, so the
   rest of the frame had to store and reload the whole framebuffer; Distant Horizons on a Mac flushes after every
   256 KB of LOD upload, dozens of times a frame while it builds. MGL_FLUSH=1 submits at every glFlush again. */
void glFlush(void)
{
    static int submit = -1;
    if (submit < 0) {
        submit = getenv("MGL_FLUSH") && atoi(getenv("MGL_FLUSH"));
        mgl_log(submit ? "glFlush submits the GPU work drawn so far (MGL_FLUSH=1)"
                       : "glFlush is left to the frame's end (MGL_FLUSH=1 submits at each one)");
    }
    if (submit)
        mglb_flush();
}
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
    case GL_DEPTH_WRITEMASK: *out = mgl->depth_mask; return 1;
    case GL_COLOR_WRITEMASK: for (int i = 0; i < 4; i++) out[i] = mgl->color_mask[i]; return 1;
    case GL_BLEND_EQUATION_RGB: *out = (GLint)mgl->blend_eq_rgb; return 1;
    case GL_BLEND_EQUATION_ALPHA: *out = (GLint)mgl->blend_eq_a; return 1;
    case GL_CULL_FACE_MODE: *out = (GLint)mgl->cull_face; return 1;
    case GL_FRONT_FACE: *out = (GLint)mgl->front_face; return 1;
    /* one value, as core-profile drivers answer: callers such as LWJGL's glGetInteger pass room for one int */
    case GL_POLYGON_MODE: *out = GL_FILL; return 1; /* glPolygonMode is ignored */
    case GL_STENCIL_FUNC: *out = (GLint)mgl->stencil_func; return 1;
    case GL_STENCIL_REF: *out = mgl->stencil_ref; return 1;
    case GL_STENCIL_VALUE_MASK: *out = (GLint)mgl->stencil_value_mask; return 1;
    case GL_STENCIL_WRITEMASK: *out = (GLint)mgl->stencil_writemask; return 1;
    case GL_STENCIL_FAIL: *out = (GLint)mgl->stencil_fail; return 1;
    case GL_STENCIL_PASS_DEPTH_FAIL: *out = (GLint)mgl->stencil_zfail; return 1;
    case GL_STENCIL_PASS_DEPTH_PASS: *out = (GLint)mgl->stencil_zpass; return 1;
    case GL_STENCIL_CLEAR_VALUE: *out = 0; return 1;
    case GL_UNPACK_ROW_LENGTH: *out = mgl->unpack_row_length; return 1;
    case GL_UNPACK_SKIP_ROWS: *out = mgl->unpack_skip_rows; return 1;
    case GL_UNPACK_SKIP_PIXELS: *out = mgl->unpack_skip_pixels; return 1;
    case GL_UNPACK_IMAGE_HEIGHT: *out = mgl->unpack_image_height; return 1;
    case GL_UNPACK_SKIP_IMAGES: *out = mgl->unpack_skip_images; return 1;
    case GL_PACK_ROW_LENGTH: *out = mgl->pack_row_length; return 1;
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
    GLint tmp[16] = {0};
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
    GLint v[16] = {0}; /* room for multi-value pnames (viewport, scissor box) */
    glGetIntegerv(pname, v);
    *data = v[0] != 0;
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
