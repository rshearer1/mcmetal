#version 330 compatibility
// Ray-traced global illumination and ambient occlusion, one ray per pixel.
// The ray leaves in a random direction over the surface (more often near the normal: cosine weighting). If it
// escapes, it brings sky light; if it hits a block, that block's own light (sun with a shadow ray, sky, torches,
// glow) times its colour comes back: bounce light and colour bleeding. The hit distance also gives the AO.
// With mcmetal's light list, the direct light of nearby light blocks is added here too (lib/lights.glsl).
// Each pixel keeps a running average over the last frames, carried along as the camera moves.
// Runs at GI_SCALE resolution (shaders.properties scale.deferred): its pixels fill the lower-left part of the buffers.
/*
const int colortex3Format = RGBA16F;   // r occlusion (1 open), g frames in the average, b distance to the camera
const int colortex4Format = RGBA16F;   // rgb indirect light (GI), a unused
const bool colortex3Clear = false;
const bool colortex4Clear = false;
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"
uniform sampler2D colortex1, colortex2, colortex3, colortex4, colortex5, depthtex0;
uniform mat4 gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

// GI hits that were on screen last frame reuse deferred1's averaged sun shadow (colortex5: rgb shadow, a distance)
// instead of tracing a shadow ray of their own
#define SHADOW_CACHE
bool cachedShadow(vec3 hp, out vec3 sh) {
    vec3 prev = hp + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prev, 1.0));
    if (pc.w <= 0.0) return false;
    vec2 uv = pc.xy / pc.w * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return false;
    vec4 c = texture(colortex5, uv);
    float d = length(prev);
    if (abs(c.a - d) > 0.03 * d + 0.15) return false;   // something else was in front of it
    sh = c.rgb;
    return true;
}

// light cache: a GI hit that was on screen last frame takes the light gathered there (colortex4, its averaged
// GI) instead of the lightmap's flat sky and block light, so light bounces again each frame (multi-bounce)
#if defined LIGHT_CACHE && defined RT_GI
    #define GI_CACHE
bool cachedGI(vec3 hp, out vec3 gi) {
    vec3 prev = hp + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prev, 1.0));
    if (pc.w <= 0.0) return false;
    vec2 uv = pc.xy / pc.w * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.002))) || any(greaterThan(uv, vec2(0.998)))) return false;
    vec4 a = texture(colortex3, uv * GI_SCALE);
    float d = length(prev);
    if (a.g < 2.0 || abs(a.b - d) > 0.03 * d + 0.15) return false;   // hidden, or no average there yet
    gi = texture(colortex4, uv * GI_SCALE).rgb;
    return true;
}
#endif

#if defined USE_RT && (defined RT_AO || defined RT_GI)
  #ifdef GI_COARSE_RAYS
    #define COARSE_RAYS   // bounce light and AO: leaves and plants count as solid (lib/reflect.glsl)
  #endif
    #include "/lib/shadow.glsl"
    #include "/lib/reflect.glsl"
#endif
#include "/lib/lights.glsl"


in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

/* RENDERTARGETS: 3,4 */
layout(location = 0) out vec4 outAO;
layout(location = 1) out vec4 outGI;

void main() {
    float depth = texture(depthtex0, texcoord).r;
    int mat = int(texture(colortex2, texcoord).r * 255.0 + 0.5);
    if (depth >= 1.0 || mat == MAT_HAND || mat == MAT_LIT) {
        outAO = vec4(1.0, 0.0, 0.0, 1.0);
        outGI = vec4(0.0);
        return;
    }
    vec4 v = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
    vec3 p = mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
    float dist = length(p);

    // where was this point last frame?
    vec3 prevPlayer = p + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
    vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    vec4 h = texture(colortex3, puv * GI_SCALE);
    bool valid = all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0)))
              && abs(h.b - length(prevPlayer)) < 0.05 * dist + 0.1;
#if defined USE_RT && GI_RATE > 1
    // 1 in GI_RATE pixels each frame trace a new ray (a checkerboard for 2, one pixel of each 2x2 for 4); the
    // rest keep their running average (where it's still valid)
    ivec2 q = ivec2(gl_FragCoord.xy);
  #if GI_RATE == 2
    bool skip = ((q.x + q.y + frameCounter) & 1) == 1;
  #else
    bool skip = ((q.x & 1) + 2 * (q.y & 1)) != (frameCounter & 3);
  #endif
  #ifdef GI_ADAPTIVE
    // spend the rays where they're needed: a pixel just uncovered (few frames in its average) traces every frame,
    // one whose average has settled traces 1 frame in 4
    if (h.g < 4.0) skip = false;
    else if (h.g >= RT_AO_FRAMES * 0.75) skip = ((q.x & 1) + 2 * (q.y & 1)) != (frameCounter & 3);
  #endif
    if (valid && skip) {
        outAO = vec4(h.r, h.g, dist, 1.0);
        outGI = vec4(texture(colortex4, puv * GI_SCALE).rgb, 1.0);
        return;
    }
#endif

    float ao = 1.0;
    vec3 gi = vec3(0.0);
