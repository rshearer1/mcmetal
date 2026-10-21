// A layer of soft clouds high above the world, drawn into our sky (deferred2.fsh). Shapes from layered noise that
// drift with time; thicker parts are darker underneath, edges towards the sun glow (forward scattering). More
// and greyer clouds in rain. Needs common, uniforms.

float cloudDensity(vec2 w) {
    vec2 drift = vec2(frameTimeCounter * 0.6 * CLOUD_SPEED, frameTimeCounter * 0.15 * CLOUD_SPEED);
    w = (w + drift) * 0.0016;
    float d = valueNoise(w) * 0.55 + valueNoise(w * 2.03 + 7.1) * 0.27 + valueNoise(w * 4.1 + 3.7) * 0.13
            + valueNoise(w * 8.3 + 1.3) * 0.05;
    float cover = mix(0.56, 0.32, rainStrength) - 0.06 * (CLOUD_AMOUNT - 1.0);
    return smoothstep(cover, cover + 0.18, d);
}

// sky colour behind, view direction, sun/moon direction and light: returns the sky with clouds over it
vec3 drawClouds(vec3 sky, vec3 dir, vec3 lightDir, vec3 sunCol, vec3 skyAmb) {
    if (dir.y < 0.01) return sky;
    float h = 900.0;                                          // height of the layer above the camera
    vec2 w = cameraPosition.xz + dir.xz / dir.y * h;
    float d = cloudDensity(w);
    if (d < 0.002) return sky;
    // light: less where the cloud is thick towards the light (one sample along the light), plus sky light
    float towards = cloudDensity(w + lightDir.xz / max(lightDir.y, 0.15) * 60.0);
    float mu = dot(dir, lightDir);
    float glow = 1.0 + 2.5 * pow(max(mu, 0.0), 8.0);
    vec3 lit = sunCol * (0.9 - 0.55 * towards) * glow * 0.7 + skyAmb * (0.9 - 0.3 * d);
    lit *= 1.0 - 0.55 * rainStrength;
    float a = d * smoothstep(0.01, 0.12, dir.y);              // thin out at the horizon
    return mix(sky, lit, a * 0.92);
}
