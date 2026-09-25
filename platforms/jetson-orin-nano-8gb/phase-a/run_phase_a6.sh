#!/bin/bash
# Phase A6 (queued 2026-09-20): NeoHorse-1-4B at its vendor-published sampling.
# Its GGUF carries no general.sampling.* metadata, so Phase A3/A5 ran it at
# llama.cpp defaults (temp 0.8, top_k 40, min_p 0.05, no presence penalty).
# TokenRhythm's reported protocol is temp=1.0, top_p=0.95, top_k=20, min_p=0,
# presence_penalty=1.5, repetition_penalty=1.0 — the presence penalty is an
# anti-repetition measure, which is exactly what long agent sessions stress.
set -u
S=$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)/suite
B=/home/JetsonOrin/Repositories/llama.cpp-master/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
C=(-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics
   --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 1.5 --repeat-penalty 1.0)
export PI_PROVIDER=jetson

STEPS="1 2 3 4s 4b" "$S/run_model.sh" neohorse-q4-vp1 32768 131072 "$B" -m "$M/NeoHorse-1-4B-Q4_K_M.gguf" "${C[@]}"
for r in 2 3; do
  STEPS="3 4s" "$S/run_model.sh" neohorse-q4-vp$r 32768 0 "$B" -m "$M/NeoHorse-1-4B-Q4_K_M.gguf" "${C[@]}"
done
