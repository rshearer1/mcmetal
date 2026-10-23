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
static inline void *mgl_hc_calloc_at(const char *file, int line, size_t c, size_t n) { return mgl_hc_calloc(c, n, file, line); }
static inline void *mgl_hc_realloc_at(const char *file, int line, void *p, size_t n) { return mgl_hc_realloc(p, n, file, line); }
#ifndef MGL_HEAPCHECK_IMPL
/* variadic: an Objective-C message in the argument ([x a:b, c]) has commas the preprocessor would split on */
#define malloc(...) mgl_hc_malloc((__VA_ARGS__), __FILE__, __LINE__)
#define calloc(...) mgl_hc_calloc_at(__FILE__, __LINE__, __VA_ARGS__)
#define realloc(...) mgl_hc_realloc_at(__FILE__, __LINE__, __VA_ARGS__)
#define strdup(...) mgl_hc_strdup((__VA_ARGS__), __FILE__, __LINE__)
#define free(...) mgl_hc_free((__VA_ARGS__), __FILE__, __LINE__)
#endif
#endif
