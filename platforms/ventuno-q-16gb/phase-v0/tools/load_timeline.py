#!/usr/bin/env python3
"""load_timeline.py — every ggml-hexagon server load since the 03:24 recovery, in order: start time, label, model,
sessions, strict pinning, outcome (ok / mapfail <domain> <size> / hang / other). From each run's run.txt + server.log."""
import glob, os, re
H = os.path.expanduser("~/bench-runs/v0")
rows = []
for d in glob.glob(f"{H}/v0d-*/*/"):
    try:
        run = open(d + "run.txt", errors="replace").read()
    except OSError:
        continue
    m = re.search(r"^(\S+) PROBE", run, re.M) or re.search(r"^(\S+) ", run, re.M)
    cmd = re.search(r"SERVER (.*)", run)
    if not (m and cmd) or "llama-server" not in cmd.group(1) or "hexpkg" not in cmd.group(1):
        continue
    t = m.group(1)
    if t < "2026-10-06T03:20":
        continue
    c = cmd.group(1)
    log = open(d + "server.log", errors="replace").read() if os.path.exists(d + "server.log") else ""
    mf = re.search(r"mapping failed[^:]*: domain_id (\d+) size (\d+)", log)
    end = re.findall(r"^(\S+) END", run, re.M)
    if mf:
        out = f"mapfail d{mf.group(1)} {int(mf.group(2))/2**20:.0f}MiB"
    elif "WATCHDOG" in run or os.path.exists(d + "stall-diagnosis.txt") or re.search(r"RESULT FAIL: speed=1", run):
        out = "HANG/stall"
    elif "RESULT PASS" in run:
        out = "ok"
    else:
        out = "other: " + (re.findall(r"RESULT (.*)", run) or ["?"])[-1][:40]
    model = "9B" if "Ornith" in c else "4B"
    ses = len(re.search(r"--device (\S+)", c).group(1).split(","))
    strict = "strict" if "--cpu-strict 1" in c else ""
    ctx = re.search(r"-c (\d+)", c).group(1)
    rows.append((t, os.path.basename(d.rstrip("/")), os.path.basename(os.path.dirname(d.rstrip("/"))), model, ses, ctx, strict, out, end[-1] if end else ""))
rows.sort()
print("# start | phase/label | model sessions ctx pinning | outcome | end")
for r in rows:
    print(f"{r[0][11:19]} | {r[2]}/{r[1]} | {r[3]} {r[4]}s {r[5]} {r[6]} | {r[7]} | {r[8][11:19]}")
