#!/bin/bash
# fixture tests for the real a32_identity_check.sh (D187), as test_b4_identity_check.sh: a tiny package with a manifest
# made by the real pkg_identity.py, a patched-library stand-in, a .farf file and a model file under a temp dir; the clean
# case passes and each mutation fails.
D=$(cd "$(dirname "$0")" && pwd); fails=0
case1() { local name=$1 want=$2 mut=$3
  T=$(mktemp -d); mkdir -p $T/p/lib $T/p/bin $T/htpr $T/farf
  echo lib > $T/p/lib/libggml.so.0; ln -s libggml.so.0 $T/p/lib/libggml.so; echo bin > $T/p/bin/llama-server
  (cd $T/p && sha256sum ./lib/libggml.so.0 ./bin/llama-server) > $T/rec.sha256
  python3 -I $D/pkg_identity.py make $T/rec.sha256 $T/p > $T/man.txt || { echo "FAIL $name: manifest not made"; fails=$((fails+1)); rm -rf $T; return; }
  echo patched > $T/htpr/libggml-htp-v75.so; echo 0x1f > $T/farf/llama-server.farf; echo model > $T/m.gguf
  local msha=$(sha256sum $T/m.gguf | cut -d' ' -f1) rsha=$(sha256sum $T/htpr/libggml-htp-v75.so | cut -d' ' -f1)
  eval "$mut"
  out=$(PKGID="python3 -I $D/pkg_identity.py" A32MAN=$T/man.txt P=$T/p HTPR=$T/htpr FARF=$T/farf RETRY_SHA=$rsha \
        A32M=$T/m.gguf A32M_SHA=$msha bash $D/a32_identity_check.sh 2>&1); rc=$?
  if [ $rc = $want ] && { { [ $want = 0 ] && [[ "$out" == OK* ]]; } || { [ $want = 1 ] && [[ "$out" == FAILED* ]]; }; }; then echo "ok   $name (rc $rc)"
  else echo "FAIL $name (rc $rc want $want): $out"; fails=$((fails+1)); fi
  rm -rf $T; }
case1 clean 0 :
case1 model-changed 1 'echo other > $T/m.gguf'
case1 model-missing 1 'rm $T/m.gguf'
case1 package-file-changed 1 'echo patched > $T/p/lib/libggml.so.0'
case1 package-extra-file 1 'echo x > $T/p/lib/libextra.so'
case1 package-link-retargeted 1 'ln -sfn ./libggml.so.0 $T/p/lib/libggml.so'
case1 htp-retry-changed 1 'echo other > $T/htpr/libggml-htp-v75.so'
case1 htp-retry-missing 1 'rm $T/htpr/libggml-htp-v75.so'
case1 farf-changed 1 'echo 0x00 > $T/farf/llama-server.farf'
echo "failures: $fails"; exit $fails
