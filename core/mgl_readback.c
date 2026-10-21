/* Reading pixels back: glReadPixels and glGetTexImage for 8-bit RGBA (what Minecraft's F2 screenshots and
   NativeImage downloads use), and mcmetal's own timed window screenshots (MGL_SHOT_DIR) for testing without
   any screen-capture permission. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "mgl_state.h"

static int is_rgba8(enum mgl_format f) { return f == MGLF_RGBA8 || f == MGLF_SRGB8_A8; }

/* tight RGBA8 rows from the texture, then GL packing (row length, alignment), RGBA or BGRA */
static void read_rgba8(mglb_texture *tex, int level, int x, int y, int w, int h, GLenum format, void *pixels)
{
    size_t tight = (size_t)w * 4;
    unsigned char *tmp = malloc(tight * (size_t)h);
    if (!tmp)
        return;
    mglb_texture_read(tex, level, x, y, w, h, tmp);
    int row_px = mgl->pack_row_length > 0 ? mgl->pack_row_length : w;
    int align = mgl->pack_alignment > 0 ? mgl->pack_alignment : 4;
    size_t stride = ((size_t)row_px * 4 + (size_t)align - 1) / (size_t)align * (size_t)align;
    for (int r = 0; r < h; r++) {
        unsigned char *dst = (unsigned char *)pixels + stride * (size_t)r, *src = tmp + tight * (size_t)r;
        if (format == GL_BGRA)
            for (int i = 0; i < w; i++) {
                dst[4 * i] = src[4 * i + 2];
                dst[4 * i + 1] = src[4 * i + 1];
                dst[4 * i + 2] = src[4 * i];
                dst[4 * i + 3] = src[4 * i + 3];
            }
        else
            memcpy(dst, src, tight);
    }
    free(tmp);
}

/* client pointer, or an offset into the bound GL_PIXEL_PACK_BUFFER */
static void *pack_dest(void *pixels)
{
    if (!mgl->pixel_pack_buffer)
        return pixels;
    mgl_buffer *b = mgl_table_get(&mgl->buffers, mgl->pixel_pack_buffer);
    return b && b->mem ? (char *)mglb_buffer_ptr(b->mem) + (size_t)pixels : NULL;
}

static int supported(GLenum format, GLenum type, const char *who)
{
    if ((format == GL_RGBA || format == GL_BGRA) && (type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_INT_8_8_8_8_REV))
        return 1;
    static int warned;
    if (warned++ < 5)
        mgl_log("%s: format 0x%x type 0x%x not supported yet", who, format, type);
    return 0;
}

void glReadPixels(GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type, void *pixels)
{
    if (w <= 0 || h <= 0 || !supported(format, type, "glReadPixels"))
        return;
    mgl_target t;
    if (!mgl_build_target(mgl->read_fbo, &t))
        return;
    int att = 0;
    if (!t.is_default) {
        mgl_framebuffer *f = mgl_table_get(&mgl->framebuffers, mgl->read_fbo);
        if (f && f->read_buffer >= GL_COLOR_ATTACHMENT0 && f->read_buffer < GL_COLOR_ATTACHMENT0 + MGL_MAX_ATTACHMENTS)
            att = (int)(f->read_buffer - GL_COLOR_ATTACHMENT0);
    }
    mglb_texture *tex = t.tex[att];
    void *dst = pack_dest(pixels);
    if (!tex || !dst)
        return;
    if (!is_rgba8(mglb_texture_format(tex))) {
        static int warned;
        if (!warned++)
            mgl_log("glReadPixels: only 8-bit RGBA framebuffers can be read yet");
        return;
    }
    read_rgba8(tex, t.level[att], x, y, w, h, format, dst);
}

void glGetTexImage(GLenum target, GLint level, GLenum format, GLenum type, void *pixels)
{
    if (target != GL_TEXTURE_2D || !supported(format, type, "glGetTexImage"))
        return;
    GLuint *slot = mgl_bound_texture_slot(target);
    mgl_texture *t = slot ? mgl_texture_obj(*slot) : NULL;
    void *dst = pack_dest(pixels);
    if (!t || !t->mem || !dst || !is_rgba8(t->desc.format))
        return;
    int w = t->desc.width >> level, h = t->desc.height >> level;
    read_rgba8(t->mem, level, 0, 0, w < 1 ? 1 : w, h < 1 ? 1 : h, format, dst);
}

/* ---- PNG writer (stored deflate blocks: no zlib needed, files are just bigger) ---- */

static unsigned crc_table[256];
static unsigned crc(unsigned c, const unsigned char *p, size_t n)
{
    if (!crc_table[1])
        for (unsigned i = 0; i < 256; i++) {
            unsigned v = i;
            for (int k = 0; k < 8; k++)
                v = v & 1 ? 0xEDB88320u ^ (v >> 1) : v >> 1;
            crc_table[i] = v;
        }
    c = ~c;
    while (n--)
        c = crc_table[(c ^ *p++) & 255] ^ (c >> 8);
    return ~c;
}

