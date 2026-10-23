#!/bin/bash
# test_b9_server.sh — offline tests of b9_server.sh (v1-plan-B9.txt section 4.5): no server, no NPU.
set -u
HERE=$(dirname "$(readlink -f "$0")"); L=$HERE/b9_server.sh; SUITE=$(readlink -f "$HERE/../../../../suite")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
cat > $T/check-ok <<EOF
#!/bin/bash
echo called >> $T/check-calls; echo "OK B9 mock"; exit 0
EOF
cat > $T/check-bad <<EOF
#!/bin/bash
echo called >> $T/check-calls; echo "FAILED B9 identity: model sha256 'x'"; exit 1
EOF
# the exec stand-in: records its argv one per line, and its parent (the launcher's PID: exec keeps it in real use)
cat > $T/exec <<EOF
#!/bin/bash
printf '%s\n' "\$@" > $T/argv; echo \$PPID > $T/ppid
EOF
echo '1b0f3c0a2e5d4f6a8b9c7d1e2f3a4b5c' > $T/boot
chmod +x $T/check-ok $T/check-bad $T/exec
export PB=/pb R=/r MB=/mb FARFD=/farf BOOT_ID_FILE=$T/boot EXEC=$T/exec
run() { rm -f $T/argv $T/ppid $T/check-calls; ( B9_CHECK=$T/$1 V1_LEDGER=$T/ledger V1_VERSION=${VV-$T/version} bash $L "${@:2}" ) > $T/out 2> $T/err; echo $? > $T/rc; }
echo "version: 9999 (ff5a2337) mock" > $T/version

run check-ok -c 65536 --host 127.0.0.1 --port 8080
ok "a window other than 32768 is refused (exit 2, before the identity check)" '[ "$(cat $T/rc)" = 2 ] && grep -q "b9_server: REFUSED: arguments" $T/err && [ ! -e $T/check-calls ] && [ ! -e $T/argv ]'
run check-ok -c 32768 --host 127.0.0.1 --port 8080 -ngl 10
ok "an extra argument is refused" '[ "$(cat $T/rc)" = 2 ] && [ ! -e $T/argv ]'
run check-ok -c 32768 --host 0.0.0.0 --port 8080
ok "another host is refused" '[ "$(cat $T/rc)" = 2 ]'
run check-ok
ok "no arguments are refused" '[ "$(cat $T/rc)" = 2 ]'
rm -f $T/ledger; run check-bad -c 32768 --host 127.0.0.1 --port 8080
ok "an identity mismatch is refused (exit 3), no ledger record, no exec" '[ "$(cat $T/rc)" = 3 ] && grep -q "REFUSED: identity: FAILED B9 identity" $T/err && [ ! -e $T/ledger ] && [ ! -e $T/argv ]'
rm -f $T/ledger; ( unset V1_LEDGER; B9_CHECK=$T/check-ok bash $L -c 32768 --host 127.0.0.1 --port 8080 ) 2> $T/err; rc=$?
ok "no ledger configured is refused (exit 4)" '[ $rc = 4 ] && [ ! -e $T/argv ]'

rm -f $T/ledger; run check-ok -c 32768 --host 127.0.0.1 --port 8080
want=$(printf '%s\n' env LD_LIBRARY_PATH=/pb/lib 'ADSP_LIBRARY_PATH=/farf;/r;/pb/lib' GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 GGML_HEXAGON_NHMX=1 \
  /pb/bin/llama-server -m /mb/Ternary-Bonsai-2-9B-Q2_0.gguf --cache-ram 5120 -lv 4 --device HTP0:0,HTP0:1 -ts 18,15 \
  -ot 'token_embd\.weight=CPU' -ngl 999 -np 1 -fa on --jinja --ctx-checkpoints 0 --metrics -c 32768 --host 127.0.0.1 --port 8080)
ok "a start execs the exact section-3 command (+ --metrics, the suite's -c/host/port)" '[ "$(cat $T/rc)" = 0 ] && [ "$(cat $T/argv)" = "$want" ]'
ok "the identity check ran once before the start" '[ "$(grep -c called $T/check-calls)" = 1 ]'
ok "one ledger record: time, the launcher PID, boot id without dashes, the stderr file" \
  '[ "$(grep -c . $T/ledger)" = 1 ] && grep -qE "^[0-9T:+-]+ START pid=$(cat $T/ppid) boot=1b0f3c0a2e5d4f6a8b9c7d1e2f3a4b5c log=$T/err$" $T/ledger'

rm -f $T/ledger; run check-bad --version
ok "--version prints the recorded line, exit 0, without an identity check, ledger record or exec" \
  '[ "$(cat $T/rc)" = 0 ] && [ "$(cat $T/out)" = "version: 9999 (ff5a2337) mock" ] && [ ! -e $T/check-calls ] && [ ! -e $T/ledger ] && [ ! -e $T/argv ]'
VV= run check-ok --version
ok "--version without a recorded version file is refused" '[ "$(cat $T/rc)" = 2 ] && [ ! -e $T/check-calls ]'

# the suite's own manifest() (suite/lib.sh), SRV_CMD = the launcher, as run_model.sh passes it
mkdir -p $T/bw $T/run; rm -f $T/ledger $T/check-calls
( export BENCH_WORK=$T/bw BENCH_PORT=1 V1_LEDGER=$T/ledger V1_VERSION=$T/version B9_CHECK=$T/check-bad
  source "$SUITE/lib.sh"; L=$T/run; SRV_CMD=("$HERE/b9_server.sh" -c 32768 --host 127.0.0.1 --port 8080)
  AVAIL0=0; POWER_SRC=none; manifest ) > /dev/null 2>&1
ok "suite manifest(): env.txt carries the pinned version line" 'grep -qx "llama-server: version: 9999 (ff5a2337) mock" $T/run/env.txt'
ok "suite manifest(): no identity check, no ledger record" '[ ! -e $T/check-calls ] && [ ! -e $T/ledger ]'
echo "$pass passed, $fail failed"; [ $fail = 0 ]
