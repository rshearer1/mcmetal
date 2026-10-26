#version 330 compatibility
// Light shafts (god rays): sunlight scattered by the air along the view ray. The ray from the camera to the surface
// is cut into a few steps; at each, a hardware ray towards the sun says whether that bit of air is lit. Where the
// sun gets through gaps (a roof hole, leaves, a window) the lit air shows as shafts. Half resolution, a different
// step offset every frame, averaged over the last frames.
/*
const int colortex8Format = RGBA16F;   // rgb light scattered towards the camera, a distance to the camera
const bool colortex8Clear = false;
*/
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"

uniform sampler2D colortex8, depthtex0;
uniform mat4 gbufferPreviousModelView, gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

in vec2 texcoord;
flat in vec3 sunCol, skyAmb, lightDir, sunDir;

/* RENDERTARGETS: 8 */
layout(location = 0) out vec4 outScatter;

#if defined USE_RT && defined LIGHT_SHAFTS && defined CAUSTICS
    #include "/lib/caustics.glsl"
#endif
#if defined USE_RT && defined LIGHT_SHAFTS
float mcm_trace(vec3 origin, vec3 dir, float tmax);
#endif
#if defined USE_RT && defined LIGHT_SHAFTS && defined FOG_GRID
// fog grid: whether the sun reaches a bit of air is kept per half-block cell of the world round the camera (Iris
// shader storage buffer 3, a grid that wraps round as the camera moves). Each cell is traced again only every
// FOG_GRID_FRAMES frames, from a random point inside it, and keeps an average: soft beam edges, and the many view
// rays that pass through the same air share one sun ray instead of tracing their own.
#extension GL_ARB_shader_storage_buffer_object : enable
layout(std430, binding = 3) buffer FogGrid { uint fgCells[]; };   // bits 0-15 which wrap of the grid (bit 15 set),
const ivec3 FG_SIZE = ivec3(192, 96, 192);                          // 16-23 frame traced, 24-31 sun visibility
float airSunVis(vec3 q, vec3 L) {
    ivec3 c = ivec3(floor((q + cameraPosition) * 2.0));
    ivec3 m = ((c % FG_SIZE) + FG_SIZE) % FG_SIZE;
    ivec3 wrap = (c - m) / FG_SIZE;
    uint key = uint(wrap.x & 31) | (uint(wrap.y & 31) << 5) | (uint(wrap.z & 31) << 10) | 0x8000u;
    int idx = (m.y * FG_SIZE.z + m.z) * FG_SIZE.x + m.x;
    uint e = fgCells[idx];
    bool same = (e & 0xFFFFu) == key;
    float vis = float(e >> 24) / 255.0;
    if (same && ((uint(frameCounter) - (e >> 16)) & 255u) < uint(FOG_GRID_FRAMES)) return vis;
    vec3 jit = vec3(hash12b(vec2(idx & 4095, frameCounter & 1023)), hash12b(vec2(frameCounter & 1023, idx >> 12)),
                    hash12b(vec2(idx % 977, (frameCounter + 7) & 1023)));
    vec3 o = (vec3(c) + jit) * 0.5 - cameraPosition;
    float v = mcm_trace(o, L, 128.0) < 0.0 ? 1.0 : 0.0;
    vis = same ? mix(vis, v, 0.3) : v;
    fgCells[idx] = key | ((uint(frameCounter) & 255u) << 16) | (uint(vis * 255.0 + 0.5) << 24);
    return vis;
}
#endif
#if defined USE_RT && defined LIGHT_SHAFTS && defined USE_LIGHTS && defined LAMP_FOG
    #include "/lib/lights.glsl"
    #define LAMP_FOG_PASS
#endif

