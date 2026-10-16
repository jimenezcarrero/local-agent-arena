#!/bin/bash
# r1_t7_x86.sh (NPU dev plan T7 / G7, stage R1) — model quality of M2 against REF on an x86_64 host's CPU, before any NPU
#   stage uses M2. Everything it uses is pinned in K5 (k5-t7/README.txt) and checked before use: the master commit, the
#   companion files (comparator, T5 client, T5 requests), the text, its token ids, and both models by size and sha256.
#   Part 1 (teacher-forced logits, same token ids and positions for both models): llama-perplexity writes REF's logits
#     (--kl-divergence-base) over the pinned 20 chunks x 1,024 tokens of WikiText-2 test; then M2 against them
#     (--kl-divergence: mean, 99th-percentile KLD, top-1 agreement "Same top p"); then M2's own logits, and the
#     comparator adds the rank of REF's top token in M2 and cross-checks top-1 and KLD from both files.
#   Part 2 (T5's fresh-prefix screening on the host CPU): llama-server per model (-np 1, --cache-ram 0, slot erased
#     before each trial), the 20 frozen tool-call requests, a trial counted only with cache_n 0 and the whole prompt
#     evaluated.
#   Rule (plan section 5, fixed before any result): PASS only if top-1 agreement >= 90 % (llama-perplexity's Same top
#     p), every reported value finite, both T5 runs valid, M2 passes >= 17/20 and >= REF's passes - 2. Mean KLD, 99th
#     percentile and rank are reported (they are T3a's measures; T7's rule does not threshold them).
#   Output: ~/r1-t7-<stamp>/ (the logits files stay there) and ~/r1-t7-evidence-<stamp>.tar.gz (logs, results, the
#   verdict; no model, no logits) to send back for the record. Nothing on the board; every run in a new directory;
#   every step checked, any failure stops (a failed check is not a FAIL verdict: the run is invalid).
#   Models: M2=<path> REF=<path> (default: the newest ~/r1-k3-*/models/ holding both K3 files).
#   Run it as a whole file, from a reviewed commit:
#     curl -fsSL https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/<commit>/platforms/ventuno-q-16gb/npu-dev/tools/r1_t7_x86.sh -o r1_t7_x86.sh
#     bash r1_t7_x86.sh
#   Overridable for the mocked test only (the manifest then says TEST and the run is not evidence): REPO_URL,
#   TOOLS_BASE, WT_URL, WT_ZIP_SHA, WT_TEST_SHA, TOK_SHA, M2_SHA, M2_SIZE, REF_SHA, REF_SIZE, CMP_SHA, SCREEN_SHA,
#   REQ_SHA, TOKTOOL_SHA, N_CTX, N_CHUNK, MIN_FREE_GIB, PORT.
set -euo pipefail
COMMIT=af0579c78a07a555d84830d01da7b61cfadbc7ef   # ggml-org master, 2026-10-14T06:23:44Z (K1, as K2 and K3)
P_REPO_URL=https://github.com/ggml-org/llama.cpp
# companion files at the commit that holds them as reviewed (filled in by the K5 commit; sha256 checked)
P_TOOLS_BASE=https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/23f36a236689c0531d5cf5599a01112ac9869d6f/platforms/ventuno-q-16gb/npu-dev
P_CMP_SHA=e2639e820eae32b28f1a2f33f80123a9b13f72770196b96b1300051b9b0cfbaa; P_SCREEN_SHA=2789d2c85b2be5b12285204c606a047e8a1d1678f88479ed1e7e0b259231628c; P_REQ_SHA=32058f2e4f24ca86db2b28c432af8e25559dc882ebca32aaa21d85f53aebae35; P_TOKTOOL_SHA=5ee422d747ca02f76ab70a52336d9e8566849568f6ca520290a62acfb200ad6b
# WikiText-2 raw test, as llama.cpp's scripts/get-wikitext-2.sh fetches it, at a pinned dataset revision
P_WT_URL=https://huggingface.co/datasets/ggml-org/ci/resolve/927b3642933080f1b0e811e2f916e14c292992f9/wikitext-2-raw-v1.zip
P_WT_ZIP_SHA=ef7edb566e3e2b2d31b29c1fdb0c89a4cc683597484c3dc2517919c615435a11
P_WT_TEST_SHA=173c87a53759e0201f33e0ccf978e510c2042d7f2cb78229d9a50d79b9e7dd08
# the first 20 x 1,024 evaluation tokens (r1_t7_tokens on the header-only M2 at af0579c78; REF's tokenizer metadata is
# identical): little-endian int32, as llama-perplexity stores them in its logits file
P_TOK_SHA=5ee34deda7a5ab386e53f6d0343f036cb2fd041214a65d3829ab6d7338bd3999
P_N_CTX=1024; P_N_CHUNK=20
# K3's models
P_M2_SHA=43b42f90f64ed2c8ce46bf92a76adcc112dd69842d6c8c43f0fc44935bd914e7; P_M2_SIZE=8809757984
P_REF_SHA=f09bf094a8a138c5b645598ca1abb6696a0fde26662d7af649b0713fdef330b6; P_REF_SIZE=25493732640
P_MIN_FREE_GIB=8; P_PORT=18080
for v in REPO_URL TOOLS_BASE CMP_SHA SCREEN_SHA REQ_SHA TOKTOOL_SHA WT_URL WT_ZIP_SHA WT_TEST_SHA TOK_SHA N_CTX N_CHUNK M2_SHA \
         M2_SIZE REF_SHA REF_SIZE MIN_FREE_GIB PORT; do
  p=P_$v; [ -n "${!v:-}" ] || printf -v "$v" '%s' "${!p}"
