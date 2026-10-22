# mac_targets.py <bare repo> <candidates out> <targets out> — find every MAC-like value in every blob and commit message
# reachable from the repo's refs (case-insensitive, ':' or '-' separators), classify each by where it occurs, and write
# the targets: every value that occurs anywhere outside a tools/ directory (the evidence), not the test fixtures that
# live only in tools/. Prints indices, counts and path classes only, never a value. Files are written mode 600.
import collections, os, re, subprocess, sys

repo, cand_out, targ_out = sys.argv[1:4]
MAC = re.compile(rb"(?<![0-9A-Za-z])[0-9A-Fa-f]{2}([:-])(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}(?![0-9A-Za-z])")


def norm(v):
    return v.decode().lower().replace("-", ":")


def git(*a, **kw):
    return subprocess.run(["git", "-C", repo, *a], check=True, stdout=subprocess.PIPE, **kw).stdout


objs = git("rev-list", "--all", "--objects").decode().splitlines()
paths = collections.defaultdict(set)
for line in objs:
    sha, _, path = line.partition(" ")
    paths[sha].add(path)
commits = git("rev-list", "--all").decode().split()
shas = [l.split(" ", 1)[0] for l in objs]
p = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
found = collections.defaultdict(lambda: {"blobs": 0, "msgs": 0, "classes": set(), "dirs": set()})
read = 0
for sha in dict.fromkeys(shas):
    p.stdin.write(sha.encode() + b"\n"); p.stdin.flush()
    # every record complete, or stop: a missed object could hide a target (Codex review of mac_verify.py's scan)
    line = p.stdout.readline(); hdr = line.split()
    if (not line.endswith(b"\n") or len(hdr) != 3 or hdr[0].decode() != sha
            or hdr[1] not in (b"blob", b"tree", b"commit", b"tag") or not hdr[2].isdigit()):
        sys.exit(f"mac_targets: bad or missing object record ({read} read)")
    size = int(hdr[2]); data = p.stdout.read(size)
    if len(data) != size or p.stdout.read(1) != b"\n":
        sys.exit(f"mac_targets: truncated object ({read} read)")
    read += 1
    kind = hdr[1]
    if kind not in (b"blob", b"commit"):
        continue
    for m in MAC.finditer(data):
        f = found[norm(m.group(0))]
        if kind == b"commit":
            f["msgs"] += 1; f["classes"].add("commit message")
        else:
            f["blobs"] += 1
            for path in paths[sha]:
                f["classes"].add("tools/" if "/tools/" in path or path.startswith("tools/") else "evidence/docs")
                f["dirs"].add(os.path.dirname(path))
p.stdin.close()
if p.wait() != 0:
    sys.exit(f"mac_targets: git cat-file exited {p.returncode}")
if read != len(dict.fromkeys(shas)):
    sys.exit(f"mac_targets: read {read} of {len(dict.fromkeys(shas))} objects")
own = open("/sys/class/net/wlp3s0/address").read().strip().lower() if os.path.exists("/sys/class/net/wlp3s0/address") else ""
fd = os.open(cand_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
cand = os.fdopen(fd, "w")
targets = []
for i, (v, f) in enumerate(sorted(found.items(), key=lambda x: -x[1]["blobs"]), 1):
    is_target = f["classes"] != {"tools/"}
    cand.write(f"{v}\n")
    if is_target:
        targets.append(v)
    tag = "TARGET" if is_target else "fixture (tools/ only, kept)"
    extra = " [the board's own interface address]" if v == own else ""
    print(f"candidate {i}: {tag}{extra}; blobs {f['blobs']}, commit messages {f['msgs']}; classes "
          f"{', '.join(sorted(f['classes']))}; dirs {', '.join(sorted(f['dirs']))[:160]}")
cand.close()
fd = os.open(targ_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as t:
    t.write("".join(v + "\n" for v in targets))
print(f"candidates {len(found)}, targets {len(targets)}; commits scanned {len(commits)}")
