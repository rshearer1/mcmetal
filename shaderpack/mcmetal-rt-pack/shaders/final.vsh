#version 330 compatibility
// Exposure follows the light of the moment: bright days are brought down, nights and caves brought up.
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"

out vec2 texcoord;
flat out float exposure;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vec3 sunCol, skyAmb;
    lightColors(sunCol, skyAmb);
    float outdoor = luma(sunCol * 0.5 + skyAmb);
    float eyeSky = float(eyeBrightnessSmooth.y) / 240.0;
    float key = mix(0.35, outdoor, eyeSky * eyeSky);   // underground: what torches give
    // nights stay nights: don't brighten past what a torch-lit scene needs, or every light blows out
    exposure = 0.55 / clamp(key, 0.15, 100.0) * EXPOSURE;
}
