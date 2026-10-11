#!/bin/bash
# v0p_workload.sh (D141, D142): run_v0e.sh workload for one pi diagnostic step (OUT, LABEL from the runner; PI_N,
# PI_MODEL, REPLAY_N, REPLAY_REQ, REPLAY_SHA from the driver). Fail-closed (Codex review of 15c6fa6, finding 3):
#   0) the server's /props (effective sampling defaults, chat template, model) saved to $OUT/props.json; required
#   1) PI_N pi smoke sessions (labels <LABEL>-pi<k>); each must end with pi_smoke.py rc 0 or 1 AND its own RESULT line
#      in $OUT/pi-smoke.txt (a low pass rate is a result; a crash or a missing result is not)
#   2) the request to replay: REPLAY_REQ (its sha256 must equal REPLAY_SHA) or, without one, the first chat request
#      captured by THIS step's proxy ($OUT/capture, created fresh with the server) that has a non-empty response and a
#      meta record; copied to $OUT/first-request.json
#   3) REPLAY_N replays straight to the server (replay_first.py: fresh $OUT/replay, exactly REPLAY_N tries, no error)
# Last line: "WORKLOAD <LABEL>: pi results <k>/<PI_N>, replays <n>/<REPLAY_N>, request sha256 <sha>". Exit 0 only when
# every part completed; 1 otherwise. Overridable for tests: SMOKE, REPLAY, PROPS_URL.
set -uo pipefail
PI_N=${PI_N:-0}; REPLAY_N=${REPLAY_N:-20}; PI_MODEL=${PI_MODEL:-local32k}
SMOKE=${SMOKE:-python3 $HOME/v0/measure/suite/tools/pi_smoke.py}; REPLAY=${REPLAY:-python3 $HOME/v0/replay_first.py}
PROPS_URL=${PROPS_URL:-http://127.0.0.1:8090/props}
fail() { echo "$(date -Is) WORKLOAD $LABEL FAILED: $*"; exit 1; }
curl -sf -m 30 "$PROPS_URL" -o $OUT/props.json && [ -s $OUT/props.json ] || fail "no /props"
k=0
for i in $(seq 1 $PI_N); do
  PI_PROVIDER=bench PI_MODEL=$PI_MODEL $SMOKE $LABEL-pi$i $OUT/pi-smoke.txt > /dev/null 2>&1; rc=$?
  line=$(grep -h "^RESULT $LABEL-pi$i: pi smoke " $OUT/pi-smoke.txt 2>/dev/null | tail -1)
  { [ $rc = 0 ] || [ $rc = 1 ]; } && [ -n "$line" ] || fail "pi session $i: rc $rc, result '${line:-none}'"
  echo "$(date -Is) pi $i: $line"; k=$((k+1))
done
req=${REPLAY_REQ:-}
if [ -z "$req" ]; then
  for r in $(ls $OUT/capture/*-request.json 2>/dev/null); do b=${r%-request.json}
    [ -s $b-response.txt ] && [ -s $b-meta.json ] && { req=$r; break; }; done
  [ -n "$req" ] || fail "no captured request with a response in $OUT/capture"
  cp $req $OUT/first-request.json; req=$OUT/first-request.json
fi
[ -s "$req" ] || fail "replay request $req missing"
sha=$(sha256sum "$req" | cut -d' ' -f1)
[ -z "${REPLAY_SHA:-}" ] || [ "$sha" = "$REPLAY_SHA" ] || fail "replay request sha256 $sha, expected $REPLAY_SHA"
echo "$(date -Is) replay request $req sha256 $sha"
res=$($REPLAY $req 8090 $REPLAY_N $OUT/replay $LABEL); rrc=$?; echo "$res"
n=$(grep -c . $OUT/replay/replay.jsonl 2>/dev/null)
[ $rrc = 0 ] && [ "${n:-0}" = "$REPLAY_N" ] && [[ "$res" =~ ^RESULT\ $LABEL:\ first-reply\ tool\ calls\ [0-9]+/$REPLAY_N\  ]] \
  || fail "replay rc $rrc, tries ${n:-0}/$REPLAY_N, result '${res:-none}'"
echo "WORKLOAD $LABEL: pi results $k/$PI_N, replays $n/$REPLAY_N, request sha256 $sha"
