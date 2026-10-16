#!/bin/bash
# mocked tests for npu_dev_run.sh (plan section 7): every verdict and refusal path with harmless commands (sleep,
# shell scripts), a fake journalctl that answers per _PID (journal.d/<pid>), a fake kernel audit, a fake meminfo file,
# a fake /proc root for the stall rule and a fake watchdog status file. Nothing touches the NPU; the campaign's sampler
# and watchdog checks are replaced by CHECK_SVC=true. Processes are checked and stopped by recorded PID, never by name.
D=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; n=0
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$W/$1"; chmod +x "$W/$1"; }
mkdir -p "$W/journal.d"
# fake journalctl: -k readable unless FAKE_K=bad; "_PID=<p>" prints journal.d/<p> (nothing if absent) unless FAKE_J=bad
mk journal 'if [ "$1" = -k ]; then [ "${FAKE_K:-ok}" = ok ]; exit; fi; [ "${FAKE_J:-ok}" = ok ] || { echo "no access" >&2; exit 1; }
p=${1#_PID=}; cat "'"$W"'/journal.d/$p" 2>/dev/null; exit 0'
# fake kernel audit: FAKE_KA=pass|fault|late (late: "missing: no good kernel read" on the first call only)
mk kaudit 'case ${FAKE_KA:-pass} in pass) echo "pass (window)"; exit 0;; fault) echo "fault fault=1"; exit 1;;
  late) f="'"$W"'/ka.calls"; c=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo $c > "$f"; [ $c -ge 2 ] && { echo "pass (window)"; exit 0; }; echo "missing: no good kernel read from boot x"; exit 3;; esac'
printf 'MemTotal: 15000000 kB\nMemAvailable: 9000000 kB\n' > "$W/meminfo"
# fake process list: the real processes descended from this test plus $W/extra_ps; the rest of the host is invisible
TROOT=$$
mk pslist 'ps -eo pid=,ppid=,args= | awk -v r='"$TROOT"' "{ p[\$1] = \$2; l[\$1] = \$0 } END { for (k in l) { for (x = k; x != \"\" && x != 0 && x != 1; x = p[x]) if (x == r) { print l[k]; break } } }"; cat "'"$W"'/extra_ps" 2>/dev/null; true'
: > "$W/extra_ps"; : > "$W/wd-status"
mk llama-fake 'sleep 1; exit 0'
base() { env PS_LIST="$W/pslist" BR="$W/br" JOURNAL="$W/journal" KAUDIT="$W/kaudit" CHECK_SVC=true MEMINFO="$W/meminfo" TICK=1 KILL_GRACE=2 \
  BOOT_ID=11111111-2222-3333-4444-555555555555 WCHAN_GLOB_ROOT="$W/proc" WD_STATUS="$W/wd-status" "$@"; }
out=
expect() {  # <name> <rc> <verdict prefix> <cmd...>
  local name=$1 want=$2 pre=$3; shift 3; n=$((n + 1))
  out=$("$@" 2>&1); rc=$?; v=$(echo "$out" | tail -1)
  if [ "$rc" = "$want" ] && [ "${v#"$pre"}" != "$v" ]; then echo "ok   $name (rc $rc: $v)"
  else echo "FAIL $name (rc $rc, wanted $want '$pre'): $(echo "$out" | tail -2 | tr '\n' ' ')"; fails=$((fails + 1)); fi
}
gone() {  # <name> <run>: every MEMBER pid recorded for the run is gone
  n=$((n + 1)); local pids left; pids=$(sed -n 's/^\S* MEMBER \([0-9]*\) .*/\1/p' "$W/br/npu-dev/t/$2/run.txt")
  left=$(for p in $pids; do kill -0 "$p" 2>/dev/null && echo "$p"; done)
  if [ -z "$pids" ]; then echo "FAIL $1: no MEMBER recorded"; fails=$((fails + 1))
  elif [ -n "$left" ]; then echo "FAIL $1: left alive $left"; fails=$((fails + 1)); kill -KILL $left 2>/dev/null
  else echo "ok   $1 (members $(echo $pids | wc -w), none alive)"; fi; }
R="$D/npu_dev_run.sh"
expect "a clean command: PASS" 0 PASS base bash "$R" --stage t --run pass --timeout 30 -- sleep 1
expect "a failing command: FAIL" 1 "FAIL: command exit 5" base bash "$R" --stage t --run fail --timeout 30 -- bash -c 'exit 5'
expect "timeout: STOP TIMEOUT" 2 "STOP: TIMEOUT" base bash "$R" --stage t --run to --timeout 2 -- sleep 60
gone "timeout killed every member" to
expect "memory floor: STOP FLOOR" 2 "STOP: FLOOR" base bash "$R" --stage t --run floor --timeout 30 --floor-mib 2000 -- \
  bash -c "sleep 2; printf 'MemAvailable: 1000000 kB\n' > '$W/meminfo'; sleep 30"
