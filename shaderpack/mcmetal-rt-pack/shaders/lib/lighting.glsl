// Light colours of the moment and the shading every lit program shares. Needs settings, common, uniforms, sky.

vec3 sunDirection() { return normalize(mat3(gbufferModelViewInverse) * sunPosition); }
vec3 lightDirection() { return normalize(mat3(gbufferModelViewInverse) * shadowLightPosition); }  // sun by day, moon by night

// Direct light colour (from the sun or moon, whichever is up) and sky light from the whole sky.
// Cheap enough for a vertex shader; full-screen passes compute it there and pass it on flat.
void lightColors(out vec3 sunCol, out vec3 skyAmb) {
    vec3 sunDir = sunDirection();
    float moonLight = 0.25 + 0.75 * abs(float(moonPhase) - 4.0) / 4.0;   // full moon brightest
    vec3 sun = lightTransmittance(sunDir) * (SUN_INTENSITY * 0.2);
    vec3 moon = lightTransmittance(-sunDir) * (MOON_INTENSITY * 0.2 * moonLight) * vec3(0.8, 0.9, 1.15);
    sunCol = (sun + moon) * SUN_STRENGTH;
    vec3 h = normalize(vec3(sunDir.x, 0.0, sunDir.z) + vec3(0.0001));
    skyAmb = PI * (0.5 * skyColor(vec3(0.0, 1.0, 0.0), sunDir)
                   + 0.25 * skyColor(normalize(h + vec3(0.0, 0.2, 0.0)), sunDir)
                   + 0.25 * skyColor(normalize(-h + vec3(0.0, 0.2, 0.0)), sunDir)) * SKY_LIGHT_STRENGTH;
    // rain: clouds block the sun and grey the sky
    sunCol *= 1.0 - 0.85 * rainStrength;
    skyAmb = mix(skyAmb, vec3(luma(skyAmb)) * 0.6, rainStrength);
}


vec3 blockLightColor() { return vec3(BLOCK_LIGHT_R, BLOCK_LIGHT_G, BLOCK_LIGHT_B); }

// Light arriving at a surface, before it's multiplied by the surface colour.
// sh = sun shadow (1 lit, 0 shadowed); ao = vanilla corner darkening for now (ray-traced AO in step 2).
vec3 surfaceLight(vec3 p, vec3 n, vec2 lm, float ao, int mat, vec3 L, vec3 sunCol, vec3 skyAmb, float sh) {
    float ndl = dot(n, L);
    float diff = mat == MAT_FOLIAGE ? 0.55 + 0.45 * abs(ndl) : max(ndl, 0.0);
    vec3 direct = sunCol * diff * sh;
    vec3 sky = skyAmb * (lm.y * lm.y) * (0.7 + 0.3 * n.y) * ao;
    // block light (torches etc.); the held light is a sphere around the player
    float held = float(max(heldBlockLightValue, heldBlockLightValue2));
    float bl = max(lm.x, clamp((held - length(p)) / 15.0, 0.0, 1.0));
    vec3 blk = blockLightColor() * (1.6 * bl * bl * bl + 0.05 * bl) * BLOCK_LIGHT_STRENGTH * ao;
    vec3 floorLight = vec3(0.0015, 0.0017, 0.002) * ao + vec3(0.25) * nightVision;
    return direct + sky + blk + floorLight;
}

// Glow of light-giving blocks: bright texels of torches/lanterns, the whole block for lava, glowstone etc.
vec3 emission(vec3 albedo, int mat) {
    if (mat == MAT_GLOW) return albedo * (2.5 * EMISSIVE_STRENGTH);
    if (mat == MAT_EMISSIVE) return albedo * (4.0 * EMISSIVE_STRENGTH) * smoothstep(0.35, 0.75, max(albedo.r, max(albedo.g, albedo.b)));
    return vec3(0.0);
}
