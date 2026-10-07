#!/bin/bash
# v0d_runner.sh — shared step runner for V0d sequences (Codex review 14:08Z findings 2-3). Source after v0d_lib.sh and after
# defining: PH (phase), O (~/bench-runs/v0/$PH), BASE (baseline probe command), say(), killall_srv().
# Every outcome goes through classify() + decide(); EVIDENCE always stops. Faults (HANG, DEVFAULT) from any step, probes
# included, are appended to $O/faults.txt (the fault history reported with the results).
# Overridable for tests: RUN_ROUTE, RUN_V0C, PROBE_WAIT (s between probes), SET_PAUSE (s between admission steps).
RUN_ROUTE=${RUN_ROUTE:-$HOME/v0/run_route.sh}; RUN_V0C=${RUN_V0C:-$HOME/v0/run_v0c.sh}
MEMFLOOR=${MEMFLOOR:-$HOME/v0/memfloor.py}; PROBE_WAIT=${PROBE_WAIT:-900}; SET_PAUSE=${SET_PAUSE:-180}; FAULT_CAP=${FAULT_CAP:-3}
nfaults() { local n; n=$(grep -c . "$O/faults.txt" 2>/dev/null); echo "${n:-0}"; }
# Inside an admission set (SET_BASE set by admit_set) every fault, probe or measured step, counts toward the set's D68
# budget (D89, Codex review 15:58Z); the exploratory cap applies outside sets only.
setfaults() { echo $(( $(nfaults) - ${SET_BASE:-0} )); }
fault() { mkdir -p "$O"; echo "$(date -Is) $1 $2" >> "$O/faults.txt"; say "FAULT $2 in $1 (faults so far: $(nfaults))"
  [ -z "${SET_BASE:-}" ] && [ "$(nfaults)" -ge "$FAULT_CAP" ] && { say "STOP: fault cap $FAULT_CAP reached"; exit 5; }; true; }
# ready [now|wait]: baseline probe until PASS (13 tries)
ready() { local i lab wd0 rc c a
  for i in $(seq 1 13); do [ $i = 1 ] && [ "${1:-wait}" = now ] || sleep $PROBE_WAIT
    lab=probe-$(date +%H%M%S); wd0=$(wdcount)
    timeout -k 60 900 $RUN_ROUTE $lab $PH --depths 512 --nctx 40960 -- $BASE > /dev/null 2>&1; rc=$?; killall_srv
    c=$(classify $O/$lab $rc $wd0); a=$(decide $c 1 probe); say "PROBE $lab: $c -> $a"
    case $a in next) return 0;;
      fault) fault $lab $c; [ -n "${SET_BASE:-}" ] && [ "$(setfaults)" -ge 2 ] && { say "PROBE $lab: second fault in the admission set"; return 3; };;
      retry_later) ;; *) say "STOP: probe $lab $c"; exit 2;; esac
  done; say "STOP: NPU not ready after 13 probes"; exit 1; }
# step_once <label> <speed|tools> <depths> <timeout> <cmd...>: one measured run; prints the class
step_once() { local lab=$1 kind=$2 dep=$3 to=$4; shift 4; local wd0=$(wdcount) rc
  if [ $kind = speed ]; then timeout -k 60 $to $RUN_ROUTE $lab $PH --depths $dep --nctx 40960 -- "$@" > /dev/null 2>&1; rc=$?
  else PHASE=$PH timeout -k 60 $to $RUN_V0C $lab llama 0 -- "$@" > /dev/null 2>&1; rc=$?; fi
  killall_srv; classify $O/$lab $rc $wd0; }
