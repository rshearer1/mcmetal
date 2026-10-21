#!/bin/bash
# Runs real Minecraft 1.21.1 + NeoForge + Sodium + Iris on mcmetal and saves timed screenshots (MGL_SHOT_DIR).
#   bash tests/game/ci_game.sh WORK OUT [phases...]   phases: title world complementary water water-shaders night night-act showcase showcase-mac showcase-plain world-f3 rt-demo showcase-rain
#   pack-NAME packnight-NAME (third-party packs, see PACKS below) (default: the first three)
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
# GAME_BENCH=true: frame-rate runs. No vsync or frame cap, 12 chunks, Minecraft's fps logged every second by the mod
# (also on Apple's OpenGL: GAME_ENV=MCMETAL_DISABLE=1), window GAME_SIZE (default 1920x1200). Once the world is on
# screen it settles for GAME_BENCH_SETTLE s (default 10), then measures GAME_BENCH_SECS s (default 30) and stops
if [ "${GAME_BENCH:-}" = true ]; then
    sed -i.bak 's/^enableVsync:.*/enableVsync:false/; s/^maxFps:.*/maxFps:260/; s/^renderDistance:.*/renderDistance:12/' "$G/options.txt"
    export MCMETAL_FPS_LOG=1 MCMETAL_FPS_EVERY=1 MGL_SHOT_EVERY=0 # screenshots only after measuring: each one stalls the GPU
fi
mkdir -p "$G/shaderpacks" && rm -rf "$G/shaderpacks/mcmetal-rt-"* && cp -r "$SRC/tests/game/packs/"mcmetal-rt-* "$G/shaderpacks/"
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
    [ -f "$1" ] || { echo 0; return; }
    awk -v title="$2" '/presented frame/ && (title || !/\(0 terrain/) {on=1} on && /screenshot/ {n++} END {print n+0}' "$1" 2>/dev/null
}

run_phase() { # name seconds world shaders [VAR=value ...]: extra env for this phase
    local name=$1 secs=$2 world=$3 shaders=$4; shift 4
    # by default a phase ends once it has GAME_SHOTS screenshots of the loaded world; GAME_LONG=true plays the
    # full time (soak test: frame counts, leaks, late GPU faults)
    local want=${GAME_SHOTS:-4} title=0
    [ -z "$world" ] && { want=2; title=1; }
    printf 'enableShaders=%s\nshaderPack=%s\ncolorSpace=SRGB\ndisableUpdateMessage=true\n' \
        "$shaders" "${PACK:-ComplementaryReimagined_r5.9.3.zip}" > "$G/config/iris.properties"
    mkdir -p "$OUT/$name"
    local wargs=(--xmx 3G --size "${GAME_SIZE:-$([ "${GAME_BENCH:-}" = true ] && echo 1920x1200 || echo 1280x720)}")
    [ -n "$world" ] && wargs+=(--world "$world")
    mkdir -p "$OUT/$name/glsl"
    echo "=== phase $name: ${secs}s, world=${world:-none}, shaders=$shaders"
    MCMETAL_BACKGROUND=${MCMETAL_BACKGROUND-behind} \
    MGL_LOG="$OUT/$name/mgl.log" MGL_SHOT_DIR="$OUT/$name" MGL_SHOT_EVERY=${MGL_SHOT_EVERY-10} \
    MGL_CACHE_DIR="$WORK/cache" MGL_DUMP_DIR="$OUT/$name/glsl" env ${GAME_ENV:-} "$@" \
        python3 -I "$SRC/tools/bare_mc.py" launch "$WORK" --java "$JAVA" "${wargs[@]}" \
        ${LIBARGS[@]+"${LIBARGS[@]}"} > "$OUT/$name/launch.out" 2>&1 &
    local t=0
    while [ $t -lt "$secs" ]; do
        sleep 5; t=$((t + 5))
        pid=$(cat "$WORK/client.pid" 2>/dev/null)
        if [ $t -gt 20 ] && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then echo "game exited after ${t}s"; break; fi
        if [ "${GAME_BENCH:-}" = true ] && [ -n "$world" ]; then
            # start on the game's own "joined the game" line: Apple's OpenGL writes no mgl.log
            if [ -z "${bench_from:-}" ] && grep -q 'joined the game' "$WORK/client.log" 2>/dev/null; then
                sleep "${GAME_BENCH_SETTLE:-10}"; t=$((t + ${GAME_BENCH_SETTLE:-10}))
                bench_from=$(grep -c '\] fps ' "$WORK/client.log" 2>/dev/null)
                echo "world on screen, measuring ${GAME_BENCH_SECS:-30}s"
                sleep "${GAME_BENCH_SECS:-30}"
                # after measuring: where the CPU goes (native stacks, mcmetal symbolised) and what the Java render
                # thread is doing, for phases whose frame time isn't GPU time
                pid=$(cat "$WORK/client.pid" 2>/dev/null)
                if [ -n "$pid" ]; then
                    sample "$pid" 5 -mayDie -file "$OUT/$name/sample.txt" >/dev/null 2>&1
                    for k in 1 2 3; do jcmd "$pid" Thread.print 2>/dev/null | awk '/^"Render thread"/,/^$/' >> "$OUT/$name/render-thread.txt"; sleep 1; done
                fi
                touch "$OUT/$name/shoot"; sleep 3; rm -f "$OUT/$name/shoot"; break
            fi
            continue
        fi
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
    # fps: Minecraft's counter every second (bench mode), only the samples from the measured window
    local fps; fps=$(grep -ho '\] fps [0-9]*' "$OUT/$name/client.log" 2>/dev/null | awk '{print $3}' | tail -n +$((${bench_from:-12} + 1)) | head -n "$([ -n "${bench_from:-}" ] && echo "${GAME_BENCH_SECS:-30}" || echo 100000)")
    bench_from=
    [ -n "$fps" ] && echo "fps $name: $(echo "$fps" | sort -n | awk '{a[NR]=$1; s+=$1} END {if (NR) printf "median %d, mean %.0f, low %d, high %d over %d samples", a[int((NR+1)/2)], s/NR, a[1], a[NR], NR}')" | tee -a "$OUT/fps.txt"
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
    [ "${3:-scene}" = showcase ] && echo 'tp @s ~ ~ ~ -90 0' > "$f/look.mcfunction"
    [ -n "${GAME_LOOK:-}" ] && echo "tp @s ~ ~ ~ $GAME_LOOK" > "$f/look.mcfunction" # GAME_LOOK="yaw pitch"
    return 0
}

