# Review J8 — the two J7 follow-ups

Automatic headless review, 2026-10-03. Stage window 2026-10-03 12:54 → 17:51
(4h57m; the estimate was ~4.5h). Headless, Claude Code exited, persistent
journal, on the fixed arena-3 harness (PR #30; the stage's guard, fixed in
PR #35, passed). Queue exit 0. Both runs are published on `jetson-j8-results`;
`oom-exposure-J8.txt` has no `unknown` row and records no kill. J8 has no
arenas 1–2, so the frozen aggregation rule has nothing to aggregate here.

## a. Granite 4.2 8B defaults marathon on the fixed harness (`j-granite42-8b-def-mar2`)

- **Result: 0/11**, 11 restarts, total 6927s, guard INTACT, no OOM kill.
- **Holdout audit, strict mode: exit 0** (`holdout-audit-J8.txt`: "no match
  found"). By the rule fixed in the README, `mar2` is the clean comparator. "No
  match found" means no detected exposure, not proof of none; on the fixed
  harness the future tests also sat outside the workspace.
- **What happened:** all 11 restarts are `timeout, swap not exhausted`
  (`restart-causes-J8.txt`; available memory 498–598MB, swap free
  1811–1957MB). In the four server logs inspected (`server.log`,
  `server_r1`–`r3`), each turn was one generation still running when the 600s
  cap cancelled it: 3,663–4,249 tokens at 7.45–7.96 tok/s. That is the same
  failure as J7's contaminated `mar1` (0/11, 11 timeouts at the cap).
- **No 32K output-budget stall:** `tools/pi_length_scan.py` finds no short
  length-limited reply in this run. No turn log reads `Connection error.`.
- **The J7 question it answers:** under matched sampling (llama.cpp defaults),
  Granite 4.2 8B's marathon is **0/11 on a clean run**, as Granite 4.1 8B's
  was (phase A). The failure differs: 4.1 8B never started work; 4.2 8B works
  and runs out the turn cap every turn. This is a historical comparison, not a
  version-only one: the quantization scheme (Unsloth UD-IQ3_XXS for 4.1,
  bartowski imatrix IQ3_XXS for 4.2) and the run conditions (desktop on and a
  single run in phase A) differ.

## b. Granite 4.2 3B vendor 32K crusher with `--cache-ram 0` (`j-granite42-3b-vp-cr0`)

- **Pre-registered verdict: SUPPORTS** the prompt-cache hypothesis
  (`memory-verdict-J8.txt`, by `j8_memory_verdict.py`): no OOM kill, and a peak
  VmHWM of **5,126,184 kB**, under the 5,700,000 kB bound.
- **Evidence checked independently:** 362 valid samples of the 3B server over
  10,848s, never more than 31s apart, covering the run's start and end. Across
  its five server processes (the first plus four restarts), VmHWM peaked at
  5.09–5.13M kB, and RssAnon rose from ~4.03M kB at load to ~4.71–4.75M kB at
  the first long prompt, then stayed flat. J7's three crushers, at the
  default `--cache-ram`, each held 6.54–6.58M kB of anonymous memory when the
  kernel killed them.
- **A confound the rule did not anticipate:** server lifetime. Turns 3–6 timed
  out at the 1800s cap, so the server restarted four times, and no J8 server
  lived longer than ~52 minutes (the last one, turns 7–8). J7's killed servers
  had lived 1h15m–1h31m. So J8 shows no growth at all within 30–52 minutes per
  server with the cache off, but it can't show what an equally long-lived
  server would have done. The verdict stands as fixed in advance; how much
  weight it carries is limited by this, and by being one run.
- **The crusher's own scores** (not the question): pytest PASS, anchor_tag,
  anchor_naming and functions_md all FAIL; 8 compactions; 4 restarts, all
  `timeout, swap not exhausted` (available memory ≥1176MB). J7's crushers had
  passed functions_md. One short length-limited reply, recovered, no stalled
  turn.

## Recommendation on the next stage

**There is no next stage: J8 was the last one listed.** By the go/no-go rule,
J8 is operationally clean: the queue exited 0, both tags ended in `done`, the
OOM exposure has no `unknown` row, both runs are published, and none of the
listed environment faults occurred (no server that failed to start, no missing
logs, no stall the vmstat log can't explain, disk 240GB free). Nothing is to
be started, so this review ends without a start command.

Proposals for the user to decide; none changes J8's data:

1. **Write J8 into the Jetson README** (a docs PR after this data PR): the
   clean 8B comparator (0/11, replacing `mar1`'s contaminated 0/11 as the
   answer to J7's question), and the cache result with its lifetime caveat.
2. **If the cache result is to be relied on** (for example, to re-read earlier
   Jetson kills), measure a long-lived server directly: one server kept up for
   1.5h of crusher work at the default cache, then with `--cache-ram 0`, with
   VmHWM sampled. Otherwise, record `--cache-ram` as a setting to cap
   deliberately on 8GB boards in later work, as a recorded configuration
   change.
3. Branch note: the hand-off text says to commit on `jetson-closeout`; that
   branch no longer exists, and J8 ran and published on `jetson-j8-results`,
   so this review is committed there.
