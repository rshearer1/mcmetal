# build the scene once, in front of the first player who joins
execute as @a[tag=!mcm] at @s run function mcm:build
tag @a add mcm
# then hold the camera still (a mouse grab at launch can turn it), so runs compare like for like
execute as @a[tag=mcm] at @s run function mcm:look
# the effects scene's boats (no-op elsewhere)
execute if entity @e[type=boat,tag=mcm_fx,limit=1] run function mcm:effects_tick
