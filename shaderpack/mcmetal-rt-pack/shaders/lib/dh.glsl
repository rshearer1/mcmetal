// Distant Horizons LODs (dh_terrain, dh_water). Far terrain is drawn by DH into the same G-buffer before
// deferred, with its own depth (dhDepthTex0). It isn't in the ray-traced scene: deferred2.fsh lights it from the
// lightmap (MAT_DH). DH_WATER = forward-lit water with a sky reflection.
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/style.glsl"
#ifdef DH_WATER
    #include "/lib/sky.glsl"
    #include "/lib/lighting.glsl"
#endif
#ifndef DH_BLOCK_WATER
    #define DH_BLOCK_WATER 12
#endif
#ifndef DH_BLOCK_ILLUMINATED
    #define DH_BLOCK_ILLUMINATED 15
#endif

#ifdef VSH
// (dhMaterialId: Iris declares it in DH vertex shaders)
out vec4 tint;
out vec2 lmcoord;
out vec3 normalW;
out vec3 playerPos;
flat out int dhMat;
#ifdef DH_WATER
flat out vec3 sunCol, skyAmb;
#endif
void main() {
    gl_Position = gl_ProjectionMatrix * (gl_ModelViewMatrix * gl_Vertex);
    tint = gl_Color;
    lmcoord = clamp(((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy * 16.0 - 0.5) / 15.0, 0.0, 1.0);
    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
    normalW = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    dhMat = dhMaterialId;
#ifdef DH_WATER
    lightColors(sunCol, skyAmb);
#endif
}
#endif

#ifdef FSH
in vec4 tint;
in vec2 lmcoord;
in vec3 normalW;
in vec3 playerPos;
flat in int dhMat;
#ifdef DH_WATER
flat in vec3 sunCol, skyAmb;
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;
#else
/* RENDERTARGETS: 0,1,2,10 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLight;
layout(location = 2) out vec4 outMaterial;
layout(location = 3) out vec4 outPBR;
#endif

void main() {
    // the real chunks cover everything nearer than the render distance: drop the LOD there (dithered edge)
    float d = length(playerPos.xz);
    if (d < far * 0.85 + 8.0 * ign(gl_FragCoord.xy, frameCounter) - 4.0) discard;
    vec3 n = normalize(normalW);
#ifdef DH_WATER
    vec3 a = styleFoliage(toLinear(tint.rgb) * 1.6, tint.rgb, true);   // the real water nearby is lighter: it shows the lit bottom through it
    vec3 L = lightDirection();
    vec3 col = a * surfaceLight(playerPos, n, lmcoord, 1.0, MAT_NONE, L, sunCol, skyAmb,
                                vec3(smoothstep(0.85, 0.97, lmcoord.y)));
    vec3 v = normalize(playerPos);
    // (at least 10%: far water is seen at a grazing angle through haze, and reads mostly as reflected sky)
    float f = max(0.02 + 0.98 * pow(1.0 - clamp(dot(-v, n), 0.0, 1.0), 5.0), 0.1);
    vec3 refl = skyColor(reflect(v, n), sunDirection()) * smoothstep(0.3, 0.9, lmcoord.y);
    outColor = vec4(mix(col, refl, f), mix(0.6, 1.0, f));
#else
    outAlbedo = vec4(styleFoliage(tint.rgb, tint.rgb, false), 1.0);   // far greens match the look too
    outNormalLight = vec4(octEncode(n), lmcoord);
    // glowing LODs (lava, light blocks) use the emission channel LabPBR uses
    outMaterial = vec4(float(MAT_DH) / 255.0, 1.0, 0.0, dhMat == DH_BLOCK_ILLUMINATED ? 0.5 : 0.0);
    outPBR = vec4(0.0);
#endif
}
#endif
