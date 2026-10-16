#!/bin/bash
# r1_models_x86.sh (NPU dev plan K3, stage R1) — makes M2 (Q2_K, llama-quantize's default mix, no imatrix) and REF
#   (Q8_0) of LFM2.5-24B-A2B from Liquid's BF16 GGUF on an x86_64 Linux host, with llama-quantize built for the host CPU
#   at the same pinned master commit as K2 (af0579c78), and records for each: sha256, size, the complete tensor table
#   with each tensor's NPU allocation (gguf_tensor_table.py, pinned by sha256), the session summaries (3 and 4
#   sessions, ctx 16,384; master and release rules; NPU-R' with the board's CPU repack types) and the header check
#   that every expert tensor is an NPU (repack) type.
#   Output: ~/r1-k3-<stamp>/ (models/ holds the .gguf files; they stay on this host) and the small evidence tarball
#   ~/r1-k3-evidence-<stamp>.tar.gz (manifest, tables, logs; no model) to send back for the record.
#   Not done here: T7 (its text, token ids and settings are pinned in K5 first), M3 (Track O), anything on the board.
#   Disk: about 45 GiB for the BF16 download, 24 GiB REF, 8 GiB M2, 1 GiB build. With BF16=<path> (relative or
#   absolute, spaces allowed; resolved before anything else) an existing copy is used, checked against the pinned size
#   and sha256 like a download, and nothing is downloaded.
#   Download (no BF16=): into ~/r1-downloads/, the one location this script reuses across runs: an interrupted
#   download stays there as <file>.part and the next run resumes it (curl -C -); a complete file there is reused; both
#   are checked against the pinned size and sha256 before use; a downloaded .part becomes the complete file only after
#   both checks pass (a failing file is named in the message: delete it and rerun).
#   Disk admission (review of 17130d9) after the source is known: 36 GiB for the outputs and build (REF 23.7 GiB, M2
#   about 8.2, the clone and build about 1.5), plus the bytes still to download (none with BF16= or a complete cached
#   file; the size minus the .part for a partial one; the whole size otherwise).
#   Every run uses a NEW directory; nothing existing is touched. Every step is checked; any failure stops.
#   Run it as a whole file, from a reviewed commit (not the moving branch):
#     curl -fsSL https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/<commit>/platforms/ventuno-q-16gb/npu-dev/tools/r1_models_x86.sh -o r1_models_x86.sh
#     bash r1_models_x86.sh            # or: BF16=/path/to/LFM2.5-24B-A2B-BF16.gguf bash r1_models_x86.sh
#   Overridable for the mocked test only (the manifest then says TEST and the run is not evidence): REPO_URL,
#   BF16_URL, BF16_SIZE, BF16_SHA, TABLE_URL, TABLE_SHA.
set -euo pipefail
COMMIT=af0579c78a07a555d84830d01da7b61cfadbc7ef   # ggml-org master, 2026-10-14T06:23:44Z (K1, the same as K2)
P_REPO_URL=https://github.com/ggml-org/llama.cpp
# Liquid's BF16 GGUF, LiquidAI/LFM2.5-24B-A2B-GGUF at revision 0912d331 (main on 2026-10-15; Hub LFS sha256 and size)
P_BF16_URL=https://huggingface.co/LiquidAI/LFM2.5-24B-A2B-GGUF/resolve/0912d33141f77e10705345a6732bfd83f0252fdc/LFM2.5-24B-A2B-BF16.gguf
P_BF16_SIZE=47962094880
P_BF16_SHA=55103fda18def5210dafac2d1f1125afc93baf604dc24cf0edf9e9aee0d576ec
# the R1 table tool as reviewed (PR #59, commit e4b35e8)
P_TABLE_URL=https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/e4b35e84e0aa31ac70c37d6d343bfaf5bbb25c61/platforms/ventuno-q-16gb/npu-dev/tools/gguf_tensor_table.py
P_TABLE_SHA=1201119e27e3b5369bb6e532e1831cb5c5b356cc9fcbb4ba86dda1c982814cb5
REPO_URL=${REPO_URL:-$P_REPO_URL}; BF16_URL=${BF16_URL:-$P_BF16_URL}; BF16_SIZE=${BF16_SIZE:-$P_BF16_SIZE}
BF16_SHA=${BF16_SHA:-$P_BF16_SHA}; TABLE_URL=${TABLE_URL:-$P_TABLE_URL}; TABLE_SHA=${TABLE_SHA:-$P_TABLE_SHA}
TEST=no
[ "$REPO_URL$BF16_URL$BF16_SIZE$BF16_SHA$TABLE_URL$TABLE_SHA" = "$P_REPO_URL$P_BF16_URL$P_BF16_SIZE$P_BF16_SHA$P_TABLE_URL$P_TABLE_SHA" ] || TEST=yes
# CPU repack types of the K2 package on the board (preset -march=armv8.2a+fp16+dotprod, no i8mm; repack.cpp at
# af0579c78): they decide whether a tied output on the CPU is a separate copy (NPU-R')
BOARD_REPACK=Q4_0,Q4_K,Q5_K,Q6_K,IQ4_NL,MXFP4,Q8_0,Q1_0
# the Hexagon backend's repack types at af0579c78 (ggml-hexagon.cpp :318-324): an expert tensor must be one of them
NPU_TYPES=Q4_0,Q4_1,Q8_0,IQ4_NL,MXFP4,Q6_K,Q4_K,Q5_K,Q3_K,Q2_K
STAMP=$(date +%Y%m%d-%H%M%S)
W=$HOME/r1-k3-$STAMP; SRC=$W/llama.cpp; M=$W/models; E=$W/evidence; TAR=$HOME/r1-k3-evidence-$STAMP.tar.gz
M2=$M/LFM2.5-24B-A2B-M2-Q2_K-${COMMIT:0:8}.gguf; REF=$M/LFM2.5-24B-A2B-REF-Q8_0-${COMMIT:0:8}.gguf
die() { echo "FAILED: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

step "0. host"
[ "$(uname -m)" = x86_64 ] || die "this host is $(uname -m), not x86_64"
for c in git cmake c++ curl sha256sum python3 tar df; do command -v $c >/dev/null || die "$c not found"; done
[ ! -e "$W" ] && [ ! -e "$TAR" ] || die "$W or $TAR already exists; not touching it"
if [ -n "${BF16:-}" ]; then  # review of 702739a: resolved here, before any cd; every later step uses this file
  [ -f "$BF16" ] || die "BF16=$BF16 is not a file"
  BF16=$(realpath -e -- "$BF16") || die "cannot resolve BF16"
fi
DL=$HOME/r1-downloads; DLF=$DL/$(basename "$BF16_URL")
RESERVE=$((36 * 1024**3))   # REF + M2 + clone and build
if [ -n "${BF16:-}" ]; then src="existing copy $BF16"; rest=0
elif [ -f "$DLF" ]; then src="complete cached download $DLF"; rest=0
elif [ -f "$DLF.part" ]; then p=$(stat -c %s "$DLF.part"); src="partial cached download $DLF.part ($p bytes)"
  [ "$p" -le "$BF16_SIZE" ] || die "$DLF.part is $p bytes, more than $BF16_SIZE: delete it and rerun"; rest=$((BF16_SIZE - p))
else src="a new download"; rest=$BF16_SIZE; fi
need=$((RESERVE + rest)); free=$(df -B1 --output=avail "$HOME" | tail -1)
gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1024^3 }'; }
[ "$free" -ge "$need" ] || die "$(gib "$free") GiB free under $HOME, need $(gib "$need") (BF16 source: $src; $(gib "$rest") GiB still to download)"
mkdir -p "$W" "$M" "$E"; echo "host OK: $(gib "$free") GiB free, need $(gib "$need") (BF16 source: $src); test overrides: $TEST"

