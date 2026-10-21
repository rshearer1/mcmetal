#version 330 compatibility
// mcmetal ray-tracing debug view (see README.txt). Only runs on mcmetal (it supplies mcm_trace).

uniform sampler2D colortex0;
uniform sampler2D depthtex0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform vec3 shadowLightPosition;

in vec2 texcoord;

// distance to the first block hit along dir, or -1 (provided by mcmetal)
float mcm_trace(vec3 origin, vec3 dir, float tmax);
// same, and cut = the alpha cutoff of the block hit (0 = solid block, else a see-through-texture block)
float mcm_trace_cut(vec3 origin, vec3 dir, float tmax, out uint cut);

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

vec4 shade(float t) { return t > 0.0 ? vec4(0.0, 1.0 - clamp(t / 64.0, 0.0, 0.8), 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0); }
// solid hit green, see-through-texture hit (grass, leaves, plain glass) yellow, miss red
vec4 shade_cut(float t, uint cut) { return t > 0.0 && cut != 0u ? vec4(1.0, 1.0, 0.0, 1.0) : shade(t); }

void main() {
    vec4 color = texture(colortex0, texcoord);
    if (texcoord.y > 0.85 && texcoord.x < 0.1) {          // camera straight down
        outColor = shade(mcm_trace(vec3(0.0), vec3(0.0, -1.0, 0.0), 256.0));
        return;
    }
    if (texcoord.y > 0.85 && texcoord.x > 0.9) {          // camera straight up
        outColor = shade(mcm_trace(vec3(0.0), vec3(0.0, 1.0, 0.0), 256.0));
        return;
    }
    float depth = texture(depthtex0, texcoord).r;
    if (depth < 1.0) {
        vec4 view = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
        view /= view.w;
        vec3 player = (gbufferModelViewInverse * view).xyz;
        vec3 toLight = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
        uint cut;
        float t = mcm_trace_cut(player + toLight * 0.1, toLight, 256.0, cut);
        color = mix(color, shade_cut(t, cut), 0.6);
    }
    outColor = color;
}
