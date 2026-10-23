/* On-disk cache of translated programs (GLSL -> MSL + reflection), so a shader pack's second launch, and every
   pack reload, skips glslang + SPIRV-Cross entirely. Enabled when MGL_CACHE_DIR is set. Keyed by a 128-bit hash
   of every stage's source, the geometry shader, glBindFragDataLocation requests and this build, so any change to
   the pack or to mcmetal itself misses cleanly. Files are written to a temp name and renamed into place. */
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "mgl_cache.h"
#include "mgl_log.h"

#define MAGIC 0x4D43534Du /* "MSCM" */
static const char build_tag[] = "mcmetal-xlate-4 " __DATE__ " " __TIME__;

/* Every key includes build_tag, so entries from an older mcmetal can never hit again. The mod turns the cache on for
   players (glfw/mtl_context.m), so drop them when the build changes instead of letting each update leave a full set
   behind. The build is noted in BUILD; pipelines.metallib and anything else that isn't ours stays. */
static void prune(const char *dir)
{
    char path[1024], old[sizeof build_tag + 1] = "";
    snprintf(path, sizeof path, "%s/BUILD", dir);
    FILE *f = fopen(path, "r");
    if (f) {
        if (!fgets(old, sizeof old, f))
            old[0] = 0;
        fclose(f);
    }
    if (!strcmp(old, build_tag))
        return;
    DIR *d = opendir(dir);
    int n = 0;
    for (struct dirent *e; d && (e = readdir(d));) {
        size_t len = strlen(e->d_name);
        if (len > 5 && !strcmp(e->d_name + len - 5, ".mclx")) {
            char victim[1400];
            snprintf(victim, sizeof victim, "%s/%s", dir, e->d_name);
            n += !unlink(victim);
        }
    }
    if (d)
        closedir(d);
    if ((f = fopen(path, "w"))) {
        fputs(build_tag, f);
        fclose(f);
    }
    if (n)
        mgl_log("shader cache: removed %d programs translated by an older mcmetal", n);
}

static const char *cache_dir(void)
{
    static int init;
    static const char *dir;
    if (!init) {
        init = 1;
        dir = getenv("MGL_CACHE_DIR");
        if (dir && *dir) {
            mkdir(dir, 0755);
            prune(dir);
        } else
            dir = NULL;
    }
    return dir;
}

typedef struct { uint64_t a, b; } h128;

static void mix(h128 *h, const void *data, size_t n)
{
    const unsigned char *p = data;
    for (size_t i = 0; i < n; i++) {
        h->a = (h->a ^ p[i]) * 0x100000001b3ull;
        h->b = (h->b ^ p[i]) * 0x9E3779B97F4A7C15ull + 0x632BE59BD9B4E019ull;
    }
    /* separator so ("ab","c") and ("a","bc") differ */
    h->a = (h->a ^ 0xFF) * 0x100000001b3ull;
    h->b = (h->b ^ (n & 0xFFFF)) * 0x9E3779B97F4A7C15ull;
}

int mgl_cache_key(const char *src[MGL_NUM_STAGES], const char *geometry, const mgl_frag_bind *binds, int nbinds,
                  char out[33])
{
    if (!cache_dir())
        return 0;
    h128 h = {0xcbf29ce484222325ull, 0x84222325cbf29ce4ull};
    mix(&h, build_tag, sizeof build_tag);
    for (int s = 0; s < MGL_NUM_STAGES; s++)
        mix(&h, src[s] ? src[s] : "", src[s] ? strlen(src[s]) : 0);
    mix(&h, geometry ? geometry : "", geometry ? strlen(geometry) : 0);
    for (int i = 0; i < nbinds; i++) {
        mix(&h, binds[i].name, strlen(binds[i].name));
        mix(&h, &binds[i].loc, sizeof binds[i].loc);
    }
    snprintf(out, 33, "%016llx%016llx", (unsigned long long)h.a, (unsigned long long)h.b);
    return 1;
}

/* ---- serialisation: plain-old-data arrays written as-is, strings length-prefixed ---- */

static void put(FILE *f, const void *p, size_t n) { fwrite(p, 1, n, f); }
static void put_int(FILE *f, int v) { put(f, &v, sizeof v); }
static void put_str(FILE *f, const char *s)
{
    int n = s ? (int)strlen(s) : -1;
    put_int(f, n);
    if (n > 0)
        put(f, s, (size_t)n);
}

static int get(FILE *f, void *p, size_t n) { return fread(p, 1, n, f) == n; }
static int get_int(FILE *f, int *v) { return get(f, v, sizeof *v); }
static int get_str(FILE *f, char **s)
{
    int n;
    *s = NULL;
    if (!get_int(f, &n) || n > (64 << 20))
        return 0;
    if (n < 0)
        return 1;
    *s = malloc((size_t)n + 1);
    if (!get(f, *s, (size_t)n))
        return 0;
    (*s)[n] = 0;
    return 1;
}
static int get_arr(FILE *f, void **arr, int *count, size_t elem)
{
    if (!get_int(f, count) || *count < 0 || *count > 100000)
        return 0;
    *arr = calloc((size_t)(*count ? *count : 1), elem);
    return get(f, *arr, elem * (size_t)*count);
}

