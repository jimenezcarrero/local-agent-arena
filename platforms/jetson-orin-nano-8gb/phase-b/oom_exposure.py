#!/usr/bin/env python3
"""Tag every run with the number of OOM kills of llama-server inside its window.

A kill does not automatically void a run — the harness restarts the server and
continues — but a run that overlaps one cannot be read as clean model behavior.
Written after discovering that 78 kills happened during Phase A while only a
handful had been noticed.
"""
import glob, os, subprocess, datetime, sys

since = sys.argv[1] if len(sys.argv) > 1 else "2026-09-19"
root = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/bench-runs")
out = subprocess.run(["journalctl", "-k", "--since", since, "-o", "short-iso"],
                     capture_output=True, text=True).stdout
kills = [datetime.datetime.fromisoformat(l.split()[0].split("+")[0])
         for l in out.splitlines() if "Killed process" in l and "llama-server" in l]

rows = []
for d in sorted(glob.glob(f"{root}/arena*/*/")):
    env = os.path.join(d, "env.txt")
    if not os.path.exists(env):
        continue
    start = next((datetime.datetime.fromisoformat(l.split("date: ")[1].strip().split("+")[0])
                  for l in open(env) if l.startswith("date: ")), None)
    if not start:
        continue
    files = [os.path.join(d, f) for f in os.listdir(d) if os.path.isfile(os.path.join(d, f))]
    end = datetime.datetime.fromtimestamp(max(os.path.getmtime(f) for f in files))
    n = sum(1 for k in kills if start <= k <= end)
    rows.append((os.path.basename(d.rstrip("/")), n, start.strftime("%m-%d %H:%M")))

print(f"# OOM kills of llama-server per run ({len(kills)} kills since {since})")
print(f"# {sum(1 for r in rows if r[1])} of {len(rows)} runs overlapped at least one kill")
for label, n, start in rows:
    print(f"{label:<34} oom_kills={n:<3} start={start}")
