#!/usr/bin/env python3
"""health_verdict.py <health.txt> <checker_exit_status> — fail-closed verdict on a health_check.py run.

Exit 0 and print "pass" only when the checker ran to completion and found no real alert:
  - exit status 0 with a valid summary line, or
  - exit status 1 with a valid summary line whose ALERT lines are ALL memory-PSI alerts (documented exception:
    PSI spikes accompany every large model load from eMMC; printed as "pass (PSI-only alerts exempt)").
Exit 1 otherwise, printing the reason: a real ALERT, a checker crash or any other exit status, a missing or
malformed summary line, or a missing/empty/unreadable file. Missing evidence is never a pass."""
import re, sys

SUMMARY = re.compile(r"^\S+ window=\S+ samples=(\d+) last=\S+ min_avail=[\d.]+GiB swap_max=\d+kB ")


def verdict(path, status):
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError as e:
        return 1, f"fail: health file unreadable ({e.__class__.__name__})"
    if not lines:
        return 1, "fail: health file empty"
    if not re.fullmatch(r"-?\d+", status):
        return 1, f"fail: checker exit status not recorded ({status!r})"
    st = int(status)
    m = SUMMARY.match(lines[0])
    if not m:
        return 1, f"fail: checker produced no valid summary (exit {st}; first line: {lines[0][:80]!r})"
    if int(m.group(1)) == 0:
        return 1, "fail: no samples in the window"
    if any(l.startswith("Traceback") for l in lines):
        return 1, f"fail: checker traceback (exit {st})"
    alerts = [l for l in lines if l.startswith("ALERT")]
    if st == 0 and not alerts:
        return 0, "pass"
    if st == 1 and alerts and all("memory PSI" in a for a in alerts):
        return 0, "pass (PSI-only alerts exempt)"
    if st == 1 and alerts:
        return 1, "fail: " + "; ".join(a for a in alerts if "memory PSI" not in a)[:300]
    return 1, f"fail: checker exit {st} inconsistent with its output ({len(alerts)} ALERT lines)"


if __name__ == "__main__":
    code, why = verdict(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    print(why)
    sys.exit(code)
