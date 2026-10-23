# Menu frame-rate runs (MCMETAL_TEST_SCREEN=inventory): a survival inventory full of different items, flat ones and
# 3D blocks, so the inventory screen draws a full grid of item icons (and JEI's item list beside it, when installed).
difficulty peaceful
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
gamemode survival @s
item replace entity @s hotbar.0 with diamond_sword 1
item replace entity @s hotbar.1 with bow 1
item replace entity @s hotbar.2 with oak_planks 34
item replace entity @s hotbar.3 with torch 35
item replace entity @s hotbar.4 with bread 36
item replace entity @s hotbar.5 with water_bucket 1
item replace entity @s hotbar.6 with crafting_table 38
item replace entity @s hotbar.7 with cobblestone 39
item replace entity @s hotbar.8 with shield 1
item replace entity @s inventory.0 with oak_log 3
item replace entity @s inventory.1 with birch_log 10
item replace entity @s inventory.2 with spruce_log 17
item replace entity @s inventory.3 with stone 24
item replace entity @s inventory.4 with granite 31
item replace entity @s inventory.5 with diorite 38
item replace entity @s inventory.6 with andesite 45
item replace entity @s inventory.7 with glass 52
item replace entity @s inventory.8 with white_wool 59
item replace entity @s inventory.9 with red_wool 64
item replace entity @s inventory.10 with furnace 64
item replace entity @s inventory.11 with chest 64
item replace entity @s inventory.12 with bookshelf 64
item replace entity @s inventory.13 with iron_ingot 64
item replace entity @s inventory.14 with gold_ingot 64
item replace entity @s inventory.15 with diamond 64
item replace entity @s inventory.16 with emerald 64
item replace entity @s inventory.17 with redstone 64
item replace entity @s inventory.18 with lapis_lazuli 64
item replace entity @s inventory.19 with apple 64
item replace entity @s inventory.20 with golden_apple 64
item replace entity @s inventory.21 with carrot 64
item replace entity @s inventory.22 with potato 64
item replace entity @s inventory.23 with wheat 64
item replace entity @s inventory.24 with pumpkin 64
item replace entity @s inventory.25 with melon 64
item replace entity @s inventory.26 with lantern 64
item replace entity @s armor.head with iron_helmet
item replace entity @s armor.chest with iron_chestplate
item replace entity @s armor.legs with iron_leggings
item replace entity @s armor.feet with iron_boots
item replace entity @s weapon.offhand with torch 16
