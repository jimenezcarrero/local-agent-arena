# V0d investigation: why decode is slower than the Jetson, and what could unlock more

Written 2026-10-06 overnight by the testing agent, on the campaign owner's request ("investigate if there is a way
to improve performance … the Jetson had better tokens/sec generation"). Measurements cited are in
`runs/v0d-tune/`, `runs/v0d-cpu/` and `bw/`; decisions D52–D54.

## 1. Hypothesis: decode is limited by memory bandwidth (not verified on the NPU path)

> Revised after the Codex review of #45 (D65). This section first presented bandwidth as *the* limit and derived NPU
> "ceilings" from a CPU microbenchmark. The 9B's later NPU results contradict those ceilings, so they are withdrawn.

Decode reads every weight once per token, so memory bandwidth ÷ model size is a common first-order bound. What was
actually measured, and what is only estimated:

| | Value | Kind |
|---|---|---|
| CPU read bandwidth on this board (`bw/bw.c`, STREAM-style) | 25.6 GB/s with 4 big-core threads; 12.5 GB/s with 8 threads | measured, CPU path only |
| Jetson Orin Nano 8GB memory bandwidth | 68 GB/s (102 GB/s "Super") | NVIDIA specification, not measured here |
| NPU, NeoHorse-1-4B Q4_0, 7.90 tok/s at 16K | ≈ 16 GB/s if all weights except the token-embedding table (2.02 GB) were read once per token | estimate, not measured traffic; KV reads at 16K add to it |
| NPU, Ornith-1.0-9B Q4_0, 6.29 tok/s at 512 (G′) | ≈ 28 GB/s on the same assumption (4.49 GB: file minus the token-embedding table and the unused MTP layer) | estimate; **above** the CPU-measured 25.6 GB/s |

The CPU measurement is not a ceiling for the NPU: the 9B's NPU decode implies a weight-read rate above it (the NPU
or its DMA path may reach DRAM faster than the CPU cores, or the estimate's assumptions may not hold). The "≈ 11
tok/s (4B)" and "≈ 5 tok/s (9B)" ceilings previously given here are therefore withdrawn. Bandwidth remains a
plausible limit, untested on the NPU path. The cross-platform comparison also uses different models and files
(Jetson: 9B IQ3_M; here: 4B and 9B Q4_0), so it cannot isolate a hardware cause.

**What still follows from measurements:**
- On the CPU path, decode tracks the measured CPU bandwidth: 4 big-core threads nearly double decode compared with
  8 threads (§4, D55), matching the drop in measured read bandwidth with 8 threads.
- **Smaller weights would help, but:** the NPU's fast path is Q4_0; IQ3 types are unsupported on HTP (D44,
  IQ3_M) and q4_0 KV is unsupported (`SET_ROWS`, D45).

## 2. What was ruled out

- **CPU↔NPU ping-pong:** the 4B's per-token graph has 3 splits (CPU input, HTP0:0, HTP0:1); the NPU backend
  implements qwen35's `GATED_DELTA_NET` and `SSM_CONV` itself. The model runs entirely on the NPU.
- **Host-side knobs** (V0d sweep, D53): threads 2/4/6/8, decode vs batch threads, `OPPOLL`, `--cache-ram`
  512/2048 — all within ~2 %. Big-core affinity gave decode +5 % (one run). Smaller ubatch costs prefill.
- **Bigger windows:** 65K does not map on the NPU for the 4B (f16 or q8_0 KV).
- **9B on the NPU:** 1/2/3 sessions, KV q8_0, `-ub 128`, `GGML_HEXAGON_MBUF` 256/512, `GGML_HEXAGON_VMEM=0`: no
  configuration maps with the KV cache on the NPU; KV on the CPU loads but decodes 2.2 tok/s; partial offload
  (20/34 layers) decodes 2.7 tok/s at 8K.
- **Bus/DDR clock:** not exposed to user space (only the GPU has a devfreq governor, `simple_ondemand`
  479–877 MHz); no user-level bandwidth unlock found.

## 2b. Why the NPU mappings fail: single large buffers (inferred mechanism)

Each NPU session is a separate DSP process: session 0 uses the cDSP domain (3); every further virtual session asks
FastRPC for a new session (`FASTRPC_RESERVE_NEW_SESSION`) and gets its own effective domain (e.g. 11) and its own
SMMU context bank (the kernel logs name `compute-cb@3`, `compute-cb@2`; the cDSP has 11 banks, `compute-cb@1–12`).
Hexagon addresses are 32-bit, so each session has a bounded address space (the backend's default `vmem` is
3158 MiB). Every failed mapping in V0c/V0d is **one large buffer**, mapped with a 4 KiB guard:

