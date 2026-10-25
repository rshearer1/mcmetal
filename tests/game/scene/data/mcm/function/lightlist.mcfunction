# Light-list test: two rows of lights on a stone floor in front of the camera. Front row: lights SEUS PTGI E12 names
# (torch, lantern, glowstone, redstone torch, lit redstone lamp). Back row: lights it doesn't (soul lantern, the
# three froglights, shroomlight, sea lantern, lit red candles, crying obsidian, an amethyst cluster, a lit soul campfire).
difficulty peaceful
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~2 ~-1 ~-8 ~12 ~6 ~8 air
fill ~2 ~-1 ~-8 ~12 ~-1 ~8 stone
setblock ~5 ~ ~-4 torch
setblock ~5 ~ ~-2 lantern
setblock ~5 ~ ~0 glowstone
setblock ~5 ~ ~2 redstone_torch
setblock ~5 ~ ~4 redstone_lamp[lit=true]
setblock ~8 ~ ~-6 soul_lantern
setblock ~8 ~ ~-4 ochre_froglight
setblock ~8 ~ ~-2 verdant_froglight
setblock ~8 ~ ~0 pearlescent_froglight
setblock ~8 ~ ~2 shroomlight
setblock ~8 ~ ~4 sea_lantern
setblock ~8 ~ ~6 red_candle[lit=true,candles=4]
setblock ~10 ~ ~-3 crying_obsidian
setblock ~10 ~ ~0 amethyst_cluster
setblock ~10 ~ ~3 soul_campfire[lit=true]
