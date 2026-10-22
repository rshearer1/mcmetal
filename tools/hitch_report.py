#!/usr/bin/env python3
"""What the game was doing during each hitch: one long frame, frame by frame.

Usage: python3 -I hitch_report.py JFR_TOOL RECORDING.jfr FRAMES GC.LOG FROM_EPOCH_S TO_EPOCH_S [MIN_MS]

FRAMES is glprof's GLPROF_FRAMES file ("end_wall_ms frame_us gl_us swap_us" per frame), GC.LOG the game's
-Xlog:gc,safepoint log, the recording a Java Flight Recorder file from the same run (ci_game.sh writes all three
with GAME_BENCH=true GAME_PROFILE=true). For the worst frames in the window that took MIN_MS (default 50) or more,
at most 5, this prints:
  - when it was (seconds into the window) and its split into Java / GL / swap (as tools/slow_frames.py),
  - JVM pauses overlapping it,
  - the render thread's samples inside the frame (Java running or inside a native call), as short stacks,
  - where the render thread was blocked inside the frame (waiting for a lock, parked, sleeping: JFR records
    those over ~10-20 ms with the "profile" settings), with the lock's class and the stack,
  - what every other thread was running at the same time (Java samples by thread, top method).
slow_frames.py says what the slowest 1% are made of on average; this says what one rare long frame was.
Only method and class names are printed: the recording itself (it also holds the environment) is never uploaded.
"""
import collections
import datetime
import re
import subprocess
import sys
import time

SAFEPOINT = re.compile(r'^\[([^\]]+)\].*\[safepoint\s*\] Safepoint "([^"]+)".*?Total: (\d+) ns')
EVENTS = ("jdk.ExecutionSample,jdk.NativeMethodSample,jdk.JavaMonitorEnter,jdk.JavaMonitorWait,jdk.ThreadPark,"
          "jdk.ThreadSleep")
RENDER = ("Render thread", "main")  # on macOS the render thread is the JVM's main thread (-XstartOnFirstThread)


def ts(s):  # "09:04:51.123 (2026-10-22)", the machine's local time
    t, d = s.split(" (")
    return time.mktime(time.strptime(d.rstrip(")") + " " + t.split(".")[0], "%Y-%m-%d %H:%M:%S")) + float("0." + t.split(".")[1])


def dur(s):  # "21.5 ms", "1.20 s", "523 us"
    n, unit = (s.split() + ["s"])[:2]
    try:
        return float(n.replace(",", "")) / {"ns": 1e9, "us": 1e6, "ms": 1e3, "s": 1, "m": 1 / 60}.get(unit, 1)
    except ValueError:
        return 0.0


def events(tool, rec):
    """(type, start epoch s, duration s, thread, [method names, top first], class) per event, streamed."""
    p = subprocess.Popen([tool, "print", "--stack-depth", "24", "--events", EVENTS, rec],
                         stdout=subprocess.PIPE, text=True, errors="replace")
    ev = None
    in_stack = False
    for line in p.stdout:
        line = line.strip()
        if line.endswith("{") and line.startswith("jdk."):
            ev, in_stack = {"type": line.split()[0], "start": None, "dur": 0.0, "thread": "?", "frames": [], "cls": ""}, False
        elif ev is None:
            continue
        elif line.startswith("startTime = "):
            ev["start"] = ts(line[len("startTime = "):])
        elif line.startswith("duration = "):
            ev["dur"] = dur(line[len("duration = "):])
        elif line.startswith("sampledThread = ") or line.startswith("eventThread = "):
            ev["thread"] = line.split('"')[1] if '"' in line else line
        elif line.startswith(("monitorClass = ", "parkedClass = ")):
            ev["cls"] = line.split(" = ", 1)[1].split(" (")[0]
        elif line.startswith("stackTrace = ["):
            in_stack = True
        elif in_stack and line == "]":
            in_stack = False
        elif in_stack and "(" in line:
            ev["frames"].append(line.split("(")[0])
        elif line == "}":
            if ev["start"] is not None:
                yield ev
            ev = None
    p.wait()


