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
