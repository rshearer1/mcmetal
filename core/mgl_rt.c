/* Step 2 groundwork: capture Sodium/Iris terrain geometry for ray tracing (see STEP2-RAYTRACING.md).

   Terrain programs are recognised at link time (vertex input a_Position + uniform u_RegionOffset). Every draw
   with such a program is recorded as a section draw: vertex buffer + stride, index range, base vertex and the
   camera-relative region origin. Vertex layout (Sodium CompactChunkVertex; Iris appends fields after byte 20):
     byte 0  : x/y/z high 10 bits     byte 4 : x/y/z low 10 bits     (20-bit, value * 32 / 2^20 - 8)
     byte 8  : colour RGBA8 (biome tint; AO in rgb, or in alpha with Iris separate AO)
     byte 12 : texture u/v (15 bits + sign each)
     byte 16 : light (block, sky bytes), material (8; Iris: tangent sign bit), section index (8)
               -> section offset 16 * ((i>>5)&7, i&3, (i>>2)&7)
   The Metal backend will build acceleration structures from this list; for now the list can be checked
   without a GPU: MGL_RT_SNAPSHOT=/path/out.ppm, then `touch /path/out.ppm.go` while the game runs, and the
   next terrain draw rasterises everything recorded in the last second, seen through the camera, on the CPU. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "mgl_state.h"

typedef struct rt_draw {
    mgl_rt_geom g;
    double seen;
} rt_draw;

static rt_draw *draws;
static int num_draws, cap_draws;
static double scene_wanted;  /* last time a program that casts rays was drawn; capture runs only around it */
static float view_proj[16];
static int have_view;

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int uniform_offset(const mgl_program *p, const char *name)
{
    for (int i = 0; i < p->x.num_uniforms; i++)
        if (!strcmp(p->x.uniforms[i].name, name))
            return p->x.uniforms[i].offset[MGL_VERTEX];
    return -1;
}

void mgl_rt_link(mgl_program *p)
{
    p->rt_pos_loc = p->rt_ent_loc = -1;
    for (int i = 0; i < p->x.num_attribs; i++) {
        if (!strcmp(p->x.attribs[i].name, "a_Position") && p->x.attribs[i].is_int && p->x.attribs[i].vecsize == 2)
            p->rt_pos_loc = p->x.attribs[i].location;
        if (!strcmp(p->x.attribs[i].name, "iris_Entity") || !strcmp(p->x.attribs[i].name, "mc_Entity"))
            p->rt_ent_loc = p->x.attribs[i].location; /* only there when the pack's terrain shader reads mc_Entity */
    }
    p->rt_region_off = uniform_offset(p, "u_RegionOffset");
    p->rt_mv_off = uniform_offset(p, "iris_ModelViewMatrix");
    p->rt_proj_off = uniform_offset(p, "iris_ProjectionMatrix");
    if (p->rt_mv_off < 0 || p->rt_proj_off < 0) {
        p->rt_mv_off = uniform_offset(p, "u_ModelViewMatrix");
        p->rt_proj_off = uniform_offset(p, "u_ProjectionMatrix");
    }
    if (p->rt_pos_loc < 0 || p->rt_region_off < 0)
        p->rt_pos_loc = -1; /* not a terrain program */
}

static void mat_mul(float *o, const float *a, const float *b) /* column-major o = a * b */
{
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++) {
            float s = 0;
            for (int k = 0; k < 4; k++)
                s += a[k * 4 + r] * b[c * 4 + k];
            o[c * 4 + r] = s;
        }
}

static void snapshot(const char *path);

/* MGL_RT_DEBUG=1: once a second, log what the capture saw (draws taken, skipped and why, sections kept). */
static struct { unsigned long taken, not_terrain, not_tris, no_attr, small_stride, idle; char last_skip[64]; } rtd;
static int rt_debug(void)
{
    static int on = -1;
    if (on < 0)
        on = getenv("MGL_RT_DEBUG") && atoi(getenv("MGL_RT_DEBUG"));
    return on;
}

