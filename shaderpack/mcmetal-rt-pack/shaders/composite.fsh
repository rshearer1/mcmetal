#version 330 compatibility
// Fog over everything (after water and glass): air haze towards the sky colour, a soft edge at the render
// distance, and fog under water / in lava / in powder snow.
/*
const bool colortex0MipmapEnabled = true;   // composite1 meters the picture's brightness from the small mip levels
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"

uniform sampler2D colortex0, colortex8, depthtex0;

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, sunDir;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    vec3 col = texture(colortex0, texcoord).rgb;
    float depth = texture(depthtex0, texcoord).r;
    vec4 v = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
    vec3 p = mat3(gbufferModelViewInverse) * (v.xyz / v.w);
    float dist = length(p);

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
    if (isEyeInWater == 0) col += texture(colortex8, texcoord * LIGHT_SHAFTS_SCALE).rgb;   // deferred3.fsh
#endif
#if DEBUG_VIEW == 5 && defined USE_RT && defined LIGHT_SHAFTS
    { vec3 ls = texture(colortex8, texcoord * LIGHT_SHAFTS_SCALE).rgb * 4.0; col = ls / (ls + 1.0); }
#endif
    col *= 1.0 - max(blindness, darknessFactor) * smoothstep(2.0, 12.0, dist);
    outColor = vec4(col, 1.0);
}
