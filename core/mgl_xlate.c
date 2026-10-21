/* GLSL -> SPIR-V (glslang) -> MSL (SPIRV-Cross), plus reflection. See mgl_xlate.h for conventions. */
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glslang/Include/glslang_c_interface.h>
#include <glslang/Public/resource_limits_c.h>
#include <spirv_cross/spirv_cross_c.h>
#include "mgl_xlate.h"

static _Thread_local const mgl_frag_bind *frag_binds;
static _Thread_local int num_frag_binds;
static _Thread_local int deferred;

/* what mgl_xlate_emit needs to finish one stage later */
typedef struct pending_stage { spvc_context ctx; spvc_compiler comp; int stage; } pending_stage;

static const glslang_stage_t gl_stage[MGL_NUM_STAGES] = {
    GLSLANG_STAGE_VERTEX, GLSLANG_STAGE_FRAGMENT, GLSLANG_STAGE_COMPUTE};
static const SpvExecutionModel spv_model[MGL_NUM_STAGES] = {
    SpvExecutionModelVertex, SpvExecutionModelFragment, SpvExecutionModelGLCompute};
static const char *const stage_name[MGL_NUM_STAGES] = {"vertex", "fragment", "compute"};

static void xlog(mgl_xlate_result *r, const char *fmt, ...)
{
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    size_t old = r->log ? strlen(r->log) : 0, add = strlen(buf);
    r->log = realloc(r->log, old + add + 2);
    memcpy(r->log + old, buf, add);
    r->log[old + add] = '\n';
    r->log[old + add + 1] = 0;
}

static void copy_name(char *dst, const char *src)
{
    snprintf(dst, 96, "%s", src ? src : "");
    size_t n = strlen(dst); /* names renamed by rename_vulkan_words: report the pack's own name to GL */
    if (n > 4 && !strcmp(dst + n - 4, "_mgl"))
        dst[n - 4] = 0;
}

#define GROW(arr, n) ((arr) = realloc((arr), sizeof(*(arr)) * ((n) + 1)), memset(&(arr)[n], 0, sizeof(*(arr))), &(arr)[(n)++])

static mgl_uniform *find_uniform(mgl_xlate_result *r, const char *raw)
{
    char name[96];
    copy_name(name, raw);
    for (int i = 0; i < r->num_uniforms; i++)
        if (!strcmp(r->uniforms[i].name, name))
            return &r->uniforms[i];
    mgl_uniform *u = GROW(r->uniforms, r->num_uniforms);
    copy_name(u->name, name);
    for (int s = 0; s < MGL_NUM_STAGES; s++)
        u->offset[s] = -1;
    return u;
}

static mgl_texture_slot *find_texture(mgl_xlate_result *r, const char *raw)
{
    char name[96];
    copy_name(name, raw);
    for (int i = 0; i < r->num_textures; i++)
        if (!strcmp(r->textures[i].name, name))
            return &r->textures[i];
    mgl_texture_slot *t = GROW(r->textures, r->num_textures);
    copy_name(t->name, name);
    for (int s = 0; s < MGL_NUM_STAGES; s++)
        t->msl_index[s] = -1;
    return t;
}

static int is_default_block(spvc_compiler comp, const spvc_reflected_resource *res)
{
    const char *tn = spvc_compiler_get_name(comp, res->base_type_id);
    return (res->name && strstr(res->name, "DefaultUniformBlock")) || (tn && strstr(tn, "DefaultUniformBlock"));
}

static enum mgl_uniform_kind kind_of(spvc_basetype bt)
{
    switch (bt) {
    case SPVC_BASETYPE_INT32: return MGL_U_INT;
    case SPVC_BASETYPE_UINT32: return MGL_U_UINT;
    case SPVC_BASETYPE_BOOLEAN: return MGL_U_BOOL;
    default: return MGL_U_FLOAT;
    }
}

static void reflect_default_block(mgl_xlate_result *r, spvc_compiler comp, int stage, const spvc_reflected_resource *res)
{
    spvc_type type = spvc_compiler_get_type_handle(comp, res->base_type_id);
    size_t size = 0;
    spvc_compiler_get_declared_struct_size(comp, type, &size);
    r->default_block_size[stage] = (int)size;
    unsigned n = spvc_type_get_num_member_types(type);
    for (unsigned i = 0; i < n; i++) {
        spvc_type_id mid = spvc_type_get_member_type(type, i);
        spvc_type mt = spvc_compiler_get_type_handle(comp, mid);
        const char *name = spvc_compiler_get_member_name(comp, res->base_type_id, i);
        if (spvc_type_get_basetype(mt) == SPVC_BASETYPE_STRUCT) {
            xlog(r, "%s: struct uniform '%s' not supported yet", stage_name[stage], name);
            continue;
        }
        mgl_uniform *u = find_uniform(r, name);
        unsigned off = 0, astride = 0, mstride = 0;
        spvc_compiler_type_struct_member_offset(comp, type, i, &off);
        u->offset[stage] = (int)off;
        u->kind = kind_of(spvc_type_get_basetype(mt));
        u->vecsize = (int)spvc_type_get_vector_size(mt);
        u->columns = (int)spvc_type_get_columns(mt);
        u->array_size = spvc_type_get_num_array_dimensions(mt) ? (int)spvc_type_get_array_dimension(mt, 0) : 1;
        if (u->array_size > 1 && spvc_compiler_type_struct_member_array_stride(comp, type, i, &astride) == SPVC_SUCCESS)
            u->array_stride = (int)astride;
        if (u->columns > 1 && spvc_compiler_type_struct_member_matrix_stride(comp, type, i, &mstride) == SPVC_SUCCESS)
            u->matrix_stride = (int)mstride;
    }
}