static int num_draws_fwd(void);
static void rt_debug_tick(void)
{
    if (!rt_debug())
        return;
    static double last_log;
    double now = now_s();
    if (now - last_log > 1.0) {
        mgl_log("rt debug: last %.1f s: %lu terrain draws taken; skipped %lu not terrain (last %s), %lu not indexed "
                "triangles, %lu no position attribute, %lu stride < 20, %lu before a ray-tracing shader; %d sections kept",
                now - last_log, rtd.taken, rtd.not_terrain, rtd.last_skip[0] ? rtd.last_skip : "-", rtd.not_tris,
                rtd.no_attr, rtd.small_stride, rtd.idle, num_draws_fwd());
        if (rt_debug() < 2) { /* level 2: the vertex scans below (slow, and they read every captured buffer) */
            memset(&rtd, 0, sizeof rtd);
            last_log = now;
            return;
        }
        /* the material byte Sodium packs beside the section index (alpha cutoff in bits 1-2), over the captured
           vertices: shows whether cutout blocks carry a cutoff here */
        unsigned long hist[256] = {0}, stride_seen = 0;
        for (int i = 0; i < num_draws; i++) {
            const unsigned char *base = mglb_buffer_ptr(draws[i].g.vbuf);
            if (!base)
                continue;
            stride_seen = (unsigned long)draws[i].g.stride;
            int nv = draws[i].g.count * 2 / 3;
            for (int v = 0; v < nv; v++) {
                const uint32_t *w = (const uint32_t *)(base + draws[i].g.vbase +
                                                       (size_t)(draws[i].g.base_vertex + v) * (size_t)draws[i].g.stride);
                hist[(w[4] >> 16) & 0xFF]++;
            }
        }
        char line[512];
        int o = snprintf(line, sizeof line, "rt debug: material bytes (stride %lu):", stride_seen);
        for (int m = 0; m < 256 && o < (int)sizeof line - 24; m++)
            if (hist[m])
                o += snprintf(line + o, sizeof line - (size_t)o, " 0x%02x x%lu", m, hist[m]);
        mgl_log("%s", line);
        /* the block ids the light list sees (Iris's word >> 1, minus 1): shows whether MCMETAL_LIGHT_IDS matches */
        unsigned long with_ent = 0, in_range = 0, nv_all = 0;
        uint32_t ids[8], raw0 = 0;
        int nids = 0, ent_off = -1;
        for (int i = 0; i < num_draws; i++) {
            const unsigned char *base = mglb_buffer_ptr(draws[i].g.vbuf);
            if (!base || draws[i].g.ent_off < 0)
                continue;
            with_ent++;
            ent_off = draws[i].g.ent_off;
            int nv = draws[i].g.count * 2 / 3;
            for (int v = 0; v < nv; v++) {
                uint32_t w = *(const uint32_t *)(base + draws[i].g.vbase + draws[i].g.ent_off +
                                                 (size_t)(draws[i].g.base_vertex + v) * (size_t)draws[i].g.stride);
                int id = (int)(w >> 1) - 1;
                nv_all++;
                if (id >= mgl_rt_light_ids[0] && id <= mgl_rt_light_ids[1])
                    in_range++;
                int k = 0;
                while (k < nids && ids[k] != (uint32_t)id)
                    k++;
                if (k == nids && nids < 8) {
                    if (!nids)
                        raw0 = w;
                    ids[nids++] = (uint32_t)id;
                }
            }
        }
        o = snprintf(line, sizeof line, "rt debug: %lu sections with block ids (offset %d, first word 0x%08x), "
                     "%lu of %lu vertices in the light range %d-%d; ids seen:", with_ent, ent_off, raw0, in_range,
                     nv_all, mgl_rt_light_ids[0], mgl_rt_light_ids[1]);
        for (int k = 0; k < nids && o < (int)sizeof line - 16; k++)
            o += snprintf(line + o, sizeof line - (size_t)o, " %d", (int)ids[k]);
        mgl_log("%s", line);
        memset(&rtd, 0, sizeof rtd);
        last_log = now;
    }
}

