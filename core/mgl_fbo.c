/* Framebuffer objects, clears and blits. Framebuffer 0 is an offscreen texture pair owned by the context;
   the backend copies it (flipped) into the window on swap. */
#include <string.h>
#include "mgl_state.h"

static mgl_framebuffer *fbo_obj(GLuint name)
{
    return mgl_table_get(&mgl->framebuffers, name);
}

static mgl_framebuffer *new_fbo(void)
{
    mgl_framebuffer *f = calloc(1, sizeof *f);
    f->draw_buffers[0] = GL_COLOR_ATTACHMENT0;
    f->num_draw_buffers = 1;
    f->read_buffer = GL_COLOR_ATTACHMENT0;
    return f;
}

void glGenFramebuffers(GLsizei n, GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        names[i] = mgl_table_gen(&mgl->framebuffers);
        mgl_table_set(&mgl->framebuffers, names[i], new_fbo());
    }
}

void glCreateFramebuffers(GLsizei n, GLuint *names) { glGenFramebuffers(n, names); }

void glDeleteFramebuffers(GLsizei n, const GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        if (!fbo_obj(names[i]))
            continue;
        free(fbo_obj(names[i]));
        mgl_table_remove(&mgl->framebuffers, names[i]);
        if (mgl->draw_fbo == names[i])
            mgl->draw_fbo = 0;
        if (mgl->read_fbo == names[i])
            mgl->read_fbo = 0;
    }
}

GLboolean glIsFramebuffer(GLuint name) { return fbo_obj(name) != NULL; }

void glBindFramebuffer(GLenum target, GLuint name)
{
    if (name && !fbo_obj(name))
        mgl_table_set(&mgl->framebuffers, name, new_fbo());
    if (target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER)
        mgl->draw_fbo = name;
    if (target == GL_FRAMEBUFFER || target == GL_READ_FRAMEBUFFER)
        mgl->read_fbo = name;
}

static mgl_framebuffer *bound_fbo(GLenum target)
{
    GLuint name = target == GL_READ_FRAMEBUFFER ? mgl->read_fbo : mgl->draw_fbo;
    mgl_framebuffer *f = fbo_obj(name);
    if (!f)
        mgl_set_error(GL_INVALID_OPERATION);
    return f;
}

static void attach(mgl_framebuffer *f, GLenum attachment, GLuint tex, int level, int layer)
{
    mgl_attachment *a;
    if (attachment >= GL_COLOR_ATTACHMENT0 && attachment < GL_COLOR_ATTACHMENT0 + MGL_MAX_ATTACHMENTS)
        a = &f->color[attachment - GL_COLOR_ATTACHMENT0];
    else if (attachment == GL_DEPTH_ATTACHMENT || attachment == GL_DEPTH_STENCIL_ATTACHMENT)
        a = &f->depth;
    else {
        mgl_log("framebuffer attachment 0x%04X not supported", attachment);
        return;
    }
    a->tex_name = tex;
    a->tex = mgl_texture_obj(tex);
    a->level = level;
    a->layer = layer;
}

void glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget, GLuint tex, GLint level)
{
    mgl_framebuffer *f = bound_fbo(target);
    int face = textarget >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && textarget <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z
                   ? (int)(textarget - GL_TEXTURE_CUBE_MAP_POSITIVE_X) : 0;
    if (f)
        attach(f, attachment, tex, level, face);
}

void glFramebufferTexture(GLenum target, GLenum attachment, GLuint tex, GLint level)
{
    mgl_framebuffer *f = bound_fbo(target);
    if (f)
        attach(f, attachment, tex, level, 0);
}

void glFramebufferTextureLayer(GLenum target, GLenum attachment, GLuint tex, GLint level, GLint layer)
{
    mgl_framebuffer *f = bound_fbo(target);
    if (f)
        attach(f, attachment, tex, level, layer);
}

void glNamedFramebufferTexture(GLuint fbo, GLenum attachment, GLuint tex, GLint level)
{
    mgl_framebuffer *f = fbo_obj(fbo);
    if (f)
        attach(f, attachment, tex, level, 0);
}

