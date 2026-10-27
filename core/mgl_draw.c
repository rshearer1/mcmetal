/* Vertex arrays, draw calls and compute dispatch: gather GL state into an mgl_draw for the backend. */
#include <string.h>
#include "mgl_state.h"

mgl_program *mgl_current_program(void);
int mgl_cull_take(const int *count, int n, mglb_buffer *ib); /* mgl_cull.c */
int mgl_cull_take_cpu(const int *count, int n, mglb_buffer *ib, unsigned char *keep);

/* ---------------------------------------------------------------- vertex arrays */

static mgl_vao *cur_vao(void)
{
    return mgl->vao ? mgl_table_get(&mgl->vaos, mgl->vao) : &mgl->default_vao;
}

void glGenVertexArrays(GLsizei n, GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        names[i] = mgl_table_gen(&mgl->vaos);
        mgl_table_set(&mgl->vaos, names[i], calloc(1, sizeof(mgl_vao)));
    }
}

void glCreateVertexArrays(GLsizei n, GLuint *names) { glGenVertexArrays(n, names); }

void glDeleteVertexArrays(GLsizei n, const GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        if (!mgl_table_get(&mgl->vaos, names[i]))
            continue;
        free(mgl_table_get(&mgl->vaos, names[i]));
        mgl_table_remove(&mgl->vaos, names[i]);
        if (mgl->vao == names[i])
            mgl->vao = 0;
    }
}

GLboolean glIsVertexArray(GLuint name) { return mgl_table_get(&mgl->vaos, name) != NULL; }

void glBindVertexArray(GLuint name)
{
    if (name && !mgl_table_get(&mgl->vaos, name))
        mgl_table_set(&mgl->vaos, name, calloc(1, sizeof(mgl_vao)));
    mgl->vao = name;
}

static void attrib_pointer(GLuint index, GLint size, GLenum type, int normalized, int integer, GLsizei stride,
                           const void *ptr)
{
    mgl_vao *v = cur_vao();
    if (!v || index >= MGL_MAX_VERTEX_ATTRIBS)
        return;
    mgl_vattrib *a = &v->attr[index];
    a->buffer = mgl->array_buffer;
    a->size = size == GL_BGRA ? 4 : size;
    a->type = type;
    a->normalized = normalized;
    a->integer = integer;
    a->offset = (size_t)ptr;
    if (!stride) {
        int ts = type == GL_FLOAT || type == GL_INT || type == GL_UNSIGNED_INT ? 4
               : type == GL_SHORT || type == GL_UNSIGNED_SHORT || type == GL_HALF_FLOAT ? 2 : 1;
        stride = ts * a->size;
    }
    a->stride = stride;
    a->use_binding = 0;
    if (!a->buffer)
        mgl_log("client-side vertex arrays are not supported (attribute %u)", index);
}

void glVertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void *ptr)
{
    attrib_pointer(index, size, type, normalized, 0, stride, ptr);
}

void glVertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void *ptr)
{
    attrib_pointer(index, size, type, 0, 1, stride, ptr);
}

void glEnableVertexAttribArray(GLuint index)
{
    mgl_vao *v = cur_vao();
    if (v && index < MGL_MAX_VERTEX_ATTRIBS)
        v->attr[index].enabled = 1;
}

void glDisableVertexAttribArray(GLuint index)
{
    mgl_vao *v = cur_vao();
    if (v && index < MGL_MAX_VERTEX_ATTRIBS)
        v->attr[index].enabled = 0;
}

/* ARB_vertex_attrib_binding (Distant Horizons with Iris): formats and buffers set apart, joined at draw time */
static void attrib_format(GLuint index, GLint size, GLenum type, int normalized, int integer, GLuint reloffset)
{
    mgl_vao *v = cur_vao();
    if (!v || index >= MGL_MAX_VERTEX_ATTRIBS)
        return;
    mgl_vattrib *a = &v->attr[index];
    if (!a->use_binding)
        a->binding = index; /* the default binding of an attribute is its own index */
    a->use_binding = 1;
    a->size = size == GL_BGRA ? 4 : size;
    a->type = type;
    a->normalized = normalized;
    a->integer = integer;
    a->offset = reloffset;
}

void glVertexAttribFormat(GLuint index, GLint size, GLenum type, GLboolean normalized, GLuint reloffset)
{
    attrib_format(index, size, type, normalized, 0, reloffset);
}

void glVertexAttribIFormat(GLuint index, GLint size, GLenum type, GLuint reloffset)
{
    attrib_format(index, size, type, 0, 1, reloffset);
}

void glVertexAttribBinding(GLuint index, GLuint binding)
{
    mgl_vao *v = cur_vao();
    if (v && index < MGL_MAX_VERTEX_ATTRIBS && binding < MGL_MAX_VERTEX_ATTRIBS) {
        v->attr[index].binding = binding;
        v->attr[index].use_binding = 1;
    }
}

void glBindVertexBuffer(GLuint binding, GLuint buffer, GLintptr offset, GLsizei stride)
{
    mgl_vao *v = cur_vao();
    if (v && binding < MGL_MAX_VERTEX_ATTRIBS) {
        v->bind[binding].buffer = buffer;
        v->bind[binding].offset = (size_t)offset;
        v->bind[binding].stride = stride;
    }
}

