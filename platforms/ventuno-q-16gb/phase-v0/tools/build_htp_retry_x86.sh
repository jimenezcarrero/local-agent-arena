#!/bin/bash
# build_htp_retry_x86.sh [user@board] (D129) — builds the two DSP libraries of upstream/htp-retry-validation-plan.txt on
#   an x86_64 Linux host with Docker, with the same toolchain image and commands as build_hexagon_x86.sh (the measured
#   package, D40): (a) control = libggml-htp-v75.so from the UNPATCHED commit, (b) retry = the same with
#   upstream/htp-main-thread-retry.patch.txt (pinned by sha256). Writes the plan's build manifest and packs
#   ~/htp-retry-builds-<commit8>.tar.gz; with user@board it copies the tarball to ~/v0/ on the board and verifies the
#   copy's sha256 there. Nothing is installed or run on the board. Every step is checked; any failure stops.
#   Run it as a whole file:
#     curl -fsSL https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/ventuno-q/platforms/ventuno-q-16gb/phase-v0/tools/build_htp_retry_x86.sh -o build_htp_retry_x86.sh
#     bash build_htp_retry_x86.sh arduino@ventunoq.local
set -euo pipefail
COMMIT=836d57176dc699a726c55418e4f96b8ca628e1bf
IMAGE=ghcr.io/snapdragon-toolchain/arm64-linux:v0.7
IMAGE_ID=sha256:41b710ee5f99d21f0fb9d83a1f815ecffb7708315b4218a11cd0baeb5ecf4c14
PATCH_URL=https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/ventuno-q/platforms/ventuno-q-16gb/phase-v0/upstream/htp-main-thread-retry.patch.txt
PATCH_SHA=4b9838df84f60e802bf1bd9564c78c72afc915e902a81b173d0d72a65045151c
RELEASE_SHA=1fd898cc0709498defeed3439a52500ff8340efd7725b3f88902e0adb2d0aa37  # measured package's libggml-htp-v75.so
W=$HOME/llama.cpp-htp-retry; OUT=$W/htp-retry-out
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
  [ -s "$W/pkg-$1/lib/libggml-htp-v75.so" ] || die "pkg-$1/lib/libggml-htp-v75.so missing"
  cp "$W/pkg-$1/lib/libggml-htp-v75.so" "$OUT/libggml-htp-v75-$1.so"
}
has() { grep -qaF "$2" "$1"; }

step "0. host"
[ "$(uname -m)" = x86_64 ] || die "this host is $(uname -m), not x86_64"
for c in docker git curl sha256sum tar; do command -v $c >/dev/null || die "$c not found"; done
docker info >/dev/null 2>&1 || die "docker daemon not reachable by $(id -un)"

step "1. source at $COMMIT (separate tree: $W)"
[ -d "$W/.git" ] || git clone https://github.com/ggml-org/llama.cpp "$W"
cd "$W"
git fetch -q origin "$COMMIT" 2>/dev/null || git fetch -q origin
git checkout -q -f --detach "$COMMIT"
rm -rf build-control build-retry pkg-control pkg-retry CMakeUserPresets.json "$OUT"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || die "checkout is $(git rev-parse HEAD)"
[ -z "$(git status --porcelain)" ] || { git status --porcelain; die "source tree not clean"; }
mkdir -p "$OUT"; echo "source OK: $COMMIT, clean"

step "2. toolchain image"
docker pull --platform linux/amd64 "$IMAGE"
got=$(docker image inspect -f '{{.Id}}' "$IMAGE")
[ "$got" = "$IMAGE_ID" ] || die "image id $got, expected $IMAGE_ID"
docker run --rm --platform linux/amd64 "$IMAGE" bash -c 'env | grep -iE "hexagon|sdk" | sort
  h=$(command -v hexagon-clang || find / -name hexagon-clang -path "*/bin/*" 2>/dev/null | head -1)
  echo "hexagon-clang: ${h:-not found}"; [ -n "$h" ] && "$h" --version' > "$OUT/toolchain.txt" 2>&1 || true
echo "image OK: $got"; cat "$OUT/toolchain.txt"

step "3. control build (unpatched; log $OUT/build-control.log)"
build control
has "$OUT/libggml-htp-v75-control.so" "in a row), retrying" && die "control library contains the patch's message"

step "4. patch"
curl -fsSL "$PATCH_URL" -o "$OUT/htp-main-thread-retry.patch.txt"
[ "$(sha256sum "$OUT/htp-main-thread-retry.patch.txt" | cut -d' ' -f1)" = "$PATCH_SHA" ] || die "patch sha256 differs from $PATCH_SHA"
rm -f CMakeUserPresets.json
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
  echo "source: ggml-org/llama.cpp $COMMIT (clean before patching)"
  echo "image: $IMAGE $got"
  echo "commands: cp docs/backend/snapdragon/CMakeUserPresets.json .; cmake --preset arm64-linux-snapdragon-release -B build-<name>;"
  echo "          cmake --build build-<name> -j \$(nproc); cmake --install build-<name> --prefix pkg-<name>"
  echo "patch: htp-main-thread-retry.patch.txt sha256 $PATCH_SHA"; sed 's/^/  /' "$OUT/patch-diffstat.txt"
  echo "toolchain:"; sed 's/^/  /' "$OUT/toolchain.txt"
  echo "SDK lines in the build logs:"; grep -hiE "hexagon sdk|HEXAGON_SDK|htp-v75" "$OUT"/build-*.log | sort -u | head -8 | sed 's/^/  /'
  for f in "$c" "$r"; do echo "$(basename "$f") sha256 $(sha256sum "$f" | cut -d' ' -f1) bytes $(stat -c %s "$f")"; done
  echo "release (measured) libggml-htp-v75.so sha256 $RELEASE_SHA"
  echo "control == release bytes: $([ "$(sha256sum "$c" | cut -d' ' -f1)" = "$RELEASE_SHA" ] && echo yes || echo 'no (expected if the build embeds paths or times; V1 tests C on the board)')"
  echo "strings check: retry has 'in a row), retrying': yes; control: no"
} > "$OUT/manifest.txt"
cat "$OUT/manifest.txt"
TAR=$HOME/htp-retry-builds-${COMMIT:0:8}.tar.gz
tar czf "$TAR" -C "$W" htp-retry-out
SUM=$(sha256sum "$TAR" | cut -d' ' -f1)
echo "package: $TAR ($(du -h "$TAR" | cut -f1)) sha256 $SUM"

if [ -n "$TARGET" ]; then
  step "7. copy to $TARGET:~/v0/ and verify there"
  scp "$TAR" "$TARGET:v0/"
  remote=$(ssh "$TARGET" "sha256sum v0/$(basename "$TAR")" | cut -d' ' -f1)
  [ "$remote" = "$SUM" ] || die "copy on the board has sha256 $remote, expected $SUM"
  echo "copy verified on the board: $remote"
fi
echo; echo "DONE"
