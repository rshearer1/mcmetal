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

// per-pixel noise that moves every frame (Jimenez 2014, interleaved gradient noise)
float ign(vec2 pixel, int frame) {
    pixel += 5.588238 * float(frame & 63);
    return fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}