static int image_dim(spvc_type t)
{
    int base;
    switch (spvc_type_get_image_dimension(t)) {
    case SpvDim1D: base = 1; break;
    case SpvDim3D: base = 3; break;
    case SpvDimCube: base = 6; break;
    default: base = 2; break;
    }
    return base + (spvc_type_get_image_arrayed(t) ? 10 : 0);
}

/* Does the combined image-sampler variable `var` ever get sampled (rather than only texelFetch'd / size-queried)?
   Fetch-only textures get a constexpr sampler in MSL, so they don't use one of Metal's 16 sampler slots. Conservative:
   any use we don't recognise counts as sampling. */
static int needs_sampler(const uint32_t *w, size_t n, uint32_t var)
{
    enum { OpName = 5, OpEntryPoint = 15, OpFunctionCall = 57, OpVariable = 59, OpLoad = 61, OpDecorate = 71, OpImage = 100 };
    uint32_t loads[64];
    int nl = 0;
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, wc = w[i] >> 16;
        if (!wc || i + wc > n)
            return 1;
        if (op == OpLoad && wc >= 4 && w[i + 3] == var) {
            if (nl == 64)
                return 1;
            loads[nl++] = w[i + 2];
        }
        i += wc;
    }
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, wc = w[i] >> 16;
        for (uint32_t k = 1; k < wc; k++) {
            uint32_t v = w[i + k];
            if (v == var) {
                if (op == OpName || op == OpDecorate || op == OpEntryPoint || (op == OpVariable && k == 2) ||
                    (op == OpLoad && k == 3))
                    continue;
                return 1;
            }
            for (int l = 0; l < nl; l++)
                if (v == loads[l]) {
                    if ((op == OpLoad && k == 2) || (op == OpImage && k == 3))
                        break;
                    (void)OpFunctionCall;
                    return 1;
                }
        }
        i += wc;
    }
    return 0;
}

/* GL matches vertex outputs to fragment inputs by name; glslang numbers each stage's locations in declaration
   order, so "out float d; out vec4 c;" against "in vec4 c; in float d;" would cross the wires (and hang the GPU on
   Metal: Sodium's terrain and cloud shaders do this). The vertex stage records its outputs here, and the fragment
   stage takes its input locations from them. */
typedef struct varying_map {
    struct { char name[96]; unsigned loc; } v[128];
    int n, have_vertex;
    unsigned next_free;
} varying_map;

/* blocks match by block name, plain variables by variable name */
static void varying_key(spvc_compiler comp, const spvc_reflected_resource *res, char *key)
{
    spvc_type t = spvc_compiler_get_type_handle(comp, res->base_type_id);
    if (spvc_type_get_basetype(t) == SPVC_BASETYPE_STRUCT)
        snprintf(key, 96, "block %s", spvc_compiler_get_name(comp, res->base_type_id));
    else
        copy_name(key, res->name);
}

static void match_varyings(spvc_compiler comp, spvc_resources res, int stage, varying_map *vm)
{
    const spvc_reflected_resource *list;
    size_t count;
    char key[96];
    if (stage == MGL_VERTEX) {
        spvc_resources_get_resource_list_for_type(res, SPVC_RESOURCE_TYPE_STAGE_OUTPUT, &list, &count);
        vm->have_vertex = 1;
        for (size_t i = 0; i < count && vm->n < 128; i++) {
            varying_key(comp, &list[i], key);
            snprintf(vm->v[vm->n].name, 96, "%s", key);
            vm->v[vm->n].loc = spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationLocation);
            if (vm->v[vm->n].loc + 64 > vm->next_free)
                vm->next_free = vm->v[vm->n].loc + 64; /* past anything an array or matrix output can span */
            vm->n++;
        }
    } else if (stage == MGL_FRAGMENT && vm->have_vertex) {
        spvc_resources_get_resource_list_for_type(res, SPVC_RESOURCE_TYPE_STAGE_INPUT, &list, &count);
        for (size_t i = 0; i < count; i++) {
            varying_key(comp, &list[i], key);
            int k = 0;
            while (k < vm->n && strcmp(vm->v[k].name, key))
                k++;
            /* an input the vertex stage never writes gets a location of its own (GL leaves it undefined) */
            unsigned loc = k < vm->n ? vm->v[k].loc : (vm->next_free += 64);
            spvc_compiler_set_decoration(comp, list[i].id, SpvDecorationLocation, loc);
        }
    }
}

/* SPIRV-Cross pads narrow fragment outputs (vec3, float) to float4 but writes only out.x.xyz, leaving alpha 0:
   with blending that made SEUS PTGI's passes transparent. GL's missing components read as (0, 0, 0, 1), so
   every padded output starts as that before the shader's own write. */
