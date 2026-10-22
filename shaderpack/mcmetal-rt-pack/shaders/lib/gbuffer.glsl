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
#if defined FORWARD && !defined UNLIT
flat out vec3 sunCol, skyAmb;
#endif
#ifdef TERRAIN
in vec4 mc_Entity;
#endif

void main() {
    gl_Position = gl_ProjectionMatrix * (gl_ModelViewMatrix * gl_Vertex);   // not ftransform(): Iris leaves it in line programs
#ifdef TAA
    // a different sub-pixel shift every frame (Halton 2,3 over 8 frames); composite1 blends them into smooth edges
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
    mat = MATERIAL;
#ifdef TERRAIN
    int id = int(mc_Entity.x + 0.5);
    if (id == 10001) mat = MAT_FOLIAGE;
    else if (id >= 10100 && id < 10200) mat = MAT_EMISSIVE;
    else if (id >= 10200 && id < 10300) mat = MAT_GLOW;
    else if (id == 10002) mat = MAT_WATER;
#endif
#if defined FORWARD && !defined UNLIT
    lightColors(sunCol, skyAmb);
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
uniform sampler2D gtexture;
in vec2 texcoord;
in vec2 lmcoord;
in vec4 tint;
in vec3 normalW;
in vec3 playerPos;
flat in int mat;
#if defined FORWARD && !defined UNLIT
flat in vec3 sunCol, skyAmb;
#endif

#if defined OPAQUE
/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLight;
layout(location = 2) out vec4 outMaterial;
#elif defined KEEP_MATERIAL
/* RENDERTARGETS: 0,2 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outMaterial;
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
    c.rgb = mix(c.rgb, entityColor.rgb, entityColor.a);   // red hurt flash on mobs

    vec3 n = normalize(normalW);
    if (!gl_FrontFacing) n = -n;

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
    outAlbedo = vec4(c.rgb, 1.0);
    outNormalLight = vec4(octEncode(n), lmcoord);
    outMaterial = vec4(float(mat) / 255.0, ao, puddle, 1.0);
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
    if (mat == MAT_WATER && n.y > 0.9) {
        // small moving waves: a few travelling sine waves in world space, their slopes tilt the normal
        vec2 w = playerPos.xz + cameraPosition.xz;
        float tm = frameTimeCounter * WAVE_SPEED;
        vec2 slope = vec2(0.0);
        const vec2 dirs[4] = vec2[4](vec2(0.8, 0.6), vec2(-0.5, 0.86), vec2(0.97, -0.26), vec2(-0.2, -0.98));
        const float lens[4] = float[4](3.1, 1.7, 0.93, 0.51);
        for (int i = 0; i < 4; i++) {
            float k = 6.2832 / lens[i], ph = dot(dirs[i], w) * k + tm * sqrt(9.8 * k);
            slope += dirs[i] * (cos(ph) * k * lens[i] * 0.012);   // amplitude grows with wavelength
        }
        n = normalize(vec3(-slope.x, 1.0, -slope.y) * vec3(WAVE_HEIGHT, 1.0, WAVE_HEIGHT));
        c.a = 0.55;    // clearer than vanilla water: you see the bottom
    }
    // reflections: a hardware ray finds what the surface mirrors (on or off screen); otherwise just the sky
    vec3 v = normalize(playerPos);
    float f = 0.02 + 0.98 * pow(1.0 - clamp(dot(-v, n), 0.0, 1.0), 5.0);
    float skyOpen = smoothstep(0.3, 0.9, lmcoord.y);
      #ifdef WATER_RT_REFLECT
    // looking down at water reflects only 2-5%: not worth a ray, the sky stands in (the biggest share of water pixels)
    // (faded in between 4% and 6%, so there's no visible line where the rays start)
    vec3 refl = skyColor(reflect(v, n), sunDirection()) * skyOpen;
    if (f > 0.04)
        refl = mix(refl, traceReflection(playerPos + n * 0.02, reflect(v, n), L, sunCol, skyAmb, sunDirection(), skyOpen),
                   smoothstep(0.04, 0.06, f));
      #else
    vec3 refl = skyColor(reflect(v, n), sunDirection()) * skyOpen;
      #endif
    // soften very bright mirrored points (lights and the sun on tiny wave facets): one sample per pixel, no history
    // here, so they would sparkle as single-pixel specks
    refl /= 1.0 + luma(refl) * 0.08;
    col = mix(col, refl, f);
    c.a = mix(c.a, 1.0, f);
    #endif
  #endif
    outColor = vec4(col, c.a);
  #ifdef KEEP_MATERIAL
    outMaterial = vec4(float(MAT_LIT) / 255.0, 1.0, 0.0, 1.0);
  #endif
#endif
}
#endif
