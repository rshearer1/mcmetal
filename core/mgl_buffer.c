/* Buffer objects. Memory is CPU-visible (unified memory), so mapping returns a direct pointer.
   GL ordering rules are kept by renaming: if the GPU may still read a buffer that GL code is about to
   overwrite (glBufferSubData, non-persistent maps), we switch to fresh memory and copy the old contents. */
#include <string.h>
#include "mgl_state.h"

mgl_buffer *mgl_buffer_obj(GLuint name)
{
    return mgl_table_get(&mgl->buffers, name);
}

static GLuint *binding_for(GLenum target)
{
    switch (target) {
    case GL_ARRAY_BUFFER: return &mgl->array_buffer;
    case GL_ELEMENT_ARRAY_BUFFER: {
        mgl_vao *v = mgl->vao ? mgl_table_get(&mgl->vaos, mgl->vao) : &mgl->default_vao;
        return v ? &v->element_buffer : &mgl->element_buffer_no_vao;
    }
    case GL_COPY_READ_BUFFER: return &mgl->copy_read_buffer;
    case GL_COPY_WRITE_BUFFER: return &mgl->copy_write_buffer;
    case GL_PIXEL_UNPACK_BUFFER: return &mgl->pixel_unpack_buffer;
    case GL_PIXEL_PACK_BUFFER: return &mgl->pixel_pack_buffer;
    case GL_UNIFORM_BUFFER: return &mgl->uniform_buffer;
    case GL_DRAW_INDIRECT_BUFFER: return &mgl->draw_indirect_buffer;
    case GL_SHADER_STORAGE_BUFFER: return &mgl->shader_storage_buffer;
    }
    mgl_log("buffer target 0x%04X not supported", target);
    return NULL;
}

static mgl_buffer *bound(GLenum target)
{
    GLuint *b = binding_for(target);
    mgl_buffer *buf = b ? mgl_buffer_obj(*b) : NULL;
    if (!buf)
        mgl_set_error(GL_INVALID_OPERATION);
    return buf;
}

static mgl_buffer *ensure(GLuint name)
{
    mgl_buffer *b = mgl_buffer_obj(name);
    if (!b && name) {
        b = calloc(1, sizeof *b);
        mgl_table_set(&mgl->buffers, name, b);
    }
    return b;
}

void glGenBuffers(GLsizei n, GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        names[i] = mgl_table_gen(&mgl->buffers);
        mgl_table_set(&mgl->buffers, names[i], calloc(1, sizeof(mgl_buffer)));
    }
}

void glCreateBuffers(GLsizei n, GLuint *names) { glGenBuffers(n, names); }

void glDeleteBuffers(GLsizei n, const GLuint *names)
{
    for (GLsizei i = 0; i < n; i++) {
        mgl_buffer *b = mgl_buffer_obj(names[i]);
        if (!b)
            continue;
        if (b->mem)
            mglb_buffer_release(b->mem);
        free(b);
        mgl_table_remove(&mgl->buffers, names[i]);
        if (mgl->array_buffer == names[i])
            mgl->array_buffer = 0;
        if (mgl->uniform_buffer == names[i])
            mgl->uniform_buffer = 0;
    }
}

GLboolean glIsBuffer(GLuint name) { return mgl_buffer_obj(name) != NULL; }

void glBindBuffer(GLenum target, GLuint name)
{
    GLuint *b = binding_for(target);
    if (!b)
        return;
    ensure(name);
    *b = name;
}

void glBindBufferBase(GLenum target, GLuint index, GLuint name)
{
    glBindBufferRange(target, index, name, 0, 0);
}

void glBindBufferRange(GLenum target, GLuint index, GLuint name, GLintptr offset, GLsizeiptr size)
{
    ensure(name);
    if (target == GL_UNIFORM_BUFFER && index < MGL_MAX_UBO_BINDINGS) {
        mgl->ubo[index].buffer = name;
        mgl->ubo[index].offset = (size_t)offset;
        mgl->ubo[index].size = (size_t)size;
    } else if (target == GL_SHADER_STORAGE_BUFFER && index < MGL_MAX_SSBO_BINDINGS) {
        mgl->ssbo[index].buffer = name;
        mgl->ssbo[index].offset = (size_t)offset;
        mgl->ssbo[index].size = (size_t)size;
    } else if (target != GL_UNIFORM_BUFFER) {
        static int warned;
        if (!warned++)
            mgl_log("glBindBufferBase/Range target 0x%04X: indexed binding not supported yet", target);
    }
    glBindBuffer(target, name);
}

