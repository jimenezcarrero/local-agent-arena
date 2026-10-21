#!/bin/bash
# mocked tests for the v0d_admit.sh entry point (Codex review of #47, 22:08Z): H2 checks its helper before any load and
# its first NPU action is the restart (no plain initial probe); other sets keep the initial probe. Fake run_route,
# memfloor, process check and helper; everything under a temp dir. Refuses to run while a llama-server is up.
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
case1() { local name=$1 set=$2 want_rc=$3 want_first=$4; shift 4
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR
  # fake runner: PASS with a 16384 probe RESULT line; LOADFAIL_LAB=<label> makes that label's first run a clean load
  # failure (D138: the admitted step is then read from <label>-retry)
  printf '#!/bin/bash\nlab=$1; o=$BR/v0/$2/$lab; [ -n "${PHASE:-}" ] && o=$BR/v0/$PHASE/$lab; mkdir -p $o; echo "$lab" >> $T/calls; echo "$lab $*" >> $T/cmds\necho pass > $o/health-verdict.txt; : > $o/server.log\nif [ "$lab" = "${LOADFAIL_LAB:-}" ]; then printf "t SERVER EXITED before ready\\nt RESULT FAIL: speed=4\\n" > $o/run.txt; echo "ggml-hex: HTP0:1 buffer mapping failed" > $o/server.log; exit 1; fi\necho "t RESULT PASS (speed, health: pass, kernel evidence)" > $o/run.txt; echo "RESULT $lab: depth=16384 prompt_tokens=18000 ttft=1s prefill_tps=300.0 gen_tokens=128 decode_tps=8.00 method=usage" > $o/probe.txt; exit 0\n' > $T/run.sh
  printf '#!/bin/bash\nv="pass|0"; echo "${v%%|*}"; exit 0\n' > $T/ka.sh; printf 'import os, sys\nopen(os.environ["T"] + "/caps", "a").write(sys.argv[2] + "\\n")\nsys.exit(0)\n' > $T/mem.py
  printf '#!/bin/bash\necho PRELOAD >> $T/calls; echo OK restart\n' > $T/pre.sh; chmod +x $T/run.sh $T/ka.sh $T/pre.sh
  # AR (D137): fake library check (ok, fail, or fail from its Nth call: lib-fail-at) and fake 16K gate (exit from gate-rc)
  printf '#!/bin/bash\nn=$(( $(cat $T/hc 2>/dev/null || echo 0) + 1 )); echo $n > $T/hc\nif [ -n "${LIBFAIL_AT:-}" ] && [ $n -ge $LIBFAIL_AT ]; then echo "FAILED htp-retry sha256"; exit 1; fi\necho "OK htp-retry sha256"\n' > $T/hcheck.sh
  printf '#!/bin/bash\necho "$*" > $T/gate-args; case ${GATE_RC:-0} in 0) echo "GATE $2: PASS median 16K prefill 317.4";; 3) echo "GATE $2: FAIL median 16K prefill 120.0";; *) echo "GATE $2: MISSING";; esac; exit ${GATE_RC:-0}\n' > $T/gate.sh
  # D178: fake B4 identity check (ok, or fail from its Nth call: B4FAIL_AT), counted in $T/b4c
  printf '#!/bin/bash\nn=$(( $(cat $T/b4c 2>/dev/null || echo 0) + 1 )); echo $n > $T/b4c\nif [ -n "${B4FAIL_AT:-}" ] && [ $n -ge $B4FAIL_AT ]; then echo "FAILED B4 identity: model sha256"; exit 1; fi\necho "OK B4 package PASS"\n' > $T/b4check.sh
  # D180: fake B9 identity check (B9FAIL_AT), counted in $T/b9c
  printf '#!/bin/bash\nn=$(( $(cat $T/b9c 2>/dev/null || echo 0) + 1 )); echo $n > $T/b9c\nif [ -n "${B9FAIL_AT:-}" ] && [ $n -ge $B9FAIL_AT ]; then echo "FAILED B9 identity: model sha256"; exit 1; fi\necho "OK B9 package PASS"\n' > $T/b9check.sh
  # D178 (review of 4d278e0): fake campaign package check for B4's baseline (fail from its Nth call: PKGFAIL_AT), in $T/pc
  printf '#!/bin/bash\nn=$(( $(cat $T/pc 2>/dev/null || echo 0) + 1 )); echo $n > $T/pc\nif [ -n "${PKGFAIL_AT:-}" ] && [ $n -ge $PKGFAIL_AT ]; then printf "FAIL file lib/libllama.so sha256\\nRESULT pkg-identity: FAIL (1 mismatch)\\n"; exit 1; fi\necho "RESULT pkg-identity: PASS (133 files)"\n' > $T/pcheck.sh
  chmod +x $T/hcheck.sh $T/gate.sh $T/b4check.sh $T/b9check.sh $T/pcheck.sh
  env RUN_ROUTE=$T/run.sh RUN_V0C=$T/run.sh MEMFLOOR=$T/mem.py KAUDIT=$T/ka.sh PROBE_WAIT=0 SET_PAUSE=0 CHECK_PROC=true \
      PRE_CMD=$T/pre.sh HTPR_CHECK=$T/hcheck.sh B4_CHECK=$T/b4check.sh B9_CHECK=$T/b9check.sh CAMP_PKG_CHECK=$T/pcheck.sh GATE=$T/gate.sh "$@" bash ~/v0/v0d_admit.sh $set > /dev/null 2>&1; local rc=$?
  local first=$(head -1 $T/calls 2>/dev/null); first=${first%%-*}
  if [ $rc = $want_rc ] && [ "${first:-none}" = "$want_first" ]; then echo "ok   $name (rc $rc, first action: ${first:-none})"
  else echo "FAIL $name (rc $rc want $want_rc; first ${first:-none} want $want_first)"; sed 's/^/     /' $T/calls 2>/dev/null; fails=$((fails+1)); fi
  case $name in ar-load-retry-real-gate) grep -q "GATE AR: PASS .*AR-s1-r2-retry 18000 tok" $BR/v0/v0d/v0d-admit-AR-status.txt \
      || { echo "FAIL ar-load-retry-real-gate: gate did not read AR-s1-r2-retry"; fails=$((fails+1)); };; esac
  case $name in ar-pass) grep -q "GATE AR: PASS" $BR/v0/v0d/v0d-admit-AR-status.txt && [ "$(cat $T/gate-args)" = "$BR/v0/v0d-admit-AR AR 1" ] \
      && [ "$(cat $T/hc)" = 7 ] || { echo "FAIL ar-pass: gate line, gate arguments or 7 library checks (start, 5 steps, after)"; fails=$((fails+1)); };; esac
  # D157: A32 = AR's command with -ngl 32 and --cache-ram 5120, memfloor at 5120, its own gate and status
  case $name in a32-pass) s=$BR/v0/v0d/v0d-admit-A32-status.txt; c=$(grep '^A32-s1-r1 ' $T/cmds)
      grep -q "GATE A32: PASS" $s && [ "$(cat $T/gate-args)" = "$BR/v0/v0d-admit-A32 A32 1" ] && [ "$(cat $T/hc)" = 7 ] \
      && [[ "$c" == *"ADSP_LIBRARY_PATH=$HOME/v0/farf;$HOME/v0/htp-retry;"*" -c 40960 --cache-ram 5120 "*" --device HTP0:0,HTP0:1 -ngl 32 --ctx-checkpoints 0"* ]] \
      && [[ "$c" != *"-ngl 99"* ]] && [ ! -e $T/pc ] && ! grep -q PRE-BASE $s && [ "$(sort -u $T/caps)" = 5120 ] && [ "$(wc -l < $T/caps)" = 5 ] \
      && [[ "$c" == "A32-s1-r1 A32-s1-r1 v0d-admit-A32 --depths 512,8192,16384,32768 --nctx 40960 -- "* ]] \
      || { echo "FAIL a32-pass: gate line/arguments, 7 library checks, the A32 command, its frozen depths/nctx or memfloor at 5120"; echo "     $c"; fails=$((fails+1)); };; esac
  # D178: B4's command, its D2 branch's depths and nctx on warm-up and r1-r3 only, the campaign's probes unchanged
  case $name in b4-pass-a|b4-pass-b) s=$BR/v0/v0d/v0d-admit-B4-status.txt
      if [ $name = b4-pass-a ]; then win=32768; dep="512,8192,16384,28672"; nc=32768; else win=40960; dep="512,8192,16384,32768"; nc=40960; fi
      ok=1; for st in warmup r1 r2 r3; do c=$(grep "^B4-s1-$st " $T/cmds)
        [[ "$c" == "B4-s1-$st B4-s1-$st v0d-admit-B4 --depths $dep --nctx $nc -- env LD_LIBRARY_PATH=$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337/lib ADSP_LIBRARY_PATH=$HOME/npu-dev/farf;$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337/lib GGML_HEXAGON_DEVICES=HTP0:0 GGML_HEXAGON_NHMX=1 "*"/llama-server -m $HOME/npu-dev/b1/models/Ternary-Bonsai-2-4B-Q2_0.gguf -c $win --cache-ram 5120 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0 -ngl 999 -np 1 -fa on -ctk q8_0 -ctv q8_0 --jinja --ctx-checkpoints 0" ]] || { ok=0; echo "     $st: $c"; }
      done
      c=$(grep "^B4-s1-tools " $T/cmds); [[ "$c" == *" -c $win "*"-np 1 "* ]] || { ok=0; echo "     tools: $c"; }
      pr=$(grep '^probe-' $T/cmds | grep -vc -- '--depths 512 --nctx 40960 -- env LD_LIBRARY_PATH=[^ ]*/v0/hexpkg/pkg-linux/lib ADSP_LIBRARY_PATH=[^ ]*/v0/farf;[^ ]*/v0/htp-retry;[^ ]*/v0/hexpkg/pkg-linux/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 .*NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 .* -ngl 99 --ctx-checkpoints 0$')
      grep -q "GATE B4: PASS" $s && [ "$(cat $T/gate-args)" = "$BR/v0/v0d-admit-B4 B4 1" ] && [ "$(cat $T/b4c)" = 7 ] \
        && np=$(grep -c '^probe-' $T/cmds) && [ "$(cat $T/hc)" = $((np+1)) ] && [ "$(cat $T/pc)" = $((np+1)) ] && [ "$(grep -c 'PRE-BASE probe-' $s)" = $np ] \
        && [ "$(sort -u $T/caps)" = 5120 ] && [ "$(wc -l < $T/caps)" = 5 ] && [ $ok = 1 ] && [ "$pr" = 0 ] && [ "$(grep -c '^probe-' $T/cmds)" -ge 1 ] \
        || { echo "FAIL $name: gate, 7 B4 identity checks, the baseline checks at entry and before each probe, memfloor 5120, B4 commands/depths ($ok) or probes ($pr not patched campaign 40960/512)"; fails=$((fails+1)); };; esac
  # D180: B9's command (the retry build after the npu-dev .farf, two sessions, -ts 18,15, embedding on the CPU, -np 1),
  # B4's D2(a) depths and nctx on warm-up and r1-r3 only, B4's baseline checks, its own identity check, never B4's
  case $name in b9-pass) s=$BR/v0/v0d/v0d-admit-B9-status.txt; ok=1
      for st in warmup r1 r2 r3; do c=$(grep "^B9-s1-$st " $T/cmds)
        [[ "$c" == "B9-s1-$st B9-s1-$st v0d-admit-B9 --depths 512,8192,16384,28672 --nctx 32768 -- env LD_LIBRARY_PATH=$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337/lib ADSP_LIBRARY_PATH=$HOME/npu-dev/farf;$HOME/npu-dev/htp-retry-ff5a2337;$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 GGML_HEXAGON_NHMX=1 "*"/llama-server -m $HOME/npu-dev/b1/models/Ternary-Bonsai-2-9B-Q2_0.gguf -c 32768 --cache-ram 5120 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ts 18,15 -ot token_embd\\.weight=CPU -ngl 999 -np 1 -fa on --jinja --ctx-checkpoints 0" ]] || { ok=0; echo "     $st: $c"; }
      done
      c=$(grep "^B9-s1-tools " $T/cmds); [[ "$c" == *" -c 32768 "*"-np 1 "* ]] || { ok=0; echo "     tools: $c"; }
      pr=$(grep '^probe-' $T/cmds | grep -vc -- '--depths 512 --nctx 40960 -- env LD_LIBRARY_PATH=[^ ]*/v0/hexpkg/pkg-linux/lib ADSP_LIBRARY_PATH=[^ ]*/v0/farf;[^ ]*/v0/htp-retry;[^ ]*/v0/hexpkg/pkg-linux/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 .*NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 .* -ngl 99 --ctx-checkpoints 0$')
      grep -q "GATE B9: PASS" $s && [ "$(cat $T/gate-args)" = "$BR/v0/v0d-admit-B9 B9 1" ] && [ "$(cat $T/b9c)" = 7 ] && [ ! -e $T/b4c ] \
        && np=$(grep -c '^probe-' $T/cmds) && [ "$(cat $T/hc)" = $((np+1)) ] && [ "$(cat $T/pc)" = $((np+1)) ] && [ "$(grep -c 'PRE-BASE probe-' $s)" = $np ] \
        && [ "$(sort -u $T/caps)" = 5120 ] && [ "$(wc -l < $T/caps)" = 5 ] && [ $ok = 1 ] && [ "$pr" = 0 ] && [ "$np" -ge 1 ] \
        || { echo "FAIL $name: gate, 7 B9 identity checks (no B4 check), the baseline checks at entry and before each probe, memfloor 5120, B9 commands/depths ($ok) or probes ($pr)"; fails=$((fails+1)); };; esac
  # D178 (review of 4d278e0): baseline identity lost before the recovery probe after r2's clean load failure: stop, no probe
  case $name in b9-*-before-recovery) grep -q "STOP: before baseline probe-" $BR/v0/v0d/v0d-admit-B9-status.txt && [ "$(tail -1 $T/calls)" = B9-s1-r2 ] \
      || { echo "FAIL $name: no stop before the recovery probe"; tail -3 $T/calls | sed 's/^/     /'; fails=$((fails+1)); };; esac
  case $name in b4-*-before-recovery) grep -q "STOP: before baseline probe-" $BR/v0/v0d/v0d-admit-B4-status.txt && [ "$(tail -1 $T/calls)" = B4-s1-r2 ] \
      || { echo "FAIL $name: no stop before the recovery probe"; tail -3 $T/calls | sed 's/^/     /'; fails=$((fails+1)); };; esac
  rm -rf $T; }
