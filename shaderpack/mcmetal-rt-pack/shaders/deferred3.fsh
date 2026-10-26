#version 330 compatibility
// GI denoiser, round 2 of 2 (lib/denoise.glsl): taps 2 GI pixels apart, colortex15 -> colortex7. The lighting
// (deferred4.fsh) reads colortex7; colortex4 keeps the plain average, the history for the next frame.
/*
const int colortex7Format = RGBA16F;   // GI after round 2
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
uniform sampler2D colortex1, colortex3, colortex15, depthtex0;
#include "/lib/denoise.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 7 */
layout(location = 0) out vec4 outGI;

void main() { outGI = vec4(denoiseRound(colortex15, texcoord, 2.0), 1.0); }
