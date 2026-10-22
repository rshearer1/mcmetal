/* Identity, version, extension list and limits that LWJGL, Minecraft, Sodium and Iris ask for. */
#include <string.h>
#include "mgl_gl.h"
#include "mgl_log.h"
#include "mgl_context.h"

static const char *const extensions[] = {
    "GL_ARB_buffer_storage",
    "GL_ARB_compute_shader",
    "GL_ARB_direct_state_access",
    "GL_ARB_multi_draw_indirect",
    "GL_ARB_shader_image_load_store",
    "GL_EXT_shader_image_load_store", /* Bliss gates its LPV coloured light on MC_GL_EXT_shader_image_load_store */
    "GL_ARB_draw_buffers_blend",
    "GL_ARB_texture_storage",
    "GL_ARB_sampler_objects",
    "GL_ARB_copy_image",
    "GL_ARB_separate_shader_objects",
    "GL_ARB_explicit_attrib_location",
    "GL_ARB_clear_texture",
    "GL_KHR_debug",
};
#define NUM_EXTENSIONS ((GLint)(sizeof(extensions) / sizeof(extensions[0])))

const GLubyte *glGetString(GLenum name)
{
    switch (name) {
    case GL_VENDOR:                   return (const GLubyte *)"mcmetal";
    case GL_RENDERER:                 return (const GLubyte *)mgl_renderer_name();
    case GL_VERSION:                  return (const GLubyte *)"4.5.0 Core Profile mcmetal 0.1";
    case GL_SHADING_LANGUAGE_VERSION: return (const GLubyte *)"4.50 mcmetal";
    }
    mgl_set_error(GL_INVALID_ENUM);
    return NULL;
}

const GLubyte *glGetStringi(GLenum name, GLuint index)
{
    if (name == GL_EXTENSIONS && index < (GLuint)NUM_EXTENSIONS)
        return (const GLubyte *)extensions[index];
    mgl_set_error(name == GL_EXTENSIONS ? GL_INVALID_VALUE : GL_INVALID_ENUM);
    return NULL;
}

/* Limits chosen to be within Apple9 GPU limits (Metal feature set tables). */
static int limit(GLenum pname, GLint *out)
{
    switch (pname) {
    case GL_MAJOR_VERSION:                     *out = 4; return 1;
    case GL_MINOR_VERSION:                     *out = 5; return 1;
    case GL_NUM_EXTENSIONS:                    *out = NUM_EXTENSIONS; return 1;
    case GL_CONTEXT_PROFILE_MASK:              *out = GL_CONTEXT_CORE_PROFILE_BIT; return 1;
    case GL_CONTEXT_FLAGS:                     *out = GL_CONTEXT_FLAG_FORWARD_COMPATIBLE_BIT; return 1;
    case GL_MAX_TEXTURE_SIZE:                  *out = 16384; return 1;
    case GL_MAX_3D_TEXTURE_SIZE:               *out = 2048; return 1;
    case GL_MAX_ARRAY_TEXTURE_LAYERS:          *out = 2048; return 1;
    case GL_MAX_TEXTURE_IMAGE_UNITS:           *out = 31; return 1;
    case GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS:  *out = 96; return 1;
    case GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS:    *out = 31; return 1;
    case GL_MAX_DRAW_BUFFERS:                  *out = 8; return 1;
    case GL_MAX_COLOR_ATTACHMENTS:             *out = 8; return 1;
    case GL_MAX_VERTEX_ATTRIBS:                *out = 31; return 1;
    case GL_MAX_RENDERBUFFER_SIZE:             *out = 16384; return 1;
    case GL_MAX_VIEWPORT_DIMS:                 out[0] = out[1] = 16384; return 1;
    case GL_MAX_UNIFORM_BLOCK_SIZE:            *out = 65536; return 1;
    case GL_MAX_IMAGE_UNITS:                   *out = 8; return 1;
    case GL_MAX_COMPUTE_SHARED_MEMORY_SIZE:    *out = 32768; return 1;
    case GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS:*out = 1024; return 1;
    case GL_MAX_SAMPLES:                       *out = 8; return 1;
    case GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT:   *out = 256; return 1;
    case GL_MAX_ELEMENTS_VERTICES:             *out = 1 << 20; return 1;
    case GL_MAX_ELEMENTS_INDICES:              *out = 1 << 20; return 1;
    }
    return 0;
}

void glGetIntegerv(GLenum pname, GLint *data)
{
    if (limit(pname, data) || mgl_get_state_integer(pname, data))
        return;
    static GLenum said[32]; /* once per pname: some callers ask every frame */
    static int nsaid;
    int known = 0;
    for (int i = 0; i < nsaid; i++)
        known |= said[i] == pname;
    if (!known) {
        if (nsaid < 32)
            said[nsaid++] = pname;
        mgl_log("glGetIntegerv: unknown pname 0x%04X, returning 0", pname);
    }
    *data = 0;
}

GLenum glGetError(void)
{
    return mgl_take_error();
}
