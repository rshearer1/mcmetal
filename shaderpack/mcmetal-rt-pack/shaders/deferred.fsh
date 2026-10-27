#version 330 compatibility
// Ray-traced global illumination and ambient occlusion, one ray per pixel.
// The ray leaves in a random direction over the surface (more often near the normal: cosine weighting). If it
// escapes, it brings sky light; if it hits a block, that block's own light (sun with a shadow ray, sky, torches,
// glow) times its colour comes back: bounce light and colour bleeding. The hit distance also gives the AO.
// With mcmetal's light list, the direct light of nearby light blocks is added here too (lib/lights.glsl).
// Each pixel keeps a running average over the last frames, carried along as the camera moves.
// Runs at GI_SCALE resolution (shaders.properties scale.deferred): its pixels fill the lower-left part of the buffers.
/*
const int colortex3Format = RGBA16F;   // r occlusion (1 open), g frames in the average, b distance to the camera
const int colortex4Format = RGBA16F;   // rgb indirect light (GI), a unused
const bool colortex3Clear = false;
const bool colortex4Clear = false;
*/
#include "/lib/settings.glsl"
#ifdef PT_COMPUTE
// the work was done by deferred.csh: copy its result into the buffers the later passes read
uniform sampler2D ptAOSampler, ptGISampler;
#else
    #include "/lib/gipass.glsl"
#endif

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

/* RENDERTARGETS: 3,4 */
layout(location = 0) out vec4 outAO;
layout(location = 1) out vec4 outGI;

void main() {
#ifdef PT_COMPUTE
    outAO = texelFetch(ptAOSampler, ivec2(gl_FragCoord.xy), 0);
    outGI = texelFetch(ptGISampler, ivec2(gl_FragCoord.xy), 0);
#else
    giMain(gl_FragCoord.xy, texcoord, sunCol, skyAmb, lightDir, sunDir, outAO, outGI);
#endif
}
