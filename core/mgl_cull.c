/* GPU chunk culling (MCMETAL_GPU_CULL=1). mcmetal's mod (mod/src/mcmetal/loader/sodium/CullHooks.java) calls
   mcmGpuCull before Sodium draws a terrain pass, with every region it is about to draw: Sodium's multi-draw arrays
   for that region, its index buffer, where the region sits relative to the camera and which section each run of
   sub-draws belongs to. The backend tests every section's box against the pass's view on the GPU and writes each
   section's indirect draw arguments (no instances when it is out of view); the region's
   glMultiDrawElementsBaseVertex then draws from those. A multi-draw that doesn't match a prepared region is drawn the normal way, so a mismatch costs
   speed, never pictures. */
#include <string.h>
#include "mgl_state.h"

#define CULL_VERSION 1
#define CULL_HEADER 128 /* bytes before the first region record */

/* Layouts written by CullHooks.java (little-endian, native memory). */
typedef struct cull_header {
    int32_t op;         /* 1 = prepare a pass, 2 = pass finished */
    int32_t flags;      /* bit 0: shadow pass */
    int32_t nregions;
    int32_t version;
    float mvp[16];      /* column-major projection * modelView of the pass (camera-relative positions) */
} cull_header;
typedef struct cull_region_rec {
    int64_t count, offset, base;   /* Sodium's MultiDrawBatch arrays: GLsizei[n], index byte offsets[n], GLint[n] */
    int64_t sections;              /* cull_section_rec[nsec], in the order Sodium filled the batch */
    int32_t n, nsec, index_buffer, pad;
    float origin[3];               /* region origin minus camera, blocks */
    int32_t pad2;
} cull_region_rec;
typedef struct cull_section_rec {
    int32_t bv_start, bv_end;      /* the section's vertices in the region buffer: [start, end) */
    int32_t local;                 /* x | y << 8 | z << 16, sections inside the region */
    int32_t pad;
} cull_section_rec;

typedef struct cull_region {
    const int32_t *count;
    int n;
    mglb_buffer *ib;
    int cmd;            /* first command + 1, 0 = not culled */
} cull_region;

static struct {
    int on;             /* -1 unknown, 0 off, 1 on */
    int active;
    cull_region *regions;
    int nregions, cap_regions, next;
    mgl_cull_draw *draws;
    int cap_draws;
    mglb_buffer **ibufs;
    /* stats, logged now and then */
    unsigned long passes, prepared, matched, unmatched, sub_draws, refused, bad_tables;
} cull = {.on = -1};

static int cull_enabled(void)
{
    if (cull.on < 0) {
        const char *e = getenv("MCMETAL_GPU_CULL");
        cull.on = e && *e && *e != '0' && mglb_cull_supported();
        mgl_log("GPU chunk culling %s", cull.on ? "on" : e && *e && *e != '0' ? "requested, but this GPU can't" : "off");
    }
    return cull.on;
}

static void planes_from(const float *m, float p[6][4])
{
    /* rows of the column-major matrix; GL clip space: -w <= x, y, z <= w */
    for (int i = 0; i < 3; i++)
        for (int s = 0; s < 2; s++) {
            float *q = p[i * 2 + s];
            float sign = s ? -1.0f : 1.0f;
            for (int c = 0; c < 4; c++)
                q[c] = m[c * 4 + 3] + sign * m[c * 4 + i];
        }
}

static void log_stats(void)
{
    if (cull.passes % 2000)
        return;
    mgl_log("GPU chunk culling: last 2000 passes: %lu regions prepared, %lu drawn from culled commands, %lu drawn "
            "normally, %lu section draws, %lu passes refused, %lu bad section tables", cull.prepared, cull.matched,
            cull.unmatched, cull.sub_draws, cull.refused, cull.bad_tables);
    cull.prepared = cull.matched = cull.unmatched = cull.sub_draws = cull.refused = cull.bad_tables = 0;
}

