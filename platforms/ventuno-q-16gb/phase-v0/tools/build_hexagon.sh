#!/bin/bash
# ggml-hexagon build per llama.cpp docs/backend/snapdragon/linux.md at 836d5717, in the amd64 toolchain
# container (qemu user emulation on this arm64 board). Log: ~/v0/builds/hexagon.log
set -uo pipefail
W=~/v0/llama.cpp-hex; L=~/v0/builds/hexagon.log
cd "$W" || exit 1
{ echo "# hexagon $(date -Is) commit $(git rev-parse HEAD) image ghcr.io/snapdragon-toolchain/arm64-linux:v0.7 ($(docker image inspect -f '{{.Id}}' ghcr.io/snapdragon-toolchain/arm64-linux:v0.7))"
  /usr/bin/time -v docker run --rm -u "$(id -u):$(id -g)" --volume "$W":/workspace --platform linux/amd64 \
    ghcr.io/snapdragon-toolchain/arm64-linux:v0.7 bash -c '
      set -e; cd /workspace; cp docs/backend/snapdragon/CMakeUserPresets.json .
      cmake --preset arm64-linux-snapdragon-release -B build-snapdragon
      cmake --build build-snapdragon -j "$(nproc)"
      cmake --install build-snapdragon --prefix pkg-linux'
  rc=$?; echo "# build rc=$rc $(date -Is)"
  find pkg-linux -type f \( -name "*.so*" -o -path "*/bin/llama-server" -o -path "*/bin/llama-cli" -o -path "*/bin/llama-bench" \) -exec sha256sum {} + 2>/dev/null | sort -k2
} > "$L" 2>&1
tail -1 "$L"; grep -o 'build rc=[0-9]*' "$L"
