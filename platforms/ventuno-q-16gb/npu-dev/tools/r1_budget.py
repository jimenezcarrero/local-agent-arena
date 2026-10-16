#!/usr/bin/env python3
"""r1_budget.py (NPU dev plan R1; review of 6403ce1): M2's pre-load memory ledger, per NPU session (mappable VA) and
for the whole board (shared DRAM), in bytes, every component an upper bound of what it stands for.

  r1_budget.py <npu-dev dir> [--avail-mib 13748] [--floor-mib 1536] [--proc-mib 512]

Inputs (committed): r1-host/k3/table-M2.tsv (per tensor: NPU allocation under master's rule, padded to 128; role =
block index, "input" or "output"); r1-budget/ledger/<config>.out ("BUFT <name> model <B> context <B> compute <B>",
exact bytes from tools/r1_dryrun_ledger.cpp: master af0579c78's own no-allocation load with RPC devices standing in
for the sessions) and <config>.splits (the scheduler's split record: which split takes inputs from which).

Per session s (VA; limit = HTP_OP_MAX_VMEM_DEFAULT 3,355,443,200 B minus the op queue's pinned buffer, SHM below;
ggml-hexagon.cpp :4988-4989):
  W_s     exact: the K3 table's NPU allocation of every tensor placed on s (blocks by the split; on the output
          session the output-layer tensors (token_embd_norm) and, for NPU-R only, the tied copy of
          token_embd.weight, 229,376,000 B tiled; NPU-R' moves only that copy to the CPU)
  ctx_s   exact: the dry run's context (KV + recurrent state) on s
  comp_s  exact: the dry run's compute buffer on s
  clone   comp_{s-1} for s >= 1: the split record shows each session's activations arriving from the previous session's
          compute buffer; ggml_hexagon_cpy_tensor_async_virt (:9002-9017) maps that whole buffer into s (clone_buffer,
          :4710-4737). Inputs from the CPU (positions, masks, indices, the recurrent-state copy list) arrive by host
          copy (cpy_tensor_async returns false for a non-Hexagon source, :9020-9022), not by mapping.
          --clone-all instead adds every other session's compute buffer (an upper bound if the split record differs).
  cpu     on s = 0 only: the CPU compute buffer, allocated from session 0's host buffer type (llama-context.cpp
          :496-504) and usable by it directly (supports_buft :9591-9597), so mapped into session 0 when its ops read
          it; bounded by the whole graph on the CPU (cpu-ub<U>.out), which also covers ops the NPU might refuse
  align   + 127 B per graph node (HTP aligns compute tensors to 128; the dry run's devices to less), all nodes counted
  fence   + 64 KiB per session (the fence buffer, :4979, and peers' fence clones)
Board (DRAM, each allocation once): sum W_s + sum ctx_s + sum comp_s + CPU weights (token_embd 215,040,000 B; NPU-R'
  adds the separate CPU-repack copy of the tied output, 215,040,000 B) + the CPU compute bound + the output buffer
  (the workload's outputs x 128,000 x 4 B: --outputs) + S x (SHM + fence) + the process bound, against
  --avail-mib (idle MemAvailable) minus --floor-mib (the wrapper's live floor).
The output buffer is not counted in VA: logits reach it by a host copy from the output session (get_tensor), not
  by an NPU op. Not modelled (stated in the README): the NPU refusing an op for a VTCM or kernel-parameter reason."""
import argparse, os, re, sys

MiB = 1024 * 1024
VMEM = 3355443200                                            # htp-ops.h :138
SHM = 8 * (16 * 24 + 1280 * 14 * 56 + 1280 * (232 + 48))    # ggml-hexagon.cpp :4120-4137, defaults, profiling off
FENCE = 64 * 1024
TIED_TILED = 229376000                                       # token_embd.weight Q6_K, NPU allocation (K3 table)
TIED_FILE = 215040000
N_VOCAB = 128000
CONFIGS = [  # name, variant, sessions, split (layer counts), ubatch
    ("s3-r-ub512", "NPU-R", 3, [15, 13, 13], 512),
    ("s3-rp-ub512", "NPU-R'", 3, [14, 13, 14], 512),
    ("s4-r-ub512", "NPU-R", 4, [11, 10, 10, 10], 512),
    ("s4-r-ub1024", "NPU-R", 4, [11, 10, 10, 10], 1024),
    ("s4-rp-ub512", "NPU-R'", 4, [11, 10, 10, 10], 512),
    ("s4-rp-ub1024", "NPU-R'", 4, [11, 10, 10, 10], 1024),
    ("s4-rp-ub256", "NPU-R'", 4, [11, 10, 10, 10], 256),     # T3a amendment proposal (k5-t7/t3a-amendment.txt)
]


