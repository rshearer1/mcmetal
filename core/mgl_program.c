#include <time.h>
/* Shaders, programs, uniforms. Shaders are kept as source; translation to Metal happens at glLinkProgram,
   when all stages are known (inputs/outputs are matched across stages by name). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mgl_state.h"
#include "mgl_cache.h"
#include <pthread.h>
#include <unistd.h>

/* ---- background link work ----
   glLinkProgram does glslang + reflection on the caller's thread, because Iris asks for the link status and
   every uniform location straight away. The expensive rest (SPIRV-Cross MSL emission, Apple's MSL compiler,
   compute pipeline creation) runs on worker threads, so a shader pack's ~100 programs compile on all cores
   while Iris carries on creating the next ones. The first draw with a program waits for its job.
   MGL_ASYNC_LINK=0 turns this off. */
typedef struct mgl_link_job {
    struct mgl_link_job *next;
    void *pending[MGL_NUM_STAGES];
    char *msl[MGL_NUM_STAGES];  /* emitted MSL (or the cached copy) */
    const mgl_xlate_result *x;  /* reflection, read-only while the job runs */
    char key[33];
    int store;                  /* write the cache entry once MSL exists */
    mglb_program *gpu;
    char *err;
    GLuint name;
    int done;
} mgl_link_job;

static pthread_mutex_t job_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t job_ready = PTHREAD_COND_INITIALIZER, job_done = PTHREAD_COND_INITIALIZER;
static mgl_link_job *queue_head, *queue_tail;
static int jobs_running; /* taken off the queue, not done yet */

/* MGL_MSL_DUMP=dir: write every program's MSL there (<key>.<stage>.metal), e.g. for an offline `xcrun metal` check */
static void dump_msl(const mgl_link_job *j)
{
    static const char *const ext[MGL_NUM_STAGES] = {"vertex", "fragment", "compute"};
    const char *dir = getenv("MGL_MSL_DUMP");
    if (!dir || !*dir)
        return;
    static unsigned seq;
    unsigned n = __atomic_add_fetch(&seq, 1, __ATOMIC_RELAXED);
    for (int s = 0; s < MGL_NUM_STAGES; s++) {
        if (!j->msl[s])
            continue;
        char path[1024], tmp[1040];
        snprintf(path, sizeof path, "%s/%s-%u.%s.metal", dir, j->key[0] ? j->key : "nokey", n, ext[s]);
        snprintf(tmp, sizeof tmp, "%s.part", path);
        FILE *f = fopen(tmp, "w");
        if (f) { /* whole files only: a background compile can still be writing when a short test exits */
            int ok = fputs(j->msl[s], f) >= 0;
            if (fclose(f) == 0 && ok)
                rename(tmp, path);
        }
    }
}

static void run_job(mgl_link_job *j)
{
    if (j->pending[0] || j->pending[1] || j->pending[2]) {
        if (!mgl_xlate_emit(j->pending, j->msl, &j->err))
            return;
        if (j->store) {
            mgl_xlate_result c = *j->x; /* shallow: reflection arrays are shared, not copied */
            memcpy(c.msl, j->msl, sizeof c.msl);
            c.ok = 1;
            mgl_cache_store(j->key, &c);
        }
    }
    dump_msl(j);
    j->gpu = mglb_program_new(j->msl[MGL_VERTEX], j->msl[MGL_FRAGMENT], j->msl[MGL_COMPUTE], &j->err);
    if (!j->gpu && !j->err)
        j->err = strdup("Metal compile failed");
}

static void *worker(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&job_lock);
    for (;;) {
        while (!queue_head)
            pthread_cond_wait(&job_ready, &job_lock);
        mgl_link_job *j = queue_head;
        queue_head = j->next;
        if (!queue_head)
            queue_tail = NULL;
        jobs_running++;
        pthread_mutex_unlock(&job_lock);
        run_job(j);
        pthread_mutex_lock(&job_lock);
        jobs_running--;
        j->done = 1;
        pthread_cond_broadcast(&job_done);
    }
    return NULL;
}

/* at exit: let queued and running compiles finish. exit() otherwise tears down glslang's and Metal's globals
   under a worker that is still using them (gl_smoke crashed with exit code 139 after its last check; a game
   quit while a shader pack compiles can too). */
static void drain_jobs(void)
{
    pthread_mutex_lock(&job_lock);
    while (queue_head || jobs_running)
        pthread_cond_wait(&job_done, &job_lock);
    pthread_mutex_unlock(&job_lock);
}

static int async_link(void)
{
    static int workers = -1;
    if (workers < 0) {
        const char *e = getenv("MGL_ASYNC_LINK");
        long n = sysconf(_SC_NPROCESSORS_ONLN) - 1; /* leave the render thread its core */
        workers = e && *e == '0' ? 0 : n < 1 ? 1 : n > 15 ? 15 : (int)n;
        for (int i = 0; i < workers; i++) {
            pthread_t t;
            pthread_attr_t a;
            pthread_attr_init(&a);
            pthread_attr_setstacksize(&a, 16u << 20); /* glslang/SPIRV-Cross recurse deeply on big shaders */
            if (pthread_create(&t, &a, worker, NULL) == 0)
                pthread_detach(t);
            pthread_attr_destroy(&a);
        }
        if (workers) {
            atexit(drain_jobs);
            mgl_log("compiling programs on %d background threads", workers);
        }
    }
    return workers;
}

static void submit_job(mgl_link_job *j)
{
    pthread_mutex_lock(&job_lock);
    if (queue_tail)
        queue_tail->next = j;
    else
        queue_head = j;
    queue_tail = j;
    pthread_cond_signal(&job_ready);
    pthread_mutex_unlock(&job_lock);
}

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec * 1e-6;
}
static double wait_ms; /* render-thread time spent waiting on jobs */

/* "GL program 12 gbuffers_water": the GL name plus the name the app gave it, for logs and MGL_*_PROGRAMS */
static void label_gpu(mgl_program *p, GLuint name)
{
    if (!p->gpu)
        return;
    char label[112];
    snprintf(label, sizeof label, "GL program %u%s%s", name, p->debug_name[0] ? " " : "", p->debug_name);
    mglb_program_label(p->gpu, label);
}

/* Applies a finished (or synchronous) job to its program. */
static void apply_job(mgl_program *p, mgl_link_job *j)
{
    for (int s = 0; s < MGL_NUM_STAGES; s++) {
        free(p->x.msl[s]);
        p->x.msl[s] = j->msl[s];
    }
    p->gpu = j->gpu;
    label_gpu(p, j->name);
    if (!p->gpu) {
        p->linked = 0; /* Iris already saw a successful link; draws with this program are skipped */
        free(p->info_log);
        p->info_log = j->err;
        mgl_log("Metal compile of program %u%s%s failed (work group %dx%dx%d):\n%s", j->name, p->debug_name[0] ? " " : "",
                p->debug_name, p->x.local_size[0], p->x.local_size[1], p->x.local_size[2], p->info_log);
    } else {
        free(j->err);
    }
    free(j);
}

void mgl_program_wait(mgl_program *p)
{
    mgl_link_job *j = p->job;
    if (!j)
        return;
    double t0 = now_ms();
    pthread_mutex_lock(&job_lock);
    while (!j->done)
        pthread_cond_wait(&job_done, &job_lock);
    pthread_mutex_unlock(&job_lock);
    wait_ms += now_ms() - t0;
    p->job = NULL;
    apply_job(p, j);
}

