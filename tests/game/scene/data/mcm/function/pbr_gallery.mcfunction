# Resource-pack material gallery (GAME_RP=vanilla-rtx / spbr / ...): the everyday blocks of a cottage world side by
# side, so PBR packs compare like for like. Back wall: 2-wide columns of stone, wood and brick; floor: strips of
# path, dirt, grass, sand, gravel, planks; metals, glass, leaves and lights in front. Morning sun from the side.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-2 ~ ~-9 ~14 ~8 ~9 air
fill ~-2 ~-1 ~-9 ~14 ~-1 ~-7 grass_block
fill ~-2 ~-1 ~-6 ~14 ~-1 ~-4 dirt_path
fill ~-2 ~-1 ~-3 ~14 ~-1 ~-1 oak_planks
fill ~-2 ~-1 ~0 ~14 ~-1 ~2 cobblestone
fill ~-2 ~-1 ~3 ~14 ~-1 ~5 gravel
fill ~-2 ~-1 ~6 ~14 ~-1 ~9 sand
fill ~12 ~ ~-9 ~12 ~4 ~-8 stone_bricks
fill ~12 ~ ~-7 ~12 ~4 ~-6 bricks
fill ~12 ~ ~-5 ~12 ~4 ~-4 oak_log
fill ~12 ~ ~-3 ~12 ~4 ~-2 spruce_planks
fill ~12 ~ ~-1 ~12 ~4 ~0 mossy_cobblestone
fill ~12 ~ ~1 ~12 ~4 ~2 deepslate_tiles
fill ~12 ~ ~3 ~12 ~4 ~4 terracotta
fill ~12 ~ ~5 ~12 ~4 ~6 andesite
fill ~12 ~ ~7 ~12 ~4 ~9 white_wool
fill ~8 ~ ~-7 ~9 ~1 ~-6 iron_block
fill ~8 ~ ~-4 ~9 ~1 ~-3 gold_block
fill ~8 ~ ~-1 ~9 ~1 ~0 copper_block
fill ~8 ~ ~2 ~9 ~1 ~3 glass
fill ~8 ~ ~5 ~9 ~1 ~6 oak_leaves[persistent=true]
setblock ~6 ~ ~-5 lantern
setblock ~6 ~ ~-2 glowstone
setblock ~6 ~ ~1 sea_lantern
setblock ~6 ~ ~4 crafting_table
setblock ~6 ~ ~7 furnace[lit=true,facing=west]
fill ~4 ~-1 ~-9 ~5 ~-1 ~-8 water
