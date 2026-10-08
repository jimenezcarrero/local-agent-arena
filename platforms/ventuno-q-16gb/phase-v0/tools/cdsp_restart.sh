#!/bin/bash
# cdsp_restart.sh — installed root-owned as /usr/local/sbin/v0-cdsp-restart by tools/install_cdsp_restart.sh (D91, D92).
# Restarts the compute DSP (the NPU: remoteproc named 26300000.remoteproc) and nothing else. The arduino user may run it
# through sudo without a password and WITHOUT arguments (the sudoers rule allows none). It reads no arguments, no
# environment and no file the arduino user can write. Hardened after the Codex review of #45 (2026-10-07 21:06Z):
#   - expiry: the installer writes EXPIRES below; after it the helper refuses (D92 "only for tonight"; D102 a new owner-installed window)
#   - one restart at a time: non-blocking flock on a root-only lock in /run
#   - fail closed on quiescence: refuses if any process holds /dev/fastrpc-cdsp or /dev/fastrpc-cdsp-secure open
#     (every NPU client, whatever its name), or if that cannot be established (any /proc read error)
#   - the starting state must be "running"; anything else is refused
#   - BEGIN is logged (and the log write must succeed) before the first state change; every write runs in the
#     background with its own 90 s deadline, so a write that blocks in the kernel ends the helper with UNKNOWN (exit 7)
#     instead of hanging it; a later call then refuses (state not "running") and the campaign must stop
#   - one terminal line per call: OK, FAIL, REFUSED or UNKNOWN, with states and duration; if that line cannot be
#     written the helper never returns 0 (exit 8: unaudited) (Codex review of #47, 22:08Z)
#   - an fd entry that is still present but cannot be read is a refusal, not "no client" (same review)
#   - owner choice (a) of D98 (2026-10-08, D102): Qualcomm's cdsprpcd service holds /dev/fastrpc-cdsp permanently, so
#     exactly that daemon is exempt from the quiescence rule: the process that is the unit's MainPID AND runs
#     /usr/sbin/cdsprpcd AND belongs to user fastrpc. Before the restart that daemon must be identified (unit active,
#     all three match), else REFUSED; any other holder still refuses. After the restart the unit must be active again
#     with a verified daemon (same or new PID) and both device nodes present within STEP_S, else FAIL (exit 9).
#     The only service command used is read-only: systemctl show. Root still writes only the cDSP state file.
#   - deadlines are elapsed time, not loop counts (Codex review of #47, 12:15Z): every systemctl query runs under
#     timeout (Q_S, killed 1 s later), every sysfs read under a 5 s timeout (killed 1 s later); each write step ends
#     within STEP_S + 13 s and the post-restart check within STEP_S + 10 s, the bounded reads and queries past the
#     deadline and in the final message included; a timed-out query counts as "not identified", so a stuck
#     systemctl ends in an audited REFUSED (before any change) or FAIL exit 9 (after), never in a silent hang.
# Exit 0 only after stop -> offline -> start -> running.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
# --- constants (tools/test_cdsp_restart.sh rewrites only these lines in a copy under /tmp) ---
EXPIRES=0
NAME=26300000.remoteproc
SYS=/sys/class/remoteproc
PROC=/proc
DEVS="/dev/fastrpc-cdsp /dev/fastrpc-cdsp-secure"
LOG=/var/log/v0-cdsp-restart.log
LOCK=/run/v0-cdsp-restart.lock
NEED_UID=0
STEP_S=90
Q_S=5
UNIT=cdsprpcd.service
DAEMON_EXE=/usr/sbin/cdsprpcd
DAEMON_USER=fastrpc
SYSTEMCTL=/usr/bin/systemctl
DEVROOT=
# --- end of constants ---
now() { date +%s; }
t0=$(now)
rd() { timeout -k 1 5 cat "$1" 2>/dev/null; }                   # every sysfs read is bounded too
log() { echo "$(date -Is) $*" >> "$LOG" && echo "$(date -Is) $*"; }
# terminal line; if it cannot be written the call is unaudited: never report success (exit 8), keep a failure's code
fin() { log "$1 ($(( $(now) - t0 )) s)" && exit "$2"
  echo "AUDIT FAIL: terminal record not written to $LOG ($1); stop the campaign" >&2; [ "$2" = 0 ] && exit 8; exit "$2"; }
