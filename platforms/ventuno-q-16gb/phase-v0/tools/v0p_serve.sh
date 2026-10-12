#!/bin/bash
# v0p_serve.sh <server command...> (D141): the pi diagnostic's server wrapper. Starts pi_capture_proxy.py on :8080
# (where pi, run_v0e.sh's readiness check and the probes connect) relaying to the server on :8090, recording every
# chat request/response in $CAP_DIR, then execs the server (same pid, so run_v0e.sh's pid, journal and kill handling
# apply to the server; the proxy is in its process group and is stopped with it).
: "${CAP_DIR:?CAP_DIR}"; mkdir -p "$CAP_DIR"
python3 $HOME/v0/pi_capture_proxy.py 8080 8090 "$CAP_DIR" &
exec "$@"
