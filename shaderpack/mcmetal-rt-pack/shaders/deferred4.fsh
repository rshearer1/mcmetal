#version 330 compatibility
// Deferred lighting (after deferred.fsh: GI + AO, deferred1.fsh: sun shadows) of everything opaque, plus our sky. Runs after the opaque G-buffer, before water and glass.
/*
const int colortex0Format = RGBA16F;   // albedo in, HDR colour out (water etc. then blend on top in HDR)
const int colortex1Format = RGBA16F;   // xy octahedral normal (player space, signed: half float, as mcmetal has no 16-bit snorm yet), zw lightmap (block, sky)
const int colortex2Format = RGBA8;     // r material id, g vanilla AO
const bool colortex1Clear = true;
const bool colortex2Clear = true;
const vec4 colortex1ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex2ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const int colortex10Format = RGBA16F;      // xy normal with the normal map (signed), z linear roughness (1 - LabPBR smoothness), w F0/metal
const bool colortex10Clear = true;
const vec4 colortex10ClearColor = vec4(0.0, 0.0, 1.0, 0.0);   // nothing written: fully rough
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"
#ifdef CLOUDS
    #include "/lib/clouds.glsl"
#endif
#include "/lib/stars.glsl"
#if !defined USE_RT || defined RT_REFLECTIONS
    // (the ray-traced shadow comes from deferred1.fsh; with RT this is only for what reflections see)
    #include "/lib/shadow.glsl"
#endif
#if defined USE_RT && defined RT_REFLECTIONS
    // reflections on puddles and on smooth LabPBR surfaces
    #define SURFACE_RT
    #include "/lib/reflect.glsl"
#endif

uniform sampler2D colortex0, colortex1, colortex2, colortex3, colortex4, colortex5, colortex7, colortex10, depthtex0;

// the sun shadow (colortex5: rgb shadow, a distance), cleaned of the grain left by one ray per pixel and frame:
// a 3x3 blur over pixels at the same distance facing the same way, so shadow edges between objects stay sharp
vec3 filteredShadow(vec2 uv, vec3 n) {
    vec4 c = texture(colortex5, uv);
#ifdef SHADOW_FILTER
    if (c.a <= 0.0) return c.rgb;
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    vec3 sum = c.rgb;
    float wsum = 1.0, tol = 0.02 * c.a + 0.05;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            vec2 q = uv + vec2(x, y) * px;
            vec4 s = texture(colortex5, q);
            float w = (abs(x) + abs(y) == 2 ? 0.5 : 1.0)
                    * step(abs(s.a - c.a), tol)
                    * pow(max(dot(octDecode(texture(colortex1, q).xy), n), 0.0), 16.0);
            sum += s.rgb * w;
            wsum += w;
        }
    return sum / wsum;
#else
    return c.rgb;
#endif
}

#ifdef DISTANT_HORIZONS
uniform sampler2D dhDepthTex0;
uniform mat4 dhProjectionInverse;
#endif

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

#if defined RAIN_PUDDLES && defined RAIN_RIPPLES
// rings spreading from raindrops on a puddle: the normal of a few cells of rings (two layers, offset), each cell
// one drop at a random spot and time; rings grow and fade over a second. Flat when it isn't raining.
vec3 rippleNormal(vec2 w) {
    vec2 g = vec2(0.0);
    for (int l = 0; l < 2; l++) {
        vec2 q = w * 2.2 + float(l) * vec2(0.37, 0.71);
        vec2 cell = floor(q), f = fract(q);
        float h = hash12(cell + float(l) * 17.0);
        vec2 c = 0.3 + 0.4 * vec2(h, fract(h * 13.7));
        float t = fract(frameTimeCounter * 1.1 + h * 7.0);
        vec2 d = f - c;
        float r = length(d), R = t * 0.45;
        float ring = sin(clamp((r - R) * 40.0, -3.1416, 3.1416)) * (1.0 - t) * (1.0 - t) * step(abs(r - R), 0.08);
        g += d / max(r, 1e-3) * ring;
    }
    g *= 0.12 * rainStrength;
    return normalize(vec3(-g.x, 1.0, -g.y));
}
#endif

#ifdef LIGHTNING_FLASH
// lightning (Iris: lightningBoltPosition, w = 1 while a bolt is out, xyz player space): a flickering blue-white
// flash on everything the sky can see, much brighter near the bolt
uniform vec4 lightningBoltPosition;
vec3 lightningLight(vec3 p) {
    if (lightningBoltPosition.w < 0.5) return vec3(0.0);
    float flicker = 0.55 + 0.45 * sin(frameTimeCounter * 47.0) * sin(frameTimeCounter * 13.0);
    float d = length(p.xz - lightningBoltPosition.xz);
    return vec3(0.75, 0.82, 1.0) * flicker * (0.35 + 3.0 / (1.0 + d * d / 400.0)) * LIGHTNING_STRENGTH;
}
#endif

#ifdef METALFX_DENOISE
/* RENDERTARGETS: 0,15 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outAlbedo;   // colortex15: diffuse albedo for MetalFX's denoiser (deferred6.fsh)
#else
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;
#endif

vec3 playerFromDepth(vec2 uv, float depth) {
    vec4 v = gbufferProjectionInverse * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    return mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
}

#if defined USE_RT && defined RT_GI
  #ifdef DENOISER
    #define GI_TEX colortex7   // after the denoiser's two rounds (deferred2.fsh, deferred3.fsh)
  #else
    #define GI_TEX colortex4
  #endif
// The averaged GI is still a little grainy: blur it over a 5x5 neighbourhood (every other pixel), but only across
// pixels on the same surface (similar normal and distance), so it doesn't bleed over edges.
// At half resolution this is also the upscale: the low-resolution GI pixels around this one are weighted by
// how well their surface matches this full-resolution pixel.
vec3 filteredGI(vec3 n, float dist) {
    vec2 px = (GI_SCALE < 1.0 ? 1.0 : 2.0) / (vec2(viewWidth, viewHeight) * GI_SCALE);   // in GI pixels
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    // (GI_FILTER 9: a 3x3 over the same area, every other tap; the history and TAA smooth the rest)
    const int R = GI_FILTER == 9 ? 1 : 2;
    float tapStep = GI_FILTER == 9 ? 2.0 : 1.0;
    // a pixel that just came into view (turning, walking past a corner) has only a frame or two in its average:
    // noisy. Spread its taps wider until its history builds up, so newly seen areas don't show the single rays
    float frames = texture(colortex3, texcoord * GI_SCALE).g;
    tapStep *= mix(3.0, 1.0, smoothstep(2.0, 8.0, frames));
    for (int y = -R; y <= R; y++)
        for (int x = -R; x <= R; x++) {
            vec2 uv = texcoord + vec2(x, y) * (px * tapStep);              // full-screen position of that GI pixel
            vec3 tn = octDecode(texture(colortex1, uv).xy);
            float td = texture(colortex3, uv * GI_SCALE).b;
            float w = pow(max(dot(n, tn), 0.0), 16.0) * exp(-abs(td - dist) / (0.02 * dist + 0.05))
                    * exp(-0.15 * tapStep * tapStep * float(x * x + y * y));
            sum += texture(GI_TEX, uv * GI_SCALE).rgb * w;
            wsum += w;
        }
    return sum / max(wsum, 1e-4);
}
#endif

void main() {
    float depth = texture(depthtex0, texcoord).r;
    vec4 albedo = texture(colortex0, texcoord);
#ifdef METALFX_DENOISE
    outAlbedo = vec4(toLinear(albedo.rgb), 1.0);
#endif
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
#ifdef END_BEAMS
        if (!hasSkylight && !hasCeiling) col += drawEndSky(dir);
#endif
#ifdef LIGHTNING_FLASH
        col += lightningLight(vec3(0.0)) * 0.08 * (0.3 + 0.7 * max(dir.y, 0.0));   // the clouds light up
#endif
        // sun disc with darker edges; the moon and stars come from vanilla's textures (MAT_SKY)
        float cosSun = dot(dir, sunDir), edge = smoothstep(0.99955, 0.99975, cosSun);
        col += sunTransmittance() * edge * (60.0 * (0.6 + 0.4 * smoothstep(0.99955, 0.99995, cosSun)));
        // the bright glow round the sun (the sky table is too coarse for the haze's sharp forward peak), less in rain
        float near = max(cosSun, 0.0);
        col += sunTransmittance() * (pow(near, 4000.0) * 3.0 + pow(near, 300.0) * 0.25) * (1.0 - 0.8 * rainStrength) * (1.0 - edge);
        if (mat == MAT_SKY) col += toLinear(albedo.rgb) * 0.4 * (1.0 - 0.9 * rainStrength);
#ifdef STARS
        col += drawStars(dir, smoothstep(0.02, -0.15, sunDir.y));
#endif
#ifdef LIGHT_POLLUTION
        {   // the glow of your own lamps in the night haze: a warm band low in the sky, by how much block light is
            // around the player (a lit village glows, a dark forest doesn't); stronger in rain (more to light up)
            float night = smoothstep(0.05, -0.1, sunDir.y);
            float lamps = float(eyeBrightnessSmooth.x) / 240.0;
            float low = exp(-max(dir.y, 0.0) * 6.0);
            col += vec3(1.0, 0.62, 0.32) * low * night * lamps * (0.015 + 0.03 * rainStrength) * LIGHT_POLLUTION_STRENGTH;
        }
#endif
#ifdef RAINBOW
        {   // a rainbow opposite the sun as the rain clears (wet air, little rain left): red outside at 42 degrees,
            // violet inside at 40, a faint second bow at 51 with the colours the other way round
            float ang = degrees(acos(clamp(dot(dir, -sunDir), -1.0, 1.0)));
            float bow = clamp(wetness * 1.5 - rainStrength * 3.0, 0.0, 1.0) * smoothstep(0.0, 0.1, sunDir.y)
                      * smoothstep(0.6, 0.2, sunDir.y) * smoothstep(-0.02, 0.06, dir.y);
            if (bow > 0.0) {
                float t1 = (ang - 40.0) / 2.5, t2 = (53.0 - ang) / 3.0;
                vec3 c1 = clamp(vec3(1.0 - abs(t1 - 0.9) * 3.0, 1.0 - abs(t1 - 0.55) * 3.0, 1.0 - abs(t1 - 0.15) * 3.0), 0.0, 1.0);
                vec3 c2 = clamp(vec3(1.0 - abs(t2 - 0.9) * 3.0, 1.0 - abs(t2 - 0.55) * 3.0, 1.0 - abs(t2 - 0.15) * 3.0), 0.0, 1.0);
                col += (c1 + c2 * 0.35) * sunCol * 0.06 * bow * RAINBOW_STRENGTH;
            }
        }
#endif
        col += styleAurora(dir, smoothstep(0.02, -0.12, sunDir.y)) * (1.0 - rainStrength);
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
        float smoothness = 1.0 - pbr.z;   // stored as roughness (what mcmetal's denoised upscaler reads)
        bool metal = pbr.w > 229.5 / 255.0;
        vec3 f0 = metal ? a : vec3(max(pbr.w, 0.02));
        vec3 sh = vec3(0.0);
#ifdef USE_RT
        sh = mat == MAT_HAND ? vec3(1.0) : filteredShadow(texcoord, n);   // traced and averaged in deferred1.fsh
#else
        if (dot(sunCol, sunCol) > 1e-6 && (dot(n, lightDir) > 0.0 || mat == MAT_FOLIAGE))
            sh = sunShadow(p, n, lightDir, mat);
#endif
#if defined CLOUDS && defined CLOUD_SHADOWS
        if (mat != MAT_HAND) sh *= cloudShadow(p + cameraPosition, lightDir);
#endif
        float ao = m.g;
#if defined USE_RT && defined RT_AO
        ao = texture(colortex3, texcoord * GI_SCALE).r * (0.6 + 0.4 * m.g);   // keep a little of the corner shading
#endif
#if defined USE_RT && defined RT_GI
        // GI brings the sky light and the bounced light, so the lightmap's sky guess is left out
        // the held item isn't in the ray scene's history: it gets the plain sky light instead
        vec3 gi = mat == MAT_HAND ? skyAmb * (nl.w * nl.w) * (0.7 + 0.3 * n.y) : filteredGI(n, length(p));
        vec3 envLight = gi;   // what a rough surface sees all round (for its blurred reflection below)
  #ifdef LABPBR
        // the GI is traced for the block's face: let the normal map shade it too (light comes mostly from above
        // and from in front of the face), so bumps show in shade and under an overhead sun
        vec3 gd = normalize(n + vec3(0.0, 0.8, 0.0));
        gi *= clamp(1.0 + 2.0 * (dot(nm, gd) - dot(n, gd)), 0.45, 1.4);
  #endif
  #ifdef USE_LIGHTS
        // coloured block light (in the GI, deferred.fsh) replaces the lightmap's block light; the held light stays
        col = a * (surfaceLight(p, nm, vec2(mat == MAT_HAND ? nl.z : 0.0, nl.w), ao, mat, lightDir, sunCol, hasSkylight ? vec3(0.0) : skyAmb, sh) + gi)
            + emission(a, mat);
  #else
        col = a * (surfaceLight(p, nm, nl.zw, ao, mat, lightDir, sunCol, hasSkylight ? vec3(0.0) : skyAmb, sh) + gi) + emission(a, mat);
  #endif
#else
        col = a * surfaceLight(p, nm, nl.zw, ao, mat, lightDir, sunCol, skyAmb, sh) + emission(a, mat);
        vec3 envLight = skyAmb * (nl.w * nl.w) * (0.7 + 0.3 * n.y);
#endif
#ifdef LIGHTNING_FLASH
        col += a * lightningLight(p) * (nl.w * nl.w) * (0.6 + 0.4 * max(n.y, 0.0));
#endif
#ifdef SUBSURFACE
        // leaves and grass let sunlight through: backlit, they glow a deeper green (light scattered inside the leaf
        // comes out tinted by it twice). Strongest looking towards the sun, a little from every side
        if (mat == MAT_FOLIAGE) {
            float fwd = max(dot(normalize(p), lightDir), 0.0);
            float through = 0.15 + 0.85 * pow(fwd, 6.0);
            col += a * a * sunCol * sh * (through * 1.6 * SUBSURFACE_STRENGTH) * (1.0 - 0.5 * max(dot(n, lightDir), 0.0));
        }
#endif
        // metals have no diffuse light of their own: their colour is in what they reflect
        // (only as far as they get a reflection below: a rough metal reflects its surroundings blurred, which
        // the diffuse light stands in for, instead of going black)
        if (metal) col = emission(a, mat) + (col - emission(a, mat)) * mix(1.0, 0.08, smoothstep(0.45, 0.75, smoothness));
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
            // rough and satin surfaces (most of a PBR pack: stone, wood, brick): a blurred reflection of their
            // surroundings, no ray. What they reflect blends from the sky in the mirror direction (fairly smooth)
            // to the light all round them (rough: the GI); how much from the split-sum fit (Karis 2014, mobile).
            // The traced reflection below takes over where the surface gets smooth enough for a sharp one.
            if (!metal && w < 1.0) {
                float rough = 1.0 - smoothness;
                vec4 r4 = rough * vec4(-1.0, -0.0275, -0.572, 0.022) + vec4(1.0, 0.0425, 1.04, -0.04);
                vec2 ab = vec2(-1.04, 1.04) * (min(r4.x * r4.x, exp2(-9.28 * nv)) * r4.x + r4.y) + r4.zw;
                vec3 spec = f0 * ab.x + ab.y;
                vec3 rdm = reflect(v, nm);
                if (dot(rdm, n) < 0.02) rdm = reflect(v, n);
                vec3 seen = mix(skyColor(rdm, sunDir) * smoothstep(0.3, 0.9, nl.w), envLight, smoothstep(0.1, 0.6, rough));
                col += seen * spec * ao * (1.0 - w) * ROUGH_REFLECTIONS_STRENGTH;
            }
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
  #ifdef RAIN_RIPPLES
            pn = rippleNormal(p.xz + cameraPosition.xz);
  #endif
            vec3 rd = reflect(v, pn);
            rd.y = abs(rd.y);   // ripples never send a ray into the ground
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
}
