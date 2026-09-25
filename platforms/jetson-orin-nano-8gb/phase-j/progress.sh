#!/bin/bash
# progress.sh — where phase J is, in one screen. Safe to run any time, from the
# console or over SSH; it only reads logs. (Don't start Claude Code to check.)
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LEDGER="${BENCH_WORK:-$HOME/bench-runs}/results.txt"
STATUS="$HOME/closeout-status.txt"

echo "== last events (~/closeout-status.txt)"
if [ -s "$STATUS" ]; then tail -4 "$STATUS" | sed 's/^/   /'; else echo "   none yet"; fi

echo "== steps done per stage"
for st in J1 J2 J3 J4; do
  tags=$(DRY_RUN=1 "$HERE/run_closeout.sh" "$st" | sed -E 's/.*run_model\.sh ([^ ]+).*/\1/')
  total=$(echo "$tags" | wc -l); done_=0; now=""
  for t in $tags; do
    if grep -qE "=== $t done|GATE $t:" "$LEDGER" 2>/dev/null; then done_=$((done_+1))
    elif [ -z "$now" ] && grep -q "=== $t  ctx=" "$LEDGER" 2>/dev/null; then now=$t; fi
  done
  printf "   %s  %2d/%-2d%s\n" "$st" "$done_" "$total" "${now:+   running: $now}"
done

run=$(ls -td "${BENCH_WORK:-$HOME/bench-runs}"/arena*/j-*/ 2>/dev/null | head -1)
if [ -n "$run" ] && pgrep -x llama-server >/dev/null; then
  echo "== current run: $(basename "$run")"
  turns=$(grep -cE '^TURN .*#[0-9]+:' "$run/turns.log" 2>/dev/null); turns=${turns:-0}
  restarts=$(ls "$run"/server_r*.log 2>/dev/null | wc -l)
  last=$(ls -t "$run" | head -1)
  echo "   turns finished: $turns   server restarts: $restarts   last write: $(( ($(date +%s) - $(stat -c %Y "$run/$last")) / 60 )) min ago ($last)"
fi
echo "== last result lines"
grep -E ' RESULT j-| GATE j-' "$LEDGER" 2>/dev/null | tail -3 | sed -E 's/ avg_power=.*//' | cut -c1-150 | sed 's/^/   /'
echo "== memory: $(free -m | awk 'NR==2{print $7}')MB available, swap used $(free -m | awk 'NR==3{print $3}')MB"
