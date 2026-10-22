// Caustics: waves focus sunlight into a moving net of bright lines under water. The lines are the ridges of two
// layers of drifting, warped value noise (where the noise crosses its middle value). The pattern is projected along
// the sun's direction, so it's the same all the way down a sun ray: on the floor that's the net of lines, in the
// water itself (deferred3.fsh) it makes the shafts. Needs common (valueNoise). Returns 0..1, about 0.2 on average.
float caustics(vec3 w, vec3 sunDir, float t) {
    vec2 uv = w.xz - sunDir.xz * w.y / max(sunDir.y, 0.2);
    float c = 0.0;
    for (int i = 0; i < 2; i++) {
        float s = i == 0 ? 0.55 : 1.1;
        vec2 q = uv * s + vec2(0.3, -0.21) * t * float(i + 1);
        q += (vec2(valueNoise(q * 0.8 + t * 0.2), valueNoise(q * 0.8 + 7.1 - t * 0.17)) - 0.5) * 1.6;
        float r = 1.0 - abs(valueNoise(q * 1.3) * 2.0 - 1.0);
        c += r * r * r * r * (i == 0 ? 0.65 : 0.35);
    }
    return c;
}
