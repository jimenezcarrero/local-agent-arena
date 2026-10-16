#!/bin/bash
# npu_dev_run.sh (NPU dev plan section 7) — the wrapper every executable of every NPU development stage runs under
#   (llama-server, llama-bench, llama-perplexity, test-backend-ops, harnesses). Proposed for review; no NPU stage runs
#   before the review and the owner's approval of that stage.
#
#   npu_dev_run.sh --stage S --run R --timeout SEC [--floor-mib 1536] [--stall-s 120] [--expect-dsp yes|no]
#                  [--declared-peak-mib A,B,..] [--declared-board-mib N]
#                  [--hash PATH]... [--env NAME=VALUE]... -- COMMAND [ARG...]
#
#   Preflight (refuses with exit 3, nothing launched):
#     - a process snapshot that succeeded and is well formed (every line "pid ppid args", this wrapper's own pid in
#       it); exclusivity on it: no campaign driver, admission, session or runner, and no llama-* / test-backend-ops
#       process other than this wrapper's own ancestry and descendants;
#     - the evidence directory ~/bench-runs/npu-dev/S/R does not exist yet (every run is new);
#     - the kernel journal is readable and the campaign's health sampler and NPU stall watchdog run;
#     - MemAvailable above the floor; every --hash PATH exists (its sha256 recorded);
#     - allocation guard (plan section 7): every --declared-peak-mib session figure at or below one session's mappable
#       limit (3,189.61 MiB: HTP_OP_MAX_VMEM_DEFAULT minus the op queue's buffer), and --declared-board-mib at or below
#       MemAvailable minus the floor.
#   Run: COMMAND in its own process group (setsid) with a clean environment: HOME, PATH and LANG=C.UTF-8 plus exactly
#   the --env variables (nothing inherited reaches the NPU, so every backend option is explicit; all recorded).
#   Supervision lasts while any process of the group lives (not just the leader). Every second: the group's members
#   are recorded (each new one as "MEMBER pid args"), MemAvailable is sampled to memory.tsv; below the floor ->
#   SIGTERM to the group, SIGKILL after the grace (FLOOR); elapsed above SEC -> the same (TIMEOUT); the leader gone while
#   members live -> the same (ORPHANS); a member with a thread in fastrpc_wait_for_completion and under 0.5 core-s of
#   CPU per 10 s continuously for --stall-s seconds -> the same (STALL). SIGINT/SIGTERM/SIGHUP to the wrapper -> the same
#   (INTERRUPTED), then the evidence is still collected. A member that lives less than a second can be missed by the
#   membership poll (stated limit).
#   After: the DSP journal of every recorded member in the run window (journalctl _PID=, this boot), fail-closed: a
#   failed read is a STOP; with --expect-dsp yes the export must show the DSP library opened (libggml-htp-v75.so) and
#   DSP-side (CDSP0) lines; any "dspqueue" error, fatal, crash or "failed" DSP line is a fault (with the unpatched master
#   library a dspqueue_peek failure ends the DSP loop, so it is one). Any new NPU-WATCHDOG line of the campaign's stall
#   watchdog during the window is recorded and is a STOP (attribution). The kernel log is audited with the campaign's
#   kernel_audit.py once a good kernel read after END exists (waited for up to 150 s, as the campaign runner does);
#   fault, unknown or missing evidence is a STOP. The group is checked gone before any verdict; a live member is
#   killed and the verdict is a STOP.
#   Verdict (verdict.txt and the exit code): PASS (0: command exit 0, nothing wrong); FAIL (1: the command failed,
#   nothing else wrong); STOP (2: TIMEOUT, FLOOR, STALL, ORPHANS, INTERRUPTED, a DSP or kernel fault, a watchdog
#   intervention, or missing or failed evidence: the stage stops, the configuration is not repeated, the owner is
#   told); REFUSED (3: preflight).
#   Evidence only under ~/bench-runs/npu-dev/S/R/: run.txt (command, environment, times, boot, members, hashes),
#   stdout.txt, stderr.txt, memory.tsv, stall.txt, fastrpc-journal.txt, journal-check.txt, kernel-audit.txt,
#   watchdog.txt, verdict.txt.
#   Overridable for the mocked tests only (run.txt then says TEST): BR (evidence root), PS_LIST (prints "pid ppid
#   args"), MEMINFO, JOURNAL, KAUDIT, CHECK_SVC, WCHAN_GLOB_ROOT (a /proc root), TICK (1 s), KILL_GRACE (10 s), BOOT_ID,
#   WD_STATUS (the watchdog's status file).
set -uo pipefail
STAGE= RUN= TO= FLOOR=1536 STALL=120 EXPECT_DSP=no DPEAK= DBOARD=; HASHES=(); ENVS=()
while [ $# -gt 0 ]; do
  case $1 in
    --stage) STAGE=$2; shift 2;; --run) RUN=$2; shift 2;; --timeout) TO=$2; shift 2;; --floor-mib) FLOOR=$2; shift 2;;
    --stall-s) STALL=$2; shift 2;; --expect-dsp) EXPECT_DSP=$2; shift 2;; --hash) HASHES+=("$2"); shift 2;;
    --declared-peak-mib) DPEAK=$2; shift 2;; --declared-board-mib) DBOARD=$2; shift 2;;
    --env) ENVS+=("$2"); shift 2;; --) shift; break;; *) echo "unknown option $1" >&2; exit 3;;
  esac