void glBindVertexBuffers(GLuint first, GLsizei count, const GLuint *buffers, const GLintptr *offsets, const GLsizei *strides)
{
    for (GLsizei i = 0; i < count; i++)
        glBindVertexBuffer(first + (GLuint)i, buffers ? buffers[i] : 0, buffers ? offsets[i] : 0, buffers ? strides[i] : 16);
}

void glVertexBindingDivisor(GLuint binding, GLuint divisor)
{
    mgl_vao *v = cur_vao();
    if (v && binding < MGL_MAX_VERTEX_ATTRIBS)
        v->bind[binding].divisor = divisor;
}

/* An attribute's effective source: its own pointer, or its binding point's buffer plus its relative offset */
static mgl_vattrib resolve_attrib(const mgl_vao *v, int gi)
{
    mgl_vattrib a = v->attr[gi];
    if (a.use_binding) {
        const mgl_vbinding *b = &v->bind[a.binding];
        a.buffer = b->buffer;
        a.offset += b->offset;
        a.divisor = b->divisor;
        a.stride = b->stride;
        if (!a.stride) {
            int ts = a.type == GL_FLOAT || a.type == GL_INT || a.type == GL_UNSIGNED_INT ? 4
                   : a.type == GL_SHORT || a.type == GL_UNSIGNED_SHORT || a.type == GL_HALF_FLOAT ? 2 : 1;
            a.stride = ts * a.size;
        }
    }
    return a;
}

void glVertexAttribDivisor(GLuint index, GLuint divisor)
{
    mgl_vao *v = cur_vao();
    if (v && index < MGL_MAX_VERTEX_ATTRIBS)
        v->attr[index].divisor = divisor;
}

/* ---------------------------------------------------------------- draw assembly */

static enum mgl_vtype vtype(GLenum t)
{
    switch (t) {
    case GL_HALF_FLOAT: return MGLV_HALF;
    case GL_UNSIGNED_BYTE: return MGLV_UBYTE;
    case GL_BYTE: return MGLV_BYTE;
    case GL_UNSIGNED_SHORT: return MGLV_USHORT;
    case GL_SHORT: return MGLV_SHORT;
    case GL_UNSIGNED_INT: return MGLV_UINT;
    case GL_INT: return MGLV_INT;
    default: return MGLV_FLOAT;
    }
}

static int tex_index_for_dim(int dim)
{
    switch (dim) {
    case 3: return 1;
    case 12: return 2;
    case 6: return 3;
    default: return 0;
    }
}

static mglb_buffer *zero_attrib_buffer(void)
{
    static mglb_buffer *z;
    if (!z) {
        z = mglb_buffer_new(32); /* GL's default attribute (0,0,0,1): floats at 0, integers at 16 */
        float v[4] = {0, 0, 0, 1};
        int32_t iv[4] = {0, 0, 0, 1};
        memcpy(mglb_buffer_ptr(z), v, sizeof v);
        memcpy((char *)mglb_buffer_ptr(z) + 16, iv, sizeof iv);
    }
    return z;
}

/* RGB internal formats live in RGBA textures (Metal has no 3-channel formats); GL samples their alpha as 1 */
static int rgb_only(GLenum internal)
{
    switch (internal) {
    case GL_RGB: case GL_RGB8: case 3: case GL_SRGB8: case GL_RGB8_SNORM: case GL_RGB16F: case GL_RGB32F: case GL_RGB16:
    case GL_SRGB: case GL_RGB4: case GL_RGB5: case GL_RGB10: case GL_RGB12: case GL_R3_G3_B2: case GL_RGB565:
        return 1;
    }
    return 0;
}

