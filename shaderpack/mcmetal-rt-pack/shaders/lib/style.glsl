// Looks ("Style"): art direction for the whole pack, not just a filter. Each look paints its own sky (which also
// colours the ambient light, the shadows, the fog and the reflections), tints the sun, moon and torches, sets the
// mist, light shafts and glow, and Storybook draws toon light bands and ink outlines. Needs common.
// 0 Natural, 1 Cottage, 2 Witchy, 3 Storybook, 4 Fairytale.
#ifndef STYLE_LIB
#define STYLE_LIB

#if STYLE == 1          // Cottage: golden afternoons, peach sunsets, soft blue-lavender shade, morning mist
    #define STYLE_SKY_PAINT 0.8
    #define STYLE_SUN_TINT vec3(1.10, 0.97, 0.80)
    #define STYLE_MOON 1.6
    #define STYLE_MOON_TINT vec3(0.85, 0.90, 1.10)
    #define STYLE_BLOCK_TINT vec3(1.05, 0.95, 0.85)
    #define STYLE_FOG 1.4
    #define STYLE_GROUND_MIST 0.5
    #define STYLE_SHAFTS 1.8
    #define STYLE_GLOW 0.16
    #define STYLE_FOLIAGE vec4(1.25, 1.10, 0.45, 0.50)   // rgb: colour (luma-normalised), a: how far towards it
    #define STYLE_WATER vec4(0.45, 0.95, 0.85, 0.40)
    #define STYLE_PAINT                                  // painted brush-stroke finish (final.fsh)
#elif STYLE == 2        // Witchy: violet dusks and nights, bright purple moonlight, aurora, ember torches, thick valley mist
    #define STYLE_SKY_PAINT 0.85
    #define STYLE_SUN_TINT vec3(0.98, 0.92, 0.95)
    #define STYLE_MOON 3.5
    #define STYLE_MOON_TINT vec3(0.80, 0.70, 1.25)
    #define STYLE_BLOCK_TINT vec3(1.15, 0.80, 0.55)
    #define STYLE_FOG 2.2
    #define STYLE_GROUND_MIST 1.0
    #define STYLE_SHAFTS 1.4
    #define STYLE_GLOW 0.22
    #define STYLE_AURORA
    #define STYLE_FOLIAGE vec4(0.40, 1.05, 1.05, 0.60)   // deep teal
    #define STYLE_WATER vec4(0.45, 0.30, 1.10, 0.65)     // inky violet
    #define STYLE_FOLIAGE_GAIN 0.80
    #define STYLE_FIREFLIES
#elif STYLE == 3        // Storybook: bright cartoon sky, banded toon light, ink outlines
    #define STYLE_SKY_PAINT 0.9
    #define STYLE_SUN_TINT vec3(1.06, 1.00, 0.90)
    #define STYLE_MOON 2.5
    #define STYLE_MOON_TINT vec3(0.75, 0.85, 1.20)
    #define STYLE_BLOCK_TINT vec3(1.05, 0.95, 0.80)
    #define STYLE_FOG 0.8
    #define STYLE_GROUND_MIST 0.0
    #define STYLE_SHAFTS 1.0
    #define STYLE_GLOW 0.10
    #define STYLE_TOON
    #define STYLE_OUTLINE
    #define STYLE_FOLIAGE_SAT 1.6                        // cartoon green: more saturated, not a different hue
    #define STYLE_WATER vec4(0.25, 0.75, 1.60, 0.50)
    #define STYLE_POSTER                                 // flat poster bands (final.fsh)
#elif STYLE == 4        // Fairytale: pink-and-turquoise sky, rose shade, sparkling glow, pearly haze
    #define STYLE_SKY_PAINT 0.85
    #define STYLE_SUN_TINT vec3(1.06, 0.94, 1.00)
    #define STYLE_MOON 2.5
    #define STYLE_MOON_TINT vec3(0.95, 0.80, 1.20)
    #define STYLE_BLOCK_TINT vec3(1.10, 0.85, 0.90)
    #define STYLE_FOG 1.5
    #define STYLE_GROUND_MIST 0.4
    #define STYLE_SHAFTS 2.0
    #define STYLE_GLOW 0.30
    #define STYLE_FOLIAGE vec4(0.70, 1.25, 0.95, 0.55)   // pastel mint
    #define STYLE_WATER vec4(0.25, 1.15, 1.15, 0.60)     // turquoise
    #define STYLE_FOLIAGE_GAIN 1.10
    #define STYLE_SPARKLE                                // twinkles on bright surfaces (final.fsh)
