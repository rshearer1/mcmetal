/* Textures, samplers, image units, pixel upload conversion. */
#include <math.h>
#include <string.h>
#include "mgl_state.h"

/* ---------------------------------------------------------------- formats */

typedef struct fmt_info {
    int bpt;            /* bytes per texel in the backend */
    int comps;          /* components stored */
    int kind;           /* 0 unorm8, 1 snorm8, 2 half, 3 float, 4 uint16, 5 uint32, 6 uint8, 7 unorm16, 8 int32, 9 depth32f, 10 packed */
} fmt_info;

static const fmt_info finfo[MGLF_COUNT] = {
    [MGLF_RGBA8] = {4, 4, 0}, [MGLF_SRGB8_A8] = {4, 4, 0}, [MGLF_RGBA8_SNORM] = {4, 4, 1}, [MGLF_R8] = {1, 1, 0},
    [MGLF_RG8] = {2, 2, 0}, [MGLF_RGBA16F] = {8, 4, 2}, [MGLF_R16F] = {2, 1, 2}, [MGLF_RG16F] = {4, 2, 2},
    [MGLF_R32F] = {4, 1, 3}, [MGLF_RG32F] = {8, 2, 3}, [MGLF_RGBA32F] = {16, 4, 3}, [MGLF_R11G11B10F] = {4, 3, 10},
    [MGLF_RGB10A2] = {4, 4, 10}, [MGLF_R16UI] = {2, 1, 4}, [MGLF_R32UI] = {4, 1, 5}, [MGLF_RGBA16] = {8, 4, 7},
    [MGLF_R16] = {2, 1, 7}, [MGLF_RG16] = {4, 2, 7}, [MGLF_RGBA8UI] = {4, 4, 6}, [MGLF_R8UI] = {1, 1, 6},
    [MGLF_RGBA16UI] = {8, 4, 4}, [MGLF_RGBA32UI] = {16, 4, 5}, [MGLF_R32I] = {4, 1, 8}, [MGLF_DEPTH32F] = {4, 1, 9},
    [MGLF_DEPTH16] = {2, 1, 7}, [MGLF_DEPTH24_STENCIL8] = {4, 1, 10}, [MGLF_DEPTH32F_STENCIL8] = {8, 1, 10},
    [MGLF_RGBA16I] = {8, 4, 4}, [MGLF_RGBA32I] = {16, 4, 8}, [MGLF_RG32UI] = {8, 2, 5},
};

enum mgl_format mgl_format_from_internal(GLenum internal, int *bpt)
{
    enum mgl_format f;
    switch (internal) {
    case GL_RGBA: case GL_RGBA8: case GL_RGB: case GL_RGB8: case 4: case 3: f = MGLF_RGBA8; break;
    case GL_SRGB8_ALPHA8: case GL_SRGB8: f = MGLF_SRGB8_A8; break;
    case GL_RGBA8_SNORM: case GL_RGB8_SNORM: f = MGLF_RGBA8_SNORM; break;
    case GL_RED: case GL_R8: case 1: f = MGLF_R8; break;
    case GL_RG: case GL_RG8: case 2: f = MGLF_RG8; break;
    case GL_RGBA16F: case GL_RGB16F: f = MGLF_RGBA16F; break;
    case GL_R16F: f = MGLF_R16F; break;
    case GL_RG16F: f = MGLF_RG16F; break;
    case GL_R32F: f = MGLF_R32F; break;
    case GL_RG32F: f = MGLF_RG32F; break;
    case GL_RGBA32F: case GL_RGB32F: f = MGLF_RGBA32F; break;
    case GL_R11F_G11F_B10F: f = MGLF_R11G11B10F; break;
    case GL_RGB10_A2: f = MGLF_RGB10A2; break;
    case GL_R16UI: f = MGLF_R16UI; break;
    case GL_R32UI: f = MGLF_R32UI; break;
    case GL_R32I: f = MGLF_R32I; break;
    case GL_RGBA16: case GL_RGB16: f = MGLF_RGBA16; break;
    case GL_R16: f = MGLF_R16; break;
    case GL_RG16: f = MGLF_RG16; break;
    case GL_RGBA8UI: f = MGLF_RGBA8UI; break;
    case GL_R8UI: f = MGLF_R8UI; break;
    case GL_RGBA16UI: f = MGLF_RGBA16UI; break;
    case GL_RGBA16I: f = MGLF_RGBA16I; break;
    case GL_RGBA32I: f = MGLF_RGBA32I; break;
    case GL_RG32UI: f = MGLF_RG32UI; break;
    case GL_RGBA32UI: f = MGLF_RGBA32UI; break;
    case GL_DEPTH_COMPONENT: case GL_DEPTH_COMPONENT24: case GL_DEPTH_COMPONENT32: case GL_DEPTH_COMPONENT32F:
        f = MGLF_DEPTH32F; break;
    case GL_DEPTH_COMPONENT16: f = MGLF_DEPTH16; break;
    case GL_DEPTH_STENCIL: case GL_DEPTH24_STENCIL8: f = MGLF_DEPTH24_STENCIL8; break;
    case GL_DEPTH32F_STENCIL8: f = MGLF_DEPTH32F_STENCIL8; break;
    default:
        mgl_log("internal format 0x%04X not supported, using RGBA8", internal);
        f = MGLF_RGBA8;
    }
    if (bpt)
        *bpt = finfo[f].bpt;
    return f;
}

