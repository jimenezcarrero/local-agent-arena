#!/usr/bin/env python3
"""v1_restart_detail.py <work root>: per server restart of a V1 batch (restarts.log in arena runs), the request the
turn timeout cancelled (generating or reading its prompt, tokens so far, rate), the lifetime's largest gap between
server-log lines, and replies that used the whole 8192-token budget; then the batch's speeds from every server log:
generation of replies of 100+ tokens (overall and by the context at the reply's end), prompts of 8000+ tokens.
Read-only; the root is the batch's BENCH_WORK (~/bench-runs/v1-b4, ~/bench-runs/v1)."""
import glob, os, re, statistics, sys
if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
    sys.exit('usage: v1_restart_detail.py <work root>')
BR = sys.argv[1]
TS = re.compile(r'^(\d+)\.(\d+)\.(\d+)\.(\d+) ')
EV = re.compile(r'\|\s+eval time =\s+([\d.]+) ms /\s+(\d+) tokens')
PE = re.compile(r'prompt eval time =\s+([\d.]+) ms /\s+(\d+) tokens')
BUCKETS = [(8000, '<8K'), (16000, '8-16K'), (24000, '16-24K'), (10 ** 9, '24K+')]
def t(line):
    m = TS.match(line)
    return int(m[1]) * 60 + int(m[2]) + int(m[3]) / 1e3 if m else None
def lines(p):
    return open(p, errors='replace').read().splitlines()
runs = sorted(d for d in glob.glob(f'{BR}/arena*/*') if glob.glob(f'{d}/server*.log'))
if not runs:
    sys.exit(f'no arena runs with server logs under {BR}')
gen, pre, byctx = [], [], {}
for d in runs:
    for log in sorted(glob.glob(f'{d}/server*.log')):
        ev = None
        for l in lines(log):
            m = PE.search(l)
            if m and int(m[2]) >= 8000 and float(m[1]) > 0:
                pre.append(int(m[2]) / float(m[1]) * 1e3)
            m = EV.search(l)
            if m and float(m[1]) > 0:
                ev = (int(m[2]), int(m[2]) / float(m[1]) * 1e3)
                if ev[0] >= 100:
                    gen.append(ev[1])
                continue
            m = re.search(r'stop processing: n_tokens = (\d+)', l)
            if m and ev and ev[0] >= 100:
                byctx.setdefault(next(b for lim, b in BUCKETS if int(m[1]) < lim), []).append(ev[1])
            if m:
                ev = None
for d in runs:
    rl = f'{d}/restarts.log'
    if not os.path.exists(rl):
        continue
    run = os.path.basename(d)
    turns = {int(m[1]): m[2] for m in re.finditer(r'#(\d+): (PASS|FAIL)', open(f'{d}/turns.log').read())} \
        if os.path.exists(f'{d}/turns.log') else {}
    for r in lines(rl):
        k = int(re.search(r'restart=(\d+)', r)[1]); turn = int(re.search(r'turn=(\d+)', r)[1])
        alive = re.search(r'server_alive=(\w+)', r)[1]
        log = f'{d}/server.log' if k == 1 else f'{d}/server_r{k - 1}.log'
        L = lines(log); ts = [x for x in (t(l) for l in L) if x is not None]
        gap = max((b - a for a, b in zip(ts, ts[1:])), default=0)
        full = sum(1 for l in L if (m := EV.search(l)) and int(m[2]) == 8192)
        c = [l for l in L if 'stop: cancel task' in l]
        task = re.search(r'id_task = (\d+)', c[-1])[1] if c else None
        state = 'no cancel line'
        if task:
            last = [l for l in L if f'| task {task} |' in l and 'print_timing' in l]
            last = last[-1] if last else ''
            m = re.search(r'n_gen =\s+(\d+), tg =\s+([\d.]+)', last)
            p = re.search(r'progress = ([\d.]+)', last)
            started = [t(l) for l in L if f'| task {task} | processing task' in l]
            if m: state = f'generating, {m[1]} tokens at {m[2]} tok/s'
            elif p: state = f'reading its prompt, progress {p[1]}'
            elif started and t(c[-1]) is not None: state = f'started {t(c[-1]) - started[-1]:.1f} s before, no progress line yet'
            else: state = 'no progress line'
        print(f'{run:24s} restart {k} turn {turn:2d} ({turns.get(turn, "-")}): alive={alive}; cancelled task {task}: '
              f'{state}; largest log gap {gap:.1f} s; 8192-token replies {full}')
q = lambda v: f'{min(v):.1f}-{max(v):.1f}, median {statistics.median(v):.1f} ({len(v)})' if v else 'none'
print(f'# generation tok/s, replies of 100+ tokens: {q(gen)}')
for _, b in BUCKETS:
    print(f'#   context {b:6s} at the reply\'s end: {q(byctx.get(b, []))}')
print(f'# prompt tok/s, prompts of 8000+ tokens: {q(pre)}')