static void gather_textures(mgl_draw *d, mgl_program *p, int compute)
{
    for (int i = 0; i < p->x.num_textures && i < MGL_MAX_TEXTURES * 3; i++) {
        mgl_texture_slot *slot = &p->x.textures[i];
        for (int s = 0; s < 3; s++) {
            int idx = slot->msl_index[s];
            if (idx < 0 || idx >= MGL_MAX_TEXTURES)
                continue;
            mgl_bound_texture *bt = &d->textures[s][idx];
            if (idx + 1 > d->num_textures[s])
                d->num_textures[s] = idx + 1;
            bt->dim = slot->dim;
            bt->sample_kind = slot->sample_kind;
            bt->is_image = slot->is_image;
            bt->is_shadow = slot->is_shadow;
            if (slot->is_image) {
                int unit = p->image_unit_of[i];
                mgl_texture *t = unit >= 0 && unit < MGL_MAX_IMAGE_UNITS ? mgl_texture_obj(mgl->images[unit].texture) : NULL;
                bt->tex = t ? t->mem : NULL;
                mglb_texture_need_image(bt->tex); /* textures start without image writes (lossless compression) */
                bt->image_level = unit >= 0 && unit < MGL_MAX_IMAGE_UNITS ? mgl->images[unit].level : 0;
            } else if (p->x.uses_scene && !strcmp(slot->name, "mcm_atlas")) {
                bt->tex = mgl_rt_atlas; /* mcm_trace's alpha test reads the terrain's block atlas */
                mgl_sampler_defaults(&bt->sampler);
                bt->sampler.min_filter = bt->sampler.mag_filter = GL_NEAREST;
            } else if (p->x.uses_scene && !strcmp(slot->name, "mcm_specular")) {
                bt->tex = mgl_rt_specular; /* mcm_hit_emission: the terrain's LabPBR specular atlas */
                mgl_sampler_defaults(&bt->sampler);
                bt->sampler.min_filter = bt->sampler.mag_filter = GL_NEAREST;
            } else if (p->x.uses_scene && !strcmp(slot->name, "mcm_normals")) {
                bt->tex = mgl_rt_normals; /* mcm_hit_mapped_normal: the terrain's LabPBR normal atlas */
                mgl_sampler_defaults(&bt->sampler);
                bt->sampler.min_filter = bt->sampler.mag_filter = GL_NEAREST;
            } else {
                int unit = p->unit_of[i];
                if (unit < 0 || unit >= MGL_MAX_UNITS)
                    continue;
                mgl_texture *t = mgl_texture_obj(mgl->bound_tex[unit][tex_index_for_dim(slot->dim)]);
                bt->tex = t ? t->mem : NULL;
                int no_alpha = t && rgb_only(t->internal_format);
                if (t && (t->has_swizzle || no_alpha)) {
                    static const int ident[4] = {GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA};
                    memcpy(bt->swizzle, t->has_swizzle ? t->swizzle : ident, sizeof bt->swizzle);
                    for (int c = 0; no_alpha && c < 4; c++)
                        if (bt->swizzle[c] == GL_ALPHA)
                            bt->swizzle[c] = GL_ONE;
                    mglb_texture_need_view(bt->tex);
                }
                mgl_sampler *so = mgl_table_get(&mgl->samplers, mgl->bound_sampler[unit]);
                if (so)
                    bt->sampler = so->s;
                else if (t)
                    bt->sampler = t->sampler;
                else
                    mgl_sampler_defaults(&bt->sampler);
            }
        }
    }
    (void)compute;
}

static void gather_uniforms(mgl_draw *d, mgl_program *p)
{
    for (int s = 0; s < 3; s++) {
        d->uniforms[s] = p->ublock[s];
        d->uniform_size[s] = p->x.default_block_size[s];
    }
    d->uniform_used = p->x.used_ranges[MGL_COMPUTE];
    d->num_uniform_used = p->x.num_used_ranges[MGL_COMPUTE];
    for (int i = 0; i < p->x.num_ubos && i < 12; i++) {
        int b = p->ubo_binding[i];
        if (b < 0 || b >= MGL_MAX_UBO_BINDINGS)
            continue;
        mgl_buffer *buf = mgl_buffer_obj(mgl->ubo[b].buffer);
        mgl_buffer_settle(buf);
        d->ubo[i] = buf ? buf->mem : NULL;
        d->ubo_offset[i] = mgl->ubo[b].offset;
        d->ubo_size[i] = mgl->ubo[b].size ? mgl->ubo[b].size : (buf ? buf->size - mgl->ubo[b].offset : 0);
    }
    for (int i = 0; i < p->x.num_ssbos && i < 8; i++) {
        int b = p->ssbo_binding[i];
        if (b < 0 || b >= MGL_MAX_SSBO_BINDINGS)
            continue;
        mgl_buffer *buf = mgl_buffer_obj(mgl->ssbo[b].buffer);
        mgl_buffer_settle(buf);
        mgl_buffer_gpu_written(buf);
        d->ssbo[i] = buf ? buf->mem : NULL;
        d->ssbo_offset[i] = mgl->ssbo[b].offset;
    }
    if (p->x.uses_scene) /* mcm_trace's own storage block: the scene's per-instance triangle data */
        for (int i = 0; i < p->x.num_ssbos && i < 8; i++)
            if (!strcmp(p->x.ssbos[i].name, "McmInstances") || !strcmp(p->x.ssbos[i].name, "McmLights")) {
                d->ssbo[i] = p->x.ssbos[i].name[3] == 'I' ? mglb_rt_instances() : mglb_rt_lights();
                d->ssbo_offset[i] = 0;
            }
}

/* the GL buffer behind each of the last built draw's vertex buffer slots (NULL: the constant-attribute buffer) */
static mgl_buffer *vsrc[MGL_MAX_VERTEX_BUFFERS];

/* Vertex buffers left partly in old memory by a lazy rename (mgl_buffer.c) are fine as long as the draw fetches
   only the bytes already written; otherwise, or when the range can't be known (max_vertex < 0), they are settled. */
