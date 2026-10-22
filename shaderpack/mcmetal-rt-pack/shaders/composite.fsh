#version 330 compatibility
// Fog over everything (after water and glass): air haze towards the sky colour, a soft edge at the render
// distance, and fog under water / in lava / in powder snow.
/*
const int colortex11Format = RGBA8;   // r water, gb glass refraction offset, a glass: nearest see-through surface
const bool colortex11Clear = true;
const vec4 colortex11ClearColor = vec4(0.0, 0.5, 0.5, 0.0);
const int colortex13Format = RGBA16F;   // light from see-through surfaces themselves, added here
const bool colortex13Clear = true;
const vec4 colortex13ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"

uniform sampler2D colortex0, colortex1, colortex5, colortex8, colortex11, colortex13, depthtex0, depthtex1;

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

#ifdef STYLE_OUTLINE
float linDepth(float d) { return 2.0 * near * far / (far + near - (d * 2.0 - 1.0) * (far - near)); }
#endif

void main() {
    // what's behind see-through blocks (already dimmed or tinted by them) plus their own light (gbuffers_water)
    vec4 wm = texture(colortex11, texcoord);
    vec3 col = texture(colortex0, texcoord).rgb;
#ifdef GLASS_REFRACTION
    if (wm.a > 0.5) {
        // glass bends the view: take what's behind from a little to the side (only if that's behind glass too)
        vec2 ruv = clamp(texcoord + (wm.gb - 0.5) / 8.0, 0.0, 1.0);
        if (texture(colortex11, ruv).a > 0.5) col = texture(colortex0, ruv).rgb;
    }
#endif
    col += texture(colortex13, texcoord).rgb;
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

#ifdef STYLE_OUTLINE
    // Storybook ink: a line where the depth jumps (silhouettes) or the surface turns (block edges), scene-tinted,
    // fading out with distance so far terrain doesn't turn to scribble
    if (depth < 1.0 && dist > 1.5) {
        vec2 px = 1.0 / vec2(viewWidth, viewHeight);
        float lc = linDepth(depth);
        vec3 nc = octDecode(texture(colortex1, texcoord).xy);
        float edge = 0.0;
        for (int i = 0; i < 4; i++) {
            vec2 o = (i == 0 ? vec2(1.0, 0.0) : i == 1 ? vec2(-1.0, 0.0) : i == 2 ? vec2(0.0, 1.0) : vec2(0.0, -1.0)) * px;
            float d = texture(depthtex0, texcoord + o).r;
            float ln = d >= 1.0 ? far * 4.0 : linDepth(d);
            if (lc - ln > 0.03 * lc + 0.15) edge = 1.0;                            // something in front: outline it
            if (d < 1.0 && dot(nc, octDecode(texture(colortex1, texcoord + o).xy)) < 0.7) edge = max(edge, 0.7);
        }
        col *= 1.0 - 0.75 * edge * (1.0 - smoothstep(40.0, 90.0, dist));
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
        float haze = (1.0 - exp(-dist * 0.0012 * FOG_DENSITY * STYLE_FOG * (1.0 + 5.0 * rainStrength)));
  #if STYLE == 1 || STYLE == 2 || STYLE == 4
        // low mist that sits in valleys and over water (thickest below about sea level + 4)
        float low = smoothstep(10.0, -2.0, p.y + cameraPosition.y - 63.0);
        haze = max(haze, STYLE_GROUND_MIST * 0.45 * low * (1.0 - exp(-dist * 0.025)));
  #endif
        // hide the edge of the loaded world (chunks load in a column round the player: measured across, not up/down,
        // or high up the ground below would all count as past the edge)
        float edge = smoothstep(fogEnd * 0.8, fogEnd, length(p.xz));
        float amount = max(haze, edge) * smoothstep(0.0, 0.2, float(eyeBrightnessSmooth.y) / 240.0 + edge);
        if (amount > 0.001) {
            // haze takes the sky's colour from a little above the view direction: right at the horizon the
            // atmosphere model is yellowed by ~100 km of air, real distant haze is blue-white
            vec3 hd = p / dist;
            col = mix(col, skyColor(normalize(vec3(hd.x, max(hd.y, 0.0) + 0.12, hd.z)), sunDir), amount);
        }
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
