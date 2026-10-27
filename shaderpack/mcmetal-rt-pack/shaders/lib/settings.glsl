// Player options (Iris reads the "// [..]" lists and shows them in the shader menu).

#define COLORED_LIGHT // torches, lanterns, glowstone... each light their own colour, with ray-traced shadows (needs mcmetal's light list)
#define COLORED_LIGHT_GLASS // light from torches and lanterns through stained glass takes its colour
#define SHARP_LIGHT_SHADOWS // block light casts crisp shadows (rays aim at the light's centre); off = soft shadows
#define COLORED_LIGHT_STRENGTH 1.0 // [0.5 0.7 0.85 1.0 1.2 1.5 2.0]
#define LIGHT_SLOTS 4 // [2 4 6 8] how many of the nearest light blocks each pixel considers (more = slower)
//#define LIGHT_RESTIR // coloured light picks carry over between frames (ReSTIR): with many lights, each pixel settles on the ones it can see
#define RT_MODE 1 // [0 1 2] 0 = shadow map only, 1 = hardware ray tracing when mcmetal provides it, 2 = always ray tracing
#if RT_MODE == 2 || (RT_MODE == 1 && defined MCMETAL_RT)
    #define USE_RT
#endif

#define RT_GI // ray-traced global illumination: bounce light, colour bleeding, sky light through openings
#define GI_RATE 2 // [1 2 4] trace bounce light and AO for 1 in GI_RATE pixels each frame (the rest keep their average)
#define GI_ADAPTIVE // rays where needed: just-uncovered pixels trace every frame, settled ones 1 frame in 4
#define UNIFIED_TARGETS // see-through things share water's buffer list, so they draw in one Metal render pass
//#define PHOTO_MODE // standing still: rays keep averaging much longer, for clean screenshots (lights settle slower while still)
#define PHOTO_FRAMES 128.0 // [32.0 64.0 128.0 256.0]
//#define METALFX_DENOISE // Apple's MetalFX denoiser cleans the whole lit picture (needs mcmetal with MCMETAL_DENOISE=1, an M3 or newer and macOS 26; our own denoiser is switched off)
#define DENOISE_PASSES 1 // [1 2] rounds of the bounce-light denoiser: 1 does the same reach in one wider pass (one pass fewer)
//#define HALF_PRECISION // the denoiser's maths in 16-bit (Apple's advice: fewer registers, faster maths; needs mcmetal from 10-26 or newer)
#define RT_NOISE 1 // [0 1] random numbers for rays: 0 the old shifted noise, 1 decorrelated per dimension (Apple's denoiser advice)
#define SHADOW_FILTER // smooth the grain out of ray-traced sun shadows (a small blur that keeps edges between objects)
#define SHADOW_CHECKERBOARD // trace the sun shadow for half the pixels each frame (the rest keep their average)
#define SHADOW_RATE 2 // [2 4] with the above: sun shadows and light shafts traced for 1 in this many pixels each frame
#if defined SHADOW_CHECKERBOARD && SHADOW_RATE == 4
    #define SHADOW_BLEND 0.25   // each new ray counts double, so shadows still follow mobs and the sun as quickly
#else
    #define SHADOW_BLEND 0.125
#endif
#define GI_COARSE_RAYS // bounce light rays see leaves and plants beyond 2 blocks as solid (no alpha test: faster in forests; needs mcmetal from 10-25 or newer)
#define LIGHT_CACHE // light bounces more than once: ray hits that are on screen reuse the bounce light already gathered there (brighter, more even rooms; no extra rays)
//#define WORLD_CACHE // the bounce light is also kept per block face in the world, so light keeps bouncing off things behind you and round corners
#define DENOISER // two extra filter rounds that clean the GI's grain but keep its light and shadow edges (a-trous, like SVGF)
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
#define GI_SHORT_RAYS // faster: bounce-light rays stop after a few blocks and fall back to the sky light Minecraft gives
#define GI_SHORT_DISTANCE 10.0 // [6.0 8.0 10.0 12.0 16.0]
#define RT_AO // ray-traced ambient occlusion (replaces Minecraft's corner shading)
#define RT_AO_RADIUS 1.5 // [0.75 1.0 1.5 2.0 3.0]
#define RT_AO_FRAMES 24.0 // [4.0 8.0 16.0 24.0 32.0 48.0]