# explore <label> <probe|none> <cmd...>: exploratory single run (512/8K/16K); returns 0 unless the sequence must stop
explore() { local lab=$1 pre=$2; shift 2; local attempt c a
  for attempt in 1 2; do [ $pre = probe ] && ready now
    say "START $lab (attempt $attempt)"; c=$(step_once $lab speed 512,8192,16384 3600 "$@"); a=$(decide $c $attempt explore)
    say "END $lab: $c -> $a | $(summary $O/$lab)"
    case $a in
      next) [ $pre = probe ] || sleep $SET_PAUSE; return 0;;
      fault) mv $O/$lab $O/$lab-fault; fault $lab $c; ready wait; return 0;;
      recover_retry) mv $O/$lab $O/$lab-loadfail1; ready wait;;
      skip) mv $O/$lab $O/$lab-loadfail2; say "SKIP $lab: clean load failure twice (does not map)"; return 0;;
      *) say "STOP: $lab $c"; exit 2;;
    esac; done; }
# admit_set <name> <cap MiB> <probe|none> <cmd...>: D68 admission set = warmup, r1-r3 (512/8K/16K/32K), tool gates; each
# PASS step must also pass memfloor --admit. Fault budget (D89): every fault after the set starts counts, whether in a
# measured step, a readiness probe before a step, or a recovery probe. The first fault ends that attempt; the whole set
# restarts once after recovery. A second fault anywhere -> not eligible (return 3). A clean load failure is retried once
# after recovery; twice -> stop. Returns 0 if admitted, 3 if not eligible.
admit_set() { local name=$1 cap=$2 pre=$3; shift 3; local set step lab c a attempt kind dep to f0
  SET_BASE=$(nfaults)
  for set in 1 2; do say "SET $name attempt $set"; f0=$(setfaults)
    for step in warmup r1 r2 r3 tools; do
      for attempt in 1 2; do
        [ $pre = probe ] && ready now
        [ "$(setfaults)" -gt "$f0" ] && break
        lab=$name-s$set-$step; [ $attempt = 2 ] && lab=$lab-retry
        if [ $step = tools ]; then kind=tools; dep=-; to=9000; else kind=speed; dep=512,8192,16384,32768; to=5400; fi
        say "START $lab"; c=$(step_once $lab $kind $dep $to "$@"); a=$(decide $c $attempt admit)
        say "END $lab: $c -> $a | $(summary $O/$lab)"
        case $a in
          next) if python3 $MEMFLOOR --admit $cap $O/$lab > $O/$lab/memfloor-admit.txt 2>&1; then say "MEM $lab: $(tail -1 $O/$lab/memfloor-admit.txt)"
                else say "STOP: MEM $lab: $(tail -1 $O/$lab/memfloor-admit.txt)"; exit 3; fi
                [ $pre = probe ] || sleep $SET_PAUSE; break;;
          recover_retry) ready wait;;
          fault) fault $lab $c; break;;
          *) say "STOP: $lab $c"; exit 2;;
        esac
        [ "$(setfaults)" -gt "$f0" ] && break
      done
      [ "$(setfaults)" -gt "$f0" ] && break
    done
    if [ "$(setfaults)" = "$f0" ]; then say "SET $name: ADMITTED in attempt $set (set faults: $(setfaults))"; unset SET_BASE; return 0; fi
    [ "$(setfaults)" -ge 2 ] && break
    say "SET $name: fault in attempt 1, restarting the full set after recovery"; ready wait
    [ "$(setfaults)" -ge 2 ] && break
  done; say "SET $name: NOT ELIGIBLE in V0d (second fault in the set; set faults: $(setfaults))"; unset SET_BASE; return 3; }
summary() { echo "$(grep -h '^RESULT' $1/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | awk '!s[$0]++' | paste -sd' ') | $(sed 's/\x1b\[[0-9;]*m//g' $1/server.log 2>/dev/null | grep -aoE '[0-9]+ accepted / *[0-9]+ generated' | awk '{a+=$1; g+=$4} END{if(g>0) printf "acceptance %d/%d = %.2f", a, g, a/g}') $(grep -aoE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+|ggml-hex: [a-z_]+ failed[^ ]*' $1/server.log 2>/dev/null | head -1)"; }
