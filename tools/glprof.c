/* glprof runtime: real-function lookup, clock, the once-a-second snapshot and (macOS) the frame hooks our GLFW
   calls. See glprof.h. */
#include "glprof.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static void *real_lib;
static pthread_once_t real_once = PTHREAD_ONCE_INIT;

static void open_real(void)
{
    const char *path = getenv("GLPROF_REAL");
#ifdef __APPLE__
    if (!path)
        path = "/System/Library/Frameworks/OpenGL.framework/OpenGL";
#else
    if (!path)
        path = "libGL.so.1";
#endif
    real_lib = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!real_lib)
        fprintf(stderr, "glprof: can't open %s: %s\n", path, dlerror());
}

#ifndef __APPLE__
static void *(*real_gpa)(const unsigned char *);
#endif

void *gp_real(const char *name)
{
    pthread_once(&real_once, open_real);
    if (!real_lib)
        return NULL;
    void *f = dlsym(real_lib, name);
#ifndef __APPLE__
    if (!real_gpa)
        real_gpa = (void *(*)(const unsigned char *))dlsym(real_lib, "glXGetProcAddressARB");
    if (!f && real_gpa)
        f = real_gpa((const unsigned char *)name);
#endif
    return f;
}

uint64_t gp_now(void)
{
#ifdef __APPLE__
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
#endif
}

/* frames (swaps) and the time spent inside swap, which includes waiting for the GPU and for a drawable */
static uint64_t start_ns, last_write, frames, swap_ns, swap_calls;

static void write_snapshot(uint64_t now)
{
    const char *out = getenv("GLPROF_OUT");
    if (!out)
        return;
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s.tmp", out);
    FILE *f = fopen(tmp, "w");
    if (!f)
        return;
    fprintf(f, "# glprof snapshot: name calls ns aux (totals since start)\n");
    fprintf(f, "@elapsed_ns %llu\n@frames %llu\n@swap %llu %llu 0\n", (unsigned long long)(now - start_ns),
            (unsigned long long)frames, (unsigned long long)swap_calls, (unsigned long long)swap_ns);
    for (int i = 0; i < gp_count; i++)
        if (gp_stats[i].calls)
            fprintf(f, "%s %llu %llu %llu\n", gp_names[i], (unsigned long long)gp_stats[i].calls,
                    (unsigned long long)gp_stats[i].ns, (unsigned long long)gp_stats[i].aux);
    fclose(f);
    rename(tmp, out);
}

void gp_tick(void)
{
    uint64_t now = gp_now();
    if (!start_ns)
        start_ns = last_write = now;
    if (now - last_write >= 1000000000u) {
        last_write = now;
        write_snapshot(now);
    }
}

#ifdef __APPLE__
/* our GLFW (glfw/mtl_context.m) dlsyms these from $MCMETAL_LIB: pass them on to libmcmetal, counting swaps */
#define HOOK(ret, name, params, args)                       \
    GP_EXPORT ret name params                               \
    {                                                       \
        static ret(*real) params;                           \
        if (!real)                                          \
            real = (ret(*) params)gp_real(#name);           \
        return real args;                                   \
    }
HOOK(void *, mgl_glfw_create, (void *layer), (layer))
HOOK(void, mgl_glfw_make_current, (void *ctx), (ctx))
HOOK(void, mgl_glfw_swap_interval, (void *ctx, int interval), (ctx, interval))
HOOK(void, mgl_glfw_destroy, (void *ctx), (ctx))

/* mcmetal's own entry point for the mod's GPU chunk culling (core/mgl_cull.c); 0 = draw normally */
GP_EXPORT int64_t mcmGpuCull(const void *cmd)
{
    static int64_t (*real)(const void *);
    if (!real)
        real = (int64_t(*)(const void *))gp_real("mcmGpuCull");
    return real ? real(cmd) : 0;
}

GP_EXPORT void mgl_glfw_swap(void *ctx)
{
    static void (*real)(void *);
    if (!real)
        real = (void (*)(void *))gp_real("mgl_glfw_swap");
    uint64_t t0 = gp_now();
    real(ctx);
    swap_ns += gp_now() - t0;
    swap_calls++;
    frames++;
    gp_tick();
}
#else
void *gp_wrapper(const char *name);
GP_EXPORT void *glXGetProcAddressARB(const unsigned char *name)
{
    void *w = gp_wrapper((const char *)name);
    if (w)
        return w;
    if (!real_gpa)
        gp_real("glGetString");
    return real_gpa ? real_gpa(name) : NULL;
}
GP_EXPORT void *glXGetProcAddress(const unsigned char *name) { return glXGetProcAddressARB(name); }
#endif