static void put32(unsigned char *p, unsigned v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static void chunk(FILE *f, const char *type, const unsigned char *data, size_t n)
{
    unsigned char hdr[8];
    put32(hdr, (unsigned)n);
    memcpy(hdr + 4, type, 4);
    fwrite(hdr, 1, 8, f);
    fwrite(data, 1, n, f);
    unsigned c = crc(crc(0, hdr + 4, 4), data, n);
    put32(hdr, c);
    fwrite(hdr, 1, 4, f);
}

/* rgba rows bottom-up (GL order); the file is written top-down */
int mgl_write_png(const char *path, const unsigned char *rgba, int w, int h)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        return 0;
    fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
    unsigned char ihdr[13];
    put32(ihdr, (unsigned)w);
    put32(ihdr + 4, (unsigned)h);
    ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = ihdr[11] = ihdr[12] = 0; /* 8-bit RGBA */
    chunk(f, "IHDR", ihdr, 13);
    size_t row = (size_t)w * 4 + 1, raw_n = row * (size_t)h;
    unsigned char *raw = malloc(raw_n);
    for (int y = 0; y < h; y++) {
        raw[row * (size_t)y] = 0; /* filter: none */
        memcpy(raw + row * (size_t)y + 1, rgba + (size_t)w * 4 * (size_t)(h - 1 - y), (size_t)w * 4);
        for (int x = 0; x < w; x++)
            raw[row * (size_t)y + 1 + 4 * (size_t)x + 3] = 255; /* the window has no meaningful alpha */
    }
    size_t blocks = (raw_n + 65534) / 65535, z_n = 2 + raw_n + blocks * 5 + 4;
    unsigned char *z = malloc(z_n), *p = z;
    *p++ = 0x78; *p++ = 0x01;
    unsigned a = 1, b = 0;
    for (size_t off = 0; off < raw_n; off += 65535) {
        size_t n = raw_n - off < 65535 ? raw_n - off : 65535;
        *p++ = off + n == raw_n;
        *p++ = (unsigned char)n; *p++ = (unsigned char)(n >> 8);
        *p++ = (unsigned char)~n; *p++ = (unsigned char)(~n >> 8);
        memcpy(p, raw + off, n);
        p += n;
        for (size_t i = 0; i < n; i++) {
            a = (a + raw[off + i]) % 65521;
            b = (b + a) % 65521;
        }
    }
    put32(p, b << 16 | a);
    chunk(f, "IDAT", z, z_n);
    chunk(f, "IEND", NULL, 0);
    free(raw);
    free(z);
    int ok = !ferror(f);
    fclose(f);
    return ok;
}

/* MGL_SHOT_DIR=dir: save the window every MGL_SHOT_EVERY seconds (default 10) as dir/shot-NNN.png.
   MGL_SHOT_EVERY=0: only when the file dir/shoot appears (it is then deleted), so benchmarks aren't
   interrupted: each shot waits for the GPU. Called by the backend just before it presents a frame. */
void mgl_shot_tick(void)
{
    static const char *dir;
    static int init, n;
    static double every, next;
    static char trigger[1024];
    if (!init) {
        init = 1;
        dir = getenv("MGL_SHOT_DIR");
        const char *e = getenv("MGL_SHOT_EVERY");
        every = e ? atof(e) : 10;
        if (every < 0)
            every = 10;
        if (dir)
            snprintf(trigger, sizeof trigger, "%s/shoot", dir);
    }
    if (!dir || !*dir || !mgl->window_color)
        return;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = ts.tv_sec + ts.tv_nsec * 1e-9;
    if (!next)
        next = now + 2; /* first one shortly after the first frame */
    if (now < next)
        return;
    if (every == 0) { /* on demand: look for the trigger file twice a second */
        next = now + 0.5;
        if (remove(trigger) != 0)
            return;
    } else {
        next = now + every;
    }
    int w = mgl->window_w, h = mgl->window_h;
    unsigned char *px = malloc((size_t)w * (size_t)h * 4);
    if (!px)
        return;
    mglb_texture_read(mgl->window_color, 0, 0, 0, w, h, px);
    char path[1024];
    snprintf(path, sizeof path, "%s/shot-%03d.png", dir, n++);
    if (mgl_write_png(path, px, w, h))
        mgl_log("screenshot %s (%dx%d)", path, w, h);
    free(px);
    if (mglb_upscaled_read(&px, &w, &h)) { /* MCMETAL_UPSCALE: also the frame as shown, after MetalFX */
        snprintf(path, sizeof path, "%s/shot-%03d-up.png", dir, n - 1);
        if (mgl_write_png(path, px, w, h))
            mgl_log("screenshot %s (%dx%d)", path, w, h);
        free(px);
    }
}
