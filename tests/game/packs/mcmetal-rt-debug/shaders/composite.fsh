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

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

vec4 shade(float t) { return t > 0.0 ? vec4(0.0, 1.0 - clamp(t / 64.0, 0.0, 0.8), 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0); }

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
        color = mix(color, shade(mcm_trace(player + toLight * 0.1, toLight, 256.0)), 0.6);
    }
    outColor = color;
}
