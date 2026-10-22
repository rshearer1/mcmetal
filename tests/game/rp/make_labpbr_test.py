#!/usr/bin/env python3
"""Builds a tiny LabPBR test resource pack (our own textures, nothing copied) for the RT pack's PBR path:
stone bricks with deep mortar grooves (normal map), a mirror-polished white concrete floor, iron and gold
blocks as metals, glowing texels on smooth stone. Plain Python, no libraries. Usage: make_labpbr_test.py OUT.zip"""
import json, math, struct, sys, zipfile, zlib

S = 16

def png(px):  # px[y][x] = (r, g, b, a) bytes
    raw = b"".join(b"\0" + bytes(c for p in row for c in p) for row in px)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

def normal_from_height(h, strength):
    out = []
    for y in range(S):
        row = []
        for x in range(S):
            gx = (h[y][(x + 1) % S] - h[y][(x - 1) % S]) * strength
            gy = (h[(y + 1) % S][x] - h[(y - 1) % S][x]) * strength
            l = math.sqrt(gx * gx + gy * gy + 1.0)
            # LabPBR: rg normal xy, b AO (255 = none), a height
            row.append((round((-gx / l * 0.5 + 0.5) * 255), round((-gy / l * 0.5 + 0.5) * 255), 255, round(h[y][x] * 255)))
        out.append(row)
    return out

def spec(smooth, f0, emission=None):  # LabPBR: r smoothness, g F0 (230+ = metal), b porosity, a emission (255 = none)
    return [[(round(smooth * 255), f0, 0, 255 if emission is None else emission[y][x]) for x in range(S)] for y in range(S)]

mortar = [[1.0 if (y % 8 == 0 or (x + (y // 8 % 2) * 4) % 8 == 0) else 0.0 for x in range(S)] for y in range(S)]
bricks_h = [[1.0 - m for m in row] for row in mortar]
flat = [[1.0] * S for _ in range(S)]
glow = [[200 if 6 <= x < 10 and 6 <= y < 10 else 255 for x in range(S)] for y in range(S)]
files = {
    "assets/minecraft/textures/block/stone_bricks_n.png": normal_from_height(bricks_h, 2.0),
    "assets/minecraft/textures/block/stone_bricks_s.png": spec(0.35, 10),
    "assets/minecraft/textures/block/white_concrete_n.png": normal_from_height(flat, 1.0),
    "assets/minecraft/textures/block/white_concrete_s.png": spec(0.92, 10),
    "assets/minecraft/textures/block/iron_block_s.png": spec(0.85, 230),
    "assets/minecraft/textures/block/gold_block_s.png": spec(0.75, 231),
    "assets/minecraft/textures/block/smooth_stone_s.png": spec(0.6, 10, glow),
}
meta = {"pack": {"pack_format": 34, "description": "mcmetal RT pack: LabPBR test textures"}}
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("pack.mcmeta", json.dumps(meta))
    for k, v in files.items():
        z.writestr(k, png(v))
print("wrote", sys.argv[1], len(files), "textures")
