#!/usr/bin/env python3
"""b1e_tensor_diff.py (NPU dev plan B1e, b1-bonsai/b1e-s2diag/SPEC.txt): first differing tensor checksum between two
llama-eval-callback dumps of the same prompt (A: the reference run, B: the run under test).

  b1e_tensor_diff.py <dump A> <dump B> [--rel 1e-3] [--gross 0.1] [--show 8] [--require result_output]

A dump is the eval-callback's output (common/debug.cpp at ff5a2337): a header line per evaluated tensor,
"common_debug_cb_eval: <name> = (<type>) <op>(<src0>{..}, <src1>{..}}) = {<ne0>, <ne1>, <ne2>, <ne3>}", then, for each
of the ne3 slices, a sample of its values (all of a dimension up to 6, else 3 at each end, printed %12.4f) and the
tensor's total "sum = <float>" (the same total repeated per slice). Quantized tensors print no values and are skipped.
Everything up to the next header belongs to the tensor; a non-quantized tensor must carry exactly ne3 sums, all equal,
and exactly ne3 * c(ne2) * c(ne1) * c(ne0) sample values (c(x) = x if x <= 6 else 6), else the dump is INCOMPLETE. Lines from other loggers may be interleaved. A tensor is keyed by its name and occurrence
number. This is checksum-level evidence: the sum and the printed sample, not the full tensor, and only src0/src1 of each
node are named.

Two keys differ when their shapes differ, when |sumA - sumB| > rel * max(1, |sumA|, |sumB|), or when any printed sample
value differs by more than rel * max(1, the largest |sample| of either). Fails closed (RESULT INCOMPLETE, exit 3) when
an options value is not finite and positive, when a non-quantized tensor's sums or sample are incomplete (above),
when a sum or sample is not finite on either side, when a key of A is missing from B or B has an extra key that is not a
session copy ("<backend>#<name>"), when a required tensor (--require, default result_output; repeatable) is missing
from either dump, or when nothing is compared.
Prints counts, MAXREL (the largest relative difference over every compared key, full precision), the first differing
key in A's order (FIRST) with its sources, the first key over --gross (GROSS, found and printed independently of
--rel, also before a SAME result), the
--show keys from the first, then one RESULT line:
  RESULT SAME (n compared, maxrel x)           exit 0
  RESULT DIFFER first=<key> op=<op>            exit 1
  RESULT INCOMPLETE <reason>                   exit 3
Exit 2 on a usage error.
"""
import math, re, sys

HEAD = re.compile(r"common_debug_cb_eval:\s+(.+?) = \((\w+)\)\s+(\S+)\((.*)\) = \{([^}]*)\}\s*$")
SUM = re.compile(r"^\s*sum = (\S+)\s*$")
NUM = re.compile(r"-?(?:\d+\.\d+|\d+)(?:e[-+]?\d+)?|-?nan|-?inf", re.I)
PLAIN = {"f32", "f16", "bf16", "i64", "i32", "i16", "i8"}
COPY = re.compile(r"^[A-Za-z]+\d*(?::\d+)?#")


def fnum(s):
    try:
        return float(s)
    except ValueError:
        return float("nan")


def parse(path):
    order, rec, seen, cur = [], {}, {}, None
    with open(path, errors="replace") as f:
        for line in f:
            m = HEAD.search(line)
            if m:
                name, typ, op, srcs, ne = m.group(1).strip(), m.group(2), m.group(3), m.group(4), m.group(5).replace(" ", "")
                seen[name] = seen.get(name, 0) + 1
                cur = (name, seen[name])
                order.append(cur)
                rec[cur] = {"type": typ, "op": op, "ne": ne, "src": re.sub(r"\{[^}]*\}", "", srcs).strip(" ,}"),
                            "sum": None, "sums": [], "vals": []}
                continue
            if cur is None:
                continue
            m = SUM.match(line)
            if m:
                rec[cur]["sums"].append(fnum(m.group(1)))
                rec[cur]["sum"] = rec[cur]["sums"][0]
                continue
            s = line.strip()
            if s.startswith("[") and s.endswith("],") and len(s) > 3:
                rec[cur]["vals"] += [fnum(x) for x in NUM.findall(s[1:-2]) if x != "..."]
    return order, rec


def coverage(r):
    """None if the tensor's sums and sample are complete for its shape (common/debug.cpp, n = 3), else the reason"""
    try:
        ne = [int(x) for x in r["ne"].split(",")]
    except ValueError:
        return f"shape {{{r['ne']}}} unreadable"
    if len(ne) != 4:
        return f"shape {{{r['ne']}}} is not 4-d"
    c = [x if x <= 6 else 6 for x in ne[:3]]
    if len(r["sums"]) != ne[3]:
        return f"{len(r['sums'])} sum line(s), expected {ne[3]} (ne3)"
    if any(x != r["sums"][0] and not (math.isnan(x) and math.isnan(r["sums"][0])) for x in r["sums"]):
        return "its repeated sums differ"
    want = ne[3] * c[0] * c[1] * c[2]
    if len(r["vals"]) != want:
        return f"{len(r['vals'])} sample value(s), expected {want}"
    return None


