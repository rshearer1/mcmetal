// One template for every gbuffers program. Each program file sets a few defines, then includes this:
//   VSH / FSH       which stage
//   OPAQUE          writes the G-buffer (albedo, normal + lightmap, material); lit later in deferred
//   FORWARD         lit right here in HDR (translucent things drawn after deferred), RENDERTARGETS 0
//   UNLIT           FORWARD without lighting: glowing overlays (spider eyes, enchant glint, beacon beam)
//   TERRAIN         reads mc_Entity (block ids from block.properties) and separate AO
//   WATER           water and other translucent blocks: sky reflection on water
//   STARS_ONLY      gbuffers_skybasic: drop vanilla's sky colour, keep the stars (with MATERIAL MAT_SKY)
//   NO_TEXTURE      gbuffers_basic and the like: vertex colour only
//   MATERIAL        material id when TERRAIN doesn't decide it (default MAT_NONE)
//   TRACE_SHADOW    FORWARD non-terrain programs that still cast a shadow ray (translucent entities, held glass)
//   KEEP_MATERIAL   FORWARD programs that may run before deferred (clouds): also mark the pixel already lit
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/style.glsl"
#if defined FORWARD && !defined UNLIT
    #include "/lib/sky.glsl"
    #include "/lib/lighting.glsl"
#endif
#ifndef MATERIAL
    #define MATERIAL MAT_NONE
#endif

#ifdef VSH
out vec2 texcoord;
out vec2 lmcoord;
out vec4 tint;
out vec3 normalW;
out vec3 playerPos;
flat out int mat;
#if defined OPAQUE && defined LABPBR
in vec4 at_tangent;
out vec4 tangentW;   // xyz tangent in player space, w handedness
#endif
#if defined FORWARD && !defined UNLIT
flat out vec3 sunCol, skyAmb;
#endif
#ifdef TERRAIN
in vec4 mc_Entity;
#endif

void main() {
    gl_Position = gl_ProjectionMatrix * (gl_ModelViewMatrix * gl_Vertex);   // not ftransform(): Iris leaves it in line programs
#ifdef TAA
    // a different sub-pixel shift every frame (Halton 2,3 over 8 frames); composite2 blends them into smooth edges
    int k = frameCounter % 8 + 1;
    vec2 halton = vec2(0.0);
    for (float f = 0.5, i = float(k); i > 0.0; f *= 0.5, i = floor(i / 2.0)) halton.x += f * mod(i, 2.0);
    for (float f = 1.0 / 3.0, i = float(k); i > 0.0; f /= 3.0, i = floor(i / 3.0)) halton.y += f * mod(i, 3.0);
    gl_Position.xy += (halton - 0.5) * 2.0 / vec2(viewWidth, viewHeight) * gl_Position.w;
#endif
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = clamp(((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy * 16.0 - 0.5) / 15.0, 0.0, 1.0);
    tint = gl_Color;
    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
    normalW = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
#if defined OPAQUE && defined LABPBR
    tangentW = vec4(mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * at_tangent.xyz), at_tangent.w);
#endif
    mat = MATERIAL;
#ifdef TERRAIN
    int id = int(mc_Entity.x + 0.5);
    if (id == 10001) mat = MAT_FOLIAGE;
    else if (id >= 10100 && id < 10200) mat = MAT_EMISSIVE;
    else if (id >= 10200 && id < 10300) mat = MAT_GLOW;
    else if (id == 10002) mat = MAT_WATER;
    else if (id == 10003) mat = MAT_GLASS;
#endif
#if defined FORWARD && !defined UNLIT
    lightColors(sunCol, skyAmb);
#endif
#ifdef STARS_ONLY
    // only the stars are kept: vanilla's sky dome and sunset fan are clipped here, before any of their pixels run
    if (renderStage != MC_RENDER_STAGE_STARS) gl_Position = vec4(0.0, 0.0, -2.0, 1.0);
#endif
}
#endif

#if defined FORWARD && !defined UNLIT && defined WATER_SHADOWS && (defined TERRAIN || defined TRACE_SHADOW)
    #define FORWARD_SHADOW
