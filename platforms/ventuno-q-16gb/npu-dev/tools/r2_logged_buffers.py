#!/usr/bin/env python3
"""r2_logged_buffers.py (NPU dev plan R2, check c): the buffers llama-server at af0579c78 logs per NPU session against R1's
ledger components for the same configuration.

  r2_logged_buffers.py <npu-dev dir> <server log> <ledger config, e.g. s4-rp-ub512>

Log lines (INFO, af0579c78): "load_tensors: <buf> model buffer size = X MiB" (llama-model.cpp :1992; a session's weights
may span several buffers, split at 1 GiB, so the lines are summed), "llama_kv_cache: <buf> KV buffer size" (:291),
"llama_memory_recurrent: <buf> RS buffer size" (:124), "sched_reserve: <buf> compute buffer size" (llama-context.cpp
:842). Sessions are the buffers named HTP0:0..HTP0:<S-1> in session order; "<session>-HOST" names a host buffer of
that session's type. The CPU's compute buffer is counted from every compute line that is not a session's: a real NPU
run's log names it "CPU" (A32-5's server log), master may name it "HTP0:0-HOST" (llama-context.cpp :496-504 allocates
it from that host type); at least one such line is required.
Limits, per session s, from the committed ledger (tools/r1_budget.py's CONFIGS and arithmetic):
  model    <= W_s (exact NPU allocation from the K3 table)
  KV + RS  <= the dry run's context bytes for s
  compute  <= the dry run's compute bytes for s + 1 MiB (HTP aligns compute tensors to 128 bytes, the dry run's devices
              to less; R1 bounded the difference at 127 B per node, 2,177 nodes: 0.26 MiB)
  host compute (any "-HOST" compute buffer) <= the whole-graph CPU compute bound for the ubatch
Each logged figure is rounded to 0.01 MiB, so it may exceed its exact value by 0.005 MiB per line: allowed.
Exit 0 WITHIN; 1 OVER (each excess named); 3 invalid input (unreadable log, unknown config, a session missing any of
its model, KV, RS or compute lines, a malformed buffer-size line, a buffer name outside the configuration's sessions)."""
import os, re, sys

LINE = re.compile(r"(load_tensors|llama_kv_cache|llama_memory_recurrent|sched_reserve):\s+(\S+)\s+(model|KV|RS|compute) buffer size =\s+([0-9.]+) MiB")
MiB = 1024 * 1024


def bad(msg):
    print(f"RESULT INVALID INPUT: {msg}"); sys.exit(3)


def main():
    if len(sys.argv) != 4:
        print(__doc__); return 2
    npudev, log, cfg = sys.argv[1:4]
    sys.path.insert(0, os.path.join(npudev, "tools"))
    import r1_budget as b
    conf = next((c for c in b.CONFIGS if c[0] == cfg), None)
    if not conf:
        bad(f"unknown ledger config {cfg}")
    _, variant, n, split, ub = conf
    w = b.weights(os.path.join(npudev, "r1-host/k3/table-M2.tsv"), split, variant)
    devs, _ = b.ledger(os.path.join(npudev, "r1-budget/ledger", cfg + ".out"))
    _, cpub = b.ledger(os.path.join(npudev, "r1-budget/ledger", f"cpu-ub{ub}.out"))
    names = [f"HTP0:{i}" for i in range(n)]
    try:
        text = open(log, errors="replace").read()
    except OSError as e:
        bad(f"cannot read {log}: {e}")
    got = {(s, k): 0.0 for s in names for k in ("model", "KV", "RS", "compute")}
    cnt = {(s, k): 0 for s in names for k in ("model", "KV", "RS", "compute")}
    host_compute, lines = 0.0, {s: 0 for s in names}
    # a line that names a buffer size but does not parse is malformed evidence, not something to skip
    for i, l in enumerate(text.splitlines(), 1):
        if re.search(r"\b(model|KV|RS|compute) buffer size", l) and not LINE.search(l):
            bad(f"line {i}: malformed buffer-size line")
    n_host = 0
    for m in LINE.finditer(text):
        _, buf, kind, mib = m.groups()
        if buf.startswith("HTP") and not buf.endswith("-HOST"):
            if buf not in names: bad(f"buffer {buf} is not one of {names}")
            got[(buf, kind)] += float(mib); cnt[(buf, kind)] += 1; lines[buf] += 1
        elif kind == "compute":   # the CPU's compute buffer: logged as "CPU" (a real release log) or "<session>-HOST"
            if buf.endswith("-HOST") and buf[:-5] not in names: bad(f"host buffer {buf} outside the sessions")
            host_compute += float(mib); n_host += 1
    if n_host == 0:
        bad("no CPU compute buffer line (named CPU or <session>-HOST)")
    over = []
    tol = lambda k: 0.005 * max(1, text.count(f" {k} buffer size"))
    for i, s in enumerate(names):
        # every component this configuration allocates on every session must be logged (review of fdb7292): each
        # session holds blocks with attention (KV) and short-convolution (RS) layers (r1-budget/ledger/<config>.out)
        missing = [k for k in ("model", "KV", "RS", "compute") if cnt[(s, k)] == 0]
        if missing:
            bad(f"session {s} has no {', '.join(missing)} buffer line (was -lv 4 set and the load complete?)")
        checks = [("model", got[(s, "model")], w[i] / MiB, tol("model")),
                  ("KV+RS", got[(s, "KV")] + got[(s, "RS")], devs[i][1] / MiB, tol("KV") + tol("RS")),
                  ("compute", got[(s, "compute")], devs[i][2] / MiB + 1, tol("compute"))]
        for what, val, lim, t in checks:
            ok = val <= lim + t
            if not ok: over.append(f"{s} {what} {val:.2f} > {lim:.2f}")
            print(f"{s} {what}: logged {val:.2f} MiB, ledger {lim:.2f} MiB: {'within' if ok else 'OVER'}")
    ok = host_compute <= cpub[2] / MiB + 0.005
    print(f"host compute: logged {host_compute:.2f} MiB, CPU bound {cpub[2] / MiB:.2f} MiB: {'within' if ok else 'OVER'}")
    if not ok: over.append(f"host compute {host_compute:.2f}")
    print("RESULT " + ("WITHIN" if not over else "OVER: " + "; ".join(over)))
    return 0 if not over else 1


if __name__ == "__main__":
    sys.exit(main())
