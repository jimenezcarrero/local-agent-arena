# Ventuno Q, phase V0: can this board run a local coding agent?

Before any arena ran, phase V0 asked which runtime, model and settings on the Arduino VENTUNO Q could serve the `pi`
coding agent fast enough, reliably enough and within memory. Every route the [runbook](../RUNBOOK.md) lists received
a recorded status against gates frozen before the first measurement; the configurations that passed were then
qualified in real pi sessions. Only NPU configurations qualified, three of them, and went on to phase V1
([results](../phase-v1/README.md)).

**Board:** Arduino VENTUNO Q, Qualcomm QCS8275 (2×A78C 2.11 GHz + 2×A78C 2.36 GHz + 4×A55 1.96 GHz), 15.3 GiB RAM,
Hexagon v75 NPU, Adreno 623 GPU; Ubuntu 24.04.5, kernel 6.8.0-1084-qcom; official 65 W supply, stock fan, eMMC only.

## Outcome

| Configuration | Model | Runtime | 16K prefill / decode (gate 145 / 4.4 tok/s) | Qualification in pi sessions (V0e) | Status |
|---|---|---|---|---|---|
| **B9** | Ternary-Bonsai-2-9B Q2_0 | llama.cpp ggml-hexagon ff5a2337, two NPU sessions, retry-patched DSP library | 190.5 / 7.58 | QUALIFIED at 32K (D181): S1 every item; S2 52 cycles, pi smoke 52/52; 0 faults | **GO** (D184); [V1 record](../phase-v1/b9/README.md) |
| **B4** | Ternary-Bonsai-2-4B Q2_0 | ggml-hexagon ff5a2337, one NPU session, q8_0 KV | 229.7 / 5.12 | QUALIFIED at 32K (D179): S1 every item; S2 70 cycles, pi smoke 69/70; 0 faults | **GO** (D187); [V1 record](../phase-v1/b4/README.md) |
| **A32-5** | NeoHorse-1-4B pure Q4_0 | ggml-hexagon 836d57176, two NPU sessions, `-ngl 32`, retry-patched DSP library | 235.7 / 5.25 | QUALIFIED at 32K (D177), fifth attempt: S1 every item; S2 42 cycles, pi smoke 42/42; 0 faults | **GO** (D187); [V1 record](../phase-v1/a32/README.md) |

