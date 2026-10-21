#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include "mgl_log.h"

static FILE *log_file;
static pthread_once_t log_once = PTHREAD_ONCE_INIT;

static void open_log(void)
{
    const char *path = getenv("MGL_LOG");
    log_file = path ? fopen(path, "a") : NULL;
    if (!log_file)
        log_file = stderr;
    setvbuf(log_file, NULL, _IOLBF, 0);
}

void mgl_log(const char *fmt, ...)
{
    va_list ap;
    pthread_once(&log_once, open_log);
    flockfile(log_file); /* link workers log too: keep lines whole */
    fputs("[mcmetal] ", log_file);
    va_start(ap, fmt);
    vfprintf(log_file, fmt, ap);
    va_end(ap);
    fputc('\n', log_file);
    funlockfile(log_file);
}

void mgl_unimplemented(const char *name)
{
    mgl_log("unimplemented: %s", name);
}
