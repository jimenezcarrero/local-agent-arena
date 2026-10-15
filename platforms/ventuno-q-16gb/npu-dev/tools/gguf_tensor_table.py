#!/usr/bin/env python3
"""gguf_tensor_table.py <model.gguf | https URL> [options]   (NPU dev plan K3/R1; offline, header only)

Every tensor of a GGUF file with its NPU allocation under the Hexagon backend's rule, its placement under llama.cpp's
loader rule, and the totals per type, per layer and per NPU session. Reads only the header: a local file, or an
https URL through HTTP range requests (a Hugging Face "resolve" link), so a model never needs to be downloaded or
staged on the board to be sized.

Allocation (--rule master = ggml-org master af0579c78, the plan's K1 base; --rule release = 836d57176, the campaign's):
  ggml-hexagon.cpp get_alloc_size (master :2836-2847, release :2769-2777): for a repack type (master :318-324: Q4_0,
  Q4_1, Q8_0, IQ4_NL, MXFP4, Q6_K, Q4_K, Q5_K, Q3_K, Q2_K) tiled_row_size(type, ne0 padded to 32) x (ne1 padded to 32)
  x ne2 x ne3, with tiled_row_size (master :328-342) = (ne0 / 32) x (tile / 32) for Q6_K (896), Q4_K (the Q4_1 tile,
  640), Q5_K (768), Q3_K (512), else ggml_row_size; the release also tiles Q2_K (512, release :291-293; master stores
  Q2_K at file size, HTP_MM_WEIGHT_TILE_SIZE_Q2_K 336 = the block's bits). Any other type: ggml_nbytes. Tile sizes:
  htp/matmul-ops.h :23-45 (identical in both except Q2_K). Each tensor is padded to the buffer alignment, 128
  (get_alignment, master :2831-2834). Static buffers are split at 1 GiB (opt_mbuf_static, master :148); the split
  does not change the total and is not modelled.
Placement (llama-model.cpp master :1618-1676, llama-model-loader.cpp :1167, :1202-1228):
  i_gpu_start = max(n_layer + 1 - ngl, 0), act = min(ngl, n_layer + 1); index il (blocks 0..n_layer-1, the output
  layer = n_layer) is on the CPU if il < i_gpu_start or il - i_gpu_start >= act; otherwise on NPU session
  upper_bound(splits, (il - i_gpu_start) / act) in float32, splits the normalized cumulative --tensor-split values
  or, without them, each session's reported free memory. The Hexagon backend reports 0 (master get_memory
  :9267-9272: opt_mbuf_total, 0 unless GGML_HEXAGON_MBUF sets it; the release: 0), so the loader falls back to the
  host's free memory, read once per session (llama-model.cpp :1626-1634): nearly equal, not exactly. The default
  split is computed with equal reads; an index exactly on a split point (a tie) goes to the next session with equal
  reads or a lower earlier read, and stays with a higher one: ties are listed. Explicit splits (review of ec37672):
  the best contiguous partition (lowest largest session of weights + KV) and the --tensor-split values (layer
  counts) that give it, checked with the same float32 placement.
  Tensors outside a block are INPUT (CPU: token_embd, pos_embd, token_types) or OUTPUT (the output layer's device:
  output, output_norm, and lfm2/lfm2moe's token_embd_norm = LLM_TENSOR_OUTPUT_NORM_LFM2, llama-arch.cpp :467, :807);
  a block id >= n_layer (e.g. an MTP block) goes with the output (llama-model.cpp :2362). Tied embeddings (no
  output.weight): token_embd.weight is requested again as the OUTPUT tensor (loader :1167) and gets its own
  allocation only if the output's buffer type differs from the input's (loader :1370-1376: an existing tensor of the
  same name in the same buffer-type context is reused). On the NPU it differs: counted again. On the CPU (--ngl
  leaving the output layer there, or --output-cpu) the input is in the plain CPU buffer (GET_ROWS: the CPU repack
  buffer takes only 2-D MUL_MAT and 3-D MUL_MAT_ID, ggml-cpu/repack.cpp :5179-5210), and the output projection goes
  to the CPU repack buffer if the host's CPU repack selects its type (repack.cpp :4925-5129, by the build's CPU
  features and ne1 divisibility: with dotprod and without i8mm, as this board's cores report, Q4_0, Q4_K, Q5_K,
  Q6_K, IQ4_NL, MXFP4, Q8_0 and Q1_0, not Q2_K or Q3_K; to be confirmed by the CPU_REPACK line of a load log), a
  separate copy; otherwise to the same plain CPU buffer, reused. --cpu-repack TYPES names the types the host's CPU repack selects (--cpu-repack
  none: none, e.g. --no-repack); without it the CPU weights are given as a bound (shared - separate).
  --output-cpu models NPU-R' (plan K4): the output projection (output.weight, or the tied copy) on the CPU.
Self-check: every tensor's computed file bytes must fit its offset gap (the gap to the next tensor, or to the end of
  the file, minus at most the alignment padding); a mismatch means an unknown type size and the run fails (exit 1).
KV estimate (--ctx): per attention layer, 2 x ctx x head_count_kv x head_dim x 2 bytes (F16 K and V); head_dim =
  key_length if present, else embedding_length / head_count. Attention layers: those not marked in
  <arch>.attention.recurrent_layers (qwen35), else every full_attention_interval-th, else those with head_count_kv > 0
  when it is a per-layer array (lfm2/lfm2moe: 0 for the convolution layers), else every layer. Recurrent and
  compute buffers are not derivable from the header and are not estimated (measured at load, plan R2).
Output: the summary on stdout; --tsv <path> writes the per-tensor table. Exit 0 on a consistent header."""
import argparse, bisect, json, re, struct, sys, urllib.request