static char *msl_dup(const char *msl, int stage)
{
    const char *init = stage == MGL_FRAGMENT ? strstr(msl, "main0_out out = {};\n") : NULL;
    if (!init)
        return strdup(msl);
    char names[16][128];
    int n = 0;
    for (const char *p = strstr(msl, "    out."); p && n < 16; p = strstr(p + 8, "    out.")) {
        const char *q = p + 8, *e = q;
        while (isalnum((unsigned char)*e) || *e == '_')
            e++;
        if (strncmp(e, ".x = ", 5) && strncmp(e, ".xy = ", 6) && strncmp(e, ".xyz = ", 7))
            continue;
        if (e - q >= 128)
            continue;
        int dup = 0;
        for (int k = 0; k < n; k++)
            dup |= strlen(names[k]) == (size_t)(e - q) && !strncmp(names[k], q, (size_t)(e - q));
        if (!dup) {
            memcpy(names[n], q, (size_t)(e - q));
            names[n++][e - q] = 0;
        }
    }
    if (!n)
        return strdup(msl);
    size_t at = (size_t)(init - msl) + strlen("main0_out out = {};\n"), extra = 0;
    for (int k = 0; k < n; k++)
        extra += strlen(names[k]) + 48;
    char *out = malloc(strlen(msl) + extra + 1), *o = out;
    memcpy(o, msl, at);
    o += at;
    for (int k = 0; k < n; k++)
        o += sprintf(o, "    out.%s = float4(0.0, 0.0, 0.0, 1.0);\n", names[k]);
    strcpy(o, msl + at);
    return out;
}