def ks(k):
    return f"{k[0]}#{k[1]}"


def rel_of(a, b):
    """relative difference of two keys (inf for a shape or sample-length mismatch)"""
    if a["ne"] != b["ne"] or len(a["vals"]) != len(b["vals"]):
        return math.inf
    d = abs(a["sum"] - b["sum"]) / max(1.0, abs(a["sum"]), abs(b["sum"]))
    if a["vals"]:
        scale = max(1.0, max(abs(x) for x in a["vals"] + b["vals"]))
        d = max(d, max(abs(x - y) for x, y in zip(a["vals"], b["vals"])) / scale)
    return d


def finite(r):
    return r["sum"] is not None and math.isfinite(r["sum"]) and all(math.isfinite(v) for v in r["vals"])


def main(argv):
    args, req, opt = [], [], {"--rel": 1e-3, "--gross": 0.1, "--show": 8}
    it = iter(argv[1:])
    for a in it:
        if a in opt or a == "--require":
            try:
                v = next(it)
            except StopIteration:
                print(f"usage: {a} needs a value", file=sys.stderr)
                return 2
            if a == "--require":
                req.append(v)
                continue
            try:
                opt[a] = type(opt[a])(v)
            except ValueError:
                print(f"usage: bad value for {a}", file=sys.stderr)
                return 2
        else:
            args.append(a)
    if len(args) != 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    req = req or ["result_output"]

    def incomplete(why):
        print(f"RESULT INCOMPLETE {why}")
        return 3

    for o in ("--rel", "--gross"):
        if not (math.isfinite(opt[o]) and opt[o] > 0):
            return incomplete(f"{o} {opt[o]} is not finite and positive")
    oa, ra = parse(args[0])
    ob, rb = parse(args[1])
    print(f"A {len(oa)} tensors, B {len(ob)}")
    for lab, o, r in (("A", oa, ra), ("B", ob, rb)):
        for n in req:
            if not any(k[0] == n for k in o):
                return incomplete(f"required tensor {n} missing from {lab}")
        for k in o:
            x = r[k]
            if x["type"] in PLAIN and x["sum"] is None:
                return incomplete(f"{lab} {ks(k)} ({x['type']}) has no sum")
            if x["sum"] is not None:
                why = coverage(x)
                if why:
                    return incomplete(f"{lab} {ks(k)}: {why}")
            if x["sum"] is not None and not finite(x):
                return incomplete(f"{lab} {ks(k)} has a non-finite sum or sample")
    only_a = [k for k in oa if k not in rb]
    extra_b = [k for k in ob if k not in ra]
    copies = [k for k in extra_b if COPY.match(k[0])]
    other_b = [k for k in extra_b if not COPY.match(k[0])]
    print(f"only in B, session copies: {len(copies)}" + (": " + ", ".join(ks(k) for k in copies[:12]) if copies else ""))
    if only_a:
        return incomplete(f"{len(only_a)} key(s) of A missing from B, first {ks(only_a[0])}")
    if other_b:
        return incomplete(f"{len(other_b)} key(s) only in B that are not session copies, first {ks(other_b[0])}")
    rels, n = [], 0
    for k in oa:
        if ra[k]["sum"] is None or rb[k]["sum"] is None:
            continue
        n += 1
        rels.append((k, rel_of(ra[k], rb[k])))
    if n == 0:
        return incomplete("no tensor compared")
    maxrel = max(d for _, d in rels)
    print(f"compared {n}; MAXREL {maxrel!r}")
    diffs = [(k, d) for k, d in rels if d > opt["--rel"]]
    gross = next((x for x in rels if x[1] > opt["--gross"]), None)
    print(f"GROSS {ks(gross[0]) + ' op=' + ra[gross[0]]['op'] if gross else 'none'} (rel > {opt['--gross']})")
    if not diffs:
        print(f"RESULT SAME ({n} compared, maxrel {maxrel!r})")
        return 0
    print(f"differing: {len(diffs)} of {n} (rel > {opt['--rel']})")
    for k, d in diffs[: opt["--show"]]:
        print(f"  {ks(k)} op={ra[k]['op']} src=[{ra[k]['src']}] ne={{{ra[k]['ne']}}} sumA={ra[k]['sum']!r} "
              f"sumB={rb[k]['sum']!r} rel={d!r}")
    f = diffs[0][0]
    print(f"FIRST {ks(f)} op={ra[f]['op']} src=[{ra[f]['src']}]")
    print(f"RESULT DIFFER first={ks(f)} op={ra[f]['op']}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
