#!/bin/bash
# Runs real Minecraft 1.21.1 + NeoForge + Sodium + Iris on mcmetal and saves timed screenshots (MGL_SHOT_DIR).
#   bash tests/game/ci_game.sh WORK OUT [phases...]   phases: title world complementary sound sound-off sound-apple water water-shaders night night-act showcase showcase-mac showcase-plain world-f3 rt-demo showcase-rain nether nether-shaders dh dh-shaders dh-PACK ours ours-noon ours-sunset ours-night ours-rain ours-gl ours-shadow ours-ao ours-gi ours-room ours-room-gi ours-room-off ours-lights ours-pool-night ours-low ours-ultra ours-glass ours-glass-night ours-glass-off ours-caustics ours-caustics-mask ours-water ours-water-full ours-underwater ours-vista ours-vista-STYLE-TIME ours-season-SEASON[-STYLE]
#   menu menu-noif menu-shaders creative creative-shaders creative-scroll particles ab-menu ab-menu-noif ab-menu-shaders ab-creative ab-creative-shaders ab-particles (JEI, ImmediatelyFast, Particle Rain)
#   pack-NAME packnight-NAME packshadow-NAME (third-party packs, see PACKS below; pack-NAME@OPT=value,... adds pack options)
#   herd-NAME (the pack over a busy farm: 240 mobs and 64 chests, for entity costs; ab-herd-NAME for A/B)
#   glcount-pack-NAME (the pack on Apple's OpenGL, draws counted by tools/glcount.c)
#   ab-pack-NAME ab-packnight-NAME (the pack three times in one job: new, old = with GAME_AB_OFF's env, new)
#   archive-NAME (pipeline binary archive: cold, warm, warm without archive)
#   (default: the first three)
# WORK holds the game install (cacheable), OUT gets screenshots and logs. Needs Java 21 as `java` or $JAVA.
set -uo pipefail
CRASHED= # phases where the JVM crashed or Minecraft wrote a crash report: the job fails at the end
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
# GAME_SEGMENTS: a file, or a name in tests/game/segments/ (see segments() below)
# (in CI only a name: the file's first fields end up in the uploaded logs)
if [ -n "${GAME_SEGMENTS:-}" ] && { [ -n "${GITHUB_ACTIONS:-}" ] || [ ! -f "$GAME_SEGMENTS" ]; }; then
    [[ $GAME_SEGMENTS =~ ^[A-Za-z0-9_-]+$ ]] || { echo "GAME_SEGMENTS must name a file in tests/game/segments/"; exit 1; }
    GAME_SEGMENTS=$SRC/tests/game/segments/$GAME_SEGMENTS.txt
fi
[ -n "${GAME_SEGMENTS:-}" ] && { [ -f "$GAME_SEGMENTS" ] || { echo "no segments file $GAME_SEGMENTS"; exit 1; }; GAME_SEGMENTS=$(cd "$(dirname "$GAME_SEGMENTS")" && pwd)/$(basename "$GAME_SEGMENTS"); }
case "${GAME_BENCH_SETTLE:-10}" in ''|*[!0-9]*) echo "GAME_BENCH_SETTLE must be a whole number of seconds"; exit 1 ;; esac
if [ "${GAME_BENCH:-}" = true ]; then
    sed -i.bak 's/^enableVsync:.*/enableVsync:false/; s/^maxFps:.*/maxFps:260/; s/^renderDistance:.*/renderDistance:12/' "$G/options.txt"
    export MCMETAL_FPS_LOG=1 MCMETAL_FPS_EVERY=1 MGL_SHOT_EVERY=0 # screenshots only after measuring: each one stalls the GPU
fi
# GAME_RP=labpbr-test: our own LabPBR test textures (tests/game/rp/make_labpbr_test.py) as the resource pack
rm -f "$G/resourcepacks/mcm-labpbr-test.zip"
if [ "${GAME_RP:-}" = labpbr-test ]; then
    mkdir -p "$G/resourcepacks" && python3 -I "$SRC/tests/game/rp/make_labpbr_test.py" "$G/resourcepacks/mcm-labpbr-test.zip" > /dev/null
    sed -i.bak 's|^resourcePacks:.*|resourcePacks:["vanilla","file/mcm-labpbr-test.zip"]|' "$G/options.txt"
fi
mkdir -p "$G/shaderpacks" && find "$G/shaderpacks" -maxdepth 1 -name "mcmetal-rt-*" ! -name "*.txt" -exec rm -rf {} + && cp -r "$SRC/tests/game/packs/"mcmetal-rt-* "$SRC/shaderpack/mcmetal-rt-pack" "$G/shaderpacks/"
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
# GAME_PROFILE=true (with GAME_BENCH): every GL call goes through glprof (tools/glprof.h: calls and CPU time per
# function, frames, time in swap) and Java Flight Recorder samples the Java side; the measured window ends up in
# glprof-report.txt and jfr-report.txt. The recording itself is deleted (it holds the environment).
JFR_TOOL=${JAVA_HOME:+$JAVA_HOME/bin/}jfr
if [ "${GAME_PROFILE:-}" = true ]; then
    LIBARGS=(--gl "$SRC/build/libglprof-mcmetal.dylib" --glfw "$SRC/build/libglfw.dylib")
    export MCMETAL_LIB="$SRC/build/libglprof-mcmetal.dylib" GLPROF_REAL="$SRC/build/libmcmetal.dylib"
fi

shots_in_world() { # screenshots taken after the first frame that drew terrain (any frame for the title screen)
    [ -f "$1" ] || { echo 0; return; }
    awk -v title="$2" '/presented frame/ && (title || !/\(0 terrain/) {on=1} on && /screenshot/ {n++} END {print n+0}' "$1" 2>/dev/null
}

