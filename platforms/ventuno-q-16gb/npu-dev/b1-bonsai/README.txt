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
  B1c (NPU, owner's approval) Load. Staged as R2 with its fixes: the package checked against its own manifest, the
      lib/libcdsprpc.so symlink after its ext check (k5-r2/README.txt), P the install directory
      (~/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337), M the model above, O the wrapper's evidence directory
      (~/bench-runs/npu-dev/b1/load1-s2), tools from the reviewed commit that merges this stage. Campaign identity
      before and after the window as R2 did (identity-before/after.txt: pkg_identity check, retry library, .farf,
      measured checkout, dpkg baseline), then the campaign's launch checks before any campaign session.
        npu_dev_run.sh --stage b1 --run load1-s2 --timeout 1800 --expect-dsp yes --floor-mib 1536 --stall-s 120 \
          --declared-peak-mib 1650,1650 --declared-board-mib 4200 \
          --hash $M --hash $P/bin/llama-server --hash $P/lib/libllama-server-impl.so --hash $P/lib/libggml-htp-v75.so \
          --env GGML_HEXAGON_NHMX=1 --env LD_LIBRARY_PATH=$P/lib --env ADSP_LIBRARY_PATH=$P/lib \
          --env GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 --env GGML_HEXAGON_VERBOSE=1 --env GGML_SCHED_DEBUG=2 -- \
          /bin/bash tools/r2_load_probe.sh $O/probe 18090 900 -- $P/bin/llama-server -m $M -c 16384 -np 1 -fa on \
            -b 2048 -ub 512 -ngl 999 --device HTP0:0,HTP0:1 -ts 18,15 -ot 'token_embd\.weight=CPU' --cache-ram 0 \
            -lv 5 --no-webui
      Declared figures (estimates, not a ledger: there is no dry run for this model; the wrapper only checks them
      against its fixed limits, so they guard the launch, not the run): per session the exact table weights
      (table-bonsai2-9b-q2_0.tsv: 1,060.33 / 1,094.53 MiB, HTP0:1 with the output layer) + KV 256 MiB + 250 MiB for
      recurrent state and compute (R2's sessions logged 60-101 MiB compute and 0.12 MiB state; 250 is a margin, not a
      measurement for this model) = 1,566.3 / 1,600.5, rounded up to 1,650 each. Board: NPU weights 2,154.9 + CPU input
      embedding 272.8 + KV 512 + 2 x 250 + about 100 MiB CPU compute = 3,540 MiB, plus about 660 MiB for the server
      process, libraries and logging (unmeasured) = 4,200.
      B1c PASS needs all of these; any one missing or failed stops B1 before B1d, even with the wrapper's PASS:
        a. the wrapper's verdict PASS (command exit 0, DSP journal with the library opened and CDSP0 lines, no DSP
           fault, kernel audit, no floor, stall, orphans or watchdog event);
        b. the probe's generation: 1..32 tokens, finite timings; its text recorded next to the CPU arm's greedy output
           for the same prompt (no parity claim);
        c. tools/r2_mapped_peak.py $O/probe/server.log 1650,1650 --sessions HTP0:0,HTP0:1: WITHIN;
        d. placement: tools/r2_placement.py $O/probe/server.log --tensors b1-bonsai/table-bonsai2-9b-q2_0.tsv
           --split 18,15 --sessions HTP0:0,HTP0:1 --variant NPU-R --types Q2_0 --output-weight output.weight
           --roles 'attn_q|attn_k|attn_v|attn_output|attn_qkv|attn_gate|ssm_out|ssm_alpha|ssm_beta|ffn_gate|ffn_up|ffn_down'
           --cpu-first 'GET_ROWS,MUL_MAT@prism.hadamard,MUL' --session-src0 prism.hadamard
           : PLACED. That is: loader layers 0-17 on HTP0:0, 18-31 and the output layer 32 on HTP0:1; every graph's
           splits exactly CPU, HTP0:0, HTP0:1 (an op the NPU does not take makes an extra CPU split, or shares the
           first CPU split, which is audited next); the first CPU split holds only GET_ROWS (the input embedding,
           token_embd.weight kept on the CPU by -ot) and the embedding's Hadamard restore (llama-graph.cpp build_tok at
           ff5a2337: a MUL_MAT with a runtime prism.hadamard.* matrix, then a MUL by its signs); every session split
           holds at least one MUL_MAT with a prism.hadamard.* src0 (the blocks' input rotations); each of the 200
           block Q2_0 matmul weights is the weight of a MUL_MAT under its block's session; result_output takes
           output.weight on HTP0:1. By hand, from the printed CPU-split inventory (the tool allows any MUL there): its
           MUL count is at most its prism.hadamard MUL_MAT count, and no other op appears. Both are part of PASS.
        e. logged buffers, the last load phase only (the sizing pass logs them once before; k5-r2 result): per session
           model = the table's weights +/- 0.01 MiB, KV <= 256.01 MiB, RS + compute <= 250 MiB; all recorded. Read by
           hand from the log (r2_logged_buffers.py needs an R1 ledger, which this model does not have).
  B1d (NPU, owner's approval, only after B1c PASS) A sketch until its own frozen spec is reviewed: before it runs, that
      spec fixes the request pairing (the same 20 T5 requests as B1b, fresh slot per trial), the thinking profiles
      (both of B1b's arms), the numeric T5 rule (with B1b's CPU count as the reference) and the llama-bench commands
      and repeats. Backend parity (T3a-style) and the campaign's own qualification (V0e) remain separate and needed
      before any campaign admission; B1's load, T5 and speed cannot give a final GO.

Known risk: ff5a2337 does not change the dspqueue_peek handling of llama.cpp#30309 (no commit since af0579c78 touches
it; checked against the compare list). The package is unpatched, as R2's was, so a peek failure ends the DSP loop and is
a fault (npu_dev_run.sh without --dsp-retry-patched); the campaign's retry library is built for 836d5717 and is not used.

Not claimed: that Bonsai fits a campaign arena budget, that its NPU output is correct, or the publisher's quality
figures. Disk: the file is 2.56 GB; the package about 50 MB; M2 (8.8 GB) stays staged until the owner decides on it.
