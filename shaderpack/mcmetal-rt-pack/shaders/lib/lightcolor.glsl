// Light blocks' colour and vanilla light level by block id (block.properties 10100-10299). Plain maths, any stage:
// lib/lights.glsl uses it for the coloured light, lib/gbuffer.glsl to tell faint glowing blocks from bright ones.
#ifndef LIGHTCOLOR_LIB
#define LIGHTCOLOR_LIB
#include "/lib/lights_modded.glsl"

// the light's colour (linear) and vanilla light level, by block id
vec3 lightColorOf(int id, out float level) {
    level = 15.0;
    switch (id) {
    case 10100: level = 14.0; return vec3(1.00, 0.55, 0.22);   // torch, lantern, campfire, candles, furnaces
    case 10101: level = 10.0; return vec3(0.25, 0.75, 1.00);   // soul torch, soul lantern, soul campfire
    case 10102: level = 7.0;  return vec3(1.00, 0.10, 0.03);   // redstone torch
    case 10103: level = 14.0; return vec3(1.00, 0.92, 0.88);   // end rod
    case 10104:               return vec3(1.00, 0.68, 0.35);   // redstone lamp
    case 10105:               return vec3(0.60, 0.90, 1.00);   // beacon, conduit
    case 10106: level = 10.0; return vec3(0.55, 0.20, 1.00);   // crying obsidian, respawn anchor
    case 10107: level = 5.0;  return vec3(0.70, 0.35, 1.00);   // amethyst cluster
    case 10108: level = 9.0;  return vec3(0.45, 1.00, 0.70);   // sea pickles
    case 10109: level = 7.0;  return vec3(1.00, 0.75, 0.45);   // enchanting table, brewing stand
    case 10200:               return vec3(1.00, 0.40, 0.10);   // lava, fire
    case 10201: level = 10.0; return vec3(0.25, 0.75, 1.00);   // soul fire
    case 10202:               return vec3(1.00, 0.75, 0.42);   // glowstone
    case 10203:               return vec3(0.70, 0.90, 1.00);   // sea lantern
    case 10204:               return vec3(1.00, 0.55, 0.28);   // shroomlight
    case 10205:               return vec3(1.00, 0.82, 0.40);   // ochre froglight
    case 10206:               return vec3(0.55, 1.00, 0.45);   // verdant froglight
    case 10207:               return vec3(1.00, 0.55, 1.00);   // pearlescent froglight
    case 10208: level = 3.0;  return vec3(1.00, 0.30, 0.08);   // magma block
    }
    return moddedLightColor(id, level);                          // modded lights (block.properties' modded part)
}
#endif
