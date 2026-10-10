# Phase V0 — VENTUNO Q (16GB): sanity check and capability matrix

Arduino VENTUNO Q (Qualcomm QCS8275, 2×A78C 2.11 GHz + 2×A78C 2.36 GHz + 4×A55 1.96 GHz, 15.3 GiB, Hexagon
v75 NPU, Adreno 623). Ubuntu 24.04.5, kernel 6.8.0-1084-qcom. Official 65 W supply (barrel jack), stock fan,
headless, eMMC only (no NVMe). Runbook: [`RUNBOOK.md`](../RUNBOOK.md). Every decision and deviation:
[`decisions.txt`](decisions.txt) (D1–D130).

**Status (2026-10-09 23:10): V0b and V0c complete. V0d admission sets done: the 4B is provisionally eligible in two
configurations (D90); the 9B is provisionally eligible as H2, which requires a cDSP restart before every load (D109).
V0e at window 32768: H2 NOT QUALIFIED (D112-D117: 3 of 3 loads failed identically, no fault; -c 40960 loaded
afterwards, cause unresolved); A NOT QUALIFIED (D118-D120: loaded and passed both streaming tool gates, then an NPU
hang on the 21st request, pi's first, during decode; watchdog kill, recovered without a restart). Nothing is GO.**

| Set (D85) | 16K median prefill/decode | 8K / 32K median decode | Tools | Memory (lowest margin) | Outcome |
|---|---|---|---|---|---|
| A: NeoHorse-1-4B, 2 NPU sessions, `--cache-ram 7942` | 317.4/8.22 | 9.80 / 7.21 | 10/10, 3/3 | all runs admitted (28 MB, tool gate) | **admitted, 0 faults: provisionally eligible** |
| AM: A + base-model MTP head drafted on a 3rd NPU session, n=1, `--cache-ram 4188` | 178.4/8.64 | 9.76 / 7.71 | 10/10, 3/3 | all runs admitted (245 MiB) | **admitted, 0 faults: provisionally eligible** |
| H: Ornith-1.0-9B, 3 sessions, `--no-host`, `--cache-ram 5364` | r1, r2: 150.3/4.96, 151.8/4.90 | — | not reached | runs admitted (933 MiB) | **stopped: r3 failed to load twice**; 3 of 6 H loads failed to map (D90) |
| H2: H with a cDSP restart + 30 s settle before every probe and load (root helper, D92–D104) | 151.1/4.95 | 5.55 / 4.31 | 10/10, 3/3 | all runs admitted (884 MiB) | **admitted in attempt 2, 1 fault (r1 hung at 32K in attempt 1): provisionally eligible, restart required** (D109) |

Per-depth medians (min–max) of the measured repeats, prefill / decode tok/s (D90; H: r1–r2 only; H2: attempt-2
r1–r3, D109):

| Depth | A (r1–r3) | AM (r1–r3) | H (r1–r2) | H2 (r1–r3) |
|---|---|---|---|---|
| 512 | 343.9 (336.6–348.7) / 10.19 (10.05–10.42) | 189.1 (184.9–189.8) / 10.17 (10.03–10.29) | 157.5 (157.1–157.9) / 5.84 (5.74–5.94) | 157.6 (143.6–158.3) / 5.92 (5.77–5.93) |
| 8K | 345.4 (341.1–347.0) / 9.80 (9.32–9.86) | 189.6 (186.7–189.8) / 9.76 (9.66–11.09) | 155.3 (155.1–155.6) / 5.76 (5.63–5.89) | 158.9 (155.1–159.1) / 5.55 (5.53–5.62) |
| 16K | 317.4 (312.5–317.5) / 8.22 (8.14–8.28) | 178.4 (175.9–178.8) / 8.64 (8.56–8.81) | 151.1 (150.3–151.8) / 4.93 (4.90–4.96) | 151.1 (149.8–152.1) / 4.95 (4.81–5.11) |
| 32K | 282.3 (279.2–282.9) / 7.21 (7.12–7.23) | 165.6 (163.7–166.1) / 7.71 (7.02–7.81) | 142.4 (142.0–142.9) / 4.52 (4.47–4.57) | 143.3 (142.3–144.1) / 4.31 (4.24–4.55) |

H2 ran on 2026-10-08 after a reboot and package updates (D101 environment cohort), a day after A, AM and H.

A and AM ran as consecutive sets (17:39–18:27, then 18:31–19:36), not interleaved, so their differences mix
configuration with time; at 32K AM's decode range overlaps A's. The interleaved comparison (D97, D99) is
incomplete under its declared rule: A hung on the first request of its second run, so one pair has no A result. In the
two complete pairs AM decoded faster at 8K, 16K and 32K (+3 % to +14 %). That A hang is the first fault on a server's
first request; A's admission set stands, but the hang is on record for V0e.

Gates at 16K: 145/4.4. AM trades 44 % of prefill and 3.7 GiB of prompt cache for +5 % median decode at 16K (ranges
do not overlap); at 8K it is level with A, and at 32K the +7 % median is within run-to-run spread (ranges overlap).
Under the runbook ranking (prefill first) A ranks first; AM is a separately eligible alternative (Codex, 20:24Z). No NPU hang or abort occurred in A's or AM's D90 sets. H2's set had one fault (attempt 1 r1 hung at
32K) and passed on its second attempt (D109). Earlier faults (D66, D69, D71, D83, D99, D105, D109, D120) remain on record: V0e's
sustained runs must show whether the admitted configurations stay fault-free.

