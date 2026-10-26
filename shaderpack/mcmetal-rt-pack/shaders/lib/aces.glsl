// ACES filmic tonemap, Stephen Hill's fit of the ACES RRT + sRGB ODT (BakingLab, MIT licence).
// Matrices are written row by row; v * M below is M (rows) times v.
const mat3 ACES_IN = mat3(0.59719, 0.35458, 0.04823,
                          0.07600, 0.90834, 0.01566,
                          0.02840, 0.13383, 0.83777);
const mat3 ACES_OUT = mat3( 1.60475, -0.53108, -0.07367,
                           -0.10208,  1.10813, -0.00605,
                           -0.00327, -0.07276,  1.07602);

vec3 rrtOdtFit(vec3 v) {
    vec3 a = v * (v + 0.0245786) - 0.000090537;
    vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

vec3 acesFitted(vec3 c) {
    c = c * ACES_IN;
    c = rrtOdtFit(c);
    c = c * ACES_OUT;
    return clamp(c, 0.0, 1.0);
}

// Our own soft filmic curve (TONEMAP 1), in the spirit of AgX: a smooth S-curve on log exposure, so very bright
// colours roll off towards white without the hue shifts and harsh orange skies of a per-channel curve. A little
// desaturation going in (bright lights don't clip to pure primaries), the colour given back coming out.
vec3 softFilmic(vec3 c) {
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    c = max(mix(vec3(l), c, 0.85), 1e-6);
    vec3 x = clamp((log2(c) + 12.47) / 16.5, 0.0, 1.0);          // about 12.5 stops below to 4 above mid grey
    const float k = 10.0, m = 0.622;                              // mid grey (0.18) comes out at 0.18
    float s0 = 1.0 / (1.0 + exp(k * m)), s1 = 1.0 / (1.0 + exp(-k * (1.0 - m)));
    vec3 s = (1.0 / (1.0 + exp(-k * (x - m))) - s0) / (s1 - s0);
    vec3 y = pow(s, vec3(2.2));
    float ly = dot(y, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(ly), y, 1.15), 0.0, 1.0);
}
