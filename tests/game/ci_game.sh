#!/bin/bash
# Runs real Minecraft 1.21.1 + NeoForge + Sodium + Iris on mcmetal and saves timed screenshots (MGL_SHOT_DIR).
#   bash tests/game/ci_game.sh WORK OUT [phases...]   phases: title world complementary water water-shaders night night-act showcase showcase-rain (default: the first three)
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
# GAME_BENCH=true: frame-rate runs. No vsync or frame cap, 12 chunks, Minecraft's fps logged every 5 s by the mod
# (also on Apple's OpenGL: GAME_ENV=MCMETAL_DISABLE=1), full phase length, window GAME_SIZE (default 1920x1200)
if [ "${GAME_BENCH:-}" = true ]; then
    sed -i.bak 's/^enableVsync:.*/enableVsync:false/; s/^maxFps:.*/maxFps:260/; s/^renderDistance:.*/renderDistance:12/' "$G/options.txt"
    export MCMETAL_FPS_LOG=1 GAME_LONG=true
fi
rm -rf "$G/saves/metal" && tar xzf "$SRC/tests/game/world-metal.tgz" -C "$G/saves"
# The game loads mcmetal the way players will: through the mod jar in mods/, no JVM arguments.
# GAME_JVM_ARGS=true uses the old -Dorg.lwjgl.*.libname route instead.
rm -f "$G/mods/mcmetal.jar"
if [ "${GAME_JVM_ARGS:-}" = true ]; then
    LIBARGS=(--gl "$SRC/build/libmcmetal.dylib" --glfw "$SRC/build/libglfw.dylib")
else
    bash "$SRC/mod/build_mod.sh" "$WORK/mc/libraries" "$G/mods/mcmetal.jar" "$SRC/build" || exit 1
    LIBARGS=()
fi

shots_in_world() { # screenshots taken after the first frame that drew terrain (any frame for the title screen)
    awk -v title="$2" '/presented frame/ && (title || !/\(0 terrain/) {on=1} on && /screenshot/ {n++} END {print n+0}' "$1" 2>/dev/null
}

