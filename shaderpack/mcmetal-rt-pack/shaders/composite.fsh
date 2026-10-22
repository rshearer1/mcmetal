#version 330 compatibility
// Fog over everything (after water and glass): air haze towards the sky colour, a soft edge at the render
// distance, and fog under water / in lava / in powder snow.
/*
const int colortex11Format = R8;   // 1 where the nearest see-through surface is water (gbuffers_water)
const bool colortex11Clear = true;
const vec4 colortex11ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"

uniform sampler2D colortex0, colortex5, colortex8, colortex11, depthtex0, depthtex1;

in vec2 texcoord;

#if defined CAUSTICS && defined USE_RT
// Caustics: waves focus sunlight into a moving net of bright lines on whatever lies under the water. The lines are
// the ridges of two layers of drifting, warped value noise (where the noise crosses its middle value).
float caustics(vec3 w, float t) {
    vec2 uv = w.xz + w.y * vec2(0.37, 0.21);   // walls get lines too, not vertical stripes
    float c = 0.0;
    for (int i = 0; i < 2; i++) {
        float s = i == 0 ? 0.9 : 1.7;
        vec2 q = uv * s + vec2(0.3, -0.21) * t * float(i + 1);
        q += (vec2(valueNoise(q * 0.8 + t * 0.2), valueNoise(q * 0.8 + 7.1 - t * 0.17)) - 0.5) * 1.6;
        float r = 1.0 - abs(valueNoise(q * 1.3) * 2.0 - 1.0);
        c += pow(r, 8.0) * (i == 0 ? 0.65 : 0.35);
    }
    return c;
}
#endif
flat in vec3 sunCol, skyAmb, sunDir;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    vec3 col = texture(colortex0, texcoord).rgb;
    float depth = texture(depthtex0, texcoord).r;
    vec4 v = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
    vec3 p = mat3(gbufferModelViewInverse) * (v.xyz / v.w);
    float dist = length(p);

#if defined CAUSTICS && defined USE_RT
    // under water: seen through the water surface, or with the camera itself in water
    float depth1 = texture(depthtex1, texcoord).r;
    bool throughWater = isEyeInWater == 0 && depth1 > depth && texture(colortex11, texcoord).r > 0.5;
    if ((throughWater || isEyeInWater == 1) && depth1 < 1.0) {
        vec4 v1 = gbufferProjectionInverse * vec4(vec3(texcoord, depth1) * 2.0 - 1.0, 1.0);
        vec3 p1 = mat3(gbufferModelViewInverse) * (v1.xyz / v1.w);
        // only where the sun reaches (the traced shadow from deferred1.fsh), fading out in deep water
        float sun = luma(texture(colortex5, texcoord).rgb) * smoothstep(-0.02, 0.15, sunDir.y);
        float deep = throughWater ? exp(-(length(p1) - dist) * 0.12) : 1.0;
        col *= 1.0 + 1.5 * CAUSTICS_STRENGTH * caustics(p1 + cameraPosition, frameTimeCounter) * sun * deep;
    }
#endif
    if (isEyeInWater == 1) {
        vec3 waterFog = vec3(0.02, 0.09, 0.12) * (skyAmb * 0.3 + sunCol * 0.1);
        col = mix(col, waterFog, 1.0 - exp(-dist * 0.07));
    } else if (isEyeInWater == 2) {
        col = mix(col, vec3(1.2, 0.3, 0.02), 1.0 - exp(-dist * 1.5));
    } else if (isEyeInWater == 3) {
        col = mix(col, vec3(0.6, 0.7, 0.8) * (skyAmb * 0.4), 1.0 - exp(-dist * 2.0));
    } else if (depth < 1.0) {
        float haze = (1.0 - exp(-dist * 0.0012 * FOG_DENSITY * (1.0 + 5.0 * rainStrength)));
        float edge = smoothstep(far * 0.8, far, dist);   // hide the edge of the loaded world
        float amount = max(haze, edge) * smoothstep(0.0, 0.2, float(eyeBrightnessSmooth.y) / 240.0 + edge);
        if (amount > 0.001) col = mix(col, skyColor(p / dist, sunDir), amount);
    }
#if defined USE_RT && defined LIGHT_SHAFTS
    if (isEyeInWater <= 1) col += texture(colortex8, texcoord * LIGHT_SHAFTS_SCALE).rgb;   // deferred3.fsh
#endif
#if DEBUG_VIEW == 5 && defined USE_RT && defined LIGHT_SHAFTS
    { vec3 ls = texture(colortex8, texcoord * LIGHT_SHAFTS_SCALE).rgb * 4.0; col = ls / (ls + 1.0); }
#endif
    col *= 1.0 - max(blindness, darknessFactor) * smoothstep(2.0, 12.0, dist);
    outColor = vec4(col, 1.0);
}