/* ---------------------------------------------------------------- texel conversion */

static uint16_t f2h(float f)
{
    union { float f; uint32_t u; } v = {f};
    uint32_t sign = (v.u >> 16) & 0x8000, exp = (v.u >> 23) & 0xff, man = v.u & 0x7fffff;
    if (exp == 0xff)
        return (uint16_t)(sign | 0x7c00 | (man ? 0x200 : 0));
    int e = (int)exp - 127 + 15;
    if (e >= 31)
        return (uint16_t)(sign | 0x7c00);
    if (e <= 0) {
        if (e < -10)
            return (uint16_t)sign;
        man |= 0x800000;
        return (uint16_t)(sign | (man >> (14 - e)));
    }
    return (uint16_t)(sign | ((uint32_t)e << 10) | (man >> 13));
}

static float h2f(uint16_t h)
{
    uint32_t sign = (uint32_t)(h & 0x8000) << 16, exp = (h >> 10) & 0x1f, man = h & 0x3ff, u;
    if (exp == 0)
        u = man ? (sign | ((uint32_t)(127 - 15 + 1) << 23)) : sign; /* denormals approximated */
    else if (exp == 31)
        u = sign | 0x7f800000 | (man << 13);
    else
        u = sign | ((exp - 15 + 127) << 23) | (man << 13);
    union { uint32_t u; float f; } v = {u};
    if (exp == 0 && man)
        return (sign ? -1.0f : 1.0f) * (float)man / 1024.0f / 16384.0f;
    return v.f;
}

static int comps_of(GLenum format)
{
    switch (format) {
    case GL_RED: case GL_RED_INTEGER: case GL_DEPTH_COMPONENT: case GL_ALPHA: return 1;
    case GL_RG: case GL_RG_INTEGER: case GL_DEPTH_STENCIL: return 2;
    case GL_RGB: case GL_BGR: case GL_RGB_INTEGER: return 3;
    default: return 4;
    }
}

static int type_size(GLenum type)
{
    switch (type) {
    case GL_UNSIGNED_BYTE: case GL_BYTE: return 1;
    case GL_UNSIGNED_SHORT: case GL_SHORT: case GL_HALF_FLOAT: return 2;
    case GL_UNSIGNED_INT_8_8_8_8: case GL_UNSIGNED_INT_8_8_8_8_REV: case GL_UNSIGNED_INT_2_10_10_10_REV:
    case GL_UNSIGNED_INT_24_8: case GL_UNSIGNED_INT_10F_11F_11F_REV:
        return -4; /* packed: whole pixel */
    default: return 4;
    }
}

static int pixel_size(GLenum format, GLenum type)
{
    int t = type_size(type);
    return t < 0 ? -t : t * comps_of(format);
}

/* read component c of a source pixel as float (normalized types) or as raw integer value in *iv */
static void read_pixel(const unsigned char *p, GLenum format, GLenum type, float out[4], uint32_t iout[4])
{
    int n = comps_of(format);
    float v[4] = {0, 0, 0, 1};
    uint32_t iv[4] = {0, 0, 0, 1};
    if (type == GL_UNSIGNED_INT_8_8_8_8_REV) {
        uint32_t x;
        memcpy(&x, p, 4);
        for (int c = 0; c < 4; c++) {
            iv[c] = (x >> (8 * c)) & 0xff;
            v[c] = (float)iv[c] / 255.0f;
        }
    } else if (type == GL_UNSIGNED_INT_8_8_8_8) {
        uint32_t x;
        memcpy(&x, p, 4);
        for (int c = 0; c < 4; c++) {
            iv[c] = (x >> (24 - 8 * c)) & 0xff;
            v[c] = (float)iv[c] / 255.0f;
        }
    } else {
        for (int c = 0; c < n; c++) {
            switch (type) {
            case GL_UNSIGNED_BYTE: iv[c] = p[c]; v[c] = p[c] / 255.0f; break;
            case GL_BYTE: iv[c] = (uint32_t)(int8_t)p[c]; v[c] = fmaxf((int8_t)p[c] / 127.0f, -1.0f); break;
            case GL_UNSIGNED_SHORT: { uint16_t s; memcpy(&s, p + 2 * c, 2); iv[c] = s; v[c] = s / 65535.0f; break; }
            case GL_SHORT: { int16_t s; memcpy(&s, p + 2 * c, 2); iv[c] = (uint32_t)s; v[c] = fmaxf(s / 32767.0f, -1.0f); break; }
            case GL_HALF_FLOAT: { uint16_t s; memcpy(&s, p + 2 * c, 2); v[c] = h2f(s); iv[c] = (uint32_t)v[c]; break; }
            case GL_FLOAT: memcpy(&v[c], p + 4 * c, 4); iv[c] = (uint32_t)v[c]; break;
            case GL_UNSIGNED_INT: case GL_INT: memcpy(&iv[c], p + 4 * c, 4); v[c] = (float)iv[c] / 4294967295.0f; break;
            default: break;
            }
        }
    }
    if (format == GL_BGRA || format == GL_BGR) {
        float t = v[0]; v[0] = v[2]; v[2] = t;
        uint32_t ti = iv[0]; iv[0] = iv[2]; iv[2] = ti;
    }
    if (format == GL_ALPHA) {
        v[3] = v[0]; v[0] = v[1] = v[2] = 0;
    }
    memcpy(out, v, sizeof v);
    memcpy(iout, iv, sizeof iv);
}

