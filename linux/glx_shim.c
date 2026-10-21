/* Linux test builds only: LWJGL looks functions up through glXGetProcAddress(ARB) in the GL library it was
   given, so answer with our own exports. Lets the cloud check the plumbing without a Mac. */
#define _GNU_SOURCE
#include <dlfcn.h>

static void *self(void)
{
    static void *h;
    if (!h) {
        Dl_info info;
        dladdr((void *)self, &info);
        h = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);
    }
    return h;
}

__attribute__((visibility("default"))) void *glXGetProcAddressARB(const unsigned char *name)
{
    return dlsym(self(), (const char *)name);
}

__attribute__((visibility("default"))) void *glXGetProcAddress(const unsigned char *name)
{
    return glXGetProcAddressARB(name);
}
