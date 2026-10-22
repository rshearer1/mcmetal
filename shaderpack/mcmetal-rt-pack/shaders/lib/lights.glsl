// Coloured block light with real rays: mcmetal keeps a list of the light blocks near the camera (block ids 10100-10299
// from block.properties); each pixel picks one nearby light per frame, weighted by how much it could add, and
// traces a shadow ray to a random point inside it. Averaged over frames with the GI (deferred.fsh) that is every
// nearby light, each with its own colour and soft shadow. Fragment shaders only. Needs settings, common, uniforms.

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
    return vec3(1.0, 0.6, 0.3);
}

#ifdef USE_LIGHTS
// supplied by mcmetal: the slot-th light block near p (block centre in player space, its block id), or -1
int mcm_lights_near(vec3 p, int slot, out vec3 pos, out int blockId);
float mcm_trace(vec3 origin, vec3 dir, float tmax);
float mcm_trace_tinted(vec3 origin, vec3 dir, float tmax, out vec3 transmit);

// unshadowed light from one light block: about inverse square (softened near the block), faded out where vanilla's
// light would end; at 1-5 blocks about as bright as vanilla's full block light
vec3 lightFrom(vec3 p, vec3 n, int mat, vec3 lp, int id, out vec3 dir, out float dist) {
    float level;
    vec3 c = lightColorOf(id, level);
    vec3 d = lp - p;
    dist = length(d);
    dir = d / max(dist, 1e-4);
    float ndl = mat == MAT_FOLIAGE ? 0.6 : max(dot(n, dir), 0.0);
    float fade = clamp(1.0 - dist / level, 0.0, 1.0);
    return c * (level / 15.0) * ndl * fade * fade * 4.0 / (0.25 * dist * dist + 1.0);
}

// one sample of all nearby lights: pick a light in proportion to its unshadowed light, trace its shadow, divide by
// the pick chance. u1, u2, u3 are random numbers in [0,1).
vec3 coloredBlockLight(vec3 p, vec3 n, int mat, float u1, float u2, float u3) {
    vec3 lp[LIGHT_SLOTS]; int ids[LIGHT_SLOTS]; float w[LIGHT_SLOTS];
    float total = 0.0;
    int count = 0;
    for (int i = 0; i < LIGHT_SLOTS; i++) {
        vec3 pos; int id;
        if (mcm_lights_near(p, i, pos, id) < 0) break;
        vec3 dir; float dist;
        w[i] = luma(lightFrom(p, n, mat, pos, id, dir, dist));
        lp[i] = pos; ids[i] = id;
        total += w[i];
        count++;
    }
    if (total <= 0.0) return vec3(0.0);
    int pick = count - 1;
    float x = u1 * total;
    for (int i = 0; i < count; i++) {
        if (x < w[i]) { pick = i; break; }
        x -= w[i];
    }
    // a random point inside the light block makes soft shadows over the frames
    vec3 target = lp[pick] + (vec3(u2, u3, fract(u2 + u3 * 1.618)) - 0.5) * 0.5;
    vec3 dir; float dist;
    vec3 l = lightFrom(p, n, mat, target, ids[pick], dir, dist);
    vec3 o = mat == MAT_FOLIAGE ? p + dir * 0.06 : p + n * 0.02 + dir * 0.01;
    // stop short of the light block itself (a full block's faces are 0.5 from its centre, corners up to 0.87)
#ifdef COLORED_SHADOWS
    // torch light through stained glass (and water) takes its colour too
    vec3 transmit = vec3(1.0);
    if (dist > 0.9 && mcm_trace_tinted(o, dir, dist - 0.9, transmit) > 0.0) return vec3(0.0);
    l *= transmit;
#else
    if (dist > 0.9 && mcm_trace(o, dir, dist - 0.9) > 0.0) return vec3(0.0);
#endif
    return l * (total / w[pick]) * COLORED_LIGHT_STRENGTH;
}
#endif