static float clamp01(float x) { return x < 0 ? 0 : x > 1 ? 1 : x; }

static void write_texel(unsigned char *d, enum mgl_format f, const float v[4], const uint32_t iv[4])
{
    const fmt_info *fi = &finfo[f];
    switch (fi->kind) {
    case 0: for (int c = 0; c < fi->comps; c++) d[c] = (unsigned char)lrintf(clamp01(v[c]) * 255.0f); break;
    case 1: for (int c = 0; c < fi->comps; c++) d[c] = (unsigned char)(int8_t)lrintf(fmaxf(-1, fminf(1, v[c])) * 127.0f); break;
    case 2: for (int c = 0; c < fi->comps; c++) { uint16_t h = f2h(v[c]); memcpy(d + 2 * c, &h, 2); } break;
    case 3: case 9: memcpy(d, v, 4 * (size_t)fi->comps); break;
    case 4: for (int c = 0; c < fi->comps; c++) { uint16_t s = (uint16_t)iv[c]; memcpy(d + 2 * c, &s, 2); } break;
    case 5: case 8: memcpy(d, iv, 4 * (size_t)fi->comps); break;
    case 6: for (int c = 0; c < fi->comps; c++) d[c] = (unsigned char)iv[c]; break;
    case 7: for (int c = 0; c < fi->comps; c++) { uint16_t s = (uint16_t)lrintf(clamp01(v[c]) * 65535.0f); memcpy(d + 2 * c, &s, 2); } break;
    default: memset(d, 0, (size_t)fi->bpt); break; /* packed float/depth-stencil uploads: not seen in Minecraft */
    }
}

/* Same layout already? Then rows can be copied as-is. */
static int direct_match(enum mgl_format f, GLenum format, GLenum type)
{
    switch (f) {
    case MGLF_RGBA8: case MGLF_SRGB8_A8:
        return format == GL_RGBA && (type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_INT_8_8_8_8_REV);
    case MGLF_R8: return format == GL_RED && type == GL_UNSIGNED_BYTE;
    case MGLF_RG8: return format == GL_RG && type == GL_UNSIGNED_BYTE;
    case MGLF_RGBA16F: return format == GL_RGBA && type == GL_HALF_FLOAT;
    case MGLF_R32F: case MGLF_DEPTH32F: return (format == GL_RED || format == GL_DEPTH_COMPONENT) && type == GL_FLOAT;
    case MGLF_RGBA32F: return format == GL_RGBA && type == GL_FLOAT;
    case MGLF_R16UI: return format == GL_RED_INTEGER && type == GL_UNSIGNED_SHORT;
    case MGLF_R32UI: return format == GL_RED_INTEGER && type == GL_UNSIGNED_INT;
    default: return 0;
    }
}

/* Convert GL client pixels (with unpack state applied) into a tight buffer in the texture's format.
   Returns malloc'd data, or (when no conversion is needed) a pointer into src with the row and image strides. */
static const void *prepare_pixels(enum mgl_format f, int w, int h, int d, GLenum format, GLenum type,
                                  const void *src, size_t *row, size_t *image, void **to_free)
{
    int ps = pixel_size(format, type);
    int row_len = mgl->unpack_row_length ? mgl->unpack_row_length : w;
    int img_h = mgl->unpack_image_height ? mgl->unpack_image_height : h;
    size_t align = (size_t)(mgl->unpack_alignment ? mgl->unpack_alignment : 1);
    size_t src_row = ((size_t)row_len * (size_t)ps + align - 1) / align * align;
    size_t src_img = src_row * (size_t)img_h;
    const unsigned char *base = (const unsigned char *)src + (size_t)mgl->unpack_skip_images * src_img +
                                (size_t)mgl->unpack_skip_rows * src_row + (size_t)mgl->unpack_skip_pixels * (size_t)ps;
    *to_free = NULL;
    if (direct_match(f, format, type)) {
        *row = src_row;
        *image = src_img;
        return base;
    }
    size_t bpt = (size_t)finfo[f].bpt;
    unsigned char *out = malloc(bpt * (size_t)w * (size_t)h * (size_t)d);
    for (int z = 0; z < d; z++)
        for (int y = 0; y < h; y++) {
            const unsigned char *s = base + (size_t)z * src_img + (size_t)y * src_row;
            unsigned char *o = out + (((size_t)z * (size_t)h + (size_t)y) * (size_t)w) * bpt;
            for (int x = 0; x < w; x++) {
                float v[4];
                uint32_t iv[4];
                read_pixel(s + (size_t)x * (size_t)ps, format, type, v, iv);
                write_texel(o + (size_t)x * bpt, f, v, iv);
            }
        }
    *row = bpt * (size_t)w;
    *image = *row * (size_t)h;
    *to_free = out;
    return out;
}

