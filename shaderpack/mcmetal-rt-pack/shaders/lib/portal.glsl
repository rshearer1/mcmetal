// End portals and gateways (END_PORTAL_STARS): a deep starfield inside the frame instead of vanilla's flat layers.
// Six layers of stars sit at different depths behind the surface, so they slide past each other as you move
// (parallax), each drifting slowly in its own direction, in the portal's teal, green and violet. Glows by itself
// (deferred keeps the colour: MAT_LIT). Needs common, uniforms, settings.
#ifdef END_PORTAL_STARS
vec3 endPortalStars(vec3 pp, vec3 n) {
    vec3 v = normalize(pp);
    vec3 wp = pp + cameraPosition;
    vec3 t = normalize(abs(n.y) > 0.9 ? vec3(1.0, 0.0, 0.0) : cross(vec3(0.0, 1.0, 0.0), n));
    vec3 b = cross(n, t);
    float into = max(-dot(v, n), 0.08);   // how straight we look in: glancing views see the layers spread out
    vec3 col = vec3(0.004, 0.012, 0.02);  // the void between the stars
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        vec3 q = wp + v * ((0.4 + fi * 1.6) / into);
        vec2 drift = vec2(sin(fi * 2.4), cos(fi * 2.4)) * frameTimeCounter * (0.03 + 0.015 * fi);
        vec2 uv = vec2(dot(q, t), dot(q, b)) * (5.0 - 0.5 * fi) + drift;
        vec2 cell = floor(uv);
        float h = hash12(cell + fi * 17.3);
        if (h > 0.4) continue;
        vec2 at = cell + 0.2 + 0.6 * vec2(hash12(cell + 3.1 + fi), hash12(cell + 7.7 - fi));
        float d = length(uv - at);
        float size = 0.05 + 0.08 * fract(h * 53.1);
        float star = exp(-d * d / (size * size)) * (0.6 + 1.6 * fract(h * 91.7));
        vec3 tint = mix(vec3(0.25, 0.95, 0.8), vec3(0.55, 0.4, 1.0), fract(h * 29.3 + fi * 0.37));
        col += tint * star * (1.0 - fi / 7.0);
    }
    return col * 2.0 * END_PORTAL_BRIGHTNESS;
}
#endif
