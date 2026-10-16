R2 pre-stage manifest, PROPOSED for review (NPU dev plan K5 and section 6, R2), drafted 2026-10-16. R2 is an NPU stage:
nothing here runs before the review, T7's PASS, the R1 admission's acceptance, the disk precondition below, and the
owner's explicit approval of staging and of the run. Values marked PROPOSED are for the review to accept or change.

0. Preconditions (each a stop if unmet)
  - R1 admission accepted (r1-budget/, #65/#66): NPU-R', four sessions, --tensor-split 11,10,10,10, ubatch 512.
  - T7 PASS on the laptop (k5-t7/, #67), recorded before R2.
  - Disk (plan K6): free space >= model + 2 GB logs + the campaign's 10 GB reserve = about 21 GB for M2 (8.8 GB).
    On 2026-10-17 (removal at 00:03:46, from the restore note) the owner allowed removing what can be downloaded again: two campaign model files with
    recorded sources and sha256 were removed (~/v0/models/REMOVED-20261017.txt has the restore commands), and the board
    went from 12 to 17 GB free. About 4 GB more is needed; what is left is not re-downloadable (geniex/ is hard links to
    the campaign's own q40/ files and frees nothing; ~/v0-backups holds evidence backups): the owner's decision.
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
       --declared-peak-mib 2594.0,2501.5,2491.7,2236.7 --declared-board-mib 10565.2 \
       --hash $M --hash $P/bin/llama-server --hash $P/lib/libllama-server-impl.so --hash $P/lib/libggml-htp-v75.so \
       --env GGML_HEXAGON_NHMX=1 \
       --env LD_LIBRARY_PATH=$P/lib --env ADSP_LIBRARY_PATH=$P/lib --env GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2,HTP0:3 \
       --env GGML_HEXAGON_VERBOSE=1 --env GGML_SCHED_DEBUG=2 -- \
       r2_load_probe.sh $O/probe 18090 900 -- $P/bin/llama-server -m $M -c 16384 -np 1 -fa on -b 2048 -ub 512 -ngl 999 \
         --device HTP0:0,HTP0:1,HTP0:2,HTP0:3 -ts 11,10,10,10 -ot 'token_embd\.weight=CPU' --cache-ram 0 -lv 5 --no-webui
   (O is the wrapper's evidence directory, ~/bench-runs/npu-dev/r2/load1-npu-r-prime, which the wrapper creates and
   requires to be new; the probe then creates its own new subdirectory $O/probe. The wrapper's own checks cover the DSP
   journal, kernel audit, memory floor, stall and timeout. The wrapper passes no inherited variable, so every backend
   option is explicit: HMX on (GGML_HEXAGON_NHMX=1, as R1's support check requires), the devices, verbosity and
   scheduler debug. -lv 5 because at af0579c78 debug is level 5 (-lv 4 is "trace" and drops the loader assignment, the
   scheduler's split record and the mapping lines; found on a production-logger dry run). The allocation guard refuses
   to launch unless the ledger's declared session peaks (split-record rule) are within the session limit and the
   declared board figure, r1-budget/budget.txt's s4-rp-ub512 server row, is within MemAvailable minus the floor.)

3. Checks after load 1 (the stage stops at the first failure; a fault is never repeated; recovery is the owner's)
  a. The wrapper's verdict PASS (command exit 0; DSP journal with the library opened and CDSP0 lines and no dspqueue
     error or fatal line; kernel audit pass; floor and stall never hit).
  b. Mapped peak per session (the parser's line format is taken from master's source, ggml-hexagon.cpp :745/:763; no
     campaign log has verbose mapping lines to check it against, so it fails closed on any session without lines):
     tools/r2_mapped_peak.py $O/probe/server.log 2594.0,2501.5,2491.7,2236.7 --sessions
     HTP0:0,HTP0:1,HTP0:2,HTP0:3 must say WITHIN: each session's own buffers plus clones at or below the ledger's
     figure for s4-rp-ub512 (r1-budget/budget.txt, split-record rule, which already includes the CPU compute bound in
     session 0), and its total including the op queue below 3,200 MiB. Also reported: the peaks against the
     every-other-session figures (2778.7, 2625.9, 2656.7, 2398.1). PROPOSED: a peak above the split-record figure stops R2.
  c. Logged buffers (-lv 5) per session: model, KV, recurrent state and compute buffer sizes, each at or below the ledger's
     component (exact weights from the K3 table; context and compute from ledger/s4-rp-ub512.out, which used CPU
     alignment: + 1 MiB per session allowed for HTP's 128-byte alignment), and the CPU's compute buffer at or below the
     whole-graph CPU bound: tools/r2_logged_buffers.py <npu-dev> $O/probe/server.log s4-rp-ub512 must say WITHIN. A
     larger one stops R2: the ledger's model of the run is then wrong. (Checked against the real A32-5 NPU log's line
     formats: there the CPU compute buffer is named "CPU", not "<session>-HOST", so the checker counts every
     non-session compute line as the CPU's; R1's ledger counted it in session 0's mappings, which stays conservative.)
  d. Placement (plan K7): tools/r2_placement.py $O/probe/server.log --tensors ../r1-host/k3/table-M2.tsv --split
     11,10,10,10 --variant "NPU-R'" must say
     PLACED: the loader puts layers 0-10 on HTP0:0, 11-20 on HTP0:1, 21-30 on HTP0:2, 31-39 and the output layer on
     HTP0:3; every reserved graph's splits are CPU (embeddings), the four sessions in order, then CPU (the output
     projection); and in every graph each of the model's 258 block matmul weights (from the K3 table: attention q/k/v/
     output, short-convolution in/out projections, dense and expert FFN weights, the routers) is the weight source of a
     MUL_MAT / MUL_MAT_ID under its block's session split, with result_output taking token_embd.weight in the final CPU
     split. Weight identity, not node names: the convolution matmuls are found by their weights too, and a log without
     matmul records cannot pass (review of fdb7292). The production logger's prefixes, which also fall inside the
     scheduler's multi-call node lines, are removed first; the scheduler's node lines cut the backend name to 5
     characters, so a node's device is read from the split it is printed under. Checked against two dry runs of this
     configuration (fixtures/s4-rp-ub512-production.log.gz through master's own logger from a clean tree, and
     fixtures/s4-rp-ub512-rawcallback.log.gz): PLACED. A difference makes the run invalid.
  e. The generation: 1..32 tokens, finite timings (r2_load_probe.sh); its text is recorded, no quality claim (T7 is the
     quality gate).
  f. Memory: the minimum MemAvailable in memory.tsv reported against the board budget (r1-budget/budget.txt: board
     margin +1,646.8 MiB for a server).

4. Load 2: PROPOSED none. NPU-R (output projection on the NPU) is within the ledger only under the split-record clone
   rule (+364.1 MiB) and over under the every-other-session bound (-131.3 MiB); the plan's second load would need its
   own acceptance after load 1's measured peaks.

5. Evidence: ~/bench-runs/npu-dev/r2/load1-npu-r-prime/ (the wrapper's files, probe/server.log, generation.json), then
   a written result in this folder: the checks' outputs, the staging hashes, the identity records before and after.

Tools in this proposal (tested offline, no NPU): tools/npu_dev_run.sh (test_npu_dev_run.sh 40/40), tools/r2_load_probe.sh
(test_r2_load_probe.sh 9/9), tools/r2_mapped_peak.py (test_r2_mapped_peak.sh 10/10), tools/r2_logged_buffers.py
(test_r2_logged_buffers.sh 17/17), tools/r2_placement.py (test_r2_placement.sh 14/14). End to end on the real system
(all defaults, the real journal, sampler, watchdog and kernel audit; a CPU-only master server as the payload, no NPU):
PASS, e2e-cpu-selftest.txt.
