R1 pre-load memory ledger for M2 (NPU dev plan section 6, R1), 2026-10-16; second pass after Codex's review of
6403ce1 (PR #65). Offline: no NPU, nothing staged; the model's weights were never read.

Status (third pass, after Codex's follow-up review of 5d1ff55): the op-support gap is closed offline (below):
master's own Hexagon support code accepts every node this graph places on an NPU session, with about 4x VTCM
headroom, so the Hexagon partition is the dry run's and the ledger's import graph and buffers stand for it.
Proposed R1 admission (for review and the owner): NPU-R', 4 sessions, --tensor-split 11,10,10,10, ubatch 512,
HMX on (the default). Three sessions are out under this ledger and the tested splits. T3a's 2048 replacement, K5
and T7 remain; nothing on the NPU before them and the owner's approval.

Method
  - Weights per session: exact bytes from the K3 tensor table (master's tiled NPU allocation, padded to 128).
  - Context (KV + recurrent state) and compute per session: exact bytes from master af0579c78's own no-allocation
    load (tools/r1_dryrun_ledger.cpp: the same no_alloc / load-mode NONE path as llama-fit-params, every allocation
    simulated from the metadata), with local RPC devices standing in for the sessions, on a header-only sparse copy
    of M2 (provenance.txt). ledger/<config>.out holds the bytes; ledger/<config>.splits the scheduler's split record.
  - The split record (GGML_SCHED_DEBUG=2, instrumented to print types and shapes: instrumentation.diff) shows the
    import graph: the CPU computes the embeddings, then session 0 -> 1 -> 2 -> 3, each session taking the previous
    session's activations (e.g. node_541, ffn_moe_out-10) plus small CPU inputs (positions, KQ mask, KV indices,
    the recurrent-state copy list rs_s_copy, an I32 graph input).
  - Per session, the mappable VA (limit 3,355,443,200 B - the op queue's pinned 10.39 MiB = 3,189.61 MiB):
      W + context + compute
      + clone: the previous session's whole compute buffer (ggml_hexagon_cpy_tensor_async_virt maps the source's
        entire buffer into the destination, :9002-9017 via clone_buffer :4710-4737; the CPU inputs arrive by host
        copy, :9020-9022). budget-clone-all.txt adds every other session's compute buffer instead (an upper bound
        should the import graph differ);
      + session 0: the CPU compute buffer (allocated from session 0's host buffer type, llama-context.cpp :496-504,
        which session 0 uses directly, :9591-9597), bounded by the whole graph on the CPU;
      + 127 B per graph node (HTP's 128-byte alignment), + 64 KiB fence.
  - Board (shared DRAM, each allocation once): all weights + context + compute + CPU weights (token_embd; NPU-R'
    adds the CPU-repack copy of the tied output) + the CPU compute bound + the output buffer for the workload
    (outputs x 128,000 x 4 B: 1 for a -np 1 server, 512 for all-logits work at -b 512) + op queue and fence buffers
    + a 512 MiB process bound; room = idle MemAvailable 13,748 - the wrapper's floor 1,536 = 12,212 MiB.
    The output buffer is filled by a host copy (get_tensor), not mapped by an NPU op: DRAM only.
  - Settings in every row: -c 16384, -np 1, -fa on, -b 2048 (all-logits rows: -b 512), F16 KV.
  - Fixed since 6403ce1: exact bytes instead of rounded table figures (session 0's weights are 2,110.47 MiB, not
    2,110); the CPU bound in bytes; the output buffer from the workload's outputs; the previous session's compute
    buffer mapped into each session; the NPU-R' variant keeps the output norm on the NPU.

Results (MiB; budget.txt = split-record clone rule, budget-clone-all.txt = every-other-session bound)
                                         fullest session margin            board margin
  configuration                     split record     every-other bound   server -np 1   all-logits -b 512
  NPU-R,  3 sessions 15,13,13 ub512      -438.5            -933.0          +1,241.8          +992.3
  NPU-R', 3 sessions 14,13,14 ub512       -87.8            -215.8          +1,714.0        +1,464.5
  NPU-R,  4 sessions 11,10,10,10 ub512   +364.1            -131.3          +1,090.9          +841.4
  NPU-R,  4 sessions ub1024              -130.4          -1,245.3             -23.0          -272.5
  NPU-R', 4 sessions 11,10,10,10 ub512   +595.6            +410.9          +1,646.8        +1,397.3
  NPU-R', 4 sessions ub1024              +208.6            -160.9          +1,075.0          +825.5
  ubatch 2048: over in every variant (first pass: the output session alone needs ~1.4 GiB of compute).
  Leading candidate: NPU-R', 4 sessions, --tensor-split 11,10,10,10, ubatch 512: within under both clone rules.
  NPU-R at 4 sessions/512 is within under the split record and over under the every-other bound: second choice.
  All-logits workloads (T3a, T7-style comparisons on the NPU) at -b 2048 would add ~750 MiB of output buffer to
  the board: they are budgeted at -b 512.

Op support on the NPU (third pass; closes the review's P1 remainder)
  tools/r1_hex_support.cpp compiles master's ggml-hexagon.cpp unchanged against stub SDK headers (tools/r1-hex-stub/:
  declarations only; every SDK function aborts if called) and calls its own ggml_backend_hexagon_device_supports_op
  (:9381) for every node the dry run placed on a session, each rebuilt from the scheduler's record of it (type,
  shape, strides, flags, op params, sources by slot; support/<config>.nodes.txt.gz, six graphs per configuration:
  prompt and single-token reservations). The stand-in session carries the board's own hwinfo: threads 4, hvx 4,
  hmx 1, vtcm 8 MB (two committed campaign logs; the MB figure is floored, so 8 MiB is a lower bound).
  Result (support/<config>.support.txt, every distinct signature with its verdict and count):
    NPU-R', 4 sessions, ub512: 7,752 NPU nodes, 89 signatures, 0 unsupported.
    NPU-R,  4 sessions, ub512: 7,758 NPU nodes, 91 signatures, 0 unsupported.
  Controls (support/controls.txt): the same nodes are refused when VTCM is too small (64 KiB: 2,746; 1 MiB: 72, the
  dense FFN's Q3_K MUL_MAT and SSM_CONV); the smallest passing VTCM is 1,984 KiB (1,920 KiB: 4 refused), about a
  quarter of the board's 8 MiB. With HMX off (GGML_HEXAGON_NHMX=0) 228 MUL_MAT_ID nodes are refused, so the
  candidate keeps HMX on (the default; the configuration pins it).
  Consequence: no op of this graph falls back to the CPU on the NPU sessions, so there is no mixed CPU/NPU partition;
  the split record (CPU embeddings, then sessions 0 -> 1 -> 2 -> 3) and the ledger above describe the Hexagon run.
  Fail-closed input (fourth pass, review of cbe3b51): the dump is framed per graph (GRAPH_BEGIN n_nodes / GRAPH_END
  logged) and checked against a manifest written at capture time (support/<config>.manifest: graph count and each
  graph's node and record counts). The checker exits 3 on a missing or unreadable dump or manifest, an unknown or
  malformed record (every field present exactly once, a repeat rejected before it is read, and numeric), a NODE without its T record, sources out of slot order, an
  unclosed or truncated graph, a GRAPH_END count that differs from the records, any difference from the manifest, or
  no node on an NPU session; 1 if any op is refused; 0 only if all are supported. tools/test_r1_hex_support.sh: 17 of
  17 on both dumps (complete dump 0; VTCM 1 MiB control 1; missing dump, missing manifest, empty, truncated at half and
  at the last line, last graph removed, a one-node dump, a non-numeric field, an unknown record, a NODE without its T,
  a wrong GRAPH_END count, a repeated name field, a repeated numeric field (review of dd5e9d8), another
  dump's manifest: 3; a one-node dump's own manifest differs
  from the capture's). A dump and a manifest replaced together stay self-consistent: the committed manifest and the
  dump's sha256 (provenance.txt) pin the capture. The framed recapture gives the same signatures and verdicts as the
  reviewed capture (support/first-capture/).
  Limits of the check: the rebuilt tensors carry no buffers or Hexagon extras (they matter to GET_ROWS on repacked
  weights, which no NPU node here does, and to repack bookkeeping, not to the verdict); n_threads is the recorded 4.
  R2's validation still compares each session's mapped peak (own buffers plus clones) and the op placement in its
  load log with this record.

Proposed plan amendments (for review; the thresholds and matched arms stay as frozen)
  - T4 speed: ubatch 512 only (1024 is over for NPU-R and over under the every-other bound for NPU-R'; 2048 over).
  - T3a backend parity (section 5 asks for ubatch 512 and 2048): 2048 cannot run on 4 sessions in any variant
    budgeted here. Proposed: T3a at ubatch 512, with the 2048 case replaced by a reviewed alternative before any NPU
    result, e.g. 1024 on NPU-R' (within under the split record only) or dropped with this budget as the reason.
    The multi-token departure the plan watches for (F9) already appears at 512 tokens per ubatch.
