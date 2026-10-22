# mac_verify.py <orig bare> <new bare> <old marks> <new marks> <targets> <commit map out> — verify a MAC-removal rewrite
# commit by commit against the untouched original. Passes only if:
#   - every original commit maps to exactly one new commit (or, outside the rewrite scope, survives with its own id)
#     and the commit counts are equal;
#   - each new commit's parents are the mapped original parents, in order;
#   - author, committer, encoding and every other header are byte-equal; the only header that may disappear is
#     gpgsig (git 2.43's fast-export does not carry commit signatures; counted);
#   - the message equals the original with the targets replaced by <mac>;
#   - every tree has the same paths, modes and types; each changed blob equals the original with the targets replaced
#     (and the original held a target); unchanged blobs keep their id;
#   - every branch and tag points to the mapped commit;
#   - no object in the new repo holds any target, in any case, with ':', '-' or no separator (an independent check).
# Prints counts only, never a value. Exit 0 only on PASS.
import os, re, subprocess, sys

orig, new, om, nm, tfile, map_out = sys.argv[1:7]
targets = [l.strip() for l in open(tfile) if l.strip()]
fails = []


def fail(msg):
    if len(fails) < 50:
        print("FAIL " + msg)
    fails.append(msg)


class ScanError(Exception):
    """An object read that is incomplete or failed; never treated as an empty or clean result (it ends the run)."""


TYPES = (b"blob", b"tree", b"commit", b"tag")


def read_object(stream, what):
    """One cat-file --batch record as (sha, type, payload); None only at a clean end of the stream."""
    hdr = stream.readline()
    if not hdr:
        return None
    if hdr.endswith(b" missing\n"):
        raise ScanError(f"{what}: object missing")
    parts = hdr.split()
    if not hdr.endswith(b"\n") or len(parts) != 3 or parts[1] not in TYPES or not parts[2].isdigit():
        raise ScanError(f"{what}: malformed object header")
    size = int(parts[2]); data = stream.read(size); end = stream.read(1)
    if len(data) != size or end != b"\n":
        raise ScanError(f"{what}: truncated object ({len(data)} of {size} bytes)")
    return parts[0].decode(), parts[1].decode(), data


class Cat:
    def __init__(self, repo):
        self.what = f"cat-file in {os.path.basename(repo)}"
        self.p = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE)

    def get(self, sha):
        self.p.stdin.write(sha.encode() + b"\n"); self.p.stdin.flush()
        rec = read_object(self.p.stdout, self.what)
        if rec is None:
            raise ScanError(f"{self.what}: ended early")
        return rec[1], rec[2]

    def close(self):
        self.p.stdin.close()
        rc = self.p.wait()
        if rc != 0:
            raise ScanError(f"{self.what}: exited {rc}")


def git(repo, *a):
    return subprocess.run(["git", "-C", repo, *a], check=True, stdout=subprocess.PIPE).stdout


# the intended transformation, written separately from mac_filter.py
VARIANTS = []
for t in targets:
    pairs = t.split(":")
    for sep in (":", "-"):
        VARIANTS.append(re.compile(re.escape(sep.join(pairs)).encode(), re.I))


def transform(b):
    for rx in VARIANTS:
        b = rx.sub(b"<mac>", b)
    return b


# residual check: any separator or none, any case
RESID = [re.compile("[:-]?".join(t.split(":")).encode(), re.I) for t in targets]

co, cn = Cat(orig), Cat(new)
marks_old = dict(l.split() for l in open(om))
marks_new = dict(l.split() for l in open(nm))
cmap = {}
for mark, old in marks_old.items():
    if mark in marks_new and co.get(old)[0] == "commit":
        cmap[old] = marks_new[mark]
orig_commits = git(orig, "rev-list", "--all").decode().split()
new_commits = set(git(new, "rev-list", "--all").decode().split())
print(f"original commits {len(orig_commits)}, new commits {len(new_commits)}, mapped {len(cmap)}")
if len(orig_commits) != len(new_commits):
    fail("commit counts differ")
kept = 0
for c in orig_commits:
    if c not in cmap:
        # outside the rewrite scope (not a leak commit or a descendant): must survive unchanged, same id
        if c in new_commits:
            cmap[c] = c; kept += 1
        else:
            fail(f"original commit {c[:10]} neither rewritten nor kept")
print(f"kept unchanged (outside the scope) {kept}")
if len(set(cmap.values())) != len(cmap):
    fail("two original commits map to one new commit")


def parse(raw):
    head, _, msg = raw.partition(b"\n\n")
    hdrs = []
    for line in head.split(b"\n"):
        if line.startswith(b" ") and hdrs:
            hdrs[-1] = (hdrs[-1][0], hdrs[-1][1] + b"\n" + line)
        else:
            k, _, v = line.partition(b" ")
            hdrs.append((k, v))
    return hdrs, msg


blob_ok = {}
tree_ok = set()
sig_dropped = changed_commits = changed_blobs = 0


