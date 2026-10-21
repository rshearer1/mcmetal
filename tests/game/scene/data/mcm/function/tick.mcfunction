# build the scene once, in front of the first player who joins
execute as @a[tag=!mcm] at @s run function mcm:build
tag @a add mcm
