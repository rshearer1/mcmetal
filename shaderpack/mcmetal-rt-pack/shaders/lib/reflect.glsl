// Ray-traced reflections (fragment shaders, with USE_RT). Needs settings, common, uniforms, sky, lighting, shadow.
// mcmetal: closest solid/cutout hit with its face normal, texture colour x vertex tint (sRGB), lightmap and block id
float mcm_trace_hit(vec3 origin, vec3 dir, float tmax, out vec3 normal, out vec4 albedo, out vec2 lightmap, out int blockId);

int materialOf(int blockId) {
    if (blockId == 10001) return MAT_FOLIAGE;
    if (blockId >= 10100 && blockId < 10200) return MAT_EMISSIVE;
    if (blockId >= 10200 && blockId < 10300) return MAT_GLOW;
    return MAT_NONE;
}

// Light coming back along -dir from what a ray from p sees: the lit block it hits, or the sky (times skyOpen).
// t = hit distance or -1.
vec3 traceRadiance(vec3 p, vec3 dir, float tmax, vec3 L, vec3 sunCol, vec3 skyAmb, vec3 sunDir, float skyOpen, out float t) {
    vec3 hn; vec4 ha; vec2 hl; int id;
    t = mcm_trace_hit(p, dir, tmax, hn, ha, hl, id);
    if (t < 0.0) return skyColor(dir, sunDir) * skyOpen;
    vec3 hp = p + dir * t;
    int mat = materialOf(id);
    vec3 a = toLinear(ha.rgb);
    vec3 sh = vec3(0.0);
    if (dot(hn, L) > 0.0 || mat == MAT_FOLIAGE) sh = sunShadow(hp, hn, L, mat);   // a second ray: is the hit in shadow?
    return a * surfaceLight(hp, hn, hl, 1.0, mat, L, sunCol, skyAmb, sh) + emission(a, mat);
}

vec3 traceReflection(vec3 p, vec3 dir, vec3 L, vec3 sunCol, vec3 skyAmb, vec3 sunDir, float skyOpen) {
    float t;
    return traceRadiance(p, dir, RT_REFLECT_DISTANCE, L, sunCol, skyAmb, sunDir, skyOpen, t);
}
