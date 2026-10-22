# Deep pool for caustics: open to the sun, 5 blocks deep over a sand floor, with prismarine and a stone pillar
# (a shadow under water, where the caustics should stop) and kelp.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-2 ~ ~-9 ~17 ~10 ~9 air
fill ~-2 ~-7 ~-9 ~17 ~-1 ~9 stone
fill ~2 ~-6 ~-6 ~14 ~-6 ~6 sand
fill ~2 ~-5 ~-6 ~14 ~-1 ~6 water
fill ~10 ~-5 ~-4 ~11 ~-4 ~-3 prismarine
fill ~6 ~-5 ~3 ~7 ~-5 ~4 prismarine_bricks
fill ~9 ~-5 ~1 ~9 ~3 ~1 stone_bricks
setblock ~5 ~-5 ~-2 kelp_plant
setblock ~5 ~-4 ~-2 kelp
setblock ~12 ~-5 ~4 kelp_plant
setblock ~12 ~-4 ~4 kelp_plant
setblock ~12 ~-3 ~4 kelp
