#!/bin/bash
# mac_rewrite.sh prepare|push — remove the board's and the access point's MAC addresses from the history of
# jimenezcarrero/local-agent-arena. Never prints a MAC value. Works only in this scratch directory.
#   prepare  records the remote's refs, clones them (orig.git, never modified), finds the targets (mac_targets.py;
#            every MAC outside tools/, the test fixtures kept), limits the rewrite to the commits that introduce a
#            target and their descendants (mac_scope.py), rewrites a copy (new.git) with mac_filter.py, and verifies
#            it commit by commit against orig.git (mac_verify.py). Writes READY only if every step and VERIFY passed.
#            Pushes nothing.
#   push     requires READY, its recorded hashes and an unchanged remote (every head and tag exactly as recorded);
#            pushes all branches in one atomic push, each with --force-with-lease=<ref>:<recorded id>; then reads the
#            remote back and compares it with the verified refs.
set -euo pipefail
S=/tmp/claude-1000/-home-arduino-Repositories-local-agent-arena/3aef4a52-ae05-468e-89f2-8a9a5201455c/scratchpad
W=$S/rewrite; O=$W/orig.git; N=$W/new.git
URL=https://github.com/jimenezcarrero/local-agent-arena.git
remote_refs(){ git ls-remote "$URL" 'refs/heads/*' 'refs/tags/*' | sort -k2; }
case ${1:-} in
prepare)
  rm -rf "$W"; mkdir -p "$W"; chmod 700 "$W"; cd "$W"
  remote_refs > remote-refs.txt
  echo "remote heads and tags recorded: $(wc -l < remote-refs.txt) ($(grep -c refs/tags/ remote-refs.txt || true) tags)"
  git clone -q --bare "$URL" "$O"
  git -C "$O" for-each-ref --format='%(objectname)	%(refname)' refs/heads refs/tags | sort -k2 > cloned-refs.txt
  cmp -s <(tr ' ' '\t' < remote-refs.txt) cloned-refs.txt || { echo "STOP: the remote changed while cloning"; exit 1; }
  echo "== targets"
  python3 -I "$S/mac_targets.py" "$O" "$W/candidates.txt" "$W/targets.txt"
  [ -s targets.txt ] || { echo "STOP: no targets"; exit 1; }
  echo "== scope"
  python3 -I "$S/mac_scope.py" "$O" "$W/targets.txt" "$W/excludes.txt"
  git clone -q --bare --no-hardlinks "$O" "$N"; git -C "$N" remote remove origin
  echo "== rewrite"
  git -C "$N" fast-export --all --signed-tags=strip --reencode=no --reference-excluded-parents \
      --export-marks="$W/old.marks" $(cat excludes.txt) \
    | TARGETS="$W/targets.txt" python3 -I "$S/mac_filter.py" \
    | git -C "$N" fast-import --force --quiet --export-marks="$W/new.marks"
  git -C "$N" reflog expire --expire=now --all; git -C "$N" gc -q --prune=now
  echo "== verify"
  python3 -I "$S/mac_verify.py" "$O" "$N" "$W/old.marks" "$W/new.marks" "$W/targets.txt" "$W/commit-map.txt" \
    | tee verify-report.txt
  echo "== GitHub copies a push cannot change"
  P=$W/pulls.git; git init -q --bare "$P"; git -C "$P" fetch -q "$URL" '+refs/pull/*/head:refs/pull/*/head'
  n=0; a=""
  for r in $(git -C "$P" for-each-ref --format='%(refname)' refs/pull); do
    n=$((n+1))
    # grep -c reads to the end: with grep -q, rev-list's SIGPIPE under pipefail would turn a match into a miss
    if [ "$(git -C "$P" rev-list "$r" | grep -cxFf <(cut -d' ' -f1 commit-map.txt))" -gt 0 ]; then a="$a ${r#refs/pull/}"; fi
  done
  a=$(echo $a | tr ' ' '\n' | sed 's#/head##' | sort -n | tr '\n' ' ')
  echo "pull request refs $n; holding a rewritten commit: $(echo $a | wc -w) (PRs: $a)" | tee -a verify-report.txt
  echo "tags: $(grep -c refs/tags/ remote-refs.txt || true) (none to rewrite or push if 0)" | tee -a verify-report.txt
  git -C "$N" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort -k2 > new-refs.txt
  { echo "remote-refs $(sha256sum < remote-refs.txt | cut -c1-64)"; echo "new-refs $(sha256sum < new-refs.txt | cut -c1-64)"
    echo "targets $(sha256sum < targets.txt | cut -c1-64)"; echo "report $(sha256sum < verify-report.txt | cut -c1-64)"; } > READY
  echo "READY written: push may run after the report is reviewed"
  ;;
push)
  cd "$W"; [ -f READY ] || { echo "STOP: no READY (prepare did not pass)"; exit 1; }
  for f in remote-refs new-refs targets; do
    [ "$(grep "^$f " READY | cut -d' ' -f2)" = "$(sha256sum < $f.txt | cut -c1-64)" ] || { echo "STOP: $f.txt changed after verification"; exit 1; }
  done
  [ "$(grep '^report ' READY | cut -d' ' -f2)" = "$(sha256sum < verify-report.txt | cut -c1-64)" ] || { echo "STOP: report changed"; exit 1; }
  grep -qx 'VERIFY: PASS' verify-report.txt || { echo "STOP: verification did not pass"; exit 1; }
  remote_refs > remote-now.txt
  cmp -s remote-refs.txt remote-now.txt || { echo "STOP: the remote changed since prepare; run prepare again"; exit 1; }
  args=()
  while read -r old ref; do
    new=$(awk -v r="$ref" '$2==r{print $1}' new-refs.txt)
    [ -n "$new" ] || { echo "STOP: $ref missing from the rewrite"; exit 1; }
    [ "$new" = "$old" ] && continue
    args+=("--force-with-lease=$ref:$old" "$new:$ref")
  done < <(awk '{print $1, $2}' remote-refs.txt)
  echo "refs to update: $(( ${#args[@]} / 2 )) of $(wc -l < remote-refs.txt)"
  [ ${#args[@]} -gt 0 ] || { echo "nothing to push"; exit 0; }
  leases=(); refspecs=()
  for ((i=0; i<${#args[@]}; i+=2)); do leases+=("${args[i]}"); refspecs+=("${args[i+1]}"); done
  git -C "$N" push --atomic "${leases[@]}" "$URL" "${refspecs[@]}"
  remote_refs | awk '{print $1, $2}' > remote-after.txt
  if cmp -s remote-after.txt new-refs.txt; then echo "PUSH: remote equals the verified refs"; else echo "PUSH: remote differs from the verified refs, check"; exit 1; fi
  ;;
*) echo "usage: $0 prepare|push"; exit 9;;
esac
