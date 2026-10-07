#!/usr/bin/env python3
"""parity.py <ref dir> <ref dir> <cand dir> <cand dir> — pre-declared parity gate for the combined build (D78).
Pass only if: every run's RESULT lines have valid values at 8K and 16K, and the candidate mean is within +-5 % of the
reference mean for prefill and decode at both depths. Prints a table; exit 0 = parity."""
import re, sys
TOL = 0.05
def vals(d):
    out = {}
    for l in open(d + "/probe.txt", errors="replace"):
        m = re.match(r"RESULT \S+ depth=(\d+) prompt_tokens=(\d+) .*?prefill_tps=([\d.]+) .*?decode_tps=([\d.]+)", l)
        if m: out[int(m.group(1))] = (float(m.group(3)), float(m.group(4)))
    return out
r = [vals(d) for d in sys.argv[1:3]]; c = [vals(d) for d in sys.argv[3:5]]; ok = True
for dep in (8192, 16384):
    for i, name in ((0, "prefill"), (1, "decode")):
        try:
            rm = sum(x[dep][i] for x in r) / 2; cm = sum(x[dep][i] for x in c) / 2
        except KeyError:
            print(f"{dep} {name}: missing value -> FAIL"); ok = False; continue
        d = (cm - rm) / rm; good = abs(d) <= TOL; ok &= good
        print(f"{dep} {name}: reference {rm:.2f} candidate {cm:.2f} diff {d*100:+.1f}% {'ok' if good else 'FAIL'}")
print("PARITY", "PASS" if ok else "FAIL"); sys.exit(0 if ok else 1)
