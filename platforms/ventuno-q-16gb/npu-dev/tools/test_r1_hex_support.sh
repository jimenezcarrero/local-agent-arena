#!/bin/bash
# test_r1_hex_support.sh <r1_hex_support binary> <node dump> (NPU dev plan R1, review of cbe3b51): the support checker
# must fail closed. Builds its manifest with r1_node_manifest.sh, then checks the complete dump passes (exit 0), a
# too-small VTCM is refused (exit 1), and every broken input is rejected (exit 3): missing dump, missing manifest,
# empty dump, truncated dump, a graph removed, a one-node dump (and its own manifest differing from the capture's), a
# bad record, an unknown record, a NODE without its T,
# a wrong GRAPH_END count, a repeated name field, a manifest from another dump. Temporary files are removed on exit.
set -uo pipefail
H=$1; DUMP=$2; HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; n=0
expect() {  # <name> <wanted rc> <cmd...>
    local name=$1 want=$2; shift 2; n=$((n + 1))
    "$@" > "$W/out" 2> "$W/err"; local rc=$?
    if [ "$rc" = "$want" ]; then echo "ok   $name (rc $rc) $(tail -1 "$W/out")"
    else echo "FAIL $name (rc $rc, wanted $want) $(tail -1 "$W/out")"; fails=$((fails + 1)); fi
}
"$HERE/r1_node_manifest.sh" "$DUMP" > "$W/m" || { echo "FAIL manifest of the complete dump"; exit 1; }
G=$(sed -n 's/^graphs //p' "$W/m")
expect "complete dump passes" 0 "$H" "$DUMP" "$W/m"
expect "VTCM 1 MiB refuses ops (control)" 1 "$H" "$DUMP" "$W/m" 1048576
expect "missing dump" 3 "$H" "$W/none" "$W/m"
expect "missing manifest" 3 "$H" "$DUMP" "$W/none"
: > "$W/empty"; expect "empty dump" 3 "$H" "$W/empty" "$W/m"
L=$(wc -l < "$DUMP"); head -n $((L / 2)) "$DUMP" > "$W/trunc"; expect "truncated dump (half)" 3 "$H" "$W/trunc" "$W/m"
head -n $((L - 1)) "$DUMP" > "$W/trunc1"; expect "truncated dump (last line)" 3 "$H" "$W/trunc1" "$W/m"
last=$(grep -n '^GRAPH_BEGIN' "$DUMP" | tail -1 | cut -d: -f1); head -n $((last - 1)) "$DUMP" > "$W/fewer"
expect "last graph removed" 3 "$H" "$W/fewer" "$W/m"
first_npu=$(grep -n '^NODE .*backend=RPC' "$DUMP" | head -1 | cut -d: -f1)
{ echo "GRAPH_BEGIN n_nodes=$(sed -n 's/^GRAPH_BEGIN n_nodes=//p' "$DUMP" | head -1)"
  awk -v s="$first_npu" 'NR == s { print; next } NR > s && /^(T|S) / { print; next } NR > s { exit }' "$DUMP"
  echo "GRAPH_END logged=1"; } > "$W/one"
expect "one-node dump against the manifest" 3 "$H" "$W/one" "$W/m"
"$HERE/r1_node_manifest.sh" "$W/one" > "$W/m1"
# a dump and a manifest replaced together are self-consistent; what pins coverage is the manifest committed at capture
# time (and the dump's sha256 in provenance): a one-node dump's own manifest must differ from it
expect "one-node dump's own manifest differs from the capture's" 1 cmp -s "$W/m1" "$W/m"
sed '0,/^T -1 op=/s/ne=\([0-9]*\),/ne=x\1,/' "$DUMP" > "$W/badnum"; expect "non-numeric field" 3 "$H" "$W/badnum" "$W/m"
sed '0,/^NODE /s/^NODE /BOGUS 0\nNODE /' "$DUMP" > "$W/unknown"; expect "unknown record" 3 "$H" "$W/unknown" "$W/m"
awk '/^T -1 / && !done { done = 1; next } { print }' "$DUMP" > "$W/noT"; expect "NODE without its T record" 3 "$H" "$W/noT" "$W/m"
sed '0,/^GRAPH_END logged=/s/^GRAPH_END logged=\([0-9]*\)/GRAPH_END logged=1\1/' "$DUMP" > "$W/badend"
expect "wrong GRAPH_END count" 3 "$H" "$W/badend" "$W/m"
sed '0,/^T -1 /s/ params=/ name=again params=/' "$DUMP" > "$W/dupname"; expect "repeated name field" 3 "$H" "$W/dupname" "$W/m"
sed '3s/n_nodes [0-9]*/n_nodes 1/' "$W/m" > "$W/m-other"; expect "manifest of another dump" 3 "$H" "$DUMP" "$W/m-other"
echo "failures: $fails of $n"; exit $fails
