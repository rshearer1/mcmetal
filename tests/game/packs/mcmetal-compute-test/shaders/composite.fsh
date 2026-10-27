#version 430 compatibility
// Shows deferred.csh's half-size shadows, and its storage-buffer counters as a square in the top-left corner:
// green = it saw ground and traced shadows, yellow = ground but no shadow hits (no ray-tracing hardware), red = nothing.
uniform sampler2D colortex0;
uniform sampler2D halfShadowSampler;
layout(std430, binding = 0) buffer Counter { uint ground; uint shadowed; };

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    vec4 color = texture(colortex0, texcoord);
    float s = texture(halfShadowSampler, texcoord).r;
    if (s == 0.0)
        color.rgb = vec3(1.0, 0.0, 1.0);          // never written: the compute pass didn't run
    else
        color.rgb *= s < 0.75 ? 0.35 : 1.0;
    if (texcoord.x < 0.05 && texcoord.y > 0.95)
        color.rgb = ground == 0u ? vec3(1.0, 0.0, 0.0) : shadowed > 0u ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 1.0, 0.0);
    outColor = color;
}