[ "$(id -u)" = "$NEED_UID" ] || { echo "must run as root (sudo /usr/local/sbin/v0-cdsp-restart)" >&2; exit 2; }
[ $# = 0 ] || { echo "takes no arguments" >&2; exit 2; }
[ "$EXPIRES" -gt 0 ] 2>/dev/null || { echo "not configured (no expiry); install with install_cdsp_restart.sh" >&2; exit 2; }
[ "$(now)" -lt "$EXPIRES" ] || fin "REFUSED expired at $(date -d @"$EXPIRES" -Is)" 3
exec 9> "$LOCK" || fin "FAIL cannot open lock $LOCK" 3
flock -n 9 || fin "REFUSED another restart is in progress" 4
rp=""
for d in "$SYS"/remoteproc*; do [ "$(rd "$d/name")" = "$NAME" ] && rp=$d && break; done
[ -n "$rp" ] || fin "FAIL no remoteproc named $NAME" 3
# the exempt daemon (D102): unit active, MainPID's executable and owner match; prints the PID, or nothing
# $1: seconds each of its two systemctl queries may take (default Q_S); a query that times out fails the check
sq() { timeout -k 1 "$1" "$SYSTEMCTL" show -p "$2" --value "$UNIT" 2>/dev/null; }
daemon() { local q=${1:-$Q_S} st pid u
  st=$(sq "$q" ActiveState) && [ "$st" = active ] || return 1
  pid=$(sq "$q" MainPID) && [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "$(readlink "$PROC/$pid/exe" 2>/dev/null)" = "$DAEMON_EXE" ] || return 1
  u=$(stat -c %u "$PROC/$pid" 2>/dev/null) && [ "$u" = "$(id -u "$DAEMON_USER" 2>/dev/null)" ] || return 1
  echo "$pid"; }
dpid=$(daemon) || fin "REFUSED $UNIT daemon not identified (unit active, MainPID running $DAEMON_EXE as $DAEMON_USER)" 4
# quiescence: no process other than the exempt daemon may hold a cDSP FastRPC device; any unreadable /proc entry other than a vanished pid fails
holders=""
for p in "$PROC"/[0-9]*; do
  [ -d "$p/fd" ] || continue
  [ "${p##*/}" = "$dpid" ] && continue
  fds=$(ls "$p/fd" 2>/dev/null) || { [ -d "$p" ] && fin "REFUSED cannot inspect $p/fd: quiescence not established" 4; continue; }
  for f in $fds; do
    # an fd that cannot be read is skipped only if it is gone (process exited or fd closed); still present -> refuse
    # skip only when it is established that the fd is gone: the process vanished, or a successful re-listing lacks it
    # (Codex review of #47, 22:16Z: a failed re-listing proves nothing)
    if ! t=$(readlink "$p/fd/$f" 2>/dev/null); then
      [ -d "$p" ] || continue
      lst=$(ls "$p/fd" 2>/dev/null) || { [ -d "$p" ] && fin "REFUSED cannot re-list $p/fd after a failed readlink: quiescence not established" 4; continue; }
      grep -qx "$f" <<< "$lst" && fin "REFUSED cannot inspect $p/fd/$f: quiescence not established" 4
      continue
    fi
    for dev in $DEVS; do [ "$t" = "$dev" ] && holders="$holders ${p##*/}($(rd "$p/comm"))"; done
  done
done
[ -z "$holders" ] || fin "REFUSED cDSP clients open:$holders" 4
[ "$(daemon)" = "$dpid" ] || fin "REFUSED $UNIT daemon changed during the client check" 4
s0=$(rd "$rp/state") || fin "FAIL cannot read $rp/state" 3
[ "$s0" = running ] || fin "REFUSED unexpected starting state '$s0' (expected running)" 4
log "BEGIN $rp ($NAME) state $s0, $UNIT pid $dpid" > /dev/null || { echo "cannot write $LOG; nothing changed" >&2; exit 3; }
# write $1 to the state file in the background; wait up to STEP_S for the write to return and the state to become $2
step() { local cmd=$1 want=$2 w st dl=$(( $(now) + STEP_S ))
  ( echo "$cmd" > "$rp/state" ) 2>/dev/null & w=$!
  while [ "$(now)" -lt "$dl" ]; do
    if ! kill -0 "$w" 2>/dev/null; then
      wait "$w" || fin "FAIL write '$cmd' returned an error (state $(rd "$rp/state"))" 5
      st=$(rd "$rp/state"); [ "$st" = "$want" ] && return 0
    fi
    sleep 1
  done
  kill -0 "$w" 2>/dev/null && fin "UNKNOWN write '$cmd' still blocked after ${STEP_S}s (state $(rd "$rp/state")); stop the campaign" 7
  fin "FAIL state '$(rd "$rp/state")' after '$cmd' (expected $want)" 6; }
step stop offline
step start running
# the daemon must come back (same or new PID) and the device nodes must exist again (D102)
# elapsed-time deadline; each round's queries get at most half the remaining time (capped at Q_S), so the last round
# of queries ends within STEP_S + 4 s, the final message's state read within 6 s more (two queries, each killed at most 1 s after its timeout, plus the 1 s pause)
back=""; dl=$(( $(now) + STEP_S ))
while rem=$(( dl - $(now) )); [ "$rem" -gt 0 ]; do
  q=$(( rem / 2 )); [ "$q" -gt "$Q_S" ] && q=$Q_S; [ "$q" -lt 1 ] && q=1
  np=$(daemon "$q") && { ok=1; for dev in $DEVS; do [ -e "$DEVROOT$dev" ] || ok=0; done; [ $ok = 1 ] && back=$np && break; }
  sleep 1
done
[ -n "$back" ] || fin "FAIL $UNIT not active with a verified daemon and device nodes after the restart (state $(rd "$rp/state")); stop the campaign" 9
fin "OK $rp ($NAME) running -> offline -> running; $UNIT pid $dpid -> $back" 0
