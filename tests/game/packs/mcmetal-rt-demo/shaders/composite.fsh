#version 330 compatibility
// mcmetal ray-tracing demo: hard sun/moon shadows cast by the GPU's ray-tracing hardware.
// Only runs on mcmetal (it supplies mcm_trace); on any other renderer this pack fails to load.

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

void main() {
    vec4 color = texture(colortex0, texcoord);
    float depth = texture(depthtex0, texcoord).r;
    if (depth < 1.0) {
        vec4 view = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
        view /= view.w;
        vec3 player = (gbufferModelViewInverse * view).xyz;
        vec3 toLight = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
        // start the ray just off the surface: the depth buffer only gives the position to within a few mm, so starting
        // on it lets the surface shadow itself in stripes (shadow acne). Face normal from screen-space derivatives.
        vec3 n = normalize(cross(dFdx(player), dFdy(player)));
        if (dot(n, player) > 0.0) n = -n;                  // towards the camera
        vec3 origin = player + n * 0.02 + toLight * 0.01;
        float t = mcm_trace(origin, toLight, 256.0);
        if (t > 0.0)
            color.rgb *= 0.35;
    }
    outColor = color;
}
