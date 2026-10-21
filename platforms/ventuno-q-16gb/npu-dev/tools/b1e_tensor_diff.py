#!/usr/bin/env python3
"""b1e_tensor_diff.py (NPU dev plan B1e, b1-bonsai/b1e-s2diag/SPEC.txt): first diverging tensor between two
llama-eval-callback dumps of the same prompt (A: the reference run, B: the run under test).

  b1e_tensor_diff.py <dump A> <dump B> [--rel 1e-3] [--gross 0.1] [--show 8]

A dump is the eval-callback's output (common/debug.cpp at ff5a2337): a header line per evaluated tensor,
"common_debug_cb_eval: <name> = (<type>) <op>(<src0>{..}, <src1>}) = {<ne0>, <ne1>, <ne2>, <ne3>}", then its sampled
values, then "sum = <float>" (quantized tensors print no sum and are skipped). Lines from other loggers may be
interleaved; only header and sum lines are read. A tensor is keyed by its name and its occurrence number (the same
name can be computed more than once per graph); keys present in only one dump (the copies a second session adds,
e.g. "HTP0:1#node_0") are listed, not compared.

Walking A's order, a key differs when |sumA - sumB| > rel * max(1, |sumA|, |sumB|), or the shapes differ, or exactly
one sum is not finite. Prints the counts, the first differing key ("FIRST"), the first beyond --gross ("GROSS") and the
--show keys from the first, then one RESULT line:
  RESULT SAME (n compared)              no compared key differs
  RESULT DIFFER first=<key> op=<op>     the first differing key in A's order
Exit 0 SAME, 1 DIFFER, 2 usage or a dump with no tensors.
"""
import math, re, sys

HEAD = re.compile(r"common_debug_cb_eval:\s+(.+?) = \((\w+)\)\s+(\S+)\(.*\) = \{([^}]*)\}\s*$")
SUM = re.compile(r"^\s*sum = (\S+)\s*$")


def parse(path):
    order, rec, seen = [], {}, {}
    cur = None
    with open(path, errors="replace") as f:
        for line in f:
            m = HEAD.search(line)
            if m:
                name, typ, op, ne = m.group(1).strip(), m.group(2), m.group(3), m.group(4).replace(" ", "")
                seen[name] = seen.get(name, 0) + 1
                cur = (name, seen[name])
                order.append(cur)
                rec[cur] = {"type": typ, "op": op, "ne": ne, "sum": None}
                continue
            m = SUM.match(line)
            if m and cur is not None and rec[cur]["sum"] is None:
                try:
                    rec[cur]["sum"] = float(m.group(1))
                except ValueError:
                    rec[cur]["sum"] = float("nan")
    return order, rec


def key_str(k):
    return f"{k[0]}#{k[1]}"


def differs(a, b, rel):
    if a["ne"] != b["ne"]:
        return True, math.inf
    sa, sb = a["sum"], b["sum"]
    fa, fb = math.isfinite(sa), math.isfinite(sb)
    if not fa or not fb:
        return fa != fb, (math.inf if fa != fb else 0.0)
    d = abs(sa - sb) / max(1.0, abs(sa), abs(sb))
    return d > rel, d


def main(argv):
    args, opt = [], {"--rel": 1e-3, "--gross": 0.1, "--show": 8}
    it = iter(argv[1:])
    for a in it:
        if a in opt:
            try:
                opt[a] = type(opt[a])(next(it))
            except (StopIteration, ValueError):
                print(f"usage: bad value for {a}", file=sys.stderr)
                return 2
        else:
            args.append(a)
    if len(args) != 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    oa, ra = parse(args[0])
    ob, rb = parse(args[1])
    if not oa or not ob:
        print(f"no tensors in {'A' if not oa else 'B'}", file=sys.stderr)
        return 2
    only_a = [k for k in oa if k not in rb]
    only_b = [k for k in ob if k not in ra]
    diffs, n = [], 0
    for k in oa:
        if k not in rb or ra[k]["sum"] is None or rb[k]["sum"] is None:
            continue
        n += 1
        bad, d = differs(ra[k], rb[k], opt["--rel"])
        if bad:
            diffs.append((k, d))
    print(f"A {len(oa)} tensors, B {len(ob)}; compared {n}; only in A {len(only_a)}, only in B {len(only_b)}")
    for lab, ks in (("only in A", only_a), ("only in B", only_b)):
        if ks:
            print(f"{lab}: " + ", ".join(key_str(k) for k in ks[:12]) + (" ..." if len(ks) > 12 else ""))
    if not diffs:
        print(f"RESULT SAME ({n} compared)")
        return 0
    gross = next((x for x in diffs if x[1] > opt["--gross"]), None)
    print(f"differing: {len(diffs)} of {n} (rel > {opt['--rel']})")
    for k, d in diffs[: opt["--show"]]:
        print(f"  {key_str(k)} op={ra[k]['op']} ne={{{ra[k]['ne']}}} sumA={ra[k]['sum']} sumB={rb[k]['sum']} rel={d:.3g}")
    f = diffs[0][0]
    print(f"FIRST {key_str(f)} op={ra[f]['op']}")
    print(f"GROSS {key_str(gross[0]) + ' op=' + ra[gross[0]]['op'] if gross else 'none'} (rel > {opt['--gross']})")
    print(f"RESULT DIFFER first={key_str(f)} op={ra[f]['op']}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
