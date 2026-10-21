#!/usr/bin/env python3
"""Compile every program of the pack with glslangValidator, the way Iris + mcmetal would see it.
Resolves /lib includes, adds the Iris macros we use and, for the RT variant, mcmetal's mcm_trace injection
(copied from core/mgl_program.c). Usage: check_pack.py <pack>/shaders"""
import os, pathlib, re, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1])
mgl = (pathlib.Path(__file__).resolve().parents[2] / "core/mgl_program.c").read_text()
head = re.search(r'static const char head\[\] = (.*?);\n', mgl, re.S).group(1)
body = re.search(r'static const char body\[\] =(.*?);\n', mgl, re.S).group(1)
unc = lambda s: "".join(eval(x) for x in re.findall(r'"(?:[^"\\]|\\.)*"', s))
HEAD, BODY = unc(head), unc(body)
# mcmetal's light list (mcm_lights_near): stub it until core/mgl_program.c supplies it, so the pack side compiles
if "mcm_lights_near" not in BODY:
    BODY += "\nint mcm_lights_near(vec3 p, int slot, out vec3 pos, out int blockId) { pos = vec3(0.0); blockId = 0; return -1; }\n"
IRIS = "#define MC_VERSION 12101\n#define MC_GL_VERSION 450\n#define MC_RENDER_STAGE_STARS 3\n#define MC_RENDER_STAGE_SUNSET 2\n"

def expand(path, seen):
    out = []
    for line in path.read_text().splitlines():
        m = re.match(r'\s*#include\s+"(.*)"', line)
        if m and not re.fullmatch(r'\s*#include\s+"[^"]*"\s*', line):
            raise SystemExit(f"{path.name}: Iris can't read an #include line with anything after it: {line.strip()}")
        if m:
            out.append(expand(root / m.group(1).lstrip("/"), seen))
        else:
            out.append(line)
    return "\n".join(out)

fails = 0
for f in sorted(root.glob("*.[vf]sh")):
    for rt in (False, True):
        src = expand(f, set())
        lines = src.split("\n", 1)
        src = lines[0] + "\n" + IRIS + ("#define MCMETAL_RT 1\n#define MCMETAL_LIGHTS 1\n" if rt else "") + lines[1]
        # strip Iris-only comment directives is unnecessary; glslang ignores comments
        stage = "vert" if f.suffix == ".vsh" else "frag"
        if rt and "mcm_trace" in re.sub(r"//.*", "", src):
            pass
        with tempfile.NamedTemporaryFile("w", suffix="." + stage, delete=False) as t:
            t.write(src)
        # the RT variant only differs when the preprocessed source calls mcm_trace: preprocess first
        pre = subprocess.run(["glslangValidator", "-E", t.name], capture_output=True, text=True).stdout
        if rt and "mcm_trace" not in pre:
            # no rays in this program, but its MCMETAL_RT/MCMETAL_LIGHTS branches still have to compile
            args = ["glslangValidator", t.name]
        elif rt:
            v = pre.index("#version"); eol = pre.index("\n", v)
            pre = pre[:v] + HEAD + pre[eol + 1:] + BODY
            # Iris turns compatibility shaders into core ones before mcmetal; our fragment shaders use no compat built-ins
            with open(t.name, "w") as w:
                w.write(pre)
            args = ["glslangValidator", "--target-env", "vulkan1.2", "-R", "--auto-map-locations", "--auto-map-bindings", "-o", os.devnull, t.name]
        else:
            args = ["glslangValidator", t.name]
        r = subprocess.run(args, capture_output=True, text=True)
        ok = r.returncode == 0
        fails += not ok
        print(("ok  " if ok else "FAIL") + f" {f.name} {'rt' if rt else 'gl'}")
        if not ok:
            print("   " + "\n   ".join(l for l in r.stdout.splitlines() if "ERROR" in l)[:2000])
sys.exit(1 if fails else 0)