static spvc_bool cross_stage(mgl_xlate_result *r, int stage, const uint32_t *words, size_t nwords, int *next_tex,
                             varying_map *vm)
{
    spvc_context ctx = NULL;
    spvc_parsed_ir ir = NULL;
    spvc_compiler comp = NULL;
    spvc_compiler_options opts = NULL;
    spvc_resources res = NULL;
    const spvc_reflected_resource *list;
    size_t count;
    spvc_bool ok = SPVC_FALSE;

    if (spvc_context_create(&ctx) != SPVC_SUCCESS)
        return SPVC_FALSE;
    if (spvc_context_parse_spirv(ctx, words, nwords, &ir) != SPVC_SUCCESS ||
        spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &comp) != SPVC_SUCCESS) {
        xlog(r, "%s: SPIRV-Cross: %s", stage_name[stage], spvc_context_get_last_error_string(ctx));
        goto done;
    }
    spvc_compiler_create_compiler_options(comp, &opts);
    spvc_compiler_options_set_uint(opts, SPVC_COMPILER_OPTION_MSL_VERSION, SPVC_MAKE_MSL_VERSION(3, 1, 0));
    if (stage == MGL_VERTEX) {
        spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_FLIP_VERTEX_Y, SPVC_TRUE);
        spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_FIXUP_DEPTH_CONVENTION, SPVC_TRUE);
    }
    /* GL lets a shader write a vec3 or float into an RGBA target; Metal needs as many components as the format */
    if (stage == MGL_FRAGMENT)
        spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_MSL_PAD_FRAGMENT_OUTPUT_COMPONENTS, SPVC_TRUE);
    spvc_compiler_install_compiler_options(comp, opts);
    /* Only resources the shader really uses: GLSL code often declares far more samplers than it reads,
       and Metal has 16 sampler slots per stage. */
    spvc_set active = NULL;
    spvc_compiler_get_active_interface_variables(comp, &active);
    spvc_compiler_create_shader_resources_for_active_variables(comp, &res, active);
    match_varyings(comp, res, stage, vm);

    /* Uniform blocks: default block -> buffer 0, others -> MGL_BUF_UBO_BASE + their binding */
    spvc_resources_get_resource_list_for_type(res, SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, &list, &count);
    for (size_t i = 0; i < count; i++) {
        spvc_msl_resource_binding b;
        spvc_msl_resource_binding_init(&b);
        b.stage = spv_model[stage];
        /* GL numbers uniform and storage blocks separately; in SPIR-V they would share set 0, and SPIRV-Cross then
           aliases a uniform block with the storage block of the same binding (Rethinking Voxels: the default
           block read through an SSBO pointer). Uniform blocks get their own set, the default block another. */
        int dflt = is_default_block(comp, &list[i]);
        spvc_compiler_set_decoration(comp, list[i].id, SpvDecorationDescriptorSet, dflt ? 5 : 4);
        b.desc_set = dflt ? 5 : 4;
        b.binding = spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationBinding);
        if (dflt) {
            b.msl_buffer = MGL_BUF_DEFAULT_UNIFORMS;
            reflect_default_block(r, comp, stage, &list[i]);
        } else {
            const char *bn = spvc_compiler_get_name(comp, list[i].base_type_id);
            mgl_ubo *u = NULL;
            for (int k = 0; k < r->num_ubos; k++)
                if (!strcmp(r->ubos[k].name, bn))
                    u = &r->ubos[k];
            if (!u) {
                u = GROW(r->ubos, r->num_ubos);
                copy_name(u->name, bn);
                u->binding = (int)b.binding;
                size_t sz = 0;
                spvc_compiler_get_declared_struct_size(comp, spvc_compiler_get_type_handle(comp, list[i].base_type_id), &sz);
                u->size = (int)sz;
            }
            b.msl_buffer = MGL_BUF_UBO_BASE + (unsigned)(u - r->ubos);
        }
        spvc_compiler_msl_add_resource_binding(comp, &b);
    }

    /* Shader storage blocks -> MGL_BUF_SSBO_BASE + index in r->ssbos */
    spvc_resources_get_resource_list_for_type(res, SPVC_RESOURCE_TYPE_STORAGE_BUFFER, &list, &count);
    for (size_t i = 0; i < count; i++) {
        spvc_msl_resource_binding b;
        spvc_msl_resource_binding_init(&b);
        b.stage = spv_model[stage];
        b.desc_set = spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationDescriptorSet);
        b.binding = spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationBinding);
        const char *bn = spvc_compiler_get_name(comp, list[i].base_type_id);
        if (bn && !strncmp(bn, "mgl_i", 5) && isdigit((unsigned char)bn[5])) { /* geometry emulation's own buffers */
            b.msl_buffer = MGL_BUF_INTERNAL_BASE + (unsigned)atoi(bn + 5);
            spvc_compiler_msl_add_resource_binding(comp, &b);
            continue;
        }
        mgl_ubo *u = NULL;
        for (int k = 0; k < r->num_ssbos; k++)
            if (!strcmp(r->ssbos[k].name, bn))
                u = &r->ssbos[k];
        if (!u) {
            if (r->num_ssbos >= MGL_MAX_SSBOS) {
                xlog(r, "%s: more than %d storage blocks", stage_name[stage], MGL_MAX_SSBOS);
                goto done;
            }
            u = GROW(r->ssbos, r->num_ssbos);
            copy_name(u->name, bn);
            u->binding = (int)b.binding;
            u->size = 0;
        }
        b.msl_buffer = MGL_BUF_SSBO_BASE + (unsigned)(u - r->ssbos);
        spvc_compiler_msl_add_resource_binding(comp, &b);
    }

    spvc_resources_get_resource_list_for_type(res, SPVC_RESOURCE_TYPE_ACCELERATION_STRUCTURE, &list, &count);
    for (size_t i = 0; i < count; i++) {
        spvc_msl_resource_binding b;
        spvc_msl_resource_binding_init(&b);
        b.stage = spv_model[stage];
        b.desc_set = spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationDescriptorSet);
        b.binding = spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationBinding);
        b.msl_buffer = MGL_BUF_SCENE;
        spvc_compiler_msl_add_resource_binding(comp, &b);
        r->uses_scene = 1;
    }

    /* Textures and images: consecutive indices per stage. Sampled textures first, so they get the low indices
       (texture index == sampler index, and Metal has 16 sampler slots); then fetch-only textures, which get a
       constexpr sampler and no slot; then images. */
    for (int pass = 0; pass < 3; pass++) {
        spvc_resources_get_resource_list_for_type(res, pass == 2 ? SPVC_RESOURCE_TYPE_STORAGE_IMAGE : SPVC_RESOURCE_TYPE_SAMPLED_IMAGE, &list, &count);
        for (size_t i = 0; i < count; i++) {
            if (pass < 2 && needs_sampler(words, nwords, list[i].id) != (pass == 0))
                continue;
            spvc_type t = spvc_compiler_get_type_handle(comp, list[i].type_id);
            mgl_texture_slot *slot = find_texture(r, list[i].name);
            slot->is_image = pass == 2;
            slot->is_shadow = spvc_type_get_image_is_depth(t);
            slot->dim = image_dim(t);
            spvc_type st = spvc_compiler_get_type_handle(comp, spvc_type_get_image_sampled_type(t));
            spvc_basetype sb = spvc_type_get_basetype(st);
            slot->sample_kind = sb == SPVC_BASETYPE_INT32 ? 1 : sb == SPVC_BASETYPE_UINT32 ? 2 : 0;
            slot->msl_index[stage] = next_tex[stage]++;
            if (slot->msl_index[stage] >= 16 && pass == 0)
                xlog(r, "%s: sampler '%s' at index %d is past Metal's 16 sampler slots", stage_name[stage], list[i].name, slot->msl_index[stage]);
            spvc_msl_resource_binding b;
            spvc_msl_resource_binding_init(&b);
            b.stage = spv_model[stage];
            b.desc_set = spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationDescriptorSet);
            b.binding = spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationBinding);
            b.msl_texture = b.msl_sampler = (unsigned)slot->msl_index[stage];
            spvc_compiler_msl_add_resource_binding(comp, &b);
            if (pass == 1) {
                spvc_msl_constexpr_sampler cs;
                spvc_msl_constexpr_sampler_init(&cs); /* nearest, clamp: irrelevant for texelFetch */
                spvc_compiler_msl_remap_constexpr_sampler_by_binding(comp, b.desc_set, b.binding, &cs);
            }
        }
    }

    if (stage == MGL_VERTEX) {
        spvc_resources_get_resource_list_for_type(res, SPVC_RESOURCE_TYPE_STAGE_INPUT, &list, &count);
        for (size_t i = 0; i < count; i++) {
            spvc_type t = spvc_compiler_get_type_handle(comp, list[i].type_id);
            mgl_attrib *a = GROW(r->attribs, r->num_attribs);
            copy_name(a->name, list[i].name);
            a->location = (int)spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationLocation);
            a->vecsize = (int)spvc_type_get_vector_size(t);
            spvc_basetype bt = spvc_type_get_basetype(t);
            a->is_int = bt == SPVC_BASETYPE_INT32 ? 1 : bt == SPVC_BASETYPE_UINT32 ? 2 : 0;
        }
    }
    if (stage == MGL_FRAGMENT) {
        spvc_resources_get_resource_list_for_type(res, SPVC_RESOURCE_TYPE_STAGE_OUTPUT, &list, &count);
        for (size_t i = 0; i < count; i++) {
            mgl_frag_out *o = GROW(r->outs, r->num_outs);
            copy_name(o->name, list[i].name);
            for (int k = 0; k < num_frag_binds; k++) /* glBindFragDataLocation wins over the shader's own location */
                if (!strcmp(frag_binds[k].name, o->name))
                    spvc_compiler_set_decoration(comp, list[i].id, SpvDecorationLocation, (unsigned)frag_binds[k].loc);
            o->location = (int)spvc_compiler_get_decoration(comp, list[i].id, SpvDecorationLocation);
        }
    }
    if (stage == MGL_COMPUTE)
        for (int k = 0; k < 3; k++)
            r->local_size[k] = (int)spvc_compiler_get_execution_mode_argument_by_index(comp, SpvExecutionModeLocalSize, (unsigned)k);

    if (deferred) {
        pending_stage *ps = malloc(sizeof *ps);
        *ps = (pending_stage){ctx, comp, stage};
        r->pending[stage] = ps;
        return SPVC_TRUE; /* the context lives on in pending[] */
    }
    const char *msl = NULL;
    if (spvc_compiler_compile(comp, &msl) != SPVC_SUCCESS) {
        xlog(r, "%s: SPIRV-Cross: %s", stage_name[stage], spvc_context_get_last_error_string(ctx));
        goto done;
    }
    r->msl[stage] = msl_dup(msl, stage);
    ok = SPVC_TRUE;
