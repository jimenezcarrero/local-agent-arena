Exploratory screen (NOT T7, not a gate): is an imatrix Q2_K of LFM2.5-24B-A2B much closer to REF than our M2?
Uses T7's saved REF logits, so it costs one download and one ~6-minute pass. Follow exactly; stop and report on any failure.

Candidate M3x: mradermacher/LFM2.5-24B-A2B-i1-GGUF, file LFM2.5-24B-A2B.i1-Q2_K.gguf (8,809,759,520 bytes; imatrix-weighted
Q2_K, about the same size as our M2's 8,809,757,984).

1. Close heavy apps (as for T7). Check free disk >= 12 GiB: df -h ~
2. Download at a pinned revision and record its identity:
   mkdir -p ~/m3x && cd ~/m3x
   REV=$(curl -fsS https://huggingface.co/api/models/mradermacher/LFM2.5-24B-A2B-i1-GGUF | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')
   echo "$REV" > revision.txt
   curl -fL -C - -o LFM2.5-24B-A2B.i1-Q2_K.gguf "https://huggingface.co/mradermacher/LFM2.5-24B-A2B-i1-GGUF/resolve/$REV/LFM2.5-24B-A2B.i1-Q2_K.gguf"
   stat -c %s LFM2.5-24B-A2B.i1-Q2_K.gguf   (must be 8809759520)
   sha256sum LFM2.5-24B-A2B.i1-Q2_K.gguf | tee sha256.txt
3. Score it against T7's REF logits with T7's own build (af0579c78), same settings as T7's official M2 pass:
   bash -c 'set -o pipefail; T="$HOME/r1-t7-20261017-093233"
     test -s "$T/ref.kld" || { echo "ref.kld missing: stop"; exit 1; }
     systemd-inhibit --what=idle:sleep:handle-lid-switch --why=bench \
       "$T/llama.cpp/build-host/bin/llama-perplexity" -m "$HOME/m3x/LFM2.5-24B-A2B.i1-Q2_K.gguf" \
       --kl-divergence --kl-divergence-base "$T/ref.kld" \
       -c 1024 -b 1024 --chunks 20 -t 8 -fa on \
       2>&1 | tee "$HOME/m3x/kld-m3x.log"'
   (--kl-divergence must be present: without it, --kl-divergence-base would WRITE logits to ref.kld.)
4. Report the summary lines:
   grep -E "^Mean PPL\(Q\)|^Mean    KLD|^99.0%   KLD|^Same top p" ~/m3x/kld-m3x.log
   plus revision.txt and sha256.txt. Then copy back (no model):
   tar -czf ~/m3x-screen.tar.gz -C ~/m3x kld-m3x.log revision.txt sha256.txt && sha256sum ~/m3x-screen.tar.gz
   scp ~/m3x-screen.tar.gz arduino@ventunoq.local:~/r1-incoming/
Keep the downloaded file: if it screens well, the formal path (tensor table, R1 fit, T7) needs it.