fps_summary() { # label log skip count: Minecraft's fps counter (one line a second in bench mode), lines skip+1..skip+count
    local fps; fps=$(grep -ho '\] fps [0-9]*' "$2" 2>/dev/null | awk '{print $3}' | tail -n +$(($3 + 1)) | head -n "$4")
    [ -n "$fps" ] && echo "fps $1: $(echo "$fps" | sort -n | awk '{a[NR]=$1; s+=$1} END {if (NR) printf "median %d, mean %.0f, low %d, high %d over %d samples", a[int((NR+1)/2)], s/NR, a[1], a[NR], NR}')" | tee -a "$OUT/fps.txt"
}

# GAME_SEGMENTS=FILE (bench mode): after the phase's own measurement, the same launch measures more scenes, one per
# line of FILE, instead of relaunching the game (JVM, NeoForge and world load) for each. A line is
#   name|time|weather|look|options|shot
# time: "time set" value (noon, 12300, midnight); weather: clear/rain; look: "yaw pitch" or "~2 7" (pan), as
# GAME_LOOK; options: shader pack options added to the phase's own (e.g. "LIGHT_SLOTS=8 RT_GI=false"), "-" for the
# phase's own; shot: yes for one screenshot at the end (in OUT/PHASE/NAME/). Empty fields keep the last segment's
# value. Only things that can change in a running game: env vars (MGL_*) and the stage still need their own launch.
# The mod's MCMETAL_CONTROL file runs the commands (time, weather, datapack reload for the look, shader reload).
segments() { # phase
    local name=$1 ctl=$OUT/$1/control look_f="$G/saves/metal/datapacks/mcm-scene/data/mcm/function/look.mcfunction"
    local opts_f="$G/shaderpacks/${PACK:-ComplementaryReimagined_r5.9.3.zip}.txt" base_opts= last_opts=- n=0 reloads=0
    [ -f "$opts_f" ] && base_opts=$(cat "$opts_f")
    local base_look; base_look=$(cat "$look_f" 2>/dev/null)
    local seg tm wx look opts shot
    while IFS='|' read -r seg tm wx look opts shot; do
        case $seg in ''|'#'*) continue ;; esac
        local t0=$SECONDS lines= wait=${GAME_SEG_SETTLE:-5}
        [ -n "$tm" ] && lines+="cmd time set $tm"$'\n'
        [ -n "$wx" ] && lines+="cmd weather $wx 100000"$'\n'
        [ -n "$look" ] && { echo "tp @s ~ ~ ~ $look" > "$look_f"; lines+="cmd reload"$'\n'; }
        if [ -n "$opts" ] && [ "$opts" != "$last_opts" ]; then
            { [ -n "$base_opts" ] && echo "$base_opts"; [ "$opts" != - ] && tr ' ' '\n' <<< "$opts"; } > "$opts_f"
            lines+="shaders"$'\n'; wait=${GAME_SEG_SETTLE_SHADERS:-10}; last_opts=$opts
        fi
        n=$((n + 1))
        printf '%smark segment %s\n' "$lines" "$seg" > "$ctl.tmp" && mv "$ctl.tmp" "$ctl" # whole batches only
        local fails; fails=$(grep -cE "control failed|command failed|shader reload failed" "$WORK/client.log" 2>/dev/null)
        # the mod polls twice a second; a shader reload finishes on the render thread after "control done"
        local k=0 done_re="control done"
        [[ $lines == *shaders* ]] && { reloads=$((reloads + 1)); done_re="shaders reloaded|shader reload failed"; }
        while [ $k -lt 90 ] && [ "$(grep -cE "$done_re" "$WORK/client.log" 2>/dev/null)" -lt "$([ "$done_re" = "control done" ] && echo $n || echo $reloads)" ]; do
            sleep 1; k=$((k + 1))
        done
        if [ $k -ge 90 ] || [ "$(grep -cE "control failed|command failed|shader reload failed" "$WORK/client.log" 2>/dev/null)" -gt "$fails" ]; then
            echo "segment $seg: the game did not take the changes (see client.log), not measured" | tee -a "$OUT/fps.txt"
            continue
        fi
        sleep "$wait"
        local from; from=$(grep -c '\] fps ' "$WORK/client.log" 2>/dev/null)
        echo "segment $seg: measuring ${GAME_BENCH_SECS:-30}s"
        sleep "${GAME_BENCH_SECS:-30}"
        fps_summary "$name/$seg" "$WORK/client.log" "$from" "${GAME_BENCH_SECS:-30}"
        if [ "$shot" = yes ]; then
            mkdir -p "$OUT/$name/$seg"
            local before; before=$(ls "$OUT/$name"/shot-*.png "$OUT/$name"/screenshots/apple-*.png 2>/dev/null)
            touch "$OUT/$name/shoot"; sleep 3; rm -f "$OUT/$name/shoot"
            for f in "$OUT/$name"/shot-*.png "$OUT/$name"/screenshots/apple-*.png; do # mcmetal / Apple's OpenGL
                [ -f "$f" ] && ! grep -qxF "$f" <<< "$before" && mv "$f" "$OUT/$name/$seg/"
            done
        fi
        echo "segment $seg took $((SECONDS - t0)) s"
    done < "$GAME_SEGMENTS"
    [ -n "$base_opts" ] && echo "$base_opts" > "$opts_f" || rm -f "$opts_f"
    [ -n "$base_look" ] && echo "$base_look" > "$look_f" # the phase's own camera for whatever runs next
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
    # PACK_OPTS="A=1 B=false": options for the pack in use (Iris reads shaderpacks/<pack>.txt)
    # our packs' option files are rewritten every phase, so one phase's options never leak into the next
    case ${PACK:-} in mcmetal-rt-*) rm -f "$G/shaderpacks/$PACK.txt" ;; esac
    [ -n "${PACK_OPTS:-}" ] && printf '%s\n' $PACK_OPTS > "$G/shaderpacks/${PACK:-ComplementaryReimagined_r5.9.3.zip}.txt"
    [ -f "$G/shaderpacks/${PACK:-ComplementaryReimagined_r5.9.3.zip}.txt" ] && echo "pack options: $(tr '\n' ' ' < "$G/shaderpacks/${PACK:-ComplementaryReimagined_r5.9.3.zip}.txt")"
    local wargs=(--xmx "${GAME_XMX:-3G}" --size "${GAME_SIZE:-$([ "${GAME_BENCH:-}" = true ] && echo 1920x1200 || echo 1280x720)}")
    [ -n "$world" ] && wargs+=(--world "$world")
    mkdir -p "$OUT/$name/glsl"
    echo "=== phase $name: ${secs}s, world=${world:-none}, shaders=$shaders"
    local started=$SECONDS
    rm -f "$OUT/$name/control"
    local jvmx=(--)
    [ "${GAME_PROFILE:-}" = true ] && jvmx+=(-XX:FlightRecorderOptions=stackdepth=128
        "-XX:StartFlightRecording=name=mcm,settings=profile,dumponexit=true,filename=$WORK/rec.jfr,jdk.ExecutionSample#period=10ms,jdk.NativeMethodSample#period=10ms")
    # bench mode: every stop-the-world pause (GC or not) is logged, for gc-report.txt (tools/gc_report.py)
    rm -f "$OUT/$name/gc.log" "$OUT/$name/frames.txt"
    [ "${GAME_BENCH:-}" = true ] && jvmx+=("-Xlog:gc,safepoint:file=$OUT/$name/gc.log:time,uptimemillis,level,tags")
    # GAME_JVM="-XX:+UseZGC -XX:+ZGenerational": JVM options for this run (after ours, so they win; GAME_XMX=8G
    # sets the heap, default 3G)
    [ -n "${GAME_JVM:-}" ] && { read -ra _jvm <<< "$GAME_JVM"; jvmx+=("${_jvm[@]}"); echo "JVM options: $GAME_JVM"; }
    MCMETAL_CONTROL=$([ -n "${GAME_SEGMENTS:-}" ] && echo "$OUT/$name/control") \
    MCMETAL_BACKGROUND=${MCMETAL_BACKGROUND-behind} \
    MGL_LOG="$OUT/$name/mgl.log" MGL_SHOT_DIR="$OUT/$name" MGL_SHOT_EVERY=${MGL_SHOT_EVERY-10} \
    MGL_CACHE_DIR="$WORK/cache" MGL_DUMP_DIR="$OUT/$name/glsl" GLPROF_OUT="$OUT/$name/glprof.txt" GLPROF_FRAMES="$OUT/$name/frames.txt" env ${GAME_ENV:-} "$@" \
        python3 -I "$SRC/tools/bare_mc.py" launch "$WORK" --java "$JAVA" "${wargs[@]}" \
        ${LIBARGS[@]+"${LIBARGS[@]}"} ${jvmx[@]+"${jvmx[@]}"} > "$OUT/$name/launch.out" 2>&1 &
    local t=0
    local poll=$([ "${GAME_BENCH:-}" = true ] && echo 1 || echo 5) # bench: notice the world within a second
    while [ $t -lt "$secs" ]; do
        sleep $poll; t=$((t + poll))
        pid=$(cat "$WORK/client.pid" 2>/dev/null)
        if [ $t -gt 20 ] && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then echo "game exited after ${t}s"; break; fi
        if [ "${GAME_BENCH:-}" = true ] && [ -n "$world" ]; then
            # start on the game's own "joined the game" line: Apple's OpenGL writes no mgl.log
            if [ -z "${bench_from:-}" ] && grep -q 'joined the game' "$WORK/client.log" 2>/dev/null; then
                sleep "${GAME_BENCH_SETTLE:-10}"; t=$((t + ${GAME_BENCH_SETTLE:-10}))
                bench_from=$(grep -c '\] fps ' "$WORK/client.log" 2>/dev/null)
                echo "world on screen, measuring ${GAME_BENCH_SECS:-30}s"
                cp "$OUT/$name/glprof.txt" "$OUT/$name/glprof-start.txt" 2>/dev/null; local from_s; from_s=$(date +%s)
                gc_window="$from_s $((from_s + ${GAME_BENCH_SECS:-30}))"
                sleep "${GAME_BENCH_SECS:-30}"
                if [ "${GAME_PROFILE:-}" = true ]; then
                    cp "$OUT/$name/glprof.txt" "$OUT/$name/glprof-end.txt" 2>/dev/null
                    python3 -I "$SRC/tools/glprof_report.py" "$OUT/$name/glprof-start.txt" "$OUT/$name/glprof-end.txt" 60 \
                        > "$OUT/$name/glprof-report.txt" 2>&1
                    head -4 "$OUT/$name/glprof-report.txt"
                    jfr_window="$from_s $((from_s + ${GAME_BENCH_SECS:-30}))" # the recording is written when the game exits
                fi
                # after measuring: where the CPU goes (native stacks, mcmetal symbolised) and what the Java render
                # thread is doing, for phases whose frame time isn't GPU time
                pid=$(cat "$WORK/client.pid" 2>/dev/null)
                if [ -n "$pid" ] && [ "${GAME_SAMPLE:-1}" != 0 ]; then # GAME_SAMPLE=0: skip (saves ~24 s a run)
                    echo "sampling CPU stacks"
                    # each tool gets a time limit (macOS has no timeout command) and no handle on the step's output:
                    # jcmd can't attach to a 1 fps game and would otherwise keep the CI step open forever
                    sample "$pid" 5 -mayDie -file "$OUT/$name/sample.txt" </dev/null >/dev/null 2>&1 &
                    for k in 1 2 3; do
                        jcmd "$pid" Thread.print </dev/null > "$OUT/$name/jstack-$k.txt" 2>/dev/null &
                        sleep 4
                    done
                    sleep 12; pkill -9 -x jcmd; pkill -9 -x sample
                    cat "$OUT/$name"/jstack-*.txt 2>/dev/null | awk '/^"Render thread"/,/^$/' > "$OUT/$name/render-thread.txt"
                    rm -f "$OUT/$name"/jstack-*.txt
                    echo "sampling done"
                fi
                [ "${GAME_SHOT:-1}" != 0 ] && { touch "$OUT/$name/shoot"; sleep 3; rm -f "$OUT/$name/shoot"; }
                [ -n "${GAME_SEGMENTS:-}" ] && segments "$name"
                break
            fi
            continue
        fi
        if [ "${GAME_LONG:-}" != true ] && [ "$(shots_in_world "$OUT/$name/mgl.log" $title)" -ge "$want" ]; then
            echo "got $want screenshots in the world after ${t}s"; break
        fi
    done
    pid=$(cat "$WORK/client.pid" 2>/dev/null); [ -n "$pid" ] && kill "$pid" 2>/dev/null
    local k=0; while [ -n "$pid" ] && [ $k -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.5; k=$((k + 1)); done
    if [ "${GAME_PROFILE:-}" = true ]; then # give the JVM time to write the flight recording on its way out
        for _ in 1 2 3 4 5; do [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && sleep 3; done
    fi
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    if [ -n "${jfr_window:-}" ] && [ -f "$WORK/rec.jfr" ]; then
        # where the render thread's time went in the measured window
        python3 -I "$SRC/tools/jfr_report.py" "$JFR_TOOL" "$WORK/rec.jfr" $jfr_window > "$OUT/$name/jfr-report.txt" 2>&1
        head -12 "$OUT/$name/jfr-report.txt"
        # what the render thread and the others were doing inside each frame of 50 ms or more (GAME_HITCH_MS)
        if [ -f "$OUT/$name/frames.txt" ] && [ -f "$OUT/$name/gc.log" ]; then
            python3 -I "$SRC/tools/hitch_report.py" "$JFR_TOOL" "$WORK/rec.jfr" "$OUT/$name/frames.txt" \
                "$OUT/$name/gc.log" $jfr_window "${GAME_HITCH_MS:-50}" > "$OUT/$name/hitch-report.txt" 2>&1
            head -40 "$OUT/$name/hitch-report.txt"
        fi
    fi
    rm -f "$WORK/rec.jfr"; jfr_window=
    if [ -n "${gc_window:-}" ] && [ -f "$OUT/$name/gc.log" ]; then # JVM pauses in the measured window
        python3 -I "$SRC/tools/gc_report.py" "$OUT/$name/gc.log" $gc_window > "$OUT/$name/gc-report.txt" 2>&1
        cat "$OUT/$name/gc-report.txt"
    fi
    # profile mode: what the slowest 1% of frames were doing (Java, GL, swap, JVM pause); frames.txt is per frame
    if [ -n "${gc_window:-}" ] && [ -f "$OUT/$name/frames.txt" ]; then
        python3 -I "$SRC/tools/slow_frames.py" "$OUT/$name/frames.txt" "$OUT/$name/gc.log" $gc_window \
            > "$OUT/$name/slow-frames.txt" 2>&1
        cat "$OUT/$name/slow-frames.txt"
    fi
    gc_window=
    cp "$WORK/client.log" "$OUT/$name/client.log" 2>/dev/null
    # mcmetal clears the mod's start marker once real screens are drawn; left behind, the next launch would
    # fall back to Apple's OpenGL, so report it and clear it for the next phase
    [ -e "$G/mcmetal/starting" ] && { echo "WARNING: start marker not cleared (mcmetal never drew a full screen)"; rm -f "$G/mcmetal/starting"; }
    grep -q 'last launch on Metal did not' "$OUT/$name/client.log" 2>/dev/null && echo "WARNING: this phase ran on Apple's OpenGL (fallback)"
    grep -h '\[mcmetal\]' "$OUT/$name/client.log" 2>/dev/null | grep -v 'presented frame\|screenshot\|\] fps ' | head -5
    # fps: Minecraft's counter every second (bench mode), only the samples from the measured window
    fps_summary "$name" "$OUT/$name/client.log" "${bench_from:-12}" "$([ -n "${bench_from:-}" ] && echo "${GAME_BENCH_SECS:-30}" || echo 100000)"
    bench_from=
    echo "phase $name took $((SECONDS - started)) s"
    cp "$G/logs/latest.log" "$OUT/$name/latest.log" 2>/dev/null
    # a JVM crash (hs_err) or a Minecraft crash report fails the job at the end (the phase's fps and shots still
    # get collected): a crash a few seconds into the world used to pass green
    if ls "$G"/hs_err_pid*.log >/dev/null 2>&1; then
        mv "$G"/hs_err_pid*.log "$OUT/$name/"
        CRASHED="$CRASHED $name"
        echo "::error::phase $name: the JVM crashed ($(grep -m1 -hE 'SIGSEGV|SIGBUS|fatal error|Internal Error' "$OUT/$name"/hs_err_pid*.log | head -1 | cut -c1-160))"
    fi
    if ls "$G"/crash-reports/*.txt >/dev/null 2>&1; then
        mkdir -p "$OUT/$name/crash-reports" && mv "$G"/crash-reports/*.txt "$OUT/$name/crash-reports/"
        CRASHED="$CRASHED $name"
        echo "::error::phase $name: Minecraft crash report ($(grep -m1 -h '^Description:' "$OUT/$name"/crash-reports/*.txt | cut -c1-160))"
    fi
    echo "screenshots: $(ls "$OUT/$name"/shot-*.png 2>/dev/null | wc -l)"
    # our own pack: keep the source of programs that failed to link (pack code + Iris's wrapper; skip anything with
    # Sodium's terrain code) outside glsl/, so it lands in the uploaded artifact
    if [ "${PACK:-}" = mcmetal-rt-pack ]; then
        for n in $(grep -o 'link of program [0-9]*' "$OUT/$name/mgl.log" 2>/dev/null | awk '{print $4}' | sort -u); do
            mkdir -p "$OUT/$name/failed"
            for f in "$OUT/$name/glsl/prog$n".*; do grep -q u_RegionOffset "$f" || cp "$f" "$OUT/$name/failed/"; done
        done
    fi
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
    # a fresh tag per phase: the player keeps tags in the shared save, so a fixed tag would skip the build (and its
    # time of day) in every phase after the first
    perl -pi -e "s/(tag=!?|add )mcm\\b/\$1mcm$RANDOM$RANDOM/g" "$f/tick.mcfunction"
    [ "${3:-scene}" = showcase ] && echo 'tp @s ~ ~ ~ -90 0' > "$f/look.mcfunction"
    [ "${3:-scene}" = room ] && echo 'tp @s ~ ~ ~ -90 12' > "$f/look.mcfunction"
    [ "${3:-scene}" = nether ] && echo 'tp @s 0.5 64 0.5 -90 7' > "$f/look.mcfunction" # held in the Nether room
    [ "${3:-scene}" = dh ] && echo 'tp @s 0.5 150 0.5 -45 12' > "$f/look.mcfunction" # high up, looking at the horizon
    [ "${3:-scene}" = herd ] && echo 'tp @s ~ ~ ~ -90 20' > "$f/look.mcfunction" # above the farm, looking down at it
    [ -n "${GAME_LOOK:-}" ] && echo "tp @s ~ ~ ~ $GAME_LOOK" > "$f/look.mcfunction" # GAME_LOOK="yaw pitch"
    [ -n "${GAME_TP:-}" ] && echo "tp @s $GAME_TP" > "$f/look.mcfunction" # GAME_TP="~0.1 ~ ~ ~2 7": walk and turn each tick
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

# Distant Horizons (LOD terrain past the render distance), fetched at run time like the packs and removed after
DH="https://cdn.modrinth.com/data/uCdwusMi/versions/9w34y8ai/DistantHorizons-3.3.3-1.21.1-fabric-neoforge.jar|4357b4d19fab818780c94f0e43dad1cc931634b2"
dh_phase() { # dh / dh-shaders / dh-PACK: Distant Horizons at noon, without a pack, with Complementary (it has DH
             # support) or with PACK (a name from PACKS, or "ours" for shaderpack/mcmetal-rt-pack); 16 screenshots
             # (~160 s) so DH has time to build its distant terrain
    local url sha pack=${3:-} file= purl=-
    if [ -n "$pack" ]; then
        if [ "$pack" = ours ]; then file=mcmetal-rt-pack
        else
            IFS='|' read -r _ file purl sha <<< "$(grep "^$pack|" <<< "$PACKS")"
            [ -n "$file" ] || { echo "unknown pack $pack"; return; }
            if [ "$purl" != - ] && ! python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import bare_mc; bare_mc.fetch(*sys.argv[2:])' \
                "$SRC/tools" "$purl" "$G/shaderpacks/$file" "$sha"; then echo "could not download $file"; return; fi
        fi
    fi
    IFS='|' read -r url sha <<< "$DH"
    python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import bare_mc; bare_mc.fetch(*sys.argv[2:])' \
        "$SRC/tools" "$url" "$G/mods/distanthorizons.jar" "$sha" || { echo "could not download Distant Horizons"; return; }
    scene noon clear dh
    # LODs for the test world, built ahead (tests/game/dh-lods.tgz: DH 3.3.3 at radius 128 on real OpenGL, ~12 min),
    # so the phase shows distant terrain to the horizon from its first frame; DH would take far longer than a CI
    # phase to build them. GAME_DH_COLD=1 starts without them (LOD build hitches, upload paths).
    rm -f "$G/saves/metal/data"/DistantHorizons.sqlite*
    [ "${GAME_DH_COLD:-}" = 1 ] || tar xzf "$SRC/tests/game/dh-lods.tgz" -C "$G/saves/metal"
    # GAME_DH_OPTS="graphics.quality.lodChunkRenderDistanceRadius=128 graphics.enableSsao=false": DH settings, as
    # keys under [client.advanced] of config/DistantHorizons.toml (DH fills in the rest); unset = DH's defaults
    rm -f "$G/config/DistantHorizons.toml"
    if [ -n "${GAME_DH_OPTS:-}" ]; then
        mkdir -p "$G/config"; echo "_version = 5" > "$G/config/DistantHorizons.toml"
        local kv; for kv in $GAME_DH_OPTS; do echo "client.advanced.${kv%%=*} = ${kv#*=}" >> "$G/config/DistantHorizons.toml"; done
    fi
    PACK=${file:-${PACK:-}} GAME_SHOTS=${GAME_SHOTS:-16} run_phase "$1" 360 metal "$2"
    rm -f "$G/mods/distanthorizons.jar" "$G/config/DistantHorizons.toml" "$G/saves/metal/data"/DistantHorizons.sqlite*
    if [ "$purl" != - ]; then rm -rf "$G/shaderpacks/$file"; fi
}

# Menus and particles, with the client mods Hearth & Hex ships for them (same versions), fetched at run time like the
# packs and removed after the phase:
#   menu         the inventory held open (MCMETAL_TEST_SCREEN) with a full grid of items and JEI's item list beside it,
#                ImmediatelyFast on (as in the pack); GUI scale 2, so JEI shows several hundred icons at 1920x1200
#   menu-noif    the same without ImmediatelyFast (every item icon its own draw)
#   menu-shaders the same with Complementary on behind the menu
#   creative     the creative menu's search tab (every item) held open with JEI beside it; creative-shaders with
#                Complementary behind it, creative-scroll scrolls the item list as someone browsing it
#   particles    rain with Particle Rain (thousands of rain and splash particles) + ImmediatelyFast, no shaders
#   ab-menu, ab-menu-noif, ab-particles: new, old (GAME_AB_OFF's env), new in one job
JEI="https://cdn.modrinth.com/data/u6dRKJwZ/versions/ufHUqt9b/jei-1.21.1-neoforge-19.51.0.418.jar|d19552586f686eae4ef5e7199f31604d1d3cfca7"
IMMEDIATELYFAST="https://cdn.modrinth.com/data/5ZwdcRci/versions/EJzmEPZV/ImmediatelyFast-NeoForge-1.6.15%2B1.21.1.jar|f991166f7c82b493481c876e3c83c9fac4159671"
PARTICLE_RAIN="https://cdn.modrinth.com/data/nrikgvxm/versions/RxfaR4ud/particlerain-4.0.2%2B1.21.1-neoforge.jar|444c6f221e57cca8e433702b18c4643faa82545a"
fetch_mod() { # "url|sha" file-in-mods/
    local url sha; IFS='|' read -r url sha <<< "$1"
    python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import bare_mc; bare_mc.fetch(*sys.argv[2:])' \
        "$SRC/tools" "$url" "$G/mods/$2" "$sha" || { echo "could not download $2"; return 1; }
}
gui_phase() { # kind (menu, menu-noif, menu-shaders, creative, creative-shaders, creative-scroll, particles) out-name [VAR=value ...]
    local kind=$1 out=$2; shift 2
    rm -f "$G/mods/mcm-jei.jar" "$G/mods/mcm-immediatelyfast.jar" "$G/mods/mcm-particlerain.jar"
    case $kind in menu-noif) ;; *) fetch_mod "$IMMEDIATELYFAST" mcm-immediatelyfast.jar || return ;; esac
    case $kind in
    menu*|creative*)
        fetch_mod "$JEI" mcm-jei.jar || return
        local screen=inventory stage=menu shaders=false
        case $kind in creative-scroll) screen=creative-scroll stage=creative ;; creative*) screen=creative stage=creative ;; esac
        case $kind in *-shaders) shaders=true ;; esac
        scene noon clear $stage
        cp "$G/options.txt" "$G/options.txt.gui"; sed -i.bak 's/^guiScale:.*/guiScale:2/' "$G/options.txt"
        run_phase "$out" 240 metal $shaders MCMETAL_TEST_SCREEN=$screen "$@"
        mv "$G/options.txt.gui" "$G/options.txt" ;;
    particles)
        fetch_mod "$PARTICLE_RAIN" mcm-particlerain.jar || return
        scene 3000 rain
        run_phase "$out" 240 metal false "$@" ;;
    esac
    rm -f "$G/mods/mcm-jei.jar" "$G/mods/mcm-immediatelyfast.jar" "$G/mods/mcm-particlerain.jar"
}