/* ---------------------------------------------------------------- objects and binding */

int mgl_tex_target_index(GLenum target)
{
    switch (target) {
    case GL_TEXTURE_2D:
    case GL_TEXTURE_1D: return 0; /* 1D textures are Nx1 2D ones (shaders: SPIRV-Cross texture_1D_as_2D) */
    case GL_TEXTURE_3D: return 1;
    case GL_TEXTURE_2D_ARRAY: return 2;
    case GL_TEXTURE_CUBE_MAP: return 3;
    }
    if (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)
        return 3;
    return -1;
}

GLuint *mgl_bound_texture_slot(GLenum target)
{
    int i = mgl_tex_target_index(target);
    return i < 0 ? NULL : &mgl->bound_tex[mgl->active_unit][i];
}

void mgl_sampler_defaults(mgl_sampler_state *s)
{
    s->min_filter = GL_NEAREST_MIPMAP_LINEAR;
    s->mag_filter = GL_LINEAR;
    s->wrap_s = s->wrap_t = s->wrap_r = GL_REPEAT;
    s->compare_mode = GL_NONE;
    s->compare_func = GL_LEQUAL;
    s->min_lod = -1000.0f;
    s->max_lod = 1000.0f;
    s->lod_bias = 0;
    s->max_anisotropy = 1;
}

static mgl_texture *new_texture(GLenum target)
{
    mgl_texture *t = calloc(1, sizeof *t);
    t->target = target;
    t->max_level = 1000;
    mgl_sampler_defaults(&t->sampler);
    return t;
}

mgl_texture *mgl_texture_obj(GLuint name)
{
    return mgl_table_get(&mgl->textures, name);
}

void glGenTextures(GLsizei n, GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        names[i] = mgl_table_gen(&mgl->textures);
        mgl_table_set(&mgl->textures, names[i], new_texture(0));
    }
}

void glCreateTextures(GLenum target, GLsizei n, GLuint *names)
{
    glGenTextures(n, names);
    for (GLsizei i = 0; i < n; i++)
        mgl_texture_obj(names[i])->target = target;
}

void glDeleteTextures(GLsizei n, const GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        mgl_texture *t = mgl_texture_obj(names[i]);
        if (!t)
            continue;
        if (t->mem)
            mglb_texture_release(t->mem);
        free(t);
        mgl_table_remove(&mgl->textures, names[i]);
        for (int u = 0; u < MGL_MAX_UNITS; u++)
            for (int k = 0; k < 4; k++)
                if (mgl->bound_tex[u][k] == names[i])
                    mgl->bound_tex[u][k] = 0;
    }
}

GLboolean glIsTexture(GLuint name) { return mgl_texture_obj(name) != NULL; }

void glActiveTexture(GLenum unit)
{
    GLuint u = unit - GL_TEXTURE0;
    if (u >= MGL_MAX_UNITS) {
        mgl_set_error(GL_INVALID_ENUM);
        return;
    }
    mgl->active_unit = u;
}

void glBindTexture(GLenum target, GLuint name)
{
    GLuint *slot = mgl_bound_texture_slot(target);
    if (!slot) {
        mgl_log("glBindTexture: target 0x%04X not supported", target);
        return;
    }
    if (name) {
        mgl_texture *t = mgl_texture_obj(name);
        if (!t) {
            t = new_texture(target);
            mgl_table_set(&mgl->textures, name, t);
        }
        if (!t->target)
            t->target = target;
    }
    *slot = name;
}

void glBindTextureUnit(GLuint unit, GLuint name)
{
    if (unit >= MGL_MAX_UNITS)
        return;
    mgl_texture *t = mgl_texture_obj(name);
    int idx = t ? mgl_tex_target_index(t->target ? t->target : GL_TEXTURE_2D) : -1;
    if (!name) {
        for (int k = 0; k < 4; k++)
            mgl->bound_tex[unit][k] = 0;
        return;
    }
    if (idx >= 0)
        mgl->bound_tex[unit][idx] = name;
}

void glBindTextures(GLuint first, GLsizei count, const GLuint *names)
{
    for (GLsizei i = 0; i < count; i++)
        glBindTextureUnit(first + (GLuint)i, names ? names[i] : 0);
}

static mgl_texture *bound_tex(GLenum target)
{
    GLuint *slot = mgl_bound_texture_slot(target);
    mgl_texture *t = slot ? mgl_texture_obj(*slot) : NULL;
    if (!t)
        mgl_set_error(GL_INVALID_OPERATION);
    return t;
}

