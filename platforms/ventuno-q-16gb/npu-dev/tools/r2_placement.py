#!/usr/bin/env python3
"""r2_placement.py (NPU dev plan K7, R2 check d): placement from an unmodified master af0579c78 llama-server log taken
with -lv 4 and GGML_SCHED_DEBUG=2, against the declared configuration.

  r2_placement.py <server log> --split 11,10,10,10 --variant "NPU-R'" [--sessions HTP0:0,HTP0:1,HTP0:2,HTP0:3]

Checks (exit 0 PLACED, 1 MISPLACED with each difference, 3 invalid input):
  1. The loader (llama-model.cpp :1656/:1661, debug): "load_tensors: layer N assigned to device D" for every layer index
     0..n_layer (the last is the output layer), each on the session its --split range gives (blocks in order; the output
     layer with the last session).
  2. Every reserved graph the scheduler printed (each starts at "## SPLIT #0"): the split backends in order are exactly
     CPU (the embeddings), the sessions in order, then, for NPU-R', CPU (the output projection). The scheduler's node
     lines cut the backend name to 5 characters (ggml-backend.cpp :1168), so a node's device is the split it is printed
     under, whose header carries the full name.
  3. In every graph: each MUL_MAT / MUL_MAT_ID whose name ends in "-<b>" (b a block) lies in block b's session split (a
     block's other ops may run on the next session: its last ADD does; the short-convolution matmuls are named
     "model.layers.{}.conv" without a block index, so for them the split sequence is the check); the
     output projection (the MUL_MAT named result_output) lies in the final CPU split for NPU-R' (in the last session's
     split for NPU-R); each split after the embeddings has at least one node.
Input is invalid if the log has no loader lines or no scheduler graph (were -lv 4 and GGML_SCHED_DEBUG=2 set?)."""
import argparse, re, sys

LOADER = re.compile(r"load_tensors: layer\s+(\d+) assigned to device (\S+?),")
SPLIT = re.compile(r"^## SPLIT #(\d+): (\S+) #")
NODE = re.compile(r"^node #\s*(\d+) \(\s*([A-Z_]+)\):\s+(\S.*?) \(")


def bad(msg):
    print(f"RESULT INVALID INPUT: {msg}"); sys.exit(3)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("log"); ap.add_argument("--split", required=True)
    ap.add_argument("--variant", required=True, choices=["NPU-R", "NPU-R'"])
    ap.add_argument("--sessions", default="HTP0:0,HTP0:1,HTP0:2,HTP0:3")
    a = ap.parse_args()
    sessions = a.sessions.split(","); split = [int(x) for x in a.split.split(",")]
    if len(split) != len(sessions):
        bad("--split and --sessions differ in length")
    # --split counts layer indices with the output layer included (the table tool's and the ledger's convention):
    # 11,10,10,10 = blocks 0..39 and the output layer 40
    n_layer = sum(split) - 1; owner = []
    for s, k in zip(sessions, split): owner += [s] * k
    try:
        lines = open(a.log, errors="replace").read().splitlines()
    except OSError as e:
        bad(f"cannot read {a.log}: {e}")
    diffs = []
    # 1. loader
    seen = {}
    for l in lines:
        m = LOADER.search(l)
        if m: seen[int(m.group(1))] = m.group(2)
    if not seen:
        bad("no loader assignment lines (was -lv 4 set?)")
    for il in range(n_layer + 1):
        want = owner[il] if il < n_layer else sessions[-1]
        if il not in seen: diffs.append(f"layer {il}: no loader line")
        elif seen[il] != want: diffs.append(f"layer {il}: on {seen[il]}, declared {want}")
    extra = sorted(k for k in seen if k > n_layer)
    if extra: diffs.append(f"loader lines for layers beyond {n_layer}: {extra}")
    # 2-3. scheduler graphs
    graphs, cur = [], None
    for l in lines:
        m = SPLIT.match(l)
        if m:
            if m.group(1) == "0":
                cur = []; graphs.append(cur)
            if cur is None: continue
            cur.append([m.group(2), []]); continue
        m = NODE.match(l)
        if m and cur:
            cur[-1][1].append((m.group(2), m.group(3).strip()))
    if not graphs:
        bad("no scheduler graph (was GGML_SCHED_DEBUG=2 set?)")
    want_seq = ["CPU"] + sessions + (["CPU"] if a.variant == "NPU-R'" else [])
    for gi, g in enumerate(graphs, 1):
        seq = [b for b, _ in g]
        if seq != want_seq:
            diffs.append(f"graph {gi}: splits {seq}, declared {want_seq}"); continue
        for si, (b, nodes) in enumerate(g):
            if si > 0 and not nodes: diffs.append(f"graph {gi}: split {si} ({b}) has no node")
            for op, name in nodes:
                if op not in ("MUL_MAT", "MUL_MAT_ID"):
                    continue     # only weight-bearing ops are bound to their block's session (a block's last ADD may
                                 # run on the next session, as the dry run shows for l_out-10/20/30)
                m = re.search(r"-(\d+)$", name)
                if m and int(m.group(1)) < n_layer and b != owner[int(m.group(1))] and b != "CPU":
                    diffs.append(f"graph {gi}: {op} {name} on {b}, block {m.group(1)} declared on {owner[int(m.group(1))]}")
                elif m and int(m.group(1)) < n_layer and b == "CPU":
                    diffs.append(f"graph {gi}: {op} {name} on the CPU, block {m.group(1)} declared on {owner[int(m.group(1))]}")
        where = [b for si, (b, nodes) in enumerate(g) for op, name in nodes if name == "result_output" and op == "MUL_MAT"]
        want_out = "CPU" if a.variant == "NPU-R'" else sessions[-1]
        if where != [want_out] or (a.variant == "NPU-R'" and not any(n == "result_output" for _, n in g[-1][1])):
            diffs.append(f"graph {gi}: result_output on {where}, declared {want_out}")
    print(f"loader: {len(seen)} layer lines; scheduler: {len(graphs)} graphs, splits {want_seq}")
    for d in diffs[:40]: print("DIFF", d)
    print("RESULT " + ("PLACED" if not diffs else f"MISPLACED ({len(diffs)} differences)"))
    return 0 if not diffs else 1


if __name__ == "__main__":
    sys.exit(main())
