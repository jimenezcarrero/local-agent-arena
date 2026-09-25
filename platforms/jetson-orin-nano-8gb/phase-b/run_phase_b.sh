#!/bin/bash
# Phase B (2026-09-21): K2-Horizon-3.7B on the MBZUAI-IFM fork (branch
# model/K2Horizon, commit 42adf01, built with GGML_CUDA_NO_VMM=ON). Upstream
# llama.cpp still has no k2_horizon support; IFM's PR is open.
#
# Sampling: IFM publishes temperature=1.0, top_p=0.95 (the GGUF carries no
# metadata, so these must be passed). Smoke test: 4915MB RSS at 32K, 15.2 tok/s.
# 131K does not load, and the 7B (5564MB at 32K) is left for a headless session.
#
# Quants come from a community packager (NANI-Nithin); IFM ships only BF16.
# If arena 1 fails twice, try another publisher before blaming the model.
set -u
S=$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)/suite
B=/home/JetsonOrin/Repositories/llama.cpp-k2/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
C=(-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics --temp 1.0 --top-p 0.95)
export PI_PROVIDER=jetson

"$S/run_model.sh" k2h37-q4 32768 0 "$B" -m "$M/K2-Horizon-3.7B-Q4_K_M.gguf" "${C[@]}"
for r in 2 3; do
  STEPS="3 4s" "$S/run_model.sh" k2h37-q4-r$r 32768 0 "$B" -m "$M/K2-Horizon-3.7B-Q4_K_M.gguf" "${C[@]}"
done