void main() {
    float depth = texture(depthtex0, texcoord).r;
    // the view direction from a point halfway into the depth range (the far plane itself unprojects to infinity)
    vec4 vm = gbufferProjectionInverse * vec4(texcoord * 2.0 - 1.0, 0.0, 1.0);
    vec3 dir = normalize(mat3(gbufferModelViewInverse) * (vm.xyz / vm.w));
    vec3 p = dir * 1000.0;
    if (depth < 1.0) {
        vec4 v = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
        p = mat3(gbufferModelViewInverse) * (v.xyz / v.w) + gbufferModelViewInverse[3].xyz;
    }
    float dist = min(length(p), 48.0);
    // average with last frame's value at this spot (the step offset changes every frame)
    vec3 prevPlayer = (depth < 1.0 ? p : dir * 48.0) + cameraPosition - previousCameraPosition;
    vec4 pc = gbufferPreviousProjection * (gbufferPreviousModelView * vec4(prevPlayer, 1.0));
    vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    vec4 h = texture(colortex8, puv * LIGHT_SHAFTS_SCALE);
    bool valid = depth >= 1.0 ? true : (all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0)))
              && abs(h.a - length(prevPlayer)) < 0.05 * dist + 0.2);
    if (depth >= 1.0) h = texture(colortex8, texcoord * LIGHT_SHAFTS_SCALE);
    if (any(isnan(h.rgb))) valid = false;   // never let a bad value live on in the history
    vec3 scatter = vec3(0.0);
#if defined USE_RT && defined LIGHT_SHAFTS
    // 1 in LIGHT_SHAFTS_RATE pixels each frame (like deferred1.fsh's shadows): the others keep their average
    if (valid && rayRest(gl_FragCoord.xy, LIGHT_SHAFTS_RATE, frameCounter)) {
        outScatter = vec4(h.rgb, depth < 1.0 ? length(p) : 48.0);
        return;
    }
