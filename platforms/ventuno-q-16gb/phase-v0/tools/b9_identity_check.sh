#!/bin/bash
# b9_identity_check.sh (D180, v0e-plan-B9.txt): set B9's own runtime is the declared one. Prints one line; exit 0 only if
#   - the ff5a2337 package PB is exactly its committed manifest (pkg_identity.py check ~/v0/pkg-identity-ff5a2337.txt),
#   - the model file has its declared sha256 (checked at every call: at launch, before every step and session, after),
#   - ~/npu-dev/htp-retry-ff5a2337/libggml-htp-v75.so, the retry build B9's ADSP_LIBRARY_PATH names after the .farf
#     directory, has its declared sha256 (B1f),
#   - ~/npu-dev/farf/llama-server.farf, the DSP logging file B9's ADSP_LIBRARY_PATH names first, is the campaign's.
# b4_identity_check.sh's checks with B9's model and the retry library; used where B4's is (v0d_admit.sh B9,
# v0e_A_retry.sh B9). The campaign's baseline probe keeps its own checks (htp_retry_check.sh, pkg-identity-836d57176.txt).
PKGID=${PKGID:-python3 $HOME/v0/pkg_identity.py}; B9MAN=${B9MAN:-$HOME/v0/pkg-identity-ff5a2337.txt}
PB=${PB:-$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337}
B9M=${B9M:-$HOME/npu-dev/b1/models/Ternary-Bonsai-2-9B-Q2_0.gguf}
B9M_SHA=${B9M_SHA:-1f884aa56aacd2bbbb2e4b7abaead2b1102b74a9c75a23fc33dab916813a384d}
B9LIB=${B9LIB:-$HOME/npu-dev/htp-retry-ff5a2337/libggml-htp-v75.so}
B9LIB_SHA=${B9LIB_SHA:-65e50e678cc3426f1160748d0e4d1b2c5319fa3004cdf754af109ecd278ad4f5}
B9FARF=${B9FARF:-$HOME/npu-dev/farf/llama-server.farf}
FARF_SHA=${FARF_SHA:-7acc31cde8878ed69e7db525b71c42440f49d29972de44d6c0653564a613e645}
p=$($PKGID check "$B9MAN" "$PB" 2>&1); prc=$?
m=$(sha256sum "$B9M" 2>/dev/null | cut -d' ' -f1); l=$(sha256sum "$B9LIB" 2>/dev/null | cut -d' ' -f1)
f=$(sha256sum "$B9FARF" 2>/dev/null | cut -d' ' -f1)
if [ $prc = 0 ] && [ "$m" = "$B9M_SHA" ] && [ "$l" = "$B9LIB_SHA" ] && [ "$f" = "$FARF_SHA" ]; then
  echo "OK B9 package $(echo "$p" | tail -1 | sed 's/^RESULT pkg-identity: //'), model sha256 ${m:0:16}..., retry library ${l:0:16}..., farf ${f:0:16}..."; exit 0; fi
why=; [ $prc = 0 ] || why="package: $(echo "$p" | grep -m1 -v '^RESULT' | head -c 160) ($(echo "$p" | tail -1))"
[ "$m" = "$B9M_SHA" ] || why="${why:+$why; }model sha256 '${m:-missing}' (want ${B9M_SHA:0:16}...)"
[ "$l" = "$B9LIB_SHA" ] || why="${why:+$why; }retry library sha256 '${l:-missing}' (want ${B9LIB_SHA:0:16}...)"
[ "$f" = "$FARF_SHA" ] || why="${why:+$why; }farf sha256 '${f:-missing}' (want ${FARF_SHA:0:16}...)"
echo "FAILED B9 identity: $why"; exit 1
