// World-space light cache: the bounce light gathered on screen (deferred.fsh's averaged GI) is also kept per block
// face in world space, in a hash table (Iris shader storage buffer 0, shaders.properties). A ray that hits a face
// off screen (behind you, round a corner) finds its light here instead of the lightmap's guess, so light keeps
// bouncing where the screen-space light cache (cachedGI) can't see.
// One cell per block face: the block on the air side of the surface and which way the face looks (6). Each cell
// is a uvec4: x key (0 empty), yzw light (float bits). Direct-mapped: a cell whose slot another face took is
// simply missing until it is seen again. Needs nothing but the position and normal.
#ifndef WORLD_CACHE_LIB
#define WORLD_CACHE_LIB
#extension GL_ARB_shader_storage_buffer_object : enable
layout(std430, binding = 0) buffer WorldCache { uvec4 wcCells[]; };
const uint WC_CELLS = 1048576u;   // 16 MB (bufferObject.0)

uint wcHash(uvec4 v) {   // pcg4d-style mix, one lane out
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    v ^= v >> 16u;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    return v.x ^ v.y ^ v.z ^ v.w;
}
// wp: world position (player space + cameraPosition), n: surface normal
void wcCell(vec3 wp, vec3 n, out uint slot, out uint key) {
    vec3 an = abs(n);
    int face = an.x > an.y && an.x > an.z ? (n.x > 0.0 ? 0 : 1) : an.y > an.z ? (n.y > 0.0 ? 2 : 3) : (n.z > 0.0 ? 4 : 5);
    uvec4 c = uvec4(ivec4(ivec3(floor(wp + n * 0.25)), face));
    slot = wcHash(c) & (WC_CELLS - 1u);
    key = wcHash(c.yzwx + 0x9e3779b9u) | 1u;
}
bool wcLoad(vec3 wp, vec3 n, out vec3 light) {
    uint slot, key;
    wcCell(wp, n, slot, key);
    uvec4 e = wcCells[slot];
    light = uintBitsToFloat(e.yzw);
    return e.x == key && all(greaterThanEqual(light, vec3(0.0))) && all(lessThan(light, vec3(64.0)));
}
// blends towards the new light (a slow average: many pixels see the same face each frame)
void wcStore(vec3 wp, vec3 n, vec3 light) {
    uint slot, key;
    wcCell(wp, n, slot, key);
    uvec4 e = wcCells[slot];
    vec3 old = uintBitsToFloat(e.yzw);
    bool same = e.x == key && all(greaterThanEqual(old, vec3(0.0))) && all(lessThan(old, vec3(64.0)));
    wcCells[slot] = uvec4(key, floatBitsToUint(same ? mix(old, light, 0.1) : light));
}
#endif