static int stage_of(GLenum type)
{
    switch (type) {
    case GL_VERTEX_SHADER: return MGL_VERTEX;
    case GL_FRAGMENT_SHADER: return MGL_FRAGMENT;
    case GL_COMPUTE_SHADER: return MGL_COMPUTE;
    case GL_GEOMETRY_SHADER: return MGL_GEOMETRY_SLOT;
    }
    return -1;
}

static mgl_shader *shader_obj(GLuint name) { return mgl_table_get(&mgl->shaders, name); }
static mgl_program *program_obj(GLuint name) { return mgl_table_get(&mgl->programs, name); }

void glObjectLabel(GLenum identifier, GLuint name, GLsizei length, const GLchar *label)
{
    mgl_program *p = identifier == GL_PROGRAM ? program_obj(name) : NULL;
    if (!p || !label)
        return;
    size_t n = length < 0 ? strlen(label) : (size_t)length;
    if (n >= sizeof p->debug_name)
        n = sizeof p->debug_name - 1;
    memcpy(p->debug_name, label, n);
    p->debug_name[n] = 0;
    label_gpu(p, name);
}

/* Shaders and programs share one name space in GL. */
GLuint glCreateShader(GLenum type)
{
    if (stage_of(type) < 0) {
        mgl_log("glCreateShader: shader type 0x%04X not supported", type);
        mgl_set_error(GL_INVALID_ENUM);
        return 0;
    }
    GLuint name = mgl_table_gen(&mgl->shaders);
    while (mgl_table_get(&mgl->programs, name))
        name = mgl_table_gen(&mgl->shaders);
    mgl_shader *s = calloc(1, sizeof *s);
    s->type = type;
    mgl_table_set(&mgl->shaders, name, s);
    mgl_table_set(&mgl->programs, name, NULL);
    return name;
}

static void free_shader(GLuint name)
{
    mgl_shader *s = shader_obj(name);
    free(s->source);
    free(s);
    mgl_table_remove(&mgl->shaders, name);
}

void glDeleteShader(GLuint name)
{
    mgl_shader *s = shader_obj(name);
    if (!s)
        return;
    if (s->refs)
        s->delete_pending = 1;
    else
        free_shader(name);
}

GLboolean glIsShader(GLuint name) { return shader_obj(name) != NULL; }

/* Hardware ray tracing for shader packs (step 2). A pack declares the prototype
       float mcm_trace(vec3 origin, vec3 dir, float tmax);   // distance to the first block hit, or -1
       float mcm_trace_cut(vec3 origin, vec3 dir, float tmax, out uint cut); // same; cut = the hit's alpha cutoff (0 = solid)
       float mcm_trace_hit(vec3 origin, vec3 dir, float tmax, out vec3 normal, out vec4 albedo, out vec2 lightmap,
                           out int blockId);  // closest hit: face normal, atlas texel * vertex colour, Sodium light
                                              // (block, sky; 0..1), Iris block id (-1 unless the terrain pass reads mc_Entity)
       float mcm_trace_tinted(vec3 origin, vec3 dir, float tmax, out vec3 transmit); // as mcm_trace; on a miss,
                                              // transmit = colour filter of the glass/water/ice on the way (1 = clear)
       int mcm_lights_near(vec3 p, int slot, out vec3 pos, out int blockId); // the slot-th nearest light block within
                                              // 16 blocks of p (ids from "#define MCMETAL_LIGHT_IDS lo hi", default
                                              // 10100 10299): index or -1; pos = block centre. MCMETAL_LIGHTS is defined.
   in plain GLSL (so Iris's own parser accepts it) and calls it; origin/dir are in Iris's player space
   (camera-relative world space). We supply the body with a GL_EXT_ray_query against the terrain scene. */