/* ---------------------------------------------------------------- storage and upload */

static int full_levels(int w, int h, int d)
{
    int m = w > h ? w : h;
    if (d > m)
        m = d;
    int n = 1;
    while (m > 1) {
        m >>= 1;
        n++;
    }
    return n;
}

static enum mgl_tex_type tex_type(GLenum target)
{
    switch (target) {
    case GL_TEXTURE_3D: return MGLT_3D;
    case GL_TEXTURE_2D_ARRAY: return MGLT_2D_ARRAY;
    case GL_TEXTURE_CUBE_MAP: return MGLT_CUBE;
    default: return MGLT_2D;
    }
}

/* (Re)create backend storage when level 0's size or format changes. */
static void define_storage(mgl_texture *t, GLenum internal, int w, int h, int d, int levels)
{
    enum mgl_format f = mgl_format_from_internal(internal, NULL);
    GLenum target = t->target ? t->target : GL_TEXTURE_2D;
    int want = levels ? levels : (t->max_level < 1000 ? t->max_level + 1 : full_levels(w, h, d));
    int maxl = full_levels(w, h, target == GL_TEXTURE_3D ? d : 1);
    if (want > maxl)
        want = maxl;
    if (want < 1)
        want = 1;
    if (t->mem && t->desc.format == f && t->desc.width == w && t->desc.height == h && t->desc.depth == d &&
        t->desc.levels >= want)
        return;
    if (t->mem)
        mglb_texture_release(t->mem);
    t->desc.type = tex_type(target);
    t->desc.format = f;
    t->desc.width = w;
    t->desc.height = h;
    t->desc.depth = d;
    t->desc.levels = want;
    t->internal_format = internal;
    t->base_w = w;
    t->base_h = h;
    t->base_d = d;
    t->mem = mglb_texture_new(&t->desc);
}

static const void *unpack_source(const void *pixels)
{
    if (mgl->pixel_unpack_buffer) {
        mgl_buffer *b = mgl_buffer_obj(mgl->pixel_unpack_buffer);
        return b && b->mem ? (const char *)mglb_buffer_ptr(b->mem) + (size_t)pixels : NULL;
    }
    return pixels;
}

static void upload(mgl_texture *t, int level, int x, int y, int z, int w, int h, int d, GLenum format, GLenum type,
                   const void *pixels)
{
    const void *src = unpack_source(pixels);
    if (!src || !t->mem || w <= 0 || h <= 0 || d <= 0 || level >= t->desc.levels)
        return;
    size_t row, image;
    void *tmp;
    const void *data = prepare_pixels(t->desc.format, w, h, d, format, type, src, &row, &image, &tmp);
    mglb_texture_upload(t->mem, level, x, y, z, w, h, d, data, row, image);
    free(tmp);
}

static int proxy_w, proxy_h;

void glTexImage2D(GLenum target, GLint level, GLint internal, GLsizei w, GLsizei h, GLint border, GLenum format,
                  GLenum type, const void *pixels)
{
    if (target == GL_PROXY_TEXTURE_2D) {
        int ok = w <= 16384 && h <= 16384;
        proxy_w = ok ? w : 0;
        proxy_h = ok ? h : 0;
        return;
    }
    mgl_texture *t = bound_tex(target);
    if (!t)
        return;
    int face = target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z
                   ? (int)(target - GL_TEXTURE_CUBE_MAP_POSITIVE_X) : 0;
    if (level == 0)
        define_storage(t, (GLenum)internal, w, h, t->target == GL_TEXTURE_CUBE_MAP ? 6 : 1, 0);
    else if (!t->mem)
        return;
    t->level_defined |= 1 << level;
    if (pixels || mgl->pixel_unpack_buffer)
        upload(t, level, 0, 0, face, w, h, 1, format, type, pixels);
}

void glTexImage3D(GLenum target, GLint level, GLint internal, GLsizei w, GLsizei h, GLsizei d, GLint border,
                  GLenum format, GLenum type, const void *pixels)
{
    mgl_texture *t = bound_tex(target);
    if (!t)
        return;
    if (level == 0)
        define_storage(t, (GLenum)internal, w, h, d, 0);
    t->level_defined |= 1 << level;
    if (pixels || mgl->pixel_unpack_buffer)
        upload(t, level, 0, 0, 0, w, h, d, format, type, pixels);
}

void glTexStorage2D(GLenum target, GLsizei levels, GLenum internal, GLsizei w, GLsizei h)
{
    mgl_texture *t = bound_tex(target);
    if (t)
        define_storage(t, internal, w, h, target == GL_TEXTURE_CUBE_MAP ? 6 : 1, levels);
}

void glTexStorage3D(GLenum target, GLsizei levels, GLenum internal, GLsizei w, GLsizei h, GLsizei d)
{
    mgl_texture *t = bound_tex(target);
    if (t)
        define_storage(t, internal, w, h, d, levels);
}

