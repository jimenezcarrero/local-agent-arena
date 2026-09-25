#!/bin/bash
# handoff.sh <stage> <queue exit code> — resume the campaign's Claude Code
# session headless and ask it to review the stage (review-prompt.md). The
# review writes and pushes a report and stops; it cannot start a stage.
#
# Which session: ~/.config/local-agent-arena/closeout.env, kept out of the repo:
#   CLAUDE_SESSION=<session id>   CLAUDE_CWD=<dir it was started in>
#   CLAUDE_BIN=<path to claude>   (the lingering job's PATH may not include it)
# If anything is missing, or a Claude Code process is already running (two
# writers on one session is unsafe), it starts nothing and says so in
# ~/closeout-status.txt. The board then stays idle, which is the safe failure.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
STAGE="$1"; RC="$2"
case "$STAGE" in J1) NEXT=J2;; J2) NEXT=J3;; J3) NEXT=J4;; *) NEXT=none;; esac
note() { echo "$(date -Is) $STAGE: $*" | tee -a "$HOME/closeout-status.txt"; }
CONF="${CLOSEOUT_CONF:-$HOME/.config/local-agent-arena/closeout.env}"
PROMPT_FILE="${CLOSEOUT_PROMPT:-$HERE/review-prompt.md}"

[ -f "$CONF" ] && . "$CONF"
if [ -z "${CLAUDE_SESSION:-}" ] || [ -z "${CLAUDE_CWD:-}" ] || [ ! -x "${CLAUDE_BIN:-}" ]; then
  note "review NOT started: $CONF is missing CLAUDE_SESSION, CLAUDE_CWD or CLAUDE_BIN. Run 'claude --resume' and ask for the $STAGE review."
  exit 1
fi
if [ -z "${ALLOW_CLAUDE:-}" ] && pgrep -x claude >/dev/null; then
  note "review NOT started: Claude Code is already running on this board. Ask that session for the $STAGE review."
  exit 1
fi
PROMPT="$(sed -e "s/{STAGE}/$STAGE/g" -e "s/{NEXT}/$NEXT/g" -e "s/{RC}/$RC/g" "$PROMPT_FILE")"
note "headless review started (session ${CLAUDE_SESSION:0:8})"
cd "$CLAUDE_CWD" && timeout 60m "$CLAUDE_BIN" -p --resume "$CLAUDE_SESSION" \
  --permission-mode auto "$PROMPT" < /dev/null > "$HOME/closeout-review-$STAGE.log" 2>&1
note "review finished, exit=$? (its reply: ~/closeout-review-$STAGE.log)"
