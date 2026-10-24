#!/bin/bash
# test_v1_post.sh — offline tests of the post-batch helpers with explicit roots (v1-plan-4B.txt section 4.4):
# v1_replay_monitor.sh on B9's committed record and on b4/ and a32/ layouts made from it (stems renamed, the same
# monitor export), each missing or foreign input refused without reading B9's record; v1_retry_turns.py on a synthetic
# work root, and refusing a missing root, lifetimes or journal.
set -u
HERE=$(dirname "$(readlink -f "$0")"); PV1=$(dirname "$HERE"); V0T=$(readlink -f "$PV1/../phase-v0/tools")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
R=$HERE/v1_replay_monitor.sh

# B9's record through the new entry point
bash $R "$PV1" "$V0T" > $T/out 2>&1; rc=$?
ok "B9's record replays through the new entry point: 45/45, as committed" \
  '[ $rc = 0 ] && [ $(grep -c "^same" $T/out) = 45 ] && [ "$(grep -c "^same" "$PV1/checks/monitor-replay.txt")" = 45 ]'

# a record for <cfg>: B9's lifetimes, probes, status, runs and monitor, its stem renamed
mkrec() { local cfg=$1 stem=$2 d=$T/phase-v1/$1; rm -rf $d; mkdir -p $d/batch $d/lifetimes $d/runs
  cp -r "$PV1/monitor" "$PV1/probes" $d/
  sed "s/b9-q20-htp2/$stem/g" "$PV1/batch/status.txt" > $d/batch/status.txt
  for lt in "$PV1"/lifetimes/*/; do n=$(basename $lt); n=${n/b9-q20-htp2/$stem}; mkdir -p $d/lifetimes/$n
    for f in run.txt memfloor-admit.txt kernel-audit.txt server-log.txt; do sed "s/b9-q20-htp2/$stem/g" $lt/$f > $d/lifetimes/$n/$f; done; done
  for r in "$PV1"/runs/*/; do n=$(basename $r); cp -r $r $d/runs/${n/b9-q20-htp2/$stem}; done; }
for c in "b4 b4-q20-htp1" "a32 nh4-q40-a32"; do set -- $c; cfg=$1; stem=$2
  mkrec $cfg $stem; d=$T/phase-v1/$cfg
  bash $R $d "$V0T" > $T/out 2>&1; rc=$?
  ok "$cfg: its own record replays (45 verdicts, its own lifetimes)" '[ $rc = 0 ] && [ $(grep -c "^same" $T/out) = 45 ] && grep -q "^same      $stem-r1-1-1 coverage" $T/out'
  mv $d/monitor $d/monitor.x; bash $R $d "$V0T" > $T/out 2>&1; rc=$?; mv $d/monitor.x $d/monitor
  ok "$cfg: no monitor export is refused (exit 2, nothing replayed)" '[ $rc = 2 ] && grep -q "no monitor export" $T/out && ! grep -q "^same" $T/out'
  mv $d/lifetimes $d/lifetimes.x; bash $R $d "$V0T" > $T/out 2>&1; rc=$?; mv $d/lifetimes.x $d/lifetimes
  ok "$cfg: no lifetimes are refused" '[ $rc = 2 ] && grep -q "no lifetimes" $T/out'
  mv $d/batch/status.txt $d/batch/s.x; bash $R $d "$V0T" > $T/out 2>&1; rc=$?; mv $d/batch/s.x $d/batch/status.txt
  ok "$cfg: no status is refused" '[ $rc = 2 ] && grep -q "no batch/status.txt" $T/out'
  echo "2026-10-24T00:00:00+02:00 START b9-q20-htp2-r1 1" >> $d/batch/status.txt; bash $R $d "$V0T" > $T/out 2>&1; rc=$?
  ok "$cfg: a status naming another configuration is refused" '[ $rc = 2 ] && grep -q "names another configuration" $T/out'
  sed -i '$d' $d/batch/status.txt; mv $d/lifetimes/$stem-r1-1-1 $d/lifetimes/b9-q20-htp2-r1-1-1
  bash $R $d "$V0T" > $T/out 2>&1; rc=$?; mv $d/lifetimes/b9-q20-htp2-r1-1-1 $d/lifetimes/$stem-r1-1-1
  ok "$cfg: a lifetime of another configuration is refused" '[ $rc = 2 ] && grep -q "is not $stem.s" $T/out'
  sed -i 's/L_min_kB=[0-9]*/L_min_kB=1/' $d/lifetimes/$stem-r1-1-1/memfloor-admit.txt; bash $R $d "$V0T" > $T/out 2>&1; rc=$?
  ok "$cfg: a recorded verdict the export does not reproduce is DIFFERENT (exit 1)" '[ $rc = 1 ] && grep -q "^DIFFERENT $stem-r1-1-1 memory admission" $T/out'
