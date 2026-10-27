# Water effects for the effect mods Hearth & Hex ships (Wakes, Particular, Particle Rain, Visuality, Make Bubbles Pop):
# a 21x21 lake in front of the camera, a cliff on its far side with five waterfalls into it (Particular's spray),
# four boats crossing it (Wakes' ripples and splash planes; effects_tick keeps them going), salmon and squid in it.
# Weather comes from time.mcfunction (ci_game.sh: rain). The camera stands on the near shore looking east and down.
difficulty peaceful
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
gamerule randomTickSpeed 0
function mcm:time
kill @e[tag=mcm_fx]
fill ~-2 ~ ~-12 ~27 ~14 ~12 air
fill ~-2 ~-1 ~-12 ~27 ~-5 ~12 stone
fill ~3 ~-1 ~-10 ~23 ~-4 ~10 water
fill ~24 ~ ~-12 ~27 ~9 ~12 stone
setblock ~24 ~10 ~-8 water
setblock ~24 ~10 ~-4 water
setblock ~24 ~10 ~0 water
setblock ~24 ~10 ~4 water
setblock ~24 ~10 ~8 water
summon boat ~5 ~-0.5 ~-6 {Type:"oak",Tags:["mcm_fx"],Rotation:[-90f,0f]}
summon boat ~9 ~-0.5 ~-2 {Type:"oak",Tags:["mcm_fx"],Rotation:[-90f,0f]}
summon boat ~6 ~-0.5 ~2 {Type:"oak",Tags:["mcm_fx"],Rotation:[-90f,0f]}
summon boat ~11 ~-0.5 ~6 {Type:"oak",Tags:["mcm_fx"],Rotation:[-90f,0f]}
summon salmon ~10 ~-2 ~-3 {Tags:["mcm_fx"],PersistenceRequired:1b}
summon salmon ~14 ~-2 ~3 {Tags:["mcm_fx"],PersistenceRequired:1b}
summon salmon ~17 ~-2 ~-7 {Tags:["mcm_fx"],PersistenceRequired:1b}
summon squid ~15 ~-3 ~0 {Tags:["mcm_fx"],PersistenceRequired:1b}
summon squid ~19 ~-3 ~6 {Tags:["mcm_fx"],PersistenceRequired:1b}
scoreboard objectives add mcm_fx dummy
scoreboard players set #t mcm_fx 0