void glNamedFramebufferTextureLayer(GLuint fbo, GLenum attachment, GLuint tex, GLint level, GLint layer)
{
    mgl_framebuffer *f = fbo_obj(fbo);
    if (f)
        attach(f, attachment, tex, level, layer);
}

static void draw_buffers(mgl_framebuffer *f, GLsizei n, const GLenum *bufs)
{
    if (n > MGL_MAX_ATTACHMENTS)
        n = MGL_MAX_ATTACHMENTS;
    f->num_draw_buffers = n;
    for (GLsizei i = 0; i < n; i++)
        f->draw_buffers[i] = bufs[i];
}

void glDrawBuffers(GLsizei n, const GLenum *bufs)
{
    mgl_framebuffer *f = fbo_obj(mgl->draw_fbo);
    if (f)
        draw_buffers(f, n, bufs);
}

void glDrawBuffer(GLenum buf)
{
    mgl_framebuffer *f = fbo_obj(mgl->draw_fbo);
    if (f)
        draw_buffers(f, 1, &buf);
}

void glNamedFramebufferDrawBuffers(GLuint fbo, GLsizei n, const GLenum *bufs)
{
    mgl_framebuffer *f = fbo_obj(fbo);
    if (f)
        draw_buffers(f, n, bufs);
}

void glNamedFramebufferDrawBuffer(GLuint fbo, GLenum buf)
{
    mgl_framebuffer *f = fbo_obj(fbo);
    if (f)
        draw_buffers(f, 1, &buf);
}

void glReadBuffer(GLenum buf)
{
    mgl_framebuffer *f = fbo_obj(mgl->read_fbo);
    if (f)
        f->read_buffer = buf;
}

void glNamedFramebufferReadBuffer(GLuint fbo, GLenum buf)
{
    mgl_framebuffer *f = fbo_obj(fbo);
    if (f)
        f->read_buffer = buf;
}

static GLenum status_of(mgl_framebuffer *f)
{
    if (!f)
        return GL_FRAMEBUFFER_COMPLETE; /* framebuffer 0 */
    int any = 0, w = -1, h = -1;
    for (int i = 0; i < MGL_MAX_ATTACHMENTS + 1; i++) {
        mgl_attachment *a = i < MGL_MAX_ATTACHMENTS ? &f->color[i] : &f->depth;
        if (!a->tex_name)
            continue;
        a->tex = mgl_texture_obj(a->tex_name);
        if (!a->tex || !a->tex->mem)
            return GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
        int aw = a->tex->base_w >> a->level, ah = a->tex->base_h >> a->level;
        if (w < 0 || aw < w)
            w = aw;
        if (h < 0 || ah < h)
            h = ah;
        any = 1;
    }
    return any ? GL_FRAMEBUFFER_COMPLETE : GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT;
}

GLenum glCheckFramebufferStatus(GLenum target)
{
    GLuint name = target == GL_READ_FRAMEBUFFER ? mgl->read_fbo : mgl->draw_fbo;
    return status_of(fbo_obj(name));
}

GLenum glCheckNamedFramebufferStatus(GLuint fbo, GLenum target)
{
    return status_of(fbo_obj(fbo));
}

/* Describe what a draw into `fbo` writes. Colour slot i corresponds to fragment output location i
   (GL draw buffer i). Returns 0 if nothing usable is attached. */