step "1. fresh clone at $COMMIT and a host CPU build of llama-quantize and llama-perplexity (log $E/host-build.log)"
git clone -q --no-checkout "$REPO_URL" "$SRC"
cd "$SRC"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch -q origin "$COMMIT"
git checkout -q --detach "$COMMIT"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || die "checkout is $(git rev-parse HEAD)"
[ -z "$(git status --porcelain)" ] || { git status --porcelain; die "fresh tree not clean"; }
{ cmake -S . -B build-host -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_OPENSSL=OFF && cmake --build build-host -j "$(nproc)" --target llama-quantize llama-perplexity; } \
  > "$E/host-build.log" 2>&1 || { tail -5 "$E/host-build.log"; die "host build failed; see $E/host-build.log"; }
Q=$SRC/build-host/bin/llama-quantize
[ -x "$Q" ] && [ -x "$SRC/build-host/bin/llama-perplexity" ] || die "llama-quantize or llama-perplexity not built"
# the host reference runtime's identity (review of 702739a): CMake's selected compilers and flags, and the sha256 of
# the two tools and of every shared library in the build's output (the libraries they load)
CC_=$(sed -n 's/^CMAKE_C_COMPILER:[A-Z]*=//p' build-host/CMakeCache.txt); CXX_=$(sed -n 's/^CMAKE_CXX_COMPILER:[A-Z]*=//p' build-host/CMakeCache.txt)
[ -n "$CC_" ] && [ -n "$CXX_" ] || die "no compiler in build-host/CMakeCache.txt"
{ cmake --version | head -1; echo "CMAKE_C_COMPILER $CC_: $("$CC_" --version | head -1)"; echo "CMAKE_CXX_COMPILER $CXX_: $("$CXX_" --version | head -1)"
  grep -E '^(CMAKE_BUILD_TYPE|CMAKE_C_FLAGS|CMAKE_CXX_FLAGS|GGML_NATIVE|BUILD_SHARED_LIBS)(_RELEASE)?:' build-host/CMakeCache.txt
  (cd build-host/bin && find . -maxdepth 1 -type f \( -name 'llama-quantize' -o -name 'llama-perplexity' -o -name '*.so*' \) -exec sha256sum {} + | sort -k2)
} > "$E/host-toolchain.txt"
grep -q '  ./llama-quantize$' "$E/host-toolchain.txt" || die "llama-quantize not hashed"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the build changed tracked files"
echo "build OK"; cat "$E/host-toolchain.txt"

