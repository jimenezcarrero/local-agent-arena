# On-demand LLM serving on the Jetson Orin Nano 8GB

Quick reference: `llm help`. This file is the long version.
Model choices come from the benchmark campaign in the repo root
([github.com/jimenezcarrero/jetson-llm-benchmarks](https://github.com/jimenezcarrero/jetson-llm-benchmarks)).

## Architecture

```
you / pi ──HTTP:8080──> llama-server (ROUTER, no model, ~0 GPU)
                          │  reads jetson-models.ini
                          │  request names "ornith" → spawn child with
                          ▼  that preset's exact flags (old child unloaded first)
                        llama-server child (internal port, one model loaded)
```

- The router is a systemd service (`llama-server.service`), **disabled at
  boot** — the GPU belongs to you until `llm start`.
- `--models-max 1` is what makes swapping safe on 8GB: the loaded model is
  fully unloaded **before** the next one loads (verified: no OOM; swap takes
  ~13–25 s including cold load).
- Presets are read **once at router startup** — after editing
  `jetson-models.ini`, run `sudo systemctl restart llama-server`.
- pi integration: `~/.pi/agent/models.json` lists the same preset IDs with
  each preset's real context window, so `/model` inside pi both swaps the
  served model *and* keeps pi's auto-compaction trigger correct.

## The `llm` command

| command | what it does |
|---|---|
| `llm start` | start router (systemd), wait for API, show model menu |
| `llm stop` | stop router + child, free GPU memory |
| `llm status` | running state, loaded model, RAM use |
| `llm pick` | recommendation menu again |
| `llm load NAME` | preload a preset (1-token warm-up request) |
| `llm models` | all presets + loaded/unloaded state |
| `llm logs [N]` | follow server logs live from journald |
| `llm fg` | run router in the foreground, logs in your terminal |

Logs: the service writes to journald (that's why `llm start` shows nothing) —
`llm logs` follows them; `llm fg` gives the classic logs-in-terminal
experience instead of the service.

## Model presets (benchmark verdicts)

| preset | model | when to use |
|---|---|---|
| `ornith` | Ornith-1.0-9B IQ3_M @65K | **default** — undefeated in all 4 arenas; frugal context use |
| `a1-131k` | Agents-A1-4B Q4_K_M @131K | speed — fastest perfect 11-turn marathon |
| `a1-262k` | same @262K | max context — only full native window that fits 8GB |
| `e4b-32k` | gemma-4-E4B QAT +MTP @32K | gemma quality — needs the small window + compaction |
| `e2b-32k` | gemma-4-E2B QAT +MTP @32K | ~58 tok/s chat; weak in long sessions |
| `qwen-131k` | Qwen3.5-4B base @131K | baseline; not agent-tuned |

## Adding a new model

1. Put the GGUF in `~/Repositories/llama.cpp/models/`. Budget: weights + KV
   cache ≤ ~5 GB with the desktop running (~6 GB headless).
2. Add a section to `jetson-models.ini` (the section name = the model ID).
   Starting points: copy `ornith`'s block for dense models; `a1-131k`'s for
   Qwen-family (their KV quantizes for free); `e4b-32k`'s if the model has a
   separate MTP draft (remember `spec-type = draft-mtp` — without it llama.cpp
   silently runs at normal speed). Then `sudo systemctl restart llama-server`.
3. Add a matching entry in `~/.pi/agent/models.json`: `"id"` = section name,
   `"contextWindow"` = the `c` value. Optionally add a line to the `llm` menu.

Sizing a context window: start high; if the child fails to load (see
`llm logs`), halve `c` or set `ctk`/`ctv` to `q4_0`. The campaign's KV-quant
findings: free on Qwen3.5-family, costs ~12% speed (and V-cache quality) on
gemma.

## Updating llama.cpp

```bash
cd ~/Repositories/llama.cpp && git pull
cmake --build build --config Release -j3 --target llama-server
```

The systemd unit and the `/usr/local/bin/{llama-server,llama-cli,llama-bench}`
symlinks all point into `build/bin/`, so a rebuild is the whole update.
(`-j3`, not more — `-j6` OOMs the board during CUDA compilation.)

Alternative: the official prebuilt distribution at [llama.app](https://llama.app)
**does work on this board** — its CUDA probe picks an sm_86 build that runs on
the Orin's sm_87 via binary compatibility (verified: 85–99% GPU utilization,
~17 W under load, 29.7 tok/s E2B solo — parity with our source build). First
run stalls several minutes on one-time PTX JIT compilation; that's normal and
cached afterwards. It installs a separate `~/.local/bin/llama` launcher and
doesn't conflict with this setup. Trade-off: `llama update` tracks upstream
`latest`, which is convenient but gives up version pinning — this serving
stack stays on the source build for reproducibility.

## Known issues

- **NvMap/CMA fragmentation**: after many load/unload cycles in one uptime,
  large allocations can start failing even with free RAM. Reboot; the router
  comes back clean (and empty).
- **`a1-262k` is the tightest fit** — close heavy desktop apps if it fails.
- First token after `llm start` includes model load time (~15–30 s) — that's
  the on-demand trade-off. `llm load` hides it up front.
