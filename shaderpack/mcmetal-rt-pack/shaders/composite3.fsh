#version 330 compatibility
// Auto exposure, like an eye or a camera: meter the average brightness of the picture (log average of 64 spots
// from a small mip level), adapt to it over about a second. Kept within 4x of what the time of day suggests, so
// a dark room gets brighter but caves never turn into daylight, and bright spots in a dark view aren't blown out.
/*
const bool colortex0MipmapEnabled = true;   // metered from the small mip levels
const int colortex6Format = R32F;
const bool colortex6Clear = false;
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"

uniform sampler2D colortex0, colortex6, depthtex0;

in vec2 texcoord;
flat in float keyExposure;

/* RENDERTARGETS: 6 */
layout(location = 0) out vec4 outExposure;

void main() {
    // only the corner pixel is read back (final.fsh); colortex6 is 1x1 (shaders.properties), this guards bigger ones
    if (gl_FragCoord.x > 1.0 || gl_FragCoord.y > 1.0) { outExposure = vec4(0.0); return; }
    float logSum = 0.0, wSum = 0.0, peak = 0.0;
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 8; x++) {
            vec2 uv = (vec2(x, y) + 0.5) / 8.0;
            float w = 1.0 - 0.6 * length(uv - 0.5);   // the middle of the screen counts more
            float l = luma(textureLod(colortex0, uv, 5.0).rgb);
            // the sky counts much less, and never as the brightest spot: an eye looking at a sunlit hill under a
            // bright sky sees the hill, it doesn't stop down for the sky (that made daylight ground far too dark)
            bool sky = textureLod(depthtex0, uv, 0.0).r >= 1.0;
            if (sky) w *= 0.25;
            logSum += log(max(l, 1e-4)) * w;
            if (!sky) peak = max(peak, l * w);
            wSum += w;
        }
    float avg = exp(logSum / wSum);
    float target = clamp(0.18 / avg, keyExposure * 0.25, keyExposure * 4.0);
    // highlight guard: a lit room under a black night sky averages dark, which would blow the room out. Never brighten
    // past the point where the brightest metered spot lands well above white (ACES rolls it off from there). It only
    // takes back the eye's extra brightening and at most half of the time of day's own exposure, so a bright stage
    // at night tones down without the night around it going pitch black.
    target = max(min(target, 2.0 / max(peak, 1e-4)), min(target, keyExposure * 0.5));
    float prev = texelFetch(colortex6, ivec2(0), 0).r;
    float e = prev > 0.0 && prev < 1e4 ? mix(prev, target, 1.0 - exp(-frameTime * 1.5)) : target;
    outExposure = vec4(mix(keyExposure, e, AUTO_EXPOSURE), 0.0, 0.0, 1.0);
}
