#!/bin/bash
# B1d-9B Step 0 (CPU only, b1-bonsai/b1d-9b/SPEC.txt): the 9B's CPU reference for the parity run, as B1c-4B Step 0c
# with B1e's base checks: 0a an independent tokenization, 0b the base, 0c b1e_kld_base_check.py, 0d the self-check.
# Runs from the merged checkout; fails closed; never rewrites the base. Tests only (test_step0.sh, mocked binaries):
# B1D9_S0_C, B1D9_S0_M, B1D9_S0_MSHA, B1D9_S0_TXT, B1D9_S0_TXTSHA, B1D9_S0_W and B1D9_S0_E replace the CPU build, the
# model and its sha256, the text and its sha256, the reference directory and the evidence directory.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
C=${B1D9_S0_C:-$HOME/npu-dev/b1/llama.cpp/build-cpu}
M=${B1D9_S0_M:-$HOME/npu-dev/b1/models/Ternary-Bonsai-2-9B-Q2_0.gguf}
MSHA=${B1D9_S0_MSHA:-1f884aa56aacd2bbbb2e4b7abaead2b1102b74a9c75a23fc33dab916813a384d}
TXT=${B1D9_S0_TXT:-$HOME/npu-dev/b1/b1c-4b/step0/text/wikitext-2-raw/wiki.test.raw}
TXTSHA=${B1D9_S0_TXTSHA:-173c87a53759e0201f33e0ccf978e510c2042d7f2cb78229d9a50d79b9e7dd08}
W=${B1D9_S0_W:-$HOME/npu-dev/b1/b1d-9b/step0}; REF=$W/cpu-ref-9b.kld; K4=f2259ac78d19f170df2883f216f01d7db853d25cd693b4b7a3e0b17e87243736
E=${B1D9_S0_E:-$HOME/bench-runs/npu-dev/b1/9b-step0-$(date +%Y%m%d-%H%M%S)}; mkdir -p "$E" "$W" || exit 1
log() { echo "$(date -Iseconds) $*" | tee -a "$E/status.txt"; }
die() { log "STOP: $*"; exit 1; }
[ -e "$REF" ] && die "$REF exists (it is never rewritten)"
git -C "$R" rev-parse HEAD > "$E/spec-commit.txt"
log "start; evidence $E; free disk $(df -BM --output=avail ~ | tail -1)"
echo "$MSHA  $M" | sha256sum -c - >> "$E/status.txt" 2>&1 || die "model sha256"
echo "$TXTSHA  $TXT" | sha256sum -c - >> "$E/status.txt" 2>&1 || die "text sha256"
(cd "$C/bin" && sha256sum llama-perplexity llama-tokenize lib*.so*) > "$E/binaries.sha256"
cp "$R/tools/r1_t7_compare.cpp" "$R/tools/b1e_kld_base_check.py" "$E/" \
  && c++ -O2 -std=c++17 -o "$E/r1_t7_compare" "$E/r1_t7_compare.cpp" || die "comparator build"
sha256sum "$E/r1_t7_compare.cpp" "$E/b1e_kld_base_check.py" > "$E/tools.sha256"
# 0a (review of aff9f6d: the tokenizer's status and the ids' parse and count are each checked before 0b)
"$C/bin/llama-tokenize" -m "$M" -f "$TXT" --ids --no-parse-special --log-disable > "$E/ids-9b.txt" 2> "$E/ids-9b.err"
rc=$?; log "0a exit $rc"; [ $rc = 0 ] || die "0a exit $rc"
N=$(python3 -I -c 'import ast,sys
v=ast.literal_eval(open(sys.argv[1]).read().strip())
assert isinstance(v, list) and all(type(x) is int for x in v)
print(len(v))' "$E/ids-9b.txt" 2>> "$E/ids-9b.err") || die "0a ids do not parse as a list of integers"
log "0a ids $N"; [ "$N" -ge 10240 ] || die "0a: $N ids, fewer than 10,240 (10 chunks x 1,024)"
# 0b
log "0b base"
"$C/bin/llama-perplexity" -m "$M" -f "$TXT" -c 1024 -b 1024 -ub 512 --chunks 10 -t 8 -fa on --kl-divergence-base "$REF" \
  > "$E/ppl-ref-base.log" 2>&1; rc=$?; log "0b exit $rc"; [ $rc = 0 ] || die "0b exit $rc"
grep -q '\[10\]' "$E/ppl-ref-base.log" || die "base log does not show chunk 10"
grep -q "Final estimate" "$E/ppl-ref-base.log" || die "no final estimate"
grep "Final estimate" "$E/ppl-ref-base.log" | tee -a "$E/status.txt" | grep -qiE "nan|inf" && die "non-finite final estimate"
# 0c
python3 -I "$E/b1e_kld_base_check.py" "$REF" "$E/ids-9b.txt" --n-ctx 1024 --n-vocab 248320 --n-chunk 10 > "$E/base-check.txt" 2>&1
rc=$?; cat "$E/base-check.txt" >> "$E/status.txt"; [ $rc = 0 ] || die "0c exit $rc"
KSHA=$(sed -n 's/^tokens sha256 \([0-9a-f]\{64\}\)$/\1/p' "$E/base-check.txt"); [ -n "$KSHA" ] || die "0c printed no token sha256"
grep -q '^scored positions 5110 ' "$E/base-check.txt" || die "0c: not 5,110 scored positions"
# 0d
"$E/r1_t7_compare" "$REF" "$REF" "$KSHA" > "$E/ref-selfcheck.txt" 2>&1; rc=$?
cat "$E/ref-selfcheck.txt" >> "$E/status.txt"; [ $rc = 0 ] || die "0d exit $rc"
sha256sum "$REF" | tee "$E/cpu-ref-9b.kld.sha256" >> "$E/status.txt"
[ "$KSHA" = "$K4" ] && log "stored tokens equal to the 4B's K (f2259ac7...)" || log "stored tokens differ from the 4B's K (f2259ac7...): recorded"
log "done; free disk $(df -BM --output=avail ~ | tail -1)"