void glTextureStorage2D(GLuint name, GLsizei levels, GLenum internal, GLsizei w, GLsizei h)
{
    mgl_texture *t = mgl_texture_obj(name);
    if (t)
        define_storage(t, internal, w, h, t->target == GL_TEXTURE_CUBE_MAP ? 6 : 1, levels);
}

void glTextureStorage3D(GLuint name, GLsizei levels, GLenum internal, GLsizei w, GLsizei h, GLsizei d)
{
    mgl_texture *t = mgl_texture_obj(name);
    if (t)
        define_storage(t, internal, w, h, d, levels);
}

void glTexSubImage2D(GLenum target, GLint level, GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type,
                     const void *pixels)
{
    mgl_texture *t = bound_tex(target);
    int face = target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z
                   ? (int)(target - GL_TEXTURE_CUBE_MAP_POSITIVE_X) : 0;
    if (t)
        upload(t, level, x, y, face, w, h, 1, format, type, pixels);
}

void glTexSubImage3D(GLenum target, GLint level, GLint x, GLint y, GLint z, GLsizei w, GLsizei h, GLsizei d,
                     GLenum format, GLenum type, const void *pixels)
{
    mgl_texture *t = bound_tex(target);
    if (t)
        upload(t, level, x, y, z, w, h, d, format, type, pixels);
}

void glTextureSubImage2D(GLuint name, GLint level, GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type,
                         const void *pixels)
{
    mgl_texture *t = mgl_texture_obj(name);
    if (t)
        upload(t, level, x, y, 0, w, h, 1, format, type, pixels);
}

void glTextureSubImage3D(GLuint name, GLint level, GLint x, GLint y, GLint z, GLsizei w, GLsizei h, GLsizei d,
                         GLenum format, GLenum type, const void *pixels)
{
    mgl_texture *t = mgl_texture_obj(name);
    if (t)
        upload(t, level, x, y, z, w, h, d, format, type, pixels);
}

/* ---------------------------------------------------------------- parameters */

static void set_param(mgl_sampler_state *s, mgl_texture *t, GLenum pname, float fv, int iv)
{
    switch (pname) {
    case GL_TEXTURE_MIN_FILTER: s->min_filter = iv; break;
    case GL_TEXTURE_MAG_FILTER: s->mag_filter = iv; break;
    case GL_TEXTURE_WRAP_S: s->wrap_s = iv; break;
    case GL_TEXTURE_WRAP_T: s->wrap_t = iv; break;
    case GL_TEXTURE_WRAP_R: s->wrap_r = iv; break;
    case GL_TEXTURE_COMPARE_MODE: s->compare_mode = iv; break;
    case GL_TEXTURE_COMPARE_FUNC: s->compare_func = iv; break;
    case GL_TEXTURE_MIN_LOD: s->min_lod = fv; break;
    case GL_TEXTURE_MAX_LOD: s->max_lod = fv; break;
    case GL_TEXTURE_LOD_BIAS: s->lod_bias = fv; break;
    case GL_TEXTURE_MAX_ANISOTROPY: s->max_anisotropy = iv < 1 ? 1 : iv > 16 ? 16 : iv; break;
    case GL_TEXTURE_MAX_LEVEL: if (t) t->max_level = iv; break;
    case GL_TEXTURE_BASE_LEVEL: if (iv) mgl_log("GL_TEXTURE_BASE_LEVEL %d ignored", iv); break;
    case GL_TEXTURE_SWIZZLE_R: case GL_TEXTURE_SWIZZLE_G: case GL_TEXTURE_SWIZZLE_B: case GL_TEXTURE_SWIZZLE_A:
        if (t) {
            if (!t->has_swizzle) {
                t->has_swizzle = 1;
                t->swizzle[0] = GL_RED; t->swizzle[1] = GL_GREEN; t->swizzle[2] = GL_BLUE; t->swizzle[3] = GL_ALPHA;
            }
            t->swizzle[pname - GL_TEXTURE_SWIZZLE_R] = iv;
        }
        break;
    default: mgl_log("texture parameter 0x%04X ignored", pname);
    }
}

static mgl_texture *named(GLuint name) { return mgl_texture_obj(name); }

void glTexParameteri(GLenum target, GLenum pname, GLint v)
{
    mgl_texture *t = bound_tex(target);
    if (t)
        set_param(&t->sampler, t, pname, (float)v, v);
}

void glTexParameterf(GLenum target, GLenum pname, GLfloat v)
{
    mgl_texture *t = bound_tex(target);
    if (t)
        set_param(&t->sampler, t, pname, v, (int)v);
}

void glTexParameteriv(GLenum target, GLenum pname, const GLint *v)
{
    if (pname == GL_TEXTURE_SWIZZLE_RGBA) {
        for (int i = 0; i < 4; i++)
            glTexParameteri(target, GL_TEXTURE_SWIZZLE_R + i, v[i]);
        return;
    }
    glTexParameteri(target, pname, v[0]);
}
void glTexParameterIiv(GLenum target, GLenum pname, const GLint *v) { glTexParameteriv(target, pname, v); }
void glTexParameterfv(GLenum target, GLenum pname, const GLfloat *v) { glTexParameterf(target, pname, v[0]); }

