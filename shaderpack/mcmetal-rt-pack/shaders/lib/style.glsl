// Looks ("Style"): a colour grade after the tonemap, plus a few world touches (mist, glow) per look.
// 0 Natural, 1 Cottage, 2 Witchy, 3 Fairytale, 4 Cinematic. Our own grades (lift/gamma/gain, split toning).
#if STYLE == 1
    #define STYLE_FOG 1.2
    #define STYLE_MIST vec3(1.00, 0.90, 0.75)   // warm haze
    #define STYLE_GROUND_MIST 0.0
#elif STYLE == 2
    #define STYLE_FOG 1.6
    #define STYLE_MIST vec3(0.80, 0.75, 1.00)   // lavender mist
    #define STYLE_GROUND_MIST 1.0
#elif STYLE == 3
    #define STYLE_FOG 1.3
    #define STYLE_MIST vec3(1.00, 0.85, 0.95)   // pink-pearl haze
    #define STYLE_GROUND_MIST 0.4
#elif STYLE == 4
    #define STYLE_FOG 1.1
    #define STYLE_MIST vec3(0.85, 0.95, 1.00)
    #define STYLE_GROUND_MIST 0.0
#else
    #define STYLE_FOG 1.0
    #define STYLE_MIST vec3(1.0)
    #define STYLE_GROUND_MIST 0.0
#endif

// soft glow around bright things (lanterns, the sun on water, glowing blocks): a ring of taps from the HDR image,
// only what is brighter than about mid-grey counts. Strength per look.
#if STYLE == 1
    #define STYLE_GLOW 0.10
#elif STYLE == 2
    #define STYLE_GLOW 0.14
#elif STYLE == 3
    #define STYLE_GLOW 0.22
#elif STYLE == 4
    #define STYLE_GLOW 0.08
#else
    #define STYLE_GLOW 0.0
#endif

// split toning: shadows pulled towards one colour, highlights towards another (sums stay about neutral)
vec3 splitTone(vec3 c, vec3 shadowTint, vec3 highTint, float amount) {
    float l = luma(c);
    vec3 tint = mix(shadowTint, highTint, smoothstep(0.05, 0.6, l));
    return mix(c, c * tint, amount);
}

// c: tonemapped linear colour 0..1; uv: screen position (for the vignette)
vec3 styleGrade(vec3 c, vec2 uv) {
    float vig = 1.0 - dot(uv - 0.5, uv - 0.5);   // 1 in the middle, 0.5 in the corners
#if STYLE == 1
    // Cottage: warm afternoon, soft lifted shadows, greens a touch golden, gentle vignette
    c *= vec3(1.08, 1.0, 0.86);
    c = c * 0.97 + vec3(0.006, 0.0045, 0.0025);                       // lifted, slightly warm blacks
    c.g = mix(c.g, c.g * 0.96 + c.r * 0.04, 0.6);                     // greens lean golden
    c = mix(vec3(luma(c)), c, 1.12);
    c *= mix(0.86, 1.0, smoothstep(0.5, 0.8, vig));
#elif STYLE == 2
    // Witchy: plum-violet shadows, ember highlights, a little less colour in the midtones, deep vignette
    c = splitTone(c, vec3(0.88, 0.80, 1.18), vec3(1.10, 0.98, 0.86), 0.75);
    c = mix(vec3(luma(c)), c, 0.88);
    c = pow(c, vec3(1.06));                                            // a bit moodier mids
    c = c * 0.99 + vec3(0.003, 0.001, 0.006);                         // violet floor in the blacks
    c *= mix(0.72, 1.0, smoothstep(0.5, 0.85, vig));
#elif STYLE == 3
    // Fairytale: bright, saturated, pastel highlights (pink-lavender), soft contrast
    c = mix(vec3(luma(c)), c, 1.25);
    c = splitTone(c, vec3(0.92, 0.95, 1.12), vec3(1.06, 0.98, 1.04), 0.6);
    c = c * 0.97 + vec3(0.008, 0.006, 0.009);
    c = pow(c, vec3(0.94));
#elif STYLE == 4
    // Cinematic: teal shadows, warm skin-tone highlights, firmer contrast, vignette
    c = splitTone(c, vec3(0.86, 1.02, 1.10), vec3(1.08, 0.99, 0.88), 0.7);
    c = pow(c, vec3(1.08)) * 1.06;                                     // firmer mids without crushing the night
    c *= mix(0.78, 1.0, smoothstep(0.5, 0.85, vig));
#endif
    return clamp(c, 0.0, 1.0);
}
