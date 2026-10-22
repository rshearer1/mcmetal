/* Geometry shader emulation. Metal has no geometry stage, so a VS+GS(+FS) program becomes:
     compute  - one thread per input triangle: fetches its 3 vertices straight from the vertex buffers, runs the
                vertex shader on each, then the geometry shader, which appends its emitted vertices to a buffer
                (gs_max_vertices records per triangle, plus how many were emitted)
     vertex   - a passthrough that turns each triangle's emitted strip into a triangle list (unused slots become
                degenerate triangles)
     fragment - the original fragment shader, unchanged
   Both shaders are rewritten at the GLSL level (after preprocessing) and then go through the normal translator.
   Scope: GS input `triangles`, output `triangle_strip`, plain (non-block, non-array) varyings, GL_TRIANGLES draws. */
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glslang/Include/glslang_c_interface.h>
#include <glslang/Public/resource_limits_c.h>
#include "mgl_xlate.h"

/* ------------------------------------------------------------------ string builder */
typedef struct { char *s; size_t n, cap; } sb;

static void sb_add(sb *b, const char *s, size_t n)
{
    if (b->n + n + 1 > b->cap) {
        b->cap = (b->n + n + 1) * 2 + 256;
        b->s = realloc(b->s, b->cap);
    }
    memcpy(b->s + b->n, s, n);
    b->n += n;
    b->s[b->n] = 0;
}

static void sb_puts(sb *b, const char *s) { sb_add(b, s, strlen(s)); }

static void sb_printf(sb *b, const char *fmt, ...)
{
    char tmp[4096];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    sb_add(b, tmp, (size_t)(n < (int)sizeof tmp ? n : (int)sizeof tmp - 1));
}

/* ------------------------------------------------------------------ tokens */
enum { T_ID = 1, T_NUM, T_PUNCT };
typedef struct { int kind; const char *p; int n; } tok;
typedef struct { tok *t; int n; } toks;

static int tok_is(const tok *t, const char *s) { return (int)strlen(s) == t->n && !memcmp(t->p, s, (size_t)t->n); }

static toks tokenize(const char *s)
{
    static const char *ops[] = {"<<=", ">>=", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "==", "!=",
                                "<=", ">=", "&&", "||", "^^", "<<", ">>", NULL};
    toks r = {0};
    int cap = 0;
    for (const char *p = s; *p;) {
        if (*p == '#') { /* directive lines (#version, #extension, #line): dropped, we write our own */
            while (*p && *p != '\n')
                p++;
            continue;
        }
        if (isspace((unsigned char)*p)) {
            p++;
            continue;
        }
        if (p[0] == '/' && p[1] == '/') {
            while (*p && *p != '\n')
                p++;
            continue;
        }
        if (p[0] == '/' && p[1] == '*') {
            const char *e = strstr(p + 2, "*/");
            p = e ? e + 2 : p + strlen(p);
            continue;
        }
        tok t = {0, p, 1};
        if (isalpha((unsigned char)*p) || *p == '_') {
            const char *q = p;
            while (isalnum((unsigned char)*q) || *q == '_')
                q++;
            t.kind = T_ID;
            t.n = (int)(q - p);
        } else if (isdigit((unsigned char)*p) || (*p == '.' && isdigit((unsigned char)p[1]))) {
            const char *q = p;
            int hex = p[0] == '0' && (p[1] == 'x' || p[1] == 'X');
            while (isalnum((unsigned char)*q) || *q == '.' || *q == '_' ||
                   ((*q == '+' || *q == '-') && !hex && (q[-1] == 'e' || q[-1] == 'E')))
                q++;
            t.kind = T_NUM;
            t.n = (int)(q - p);
        } else {
            t.kind = T_PUNCT;
            for (int i = 0; ops[i]; i++)
                if (!strncmp(p, ops[i], strlen(ops[i]))) {
                    t.n = (int)strlen(ops[i]);
                    break;
                }
        }
        if (r.n == cap) {
            cap = cap ? cap * 2 : 1024;
            r.t = realloc(r.t, sizeof(tok) * (size_t)cap);
        }
        r.t[r.n++] = t;
        p += t.n;
    }
    return r;
}

/* index of the token closing the bracket opened at i */
static int match(const toks *ts, int i)
{
    char open = ts->t[i].p[0], close = open == '(' ? ')' : open == '[' ? ']' : '}';
    int depth = 0;
    for (int k = i; k < ts->n; k++) {
        if (ts->t[k].kind != T_PUNCT || ts->t[k].n != 1)
            continue;
        if (ts->t[k].p[0] == open)
            depth++;
        else if (ts->t[k].p[0] == close && --depth == 0)
            return k;
    }
    return ts->n - 1;
}

/* ------------------------------------------------------------------ top-level statements */
enum { S_OTHER, S_FUNC, S_STRUCT, S_BLOCK, S_DECL, S_LAYOUT_ONLY, S_PRECISION };
enum { Q_IN = 1, Q_OUT = 2, Q_UNIFORM = 4, Q_CONST = 8, Q_FLAT = 16, Q_NOPERSP = 32, Q_BUFFER = 64, Q_SHARED = 128 };

typedef struct {
    int kind, start, end;         /* tokens [start, end) */
    int quals;                    /* Q_* */
    int layout_start, layout_end; /* layout( ... ) token range, or -1 */
    int type_start, type_end;     /* type tokens (incl. array suffix on the type) */
    int names[16], nnames;        /* declarator name tokens */
    int name_arr[16];             /* declarator has [..] after its name */
    int fname;                    /* S_FUNC / S_STRUCT / S_BLOCK name token */
} stmt;

typedef struct { stmt *s; int n; } stmts;

static int is_qual(const tok *t, int *q)
{
    static const struct { const char *w; int q; } tab[] = {
        {"in", Q_IN}, {"out", Q_OUT}, {"uniform", Q_UNIFORM}, {"const", Q_CONST}, {"flat", Q_FLAT},
        {"noperspective", Q_NOPERSP}, {"buffer", Q_BUFFER}, {"shared", Q_SHARED}, {"smooth", 0}, {"centroid", 0},
        {"invariant", 0}, {"highp", 0}, {"mediump", 0}, {"lowp", 0}, {"precise", 0}, {"readonly", 0},
        {"writeonly", 0}, {"coherent", 0}, {"restrict", 0}, {"volatile", 0}, {"sample", 0}, {NULL, 0}};
    if (t->kind != T_ID)
        return 0;
    for (int i = 0; tab[i].w; i++)
        if (tok_is(t, tab[i].w)) {
            *q |= tab[i].q;
            return 1;
        }
    return 0;
}