| Failed mapping | MiB | The buffer |
|---|---|---|
| 1,073,745,920 | 1024 + 4 KiB | 4B KV cache at 65K |
| 671,092,736 | 640 + 4 KiB | 4B KV cache at 40960 (degraded NPU, D53) |
| 570,429,440 | 544 + 4 KiB | 4B KV q8_0 at 65K |
| 1,006,637,056 | 960 + 4 KiB | GenieX ~1 GB compute buffer |
| 572,133,376 | 545.6 | the 9B output layer (one 248K-vocab tensor) |

Large mappings are typically placed at power-of-two alignment, so a "1 GiB + 4 KiB" buffer may need a 2 GiB slot,
and a session can fail while its total is well under its window — consistent with "the limit is not a simple
total" (D53). `GGML_HEXAGON_MBUF` only splits weight buffers, which is why it moved the failure but did not fix it.
This is an inference from the logs; the kernel-side IOVA layout was not inspected (no root, no debugfs).

**Post-reset tests that follow from it** (`tools/v0d_unlock.sh`, run after the final re-measurement):
`-ngl <n_layer>` to keep the output layer and the vocabulary-sized logits on the CPU (4B: 32, 9B: 33),
`GGML_HEXAGON_MBUF=256`, and more sessions to shrink each KV buffer — 9B on 3 and 2 sessions, the 4B on 2, the
4B at 65K on 4 sessions. Even if the 9B fits, its decode margin was then expected to be small (the ceiling estimate is withdrawn, §1) over the
4.4 gate, and the output layer on the CPU costs a little more.

## 3. Paths that could still unlock performance, ranked

1. **Speculative decoding (MTP / draft model)** — a candidate lever if decode is bandwidth-limited, on a board with spare
   NPU compute: one verification pass checks several drafted tokens, so tokens per weight-read rise. On the
   Jetson, MTP gave +27 % to +78 % decode (README, MTP table: A1-4B +27–34 %, E2B +55 %, Qwen3.5-4B +52 %,
   gemma-E4B 19.1 → 32–34 tok/s). Ornith-1.0 has an MTP head (`mtp-head/…Q8_0.gguf`); NeoHorse
   has none published. Needs: llama.cpp MTP support for qwen35 on the Hexagon backend, the draft's own NPU
   mapping (the window is already tight), and separate qualification (runbook: V2 row `e4b-98k-mtp`; never
   assumed). **Not tested.** This llama.cpp build offers `--spec-type draft-mtp`, draft models
   (`draft-simple`, `draft-eagle3`, …) and **n-gram lookup** (`ngram-simple`, `ngram-map-k`, `ngram-mod`,
   `ngram-cache`), which needs no draft model and no extra NPU memory and suits agent workloads that repeat their
   context. Caveat: rejected drafts need the recurrent state rolled back — the same state readback that crashed
   context checkpoints on HTP (D43) — so feasibility on the NPU is the first question (`tools/v0d_unlock.sh` has
   one n-gram test). The speed probe cannot show its benefit; an agent-like workload can.
2. **CPU route with 4 big-core threads** — measured tonight (§4): decode +63 % to +96 %, prefill unchanged. The
   CPU route stays far below the prefill gate, but this is the right default for any CPU-side work.
3. **cDSP reset procedure** — not a speed gain but a prerequisite: after an NPU hang the NPU stays degraded until
   the cDSP is restarted (D53). V0e and the arenas need an automatic, root-scoped recovery (e.g. a sudoers rule
   for one cDSP-restart script) or a reboot policy.
4. **GPU/CPU `performance` governors (root)** — small expected gain for the OpenCL route (GPU at 479 MHz idle
   floor vs 877 max) and the CPU route; the fast A78C pair runs `ondemand`. Untested.
