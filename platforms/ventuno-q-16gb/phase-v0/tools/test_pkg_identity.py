#!/usr/bin/env python3
"""offline tests for pkg_identity.py (D176): a small fake package (files, relative symlink chains, an absolute link to an
external file) and its build record; each case changes one thing and checks the verdict and the message."""
import contextlib, hashlib, io, os, shutil, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pkg_identity as pi

fails = 0
def ok(name, cond, text=""):
    global fails
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails += 1; print(text)


def build(t):
    """<t>/pkg with bin/llama-server, lib/libllama.so.0.5.0 (+ .so.0 -> .so.0.5.0, .so -> .so.0), lib/libggml-htp-v75.so,
    lib/libcdsprpc.so -> <t>/sys/libcdsprpc.so.1 -> libcdsprpc.so.1.0.0; the build record of the regular files"""
    p = f"{t}/pkg"; os.makedirs(f"{p}/bin"); os.makedirs(f"{p}/lib"); os.makedirs(f"{t}/sys")
    for rel, data in [("bin/llama-server", b"launcher"), ("lib/libllama.so.0.5.0", b"llama"), ("lib/libggml-htp-v75.so", b"htp")]:
        open(f"{p}/{rel}", "wb").write(data)
    os.symlink("libllama.so.0.5.0", f"{p}/lib/libllama.so.0"); os.symlink("libllama.so.0", f"{p}/lib/libllama.so")
    open(f"{t}/sys/libcdsprpc.so.1.0.0", "wb").write(b"fastrpc"); os.symlink("libcdsprpc.so.1.0.0", f"{t}/sys/libcdsprpc.so.1")
    os.symlink(f"{t}/sys/libcdsprpc.so.1", f"{p}/lib/libcdsprpc.so")
    with open(f"{t}/record.sha256", "w") as f:
        for rel in ("bin/llama-server", "lib/libggml-htp-v75.so", "lib/libllama.so.0.5.0"):
            f.write(f"{hashlib.sha256(open(f'{p}/{rel}', 'rb').read()).hexdigest()}  ./{rel}\n")
    return p


def run(*args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = (pi.check if args[0] == "check" else pi.make)(*args[1:])
    return rc, out.getvalue() + err.getvalue()


def case(name, change, want_rc, want_msg):
    t = tempfile.mkdtemp(); p = build(t)
    rc, man = run("make", f"{t}/record.sha256", p)
    open(f"{t}/manifest.txt", "w").write(man)
    change(t, p)
    rc, text = run("check", f"{t}/manifest.txt", p)
    ok(f"{name} (rc {rc})", rc == want_rc and want_msg in text, text)
    shutil.rmtree(t)


def write(path, data):
    open(path, "wb").write(data)


def relink(path, target):
    os.remove(path); os.symlink(target, path)


case("the package as built passes", lambda t, p: None, 0, "RESULT pkg-identity: PASS (3 files, 3 links, 1 external")
case("a modified library fails", lambda t, p: write(f"{p}/lib/libllama.so.0.5.0", b"llama2"), 1,
     "FAIL lib/libllama.so.0.5.0: sha256 differs from the manifest")
case("a missing library fails", lambda t, p: os.remove(f"{p}/lib/libllama.so.0.5.0"), 1, "FAIL lib/libllama.so.0.5.0: missing")
case("a missing symlink fails", lambda t, p: os.remove(f"{p}/lib/libllama.so.0"), 1, "FAIL lib/libllama.so.0: missing, expected a link")
case("a redirected symlink fails (to another pinned file)", lambda t, p: relink(f"{p}/lib/libllama.so.0", "../lib/libggml-htp-v75.so"),
     1, "FAIL lib/libllama.so.0: links to ../lib/libggml-htp-v75.so, expected libllama.so.0.5.0")
def outside(t, p):  # same link text, but the pinned file is now itself a link to an outside copy
    write(f"{t}/evil.so", b"llama"); relink(f"{p}/lib/libllama.so.0.5.0", f"{t}/evil.so")
case("a pinned file replaced by a symlink to an identical outside copy fails", outside, 1,
     "FAIL lib/libllama.so.0.5.0: a symlink")
case("a symlink replaced by a regular copy fails", lambda t, p: (os.remove(f"{p}/lib/libllama.so"), write(f"{p}/lib/libllama.so", b"llama")),
     1, "FAIL lib/libllama.so: not a symlink")
case("an extra library in the package fails (could shadow on LD_LIBRARY_PATH)", lambda t, p: write(f"{p}/lib/libggml-extra.so", b"x"), 1,
     "FAIL lib/libggml-extra.so: not in the manifest")
case("an extra symlink in the package fails", lambda t, p: os.symlink("libllama.so.0", f"{p}/lib/libllama.so.9"), 1,
     "FAIL lib/libllama.so.9: not in the manifest")
case("the external FastRPC library changed fails", lambda t, p: write(f"{t}/sys/libcdsprpc.so.1.0.0", b"fastrpc2"), 1,
     "(external)")
def ext_redirect(t, p):  # the system link now points to another file
    write(f"{t}/sys/libcdsprpc.so.2.0.0", b"fastrpc"); relink(f"{t}/sys/libcdsprpc.so.1", "libcdsprpc.so.2.0.0")
case("the external link chain redirected fails", ext_redirect, 1, "not a pinned external file")
# make refuses an installed package that differs from its build record
t = tempfile.mkdtemp(); p = build(t); write(f"{p}/lib/libggml-htp-v75.so", b"htp2")
rc, text = run("make", f"{t}/record.sha256", p)
ok("make refuses a package that differs from its build record", rc == 1 and "installed file differs from the build record" in text, text)
write(f"{p}/lib/libggml-htp-v75.so", b"htp"); write(f"{p}/lib/new.so", b"n")
rc, text = run("make", f"{t}/record.sha256", p)
ok("make refuses a file not in the build record", rc == 1 and "lib/new.so: installed but not in the build record" in text, text)
shutil.rmtree(t)
print(f"failures: {fails}"); sys.exit(fails)
