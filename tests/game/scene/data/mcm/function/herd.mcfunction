# A busy farm for entity costs (MCMETAL_SHADOW_ENTITY_LOD, Iris's shadow pass): 240 animals, villagers and armour
# stands, frozen (NoAI) and spread over the land up to 90 blocks around the camera, plus 64 chests in rings 12-60
# blocks out. The camera floats 14 blocks up (spectator) looking east and down. Noon, so every one casts a shadow.
difficulty peaceful
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
gamerule randomTickSpeed 0
function mcm:time
function mcm:herd_batch
function mcm:herd_batch
function mcm:herd_batch
function mcm:herd_batch
function mcm:herd_batch
function mcm:herd_batch
spreadplayers ~ ~ 6 90 false @e[tag=mcm_herd]
function mcm:herd_chests
gamemode spectator @s
tp @s ~ ~14 ~ -90 20
