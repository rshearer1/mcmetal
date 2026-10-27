// Sun/moon shadow for fragment shaders: a hardware ray through mcmetal, or the fallback shadow map.
// Needs settings, common, uniforms. Only include in fragment shaders (mcmetal adds ray tracing to any stage that names mcm_trace).
#ifdef USE_RT
// supplied by mcmetal: distance to the first solid or cutout block along dir (player space), or -1; on a miss,
// transmit = the colour light keeps after passing every glass/water/ice face on the way
float mcm_trace_tinted(vec3 origin, vec3 dir, float tmax, out vec3 transmit);
float mcm_trace(vec3 origin, vec3 dir, float tmax);

vec3 sunShadow(vec3 p, vec3 n, vec3 L, int mat) {
    // start just off the surface: the depth buffer only knows the position to a few mm, which would let a surface
    // shadow itself in stripes (acne). Plants have no real side, so push them towards the light instead.
    vec3 o = mat == MAT_FOLIAGE ? p + L * 0.06 : p + n * 0.02 + L * 0.01;
    o += L * ownBodySkip(p, mat);
#ifdef COLORED_SHADOWS
    vec3 transmit;
    return mcm_trace_tinted(o, L, 256.0, transmit) > 0.0 ? vec3(0.0) : transmit;
#else
    return mcm_trace(o, L, 256.0) > 0.0 ? vec3(0.0) : vec3(1.0);
#endif
}
#else
uniform sampler2DShadow shadowtex1;

vec3 distortShadow(vec3 s) { return vec3(s.xy / (length(s.xy) * 0.9 + 0.1), s.z * 0.25); }

vec3 sunShadow(vec3 p, vec3 n, vec3 L, int mat) {
    float dist = length(p);
    vec3 o = mat == MAT_FOLIAGE ? p : p + n * (0.03 + dist * 0.002);
    vec4 s = shadowProjection * (shadowModelView * vec4(o, 1.0));
    s.xyz = distortShadow(s.xyz / s.w) * 0.5 + 0.5;
    if (any(lessThan(s.xy, vec2(0.0))) || any(greaterThan(s.xy, vec2(1.0)))) return vec3(1.0);
    float r = 1.0 / float(shadowMapResolution), a = ign(gl_FragCoord.xy, frameCounter) * 6.2832, sum = 0.0;
    for (int i = 0; i < 4; i++) {
        float ang = a + float(i) * 1.5708;
        sum += texture(shadowtex1, vec3(s.xy + vec2(cos(ang), sin(ang)) * r * 1.2, s.z - 0.0004));
    }
    return vec3(mix(sum * 0.25, 1.0, smoothstep(shadowDistance * 0.85, shadowDistance, dist)));
}
#endif
