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

uniform sampler2D colortex0, colortex1, colortex5, colortex8, colortex11, depthtex0, depthtex1;

#ifdef DISTANT_HORIZONS
uniform sampler2D dhDepthTex0;
uniform mat4 dhProjectionInverse;
uniform int dhRenderDistance;   // blocks (Iris provides an int)
#endif

in vec2 texcoord;

#if defined CAUSTICS && defined USE_RT
    #include "/lib/caustics.glsl"
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
    float fogEnd = far;
#ifdef DISTANT_HORIZONS
    // Distant Horizons: the world goes on past the real chunks (dh_terrain), so fog uses the LOD's depth and range
    fogEnd = max(float(dhRenderDistance), far);
    float dhDepth = texture(dhDepthTex0, texcoord).r;
    if (depth >= 1.0 && dhDepth < 1.0) {
        vec4 vd = dhProjectionInverse * vec4(vec3(texcoord, dhDepth) * 2.0 - 1.0, 1.0);
        p = mat3(gbufferModelViewInverse) * (vd.xyz / vd.w);
        dist = length(p);
        depth = 0.999999;   // fogged like terrain below, not left as sky
    }
#endif

#if defined CAUSTICS && defined USE_RT
    // under water: seen through the water surface, or with the camera itself in water
    float depth1 = texture(depthtex1, texcoord).r;
    bool throughWater = isEyeInWater == 0 && depth1 > depth && texture(colortex11, texcoord).r > 0.5;
    if ((throughWater || isEyeInWater == 1) && depth1 < 1.0) {
        vec4 v1 = gbufferProjectionInverse * vec4(vec3(texcoord, depth1) * 2.0 - 1.0, 1.0);
        vec3 p1 = mat3(gbufferModelViewInverse) * (v1.xyz / v1.w);
        // only where the sun reaches (the traced shadow from deferred1.fsh), fading out in deep water
        // (lit or not: the shadow ray already passed the water surface, whose tint makes the value itself small)
        vec3 sh5 = texture(colortex5, texcoord).rgb;
        float sun = smoothstep(0.01, 0.08, max(sh5.r, max(sh5.g, sh5.b))) * smoothstep(-0.02, 0.15, sunDir.y);
        float deep = throughWater ? exp(-(length(p1) - dist) * 0.04) : 1.0;
        float c = caustics(p1 + cameraPosition, sunDir, frameTimeCounter);
        // focused lines brighter, the gaps between them darker (about the same light overall)
        // walls catch the lines at a slant: softer there than on the floor
        float facing = mix(0.45, 1.0, max(octDecode(texture(colortex1, texcoord).xy).y, 0.0));
        col *= mix(1.0, 0.45 + 2.75 * c, min(CAUSTICS_STRENGTH * sun * deep * facing, 1.0));
  #if DEBUG_VIEW == 7
        col = vec3(c, float(throughWater), sun);
  #endif
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
        // hide the edge of the loaded world (chunks load in a column round the player: measured across, not up/down,
        // or high up the ground below would all count as past the edge)
        float edge = smoothstep(fogEnd * 0.8, fogEnd, length(p.xz));
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
