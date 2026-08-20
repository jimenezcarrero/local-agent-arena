#!/usr/bin/env python3
"""Extract a head-only MTP draft GGUF from a Qwen3.5-family model that has a
baked-in nextn block (what gemma ships separately as a 60 MB draft).

Keeps: token_embd, output, output_norm, and the nextn layer (renamed to blk.0).
Sets block_count=1 so llama.cpp loads a single-layer draft model.
"""
import sys, os
sys.path.insert(0, "/home/JetsonOrin/Repositories/llama.cpp/gguf-py")
import numpy as np
from gguf import GGUFReader, GGUFWriter

src, dst = sys.argv[1], sys.argv[2]
# how many normal layers to keep before the nextn layer; llama.cpp asserts
# n_layer_nextn < n_layer_all, so a draft needs >= 1 ordinary layer
N_PRE = int(sys.argv[3]) if len(sys.argv) > 3 else 1
r = GGUFReader(src)

# locate the nextn layer index
nextn_idx = None
for t in r.tensors:
    if ".nextn." in t.name:
        nextn_idx = t.name.split(".")[1]
        break
if nextn_idx is None:
    sys.exit("no nextn tensors found - this model has no baked-in MTP head")
print(f"nextn layer: blk.{nextn_idx}")

nx = int(nextn_idx)
pre = [nx - i for i in range(N_PRE, 0, -1)]          # e.g. [31] when N_PRE=1
KEEP_PREFIX = tuple(f"blk.{i}." for i in pre + [nx])
# old index -> new contiguous index (0..N_PRE), nextn layer goes last
REMAP = {old: new for new, old in enumerate(pre + [nx])}
print(f"keeping layers {pre + [nx]} -> {list(REMAP.values())}, block_count={len(REMAP)}")
KEEP_EXACT  = ("token_embd.weight", "output.weight", "output_norm.weight",
               "rope_freqs.weight")

arch = None
for f in r.fields.values():
    if f.name == "general.architecture":
        arch = f.contents()
print(f"architecture: {arch}")

w = GGUFWriter(dst, arch)

# copy metadata, overriding block_count to 1
import gguf
skip = {"general.architecture", f"{arch}.block_count", "split.no", "split.count",
        "split.tensors.count", "general.file_type"}
copied = 0
for f in r.fields.values():
    # GGUF.* are reader-internal pseudo-fields the writer emits itself
    if f.name in skip or f.name.startswith("GGUF.") or not f.types:
        continue
    try:
        val = f.contents()
    except Exception:
        continue
    if val is None:
        continue
    t0 = f.types[0]
    try:
        if t0 == gguf.GGUFValueType.STRING:
            w.add_string(f.name, val)
        elif t0 == gguf.GGUFValueType.ARRAY:
            sub = f.types[1] if len(f.types) > 1 else None
            if sub == gguf.GGUFValueType.STRING:
                w.add_array(f.name, val)
            else:
                w.add_array(f.name, list(val))
        elif t0 == gguf.GGUFValueType.BOOL:
            w.add_bool(f.name, bool(val))
        elif t0 in (gguf.GGUFValueType.FLOAT32, gguf.GGUFValueType.FLOAT64):
            w.add_float32(f.name, float(val))
        else:
            w.add_uint32(f.name, int(val))
        copied += 1
    except Exception as e:
        print(f"  skip {f.name}: {e}")
w.add_uint32(f"{arch}.block_count", len(REMAP))
print(f"metadata fields copied: {copied} (+ block_count={len(REMAP)})")

total = 0
for t in r.tensors:
    keep = t.name in KEEP_EXACT or any(t.name.startswith(p) for p in KEEP_PREFIX)
    if not keep:
        continue
    new_name = t.name
    if t.name.startswith("blk."):
        old_i = int(t.name.split(".")[1])
        new_name = t.name.replace(f"blk.{old_i}.", f"blk.{REMAP[old_i]}.", 1)
    data = t.data
    # data.shape is the BYTE shape for quantized tensors; let the writer
    # derive the logical shape from it via quant_shape_from_byte_shape
    w.add_tensor(new_name, data, raw_dtype=t.tensor_type)
    total += getattr(t, "n_bytes", data.nbytes)
    print(f"  keep {t.name:48s} -> {new_name:26s} {t.tensor_type.name:8s} {getattr(t,'n_bytes',0)/1e6:7.1f} MB")

w.write_header_to_file()
w.write_kv_data_to_file()
w.write_tensors_to_file()
w.close()
print(f"\nwrote {dst}  ({os.path.getsize(dst)/1e6:.0f} MB, tensor payload {total/1e6:.0f} MB)")