#endif

#ifdef FSH
#ifdef FORWARD_SHADOW
    #include "/lib/shadow.glsl"
#endif
#if defined WATER && defined USE_RT && defined RT_REFLECTIONS && defined FORWARD_SHADOW
    #define WATER_RT_REFLECT
    #include "/lib/reflect.glsl"
#endif
#ifdef WATER
    #include "/lib/waves.glsl"
#endif
uniform sampler2D gtexture;
in vec2 texcoord;
in vec2 lmcoord;
in vec4 tint;
in vec3 normalW;
in vec3 playerPos;
flat in int mat;
#if defined OPAQUE && defined LABPBR
in vec4 tangentW;
uniform sampler2D normals, specular;   // LabPBR resource packs (Iris binds flat defaults without one)
#endif
#if defined FORWARD && !defined UNLIT
flat in vec3 sunCol, skyAmb;
#endif

#if defined OPAQUE
/* RENDERTARGETS: 0,1,2,10 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLight;
layout(location = 2) out vec4 outMaterial;
layout(location = 3) out vec4 outPBR;   // colortex10: xy normal with the normal map, z smoothness, w F0/metal (LabPBR)
#elif defined KEEP_MATERIAL
/* RENDERTARGETS: 0,2 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outMaterial;
#elif defined WATER
// Water, glass and the other see-through blocks are blended in two parts (shaders.properties): colortex0 is
// multiplied by how much light gets through (a colour, so stained glass tints what's behind it), colortex13 adds
// what the surface itself gives (its lit texture, reflections); composite1.fsh adds the two.
/* RENDERTARGETS: 0,11,13 */
layout(location = 0) out vec4 outColor;   // rgb: light let through (multiplies what's behind)
layout(location = 1) out vec4 outWater;   // colortex11: r water, gb glass refraction offset, a glass (nearest surface)
layout(location = 2) out vec4 outAdd;     // colortex13: light from the surface itself (added)
#else
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;
#endif