5. **GenieX with a smaller ubatch** — GenieX v0.8.0's NPU prefill was 25 % faster than upstream on the 1.5B, but
   its NPU route fails on the campaign models because its n_ubatch (1024) makes ~1 GB compute buffers. Its source
   (`params.cpp` at `a5c8e7f`) honours a config `n_ubatch`, yet the server never sets one ("Ubatch stays 0:
   ModelParam has no n_ubatch to key on", `keepalive.go`), and the only override table covers two other boards'
   GPUs. Unlocking it needs a GenieX patch/rebuild or a newer release. GenieX does accept explicit multi-session
   device lists (`--compute HTP0,HTP1`), but at ubatch 1024 each session's compute buffer (~488 MiB) matches the
   upstream `-ub 1024` case that failed to map. Cheap to test after the cDSP reset; low expectation.
6. **Newer llama.cpp Hexagon backend** — one Hexagon commit landed upstream after `836d5717` (8345f33,
   2026-10-05: flash-attention head-split for multi-core row-split NPUs; +4 % reported for Qwen3.5-4B); nothing
   about mapping limits or hangs, and this board's HTP is single-core (`hmx 1`). Changing the build means a new configuration and a new V0 baseline.

## 3b. Strata (owner question, 2026-10-06): direct use or its principles

[Strata](https://github.com/Niko1221/Strata) (MIT, built partly on llama.cpp/ggml) runs one 125B mixture-of-experts
model (Qwen3.8-Flash-Next, 24,576 experts, 10 active per token). It places attention, router, KV cache and the
most-used experts on a discrete GPU, holds all experts in RAM and computes the rest on the CPU. It keeps an n-gram
lookup table on an NVMe SSD for prompt processing, and uses MTP speculative decoding (1.6–1.8× claimed).

**Direct use: no.**
- Strata requires an NVIDIA or AMD discrete GPU, x86-64 (AVX2), 32–64 GB of RAM and 70–120 GB on NVMe.
- This board is aarch64, with 15.3 GiB of unified memory, an Adreno/Hexagon accelerator, and eMMC with about 19 GB
  free.

**Its principles, applied to this board:**

| Strata principle | Here | Assessment |
|---|---|---|
| MTP speculative decoding | The 9B GGUF carries its MTP layer: `n_layer_all = 33`, kept on the CPU in H (117 MiB). This build has `--spec-type draft-mtp`. | **Most promising.** Decode is the weak side; on the Jetson MTP gave +27 % to +78 %. Untested here: needs the recurrent-state rollback that failed for context checkpoints on HTP (D43), and its own hang/memory admission. NeoHorse-1-4B has no MTP head. |
| Hot experts on the accelerator, cold experts on CPU/RAM | Only for MoE models; ours are dense. llama.cpp offers it (`--override-tensor`, `--n-cpu-moe`). | A future model class: an MoE with ~3B active parameters could decode like a 3B dense model. It is limited by 16 GB of RAM (a 30B-A3B at Q4 does not fit) and the NPU's per-session mapping (§2b). Unified memory removes the GPU-RAM copy Strata manages. |
| n-gram lookup table on disk | `ngram-map-k` gave no gain on the probe prompts (D59). `ngram-cache` exists in this build. | Agent sessions repeat code and tool output; measure only in real pi sessions (V0e). A disk-backed cache on eMMC is unmeasured; NVMe would help. |
| Weights streamed from SSD | eMMC only | Not useful for weights; would page the model through slow storage. Revisit only with NVMe. |
| 4-bit KV cache, 8,192-token prompt batches | q4_0 KV unsupported on HTP (D45); KV q8_0 hangs (D53); ubatch 1024 does not map (V0c) | Not applicable on the NPU path. |

## 4. CPU thread placement (tonight): decode nearly doubles on the big cores

llama.cpp CPU route (ARMv8.2 build), `-c 40960`, single runs (`runs/v0d-cpu/`), prefill / decode tok/s:

| Model, threads | 512 | 8K |
|---|---|---|
| NeoHorse-1-4B, 8 threads (llama.cpp default) | 30.3 / 4.16 | 24.1 / 2.47 |
| NeoHorse-1-4B, **4 big cores** (`-t 4 --cpu-mask 0xF --cpu-strict 1`) | 31.7 / **7.74** | 23.9 / **4.83** |
| NeoHorse-1-4B, 2 fastest cores (`-t 2 --cpu-mask 0xC`) | 19.0 / 6.46 | 14.0 / 4.23 |
| Ornith-1.0-9B, 8 threads | 18.9 / 2.81 | 16.1 / 1.89 |
| Ornith-1.0-9B, **4 big cores** | 18.6 / **4.58** | 15.6 / **3.32** |

Decode improves by 63–96 % while prefill is unchanged. This is consistent with CPU decode being bandwidth-limited:
measured CPU read bandwidth also halves with 8 threads (§1). Prefill is compute-bound. **llama.cpp's default (all 8 cores) is the wrong
placement for decode on this SoC.** Consequences:
- Every V0c CPU-route number (and GenieX CPU, which ran 8 unpinned threads) is the documented-default result, not
  the route's best; the CPU route still misses the 145 tok/s prefill gate by a factor of 6–9, so no eligibility
  changes.
- Any CPU-side work in the campaign — the V2 rows planned on the CPU (BF16, Q8), the output layer kept on the CPU
  in the unlock tests, partial offload — should use 4 big-core threads. The partial-offload 9B (D48: 2.71 tok/s
  decode at 8K with 8 threads) likely decodes faster this way, but its prefill (~30–40 tok/s) still fails the gate.
- For the NPU candidate the host threads matter less (the NPU does the work), consistent with the +5 % decode
  seen for big-core affinity in the sweep; the final re-measurement compares exactly that (F vs A).

## 4b. What the 40960 cap means for pi and the arenas

The 4B NPU candidate is capped at a 40960-token window (D53). Using pi 0.80.10's own formulas, documented in
`platforms/jetson-orin-nano-8gb/pi-32k-window.txt`:
- output budget = window − context − 4096 → the one-token stall starts at a context ≥ 36,864 at 40960;
- compaction triggers at context > window − 16,384 = 24,576 and keeps ~20K recent tokens plus a summary
  (≈ 26–29K left after compaction in the Jetson's 32K sessions).

At 32K the post-compaction context sat above the stall point (28,672) and sessions stalled; at 40960 the same
context leaves ≈ 8–10K tokens of output budget, so the 32K stall mechanism should not occur. This is arithmetic
from pi's formulas, not a measurement: V0e must verify it with real pi sessions at the window used.

| Cell | Window | 4B NPU candidate |
|---|---|---|
| 32K crusher (pi defaults; comparable with the Jetson) | 32768 | fits |
| Marathons (runbook: 65K or more) | ≥ 65536 | **not possible** unless an unlock test makes 65K map |
| Arenas 1–2 (Jetson parity flags used 65K) | 65536 | only at a smaller window, reported as such |

## 5. Outcome of the morning chain (D57–D59)

- **NPU recovery.** The NPU recovered by itself (idle) about 3 h after the 23:44 hang; no reset was needed.
- **F hung once.** F (4 big-core threads) hung the NPU once in 3 runs (D57). That hang did not degrade the NPU.
- **Final 4B re-measurement on A** (2 sessions, defaults; D58). All runs PASS, no hang:

  | 512 | 8K | 16K | 32K |
  |---|---|---|---|
  | 326.4/9.54 | 342.6/9.31 | 312.9/8.06 | 279.3/6.71 |

  Both tool gates passed. Memory headroom floor: 7.10 GiB.
- **The 9B mapping failure is the token-embedding table** (D59), not the session total:
  - The table stays on the CPU, but lives in ggml-hexagon's DSP-shared host buffer. Op offload sends its lookup to an
    HTP session, which then maps all 546 MiB.
  - Fix: `--no-op-offload` with `-ngl 33` on 3 sessions. The 9B then reaches 152/5.5 at 16K (single run).
  - The mechanism in §2b (single large buffers) holds. The "output layer" in its table was this embedding table.
- **4B at 65K.** It loads on 4 sessions, with every per-session buffer small enough, at the same speed (16K
  314.7/7.81). It still needs depth checks and V0e window qualification.
- **No gain:** n-gram speculation and `--no-host`. `--cache-ram 0` is confirmed slower.

### Round 5 and after (D60–D61)

> Superseded in part: G′ is withdrawn (strict pinning, D63). Its replacement H is re-measured under D65, with
> per-configuration `--cache-ram` from the computed floor. The degraded state's link to full 9B loads is in D64.

- **9B final, G′** (3 sessions, `-ngl 33 --no-op-offload`, MBUF 256, 4 big-core threads). Medians, prefill/decode:

  | 512 | 8K | 16K | 32K |
  |---|---|---|---|
  | 163.5/6.29 | 166.7/6.02 | 159.4/5.49 | 150.1/4.95 |

  Tools: one-shot 10/10, agentic 3/3. Memory floor 5.10 GiB.
  - Without the affinity: 143.5/3.90, so the affinity is required.
  - Why it matters is not known. The CPU side does only the embedding lookup and graph dispatch. A plausible
    explanation, untested: host threads on the A55 cores slow every HTP round-trip.
- **4B at 65536 on 4 sessions:** works to 48.9K tokens (244.4/5.67); min MemAvailable 4.10 GiB in that single run.
- **The NPU degraded with no hang** after about 32 clean loads (03:24–06:28). Every server exited cleanly (SIGTERM,
  memory breakdown printed).
  - Both the base 4B and the 9B then fail to map. The 9B still maps the 546 MiB host buffer into session 2, so it
    loads only on a clean NPU.
  - The degraded state therefore builds up or lingers on the DSP side, independent of hangs. Recovery took about 3 h
    idle once (02:36–02:46). An idle probe is timing it again.
  - This is the main risk for V0e: an arena run that reloads the server could hit a degraded NPU in the middle of a
    campaign. V0e needs a recovery procedure (cDSP restart as root) and a trigger study (number of loads, time, or
    total mapped bytes).
