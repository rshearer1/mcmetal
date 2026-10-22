#!/bin/bash
# Cloud/Linux test build: GL front end + null backend, so Minecraft can run on the front end without a GPU.
# Needs: gcc, python3, glslang-dev, libspirv-cross-c-shared-dev.   bash build_linux.sh -> build-linux/libmcmetal.so
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build-linux/gen
[ -f build-linux/gl.xml ] || curl -fsSL -o build-linux/gl.xml https://raw.githubusercontent.com/KhronosGroup/OpenGL-Registry/main/xml/gl.xml
python3 -I gen/gen_exports.py build-linux/gl.xml build-linux/gen 4.5
cp build-linux/gen/mgl_gl.h build-linux/gen/gl_stubs.c core/
gcc -std=gnu11 -O1 -g -Wall -Wno-unused-parameter -fPIC -shared -fvisibility=hidden -Icore \
    core/*.c linux/*.c -o build-linux/libmcmetal.so \
    -Wl,--whole-archive -lglslang -lglslang-default-resource-limits -lSPIRV -Wl,--no-whole-archive \
    -lSPIRV-Tools-opt -lSPIRV-Tools -lspirv-cross-c-shared -lstdc++ -lpthread -lm -ldl
echo "built build-linux/libmcmetal.so: $(nm -D --defined-only build-linux/libmcmetal.so | grep -c ' gl') GL symbols"
# GL call profiler for the Mesa reference rig (tools/glprof.h): -Dorg.lwjgl.opengl.libname=build-linux/libglprof.so
python3 -I gen/gen_glprof.py build-linux/gl.xml build-linux/gen/glprof_gen.c
gcc -std=gnu11 -O2 -Wall -Wno-unused-parameter -fPIC -shared -fvisibility=hidden -Icore -Itools tools/glprof.c \
    build-linux/gen/glprof_gen.c -o build-linux/libglprof.so -ldl
