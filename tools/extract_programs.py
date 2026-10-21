#!/usr/bin/env python3
"""From an apitrace dump, write every linked program's shader sources as OUTDIR/p<N>/<stage>.glsl.

Usage: apitrace dump --color=never T.trace | python3 -I extract_programs.py OUTDIR
"""
import hashlib, os, re, sys

out = sys.argv[1]
call_re = re.compile(r"^(\d+) (gl\w+|memcpy)\(")
stype, ssrc, attached, seen = {}, {}, {}, set()
STAGE = {"GL_VERTEX_SHADER": "vertex", "GL_FRAGMENT_SHADER": "fragment", "GL_COMPUTE_SHADER": "compute"}


def handle(block):
    m = re.match(r"^\d+ glCreateShader\(type = (\w+)\) = (\d+)", block)
    if m:
        stype[m.group(2)] = STAGE.get(m.group(1), m.group(1))
        return
    m = re.match(r"^\d+ glShaderSource\(shader = (\d+), count = \d+, string = &\"(.*)\", length", block, re.S)
    if m:
        ssrc[m.group(1)] = m.group(2).replace('\\"', '"').replace("\\\\", "\\")
        return
    m = re.match(r"^\d+ glAttachShader\(program = (\d+), shader = (\d+)\)", block)
    if m:
        attached.setdefault(m.group(1), {})[stype.get(m.group(2))] = ssrc.get(m.group(2), "")
        return
    m = re.match(r"^\d+ glDetachShader\(program = (\d+), shader = (\d+)\)", block)
    if m:
        attached.get(m.group(1), {}).pop(stype.get(m.group(2)), None)
        return
    m = re.match(r"^\d+ glLinkProgram\(program = (\d+)\)", block)
    if m:
        stages = attached.get(m.group(1), {})
        key = hashlib.sha1(repr(sorted(stages.items())).encode()).hexdigest()[:12]
        if key in seen or not stages:
            return
        seen.add(key)
        d = os.path.join(out, "p" + key)
        os.makedirs(d, exist_ok=True)
        for st, src in stages.items():
            open(os.path.join(d, f"{st}.glsl"), "w").write(src)


cur = None
for line in sys.stdin:
    if call_re.match(line):
        if cur:
            handle(cur)
        cur = line
    elif cur is not None:
        cur += line
if cur:
    handle(cur)
print(len(seen), "unique programs")
