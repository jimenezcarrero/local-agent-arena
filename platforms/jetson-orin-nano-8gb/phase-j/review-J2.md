# Review of stage J2 — 2026-09-26

*Written by the automatic hand-off (Claude Code resumed headless). Nothing was
started by this review.*

J2 ran 07:37–11:46, headless, Claude Code exited. Queue exit 0, all 10 steps
done, all 17 runs published, disk 257GB free. No suspend during the stage.

**The board rebooted before J2** (new boot `ff31da5c`, from 2026-09-26 07:07).
The persistent journal kept the previous boot, including J1's 11 kills: the
first live check of the journal across a reboot, and it held. Every J2 run's
`env.txt` records `boot_id: ff31da5c…`, which matches the running boot.

## OOM exposure: 4 kills in 3 runs, cross-checked

`oom-exposure-J2.txt`: **4 kills, 3 of 17 runs exposed, 0 unknown**. The raw
kernel log for the stage holds exactly those four kills, all in the NeoHorse
Q8 marathons, so this time the file matches what the kernel recorded.

## Every restart, timeout and lost turn, from the logs

| Run | What happened |
|---|---|
| j-neohorse-q8-vp-r1-a3 | Kill at 09:34:00, the moment turn 8's log stops; its tests were green afterwards. Kill at 09:45:51 during turn 11: `pi_t11.log` is exactly `Connection error.`, so turn 11 never reached the model. It still counts green because turn 11 adds no tests. 2 restarts, both after kills. |
| j-neohorse-q8-vp-r2-a3 | **Turn 4 stalled on memory without a kill.** Swap was exhausted (`swapfree_mb=0`), 16–29MB available, 177k–334k major faults per sample. The server only took the request at 10:05:40, 8 minutes into the turn, and the turn hit the cap (691s, rc=124); tests green afterwards, so it counts. Restart #1 followed that timeout. Kill at 10:21:09, the moment turn 10's log stops (turn passed). Restart #2 followed the kill. |
| j-neohorse-q8-vp-r3-a3 | Kill at 10:49:30, the moment turn 10's log stops (turn passed). 1 restart. |
| j-e4b-98k-nomtp-a4-big | **Turn 6: a genuine 30-minute timeout, no fault.** The server was working throughout. One request (task 8507) took a 12,560-token prompt and generated **8,192 tokens, the output limit, at 5.8 tok/s** with 67–88K of context: 24.6 minutes for a single reply. The turn ran into the 1800s cap; the restart followed the timeout. No memory pressure (≈800MB free, swap untouched). The ledger's `peak_slot_ctx=0` for turn 6 is wrong: the context reached 88,595 tokens. See proposal 1. |
| j-lfm25-vp-r2-a2 | Arena 2 timed out (901s, rc=124). The model made 24 requests (largest generation 4,484 tokens) and didn't finish. ≥2.9GB free, no swap, no kill: a genuine timeout. |
| j-lfm25-vp-r3-a1 | Arena 1 timed out (900s, rc=124) after 50 requests; same memory picture. The suite's single arena-1 retry passed in 169s. |

No `guard=MODIFIED`, no GATE stop.

## The README's J2 questions

**A1-4B and LFM2.5 under their published profiles, arenas 1–2 ×3**

| Model | Arena 1 (3 runs) | Arena 2 (3 runs) |
|---|---|---|
| Agents-A1-4B, vendor | **3/3** — 199s, 110s, 154s; median **154s** | **3/3** — 479s, 546s, 658s; median **546s** |
| LFM2.5-2.6B, vendor (temp 0.1) | **2/3** — 240s, 128s, timeout (the retry passed in 169s) | **2/3** — 239s, timeout, 412s |

A1-4B passes every single task under its profile. LFM2.5 timed out once in
each arena, both genuine: the model kept working and didn't finish. That's
consistent with its marathon under the same profile (5/11 ×3 in phase C,
failing from the refactor turn on). **The repo holds no default-sampling
arena 1–2 times for either model**, so this gives vendor-profile results,
not a before/after comparison.

**NeoHorse-1-4B Q8_0 at its vendor profile, marathon ×3 — is the profile what
made the Q4 the best new model?**

11/11 in all three (35m47s, 35m36s, 30m03s), but **no run was uninterrupted**:
4 kills and 5 restarts across the three, one turn that never reached the model
(r1 turn 11) and one memory stall (r2 turn 4). At defaults (phase A) the Q8
scored 10/11 ×3, each losing a turn that never reached the model, so the
difference between the two arms is exactly the kind of interruption both
suffered. **The question can't be settled on this board:** at 4.2GB plus a 32K
window, the Q8 is memory-bound here, and both arms were interrupted. It stays
open for the laptop tier (its B0 baseline runs NeoHorse Q8 at the vendor
profile). Q8 took roughly twice as long as the Q4 (18m51s).

**gemma-E4B @98K without its MTP draft — does the cell fit at all?**

**Yes.** It loaded and ran the big crusher, which it never did with the draft
model (`NvMapMemHandleAlloc` error 12, twice): **partial**, meaning pytest,
the build-tag anchor and FUNCTIONS.md pass while the naming anchor fails. 50m40s,
1 compaction, 0 kills, 1 restart after the turn-6 timeout above. This is a
different configuration from the published row (no MTP) and is reported as
such.

## Recommendation: GO for J3

By the go/no-go rule: the queue exited 0; every tag ended in `done`; the
exposure file has no `unknown` row; all 17 runs are published; and every
restart, timeout and lost turn has an established cause. None of them is a
harness or environment fault. The kills and the memory stall are the board's
memory limit acting on the model (results, not faults), the three timeouts
are genuine, and the `peak_slot_ctx` error is in a diagnostic column that no
score uses.

**J4 reminder:** J1 already met the README's condition for recommending that
J4 (Bonsai) be skipped, and J2's memory stall without a kill points the same
way. The J3 review should make that call.

## Proposals (not applied: scripts are not changed during a review)

1. **arena4.sh reads the context peak after a restart.** After a timeout the
   server is restarted before `peak_slot_ctx` is read, so the new server
   reports 0 (J2 turn 6: really 88,595). Read it before the restart, as
   arena3.sh already does for the prefill counter.
2. **Report memory stalls, not only kills.** J2's r2 turn 4 was a
   swap-exhaustion stall that the kernel never resolved with a kill, so the
   OOM audit can't see it. Write-ups should list every restart with its cause
   (kill, memory stall, or timeout), from the vmstat log and the server log.
   The J1 and J2 reviews do this by hand.
3. **J3 medians need a timeout rule** before the numbers come in: a timed-out
   arena 1–2 run should enter the median as a fail at the cap, not be
   dropped, so a model that times out isn't ranked on its good runs only.

```bash
platforms/jetson-orin-nano-8gb/phase-j/start_stage.sh J3
```
