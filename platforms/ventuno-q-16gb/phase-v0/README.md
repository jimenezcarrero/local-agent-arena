# Phase V0 — VENTUNO Q (16GB): sanity check and capability matrix

Arduino VENTUNO Q (Qualcomm QCS8275, 2×A78C 2.11 GHz + 2×A78C 2.36 GHz + 4×A55 1.96 GHz, 15.3 GiB, Hexagon
v75 NPU, Adreno 623). Ubuntu 24.04.5, kernel 6.8.0-1084-qcom. Official 65 W supply (barrel jack), stock fan,
headless, eMMC only (no NVMe). Runbook: [`RUNBOOK.md`](../RUNBOOK.md). Every decision and deviation:
[`decisions.txt`](decisions.txt) (D1–D46).

**Status: V0b complete; V0c exploration complete except for three deferred cells; one shortlist candidate
(the ~4B) with its repeats. No GO is declared: provisional eligibility needs V0d's re-measurement on final
settings, and GO needs V0e.**

## What was measured, and how

- **Measurement commit `7badb21`** (`~/v0/measure`, read-only Markdown). Corpus sha256 `3611eb84…`, recomputed
  before every run (`tools/corpus_check.py`). V0b runs at `58885b8` (identical corpus, older `speed_probe.py`)
  are kept as labelled evidence.
- **Probes:** `speed_probe.py` at 512/8K/16K/32K tokens; prefill is prompt tokens over time to first token
  (server timing beside it). `probe_toolcalls.py` one-shot (10) and agentic (3 loops). VmHWM after the deepest
  probe. Health sampled every 10 s throughout; each run's window is published (`monitor/*-runs.jsonl`).
