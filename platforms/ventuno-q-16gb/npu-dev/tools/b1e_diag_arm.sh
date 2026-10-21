#!/bin/bash
# b1e_diag_arm.sh (NPU dev plan B1e, b1-bonsai/b1e-s2diag/SPEC.txt): launch one of the stage's four wrapper runs.
#   b1e_diag_arm.sh s1|s1r|s2|nh2
#   s1, s1r  llama-eval-callback, Bonsai-2-4B, one session (HTP0:0); s1r repeats s1 (run-to-run noise)
#   s2       the same on two sessions (HTP0:0,HTP0:1, -ts 16,17: B1d-4B's S2 split)
#   nh2      llama-perplexity, NeoHorse-1-4B q4_0 (the campaign's model) on two sessions with this package
# Every run's command, environment, hashes, timeout, evidence name and declared figures are fixed here. Before
# launching: the three FARF files (~/npu-dev/farf) against the campaign's hash, the model's sha256, and for nh2 the
# text's. Refuses (exit 1) on any mismatch or an existing evidence name; exit 2 on a usage error. B1E_DRY=1 prints the
# wrapper command instead of starting it (tests only).
set -uo pipefail
RUN=${1:-}
T=$(cd "$(dirname "$0")" && pwd)
P=$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337
MB=$HOME/npu-dev/b1/models/Ternary-Bonsai-2-4B-Q2_0.gguf; MBSHA=64a5183b44921bdb5ac4a6f5f92007821d6ebe5c66997d3c147fd214ab9433d4
MN=$HOME/v0/models/q40/NeoHorse-1-4B-q4_0-pure.gguf; MNSHA=f822fa2602af45d802e54bac518bab3f62b08943029626114a474afc3d8f3049
TXT=$HOME/npu-dev/b1/b1c-4b/step0/text/wikitext-2-raw/wiki.test.raw; TXTSHA=173c87a53759e0201f33e0ccf978e510c2042d7f2cb78229d9a50d79b9e7dd08
FS=7acc31cde8878ed69e7db525b71c42440f49d29972de44d6c0653564a613e645
PROMPT="The capital of France is"
B=$HOME/bench-runs/npu-dev/b1
case $RUN in
  #   sessions            device flags                                peaks      board
  s1|s1r) DEVS=HTP0:0;        FL=(--device HTP0:0);                   PK=1700;      BD=2800; M=$MB; MS=$MBSHA;;
  s2)     DEVS=HTP0:0,HTP0:1; FL=(--device HTP0:0,HTP0:1 -ts 16,17);  PK=1350,1500; BD=4000; M=$MB; MS=$MBSHA;;
  nh2)    DEVS=HTP0:0,HTP0:1; FL=(--device HTP0:0,HTP0:1);            PK=1450,1900; BD=4500; M=$MN; MS=$MNSHA;;
  *) echo "usage: b1e_diag_arm.sh s1|s1r|s2|nh2" >&2; exit 2;;
esac
for n in llama-server llama-perplexity llama-bench; do
  echo "$FS  $HOME/npu-dev/farf/$n.farf" | sha256sum -c --quiet - 2>/dev/null || { echo "farf $n mismatch"; exit 1; }
done
echo "$MS  $M" | sha256sum -c --quiet - 2>/dev/null || { echo "model sha256 mismatch: $M"; exit 1; }
NAME=b1e-$RUN; O=$B/$NAME; L=$B/$NAME-wrapper-console.txt
[ -e "$O" ] || [ -e "$L" ] && { echo "$O or $L exists (every run is new)"; exit 1; }
ENVS=(--env GGML_HEXAGON_NHMX=1 --env LD_LIBRARY_PATH=$P/lib --env "ADSP_LIBRARY_PATH=$HOME/npu-dev/farf;$P/lib"
  --env GGML_HEXAGON_DEVICES=$DEVS --env GGML_HEXAGON_VERBOSE=1 --env GGML_SCHED_DEBUG=2)
HASH=(--hash $M --hash $P/lib/libllama.so.0.7.0 --hash $P/lib/libggml-base.so.0.27.0
  --hash $P/lib/libggml-hexagon.so.0.27.0 --hash $P/lib/libggml-htp-v75.so)
if [ $RUN = nh2 ]; then
  echo "$TXTSHA  $TXT" | sha256sum -c --quiet - 2>/dev/null || { echo "text sha256 mismatch"; exit 1; }
  CMD=(bash $T/npu_dev_run.sh --stage b1 --run $NAME --timeout 1800 --expect-dsp yes --floor-mib 1536 --stall-s 120
    --declared-peak-mib $PK --declared-board-mib $BD "${HASH[@]}" --hash $P/bin/llama-perplexity
    --hash $P/lib/libllama-perplexity-impl.so "${ENVS[@]}" --
    $P/bin/llama-perplexity -m $M -f $TXT -c 256 -b 256 -ub 256 --chunks 16 -t 8 -fa on -lv 5 -ngl 99 "${FL[@]}")
else
  CMD=(bash $T/npu_dev_run.sh --stage b1 --run $NAME --timeout 900 --expect-dsp yes --floor-mib 1536 --stall-s 120
    --declared-peak-mib $PK --declared-board-mib $BD "${HASH[@]}" --hash $P/bin/llama-eval-callback "${ENVS[@]}" --
    $P/bin/llama-eval-callback -m $M -p "$PROMPT" -c 256 -b 256 -ub 256 -t 8 -fa on -lv 5 -ngl 999 "${FL[@]}")
fi
echo "B1e $NAME: sessions $DEVS, declared peaks $PK (r2_mapped_peak.py <log> $PK --sessions $DEVS)"
if [ "${B1E_DRY:-}" = 1 ]; then printf '%q ' "${CMD[@]}"; echo; exit 0; fi
cd ~/bench-runs || exit 1
setsid nohup "${CMD[@]}" > "$L" 2>&1 < /dev/null &
echo "started (pid $!); console: $L"