static void add_ray_tracing(mgl_shader *s)
{
    if (!strstr(s->source, "mcm_trace"))
        return;
    const char *v = strstr(s->source, "#version");
    if (!v)
        return;
    const char *eol = strchr(v, '\n');
    if (!eol)
        return;
    /* Cutout blocks (grass, leaves, flowers): candidate triangles get Sodium's alpha test against the block atlas,
       using the texture coordinates and cutoff that rt_decode stored per triangle (McmInstances -> per-section data). */
    static const char head[] = "#version 460\n#extension GL_EXT_ray_query : require\n"
                               "#extension GL_EXT_buffer_reference : require\n"
                               "layout(set = 7, binding = 0) uniform accelerationStructureEXT mcm_scene; // own set: no clash with SSBO 0\n"
                               "layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer McmTris { uint w[]; };\n"
                               "layout(std430, binding = 15) readonly buffer McmInstances { McmTris mcm_tris[]; };\n"
                               "uniform sampler2D mcm_atlas;\n"
                               "#define MCMETAL_LIGHTS 1\n"
                               /* light list (mglb_rt_update): count, lights (camera-relative block centre, id),
                                  then a 16^3 grid of 4-block cells, each a count and up to 16 light indices */
                               "layout(std430, binding = 14) readonly buffer McmLights { uint mcm_lcount; uint mcm_lpad[3];\n"
                               "  vec4 mcm_light[2048]; uint mcm_lcell[]; };\n";
    /* McmTris: 12 words per triangle, written by rt_decode (mac/mgl_metal.m): 0-2 uv, 3 cutoff | 0x100 translucent,
       4-6 colour, 7 octahedral normal, 8-10 light, 11 Iris block id + 1; 0x200 in word 3 = untextured (entities,
       mglb_rt_dynamic). Candidates (every triangle is non-opaque)
       pass Sodium's alpha test against the block atlas before they count. */
    static const char body[] =
        "\nvec2 mcm_uv(McmTris t, uint b, vec2 w) {\n"
        "  return (unpackUnorm2x16(t.w[b]) * (1.0 - w.x - w.y) + unpackUnorm2x16(t.w[b + 1u]) * w.x\n"
        "          + unpackUnorm2x16(t.w[b + 2u]) * w.y) * (65535.0 / 32768.0);\n"
        "}\n"
        "vec4 mcm_colour(McmTris t, uint b, vec2 w) {\n"
        "  return unpackUnorm4x8(t.w[b + 4u]) * (1.0 - w.x - w.y) + unpackUnorm4x8(t.w[b + 5u]) * w.x\n"
        "       + unpackUnorm4x8(t.w[b + 6u]) * w.y;\n"
        "}\n"
        "bool mcm_opaque_at(McmTris t, uint b, vec2 w) {\n"
        "  uint cut = t.w[b + 3u] & 0xFFu;\n"
        "  return cut == 0u || textureLod(mcm_atlas, mcm_uv(t, b, w), 0.0).a >= (cut == 3u ? 1.0 : 0.1);\n"
        "}\n"
        "#define MCM_QUERY(q, flags, o, d, tmax) \\\n"
        "  rayQueryInitializeEXT(q, mcm_scene, flags, 0x01, o, 0.001, d, tmax); \\\n"
        "  while (rayQueryProceedEXT(q)) { \\\n"
        "    McmTris t_ = mcm_tris[rayQueryGetIntersectionInstanceIdEXT(q, false)]; \\\n"
        "    uint b_ = uint(rayQueryGetIntersectionPrimitiveIndexEXT(q, false)) * 12u; \\\n"
        "    if (mcm_opaque_at(t_, b_, rayQueryGetIntersectionBarycentricsEXT(q, false))) \\\n"
        "      rayQueryConfirmIntersectionEXT(q); \\\n"
        "  }\n"
        "#define MCM_MISSED(q) (rayQueryGetIntersectionTypeEXT(q, true) == gl_RayQueryCommittedIntersectionNoneEXT)\n"
        "float mcm_trace(vec3 origin, vec3 dir, float tmax) {\n"
        "  rayQueryEXT q;\n"
        "  MCM_QUERY(q, gl_RayFlagsTerminateOnFirstHitEXT, origin, dir, tmax)\n"
        "  return MCM_MISSED(q) ? -1.0 : rayQueryGetIntersectionTEXT(q, true);\n"
        "}\n"
        "float mcm_trace_cut(vec3 origin, vec3 dir, float tmax, out uint cut) {\n"
        "  rayQueryEXT q;\n"
        "  MCM_QUERY(q, gl_RayFlagsTerminateOnFirstHitEXT, origin, dir, tmax)\n"
        "  cut = 0u;\n"
        "  if (MCM_MISSED(q)) return -1.0;\n"
        "  McmTris t = mcm_tris[rayQueryGetIntersectionInstanceIdEXT(q, true)];\n"
        "  cut = t.w[uint(rayQueryGetIntersectionPrimitiveIndexEXT(q, true)) * 12u + 3u] & 0xFFu;\n"
        "  return rayQueryGetIntersectionTEXT(q, true);\n"
        "}\n"
        "float mcm_trace_hit(vec3 origin, vec3 dir, float tmax, out vec3 normal, out vec4 albedo, out vec2 lightmap,\n"
        "                    out int blockId) {\n"
        "  rayQueryEXT q;\n"
        "  MCM_QUERY(q, gl_RayFlagsNoneEXT, origin, dir, tmax)\n"
        "  normal = vec3(0.0); albedo = vec4(0.0); lightmap = vec2(0.0); blockId = -1;\n"
        "  if (MCM_MISSED(q)) return -1.0;\n"
        "  McmTris t = mcm_tris[rayQueryGetIntersectionInstanceIdEXT(q, true)];\n"
        "  uint b = uint(rayQueryGetIntersectionPrimitiveIndexEXT(q, true)) * 12u;\n"
        "  vec2 w = rayQueryGetIntersectionBarycentricsEXT(q, true);\n"
        "  vec2 on = unpackSnorm2x16(t.w[b + 7u]);\n"
        "  vec3 n = vec3(on, 1.0 - abs(on.x) - abs(on.y));\n"
        "  if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);\n"
        "  normal = normalize(n);\n"
        "  if (dot(normal, dir) > 0.0) normal = -normal; /* the face the ray hit */\n"
        "  albedo = ((t.w[b + 3u] & 0x200u) != 0u ? vec4(1.0) : textureLod(mcm_atlas, mcm_uv(t, b, w), 0.0))\n"
        "         * vec4(mcm_colour(t, b, w).rgb, 1.0);\n"
        "  uvec3 l = uvec3(t.w[b + 8u], t.w[b + 9u], t.w[b + 10u]);\n"
        "  vec3 wv = vec3(1.0 - w.x - w.y, w.x, w.y);\n"
        "  lightmap = vec2(dot(vec3(l & 0xFFu), wv), dot(vec3((l >> 8u) & 0xFFu), wv)) / 256.0;\n"
        "  blockId = int(t.w[b + 11u]) - 1;\n"
        "  return rayQueryGetIntersectionTEXT(q, true);\n"
        "}\n"
        "float mcm_trace_tinted(vec3 origin, vec3 dir, float tmax, out vec3 transmit) {\n"
        "  float hit = mcm_trace(origin, dir, tmax);\n"
        "  transmit = vec3(hit >= 0.0 ? 0.0 : 1.0);\n"
        "  if (hit >= 0.0) return hit;\n"
        "  rayQueryEXT q; /* nothing solid on the way: filter through every translucent face (glass, water, ice) */\n"
        "  rayQueryInitializeEXT(q, mcm_scene, gl_RayFlagsNoneEXT, 0x02, origin, 0.001, dir, tmax);\n"
        "  while (rayQueryProceedEXT(q)) {\n"
        "    McmTris t = mcm_tris[rayQueryGetIntersectionInstanceIdEXT(q, false)];\n"
        "    uint b = uint(rayQueryGetIntersectionPrimitiveIndexEXT(q, false)) * 12u;\n"
        "    vec2 w = rayQueryGetIntersectionBarycentricsEXT(q, false);\n"
        "    vec4 tex = textureLod(mcm_atlas, mcm_uv(t, b, w), 0.0);\n"
        "    transmit *= mix(vec3(1.0), tex.rgb * mcm_colour(t, b, w).rgb, tex.a);\n"
        "  }\n"
        "  return -1.0;\n"
        "}\n"
        /* the slot-th nearest light block (id in the pack's MCMETAL_LIGHT_IDS range) within 16 blocks of p:
           returns its index and sets pos (block centre, player space) and blockId, or -1 */
        "int mcm_lights_near(vec3 p, int slot, out vec3 pos, out int blockId) {\n"
        "  pos = vec3(0.0); blockId = -1;\n"
        "  ivec3 c = ivec3(floor((p + 32.0) / 4.0));\n"
        "  if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(16)))) return -1;\n"
        "  uint base = uint((c.z * 16 + c.y) * 16 + c.x) * 17u, n = min(mcm_lcell[base], 16u);\n"
        "  float last = -1.0; uint li = 0xFFFFFFFFu;\n"
        "  for (int s = 0; s <= slot; s++) {\n"
        "    float best = 1e30; uint bi = 0xFFFFFFFFu;\n"
        "    for (uint k = 0u; k < n; k++) {\n"
        "      uint j = mcm_lcell[base + 1u + k];\n"
        "      float d = distance(p, mcm_light[j].xyz);\n"
        "      if (d > 16.0 || d < last || (d == last && j <= li)) continue;\n"
        "      if (d < best || (d == best && j < bi)) { best = d; bi = j; }\n"
        "    }\n"
        "    if (bi == 0xFFFFFFFFu) return -1;\n"
        "    last = best; li = bi;\n"
        "  }\n"
        "  pos = mcm_light[li].xyz; blockId = int(mcm_light[li].w);\n"
        "  return int(li);\n"
        "}\n";
    /* MCMETAL_LIGHT_IDS lo hi: which block ids mcm_lights_near lists (the last program to say wins) */
    const char *li = strstr(s->source, "#define MCMETAL_LIGHT_IDS");
    int lo = 10100, hi = 10299; /* default for packs that call mcm_lights_near without saying */
    if ((li && sscanf(li + 25, "%d %d", &lo, &hi) == 2 && lo <= hi) ||
        (!li && mgl_rt_light_ids[0] < 0 && strstr(s->source, "mcm_lights_near"))) {
        if (lo != mgl_rt_light_ids[0] || hi != mgl_rt_light_ids[1])
            mgl_log("ray tracing: light list collects block ids %d-%d", lo, hi);
        mgl_rt_light_ids[0] = lo;
        mgl_rt_light_ids[1] = hi;
    }
    size_t pre = (size_t)(v - s->source), rest = strlen(eol + 1);
    char *n = malloc(pre + sizeof head + rest + sizeof body);
    memcpy(n, s->source, pre);
    memcpy(n + pre, head, sizeof head - 1);
    memcpy(n + pre + sizeof head - 1, eol + 1, rest);
    memcpy(n + pre + sizeof head - 1 + rest, body, sizeof body);
    free(s->source);
    s->source = n;
    static int noted;
    if (!noted++)
        mgl_log("shader uses mcm_trace: hardware ray tracing enabled for it");
}

