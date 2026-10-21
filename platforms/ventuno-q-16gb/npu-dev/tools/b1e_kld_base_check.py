#!/usr/bin/env python3
"""b1e_kld_base_check.py (NPU dev plan B1e, b1-bonsai/b1e-s2diag/SPEC.txt; review of f827e4c): validate a
llama-perplexity --kl-divergence-base file against the sample the stage declares, before any reading uses it.

  b1e_kld_base_check.py <base.kld> <ids file> --n-ctx N --n-vocab V --n-chunk C

File format (tools/perplexity/perplexity.cpp at ff5a2337, as r1_t7_compare.cpp documents): "_logits_", n_ctx (u32),
n_vocab (i32), n_chunk (i32), the evaluation tokens (n_chunk x n_ctx i32, little-endian), then per chunk
n_ctx - 1 - n_ctx/2 rows of nv = 2*((n_vocab+1)/2) + 4 uint16, each row starting with two float32 (scale,
min_log_prob). The ids file is llama-tokenize --ids output for the same model and text (a Python list), an independent
tokenization: the stored tokens must equal its first n_chunk x n_ctx ids.
Checks, failing closed (exit 3): the magic; the header equal to the declared n_ctx, n_vocab and n_chunk; the exact
size 20 + 4*n_chunk*n_ctx + 2*n_chunk*(n_ctx-1-n_ctx//2)*nv bytes; the stored tokens equal to the ids; every row's
scale and min_log_prob finite and scale positive. Prints the header, the scored positions (n_chunk*(n_ctx-1-n_ctx//2)),
the stored tokens' sha256 and "RESULT VALID"; exit 0. Exit 2 on a usage error.
"""
import ast, hashlib, math, os, struct, sys


def main(argv):
    args, opt = [], {"--n-ctx": None, "--n-vocab": None, "--n-chunk": None}
    it = iter(argv[1:])
    for a in it:
        if a in opt:
            try:
                opt[a] = int(next(it))
            except (StopIteration, ValueError):
                print(f"usage: {a} needs an integer", file=sys.stderr)
                return 2
        else:
            args.append(a)
    if len(args) != 2 or None in opt.values():
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    base, ids_path = args
    nc, nvoc, nk = opt["--n-ctx"], opt["--n-vocab"], opt["--n-chunk"]

    def bad(why):
        print(f"RESULT INVALID {why}")
        return 3

    nv = 2 * ((nvoc + 1) // 2) + 4
    rows = nc - 1 - nc // 2
    want = 20 + 4 * nk * nc + 2 * nk * rows * nv
    try:
        size = os.path.getsize(base)
        f = open(base, "rb")
    except OSError as e:
        return bad(f"cannot open base: {e}")
    with f:
        if f.read(8) != b"_logits_":
            return bad("no _logits_ magic")
        hdr = f.read(12)
        if len(hdr) != 12:
            return bad("short header")
        h_ctx, h_voc, h_chunk = struct.unpack("<Iii", hdr)
        print(f"header n_ctx {h_ctx}, n_vocab {h_voc}, n_chunk {h_chunk}")
        if (h_ctx, h_voc, h_chunk) != (nc, nvoc, nk):
            return bad(f"header ({h_ctx}, {h_voc}, {h_chunk}) is not the declared ({nc}, {nvoc}, {nk})")
        if size != want:
            return bad(f"size {size} bytes, expected {want}")
        tok = f.read(4 * nk * nc)
        try:
            ids = ast.literal_eval(open(ids_path).read().strip())
        except (OSError, ValueError, SyntaxError) as e:
            return bad(f"ids file unreadable: {e}")
        if not isinstance(ids, list) or len(ids) < nk * nc:
            return bad(f"ids file holds {len(ids) if isinstance(ids, list) else 'no list'} ids, fewer than {nk * nc}")
        stored = list(struct.unpack(f"<{nk * nc}i", tok))
        if stored != ids[: nk * nc]:
            i = next(j for j, (a, b) in enumerate(zip(stored, ids)) if a != b)
            return bad(f"stored tokens differ from the ids at position {i} ({stored[i]} vs {ids[i]})")
        start = 20 + 4 * nk * nc
        for r in range(nk * rows):
            f.seek(start + 2 * nv * r)
            scale, mn = struct.unpack("<ff", f.read(8))
            if not (math.isfinite(scale) and math.isfinite(mn) and scale > 0):
                return bad(f"row {r}: scale {scale}, min_log_prob {mn}")
    print(f"scored positions {nk * rows} ({nk} chunks x {rows}); size {size} bytes")
    print(f"tokens sha256 {hashlib.sha256(tok).hexdigest()}")
    print("RESULT VALID")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
