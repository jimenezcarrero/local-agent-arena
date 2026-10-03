#!/usr/bin/env python3
"""pi_length_scan.py — find pi replies cut by the output-budget clamp, in saved sessions.

Usage: pi_length_scan.py [RUN_DIR...]   (default: ~/bench-runs/arena3/* and arena4/*)
       pi_length_scan.py --turns RUN_DIR   per-turn detail for one run

A "short reply" is an assistant message with stopReason=length and at most 2
output tokens: the signature of pi asking for one token. A "stalled turn" is a
turn (one user prompt) in which every assistant reply was a short reply.
"Recovered" means a normal reply (not short) came after the run's first short
reply. Output tokens and context come from each reply's recorded usage.
"""
import glob, json, os, re, sys


def replies(run_dir):
    turn = 0
    for s in sorted(glob.glob(os.path.join(run_dir, "pisessions", "*.jsonl"))):
        for line in open(s, errors="replace"):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            m = e.get("message") if isinstance(e.get("message"), dict) else None
            if not m:
                continue
            if m.get("role") == "user":
                turn += 1
            elif m.get("role") == "assistant":
                u = m.get("usage") or {}
                short = m.get("stopReason") == "length" and (u.get("output") or 0) <= 2
                yield turn, short, m.get("stopReason"), u.get("output") or 0, u.get("totalTokens") or 0


def scan(run_dir):
    rs = list(replies(run_dir))
    if not rs:
        return None
    by_turn = {}
    for t, short, *_ in rs:
        by_turn.setdefault(t, []).append(short)
    first = next((i for i, r in enumerate(rs) if r[1]), None)
    return {"short": sum(r[1] for r in rs),
            "stalled": sorted(t for t, v in by_turn.items() if v and all(v)),
            "recovered": first is not None and any(not r[1] for r in rs[first + 1:]),
            "ctx": max((r[4] for r in rs if r[1]), default=0)}


def main(argv):
    if argv[:1] == ["--turns"]:
        for t, short, stop, out, ctx in replies(argv[1]):
            print(f"turn {t:>2}  stop={stop:<8} output={out:<5} ctx={ctx:<6} {'SHORT' if short else ''}")
        return 0
    runs = argv or sorted(d for d in glob.glob(os.path.expanduser("~/bench-runs/arena[34]/*")) if os.path.isdir(d))
    led = {}
    lp = os.path.expanduser("~/bench-runs/results.txt")
    if os.path.exists(lp):
        for line in open(lp, errors="replace"):
            m = re.search(r"RESULT (\S+?): arena=\d pimodel=(\S+) (turns_passed=\S+|pytest=\S+)", line)
            if m:
                led[m.group(1)] = (m.group(2), m.group(3))
    total = flagged = stalled = 0
    for r in runs:
        tag = os.path.basename(r.rstrip("/"))
        res = scan(r)
        if res is None:
            continue
        total += 1
        if not res["short"]:
            continue
        flagged += 1; stalled += bool(res["stalled"])
        pm, score = led.get(tag, ("?", "?"))
        st = ",".join(map(str, res["stalled"])) or "-"
        print(f"{tag:<36} {pm:<9} {score:<22} short={res['short']:<3} stalled_turns={st:<14} "
              f"recovered={'yes' if res['recovered'] else 'no':<3} ctx_at_short<={res['ctx']}")
    print(f"# {flagged} of {total} runs had at least one short length-limited reply; "
          f"{stalled} of them had at least one stalled turn.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