printf 'MemTotal: 15000000 kB\nMemAvailable: 9000000 kB\n' > "$W/meminfo"
expect "stall: STOP STALL" 2 "STOP: STALL" base bash "$R" --stage t --run stall --timeout 60 --stall-s 3 -- \
  bash -c "mkdir -p '$W/proc/'\$\$/task/1; ln -s /proc/\$\$/stat '$W/proc/'\$\$/stat; echo fastrpc_wait_for_completion > '$W/proc/'\$\$/task/1/wchan; sleep 60"
expect "busy FastRPC wait with CPU use, past two samples: PASS" 0 PASS base bash "$R" --stage t --run busy --timeout 40 --stall-s 3 -- \
  bash -c "mkdir -p '$W/proc/'\$\$/task/1; ln -s /proc/\$\$/stat '$W/proc/'\$\$/stat; echo fastrpc_wait_for_completion > '$W/proc/'\$\$/task/1/wchan; end=\$((SECONDS + 24)); while [ \$SECONDS -lt \$end ]; do :; done"
# the review of fdb7292: children, orphans, interruption
expect "a child's DSP journal is exported (expect-dsp yes): PASS" 0 PASS base bash "$R" --stage t --run child --timeout 30 --expect-dsp yes -- \
  bash -c "sleep 3 & c=\$!; printf 'x CDSP0: Successfully opened file libggml-htp-v75.so\nx CDSP0:[R]: htp-main-thread: started\n' > '$W/journal.d/'\$c; wait"
expect "a DSP fault in a child's journal: STOP" 2 "STOP: DSP fault lines" base bash "$R" --stage t --run childfault --timeout 30 --expect-dsp yes -- \
  bash -c "sleep 3 & c=\$!; printf 'x CDSP0: Successfully opened file libggml-htp-v75.so\nx CDSP0:[R]: dspqueue_peek failed: 0x0000002f\n' > '$W/journal.d/'\$c; wait"
expect "the leader exits leaving a child: STOP ORPHANS" 2 "STOP: ORPHANS" base bash "$R" --stage t --run orphan --timeout 30 -- \
  bash -c "sleep 60 & sleep 2; exit 0"
gone "the orphaned child was killed" orphan
# the signal must reach the wrapper itself: exec keeps the background pid the wrapper's own
( exec env PS_LIST="$W/pslist" BR="$W/br" JOURNAL="$W/journal" KAUDIT="$W/kaudit" CHECK_SVC=true MEMINFO="$W/meminfo" TICK=1 KILL_GRACE=2 \
    BOOT_ID=11111111-2222-3333-4444-555555555555 WCHAN_GLOB_ROOT="$W/proc" WD_STATUS="$W/wd-status" \
    bash "$R" --stage t --run intr --timeout 60 -- sleep 60 > "$W/intr.out" 2>&1 ) & wpid=$!
