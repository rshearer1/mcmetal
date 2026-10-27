# A chat line every 2 s, so the chat box stays on screen (it fades 10 s after the last line).
tellraw @a [{"text":"[HUD test] ","color":"gold"},{"text":"chat stays on screen while the HUD cache is measured"}]
schedule function mcm:hud_tick 40t replace