/* MCMETAL_PHOTON_RT=1: ray-traced shadows for Photon's coloured block light (the job its Photonics slot leaves to
   the Photonics mod). Photon's light comes from a flood-filled light volume that bends round corners and has no
   sharp shadows. We keep that light (its brightness and colour are Photon's own), and scale it by what the four
   nearest light blocks (Photon's ids 32-79, its own colour table) can actually see: one shadow ray each from the
   surface to the light's centre. Where every light is hidden, a quarter stays as bounce light. A light in view
   but another of a different colour hidden shifts the tint towards the one in view. Photon's licence allows this
   kind of derivative; nothing of the pack is changed on disk. */
static void add_photon_rt(mgl_shader *s)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MCMETAL_PHOTON_RT");
        on = e && *e && *e != '0';
    }
    char *f = on && s->type == GL_FRAGMENT_SHADER ? strstr(s->source, "vec3 get_lpv_blocklight(") : NULL;
    if (!f || !strstr(s->source, "vec3 get_block_lighting(") || strstr(s->source, "mcm_photon_lpv"))
        return;
    /* the end of Photon's function: its closing brace */
    char *b = strchr(f, '{');
    int depth = 0;
    char *end = NULL;
    for (char *q = b; q && *q; q++) {
        if (*q == '{')
            depth++;
        else if (*q == '}' && --depth == 0) {
            end = q + 1;
            break;
        }
    }
    if (!end)
        return;
    static const char wrap[] =
        "\n#define MCMETAL_LIGHT_IDS 32 79\n"
        "int mcm_lights_near(vec3 p, int slot, out vec3 pos, out int blockId);\n"
        "float mcm_trace(vec3 origin, vec3 dir, float tmax);\n"
        "const vec3 mcm_photon_light[48] = vec3[48](\n"
        "  vec3(1.0,1.0,1.0)*12.0, vec3(1.0,1.0,1.0)*6.0, vec3(1.0,1.0,1.0), vec3(1.0,0.55,0.27)*14.0,\n"
        "  vec3(1.0,0.57,0.3)*8.0, vec3(1.0,0.57,0.3)*6.0, vec3(1.0,0.18,0.1)*5.0, vec3(1.0,0.38,0.1)*7.0,\n"
        "  vec3(1.0,0.45,0.1)*9.0, vec3(1.0,0.63,0.15)*4.0, vec3(1.0,0.57,0.3)*12.0, vec3(0.45,0.73,1.0)*6.0,\n"
        "  vec3(0.45,0.73,1.0)*14.0, vec3(0.75,1.0,0.83)*3.0, vec3(0.75,1.0,0.83), vec3(0.6,0.1,1.0)*2.5,\n"
        "  vec3(0.75,1.0,0.5), vec3(1.0,0.5,0.25)*4.0, vec3(1.0,0.57,0.3)*8.0, vec3(1.0,0.65,0.3)*8.0,\n"
        "  vec3(0.86,1.0,0.44)*8.0, vec3(0.75,0.44,1.0)*8.0, vec3(0.6,0.1,1.0)*2.0, vec3(0.75,0.44,1.0)*4.0,\n"
        "  vec3(0.75,0.44,1.0)*4.0, vec3(0.75,1.0,0.83)*6.0, vec3(1.0,0.18,0.1)*3.3, vec3(1.0,0.5,0.25)*3.0,\n"
        "  vec3(0.85,1.3,1.0)*3.9, vec3(1.0,0.57,0.3)*8.0, vec3(0.6,0.1,1.0)*12.0, vec3(0.0),\n"
        "  vec3(1.0)*10.0, vec3(0.85)*9.0, vec3(0.55)*8.0, vec3(0.2,0.2,0.22)*6.0, vec3(0.55,0.35,0.2)*8.0,\n"
        "  vec3(1.0,0.1,0.1)*10.0, vec3(1.0,0.45,0.1)*10.0, vec3(1.0,0.95,0.2)*10.0, vec3(0.55,1.0,0.2)*10.0,\n"
        "  vec3(0.15,1.0,0.2)*10.0, vec3(0.15,0.95,1.0)*10.0, vec3(0.45,0.75,1.0)*10.0, vec3(0.15,0.3,1.0)*10.0,\n"
        "  vec3(0.55,0.15,1.0)*10.0, vec3(1.0,0.2,0.9)*10.0, vec3(1.0,0.55,0.85)*10.0);\n"
        "vec3 get_lpv_blocklight(vec3 scene_pos, vec3 normal, vec3 mc_blocklight, float ao) {\n"
        "  vec3 lpv = mcm_photon_lpv(scene_pos, normal, mc_blocklight, ao);\n"
        "  vec3 seen = vec3(0.0), all_ = vec3(0.0);\n"
        "  vec3 o = scene_pos + normal * 0.02;\n"
        "  for (int i = 0; i < 4; i++) {\n"
        "    vec3 lp; int id;\n"
        "    if (mcm_lights_near(scene_pos, i, lp, id) < 0) break;\n"
        "    vec3 d = lp - o;\n"
        "    float dist = length(d);\n"
        "    vec3 dir = d / max(dist, 1e-4);\n"
        "    float fade = clamp(1.0 - dist / 15.0, 0.0, 1.0);\n"
        "    float ndl = dist < 0.9 ? 1.0 : max(dot(normal, dir), 0.0);\n"
        "    vec3 c = mcm_photon_light[clamp(id - 32, 0, 47)] * fade * fade * ndl / (0.25 * dist * dist + 1.0);\n"
        "    if (dot(c, vec3(1.0)) <= 0.0) continue;\n"
        "    all_ += c;\n"
        /* stop short of the light block itself (a full block's faces are 0.5 from its centre, corners up to 0.87) */
        "    if (dist <= 0.9 || mcm_trace(o + dir * 0.01, dir, dist - 0.9) < 0.0) seen += c;\n"
        "  }\n"
        "  if (dot(all_, vec3(1.0)) <= 1e-4) return lpv;\n"
        "  return lpv * mix(vec3(0.25), min(seen / max(all_, vec3(1e-4)), vec3(2.0)), 0.75);\n"
        "}\n";
    size_t pre = (size_t)(f - s->source);
    const char *nm = "vec3 mcm_photon_lpv(";
    size_t oldnm = strlen("vec3 get_lpv_blocklight(");
    size_t head = (size_t)(end - (f + oldnm)), rest = strlen(end);
    char *n = malloc(pre + strlen(nm) + head + sizeof wrap + rest);
    char *o = n;
    memcpy(o, s->source, pre); o += pre;
    memcpy(o, nm, strlen(nm)); o += strlen(nm);
    memcpy(o, f + oldnm, head); o += head;
    memcpy(o, wrap, sizeof wrap - 1); o += sizeof wrap - 1;
    memcpy(o, end, rest + 1);
    free(s->source);
    s->source = n;
    static int noted;
    if (!noted++)
        mgl_log("Photon: ray-traced shadows for its coloured block light (MCMETAL_PHOTON_RT)");
}

void glShaderSource(GLuint name, GLsizei count, const GLchar *const *strings, const GLint *lengths)
{
    mgl_shader *s = shader_obj(name);
    if (!s)
        return;
    size_t total = 0;
    for (GLsizei i = 0; i < count; i++)
        total += lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
    free(s->source);
    s->source = malloc(total + 1);
    size_t o = 0;
    for (GLsizei i = 0; i < count; i++) {
        size_t n = lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
        memcpy(s->source + o, strings[i], n);
        o += n;
    }
    s->source[o] = 0;
    /* Iris tells shader packs they're on a Mac, and Complementary then hard-disables its coloured light
       tracing because Apple's OpenGL 4.1 can't run it. We can, so hide the Mac define (same length, so line
       numbers in error logs stay right). */
    for (char *p = s->source; (p = strstr(p, "#define MC_OS_MAC")) != NULL; p += 17) {
        char c = p[17];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0) {
            memcpy(p, "#define MCM_OS_MC", 17);
            static int noted;
            if (!noted++)
                mgl_log("hiding MC_OS_MAC from shaders (Iris's macOS define)");
        }
    }
    add_photon_rt(s);
    add_ray_tracing(s);
}

