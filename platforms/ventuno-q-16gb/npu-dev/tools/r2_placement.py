#!/usr/bin/env python3
"""r2_placement.py (NPU dev plan K7, R2 check d): placement from an unmodified master af0579c78 llama-server log taken
with -lv 5 (debug; at af0579c78 -lv 4 is "trace" and drops the debug lines this needs) and GGML_SCHED_DEBUG=2, against
the declared configuration and the model's own weights.

  r2_placement.py <server log> --tensors <K3 table-M2.tsv> --split 11,10,10,10 --variant "NPU-R'"
                  [--sessions HTP0:0,HTP0:1,HTP0:2,HTP0:3] [--roles REGEX] [--types T1,T2] [--output-weight NAME]

Other models (B1, review of af9889f): --roles replaces the alternation of block matmul roles (default LFM2's, below);
--types keeps only the table's weights of those types as required (the others are not checked); --output-weight names
the output projection's weight (default token_embd.weight, LFM2's tied embedding; e.g. output.weight). The split
sequence check (2) is what catches a CPU fallback: an op the NPU does not take makes an extra CPU split mid-graph.

The production logger (common_init: common/common.cpp :394-397, common/log.cpp) puts "M.SS.mmm.uuu X " before every log
call, and the scheduler prints a node line in several calls (ggml-backend.cpp :1166-1180), so prefixes also appear inside
lines: every such prefix is removed first. --split counts layer indices with the output layer (11,10,10,10 = blocks
0..39 and the output layer 40), as the table tool and the ledger do.
Checks (exit 0 PLACED, 1 MISPLACED with each difference, 3 invalid input):
  1. Loader (llama-model.cpp :1656/:1661): "layer N assigned to device D" for every index 0..n_layer, each on its
     session (the output layer with the last session).
  2. Every reserved graph (each starts at "## SPLIT #0"): the split backends are exactly CPU (embeddings), the sessions
     in order, then CPU for NPU-R' (the output projection). Node lines cut the backend name to 5 characters, so a node's
     device is the split it is printed under (whose header carries the full name).
  3. Weight coverage, per graph: every matmul weight of every block, read from the tensor table (attn_q/k/v/output,
     shortconv.in_proj/out_proj, ffn_gate/up/down, ffn_gate_inp, ffn_gate/up/down_exps), must appear as the weight
     source (src0, name cut to 20 characters by the scheduler) of a MUL_MAT or MUL_MAT_ID printed under its block's
     session split; the output projection (result_output) must take token_embd.weight and sit in the final CPU split
     for NPU-R' (in the last session's split for NPU-R). A weight missing from a graph, or found under another split,
     is a difference. So a log without the matmul records cannot pass.
Invalid input: no loader lines or no scheduler graph (were -lv 5 and GGML_SCHED_DEBUG=2 set?), a node line that does not
parse, an unreadable log or table."""
import argparse, re, sys

PREFIX = re.compile(r"\d+\.\d{2}\.\d{3}\.\d{3} [IWED] ")
LOADER = re.compile(r"load_tensors: layer\s+(\d+) assigned to device (\S+?),")
SPLIT = re.compile(r"^## SPLIT #(\d+): (\S+) #")
NODE = re.compile(r"^node #\s*(\d+) \(\s*([A-Z_0-9]+)\): (.{20}) \(.{5}\) \[.{5} .{8}\] use=\d+,c=\d+:(.*)$")
SRC = re.compile(r"(.{20}) \(.{5}\) \[.{5} .{8}\]")
ROLES = r"(attn_q|attn_k|attn_v|attn_output|shortconv\.in_proj|shortconv\.out_proj|ffn_gate|ffn_up|ffn_down|ffn_gate_inp|ffn_gate_exps|ffn_up_exps|ffn_down_exps)"


