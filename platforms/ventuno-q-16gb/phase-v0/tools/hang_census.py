#!/usr/bin/env python3
"""hang_census.py [--rows FILE] (D125; Codex review of 892d7b9 finding 4): the pooled NPU hang count behind "14 hangs in
898 requests", recomputed from the committed run directories (run from phase-v0/). A run counts when its server log
shows ggml-hexagon and at least one served request (launch_slot_); requests = "processing task" lines; devices from the
GGML_HEXAGON_DEVICES of the SERVER line in run.txt (else the registry's ndev). The diagnostic runs (runs/v0f-*) are
excluded. HUNG lists the runs recorded as hangs (watchdog kill or the hang signature) in the fault histories and
decisions D61-D120; the script checks that each of them is among the counted runs. With --rows, one TSV row per counted
run (directory, devices, requests, hung). This is a pooled history over mixed configurations and recovery histories,
not a controlled failure rate."""
import collections, glob, os, re, sys

HUNG = {"runs/v0d-interleave/A-2-fault", "runs/v0d-final-attempt1/neohorse4b-F-r2", "runs/v0d-soak/soak-F4-3",
        "runs/v0d-affinity/9b-t4-strict-poll0", "runs/v0d-final3/A-r1", "runs/v0d-diag/attempt1/probe-120957",
        "runs/v0d-cdsp-test2/probe-2", "runs/v0d-spec2/probe-161103", "runs/v0d-spec3/probe-165408",
        "runs/v0d-spec3/probe-171611", "runs/v0d-admit-H2/H2-s1-r1", "runs/v0d-spec4c/4B-3s-mtpbase-n2-npu-fault",
        "runs/v0e-A/attempt2/v0e-A-S1", "runs/v0d-tune/v0d-4b-kvq8"}

def main(argv):
    rows, S = [], collections.defaultdict(lambda: [0, 0, 0])
    for log in sorted(glob.glob("runs/**/server.log*", recursive=True)):
        d = os.path.dirname(log)
        if d.startswith("runs/v0f-"):
            continue
        txt = open(log, errors="replace").read()
        if "ggml-hex" not in txt or "launch_slot_" not in txt:
            continue
        cmd = ""
        for p in (d + "/run.txt", d + "/run.txt.txt"):
            if os.path.exists(p):
                cmd = next((l for l in open(p, errors="replace") if " SERVER " in l or "server:" in l.lower()), "")
                break
        m = re.search(r"GGML_HEXAGON_DEVICES=(\S+)", cmd)
        if m:
            devs = m.group(1)
        else:
            m2 = re.search(r"allocating new registry : ndev (\d+)", txt)
            devs = f"ndev={m2.group(1)}" if m2 else "?"
        n = len(re.findall(r"processing task", txt))
        rows.append((d, devs, n, int(d in HUNG)))
        S[devs][0] += 1; S[devs][1] += n; S[devs][2] += d in HUNG
    counted = {r[0] for r in rows}
    missing = sorted(HUNG - counted)
    for k, (s, r, h) in sorted(S.items(), key=lambda x: -x[1][1]):
        print(f"{k:28s} servers {s:4d} requests {r:5d} hung {h}")
    print(f"total: servers {len(rows)} requests {sum(r[2] for r in rows)} hung {sum(r[3] for r in rows)}")
    if "--rows" in argv:
        with open(argv[argv.index("--rows") + 1], "w") as f:
            f.write("run\tdevices\trequests\thung\n")
            f.writelines(f"{d}\t{v}\t{n}\t{h}\n" for d, v, n, h in rows)
    if missing:
        print("listed hangs not among the counted runs:", " ".join(missing)); return 1
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
