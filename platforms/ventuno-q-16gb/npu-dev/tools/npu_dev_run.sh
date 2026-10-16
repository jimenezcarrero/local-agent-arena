#!/bin/bash
# npu_dev_run.sh (NPU dev plan section 7) — the wrapper every executable of every NPU development stage runs under
#   (llama-server, llama-bench, llama-perplexity, test-backend-ops, harnesses). Proposed for review; no NPU stage runs
#   before the review and the owner's approval of that stage.
#
#   npu_dev_run.sh --stage S --run R --timeout SEC [--floor-mib 1536] [--stall-s 120] [--expect-dsp yes|no]
#                  [--hash PATH]... [--env NAME=VALUE]... -- COMMAND [ARG...]
#
#   Preflight (refuses with exit 3, nothing launched):
#     - exclusivity: no campaign driver, admission, session or runner, and no llama-* / test-backend-ops process other
#       than this wrapper's own ancestry (the campaign's launch-check patterns);
#     - the evidence directory ~/bench-runs/npu-dev/S/R does not exist yet (every run is new);
#     - the kernel journal is readable (journalctl -k) and the campaign's health sampler and NPU stall watchdog run
#       (they keep running during development windows; the watchdog is not modified);
#     - MemAvailable is above the floor; every --hash PATH exists (its sha256 is recorded).
#   Run: COMMAND in its own process group (setsid), stdout and stderr to files, with only the --env variables added.
#   Every second: MemAvailable sampled to memory.tsv; below the floor -> SIGTERM to the group, SIGKILL after 10 s
#   (verdict FLOOR). Elapsed above SEC -> the same (TIMEOUT). Stall: a process of the group with a thread in
#   fastrpc_wait_for_completion and under 0.5 core-s of CPU per 10 s, continuously for --stall-s seconds -> killed
#   (STALL; the campaign watchdog's rule with a 120 s default).
#   After: the DSP journal of every process of the group in the run window (journalctl _PID=, this boot), fail-closed:
#   the command failing is a STOP; with --expect-dsp yes the export must also show the DSP library opened
#   (libggml-htp-v75.so) and DSP-side (CDSP0) lines. Any "dspqueue" error, fatal, crash or "failed" line from the DSP
#   side is a fault (with the unpatched master library a dspqueue_peek failure ends the DSP loop, so it is one). The kernel
#   log over the window is audited with the campaign's kernel_audit.py once a good kernel read after END exists (waited
#   for up to 150 s, as the campaign runner does); fault, unknown or missing evidence is a STOP.
#   Verdict (verdict.txt and the exit code): PASS (0: command exit 0, no fault, audits pass); FAIL (1: the command
#   failed, nothing else wrong); STOP (2: TIMEOUT, FLOOR, STALL, a DSP or kernel fault, or missing or failed evidence:
#   the stage stops, the configuration is not repeated, the owner is told); REFUSED (3: preflight).
#   Evidence only under ~/bench-runs/npu-dev/S/R/: run.txt (command, env, times, boot, pid, hashes), stdout.txt,
#   stderr.txt, memory.tsv, stall.txt, fastrpc-journal.txt, journal-check.txt, kernel-audit.txt, verdict.txt.
#   Overridable for the mocked tests only (run.txt then says TEST): BR (evidence root), PS_LIST (ps -eo pid,ppid,args),
#   MEMINFO, JOURNAL, KAUDIT, CHECK_SVC, WCHAN_GLOB_ROOT (a /proc root), TICK (1 s), KILL_GRACE (10 s), BOOT_ID.
set -uo pipefail
STAGE= RUN= TO= FLOOR=1536 STALL=120 EXPECT_DSP=no; HASHES=(); ENVS=()
while [ $# -gt 0 ]; do
  case $1 in
    --stage) STAGE=$2; shift 2;; --run) RUN=$2; shift 2;; --timeout) TO=$2; shift 2;; --floor-mib) FLOOR=$2; shift 2;;
    --stall-s) STALL=$2; shift 2;; --expect-dsp) EXPECT_DSP=$2; shift 2;; --hash) HASHES+=("$2"); shift 2;;
    --env) ENVS+=("$2"); shift 2;; --) shift; break;; *) echo "unknown option $1" >&2; exit 3;;
  esac
done
CMD=("$@")
TEST=no
for v in BR PS_LIST MEMINFO JOURNAL KAUDIT CHECK_SVC WCHAN_GLOB_ROOT TICK KILL_GRACE BOOT_ID; do [ -n "${!v:-}" ] && TEST=yes; done
BR=${BR:-$HOME/bench-runs}; PS_LIST=${PS_LIST:-ps -eo pid=,ppid=,args=}; MEMINFO=${MEMINFO:-/proc/meminfo}
JOURNAL=${JOURNAL:-journalctl}; KAUDIT=${KAUDIT:-python3 $HOME/v0/kernel_audit.py}; CHECK_SVC=${CHECK_SVC:-default}
PROCROOT=${WCHAN_GLOB_ROOT:-/proc}; TICK=${TICK:-1}; KILL_GRACE=${KILL_GRACE:-10}
BOOT=${BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id)}