- **Fail-fast rule (D32, owner's decision):** 16K/32K are skipped when the valid 8K prefill is below 72.5 tok/s
  (half the gate). The one full-depth CPU cell confirmed that prefill falls with depth (29.5 → 17.4 → 11.8 → 9.2).
- **Gates (runbook, frozen):** at 16K (prompt within ±20%), prefill ≥ 145 tok/s and decode ≥ 4.4 tok/s, both
  tool gates passed, memory floor kept.

## Runtimes, builds and files

| Component | Version / hash |
|---|---|
| llama.cpp (native builds) | `836d5717` (build 11381), GCC 13.3; CPU and OpenCL, each at upstream defaults and with `-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16+rcpc` (D24) — `builds/*.txt` |
| llama.cpp ggml-hexagon | same commit, cross-built on x86_64 (Hexagon SDK 6.6.0.0, Clang 21.1.8); package `5916fed1…`, `llama-server` `815b22bb…`, `libggml-htp-v75.so` `1fd898cc…` (D40) |
| GenieX | v0.8.0, QAIRT 2.45; llama.cpp plugin version not reported (empty), identified by file hashes (`geniex-install.txt`) |
| OpenCL driver | `qcom-adreno-cl1` 1.855.3, OpenCL 3.0 build 0855.3 |

| File | Source | sha256 | Quantization |
|---|---|---|---|
| Qwen2.5-1.5B-Instruct (V0b) | `Qwen/…-GGUF@91cad51` fp16 `fc89e330…` | `78b8d3c9…` | pure Q4_0, 198/198 weights, 4.50 BPW |
| NeoHorse-1-4B (~4B) | `TokenRhythm/…-GGUF@3c5d58c` BF16 `b27b4cb2…` | `f822fa26…` | pure Q4_0, 249/249, 4.51 BPW |
| Ornith-1.0-9B (native) | `protoLabsAI/Ornith-1.0-9B-MTP-GGUF@fd81c7a` BF16 `018d5c0a…` | `d21c19e5…` | pure Q4_0, 258/258, 4.50 BPW |
| Ornith-1.0-9B (parity) | same repo/revision | `9ef72d9c…677b` | IQ3_M — **identical to the Jetson's copy** (D36) |

## V0b — sanity check against Arduino (Qwen2.5-1.5B pure Q4_0, 512 tokens)

| Route | Placement | Decode tok/s | Prefill tok/s | Arduino | Ratio | Verdict |
|---|---|---|---|---|---|---|
| llama.cpp OpenCL | 29/29 layers GPU | 4.92 | 62.3 | 7.4 | 0.66 | PASS |
| llama.cpp CPU, upstream default | CPU, no DOTPROD | 5.50 | 20.4 | – | – | reference |
| llama.cpp CPU, ARMv8.2 | CPU, DOTPROD, repack | 12.04 | 80.3 | – | – | reference |
| GenieX GPU | GPUOpenCL | 7.61 | 61.9 | 9.2 | 0.83 | PASS |
| GenieX CPU | CPU | 16.54 | 91.2 | 11.4 | 1.45 | PASS |
| GenieX hybrid | HTP0 + OpenCL + CPU | 11.37 | 171.4 | 13.9 | 0.82 | PASS, hung once in 2 runs |
| GenieX NPU | HTP0 | 28.81 | 1014.6 | ~25 | 1.15 | PASS |
| llama.cpp ggml-hexagon | 29/29 layers HTP0 (v75) | 28.26 | 801.6 | ~25 | 1.13 | PASS |
| llama.cpp Vulkan | – | – | – | – | – | not built (D28; `spirv-headers` now installed) |

## V0c — capability matrix (`-c`/`--nctx 40960`)

Speeds are prefill / decode tok/s, TTFT-based; prompt sizes are in the per-run evidence. FF = fail-fast (16K/32K
not measured).

| Route | NeoHorse-1-4B pure Q4_0 | Ornith-1.0-9B pure Q4_0 | Ornith-1.0-9B IQ3_M (parity) |
|---|---|---|---|
| GenieX NPU | **unsupported at defaults**: ~1 GB HTP compute buffer fails to map (D30) | same | not importable (D30) |
| GenieX hybrid | same mapping failure | same | not importable |
| GenieX CPU | 512: 29.5/6.12 · 8K: 17.4/2.14 · 16K: 11.8/1.36 · 32K: 9.2/0.85; tools 1/10 (GenieX empty-reply defect, D33), agentic 3/3; VmHWM 6.34 GiB | 512: 14.6/3.66 · 8K: 11.8/1.97 FF; tools 1/10 (D33), 3/3; VmHWM 10.35 GiB | not importable |
| GenieX GPU | **unsupported at defaults**: 1280 MiB OpenCL buffer > 1024 MB driver limit (D34) | deferred: board stopped during start-up (D39) | not importable |
| llama.cpp CPU (ARMv8.2) | 512: 29.7/4.66 · 8K: 24.0/2.54 FF; tools 10/10, 3/3; VmHWM 6.95 GiB | 512: 18.7/2.83 · 8K: 16.3/1.89 FF; tools 10/10, 3/3; VmHWM 10.88 GiB | 512: 2.7/1.36 · 8K: 2.6/1.10 FF; tools 10/10, 3/3; VmHWM 7.28 GiB (no fast path for iq3_s) |
| llama.cpp OpenCL | 512: 21.5/3.16; **GPU lockup** in the 8K prefill, driver killed the server (D37) | deferred (GPU lockup risk) | deferred |
| ggml-hexagon, 1 session | aborts at load: KV 1280 MiB + model exceed the session window (D43) | same | – |
| ggml-hexagon, 2 sessions, defaults | loads; 512: 288.8/9.97; ~12K prefill at ~390 tok/s, then **aborts on a context checkpoint** (`dsp-error NO-SUPPORT`, D43) | – | – |
| **ggml-hexagon, 2 sessions, `--ctx-checkpoints 0`** (non-default, D43) | **512: 349.8/10.06 · 8K: 348.4/9.56 · 16K: 318.8/8.25 · 32K: 282.9/7.22; tools 10/10, 3/3; VmHWM 2.09 GiB** | fails to map (2 and 3 sessions, D44) | iq3_s unsupported on HTP, 2.7 GB stays on CPU, mapping fails |

Exploratory (outside V0c, labelled `v0-explore`): 9B with KV q8_0, KV q4_0 (unsupported: `SET_ROWS`), `-ub 128`,
and KV on CPU — only KV-on-CPU loads, decoding at 2.2 tok/s (D45). 4B with 3 sessions: 16K 282.6/7.12, then an
NPU hang at 32K (threads in `fastrpc_wait_for_completion`). 4B with `-ub 1024`: fails to map.

## Shortlist and repeats

Only one configuration meets every gate: **llama.cpp ggml-hexagon, 2 virtual sessions (`HTP0:0,HTP0:1`),
`--ctx-checkpoints 0`, NeoHorse-1-4B pure Q4_0**, otherwise llama-server defaults (n_ubatch 512, flash attention
auto, 4 slots, `--cache-ram 8192`, `-c 40960`). One discarded warm-up, then 3 repeats per depth
(`runs/v0c-repeats/`):

| Depth | Prompts (r1–r3) | Prefill median (min–max) | Decode median (min–max) |
|---|---|---|---|
| 512 | 483–494 | 344.9 (325.8–347.6) | 9.64 (9.33–9.93) |
| 8K | 7,576–7,582 | 347.5 (340.8–348.7) | 9.00 (9.00–9.11) |
| **16K** | 18,031–18,039 | **318.9 (312.0–319.2)** | **7.90 (7.82–8.08)** |
| 32K | 31,704–31,715 | 284.3 (278.5–284.6) | 6.88 (6.70–7.18) |

Memory: min MemAvailable 6.11 GiB (V0c cell with tool probes), 7.29–7.33 GiB in the repeats; no swap at any
point; NPU sensor ≤ 50.5 °C. Against the gates: prefill 318.9 ≥ 145, decode 7.90 ≥ 4.4 — **provisionally
eligible for the ~4B**, pending V0d and V0e.

**9B: no configuration found.** On the NPU, the 9B's KV cache cannot be mapped at 40960 (an NPU-wide mapping
ceiling between ~4.7 and ~5.3 GB is inferred, not verified); every measured non-NPU route is 9–56× below the prefill gate (16.3 tok/s at best, 2.6 at worst, at 8K).