done
TEST=no
for v in REPO_URL TOOLS_BASE CMP_SHA SCREEN_SHA REQ_SHA TOKTOOL_SHA WT_URL WT_ZIP_SHA WT_TEST_SHA TOK_SHA N_CTX N_CHUNK M2_SHA \
         M2_SIZE REF_SHA REF_SIZE MIN_FREE_GIB PORT; do p=P_$v; [ "${!v}" = "${!p}" ] || TEST=yes; done
STAMP=$(date +%Y%m%d-%H%M%S)
W=$HOME/r1-t7-$STAMP; SRC=$W/llama.cpp; E=$W/evidence; TAR=$HOME/r1-t7-evidence-$STAMP.tar.gz
die() { echo "FAILED: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
SERVER_PID=
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; wait 2>/dev/null || true; }
trap cleanup EXIT

step "0. host"
[ "$(uname -m)" = x86_64 ] || die "this host is $(uname -m), not x86_64"
for c in git cmake c++ curl sha256sum python3 tar df nproc; do command -v $c >/dev/null || die "$c not found"; done
[ ! -e "$W" ] && [ ! -e "$TAR" ] || die "$W or $TAR already exists; not touching it"
if [ -z "${M2:-}" ] || [ -z "${REF:-}" ]; then
  K3=$(ls -d "$HOME"/r1-k3-*/models 2>/dev/null | sort | tail -1) || true
  [ -n "$K3" ] || die "no ~/r1-k3-*/models directory; set M2= and REF="
  M2=${M2:-$K3/LFM2.5-24B-A2B-M2-Q2_K-af0579c7.gguf}; REF=${REF:-$K3/LFM2.5-24B-A2B-REF-Q8_0-af0579c7.gguf}
fi
[ -f "$M2" ] && [ -f "$REF" ] || die "model files not found: M2=$M2 REF=$REF"
M2=$(realpath -e -- "$M2"); REF=$(realpath -e -- "$REF")
free=$(df -B1 --output=avail "$HOME" | tail -1); need=$((MIN_FREE_GIB * 1024**3))
[ "$free" -ge "$need" ] || die "$((free / 1024**3)) GiB free under $HOME, need $MIN_FREE_GIB (two logits files of ~2.6 GB, the build, logs)"
avail=$(awk '/^MemAvailable:/ {print $2 * 1024}' /proc/meminfo)
[ "$avail" -ge $((REF_SIZE + 2 * 1024**3)) ] || die "MemAvailable $((avail / 1024**2)) MiB < REF + 2 GiB: close other programs and rerun"
THREADS=$(nproc)
mkdir -p "$W" "$E"
echo "host OK: $((free / 1024**3)) GiB free, MemAvailable $((avail / 1024**2)) MiB, threads $THREADS; test overrides: $TEST"

