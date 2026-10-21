// Does the Metal compiler keep GLSL's wrap-around for signed left shifts? Iris decodes normals with
// (int(packed) << 20) >> 20 (sign-extend 12 bits); MSL inherits C++'s overflow rule.
// Run: swift tests/shift_check.swift   (prints GPU vs expected for a few packed values)
import Metal
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void k(device const uint *in [[buffer(0)]], device int2 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    int sx = int(in[i]);
    out[i] = int2((sx << 8) >> 20, (sx << 20) >> 20);
}
"""
let dev = MTLCreateSystemDefaultDevice()!
for mode in ["relaxed", "safe"] {
    let o = MTLCompileOptions()
    if #available(macOS 15.0, *) { o.mathMode = mode == "safe" ? .safe : .relaxed }
    let lib = try! dev.makeLibrary(source: src, options: o)
    let ps = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "k")!)
    let vals: [UInt32] = [0x00_801_000 | 0x000, 0x7F_000_801, 0x80_801_7FF, 0xFF_FFF_FFF, 0x12_345_678]
    let inb = dev.makeBuffer(bytes: vals, length: vals.count * 4)!
    let outb = dev.makeBuffer(length: vals.count * 8)!
    let q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(ps); e.setBuffer(inb, offset: 0, index: 0); e.setBuffer(outb, offset: 0, index: 1)
    e.dispatchThreads(MTLSize(width: vals.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: vals.count, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let r = outb.contents().bindMemory(to: Int32.self, capacity: vals.count * 2)
    for (i, v) in vals.enumerated() {
        let s = Int32(bitPattern: v)
        let ex = ((s << 8) >> 20, (s << 20) >> 20)   // Swift: wrapping shifts, arithmetic right shift
        print(mode, String(format: "%08x", v), "gpu", r[2 * i], r[2 * i + 1], "expected", ex.0, ex.1, (r[2*i] == ex.0 && r[2*i+1] == ex.1) ? "OK" : "WRONG")
    }
}
