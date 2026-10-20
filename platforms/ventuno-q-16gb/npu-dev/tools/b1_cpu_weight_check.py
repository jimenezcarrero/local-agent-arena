#!/usr/bin/env python3
"""b1_cpu_weight_check.py (NPU dev plan B1d-4B, option CK): in a llama-server or llama-perplexity log taken with -lv 5
and GGML_SCHED_DEBUG=2, check that the CPU does no work on the model's weights, whatever else it runs.

  b1_cpu_weight_check.py <log> --tensors <table.tsv> --session HTP0:0

CK keeps the KV cache and the recurrent state on the CPU (-nkvo), so the scheduler gives the CPU the work on them in
splits of its own; which non-weight nodes land there is the option's design and is priced by its speed, so it is
inventoried, not judged. What is judged (review of 09a7a43, frozen before the load):
  1. loader: the last load phase (as r2_placement.py) has a "layer N assigned to device" line for every index 0..n
     (n = the table's highest block + 1, the output layer), each naming the session; a missing index is a difference;
  2. no node in a CPU split has a model weight as a source, except GET_ROWS on token_embd.weight (the input lookup)
     and nodes proved empty in that graph (review of 98ebbd0, as r2_placement.py --empty-cpu-ok): the node's op and
     name were declined by the backend with a zero-element result shape in the supports-op block logged for that graph
     (the queries between the previous graph's print and this one's "## SPLIT #0"), and the same block has no
     accepted or non-empty query under that op and name. A source is a model weight when its printed name, after any
     "<backend>#" copy prefix and "#<n>" copy suffix, starts with "blk." or is the start (6 characters or more) of a
     non-block tensor of the table (output_norm.weight, token_embd.weight);
  3. per graph (review of 98ebbd0), every block weight and output_norm.weight of the table is read by a node under the
     session or by a proved-empty CPU node (a copy's cut name counts for every table tensor it is the start of), and
     the graph has exactly one result_output node, under the session or proved empty, reading token_embd.weight (the
     tied, duplicated output).
The CPU splits' node inventory (op counts over the last phase's graphs) is printed for the record.
Exit 0 OK, 1 DIFF (each difference printed), 3 invalid input (no loader lines, no graph, a node line that does not
parse, an unreadable file)."""
import argparse, collections, re, sys

PREFIX = re.compile(r"\d+\.\d{2}\.\d{3}\.\d{3} [IWED] ")
LOADER = re.compile(r"load_tensors: layer\s+(\d+) assigned to device (\S+?),")
SPLIT = re.compile(r"^## SPLIT #(\d+): (\S+) #")
NODE = re.compile(r"^node #\s*(\d+) \(\s*([A-Z_0-9]+)\): (.{20}) \(.{5}\) \[.{5} .{8}\] use=\d+,c=\d+:(.*)$")
SRC = re.compile(r"(.{20}) \(.{5}\) \[.{5} .{8}\]")
SUPP = re.compile(r"^ggml-hex: \S+ supports-op ([A-Z_0-9]+)\|(.*)$")


