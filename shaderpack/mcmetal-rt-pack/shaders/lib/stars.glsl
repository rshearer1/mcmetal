// Our own night sky (STARS): steady stars of different sizes, brightnesses and tints, with the Milky Way's band of
// faint glow and dark dust lanes across it. Fixed to the sky, so they turn with the sun and moon through the night.
// Replaces vanilla's stars (gbuffers_skybasic drops them). Needs common, uniforms, settings.
#ifdef STARS
float hash13(vec3 p) { p = fract(p * 0.1031); p += dot(p, p.zyx + 31.32); return fract((p.x + p.y) * p.z); }
vec3 hash33(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

// view direction (player space) to the sky's own frame: turned back by the time of day about the sun's axis
vec3 celestialDir(vec3 dir) {
    float a = (float(worldTime) / 24000.0) * 6.2831853;
    float r = radians(sunPathRotation);
    vec3 axis = normalize(vec3(0.0, sin(r), cos(r)));       // the sun goes round this (east to west)
    float c = cos(a), s = sin(a);
    return dir * c + cross(axis, dir) * s + axis * dot(axis, dir) * (1.0 - c);
}

vec3 starLayer(vec3 d, float scale, float density) {
    vec3 q = d * scale;
    vec3 cell = floor(q);
    float h = hash13(cell);
    if (h > density) return vec3(0.0);
    vec3 at = cell + 0.2 + 0.6 * hash33(cell + 7.0);
    vec3 sd = normalize(at / scale);
    float ang = acos(clamp(dot(d, sd), -1.0, 1.0)) * scale;  // distance in cells
    float size = 0.06 + 0.1 * fract(h * 91.7);
    float b = exp(-ang * ang / (size * size));
    float mag = pow(fract(h * 37.3), 6.0) * 4.0 + 0.25;      // a few bright ones, many faint
    float temp = fract(h * 13.1);                             // blue-white to orange
    vec3 tint = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.8, 0.6), temp * temp);
    return tint * b * mag;
}

// light to add to the night sky in direction dir; night: 0 by day .. 1 at night
vec3 drawStars(vec3 dir, float night) {
    if (night < 0.01 || dir.y < -0.05) return vec3(0.0);
    vec3 d = celestialDir(dir);
    vec3 galN = normalize(vec3(0.35, 0.25, 0.9));              // the Milky Way's great circle
    float g = dot(d, galN);
    float band = exp(-g * g * 28.0);
    vec3 c = starLayer(d, 140.0, 0.12 + 0.18 * band) + starLayer(d, 260.0, 0.05 + 0.3 * band) * 0.5;
  #ifdef MILKY_WAY
    vec3 w = d * 6.0;
    float glow = valueNoise(w.xy + w.z * 0.7) * 0.5 + valueNoise(w.yz * 2.3 + 3.1) * 0.3 + valueNoise(w.zx * 5.1 + 1.7) * 0.2;
    float dust = smoothstep(0.45, 0.7, valueNoise(w.xz * 3.0 + w.y * 1.3 + 5.0)) * exp(-g * g * 120.0);
    c += mix(vec3(0.55, 0.6, 0.85), vec3(0.85, 0.75, 0.65), glow) * band * glow * (1.0 - 0.8 * dust) * 0.12;
  #endif
    float fade = smoothstep(-0.05, 0.25, dir.y);              // thicker air near the horizon hides them
    return c * fade * night * (1.0 - rainStrength) * 0.12 * STARS_BRIGHTNESS;
}
#endif