static stmts parse_top(const toks *ts)
{
    stmts r = {0};
    int cap = 0;
    for (int i = 0; i < ts->n;) {
        stmt s;
        memset(&s, 0, sizeof s);
        s.start = i;
        s.layout_start = s.layout_end = -1;
        s.fname = -1;
        int k = i;
        for (;;) { /* qualifiers */
            if (k + 1 < ts->n && tok_is(&ts->t[k], "layout") && tok_is(&ts->t[k + 1], "(")) {
                s.layout_start = k;
                s.layout_end = match(ts, k + 1) + 1;
                k = s.layout_end;
                continue;
            }
            if (k < ts->n && is_qual(&ts->t[k], &s.quals)) {
                k++;
                continue;
            }
            break;
        }
        if (k < ts->n && tok_is(&ts->t[k], ";")) { /* layout(...) in; */
            s.kind = S_LAYOUT_ONLY;
            s.end = k + 1;
        } else if (k < ts->n && tok_is(&ts->t[k], "precision")) {
            while (k < ts->n && !tok_is(&ts->t[k], ";"))
                k++;
            s.kind = S_PRECISION;
            s.end = k + 1;
        } else if (k < ts->n && tok_is(&ts->t[k], "struct")) { /* struct X {...} [declarators]; */
            s.kind = S_STRUCT;
            s.fname = k + 1;
            int b = k + 2;
            while (b < ts->n && !tok_is(&ts->t[b], "{"))
                b++;
            k = match(ts, b) + 1;
            s.type_start = s.type_end = -1;
            while (k < ts->n && !tok_is(&ts->t[k], ";")) {
                if (ts->t[k].kind == T_ID && s.nnames < 16)
                    s.names[s.nnames++] = k;
                k++;
            }
            s.end = k + 1;
        } else if (k + 1 < ts->n && ts->t[k].kind == T_ID && tok_is(&ts->t[k + 1], "{")) { /* uniform Block { } x; */
            s.kind = S_BLOCK;
            s.fname = k;
            k = match(ts, k + 1) + 1;
            while (k < ts->n && !tok_is(&ts->t[k], ";")) {
                if (ts->t[k].kind == T_ID && s.nnames < 16)
                    s.names[s.nnames++] = k;
                k++;
            }
            s.end = k + 1;
        } else { /* type [array] name ... : function or declaration */
            s.type_start = k;
            k++;
            while (k < ts->n && tok_is(&ts->t[k], "["))
                k = match(ts, k) + 1;
            s.type_end = k;
            if (k + 1 < ts->n && ts->t[k].kind == T_ID && tok_is(&ts->t[k + 1], "(")) {
                int close = match(ts, k + 1);
                s.fname = k;
                s.kind = S_FUNC;
                if (close + 1 < ts->n && tok_is(&ts->t[close + 1], "{"))
                    s.end = match(ts, close + 1) + 1;
                else
                    s.end = close + 2; /* prototype */
            } else {
                s.kind = S_DECL;
                while (k < ts->n && !tok_is(&ts->t[k], ";")) {
                    if (ts->t[k].kind == T_ID && s.nnames < 16) {
                        s.names[s.nnames] = k;
                        s.name_arr[s.nnames] = k + 1 < ts->n && tok_is(&ts->t[k + 1], "[");
                        s.nnames++;
                    }
                    k++;
                    /* skip array sizes and initialisers up to the next top-level comma */
                    while (k < ts->n && !tok_is(&ts->t[k], ",") && !tok_is(&ts->t[k], ";")) {
                        if (tok_is(&ts->t[k], "(") || tok_is(&ts->t[k], "[") || tok_is(&ts->t[k], "{"))
                            k = match(ts, k);
                        k++;
                    }
                    if (k < ts->n && tok_is(&ts->t[k], ","))
                        k++;
                }
                s.end = k + 1;
            }
        }
        if (s.end <= i)
            s.end = i + 1;
        if (s.end > ts->n)
            s.end = ts->n;
        if (r.n == cap) {
            cap = cap ? cap * 2 : 256;
            r.s = realloc(r.s, sizeof(stmt) * (size_t)cap);
        }
        r.s[r.n++] = s;
        i = s.end;
    }
    return r;
}

/* ------------------------------------------------------------------ renaming */
typedef struct { char from[96], to[112]; } rename_t;
typedef struct { rename_t *r; int n; } renames;

static void add_rename(renames *m, const tok *t, const char *prefix)
{
    if (t->n >= 96)
        return;
    m->r = realloc(m->r, sizeof(rename_t) * (size_t)(m->n + 1));
    rename_t *e = &m->r[m->n++];
    memcpy(e->from, t->p, (size_t)t->n);
    e->from[t->n] = 0;
    snprintf(e->to, sizeof e->to, "%s%s", prefix, e->from);
}

static void add_rename_s(renames *m, const char *from, const char *to)
{
    m->r = realloc(m->r, sizeof(rename_t) * (size_t)(m->n + 1));
    rename_t *e = &m->r[m->n++];
    snprintf(e->from, sizeof e->from, "%s", from);
    snprintf(e->to, sizeof e->to, "%s", to);
}

static const char *lookup(const renames *m, const tok *t)
{
    for (int i = 0; i < m->n; i++)
        if (tok_is(t, m->r[i].from))
            return m->r[i].to;
    return NULL;
}

/* emit tokens [a, b) with renames; member accesses (after '.') keep their names, except gl_in[i].gl_Position */
static void emit_range(sb *o, const toks *ts, int a, int b, const renames *m)
{
    for (int k = a; k < b; k++) {
        const tok *t = &ts->t[k];
        const char *to = NULL;
        int after_dot = k > 0 && tok_is(&ts->t[k - 1], ".");
        if (t->kind == T_ID && !after_dot)
            to = lookup(m, t);
        if (t->kind == T_ID && after_dot && tok_is(t, "gl_Position"))
            to = "pos";
        if (t->kind == T_ID && after_dot && tok_is(t, "gl_PointSize"))
            to = "pointSize";
        if (to)
            sb_puts(o, to);
        else
            sb_add(o, t->p, (size_t)t->n);
        sb_puts(o, tok_is(t, ";") || tok_is(t, "{") || tok_is(t, "}") ? "\n" : " ");
    }
}

/* A vertex-shader global with an initialiser, such as Iris's
     vec4 iris_Entity = vec4(int(mc_Entity >> 1u) - 1, mc_Entity & 1u, 0, 1);
   In GL it is evaluated per vertex, after the attributes are read. In the compute job the attributes are fetched
   inside the per-vertex loop, so the declaration keeps no initialiser and the assignment goes into
   mgl_v_init(), called before each vertex's main. Returns 0 (emit as is) when nothing needs splitting. */
static int split_global_init(sb *decl, sb *init, const toks *ts, const stmt *s, const renames *m)
{
    int any = 0;
    for (int k = 0; k < s->nnames; k++) {
        int j = s->names[k] + 1;
        while (j < s->end && tok_is(&ts->t[j], "["))
            j = match(ts, j) + 1;
        any |= j < s->end && tok_is(&ts->t[j], "=");
    }
    if (!any)
        return 0;
    for (int k = 0; k < s->nnames; k++) {
        int n = s->names[k], j = n + 1;
        while (j < s->end && tok_is(&ts->t[j], "["))
            j = match(ts, j) + 1;
        int e = j, unsized = 0;
        if (j < s->end && tok_is(&ts->t[j], "=")) {
            e = j + 1;
            while (e < s->end && !tok_is(&ts->t[e], ",") && !tok_is(&ts->t[e], ";")) {
                if (tok_is(&ts->t[e], "(") || tok_is(&ts->t[e], "[") || tok_is(&ts->t[e], "{"))
                    e = match(ts, e);
                e++;
            }
        }
        for (int q = s->start; q + 1 < j; q++) /* vec3[] x = vec3[](...): the size comes from the initialiser */
            unsized |= tok_is(&ts->t[q], "[") && tok_is(&ts->t[q + 1], "]");
        emit_range(decl, ts, s->start, s->type_end, m); /* qualifiers and type */
        emit_range(decl, ts, n, unsized ? e : j, m);    /* name, array suffix (and an unsized array's initialiser) */
        sb_puts(decl, ";\n");
        if (!unsized && j < s->end && tok_is(&ts->t[j], "=")) {
            sb_puts(init, "  ");
            emit_range(init, ts, n, n + 1, m);
            sb_puts(init, "= ");
            emit_range(init, ts, j + 1, e, m);
            sb_puts(init, ";\n");
        }
    }
    return 1;
}

