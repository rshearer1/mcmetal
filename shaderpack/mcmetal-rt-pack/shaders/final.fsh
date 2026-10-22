#version 330 compatibility
// ACES filmic grading and the chosen look (lib/style.glsl), then to the screen's sRGB.
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/aces.glsl"
#include "/lib/style.glsl"

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
#if STYLE > 0
    // glow: a ring of taps around the pixel at two radii, only the part above about mid-grey
    vec3 glow = vec3(0.0);
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.7854 + 0.39;
        vec2 d = vec2(cos(a), sin(a)) * px;
        glow += max(texture(colortex0, texcoord + d * 6.0).rgb * exposure - 0.6, 0.0);
        glow += max(texture(colortex0, texcoord + d * 18.0).rgb * exposure - 0.6, 0.0) * 0.6;
    }
    col += glow * (STYLE_GLOW / 8.0);
#endif
    col = acesFitted(col);
    col = styleGrade(col, texcoord);
    col = mix(vec3(luma(col)), col, SATURATION);
    col = clamp((col - 0.18) * CONTRAST + 0.18, 0.0, 1.0);
    col = toSRGB(col);
    col += (ign(gl_FragCoord.xy, frameCounter) - 0.5) / 255.0;   // dither: no banding in dark skies
    outColor = vec4(col, 1.0);
}