done:
    spvc_context_destroy(ctx);
    return ok;
}


/* GL drivers accept a fragment input with no matching vertex output (it reads undefined values); glslang
   refuses to link. Find "in <type> NAME;" in the fragment source and give the vertex shader a matching,
   never-written output. Returns a malloc'd vertex source, or NULL if the declaration can't be found. */
static char *add_missing_output(const char *vs, const char *fs, const char *name)
{
    size_t nl = strlen(name);
    for (const char *p = strstr(fs, name); p; p = strstr(p + 1, name)) {
        if (p[nl] != ';' && p[nl] != ' ' && p[nl] != '[')
            continue;
        const char *line = p;
        while (line > fs && line[-1] != '\n')
            line--;
        const char *in = strstr(line, "in ");
        if (!in || in > p)
            continue;
        const char *end = strchr(p, ';');
        if (!end)
            return NULL;
        /* qualifiers before "in" (flat, noperspective) are kept; "in" becomes "out" */
        size_t pre = (size_t)(in - line), rest = (size_t)(end + 1 - (in + 3));
        const char *ver = strstr(vs, "#version");
        const char *after = ver ? strchr(ver, '\n') : NULL;
        size_t head = after ? (size_t)(after + 1 - vs) : 0;
        char *out = malloc(strlen(vs) + pre + rest + 16);
        memcpy(out, vs, head);
        size_t o = head;
        memcpy(out + o, line, pre); o += pre;
        memcpy(out + o, "out ", 4); o += 4;
        memcpy(out + o, in + 3, rest); o += rest;
        out[o++] = '\n';
        strcpy(out + o, vs + head);
        return out;
    }
    return NULL;
}

/* GL drivers take layout(binding = N) in pre-4.20 shaders (Complementary's world-space reflection buffers in
   #version 330 composites); glslang only with GL_ARB_shading_language_420pack. Returns a copy with that extension
   enabled right after #version (and #line keeping error line numbers), or NULL when nothing needs it. */
static char *with_420pack(const char *text)
{
    const char *v = strstr(text, "#version");
    int ver = v ? atoi(v + 8) : 0;
    if (!v || ver >= 420 || !strstr(text, "binding"))
        return NULL;
    const char *eol = strchr(v, '\n');
    if (!eol)
        return NULL;
    int line = 1;
    for (const char *c = text; c <= eol; c++)
        line += *c == '\n';
    size_t head = (size_t)(eol + 1 - text), len = strlen(text);
    char *out = malloc(len + 128);
    memcpy(out, text, head);
    int n = snprintf(out + head, 128, "#extension GL_ARB_shading_language_420pack : enable\n#line %d\n", line);
    memcpy(out + head + n, eol + 1, len - head + 1);
    return out;
}

