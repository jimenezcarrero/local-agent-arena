#!/bin/bash
# mocked tests for v0p_diag.sh (D141): fake run_route/run_v0e/kernel audit/library check under a temp dir; checks the
# exit code, the sequence of actions and the server/workload settings of each step. Refuses to run while a
# llama-server is up.
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
FAKE='#!/bin/bash
lab=$1; ph=${PHASE:-$2}; o=$BR/v0/$ph/$lab; mkdir -p $o; k=probe; case $lab in v0p-D*) k=${lab#v0p-};; esac
echo "$k" >> $T/calls; [ $k != probe ] && echo "$k ${PI_N:-} ${REPLAY_N:-} ${REPLAY_REQ:-none} SHA=${REPLAY_SHA:-none} CAP=${CAP_DIR:-} :: $*" >> $T/args
m=$(head -1 $T/mode-$k 2>/dev/null); m=${m:-pass}; sed -i 1d $T/mode-$k 2>/dev/null
echo pass > $o/health-verdict.txt; : > $o/server.log; echo pass > $o/kernel-audit.txt
case $m in
  pass|nosummary) printf "t server pid 4242\nt RESULT PASS (workload, health: pass, kernel evidence)\n" > $o/run.txt
        echo "{\"req\": 1}" > $o/first-request.json
        echo "RESULT $lab: first-reply tool calls 3/20 (no_tool 17, timeout 0, error 0)" > $o/workload.txt
        [ $m = pass ] && echo "WORKLOAD $lab: pi results ${PI_N}/${PI_N}, replays 20/20, request sha256 $(printf %064d 7)" >> $o/workload.txt; exit 0;;
  hang) echo NPU-WATCHDOG >> $WD_LOG; echo "t RESULT FAIL: workload=5" > $o/run.txt; exit 1;;
  evidence) echo "t RESULT FAIL: workload=1" > $o/run.txt; exit 1;;
