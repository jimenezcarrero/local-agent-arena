#!/usr/bin/env python3
"""offline tests for gguf_tensor_table.py: small synthetic GGUF files (written here, zero data) with hand-computed
allocations, placement and session splits; a local HTTP server with range support for the URL path. No network,
no NPU. Usage: python3 test_gguf_tensor_table.py"""
import contextlib, http.server, io, os, re, struct, sys, tempfile, threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gguf_tensor_table as g

TID = {"F32": 0, "Q4_0": 2, "Q8_0": 8, "Q2_K": 10, "Q3_K": 11, "Q4_K": 12, "Q6_K": 14, "IQ3_XXS": 18}


def gguf(path, arch, n_layer, tensors, kv_extra=(), size_override=None, bad_type=None):
    """tensors: (name, dims, type name); data zero, each tensor aligned to 32. size_override: name -> bytes stored"""
    s = lambda x: struct.pack("<Q", len(x.encode())) + x.encode()
    kvs = [(f"general.architecture", 8, s(arch)), (f"{arch}.block_count", 4, struct.pack("<I", n_layer))]
    for k, t, v in kv_extra:
        kvs.append((k, t, v))
    out = b"GGUF" + struct.pack("<IQQ", 3, len(tensors), len(kvs))
    for k, t, v in kvs:
        out += s(k) + struct.pack("<I", t) + v
    off, data = 0, b""
    for name, dims, ty in tensors:
        tid = bad_type if (bad_type is not None and name == "blk.0.bad.weight") else TID[ty]
        out += s(name) + struct.pack("<I", len(dims)) + struct.pack("<" + "Q" * len(dims), *dims) + struct.pack("<IQ", tid, off)
        nb = (size_override or {}).get(name)
        if nb is None:
            nb = g.nbytes({"type_id": TID[ty], "ne": list(dims) + [1] * (4 - len(dims))})
        pad = (nb + 31) // 32 * 32
        data += b"\0" * pad; off += pad
    out += b"\0" * ((32 - len(out) % 32) % 32)
    open(path, "wb").write(out + data)


def run(path, *args):
    with tempfile.NamedTemporaryFile("r", suffix=".tsv") as tsv, contextlib.redirect_stdout(io.StringIO()) as buf:
        rc = g.main([path, "--tsv", tsv.name, *args])
        rows = {l.split("\t")[0]: l.rstrip("\n").split("\t") for l in open(tsv.name).readlines()[1:]} if rc == 0 else {}
    return rc, buf.getvalue(), rows


fails = 0
def ok(name, cond, text=""):
    global fails
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails += 1; print(text)


T = tempfile.mkdtemp()
# 1. allocation per type, master rule (hand-computed; 128-byte padding)
base = [("token_embd.weight", (512, 64), "Q8_0"), ("blk.0.attn_norm.weight", (7,), "F32"),
        ("blk.0.q3.weight", (512, 40), "Q3_K"),      # ne1 40 -> 64; row 512/32*16 = 256; 256*64 = 16384 (file 8800)
        ("blk.0.q2.weight", (512, 64), "Q2_K"),      # master: row_size 168; *64 = 10752; release: 256*64 = 16384
        ("blk.1.q4k.weight", (256, 32), "Q4_K"),     # 8*20*32 = 5120 (file 4608)
        ("blk.1.q6k.weight", (256, 32), "Q6_K"),     # 8*28*32 = 7168 (file 6720)
        ("blk.1.q40.weight", (64, 33), "Q4_0"),      # ne1 33 -> 64; row 36; 2304 (file 1188 -> gap 1216)
        ("blk.1.iq3.weight", (256, 4), "IQ3_XXS"),   # not a repack type: 392 -> 512
        ("blk.1.exps.weight", (256, 32, 4), "Q2_K"),  # 3-D expert tensor: 84*32*4 = 10752
        ("output_norm.weight", (512,), "F32"), ("output.weight", (512, 64), "Q8_0")]
