R1 pre-load memory ledger for M2 (NPU dev plan section 6, R1), 2026-10-16; second pass after Codex's review of
6403ce1 (PR #65). Offline: no NPU, nothing staged; the model's weights were never read.

Status: an estimate built on master's own loader, scheduler and allocator, NOT yet a demonstrated conservative
admission. One gap remains open (below: whether the NPU refuses any op for a VTCM or kernel-parameter reason).
Four sessions are the leading candidate; three sessions are out under this surrogate and the tested splits. Nothing
here is decided until the review and the owner accept it.

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

Open (the review's P1 remainder): op support beyond types and layouts
  Every op of the graph (20 kinds, 32 type signatures in the split record) is in the NPU's supports_op list
  (:9381 on) and meets its type and layout conditions. Several also require a kernel plan that fits the session's
  VTCM (MUL_MAT / MUL_MAT_ID, binary ops, ROPE, GET_ROWS, ARGSORT, SSM_CONV, CPY, CONCAT, FLASH_ATTN_EXT); those
  plans depend on the session's VTCM size, which our NPU logs do not record. An op refused there would run on the
  CPU and add HTP<->CPU copies; the session-0 CPU bound covers the CPU buffer, but a mixed partition's copy buffers
  are not proven bounded. Ways to close it, for the owner and the review to choose:
    a. Offline: evaluate the kernel-plan functions on the host with the v75 VTCM size (the backend's fallback is
       8 MiB when the query fails, :4925; the real size needs a source), for this graph's exact shapes.
    b. A separately reviewed, minimal NPU check: open the sessions without loading the model and ask
       ggml_backend_dev_supports_op for this graph's ops and shapes (no weights, no compute). NPU work: the owner's
       approval.
  R2's validation must then also compare each session's mapped peak (own buffers plus clones), not only the logged
  owner buffers.

Proposed plan amendments (for review; the thresholds and matched arms stay as frozen)
  - T4 speed: ubatch 512 only (1024 is over for NPU-R and over under the every-other bound for NPU-R'; 2048 over).
  - T3a backend parity (section 5 asks for ubatch 512 and 2048): 2048 cannot run on 4 sessions in any variant
    budgeted here. Proposed: T3a at ubatch 512, with the 2048 case replaced by a reviewed alternative before any NPU
    result, e.g. 1024 on NPU-R' (within under the split record only) or dropped with this budget as the reason.
    The multi-token departure the plan watches for (F9) already appears at 512 tokens per ubatch.
