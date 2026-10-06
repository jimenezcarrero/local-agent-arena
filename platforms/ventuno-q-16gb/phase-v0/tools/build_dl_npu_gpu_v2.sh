#!/bin/bash
# D80: version 2, CPU options matched to the reference package (OpenMP OFF, llamafile OFF, -march=armv8.2-a+fp16+dotprod, -O3 Release); gcc 13 instead of clang 21 (no clang on the board).
# D74: native board build of llama.cpp 836d5717 with dynamic backends (CPU, OpenCL) plus a shim that loads the prebuilt
# Hexagon backend, so one llama-server can place the target on the NPU and a draft on the Adreno GPU.
# Waits for the speculation sweep (round 2) so the CPU-heavy build does not disturb measurements.
set -uo pipefail
L=~/v0/dlbuild/build2.log; say() { echo "$(date -Is) $*" | tee -a $L; }
say "build start"; cd ~/v0/llama.cpp; [ "$(git rev-parse --short=9 HEAD)" = 836d57176 ] || { say "FAIL: source not at 836d5717"; exit 1; }
cmake -S . -B build-dl2 -DCMAKE_BUILD_TYPE=Release -DGGML_BACKEND_DL=ON -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16+rcpc \
  -DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=ON -DGGML_OPENCL_EMBED_KERNELS=ON -DLLAMA_CURL=OFF -DGGML_OPENMP=OFF -DGGML_LLAMAFILE=OFF -DCMAKE_C_FLAGS="-march=armv8.2-a+fp16+dotprod -D_GNU_SOURCE" -DCMAKE_CXX_FLAGS="-march=armv8.2-a+fp16+dotprod -D_GNU_SOURCE" -DOpenCL_LIBRARY=/usr/lib/aarch64-linux-gnu/libOpenCL.so.1 >> $L 2>&1 || { say "FAIL: cmake"; exit 1; }
nice -n 10 cmake --build build-dl2 --target llama-server -j 6 >> $L 2>&1 || { say "FAIL: build"; exit 1; }
B=build-dl2/bin; H=~/v0/hexpkg/pkg-linux/lib
gcc -O2 -fPIC -shared -I ggml/include ~/v0/dlbuild/shim_hexagon.c -o $B/libggml-hexagon-shim.so -L$H -lggml-hexagon -Wl,-rpath,$H >> $L 2>&1 || { say "FAIL: shim"; exit 1; }
ls $B/libggml-*.so >> $L
say "devices:"; env LD_LIBRARY_PATH=$B:$H ADSP_LIBRARY_PATH=$H GGML_HEXAGON_DEVICES=HTP0:0 $B/llama-server --list-devices >> $L 2>&1
grep -E 'HTP0|GPUOpenCL' $L | tail -3; say "build done"
