#!/bin/bash
# V0d admission sets (D68 restart rule, D85): v0d_admit.sh <A|AM|H>. One set per invocation, each its own phase dir and
# fault counter. Exit 0 admitted, 3 not eligible / memory reject, anything else = stop the chain (fail-closed).
#   A   NeoHorse-1-4B plain, 2 NPU sessions, --cache-ram 7942 (D67)
#   AM  A + base Qwen3.5-4B MTP head drafted on a 3rd NPU session, n1 (D80), --cache-ram 4188 (D85, provisional)
#   H   Ornith-1.0-9B, 3 sessions, MBUF 256, -ngl 33 --no-op-offload -t 4 --no-host, --cache-ram 5364 (D67); probe first
#   H2  H again (D92, D102: owner-authorized within the installed helper's expiry window): cDSP restart + settle before every step's probe and load
#   AR  A with the patched DSP library (D137): ~/v0/htp-retry first on ADSP_LIBRARY_PATH after the DSP logging file
#       (~/v0/farf); htp_retry_check.sh runs before every step's probe and load and after the set (a mismatch stops);
#       if admitted, admit_gate.py applies the frozen 16K gate to that attempt's r1-r3 ("GATE AR: PASS" or exit 3)
#   A32 AR with the output layer on the CPU (-ngl 32, D155: the NPU output-layer path breaks pi's tool calls) and
#       --cache-ram 5120 (D157: AR's 7942 left MemAvailable at 1.06 GiB in V0e, D139); same library checks and gate
#   B4  Ternary-Bonsai-2-4B Q2_0 on one NPU session with a q8_0 KV cache, package ff5a2337 (D178, v0e-plan-B4.txt):
#       "v0d_admit.sh B4 a|b", the owner's decision D2: a = -c 32768 with the measured steps at depths
#       512,8192,16384,28672 (--nctx 32768), b = -c 40960 with the frozen depths; --cache-ram 5120. b4_identity_check.sh
#       (package manifest, model hash, npu-dev .farf) at entry, before every step's probe and load, and after the set;
#       the frozen 16K gate as AR/A32. Its baseline and recovery probes are A32-5's (review of 4d278e0): the campaign
#       package with the patched DSP library (~/v0/farf;~/v0/htp-retry first), and at entry and immediately before
#       EVERY baseline load (PRE_BASE: first try, retries, recovery) htp_retry_check.sh and the campaign package's D176
#       manifest check; a mismatch stops. Other sets keep their release-library baseline and no PRE_BASE.
# Overridable for tests (tools/test_admit_entry.sh): BR, CHECK_PROC, HELPER_CHECK, PRE_CMD, HTPR_CHECK, B4_CHECK, CAMP_PKG_CHECK, GATE, plus the
# runner's RUN_ROUTE etc.
set -uo pipefail
source ~/v0/v0d_lib.sh
S=$1; case $S in A|AM|H|H2|AR|A32) ;; B4) case ${2:-} in a|b) D2=$2;; *) echo "set B4 needs the D2 branch: a or b" >&2; exit 9;; esac;; *) echo "unknown set $S" >&2; exit 9;; esac
BR=${BR:-$HOME/bench-runs}; CHECK_PROC=${CHECK_PROC:-pgrep -f}
HELPER_CHECK=${HELPER_CHECK:-sudo -n -l /usr/local/sbin/v0-cdsp-restart}; PRE_CMD=${PRE_CMD:-/bin/bash $HOME/v0/cdsp_pre.sh}
HTPR_CHECK=${HTPR_CHECK:-/bin/bash $HOME/v0/htp_retry_check.sh}; GATE=${GATE:-python3 $HOME/v0/admit_gate.py}
B4_CHECK=${B4_CHECK:-/bin/bash $HOME/v0/b4_identity_check.sh}
PH=v0d-admit-$S; ST=$BR/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; DR=~/v0/models/drafts; O=$BR/v0/$PH
CAMP_PKG_CHECK=${CAMP_PKG_CHECK:-python3 $HOME/v0/pkg_identity.py check $HOME/v0/pkg-identity-836d57176.txt $P}
mkdir -p $O $BR/v0/v0d; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
A="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
AM="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 4188 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 1 --device-draft HTP0:2 --spec-draft-ngl all -otd blk\.([0-9]|[12][0-9]|3[01])\.=CPU --no-repack"
# AR = A with only ADSP_LIBRARY_PATH changed (the .farf directory, then the patched library, then the package)
AR="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$HOME/v0/farf;$HOME/v0/htp-retry;$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
# A32 = AR with -ngl 32 instead of 99 and --cache-ram 5120 instead of 7942 (D157), nothing else changed
A32="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$HOME/v0/farf;$HOME/v0/htp-retry;$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 5120 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 32 --ctx-checkpoints 0"
# B4 (D178): PB's own (unpatched) library after the npu-dev .farf directory, one session, q8_0 KV, -np 1 pinned
PB=~/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337; MB=~/npu-dev/b1/models
unset ADMIT_NCTX ADMIT_DEPTHS
if [ $S = B4 ]; then
  case $D2 in a) B4C=32768; export ADMIT_NCTX=32768 ADMIT_DEPTHS=512,8192,16384,28672;; b) B4C=40960;; esac
  # the baseline as A32-5's V0e (LV>=2): only ADSP_LIBRARY_PATH changed from the release-library baseline
  BASE="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$HOME/v0/farf;$HOME/v0/htp-retry;$P/lib ${BASE#* ADSP_LIBRARY_PATH=$P/lib }"
  B4="env LD_LIBRARY_PATH=$PB/lib ADSP_LIBRARY_PATH=$HOME/npu-dev/farf;$PB/lib GGML_HEXAGON_DEVICES=HTP0:0 GGML_HEXAGON_NHMX=1 $PB/bin/llama-server -m $MB/Ternary-Bonsai-2-4B-Q2_0.gguf -c $B4C --cache-ram 5120 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0 -ngl 999 -np 1 -fa on -ctk q8_0 -ctv q8_0 --jinja --ctx-checkpoints 0"
