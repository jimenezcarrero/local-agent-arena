#!/bin/bash
# mocked tests for npu_dev_run.sh (plan section 7): every verdict and refusal path with harmless commands (sleep,
# shell scripts), a fake journalctl, a fake kernel audit, a fake meminfo file and a fake /proc root for the stall rule.
# Nothing touches the NPU; the campaign's sampler and watchdog checks are replaced by CHECK_SVC=true.
D=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; n=0
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$W/$1"; chmod +x "$W/$1"; }
# fake journalctl: -k readable unless FAKE_K=bad; per-pid export from $W/journal.txt unless FAKE_J=bad
mk journal 'if [ "$1" = -k ]; then [ "${FAKE_K:-ok}" = ok ]; exit; fi; [ "${FAKE_J:-ok}" = ok ] || { echo "no access" >&2; exit 1; }; cat "'"$W"'/journal.txt" 2>/dev/null; exit 0'
# fake kernel audit: FAKE_KA=pass|fault|late (late: "missing: no good kernel read" on the first call only)
mk kaudit 'case ${FAKE_KA:-pass} in pass) echo "pass (window)"; exit 0;; fault) echo "fault fault=1"; exit 1;;
  late) f="'"$W"'/ka.calls"; c=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo $c > "$f"; [ $c -ge 2 ] && { echo "pass (window)"; exit 0; }; echo "missing: no good kernel read from boot x"; exit 3;; esac'
printf 'MemTotal: 15000000 kB\nMemAvailable: 9000000 kB\n' > "$W/meminfo"
# fake process list: the real processes descended from this test (so the wrapper's ancestry and descendant rules and the
# stall rule see real pids) plus the lines of $W/extra_ps; whatever else runs on the host is invisible to the tests
TROOT=$$
mk pslist 'ps -eo pid=,ppid=,args= | awk -v r='"$TROOT"' "{ p[\$1] = \$2; l[\$1] = \$0 } END { for (k in l) { for (x = k; x != \"\" && x != 0 && x != 1; x = p[x]) if (x == r) { print l[k]; break } } }"; cat "'"$W"'/extra_ps" 2>/dev/null; true'
: > "$W/extra_ps"
mk llama-fake 'sleep 1; exit 0'
base() { env PS_LIST="$W/pslist" BR="$W/br" JOURNAL="$W/journal" KAUDIT="$W/kaudit" CHECK_SVC=true MEMINFO="$W/meminfo" TICK=1 KILL_GRACE=2 \
  BOOT_ID=11111111-2222-3333-4444-555555555555 WCHAN_GLOB_ROOT="$W/proc" "$@"; }
expect() {  # <name> <rc> <verdict prefix> <cmd...>
  local name=$1 want=$2 pre=$3; shift 3; n=$((n + 1))
  out=$("$@" 2>&1); rc=$?; v=$(echo "$out" | tail -1)
  if [ "$rc" = "$want" ] && [ "${v#"$pre"}" != "$v" ]; then echo "ok   $name (rc $rc: $v)"
  else echo "FAIL $name (rc $rc, wanted $want '$pre'): $(echo "$out" | tail -2 | tr '\n' ' ')"; fails=$((fails + 1)); fi
}
R="$D/npu_dev_run.sh"
: > "$W/journal.txt"
expect "a clean command: PASS" 0 PASS base bash "$R" --stage t --run pass --timeout 30 -- sleep 1
expect "a failing command: FAIL" 1 "FAIL: command exit 5" base bash "$R" --stage t --run fail --timeout 30 -- bash -c 'exit 5'
expect "timeout: STOP TIMEOUT" 2 "STOP: TIMEOUT" base bash "$R" --stage t --run to --timeout 2 -- sleep 60
# the timed-out run's process group (its pid, recorded in run.txt) must be gone: checked by pid, never by a name pattern
sleep 1; n=$((n + 1)); tp=$(sed -n 's/^\S* PID \([0-9]*\)$/\1/p' "$W/br/npu-dev/t/to/run.txt")
if [ -z "$tp" ]; then echo "FAIL timeout run recorded no pid"; fails=$((fails + 1))
elif kill -0 -- -"$tp" 2>/dev/null; then echo "FAIL timeout left its process group $tp running"; fails=$((fails + 1)); kill -KILL -- -"$tp" 2>/dev/null
else echo "ok   timeout killed the whole group (pgid $tp gone)"; fi
# memory floor: the command lowers MemAvailable in the fake meminfo after it starts
expect "memory floor: STOP FLOOR" 2 "STOP: FLOOR" base bash "$R" --stage t --run floor --timeout 30 --floor-mib 2000 -- \
  bash -c "sleep 2; printf 'MemAvailable: 1000000 kB\n' > '$W/meminfo'; sleep 30"
printf 'MemTotal: 15000000 kB\nMemAvailable: 9000000 kB\n' > "$W/meminfo"
# stall: the command plants a fake /proc entry for itself with a thread in fastrpc_wait_for_completion and no CPU use
expect "stall: STOP STALL" 2 "STOP: STALL" base bash "$R" --stage t --run stall --timeout 60 --stall-s 3 -- \
  bash -c "mkdir -p '$W/proc/'\$\$/task/1; ln -s /proc/\$\$/stat '$W/proc/'\$\$/stat; echo fastrpc_wait_for_completion > '$W/proc/'\$\$/task/1/wchan; sleep 60"