step "2. table tool (pinned sha256)"
curl -fsSL "$TABLE_URL" -o "$E/gguf_tensor_table.py"
[ "$(sha "$E/gguf_tensor_table.py")" = "$TABLE_SHA" ] || die "gguf_tensor_table.py sha256 differs from $TABLE_SHA"
T() { python3 -I "$E/gguf_tensor_table.py" "$@"; }

step "3. BF16 source"
got=
if [ -n "${BF16:-}" ]; then
  B=$BF16; echo "using the existing $B (not downloaded)"
else
  mkdir -p "$DL"; B=$DLF
  if [ -f "$B" ]; then echo "reusing the earlier complete download $B (checked below)"
  else
    [ -f "$B.part" ] && echo "resuming $B.part ($(stat -c %s "$B.part") bytes)" || echo "downloading $BF16_URL"
    curl -fL --retry 5 --retry-delay 10 -C - -o "$B.part" "$BF16_URL" || die "download failed; rerun to resume $B.part"
    [ "$(stat -c %s "$B.part")" = "$BF16_SIZE" ] || die "$B.part is $(stat -c %s "$B.part") bytes, expected $BF16_SIZE; rerun to resume (or delete $B.part)"
    echo "hashing $B.part ..."; got=$(sha "$B.part")
    [ "$got" = "$BF16_SHA" ] || die "$B.part sha256 $got, expected $BF16_SHA: delete $B.part and rerun"
    mv "$B.part" "$B"   # promoted only after its size and sha256 passed
  fi
fi
if [ -z "$got" ]; then   # an existing or cached complete file (a fresh download was checked before promotion)
  [ "$(stat -c %s "$B")" = "$BF16_SIZE" ] || die "$B is $(stat -c %s "$B") bytes, expected $BF16_SIZE$([ "$B" = "$DLF" ] && echo ": delete $B and rerun")"
  echo "hashing $B ..."; got=$(sha "$B")
  [ "$got" = "$BF16_SHA" ] || die "$B sha256 $got, expected $BF16_SHA$([ "$B" = "$DLF" ] && echo ": delete $B and rerun")"
fi
T "$B" --sessions 1 > "$E/table-BF16.txt" || { tail -3 "$E/table-BF16.txt"; die "BF16 header check failed"; }
grep -q "architecture lfm2moe, block_count 40," "$E/table-BF16.txt" || die "BF16 header is not lfm2moe with 40 blocks"
echo "BF16 OK: $BF16_SIZE bytes, sha256 $got, lfm2moe, 40 blocks"