## Failure classes found

| Class | Where |
|---|---|
| Unsupported at defaults (memory mapping) | GenieX npu/hybrid (D30); ggml-hexagon 1 session and the 9B (D43–D45) |
| Unsupported quantization | IQ3_M on GenieX (import) and on HTP (iq3_s) |
| Driver allocation limit | GenieX GPU, 1024 MB OpenCL buffer (D34) |
| Runtime defect | GenieX empty reply on a fully cached prompt (D33); ggml-hexagon context checkpoint `NO-SUPPORT` (D43) |
| Hangs | GenieX hybrid (V0b, FastRPC wait); ggml-hexagon 3 sessions at 32K (FastRPC wait); OpenCL GPU lockup (D37); unexplained board stop (D39) |
| Client/tooling | `speed_probe.py` SSE parsing, fixed in #44 (D25) |

## Still pending before any admission

- **Deferred V0c cells:** llama.cpp OpenCL × 9B and × IQ3_M; GenieX GPU × 9B; llama.cpp Vulkan (now buildable).
- **V0d** (tuning on the shortlist, final settings, re-measurement), then **V0e** for the exact configuration:
  pi's streaming path and a real-pi smoke session, each intended window at its real size (40960 is not 65K),
  cached multi-turn reuse, and a ≥ 90-minute sustained run. The two NPU hangs seen in other configurations make
  the sustained run essential.
- **9B:** tuning paths (KV q8_0 on fewer layers, partial `-ngl`, smaller windows) need their own decision.
- **`--ctx-checkpoints 0`** is a non-default setting adopted in V0c (D43); it is part of the candidate's manifest.
- `speed_probe.py`'s `timeout=3600` is a socket read timeout, not a per-request cap (several 8K requests on the
  slowest routes took longer than an hour and completed).
