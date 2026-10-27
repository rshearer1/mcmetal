// PT_WAVEFRONT: one bounce pass of the path tracer (deferred_a.csh is bounce 1, deferred_b.csh bounce 2, ...;
// PT_PASS says which). One thread per path in this bounce's queue (lib/ptqueue.glsl), 64 to a group in queue
// order, so a group's threads all have work until the queue runs out. Each adds what its path picks up at this
// bounce to its pixel's GI in ptGI (already weighted for the running average by deferred.csh), and puts the path
// into the next bounce's queue if it carries on. Without PT_WAVEFRONT, or past PT_BOUNCES: one thread that does
// nothing.
#include "/lib/settings.glsl"
layout(local_size_x = 8, local_size_y = 8) in;
#if defined PT_WAVEFRONT && PT_PASS < PT_BOUNCES
    #define PT_PASS_ON
  #if GI_HALF_RES == 1
const vec2 workGroupsRender = vec2(0.5, 0.5);
  #else
const vec2 workGroupsRender = vec2(1.0, 1.0);
  #endif
    #include "/lib/gipass.glsl"
    #include "/lib/ptqueue.glsl"
layout(rgba16f) uniform image2D ptGI;
#else
const ivec3 workGroups = ivec3(1, 1, 1);
#endif

void main() {
#ifdef PT_PASS_ON
    uint i = (gl_WorkGroupID.y * gl_NumWorkGroups.x + gl_WorkGroupID.x) * 64u + gl_LocalInvocationIndex;
    if (i >= min(ptCount[PT_PASS], PT_QUEUE)) return;
    vec3 o, d, throughput;
    float skyLM;
    ivec2 px;
    ptPop(PT_PASS, i, o, d, throughput, skyLM, px);
    vec3 sunCol, skyAmb;
    lightColors(sunCol, skyAmb);
    vec3 radiance = vec3(0.0);
    float t;
    bool on = ptBounce(o, d, throughput, skyLM, PT_PASS, lightDirection(), sunCol, skyAmb, sunDirection(),
                       vec2(px) + 0.5, radiance, t);
    vec4 g = imageLoad(ptGI, px);
    imageStore(ptGI, px, vec4(g.rgb + min(radiance, vec3(16.0)), g.a));
    if (on && PT_PASS + 1 < PT_BOUNCES) ptPush(PT_PASS + 1, o, d, throughput, skyLM, px);
#endif
}
