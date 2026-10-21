#include "mgl_context.h"

static GLenum pending_error = GL_NO_ERROR;

void mgl_set_error(GLenum err)
{
    if (pending_error == GL_NO_ERROR)
        pending_error = err;
}

GLenum mgl_take_error(void)
{
    GLenum e = pending_error;
    pending_error = GL_NO_ERROR;
    return e;
}

/* Overridden by the Metal backend on macOS. */
__attribute__((weak)) const char *mgl_renderer_name(void)
{
    return "mcmetal (no Metal device)";
}
