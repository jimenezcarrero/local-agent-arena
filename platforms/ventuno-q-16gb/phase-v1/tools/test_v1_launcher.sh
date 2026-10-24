#!/bin/bash
# test_v1_launcher.sh — offline tests of b4_server.sh and a32_server.sh through v1_launcher.sh (v1-plan-4B.txt section
# 4.3), as test_b9_server.sh: no server, no NPU.
set -u
HERE=$(dirname "$(readlink -f "$0")"); SUITE=$(readlink -f "$HERE/../../../../suite")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
cat > $T/check-ok <<EOF
#!/bin/bash
echo called >> $T/check-calls; echo "OK mock"; exit 0
EOF
cat > $T/check-bad <<EOF
#!/bin/bash
echo called >> $T/check-calls; echo "FAILED identity: model sha256 'x'"; exit 1
EOF
# the exec stand-in: records its argv one per line, and its parent (the launcher's PID: exec keeps it in real use)
cat > $T/exec <<EOF
#!/bin/bash
printf '%s\n' "\$@" > $T/argv; echo \$PPID > $T/ppid
EOF
echo '1b0f3c0a2e5d4f6a8b9c7d1e2f3a4b5c' > $T/boot
chmod +x $T/check-ok $T/check-bad $T/exec
export PB=/pb MB=/mb P=/p M=/m HTPR=/htpr BOOT_ID_FILE=$T/boot EXEC=$T/exec

for cfg in b4 a32; do
  L=$HERE/${cfg}_server.sh; CV=$(echo $cfg | tr a-z A-Z)_CHECK
  case $cfg in
    b4) export FARFD=/farf; build=ff5a2337
        want=$(printf '%s\n' env LD_LIBRARY_PATH=/pb/lib 'ADSP_LIBRARY_PATH=/farf;/pb/lib' GGML_HEXAGON_DEVICES=HTP0:0 \
          GGML_HEXAGON_NHMX=1 /pb/bin/llama-server -m /mb/Ternary-Bonsai-2-4B-Q2_0.gguf --cache-ram 5120 -lv 4 \
          --device HTP0:0 -ngl 999 -np 1 -fa on -ctk q8_0 -ctv q8_0 --jinja --ctx-checkpoints 0 --metrics \
          -c 32768 --host 127.0.0.1 --port 8080);;
    a32) export FARFD=/v0farf; build=836d57176
        want=$(printf '%s\n' env LD_LIBRARY_PATH=/p/lib 'ADSP_LIBRARY_PATH=/v0farf;/htpr;/p/lib' GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 \
          /p/bin/llama-server -m /m/NeoHorse-1-4B-q4_0-pure.gguf --cache-ram 5120 -lv 4 --device HTP0:0,HTP0:1 \
          -ngl 32 --ctx-checkpoints 0 --metrics -c 32768 --host 127.0.0.1 --port 8080);;
  esac
  run() { rm -f $T/argv $T/ppid $T/check-calls; ( export $CV=$T/$1; V1_LEDGER=$T/ledger V1_VERSION=${VV-$T/version} bash $L "${@:2}" ) > $T/out 2> $T/err; echo $? > $T/rc; }
  echo "version: 9999 ($build) mock" > $T/version

  run check-ok -c 65536 --host 127.0.0.1 --port 8080
  ok "$cfg: a window other than 32768 is refused (exit 2, before the identity check)" \
    '[ "$(cat $T/rc)" = 2 ] && grep -q "${cfg}_server: REFUSED: arguments" $T/err && [ ! -e $T/check-calls ] && [ ! -e $T/argv ]'
  run check-ok -c 32768 --host 127.0.0.1 --port 8080 -ngl 10
  ok "$cfg: an extra argument is refused" '[ "$(cat $T/rc)" = 2 ] && [ ! -e $T/argv ]'
  run check-ok -c 32768 --host 0.0.0.0 --port 8080
  ok "$cfg: another host is refused" '[ "$(cat $T/rc)" = 2 ]'
  run check-ok
  ok "$cfg: no arguments are refused" '[ "$(cat $T/rc)" = 2 ]'
  rm -f $T/ledger; run check-bad -c 32768 --host 127.0.0.1 --port 8080
  ok "$cfg: an identity mismatch is refused (exit 3), no ledger record, no exec" \
    '[ "$(cat $T/rc)" = 3 ] && grep -q "${cfg}_server: REFUSED: identity: FAILED identity" $T/err && [ ! -e $T/ledger ] && [ ! -e $T/argv ]'
  rm -f $T/ledger; ( unset V1_LEDGER; export $CV=$T/check-ok; bash $L -c 32768 --host 127.0.0.1 --port 8080 ) 2> $T/err; rc=$?
  ok "$cfg: no ledger configured is refused (exit 4)" '[ $rc = 4 ] && [ ! -e $T/argv ]'

  rm -f $T/ledger; run check-ok -c 32768 --host 127.0.0.1 --port 8080
  ok "$cfg: a start execs the exact section-3 command (+ --metrics, the suite's -c/host/port)" '[ "$(cat $T/rc)" = 0 ] && [ "$(cat $T/argv)" = "$want" ]'
  ok "$cfg: the identity check ran once before the start" '[ "$(grep -c called $T/check-calls)" = 1 ]'
  ok "$cfg: one ledger record: time, the launcher PID, boot id without dashes, the stderr file" \
    '[ "$(grep -c . $T/ledger)" = 1 ] && grep -qE "^[0-9T:+-]+ START pid=$(cat $T/ppid) boot=1b0f3c0a2e5d4f6a8b9c7d1e2f3a4b5c log=$T/err$" $T/ledger'

  rm -f $T/ledger; run check-bad --version
  ok "$cfg: --version prints the recorded line, exit 0, without an identity check, ledger record or exec" \
    '[ "$(cat $T/rc)" = 0 ] && [ "$(cat $T/out)" = "version: 9999 ($build) mock" ] && [ ! -e $T/check-calls ] && [ ! -e $T/ledger ] && [ ! -e $T/argv ]'
  VV= run check-ok --version
  ok "$cfg: --version without a recorded version file is refused" '[ "$(cat $T/rc)" = 2 ] && [ ! -e $T/check-calls ]'

  # the suite's own manifest() (suite/lib.sh), SRV_CMD = the launcher, as run_model.sh passes it
  rm -rf $T/bw $T/run; mkdir -p $T/bw $T/run; rm -f $T/ledger $T/check-calls
  ( export BENCH_WORK=$T/bw BENCH_PORT=1 V1_LEDGER=$T/ledger V1_VERSION=$T/version $CV=$T/check-bad
    source "$SUITE/lib.sh"; L=$T/run; SRV_CMD=("$HERE/${cfg}_server.sh" -c 32768 --host 127.0.0.1 --port 8080)
    AVAIL0=0; POWER_SRC=none; manifest ) > /dev/null 2>&1
  ok "$cfg: suite manifest(): env.txt carries the recorded version line ($build)" 'grep -qx "llama-server: version: 9999 ($build) mock" $T/run/env.txt'
  ok "$cfg: suite manifest(): no identity check, no ledger record" '[ ! -e $T/check-calls ] && [ ! -e $T/ledger ]'
done
echo "$pass passed, $fail failed"; [ $fail = 0 ]
