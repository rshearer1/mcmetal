#!/usr/bin/env python3
"""Automatic materials for blocks without PBR maps: picks ores, metal blocks, gem blocks and polished stone out
of a list of block ids (one namespace:name per line, e.g. every assets/*/blockstates/*.json name in the modpack's
jars) and writes them between the BEGIN/END AUTO MATERIALS lines of shaders/block.properties:
  10400 ores (the bright, coloured texels glint), 10401 metal blocks, 10402 gem blocks, 10403 polished stone and tiles.
Blocks the file already names elsewhere (plants, glass, lights) are left out, since a block on two lines keeps only
one id. Iris skips names that aren't installed. Usage: gen_auto_materials.py blocks.txt [pack dir]"""
import pathlib, re, sys

here = pathlib.Path(__file__).resolve().parent
pack = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else here.parent / "mcmetal-rt-pack"
props = pack / "shaders/block.properties"

METALS = r"(iron|gold|golden|copper|steel|bronze|brass|silver|tin|lead|zinc|nickel|platinum|aluminum|aluminium|" \
         r"netherite|pewter|cobalt|osmium|uranium|electrum|invar|constantan|titanium|tungsten|rose_gold|andesite_alloy|" \
         r"mythril|orichalcum|adamantite|desh|ostrum|calorite|industrial_iron|cast_iron|wrought_iron)"
GEMS = r"(diamond|emerald|amethyst|quartz|ruby|sapphire|topaz|peridot|jade|crystal|gem|opal|onyx|citrine|" \
       r"source_gem|fluix|certus|prismarine_crystal)"

def classify(name):
    if re.search(r"(^|_)ore($|_)", name) and "chest" not in name and "core" not in name and "cluster" not in name:
        return 10400
    if re.fullmatch(rf"((raw_|\w+_)?{METALS}_block|block_of_{METALS}|(exposed|weathered|oxidized|waxed)(_\w+)?_copper|"
                    rf"(cut|chiseled)_copper(_\w+)?|{METALS}_(plate|plates|tiles|bars_block|sheetmetal|sheet_metal))", name) \
            or name in ("copper_block", "iron_block", "gold_block", "netherite_block", "heavy_core"):
        return None if name.startswith("raw_") or "_raw_" in name else 10401
    if re.fullmatch(rf"((\w+_)?{GEMS}_block|block_of_{GEMS}|budding_amethyst|smooth_quartz|quartz_bricks|quartz_pillar|"
                    rf"chiseled_quartz_block)", name):
        return 10402
    if re.search(r"(^|_)(polished|smooth)_", name) or name.startswith(("polished_", "smooth_")) \
            or name.endswith("glazed_terracotta") or re.search(r"(^|_)(marble|tiles?)($|_)", name):
        if not re.search(r"(sandstone|basalt)$", name) or name.startswith(("polished", "smooth")):
            return 10403
    return None

text = props.read_text()
begin, end = "# BEGIN AUTO MATERIALS", "# END AUTO MATERIALS"
if begin in text:
    pre, rest = text.split(begin, 1)
    post = rest.split(end, 1)[1].lstrip("\n")
else:
    pre, post = text.rstrip("\n") + "\n", ""
taken = set(re.findall(r"[a-z0-9_.-]+:[a-z0-9_/.-]+|(?<![:\w])[a-z0-9_]+(?=[\s\\:]|$)", pre + post))
groups = {10400: [], 10401: [], 10402: [], 10403: []}
# vanilla's own (the modpack's jars don't list them)
VANILLA = """coal_ore deepslate_coal_ore iron_ore deepslate_iron_ore copper_ore deepslate_copper_ore gold_ore
deepslate_gold_ore redstone_ore deepslate_redstone_ore emerald_ore deepslate_emerald_ore lapis_ore deepslate_lapis_ore
diamond_ore deepslate_diamond_ore nether_gold_ore nether_quartz_ore iron_block gold_block copper_block exposed_copper
weathered_copper oxidized_copper cut_copper exposed_cut_copper weathered_cut_copper oxidized_cut_copper
waxed_copper_block waxed_exposed_copper waxed_weathered_copper waxed_oxidized_copper netherite_block heavy_core
chiseled_copper copper_grate diamond_block emerald_block amethyst_block budding_amethyst lapis_block quartz_block
smooth_quartz quartz_bricks quartz_pillar chiseled_quartz_block polished_andesite polished_diorite polished_granite
polished_deepslate polished_blackstone polished_blackstone_bricks polished_basalt polished_tuff smooth_stone
smooth_sandstone smooth_red_sandstone deepslate_tiles calcite""".split()
names = [f"minecraft:{v}" for v in VANILLA] + pathlib.Path(sys.argv[1]).read_text().split()
for line in names:
    if ":" not in line or line.startswith("#"): continue
    ns, name = line.split(":", 1)
    ident = name if ns == "minecraft" else f"{ns}:{name}"
    if ident in taken or name in taken and ns == "minecraft": continue
    k = classify(name)
    if ns == "minecraft" and name in ("lapis_block", "calcite", "copper_grate", "chiseled_copper"):
        k = {"lapis_block": 10402, "calcite": 10403}.get(name, 10401)
    if k: groups[k].append(ident)
out = [begin + " (shaderpack/tools/gen_auto_materials.py; ores, metal, gems, polished stone without PBR maps)"]
for k, names in groups.items():
    names = sorted(set(names))
    if not names: continue
    lines, cur = [], f"block.{k}="
    for n in names:
        if len(cur) + len(n) > 110:
            lines.append(cur + " \\"); cur = " "
        cur += n + " "
    lines.append(cur.rstrip())
    out += lines
    print(k, len(names))
out.append(end)
props.write_text(pre.rstrip("\n") + "\n" + "\n".join(out) + "\n" + post)
