#version 330 compatibility
// Shadow map for systems without hardware ray tracing (not used on mcmetal, see shaders.properties).
#include "/lib/settings.glsl"

out vec2 texcoord;
out vec4 tint;

vec3 distortShadow(vec3 s) { return vec3(s.xy / (length(s.xy) * 0.9 + 0.1), s.z * 0.25); }

void main() {
    gl_Position = ftransform();
    gl_Position.xyz = distortShadow(gl_Position.xyz / gl_Position.w) * gl_Position.w;
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    tint = gl_Color;
}
