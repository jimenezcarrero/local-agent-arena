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
- Each boot's journal is split into *clock segments*: stretches where the wall
  clock advanced in step with the monotonic clock. A suspend (the monotonic
  clock stops, the wall clock doesn't) or a clock correction starts a new
  segment. Kills and run windows are both dated on the wall clock and matched
  only within one segment; a run that spans two segments (it ran across a
  suspend or a clock step) is `unknown`. (Adding monotonic offsets to the boot
  time instead put every kill after an overnight suspend 7.6 hours early: 11
  real kills read as 0.)
- A segment's wall clock may be stale: boards without an RTC battery log
  early-boot entries dated July 2026, 1970 or the previous shutdown until NTP
  corrects the clock. A run is matched to its boot by the `boot_id:` line in
  env.txt when present, and then staleness doesn't matter (run and kills share
  the clock). Without it (every run before this line was added), only the
  running boot's segments that start after /proc/stat's btime count. A past
  boot offers no such proof — its last retained entry isn't its shutdown, and
  its successor's stale clock can land on either side of it — so a past-boot
  run without `boot_id:` is `unknown`.
- Kernel history must reach back over the whole run: coverage within a segment
  starts at the boot's oldest retained kernel entry, not at the oldest entry
  of any kind. Retained service logs prove nothing about the kernel's.
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


STEP = 2.0  # seconds of wall-vs-monotonic disagreement that start a new segment


def coverage():
    """Clock segments per boot, kills per segment, and the running boot's id.

    Returns (current, segments, kills): segments is a list of dicts with
    boot, first/last wall time, mono range and `trusted`; kills maps a segment
    index to the wall times of llama-server kills inside it."""
    current = open(f"{PROC}/sys/kernel/random/boot_id").read().strip().replace("-", "")
    btime = next(int(l.split()[1]) for l in open(f"{PROC}/stat") if l.startswith("btime"))
    kernel = {}
    for e in journal("_TRANSPORT=kernel"):
        kernel.setdefault(e.get("_BOOT_ID"), []).append(e)
    if not kernel.get(current):
        raise JournalError("no kernel entries readable for the running boot; this account "
                           "may not have access to the system journal (groups adm, "
                           "systemd-journal)")
    entries = {}
    for e in journal("--output-fields=_BOOT_ID"):
        entries.setdefault(e.get("_BOOT_ID"), []).append(
            (int(e["__MONOTONIC_TIMESTAMP"]) / 1e6, int(e["__REALTIME_TIMESTAMP"]) / 1e6))
    order = [b["boot_id"] for b in journal("--list-boots", lines=False)]
    if current not in order:
        raise JournalError("the running boot is missing from journalctl --list-boots")

    segments = []
    for bid in order:
        ents = sorted(entries.get(bid, []))
        if not ents:
            continue
        boot_segs, prev = [], None
        for mono, rt in ents:
            if prev is None or abs((rt - prev[1]) - (mono - prev[0])) > STEP:
                boot_segs.append({"boot": bid, "first": rt, "last": rt, "mono": [mono, mono]})
            boot_segs[-1]["last"], boot_segs[-1]["mono"][1] = rt, mono
            prev = (mono, rt)
        if bid == current:
            boot_segs[-1]["last"] = time.time()  # the running boot is covered up to now
        # Kernel history is retained from the boot's oldest kernel entry on.
        # A segment is covered from its start if that entry is in an earlier
        # segment, from the entry itself if it falls inside, and not at all if
        # it comes later (or the boot has no readable kernel entries).
        kfloor = min((int(e["__MONOTONIC_TIMESTAMP"]) / 1e6, int(e["__REALTIME_TIMESTAMP"]) / 1e6)
                     for e in kernel[bid]) if kernel.get(bid) else None
        for seg in boot_segs:
            if kfloor is None or kfloor[0] > seg["mono"][1]:
                seg["kernel_from"] = None
            elif kfloor[0] <= seg["mono"][0]:
                seg["kernel_from"] = seg["first"]
            else:
                seg["kernel_from"] = kfloor[1]
            # without a boot_id, only the running boot's post-btime clock is proof
            seg["trusted"] = bid == current and seg["first"] >= btime - STEP
        segments += boot_segs

    kills = {i: [] for i in range(len(segments))}
    for bid, ents in kernel.items():
        for e in ents:
            m = text(e.get("MESSAGE"))
            if "Killed process" not in m or "llama-server" not in m:
                continue
            mono, rt = int(e["__MONOTONIC_TIMESTAMP"]) / 1e6, int(e["__REALTIME_TIMESTAMP"]) / 1e6
            home = [i for i, g in enumerate(segments) if g["boot"] == bid and g["mono"][0] <= mono <= g["mono"][1]]
            if not home:
                raise JournalError(f"a kill at monotonic {mono:.0f}s in boot {bid[:8]} falls in no clock segment")
            kills[home[0]].append(rt)
    return current, segments, kills


def main():
    since = datetime.datetime.fromisoformat(sys.argv[1] if len(sys.argv) > 1 else "2026-09-19")
    if since.tzinfo is None:
        since = since.astimezone()
    root = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/bench-runs")
    try:
        current, segments, kills = coverage()
    except (JournalError, OSError, ValueError, KeyError, StopIteration) as e:
        sys.exit(f"ERROR: {e}. Kill exposure is UNKNOWN, not zero.")

    rows = []  # (label, kills or None, start as recorded, reason when unknown)
    for d in sorted(glob.glob(f"{root}/arena*/*/")):
        env = os.path.join(d, "env.txt")
        if not os.path.exists(env):
            continue
        label = os.path.basename(d.rstrip("/"))
        lines = open(env).read().splitlines()
        raw = next((l.split("date: ", 1)[1].strip() for l in lines if l.startswith("date: ")), None)
        if raw is None:
            continue
        run_boot = next((l.split(":", 1)[1].strip().replace("-", "") for l in lines if l.startswith("boot_id:")), None)
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
        if run_boot:   # the run says which boot it ran in: that boot's clock, stale or not
            pool = [i for i, g in enumerate(segments) if g["boot"] == run_boot]
        else:          # otherwise only the running boot's provably right clock
            pool = [i for i, g in enumerate(segments) if g["trusted"]]
        pool = [i for i in pool if segments[i]["kernel_from"] is not None]
        home = [i for i in pool if segments[i]["kernel_from"] <= t0 and t1 <= segments[i]["last"]]
        if len(home) != 1:
            why = ("spans a suspend or clock step, lies outside the retained kernel log, "
                   "or is a past-boot run without boot_id" if not home else "matches more than one clock segment")
            rows.append((label, None, raw, why)); continue
        rows.append((label, sum(1 for k in kills[home[0]] if t0 <= k <= t1), raw, ""))

    fmt = lambda t: datetime.datetime.fromtimestamp(t).astimezone().strftime("%Y-%m-%d %H:%M %z")
    unknown = [r for r in rows if r[1] is None]
    print(f"# OOM kills of llama-server per run ({sum(len(k) for k in kills.values())} kills found)")
    for i, g in enumerate(segments):
        if g["kernel_from"] is not None and g["last"] - g["first"] >= 60:
            print(f"# clock segment {fmt(g['kernel_from'])} .. {fmt(g['last'])}  (boot {g['boot'][:8]}"
                  f"{', running' if g['boot'] == current else ''}"
                  f"{'' if g['trusted'] else ', only runs with its boot_id'})  kills: {len(kills[i])}")
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
