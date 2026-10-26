// GI denoiser (deferred2.fsh, deferred3.fsh): two rounds of an edge-aware a-trous wavelet filter (Dammertz et al.
// 2010, as in SVGF, Schied et al. 2017) over the averaged GI, between the trace (deferred.fsh) and the lighting
// (deferred4.fsh, whose own filter is then the third round and the upscale). Each round is a 3x3 with its taps
// spread further apart (1, then 2 GI pixels), so three cheap rounds reach as far as a 13x13. Taps only count
// where they are on the same surface (normal, distance) and, unlike our old single blur, where their brightness
// is close to this pixel's given how noisy the neighbourhood is: the grain goes, light and shadow edges stay.
// Works at GI resolution (lower-left part of the buffers, like deferred.fsh). Needs common, uniforms.
#if defined USE_RT && defined RT_GI && defined DENOISER
    #define DENOISE_ON
#endif

// HALF_PRECISION: the taps' weights and sums in 16-bit floats (Apple: half the registers, so more pixels in flight,
// and faster maths). Only on mcmetal, which compiles a shader that asks for 16-bit types as GLSL 4.50; distances stay
// 32-bit (a block a few hundred away needs it). Elsewhere these are plain floats.
#if defined HALF_PRECISION && defined MCMETAL_RT
    #extension GL_EXT_shader_explicit_arithmetic_types_float16 : enable
    #define hfloat float16_t
    #define hvec3 f16vec3
#else
    #define hfloat float
    #define hvec3 vec3
#endif

// one tap's weight: same surface (normal, distance) and, against this pixel, a brightness the noise can explain
hfloat tapWeight(float k, vec3 n, vec2 uv, float dist, float distSlope, hfloat lc, hfloat sigmaL, hvec3 s) {
    vec3 tn = octDecode(texture(colortex1, uv).xy);
    float td = texture(colortex3, uv * GI_SCALE).b;
    hfloat facing = hfloat(max(dot(n, tn), 0.0));
    facing *= facing; facing *= facing; facing *= facing; facing *= facing; facing *= facing;   // ^32
    hfloat same = hfloat(exp(-abs(td - dist) / (0.02 * dist * distSlope + 0.05)));
    hfloat lum = dot(s, hvec3(0.2126, 0.7152, 0.0722));
    return hfloat(k) * facing * same * exp(-abs(lum - lc) / sigmaL);
}

// DENOISE_PASSES 1: one wider pass instead of two rounds. The 5x5 below covers the same reach as the two 3x3
// rounds (taps at 1 and 2 GI pixels) in a single render pass, which saves a pass and a full read and write of the
// GI buffer. Apple's guidance: fewer, fatter passes beat more passes over the same pixels.
vec3 denoiseWide(sampler2D src, vec2 tc);

vec3 denoiseRound(sampler2D src, vec2 tc, float stride) {
    vec3 c = texture(src, tc * GI_SCALE).rgb;
#ifdef DENOISE_ON
    float depth = texture(depthtex0, tc).r;
    if (depth >= 1.0) return c;
    vec2 px = 1.0 / (vec2(viewWidth, viewHeight) * GI_SCALE);   // one GI pixel, in full-screen coordinates
    vec4 ad = texture(colortex3, tc * GI_SCALE);                // g frames in the average, b distance
    vec3 n = octDecode(texture(colortex1, tc).xy);
    float lc = luma(c);
    // how noisy the neighbourhood is (3x3 at 1 pixel): the brightness test is loose where it is grainy
    float m1 = 0.0, m2 = 0.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            float l = luma(texture(src, (tc + vec2(x, y) * px) * GI_SCALE).rgb);
            m1 += l; m2 += l * l;
        }
    m1 /= 9.0;
    float sd = sqrt(max(m2 / 9.0 - m1 * m1, 0.0));
    // few frames in the average (just came into view): mostly single rays, lean on space more than brightness
    float sigmaL = 4.0 * sd * mix(3.0, 1.0, smoothstep(2.0, 12.0, ad.g)) + 0.002;
    hvec3 sum = hvec3(c);
    hfloat wsum = hfloat(1.0);
    const float k[3] = float[3](0.25, 0.5, 0.25);
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            vec2 uv = tc + vec2(x, y) * (px * stride);
            hvec3 s = hvec3(texture(src, uv * GI_SCALE).rgb);
            hfloat w = tapWeight(k[x + 1] * k[y + 1] * 4.0, n, uv, ad.b, stride, hfloat(lc), hfloat(sigmaL), s);
            sum += s * w;
            wsum += w;
        }
    c = vec3(sum / wsum);
#endif
    return c;
}

// one pass: a 5x5 with the same weights, taps 1 and 2 GI pixels out (the two rounds' reach in one go)
vec3 denoiseWide(sampler2D src, vec2 tc) {
    vec3 c = texture(src, tc * GI_SCALE).rgb;
#ifdef DENOISE_ON
    float depth = texture(depthtex0, tc).r;
    if (depth >= 1.0) return c;
    vec2 px = 1.0 / (vec2(viewWidth, viewHeight) * GI_SCALE);
    vec4 ad = texture(colortex3, tc * GI_SCALE);
    vec3 n = octDecode(texture(colortex1, tc).xy);
    float lc = luma(c);
    float m1 = 0.0, m2 = 0.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            float l = luma(texture(src, (tc + vec2(x, y) * px) * GI_SCALE).rgb);
            m1 += l; m2 += l * l;
        }
    m1 /= 9.0;
    float sd = sqrt(max(m2 / 9.0 - m1 * m1, 0.0));
    float sigmaL = 4.0 * sd * mix(3.0, 1.0, smoothstep(2.0, 12.0, ad.g)) + 0.002;
    hvec3 sum = hvec3(c);
    hfloat wsum = hfloat(1.0);
    const float k[5] = float[5](0.0625, 0.25, 0.375, 0.25, 0.0625);   // the two rounds' kernels, convolved
    for (int y = -2; y <= 2; y++)
        for (int x = -2; x <= 2; x++) {
            if (x == 0 && y == 0) continue;
            vec2 uv = tc + vec2(x, y) * px;
            hvec3 s = hvec3(texture(src, uv * GI_SCALE).rgb);
            float reach = max(abs(float(x)), abs(float(y)));           // the far taps judge distance more loosely
            hfloat w = tapWeight(k[x + 2] * k[y + 2] * 16.0, n, uv, ad.b, reach, hfloat(lc), hfloat(sigmaL), s);
            sum += s * w;
            wsum += w;
        }
    c = vec3(sum / wsum);
#endif
    return c;
}