#define SUN_SOFTNESS 1.0 // [0.0 0.25 0.5 1.0 1.5 2.0 3.0] how wide the sun is, in degrees: wider = softer shadow edges
#define COLORED_SHADOWS // sunlight through stained glass (and water) takes its colour
#define RT_REFLECTIONS // ray-traced reflections on water and glass
#define RT_REFLECT_DISTANCE 128.0 // [32.0 64.0 128.0 256.0]
//#define REFLECTION_DENOISE // glossy traced reflections average over frames (rougher = longer), so they are smooth instead of grainy
#define WATER_REFLECT_HALF // open water's reflections traced at half resolution, half the pixels each frame, averaged over frames (much faster)

#define LIGHT_SHAFTS // ray-traced light shafts (god rays) where sunlight comes through gaps
#define LIGHT_SHAFTS_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define LIGHT_SHAFTS_STEPS 6 // [4 6 8 12 16]
#define LIGHT_SHAFTS_SCALE 0.5
//#define SHAFT_BUDGET // fewer light-shaft rays where the view ray is short (rooms, close walls): one step every few blocks instead of the full count
#define SHAFT_STEP_LENGTH 4.0 // [2.0 3.0 4.0 6.0 8.0] with the above: blocks of air per light-shaft step
//#define FOG_GRID // light shafts: whether the sun reaches each half-block of air is traced once per cell and shared, not per pixel
#define FOG_GRID_FRAMES 8 // [4 8 16 32] how many frames a cell keeps its sun ray before tracing again
//#define DH_SHADOWS // far Distant Horizons terrain gets sun shadows (a march over its depth on screen): hills and forests cast long shadows
#define DH_SHADOW_STEPS 16 // [8 12 16 24]
#define LAMP_FOG // torches, lanterns and glowing blocks light up the air round them: a soft glow in fog, rain and dusty rooms (needs coloured light)
#define LAMP_FOG_STRENGTH 1.0 // [0.5 1.0 1.5 2.0 3.0]
#define VOLUMETRIC_MIST // morning mist near the ground that the sun's beams light up (with Light Shafts)
#define MIST_AMOUNT 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0]
#define LIGHT_SHAFTS_RATE 4 // [2 4] light shafts traced for 1 in this many pixels each frame (the rest keep their average; shafts are soft, 4 is enough)
#if LIGHT_SHAFTS_RATE == 4
    #define LIGHT_SHAFTS_BLEND 0.25
#else
    #define LIGHT_SHAFTS_BLEND 0.125
#endif