gguf(f"{T}/a.gguf", "llama", 2, base)
rc, text, rows = run(f"{T}/a.gguf")
want = {"blk.0.attn_norm.weight": 128, "blk.0.q3.weight": 16384, "blk.0.q2.weight": 10752, "blk.1.q4k.weight": 5120,
        "blk.1.q6k.weight": 7168, "blk.1.q40.weight": 2304, "blk.1.iq3.weight": 512, "blk.1.exps.weight": 10752,
        "token_embd.weight": 34816, "output.weight": 34816}
got = {k: int(rows[k][4]) for k in want if k in rows}
ok("master allocation per type (Q3_K/Q4_K/Q6_K tiles, Q2_K at file size, Q4_0 ne1 padding, non-repack, 3-D, 128 pad)",
   rc == 0 and got == want, f"{got}\n{text}")
ok("file bytes from the type table", rows["blk.0.q3.weight"][3] == "8800" and rows["blk.1.q40.weight"][3] == "1188"
   and rows["blk.1.exps.weight"][3] == "10752", text)
ok("offset gaps consistent", "offset gaps consistent: 11/11" in text, text)
rc, text, rows = run(f"{T}/a.gguf", "--rule", "release")
ok("release rule tiles Q2_K at 512 (512/32*16*64 = 16384; the 3-D expert 256/32*16*32*4 = 16384)",
   rows["blk.0.q2.weight"][4] == "16384" and rows["blk.1.exps.weight"][4] == "16384", text)
ok("roles: input, blocks, output", rows["token_embd.weight"][5] == "input" and rows["blk.1.q6k.weight"][5] == "1"
   and rows["output.weight"][5] == "output" and rows["output_norm.weight"][5] == "output", text)

# 2. tied output: token_embd counted again at the output layer; --output-cpu removes the projection
tied = [t for t in base if t[0] != "output.weight"]
gguf(f"{T}/tied.gguf", "llama", 2, tied)
rc, text, _ = run(f"{T}/tied.gguf", "--sessions", "1")
out_line = next(l for l in text.splitlines() if l.startswith("LAYER 2 "))
ok("tied: output layer = output_norm (2048 -> 2048) + token_embd copy (34816)", "tied" in text and
   out_line == f"LAYER 2 {(2048 + 34816) / 2**20:.2f} {(2048 + 34816) / 2**20:.2f}", out_line)
rc, text, _ = run(f"{T}/tied.gguf", "--sessions", "1", "--output-cpu")
out_line = next(l for l in text.splitlines() if l.startswith("LAYER 2 "))
ok("--output-cpu (NPU-R'): the tied copy leaves the output layer", out_line == f"LAYER 2 {2048 / 2**20:.2f} {2048 / 2**20:.2f}", out_line)

# 3. lfm2moe: token_embd_norm is the output norm; head_count_kv per layer (0 = convolution layer); MTP-like block
arr = lambda vals: struct.pack("<IQ", 4, len(vals)) + struct.pack(f"<{len(vals)}I", *vals)
kvx = [("lfm2moe.attention.head_count_kv", 9, arr([0, 2, 0, 2])), ("lfm2moe.attention.head_count", 4, struct.pack("<I", 4)),
       ("lfm2moe.embedding_length", 4, struct.pack("<I", 256))]
lt = [("token_embd.weight", (256, 64), "Q8_0"), ("token_embd_norm.weight", (256,), "F32")] + \
     [(f"blk.{i}.w.weight", (256, 32), "Q4_0") for i in range(5)]     # blk.4 >= block_count 4: goes with the output
gguf(f"{T}/lfm.gguf", "lfm2moe", 4, lt, kvx)
rc, text, rows = run(f"{T}/lfm.gguf", "--ctx", "1024", "--sessions", "1")
ok("lfm2moe: token_embd_norm with the output, block 4 (>= block_count) with the output",
   rows["token_embd_norm.weight"][5] == "output" and rows["blk.4.w.weight"][5] == "output", text)
