#version 430 compatibility
// Half-resolution sun shadows from a compute pass: one thread per half-size pixel, traced with mcm_trace.
layout(local_size_x = 8, local_size_y = 8) in;
const vec2 workGroupsRender = vec2(0.5, 0.5);

layout(r16f) uniform image2D halfShadow;
layout(std430, binding = 0) buffer Counter { uint ground; uint shadowed; };

uniform sampler2D depthtex0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform vec3 shadowLightPosition;
uniform float viewWidth;
uniform float viewHeight;

float mcm_trace(vec3 origin, vec3 dir, float tmax);

void main() {
    ivec2 hp = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(halfShadow);
    if (hp.x >= size.x || hp.y >= size.y) return;
    ivec2 full = hp * 2;
    vec2 uv = (vec2(full) + 1.0) / vec2(viewWidth, viewHeight);
    float depth = texelFetch(depthtex0, full, 0).r;
    float lit = 1.0;
    if (depth < 1.0) {
        atomicAdd(ground, 1u);
        vec4 view = gbufferProjectionInverse * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
        view /= view.w;
        vec3 player = (gbufferModelViewInverse * view).xyz;
        vec3 toLight = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
        // no screen derivatives in compute: step back towards the camera and towards the light instead
        vec3 origin = player - normalize(player) * 0.03 + toLight * 0.03;
        if (mcm_trace(origin, toLight, 256.0) > 0.0) {
            lit = 0.5;
            atomicAdd(shadowed, 1u);
        }
    }
    imageStore(halfShadow, hp, vec4(lit));
}
