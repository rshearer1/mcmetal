# End portal stage for our shader pack's portal starfield (END_PORTAL_STARS): a 3x3 portal pool in its frame on
# the ground in front of the camera, and an End gateway block beside it.
difficulty peaceful
weather clear 100000
gamerule doDaylightCycle false
gamerule doWeatherCycle false
gamerule doMobSpawning false
function mcm:time
fill ~-2 ~ ~-6 ~10 ~6 ~6 air
fill ~-2 ~-1 ~-6 ~10 ~-1 ~6 stone_bricks
fill ~3 ~-1 ~-2 ~7 ~-1 ~2 end_portal_frame[eye=true]
fill ~4 ~-1 ~-1 ~6 ~-1 ~1 end_portal
setblock ~6 ~1 ~4 end_gateway
