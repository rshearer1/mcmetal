#!/bin/bash
# Runs real Minecraft 1.21.1 + NeoForge + Sodium + Iris on mcmetal and saves timed screenshots (MGL_SHOT_DIR).
#   bash tests/game/ci_game.sh WORK OUT [phases...]   phases: title world complementary (default: all three)
# WORK holds the game install (cacheable), OUT gets screenshots and logs. Needs Java 21 as `java` or $JAVA.
set -uo pipefail
SRC=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$1" "$2"
WORK=$(cd "$1" && pwd); OUT=$(cd "$2" && pwd); shift 2  # absolute: the game runs in WORK/game
PHASES=${*:-title world complementary}
JAVA=${JAVA:-java}
mkdir -p "$WORK" "$OUT"
python3 -I "$SRC/tools/bare_mc.py" setup "$WORK" --java "$JAVA" > "$OUT/setup.log" 2>&1 || { tail -20 "$OUT/setup.log"; exit 1; }
G=$WORK/game
mkdir -p "$G/config" "$G/saves"
cp "$SRC/tests/game/options.txt" "$G/options.txt"
rm -rf "$G/saves/metal" && tar xzf "$SRC/tests/game/world-metal.tgz" -C "$G/saves"

run_phase() { # name seconds world shaders [VAR=value ...]: extra env for this phase
    local name=$1 secs=$2 world=$3 shaders=$4; shift 4
    printf 'enableShaders=%s\nshaderPack=ComplementaryReimagined_r5.9.3.zip\ncolorSpace=SRGB\ndisableUpdateMessage=true\n' \
        "$shaders" > "$G/config/iris.properties"
    mkdir -p "$OUT/$name"
    local wargs=(--xmx 3G)
    [ -n "$world" ] && wargs+=(--world "$world")
    mkdir -p "$OUT/$name/glsl"
    echo "=== phase $name: ${secs}s, world=${world:-none}, shaders=$shaders"
    MGL_LOG="$OUT/$name/mgl.log" MGL_SHOT_DIR="$OUT/$name" MGL_SHOT_EVERY=${MGL_SHOT_EVERY:-15} \
    MGL_CACHE_DIR="$WORK/cache" MGL_DUMP_DIR="$OUT/$name/glsl" env "$@" \
        python3 -I "$SRC/tools/bare_mc.py" launch "$WORK" --java "$JAVA" "${wargs[@]}" \
        --gl "$SRC/build/libmcmetal.dylib" --glfw "$SRC/build/libglfw.dylib" > "$OUT/$name/launch.out" 2>&1 &
    local t=0
    while [ $t -lt "$secs" ]; do
        sleep 5; t=$((t + 5))
        pid=$(cat "$WORK/client.pid" 2>/dev/null)
        if [ $t -gt 20 ] && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then echo "game exited after ${t}s"; break; fi
    done
    pid=$(cat "$WORK/client.pid" 2>/dev/null); [ -n "$pid" ] && kill "$pid" 2>/dev/null; sleep 5
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    cp "$WORK/client.log" "$OUT/$name/client.log" 2>/dev/null
    cp "$G/logs/latest.log" "$OUT/$name/latest.log" 2>/dev/null
    ls "$G"/hs_err_pid*.log >/dev/null 2>&1 && mv "$G"/hs_err_pid*.log "$OUT/$name/"
    ls -d "$G"/crash-reports/* >/dev/null 2>&1 && cp -r "$G/crash-reports" "$OUT/$name/"
    echo "screenshots: $(ls "$OUT/$name"/shot-*.png 2>/dev/null | wc -l)"
    grep -E "GPU fault|validation|failed" "$OUT/$name/client.log" 2>/dev/null | head -10 | cut -c1-300
    grep -vE "^\s*$" "$OUT/$name/mgl.log" 2>/dev/null | sort | uniq -c | sort -rn | head -15 | cut -c1-220
    grep -E "joined the game|ERROR|Exception" "$OUT/$name/latest.log" 2>/dev/null | grep -viE "sound|openal" | head -8 | cut -c1-220
}

for p in $PHASES; do
    case $p in
    title) run_phase title 150 "" false MGL_DEBUG_DRAWS=1 MTL_DEBUG_LAYER=1 ;;
    world) run_phase world 240 metal false MGL_DEBUG_DRAWS=1 ;;
    complementary) run_phase complementary 300 metal true ;;
    esac
done