# packnight-NAME turns each pack's coloured block light on (all ship with it off except Solas and RV)
PACK_LIGHT="photon|COLORED_LIGHTS=true
bliss|LPV_ENABLED=true
bsl|MULTICOLORED_BLOCKLIGHT=true
unbound|COLORED_LIGHTING=128
complementary|COLORED_LIGHTING=128"

third_party() { # pack-NAME / packnight-NAME / packshadow-NAME / herd-NAME [OUTNAME [VAR=value ...]]: one third-party pack in the pool scene, at
                # noon (pack settings as shipped) or midnight (coloured block light on); packshadow: the shadows room
    local p=$1 out=${2:-$1} name=${1#*-} file url sha extra=
    shift; [ $# -gt 0 ] && shift
    case $name in *@*) extra=${name#*@}; name=${name%%@*} ;; esac # pack-bliss@OPT=value,OPT2=value: extra options
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
    packnight-*|packshadow-*) scene midnight clear "$([ "${p%%-*}" = packshadow ] && echo shadows || echo scene)"
        grep "^${name%%+*}|" <<< "$PACK_LIGHT" | cut -d'|' -f2 > "$opts"; [ -s "$opts" ] || rm -f "$opts" ;;
    herd-*) scene noon clear herd ;; # herd-NAME: the busy farm (240 mobs, 64 chests) for entity costs
    *) scene noon ;;
    esac
    [ -n "$extra" ] && tr ',' '\n' <<< "$extra" >> "$opts"
    PACK=$file run_phase "$out" 240 metal true "$@"
    rm -f "$opts"
    rm -f "$G/mods/euphoria-patcher.jar"
    [ "$url" != - ] && rm -rf "$G/shaderpacks/$file"
    rm -rf "$G/shaderpacks/$EUPHORIA_PACK"*
}

