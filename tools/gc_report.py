#!/usr/bin/env python3
"""How much the JVM stopped the game in a time window, from a -Xlog:gc,safepoint log.

Usage: python3 -I gc_report.py GC.LOG [FROM_EPOCH_S TO_EPOCH_S]

The game is launched with -Xlog:gc,safepoint:file=GC.LOG:time,uptimemillis,level,tags (ci_game.sh does this in
bench mode). Every stop-the-world pause is a safepoint, whichever collector is in use, so the safepoint lines are
the honest measure of how long all Java threads (the render thread too) were frozen. This prints:
  - the collector, and the collections in the window by kind (G1 "Pause Young (Normal)", ZGC "Minor Collection"...),
  - pauses: count, total ms (and ms per second), worst, 99th percentile, how many over 2, 10 and 50 ms,
    and which safepoint reasons cost the most,
  - ZGC allocation stalls (a thread waiting for memory: a hitch even though ZGC's pauses are tiny),
  - allocation rate (MB/s) from the heap before/after each collection, and the heap after the last one.
"""
import collections
import datetime
import re
import sys

LINE = re.compile(r"^\[([^\]]+)\]\[(\d+)ms\]\[\w+\]\[([\w,\s]+?)\s*\] (.*)$")
SAFEPOINT = re.compile(r'Safepoint "([^"]+)".*?Total: (\d+) ns')
HEAP = re.compile(r"(\d+)M(?:\(\d+%\))?->(\d+)M")
STALL = re.compile(r"Allocation Stall \(([^)]*)\) ([\d.]+)ms")
KIND = re.compile(r"GC\(\d+\) (.+?)(?: \d+M| [\d.]+m?s$|$)")


def epoch(s):  # "2026-10-22T14:15:01.096+0000"
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f%z").timestamp()


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else 0.0


def main():
    path = sys.argv[1]
    lo = float(sys.argv[2]) if len(sys.argv) > 3 else 0
    hi = float(sys.argv[3]) if len(sys.argv) > 3 else 1e12
    collector, kinds, pauses, reasons = "?", collections.Counter(), [], collections.Counter()
    stalls, allocated, last_after, t_first, t_last, heap_after = [], 0, None, None, None, None
    for line in open(path, errors="replace"):
        m = LINE.match(line.strip())
        if not m:
            continue
        t, tags, msg = epoch(m.group(1)), m.group(3), m.group(4)
        if msg.startswith("Using "):
            collector = msg[len("Using "):]
        h = HEAP.search(msg) if tags == "gc" else None
        if h:  # a finished collection: what was allocated since the previous one ended
            before, after = int(h.group(1)), int(h.group(2))
            if lo <= t <= hi and last_after is not None:
                allocated += max(0, before - last_after)
                t_first, t_last = t_first or t, t
            last_after, heap_after = after, after
        if not lo <= t <= hi:
            continue
        if tags == "safepoint":
            s = SAFEPOINT.search(msg)
            if s:
                ms = int(s.group(2)) / 1e6
                pauses.append(ms)
                reasons[s.group(1)] += ms
        elif tags == "gc":
            st = STALL.search(msg)
            if st:
                stalls.append((st.group(1), float(st.group(2))))
            elif h:
                k = KIND.search(msg)
                kinds[k.group(1) if k else msg] += 1
    secs = hi - lo if hi < 1e12 else max(1.0, (t_last or 1) - (t_first or 0))
    print(f"collector: {collector}; window {secs:.0f} s")
    print("collections: " + (", ".join(f"{n} x {k}" for k, n in kinds.most_common()) or "none"))
    tot = sum(pauses)
    print(f"pauses (all safepoints): {len(pauses)}, total {tot:.1f} ms ({tot / secs:.2f} ms/s), worst {max(pauses, default=0):.2f} ms, "
          f"p99 {pct(pauses, 0.99):.2f} ms, over 2 ms {sum(p > 2 for p in pauses)}, over 10 ms {sum(p > 10 for p in pauses)}, "
          f"over 50 ms {sum(p > 50 for p in pauses)}")
    for r, ms in reasons.most_common(5):
        print(f"  {ms:8.1f} ms  {r}")
    if stalls:
        by = collections.Counter()
        for th, ms in stalls:
            by[th] += ms
        print(f"allocation stalls: {len(stalls)}, total {sum(ms for _, ms in stalls):.1f} ms, worst {max(ms for _, ms in stalls):.1f} ms; "
              + ", ".join(f"{th} {ms:.1f} ms" for th, ms in by.most_common(4)))
    else:
        print("allocation stalls: none")
    span = (t_last - t_first) if t_first and t_last and t_last > t_first else 0
    print(f"allocation: {allocated} MB in the window" + (f" (~{allocated / span:.0f} MB/s)" if span else "")
          + (f"; heap after last collection {heap_after} MB" if heap_after is not None else ""))


if __name__ == "__main__":
    main()
