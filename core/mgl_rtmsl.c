/* mcm_trace on Metal's intersector (Apple's advice for ray tracing on Apple GPUs).

   SPIRV-Cross turns the GLSL ray query in mcm_rq (core/mgl_program.c) into Metal's intersection_query: our own
   loop runs the alpha test of every candidate triangle inside the calling shader. Apple's M3 talks say queries
   can't be sorted or grouped and need more scratch memory (so fewer threads in flight); the intersector with
   small intersection functions is the fast path. This rewrites the MSL of a fragment or compute stage:
   - every function that takes the scene (mcm_scene) also takes an intersection function table, mcm_ift, bound
     at [[buffer(table_index)]] in main0, and every call passes it on;
   - mcm_rq's body becomes one intersector call; solid triangles (built opaque) never leave the ray hardware,
     cutout and translucent ones run mcm_any_hit, the table's only function (index 0);
   - mcm_any_hit does what the query loop did: Sodium's alpha test against the block atlas, and on translucent
     faces (tinted rays, mask 3) the colour filter, never accepting them.
   The atlas and the per-instance triangle data reach mcm_any_hit in the ray payload, so the table holds no
   buffers and never changes after the pipeline is made. */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mgl_xlate.h"

typedef struct sbuf { char *s; size_t n, cap; } sbuf;

static void put(sbuf *b, const char *s, size_t n)
{
    if (b->n + n + 1 > b->cap) {
        b->cap = (b->n + n + 1) * 2;
        b->s = realloc(b->s, b->cap);
    }
    memcpy(b->s + b->n, s, n);
    b->n += n;
    b->s[b->n] = 0;
}

static void puts_(sbuf *b, const char *s) { put(b, s, strlen(s)); }

static int ident(char c) { return isalnum((unsigned char)c) || c == '_'; }

#define IFT_TYPE "raytracing::intersection_function_table<raytracing::triangle_data, raytracing::instancing>"
#define AS_TYPE "acceleration_structure<raytracing::instancing> "

/* thread mcm_ift wherever mcm_scene goes */
static char *thread_table(const char *msl, int table_index)
{
    sbuf o = {0};
    const char *p = msl, *q;
    int decls = 0;
    while ((q = strstr(p, "mcm_scene"))) {
        const char *end = q + 9;
        if ((q > msl && ident(q[-1])) || ident(*end)) { /* part of a longer name */
            put(&o, p, (size_t)(end - p));
            p = end;
            continue;
        }
        size_t al = strlen(AS_TYPE);
        int decl = (size_t)(q - msl) >= al && !strncmp(q - al, AS_TYPE, al);
        if (decl && !strncmp(end, " [[buffer(", 10)) { /* main0's argument */
            const char *close = strstr(end, "]]");
            if (!close) {
                free(o.s);
                return NULL;
            }
            put(&o, p, (size_t)(close + 2 - p));
            char extra[160];
            snprintf(extra, sizeof extra, ", " IFT_TYPE " mcm_ift [[buffer(%d)]]", table_index);
            puts_(&o, extra);
            p = close + 2;
            decls++;
            continue;
        }
        put(&o, p, (size_t)(end - p));
        p = end;
        if (decl) {
            puts_(&o, ", " IFT_TYPE " mcm_ift");
            decls++;
        } else {
            const char *n = end;
            while (*n == ' ')
                n++;
            if (*n == ',' || *n == ')') /* passed to a function */
                puts_(&o, ", mcm_ift");
        }
    }
    puts_(&o, p);
    if (!decls) {
        free(o.s);
        return NULL;
    }
    return o.s;
}

/* the name a parameter declares: its last identifier */
static void param_name(const char *a, const char *b, char *out, size_t cap)
{
    while (b > a && !ident(b[-1]))
        b--;
    const char *s = b;
    while (s > a && ident(s[-1]))
        s--;
    size_t n = (size_t)(b - s) < cap - 1 ? (size_t)(b - s) : cap - 1;
    memcpy(out, s, n);
    out[n] = 0;
}

static const char hit_fn[] =
    "\n/* mcmetal: the alpha test and colour filter of mcm_trace, as an intersection function (mgl_rtmsl.c) */\n"
    "struct McmRayPayload { float3 transmit; const device McmInstances *ins; texture2d<float> atlas; };\n"
    "[[intersection(triangle, triangle_data, instancing)]]\n"
    "bool mcm_any_hit(uint inst [[instance_id]], uint prim [[primitive_id]], float2 w [[barycentric_coord]],\n"
    "                 ray_data McmRayPayload &pl [[payload]]) {\n"
    "  const device McmTris *t = pl.ins->mcm_tris[inst];\n"
    "  uint b = prim * 12u, flags = t->w[b + 3u], cut = flags & 0xFFu;\n"
    "  bool tinted = (flags & 0x100u) != 0u;\n"
    "  if (!tinted && cut == 0u) return true;\n"
    "  float3 wv = float3(1.0 - w.x - w.y, w.x, w.y);\n"
    "  float2 uv = (unpack_unorm2x16_to_float(t->w[b]) * wv.x + unpack_unorm2x16_to_float(t->w[b + 1u]) * wv.y\n"
    "             + unpack_unorm2x16_to_float(t->w[b + 2u]) * wv.z) * (65535.0 / 32768.0);\n"
    "  constexpr sampler s(coord::normalized, filter::nearest, address::repeat);\n"
    "  float4 tex = pl.atlas.sample(s, uv, level(0.0));\n"
    "  if (tinted) {\n"
    "    float3 c = unpack_unorm4x8_to_float(t->w[b + 4u]).rgb * wv.x + unpack_unorm4x8_to_float(t->w[b + 5u]).rgb * wv.y\n"
    "             + unpack_unorm4x8_to_float(t->w[b + 6u]).rgb * wv.z;\n"
    "    pl.transmit *= mix(float3(1.0), tex.rgb * c, tex.a);\n"
    "    return false;\n"
    "  }\n"
    "  return tex.a >= (cut == 3u ? 1.0 : 0.1);\n"
    "}\n\n";