void glTextureParameteri(GLuint name, GLenum pname, GLint v)
{
    mgl_texture *t = named(name);
    if (t)
        set_param(&t->sampler, t, pname, (float)v, v);
}

void glTextureParameterf(GLuint name, GLenum pname, GLfloat v)
{
    mgl_texture *t = named(name);
    if (t)
        set_param(&t->sampler, t, pname, v, (int)v);
}

void glTextureParameteriv(GLuint name, GLenum pname, const GLint *v)
{
    if (pname == GL_TEXTURE_SWIZZLE_RGBA) {
        for (int i = 0; i < 4; i++)
            glTextureParameteri(name, GL_TEXTURE_SWIZZLE_R + i, v[i]);
        return;
    }
    glTextureParameteri(name, pname, v[0]);
}
void glTextureParameterfv(GLuint name, GLenum pname, const GLfloat *v) { glTextureParameterf(name, pname, v[0]); }

static void level_param(mgl_texture *t, GLint level, GLenum pname, GLint *out)
{
    *out = 0;
    if (!t || !t->mem)
        return;
    int w = t->base_w >> level, h = t->base_h >> level;
    switch (pname) {
    case GL_TEXTURE_WIDTH: *out = w ? w : 1; break;
    case GL_TEXTURE_HEIGHT: *out = h ? h : 1; break;
    case GL_TEXTURE_DEPTH: *out = t->base_d; break;
    case GL_TEXTURE_INTERNAL_FORMAT: *out = (GLint)t->internal_format; break;
    }
}

void glGetTexLevelParameteriv(GLenum target, GLint level, GLenum pname, GLint *out)
{
    if (target == GL_PROXY_TEXTURE_2D) {
        *out = pname == GL_TEXTURE_WIDTH ? proxy_w : pname == GL_TEXTURE_HEIGHT ? proxy_h : 0;
        return;
    }
    GLuint *slot = mgl_bound_texture_slot(target);
    level_param(slot ? mgl_texture_obj(*slot) : NULL, level, pname, out);
}

void glGetTextureLevelParameteriv(GLuint name, GLint level, GLenum pname, GLint *out)
{
    level_param(mgl_texture_obj(name), level, pname, out);
}

void glGetTexParameteriv(GLenum target, GLenum pname, GLint *out)
{
    mgl_texture *t = bound_tex(target);
    *out = 0;
    if (!t)
        return;
    switch (pname) {
    case GL_TEXTURE_MIN_FILTER: *out = t->sampler.min_filter; break;
    case GL_TEXTURE_MAG_FILTER: *out = t->sampler.mag_filter; break;
    case GL_TEXTURE_WRAP_S: *out = t->sampler.wrap_s; break;
    case GL_TEXTURE_WRAP_T: *out = t->sampler.wrap_t; break;
    case GL_TEXTURE_MAX_LEVEL: *out = t->max_level; break;
    }
}

void glGenerateMipmap(GLenum target)
{
    mgl_texture *t = bound_tex(target);
    if (t && t->mem)
        mglb_texture_generate_mipmaps(t->mem);
}

void glGenerateTextureMipmap(GLuint name)
{
    mgl_texture *t = mgl_texture_obj(name);
    if (t && t->mem)
        mglb_texture_generate_mipmaps(t->mem);
}

/* ---------------------------------------------------------------- clears and copies */

void glClearTexImage(GLuint name, GLint level, GLenum format, GLenum type, const void *data)
{
    mgl_texture *t = mgl_texture_obj(name);
    if (!t || !t->mem)
        return;
    unsigned char texel[16] = {0};
    if (data) {
        float v[4];
        uint32_t iv[4];
        read_pixel(data, format, type, v, iv);
        write_texel(texel, t->desc.format, v, iv);
    }
    mglb_texture_clear(t->mem, level, data ? texel : NULL);
}

void glCopyImageSubData(GLuint src, GLenum src_target, GLint src_level, GLint sx, GLint sy, GLint sz, GLuint dst,
                        GLenum dst_target, GLint dst_level, GLint dx, GLint dy, GLint dz, GLsizei w, GLsizei h,
                        GLsizei d)
{
    mgl_texture *s = mgl_texture_obj(src), *t = mgl_texture_obj(dst);
    if (src_target == GL_RENDERBUFFER || dst_target == GL_RENDERBUFFER) {
        mgl_log("glCopyImageSubData with renderbuffers not supported");
        return;
    }
    if (s && t && s->mem && t->mem)
        mglb_texture_copy(s->mem, src_level, sx, sy, sz, t->mem, dst_level, dx, dy, dz, w, h, d);
}

