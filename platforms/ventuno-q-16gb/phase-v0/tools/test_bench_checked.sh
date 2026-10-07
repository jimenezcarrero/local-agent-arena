#!/bin/bash
# mocked tests for bench_checked.sh (Codex review of #45 20:32Z finding 2: rc 1 and timeouts must not return success;
# malformed output, health and kernel-audit failures must fail the run). Fake llama-bench, health and audit helpers.
W=${W:-$HOME/v0/bench_checked.sh}; T=$(mktemp -d); fails=0
mkdir -p $T/v0/monitor $T/mon $T/bin
cat > $T/bin/llama-bench <<'B'
#!/bin/bash
row() { echo "| qwen35 4B Q4_0 | 2.21 GiB | 4.21 B | HTP | 99 | HTP0:0 | $1 | $2 |"; }
echo "| model | size | params | backend | ngl | dev | test | t/s |"; echo "| --- | ---: | ---: | --- | --: | --- | ---: | ---: |"
case $FAKE in
  ok) row pp1 "10.53 ± 0.20"; row pp2 "17.88 ± 0.14";;
  rc1) row pp1 "10.53 ± 0.20"; echo "ggml-hex: dspqueue_read failed" >&2; exit 1;;
  hang) row pp1 "10.53 ± 0.20"; sleep 30;;
  short) row pp1 "10.53 ± 0.20";;
  nan) row pp1 "10.53 ± 0.20"; row pp2 "nan ± nan";;
esac
B
printf 'print("summary")\n' > $T/v0/monitor/health_check.py
printf 'import os,sys\nv=os.environ.get("FAKE_HEALTH","pass"); print(v); sys.exit(0 if v=="pass" else 1)\n' > $T/v0/health_verdict.py
printf 'import os,sys\nv=os.environ.get("FAKE_KA","pass"); print(v); sys.exit({"pass":0,"fault":1,"unknown":2}[v])\n' > $T/v0/kernel_audit.py
chmod +x $T/bin/llama-bench; : > $T/mon/run-windows.jsonl
chk() { local name=$1 want=$2; shift 2
  echo "{\"epoch\": $(( $(date +%s) + 600 )), \"kern_read\": \"ok\", \"kern_alert_lines\": 0}" > $T/mon/health-$(date -u +%Y%m%d).jsonl
  env "$@" V0=$T/v0 MEASURE=$HOME/v0/measure MON=$T/mon OUTROOT=$T/out EXCL_PROCS=no-such-proc BENCH_TIMEOUT=3 \
    bash $W $name ph 2 -- $T/bin/llama-bench -m $T/bin/llama-bench > /dev/null 2>&1; local rc=$?
  local res=$(grep -o 'RESULT.*' $T/out/ph/$name/run.txt | tail -1)
  local wres="RESULT FAIL"; [ $want = 0 ] && wres="RESULT PASS"
  if [ $rc = $want ] && [ "${res:0:11}" = "$wres" ]; then echo "ok   $name rc=$rc | $res"
  else echo "FAIL $name rc=$rc want $want | $res"; fails=$((fails+1)); fi; }
chk ok 0 FAKE=ok
chk rc1 1 FAKE=rc1
chk timeout 1 FAKE=hang
chk short 1 FAKE=short
chk nan 1 FAKE=nan
chk health 1 FAKE=ok FAKE_HEALTH=fail
chk kfault 1 FAKE=ok FAKE_KA=fault
chk kunknown 1 FAKE=ok FAKE_KA=unknown
grep -q '"end_epoch": [0-9]' $T/mon/run-windows.jsonl && [ $(grep -c null $T/mon/run-windows.jsonl) = 0 ] && echo "ok   windows registered and closed ($(wc -l < $T/mon/run-windows.jsonl))" || { echo "FAIL windows"; fails=$((fails+1)); }
grep -q "dspqueue_read failed" $T/out/ph/rc1/server.log && echo "ok   stderr kept in server.log for classify()" || { echo "FAIL stderr"; fails=$((fails+1)); }
rm -rf $T; echo "failures: $fails"; exit $fails
