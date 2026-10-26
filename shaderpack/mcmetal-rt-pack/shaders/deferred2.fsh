#version 330 compatibility
// GI denoiser, round 1 of 2 (lib/denoise.glsl): taps 1 GI pixel apart, colortex4 -> colortex15.
/*
const int colortex15Format = RGBA16F;   // GI after round 1
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
uniform sampler2D colortex1, colortex3, colortex4, depthtex0;
#include "/lib/denoise.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 15 */
layout(location = 0) out vec4 outGI;

void main() { outGI = vec4(denoiseRound(colortex4, texcoord, 1.0), 1.0); }
