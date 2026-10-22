#!/usr/bin/env python3
"""What the slowest frames were doing: Java, GL calls, waiting in swap, or a JVM pause.

Usage: python3 -I slow_frames.py FRAMES [GC.LOG] [FROM_EPOCH_S TO_EPOCH_S]

FRAMES is glprof's GLPROF_FRAMES file (tools/glprof.h): one line per frame, "end_wall_ms frame_us gl_us swap_us".
GC.LOG is the game's -Xlog:gc,safepoint log (ci_game.sh writes both in bench + profile mode). For the measured
window this prints the typical frame and the slowest 1% of frames split into
  Java (everything on the render thread outside GL calls and swap: game code, Sodium, Iris, and JVM pauses),
  GL (inside mcmetal's GL calls), swap (presenting, waiting for the GPU or a drawable),
how many slow frames overlap a stop-the-world pause, and what dominated each slow frame. If Java dominates the
slow frames and they don't overlap pauses, the hitches are game work (chunk uploads, culling); if they overlap
pauses, GC settings matter; if swap dominates, it's the GPU or presenting.
"""
import datetime
import re
import sys

SAFEPOINT = re.compile(r'^\[([^\]]+)\].*\[safepoint\s*\] Safepoint "([^"]+)".*?Total: (\d+) ns')


def main():
    args = sys.argv[1:]
    frames_path = args.pop(0)
    gc_path = args.pop(0) if args and not re.match(r"^\d+(\.\d+)?$", args[0]) else None
    lo, hi = (float(args[0]), float(args[1])) if len(args) >= 2 else (0, 1e12)
    frames = []  # (start s, end s, frame ms, gl ms, swap ms, java ms)
    for line in open(frames_path, errors="replace"):
        p = line.split()
        if len(p) != 4:
            continue
        end = float(p[0]) / 1000
        if not lo <= end <= hi:
            continue
        f, gl, sw = (int(x) / 1000 for x in p[1:])
        frames.append((end - f / 1000, end, f, gl, sw, max(0.0, f - gl - sw)))
    if len(frames) < 100:
        print(f"only {len(frames)} frames in the window")
        return
    pauses = []  # (start s, end s, ms, reason)
    if gc_path:
        for line in open(gc_path, errors="replace"):
            m = SAFEPOINT.match(line.strip())
            if m:
                t = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S.%f%z").timestamp()
                ms = int(m.group(3)) / 1e6
                pauses.append((t - ms / 1000, t, ms, m.group(2)))
    by_time = sorted(frames, key=lambda x: x[2])
    n = len(by_time)
    cut = by_time[int(n * 0.99)][2]
    slow = [x for x in frames if x[2] >= cut]
    mid = by_time[n // 4:3 * n // 4]

    def avg(rows, i):
        return sum(r[i] for r in rows) / max(1, len(rows))

    print(f"{n} frames; median {by_time[n // 2][2]:.2f} ms, 99th percentile {cut:.2f} ms (1% low {1000 / cut:.1f} fps), "
          f"worst {by_time[-1][2]:.1f} ms")
    for name, rows in (("typical (middle 50%)", mid), (f"slowest 1% ({len(slow)})", slow)):
        print(f"  {name:22s} frame {avg(rows, 2):6.2f} ms = Java {avg(rows, 5):6.2f} + GL {avg(rows, 3):5.2f} + swap {avg(rows, 4):6.2f}")
    dom = {"Java": 0, "GL": 0, "swap": 0}
    in_pause, pause_ms = 0, 0.0
    for s, e, f, gl, sw, j in slow:
        dom[max((("Java", j), ("GL", gl), ("swap", sw)), key=lambda x: x[1])[0]] += 1
        ov = sum(min(e, pe) - max(s, ps) for ps, pe, _, _ in pauses if pe > s and ps < e) * 1000
        if ov > 0.5:
            in_pause += 1
            pause_ms += ov
    print("  slowest 1% dominated by: " + ", ".join(f"{k} {v}" for k, v in dom.items()))
    if gc_path:
        print(f"  slowest 1% overlapping a JVM pause (>0.5 ms of it): {in_pause} of {len(slow)}, "
              f"{pause_ms / max(1, in_pause):.1f} ms of pause each on average")
        typical = sum(1 for s, e, *_ in mid if any(pe > s and ps < e and min(e, pe) - max(s, ps) > 0.0005 for ps, pe, _, _ in pauses))
        print(f"  typical frames overlapping a pause: {typical} of {len(mid)}")


if __name__ == "__main__":
    main()