void glCompileShader(GLuint name)
{
    mgl_shader *s = shader_obj(name);
    if (s)
        s->compiled = s->source != NULL; /* real errors surface at link time */
}

void glGetShaderiv(GLuint name, GLenum pname, GLint *out)
{
    mgl_shader *s = shader_obj(name);
    *out = 0;
    if (!s)
        return;
    switch (pname) {
    case GL_COMPILE_STATUS: *out = s->compiled; break;
    case GL_SHADER_TYPE: *out = (GLint)s->type; break;
    case GL_DELETE_STATUS: *out = s->delete_pending; break;
    case GL_INFO_LOG_LENGTH: *out = 0; break;
    case GL_SHADER_SOURCE_LENGTH: *out = s->source ? (GLint)strlen(s->source) + 1 : 0; break;
    }
}

void glGetShaderInfoLog(GLuint name, GLsizei max, GLsizei *len, GLchar *log)
{
    if (len)
        *len = 0;
    if (max > 0)
        log[0] = 0;
}

void glGetShaderSource(GLuint name, GLsizei max, GLsizei *len, GLchar *out)
{
    mgl_shader *s = shader_obj(name);
    const char *src = s && s->source ? s->source : "";
    GLsizei n = (GLsizei)strlen(src);
    if (n > max - 1)
        n = max - 1;
    if (n < 0)
        n = 0;
    if (max > 0) {
        memcpy(out, src, (size_t)n);
        out[n] = 0;
    }
    if (len)
        *len = n;
}

GLuint glCreateProgram(void)
{
    GLuint name = mgl_table_gen(&mgl->programs);
    while (mgl_table_get(&mgl->shaders, name))
        name = mgl_table_gen(&mgl->programs);
    mgl_program *p = calloc(1, sizeof *p);
    mgl_table_set(&mgl->programs, name, p);
    return name;
}

static void release_link(mgl_program *p)
{
    mgl_program_wait(p);
    if (p->gpu)
        mglb_program_release(p->gpu);
    p->gpu = NULL;
    mgl_xlate_free(&p->x);
    free(p->name_hash);
    p->name_hash = NULL;
    for (int s = 0; s < 3; s++) {
        free(p->ublock[s]);
        p->ublock[s] = NULL;
    }
    free(p->info_log);
    p->info_log = NULL;
    p->linked = 0;
}

static void detach_all(mgl_program *p)
{
    for (int s = 0; s < 4; s++) {
        mgl_shader *sh = shader_obj(p->attached[s]);
        if (sh && --sh->refs == 0 && sh->delete_pending)
            free_shader(p->attached[s]);
        p->attached[s] = 0;
    }
}

void glDeleteProgram(GLuint name)
{
    mgl_program *p = program_obj(name);
    if (!p)
        return;
    if (mgl->current_program == name) {
        p->delete_pending = 1;
        return;
    }
    release_link(p);
    detach_all(p);
    free(p->bound_attribs);
    free(p->bound_frag);
    free(p);
    mgl_table_remove(&mgl->programs, name);
}

GLboolean glIsProgram(GLuint name) { return program_obj(name) != NULL; }

void glAttachShader(GLuint prog, GLuint shader)
{
    mgl_program *p = program_obj(prog);
    mgl_shader *s = shader_obj(shader);
    if (!p || !s)
        return;
    int st = stage_of(s->type);
    if (p->attached[st] == shader)
        return;
    if (p->attached[st]) {
        mgl_shader *old = shader_obj(p->attached[st]);
        if (old && --old->refs == 0 && old->delete_pending)
            free_shader(p->attached[st]);
    }
    p->attached[st] = shader;
    s->refs++;
}

void glDetachShader(GLuint prog, GLuint shader)
{
    mgl_program *p = program_obj(prog);
    mgl_shader *s = shader_obj(shader);
    if (!p || !s)
        return;
    int st = stage_of(s->type);
    if (p->attached[st] != shader)
        return;
    p->attached[st] = 0;
    if (--s->refs == 0 && s->delete_pending)
        free_shader(shader);
}

void glBindAttribLocation(GLuint prog, GLuint index, const GLchar *name)
{
    mgl_program *p = program_obj(prog);
    if (!p)
        return;
    for (int i = 0; i < p->num_bound_attribs; i++)
        if (!strcmp(p->bound_attribs[i].name, name)) {
            p->bound_attribs[i].index = (int)index;
            return;
        }
    p->bound_attribs = realloc(p->bound_attribs, sizeof(*p->bound_attribs) * (size_t)(p->num_bound_attribs + 1));
    snprintf(p->bound_attribs[p->num_bound_attribs].name, 96, "%s", name);
    p->bound_attribs[p->num_bound_attribs++].index = (int)index;
}

void glBindFragDataLocation(GLuint prog, GLuint color, const GLchar *name)
{
    mgl_program *p = program_obj(prog);
    if (!p)
        return;
    p->bound_frag = realloc(p->bound_frag, sizeof(*p->bound_frag) * (size_t)(p->num_bound_frag + 1));
    snprintf(p->bound_frag[p->num_bound_frag].name, 96, "%s", name);
    p->bound_frag[p->num_bound_frag++].loc = (int)color;
}

/* GL attribute index for each reflected vertex input: glBindAttribLocation wins, then the shader's own
   location, then the next free index. gl_index_to_loc[] maps back to the MSL attribute. */
static void assign_attribs(mgl_program *p)
{
    int used[MGL_MAX_VERTEX_ATTRIBS] = {0};
    int gl_index[64];
    for (int i = 0; i < MGL_MAX_VERTEX_ATTRIBS; i++)
        p->gl_index_to_loc[i] = -1;
    for (int a = 0; a < p->x.num_attribs && a < 64; a++) {
        gl_index[a] = -1;
        for (int b = 0; b < p->num_bound_attribs; b++)
            if (!strcmp(p->bound_attribs[b].name, p->x.attribs[a].name))
                gl_index[a] = p->bound_attribs[b].index;
        if (gl_index[a] >= 0 && gl_index[a] < MGL_MAX_VERTEX_ATTRIBS)
            used[gl_index[a]] = 1;
    }
    for (int a = 0; a < p->x.num_attribs && a < 64; a++) {
        if (gl_index[a] < 0) {
            int want = p->x.attribs[a].location;
            if (want < 0 || want >= MGL_MAX_VERTEX_ATTRIBS || used[want])
                for (want = 0; want < MGL_MAX_VERTEX_ATTRIBS && used[want]; want++)
                    ;
            gl_index[a] = want;
            if (want < MGL_MAX_VERTEX_ATTRIBS)
                used[want] = 1;
        }
        if (gl_index[a] < MGL_MAX_VERTEX_ATTRIBS)
            p->gl_index_to_loc[gl_index[a]] = p->x.attribs[a].location;
    }
    for (int a = 0; a < p->x.num_attribs && a < 64; a++)
        p->attrib_gl_index[a] = gl_index[a];
}

