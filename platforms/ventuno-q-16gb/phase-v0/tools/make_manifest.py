#!/usr/bin/env python3
"""make_manifest.py > files.txt — effective-settings manifest for every V0b/V0c/explore/repeat run, built only
from each run's own evidence: run.txt (exact server command), server.log (startup lines), the tool-probe
evidence (build, chat-template and render hashes, effective sampling) and the binary/model hash tables below.
A field the evidence does not contain is written as "not logged"; nothing is inferred from documentation."""
import glob, hashlib, os, re, sys

H = os.path.expanduser("~")
PHASES = ["v0b-7badb21", "v0c", "v0-explore", "v0c-repeats", "v0d-final", "v0d-final-9b", "v0d-final-9b-h", "v0d-final3",
          "v0d-soak", "v0d-affinity", "v0d-diag", "v0d-spec", "v0d-spec2", "v0d-spec3", "v0d-spec4", "v0d-spec4b", "v0d-spec4c",
          "v0d-spec5", "v0d-spec5b", "v0d-spec5c", "v0d-spec5d", "v0d-admit-A", "v0d-admit-AM", "v0d-admit-H", "v0d-interleave", "v0d-cdsp-test2", "v0d-cdsp-test3", "v0d-admit-H2"]
# V0d status per phase/label prefix (D58, D60, D63, D64, D65)
STATUS = [("v0d-final/", "V0d A with --cache-ram 8192 (D58): evidence only, superseded by the D65 re-measurement"),
          ("v0d-final-9b/9b-Gbig", "V0d 9B G' (D60): WITHDRAWN (--cpu-strict 1 linked to NPU hangs, D63)"),
          ("v0d-final-9b/", "V0d exploratory single run (D60)"),
          ("v0d-final-9b-h/probe", "baseline readiness probe (unchanged A config), not a measurement"),
          ("v0d-final-9b-h/", "V0d 9B H with --cache-ram 8192 (D64): partial, superseded by the D65 re-measurement"),
          ("v0d-final3/probe", "baseline readiness probe (unchanged A config), not a measurement"),
          ("v0d-final3/", "V0d final re-measurement with per-configuration --cache-ram (D65)"),
          ("v0d-soak/", "V0d soak (D61-D63): exploratory"), ("v0d-affinity/", "V0d affinity test (D63): exploratory"),
          ("v0d-diag/", "V0d diagnostic soak (D68-D71): exploratory"),
          ("v0d-spec4/dl-", "combined build v1 (D77): FAILED parity (D80), exploratory only"),
          ("v0d-spec4b/dl-4B-d08-n4-gpu", "combined build v2, GPU draft: GPU device fault (D82, D86), route closed"),
          ("v0d-spec4b/dl-", "combined build v2 (D81): parity PASS (D82), exploratory"),
          ("v0d-spec", "V0d speculation exploration (D70-D84): single exploratory run, not an admission run"),
          ("v0d-admit-A/probe", "baseline readiness probe (unchanged A config), not a measurement"),
          ("v0d-admit-AM/probe", "baseline readiness probe (unchanged A config), not a measurement"),
          ("v0d-admit-H/probe", "baseline readiness probe (unchanged A config), not a measurement"),
          ("v0d-admit-", "V0d admission set (D85, D68 restart rule)"),
          ("v0d-interleave/probe", "baseline readiness probe (unchanged A config), not a measurement"),
          ("v0d-interleave/A-2", "interleaved comparison (D97): NPU HANG on the first request (D99)"),
          ("v0d-interleave/", "interleaved A vs AM comparison (D97, D99): exploratory")]
# Draft models (drafts/expected-sha256.txt, verified at download: drafts/fetch.log.txt)
DRAFTS = {"Qwen3.5-0.8B-Q4_0.gguf": "444406ddd926550c724ec18d5120a9d40ded44908a063b0e66e9a7e5464c652c",
          "Qwen3.5-4B-Q4_0.gguf": "14e6ef39302330c63c2c1a1ab548c7f6f1b7e36b3150ca8b42cab7193b0c3669",
          "Qwen3.5-4B-DFlash.Q8_0.gguf": "f0689eadab0d46468bc2629bb2706f4aba7f794b63e1c9f6eb291269d572a52b",
          "Qwen3.5-9B-DFlash.Q8_0.gguf": "27b9d18e605aea9c50ef506e4b63921e0dc624cc91c63c60617a8295f153d436"}
# Backend libraries hashed next to each llama-server binary: the release package (lib/) or a combined build (bin/, DL
# modules + the Hexagon shim). Source revision: package name / build log "ggml commit" line.
LIBS = {"hexpkg/pkg-linux/bin": ("../lib", ["libggml-base.so.0.25.3", "libggml.so.0.25.3", "libggml-cpu.so.0.25.3",
                                            "libggml-hexagon.so.0.25.3", "libggml-htp-v75.so", "libllama.so.0.5.0"],
                                 "836d5717 (pkg-linux-836d5717.tar.gz, Hexagon release package)"),
        "llama.cpp/build-dl/bin": (".", ["libggml-base.so", "libggml.so", "libggml-cpu.so", "libggml-opencl.so",
                                         "libggml-hexagon-shim.so", "libllama.so"],
                                   "836d57176 (builds/dl-build.log.txt; v1, D77)"),
        "llama.cpp/build-dl2/bin": (".", ["libggml-base.so", "libggml.so", "libggml-cpu.so", "libggml-opencl.so",
                                          "libggml-hexagon-shim.so", "libllama.so"],
                                    "836d57176 (builds/dl-build2.log.txt; v2, D81)")}
