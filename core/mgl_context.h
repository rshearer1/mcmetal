/* Per-context state shared by the GL front end. One context for now (Minecraft uses one render thread). */
#pragma once
#include "mgl_gl.h"

const char *mgl_renderer_name(void);          /* "<GPU name> (Metal)"; from the Metal backend */
void mgl_set_error(GLenum err);               /* keeps the first error until glGetError */
GLenum mgl_take_error(void);
int mgl_get_state_integer(GLenum pname, GLint *out); /* bindings and other state; 0 if unknown */
