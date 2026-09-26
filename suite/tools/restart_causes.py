#!/usr/bin/env python3
"""Say why each server restart in a run happened, from the facts the harness
recorded (restarts.log), the kernel log and the swap sampler.

Usage: restart_causes.py <run-dir>... [--vmstat PATH]
  default vmstat log: $BENCH_WORK/vmstat.log (~/bench-runs/vmstat.log)

The OOM audit only sees kernel kills. A server can also stall under memory
pressure without the kernel killing it (J2: swap exhausted, 16MB available,
a turn that timed out while the server never took its request), and a turn can
simply run out of time. Each restart gets one of:

  oom-kill                 the server was dead and the kernel logged killing its PID
  died, no kill record     the server was dead and the kernel logged no kill of it
  died, kill log unreadable  the server was dead; the kernel log couldn't be read
  timeout, swap exhausted  alive, the turn hit its cap, and the sampler saw swap
                           run out during the turn (a memory stall is likely)
  timeout, no memory pressure  alive, the turn hit its cap, swap never ran out
  timeout, no memory samples   alive, the turn hit its cap, sampler not running
  unhealthy                alive but not answering /health, turn not timed out

The labels state evidence, not blame: "swap exhausted" says what the sampler
saw during the turn, not that it alone caused the timeout. Runs recorded before
restarts.log existed are reported as unrecorded, never as clean.
"""
import datetime, glob, json, os, re, subprocess, sys


def kernel_kill(pid, t0, t1):
    """True/False, or None when the kernel log can't be read."""
    r = subprocess.run(["journalctl", "--system", "_TRANSPORT=kernel", "-o", "json",
                        "--since", f"@{int(t0) - 5}", "--until", f"@{int(t1) + 5}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    pat = re.compile(rf"Killed process {pid} \(llama-server\)")
    return any(pat.search(str(json.loads(l).get("MESSAGE", ""))) for l in r.stdout.splitlines() if l.strip())


def samples(path):
    """[(epoch, avail_mb, swapfree_mb, majflt)] from vmstat_sampler.sh output."""
    out = []
    try:
        for line in open(path):
            m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) .*majflt=(\d+) avail_mb=(\d+) swapfree_mb=(\d+)", line)
            if m:
                t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timestamp()
                out.append((t, int(m.group(3)), int(m.group(4)), int(m.group(2))))
    except OSError:
        pass
    return out


def classify(rec, vm):
    t0, t1 = float(rec["turn_start"]), float(rec["at"])
    if rec["server_alive"] == "no":
        k = kernel_kill(rec["server_pid"], t0, t1)
        return {True: "oom-kill", False: "died, no kill record", None: "died, kill log unreadable"}[k], ""
    if rec["rc"] != "124":
        return "unhealthy", f"rc={rec['rc']}"
    during = [s for s in vm if t0 <= s[0] <= t1 + 60]   # the sampler writes once a minute
    if not during:
        return "timeout, no memory samples", ""
    detail = (f"min avail {min(s[1] for s in during)}MB, min swap free {min(s[2] for s in during)}MB, "
              f"max majflt {max(s[3] for s in during)}/min")
    if min(s[2] for s in during) == 0:
        return "timeout, swap exhausted", detail
    return "timeout, no memory pressure", detail


def main(argv):
    vmpath = os.path.join(os.environ.get("BENCH_WORK", os.path.expanduser("~/bench-runs")), "vmstat.log")
    if "--vmstat" in argv:
        i = argv.index("--vmstat"); vmpath = argv[i + 1]; del argv[i:i + 2]
    vm = samples(vmpath)
    for d in argv:
        name = os.path.basename(d.rstrip("/"))
        log = os.path.join(d, "restarts.log")
        n_logs = len(glob.glob(os.path.join(d, "server_r*.log")))
        if not os.path.exists(log):
            print(f"{name:<34} " + (f"{n_logs} restart(s) NOT RECORDED (run predates restarts.log)" if n_logs else "no restarts"))
            continue
        for line in open(log):
            rec = dict(kv.split("=", 1) for kv in line.split())
            cause, detail = classify(rec, vm)
            print(f"{name:<34} restart {rec['restart']} after turn {rec['turn']}: {cause}" + (f"  ({detail})" if detail else ""))


if __name__ == "__main__":
    main(sys.argv[1:])
