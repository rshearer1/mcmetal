# Showcase stage for what mcmetal unlocks on a Mac: Complementary's coloured light (ACT) and the effects built on
# it. White floor and walls so the light colours show. The camera looks down +x at: a row of candles, three
# lights shut in red / lime / blue stained glass (ACT tints light passing through glass), a pool for reflections,
# and six bays at the back each lit by one coloured light block. Portal on the right, red beacon on the left.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
gamerule randomTickSpeed 0
gamerule announceAdvancements false
function mcm:time
fill ~-2 ~ ~-13 ~22 ~12 ~13 air
fill ~-2 ~-1 ~-13 ~22 ~-3 ~13 white_concrete
# candles at the camera's feet
setblock ~6 ~ ~-2 red_candle[candles=4,lit=true]
setblock ~6 ~ ~-1 orange_candle[candles=4,lit=true]
setblock ~6 ~ ~0 lime_candle[candles=4,lit=true]
setblock ~6 ~ ~1 cyan_candle[candles=4,lit=true]
setblock ~6 ~ ~2 purple_candle[candles=4,lit=true]
# three white lights, each shut in one colour of stained glass
fill ~9 ~ ~-5 ~11 ~2 ~-3 red_stained_glass
setblock ~10 ~1 ~-4 sea_lantern
fill ~9 ~ ~-1 ~11 ~2 ~1 lime_stained_glass
setblock ~10 ~1 ~0 sea_lantern
fill ~9 ~ ~3 ~11 ~2 ~5 blue_stained_glass
setblock ~10 ~1 ~4 sea_lantern
# pool: reflections of everything behind it
fill ~13 ~-1 ~-11 ~14 ~-1 ~11 water
# six bays, each lit by one coloured light block
fill ~16 ~ ~-12 ~19 ~3 ~12 white_concrete
fill ~16 ~ ~-11 ~18 ~3 ~-9 air
fill ~16 ~ ~-7 ~18 ~3 ~-5 air
fill ~16 ~ ~-3 ~18 ~3 ~-1 air
fill ~16 ~ ~1 ~18 ~3 ~3 air
fill ~16 ~ ~5 ~18 ~3 ~7 air
fill ~16 ~ ~9 ~18 ~3 ~11 air
fill ~18 ~ ~-11 ~18 ~1 ~-9 crying_obsidian
fill ~18 ~ ~-7 ~18 ~1 ~-5 verdant_froglight
fill ~18 ~ ~-3 ~18 ~1 ~-1 ochre_froglight
fill ~18 ~ ~1 ~18 ~1 ~3 pearlescent_froglight
fill ~18 ~ ~5 ~18 ~1 ~7 sea_lantern
fill ~18 ~ ~9 ~18 ~1 ~11 shroomlight
fill ~16 ~4 ~-12 ~19 ~4 ~12 white_concrete
# right: lit nether portal facing the camera; left: beacon with a red beam
fill ~10 ~ ~7 ~10 ~4 ~10 obsidian
fill ~10 ~1 ~8 ~10 ~3 ~9 nether_portal[axis=z]
fill ~9 ~-1 ~-10 ~11 ~-1 ~-8 iron_block
setblock ~10 ~ ~-9 beacon
setblock ~10 ~1 ~-9 red_stained_glass
# a three-block plinth for a view over the whole stage
fill ~ ~ ~ ~ ~2 ~ polished_deepslate
tp @s ~ ~3 ~ facing ~19 ~0 ~0
