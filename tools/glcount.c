/* glcount: a counting stand-in for Apple's OpenGL, to compare what Iris and Sodium draw on real OpenGL with what they
   draw on mcmetal. Built as a dylib that re-exports OpenGL.framework and overrides only the draw calls and
   glViewport; load it with -Dorg.lwjgl.opengl.libname=libglcount.dylib (mcmetal off: MCMETAL_DISABLE=1).
   Once a second it appends to $GLCOUNT_LOG: draw calls and triangles, all and those into square viewports of
   1024 or more (shadow maps).

   clang -dynamiclib -o libglcount.dylib tools/glcount.c -framework OpenGL -Wl,-reexport_framework,OpenGL
   Linux (Mesa, for the cloud reference rig): gcc -shared -fPIC -o libglcount.so tools/glcount.c -lGL -ldl
   (LWJGL finds GL functions through glXGetProcAddress there, so that is answered here too). */
#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/* own declarations: Apple's headers declare some of these with other const-ness */
typedef unsigned int GLenum, GLuint;
typedef int GLint, GLsizei;
#define GL_TRIANGLES 0x0004
#define GL_TRIANGLE_STRIP 0x0005
#define GL_TRIANGLE_FAN 0x0006

static GLint vp_w, vp_h;
static unsigned long draws, tris, sh_draws, sh_tris, sh_passes; /* passes: runs of shadow-sized draws (one a frame) */
static int in_shadow;
static double last;

static void tick(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    double now = t.tv_sec + t.tv_nsec * 1e-9;
    if (!last)
        last = now;
    if (now - last < 1.0)
        return;
    const char *path = getenv("GLCOUNT_LOG");
    FILE *f = path ? fopen(path, "a") : NULL;
    if (f) {
        fprintf(f, "glcount: per second %lu draws %lu triangles; shadow-sized viewports %lu draws %lu triangles in %lu "
                "passes (%.0fk triangles a pass)\n", draws, tris, sh_draws, sh_tris, sh_passes,
                sh_passes ? sh_tris * 1e-3 / sh_passes : 0.0);
        fclose(f);
    }
    draws = tris = sh_draws = sh_tris = sh_passes = 0;
    last = now;
}

static void count(GLenum mode, long n, long instances)
{
    long t = mode == GL_TRIANGLES ? n / 3 : mode == GL_TRIANGLE_STRIP || mode == GL_TRIANGLE_FAN ? (n > 2 ? n - 2 : 0) : 0;
    t *= instances > 0 ? instances : 1;
    draws++;
    tris += (unsigned long)t;
    int sh = vp_w == vp_h && vp_w >= 1024;
    if (sh && !in_shadow)
        sh_passes++;
    in_shadow = sh;
    if (sh) {
        sh_draws++;
        sh_tris += (unsigned long)t;
    }
    tick();
}

#ifdef __APPLE__
static void *real_lib(void) { return RTLD_NEXT; }
#else
static void *real_lib(void) /* RTLD_NEXT doesn't reach a dependency of a library LWJGL dlopens privately */
{
    static void *h;
    if (!h)
        h = dlopen("libGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    return h;
}
#endif

#define REAL(name, ret, args) \
    static ret(*real_##name) args; \
    if (!real_##name) real_##name = (ret(*) args)dlsym(real_lib(), #name)

void glViewport(GLint x, GLint y, GLsizei w, GLsizei h)
{
    REAL(glViewport, void, (GLint, GLint, GLsizei, GLsizei));
    vp_w = w;
    vp_h = h;
    real_glViewport(x, y, w, h);
}

void glDrawArrays(GLenum m, GLint first, GLsizei n)
{
    REAL(glDrawArrays, void, (GLenum, GLint, GLsizei));
    count(m, n, 1);
    real_glDrawArrays(m, first, n);
}

void glDrawArraysInstanced(GLenum m, GLint first, GLsizei n, GLsizei inst)
{
    REAL(glDrawArraysInstanced, void, (GLenum, GLint, GLsizei, GLsizei));
    count(m, n, inst);
    real_glDrawArraysInstanced(m, first, n, inst);
}

void glDrawElements(GLenum m, GLsizei n, GLenum type, const void *ind)
{
    REAL(glDrawElements, void, (GLenum, GLsizei, GLenum, const void *));
    count(m, n, 1);
    real_glDrawElements(m, n, type, ind);
}

void glDrawElementsInstanced(GLenum m, GLsizei n, GLenum type, const void *ind, GLsizei inst)
{
    REAL(glDrawElementsInstanced, void, (GLenum, GLsizei, GLenum, const void *, GLsizei));
    count(m, n, inst);
    real_glDrawElementsInstanced(m, n, type, ind, inst);
}

void glDrawElementsBaseVertex(GLenum m, GLsizei n, GLenum type, void *ind, GLint bv)
{
    REAL(glDrawElementsBaseVertex, void, (GLenum, GLsizei, GLenum, void *, GLint));
    count(m, n, 1);
    real_glDrawElementsBaseVertex(m, n, type, ind, bv);
}

void glDrawRangeElements(GLenum m, GLuint s, GLuint e, GLsizei n, GLenum type, const void *ind)
{
    REAL(glDrawRangeElements, void, (GLenum, GLuint, GLuint, GLsizei, GLenum, const void *));
    count(m, n, 1);
    real_glDrawRangeElements(m, s, e, n, type, ind);
}

void glMultiDrawElements(GLenum m, const GLsizei *n, GLenum type, const void *const *ind, GLsizei k)
{
    REAL(glMultiDrawElements, void, (GLenum, const GLsizei *, GLenum, const void *const *, GLsizei));
    for (GLsizei i = 0; i < k; i++)
        count(m, n[i], 1);
    real_glMultiDrawElements(m, n, type, ind, k);
}

void glMultiDrawElementsBaseVertex(GLenum m, const GLsizei *n, GLenum type, void *const *ind, GLsizei k, const GLint *bv)
{
    REAL(glMultiDrawElementsBaseVertex, void, (GLenum, const GLsizei *, GLenum, void *const *, GLsizei, const GLint *));
    for (GLsizei i = 0; i < k; i++)
        count(m, n[i], 1);
    real_glMultiDrawElementsBaseVertex(m, n, type, ind, k, bv);
}

#ifndef __APPLE__
static void *own(const char *n)
{
    static const char *names[] = {"glViewport", "glDrawArrays", "glDrawArraysInstanced", "glDrawElements",
                                  "glDrawElementsInstanced", "glDrawElementsBaseVertex", "glDrawRangeElements",
                                  "glMultiDrawElements", "glMultiDrawElementsBaseVertex"};
    static void *fns[] = {(void *)glViewport, (void *)glDrawArrays, (void *)glDrawArraysInstanced, (void *)glDrawElements,
                          (void *)glDrawElementsInstanced, (void *)glDrawElementsBaseVertex, (void *)glDrawRangeElements,
                          (void *)glMultiDrawElements, (void *)glMultiDrawElementsBaseVertex};
    for (unsigned i = 0; i < sizeof names / sizeof *names; i++)
        if (!strcmp(n, names[i]))
            return fns[i];
    return NULL;
}

void *glXGetProcAddress(const unsigned char *n)
{
    REAL(glXGetProcAddress, void *, (const unsigned char *));
    void *f = own((const char *)n);
    return f ? f : real_glXGetProcAddress(n);
}

void *glXGetProcAddressARB(const unsigned char *n)
{
    REAL(glXGetProcAddressARB, void *, (const unsigned char *));
    void *f = own((const char *)n);
    return f ? f : real_glXGetProcAddressARB(n);
}
#endif