static void vertex_ranges(const mgl_draw *d, long min_vertex, long max_vertex)
{
    for (int i = 0; i < d->num_vbufs; i++) {
        mgl_buffer *b = vsrc[i];
        if (!b || !b->lazy)
            continue;
        const mgl_vertex_buf *vb = &d->vbufs[i];
        if (max_vertex >= 0 && min_vertex >= 0 && !vb->divisor && vb->stride > 0 && d->instances <= 1) {
            size_t lo = vb->offset + (size_t)min_vertex * (size_t)vb->stride;
            size_t hi = vb->offset + ((size_t)max_vertex + 1) * (size_t)vb->stride;
            if (lo >= b->valid_lo && hi <= b->valid_hi)
                continue;
        }
        mgl_buffer_settle(b);
        ((mgl_draw *)d)->vbufs[i].buf = b->mem;
    }
}

/* Returns 0 when the draw can't happen (no program, no target). */
static int build_draw(mgl_draw *d)
{
    memset(vsrc, 0, sizeof vsrc);
    mgl_program *p = mgl_current_program();
    memset(d, 0, sizeof *d);
    if (p)
        mgl_program_wait(p);
    if (!p || !p->linked || !p->gpu)
        return 0;
    if (!mgl_build_target(mgl->draw_fbo, &d->target))
        return 0;
    d->program = p->gpu;

    uint8_t cm = (uint8_t)((mgl->color_mask[0] ? 1 : 0) | (mgl->color_mask[1] ? 2 : 0) | (mgl->color_mask[2] ? 4 : 0) |
                           (mgl->color_mask[3] ? 8 : 0));
    for (int i = 0; i < MGL_MAX_ATTACHMENTS; i++) {
        mgl_blend *b = &d->blend[i];
        b->enabled = i < 8 ? mgl->blend_i[i] : mgl->blend;
        const GLenum *f = mgl->blend_fn_i[i < 8 ? i : 0];
        b->src_rgb = (int)f[0];
        b->dst_rgb = (int)f[1];
        b->src_a = (int)f[2];
        b->dst_a = (int)f[3];
        b->eq_rgb = (int)f[4];
        b->eq_a = (int)f[5];
        b->color_mask = cm;
    }
    d->depth_test = mgl->depth_test;
    d->depth_write = mgl->depth_mask && mgl->depth_test; /* GL: no depth writes while the test is disabled */
    d->depth_func = (int)mgl->depth_func;
    d->cull = mgl->cull_face_enabled;
    d->cull_face = (int)mgl->cull_face;
    d->front_face = (int)mgl->front_face;
    memcpy(d->viewport, mgl->viewport, sizeof d->viewport);
    d->scissor_enabled = mgl->scissor_test;
    memcpy(d->scissor, mgl->scissor, sizeof d->scissor);
    d->polygon_offset_enabled = mgl->polygon_offset_fill;
    d->polygon_offset_factor = mgl->polygon_offset_factor;
    d->polygon_offset_units = mgl->polygon_offset_units;

    /* vertex attributes: every shader input needs a source; disabled ones read a constant (0,0,0,1) */
    mgl_vao *v = cur_vao();
    int has_input[MGL_MAX_VERTEX_ATTRIBS] = {0};
    for (int gi = 0; gi < MGL_MAX_VERTEX_ATTRIBS; gi++) {
        int loc = p->gl_index_to_loc[gi];
        if (loc < 0 || loc >= MGL_MAX_VERTEX_ATTRIBS)
            continue;
        has_input[loc] = 1;
        mgl_vattrib ra = resolve_attrib(v, gi), *a = &ra;
        mgl_vertex_attr *o = &d->attrs[loc];
        o->enabled = 1;
        o->location = loc;
        mgl_buffer *buf = a->enabled ? mgl_buffer_obj(a->buffer) : NULL;
        if (!buf || !buf->mem) {
            o->type = MGLV_FLOAT;
            o->size = 4;
            o->buffer = -1; /* constant */
            continue;
        }
        o->type = vtype(a->type);
        o->size = a->size;
        o->normalized = a->normalized;
        o->integer = a->integer;
        /* share a vertex buffer slot when buffer and stride match and the offset fits within the stride */
        int slot = -1;
        for (int k = 0; k < d->num_vbufs; k++)
            if (d->vbufs[k].buf == buf->mem && d->vbufs[k].stride == a->stride && d->vbufs[k].divisor == (int)a->divisor &&
                a->offset >= d->vbufs[k].offset &&
                a->offset - d->vbufs[k].offset < (size_t)a->stride) {
                slot = k;
                break;
            }
        if (slot < 0 && d->num_vbufs < MGL_MAX_VERTEX_BUFFERS - 1) {
            slot = d->num_vbufs++;
            d->vbufs[slot].buf = buf->mem;
            d->vbufs[slot].stride = a->stride;
            d->vbufs[slot].offset = a->offset;
            d->vbufs[slot].divisor = (int)a->divisor;
            vsrc[slot] = buf;
        }
        if (slot < 0)
            return 0;
        o->buffer = slot;
        o->offset = a->offset - d->vbufs[slot].offset;
    }
    /* shader inputs with no GL index mapping at all */
    for (int i = 0; i < p->x.num_attribs; i++) {
        int loc = p->x.attribs[i].location;
        if (loc >= 0 && loc < MGL_MAX_VERTEX_ATTRIBS && !has_input[loc]) {
            d->attrs[loc].enabled = 1;
            d->attrs[loc].location = loc;
            d->attrs[loc].type = MGLV_FLOAT;
            d->attrs[loc].size = 4;
            d->attrs[loc].buffer = -1;
        }
    }
    for (int loc = 0; loc < MGL_MAX_VERTEX_ATTRIBS; loc++)
        if (d->attrs[loc].enabled && d->attrs[loc].buffer < 0) {
            int slot = d->num_vbufs;
            for (int k = 0; k < d->num_vbufs; k++)
                if (d->vbufs[k].stride == 0)
                    slot = k;
            if (slot == d->num_vbufs) {
                d->vbufs[slot].buf = zero_attrib_buffer();
                d->vbufs[slot].stride = 0;
                d->num_vbufs++;
            }
            d->attrs[loc].buffer = slot;
            d->attrs[loc].offset = 0;
            d->attrs[loc].integer = 0;
            for (int i = 0; i < p->x.num_attribs; i++)
                if (p->x.attribs[i].location == loc && p->x.attribs[i].is_int) {
                    d->attrs[loc].type = MGLV_INT;
                    d->attrs[loc].integer = 1;
                    d->attrs[loc].offset = 16;
                }
        }
    /* Metal reads ints only into int inputs and unsigned only into uint (GL converts freely): make the vertex format
       follow the shader's signedness. Iris feeds its ivec3 iris_Entity from GL_UNSIGNED_SHORT data, for example. */
    for (int i = 0; i < p->x.num_attribs; i++) {
        int loc = p->x.attribs[i].location, k = p->x.attribs[i].is_int;
        if (!k || loc < 0 || loc >= MGL_MAX_VERTEX_ATTRIBS || !d->attrs[loc].enabled)
            continue;
        mgl_vertex_attr *o = &d->attrs[loc];
        o->integer = 1;
        o->normalized = 0;
        static const enum mgl_vtype as_signed[] = {MGLV_INT, MGLV_INT, MGLV_BYTE, MGLV_BYTE, MGLV_SHORT, MGLV_SHORT, MGLV_INT, MGLV_INT};
        static const enum mgl_vtype as_unsigned[] = {MGLV_UINT, MGLV_UINT, MGLV_UBYTE, MGLV_UBYTE, MGLV_USHORT, MGLV_USHORT, MGLV_UINT, MGLV_UINT};
        o->type = k == 2 ? as_unsigned[o->type] : as_signed[o->type];
    }

    if (mgl_tu_jitter_on()) /* world geometry (depth tested or written) moves with the temporal upscaler's jitter */
        mgl_program_jitter(p, mgl->current_program, &d->target, d->depth_test || d->depth_write);
    gather_uniforms(d, p);
    d->uses_scene = p->x.uses_scene;
    d->copy_fs = p->copy_fs;
    gather_textures(d, p, 0);
    d->instances = 1;
    return 1;
}

