/* glcount: a counting stand-in for Apple's OpenGL, to compare what Iris and Sodium draw on real OpenGL with what they
   draw on mcmetal. Built as a dylib that re-exports OpenGL.framework and overrides only the draw calls and
   glViewport; load it with -Dorg.lwjgl.opengl.libname=libglcount.dylib (mcmetal off: MCMETAL_DISABLE=1).
   Once a second it appends to $GLCOUNT_LOG: draw calls and triangles, all and those into square viewports of
   1024 or more (shadow maps).

   clang -dynamiclib -o libglcount.dylib tools/glcount.c -framework OpenGL -Wl,-reexport_framework,OpenGL */
#include <dlfcn.h>
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
static unsigned long draws, tris, sh_draws, sh_tris;
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
        fprintf(f, "glcount: per second %lu draws %lu triangles; shadow-sized viewports %lu draws %lu triangles\n", draws,
                tris, sh_draws, sh_tris);
        fclose(f);
    }
    draws = tris = sh_draws = sh_tris = 0;
    last = now;
}

static void count(GLenum mode, long n, long instances)
{
    long t = mode == GL_TRIANGLES ? n / 3 : mode == GL_TRIANGLE_STRIP || mode == GL_TRIANGLE_FAN ? (n > 2 ? n - 2 : 0) : 0;
    t *= instances > 0 ? instances : 1;
    draws++;
    tris += (unsigned long)t;
    if (vp_w == vp_h && vp_w >= 1024) {
        sh_draws++;
        sh_tris += (unsigned long)t;
    }
    tick();
}

#define REAL(name, ret, args) \
    static ret(*real_##name) args; \
    if (!real_##name) real_##name = (ret(*) args)dlsym(RTLD_NEXT, #name)

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
