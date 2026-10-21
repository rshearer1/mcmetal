mcmetal ray-tracing debug pack. Every terrain pixel casts one hardware ray (mcm_trace) towards the sun:
green = hit (darker = farther), red = miss. Sky is untouched. The top-left square casts from the camera
straight down (should be green: the ground under the player), the top-right square straight up.
