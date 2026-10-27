// Coloured block light with real rays: mcmetal keeps a list of the light blocks near the camera (block ids 10100-10299
// from block.properties); each pixel picks one nearby light per frame, weighted by how much it could add, and
// traces a shadow ray to a random point inside it. Averaged over frames with the GI (deferred.fsh) that is every
// nearby light, each with its own colour and soft shadow. Fragment shaders only. Needs settings, common, uniforms.

#include "/lib/lightcolor.glsl"

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
    // mobs and your own body can stand closer to a light than any block face: lit as if 1.5 blocks away at most, so
    // skin beside lava or a lamp is warm, not blown out
    float dd = mat == MAT_ENTITY ? max(dist, 1.5) : dist;
    // faint lights (glowing leaves and logs: a whole tree of them) at half strength, or a grove lights itself up
    float strength = level / 15.0 * (level <= 6.0 ? 0.5 : 1.0);
    // and glowing leaves barely light each other: a canopy of them adds up to a white blaze at night's exposure
    if (level <= 6.0 && mat == MAT_EMISSIVE_DIM) strength *= 0.15;
    return c * strength * ndl * fade * fade * 4.0 / (0.25 * dd * dd + 1.0);
}

// where a light block's light comes from, seen from p. Small lights (torches, lanterns): the block's centre. Whole
// glowing blocks and lava: the point of the block nearest p, and for lava and fire the glow just over the surface.
// Aimed at the centre, lava's light came from below the floor beside it: that floor got none, and the floor's edge
// cut a hard curved shadow into the walls round the pool.
bool wholeLight(int id) { return (id >= 10200 && id < 10300) || id == 10104 || id == 10106; }
vec3 lightPoint(vec3 lp, int id, vec3 p) {
    if (!wholeLight(id)) return lp;
    vec3 q = lp + clamp(p - lp, vec3(-0.5), vec3(0.5));
    if (id == 10200) q.y = lp.y + 0.6;   // lava, fire
    return q;
}
// the point a shadow ray aims at (u2, u3 random): a random spot round lightPoint for soft shadows; small lights go to
// their centre with SHARP_LIGHT_SHADOWS, but whole blocks and lava are big lights and always soft
vec3 lightTarget(vec3 lp, int id, vec3 p, float u2, float u3) {
    vec3 j = (vec3(u2, u3, fract(u2 + u3 * 1.618)) - 0.5) * 0.5;
#ifdef SHARP_LIGHT_SHADOWS
    if (!wholeLight(id)) return lp;
#endif
    if (id == 10200) j = vec3(j.x * 1.8, j.y * 0.2, j.z * 1.8);   // spread over the pool's surface
    return lightPoint(lp, id, p) + j;
}
// how far short of the target a shadow ray stops (so it doesn't hit the light block itself): a full block's faces
// are 0.5 from its centre, corners up to 0.87; a target on the surface needs only its jitter's room
float lightStop(int id) { return wholeLight(id) ? 0.45 : 0.9; }

