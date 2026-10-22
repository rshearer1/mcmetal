#!/usr/bin/env python3
"""Per-frame GL call table from two glprof snapshots (see tools/glprof.h).

Usage: python3 -I glprof_report.py START END [TOP]

Prints, for the window between the two snapshots: frame time, how much of it was CPU time inside GL calls, inside
swap (waiting for the GPU or a drawable) and outside GL (Java: Minecraft, Sodium, Iris), then each GL function by
CPU time per frame with calls per frame, ns per call and its size figure per frame, and the same by call group.
"""
import re
import sys

AUX_UNIT = [
    (r"^gl(Named)?Buffer(Sub)?Data$|^gl(Named)?BufferStorage$|Copy(Named)?BufferSubData$|MapBufferRange|FlushMapped", "bytes"),
    (r"^glTex(ture)?(Sub)?Image[23]D$|^glReadPixels$|^glBlitFramebuffer$", "texels"),
    (r"^glMultiDraw", "sub-draws"),
    (r"^glDraw", "vertices"),
    (r"^glDispatchCompute$", "groups"),
]
GROUPS = [
    ("draw", r"^gl(Multi)?Draw"),
    ("compute", r"^glDispatch|^glMemoryBarrier"),
    ("uniform", r"^gl(Program)?Uniform|^glGetUniformLocation|^glGetUniformBlockIndex|^glUniformBlockBinding"),
    ("buffer upload/map", r"Buffer(Sub)?Data$|BufferStorage$|MapBuffer|UnmapBuffer|FlushMapped|CopyBufferSubData|CopyNamedBufferSubData|^glClearBuffer"),
    ("texture upload/copy", r"^glTex(ture)?(Sub)?Image|^glCopyTex|^glGenerateMipmap|^glClearTex|^glCopyImageSubData|^glPixelStore"),
    ("texture bind/params", r"^glBindTexture|^glActiveTexture|^glTexParameter|^glBindImageTexture|^glBindSampler|^glSamplerParameter|^glTextureParameter"),
    ("framebuffer", r"Framebuffer|^glDrawBuffer|^glReadBuffer|^glClear|^glBlitFramebuffer|^glViewport|^glScissor"),
    ("program", r"^glUseProgram|^glProgram|^glShader|^glCompileShader|^glLinkProgram|^glAttachShader|^glDetachShader|^glCreate(Program|Shader)|^glDelete(Program|Shader)|^glBindAttribLocation|^glBindFragDataLocation"),
    ("vertex setup", r"VertexArray|VertexAttrib|^glBindBuffer|^glBindVertexBuffer"),
    ("blend/depth/raster state", r"^glEnable|^glDisable|^glBlend|^glDepth|^glColorMask|^glCullFace|^glFrontFace|^glPolygon|^glStencil|^glLineWidth|^glLogicOp"),
    ("queries/gets/sync", r"^glGet|^glIs|^glFence|^glClientWaitSync|^glWaitSync|^glDeleteSync|^glFinish|^glFlush|Query"),
    ("object create/delete", r"^glGen|^glDelete|^glCreate"),
]


def load(path):
    meta, rows = {}, {}
    for line in open(path):
        if line.startswith("#") or not line.strip():
            continue
        p = line.split()
        if p[0].startswith("@"):
            meta[p[0][1:]] = [int(x) for x in p[1:]]
        else:
            rows[p[0]] = tuple(int(x) for x in p[1:4])
    return meta, rows


def unit(name):
    for pat, u in AUX_UNIT:
        if re.search(pat, name):
            return u
    return ""


def group(name):
    for g, pat in GROUPS:
        if re.search(pat, name):
            return g
    return "other"


def main():
    (m0, r0), (m1, r1) = load(sys.argv[1]), load(sys.argv[2])
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    el = (m1["elapsed_ns"][0] - m0["elapsed_ns"][0]) / 1e9
    frames = m1["frames"][0] - m0["frames"][0]
    swap_ns = m1["swap"][1] - m0["swap"][1]
    d = {}
    for n, (c, ns, a) in r1.items():
        c0, ns0, a0 = r0.get(n, (0, 0, 0))
        if c - c0:
            d[n] = (c - c0, ns - ns0, a - a0)
    per = frames if frames else el  # no swap hook (Linux): per second instead
    what = "frame" if frames else "second"
    gl_ns = sum(v[1] for v in d.values())
    calls = sum(v[0] for v in d.values())
    print(f"window {el:.1f} s, {frames} frames ({frames / el:.1f} fps)" if frames else f"window {el:.1f} s (no frame count)")
    if frames:
        ft = el * 1e3 / frames
        g, s = gl_ns / frames / 1e6, swap_ns / frames / 1e6
        print(f"per frame: {ft:.2f} ms = GL calls {g:.2f} ms ({calls / frames:.0f} calls) + swap {s:.2f} ms"
              f" + outside GL (Java) {ft - g - s:.2f} ms")
    else:
        print(f"per second: GL calls {gl_ns / el / 1e6:.1f} ms in {calls / el:.0f} calls")
    print(f"\n{'GL function':44s} {'us/' + what:>10s} {'calls/' + what:>12s} {'ns/call':>9s}  size/{what}")
    for n, (c, ns, a) in sorted(d.items(), key=lambda kv: -kv[1][1])[:top]:
        u = unit(n)
        aux = f"{a / per:,.0f} {u}" if u and a else ""
        print(f"{n:44s} {ns / per / 1e3:10.1f} {c / per:12.1f} {ns / c:9.0f}  {aux}")
    gs = {}
    for n, (c, ns, a) in d.items():
        k = group(n)
        gc, gns = gs.get(k, (0, 0))
        gs[k] = (gc + c, gns + ns)
    print(f"\n{'call group':44s} {'us/' + what:>10s} {'calls/' + what:>12s} {'ns/call':>9s}")
    for k, (c, ns) in sorted(gs.items(), key=lambda kv: -kv[1][1]):
        print(f"{k:44s} {ns / per / 1e3:10.1f} {c / per:12.1f} {ns / c:9.0f}")


if __name__ == "__main__":
    main()
