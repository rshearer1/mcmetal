// PATH_TRACED: the bounce light as a real path (deferred.fsh), like Bedrock RTX, instead of one bounce plus the light
// cache's guesses. From the surface the ray bounces up to PT_BOUNCES times; at every block it lands on it adds that
// block's own glow (glowing blocks, LabPBR emissive texels) and asks the lights directly (next event estimation):
// a shadow ray to the sun or moon, and one nearby light block from mcmetal's light list with its own shadow ray. The
// light it carries on is tinted by each block's colour, so a red wall really fills a white room with red after two
// bounces, and a lamp-lit corridor lights the room round the corner. Lightmaps are not used for light, only to tell
// whether a surface can see the sky at all (rays that run out of range fall back to the sky only as far as
// Minecraft's sky light reaches there, so caves stay dark). Needs reflect.glsl (TRACE_HIT, materialOf), shadow.glsl
// and lights.glsl included first. Fragment shaders only.

// sky seen by a path: the sky colour, paled as for the one-bounce GI (SKY_GI_SATURATION), times how open the place
// the ray left from is to the sky (skyLM: its sky lightmap, 1 under open sky)
vec3 ptSky(vec3 dir, vec3 sunDir, float skyLM) {
    vec3 s = skyColor(dir, sunDir);
    s = mix(vec3(luma(s)), s, SKY_GI_SATURATION) * SKY_LIGHT_STRENGTH;
    return hasSkylight ? s * (skyLM * skyLM) : s;
}

// a cosine-weighted direction round n (its pdf cancels the cosine and 1/pi of a matte surface: the throughput just
// takes the surface colour)
vec3 ptCosine(vec3 n, float u1, float u2) {
    float r = sqrt(u1), phi = 6.2832 * u2;
    vec3 t = normalize(abs(n.y) < 0.99 ? cross(n, vec3(0.0, 1.0, 0.0)) : cross(n, vec3(1.0, 0.0, 0.0)));
    return normalize(t * (r * cos(phi)) + cross(n, t) * (r * sin(phi)) + n * sqrt(max(1.0 - u1, 0.0)));
}

// Light arriving at the surface along d, from a path that starts at o. skyLM0: the sky lightmap where it starts.
// t0 = distance to the first block the path hits, or -1 (the AO uses it). px: this pixel, for the random numbers.
vec3 pathTrace(vec3 o, vec3 d, float skyLM0, vec3 L, vec3 sunCol, vec3 skyAmb, vec3 sunDir, vec2 px, out float t0) {
    vec3 radiance = vec3(0.0), throughput = vec3(1.0);
    float skyLM = skyLM0;
    t0 = -1.0;
    for (int b = 0; b < PT_BOUNCES; b++) {
        vec3 hn; vec4 ha; vec2 hl; int id;
        float t = TRACE_HIT(o, d, PT_DISTANCE, hn, ha, hl, id);
        if (b == 0) t0 = t;
        if (t < 0.0) {
            radiance += throughput * ptSky(d, sunDir, skyLM);
            break;
        }
        vec3 hp = o + d * t;
        int mat = materialOf(id);
        vec3 a = toLinear(ha.rgb);
        int dim = 6 + 6 * b;   // this bounce's own random numbers (lights 3, roulette, direction, plant side)
        // what the block gives off itself
#ifdef HIT_PBR_EMISSION
        radiance += throughput * (emission(a, mat) + a * mcm_hit_emission() * (4.0 * EMISSIVE_STRENGTH));
#else
        radiance += throughput * emission(a, mat);
#endif
        // a block seen from behind (inside a wall, the back of a plant): face the ray
        if (dot(hn, d) > 0.0) hn = -hn;
        // the sun or moon, with a shadow ray (none where no sky light reaches: no path to the sun)
        vec3 sh = vec3(0.0);
        if ((dot(hn, L) > 0.0 || mat == MAT_FOLIAGE) && hl.y > 0.05 && hasSkylight) {
#ifdef SHADOW_CACHE
            if (!cachedShadow(hp, sh))
#endif
            sh = sunShadow(hp, hn, L, mat);
        }
        // direct light at the hit: sun, the held light, and (no light list) the lightmap's block light; no sky guess
#ifdef USE_LIGHTS
        vec2 clm = vec2(0.0);
#else
        vec2 clm = vec2(hl.x, 0.0);
#endif
        vec3 direct = surfaceLight(hp, hn, clm, 1.0, mat, L, sunCol, hasSkylight ? vec3(0.0) : skyAmb, sh);
#ifdef USE_LIGHTS
        // one nearby light block, picked by what it could add, with its own shadow ray
        if (hl.x > 0.05)
            direct += coloredBlockLight(hp, hn, mat, rayRand(px, frameCounter, dim),
                                        rayRand(px, frameCounter, dim + 1), rayRand(px, frameCounter, dim + 2));
#endif
        radiance += throughput * a * direct;
        throughput *= a;
        // Russian roulette after the second bounce: a dark path stops early, a surviving one counts for more
        if (b >= 1) {
            float keep = clamp(max(throughput.r, max(throughput.g, throughput.b)) * 1.5, 0.05, 1.0);
            if (rayRand(px, frameCounter, dim + 3) >= keep) break;
            throughput /= keep;
        }
        // the next direction: plants let light through, so half their bounces go out the other side
        vec3 bn = hn;
        float u1 = rayRand(px, frameCounter + 7 * (b + 1), 0), u2 = rayRand(px, frameCounter, dim + 4);
        if (mat == MAT_FOLIAGE && rayRand(px, frameCounter, dim + 5) < 0.5) bn = -hn;
        d = ptCosine(bn, u1, u2);
        o = mat == MAT_FOLIAGE ? hp + d * 0.05 : hp + hn * 0.02;
        skyLM = hl.y;
    }
    return radiance;
}
