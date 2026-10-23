/* Guarded allocations for MCMETAL_HEAPCHECK=1 builds (see mgl_heapcheck.h). Each block: a header (magic, size, where it
   was allocated, list links), the caller's bytes, then 32 guard bytes. Freed blocks are filled with a pattern and kept
   in a quarantine of 4096 blocks; a write after free shows when one leaves it. Every 20 ms (and at each free) the live
   blocks' guards are checked. A damaged block is logged with its allocation site, then the process aborts, so the
   crash report is near the bad write instead of in the JVM much later. Pointers we didn't allocate (from libraries)
   go to the real free(). Compiled into every build; only used when the header is force-included. */
#define MGL_HEAPCHECK_IMPL
#include "mgl_heapcheck.h"
#undef malloc /* the build force-includes the header here too: this file uses the real ones */
#undef calloc
#undef realloc
#undef strdup
#undef free
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include "mgl_log.h"

#define HC_MAGIC 0x6d676c68636b3031ull /* "mglhck01" */
#define HC_DEAD 0x6d676c6866726565ull  /* "mglhfree" */
#define HC_GUARD 32
#define HC_QUARANTINE 4096

typedef struct hc_block {
    uint64_t magic;
    size_t size;
    const char *file;
    int line;
    struct hc_block *prev, *next;
    uint64_t pad; /* header is 48 bytes: the caller's bytes stay 16-byte aligned */
} hc_block;

static pthread_mutex_t hc_lock = PTHREAD_MUTEX_INITIALIZER;
static hc_block *live;
static hc_block *quarantine[HC_QUARANTINE];
static unsigned q_next;
static double last_sweep;

static unsigned char *user(hc_block *b) { return (unsigned char *)(b + 1); }

static void report(hc_block *b, const char *what, size_t at)
{
    mgl_log("HEAPCHECK: %s at byte %zu of a %zu-byte block allocated at %s:%d", what, at, b->size, b->file, b->line);
    fprintf(stderr, "[mcmetal] HEAPCHECK: %s at byte %zu of a %zu-byte block allocated at %s:%d\n", what, at, b->size,
            b->file, b->line);
    abort();
}

static void check_guard(hc_block *b)
{
    const unsigned char *g = user(b) + b->size;
    for (int i = 0; i < HC_GUARD; i++)
        if (g[i] != 0xFD)
            report(b, "write past the end", b->size + (size_t)i);
}

static void check_dead(hc_block *b)
{
    if (b->magic != HC_DEAD)
        report(b, "freed block's header overwritten", 0);
    const unsigned char *u = user(b);
    for (size_t i = 0; i < b->size + HC_GUARD; i++)
        if (u[i] != 0xDD)
            report(b, "write after free", i);
}

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec * 1e-6;
}

static void sweep_locked(void)
{
    for (hc_block *b = live; b; b = b->next) {
        if (b->magic != HC_MAGIC)
            report(b, "block header overwritten", 0);
        check_guard(b);
    }
    for (int i = 0; i < HC_QUARANTINE; i++)
        if (quarantine[i])
            check_dead(quarantine[i]);
}

static void maybe_sweep_locked(void)
{
    double t = now_ms();
    if (t - last_sweep >= 20.0) {
        last_sweep = t;
        sweep_locked();
    }
}

void *mgl_hc_malloc(size_t n, const char *file, int line)
{
    hc_block *b = malloc(sizeof *b + n + HC_GUARD);
    if (!b)
        return NULL;
    b->magic = HC_MAGIC;
    b->size = n;
    b->file = file;
    b->line = line;
    memset(user(b) + n, 0xFD, HC_GUARD);
    pthread_mutex_lock(&hc_lock);
    b->prev = NULL;
    b->next = live;
    if (live)
        live->prev = b;
    live = b;
    maybe_sweep_locked();
    pthread_mutex_unlock(&hc_lock);
    return user(b);
}

void *mgl_hc_calloc(size_t c, size_t n, const char *file, int line)
{
    if (n && c > (size_t)-1 / n)
        return NULL;
    void *p = mgl_hc_malloc(c * n, file, line);
    if (p)
        memset(p, 0, c * n);
    return p;
}

static hc_block *ours(void *p)
{
    if (!p)
        return NULL;
    hc_block *b = (hc_block *)p - 1;
    return b->magic == HC_MAGIC ? b : NULL;
}

void mgl_hc_free(void *p, const char *file, int line)
{
    if (!p)
        return;
    hc_block *b = ours(p);
    if (!b) {
        if (((hc_block *)p - 1)->magic == HC_DEAD) {
            mgl_log("HEAPCHECK: double free at %s:%d of a block allocated at %s:%d", file, line,
                    ((hc_block *)p - 1)->file, ((hc_block *)p - 1)->line);
            abort();
        }
        free(p); /* a library's allocation */
        return;
    }
    pthread_mutex_lock(&hc_lock);
    check_guard(b);
    if (b->prev)
        b->prev->next = b->next;
    else
        live = b->next;
    if (b->next)
        b->next->prev = b->prev;
    b->magic = HC_DEAD;
    memset(user(b), 0xDD, b->size + HC_GUARD);
    hc_block *old = quarantine[q_next];
    quarantine[q_next] = b;
    q_next = (q_next + 1) % HC_QUARANTINE;
    if (old)
        check_dead(old);
    maybe_sweep_locked();
    pthread_mutex_unlock(&hc_lock);
    if (old)
        free(old);
}

void *mgl_hc_realloc(void *p, size_t n, const char *file, int line)
{
    if (!p)
        return mgl_hc_malloc(n, file, line);
    hc_block *b = ours(p);
    if (!b)
        return realloc(p, n); /* a library's allocation */
    void *q = mgl_hc_malloc(n, file, line);
    if (!q)
        return NULL;
    memcpy(q, p, b->size < n ? b->size : n);
    mgl_hc_free(p, file, line);
    return q;
}

char *mgl_hc_strdup(const char *s, const char *file, int line)
{
    size_t n = strlen(s) + 1;
    char *p = mgl_hc_malloc(n, file, line);
    if (p)
        memcpy(p, s, n);
    return p;
}
