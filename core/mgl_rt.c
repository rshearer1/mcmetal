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
static float terrain_mv[16]; /* the terrain pass's model-view (camera rotation; positions are camera-relative) */
static float terrain_proj[16];
static int have_terrain_mv;
static float *ent_tris;      /* this frame's entity triangles, camera-relative, 9 floats each */
static int ent_n, ent_cap;
static int ent_near_skipped; /* debug: triangles left out as the held item */
static char ent_debug[2048]; /* debug: this frame's entity draws */
static int ent_debug_draws;
static int ent_why[5];       /* debug: entity draws left out: no camera yet / not triangles / projection / rotation / other */
static uint32_t *ent_col;    /* this frame's entity triangle colours, RGBA8 per corner (3 each), as mcm_trace reads */
static int ent_col_cap, ent_coloured;
static float *snap_ent;      /* MGL_RT_SNAPSHOT: the last whole frame's entity triangles */
static int snap_ent_n, snap_ent_cap;

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

static int rt_debug(void);

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
    p->rt_atlas_slot = p->rt_spec_slot = -1; /* the block atlas, for mcm_trace's alpha test; its LabPBR twin */
    for (int i = 0; i < p->x.num_textures; i++) {
        const char *n = p->x.textures[i].name;
        if (!strcmp(n, "u_BlockTex") || !strcmp(n, "gtexture") || !strcmp(n, "tex") || !strcmp(n, "texture"))
            p->rt_atlas_slot = i;
        if (!strcmp(n, "specular"))
            p->rt_spec_slot = i;
    }
    /* entities: a float3 position (vanilla's Position, or Iris's / OptiFine-style core names) and a model-view */
    p->rt_epos_loc = p->rt_emv_off = p->rt_eproj_off = p->rt_euv_loc = p->rt_ecol_loc = -1;
    p->rt_etex_slot = p->rt_atlas_slot;
    for (int i = 0; i < p->x.num_textures && p->rt_etex_slot < 0; i++)
        if (!strcmp(p->x.textures[i].name, "Sampler0") || !strcmp(p->x.textures[i].name, "iris_Sampler0"))
            p->rt_etex_slot = i;
    p->rt_entity = 0;
    int overlay = 0;
    for (int i = 0; i < p->x.num_attribs; i++) {
        const char *n = p->x.attribs[i].name;
        if ((!strcmp(n, "Position") || !strcmp(n, "iris_Position") || !strcmp(n, "vaPosition")) &&
            !p->x.attribs[i].is_int && p->x.attribs[i].vecsize == 3)
            p->rt_epos_loc = p->x.attribs[i].location;
        if ((!strcmp(n, "UV0") || !strcmp(n, "iris_UV0") || !strcmp(n, "vaUV0")) && p->x.attribs[i].vecsize == 2)
            p->rt_euv_loc = p->x.attribs[i].location;
        if ((!strcmp(n, "Color") || !strcmp(n, "iris_Color") || !strcmp(n, "vaColor")) && p->x.attribs[i].vecsize == 4)
            p->rt_ecol_loc = p->x.attribs[i].location;
        /* the overlay coordinate (hurt flash) is only in the entity vertex format: entities, block entities, items */
        overlay |= !strcmp(n, "UV1") || !strcmp(n, "iris_UV1") || !strcmp(n, "vaUV1");
    }
    static const char *const mv_names[] = {"iris_ModelViewMat", "ModelViewMat", "modelViewMatrix", "iris_ModelViewMatrix"};
    static const char *const proj_names[] = {"iris_ProjMat", "ProjMat", "projectionMatrix", "iris_ProjectionMatrix"};
    for (int i = 0; i < 4 && p->rt_emv_off < 0; i++)
        p->rt_emv_off = uniform_offset(p, mv_names[i]);
    for (int i = 0; i < 4 && p->rt_eproj_off < 0; i++)
        p->rt_eproj_off = uniform_offset(p, proj_names[i]);
    /* Iris doesn't label its programs (debug_name stays empty unless the game calls glObjectLabel), so the
       vertex format is the main signal; MCMETAL_RT_ENTITIES=all takes every other solid world draw (clouds too) */
    static int all = -1;
    if (all < 0)
        all = getenv("MCMETAL_RT_ENTITIES") && !strcmp(getenv("MCMETAL_RT_ENTITIES"), "all");
    p->rt_entity = p->rt_pos_loc < 0 && p->rt_epos_loc >= 0 && p->rt_emv_off >= 0 && p->rt_eproj_off >= 0 &&
                   (overlay || all || !strncmp(p->debug_name, "gbuffers_entities", 17) ||
                    !strncmp(p->debug_name, "gbuffers_block", 14));
    if (rt_debug() && p->rt_pos_loc < 0 && p->rt_epos_loc >= 0) {
        char names[256] = "";
        for (int i = 0; i < p->x.num_attribs; i++)
            snprintf(names + strlen(names), sizeof names - strlen(names), "%s%s", i ? "," : "", p->x.attribs[i].name);
        mgl_log("rt debug: program with a float3 position: entity %d (overlay %d, mv %d, proj %d), inputs %s",
                p->rt_entity, overlay, p->rt_emv_off >= 0, p->rt_eproj_off >= 0, names);
    }
}

static void mat_mul(float *o, const float *a, const float *b);

/* Entity programs (mgl_rt_link decides). Per draw, record_entity also wants the main pass's projection, which
   leaves out the held item (its own field of view) and the shadow pass (orthographic). */