/* a loose uniform declaration without layout(location = N), keeping image formats and bindings */
static void emit_uniform(sb *o, const toks *ts, const stmt *s, const renames *m)
{
    int a = s->start;
    if (s->layout_start >= 0) {
        emit_range(o, ts, a, s->layout_start, m);
        sb items = {0};
        int k = s->layout_start + 2, end = s->layout_end - 1; /* inside layout( ... ) */
        while (k < end) {
            int e = k;
            while (e < end && !tok_is(&ts->t[e], ","))
                e++;
            if (!tok_is(&ts->t[k], "location")) {
                if (items.s)
                    sb_puts(&items, ", ");
                emit_range(&items, ts, k, e, m);
            }
            k = e + 1;
        }
        if (items.s)
            sb_printf(o, "layout(%s) ", items.s);
        free(items.s);
        a = s->layout_end;
    }
    emit_range(o, ts, a, s->end, m);
}

static void tok_str(const tok *t, char *buf, size_t n)
{
    size_t m = (size_t)t->n < n - 1 ? (size_t)t->n : n - 1;
    memcpy(buf, t->p, m);
    buf[m] = 0;
}

/* ------------------------------------------------------------------ preprocessing */
static char *preprocess(const char *src, glslang_stage_t stage, char **log)
{
    glslang_input_t in = {
        .language = GLSLANG_SOURCE_GLSL,
        .stage = stage,
        .client = GLSLANG_CLIENT_VULKAN,
        .client_version = GLSLANG_TARGET_VULKAN_1_0,
        .target_language = GLSLANG_TARGET_SPV,
        .target_language_version = GLSLANG_TARGET_SPV_1_0,
        .code = src,
        .default_version = 110,
        .default_profile = GLSLANG_NO_PROFILE,
        .messages = GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT,
        .resource = glslang_default_resource(),
    };
    glslang_initialize_process();
    glslang_shader_t *sh = glslang_shader_create(&in);
    char *out = NULL;
    if (glslang_shader_preprocess(sh, &in))
        out = strdup(glslang_shader_get_preprocessed_code(sh));
    else if (log)
        *log = strdup(glslang_shader_get_info_log(sh));
    glslang_shader_delete(sh);
    return out;
}

