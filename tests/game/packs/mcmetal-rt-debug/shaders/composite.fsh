#version 330 compatibility
// mcmetal ray-tracing debug view (see README.txt). Only runs on mcmetal (it supplies mcm_trace).

uniform sampler2D colortex0;
uniform sampler2D depthtex0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform vec3 shadowLightPosition;

in vec2 texcoord;

// distance to the first block hit along dir, or -1 (provided by mcmetal)
float mcm_trace(vec3 origin, vec3 dir, float tmax);
// same, and cut = the alpha cutoff of the block hit (0 = solid block, else a see-through-texture block)
float mcm_trace_cut(vec3 origin, vec3 dir, float tmax, out uint cut);
// closest hit with its surface: normal, albedo (texture * tint), light (block, sky), Iris block id
float mcm_trace_hit(vec3 origin, vec3 dir, float tmax, out vec3 normal, out vec4 albedo, out vec2 lightmap,
                    out int blockId);
// as mcm_trace; on a miss, transmit = colour filter of the glass/water/ice on the way
float mcm_trace_tinted(vec3 origin, vec3 dir, float tmax, out vec3 transmit);

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

vec4 shade(float t) { return t > 0.0 ? vec4(0.0, 1.0 - clamp(t / 64.0, 0.0, 0.8), 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0); }
// solid hit green, see-through-texture hit (grass, leaves, plain glass) yellow, miss red
vec4 shade_cut(float t, uint cut) { return t > 0.0 && cut != 0u ? vec4(1.0, 1.0, 0.0, 1.0) : shade(t); }

void main() {
    vec4 color = texture(colortex0, texcoord);
#ifndef MCMETAL_RT
    if (texcoord.y < 0.15 && texcoord.x < 0.1) {          // magenta corner: Iris did not define MCMETAL_RT
        outColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
#endif
    if (texcoord.y > 0.85 && texcoord.x < 0.1) {          // camera straight down
        outColor = shade(mcm_trace(vec3(0.0), vec3(0.0, -1.0, 0.0), 256.0));
        return;
    }
    if (texcoord.y > 0.85 && texcoord.x > 0.9) {          // camera straight up
        outColor = shade(mcm_trace(vec3(0.0), vec3(0.0, 1.0, 0.0), 256.0));
        return;
    }
    if (texcoord.y < 0.3 && texcoord.x > 0.6) {           // bottom right: the picture as the rays see it
        vec4 view = gbufferProjectionInverse * vec4(vec3(texcoord, 1.0) * 2.0 - 1.0, 1.0);
        vec3 dir = normalize(mat3(gbufferModelViewInverse) * (view.xyz / view.w));
        vec3 nrm; vec4 alb; vec2 lm; int id;
        float t = mcm_trace_hit(vec3(0.0), dir, 256.0, nrm, alb, lm, id);
        // left half of the inset: albedo lit by sky/block light; right half: face normal
        outColor = t < 0.0 ? vec4(0.2, 0.3, 0.6, 1.0)
                 : texcoord.x < 0.8 ? vec4(alb.rgb * max(lm.x, lm.y), 1.0) : vec4(nrm * 0.5 + 0.5, 1.0);
        return;
    }
    float depth = texture(depthtex0, texcoord).r;
    if (depth < 1.0) {
        vec4 view = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
        view /= view.w;
        vec3 player = (gbufferModelViewInverse * view).xyz;
        vec3 toLight = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
        uint cut;
        // start the ray just off the surface: the depth buffer only gives the position to within a few mm, so starting
        // on it lets the surface shadow itself in stripes (shadow acne). Face normal from screen-space derivatives.
        vec3 n = normalize(cross(dFdx(player), dFdy(player)));
        if (dot(n, player) > 0.0) n = -n;                  // towards the camera
        vec3 origin = player + n * 0.02 + toLight * 0.01;
        float t = mcm_trace_cut(origin, toLight, 256.0, cut);
        vec4 c = shade_cut(t, cut);
        if (t < 0.0) {                                     // lit: through stained glass shows the glass colour
            vec3 tr;
            mcm_trace_tinted(origin, toLight, 256.0, tr);
            if (any(lessThan(tr, vec3(0.99)))) c = vec4(tr, 1.0);
        }
        color = mix(color, c, 0.6);
    }
    outColor = color;
}
