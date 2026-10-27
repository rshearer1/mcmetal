// PT_WAVEFRONT: the paths still going after each bounce, in a queue (Iris shader storage buffer 4). deferred.csh
// traces every GI pixel's first bounce and puts the paths that carry on into the queue for bounce 1; each bounce
// pass (deferred_a.csh ...) then runs only over the paths in its queue, packed together, so no thread works on a
// path that already ended in the sky or was stopped by Russian roulette, and the next bounce's queue fills up as
// it goes. Two halves take turns (bounce b reads half b & 1 and fills the other); ptCount[b] counts bounce b's
// paths and deferred_f.csh clears the counts for the next frame.
const uint PT_QUEUE = 2097152u;   // paths per half: every GI pixel up to 2M (1920 x 1080 at full GI resolution)

struct PtPath {
    vec4 oPixel;   // xyz where the path goes on from, w the GI pixel (x | y << 16, as bits)
    uvec4 dThr;    // halves: direction xy, direction z + sky lightmap, throughput rg, throughput b
};
layout(std430, binding = 4) buffer PtQueue {
    uint ptCount[16];
    PtPath ptPaths[];
};

void ptPush(int b, vec3 o, vec3 d, vec3 throughput, float skyLM, ivec2 px) {
    uint i = atomicAdd(ptCount[b], 1u);
    if (i >= PT_QUEUE) return;   // more paths than GI pixels at 1080p: this one stops here
    ptPaths[uint(b & 1) * PT_QUEUE + i] = PtPath(vec4(o, uintBitsToFloat(uint(px.x) | (uint(px.y) << 16))),
        uvec4(packHalf2x16(d.xy), packHalf2x16(vec2(d.z, skyLM)), packHalf2x16(throughput.rg),
              packHalf2x16(vec2(throughput.b, 0.0))));
}

void ptPop(int b, uint i, out vec3 o, out vec3 d, out vec3 throughput, out float skyLM, out ivec2 px) {
    PtPath p = ptPaths[uint(b & 1) * PT_QUEUE + i];
    o = p.oPixel.xyz;
    uint bits = floatBitsToUint(p.oPixel.w);
    px = ivec2(bits & 0xffffu, bits >> 16);
    vec2 dz = unpackHalf2x16(p.dThr.y);
    d = normalize(vec3(unpackHalf2x16(p.dThr.x), dz.x));
    skyLM = dz.y;
    throughput = vec3(unpackHalf2x16(p.dThr.z), unpackHalf2x16(p.dThr.w).x);
}