int mgl_build_target(GLuint fbo, mgl_target *t)
{
    memset(t, 0, sizeof *t);
    if (!fbo) {
        int ww = 0, wh = 0;
        mglb_window_size(&ww, &wh);
        if (ww > 0 && wh > 0)
            mgl_window_resize(ww, wh);
        if (!mgl->window_color)
            return 0;
        t->tex[0] = mgl->window_color;
        t->depth = mgl->window_depth;
        t->width = mgl->window_w;
        t->height = mgl->window_h;
        t->is_default = 1;
        return 1;
    }
    mgl_framebuffer *f = fbo_obj(fbo);
    if (!f || status_of(f) != GL_FRAMEBUFFER_COMPLETE)
        return 0;
    int w = 1 << 30, h = 1 << 30;
    for (int i = 0; i < f->num_draw_buffers; i++) {
        GLenum b = f->draw_buffers[i];
        if (b < GL_COLOR_ATTACHMENT0 || b >= GL_COLOR_ATTACHMENT0 + MGL_MAX_ATTACHMENTS)
            continue;
        mgl_attachment *a = &f->color[b - GL_COLOR_ATTACHMENT0];
        if (!a->tex || !a->tex->mem)
            continue;
        t->tex[i] = a->tex->mem;
        t->level[i] = a->level;
        t->layer[i] = a->layer;
        int aw = a->tex->base_w >> a->level, ah = a->tex->base_h >> a->level;
        if (aw < w) w = aw;
        if (ah < h) h = ah;
    }
    if (f->depth.tex && f->depth.tex->mem) {
        t->depth = f->depth.tex->mem;
        t->depth_level = f->depth.level;
        int aw = f->depth.tex->base_w >> f->depth.level, ah = f->depth.tex->base_h >> f->depth.level;
        if (aw < w) w = aw;
        if (ah < h) h = ah;
    }
    if (w == 1 << 30) {
        /* only a read-side attachment; still give the colour attachment 0 for blits/copies */
        if (f->color[0].tex && f->color[0].tex->mem) {
            t->tex[0] = f->color[0].tex->mem;
            w = f->color[0].tex->base_w;
            h = f->color[0].tex->base_h;
        } else
            return 0;
    }
    t->width = w ? w : 1;
    t->height = h ? h : 1;
    return 1;
}

/* For reads and blits: the read framebuffer's selected colour attachment as slot 0. */
static int build_read_target(mgl_target *t)
{
    if (!mgl->read_fbo)
        return mgl_build_target(0, t);
    mgl_framebuffer *f = fbo_obj(mgl->read_fbo);
    if (!f || status_of(f) != GL_FRAMEBUFFER_COMPLETE)
        return 0;
    memset(t, 0, sizeof *t);
    GLenum rb = f->read_buffer;
    if (rb >= GL_COLOR_ATTACHMENT0 && rb < GL_COLOR_ATTACHMENT0 + MGL_MAX_ATTACHMENTS) {
        mgl_attachment *a = &f->color[rb - GL_COLOR_ATTACHMENT0];
        if (a->tex && a->tex->mem) {
            t->tex[0] = a->tex->mem;
            t->level[0] = a->level;
            t->width = a->tex->base_w >> a->level;
            t->height = a->tex->base_h >> a->level;
        }
    }
    if (f->depth.tex && f->depth.tex->mem) {
        t->depth = f->depth.tex->mem;
        if (!t->width) {
            t->width = f->depth.tex->base_w;
            t->height = f->depth.tex->base_h;
        }
    }
    return t->width > 0;
}

static uint8_t color_write_mask(void)
{
    return (uint8_t)((mgl->color_mask[0] ? 1 : 0) | (mgl->color_mask[1] ? 2 : 0) | (mgl->color_mask[2] ? 4 : 0) |
                     (mgl->color_mask[3] ? 8 : 0));
}

void glClear(GLbitfield mask)
{
    mgl_target t;
    if (!mgl_build_target(mgl->draw_fbo, &t))
        return;
    unsigned colors = 0;
    if (mask & GL_COLOR_BUFFER_BIT)
        for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++)
            if (t.tex[i])
                colors |= 1u << i;
    int depth = (mask & GL_DEPTH_BUFFER_BIT) && t.depth && mgl->depth_mask;
    if (!colors && !depth)
        return;
    mglb_clear(&t, colors, mgl->clear_color, depth, mgl->clear_depth, mgl->scissor_test ? mgl->scissor : NULL,
               color_write_mask());
}

