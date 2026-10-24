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
  # inventory (review of b0cec52): every recorded probe and lifetime present, one-to-one
  mv $d/probes $d/probes.x; mkdir $d/probes; bash $R $d "$V0T" > $T/out 2>&1; rc=$?; rm -rf $d/probes; mv $d/probes.x $d/probes
  ok "$cfg: all probes removed is refused, not a smaller success" '[ $rc = 2 ] && grep -q "probes in probes/ are not the ones status.txt records" $T/out && ! grep -q "^same" $T/out'
  p1=$(ls -d $d/probes/probe-*/ | head -1); mv $p1 $T/p1.x; bash $R $d "$V0T" > $T/out 2>&1; rc=$?; mv $T/p1.x $p1
  ok "$cfg: one probe removed is refused" '[ $rc = 2 ] && grep -q "probes in probes/" $T/out'
  mv $d/lifetimes/$stem-r2-3-2 $T/l1.x; bash $R $d "$V0T" > $T/out 2>&1; rc=$?; mv $T/l1.x $d/lifetimes/$stem-r2-3-2
  ok "$cfg: one lifetime removed is refused" '[ $rc = 2 ] && grep -q "lifetimes in lifetimes/ are not the ones status.txt records" $T/out'
  # containment: a log reference leaving runs/, or a run linked outside the record
  cp $d/lifetimes/$stem-r1-1-1/server-log.txt $T/sl.x; echo "arena1/../../../phase-v1/runs/b9-q20-htp2-r1-a1/server.log" > $d/lifetimes/$stem-r1-1-1/server-log.txt
  bash $R $d "$V0T" > $T/out 2>&1; rc=$?; cp $T/sl.x $d/lifetimes/$stem-r1-1-1/server-log.txt
  ok "$cfg: a server-log reference traversing out of runs/ is refused" '[ $rc = 2 ] && grep -q "resolves outside" $T/out'
  mv $d/runs/$stem-r1-a1 $T/r1.x; ln -s "$PV1/runs/b9-q20-htp2-r1-a1" $d/runs/$stem-r1-a1; bash $R $d "$V0T" > $T/out 2>&1; rc=$?
  rm $d/runs/$stem-r1-a1; mv $T/r1.x $d/runs/$stem-r1-a1
  ok "$cfg: a run linked to B9's record is refused" '[ $rc = 2 ] && grep -q "resolves outside" $T/out'
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

# v1_retry_turns.py on a synthetic B4 work root (v1-b4): one marathon lifetime, retry lines in turns 1 and 2
W=$T/w/v1-b4; Y=b4-q20-htp1; run=$W/arena3/$Y-r1-a3; LT1=$W/lifetimes/$Y-r1-3-1
mkwork() { rm -rf $T/w; mkdir -p $LT1 $run/pisessions; echo "t LIFETIME $Y-r1-3-1: pid 1, covered" > $W/status.txt
  printf 'TURN x #1: PASS\nTURN x #2: PASS\n' > $run/turns.log; touch $run/server.log
  echo "2026-10-24T08:00:00+02:00 START pid=1 boot=b log=$run/server.log" > $W/ledger.txt
  printf '{"type": "message", "timestamp": "2026-10-24T06:00:00.000Z", "message": {"role": "user"}}\n{"type": "message", "timestamp": "2026-10-24T06:10:00.000Z", "message": {"role": "assistant"}}\n{"type": "message", "timestamp": "2026-10-24T06:20:00.000Z", "message": {"role": "user"}}\n' > $run/pisessions/s.jsonl
  ln -s $run/server.log $LT1/server.log; echo "ok: pid 1, 5 lines" > $LT1/journal-check.txt
  printf '2026-10-24T08:00:01+02:00 h p: Successfully opened file libggml-htp-v75.so\n2026-10-24T08:05:00+02:00 h p: CDSP0:[R]: dspqueue_peek failed (1 in a row), retrying\n2026-10-24T08:25:00+02:00 h p: CDSP0:[R]: x (1 in a row), retrying\n2026-10-24T08:06:00+02:00 h p: CDSP0:[R]: other\n' > $LT1/fastrpc-journal.txt; }