static int entity_program(const mgl_program *p)
{
    return p->rt_entity;
}

static void rigid_inverse(const float *m, float *o) /* rotation + translation, column-major */
{
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            o[c * 4 + r] = m[r * 4 + c];
    for (int r = 0; r < 3; r++)
        o[12 + r] = -(o[r] * m[12] + o[4 + r] * m[13] + o[8 + r] * m[14]);
    o[3] = o[7] = o[11] = 0;
    o[15] = 1;
}

/* Entity colours. mcm_trace_hit shows entities in their corner colours (they carry no atlas texture), so each
   entity triangle gets its own texture's colour at the triangle's centre, times its vertex colour (dyed wool,
   leather). That needs the texture on the CPU: a thumbnail of every RGBA8 2D texture's level 0, kept up to date
   by its uploads. Textures up to 256 a side are copied whole (entity skins are 64x64); bigger ones (atlases) are
   box-averaged down to 256, ignoring clear texels. MCMETAL_RT_ENTITY_COLOR=0: grey entities, as before. */
typedef struct rt_thumb {
    const mglb_texture *key;
    int w, h, tw, th;
    uint32_t *px;
} rt_thumb;
static rt_thumb *thumbs;
static int thumb_n, thumb_cap, thumb_last = -1;
static size_t thumb_bytes;

static int thumb_enabled(void)
{
    static int on = -1;
    if (on < 0)
        on = !getenv("MCMETAL_RT_ENTITY_COLOR") || strcmp(getenv("MCMETAL_RT_ENTITY_COLOR"), "0");
    return on;
}

static rt_thumb *thumb_find(const mglb_texture *m)
{
    if (thumb_last >= 0 && thumb_last < thumb_n && thumbs[thumb_last].key == m)
        return &thumbs[thumb_last];
    for (int i = 0; i < thumb_n; i++)
        if (thumbs[i].key == m) {
            thumb_last = i;
            return &thumbs[i];
        }
    return NULL;
}

void mgl_rt_thumb_forget(mglb_texture *m)
{
    rt_thumb *t = m ? thumb_find(m) : NULL;
    if (!t)
        return;
    thumb_bytes -= (size_t)t->tw * t->th * 4;
    free(t->px);
    *t = thumbs[--thumb_n];
    thumb_last = -1;
}

void mgl_rt_thumb_upload(mglb_texture *m, const mglb_texture_desc *desc, int level, int x, int y, int z, int w, int h,
                         const void *data, size_t bytes_per_row)
{
    if (level || z || desc->type != MGLT_2D || (desc->format != MGLF_RGBA8 && desc->format != MGLF_SRGB8_A8) ||
        !data || !thumb_enabled())
        return;
    int W = desc->width, H = desc->height;
    rt_thumb *t = thumb_find(m);
    if (t && (t->w != W || t->h != H)) {
        mgl_rt_thumb_forget(m);
        t = NULL;
    }
    if (!t) {
        int tw = W < 256 ? W : 256, th = H < 256 ? H : 256;
        if (tw <= 0 || th <= 0 || thumb_bytes + (size_t)tw * th * 4 > ((size_t)64 << 20))
            return; /* 64 MB of thumbnails is far more than any pack's entity textures */
        if (thumb_n == thumb_cap) {
            thumb_cap = thumb_cap ? thumb_cap * 2 : 256;
            thumbs = realloc(thumbs, sizeof *thumbs * (size_t)thumb_cap);
        }
        t = &thumbs[thumb_n++];
        *t = (rt_thumb){m, W, H, tw, th, calloc((size_t)tw * th, 4)};
        thumb_bytes += (size_t)tw * th * 4;
    }
    if (x < 0 || y < 0 || x + w > W || y + h > H)
        return;
    /* thumbnail texel (i, j) covers source columns [i * W / tw, (i + 1) * W / tw), rows likewise */
    int i0 = (int)((int64_t)x * t->tw / W), i1 = (int)((int64_t)(x + w - 1) * t->tw / W);
    int j0 = (int)((int64_t)y * t->th / H), j1 = (int)((int64_t)(y + h - 1) * t->th / H);
    for (int j = j0; j <= j1; j++) {
        int sy0 = (int)((int64_t)j * H / t->th), sy1 = (int)((int64_t)(j + 1) * H / t->th);
        sy0 = sy0 < y ? y : sy0;
        sy1 = sy1 > y + h ? y + h : sy1;
        for (int i = i0; i <= i1; i++) {
            int sx0 = (int)((int64_t)i * W / t->tw), sx1 = (int)((int64_t)(i + 1) * W / t->tw);
            sx0 = sx0 < x ? x : sx0;
            sx1 = sx1 > x + w ? x + w : sx1;
            uint32_t sum[4] = {0, 0, 0, 0}, n = 0;
            for (int sy = sy0; sy < sy1; sy++) {
                const unsigned char *row = (const unsigned char *)data + (size_t)(sy - y) * bytes_per_row;
                for (int sx = sx0; sx < sx1; sx++) {
                    const unsigned char *c = row + (size_t)(sx - x) * 4;
                    n++;
                    if (c[3] < 26)
                        continue; /* clear: leave it out of the colour */
                    sum[0] += c[0], sum[1] += c[1], sum[2] += c[2], sum[3]++;
                }
            }
            if (!n)
                continue;
            uint32_t v = 0;
            if (sum[3])
                v = (sum[0] / sum[3]) | (sum[1] / sum[3]) << 8 | (sum[2] / sum[3]) << 16 | (255u * sum[3] / n) << 24;
            t->px[(size_t)j * t->tw + i] = v;
        }
    }
}

