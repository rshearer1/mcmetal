# The HUD in view (MCMETAL_HUD_CACHE): the pool scene in survival with a full hotbar, armour, two status effects, XP
# levels, a boss bar and chat lines kept coming (hud_tick), so the hotbar, hearts, armour, effects, XP bar, boss bar
# and chat are all drawn over the world. Off-hand item for the second hotbar slot.
function mcm:scene
gamemode survival @s
effect give @s speed infinite 0 true
effect give @s night_vision infinite 0 true
experience set @s 30 levels
item replace entity @s hotbar.0 with diamond_sword 1
item replace entity @s hotbar.1 with bow 1
item replace entity @s hotbar.2 with oak_planks 34
item replace entity @s hotbar.3 with torch 35
item replace entity @s hotbar.4 with bread 36
item replace entity @s hotbar.5 with water_bucket 1
item replace entity @s hotbar.6 with crafting_table 38
item replace entity @s hotbar.7 with cobblestone 39
item replace entity @s hotbar.8 with shield 1
item replace entity @s armor.head with iron_helmet
item replace entity @s armor.chest with iron_chestplate
item replace entity @s armor.legs with iron_leggings
item replace entity @s armor.feet with iron_boots
item replace entity @s weapon.offhand with lantern 16
bossbar add mcm:hud "Hearth & Hex HUD test"
bossbar set mcm:hud players @s
bossbar set mcm:hud value 60
bossbar set mcm:hud color purple
function mcm:hud_tick
