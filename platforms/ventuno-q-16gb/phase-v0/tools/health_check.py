#!/usr/bin/env python3
"""health_check.py [minutes=60] — summarise the sampler's last N minutes and flag problems.

Flags: sampler stale (>60s), MemAvailable < 1.5 GiB, swap used, PSI memory full avg10 > 5,
any zone >= 85 C, a CPU policy capped below its hardware max (thermal throttling),
active cooling devices, kernel alert lines or OOM kills. Prints one summary line
plus one line per alert; appends the same to ~/bench-runs/monitor/health-checks.txt.
"""
import glob, json, os, sys, time

mins = float(sys.argv[1]) if len(sys.argv) > 1 else 60
files = sorted(glob.glob(os.path.expanduser("~/bench-runs/monitor/health-*.jsonl")))[-2:]
rows = []
for f in files:
    for line in open(f):
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
cut = time.time() - mins * 60
rows = [r for r in rows if r["epoch"] >= cut]
out = []
if not rows:
    out.append("ALERT no samples in window (sampler down?)")
    summary = f"{time.strftime('%FT%T%z')} window={mins:g}m samples=0"
else:
    last = rows[-1]
    stale = time.time() - last["epoch"]
    gib = lambda k: k / 1048576
    min_avail = min(r["MemAvailable_kB"] for r in rows)
    swap = max(r["SwapTotal_kB"] - r["SwapFree_kB"] for r in rows)
    psi_full = max(r.get("mem_full_avg10", 0) for r in rows)
    tmax = max((v, k, r["ts"]) for r in rows for k, v in r["temp_mC"].items())
    capped = sorted({f"{p}:{c[1]}<{c[2]}" for r in rows for p, c in r["freq_cur_max_hw"].items() if c[1] < c[2]})
    cooling = sorted({k for r in rows for k in r.get("cooling_active", {})})
    kern = sum(r.get("kern_alert_lines_60s", 0) for r in rows)
    ooms = sorted({r["oom"] for r in rows if r.get("oom")})
    procs = {p["cmd"].split()[0].rsplit("/", 1)[-1] for p in last["procs"]}
    summary = (f"{time.strftime('%FT%T%z')} window={mins:g}m samples={len(rows)} last={last['ts']} "
               f"min_avail={gib(min_avail):.2f}GiB swap_max={swap}kB psi_full_max={psi_full} "
               f"tmax={tmax[0]/1000:.1f}C({tmax[1]}) capped={capped or 'none'} cooling={cooling or 'none'} "
               f"kern_alert_lines={kern} procs={sorted(procs) or 'none'}")
    if stale > 60: out.append(f"ALERT sampler stale {stale:.0f}s")
    if min_avail < 1.5 * 1048576: out.append(f"ALERT MemAvailable fell to {gib(min_avail):.2f}GiB")
    if swap > 0: out.append(f"ALERT swap used {swap}kB")
    if psi_full > 5: out.append(f"ALERT memory PSI full avg10 {psi_full}")
    if tmax[0] >= 85000: out.append(f"ALERT {tmax[1]} {tmax[0]/1000:.1f}C at {tmax[2]}")
    if capped: out.append(f"ALERT CPU max frequency capped: {capped}")
    if cooling: out.append(f"NOTE cooling devices active: {cooling}")
    if kern: out.append(f"NOTE {kern} kernel alert lines (inspect journalctl -k)")
    for o in ooms: out.append(f"ALERT OOM: {o}")
import subprocess
base = os.path.expanduser("~/bench-runs/monitor/dpkg-baseline.txt")
cur = subprocess.run(["dpkg-query", "-W", "-f=${Package} ${Version}\n"], capture_output=True, text=True).stdout
if not os.path.exists(base):
    out.append("NOTE no dpkg baseline yet (write one with: dpkg-query -W -f='${Package} ${Version}\\n' > " + base + ")")
elif open(base).read() != cur:
    old, new = set(open(base).read().splitlines()), set(cur.splitlines())
    out.append(f"ALERT packages changed since baseline: -{sorted(old - new)[:8]} +{sorted(new - old)[:8]}")
text = "\n".join([summary] + out)
print(text)
with open(os.path.expanduser("~/bench-runs/monitor/health-checks.txt"), "a") as f:
    f.write(text + "\n")
sys.exit(1 if any(o.startswith("ALERT") for o in out) else 0)