mglb_texture *mgl_rt_atlas;
int mgl_rt_light_ids[2] = {-1, -1};
float mgl_rt_radius;

void mgl_rt_record(mgl_program *p, const mgl_draw *d)
{
    rt_debug_tick();
    if (p && p->x.uses_scene)
        scene_wanted = now_s();
    static int snap_env = -1;
    if (snap_env < 0)
        snap_env = getenv("MGL_RT_SNAPSHOT") != NULL;
    if (!snap_env && (!scene_wanted || now_s() - scene_wanted > 5.0)) {
        rtd.idle++;
        return; /* no ray-tracing shader in use: capture costs nothing */
    }
    if (!p || p->rt_pos_loc < 0 || !p->ublock[MGL_VERTEX]) {
        rtd.not_terrain++;
        if (p && rt_debug())
            snprintf(rtd.last_skip, sizeof rtd.last_skip, "%d attribs, first %s, region %d", p->x.num_attribs,
                     p->x.num_attribs ? p->x.attribs[0].name : "-", p->rt_region_off);
        return;
    }
    if (d->primitive != GL_TRIANGLES || !d->index_buf) {
        rtd.not_tris++;
        return;
    }
    const mgl_vertex_attr *a = &d->attrs[p->rt_pos_loc];
    if (!a->enabled || a->buffer < 0 || a->buffer >= d->num_vbufs) {
        rtd.no_attr++;
        return;
    }
    if (d->vbufs[a->buffer].stride < 20) {
        rtd.small_stride++;
        return;
    }
    rtd.taken++;
    for (int i = 0; i < p->x.num_textures; i++) { /* the block atlas, for mcm_trace's alpha test */
        const mgl_texture_slot *slot = &p->x.textures[i];
        int idx = slot->msl_index[MGL_FRAGMENT];
        if (idx >= 0 && idx < MGL_MAX_TEXTURES && d->textures[MGL_FRAGMENT][idx].tex &&
            (!strcmp(slot->name, "u_BlockTex") || !strcmp(slot->name, "gtexture") || !strcmp(slot->name, "tex") ||
             !strcmp(slot->name, "texture")))
            mgl_rt_atlas = d->textures[MGL_FRAGMENT][idx].tex;
    }
    const mgl_vertex_buf *vb = &d->vbufs[a->buffer];
    int ent_off = -1; /* Iris: ((id + 1) << 1) | render type, 4 bytes */
    if (p->rt_ent_loc >= 0) {
        const mgl_vertex_attr *e = &d->attrs[p->rt_ent_loc];
        if (e->enabled && e->buffer == a->buffer && e->offset >= a->offset && !((e->offset - a->offset) & 3))
            ent_off = (int)(e->offset - a->offset);
    }
    const float *region = (const float *)(p->ublock[MGL_VERTEX] + p->rt_region_off);
    double t = now_s();

    /* camera: the terrain pass drawing into a window-sized target (the shadow map is square) */
    int ww, wh;
    mglb_window_size(&ww, &wh);
    if (p->rt_mv_off >= 0 && p->rt_proj_off >= 0 && d->target.width == ww && d->target.height == wh) {
        mat_mul(view_proj, (const float *)(p->ublock[MGL_VERTEX] + p->rt_proj_off),
                (const float *)(p->ublock[MGL_VERTEX] + p->rt_mv_off));
        have_view = 1;
    }

    rt_draw key = {{vb->buf, d->index_buf, vb->offset + (size_t)a->offset, vb->stride, d->index_offset,
                    d->index_type, d->count, d->base_vertex, 0, {region[0], region[1], region[2]},
                    d->blend[0].enabled, ent_off}, t};
    for (int i = 0; i < num_draws; i++) {
        rt_draw *r = &draws[i];
        if (r->g.vbuf == key.g.vbuf && r->g.vbase == key.g.vbase && r->g.base_vertex == key.g.base_vertex &&
            r->g.ioff == key.g.ioff && r->g.count == key.g.count && r->g.ibuf == key.g.ibuf &&
            r->g.translucent == key.g.translucent) {
            memcpy(r->g.region, key.g.region, sizeof r->g.region);
            if (key.g.ent_off >= 0 && r->g.ent_off != key.g.ent_off) { /* passes without mc_Entity keep it */
                r->g.ent_off = key.g.ent_off;
                r->g.gen++;
            }
            r->seen = t;
            goto recorded;
        }
    }
    if (num_draws == cap_draws) {
        cap_draws = cap_draws ? cap_draws * 2 : 1024;
        draws = realloc(draws, sizeof *draws * (size_t)cap_draws);
    }
    draws[num_draws++] = key;
recorded:;
    /* forget sections not drawn for 2 s (unloaded, rebuilt elsewhere, or behind every pass) */
    static double last_prune;
    if (t - last_prune > 1.0) {
        int n = 0;
        for (int i = 0; i < num_draws; i++)
            if (t - draws[i].seen < 2.0)
                draws[n++] = draws[i];
        num_draws = n;
        last_prune = t;
    }
    const char *snap = getenv("MGL_RT_SNAPSHOT");
    if (snap) {
        char go[600];
        snprintf(go, sizeof go, "%s.go", snap);
        if (!access(go, F_OK)) {
            unlink(go);
            snapshot(snap);
        }
    }
}