step "4. quantize (llama-quantize's default mix, no imatrix; logs in $E)"
"$Q" "$B" "$REF" Q8_0 "$(nproc)" > "$E/quantize-REF-Q8_0.log" 2>&1 || { tail -5 "$E/quantize-REF-Q8_0.log"; die "REF quantize failed"; }
"$Q" "$B" "$M2" Q2_K "$(nproc)" > "$E/quantize-M2-Q2_K.log" 2>&1 || { tail -5 "$E/quantize-M2-Q2_K.log"; die "M2 quantize failed"; }
[ -s "$REF" ] && [ -s "$M2" ] || die "quantize wrote no file"
echo "quantize OK"

step "5. tensor tables and the expert-type check"
check_experts() {  # <tsv>: every *_exps tensor of an NPU type, at least one
  python3 -I - "$1" "$NPU_TYPES" <<'PY'
import sys
tsv, ok_types = sys.argv[1], set(sys.argv[2].split(","))
rows = [l.rstrip("\n").split("\t") for l in open(tsv)][1:]
ex = [r for r in rows if "_exps." in r[0]]
bad = [f"{r[0]} {r[2]}" for r in ex if r[2] not in ok_types]
print(f"expert tensors: {len(ex)}, not an NPU type: {len(bad)} {bad[:5]}")
sys.exit(0 if ex and not bad else 1)
PY
}
for f in M2:"$M2" REF:"$REF"; do
  n=${f%%:*}; g=${f#*:}
  T "$g" --sessions 3,4 --ctx 16384 --tsv "$E/table-$n.tsv" > "$E/table-$n.txt" || { tail -3 "$E/table-$n.txt"; die "$n table failed"; }
  T "$g" --sessions 3,4 --ctx 16384 --rule release > "$E/table-$n-release.txt" || die "$n release table failed"
  T "$g" --sessions 3,4 --ctx 16384 --output-cpu --cpu-repack "$BOARD_REPACK" > "$E/table-$n-npu-r-prime.txt" || die "$n NPU-R' table failed"
  grep -q "architecture lfm2moe, block_count 40," "$E/table-$n.txt" || die "$n header is not lfm2moe with 40 blocks"
  check_experts "$E/table-$n.tsv" > "$E/experts-$n.txt" || { cat "$E/experts-$n.txt"; die "$n: an expert tensor is not an NPU type"; }
  echo "$n: $(cat "$E/experts-$n.txt")"
done

step "6. manifest and evidence"
{ echo "# K3 models (NPU dev plan K3, stage R1), $(date -Is)"
  [ $TEST = yes ] && echo "TEST RUN with overridden sources: NOT EVIDENCE"
  echo "host: $(uname -srm)"; sed 's/^/host toolchain: /' "$E/host-toolchain.txt"
  echo "llama.cpp: $COMMIT (master, fresh clone, clean); host build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF, targets llama-quantize llama-perplexity"
  echo "BF16 source: $BF16_URL"; echo "BF16: $B bytes $BF16_SIZE sha256 $BF16_SHA$([ -n "${BF16:-}" ] && echo ' (existing copy, checked)')"
  echo "table tool: $TABLE_URL sha256 $TABLE_SHA"
  echo "commands: llama-quantize <BF16> <REF> Q8_0 $(nproc); llama-quantize <BF16> <M2> Q2_K $(nproc)"
  for f in "$M2" "$REF"; do echo "$(basename "$f") bytes $(stat -c %s "$f") sha256 $(sha "$f")"; done
  for n in M2 REF; do
    echo "## $n (master rule unless stated; ctx 16,384; weights + KV only, before recurrent state and compute buffers)"
    sed 's/^/  /' "$E/experts-$n.txt"
    grep -E '^(TYPE|KV estimate|SESSIONS|EXPLICIT|RESULT)' "$E/table-$n.txt" | sed 's/^/  /'
    echo "  release rule:"; grep -E '^(SESSIONS|EXPLICIT|RESULT)' "$E/table-$n-release.txt" | sed 's/^/    /'
    echo "  NPU-R' (--output-cpu --cpu-repack $BOARD_REPACK):"; grep -E '^(TIED|SESSIONS|EXPLICIT)' "$E/table-$n-npu-r-prime.txt" | sed 's/^/    /'
  done
  echo "models stay on this host under $M; nothing copied to the board"
} > "$E/manifest.txt"
cat "$E/manifest.txt"
tar czf "$TAR" -C "$W" evidence
echo "evidence: $TAR ($(du -h "$TAR" | cut -f1)) sha256 $(sha "$TAR") (send it back; no model inside)"
echo; echo "DONE"