//#define HELD_LIGHT_SHADOWS // the torch or lantern in your hand casts shadows (one ray per lit pixel while you hold a light)
#define END_PORTAL_STARS // a deep starfield inside End portals and gateways instead of vanilla's flat layers
#define END_PORTAL_BRIGHTNESS 1.0 // [0.5 1.0 1.5 2.0]
//#define AURORA // northern lights at a real height over the world, in every look (you can fly through them); replaces Witchy's painted aurora
#define AURORA_HEIGHT 400.0 // [250.0 400.0 600.0 1000.0]
#define AURORA_SCALE 1.0 // [0.5 1.0 2.0]
#define AURORA_SPEED 1.0 // [0.5 1.0 2.0 4.0]
#define AURORA_BRIGHTNESS 1.0 // [0.5 1.0 2.0 3.0]
//#define PIXEL_SHADOWS // sun shadows snap to the blocks' own pixels (stepped edges like Minecraft's textures; suits Storybook and Fairytale)
#define LIGHTNING_FLASH // lightning bolts light up the land and the sky in a flickering blue-white flash
#define LIGHTNING_STRENGTH 1.0 // [0.5 1.0 1.5 2.0]
#define WAVING_PLANTS // grass, flowers, crops and leaves sway gently in the wind
#define WAVING_AMOUNT 1.0 // [0.5 1.0 1.5 2.0]
#define WAVING_SPEED 1.0 // [0.5 1.0 1.5 2.0]
#define SUBSURFACE // leaves and grass glow a deeper green with the sun behind them (light through the leaf)
#define SUBSURFACE_STRENGTH 1.0 // [0.5 1.0 1.5 2.0]
#define PARALLAX // resource-pack height maps (Vanilla RTX) give bricks and cobbles real depth up close
#define PARALLAX_DEPTH 0.2 // [0.1 0.15 0.2 0.25 0.3 0.4]
#define PARALLAX_STEPS 16 // [8 12 16 24 32]
#define LABPBR_NORMAL_STRENGTH 1.0 // [0.5 1.0 1.5 2.0 3.0] how deep LabPBR normal maps and height look
#define LABPBR // LabPBR resource packs: normal maps, shiny and metal blocks, glowing texels
#define RT_PBR_EMISSIVE // glowing texels of LabPBR packs (lamps, ores, lava) also light rooms in the bounce light and glow in reflections
#define AUTO_PBR // blocks without PBR maps still look their part: ores glint, metal blocks shine, gems and polished stone are glossy (also modded blocks)
#define AUTO_PBR_STRENGTH 1.0 // [0.5 0.75 1.0]
#define ROUGH_REFLECTIONS_STRENGTH 1.0 // [0.0 0.5 1.0 1.5 2.0] the soft sheen of rough and satin PBR blocks (stone, wood, brick): a blurred reflection of their surroundings
//#define GLOSSY_RT // satin PBR blocks close by trace one short ray for their sheen, so it shows the torch or wall really there
#define GLOSSY_RT_DISTANCE 24.0 // [12.0 16.0 24.0 32.0 48.0]
#define BLOOM // soft glow around the sun, lights and other bright things
#define BLOOM_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0]
//#define LENS_FLARE // a camera's lens flare from the sun: soft coloured ghosts across the screen
#define LENS_FLARE_STRENGTH 1.0 // [0.5 1.0 1.5 2.0]
//#define DEPTH_OF_FIELD // like a camera: what's nearer or further than what you look at goes soft
#define DOF_STRENGTH 1.0 // [0.5 1.0 2.0 4.0 8.0]
//#define MOTION_BLUR // a soft blur while turning and moving, like a camera's shutter
#define MOTION_BLUR_STRENGTH 1.0 // [0.5 1.0 1.5 2.0]
#define PURKINJE // night vision: in very dim light colours fade and lean blue, as the eye sees them
#define PURKINJE_STRENGTH 0.6 // [0.3 0.6 0.8 1.0]
#define SHARPEN // a light sharpen after anti-aliasing, so textures stay crisp
#define SHARPEN_STRENGTH 0.5 // [0.25 0.5 0.75 1.0 1.5]
#define TONEMAP 0 // [0 1] 0 ACES filmic (punchy), 1 soft filmic (gentler highlights, truer bright colours)
#define TAA // temporal anti-aliasing: smooth edges, no shimmering plants and fences
#define CLOUDS // our own soft cloud layer (replaces Minecraft's blocky clouds)
#define CLOUD_AMOUNT 1.0 // [0.0 0.5 1.0 1.5 2.0]
#define CLOUD_SPEED 1.0 // [0.0 0.5 1.0 2.0 4.0]
#define VOLUMETRIC_CLOUDS // clouds with real height: self-shadowed, silver edges towards the sun, dark bellies (off = flat layer, faster)
#define STARS // our own steady night sky: stars of many sizes and colours that turn with the night
#define MILKY_WAY // the Milky Way's faint band and dust lanes across the stars
#define STARS_BRIGHTNESS 1.0 // [0.5 1.0 1.5 2.0 3.0]
#define LIGHT_POLLUTION // your lamps light up the night haze: a warm glow low in the sky over a lit base
#define LIGHT_POLLUTION_STRENGTH 1.0 // [0.5 1.0 2.0 3.0]
#define END_BEAMS // the End's sky: violet beams rising out of the void, and faint stars
#define END_BEAMS_STRENGTH 1.0 // [0.5 1.0 2.0 3.0]
#define RAINBOW // a rainbow opposite the sun as the rain clears
#define RAINBOW_STRENGTH 1.0 // [0.5 1.0 1.5 2.0]
#define CIRRUS // thin, high streaks of ice cloud above the main clouds
#define DAILY_WEATHER // each day has its own sky: some clear, some cloudy (the same for everyone in the world)
#define CLOUD_SHADOWS // the clouds' shadows drift over the land
#define CLOUD_SHADOW_STRENGTH 0.8 // [0.4 0.6 0.8 1.0]
#define CLOUD_STEPS 12 // [6 8 12 16 24] samples through the clouds per pixel (more = smoother, slower)
#define RAIN_PUDDLES // puddles on open ground in the rain, with ray-traced reflections
#define PUDDLE_AMOUNT 1.0 // [0.5 1.0 1.5 2.0]
#define RAIN_RIPPLES // raindrops make rings on puddles
#define WET_SHEEN // rain leaves a soft wet shine on every surface the sky reaches: walls, roofs, leaves
#define GLASS_REFRACTION // glass bends and tints what is behind it, with clean see-through panes
#define GLASS_REFRACTION_STRENGTH 1.0 // [0.0 0.5 1.0 2.0 3.0]
#define CAUSTICS // moving light patterns on the bottom of sunlit water
#define CAUSTICS_STRENGTH 1.0 // [0.5 1.0 1.5 2.0]
const float wetnessHalfLife = 100.0;   // ticks for the ground to get wet once rain starts (Iris's default is 600)
const float drynessHalfLife = 400.0;