kv_want = 2 * (2 * 1024 * 2 * 64 * 2)          # layers 1 and 3, head_dim 256/4 = 64, F16 K and V
ok("KV: only the layers with head_count_kv > 0", f"2 attention layers [1, 3], {kv_want / 2**20:.1f} MiB" in text, text)
# qwen35-style recurrent mask
kvq = [("qwen35.attention.head_count_kv", 4, struct.pack("<I", 4)), ("qwen35.attention.head_count", 4, struct.pack("<I", 16)),
       ("qwen35.attention.key_length", 4, struct.pack("<I", 256)),
       ("qwen35.attention.recurrent_layers", 9, struct.pack("<IQ", 7, 4) + bytes([1, 1, 1, 0]))]
gguf(f"{T}/q35.gguf", "qwen35", 4, [("token_embd.weight", (256, 64), "Q8_0")] + [(f"blk.{i}.w.weight", (256, 32), "Q4_0") for i in range(4)], kvq)
rc, text, _ = run(f"{T}/q35.gguf", "--ctx", "32768", "--sessions", "1")
ok("KV: qwen35 recurrent_layers mask (one attention layer, 128 MiB at 32768)", "1 attention layers [3], 128.0 MiB" in text, text)

# 4. session split (equal fractions, upper_bound): 8 blocks + output = 9 indices
gguf(f"{T}/s.gguf", "llama", 8, [("token_embd.weight", (256, 64), "Q8_0")] + [(f"blk.{i}.w.weight", (256, 32), "Q4_0") for i in range(8)]
     + [("output.weight", (256, 64), "Q8_0")])
rc, text, _ = run(f"{T}/s.gguf", "--sessions", "3")
ok("3 sessions, all layers: 0-2, 3-5, 6-8", "HTP0:0 layers 0-2 " in text and "HTP0:1 layers 3-5 " in text
   and "HTP0:2 layers 6-8 " in text, text)
rc, text, _ = run(f"{T}/s.gguf", "--sessions", "3", "--ngl", "8")
ok("3 sessions, -ngl 8: block 0 on the CPU, then 1-3, 4-6, 7-8", "HTP0:0 layers 1-3 " in text and "HTP0:1 layers 4-6 " in text
   and "HTP0:2 layers 7-8 " in text and "incl. layers [0]" in text, text)

# 5. fail closed: a type size that does not fit the offsets; an unknown type id
gguf(f"{T}/gap.gguf", "llama", 1, [("blk.0.a.weight", (256, 32), "Q4_K"), ("blk.0.b.weight", (256, 32), "Q4_K")],
     size_override={"blk.0.a.weight": 1024})
rc, text, _ = run(f"{T}/gap.gguf")
ok("offset gap smaller than the computed size -> FAIL", rc == 1 and "MISMATCH" in text and "RESULT gguf-table: FAIL" in text, text)
gguf(f"{T}/unk.gguf", "llama", 1, [("blk.0.bad.weight", (256, 32), "Q4_K")], bad_type=99)
rc, text, _ = run(f"{T}/unk.gguf")
ok("unknown type id -> FAIL", rc == 1 and "unknown tensor types [99]" in text, text)

# 6. review of ec37672: a tied embedding on the CPU is reused when the output selects the same buffer context (plain
# CPU), separate in the CPU repack buffer; unresolved without --cpu-repack. A 4 MiB F32 embedding (1024 x 1024).
emb4 = [("token_embd.weight", (1024, 1024), "F32"), ("blk.0.w.weight", (256, 32), "Q4_0"), ("output_norm.weight", (1024,), "F32")]
gguf(f"{T}/t4.gguf", "llama", 1, emb4)
cpu = lambda text, ns="1": re.search(rf"SESSIONS {ns} default split[^\n]*CPU weights ([0-9-]+) MiB", text).group(1)
for args, want, what in [(["--ngl", "0", "--cpu-repack", "none"], "4", "--ngl 0, no CPU repack: one copy (reused)"),
                         (["--output-cpu", "--cpu-repack", "Q4_0,Q8_0"], "4", "--output-cpu, F32 not repacked: one copy"),
                         (["--ngl", "0"], "4-8", "--ngl 0, --cpu-repack unset: a bound, reused - separate")]:
    rc, text, _ = run(f"{T}/t4.gguf", "--sessions", "1", *args)
    ok(f"tied on the CPU: {what}", rc == 0 and cpu(text) == want, text)