void glLinkProgram(GLuint prog)
{
    mgl_program *p = program_obj(prog);
    if (!p)
        return;
    release_link(p);
    const char *src[MGL_NUM_STAGES] = {0};
    for (int s = 0; s < MGL_NUM_STAGES; s++) {
        mgl_shader *sh = shader_obj(p->attached[s]);
        src[s] = sh ? sh->source : NULL;
    }
    mgl_shader *gsh = shader_obj(p->attached[MGL_GEOMETRY_SLOT]);
    const char *dump = getenv("MGL_DUMP_DIR");
    if (dump) {
        static const char *ext[4] = {"vsh", "fsh", "csh", "gsh"};
        for (int s = 0; s < 4; s++) {
            mgl_shader *sh = shader_obj(p->attached[s]);
            if (!sh || !sh->source)
                continue;
            char path[512];
            snprintf(path, sizeof path, "%s/prog%u.%s", dump, prog, ext[s]);
            FILE *f = fopen(path, "w");
            if (f) {
                fputs(sh->source, f);
                fclose(f);
            }
        }
    }
    double t0 = now_ms();
    static int links, hits;
    static double ms;
    links++;
    char key[33] = "";
    int cached = 0, keyed = mgl_cache_key(src, gsh ? gsh->source : NULL, p->bound_frag, p->num_bound_frag, key);
    if (keyed)
        cached = mgl_cache_load(key, &p->x);
    int background = async_link() > 0;
    if (!cached) {
        mgl_xlate_set_frag_binds(p->bound_frag, p->num_bound_frag);
        mgl_xlate_set_deferred(1);
        if (gsh && gsh->source)
            mgl_gs_translate(src, gsh->source, &p->x);
        else
            mgl_xlate_program(src, &p->x);
        mgl_xlate_set_deferred(0);
        mgl_xlate_set_frag_binds(NULL, 0);
    }
    hits += cached;
    if (!p->x.ok) {
        ms += now_ms() - t0;
        p->info_log = strdup(p->x.log ? p->x.log : "translation failed");
        mgl_log("link of program %u failed:\n%s", prog, p->info_log);
        return;
    }
    mgl_link_job *j = calloc(1, sizeof *j);
    memcpy(j->pending, p->x.pending, sizeof j->pending);
    memset(p->x.pending, 0, sizeof p->x.pending);
    for (int s = 0; s < MGL_NUM_STAGES; s++) { /* a cache hit already has MSL */
        j->msl[s] = p->x.msl[s];
        p->x.msl[s] = NULL;
    }
    j->x = &p->x;
    memcpy(j->key, key, sizeof key);
    j->store = keyed && !cached;
    j->name = prog;
    for (int s = 0; s < 3; s++)
        if (p->x.default_block_size[s])
            p->ublock[s] = calloc(1, (size_t)p->x.default_block_size[s]);
    for (int i = 0; i < p->x.num_textures && i < MGL_MAX_TEXTURES * 3; i++)
        p->unit_of[i] = p->image_unit_of[i] = 0;
    for (int i = 0; i < p->x.num_ubos && i < 12; i++)
        p->ubo_binding[i] = p->x.ubos[i].binding;
    for (int i = 0; i < p->x.num_ssbos && i < 8; i++)
        p->ssbo_binding[i] = p->x.ssbos[i].binding;
    assign_attribs(p);
    mgl_rt_link(p);
    if (p->x.log)
        mgl_log("program %u notes: %s", prog, p->x.log);
    p->linked = 1;
    if (background) {
        p->job = j;
        submit_job(j);
    } else {
        run_job(j);
        apply_job(p, j);
        if (!p->linked)
            mgl_log("(program %u)", prog);
    }
    ms += now_ms() - t0;
    if (links % 50 == 0)
        mgl_log("linked %d programs (%d from cache): %.0f ms in glLinkProgram, %.0f ms waiting for background compiles",
                links, hits, ms, wait_ms);
}

void glValidateProgram(GLuint prog) {}

void glGetProgramiv(GLuint prog, GLenum pname, GLint *out)
{
    mgl_program *p = program_obj(prog);
    *out = 0;
    if (!p)
        return;
    switch (pname) {
    case GL_LINK_STATUS: *out = p->linked; break;
    case GL_VALIDATE_STATUS: *out = p->linked; break;
    case GL_DELETE_STATUS: *out = p->delete_pending; break;
    case GL_INFO_LOG_LENGTH: *out = p->info_log ? (GLint)strlen(p->info_log) + 1 : 0; break;
    case GL_ATTACHED_SHADERS: for (int s = 0; s < 4; s++) *out += p->attached[s] != 0; break;
    case GL_ACTIVE_ATTRIBUTES: *out = p->x.num_attribs; break;
    case GL_ACTIVE_UNIFORMS: *out = p->x.num_uniforms + p->x.num_textures; break;
    case GL_ACTIVE_UNIFORM_MAX_LENGTH: case GL_ACTIVE_ATTRIBUTE_MAX_LENGTH: *out = 96; break;
    case GL_ACTIVE_UNIFORM_BLOCKS: *out = p->x.num_ubos; break;
    case GL_COMPUTE_WORK_GROUP_SIZE: memcpy(out, p->x.local_size, sizeof p->x.local_size); break;
    }
}

void glGetProgramInfoLog(GLuint prog, GLsizei max, GLsizei *len, GLchar *log)
{
    mgl_program *p = program_obj(prog);
    const char *s = p && p->info_log ? p->info_log : "";
    GLsizei n = (GLsizei)strlen(s);
    if (n > max - 1)
        n = max - 1;
    if (n < 0)
        n = 0;
    if (max > 0) {
        memcpy(log, s, (size_t)n);
        log[n] = 0;
    }
    if (len)
        *len = n;
}

void glUseProgram(GLuint prog)
{
    GLuint old = mgl->current_program;
    mgl->current_program = prog;
    mgl_program *op = program_obj(old);
    if (op && op->delete_pending && old != prog)
        glDeleteProgram(old);
}

/* ---- uniform locations: (index << 8) | array element; textures follow the plain uniforms ---- */

static int parse_name(const char *name, char *base, int *element)
{
    const char *br = strchr(name, '[');
    *element = 0;
    if (!br) {
        snprintf(base, 96, "%s", name);
        return 1;
    }
    size_t n = (size_t)(br - name);
    if (n >= 96)
        return 0;
    memcpy(base, name, n);
    base[n] = 0;
    *element = atoi(br + 1);
    return strchr(br, '.') == NULL; /* no struct members */
}

static unsigned name_hash_of(const char *s)
{
    unsigned h = 2166136261u; /* FNV-1a */
    while (*s)
        h = (h ^ (unsigned char)*s++) * 16777619u;
    return h;
}

/* Iris and the packs ask for every uniform's location by name, again on each program reload (Complementary and
   Rethinking Voxels: 22-26k calls a minute); a table instead of a strcmp over all of a program's uniforms. */
static void build_name_hash(mgl_program *p)
{
    int n = p->x.num_uniforms + p->x.num_textures;
    unsigned size = 16;
    while (size < (unsigned)n * 2)
        size <<= 1;
    p->name_hash = calloc(size, sizeof *p->name_hash);
    if (!p->name_hash)
        return;
    p->name_hash_mask = size - 1;
    for (int i = 0; i < n; i++) {
        const char *nm = i < p->x.num_uniforms ? p->x.uniforms[i].name : p->x.textures[i - p->x.num_uniforms].name;
        unsigned h = name_hash_of(nm) & p->name_hash_mask;
        while (p->name_hash[h])
            h = (h + 1) & p->name_hash_mask;
        p->name_hash[h] = i + 1;
    }
}

