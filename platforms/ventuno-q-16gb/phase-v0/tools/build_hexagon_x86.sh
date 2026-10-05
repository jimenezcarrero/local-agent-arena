#!/bin/bash
# build_hexagon_x86.sh [user@board]
#   Cross-compiles upstream llama.cpp with the Hexagon (NPU) backend for the VENTUNO Q on an x86_64 Linux host
#   with Docker (llama.cpp docs/backend/snapdragon/linux.md at the pinned commit; D26 option a). Every step is
#   checked; nothing is packaged or sent unless the build installed llama-server and the v75 HTP library.
#   With user@board it copies the package to ~/v0/ on the board and verifies the copy's sha256 there.
#   Run it as a whole file, not by pasting lines:
#     curl -fsSL https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/ventuno-q/platforms/ventuno-q-16gb/phase-v0/tools/build_hexagon_x86.sh -o build_hexagon_x86.sh
#     bash build_hexagon_x86.sh arduino@ventunoq.local
set -euo pipefail
COMMIT=836d57176dc699a726c55418e4f96b8ca628e1bf
IMAGE=ghcr.io/snapdragon-toolchain/arm64-linux:v0.7
IMAGE_ID=sha256:41b710ee5f99d21f0fb9d83a1f815ecffb7708315b4218a11cd0baeb5ecf4c14
W=$HOME/llama.cpp-hex
TARGET=${1:-}
die() { echo "FAILED: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }

step "0. host"
[ "$(uname -m)" = x86_64 ] || die "this host is $(uname -m), not x86_64"
command -v docker >/dev/null || die "docker not found"
command -v git >/dev/null || die "git not found"
docker info >/dev/null 2>&1 || die "docker daemon not reachable by $(id -un)"

step "1. source at $COMMIT"
[ -d "$W/.git" ] || git clone https://github.com/ggml-org/llama.cpp "$W"
cd "$W"
git fetch -q origin "$COMMIT" 2>/dev/null || git fetch -q origin
git checkout -q --detach "$COMMIT"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || die "checkout is $(git rev-parse HEAD)"
rm -rf build-snapdragon pkg-linux CMakeUserPresets.json hexagon-build.log pkg-linux.sha256 build-host.txt
[ -z "$(git status --porcelain)" ] || { git status --porcelain; die "source tree not clean"; }
echo "source OK: $(git rev-parse HEAD), clean"

step "2. toolchain image"
docker pull --platform linux/amd64 "$IMAGE"
got=$(docker image inspect -f '{{.Id}}' "$IMAGE")
[ "$got" = "$IMAGE_ID" ] || die "image id $got, expected $IMAGE_ID"
echo "image OK: $got"

step "3. build (log: $W/hexagon-build.log)"
set +e
docker run --rm -u "$(id -u):$(id -g)" -v "$W":/workspace --platform linux/amd64 "$IMAGE" bash -c '
  set -e; cd /workspace
  cp docs/backend/snapdragon/CMakeUserPresets.json .
  cmake --preset arm64-linux-snapdragon-release -B build-snapdragon
  cmake --build build-snapdragon -j "$(nproc)"
  cmake --install build-snapdragon --prefix pkg-linux' > hexagon-build.log 2>&1
rc=$?
set -e
echo "docker build rc=$rc"; tail -5 hexagon-build.log
[ $rc -eq 0 ] || die "build failed (rc=$rc); see $W/hexagon-build.log"

step "4. check the installed package"
for f in bin/llama-server bin/llama-cli bin/llama-bench lib/libggml-hexagon.so lib/libggml-htp-v75.so; do
  [ -s "pkg-linux/$f" ] || die "pkg-linux/$f missing"
done
[ "$(od -An -tx1 -j18 -N2 pkg-linux/bin/llama-server | tr -d ' ')" = b700 ] || die "llama-server is not an aarch64 ELF binary"
echo "package OK: $(find pkg-linux -type f | wc -l) files"

step "5. hash and pack"
(cd pkg-linux && find . -type f -exec sha256sum {} + | sort -k2) > pkg-linux.sha256
[ -s pkg-linux.sha256 ] || die "empty hash list"
{ echo "host: $(uname -a)"; echo "docker: $(docker --version)"; echo "commit: $(git rev-parse HEAD)"
  echo "image: $IMAGE $got"; echo "built: $(date -Is)"; } > build-host.txt
TAR=$HOME/pkg-linux-${COMMIT:0:8}.tar.gz
tar czf "$TAR" pkg-linux pkg-linux.sha256 hexagon-build.log build-host.txt
SUM=$(sha256sum "$TAR" | cut -d' ' -f1)
echo "package: $TAR ($(du -h "$TAR" | cut -f1)) sha256 $SUM"

if [ -n "$TARGET" ]; then
  step "6. copy to $TARGET:~/v0/ and verify there"
  scp "$TAR" "$TARGET:v0/"
  remote=$(ssh "$TARGET" "sha256sum v0/$(basename "$TAR")" | cut -d' ' -f1)
  [ "$remote" = "$SUM" ] || die "copy on the board has sha256 $remote, expected $SUM"
  echo "copy verified on the board: $remote"
fi
echo; echo "DONE"