sleep 3; kill -TERM "$wpid"; wait "$wpid"; rc=$?; n=$((n + 1))
if [ "$rc" = 2 ] && grep -q '^STOP: INTERRUPTED' "$W/intr.out"; then echo "ok   the wrapper interrupted by SIGTERM: STOP INTERRUPTED (rc 2)"
else echo "FAIL wrapper interrupted (rc $rc): $(tail -1 "$W/intr.out")"; fails=$((fails + 1)); fi
gone "the interrupted run's members were killed" intr
echo '4242 1 bash /home/arduino/v0/v0e_A_retry.sh A32 5' > "$W/extra_ps"
expect "exclusivity: a campaign driver running: REFUSED" 3 "REFUSED: busy" base bash "$R" --stage t --run excl --timeout 30 -- sleep 1
n=$((n + 1)); [ ! -e "$W/br/npu-dev/t/excl" ] && echo "ok   a busy refusal writes no evidence directory" || { echo "FAIL busy refusal wrote a directory"; fails=$((fails + 1)); }
echo '4243 1 /x/build/bin/llama-server -m m.gguf' > "$W/extra_ps"
expect "exclusivity: a llama-server running: REFUSED" 3 "REFUSED: busy" base bash "$R" --stage t --run excl2 --timeout 30 -- sleep 1
: > "$W/extra_ps"
expect "its own llama-* command is not a conflict: PASS" 0 PASS base bash "$R" --stage t --run self --timeout 30 -- "$W/llama-fake"
# the review of fdb7292: a failed or unusable snapshot refuses, and the payload never runs
for c in "false:the process snapshot failed" "true:empty or malformed" "echo garbage:empty or malformed" "echo 1 1 init:does not contain this wrapper"; do
  cmd=${c%%:*}; why=${c#*:}
  expect "process snapshot '$cmd': REFUSED" 3 "REFUSED: " base PS_LIST="$cmd" bash "$R" --stage t --run snap$n --timeout 30 -- touch "$W/marker"
  n=$((n + 1)); if [ ! -e "$W/marker" ] && grep -q "$why" <<< "$out"; then echo "ok   ... the reason '$why', and the payload never ran"
  else echo "FAIL snapshot '$cmd': marker or reason ($out)"; fails=$((fails + 1)); rm -f "$W/marker"; fi
done
expect "an existing evidence directory: REFUSED" 3 "REFUSED: evidence directory" base bash "$R" --stage t --run pass --timeout 30 -- sleep 1
expect "kernel journal unreadable: REFUSED" 3 "REFUSED: the kernel journal" base FAKE_K=bad bash "$R" --stage t --run k --timeout 30 -- sleep 1
expect "MemAvailable below the floor at the start: REFUSED" 3 "REFUSED: MemAvailable" base bash "$R" --stage t --run lowmem --timeout 30 --floor-mib 99999 -- sleep 1
expect "a missing --hash file: REFUSED" 3 "REFUSED: --hash" base bash "$R" --stage t --run hash --timeout 30 --hash "$W/none" -- sleep 1
expect "a bad --env: REFUSED" 3 "REFUSED: --env" base bash "$R" --stage t --run env --timeout 30 --env "1BAD=x" -- sleep 1
expect "--env reaches the command, nothing inherited does: PASS" 0 PASS base GGML_INHERITED=1 bash "$R" --stage t --run env2 --timeout 30 --env GGML_TESTVAR=ok -- \
  bash -c '[ "$GGML_TESTVAR" = ok ] && [ -z "${GGML_INHERITED:-}" ]'
expect "allocation guard: a declared session peak above the limit: REFUSED" 3 "REFUSED: allocation guard" base bash "$R" --stage t --run g1 --timeout 30 --declared-peak-mib 2594.0,3200.0 -- sleep 1
expect "allocation guard: declared peaks within: PASS" 0 PASS base bash "$R" --stage t --run g2 --timeout 30 --declared-peak-mib 2594.0,2501.5,2491.7,2236.7 --declared-board-mib 7000 -- sleep 1
expect "allocation guard: a declared board peak above MemAvailable - floor: REFUSED" 3 "REFUSED: allocation guard" base bash "$R" --stage t --run g3 --timeout 30 --declared-board-mib 9000 -- sleep 1
expect "the campaign watchdog intervening during the run: STOP" 2 "STOP: the campaign stall watchdog" base bash "$R" --stage t --run wd --timeout 30 -- \
  bash -c "sleep 1; echo '2026-10-17T00:00:00+02:00 NPU-WATCHDOG killed hung llama-server pid 1' >> '$W/wd-status'"
expect "journal read failure: STOP" 2 "STOP: journal read failed" base FAKE_J=bad bash "$R" --stage t --run j --timeout 30 -- sleep 1
expect "--expect-dsp yes without DSP lines: STOP" 2 "STOP: DSP evidence missing" base bash "$R" --stage t --run dsp0 --timeout 30 --expect-dsp yes -- sleep 1
expect "kernel audit fault: STOP" 2 "STOP: kernel audit rc 1" base FAKE_KA=fault bash "$R" --stage t --run kf --timeout 30 -- sleep 1
expect "kernel read late, then present: PASS" 0 PASS base FAKE_KA=late bash "$R" --stage t --run kl --timeout 30 -- sleep 1
n=$((n + 1)); r="$W/br/npu-dev/t/pass/run.txt"
grep -q '^\S* START stage=t run=pass boot=11111111-2222-3333-4444-555555555555 test=yes' "$r" && grep -q '^\S* END rc=0' "$r" && grep -q '^\S* PID [0-9]' "$r" \
  && grep -q '^\S* MEMBER [0-9]' "$r" && grep -q '^\S* ENVIRONMENT clean' "$r" && [ "$(head -1 "$W/br/npu-dev/t/pass/memory.tsv")" = "$(printf 't\tmem_avail_mib')" ] \
  && echo "ok   run.txt has START (boot, test flag), PID, MEMBER, ENVIRONMENT and END lines; memory.tsv written" \
  || { echo "FAIL run.txt or memory.tsv format"; fails=$((fails + 1)); }
echo "failures: $fails of $n"; exit $fails
