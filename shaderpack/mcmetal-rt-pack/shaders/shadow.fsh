#version 330 compatibility
uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 tint;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 c = texture(gtexture, texcoord) * tint;
    if (c.a < 0.1) discard;
    outColor = c;
}
