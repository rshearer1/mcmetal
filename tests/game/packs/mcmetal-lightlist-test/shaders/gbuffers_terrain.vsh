#version 330 compatibility
in vec4 mc_Entity;
flat out int blockId;
out vec2 texcoord;
void main() {
    blockId = int(mc_Entity.x + 0.5);
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    gl_Position = ftransform();
}