step "1. models (size and sha256; REF takes a minute)"
[ "$(stat -c %s "$M2")" = "$M2_SIZE" ] || die "M2 is $(stat -c %s "$M2") bytes, expected $M2_SIZE"
[ "$(stat -c %s "$REF")" = "$REF_SIZE" ] || die "REF is $(stat -c %s "$REF") bytes, expected $REF_SIZE"
[ "$(sha "$M2")" = "$M2_SHA" ] || die "M2 sha256 differs from $M2_SHA"
[ "$(sha "$REF")" = "$REF_SHA" ] || die "REF sha256 differs from $REF_SHA"
echo "models OK"

step "2. fresh clone at $COMMIT and a host CPU build of llama-perplexity and llama-server (log $E/host-build.log)"
git clone -q --no-checkout "$REPO_URL" "$SRC"
cd "$SRC"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch -q origin "$COMMIT"
git checkout -q --detach "$COMMIT"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || die "checkout is $(git rev-parse HEAD)"
[ -z "$(git status --porcelain)" ] || { git status --porcelain; die "fresh tree not clean"; }
{ cmake -S . -B build-host -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_OPENSSL=OFF && cmake --build build-host -j "$(nproc)" --target llama-perplexity llama-server; } \
  > "$E/host-build.log" 2>&1 || { tail -5 "$E/host-build.log"; die "host build failed; see $E/host-build.log"; }
BIN=$SRC/build-host/bin
[ -x "$BIN/llama-perplexity" ] && [ -x "$BIN/llama-server" ] || die "llama-perplexity or llama-server not built"
CC_=$(sed -n 's/^CMAKE_C_COMPILER:[A-Z]*=//p' build-host/CMakeCache.txt); CXX_=$(sed -n 's/^CMAKE_CXX_COMPILER:[A-Z]*=//p' build-host/CMakeCache.txt)
[ -n "$CC_" ] && [ -n "$CXX_" ] || die "no compiler in build-host/CMakeCache.txt"
{ cmake --version | head -1; echo "CMAKE_C_COMPILER $CC_: $("$CC_" --version | head -1)"; echo "CMAKE_CXX_COMPILER $CXX_: $("$CXX_" --version | head -1)"
  grep -E '^(CMAKE_BUILD_TYPE|CMAKE_C_FLAGS|CMAKE_CXX_FLAGS|GGML_NATIVE|BUILD_SHARED_LIBS)(_RELEASE)?:' build-host/CMakeCache.txt
  echo "cpu: $(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //'); flags: $(grep -m1 '^flags' /proc/cpuinfo | grep -o -w 'avx2\|avx512f\|avx_vnni\|fma\|f16c' | sort -u | tr '\n' ' ')"
  (cd build-host/bin && find . -maxdepth 1 -type f \( -name 'llama-perplexity' -o -name 'llama-server' -o -name '*.so*' \) -exec sha256sum {} + | sort -k2)
} > "$E/host-toolchain.txt"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the build changed tracked files"
echo "build OK"

step "3. companion files (pinned sha256) and the two small tools"
T=$W/tools; mkdir -p "$T"
fetch() { curl -fsSL "$TOOLS_BASE/$1" -o "$T/$(basename "$1")"; [ "$(sha "$T/$(basename "$1")")" = "$2" ] || die "$1 sha256 differs from $2"; }
fetch tools/r1_t7_compare.cpp "$CMP_SHA"; fetch tools/r1_t5_screen.py "$SCREEN_SHA"
fetch k5-t7/t5-requests.json "$REQ_SHA"; fetch tools/r1_t7_tokens.cpp "$TOKTOOL_SHA"
c++ -O2 -std=c++17 "$T/r1_t7_compare.cpp" -o "$T/r1_t7_compare" || die "comparator build failed"
c++ -O2 -std=c++17 -I"$SRC/include" -I"$SRC/common" -I"$SRC/ggml/include" -I"$SRC/vendor" "$T/r1_t7_tokens.cpp" \
  -L"$BIN" -lllama-common -lllama -lggml -lggml-base -Wl,-rpath,"$BIN" -o "$T/r1_t7_tokens" || die "token tool build failed"
