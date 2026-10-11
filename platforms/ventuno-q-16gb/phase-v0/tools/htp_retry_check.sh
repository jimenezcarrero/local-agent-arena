#!/bin/bash
# htp_retry_check.sh (D137): the patched DSP library and the DSP logging file are the declared ones. Prints one line;
# exit 0 only if ~/v0/htp-retry/libggml-htp-v75.so has sha256 RETRY_SHA and ~/v0/farf/llama-server.farf holds 0x1f.
# Used as PRE_LOAD by v0d_admit.sh AR (before every step's probe and load) and after the set.
HTPR=${HTPR:-$HOME/v0/htp-retry}; FARF=${FARF:-$HOME/v0/farf}
RETRY_SHA=${RETRY_SHA:-aa2ae2a978d95935b763234c1a6cefe27f42c1cf98d67f041c17f13210fedde2}
got=$(sha256sum "$HTPR/libggml-htp-v75.so" 2>/dev/null | cut -d' ' -f1); farf=$(cat "$FARF/llama-server.farf" 2>/dev/null)
if [ "$got" = "$RETRY_SHA" ] && [ "$farf" = 0x1f ]; then echo "OK htp-retry sha256 ${got:0:16}..., farf $farf"; exit 0; fi
echo "FAILED htp-retry sha256 '${got:-missing}' (want ${RETRY_SHA:0:16}...), farf '${farf:-missing}' (want 0x1f)"; exit 1
