#!/usr/bin/env python3
"""b1_cpu_weight_check.py (NPU dev plan B1d-4B, option CK): in a llama-server or llama-perplexity log taken with -lv 5
and GGML_SCHED_DEBUG=2, check that the CPU does no work on the model's weights, whatever else it runs.

  b1_cpu_weight_check.py <log> --tensors <table.tsv> --session HTP0:0

CK keeps the KV cache and the recurrent state on the CPU (-nkvo), so the scheduler gives the CPU the work on them in
splits of its own; which non-weight nodes land there is the option's design and is priced by its speed, so it is
inventoried, not judged. What is judged (review of 09a7a43, frozen before the load):
  1. loader: every "layer N assigned to device" line of the last load phase (as r2_placement.py) names the session;
  2. no node in a CPU split has a model weight as a source, except GET_ROWS on token_embd.weight (the input lookup).
     A source is a model weight when its printed name, after any "<backend>#" copy prefix, starts with "blk." or is
     the start (6 characters or more) of a non-block tensor of the table (output_norm.weight, token_embd.weight);
  3. every block weight of the table appears, cut to 20 characters as the scheduler prints it, as a source under a
     split of the session in at least one graph.
The CPU splits' node inventory (op counts over the last phase's graphs) is printed for the record.
Exit 0 OK, 1 DIFF (each difference printed), 3 invalid input (no loader lines, no graph, a node line that does not
parse, an unreadable file)."""
import argparse, collections, re, sys

PREFIX = re.compile(r"\d+\.\d{2}\.\d{3}\.\d{3} [IWED] ")
LOADER = re.compile(r"load_tensors: layer\s+(\d+) assigned to device (\S+?),")
SPLIT = re.compile(r"^## SPLIT #(\d+): (\S+) #")
NODE = re.compile(r"^node #\s*(\d+) \(\s*([A-Z_0-9]+)\): (.{20}) \(.{5}\) \[.{5} .{8}\] use=\d+,c=\d+:(.*)$")
SRC = re.compile(r"(.{20}) \(.{5}\) \[.{5} .{8}\]")


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
    blocks = {n[:20] for n in names if n.startswith("blk.")}
    others = [n for n in names if n and not n.startswith("blk.")]
    if not blocks:
        bad("no block weights in the tensor table")
    def weight(src):
        s = src.split("#", 1)[1] if "#" in src else src
        return s.startswith("blk.") or any(len(s) >= 6 and o.startswith(s) for o in others)
    lines = PREFIX.sub("", raw).splitlines()
    starts = [i for i, l in enumerate(lines) if LOADER.search(l) and (i == 0 or not LOADER.search(lines[i - 1]))]
    if not starts:
        bad("no loader assignment lines (was -lv 5 set?)")
    print(f"phases: {len(starts)}; judged: the last, from line {starts[-1] + 1}")
    lines = lines[starts[-1]:]
    diffs, graphs, cur, layers = [], 0, None, {}
    inv, on_session = collections.Counter(), set()
    for i, l in enumerate(lines, 1):
        m = LOADER.search(l)
        if m:
            layers[int(m.group(1))] = m.group(2); continue
        m = SPLIT.match(l)
        if m:
            if m.group(1) == "0": graphs += 1
            cur = m.group(2); continue
        if l.startswith("node #"):
            m = NODE.match(l)
            if not m: bad(f"line {i}: a node line that does not parse")
            if cur is None: continue
            op, srcs = m.group(2), [x.strip() for x in SRC.findall(m.group(4))]
            if cur == "CPU":
                inv[op] += 1
                for s in srcs:
                    if weight(s) and not (op == "GET_ROWS" and s == "token_embd.weight"):
                        diffs.append(f"graph {graphs}: CPU node #{m.group(1)} {op} {m.group(3).strip()} reads weight {s}")
            elif cur == a.session:
                on_session.update(s for s in srcs if s in blocks)
    if not graphs:
        bad("no scheduler graph (was GGML_SCHED_DEBUG=2 set?)")
    for il, dev in sorted(layers.items()):
        if dev != a.session: diffs.append(f"layer {il}: on {dev}, declared {a.session}")
    missing = sorted(blocks - on_session)
    if missing:
        diffs.append(f"{len(missing)} block weights never read under {a.session}, e.g. {missing[:3]}")
    print(f"graphs: {graphs}; layers on {a.session}: {sum(d == a.session for d in layers.values())}/{len(layers)}; "
          f"block weights read under {a.session}: {len(blocks & on_session)}/{len(blocks)}")
    print("CPU split inventory: " + (", ".join(f"{k} {v}" for k, v in sorted(inv.items())) or "none"))
    for d in diffs[:50]: print(f"DIFF {d}")
    if len(diffs) > 50: print(f"DIFF ... {len(diffs) - 50} more")
    print("RESULT cpu-weight-check: " + ("OK" if not diffs else f"DIFF ({len(diffs)})"))
    sys.exit(1 if diffs else 0)


if __name__ == "__main__":
    main()