(cd "$T" && sha256sum r1_t7_compare r1_t7_tokens r1_t7_compare.cpp r1_t7_tokens.cpp r1_t5_screen.py t5-requests.json) > "$E/tools.sha256"
echo "tools OK"

step "4. text and its token ids"
curl -fsSL "$WT_URL" -o "$W/wikitext-2-raw-v1.zip"
[ "$(sha "$W/wikitext-2-raw-v1.zip")" = "$WT_ZIP_SHA" ] || die "wikitext zip sha256 differs from $WT_ZIP_SHA"
python3 -I -c 'import sys, zipfile; open(sys.argv[2], "wb").write(zipfile.ZipFile(sys.argv[1]).read("wikitext-2-raw/wiki.test.raw"))' \
  "$W/wikitext-2-raw-v1.zip" "$W/wiki.test.raw"
[ "$(sha "$W/wiki.test.raw")" = "$WT_TEST_SHA" ] || die "wiki.test.raw sha256 differs from $WT_TEST_SHA"
"$T/r1_t7_tokens" "$M2" "$W/wiki.test.raw" "$N_CTX" "$N_CHUNK" "$W/tokens-m2.bin" > "$E/tokens-m2.txt" || die "M2 tokenization failed"
"$T/r1_t7_tokens" "$REF" "$W/wiki.test.raw" "$N_CTX" "$N_CHUNK" "$W/tokens-ref.bin" > "$E/tokens-ref.txt" || die "REF tokenization failed"
[ "$(sha "$W/tokens-m2.bin")" = "$TOK_SHA" ] || die "M2's tokens differ from the pinned $TOK_SHA"
[ "$(sha "$W/tokens-ref.bin")" = "$TOK_SHA" ] || die "REF's tokens differ from the pinned $TOK_SHA"
echo "text and tokens OK ($N_CHUNK x $N_CTX)"

step "5. teacher-forced logits (llama-perplexity; logs in $E)"
PPL=("$BIN/llama-perplexity" -c "$N_CTX" -b "$N_CTX" --chunks "$N_CHUNK" -t "$THREADS" -fa on)
"${PPL[@]}" -m "$REF" -f "$W/wiki.test.raw" --kl-divergence-base "$W/ref.kld" > "$E/ppl-ref-base.log" 2>&1 \
  || { tail -5 "$E/ppl-ref-base.log"; die "REF logits failed"; }
"${PPL[@]}" -m "$M2" --kl-divergence-base "$W/ref.kld" --kl-divergence > "$E/ppl-m2-kld.log" 2>&1 \
  || { tail -5 "$E/ppl-m2-kld.log"; die "M2 KL divergence failed"; }
"${PPL[@]}" -m "$M2" -f "$W/wiki.test.raw" --kl-divergence-base "$W/m2.kld" > "$E/ppl-m2-base.log" 2>&1 \
  || { tail -5 "$E/ppl-m2-base.log"; die "M2 logits failed"; }
"$T/r1_t7_compare" "$W/ref.kld" "$W/m2.kld" "$TOK_SHA" > "$E/compare.txt" || { cat "$E/compare.txt"; die "comparator rejected the logits files"; }
(cd "$W" && sha256sum ref.kld m2.kld) > "$E/logits.sha256"
num() { sed -n "s/^$1 *\([-0-9.eE+naif]*\).*/\1/p" "$E/ppl-m2-kld.log" | tail -1; }
MEAN_KLD=$(num 'Mean    KLD:'); P99_KLD=$(num '99.0%   KLD:'); TOP1=$(num 'Same top p:')
for v in "$MEAN_KLD" "$P99_KLD" "$TOP1"; do
  python3 -I -c 'import math,sys; x=float(sys.argv[1]); sys.exit(0 if math.isfinite(x) else 1)' "$v" 2>/dev/null \
    || die "a KL-divergence statistic is missing or not finite (mean '$MEAN_KLD', p99 '$P99_KLD', top-1 '$TOP1')"