# a FastRPC wait with CPU progress is not a stall
expect "busy FastRPC wait with CPU use: PASS" 0 PASS base bash "$R" --stage t --run busy --timeout 30 --stall-s 3 -- \
  bash -c "mkdir -p '$W/proc/'\$\$/task/1; ln -s /proc/\$\$/stat '$W/proc/'\$\$/stat; echo fastrpc_wait_for_completion > '$W/proc/'\$\$/task/1/wchan; end=\$((SECONDS + 14)); while [ \$SECONDS -lt \$end ]; do :; done"
echo '4242 1 bash /home/arduino/v0/v0e_A_retry.sh A32 5' > "$W/extra_ps"
expect "exclusivity: a campaign driver running: REFUSED" 3 "REFUSED: busy" base bash "$R" --stage t --run excl --timeout 30 -- sleep 1
n=$((n + 1)); [ ! -e "$W/br/npu-dev/t/excl" ] && echo "ok   a busy refusal writes no evidence directory" || { echo "FAIL busy refusal wrote a directory"; fails=$((fails + 1)); }
echo '4243 1 /x/build/bin/llama-server -m m.gguf' > "$W/extra_ps"
expect "exclusivity: a llama-server running: REFUSED" 3 "REFUSED: busy" base bash "$R" --stage t --run excl2 --timeout 30 -- sleep 1
: > "$W/extra_ps"
expect "its own llama-* command is not a conflict: PASS" 0 PASS base bash "$R" --stage t --run self --timeout 30 -- "$W/llama-fake"
expect "an existing evidence directory: REFUSED" 3 "REFUSED: evidence directory" base bash "$R" --stage t --run pass --timeout 30 -- sleep 1
expect "kernel journal unreadable: REFUSED" 3 "REFUSED: the kernel journal" base FAKE_K=bad bash "$R" --stage t --run k --timeout 30 -- sleep 1
expect "MemAvailable below the floor at the start: REFUSED" 3 "REFUSED: MemAvailable" base bash "$R" --stage t --run lowmem --timeout 30 --floor-mib 99999 -- sleep 1
expect "a missing --hash file: REFUSED" 3 "REFUSED: --hash" base bash "$R" --stage t --run hash --timeout 30 --hash "$W/none" -- sleep 1
expect "a bad --env: REFUSED" 3 "REFUSED: --env" base bash "$R" --stage t --run env --timeout 30 --env "1BAD=x" -- sleep 1
expect "--env reaches the command: PASS" 0 PASS base bash "$R" --stage t --run env2 --timeout 30 --env GGML_TESTVAR=ok -- bash -c '[ "$GGML_TESTVAR" = ok ]'
expect "journal read failure: STOP" 2 "STOP: journal read failed" base FAKE_J=bad bash "$R" --stage t --run j --timeout 30 -- sleep 1
expect "--expect-dsp yes without DSP lines: STOP" 2 "STOP: DSP evidence missing" base bash "$R" --stage t --run dsp0 --timeout 30 --expect-dsp yes -- sleep 1
printf 'x CDSP0: Successfully opened file libggml-htp-v75.so\nx CDSP0:[R]: htp-main-thread: started\n' > "$W/journal.txt"
expect "--expect-dsp yes with DSP lines: PASS" 0 PASS base bash "$R" --stage t --run dsp1 --timeout 30 --expect-dsp yes -- sleep 1
printf 'x CDSP0: Successfully opened file libggml-htp-v75.so\nx CDSP0:[R]: dspqueue_peek failed: 0x0000002f\n' > "$W/journal.txt"
expect "a dspqueue error in the journal: STOP" 2 "STOP: DSP fault lines" base bash "$R" --stage t --run dspf --timeout 30 --expect-dsp yes -- sleep 1
: > "$W/journal.txt"
expect "kernel audit fault: STOP" 2 "STOP: kernel audit rc 1" base FAKE_KA=fault bash "$R" --stage t --run kf --timeout 30 -- sleep 1
expect "kernel read late, then present: PASS" 0 PASS base FAKE_KA=late bash "$R" --stage t --run kl --timeout 30 -- sleep 1
n=$((n + 1)); r="$W/br/npu-dev/t/pass/run.txt"
grep -q '^\S* START stage=t run=pass boot=11111111-2222-3333-4444-555555555555 test=yes' "$r" && grep -q '^\S* END rc=0' "$r" && grep -q '^\S* PID [0-9]' "$r" \
  && [ "$(head -1 "$W/br/npu-dev/t/pass/memory.tsv")" = "$(printf 't\tmem_avail_mib')" ] \
  && echo "ok   run.txt has the START (boot, test flag), PID and END lines kernel_audit.py reads; memory.tsv written" \
  || { echo "FAIL run.txt or memory.tsv format"; fails=$((fails + 1)); }
echo "failures: $fails of $n"; exit $fails
