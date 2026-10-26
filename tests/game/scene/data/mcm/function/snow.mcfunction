# Snow stage for our shader pack: a snowy clearing in front of the camera (snow, snow layers, powder snow, ice,
# packed and blue ice, a frozen pond) with spruce trees and a lantern, for how white surfaces take sun, sky and
# bounce light without blowing out.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-2 ~-3 ~-10 ~22 ~-1 ~10 dirt
fill ~-2 ~-1 ~-10 ~22 ~-1 ~10 snow_block
fill ~-2 ~ ~-10 ~22 ~14 ~10 air
fill ~4 ~-1 ~-3 ~9 ~-1 ~2 ice
fill ~5 ~-1 ~-2 ~8 ~-1 ~1 packed_ice
setblock ~6 ~-1 ~0 blue_ice
fill ~11 ~ ~-6 ~14 ~ ~-3 snow[layers=3]
fill ~11 ~-1 ~3 ~13 ~-1 ~5 powder_snow
fill ~16 ~ ~-8 ~16 ~5 ~-8 spruce_log
fill ~15 ~3 ~-9 ~17 ~6 ~-7 spruce_leaves[persistent=true] replace air
fill ~18 ~ ~5 ~18 ~6 ~5 spruce_log
fill ~17 ~4 ~4 ~19 ~7 ~6 spruce_leaves[persistent=true] replace air
fill ~15 ~7 ~-9 ~17 ~7 ~-7 snow replace air
setblock ~10 ~ ~0 snow_block
setblock ~10 ~1 ~0 lantern
