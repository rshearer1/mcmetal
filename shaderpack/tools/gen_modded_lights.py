#!/usr/bin/env python3
"""Give modded light blocks their light colour in the RT pack. Reads modded-lights.tsv (block, lit states, light
level, colour name) and writes the modded part of shaders/block.properties (between the BEGIN/END MODDED LIGHTS
lines) and shaders/lib/lights_modded.glsl (the colour and light level of each new id). They get ids 10110-10199
(bright texels glow) or 10209-10299 (glow all over), one per colour and level (never a vanilla light's id: a
repeated block.N line would replace the vanilla one). Iris skips block names that aren't installed, so the list is harmless without
the mods. Usage: gen_modded_lights.py [pack dir], default shaderpack/mcmetal-rt-pack"""
import collections, pathlib, re, sys

here = pathlib.Path(__file__).resolve().parent
pack = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else here.parent / "mcmetal-rt-pack"

# colour name: linear colour, glows all over
COLORS = {
    "torch": ((1.00, 0.55, 0.22), False), "soul": ((0.25, 0.75, 1.00), False), "redstone": ((1.00, 0.10, 0.03), False),
    "end_rod": ((1.00, 0.92, 0.88), False), "crying_obsidian": ((0.55, 0.20, 1.00), False),
    "amethyst": ((0.70, 0.35, 1.00), False), "copper": ((0.45, 1.00, 0.55), False),
    "glow_berries": ((1.00, 0.70, 0.30), False),
    "white": ((1.00, 0.93, 0.85), False), "orange": ((1.00, 0.48, 0.15), False), "yellow": ((1.00, 0.85, 0.30), False),
    "red": ((1.00, 0.18, 0.10), False), "pink": ((1.00, 0.50, 0.75), False), "magenta": ((1.00, 0.30, 0.90), False),
    "purple": ((0.60, 0.30, 1.00), False), "blue": ((0.25, 0.40, 1.00), False), "light_blue": ((0.45, 0.80, 1.00), False),
    "cyan": ((0.30, 0.95, 0.95), False), "green": ((0.35, 1.00, 0.35), False), "lime": ((0.60, 1.00, 0.25), False),
    "brown": ((0.85, 0.55, 0.30), False),
    "lava": ((1.00, 0.40, 0.10), True), "soul_fire": ((0.25, 0.75, 1.00), True), "glowstone": ((1.00, 0.75, 0.42), True),
    "sea_lantern": ((0.70, 0.90, 1.00), True), "shroomlight": ((1.00, 0.55, 0.28), True),
    "ochre": ((1.00, 0.82, 0.40), True), "verdant": ((0.55, 1.00, 0.45), True), "pearlescent": ((1.00, 0.55, 1.00), True),
    "magma": ((1.00, 0.30, 0.08), True),
}

def bucket(level):  # fewer distinct levels, so the ids fit
    for top, b in ((3, 3), (6, 5), (9, 7), (12, 10), (14, 14)):
        if level <= top: return b
    return 15

groups = collections.defaultdict(list)
for line in (here / "modded-lights.tsv").read_text().splitlines():
    if line.startswith("#") or not line.strip(): continue
    block, states, level, color = line.split("\t")
    if states:
        key, vals = states.split("=", 1)
        tokens = ["%s:%s=%s" % (block, key, v) for v in vals.split(",")]
    else:
        tokens = [block]
    groups[(color, bucket(int(level)))] += tokens

ids, next_id = {}, {False: 10110, True: 10209}
for key in sorted(groups, key=lambda k: (-len(groups[k]), k)):
    glow = COLORS[key[0]][1]
    ids[key] = next_id[glow]
    next_id[glow] += 1
if next_id[False] > 10200 or next_id[True] > 10300:
    raise SystemExit("too many modded light ids: %s" % next_id)

props = ["# BEGIN MODDED LIGHTS (made by shaderpack/tools/gen_modded_lights.py from tools/modded-lights.tsv; don't edit)"]
for key in sorted(groups, key=lambda k: ids[k]):
    toks = sorted(groups[key])
    lines = [" ".join(toks[i:i + 8]) for i in range(0, len(toks), 8)]
    props.append("block.%d=%s" % (ids[key], " \\\n ".join(lines)))
props.append("# END MODDED LIGHTS")
bp = pack / "shaders/block.properties"
text = bp.read_text()
text = re.sub(r"\n# BEGIN MODDED LIGHTS.*?# END MODDED LIGHTS\n", "\n", text, flags=re.S).rstrip("\n") + "\n"
bp.write_text(text + "\n".join(props) + "\n")

glsl = ["// Modded light blocks' colour and vanilla light level by block id (made by shaderpack/tools/gen_modded_lights.py",
        "// from tools/modded-lights.tsv; don't edit). Used by lightColorOf in lib/lights.glsl.",
        "vec3 moddedLightColor(int id, inout float level) {",
        "    switch (id) {"]
for key in sorted(groups, key=lambda k: ids[k]):
    (r, g, b), _ = COLORS[key[0]]
    glsl.append("    case %d: level = %.1f; return vec3(%.2f, %.2f, %.2f); // %s, %d blocks"
                % (ids[key], key[1], r, g, b, key[0], len(groups[key])))
glsl += ["    }", "    return vec3(1.0, 0.6, 0.3);", "}", ""]
(pack / "shaders/lib/lights_modded.glsl").write_text("\n".join(glsl))
print("%d tokens, %d ids, next free ids %s" % (sum(map(len, groups.values())), len(groups), next_id))
