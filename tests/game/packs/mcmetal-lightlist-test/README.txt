mcmetal light-list test pack (MIT, ours). Stands in for SEUS PTGI E12 in tests: its block.properties uses the same
old-style ids for lights (50 torch and lantern, 76 lit redstone torch, 89 glowstone, 10 lava, 51 fire) and names no
light newer than Minecraft 1.14. Terrain is drawn flat in a colour per id (50 orange, 76 red, 89 yellow, 10 and 51
deep orange; everything else grey), so a screenshot shows which id each block got. Without mcmetal's light list
(MCMETAL_LIGHT_LIST=0) soul lanterns, froglights, candles and the rest stay grey; with it they take their twin's colour.