# Sound Physics Remastered (echoes and muffling, ray traced per sound), fetched at run time and removed after: checks
# that mcmetal moves its rays off the sound engine thread (MCMETAL_SOUND_PHYSICS_ASYNC) without errors. A small
# datapack plays ten note-block sounds around the player once a second. Correctness only; listen on a real Mac.
SPR="https://cdn.modrinth.com/data/qyVF9oeo/versions/Dd2tmpsk/sound-physics-remastered-neoforge-1.21.1-1.5.1.jar|a5ac35ccb902231047709530a5708fb71dc3e3b5"
sound_phase() { # name [VAR=value ...]
    local url sha name=$1 d="$G/saves/metal/datapacks/mcm-sound"; shift
    IFS='|' read -r url sha <<< "$SPR"
    python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import bare_mc; bare_mc.fetch(*sys.argv[2:])' \
        "$SRC/tools" "$url" "$G/mods/sound-physics-remastered.jar" "$sha" || { echo "could not download Sound Physics Remastered"; return; }
    rm -rf "$d"; mkdir -p "$d/data/mcmsound/function" "$d/data/minecraft/tags/function"
    echo '{"pack":{"pack_format":48,"description":"mcmetal sound test"}}' > "$d/pack.mcmeta"
    echo '{"values":["mcmsound:tick"]}' > "$d/data/minecraft/tags/function/tick.json"
    echo '{"values":["mcmsound:load"]}' > "$d/data/minecraft/tags/function/load.json"
    echo 'scoreboard objectives add mcmsound dummy' > "$d/data/mcmsound/function/load.mcfunction"
    printf '%s\n' 'scoreboard players add #t mcmsound 1' 'execute if score #t mcmsound matches 20.. run function mcmsound:burst' \
        'execute if score #t mcmsound matches 20.. run scoreboard players set #t mcmsound 0' > "$d/data/mcmsound/function/tick.mcfunction"
    local i; : > "$d/data/mcmsound/function/burst.mcfunction"
    for i in 0 1 2 3 4 5 6 7 8 9; do
        echo "execute as @a at @s run playsound minecraft:block.note_block.harp block @s ~$((i - 5)) ~1 ~$((i % 3 + 2)) 1 1" >> "$d/data/mcmsound/function/burst.mcfunction"
    done
    cp "$G/options.txt" "$G/options.txt.sound"
    sed -i.bak 's/^soundCategory_master:.*/soundCategory_master:1.0/' "$G/options.txt" # at 0 Minecraft plays no sounds at all
    run_phase "$name" 180 metal false "$@"
    grep -hE "\[mcmetal\] (audio|sound)|\[mcmetal-al\]" "$OUT/$name/client.log" | sort | uniq -c | head -20
    [ -f "$OUT/$name/played.caf" ] && echo "recorded output: $(du -h "$OUT/$name/played.caf" | cut -f1)"
    grep -hE "OpenAL|Sound engine started|sound_physics.*(ERROR|Exception)" "$OUT/$name/client.log" | head -5
    rm -rf "$d" "$G/mods/sound-physics-remastered.jar"
    mv "$G/options.txt.sound" "$G/options.txt"
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
    sound) sound_phase sound ;;                       # Sound Physics Remastered, rays off the sound engine thread
    sound-off) sound_phase sound-off MCMETAL_SOUND_PHYSICS_ASYNC=0 ;;  # the same with the fix off
    sound-apple) sound_phase sound-apple MCMETAL_AUDIO_ENGINE=apple MCMETAL_AL_TAP="$OUT/sound-apple/played.caf" ;;  # on Apple's audio engine (libmcmetal-al)
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
    # our own pack (shaderpack/mcmetal-rt-pack): morning, noon, sunset, night with lights, rain, and on Apple GL
    ours) scene 1500; PACK=mcmetal-rt-pack run_phase ours 180 metal true ;;
    ours-noon) scene noon; PACK=mcmetal-rt-pack run_phase ours-noon 180 metal true ;;
    ours-sunset) scene 12300; PACK=mcmetal-rt-pack run_phase ours-sunset 180 metal true ;;
    ours-night) scene midnight clear showcase; PACK=mcmetal-rt-pack run_phase ours-night 180 metal true ;;
    ours-rain) scene 3000 rain; PACK=mcmetal-rt-pack run_phase ours-rain 180 metal true ;;
    ours-shadow|ours-ao|ours-gi) scene 1500; v=${p#ours-}; v=$( [ $v = shadow ] && echo 1 || ([ $v = ao ] && echo 2 || echo 3))
        PACK_OPTS="DEBUG_VIEW=$v ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase $p 180 metal true ;;  # debug views of the rays
    ours-room) scene noon clear room; PACK=mcmetal-rt-pack run_phase ours-room 180 metal true ;;  # GI test room
    ours-room-gi) scene noon clear room; PACK_OPTS="DEBUG_VIEW=3 ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase ours-room-gi 180 metal true ;;
    ours-room-off) scene noon clear room; PACK_OPTS="RT_GI=false ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase ours-room-off 180 metal true ;;  # GI off
    ours-room-plain) scene noon clear room; PACK_OPTS="COLORED_SHADOWS=false ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase ours-room-plain 180 metal true ;;  # plain mcm_trace shadows
    ours-lights) scene midnight clear showcase; PACK_OPTS="DEBUG_VIEW=3 ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase ours-lights 180 metal true ;;  # GI view: coloured block light + bounce
    ours-pool-night) scene midnight; PACK=mcmetal-rt-pack run_phase ours-pool-night 180 metal true ;;  # torches, soul and redstone lights by the pool
    ours-shafts) scene noon clear room; PACK_OPTS="DEBUG_VIEW=5 ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase ours-shafts 180 metal true ;;  # light shafts only
    ours-puddles) GAME_LOOK="-90 50" scene 3000 rain room; PACK=mcmetal-rt-pack run_phase ours-puddles 180 metal true ;;  # open ground in rain
    ours-puddle-mask) GAME_LOOK="-90 50" scene 3000 rain room; PACK_OPTS="DEBUG_VIEW=6 ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase ours-puddle-mask 180 metal true ;;
    ours-pbr) GAME_LOOK="-90 10" scene 3000 clear pbr; PACK=mcmetal-rt-pack run_phase ours-pbr 180 metal true ;;  # with GAME_RP=labpbr-test
    ours-low|ours-ultra)   # the Low / Ultra presets (shaders.properties profile.LOW / profile.ULTRA) in the test room
        [ $p = ours-low ] && o="RT_GI=false LIGHT_SLOTS=2 LIGHT_SHAFTS=false LIGHT_SHAFTS_STEPS=4 RT_REFLECT_DISTANCE=32.0 RT_GI_DISTANCE=16.0 RT_AO_FRAMES=32.0" \
                          || o="LIGHT_SLOTS=8 LIGHT_SHAFTS_STEPS=12 RT_REFLECT_DISTANCE=256.0 RT_GI_DISTANCE=64.0 RT_AO_FRAMES=32.0"
        scene noon clear room; PACK_OPTS="$o ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase $p 180 metal true ;;
    ours-glass) GAME_LOOK="-90 8" scene 6000 clear glass; PACK=mcmetal-rt-pack run_phase ours-glass 180 metal true ;;  # refraction
    ours-glass-night) GAME_LOOK="-90 35" scene 18000 clear glass; PACK=mcmetal-rt-pack run_phase ours-glass-night 180 metal true ;;  # torch light through stained glass
    ours-glass-off) GAME_LOOK="-90 8" scene 6000 clear glass; PACK_OPTS="GLASS_REFRACTION=false ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase ours-glass-off 180 metal true ;;
    ours-caustics) GAME_LOOK="-90 45" scene 6000 clear pool; PACK=mcmetal-rt-pack run_phase ours-caustics 180 metal true ;;  # deep pool from above
    ours-caustics-mask) GAME_LOOK="-90 45" scene 6000 clear pool; PACK_OPTS="DEBUG_VIEW=7 ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase ours-caustics-mask 180 metal true ;;
    ours-water|ours-water-full)   # the pool at a low angle: water reflections (-full: every pixel traces its own, WATER_REFLECT_HALF off)
        o=; [ $p = ours-water-full ] && o="WATER_REFLECT_HALF=false"
        GAME_LOOK="${GAME_LOOK:--90 6}" scene 6000 clear pool; PACK_OPTS="$o ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase $p 180 metal true ;;
    ours-underwater) GAME_LOOK="-90 -10" scene 6000 clear pool_under; PACK=mcmetal-rt-pack run_phase ours-underwater 180 metal true ;;
    ours-sky) GAME_LOOK="-60 -25" scene 2000; PACK=mcmetal-rt-pack run_phase ours-sky 180 metal true ;;  # clouds
    ours-vista) GAME_TP="${VISTA_TP:-~ 88 ~ 90 10}" scene ${VISTA_TIME:-noon}; PACK=mcmetal-rt-pack run_phase ours-vista 180 metal true ;;  # open land and sky from y 88, away from the test stages (style shots)
    ours-vista-*-*) # ours-vista-<STYLE>-<noon|sunset|night>: one look at one time of day, for style comparisons
        v=${p#ours-vista-}; t=${v#*-}; case $t in sunset) t=12600 ;; night) t=18000 ;; esac
        GAME_TP="${VISTA_TP:-~ 88 ~ 90 10}" scene $t; PACK_OPTS="STYLE=${v%%-*} ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase $p 180 metal true ;;
    ours-season-*) # ours-season-<spring|summer|autumn|winter>[-STYLE]: the vista at noon in the middle of a season (the
                   # pack follows Serene Seasons' calendar from the world's day count: 8-day sub-seasons, from spring)
        v=${p#ours-season-}; sn=${v%%-*}; st=0; [ "$v" != "$sn" ] && st=${v#*-}
        case $sn in spring) d=12 ;; summer) d=36 ;; autumn) d=60 ;; *) d=84 ;; esac
        GAME_TP="${VISTA_TP:-~ 88 ~ 90 10}" scene $((d * 24000 + ${SEASON_TIME:-6000})); PACK_OPTS="STYLE=$st ${PACK_OPTS:-}" PACK=mcmetal-rt-pack run_phase $p 180 metal true ;;
    ours-gl) scene 1500; PACK=mcmetal-rt-pack run_phase ours-gl 180 metal true MCMETAL_DISABLE=1 ;; # shadow-map fallback on Apple GL
    nether) scene noon clear nether; run_phase nether 180 metal false ;;                       # Nether room, Sodium
    nether-shaders) scene noon clear nether; run_phase nether-shaders 240 metal true ;;      # Nether room, Complementary
    dh) dh_phase dh false ;;                    # Distant Horizons, Sodium
    dh-shaders) dh_phase dh-shaders true ;;     # Distant Horizons + Complementary
    dh-ours-high) GAME_TP="${DH_TP:-~ 140 ~ 90 35}" dh_phase "$p" true ours ;;  # from high up, looking down past the near chunks at far water
    dh-*) dh_phase "$p" true "${p#dh-}" ;;      # Distant Horizons + a pack: dh-photon, dh-bliss, dh-ours, ...
    glcount-*) # the pack on Apple's OpenGL through tools/glcount.c, which logs draws and triangles per second (all,
               # and into shadow-map-sized viewports) to glcount.log: what Iris and Sodium draw on real OpenGL
        # (Apple's OpenGL can't make a context on GitHub's runners; on Linux this counts Mesa, the cloud reference rig)
        if [ "$(uname)" = Darwin ]; then
            lib="$WORK/libglcount.dylib"
            clang -dynamiclib -o "$lib" "$SRC/tools/glcount.c" -framework OpenGL -Wl,-reexport_framework,OpenGL
        else
            lib="$WORK/libglcount.so"
            gcc -shared -fPIC -o "$lib" "$SRC/tools/glcount.c" "$(ls /usr/lib/*/libGL.so.1 /usr/lib/libGL.so.1 2>/dev/null | head -1)" -ldl
        fi
        inner=${p#glcount-}
        LIBARGS=(--gl "$lib")
        third_party "$inner" "$p" MCMETAL_DISABLE=1 GLCOUNT_LOG="$OUT/$p/glcount.log"
        LIBARGS=()
        tail -5 "$OUT/$p/glcount.log" 2>/dev/null ;;
    menu|menu-noif|menu-shaders|creative|creative-shaders|creative-scroll|particles) gui_phase "$p" "$p" ;;
    ab-menu|ab-menu-noif|ab-menu-shaders|ab-creative|ab-creative-shaders|ab-particles) # new, old (GAME_AB_OFF's env), new, as for the packs below
        inner=${p#ab-}
        gui_phase "$inner" "$p-new1"
        gui_phase "$inner" "$p-old" ${GAME_AB_OFF:-}
        gui_phase "$inner" "$p-new2" ;;
    ab-*) # A/B in one job (separate jobs run on machines up to ~30% apart): ab-pack-NAME runs the pack with this
          # change (new), with GAME_AB_OFF's env (old, e.g. MGL_TEX_COMPRESS=0), then new again; compare in fps.txt
        inner=${p#ab-}
        third_party "$inner" "$p-new1"
        third_party "$inner" "$p-old" ${GAME_AB_OFF:-}
        third_party "$inner" "$p-new2" ;;
    pack-*|packnight-*|packshadow-*|herd-*) third_party "$p" ;; # compatibility sweep: pack-photon, packnight-bsl, pack-complementary+euphoria, ...
        # packshadow-NAME: night in the shadows room (shadows.mcfunction)
    archive-*) # Metal pipeline binary archive: the pack from an empty shader cache (archive written), again with the
               # archive, and again with the shader cache but no archive. Run with bench=true settle=0 so the fps
               # samples cover the first seconds in the world, where pipeline compiles show up as stalls
        rm -rf "$WORK/cache"
        third_party "pack-${p#archive-}" "$p-cold" MGL_BINARY_ARCHIVE=1
        third_party "pack-${p#archive-}" "$p-warm" MGL_BINARY_ARCHIVE=1
        third_party "pack-${p#archive-}" "$p-warm-noarchive"
        ls -la "$WORK/cache" | tail -3 ;;
    esac
done
[ -z "${CRASHED:-}" ] || { echo "crashed:$CRASHED"; exit 1; }
