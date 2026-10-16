K3 result (NPU dev plan K3, stage R1): M2 (Q2_K, llama-quantize's default mix, no imatrix) and REF (Q8_0) of
LFM2.5-24B-A2B, made by the owner on the x86_64 laptop on 2026-10-16 (20:20-20:40) with r1_models_x86.sh at the
reviewed commit ceb2688 (sha256 812fc718..., checked before the run). Result: DONE, exit 0. No NPU, nothing staged on
the board; the models stay on the laptop.

Owner's exception to the R1 run rules, recorded before use (as for K2's records):
  - This evidence tarball (text only: the files below; no model) was copied by the owner with scp to ~/r1-incoming/
    on the board for committing. sha256 a147aae4bece86dc9bc6d21d7f706460ef9e790005cd70ee8c87685d19ae26f2 on the
    laptop (checked by the owner before the copy) and on the board after it: the copy is exact. Only that file was
    transferred. Unpacked into an empty scratch directory; no symlinks; nothing executed from it.

Files: manifest.txt (the run's record), host-toolchain.txt, host-build.log.txt, quantize-{M2-Q2_K,REF-Q8_0}.log.txt,
table-BF16.txt, table-{M2,REF}.txt/.tsv (master rule), table-{M2,REF}-release.txt (release rule),
table-{M2,REF}-npu-r-prime.txt (output projection on the CPU, the board's CPU repack types), experts-{M2,REF}.txt.
Not copied: the tarball's gguf_tensor_table.py, byte-identical to tools/gguf_tensor_table.py (sha256 1201119e...,
as pinned by the script).

Identities (manifest.txt):
  - source BF16 LiquidAI/LFM2.5-24B-A2B-GGUF at revision 0912d331, 47,962,094,880 bytes, sha256 55103fda... (pinned).
  - llama.cpp af0579c78 (master, fresh clone, clean), host CPU build (Release, GGML_NATIVE=OFF), GCC 16.2.1.
  - M2: LFM2.5-24B-A2B-M2-Q2_K-af0579c7.gguf, 8,809,757,984 bytes, sha256
    43b42f90f64ed2c8ce46bf92a76adcc112dd69842d6c8c43f0fc44935bd914e7.
  - REF: LFM2.5-24B-A2B-REF-Q8_0-af0579c7.gguf, 25,493,732,640 bytes, sha256
    f09bf094a8a138c5b645598ca1abb6696a0fde26662d7af649b0713fdef330b6.

Findings (weights + KV at ctx 16,384 against one session's 3,200 MiB; necessary, not sufficient: recurrent state,
compute and scratch buffers not included):
  - Every one of the 114 expert tensors is an NPU repack type, in M2 and in REF.
  - M2 = Q2_K 160, Q3_K 60, Q6_K 1, F32 207; file 8,393.77 MiB; NPU allocation 8,927.19 MiB (master rule).
    Its tensor table (names, shapes, types, file and NPU bytes) equals the Hub preview of NANI-Nithin's Q2_K
    (../../r1-tensor-tables/NANI-Nithin-LFM2.5-24B-A2B-Q2_K.tsv) line for line, so the preview's readings hold for M2:
    master rule: 3 sessions +51.5 MiB on the fullest (best explicit split 15,13,13; the default split is over, 3,313),
      4 sessions +829.5 MiB (default and explicit 11,10,10,10 agree);
    release rule: 3 sessions -856.0 (no), 4 sessions +147.7;
    NPU-R' (output on the CPU): 3 sessions +115.3, 4 sessions +829.5.
    So on master M2 needs 4 sessions to keep a usable margin; 3 is unresolved until R2 measures the compute buffers.
  - REF (Q8_0, 24,304.85 MiB) does not fit any tried session count (3: -5,267.1; 4: -3,172.2; NPU-R' 3: -5,086.4).
    That is expected: REF is the CPU-side reference for T7 and is never staged on the NPU.
  - Reading note (2026-10-16): the owner's paste of the run's last lines showed REF's NPU-R' line, which was first
    misread here as M2's; the full manifest shows the M2 figures above.

Next (R1): M2's session count from these tables plus R2's measured buffers; T7 on the laptop after K5 pins its text,
token ids and settings. Models and the BF16 source stay on the laptop until those steps; staging M2 on the board
needs its own approval.
