#!/usr/bin/env python3
"""v1_coverage.py <lifetime dir> — evidence coverage for one server lifetime before memfloor's verdict (v1-plan-B9.txt
section 4.4). The lifetime dir is the driver's: run.txt ("<t0> server pid N", "<t1> END") and server.log.
Prints one line; exit 0 "covered ..." only if:
  - health samples (the files memfloor.py reads) cover the window [t0, t1]: the first within MAX_GAP s after t0, the
    last within MAX_GAP s before t1, and no gap between consecutive samples over MAX_GAP s;
  - a log that shows a completed request ("prompt eval time") also has at least one "cache state" line, so the
    prompt cache memfloor adds back is evidenced, not assumed to be 0.
Exit 1 "missing: <reason>" otherwise; missing evidence is never covered."""
import datetime as dt, glob, json, os, re, sys

MAX_GAP = 30
H = os.environ.get("MONITOR_DIR", os.path.expanduser("~/bench-runs/monitor"))


def ep(s):
    return dt.datetime.fromisoformat(s).timestamp()


def main(d):
    try:
        run = open(os.path.join(d, "run.txt")).read()
        t0 = ep(re.search(r"^(\S+) server pid", run, re.M).group(1))
        t1 = ep(re.findall(r"^(\S+) END", run, re.M)[-1])
    except (OSError, AttributeError, IndexError, ValueError):
        return "missing: no 'server pid' and END window in run.txt"
    files = sorted(glob.glob(f"{H}/health-*-runs.jsonl")) or sorted(glob.glob(f"{H}/health-2*.jsonl"))
    ts = set()
    for f in files:
        for line in open(f, errors="replace"):
            try:
                r = json.loads(line)
                if isinstance(r.get("MemAvailable_kB"), int):
                    ts.add(float(r["epoch"]))
            except (ValueError, KeyError, TypeError, AttributeError):
                pass
    win = sorted(t for t in ts if t0 - MAX_GAP <= t <= t1 + MAX_GAP)
    inside = [t for t in win if t0 <= t <= t1]
    if not inside:
        return f"missing: no health sample in the window ({t1 - t0:.0f} s)"
    pts = [t0] + inside + [t1]
    gap = max(b - a for a, b in zip(pts, pts[1:]))
    if gap > MAX_GAP:
        return f"missing: health sample gap {gap:.0f} s > {MAX_GAP} s"
    try:
        log = open(os.path.join(d, "server.log"), errors="replace").read()
    except OSError:
        return "missing: server.log unreadable"
    if "prompt eval time" in log and not re.search(r"cache state: \d+ prompts, [\d.]+ MiB", log):
        return "missing: completed requests but no 'cache state' line"
    return None, len(inside), gap


if __name__ == "__main__":
    r = main(sys.argv[1])
    if isinstance(r, str):
        print(r)
        sys.exit(1)
    print(f"covered: {r[1]} samples, largest gap {r[2]:.0f} s")
