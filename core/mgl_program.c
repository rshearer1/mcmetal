#include <time.h>
/* Shaders, programs, uniforms. Shaders are kept as source; translation to Metal happens at glLinkProgram,
   when all stages are known (inputs/outputs are matched across stages by name). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "mgl_state.h"
#include "mgl_cache.h"
#include <pthread.h>
#include <stdatomic.h>
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
        /* and the intersector versions the Metal backend compiles instead (mgl_rtmsl.c), for the same check */
        for (int pd = 0; pd < 2 && s != MGL_VERTEX; pd++) {
            char *native = mgl_rt_native_msl(j->msl[s], MGL_BUF_RT_FUNCS, pd);
            if (!native)
                break;
            snprintf(path, sizeof path, "%s/%s-%u.%s-native%s.metal", dir, j->key[0] ? j->key : "nokey", n, ext[s],
                     pd ? "-primdata" : "");
            snprintf(tmp, sizeof tmp, "%s.part", path);
            f = fopen(tmp, "w");
            if (f) {
                int ok = fputs(native, f) >= 0;
                if (fclose(f) == 0 && ok)
                    rename(tmp, path);
            }
            free(native);
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
        /* exit() runs atexit handlers and C++ static destructors newest first. SPIRV-Cross builds function-local
           statics (its keyword sets) during the first compiles, after async_link registered the drain, so they
           were destroyed before the drain waited for the workers still using them (gl_smoke crashed at exit in
           replace_illegal_names). Registering the drain again after the 1st, 2nd, 4th, 8th... job puts it after
           them; draining twice is harmless. */
        static _Atomic unsigned long jobs_finished;
        unsigned long nf = atomic_fetch_add(&jobs_finished, 1) + 1;
        if (!(nf & (nf - 1)))
            atexit(mgl_program_drain);
        pthread_mutex_lock(&job_lock);
        jobs_running--;
        j->done = 1;
        pthread_cond_broadcast(&job_done);
    }
    return NULL;
}

/* at exit: let queued and running compiles finish. exit() otherwise tears down glslang's and Metal's globals
   under a worker that is still using them (gl_smoke crashed with exit code 139 after its last check; a game
   quit while a shader pack compiles can too). The binary archive's exit save calls it too, so pipelines these
   jobs add are saved. */
