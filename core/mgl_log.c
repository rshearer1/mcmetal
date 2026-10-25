#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <dlfcn.h>
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

/* Without jni.h (the Mac build has no JDK): the JNI function tables are fixed by the spec, so call through them by
   index. JavaVM: GetEnv 6. JNIEnv: FindClass 6, ExceptionClear 17, GetStaticMethodID 113, CallStaticVoidMethodA 143. */
typedef void *(**jvm_t);
typedef void *(**jenv_t);
void mgl_java_stack(void)
{
    int (*created)(jvm_t *, int, int *) = (int (*)(jvm_t *, int, int *))dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
    jvm_t vm = NULL;
    int n = 0;
    if (!created || created(&vm, 1, &n) != 0 || n < 1 || !vm) {
        mgl_log("(no Java VM found for a stack)");
        return;
    }
    jenv_t env = NULL;
    int (*get_env)(jvm_t, void **, int) = (int (*)(jvm_t, void **, int))(*vm)[6];
    if (get_env(vm, (void **)&env, 0x00010008 /* JNI 1.8 */) != 0 || !env) {
        mgl_log("(this thread isn't a Java thread)");
        return;
    }
    void *(*find_class)(jenv_t, const char *) = (void *(*)(jenv_t, const char *))(*env)[6];
    void (*exc_clear)(jenv_t) = (void (*)(jenv_t))(*env)[17];
    void *(*static_method)(jenv_t, void *, const char *, const char *) =
        (void *(*)(jenv_t, void *, const char *, const char *))(*env)[113];
    void (*call_static_void)(jenv_t, void *, void *, const void *) =
        (void (*)(jenv_t, void *, void *, const void *))(*env)[143];
    void *thread = find_class(env, "java/lang/Thread");
    void *dump = thread ? static_method(env, thread, "dumpStack", "()V") : NULL;
    if (dump)
        call_static_void(env, thread, dump, NULL);
    exc_clear(env);
}
