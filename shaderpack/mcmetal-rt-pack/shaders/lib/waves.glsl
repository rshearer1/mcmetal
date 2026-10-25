// Small moving waves on open water: a few travelling sine waves in world space, their slopes tilt the normal.
// Shared by the water itself (lib/gbuffer.glsl) and its reflections (composite.fsh), so both see the same waves.
// w: world position x z. Needs settings, uniforms.
#ifndef WAVES_LIB
#define WAVES_LIB
vec3 waveNormal(vec2 w) {
    float tm = frameTimeCounter * WAVE_SPEED;
    vec2 slope = vec2(0.0);
    const vec2 dirs[4] = vec2[4](vec2(0.8, 0.6), vec2(-0.5, 0.86), vec2(0.97, -0.26), vec2(-0.2, -0.98));
    const float lens[4] = float[4](3.1, 1.7, 0.93, 0.51);
    for (int i = 0; i < 4; i++) {
        float k = 6.2832 / lens[i], ph = dot(dirs[i], w) * k + tm * sqrt(9.8 * k);
        slope += dirs[i] * (cos(ph) * k * lens[i] * 0.012);   // amplitude grows with wavelength
    }
    return normalize(vec3(-slope.x, 1.0, -slope.y) * vec3(WAVE_HEIGHT, 1.0, WAVE_HEIGHT));
}
#endif
