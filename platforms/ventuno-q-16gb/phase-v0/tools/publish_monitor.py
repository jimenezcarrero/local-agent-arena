#!/usr/bin/env python3
"""publish_monitor.py <phase-v0 dir> — copy monitor evidence into the repo for publication.

From ~/bench-runs/monitor (or $MONITOR_DIR):
health-<date>.jsonl -> monitor/health-<date>-minutes.jsonl: every event line, plus one summary per minute
    with its extrema: min MemAvailable, max swap used, max memory/CPU PSI, max of every thermal zone,
    min scaling-max and max current clock per CPU policy, max cooling state per device, summed kernel
    counters with read/parse failures counted separately, max RSS per test process, sample count and span.
    Nothing that a peak or a floor depends on is lost to downsampling.
health-<date>.jsonl -> monitor/health-<date>-runs.jsonl: every raw 10 s sample inside a registered run
    window (run-windows.jsonl lines: {"label", "start_epoch", "end_epoch"}), tagged with its label,
    plus 120 s before and after each window.
kernel-<date>.jsonl -> monitor/kernel-<date>.jsonl: every kernel line, with _MACHINE_ID and _HOSTNAME
    removed and USB serial values replaced by <usb-serial>; _BOOT_ID and timestamps kept.
health-checks.txt, trip-points.txt, run-windows.jsonl: copied as they are.
Raw files stay in ~/bench-runs/monitor and the daily backup.
"""
import glob, json, os, re, shutil, sys

DROP = ("_MACHINE_ID", "_HOSTNAME")


def _read(path):
    try:
        return open(path).read().strip()
    except OSError:
        return ""


# Device identifiers are scrubbed from every published line, field values and message text alike
# (a journald message after the 23:02 stop carried the machine-id inside a journal file path).
SCRUB = [(v, tag) for v, tag in ((_read("/etc/machine-id"), "<machine-id>"),
                                  (_read("/sys/devices/soc0/serial_number"), "<serial>")) if v]


# USB devices print their serial at enumeration ("usb 3-1: SerialNumber: <value>"; Codex review of 40eaf0f). The
# descriptor index ("SerialNumber=3") is not an identifier and is kept.
USB_SERIAL = re.compile(r"(SerialNumber: )[^\s\"\\]+")


def scrub(text):
    for v, tag in SCRUB:
        text = text.replace(v, tag)
    return USB_SERIAL.sub(r"\1<usb-serial>", text)
PAD = 120
src = os.environ.get("MONITOR_DIR", os.path.expanduser("~/bench-runs/monitor"))
dst = os.path.join(sys.argv[1], "monitor")
os.makedirs(dst, exist_ok=True)

windows = []
if os.path.exists(f"{src}/run-windows.jsonl"):
    for line in open(f"{src}/run-windows.jsonl"):
        if line.strip():
            windows.append(json.loads(line))


def summarise(minute, rs):
    isint = lambda v: isinstance(v, int) and not isinstance(v, bool)
    s = {"minute_epoch": minute * 60, "ts_first": rs[0]["ts"], "ts_last": rs[-1]["ts"], "samples": len(rs),
         "boot_ids": sorted({r.get("boot_id") for r in rs if r.get("boot_id")}),
         "MemAvailable_kB_min": min(r["MemAvailable_kB"] for r in rs),
         "swap_used_kB_max": max(r["SwapTotal_kB"] - r["SwapFree_kB"] for r in rs)}
    for k in ("mem_some_avg10", "mem_full_avg10", "cpu_some_avg10"):
        v = [r[k] for r in rs if k in r]
        s[k + "_max"] = max(v) if v else None
    s["temp_mC_max"] = {}
    for r in rs:
        for z, t in r["temp_mC"].items():
            s["temp_mC_max"][z] = max(t, s["temp_mC_max"].get(z, t))
    s["freq_kHz"] = {}
    for r in rs:
        for p, (cur, smax, hw) in r["freq_cur_max_hw"].items():
            e = s["freq_kHz"].setdefault(p, {"cur_max": cur, "scaling_max_min": smax, "hw_max": hw})
            e["cur_max"] = max(e["cur_max"], cur); e["scaling_max_min"] = min(e["scaling_max_min"], smax)
    s["cooling_max"] = {}
    for r in rs:
        for c, v in r.get("cooling_active", {}).items():
            s["cooling_max"][c] = max(v, s["cooling_max"].get(c, v))
    kr = [r for r in rs if "kern_read" in r]
    good = [r for r in kr if r["kern_read"] == "ok" and r.get("kern_parse") != "FAILED"
            and isint(r.get("kern_alert_lines")) and isint(r.get("kern_oom_lines"))]
    s.update(kern_reads=len(kr), kern_good_reads=len(good),
             kern_read_failures=[r["kern_read"] for r in kr if r["kern_read"] != "ok"],
             kern_parse_failures=len(kr) - len(good) - sum(r["kern_read"] != "ok" for r in kr),
             kern_new_lines=sum(r.get("kern_new_lines") or 0 for r in good),
             kern_alert_lines=sum(r["kern_alert_lines"] for r in good),
             kern_oom_lines=sum(r["kern_oom_lines"] for r in good))
    procs = {}
    for r in rs:
        for p in r.get("procs", []):
            key = f'{p["pid"]} {p["cmd"][:60]}'
            procs[key] = max(p["rss_kB"], procs.get(key, 0))
    s["proc_rss_kB_max"] = procs
    return s


for f in sorted(glob.glob(f"{src}/health-*.jsonl")):
    stem = os.path.basename(f)[:-len(".jsonl")]
    rows, events = [], []
    bad = 0
    for line in open(f, errors="replace"):
        try:
            r = json.loads(line)
        except ValueError:      # e.g. a NUL-filled block left by an abrupt power loss; counted, never parsed
            bad += 1; continue
        (events if "event" in r else rows).append(r)
    if bad:
        events.append({"event": "unparseable_lines_skipped", "file": os.path.basename(f), "count": bad})
    minutes = {}
    for r in rows:
        minutes.setdefault(r["epoch"] // 60, []).append(r)
    with open(os.path.join(dst, stem + "-minutes.jsonl"), "w") as o:
        for e in events:
            o.write(scrub(json.dumps(e)) + "\n")
        for m in sorted(minutes):
            o.write(scrub(json.dumps(summarise(m, minutes[m]))) + "\n")
    with open(os.path.join(dst, stem + "-runs.jsonl"), "w") as o:
        for r in rows:
            labels = [w["label"] for w in windows
                      if w["start_epoch"] - PAD <= r["epoch"] <= (w.get("end_epoch") or 10**12) + PAD]
            if labels:
                o.write(scrub(json.dumps({**r, "run_labels": labels})) + "\n")
    old = os.path.join(dst, stem + "-1min.jsonl")   # superseded format
    if os.path.exists(old):
        os.remove(old)
for f in sorted(glob.glob(f"{src}/kernel-*.jsonl")):
    with open(os.path.join(dst, os.path.basename(f)), "w") as o:
        for line in open(f, errors="replace"):
            try:
                k = json.loads(line)
            except ValueError:
                continue
            o.write(scrub(json.dumps({x: v for x, v in k.items() if x not in DROP})) + "\n")
for name in ("health-checks.txt", "trip-points.txt", "run-windows.jsonl"):
    if os.path.exists(f"{src}/{name}"):
        open(os.path.join(dst, name), "w").write(scrub(open(f"{src}/{name}", errors="replace").read()))
print("published to", dst)
