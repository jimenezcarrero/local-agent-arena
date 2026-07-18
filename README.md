# LLM Inference Benchmarks — Jetson Orin Nano 8GB on JetPack 7.2

Head-to-head comparison of local LLM inference engines on the NVIDIA Jetson Orin Nano
Developer Kit (8GB) running JetPack 7.2, including a packaging pitfall that cost 40%
of generation speed, and a compatibility survey of five engines.

**TL;DR:** Ollama and llama.cpp are effectively tied when they run the same file fully
on GPU. The real performance killers are *packaging* issues: Ollama's official
`qwen3.5:4b` registry blob bundles a vision encoder that forces a CPU split (8 tok/s
instead of 13+), and LM Studio's ARM64 build ships no `sm_87` CUDA kernels at all, so
it cannot use the Orin GPU.

## Test environment

| Component | Value |
|---|---|
| Device | Jetson Orin Nano Developer Kit 8GB (Ampere iGPU, compute capability 8.7 / sm_87) |
| JetPack | 7.2 (L4T R39.2), CUDA 13.2, unified memory 7.4 GiB |
| Power mode | MAXN_SUPER, active cooling |
| Ollama | v0.32.1 (native install, `OLLAMA_IGPU_ENABLE=1`) |
| llama.cpp | build 86a9c79, `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87` |
| LM Studio | 0.4.19-2 ARM64 AppImage (inspected, not benchmarkable — see below) |
| Date | 2026-07-18 |

## Methodology

- **llama.cpp**: `llama-bench -ngl 99 -r 3` (pp512 = 512-token prompt processing,
  tg128 = 128-token generation, 3 repetitions, mean ± σ).
- **Ollama**: `/api/generate` with a ~760-token prompt, `num_predict: 128`, 3 runs
  after a warm-up request; rates computed from the API's `prompt_eval_duration` /
  `eval_duration` nanosecond timings. First-run prompt rates discarded when
  contaminated by model load; cached-prompt runs discarded for pp.
- Ollama service **stopped** during llama.cpp runs and vice versa. No other load
  (desktop idle).
- Same-file testing wherever possible (see caveats).

## Results

### gemma3:1b Q4_K_M — byte-identical GGUF in both engines, 100% GPU in both

| Engine | Prompt processing (tok/s) | Generation (tok/s) |
|---|---|---|
| llama.cpp | **2278 ± 235** | **43.9 ± 0.1** |
| Ollama | ~1125 | 35.0 |

### Qwen3.5-4B Q4_K_M

| Engine | Model file | Offload | pp (tok/s) | tg (tok/s) |
|---|---|---|---|---|
| Ollama | official `qwen3.5:4b` registry blob (3.4 GB) | 62% GPU / 38% CPU (auto) | ~415 | **8.0** |
| Ollama | unsloth text-only GGUF (2.7 GB, imported) | 100% GPU (auto) | ~590 | **13.3** |
| llama.cpp | unsloth text-only GGUF (same file) | 100% GPU (`-ngl 99`) | 393 ± 22 | **14.3 ± 0.2** |

Forcing `num_gpu: 99` on the unsloth import changed nothing (it already fully
offloaded). The pp measurements between tools are not directly comparable
(llama-bench measures a clean pp512 batch; the API timing includes some overhead) —
treat generation (tg) as the headline metric.

## Findings

1. **Engine speed is nearly identical; packaging decides everything.** Ollama *is*
   llama.cpp under the hood. Same file, same offload → within ~7% on generation
   (13.3 vs 14.3 tok/s on the 4B; the gap is Ollama's server overhead).
2. **Ollama's official qwen3.5:4b blob is a performance trap on 8GB boards.** It
   bundles the vision encoder into the text-model layer (3.4 GB vs 2.7 GB text-only).
   On an 8GB unified-memory board that difference pushes the scheduler into a
   38% CPU split: **8.0 tok/s instead of 13.3** — a 40% loss for the same weights.
   Fix: import a text-only community GGUF (`ollama create` + `FROM model.gguf`).
3. **Ollama's engine-specific GGUF exports don't load upstream.** The qwen3.5 blob
   uses 3-element mRoPE metadata (upstream expects 4) and a different SSM tensor
   layout (`blk.0.ssm_dt.bias` missing). Cross-engine tests must use standard
   HF GGUFs.
4. **LM Studio 0.4.19 cannot use the Orin GPU.** Its ARM64 CUDA-13 backend ships
   kernels for sm_75/80/89/90/100/120/121 — **no sm_87**. It silently falls back to
   CPU on Jetson. (Same bug class Ollama fixed in v0.30.11 / PR #16628.)
5. **JetPack 7.2 + Ollama works natively since v0.31.2** (runtime falls back to the
   sm_87-enabled `cuda_v13` backend; PR #16949). Older versions need the
   `JETSON_JETPACK=6` + jetpack6-tarball workaround. The installer's "Unsupported
   JetPack version" warning is cosmetic (fix pending in PR #17079).

## Engines that could not be benchmarked

| Engine | Status on JetPack 7.2 / Orin Nano 8GB |
|---|---|
| **vLLM** | No Jetson support; PyTorch serving overhead is impractical on 8GB unified memory. |
| **MLC LLM** | Prebuilt containers top out at JetPack 6 (`dustynv/mlc:*-r36.4.0`); incompatible with the R39 driver stack. Source build of TVM untested (multi-hour). |
| **TensorRT Edge-LLM** | Officially supports Orin Nano + JetPack 7.2 and is the most promising performer (NVIDIA's new C++ edge runtime, INT4/NVFP4). Blocked here because the model-export step requires an x86 + NVIDIA GPU host, and no pre-exported ONNX models are published yet. |
| **LM Studio** | ARM64 build lacks sm_87 CUDA kernels (see finding 4). |

## Reproduction

```bash
# llama.cpp with CUDA for Orin (use -j3: -j6 OOM-kills nvcc on 8GB)
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git && cd llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87 -DLLAMA_CURL=OFF
cmake --build build --config Release -j3 --target llama-bench llama-cli

# benchmark
sudo systemctl stop ollama
./build/bin/llama-bench -m Qwen3.5-4B-Q4_K_M.gguf -ngl 99 -r 3
sudo systemctl start ollama

# import a text-only GGUF into Ollama (avoids the vision-bundle CPU split)
printf 'FROM ./Qwen3.5-4B-Q4_K_M.gguf\n' > Modelfile
ollama create qwen3.5-textonly:4b -f Modelfile
```

Model file: [unsloth/Qwen3.5-4B-GGUF](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF)
(`Qwen3.5-4B-Q4_K_M.gguf`), quantized from the same `Qwen/Qwen3.5-4B` base as
Ollama's registry model (both Q4_K_M).

## License

Results and text: CC BY 4.0. Do your own validation before relying on these numbers;
absolute performance depends on thermals, power mode, and software versions.