/* GL_TRIANGLE_FAN -> GL_TRIANGLES with a generated index list (Metal has no fans). */
static mglb_buffer *fan_indices(const mgl_draw *d, int count, GLenum type, const void *src_indices, int *out_count)
{
    int tris = count - 2;
    if (tris <= 0)
        return NULL;
    mglb_buffer *b = mglb_buffer_new((size_t)tris * 3 * 4);
    uint32_t *o = mglb_buffer_ptr(b);
    for (int i = 0; i < tris; i++) {
        uint32_t idx[3] = {0, (uint32_t)i + 1, (uint32_t)i + 2};
        for (int k = 0; k < 3; k++) {
            uint32_t v = idx[k];
            if (src_indices)
                v = type == GL_UNSIGNED_SHORT ? ((const uint16_t *)src_indices)[v]
                    : type == GL_UNSIGNED_BYTE ? ((const uint8_t *)src_indices)[v] : ((const uint32_t *)src_indices)[v];
            else
                v += (uint32_t)d->first;
            o[i * 3 + k] = v;
        }
    }
    *out_count = tris * 3;
    return b;
}

/* Programs with a geometry shader take the emulation path (mgl_gs.c); everything else draws directly. */
static void submit(mgl_draw *d)
{
    mgl_program *p = mgl_current_program();
    mgl_rt_record(p, d);
    if (mgl_denoise_draw(p, d)) /* MetalFX instead of the pack's own pass */
        return;
    if (!p || !p->x.gs_max_vertices) {
        mglb_draw(d);
        return;
    }
    if (d->primitive != GL_TRIANGLES) {
        static int warned;
        if (!warned++)
            mgl_log("geometry shader with primitive 0x%04X not supported (triangles only)", d->primitive);
        return;
    }
    int tris = d->count / 3;
    if (tris <= 0)
        return;
    int esize = d->index_type == GL_UNSIGNED_SHORT ? 2 : 4;
    GLint info[4] = {tris, !d->index_buf ? 0 : esize == 2 ? 1 : 2, d->base_vertex,
                     d->index_buf ? (GLint)(d->index_offset / (size_t)esize) : d->first};
    for (int i = 0; i < p->x.num_uniforms; i++)
        if (!strcmp(p->x.uniforms[i].name, "mgl_draw_info") && p->x.uniforms[i].offset[MGL_COMPUTE] >= 0 &&
            p->ublock[MGL_COMPUTE])
            memcpy(p->ublock[MGL_COMPUTE] + p->x.uniforms[i].offset[MGL_COMPUTE], info, sizeof info);
    memcpy(d->local_size, p->x.local_size, sizeof d->local_size);
    mglb_draw_gs(d, tris, p->x.gs_max_vertices, p->x.gs_record_floats);
}

