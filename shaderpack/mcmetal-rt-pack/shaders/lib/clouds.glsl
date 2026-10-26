// A layer of soft clouds high above the world, drawn into our sky (deferred2.fsh). Shapes from layered noise that
// drift with time; thicker parts are darker underneath, edges towards the sun glow (forward scattering). More
// and greyer clouds in rain. The look (lib/style.glsl, STYLE_CLOUD) sets cover, size, softness, brightness and the
// colour of the shaded undersides; Storybook draws them as flat cartoon clouds. With VOLUMETRIC_CLOUDS the same
// shapes get height: a slab of cloud marched through, lit by a short march towards the sun (self-shadowing,
// silver linings, dark bellies). Needs common, uniforms.
#include "/lib/style.glsl"

float cloudDensity(vec2 w) {
    vec2 drift = vec2(frameTimeCounter * 0.6 * CLOUD_SPEED, frameTimeCounter * 0.15 * CLOUD_SPEED);
    w = (w + drift) * 0.0016 / STYLE_CLOUD.y;
    float d = valueNoise(w) * 0.55 + valueNoise(w * 2.03 + 7.1) * 0.27 + valueNoise(w * 4.1 + 3.7) * 0.13
            + valueNoise(w * 8.3 + 1.3) * 0.05;
    float cover = mix(0.56, 0.32, rainStrength) - 0.06 * (CLOUD_AMOUNT - 1.0) - STYLE_CLOUD.x - seasonClouds(seasonWeights()).x;
    return smoothstep(cover, cover + STYLE_CLOUD.z, d);
}

#ifdef VOLUMETRIC_CLOUDS
const float CLOUD_BASE = 230.0, CLOUD_TOP = 420.0;          // world heights of the cloud slab

// how much cloud at a point of the slab: the flat layer's cover gives each cloud its footprint, which is
// tallest where the cover is thickest (rounded tops, flat bases), worn at the edges by finer noise
float cloudVolume(vec3 p, bool fine) {
    float h = (p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE);
    float cov = cloudDensity(p.xz);
    float d = cov - smoothstep(0.05, 1.0, h) * 0.75 - (1.0 - smoothstep(0.0, 0.08, h)) * 0.6;
    if (fine && d > 0.0) {
        vec2 q = (p.xz + vec2(p.y * 0.7, -p.y * 0.4) + frameTimeCounter * 2.0 * CLOUD_SPEED) * 0.012 / STYLE_CLOUD.y;
        d -= (valueNoise(q) * 0.65 + valueNoise(q * 2.7 + 5.3) * 0.35) * 0.22 * (1.0 - 0.5 * h);
    }
    return clamp(d * 3.0, 0.0, 1.0);
}

float cloudPhase(float mu, float g) { return (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * mu, 1.5); }  // Henyey-Greenstein x4pi
#endif

