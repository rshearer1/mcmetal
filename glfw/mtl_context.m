//========================================================================
// mcmetal: drop-in replacement for GLFW 3.4 src/nsgl_context.m.
// Instead of an NSOpenGLContext, GLFW puts a CAMetalLayer on the content view
// and hands it to libmcmetal, which is the "OpenGL context".
// libmcmetal is found via $MCMETAL_LIB (full path to libmcmetal.dylib).
// Based on GLFW 3.4 (zlib licence, Copyright (c) 2009-2019 Camilla Löwy).
//========================================================================

#include "internal.h"

#if defined(_GLFW_COCOA)

#include <dlfcn.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdlib.h>

// GLFW's Cocoa code sends -update to context.nsgl.object in several places, so the slot must
// hold an Objective-C object. This box carries the libmcmetal context pointer.
@interface MGLContextBox : NSObject { @public void* ctx; }
@end
@implementation MGLContextBox
- (void)update {}
@end

static void* mglContext(_GLFWwindow* window)
{
    return window ? ((MGLContextBox*) window->context.nsgl.object)->ctx : NULL;
}

static void* mgl_lib;
static void* (*mgl_glfw_create)(void* metalLayer);
static void (*mgl_glfw_make_current)(void* ctx);
static void (*mgl_glfw_swap)(void* ctx);
static void (*mgl_glfw_swap_interval)(void* ctx, int interval);
static void (*mgl_glfw_destroy)(void* ctx);

static void makeContextCurrentNSGL(_GLFWwindow* window)
{
    mgl_glfw_make_current(mglContext(window));
    _glfwPlatformSetTls(&_glfw.contextSlot, window);
}

static void swapBuffersNSGL(_GLFWwindow* window)
{
    @autoreleasepool {
    mgl_glfw_swap(mglContext(window));
    }
}

static void swapIntervalNSGL(int interval)
{
    _GLFWwindow* window = _glfwPlatformGetTls(&_glfw.contextSlot);
    assert(window != NULL);
    mgl_glfw_swap_interval(mglContext(window), interval);
}

static int extensionSupportedNSGL(const char* extension)
{
    return GLFW_FALSE;
}

static GLFWglproc getProcAddressNSGL(const char* procname)
{
    return (GLFWglproc) dlsym(mgl_lib, procname);
}

static void destroyContextNSGL(_GLFWwindow* window)
{
    if (window->context.nsgl.object)
    {
        mgl_glfw_destroy(mglContext(window));
        [window->context.nsgl.object release]; // GLFW is built without ARC
    }
    window->context.nsgl.object = nil;
}

GLFWbool _glfwInitNSGL(void)
{
    if (mgl_lib)
        return GLFW_TRUE;

    const char* path = getenv("MCMETAL_LIB");
    if (!path)
    {
        _glfwInputError(GLFW_API_UNAVAILABLE, "mcmetal: MCMETAL_LIB is not set");
        return GLFW_FALSE;
    }

    mgl_lib = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!mgl_lib)
    {
        _glfwInputError(GLFW_API_UNAVAILABLE, "mcmetal: cannot load %s: %s", path, dlerror());
        return GLFW_FALSE;
    }

    mgl_glfw_create = dlsym(mgl_lib, "mgl_glfw_create");
    mgl_glfw_make_current = dlsym(mgl_lib, "mgl_glfw_make_current");
    mgl_glfw_swap = dlsym(mgl_lib, "mgl_glfw_swap");
    mgl_glfw_swap_interval = dlsym(mgl_lib, "mgl_glfw_swap_interval");
    mgl_glfw_destroy = dlsym(mgl_lib, "mgl_glfw_destroy");
    if (!mgl_glfw_create || !mgl_glfw_make_current || !mgl_glfw_swap ||
        !mgl_glfw_swap_interval || !mgl_glfw_destroy)
    {
        _glfwInputError(GLFW_API_UNAVAILABLE, "mcmetal: %s lacks the mgl_glfw_* entry points", path);
        return GLFW_FALSE;
    }

    return GLFW_TRUE;
}

void _glfwTerminateNSGL(void)
{
}

GLFWbool _glfwCreateContextNSGL(_GLFWwindow* window,
                                const _GLFWctxconfig* ctxconfig,
                                const _GLFWfbconfig* fbconfig)
{
    if (ctxconfig->client == GLFW_OPENGL_ES_API)
    {
        _glfwInputError(GLFW_API_UNAVAILABLE, "mcmetal: OpenGL ES is not supported");
        return GLFW_FALSE;
    }

    // Same layer setup as GLFW's Vulkan surface path, so GLFW keeps contentsScale up to date.
    @autoreleasepool {
    window->ns.layer = [CAMetalLayer layer];
    if (window->ns.scaleFramebuffer)
        [window->ns.layer setContentsScale:[window->ns.object backingScaleFactor]];
    [window->ns.view setLayer:window->ns.layer];
    [window->ns.view setWantsLayer:YES];
    }

    void* ctx = mgl_glfw_create((void*) window->ns.layer);
    if (!ctx)
    {
        _glfwInputError(GLFW_VERSION_UNAVAILABLE, "mcmetal: failed to create Metal context");
        return GLFW_FALSE;
    }
    MGLContextBox* box = [[MGLContextBox alloc] init];
    box->ctx = ctx;
    window->context.nsgl.object = box;

    window->context.makeCurrent = makeContextCurrentNSGL;
    window->context.swapBuffers = swapBuffersNSGL;
    window->context.swapInterval = swapIntervalNSGL;
    window->context.extensionSupported = extensionSupportedNSGL;
    window->context.getProcAddress = getProcAddressNSGL;
    window->context.destroy = destroyContextNSGL;

    return GLFW_TRUE;
}

GLFWAPI id glfwGetNSGLContext(GLFWwindow* handle)
{
    _GLFW_REQUIRE_INIT_OR_RETURN(nil);
    _glfwInputError(GLFW_NO_WINDOW_CONTEXT, "mcmetal: there is no NSOpenGLContext");
    return nil;
}

#endif // _GLFW_COCOA
