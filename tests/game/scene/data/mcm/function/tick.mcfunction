# build the scene once, in front of the first player who joins
execute as @a[tag=!mcm] at @s run function mcm:scene
tag @a add mcm
