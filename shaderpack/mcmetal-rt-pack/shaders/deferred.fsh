#version 330 compatibility
// Ray-traced global illumination and ambient occlusion, one ray per pixel.
// The ray leaves in a random direction over the surface (more often near the normal: cosine weighting). If it
// escapes, it brings sky light; if it hits a block, that block's own light (sun with a shadow ray, sky, torches,
// glow) times its colour comes back: bounce light and colour bleeding. The hit distance also gives the AO.
// Each pixel keeps a running average over the last frames, carried along as the camera moves.
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
#if defined USE_RT && (defined RT_AO || defined RT_GI)
    #include "/lib/shadow.glsl"
    #include "/lib/reflect.glsl"
#endif

uniform sampler2D colortex1, colortex2, colortex3, colortex4, depthtex0;
uniform mat4 gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

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

    float ao = 1.0;
    vec3 gi = vec3(0.0);
#if defined USE_RT && (defined RT_AO || defined RT_GI)
    vec3 n = octDecode(texture(colortex1, texcoord).xy);
    // cosine-weighted direction around n, new random numbers each frame
    float u1 = ign(gl_FragCoord.xy, frameCounter), u2 = ign(gl_FragCoord.xy + vec2(47.0, 17.0), frameCounter * 7 + 3);
    float r = sqrt(u1), phi = 6.2832 * u2;
    vec3 t = normalize(abs(n.y) < 0.99 ? cross(n, vec3(0.0, 1.0, 0.0)) : cross(n, vec3(1.0, 0.0, 0.0)));
    vec3 d = normalize(t * (r * cos(phi)) + cross(n, t) * (r * sin(phi)) + n * sqrt(1.0 - u1));
    vec3 o = mat == MAT_FOLIAGE ? p + d * 0.05 : p + n * 0.02;
    float hit;
  #ifdef RT_GI
    gi = traceRadiance(o, d, RT_GI_DISTANCE, lightDir, sunCol, skyAmb, sunDir, 1.0, hit);
    gi = min(gi, vec3(16.0));   // one lucky ray into the sun-lit sky must not leave a bright speck
  #else
    hit = mcm_trace(o, d, RT_AO_RADIUS);
  #endif
    ao = hit < 0.0 ? 1.0 : smoothstep(0.0, RT_AO_RADIUS, hit);
#endif

    // where was this point last frame?
    vec3 prevPlayer = p + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
    vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    vec4 h = texture(colortex3, puv);
    bool valid = all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0)))
              && abs(h.b - length(prevPlayer)) < 0.05 * dist + 0.1;
    float frames = valid ? min(h.g + 1.0, RT_AO_FRAMES) : 1.0;
    float w = 1.0 / frames;
    outAO = vec4(mix(valid ? h.r : ao, ao, w), frames, dist, 1.0);
    vec3 hgi = valid ? texture(colortex4, puv).rgb : gi;
    outGI = vec4(mix(hgi, gi, w), 1.0);
}
