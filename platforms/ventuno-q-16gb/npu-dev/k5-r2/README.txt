R2 pre-stage manifest, PROPOSED for review (NPU dev plan K5 and section 6, R2), drafted 2026-10-16. R2 is an NPU stage:
nothing here runs before the review, T7's PASS, the R1 admission's acceptance, the disk precondition below, and the
owner's explicit approval of staging and of the run. Values marked PROPOSED are for the review to accept or change.

0. Preconditions (each a stop if unmet)
  - R1 admission accepted (r1-budget/, #65/#66): NPU-R', four sessions, --tensor-split 11,10,10,10, ubatch 512.
  - T7 PASS on the laptop (k5-t7/, #67), recorded before R2.
  - Disk (plan K6): free space >= model + 2 GB logs + the campaign's 10 GB reserve = about 21 GB for M2 (8.8 GB).
    The board had 12 GB free on 2026-10-16 23:1x: R2 cannot be staged until the owner frees about 9 GB (the largest
    items are campaign files: ~/v0/models/geniex 7.1 GB, ~/v0/models/drafts 2.5 GB, ~/v0/models/neohorse-q4km 2.6 GB;
    the owner's decision; this plan touches none of them).
  - No campaign process (npu_dev_run.sh's exclusivity check); the campaign's sampler and stall watchdog running.
  - Identity records before the window: the campaign's package (pkg_identity.py check), the patched DSP library and
    .farf, the measured checkout (7badb21), the dpkg baseline. After the window the same, then the campaign's launch
    checks before any campaign session.

1. Staging (the owner's approval; plan K2, K6)
  - The K2 package tarball (pkg-unpatched-af0579c7-20261016-102302.tar.gz, sha256 d0ca1bb5...) copied from the laptop
    to ~/npu-dev/, its sha256 checked, extracted to ~/npu-dev/pkg-unpatched-af0579c7/, every file checked against
    ../r1-host/k2/pkg-unpatched-af0579c7.sha256 (132 files). Never under ~/v0.
  - M2 copied from the laptop to ~/npu-dev/models/, size 8,809,757,984 and sha256 43b42f90... checked.
  - Both removed after R2 unless the owner keeps them.

2. Load 1: NPU-R' (the admitted configuration). PROPOSED commands, P=~/npu-dev/pkg-unpatched-af0579c7,
   M=~/npu-dev/models/LFM2.5-24B-A2B-M2-Q2_K-af0579c7.gguf, O=<the wrapper's evidence directory>:
     npu_dev_run.sh --stage r2 --run load1-npu-r-prime --timeout 1800 --expect-dsp yes --floor-mib 1536 --stall-s 120 \
       --hash $M --hash $P/bin/llama-server --hash $P/lib/libllama-server-impl.so --hash $P/lib/libggml-htp-v75.so \
       --env LD_LIBRARY_PATH=$P/lib --env ADSP_LIBRARY_PATH=$P/lib --env GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2,HTP0:3 \
       --env GGML_HEXAGON_VERBOSE=1 --env GGML_SCHED_DEBUG=2 -- \
       r2_load_probe.sh $O/probe 18090 900 -- $P/bin/llama-server -m $M -c 16384 -np 1 -fa on -b 2048 -ub 512 -ngl 999 \
         --device HTP0:0,HTP0:1,HTP0:2,HTP0:3 -ts 11,10,10,10 -ot 'token_embd\.weight=CPU' --cache-ram 0 -lv 4 --no-webui
   (O is the wrapper's evidence directory, ~/bench-runs/npu-dev/r2/load1-npu-r-prime, which the wrapper creates and
   requires to be new; the probe then creates its own new subdirectory $O/probe. The wrapper's own checks cover the DSP
   journal, kernel audit, memory floor, stall and timeout. HMX stays on: GGML_HEXAGON_NHMX is
   not set, as R1's support check requires. -lv 4 because master logs the mapping lines at debug level.)

3. Checks after load 1 (the stage stops at the first failure; a fault is never repeated; recovery is the owner's)
  a. The wrapper's verdict PASS (command exit 0; DSP journal with the library opened and CDSP0 lines and no dspqueue
     error or fatal line; kernel audit pass; floor and stall never hit).
  b. Mapped peak per session: tools/r2_mapped_peak.py $O/probe/server.log 2594.0,2501.5,2491.7,2236.7 --sessions
     HTP0:0,HTP0:1,HTP0:2,HTP0:3 must say WITHIN: each session's own buffers plus clones at or below the ledger's
     figure for s4-rp-ub512 (r1-budget/budget.txt, split-record rule, which already includes the CPU compute bound in
     session 0), and its total including the op queue below 3,200 MiB. Also reported: the peaks against the
     every-other-session figures (2778.7, 2625.9, 2656.7, 2398.1). PROPOSED: a peak above the split-record figure stops R2.
  c. Logged buffers (-lv 4) per session: model, KV, recurrent state and compute buffer sizes, each at or below the ledger's
     component (exact weights from the K3 table; context and compute from ledger/s4-rp-ub512.out, which used CPU
     alignment: + 1 MiB per session allowed for HTP's 128-byte alignment). A larger one stops R2: the ledger's model of
     the run is then wrong. (Parser to be written after this manifest's review.)
  d. Placement (plan K7): the loader's per-layer assignment (layers 0-10 HTP0:0, 11-20 HTP0:1, 21-30 HTP0:2, 31-39 and
     the output norm HTP0:3), token_embd.weight on the CPU in both roles (input and the tied output projection), and the
     scheduler's split record (CPU embeddings, sessions 0 -> 1 -> 2 -> 3, the output projection on the CPU) equal to
     r1-budget/ledger/s4-rp-ub512.splits; every MUL_MAT / MUL_MAT_ID of blocks 0-39 on its session. A difference makes
     the run invalid for R2's purpose. (Checker to be written after review, reusing the support harness's node records.)
  e. The generation: 1..32 tokens, finite timings (r2_load_probe.sh); its text is recorded, no quality claim (T7 is the
     quality gate).
  f. Memory: the minimum MemAvailable in memory.tsv reported against the board budget (r1-budget/budget.txt: board
     margin +1,646.8 MiB for a server).

4. Load 2: PROPOSED none. NPU-R (output projection on the NPU) is within the ledger only under the split-record clone
   rule (+364.1 MiB) and over under the every-other-session bound (-131.3 MiB); the plan's second load would need its
   own acceptance after load 1's measured peaks.

5. Evidence: ~/bench-runs/npu-dev/r2/load1-npu-r-prime/ (the wrapper's files, probe/server.log, generation.json), then
   a written result in this folder: the checks' outputs, the staging hashes, the identity records before and after.

Tools in this proposal (tested offline, no NPU): tools/npu_dev_run.sh (test_npu_dev_run.sh 24/24), tools/r2_load_probe.sh
(test_r2_load_probe.sh 7/7), tools/r2_mapped_peak.py (test_r2_mapped_peak.sh 10/10).