/* the colour (RGBA8, R in the low byte) a triangle with these texture coordinates shows; alpha 0 = unknown */
static uint32_t thumb_colour(const rt_thumb *t, const float uv[3][2])
{
    float u = (uv[0][0] + uv[1][0] + uv[2][0]) / 3.0f, v = (uv[0][1] + uv[1][1] + uv[2][1]) / 3.0f;
    if (!(u >= 0.0f && u < 1.0f && v >= 0.0f && v < 1.0f))
        return 0;
    int i = (int)(u * t->tw), j = (int)(v * t->th);
    uint32_t c = t->px[(size_t)j * t->tw + i];
    for (int k = 0; k < 3 && !(c >> 24); k++) { /* the centre is clear (a thin part): try towards each corner */
        int ci = (int)((u + uv[k][0]) * 0.5f * t->tw), cj = (int)((v + uv[k][1]) * 0.5f * t->th);
        if (ci >= 0 && ci < t->tw && cj >= 0 && cj < t->th)
            c = t->px[(size_t)cj * t->tw + ci];
    }
    return c;
}

/* record_entity's colours for its tris triangles at ent_n: texture colour at each triangle's centre x vertex colour */
static void entity_colours(const mgl_program *p, const mgl_draw *d, const unsigned char *ib, int tris)
{
    uint32_t *out = ent_col + (size_t)ent_n * 3;
    const rt_thumb *t = NULL;
    if (p->rt_etex_slot >= 0) {
        int idx = p->x.textures[p->rt_etex_slot].msl_index[MGL_FRAGMENT];
        if (idx >= 0 && idx < MGL_MAX_TEXTURES && d->textures[MGL_FRAGMENT][idx].tex)
            t = thumb_find(d->textures[MGL_FRAGMENT][idx].tex);
    }
    const mgl_vertex_attr *ua = p->rt_euv_loc >= 0 ? &d->attrs[p->rt_euv_loc] : NULL;
    const mgl_vertex_attr *ca = p->rt_ecol_loc >= 0 ? &d->attrs[p->rt_ecol_loc] : NULL;
    if (ua && (!ua->enabled || ua->type != MGLV_FLOAT || ua->size < 2 || ua->buffer < 0 || ua->buffer >= d->num_vbufs))
        ua = NULL;
    if (ca && (!ca->enabled || ca->type != MGLV_UBYTE || ca->size < 4 || ca->buffer < 0 || ca->buffer >= d->num_vbufs))
        ca = NULL;
    const unsigned char *ub = ua ? mglb_buffer_ptr(d->vbufs[ua->buffer].buf) : NULL;
    const unsigned char *cb = ca ? mglb_buffer_ptr(d->vbufs[ca->buffer].buf) : NULL;
    if (!t || !ub)
        t = NULL;
    for (int tr = 0; tr < tris; tr++) {
        uint32_t idx[3];
        for (int c = 0; c < 3; c++) {
            int k = tr * 3 + c;
            if (ib) {
                size_t at = d->index_offset + (size_t)k * (d->index_type == GL_UNSIGNED_SHORT ? 2 : 4);
                idx[c] = d->index_type == GL_UNSIGNED_SHORT ? *(const uint16_t *)(ib + at) : *(const uint32_t *)(ib + at);
            } else
                idx[c] = (uint32_t)(d->first + k);
        }
        uint32_t tex = 0;
        if (t) {
            const mgl_vertex_buf *vb = &d->vbufs[ua->buffer];
            float uv[3][2];
            for (int c = 0; c < 3; c++)
                memcpy(uv[c], ub + vb->offset + ua->offset + (size_t)((int64_t)idx[c] + d->base_vertex) * (size_t)vb->stride,
                       sizeof uv[c]);
            tex = thumb_colour(t, (const float(*)[2])uv);
        }
        if (tex >> 24)
            ent_coloured++;
        else
            tex = 0xFF999999u; /* no texture we know: mid grey, as before */
        for (int c = 0; c < 3; c++) {
            uint32_t v = tex;
            if (cb) {
                const mgl_vertex_buf *vb = &d->vbufs[ca->buffer];
                const unsigned char *vc = cb + vb->offset + ca->offset + (size_t)((int64_t)idx[c] + d->base_vertex) * (size_t)vb->stride;
                v = ((tex & 0xFF) * vc[0] / 255) | ((tex >> 8 & 0xFF) * vc[1] / 255) << 8 |
                    ((tex >> 16 & 0xFF) * vc[2] / 255) << 16 | 0xFF000000u;
            }
            out[tr * 3 + c] = v | 0xFF000000u;
        }
    }
}

/* An entity draw: its triangles, moved into the terrain's camera-relative space, appended to this frame's list.
   Entity buffers are rewritten every frame, so the corners are copied now. */
