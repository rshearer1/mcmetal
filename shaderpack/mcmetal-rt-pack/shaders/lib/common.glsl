// Shared helpers: constants, packing, colour.
const float PI = 3.14159265359;

// materials (colortex2.r * 255)
#define MAT_NONE     0
#define MAT_FOLIAGE  1   // thin plants and leaves: lit from both sides
#define MAT_EMISSIVE 2   // light blocks: their bright texels glow
#define MAT_GLOW     3   // fully glowing blocks (lava, glowstone, froglights)
#define MAT_HAND     4
#define MAT_ENTITY   5
#define MAT_WATER    6
#define MAT_SKY      7   // stars and the moon, drawn into the sky
#define MAT_LIT      8   // already lit (clouds etc.): deferred keeps the colour as it is
#define MAT_GLASS   10   // glass and stained glass: refraction in gbuffers_water (lib/gbuffer.glsl)
#define MAT_DH       9   // Distant Horizons terrain (far LODs): no rays, lit from the lightmap in deferred4.fsh

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
vec3 toLinear(vec3 c) { return c * c * (c * 0.2 + 0.8); }     // cheap fit of the sRGB curve
vec3 toSRGB(vec3 c) {
    vec3 lo = c * 12.92, hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(lo, hi, step(0.0031308, c));
}

// octahedral normal packing into [0,1]^2 (Cigolle et al. 2014)
vec2 octEncode(vec3 n) {
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    vec2 p = n.z >= 0.0 ? n.xy : (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return p * 0.5 + 0.5;
}
vec3 octDecode(vec2 e) {
    e = e * 2.0 - 1.0;
    vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    float t = clamp(-n.z, 0.0, 1.0);
    n.xy -= vec2(n.x >= 0.0 ? t : -t, n.y >= 0.0 ? t : -t);
    return normalize(n);
}

// rays for only 1 in `rate` pixels this frame (a checkerboard for 2, one pixel of each 2x2 for 4); true = skip
bool rayRest(vec2 fragCoord, int rate, int frame) {
    ivec2 q = ivec2(fragCoord);
    return rate == 4 ? ((q.x & 1) + 2 * (q.y & 1)) != (frame & 3) : ((q.x + q.y + frame) & 1) == 1;
}

// where ign() should look for a pass that traces 1 in `rate` pixels (rayRest): on just the pixels that trace, the
// plain noise lines up into smooth stripes (neighbours there differ by ~0.1), which showed as wave-like bands in
// soft shadows and light shafts. Counting along that lattice keeps the noise as even as on the full screen; the
// pixels sharing a lattice spot trace on different frames, so they still get different values.
vec2 rayPixel(vec2 fragCoord, int rate) {
    return rate == 4 ? floor(fragCoord * 0.5) : vec2(floor(fragCoord.x * 0.5), floor(fragCoord.y));
}

// per-pixel noise that moves every frame (Jimenez 2014, interleaved gradient noise)
float ign(vec2 pixel, int frame) {
    pixel += 5.588238 * float(frame & 63);
    return fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}

// smooth value noise in 2D (0..1), for puddle shapes
float hash12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float valueNoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + 1.0), f.x), f.y);
}