esac'
case1() { local name=$1 want_rc=$2 want_seq=$3; shift 3
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR
  echo "$FAKE" > $T/run.sh; printf '#!/bin/bash\necho pass; exit 0\n' > $T/ka.sh; chmod +x $T/run.sh $T/ka.sh
  printf '#!/bin/bash\nn=$(( $(cat $T/hc 2>/dev/null || echo 0) + 1 )); echo $n > $T/hc\n[ -n "${LIBFAIL_AT:-}" ] && [ $n -ge $LIBFAIL_AT ] && { echo "FAILED htp-retry"; exit 1; }; echo "OK htp-retry"\n' > $T/hc.sh; chmod +x $T/hc.sh
  echo q4km > $T/q4km.gguf; local qsha=$(sha256sum $T/q4km.gguf | cut -d' ' -f1)
  local kv; for kv in "$@"; do case $kv in mode-*) echo "${kv#*=}" | tr , '\n' > $T/${kv%%=*};; noq4km) rm $T/q4km.gguf;; stale) mkdir -p $BR/v0/v0p-pi/v0p-D1;; d1done) mkdir -p $BR/v0/v0p-pi/v0p-D1; echo '{"req": 1}' > $BR/v0/v0p-pi/v0p-D1/first-request.json; sha256sum $BR/v0/v0p-pi/v0p-D1/first-request.json | cut -d' ' -f1 > $BR/v0/v0p-pi/v0p-D1/first-request.sha256;; esac; done
  # the driver pins the Q4_K_M sha256; the test points QKM at a file and patches the pin in a copy of the driver
  sed "s/QKM_SHA=7da8ac62[0-9a-f]*/QKM_SHA=$qsha/" ~/v0/v0p_diag.sh > $T/drv.sh
  local xe=(); for kv in "$@"; do case $kv in LIBFAIL_AT=*|STEPS=*) xe+=("$kv");; esac; done
  env RUN_ROUTE=$T/run.sh RUN_V0E=$T/run.sh KAUDIT=$T/ka.sh PROBE_WAIT=0 STEP_PAUSE=0 CHECK_PROC=true HTPR_CHECK=$T/hc.sh QKM=$T/q4km.gguf \
      "${xe[@]}" bash $T/drv.sh > $T/out.txt 2>&1; local rc=$?
  local seq=$(paste -sd' ' $T/calls 2>/dev/null)
  if [ $rc = $want_rc ] && [ "$seq" = "$want_seq" ]; then echo "ok   $name (rc $rc: $seq)"
  else echo "FAIL $name (rc $rc want $want_rc; seq '$seq' want '$want_seq')"; sed 's/^/     /' $T/out.txt | tail -6; fails=$((fails+1)); fi
  if [ $name = hang-plus-library-change-keeps-fault ]; then grep -q "v0p-D1 HANG" $BR/v0/v0p-pi/faults.txt 2>/dev/null && grep -q "NOTE v0p-D1: post-run library check FAILED" $BR/v0/v0d/v0p-pi-status.txt \
      && echo "ok   fault recorded and library mismatch kept as evidence" || { echo "FAIL fault/library evidence"; fails=$((fails+1)); }; fi
  if [ $name = d5-gdn-hvx ]; then grep -q "^D5 10 20 $BR/v0/v0p-pi/v0p-D1/first-request.json SHA=[0-9a-f]\{64\} CAP=$BR/v0/v0p-pi/v0p-D5/capture :: v0p-D5 .*v0p_serve.sh env GGML_HEXAGON_GDN_SELECT=1 env .*ADSP_LIBRARY_PATH=/home/arduino/v0/farf;/home/arduino/v0/htp-retry;.*-c 32768 .*--port 8090 .*--ctx-checkpoints 0$" $T/args \
      && echo "ok   D5 settings: D1's runtime and request plus GDN_SELECT=1, pi 10, replay 20" || { echo "FAIL D5 settings: $(cat $T/args)"; fails=$((fails+1)); }; fi
  if [ $name = all-pass ]; then a=$T/args
    chk() { grep -q -- "$2" <(grep "^$1 " $a) && echo "ok   $1 settings: $3" || { echo "FAIL $1 settings: $3"; fails=$((fails+1)); }; }
    chk D1 "^D1 10 20 none SHA=none CAP=$BR/v0/v0p-pi/v0p-D1/capture :: v0p-D1 /home/arduino/v0/v0p_workload.sh -- bash /home/arduino/v0/v0p_serve.sh env .*ADSP_LIBRARY_PATH=/home/arduino/v0/farf;/home/arduino/v0/htp-retry;" "pi 10, replay 20, capture dir, patched library via the wrapper"
    chk D1 "--port 8090 " "server behind the proxy"
    chk D2 "^D2 10 20 $BR/v0/v0p-pi/v0p-D1/first-request.json SHA=$(echo '{"req": 1}' | sha256sum | cut -d' ' -f1) .*--presence-penalty 1.5 --repeat-penalty 1.0$" "vendor profile, D1's request"
    chk D3 "^D3 0 20 $BR/v0/v0p-pi/v0p-D1/first-request.json .*--device none -ngl 0 .*q40/NeoHorse-1-4B-q4_0-pure.gguf$" "CPU, same Q4_0 file"
    chk D4 "^D4 0 20 .*--device none -ngl 0 .* -m $T/q4km.gguf$" "CPU, Q4_K_M file"
    [ "$(cat $T/hc)" = 5 ] && echo "ok   library checked at start and before/after both NPU steps" || { echo "FAIL library checks: $(cat $T/hc)"; fails=$((fails+1)); }
  fi
  rm -rf $T; }
case1 all-pass 0 "probe D1 probe D2 D3 D4"
case1 d1-hang-stops 3 "probe D1 probe" mode-D1=hang
case1 d2-baseline-hang-stops 3 "probe D1 probe probe" mode-probe=pass,hang,pass
case1 d3-evidence-stops 2 "probe D1 probe D2 D3" mode-D3=evidence
case1 library-wrong-at-start 6 "" LIBFAIL_AT=1
case1 library-changes-during-d1 2 "probe D1" LIBFAIL_AT=3
case1 q4km-missing 6 "" noq4km
case1 cpu-steps-only 0 "D3 D4" "STEPS=D3 D4" d1done
case1 cpu-steps-without-d1-stops 2 "" "STEPS=D3 D4"
case1 d5-gdn-hvx 0 "probe D5" "STEPS=D5" d1done
case1 missing-workload-summary-stops 2 "probe D1" mode-D1=nosummary
case1 stale-run-directory-stops 2 "" stale
case1 hang-plus-library-change-keeps-fault 3 "probe D1 probe" mode-D1=hang LIBFAIL_AT=3
echo "failures: $fails"; exit $fails
