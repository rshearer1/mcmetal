#!/usr/bin/env python3
"""Converts Cubeir's Vanilla RTX (Bedrock RTX PBR maps) into a Java LabPBR 1.3 resource pack (_n and _s maps).

Vanilla RTX is the pack most Bedrock RTX players use, so this gives Java shader packs the Bedrock RTX look.
Only Cubeir's PBR maps go into the output, converted; the colour textures (Mojang's art) are never copied.
Vanilla RTX's licence allows modified redistribution with credit and a link to its licence, and it must stay
free: the output gets README.txt with the credit and the licence link. Plain Python, no libraries.

  vanilla_rtx_labpbr.py VANILLA_RTX_DIR CLIENT_JAR OUT.zip [--opus] [--emissive-gain 3.0]

VANILLA_RTX_DIR is a checkout of https://github.com/Cubeir/Vanilla-RTX. CLIENT_JAR is Minecraft 1.21.1's client
jar: Bedrock and Java name many textures differently, so each Bedrock colour texture is matched to the Java
texture with the same pixels (plus a short table for the ones that differ). --opus takes the 96x hand-made +
height-derived normals of Vanilla RTX Opus instead of the 16x ones of Vanilla RTX Normals.

Channel mapping (Bedrock texture set -> LabPBR):
  MERS r metalness  -> _s g: 255 (albedo as F0) when >= 128, else 10 (F0 0.04)
  MERS g emissive   -> _s a: emissive * gain, 0..254 (255 = no emission)
  MERS b roughness  -> _s r: perceptual smoothness = 255 - roughness
  MERS a subsurface -> _s b: 65..255 (LabPBR's subsurface range), 0 = none
  normal (DirectX)  -> _n rg with green flipped (LabPBR is OpenGL, Y+); b = 255 (no AO)
  heightmap         -> _n a: 255 - (255 - h) / 2 (half depth: parallax stays gentle, like Bedrock's)
"""
import io, json, os, struct, sys, zipfile, zlib

VERSION = "1"
COLOURS = ["white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "silver", "cyan",
           "purple", "blue", "brown", "green", "red", "black"]
# Bedrock texture -> Java texture where the pixels differ (recoloured, retinted, or a different file split)
RENAMES = {
    "grass_side": ["grass_block_side"], "grass_side_snowed": ["grass_block_snow"],
    "nether_brick": ["nether_bricks"], "red_nether_brick": ["red_nether_bricks"], "slime": ["slime_block"],
    "honey_bottom": ["honey_block_bottom"], "honey_side": ["honey_block_side"], "honey_top": ["honey_block_top"],
    "kelp_a": ["kelp_plant"], "kelp_top": ["kelp"], "dried_kelp_top": ["dried_kelp_top", "dried_kelp_bottom"],
    "piston_top_normal": ["piston_top"], "piston_top_sticky": ["piston_top_sticky"],
    "redstone_dust_cross": ["redstone_dust_dot"], "redstone_dust_line": ["redstone_dust_line0", "redstone_dust_line1"],
    "pumpkin_stem_disconnected": ["pumpkin_stem"], "melon_stem_disconnected": ["melon_stem"],
    "portal": ["nether_portal"], "cocoa_stage_2": ["cocoa_stage2"], "lightning_rod_powered": ["lightning_rod_on"],
    "bamboo_leaf": ["bamboo_large_leaves"], "bamboo_small_leaf": ["bamboo_small_leaves"],
    "beehive_top": ["beehive_end"], "trip_wire": ["tripwire"], "planks_spruce": ["spruce_planks"],
    "leaves_oak": ["oak_leaves"], "leaves_jungle": ["jungle_leaves"], "leaves_acacia": ["acacia_leaves"],
    "leaves_big_oak": ["dark_oak_leaves"], "leaves_birch": ["birch_leaves"], "leaves_spruce": ["spruce_leaves"],
    "double_plant_syringa_top": ["lilac_top"], "double_plant_syringa_bottom": ["lilac_bottom"],
    "observer_back_lit": ["observer_back_on"], "glazed_terracotta_purple": ["purple_glazed_terracotta"],
    "coral_red": ["fire_coral_block"], "coral_purple": ["bubble_coral_block"],
    "crimson_log_side": ["crimson_stem"], "crimson_log_top": ["crimson_stem_top"],
    "warped_stem_side": ["warped_stem"], "stripped_crimson_stem_side": ["stripped_crimson_stem"],
    "stripped_warped_stem_side": ["stripped_warped_stem"], "crimson_door_lower": ["crimson_door_bottom"],
    "warped_door_lower": ["warped_door_bottom"], "weeping_vines_base": ["weeping_vines_plant"],
    "weeping_vines_bottom": ["weeping_vines"],
}
for c in COLOURS:
    j = "light_gray" if c == "silver" else c
    RENAMES[f"glass_{c}"] = [f"{j}_stained_glass"]
    RENAMES[f"glass_pane_top_{c}"] = [f"{j}_stained_glass_pane_top"]