MODELS = {"qwen2.5-1.5b-instruct-q4_0-pure.gguf": "78b8d3c9439ec6b511ed0d3acd07f421161771ca08faba571e18137122879eb0",
          "NeoHorse-1-4B-q4_0-pure.gguf": "f822fa2602af45d802e54bac518bab3f62b08943029626114a474afc3d8f3049",
          "Ornith-1.0-9B-q4_0-pure.gguf": "d21c19e56e1a7d2cdc42a0714cb318769fcc53c28ad2c8b19e500c70cc490528",
          "Ornith-1.0-9B-MTP-IQ3_M.gguf": "9ef72d9cf410f7606a4ba621f17d9b204b441bc589fc24b035074796c5fe677b"}
_bin = {}
CMDS = {}


def binhash(path):
    if path not in _bin:
        try:
            _bin[path] = hashlib.sha256(open(path, "rb").read()).hexdigest()
        except OSError:
            _bin[path] = "not available"
    return _bin[path]


def tool_evidence(label):
    out = {}
    for f in glob.glob(f"{H}/bench-runs/v0/*/probe.txt"):
        txt = open(f, errors="replace").read()
        m = re.search(r"^## " + re.escape(label) + r"\n(.*?)(?=^## |\Z)", txt, re.S | re.M)
        if m:
            for k in ("build", "chat_template sha256", "rendered fixed conversation sha256", "sampling", "model id sent"):
                mm = re.search(r"^" + re.escape(k) + r": (.*)$", m.group(1), re.M)
                if mm:
                    out[k] = mm.group(1).strip()
    return out


def grab(log, pats, n=12):
    lines = []
    for l in log.splitlines():
        l2 = re.sub(r"\x1b\[[0-9;]*m", "", l)
        if any(re.search(p, l2) for p in pats):
            l2 = re.sub(r"^\d+\.\d+\.\d+\.\d+ [A-Z] +", "", l2)
            l2 = re.sub(r"^\w{3} +\d+ [\d:.]+ \w+ \S+ (\[ML\] )?(\[[^]]+\] )?", "", l2)
            if l2 not in lines:
                lines.append(l2[:200])
    return lines[:n]


def prescan():
    # first pass: map each exact server command to the first run that has tool-probe evidence
    for ph in PHASES:
        for d in sorted(glob.glob(f"{H}/bench-runs/v0/{ph}/*/")):
            lab = os.path.basename(d.rstrip("/"))
            try:
                import re as _re
                c = _re.search(r"SERVER (.*)", open(d + "run.txt", errors="replace").read())
            except OSError:
                continue
            if c and tool_evidence(lab) and c.group(1) not in CMDS:
                CMDS[c.group(1)] = f"{ph}/{lab}"


