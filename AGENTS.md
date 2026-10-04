# Agent guidance

This repository contains a benchmark campaign for local LLMs driven by the
`pi` coding agent. Read [CLAUDE.md](CLAUDE.md) for repository structure,
platform branches and contribution rules. Read
[suite/OPERATING.md](suite/OPERATING.md) before executing campaign work.

Shared guidance and suite changes belong in a separate PR to `main`, not in
a platform results batch. A person reviews results before merging.

## Code Review Rules

### Evidence and methodology

- Read the relevant platform's RUNBOOK.md and, where present,
  PERFORMANCE_RESEARCH.md before reviewing its results.
- Read the PR description, progress comments, previous reviews and the latest
  committed evidence. Distinguish verified measurements from progress claims.
- Check measurement provenance, exact runtime/backend and model hashes,
  actual compute placement, effective settings, prompt token counts, repeats,
  memory/swap, tool-call results and failure classifications against the
  applicable runbook. Do not infer execution from installed backend libraries.
- Preserve distinctions between model files, quantizations, sampling profiles,
  routes, contexts and interrupted versus uninterrupted runs. Do not borrow
  qualification from a different configuration.
- For Ventuno, provisional eligibility requires both speed gates and the
  documented correctness/memory requirements. Final GO requires V0e for the
  exact configuration and intended windows.

### Independent review

- Review evidence without running benchmarks, installing packages, changing
  the measured checkout, starting servers or starting monitoring agents.
  Execution and live health monitoring belong to the testing agent.
- Identify actionable defects, missing evidence and premature conclusions.
  Check previous findings before posting; avoid duplicates and acknowledge
  fixes. Explain what is complete, what is blocked and the next needed action.
- Check that the PR description contains the testing agent's full execution
  brief, phase boundaries, stop conditions and documented deviations so the
  task can be reconstructed from GitHub.
- Do not post credentials, secrets or unnecessary device identifiers in this
  public repository or repeat them in review comments.