class Img:  # RGBA, 8 bits per channel, rows top to bottom
    def __init__(self, w, h, px):
        self.w, self.h, self.px = w, h, px  # px: bytearray w*h*4

    def frames(self):
        return self.h // self.w if self.h > self.w and self.h % self.w == 0 else 1

    def crop_top(self, n):
        return Img(self.w, n, self.px[:self.w * n * 4])

    def resize(self, w):  # nearest, keeps aspect
        if w == self.w:
            return self
        h = self.h * w // self.w
        out = bytearray(w * h * 4)
        for y in range(h):
            sy = y * self.h // h
            for x in range(w):
                sx = x * self.w // w
                o, s = (y * w + x) * 4, (sy * self.w + sx) * 4
                out[o:o + 4] = self.px[s:s + 4]
        return Img(w, h, out)

    def frames_as(self, n):
        """n animation frames: this strip if it already has n frames, else frame 0 repeated."""
        if self.frames() == n:
            return self
        f = self.crop_top(self.w)
        return Img(self.w, self.w * n, f.px * n)

    def key(self):  # frame 0 at 16x16, transparent pixels zeroed: identical art gives identical keys
        f = self.crop_top(self.w).resize(16)
        p = bytearray(f.px)
        for i in range(0, len(p), 4):
            if p[i + 3] == 0:
                p[i:i + 4] = b"\0\0\0\0"
        return bytes(p)


def read_tga(data):
    idlen, cmtype, itype = data[0], data[1], data[2]
    w, h, bpp, desc = struct.unpack_from("<HHBB", data, 12)
    if cmtype or itype not in (2, 3, 10, 11) or bpp not in (8, 24, 32):
        raise ValueError(f"unsupported TGA type {itype} bpp {bpp}")
    n, src, pos = w * h, data, 18 + idlen
    ch = bpp // 8
    raw = bytearray()
    if itype in (2, 3):
        raw = src[pos:pos + n * ch]
    else:  # RLE
        while len(raw) < n * ch:
            hdr = src[pos]; pos += 1
            cnt = (hdr & 0x7f) + 1
            if hdr & 0x80:
                raw += src[pos:pos + ch] * cnt; pos += ch
            else:
                raw += src[pos:pos + ch * cnt]; pos += ch * cnt
    px = bytearray(n * 4)
    for i in range(n):
        if ch == 1:
            px[i * 4:i * 4 + 4] = bytes((raw[i], raw[i], raw[i], 255))
        else:
            b, g, r = raw[i * ch], raw[i * ch + 1], raw[i * ch + 2]
            px[i * 4:i * 4 + 4] = bytes((r, g, b, raw[i * ch + 3] if ch == 4 else 255))
    if not desc & 0x20:  # bottom-up
        row = w * 4
        px = b"".join(px[y * row:(y + 1) * row] for y in reversed(range(h)))
    return Img(w, h, bytearray(px))


