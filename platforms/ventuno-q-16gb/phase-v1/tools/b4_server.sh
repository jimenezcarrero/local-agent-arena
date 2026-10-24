#!/bin/bash
# b4_server.sh (v1-plan-4B.txt sections 3.1, 4.1): the "llama-server binary" suite/run_model.sh receives for V1 on B4
# (Ternary-Bonsai-2-4B Q2_0, one NPU session, the ff5a2337 package's own unpatched DSP library, q8_0 KV), run by
# v1_launcher.sh. The qualified V0e command plus --metrics.
# Overridable for tests: B4_CHECK, PB, MB, FARFD, and v1_launcher.sh's EXEC, BOOT_ID_FILE.
set -u
PB=${PB:-$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337}; MB=${MB:-$HOME/npu-dev/b1/models}
FARFD=${FARFD:-$HOME/npu-dev/farf}
NAME=b4_server; ID_CHECK=${B4_CHECK:-/bin/bash $HOME/v0/b4_identity_check.sh}
CMD=(env LD_LIBRARY_PATH=$PB/lib "ADSP_LIBRARY_PATH=$FARFD;$PB/lib" GGML_HEXAGON_DEVICES=HTP0:0 GGML_HEXAGON_NHMX=1
  $PB/bin/llama-server -m $MB/Ternary-Bonsai-2-4B-Q2_0.gguf --cache-ram 5120 -lv 4 --device HTP0:0 -ngl 999 -np 1
  -fa on -ctk q8_0 -ctv q8_0 --jinja --ctx-checkpoints 0 --metrics)
source "$(dirname "$(readlink -f "$0")")/v1_launcher.sh"