#else
    #define STYLE_SKY_PAINT 0.0
    #define STYLE_SUN_TINT vec3(1.0)
    #define STYLE_MOON 1.0
    #define STYLE_MOON_TINT vec3(1.0)
    #define STYLE_BLOCK_TINT vec3(1.0)
    #define STYLE_FOG 1.0
    #define STYLE_GROUND_MIST 0.0
    #define STYLE_SHAFTS 1.0
    #define STYLE_GLOW 0.0
#endif

#ifndef STYLE_FOLIAGE_GAIN
    #define STYLE_FOLIAGE_GAIN 1.0
#endif

// Plants and water carry the biome colour in the vertex tint (green for grass and leaves, blue for water): the look
// recolours exactly those, which covers most of an outdoor screen. c: textured colour, tint: the vertex colour.
vec3 styleFoliage(vec3 c, vec3 tint, bool water) {
#if STYLE > 0
    if (water) {
  #ifdef STYLE_WATER
        return mix(c, luma(c) * STYLE_WATER.rgb, STYLE_WATER.a);
  #endif
    } else {
        float tinted = clamp((tint.g - min(tint.r, tint.b)) * 5.0, 0.0, 1.0);   // 0 for untinted (white) blocks
        if (tinted > 0.0) {
  #ifdef STYLE_FOLIAGE
            vec3 f = mix(c, luma(c) * STYLE_FOLIAGE.rgb, STYLE_FOLIAGE.a) * STYLE_FOLIAGE_GAIN;
  #elif defined STYLE_FOLIAGE_SAT
            vec3 f = max(mix(vec3(luma(c)), c, STYLE_FOLIAGE_SAT), 0.0);
  #else
            vec3 f = c;
  #endif
            return mix(c, f, tinted);
        }
    }
#endif
    return c;
}

// Witchy fireflies: small warm-green lights drifting in the air at dusk and night, one per 3x3x3 block cell that
// the hash picks, sampled on a few shells along the view ray in front of the scene. Returns light to add.
vec3 styleFireflies(vec3 dir, float sceneDist, vec3 camPos, float night) {
#ifdef STYLE_FIREFLIES
    if (night < 0.01) return vec3(0.0);
    vec3 acc = vec3(0.0);
    for (int i = 0; i < 6; i++) {
        float t = 2.5 + float(i) * 2.6;
        if (t > sceneDist) break;
        vec3 w = camPos + dir * t;
        vec3 cell = floor(w / 3.0);
        float h = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
        if (h > 0.35) continue;                                        // about a third of the cells have one
        float tm = frameTimeCounter * 0.4 + h * 40.0;
        vec3 fp = (cell + 0.5 + 0.35 * vec3(sin(tm * 1.3), sin(tm * 0.9 + 1.7), cos(tm * 1.1))) * 3.0;
        // distance from the firefly to the view ray, in blocks
        vec3 rel = fp - camPos;
        float along = dot(rel, dir);
        if (along < 0.5 || along > sceneDist) continue;
        float d = length(rel - dir * along);
        float pulse = 0.55 + 0.45 * sin(tm * 3.0);
        acc += vec3(0.75, 1.0, 0.35) * pulse * exp(-d * d * 220.0 / (1.0 + along * 0.15)) ;
    }
    return acc * night * 0.6;
#else
    return vec3(0.0);
#endif
}

// The painted sky: zenith and horizon colours for day, golden hour and night (sRGB-ish, squared to linear).
// Only the colour is taken: the brightness stays the physical sky's, so exposure and the day/night cycle hold.
void stylePalette(out vec3 dayZ, out vec3 dayH, out vec3 goldZ, out vec3 goldH, out vec3 nightZ, out vec3 nightH) {
#if STYLE == 1
    dayZ = vec3(0.36, 0.60, 0.95);  dayH = vec3(1.00, 0.94, 0.80);     // blue over cream
    goldZ = vec3(0.50, 0.50, 0.88); goldH = vec3(1.00, 0.62, 0.36);    // lavender over peach
    nightZ = vec3(0.10, 0.14, 0.32); nightH = vec3(0.30, 0.28, 0.45);
#elif STYLE == 2
    dayZ = vec3(0.42, 0.50, 0.72);  dayH = vec3(0.80, 0.82, 0.80);     // pale, slightly overcast
    goldZ = vec3(0.40, 0.22, 0.62); goldH = vec3(1.00, 0.42, 0.38);    // violet over coral
    nightZ = vec3(0.14, 0.06, 0.30); nightH = vec3(0.36, 0.20, 0.50);  // deep purple
#elif STYLE == 3
    dayZ = vec3(0.18, 0.50, 1.00);  dayH = vec3(0.70, 0.92, 1.00);     // bright cartoon blue
    goldZ = vec3(0.40, 0.42, 0.95); goldH = vec3(1.00, 0.55, 0.30);
    nightZ = vec3(0.06, 0.10, 0.34); nightH = vec3(0.18, 0.26, 0.50);
#else
    dayZ = vec3(0.45, 0.66, 1.00);  dayH = vec3(1.00, 0.80, 0.90);     // turquoise-blue over pink
    goldZ = vec3(0.58, 0.40, 0.90); goldH = vec3(1.00, 0.55, 0.68);    // lilac over rose
    nightZ = vec3(0.14, 0.08, 0.32); nightH = vec3(0.40, 0.22, 0.48);
#endif
}

