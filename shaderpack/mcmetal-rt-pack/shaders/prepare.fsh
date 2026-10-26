#version 330 compatibility
// The sky table, once a frame before anything is drawn (lib/sky.glsl): the full sky model for 128 x 63 directions,
// and in the last row the frame's light colours. Every other program reads it instead of running the model.
/*
const int colortex12Format = RGBA16F;
const bool colortex12Clear = false;
*/
#define SKY_LUT_BUILD
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 12 */
layout(location = 0) out vec4 outSky;

void main() {
    ivec2 q = ivec2(gl_FragCoord.xy);
    vec3 sunDir = sunDirection();
    if (q.y >= int(SKY_LUT_ROWS)) {
        vec3 sunCol, skyAmb;
        lightColorsExact(sunCol, skyAmb);
        outSky = vec4(q.x == 0 ? sunCol : q.x == 1 ? skyAmb : q.x == 2 ? (hasSkylight ? lightTransmittance(sunDir) : vec3(0.0)) : vec3(0.0), 1.0);
        return;
    }
    vec2 a = vec2(q) / vec2(SKY_LUT_W - 1.0, SKY_LUT_ROWS - 1.0);
    outSky = vec4(skyColorExact(skyLutDirection(a, sunDir), sunDir), 1.0);
}