def bad(msg):
    print(f"INVALID: {msg}"); sys.exit(3)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("log"); ap.add_argument("--tensors", required=True)
    ap.add_argument("--session", required=True)
    a = ap.parse_args()
    try:
        raw = open(a.log, errors="replace").read()
        names = [l.split("\t")[0] for l in open(a.tensors)][1:]
    except OSError as e:
        bad(f"cannot read: {e}")
    others = [n for n in names if n and not n.startswith("blk.")]
    blk_idx = [int(n.split(".")[1]) for n in names if n.startswith("blk.")]
    if not blk_idx or "token_embd.weight" not in names:
        bad("no block weights or no token_embd.weight in the tensor table")
    n_layer = max(blk_idx) + 1
    required = [n for n in names if n and n != "token_embd.weight"]
    def strip(src):
        x = src.split("#", 1)[1] if "#" in src else src
        return re.sub(r"#\d+$", "", x)
    def weight(src):
        x = strip(src)
        return x.startswith("blk.") or any(len(x) >= 6 and o.startswith(x) for o in others)
    def covers(src):
        x = strip(src)
        if x != src:   # a copy: its cut name counts for every table tensor it starts
            return {n for n in required if len(x) >= 6 and n.startswith(x)}
        return {n for n in required if n[:20] == x}
    lines = PREFIX.sub("", raw).splitlines()
    starts = [i for i, l in enumerate(lines) if LOADER.search(l) and (i == 0 or not LOADER.search(lines[i - 1]))]
    if not starts:
        bad("no loader assignment lines (was -lv 5 set?)")
    print(f"phases: {len(starts)}; judged: the last, from line {starts[-1] + 1}")
    lines = lines[starts[-1]:]
    diffs, graphs, layers, cur = [], [], {}, None
    pend_e, pend_n = set(), set()
    for i, l in enumerate(lines, 1):
        m = LOADER.search(l)
        if m:
            layers[int(m.group(1))] = m.group(2); continue
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
                graphs.append({"empty": pend_e - pend_n, "nodes": []}); pend_e, pend_n = set(), set()
            cur = m.group(2); continue
        if l.startswith("node #"):
            m = NODE.match(l)
            if not m: bad(f"line {i}: a node line that does not parse")
            if graphs and cur is not None:
                graphs[-1]["nodes"].append((cur, m.group(1), m.group(2), m.group(3).strip(),
                                            [x.strip() for x in SRC.findall(m.group(4))]))
    if not graphs:
        bad("no scheduler graph (was GGML_SCHED_DEBUG=2 set?)")
    for il in range(n_layer + 1):
        if il not in layers: diffs.append(f"layer {il}: no loader line")
        elif layers[il] != a.session: diffs.append(f"layer {il}: on {layers[il]}, declared {a.session}")
    extra = sorted(k for k in layers if k > n_layer)
    if extra: diffs.append(f"loader lines for layers beyond {n_layer}: {extra}")
    inv, n_empty = collections.Counter(), 0
    for gi, g in enumerate(graphs, 1):
        got, outs = set(), []
        for dev, nid, op, name, srcs in g["nodes"]:
            empty = dev == "CPU" and (op, name[:20]) in g["empty"]
            if dev == "CPU":
                inv[op] += 1; n_empty += empty
                for s in srcs:
                    if weight(s) and not empty and not (op == "GET_ROWS" and s == "token_embd.weight"):
                        diffs.append(f"graph {gi}: CPU node #{nid} {op} {name} reads weight {s}")
            if dev == a.session or empty:
                for s in srcs: got |= covers(s)
                if name == "result_output": outs.append(srcs)
            elif name == "result_output":
                diffs.append(f"graph {gi}: result_output under {dev}")
        miss = [n for n in required if n not in got]
        if miss: diffs.append(f"graph {gi}: {len(miss)} table weights not read under {a.session}, e.g. {miss[:3]}")
        if len(outs) != 1 or not any(strip(s) == "token_embd.weight" for s in outs[0] if outs):
            diffs.append(f"graph {gi}: {len(outs)} result_output node(s) under {a.session} reading token_embd.weight, expected 1")
    print(f"graphs: {len(graphs)}; loader lines {len(layers)} (0..{n_layer} required); table weights required per "
          f"graph: {len(required)}; CPU nodes proved empty: {n_empty}")
    print("CPU split inventory: " + (", ".join(f"{k} {v}" for k, v in sorted(inv.items())) or "none"))
    for d in diffs[:50]: print(f"DIFF {d}")
    if len(diffs) > 50: print(f"DIFF ... {len(diffs) - 50} more")
    print("RESULT cpu-weight-check: " + ("OK" if not diffs else f"DIFF ({len(diffs)})"))
    sys.exit(1 if diffs else 0)


if __name__ == "__main__":
    main()