def weights(tsv, split, variant):
    bounds, acc = [], 0
    for n in split:
        acc += n; bounds.append(acc)            # layer index < bounds[s] -> session s; index 40 = the output layer
    w = [0] * len(split)
    for line in list(open(tsv))[1:]:
        f = line.rstrip("\n").split("\t")
        role, alloc = f[5], int(f[4])
        if role == "input":
            continue
        idx = 40 if role == "output" else int(role)
        w[next(s for s, b in enumerate(bounds) if idx < b)] += alloc
    if variant == "NPU-R":
        w[-1] += TIED_TILED
    return w


def ledger(path):
    devs, cpu = [], None
    for line in open(path):
        m = re.match(r"BUFT (\S+) model (\d+) context (\d+) compute (\d+)", line)
        if m:
            t = tuple(int(x) for x in m.groups()[1:])
            if m.group(1) == "CPU":
                cpu = t
            else:
                devs.append(t)
    return devs, cpu


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("npudev")
    ap.add_argument("--avail-mib", type=float, default=13748); ap.add_argument("--floor-mib", type=float, default=1536)
    ap.add_argument("--proc-mib", type=float, default=512); ap.add_argument("--clone-all", action="store_true")
    a = ap.parse_args()
    k3, ld = os.path.join(a.npudev, "r1-host/k3"), os.path.join(a.npudev, "r1-budget/ledger")
    limit = VMEM - SHM
    room = (a.avail_mib - a.floor_mib) * MiB
    print(f"session limit {limit / MiB:.2f} MiB (VMEM {VMEM / MiB:.2f} - shm {SHM / MiB:.2f}); board room "
          f"{room / MiB:.0f} MiB ({a.avail_mib:.0f} - floor {a.floor_mib:.0f}); process bound {a.proc_mib:.0f} MiB; "
          f"clone rule: {'every other session' if a.clone_all else 'previous session (split record)'}")
    for name, variant, n, split, ub in CONFIGS:
        devs, cpu = ledger(os.path.join(ld, name + ".out"))
        _, cpub = ledger(os.path.join(ld, f"cpu-ub{ub}.out"))
        nodes = int(re.search(r"nodes = (\d+)", open(os.path.join(ld, name + ".splits")).read()).group(1))
        assert len(devs) == n, name
        w = weights(os.path.join(k3, "table-M2.tsv"), split, variant)
        comp = [d[2] for d in devs]
        sess = []
        for s in range(n):
            clone = sum(comp[:s] + comp[s + 1:]) if a.clone_all else (comp[s - 1] if s > 0 else 0)
            v = w[s] + devs[s][1] + comp[s] + clone + (cpub[2] if s == 0 else 0) + nodes * 127 + FENCE
            sess.append(v)
        cpu_w = TIED_FILE + (TIED_FILE if variant == "NPU-R'" else 0)
        for outputs, label in ((1, "server -np 1"), (512, "all-logits -b 512")):
            board = sum(w) + sum(d[1] for d in devs) + sum(comp) + cpu_w + cpub[2] + outputs * N_VOCAB * 4 \
                + n * (SHM + FENCE) + a.proc_mib * MiB
            worst = min(limit - v for v in sess); bm = room - board
            print(f"{name:13} {variant:6} S={n} ts={','.join(map(str, split)):11} ub={ub:4} {label:17} | sessions "
                  + " ".join(f"{v / MiB:.1f}" for v in sess) + f" | fullest margin {worst / MiB:+.1f} | board "
                  f"{board / MiB:.1f}, margin {bm / MiB:+.1f} | {'within' if worst >= 0 and bm >= 0 else 'OVER'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
