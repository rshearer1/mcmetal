# Block-light shadow test: a closed stone room at night with a wall facing the camera. Each light stands beside a
# pillar, one block off its line, so ray-traced block light throws the pillar's shadow sideways onto the wall at
# x=7, two blocks to the right of the pillar where the camera can see it (a flood-filled light volume only dims
# softly round it).
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-1 ~-1 ~-7 ~8 ~6 ~7 stone
fill ~0 ~ ~-6 ~6 ~4 ~6 air
# torch, plank pillar diagonally behind it (shadow on the wall near z=2)
setblock ~4 ~ ~-1 torch
fill ~5 ~ ~0 ~5 ~1 ~0 oak_planks
# glowstone with a cobblestone pillar (shadow near z=5)
setblock ~4 ~ ~2 glowstone
fill ~5 ~ ~3 ~5 ~2 ~3 cobblestone
# soul lantern with a fence post (shadow near z=-2)
setblock ~4 ~ ~-5 soul_lantern
fill ~5 ~ ~-4 ~5 ~1 ~-4 oak_fence
tp @s ~0.5 ~1.5 ~0.5 facing ~7 ~1.5 ~0.5