/* Every CPU write into buffer memory: ray-tracing caches (mgl_rt.c) and the geometry-shader output cache
   (mglb_buffer_written) key on buffer contents. */
static void note_write(mglb_buffer *m, size_t offset, size_t size)
{
    mglb_buffer_written(m);
    mgl_rt_note_write(m, offset, size);
}

/* All buffer memory comes from here, so ray-tracing caches keyed by it start fresh (mgl_rt.c). */
static mglb_buffer *new_mem(size_t size)
{
    mglb_buffer *m = mglb_buffer_new(size);
    note_write(m, 0, (size_t)-1);
    return m;
}

/* Fresh memory for b; keep the old contents when copy is set. */
static void rename_mem(mgl_buffer *b, int copy)
{
    mglb_buffer *fresh = new_mem(b->size ? b->size : 1);
    if (copy && b->mem)
        memcpy(mglb_buffer_ptr(fresh), mglb_buffer_ptr(b->mem), b->size);
    if (b->mem)
        mglb_buffer_release(b->mem);
    b->mem = fresh;
}

static void buffer_data(mgl_buffer *b, GLsizeiptr size, const void *data)
{
    if (b->immutable) {
        mgl_set_error(GL_INVALID_OPERATION);
        return;
    }
    if (b->mem && (size_t)size == b->size && !mglb_buffer_in_use(b->mem)) {
        /* same size and idle: reuse */
    } else {
        if (b->mem)
            mglb_buffer_release(b->mem);
        b->size = (size_t)size;
        b->mem = new_mem(b->size ? b->size : 1);
    }
    if (data && size)
        memcpy(mglb_buffer_ptr(b->mem), data, (size_t)size);
    note_write(b->mem, 0, (size_t)size);
}

void glBufferData(GLenum target, GLsizeiptr size, const void *data, GLenum usage)
{
    mgl_buffer *b = bound(target);
    if (b)
        buffer_data(b, size, data);
}

void glNamedBufferData(GLuint name, GLsizeiptr size, const void *data, GLenum usage)
{
    mgl_buffer *b = ensure(name);
    if (b)
        buffer_data(b, size, data);
}

static void buffer_storage(mgl_buffer *b, GLsizeiptr size, const void *data, GLbitfield flags)
{
    if (b->mem)
        mglb_buffer_release(b->mem);
    b->size = (size_t)size;
    b->mem = new_mem(b->size ? b->size : 1);
    b->storage_flags = flags;
    b->immutable = 1;
    if (data && size)
        memcpy(mglb_buffer_ptr(b->mem), data, (size_t)size);
}

void glBufferStorage(GLenum target, GLsizeiptr size, const void *data, GLbitfield flags)
{
    mgl_buffer *b = bound(target);
    if (b)
        buffer_storage(b, size, data, flags);
}

void glNamedBufferStorage(GLuint name, GLsizeiptr size, const void *data, GLbitfield flags)
{
    mgl_buffer *b = ensure(name);
    if (b)
        buffer_storage(b, size, data, flags);
}

static void buffer_sub_data(mgl_buffer *b, GLintptr offset, GLsizeiptr size, const void *data)
{
    if (!b->mem || (size_t)(offset + size) > b->size) {
        mgl_set_error(GL_INVALID_VALUE);
        return;
    }
    if (!(b->storage_flags & GL_MAP_PERSISTENT_BIT) && mglb_buffer_in_use(b->mem))
        rename_mem(b, (size_t)size != b->size);
    memcpy((char *)mglb_buffer_ptr(b->mem) + offset, data, (size_t)size);
    note_write(b->mem, (size_t)offset, (size_t)size);
}

void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void *data)
{
    mgl_buffer *b = bound(target);
    if (b)
        buffer_sub_data(b, offset, size, data);
}

void glNamedBufferSubData(GLuint name, GLintptr offset, GLsizeiptr size, const void *data)
{
    mgl_buffer *b = mgl_buffer_obj(name);
    if (b)
        buffer_sub_data(b, offset, size, data);
}

