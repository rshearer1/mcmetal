#!/usr/bin/env python3
"""Where the game's render thread spends its CPU time, from a Java Flight Recorder file.

Usage: python3 -I jfr_report.py JFR_TOOL RECORDING.jfr [FROM_EPOCH_S TO_EPOCH_S] [THREAD]

JFR samples Java threads every ~10 ms (jdk.ExecutionSample: running Java code) and threads that are inside native
code every ~20 ms (jdk.NativeMethodSample: e.g. inside a GL call, i.e. in mcmetal). This prints, for one thread
(default "Render thread"):
  - share of samples by mod (first Iris/Sodium/NeoForge/Minecraft frame from the top of the stack),
  - the hottest methods where Java was itself running (self time),
  - the hottest methods anywhere on the stack (inclusive), Iris and Sodium only,
  - for native samples: which GL function, and which Iris/Sodium/Minecraft method called it.
Only aggregated method names are printed: the recording itself (it also holds the environment) is never uploaded.
"""
import collections
import subprocess
import sys
import time

MODS = [("net.irisshaders.", "Iris"), ("net.coderbot.", "Iris"), ("net.caffeinemc.", "Sodium"),
        ("me.jellysquid.", "Sodium"), ("net.neoforged.", "NeoForge"), ("net.minecraft.", "Minecraft"),
        ("com.mojang.blaze3d.", "Minecraft (blaze3d)"), ("com.mojang.", "Minecraft"), ("org.lwjgl.", "LWJGL"),
        ("java.", "JDK"), ("jdk.", "JDK"), ("sun.", "JDK")]


def mod_of(name):
    for p, m in MODS:
        if name.startswith(p):
            return m
    return "other"


def ts(s):  # "09:04:51.123 (2026-10-22)", the machine's local time
    t, d = s.split(" (")
    return time.mktime(time.strptime(d.rstrip(")") + " " + t.split(".")[0], "%Y-%m-%d %H:%M:%S")) + float("0." + t.split(".")[1])


def samples(tool, rec):
    """(type, start epoch s, thread name, [method names, top first]) per sample, streamed from jfr's text output:
    a long recording's JSON would not fit in memory."""
    p = subprocess.Popen([tool, "print", "--stack-depth", "64", "--events", "jdk.ExecutionSample,jdk.NativeMethodSample",
                          rec], stdout=subprocess.PIPE, text=True, errors="replace")
    typ = start = thread = None
    frames, in_stack = [], False
    for line in p.stdout:
        line = line.strip()
        if line.endswith("{") and line.startswith("jdk."):
            typ, start, thread, frames, in_stack = line.split()[0], None, None, [], False
        elif line.startswith("startTime = "):
            start = ts(line[len("startTime = "):])
        elif line.startswith("sampledThread = "):
            thread = line.split('"')[1] if '"' in line else line
        elif line.startswith("stackTrace = ["):
            in_stack = True
        elif in_stack and line == "]":
            in_stack = False
        elif in_stack and "(" in line:
            frames.append(line.split("(")[0])
        elif line == "}" and typ:
            yield typ, start, thread, frames
            typ = None
    p.wait()


def main():
    tool, rec = sys.argv[1], sys.argv[2]
    lo = float(sys.argv[3]) if len(sys.argv) > 4 else 0
    hi = float(sys.argv[4]) if len(sys.argv) > 4 else 1e12
    thread = sys.argv[5] if len(sys.argv) > 5 else "Render thread"
    exec_self, exec_incl, exec_mod = collections.Counter(), collections.Counter(), collections.Counter()
    nat_fn, nat_caller, nat_mod = collections.Counter(), collections.Counter(), collections.Counter()
    n_exec = n_nat = 0
    seen, t_lo, t_hi = collections.Counter(), None, None  # to say why nothing matched
    for typ, start, th, names in samples(tool, rec):
        seen[th] += 1
        if start is not None:
            t_lo, t_hi = min(t_lo or start, start), max(t_hi or start, start)
        if th != thread or not names or start is None or not lo <= start <= hi:
            continue
        first_mod = next((mod_of(n) for n in names if mod_of(n) not in ("JDK", "LWJGL", "other")), "other")
        if typ == "jdk.ExecutionSample":
            n_exec += 1
            exec_self[names[0]] += 1
            for n in set(names):
                if mod_of(n) in ("Iris", "Sodium"):
                    exec_incl[n] += 1
            exec_mod[first_mod] += 1
        else:
            n_nat += 1
            nat_fn[names[0]] += 1
            caller = next((n for n in names if mod_of(n) not in ("JDK", "LWJGL", "other")), names[-1])
            nat_caller[f"{names[0].rsplit('.', 1)[1]}  <-  {caller}"] += 1
            nat_mod[first_mod] += 1

    def table(title, c, total, top=25):
        print(f"\n{title} ({total} samples)")
        for k, n in c.most_common(top):
            print(f"  {100 * n / max(total, 1):5.1f}%  {k}")

    print(f"thread '{thread}': {n_exec} Java samples (running Java), {n_nat} native samples (inside native code)")
    if not n_exec + n_nat:
        print(f"nothing matched: {sum(seen.values())} samples in the recording, from {t_lo} to {t_hi} (window {lo} to {hi});"
              f" busiest threads: {seen.most_common(8)}")
    table("Java running, by mod (first mod frame from the top)", exec_mod, n_exec)
    table("Java running, hottest methods (self)", exec_self, n_exec)
    table("Java running, Iris and Sodium methods on the stack (inclusive)", exec_incl, n_exec)
    table("Inside native code, by mod that called it", nat_mod, n_nat)
    table("Inside native code, by native function", nat_fn, n_nat)
    table("Inside native code, function <- calling method", nat_caller, n_nat, 40)


if __name__ == "__main__":
    main()
