# Glass test: a wall of clear glass, stained glass blocks and panes between the camera and a colourful back wall,
# a clear glass cube on the floor, ice; for refraction, tint and reflections.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-2 ~ ~-9 ~17 ~10 ~9 air
fill ~-2 ~-1 ~-9 ~17 ~-1 ~9 grass_block
fill ~12 ~ ~-6 ~12 ~5 ~6 white_concrete
fill ~12 ~1 ~-5 ~12 ~1 ~5 red_concrete
fill ~12 ~3 ~-5 ~12 ~3 ~5 blue_concrete
fill ~11 ~ ~-6 ~11 ~0 ~6 oak_planks
setblock ~11 ~1 ~0 lantern
# lanterns right behind the stained glass: their light reaches the floor in front through it (ours-glass-night)
setblock ~7 ~0 ~1 lantern
setblock ~7 ~0 ~2 lantern
fill ~5 ~ ~-4 ~5 ~3 ~-1 glass
fill ~5 ~ ~0 ~5 ~3 ~0 red_stained_glass
fill ~5 ~ ~1 ~5 ~3 ~1 lime_stained_glass
fill ~5 ~ ~2 ~5 ~3 ~2 light_blue_stained_glass
fill ~5 ~ ~3 ~5 ~3 ~4 glass_pane
fill ~8 ~ ~-3 ~9 ~1 ~-2 glass
fill ~8 ~ ~2 ~9 ~0 ~3 ice
