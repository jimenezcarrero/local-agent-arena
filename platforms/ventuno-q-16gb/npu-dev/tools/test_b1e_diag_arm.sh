#!/bin/bash
# tests for b1e_diag_arm.sh (dry mode, B1E_DRY=1): the per-executable FARF check (review of 67dab16), usage, REF and
# evidence-name refusals, and the composed commands. Uses the board's real model and text files (their hashes are
# fixed in the launcher); FARF, evidence and REF paths are temporary.
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); fails=0
FS_SRC=$HOME/npu-dev/farf/llama-server.farf
mkdir -p $T/farf $T/out; for n in llama-eval-callback llama-server llama-perplexity llama-bench; do cp $FS_SRC $T/farf/$n.farf; done
echo ref > $T/ref.kld; RS=$(sha256sum $T/ref.kld | cut -d' ' -f1)
# the dry command is printf %q output: unescape spaces, commas and semicolons and drop the trailing space
run() { B1E_DRY=1 B1E_FARF=$T/farf B1E_OUT=$T/out B1E_REF=$T/ref.kld bash $D/b1e_diag_arm.sh "$@" 2>&1 | sed 's/\\\([ ,;]\)/\1/g; s/ $//'; return ${PIPESTATUS[0]}; }
case1() { local name=$1 want=$2 pat=$3; shift 3; out=$(run "$@"); rc=$?
  if [ $rc = $want ] && grep -q -- "$pat" <<<"$out"; then echo "ok   $name"; else echo "FAIL $name (rc $rc want $want, /$pat/)"; sed 's/^/     /' <<<"$out" | cut -c1-300; fails=$((fails+1)); fi; }
case1 s1-composes 0 "llama-eval-callback -m .*Ternary-Bonsai-2-4B-Q2_0.gguf -p The capital of France is -c 256 -b 256 -ub 256 -t 8 -fa on -lv 5 -ngl 999 --device HTP0:0\$" s1
case1 s1r-composes 0 "--run b1e-s1r " s1r
case1 s2-composes 0 "--device HTP0:0,HTP0:1 -ts 16,17\$" s2
case1 s2-peaks 0 "declared peaks 1350,1500" s2
case1 s1-farf-on-path 0 "ADSP_LIBRARY_PATH=$T/farf;/home" s1
case1 nh2-composes 0 "llama-perplexity -m .*NeoHorse-1-4B-q4_0-pure.gguf --kl-divergence-base $T/ref.kld --kl-divergence -c 256 -b 256 -ub 256 --chunks 16 -t 8 -fa on -lv 5 -ngl 99 --device HTP0:0,HTP0:1\$" nh2 $RS
case1 usage 2 "usage" bad
case1 nh2-needs-ref 2 "nh2 needs REF" nh2
case1 s1-takes-no-ref 2 "takes no REF" s1 $RS
case1 nh2-ref-mismatch 1 "REF mismatch" nh2 $(echo x | sha256sum | cut -d' ' -f1)
mv $T/farf/llama-eval-callback.farf $T/cb.farf
case1 callback-farf-missing 1 "farf llama-eval-callback missing" s1
case1 nh2-without-callback-farf 0 "--run b1e-nh2 " nh2 $RS
echo 0x00 > $T/farf/llama-eval-callback.farf
case1 callback-farf-wrong-mask 1 "farf llama-eval-callback missing or not the campaign's" s2
mv $T/cb.farf $T/farf/llama-eval-callback.farf; echo 0x00 > $T/farf/llama-perplexity.farf
case1 perplexity-farf-wrong-mask 1 "farf llama-perplexity" nh2 $RS
cp $FS_SRC $T/farf/llama-perplexity.farf; mkdir $T/out/b1e-s1
case1 evidence-exists 1 "exists (every run is new)" s1
rm -rf $T; echo "failures: $fails"; exit $fails