/* Called by the mod through LWJGL (JNI.invokePP). Returns the number of regions prepared (0: draw normally). */
GLAPI int64_t mcmGpuCull(const void *cmd)
{
    const cull_header *h = cmd;
    if (!h)
        return 0;
    if (h->op == 2) {
        cull.active = 0;
        return 0;
    }
    cull.active = 0;
    if (h->op != 1 || h->version != CULL_VERSION || !cull_enabled() || h->nregions <= 0)
        return 0;
    cull.passes++;
    log_stats();
    if (cull.cap_regions < h->nregions) {
        cull.cap_regions = h->nregions * 2;
        cull.regions = realloc(cull.regions, sizeof *cull.regions * (size_t)cull.cap_regions);
        cull.ibufs = realloc(cull.ibufs, sizeof *cull.ibufs * (size_t)cull.cap_regions);
    }
    const cull_region_rec *rec = (const cull_region_rec *)((const char *)cmd + CULL_HEADER);
    int total = 0;
    for (int r = 0; r < h->nregions; r++)
        total += rec[r].n > 0 ? rec[r].n : 0;
    if (cull.cap_draws < total) {
        cull.cap_draws = total * 2;
        cull.draws = realloc(cull.draws, sizeof *cull.draws * (size_t)cull.cap_draws);
    }
    int nd = 0, nr = 0;
    for (int r = 0; r < h->nregions; r++) {
        const cull_region_rec *g = &rec[r];
        mgl_buffer *ib = mgl_buffer_obj((GLuint)g->index_buffer);
        if (g->n <= 0 || !ib || !ib->mem)
            continue;
        const int32_t *count = (const int32_t *)(intptr_t)g->count, *base = (const int32_t *)(intptr_t)g->base;
        const int64_t *off = (const int64_t *)(intptr_t)g->offset;
        const cull_section_rec *sec = (const cull_section_rec *)(intptr_t)g->sections;
        /* each section's sub-draws follow each other in fill order: walk both lists together */
        int s = 0, start = nd, ok = 1;
        for (int i = 0; i < g->n; i++) {
            int bv = base[i];
            while (s < g->nsec && !(bv >= sec[s].bv_start && bv < sec[s].bv_end))
                s++;
            if (s >= g->nsec || (off[i] & 3)) {
                ok = 0;
                break;
            }
            mgl_cull_draw *d = &cull.draws[nd++];
            d->count = (uint32_t)count[i];
            d->first_index = (uint32_t)(off[i] >> 2);
            d->base_vertex = (uint32_t)bv;
            d->region = (uint32_t)nr;
            d->min[0] = g->origin[0] + (float)((sec[s].local & 0xFF) * 16);
            d->min[1] = g->origin[1] + (float)(((sec[s].local >> 8) & 0xFF) * 16);
            d->min[2] = g->origin[2] + (float)(((sec[s].local >> 16) & 0xFF) * 16);
            d->pad = 0;
        }
        if (!ok) { /* Sodium filled this batch differently from the table: draw it the normal way */
            nd = start;
            cull.bad_tables++;
            continue;
        }
        cull.regions[nr] = (cull_region){count, g->n, ib->mem, start + 1}; /* made absolute below */
        cull.ibufs[nr] = ib->mem;
        nr++;
    }
    if (!nr)
        return 0;
    mgl_cull_pass p;
    planes_from(h->mvp, p.planes);
    p.flags = h->flags;
    int first = mglb_cull_run(&p, cull.draws, nd, cull.ibufs, nr);
    if (first < 0) {
        cull.refused++;
        return 0;
    }
    for (int r = 0; r < nr; r++)
        cull.regions[r].cmd += first;
    cull.nregions = nr;
    cull.next = 0;
    cull.active = 1;
    cull.prepared += (unsigned long)nr;
    cull.sub_draws += (unsigned long)nd;
    return nr;
}

/* For a multi-draw about to run: its prepared commands (first + 1), or 0 to draw it normally. Regions are drawn in
   the order they were prepared; one that Sodium skipped (nothing to draw after all) is passed over. */
int mgl_cull_take(const int *count, int n, mglb_buffer *ib)
{
    if (!cull.active)
        return 0;
    for (int r = cull.next; r < cull.nregions; r++) {
        cull_region *g = &cull.regions[r];
        if (g->count == (const int32_t *)count && g->n == n && g->ib == ib) {
            cull.next = r + 1;
            cull.matched++;
            return g->cmd;
        }
    }
    cull.unmatched++;
    return 0;
}
