Exploratory reference test (NOT T7, not a gate), revision 4. Question: if every gate and up expert tensor of
LFM2.5-24B-A2B were Q3_K, with M2's recipe and source otherwise unchanged, how close would it get to REF?
This file does not fit on the board's NPU. It is a practical reference point for partial Q2_K/Q3_K mixes that would fit,
not a proof about them: a partial mix is expected, but not guaranteed, to score no better.
Follow exactly; stop and report on any failure or unexpected count; do not improvise.

Inputs already on this laptop:
  BF16 ~/r1-downloads/LFM2.5-24B-A2B-BF16.gguf (M2's own source, K3 manifest)
       47962094880 bytes, sha256 55103fda18def5210dafac2d1f1125afc93baf604dc24cf0edf9e9aee0d576ec
  T7 tree and saved REF logits: ~/r1-t7-20261017-093233 (llama.cpp at af0579c78, build-host; ref.kld)
M2 was made with: llama-quantize <BF16> <M2> Q2_K 8 (same commit). This run adds only two --tensor-type overrides.

1. Resources and start (no app needs closing if these pass):
   Disk: before step 3 >= 14G (the new file takes about 9.7 GiB); before step 4 >= 2G (scoring writes only a log).
   Memory: >= 14 GiB available before steps 3 and 4.
   df -BG --output=avail ~ | tail -1                     (now: must be >= 14G)
   grep MemAvailable /proc/meminfo                       (must be >= 14 GiB = 14680064 kB)
   mkdir -p ~/m3c && cd ~/m3c && date -Iseconds | tee start.txt

2. Build llama-quantize in T7's tree without changing T7's binaries:
   bash -c 'set -euo pipefail; T="$HOME/r1-t7-20261017-093233"; B="$T/llama.cpp/build-host/bin"
     test "$(git -C "$T/llama.cpp" rev-parse HEAD)" = af0579c78a07a555d84830d01da7b61cfadbc7ef
     test -z "$(git -C "$T/llama.cpp" status --porcelain)"
     (cd "$B" && sha256sum llama-perplexity llama-server lib*.so*) > "$HOME/m3c/t7-bins-before.sha256"
     cmake --build "$T/llama.cpp/build-host" -j8 --target llama-quantize > "$HOME/m3c/build-quantize.log" 2>&1
     (cd "$B" && sha256sum -c "$HOME/m3c/t7-bins-before.sha256") > "$HOME/m3c/t7-bins-after.check" 2>&1
     # checks exactly the files T7 had; the new llama-quantize and its library are not in that list
     rc=0; "$B/llama-quantize" --help > "$HOME/m3c/quantize-help.txt" 2>&1 || rc=$?
     test "$rc" -le 1    # at af0579c78, --help prints the usage and exits 1; 0 or 1 is accepted
     grep -q -- "--tensor-type" "$HOME/m3c/quantize-help.txt"
     sha256sum "$B/llama-quantize" "$B"/libllama-quantize-impl.so* > "$HOME/m3c/quantize-bin.sha256"
     echo "step 2 OK"'
   It must end with "step 2 OK"; if not, stop and send the last 30 lines of ~/m3c/build-quantize.log.

3. Check BF16, then quantize (M2's command plus the two overrides):
   bash -c 'set -euo pipefail; S="$HOME/r1-downloads/LFM2.5-24B-A2B-BF16.gguf"
     test "$(stat -c %s "$S")" = 47962094880
     echo "55103fda18def5210dafac2d1f1125afc93baf604dc24cf0edf9e9aee0d576ec  $S" | sha256sum -c -
     echo "BF16 OK"'
   bash -c 'set -o pipefail; T="$HOME/r1-t7-20261017-093233"; S="$HOME/r1-downloads/LFM2.5-24B-A2B-BF16.gguf"
     systemd-inhibit --what=idle:sleep:handle-lid-switch --why=bench \
       "$T/llama.cpp/build-host/bin/llama-quantize" \
       --tensor-type ffn_gate_exps=q3_k --tensor-type ffn_up_exps=q3_k \
       "$S" "$HOME/m3c/LFM2.5-24B-A2B-CEIL-Q2_K-gu-Q3_K.gguf" Q2_K 8 \
       > "$HOME/m3c/quantize.log" 2>&1; echo "quantize exit=$?"'
   (must print "quantize exit=0")
   Counts (awk always exits 0, so a count of 0 is not an error). The quantize log has one line per tensor, e.g.
   "[ 415/ 428] blk.38.ffn_gate_exps.weight ... converting to q2_K .. size = ...":
     awk '/ffn_gate_exps\.weight/ && /converting to q3_K/ {n++} END {print "gate q3_K:", n+0, "(expect 38)"}' ~/m3c/quantize.log
     awk '/ffn_up_exps\.weight/   && /converting to q3_K/ {n++} END {print "up q3_K:",   n+0, "(expect 38)"}' ~/m3c/quantize.log
     awk '/ffn_(gate|up)_exps\.weight/ && /converting to q2_K/ {n++} END {print "gate/up q2_K:", n+0, "(expect 0)"}' ~/m3c/quantize.log
     awk '/ffn_down_exps\.weight/ && /converting to q3_K/ {n++} END {print "down q3_K:", n+0, "(expect 38, as in M2)"}' ~/m3c/quantize.log
   Stop if any count differs from its expected value.
   stat -c %s ~/m3c/LFM2.5-24B-A2B-CEIL-Q2_K-gu-Q3_K.gguf; sha256sum ~/m3c/LFM2.5-24B-A2B-CEIL-Q2_K-gu-Q3_K.gguf | tee ~/m3c/sha256.txt

4. Score it against T7's saved REF logits, exactly as the M3x screen:
   bash -c 'set -o pipefail; T="$HOME/r1-t7-20261017-093233"
     test -s "$T/ref.kld" || { echo "ref.kld missing: stop"; exit 1; }
     systemd-inhibit --what=idle:sleep:handle-lid-switch --why=bench \
       "$T/llama.cpp/build-host/bin/llama-perplexity" -m "$HOME/m3c/LFM2.5-24B-A2B-CEIL-Q2_K-gu-Q3_K.gguf" \
       --kl-divergence --kl-divergence-base "$T/ref.kld" \
       -c 1024 -b 1024 --chunks 20 -t 8 -fa on \
       > "$HOME/m3c/kld-ceil.log" 2>&1; echo "score exit=$?"'
   (must print "score exit=0"; --kl-divergence must be present: without it, --kl-divergence-base would WRITE to ref.kld)

5. Report and copy back (no model):
   grep -E "^Mean PPL\(Q\)|^Mean    KLD|^99.0%   KLD|^Same top p" ~/m3c/kld-ceil.log
   date -Iseconds | tee ~/m3c/end.txt
   tar -czf ~/m3c-ceiling.tar.gz -C ~/m3c start.txt end.txt t7-bins-before.sha256 t7-bins-after.check \
       build-quantize.log quantize-help.txt quantize-bin.sha256 quantize.log sha256.txt kld-ceil.log
   sha256sum ~/m3c-ceiling.tar.gz
   scp -o HostKeyAlias=ventunoq.local ~/m3c-ceiling.tar.gz arduino@192.168.1.39:~/r1-incoming/
Keep the .gguf until the result is discussed.