#define WATER_DEPTH_COLOR // shallow water is clear, deep water turns blue-green and dark (light absorbed by depth)
#define WATER_DEPTH_COLOR_STRENGTH 1.0 // [0.5 1.0 1.5 2.0]
#define WATER_FOAM // a thin moving line of foam where water meets the shore
//#define WATER_REFRACTION // traced refraction: the view bends where it enters water, so the bottom looks nearer and moves with the waves
#define WAVE_HEIGHT 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0]
#define WAVE_SPEED 1.0 // [0.5 1.0 1.5 2.0]

#define DEBUG_VIEW 0 // [0 1 2 3 4 5 6 7] 0 off, 1 sun shadow, 2 ambient occlusion, 3 global illumination (with coloured block light), 4 normals, 5 light shafts, 6 puddle mask, 7 caustics (r pattern, g seen through water, b sunlit)

#define STYLE 0 // [0 1 2 3 4] the look (sky, light, mist, glow): 0 Natural, 1 Cottage, 2 Witchy, 3 Storybook, 4 Fairytale
#define SEASONS // light, sky, clouds, mist and winter frost follow the year (Serene Seasons' calendar, lib/season.glsl)
#define SEASON_LENGTH 8 // [2 4 6 8 10 12 16 20 24 30] days per sub-season (Serene Seasons: sub_season_duration)
#define SEASON_OFFSET 0 // [-48 -40 -32 -24 -16 -8 -4 -2 -1 0 1 2 4 8 16 24 32 40 48] days to move the pack's calendar on, if it is out of step with the mod
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
#ifdef WATER_REFLECT_HALF
#endif
#if defined USE_RT && defined RT_REFLECTIONS && defined WATER_SHADOWS && defined WATER_REFLECT_HALF
    #define WATER_REFLECT_PASS   // composite.fsh traces open water's reflections, composite1.fsh adds them
#endif
#ifdef COLORED_SHADOWS
#endif
#ifdef COLORED_LIGHT
#endif
#ifdef COLORED_LIGHT_GLASS
#endif
#ifdef LIGHT_SHAFTS
#endif
#ifdef SHAFT_BUDGET
#endif
#ifdef HELD_LIGHT_SHADOWS
#endif
#ifdef END_PORTAL_STARS
#endif
#ifdef AURORA
#endif
#ifdef PIXEL_SHADOWS
#endif
#ifdef CAUSTICS
#endif
#ifdef WATER_DEPTH_COLOR
#endif
#ifdef WATER_FOAM
#endif
#ifdef GI_COARSE_RAYS
#endif
// MetalFX denoises the whole picture: our own GI denoiser steps aside
#ifdef METALFX_DENOISE
    #undef DENOISER
#endif
#ifdef DENOISER
#endif
#ifdef HALF_PRECISION
#endif
#ifdef LIGHT_CACHE
#endif
#ifdef WORLD_CACHE
#endif
#ifdef LIGHT_RESTIR
#endif
#ifdef REFLECTION_DENOISE
#endif
#ifdef FOG_GRID
#endif
#ifdef DH_SHADOWS
#endif
#ifndef IRIS_FEATURE_SSBO   // these keep their history in Iris shader storage buffers
    #undef FOG_GRID
    #undef LIGHT_RESTIR
    #undef REFLECTION_DENOISE
#endif
#if defined WORLD_CACHE && !(defined USE_RT && defined LIGHT_CACHE && defined RT_GI && defined IRIS_FEATURE_SSBO)
    #undef WORLD_CACHE   // it extends the light cache
#endif
#ifdef SHADOW_CHECKERBOARD
#endif
#ifdef SHADOW_FILTER
#endif
#ifdef GLASS_REFRACTION
#endif
#ifdef RAIN_PUDDLES
#endif
#ifdef CLOUDS
#endif
#ifdef VOLUMETRIC_CLOUDS
#endif
#ifdef CLOUD_SHADOWS
#endif
#ifdef CIRRUS
#endif
#ifdef DAILY_WEATHER
#endif
#ifdef TAA
#endif
#ifdef BLOOM
#endif
#ifdef LENS_FLARE
#endif
#ifdef VOLUMETRIC_MIST
#endif
#ifdef LABPBR
#endif
#ifdef DEPTH_OF_FIELD
#endif
#ifdef MOTION_BLUR
#endif
#ifdef SUBSURFACE
#endif
#ifdef WAVING_PLANTS
#endif
#ifdef AUTO_PBR
#endif
#ifdef LAMP_FOG
#endif
#ifdef SHARPEN
#endif
#ifdef LIGHTNING_FLASH
#endif
#ifdef RT_PBR_EMISSIVE
#endif
