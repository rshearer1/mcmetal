mcmetal ray-tracing debug pack. Every terrain pixel casts one hardware ray (mcm_trace) towards the sun:
green = hit on a solid block (darker = farther), yellow = hit on a see-through-texture block (grass, leaves, plain glass), red = miss. Sky is untouched. The top-left square casts from the camera
straight down (should be green: the ground under the player), the top-right square straight up.
Lit pixels behind glass, water or ice show the colour the light is filtered to (mcm_trace_tinted).
The bottom-right inset is the view as the rays see it (mcm_trace_hit from the camera): left part albedo times
light, right part face normals (x red, y green, z blue). It should look like a plain version of the game picture.