rt() { python3 -I $HERE/v1_retry_turns.py "$@" > $T/out 2>&1; echo $? > $T/rc; }; rrc() { cat $T/rc; }
mkwork; rt $W
ok "retry turns: each event with its turn and the count" \
  '[ $(rrc) = 0 ] && grep -q "08:05:00.*$Y-r1-3-1 .*$Y-r1-a3 .*turn 1 " $T/out && grep -q "08:25:00.*turn 2 " $T/out && grep -qx "# 2 logged retry events" $T/out'
rt; ok "retry turns: the work root is required" '[ $(rrc) = 2 ] && grep -q "REFUSED: usage" $T/out'
rt $T/nowhere; ok "retry turns: a missing root is refused (no fallback)" '[ $(rrc) = 2 ] && grep -q "no work root" $T/out && ! grep -q "logged retry events" $T/out'
mkdir -p $T/w2/v1-c9; rt $T/w2/v1-c9; ok "retry turns: an unknown root name is refused" '[ $(rrc) = 2 ] && grep -q "unknown work root name" $T/out'
mkwork; rm $W/ledger.txt; rt $W; ok "retry turns: a root without its ledger is refused" '[ $(rrc) = 2 ] && grep -q "no ledger.txt" $T/out'
mkwork; rm -rf $W/lifetimes/*; rt $W; ok "retry turns: a root without lifetimes is refused" '[ $(rrc) = 2 ] && grep -q "no lifetimes" $T/out'
mkwork; : > $LT1/fastrpc-journal.txt; rt $W
ok "retry turns: an empty journal export is refused, not a zero count" '[ $(rrc) = 2 ] && grep -q "journal export missing or incomplete" $T/out && ! grep -q "logged retry events" $T/out'
mkwork; sed -i '/Successfully opened/d' $LT1/fastrpc-journal.txt; rt $W; ok "retry turns: an export without the library open line is refused" '[ $(rrc) = 2 ] && grep -q "incomplete" $T/out'
mkwork; echo "empty journal export" > $LT1/journal-check.txt; rt $W; ok "retry turns: a capture the driver did not accept is refused" '[ $(rrc) = 2 ] && grep -q "incomplete" $T/out'
mkwork; rm $LT1/fastrpc-journal.txt; rt $W; ok "retry turns: a lifetime without its journal export is refused" '[ $(rrc) = 2 ] && grep -q "incomplete" $T/out'
mkwork; mkdir -p $T/w/v1/arena3/b9-q20-htp2-r1-a3; cp -r $run/. $T/w/v1/arena3/b9-q20-htp2-r1-a3/; ln -sfn $T/w/v1/arena3/b9-q20-htp2-r1-a3/server.log $LT1/server.log
echo "x START pid=2 boot=b log=$T/w/v1/arena3/b9-q20-htp2-r1-a3/server.log" >> $W/ledger.txt; rt $W
ok "retry turns: a server.log linked into another root (B9's) is refused" '[ $(rrc) = 2 ] && grep -q "resolves outside" $T/out'
mkwork; mkdir -p $W/arena3/b9-q20-htp2-r1-a3; cp -r $run/. $W/arena3/b9-q20-htp2-r1-a3/; ln -sfn $W/arena3/b9-q20-htp2-r1-a3/server.log $LT1/server.log
echo "x START pid=2 boot=b log=$W/arena3/b9-q20-htp2-r1-a3/server.log" >> $W/ledger.txt; rt $W
ok "retry turns: a run of another configuration inside the root is refused" '[ $(rrc) = 2 ] && grep -q "resolves outside" $T/out'
mkwork; : > $W/ledger.txt; rt $W; ok "retry turns: a server log not recorded in the ledger is refused" '[ $(rrc) = 2 ] && grep -q "not recorded in the ledger" $T/out'
mkwork; mv $LT1 $W/lifetimes/b9-q20-htp2-r1-3-1; sed -i "s/$Y-r1-3-1/b9-q20-htp2-r1-3-1/" $W/status.txt; rt $W; ok "retry turns: a lifetime of another configuration is refused" '[ $(rrc) = 2 ] && grep -q "is not $Y.s" $T/out'
mkwork; rm -rf $run/pisessions; rt $W; ok "retry turns: a marathon without its pi session is refused" '[ $(rrc) = 2 ] && grep -q "0 pi user messages for 2 turns" $T/out'
mkwork; echo "2026-10-24T07:59:00+02:00 h p: CDSP0:[R]: y (1 in a row), retrying" >> $LT1/fastrpc-journal.txt; rt $W
ok "retry turns: an event outside every turn is refused, not listed as unknown" '[ $(rrc) = 2 ] && grep -q "outside every turn" $T/out'
# review of 687ffbe: turn evidence required by the arena, the lifetime inventory one-to-one
mkwork; rm $run/turns.log; rt $W; ok "retry turns: a marathon without turns.log is refused, not labelled one-turn" '[ $(rrc) = 2 ] && grep -q "no turn records" $T/out && ! grep -q "turn -" $T/out'
mkwork; : > $run/turns.log; rt $W; ok "retry turns: a marathon with an empty turns.log is refused" '[ $(rrc) = 2 ] && grep -q "no turn records" $T/out'
mkwork; : > $run/pisessions/s.jsonl; rt $W; ok "retry turns: a marathon with an empty session is refused" '[ $(rrc) = 2 ] && grep -q "0 pi user messages" $T/out'
# a second lifetime (arena 1, one turn), recorded in status and ledger, with one event
mk2() { mkwork; r2=$W/arena1/$Y-r1-a1; L2=$W/lifetimes/$Y-r1-1-1; mkdir -p $r2 $L2; touch $r2/server.log; ln -s $r2/server.log $L2/server.log
  cp $LT1/journal-check.txt $L2/; printf '2026-10-24T07:00:01+02:00 h p: Successfully opened file libggml-htp-v75.so\n2026-10-24T07:01:00+02:00 h p: CDSP0:[R]: z (1 in a row), retrying\n' > $L2/fastrpc-journal.txt
  echo "t LIFETIME $Y-r1-1-1: pid 2, covered" >> $W/status.txt; echo "2026-10-24T07:00:00+02:00 START pid=2 boot=b log=$r2/server.log" >> $W/ledger.txt; }
mk2; rt $W; ok "retry turns: two lifetimes, arena 1's event labelled -, three events" '[ $(rrc) = 0 ] && grep -q "07:01:00.*$Y-r1-1-1 .*turn - " $T/out && grep -qx "# 3 logged retry events" $T/out'
mk2; rm -rf $L2; rt $W; ok "retry turns: a recorded lifetime removed is refused, not a smaller count" '[ $(rrc) = 2 ] && grep -q "not the ones status.txt records" $T/out && ! grep -q "logged retry events" $T/out'
mk2; sed -i '$d' $W/status.txt; rt $W; ok "retry turns: a lifetime status.txt does not record is refused" '[ $(rrc) = 2 ] && grep -q "not the ones status.txt records" $T/out'
mk2; echo "x START pid=3 boot=b log=$W/arena1/$Y-r2-a1/server.log" >> $W/ledger.txt; rt $W
ok "retry turns: a ledger server start without its lifetime is refused" '[ $(rrc) = 2 ] && grep -q "not the ledger.s server starts one-to-one" $T/out'
mkwork; echo "2026-10-24T08:30:00+02:00 START pid=7 boot=b log=$run/server.log" >> $W/ledger.txt; rt $W
ok "retry turns: a second start (another PID) on the same log is refused, not collapsed" '[ $(rrc) = 2 ] && grep -q "not the ledger.s server starts one-to-one" $T/out && ! grep -q "logged retry events" $T/out'
if [ -d "$HOME/bench-runs/v1/lifetimes" ]; then
  ok "retry turns: B9's work root gives B9's committed list" \
    '[ "$(python3 -I $HERE/v1_retry_turns.py $HOME/bench-runs/v1)" = "$(cat "$PV1/checks/dsp-retry-events.txt")" ]'
fi
echo "$pass passed, $fail failed"; [ $fail = 0 ]
