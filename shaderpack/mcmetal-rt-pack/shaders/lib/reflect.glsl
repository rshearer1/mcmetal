// Ray-traced reflections (fragment shaders, with USE_RT). Needs settings, common, uniforms, sky, lighting, shadow.
// mcmetal: closest solid/cutout hit with its face normal, texture colour x vertex tint (sRGB), lightmap and block id
float mcm_trace_hit(vec3 origin, vec3 dir, float tmax, out vec3 normal, out vec4 albedo, out vec2 lightmap, out int blockId);
#ifdef COARSE_RAYS
// the same, but every block counts as solid: no alpha test for leaves, grass and flowers, so the ray hardware never
// stops for them (mcmetal's MCMETAL_RT_COARSE). For blurry light only (bounce light, AO): a leaf's holes don't show.
float mcm_trace_hit_coarse(vec3 origin, vec3 dir, float tmax, out vec3 normal, out vec4 albedo, out vec2 lightmap,
                           out int blockId);
float mcm_trace_coarse(vec3 origin, vec3 dir, float tmax);
// the first 2 blocks still exact (grass and flowers right next to a surface would darken its AO as solid squares)
float traceHitCoarse(vec3 p, vec3 dir, float tmax, out vec3 hn, out vec4 ha, out vec2 hl, out int id) {
    float t = mcm_trace_hit(p, dir, min(tmax, 2.0), hn, ha, hl, id);
    if (t >= 0.0 || tmax <= 2.0) return t;
    t = mcm_trace_hit_coarse(p + dir * 2.0, dir, tmax - 2.0, hn, ha, hl, id);
    return t < 0.0 ? t : t + 2.0;
}
    #define TRACE_HIT traceHitCoarse
#else
    #define TRACE_HIT mcm_trace_hit
#endif
#if defined MCMETAL_RT_PBR && defined LABPBR && defined RT_PBR_EMISSIVE
// mcmetal: the LabPBR emission (specular map alpha) where the last TRACE_HIT landed, so glowing texels light
// rooms and show in reflections, like they do on screen
float mcm_hit_emission();
    #define HIT_PBR_EMISSION
#endif

#if defined WORLD_CACHE && defined GI_CACHE
    #include "/lib/worldcache.glsl"
#endif

int materialOf(int blockId) {
    if (blockId == 10001 || blockId == 10004) return MAT_FOLIAGE;
    if (blockId >= 10100 && blockId < 10200) return MAT_EMISSIVE;
    if (blockId >= 10200 && blockId < 10300) return MAT_GLOW;
    return MAT_NONE;
}

// Light coming back along -dir from what a ray from p sees: the lit block it hits, or the sky (times skyOpen).
// t = hit distance or -1.
vec3 traceRadiance(vec3 p, vec3 dir, float tmax, vec3 L, vec3 sunCol, vec3 skyAmb, vec3 sunDir, float skyOpen, out float t) {
    vec3 hn; vec4 ha; vec2 hl; int id;
    t = TRACE_HIT(p, dir, tmax, hn, ha, hl, id);
    if (t < 0.0) return skyColor(dir, sunDir) * skyOpen;
    vec3 hp = p + dir * t;
    int mat = materialOf(id);
    vec3 a = toLinear(ha.rgb);
#ifdef HIT_PBR_EMISSION
    vec3 pbrGlow = a * mcm_hit_emission() * (4.0 * EMISSIVE_STRENGTH);   // the same as deferred4's
#else
    vec3 pbrGlow = vec3(0.0);
#endif
    vec3 sh = vec3(0.0);
    // a second ray: is the hit in shadow? Far away (only in reflections) the hit's sky light stands in for it
    // (no sky light at the hit, in a world that has it: no path to the sun, no ray)
    if ((dot(hn, L) > 0.0 || mat == MAT_FOLIAGE) && hl.y > 0.05 && hasSkylight)   // no sun in the Nether or End
    {
  #ifdef SHADOW_CACHE
        // a hit that was on screen last frame already has its (soft, averaged) sun shadow: no ray needed
        if (!cachedShadow(hp, sh))
  #endif
  #ifdef COARSE_RAYS
        sh = t < 48.0 ? vec3(mcm_trace_coarse(mat == MAT_FOLIAGE ? hp + L * 0.06 : hp + hn * 0.02 + L * 0.01, L, 256.0) < 0.0) : vec3(smoothstep(0.8, 0.95, hl.y));
  #else
        sh = t < 48.0 ? sunShadow(hp, hn, L, mat) : vec3(smoothstep(0.8, 0.95, hl.y));
  #endif
    }
#ifdef GI_CACHE
    // light cache (the pass's cachedGI): on screen, the hit takes the GI gathered there, which already holds the
    // sky light, earlier bounces and (with coloured light) the block light, in place of the lightmap's guesses
    vec3 cgi;
    bool cached = cachedGI(hp, cgi);
  #ifdef WORLD_CACHE
    if (!cached) cached = wcLoad(hp + cameraPosition, hn, cgi);   // off screen: the world-space cache
  #endif
    if (cached) {
  #ifdef USE_LIGHTS
        vec2 clm = vec2(0.0, hl.y);
  #else
        vec2 clm = hl;
  #endif
        return a * (surfaceLight(hp, hn, clm, 1.0, mat, L, sunCol, hasSkylight ? vec3(0.0) : skyAmb, sh) + cgi)
             + emission(a, mat) + pbrGlow;
    }
#endif
    return a * surfaceLight(hp, hn, hl, 1.0, mat, L, sunCol, skyAmb, sh) + emission(a, mat) + pbrGlow;
}

vec3 traceReflection(vec3 p, vec3 dir, vec3 L, vec3 sunCol, vec3 skyAmb, vec3 sunDir, float skyOpen) {
    float t;
    return traceRadiance(p, dir, RT_REFLECT_DISTANCE, L, sunCol, skyAmb, sunDir, skyOpen, t);
}
