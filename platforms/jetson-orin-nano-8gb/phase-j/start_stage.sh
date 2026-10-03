#!/bin/bash
# start_stage.sh <J1|J2|J3|J4|J5|J7|J8> — run one stage of phase J, then hand back to
# Claude Code for review before anything else runs on the board.
#
#   1. detaches itself and returns at once, so the caller (you, or a Claude
#      review session) can exit
#   2. waits until no Claude Code process is running and the desktop is off:
#      Claude's ~400MB and the desktop's ~1.4GB are part of the margin these
#      runs need
#   3. runs the stage's queue with its publisher, then commits the stage's
#      kernel-recorded OOM exposure
#   4. handoff.sh resumes the campaign's Claude Code session headless with
#      review-prompt.md. The review audits the stage, pushes review-<stage>.md
#      with a go/no-go recommendation, and stops. It never starts a stage: the
#      next one runs only when the user starts it.
#
# Every step appends a line to ~/closeout-status.txt.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
STAGE="${1:?usage: start_stage.sh <J1|J2|J3|J4|J5|J7|J8>}"
case "$STAGE" in J1|J2|J3|J4|J5|J7|J8) ;; *) echo "unknown stage: $STAGE"; exit 2;; esac
note() { echo "$(date -Is) $STAGE: $*" | tee -a "$HOME/closeout-status.txt"; }

# One stage at a time, from queueing through its review (J4 was launched twice;
# the second launch truncated the first one's logs). The lock is an flock on
# ~/.closeout-stage.lock held through file descriptor 9, which every process of
# the stage inherits: this wrapper, the queue, the publisher, each llama-server.
# The kernel releases it only when the last of them exits, so a killed wrapper
# cannot free it while the workload still runs, and no stale lock can exist.
# Two processes are started without fd 9 on purpose: the swap sampler, which
# would outlive a crashed queue, and the review's Claude, which this wrapper
# waits for, still holding the lock.
LOCK="$HOME/.closeout-stage.lock"
if [ "${2:-}" != --detached ]; then
  exec 9>>"$LOCK"
  if ! flock -n 9; then
    echo "REFUSING: a stage is already queued, running or under review ($(cat "$LOCK.info" 2>/dev/null)). One stage at a time."
    exit 2
  fi
  echo "stage $STAGE, queued $(date -Is) by PID $$" > "$LOCK.info"
  setsid nohup "$0" "$STAGE" --detached >> "$HOME/closeout-$STAGE.log" 2>&1 < /dev/null &   # inherits fd 9
  if [ -n "${ALLOW_CLAUDE:-}" ]; then
    echo "Stage $STAGE queued (attended: Claude Code may stay running): it starts once the desktop is off."
  else
    echo "Stage $STAGE queued: it starts once Claude Code has exited and the desktop is off."
  fi
  echo "Log ~/closeout-$STAGE.log, status ~/closeout-status.txt"
  exit 0
fi

# Wait for the desktop (~1.4GB) and, unless ALLOW_CLAUDE=1 (an attended stage,
# for a model small enough that Claude's ~400MB is immaterial), for Claude Code
# to exit. Starting when only Claude had exited let J1 start before headless.
if [ -n "${ALLOW_CLAUDE:-}" ]; then note "queued (attended); waiting for the desktop to stop"
else note "queued; waiting for Claude Code to exit and the desktop to stop"; fi
while { [ -z "${ALLOW_CLAUDE:-}" ] && pgrep -x claude >/dev/null; } || systemctl is-active -q graphical.target; do sleep 30 & wait $!; done
note "starting"
"$HERE/run_closeout.sh" "$STAGE" &
QUEUE_PID=$!
sleep 5   # the publisher checks that the queue is running
STAGE="$STAGE" "$HERE/publish_results.sh" >> "$HOME/closeout-publish-$STAGE.log" 2>&1 &
PUB_PID=$!
wait "$QUEUE_PID"; RC=$?
wait "$PUB_PID"
note "queue exit=$RC; publisher finished"

# Kernel-recorded OOM exposure for exactly this stage's runs. Committed only
# now, after the publisher, so the two never touch the git index at once.
START="$(cat "${BENCH_WORK:-$HOME/bench-runs}/.phase-j-$STAGE.start" 2>/dev/null)"
if [ -n "$START" ]; then
  "$REPO/suite/tools/oom_exposure.py" "$START" > "$HERE/oom-exposure-$STAGE.txt" 2>&1
  note "oom_exposure exit=$? (non-zero: some runs not covered)"
  (cd "$REPO" && git add "$HERE/oom-exposure-$STAGE.txt" \
     && git commit -q -m "phase-j $STAGE: kernel-recorded OOM exposure" \
     && git push -q origin HEAD) || note "exposure commit/push FAILED"
else
  note "no stage start marker: the queue never started (see ~/closeout-$STAGE.log)"
fi

# Why each server restart happened (kill, memory stall, timeout), from the
# restarts.log the harness writes; the OOM audit only sees kernel kills.
if [ -n "$START" ]; then
  tags=$(DRY_RUN=1 "$HERE/run_closeout.sh" "$STAGE" | sed -nE 's/.*run_model\.sh ([^ ]+).*/\1/p')
  dirs=$(for t in $tags; do ls -d "${BENCH_WORK:-$HOME/bench-runs}"/arena*/"$t"-a* 2>/dev/null; done)
  [ -n "$dirs" ] && "$REPO/suite/tools/restart_causes.py" $dirs > "$HERE/restart-causes-$STAGE.txt" 2>&1
  (cd "$REPO" && git add "$HERE/restart-causes-$STAGE.txt" \
     && git commit -q -m "phase-j $STAGE: restart causes" && git push -q origin HEAD) \
     || note "restart-causes commit/push FAILED (or no runs)"
fi

# Other evidence a stage may write into this folder (J8: the holdout audit of its
# marathon and the server-memory samples), committed if present.
ev=$(ls "$HERE/holdout-audit-$STAGE.txt" "$HERE/rss-$STAGE.log" 2>/dev/null)
if [ -n "$ev" ]; then
  (cd "$REPO" && git add $ev && git commit -q -m "phase-j $STAGE: stage evidence" && git push -q origin HEAD) \
    || note "stage evidence commit/push FAILED"
fi

"$HERE/handoff.sh" "$STAGE" "$RC"
