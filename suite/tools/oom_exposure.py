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
res = subprocess.run(["journalctl", "-k", "--since", since, "-o", "short-iso"],
                     capture_output=True, text=True)
lines = res.stdout.splitlines()
kills = [datetime.datetime.fromisoformat(l.split()[0].split("+")[0])
         for l in lines if "Killed process" in l and "llama-server" in l]

# What the journal can actually answer for. journalctl is boot-scoped, and
# without /var/log/journal a reboot destroys the history, so a non-empty journal
# says nothing about whether it covers a given run: a log that starts after the
# run ended would otherwise report "0 kills" for it. Coverage is the interval
# the kernel log really spans, and every run is checked against it.
def stamp(line):
    try:
        return datetime.datetime.fromisoformat(line.split()[0].split("+")[0])
    except (ValueError, IndexError):
        return None

stamps = [t for t in (stamp(l) for l in lines) if t]
if res.returncode != 0 or not stamps:
    sys.exit(f"ERROR: no readable kernel log since {since} (rc={res.returncode}). "
             f"Kill exposure is UNKNOWN, not zero.")
cov_start, cov_end = min(stamps), max(stamps)
persistent = os.path.isdir("/var/log/journal")

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
    covered = cov_start <= start and end <= cov_end
    n = sum(1 for k in kills if start <= k <= end) if covered else None
    rows.append((os.path.basename(d.rstrip("/")), n, start.strftime("%m-%d %H:%M")))

unknown = [r for r in rows if r[1] is None]
print(f"# OOM kills of llama-server per run ({len(kills)} kills found)")
print(f"# kernel log covers {cov_start:%Y-%m-%d %H:%M} .. {cov_end:%Y-%m-%d %H:%M}"
      f"  (persistent journal: {persistent})")
print(f"# {sum(1 for r in rows if r[1])} of {len(rows)} runs overlapped a kill; "
      f"{len(unknown)} outside the covered interval -> unknown")
for label, n, start in rows:
    val = "unknown" if n is None else str(n)
    print(f"{label:<34} oom_kills={val:<8} start={start}")
if unknown:
    sys.exit(f"\nERROR: {len(unknown)} of {len(rows)} runs fall outside the kernel "
             f"log's interval; their exposure is unknown, not zero. Treat those runs "
             f"as unattributed, or re-run the audit on a host whose journal covers them.")