static void record_entity(const mgl_program *p, const mgl_draw *d)
{
    if (!have_terrain_mv) {
        ent_why[0]++;
        return;
    }
    if (d->primitive != GL_TRIANGLES || d->instances > 1 || !d->depth_write) {
        ent_why[1]++;
        return;
    }
    const float *proj = (const float *)(p->ublock[MGL_VERTEX] + p->rt_eproj_off);
    for (int i = 0; i < 16; i++)
        if (fabsf(proj[i] - terrain_proj[i]) > 1e-3f * (fabsf(terrain_proj[i]) + 1e-3f)) {
            ent_why[2]++;
            return; /* not the world camera: the hand, the shadow map, a GUI item */
        }
    const float *emv = (const float *)(p->ublock[MGL_VERTEX] + p->rt_emv_off);
    for (int c = 0; c < 3; c++)
        for (int r = 0; r < 3; r++)
            if (fabsf(emv[c * 4 + r] - terrain_mv[c * 4 + r]) > 1e-3f) {
                ent_why[3]++;
                return; /* world draws carry the camera's rotation; the held item (same projection at some FOVs) doesn't */
            }
    const mgl_vertex_attr *a = &d->attrs[p->rt_epos_loc];
    if (!a->enabled || a->type != MGLV_FLOAT || a->size < 3 || a->buffer < 0 || a->buffer >= d->num_vbufs) {
        ent_why[4]++;
        return;
    }
    const mgl_vertex_buf *vb = &d->vbufs[a->buffer];
    const unsigned char *base = mglb_buffer_ptr(vb->buf);
    const unsigned char *ib = d->index_buf ? mglb_buffer_ptr(d->index_buf) : NULL;
    if (!base || (d->index_buf && !ib) || vb->stride < 12 || mglb_buffer_gpu_writing(vb->buf) ||
        mglb_buffer_gpu_writing(d->index_buf)) {
        ent_why[4]++;
        return;
    }
    float inv[16], m[16];
    rigid_inverse(terrain_mv, inv);
    mat_mul(m, inv, (const float *)(p->ublock[MGL_VERTEX] + p->rt_emv_off));
    int tris = d->count / 3;
    if (ent_n + tris > 262144) /* plenty for a busy farm; past that, skip */
        return;
    if (ent_n + tris > ent_cap) {
        ent_cap = (ent_n + tris) * 2;
        ent_tris = realloc(ent_tris, sizeof(float) * 9 * (size_t)ent_cap);
    }
    if (thumb_enabled() && ent_n + tris > ent_col_cap) {
        ent_col_cap = ent_cap;
        ent_col = realloc(ent_col, sizeof(uint32_t) * 3 * (size_t)ent_col_cap);
    }
    float *o = ent_tris + (size_t)ent_n * 9;
    for (int k = 0; k < tris * 3; k++) {
        uint32_t idx;
        if (ib) {
            size_t at = d->index_offset + (size_t)k * (d->index_type == GL_UNSIGNED_SHORT ? 2 : 4);
            idx = d->index_type == GL_UNSIGNED_SHORT ? *(const uint16_t *)(ib + at) : *(const uint32_t *)(ib + at);
        } else
            idx = (uint32_t)(d->first + k);
        const float *v = (const float *)(base + vb->offset + a->offset + (size_t)((int64_t)idx + d->base_vertex) * (size_t)vb->stride);
        for (int r = 0; r < 3; r++)
            o[k * 3 + r] = m[r] * v[0] + m[4 + r] * v[1] + m[8 + r] * v[2] + m[12 + r];
    }
    float far2 = 0; /* the held item and arm sit within 2 blocks of the eye; little in the world fits there whole */
    for (int k = 0; k < tris * 3; k++) {
        float d2 = o[k * 3] * o[k * 3] + o[k * 3 + 1] * o[k * 3 + 1] + o[k * 3 + 2] * o[k * 3 + 2];
        far2 = d2 > far2 ? d2 : far2;
    }
    if (far2 < 4.0f) {
        ent_near_skipped += tris;
        return;
    }
    if (rt_debug() && ent_debug_draws < 16) { /* which draws these are: size and where (camera-relative box) */
        float lo[3] = {o[0], o[1], o[2]}, hi[3] = {o[0], o[1], o[2]};
        for (int k = 1; k < tris * 3; k++)
            for (int r = 0; r < 3; r++) {
                lo[r] = o[k * 3 + r] < lo[r] ? o[k * 3 + r] : lo[r];
                hi[r] = o[k * 3 + r] > hi[r] ? o[k * 3 + r] : hi[r];
            }
        snprintf(ent_debug + strlen(ent_debug), sizeof ent_debug - strlen(ent_debug),
                 " [%d tris, %d verts/stride %d, box %.1f,%.1f,%.1f..%.1f,%.1f,%.1f]", tris, d->count, vb->stride,
                 lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]);
        ent_debug_draws++;
    }
    if (thumb_enabled())
        entity_colours(p, d, ib, tris);
    ent_n += tris;
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
static struct { unsigned long taken, not_terrain, not_tris, no_attr, small_stride, idle, fresh, f_range, f_ibuf, f_vbuf, f_other,
                  f_sub, f_merged, f_overlap,
                  writes, bumped; unsigned long long write_bytes;
                char last_skip[64]; } rtd;
static int rt_debug(void)
{
    static int on = -1;
    if (on < 0)
        on = getenv("MGL_RT_DEBUG") && atoi(getenv("MGL_RT_DEBUG"));
    return on;
}

static int rt_fold(void) /* MGL_RT_FOLD=0 keeps every draw as its own section */
{
    static int on = -1;
    if (on < 0)
        on = !getenv("MGL_RT_FOLD") || atoi(getenv("MGL_RT_FOLD")) != 0;
    return on;
}

/* Sodium draws a section's faces as separate index ranges and leaves out those facing away from the camera, so
   panning keeps producing new (base vertex, count) pairs for the same section, and each one cost an acceleration
   structure build. Rays need every face anyway: a draw inside a kept section only refreshes it, and one next to
   it (same section, vertices in between all its own) widens the kept range to cover both. */