/* a geometry-shader multi-draw as one job over a table of sections (already recorded for ray tracing) */
static void submit_gs_sections(mgl_draw *d, int32_t (*sec)[4], int nsec, int slots)
{
    mgl_program *p = mgl_current_program();
    GLint info[4] = {slots, d->index_type == GL_UNSIGNED_SHORT ? 1 : 2, 0, 0};
    for (int i = 0; i < p->x.num_uniforms; i++)
        if (!strcmp(p->x.uniforms[i].name, "mgl_draw_info") && p->x.uniforms[i].offset[MGL_COMPUTE] >= 0 &&
            p->ublock[MGL_COMPUTE])
            memcpy(p->ublock[MGL_COMPUTE] + p->x.uniforms[i].offset[MGL_COMPUTE], info, sizeof info);
    memcpy(d->local_size, p->x.local_size, sizeof d->local_size);
    d->count = slots * 3;
    d->gs_sec = (const int32_t (*)[4])sec;
    d->gs_sec_n = nsec;
    mglb_draw_gs(d, slots, p->x.gs_max_vertices, p->x.gs_record_floats);
    d->gs_sec = NULL;
    d->gs_sec_n = 0;
}

static void draw(GLenum mode, GLsizei count, GLenum type, const void *indices, GLint first, GLint basevertex,
                 GLsizei instances)
{
    mgl_draw d;
    if (count <= 0 || instances <= 0 || !build_draw(&d))
        return;
    d.primitive = (int)mode;
    d.count = count;
    d.first = first;
    d.base_vertex = basevertex;
    d.instances = instances;
    mgl_vao *v = cur_vao();
    mgl_buffer *ib = type ? mgl_buffer_obj(v->element_buffer) : NULL;
    if (type && (!ib || !ib->mem)) {
        mgl_log("indexed draw without an element buffer (client-side indices are not supported)");
        return;
    }
    mgl_buffer_settle(ib);
    if (ib) {
        size_t es = type == GL_UNSIGNED_SHORT ? 2 : type == GL_UNSIGNED_INT ? 4 : 1;
        long top = mode == GL_TRIANGLE_FAN || (size_t)indices % es ? -1
                   : mgl_buffer_index_bound(ib, type, (size_t)indices / es, (size_t)count);
        vertex_ranges(&d, basevertex < 0 ? -1 : basevertex, top < 0 ? -1 : top + basevertex);
    } else {
        vertex_ranges(&d, first, (long)first + count - 1);
    }
    if (ib && (type == GL_UNSIGNED_BYTE || mode == GL_TRIANGLE_FAN))
        mglb_buffer_wait_writes(ib->mem); /* read on the CPU below */
    if (type == GL_UNSIGNED_BYTE && mode != GL_TRIANGLE_FAN) {
        /* Metal has no 8-bit indices: widen */
        mglb_buffer *w = mglb_buffer_new((size_t)count * 2);
        const uint8_t *s = (const uint8_t *)mglb_buffer_ptr(ib->mem) + (size_t)indices;
        for (GLsizei i = 0; i < count; i++)
            ((uint16_t *)mglb_buffer_ptr(w))[i] = s[i];
        d.index_buf = w;
        d.index_offset = 0;
        d.index_type = GL_UNSIGNED_SHORT;
        submit(&d);
        mglb_buffer_release(w);
        return;
    }
    if (mode == GL_TRIANGLE_FAN) {
        int n = 0;
        const void *src = ib ? (const char *)mglb_buffer_ptr(ib->mem) + (size_t)indices : NULL;
        mglb_buffer *fan = fan_indices(&d, count, type, src, &n);
        if (!fan)
            return;
        d.primitive = GL_TRIANGLES;
        d.index_buf = fan;
        d.index_offset = 0;
        d.index_type = GL_UNSIGNED_INT;
        d.count = n;
        d.first = 0;
        submit(&d);
        mglb_buffer_release(fan);
        return;
    }
    if (ib) {
        d.index_buf = ib->mem;
        d.index_offset = (size_t)indices;
        d.index_type = (int)type;
    }
    submit(&d);
}

void glDrawArrays(GLenum mode, GLint first, GLsizei count) { draw(mode, count, 0, NULL, first, 0, 1); }
void glDrawArraysInstanced(GLenum mode, GLint first, GLsizei count, GLsizei n) { draw(mode, count, 0, NULL, first, 0, n); }
void glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *ind) { draw(mode, count, type, ind, 0, 0, 1); }
void glDrawElementsInstanced(GLenum mode, GLsizei count, GLenum type, const void *ind, GLsizei n) { draw(mode, count, type, ind, 0, 0, n); }
void glDrawRangeElements(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void *ind) { draw(mode, count, type, ind, 0, 0, 1); }
void glDrawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type, const void *ind, GLint bv) { draw(mode, count, type, ind, 0, bv, 1); }