fi
# campck <where>: B4's baseline identity (the patched library and .farf, the campaign package); prints its line, 1 on mismatch
campck() { local c p; c=$($HTPR_CHECK 2>&1) || { echo "$1: $c"; return 1; }
  p=$($CAMP_PKG_CHECK 2>&1) || { echo "$1: campaign package: $(echo "$p" | grep -m1 -v '^RESULT') ($(echo "$p" | tail -1))"; return 1; }
  echo "$c; campaign package $(echo "$p" | tail -1)"; }
b4base() { local c; c=$(campck "before baseline $1") || { say "STOP: $c"; exit 2; }; say "PRE-BASE $1: $c"; }
[ $S = B4 ] && PRE_BASE=b4base
H="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 5364 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4 --no-host"
# fail-closed preconditions: HANG detection needs the stall watchdog, kernel/health evidence needs the sampler
$CHECK_PROC '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
$CHECK_PROC '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
# H2 (D93, Codex review of #47 22:08Z): its helper is checked before anything loads, and there is no plain initial
# probe: the first step is restart + settle -> baseline probe -> warm-up. Each admission step's probe/load pair follows
# a restart; recovery probes (after a fault or load failure) do not restart.
[ $S = H2 ] && { $HELPER_CHECK > /dev/null 2>&1 || { say "STOP: cDSP restart helper not installed (D92)"; exit 6; }; }
case $S in AR|A32) c=$($HTPR_CHECK 2>&1) || { say "STOP: $c"; exit 6; }; say "$S library: $c";;
  B4) c=$($B4_CHECK 2>&1) || { say "STOP: $c"; exit 6; }; say "B4 identity: $c"
      c=$(campck "baseline at entry") || { say "STOP: $c"; exit 6; }; say "B4 baseline identity: $c"; say "B4 D2 branch $D2: -c $B4C, measured depths ${ADMIT_DEPTHS:-512,8192,16384,32768}, --nctx ${ADMIT_NCTX:-40960}";; esac
say "admission $S start (pid $$)"; [ $S = H2 ] || ready now
case $S in
  A)  admit_set A 7942 none $A;;
  AM) admit_set AM 4188 none $AM;;
  H)  admit_set H 5364 probe $H;;
  H2) PRE_LOAD="$PRE_CMD" admit_set H2 5364 probe $H;;
  AR) PRE_LOAD="$HTPR_CHECK" admit_set AR 7942 none $AR;;
  A32) PRE_LOAD="$HTPR_CHECK" admit_set A32 5120 none $A32;;
  B4) PRE_LOAD="$B4_CHECK" admit_set B4 5120 none $B4;;
esac; rc=$?
# AR (D137), A32 (D157): the library must still be the declared one after the set, and an admitted set must pass the
# 16K gate
if { [ $S = AR ] || [ $S = A32 ] || [ $S = B4 ]; } && [ $rc = 0 ]; then
  if [ $S = B4 ]; then c=$($B4_CHECK 2>&1) || { say "STOP: after the set: $c"; exit 2; }
  else c=$($HTPR_CHECK 2>&1) || { say "STOP: after the set: $c"; exit 2; }; fi
  att=$(grep -oE "SET $S: ADMITTED in attempt [12]" $ST | tail -1 | grep -oE '[12]$')
  g=$($GATE $O $S "${att:-0}" 2>&1); grc=$?; say "$g"
  case $grc in 0) ;; 3) rc=3;; *) say "STOP: 16K gate evidence missing"; rc=2;; esac
fi
say "admission $S done rc=$rc (faults $(nfaults))"; exit $rc
