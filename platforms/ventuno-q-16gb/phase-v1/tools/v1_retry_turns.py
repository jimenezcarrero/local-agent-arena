#!/usr/bin/env python3
"""v1_retry_turns.py <live work root> (v1-plan-4B.txt section 4.4): every logged DSP retry event of one batch with its
server lifetime, run and turn (turn N: from the pi session's Nth user message to the next; one-turn arenas print "-").
retry_turns.py, B9's (D186), with the batch's BENCH_WORK as a required argument (it read ~/bench-runs/v1). Exit 2,
nothing printed but the reason, on a missing root, no lifetimes, or a lifetime without its journal export or server
log; it never falls back to another path."""
import datetime, glob, json, os, re, sys


def refuse(why):
    print(f'v1_retry_turns: REFUSED: {why}', file=sys.stderr); sys.exit(2)


if len(sys.argv) != 2:
    refuse('usage: v1_retry_turns.py <live work root>')
root = sys.argv[1]
lts = sorted(glob.glob(os.path.join(root, 'lifetimes', '*')))
if not os.path.isdir(root) or not lts:
    refuse(f'no lifetimes under {root}')
rows = []
for lt in lts:
    if not os.path.isfile(lt + '/fastrpc-journal.txt') or not os.path.isfile(lt + '/server.log'):
        refuse(f'{os.path.basename(lt)}: journal export or server log missing')
    run = os.path.dirname(os.path.realpath(lt + '/server.log'))
    starts = []  # turn N starts at the session's Nth user message
    for f in glob.glob(run + '/pisessions/*.jsonl'):
        for l in open(f):
            e = json.loads(l)
            if e.get('type') == 'message' and (e.get('message') or {}).get('role') == 'user':
                starts.append(datetime.datetime.fromisoformat(e['timestamp'].replace('Z', '+00:00')).timestamp())
    starts.sort(); nturns = sum(1 for _ in open(run + '/turns.log')) if os.path.exists(run + '/turns.log') else 0
    turns = [(i + 1, t, starts[i + 1] if i + 1 < len(starts) else 1e12) for i, t in enumerate(starts)] if nturns else []
    if nturns and len(starts) != nturns: print(f'# {run}: {len(starts)} user messages for {nturns} turns')
    for line in open(lt + '/fastrpc-journal.txt', errors='replace'):
        if 'retrying' not in line:
            continue
        ts = datetime.datetime.fromisoformat(line.split()[0]).timestamp()
        turn = next((str(n) for n, a, b in turns if a <= ts < b), '-' if not turns else '?')
        msg = re.sub(r'^.*?(\S*retrying.*)$', r'\1', line.strip())[:110]
        rows.append(f"{line.split()[0]}  {os.path.basename(lt):22s} {os.path.basename(run):24s} turn {turn:3s} {msg}")
print('\n'.join(rows)); print(f'# {len(rows)} logged retry events')
