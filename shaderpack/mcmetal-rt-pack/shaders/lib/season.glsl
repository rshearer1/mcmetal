// Seasons: the light, sky, clouds, mist and frost follow the year of Serene Seasons, on top of the chosen look.
// Serene Seasons counts its year from the world clock (sleeping and /time add move it on too), from early spring on
// a new world, in 12 sub-seasons of SEASON_LENGTH days (its default: 8). Iris gives shaders the same clock
// (worldDay, worldTime), so the pack follows the mod's calendar by itself, also without mcmetal. SEASON_OFFSET moves
// the pack's calendar by days, if /season set or /time set has put the two out of step.
// Each season is fullest in its middle sub-season and fades into the next over the early and late ones, so nothing
// jumps from one day to the next. The grass and leaf colours themselves come from Serene Seasons (the biome tint).
// Needs uniforms.
#ifndef SEASON_LIB
#define SEASON_LIB

// how much of each season it is now: x spring, y summer, z autumn, w winter (they add up to 1; all 0 when off)
vec4 seasonWeights() {
#ifdef SEASONS
    float day = float(worldDay) + float(worldTime) / 24000.0 + float(SEASON_OFFSET);
    float p = fract(day / (12.0 * float(SEASON_LENGTH))) * 4.0 - 0.5;   // 0 = middle of spring, 1 = middle of summer
    float i = floor(p);
    float f = smoothstep(0.2, 0.8, p - i);   // the middle 2/5 of each season's span is fully that season
    int a = int(mod(i, 4.0)), b = int(mod(i + 1.0, 4.0));
    vec4 w = vec4(0.0);
    w[a] += 1.0 - f;
    w[b] += f;
    return w;
#else
    return vec4(0.0);
#endif
}

// colour and strength of sunlight: spring fresh, summer warm and strong, autumn golden, winter pale and cool
vec3 seasonSunTint(vec4 w) {
    return vec3(1.0) * (1.0 - dot(w, vec4(1.0)))
         + w.x * vec3(1.00, 1.00, 0.97)
         + w.y * vec3(1.10, 1.03, 0.90)
         + w.z * vec3(1.08, 0.90, 0.68)
         + w.w * vec3(0.78, 0.86, 1.00);
}

// the sky's colour (its brightness is kept): summer deeper blue, autumn warmer, winter paler and colder
vec3 seasonSky(vec3 c, vec4 w) {
    float l = luma(c);
    vec3 tint = vec3(1.0) * (1.0 - dot(w, vec4(1.0)))
              + w.x * vec3(0.97, 1.03, 1.00)
              + w.y * vec3(0.86, 0.97, 1.14)
              + w.z * vec3(1.14, 1.00, 0.80)
              + w.w * vec3(0.94, 0.98, 1.06);
    c *= tint;
    c = mix(c, vec3(luma(c)), 0.35 * w.w);   // winter: a washed-out sky
    return c / max(luma(c), 1e-5) * l;
}

// more (or fewer) clouds and how grey they are: x cover added, y brightness
vec2 seasonClouds(vec4 w) {
    return vec2(dot(w, vec4(0.02, -0.10, 0.10, 0.16)), 1.0 - 0.20 * w.w - 0.08 * w.z);
}

// air haze (times the look's own) and low mist: spring mornings, thick autumn mist, a little in winter
float seasonFog(vec4 w) { return 1.0 + dot(w, vec4(0.1, -0.15, 1.2, 0.7)); }
float seasonMist(vec4 w) {
    float t = float(worldTime);
    float morning = 1.0 - smoothstep(1500.0, 4000.0, mod(t + 1000.0, 24000.0));   // dawn to mid morning
    return w.x * (0.15 + 0.45 * morning) + w.z * (0.45 + 0.3 * morning) + w.w * 0.25;
}

// plants that are still green (tinted: 1 for green grass and leaves): fresh lime in spring, deep in summer, gold and
// russet in autumn, faded in winter. Serene Seasons' own autumn and winter tints aren't green, so they are kept as
// they are; this turns the rest (and every plant when the mod isn't there) with the season.
vec3 seasonPlants(vec3 c, vec4 w, float tinted) {
    if (tinted <= 0.0 || dot(w, vec4(1.0)) <= 0.0) return c;
    float l = luma(c);
    vec3 f = c;
    f = mix(f, l * vec3(0.85, 1.25, 0.50), 0.30 * w.x);                   // spring: fresh lime
    f = mix(f, max(mix(vec3(l), f, 1.25), 0.0), w.y);                     // summer: deep, saturated
    f = mix(f, l * mix(vec3(1.45, 1.00, 0.35), vec3(1.55, 0.70, 0.30), 0.4), 0.55 * w.z);   // autumn: gold, russet
    f = mix(f, mix(vec3(l), f, 0.55) * vec3(0.95, 0.97, 1.0), w.w);       // winter: faded
    return mix(c, f, tinted);
}

// winter frost on what faces the sky: white on the tops of plants, lighter on other blocks. c: surface colour,
// tinted: 1 for grass and leaves, up: how much the surface faces up, sky: sky light 0..1
vec3 seasonFrost(vec3 c, vec4 w, float tinted, float up, float sky) {
    float f = w.w * up * smoothstep(0.7, 0.95, sky) * mix(0.25, 0.55, tinted);
    return mix(c, vec3(0.82, 0.88, 0.95) * max(luma(c) * 1.4, 0.55), f);
}
#endif
