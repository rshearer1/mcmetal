#version 430 compatibility
// PT_COMPUTE: the GI pass (lib/gipass.glsl, the same work as deferred.fsh) as a compute pass: one thread per GI pixel,
// in 8x8 groups. deferred.fsh is switched off with it (shaders.properties). A first step towards the path tracer
// running bounce by bounce over only the paths still alive.
layout(local_size_x = 8, local_size_y = 8) in;
#if GI_HALF_RES == 1
const vec2 workGroupsRender = vec2(0.5, 0.5);
#else
const vec2 workGroupsRender = vec2(1.0, 1.0);
#endif
#include "/lib/gipass.glsl"

layout(rgba16f) uniform image2D colorimg3, colorimg4;

void main() {
    ivec2 px = ivec2(gl_GlobalInvocationID.xy);
    vec2 size = vec2(viewWidth, viewHeight) * GI_SCALE;
    if (px.x >= int(ceil(size.x)) || px.y >= int(ceil(size.y))) return;
    vec2 fc = vec2(px) + 0.5;
    vec3 sunCol, skyAmb;
    lightColors(sunCol, skyAmb);
    vec4 ao, gi;
    giMain(fc, fc / size, sunCol, skyAmb, lightDirection(), sunDirection(), ao, gi);
    imageStore(colorimg3, px, ao);
    imageStore(colorimg4, px, gi);
}