void mgl_program_drain(void)
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
        /* without a way to drain them at exit, link on the caller's thread */
        int want = workers > 0 && atexit(mgl_program_drain) == 0 ? workers : 0;
        workers = 0;
        for (int i = 0; i < want; i++) {
            pthread_t t;
            pthread_attr_t a;
            pthread_attr_init(&a);
            pthread_attr_setstacksize(&a, 16u << 20); /* glslang/SPIRV-Cross recurse deeply on big shaders */
            if (pthread_create(&t, &a, worker, NULL) == 0) {
                pthread_detach(t);
                workers++; /* only threads that exist take jobs */
            }
            pthread_attr_destroy(&a);
        }
        if (workers)
            mgl_log("compiling programs on %d background threads", workers);
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
       float mcm_trace_coarse(vec3 origin, vec3 dir, float tmax);  // as mcm_trace, and
       float mcm_trace_hit_coarse(...);                           // as mcm_trace_hit, but every triangle counts as
                                              // solid (no alpha test: leaves are whole squares); MCMETAL_RT_COARSE
       int mcm_lights_near(vec3 p, int slot, out vec3 pos, out int blockId); // the slot-th nearest light block within
                                              // 16 blocks of p (ids from "#define MCMETAL_LIGHT_IDS lo hi", default
                                              // 10100 10299): index or -1; pos = block centre. MCMETAL_LIGHTS is defined.
       float mcm_hit_emission();                      // LabPBR emission (specular alpha, 0..1) at the last
                                              // mcm_trace_hit / _coarse hit; 0 for entities. MCMETAL_RT_PBR is defined.
       float mcm_hit_roughness();                     // LabPBR roughness (1 - smoothness, specular red; 0..1) at
                                              // the last hit; 1 for entities and without a resource pack's maps
       float mcm_hit_f0();                            // LabPBR F0 / metal id (specular green, 0..1; >= 230/255 =
                                              // metal) at the last hit; 0.04 for entities
       vec3 mcm_hit_mapped_normal(vec3 normal);       // the last hit's face normal (as mcm_trace_hit gave it) bent
                                              // by the LabPBR normal map; the face itself without one. The tangent
                                              // frame is Minecraft's for full-block faces (u east/west, v down or
                                              // south): right for most blocks, rotated on a few. MCMETAL_RT_HIT_PBR.
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
                               "uniform sampler2D mcm_specular; // the terrain's LabPBR specular atlas (Iris's specular)\n"
                               "uniform sampler2D mcm_normals; // the terrain's LabPBR normal atlas (Iris's normals)\n"
                               "#define MCMETAL_RT_HIT_PBR 1 // mcm_hit_roughness, mcm_hit_f0, mcm_hit_mapped_normal\n"
                               "#define MCMETAL_LIGHTS 1\n"
                               "#define MCMETAL_RT_COARSE 1 // mcm_trace_coarse, mcm_trace_hit_coarse\n"
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
        /* Every trace goes through mcm_rq, so a shader holds one ray query (Apple: create as few as possible and
           reuse them). kind 0: any hit, 1: closest hit, 2 and 3: the same with every triangle solid (coarse),
           4: any hit through solid, cutout and translucent terrain, translucent faces filtering transmit and never
           ending the walk. On Metal, mgl_rt_native_msl swaps this body for Metal's intersector, which runs the
           same tests in mcm_any_hit (an intersection function) instead of in this loop. */
        "float mcm_rq(vec3 o, vec3 d, float tmax, uint kind, out uint inst, out uint prim, out vec2 w,\n"
        "             inout vec3 transmit) {\n"
        "  rayQueryEXT mcm_q;\n"
        "  uint flags = (kind == 1u || kind == 3u ? gl_RayFlagsNoneEXT : gl_RayFlagsTerminateOnFirstHitEXT)\n"
        "             | (kind == 2u || kind == 3u ? gl_RayFlagsOpaqueEXT : gl_RayFlagsNoneEXT);\n"
        "  rayQueryInitializeEXT(mcm_q, mcm_scene, flags, kind == 4u ? 0x03u : 0x01u, o, 0.001, d, tmax);\n"
        "  while (rayQueryProceedEXT(mcm_q)) {\n"
        "    McmTris t = mcm_tris[rayQueryGetIntersectionInstanceIdEXT(mcm_q, false)];\n"
        "    uint b = uint(rayQueryGetIntersectionPrimitiveIndexEXT(mcm_q, false)) * 12u;\n"
        "    vec2 cw = rayQueryGetIntersectionBarycentricsEXT(mcm_q, false);\n"
        "    if ((t.w[b + 3u] & 0x100u) != 0u) {\n"
        "      vec4 tex = textureLod(mcm_atlas, mcm_uv(t, b, cw), 0.0);\n"
        "      transmit *= mix(vec3(1.0), tex.rgb * mcm_colour(t, b, cw).rgb, tex.a);\n"
        "    } else if (mcm_opaque_at(t, b, cw))\n"
        "      rayQueryConfirmIntersectionEXT(mcm_q);\n"
        "  }\n"
        "  inst = 0u; prim = 0u; w = vec2(0.0);\n"
        "  if (rayQueryGetIntersectionTypeEXT(mcm_q, true) == gl_RayQueryCommittedIntersectionNoneEXT) return -1.0;\n"
        "  inst = uint(rayQueryGetIntersectionInstanceIdEXT(mcm_q, true));\n"
        "  prim = uint(rayQueryGetIntersectionPrimitiveIndexEXT(mcm_q, true));\n"
        "  w = rayQueryGetIntersectionBarycentricsEXT(mcm_q, true);\n"
        "  return rayQueryGetIntersectionTEXT(mcm_q, true);\n"
        "}\n"
        "float mcm_trace(vec3 origin, vec3 dir, float tmax) {\n"
        "  uint i, p; vec2 w; vec3 tr = vec3(1.0);\n"
        "  return mcm_rq(origin, dir, tmax, 0u, i, p, w, tr);\n"
        "}\n"
        "float mcm_trace_cut(vec3 origin, vec3 dir, float tmax, out uint cut) {\n"
        "  uint i, p; vec2 w; vec3 tr = vec3(1.0);\n"
        "  float h = mcm_rq(origin, dir, tmax, 0u, i, p, w, tr);\n"
        "  cut = h < 0.0 ? 0u : mcm_tris[i].w[p * 12u + 3u] & 0xFFu;\n"
        "  return h;\n"
        "}\n"
        /* what a hit is: face normal (towards the ray), atlas texel x vertex colour, light, Iris block id; and
           where in the atlas, for mcm_hit_emission */
        "vec2 mcm_hit_uv_; bool mcm_hit_tex_;\n"
        "void mcm_hit_attrs(uint inst, uint prim, vec2 w, vec3 dir, out vec3 normal, out vec4 albedo, out vec2 lightmap,\n"
        "                   out int blockId) {\n"
        "  McmTris t = mcm_tris[inst];\n"
        "  uint b = prim * 12u;\n"
        "  vec2 on = unpackSnorm2x16(t.w[b + 7u]);\n"
        "  vec3 n = vec3(on, 1.0 - abs(on.x) - abs(on.y));\n"
        "  if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);\n"
        "  normal = normalize(n);\n"
        "  if (dot(normal, dir) > 0.0) normal = -normal; /* the face the ray hit */\n"
        "  mcm_hit_tex_ = (t.w[b + 3u] & 0x200u) == 0u;\n"
        "  mcm_hit_uv_ = mcm_uv(t, b, w);\n"
        "  albedo = (mcm_hit_tex_ ? textureLod(mcm_atlas, mcm_hit_uv_, 0.0) : vec4(1.0))\n"
        "         * vec4(mcm_colour(t, b, w).rgb, 1.0);\n"
        "  uvec3 l = uvec3(t.w[b + 8u], t.w[b + 9u], t.w[b + 10u]);\n"
        "  vec3 wv = vec3(1.0 - w.x - w.y, w.x, w.y);\n"
        "  lightmap = vec2(dot(vec3(l & 0xFFu), wv), dot(vec3((l >> 8u) & 0xFFu), wv)) / 256.0;\n"
        "  blockId = int(t.w[b + 11u]) - 1;\n"
        "}\n"
        "float mcm_trace_hit(vec3 origin, vec3 dir, float tmax, out vec3 normal, out vec4 albedo, out vec2 lightmap,\n"
        "                    out int blockId) {\n"
        "  uint i, p; vec2 w; vec3 tr = vec3(1.0);\n"
        "  float h = mcm_rq(origin, dir, tmax, 1u, i, p, w, tr);\n"
        "  normal = vec3(0.0); albedo = vec4(0.0); lightmap = vec2(0.0); blockId = -1;\n"
        "  if (h < 0.0) return -1.0;\n"
        "  mcm_hit_attrs(i, p, w, dir, normal, albedo, lightmap, blockId);\n"
        "  return h;\n"
        "}\n"
        /* MCMETAL_RT_PBR: the LabPBR emission (0..1, specular alpha; 255 = none) of the last mcm_trace_hit's hit */
        "float mcm_hit_emission() {\n"
        "  if (!mcm_hit_tex_) return 0.0;\n"
        "  float e = textureLod(mcm_specular, mcm_hit_uv_, 0.0).a;\n"
        "  return e > 254.5 / 255.0 ? 0.0 : e;\n"
        "}\n"
        /* MCMETAL_RT_HIT_PBR: the rest of the last hit's LabPBR material, for shiny bounces in path tracing.
           Without a resource pack's maps Iris binds plain defaults (specular 0 = rough, normals flat). */
        "float mcm_hit_roughness() {\n"
        "  return mcm_hit_tex_ ? 1.0 - textureLod(mcm_specular, mcm_hit_uv_, 0.0).r : 1.0;\n"
        "}\n"
        "float mcm_hit_f0() {\n"
        "  return mcm_hit_tex_ ? textureLod(mcm_specular, mcm_hit_uv_, 0.0).g : 0.04;\n"
        "}\n"
        "vec3 mcm_hit_mapped_normal(vec3 n) {\n"
        "  if (!mcm_hit_tex_) return n;\n"
        "  vec2 m = textureLod(mcm_normals, mcm_hit_uv_, 0.0).rg * 2.0 - 1.0;\n"
        "  if (dot(m, m) < 1e-4) return n;\n" /* flat, or no map */
        "  vec3 ts = vec3(m, sqrt(max(1.0 - dot(m, m), 0.0)));\n"
        /* Minecraft's full-block faces: up/down u = +x, v = +z / -z; north/south u = -x / +x, v = -y; west/east
           u = +z / -z, v = -y */
        "  vec3 a = abs(n);\n"
        "  vec3 t, b;\n"
        "  if (a.y >= a.x && a.y >= a.z) { t = vec3(1.0, 0.0, 0.0); b = vec3(0.0, 0.0, n.y > 0.0 ? 1.0 : -1.0); }\n"
        "  else if (a.z >= a.x) { t = vec3(n.z > 0.0 ? 1.0 : -1.0, 0.0, 0.0); b = vec3(0.0, -1.0, 0.0); }\n"
        "  else { t = vec3(0.0, 0.0, n.x > 0.0 ? -1.0 : 1.0); b = vec3(0.0, -1.0, 0.0); }\n"
        "  return normalize(t * ts.x + b * ts.y + n * ts.z);\n"
        "}\n"
        /* coarse rays (MCMETAL_RT_COARSE): every triangle counts as solid, so the ray hardware never stops to run
           the alpha test of leaves, grass and flowers. For blurry light (bounce light, AO), where a leaf's holes
           don't show. A hit on a see-through texel takes the vertex colour (the biome tint) at half brightness. */
        "float mcm_trace_coarse(vec3 origin, vec3 dir, float tmax) {\n"
        "  uint i, p; vec2 w; vec3 tr = vec3(1.0);\n"
        "  return mcm_rq(origin, dir, tmax, 2u, i, p, w, tr);\n"
        "}\n"
        "float mcm_trace_hit_coarse(vec3 origin, vec3 dir, float tmax, out vec3 normal, out vec4 albedo,\n"
        "                           out vec2 lightmap, out int blockId) {\n"
        "  uint inst, prim; vec2 w; vec3 tr = vec3(1.0);\n"
        "  float h = mcm_rq(origin, dir, tmax, 3u, inst, prim, w, tr);\n"
        "  normal = vec3(0.0); albedo = vec4(0.0); lightmap = vec2(0.0); blockId = -1;\n"
        "  if (h < 0.0) return -1.0;\n"
        "  mcm_hit_attrs(inst, prim, w, dir, normal, albedo, lightmap, blockId);\n"
        "  McmTris t = mcm_tris[inst];\n"
        "  if (albedo.a < 0.5) albedo = vec4(mcm_colour(t, prim * 12u, w).rgb * 0.5, 1.0);\n"
        "  return h;\n"
        "}\n"
        /* one walk through solid, cutout and translucent terrain together (it was two: a solid test, then the
           translucent faces): translucent candidates filter the light and are never committed, a solid or
           passing cutout hit ends the walk (the colour gathered on the way no longer matters then) */
        "float mcm_trace_tinted(vec3 origin, vec3 dir, float tmax, out vec3 transmit) {\n"
        "  uint i, p; vec2 w;\n"
        "  transmit = vec3(1.0);\n"
        "  float h = mcm_rq(origin, dir, tmax, 4u, i, p, w, transmit);\n"
        "  if (h >= 0.0) transmit = vec3(0.0);\n"
        "  return h;\n"
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
    /* MCMETAL_RT_RADIUS r: rays never go further than r blocks from the camera, so the scene can drop the rest
       (the last program to say wins; packs that don't say get every section) */
    const char *rr = strstr(s->source, "#define MCMETAL_RT_RADIUS");
    float radius;
    if (rr && sscanf(rr + 25, "%f", &radius) == 1 && radius != mgl_rt_radius) {
        mgl_rt_radius = radius;
        mgl_log("ray tracing: scene keeps sections within %.0f blocks of the camera", radius);
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
   the Photonics mod; =2 shows the shadow factor instead of the light). Photon's light comes from a flood-filled light volume that bends round corners and has no
   sharp shadows. We keep that light (its brightness and colour are Photon's own), and scale it by what the four
   nearest light blocks (Photon's ids 10032-10079, its own colour table) can actually see: one shadow ray each from the
   surface to the light's centre. Where every light is hidden, a quarter stays as bounce light. A light in view
   but another of a different colour hidden shifts the tint towards the one in view. Photon's licence allows this
   kind of derivative; nothing of the pack is changed on disk. */
static void add_photon_rt(mgl_shader *s)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MCMETAL_PHOTON_RT");
        on = e && *e >= '1' && *e <= '4' ? *e - '0' : 0;
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
        "\n#define MCMETAL_LIGHT_IDS 10032 10079\n"
        "#define MCMETAL_RT_RADIUS 72\n" /* the furthest light the list keeps (grid corner 55 + 16 of reach) */
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
        "#ifdef MCM_PHOTON_RT_NOLIGHTS\n" /* cost split: the scene is still built, but nothing is looked up or traced */
        "  if (lpv.x < -1e30) return vec3(mcm_trace(scene_pos, normal, 1.0));\n"
        "  return lpv;\n"
        "#endif\n"
        /* no block light here worth shadowing: skip the rays */
        "#ifndef MCM_PHOTON_RT_DEBUG\n"
        "  if (dot(lpv, vec3(0.2126, 0.7152, 0.0722)) < 0.002) return lpv;\n"
        "#endif\n"
        "  vec3 o = scene_pos + normal * 0.02;\n"
        "  vec3 c[4], dir[4]; float dist[4]; float w[4];\n"
        "  vec3 all_ = vec3(0.0); float total = 0.0; int n = 0;\n"
        "  for (int i = 0; i < 4; i++) {\n"
        "    vec3 lp; int id;\n"
        "    if (mcm_lights_near(scene_pos, i, lp, id) < 0) break;\n"
        "    vec3 d = lp - o;\n"
        "    dist[n] = length(d);\n"
        "    dir[n] = d / max(dist[n], 1e-4);\n"
        "    float fade = clamp(1.0 - dist[n] / 15.0, 0.0, 1.0);\n"
        "    float ndl = dist[n] < 0.9 ? 1.0 : max(dot(normal, dir[n]), 0.0);\n"
        "    c[n] = mcm_photon_light[clamp(id - 10032, 0, 47)] * fade * fade * ndl / (0.25 * dist[n] * dist[n] + 1.0);\n"
        "    w[n] = dot(c[n], vec3(0.2126, 0.7152, 0.0722));\n"
        "    if (w[n] <= 0.0) continue;\n"
        "    all_ += c[n]; total += w[n]; n++;\n"
        "  }\n"
        "#ifdef MCM_PHOTON_RT_DEBUG\n"
        "  if (total <= 1e-4) return vec3(0.0); /* no light in reach: black */\n"
        "#endif\n"
        "  if (total <= 1e-4) return lpv;\n"
        /* shadow rays only for lights that give at least a tenth of the light here; the faint ones count as seen */
        "  vec3 seen = vec3(0.0);\n"
        "  for (int i = 0; i < n; i++) {\n"
        /* stop short of the light block itself (a full block's faces are 0.5 from its centre, corners up to 0.87) */
        "#ifdef MCM_PHOTON_RT_NORAYS\n" /* cost split: lights looked up, no rays */
        "    if (w[i] >= 0.0 || mcm_trace(o, dir[i], 1.0) < 0.0)\n" /* the dead trace keeps the scene bound and built */
        "#else\n"
        "    if (w[i] < 0.1 * total || dist[i] <= 0.9 || mcm_trace(o + dir[i] * 0.01, dir[i], dist[i] - 0.9) < 0.0)\n"
        "#endif\n"
        "      seen += c[i];\n"
        "  }\n"
        "#ifdef MCM_PHOTON_RT_DEBUG\n"
        "  return 8.0 * mix(vec3(0.25), min(seen / max(all_, vec3(1e-4)), vec3(2.0)), 0.75); /* the shadow factor alone */\n"
        "#endif\n"
        "  return lpv * mix(vec3(0.25), min(seen / max(all_, vec3(1e-4)), vec3(2.0)), 0.75);\n"
        "}\n";
    size_t pre = (size_t)(f - s->source);
    const char *nm = "vec3 mcm_photon_lpv(";
    size_t oldnm = strlen("vec3 get_lpv_blocklight(");
    size_t head = (size_t)(end - (f + oldnm)), rest = strlen(end);
    char *n = malloc(pre + strlen(nm) + head + 32 + sizeof wrap + rest);
    char *o = n;
    memcpy(o, s->source, pre); o += pre;
    memcpy(o, nm, strlen(nm)); o += strlen(nm);
    memcpy(o, f + oldnm, head); o += head;
    /* MCMETAL_PHOTON_RT=2: show the shadow factor instead of the light (white = every light in view);
       3: look the lights up but cast no rays; 4: build the scene only (3 and 4 split the cost) */
    static const char *const mode[5] = {"", "", "\n#define MCM_PHOTON_RT_DEBUG", "\n#define MCM_PHOTON_RT_NORAYS",
                                        "\n#define MCM_PHOTON_RT_NOLIGHTS"};
    memcpy(o, mode[on], strlen(mode[on])); o += strlen(mode[on]);
    memcpy(o, wrap, sizeof wrap - 1); o += sizeof wrap - 1;
    memcpy(o, end, rest + 1);
    free(s->source);
    s->source = n;
    static int patched;
    mgl_log("Photon: ray-traced shadows for its coloured block light (MCMETAL_PHOTON_RT), shader %d", ++patched);
}

static void write_uniform(mgl_program *p, GLint loc, int n, int cols, GLsizei count, const void *data, int is_int);

/* MCMETAL_UPSCALE=2 (MetalFX temporal upscaler): every vertex shader's main() becomes mcm_main(), and a new main()
   moves gl_Position by mcm_jitter, a sub-pixel shift that changes every frame (set per draw by mgl_draw.c, zero for
   draws outside the world picture). Comments are skipped, so a "void main" in one doesn't count.
   MCMETAL_TU_JITTER=0 turns it off; frame interpolation (MCMETAL_FRAMEGEN) does too, its pictures must hold still. */
int mgl_tu_jitter_on(void)
{
    static int on = -1;
    if (on < 0) {
        const char *up = getenv("MCMETAL_UPSCALE"), *j = getenv("MCMETAL_TU_JITTER"), *fg = getenv("MCMETAL_FRAMEGEN");
        on = up && atoi(up) == 2 && !(j && atoi(j) == 0) && !(fg && atoi(fg) > 0);
        if (on)
            mgl_log("temporal upscaler: world drawn with sub-pixel jitter");
    }
    return on;
}

static void add_jitter(mgl_shader *s)
{
    if (s->type != GL_VERTEX_SHADER || !mgl_tu_jitter_on() || strstr(s->source, "mcm_jitter"))
        return;
    size_t n = strlen(s->source);
    int renamed = 0;
    for (char *p = s->source; *p;) {
        if (p[0] == '/' && p[1] == '/') {
            p += strcspn(p, "\n");
            continue;
        }
        if (p[0] == '/' && p[1] == '*') {
            char *e = strstr(p + 2, "*/");
            p = e ? e + 2 : p + strlen(p);
            continue;
        }
        if (!strncmp(p, "void", 4) && (p == s->source || !(isalnum((unsigned char)p[-1]) || p[-1] == '_'))) {
            char *q = p + 4;
            if (*q != ' ' && *q != '\t' && *q != '\n' && *q != '\r') {
                p++;
                continue;
            }
            while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r')
                q++;
            char *r = q + 4;
            while (*r == ' ' || *r == '\t')
                r++;
            if (!strncmp(q, "main", 4) && *r == '(') { /* "main" -> "mcm_main": 4 more bytes */
                size_t at = (size_t)(q - s->source);
                char *grown = realloc(s->source, n + 5);
                if (!grown)
                    return;
                s->source = grown;
                memmove(s->source + at + 4, s->source + at, n - at + 1);
                memcpy(s->source + at, "mcm_", 4);
                n += 4;
                renamed++;
                p = s->source + at + 8;
                continue;
            }
        }
        p++;
    }
    if (!renamed)
        return;
    static const char tail[] = "\nuniform vec2 mcm_jitter;\n"
                               "void main() { mcm_main(); gl_Position.xy += mcm_jitter * gl_Position.w; }\n";
    char *grown = realloc(s->source, n + sizeof tail);
    if (!grown)
        return;
    s->source = grown;
    memcpy(s->source + n, tail, sizeof tail);
}

/* Per draw: this frame's jitter for programs that have mcm_jitter (see add_jitter). */
void mgl_program_jitter(mgl_program *p, GLuint name, const mgl_target *t, int world)
{
    if (!p->jitter_loc) {
        GLint l = glGetUniformLocation(name, "mcm_jitter");
        p->jitter_loc = l < 0 ? -1 : l + 1;
    }
    if (p->jitter_loc < 0)
        return;
    float j[2] = {0, 0};
    if (world && !p->x.gs_max_vertices) /* geometry shaders make their own positions */
        mglb_tu_jitter(t, j);
    write_uniform(p, p->jitter_loc - 1, 2, 1, 1, j, 0);
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
    add_jitter(s);
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
    mgl_denoise_free(p->denoise);
    p->denoise = NULL;
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

/* Minecraft's blit_screen fragment shader, whitespace aside: the output is the texture's sample, unchanged. The
   backend skips such a draw when the texture is known to hold only transparent black and the blend keeps the
   target as it is (vanilla blends the empty glowing-outline layer over the screen every frame). */
static int plain_copy_fs(const char *src)
{
    static const char want[] = "#version150uniformsampler2DDiffuseSampler;invec2texCoord;outvec4fragColor;"
                               "voidmain(){fragColor=texture(DiffuseSampler,texCoord);}";
    size_t i = 0;
    for (const char *c = src; c && *c; c++) {
        if (isspace((unsigned char)*c))
            continue;
        if (i >= sizeof want - 1 || *c != want[i++])
            return 0;
    }
    return src && i == sizeof want - 1;
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
    p->copy_fs = plain_copy_fs(src[MGL_FRAGMENT]);
    p->denoise = mgl_denoise_parse(src[MGL_FRAGMENT]);
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
    p->jitter_loc = 0;
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
