# Showcase stage for what mcmetal unlocks on a Mac (Complementary's coloured light and the effects built on it).
# The camera looks down +x over a reflective floor: a stained-glass wall with lights behind it at the far end,
# a pool in the middle, every light colour along the left, a nether portal, beacon and candles on the right.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
gamerule randomTickSpeed 0
function mcm:time
fill ~-2 ~ ~-11 ~26 ~12 ~11 air
fill ~-2 ~-1 ~-11 ~26 ~-3 ~11 polished_deepslate
fill ~2 ~-1 ~-2 ~6 ~-1 ~2 polished_diorite
fill ~9 ~-1 ~-3 ~15 ~-1 ~3 water
fill ~9 ~-2 ~-3 ~15 ~-2 ~3 prismarine_bricks
# far wall: connected stained glass in eight colours, light sources behind each pair of panels
fill ~23 ~ ~-9 ~24 ~6 ~9 black_concrete
fill ~22 ~ ~-8 ~22 ~4 ~-7 red_stained_glass
fill ~22 ~ ~-6 ~22 ~4 ~-5 orange_stained_glass
fill ~22 ~ ~-4 ~22 ~4 ~-3 yellow_stained_glass
fill ~22 ~ ~-2 ~22 ~4 ~-1 lime_stained_glass
fill ~22 ~ ~0 ~22 ~4 ~1 cyan_stained_glass
fill ~22 ~ ~2 ~22 ~4 ~3 blue_stained_glass
fill ~22 ~ ~4 ~22 ~4 ~5 purple_stained_glass
fill ~22 ~ ~6 ~22 ~4 ~7 magenta_stained_glass
fill ~23 ~1 ~-8 ~23 ~3 ~7 sea_lantern
fill ~21 ~5 ~-9 ~23 ~5 ~9 black_concrete
# left: every light colour on a deepslate shelf
fill ~6 ~ ~-7 ~21 ~ ~-7 polished_blackstone
setblock ~6 ~1 ~-7 torch
setblock ~7 ~1 ~-7 soul_torch
setblock ~8 ~1 ~-7 redstone_torch
setblock ~9 ~1 ~-7 lantern
setblock ~10 ~1 ~-7 soul_lantern
setblock ~11 ~1 ~-7 campfire
setblock ~12 ~1 ~-7 soul_campfire
setblock ~13 ~1 ~-7 ochre_froglight
setblock ~14 ~1 ~-7 verdant_froglight
setblock ~15 ~1 ~-7 pearlescent_froglight
setblock ~16 ~1 ~-7 crying_obsidian
setblock ~17 ~1 ~-7 amethyst_cluster
setblock ~18 ~1 ~-7 jack_o_lantern[facing=south]
setblock ~19 ~1 ~-7 magma_block
setblock ~20 ~1 ~-7 shroomlight
setblock ~21 ~1 ~-7 end_rod
setblock ~19 ~2 ~-7 redstone_lamp[lit=true]
setblock ~19 ~3 ~-7 redstone_block
# right: nether portal (purple light, portal edge effect), beacon beam, coloured candles
fill ~16 ~ ~7 ~19 ~4 ~7 obsidian
fill ~17 ~1 ~7 ~18 ~3 ~7 nether_portal[axis=x]
fill ~9 ~-1 ~6 ~11 ~-1 ~8 iron_block
setblock ~10 ~ ~7 beacon
setblock ~10 ~1 ~7 light_blue_stained_glass
setblock ~6 ~ ~6 red_candle[candles=4,lit=true]
setblock ~7 ~ ~6 lime_candle[candles=4,lit=true]
setblock ~8 ~ ~6 blue_candle[candles=4,lit=true]
setblock ~13 ~ ~6 glow_lichen[down=true]
setblock ~14 ~ ~6 sea_pickle[pickles=4,waterlogged=false]
setblock ~12 ~-1 ~0 sea_pickle[pickles=4,waterlogged=true]
# a two-block plinth for a view over the whole stage
fill ~ ~ ~ ~ ~1 ~ polished_deepslate
tp @s ~ ~2 ~ facing ~22 ~0 ~0
