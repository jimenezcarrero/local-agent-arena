#!/usr/bin/env python3
"""memfloor.py [--admit CACHE_MIB] <run dir>... — per run: min MemAvailable, and min of (MemAvailable + prompt-cache size held at that moment)
over the run window. The second is the memory left for the prompt cache plus everything outside the server (pi, tests).
Cache size over time: the server log's "cache state: N prompts, X MiB" lines (timestamps are minutes.seconds.ms since
server start; server start = run.txt "server pid" line). MemAvailable: ~/bench-runs/monitor/health-*.jsonl (~10 s)."""
import datetime as dt, glob, json, os, re, sys
# Inputs: raw samples from ~/bench-runs/monitor/health-<date>.jsonl, or (MONITOR_DIR=<repo phase-v0>/monitor) the
# published health-<date>-runs.jsonl, which keep every raw sample inside each registered run window +-120 s.
H = os.environ.get("MONITOR_DIR", os.path.expanduser("~/bench-runs/monitor"))
samples = []
files = sorted(glob.glob(f"{H}/health-*-runs.jsonl")) or sorted(glob.glob(f"{H}/health-2*.jsonl"))
seen = set()
for f in files:
    for line in open(f):
        try:
            r = json.loads(line)
            if r["epoch"] in seen: continue
            seen.add(r["epoch"]); samples.append((r["epoch"], r["MemAvailable_kB"]))
        except (ValueError, KeyError):
            pass
def ep(s): return dt.datetime.fromisoformat(s).timestamp()
ADMIT = None
if sys.argv[1:2] == ["--admit"]:
    ADMIT = int(sys.argv[2]); sys.argv[1:3] = []
# Admission (D65): L_min >= --cache-ram + 0.33 GiB, compared in kB without rounding (Codex review 08:38Z).
ALLOW_KB = 0.33 * 2**20
if ADMIT is None: print("run | window | samples | min MemAvailable GiB | min (MemAvailable + cache) GiB | cache at that point GiB | max cache GiB")
for d in sys.argv[1:]:
    run = open(os.path.join(d, "run.txt")).read()
    t0 = ep(re.search(r"^(\S+) server pid", run, re.M).group(1))
    ends = re.findall(r"^(\S+) END", run, re.M); t1 = ep(ends[-1]) if ends else t0 + 3600
    ev = [(0.0, 0.0)]
    slog = os.path.join(d, "server.log")
    slog = slog if os.path.exists(slog) else slog + ".txt"   # committed copies are server.log.txt
    for l in open(slog, errors="replace"):
        l = re.sub(r"\x1b\[[0-9;]*m", "", l)
        m = re.match(r"(\d+)\.(\d+)\.(\d+)\.(\d+) .*cache state: \d+ prompts, ([\d.]+) MiB", l)
        if m:
            # llama.cpp log timestamp: minutes.seconds.milliseconds.microseconds since start
            secs = int(m.group(1)) * 60 + int(m.group(2)) + int(m.group(3)) / 1000
            ev.append((secs, float(m.group(5)) * 1024))
    ev.sort()
    def cache_at(t):
        c = 0.0
        for s, v in ev:
            if t0 + s <= t: c = v
        return c
    win = [(e, a) for e, a in samples if t0 <= e <= t1]
    if not win:
        print(f"{os.path.basename(d)} | no samples"); continue
    ma = min(a for e, a in win)
    e2, a2 = min(win, key=lambda x: x[1] + cache_at(x[0]))
    L = a2 + cache_at(e2); G = 2**20
    if ADMIT is not None:
        need = ADMIT * 1024 + ALLOW_KB
        ok = L >= need
        print(f"{'ADMIT' if ok else 'REJECT'} {os.path.basename(d)} L_min_kB={L:.0f} required_kB={need:.0f} (cache {ADMIT} MiB + 0.33 GiB)")
        sys.exit(0 if ok else 1)
    print(f"{os.path.basename(d)} | {int(t1-t0)} s | {len(win)} | {ma/G:.2f} | {L/G:.2f} | {cache_at(e2)/G:.2f} | {max(v for s, v in ev)/G:.2f}")