static int xlate_once(const char *src[MGL_NUM_STAGES], mgl_xlate_result *r)
{
    static int initialized;
    glslang_shader_t *sh[MGL_NUM_STAGES] = {0};
    glslang_program_t *prog = NULL;
    char *patched_src[MGL_NUM_STAGES] = {0};
    int next_tex[MGL_NUM_STAGES] = {0};
    static __thread varying_map vm;
    const int msgs = GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT;

    memset(r, 0, sizeof *r);
    memset(&vm, 0, sizeof vm);
    if (!initialized) {
        glslang_initialize_process();
        initialized = 1;
    }
    /* compute links on its own: alongside vertex+fragment it is geometry emulation (mgl_gs.c), not a pipeline stage */
    int split = src[MGL_COMPUTE] && (src[MGL_VERTEX] || src[MGL_FRAGMENT]);
    prog = glslang_program_create();
    glslang_program_t *cprog = split ? glslang_program_create() : NULL;
    for (int s = 0; s < MGL_NUM_STAGES; s++) {
        if (!src[s])
            continue;
        char *patched = with_420pack(src[s]);
        glslang_input_t in = {
            .language = GLSLANG_SOURCE_GLSL,
            .stage = gl_stage[s],
            .client = GLSLANG_CLIENT_VULKAN,
            .client_version = GLSLANG_TARGET_VULKAN_1_0,
            .target_language = GLSLANG_TARGET_SPV,
            .target_language_version = GLSLANG_TARGET_SPV_1_0,
            .code = patched ? patched : src[s],
            .default_version = 110,
            .default_profile = GLSLANG_NO_PROFILE,
            .messages = msgs,
            .resource = glslang_default_resource(),
        };
        sh[s] = glslang_shader_create(&in);
        patched_src[s] = patched; /* glslang keeps the pointer: freed at the end */
        glslang_shader_set_options(sh[s], GLSLANG_SHADER_AUTO_MAP_BINDINGS | GLSLANG_SHADER_AUTO_MAP_LOCATIONS |
                                              GLSLANG_SHADER_VULKAN_RULES_RELAXED);
        if (!glslang_shader_preprocess(sh[s], &in) || !glslang_shader_parse(sh[s], &in)) {
            xlog(r, "%s: %s", stage_name[s], glslang_shader_get_info_log(sh[s]));
            goto done;
        }
        glslang_program_add_shader(split && s == MGL_COMPUTE ? cprog : prog, sh[s]);
    }
    if (!glslang_program_link(prog, msgs) || !glslang_program_map_io(prog)) {
        xlog(r, "link: %s", glslang_program_get_info_log(prog));
        goto done;
    }
    if (cprog && (!glslang_program_link(cprog, msgs) || !glslang_program_map_io(cprog))) {
        xlog(r, "link (compute): %s", glslang_program_get_info_log(cprog));
        goto done;
    }
    for (int s = 0; s < MGL_NUM_STAGES; s++) {
        if (!src[s])
            continue;
        glslang_program_t *pp = split && s == MGL_COMPUTE ? cprog : prog;
        glslang_program_SPIRV_generate(pp, gl_stage[s]);
        if (!cross_stage(r, s, glslang_program_SPIRV_get_ptr(pp), glslang_program_SPIRV_get_size(pp), next_tex, &vm))
            goto done;
    }
    r->ok = 1;
done:
    glslang_program_delete(prog);
    if (cprog)
        glslang_program_delete(cprog);
    for (int s = 0; s < MGL_NUM_STAGES; s++) {
        if (sh[s])
            glslang_shader_delete(sh[s]);
        free(patched_src[s]);
    }
    return r->ok;
}

/* SPIR-V stores loose bool uniforms as uint, but GL (and Iris) must see GL_BOOL. Find "uniform bool a, b;" and
   "uniform bvecN x;" in the GLSL and mark those uniforms. */
static void mark_bools(mgl_xlate_result *r, const char *src)
{
    for (const char *p = src; p && (p = strstr(p, "uniform")) != NULL; p += 7) {
        if (p > src && (isalnum((unsigned char)p[-1]) || p[-1] == '_'))
            continue;
        const char *q = p + 7;
        if (!isspace((unsigned char)*q))
            continue;
        while (isspace((unsigned char)*q))
            q++;
        if (strncmp(q, "bool", 4) && strncmp(q, "bvec", 4))
            continue;
        q += 4;
        if (isdigit((unsigned char)*q))
            q++;
        if (!isspace((unsigned char)*q))
            continue;
        while (*q && *q != ';') {
            while (isspace((unsigned char)*q) || *q == ',')
                q++;
            char name[96];
            size_t n = 0;
            while ((isalnum((unsigned char)*q) || *q == '_') && n + 1 < sizeof name)
                name[n++] = *q++;
            name[n] = 0;
            for (int i = 0; n && i < r->num_uniforms; i++)
                if (!strcmp(r->uniforms[i].name, name))
                    r->uniforms[i].kind = MGL_U_BOOL;
            while (*q && *q != ',' && *q != ';')
                q++;
        }
    }
}

/* We compile desktop GLSL with Vulkan rules, which reserve some words desktop GLSL lets packs use as names
   (Photon has "sampler2D sampler"). Rename those identifiers. The MSL that SPIRV-Cross writes is C++ with
   "using namespace metal", so C++ keywords (BSL's "bool new") and the pack's own functions named like Metal
   library ones (Bliss's bias(), Photon's length_squared()) break there; rename those too. The added _mgl suffix
   is taken off again in reflection (copy_name), so GL names still match. Returns a new string, or NULL if
   nothing changed. */
