#version 330 compatibility
// ACES filmic grading, then to the screen's sRGB.
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/aces.glsl"

uniform sampler2D colortex0, colortex6;

in vec2 texcoord;

layout(location = 0) out vec4 outColor;

void main() {
    float exposure = texelFetch(colortex6, ivec2(0), 0).r * EXPOSURE;   // from composite2
    vec3 col = texture(colortex0, texcoord).rgb * exposure;
#if DEBUG_VIEW > 0
    outColor = vec4(texture(colortex0, texcoord).rgb, 1.0);   // debug views: raw values, no grading
    return;
#endif
    col = acesFitted(col);
    col = mix(vec3(luma(col)), col, SATURATION);
    col = clamp((col - 0.18) * CONTRAST + 0.18, 0.0, 1.0);
    col = toSRGB(col);
    col += (ign(gl_FragCoord.xy, frameCounter) - 0.5) / 255.0;   // dither: no banding in dark skies
    outColor = vec4(col, 1.0);
}
