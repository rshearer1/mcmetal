// AURORA: northern lights hanging at a real height over the world (AURORA_HEIGHT blocks up, 150 tall), so they
// stay put as you walk, grow as you climb and can be flown through with an elytra. The view ray is stepped
// through that slab; at each step the curtains are thin folds where a slow noise field crosses one value, with
// fine vertical rays through them. Green-teal at the foot, violet towards the top. Needs common, uniforms, settings.
#ifdef AURORA
float auroraCurtain(vec2 xz, float tt) {
    vec2 q = xz / (220.0 * AURORA_SCALE);
    float f = valueNoise(q + vec2(tt, -0.6 * tt)) * 0.65 + valueNoise(q * 2.3 - vec2(0.4 * tt, tt)) * 0.35;
    float fold = (f - 0.5) / 0.035;
    return exp(-fold * fold);
}

vec3 drawAurora(vec3 dir, float night) {
    if (night < 0.01) return vec3(0.0);
    float bottom = AURORA_HEIGHT, top = AURORA_HEIGHT + 150.0;
    float y0 = cameraPosition.y;
    // where the view ray is inside the slab (from below, from above, or starting inside it when flying through)
    float dy = abs(dir.y) < 1e-3 ? 1e-3 : dir.y;
    float tA = (bottom - y0) / dy, tB = (top - y0) / dy;
    float t0 = max(min(tA, tB), 0.0), t1 = max(tA, tB);
    if (t1 <= 0.0) return vec3(0.0);
    t1 = min(t1, t0 + 2500.0);                         // glancing rays: the far part is too thin to see anyway
    const int STEPS = 16;
    float stepLen = (t1 - t0) / float(STEPS);
    float jitter = ign(gl_FragCoord.xy, frameCounter);
    float tt = frameTimeCounter * 0.004 * AURORA_SPEED;
    vec3 c = vec3(0.0);
    for (int i = 0; i < STEPS; i++) {
        vec3 p = cameraPosition + dir * (t0 + (float(i) + jitter) * stepLen);
        float h = clamp((p.y - bottom) / (top - bottom), 0.0, 1.0);
        float curtain = auroraCurtain(p.xz, tt);
        if (curtain < 0.01) continue;
        float rays = 0.55 + 0.45 * valueNoise(vec2(dot(p.xz, vec2(0.7, 0.71)) * 0.35, tt * 30.0));
        float profile = smoothstep(0.0, 0.06, h) * exp(-h * 3.2);   // a sharp bright foot, fading upwards
        vec3 tint = mix(vec3(0.10, 1.00, 0.55), vec3(0.65, 0.25, 1.00), smoothstep(0.15, 0.8, h));
        c += tint * curtain * rays * profile * stepLen;
    }
    return c * night * 0.0006 * AURORA_BRIGHTNESS;
}
#endif
