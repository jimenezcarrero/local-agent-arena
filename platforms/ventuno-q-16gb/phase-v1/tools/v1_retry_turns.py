#!/usr/bin/env python3
"""v1_retry_turns.py <live work root> (v1-plan-4B.txt section 4.4): every logged DSP retry event of one batch with its
server lifetime, run and turn (turn N: from the pi session's Nth user message to the next; one-turn arenas print "-").
retry_turns.py, B9's (D186), with the batch's BENCH_WORK as a required argument (it read ~/bench-runs/v1).
The root's name gives its configuration (v1 = B9, v1-b4, v1-a32); every input must be complete and inside the root
(review of b0cec52), else exit 2 with only the reason printed, never a fallback or a partial list:
  - status.txt and ledger.txt present; at least one lifetime, each named with the configuration's tag stem;
  - each lifetime's journal export complete as the driver accepted it: journal-check.txt "ok:", the export non-empty
    with the DSP library open line and CDSP0 lines;
  - its server.log resolving to a log under <root>/arena<n>/<run>/, the run named with the stem, the log recorded in
    the ledger (log=<path>);
  - the lifetimes one-to-one with status.txt's LIFETIME lines, and their server logs one-to-one with the ledger's
    server starts, so a missing lifetime cannot shrink the list (review of 687ffbe);
  - an arena 3 or 4 run (the arena from its directory, not from which files exist) with a non-empty turns.log and a
    pi session holding one user message per turn, and every event inside a turn; "-" only for arenas 1 and 2."""
import datetime, glob, json, os, re, sys

STEMS = {'v1': 'b9-q20-htp2', 'v1-b4': 'b4-q20-htp1', 'v1-a32': 'nh4-q40-a32'}


def refuse(why):
    print(f'v1_retry_turns: REFUSED: {why}', file=sys.stderr); sys.exit(2)


if len(sys.argv) != 2:
    refuse('usage: v1_retry_turns.py <live work root>')
root = os.path.realpath(sys.argv[1])
if not os.path.isdir(root):
    refuse(f'no work root at {sys.argv[1]}')
stem = STEMS.get(os.path.basename(root)) or refuse(f'unknown work root name {os.path.basename(root)} (v1, v1-b4 or v1-a32)')
for f in ('status.txt', 'ledger.txt'):
    if not os.path.isfile(os.path.join(root, f)):
        refuse(f'no {f} in {root}')
ledger_logs = set()
for l in open(os.path.join(root, 'ledger.txt')):
    m = re.search(r' START pid=\d+ boot=\S+ log=(.+)$', l.rstrip('\n'))
    if m:
        ledger_logs.add(os.path.realpath(m[1]))
lts = sorted(glob.glob(os.path.join(root, 'lifetimes', '*')))
if not lts:
    refuse(f'no lifetimes under {root}')
want = sorted(re.findall(r' LIFETIME ([^:\s]+):', open(os.path.join(root, 'status.txt')).read()))
have = sorted(os.path.basename(x) for x in lts)
if want != have:
    refuse(f'the lifetimes under {root}/lifetimes are not the ones status.txt records '
           f'(missing {sorted(set(want) - set(have))[:3]}, extra {sorted(set(have) - set(want))[:3]})')
seen = []
rows = []
for lt in lts:
    name = os.path.basename(lt)
    if not name.startswith(stem + '-'):
        refuse(f'lifetime {name} is not {stem}\'s')
    j = os.path.join(lt, 'fastrpc-journal.txt')
    chk = open(os.path.join(lt, 'journal-check.txt')).read() if os.path.isfile(os.path.join(lt, 'journal-check.txt')) else ''
    text = open(j, errors='replace').read() if os.path.isfile(j) else ''
    if not chk.startswith('ok:') or not text or 'Successfully opened file libggml-htp-v75.so' not in text or 'CDSP0:' not in text:
        refuse(f'{name}: journal export missing or incomplete (journal-check "{chk.strip()[:60]}")')
    if not os.path.lexists(os.path.join(lt, 'server.log')):
        refuse(f'{name}: no server.log')
    log = os.path.realpath(os.path.join(lt, 'server.log')); run = os.path.dirname(log)
    rel = os.path.relpath(log, root).split(os.sep)
    if len(rel) != 3 or not re.fullmatch(r'arena[1-4]', rel[0]) or not rel[1].startswith(stem + '-') or not os.path.isfile(log):
        refuse(f'{name}: server.log resolves outside {root}/arena<n>/{stem}-*/ ({log})')
    if log not in ledger_logs:
        refuse(f'{name}: its server log is not recorded in the ledger')
    seen.append(log)
    turns = []
    if rel[0] in ('arena3', 'arena4'):
        nturns = sum(1 for l in open(run + '/turns.log') if l.strip()) if os.path.isfile(run + '/turns.log') else 0
        if not nturns:
            refuse(f'{name}: {rel[0]} run {rel[1]} has no turn records (turns.log missing or empty)')
        starts = []  # turn N starts at the session's Nth user message
        for f in glob.glob(run + '/pisessions/*.jsonl'):
            for l in open(f):
                e = json.loads(l)
                if e.get('type') == 'message' and (e.get('message') or {}).get('role') == 'user':
                    starts.append(datetime.datetime.fromisoformat(e['timestamp'].replace('Z', '+00:00')).timestamp())
        starts.sort()
        if not starts or len(starts) != nturns:
            refuse(f'{name}: {len(starts)} pi user messages for {nturns} turns in {os.path.basename(run)}')
        turns = [(i + 1, t, starts[i + 1] if i + 1 < len(starts) else 1e12) for i, t in enumerate(starts)]
    for line in text.splitlines():
        if 'retrying' not in line:
            continue
        ts = datetime.datetime.fromisoformat(line.split()[0]).timestamp()
        turn = next((str(n) for n, a, b in turns if a <= ts < b), '-' if not turns else None)
        if turn is None:
            refuse(f'{name}: a retry event at {line.split()[0]} is outside every turn of {os.path.basename(run)}')
        msg = re.sub(r'^.*?(\S*retrying.*)$', r'\1', line.strip())[:110]
        rows.append(f"{line.split()[0]}  {name:22s} {os.path.basename(run):24s} turn {turn:3s} {msg}")
if sorted(seen) != sorted(ledger_logs) or len(set(seen)) != len(seen):
    refuse(f'the lifetimes\' server logs are not the ledger\'s server starts one-to-one '
           f'({len(set(seen))} logs for {len(ledger_logs)} recorded starts)')
print('\n'.join(rows)); print(f'# {len(rows)} logged retry events')