static char *rename_vulkan_words(const char *src)
{
    static const char *words[] = {"sampler", "samplerShadow", "texture1D", "texture2D", "texture3D", "textureCube",
                                  "texture1DArray", "texture2DArray", "textureCubeArray", "textureBuffer", "texture2DMS",
                                  "texture2DMSArray", "texture2DRect", "subpassInput", "subpassInputMS", NULL};
    /* C++ keywords that GLSL leaves free, Metal address spaces / stages, and metal:: functions packs define */
    static const char *cxx[] = {"new", "delete", "this", "operator", "friend", "virtual", "typename", "explicit",
                                "mutable", "private", "protected", "throw", "try", "catch", "nullptr", "and", "or",
                                "not", "xor", "bitand", "bitor", "compl", "and_eq", "or_eq", "not_eq", "xor_eq",
                                "char", "signed", "wchar_t", "constexpr", "decltype", "alignas", "alignof",
                                "noexcept", "static_assert", "thread_local", "export", "register", "typeid",
                                "dynamic_cast", "static_cast", "const_cast", "reinterpret_cast", "auto",
                                "constant", "device", "thread", "threadgroup", "kernel", "vertex", "fragment",
                                "bias", "level", "gradient2d", "gradient3d", "gradientcube", "min_lod_clamp",
                                "length_squared", "distance_squared", "rotate", "sincos", "lerp", "square", "rsqrt",
                                "rcp", "atan2", "cbrt", "fmin", "fmax", "fmod", "select", "powr", "exp10",
                                "sinpi", "cospi", "tanpi", "rint", "copysign", "fdim", "popcount", "clz", "ctz",
                                "extract_bits", "insert_bits", "reverse_bits", "mulhi", "hadd", "rhadd",
                                "addsat", "subsat", "abs_diff", "max3", "min3", "median3", "fmin3", "fmax3",
                                "saturate", "divide", "recip", "as_type", NULL};
    if (!src)
        return NULL;
    size_t len = strlen(src), cap = len + 64, o = 0;
    char *out = malloc(cap);
    int changed = 0;
    for (const char *p = src; *p;) {
        /* comments are copied as they are: "// FMA for precision" in Sodium's terrain shader once had its
           "precision ... ;" blanked through the next line's statement (v_Material = ...), which broke cutout */
        if (p[0] == '/' && (p[1] == '/' || p[1] == '*')) {
            const char *e = p[1] == '/' ? strchr(p, '\n') : strstr(p + 2, "*/");
            e = !e ? p + strlen(p) : p[1] == '/' ? e : e + 2;
            size_t m = (size_t)(e - p);
            if (o + m + 8 > cap) {
                cap = (cap + m + 8) * 2;
                out = realloc(out, cap);
            }
            memcpy(out + o, p, m);
            o += m;
            p = e;
            continue;
        }
        if (isalpha((unsigned char)*p) || *p == '_') {
            const char *q = p;
            while (isalnum((unsigned char)*q) || *q == '_')
                q++;
            size_t n = (size_t)(q - p);
            /* Precision qualifiers mean nothing on desktop GL, but glslang's Vulkan rules reject packs that
               mix them between declaration and definition (Bliss). Blank them out, same length. */
            if ((n == 5 && !memcmp(p, "highp", 5)) || (n == 7 && !memcmp(p, "mediump", 7)) || (n == 4 && !memcmp(p, "lowp", 4)) ||
                (n == 9 && !memcmp(p, "precision", 9))) {
                const char *e = q;
                if (n == 9) /* whole "precision highp float;" statement */
                    while (*e && *e != ';')
                        e++;
                if (n == 9 && *e == ';')
                    e++;
                size_t m = (size_t)(e - p);
                if (o + m + 8 > cap) {
                    cap = (cap + m + 8) * 2;
                    out = realloc(out, cap);
                }
                for (size_t k = 0; k < m; k++)
                    out[o++] = p[k] == '\n' ? '\n' : ' ';
                changed = 1;
                p = e;
                continue;
            }
            int hit = 0;
            for (int i = 0; words[i] && !hit; i++)
                if (strlen(words[i]) == n && !memcmp(p, words[i], n)) {
                    const char *r = q;
                    while (*r == ' ' || *r == '\t')
                        r++;
                    /* texture2D(...) is the old lookup function, not a name; leave calls alone */
                    hit = i < 2 || *r != '(';
                }
            for (int i = 0; cxx[i] && !hit; i++)
                hit = cxx[i][0] == *p && strlen(cxx[i]) == n && !memcmp(p, cxx[i], n);
            if (o + n + 8 > cap) {
                cap = (cap + n + 8) * 2;
                out = realloc(out, cap);
            }
            memcpy(out + o, p, n);
            o += n;
            if (hit) {
                memcpy(out + o, "_mgl", 4);
                o += 4;
                changed = 1;
            }
            p = q;
            continue;
        }
        if (o + 2 > cap) {
            cap *= 2;
            out = realloc(out, cap);
        }
        out[o++] = *p++;
    }
    out[o] = 0;
    if (!changed) {
        free(out);
        return NULL;
    }
    return out;
}

/* Packs written against Mesa sometimes define their own tanh() etc. (Bliss); glslang rejects redefining a
   built-in. Rename the pack's version to mgl_<name> everywhere, and forward the shapes it didn't define back
   to the built-in. Returns NULL when nothing changed. */
static int is_ident(char c) { return isalnum((unsigned char)c) || c == '_'; }

