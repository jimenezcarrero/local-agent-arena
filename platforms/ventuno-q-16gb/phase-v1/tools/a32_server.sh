#!/bin/bash
# a32_server.sh (v1-plan-4B.txt sections 3.2, 4.1): the "llama-server binary" suite/run_model.sh receives for V1 on
# A32-5 (NeoHorse-1-4B pure Q4_0, -ngl 32 on two NPU sessions, the campaign package 836d57176 with its patched DSP
# library), run by v1_launcher.sh. The qualified V0e command plus --metrics; as qualified it sets no -np, -fa or
# --jinja (the build's defaults apply, as in V0e).
# Overridable for tests: A32_CHECK, P, M, FARFD, HTPR, and v1_launcher.sh's EXEC, BOOT_ID_FILE.
set -u
P=${P:-$HOME/v0/hexpkg/pkg-linux}; M=${M:-$HOME/v0/models/q40}; FARFD=${FARFD:-$HOME/v0/farf}; HTPR=${HTPR:-$HOME/v0/htp-retry}
NAME=a32_server; ID_CHECK=${A32_CHECK:-/bin/bash $HOME/v0/a32_identity_check.sh}
CMD=(env LD_LIBRARY_PATH=$P/lib "ADSP_LIBRARY_PATH=$FARFD;$HTPR;$P/lib" GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1
  $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf --cache-ram 5120 -lv 4 --device HTP0:0,HTP0:1 -ngl 32
  --ctx-checkpoints 0 --metrics)
source "$(dirname "$(readlink -f "$0")")/v1_launcher.sh"
