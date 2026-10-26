#version 330 compatibility
// ACES filmic grading and the chosen look (lib/style.glsl), then to the screen's sRGB.
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/aces.glsl"
#include "/lib/style.glsl"

uniform sampler2D colortex0, colortex6, depthtex0;

in vec2 texcoord;

layout(location = 0) out vec4 outColor;

#ifdef BLOOM
// soft glow around bright things (the sun, lights, lava, glowing texels), as SEUS and Bedrock RTX have: the picture
// blurred at five widths, from colortex0's mip levels (composite3 has them made for metering). Each level takes 4
// taps half a texel apart, so with filtering every level is a smooth tent instead of blocky squares.
vec3 bloom(vec2 uv) {
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 5; i++) {
        float lod = float(i + 2);
        vec2 t = exp2(lod) * 0.5 / vec2(viewWidth, viewHeight);
        vec3 c = textureLod(colortex0, uv + vec2(t.x, t.y), lod).rgb + textureLod(colortex0, uv + vec2(-t.x, t.y), lod).rgb
               + textureLod(colortex0, uv + vec2(t.x, -t.y), lod).rgb + textureLod(colortex0, uv - t, lod).rgb;
        float w = 1.0 + 0.5 * float(i);   // the wide levels a little stronger: a broad, soft halo
        sum += c * (0.25 * w);
        wsum += w;
    }
    return sum / wsum;
}
#endif

#ifdef LENS_FLARE
// a camera's lens flare, as SEUS has (off by default): soft coloured ghosts on the line from the sun through the
// middle of the screen and a faint ring round it, only while the sun itself is in view and not hidden by anything
vec3 lensFlare(vec2 uv) {
    vec4 sc = gbufferProjection * vec4(sunPosition, 1.0);
    if (sc.w <= 0.0 || dot(normalize(sunPosition), normalize(upPosition)) < 0.0) return vec3(0.0);
    vec2 sp = sc.xy / sc.w * 0.5 + 0.5;
    if (any(lessThan(sp, vec2(-0.2))) || any(greaterThan(sp, vec2(1.2)))) return vec3(0.0);
    float vis = 0.0;   // how much of the sun is open sky (5 taps round its centre)
    vec2 px = 6.0 / vec2(viewWidth, viewHeight);
    for (int i = 0; i < 5; i++) {
        vec2 o = i == 0 ? vec2(0.0) : vec2(i == 1 ? 1.0 : i == 2 ? -1.0 : 0.0, i == 3 ? 1.0 : i == 4 ? -1.0 : 0.0);
        vec2 q = sp + o * px;
        vis += (all(greaterThan(q, vec2(0.0))) && all(lessThan(q, vec2(1.0))) && texture(depthtex0, q).r >= 1.0) ? 0.2 : 0.0;
    }
    if (vis <= 0.0) return vec3(0.0);
    float aspect = viewWidth / viewHeight;
    vec2 axis = vec2(0.5) - sp;
    vec3 f = vec3(0.0);
    const vec4 ghosts[4] = vec4[4](vec4(0.35, 0.05, 0.9, 0.7), vec4(0.7, 0.03, 0.5, 1.0), vec4(1.15, 0.07, 1.0, 0.6), vec4(1.6, 0.12, 0.6, 0.9));
    const vec3 tints[4] = vec3[4](vec3(1.0, 0.75, 0.45), vec3(0.5, 0.9, 1.0), vec3(1.0, 0.55, 0.8), vec3(0.6, 1.0, 0.6));
    for (int i = 0; i < 4; i++) {
        vec2 g = sp + axis * ghosts[i].x;
        vec2 d = (uv - g) * vec2(aspect, 1.0);
        float r = length(d) / ghosts[i].y;
        f += tints[i] * smoothstep(1.0, 0.6, r) * (0.4 + 0.6 * r) * ghosts[i].z * 0.05;   // brighter towards the rim
    }
    float ring = length((uv - sp) * vec2(aspect, 1.0));
    f += vec3(0.9, 0.8, 1.0) * exp(-pow((ring - 0.25) / 0.012, 2.0)) * 0.03;
    float edge = 1.0 - smoothstep(0.35, 0.75, length(sp - 0.5));   // fades as the sun nears the edge of view
    return f * vis * edge * (1.0 - rainStrength) * LENS_FLARE_STRENGTH;
}
#endif

