#version 330 compatibility
// METALFX_DENOISE: the hand-over to mcmetal's MetalFX denoiser (core/mgl_denoise.c, MCMETAL_DENOISE=1 in mcmetal's
// options). mcmetal recognises this pass by its defines, reads the buffers they name, and replaces the draw with
// Apple's denoised scaler, writing the cleaned lit picture into colortex0. Where MetalFX can't run (before M3, older
// macOS, Apple GL) this pass's own body runs instead: a plain copy, so nothing changes. Our own denoiser is off
// with this option (the MetalFX one sees the whole lit picture instead of just the bounce light).
// (the same lines again in a comment: Iris's preprocessor removes #define lines before mcmetal sees the source, but
// keeps comments; mcmetal reads either)
/* mcmetal denoiser inputs
MCMETAL_DENOISE_PASS
MCMETAL_DENOISE_COLOR colortex0
MCMETAL_DENOISE_DEPTH depthtex0
MCMETAL_DENOISE_NORMAL colortex1
MCMETAL_DENOISE_ALBEDO colortex15
MCMETAL_DENOISE_ROUGHNESS colortex10 b
MCMETAL_DENOISE_SPECULAR colortex10 a
MCMETAL_DENOISE_MOTION colortex7
*/
#define MCMETAL_DENOISE_PASS
#define MCMETAL_DENOISE_COLOR colortex0
#define MCMETAL_DENOISE_DEPTH depthtex0
#define MCMETAL_DENOISE_NORMAL colortex1
#define MCMETAL_DENOISE_ALBEDO colortex15
#define MCMETAL_DENOISE_ROUGHNESS colortex10 b
#define MCMETAL_DENOISE_SPECULAR colortex10 a
#define MCMETAL_DENOISE_MOTION colortex7      // rg: previous minus current position, in pixels, +y up (deferred4.fsh)
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
