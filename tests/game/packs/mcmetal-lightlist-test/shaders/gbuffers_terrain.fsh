#version 330 compatibility
uniform sampler2D gtexture;
flat in int blockId;
in vec2 texcoord;
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;
void main() {
    vec4 tex = texture(gtexture, texcoord);
    if (tex.a < 0.1)
        discard;
    vec3 c = vec3(0.35); // not a light id
    if (blockId == 50) c = vec3(1.0, 0.55, 0.1);
    else if (blockId == 76) c = vec3(0.9, 0.05, 0.05);
    else if (blockId == 89) c = vec3(1.0, 0.95, 0.2);
    else if (blockId == 10 || blockId == 51) c = vec3(0.8, 0.25, 0.0);
    else if (blockId == 124) c = vec3(0.6, 1.0, 0.2);
    else if (blockId == 198) c = vec3(1.0);
    outColor = vec4(c * (0.6 + 0.4 * dot(tex.rgb, vec3(0.333))), 1.0);
}
