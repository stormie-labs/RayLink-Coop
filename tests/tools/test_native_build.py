"""tools/native_build.py, the build step of tools/build_tests.cmd, tested on a repository of tiny sources with real MSVC (check_gates.vcvars)."""
import os
import subprocess
import sys
import time

import native_slice
from conftest import ROOT

FILES = {
    "engine/src/xrCoop/coop_wire.cpp": "int coop_wire() { return 1; }\n",
    "engine/src/xrCoop/coop_protocol.cpp": "int coop_protocol() { return 2; }\n",
    "engine/src/xrCoop/coop_transport.cpp": "int coop_transport() { return 3; }\n",
    "engine/src/xrCoop/coop_session.cpp": "int coop_session() { return 4; }\n",
    "tests/test_util.h": "#pragma once\ninline int util() { return 5; }\n",
    "tests/only_a.h": "#pragma once\ninline int only_a() { return 6; }\n",
    "tests/test_main.cpp": '#include "test_util.h"\nint a(); int b();\nint main() { return a() + b() == 13 ? 0 : 1; }\n',
    "tests/test_a.cpp": '#include "test_util.h"\n#include "only_a.h"\nint a() { return only_a(); }\n',
    "tests/test_b.cpp": '#include "test_util.h"\nint b() { return util() + 2; }\n',
}
ENET = ("callbacks", "compress", "host", "list", "packet", "peer", "protocol", "win32")


def fake_repo(root):
    for rel, text in FILES.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text, encoding="utf-8")
    enet = root / "engine/src/3rd party/enet"
    (enet / "include").mkdir(parents=True)
    for name in ENET:
        (enet / f"{name}.c").write_text(f"int enet_{name}(void) {{ return 0; }}\n", encoding="utf-8")


def build(root, out):
    done = subprocess.run([sys.executable, "-I", str(ROOT / "tools" / "native_build.py"), "--root", str(root),
                           "--out", str(out)], env=native_slice.msvc_env(), capture_output=True, text=True,
                          errors="replace", timeout=600)
    return done.returncode, done.stdout + done.stderr


def compiled(log, group):
    """How many sources of the group this run compiled (0 when it compiled none)."""
    for line in log.splitlines():
        if line.startswith(f"[build_tests] {group}: compiling "):
            return int(line.split()[3])
    return 0


def touch(path):
    time.sleep(0.05)  # a later time than every object of the run before
    os.utime(path)


def test_native_build_compiles_what_changed_and_links_what_there_is(work):
    root, out = work / "repo", work / "out"
    fake_repo(root)
    rc, log = build(root, out)
    assert rc == 0, log
    assert [compiled(log, g) for g in ("enet", "coop", "pch", "tests")] == [8, 4, 1, 3], log
    rc, log = build(root, out)  # nothing changed: nothing compiled, the exe linked and run again
    assert rc == 0 and [compiled(log, g) for g in ("enet", "coop", "pch", "tests")] == [0, 0, 0, 0], log
    touch(root / "tests/only_a.h")  # a header of one test: that test only
    rc, log = build(root, out)
    assert rc == 0 and compiled(log, "tests") == 1 and compiled(log, "pch") == 0, log
    touch(root / "tests/test_util.h")  # the precompiled header: it and every test
    rc, log = build(root, out)
    assert rc == 0 and compiled(log, "pch") == 1 and compiled(log, "tests") == 3, log
    # a test that is gone: its object goes too, and the exe is linked without it (b() is missing: the link fails)
    (root / "tests/test_b.cpp").unlink()
    rc, log = build(root, out)
    assert rc != 0 and not (out / "obj" / "test_b.obj").exists() and "link failed" in log, log
    assert not (out / "coop_tests.exe").exists(), "a failed build leaves no exe of an older one"


def test_native_build_compiles_a_replaced_header(work):
    root, out = work / "repo", work / "out"
    fake_repo(root)
    groups = ("enet", "coop", "pch", "tests")
    rc, log = build(root, out)
    assert rc == 0 and [compiled(log, g) for g in groups] == [8, 4, 1, 3], log

    header = root / "tests/only_a.h"
    original = header.stat()
    header.write_bytes(header.read_bytes().replace(b"return 6;", b"return+6;"))
    os.utime(header, ns=(original.st_atime_ns, original.st_mtime_ns - 2_000_000_000))
    older = header.stat()
    assert older.st_mtime_ns < original.st_mtime_ns and older.st_size == original.st_size
    rc, log = build(root, out)
    assert rc == 0 and [compiled(log, g) for g in groups] == [0, 0, 0, 1], log

    header.write_bytes(header.read_bytes() + b"// single-test header\n")
    os.utime(header, ns=(older.st_atime_ns, older.st_mtime_ns))
    replaced = header.stat()
    assert replaced.st_mtime_ns == older.st_mtime_ns and replaced.st_size != older.st_size
    rc, log = build(root, out)
    assert rc == 0 and [compiled(log, g) for g in groups] == [0, 0, 0, 1], log

    rc, log = build(root, out)
    assert rc == 0 and [compiled(log, g) for g in groups] == [0, 0, 0, 0], log
