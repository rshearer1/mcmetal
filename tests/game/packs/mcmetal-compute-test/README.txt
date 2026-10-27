mcmetal compute test pack: checks that an Iris compute pass runs on mcmetal with what native passes for our RT
pack need: a compute shader (deferred.csh) dispatched over half the screen, mcm_trace from compute, a half-size
custom image (image. in shaders.properties) written with imageStore, and a storage buffer with atomics.
A working run shows sun shadows from the compute pass and a green square in the top-left corner (the buffer
counted ground and shadowed pixels; yellow on a Mac without ray-tracing hardware, where every ray misses).
Magenta = the custom image was never written (the compute pass didn't run); red = the counters stayed 0.
Needs mcmetal (mcm_trace); fails to load elsewhere.