char *mgl_rt_native_msl(const char *msl, int table_index)
{
    if (!msl || !strstr(msl, "float mcm_rq(") || !strstr(msl, "intersection_query<") || strstr(msl, "mcm_any_hit"))
        return NULL;
    char *t = thread_table(msl, table_index);
    if (!t)
        return NULL;
    char *def = strstr(t, "float mcm_rq(");
    char *open = def ? def + 12 : NULL, *close = NULL;
    int depth = 0;
    for (char *c = open; c && *c; c++) {
        if (*c == '(')
            depth++;
        else if (*c == ')' && --depth == 0) {
            close = c;
            break;
        }
    }
    char *body = close ? strstr(close, "\n{") : NULL;
    if (!body || body - close > 4) {
        free(t);
        return NULL;
    }
    body++;
    /* parameters: o, d, tmax, kind, inst, prim, w, transmit, then the resources SPIRV-Cross passes down */
    char user[8][64] = {{0}}, scene[64] = "", ins[64] = "", atlas[64] = "", ift[64] = "";
    int np = 0, angle = 0;
    const char *a = open + 1;
    for (const char *c = a; c <= close; c++) {
        if (*c == '<')
            angle++;
        else if (*c == '>')
            angle--;
        else if ((*c == ',' && angle == 0) || c == close) {
            char name[64];
            param_name(a, c, name, sizeof name);
            size_t len = (size_t)(c - a);
            char decl[512];
            snprintf(decl, sizeof decl, "%.*s", (int)(len < sizeof decl ? len : sizeof decl - 1), a);
            if (np < 8)
                snprintf(user[np], sizeof user[np], "%s", name);
            else if (strstr(decl, "acceleration_structure"))
                snprintf(scene, sizeof scene, "%s", name);
            else if (strstr(decl, "McmInstances"))
                snprintf(ins, sizeof ins, "%s", name);
            else if (strstr(decl, "intersection_function_table"))
                snprintf(ift, sizeof ift, "%s", name);
            else if (strstr(decl, "texture2d<float>") && strstr(name, "mcm_atlas"))
                snprintf(atlas, sizeof atlas, "%s", name);
            np++;
            a = c + 1;
        }
    }
    if (np < 8 || !*scene || !*ins || !*atlas || !*ift) {
        free(t);
        return NULL;
    }
    depth = 0;
    char *bend = NULL;
    for (char *c = body; *c; c++) {
        if (*c == '{')
            depth++;
        else if (*c == '}' && --depth == 0) {
            bend = c + 1;
            break;
        }
    }
    if (!bend) {
        free(t);
        return NULL;
    }
    /* kind as in mcm_rq: 1 and 3 closest hit, 2 and 3 every triangle solid, 4 tinted (masks 1 and 2) */
    char nb[2048];
    snprintf(nb, sizeof nb,
             "{\n"
             "    raytracing::intersector<raytracing::triangle_data, raytracing::instancing> it;\n"
             "    it.assume_geometry_type(raytracing::geometry_type::triangle);\n"
             "    it.accept_any_intersection(%4$s != 1u && %4$s != 3u);\n"
             "    if (%4$s == 2u || %4$s == 3u)\n"
             "        it.force_opacity(raytracing::forced_opacity::opaque);\n"
             "    McmRayPayload pl;\n"
             "    pl.transmit = %8$s;\n"
             "    pl.ins = &%10$s;\n"
             "    pl.atlas = %11$s;\n"
             "    raytracing::intersection_result<raytracing::triangle_data, raytracing::instancing> h =\n"
             "        it.intersect(raytracing::ray(%1$s, %2$s, 0.001, %3$s), %9$s, %4$s == 4u ? 3u : 1u, %12$s, pl);\n"
             "    %8$s = pl.transmit;\n"
             "    %5$s = 0u;\n"
             "    %6$s = 0u;\n"
             "    %7$s = float2(0.0);\n"
             "    if (h.type == raytracing::intersection_type::none)\n"
             "        return -1.0;\n"
             "    %5$s = h.instance_id;\n"
             "    %6$s = h.primitive_id;\n"
             "    %7$s = h.triangle_barycentric_coord;\n"
             "    return h.distance;\n"
             "}",
             user[0], user[1], user[2], user[3], user[4], user[5], user[6], user[7], scene, ins, atlas, ift);
    /* the payload and intersection function go before mcm_rq (after the structs they use) */
    char *line = def, *prev = def - 1; /* "static inline __attribute__((always_inline))\nfloat mcm_rq(" */
    while (prev > t && prev[-1] != '\n')
        prev--;
    if (prev > t && !strncmp(prev, "static inline", 13))
        line = prev;
    sbuf o = {0};
    put(&o, t, (size_t)(line - t));
    puts_(&o, hit_fn);
    put(&o, line, (size_t)(body - line));
    puts_(&o, nb);
    puts_(&o, bend);
    free(t);
    return o.s;
}