## What was measured, and how

- **Measurement commit `7badb21`** (`~/v0/measure`, read-only Markdown). Corpus sha256 `3611eb84…`. From
  2026-10-04 19:52 on, `tools/corpus_check.py` recomputed it before every run; runs before 19:52 were covered by a
  single check at that time (`git status --ignored` clean, hash unchanged), not checked individually (D31). V0b runs at `58885b8` (identical corpus, older `speed_probe.py`)
  are kept as labelled evidence.
- **Probes:** `speed_probe.py` at 512/8K/16K/32K tokens; prefill is prompt tokens over time to first token
  (server timing beside it). `probe_toolcalls.py` one-shot (10) and agentic (3 loops). VmHWM after the deepest
  probe. Health sampled every 10 s throughout; each run's window is published (`monitor/*-runs.jsonl`).
- **Fail-fast rule (D32, owner's decision, a runbook deviation):** 16K/32K are not measured when the valid 8K
  prefill is below 72.5 tok/s (half the gate). Such cells are **screened out under D32; their 16K/32K performance
  is unmeasured**, not a measured failure of the 16K gate. The assumption that prefill falls with depth held in the
  one full-depth slow cell (29.5 → 17.4 → 11.8 → 9.2) and in every NPU cell, but is not proven for every route.
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
| llama.cpp Vulkan | Vulkan0 Adreno623, 29/29 layers | – | – | – | – | **FAIL: device lost** (GPU fault at first compute, D48) |

## V0c — capability matrix (`-c`/`--nctx 40960`)

Speeds are prefill / decode tok/s, TTFT-based; prompt sizes are in the per-run evidence. "Screened out (D32)" =
16K/32K unmeasured under the fail-fast rule.

| Route | NeoHorse-1-4B pure Q4_0 | Ornith-1.0-9B pure Q4_0 | Ornith-1.0-9B IQ3_M (parity) |
|---|---|---|---|
| GenieX NPU | **unsupported at defaults**: ~1 GB HTP compute buffer fails to map (D30) | same | not importable (D30) |
| GenieX hybrid | same mapping failure | same | not importable |
| GenieX CPU | 512: 29.5/6.12 · 8K: 17.4/2.14 · 16K: 11.8/1.36 · 32K: 9.2/0.85; tools 1/10 (GenieX empty-reply defect, D33), agentic 3/3; VmHWM 6.34 GiB | 512: 14.6/3.66 · 8K: 11.8/1.97 screened out (D32); tools 1/10 (D33), 3/3; VmHWM 10.35 GiB | not importable |
| GenieX GPU | **unsupported at defaults**: 1280 MiB OpenCL buffer > 1024 MB driver limit (D34) | same (re-run with the owner present, D49; the board did not stop) | not importable |
| llama.cpp CPU (ARMv8.2) | 512: 29.7/4.66 · 8K: 24.0/2.54 screened out (D32); tools 10/10, 3/3; VmHWM 6.95 GiB | 512: 18.7/2.83 · 8K: 16.3/1.89 screened out (D32); tools 10/10, 3/3; VmHWM 10.88 GiB | 512: 2.7/1.36 · 8K: 2.6/1.10 screened out (D32); tools 10/10, 3/3; VmHWM 7.28 GiB (no fast path for iq3_s) |
| llama.cpp OpenCL | 512: 21.5/3.16; **GPU lockup** in the 8K prefill, driver killed the server (D37) | 512: 10.4/1.88 (31/34 layers on GPU); **GPU lockup** in the 8K prefill (D49) | partial placement; 512: 2.2/0.71; stopped after 512 (D49) |
| ggml-hexagon, 1 session | aborts at load: KV 1280 MiB + model exceed the session window (D43) | same | – |
| ggml-hexagon, 2 sessions, defaults | loads; 512: 288.8/9.97; ~12K prefill at ~390 tok/s, then **aborts on a context checkpoint** (`dsp-error NO-SUPPORT`, D43) | – | – |
| **ggml-hexagon, 2 sessions, `--ctx-checkpoints 0`** (non-default, D43) | **512: 349.8/10.06 · 8K: 348.4/9.56 · 16K: 318.8/8.25 · 32K: 282.9/7.22; tools 10/10, 3/3; VmHWM 2.09 GiB** | fails to map (2 and 3 sessions, D44) | iq3_s unsupported on HTP, 2.7 GB stays on CPU, mapping fails |

Exploratory (outside V0c, labelled `v0-explore`): 9B with KV q8_0, KV q4_0 (unsupported: `SET_ROWS`), `-ub 128`,
and KV on CPU — only KV-on-CPU loads, decoding at 2.2 tok/s (D45). 4B with 3 sessions: 16K 282.6/7.12, then an
NPU hang at 32K (threads in `fastrpc_wait_for_completion`). 4B with `-ub 1024`: fails to map.

## Every runbook route: status

Statuses: **measured** (with its V0b verdict), **unsupported at tested defaults**, **blocked**, **failed**,
**deferred** (risk; owner present needed), **not run** (decision recorded).

| Runbook route | V0b (Qwen 1.5B) | V0c status |
|---|---|---|
| llama.cpp CPU, upstream defaults | measured, reference (no DOTPROD, D24) | **not run in V0c** (D29: same CPU route rebuilt with the ISA it lacked) |
| llama.cpp CPU, ARMv8.2 build | measured, reference | measured: 4B, 9B, IQ3_M (all screened out under D32; tool gates pass) |
| llama.cpp OpenCL (Adreno) | PASS 0.66× | 4B: GPU lockup (D37); 9B: 31/34 layers on GPU, 512 10.4/1.88, GPU lockup in the 8K prefill (D49); IQ3_M: partial placement (2.8 GB iq3_s on CPU), 512 2.2/0.71, stopped after 512 (D49) |
| llama.cpp Vulkan (Turnip) | **FAIL: GPU fault** (`device lost on Vulkan0`, kernel GPU recover; D48) | not run (route failed V0b) |
| llama.cpp ggml-hexagon, 1 session | PASS 1.13× | 4B and 9B unsupported at tested defaults (KV mapping, D43) |
| ggml-hexagon, 2 virtual sessions | – | 4B: loads, aborts on context checkpoint at defaults (D43); with `--ctx-checkpoints 0`: **V0c shortlist candidate**; 9B: does not map (D44); IQ3_M: iq3_s unsupported on HTP |
| ggml-hexagon, partial layer offload (`-ngl 20`, 2 sessions, ckpt 0) | – | 9B: loads (20/34 layers on HTP0, rest on CPU); 512: 37.1/3.65, 8K: 28.3/2.71, screened out (D32); one-shot 10/10 (D48) |
| GenieX NPU | PASS 1.15× | 4B and 9B unsupported at defaults (HTP mapping, D30); IQ3_M not importable |
| GenieX hybrid | PASS 0.82× (hung 1 of 2) | 4B and 9B unsupported at defaults (D30); IQ3_M not importable |
| GenieX CPU | PASS 1.45× | 4B measured full depth; 9B screened out (D32); one-shot gate failed by a GenieX defect (D33); IQ3_M not importable |
| GenieX GPU | PASS 0.83× | 4B and 9B unsupported at defaults (1280 MiB OpenCL buffer > 1024 MB limit, D34, D49; the 9B re-run did not stop the board); IQ3_M not importable |
| GenieX QAIRT runtime | – | not tested (runbook: out of scope, issue #1454) |

## V0c shortlist candidate and repeats

One configuration passed both speed thresholds at 16K and both tool gates in V0c, a **V0c shortlist candidate**
(not yet provisionally eligible: V0d must fix final settings, declare the memory floor and re-measure): **llama.cpp ggml-hexagon, 2 virtual sessions (`HTP0:0,HTP0:1`),
`--ctx-checkpoints 0`, NeoHorse-1-4B pure Q4_0**, otherwise llama-server defaults (n_ubatch 512, flash attention
auto, 4 slots, `--cache-ram 8192`, `-c 40960`). One discarded warm-up, then 3 repeats per depth
(`runs/v0c-repeats/`):

| Depth | Prompts (r1–r3) | Prefill median (min–max) | Decode median (min–max) |
|---|---|---|---|
| 512 | 483–494 | 344.9 (325.8–347.6) | 9.64 (9.33–9.93) |
| 8K | 7,576–7,582 | 347.5 (340.8–348.7) | 9.00 (9.00–9.11) |
| **16K** | 18,031–18,039 | **318.9 (312.0–319.2)** | **7.90 (7.82–8.08)** |
| 32K | 31,704–31,715 | 284.3 (278.5–284.6) | 6.88 (6.70–7.18) |

Memory (observed, not a declared floor): min MemAvailable 6.11 GiB (V0c cell with tool probes), 7.29–7.33 GiB
in the repeats; no swap at any point; NPU sensor ≤ 50.5 °C. Against the frozen thresholds: median prefill 318.9
(≥ 145) and decode 7.90 (≥ 4.4) at 16K, both tool gates passed. The memory floor is declared in V0d.

**9B: no viable configuration observed among the tested configurations** (not an exhaustive exclusion). On the
NPU, the 9B's KV cache cannot be mapped at 40960 (an NPU-wide mapping ceiling between ~4.7 and ~5.3 GB is
inferred, not verified); partial offload (20 of 34 layers on the NPU) loads but decodes below the gate; every measured non-NPU route is 9–56× below the prefill gate (16.3 tok/s at best, 2.6 at worst, at 8K).

## V0d — tuning, final settings and re-measurement

Tuning sweep (D53), CPU thread placement (D55), unlock tests (D59), placement variants (D63) and re-measurements
(D58, D60, D64, and D65 running); method and analysis in [`v0d-investigation.md`](v0d-investigation.md). Every
re-measurement: discarded warm-up, 3 repeats (medians below), both tool gates, from measurement commit 7badb21,
ggml-hexagon 836d5717, pure Q4_0, `--ctx-checkpoints 0 -c 40960`, otherwise llama-server defaults.

**Earlier re-measurements, with `--cache-ram 8192`** (evidence only; superseded by D65):

| Configuration | 512 | 8K | **16K** | 32K | Tools | min MemAvailable (32K runs / tools) | Status |
|---|---|---|---|---|---|---|---|
| ~4B A: NeoHorse-1-4B, 2 sessions, `-ngl 99` (D58) | 326.4/9.54 | 342.6/9.31 | **312.9/8.06** | 279.3/6.71 | 10/10; 3 passed, 1 inconclusive | 7.10 / 6.10 GiB | historical (2026-10-06); superseded by the D90 admission set |
| 9B G′: Ornith-1.0-9B, 3 sessions, `GGML_HEXAGON_MBUF=256 -ngl 33 --no-op-offload -t 4 --cpu-mask 0xF --cpu-strict 1` (D60) | 163.5/6.29 | 166.7/6.02 | **159.4/5.49** | 150.1/4.95 | 10/10; 3/3 | 5.10 / 4.05 GiB | **withdrawn** (strict pinning, D63) |
| 9B H: G′ with `-t 4` only (D64) | warm-up + r1 only: r1 158.5/6.01 | 160.0/5.76 | 153.9/5.27 | 144.8/4.75 | not run | — | historical (2026-10-06); superseded by D90 (H not admitted) |

Prefill/decode in tok/s; gates at 16K: 145/4.4.

**Memory floor (D65, [`memfloor/memory-floor.txt`](memfloor/memory-floor.txt)).** Computed, not chosen. L_min is
MemAvailable plus the prompt cache held, at its lowest point in the run. It must cover:
- the prompt cache filling to `--cache-ram` (the MiB cap binds; llama.cpp source);
- pi with its pytest and bash children: 0.19 GiB peak, measured against a mock server, flat up to a ~120K-token
  context;
- transients the cache doesn't explain: 0.14 GiB, the largest drop between health samples.

With 8192 MiB neither A nor the 9B was estimated OOM-safe.

**Per-configuration caps (owner decision).** Each configuration gets floor(L_min − 0.33 GiB), computed in exact kB
(D67; D65's 7,946/5,365/5,724 came from rounded values and are superseded):

| Configuration | `--cache-ram` |
|---|---|
| A | 7,942 MiB |
| 9B H | 5,364 MiB |
| AM (A + NPU-drafted MTP) | 4,188 MiB (provisional: its only run had no tool gate; A's speed-to-tool drop applied, D85) |
| 4B at 65K | 5,727 MiB (provisional; not in admission) |

This deviates from the runbook's single tier value.

**Admission rule** (`tools/memfloor.py --admit`): every final run needs L_min ≥ `--cache-ram` + 0.33 GiB, with swap
growth 0. Missing samples never admit (D75). The policy is an estimate, to be confirmed by real pi sessions in V0e.

**9B unlock (D59, D73, D75).** The 9B's 546 MiB token-embedding table sits in a DSP-shared host buffer. The 9B
does not load with 2 sessions, or without `--no-op-offload`. Even with 3 sessions it maps only intermittently (D61, D64,
D73). With `--no-host` added, the table stays in plain CPU memory and H loaded on the first try (16K 147.0/5.07, single
run, D75).
Without any CPU placement it decodes below the gate (16K 143.5/3.90).

**NPU faults** (exploratory counts across different configurations, depths and recovery states; not a controlled
rate):
- **With `--cpu-strict 1`:** hangs in 3 of 5 loaded servers (D57, D62, D63). Strict pinning is excluded.
- **Before 10:40, without strict pinning, at the final settings:** none in about 28 servers (historical count,
  D63).
- **Since then, without strict pinning:**
  - A hung in its final r1 (D66);
  - the unchanged 4B baseline probe hung twice (D69, spec round 2 at 16:17);
  - a 4B server with the prompt cache off aborted with `dspqueue_read failed` (D71);
  - A hung on the **first request** of a freshly loaded server in the interleaved comparison (A-2, D99), after
    passing its D90 admission.
  - in cDSP-restart screen 2 the unchanged 4B baseline hung on its **first request** after the second restart
    (task 0, 384 prompt tokens; D105); the recovery probe passed 16 min later without a restart (D106);
  - H2 attempt 1: r1 hung at 32K on its sixth request (task 661, 31,722 prompt tokens, after the off-depth 512 and
    8K retries), during decode; the first recovery probe failed to load (degraded mapping, as D61/D64), the second
    passed (D109, D110). Attempt 2 passed with no fault.
  - V0e A: the 21st request of a fresh -c 32768 A server (pi's first request, 1,642 prompt tokens) hung during
    decode after ~278 tokens; watchdog kill after 300 s; the first recovery probe passed without a restart (D120).
- **Pattern:** through D90 every fault hit a later request on a server that had already answered. D99 and D105
  break that: a fresh server is not a safeguard, with or without a cDSP restart. The cause is unknown.

**Admission policy (D68, D71, D75; tools/v0d_runner.sh `admit_set`):**
- A complete set (warm-up, r1–r3, both tool gates, each with the memory check) must finish with no hang or NPU
  abort.
- After a fault, the full set restarts once after baseline recovery. A second fault means not eligible in V0d.
  Faults in readiness or recovery probes during a set count toward the same budget (D89).
- All faults, readiness probes included, go to the phase's `faults.txt`.
- A GPU, DSP, SMMU or FastRPC fault line in the run's kernel window is a device fault even when the speed probe
  passed; an unknown kernel alert stops the sequence (D86, `tools/kernel_audit.py`).
- Admission sets (D85, `tools/v0d_admit_chain.sh`, in this order): A at 7,942 MiB, AM at 4,188 MiB, 9B H with
  `--no-host` at 5,364 MiB. The 4B at 65K is not run.

**Speculative decoding** (D70–D84; single exploratory runs, Markdown-continuation probes; the outcome per model):

| Model | Variant | 16K prefill/decode | Acceptance | Note |
|---|---|---|---|---|
| 4B | control (same-session reference, round 4 mean) | ~315/7.95 | — | 8K decode 9.04 |
| 4B | **base-model MTP head, n=1, drafted on a 3rd NPU session** | 176.1/8.72 | 0.81 | +10 % decode at 16K, +6 % at 8K; prefill falls (MTP outputs every prompt position) but stays above 145. Single exploratory run; admitted as AM in D90 (see the status table). |
| 4B | same, target on 3 sessions + draft on a 4th | 176.3/8.55 | 0.79 | equal; n=2 hung the NPU at 16K (D83) |
| 4B | base-model MTP, n=1, drafted on the CPU | 95.1/5.57 (4 big cores) | 0.78 | CPU drafting costs about one target step |
| 4B | 0.8B draft, n=4 | 41.1/2.36 | 0.54 | |
| 4B | n-gram (`ngram-mod`) | 312.7/8.03 | 0.06 | no gain |
| 4B | DFlash, n=3 (head on the CPU, the only layout that loads) | 151.2/3.58 | 0.58 | below the decode gate (D84) |
| 4B | GPU draft (combined NPU+GPU+CPU build v2) | — | — | Adreno lockup on the 8K prompt: GPU device fault, route closed (D82, D86) |
| 9B | **plain H with `--no-host`** | 147.0/5.07 | — | best 9B; single exploratory run; not admitted in D90 (load failures) |
| 9B | own MTP, n=1, output head on the CPU | below H | 0.81–0.84 | loads only in this layout; the head on the CPU costs more than MTP gains (D79) |

The combined build v1 failed the parity gate on decode (−5.1 % at 8K, D80); v2 (gcc 13, OpenMP and llamafile off,
different -march flags) passed it (D82). v2 changed several build options, so the pass supports a build-configuration
explanation, not one isolated cause (D88). Batch-cost ratios from llama-bench (D83, audited offline in
`runs/v0d-spec4c/bench-audit.txt`) are derived per-call costs for these layouts and depths, not NPU-only timings.

**Tested, not adopted:**

| Setting | Result |
|---|---|
| 4 big-core threads, strict pinning, on the 4B (F) | +4–7 % decode; hung the NPU in 2 of its 4 loaded servers (D57, D62) |
| KV q8_0 | hangs the NPU |
| `--cache-ram 0` | 16K about 217/6.4 (3 runs) |
| ubatch 128/256 | prefill drops |
| ubatch 1024 | does not map |
| n-gram speculation | no gain |
| `--no-host` | no gain |
| 4B with the output layer on the CPU | slower prefill |

**65K window for the 4B:** it loads on 4 sessions (`-ngl 99`). A single run reached a depth of 48.9K tokens
(244.4/5.67), with a floor of 4.10 GiB. It is a candidate for window qualification in V0e; the 4B's final
setting stays at 40960.

**Why decode trails the Jetson:**
- Hypothesis, not verified on the NPU: decode is limited by memory bandwidth. Measured CPU read bandwidth is 25.6 GB/s
  with 4 threads; the Jetson's is 68 GB/s by specification (not measured here). The NPU path's bandwidth is unknown:
  the 9B's NPU decode implies a rate above the CPU figure. The platforms also ran different model files, so this
  does not isolate a hardware cause (D54, revised D65).
- On the CPU route, llama.cpp's default 8 threads halve decode compared with 4 threads on the big cores (D55).

**Open risk — the NPU's degraded state:**
- After a hang, or with no hang after successful full 9B loads (after 7, then after 2; D61, D64), no configuration
  maps until the NPU recovers. About 18 4B-only loads in a row never triggered it.
- Idle recovery took about 3 h once, then about 16–17 min three times. Otherwise it needs a cDSP restart, which
  requires root.
- V0e must define a recovery procedure, and the 9B route must keep one long-lived server or space its restarts.

## Failure classes found

| Class | Where |
|---|---|
| Unsupported at defaults (memory mapping) | GenieX npu/hybrid (D30); ggml-hexagon 1 session and the 9B (D43–D45) |
| Unsupported quantization | IQ3_M on GenieX (import) and on HTP (iq3_s) |
| Driver allocation limit | GenieX GPU, 1024 MB OpenCL buffer (D34) |
| Runtime defect | GenieX empty reply on a fully cached prompt (D33); ggml-hexagon context checkpoint `NO-SUPPORT` (D43) |
| Hangs | GenieX hybrid (V0b, FastRPC wait); ggml-hexagon 3 sessions at 32K (FastRPC wait), KV q8_0 (D53), strict CPU pinning, 4B and 9B (D57, D62, D63), later requests at final settings (D66, D69, D71), MTP n=2 (D83); OpenCL GPU lockup (D37, D82); unexplained board stop (D39) |
| NPU degraded state | no mapping until idle recovery; after a hang (D53) or after full 9B loads (D61, D64) |
| Client/tooling | `speed_probe.py` SSE parsing, fixed in #44 (D25) |

## Still pending before any admission

- **V0c coverage:** every runbook route now has a status (the table above). The three cells deferred overnight were
  run with the owner present (D49). Vulkan failed V0b and is not carried into V0c. The 2026-10-04 board stop (D39)
  did not reproduce when GenieX GPU × Ornith-9B was re-run; its cause stays unexplained.
- **V0d:** done for the 4B (A and AM provisionally eligible, D90). The 9B is not admitted (load reliability); another
  declared attempt is the owner's decision. **V0e** comes next for each exact configuration:
  - pi's streaming path and a real-pi smoke session;
  - each intended window at its real size (40960 is not 65K);
  - cached multi-turn reuse;
  - a ≥ 90-minute sustained run with no NPU hang;
  - a recovery procedure for the NPU's degraded state (D61).
- **9B:** H is a candidate pending its own re-measurement. Its prefill margin is thin (1.03–1.06× in single runs),
  and it loads only on a clean NPU.
- **`--ctx-checkpoints 0`** is a non-default setting adopted in V0c (D43); it is part of the candidate's manifest.
- `speed_probe.py`'s `timeout=3600` is a socket read timeout, not a per-request cap (several 8K requests on the
  slowest routes took longer than an hour and completed).
