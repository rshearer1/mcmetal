#version 330 compatibility
// Deferred lighting (after deferred.fsh, the ray-traced AO) of everything opaque, plus our sky. Runs after the opaque G-buffer, before water and glass.
/*
const int colortex0Format = RGBA16F;   // albedo in, HDR colour out (water etc. then blend on top in HDR)
const int colortex1Format = RGBA16;    // xy octahedral normal (player space), zw lightmap (block, sky)
const int colortex2Format = RGBA8;     // r material id, g vanilla AO
const bool colortex1Clear = true;
const bool colortex2Clear = true;
const vec4 colortex1ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex2ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"
#ifndef USE_RT
    #include "/lib/shadow.glsl"   // the ray-traced shadow comes from deferred.fsh
#endif

uniform sampler2D colortex0, colortex1, colortex2, colortex3, colortex4, colortex5, depthtex0;

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

vec3 playerFromDepth(vec2 uv, float depth) {
    vec4 v = gbufferProjectionInverse * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    return mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
}

#if defined USE_RT && defined RT_GI
// The averaged GI is still a little grainy: blur it over a 5x5 neighbourhood (every other pixel), but only across
// pixels on the same surface (similar normal and distance), so it doesn't bleed over edges.
vec3 filteredGI(vec3 n, float dist) {
    vec2 px = 2.0 / vec2(viewWidth, viewHeight);
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int y = -2; y <= 2; y++)
        for (int x = -2; x <= 2; x++) {
            vec2 uv = texcoord + vec2(x, y) * px;
            vec3 tn = octDecode(texture(colortex1, uv).xy);
            float td = texture(colortex3, uv).b;
            float w = pow(max(dot(n, tn), 0.0), 16.0) * exp(-abs(td - dist) / (0.02 * dist + 0.05))
                    * exp(-0.15 * float(x * x + y * y));
            sum += texture(colortex4, uv).rgb * w;
            wsum += w;
        }
    return sum / max(wsum, 1e-4);
}
#endif

void main() {
    float depth = texture(depthtex0, texcoord).r;
    vec4 albedo = texture(colortex0, texcoord);
    vec4 m = texture(colortex2, texcoord);
    int mat = int(m.r * 255.0 + 0.5);
    vec3 p = playerFromDepth(texcoord, depth);

    vec3 col;
    if (depth >= 1.0) {
        vec3 dir = normalize(p);
        col = skyColor(dir, sunDir);
        // sun disc with darker edges; the moon and stars come from vanilla's textures (MAT_SKY)
        float cosSun = dot(dir, sunDir), edge = smoothstep(0.99955, 0.99975, cosSun);
        col += lightTransmittance(sunDir) * edge * (60.0 * (0.6 + 0.4 * smoothstep(0.99955, 0.99995, cosSun)));
        if (mat == MAT_SKY) col += toLinear(albedo.rgb) * 0.4 * (1.0 - 0.9 * rainStrength);
    } else if (mat == MAT_LIT) {
        col = albedo.rgb;
    } else {
        vec4 nl = texture(colortex1, texcoord);
        vec3 n = octDecode(nl.xy);
        vec3 a = toLinear(albedo.rgb);
        vec3 sh = vec3(0.0);
#ifdef USE_RT
        sh = mat == MAT_HAND ? vec3(1.0) : texture(colortex5, texcoord).rgb;   // traced and averaged in deferred.fsh
#else
        if (dot(sunCol, sunCol) > 1e-6 && (dot(n, lightDir) > 0.0 || mat == MAT_FOLIAGE))
            sh = sunShadow(p, n, lightDir, mat);
#endif
        float ao = m.g;
#if defined USE_RT && defined RT_AO
        ao = texture(colortex3, texcoord).r * (0.6 + 0.4 * m.g);   // keep a little of the corner shading
#endif
#if defined USE_RT && defined RT_GI
        // GI brings the sky light and the bounced light, so the lightmap's sky guess is left out
        vec3 gi = filteredGI(n, length(p));
        col = a * (surfaceLight(p, n, nl.zw, ao, mat, lightDir, sunCol, vec3(0.0), sh) + gi) + emission(a, mat);
#else
        col = a * surfaceLight(p, n, nl.zw, ao, mat, lightDir, sunCol, skyAmb, sh) + emission(a, mat);
#endif
#if DEBUG_VIEW == 1
        col = sh * max(dot(n, lightDir), 0.0);
#elif DEBUG_VIEW == 2
        col = vec3(ao);
#elif DEBUG_VIEW == 3 && defined USE_RT && defined RT_GI
        col = gi / (gi + 1.0);
#elif DEBUG_VIEW == 4
        col = n * 0.5 + 0.5;
#endif
    }
    outColor = vec4(col, 1.0);
}