run_phase() { # name seconds world shaders [VAR=value ...]: extra env for this phase
    local name=$1 secs=$2 world=$3 shaders=$4; shift 4
    # by default a phase ends once it has GAME_SHOTS screenshots of the loaded world; GAME_LONG=true plays the
    # full time (soak test: frame counts, leaks, late GPU faults)
    local want=${GAME_SHOTS:-4} title=0
    [ -z "$world" ] && { want=2; title=1; }
    printf 'enableShaders=%s\nshaderPack=ComplementaryReimagined_r5.9.3.zip\ncolorSpace=SRGB\ndisableUpdateMessage=true\n' \
        "$shaders" > "$G/config/iris.properties"
    mkdir -p "$OUT/$name"
    local wargs=(--xmx 3G --size "${GAME_SIZE:-$([ "${GAME_BENCH:-}" = true ] && echo 1920x1200 || echo 1280x720)}")
    [ -n "$world" ] && wargs+=(--world "$world")
    mkdir -p "$OUT/$name/glsl"
    echo "=== phase $name: ${secs}s, world=${world:-none}, shaders=$shaders"
    MGL_LOG="$OUT/$name/mgl.log" MGL_SHOT_DIR="$OUT/$name" MGL_SHOT_EVERY=${MGL_SHOT_EVERY:-10} \
    MGL_CACHE_DIR="$WORK/cache" MGL_DUMP_DIR="$OUT/$name/glsl" env ${GAME_ENV:-} "$@" \
        python3 -I "$SRC/tools/bare_mc.py" launch "$WORK" --java "$JAVA" "${wargs[@]}" \
        ${LIBARGS[@]+"${LIBARGS[@]}"} > "$OUT/$name/launch.out" 2>&1 &
    local t=0
    while [ $t -lt "$secs" ]; do
        sleep 5; t=$((t + 5))
        pid=$(cat "$WORK/client.pid" 2>/dev/null)
        if [ $t -gt 20 ] && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then echo "game exited after ${t}s"; break; fi
        if [ "${GAME_LONG:-}" != true ] && [ "$(shots_in_world "$OUT/$name/mgl.log" $title)" -ge "$want" ]; then
            echo "got $want screenshots in the world after ${t}s"; break
        fi
    done
    pid=$(cat "$WORK/client.pid" 2>/dev/null); [ -n "$pid" ] && kill "$pid" 2>/dev/null; sleep 5
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    cp "$WORK/client.log" "$OUT/$name/client.log" 2>/dev/null
    # mcmetal clears the mod's start marker once real screens are drawn; left behind, the next launch would
    # fall back to Apple's OpenGL, so report it and clear it for the next phase
    [ -e "$G/mcmetal/starting" ] && { echo "WARNING: start marker not cleared (mcmetal never drew a full screen)"; rm -f "$G/mcmetal/starting"; }
    grep -q 'last launch on Metal did not' "$OUT/$name/client.log" 2>/dev/null && echo "WARNING: this phase ran on Apple's OpenGL (fallback)"
    grep -h '\[mcmetal\]' "$OUT/$name/client.log" 2>/dev/null | grep -v 'presented frame\|screenshot\|\] fps ' | head -5
    # fps: Minecraft's counter every 5 s (bench mode); the summary skips the first minute of loading
    local fps; fps=$(grep -ho '\] fps [0-9]*' "$OUT/$name/client.log" 2>/dev/null | awk '{print $3}')
    [ -n "$fps" ] && echo "fps $name: $(echo "$fps" | tail -n +13 | sort -n | awk '{a[NR]=$1; s+=$1} END {if (NR) printf "median %d, mean %.0f, low %d, high %d over %d samples", a[int((NR+1)/2)], s/NR, a[1], a[NR], NR}')" | tee -a "$OUT/fps.txt"
    cp "$G/logs/latest.log" "$OUT/$name/latest.log" 2>/dev/null
    ls "$G"/hs_err_pid*.log >/dev/null 2>&1 && mv "$G"/hs_err_pid*.log "$OUT/$name/"
    ls -d "$G"/crash-reports/* >/dev/null 2>&1 && cp -r "$G/crash-reports" "$OUT/$name/"
    echo "screenshots: $(ls "$OUT/$name"/shot-*.png 2>/dev/null | wc -l)"
    grep -E "GPU fault|debug:|validation|failed" "$OUT/$name/client.log" 2>/dev/null | head -10 | cut -c1-300
    grep -vE "^\s*$" "$OUT/$name/mgl.log" 2>/dev/null | sort | uniq -c | sort -rn | head -15 | cut -c1-220
    grep -E "joined the game|ERROR|Exception" "$OUT/$name/latest.log" 2>/dev/null | grep -viE "sound|openal" | head -8 | cut -c1-220
}

scene() { # time [weather [stage]]: copy the test datapack into the world; it builds STAGE (default: scene, the
          # pool with lights; showcase: the feature gallery) next to the player at this time of day and weather
    rm -rf "$G/saves/metal/datapacks/mcm-scene"; mkdir -p "$G/saves/metal/datapacks"
    cp -r "$SRC/tests/game/scene" "$G/saves/metal/datapacks/mcm-scene"
    local f="$G/saves/metal/datapacks/mcm-scene/data/mcm/function"
    printf 'time set %s\nweather %s 100000\n' "$1" "${2:-clear}" > "$f/time.mcfunction"
    echo "function mcm:${3:-scene}" > "$f/build.mcfunction"
}

act() { # on|off|showcase: Complementary's options. ACT ships off; "on" = 128, the size the inventory was taken at;
        # "showcase" = everything Iris's Mac flag used to lock away, at high settings
    local f="$G/shaderpacks/ComplementaryReimagined_r5.9.3.zip.txt"
    case $1 in
    on) echo "COLORED_LIGHTING=128" > "$f" ;;
    showcase) printf 'COLORED_LIGHTING=256\nWORLD_SPACE_REFLECTIONS=1\nRAIN_PUDDLES=1\nDETAIL_QUALITY=3\n' > "$f" ;;
    *) rm -f "$f" ;;
    esac
}

for p in $PHASES; do
    act off
    case $p in
    title) run_phase title 60 "" false ;;
    world) run_phase world 180 metal false
        # replay Sodium's own cutout shaders (dumped by this run) in the headless terrain tests
        fsh=$(grep -l "define USE_FRAGMENT_DISCARD" "$OUT/world/glsl/"*.fsh 2>/dev/null | head -1)
        if [ -n "$fsh" ] && [ -x "$SRC/build/gl_smoke" ]; then
            "$SRC/build/gl_smoke" "${fsh%.fsh}.vsh" "$fsh" > "$OUT/world/replay-sodium-cutout.txt" 2>&1
            grep -E "use|FAIL|cutout|replayed|failed" "$OUT/world/replay-sodium-cutout.txt"
        fi ;;
    complementary) run_phase complementary 300 metal true ;;
    water) scene noon; run_phase water 150 metal false ;;                  # Sodium water, glass, waterfall
    water-shaders) scene noon; run_phase water-shaders 240 metal true ;;  # Complementary water + reflections
    night) scene midnight; run_phase night 240 metal true ;;             # Complementary at night, ACT off (as shipped)
    night-act) scene midnight; act on; run_phase night-act 240 metal true ;;  # ACT coloured light (voxel images from vertex shaders)
    showcase) scene midnight clear showcase; act showcase; run_phase showcase 240 metal true ;;     # feature gallery
    showcase-rain) scene 13800 rain showcase; act showcase; run_phase showcase-rain 240 metal true ;;  # + improved rain, puddles
    esac
done