refuse() { echo "REFUSED: $*" >&2; [ -n "${D:-}" ] && [ -d "$D" ] && echo "REFUSED: $*" > "$D/verdict.txt"; exit 3; }
[[ "$STAGE" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$RUN" =~ ^[A-Za-z0-9._-]+$ ]] || refuse "--stage and --run must be plain names"
[[ "$TO" =~ ^[0-9]+$ ]] && [ "$TO" -gt 0 ] || refuse "--timeout must be a positive number of seconds"
[[ "$FLOOR" =~ ^[0-9]+$ ]] && [[ "$STALL" =~ ^[0-9]+$ ]] || refuse "--floor-mib and --stall-s must be numbers"
[ "$EXPECT_DSP" = yes ] || [ "$EXPECT_DSP" = no ] || refuse "--expect-dsp must be yes or no"
[ ${#CMD[@]} -gt 0 ] || refuse "no command after --"
for e in "${ENVS[@]}"; do [[ "$e" =~ ^[A-Z_][A-Z0-9_]*=.*$ ]] || refuse "--env '$e' is not NAME=VALUE"; done

# exclusivity (before anything is written): the campaign's patterns, on one process snapshot, excluding this wrapper's
# own ancestry and its own descendants (its subshells carry its command line, which names the payload)
snap=$($PS_LIST)
busy=$(awk -v me="$$" '
  { pid[NR] = $1; ppid[$1] = $2; args = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", args); a[$1] = args }
  END {
    for (p = me; p != "" && p != 0 && p != 1; p = ppid[p]) anc[p] = 1
    for (i = 1; i <= NR; i++) {
      q = pid[i]; if (q in anc) continue
      d = 0; for (x = q; x != "" && x != 0 && x != 1; x = ppid[x]) if (x == me) { d = 1; break }
      if (d) continue
      s = a[q]
      if (s ~ /(^|\/)(v0e_[A-Za-z0-9_]+|v0d_[A-Za-z0-9_]+|run_v0e|run_route|night_batch|v0f_[A-Za-z0-9_]+|v0q_[A-Za-z0-9_]+|v0p_[A-Za-z0-9_]+)\.sh( |$)/ \
          || s ~ /(^|\/)(llama-[a-z-]+|test-backend-ops)( |$)/) print q " " s
    }
  }' <<< "$snap")
[ -z "$busy" ] || refuse "busy: $(echo "$busy" | head -3 | cut -c1-160 | tr '\n' ';')"

D=$BR/npu-dev/$STAGE/$RUN
[ ! -e "$D" ] || { D=; refuse "evidence directory $BR/npu-dev/$STAGE/$RUN already exists"; }
mkdir -p "$D" || { D=; refuse "cannot create the evidence directory"; }
memavail() { awk '/^MemAvailable:/ {print int($2 / 1024)}' "$MEMINFO"; }
log() { echo "$(date -Is) $*" >> "$D/run.txt"; }
log "START stage=$STAGE run=$RUN boot=$BOOT test=$TEST timeout=$TO floor_mib=$FLOOR stall_s=$STALL expect_dsp=$EXPECT_DSP"
log "COMMAND $(printf '%q ' "${CMD[@]}")"
for e in "${ENVS[@]}"; do log "ENV $e"; done

# preflight checks that need the directory
$JOURNAL -k -n 1 --no-pager -q > /dev/null 2>&1 || refuse "the kernel journal is not readable"
if [ "$CHECK_SVC" = default ]; then
  ps -eo args= | grep -q '^/bin/bash /home/arduino/v0/monitor/health_sampler\.sh' || refuse "the campaign health sampler is not running"
  ps -eo args= | grep -q '^/bin/bash /home/arduino/v0/npu_stall_watchdog\.sh' || refuse "the campaign NPU stall watchdog is not running"
else $CHECK_SVC || refuse "the campaign sampler or watchdog is not running"; fi
m=$(memavail); [ -n "$m" ] && [ "$m" -gt "$FLOOR" ] || refuse "MemAvailable ${m:-?} MiB not above the floor $FLOOR MiB"
for h in "${HASHES[@]}"; do [ -f "$h" ] || refuse "--hash $h: not a file"; log "HASH $(sha256sum "$h")"; done
ka_file=$(echo "$KAUDIT" | awk '{print $NF}'); [ -f "$ka_file" ] && log "KAUDIT $(sha256sum "$ka_file")"
log "PREFLIGHT ok: exclusive, journal readable, sampler and watchdog running, MemAvailable $m MiB"

# run
envargs=(); for e in "${ENVS[@]}"; do envargs+=("$e"); done
setsid env "${envargs[@]}" "${CMD[@]}" > "$D/stdout.txt" 2> "$D/stderr.txt" < /dev/null &
PID=$!; PGID=$PID; T0=$(date +%s); log "PID $PID"
printf 't\tmem_avail_mib\n' > "$D/memory.tsv"; : > "$D/stall.txt"
REASON=; declare -A cpu0 since
stop_group() { REASON=$1; log "KILL $1"; kill -TERM -- -"$PGID" 2>/dev/null
  local i; for ((i = 0; i < KILL_GRACE; i++)); do kill -0 -- -"$PGID" 2>/dev/null || return 0; sleep 1; done
  kill -KILL -- -"$PGID" 2>/dev/null; }
group_pids() { $PS_LIST | awk -v g="$PGID" '{print $1}' | while read -r p; do
  [ "$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')" = "$PGID" ] && echo "$p"; done; }
n=0
while kill -0 "$PID" 2>/dev/null; do
  sleep "$TICK"; n=$((n + 1)); now=$(date +%s); m=$(memavail)
  printf '%s\t%s\n' "$now" "${m:-NA}" >> "$D/memory.tsv"
  if [ -z "$m" ] || [ "$m" -lt "$FLOOR" ]; then stop_group FLOOR; break; fi
  if [ $((now - T0)) -ge "$TO" ]; then stop_group TIMEOUT; break; fi
  for p in $(group_pids); do   # stall rule: a FastRPC wait with almost no CPU, continuously for STALL seconds
    [ -r "$PROCROOT/$p/stat" ] || continue
    cpu=$(awk '{print $14 + $15}' "$PROCROOT/$p/stat" 2>/dev/null) || continue
    nf=$(cat "$PROCROOT/$p"/task/*/wchan 2>/dev/null | tr '\0' '\n' | grep -c fastrpc_wait_for_completion)
    if [ $((n % 10)) = 0 ]; then
      prev=${cpu0[$p]:-$cpu}; cpu0[$p]=$cpu
      if [ "$nf" -gt 0 ] && [ $((cpu - prev)) -lt 50 ]; then since[$p]=${since[$p]:-$((now - 10))}
      else unset "since[$p]"; fi
    fi
    if [ -n "${since[$p]:-}" ] && [ $((now - since[$p])) -ge "$STALL" ]; then
      echo "$(date -Is) pid $p: fastrpc wait with < 0.5 core-s per 10 s since $(date -d @"${since[$p]}" -Is)" >> "$D/stall.txt"
      stop_group STALL; break 2
    fi
  done
done
wait "$PID" 2>/dev/null; RC=$?; T1=$(date +%s)
log "END rc=$RC reason=${REASON:-none} duration=$((T1 - T0))s"

# after: DSP journal (fail-closed) and kernel audit
STOPWHY=()
[ -n "$REASON" ] && STOPWHY+=("$REASON")
pids=$(grep -oE '^[^ ]+ PID [0-9]+' "$D/run.txt" | awk '{print $3}')
: > "$D/fastrpc-journal.txt"; jok=1
for p in $pids; do
  $JOURNAL "_PID=$p" "_BOOT_ID=${BOOT//-/}" --since "@$T0" --until "@$((T1 + 60))" --no-pager -q -o short-iso >> "$D/fastrpc-journal.txt" 2>> "$D/journal-err.txt" || jok=0
done
if [ "$jok" != 1 ]; then echo "journal command failed: $(head -c 200 "$D/journal-err.txt")" > "$D/journal-check.txt"; STOPWHY+=("journal read failed")
elif [ "$EXPECT_DSP" = yes ] && ! { grep -q 'Successfully opened file libggml-htp-v75.so' "$D/fastrpc-journal.txt" && grep -q 'CDSP0:' "$D/fastrpc-journal.txt"; }; then
  echo "export lacks the DSP library open line or CDSP0 lines" > "$D/journal-check.txt"; STOPWHY+=("DSP evidence missing")
else echo "ok: $(wc -l < "$D/fastrpc-journal.txt") lines" > "$D/journal-check.txt"; fi
if grep -qiE 'dspqueue[^ ]* .*(fail|error)|CDSP0:.*(fatal|crash|exception|abort)|htp.*(fatal|crash)' "$D/fastrpc-journal.txt"; then
  STOPWHY+=("DSP fault lines in the journal")
fi
# the audit needs a good kernel read after END (kernel_audit.py COVER_S = 150 s): retried every 10 s while it reports
# exactly that missing read, up to 15 tries, as the campaign runner waits
for i in $(seq 1 15); do
  $KAUDIT "$D" > "$D/kernel-audit.txt" 2>&1; ka=$?
  [ "$ka" = 3 ] && grep -q '^missing: no good kernel read' "$D/kernel-audit.txt" && [ "$i" -lt 15 ] || break
  sleep "$((TICK * 10))"
done
case $ka in 0) grep -q '^pass' "$D/kernel-audit.txt" || STOPWHY+=("kernel audit: $(head -1 "$D/kernel-audit.txt")");;
  *) STOPWHY+=("kernel audit rc $ka: $(head -1 "$D/kernel-audit.txt" | cut -c1-120)");; esac

if [ ${#STOPWHY[@]} -gt 0 ]; then V="STOP: $(IFS=';'; echo "${STOPWHY[*]}")"; EC=2
elif [ "$RC" != 0 ]; then V="FAIL: command exit $RC"; EC=1
else V="PASS"; EC=0; fi
echo "$V" > "$D/verdict.txt"; log "VERDICT $V"; echo "$V"
exit $EC
