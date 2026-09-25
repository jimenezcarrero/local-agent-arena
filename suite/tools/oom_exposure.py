#!/usr/bin/env python3
"""Tag every run with the number of OOM kills of llama-server inside its window.

A kill does not automatically void a run — the harness restarts the server and
continues — but a run that overlaps one cannot be read as clean model behavior.
Written after discovering that 78 kills happened during Phase A while only a
handful had been noticed.

Usage: oom_exposure.py [since] [runs-root]
  since      only list runs that started on or after this date (default 2026-09-19)
  runs-root  default ~/bench-runs

A run is reported as oom_kills=unknown, never 0, unless the journal provably
covers its whole window. Coverage is worked out per boot, from the boot clock
(monotonic time) rather than the wall clock, because boards without an RTC
battery stamp their early-boot entries with a stale date: the Jetson's current
boot logs entries dated July 2026, 1970 and the previous shutdown before NTP
corrects it. Run windows come from env.txt, written by the harness long after
boot, when the wall clock is synced.
"""
import datetime, glob, json, os, subprocess, sys, time

since = datetime.datetime.fromisoformat(sys.argv[1] if len(sys.argv) > 1 else "2026-09-19")
root = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/bench-runs")

def jctl(*args, first=False):
    """Journal entries as dicts. first=True returns only the oldest one."""
    p = subprocess.Popen(["journalctl", "-o", "json", *args], stdout=subprocess.PIPE, text=True)
    out = []
    for line in p.stdout:
        out.append(json.loads(line))
        if first:
            p.kill(); break
    p.wait()
    return out

def text(msg):  # MESSAGE is a byte array when it isn't valid UTF-8
    return bytes(msg).decode("utf-8", "replace") if isinstance(msg, list) else (msg or "")

# Each boot's real start = (wall clock − boot clock) at an entry written after
# NTP sync. For the running boot that is /proc/stat's btime; for a past boot,
# its last entry. Coverage runs from the boot's oldest retained entry (the
# journal may have rotated older ones away) to its last entry, or now.
current = open("/proc/sys/kernel/random/boot_id").read().strip().replace("-", "")
btime = next(int(l.split()[1]) for l in open("/proc/stat") if l.startswith("btime"))
boots = {}
res = subprocess.run(["journalctl", "--list-boots", "-o", "json"], capture_output=True, text=True)
for b in (json.loads(res.stdout) if res.returncode == 0 and res.stdout.strip() else []):
    bid = b["boot_id"]
    if bid == current:
        start, end = float(btime), time.time()
    else:
        last = jctl("-b", bid, "-n", "1")
        if not last:
            continue
        rt, mono = int(last[0]["__REALTIME_TIMESTAMP"]), int(last[0]["__MONOTONIC_TIMESTAMP"])
        start, end = (rt - mono) / 1e6, rt / 1e6
    oldest = jctl("-b", bid, first=True)
    if not oldest:
        continue
    cov_from = start + int(oldest[0]["__MONOTONIC_TIMESTAMP"]) / 1e6
    boots[bid] = (start, cov_from, end)
if current not in boots:
    sys.exit("ERROR: no journal entries for the running boot. Kill exposure is UNKNOWN, not zero.")

kills = []  # kill time = the boot's real start + the entry's boot-clock offset
for e in jctl("_TRANSPORT=kernel"):
    m = text(e.get("MESSAGE"))
    if "Killed process" in m and "llama-server" in m and e.get("_BOOT_ID") in boots:
        kills.append(boots[e["_BOOT_ID"]][0] + int(e["__MONOTONIC_TIMESTAMP"]) / 1e6)

def covered(t0, t1):
    return any(cf <= t0 and t1 <= end for _, cf, end in boots.values())

rows = []
for d in sorted(glob.glob(f"{root}/arena*/*/")):
    env = os.path.join(d, "env.txt")
    if not os.path.exists(env):
        continue
    start = next((datetime.datetime.fromisoformat(l.split("date: ")[1].strip().split("+")[0])
                  for l in open(env) if l.startswith("date: ")), None)
    if not start or start < since:
        continue
    files = [os.path.join(d, f) for f in os.listdir(d) if os.path.isfile(os.path.join(d, f))]
    t0, t1 = start.timestamp(), max(os.path.getmtime(f) for f in files)
    n = sum(1 for k in kills if t0 <= k <= t1) if covered(t0, t1) else None
    rows.append((os.path.basename(d.rstrip("/")), n, start.strftime("%m-%d %H:%M")))

fmt = lambda t: datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M")
unknown = [r for r in rows if r[1] is None]
print(f"# OOM kills of llama-server per run ({len(kills)} kills found)")
for bid, (_, cf, end) in sorted(boots.items(), key=lambda kv: kv[1][1]):
    print(f"# journal covers {fmt(cf)} .. {fmt(end)}  (boot {bid[:8]}{', running' if bid == current else ''})")
print(f"# persistent journal: {os.path.isdir('/var/log/journal')}")
print(f"# {sum(1 for r in rows if r[1])} of {len(rows)} runs overlapped a kill; "
      f"{len(unknown)} outside the covered interval -> unknown")
for label, n, start in rows:
    print(f"{label:<34} oom_kills={'unknown' if n is None else n:<8} start={start}")
if unknown:
    sys.exit(f"\nERROR: {len(unknown)} of {len(rows)} runs fall outside the journal's "
             f"coverage; their exposure is unknown, not zero. Treat those runs as "
             f"unattributed, or re-run the audit on a host whose journal covers them.")
