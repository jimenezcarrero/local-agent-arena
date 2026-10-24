# v1_launcher.sh (v1-plan-4B.txt section 4.1): b9_server.sh's logic with the configuration as variables, sourced by a
# configuration's launcher (b4_server.sh, a32_server.sh) after it sets:
#   NAME      the launcher's name, prefixing refusals ("<NAME>: REFUSED: <reason>")
#   ID_CHECK  the configuration's identity command
#   CMD       the qualified V0e command plus --metrics, as an array, without the suite's trailing arguments
# Two call forms, as b9_server.sh's (v1-plan-B9.txt section 4.1):
#   <launcher> --version
#     prints the version line recorded with no server up ($V1_VERSION) and exits 0: no identity check, no backend
#     load, no ledger record (suite/lib.sh manifest() calls it while the measured server is up).
#   <launcher> -c 32768 --host 127.0.0.1 --port 8080
#     exactly the suite's trailing arguments, anything else refused (exit 2); the identity check (exit 3 on a
#     mismatch); one lifetime record in $V1_LEDGER (exit 4 if it cannot); then exec, so the PID is llama-server's.
# Overridable for tests: EXEC (default exec), BOOT_ID_FILE.
EXEC=${EXEC:-exec}; BOOT_ID_FILE=${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
refuse() { echo "$NAME: REFUSED: $2" >&2; exit "$1"; }
if [ "$#" = 1 ] && [ "$1" = --version ]; then
  [ -s "${V1_VERSION:-}" ] || refuse 2 "no recorded version file (V1_VERSION='${V1_VERSION:-}')"
  cat "$V1_VERSION"; exit 0; fi
[ "$*" = "-c 32768 --host 127.0.0.1 --port 8080" ] || refuse 2 "arguments '$*' (only '-c 32768 --host 127.0.0.1 --port 8080' or '--version')"
[ -n "${V1_LEDGER:-}" ] || refuse 4 "V1_LEDGER not set"
idl=$($ID_CHECK 2>&1) || refuse 3 "identity: $(echo "$idl" | tail -1)"
log=$(readlink /proc/$$/fd/2) || refuse 4 "cannot resolve the server log (stderr)"
printf '%s START pid=%s boot=%s log=%s\n' "$(date -Is)" $$ "$(tr -d - < "$BOOT_ID_FILE")" "$log" >> "$V1_LEDGER" \
  || refuse 4 "cannot write the ledger $V1_LEDGER"
$EXEC "${CMD[@]}" "$@"
