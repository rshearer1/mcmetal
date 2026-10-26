# Cave stage for our shader pack: a closed stone cave round the camera with no sky light (no sun, no sky in the
# bounce light), lit by two torches, a lantern, glow lichen and a lava pool, with a dripstone column for shadows.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-4 ~-2 ~-8 ~16 ~8 ~8 stone
fill ~-2 ~ ~-6 ~14 ~5 ~6 air
fill ~2 ~5 ~-3 ~10 ~6 ~3 air
fill ~6 ~-1 ~-5 ~9 ~-1 ~-3 lava
fill ~-2 ~-1 ~-6 ~14 ~-1 ~6 deepslate replace stone
fill ~7 ~ ~1 ~7 ~4 ~1 dripstone_block
setblock ~4 ~ ~-6 wall_torch[facing=south]
setblock ~12 ~ ~6 wall_torch[facing=north]
setblock ~13 ~ ~-2 lantern
fill ~14 ~1 ~-3 ~14 ~4 ~3 glow_lichen[east=true] replace air
