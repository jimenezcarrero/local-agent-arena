#!/usr/bin/env python3
# placement_from_gguf.py <model.gguf> [ngl ...] (D170) - which weights the pinned loader (llama.cpp 836d57176) places
# on the CPU and which on the accelerator for each -ngl, read from the GGUF header only (no backend, no NPU).
# Loader rule (src/llama-model.cpp:1591-1616): i_gpu_start = max(n_layer_all + 1 - ngl, 0),
# act = min(ngl, n_layer_all + 1); index il (blocks 0..n_layer_all-1, output = n_layer_all) is on the CPU when
# il < i_gpu_start or il - i_gpu_start >= act. The input layer (token_embd for the lookup) is always on the CPU.
# Tied embeddings: with no output.weight, qwen35.cpp creates token_embd.weight again with TENSOR_DUPLICATED and
# llama-model-loader.cpp:1166 classifies that copy as OUTPUT, so it follows the output layer's device.
import re, struct, sys

TYPES = {0: ("F32", 1, 4), 1: ("F16", 1, 2), 2: ("Q4_0", 32, 18), 3: ("Q4_1", 32, 20), 8: ("Q8_0", 32, 34),
         30: ("BF16", 1, 2)}

def read_header(path):
    f = open(path, "rb")
    r = lambda fmt: struct.unpack("<" + fmt, f.read(struct.calcsize("<" + fmt)))
    def s():
        (n,) = r("Q"); return f.read(n).decode("utf-8", "replace")
    def val(t):
        fm = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}
        if t in fm: return r(fm[t])[0]
        if t == 8: return s()
        if t == 9:
            (at,) = r("I"); (n,) = r("Q"); return [val(at) for _ in range(n)]
        raise ValueError(f"metadata type {t}")
    magic, ver = f.read(4), r("I")[0]
    assert magic == b"GGUF", "not a GGUF file"
    nt, nkv = r("QQ")
    kv = {}
    for _ in range(nkv):
        k = s(); (t,) = r("I"); kv[k] = val(t)
    tensors = []
    for _ in range(nt):
        name = s(); (nd,) = r("I"); dims = r("Q" * nd); (t,) = r("I"); r("Q")
        n = 1
        for d in dims: n *= d
        tn, blk, bs = TYPES.get(t, (f"type{t}", None, None))
        nbytes = n // blk * bs if blk else None
        tensors.append((name, dims, tn, nbytes))
    return kv, tensors

def main():
    path = sys.argv[1]; ngls = [int(x) for x in sys.argv[2:]] or [99, 33, 32, 16]
    kv, tensors = read_header(path)
    arch = kv["general.architecture"]; n_layer = kv[f"{arch}.block_count"]
    names = {t[0] for t in tensors}
    tied = "output.weight" not in names and "token_embd.weight" in names
    MiB = 1024 * 1024
    print(f"model {path.rsplit('/', 1)[-1]}: architecture {arch}, block_count {n_layer}, tensors {len(tensors)}, "
          f"output.weight present: {'no (tied: token_embd.weight duplicated as the OUTPUT tensor)' if tied else 'yes'}")
    def role(name):
        m = re.match(r"blk\.(\d+)\.", name)
        if m: return int(m.group(1))
        if name.startswith("output") : return "output"
        if name == "token_embd.weight": return "input"
        return "other"
    for ngl in ngls:
        start = max(n_layer + 1 - ngl, 0); act = min(ngl, n_layer + 1)
        on_cpu = lambda il: il < start or (il - start) >= act
        cpu_blocks = [il for il in range(n_layer) if on_cpu(il)]
        out_dev = "CPU" if on_cpu(n_layer) else "accelerator"
        acc = cpu = 0
        for name, dims, tn, nb in tensors:
            r_ = role(name)
            if r_ == "input": cpu += nb; continue          # the lookup copy, always CPU
            if r_ == "output" or r_ == "other": dev_cpu = on_cpu(n_layer)
            else: dev_cpu = on_cpu(r_)
            if dev_cpu: cpu += nb
            else: acc += nb
        if tied:                                          # the OUTPUT copy of token_embd.weight
            nb = next(t[3] for t in tensors if t[0] == "token_embd.weight")
            if on_cpu(n_layer): cpu += nb
            else: acc += nb
        blocks = ("none" if not cpu_blocks else
                  f"{cpu_blocks[0]}-{cpu_blocks[-1]}" if len(cpu_blocks) > 1 else str(cpu_blocks[0]))
        print(f"-ngl {ngl}: i_gpu_start {start}; blocks on the CPU: {blocks}; blocks on the accelerator: "
              f"{n_layer - len(cpu_blocks)}; output layer (output_norm + output projection): {out_dev}; "
              f"weights CPU {cpu / MiB:.2f} MiB, accelerator {acc / MiB:.2f} MiB")
    for b in (0,):
        sz = {}
        for name, dims, tn, nb in tensors:
            if role(name) == b: sz[tn] = sz.get(tn, 0) + nb
        print(f"block {b} weights by type: " + ", ".join(f"{k} {v / MiB:.2f} MiB" for k, v in sorted(sz.items())))
    for name, dims, tn, nb in tensors:
        if role(name) in ("input", "output"):
            print(f"tensor {name} {list(dims)} {tn} {nb / MiB:.2f} MiB")

if __name__ == "__main__":
    main()
