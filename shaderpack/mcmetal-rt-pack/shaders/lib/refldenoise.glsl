// Reflection denoiser: the traced reflection of a glossy surface scatters around the mirror direction (one ray per
// pixel and frame), so on its own it is grainy. Each pixel keeps a running average of its reflection (Iris shader
// storage buffer 2), carried along as the camera moves like the GI's; the rougher the surface, the more frames it
// averages (a mirror keeps none: its reflection moves differently from the surface, and has no scatter to hide).
// Needs uniforms; deferred4.fsh only.
#ifndef REFL_DENOISE_LIB
#define REFL_DENOISE_LIB
#extension GL_ARB_shader_storage_buffer_object : enable
layout(std430, binding = 2) buffer ReflHistory { uvec2 rhCells[]; };   // x light (RGB9E5), y distance, frames
const int RH_HALF = 4194304;   // two frames x 4M pixels (2560x1600) x 8 bytes
uniform mat4 gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

int rhIndex(vec2 px, int frame) {
    ivec2 q = ivec2(px);
    int s = int(viewWidth), i = q.y * s + q.x;
    return q.x < 0 || q.y < 0 || q.x >= s || i >= RH_HALF ? -1 : i + (frame & 1) * RH_HALF;
}
// HDR colour in 32 bits: 9 bits per channel and a shared exponent
uint packRGB9E5(vec3 c) {
    c = clamp(c, vec3(0.0), vec3(65000.0));
    float m = max(c.r, max(c.g, c.b));
    int e = clamp(int(floor(log2(max(m, 1e-20)))) + 1, -15, 16);
    float s = exp2(float(e - 9));
    uvec3 q = uvec3(min(round(c / s), vec3(511.0)));
    return q.r | (q.g << 9) | (q.b << 18) | (uint(e + 15) << 27);
}
vec3 unpackRGB9E5(uint v) {
    return vec3(uvec3(v, v >> 9, v >> 18) & 511u) * exp2(float(int(v >> 27) - 24));
}

// p: the surface (player space), refl: this frame's traced reflection, alpha: GGX roughness
vec3 reflDenoise(vec3 p, vec3 refl, float alpha) {
    float dist = length(p);
    float cap = 1.0 + 15.0 * smoothstep(0.02, 0.2, alpha);
    vec3 pp = p + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(pp, 1.0));
    float n = 0.0;
    vec3 hist = refl;
    int hi = pc.w > 0.0 ? rhIndex((pc.xy / pc.w * 0.5 + 0.5) * vec2(viewWidth, viewHeight), frameCounter + 1) : -1;
    if (hi >= 0) {
        uvec2 e = rhCells[hi];
        vec2 dn = unpackHalf2x16(e.y);
        if (dn.y > 0.0 && abs(dn.x - length(pp)) < 0.03 * dist + 0.1) {   // the same surface was there
            n = min(dn.y, cap - 1.0);
            hist = unpackRGB9E5(e.x);
        }
    }
    vec3 c = mix(hist, refl, 1.0 / (n + 1.0));
    int ci = rhIndex(gl_FragCoord.xy, frameCounter);
    if (ci >= 0) rhCells[ci] = uvec2(packRGB9E5(c), packHalf2x16(vec2(dist, n + 1.0)));
    return c;
}
#endif
