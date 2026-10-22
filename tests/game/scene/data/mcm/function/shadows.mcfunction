# Block-light shadow test: a closed stone room at night with a wall facing the camera. Each light stands one block
# in front of a pillar, three blocks from the wall, so ray-traced block light should leave a sharp shadow about
# three blocks wide on the wall behind each pillar (a flood-filled light volume only dims softly round it).
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-1 ~-1 ~-7 ~8 ~6 ~7 stone
fill ~0 ~ ~-6 ~6 ~4 ~6 air
# torch in the middle, plank pillar just behind it
setblock ~3 ~ ~0 torch
fill ~4 ~ ~0 ~4 ~1 ~0 oak_planks
# glowstone on the right with a cobblestone pillar
setblock ~3 ~ ~4 glowstone
fill ~4 ~ ~4 ~4 ~2 ~4 cobblestone
# soul lantern on the left with a fence post
setblock ~3 ~ ~-4 soul_lantern
fill ~4 ~ ~-4 ~4 ~1 ~-4 oak_fence
tp @s ~0.5 ~1.5 ~0.5 facing ~7 ~1 ~0.5