done
CMD=("$@")
TEST=no
for v in BR PS_LIST MEMINFO JOURNAL KAUDIT CHECK_SVC WCHAN_GLOB_ROOT TICK KILL_GRACE BOOT_ID WD_STATUS; do [ -n "${!v:-}" ] && TEST=yes; done
BR=${BR:-$HOME/bench-runs}; PS_LIST=${PS_LIST:-ps -eo pid=,ppid=,args=}; MEMINFO=${MEMINFO:-/proc/meminfo}
JOURNAL=${JOURNAL:-journalctl}; KAUDIT=${KAUDIT:-python3 $HOME/v0/kernel_audit.py}; CHECK_SVC=${CHECK_SVC:-default}
PROCROOT=${WCHAN_GLOB_ROOT:-/proc}; TICK=${TICK:-1}; KILL_GRACE=${KILL_GRACE:-10}
BOOT=${BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id)}; WD_STATUS=${WD_STATUS:-$HOME/bench-runs/v0/night/status.txt}
SESSION_LIMIT_MIB=3189.61
D=

refuse() { echo "REFUSED: $*" >&2; [ -n "$D" ] && [ -d "$D" ] && echo "REFUSED: $*" > "$D/verdict.txt"; exit 3; }
[[ "$STAGE" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$RUN" =~ ^[A-Za-z0-9._-]+$ ]] || refuse "--stage and --run must be plain names"
[[ "$TO" =~ ^[0-9]+$ ]] && [ "$TO" -gt 0 ] || refuse "--timeout must be a positive number of seconds"
[[ "$FLOOR" =~ ^[0-9]+$ ]] && [[ "$STALL" =~ ^[0-9]+$ ]] || refuse "--floor-mib and --stall-s must be numbers"
[ "$EXPECT_DSP" = yes ] || [ "$EXPECT_DSP" = no ] || refuse "--expect-dsp must be yes or no"
[ ${#CMD[@]} -gt 0 ] || refuse "no command after --"
for e in "${ENVS[@]}"; do [[ "$e" =~ ^[A-Z_][A-Z0-9_]*=.*$ ]] || refuse "--env '$e' is not NAME=VALUE"; done
[ -z "$DPEAK" ] || [[ "$DPEAK" =~ ^[0-9]+(\.[0-9]+)?(,[0-9]+(\.[0-9]+)?)*$ ]] || refuse "--declared-peak-mib must be numbers"
[ -z "$DBOARD" ] || [[ "$DBOARD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || refuse "--declared-board-mib must be a number"

# exclusivity (before anything is written), on one process snapshot that must have succeeded and be well formed
snap=$($PS_LIST) || refuse "the process snapshot failed"
[ -n "$snap" ] && awk 'NF < 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' <<< "$snap" \
  || refuse "the process snapshot is empty or malformed"
awk -v me="$$" '$1 == me { f = 1 } END { exit !f }' <<< "$snap" || refuse "the process snapshot does not contain this wrapper"
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

[ ! -e "$BR/npu-dev/$STAGE/$RUN" ] || refuse "evidence directory $BR/npu-dev/$STAGE/$RUN already exists"
mkdir -p "$BR/npu-dev/$STAGE/$RUN" || refuse "cannot create the evidence directory"
D=$BR/npu-dev/$STAGE/$RUN
memavail() { awk '/^MemAvailable:/ {print int($2 / 1024)}' "$MEMINFO"; }
log() { echo "$(date -Is) $*" >> "$D/run.txt"; }
log "START stage=$STAGE run=$RUN boot=$BOOT test=$TEST timeout=$TO floor_mib=$FLOOR stall_s=$STALL expect_dsp=$EXPECT_DSP"
log "COMMAND $(printf '%q ' "${CMD[@]}")"
log "ENVIRONMENT clean: HOME PATH LANG=C.UTF-8 and $( [ ${#ENVS[@]} -gt 0 ] && printf '%s ' "${ENVS[@]}" || echo 'nothing else')"

# preflight checks that need the directory
$JOURNAL -k -n 1 --no-pager -q > /dev/null 2>&1 || refuse "the kernel journal is not readable"
if [ "$CHECK_SVC" = default ]; then
  ps -eo args= | grep -q '^/bin/bash /home/arduino/v0/monitor/health_sampler\.sh' || refuse "the campaign health sampler is not running"
  ps -eo args= | grep -q '^/bin/bash /home/arduino/v0/npu_stall_watchdog\.sh' || refuse "the campaign NPU stall watchdog is not running"
else $CHECK_SVC || refuse "the campaign sampler or watchdog is not running"; fi
m=$(memavail); [ -n "$m" ] && [ "$m" -gt "$FLOOR" ] || refuse "MemAvailable ${m:-?} MiB not above the floor $FLOOR MiB"
for h in "${HASHES[@]}"; do [ -f "$h" ] || refuse "--hash $h: not a file"; log "HASH $(sha256sum "$h")"; done
if [ -n "$DPEAK" ]; then
  over=$(awk -v l="$SESSION_LIMIT_MIB" -v p="$DPEAK" 'BEGIN { n = split(p, a, ","); for (i = 1; i <= n; i++) if (a[i] + 0 > l + 0) printf "%s%s", (o++ ? "," : ""), a[i] }')
  [ -z "$over" ] || refuse "allocation guard: declared session peak(s) $over MiB above the session limit $SESSION_LIMIT_MIB MiB"
  log "GUARD declared session peaks $DPEAK MiB within $SESSION_LIMIT_MIB"
fi
if [ -n "$DBOARD" ]; then
  awk -v b="$DBOARD" -v r="$((m - FLOOR))" 'BEGIN { exit !(b + 0 <= r + 0) }' \
    || refuse "allocation guard: declared board peak $DBOARD MiB above MemAvailable minus the floor ($((m - FLOOR)) MiB)"
  log "GUARD declared board peak $DBOARD MiB within $((m - FLOOR))"
fi
ka_file=$(echo "$KAUDIT" | awk '{print $NF}'); [ -f "$ka_file" ] && log "KAUDIT $(sha256sum "$ka_file")"
wd0=$(grep -c 'NPU-WATCHDOG' "$WD_STATUS" 2>/dev/null); wd0=${wd0:-0}
log "PREFLIGHT ok: snapshot valid, exclusive, journal readable, sampler and watchdog running, MemAvailable $m MiB, watchdog lines $wd0"

# run, supervised while any member of its process group lives
envargs=(HOME="$HOME" PATH="$PATH" LANG=C.UTF-8 "${ENVS[@]}")
setsid env -i "${envargs[@]}" "${CMD[@]}" > "$D/stdout.txt" 2> "$D/stderr.txt" < /dev/null &
PID=$!; PGID=$PID; T0=$(date +%s); log "PID $PID"
printf 't\tmem_avail_mib\n' > "$D/memory.tsv"; : > "$D/stall.txt"
REASON=; declare -A cpu0 since member
group_alive() { kill -0 -- -"$PGID" 2>/dev/null; }
stop_group() { [ -z "$REASON" ] && REASON=$1; log "KILL $1"; kill -TERM -- -"$PGID" 2>/dev/null
  local i; for ((i = 0; i < KILL_GRACE; i++)); do group_alive || return 0; sleep 1; done
  kill -KILL -- -"$PGID" 2>/dev/null; sleep 1; }
record_members() { local p a
  while read -r p a; do [ -n "$p" ] || continue
    if [ -z "${member[$p]:-}" ]; then member[$p]=1; log "MEMBER $p $a"; fi
  done < <(ps -eo pid=,pgid=,args= | awk -v g="$PGID" '$2 == g { pid = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); print pid, $0 }'); }
on_signal() { log "SIGNAL $1"; stop_group INTERRUPTED; }
trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal HUP' HUP
trap 'group_alive && kill -KILL -- -"$PGID" 2>/dev/null' EXIT
record_members
n=0
while group_alive && [ -z "$REASON" ]; do
  sleep "$TICK"; n=$((n + 1)); now=$(date +%s); m=$(memavail); record_members
  printf '%s\t%s\n' "$now" "${m:-NA}" >> "$D/memory.tsv"
  if [ -z "$m" ] || [ "$m" -lt "$FLOOR" ]; then stop_group FLOOR; break; fi
  if [ $((now - T0)) -ge "$TO" ]; then stop_group TIMEOUT; break; fi
  if ! kill -0 "$PID" 2>/dev/null && group_alive; then stop_group ORPHANS; break; fi
  for p in "${!member[@]}"; do   # stall rule: a FastRPC wait with almost no CPU, continuously for STALL seconds
    [ -r "$PROCROOT/$p/stat" ] || continue
    cpu=$(awk '{print $14 + $15}' "$PROCROOT/$p/stat" 2>/dev/null) || continue
    nf=$(cat "$PROCROOT/$p"/task/*/wchan 2>/dev/null | tr '\0' '\n' | grep -c fastrpc_wait_for_completion)
    if [ $((n % 10)) = 0 ]; then   # compare with the previous 10 s sample only (the first sample has none)
      if [ -n "${cpu0[$p]:-}" ]; then
        if [ "$nf" -gt 0 ] && [ $((cpu - cpu0[$p])) -lt 50 ]; then since[$p]=${since[$p]:-$((now - 10))}
        else unset "since[$p]"; fi
      fi
      cpu0[$p]=$cpu
    fi
    if [ -n "${since[$p]:-}" ] && [ $((now - since[$p])) -ge "$STALL" ]; then
      echo "$(date -Is) pid $p: fastrpc wait with < 0.5 core-s per 10 s since $(date -d @"${since[$p]}" -Is)" >> "$D/stall.txt"
      stop_group STALL; break 2
    fi
  done
done
wait "$PID" 2>/dev/null; RC=$?; T1=$(date +%s)
trap - INT TERM HUP
if group_alive; then stop_group ORPHANS; fi
log "END rc=$RC reason=${REASON:-none} duration=$((T1 - T0))s members=${#member[@]}"

# after: DSP journal of every member (fail-closed), watchdog attribution, kernel audit
STOPWHY=()
[ -n "$REASON" ] && STOPWHY+=("$REASON")
: > "$D/fastrpc-journal.txt"; : > "$D/journal-err.txt"; jok=1
for p in "${!member[@]}"; do
  $JOURNAL "_PID=$p" "_BOOT_ID=${BOOT//-/}" --since "@$T0" --until "@$((T1 + 60))" --no-pager -q -o short-iso >> "$D/fastrpc-journal.txt" 2>> "$D/journal-err.txt" || jok=0
done
if [ "$jok" != 1 ]; then echo "journal command failed: $(head -c 200 "$D/journal-err.txt")" > "$D/journal-check.txt"; STOPWHY+=("journal read failed")
elif [ "$EXPECT_DSP" = yes ] && ! { grep -q 'Successfully opened file libggml-htp-v75.so' "$D/fastrpc-journal.txt" && grep -q 'CDSP0:' "$D/fastrpc-journal.txt"; }; then
  echo "export lacks the DSP library open line or CDSP0 lines" > "$D/journal-check.txt"; STOPWHY+=("DSP evidence missing")
else echo "ok: ${#member[@]} members, $(wc -l < "$D/fastrpc-journal.txt") lines" > "$D/journal-check.txt"; fi
if grep -qiE 'dspqueue[^ ]* .*(fail|error)|CDSP0:.*(fatal|crash|exception|abort)|htp.*(fatal|crash)' "$D/fastrpc-journal.txt"; then
  STOPWHY+=("DSP fault lines in the journal")
fi
wd1=$(grep -c 'NPU-WATCHDOG' "$WD_STATUS" 2>/dev/null); wd1=${wd1:-0}
if [ "$wd1" -gt "$wd0" ]; then
  grep 'NPU-WATCHDOG' "$WD_STATUS" | tail -n $((wd1 - wd0)) > "$D/watchdog.txt"
  log "WATCHDOG $((wd1 - wd0)) new line(s) during the window (watchdog.txt)"; STOPWHY+=("the campaign stall watchdog intervened")
else : > "$D/watchdog.txt"; fi
for i in $(seq 1 15); do
  $KAUDIT "$D" > "$D/kernel-audit.txt" 2>&1; ka=$?
  [ "$ka" = 3 ] && grep -q '^missing: no good kernel read' "$D/kernel-audit.txt" && [ "$i" -lt 15 ] || break
  sleep "$((TICK * 10))"
done
case $ka in 0) grep -q '^pass' "$D/kernel-audit.txt" || STOPWHY+=("kernel audit: $(head -1 "$D/kernel-audit.txt")");;
  *) STOPWHY+=("kernel audit rc $ka: $(head -1 "$D/kernel-audit.txt" | cut -c1-120)");; esac
group_alive && { stop_group ORPHANS; STOPWHY+=("a group member was still alive at the verdict"); }

if [ ${#STOPWHY[@]} -gt 0 ]; then V="STOP: $(IFS=';'; echo "${STOPWHY[*]}")"; EC=2
elif [ "$RC" != 0 ]; then V="FAIL: command exit $RC"; EC=1
else V="PASS"; EC=0; fi
echo "$V" > "$D/verdict.txt"; log "VERDICT $V"; echo "$V"
exit $EC
