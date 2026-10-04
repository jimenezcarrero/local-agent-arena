#!/usr/bin/env python3
"""publish_monitor.py <phase-v0 dir> — copy monitor evidence into the repo for publication.

health-<date>.jsonl  -> monitor/health-<date>-1min.jsonl: every event line, one sample per minute,
                        plus every sample with a kernel alert/OOM line or a failed kernel read.
kernel-<date>.jsonl  -> monitor/kernel-<date>.jsonl: every kernel line, with device-identifying journal
                        fields removed (_MACHINE_ID, _HOSTNAME); _BOOT_ID and timestamps are kept.
health-checks.txt, trip-points.txt: copied as they are.
Raw files stay in ~/bench-runs/monitor and the daily backup.
"""
import glob, json, os, shutil, sys

DROP = ("_MACHINE_ID", "_HOSTNAME")
src = os.path.expanduser("~/bench-runs/monitor")
dst = os.path.join(sys.argv[1], "monitor")
os.makedirs(dst, exist_ok=True)
for f in sorted(glob.glob(f"{src}/health-*.jsonl")):
    seen = set()
    with open(os.path.join(dst, os.path.basename(f).replace(".jsonl", "-1min.jsonl")), "w") as o:
        for line in open(f):
            r = json.loads(line)
            if "event" in r:
                o.write(line); continue
            m = r["epoch"] // 60
            if (m not in seen or r.get("kern_alert_lines") or r.get("kern_oom_lines")
                    or str(r.get("kern_read", "ok")) != "ok"):
                seen.add(m); o.write(line)
for f in sorted(glob.glob(f"{src}/kernel-*.jsonl")):
    with open(os.path.join(dst, os.path.basename(f)), "w") as o:
        for line in open(f):
            k = json.loads(line)
            o.write(json.dumps({x: v for x, v in k.items() if x not in DROP}) + "\n")
for name in ("health-checks.txt", "trip-points.txt"):
    if os.path.exists(f"{src}/{name}"):
        shutil.copy(f"{src}/{name}", dst)
print("published to", dst)
