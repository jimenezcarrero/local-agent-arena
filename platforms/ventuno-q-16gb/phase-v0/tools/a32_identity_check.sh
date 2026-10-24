#!/bin/bash
# a32_identity_check.sh (D187, phase-v1/v1-plan-4B.txt section 3.2): A32-5's runtime is the declared one. Prints one
# line; exit 0 only if
#   - the campaign package P (836d57176) is exactly its committed manifest (pkg_identity.py check
#     ~/v0/pkg-identity-836d57176.txt, D176),
#   - the patched DSP library ~/v0/htp-retry/libggml-htp-v75.so has its declared sha256 and ~/v0/farf/llama-server.farf
#     holds 0x1f (htp_retry_check.sh's two checks, same expected values, D137),
#   - the model file has its declared sha256 (V0e A32-5 did not hash it at every start; B4 and B9 do).
# Used by phase-v1/tools/a32_server.sh before every start and by v1_batch.sh a32 at launch and after every arena.
PKGID=${PKGID:-python3 $HOME/v0/pkg_identity.py}; A32MAN=${A32MAN:-$HOME/v0/pkg-identity-836d57176.txt}
P=${P:-$HOME/v0/hexpkg/pkg-linux}; HTPR=${HTPR:-$HOME/v0/htp-retry}; FARF=${FARF:-$HOME/v0/farf}
RETRY_SHA=${RETRY_SHA:-aa2ae2a978d95935b763234c1a6cefe27f42c1cf98d67f041c17f13210fedde2}
A32M=${A32M:-$HOME/v0/models/q40/NeoHorse-1-4B-q4_0-pure.gguf}
A32M_SHA=${A32M_SHA:-f822fa2602af45d802e54bac518bab3f62b08943029626114a474afc3d8f3049}
p=$($PKGID check "$A32MAN" "$P" 2>&1); prc=$?
m=$(sha256sum "$A32M" 2>/dev/null | cut -d' ' -f1); r=$(sha256sum "$HTPR/libggml-htp-v75.so" 2>/dev/null | cut -d' ' -f1)
f=$(cat "$FARF/llama-server.farf" 2>/dev/null)
if [ $prc = 0 ] && [ "$m" = "$A32M_SHA" ] && [ "$r" = "$RETRY_SHA" ] && [ "$f" = 0x1f ]; then
  echo "OK A32-5 package $(echo "$p" | tail -1 | sed 's/^RESULT pkg-identity: //'), htp-retry sha256 ${r:0:16}..., farf $f, model sha256 ${m:0:16}..."; exit 0; fi
why=; [ $prc = 0 ] || why="package: $(echo "$p" | grep -m1 -v '^RESULT' | head -c 160) ($(echo "$p" | tail -1))"
[ "$r" = "$RETRY_SHA" ] || why="${why:+$why; }htp-retry sha256 '${r:-missing}' (want ${RETRY_SHA:0:16}...)"
[ "$f" = 0x1f ] || why="${why:+$why; }farf '${f:-missing}' (want 0x1f)"
[ "$m" = "$A32M_SHA" ] || why="${why:+$why; }model sha256 '${m:-missing}' (want ${A32M_SHA:0:16}...)"
echo "FAILED A32-5 identity: $why"; exit 1
