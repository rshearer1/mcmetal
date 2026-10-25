#!/usr/bin/env python3
"""Generates LabPBR maps (_n/_s) for modded blocks in the style of the Vanilla RTX conversion.

Mods almost never ship PBR maps, so with a PBR resource pack their blocks look flat next to vanilla ones. This
tool gives every block texture in the given mod jars (or resource-pack zips) maps that follow Vanilla RTX's
own rules, learned from the vanilla textures it covers:
  - height = brightness (Vanilla RTX's heightmaps track brightness, median correlation 0.76 over 551 textures),
    and the normal map tilts with the brightness slope at Vanilla RTX's strength (2.8x, its median);
  - smoothness and subsurface come from the closest colour among the vanilla pixels: a modded oak table gets
    the roughness Vanilla RTX gives oak planks, a modded marble gets what it gives quartz and calcite;
  - metal, glass and light only where the texture's name says so (iron/copper/gold/brass..., glass/crystal...,
    lantern/lamp/candle...), because colour alone can't tell gold from yellow wool.
Textures that are pixel copies of a vanilla texture (common in Chipped, Every Compat, ...) reuse the converted
Vanilla RTX maps as they are. Plain Python, no libraries.

  modded_labpbr.py VANILLA_RTX_LABPBR.zip CLIENT_JAR OUT.zip MOD.jar|DIR [...]

The output is made from the mods' own textures, so it is for local use: don't redistribute it unless each mod's
licence allows derived assets.
"""
import json, os, re, sys, zipfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vanilla_rtx_labpbr import Img, read_png, write_png

STRENGTH = 2.8
METAL = re.compile(r"(^|_)(iron|steel|copper|gold|golden|brass|bronze|silver|metal|tin|zinc|nickel|netherite|anvil|chain|cage|grate|kettle|cauldron|pot_rack|bell)($|_)")
GLASS = re.compile(r"(^|_)(glass|crystal|gem|jar|bottle|ice|window|pane|quartz_glass|amethyst|diamond|emerald)($|_)")
LIGHT = re.compile(r"(lantern|lamp|candle_lit|torch|glow|light|lit$|_lit_|fire|ember|brazier|campfire|sconce|chandelier|lava|magma|shroom)")
PLANT = re.compile(r"(leaves|leaf|grass|flower|crop|stage|sapling|vine|petal|bush|fern|moss|herb|plant|sprout|mushroom|tulip|rose|lily|reed|hay|wool|carpet|bed|cloth|fabric|curtain|banner|cushion)")


def lum(p):
    return (p[0] * 299 + p[1] * 587 + p[2] * 114) / 255000.0


def q(p):  # colour bin, 5 bits a channel
    return (p[0] >> 3) << 10 | (p[1] >> 3) << 5 | (p[2] >> 3)


def colour_table(vrtx_zip, jar):
    """For each colour bin, Vanilla RTX's mean smoothness and subsurface over the vanilla pixels of that colour;
    empty bins take their nearest filled neighbour (breadth-first over the colour cube)."""
    acc = {}
    with zipfile.ZipFile(vrtx_zip) as P, zipfile.ZipFile(jar) as J:
        spec = {n.rsplit("/", 1)[1][:-6]: n for n in P.namelist() if n.endswith("_s.png")}
        for t, n in spec.items():
            try:
                col = read_png(J.read(f"assets/minecraft/textures/block/{t}.png"))
            except (KeyError, ValueError):
                continue
            s = read_png(P.read(n))
            if (s.w, s.h) != (col.w, col.h):
                continue
            for i in range(0, len(col.px), 4):
                if col.px[i + 3] < 128:
                    continue
                k = q(col.px[i:i + 3])
                a = acc.setdefault(k, [0, 0, 0])
                a[0] += s.px[i]; a[1] += s.px[i + 2]; a[2] += 1
    table = [None] * 32768
    frontier = []
    for k, (sm, ss, n) in acc.items():
        table[k] = (round(sm / n), round(ss / n)); frontier.append(k)
    while frontier:
        nxt = []
        for k in frontier:
            r, g, b = k >> 10, (k >> 5) & 31, k & 31
            for dr, dg, db in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)):
                rr, gg, bb = r + dr, g + dg, b + db
                if 0 <= rr < 32 and 0 <= gg < 32 and 0 <= bb < 32:
                    kk = rr << 10 | gg << 5 | bb
                    if table[kk] is None:
                        table[kk] = table[k]; nxt.append(kk)
        frontier = nxt
    return table


def frame_wrap(w, h):  # neighbours wrap inside each animation frame
    fh = w if h > w and h % w == 0 else h
    return fh


