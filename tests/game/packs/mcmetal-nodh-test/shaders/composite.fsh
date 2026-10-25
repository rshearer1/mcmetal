#version 330 compatibility
uniform sampler2D colortex0;
uniform sampler2D depthtex0;
in vec2 texcoord;
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;
void main() {
    vec3 c = texture(colortex0, texcoord).rgb;
    if (texture(depthtex0, texcoord).r >= 1.0) // nothing drawn: the pack's own sky, like SEUS's
        c = mix(vec3(0.86, 0.76, 0.92), vec3(0.32, 0.48, 0.86), clamp(texcoord.y * 1.6 - 0.5, 0.0, 1.0));
    outColor = vec4(c, 1.0);
}
