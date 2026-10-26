// Light colours of the moment and the shading every lit program shares. Needs settings, common, uniforms, sky.

vec3 sunDirection() { return normalize(mat3(gbufferModelViewInverse) * sunPosition); }
vec3 lightDirection() { return normalize(mat3(gbufferModelViewInverse) * shadowLightPosition); }  // sun by day, moon by night

// Direct light colour (from the sun or moon, whichever is up) and sky light from the whole sky.
// Worked out once a frame in prepare.fsh (lightColorsExact) and read back from the sky table everywhere else.
void lightColorsExact(out vec3 sunCol, out vec3 skyAmb) {
    if (!hasSkylight) {   // Nether, End: no sun or moon; skyAmb is the world's own light (lib/sky.glsl)
        sunCol = vec3(0.0);
        skyAmb = dimensionLight() * SKY_LIGHT_STRENGTH;
        return;
    }
    vec3 sunDir = sunDirection();
    float moonLight = 0.25 + 0.75 * abs(float(moonPhase) - 4.0) / 4.0;   // full moon brightest
    vec3 sun = lightTransmittance(sunDir) * (SUN_INTENSITY * 0.2) * STYLE_SUN_TINT * seasonSunTint(seasonWeights());
    vec3 moon = lightTransmittance(-sunDir) * (MOON_INTENSITY * 0.2 * moonLight * STYLE_MOON) * vec3(0.8, 0.9, 1.15) * STYLE_MOON_TINT;
    sunCol = (sun + moon) * SUN_STRENGTH;
    vec3 h = normalize(vec3(sunDir.x, 0.0, sunDir.z) + vec3(0.0001));
    skyAmb = (0.5 * skyColorExact(vec3(0.0, 1.0, 0.0), sunDir)
                   + 0.25 * skyColorExact(normalize(h + vec3(0.0, 0.2, 0.0)), sunDir)
                   + 0.25 * skyColorExact(normalize(-h + vec3(0.0, 0.2, 0.0)), sunDir)) * SKY_LIGHT_STRENGTH;
    // rain: clouds block the sun and grey the sky
    sunCol *= 1.0 - 0.85 * rainStrength;
    skyAmb = mix(skyAmb, vec3(luma(skyAmb)) * 0.6, rainStrength);
}
#ifndef SKY_LUT_BUILD
void lightColors(out vec3 sunCol, out vec3 skyAmb) {
    sunCol = texelFetch(colortex12, ivec2(0, 63), 0).rgb;
    skyAmb = texelFetch(colortex12, ivec2(1, 63), 0).rgb;
}
#endif


vec3 blockLightColor() { return vec3(BLOCK_LIGHT_R, BLOCK_LIGHT_G, BLOCK_LIGHT_B) * STYLE_BLOCK_TINT; }

// Light arriving at a surface, before it's multiplied by the surface colour.
// sh = sun shadow (1 lit, 0 shadowed); ao = vanilla corner darkening for now (ray-traced AO in step 2).
vec3 surfaceLight(vec3 p, vec3 n, vec2 lm, float ao, int mat, vec3 L, vec3 sunCol, vec3 skyAmb, vec3 sh) {
    float ndl = dot(n, L);
    float diff = mat == MAT_FOLIAGE ? 0.55 + 0.45 * abs(ndl) : max(ndl, 0.0);
    vec3 direct = sunCol * diff * sh;
#ifdef STYLE_TOON
    // Storybook: flat bands of sunlight instead of a smooth falloff (the shadow's colour is kept)
    float ls = luma(sh);
    direct = sunCol * toonBands(clamp(diff * ls, 0.0, 1.0)) * (ls > 1e-3 ? sh / ls : vec3(1.0));
#endif
    // sky light by the lightmap; where there is no sky (Nether, End) skyAmb is the world's own light, everywhere
    vec3 sky = skyAmb * (hasSkylight ? lm.y * lm.y : 1.0) * (0.7 + 0.3 * n.y) * ao;
    // block light (torches etc.); the held light is a sphere around the player
    float held = float(max(heldBlockLightValue, heldBlockLightValue2));
    float bl = max(lm.x, clamp((held - length(p)) / 15.0, 0.0, 1.0));
#ifdef STYLE_TOON
    bl = toonBands(bl);
#endif
    vec3 blk = blockLightColor() * (1.2 * bl * bl * bl + 0.05 * bl) * BLOCK_LIGHT_STRENGTH * ao;
    vec3 floorLight = vec3(0.0015, 0.0017, 0.002) * ao + vec3(0.25) * nightVision;
    return direct + sky + blk + floorLight;
}

// Glow of light-giving blocks: bright texels of torches/lanterns, the whole block for lava, glowstone etc.
vec3 emission(vec3 albedo, int mat) {
    if (mat == MAT_GLOW) return albedo * (2.5 * EMISSIVE_STRENGTH);
    if (mat == MAT_EMISSIVE) return albedo * (4.0 * EMISSIVE_STRENGTH) * smoothstep(0.35, 0.75, max(albedo.r, max(albedo.g, albedo.b)));
    return vec3(0.0);
}
