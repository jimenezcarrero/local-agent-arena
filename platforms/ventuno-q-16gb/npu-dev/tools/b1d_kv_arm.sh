#!/bin/bash
# b1d_kv_arm.sh (NPU dev plan B1d-4B, b1-bonsai/b1d-4b/SPEC.txt): launch one of the stage's six wrapper runs.
#   b1d_kv_arm.sh S2|CK|Q8 parity <REF sha256>      b1d_kv_arm.sh S2|CK|Q8 server
# Every option's device, KV and attention flags, environment, hashes, timeout, evidence names and declared figures are
# fixed here (review of 09a7a43: the launch and the acceptance read the same per-session peak vector, printed at
# launch). Before launching: the three FARF files (~/npu-dev/farf) against the campaign's hash; for parity, REF against
# the sha256 given (Step 0's recorded hash). Refuses (exit 1) on any mismatch or an existing evidence name; exit 2 on a
# usage error. B1D_DRY=1 prints the wrapper command instead of starting it (tests only).
set -uo pipefail
OPT=${1:-} KIND=${2:-} REFSHA=${3:-}
T=$(cd "$(dirname "$0")" && pwd)
P=$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337
M=$HOME/npu-dev/b1/models/Ternary-Bonsai-2-4B-Q2_0.gguf
REF=$HOME/npu-dev/b1/b1c-4b/step0/cpu-ref.kld
FS=7acc31cde8878ed69e7db525b71c42440f49d29972de44d6c0653564a613e645
B=$HOME/bench-runs/npu-dev/b1
case $OPT in
  #     sessions            option flags                              attention   peaks parity  peaks server  board parity/server
  S2) DEVS=HTP0:0,HTP0:1; FL=(--device HTP0:0,HTP0:1 -ts 16,17);      FA=(-fa on);  PP=1350,1950; SP=1350,1500; PB=5500; SB=4000;;
  Q8) DEVS=HTP0:0;        FL=(--device HTP0:0 -ctk q8_0 -ctv q8_0);   FA=(-fa on);  PP=1950;      SP=2000;      PB=4500; SB=3500;;
  CK) DEVS=HTP0:0;        FL=(--device HTP0:0 -nkvo);                 FA=(-fa off); PP=1950;      SP=1500;      PB=4500; SB=6000;;
  *) echo "usage: b1d_kv_arm.sh S2|CK|Q8 parity <REF sha256> | server" >&2; exit 2;;
esac
case $KIND in
  parity) [[ "$REFSHA" =~ ^[0-9a-f]{64}$ ]] || { echo "usage: parity needs REF's sha256" >&2; exit 2; };;
  server) [ -z "$REFSHA" ] || { echo "usage: server takes no REF" >&2; exit 2; };;
  *) echo "usage: kind parity|server" >&2; exit 2;;
esac
for n in llama-server llama-perplexity llama-bench; do
  echo "$FS  $HOME/npu-dev/farf/$n.farf" | sha256sum -c --quiet - 2>/dev/null || { echo "farf $n mismatch"; exit 1; }
done
RUN=4b-kv-$OPT-$KIND; O=$B/$RUN; L=$B/$RUN-wrapper-console.txt
[ -e "$O" ] || [ -e "$L" ] && { echo "$O or $L exists (every run is new)"; exit 1; }
ENVS=(--env GGML_HEXAGON_NHMX=1 --env LD_LIBRARY_PATH=$P/lib --env "ADSP_LIBRARY_PATH=$HOME/npu-dev/farf;$P/lib"
  --env GGML_HEXAGON_DEVICES=$DEVS --env GGML_HEXAGON_VERBOSE=1 --env GGML_SCHED_DEBUG=2)
HASH=(--hash $M --hash $P/lib/libllama.so.0.7.0 --hash $P/lib/libggml-base.so.0.27.0
  --hash $P/lib/libggml-hexagon.so.0.27.0 --hash $P/lib/libggml-htp-v75.so)
if [ "$KIND" = parity ]; then
  echo "$REFSHA  $REF" | sha256sum -c --quiet - 2>/dev/null || { echo "REF mismatch"; exit 1; }
  CMD=(bash $T/npu_dev_run.sh --stage b1 --run $RUN --timeout 5400 --expect-dsp yes --floor-mib 1536 --stall-s 120
    --declared-peak-mib $PP --declared-board-mib $PB "${HASH[@]}" --hash $P/bin/llama-perplexity
    --hash $P/lib/libllama-perplexity-impl.so "${ENVS[@]}" --
    $P/bin/llama-perplexity -m $M --kl-divergence-base $REF --kl-divergence -c 1024 -b 1024 -ub 512 --chunks 10 -t 8
    "${FA[@]}" -lv 5 -ngl 999 "${FL[@]}")
  PEAK=$PP
else
  S=$O-slots; [ -e "$S" ] && { echo "$S exists"; exit 1; }
  CMD=(bash $T/npu_dev_run.sh --stage b1 --run $RUN --timeout 7200 --expect-dsp yes --floor-mib 1536 --stall-s 120
    --declared-peak-mib $SP --declared-board-mib $SB "${HASH[@]}" --hash $P/bin/llama-server
    --hash $P/lib/libllama-server-impl.so "${ENVS[@]}" --
    /bin/bash $T/b1_t5_payload.sh --speed 1024,8192,16384,28672 --min-pass 18 $O/payload 18090 900 bonsai4b-kv-$OPT 900 --
    $P/bin/llama-server -m $M -c 32768 -np 1 --cache-ram 0 --slot-save-path $S --jinja "${FA[@]}" -b 2048 -ub 512
    -ngl 999 "${FL[@]}" -lv 5 --no-webui)
  PEAK=$SP
fi
echo "B1d-4B $RUN: sessions $DEVS, declared peaks $PEAK (r2_mapped_peak.py <log> $PEAK --sessions $DEVS)"
if [ "${B1D_DRY:-}" = 1 ]; then printf '%q ' "${CMD[@]}"; echo; exit 0; fi
[ "$KIND" = server ] && mkdir -p "$S"
cd ~/bench-runs || exit 1
setsid nohup "${CMD[@]}" > "$L" 2>&1 < /dev/null &
echo "started (pid $!); console: $L"