# ggml types: id -> (name, block size, type size), from gguf-py constants.py GGML_QUANT_SIZES (llama.cpp 836d57176)
QK_K = 256
TYPES = {0: ("F32", 1, 4), 1: ("F16", 1, 2), 2: ("Q4_0", 32, 18), 3: ("Q4_1", 32, 20), 6: ("Q5_0", 32, 22),
         7: ("Q5_1", 32, 24), 8: ("Q8_0", 32, 34), 9: ("Q8_1", 32, 36), 10: ("Q2_K", 256, 84), 11: ("Q3_K", 256, 110),
         12: ("Q4_K", 256, 144), 13: ("Q5_K", 256, 176), 14: ("Q6_K", 256, 210), 15: ("Q8_K", 256, 292),
         16: ("IQ2_XXS", 256, 66), 17: ("IQ2_XS", 256, 74), 18: ("IQ3_XXS", 256, 98), 19: ("IQ1_S", 256, 50),
         20: ("IQ4_NL", 32, 18), 21: ("IQ3_S", 256, 110), 22: ("IQ2_S", 256, 82), 23: ("IQ4_XS", 256, 136),
         24: ("I8", 1, 1), 25: ("I16", 1, 2), 26: ("I32", 1, 4), 27: ("I64", 1, 8), 28: ("F64", 1, 8),
         29: ("IQ1_M", 256, 56), 30: ("BF16", 1, 2), 34: ("TQ1_0", 256, 54), 35: ("TQ2_0", 256, 66),
         39: ("MXFP4", 32, 17), 40: ("NVFP4", 64, 36), 41: ("Q1_0", 128, 18), 42: ("Q2_0", 64, 18)}
REPACK = {"Q4_0", "Q4_1", "Q8_0", "IQ4_NL", "MXFP4", "Q6_K", "Q4_K", "Q5_K", "Q3_K", "Q2_K"}
TILE = {"Q6_K": 896, "Q4_K": 640, "Q5_K": 768, "Q3_K": 512}           # tiled_row_size branches (master)
RULES = {"master": TILE, "release": dict(TILE, Q2_K=512)}
ALIGN = 128
VMEM = 3355443200   # HTP_OP_MAX_VMEM_DEFAULT, htp/htp-ops.h :138 (master): what one NPU session can address (F5)
MiB = 1024 * 1024
f32 = lambda v: struct.unpack("<f", struct.pack("<f", v))[0]   # the loader's float arithmetic