#if defined USE_RT && (defined RT_AO || defined RT_GI)
    vec3 n = octDecode(texture(colortex1, texcoord).xy);
    // cosine-weighted direction around n, new random numbers each frame
  #if RT_NOISE == 1
    float u1 = rayRand(gl_FragCoord.xy, frameCounter, 0), u2 = rayRand(gl_FragCoord.xy, frameCounter, 1);
  #else
    float u1 = ign(gl_FragCoord.xy, frameCounter), u2 = ign(gl_FragCoord.xy + vec2(47.0, 17.0), frameCounter * 7 + 3);
  #endif
    float r = sqrt(u1), phi = 6.2832 * u2;
    vec3 t = normalize(abs(n.y) < 0.99 ? cross(n, vec3(0.0, 1.0, 0.0)) : cross(n, vec3(1.0, 0.0, 0.0)));
    vec3 d = normalize(t * (r * cos(phi)) + cross(n, t) * (r * sin(phi)) + n * sqrt(1.0 - u1));
    vec3 o = mat == MAT_FOLIAGE ? p + d * 0.05 : p + n * 0.02;
    o += d * ownBodySkip(p, mat);
    float hit;
  #ifdef RT_GI
  #ifdef GI_SHORT_RAYS
    // short rays (most bounce light comes from within a few blocks; long rays cost the most): a ray that leaves
    // the short range without a hit takes the sky, but only as much as Minecraft's sky light says reaches here,
    // so a big hall doesn't fill with sky light through walls the ray never got to
    gi = traceRadiance(o, d, GI_SHORT_DISTANCE, lightDir, sunCol, skyAmb, sunDir, 1.0, hit);
    if (hit < 0.0) {
        float skyLM = texture(colortex1, texcoord).w;
        gi *= skyLM * skyLM;
    }
  #else
    gi = traceRadiance(o, d, RT_GI_DISTANCE, lightDir, sunCol, skyAmb, sunDir, 1.0, hit);
  #endif
    // skylight through openings: less saturated than the raw sky, so rooms aren't tinted slate-blue (the eye
    // white-balances indoors); Sky Light scales it like it scales the sky ambient
    if (hit < 0.0) gi = mix(vec3(luma(gi)), gi, SKY_GI_SATURATION) * SKY_LIGHT_STRENGTH;
    gi = min(gi, vec3(16.0));   // one lucky ray into the sun-lit sky must not leave a bright speck
    #ifdef USE_LIGHTS
    // coloured block light: one nearby light per pixel and frame, averaged and filtered along with the GI. Where
    // Minecraft's own block light is zero no light block is in reach: skip the light list (most of a daytime view)
    if (texture(colortex1, texcoord).z > 0.05)
    #ifdef LIGHT_RESTIR
    gi += min(coloredBlockLightReSTIR(p, n, mat, rayRand(gl_FragCoord.xy, frameCounter, 2),
                                      rayRand(gl_FragCoord.xy, frameCounter, 3), rayRand(gl_FragCoord.xy, frameCounter, 4),
                                      rayRand(gl_FragCoord.xy, frameCounter, 5),
                                      puv * vec2(viewWidth, viewHeight) * GI_SCALE, valid, gl_FragCoord.xy), vec3(32.0));
    #elif RT_NOISE == 1
    gi += min(coloredBlockLight(p, n, mat, rayRand(gl_FragCoord.xy, frameCounter, 2),
                                rayRand(gl_FragCoord.xy, frameCounter, 3),
                                rayRand(gl_FragCoord.xy, frameCounter, 4)), vec3(32.0));
    #else
    gi += min(coloredBlockLight(p, n, mat, ign(gl_FragCoord.xy + vec2(5.0, 37.0), frameCounter * 11 + 4),
                                ign(gl_FragCoord.xy + vec2(61.0, 3.0), frameCounter * 13 + 5),
                                ign(gl_FragCoord.xy + vec2(23.0, 83.0), frameCounter * 17 + 6)), vec3(32.0));
    #endif
    #endif
  #else
    hit = mcm_trace(o, d, RT_AO_RADIUS);
  #endif
    ao = hit < 0.0 ? 1.0 : smoothstep(0.0, RT_AO_RADIUS, hit);
#endif

    float cap = RT_AO_FRAMES;
#ifdef PHOTO_MODE
    // standing still and not turning: keep averaging far longer, for clean screenshots (a light switched on
    // nearby takes a few seconds to settle while you stand still)
    bool still = length(cameraPosition - previousCameraPosition) < 1e-4
              && distance(gbufferModelView[2].xyz, gbufferPreviousModelView[2].xyz) < 1e-5;
    if (still) cap = PHOTO_FRAMES;
#endif
    float frames = valid ? min(h.g + 1.0, cap) : 1.0;
    float w = 1.0 / frames;
    outAO = vec4(mix(valid ? h.r : ao, ao, w), frames, dist, 1.0);
    vec3 hgi = valid ? texture(colortex4, puv * GI_SCALE).rgb : gi;
    outGI = vec4(mix(hgi, gi, w), 1.0);
#if defined WORLD_CACHE && defined GI_CACHE
    // feed the world-space light cache (lib/worldcache.glsl) from settled pixels, a quarter of them each frame
    if (frames >= 4.0 && ((int(gl_FragCoord.x) + 2 * int(gl_FragCoord.y) + frameCounter) & 3) == 0)
        wcStore(p + cameraPosition, octDecode(texture(colortex1, texcoord).xy), outGI.rgb);
#endif
}