static int quad_range(const mgl_rt_geom *g, int *lo, int *hi)
{
    if (g->ioff || g->count <= 0 || g->count % 6)
        return 0;
    *lo = g->base_vertex;
    *hi = g->base_vertex + g->count / 6 * 4;
    return 1;
}

static int same_layout(const mgl_rt_geom *a, const mgl_rt_geom *b)
{
    return a->vbuf == b->vbuf && a->ibuf == b->ibuf && a->vbase == b->vbase && a->stride == b->stride &&
           a->itype == b->itype && a->translucent == b->translucent;
}

/* every vertex in [lo, hi) carries the same section index, and the index buffer reaches far enough */
static int one_section(const mgl_rt_geom *g, int lo, int hi)
{
    if (mglb_buffer_gpu_writing(g->vbuf))
        return 0; /* a GPU copy into it hasn't run yet: the CPU sees old vertices, so don't fold */
    const unsigned char *base = mglb_buffer_ptr(g->vbuf);
    size_t isz = (size_t)(g->itype == GL_UNSIGNED_SHORT ? 2 : 4);
    if (!base || lo < 0 || (size_t)(hi - lo) / 4 * 6 * isz > mglb_buffer_size(g->ibuf) ||
        g->vbase + (size_t)hi * (size_t)g->stride > mglb_buffer_size(g->vbuf))
        return 0;
    if (g->itype == GL_UNSIGNED_SHORT && hi - lo > 65536)
        return 0;
    uint32_t sec = ((const uint32_t *)(base + g->vbase + (size_t)lo * (size_t)g->stride))[4] >> 24;
    for (int v = lo + 1; v < hi; v++)
        if (((const uint32_t *)(base + g->vbase + (size_t)v * (size_t)g->stride))[4] >> 24 != sec)
            return 0;
    return 1;
}

static void touch(rt_draw *r, const rt_draw *key, double t)
{
    memcpy(r->g.region, key->g.region, sizeof r->g.region);
    if (key->g.ent_off >= 0 && r->g.ent_off != key->g.ent_off) { /* passes without mc_Entity keep it */
        r->g.ent_off = key->g.ent_off;
        r->g.gen++;
    }
    r->seen = t;
}

/* Draw -> kept entry. Each terrain draw used to be compared with every kept section (a few thousand), and a draw
   that folds into one (most of them: Sodium draws the camera-facing faces of a kept range) went through the fold
   scans as well: 26-51 us per multi-draw call on the M3 with our RT pack, against 3-5 us without ray tracing.
   The table holds every entry's own key and, once a draw has folded into an entry, that draw's key too. Entries
   move when the list is compacted; the table is then rebuilt on the next lookup. */
typedef struct rt_slot {
    uint64_t h; /* 0 = empty */
    int idx;
} rt_slot;
static rt_slot *tab;
static int tab_cap, tab_used, tab_stale = 1;

static uint64_t mix64(uint64_t h, uint64_t v)
{
    h ^= v + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2);
    return h * 0xBF58476D1CE4E5B9ull;
}

static uint64_t key_hash(const mgl_rt_geom *g)
{
    uint64_t h = mix64((uint64_t)(uintptr_t)g->vbuf, (uint64_t)(uintptr_t)g->ibuf);
    h = mix64(h, (uint64_t)g->vbase);
    h = mix64(h, (uint64_t)g->ioff);
    h = mix64(h, (uint64_t)(uint32_t)g->count << 32 | (uint32_t)g->base_vertex);
    h = mix64(h, (uint64_t)g->translucent);
    h ^= h >> 31;
    return h ? h : 1;
}

static int same_draw(const mgl_rt_geom *a, const mgl_rt_geom *b)
{
    return a->vbuf == b->vbuf && a->vbase == b->vbase && a->base_vertex == b->base_vertex && a->ioff == b->ioff &&
           a->count == b->count && a->ibuf == b->ibuf && a->translucent == b->translucent;
}

static void tab_put(uint64_t h, int idx)
{
    unsigned m = (unsigned)tab_cap - 1, at = (unsigned)h & m;
    while (tab[at].h)
        at = (at + 1) & m;
    tab[at].h = h;
    tab[at].idx = idx;
    tab_used++;
}

static void tab_rebuild(void)
{
    int want = 1024;
    while (want < num_draws * 4)
        want *= 2;
    if (want != tab_cap) {
        free(tab);
        tab = malloc(sizeof *tab * (size_t)want);
        tab_cap = want;
    }
    memset(tab, 0, sizeof *tab * (size_t)tab_cap);
    tab_used = 0;
    for (int i = 0; i < num_draws; i++)
        tab_put(key_hash(&draws[i].g), i);
    tab_stale = 0;
}

static int quad_range(const mgl_rt_geom *g, int *lo, int *hi);
static int same_layout(const mgl_rt_geom *a, const mgl_rt_geom *b);

/* the kept entry for this draw (its own, or the one it folded into before), or -1 */
static int tab_find(const mgl_rt_geom *g, uint64_t h)
{
    if (tab_stale)
        tab_rebuild();
    unsigned m = (unsigned)tab_cap - 1;
    for (unsigned at = (unsigned)h & m; tab[at].h; at = (at + 1) & m) {
        if (tab[at].h != h || tab[at].idx >= num_draws)
            continue;
        const mgl_rt_geom *r = &draws[tab[at].idx].g;
        if (same_draw(r, g))
            return tab[at].idx;
        int lo, hi, klo, khi;
        if (same_layout(r, g) && quad_range(r, &lo, &hi) && quad_range(g, &klo, &khi) && klo >= lo && khi <= hi)
            return tab[at].idx;
    }
    return -1;
}