def main():
    prescan()
    print("# Effective-settings manifest (RUNBOOK.md V0c 'Effective-settings manifest'), generated", end=" ")
    print(os.popen("date -Is").read().strip(), "by tools/make_manifest.py from each run's own evidence.")
    print("# Measurement commit 7badb21 for every run below (V0b-V0d) (corpus sha256 3611eb84...); 'not logged' = absent from the evidence.")
    print("# Binary, library and model hashes are computed from the files on disk when this manifest is generated, not")
    print("#   recorded at run time: for earlier runs they are retrospective. Each binary line gives the file's mtime;")
    print("#   a binary modified after a run's date would not be the one that run used.")
    print("# Request-side settings: speed_probe.py sends stream=true, max_tokens=128 (gen), cache_prompt=false, no sampling")
    print("#   fields (server defaults apply), and nctx=40960 in V0c (GenieX per-request field; llama-server ignores it).")
    print("#   probe_toolcalls.py sends no sampling fields either; its evidence records the effective server sampling.")
    print("# Sampling audit (check_sampling.sh, sampling-audit.txt): no file embeds general.sampling.*; cards recommend")
    print("#   NeoHorse temp 1.0/top_p 0.95/top_k 20/presence 1.5 and Ornith temp 0.6/top_p 0.95/top_k 20 — NOT applied in V0.")
    for ph in PHASES:
        for d in sorted(glob.glob(f"{H}/bench-runs/v0/{ph}/*/")):
            lab = os.path.basename(d.rstrip("/"))
            try:
                run = open(d + "run.txt", errors="replace").read()
                log = open(d + "server.log", errors="replace").read()
            except OSError:
                continue
            cmd = re.search(r"SERVER (.*)", run)
            cmd = cmd.group(1) if cmd else "not logged"
            print(f"\n## {ph}/{lab}")
            st = next((t for k, t in STATUS if f"{ph}/{lab}".startswith(k)), None)
            if st:
                print(f"status: {st}")
            print(f"server command: {cmd}")
            mfile = next((m for m in MODELS if m in cmd), None)
            te0 = tool_evidence(lab)
            gid = te0.get("model id sent", "")
            if not mfile and "geniex" in cmd:   # GenieX: the file is named only through the registered model id
                mfile = {"qwen15-q40-pure": "qwen2.5-1.5b-instruct-q4_0-pure.gguf", "neohorse4b-q40-pure": "NeoHorse-1-4B-q4_0-pure.gguf",
                         "ornith9b-q40-pure": "Ornith-1.0-9B-q4_0-pure.gguf"}.get(next((k for k in ("qwen15-q40-pure", "neohorse4b-q40-pure",
                         "ornith9b-q40-pure") if k in gid or k in lab.replace("-sanity", "") or (k.startswith("qwen") and "sanity" in lab)), ""), None)
            print(f"model: {mfile or 'not logged'} sha256 {MODELS.get(mfile, 'n/a')}")
            exe = next((w for w in cmd.split() if w.endswith("/llama-server") or w == "geniex"), None)
            if exe and exe.startswith("/"):
                mt = os.popen(f"date -r {exe} -Is 2>/dev/null").read().strip() or "not available"
                print(f"server binary: {exe} sha256 {binhash(exe)} (retrospective; mtime {mt})")
                lk = next((k for k in LIBS if exe.endswith(k + "/llama-server")), None)
                if lk:
                    rel, libs, rev = LIBS[lk]
                    print(f"source revision: {rev}")
                    for lib in libs:
                        print(f"  lib {lib} sha256 {binhash(os.path.normpath(os.path.join(os.path.dirname(exe), rel, lib)))}")
                    if "hexpkg" not in lk:   # the combined build loads the Hexagon backend through the shim from the package
                        print(f"  lib libggml-hexagon.so.0.25.3 (package, via shim) sha256 {binhash(H + '/v0/hexpkg/pkg-linux/lib/libggml-hexagon.so.0.25.3')}")
            md = re.search(r"-md (\S+)", cmd)
            if md:
                dn = os.path.basename(md.group(1))
                print(f"draft model: {dn} sha256 {DRAFTS.get(dn, 'not in drafts/expected-sha256.txt')}")
            elif exe == "geniex":
                print("server binary: GenieX v0.8.0 launcher; bundled files hashed in geniex-install.txt")
            te = te0
            twin = CMDS.get(cmd)
            if not te and twin and twin != f"{ph}/{lab}":
                print(f"configuration: identical server command and binary to {twin}; its tool-probe evidence below applies")
                te = tool_evidence(twin.split("/", 1)[1])
            elif cmd not in CMDS and te:
                CMDS[cmd] = f"{ph}/{lab}"
            for k in ("build", "chat_template sha256", "rendered fixed conversation sha256", "sampling", "model id sent"):
                print(f"{k}: {te.get(k, 'not logged (no tool-probe evidence for this run' + (', GenieX --no-props' if 'geniex' in cmd else '') + ')')}")
            gen = "geniex" in cmd
            pats = (["resolve_devices", "Using \\d+ device", "context params", "threadpool attached", "power mode",
                     "SamplerConfig", "model params", "llama_kv_cache: size =", "load_tensors: +(HTP0|CPU|OpenCL)", "KV buffer", "compute buffer size ="]
                    if gen else
                    ["system_info", "using device", "offloaded \\d+/\\d+", "model buffer size", "KV buffer size", "RS buffer size",
                     "compute buffer size =", "llama_kv_cache: size =", "n_slots =", "llama_context: n_ctx +=", "llama_context: n_batch",
                     "llama_context: n_ubatch", "llama_context: flash_attn", "type_k", "HTP0 power", "Hexagon Arch",
                     "allocating new session", "op batching", "n_rs_seq", "loading draft model",
                     "adding speculative implementation", "- n_max=", "devices=\\["])
            print("startup evidence:")
            for l in grab(log, pats, 40 if "-md " in cmd else 26):
                print("  " + l)
            if not gen:
                aff = "set" if re.search(r"--cpu-mask|-C |--poll ", cmd) else "not set (llama.cpp defaults; no affinity mask)"
                print(f"threads affinity/polling: {aff}")
                ck = re.search(r"--ctx-checkpoints (\d+)", cmd)
                print(f"prompt-cache policy: --cache-ram {re.search(r'--cache-ram (\d+)', cmd).group(1) if '--cache-ram' in cmd else 'default'} MiB;"
                      f" context checkpoints {ck.group(1) if ck else 'default (32 per slot, min step 8192)'}")
            else:
                print("prompt-cache policy: no cache-ram setting; previous-prompt prefix match (D33)")
            res = re.findall(r"RESULT (PASS.*|FAIL.*)", run)
            print(f"run result: {res[-1] if res else re.search(r'END .*', run).group(0) if re.search(r'END .*', run) else 'not logged'}")


main()