void glMultiDrawElementsBaseVertex(GLenum mode, const GLsizei *count, GLenum type, const void *const *ind,
                                   GLsizei drawcount, const GLint *bv)
{
    mgl_program *p = mgl_current_program();
    mgl_vao *v = cur_vao();
    mgl_buffer *ib = v ? mgl_buffer_obj(v->element_buffer) : NULL;
    /* Fast path: assemble the state once for all of Sodium's section draws in a region */
    if (drawcount > 1 && p && !p->x.gs_max_vertices && ib && ib->mem && mode != GL_TRIANGLE_FAN &&
        (type == GL_UNSIGNED_SHORT || type == GL_UNSIGNED_INT)) {
        mgl_draw d;
        if (!build_draw(&d))
            return;
        mgl_buffer_settle(ib);
        vertex_ranges(&d, -1, -1);
        d.primitive = (int)mode;
        d.instances = 1;
        d.index_buf = ib->mem;
        d.index_type = (int)type;
        for (GLsizei i = 0; i < drawcount; i++) { /* ray-tracing capture still sees each section */
            d.count = count[i];
            d.index_offset = (size_t)ind[i];
            d.base_vertex = bv[i];
            mgl_rt_record(p, &d);
        }
        d.multi_n = drawcount;
        d.multi_count = count;
        d.multi_offset = ind;
        d.multi_base = bv;
        if (mode == GL_TRIANGLES && type == GL_UNSIGNED_INT)
            d.cull_cmd = mgl_cull_take(count, drawcount, ib->mem);
        mglb_draw(&d);
        return;
    }
    /* Geometry-shader programs (SEUS's shadow terrain: ~30 sections per call): the state is the same for every
       section, so assemble it once and only change the range per section. */
    if (drawcount > 1 && p && p->x.gs_max_vertices && ib && ib->mem && mode == GL_TRIANGLES &&
        (type == GL_UNSIGNED_SHORT || type == GL_UNSIGNED_INT)) {
        mgl_draw d;
        if (!build_draw(&d))
            return;
        mgl_buffer_settle(ib);
        vertex_ranges(&d, -1, -1);
        d.primitive = (int)mode;
        d.instances = 1;
        d.index_buf = ib->mem;
        d.index_type = (int)type;
        /* GPU chunk culling: sections out of the pass's view are skipped (still recorded for ray tracing) */
        unsigned char keep_small[256], *keep = drawcount <= 256 ? keep_small : malloc((size_t)drawcount);
        int culled = keep && type == GL_UNSIGNED_INT && mgl_cull_take_cpu(count, drawcount, ib->mem, keep);
        /* MGL_GS_BATCH_SECTIONS=1: one job per call, the sections packed as a table (SEUS's shadow pass: ~1700 jobs a
           frame -> ~70). Off by default: on the M3 the concurrent small jobs were faster (75 vs 44 fps walking) */
        static int one_job = -1;
        if (one_job < 0)
            one_job = getenv("MGL_GS_BATCH_SECTIONS") && atoi(getenv("MGL_GS_BATCH_SECTIONS")) != 0;
        int esize = type == GL_UNSIGNED_SHORT ? 2 : 4;
        int32_t (*sec)[4] = one_job ? malloc(sizeof *sec * (size_t)(drawcount + 1)) : NULL;
        int nsec = 0, slots = 0;
        for (GLsizei i = 0; i < drawcount; i++) {
            if (count[i] <= 0)
                continue;
            d.count = count[i];
            d.index_offset = (size_t)ind[i];
            d.base_vertex = bv[i];
            if (culled && !keep[i])
                mgl_rt_record(p, &d);
            else if (!sec || count[i] < 3)
                submit(&d);
            else {
                mgl_rt_record(p, &d);
                int tris = count[i] / 3;
                if (slots > INT32_MAX - tris - 2)
                    break;
                sec[nsec][0] = slots;
                sec[nsec][1] = tris;
                sec[nsec][2] = bv[i];
                sec[nsec][3] = (int32_t)((size_t)ind[i] / (size_t)esize);
                nsec++;
                slots += (tris + 1) & ~1; /* sections start on an even slot: the vertex sharing pairs triangles */
            }
        }
        if (nsec)
            submit_gs_sections(&d, sec, nsec, slots);
        free(sec);
        if (keep != keep_small)
            free(keep);
        return;
    }
    for (GLsizei i = 0; i < drawcount; i++)
        draw(mode, count[i], type, ind[i], 0, bv[i], 1);
}

void glMultiDrawElements(GLenum mode, const GLsizei *count, GLenum type, const void *const *ind, GLsizei drawcount)
{
    for (GLsizei i = 0; i < drawcount; i++)
        draw(mode, count[i], type, ind[i], 0, 0, 1);
}

void glMultiDrawArrays(GLenum mode, const GLint *first, const GLsizei *count, GLsizei drawcount)
{
    for (GLsizei i = 0; i < drawcount; i++)
        draw(mode, count[i], 0, NULL, first[i], 0, 1);
}

