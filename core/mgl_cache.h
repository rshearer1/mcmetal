/* On-disk cache of translated programs (see mgl_cache.c). Enabled by MGL_CACHE_DIR. */
#pragma once
#include "mgl_xlate.h"

int mgl_cache_key(const char *src[MGL_NUM_STAGES], const char *geometry, const mgl_frag_bind *binds, int nbinds,
                  char out[33]); /* 0 when the cache is off */
int mgl_cache_load(const char *key, mgl_xlate_result *r);   /* 1 on hit (r filled, ok = 1) */
void mgl_cache_store(const char *key, const mgl_xlate_result *r);
