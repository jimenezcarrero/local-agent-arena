#!/usr/bin/env python3
"""List every logged DSP retry event with its lifetime, run and turn (turn N: from the pi session's Nth user message to the next)."""
import os, re, glob, datetime, json
V1 = os.path.expanduser('~/bench-runs/v1')
rows = []
for lt in sorted(glob.glob(V1 + '/lifetimes/*')):
    log = os.path.realpath(lt + '/server.log'); run = os.path.dirname(log)
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
