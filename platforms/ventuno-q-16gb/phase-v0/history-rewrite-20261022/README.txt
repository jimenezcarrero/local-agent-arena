History rewrite of 2026-10-22 (D182): the access point's and the board's MAC addresses removed from every commit.
The tools ran from the agent's scratch directory (the paths in mac_rewrite.sh); they are kept here as the record of
what ran, with their reviewed outputs. No MAC value is in any of these files (scan_identifiers.py: CLEAN apart from
the test's fake addresses); the target list itself was never committed.
  mac_rewrite.sh     prepare (clone, targets, scope, rewrite, verify, READY) and push (gated, atomic, leased)
  mac_targets.py     every MAC-like value in all history; targets = those outside tools/ (2), fixtures kept (6)
  mac_scope.py       commits introducing a target and their descendants (335); the other 195 untouched
  mac_filter.py      fast-export stream filter, exact-length records only
  mac_verify.py      commit-by-commit verification against the untouched original; residual scan
  test_mac_verify.sh regressions for the verifier and the target discovery (9/9)
  verify-report.txt  prepare's report (VERIFY: PASS); READY its hashes
  remote-refs.txt    the remote's heads before the push; new-refs.txt the verified rewritten heads;
  remote-after.txt   the remote read back after the push (equal to new-refs.txt)
  commit-map.txt     old -> new commit ids (335 lines)
