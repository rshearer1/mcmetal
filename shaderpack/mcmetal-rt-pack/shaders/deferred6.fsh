#version 330 compatibility
// METALFX_DENOISE: the hand-over to mcmetal's MetalFX denoiser (core/mgl_denoise.c, MCMETAL_DENOISE=1 in mcmetal's
// options). mcmetal recognises this pass by the constants below, reads the buffers they name, and replaces the draw with
// Apple's denoised scaler, writing the cleaned lit picture into colortex0. Where MetalFX can't run (before M3, older
// macOS, Apple GL) this pass's own body runs instead: a plain copy, so nothing changes. Our own denoiser is off
// with this option (the MetalFX one sees the whole lit picture instead of just the bounce light).
// (constants, not #define lines: Iris's preprocessor removes #define lines and comments before mcmetal sees the
// source. Role, two underscores, sampler, and two underscores and the channel where one is needed)
const int MCMETAL_DENOISE_PASS = 1;
const int MCMETAL_DENOISE_COLOR__colortex0 = 1;
const int MCMETAL_DENOISE_DEPTH__depthtex0 = 1;
const int MCMETAL_DENOISE_NORMAL__colortex1 = 1;
const int MCMETAL_DENOISE_ALBEDO__colortex15 = 1;
const int MCMETAL_DENOISE_ROUGHNESS__colortex10__b = 1;
const int MCMETAL_DENOISE_SPECULAR__colortex10__a = 1;
const int MCMETAL_DENOISE_MOTION__colortex7 = 1;   // rg: previous minus current position, in pixels, +y up (deferred4.fsh)
#include "/lib/settings.glsl"
#include "/lib/uniforms.glsl"

uniform sampler2D colortex0, colortex1, colortex7, colortex10, colortex15, depthtex0;

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(colortex0, texcoord);
    // every named input must stay in the compiled shader, or mcmetal can't find its binding: read them behind a
    // condition that is never true at run time
    if (frameCounter < -1) outColor += texture(colortex1, texcoord) + texture(colortex10, texcoord)
                                       + texture(colortex15, texcoord) + texture(depthtex0, texcoord)
                                       + texture(colortex7, texcoord);
}
