#!/bin/bash
# b9_server.sh (v1-plan-B9.txt section 4.1): the "llama-server binary" suite/run_model.sh receives for V1 on B9. Two forms:
#   b9_server.sh --version
#     suite/lib.sh manifest() calls it while the measured server is up: prints the pinned binary's version line,
#     recorded with no server running before the batch ($V1_VERSION), and exits 0. No identity check, no backend
#     load, no ledger record: nothing touches the NPU beside the running server.
#   b9_server.sh -c 32768 --host 127.0.0.1 --port 8080
#     exactly the suite's trailing arguments; anything else is refused (exit 2). Runs B9's identity check (refused,
#     exit 3, on a mismatch: the suite records SERVER_FAILED), appends one lifetime record to $V1_LEDGER (exit 4 if it
#     cannot), then execs the qualified V0e command plus --metrics (section 3): the PID stays the same, so the arena's
#     server PID, the ledger's and the stall watchdog's (it matches the llama-server path) are one process.
# Refusals go to stderr, i.e. to the suite's server log for this start, prefixed "b9_server: REFUSED".
# Overridable for tests: B9_CHECK, PB, R, MB, FARFD, EXEC (default exec), BOOT_ID_FILE.
set -u
PB=${PB:-$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337}; R=${R:-$HOME/npu-dev/htp-retry-ff5a2337}
MB=${MB:-$HOME/npu-dev/b1/models}; FARFD=${FARFD:-$HOME/npu-dev/farf}
B9_CHECK=${B9_CHECK:-/bin/bash $HOME/v0/b9_identity_check.sh}; EXEC=${EXEC:-exec}
BOOT_ID_FILE=${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
refuse() { echo "b9_server: REFUSED: $2" >&2; exit "$1"; }
if [ "$#" = 1 ] && [ "$1" = --version ]; then
  [ -s "${V1_VERSION:-}" ] || refuse 2 "no recorded version file (V1_VERSION='${V1_VERSION:-}')"
  cat "$V1_VERSION"; exit 0; fi
[ "$*" = "-c 32768 --host 127.0.0.1 --port 8080" ] || refuse 2 "arguments '$*' (only '-c 32768 --host 127.0.0.1 --port 8080' or '--version')"
[ -n "${V1_LEDGER:-}" ] || refuse 4 "V1_LEDGER not set"
idl=$($B9_CHECK 2>&1) || refuse 3 "identity: $(echo "$idl" | tail -1)"
log=$(readlink /proc/$$/fd/2) || refuse 4 "cannot resolve the server log (stderr)"
printf '%s START pid=%s boot=%s log=%s\n' "$(date -Is)" $$ "$(tr -d - < "$BOOT_ID_FILE")" "$log" >> "$V1_LEDGER" \
  || refuse 4 "cannot write the ledger $V1_LEDGER"
$EXEC env LD_LIBRARY_PATH=$PB/lib "ADSP_LIBRARY_PATH=$FARFD;$R;$PB/lib" GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 \
  GGML_HEXAGON_NHMX=1 $PB/bin/llama-server -m $MB/Ternary-Bonsai-2-9B-Q2_0.gguf --cache-ram 5120 -lv 4 \
  --device HTP0:0,HTP0:1 -ts 18,15 -ot 'token_embd\.weight=CPU' -ngl 999 -np 1 -fa on --jinja --ctx-checkpoints 0 \
  --metrics "$@"
