# Mobs on an open white floor at noon, for ray-traced entity shadows: cow, villager, armour stand and iron golem
# 5-10 blocks ahead of the camera (looking down +x), frozen (NoAI) so runs compare.
difficulty peaceful
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
gamerule randomTickSpeed 0
function mcm:time
fill ~-4 ~ ~-8 ~16 ~8 ~8 air
fill ~-4 ~-1 ~-8 ~16 ~-3 ~8 white_concrete
summon cow ~6 ~ ~-2 {NoAI:1b}
summon villager ~6 ~ ~1 {NoAI:1b}
summon armor_stand ~5 ~ ~3
summon iron_golem ~10 ~ ~0 {NoAI:1b}
tp @s ~ ~ ~ -90 25
