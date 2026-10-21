#!/bin/bash
# b4_identity_check.sh (D178, v0e-plan-B4.txt): set B4's own runtime is the declared one. Prints one line; exit 0 only if
#   - the ff5a2337 package PB is exactly its committed manifest (pkg_identity.py check ~/v0/pkg-identity-ff5a2337.txt),
#   - the model file has its declared sha256 (checked at every call: at launch, before every step and session, after),
#   - ~/npu-dev/farf/llama-server.farf, the DSP logging file B4's ADSP_LIBRARY_PATH names first, is the campaign's.
# Used by v0d_admit.sh B4 (at entry, as PRE_LOAD before every step's probe and load, after the set) and by
# v0e_A_retry.sh B4 (with the campaign checks, before every baseline load and every session and after every session).
# The campaign's baseline probe keeps its own checks (htp_retry_check.sh, pkg-identity-836d57176.txt).
PKGID=${PKGID:-python3 $HOME/v0/pkg_identity.py}; B4MAN=${B4MAN:-$HOME/v0/pkg-identity-ff5a2337.txt}
PB=${PB:-$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337}
B4M=${B4M:-$HOME/npu-dev/b1/models/Ternary-Bonsai-2-4B-Q2_0.gguf}
B4M_SHA=${B4M_SHA:-64a5183b44921bdb5ac4a6f5f92007821d6ebe5c66997d3c147fd214ab9433d4}
B4FARF=${B4FARF:-$HOME/npu-dev/farf/llama-server.farf}
FARF_SHA=${FARF_SHA:-7acc31cde8878ed69e7db525b71c42440f49d29972de44d6c0653564a613e645}
p=$($PKGID check "$B4MAN" "$PB" 2>&1); prc=$?
m=$(sha256sum "$B4M" 2>/dev/null | cut -d' ' -f1); f=$(sha256sum "$B4FARF" 2>/dev/null | cut -d' ' -f1)
if [ $prc = 0 ] && [ "$m" = "$B4M_SHA" ] && [ "$f" = "$FARF_SHA" ]; then
  echo "OK B4 package $(echo "$p" | tail -1 | sed 's/^RESULT pkg-identity: //'), model sha256 ${m:0:16}..., farf ${f:0:16}..."; exit 0; fi
why=; [ $prc = 0 ] || why="package: $(echo "$p" | grep -m1 -v '^RESULT' | head -c 160) ($(echo "$p" | tail -1))"
[ "$m" = "$B4M_SHA" ] || why="${why:+$why; }model sha256 '${m:-missing}' (want ${B4M_SHA:0:16}...)"
[ "$f" = "$FARF_SHA" ] || why="${why:+$why; }farf sha256 '${f:-missing}' (want ${FARF_SHA:0:16}...)"
echo "FAILED B4 identity: $why"; exit 1
