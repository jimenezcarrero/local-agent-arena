# Phase V1 (B9) notes

Times are from the clock (status.txt, ledger.txt, server logs, the pi sessions). Server-log times are relative to
each server's start; the clock times below add them to the lifetime's START line.

## Deviations from the plan

1. **Sampling audit after the batch.** v1-plan-B9.txt section 3 asks for `suite/check_sampling.sh` before the first
   run (OPERATING rule 6); it was not in the launch checks and ran at 14:06:36, after the batch (D186; the same
   omission as V0's D48). It changes no setting: every run's /props shows the GGUF's embedded values (temp 1.0,
   top_p 0.95, top_k 20, min_p 0, penalty_repeat 1.0, presence 0), as the plan intends ("llama-server defaults with
   the GGUF's metadata"). For the record, the card (prism-ml/Ternary-Bonsai-2-9B-gguf, revision 5b2abb02362e)
   recommends the same values for thinking mode plus `presence_penalty=1.0`, which was not applied; the base card
   (Qwen/Qwen3.5-9B) gives 1.5 for thinking mode, general tasks.
2. **Hostname redacted.** The committed copies replace the board's hostname with `<host>` (12 env.txt files, the 14
   lifetime journal exports, 3 probe files; 10,153 replacements). Boot ids are kept, as phase-v0 keeps them (D182):
   the journal checks select by them. `scan_identifiers.py --boot-id` matches only the dashed form; the journal and
   the ledger write it without dashes, so 29 of these files carry this boot's id unflagged. Raised to the owner, not
   changed here.

## The two server restarts

Both were turn timeouts (rc 124) with the server alive (restarts.log: `server_alive=yes`); `restart_causes.py` has
no vmstat log for this batch ("no memory samples"), but the health samples cover both lifetimes (memory admitted,
lowest L_min 9,730,192 and 9,631,320 kB for r2 arena 3).

- **r2 arena 3, turn 1** (09:48:41-09:58:41, 600 s budget). The server log shows steady generation to the end: the
  last request started at 09:57:15 and was at 710 generated tokens, 8.33 tok/s, when the turn was stopped. No gap
  over 14.1 s in the log. The turn failed (pytest_t1.log); turns 2-11 passed on the restarted server: 10/11.
- **r3 arena 4, turn 4** (13:15:10-13:45:10, 1800 s budget). One request (task 9602, 13:22:55-13:44:04) had a 20,356-
  token prompt re-read in full (hybrid model, `--ctx-checkpoints 0`; 106 s at 191 tok/s) and generated 8192 tokens,
  the whole output budget, in 1162 s (7.05 tok/s). Three short requests followed; the last was in flight when the
  budget ran out. No gap over 19.0 s in the log. Turns 5-8 ran on the restarted server and the arena passed.

What made these replies long (a long reasoning trace, repetition) is not established; the pi sessions are kept in
`~/bench-runs/v1` (not committed, as in other phases).

## Short replies (pi_length_scan.py)

r3 arena 4 had 3 replies cut by the output-budget clamp, the last at a context of at most 31,598 tokens; pi
recovered each time, and no turn stalled. The other 5 marathon and crusher runs had none.

## DSP retry events

22 logged events (the retry build's rate-limited log of a dspqueue_peek retry, D181) over 14 server lifetimes, each
1 in a row, so none met the fault rule (more than 1 in a row). All 3 baseline probes logged 0. Per run and turn:
`checks/dsp-retry-events.txt` (turn N runs from the pi session's Nth user message to the next; arenas 1-2 have one
turn, shown as `-`), produced by `../tools/retry_turns.py`.

| Run | Events | Turns |
|---|---|---|
| r1 arena 3 | 3 | 1, 1, 1 |
| r1 arena 4 | 5 | 2, 3, 3, 3, 3 |
| r2 arena 1 | 1 | - |
| r2 arena 2 | 1 | - |
| r2 arena 3 | 9 | 1, 1, 1 (first server); 7, 7, 8, 9, 9, 11 (after the restart) |
| r3 arena 2 | 2 | - |
| r3 arena 3 | 1 | 10 |
| all others | 0 | |

## Speed (observed, not a benchmark)

From the server logs' per-request timings: generation 6.5-9.7 tok/s, median 8.0 (207 replies of 100 tokens or
more); prompt processing 162-205 tok/s (64 prompts of 8,000 tokens or more). Prompt caching across turns is limited on this hybrid model with `--ctx-checkpoints 0` (D171): long
prompts are often re-read in full.
