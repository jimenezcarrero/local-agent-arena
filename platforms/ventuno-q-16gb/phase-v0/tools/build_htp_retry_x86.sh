#!/bin/bash
# build_htp_retry_x86.sh [user@board] (D129, D130) — builds the two DSP libraries of upstream/htp-retry-validation-plan.txt
#   on an x86_64 Linux host with Docker, with the same toolchain image and commands as build_hexagon_x86.sh (the
#   measured package, D40): (a) control = libggml-htp-v75.so from the UNPATCHED commit, (b) retry = the same with
#   upstream/htp-main-thread-retry.patch.txt (pinned by sha256). Writes the plan's build manifest and packs
#   ~/htp-retry-builds-<stamp>.tar.gz; with user@board it copies the tarball to ~/v0/ on the board (never over an
#   existing file) and verifies the copy's sha256 there. Nothing is installed or run on the board.
#   Every build uses a NEW directory ~/htp-retry-<stamp> (a fresh clone); no existing directory, tree or earlier
#   output is checked out, cleaned or overwritten (D130, Codex review of 91fe117 finding 1). Every step is checked;
#   any failure stops before packing, including missing toolchain provenance (finding 3).
#   Run it as a whole file, from a reviewed commit (not the moving branch):
#     curl -fsSL https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/<commit>/platforms/ventuno-q-16gb/phase-v0/tools/build_htp_retry_x86.sh -o build_htp_retry_x86.sh
#     bash build_htp_retry_x86.sh arduino@ventunoq.local
#   Overridable for the mocked test only: REPO_URL, PATCH_URL.
set -euo pipefail
COMMIT=836d57176dc699a726c55418e4f96b8ca628e1bf
REPO_URL=${REPO_URL:-https://github.com/ggml-org/llama.cpp}
IMAGE=ghcr.io/snapdragon-toolchain/arm64-linux:v0.7
IMAGE_ID=sha256:41b710ee5f99d21f0fb9d83a1f815ecffb7708315b4218a11cd0baeb5ecf4c14
PATCH_URL=${PATCH_URL:-https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/8002b63938901c480ac28d90c3125a06e20d862c/platforms/ventuno-q-16gb/phase-v0/upstream/htp-main-thread-retry.patch.txt}
PATCH_SHA=4b9838df84f60e802bf1bd9564c78c72afc915e902a81b173d0d72a65045151c
RELEASE_SHA=1fd898cc0709498defeed3439a52500ff8340efd7725b3f88902e0adb2d0aa37  # measured package's libggml-htp-v75.so
# The SDK and tools of the measured build (builds/hexagon-laptop/hexagon-build.txt): each build log must name them.
SDK_LINE="-- hexagon: using /opt/hexagon/6.6.0.0 and /opt/hexagon/6.6.0.0/tools/HEXAGON_Tools/19.0.07 for building libggml-htp skels"
STAMP=$(date +%Y%m%d-%H%M%S)
W=$HOME/htp-retry-$STAMP; OUT=$W/htp-retry-out; TAR=$HOME/htp-retry-builds-$STAMP.tar.gz
TARGET=${1:-}
die() { echo "FAILED: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }
build() {  # build <name>: documented commands into build-<name>, installed into pkg-<name>
  set +e
  docker run --rm -u "$(id -u):$(id -g)" -v "$W":/workspace --platform linux/amd64 "$IMAGE" bash -c "
    set -e; cd /workspace
    cp docs/backend/snapdragon/CMakeUserPresets.json .
    cmake --preset arm64-linux-snapdragon-release -B build-$1
    cmake --build build-$1 -j \"\$(nproc)\"
    cmake --install build-$1 --prefix pkg-$1" > "$OUT/build-$1.log" 2>&1
  local rc=$?; set -e
  echo "docker build $1 rc=$rc"; tail -3 "$OUT/build-$1.log"
  [ $rc -eq 0 ] || die "build $1 failed (rc=$rc); see $OUT/build-$1.log"
  grep -qxF -- "$SDK_LINE" "$OUT/build-$1.log" || die "build $1 log does not name the measured SDK/tools: $SDK_LINE"
  [ -s "$W/pkg-$1/lib/libggml-htp-v75.so" ] || die "pkg-$1/lib/libggml-htp-v75.so missing"
  cp "$W/pkg-$1/lib/libggml-htp-v75.so" "$OUT/libggml-htp-v75-$1.so"
}
has() { grep -qaF "$2" "$1"; }

step "0. host"
[ "$(uname -m)" = x86_64 ] || die "this host is $(uname -m), not x86_64"
for c in docker git curl sha256sum tar; do command -v $c >/dev/null || die "$c not found"; done
docker info >/dev/null 2>&1 || die "docker daemon not reachable by $(id -un)"
[ ! -e "$W" ] && [ ! -e "$TAR" ] || die "$W or $TAR already exists; not touching it"

step "1. fresh clone at $COMMIT ($W)"
ref=(); [ -d "$HOME/llama.cpp-hex/.git" ] && ref=(--reference-if-able "$HOME/llama.cpp-hex" --dissociate)  # read-only reuse of objects
git clone -q --no-checkout "${ref[@]}" "$REPO_URL" "$W"
cd "$W"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch -q origin "$COMMIT"
git checkout -q --detach "$COMMIT"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || die "checkout is $(git rev-parse HEAD)"
[ -z "$(git status --porcelain)" ] || { git status --porcelain; die "fresh tree not clean"; }
mkdir "$OUT"; echo "source OK: $COMMIT, fresh clone, clean"

step "2. toolchain image and provenance"
docker pull --platform linux/amd64 "$IMAGE"
got=$(docker image inspect -f '{{.Id}}' "$IMAGE")
[ "$got" = "$IMAGE_ID" ] || die "image id $got, expected $IMAGE_ID"
docker run --rm --platform linux/amd64 "$IMAGE" bash -c 'set -e
  echo "HEXAGON_SDK_ROOT=${HEXAGON_SDK_ROOT:?not set}"; echo "HEXAGON_TOOLS_ROOT=${HEXAGON_TOOLS_ROOT:?not set}"
  "$HEXAGON_TOOLS_ROOT/Tools/bin/hexagon-clang" --version' > "$OUT/toolchain.txt" 2>&1 \
  || { cat "$OUT/toolchain.txt"; die "toolchain provenance not captured (SDK/tools roots or hexagon-clang --version)"; }
grep -qx 'HEXAGON_SDK_ROOT=/opt/hexagon/6.6.0.0' "$OUT/toolchain.txt" || die "image SDK root is not /opt/hexagon/6.6.0.0"
grep -qx 'HEXAGON_TOOLS_ROOT=/opt/hexagon/6.6.0.0/tools/HEXAGON_Tools/19.0.07' "$OUT/toolchain.txt" || die "image tools root is not 19.0.07"
grep -qi 'clang version' "$OUT/toolchain.txt" || die "hexagon-clang --version printed no version"
echo "image OK: $got"; cat "$OUT/toolchain.txt"

step "3. control build (unpatched; log $OUT/build-control.log)"
build control
has "$OUT/libggml-htp-v75-control.so" "in a row), retrying" && die "control library contains the patch's message"

step "4. patch"
curl -fsSL "$PATCH_URL" -o "$OUT/htp-main-thread-retry.patch.txt"
[ "$(sha256sum "$OUT/htp-main-thread-retry.patch.txt" | cut -d' ' -f1)" = "$PATCH_SHA" ] || die "patch sha256 differs from $PATCH_SHA"
rm -f CMakeUserPresets.json  # copied by the control build; the next build copies it again
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "control build changed tracked files"
git apply --check -v "$OUT/htp-main-thread-retry.patch.txt" > "$OUT/patch-check.txt" 2>&1 || { cat "$OUT/patch-check.txt"; die "patch does not apply"; }
git apply "$OUT/htp-main-thread-retry.patch.txt"
git diff --stat > "$OUT/patch-diffstat.txt"; git diff > "$OUT/patch-applied.diff"
[ "$(git diff --name-only)" = ggml/src/ggml-hexagon/htp/main.c ] || die "patch changed more than htp/main.c"
cat "$OUT/patch-diffstat.txt"

step "5. retry build (patched; log $OUT/build-retry.log)"
build retry
has "$OUT/libggml-htp-v75-retry.so" "in a row), retrying" || die "retry library lacks the patch's message"

step "6. manifest and pack"
c=$OUT/libggml-htp-v75-control.so; r=$OUT/libggml-htp-v75-retry.so
{ echo "# htp retry build manifest (upstream/htp-retry-validation-plan.txt section 1), $(date -Is)"
  echo "host: $(uname -srm)"; echo "docker: $(docker --version)"
  echo "source: ggml-org/llama.cpp $COMMIT (fresh clone, clean before patching)"
  echo "image: $IMAGE $got"
  echo "commands: cp docs/backend/snapdragon/CMakeUserPresets.json .; cmake --preset arm64-linux-snapdragon-release -B build-<name>;"
  echo "          cmake --build build-<name> -j \$(nproc); cmake --install build-<name> --prefix pkg-<name>"
  echo "patch: htp-main-thread-retry.patch.txt sha256 $PATCH_SHA"; sed 's/^/  /' "$OUT/patch-diffstat.txt"
  echo "toolchain:"; sed 's/^/  /' "$OUT/toolchain.txt"
  echo "SDK line in both build logs: $SDK_LINE"
  for f in "$c" "$r"; do echo "$(basename "$f") sha256 $(sha256sum "$f" | cut -d' ' -f1) bytes $(stat -c %s "$f")"; done
  echo "release (measured) libggml-htp-v75.so sha256 $RELEASE_SHA"
  echo "control == release bytes: $([ "$(sha256sum "$c" | cut -d' ' -f1)" = "$RELEASE_SHA" ] && echo yes || echo 'no (expected if the build embeds paths or times; V1 tests C on the board)')"
  echo "strings check: retry has 'in a row), retrying': yes; control: no"
} > "$OUT/manifest.txt"
cat "$OUT/manifest.txt"
tar czf "$TAR" -C "$W" htp-retry-out
SUM=$(sha256sum "$TAR" | cut -d' ' -f1)
echo "package: $TAR ($(du -h "$TAR" | cut -f1)) sha256 $SUM"

if [ -n "$TARGET" ]; then
  step "7. copy to $TARGET:~/v0/ and verify there"
  ssh "$TARGET" "test ! -e v0/$(basename "$TAR")" || die "v0/$(basename "$TAR") already exists on the board (or ssh failed)"
  scp "$TAR" "$TARGET:v0/"
  remote=$(ssh "$TARGET" "sha256sum v0/$(basename "$TAR")" | cut -d' ' -f1)
  [ "$remote" = "$SUM" ] || die "copy on the board has sha256 $remote, expected $SUM"
  echo "copy verified on the board: $remote"
fi
echo; echo "DONE"