act() { # on|off|showcase: Complementary's options. ACT ships off; "on" = 128, the size the inventory was taken at;
        # "showcase" = everything Iris's Mac flag used to lock away, at high settings
    local f="$G/shaderpacks/ComplementaryReimagined_r5.9.3.zip.txt"
    case $1 in
    on) echo "COLORED_LIGHTING=128" > "$f" ;;
    plain) printf 'RAIN_PUDDLES=1\nDETAIL_QUALITY=3\n' > "$f" ;; # showcase settings Apple's OpenGL can also run
    showcase) printf 'COLORED_LIGHTING=256\nWORLD_SPACE_REFLECTIONS=1\nRAIN_PUDDLES=1\nDETAIL_QUALITY=3\n' > "$f" ;;
    *) rm -f "$f" ;;
    esac
}

# Third-party shader packs for the compatibility sweep, fetched from Modrinth at run time and deleted after the
# phase: their source must never be committed or uploaded (the glsl/ dumps are left out of the CI artifacts).
#   name|file in shaderpacks/|url|sha1
PACKS="photon|photon_v1.4.zip|https://cdn.modrinth.com/data/lLqFfGNs/versions/BnGklH5y/photon_v1.4.zip|96c7730f5891a42e39bbf1f0f5a98fa99628a7fe
bsl|BSL_v10.1.8.zip|https://cdn.modrinth.com/data/Q1vvjJYV/versions/Y68yiql9/BSL_v10.1.8.zip|e89818c8827d0131c102fb480c3c3446624db0df
bliss|Bliss_v2.1.2.zip|https://cdn.modrinth.com/data/ZvMtQlho/versions/kC2Y8q1P/Bliss_v2.1.2_%28Chocapic13_Shaders_edit%29.zip|ded6c8a98305f8aff90ef781e7585b33b8452cfd
makeup|MakeUp-UltraFast-9.6.zip|https://cdn.modrinth.com/data/izsIPI7a/versions/t4YRxQug/MakeUp-UltraFast-9.6.zip|e2a930f1ffb7ca6a56cf466c13c9e36193425a38
solas|Solas-V3.8.zip|https://cdn.modrinth.com/data/EpQFjzrQ/versions/XE9yh7pS/Solas%20Shader%20V3.8.zip|e2a5ded8e3061fa1bbf12e828a9992044c88fa62
rv|rethinking-voxels_r0.1-beta9.zip|https://cdn.modrinth.com/data/kmwfVOoi/versions/cpD4esk9/rethinking-voxels_r0.1-beta9.zip|9689915ec1a7215eb6060be2a08eaf3a09ebdbab
unbound|ComplementaryUnbound_r5.9.3.zip|https://cdn.modrinth.com/data/R6NEzAwj/versions/B1kyfoUZ/ComplementaryUnbound_r5.9.3.zip|2ee08300e1d6f039e63eae8484dddf57b3aaaf67
complementary|ComplementaryReimagined_r5.9.3.zip|-|-"
# Euphoria Patches is a mod: it writes a patched copy of Complementary into shaderpacks/ when the game starts
EUPHORIA="https://cdn.modrinth.com/data/4H6sumDB/versions/QMsRXtSJ/EuphoriaPatcher-1.10.5-r5.9.3-neoforge.jar|2b3f92878d6867fa0199937da25ba882b9db7902"
EUPHORIA_PACK="ComplementaryReimagined_r5.9.3 + EuphoriaPatches_1.10.5"

