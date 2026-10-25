#version 330 compatibility
// Ray-traced reflections on open water (the flat tops of lakes, rivers and the sea), the costliest rays of a view
// with water in it. Traced here instead of in gbuffers_water: at half resolution (scale.composite), and each pixel
// traces a new ray every other frame (a checkerboard); the rest keep their average, carried along as the camera
// moves. The waves are the water's own (lib/waves.glsl). What's stored is only the part the rays add over the sky
// reflection gbuffers_water already gave, weighted the same way, so composite1.fsh just adds it.
// Waterfalls, glass and water seen from below still trace their own rays in gbuffers_water.
/*
const int colortex14Format = RGBA16F;   // rgb reflected light to add, a distance to the camera (0: no open water)
const bool colortex14Clear = false;
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

/* RENDERTARGETS: 14 */
layout(location = 0) out vec4 outRefl;

#ifdef WATER_REFLECT_PASS
uniform sampler2D colortex5, colortex11, colortex14, depthtex0;
uniform mat4 gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

// a reflected block that is on screen already has its (soft, averaged) sun shadow from deferred1.fsh this frame
#define SHADOW_CACHE
bool cachedShadow(vec3 hp, out vec3 sh) {
    vec4 pc = gbufferProjection * (gbufferModelView * vec4(hp, 1.0));
    if (pc.w <= 0.0) return false;
    vec2 uv = pc.xy / pc.w * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return false;
    vec4 c = texture(colortex5, uv);
    float d = length(hp);
    if (abs(c.a - d) > 0.03 * d + 0.15) return false;   // something else is in front of it
    sh = c.rgb;
    return true;
}
#include "/lib/shadow.glsl"
#include "/lib/reflect.glsl"
#include "/lib/waves.glsl"
#endif

void main() {
#ifdef WATER_REFLECT_PASS
    vec2 size = vec2(viewWidth, viewHeight);
    ivec2 fp = ivec2(texcoord * size);
    float wr = texelFetch(colortex11, fp, 0).r;
    float depth = texelFetch(depthtex0, fp, 0).r;
    if (wr < 0.58 || isEyeInWater != 0 || depth >= 1.0) { outRefl = vec4(0.0); return; }
    vec2 uv = (vec2(fp) + 0.5) / size;
    vec4 v4 = gbufferProjectionInverse * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    vec3 p = mat3(gbufferModelViewInverse) * (v4.xyz / v4.w) + gbufferModelViewInverse[3].xyz;
    float dist = length(p);

    // where was this point last frame? (the history is half resolution too: the lower-left quarter of colortex14)
    vec3 prevPlayer = p + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
    vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    vec4 h = texelFetch(colortex14, ivec2(puv * size * 0.5), 0);
    bool valid = pc.w > 0.0 && all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0)))
              && h.a > 0.0 && abs(h.a - length(prevPlayer)) < 0.05 * dist + 0.1;
    ivec2 q = ivec2(gl_FragCoord.xy);
    if (valid && ((q.x + q.y + frameCounter) & 1) == 1) { outRefl = vec4(h.rgb, dist); return; }

    // the same reflection gbuffers_water would have traced here (lib/gbuffer.glsl), minus the sky it already has
    vec3 n = waveNormal(p.xz + cameraPosition.xz);
    vec3 v = normalize(p);
    float f = 0.02 + 0.98 * pow(1.0 - clamp(dot(-v, n), 0.0, 1.0), 5.0);
    float skyOpen = (wr - 0.6) / 0.4;
    vec3 add = vec3(0.0);
    if (f > 0.04) {
        vec3 sky = skyColor(reflect(v, n), sunDir) * skyOpen;
        vec3 refl = mix(sky, traceReflection(p + n * 0.02, reflect(v, n), lightDir, sunCol, skyAmb, sunDir, skyOpen),
                        smoothstep(0.04, 0.06, f));
        add = (refl / (1.0 + luma(refl) * 0.08) - sky / (1.0 + luma(sky) * 0.08)) * f * mix(0.55, 1.0, f);
    }
    // a short average: still follows the waves and anything moving in the reflection
    outRefl = vec4(valid ? mix(h.rgb, add, 0.5) : add, dist);
#else
    outRefl = vec4(0.0);
#endif
}
