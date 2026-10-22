/* glprof: a GL call profiler between the game and the real GL library (libmcmetal on macOS, Mesa's libGL on
   Linux). Each GL entry point is wrapped (build/gen/glprof_gen.c, made by gen/gen_glprof.py): calls, CPU time
   inside the call and one size figure are summed per function. Once a second the totals since start go to
   $GLPROF_OUT (rewritten in place), so two copies taken at the start and end of a measuring window give exact
   per-frame numbers: python3 -I tools/glprof_report.py START END.

   macOS:  -Dorg.lwjgl.opengl.libname=libglprof-mcmetal.dylib, MCMETAL_LIB=libglprof-mcmetal.dylib (our GLFW
           takes its mgl_glfw_* hooks from there, so frames and the time spent in swap are counted too) and
           GLPROF_REAL=libmcmetal.dylib. ci_game.sh does this for GAME_GLPROF=true.
   GLPROF_FRAMES=FILE (macOS): one line per frame, "end_wall_ms frame_us gl_us swap_us": what each frame's time
           went to (the rest is Java and everything else on the render thread), for tools/slow_frames.py.
   Linux:  -Dorg.lwjgl.opengl.libname=libglprof.so, GLPROF_REAL=libGL.so.1 (no frame count: swaps go through GLX). */
#pragma once
#include <stdint.h>
#include <string.h>
#include "mgl_gl.h"
typedef unsigned int GLhandleARB; /* left out of mgl_gl.h; only old ARB shader-object calls use it */

#define GP_EXPORT __attribute__((visibility("default")))

typedef struct gp_stat {
    uint64_t calls, ns, aux;
} gp_stat;

extern const char *const gp_names[];
extern const int gp_count;
extern gp_stat gp_stats[];

void *gp_real(const char *name);
uint64_t gp_now(void);
void gp_tick(void);
extern uint64_t gp_frame_ns; /* time inside GL calls since the last swap (GLPROF_FRAMES) */

#define GP_REAL(n) \
    if (!real_##n) real_##n = gp_real(#n)

static inline void gp_add(int i, uint64_t t0, long aux)
{
    gp_stat *s = &gp_stats[i];
    uint64_t dt = gp_now() - t0;
    s->calls++;
    s->ns += dt;
    gp_frame_ns += dt;
    s->aux += (uint64_t)(aux > 0 ? aux : 0);
    static unsigned n;
    if (!(++n & 4095))
        gp_tick();
}
