#!/bin/bash
# tests for v0p_workload.sh (D142): fake pi_smoke, replay and /props; checks exit status and the WORKLOAD line.
W=${W:-$(cd "$(dirname "$0")" && pwd)/v0p_workload.sh}; fails=0
case1() { local name=$1 want=$2; shift 2
  T=$(mktemp -d); export OUT=$T/out LABEL=v0p-DX; mkdir -p $OUT/capture
  printf '%s' '{"messages":[]}' > $OUT/capture/0001-request.json; echo data > $OUT/capture/0001-response.txt; echo '{}' > $OUT/capture/0001-meta.json
  echo '{"default_generation_settings":{}}' > $T/props.json
  cat > $T/smoke.sh <<'S'
#!/bin/bash
case ${SMOKE_MODE:-ok} in ok) echo "RESULT $1: pi smoke FAIL (1/7 checks)" >> $2; exit 1;; crash) exit 7;; noresult) exit 0;; esac
S
  cat > $T/replay.sh <<'R'
#!/bin/bash
mkdir $4 || exit 2; n=$3; [ "${REPLAY_MODE:-ok}" = short ] && n=$((n-1)); for i in $(seq 1 $n); do echo '{}' >> $4/replay.jsonl; done
[ "${REPLAY_MODE:-ok}" = error ] && { echo "RESULT $5: first-reply tool calls 0/$3 (no_tool 0, timeout 0, error $3)"; exit 1; }
echo "RESULT $5: first-reply tool calls 2/$3 (no_tool $(($3-2)), timeout 0, error 0)"
R
  chmod +x $T/smoke.sh $T/replay.sh
  [ -n "${OUT_NORESP:-}" ] && : > $OUT/capture/0001-response.txt
  env SMOKE=$T/smoke.sh REPLAY=$T/replay.sh PROPS_URL=file://$T/props.json PI_N=2 REPLAY_N=3 "$@" bash $W > $T/out.txt 2>&1; local rc=$?
  if [ $rc = $want ]; then echo "ok   $name (rc $rc): $(tail -1 $T/out.txt | cut -c1-110)"; else echo "FAIL $name (rc $rc want $want)"; tail -3 $T/out.txt; fails=$((fails+1)); fi
  rm -rf $T; }
case1 complete 0
case1 pi-client-crash 1 SMOKE_MODE=crash
case1 pi-missing-result 1 SMOKE_MODE=noresult
case1 replay-error 1 REPLAY_MODE=error
case1 replay-short 1 REPLAY_MODE=short
OUT_NORESP=1 case1 no-capture-response 1 PI_N=0
case1 replay-sha-mismatch 1 REPLAY_REQ=/etc/hostname REPLAY_SHA=0000
case1 no-props 1 PROPS_URL=file:///nonexistent
echo "failures: $fails"; exit $fails
