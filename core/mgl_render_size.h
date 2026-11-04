/* The size the game renders at, shared by libmcmetal (update_size in mac/mgl_metal.m) and the patched GLFW
   (the framebuffer size it reports, see build_mac.sh), so both always agree to the pixel.

   native: the window in pixels as the layer shows it (points x the layer's contentsScale), scale: that
   contentsScale. The game renders smaller than native, and MetalFX upscales to the window, when:
   - MCMETAL_UPSCALE=1/2 on a Retina screen: MCMETAL_UPSCALE_SCALE % of native each way (34-100, default 50);
   - the render cap: native has more pixels than MCMETAL_RENDER_CAP allows (default 1440 = as many pixels as
     2560x1440; the shape stays the window's). Big Retina and scaled external screens are 5-8K behind the scenes
     (a 4K screen set to "looks like 2560x1440" is 5120x2880) and nobody needs Minecraft drawn at that size.
     Up to a quarter over the cap stays native. 0 = no cap. The cap never goes below 34% of native each way
     (MetalFX's limit is 3x). */
#ifndef MGL_RENDER_SIZE_H
#define MGL_RENDER_SIZE_H

#include <math.h>
#include <stdlib.h>

/* MCMETAL_RENDER_CAP in 16:9 lines (1440 = 2560x1440 worth of pixels), 0 = off; at least 360 */
static inline int mgl_render_cap(void)
{
    const char *e = getenv("MCMETAL_RENDER_CAP");
    if (!e || !*e)
        return 1440;
    int v = atoi(e);
    return v <= 0 ? 0 : v < 360 ? 360 : v;
}

/* MCMETAL_UPSCALE's own render scale in %, or 0 when that's off */
static inline int mgl_upscale_pct(void)
{
    const char *up = getenv("MCMETAL_UPSCALE");
    if (!up || atoi(up) <= 0)
        return 0;
    const char *e = getenv("MCMETAL_UPSCALE_SCALE");
    int pct = e ? atoi(e) : 50;
    return pct < 34 ? 34 : pct > 100 ? 100 : pct;
}

/* Render size for a native size; returns 1 when that is below native (MetalFX upscales), 0 when native. */
static inline int mgl_render_size(double native_w, double native_h, double scale, int *w, int *h)
{
    double f = 1;
    int pct = mgl_upscale_pct();
    if (pct && scale > 1)
        f = pct / 100.0;
    int cap = mgl_render_cap();
    if (cap) {
        double budget = (double)cap * floor(cap * 16.0 / 9.0 + 0.5);
        /* a screen up to a quarter over the cap (an M2 Air's 2560x1664) isn't worth an upscale pass */
        if (native_w * f * native_h * f > budget * (f < 1 ? 1.0 : 1.25)) {
            f = sqrt(budget / (native_w * native_h));
            if (f < 0.34)
                f = 0.34;
        }
    }
    *w = (int)floor(native_w * f);
    *h = (int)floor(native_h * f);
    if (*w < 1)
        *w = 1;
    if (*h < 1)
        *h = 1;
    return *w < (int)native_w || *h < (int)native_h;
}

#endif
