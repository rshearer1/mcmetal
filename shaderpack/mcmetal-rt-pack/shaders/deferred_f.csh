#version 430 compatibility
// PT_WAVEFRONT: after the last bounce pass, empty the path queues' counts for the next frame (lib/ptqueue.glsl)
#include "/lib/settings.glsl"
layout(local_size_x = 16) in;
const ivec3 workGroups = ivec3(1, 1, 1);
#ifdef PT_WAVEFRONT
    #include "/lib/ptqueue.glsl"
#endif

void main() {
#ifdef PT_WAVEFRONT
    ptCount[gl_LocalInvocationIndex] = 0u;
#endif
}