/* does text contain name as a whole identifier (comments and inactive #if blocks count: erring on keeping) */
static int mentions(const char *text, const char *name)
{
    size_t n = strlen(name);
    for (const char *p = strstr(text, name); p; p = strstr(p + 1, name)) {
        char a = p > text ? p[-1] : ' ', b = p[n];
        if (!(isalnum((unsigned char)a) || a == '_') && !(isalnum((unsigned char)b) || b == '_'))
            return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ varyings */
/* How many leading components of fragment input `name` the fragment shader reads: when every use is swizzled
   (SEUS reads only texcoord.xy and viewPos.xyz), the highest component named; otherwise all of them. The one
   unswizzled occurrence allowed is its declaration, `<type> name`. */
static int fs_used_comps(const char *fs, const char *type, const char *name, int comps)
{
    size_t n = strlen(name), tn = strlen(type);
    int hi = -1, bare = 0;
    if (strstr(fs, "##")) /* token pasting can build a use this scan can't see */
        return comps;
    for (const char *p = strstr(fs, name); p; p = strstr(p + 1, name)) {
        char a = p > fs ? p[-1] : ' ', b = p[n];
        if (isalnum((unsigned char)a) || a == '_' || isalnum((unsigned char)b) || b == '_')
            continue;
        const char *q = p + n;
        while (*q == ' ' || *q == '\t')
            q++;
        if (*q != '.') {
            const char *t = p;
            while (t > fs && (t[-1] == ' ' || t[-1] == '\t'))
                t--;
            if (++bare > 1 || (size_t)(t - fs) < tn || strncmp(t - tn, type, tn) ||
                (t - tn > fs && (isalnum((unsigned char)t[-(ptrdiff_t)tn - 1]) || t[-(ptrdiff_t)tn - 1] == '_')))
                return comps;
            continue;
        }
        const char *a2 = p;
        while (a2 > fs && (a2[-1] == ' ' || a2[-1] == '\t'))
            a2--;
        if (a2 > fs && a2[-1] == '.') /* a member of something else */
            return comps;
        int len = 0;
        for (q++; isalpha((unsigned char)*q); q++, len++) {
            const char *c = strchr("xyzwrgbastpq", *q);
            if (!c)
                return comps;
            int idx = (int)(c - "xyzwrgbastpq") % 4;
            hi = idx > hi ? idx : hi;
        }
        if (!len || len > 4)
            return comps;
    }
    return hi < 0 ? comps : hi + 1 < comps ? hi + 1 : comps;
}


typedef struct {
    char type[32], name[96];
    int comps, is_int, is_uint, flat, noperspective;
    int stored; /* leading components kept in the records (the rest are never read: written as 0) */
} varying;

static int type_info(const char *t, int *comps, int *is_int, int *is_uint)
{
    static const struct { const char *t; int c, i, u; } tab[] = {
        {"float", 1, 0, 0}, {"vec2", 2, 0, 0}, {"vec3", 3, 0, 0}, {"vec4", 4, 0, 0},
        {"int", 1, 1, 0}, {"ivec2", 2, 1, 0}, {"ivec3", 3, 1, 0}, {"ivec4", 4, 1, 0},
        {"uint", 1, 0, 1}, {"uvec2", 2, 0, 1}, {"uvec3", 3, 0, 1}, {"uvec4", 4, 0, 1},
        {"bool", 1, 1, 0}, {NULL, 0, 0, 0}};
    for (int i = 0; tab[i].t; i++)
        if (!strcmp(t, tab[i].t)) {
            *comps = tab[i].c;
            *is_int = tab[i].i;
            *is_uint = tab[i].u;
            return 1;
        }
    return 0;
}

static const char *swz[5] = {"", ".x", ".xy", ".xyz", ""};

/* value of a varying packed into a vec4 (ints as bits) */
/* Records are tightly packed floats: position (4), then each varying's own components, then the strip id (1).
   SEUS's shadow pass writes 20 floats per vertex instead of 10 vec4s: the record traffic was most of the geometry
   stage's cost. Outputs set only to a constant and components the fragment shader never reads are left out. */
static void pack_store(sb *o, const varying *v, const char *expr, int off)
{
    for (int j = 0; j < v->stored; j++) {
        char c[160];
        if (v->comps == 1)
            snprintf(c, sizeof c, "%s", expr);
        else
            snprintf(c, sizeof c, "%s[%d]", expr, j);
        if (!strcmp(v->type, "bool"))
            sb_printf(o, "  mgl_ov[mgl_rec + %du] = %s ? 1.0 : 0.0;\n", off + j, c);
        else if (v->is_int)
            sb_printf(o, "  mgl_ov[mgl_rec + %du] = intBitsToFloat(%s);\n", off + j, c);
        else if (v->is_uint)
            sb_printf(o, "  mgl_ov[mgl_rec + %du] = uintBitsToFloat(%s);\n", off + j, c);
        else
            sb_printf(o, "  mgl_ov[mgl_rec + %du] = %s;\n", off + j, c);
    }
}

static void unpack_expr(sb *o, const varying *v, int off)
{
    const char *conv = v->is_int && strcmp(v->type, "bool") ? "floatBitsToInt" : v->is_uint ? "floatBitsToUint" : "";
    if (!strcmp(v->type, "bool")) {
        sb_printf(o, "(mgl_ov[mgl_rec + %du] > 0.5 ? 1 : 0)", off);
        return;
    }
    if (v->comps > 1)
        sb_printf(o, "%s(", v->type);
    for (int j = 0; j < v->comps; j++)
        if (j < v->stored)
            sb_printf(o, "%s%s(mgl_ov[mgl_rec + %du])", j ? ", " : "", conv, off + j);
        else
            sb_printf(o, "%s%s", j ? ", " : "", v->is_int || v->is_uint ? "0" : "0.0");
    if (v->comps > 1)
        sb_puts(o, ")");
}

/* ------------------------------------------------------------------ the rewrite */
typedef struct {
    char type[32], name[96], renamed[112];
    int location, comps, is_int, is_uint;
} vs_attr;

/* A geometry output the shader only ever sets to one constant, such as Iris's `isWater = 0.0f;` in SEUS's shadow
   pass: it needs no space in the records, the passthrough stage writes the constant itself. Returns 1 and the
   constant's text when every use of the name outside its declaration is `name = <literal or constructor of
   literals>;` with the same right-hand side. */
static int const_output(const toks *ts, const stmts *ss, const char *name, char *rhs, size_t cap)
{
    static const char *const ctor[] = {"float", "int", "uint", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
                                       "uvec2", "uvec3", "uvec4", NULL};
    int found = 0;
    rhs[0] = 0;
    for (int i = 0; i < ss->n; i++) {
        const stmt *st = &ss->s[i];
        if (st->kind == S_DECL && (st->quals & (Q_IN | Q_OUT)))
            continue;
        for (int k = st->start; k < st->end; k++) {
            const tok *t = &ts->t[k];
            if (t->kind != T_ID || (int)strlen(name) != t->n || memcmp(t->p, name, (size_t)t->n) ||
                (k > 0 && tok_is(&ts->t[k - 1], ".")))
                continue;
            if (k + 1 >= st->end || !tok_is(&ts->t[k + 1], "=") || (k > 0 && !tok_is(&ts->t[k - 1], ";") &&
                                                                     !tok_is(&ts->t[k - 1], "{") && !tok_is(&ts->t[k - 1], "}")))
                return 0; /* read, swizzled, compound-assigned, passed on, or part of a larger expression */
            char cur[256];
            size_t n = 0;
            int j = k + 2;
            for (; j < st->end && !tok_is(&ts->t[j], ";"); j++) {
                const tok *a = &ts->t[j];
                int ok = a->kind == T_NUM || tok_is(a, "(") || tok_is(a, ")") || tok_is(a, ",") || tok_is(a, "-") ||
                         tok_is(a, "+");
                for (int c = 0; !ok && a->kind == T_ID && ctor[c]; c++)
                    ok = tok_is(a, ctor[c]);
                if (!ok || n + (size_t)a->n + 2 >= sizeof cur)
                    return 0;
                memcpy(cur + n, a->p, (size_t)a->n);
                n += (size_t)a->n;
                cur[n++] = ' '; /* keeps `1.0 - -2.0` from becoming `1.0--2.0` */
            }
            cur[n] = 0;
            if (j >= st->end || !n || (found && strcmp(cur, rhs)))
                return 0;
            if (!found && strlen(cur) < cap)
                memcpy(rhs, cur, n + 1);
            else if (!found)
                return 0;
            found = 1;
            k = j;
        }
    }
    return found;
}

static void fail(mgl_xlate_result *r, const char *msg)
{
    memset(r, 0, sizeof *r);
    r->log = strdup(msg);
}

static int layout_int(const toks *ts, const stmt *s, const char *key)
{
    for (int k = s->layout_start; k >= 0 && k + 2 < s->layout_end; k++)
        if (tok_is(&ts->t[k], key) && tok_is(&ts->t[k + 1], "="))
            return atoi(ts->t[k + 2].p);
    return -1;
}

static int layout_has(const toks *ts, const stmt *s, const char *word)
{
    for (int k = s->layout_start; k >= 0 && k < s->layout_end; k++)
        if (tok_is(&ts->t[k], word))
            return 1;
    return 0;
}

static int same_tok(const tok *a, const tok *b) { return a->n == b->n && !memcmp(a->p, b->p, (size_t)a->n); }

/* does the vertex shader declare uniform `t` (loose or as a block name)? */
static int vs_has_uniform(const toks *tv, const stmts *sv, const tok *t, int block)
{
    for (int j = 0; j < sv->n; j++) {
        const stmt *s = &sv->s[j];
        if (block && s->kind == S_BLOCK && same_tok(&tv->t[s->fname], t))
            return 1;
        if (!block && s->kind == S_DECL && (s->quals & Q_UNIFORM))
            for (int m = 0; m < s->nnames; m++)
                if (same_tok(&tv->t[s->names[m]], t))
                    return 1;
    }
    return 0;
}

static void dump(const char *what, const char *text, const void *id)
{
    const char *dir = getenv("MGL_DUMP_DIR");
    if (!dir)
        return;
    char path[512];
    snprintf(path, sizeof path, "%s/gs-%p.%s", dir, id, what);
    FILE *f = fopen(path, "w");
    if (f) {
        fputs(text, f);
        fclose(f);
    }
}

static const char *compute_prelude =
    "#version 450\nlayout(local_size_x = 64) in;\n"
    "layout(std430, binding = 20) readonly buffer mgl_i0_ { ivec4 mgl_attr[16]; };\n"
    "layout(std430, binding = 21) readonly buffer mgl_i1_ { uint mgl_vb0[]; };\n"
    "layout(std430, binding = 22) readonly buffer mgl_i2_ { uint mgl_vb1[]; };\n"
    "layout(std430, binding = 23) readonly buffer mgl_i3_ { uint mgl_vb2[]; };\n"
    "layout(std430, binding = 24) readonly buffer mgl_i4_ { uint mgl_vb3[]; };\n"
    "layout(std430, binding = 25) readonly buffer mgl_i5_ { uint mgl_ib[]; };\n"
    "layout(std430, binding = 26) writeonly buffer mgl_i6_ { float mgl_ov[]; };\n"
    "layout(std430, binding = 27) writeonly buffer mgl_i7_ { uint mgl_oc[]; };\n"
    /* a multi-draw as one job: [0].x = sections (0 = a single draw, see mgl_draw_info), then per section its first
       triangle slot (even), triangles, base vertex and first index */
    "layout(std430, binding = 28) readonly buffer mgl_i8_ { uvec4 mgl_sec[]; };\n"
    "uniform ivec4 mgl_draw_info; /* triangles, index type (0 none, 1 u16, 2 u32), base vertex, first index */\n"
    "vec4 mgl_v_Position; float mgl_v_PointSize; int mgl_vertex_id; int mgl_instance_id;\n"
    "struct mgl_gin_t { vec4 pos; float pointSize; };\nmgl_gin_t mgl_gin[3];\n"
    "vec4 mgl_g_Position; float mgl_g_PointSize; int mgl_prim_id; int mgl_g_PrimitiveID; int mgl_g_Layer;\n"
    "int mgl_g_ViewportIndex; const int mgl_invocation_id = 0; uint mgl_emitted; uint mgl_strip; uint mgl_slot;\n"
    "uint mgl_first; uint mgl_bv; uint mgl_ntri;\n"
    "void mgl_emit();\nvoid mgl_end_primitive();\n"
    "uint mgl_word(int b, uint w) {\n"
    "  if (b == 0) return mgl_vb0[w];\n  if (b == 1) return mgl_vb1[w];\n  if (b == 2) return mgl_vb2[w];\n"
    "  return mgl_vb3[w];\n}\n"
    "uint mgl_bits(int b, uint off, uint size) {\n"
    "  uint w = mgl_word(b, off >> 2u);\n  if (size == 4u) return w;\n"
    "  return (w >> ((off & 3u) * 8u)) & ((1u << (size * 8u)) - 1u);\n}\n"
    /* attribute descriptor: x buffer (-1 none), y byte offset, z stride, w type | size << 4 | normalized << 8 */
    "vec4 mgl_fetchf(int loc, uint v) {\n"
    "  ivec4 a = mgl_attr[loc];\n  vec4 r = vec4(0.0, 0.0, 0.0, 1.0);\n  if (a.x < 0) return r;\n"
    "  int type = a.w & 15;\n  int n = (a.w >> 4) & 7;\n  bool norm = ((a.w >> 8) & 1) != 0;\n"
    "  uint sz = (type == 0 || type >= 6) ? 4u : (type == 1 || type == 4 || type == 5) ? 2u : 1u;\n"
    "  uint base = uint(a.y) + v * uint(a.z);\n"
    "  for (int c = 0; c < 4; c++) {\n    if (c >= n) break;\n"
    "    uint b = mgl_bits(a.x, base + uint(c) * sz, sz);\n    float f;\n"
    "    if (type == 0) f = uintBitsToFloat(b);\n"
    "    else if (type == 1) f = unpackHalf2x16(b).x;\n"
    "    else if (type == 2) f = norm ? float(b) / 255.0 : float(b);\n"
    "    else if (type == 3) { int s = int(b << 24u) >> 24; f = norm ? max(float(s) / 127.0, -1.0) : float(s); }\n"
    "    else if (type == 4) f = norm ? float(b) / 65535.0 : float(b);\n"
    "    else if (type == 5) { int s = int(b << 16u) >> 16; f = norm ? max(float(s) / 32767.0, -1.0) : float(s); }\n"
    "    else if (type == 6) f = float(b);\n    else f = float(int(b));\n"
    "    r[c] = f;\n  }\n  return r;\n}\n"
    "ivec4 mgl_fetchi(int loc, uint v) {\n"
    "  ivec4 a = mgl_attr[loc];\n  ivec4 r = ivec4(0, 0, 0, 1);\n  if (a.x < 0) return r;\n"
    "  int type = a.w & 15;\n  int n = (a.w >> 4) & 7;\n"
    "  uint sz = (type == 0 || type >= 6) ? 4u : (type == 1 || type == 4 || type == 5) ? 2u : 1u;\n"
    "  uint base = uint(a.y) + v * uint(a.z);\n"
    "  for (int c = 0; c < 4; c++) {\n    if (c >= n) break;\n"
    "    uint b = mgl_bits(a.x, base + uint(c) * sz, sz);\n    int x;\n"
    "    if (type == 3) x = int(b << 24u) >> 24;\n    else if (type == 5) x = int(b << 16u) >> 16;\n"
    "    else if (type == 0) x = int(uintBitsToFloat(b));\n    else x = int(b);\n"
    "    r[c] = x;\n  }\n  return r;\n}\n"
    /* sets the section of triangle slot g and returns g's triangle within it (>= mgl_ntri: a padding slot) */
    "uint mgl_locate(uint g) {\n"
    "  uint n = mgl_sec[0].x;\n"
    "  if (n == 0u) { mgl_first = uint(mgl_draw_info.w); mgl_bv = uint(mgl_draw_info.z); mgl_ntri = uint(mgl_draw_info.x); return g; }\n"
    "  uint lo = 1u, hi = n;\n"
    "  while (lo < hi) { uint m = (lo + hi + 1u) >> 1u; if (mgl_sec[m].x <= g) lo = m; else hi = m - 1u; }\n"
    "  uvec4 e = mgl_sec[lo];\n  mgl_first = e.w; mgl_bv = e.z; mgl_ntri = e.y;\n  return g - e.x;\n}\n"
    "uint mgl_index(uint i) {\n"
    "  uint k = mgl_first + i;\n  if (mgl_draw_info.y == 0) return k;\n"
    "  if (mgl_draw_info.y == 1) return (mgl_ib[k >> 1u] >> ((k & 1u) * 16u)) & 0xffffu;\n"
    "  return mgl_ib[k];\n}\n";

void mgl_gs_translate(const char *src[MGL_NUM_STAGES], const char *geometry, mgl_xlate_result *r)
{
    char *plog = NULL;
    char *pv = src[MGL_VERTEX] ? preprocess(src[MGL_VERTEX], GLSLANG_STAGE_VERTEX, &plog) : NULL;
    char *pg = pv ? preprocess(geometry, GLSLANG_STAGE_GEOMETRY, &plog) : NULL;
    if (!pv || !pg) {
        fail(r, plog ? plog : "geometry emulation: preprocessing failed");
        free(plog);
        free(pv);
        free(pg);
        return;
    }
    toks tv = tokenize(pv), tg = tokenize(pg);
    stmts sv = parse_top(&tv), sg = parse_top(&tg);
    sb vs = {0}, vinit = {0}, gs = {0}, comp = {0}, pass = {0};
    renames rv = {0}, rg = {0};
    vs_attr attrs[32];
    int nattrs = 0;
    varying gin[32], gout[32];
    int ngin = 0, ngout = 0, max_vertices = -1, strip_out = 0, tri_in = 0;
    const char *err = NULL;

    /* ---- vertex shader: rename its globals so they can't clash with the geometry shader's ---- */
    add_rename_s(&rv, "gl_Position", "mgl_v_Position");
    add_rename_s(&rv, "gl_PointSize", "mgl_v_PointSize");
    add_rename_s(&rv, "gl_VertexID", "mgl_vertex_id");
    add_rename_s(&rv, "gl_VertexIndex", "mgl_vertex_id");
    add_rename_s(&rv, "gl_InstanceID", "mgl_instance_id");
    add_rename_s(&rv, "gl_InstanceIndex", "mgl_instance_id");
    for (int i = 0; i < sv.n; i++) {
        stmt *s = &sv.s[i];
        if (s->kind == S_FUNC || s->kind == S_STRUCT)
            add_rename(&rv, &tv.t[s->fname], "mgl_v_");
        if ((s->kind == S_DECL && !(s->quals & Q_UNIFORM)) || s->kind == S_STRUCT)
            for (int k = 0; k < s->nnames; k++)
                add_rename(&rv, &tv.t[s->names[k]], (s->quals & Q_IN) ? "mgl_a_" : "mgl_v_");
    }
    for (int i = 0; i < sv.n && !err; i++) {
        stmt *s = &sv.s[i];
        if (s->kind == S_LAYOUT_ONLY || s->kind == S_PRECISION)
            continue;
        if (s->kind == S_DECL && (s->quals & (Q_IN | Q_OUT))) { /* attributes and outputs become plain globals */
            char type[32];
            tok_str(&tv.t[s->type_start], type, sizeof type);
            for (int k = 0; k < s->nnames; k++) {
                if (s->name_arr[k]) {
                    err = "geometry emulation: array vertex inputs/outputs not supported";
                    break;
                }
                sb_printf(&vs, "%s %s;\n", type, lookup(&rv, &tv.t[s->names[k]]));
                if (!(s->quals & Q_IN) || nattrs == 32)
                    continue;
                vs_attr *a = &attrs[nattrs++];
                snprintf(a->type, sizeof a->type, "%s", type);
                tok_str(&tv.t[s->names[k]], a->name, sizeof a->name);
                snprintf(a->renamed, sizeof a->renamed, "%s", lookup(&rv, &tv.t[s->names[k]]));
                a->location = s->nnames == 1 ? layout_int(&tv, s, "location") : -1;
                if (!type_info(type, &a->comps, &a->is_int, &a->is_uint))
                    err = "geometry emulation: unsupported vertex attribute type";
            }
            continue;
        }
        if (s->kind == S_DECL && (s->quals & Q_UNIFORM) && s->layout_start >= 0) {
            emit_uniform(&vs, &tv, s, &rv); /* drop layout(location=) on loose uniforms */
            continue;
        }
        if (s->kind == S_DECL && !(s->quals & (Q_CONST | Q_UNIFORM | Q_BUFFER | Q_SHARED)) && s->nnames > 0 &&
            split_global_init(&vs, &vinit, &tv, s, &rv))
            continue;
        emit_range(&vs, &tv, s->start, s->end, &rv);
    }
    for (int i = 0, next_loc = 0; i < nattrs; i++) /* attributes without layout(location): next free location */
        if (attrs[i].location < 0) {
            for (int used = 1; used;) {
                used = 0;
                for (int j = 0; j < nattrs; j++)
                    used |= attrs[j].location == next_loc;
                if (used)
                    next_loc++;
            }
            attrs[i].location = next_loc++;
        }
    for (int i = 0; i < nattrs && !err; i++)
        if (attrs[i].location >= 16)
            err = "geometry emulation: attribute location over 15";

    /* ---- geometry shader ---- */
    add_rename_s(&rg, "gl_in", "mgl_gin");
    add_rename_s(&rg, "gl_Position", "mgl_g_Position");
    add_rename_s(&rg, "gl_PointSize", "mgl_g_PointSize");
    add_rename_s(&rg, "gl_PrimitiveIDIn", "mgl_prim_id");
    add_rename_s(&rg, "gl_PrimitiveID", "mgl_g_PrimitiveID");
    add_rename_s(&rg, "gl_Layer", "mgl_g_Layer");
    add_rename_s(&rg, "gl_ViewportIndex", "mgl_g_ViewportIndex");
    add_rename_s(&rg, "gl_InvocationID", "mgl_invocation_id");
    add_rename_s(&rg, "EmitVertex", "mgl_emit");
    add_rename_s(&rg, "EndPrimitive", "mgl_end_primitive");
    add_rename_s(&rg, "main", "mgl_g_main");
    for (int i = 0; i < sg.n && !err; i++) {
        stmt *s = &sg.s[i];
        if (s->kind == S_PRECISION)
            continue;
        if (s->kind == S_LAYOUT_ONLY) {
            if (s->quals & Q_IN)
                tri_in = layout_has(&tg, s, "triangles");
            if (s->quals & Q_OUT) {
                strip_out = layout_has(&tg, s, "triangle_strip");
                max_vertices = layout_int(&tg, s, "max_vertices");
            }
            continue;
        }
        if (s->kind == S_DECL && (s->quals & (Q_IN | Q_OUT))) {
            for (int k = 0; k < s->nnames; k++) {
                varying *v = (s->quals & Q_IN) ? (ngin < 32 ? &gin[ngin++] : NULL) : (ngout < 32 ? &gout[ngout++] : NULL);
                if (!v) {
                    err = "geometry emulation: too many varyings";
                    break;
                }
                memset(v, 0, sizeof *v);
                tok_str(&tg.t[s->type_start], v->type, sizeof v->type);
                tok_str(&tg.t[s->names[k]], v->name, sizeof v->name);
                v->flat = (s->quals & Q_FLAT) != 0;
                v->noperspective = (s->quals & Q_NOPERSP) != 0;
                if (!type_info(v->type, &v->comps, &v->is_int, &v->is_uint)) {
                    err = "geometry emulation: unsupported varying type";
                    break;
                }
                if ((s->quals & Q_OUT) && !strncmp(v->name, "mgl_", 4)) {
                    err = "geometry emulation: outputs named mgl_* clash with the emulation's own names";
                    break;
                }
                if ((s->quals & Q_OUT) && s->name_arr[k]) {
                    err = "geometry emulation: array geometry outputs not supported";
                    break;
                }
                sb_printf(&gs, (s->quals & Q_IN) ? "%s %s[3];\n" : "%s %s;\n", v->type, v->name);
            }
            continue;
        }
        if (s->kind == S_DECL && (s->quals & Q_UNIFORM)) {
            /* the vertex shader usually declares the same uniforms: keep one copy */
            int dup = s->nnames > 0;
            for (int k = 0; k < s->nnames && dup; k++)
                dup = vs_has_uniform(&tv, &sv, &tg.t[s->names[k]], 0);
            if (!dup)
                emit_uniform(&gs, &tg, s, &rg);
            continue;
        }
        if (s->kind == S_BLOCK && (s->quals & Q_UNIFORM) && vs_has_uniform(&tv, &sv, &tg.t[s->fname], 1))
            continue;
        if (s->kind == S_BLOCK && (s->quals & (Q_IN | Q_OUT))) {
            err = "geometry emulation: interface blocks not supported";
            break;
        }
        emit_range(&gs, &tg, s->start, s->end, &rg);
    }
    if (!err && (!tri_in || !strip_out || max_vertices < 3 || max_vertices > 256))
        err = "geometry emulation: only triangles in, triangle_strip out (3..256 vertices) supported";
    if (err) {
        fail(r, err);
        goto out;
    }

    /* record floats: position, the components of each varying the fragment shader mentions (the rest are never
       stored, voff -1; MGL_GS_KEEP_ALL=1 keeps them), strip id */
    int R = 5, voff[64];
    char konst[64][96]; /* outputs only ever set to one constant (voff -2): written by the passthrough stage */
    int keep_all = !src[MGL_FRAGMENT] || (getenv("MGL_GS_KEEP_ALL") && atoi(getenv("MGL_GS_KEEP_ALL")));
    for (int i = 0; i < ngout; i++) {
        voff[i] = -1;
        if (!keep_all && !mentions(src[MGL_FRAGMENT], gout[i].name))
            continue;
        if (!keep_all && strcmp(gout[i].type, "bool") && const_output(&tg, &sg, gout[i].name, konst[i], sizeof konst[i])) {
            voff[i] = -2;
            continue;
        }
        gout[i].stored = keep_all ? gout[i].comps : fs_used_comps(src[MGL_FRAGMENT], gout[i].type, gout[i].name, gout[i].comps);
        voff[i] = R - 1;
        R += gout[i].stored;
    }

    /* ---- compute shader ---- */
    /* MGL_GS_PROBE (timing experiments only, the picture is wrong): 1 = no geometry stage (nothing emitted),
       2 = no vertex stage (attributes straight to the geometry stage), 3 = no record writes, 4 = constant attributes (no fetch),
       5 = attribute fetch only (no vertex stage), 6 = no passthrough draws (mgl_metal.m), 7 = vertex stage
       on real data with its results kept alive but no geometry stage. MGL_GS_LOCAL = threads
       per threadgroup (default 64). Both change the generated shader: run with MGL_CACHE_DIR unset. */
    int probe = getenv("MGL_GS_PROBE") ? atoi(getenv("MGL_GS_PROBE")) : 0;
    int local = getenv("MGL_GS_LOCAL") ? atoi(getenv("MGL_GS_LOCAL")) : 64;
    if (local < 2 || local > 1024 || (local & 1))
        local = 64;
    const char *prelude = strstr(compute_prelude, "\n") + 1; /* past "#version 450" */
    prelude = strstr(prelude, "\n") + 1;                     /* past the default local size */
    sb_printf(&comp, "#version 450\nlayout(local_size_x = %d) in;\n", local);
    sb_puts(&comp, prelude);
    sb_add(&comp, vs.s, vs.n);
    sb_puts(&comp, "void mgl_v_init() {\n");
    if (vinit.n)
        sb_add(&comp, vinit.s, vinit.n);
    sb_puts(&comp, "}\n");
    sb_add(&comp, gs.s, gs.n);
    if (probe == 3)
        sb_printf(&comp, "void mgl_emit() {\n  if (mgl_emitted < %du) mgl_emitted++;\n}\nvoid mgl_emit_unused() {\n"
                         "  uint mgl_rec = 0u;\n", max_vertices);
    else
    sb_printf(&comp, "void mgl_emit() {\n  if (mgl_emitted >= %du) return;\n"
                     "  uint mgl_rec = (mgl_slot * %du + mgl_emitted) * %du;\n"
                     "  mgl_ov[mgl_rec] = mgl_g_Position.x;\n  mgl_ov[mgl_rec + 1u] = mgl_g_Position.y;\n"
                     "  mgl_ov[mgl_rec + 2u] = mgl_g_Position.z;\n  mgl_ov[mgl_rec + 3u] = mgl_g_Position.w;\n",
              max_vertices, max_vertices, R);
    for (int i = 0; i < ngout; i++)
        if (voff[i] >= 0)
            pack_store(&comp, &gout[i], gout[i].name, voff[i]);
    sb_printf(&comp, "  mgl_ov[mgl_rec + %du] = uintBitsToFloat(mgl_strip);\n  mgl_emitted++;\n}\n"
                     "void mgl_end_primitive() { mgl_strip++; }\n", R - 1);
    /* one vertex-stage run: fetch the attributes of vtx, run the vertex shader, store the results as input c */
    sb_puts(&comp, "void mgl_run_vs(uint vtx, int c) {\n    mgl_vertex_id = int(vtx);\n    mgl_instance_id = 0;\n");
    for (int i = 0; i < nattrs; i++) {
        vs_attr *a = &attrs[i];
        const char *fetch = a->is_int || a->is_uint ? "mgl_fetchi" : "mgl_fetchf";
        if (probe == 4) /* constants instead of fetched attributes */
            sb_printf(&comp, "    %s = %s(%s(%s(1)));\n", a->renamed, a->type, a->is_int || a->is_uint ? "ivec4" : "vec4",
                      a->is_int || a->is_uint ? "" : "0.5 * float");
        else
            sb_printf(&comp, "    %s = %s(%s(%d, vtx)%s);\n", a->renamed, a->type, fetch, a->location, swz[a->comps]);
    }
    if (probe == 5) { /* fetch only: keep the fetched attributes alive through the position, no vertex shader */
        sb_puts(&comp, "    vec4 mgl_probe_sum = vec4(0.0);\n");
        for (int i = 0; i < nattrs; i++)
            sb_printf(&comp, "    mgl_probe_sum += vec4(%s(%d, vtx));\n", attrs[i].is_int || attrs[i].is_uint ? "mgl_fetchi" : "mgl_fetchf", attrs[i].location);
    }
    sb_puts(&comp, probe == 5 ? "    mgl_v_Position = mgl_probe_sum * 1e-6 + vec4(0.0, 0.0, 0.0, 1.0);\n    mgl_v_PointSize = 1.0;\n" :
                   probe == 2 ? "    mgl_v_Position = vec4(0.0, 0.0, 0.0, 1.0);\n    mgl_v_PointSize = 1.0;\n" : "    mgl_v_Position = vec4(0.0, 0.0, 0.0, 1.0);\n    mgl_v_PointSize = 1.0;\n    mgl_v_init();\n    mgl_v_main();\n");
    sb_puts(&comp, "    mgl_gin[c].pos = mgl_v_Position;\n    mgl_gin[c].pointSize = mgl_v_PointSize;\n");
    int fed[32] = {0};
    for (int i = 0; i < ngin; i++) { /* only inputs the vertex shader writes; the rest stay zero */
        tok t = {T_ID, gin[i].name, (int)strlen(gin[i].name)};
        const char *v = lookup(&rv, &t);
        if (v) {
            sb_printf(&comp, "    %s[c] = %s;\n", gin[i].name, v);
            fed[i] = 1;
        }
    }
    sb_puts(&comp, "}\n");
    /* probe 7: the vertex stage runs on real data and its results are kept alive, but the geometry stage doesn't run */
    sb ks = {0};
    if (probe == 7) {
        sb_puts(&ks, "  float mgl_ks = dot(mgl_gin[0].pos + mgl_gin[1].pos + mgl_gin[2].pos, vec4(1.0));\n");
        static const char *sw[4] = {".x", ".y", ".z", ".w"};
        for (int i = 0; i < ngin; i++)
            for (int j = 0; fed[i] && j < gin[i].comps && j < 4; j++) {
                const char *w = gin[i].comps == 1 ? "" : sw[j];
                sb_printf(&ks, "  mgl_ks += float(%s[0]%s + %s[1]%s + %s[2]%s);\n", gin[i].name, w, gin[i].name, w,
                          gin[i].name, w);
            }
        sb_puts(&ks, "  if (mgl_ks == 1234.5678) mgl_emitted = 1u;\n");
    }
    const char *gs_call = probe == 1 ? "" : probe == 7 ? ks.s : "  mgl_g_main();\n";
    /* MGL_GS_SHARE=0: every thread runs the vertex stage for its own three corners. Default: when two neighbouring
       triangles form a quad the way Sodium indexes them (0 1 2, 2 3 0), the pair runs the vertex stage once per
       corner, two corners per thread, and swaps the results through threadgroup memory (4 runs instead of 6). */
    int share = !getenv("MGL_GS_SHARE") || atoi(getenv("MGL_GS_SHARE")) != 0;
    int sh_bytes = 32; /* threadgroup bytes per corner: mgl_gin_t plus each fed input, at Metal's alignment */
    for (int i = 0; i < ngin; i++)
        if (fed[i])
            sh_bytes += gin[i].comps >= 3 ? 16 : gin[i].comps * 4;
    if (sh_bytes * local * 2 > 28 * 1024) /* stay well inside Apple GPUs' 32 KB */
        share = 0;
    if (!share) {
        sb_printf(&comp, "void main() {\n  uint g = gl_GlobalInvocationID.x;\n  if (g >= uint(mgl_draw_info.x)) return;\n"
                         "  uint prim = mgl_locate(g);\n  if (prim >= mgl_ntri) { mgl_oc[g] = 0u; return; }\n"
                         "  for (int c = 0; c < 3; c++)\n    mgl_run_vs(mgl_index(prim * 3u + uint(c)) + mgl_bv, c);\n"
                         "  mgl_prim_id = int(prim);\n  mgl_slot = g;\n  mgl_emitted = 0u;\n  mgl_strip = 0u;\n"
                         "%s  mgl_oc[g] = mgl_emitted;\n}\n", gs_call);
    } else {
        sb_printf(&comp, "shared mgl_gin_t mgl_gin_sh[%d];\n", local * 2);
        for (int i = 0; i < ngin; i++)
            if (fed[i])
                sb_printf(&comp, "shared %s %s_mgl_sh[%d];\n", gin[i].type, gin[i].name, local * 2);
        sb_puts(&comp, "void mgl_put_sh(uint slot, int c) {\n  mgl_gin_sh[slot] = mgl_gin[c];\n");
        for (int i = 0; i < ngin; i++)
            if (fed[i])
                sb_printf(&comp, "  %s_mgl_sh[slot] = %s[c];\n", gin[i].name, gin[i].name);
        sb_puts(&comp, "}\nvoid mgl_get_sh(uint slot, int c) {\n  mgl_gin[c] = mgl_gin_sh[slot];\n");
        for (int i = 0; i < ngin; i++)
            if (fed[i])
                sb_printf(&comp, "  %s[c] = %s_mgl_sh[slot];\n", gin[i].name, gin[i].name);
        sb_printf(&comp, "}\n"
                         "void main() {\n"
                         "  uint g = gl_GlobalInvocationID.x;\n"
                         "  uint prim = mgl_locate(min(g, uint(mgl_draw_info.x) - 1u));\n"
                         "  if (g >= uint(mgl_draw_info.x)) prim = 0xffffffffu;\n" /* past the end: no quad, then return */
                         "  uint ntri = mgl_ntri, bv = mgl_bv;\n"
                         "  uint lt = gl_LocalInvocationID.x;\n"
                         "  bool odd = (lt & 1u) != 0u;\n"
                         "  uint pa = prim & ~1u;\n" /* the pair's first triangle; local size is even, so the pair shares a group */
                         "  bool quad = prim != 0xffffffffu && pa + 1u < ntri;\n"
                         "  uint a0 = 0u, a1 = 0u, a2 = 0u, b1 = 0u;\n"
                         "  if (quad) {\n"
                         "    a0 = mgl_index(pa * 3u); a1 = mgl_index(pa * 3u + 1u); a2 = mgl_index(pa * 3u + 2u);\n"
                         "    b1 = mgl_index(pa * 3u + 4u);\n"
                         "    quad = mgl_index(pa * 3u + 3u) == a2 && mgl_index(pa * 3u + 5u) == a0;\n"
                         "  }\n"
                         "  uint s = (lt & ~1u) * 2u;\n" /* the pair's four slots: a0 a1 a2 b1 */
                         "  if (quad) {\n"
                         "    mgl_run_vs((odd ? a2 : a0) + bv, 0);\n    mgl_put_sh(s + (odd ? 2u : 0u), 0);\n"
                         "    mgl_run_vs((odd ? b1 : a1) + bv, 0);\n    mgl_put_sh(s + (odd ? 3u : 1u), 0);\n"
                         "  }\n"
                         "  barrier();\n"
                         "  if (g >= uint(mgl_draw_info.x)) return;\n"
                         "  if (prim >= ntri) { mgl_oc[g] = 0u; return; }\n"
                         "  if (quad) {\n"
                         "    mgl_get_sh(odd ? s + 2u : s, 0);\n    mgl_get_sh(odd ? s + 3u : s + 1u, 1);\n"
                         "    mgl_get_sh(odd ? s : s + 2u, 2);\n"
                         "  } else {\n"
                         "    for (int c = 0; c < 3; c++)\n      mgl_run_vs(mgl_index(prim * 3u + uint(c)) + bv, c);\n"
                         "  }\n"
                         "  mgl_prim_id = int(prim);\n  mgl_slot = g;\n  mgl_emitted = 0u;\n  mgl_strip = 0u;\n"
                         "%s  mgl_oc[g] = mgl_emitted;\n}\n", gs_call);
    }

    free(ks.s);

    /* ---- passthrough vertex shader: strip -> triangle list ---- */
    sb_puts(&pass, "#version 450\n"
                   "layout(std430, binding = 26) readonly buffer mgl_i6_ { float mgl_ov[]; };\n"
                   "layout(std430, binding = 27) readonly buffer mgl_i7_ { uint mgl_oc[]; };\n");
    for (int i = 0; i < ngout; i++)
        if (voff[i] >= 0 || voff[i] == -2)
            sb_printf(&pass, "%sout %s %s;\n",
                  gout[i].flat || gout[i].is_int || gout[i].is_uint || !strcmp(gout[i].type, "bool") ? "flat "
                  : gout[i].noperspective                                                            ? "noperspective "
                                                                                                     : "",
                  !strcmp(gout[i].type, "bool") ? "int" : gout[i].type, gout[i].name);
    /* locals are mgl_-prefixed: the outputs keep the geometry shader's names (SEUS-style packs use short ones) */
    sb_printf(&pass, "void main() {\n"
                     "  const uint mgl_M = %du, mgl_R = %du, mgl_T = mgl_M - 2u;\n"
                     "  uint mgl_v = uint(gl_VertexIndex);\n  uint mgl_prim = mgl_v / (mgl_T * 3u);\n"
                     "  uint mgl_rem = mgl_v %% (mgl_T * 3u);\n"
                     "  uint mgl_t = mgl_rem / 3u;\n  uint mgl_j = mgl_rem %% 3u;\n"
                     "  uint mgl_k = (mgl_t & 1u) != 0u ? (mgl_j == 0u ? 1u : (mgl_j == 1u ? 0u : 2u)) : mgl_j; /* keep strip winding */\n"
                     "  uint mgl_base = mgl_prim * mgl_M;\n"
                     "  bool mgl_ok = mgl_t + 2u < mgl_oc[mgl_prim] &&\n"
                     "      floatBitsToUint(mgl_ov[(mgl_base + mgl_t) * mgl_R + mgl_R - 1u]) ==\n"
                     "      floatBitsToUint(mgl_ov[(mgl_base + mgl_t + 2u) * mgl_R + mgl_R - 1u]);\n"
                     "  uint mgl_rec = (mgl_base + mgl_t + mgl_k) * mgl_R;\n"
                     "  gl_Position = mgl_ok ? vec4(mgl_ov[mgl_rec], mgl_ov[mgl_rec + 1u], mgl_ov[mgl_rec + 2u], mgl_ov[mgl_rec + 3u]) : vec4(2.0, 2.0, 2.0, 1.0);\n",
              max_vertices, R);
    sb_puts(&pass, "  if (!mgl_ok) return; /* unused slot or strip join: off-screen, its varyings never read */\n");
    for (int i = 0; i < ngout; i++) {
        if (voff[i] == -2)
            sb_printf(&pass, "  %s = %s(%s);\n", gout[i].name, gout[i].type, konst[i]);
        if (voff[i] < 0)
            continue;
        sb_printf(&pass, "  %s = ", gout[i].name);
        unpack_expr(&pass, &gout[i], voff[i]);
        sb_puts(&pass, ";\n");
    }
    sb_puts(&pass, "}\n");
    dump("comp", comp.s, r);
    dump("vert", pass.s, r);

    const char *stages[MGL_NUM_STAGES] = {pass.s, src[MGL_FRAGMENT], comp.s};
    mgl_xlate_program(stages, r);
    if (r->ok) {
        r->gs_max_vertices = max_vertices;
        r->gs_record_floats = R;
        /* the attributes Iris binds belong to the original vertex shader, now fetched by the compute stage */
        free(r->attribs);
        r->attribs = calloc((size_t)(nattrs ? nattrs : 1), sizeof *r->attribs);
        r->num_attribs = nattrs;
        for (int i = 0; i < nattrs; i++) {
            snprintf(r->attribs[i].name, sizeof r->attribs[i].name, "%s", attrs[i].name);
            r->attribs[i].location = attrs[i].location;
            r->attribs[i].vecsize = attrs[i].comps;
            r->attribs[i].is_int = attrs[i].is_uint ? 2 : attrs[i].is_int ? 1 : 0;
        }
    }
out:
    free(pv);
    free(pg);
    free(tv.t);
    free(tg.t);
    free(sv.s);
    free(sg.s);
    free(vs.s);
    free(vinit.s);
    free(gs.s);
    free(comp.s);
    free(pass.s);
    free(rv.r);
    free(rg.r);
}