def bad(msg):
    print(f"RESULT INVALID INPUT: {msg}"); sys.exit(3)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("log"); ap.add_argument("--tensors", required=True)
    ap.add_argument("--split", required=True); ap.add_argument("--variant", required=True, choices=["NPU-R", "NPU-R'"])
    ap.add_argument("--sessions", default="HTP0:0,HTP0:1,HTP0:2,HTP0:3")
    ap.add_argument("--roles", default=ROLES[1:-1]); ap.add_argument("--types", default="")
    ap.add_argument("--output-weight", default="token_embd.weight")
    a = ap.parse_args()
    weight_re = re.compile(r"^blk\.(\d+)\.(" + a.roles + r")\.weight$")
    types = set(x for x in a.types.split(",") if x)
    sessions = a.sessions.split(","); split = [int(x) for x in a.split.split(",")]
    if len(split) != len(sessions):
        bad("--split and --sessions differ in length")
    n_layer = sum(split) - 1; owner = []
    for s, k in zip(sessions, split): owner += [s] * k
    try:
        raw = open(a.log, errors="replace").read()
        rows = [l.rstrip("\n").split("\t") for l in open(a.tensors)][1:]
    except OSError as e:
        bad(f"cannot read: {e}")
    expected = {}   # weight name cut to 20 characters (as the scheduler prints it) -> block
    for r in rows:
        m = weight_re.match(r[0])
        if m and (not types or (len(r) > 2 and r[2] in types)):
            if r[0][:20] in expected:
                bad(f"two weights share the 20-character name {r[0][:20]}")
            expected[r[0][:20]] = int(m.group(1))
    if not expected:
        bad("no block matmul weights in the tensor table")
    lines = PREFIX.sub("", raw).splitlines()
    diffs = []
    seen = {}
    for l in lines:
        m = LOADER.search(l)
        if m: seen[int(m.group(1))] = m.group(2)
    if not seen:
        bad("no loader assignment lines (was -lv 5 set?)")
    for il in range(n_layer + 1):
        want = owner[il]
        if il not in seen: diffs.append(f"layer {il}: no loader line")
        elif seen[il] != want: diffs.append(f"layer {il}: on {seen[il]}, declared {want}")
    extra = sorted(k for k in seen if k > n_layer)
    if extra: diffs.append(f"loader lines for layers beyond {n_layer}: {extra}")
    graphs, cur = [], None
    for i, l in enumerate(lines, 1):
        m = SPLIT.match(l)
        if m:
            if m.group(1) == "0":
                cur = []; graphs.append(cur)
            if cur is not None: cur.append([m.group(2), []])
            continue
        if l.startswith("node #"):
            m = NODE.match(l)
            if not m: bad(f"line {i}: a node line that does not parse")
            if cur:
                srcs = [x.strip() for x in SRC.findall(m.group(4))]
                cur[-1][1].append((m.group(2), m.group(3).strip(), srcs))
    if not graphs:
        bad("no scheduler graph (was GGML_SCHED_DEBUG=2 set?)")
    want_seq = ["CPU"] + sessions + (["CPU"] if a.variant == "NPU-R'" else [])
    want_out = "CPU" if a.variant == "NPU-R'" else sessions[-1]
    for gi, g in enumerate(graphs, 1):
        seq = [b for b, _ in g]
        if seq != want_seq:
            diffs.append(f"graph {gi}: splits {seq}, declared {want_seq}"); continue
        found, outputs = {}, []
        for si, (b, nodes) in enumerate(g):
            for op, name, srcs in nodes:
                if op not in ("MUL_MAT", "MUL_MAT_ID") or not srcs:
                    continue
                w = srcs[0]
                if w in expected:
                    found.setdefault(w, []).append(b)
                if name == "result_output":
                    outputs.append((w, b, si))
        for w, blk in sorted(expected.items(), key=lambda x: (x[1], x[0])):
            where = found.get(w)
            if not where: diffs.append(f"graph {gi}: no matmul takes {w} (block {blk})")
            elif any(b != owner[blk] for b in where): diffs.append(f"graph {gi}: {w} used on {sorted(set(where))}, declared {owner[blk]}")
        if len(outputs) != 1:
            diffs.append(f"graph {gi}: {len(outputs)} result_output matmuls, expected 1")
        else:
            w, b, si = outputs[0]
            if w != a.output_weight[:20] or b != want_out or (a.variant == "NPU-R'" and si != len(g) - 1):
                diffs.append(f"graph {gi}: result_output takes {w} on {b}, declared {a.output_weight} on {want_out}")
    print(f"loader: {len(seen)} layer lines; scheduler: {len(graphs)} graphs, splits {want_seq}; "
          f"{len(expected)} block matmul weights expected per graph")
    for d in diffs[:40]: print("DIFF", d)
    if len(diffs) > 40: print(f"DIFF ... and {len(diffs) - 40} more")
    print("RESULT " + ("PLACED" if not diffs else f"MISPLACED ({len(diffs)} differences)"))
    return 0 if not diffs else 1


if __name__ == "__main__":
    sys.exit(main())
