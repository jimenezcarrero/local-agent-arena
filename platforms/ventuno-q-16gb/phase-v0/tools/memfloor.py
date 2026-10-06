#!/usr/bin/env python3
"""memfloor.py <run dir>... — per run: min MemAvailable, and min of (MemAvailable + prompt-cache size held at that moment)
over the run window. The second is the memory left for the prompt cache plus everything outside the server (pi, tests).
Cache size over time: the server log's "cache state: N prompts, X MiB" lines (timestamps are minutes.seconds.ms since
server start; server start = run.txt "server pid" line). MemAvailable: ~/bench-runs/monitor/health-*.jsonl (~10 s)."""
import datetime as dt, glob, json, os, re, sys
H = os.path.expanduser("~/bench-runs/monitor")
samples = []
for f in sorted(glob.glob(f"{H}/health-*.jsonl")):
    for line in open(f):
        try:
            r = json.loads(line); samples.append((r["epoch"], r["MemAvailable_kB"] / 2**20))
        except (ValueError, KeyError):
            pass
def ep(s): return dt.datetime.fromisoformat(s).timestamp()
print("run | window | samples | min MemAvailable GiB | min (MemAvailable + cache) GiB | cache at that point GiB | max cache GiB")
for d in sys.argv[1:]:
    run = open(os.path.join(d, "run.txt")).read()
    t0 = ep(re.search(r"^(\S+) server pid", run, re.M).group(1))
    ends = re.findall(r"^(\S+) END", run, re.M); t1 = ep(ends[-1]) if ends else t0 + 3600
    ev = [(0.0, 0.0)]
    for l in open(os.path.join(d, "server.log"), errors="replace"):
        l = re.sub(r"\x1b\[[0-9;]*m", "", l)
        m = re.match(r"(\d+)\.(\d+)\.(\d+)\.(\d+) .*cache state: \d+ prompts, ([\d.]+) MiB", l)
        if m:
            # llama.cpp log timestamp: minutes.seconds.milliseconds.microseconds since start
            secs = int(m.group(1)) * 60 + int(m.group(2)) + int(m.group(3)) / 1000
            ev.append((secs, float(m.group(5)) / 1024))
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
    print(f"{os.path.basename(d)} | {int(t1-t0)} s | {len(win)} | {ma:.2f} | {a2 + cache_at(e2):.2f} | {cache_at(e2):.2f} | {max(v for s, v in ev):.2f}")