GLint glGetUniformLocation(GLuint prog, const GLchar *name)
{
    mgl_program *p = program_obj(prog);
    char base[96];
    int el;
    if (!p || !p->linked || !parse_name(name, base, &el))
        return -1;
    if (!p->name_hash)
        build_name_hash(p);
    if (!p->name_hash)
        return -1;
    /* the first entry with this name wins, as in the uniforms-then-textures order of the old linear search */
    for (unsigned h = name_hash_of(base) & p->name_hash_mask; p->name_hash[h]; h = (h + 1) & p->name_hash_mask) {
        int i = p->name_hash[h] - 1;
        if (i < p->x.num_uniforms) {
            if (!strcmp(p->x.uniforms[i].name, base) && el < p->x.uniforms[i].array_size)
                return (i << 8) | el;
        } else if (!strcmp(p->x.textures[i - p->x.num_uniforms].name, base) && el == 0) {
            return i << 8;
        }
    }
    return -1;
}

GLint glGetAttribLocation(GLuint prog, const GLchar *name)
{
    mgl_program *p = program_obj(prog);
    if (!p || !p->linked)
        return -1;
    for (int a = 0; a < p->x.num_attribs; a++)
        if (!strcmp(p->x.attribs[a].name, name))
            return a < 64 ? p->attrib_gl_index[a] : -1;
    return -1;
}

static GLenum gl_type_of(const mgl_uniform *u)
{
    static const GLenum fv[] = {0, GL_FLOAT, GL_FLOAT_VEC2, GL_FLOAT_VEC3, GL_FLOAT_VEC4};
    static const GLenum iv[] = {0, GL_INT, GL_INT_VEC2, GL_INT_VEC3, GL_INT_VEC4};
    static const GLenum uv[] = {0, GL_UNSIGNED_INT, GL_UNSIGNED_INT_VEC2, GL_UNSIGNED_INT_VEC3, GL_UNSIGNED_INT_VEC4};
    if (u->columns == 4) return GL_FLOAT_MAT4;
    if (u->columns == 3) return GL_FLOAT_MAT3;
    if (u->columns == 2) return GL_FLOAT_MAT2;
    int v = u->vecsize < 1 ? 1 : u->vecsize > 4 ? 4 : u->vecsize;
    return u->kind == MGL_U_INT ? iv[v] : u->kind == MGL_U_UINT ? uv[v] : u->kind == MGL_U_BOOL ? GL_BOOL : fv[v];
}

void glGetActiveUniform(GLuint prog, GLuint index, GLsizei max, GLsizei *len, GLint *size, GLenum *type, GLchar *name)
{
    mgl_program *p = program_obj(prog);
    const char *n = "";
    *size = 1;
    *type = GL_FLOAT;
    if (p && index < (GLuint)p->x.num_uniforms) {
        n = p->x.uniforms[index].name;
        *size = p->x.uniforms[index].array_size;
        *type = gl_type_of(&p->x.uniforms[index]);
    } else if (p && index < (GLuint)(p->x.num_uniforms + p->x.num_textures)) {
        mgl_texture_slot *t = &p->x.textures[index - (GLuint)p->x.num_uniforms];
        n = t->name;
        *type = t->is_image ? (t->dim == 3 ? GL_IMAGE_3D : GL_IMAGE_2D)
              : t->is_shadow ? GL_SAMPLER_2D_SHADOW : t->dim == 3 ? GL_SAMPLER_3D : t->dim == 12 ? GL_SAMPLER_2D_ARRAY
              : t->dim == 6 ? GL_SAMPLER_CUBE : GL_SAMPLER_2D;
    }
    GLsizei l = (GLsizei)strlen(n);
    if (l > max - 1)
        l = max - 1;
    if (l < 0)
        l = 0;
    if (max > 0) {
        memcpy(name, n, (size_t)l);
        name[l] = 0;
    }
    if (len)
        *len = l;
}

GLuint glGetUniformBlockIndex(GLuint prog, const GLchar *name)
{
    mgl_program *p = program_obj(prog);
    if (p)
        for (int i = 0; i < p->x.num_ubos; i++)
            if (!strcmp(p->x.ubos[i].name, name))
                return (GLuint)i;
    return GL_INVALID_INDEX;
}

void glUniformBlockBinding(GLuint prog, GLuint index, GLuint binding)
{
    mgl_program *p = program_obj(prog);
    if (p && index < 12 && (int)index < p->x.num_ubos)
        p->ubo_binding[index] = (int)binding;
}

GLuint glGetProgramResourceIndex(GLuint prog, GLenum iface, const GLchar *name)
{
    mgl_program *p = program_obj(prog);
    if (!p)
        return GL_INVALID_INDEX;
    if (iface == GL_UNIFORM_BLOCK)
        return glGetUniformBlockIndex(prog, name);
    if (iface == GL_SHADER_STORAGE_BLOCK) {
        for (int i = 0; i < p->x.num_ssbos; i++)
            if (!strcmp(p->x.ssbos[i].name, name))
                return (GLuint)i;
        return GL_INVALID_INDEX;
    }
    mgl_log("glGetProgramResourceIndex: interface 0x%04X not supported", iface);
    return GL_INVALID_INDEX;
}

void glShaderStorageBlockBinding(GLuint prog, GLuint index, GLuint binding)
{
    mgl_program *p = program_obj(prog);
    if (p && index < 8 && (int)index < p->x.num_ssbos)
        p->ssbo_binding[index] = (int)binding;
}

/* ---- writing uniform values ---- */

mgl_camera mgl_cam;

/* Keep Iris's camera uniforms for the backend (see mgl_camera); names only checked for float mat4 / vec3 writes */
static void note_camera(const char *name, int n, int cols, const void *data)
{
    static const char *mats[] = {"gbufferModelView", "gbufferProjection", "gbufferPreviousModelView", "gbufferPreviousProjection"};
    static const char *vecs[] = {"cameraPosition", "previousCameraPosition"};
    if (cols == 4 && n == 4) {
        for (int i = 0; i < 4; i++)
            if (!strcmp(name, mats[i])) {
                memcpy(mgl_cam.mat[i], data, sizeof mgl_cam.mat[i]);
                mgl_cam.seen |= 1u << i;
            }
    } else if (cols <= 1 && n == 3) {
        for (int i = 0; i < 2; i++)
            if (!strcmp(name, vecs[i])) {
                memcpy(mgl_cam.pos[i], data, sizeof mgl_cam.pos[i]);
                mgl_cam.seen |= 1u << (4 + i);
            }
    }
}

