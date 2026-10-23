#!/bin/bash
# check_sampling.sh <model.gguf> <hf-repo-id> [base-repo-id]
#
# Run this before a model's FIRST run, and paste the output into the platform's
# files.txt. It reports the three places sampling comes from:
#   - what the GGUF carries (llama.cpp applies general.sampling.* silently)
#   - what the model card recommends, with the card's revision, so the exact
#     text used can be found again later
#   - llama.cpp's defaults, which apply when neither of the above does
#
# Settings are pinned per model: once a model's runs start, they do not change,
# or the repeats of a cell stop being comparable. See sampling-reference.md.
set -u
GGUF="${1:?usage: check_sampling.sh <model.gguf> <hf-repo-id> [base-repo-id]}"
REPO="${2:?usage: check_sampling.sh <model.gguf> <hf-repo-id> [base-repo-id]}"
BASE="${3:-}"

echo "# checked $(date -Is)"
echo "## GGUF: $(basename "$GGUF")"
python3 - "$GGUF" <<'EOF'
import struct,sys
fh=open(sys.argv[1],'rb')
magic,ver,nt,nkv=struct.unpack('<IIQQ',fh.read(24))
def rs():
    n=struct.unpack('<Q',fh.read(8))[0]; return fh.read(n).decode('utf-8','replace')
def rv(t):
    T={0:'B',1:'b',2:'H',3:'h',4:'I',5:'i',6:'f',7:'?',10:'Q',11:'q',12:'d'}
    if t==8: return rs()
    if t==9:
        et,ln=struct.unpack('<IQ',fh.read(12)); return [rv(et) for _ in range(ln)]
    return struct.unpack('<'+T[t],fh.read(struct.calcsize('<'+T[t])))[0]
out={}
for _ in range(nkv):
    k=rs(); t=struct.unpack('<I',fh.read(4))[0]; v=rv(t)
    if 'sampling' in k: out[k]=round(v,4) if isinstance(v,float) else v
print("  embedded sampling:", out or "none — llama.cpp defaults apply unless you pass flags")
EOF

for r in "$REPO" $BASE; do
  echo "## card: $r"
  rev=$(curl -sL "https://huggingface.co/api/models/$r" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); print(d.get('sha','?')[:12], d.get('lastModified','?'))
except Exception: print('unavailable')")
  echo "  revision: $rev"
  curl -sL "https://huggingface.co/$r/raw/main/README.md" 2>/dev/null \
    | grep -iE 'temperature|temp=|top_p|top_k|min_p|presence_penalty|repetition_penalty|frequency_penalty' \
    | sed 's/^[[:space:]]*/  /' | cut -c1-200 | sort -u | head -12
done

echo "## llama.cpp defaults if nothing above applies: temp 0.8, top_k 40, top_p 0.95, min_p 0.05, no penalties"
echo "## after starting the server, confirm with: curl -s localhost:8080/props | grep -oE '\"(temperature|top_k|top_p|min_p|presence_penalty)\":[^,]*'"
