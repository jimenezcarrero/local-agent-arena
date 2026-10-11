#!/usr/bin/env python3
"""admit_gate.py <phase dir> <set name> <attempt> (D137) — the frozen V0d 16K eligibility gate (RUNBOOK: the median of
the three measured runs at 16384 tokens, after the discarded warm-up, with actual prompts within +-20 % of 16384, meets
>= 145 tok/s prefill and >= 4.4 tok/s decode). Reads <phase dir>/<set>-s<attempt>-r{1,2,3}/probe.txt, the "RESULT
<label>: depth=16384 ..." line of each (OFF_DEPTH "RETRY" lines are not results). Prints one line starting with
"GATE <set>: PASS", "GATE <set>: FAIL" or "GATE <set>: MISSING". Exit 0 pass, 3 fail, 2 missing or malformed."""
import re, statistics, sys

def main(d, name, att):
    rows = []
    for r in (1, 2, 3):
        lab = f"{name}-s{att}-r{r}"
        try:
            txt = open(f"{d}/{lab}/probe.txt").read()
        except OSError:
            print(f"GATE {name}: MISSING {lab}/probe.txt"); return 2
        hits = re.findall(rf"^RESULT {re.escape(lab)}: depth=16384 (.*)$", txt, re.M)
        if len(hits) != 1:
            print(f"GATE {name}: MISSING one 16384 RESULT line in {lab} (found {len(hits)})"); return 2
        kv = dict(x.split("=", 1) for x in hits[0].split() if "=" in x)
        try:
            p, pf, dc = int(kv["prompt_tokens"]), float(kv["prefill_tps"]), float(kv["decode_tps"])
        except (KeyError, ValueError):
            print(f"GATE {name}: MISSING numeric prompt_tokens/prefill_tps/decode_tps in {lab}"); return 2
        if not 0.8 * 16384 <= p <= 1.2 * 16384:
            print(f"GATE {name}: MISSING {lab} prompt {p} tokens outside +-20 % of 16384"); return 2
        rows.append((p, pf, dc))
    mp, md = statistics.median(r[1] for r in rows), statistics.median(r[2] for r in rows)
    ok = mp >= 145 and md >= 4.4
    detail = ", ".join(f"r{i+1} {p} tok {pf:.1f}/{dc:.2f}" for i, (p, pf, dc) in enumerate(rows))
    print(f"GATE {name}: {'PASS' if ok else 'FAIL'} median 16K prefill {mp:.1f} (>= 145), decode {md:.2f} (>= 4.4); {detail}")
    return 0 if ok else 3

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3]))
