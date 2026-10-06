#!/bin/bash
# decision-table tests for v0d_lib.sh decide()
source ~/v0/v0d_lib.sh; fails=0
chk() { local got; got=$(decide $1 $2 $3); [ "$got" = "$4" ] && echo "ok   $1 attempt $2 $3 -> $got" || { echo "FAIL $1 attempt $2 $3 -> $got (want $4)"; fails=$((fails+1)); }; }
for m in explore admit probe; do chk PASS 1 $m next; chk EVIDENCE 1 $m stop; chk EVIDENCE 2 $m stop; chk HANG 1 $m fault; chk DEVFAULT 2 $m fault; chk BOGUS 1 $m stop; chk "" 1 $m stop; done
chk LOADFAIL 1 explore recover_retry; chk LOADFAIL 2 explore skip
chk LOADFAIL 1 admit recover_retry;   chk LOADFAIL 2 admit stop
chk LOADFAIL 1 probe retry_later;     chk LOADFAIL 2 probe retry_later
echo "failures: $fails"; exit $fails
