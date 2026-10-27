#version 430 compatibility
// PT_COMPUTE: the GI pass (lib/gipass.glsl, the same work as deferred.fsh) as a compute pass, one thread per GI pixel
// in 8x8 groups. It runs just before deferred.fsh, reads last frame's history from colortex3/4 like the fragment
// version, and writes this frame's into the ptAO/ptGI images; deferred.fsh then only copies them into colortex3/4
// (writing colortex3/4 here directly would race with the history reads of neighbouring pixels). The first step
// towards a path tracer that runs bounce by bounce over only the paths still alive: with PT_WAVEFRONT this pass
// traces only the first bounce and the rest run in deferred_a.csh ... (lib/ptpass.glsl). Without PT_COMPUTE: one
// thread that does nothing.
#include "/lib/settings.glsl"
layout(local_size_x = 8, local_size_y = 8) in;
#ifdef PT_COMPUTE
  #if GI_HALF_RES == 1
const vec2 workGroupsRender = vec2(0.5, 0.5);
  #else
const vec2 workGroupsRender = vec2(1.0, 1.0);
  #endif
    #include "/lib/gipass.glsl"
  #ifdef PT_WAVEFRONT
    #include "/lib/ptqueue.glsl"
  #endif
layout(rgba16f) uniform image2D ptAO, ptGI;
#else
const ivec3 workGroups = ivec3(1, 1, 1);
#endif

void main() {
#ifdef PT_COMPUTE
    ivec2 px = ivec2(gl_GlobalInvocationID.xy);
    vec2 size = imageSize(ptAO);
    if (px.x >= int(size.x) || px.y >= int(size.y)) return;
    vec2 fc = vec2(px) + 0.5;
    vec3 sunCol, skyAmb;
    lightColors(sunCol, skyAmb);
    vec4 ao, gi;
  #ifdef PT_WAVEFRONT
    ptGoesOn = false;
  #endif
    giMain(fc, fc / (vec2(viewWidth, viewHeight) * GI_SCALE), sunCol, skyAmb, lightDirection(), sunDirection(), ao, gi);
    imageStore(ptAO, px, ao);
    imageStore(ptGI, px, gi);
  #ifdef PT_WAVEFRONT
    // the path goes on in the bounce passes; what it finds there counts 1 / frames into the running average,
    // like this frame's first bounce did
    if (ptGoesOn) ptPush(1, ptO, ptD, ptThroughput / ao.g, ptSkyLM, px);
  #endif
#endif
}
