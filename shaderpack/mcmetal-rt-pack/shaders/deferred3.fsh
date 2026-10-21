#version 330 compatibility
// Light shafts (god rays): sunlight scattered by the air along the view ray. The ray from the camera to the surface
// is cut into a few steps; at each, a hardware ray towards the sun says whether that bit of air is lit. Where the
// sun gets through gaps (a roof hole, leaves, a window) the lit air shows as shafts. Half resolution, a different
// step offset every frame, averaged over the last frames.
/*
const int colortex8Format = RGBA16F;   // rgb light scattered towards the camera, a distance to the camera
const bool colortex8Clear = false;
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"

uniform sampler2D colortex8, depthtex0;
uniform mat4 gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

/* RENDERTARGETS: 8 */
layout(location = 0) out vec4 outScatter;

#if defined USE_RT && defined LIGHT_SHAFTS
float mcm_trace(vec3 origin, vec3 dir, float tmax);
#endif

void main() {
    float depth = texture(depthtex0, texcoord).r;
    // the view direction from a point halfway into the depth range (the far plane itself unprojects to infinity)
    vec4 vm = gbufferProjectionInverse * vec4(texcoord * 2.0 - 1.0, 0.0, 1.0);
    vec3 dir = normalize(mat3(gbufferModelViewInverse) * (vm.xyz / vm.w));
    vec3 p = dir * 1000.0;
    if (depth < 1.0) {
        vec4 v = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
        p = mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
    }
    float dist = min(length(p), 48.0);
    vec3 scatter = vec3(0.0);
#if defined USE_RT && defined LIGHT_SHAFTS
    if (isEyeInWater == 0 && dot(sunCol, sunCol) > 1e-6) {
        // Henyey-Greenstein phase: most light scatters a little off the sun's direction (bright towards the sun)
        float g = 0.65, mu = dot(dir, lightDir);
        float phase = 0.3 / (4.0 * PI) + 0.7 * (1.0 - g * g) / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
        // thicker indoors (dusty air, and the eye adapts to the dark), so shafts through a roof hole show
        float indoors = 1.0 - float(eyeBrightnessSmooth.y) / 240.0;
        // clear air at midday, hazier with a low sun (morning, evening) and in rain
        float density = 0.005 * LIGHT_SHAFTS_STRENGTH * mix(1.0, 0.25, smoothstep(0.25, 0.7, lightDir.y))
                      * (1.0 + 3.0 * rainStrength + 3.0 * indoors);
        float stepLen = dist / float(LIGHT_SHAFTS_STEPS);
        float jitter = ign(gl_FragCoord.xy, frameCounter);
        float lit = 0.0;
        for (int i = 0; i < LIGHT_SHAFTS_STEPS; i++) {
            float t = (float(i) + jitter) * stepLen;
            // air further away is seen through more air (the haze in composite.fsh adds the rest)
            float vis = exp(-t * density);
            if (mcm_trace(dir * t, lightDir, 256.0) < 0.0) lit += vis;
        }
        // a beam in shade (sun through a roof hole or a gap in the trees) stands out the way it does in real dusty
        // air: the less of the view ray is lit, the more each lit step counts. Open air (all lit) stays clear
        // (dust that only shows in a beam: 0.05 per block where the view ray is all in shade)
        float shade = 1.0 - lit / float(LIGHT_SHAFTS_STEPS);
        // (cubed: a view ray that starts in open sunlight and then enters a room shouldn't haze the whole room)
        float beam = 0.05 * LIGHT_SHAFTS_STRENGTH * shade * shade * shade;
        scatter = sunCol * phase * (density + beam) * stepLen * lit * 4.0 * PI;   // x 4pi: our lights skip the 1/pi of diffuse
        if (any(isnan(scatter)) || any(isinf(scatter))) scatter = vec3(0.0);
    }
#endif
    // average with last frame's value at this spot (the step offset changes every frame)
    vec3 prevPlayer = (depth < 1.0 ? p : dir * 48.0) + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
    vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    vec4 h = texture(colortex8, puv * LIGHT_SHAFTS_SCALE);
    bool valid = depth >= 1.0 ? true : (all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0)))
              && abs(h.a - length(prevPlayer)) < 0.05 * dist + 0.2);
    if (depth >= 1.0) h = texture(colortex8, texcoord * LIGHT_SHAFTS_SCALE);
    if (any(isnan(h.rgb))) valid = false;   // never let a bad value live on in the history
    outScatter = vec4(valid ? mix(h.rgb, scatter, 1.0 / 8.0) : scatter, depth < 1.0 ? length(p) : 48.0);
}
