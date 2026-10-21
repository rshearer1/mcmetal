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