// sky colour behind, view direction, sun/moon direction and light: returns the sky with clouds over it
vec3 drawClouds(vec3 sky, vec3 dir, vec3 lightDir, vec3 sunCol, vec3 skyAmb) {
    if (!hasSkylight) return sky;
#ifdef VOLUMETRIC_CLOUDS
    // where the view ray is inside the slab
    float camY = cameraPosition.y;
    float tb = (CLOUD_BASE - camY) / dir.y, tt = (CLOUD_TOP - camY) / dir.y;
    float t0 = max(min(tb, tt), 0.0), t1 = max(tb, tt);
    if (abs(dir.y) < 1e-4) { t0 = 0.0; t1 = (camY > CLOUD_BASE && camY < CLOUD_TOP) ? 6000.0 : -1.0; }
    t1 = min(t1, t0 + 3000.0);                                // flat rays through a lot of cloud: stop somewhere
    if (t1 <= t0 || t0 > 20000.0) return sky;
    float stepLen = (t1 - t0) / float(CLOUD_STEPS);
    float t = t0 + stepLen * ign(gl_FragCoord.xy, frameCounter); // dithered start (TAA averages it)
    vec3 org = cameraPosition;
    float mu = dot(dir, lightDir);
    float phase = mix(cloudPhase(mu, -0.15), cloudPhase(mu, 0.7), 0.3);  // bright towards the sun (silver lining)
    vec3 shade = sunCol * 0.7 * STYLE_CLOUD.w * seasonClouds(seasonWeights()).y * (1.0 - 0.55 * rainStrength);
    vec3 ambCol = skyAmb * STYLE_CLOUD_SHADE * STYLE_CLOUD.w * seasonClouds(seasonWeights()).y * (1.0 - 0.55 * rainStrength);
    float sigma = 0.035 * (1.0 + rainStrength);               // per block: a 30-block thick cloud is nearly opaque
    float trans = 1.0;
    vec3 light = vec3(0.0);
    vec3 ld = lightDir * (1.0 / max(lightDir.y, 0.2));       // light march: across the slab, not along it
    for (int i = 0; i < CLOUD_STEPS; i++, t += stepLen) {
        vec3 p = org + dir * t;
        float d = cloudVolume(p, true);
        if (d <= 0.0) continue;
        // self-shadow: two samples towards the light (no fine noise: cheaper, softer)
        float od = (cloudVolume(p + ld * 18.0, false) * 18.0 + cloudVolume(p + ld * 60.0, false) * 42.0) * sigma;
        float tl = exp(-od);
  #ifdef STYLE_CLOUD_TOON
        tl = tl > 0.35 ? 1.0 : 0.45;                          // two flat bands: lit and shaded
  #endif
        float powder = 1.0 - exp(-d * 6.0);                   // dark, dense edges facing away from the sun
        float h = clamp((p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE), 0.0, 1.0);
        vec3 ls = shade * (tl * phase * mix(1.0, powder, 0.5) + 0.25 * sqrt(tl)) * mix(STYLE_CLOUD_SHADE, vec3(1.0), tl)
                + ambCol * (0.55 + 0.45 * h);                 // multiple scattering stand-in + sky light, brighter on top
        float s = d * sigma, a = exp(-s * stepLen);
        light += trans * ls * (1.0 - a);                      // energy-conserving step (Hillaire 2015)
        trans *= a;
        if (trans < 0.02) break;
    }
    // far clouds fade into the haze
    float fade = exp(-t0 / 9000.0) * smoothstep(0.0, 0.03, abs(dir.y));
    return mix(sky, sky * trans + light, fade);
#else
    if (dir.y < 0.01) return sky;
    float h = 900.0;                                          // height of the layer above the camera
    vec2 w = cameraPosition.xz + dir.xz / dir.y * h;
    float d = cloudDensity(w);
    if (d < 0.002) return sky;
    // light: less where the cloud is thick towards the light (one sample along the light), plus sky light
    float towards = cloudDensity(w + lightDir.xz / max(lightDir.y, 0.15) * 60.0);
    float mu = dot(dir, lightDir);
    float glow = 1.0 + 2.5 * pow(max(mu, 0.0), 8.0);
    float sunPart = 0.9 - 0.55 * towards;
#ifdef STYLE_CLOUD_TOON
    sunPart = towards > 0.45 ? 0.45 : 0.9;                    // two flat bands: lit and shaded
#endif
    vec3 lit = sunCol * sunPart * glow * 0.7 * mix(STYLE_CLOUD_SHADE, vec3(1.0), sunPart / 0.9)
             + skyAmb * (0.9 - 0.3 * d) * STYLE_CLOUD_SHADE;
    lit *= STYLE_CLOUD.w * seasonClouds(seasonWeights()).y;   // greyer in autumn and winter
#ifdef STYLE_CLOUD_TOON
    lit *= mix(0.55, 1.0, smoothstep(0.0, 0.35, d));          // ink rim at the edge
#endif
    lit *= 1.0 - 0.55 * rainStrength;
    float a = d * smoothstep(0.01, 0.12, dir.y);              // thin out at the horizon
    return mix(sky, lit, a * 0.92);
#endif
}
