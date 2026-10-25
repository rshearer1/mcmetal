#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"

out vec2 texcoord;
flat out vec3 sunCol, skyAmb, lightDir, sunDir;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lightColors(sunCol, skyAmb);
    lightDir = lightDirection();
    sunDir = sunDirection();
}
