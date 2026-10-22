# mac_scope.py <bare repo> <targets> <excludes out> — the rewrite scope: every commit that introduces a target (git log
# -G, any case, ':' or '-') and every descendant of one. Writes the other commits, one "^<id>" per line, for
# fast-export to leave untouched (their ids and signatures stay). Prints counts only.
import collections, subprocess, sys

repo, tfile, out = sys.argv[1:4]
targets = [l.strip() for l in open(tfile) if l.strip()]
rx = "|".join("[:-]".join(t.split(":")) for t in targets)
git = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True, stdout=subprocess.PIPE).stdout.decode()
leak = set(git("log", "--all", "-m", "-i", "-G", rx, "--format=%H").split())
children = collections.defaultdict(list)
allc = []
for line in git("rev-list", "--all", "--parents").splitlines():
    c, *ps = line.split(); allc.append(c)
    for p in ps:
        children[p].append(c)
scope, todo = set(), list(leak)
while todo:
    c = todo.pop()
    if c in scope:
        continue
    scope.add(c); todo.extend(children[c])
with open(out, "w") as f:
    f.write("".join(f"^{c}\n" for c in allc if c not in scope))
print(f"commits introducing a target {len(leak)}; in scope with descendants {len(scope)}; left untouched "
      f"{len(allc) - len(scope)} of {len(allc)}")
