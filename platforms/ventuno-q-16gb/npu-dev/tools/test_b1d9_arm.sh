#!/bin/bash
# tests for b1d9_arm.sh (dry mode, B1D9_DRY=1): usage, the per-executable FARF check, REF, disk and evidence-name
# refusals, and the composed commands. Uses the board's real model file (its hash is fixed in the launcher); FARF,
# evidence and REF paths are temporary.
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); fails=0
FS_SRC=$HOME/npu-dev/farf/llama-server.farf
mkdir -p $T/farf $T/out; for n in llama-server llama-perplexity llama-bench; do cp $FS_SRC $T/farf/$n.farf; done
echo ref > $T/ref.kld; RS=$(sha256sum $T/ref.kld | cut -d' ' -f1)
# the dry command is printf %q output: unescape spaces, commas, semicolons, quotes, braces and backslashes
run() { B1D9_DRY=1 B1D9_FARF=$T/farf B1D9_OUT=$T/out B1D9_REF=$T/ref.kld bash $D/b1d9_arm.sh "$@" 2>&1 \
  | sed 's/\\\([] ,;{}":[\\]\)/\1/g; s/ $//'; return ${PIPESTATUS[0]}; }
case1() { local name=$1 want=$2 pat=$3; shift 3; out=$(run "$@"); rc=$?
  if [ $rc = $want ] && grep -q -- "$pat" <<<"$out"; then echo "ok   $name"; else echo "FAIL $name (rc $rc want $want, /$pat/)"; sed 's/^/     /' <<<"$out" | cut -c1-300; fails=$((fails+1)); fi; }
DV='--device HTP0:0,HTP0:1 -ts 18,15 -ot token_embd\\.weight=CPU -fa on'
case1 parity-composes 0 "llama-perplexity -m .*Ternary-Bonsai-2-9B-Q2_0.gguf --kl-divergence-base $T/ref.kld --kl-divergence -c 1024 -b 1024 -ub 512 --chunks 10 -t 8 -lv 5 -ngl 999 $DV\$" parity $RS
case1 parity-peaks 0 "declared peaks 1350,1950" parity $RS
case1 parity-wrapper 0 "--run 9b-parity --timeout 5400 .*--declared-peak-mib 1350,1950 --declared-board-mib 5500 " parity $RS
case1 think-composes 0 "b1_t5_payload.sh --speed 1024,8192,16384,28672 --min-pass 18 $T/out/9b-think/payload 18090 900 bonsai9b-think 900 -- .*llama-server -m .*-c 32768 -np 1 --cache-ram 0 --slot-save-path $T/out/9b-think-slots --jinja -b 2048 -ub 512 -ngl 999 $DV -lv 5 --no-webui\$" think
case1 think-wrapper 0 "--run 9b-think --timeout 7200 .*--declared-peak-mib 1900,1950 --declared-board-mib 5100 " think
case1 nothink-composes 0 "b1_t5_payload.sh $T/out/9b-nothink/payload 18090 900 bonsai9b-nothink 900 -- .*--jinja --chat-template-kwargs {\"enable_thinking\":false} -b 2048" nothink
case1 nothink-timeout 0 "--run 9b-nothink --timeout 3600 " nothink
case1 farf-on-path 0 "ADSP_LIBRARY_PATH=$T/farf;/home" think
case1 usage 2 "usage" bad
case1 parity-needs-ref 2 "parity needs REF" parity
case1 think-takes-no-ref 2 "takes no REF" think $RS
case1 ref-mismatch 1 "REF mismatch" parity $(echo x | sha256sum | cut -d' ' -f1)
echo 0x00 > $T/farf/llama-perplexity.farf
case1 perplexity-farf-wrong 1 "farf llama-perplexity missing or not the campaign's" parity $RS
case1 server-farf-checks-all 1 "farf llama-perplexity" think
cp $FS_SRC $T/farf/llama-perplexity.farf; rm $T/farf/llama-server.farf
case1 server-farf-missing 1 "farf llama-server missing" nothink
cp $FS_SRC $T/farf/llama-server.farf
B1D9_DISK_MIB=99999999 case1 low-disk 1 "below 99999999 MiB" think
mkdir -p $T/htpr; echo retry > $T/htpr/libggml-htp-v75.so; HS=$(sha256sum $T/htpr/libggml-htp-v75.so | cut -d' ' -f1)
export B1D9_HTPR=$T/htpr
case1 rparity-composes 0 "--run 9b-rparity --timeout 5400 --expect-dsp yes --dsp-retry-patched yes --floor-mib 1536 .*--hash $T/htpr/libggml-htp-v75.so .*ADSP_LIBRARY_PATH=$T/farf;$T/htpr;/home.*llama-perplexity -m .*--kl-divergence-base $T/ref.kld --kl-divergence -c 1024 -b 1024 -ub 512 --chunks 10 -t 8 -lv 5 -ngl 999 $DV\$" rparity $RS $HS
case1 parity-no-retry-flag 0 "--run 9b-parity --timeout 5400 --expect-dsp yes --floor-mib 1536 " parity $RS
case1 parity-unpatched-path 0 "ADSP_LIBRARY_PATH=$T/farf;/home" parity $RS
case1 rparity-needs-lib-sha 2 "rparity needs" rparity $RS
case1 parity-takes-no-lib 2 "takes no retry library" parity $RS $HS
case1 rparity-lib-mismatch 1 "retry library mismatch" rparity $RS $(echo y | sha256sum | cut -d' ' -f1)
case1 rparity-ref-mismatch 1 "REF mismatch" rparity $(echo x | sha256sum | cut -d' ' -f1) $HS
unset B1D9_HTPR
mkdir $T/out/9b-think; case1 evidence-exists 1 "exists (every run is new)" think
mkdir $T/out/9b-nothink-slots; case1 slots-exist 1 "slots exists" nothink
rm -rf $T; echo "failures: $fails"; exit $fails