static char *fix_builtin_overrides(const char *src)
{
    static const char *names[] = {"sinh", "cosh", "tanh", "asinh", "acosh", "atanh", NULL};
    static const char *types[] = {"float", "vec2", "vec3", "vec4"};
    if (!src)
        return NULL;
    char *cur = NULL;
    for (int ni = 0; names[ni]; ni++) {
        const char *text = cur ? cur : src, *nm = names[ni];
        size_t nl = strlen(nm);
        int defined[4] = {0}, any = 0;
        for (int ti = 0; ti < 4; ti++) {
            size_t tl = strlen(types[ti]);
            for (const char *p = text; (p = strstr(p, types[ti])) != NULL; p += tl) {
                if (p > text && is_ident(p[-1]))
                    continue;
                const char *q = p + tl;
                if (!isspace((unsigned char)*q))
                    continue;
                while (isspace((unsigned char)*q))
                    q++;
                if (strncmp(q, nm, nl) || is_ident(q[nl]))
                    continue;
                q += nl;
                while (isspace((unsigned char)*q))
                    q++;
                if (*q == '(')
                    defined[ti] = any = 1;
            }
        }
        if (!any)
            continue;
        /* rename every whole-word use */
        size_t len = strlen(text), cap = len * 2 + 1024, o = 0;
        char *out = malloc(cap);
        const char *v = strstr(text, "#version");
        const char *ins = v ? strchr(v, '\n') : NULL;
        for (const char *p = text; *p;) {
            if (o + 600 > cap) {
                cap *= 2;
                out = realloc(out, cap);
            }
            if (!strncmp(p, nm, nl) && !is_ident(p[nl]) && (p == text || !is_ident(p[-1]))) {
                o += (size_t)sprintf(out + o, "mgl_%s", nm);
                p += nl;
                continue;
            }
            out[o++] = *p++;
            if (p - 1 == ins) /* after the #version line: forwarders for the shapes the pack didn't define */
                for (int ti = 0; ti < 4; ti++)
                    if (!defined[ti])
                        o += (size_t)sprintf(out + o, "%s mgl_%s(%s x) { return %s(x); }\n", types[ti], nm, types[ti], nm);
        }
        out[o] = 0;
        free(cur);
        cur = out;
    }
    return cur;
}

void mgl_xlate_set_deferred(int on) { deferred = on; }

int mgl_xlate_emit(void *pending[MGL_NUM_STAGES], char *msl[MGL_NUM_STAGES], char **log)
{
    int ok = 1;
    for (int s = 0; s < MGL_NUM_STAGES; s++) {
        pending_stage *ps = pending[s];
        if (!ps)
            continue;
        const char *out = NULL;
        if (ok && spvc_compiler_compile(ps->comp, &out) == SPVC_SUCCESS) {
            msl[s] = msl_dup(out, ps->stage);
        } else if (ok) {
            ok = 0;
            mgl_xlate_result tmp = {0};
            xlog(&tmp, "%s: SPIRV-Cross: %s", stage_name[ps->stage], spvc_context_get_last_error_string(ps->ctx));
            *log = tmp.log;
        }
        spvc_context_destroy(ps->ctx);
        free(ps);
        pending[s] = NULL;
    }
    return ok;
}

void mgl_xlate_set_frag_binds(const mgl_frag_bind *binds, int n)
{
    frag_binds = binds;
    num_frag_binds = n;
}

void mgl_xlate_program(const char *src[MGL_NUM_STAGES], mgl_xlate_result *r)
{
    const char *cur[MGL_NUM_STAGES] = {src[0], src[1], src[2]};
    char *renamed[MGL_NUM_STAGES];
    for (int st = 0; st < MGL_NUM_STAGES; st++) {
        if ((renamed[st] = rename_vulkan_words(src[st])) != NULL)
            cur[st] = renamed[st];
        char *fixed = fix_builtin_overrides(cur[st]);
        if (fixed) {
            free(renamed[st]);
            cur[st] = renamed[st] = fixed;
        }
    }
    char *patched = NULL;
    for (int tries = 0; tries < 16; tries++) {
        if (xlate_once(cur, r))
            break;
        const char *m = r->log ? strstr(r->log, "Input '") : NULL;
        if (!m || !strstr(m, "has no corresponding output") || !cur[MGL_VERTEX] || !cur[MGL_FRAGMENT])
            break;
        char name[96];
        const char *q = strchr(m + 7, '\'');
        if (!q || q - (m + 7) >= (long)sizeof name)
            break;
        memcpy(name, m + 7, (size_t)(q - (m + 7)));
        name[q - (m + 7)] = 0;
        char *next = add_missing_output(cur[MGL_VERTEX], cur[MGL_FRAGMENT], name);
        if (!next)
            break;
        free(patched);
        patched = next;
        cur[MGL_VERTEX] = patched;
        mgl_xlate_free(r);
    }
    if (r->ok)
        for (int st = 0; st < MGL_NUM_STAGES; st++)
            mark_bools(r, cur[st]);
    free(patched);
    for (int st = 0; st < MGL_NUM_STAGES; st++)
        free(renamed[st]);
}

void mgl_xlate_free(mgl_xlate_result *r)
{
    for (int s = 0; s < MGL_NUM_STAGES; s++)
        if (r->pending[s]) {
            pending_stage *ps = r->pending[s];
            spvc_context_destroy(ps->ctx);
            free(ps);
        }
    free(r->log);
    for (int s = 0; s < MGL_NUM_STAGES; s++)
        free(r->msl[s]);
    free(r->uniforms);
    free(r->textures);
    free(r->ubos);
    free(r->ssbos);
    free(r->attribs);
    free(r->outs);
    memset(r, 0, sizeof *r);
}
