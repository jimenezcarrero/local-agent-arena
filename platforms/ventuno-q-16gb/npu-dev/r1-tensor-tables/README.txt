R1, part 1 (offline): the tensor/allocation table tool (plan K3) and header-only previews of LFM2.5-24B-A2B files.
2026-10-15, on the owner's approval ("Start NPU plan R1 offline"; "Do both is you have time"). No NPU, no model
download, nothing staged on the board: every model below was sized from its GGUF header, read through HTTP range
requests. Not a fit decision: R1 decides on M2 itself (made on the x86 host from Liquid's BF16, K3), and compute and
recurrent buffers are measured at load (R2).

Tool: ../tools/gguf_tensor_table.py (rule, placement and sources in its docstring, with file:line at master
af0579c78 and release 836d57176). Per tensor: name, shape, type, file bytes, NPU allocation, role, offset (.tsv); per
type, per layer and per NPU session (weights + KV at a given context, against one session's 3,200 MiB address space,
HTP_OP_MAX_VMEM_DEFAULT, F5). Fails closed if any tensor's computed size does not fit its offset gap (unknown type
size) or a type id is unknown. After the review of ec37672: placement in float32 as the loader computes it, ties at
split points listed, the best explicit split (contiguous, lowest fullest session) with its --tensor-split values, a
fit line per session count (necessary, not sufficient), and a tied output on the CPU counted once when it reuses the
input's tensor (plain CPU buffer), twice when the CPU repack takes it (--cpu-repack), as a bound when unresolved.
Tests: ../tools/test_gguf_tensor_table.py 25/25 (synthetic GGUF files with
hand-computed allocations: Q3_K/Q4_K/Q6_K tiles, Q2_K at file size on master and tiled at 512 on the release, ne1
padding, non-repack types, 3-D expert tensors, 128-byte padding; tied output and --output-cpu; lfm2moe's
token_embd_norm and a block id >= block_count with the output; KV for head_count_kv arrays and qwen35's recurrent
mask; session splits with and without block 0 on the CPU; offset-gap and unknown-type failures; tied on the CPU:
reused, separate, bound, and on the NPU; float32 placement of a given split; ties; the best partition and explicit
split; the same table through a local range server).

Validation against a real load (validation-neohorse.txt): the campaign's NeoHorse Q4_0 file (Q4_0: both rules agree)
with -ngl 32 on 2 sessions, against A32-3 S1's server log. Computed HTP0:0 959.1338 MiB and HTP0:1 1239.4573 MiB
(logged 959.13 and 1239.46); CPU 341.16 (token_embd 341.02 + block 0's F32 0.14) and CPU_REPACK 60.56 (block 0's
Q4_0), logged 341.16 and 60.56; KV 8 attention layers, 512 + 512 MiB at 32,768 (logged 512.00 + 512.00). The layer
split (blocks 1-16 / 17-31 + output) and the allocation rule reproduce the loader per session.
Block 17 sits exactly on the split point (index 16 of 32 active = 0.5, a tie): the loader put it on HTP0:1, as the
tool does with equal free-memory reads; a higher first read would have kept it on HTP0:0. Explicit --tensor-split
values avoid the dependence.