def read_png(data):
    pos, idat, plte, trns = 8, b"", None, None
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    while pos + 8 <= len(data):
        ln, = struct.unpack_from(">I", data, pos); t = data[pos + 4:pos + 8]; d = data[pos + 8:pos + 8 + ln]
        if t == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", d)
        elif t == b"PLTE":
            plte = d
        elif t == b"tRNS":
            trns = d
        elif t == b"IDAT":
            idat += d
        elif t == b"IEND":
            break
        pos += 12 + ln
    if depth not in (1, 2, 4, 8) or inter or (depth < 8 and ctype not in (0, 3)):
        raise ValueError("only non-interlaced 8-bit, or palette/grey 1-4 bit PNGs")
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw, stride, bpp = zlib.decompress(idat), (w * ch * depth + 7) // 8, max(1, ch * depth // 8)
    prev, rows, i = bytearray(stride), [], 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    px = bytearray(w * h * 4)
    per, mask = 8 // depth, (1 << depth) - 1
    for y, line in enumerate(rows):
        if depth < 8:  # unpack sub-byte samples, high bits first
            line = bytearray((line[x // per] >> (8 - depth * (x % per + 1))) & mask for x in range(w))
            if ctype == 0:
                line = bytearray(v * 255 // mask for v in line)
        for x in range(w):
            o = (y * w + x) * 4
            if ctype == 6: px[o:o + 4] = line[x * 4:x * 4 + 4]
            elif ctype == 2: px[o:o + 4] = line[x * 3:x * 3 + 3] + b"\xff"
            elif ctype == 0: px[o:o + 4] = bytes((line[x],) * 3 + (255,))
            elif ctype == 4: px[o:o + 4] = bytes((line[x * 2],) * 3 + (line[x * 2 + 1],))
            else:
                k = line[x]
                px[o:o + 4] = plte[k * 3:k * 3 + 3] + bytes((trns[k] if trns and k < len(trns) else 255,))
    return Img(w, h, px)


def write_png(img):
    row = img.w * 4
    raw = b"".join(b"\0" + bytes(img.px[y * row:(y + 1) * row]) for y in range(img.h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", img.w, img.h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    src, jar, out = args[:3]
    opus = "--opus" in argv
    gain = float(argv[argv.index("--emissive-gain") + 1]) if "--emissive-gain" in argv else 3.0
    nrm_dir = os.path.join(src, "Vanilla-RTX-Opus" if opus else "Vanilla-RTX-Normals", "textures", "blocks")
    hgt_dir = os.path.join(src, "Vanilla-RTX", "textures", "blocks")

    java, metas = {}, {}
    with zipfile.ZipFile(jar) as z:
        for n in z.namelist():
            if n.startswith("assets/minecraft/textures/block/") and n.count("/") == 4:
                b = n.rsplit("/", 1)[1]
                if b.endswith(".png"):
                    try:
                        java[b[:-4]] = read_png(z.read(n))
                    except ValueError:
                        pass
                elif b.endswith(".png.mcmeta"):
                    metas[b[:-11]] = z.read(n)
    by_key = {}
    for n, im in java.items():
        by_key.setdefault(im.key(), []).append(n)

    sets = {}
    for root, _, files in os.walk(nrm_dir):
        for f in files:
            if f.endswith(".texture_set.json"):
                rel = os.path.relpath(os.path.join(root, f[:-17]), nrm_dir)
                with open(os.path.join(root, f)) as fh:
                    sets[rel] = json.load(fh)["minecraft:texture_set"]

    owner = {}  # java texture -> Bedrock texture set; exact names win, then shorter non-mipmap names
    for rel in sorted(sets, key=lambda r: ("mipmap" in r, len(r), r)):
        ts, base, d = sets[rel], os.path.basename(rel), os.path.join(nrm_dir, os.path.dirname(rel))
        targets = set(t for t in RENAMES.get(base, []) if t in java)
        if base in java:
            targets.add(base)
        col = os.path.join(d, ts.get("color", "") + ".tga")
        if isinstance(ts.get("color"), str) and os.path.exists(col):
            with open(col, "rb") as fh:
                targets.update(by_key.get(read_tga(fh.read()).key(), []))
        for t in targets:
            if t not in owner or (t == base and os.path.basename(owner[t]) != t):
                owner[t] = rel

    def tga(path):
        with open(path, "rb") as fh:
            return read_tga(fh.read())

    counts = {"_s": 0, "_n": 0, "height": 0}
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("pack.mcmeta", json.dumps({"pack": {
            "pack_format": 34, "supported_formats": [34, 46],
            "description": "Vanilla RTX PBR (Bedrock RTX look) as LabPBR, by Cubeir; converted for Java"}}, indent=1))
        z.writestr("README.txt", README)
        for t, rel in sorted(owner.items()):
            ts, d = sets[rel], os.path.join(nrm_dir, os.path.dirname(rel))
            jw, nf = java[t].w, java[t].frames()
            mk = "metalness_emissive_roughness_subsurface" if "metalness_emissive_roughness_subsurface" in ts else "metalness_emissive_roughness"
            path = os.path.join(d, str(ts.get(mk)) + ".tga")
            wrote = []
            if os.path.exists(path):
                m = tga(path).resize(jw).frames_as(nf)
                s = bytearray(len(m.px))
                for i in range(0, len(s), 4):
                    met, emi, rough, sss = m.px[i:i + 4]
                    sss = sss if mk.endswith("subsurface") else 0
                    e = min(254, round(emi * gain))
                    s[i:i + 4] = bytes((255 - rough, 255 if met >= 128 else 10,
                                        round(65 + sss * 190 / 255) if sss else 0, e if e else 255))
                z.writestr(f"assets/minecraft/textures/block/{t}_s.png", write_png(Img(m.w, m.h, s)))
                counts["_s"] += 1; wrote.append("_s")
            path = os.path.join(d, str(ts.get("normal")) + ".tga")
            if os.path.exists(path):
                n = tga(path)
                nw = max(jw, n.w)
                n = n.resize(nw).frames_as(nf)
                hp = os.path.join(hgt_dir, rel + "_heightmap.tga")
                h = tga(hp).resize(nw).frames_as(nf) if os.path.exists(hp) else None
                if h and (h.w, h.h) != (n.w, n.h):
                    h = None
                o = bytearray(len(n.px))
                for i in range(0, len(o), 4):
                    o[i:i + 4] = bytes((n.px[i], 255 - n.px[i + 1], 255,
                                        255 - (255 - h.px[i]) // 2 if h else 255))
                z.writestr(f"assets/minecraft/textures/block/{t}_n.png", write_png(Img(n.w, n.h, o)))
                counts["_n"] += 1; counts["height"] += h is not None; wrote.append("_n")
            if nf > 1 and t in metas:  # the maps animate with the sprite
                for suf in wrote:
                    z.writestr(f"assets/minecraft/textures/block/{t}{suf}.png.mcmeta", metas[t])
    missing = sorted(set(java) - set(owner))
    print(f"{len(owner)} of {len(java)} Java block textures covered ({counts['_n']} normal maps, "
          f"{counts['height']} with height, {counts['_s']} specular maps); none for: {' '.join(missing)}")


README = """Vanilla RTX PBR for Java (LabPBR) - converted from Vanilla RTX by Cubeir

All PBR maps in this pack come from Vanilla RTX / Vanilla RTX Normals by Cubeir, converted from Bedrock's
texture-set format (MERS + DirectX normals + heightmaps) to Java's LabPBR 1.3 format. This is an unofficial
conversion and is not made, uploaded or endorsed by Cubeir. It contains no Minecraft colour textures.

Original source: https://github.com/Cubeir/Vanilla-RTX/
Vanilla RTX licence (applies to these files): https://github.com/Cubeir/Vanilla-RTX/blob/master/LICENSE.txt
Vanilla RTX is free and must stay free: do not sell this pack or put it behind a paywall.

Use with a LabPBR shader pack (Complementary: RP Support = labPBR; the mcmetal RT pack reads LabPBR by default).
Converted with mcmetal's shaderpack/tools/vanilla_rtx_labpbr.py.
"""

if __name__ == "__main__":
    main(sys.argv[1:])
