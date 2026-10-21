#!/bin/bash
# Build the shader translator's two libraries from source with plain clang++ (no CMake):
#   glslang 15.1.0 (GLSL -> SPIR-V) and SPIRV-Cross vulkan-sdk-1.4.304.0 (SPIR-V -> MSL).
# Works on macOS (Command Line Tools only) and Linux. Needs git and python3.
#   bash build_deps.sh <outdir>   -> <outdir>/libglslang_all.a, <outdir>/libspirvcross_all.a, <outdir>/include
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-build/deps}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SRCDIR=$OUT/src
mkdir -p "$SRCDIR"
[ -d "$SRCDIR/glslang" ] || git clone -q --depth 1 --branch 15.1.0 https://github.com/KhronosGroup/glslang.git "$SRCDIR/glslang"
[ -d "$SRCDIR/SPIRV-Cross" ] || git clone -q --depth 1 --branch vulkan-sdk-1.4.304.0 https://github.com/KhronosGroup/SPIRV-Cross.git "$SRCDIR/SPIRV-Cross"

CXX=${CXX:-clang++}
CXXFLAGS=(-std=c++17 -O2 -fPIC -fvisibility=hidden -w)
if [ "$(uname)" = Darwin ]; then CXXFLAGS+=(-arch arm64 -mmacosx-version-min=13.0); fi
JOBS=$( (sysctl -n hw.ncpu 2>/dev/null || nproc) )

compile_all() { # objdir, flags..., -- files...
    local objdir=$1; shift
    local flags=()
    while [ "$1" != "--" ]; do flags+=("$1"); shift; done; shift
    mkdir -p "$objdir"
    printf '%s\n' "$@" | xargs -P "$JOBS" -I{} sh -c 'd=$0; f=$1; shift; o="$d/$(echo "$f" | tr / _).o"; [ "$o" -nt "$f" ] || '"$CXX"' "$@" -c "$f" -o "$o"' "$objdir" {} "${CXXFLAGS[@]}" "${flags[@]}"
}

# ---- glslang
G=$SRCDIR/glslang
mkdir -p "$OUT/include/glslang"
python3 -I "$G/build_info.py" "$G" -i "$G/build_info.h.tmpl" -o "$OUT/include/glslang/build_info.h"
GFILES=()
while IFS= read -r f; do GFILES+=("$f"); done < <(cd "$G" && find glslang/MachineIndependent glslang/GenericCodeGen glslang/OSDependent/Unix \
    glslang/CInterface glslang/ResourceLimits SPIRV -name '*.cpp' ! -name SpvTools.cpp | sort)
(cd "$G" && compile_all "$OUT/obj-glslang" -I. -I"$OUT/include" -DENABLE_SPIRV=1 -- "${GFILES[@]}")
rm -f "$OUT/libglslang_all.a"
ar rcs "$OUT/libglslang_all.a" "$OUT"/obj-glslang/*.o

# ---- SPIRV-Cross (core + GLSL + MSL backends, C API)
S=$SRCDIR/SPIRV-Cross
SFILES=(spirv_cfg.cpp spirv_cross.cpp spirv_cross_c.cpp spirv_cross_parsed_ir.cpp spirv_cross_util.cpp spirv_glsl.cpp
        spirv_msl.cpp spirv_parser.cpp)
(cd "$S" && compile_all "$OUT/obj-spvc" -I. -DSPIRV_CROSS_C_API_GLSL=1 -DSPIRV_CROSS_C_API_MSL=1 -- "${SFILES[@]}")
rm -f "$OUT/libspirvcross_all.a"
ar rcs "$OUT/libspirvcross_all.a" "$OUT"/obj-spvc/*.o

# headers in the layout mgl_xlate.c includes
mkdir -p "$OUT/include/glslang/Include" "$OUT/include/glslang/Public" "$OUT/include/spirv_cross"
cp "$G"/glslang/Include/*.h "$OUT/include/glslang/Include/"
cp "$G"/glslang/Public/*.h "$OUT/include/glslang/Public/"
cp "$S"/spirv_cross_c.h "$S"/spirv.h "$OUT/include/spirv_cross/"
echo "deps built in $OUT"
