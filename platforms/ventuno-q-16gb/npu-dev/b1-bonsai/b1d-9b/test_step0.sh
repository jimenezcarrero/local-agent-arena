#!/bin/bash
# tests for step0.sh's 0a gate (review of aff9f6d), with mocked llama-tokenize and llama-perplexity: a failed or
# malformed tokenization never reaches 0b (the mock perplexity leaves a marker when it is invoked).
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); fails=0
mkdir -p $T/c/bin; echo model > $T/m; echo text > $T/txt
ids() { python3 -c "print(list(range($1)))"; }
mock() { # mock <tokenizer output> <tokenizer exit>
  printf '%s\n' "$1" > $T/tok.out
  printf '#!/bin/bash\ncat %s\nexit %s\n' $T/tok.out "$2" > $T/c/bin/llama-tokenize
  printf '#!/bin/bash\ntouch %s/ppl-invoked\nexit 1\n' $T > $T/c/bin/llama-perplexity
  chmod +x $T/c/bin/*; rm -rf $T/ppl-invoked $T/w $T/e; }
case1() { local name=$1 pat=$2 ppl=$3; out=$(B1D9_S0_C=$T/c B1D9_S0_M=$T/m B1D9_S0_MSHA=$(sha256sum $T/m | cut -d' ' -f1) \
  B1D9_S0_TXT=$T/txt B1D9_S0_TXTSHA=$(sha256sum $T/txt | cut -d' ' -f1) B1D9_S0_W=$T/w B1D9_S0_E=$T/e bash $D/step0.sh 2>&1); rc=$?
  inv=no; [ -e $T/ppl-invoked ] && inv=yes
  if [ $rc = 1 ] && grep -q -- "$pat" <<<"$out" && [ $inv = $ppl ]; then echo "ok   $name"
  else echo "FAIL $name (rc $rc, 0b invoked $inv want $ppl, /$pat/)"; sed 's/^/     /' <<<"$out" | tail -5; fails=$((fails+1)); fi; }
mock "[]" 7;                       case1 tokenizer-exit-nonzero "STOP: 0a exit 7" no
mock "$(ids 20000)" 3;             case1 tokenizer-valid-ids-but-nonzero "STOP: 0a exit 3" no
mock "[1, 2, oops" 0;              case1 ids-malformed "STOP: 0a ids do not parse" no
mock "[1, 2.5, 3]" 0;              case1 ids-not-integers "STOP: 0a ids do not parse" no
mock "" 0;                         case1 ids-empty-output "STOP: 0a ids do not parse" no
mock "$(ids 10239)" 0;             case1 ids-truncated "fewer than 10,240" no
mock "$(ids 10240)" 0;             case1 ids-enough-reach-0b "STOP: 0b exit 1" yes
rm -f $T/ppl-invoked; mkdir -p $T/w; touch $T/w/cpu-ref-9b.kld; printf '#!/bin/bash\ntouch %s/ppl-invoked\n' $T > $T/c/bin/llama-perplexity
out=$(B1D9_S0_W=$T/w B1D9_S0_E=$T/e bash $D/step0.sh 2>&1); if grep -q "exists (it is never rewritten)" <<<"$out" && [ ! -e $T/ppl-invoked ]; then echo "ok   ref-exists"; else echo "FAIL ref-exists"; fails=$((fails+1)); fi
rm -rf $T; echo "failures: $fails"; exit $fails