/* ---------------------------------------------------------------- compute */

void glDispatchCompute(GLuint gx, GLuint gy, GLuint gz)
{
    mgl_program *p = mgl_current_program();
    if (p)
        mgl_program_wait(p);
    if (!p || !p->linked || !p->gpu)
        return;
    mgl_draw d;
    memset(&d, 0, sizeof d);
    d.program = p->gpu;
    memcpy(d.local_size, p->x.local_size, sizeof d.local_size);
    gather_uniforms(&d, p);
    d.uses_scene = p->x.uses_scene;
    gather_textures(&d, p, 1);
    mglb_dispatch(&d, (int)gx, (int)gy, (int)gz);
}

void glMemoryBarrier(GLbitfield barriers) { mglb_memory_barrier(); }
GLAPI void glMemoryBarrierEXT(GLbitfield barriers) { mglb_memory_barrier(); }
void glMemoryBarrierByRegion(GLbitfield barriers) { mglb_memory_barrier(); }
void glTextureBarrier(void) { mglb_memory_barrier(); }

/* ---------------------------------------------------------------- sync and queries */

GLsync glFenceSync(GLenum condition, GLbitfield flags)
{
    mgl_sync *s = malloc(sizeof *s);
    s->fence = mglb_fence();
    return (GLsync)s;
}

GLenum glClientWaitSync(GLsync sync, GLbitfield flags, GLuint64 timeout)
{
    mgl_sync *s = (mgl_sync *)sync;
    if (!s)
        return GL_WAIT_FAILED;
    if (mglb_fence_wait(s->fence, 0))
        return GL_ALREADY_SIGNALED;
    if (flags & GL_SYNC_FLUSH_COMMANDS_BIT)
        mglb_flush();
    return mglb_fence_wait(s->fence, timeout) ? GL_CONDITION_SATISFIED : GL_TIMEOUT_EXPIRED;
}

void glWaitSync(GLsync sync, GLbitfield flags, GLuint64 timeout) {}

void glGetSynciv(GLsync sync, GLenum pname, GLsizei count, GLsizei *length, GLint *values)
{
    mgl_sync *s = (mgl_sync *)sync;
    if (length)
        *length = 1;
    switch (pname) {
    case GL_SYNC_STATUS: *values = s && mglb_fence_wait(s->fence, 0) ? GL_SIGNALED : GL_UNSIGNALED; break;
    case GL_OBJECT_TYPE: *values = GL_SYNC_FENCE; break;
    case GL_SYNC_CONDITION: *values = GL_SYNC_GPU_COMMANDS_COMPLETE; break;
    default: *values = 0;
    }
}

void glDeleteSync(GLsync sync) { free(sync); }
GLboolean glIsSync(GLsync sync) { return sync != NULL; }

/* Timer queries report 0 ns for now; enough for Iris's profiling hooks. */
void glGenQueries(GLsizei n, GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        names[i] = mgl_table_gen(&mgl->queries);
        mgl_table_set(&mgl->queries, names[i], calloc(1, sizeof(mgl_query)));
    }
}

void glCreateQueries(GLenum target, GLsizei n, GLuint *names) { glGenQueries(n, names); }

void glDeleteQueries(GLsizei n, const GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        free(mgl_table_get(&mgl->queries, names[i]));
        mgl_table_remove(&mgl->queries, names[i]);
    }
}

void glBeginQuery(GLenum target, GLuint id)
{
    mgl_query *q = mgl_table_get(&mgl->queries, id);
    if (!q) {
        q = calloc(1, sizeof *q);
        mgl_table_set(&mgl->queries, id, q);
    }
    q->target = target;
    q->available = 0;
}

void glEndQuery(GLenum target)
{
    for (unsigned i = 1; i < mgl->queries.cap; i++) {
        mgl_query *q = mgl->queries.obj[i];
        if (q && q->target == target && !q->available) {
            q->result = 0;
            q->available = 1;
        }
    }
}

void glQueryCounter(GLuint id, GLenum target)
{
    glBeginQuery(target, id);
    glEndQuery(target);
}

void glGetQueryObjectiv(GLuint id, GLenum pname, GLint *v)
{
    mgl_query *q = mgl_table_get(&mgl->queries, id);
    *v = pname == GL_QUERY_RESULT_AVAILABLE ? (q ? q->available : 1) : (GLint)(q ? q->result : 0);
}

void glGetQueryObjectuiv(GLuint id, GLenum pname, GLuint *v)
{
    GLint t;
    glGetQueryObjectiv(id, pname, &t);
    *v = (GLuint)t;
}

void glGetQueryObjecti64v(GLuint id, GLenum pname, GLint64 *v)
{
    mgl_query *q = mgl_table_get(&mgl->queries, id);
    *v = pname == GL_QUERY_RESULT_AVAILABLE ? (q ? q->available : 1) : (GLint64)(q ? q->result : 0);
}

void glGetQueryObjectui64v(GLuint id, GLenum pname, GLuint64 *v)
{
    GLint64 t;
    glGetQueryObjecti64v(id, pname, &t);
    *v = (GLuint64)t;
}
