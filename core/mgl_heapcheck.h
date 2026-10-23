/* MCMETAL_HEAPCHECK=1 builds (build_mac.sh): every malloc/calloc/realloc/strdup/free in our own C and Objective-C
   goes through mgl_heapcheck.c, which puts guard bytes after each block and keeps freed blocks poisoned for a while,
   then names the file:line of a block whose guard or poison was overwritten. Force-included with -include, after the
   system headers so their declarations stay as they are. */
#ifndef MGL_HEAPCHECK_H
#define MGL_HEAPCHECK_H
#include <stdlib.h>
#include <string.h>
void *mgl_hc_malloc(size_t n, const char *file, int line);
void *mgl_hc_calloc(size_t c, size_t n, const char *file, int line);
void *mgl_hc_realloc(void *p, size_t n, const char *file, int line);
char *mgl_hc_strdup(const char *s, const char *file, int line);
void mgl_hc_free(void *p, const char *file, int line);
#ifndef MGL_HEAPCHECK_IMPL
#define malloc(n) mgl_hc_malloc((n), __FILE__, __LINE__)
#define calloc(c, n) mgl_hc_calloc((c), (n), __FILE__, __LINE__)
#define realloc(p, n) mgl_hc_realloc((p), (n), __FILE__, __LINE__)
#define strdup(s) mgl_hc_strdup((s), __FILE__, __LINE__)
#define free(p) mgl_hc_free((p), __FILE__, __LINE__)
#endif
#endif
