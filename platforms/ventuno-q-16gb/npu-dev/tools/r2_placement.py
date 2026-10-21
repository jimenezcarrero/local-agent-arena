#!/usr/bin/env python3
"""r2_placement.py (NPU dev plan K7, R2 check d): placement from an unmodified master af0579c78 llama-server log taken
with -lv 5 (debug; at af0579c78 -lv 4 is "trace" and drops the debug lines this needs) and GGML_SCHED_DEBUG=2, against
the declared configuration and the model's own weights.

  r2_placement.py <server log> --tensors <K3 table-M2.tsv> --split 11,10,10,10 --variant "NPU-R'"
                  [--sessions HTP0:0,HTP0:1,HTP0:2,HTP0:3] [--roles REGEX] [--types T1,T2] [--output-weight NAME]

Other models (B1, review of af9889f): --roles replaces the alternation of block matmul roles (default LFM2's, below);
--types keeps only the table's weights of those types as required (the others are not checked); --output-weight names
the output projection's weight (default token_embd.weight, LFM2's tied embedding; e.g. output.weight).
CPU splits (review of fd5e987): a fallback can make an extra CPU split mid-graph (check 2), or share an allowed CPU
split, so the CPU splits' nodes are audited too: --cpu-first lists what the first CPU split may hold (default GET_ROWS,
as the R2 fixtures show), --cpu-last what the final CPU split of NPU-R' may hold (default MUL_MAT); an item is OP or
OP@<src0 prefix>; any other node there is a difference. --session-src0 PREFIX requires, in every graph, at least one
MUL_MAT whose weight (src0) starts with PREFIX under every session split (e.g. prism.hadamard: the runtime's
Hadamard input rotations). The CPU splits' node inventory of the first graph is printed for the record.
Phases (B1c-4B Step 1 result): llama-server's parameter fitting loads the model once with empty buffers and reserves
graphs before the real load, so a log holds more than one block of loader lines. A phase starts at each block of
"layer N assigned to device" lines; only the LAST phase (its loader lines and the graphs after them) is judged, earlier
ones are counted and ignored, as r2_logged_buffers.py does.
--empty-cpu-ok (B1c-4B Step 1 result, opt-in): a graph that requests no output rows makes the last layer's output-row
ops zero-element (e.g. 2560:0), the Hexagon backend declines them (its supports-op debug line ends "|no") and the
scheduler gives them extra CPU splits that do no arithmetic. With this flag an extra CPU split (one not at an allowed
position) is dropped when every node in it was declined with a zero-element result shape in the supports-op block
logged for that graph (the queries between the previous graph's print and this one's "## SPLIT #0"; node names repeat
across graphs, so a decision is matched only within its own graph's block) and the same block has no non-empty query
under that op and name; adjacent splits of one backend are then merged and every check above runs on the result. Any
other extra CPU split is still a difference. The dropped splits are counted.
--lead-split SESSION --lead-allow RULES (B1c-9B result, b1-bonsai/README.txt check d revision 2): the scheduler puts the
input embedding's Hadamard restore with its matrix, on the session that holds it, in a split of its own between the
first CPU split and the sessions (B1c-9B and B1d-4B S2: CPU, HTP0:1, HTP0:0, HTP0:1). With these options that split is
declared: the sequence becomes CPU, SESSION, the sessions in order (then CPU for NPU-R'), required in every graph, and
every node in it must match RULES. A rule is OP, OP@PREFIX (src0 starts with PREFIX) or OP~TEXT (some source's printed
name, cut to 20 characters, contains TEXT). The allowed splits' node inventories are printed for the first graph and
summed over all graphs.

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
SUPP = re.compile(r"^ggml-hex: \S+ supports-op ([A-Z_0-9]+)\|(.*)$")
ROLES = r"(attn_q|attn_k|attn_v|attn_output|shortconv\.in_proj|shortconv\.out_proj|ffn_gate|ffn_up|ffn_down|ffn_gate_inp|ffn_gate_exps|ffn_up_exps|ffn_down_exps)"


def bad(msg):
    print(f"RESULT INVALID INPUT: {msg}"); sys.exit(3)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("log"); ap.add_argument("--tensors", required=True)
    ap.add_argument("--split", required=True); ap.add_argument("--variant", required=True, choices=["NPU-R", "NPU-R'"])
    ap.add_argument("--sessions", default="HTP0:0,HTP0:1,HTP0:2,HTP0:3")
    ap.add_argument("--roles", default=ROLES[1:-1]); ap.add_argument("--types", default="")
    ap.add_argument("--output-weight", default="token_embd.weight")
    ap.add_argument("--cpu-first", default="GET_ROWS"); ap.add_argument("--cpu-last", default="MUL_MAT")
    ap.add_argument("--session-src0", default="")
    ap.add_argument("--empty-cpu-ok", action="store_true")
    ap.add_argument("--lead-split", default=""); ap.add_argument("--lead-allow", default="")
    a = ap.parse_args()
    weight_re = re.compile(r"^blk\.(\d+)\.(" + a.roles + r")\.weight$")
    types = set(x for x in a.types.split(",") if x)
    sessions = a.sessions.split(","); split = [int(x) for x in a.split.split(",")]
    if len(split) != len(sessions):
        bad("--split and --sessions differ in length")
    if a.lead_split and (a.lead_split not in sessions or not a.lead_allow):
        bad("--lead-split must name one of --sessions and needs --lead-allow")
    if a.lead_allow and not a.lead_split:
        bad("--lead-allow needs --lead-split")
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
    starts = [i for i, l in enumerate(lines) if LOADER.search(l) and (i == 0 or not LOADER.search(lines[i - 1]))]
    if not starts:
        bad("no loader assignment lines (was -lv 5 set?)")
    print(f"phases: {len(starts)}; judged: the last, from line {starts[-1] + 1}" + ("; earlier phases ignored" if len(starts) > 1 else ""))
    first = starts[-1]
    lines = lines[first:]
    for l in lines:
        m = LOADER.search(l)
        if m: seen[int(m.group(1))] = m.group(2)
    pend_e, pend_n, empties = set(), set(), []   # per graph: (op, result name cut to 20) declined with a zero-element shape
    for il in range(n_layer + 1):
        want = owner[il]
        if il not in seen: diffs.append(f"layer {il}: no loader line")
        elif seen[il] != want: diffs.append(f"layer {il}: on {seen[il]}, declared {want}")
    extra = sorted(k for k in seen if k > n_layer)
    if extra: diffs.append(f"loader lines for layers beyond {n_layer}: {extra}")
    graphs, cur = [], None
    for i, l in enumerate(lines, 1):
        m = SUPP.match(l)
        if m:
            f = m.group(2).split("|")
            if len(f) < 6: bad(f"line {i}: a supports-op line that does not parse")
            key = (m.group(1), f[0].split(" -> ")[-1].strip()[:20])
            dims = [x for x in f[1].split(" -> ")[-1].split(":") if x.strip().isdigit()]
            (pend_e if f[-1].strip() == "no" and any(int(x) == 0 for x in dims) else pend_n).add(key)
            continue
        m = SPLIT.match(l)
        if m:
            if m.group(1) == "0":
                cur = []; graphs.append(cur); empties.append(pend_e - pend_n); pend_e, pend_n = set(), set()
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
    want_seq = ["CPU"] + ([a.lead_split] if a.lead_split else []) + sessions + (["CPU"] if a.variant == "NPU-R'" else [])
    want_out = "CPU" if a.variant == "NPU-R'" else sessions[-1]
    rule = lambda x: [*x.split("@", 1), "@"] if "@" in x else ([*x.split("~", 1), "~"] if "~" in x else [x, "", "@"])
    allow = lambda spec: [rule(x) for x in spec.split(",") if x]
    allowed = {0: allow(a.cpu_first)}
    if a.lead_split: allowed[1] = allow(a.lead_allow)
    if a.variant == "NPU-R'": allowed[len(want_seq) - 1] = allow(a.cpu_last)
    match = lambda t, k, srcs: not t or (srcs and srcs[0].startswith(t) if k == "@" else any(t in x for x in srcs))
    ok_node = lambda rules, op, srcs: any(op == o and match(t, k, srcs) for o, t, k in rules)
    totals = {si: {} for si in allowed}; n_judged = 0
    n_dropped = 0
    if a.empty_cpu_ok:
        for gi, g in enumerate(graphs):
            keep = []
            for si, (b, nodes) in enumerate(g):
                if b == "CPU" and si > 0 and si != len(g) - 1 or (b == "CPU" and si == len(g) - 1 and a.variant != "NPU-R'"):
                    if nodes and all((op, name[:20]) in empties[gi] for op, name, _ in nodes):
                        n_dropped += 1; continue
                if keep and keep[-1][0] == b and b != "CPU": keep[-1][1].extend(nodes)
                else: keep.append([b, list(nodes)])
            graphs[gi] = keep
        print(f"--empty-cpu-ok: {n_dropped} extra CPU split(s) of zero-element declined nodes dropped, in "
              f"{sum(1 for e in empties if e)} graph(s) with zero-element declines")
    for gi, g in enumerate(graphs, 1):
        seq = [b for b, _ in g]
        if seq != want_seq:
            diffs.append(f"graph {gi}: splits {seq}, declared {want_seq}"); continue
        n_judged += 1
        for si, rules in allowed.items():
            inv = {}; label = "CPU split" if g[si][0] == "CPU" else f"lead split ({g[si][0]})"
            for op, name, srcs in g[si][1]:
                key = f"{op}" + (f"@{srcs[0]}" if srcs else "")
                inv[key] = inv.get(key, 0) + 1; totals[si][key] = totals[si].get(key, 0) + 1
                if not ok_node(rules, op, srcs):
                    diffs.append(f"graph {gi}: {label} #{si} holds {op} {name} (src0 {srcs[0] if srcs else '-'}), not allowed")
            if gi == 1: print(f"{label} #{si} nodes (graph 1): " + (", ".join(f"{k} x{v}" for k, v in sorted(inv.items())) or "none"))
        if a.session_src0:
            for si, (b, nodes) in enumerate(g):
                if b in sessions and not any(op == "MUL_MAT" and srcs and srcs[0].startswith(a.session_src0) for op, _, srcs in nodes):
                    diffs.append(f"graph {gi}: no MUL_MAT with src0 {a.session_src0}* under {b}")
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
    for si, inv in totals.items():
        print(f"split #{si} ({want_seq[si]}) nodes, all {n_judged} graph(s) with the declared splits: "
              + (", ".join(f"{k} x{v}" for k, v in sorted(inv.items())) or "none"))
    print(f"loader: {len(seen)} layer lines; scheduler: {len(graphs)} graphs, splits {want_seq}; "
          f"{len(expected)} block matmul weights expected per graph")
    for d in diffs[:40]: print("DIFF", d)
    if len(diffs) > 40: print(f"DIFF ... and {len(diffs) - 40} more")
    print("RESULT " + ("PLACED" if not diffs else f"MISPLACED ({len(diffs)} differences)"))
    return 0 if not diffs else 1


if __name__ == "__main__":
    sys.exit(main())