done
echo "logits OK: mean KLD $MEAN_KLD, p99 KLD $P99_KLD, top-1 $TOP1 %"; cat "$E/compare.txt"

step "6. T5 fresh-prefix screening on the host CPU (REF, then M2)"
screen() {  # <label> <model>
  local slots=$W/slots-$1; mkdir -p "$slots"
  "$BIN/llama-server" -m "$2" -c 8192 -np 1 --cache-ram 0 --slot-save-path "$slots" --jinja -fa on -t "$THREADS" \
    --host 127.0.0.1 --port "$PORT" --no-webui > "$E/server-$1.log" 2>&1 &
  SERVER_PID=$!
  local up=0
  for _ in $(seq 1 600); do
    kill -0 "$SERVER_PID" 2>/dev/null || die "llama-server ($1) exited; see $E/server-$1.log"
    curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { up=1; break; }; sleep 1
  done
  [ "$up" = 1 ] || die "llama-server ($1) not ready after 600 s"
  python3 -I "$T/r1_t5_screen.py" --server "http://127.0.0.1:$PORT" --requests "$T/t5-requests.json" --out "$E" --label "$1" \
    > "$E/t5-$1.log" 2>&1 || { tail -3 "$E/t5-$1.log"; die "T5 run ($1) invalid; see $E/t5-$1.log"; }
  kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=
}
screen REF "$REF"; screen M2 "$M2"
P_REF=$(sed -n 's/^T5 REF: passes \([0-9]*\)\/20, valid 20\/20$/\1/p' "$E/REF-summary.txt")
P_M2=$(sed -n 's/^T5 M2: passes \([0-9]*\)\/20, valid 20\/20$/\1/p' "$E/M2-summary.txt")
[ -n "$P_REF" ] && [ -n "$P_M2" ] || die "T5 summaries missing or invalid"
echo "T5 OK: REF $P_REF/20, M2 $P_M2/20"

step "7. verdict (plan section 5, T7; fixed before any result)"
VERDICT=$(python3 -I - "$TOP1" "$P_M2" "$P_REF" <<'PY'
import sys
top1, m2, ref = float(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
why = []
if not top1 >= 90.0: why.append(f"top-1 agreement {top1} % < 90 %")
if not m2 >= 17: why.append(f"M2 T5 passes {m2}/20 < 17")
if not m2 >= ref - 2: why.append(f"M2 T5 passes {m2} < REF's {ref} - 2")
print("PASS" if not why else "FAIL: " + "; ".join(why))
PY
)
{ echo "# T7 (NPU dev plan, G7), $(date -Iseconds); test overrides: $TEST"
  echo "llama.cpp: $COMMIT (fresh clone, clean), host CPU build -DGGML_NATIVE=ON (host-toolchain.txt)"
  echo "M2: $M2 bytes $M2_SIZE sha256 $M2_SHA"; echo "REF: $REF bytes $REF_SIZE sha256 $REF_SHA"
  echo "text: $WT_URL sha256 $WT_ZIP_SHA; wiki.test.raw sha256 $WT_TEST_SHA; tokens $N_CHUNK x $N_CTX sha256 $TOK_SHA"
  echo "logits: ${PPL[*]} (paths shortened): REF base, M2 --kl-divergence, M2 base; logits.sha256"
  echo "KL divergence (M2 vs REF): mean $MEAN_KLD, p99 $P99_KLD; top-1 agreement $TOP1 %"
  sed 's/^/compare: /' "$E/compare.txt"
  echo "T5 fresh (host CPU, llama-server -c 8192 -np 1 --cache-ram 0 --slot-save-path <dir> --jinja -fa on): REF $P_REF/20, M2 $P_M2/20"
  echo "rule: top-1 >= 90 %, all statistics finite, both T5 runs valid, M2 >= 17/20 and >= REF - 2"
  echo "T7 VERDICT: $VERDICT"
} > "$E/manifest.txt"
cat "$E/manifest.txt"
tar -C "$W" -czf "$TAR" evidence || die "evidence tarball failed"
echo; echo "evidence: $TAR ($(du -h "$TAR" | cut -f1)) sha256 $(sha "$TAR") (send it back; no model, no logits)"
echo "logits files stay in $W"; echo; echo "DONE"
