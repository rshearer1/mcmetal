// Our sky: single-scattering atmosphere (Nishita et al. 1993) with Rayleigh and Mie scattering, written from the
// paper's equations. Directions are in player space (y up). Needs common.glsl.
// The full model runs once a frame, into a small table (prepare.fsh, colortex12); everything else looks it up.
#ifndef SKY_LIB
#define SKY_LIB
#include "/lib/style.glsl"
const float R_EARTH = 6360e3, R_ATMOS = 6420e3, H_RAY = 8000.0, H_MIE = 1200.0, MIE_G = 0.76;
const vec3 BETA_RAY = vec3(5.8e-6, 13.5e-6, 33.1e-6);
const float BETA_MIE = 21e-6;
const float SUN_INTENSITY = 20.0, MOON_INTENSITY = 0.05;

vec2 raySphere(vec3 ro, vec3 rd, float r) {
    float b = dot(ro, rd), c = dot(ro, ro) - r * r, d = b * b - c;
    if (d < 0.0) return vec2(-1.0);
    d = sqrt(d);
    return vec2(-b - d, -b + d);
}

vec2 opticalDepthTowards(vec3 p, vec3 dir, int steps) {   // Rayleigh, Mie densities integrated to the top
    float len = raySphere(p, dir, R_ATMOS).y, seg = len / float(steps);
    vec2 od = vec2(0.0);
    for (int j = 0; j < steps; j++) {
        float h = length(p + dir * (seg * (float(j) + 0.5))) - R_EARTH;
        od += exp(-max(h, 0.0) / vec2(H_RAY, H_MIE)) * seg;
    }
    return od;
}

vec3 transmittance(vec2 od) { return exp(-(BETA_RAY * od.x + BETA_MIE * 1.1 * od.y)); }

// light scattered towards the eye along dir, lit from lightDir
vec3 atmosphere(vec3 dir, vec3 lightDir, float intensity) {
    // below the horizon there's terrain; keep the horizon colour there. Not quite at the horizon: through ~100 km
    // of air the Mie haze turns olive, which showed as a brown band past the loaded world (and over DH's far LODs)
    dir.y = max(dir.y, 0.0) * 0.94 + 0.06;
    dir = normalize(dir);
    vec3 ro = vec3(0.0, R_EARTH + 100.0, 0.0);
    float len = raySphere(ro, dir, R_ATMOS).y;
    float mu = dot(dir, lightDir), g2 = MIE_G * MIE_G;
    float phR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    float phM = 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + mu * mu)) / ((2.0 + g2) * pow(1.0 + g2 - 2.0 * MIE_G * mu, 1.5));
    vec2 od = vec2(0.0);
    vec3 sumR = vec3(0.0), sumM = vec3(0.0);
    // samples packed towards the eye (spacing grows as i^2), where the air is dense: 8 even steps along a near-
    // horizontal view skip most of the low air and turned the horizon olive; this matches 128 even steps closely
    for (int i = 0; i < 8; i++) {
        float a = float(i) / 8.0, b = float(i + 1) / 8.0;
        float seg = (b * b - a * a) * len;
        vec3 p = ro + dir * (0.5 * (a * a + b * b) * len);
        vec2 d = exp(-(length(p) - R_EARTH) / vec2(H_RAY, H_MIE)) * seg;
        od += d;
        vec3 t = transmittance(od - 0.5 * d + opticalDepthTowards(p, lightDir, 3));   // (to the middle of the step)
        // light below the horizon: fade instead of a hard cut (the earth shadows the air)
        t *= smoothstep(-0.12, 0.02, dot(normalize(p), lightDir));
        sumR += t * d.x;
        sumM += t * d.y;
    }
    return intensity * (sumR * BETA_RAY * phR + sumM * BETA_MIE * phM);
}

// colour of direct sun/moon light at the ground
vec3 lightTransmittance(vec3 lightDir) {
    vec3 ro = vec3(0.0, R_EARTH + 100.0, 0.0);
    vec3 d = normalize(vec3(lightDir.x, max(lightDir.y, 0.03), lightDir.z));
    return transmittance(opticalDepthTowards(ro, d, 6)) * smoothstep(-0.05, 0.06, lightDir.y);
}

// full sky (sun + moon lit air, a little airglow at night), no discs. Times pi: our surfaces skip Lambert's 1/pi,
// so the sky is scaled the same way to keep sky and ground in the right balance.
vec3 skyColorExact(vec3 dir, vec3 sunDir) {
    vec3 c = atmosphere(dir, sunDir, SUN_INTENSITY);
    c += atmosphere(dir, -sunDir, MOON_INTENSITY) + vec3(0.0006, 0.0009, 0.0018);
    return stylePaintSky(c * PI, dir, sunDir);   // the chosen look's sky colours (lib/style.glsl)
}

// The sky table (colortex12, 128x64, shaders.properties size.buffer): the sky only depends on how high a direction
// looks and how far round from the sun it is (the air is the same all round), so one frame's sky fits in a small
// table: columns 0..127 the angle from the sun (0..180 degrees), rows 0..62 the elevation (its square root: more
// rows near the horizon, where the colour changes fastest; below the horizon the sky model keeps the horizon
// colour). Against the full model: under 0.7% off anywhere, 0.02% typical (checked offline for six sun heights). Row 63
// holds the frame's light colours (lighting.glsl). The full model above is hundreds of operations a call, and ran per
// sky and fog pixel, per water, glass and particle vertex and per reflection; a lookup is one filtered read.
const float SKY_LUT_W = 128.0, SKY_LUT_H = 64.0, SKY_LUT_ROWS = 63.0;
vec2 skyLutAngles(vec3 dir, vec3 sunDir) {   // (angle from the sun round the horizon / pi, sqrt(elevation / 90)), 0..1
    vec2 s = normalize(sunDir.xz + 1e-4), d = normalize(dir.xz + 1e-4);
    return vec2(acos(clamp(dot(s, d), -1.0, 1.0)) / PI, sqrt(asin(clamp(dir.y, 0.0, 1.0)) / (PI * 0.5)));
}
vec3 skyLutDirection(vec2 a, vec3 sunDir) {   // the inverse, for the table's texels
    vec2 s = normalize(sunDir.xz + 1e-4);
    float el = a.y * a.y * (PI * 0.5), ang = a.x * PI;
    vec2 xz = (s * cos(ang) + vec2(-s.y, s.x) * sin(ang)) * cos(el);
    return vec3(xz.x, sin(el), xz.y);
}
#ifndef SKY_LUT_BUILD
uniform sampler2D colortex12;
vec3 skyColor(vec3 dir, vec3 sunDir) {
    vec2 a = skyLutAngles(dir, sunDir);
    return textureLod(colortex12, (a * vec2(SKY_LUT_W - 1.0, SKY_LUT_ROWS - 1.0) + 0.5) / vec2(SKY_LUT_W, SKY_LUT_H), 0.0).rgb;
}
// colour of the direct sun light at the ground, this frame (row 63, texel 2)
vec3 sunTransmittance() { return texelFetch(colortex12, ivec2(2, 63), 0).rgb; }
#endif
#endif
