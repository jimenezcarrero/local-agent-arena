#!/usr/bin/env python3
"""memfloor_transient.py <run dir>... — largest drop of MemAvailable between consecutive health samples after the model
load (first 60 s skipped) that the prompt cache does not explain (cache events within +-3 s are netted out).
Inputs as memfloor.py (MONITOR_DIR for the published health-*-runs.jsonl; server.log or server.log.txt).
Limitation: samples are ~11 s apart, so this does not bound excursions shorter than the sampling interval."""
import datetime as dt, glob, json, os, re, sys
H = os.environ.get("MONITOR_DIR", os.path.expanduser("~/bench-runs/monitor"))
S, seen = [], set()
for f in sorted(glob.glob(f"{H}/health-*-runs.jsonl")) or sorted(glob.glob(f"{H}/health-2*.jsonl")):
    for l in open(f):
        try:
            r = json.loads(l)
        except ValueError:
            continue
        if "MemAvailable_kB" in r and r["epoch"] not in seen:
            seen.add(r["epoch"]); S.append((r["epoch"], r["MemAvailable_kB"]))
S.sort(); tol = 3; worst = (0, None, 0)
for d in sys.argv[1:]:
    run = open(d + "/run.txt").read()
    t0 = dt.datetime.fromisoformat(re.search(r"^(\S+) server pid", run, re.M).group(1)).timestamp()
    t1 = dt.datetime.fromisoformat(re.findall(r"^(\S+) END", run, re.M)[-1]).timestamp()
    ev = [(0, 0.0)]
    slog = d + "/server.log"; slog = slog if os.path.exists(slog) else slog + ".txt"
    for l in open(slog, errors="replace"):
        l = re.sub(r"\x1b\[[0-9;]*m", "", l)
        m = re.match(r"(\d+)\.(\d+)\.(\d+)\.\d+ .*cache state: \d+ prompts, ([\d.]+) MiB", l)
        if m:
            ev.append((t0 + int(m.group(1)) * 60 + int(m.group(2)) + int(m.group(3)) / 1000, float(m.group(4)) * 1024))
    ev.sort(); ca = lambda t: [v for s, v in ev if s <= t][-1]
    w = [(e, a) for e, a in S if t0 + 60 <= e <= t1]
    for (e1, a1), (e2, a2) in zip(w, w[1:]):
        drop = (a1 - a2) - ((ca(e2 + tol) - ca(e1 - tol)) if any(e1 - tol <= s <= e2 + tol for s, _ in ev[1:]) else 0)
        if drop > worst[0]:
            worst = (drop, os.path.basename(d), e2 - e1)
print(f"largest unexplained drop: {worst[0]:.0f} kB ({worst[0]/2**20:.3f} GiB) in {worst[1]} over {worst[2]:.0f} s")
