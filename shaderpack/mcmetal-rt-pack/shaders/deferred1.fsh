#version 330 compatibility
// Soft sun shadows, full resolution: each frame's ray aims at a different point of the sun's disc, and the
// average over the last frames (carried along as the camera moves) gives the soft edge. Colour from glass.
/*
const int colortex5Format = RGBA16F;   // rgb sun shadow, a distance to the camera (to check the history)
const bool colortex5Clear = false;
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"
#ifdef USE_RT
    #include "/lib/shadow.glsl"
#endif

uniform sampler2D colortex1, colortex2, colortex5, depthtex0;
uniform mat4 gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

/* RENDERTARGETS: 5 */
layout(location = 0) out vec4 outShadow;

void main() {
    float depth = texture(depthtex0, texcoord).r;
    int mat = int(texture(colortex2, texcoord).r * 255.0 + 0.5);
    if (depth >= 1.0 || mat == MAT_HAND || mat == MAT_LIT) { outShadow = vec4(1.0, 1.0, 1.0, 0.0); return; }
    vec4 v = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
    vec3 p = mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
    float dist = length(p);
    vec3 prevPlayer = p + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
    vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    vec4 h = texture(colortex5, puv);
    bool valid = all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0)))
              && abs(h.a - length(prevPlayer)) < 0.05 * dist + 0.1;
    vec3 sh = vec3(1.0);
#if defined USE_RT && defined SHADOW_CHECKERBOARD
    // 1 in SHADOW_RATE pixels each frame: the others keep their averaged shadow (where it's still valid)
    if (valid && rayRest(gl_FragCoord.xy, SHADOW_RATE, frameCounter)) {
        outShadow = vec4(h.rgb, dist);
        return;
    }
#endif
#ifdef USE_RT
    // soft sun shadow: aim each frame's ray at a different point of the sun's disc; the average gives the penumbra
    {
        vec4 nl = texture(colortex1, texcoord);
        vec3 ns = octDecode(nl.xy);
        // no sky light at all (caves, deep indoors): no path to the sun either, so no ray (the lightmap's sky
        // level is 0 there); worlds without sky light (Nether, End) have no sun or moon to trace to
        bool skyReach = nl.w > 0.5 / 15.0 && hasSkylight;
        if (skyReach && (dot(ns, lightDir) > 0.0 || mat == MAT_FOLIAGE)) {
            vec2 q = gl_FragCoord.xy;
  #ifdef SHADOW_CHECKERBOARD
            if (valid) q = rayPixel(q, SHADOW_RATE);   // only 1 in SHADOW_RATE pixels traces (see rayRest above)
  #endif
            float a1 = ign(q + vec2(13.0, 71.0), frameCounter * 3 + 1) * 6.2832;
            float a2 = sqrt(ign(q + vec2(91.0, 29.0), frameCounter * 5 + 2)) * radians(SUN_SOFTNESS);
            vec3 st = normalize(abs(lightDir.y) < 0.99 ? cross(lightDir, vec3(0.0, 1.0, 0.0)) : cross(lightDir, vec3(1.0, 0.0, 0.0)));
            vec3 sl = normalize(lightDir + (st * cos(a1) + cross(lightDir, st) * sin(a1)) * tan(a2));
            sh = sunShadow(p, ns, sl, mat);
        } else sh = vec3(0.0);
    }
#endif

    // a short memory (8 frames at half rate): shadows move with the sun and with mobs
    outShadow = vec4(valid ? mix(h.rgb, sh, SHADOW_BLEND) : sh, dist);
}