void mgl_cache_store(const char *key, const mgl_xlate_result *r)
{
    const char *dir = cache_dir();
    if (!dir || !r->ok)
        return;
    char path[1024], tmp[1100];
    snprintf(path, sizeof path, "%s/%s.mclx", dir, key);
    static unsigned seq; /* stores run on link worker threads too */
    snprintf(tmp, sizeof tmp, "%s.%d.%u.tmp", path, (int)getpid(), __atomic_add_fetch(&seq, 1, __ATOMIC_RELAXED));
    FILE *f = fopen(tmp, "wb");
    if (!f)
        return;
    put_int(f, (int)MAGIC);
    put_int(f, (int)sizeof(mgl_uniform) ^ (int)sizeof(mgl_texture_slot) << 12); /* layout guard */
    for (int s = 0; s < MGL_NUM_STAGES; s++)
        put_str(f, r->msl[s]);
    put(f, r->default_block_size, sizeof r->default_block_size);
    put(f, r->used_ranges, sizeof r->used_ranges);
    put(f, r->num_used_ranges, sizeof r->num_used_ranges);
    put(f, r->local_size, sizeof r->local_size);
    put_int(f, r->num_uniforms); put(f, r->uniforms, sizeof *r->uniforms * (size_t)r->num_uniforms);
    put_int(f, r->num_textures); put(f, r->textures, sizeof *r->textures * (size_t)r->num_textures);
    put_int(f, r->num_ubos); put(f, r->ubos, sizeof *r->ubos * (size_t)r->num_ubos);
    put_int(f, r->num_ssbos); put(f, r->ssbos, sizeof *r->ssbos * (size_t)r->num_ssbos);
    put_int(f, r->num_attribs); put(f, r->attribs, sizeof *r->attribs * (size_t)r->num_attribs);
    put_int(f, r->num_outs); put(f, r->outs, sizeof *r->outs * (size_t)r->num_outs);
    put_int(f, r->gs_max_vertices);
    put_int(f, r->gs_record_floats);
    put_int(f, r->uses_scene);
    put_str(f, r->log);
    int bad = ferror(f);
    fclose(f);
    if (bad || rename(tmp, path))
        unlink(tmp);
}

int mgl_cache_load(const char *key, mgl_xlate_result *r)
{
    const char *dir = cache_dir();
    if (!dir)
        return 0;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s.mclx", dir, key);
    FILE *f = fopen(path, "rb");
    if (!f)
        return 0;
    memset(r, 0, sizeof *r);
    int magic, guard, ok = get_int(f, &magic) && magic == (int)MAGIC && get_int(f, &guard) &&
                              guard == ((int)sizeof(mgl_uniform) ^ (int)sizeof(mgl_texture_slot) << 12);
    for (int s = 0; ok && s < MGL_NUM_STAGES; s++)
        ok = get_str(f, &r->msl[s]);
    ok = ok && get(f, r->default_block_size, sizeof r->default_block_size) && get(f, r->used_ranges, sizeof r->used_ranges) &&
         get(f, r->num_used_ranges, sizeof r->num_used_ranges) && get(f, r->local_size, sizeof r->local_size);
    ok = ok && get_arr(f, (void **)&r->uniforms, &r->num_uniforms, sizeof *r->uniforms);
    ok = ok && get_arr(f, (void **)&r->textures, &r->num_textures, sizeof *r->textures);
    ok = ok && get_arr(f, (void **)&r->ubos, &r->num_ubos, sizeof *r->ubos);
    ok = ok && get_arr(f, (void **)&r->ssbos, &r->num_ssbos, sizeof *r->ssbos);
    ok = ok && get_arr(f, (void **)&r->attribs, &r->num_attribs, sizeof *r->attribs);
    ok = ok && get_arr(f, (void **)&r->outs, &r->num_outs, sizeof *r->outs);
    ok = ok && get_int(f, &r->gs_max_vertices) && get_int(f, &r->gs_record_floats) && get_int(f, &r->uses_scene);
    ok = ok && get_str(f, &r->log);
    for (int s = 0; ok && s < MGL_NUM_STAGES; s++) { /* a damaged file must not index past used_ranges */
        int n = r->num_used_ranges[s];
        if (n < -1 || n > 64)
            ok = 0;
        for (int k = 0; ok && k < n; k++)
            ok = r->used_ranges[s][k][0] >= 0 && r->used_ranges[s][k][1] > 0 &&
                 (long)r->used_ranges[s][k][0] + r->used_ranges[s][k][1] <= (long)r->default_block_size[s];
    }
    fclose(f);
    if (!ok) {
        mgl_xlate_free(r);
        memset(r, 0, sizeof *r);
        unlink(path); /* damaged or from another layout: drop it */
        return 0;
    }
    r->ok = 1;
    return 1;
}
