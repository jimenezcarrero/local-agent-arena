#!/usr/bin/env python3
"""Tag every run with the number of OOM kills of llama-server inside its window.

A kill does not automatically void a run — the harness restarts the server and
continues — but a run that overlaps one cannot be read as clean model behavior.
Written after discovering that 78 kills happened during Phase A while only a
handful had been noticed.

Usage: oom_exposure.py [since] [runs-root]
  since      only list runs that started on or after this date (default
             2026-09-19; without a UTC offset it is read in this machine's zone)
  runs-root  default ~/bench-runs

A run gets oom_kills=0 only when the kernel log provably covers its whole
window. Anything short of that is `unknown`, and the tool exits non-zero:

- Every journal query must succeed. A failed query is an error, never "no kills".
- Coverage comes from kernel entries in the *system* journal. An account that
  can read only its own user journal sees boots and entries but no kernel
  history; a boot with no readable kernel entries covers nothing, and if the
  running boot has none the audit stops (add the account to `adm` or
  `systemd-journal`).
- Times come from the boot clock (monotonic time), not the wall clock: boards
  without an RTC battery stamp early-boot entries with stale dates (the
  Jetson's boot logs entries dated July 2026 and 1970 before NTP syncs). A
  boot's real start is (wall time − boot-clock offset) of an entry written
  after sync: /proc/stat's btime for the running boot, the last entry for a
  past one.
- Run windows come from env.txt, which records the UTC offset; a start without
  one, or a window that ends before it starts, is `unknown`.

OOM_PROC_ROOT (default /proc) exists so the tests can supply boot id and btime.
"""
import datetime, glob, json, os, subprocess, sys, time

PROC = os.environ.get("OOM_PROC_ROOT", "/proc")


class JournalError(Exception):
    pass


def journal(*args, lines=True):
    """Run journalctl on the system journal. A non-zero exit is an error."""
    r = subprocess.run(["journalctl", "--system", "-o", "json", *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise JournalError(f"journalctl {' '.join(args)} exited {r.returncode}: "
                           f"{r.stderr.strip()[:200]}")
    if not lines:
        return json.loads(r.stdout) if r.stdout.strip() else []
    return [json.loads(l) for l in r.stdout.splitlines() if l.strip()]


def text(msg):  # MESSAGE is a byte array when it isn't valid UTF-8
    return bytes(msg).decode("utf-8", "replace") if isinstance(msg, list) else (msg or "")


def coverage():
    """{boot_id: (real start, covered from, covered to)} and the kill times."""
    current = open(f"{PROC}/sys/kernel/random/boot_id").read().strip().replace("-", "")
    btime = next(int(l.split()[1]) for l in open(f"{PROC}/stat") if l.startswith("btime"))
    kernel = {}
    for e in journal("_TRANSPORT=kernel"):
        kernel.setdefault(e.get("_BOOT_ID"), []).append(e)
    if not kernel.get(current):
        raise JournalError("no kernel entries readable for the running boot; this account "
                           "may not have access to the system journal (groups adm, "
                           "systemd-journal)")
    boots = {}
    for b in journal("--list-boots", lines=False):
        bid = b["boot_id"]
        if not kernel.get(bid):
            continue  # no readable kernel history: this boot covers nothing
        if bid == current:
            start, end = float(btime), time.time()
        else:
            last = journal("-b", bid, "-n", "1")
            if not last:
                continue
            rt, mono = int(last[0]["__REALTIME_TIMESTAMP"]), int(last[0]["__MONOTONIC_TIMESTAMP"])
            start, end = (rt - mono) / 1e6, rt / 1e6
        first = min(int(e["__MONOTONIC_TIMESTAMP"]) for e in kernel[bid])
        boots[bid] = (start, start + first / 1e6, end)
    if current not in boots:
        raise JournalError("the running boot is missing from journalctl --list-boots")
    kills = [boots[bid][0] + int(e["__MONOTONIC_TIMESTAMP"]) / 1e6
             for bid, entries in kernel.items() if bid in boots for e in entries
             if "Killed process" in text(e.get("MESSAGE")) and "llama-server" in text(e.get("MESSAGE"))]
    return current, boots, kills


def main():
    since = datetime.datetime.fromisoformat(sys.argv[1] if len(sys.argv) > 1 else "2026-09-19")
    if since.tzinfo is None:
        since = since.astimezone()
    root = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/bench-runs")
    try:
        current, boots, kills = coverage()
    except (JournalError, OSError, ValueError, KeyError, StopIteration) as e:
        sys.exit(f"ERROR: {e}. Kill exposure is UNKNOWN, not zero.")

    rows = []  # (label, kills or None, start as recorded, reason when unknown)
    for d in sorted(glob.glob(f"{root}/arena*/*/")):
        env = os.path.join(d, "env.txt")
        if not os.path.exists(env):
            continue
        label = os.path.basename(d.rstrip("/"))
        raw = next((l.split("date: ", 1)[1].strip() for l in open(env) if l.startswith("date: ")), None)
        if raw is None:
            continue
        try:
            start = datetime.datetime.fromisoformat(raw)
        except ValueError:
            rows.append((label, None, raw, "start time unparseable")); continue
        if start.tzinfo is None:
            rows.append((label, None, raw, "start time has no UTC offset")); continue
        if start < since:
            continue
        files = [os.path.join(d, f) for f in os.listdir(d) if os.path.isfile(os.path.join(d, f))]
        t0, t1 = start.timestamp(), max(os.path.getmtime(f) for f in files)
        if t1 < t0:
            rows.append((label, None, raw, "window ends before it starts")); continue
        if not any(cf <= t0 and t1 <= end for _, cf, end in boots.values()):
            rows.append((label, None, raw, "outside the journal's coverage")); continue
        rows.append((label, sum(1 for k in kills if t0 <= k <= t1), raw, ""))

    fmt = lambda t: datetime.datetime.fromtimestamp(t).astimezone().strftime("%Y-%m-%d %H:%M %z")
    unknown = [r for r in rows if r[1] is None]
    print(f"# OOM kills of llama-server per run ({len(kills)} kills found)")
    for bid, (_, cf, end) in sorted(boots.items(), key=lambda kv: kv[1][1]):
        print(f"# kernel log covers {fmt(cf)} .. {fmt(end)}  (boot {bid[:8]}{', running' if bid == current else ''})")
    print(f"# persistent journal: {os.path.isdir('/var/log/journal')}")
    print(f"# {sum(1 for r in rows if r[1])} of {len(rows)} runs overlapped a kill; "
          f"{len(unknown)} unknown")
    for label, n, raw, why in rows:
        print(f"{label:<34} oom_kills={'unknown' if n is None else n:<8} start={raw}"
              + (f"  ({why})" if why else ""))
    if unknown:
        sys.exit(f"\nERROR: {len(unknown)} of {len(rows)} runs have unknown exposure; "
                 f"unknown is not zero. Treat those runs as unattributed, or re-run the "
                 f"audit on a host whose journal covers them.")


if __name__ == "__main__":
    main()
