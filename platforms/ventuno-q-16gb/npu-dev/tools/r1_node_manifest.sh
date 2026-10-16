#!/bin/bash
# r1_node_manifest.sh <node dump> (NPU dev plan R1): the completion manifest of an R1_NODE_DUMP capture, written right
# after the capture and committed beside it. Fails (exit 1) unless every GRAPH_BEGIN is closed by a GRAPH_END and the
# file ends after a GRAPH_END. Output: "r1-node-dump-manifest v1", "graphs G", "graph i n_nodes N logged K".
set -euo pipefail
f=$1
[ -s "$f" ] || { echo "r1_node_manifest: $f missing or empty" >&2; exit 1; }
awk '
  /^GRAPH_BEGIN n_nodes=/ { if (open) exit 2; open = 1; split($2, a, "="); n = a[2]; next }
  /^GRAPH_END logged=/    { if (!open) exit 3; open = 0; split($2, a, "="); g++; line[g] = "graph " g " n_nodes " n " logged " a[2]; next }
  END { if (open || g == 0) exit 4; print "r1-node-dump-manifest v1"; print "graphs " g; for (i = 1; i <= g; i++) print line[i] }
' "$f" || { echo "r1_node_manifest: $f is not a complete framed dump" >&2; exit 1; }
