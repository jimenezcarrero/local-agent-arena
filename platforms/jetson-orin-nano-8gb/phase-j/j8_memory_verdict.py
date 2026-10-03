#!/usr/bin/env python3
"""j8_memory_verdict.py <rss-J8.log> <oom-exposure-J8.txt> <results.txt> — J8b's reading, as fixed in README.md.

Question: with --cache-ram 0, does the Granite 4.2 3B 32K crusher's llama-server
still grow toward the ~6.8GB (RSS) at which J7's three crushers were killed?

Evidence used:
- rss-J8.log, one line per 30s sample: time, pid, model file, VmHWM and RssAnon
  (kB as /proc reports them, 1 kB = 1024 bytes). VmHWM is the kernel's own
  high-water mark of the process's resident set, so growth between samples is
  not missed: each sample reports the peak so far. Lines with a missing value
  are discarded. Only samples whose model is granite-4.2-3b-Q8_0.gguf count.
- oom-exposure-J8.txt, the kernel-recorded kills of the run
  (j-granite42-3b-vp-cr0-a4-32k).
- results.txt, the run's RESULT line (end time and total) for its time window.

Verdict (README.md, J8b), on the peak = max VmHWM over the run's server PIDs:
  supports      no OOM kill, peak <= 5,700,000 kB (load baseline 4,958,380 kB
                measured with --cache-ram 0, plus one 32K context, ~732,000 kB)
  refutes       an OOM kill, or peak >= 6,500,000 kB
  inconclusive  anything between, or incomplete evidence: no RESULT line, no
                OOM row (or "unknown"), fewer than 10 valid samples, a sample
                gap over 120s, or the samples not reaching within 120s of the
                run's start and end
Limit: growth in a server's last <=30s before a normal exit is not sampled; a
kill in that window is still caught by the OOM row.
Exit: 0 supports, 1 refutes, 2 inconclusive.
"""
import datetime, re, sys

RUN = "j-granite42-3b-vp-cr0-a4-32k"
MODEL = "granite-4.2-3b-Q8_0.gguf"
SUPPORT_MAX, REFUTE_MIN = 5_700_000, 6_500_000
MAX_GAP, EDGE, MIN_SAMPLES = 120, 120, 10


def ts(s):
    return datetime.datetime.fromisoformat(s).timestamp()


def verdict(rss_lines, oom_text, results_text):
    why = []
    m = None
    for line in results_text.splitlines():
        mm = re.match(rf"(\S+) RESULT {re.escape(RUN)}: .*total=(\d+)s", line)
        if mm:
            m = mm
    if not m:
        return "inconclusive", ["no RESULT line for the run"], None
    end = ts(m.group(1)); start = end - int(m.group(2))
    om = re.search(rf"^{re.escape(RUN)}\s+oom_kills=(\S+)", oom_text, re.M)
    kills = om.group(1) if om else None
    samples = []
    for line in rss_lines:
        f = dict(x.split("=", 1) for x in line.split()[1:] if "=" in x)
        try:
            t = ts(line.split()[0]); hwm = int(f["vmhwm_kb"]); int(f["rss_anon_kb"])
        except (ValueError, KeyError, IndexError):
            continue
        if f.get("model") == MODEL and start - EDGE <= t <= end + EDGE:
            samples.append((t, f["pid"], hwm))
    samples.sort()
    peak = max((s[2] for s in samples), default=None)
    if kills not in (None, "unknown") and kills != "0":
        return "refutes", [f"{kills} OOM kill(s) recorded for the run"], peak
    if peak is not None and peak >= REFUTE_MIN:
        return "refutes", [f"peak VmHWM {peak} kB >= {REFUTE_MIN} kB"], peak
    if kills is None:
        why.append("no OOM-exposure row for the run")
    elif kills == "unknown":
        why.append("OOM exposure unknown for the run")
    if len(samples) < MIN_SAMPLES:
        why.append(f"{len(samples)} valid samples (< {MIN_SAMPLES})")
    else:
        gaps = [b[0] - a[0] for a, b in zip(samples, samples[1:])]
        if max(gaps) > MAX_GAP:
            why.append(f"a sample gap of {int(max(gaps))}s (> {MAX_GAP}s)")
        if samples[0][0] > start + EDGE or samples[-1][0] < end - EDGE:
            why.append("samples do not cover the run's start and end")
    if why:
        return "inconclusive", why, peak
    if peak <= SUPPORT_MAX:
        return "supports", [f"no OOM kill; peak VmHWM {peak} kB <= {SUPPORT_MAX} kB"], peak
    return "inconclusive", [f"peak VmHWM {peak} kB between {SUPPORT_MAX} and {REFUTE_MIN} kB"], peak


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    rss = open(argv[0], errors="replace").read().splitlines() if argv[0] != "-" else []
    v, why, peak = verdict(rss, open(argv[1], errors="replace").read(), open(argv[2], errors="replace").read())
    print(f"J8b memory verdict: {v.upper()}  (peak VmHWM {peak if peak is not None else 'n/a'} kB)")
    for w in why:
        print(f"  - {w}")
    return {"supports": 0, "refutes": 1, "inconclusive": 2}[v]


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except OSError as e:
        print(f"J8b memory verdict: INCONCLUSIVE  (cannot read input: {e})"); sys.exit(2)