#endif
#if defined USE_RT && defined LIGHT_SHAFTS
    bool underWater = isEyeInWater == 1;
  #ifndef CAUSTICS
    underWater = false;
  #endif
    if ((isEyeInWater == 0 || underWater) && dot(sunCol, sunCol) > 1e-6) {
        // Henyey-Greenstein phase: most light scatters a little off the sun's direction (bright towards the sun)
        float g = 0.65, mu = dot(dir, lightDir);
        float phase = 0.3 / (4.0 * PI) + 0.7 * (1.0 - g * g) / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
        // thicker indoors (dusty air, and the eye adapts to the dark), so shafts through a roof hole show
        float indoors = 1.0 - float(eyeBrightnessSmooth.y) / 240.0;
        // clear air at midday, hazier with a low sun (morning, evening) and in rain
        float density = 0.005 * (LIGHT_SHAFTS_STRENGTH * STYLE_SHAFTS) * mix(1.0, 0.25, smoothstep(0.25, 0.7, lightDir.y))
                      * (1.0 + 3.0 * rainStrength + 3.0 * indoors);
        // under water: much thicker (the beams you see from below the surface), and blue-green
        if (underWater) { dist = min(dist, 32.0); density = 0.04 * (LIGHT_SHAFTS_STRENGTH * STYLE_SHAFTS); }
        // SHAFT_BUDGET: rays where the air is: a short view ray (indoors, a wall close by) gets a step every
        // SHAFT_STEP_LENGTH blocks instead of the full count, so rooms and close-up views trace far fewer sun rays
        int steps = LIGHT_SHAFTS_STEPS;
  #ifdef SHAFT_BUDGET
        steps = clamp(int(ceil(dist / SHAFT_STEP_LENGTH)), 2, LIGHT_SHAFTS_STEPS);
  #endif
        float stepLen = dist / float(steps);
        // ground mist the sun's beams show in (SEUS's misty mornings): thick air in the lowest few blocks above sea
        // level, around sunrise, in rain, and with the look's own ground mist; it thins out over 6 blocks of height
        float mist = 0.0;
  #ifdef VOLUMETRIC_MIST
        float wt = float(worldTime);
        float dawn = max(smoothstep(22000.0, 23200.0, wt), 1.0 - smoothstep(1000.0, 3500.0, wt));
        if (!underWater && hasSkylight) mist = 0.015 * MIST_AMOUNT * (dawn + 0.5 * rainStrength + 0.5 * STYLE_GROUND_MIST);
  #endif
        float litMist = 0.0, skyMist = 0.0, od = 0.0;
        float jitter = ign(valid ? rayPixel(gl_FragCoord.xy, LIGHT_SHAFTS_RATE) : gl_FragCoord.xy, frameCounter);
        float lit = 0.0;
        for (int i = 0; i < steps; i++) {
            float t = (float(i) + jitter) * stepLen;
            // air further away is seen through more air (the haze in composite1.fsh adds the rest)
            float md = mist > 0.0 ? mist * exp(-max(dir.y * t + cameraPosition.y - 62.0, 0.0) / 6.0) : 0.0;
            od += md * stepLen;
            float vis = exp(-t * density - od);
            float through = vis;
            skyMist += vis * md;   // mist in shade still glows with the sky's light
  #ifdef CAUSTICS
            // under water the light comes down in the waves' focused lines: shafts even with nothing in the way
            if (underWater) through *= 3.5 * caustics(dir * t + cameraPosition, lightDir, frameTimeCounter);
  #endif
  #ifdef FOG_GRID
            float sv = airSunVis(dir * t, lightDir);
            lit += through * sv; litMist += through * md * sv;
  #else
            if (mcm_trace(dir * t, lightDir, 128.0) < 0.0) { lit += through; litMist += through * md; }   // (what's further off barely shades the air you see)
  #endif
        }
        // a beam in shade (sun through a roof hole or a gap in the trees) stands out the way it does in real dusty
        // air: the less of the view ray is lit, the more each lit step counts. Open air (all lit) stays clear
        // (dust that only shows in a beam: 0.05 per block where the view ray is all in shade)
        float shade = 1.0 - lit / float(steps);
        // (cubed: a view ray that starts in open sunlight and then enters a room shouldn't haze the whole room)
        float beam = underWater ? 0.0 : 0.05 * (LIGHT_SHAFTS_STRENGTH * STYLE_SHAFTS) * shade * shade * shade;
        scatter = sunCol * (underWater ? vec3(0.1, 0.26, 0.32) : vec3(1.0)) * phase * ((density + beam) * lit + litMist) * stepLen * 4.0 * PI;   // x 4pi: our lights skip the 1/pi of diffuse
        scatter += skyAmb * skyMist * stepLen;
    }
  #ifdef LAMP_FOG_PASS
    // lamp-lit air: the light of the nearest torch, lantern or glowing block, scattered by the air and mist round
    // it, so lamps glow in fog, dusty rooms and at night. A few steps over the first 24 blocks, each with a
    // shadow ray to that light (walls cut the glow off)
    {
        float ld = min(dist, 24.0), lstep = ld / 4.0;
        float air = 0.012 * LAMP_FOG_STRENGTH * (1.0 + 3.0 * rainStrength + 2.0 * (1.0 - float(eyeBrightnessSmooth.y) / 240.0));
        float lj = ign(gl_FragCoord.xy + vec2(13.0, 71.0), frameCounter);
        for (int i = 0; i < 4; i++) {
            vec3 q = dir * ((float(i) + lj) * lstep);
            vec3 lp; int lid;
            if (mcm_lights_near(q, 0, lp, lid) < 0) continue;
            vec3 to = lp - q;
            float d2 = max(dot(to, to), 0.25), d = sqrt(d2);
            float level;
            vec3 lc = lightColorOf(lid, level);
            if (mcm_trace(q, to / d, max(d - 0.6, 0.0)) >= 0.0) continue;   // a wall between
            scatter += lc * (level / 15.0) * air * lstep * BLOCK_LIGHT_STRENGTH / d2 * exp(-float(i) * lstep * 0.02);
        }
    }
  #endif
    if (any(isnan(scatter)) || any(isinf(scatter))) scatter = vec3(0.0);
#endif
    outScatter = vec4(valid ? mix(h.rgb, scatter, LIGHT_SHAFTS_BLEND) : scatter, depth < 1.0 ? length(p) : 48.0);
}
