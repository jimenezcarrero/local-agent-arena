#!/bin/bash
# TEMPLATE: copy into platforms/<machine>/<phase>/, then set TAGS and QUEUE for
# that phase. It commits results into the folder it lives in.
# publish_results.sh — runs next to a phase queue (QUEUE=run_headless.sh by default). Whenever a model's ladder
# ends (a "=== <tag> done" line, or a GATE stop), copy that model's results into
# this folder, commit them on the current branch and push. It only ever adds files
# under phase-a/, so it never changes anything the running queue is using.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
LEDGER="${BENCH_WORK:-$HOME/bench-runs}/results.txt"
TAGS="${TAGS:?set TAGS to the run tags for this phase}"
cd "$REPO" || exit 1
# only ledger lines written after this publisher started count as "finished"
START=$(( $(wc -l < "$LEDGER" 2>/dev/null || echo 0) + 1 ))

publish() {
  local tag="$1"
  # the LAST block for this tag, so a tag that runs again publishes its new results
  awk -v t="$tag" '
    index($0, "=== " t "  ctx=") {on=1; buf=""}
    on && (/ RESULT /||/ GATE /||/^=== /) {buf=buf $0 "\n"}
    on && (index($0, "=== " t " done") || index($0, "GATE " t ":")) {out=buf; on=0}
    END {printf "%s", out}
  ' "$LEDGER" | sed -E 's/^[0-9T:+-]+ //' >> "$HERE/results.txt"
  for d in "${BENCH_WORK:-$HOME/bench-runs}"/arena*/"$tag"-a*; do
    [ -d "$d" ] || continue
    local out="$HERE/runs/$(basename "$d")"
    mkdir -p "$out"
    cp "$d"/env.txt "$d"/turns.log "$d"/pytest*.log "$d"/server*.log "$out"/ 2>/dev/null
  done
  local summary; summary=$(grep -E "RESULT $tag-|GATE $tag:" "$HERE/results.txt" | sed -E 's/ avg_power=.*//' | cut -c1-120)
  git add "$HERE"
  git commit -q -m "$(basename "$HERE"): $tag results

$summary

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NsDPrjxWYvcNbs2s3CjmKL"
  git push -q origin HEAD 2>&1 | grep -v '^remote:' || true
  echo "$(date -Is) published $tag"
}

for tag in $TAGS; do
  until tail -n +"$START" "$LEDGER" 2>/dev/null | grep -qE "=== $tag done|GATE $tag:"; do
    ps -eo args | grep -qE "^/bin/bash .*${QUEUE:?set QUEUE to the queue script for this phase}" || { echo "$(date -Is) queue gone before $tag finished"; exit 1; }
    sleep 60
  done
  publish "$tag"
done
echo "$(date -Is) all Phase A models published"