def place(values, start, act, n_idx):
    """llama-model.cpp :1617-1661: the device of each index 0..n_idx-1 (None = CPU) for split values <values> (one per
    session), in float32 as the loader computes it; and the indices exactly on a split point (ties)"""
    acc, cum = f32(0.0), []
    for v in values:
        acc = f32(acc + f32(v)); cum.append(acc)
    splits = [f32(c / acc) for c in cum]
    dev, ties = [], []
    for il in range(n_idx):
        if il < start or il - start >= act:
            dev.append(None); continue
        x = f32(f32(il - start) / f32(act))
        dev.append(min(bisect.bisect_right(splits, x), len(values) - 1))
        if x in splits[:-1]:
            ties.append(il)
    return dev, ties


def best_partition(costs, ns):
    """contiguous partition of <costs> into ns non-empty groups with the lowest largest group sum: the group sizes"""
    n = len(costs); pre = [0]
    for c in costs:
        pre.append(pre[-1] + c)
    INF = float("inf"); best = [[INF] * (n + 1) for _ in range(ns + 1)]; cut = [[0] * (n + 1) for _ in range(ns + 1)]
    best[0][0] = 0
    for g in range(1, ns + 1):
        for j in range(g, n + 1):
            for i in range(g - 1, j):
                v = max(best[g - 1][i], pre[j] - pre[i])
                if v < best[g][j]:
                    best[g][j], cut[g][j] = v, i
    sizes, j = [], n
    for g in range(ns, 0, -1):
        i = cut[g][j]; sizes.append(j - i); j = i
    return sizes[::-1]


class Source:
    """sequential reads from a local file or an https URL (range requests of CHUNK bytes)"""
    CHUNK = 8 * MiB

    def __init__(self, src):
        self.url = src if re.match(r"https?://", src) else None
        self.f = None if self.url else open(src, "rb")
        self.buf, self.base, self.pos, self.size = b"", 0, 0, None
        if self.f:
            self.f.seek(0, 2); self.size = self.f.tell(); self.f.seek(0)

    def _fetch(self, start):
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{start + self.CHUNK - 1}",
                                                        "User-Agent": "gguf_tensor_table"})
        with urllib.request.urlopen(req, timeout=120) as r:
            if r.status != 206:
                raise SystemExit(f"range request not honoured (HTTP {r.status})")
            m = re.search(r"/(\d+)$", r.headers.get("Content-Range", ""))
            self.size = int(m.group(1)) if m else None
            return r.read()

    def read(self, n):
        if self.f:
            b = self.f.read(n); self.pos += len(b)
            if len(b) != n:
                raise SystemExit("unexpected end of file")
            return b
        while self.pos + n > self.base + len(self.buf):
            more = self._fetch(self.base + len(self.buf))
            if not more:
                raise SystemExit("unexpected end of data")
            self.buf += more
        off = self.pos - self.base; b = self.buf[off:off + n]; self.pos += n
        if off > 64 * MiB:                     # drop what was consumed
            self.buf, self.base = self.buf[off:], self.base + off
        return b


def read_header(src):
    s = Source(src)
    r = lambda fmt: struct.unpack("<" + fmt, s.read(struct.calcsize("<" + fmt)))
    def string():
        (n,) = r("Q"); return s.read(n).decode("utf-8", "replace")
    scal = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}
    def value(t):
        if t in scal: return r(scal[t])[0]
        if t == 8: return string()
        if t == 9:
            (at,) = r("I"); (n,) = r("Q")
            if at in scal:                     # fast path for large numeric arrays
                fmt = scal[at]; return list(struct.unpack(f"<{n}{fmt}", s.read(n * struct.calcsize(fmt))))
            return [value(at) for _ in range(n)]
        raise SystemExit(f"unknown metadata type {t}")
    if s.read(4) != b"GGUF":
        raise SystemExit("not a GGUF file")
    (ver,) = r("I"); nt, nkv = r("QQ")
    kv = {}
    for _ in range(nkv):
        k = string(); (t,) = r("I"); kv[k] = value(t)
    tensors = []
    for _ in range(nt):
        name = string(); (nd,) = r("I"); dims = list(r("Q" * nd)); (t,) = r("I"); (off,) = r("Q")
        tensors.append({"name": name, "ne": dims + [1] * (4 - nd), "nd": nd, "type_id": t, "offset": off})
    align = kv.get("general.alignment", 32)
    data_start = (s.pos + align - 1) // align * align
    return ver, kv, tensors, data_start, align, s.size


