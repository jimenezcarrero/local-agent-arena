Exploratory CPU runs of LFM2.5-24B-A2B on the Ventuno Q, 2026-10-13/14. Local exploratory results: not campaign evidence,
not a qualification, and not a matched control for the op-offload plan (that plan measures its own controls on its own
file, plan section 5).

Model  AtomicChat/LFM2.5-24B-A2B-GGUF, LFM2.5-24B-A2B-AD-IQ3_XXS.gguf, 11,124,048,128 bytes,
       sha256 7f1dd73617286f6b8e718d9231a1799374645701c03f041834914d5bac9af699 (matches the Hub's x-linked-etag).
       Experts IQ3_XXS/IQ4_XS: CPU only (no NPU kernel for these types). File removed from the board 2026-10-14 for disk.
Build  ~/v0/llama.cpp/build-cpu-v82 (llama.cpp 836d57176, CPU backend only).
CPU    -t 4 --cpu-mask 0xF --cpu-strict 1 (the four Cortex-A78C cores); default CPU repack on.
Files
  lfm_bench.sh / run1.txt      llama-bench pp512/tg128 at depth 0 and 8192 (llama-bench.md); llama-server -c 16384 --jinja,
                               base vs --spec-type ngram-mod, pi's recorded first request and a 2,048-token code edit, seed 42.
  lfm_bench2.sh / run2.txt     20 replays of pi's first request without a seed (GGUF default sampling: temp 0.1, top_k 50,
                               repeat 1.05); the edit with max_tokens 6144, base vs ngram-mod.
  run2-pi-calls.txt            per replay: cache_n, prompt_n, call name and arguments. Replay 1 is the only fresh prefill;
                               replays 2-20 reuse 1,452 of 1,456 prompt tokens from the server's cache.
  gguf_tensor_types.py         reads a GGUF header and lists tensor types (used on the first 24 MB of the Hub files).
Two kinds of figures: llama-bench (llama-bench.md: pp512 15.81, tg128 9.13 at depth 0; pp512 13.31, tg128 5.90 at depth
8192) and llama-server timings (run*.txt: prompt 15.6 tok/s, generation 8.1-8.5 tok/s on short replies, 7.1 on 6,144).
