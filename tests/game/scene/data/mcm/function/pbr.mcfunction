# LabPBR test stage (with tests/game/rp/make_labpbr_test.py's pack): a mirror-polished white floor, stone-brick
# walls with deep mortar (normal maps), iron and gold blocks (metals), smooth stone with glowing texels.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-2 ~ ~-8 ~16 ~8 ~8 air
fill ~-2 ~-1 ~-8 ~16 ~-1 ~8 white_concrete
fill ~14 ~ ~-7 ~14 ~5 ~7 stone_bricks
fill ~4 ~ ~-7 ~13 ~4 ~-7 stone_bricks
fill ~8 ~ ~-2 ~9 ~1 ~-1 iron_block
fill ~8 ~ ~1 ~9 ~1 ~2 gold_block
fill ~11 ~ ~4 ~12 ~2 ~5 smooth_stone
setblock ~6 ~ ~-4 lantern
setblock ~6 ~ ~4 torch
