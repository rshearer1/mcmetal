# Test scene for the visual sweep: a still pool (water + translucency), a waterfall into it, and every
# vanilla light colour ACT cares about. Time of day comes from time.mcfunction (written by ci_game.sh).
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-2 ~ ~-6 ~13 ~8 ~6 air
fill ~2 ~-1 ~-5 ~12 ~-3 ~5 stone
fill ~3 ~-1 ~-4 ~11 ~-2 ~4 water
fill ~12 ~ ~-1 ~12 ~4 ~1 stone
setblock ~11 ~4 ~0 water
setblock ~2 ~ ~-5 torch
setblock ~12 ~ ~-5 lantern
setblock ~12 ~ ~5 soul_lantern
setblock ~7 ~ ~-5 torch
setblock ~7 ~ ~5 campfire
setblock ~5 ~ ~-5 sea_lantern
setblock ~5 ~ ~5 glowstone
setblock ~9 ~ ~-5 shroomlight
setblock ~9 ~ ~5 end_rod
setblock ~10 ~-1 ~-5 lava
fill ~4 ~ ~-2 ~4 ~2 ~2 red_stained_glass
fill ~4 ~ ~-2 ~4 ~0 ~2 blue_stained_glass
setblock ~8 ~-2 ~0 sea_pickle[pickles=4,waterlogged=true]
# two dim lights in dark nooks close to the camera, where their small glow is easy to judge:
# redstone torch (light 7, red) on the left, soul torch (light 10, cyan) on the right
fill ~1 ~ ~-4 ~3 ~2 ~-4 stone
fill ~1 ~2 ~-4 ~3 ~2 ~-3 stone
setblock ~2 ~ ~-3 redstone_torch
fill ~1 ~ ~4 ~3 ~2 ~4 stone
fill ~1 ~2 ~3 ~3 ~2 ~4 stone
setblock ~2 ~ ~3 soul_torch
tp @s ~ ~1.5 ~ facing ~8 ~-1 ~0