static void *map_range(mgl_buffer *b, GLintptr offset, GLsizeiptr length, GLbitfield access)
{
    if (!b->mem || (size_t)(offset + length) > b->size) {
        mgl_set_error(GL_INVALID_VALUE);
        return NULL;
    }
    if (!(access & (GL_MAP_PERSISTENT_BIT | GL_MAP_UNSYNCHRONIZED_BIT)) && !(b->storage_flags & GL_MAP_PERSISTENT_BIT) &&
        mglb_buffer_in_use(b->mem)) {
        if (access & GL_MAP_INVALIDATE_BUFFER_BIT)
            rename_mem(b, 0);
        else if (access & GL_MAP_WRITE_BIT)
            rename_mem(b, !(access & GL_MAP_INVALIDATE_RANGE_BIT) || (size_t)length != b->size);
        else
            mglb_finish(); /* reading: wait for the GPU */
    }
    if ((access | b->storage_flags) & GL_MAP_PERSISTENT_BIT)
        mglb_buffer_volatile(b->mem);
    b->mapped = 1;
    b->map_offset = (size_t)offset;
    b->map_length = (size_t)length;
    b->map_access = access;
    return (char *)mglb_buffer_ptr(b->mem) + offset;
}

void *glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access)
{
    mgl_buffer *b = bound(target);
    return b ? map_range(b, offset, length, access) : NULL;
}

void *glMapNamedBufferRange(GLuint name, GLintptr offset, GLsizeiptr length, GLbitfield access)
{
    mgl_buffer *b = mgl_buffer_obj(name);
    return b ? map_range(b, offset, length, access) : NULL;
}

void *glMapBuffer(GLenum target, GLenum access)
{
    mgl_buffer *b = bound(target);
    if (!b)
        return NULL;
    GLbitfield a = access == GL_READ_ONLY ? GL_MAP_READ_BIT : access == GL_WRITE_ONLY ? GL_MAP_WRITE_BIT
                                                                                      : GL_MAP_READ_BIT | GL_MAP_WRITE_BIT;
    return map_range(b, 0, (GLsizeiptr)b->size, a);
}

static GLboolean unmap(mgl_buffer *b)
{
    if (!b || !b->mapped) {
        mgl_set_error(GL_INVALID_OPERATION);
        return GL_FALSE;
    }
    b->mapped = 0;
    if (b->map_access & GL_MAP_WRITE_BIT)
        note_write(b->mem, b->map_offset, b->map_length);
    return GL_TRUE;
}

GLboolean glUnmapBuffer(GLenum target) { return unmap(bound(target)); }
GLboolean glUnmapNamedBuffer(GLuint name) { return unmap(mgl_buffer_obj(name)); }

/* Shared storage is coherent for the next command buffer, so explicit flushes need no work. */
void glFlushMappedBufferRange(GLenum target, GLintptr offset, GLsizeiptr length) {}
void glFlushMappedNamedBufferRange(GLuint name, GLintptr offset, GLsizeiptr length) {}

static void copy_sub_data(mgl_buffer *src, mgl_buffer *dst, GLintptr ro, GLintptr wo, GLsizeiptr size)
{
    if (!src || !dst || !src->mem || !dst->mem || (size_t)(ro + size) > src->size || (size_t)(wo + size) > dst->size) {
        mgl_set_error(GL_INVALID_VALUE);
        return;
    }
    /* CPU copy; if the destination is busy, rename it first so earlier draws keep the old data. */
    if (!(dst->storage_flags & GL_MAP_PERSISTENT_BIT) && mglb_buffer_in_use(dst->mem))
        rename_mem(dst, 1);
    memmove((char *)mglb_buffer_ptr(dst->mem) + wo, (char *)mglb_buffer_ptr(src->mem) + ro, (size_t)size);
    note_write(dst->mem, (size_t)wo, (size_t)size);
}

void glCopyBufferSubData(GLenum rt, GLenum wt, GLintptr ro, GLintptr wo, GLsizeiptr size)
{
    copy_sub_data(bound(rt), bound(wt), ro, wo, size);
}

void glCopyNamedBufferSubData(GLuint r, GLuint w, GLintptr ro, GLintptr wo, GLsizeiptr size)
{
    copy_sub_data(mgl_buffer_obj(r), mgl_buffer_obj(w), ro, wo, size);
}