# packnight-NAME turns each pack's coloured block light on (all ship with it off except Solas and RV)
PACK_LIGHT="photon|COLORED_LIGHTS=true
bliss|LPV_ENABLED=true
bsl|MULTICOLORED_BLOCKLIGHT=true
unbound|COLORED_LIGHTING=128
complementary|COLORED_LIGHTING=128"

third_party() { # pack-NAME / packnight-NAME: one third-party pack in the pool scene, at noon (pack settings as
                # shipped) or midnight (coloured block light on)
    local p=$1 name=${1#*-} file url sha
    IFS='|' read -r _ file url sha <<< "$(grep "^${name%%+*}|" <<< "$PACKS")"
    [ -n "$file" ] || { echo "unknown pack $name"; return; }
    if [ "$url" != - ] && ! python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import bare_mc; bare_mc.fetch(*sys.argv[2:])' \
        "$SRC/tools" "$url" "$G/shaderpacks/$file" "$sha"; then echo "could not download $file"; return; fi
    case $name in *+euphoria) # pack-complementary+euphoria
        IFS='|' read -r url sha <<< "$EUPHORIA"
        python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import bare_mc; bare_mc.fetch(*sys.argv[2:])' \
            "$SRC/tools" "$url" "$G/mods/euphoria-patcher.jar" "$sha" || return
        file=$EUPHORIA_PACK ;;
    esac
    local opts=$G/shaderpacks/$file.txt
    rm -f "$opts"
    case $p in
    packnight-*) scene midnight
        grep "^${name%%+*}|" <<< "$PACK_LIGHT" | cut -d'|' -f2 > "$opts"; [ -s "$opts" ] || rm -f "$opts" ;;
    *) scene noon ;;
    esac
    PACK=$file run_phase "$p" 240 metal true
    rm -f "$opts"
    rm -f "$G/mods/euphoria-patcher.jar"
    [ "$url" != - ] && rm -rf "$G/shaderpacks/$file"
    rm -rf "$G/shaderpacks/$EUPHORIA_PACK"*
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
    showcase-mac) scene midnight clear showcase; act showcase; run_phase showcase-mac 240 metal true MCMETAL_KEEP_MAC_FLAG=1 ;; # as Apple GL renders it
    world-f3) rm -rf "$G/saves/metal/datapacks/mcm-scene"; run_phase world-f3 180 metal false MCMETAL_F3=1 ;;     # bench: F3 screen open
    rt-demo) scene 1500; PACK=mcmetal-rt-demo run_phase rt-demo 180 metal true ;; # hardware ray-traced sun shadows (mcm_trace)
    rt-debug) scene 1500; PACK=mcmetal-rt-debug run_phase rt-debug 180 metal true ;; # rays drawn as hit (green) / miss (red)
    showcase-plain) scene midnight clear showcase; act plain; run_phase showcase-plain 240 metal true MCMETAL_KEEP_MAC_FLAG=1 ;; # like-for-like with Apple GL, no error screen
    showcase-rain) scene 13800 rain showcase; act showcase; run_phase showcase-rain 240 metal true ;;  # + improved rain, puddles
    pack-*|packnight-*) third_party "$p" ;; # compatibility sweep: pack-photon, packnight-bsl, pack-complementary+euphoria, ...
    esac
done
