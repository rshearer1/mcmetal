// Player options (Iris reads the "// [..]" lists and shows them in the shader menu).

#define RT_MODE 1 // [0 1 2] 0 = shadow map only, 1 = hardware ray tracing when mcmetal provides it, 2 = always ray tracing
#if RT_MODE == 2 || (RT_MODE == 1 && defined MCMETAL_RT)
    #define USE_RT
#endif

#define RT_AO // ray-traced ambient occlusion (replaces Minecraft's corner shading)
#define RT_AO_RADIUS 1.5 // [0.75 1.0 1.5 2.0 3.0]
#define RT_AO_FRAMES 16.0 // [4.0 8.0 16.0 32.0]

#define EXPOSURE 1.0 // [0.25 0.35 0.5 0.7 0.85 1.0 1.2 1.4 1.7 2.0 2.5 3.0 4.0]
#define SATURATION 1.0 // [0.0 0.5 0.7 0.8 0.9 1.0 1.1 1.2 1.3 1.5]
#define CONTRAST 1.0 // [0.8 0.9 1.0 1.1 1.2]
#define SUN_STRENGTH 1.0 // [0.5 0.7 0.85 1.0 1.2 1.5 2.0]
#define SKY_LIGHT_STRENGTH 1.0 // [0.5 0.7 0.85 1.0 1.2 1.5 2.0]
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
#ifdef WATER_SHADOWS
#endif