def nbytes(t):
    name, blk, ts = TYPES[t["type_id"]]
    n = t["ne"][0] * t["ne"][1] * t["ne"][2] * t["ne"][3]
    return n // blk * ts


def alloc(t, rule):
    name, blk, ts = TYPES[t["type_id"]]
    if name in REPACK:
        ne0 = (t["ne"][0] + 31) // 32 * 32; ne1 = (t["ne"][1] + 31) // 32 * 32
        tile = RULES[rule].get(name)
        row = ne0 // 32 * (tile // 32) if tile else ne0 // blk * ts
        size = row * ne1 * t["ne"][2] * t["ne"][3]
    else:
        size = nbytes(t)
    return (size + ALIGN - 1) // ALIGN * ALIGN


def role(name, arch, n_layer):
    """block index, or "input" / "output" (the loader's layer class for tensors outside a block)"""
    m = re.match(r"blk\.(\d+)\.", name)
    if m:
        b = int(m.group(1)); return b if b < n_layer else "output"
    base = name.rsplit(".", 1)[0]
    if base in ("token_embd", "pos_embd", "token_types"):
        return "input"
    if base in ("output", "output_norm") or (base == "token_embd_norm" and arch in ("lfm2", "lfm2moe")):
        return "output"
    return "unknown"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source"); ap.add_argument("--rule", choices=sorted(RULES), default="master")
    ap.add_argument("--ngl", type=int, default=999); ap.add_argument("--sessions", default="1,2,3,4")
    ap.add_argument("--ctx", type=int, default=16384); ap.add_argument("--output-cpu", action="store_true")
    ap.add_argument("--cpu-repack", help="types the host's CPU repack selects for 2-D MUL_MAT (comma list, or none); "
                    "decides whether a tied output on the CPU is a separate copy; unset: a bound")
    ap.add_argument("--tsv")
    a = ap.parse_args(argv)
    repack = None if a.cpu_repack is None else {x.strip() for x in a.cpu_repack.split(",") if x.strip() and x.strip() != "none"}
    ver, kv, tensors, data_start, align, fsize = read_header(a.source)
    arch = kv.get("general.architecture"); n_layer = kv[f"{arch}.block_count"]
    unknown_types = sorted({t["type_id"] for t in tensors if t["type_id"] not in TYPES})
    if unknown_types:
        print(f"RESULT gguf-table: FAIL (unknown tensor types {unknown_types})"); return 1
    names = {t["name"] for t in tensors}
    tied = "output.weight" not in names and "token_embd.weight" in names
    for t in tensors:
        t["type"] = TYPES[t["type_id"]][0]; t["bytes"] = nbytes(t); t["alloc"] = alloc(t, a.rule)
        t["role"] = role(t["name"], arch, n_layer)
    # self-check: computed bytes against the offset gaps
    order = sorted(tensors, key=lambda t: t["offset"]); bad = []
    for i, t in enumerate(order):
        end = order[i + 1]["offset"] if i + 1 < len(order) else (fsize - data_start if fsize else None)
        if end is None:
            continue
        gap = end - t["offset"]
        if not (t["bytes"] <= gap < t["bytes"] + align + (0 if i + 1 < len(order) else 1)):
            bad.append(f"{t['name']} ({t['type']}, computed {t['bytes']}, gap {gap})")
    file_total = sum(t["bytes"] for t in tensors)
    print(f"model {a.source.rsplit('/', 1)[-1]}: GGUF v{ver}, architecture {arch}, block_count {n_layer}, tensors "
          f"{len(tensors)}, file {fsize if fsize else '?'} bytes, data from {data_start}; output.weight: "
          f"{'no (tied: token_embd.weight duplicated as the OUTPUT tensor)' if tied else 'yes'}; rule {a.rule}")
    print(f"offset gaps consistent: {len(order) - len(bad)}/{len(order)}" + (f"; MISMATCH {bad[:5]}" if bad else ""))
    unk = [t["name"] for t in tensors if t["role"] == "unknown"]
    if unk:
        print(f"WARNING: {len(unk)} tensors outside a block of no known class (counted with the output): {unk[:8]}")
    # per type
    print("TYPE count params_M file_MiB npu_alloc_MiB alloc/file")
    for ty in sorted({t["type"] for t in tensors}, key=lambda x: -sum(t["bytes"] for t in tensors if t["type"] == x)):
        ts_ = [t for t in tensors if t["type"] == ty]
        f, al = sum(t["bytes"] for t in ts_), sum(t["alloc"] for t in ts_)
        par = sum(t["ne"][0] * t["ne"][1] * t["ne"][2] * t["ne"][3] for t in ts_) / 1e6
        print(f"TYPE {ty} {len(ts_)} {par:.1f} {f / MiB:.2f} {al / MiB:.2f} {al / f:.4f}")
    # per layer (index n_layer = the output layer; "input" separately)
    per = {}
    for t in tensors:
        k = n_layer if t["role"] in ("output", "unknown") else t["role"]
        per.setdefault(k, [0, 0]); per[k][0] += t["bytes"]; per[k][1] += t["alloc"]
    emb = next((t for t in tensors if t["name"] == "token_embd.weight"), None)
    out_proj = next((t for t in tensors if t["name"] == "output.weight"), emb if tied else None)
    per.setdefault(n_layer, [0, 0])          # the output layer exists even with no output-class tensor of its own
    if tied and emb:
        per[n_layer][0] += emb["bytes"]; per[n_layer][1] += emb["alloc"]
    if a.output_cpu and out_proj:   # NPU-R': the output projection (or its tied copy) on the CPU
        per[n_layer][0] -= out_proj["bytes"]; per[n_layer][1] -= out_proj["alloc"]
    # a tied copy on the CPU: separate only in the CPU repack buffer (loader :1370-1376); None = unresolved
    tied_sep = None if (repack is None or not tied or not emb) else emb["type"] in repack
    print("LAYER index file_MiB npu_alloc_MiB (index " + str(n_layer) + " = the output layer"
          + (", without the output projection (--output-cpu)" if a.output_cpu else "") + ")")
    for k in sorted(x for x in per if x != "input"):
        print(f"LAYER {k} {per[k][0] / MiB:.2f} {per[k][1] / MiB:.2f}")
    if "input" in per:
        print(f"INPUT (CPU) file {per['input'][0] / MiB:.2f} MiB")
    # KV estimate
    hkv = kv.get(f"{arch}.attention.head_count_kv"); nh = kv.get(f"{arch}.attention.head_count")
    emb_len = kv.get(f"{arch}.embedding_length"); hd = kv.get(f"{arch}.attention.key_length")
    if isinstance(nh, list): nh = max(nh)
    if hd is None and nh and emb_len: hd = emb_len // nh
    rec = kv.get(f"{arch}.attention.recurrent_layers"); fai = kv.get(f"{arch}.full_attention_interval")
    def is_attn(il):
        if isinstance(rec, list): return not rec[il]
        if fai: return il % fai == fai - 1
        return True
    kvl = {}
    if hkv is not None and hd:
        for il in range(n_layer):
            h = hkv[il] if isinstance(hkv, list) else hkv
            if h and is_attn(il): kvl[il] = 2 * a.ctx * h * hd * 2
    print(f"KV estimate at ctx {a.ctx}: {len(kvl)} attention layers {sorted(kvl)}, {sum(kvl.values()) / MiB:.1f} MiB (F16 K and V, "
          f"head_dim {hd}); recurrent state and compute buffers not estimated")
    # sessions
    ngl = a.ngl; start = max(n_layer + 1 - ngl, 0); act = min(ngl, n_layer + 1)
    out_on_cpu = a.output_cpu or not (start <= n_layer and n_layer - start < act)
    cpu_w = per.get("input", [0, 0])[0]
    if a.output_cpu and out_proj:
        cpu_w += out_proj["bytes"]
    dup = emb["bytes"] if (tied and emb and out_on_cpu) else 0   # the tied copy, counted once in the CPU weights
    if dup:
        print(f"TIED output on the CPU: the copy of token_embd.weight ({emb['type']}, {dup / MiB:.2f} MiB) is "
              + ({True: f"separate (CPU repack selects {emb['type']}, --cpu-repack)",
                  False: f"the input's own tensor, reused (CPU repack does not select {emb['type']}, --cpu-repack)",
                  None: f"separate if the host's CPU repack selects {emb['type']}, else the input's own tensor (unresolved: "
                        "give --cpu-repack); CPU weights as a bound, reused - separate"}[tied_sep]))
    cost = lambda il: per.get(il, [0, 0])[1] + kvl.get(il, 0)

    def show(label, devs, ns):
        sess = [{"layers": [], "w": 0, "kv": 0} for _ in range(ns)]
        cpu_layers = [il for il, d in enumerate(devs) if d is None]
        for il, d in enumerate(devs):
            if d is not None:
                sess[d]["layers"].append(il); sess[d]["w"] += per.get(il, [0, 0])[1]; sess[d]["kv"] += kvl.get(il, 0)
        cpu_hi = cpu_w + sum(per.get(il, [0, 0])[0] for il in cpu_layers)
        cpu_lo = cpu_hi - (dup if tied_sep is not True else 0)
        cpu_hi = cpu_hi if tied_sep is not False else cpu_lo
        line = []
        for i, s_ in enumerate(sess):
            ls = s_["layers"]; rng = f"{ls[0]}-{ls[-1]}" if ls else "none"
            tot = s_["w"] + s_["kv"]
            line.append(f"HTP0:{i} layers {rng} weights {s_['w'] / MiB:.0f} + KV {s_['kv'] / MiB:.0f} = {tot / MiB:.0f} MiB"
                        f" ({tot / VMEM:.0%} of {VMEM / MiB:.0f})")
        cpu = f"{cpu_lo / MiB:.0f}" if cpu_lo == cpu_hi else f"{cpu_lo / MiB:.0f}-{cpu_hi / MiB:.0f}"
        print(f"SESSIONS {ns} {label}: " + "; ".join(line) + f"; CPU weights {cpu} MiB"
              + (f" incl. layers {cpu_layers}" if cpu_layers else ""))
        return max(s_["w"] + s_["kv"] for s_ in sess)

    fit = {}
    for ns in [int(x) for x in a.sessions.split(",") if x]:
        devs, ties = place([1.0] * ns, start, act, n_layer + 1)
        show(f"default split (-ngl {ngl}" + (f"; ties at {ties}: next session with equal free-memory reads" if ties else "")
             + ")", devs, ns)
        npu = [il for il in range(n_layer + 1) if devs[il] is not None]
        if ns > 1 and len(npu) >= ns:
            sizes = best_partition([cost(il) for il in npu], ns)
            devs2, _ = place(sizes, start, act, n_layer + 1)
            want = [g for g, c in enumerate(sizes) for _ in range(c)]
            ok = [devs2[il] for il in npu] == want
            big = show(f"best explicit split (-ngl {ngl} --tensor-split {','.join(map(str, sizes))}"
                       + ("" if ok else "; WARNING: the loader's float32 placement differs from the partition") + ")", devs2, ns)
            fit[ns] = (big, ok)
    if fit:
        ok_ns = [ns for ns, (big, ok) in sorted(fit.items()) if ok and big <= VMEM]
        tight = {ns: (VMEM - big) / MiB for ns, (big, ok) in fit.items()}
        print("EXPLICIT weights + KV under one session's address space: " + "; ".join(
            f"{ns} sessions {'yes' if tight[ns] >= 0 else 'no'} ({tight[ns]:+.1f} MiB on the fullest)" for ns in sorted(fit))
            + (f"; fewest sessions {ok_ns[0]} of those tried" if ok_ns else "; none of those tried")
            + " (necessary, not sufficient: recurrent state, compute and scratch buffers are not included)")
    if a.tsv:
        with open(a.tsv, "w") as f:
            f.write("name\tshape\ttype\tfile_bytes\tnpu_alloc_bytes\trole\toffset\n")
            for t in tensors:
                f.write(f"{t['name']}\t{'x'.join(str(x) for x in t['ne'][:t['nd']])}\t{t['type']}\t{t['bytes']}\t"
                        f"{t['alloc']}\t{t['role']}\t{t['offset']}\n")
    tot_f, tot_a = file_total + (emb["bytes"] if tied and emb else 0), sum(v[1] for v in per.values())
    print(f"RESULT gguf-table: {'PASS' if not bad else 'FAIL'} ({len(tensors)} tensors; file {file_total / MiB:.2f} MiB; "
          f"NPU allocation of everything placeable {sum(v[1] for k, v in per.items() if k != 'input') / MiB:.2f} MiB, "
          f"rule {a.rule})")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
