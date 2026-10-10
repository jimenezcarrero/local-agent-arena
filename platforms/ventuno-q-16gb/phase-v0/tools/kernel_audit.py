#!/usr/bin/env python3
"""kernel_audit.py <run dir> — classify every kernel alert line inside a run window (Codex review of #45, 2026-10-06
20:32Z, finding 1: accelerator faults must fail health admission on their own, not only through the speed probe).
Window: run.txt START .. END + 30 s (run_route.sh waits for a successful kernel read after END). Kernel lines: the
durable journal copy, ~/bench-runs/monitor/kernel-*.jsonl (or MONITOR_DIR=<repo phase-v0>/monitor). Audited lines: the
sampler's ALERT_RE matches plus any FAULT match (a GPU "lockup" line has no ALERT_RE word). Each is put in
exactly one class:
  fault     accelerator or system fault: GPU (adreno/a6xx/kgsl/msm gpu fault, display hangcheck/recover), SMMU, DSP or
            remoteproc crash/fatal/watchdog, any fastrpc/adsprpc/cdsp line other than npu_map, hung task, segfault, OOM
  npu_map   "fastrpc ... failed to map buffer": an NPU session mapping failure (expected only with a load failure)
  allowed   on the audited allowlist below (each entry records why it is benign)
  unknown   any other alert line (fail-closed: evidence incomplete, not a pass)
First output line is the verdict: "pass", or the worst class present in the order fault > unknown > npu_map with counts.
Exit 0 only for pass or npu_map-only (the caller decides whether npu_map is consistent with the run's outcome); 1 for
fault, 2 for unknown, 3 for missing inputs (no window, no kernel journal copy, or no successful kernel read at or after
END in the health samples: D128, Codex review of 8002b63 finding 2: a copy that ends before the run cannot vouch for
it)."""
import datetime as dt, glob, json, os, re, sys

ALERT_RE = re.compile(r"oom|killed process|out of memory|thermal|throttl|fastrpc|kgsl|adsprpc|cdsp|smmu|fault|error|"
                      r"segfault|hung task|watchdog", re.I)          # same expression as health_sampler.sh
NPU_MAP = re.compile(r"fastrpc.*failed to map buffer", re.I)
FAULT = re.compile(r"adreno|a6xx|kgsl|gpu fault|lockup|\bgpu\b.*(hang|fault|recover)|hangcheck|recover_worker|smmu|"
                   r"fastrpc|adsprpc|cdsp|remoteproc.*(crash|fatal|watchdog|stop)|hung task|segfault|"
                   r"killed process|oom-kill|out of memory", re.I)
# Audited allowlist: (regex, reason). Only lines reviewed in the committed kernel journal belong here.
ALLOWED = [
    (re.compile(r"^usb \S+: USB disconnect"), "USB hub/device unplug (owner peripherals), not a compute device"),
]
H = os.environ.get("MONITOR_DIR", os.path.expanduser("~/bench-runs/monitor"))

def ep(s): return dt.datetime.fromisoformat(s).timestamp()

def classify(msg):
    if NPU_MAP.search(msg): return "npu_map"
    for rx, _ in ALLOWED:
        if rx.search(msg): return "allowed"
    if FAULT.search(msg): return "fault"
    return "unknown"

def main(d):
    try:
        run = open(os.path.join(d, "run.txt")).read()
        t0 = ep(re.search(r"^(\S+) START", run, re.M).group(1))
        t1 = ep(re.findall(r"^(\S+) END", run, re.M)[-1]) + 30
    except (OSError, AttributeError, IndexError):
        print("missing: no START/END window in run.txt"); return 3
    files = sorted(glob.glob(f"{H}/kernel-*.jsonl"))
    lines = []
    for f in files:
        for l in open(f, errors="replace"):
            try: r = json.loads(l); t = int(r["__REALTIME_TIMESTAMP"]) / 1e6
            except (ValueError, KeyError): continue
            m = str(r.get("MESSAGE", ""))
            if t0 <= t <= t1 and (ALERT_RE.search(m) or FAULT.search(m)): lines.append((t, classify(m), m))
    if not files:
        print(f"missing: no kernel journal copy in {H}"); return 3
    # The sampler appends to the kernel copy only when the kernel logs something, so silence is evidence only up to the
    # last successful read. Coverage: some health sample at or after END (same monitor directory) records kern_read ok.
    t_end = t1 - 30; covered = False
    for f in sorted(glob.glob(f"{H}/health-*.jsonl")):
        for l in open(f, errors="replace"):
            if '"kern_read":"ok"' not in l.replace(" ", ""): continue
            try: r = json.loads(l)
            except ValueError: continue
            if r.get("kern_read") == "ok" and r.get("epoch", 0) >= t_end: covered = True; break
        if covered: break
    if not covered:
        print(f"missing: no successful kernel read at or after END in {H}/health-*.jsonl"); return 3
    cnt = {c: sum(1 for x in lines if x[1] == c) for c in ("fault", "unknown", "npu_map", "allowed")}
    worst = next((c for c in ("fault", "unknown", "npu_map") if cnt[c]), None)
    print("pass" if worst is None else f"{worst} " + " ".join(f"{c}={n}" for c, n in cnt.items() if n),
          f"(window {dt.datetime.fromtimestamp(t0).isoformat(timespec='seconds')} .. +{t1 - t0:.0f}s)")
    for t, c, m in lines:
        print(dt.datetime.fromtimestamp(t).isoformat(timespec="seconds"), c, m[:200])
    return {None: 0, "npu_map": 0, "fault": 1, "unknown": 2}[worst]

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
