// Our sky: single-scattering atmosphere (Nishita et al. 1993) with Rayleigh and Mie scattering, written from the
// paper's equations. Directions are in player space (y up). Needs common.glsl.
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
    float len = raySphere(ro, dir, R_ATMOS).y, seg = len / 8.0;
    float mu = dot(dir, lightDir), g2 = MIE_G * MIE_G;
    float phR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    float phM = 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + mu * mu)) / ((2.0 + g2) * pow(1.0 + g2 - 2.0 * MIE_G * mu, 1.5));
    vec2 od = vec2(0.0);
    vec3 sumR = vec3(0.0), sumM = vec3(0.0);
    for (int i = 0; i < 8; i++) {
        vec3 p = ro + dir * (seg * (float(i) + 0.5));
        vec2 d = exp(-(length(p) - R_EARTH) / vec2(H_RAY, H_MIE)) * seg;
        od += d;
        vec3 t = transmittance(od + opticalDepthTowards(p, lightDir, 3));
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
vec3 skyColor(vec3 dir, vec3 sunDir) {
    vec3 c = atmosphere(dir, sunDir, SUN_INTENSITY);
    c += atmosphere(dir, -sunDir, MOON_INTENSITY) + vec3(0.0006, 0.0009, 0.0018);
    return c * PI;
}