vec3 stylePaintSky(vec3 phys, vec3 dir, vec3 sunDir) {
#if STYLE > 0
    vec3 dayZ, dayH, goldZ, goldH, nightZ, nightH;
    stylePalette(dayZ, dayH, goldZ, goldH, nightZ, nightH);
    float s = sunDir.y;
    float gold = clamp(1.0 - abs(s - 0.04) / 0.22, 0.0, 1.0);                  // around sunrise and sunset
    float night = smoothstep(0.02, -0.12, s);
    float t = pow(1.0 - clamp(dir.y, 0.0, 1.0), 3.0);                           // 0 zenith .. 1 horizon
    // golden hour: warmer towards the sun's side of the sky
    float sunSide = 0.5 + 0.5 * dot(normalize(dir.xz + 1e-4), normalize(sunDir.xz + 1e-4));
    vec3 day = mix(dayZ, dayH, t);
    vec3 goldC = mix(goldZ, mix(goldZ, goldH, 0.5 + 0.5 * sunSide), t);
    vec3 nightC = mix(nightZ, nightH, t);
    vec3 paint = mix(mix(day, goldC, gold), nightC, night);
    paint *= paint;                                                             // to linear
    float l = luma(phys);
    vec3 painted = paint / max(luma(paint), 1e-4) * l;
    return mix(phys, painted, STYLE_SKY_PAINT);
#else
    return phys;
#endif
}

// toon light: a smooth value turned into a few flat bands with soft steps between them
float toonBands(float x) {
    float b = x * 3.0;
    float f = fract(b);
    return (floor(b) + smoothstep(0.42, 0.58, f)) / 3.0;
}

// aurora curtains for night skies (Witchy): bands of light that drift and fold, green-teal at the bottom, violet
// at the top. dir: view direction; returns light to add.
vec3 styleAurora(vec3 dir, float night) {
#ifdef STYLE_AURORA
    if (dir.y < 0.03 || night < 0.01) return vec3(0.0);
    vec2 w = dir.xz / (dir.y + 0.15) * 1.6;
    float tt = frameTimeCounter * 0.03;
    vec3 c = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float wave = valueNoise(vec2(w.x * 0.6 + fi * 3.1 + tt, w.y * 0.25 - tt * 0.5)) * 2.0;
        float band = 1.0 - abs(fract(w.y * 0.35 + wave + fi * 0.37) - 0.5) * 2.0;
        band = pow(clamp(band, 0.0, 1.0), 6.0);
        float rays = 0.6 + 0.4 * valueNoise(vec2(w.x * 6.0 + fi * 5.0, tt * 4.0));
        c += band * rays * mix(vec3(0.10, 1.00, 0.55), vec3(0.65, 0.25, 1.00), clamp(dir.y * 2.0 + fi * 0.2, 0.0, 1.0));
    }
    float fade = smoothstep(0.03, 0.25, dir.y) * (1.0 - smoothstep(0.75, 1.0, dir.y));
    return c * fade * night * 0.03;
#else
    return vec3(0.0);
#endif
}

// a light finishing grade on top (the looks come from the light; this only rounds them off)
vec3 styleGrade(vec3 c, vec2 uv) {
    float vig = 1.0 - dot(uv - 0.5, uv - 0.5);   // 1 in the middle, 0.5 in the corners
#if STYLE == 1
    c = mix(vec3(luma(c)), c, 1.10) * vec3(1.04, 1.00, 0.92);     // honey
    c *= mix(0.85, 1.0, smoothstep(0.5, 0.8, vig));
#elif STYLE == 2
    c = mix(vec3(luma(c)), c, 0.95) * vec3(0.97, 0.94, 1.06);     // dusk violet
    c *= mix(0.70, 1.0, smoothstep(0.5, 0.85, vig));
#elif STYLE == 3
    c = mix(vec3(luma(c)), c, 1.30);
#elif STYLE == 4
    c = mix(vec3(luma(c)), c, 1.22) * vec3(1.03, 0.97, 1.04);     // rose
    c *= mix(0.90, 1.0, smoothstep(0.5, 0.8, vig));
#endif
    return clamp(c, 0.0, 1.0);
}
#endif
