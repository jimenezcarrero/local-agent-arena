#!/bin/bash
# r1_build_master_x86.sh (NPU dev plan K2, stage R1) — builds the UNPATCHED control package of ggml-org master af0579c78
#   for the VENTUNO Q on an x86_64 Linux host with Docker: the campaign's toolchain image pinned by id, the documented
#   Snapdragon preset and commands (docs/backend/snapdragon/linux.md at af0579c78). Output ~/r1-k2-<stamp>/ with
#   pkg-unpatched-af0579c7/ (the cmake install), its manifest (sha256 of every file), the build log, the toolchain
#   provenance and the compile flags; packed as ~/pkg-unpatched-af0579c7-<stamp>.tar.gz.
#   Nothing is copied to or installed on the board: staging belongs to R2 (its own manifest and the owner's approval;
#   on the board only under ~/npu-dev/<pkg>, never ~/v0). Every build uses a NEW directory (a fresh clone); nothing
#   existing is checked out, cleaned or overwritten. Every step is checked; any failure stops before packing.
#   Run it as a whole file, from a reviewed commit (not the moving branch):
#     curl -fsSL https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/<commit>/platforms/ventuno-q-16gb/npu-dev/tools/r1_build_master_x86.sh -o r1_build_master_x86.sh
#     bash r1_build_master_x86.sh
#   Overridable for the mocked test only: REPO_URL.
#   Another master commit (a later stage's own manifest names it and its date; the default stays K1's):
#     BUILD_COMMIT=<40-hex sha> BUILD_COMMIT_DATE=<its committer date> bash r1_build_master_x86.sh
#   The package is then pkg-unpatched-<first 8 hex>; everything else (image, preset, checks) is unchanged.
set -euo pipefail
COMMIT=${BUILD_COMMIT:-af0579c78a07a555d84830d01da7b61cfadbc7ef}   # default: ggml-org master, committed 2026-10-14T06:23:44Z (K1)
COMMIT_DATE=${BUILD_COMMIT_DATE:-2026-10-14T06:23:44Z}
REPO_URL=${REPO_URL:-https://github.com/ggml-org/llama.cpp}
IMAGE=ghcr.io/snapdragon-toolchain/arm64-linux:v0.7
IMAGE_ID=sha256:41b710ee5f99d21f0fb9d83a1f815ecffb7708315b4218a11cd0baeb5ecf4c14
# master's ggml-hexagon/CMakeLists.txt :20 prints this line; the campaign's measured build named the same SDK/tools
SDK_LINE="-- hexagon: using /opt/hexagon/6.6.0.0 and /opt/hexagon/6.6.0.0/tools/HEXAGON_Tools/19.0.07 for building libggml-htp skels"
# the preset's CPU flags (CMakeUserPresets.json at af0579c78): dotprod, no i8mm; they decide the CPU repack types
MARCH=-march=armv8.2a+fp16+dotprod
PKG=pkg-unpatched-${COMMIT:0:8}
STAMP=$(date +%Y%m%d-%H%M%S)
W=$HOME/r1-k2-$STAMP; SRC=$W/llama.cpp; TAR=$HOME/$PKG-$STAMP.tar.gz
die() { echo "FAILED: $*" >&2; exit 1; }
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "BUILD_COMMIT must be a full 40-hex sha, got '$COMMIT'"
[ -z "${BUILD_COMMIT:-}" ] || [ -n "${BUILD_COMMIT_DATE:-}" ] || die "BUILD_COMMIT needs BUILD_COMMIT_DATE"
[[ "$COMMIT_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || die "BUILD_COMMIT_DATE must be the committer date in UTC, YYYY-MM-DDTHH:MM:SSZ, got '$COMMIT_DATE'"
step() { echo; echo "=== $*"; }

step "0. host"
[ "$(uname -m)" = x86_64 ] || die "this host is $(uname -m), not x86_64"
for c in docker git sha256sum tar od; do command -v $c >/dev/null || die "$c not found"; done
docker info >/dev/null 2>&1 || die "docker daemon not reachable by $(id -un)"
[ ! -e "$W" ] && [ ! -e "$TAR" ] || die "$W or $TAR already exists; not touching it"
mkdir -p "$W"

step "1. fresh clone at $COMMIT ($SRC)"
git clone -q --no-checkout "$REPO_URL" "$SRC"
cd "$SRC"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch -q origin "$COMMIT"
git checkout -q --detach "$COMMIT"
# the stated date is checked against the commit itself (review of 687d862): the manifest records git's value
GITDATE=$(TZ=UTC git show -s --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ HEAD)
[ "$GITDATE" = "$COMMIT_DATE" ] || die "the commit's committer date is $GITDATE, not $COMMIT_DATE"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || die "checkout is $(git rev-parse HEAD)"
[ -z "$(git status --porcelain)" ] || { git status --porcelain; die "fresh tree not clean"; }
grep -qF -- "\"CMAKE_C_FLAGS\":   \"$MARCH " docs/backend/snapdragon/CMakeUserPresets.json \
  || die "the documented preset's CPU flags are not $MARCH"
echo "source OK: $COMMIT, fresh clone, clean; preset CPU flags $MARCH"

step "2. toolchain image and provenance"
docker pull --platform linux/amd64 "$IMAGE"
got=$(docker image inspect -f '{{.Id}}' "$IMAGE")
[ "$got" = "$IMAGE_ID" ] || die "image id $got, expected $IMAGE_ID"
docker run --rm --platform linux/amd64 "$IMAGE" bash -c 'set -e
  echo "HEXAGON_SDK_ROOT=${HEXAGON_SDK_ROOT:?not set}"; echo "HEXAGON_TOOLS_ROOT=${HEXAGON_TOOLS_ROOT:?not set}"
  "$HEXAGON_TOOLS_ROOT/Tools/bin/hexagon-clang" --version' > "$W/toolchain.txt" 2>&1 \
  || { cat "$W/toolchain.txt"; die "toolchain provenance not captured (SDK/tools roots or hexagon-clang --version)"; }
grep -qx 'HEXAGON_SDK_ROOT=/opt/hexagon/6.6.0.0' "$W/toolchain.txt" || die "image SDK root is not /opt/hexagon/6.6.0.0"
grep -qx 'HEXAGON_TOOLS_ROOT=/opt/hexagon/6.6.0.0/tools/HEXAGON_Tools/19.0.07' "$W/toolchain.txt" || die "image tools root is not 19.0.07"
grep -qi 'clang version' "$W/toolchain.txt" || die "hexagon-clang --version printed no version"
echo "image OK: $got"; cat "$W/toolchain.txt"

step "3. build (documented commands; log $W/build.log)"
set +e
docker run --rm -u "$(id -u):$(id -g)" -v "$SRC":/workspace --platform linux/amd64 "$IMAGE" bash -c "
  set -e; cd /workspace
  cp docs/backend/snapdragon/CMakeUserPresets.json .
  cmake --preset arm64-linux-snapdragon-release -B build-snapdragon
  cmake --build build-snapdragon -j \"\$(nproc)\"
  cmake --install build-snapdragon --prefix $PKG" > "$W/build.log" 2>&1
rc=$?
set -e
echo "docker build rc=$rc"; tail -3 "$W/build.log"
[ $rc -eq 0 ] || die "build failed (rc=$rc); see $W/build.log"
grep -qxF -- "$SDK_LINE" "$W/build.log" || die "build log does not name the SDK/tools: $SDK_LINE"

step "4. check the installed package"
P=$SRC/$PKG
for f in bin/llama-server bin/llama-cli bin/llama-bench bin/llama-perplexity bin/llama-quantize \
         lib/libggml-hexagon.so lib/libggml-htp-v75.so; do
  [ -s "$P/$f" ] || die "$PKG/$f missing"
done
[ "$(od -An -tx1 -j18 -N2 "$P/bin/llama-server" | tr -d ' ')" = b700 ] || die "llama-server is not an aarch64 ELF binary"
grep -E '^CMAKE_C(XX)?_FLAGS:' "$SRC/build-snapdragon/CMakeCache.txt" > "$W/compile-flags.txt" || die "no compile flags in CMakeCache.txt"
[ "$(grep -cF -- "$MARCH" "$W/compile-flags.txt")" = 2 ] || die "the build's C/C++ flags are not $MARCH"
grep -q i8mm "$W/compile-flags.txt" && die "the build's flags name i8mm"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the build changed tracked files"
mv "$P" "$W/$PKG"; P=$W/$PKG
echo "package OK: $(find "$P" -type f | wc -l) files"

step "5. manifest and pack"
(cd "$P" && find . -type f -exec sha256sum {} + | sort -k2) > "$W/$PKG.sha256"
[ -s "$W/$PKG.sha256" ] || die "empty hash list"
{ echo "# K2 unpatched control package (NPU dev plan K2, stage R1), $(date -Is)"
  echo "host: $(uname -srm)"; echo "docker: $(docker --version)"
  echo "source: ggml-org/llama.cpp $COMMIT (master, $COMMIT_DATE; fresh clone, clean, unpatched)"
  echo "image: $IMAGE $got"
  echo "commands: cp docs/backend/snapdragon/CMakeUserPresets.json .; cmake --preset arm64-linux-snapdragon-release -B build-snapdragon;"
  echo "          cmake --build build-snapdragon -j \$(nproc); cmake --install build-snapdragon --prefix $PKG"
  echo "toolchain:"; sed 's/^/  /' "$W/toolchain.txt"
  echo "SDK line in the build log: $SDK_LINE"
  echo "compile flags (CPU repack types follow them: dotprod, no i8mm):"; sed 's/^/  /' "$W/compile-flags.txt"
  echo "files: $(wc -l < "$W/$PKG.sha256"), sha256 list $PKG.sha256 sha256 $(sha256sum "$W/$PKG.sha256" | cut -d' ' -f1)"
  for f in bin/llama-server lib/libggml-hexagon.so lib/libggml-htp-v75.so; do
    echo "$f sha256 $(sha256sum "$P/$f" | cut -d' ' -f1) bytes $(stat -c %s "$P/$f")"; done
  echo "not copied to the board (R2 stages it under ~/npu-dev/$PKG with its own manifest and approval)"
} > "$W/manifest.txt"
cat "$W/manifest.txt"
tar czf "$TAR" -C "$W" "$PKG" "$PKG.sha256" manifest.txt build.log toolchain.txt compile-flags.txt
SUM=$(sha256sum "$TAR" | cut -d' ' -f1)
echo "package: $TAR ($(du -h "$TAR" | cut -f1)) sha256 $SUM"
echo "for the record (send back, small): $W/manifest.txt, $W/$PKG.sha256, $W/compile-flags.txt, $W/toolchain.txt"
echo; echo "DONE"