// one sample of all nearby lights: pick a light in proportion to its unshadowed light, trace its shadow, divide by
// the pick chance. u1, u2, u3 are random numbers in [0,1).
vec3 coloredBlockLight(vec3 p, vec3 n, int mat, float u1, float u2, float u3) {
    // glowing blocks (lava, glowstone) shine by themselves: lit by their own light, or a pool by its neighbours,
    // since lava's light comes from just over its surface they washed out pale
    if (mat == MAT_GLOW) return vec3(0.0);
    vec3 lp[LIGHT_SLOTS]; int ids[LIGHT_SLOTS]; float w[LIGHT_SLOTS];
    float total = 0.0;
    int count = 0;
    for (int i = 0; i < LIGHT_SLOTS; i++) {
        vec3 pos; int id;
        if (mcm_lights_near(p, i, pos, id) < 0) break;
        vec3 dir; float dist;
        w[i] = luma(lightFrom(p, n, mat, lightPoint(pos, id, p), id, dir, dist));
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
    // SHARP_LIGHT_SHADOWS: small lights' rays go to their centre (crisp edges); otherwise a random point of the light
    // makes soft shadows over the frames
    vec3 target = lightTarget(lp[pick], ids[pick], p, u2, u3);
    float stop = lightStop(ids[pick]);
    vec3 dir; float dist;
    vec3 l = lightFrom(p, n, mat, target, ids[pick], dir, dist);
    vec3 o = mat == MAT_FOLIAGE ? p + dir * 0.06 : p + n * 0.02 + dir * 0.01;
    // stop short of the light block itself (a full block's faces are 0.5 from its centre, corners up to 0.87)
#ifdef COLORED_LIGHT_GLASS
    // torch light through stained glass (and water) takes its colour too
    vec3 transmit = vec3(1.0);
    if (dist > stop && mcm_trace_tinted(o, dir, dist - stop, transmit) > 0.0) return vec3(0.0);
    // the filter mcmetal gives back is pale (the glass texture is half see-through): deepen its colour, keep its
    // brightness, so the floor behind red glass is clearly red
    l *= max(mix(vec3(luma(transmit)), transmit, 3.0), vec3(0.0));
#else
    if (dist > stop && mcm_trace(o, dir, dist - stop) > 0.0) return vec3(0.0);
#endif
    return l * (total / w[pick]) * COLORED_LIGHT_STRENGTH * STYLE_BLOCK_TINT;
}
#ifdef LIGHT_RESTIR
// Reservoir reuse over time (ReSTIR, the temporal half): each GI pixel keeps the light it picked last frame and how
// much evidence is behind that pick (a reservoir, in Iris shader storage buffer 1). This frame's fresh pick competes
// with last frame's, weighted by what each could add here now, so with 30 candles the pixel settles on the ones that
// matter and that it can see (an occluded pick is stored with weight 0: visibility reuse). Less noise per frame,
// so the averaged block light settles faster and lags less behind a moving camera.
#extension GL_ARB_shader_storage_buffer_object : enable
layout(std430, binding = 1) buffer LightReservoirs { uvec2 lrCells[]; };   // x light block (10 bits per axis,
const int LR_HALF = 2097152;                                                 // world mod 1024; bit 30 set), y W, M
int lrIndex(vec2 px, int frame) {
    ivec2 q = ivec2(px);
    int stride = int(ceil(viewWidth * GI_SCALE));
    int i = q.y * stride + q.x;
    return q.x < 0 || q.y < 0 || q.x >= stride || i >= LR_HALF ? -1 : i + (frame & 1) * LR_HALF;
}
uint lrPackPos(vec3 playerPos) {
    ivec3 b = ivec3(floor(playerPos + cameraPosition));
    return uint(b.x & 1023) | (uint(b.y & 1023) << 10) | (uint(b.z & 1023) << 20) | (1u << 30);
}
vec3 lrUnpackPos(uint v) {   // the light block's centre in player space (the copy of it nearest the camera)
    ivec3 cb = ivec3(floor(cameraPosition));
    ivec3 s = ivec3(int(v & 1023u), int((v >> 10) & 1023u), int((v >> 20) & 1023u));
    ivec3 d = (s - cb) & 1023;
    d -= ivec3(greaterThanEqual(d, ivec3(512))) * 1024;
    return vec3(cb + d) + 0.5 - cameraPosition;
}

// u1-u4 random numbers in [0,1); prevPx: this point's GI pixel last frame (prevOk: it was this surface); px: now
vec3 coloredBlockLightReSTIR(vec3 p, vec3 n, int mat, float u1, float u2, float u3, float u4, vec2 prevPx, bool prevOk, vec2 px) {
    if (mat == MAT_GLOW) {   // (as coloredBlockLight)
        int gi = lrIndex(px, frameCounter);
        if (gi >= 0) lrCells[gi] = uvec2(0u);
        return vec3(0.0);
    }
    // a fresh pick among the nearest lights, in proportion to their unshadowed light (as coloredBlockLight)
    vec3 lp[LIGHT_SLOTS]; int ids[LIGHT_SLOTS]; float w[LIGHT_SLOTS];
    float total = 0.0;
    int count = 0;
    for (int i = 0; i < LIGHT_SLOTS; i++) {
        vec3 pos; int id;
        if (mcm_lights_near(p, i, pos, id) < 0) break;
        vec3 dir; float dist;
        w[i] = luma(lightFrom(p, n, mat, lightPoint(pos, id, p), id, dir, dist));
        lp[i] = pos; ids[i] = id;
        total += w[i];
        count++;
    }
    vec3 yPos = vec3(0.0); int yId = -1; float yPhat = 0.0;
    float wsum = 0.0, M = 0.0;
    if (total > 0.0) {
        int pick = count - 1;
        float x = u1 * total;
        for (int i = 0; i < count; i++) {
            if (x < w[i]) { pick = i; break; }
            x -= w[i];
        }
        yPos = lp[pick]; yId = ids[pick]; yPhat = w[pick];
        wsum = total;   // its target over its pick chance: w / (w / total)
        M = 1.0;
    }
    // last frame's pick, if that light is still there and this pixel saw the same surface
    int pi = prevOk ? lrIndex(prevPx, frameCounter + 1) : -1;
    if (pi >= 0) {
        uvec2 e = lrCells[pi];
        vec2 wm = unpackHalf2x16(e.y);
        if ((e.x & (1u << 30)) != 0u && wm.x > 0.0 && wm.y > 0.0) {
            vec3 pp = lrUnpackPos(e.x), qpos; int qid;
            if (mcm_lights_near(pp, 0, qpos, qid) >= 0 && distance(qpos, pp) < 0.1) {
                vec3 dir; float dist;
                float phat = luma(lightFrom(p, n, mat, lightPoint(qpos, qid, p), qid, dir, dist));
                float pm = min(wm.y, 20.0);   // caps how long an old pick outweighs fresh ones
                float wp = phat * wm.x * pm;
                wsum += wp;
                M += pm;
                if (u4 * wsum < wp) { yPos = qpos; yId = qid; yPhat = phat; }
            }
        }
    }
    int ci = lrIndex(px, frameCounter);
    if (yPhat <= 0.0 || M <= 0.0) {
        if (ci >= 0) lrCells[ci] = uvec2(0u);
        return vec3(0.0);
    }
    float W = wsum / (M * yPhat);
    vec3 target = lightTarget(yPos, yId, p, u2, u3);
    float stop = lightStop(yId);
    vec3 dir; float dist;
    vec3 l = lightFrom(p, n, mat, target, yId, dir, dist);
    vec3 o = mat == MAT_FOLIAGE ? p + dir * 0.06 : p + n * 0.02 + dir * 0.01;
  #ifdef COLORED_LIGHT_GLASS
    vec3 transmit = vec3(1.0);
    bool blocked = dist > stop && mcm_trace_tinted(o, dir, dist - stop, transmit) > 0.0;
    l *= max(mix(vec3(luma(transmit)), transmit, 3.0), vec3(0.0));
  #else
    bool blocked = dist > stop && mcm_trace(o, dir, dist - stop) > 0.0;
  #endif
    if (ci >= 0) lrCells[ci] = uvec2(lrPackPos(yPos), packHalf2x16(vec2(blocked ? 0.0 : W, min(M, 20.0))));
    if (blocked) return vec3(0.0);
    return l * W * COLORED_LIGHT_STRENGTH * STYLE_BLOCK_TINT;
}
#endif
#endif