def ls_tree(repo, tree):
    out = git(repo, "ls-tree", "-r", "-z", "--full-tree", tree).split(b"\0")
    ents = []
    for e in out:
        if not e:
            continue
        meta, _, path = e.partition(b"\t")
        mode, typ, sha = meta.split()
        ents.append((path, mode, typ, sha.decode()))
    return ents


for c in orig_commits:
    n = cmap.get(c)
    if not n:
        continue
    if n == c:
        continue  # kept: same id, so byte-identical (its signature, if any, stays)
    to, ro = co.get(c); tn, rn = cn.get(n)
    if tn != "commit":
        fail(f"{c[:10]}: new object is not a commit"); continue
    ho, mo = parse(ro); hn, mn = parse(rn)
    po = [v.decode() for k, v in ho if k == b"parent"]; pn = [v.decode() for k, v in hn if k == b"parent"]
    if [cmap.get(p) for p in po] != pn:
        fail(f"{c[:10]}: parents differ from the mapped originals")
    keep_o = [(k, v) for k, v in ho if k not in (b"tree", b"parent", b"gpgsig")]
    keep_n = [(k, v) for k, v in hn if k not in (b"tree", b"parent")]
    if keep_o != keep_n:
        fail(f"{c[:10]}: headers differ (author, committer, encoding or other)")
    if any(k == b"gpgsig" for k, _ in ho):
        sig_dropped += 1
    if transform(mo) != mn:
        fail(f"{c[:10]}: message differs beyond the replacement")
    if c != n:
        changed_commits += 1
    tro = dict(ho)[b"tree"].decode(); trn = dict(hn)[b"tree"].decode()
    if (tro, trn) in tree_ok:
        continue
    eo, en = ls_tree(orig, tro), ls_tree(new, trn)
    if [(p, m, t) for p, m, t, _ in eo] != [(p, m, t) for p, m, t, _ in en]:
        fail(f"{c[:10]}: paths, modes or types differ"); continue
    good = True
    for (p, m, t, so), (_, _, _, sn) in zip(eo, en):
        if so == sn:
            continue
        if t != b"blob":
            fail(f"{c[:10]}: non-blob entry changed"); good = False; continue
        if (so, sn) not in blob_ok:
            bo = co.get(so)[1]; bn = cn.get(sn)[1]
            blob_ok[(so, sn)] = bo is not None and bn is not None and transform(bo) == bn and bo != bn
            changed_blobs += blob_ok[(so, sn)]
        if not blob_ok[(so, sn)]:
            fail(f"{c[:10]}: a file differs beyond the replacement"); good = False
    if good:
        tree_ok.add((tro, trn))

refs_o = dict(l.split()[::-1] for l in git(orig, "for-each-ref", "--format=%(objectname) %(refname)",
                                           "refs/heads", "refs/tags").decode().splitlines())
refs_n = dict(l.split()[::-1] for l in git(new, "for-each-ref", "--format=%(objectname) %(refname)",
                                           "refs/heads", "refs/tags").decode().splitlines())
if set(refs_o) != set(refs_n):
    fail("branch/tag names differ")
for r, s in refs_o.items():
    if refs_n.get(r) != cmap.get(s):
        fail(f"{r}: does not point to the mapped commit")
print(f"refs {len(refs_o)} (heads and tags), all checked")

for cat in (co, cn):
    try:
        cat.close()
    except ScanError as e:
        fail(str(e))
# Residual scan (Codex review: a failed or cut-off reader must not read as "0 objects, 0 occurrences"): every record
# complete, the reader's exit status 0, and the count equal to an independent listing of the same repo.
resid = objs = 0
p = subprocess.Popen(["git", "-C", new, "cat-file", "--batch-all-objects", "--batch"], stdout=subprocess.PIPE)
try:
    while True:
        rec = read_object(p.stdout, "residual scan")
        if rec is None:
            break
        objs += 1
        resid += sum(len(rx.findall(rec[2])) for rx in RESID)
except ScanError as e:
    fail(str(e))
p.stdout.close()
rc = p.wait()
if rc != 0:
    fail(f"residual scan: git cat-file exited {rc}")
listed = subprocess.run(["git", "-C", new, "cat-file", "--batch-all-objects", "--batch-check=%(objectname)"],
                        stdout=subprocess.PIPE)
nlisted = len(listed.stdout.split())
if listed.returncode != 0:
    fail(f"residual scan: object listing exited {listed.returncode}")
elif objs == 0 or objs != nlisted:
    fail(f"residual scan: read {objs} objects, the listing has {nlisted}")
print(f"objects in the new repo {objs}; target occurrences left (any case, ':', '-' or no separator): {resid}")
if resid:
    fail("targets remain in the new repo")
print(f"commits changed {changed_commits}; distinct files changed {changed_blobs}; commit signatures dropped "
      f"{sig_dropped} (fast-export cannot carry them; a rewritten commit's signature would not verify anyway)")
fd = os.open(map_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
with os.fdopen(fd, "w") as f:
    f.write("".join(f"{o} {n}\n" for o, n in sorted(cmap.items()) if o != n))
if fails:
    print(f"VERIFY: FAIL ({len(fails)} problems)"); sys.exit(1)
print("VERIFY: PASS")
