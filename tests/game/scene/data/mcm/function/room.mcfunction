# Test room for our shader pack's ray-traced light: a roofed room open towards the camera, sunlight through a hole
# in the roof, red and lime walls that should tint the white floor (bounce light), a pillar for a cast shadow,
# leaves on the roof edge (cutout shadows) and a lantern in the dark back corner.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-2 ~ ~-9 ~17 ~10 ~9 air
fill ~-2 ~-1 ~-9 ~17 ~-1 ~9 grass_block
fill ~4 ~-1 ~-6 ~14 ~-1 ~6 white_concrete
fill ~4 ~ ~-6 ~14 ~5 ~-6 red_wool
fill ~4 ~ ~6 ~14 ~5 ~6 lime_wool
fill ~14 ~ ~-6 ~14 ~5 ~6 white_concrete
fill ~4 ~5 ~-6 ~14 ~5 ~6 white_concrete
fill ~8 ~5 ~-2 ~10 ~5 ~0 air
fill ~4 ~6 ~-6 ~14 ~6 ~-6 oak_leaves[persistent=true]
fill ~9 ~ ~2 ~9 ~4 ~2 stone_bricks
setblock ~13 ~ ~-5 lantern
setblock ~13 ~ ~5 light_blue_stained_glass
