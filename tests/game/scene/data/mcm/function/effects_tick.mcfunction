# Keeps the effects scene's boats crossing the lake: a push east every tick, and every 60 ticks (~11 blocks at this
# speed) back where they started, so Wakes always has fresh wakes to simulate and draw
execute as @e[type=boat,tag=mcm_fx] run data merge entity @s {Motion:[0.2d,0.0d,0.0d]}
scoreboard players add #t mcm_fx 1
execute if score #t mcm_fx matches 60.. as @e[type=boat,tag=mcm_fx] at @s run tp @s ~-11 ~ ~
execute if score #t mcm_fx matches 60.. run scoreboard players set #t mcm_fx 0
