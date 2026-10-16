#!/usr/bin/env python3
"""r1_budget.py (NPU dev plan R1): M2's conservative pre-load memory budget, per NPU session and for the whole board.

  r1_budget.py <npu-dev dir> [--avail MiB] [--floor MiB] [--proc MiB]

Inputs (all committed): r1-host/k3/table-M2.txt and table-M2-npu-r-prime.txt (weights per session under master's
NPU allocation rule, the "SESSIONS 4 best explicit split" and "SESSIONS 3 best explicit split" lines), and the
dry-run outputs in r1-budget/ (matrix.txt, npu-r-prime.txt, cpu-bound.txt: llama-fit-params --fit-print on at
af0579c78 with RPC devices standing in for the NPU sessions; per device "model context compute" in MiB, floored).

Per session (against one session's mappable VA, ggml-hexagon.cpp af0579c78 :4988-4989: HTP_OP_MAX_VMEM_DEFAULT
3,355,443,200 B minus the op queue's shared buffer, SHM below):
  weights (K3 table, master rule)                      [the dry run's "model" uses CPU sizes; not used]
  + context (dry run: KV + recurrent state) + 1        [+1: the dry run floors to MiB]
  + compute (dry run) + 1
  + on session 0 only: the CPU compute buffer, bounded by the whole graph on the CPU (cpu-bound.txt)
    [llama-context.cpp :496-504 allocates the CPU compute buffer from the first device's host buffer type, which
     that session supports (ggml-hexagon.cpp :9591-9597), so its tensors can be mapped into session 0]
  + on the output session: the output buffer, 1 MiB bound (np 1: 1 x 128,000 x 4 B)
Whole board (shared DRAM): every NPU allocation (K3: all placeable weights incl. the tied copy) + context + NPU
compute + CPU weights + the CPU compute bound + SHM per session + the process (--proc, a bound), against
--avail (idle MemAvailable) minus --floor (the wrapper's live floor, 1.5 GB = 1,536 MiB).
Output: one line per configuration, ADMIT only if every session and the board keep a non-negative margin."""
import argparse, os, re, sys

MiB = 1024 * 1024
VMEM = 3355443200 / MiB                               # HTP_OP_MAX_VMEM_DEFAULT (htp-ops.h :138)
# op queue shm (ggml-hexagon.cpp :4120-4137): depth 8 x (16 buf descs x 24 + 1280 x 14 tensors x 56 + 1280 ops x
# (232 op desc + 48 prof desc)); profiling off (no trace buffer)
SHM = 8 * (16 * 24 + 1280 * 14 * 56 + 1280 * (232 + 48)) / MiB
LIMIT = VMEM - SHM


def table_weights(path, n):
    for line in open(path):
        if re.match(rf"\s*SESSIONS {n} best explicit split", line):
            split = re.search(r"--tensor-split ([\d,]+)", line).group(1)
            return split, [int(w) for w in re.findall(r"weights (\d+) \+ KV", line)], \
                int(re.search(r"CPU weights (\d+)", line).group(1))
    raise SystemExit(f"no 'SESSIONS {n} best explicit split' line in {path}")


def dry(path, key):
    for line in open(path):
        if line.startswith(key + " |"):
            devs = {}
            for part in line.split("|", 1)[1].split(";"):
                f = part.split()
                if len(f) == 4:
                    devs[f[0]] = tuple(int(x) for x in f[1:])
            return devs
    raise SystemExit(f"no line '{key}' in {path}")


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("npudev")
    ap.add_argument("--avail", type=float, default=13748); ap.add_argument("--floor", type=float, default=1536)
    ap.add_argument("--proc", type=float, default=512)
    a = ap.parse_args()
    k3, bd = os.path.join(a.npudev, "r1-host/k3"), os.path.join(a.npudev, "r1-budget")
    total_npu = float(re.search(r"NPU allocation of everything placeable ([\d.]+) MiB",
                                open(os.path.join(k3, "table-M2.txt")).read()).group(1))
    cpu_bound = {int(m.group(1)): int(m.group(2)) for m in
                 re.finditer(r"CPU-only ub=(\d+) np=1 \| Host \d+ \d+ (\d+)", open(os.path.join(bd, "cpu-bound.txt")).read())}
    print(f"session limit {LIMIT:.1f} MiB (VMEM {VMEM:.1f} - op queue shm {SHM:.1f}); board room {a.avail:.0f} - floor "
          f"{a.floor:.0f} = {a.avail - a.floor:.0f} MiB; process bound {a.proc:.0f} MiB")
    rows = []
    for variant, tfile, dfile, keyfmt in [("NPU-R", "table-M2.txt", "matrix.txt", "S={n} ts={ts} ub={ub} np={np}"),
                                         ("NPU-R'", "table-M2-npu-r-prime.txt", "npu-r-prime.txt",
                                          "S={n} NPU-R' (-ot token_embd=CPU) ub={ub} np={np}")]:
        for n in (3, 4):
            split, w, cpu_w = table_weights(os.path.join(k3, tfile), n)
            for ub in (512, 1024, 2048):
                for np_ in (1, 4):
                    key = keyfmt.format(n=n, ts=split, ub=ub, np=np_)
                    try:
                        d = dry(os.path.join(bd, dfile), key)
                    except SystemExit:
                        continue
                    devs = [d[f"RPC{i}"] for i in range(n)]
                    cbound = cpu_bound[ub]
                    sess = []
                    for i, (_, ctx, comp) in enumerate(devs):
                        v = w[i] + ctx + 1 + comp + 1 + (cbound if i == 0 else 0) + (1 if i == n - 1 else 0)
                        sess.append(v)
                    board = (total_npu if variant == "NPU-R" else sum(w)) + sum(c + 1 for _, c, _ in devs) \
                        + sum(c + 1 for _, _, c in devs) + cpu_w + cbound + 1 + n * SHM + a.proc
                    worst = min(LIMIT - v for v in sess); room = a.avail - a.floor - board
                    ok = worst >= 0 and room >= 0
                    rows.append((variant, n, split, ub, np_, sess, worst, board, room, ok))
                    print(f"{variant:6} S={n} ts={split:11} ub={ub:4} np={np_} | sessions " +
                          " ".join(f"{v:.0f}" for v in sess) + f" | fullest margin {worst:+.0f} | board {board:.0f}, "
                          f"margin {room:+.0f} | {'ADMIT' if ok else 'NO'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