void main() {
    float exposure = texelFetch(colortex6, ivec2(0), 0).r * EXPOSURE;   // from composite3
    vec3 col = texture(colortex0, texcoord).rgb * exposure;
#ifdef STYLE_PAINT
    // painted finish (Kuwahara): of the four 3x3 corners around the pixel, take the average of the calmest one, so
    // flat areas become soft dabs of colour while edges stay sharp
    {
        vec2 px = 1.5 / vec2(viewWidth, viewHeight);
        float best = 1e9;
        for (int q = 0; q < 4; q++) {
            vec2 dir = vec2(q == 1 || q == 3 ? 1.0 : -1.0, q >= 2 ? 1.0 : -1.0);
            vec3 m = vec3(0.0); float s1 = 0.0, s2 = 0.0;
            for (int j = 0; j < 3; j++) for (int i = 0; i < 3; i++) {
                vec3 t = texture(colortex0, texcoord + vec2(i, j) * dir * px).rgb;
                float l = luma(t);
                m += t; s1 += l; s2 += l * l;
            }
            float var = s2 / 9.0 - (s1 / 9.0) * (s1 / 9.0);
            if (var < best) { best = var; col = m / 9.0 * exposure; }
        }
    }
#endif
#if DEBUG_VIEW > 0
    outColor = vec4(texture(colortex0, texcoord).rgb, 1.0);   // debug views: raw values, no grading
    return;
#endif
#if STYLE > 0
    // glow: a ring of taps around the pixel at two radii, only the part above about mid-grey
    vec3 glow = vec3(0.0);
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.7854 + 0.39;
        vec2 d = vec2(cos(a), sin(a)) * px;
        glow += max(texture(colortex0, texcoord + d * 6.0).rgb * exposure - 0.6, 0.0);
        glow += max(texture(colortex0, texcoord + d * 18.0).rgb * exposure - 0.6, 0.0) * 0.6;
    }
    col += glow * (STYLE_GLOW / 8.0);
#endif
#ifdef BLOOM
    // a small share of the blurred picture: bright things spill light around them, dark ones barely change
    col = mix(col, bloom(texcoord) * exposure, 0.04 * BLOOM_STRENGTH);
#endif
#ifdef LENS_FLARE
    col += lensFlare(texcoord);
#endif
    col = acesFitted(col);
    col = styleGrade(col, texcoord);
#ifdef STYLE_POSTER
    if (texture(depthtex0, texcoord).r < 1.0) {   // flat poster colour on the world (the sky stays smooth)
        float l = luma(col);
        float b = l * 6.0;
        float q = (floor(b) + smoothstep(0.35, 0.65, fract(b))) / 6.0;
        col = mix(col, col * (q / max(l, 1e-3)), 0.6);
    }
#endif
#ifdef STYLE_SPARKLE
    {   // twinkles: a few bright surface pixels flash for a moment (leaves, water, snow in the sun)
        vec2 cell = floor(gl_FragCoord.xy / 3.0);
        float h = fract(sin(dot(cell, vec2(12.9898, 78.233)) + floor(frameTimeCounter * 3.0) * 7.31) * 43758.5453);
        col += vec3(1.0, 0.92, 1.0) * step(0.996, h) * smoothstep(0.45, 0.8, luma(col)) * 0.8;
    }
#endif
    col = mix(vec3(luma(col)), col, SATURATION);
    col = clamp((col - 0.18) * CONTRAST + 0.18, 0.0, 1.0);
    col = toSRGB(col);
    col += (ign(gl_FragCoord.xy, frameCounter) - 0.5) / 255.0;   // dither: no banding in dark skies
    outColor = vec4(col, 1.0);
}