/* Vertex data written: sections whose vertices may overlap the range get a new generation (rebuilt). */
void mgl_rt_note_write(mglb_buffer *m, size_t offset, size_t size)
{
    for (int i = 0; i < num_draws; i++) {
        mgl_rt_geom *g = &draws[i].g;
        if (g->vbuf != m)
            continue;
        /* Sodium draws quads: 4 vertices per 6 indices, starting at the base vertex */
        size_t lo = g->vbase + (size_t)g->base_vertex * (size_t)g->stride;
        size_t hi = lo + ((size_t)g->count * 2 / 3 + 4) * (size_t)g->stride;
        if (offset < hi && (size == (size_t)-1 || offset + size > lo))
            g->gen++;
    }
}

static int num_draws_fwd(void) { return num_draws; }

void mgl_rt_end_frame(void)
{
    rt_debug_tick();
    if (!scene_wanted || now_s() - scene_wanted > 5.0 || !num_draws)
        return;
    static mgl_rt_geom *list;
    static int cap;
    if (cap < num_draws) {
        cap = num_draws * 2;
        list = realloc(list, sizeof *list * (size_t)cap);
    }
    for (int i = 0; i < num_draws; i++)
        list[i] = draws[i].g;
    mglb_rt_update(list, num_draws);
}

/* ---------------------------------------------------------------- CPU check: rasterise the captured scene */

static int decode(const mgl_rt_geom *r, uint32_t v, float out[3])
{
    const unsigned char *base = mglb_buffer_ptr(r->vbuf);
    if (!base)
        return 0;
    const uint32_t *w = (const uint32_t *)(base + r->vbase + (size_t)v * (size_t)r->stride);
    uint32_t hi = w[0], lo = w[1], sec = w[4] >> 24;
    for (int c = 0; c < 3; c++) {
        uint32_t q = (((hi >> (10 * c)) & 0x3FF) << 10) | ((lo >> (10 * c)) & 0x3FF);
        out[c] = (float)q * (32.0f / 1048576.0f) - 8.0f;
    }
    out[0] += 16.0f * (float)((sec >> 5) & 7) + r->region[0];
    out[1] += 16.0f * (float)(sec & 3) + r->region[1];
    out[2] += 16.0f * (float)((sec >> 2) & 7) + r->region[2];
    return 1;
}