void main() {
#ifdef NO_TEXTURE
    vec4 c = tint;
#else
    vec4 c = texture(gtexture, texcoord) * tint;
#endif
    float ao = 1.0;
#ifdef TERRAIN
    // Iris separateAo: vertex alpha is the corner darkening, the texture alpha is the real alpha
    ao = tint.a;
    c.a = texture(gtexture, texcoord).a;
#endif
#ifdef STARS_ONLY
    // gbuffers_skybasic: keep only the stars; the sky colour itself is ours (deferred)
    if (renderStage != MC_RENDER_STAGE_STARS) discard;
#endif
    if (c.a < 0.1) discard;
#if defined TERRAIN && STYLE > 0
    c.rgb = styleFoliage(c.rgb, tint.rgb, mat == MAT_WATER);   // the look's own greens and water
#endif
#if defined TERRAIN && defined SEASONS
    if (mat != MAT_WATER) c.rgb = seasonPlants(c.rgb, seasonWeights(), clamp((tint.g - max(tint.r, tint.b)) * 6.0, 0.0, 1.0));
#endif
    c.rgb = mix(c.rgb, entityColor.rgb, entityColor.a);   // red hurt flash on mobs

    vec3 n = normalize(normalW);
    if (!gl_FrontFacing) n = -n;
#if defined TERRAIN && defined OPAQUE && defined SEASONS
    if (mat == MAT_NONE || mat == MAT_FOLIAGE)   // winter frost on what faces the open sky
        c.rgb = seasonFrost(c.rgb, seasonWeights(), clamp((tint.g - max(tint.r, tint.b)) * 6.0, 0.0, 1.0),
                            smoothstep(0.5, 0.9, n.y), lmcoord.y);
#endif

#if defined OPAQUE
    float puddle = 0.0;
  #if defined TERRAIN && defined RAIN_PUDDLES
    // rain wets what the sky reaches (full sky light only: the lightmap fades in diamonds, which drew straight
    // diagonal puddle edges near roofs): darker, richer colours; on flat ground, water gathers in patches
    float wet = wetness * smoothstep(0.93, 0.99, lmcoord.y) * float(mat == MAT_NONE);
    if (wet > 0.001) {
        vec2 w = playerPos.xz + cameraPosition.xz;
        // two noise layers add up to a narrow range around 0.5: stretch it, then keep the top ~quarter as puddles
        w += (vec2(valueNoise(w * 0.7), valueNoise(w * 0.7 + 5.2)) - 0.5) * 2.4;   // warp: no straight edges
        float shape = (valueNoise(w * 0.45) * 0.6 + valueNoise(w * 1.6) * 0.27 + valueNoise(w * 4.1) * 0.13 - 0.5) * 2.5 + 0.5;
        puddle = wet * smoothstep(0.56, 0.64, shape + 0.1 * (PUDDLE_AMOUNT - 1.0)) * smoothstep(0.9, 0.98, n.y);
        c.rgb = pow(c.rgb, vec3(1.0 + 0.4 * wet)) * (1.0 - 0.25 * wet - 0.55 * puddle);
    }
  #endif
    outNormalLight = vec4(octEncode(n), lmcoord);
    // LabPBR: normal map (tangent space xy, AO in b), smoothness / F0 / emission from the specular map
    vec3 nm = n;
    vec4 spec = vec4(0.0);
  #ifdef LABPBR
    {
        vec4 nt = texture(normals, texcoord);
        // bumps fade out with distance: far away a texel is smaller than a pixel, and full-strength normals there
        // shimmer into wave-like patterns (moire) as the view moves
        float bump = LABPBR_NORMAL_STRENGTH * (1.0 - 0.75 * smoothstep(12.0, 40.0, length(playerPos)));
        vec2 xy = (nt.xy * 2.0 - 1.0) * bump;
        vec3 tn = vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
        vec3 t = tangentW.xyz - n * dot(tangentW.xyz, n);
        if (dot(t, t) > 1e-6 && nt.a > 0.0) {
            t = normalize(t);
            vec3 b = cross(n, t) * (tangentW.w < 0.0 ? -1.0 : 1.0);
            nm = normalize(t * tn.x + b * tn.y + n * tn.z);
            // the pack's own AO and height (cracks, grout, mortar lines) darken the colour itself, so the relief
            // shows in every light, also in the ray-traced bounce light and at noon when the sun is straight above
            // (at most to 0.6 in all: packs made by converters often store something else in blue, and the
            // ray-traced AO darkens the same cracks again)
            c.rgb *= max(nt.b * mix(1.0 - 0.3 * bump, 1.0, nt.a), 0.6);
        }
        spec = texture(specular, texcoord);
        if (spec.a > 254.5 / 255.0) spec.a = 0.0;   // LabPBR: 255 = no emission
    }
  #endif
    outAlbedo = vec4(c.rgb, 1.0);
    // puddles are flat and mirror-smooth
    spec.r = max(spec.r, puddle);
    outMaterial = vec4(float(mat) / 255.0, ao, puddle, spec.a);
    outPBR = vec4(octEncode(nm), spec.r, spec.g);
#else
    vec3 albedo = toLinear(c.rgb);
  #ifdef UNLIT
    vec3 col = albedo * 2.0;
  #else
    vec3 L = lightDirection();
    #ifdef FORWARD_SHADOW
    vec3 sh = vec3(0.0);
    if (dot(n, L) > 0.0 || mat == MAT_FOLIAGE) sh = sunShadow(playerPos, n, L, mat);
    #else
    vec3 sh = vec3(smoothstep(0.85, 0.97, lmcoord.y));   // particles, rain, clouds: lit where the sky is open
    #endif
    vec3 col = albedo * surfaceLight(playerPos, n, lmcoord, ao, mat, L, sunCol, skyAmb, sh) + emission(albedo, mat);
    #ifdef WATER
    bool top = false;   // open water's flat top: its rays are traced in composite.fsh instead (WATER_REFLECT_PASS)
    if (mat == MAT_WATER && n.y > 0.9) {
        n = waveNormal(playerPos.xz + cameraPosition.xz);   // lib/waves.glsl
        top = true;
        c.a = 0.55;    // clearer than vanilla water: you see the bottom
    }
    // glass: the streaks become bumps. Their brightness slope across the texture bends the view (composite1.fsh
    // shifts what's seen through it), more up close than far away
    vec2 refr = vec2(0.0);
      #ifdef GLASS_REFRACTION
    if (mat == MAT_GLASS) {
        vec2 ts = 1.0 / vec2(textureSize(gtexture, 0));
        float h0 = luma(texture(gtexture, texcoord).rgb), hx = luma(texture(gtexture, texcoord + vec2(ts.x, 0.0)).rgb),
              hy = luma(texture(gtexture, texcoord + vec2(0.0, ts.y)).rgb);
        refr = vec2(hx - h0, hy - h0) * (0.2 * GLASS_REFRACTION_STRENGTH / max(length(playerPos), 1.0));
    }
      #endif
    // reflections: a hardware ray finds what the surface mirrors (on or off screen); otherwise just the sky
    vec3 v = normalize(playerPos);
    float f = 0.02 + 0.98 * pow(1.0 - clamp(dot(-v, n), 0.0, 1.0), 5.0);
    float skyOpen = smoothstep(0.3, 0.9, lmcoord.y);
      #ifdef WATER_RT_REFLECT
    // looking down at water reflects only 2-5%: not worth a ray, the sky stands in (the biggest share of water pixels)
    // (faded in between 4% and 6%, so there's no visible line where the rays start)
    vec3 refl = skyColor(reflect(v, n), sunDirection()) * skyOpen;
    bool traced = f > 0.04;
        #ifdef WATER_REFLECT_PASS
    if (top && isEyeInWater == 0) traced = false;   // open water: only the sky here, composite.fsh adds the traced part
        #endif
    if (traced)
        refl = mix(refl, traceReflection(playerPos + n * 0.02, reflect(v, n), L, sunCol, skyAmb, sunDirection(), skyOpen),
                   smoothstep(0.04, 0.06, f));
      #else
    vec3 refl = skyColor(reflect(v, n), sunDirection()) * skyOpen;
      #endif
    // soften very bright mirrored points (lights and the sun on tiny wave facets): one sample per pixel, no history
    // here, so they would sparkle as single-pixel specks
    refl /= 1.0 + luma(refl) * 0.08;
    vec3 through = vec3(1.0 - mix(c.a, 1.0, f));      // plain see-through blocks and water: like alpha blending
    vec3 own = mix(col, refl, f) * mix(c.a, 1.0, f);
      #ifdef GLASS_REFRACTION
    if (mat == MAT_GLASS) {
        // clear glass barely tints and its streaks stay faint; stained glass tints by its colour like real glass
        // (stained glass is ~half opaque in its texture: that's already full tint; squared for a deeper colour)
        vec3 hue = albedo / max(max(albedo.r, max(albedo.g, albedo.b)), 1e-3);
        vec3 tintCol = mix(vec3(1.0), hue * hue, clamp(c.a * 2.5, 0.0, 1.0));
        through = tintCol * (1.0 - 0.3 * c.a) * (1.0 - f);
        own = col * c.a * 0.5 * (1.0 - f) + refl * f;
    }
      #endif
    #endif
  #endif
  #ifdef WATER
    outColor = vec4(through, 1.0);
    // (alpha: dims the light that surfaces further back added to colortex13, which the multiply on colortex0 can't
    // reach; only by brightness, so a waterfall behind red glass is darkened rather than reddened)
    outAdd = vec4(own, 1.0 - luma(through));
    // r: 0 not water, 0.55 water, 0.6-1.0 open water's top (and how open its sky is, for composite.fsh)
    float wr = mat != MAT_WATER ? 0.0 : top ? 0.6 + 0.4 * skyOpen : 0.55;
    outWater = vec4(wr, clamp(refr * 8.0 + 0.5, 0.0, 1.0), float(mat == MAT_GLASS));
  #else
    outColor = vec4(col, c.a);
  #endif
  #ifdef KEEP_MATERIAL
    outMaterial = vec4(float(MAT_LIT) / 255.0, 1.0, 0.0, 0.0);
  #endif
#endif
}
#endif
