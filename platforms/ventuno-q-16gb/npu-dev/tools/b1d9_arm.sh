#!/bin/bash
# b1d9_arm.sh (NPU dev plan B1d-9B, b1-bonsai/b1d-9b/SPEC.txt): launch one of the stage's three wrapper runs.
#   b1d9_arm.sh parity <REF sha256>      b1d9_arm.sh think      b1d9_arm.sh nothink
#   b1d9_arm.sh rparity <REF sha256> <retry library sha256>   (B1f, b1-bonsai/b1f-retry/SPEC.txt)
#   parity   llama-perplexity --kl-divergence against Step 0's CPU base REF (10 chunks x 1,024)
#   think    llama-server at -c 32768, the frozen T5 screen with the template's default (thinking on), then the speed
#            probe at 1024,8192,16384,28672 if T5 passes >= 18 of 20
#   nothink  the same server with --chat-template-kwargs '{"enable_thinking":false}', the T5 screen only
#   rparity  parity's command with the htp_main_thread retry build for ff5a2337 (~/npu-dev/htp-retry-ff5a2337) first on
#            ADSP_LIBRARY_PATH after the FARF directory, its sha256 checked and hashed, --dsp-retry-patched yes
# All three: Ternary-Bonsai-2-9B Q2_0 on two sessions as B1c-9B (--device HTP0:0,HTP0:1 -ts 18,15, the input embedding
# on the CPU by -ot, flash attention, F16 KV). Every run's command, environment, hashes, timeout, evidence name and
# declared figures are fixed here. Before launching: the running executable's own FARF file and the others in
# ~/npu-dev/farf against the campaign's hash, the model's sha256, for parity REF's, and at least 5,120 MiB free on the
# home filesystem. Refuses (exit 1) on any mismatch, low disk or an existing evidence name; exit 2 on a usage error.
# Tests only (tools/test_b1d9_arm.sh): B1D9_DRY=1 prints the wrapper command instead of starting it; B1D9_FARF,
# B1D9_OUT, B1D9_REF, B1D9_DISK_MIB and B1D9_HTPR replace the FARF directory, the evidence directory, REF's path, the disk
# minimum and the retry library's directory.
set -uo pipefail
KIND=${1:-} REFSHA=${2:-} HRSHA=${3:-}
HTPR=${B1D9_HTPR:-$HOME/npu-dev/htp-retry-ff5a2337}
T=$(cd "$(dirname "$0")" && pwd)
P=$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337
M=$HOME/npu-dev/b1/models/Ternary-Bonsai-2-9B-Q2_0.gguf; MSHA=1f884aa56aacd2bbbb2e4b7abaead2b1102b74a9c75a23fc33dab916813a384d
FS=7acc31cde8878ed69e7db525b71c42440f49d29972de44d6c0653564a613e645; FD=${B1D9_FARF:-$HOME/npu-dev/farf}
REF=${B1D9_REF:-$HOME/npu-dev/b1/b1d-9b/step0/cpu-ref-9b.kld}
B=${B1D9_OUT:-$HOME/bench-runs/npu-dev/b1}; DISK=${B1D9_DISK_MIB:-5120}
DEVS=HTP0:0,HTP0:1; FL=(--device HTP0:0,HTP0:1 -ts 18,15 -ot 'token_embd\.weight=CPU' -fa on)
case $KIND in
  #        peaks      board  executable
  parity)  PK=1350,1950; BD=5500; X=llama-perplexity
    [[ "$REFSHA" =~ ^[0-9a-f]{64}$ ]] || { echo "usage: parity needs REF's sha256" >&2; exit 2; }
    [ -z "$HRSHA" ] || { echo "usage: parity takes no retry library" >&2; exit 2; };;
  rparity) PK=1350,1950; BD=5500; X=llama-perplexity
    [[ "$REFSHA" =~ ^[0-9a-f]{64}$ ]] && [[ "$HRSHA" =~ ^[0-9a-f]{64}$ ]] \
      || { echo "usage: rparity needs REF's sha256 and the retry library's sha256" >&2; exit 2; };;
  think|nothink) PK=1900,1950; BD=5100; X=llama-server   # revision 2 (SPEC.txt)
    [ -z "$REFSHA" ] || { echo "usage: $KIND takes no REF" >&2; exit 2; };;
  *) echo "usage: b1d9_arm.sh parity <REF sha256> | think | nothink | rparity <REF sha256> <retry library sha256>" >&2; exit 2;;
