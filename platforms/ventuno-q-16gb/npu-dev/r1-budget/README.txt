R1 conservative pre-load budget for M2 (NPU dev plan section 6, R1; review of a7b6223 on PR #64), 2026-10-16.
Offline: no NPU, nothing staged; the model's weights were never read. Proposed for review; the session-count decision
and the pinned candidate configuration below are proposals until the review and the owner accept them.

Method
  Per session, against what one session can map. ggml-hexagon.cpp at af0579c78 maps each buffer into the session
  that owns it (lazy fastrpc_mmap, :729-749), and op batches must fit max_vmem = HTP_OP_MAX_VMEM_DEFAULT
  (3,355,443,200 B, htp-ops.h :138) minus the op queue's pinned shared buffer (:4988-4989; 10.4 MiB with the default
  1,280 ops x depth 8, :4120-4137): limit 3,189.6 MiB. Counted in each session:
    - weights: the K3 tables (master's NPU allocation rule, tiled sizes; r1-host/k3/table-M2*.txt);
    - context (KV + recurrent state) and compute: a dry run of master af0579c78 itself (llama-fit-params --fit-print
      on: no_alloc, every allocation simulated from the model's metadata), with local RPC devices standing in for the
      NPU sessions, so the loader's layer placement and the scheduler's per-device graph splits and copies are
      master's own; +1 MiB on each figure for the dry run's flooring;
    - session 0 also: the CPU compute buffer. llama-context.cpp :496-504 allocates it from the first device's host
      buffer type, which that session supports (ggml-hexagon.cpp :9591-9597), so its tensors can be mapped into
      session 0. Bounded by the whole graph on the CPU (cpu-bound.txt), which also covers any op the NPU refuses;
    - the output session also: the output buffer (1 MiB bound at -np 1).
  Whole board (CPU and NPU share DRAM, F7): every NPU allocation + context + NPU compute + CPU weights + the CPU
  compute bound + the op queue buffers + a 512 MiB process bound, against idle MemAvailable 13,748 MiB (this
  evening's reading, no server) minus the wrapper's live floor 1,536 MiB (section 7): room 12,212 MiB.
  Fixed for every row: -c 16384 (the plan's context), -fa on (pinned: the NPU's flash attention is chunked to VTCM,
  :5174-5340, so it does not grow with context; without it the attention scratch at 16K would be ~1 GiB per layer),
  -b 2048, F16 KV, -ngl all (NPU-R) or the output projection on the CPU (NPU-R', -ot 'token_embd\.weight=CPU'),
  splits as K3's best explicit split.
  Inputs and reproduction: matrix.txt, npu-r-prime.txt, cpu-bound.txt (dry-run outputs), provenance.txt (commit,
  build, binary hashes, the header-only model), ../tools/r1_budget.py (the arithmetic; budget.txt is its output:
  python3 -I tools/r1_budget.py <npu-dev dir>).

Results (MiB; fullest session's margin against 3,189.6; board margin against 12,212)
  NPU-R,  3 sessions (15,13,13): no row fits; at ubatch 512 the fullest session is 439 over (3,629), even before
          anything is added for the rows below.
  NPU-R', 3 sessions (14,13,14): ubatch 512: 89 over (3,279); 1024: 476 over.
  NPU-R,  4 sessions (11,10,10,10; = the default split):
          ubatch  512, -np 1: sessions 2,687 / 2,482 / 2,512 / 2,688; fullest margin +502; board 11,128 (+1,084). ADMIT
          ubatch 1024, -np 1: fullest +24, board -29. NO
          ubatch 2048: over by 934 and more. NO
          (-np 4 gives slightly smaller compute buffers in the dry run; the candidate pins -np 1.)
  NPU-R', 4 sessions (11,10,10,10):
          ubatch  512: sessions 2,595 / 2,402 / 2,432 / 2,179; fullest +595; board 10,572 (+1,640). ADMIT
          ubatch 1024: fullest +208 (session 0, the CPU compute bound); board +1,069. ADMIT, thin
  So: 3 sessions are out in every variant; 4 sessions fit at ubatch 512 with about 500 MiB per session to spare.

Proposed candidate configuration (for review; K5 pins it)
  GGML_HEXAGON_DEVICES=4, -ngl all, --tensor-split 11,10,10,10 (written explicitly although it equals the default),
  -c 16384, -np 1, -fa on, -b 2048, -ub 512, F16 KV; master af0579c78 (the K2 package). NPU-R' (output on the CPU) is
  admitted with the same settings as the second load. The plan's T4 ubatch sweep (512/1024/2048) does not fit: 2048
  is out everywhere and 1024 is out for NPU-R and thin for NPU-R'; proposed: T4 at ubatch 512 only, unless the review
  prefers 1024 on NPU-R' with its 208 MiB margin (a plan change either way).

What this does not establish (for R2 to check against, not to supply)
  - The RPC devices stand in for the NPU: same loader, scheduler and allocator, but CPU op support and alignment. The
    NPU accepts nearly every op of this graph (supports_op from :9381: MUL_MAT_ID, SSM_CONV, TOP_K, FLASH_ATTN_EXT,
    ...); an op it refused would move to the CPU, which the CPU compute bound covers in session 0. Alignment 128 vs
    the CPU's is under 1 MiB per session here.
  - Hexagon-internal memory beyond the op queue and the 64 KiB fence buffer is not modelled; the ~500 MiB per-session
    margin is the allowance for it.
  - The process bound (512 MiB) and the idle MemAvailable are one reading each; the wrapper's live floor still
    applies during every run.
  R2's load probe then checks, before generating: every session's logged model, KV/RS and compute buffer sizes at or
  below this budget's figures; a larger one stops the probe. T7 for M2 comes before R2 (plan section 6).