case1 h2-helper-missing H2 6 none HELPER_CHECK=false
case1 h2-restart-first H2 0 PRELOAD HELPER_CHECK=true
case1 a-probe-first A 0 probe HELPER_CHECK=false
# D137: AR checks the patched library before anything, before every step and after the set, then the 16K gate
case1 ar-pass AR 0 probe HELPER_CHECK=false
case1 ar-library-wrong AR 6 none LIBFAIL_AT=1
case1 ar-library-changes-mid-set AR 2 probe LIBFAIL_AT=3
case1 ar-library-changes-after-set AR 2 probe LIBFAIL_AT=7
case1 ar-gate-fail AR 3 probe GATE_RC=3
case1 ar-gate-missing AR 2 probe GATE_RC=2
# D138: integration with the real gate: r2 fails to load once (clean), its retry passes, the gate reads the retry
case1 ar-load-retry-real-gate AR 0 probe LOADFAIL_LAB=AR-s1-r2 GATE="python3 $HOME/v0/admit_gate.py"
# D157: A32 (AR + -ngl 32, --cache-ram 5120): same library checks and gate as AR
case1 a32-pass A32 0 probe HELPER_CHECK=false
case1 a32-library-wrong A32 6 none LIBFAIL_AT=1
case1 a32-library-changes-mid-set A32 2 probe LIBFAIL_AT=3
case1 a32-gate-fail A32 3 probe GATE_RC=3
case1 a32-load-retry-real-gate A32 0 probe LOADFAIL_LAB=A32-s1-r3 GATE="python3 $HOME/v0/admit_gate.py"
# D178: B4 (Bonsai-2-4B, q8_0 KV, package ff5a2337), both D2 branches; its identity check at entry, per step and after
case1 b4-pass-a "B4 a" 0 probe
case1 b4-pass-b "B4 b" 0 probe
case1 b4-no-d2-branch B4 9 none
case1 b4-identity-wrong "B4 a" 6 none B4FAIL_AT=1
case1 b4-identity-changes-mid-set "B4 a" 2 probe B4FAIL_AT=3
case1 b4-identity-changes-after-set "B4 a" 2 probe B4FAIL_AT=7
case1 b4-gate-fail "B4 a" 3 probe GATE_RC=3
case1 b4-baseline-library-wrong-at-entry "B4 a" 6 none LIBFAIL_AT=1
case1 b4-campaign-package-wrong-at-entry "B4 a" 6 none PKGFAIL_AT=1
case1 b4-library-drift-before-recovery "B4 a" 2 probe LIBFAIL_AT=3 LOADFAIL_LAB=B4-s1-r2
case1 b4-package-drift-before-recovery "B4 a" 2 probe PKGFAIL_AT=3 LOADFAIL_LAB=B4-s1-r2
case1 b4-load-retry-real-gate "B4 a" 0 probe LOADFAIL_LAB=B4-s1-r2 GATE="python3 $HOME/v0/admit_gate.py"
# D180: B9 (Bonsai-2-9B, two sessions, the retry build of ff5a2337), B4's D2(a) window; its identity check at entry, per
# step and after; B4's baseline checks
case1 b9-pass B9 0 probe
case1 b9-identity-wrong B9 6 none B9FAIL_AT=1
case1 b9-identity-changes-mid-set B9 2 probe B9FAIL_AT=3
case1 b9-identity-changes-after-set B9 2 probe B9FAIL_AT=7
case1 b9-gate-fail B9 3 probe GATE_RC=3
case1 b9-baseline-library-wrong-at-entry B9 6 none LIBFAIL_AT=1
case1 b9-campaign-package-wrong-at-entry B9 6 none PKGFAIL_AT=1
case1 b9-library-drift-before-recovery B9 2 probe LIBFAIL_AT=3 LOADFAIL_LAB=B9-s1-r2
case1 b9-package-drift-before-recovery B9 2 probe PKGFAIL_AT=3 LOADFAIL_LAB=B9-s1-r2
case1 b9-load-retry-real-gate B9 0 probe LOADFAIL_LAB=B9-s1-r2 GATE="python3 $HOME/v0/admit_gate.py"
echo "failures: $fails"; exit $fails
