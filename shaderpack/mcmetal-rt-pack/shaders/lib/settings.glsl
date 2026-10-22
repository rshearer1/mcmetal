// Player options (Iris reads the "// [..]" lists and shows them in the shader menu).

#define COLORED_LIGHT // torches, lanterns, glowstone... each light their own colour, with ray-traced shadows (needs mcmetal's light list)
#define COLORED_LIGHT_GLASS // light from torches and lanterns through stained glass takes its colour
#define COLORED_LIGHT_STRENGTH 1.0 // [0.5 0.7 0.85 1.0 1.2 1.5 2.0]
#define LIGHT_SLOTS 4 // [2 4 6 8] how many of the nearest light blocks each pixel considers (more = slower)
#define RT_MODE 1 // [0 1 2] 0 = shadow map only, 1 = hardware ray tracing when mcmetal provides it, 2 = always ray tracing
#if RT_MODE == 2 || (RT_MODE == 1 && defined MCMETAL_RT)
    #define USE_RT
#endif

#define RT_GI // ray-traced global illumination: bounce light, colour bleeding, sky light through openings
#define GI_CHECKERBOARD // trace bounce light and AO for half the pixels each frame (the rest keep their average)
#define SHADOW_CHECKERBOARD // trace the sun shadow for half the pixels each frame (the rest keep their average)
#define GI_FILTER 9 // [9 25] taps in the GI blur/upscale (9: 6% less GPU on the M3, no visible difference)
#define GI_HALF_RES 1 // [0 1] trace GI and AO for every 2x2 pixels (about half the cost), then upscale
#if GI_HALF_RES == 1
    #define GI_SCALE 0.5
#else
    #define GI_SCALE 1.0
#endif
#if defined USE_RT && defined RT_GI && defined MCMETAL_LIGHTS && defined COLORED_LIGHT
    // coloured block light needs mcmetal's list of nearby light blocks (mcm_lights_near); it's traced with the GI
    #define USE_LIGHTS
#endif
#define RT_GI_DISTANCE 32.0 // [8.0 16.0 32.0 64.0]
#define RT_AO // ray-traced ambient occlusion (replaces Minecraft's corner shading)
#define RT_AO_RADIUS 1.5 // [0.75 1.0 1.5 2.0 3.0]
#define RT_AO_FRAMES 24.0 // [4.0 8.0 16.0 24.0 32.0 48.0]

#define SUN_SOFTNESS 1.0 // [0.0 0.25 0.5 1.0 1.5 2.0 3.0] how wide the sun is, in degrees: wider = softer shadow edges
#define COLORED_SHADOWS // sunlight through stained glass (and water) takes its colour
#define RT_REFLECTIONS // ray-traced reflections on water and glass
#define RT_REFLECT_DISTANCE 128.0 // [32.0 64.0 128.0 256.0]

#define LIGHT_SHAFTS // ray-traced light shafts (god rays) where sunlight comes through gaps
#define LIGHT_SHAFTS_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define LIGHT_SHAFTS_STEPS 6 // [4 6 8 12 16]
#define LIGHT_SHAFTS_SCALE 0.5

#define LABPBR // LabPBR resource packs: normal maps, shiny and metal blocks, glowing texels
#define TAA // temporal anti-aliasing: smooth edges, no shimmering plants and fences
#define CLOUDS // our own soft cloud layer (replaces Minecraft's blocky clouds)
#define CLOUD_AMOUNT 1.0 // [0.0 0.5 1.0 1.5 2.0]
#define CLOUD_SPEED 1.0 // [0.0 0.5 1.0 2.0 4.0]
#define RAIN_PUDDLES // puddles on open ground in the rain, with ray-traced reflections
#define PUDDLE_AMOUNT 1.0 // [0.5 1.0 1.5 2.0]
#define GLASS_REFRACTION // glass bends and tints what is behind it, with clean see-through panes
#define GLASS_REFRACTION_STRENGTH 1.0 // [0.0 0.5 1.0 2.0 3.0]
#define CAUSTICS // moving light patterns on the bottom of sunlit water
#define CAUSTICS_STRENGTH 1.0 // [0.5 1.0 1.5 2.0]
const float wetnessHalfLife = 100.0;   // ticks for the ground to get wet once rain starts (Iris's default is 600)
const float drynessHalfLife = 400.0;