All three run at window 32768 with `--cache-ram 5120` and `--ctx-checkpoints 0`. Their exact commands: B9 and B4 in
section 3 of [`v0e-plan-B9.txt`](v0e-plan-B9.txt) and [`v0e-plan-B4.txt`](v0e-plan-B4.txt); A32-5 inherits A32's,
in [`v0e-plan-A32.txt`](v0e-plan-A32.txt) section 3 (command; block 0's placement as corrected in D170) and section 2
(identities), with [`v0e-plan-A32-5.txt`](v0e-plan-A32-5.txt) for its qualification amendments and the package checked
as built at every launch (D176). Speeds are the median of three repeats at a ~16K-token
prompt in the admission set (V0d). The runbook's intended native file, Ornith-1.0-9B pure Q4_0, never qualified, and
its parity file (Ornith-1.0 IQ3_M) is not viable on this board; B9 takes the native lane by the owner's GO (D184).
The two Ternary-Bonsai configurations came out of the NPU development work in [`../npu-dev/`](../npu-dev/)
(`b1-bonsai/`).

**Frozen for V1 (RUNBOOK V0d):** the three admitted configurations above, each exactly as qualified (the commands,
model hashes and package identities above), at window 32768 only; the tier's `--cache-ram` is 5120 MiB. Two memory
checks, both with zero swap growth: memfloor `--admit 5120` per server lifetime, restarts included (L_min, the lowest
MemAvailable plus the held prompt cache, at least 5120 MiB + 0.33 GiB; D184), and the health floor, MemAvailable never
below 1.5 GiB. V2 rows with an admitted configuration: none.

## What V0 found

1. **Only NPU configurations qualified.** The CPU routes were screened out under the fail-fast rule (D32): their 8K
   prefill (about 24 tok/s for the 4B, 16 for the 9B at best) was below half the 145 tok/s gate, so their 16K speed
   was not measured, not measured as a failure. The GPU routes failed where they were tested: OpenCL locked up in the
   8K prefill, Vulkan faulted at the first compute in V0b; GenieX could not load the 4B or 9B on the NPU or GPU at
   its defaults. The NPU (llama.cpp's ggml-hexagon backend) read prompts at 280-350 tok/s with the 4B.
2. **One NPU hang mechanism was diagnosed and mitigated.** Early configurations hung the NPU intermittently, on
   first and later requests alike. One mechanism was identified: the DSP's main thread exits when `dspqueue_peek`
   returns a transient `AEE_ENOMORE` (D127). A retry patch in the DSP library mitigates it (D131-D133): in the patched
   runs each such event was retried once and the session kept serving, with no hang. Persistent or consecutive
   errors, the cause of the underlying signal-wait failure, and configurations beyond those run are not validated.
   Reported upstream as [ggml-org/llama.cpp#30309](https://github.com/ggml-org/llama.cpp/issues/30309). B9 and A32-5
   run patched libraries and logged only isolated retries; B4 qualified on an unpatched library with no retry event.
3. **Full NPU offload broke pi's tool calls on NeoHorse.** With every layer on the NPU, pi's first request got a tool
   call 3 times in 20, against 20 in 20 on the CPU with the same file (D144). Keeping block 0 on the CPU (`-ngl 32`)
   restored 20/20 (D155; its placement corrected in D170). The NPU's outputs depart from the CPU's only with multi-token batches and full offload; the
   exact cause is narrowed, not localized.
4. **Memory is budgeted, not assumed.** The prompt cache grows to its cap. For the early configurations the cap was
   computed from a measured memory floor (D65, D67); the 5120 MiB the three final configurations use began as an
   estimate for A32 (`v0e-plan-A32.txt` section 1(b)), validated in each configuration's own admission and V0e. Every
   run must show the floor kept: L_min at least `--cache-ram` + 0.33 GiB, no swap growth, and MemAvailable above the
   1.5 GiB health floor.
5. **A required NPU setting changes how the cache behaves.** Context checkpoints abort the server (`dsp-error NO-SUPPORT`, D43), so
   all configurations run `--ctx-checkpoints 0`; on these hybrid models that makes prompt-cache reuse across turns
   partial, and V0e measures the cost instead of requiring reuse (D171).
6. **Qualification in real pi sessions caught what the speed gates did not.** Configurations that passed every
   speed and tool gate still failed in pi: no tool call from the model, an NPU hang, the memory floor reached after
   a long session. A32 needed five attempts, and its history shows both kinds of failure: model results (a missed
   tool call, no prefix reuse) and defects in the qualification checks themselves (D159-D175, below).

Decode on this board trails the Jetson Orin Nano's (8.8 tok/s at 16K with Ornith IQ3_M); memory bandwidth is a
hypothesis, not verified on the NPU (D54, D65).

## How V0 worked

| Stage | Question | Result |
|---|---|---|
| V0a | What is on the board as shipped? | Inventory and setup recorded ([`inventory.txt`](inventory.txt), [`files.txt`](files.txt)) |
| V0b | Do the runtimes reproduce Arduino's published figures? (Qwen2.5-1.5B pure Q4_0, 512 tokens) | Every route passed except Vulkan (GPU fault, D48); NPU decode 28.3 tok/s (llama.cpp) and 28.8 (GenieX), against Arduino's ~25 |
| V0c | Which route can run a 4B and a 9B at the 16K gate? | One candidate: ggml-hexagon, two NPU sessions, `--ctx-checkpoints 0`, NeoHorse-1-4B (16K 318.9 / 7.90); no 9B route |
| V0d | Final settings, memory floor and admission (three repeats, both tool gates, no fault) | NeoHorse A and AM admitted (D90); Ornith 9B (H) not, it failed to map; later B4, B9 and A32 admitted |
| V0e | Does the exact configuration hold up in real pi sessions at its window? | S1: pi smoke, streaming tool gates, multi-turn, window and compaction checks; S2: a sustained run of 90+ minutes on one server. A, AR, H2 and A32 attempts 1-4 not qualified; A32-5, B4, B9 qualified |

**Gates (frozen by the runbook before any measurement).** At a ~16K-token prompt: median prefill at least 145 tok/s
and decode at least 4.4 tok/s (half the Jetson reference, 291 / 8.8, [`jetson-reference.txt`](jetson-reference.txt)),
both tool-call gates (10/10 one-shot, 3/3 agentic loops), and the memory floor kept. Measured from the read-only
measurement commit `7badb21`, with health sampled every 10 s throughout.

**Configurations that did not qualify**, and why:

| Configuration | Stopped at | Reason |
|---|---|---|
| A: NeoHorse-1-4B, two NPU sessions, `--cache-ram 7942` | V0e (D118-D120) | NPU hang on pi's first request (before the retry patch) |
| AM: A with an MTP draft head on a third session | not taken to V0e | admitted (D90); A ranked first under the runbook |
| H, H2: Ornith-1.0-9B, three sessions | V0d (H), V0e (H2, D112-D117) | intermittent load failures (NPU mapping); H2 needed a DSP restart before every load |
| AR: A with the retry-patched library | V0e (D139-D140) | no NPU hang in about 3 h, but pi rarely got a tool call (S2: 5 of 56 cycles), and the memory floor was reached after S2 with the cache near its 7,942 MiB cap |
| A32 attempts 1-4: AR with `-ngl 32`, `--cache-ram 5120` | V0e (D159-D175) | 1: the cache item missed its then-frozen reuse limit, compaction could not start, and the baseline probe before S2 hung (D159-D160). 2: a confirmed defect in the window check, and the cache item's first turn did not call bash (suspected wording or model refusal; D165-D166). 3: the window check's ablation refused by the server (a defect), and zero prefix reuse, failing the then-required reuse gate (D169). D171 then replaced the reuse gate with a multi-turn correctness and cost check, a methodology amendment; attempts 1-3 keep their verdicts. 4: a request sizing defect in the new check (D174) |

## Records

- [`details.md`](details.md): the full stage-by-stage record (every table, measurement and fault, as the phase
  README carried it until D192).
- [`decisions.txt`](decisions.txt): every decision and deviation, D1-D192, with the owner's words and the reviews.
- [`v0d-investigation.md`](v0d-investigation.md): the V0d tuning method and analysis.
- Plans, declared before each run: `v0e-plan-*.txt`, [`v0p-plan.txt`](v0p-plan.txt) (the pi tool-call diagnostic).
- Evidence: [`runs/`](runs/) (per run and attempt), [`monitor/`](monitor/) (health exports), [`memfloor/`](memfloor/),
  [`builds/`](builds/), [`quantize/`](quantize/), [`tools/`](tools/) (every script that ran).
- Runbook: [`../RUNBOOK.md`](../RUNBOOK.md).