Previews (each .txt holds the master rule in full, then the release rule and NPU-R' (--output-cpu, master, CPU repack
as expected on this board) in summary; each .tsv the per-tensor table on master; source, Hub revision, sha256 and size
at the top). Regenerated 2026-10-15 after the review of ec37672 (explicit splits, tied-copy identity). LFM2.5-24B-A2B:
lfm2moe, 40 blocks, 10 attention layers (2, 6, ..., 38), tied output, KV 320 MiB at 16K. token_embd.weight is Q6_K
(205.08 MiB in the file, 218.75 MiB on the NPU) in three files and Q8_0 (265.62 MiB) in bartowski's.
All numbers below are MiB; per session they are weights + KV only (no recurrent state, compute or scratch buffers),
against one session's address space of 3,200 MiB (HTP_OP_MAX_VMEM_DEFAULT, F5). All layers on the NPU (NPU-R), ctx
16,384, master rule:
  file (Hub)                          types (count)                    file    NPU    fullest session, default split / best explicit split
                                                                                       3 sessions               4 sessions
  NANI-Nithin Q2_K (default-mix)      Q2_K 160, Q3_K 60, Q6_K 1        8,394   8,927  3,313 / 3,148 (15,13,13)  2,370 / 2,370
  bartowski Q2_K (another mix)        Q2_K 94, Q4_K 13, Q8_0 50, ...   8,745   9,031  3,417 / 3,184 (12,15,14)  2,809 / 2,406 (9,11,11,10)
  NANI-Nithin Q3_K_S                  Q3_K 220, Q6_K 1                 9,939   11,542 4,267 / 3,942             3,052 / 3,052
  LiquidAI QAD-Q4_0 (official)        Q4_0 220, Q6_K 1                 12,941  12,955 4,784 / 4,307             3,421 / 3,421
  (NPU = every NPU allocation, the tied copy included; the explicit split's --tensor-split values in brackets where
  they differ from the default; ties: none in these four.)
On the release rule the Q2_K files grow to 11,542 (NANI) and 12,133 (bartowski): the release tiles Q2_K at 1.52x the
file size, master stores it at file size (the K1 reason, in numbers); their fullest sessions are then 3,052 and 3,172
at 4 sessions and over 3,200 at 3.
Readings, for the R1 decision on M2 (not made here). Three separate limits:
  1. Per session (weights + KV against 3,200): with the best explicit split, the Q2_K files fit on 3 sessions with
     51.5 (NANI) and 15.8 (bartowski) left on the fullest session, before recurrent state and compute buffers: too
     little to count on, and unresolved until R2 measures those buffers; on 4 sessions with 830 and 794 left. The
     default split needs 4 (3 sessions: 3,313 and 3,417). Q3_K_S fits on 4 sessions with 148 left (default and
     explicit agree), not on 3. Q4_0 does not fit on 4 (fullest 3,421, 221 over, explicit split included). Earlier
     wording ("a Q2_K needs 4 sessions"; "Q3_K_S and Q4_0 do not fit") held for the default split only, and the
     Q3_K_S part was wrong even there (89-95 % at 4 sessions): corrected here.
  2. Whole board (one idle reading on 2026-10-15, no server: MemAvailable 13,665; the campaign's floor F7 1,536;
     room 12,129), assuming every NPU allocation comes out of the same DRAM, as the plan does: NANI Q2_K needs 8,927
     + KV 320 + CPU 205 = 9,452 (2,677 left for recurrent state, compute, scratch, the server and pi); bartowski Q2_K
     9,617 (2,512 left); Q3_K_S 12,067 (62 left: no room in practice); Q4_0 13,480 (over).
  3. Omitted buffers (recurrent state, compute, scratch): not derivable from the header; R2's load probe measures
     them, and the plan's conservative pre-load admission calculation must be done before that probe is authorized.
  NPU-R' (output projection on the CPU): the tied copy leaves the NPU (-219 on the output layer's session, bartowski -266) and, with
  the CPU repack selecting Q6_K/Q8_0 as expected on this board (dotprod without i8mm), becomes a separate CPU copy
  (+205, bartowski +266): whole-board totals change by -14 and +0 respectively; without CPU repack it is the input's
  own tensor (CPU +0). To be confirmed by a load log's CPU_REPACK line.
  The Q3_K tensors in the default Q2_K mix (60 of 220 large tensors) cost 520 of tile overhead; a mix whose larger
  tensors are Q4_0/Q8_0 (file size on the NPU) would place differently. Mixes are a model-quality question (T7)
  before they are a fit question. These previews are for these exact Hub files, not for the future host-made M2.
Still to do in R1 (plan section 6, on the x86 host: the owner's machine): build the unpatched master package (K2);
make M2 and REF from Liquid's BF16 (K3); run this tool on M2 itself (its table goes into K5); T7 for M2. Then the
session-count decision with the measured compute buffers from R2's load probe.
