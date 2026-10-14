R1, part 1 (offline): the tensor/allocation table tool (plan K3) and header-only previews of LFM2.5-24B-A2B files.
2026-10-15, on the owner's approval ("Start NPU plan R1 offline"; "Do both is you have time"). No NPU, no model
download, nothing staged on the board: every model below was sized from its GGUF header, read through HTTP range
requests. Not a fit decision: R1 decides on M2 itself (made on the x86 host from Liquid's BF16, K3), and compute and
recurrent buffers are measured at load (R2).

Tool: ../tools/gguf_tensor_table.py (rule, placement and sources in its docstring, with file:line at master
af0579c78 and release 836d57176). Per tensor: name, shape, type, file bytes, NPU allocation, role, offset (.tsv); per
type, per layer and per NPU session (weights + KV at a given context, against one session's 3,200 MiB address space,
HTP_OP_MAX_VMEM_DEFAULT, F5). Fails closed if any tensor's computed size does not fit its offset gap (unknown type
size) or a type id is unknown. Tests: ../tools/test_gguf_tensor_table.py 15/15 (synthetic GGUF files with
hand-computed allocations: Q3_K/Q4_K/Q6_K tiles, Q2_K at file size on master and tiled at 512 on the release, ne1
padding, non-repack types, 3-D expert tensors, 128-byte padding; tied output and --output-cpu; lfm2moe's
token_embd_norm and a block id >= block_count with the output; KV for head_count_kv arrays and qwen35's recurrent
mask; session splits with and without block 0 on the CPU; offset-gap and unknown-type failures; the same table through
a local range server).

Validation against a real load (validation-neohorse.txt): the campaign's NeoHorse Q4_0 file (Q4_0: both rules agree)
with -ngl 32 on 2 sessions, against A32-3 S1's server log. Computed HTP0:0 959.1338 MiB and HTP0:1 1239.4573 MiB
(logged 959.13 and 1239.46); CPU 341.16 (token_embd 341.02 + block 0's F32 0.14) and CPU_REPACK 60.56 (block 0's
Q4_0), logged 341.16 and 60.56; KV 8 attention layers, 512 + 512 MiB at 32,768 (logged 512.00 + 512.00). The layer
split (blocks 1-16 / 17-31 + output) and the allocation rule reproduce the loader per session.

Previews (each .txt holds the master and the release rule, each .tsv the per-tensor table; source, Hub revision,
sha256 and size at the top). LFM2.5-24B-A2B: lfm2moe, 40 blocks, 10 attention layers (2, 6, ..., 38), tied output
(token_embd.weight is Q6_K in these four files, 219 MiB tiled; F12's Q8_0 was another file's), KV 320 MiB at 16K.
NPU allocation, all layers on the NPU (NPU-R), weights + KV at ctx 16,384, per session:
  file (Hub)                              types (count)                      file MiB  master MiB  4 sessions       3 sessions
  NANI-Nithin Q2_K (default-mix shape)    Q2_K 160, Q3_K 60, Q6_K 1          8,394     8,927       2,206-2,370      2,890 / 3,313 / 3,045
  bartowski Q2_K (another mix)            Q2_K 94, Q4_K 13, Q8_0 50, ...     8,745     9,031       2,085-2,809      3,417 / 2,952 / 2,982
  NANI-Nithin Q3_K_S                      Q3_K 220, Q6_K 1                   9,939     11,542      2,841-3,052      3,730-4,267
  LiquidAI QAD-Q4_0 (official)            Q4_0 220, Q6_K 1                   12,941    12,955      3,183-3,421      4,184-4,784
  (session limit 3,200 MiB each, before compute buffers and recurrent state)
On the release rule the Q2_K files grow to 11,542 (NANI) and 12,133 MiB (bartowski) because the release tiles Q2_K at
1.52x the file size; master stores it at file size. This is the K1 reason, now in numbers.
Readings, for the R1 decision on M2 (not made here):
  - A default-mix Q2_K needs 4 sessions: with 3, one session's weights and KV alone exceed 3,200 MiB. With 4, each
    session holds 2.2-2.4 GB of weights and KV, leaving about 0.8-1.0 GB each for compute buffers and recurrent state.
  - Whole-board memory: about 8.9 GB mapped for the NPU plus 205 MiB of CPU weights, plus compute, recurrent state and
    the server, against about 13 GB available and the campaign's 1.5 GiB floor (F7): about 2.4 GB left for everything
    not in the table. Plausible, unproven; R2 measures it.
  - Q3_K_S and Q4_0 do not fit as resident files (Q3_K tiles +16 %; 4 sessions at 89-107 % before compute), consistent
    with F6. Q3_K experts need Track O.
  - The Q3_K tensors in the default Q2_K mix (60 of 220 large tensors) cost 520 MiB of tile overhead; a mix whose
    larger tensors are Q4_0/Q8_0 (file size on the NPU) would place differently. Mixes are a model-quality question
    (T7) before they are a fit question.
Still to do in R1 (plan section 6, on the x86 host: the owner's machine): build the unpatched master package (K2);
make M2 and REF from Liquid's BF16 (K3); run this tool on M2 itself (its table goes into K5); T7 for M2. Then the
session-count decision with the measured compute buffers from R2's load probe.