static void snapshot(const char *path)
{
    const int W = 640, H = 360;
    float *zb = malloc(sizeof(float) * W * H);
    unsigned char *img = calloc(1, (size_t)W * H * 3);
    for (int i = 0; i < W * H; i++)
        zb[i] = 1e30f;
    double t = now_s();
    long tris = 0, used = 0;
    for (int di = 0; di < num_draws; di++) {
        const rt_draw *rd = &draws[di];
        const mgl_rt_geom *r = &rd->g;
        if (t - rd->seen > 1.0 || !have_view)
            continue;
        used++;
        const unsigned char *ib = mglb_buffer_ptr(r->ibuf);
        if (!ib)
            continue;
        for (int k = 0; k + 2 < r->count; k += 3) {
            float wp[3][3], sx[3], sy[3], sz[3];
            int ok = 1;
            for (int j = 0; j < 3; j++) {
                size_t at = r->ioff + (size_t)(k + j) * (r->itype == GL_UNSIGNED_SHORT ? 2 : 4);
                uint32_t idx = r->itype == GL_UNSIGNED_SHORT ? *(const uint16_t *)(ib + at) : *(const uint32_t *)(ib + at);
                if (!decode(r, idx + (uint32_t)r->base_vertex, wp[j])) { ok = 0; break; }
                const float *m = view_proj;
                float cx = m[0] * wp[j][0] + m[4] * wp[j][1] + m[8] * wp[j][2] + m[12];
                float cy = m[1] * wp[j][0] + m[5] * wp[j][1] + m[9] * wp[j][2] + m[13];
                float cw = m[3] * wp[j][0] + m[7] * wp[j][1] + m[11] * wp[j][2] + m[15];
                if (cw < 0.05f) { ok = 0; break; }
                sx[j] = (cx / cw * 0.5f + 0.5f) * W;
                sy[j] = (0.5f - cy / cw * 0.5f) * H;
                sz[j] = cw;
            }
            if (!ok)
                continue;
            tris++;
            /* flat shade by the face normal so block shapes are readable */
            float e1[3] = {wp[1][0] - wp[0][0], wp[1][1] - wp[0][1], wp[1][2] - wp[0][2]};
            float e2[3] = {wp[2][0] - wp[0][0], wp[2][1] - wp[0][1], wp[2][2] - wp[0][2]};
            float n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
            float nl = sqrtf(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]) + 1e-9f;
            float shade = 0.35f + 0.65f * fabsf(0.3f * n[0] + 0.85f * n[1] + 0.45f * n[2]) / nl;
            int x0 = (int)fmaxf(0, floorf(fminf(sx[0], fminf(sx[1], sx[2]))));
            int x1 = (int)fminf(W - 1, ceilf(fmaxf(sx[0], fmaxf(sx[1], sx[2]))));
            int y0 = (int)fmaxf(0, floorf(fminf(sy[0], fminf(sy[1], sy[2]))));
            int y1 = (int)fminf(H - 1, ceilf(fmaxf(sy[0], fmaxf(sy[1], sy[2]))));
            float area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0]);
            if (fabsf(area) < 1e-6f || x1 - x0 > W || y1 - y0 > H)
                continue;
            for (int y = y0; y <= y1; y++)
                for (int x = x0; x <= x1; x++) {
                    float px = x + 0.5f, py = y + 0.5f;
                    float w0 = ((sx[1] - px) * (sy[2] - py) - (sx[2] - px) * (sy[1] - py)) / area;
                    float w1 = ((sx[2] - px) * (sy[0] - py) - (sx[0] - px) * (sy[2] - py)) / area;
                    float w2 = 1 - w0 - w1;
                    if (w0 < 0 || w1 < 0 || w2 < 0)
                        continue;
                    float z = w0 * sz[0] + w1 * sz[1] + w2 * sz[2];
                    if (z >= zb[y * W + x])
                        continue;
                    zb[y * W + x] = z;
                    float fog = fmaxf(0.25f, 1.0f - z / 400.0f);
                    unsigned char *o = img + (size_t)(y * W + x) * 3;
                    o[0] = (unsigned char)(255 * shade * fog * 0.85f);
                    o[1] = (unsigned char)(255 * shade * fog);
                    o[2] = (unsigned char)(255 * shade * fog * 0.75f);
                }
        }
    }
    FILE *f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        fwrite(img, 1, (size_t)W * H * 3, f);
        fclose(f);
    }
    mgl_log("rt snapshot: %ld of %d section draws, %ld triangles -> %s", used, num_draws, tris, path);
    free(zb);
    free(img);
}