def make_maps(col, name, table):
    w, h, px = col.w, col.h, col.px
    fh = frame_wrap(w, h)
    L = [lum(px[i:i + 3]) for i in range(0, len(px), 4)]
    metal, glass = bool(METAL.search(name)), bool(GLASS.search(name))
    light, plant = bool(LIGHT.search(name)), bool(PLANT.search(name))
    nmap, smap = bytearray(len(px)), bytearray(len(px))
    for y in range(h):
        f0 = y - y % fh
        yu, yd = f0 + (y - f0 - 1) % fh, f0 + (y - f0 + 1) % fh
        for x in range(w):
            i = y * w + x
            o = i * 4
            a = px[o + 3]
            xl, xr = y * w + (x - 1) % w, y * w + (x + 1) % w
            # transparent neighbours count as the pixel itself: cut-out edges stay flat instead of bevelled
            def l(j):
                return L[j] if px[j * 4 + 3] >= 128 else L[i]
            gx = (l(xr) - l(xl)) / 2 * STRENGTH
            gy = (l(yd * w + x) - l(yu * w + x)) / 2 * STRENGTH
            m2 = gx * gx + gy * gy
            if m2 > 0.81:
                k = 0.9 / m2 ** 0.5; gx *= k; gy *= k
            nmap[o:o + 4] = bytes((round((-gx * 0.5 + 0.5) * 255), round((gy * 0.5 + 0.5) * 255), 255,
                                   255 - round((1.0 - L[i]) * 127)))
            sm, ss = table[q(px[o:o + 3])] if a else (0, 0)
            f0v, em = 10, 255
            if not plant:
                ss = 0                                     # colour alone would give pale stone and wool leaf-like glow
            if metal:
                sm, f0v = max(sm, 150), 255
            if glass:
                sm = max(sm, 225)
            if plant:
                ss = max(ss, 140)
            if light and L[i] > 0.62:                      # the bright texels of lights glow, like Vanilla RTX's
                em = min(254, round((L[i] - 0.55) / 0.45 * 200))
            smap[o:o + 4] = bytes((sm, f0v, ss, em))
    return Img(w, h, nmap), Img(w, h, smap)


def sources(paths):
    for p in paths:
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if f.endswith((".jar", ".zip")):
                    yield os.path.join(p, f)
        else:
            yield p


def main(argv):
    vrtx, jar, out = argv[:3]
    table = colour_table(vrtx, jar)
    vanilla = {}
    with zipfile.ZipFile(jar) as J, zipfile.ZipFile(vrtx) as P:
        have = set(P.namelist())
        for n in J.namelist():
            t = n.rsplit("/", 1)[1][:-4] if n.startswith("assets/minecraft/textures/block/") and n.endswith(".png") else None
            if t and f"assets/minecraft/textures/block/{t}_n.png" in have:
                try:
                    vanilla[read_png(J.read(n)).key()] = (P.read(f"assets/minecraft/textures/block/{t}_n.png"),
                                                          P.read(f"assets/minecraft/textures/block/{t}_s.png"))
                except (ValueError, KeyError):
                    pass
    done, counts = set(), {"copied": 0, "generated": 0, "skipped": 0}
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("pack.mcmeta", json.dumps({"pack": {"pack_format": 34, "supported_formats": [34, 46],
                   "description": "Generated LabPBR maps for modded blocks (Vanilla RTX style), local use"}}, indent=1))
        for src in sources(argv[3:]):
            try:
                zs = zipfile.ZipFile(src)
            except zipfile.BadZipFile:
                continue
            names = set(zs.namelist())
            for n in sorted(names):
                p = n.split("/")
                if not (len(p) >= 5 and p[0] == "assets" and p[1] != "minecraft" and p[2] == "textures"
                        and p[3] in ("block", "blocks") and n.endswith(".png")) or n.endswith(("_n.png", "_s.png")):
                    continue
                base = n[:-4]
                if base in done or base + "_n.png" in names or base + "_s.png" in names:  # the mod's own maps win
                    counts["skipped"] += 1; continue
                done.add(base)
                try:
                    col = read_png(zs.read(n))
                except Exception:  # 16-bit, interlaced or broken PNGs: Minecraft's own loader copes, we skip them
                    counts["skipped"] += 1; continue
                if col.w > 256 or col.w * col.h > 256 * 4096:
                    counts["skipped"] += 1; continue
                v = vanilla.get(col.key()) if col.frames() == 1 and col.w == 16 and col.h == 16 else None
                if v:
                    z.writestr(base + "_n.png", v[0]); z.writestr(base + "_s.png", v[1]); counts["copied"] += 1
                else:
                    nm, sm = make_maps(col, p[-1][:-4], table)
                    z.writestr(base + "_n.png", write_png(nm)); z.writestr(base + "_s.png", write_png(sm))
                    counts["generated"] += 1
                if base + ".png.mcmeta" in names:
                    meta = zs.read(base + ".png.mcmeta")
                    z.writestr(base + "_n.png.mcmeta", meta); z.writestr(base + "_s.png.mcmeta", meta)
    print(f"{counts['generated']} generated, {counts['copied']} copied from vanilla matches, {counts['skipped']} skipped")


if __name__ == "__main__":
    main(sys.argv[1:])