static void tab_add(uint64_t h, int idx)
{
    if (tab_stale)
        return; /* rebuilt from the list on the next lookup */
    if ((tab_used + 1) * 2 > tab_cap) {
        tab_stale = 1;
        return;
    }
    tab_put(h, idx);
}

/* the kept entry that covers the draw (or now does, widened), or -1 */
static int fold_into_section(const rt_draw *key, double t)
{
    int klo, khi;
    if (!quad_range(&key->g, &klo, &khi))
        return -1;
    for (int i = 0; i < num_draws; i++) {
        rt_draw *r = &draws[i];
        int lo, hi;
        if (!same_layout(&r->g, &key->g) || !quad_range(&r->g, &lo, &hi))
            continue;
        if (klo >= lo && khi <= hi) {
            touch(r, key, t);
            rtd.f_sub++;
            return i;
        }
    }
    for (int i = 0; i < num_draws; i++) {
        rt_draw *r = &draws[i];
        int lo, hi;
        if (!same_layout(&r->g, &key->g) || !quad_range(&r->g, &lo, &hi))
            continue;
        int ulo = lo < klo ? lo : klo, uhi = hi > khi ? hi : khi;
        /* near enough to be the same section's other faces (a section holds at most a few 10k vertices) */
        if (uhi - ulo > 4 * ((hi - lo) + (khi - klo)) + 4096 || !one_section(&key->g, ulo, uhi))
            continue;
        r->g.base_vertex = ulo;
        r->g.count = (uhi - ulo) / 4 * 6;
        touch(r, key, t);
        rtd.f_merged++;
        /* drop other kept ranges now inside this one */
        int n = 0, at = i;
        for (int j = 0; j < num_draws; j++) {
            int jl, jh;
            if (j != i && same_layout(&draws[j].g, &r->g) && quad_range(&draws[j].g, &jl, &jh) && jl >= ulo &&
                jh <= uhi) {
                if (draws[j].seen > r->seen)
                    r->seen = draws[j].seen;
                continue;
            }
            if (j == i)
                at = n;
            draws[n++] = draws[j];
        }
        num_draws = n;
        tab_stale = 1; /* entries moved, and this one's own key changed */
        return at;
    }
    return -1;
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
        mgl_log("rt debug: %lu draws new to the capture: %lu same section with another index range, %lu another index "
                "buffer, %lu a vertex buffer not seen before, %lu other (%lu overlapping a kept section); %lu inside a kept section, %lu merged into "
                "one", rtd.fresh, rtd.f_range, rtd.f_ibuf, rtd.f_vbuf, rtd.f_other, rtd.f_overlap, rtd.f_sub, rtd.f_merged);
        mgl_log("rt debug: %lu buffer writes (%llu KB), %lu kept sections overwritten (dropped)", rtd.writes,
                rtd.write_bytes / 1024, rtd.bumped);
        /* MGL_RT_DEBUG=2: the material byte Sodium packs beside the section index (alpha cutoff in bits 1-2), over
           the captured vertices: shows whether cutout blocks carry a cutoff here (reads every vertex: slow) */
        if (rt_debug() >= 2) {
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
        }
        memset(&rtd, 0, sizeof rtd);
        last_log = now;
    }
}

mglb_texture *mgl_rt_atlas, *mgl_rt_specular;
int mgl_rt_light_ids[2] = {-1, -1};
float mgl_rt_radius;

