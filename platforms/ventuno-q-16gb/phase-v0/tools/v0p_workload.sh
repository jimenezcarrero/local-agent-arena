#!/bin/bash
# v0p_workload.sh (D141): run_v0e.sh workload for one pi diagnostic step (OUT, LABEL from the runner; PI_N, PI_MODEL,
# REPLAY_N, REPLAY_REQ from the driver). 1) PI_N pi smoke sessions (pi_smoke.py, labels <LABEL>-pi<k>, through the
# capture proxy) when PI_N > 0; 2) the replay request: REPLAY_REQ if set, else the first captured chat request of this
# step (copied to $OUT/first-request.json); 3) REPLAY_N replays of it straight to the server (:8090). Exit 0 when every
# part ran (low pass rates are results, not errors); 1 when no request could be captured or a replay got HTTP != 200.
set -uo pipefail
PI_N=${PI_N:-0}; REPLAY_N=${REPLAY_N:-20}; PI_MODEL=${PI_MODEL:-local32k}; SMOKE=$HOME/v0/measure/suite/tools/pi_smoke.py
for k in $(seq 1 $PI_N); do
  PI_PROVIDER=bench PI_MODEL=$PI_MODEL python3 $SMOKE $LABEL-pi$k $OUT/pi-smoke.txt > /dev/null 2>&1
  echo "$(date -Is) pi $k: $(grep -h "RESULT $LABEL-pi$k:" $OUT/pi-smoke.txt | tail -1)"
done
req=${REPLAY_REQ:-}
if [ -z "$req" ]; then req=$(ls $OUT/capture/*-request.json 2>/dev/null | head -1); [ -n "$req" ] && cp $req $OUT/first-request.json && req=$OUT/first-request.json; fi
[ -n "$req" ] && [ -s "$req" ] || { echo "$(date -Is) no request to replay"; exit 1; }
echo "$(date -Is) replay request $req sha256 $(sha256sum $req | cut -d' ' -f1)"
python3 $HOME/v0/replay_first.py $req 8090 $REPLAY_N $OUT/replay $LABEL
