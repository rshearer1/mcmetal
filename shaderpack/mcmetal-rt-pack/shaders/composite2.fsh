#version 330 compatibility
// Temporal anti-aliasing: every frame the whole picture is shifted by a different sub-pixel amount (lib/gbuffer.glsl),
// and here each pixel is blended with where it was last frame. Edges, thin plants and far details get smooth
// instead of jagged and shimmering. Last frame's colour is kept within the range of this pixel's neighbours, so
// moving things don't leave ghosts.
/*
const int colortex9Format = RGBA16F;   // last frame's anti-aliased picture
const bool colortex9Clear = false;
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"

uniform sampler2D colortex0, colortex2, colortex9, depthtex0;
uniform mat4 gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

in vec2 texcoord;

/* RENDERTARGETS: 0,9 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outHistory;

vec3 toYCoCg(vec3 c) { return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b); }
vec3 fromYCoCg(vec3 c) { return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z); }
// HDR values compressed before blending, so one very bright pixel doesn't dominate (and back after)
vec3 squash(vec3 c) { return c / (1.0 + luma(c)); }
vec3 unsquash(vec3 c) { return c / max(1.0 - luma(c), 1e-4); }

void main() {
    vec3 cur = texture(colortex0, texcoord).rgb;
#ifdef TAA
    vec2 px = 1.0 / vec2(viewWidth, viewHeight);
    // the neighbourhood's range (mean +- spread, in YCoCg) bounds what last frame may contribute
    vec3 m1 = vec3(0.0), m2 = vec3(0.0);
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            vec3 c = toYCoCg(squash(texture(colortex0, texcoord + vec2(x, y) * px).rgb));
            m1 += c; m2 += c * c;
        }
    m1 /= 9.0;
    vec3 sigma = sqrt(max(m2 / 9.0 - m1 * m1, 0.0));
    vec3 lo = m1 - sigma * 1.25, hi = m1 + sigma * 1.25;

    // where was this pixel last frame? (the held item moves with the camera: no reprojection)
    float depth = texture(depthtex0, texcoord).r;
    int mat = int(texture(colortex2, texcoord).r * 255.0 + 0.5);
    vec2 puv = texcoord;
    if (!handLike(mat) && depth < 1.0) {
        vec4 v = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
        vec3 p = mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
        vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(p + cameraPosition - previousCameraPosition, 1.0));
        puv = pc.xy / pc.w * 0.5 + 0.5;
    } else if (depth >= 1.0) {
        // sky: only the camera's turn matters
        vec4 v = gbufferProjectionInverse * vec4(texcoord * 2.0 - 1.0, 0.0, 1.0);
        vec3 d = mat3(gbufferModelViewInverse) * (v.xyz / v.w);
        vec4 pc = gbufferPreviousProjection * vec4(mat3(gbufferPreviousModelView) * d, 1.0);
        puv = pc.xy / pc.w * 0.5 + 0.5;
    }
    vec3 hist = texture(colortex9, puv).rgb;
    bool valid = all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0))) && !any(isnan(hist));
    vec3 h = clamp(toYCoCg(squash(hist)), lo, hi);
    // fast camera moves: trust the new frame more
    float motion = length((puv - texcoord) * vec2(viewWidth, viewHeight));
    float w = valid ? mix(0.9, 0.7, clamp(motion / 20.0, 0.0, 1.0)) : 0.0;
  #ifdef PHOTO_MODE
    if (motion < 0.01 && length(cameraPosition - previousCameraPosition) < 1e-4) w = valid ? 0.97 : 0.0;
  #endif
    cur = unsquash(fromYCoCg(mix(toYCoCg(squash(cur)), h, w)));
#endif
    outColor = vec4(cur, 1.0);
    outHistory = vec4(cur, 1.0);
}
