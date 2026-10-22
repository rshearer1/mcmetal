# Block-light shadow test: a closed stone room at night with a wall facing the camera. Each light has a pillar
# between it and the wall, so ray-traced block light should leave a sharp shadow of the pillar on the wall
# (a flood-filled light volume only dims softly round it).
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-1 ~-1 ~-6 ~10 ~7 ~6 stone
fill ~0 ~ ~-5 ~8 ~5 ~5 air
# torch in the middle, pillar of planks just behind it
setblock ~5 ~ ~0 torch
fill ~6 ~ ~0 ~6 ~1 ~0 oak_planks
# glowstone on the right with a cobblestone pillar
setblock ~4 ~ ~3 glowstone
fill ~6 ~ ~3 ~6 ~2 ~3 cobblestone
# soul lantern on the left with a fence post
setblock ~5 ~ ~-3 soul_lantern
fill ~6 ~ ~-3 ~6 ~1 ~-3 oak_fence
tp @s ~0.5 ~1.5 ~0.5 facing ~8 ~1 ~0.5
