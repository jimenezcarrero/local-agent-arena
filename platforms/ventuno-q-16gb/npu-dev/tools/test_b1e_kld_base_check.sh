#!/bin/bash
# tests for b1e_kld_base_check.py on small synthetic bases (n_ctx 8, n_vocab 5, n_chunk 2: 3 rows per chunk, 10 uint16
# per row) in the ff5a2337 layout
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); fails=0
mk() { python3 - "$@" <<'EOF'
import struct, sys
out, ctx, voc, chunk, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
nv = 2 * ((voc + 1) // 2) + 4; rows = ctx - 1 - ctx // 2
b = bytearray(b"_logits_" if mode != "magic" else b"_logitz_")
b += struct.pack("<Iii", ctx, voc, chunk)
b += struct.pack(f"<{ctx*chunk}i", *range(100, 100 + ctx * chunk))
for r in range(chunk * rows):
    sc = float("nan") if (mode == "nan" and r == 4) else (0.0 if (mode == "zero" and r == 0) else 0.01)
    b += struct.pack("<ff", sc, -16.0) + bytes(2 * nv - 8)
if mode == "short": b = b[:-2]
open(out, "wb").write(bytes(b))
EOF
}
python3 -c "print(list(range(100, 140)))" > $T/ids; python3 -c "print(list(range(100, 115)) + [7] + list(range(116, 140)))" > $T/ids-bad
python3 -c "print(list(range(100, 110)))" > $T/ids-few
case1() { local name=$1 want=$2 pat=$3; shift 3; out=$(python3 -I $D/b1e_kld_base_check.py "$@" 2>&1); rc=$?
  if [ $rc = $want ] && grep -q -- "$pat" <<<"$out"; then echo "ok   $name"; else echo "FAIL $name (rc $rc want $want, /$pat/)"; sed 's/^/     /' <<<"$out"; fails=$((fails+1)); fi; }
A="--n-ctx 8 --n-vocab 5 --n-chunk 2"
mk $T/ok 8 5 2 ok; mk $T/magic 8 5 2 magic; mk $T/short 8 5 2 short; mk $T/nan 8 5 2 nan; mk $T/zero 8 5 2 zero; mk $T/hdr 8 5 1 ok
case1 valid 0 "RESULT VALID" $T/ok $T/ids $A
case1 scored-positions 0 "scored positions 6 (2 chunks x 3)" $T/ok $T/ids $A
case1 token-sha 0 "tokens sha256 [0-9a-f]\{64\}" $T/ok $T/ids $A
case1 magic 3 "no _logits_ magic" $T/magic $T/ids $A
case1 short-file 3 "size .* expected" $T/short $T/ids $A
case1 header-chunks 3 "header (8, 5, 1) is not the declared (8, 5, 2)" $T/hdr $T/ids $A
case1 tokens-differ 3 "differ from the ids at position 15" $T/ok $T/ids-bad $A
case1 too-few-ids 3 "fewer than 16" $T/ok $T/ids-few $A
case1 row-nan 3 "row 4: scale nan" $T/nan $T/ids $A
case1 row-zero-scale 3 "row 0: scale 0.0" $T/zero $T/ids $A
case1 missing-file 3 "cannot open base" $T/none $T/ids $A
case1 usage 2 "" $T/ok $T/ids
rm -rf $T; echo "failures: $fails"; exit $fails
