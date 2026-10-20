#!/bin/bash
# offline tests for b1_cpu_weight_check.py: synthetic logs in the scheduler's fixed-width format, a 2-block table
D=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; fails=0; n=0
printf 'name\tshape\ttype\tfile_bytes\tnpu_alloc_bytes\trole\toffset\n' > "$W/t.tsv"
for t in output_norm.weight token_embd.weight blk.0.attn_qkv.weight blk.0.ffn_down.weight blk.1.attn_q.weight; do
  printf '%s\t1\tQ2_0\t1\t1\t0\t0\n' "$t" >> "$W/t.tsv"; done
cat > "$W/gen.py" <<'PY'
import sys
# spec lines: L <layer> <dev> | S <n> <backend> | N <op> <name> <src>[,<src>...]
def col(name, dev): return f"{name[:20]:>20} (  10K) [{dev[:5]:<5} {'':8}]"
out, k = [], 0
for l in open(sys.argv[1]).read().splitlines():
    f = l.split()
    if f[0] == "L": out.append(f"0.00.001.000 I load_tensors: layer {f[1]:>3} assigned to device {f[2]}, is_swa = 0")
    elif f[0] == "S": out.append(f"## SPLIT #{f[1]}: {f[2]} # 0 inputs"); dev = f[2]
    elif f[0] == "N":
        k += 1; srcs = "".join("0.00.001.000 D " + col(s, dev) for s in f[3].split(","))
        out.append(f"0.00.001.000 D node #{k:>3} ({f[1]:>10}): {col(f[2], dev)} use=1,c=1:{srcs}")
print("\n".join(out))
PY
good='L 0 HTP0:0
L 1 HTP0:0
L 2 HTP0:0
S 0 CPU
N GET_ROWS model.input_embed token_embd.weight,inp_tokens
S 1 HTP0:0
N MUL_MAT node_5 blk.0.attn_qkv.weight,attn_norm-0
N MUL_MAT node_6 blk.0.ffn_down.weight,x
N MUL_MAT node_7 blk.1.attn_q.weight,y
N MUL out output_norm.weight,z
S 2 CPU
N SET_ROWS cache_k_l3 CPU#k-3#0,idx
N MUL_MAT kq-3 cache_k_l3,CPU#q-3#0
N SOFT_MAX kq_soft-3 kq-3'
expect() { local name=$1 want=$2 spec=$3; n=$((n + 1))
  printf '%s\n' "$spec" > "$W/s$n"; python3 -I "$W/gen.py" "$W/s$n" > "$W/l$n"
  python3 -I "$D/b1_cpu_weight_check.py" "$W/l$n" --tensors "$W/t.tsv" --session HTP0:0 > "$W/o$n" 2>&1; got=$?
  [ "$got" = "$want" ] && echo "ok   $name (rc $got: $(tail -1 "$W/o$n"))" || { echo "FAIL $name (rc $got, wanted $want): $(tr '\n' ' ' < "$W/o$n")"; fails=$((fails + 1)); }; }
expect "attention and cache writes on the CPU, every weight on the session: OK" 0 "$good"
grep -q "CPU split inventory: GET_ROWS 1, MUL_MAT 1, SET_ROWS 1, SOFT_MAX 1" "$W/o$n" && echo "ok   the CPU inventory is printed" || { echo "FAIL inventory: $(grep inventory "$W/o$n")"; fails=$((fails + 1)); }; n=$((n + 1))
expect "a CPU node reads a block weight copied to the CPU: DIFF" 1 "$good
N MUL_MAT node_9 CPU#blk.1.attn_q.weight#0,x"
expect "a CPU node reads a block weight in place: DIFF" 1 "$good
N MUL_MAT node_9 blk.0.ffn_down.weight,x"
expect "a CPU node reads output_norm.weight: DIFF" 1 "$good
N MUL out2 output_norm.weight,x"
expect "token_embd.weight under a CPU op other than GET_ROWS: DIFF" 1 "$good
N MUL_MAT logits token_embd.weight,x"
expect "a layer on the CPU: DIFF" 1 "$(printf '%s\n' "$good" | sed 's/^L 2 HTP0:0$/L 2 CPU/')"
expect "a block weight never read under the session: DIFF" 1 "$(printf '%s\n' "$good" | grep -v blk.1.attn_q)"
expect "no loader lines: INVALID" 3 "$(printf '%s\n' "$good" | grep -v '^L')"
expect "no graph: INVALID" 3 "$(printf '%s\n' "$good" | grep '^L')"
# the last load phase only: an earlier phase with a layer elsewhere is ignored
expect "an earlier phase is ignored: OK" 0 "L 0 CPU
S 0 CPU
N MUL_MAT node_1 blk.0.attn_qkv.weight,x
$good"
echo "failures: $fails of $n"; exit $fails