/* Write `count` elements of n components each (floats or 32-bit ints) for location loc of program p. */
static void write_uniform(mgl_program *p, GLint loc, int n, int cols, GLsizei count, const void *data, int is_int)
{
    if (!p || loc < 0)
        return;
    int idx = loc >> 8, el = loc & 0xff;
    if (idx >= p->x.num_uniforms) {
        /* sampler / image: the value is a texture or image unit */
        int t = idx - p->x.num_uniforms;
        if (t < p->x.num_textures && is_int) {
            if (p->x.textures[t].is_image)
                p->image_unit_of[t] = ((const GLint *)data)[0];
            else
                p->unit_of[t] = ((const GLint *)data)[0];
        }
        return;
    }
    mgl_uniform *u = &p->x.uniforms[idx];
    if (!is_int && count == 1 && el == 0 && (u->name[0] == 'g' || u->name[0] == 'c' || u->name[0] == 'p'))
        note_camera(u->name, n, cols, data);
    const char *src = data;
    for (GLsizei e = 0; e < count && el + e < u->array_size; e++) {
        for (int s = 0; s < 3; s++) {
            if (u->offset[s] < 0 || !p->ublock[s])
                continue;
            unsigned char *dst = p->ublock[s] + u->offset[s] + (size_t)(el + e) * (size_t)(u->array_stride);
            if (cols <= 1) {
                if (u->kind == MGL_U_FLOAT && is_int) {
                    /* glUniform1i on a float uniform: convert (lenient, like many drivers) */
                    for (int c = 0; c < n; c++) {
                        float f = (float)((const GLint *)src)[c];
                        memcpy(dst + 4 * c, &f, 4);
                    }
                } else if (u->kind != MGL_U_FLOAT && !is_int) {
                    for (int c = 0; c < n; c++) {
                        GLint iv = (GLint)((const float *)src)[c];
                        memcpy(dst + 4 * c, &iv, 4);
                    }
                } else
                    memcpy(dst, src, 4 * (size_t)n);
            } else {
                int stride = u->matrix_stride ? u->matrix_stride : 16;
                for (int c = 0; c < cols; c++)
                    memcpy(dst + c * stride, src + 4 * (size_t)(c * n), 4 * (size_t)n);
            }
        }
        src += 4 * (size_t)(n * (cols ? cols : 1));
    }
}

static mgl_program *cur(void) { return program_obj(mgl->current_program); }

void glUniform1f(GLint l, GLfloat a) { write_uniform(cur(), l, 1, 1, 1, &a, 0); }
void glUniform2f(GLint l, GLfloat a, GLfloat b) { GLfloat v[] = {a, b}; write_uniform(cur(), l, 2, 1, 1, v, 0); }
void glUniform3f(GLint l, GLfloat a, GLfloat b, GLfloat c) { GLfloat v[] = {a, b, c}; write_uniform(cur(), l, 3, 1, 1, v, 0); }
void glUniform4f(GLint l, GLfloat a, GLfloat b, GLfloat c, GLfloat d) { GLfloat v[] = {a, b, c, d}; write_uniform(cur(), l, 4, 1, 1, v, 0); }
void glUniform1i(GLint l, GLint a) { write_uniform(cur(), l, 1, 1, 1, &a, 1); }
void glUniform2i(GLint l, GLint a, GLint b) { GLint v[] = {a, b}; write_uniform(cur(), l, 2, 1, 1, v, 1); }
void glUniform3i(GLint l, GLint a, GLint b, GLint c) { GLint v[] = {a, b, c}; write_uniform(cur(), l, 3, 1, 1, v, 1); }
void glUniform4i(GLint l, GLint a, GLint b, GLint c, GLint d) { GLint v[] = {a, b, c, d}; write_uniform(cur(), l, 4, 1, 1, v, 1); }
void glUniform1ui(GLint l, GLuint a) { write_uniform(cur(), l, 1, 1, 1, &a, 1); }
void glUniform2ui(GLint l, GLuint a, GLuint b) { GLuint v[] = {a, b}; write_uniform(cur(), l, 2, 1, 1, v, 1); }
void glUniform3ui(GLint l, GLuint a, GLuint b, GLuint c) { GLuint v[] = {a, b, c}; write_uniform(cur(), l, 3, 1, 1, v, 1); }
void glUniform4ui(GLint l, GLuint a, GLuint b, GLuint c, GLuint d) { GLuint v[] = {a, b, c, d}; write_uniform(cur(), l, 4, 1, 1, v, 1); }
void glUniform1fv(GLint l, GLsizei n, const GLfloat *v) { write_uniform(cur(), l, 1, 1, n, v, 0); }
void glUniform2fv(GLint l, GLsizei n, const GLfloat *v) { write_uniform(cur(), l, 2, 1, n, v, 0); }
void glUniform3fv(GLint l, GLsizei n, const GLfloat *v) { write_uniform(cur(), l, 3, 1, n, v, 0); }
void glUniform4fv(GLint l, GLsizei n, const GLfloat *v) { write_uniform(cur(), l, 4, 1, n, v, 0); }
void glUniform1iv(GLint l, GLsizei n, const GLint *v) { write_uniform(cur(), l, 1, 1, n, v, 1); }
void glUniform2iv(GLint l, GLsizei n, const GLint *v) { write_uniform(cur(), l, 2, 1, n, v, 1); }
void glUniform3iv(GLint l, GLsizei n, const GLint *v) { write_uniform(cur(), l, 3, 1, n, v, 1); }
void glUniform4iv(GLint l, GLsizei n, const GLint *v) { write_uniform(cur(), l, 4, 1, n, v, 1); }
void glUniform1uiv(GLint l, GLsizei n, const GLuint *v) { write_uniform(cur(), l, 1, 1, n, v, 1); }
void glUniform2uiv(GLint l, GLsizei n, const GLuint *v) { write_uniform(cur(), l, 2, 1, n, v, 1); }
void glUniform3uiv(GLint l, GLsizei n, const GLuint *v) { write_uniform(cur(), l, 3, 1, n, v, 1); }
void glUniform4uiv(GLint l, GLsizei n, const GLuint *v) { write_uniform(cur(), l, 4, 1, n, v, 1); }

static void matrix(GLint l, int n, GLsizei count, GLboolean transpose, const GLfloat *v)
{
    if (!transpose) {
        write_uniform(cur(), l, n, n, count, v, 0);
        return;
    }
    GLfloat *t = malloc(sizeof(GLfloat) * (size_t)(n * n * count));
    for (GLsizei m = 0; m < count; m++)
        for (int r = 0; r < n; r++)
            for (int c = 0; c < n; c++)
                t[m * n * n + c * n + r] = v[m * n * n + r * n + c];
    write_uniform(cur(), l, n, n, count, t, 0);
    free(t);
}

void glUniformMatrix2fv(GLint l, GLsizei n, GLboolean t, const GLfloat *v) { matrix(l, 2, n, t, v); }
void glUniformMatrix3fv(GLint l, GLsizei n, GLboolean t, const GLfloat *v) { matrix(l, 3, n, t, v); }
void glUniformMatrix4fv(GLint l, GLsizei n, GLboolean t, const GLfloat *v) { matrix(l, 4, n, t, v); }

/* DSA-style: temporarily treat `prog` as current */
#define WITH_PROGRAM(prog, call) do { GLuint _s = mgl->current_program; mgl->current_program = (prog); call; mgl->current_program = _s; } while (0)
void glProgramUniform1i(GLuint p, GLint l, GLint a) { WITH_PROGRAM(p, glUniform1i(l, a)); }
void glProgramUniform1f(GLuint p, GLint l, GLfloat a) { WITH_PROGRAM(p, glUniform1f(l, a)); }
void glProgramUniform2f(GLuint p, GLint l, GLfloat a, GLfloat b) { WITH_PROGRAM(p, glUniform2f(l, a, b)); }
void glProgramUniform3f(GLuint p, GLint l, GLfloat a, GLfloat b, GLfloat c) { WITH_PROGRAM(p, glUniform3f(l, a, b, c)); }
void glProgramUniform4f(GLuint p, GLint l, GLfloat a, GLfloat b, GLfloat c, GLfloat d) { WITH_PROGRAM(p, glUniform4f(l, a, b, c, d)); }
void glProgramUniformMatrix4fv(GLuint p, GLint l, GLsizei n, GLboolean t, const GLfloat *v) { WITH_PROGRAM(p, glUniformMatrix4fv(l, n, t, v)); }

mgl_program *mgl_current_program(void) { return cur(); }
