# Sampling settings per model

**Read this before running any model.** Sampling comes from three places, and
they disagree:

1. **The model card** on Hugging Face — the vendor's recommendation, often
   given as the protocol used for their own benchmark numbers. Check the base
   model's card, not only the GGUF repo's.
2. **The GGUF's `general.sampling.*` metadata** — llama.cpp applies these
   automatically when present, so a model can silently run at settings you
   never passed.
3. **llama.cpp defaults** (temp 0.8, top_k 40, top_p 0.95, min_p 0.05, no
   penalties) — what you get when neither of the above applies.

To see what a running server will actually use:

```bash
curl -s localhost:8080/props | python3 -m json.tool | grep -A2 -E 'temperature|top_k|top_p|min_p|penalty'
```

The suite records this in every run's `env.txt` (`sampling:` line).

## Policy

- **Run each model at its vendor-recommended settings** when the card publishes
  any, and say so in the results. Where the card gives separate thinking and
  non-thinking profiles, use the thinking one: these arenas are agent sessions.
- **When no recommendation exists**, run llama.cpp defaults and record that.
- **When a model fails in a way sampling could explain** — endless generation,
  repetition, wildly different results between identical runs — run the
  alternative profile as a labelled variant and report both. Two measurements
  beat an argument. This has paid off twice: Ling-3.0-tiny matched its score
  27% faster on 32% less energy at temp 0.3 instead of the recommended 1.0, and
  Spark-X2.5-4B's runaway sessions are being retested the same way.
- **Never change sampling midway through a model's runs.** A cell's repeats must
  share one configuration, or the pass count means nothing.

## Known settings

| Model | Vendor recommendation | In GGUF metadata? | Notes |
|---|---|---|---|
| Spark-X2.5-4B / 1.7B | temp 1.0, top_p 0.95, top_k -1 | **yes** — runs at these automatically | Jetson runs used them; sessions were unstable (see phase-a results) |
| NeoHorse-1-4B | temp 1.0, top_p 0.95, top_k 20, min_p 0, presence_penalty **1.5**, repetition_penalty 1.0 | no | Jetson Phase A3/A5 ran llama.cpp defaults; Phase A6 runs the vendor profile |
| Ornith-1.0-9B / 1.5-9B | temp 1.0, top_p 0.95 (agent harnesses); top_p 1.0 on Terminal-Bench | no | The whole Jetson campaign ran these at llama.cpp defaults |
| Ling-3.0-tiny | temp 1.0, top_p 0.95, top_k 20 | **yes** | At temp 0.3: same marathon score, 27% faster, 32% less energy |
| Qwen3.8-27B | thinking: temp 1.0, top_p 0.95, top_k 20, min_p 0; non-thinking: temp 0.7, top_p 0.80, presence_penalty 1.5 | check the file | Card suggests raising presence_penalty up to 2 against endless repetition |
| Granite 4.1 3B / 8B / 30B | none published | no | llama.cpp defaults; record that |

Add a row whenever you test a new model, and put the same information next to
its sha256 in the platform's `files.txt`.
