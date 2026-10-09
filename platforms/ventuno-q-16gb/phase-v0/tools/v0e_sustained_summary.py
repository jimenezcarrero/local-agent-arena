#!/usr/bin/env python3
"""v0e_sustained_summary.py <run dir> [monitor dir]   (V0e step 4 report, D112 as completed by D117)
Reads <run dir>/cycles.tsv (cycle, start epoch, end epoch; written by v0e_sustained.sh), the speed_probe RESULT line of
each <run dir>/speed-c<n>.txt (depth 8192: prefill_tps, decode_tps) and the health sampler rows
(<monitor dir>/health-*.jsonl, default ~/bench-runs/monitor) inside each cycle's window (max NSP and max CPU sensor,
degrees C). Reports every cycle, then first 3 vs last 3 cycles: mean prefill/decode, change in %, mean of the per-cycle
temperature maxima. A decline over 10 % in either rate is FLAGGED for the owner (declared in D112: a flag, not a fail).
Last line: "RESULT summary: VALID ..." (exit 0), or "RESULT summary: INSUFFICIENT ..." (fewer than 6 cycles, so the
first and last three would overlap) / "RESULT summary: INVALID ..." (a cycle without a speed result or without
temperature samples), exit 1. Written to stdout; v0e_sustained.sh saves it as <run dir>/sustained-summary.txt."""
import glob, json, os, re, sys

run = sys.argv[1]
mon = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/bench-runs/monitor")


def end(kind, why):
    print(f"RESULT summary: {kind} ({why})"); sys.exit(1)


try:
    cycles = [tuple(int(x) for x in l.split()[:3]) for l in open(os.path.join(run, "cycles.tsv")) if l.strip()]
except (OSError, ValueError) as e:
    end("INVALID", f"cycles.tsv unreadable: {e}")
rows = []
for f in sorted(glob.glob(os.path.join(mon, "health-*.jsonl"))):
    for l in open(f, errors="replace"):
        try:
            r = json.loads(l)
        except ValueError:
            continue
        if isinstance(r.get("epoch"), int) and isinstance(r.get("temp_mC"), dict):
            rows.append(r)
res, problems = [], []
for n, t0, t1 in cycles:
    try:
        txt = open(os.path.join(run, f"speed-c{n}.txt"), errors="replace").read()
    except OSError:
        txt = ""
    m = [l for l in txt.splitlines() if l.startswith("RESULT ") and " depth=8192 " in l and "ERROR" not in l]
    pf = re.search(r" prefill_tps=([\d.]+)", m[-1]) if m else None
    dc = re.search(r" decode_tps=([\d.]+)", m[-1]) if m else None
    temps = [r["temp_mC"] for r in rows if t0 <= r["epoch"] <= t1]
    nsp = [v for t in temps for k, v in t.items() if k.startswith("nsp") and isinstance(v, (int, float))]
    cpu = [v for t in temps for k, v in t.items() if k.startswith("cpu") and isinstance(v, (int, float))]
    if not (pf and dc):
        problems.append(f"cycle {n}: no speed result")
    if not (nsp and cpu):
        problems.append(f"cycle {n}: no temperature samples")
    res.append((n, float(pf.group(1)) if pf else None, float(dc.group(1)) if dc else None,
                max(nsp) / 1000 if nsp else None, max(cpu) / 1000 if cpu else None, t1 - t0, len(temps)))
    print(f"cycle {n}: {t1 - t0}s prefill={res[-1][1]} decode={res[-1][2]} nsp_max={res[-1][3]} cpu_max={res[-1][4]} "
          f"samples={len(temps)}")
if len(res) < 6:
    end("INSUFFICIENT", f"{len(res)} cycles; first 3 and last 3 need at least 6")
if problems:
    end("INVALID", "; ".join(problems))
mean = lambda xs: sum(xs) / len(xs)
a, b = res[:3], res[-3:]
out, flags = [], []
for i, name in ((1, "prefill"), (2, "decode")):
    e, l = mean([r[i] for r in a]), mean([r[i] for r in b]); ch = (l - e) / e * 100
    out.append(f"{name} {e:.1f}->{l:.1f} tok/s ({ch:+.1f}%)")
    if ch < -10:
        flags.append(f"{name} {ch:+.1f}%")
for i, name in ((3, "nsp_max"), (4, "cpu_max")):
    out.append(f"{name} {mean([r[i] for r in a]):.1f}->{mean([r[i] for r in b]):.1f} C")
print("first 3 vs last 3 cycles: " + ", ".join(out))
print(f"RESULT summary: VALID ({len(res)} cycles; {', '.join(out)}; "
      + (f"FLAG for owner review: decline over 10 %: {', '.join(flags)})" if flags else "no decline over 10 %)"))
