#!/bin/bash
# Build libmcmetal.dylib and the patched libglfw.dylib on macOS (Apple Silicon). Needs only the
# Command Line Tools (clang, git, python3) and internet on first run (gl.xml, GLFW 3.4, glslang, SPIRV-Cross).
#   bash build_mac.sh         -> build/libmcmetal.dylib, build/libglfw.dylib
set -euo pipefail
cd "$(dirname "$0")"
SRC=$(pwd)
mkdir -p build/gen build/obj
CFLAGS=(-arch arm64 -O2 -g -Wall -Wno-unused-parameter -fvisibility=hidden -mmacosx-version-min=14.0) # Metal 3.1 (texture atomics)
# MCMETAL_HEAPCHECK=1: guarded allocations in libmcmetal (core/mgl_heapcheck.h): finds our writes past a block or after free
HC=(); [ "${MCMETAL_HEAPCHECK:-}" = 1 ] && HC=(-include "$SRC/core/mgl_heapcheck.h")

# 1. Generated GL entry points
[ -f build/gl.xml ] || curl -fsSL -o build/gl.xml https://raw.githubusercontent.com/KhronosGroup/OpenGL-Registry/main/xml/gl.xml
python3 -I gen/gen_exports.py build/gl.xml build/gen 4.5
cp build/gen/mgl_gl.h build/gen/gl_stubs.c core/ 2>/dev/null || true

# 2. Shader translator libraries (first run takes a few minutes)
bash build_deps.sh build/deps
D=build/deps