esac
for n in $X llama-server llama-perplexity llama-bench; do
  echo "$FS  $FD/$n.farf" | sha256sum -c --quiet - 2>/dev/null || { echo "farf $n missing or not the campaign's ($FD/$n.farf)"; exit 1; }
done
echo "$MSHA  $M" | sha256sum -c --quiet - 2>/dev/null || { echo "model sha256 mismatch: $M"; exit 1; }
AV=$(df -BM --output=avail "$HOME" | tail -1 | tr -dc 0-9)
[ "${AV:-0}" -ge "$DISK" ] || { echo "free disk ${AV:-?} MiB, below $DISK MiB"; exit 1; }
RUN=9b-$KIND; O=$B/$RUN; L=$B/$RUN-wrapper-console.txt
[ -e "$O" ] || [ -e "$L" ] && { echo "$O or $L exists (every run is new)"; exit 1; }
ADSP="$FD;$P/lib"; RP=()   # parity, think, nothink: as run in B1d-9B
HASH=(--hash $M --hash $P/lib/libllama.so.0.7.0 --hash $P/lib/libggml-base.so.0.27.0
  --hash $P/lib/libggml-hexagon.so.0.27.0 --hash $P/lib/libggml-htp-v75.so)
if [ $KIND = rparity ]; then
  echo "$HRSHA  $HTPR/libggml-htp-v75.so" | sha256sum -c --quiet - 2>/dev/null || { echo "retry library mismatch: $HTPR/libggml-htp-v75.so"; exit 1; }
  ADSP="$FD;$HTPR;$P/lib"; RP=(--dsp-retry-patched yes); HASH+=(--hash $HTPR/libggml-htp-v75.so)
fi
ENVS=(--env GGML_HEXAGON_NHMX=1 --env LD_LIBRARY_PATH=$P/lib --env "ADSP_LIBRARY_PATH=$ADSP"
  --env GGML_HEXAGON_DEVICES=$DEVS --env GGML_HEXAGON_VERBOSE=1 --env GGML_SCHED_DEBUG=2)
if [ $KIND = parity ] || [ $KIND = rparity ]; then
  echo "$REFSHA  $REF" | sha256sum -c --quiet - 2>/dev/null || { echo "REF mismatch"; exit 1; }
  CMD=(bash $T/npu_dev_run.sh --stage b1 --run $RUN --timeout 5400 --expect-dsp yes "${RP[@]}" --floor-mib 1536 --stall-s 120
    --declared-peak-mib $PK --declared-board-mib $BD "${HASH[@]}" --hash $P/bin/llama-perplexity
    --hash $P/lib/libllama-perplexity-impl.so "${ENVS[@]}" --
    $P/bin/llama-perplexity -m $M --kl-divergence-base $REF --kl-divergence -c 1024 -b 1024 -ub 512 --chunks 10 -t 8
    -lv 5 -ngl 999 "${FL[@]}")
else
  S=$O-slots; [ -e "$S" ] && { echo "$S exists"; exit 1; }
  if [ $KIND = think ]; then PAY=(--speed 1024,8192,16384,28672 --min-pass 18); TO=7200; TK=()
  else PAY=(); TO=3600; TK=(--chat-template-kwargs '{"enable_thinking":false}'); fi
  CMD=(bash $T/npu_dev_run.sh --stage b1 --run $RUN --timeout $TO --expect-dsp yes "${RP[@]}" --floor-mib 1536 --stall-s 120
    --declared-peak-mib $PK --declared-board-mib $BD "${HASH[@]}" --hash $P/bin/llama-server
    --hash $P/lib/libllama-server-impl.so "${ENVS[@]}" --
    /bin/bash $T/b1_t5_payload.sh "${PAY[@]}" $O/payload 18090 900 bonsai9b-$KIND 900 --
    $P/bin/llama-server -m $M -c 32768 -np 1 --cache-ram 0 --slot-save-path $S --jinja "${TK[@]}" -b 2048 -ub 512
    -ngl 999 "${FL[@]}" -lv 5 --no-webui)
fi
echo "B1d-9B $RUN: sessions $DEVS, declared peaks $PK (r2_mapped_peak.py <log> $PK --sessions $DEVS)"
if [ "${B1D9_DRY:-}" = 1 ]; then printf '%q ' "${CMD[@]}"; echo; exit 0; fi
[ $KIND = think ] || [ $KIND = nothink ] && mkdir -p "$S"
cd ~/bench-runs || exit 1
setsid nohup "${CMD[@]}" > "$L" 2>&1 < /dev/null &
echo "started (pid $!); console: $L"