void glClearBufferfv(GLenum buffer, GLint drawbuffer, const GLfloat *value)
{
    mgl_target t;
    if (!mgl_build_target(mgl->draw_fbo, &t))
        return;
    if (buffer == GL_COLOR && drawbuffer >= 0 && drawbuffer < MGL_MAX_ATTACHMENTS && t.tex[drawbuffer])
        mglb_clear(&t, 1u << drawbuffer, value, 0, 0, mgl->scissor_test ? mgl->scissor : NULL, color_write_mask());
    else if (buffer == GL_DEPTH && t.depth)
        mglb_clear(&t, 0, NULL, 1, value[0], mgl->scissor_test ? mgl->scissor : NULL, 0xf);
}

void glClearNamedFramebufferfv(GLuint fbo, GLenum buffer, GLint drawbuffer, const GLfloat *value)
{
    GLuint saved = mgl->draw_fbo;
    mgl->draw_fbo = fbo;
    glClearBufferfv(buffer, drawbuffer, value);
    mgl->draw_fbo = saved;
}

static void blit(GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0, GLint dy0, GLint dx1, GLint dy1,
                 GLbitfield mask, GLenum filter)
{
    mgl_target src, dst;
    if (!build_read_target(&src) || !mgl_build_target(mgl->draw_fbo, &dst))
        return;
    int s[4] = {sx0, sy0, sx1, sy1}, d[4] = {dx0, dy0, dx1, dy1};
    mglb_blit(&src, 0, s, &dst, d, (mask & GL_COLOR_BUFFER_BIT) != 0, (mask & GL_DEPTH_BUFFER_BIT) != 0,
              filter == GL_LINEAR);
}

void glBlitFramebuffer(GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0, GLint dy0, GLint dx1, GLint dy1,
                       GLbitfield mask, GLenum filter)
{
    blit(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
}

void glBlitNamedFramebuffer(GLuint read, GLuint draw, GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0, GLint dy0,
                            GLint dx1, GLint dy1, GLbitfield mask, GLenum filter)
{
    GLuint r = mgl->read_fbo, d = mgl->draw_fbo;
    mgl->read_fbo = read;
    mgl->draw_fbo = draw;
    blit(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
    mgl->read_fbo = r;
    mgl->draw_fbo = d;
}

void glGetFramebufferAttachmentParameteriv(GLenum target, GLenum attachment, GLenum pname, GLint *out)
{
    mgl_framebuffer *f = fbo_obj(target == GL_READ_FRAMEBUFFER ? mgl->read_fbo : mgl->draw_fbo);
    *out = 0;
    if (!f) {
        if (pname == GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE)
            *out = GL_FRAMEBUFFER_DEFAULT;
        return;
    }
    mgl_attachment *a = attachment == GL_DEPTH_ATTACHMENT ? &f->depth
                        : (attachment >= GL_COLOR_ATTACHMENT0 && attachment < GL_COLOR_ATTACHMENT0 + MGL_MAX_ATTACHMENTS)
                            ? &f->color[attachment - GL_COLOR_ATTACHMENT0] : NULL;
    if (!a)
        return;
    switch (pname) {
    case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: *out = a->tex_name ? GL_TEXTURE : GL_NONE; break;
    case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: *out = (GLint)a->tex_name; break;
    case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL: *out = a->level; break;
    }
}

/* ---- window framebuffer (called by the backend when the drawable size changes) ---- */
void mgl_window_resize(int w, int h)
{
    if (w == mgl->window_w && h == mgl->window_h && mgl->window_color)
        return;
    if (mgl->window_color)
        mglb_texture_release(mgl->window_color);
    if (mgl->window_depth)
        mglb_texture_release(mgl->window_depth);
    mglb_texture_desc d = {MGLT_2D, MGLF_RGBA8, w, h, 1, 1};
    mgl->window_color = mglb_texture_new(&d);
    d.format = MGLF_DEPTH32F;
    mgl->window_depth = mglb_texture_new(&d);
    mgl->window_w = w;
    mgl->window_h = h;
    if (!mgl->viewport[2]) {
        mgl->viewport[2] = w;
        mgl->viewport[3] = h;
    }
}