# 3. libmcmetal.dylib
clang "${CFLAGS[@]}" ${HC[@]+"${HC[@]}"} -std=gnu11 -Icore -I$D/include -c core/*.c
mv ./*.o build/obj/
clang "${CFLAGS[@]}" ${HC[@]+"${HC[@]}"} -fobjc-arc -Icore -c mac/*.m
mv ./*.o build/obj/
clang -arch arm64 -dynamiclib -o build/libmcmetal.dylib build/obj/*.o $D/libspirvcross_all.a $D/libglslang_all.a -lc++ \
    -install_name @rpath/libmcmetal.dylib -framework Metal -framework MetalFX -framework QuartzCore -framework Foundation -framework AppKit
echo "libmcmetal: $(nm -gU build/libmcmetal.dylib | grep -c ' _gl') GL symbols exported"

# 3a. libmcmetal-al.dylib: OpenAL on Apple's AVAudioEngine (audio/mcm_al.m), used when MCMETAL_AUDIO_ENGINE=apple
clang "${CFLAGS[@]}" -fobjc-arc -dynamiclib audio/mcm_al.m -o build/libmcmetal-al.dylib -install_name @rpath/libmcmetal-al.dylib \
    -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework Foundation
echo "libmcmetal-al: $(nm -gU build/libmcmetal-al.dylib | grep -c ' _al') OpenAL symbols exported"
clang "${CFLAGS[@]}" -fobjc-arc tests/al_test.m -o build/al_test -Lbuild -lmcmetal-al -Wl,-rpath,@executable_path \
    -framework AVFoundation -framework Foundation

# 3b. glprof (tools/glprof.h): GL call profiler that wraps exactly the GL functions libmcmetal exports
nm -gU build/libmcmetal.dylib | grep ' _gl' > build/gen/mcmetal-gl-names.txt
python3 -I gen/gen_glprof.py build/gl.xml build/gen/glprof_gen.c build/gen/mcmetal-gl-names.txt
clang "${CFLAGS[@]}" -std=gnu11 -Icore -Itools -dynamiclib -o build/libglprof-mcmetal.dylib tools/glprof.c build/gen/glprof_gen.c \
    -install_name @rpath/libglprof-mcmetal.dylib

# 4. Patched GLFW 3.4 (nsgl_context.m replaced by glfw/mtl_context.m)
if [ ! -d build/glfw-3.4 ]; then
    curl -fsSL -o build/glfw-3.4.zip https://github.com/glfw/glfw/releases/download/3.4/glfw-3.4.zip
    (cd build && unzip -q glfw-3.4.zip)
fi
G=build/glfw-3.4/src
cp glfw/mtl_context.m $G/nsgl_context.m
# MCMETAL_BACKGROUND=behind|front (test runs): the game never takes focus or the Dock; "behind" also opens the
# window behind other windows. Patched in once; the markers keep it idempotent.
grep -q MCMETAL_BACKGROUND $G/cocoa_window.m || python3 - "$G" <<'PY'
import sys
g = sys.argv[1]
w = open(g + "/cocoa_window.m").read()
w = w.replace("    [window->ns.object orderFront:nil];\n",
              "    const char* bg = getenv(\"MCMETAL_BACKGROUND\");\n"
              "    if (bg && !strcmp(bg, \"behind\")) [window->ns.object orderBack:nil];\n"
              "    else [window->ns.object orderFront:nil];\n", 1)
w = w.replace("    [NSApp activateIgnoringOtherApps:YES];\n    [window->ns.object makeKeyAndOrderFront:nil];\n",
              "    if (getenv(\"MCMETAL_BACKGROUND\")) return; // test runs: never steal focus\n"
              "    [NSApp activateIgnoringOtherApps:YES];\n    [window->ns.object makeKeyAndOrderFront:nil];\n", 1)
open(g + "/cocoa_window.m", "w").write(w)
i = open(g + "/cocoa_init.m").read()
i = i.replace("        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];\n",
              "        [NSApp setActivationPolicy:getenv(\"MCMETAL_BACKGROUND\") ? NSApplicationActivationPolicyAccessory\n"
              "                                                                : NSApplicationActivationPolicyRegular];\n"
              "    if (getenv(\"MCMETAL_BACKGROUND\")) // no App Nap throttling while in the background\n"
              "        [[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical\n"
              "                                                       reason:@\"mcmetal test run\"] retain];\n", 1)
open(g + "/cocoa_init.m", "w").write(i)
PY
# MCMETAL_RETINA=0: on a Retina screen the game renders at the window's point size instead of 2x
# and the layer scales it up, about 4x fewer pixels for heavy shader packs.
grep -q MCMETAL_RETINA $G/cocoa_window.m || python3 - "$G" <<'PY'
import sys
g = sys.argv[1]
w = open(g + "/cocoa_window.m").read()
w = w.replace("[window->ns.view convertRectToBacking:contentRect]",
              "(window->ns.scaleFramebuffer ? [window->ns.view convertRectToBacking:contentRect] : contentRect)")
w = w.replace("    window->ns.scaleFramebuffer = wndconfig->scaleFramebuffer;\n",
              "    window->ns.scaleFramebuffer = wndconfig->scaleFramebuffer;\n"
              "    const char* retina = getenv(\"MCMETAL_RETINA\");\n"
              "    if (retina && !strcmp(retina, \"0\")) window->ns.scaleFramebuffer = GLFW_FALSE;\n", 1)
open(g + "/cocoa_window.m", "w").write(w)
PY
# MCMETAL_UPSCALE + MCMETAL_UPSCALE_SCALE=N: the framebuffer GLFW reports is N% of the Retina size each way
# (default 50 = the point size), matching what libmcmetal renders (update_size in mac/mgl_metal.m).
grep -q MCMETAL_UPSCALE_SCALE $G/cocoa_window.m || python3 - "$G" <<'PY'
import sys
g = sys.argv[1]
w = open(g + "/cocoa_window.m").read()
w = w.replace(": contentRect)", ": mcmetalFramebufferRect(window, contentRect))")
w = w.replace("#include <string.h>\n",
              "#include <string.h>\n#include <stdlib.h>\n#include <math.h>\n\n"
              "static NSRect mcmetalFramebufferRect(_GLFWwindow* window, NSRect r)\n"
              "{\n"
              "    const char* up = getenv(\"MCMETAL_UPSCALE\");\n"
              "    if (!up || atoi(up) <= 0) return r;\n"
              "    const char* e = getenv(\"MCMETAL_UPSCALE_SCALE\");\n"
              "    int pct = e ? atoi(e) : 50;\n"
              "    pct = pct < 34 ? 34 : pct > 100 ? 100 : pct;\n"
              "    const double s = [window->ns.object backingScaleFactor];\n"
              "    if (s <= 1) return r; // no Retina: no upscaler (libmcmetal does the same)\n"
              "    r.size.width = floor(r.size.width * s * pct / 100.0);\n"
              "    r.size.height = floor(r.size.height * s * pct / 100.0);\n"
              "    return r;\n"
              "}\n", 1)
open(g + "/cocoa_window.m", "w").write(w)
PY
GLFW_SRC=(context.c init.c input.c monitor.c platform.c vulkan.c window.c egl_context.c osmesa_context.c
          null_init.c null_monitor.c null_window.c null_joystick.c cocoa_time.c posix_module.c posix_thread.c
          cocoa_init.m cocoa_joystick.m cocoa_monitor.m cocoa_window.m nsgl_context.m)
rm -rf build/glfwobj && mkdir build/glfwobj
for f in "${GLFW_SRC[@]}"; do
    clang -arch arm64 -O2 -mmacosx-version-min=13.0 -D_GLFW_COCOA -D_GLFW_BUILD_DLL -fvisibility=hidden \
        -Wno-deprecated-declarations -I$G -Ibuild/glfw-3.4/include -c "$G/$f" -o "build/glfwobj/${f%.*}.o"
done
clang -arch arm64 -dynamiclib -o build/libglfw.dylib build/glfwobj/*.o -install_name @rpath/libglfw.dylib \
    -framework Cocoa -framework IOKit -framework CoreFoundation -framework QuartzCore
echo "libglfw: $(nm -gU build/libglfw.dylib | grep -c ' _glfw') GLFW symbols exported"
# 5. Headless smoke test (no window, no Minecraft): build/gl_smoke draws a few things and checks the pixels
clang "${CFLAGS[@]}" -std=gnu11 -Icore tests/gl_smoke.c -o build/gl_smoke -Lbuild -lmcmetal -Wl,-rpath,@executable_path
echo "built: $SRC/build/libmcmetal.dylib $SRC/build/libglfw.dylib $SRC/build/gl_smoke"
