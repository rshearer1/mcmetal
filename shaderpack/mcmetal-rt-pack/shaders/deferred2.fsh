#version 330 compatibility
// Deferred lighting (after deferred.fsh: GI + AO, deferred1.fsh: sun shadows) of everything opaque, plus our sky. Runs after the opaque G-buffer, before water and glass.
/*
const int colortex0Format = RGBA16F;   // albedo in, HDR colour out (water etc. then blend on top in HDR)
const int colortex1Format = RGBA16;    // xy octahedral normal (player space), zw lightmap (block, sky)
const int colortex2Format = RGBA8;     // r material id, g vanilla AO
const bool colortex1Clear = true;
const bool colortex2Clear = true;
const vec4 colortex1ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex2ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const int colortex12Format = RGBA16F;   // lit opaque scene + distance, read by glass for refraction
const bool colortex12Clear = false;
const int colortex10Format = RGBA16;   // xy normal with the normal map, z smoothness, w F0/metal (LabPBR)
const bool colortex10Clear = true;
const vec4 colortex10ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"
#ifdef CLOUDS
    #include "/lib/clouds.glsl"
#endif
#if !defined USE_RT || defined RT_REFLECTIONS
    // (the ray-traced shadow comes from deferred1.fsh; with RT this is only for what reflections see)
    #include "/lib/shadow.glsl"
#endif
#if defined USE_RT && defined RT_REFLECTIONS
    // reflections on puddles and on smooth LabPBR surfaces
    #define SURFACE_RT
    #include "/lib/reflect.glsl"
#endif

uniform sampler2D colortex0, colortex1, colortex2, colortex3, colortex4, colortex5, colortex10, depthtex0;

#ifdef DISTANT_HORIZONS
uniform sampler2D dhDepthTex0;
uniform mat4 dhProjectionInverse;
#endif

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

/* RENDERTARGETS: 0,12 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outBehind;   // colortex12: the lit scene before glass and water, a distance (refraction)

vec3 playerFromDepth(vec2 uv, float depth) {
    vec4 v = gbufferProjectionInverse * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    return mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
}

#if defined USE_RT && defined RT_GI
// The averaged GI is still a little grainy: blur it over a 5x5 neighbourhood (every other pixel), but only across
// pixels on the same surface (similar normal and distance), so it doesn't bleed over edges.
// At half resolution this is also the upscale: the low-resolution GI pixels around this one are weighted by
// how well their surface matches this full-resolution pixel.
vec3 filteredGI(vec3 n, float dist) {
    vec2 px = (GI_SCALE < 1.0 ? 1.0 : 2.0) / (vec2(viewWidth, viewHeight) * GI_SCALE);   // in GI pixels
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int y = -2; y <= 2; y++)
        for (int x = -2; x <= 2; x++) {
            vec2 uv = texcoord + vec2(x, y) * px;              // full-screen position of that GI pixel
            vec3 tn = octDecode(texture(colortex1, uv).xy);
            float td = texture(colortex3, uv * GI_SCALE).b;
            float w = pow(max(dot(n, tn), 0.0), 16.0) * exp(-abs(td - dist) / (0.02 * dist + 0.05))
                    * exp(-0.15 * float(x * x + y * y));
            sum += texture(colortex4, uv * GI_SCALE).rgb * w;
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
#ifdef DISTANT_HORIZONS
    if (depth >= 1.0 && mat == MAT_DH) {
        // far LOD terrain: lit from its lightmap (sun where the sky is open), no rays
        vec4 v = dhProjectionInverse * vec4(vec3(texcoord, texture(dhDepthTex0, texcoord).r) * 2.0 - 1.0, 1.0);
        p = mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
        vec4 nl = texture(colortex1, texcoord);
        vec3 a = toLinear(albedo.rgb);
        // (sky light x1.3: stands in for the bounce light the real chunks get from the GI, so the seam doesn't show)
        col = a * surfaceLight(p, octDecode(nl.xy), nl.zw, 1.0, MAT_NONE, lightDir, sunCol, skyAmb * 1.3,
                               vec3(smoothstep(0.85, 0.97, nl.w))) + a * m.a * (4.0 * EMISSIVE_STRENGTH);
    } else
#endif
    if (depth >= 1.0) {
        vec3 dir = normalize(p);
        col = skyColor(dir, sunDir);
        // sun disc with darker edges; the moon and stars come from vanilla's textures (MAT_SKY)
        float cosSun = dot(dir, sunDir), edge = smoothstep(0.99955, 0.99975, cosSun);
        col += lightTransmittance(sunDir) * edge * (60.0 * (0.6 + 0.4 * smoothstep(0.99955, 0.99995, cosSun)));
        if (mat == MAT_SKY) col += toLinear(albedo.rgb) * 0.4 * (1.0 - 0.9 * rainStrength);
  #ifdef CLOUDS
        col = drawClouds(col, dir, lightDir, sunCol, skyAmb);
  #endif
    } else if (mat == MAT_LIT) {
        col = albedo.rgb;
    } else {
        vec4 nl = texture(colortex1, texcoord);
        vec3 n = octDecode(nl.xy);
        vec3 a = toLinear(albedo.rgb);
        // LabPBR (colortex10): the normal-mapped normal lights the surface; the block's own normal stays for rays
        vec4 pbr = texture(colortex10, texcoord);
        vec3 nm = dot(pbr.xy, pbr.xy) > 0.0 ? octDecode(pbr.xy) : n;
        float smoothness = pbr.z;
        bool metal = pbr.w > 229.5 / 255.0;
        vec3 f0 = metal ? a : vec3(max(pbr.w, 0.02));
        vec3 sh = vec3(0.0);
#ifdef USE_RT
        sh = mat == MAT_HAND ? vec3(1.0) : texture(colortex5, texcoord).rgb;   // traced and averaged in deferred1.fsh
#else
        if (dot(sunCol, sunCol) > 1e-6 && (dot(n, lightDir) > 0.0 || mat == MAT_FOLIAGE))
            sh = sunShadow(p, n, lightDir, mat);
#endif
        float ao = m.g;
#if defined USE_RT && defined RT_AO
        ao = texture(colortex3, texcoord * GI_SCALE).r * (0.6 + 0.4 * m.g);   // keep a little of the corner shading
#endif
#if defined USE_RT && defined RT_GI
        // GI brings the sky light and the bounced light, so the lightmap's sky guess is left out
        // the held item isn't in the ray scene's history: it gets the plain sky light instead
        vec3 gi = mat == MAT_HAND ? skyAmb * (nl.w * nl.w) * (0.7 + 0.3 * n.y) : filteredGI(n, length(p));
  #ifdef USE_LIGHTS
        // coloured block light (in the GI, deferred.fsh) replaces the lightmap's block light; the held light stays
        col = a * (surfaceLight(p, nm, vec2(mat == MAT_HAND ? nl.z : 0.0, nl.w), ao, mat, lightDir, sunCol, vec3(0.0), sh) + gi)
            + emission(a, mat);
  #else
        col = a * (surfaceLight(p, nm, nl.zw, ao, mat, lightDir, sunCol, vec3(0.0), sh) + gi) + emission(a, mat);
  #endif
#else
        col = a * surfaceLight(p, nm, nl.zw, ao, mat, lightDir, sunCol, skyAmb, sh) + emission(a, mat);
#endif
        // metals have no diffuse light of their own: their colour is in what they reflect
        if (metal) col = emission(a, mat) + (col - emission(a, mat)) * 0.08;
        // LabPBR emission (specular map alpha)
        col += a * m.a * (4.0 * EMISSIVE_STRENGTH);
#ifdef LABPBR
        // shiny surfaces: the sun's highlight (GGX), and ray-traced reflections where smooth enough
        if ((smoothness > 0.01 || metal) && m.b < 0.01 && mat != MAT_HAND) {
            vec3 v = normalize(p);
            float alpha = max((1.0 - smoothness) * (1.0 - smoothness), 0.003);
            float nv = clamp(dot(nm, -v), 1e-3, 1.0);
            vec3 hv = normalize(lightDir - v);
            float nl2 = max(dot(nm, lightDir), 0.0), nh = max(dot(nm, hv), 0.0), a2 = alpha * alpha;
            float dd = nh * nh * (a2 - 1.0) + 1.0;
            float D = a2 / (PI * dd * dd);
            float k = alpha * 0.5, G = nv / (nv * (1.0 - k) + k) * nl2 / (nl2 * (1.0 - k) + k);
            vec3 F = f0 + (1.0 - f0) * pow(1.0 - max(dot(hv, -v), 0.0), 5.0);
            col += sunCol * sh * D * G * F / max(4.0 * nv, 1e-3) * PI;   // x pi: our lights skip diffuse's 1/pi
            vec3 Fv = f0 + (1.0 - f0) * pow(1.0 - nv, 5.0) * smoothness;
            float w = smoothstep(0.45, 0.75, smoothness);
            if (w > 0.0 && (metal || luma(Fv) > 0.03)) {
                // a little scatter around the mirror direction for rough-ish surfaces (TAA smooths the noise)
                vec3 jit = vec3(ign(gl_FragCoord.xy, frameCounter), ign(gl_FragCoord.xy + 17.0, frameCounter + 3),
                                ign(gl_FragCoord.xy + 41.0, frameCounter + 7)) - 0.5;
                vec3 rd = normalize(reflect(v, nm) + jit * alpha * 2.0);
                if (dot(rd, n) < 0.02) rd = reflect(v, n);
                float skyOpen = smoothstep(0.3, 0.9, nl.w);
                vec3 refl = skyColor(rd, sunDir) * skyOpen;
  #ifdef SURFACE_RT
                refl = traceReflection(p + n * 0.02, rd, lightDir, sunCol, skyAmb, sunDir, skyOpen);
  #endif
                refl /= 1.0 + luma(refl) * 0.08;
                col = mix(col, refl * (metal ? a : vec3(1.0)), w * (metal ? 0.9 : luma(Fv)));
            }
        }
#endif
#ifdef RAIN_PUDDLES
        // puddles: a flat water surface on top, mirroring what's above it (ray traced, or the sky without RT)
        if (m.b > 0.01) {
            vec3 v = normalize(p);
            vec3 pn = vec3(0.0, 1.0, 0.0);
            vec3 rd = reflect(v, pn);
            // (at least 15%: a real puddle seen from above is dark and still shows the sky; pure Fresnel's 2% vanishes)
            float f = max(0.02 + 0.98 * pow(1.0 - clamp(-v.y, 0.0, 1.0), 5.0), 0.15);
            float skyOpen = smoothstep(0.3, 0.9, nl.w);
            vec3 refl = skyColor(rd, sunDir) * skyOpen;
  #ifdef SURFACE_RT
            if (f > 0.04)   // faded in, so there's no ring where the rays start
                refl = mix(refl, traceReflection(p + pn * 0.02, rd, lightDir, sunCol, skyAmb, sunDir, skyOpen),
                           smoothstep(0.04, 0.06, f));
  #endif
            refl /= 1.0 + luma(refl) * 0.08;
            col = mix(col, refl, f * m.b);
        }
#endif
#if DEBUG_VIEW == 1
        col = sh * max(dot(n, lightDir), 0.0);
#elif DEBUG_VIEW == 2
        col = vec3(ao);
#elif DEBUG_VIEW == 3 && defined USE_RT && defined RT_GI
        col = gi / (gi + 1.0);
#elif DEBUG_VIEW == 6
        col = vec3(m.b, nl.w * 0.3, 0.0);   // red: puddle, green: sky light
#elif DEBUG_VIEW == 4
        col = n * 0.5 + 0.5;
#endif
    }
    outColor = vec4(col, 1.0);
    outBehind = vec4(col, depth >= 1.0 && mat != MAT_DH ? 1e4 : length(p));
}
