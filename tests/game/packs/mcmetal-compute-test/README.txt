mcmetal compute test pack: checks what native passes for our RT pack need. A compute shader (deferred.csh) runs
over half the screen, traces sun shadows with mcm_trace, writes half-size custom images (image. lines in
shaders.properties) with imageStore, and counts pixels in a storage buffer with atomics. composite.fsh is a
MCMETAL_DENOISE_PASS with half-size inputs: with MCMETAL_DENOISE=1 on an M3 or newer, MetalFX denoises and
upscales them to full size in one step; otherwise its own bilinear upscale runs.
A working run shows sun shadows (a little soft: half size) and a green square in the top-left corner (yellow on a
Mac without ray-tracing hardware, where every ray misses). Magenta = the half-size picture was never written (the
compute pass didn't run); red = the counters stayed 0. Needs mcmetal (mcm_trace); fails to load elsewhere.