/* Copy from the read framebuffer's selected colour (or depth) attachment into the bound texture. */
static void copy_from_read_fbo(mgl_texture *t, int level, int dx, int dy, int x, int y, int w, int h)
{
    mgl_target rt;
    if (!t || !t->mem || !mgl_build_target(mgl->read_fbo, &rt))
        return;
    int is_depth = t->desc.format >= MGLF_DEPTH32F;
    mglb_texture *src = is_depth ? rt.depth : rt.tex[0];
    if (!is_depth && mgl->read_fbo) {
        mgl_framebuffer *fb = mgl_table_get(&mgl->framebuffers, mgl->read_fbo);
        if (fb && fb->read_buffer >= GL_COLOR_ATTACHMENT0 && fb->read_buffer < GL_COLOR_ATTACHMENT0 + MGL_MAX_ATTACHMENTS)
            src = rt.tex[fb->read_buffer - GL_COLOR_ATTACHMENT0];
    }
    if (src)
        mglb_texture_copy(src, 0, x, y, 0, t->mem, level, dx, dy, 0, w, h, 1);
}

void glCopyTexSubImage2D(GLenum target, GLint level, GLint dx, GLint dy, GLint x, GLint y, GLsizei w, GLsizei h)
{
    copy_from_read_fbo(bound_tex(target), level, dx, dy, x, y, w, h);
}

void glCopyTextureSubImage2D(GLuint texture, GLint level, GLint dx, GLint dy, GLint x, GLint y, GLsizei w, GLsizei h)
{
    copy_from_read_fbo(mgl_texture_obj(texture), level, dx, dy, x, y, w, h);
}

void glCopyTexImage2D(GLenum target, GLint level, GLenum internal, GLint x, GLint y, GLsizei w, GLsizei h, GLint border)
{
    mgl_texture *t = bound_tex(target);
    if (!t)
        return;
    if (level == 0)
        define_storage(t, internal, w, h, 1, 0);
    copy_from_read_fbo(t, level, 0, 0, x, y, w, h);
}

/* ---------------------------------------------------------------- samplers and images */

void glGenSamplers(GLsizei n, GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        names[i] = mgl_table_gen(&mgl->samplers);
        mgl_sampler *s = calloc(1, sizeof *s);
        mgl_sampler_defaults(&s->s);
        mgl_table_set(&mgl->samplers, names[i], s);
    }
}

void glCreateSamplers(GLsizei n, GLuint *names) { glGenSamplers(n, names); }

void glDeleteSamplers(GLsizei n, const GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        free(mgl_table_get(&mgl->samplers, names[i]));
        mgl_table_remove(&mgl->samplers, names[i]);
        for (int u = 0; u < MGL_MAX_UNITS; u++)
            if (mgl->bound_sampler[u] == names[i])
                mgl->bound_sampler[u] = 0;
    }
}

void glBindSampler(GLuint unit, GLuint sampler)
{
    if (unit < MGL_MAX_UNITS)
        mgl->bound_sampler[unit] = sampler;
}

void glBindSamplers(GLuint first, GLsizei count, const GLuint *samplers)
{
    for (GLsizei i = 0; i < count; i++)
        glBindSampler(first + (GLuint)i, samplers ? samplers[i] : 0);
}

void glSamplerParameteri(GLuint sampler, GLenum pname, GLint v)
{
    mgl_sampler *s = mgl_table_get(&mgl->samplers, sampler);
    if (s)
        set_param(&s->s, NULL, pname, (float)v, v);
}

void glSamplerParameterf(GLuint sampler, GLenum pname, GLfloat v)
{
    mgl_sampler *s = mgl_table_get(&mgl->samplers, sampler);
    if (s)
        set_param(&s->s, NULL, pname, v, (int)v);
}

void glSamplerParameteriv(GLuint sampler, GLenum pname, const GLint *v) { glSamplerParameteri(sampler, pname, v[0]); }
void glSamplerParameterfv(GLuint sampler, GLenum pname, const GLfloat *v) { glSamplerParameterf(sampler, pname, v[0]); }

void glBindImageTexture(GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum access,
                        GLenum format)
{
    if (unit >= MGL_MAX_IMAGE_UNITS)
        return;
    mgl->images[unit].texture = texture;
    mgl->images[unit].level = level;
    mgl->images[unit].layered = layered;
    mgl->images[unit].layer = layer;
    mgl->images[unit].access = access;
    mgl->images[unit].format = format;
}

/* 1D textures (Bliss's LPV block data): stored and sampled as Nx1 2D textures */
void glTexImage1D(GLenum target, GLint level, GLint internal, GLsizei w, GLint border, GLenum format, GLenum type,
                  const void *pixels)
{
    glTexImage2D(target, level, internal, w, 1, border, format, type, pixels);
}

void glTexSubImage1D(GLenum target, GLint level, GLint x, GLsizei w, GLenum format, GLenum type, const void *pixels)
{
    glTexSubImage2D(target, level, x, 0, w, 1, format, type, pixels);
}

void glTexStorage1D(GLenum target, GLsizei levels, GLenum internal, GLsizei w)
{
    glTexStorage2D(target, levels, internal, w, 1);
}
