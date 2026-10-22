# Nether stage: a sealed room in the Nether at 0 64 0 (netherrack shell, so natural lava can't flow in) with the
# Nether's own blocks: lava lake, glowstone, soul fire, crimson and warped growth, magma, a lit portal. The camera
# looks down +x from the room's west end. Built a couple of seconds after the teleport, once the chunks are loaded.
difficulty peaceful
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
gamerule doFireTick false
gamerule randomTickSpeed 0
execute in minecraft:the_nether run forceload add -32 -32 32 32
execute in minecraft:the_nether run tp @s 0.5 64 0.5 -90 7
schedule function mcm:nether_room 40t