emb8 = [("token_embd.weight", (2048, 3072), "Q8_0"), ("blk.0.w.weight", (256, 32), "Q4_0"), ("output_norm.weight", (1024,), "F32")]
gguf(f"{T}/t8.gguf", "llama", 1, emb8)       # Q8_0 2048 x 3072: 6,684,672 bytes = 6.375 MiB
rc, text, _ = run(f"{T}/t8.gguf", "--sessions", "1", "--output-cpu", "--cpu-repack", "Q8_0")
ok("tied on the CPU: the CPU repack selects Q8_0: a separate copy (two)", rc == 0 and cpu(text) == "13" and "separate (CPU repack" in text, text)
rc, text, _ = run(f"{T}/t8.gguf", "--sessions", "1")
ok("tied, output on the NPU: a separate copy in the output layer, CPU input once", rc == 0 and cpu(text) == "6"
   and "TIED output on the CPU" not in text and next(l for l in text.splitlines() if l.startswith("LAYER 1 ")) == "LAYER 1 6.38 6.38", text)

# 7. explicit splits (review of ec37672): float32 placement, ties, the best contiguous partition and its --tensor-split
ok("best partition: lowest largest group", g.best_partition([1, 1, 1, 1, 4, 4], 3) == [4, 1, 1]
   and g.best_partition([5, 5, 5, 5], 2) == [2, 2], g.best_partition([1, 1, 1, 1, 4, 4], 3))
devs, ties = g.place([4, 1, 1], 0, 6, 6)
ok("place: --tensor-split 4,1,1 gives indices 0-3 / 4 / 5 (float32, upper_bound)", devs == [0, 0, 0, 0, 1, 2], devs)
rc, text, _ = run(f"{T}/s.gguf", "--sessions", "3")
ok("equal split: ties at the split points listed (9 indices, 3 sessions: 3 and 6)", "ties at [3, 6]" in text, text)
heavy = [("token_embd.weight", (256, 64), "Q8_0")] + [(f"blk.{i}.w.weight", (256, 32 * (8 if i < 2 else 1)), "Q4_0") for i in range(6)]
gguf(f"{T}/h.gguf", "llama", 6, heavy)          # blocks 0-1 eight times the others; output index 6 empty
rc, text, _ = run(f"{T}/h.gguf", "--sessions", "2")
ex = next(l for l in text.splitlines() if "best explicit split" in l)
ok("explicit split: the heavy blocks apart, the rest together (--tensor-split 1,6)",
   "--tensor-split 1,6)" in ex and "HTP0:0 layers 0-0 " in ex and "HTP0:1 layers 1-6 " in ex and "WARNING" not in ex, ex)
ok("EXPLICIT line: fit per session count, labelled necessary, not sufficient", "EXPLICIT weights + KV" in text
   and "necessary, not sufficient" in text, text)

# 8. URL: the same table through HTTP range requests (a local server honouring Range; small chunks)
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        data = open(os.path.join(T, os.path.basename(self.path)), "rb").read()
        a, b = self.headers["Range"].split("=")[1].split("-"); a, b = int(a), min(int(b), len(data) - 1)
        self.send_response(206); self.send_header("Content-Range", f"bytes {a}-{b}/{len(data)}")
        self.send_header("Content-Length", str(b - a + 1)); self.end_headers(); self.wfile.write(data[a:b + 1])
srv = http.server.HTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
g.Source.CHUNK = 100
rc1, text1, rows1 = run(f"{T}/a.gguf"); rc2, text2, rows2 = run(f"http://127.0.0.1:{srv.server_port}/a.gguf")
ok("URL source with range requests gives the same table and summary", rc2 == 0 and rows1 == rows2
   and text1.split("\n", 1)[1] == text2.split("\n", 1)[1], text2)
srv.shutdown()
print(f"failures: {fails}"); sys.exit(fails)
