B1 (NPU dev, new candidate after Track R): Ternary-Bonsai-2-9B Q2_0 on the VENTUNO Q NPU. PROPOSED for review and
the owner's approval, written 2026-10-19. Nothing on the NPU runs before both. Builds on R2's lessons (k5-r2/result/).

Why this model (the owner, 2026-10-19: "Ok to look for smaller that fit maybe star here
https://prismml.com/news/bonsai-2-family and ok to see what new in the new version")
  - Natively ternary weights ({-1, 0, +1}, FP16 group scales), so low bits are the model's own format, not a
    post-training cut like LFM2.5's Q2_K (M2: 63.6 % top-1 vs Q8_0). Dense, Qwen3.5-9B hybrid attention (24 linear-
    attention, 8 full-attention layers), the architecture (qwen35) the campaign already runs. Apache-2.0.
  - Publisher's claims (not checked here): 92.4 % overall retention of Qwen3.5-9B, BFCLv3 71.81 (base 73.81).
  - Upstream llama.cpp runs only the Q2_0 packing (the card: "Upstream llama.cpp runs only Q2_0 ... it rejects PQ2_0
    and PTQ1_0"). ggml-hexagon gained Q2_0 MUL_MAT (797de63b2, 2026-10-17) and its Hadamard MUL_MAT/GET_ROWS
    (848bbda90, 2026-10-18; its PR: "Bonsai-2 Q1 and Q2 are fully usable now"). Neither is in af0579c78 (R1's pin).

The file (on the board since 2026-10-19 00:59:54 +02:00, its mtime; in ~/npu-dev/b1/models/)
  prism-ml/Ternary-Bonsai-2-9B-gguf Ternary-Bonsai-2-9B-Q2_0.gguf, 2,556,640,128 bytes, sha256
  1f884aa56aacd2bbbb2e4b7abaead2b1102b74a9c75a23fc33dab916813a384d (the repository's SHA256SUMS; checked).

Size on the NPU (table-bonsai2-9b-q2_0.txt, tools/gguf_tensor_table.py, header only)
  202 Q2_0 tensors (8,946.5 M params) and 225 F32. NPU allocation of everything placeable 2,154.86 MiB; the input
  embedding (272.8 MiB) stays on the CPU. The tool's repack rules are af0579c78's, where Q2_0 is not tiled (allocation =
  file bytes); at ff5a2337 Q2_0 is tiled at HTP_TENSOR_TILE_SIZE_Q2_0 576 bytes per 32 rows x 64 = 2.25 bits per
  weight, the file's own rate (block 64 elements, 18 bytes), so the figures are expected to hold; the load's logged
  model buffers are the check.
  KV at context 16384: 512 MiB F16 over the 8 attention layers (the tool's estimate; the load below keeps the server's
  default F16 cache, as R2 did). Two sessions, --tensor-split 18,15: HTP0:0 weights 1,060 + KV 256 = 1,316 MiB,
  HTP0:1 1,095 + 256 = 1,351 MiB, before recurrent state and compute buffers.
  R2's suspected limit (a map refused at 2,144.55 MiB in one session, not isolated): two sessions keep each below about
  1.6 GiB even with a compute allowance, so this load also tests the region below that suspicion without probing it.

Stages (each ends with a written result in this folder)
  B1a (laptop, offline) Package: tools/r1_build_master_x86.sh with BUILD_COMMIT=ff5a23376725e5a889fa0bfb987b7541dc304da0
      BUILD_COMMIT_DATE=2026-10-18T17:48:47Z, from a reviewed commit (#75 adds the option). Output
      pkg-unpatched-ff5a2337-<stamp>.tar.gz and its manifest, sent to the board.
  B1b (board, CPU only, done 2026-10-19 as an exploratory check; result to be added here): upstream ff5a2337 CPU build
      on the board, the file's smoke generation, the frozen T5 screen (k5-t7/t5-requests.json) with the template's
      default and with thinking disabled, llama-bench pp512/tg128. The CPU arm for B1c's comparison.
  B1c (NPU, owner's approval) Load: staged as R2 with its fixes (package checked against its manifest, the
      lib/libcdsprpc.so symlink after its ext check, P the install directory), under npu_dev_run.sh:
        --stage b1 --run load1-s2 --timeout 1800 --expect-dsp yes --floor-mib 1536 --stall-s 120
        --declared-peak-mib 1600,1600 --declared-board-mib 4200 (estimates: weights + KV above + 250 MiB compute and
        state allowance per session; there is no dry-run ledger for this model, so the guard checks estimates)
        --hash <model> --hash $P/bin/llama-server --hash $P/lib/libllama-server-impl.so --hash $P/lib/libggml-htp-v75.so
        --env GGML_HEXAGON_NHMX=1 --env LD_LIBRARY_PATH=$P/lib --env ADSP_LIBRARY_PATH=$P/lib
        --env GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 --env GGML_HEXAGON_VERBOSE=1 --env GGML_SCHED_DEBUG=2 --
        /bin/bash tools/r2_load_probe.sh $O/probe 18090 900 -- $P/bin/llama-server -m <model> -c 16384 -np 1 -fa on
          -b 2048 -ub 512 -ngl 999 --device HTP0:0,HTP0:1 -ts 18,15 -ot 'token_embd\.weight=CPU' --cache-ram 0 -lv 5
          --no-webui
      Checks: the wrapper's PASS (DSP journal, kernel audit, floor, stall, orphans); the probe's generation (1..32 tokens,
      finite timings) and its text compared with the CPU arm's greedy output for the same prompt (recorded, not a
      parity claim: T3a-style parity is a later stage); logged buffers per session against the estimates above
      (r2_logged_buffers.py needs a ledger and is not used; the figures are recorded); the mapped peak per session
      (r2_mapped_peak.py with the declared peaks). Stop at the first fault; a fault is never repeated.
  B1d (NPU, owner's approval, only after B1c PASS) The T5 screen on the NPU arm (fresh, the same 20 requests) against
      B1b's CPU arm, and llama-bench on the NPU; then the owner decides on campaign arenas.

Not claimed: that Bonsai fits a campaign arena budget, that its NPU output is correct, or the publisher's quality
figures. Disk: the file is 2.56 GB; the package about 50 MB; M2 (8.8 GB) stays staged until the owner decides on it.