void mgl_rt_record(mgl_program *p, const mgl_draw *d)
{
    rt_debug_tick();
    double t = now_s();
    if (p && p->x.uses_scene)
        scene_wanted = t;
    static int snap_env = -1;
    if (snap_env < 0)
        snap_env = getenv("MGL_RT_SNAPSHOT") != NULL;
    if (!snap_env && (!scene_wanted || t - scene_wanted > 5.0)) {
        rtd.idle++;
        if (num_draws) { /* nothing prunes the capture while idle: start afresh when rays are next wanted */
            num_draws = 0;
            tab_stale = 1;
        }
        return; /* no ray-tracing shader in use: capture costs nothing */
    }
    if (p && p->ublock[MGL_VERTEX] && entity_program(p)) {
        record_entity(p, d);
        return;
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
    if (p->rt_atlas_slot >= 0) { /* the block atlas, for mcm_trace's alpha test */
        int idx = p->x.textures[p->rt_atlas_slot].msl_index[MGL_FRAGMENT];
        if (idx >= 0 && idx < MGL_MAX_TEXTURES && d->textures[MGL_FRAGMENT][idx].tex)
            mgl_rt_atlas = d->textures[MGL_FRAGMENT][idx].tex;
    }
    if (p->rt_spec_slot >= 0) { /* Iris's specular atlas (same layout), for mcm_hit_emission */
        int idx = p->x.textures[p->rt_spec_slot].msl_index[MGL_FRAGMENT];
        if (idx >= 0 && idx < MGL_MAX_TEXTURES && d->textures[MGL_FRAGMENT][idx].tex)
            mgl_rt_specular = d->textures[MGL_FRAGMENT][idx].tex;
    }
    const mgl_vertex_buf *vb = &d->vbufs[a->buffer];
    int ent_off = -1; /* Iris: ((id + 1) << 1) | render type, 4 bytes */
    if (p->rt_ent_loc >= 0) {
        const mgl_vertex_attr *e = &d->attrs[p->rt_ent_loc];
        if (e->enabled && e->buffer == a->buffer && e->offset >= a->offset && !((e->offset - a->offset) & 3))
            ent_off = (int)(e->offset - a->offset);
    }
    const float *region = (const float *)(p->ublock[MGL_VERTEX] + p->rt_region_off);

    /* camera: the terrain pass drawing into a window-sized target (the shadow map is square) */
    int ww, wh;
    mglb_window_size(&ww, &wh);
    if (p->rt_mv_off >= 0 && p->rt_proj_off >= 0 && d->target.width == ww && d->target.height == wh) {
        mat_mul(view_proj, (const float *)(p->ublock[MGL_VERTEX] + p->rt_proj_off),
                (const float *)(p->ublock[MGL_VERTEX] + p->rt_mv_off));
        memcpy(terrain_mv, p->ublock[MGL_VERTEX] + p->rt_mv_off, sizeof terrain_mv);
        memcpy(terrain_proj, p->ublock[MGL_VERTEX] + p->rt_proj_off, sizeof terrain_proj);
        have_view = have_terrain_mv = 1;
    }

    /* gen 0: an acceleration structure built from these vertices stays good until they are written, and the
       backend forgets it then (mglb_rt_forget), so a section that comes back into view is not built again */
    rt_draw key = {{vb->buf, d->index_buf, vb->offset + (size_t)a->offset, vb->stride, d->index_offset,
                    d->index_type, d->count, d->base_vertex, 0, {region[0], region[1], region[2]},
                    d->blend[0].enabled, ent_off}, t};
    uint64_t h = key_hash(&key.g);
    int at = tab_find(&key.g, h);
    if (at >= 0) {
        touch(&draws[at], &key, t);
        goto recorded;
    }
    if (rt_fold() && (at = fold_into_section(&key, t)) >= 0) {
        tab_add(h, at); /* the next frame's same draw finds it at once */
        goto recorded;
    }
    if (rt_debug()) { /* why is this draw new: compare with a capture entry for the same vertices */
        rtd.fresh++;
        int same_vb = 0, why = 0;
        for (int i = 0; i < num_draws && !why; i++) {
            const mgl_rt_geom *o = &draws[i].g;
            if (o->vbuf != key.g.vbuf)
                continue;
            same_vb = 1;
            if (o->vbase == key.g.vbase && o->base_vertex == key.g.base_vertex && o->translucent == key.g.translucent)
                why = o->ibuf != key.g.ibuf ? 2 : 1;
        }
        if (why == 1)
            rtd.f_range++;
        else if (why == 2)
            rtd.f_ibuf++;
        else if (!same_vb)
            rtd.f_vbuf++;
        else {
            rtd.f_other++;
            int klo, khi;
            if (quad_range(&key.g, &klo, &khi))
                for (int i = 0; i < num_draws; i++) {
                    int lo, hi;
                    if (draws[i].g.vbuf == key.g.vbuf && draws[i].g.vbase == key.g.vbase &&
                        quad_range(&draws[i].g, &lo, &hi) && klo < hi && khi > lo) {
                        rtd.f_overlap++;
                        break;
                    }
                }
        }
    }
    if (num_draws == cap_draws) {
        cap_draws = cap_draws ? cap_draws * 2 : 1024;
        draws = realloc(draws, sizeof *draws * (size_t)cap_draws);
    }
    draws[num_draws++] = key;
    tab_add(h, num_draws - 1);
recorded:;
    /* forget sections not drawn for 2 s (unloaded, rebuilt elsewhere, or behind every pass) */
    static double last_prune;
    if (t - last_prune > 1.0) {
        int n = 0;
        for (int i = 0; i < num_draws; i++)
            if (t - draws[i].seen < 2.0)
                draws[n++] = draws[i];
        if (n != num_draws)
            tab_stale = 1;
        num_draws = n;
        last_prune = t;
    }
    static const char *snap;
    if (snap_env && !snap)
        snap = getenv("MGL_RT_SNAPSHOT");
    if (snap) {
        char go[600];
        snprintf(go, sizeof go, "%s.go", snap);
        if (!access(go, F_OK)) {
            unlink(go);
            snapshot(snap);
        }
    }
}

/* Vertex data written. Sodium never rewrites a live section in place (a rebuilt section gets new space and the
   old space is freed), so a write over a kept range means that range is gone: drop it rather than rebuild it, and
   if the same range is drawn again it comes back as new. The backend forgets acceleration structures built from
   the written bytes, so a range reused for other vertices never matches one built before. */
void mgl_rt_note_write(mglb_buffer *m, size_t offset, size_t size)
{
    mglb_rt_forget(m, offset, size);
    int n = 0;
    for (int i = 0; i < num_draws; i++) {
        mgl_rt_geom *g = &draws[i].g;
        if (g->vbuf == m) {
            /* Sodium draws quads: 4 vertices per 6 indices, starting at the base vertex */
            size_t lo = g->vbase + (size_t)g->base_vertex * (size_t)g->stride;
            size_t hi = lo + (size_t)g->count * 2 / 3 * (size_t)g->stride;
            if (offset < hi && (size == (size_t)-1 || offset + size > lo)) {
                rtd.bumped++;
                continue;
            }
        }
        draws[n++] = draws[i];
    }
    if (n != num_draws)
        tab_stale = 1;
    num_draws = n;
    if (n) {
        rtd.writes++;
        rtd.write_bytes += size == (size_t)-1 ? 0 : size;
    }
}

/* Buffer memory freed for good (not just back to the pool, which keeps it whole): captured draws that read it
   would hand rt_update a dangling buffer (a pack switch crashed in setBuffer after Sodium freed its arenas). */
void mgl_rt_note_free(mglb_buffer *m)
{
    int n = 0;
    for (int i = 0; i < num_draws; i++)
        if (draws[i].g.vbuf != m && draws[i].g.ibuf != m)
            draws[n++] = draws[i];
    if (n != num_draws)
        tab_stale = 1;
    num_draws = n;
}

static int num_draws_fwd(void) { return num_draws; }

void mgl_rt_end_frame(void)
{
    rt_debug_tick();
    if (rt_debug() && (ent_n || ent_why[0] + ent_why[1] + ent_why[2] + ent_why[3] + ent_why[4])) {
        static double last;
        if (now_s() - last > 1.0) {
            mgl_log("rt debug: %d entity triangles this frame (%d coloured from %d texture thumbnails, %zu KB; %d left "
                    "out next to the eye; draws left out: %d before "
                    "the terrain camera, %d not triangles/depth, %d other projection, %d other rotation, %d no "
                    "position data);%s", ent_n, ent_coloured, thumb_n, thumb_bytes >> 10, ent_near_skipped, ent_why[0], ent_why[1], ent_why[2], ent_why[3],
                    ent_why[4], ent_debug);
            last = now_s();
        }
    }
    memset(ent_why, 0, sizeof ent_why);
    if (getenv("MGL_RT_SNAPSHOT")) {
        if (ent_n > snap_ent_cap) {
            snap_ent_cap = ent_n * 2;
            snap_ent = realloc(snap_ent, sizeof(float) * 9 * (size_t)snap_ent_cap);
        }
        if (ent_n)
            memcpy(snap_ent, ent_tris, sizeof(float) * 9 * (size_t)ent_n);
        snap_ent_n = ent_n;
    }
    if (!scene_wanted || now_s() - scene_wanted > 5.0 || !num_draws) {
        ent_n = ent_near_skipped = ent_debug_draws = ent_coloured = 0; /* snapshot-only capture: start each frame afresh */
        ent_debug[0] = 0;
        return;
    }
    static mgl_rt_geom *list;
    static int cap;
    if (cap < num_draws) {
        cap = num_draws * 2;
        list = realloc(list, sizeof *list * (size_t)cap);
    }
    for (int i = 0; i < num_draws; i++)
        list[i] = draws[i].g;

    mglb_rt_dynamic(ent_tris, thumb_enabled() ? ent_col : NULL, ent_n);
    ent_n = 0;
    ent_near_skipped = 0;
    ent_coloured = 0;
    ent_debug[0] = 0;
    ent_debug_draws = 0;
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

/* depth-tested flat-shaded triangle into the snapshot; red = an entity */
static int snap_tri(const float wp[3][3], float *zb, unsigned char *img, int W, int H, int red)
{
    float sx[3], sy[3], sz[3];
    for (int j = 0; j < 3; j++) {
        const float *m = view_proj;
        float cx = m[0] * wp[j][0] + m[4] * wp[j][1] + m[8] * wp[j][2] + m[12];
        float cy = m[1] * wp[j][0] + m[5] * wp[j][1] + m[9] * wp[j][2] + m[13];
        float cw = m[3] * wp[j][0] + m[7] * wp[j][1] + m[11] * wp[j][2] + m[15];
        if (cw < 0.05f)
            return 0;
        sx[j] = (cx / cw * 0.5f + 0.5f) * W;
        sy[j] = (0.5f - cy / cw * 0.5f) * H;
        sz[j] = cw;
    }
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
        return 1;
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
            o[0] = (unsigned char)(255 * shade * fog * (red ? 1.0f : 0.85f));
            o[1] = (unsigned char)(255 * shade * fog * (red ? 0.15f : 1.0f));
            o[2] = (unsigned char)(255 * shade * fog * (red ? 0.15f : 0.75f));
        }
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
    long tris = 0, used = 0, ents = 0;
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
            float wp[3][3];
            int ok = 1;
            for (int j = 0; j < 3 && ok; j++) {
                size_t at = r->ioff + (size_t)(k + j) * (r->itype == GL_UNSIGNED_SHORT ? 2 : 4);
                uint32_t idx = r->itype == GL_UNSIGNED_SHORT ? *(const uint16_t *)(ib + at) : *(const uint32_t *)(ib + at);
                ok = decode(r, idx + (uint32_t)r->base_vertex, wp[j]);
            }
            if (ok)
                tris += snap_tri((const float(*)[3])wp, zb, img, W, H, 0);
        }
    }
    for (int k = 0; have_view && k < snap_ent_n; k++) /* entities in red: they should stand on the terrain */
        ents += snap_tri((const float(*)[3])(snap_ent + (size_t)k * 9), zb, img, W, H, 1);
    FILE *f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        fwrite(img, 1, (size_t)W * H * 3, f);
        fclose(f);
    }
    mgl_log("rt snapshot: %ld of %d section draws, %ld triangles, %ld entity triangles (red) -> %s", used, num_draws,
            tris, ents, path);
    free(zb);
    free(img);
}