def short(frames, n=6):
    """The top of a stack without JDK/LWJGL plumbing, top first."""
    keep = [f for f in frames if not f.startswith(("java.", "jdk.", "sun."))] or frames
    return " <- ".join(f.rsplit(".", 2)[-2] + "." + f.rsplit(".", 1)[-1] if f.count(".") > 1 else f for f in keep[:n])


def main():
    tool, rec, frames_path, gc_path = sys.argv[1:5]
    lo, hi = float(sys.argv[5]), float(sys.argv[6])
    min_ms = float(sys.argv[7]) if len(sys.argv) > 7 else 50.0
    frames = []  # (start s, end s, frame ms, gl ms, swap ms)
    for line in open(frames_path, errors="replace"):
        p = line.split()
        if len(p) != 4:
            continue
        end = float(p[0]) / 1000
        if lo <= end <= hi:
            f, gl, sw = (int(x) / 1000 for x in p[1:])
            frames.append((end - f / 1000, end, f, gl, sw))
    long_ = sorted((x for x in frames if x[2] >= min_ms), key=lambda x: -x[2])[:5]
    print(f"{len(frames)} frames in the window, {sum(1 for x in frames if x[2] >= min_ms)} of {min_ms:.0f} ms or more")
    if not long_:
        return
    long_.sort()
    pauses = []
    for line in open(gc_path, errors="replace"):
        m = SAFEPOINT.match(line.strip())
        if m:
            t = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S.%f%z").timestamp()
            ms = int(m.group(3)) / 1e6
            pauses.append((t - ms / 1000, t, ms, m.group(2)))
    # one pass over the recording, events sorted into the frames they overlap
    per = [{"render": collections.Counter(), "blocked": [], "others": collections.defaultdict(collections.Counter),
            "n_render": 0} for _ in long_]
    for ev in events(tool, rec):
        s, e = ev["start"], ev["start"] + ev["dur"]
        for i, (fs, fe, *_rest) in enumerate(long_):
            if e < fs or s > fe:
                continue
            r = per[i]
            if ev["type"] in ("jdk.ExecutionSample", "jdk.NativeMethodSample"):
                if ev["thread"] in RENDER:
                    r["n_render"] += 1
                    kind = "Java" if ev["type"] == "jdk.ExecutionSample" else "native"
                    r["render"][f"{kind}: {short(ev['frames'])}"] += 1
                elif ev["type"] == "jdk.ExecutionSample" and ev["frames"]:
                    r["others"][re.sub(r"\d+", "#", ev["thread"])][short(ev["frames"], 2)] += 1
            elif ev["thread"] in RENDER:
                ov = (min(e, fe) - max(s, fs)) * 1000
                r["blocked"].append((ov, ev["dur"] * 1000, ev["type"][4:], ev["cls"], short(ev["frames"], 8)))
    for (fs, fe, f, gl, sw), r in zip(long_, per):
        print(f"\n=== frame at {fs - lo:.2f} s: {f:.1f} ms = Java {max(0.0, f - gl - sw):.1f} + GL {gl:.1f} + swap {sw:.1f}")
        for ps, pe, ms, why in pauses:
            if pe > fs and ps < fe:
                print(f"  JVM pause {why}: {ms:.1f} ms ({(min(fe, pe) - max(fs, ps)) * 1000:.1f} ms inside the frame)")
        print(f"  render thread: {r['n_render']} samples")
        for k, n in r["render"].most_common(8):
            print(f"    {n:3d}  {k}")
        for ov, d, typ, cls, st in sorted(r["blocked"], reverse=True)[:5]:
            print(f"  render thread blocked {ov:.1f} ms of the frame ({typ} {d:.1f} ms{', ' + cls if cls else ''}): {st}")
        busy = sorted(r["others"].items(), key=lambda kv: -sum(kv[1].values()))[:8]
        if busy:
            print("  other threads running Java meanwhile:")
            for th, c in busy:
                top, n = c.most_common(1)[0]
                print(f"    {th}: {sum(c.values())} samples, mostly {top} ({n})")


if __name__ == "__main__":
    main()
