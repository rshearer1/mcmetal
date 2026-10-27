#version 430 compatibility
// Puts deferred.csh's half-size picture on the full-size screen. With MCMETAL_DENOISE=1 on an M3 or newer, MetalFX's
// denoiser replaces this pass and upscales the half-size inputs itself ("trace small, show big"); otherwise this
// plain bilinear upscale runs. Magenta = the half-size picture was never written (the compute pass didn't run).
const int MCMETAL_DENOISE_PASS = 1;
const int MCMETAL_DENOISE_COLOR__halfColorSampler = 1;
const int MCMETAL_DENOISE_DEPTH__halfDepthSampler = 1;
const int MCMETAL_DENOISE_NORMAL__halfNormalSampler = 1;
const int MCMETAL_DENOISE_ALBEDO__halfAlbedoSampler = 1;
const int MCMETAL_DENOISE_ROUGHNESS__halfRoughSampler__r = 1;

uniform sampler2D halfColorSampler;
uniform sampler2D halfDepthSampler;
uniform sampler2D halfNormalSampler;
uniform sampler2D halfAlbedoSampler;
uniform sampler2D halfRoughSampler;
// the camera, which mcmetal keeps for MetalFX's motion (it only sees the uniforms a pack declares)
uniform mat4 gbufferModelView, gbufferProjection, gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 cameraPosition, previousCameraPosition;

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    vec4 c = texture(halfColorSampler, texcoord);
    // the guides must be read, or the compiler drops their samplers and mcmetal can't find them
    float guides = texture(halfDepthSampler, texcoord).r + texture(halfNormalSampler, texcoord).a +
                   texture(halfAlbedoSampler, texcoord).a + texture(halfRoughSampler, texcoord).r +
                   gbufferModelView[3][3] + gbufferProjection[3][3] + gbufferPreviousModelView[3][3] +
                   gbufferPreviousProjection[3][3] + cameraPosition.x + previousCameraPosition.x;
    outColor = c.a == 0.0 ? vec4(1.0, 0.0, 1.0, 1.0) : vec4(c.rgb + guides * 1e-6, 1.0);
}