static void get_param(mgl_buffer *b, GLenum pname, GLint *out)
{
    if (!b) {
        *out = 0;
        return;
    }
    switch (pname) {
    case GL_BUFFER_SIZE: *out = (GLint)b->size; break;
    case GL_BUFFER_MAPPED: *out = b->mapped; break;
    case GL_BUFFER_IMMUTABLE_STORAGE: *out = b->immutable; break;
    case GL_BUFFER_STORAGE_FLAGS: *out = (GLint)b->storage_flags; break;
    case GL_BUFFER_USAGE: *out = GL_DYNAMIC_DRAW; break;
    case GL_BUFFER_ACCESS_FLAGS: *out = (GLint)b->map_access; break;
    case GL_BUFFER_MAP_OFFSET: *out = (GLint)b->map_offset; break;
    case GL_BUFFER_MAP_LENGTH: *out = (GLint)b->map_length; break;
    default: *out = 0; mgl_log("glGetBufferParameteriv: pname 0x%04X", pname);
    }
}

void glGetBufferParameteriv(GLenum target, GLenum pname, GLint *out) { get_param(bound(target), pname, out); }
void glGetNamedBufferParameteriv(GLuint name, GLenum pname, GLint *out) { get_param(mgl_buffer_obj(name), pname, out); }

void glGetBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void *data)
{
    mgl_buffer *b = bound(target);
    if (!b || !b->mem)
        return;
    if (mglb_buffer_in_use(b->mem))
        mglb_finish();
    memcpy(data, (char *)mglb_buffer_ptr(b->mem) + offset, (size_t)size);
}

/* ---- glClearBuffer(Sub)Data: fill with one element. Assumes data is already laid out like internalformat,
   which is how packs call it (R32UI / RGBA32F with matching format/type, or NULL for zero). ---- */
static int element_size(GLenum internalformat)
{
    switch (internalformat) {
    case GL_R8: case GL_R8UI: case GL_R8I: return 1;
    case GL_R16: case GL_R16F: case GL_R16UI: case GL_R16I: case GL_RG8: case GL_RG8UI: return 2;
    case GL_RG32F: case GL_RG32UI: case GL_RG32I: case GL_RGBA16: case GL_RGBA16F: case GL_RGBA16UI: case GL_RGBA16I: return 8;
    case GL_RGB32F: case GL_RGB32UI: case GL_RGB32I: return 12;
    case GL_RGBA32F: case GL_RGBA32UI: case GL_RGBA32I: return 16;
    default: return 4;
    }
}

static void clear_sub_data(mgl_buffer *b, GLenum internalformat, size_t offset, size_t size, const void *data)
{
    if (!b->mem || offset + size > b->size) {
        mgl_set_error(GL_INVALID_VALUE);
        return;
    }
    if (!(b->storage_flags & GL_MAP_PERSISTENT_BIT) && mglb_buffer_in_use(b->mem))
        rename_mem(b, size != b->size);
    char *p = (char *)mglb_buffer_ptr(b->mem) + offset;
    size_t es = (size_t)element_size(internalformat);
    if (!data) {
        memset(p, 0, size);
        return;
    }
    for (size_t o = 0; o + es <= size; o += es)
        memcpy(p + o, data, es);
}

void glClearBufferSubData(GLenum target, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format,
                          GLenum type, const void *data)
{
    mgl_buffer *b = bound(target);
    if (b)
        clear_sub_data(b, internalformat, (size_t)offset, (size_t)size, data);
}

void glClearBufferData(GLenum target, GLenum internalformat, GLenum format, GLenum type, const void *data)
{
    mgl_buffer *b = bound(target);
    if (b)
        clear_sub_data(b, internalformat, 0, b->size, data);
}

void glClearNamedBufferSubData(GLuint name, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format,
                               GLenum type, const void *data)
{
    mgl_buffer *b = mgl_buffer_obj(name);
    if (b)
        clear_sub_data(b, internalformat, (size_t)offset, (size_t)size, data);
}

void glClearNamedBufferData(GLuint name, GLenum internalformat, GLenum format, GLenum type, const void *data)
{
    mgl_buffer *b = mgl_buffer_obj(name);
    if (b)
        clear_sub_data(b, internalformat, 0, b->size, data);
}