#define WAVE_HEIGHT 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0]
#define WAVE_SPEED 1.0 // [0.5 1.0 1.5 2.0]

#define DEBUG_VIEW 0 // [0 1 2 3 4 5 6 7] 0 off, 1 sun shadow, 2 ambient occlusion, 3 global illumination (with coloured block light), 4 normals, 5 light shafts, 6 puddle mask, 7 caustics (r pattern, g seen through water, b sunlit)

#define EXPOSURE 1.0 // [0.25 0.35 0.5 0.7 0.85 1.0 1.2 1.4 1.7 2.0 2.5 3.0 4.0]
#define AUTO_EXPOSURE 1.0 // [0.0 0.25 0.5 0.75 1.0] how much brightness adapts to what you look at (0 = time of day only)
#define SATURATION 1.0 // [0.0 0.5 0.7 0.8 0.9 1.0 1.1 1.2 1.3 1.5]
#define CONTRAST 1.0 // [0.8 0.9 1.0 1.1 1.2]
#define SUN_STRENGTH 1.0 // [0.5 0.7 0.85 1.0 1.2 1.5 2.0]
#define SKY_LIGHT_STRENGTH 1.0 // [0.5 0.7 0.85 1.0 1.2 1.5 2.0]
#define SKY_GI_SATURATION 0.55 // [0.0 0.25 0.4 0.55 0.7 0.85 1.0] how blue sky light looks indoors
#define BLOCK_LIGHT_STRENGTH 1.0 // [0.5 0.7 0.85 1.0 1.2 1.5 2.0 3.0]
#define BLOCK_LIGHT_R 1.00 // [0.60 0.70 0.80 0.90 1.00]
#define BLOCK_LIGHT_G 0.62 // [0.40 0.50 0.55 0.62 0.70 0.80 0.90 1.00]
#define BLOCK_LIGHT_B 0.32 // [0.10 0.20 0.32 0.40 0.50 0.60 0.80 1.00]
#define EMISSIVE_STRENGTH 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0]
#define FOG_DENSITY 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0]
#define WATER_SHADOWS // ray-traced or shadow-map shadows on the water surface

// fallback shadow map (only when not ray tracing)
const int shadowMapResolution = 2048; // [1024 2048 4096]
const float shadowDistance = 128.0; // [64.0 96.0 128.0 192.0 256.0]
const float shadowDistanceRenderMul = 1.0;
const bool shadowHardwareFiltering = true;
const float sunPathRotation = -30.0; // [-45.0 -40.0 -30.0 -20.0 -10.0 0.0 10.0 20.0 30.0]

// Iris only lists an on/off option in the menu if some #ifdef names it directly (#if defined doesn't count)
#ifdef RT_AO
#endif
#ifdef RT_GI
#endif
#ifdef WATER_SHADOWS
#endif
#ifdef RT_REFLECTIONS
#endif
#ifdef COLORED_SHADOWS
#endif
#ifdef COLORED_LIGHT
#endif
#ifdef COLORED_LIGHT_GLASS
#endif
#ifdef LIGHT_SHAFTS
#endif
#ifdef CAUSTICS
#endif
#ifdef SHADOW_CHECKERBOARD
#endif
#ifdef GI_CHECKERBOARD
#endif
#ifdef GLASS_REFRACTION
#endif
#ifdef RAIN_PUDDLES
#endif
#ifdef CLOUDS
#endif
#ifdef TAA
#endif
#ifdef LABPBR
#endif