done
bash $R $T/phase-v1/nothing "$V0T" > $T/out 2>&1; rc=$?
ok "a missing record root is refused" '[ $rc = 2 ] && grep -q "no record" $T/out'
mkdir -p $T/phase-v1/c9; bash $R $T/phase-v1/c9 "$V0T" > $T/out 2>&1; rc=$?
ok "an unknown record name is refused" '[ $rc = 2 ] && grep -q "unknown record" $T/out'
bash $R $T/phase-v1/b4 > $T/out 2>&1; rc=$?
ok "the phase-v0 tools root is required" '[ $rc = 2 ] && grep -q usage $T/out'
bash $R $T/phase-v1/b4 $T > $T/out 2>&1; rc=$?
ok "a tools root without memfloor.py and kernel_audit.py is refused" '[ $rc = 2 ] && grep -q "no memfloor.py" $T/out'

# v1_retry_turns.py on a synthetic work root: one marathon lifetime, retry lines in turns 1 and 2, one before the session
W=$T/work; run=$W/arena3/x-r1-a3; mkdir -p $W/lifetimes/x-r1-3-1 $run/pisessions
printf 'TURN x #1: PASS\nTURN x #2: PASS\n' > $run/turns.log; touch $run/server.log
printf '{"type": "message", "timestamp": "2026-10-24T06:00:00.000Z", "message": {"role": "user"}}\n{"type": "message", "timestamp": "2026-10-24T06:10:00.000Z", "message": {"role": "assistant"}}\n{"type": "message", "timestamp": "2026-10-24T06:20:00.000Z", "message": {"role": "user"}}\n' > $run/pisessions/s.jsonl
ln -s $run/server.log $W/lifetimes/x-r1-3-1/server.log
printf '2026-10-24T08:05:00+02:00 h p: CDSP0:[R]: dspqueue_peek failed (1 in a row), retrying\n2026-10-24T08:25:00+02:00 h p: CDSP0:[R]: x (1 in a row), retrying\n2026-10-24T07:59:00+02:00 h p: CDSP0:[R]: y (1 in a row), retrying\n2026-10-24T08:06:00+02:00 h p: CDSP0:[R]: other\n' > $W/lifetimes/x-r1-3-1/fastrpc-journal.txt
out=$(python3 -I $HERE/v1_retry_turns.py $W 2>&1); rc=$?
ok "retry turns: each event with its turn (1, 2, and ? before the first message), the count" \
  '[ $rc = 0 ] && echo "$out" | grep -q "08:05:00.*x-r1-3-1 .*x-r1-a3 .*turn 1 " && echo "$out" | grep -q "08:25:00.*turn 2 " && echo "$out" | grep -q "07:59:00.*turn ? " && echo "$out" | grep -qx "# 3 logged retry events"'
python3 -I $HERE/v1_retry_turns.py > $T/out 2>&1; rc=$?
ok "retry turns: the work root is required" '[ $rc = 2 ] && grep -q "REFUSED: usage" $T/out'
python3 -I $HERE/v1_retry_turns.py $T/nowhere > $T/out 2>&1; rc=$?
ok "retry turns: a root without lifetimes is refused (no fallback)" '[ $rc = 2 ] && grep -q "no lifetimes" $T/out && ! grep -q "logged retry events" $T/out'
rm $W/lifetimes/x-r1-3-1/fastrpc-journal.txt; python3 -I $HERE/v1_retry_turns.py $W > $T/out 2>&1; rc=$?
ok "retry turns: a lifetime without its journal export is refused" '[ $rc = 2 ] && grep -q "journal export or server log missing" $T/out'
if [ -d "$HOME/bench-runs/v1/lifetimes" ]; then
  ok "retry turns: B9's work root gives B9's committed list" \
    '[ "$(python3 -I $HERE/v1_retry_turns.py $HOME/bench-runs/v1)" = "$(cat "$PV1/checks/dsp-retry-events.txt")" ]'
fi
echo "$pass passed, $fail failed"; [ $fail = 0 ]
