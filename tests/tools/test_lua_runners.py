"""The runners that build against the engine's LuaJIT: tools/test_lua.cmd builds its runner with the stamp
tools/check_gates.py prints (the one the tests.ok gate compares), tools/test_luajit.cmd packs only the LuaJIT objects
it built and the lj_vm.obj check_gates resolves into its library, and the identity API slice links the lua51.lib
check_gates resolves.
They build with MSVC (check_gates.vcvars: VCVARS, else the one vswhere names) and the engine's lua51.lib (LUA51_LIB, else engine-ci's
build): without them a test fails and names the variable.
Run: python -m pytest tests\\tools\\test_lua_runners.py -q
"""
import ntpath
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

import check_gates as gates
from conftest import ROOT

import native_slice
import test_trader_identity_api as identity

RUNLUA = """#include <stdio.h>
#include <string.h>
int main(int argc, char** argv)
{
    for (int i = 1; i < argc; ++i)
        if (!strcmp(argv[i], "-stamp"))
            printf("%s\\n", RUNLUA_STAMP);
    return 0;
}
"""


def cmd_env(**extra: str) -> dict[str, str]:
    """The environment of a runner started from a test: this Python first on PATH, no LJ_VM_OBJ of the caller."""
    env = dict(os.environ, PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ.get("PATH", ""))
    env.pop("LJ_VM_OBJ", None)
    env.update(extra)
    return env


def archive_members(lib: Path) -> list[str]:
    """The file names of the objects a COFF archive (.lib) holds, without the linker members and the name table."""
    data = lib.read_bytes()
    assert data[:8] == b"!<arch>\n", lib
    names: list[str] = []
    long_names = b""
    pos = 8
    while pos + 60 <= len(data):
        header = data[pos:pos + 60]
        name = header[:16].decode("ascii").rstrip()
        size = int(header[48:58])
        body = data[pos + 60:pos + 60 + size]
        if name == "//":
            long_names = body
        elif name != "/":
            if name.startswith("/"):
                start = int(name[1:])
                name = long_names[start:long_names.index(b"\0", start)].decode("utf-8")
            names.append(ntpath.basename(name.rstrip("/")))
        pos += 60 + size + (size & 1)
    return names


def fake_lua_tree(root: Path, check_gates_text: str) -> None:
    """A repository of one fake runner source and one coop header, with test_lua.cmd and the given check_gates.py."""
    (root / "tools").mkdir(parents=True)
    for name in ("test_lua.cmd", "check_layers.py"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    (root / "tools" / "check_gates.py").write_text(check_gates_text, encoding="utf-8", newline="\n")
    files = {
        "tests/lua/runlua.c": RUNLUA,
        "tests/lua/native_coop.cpp": "#include \"coop_fake.h\"\nint native_coop_fake() { return coop_fake(); }\n",
        "tests/lua/run_all.lua": "-- the fake runner reads no script\n",
        "engine/src/xrCoop/coop_fake.h": "#pragma once\ninline int coop_fake() { return 1; }\n",
    }
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text, encoding="utf-8", newline="\n")


def run_test_lua(root: Path, **env: str) -> str:
    """Runs the tree's test_lua.cmd (layer check off) and returns the stamp its runner says."""
    done = subprocess.run(["cmd", "/d", "/c", str(root / "tools" / "test_lua.cmd")], cwd=root, capture_output=True,
                          text=True, errors="replace", timeout=600, env=cmd_env(COOP_SKIP_LAYERS="1", **env))
    assert done.returncode == 0, done.stdout + done.stderr
    exe = root.joinpath(*gates.LUA_RUNNER)
    return subprocess.run([str(exe), "-stamp"], capture_output=True, text=True, timeout=30).stdout.strip()


def test_lua_cmd_builds_the_runner_with_the_stamp_check_gates_wants(work, monkeypatch):
    lib = gates.lua51_lib(ROOT)
    assert lib.is_file(), f"the engine's lua51.lib is required (LUA51_LIB): {lib}"
    root = work / "mod"
    fake_lua_tree(root, (ROOT / "tools" / "check_gates.py").read_text(encoding="utf-8"))
    said = run_test_lua(root, LUA51_LIB=str(lib))
    monkeypatch.setenv("LUA51_LIB", str(lib))
    assert said == gates.lua_stamp(root), f"the runner says {said}, check_gates wants {gates.lua_stamp(root)}"
    assert gates.lua_runner_stale(root) is None


def test_lua_cmd_takes_the_stamp_and_the_lib_from_check_gates(work):
    # check_gates of this tree answers a stamp and a lib no other computation gives: LUA51_LIB names no file and the stamp
    # is planted. A runner built at all, saying the planted stamp, took both from check_gates --lua-stamp.
    lib = gates.lua51_lib(ROOT)
    assert lib.is_file(), f"the engine's lua51.lib is required (LUA51_LIB): {lib}"
    text = (ROOT / "tools" / "check_gates.py").read_text(encoding="utf-8")
    main_guard = '\nif __name__ == "__main__":'
    assert text.count(main_guard) == 1
    planted = (f"\n\ndef lua51_lib(root):\n    return pathlib.Path({str(lib)!r})\n\n\n"
               "def lua_stamp(root):\n    return \"planted0\"\n\n")
    root = work / "mod"
    fake_lua_tree(root, text.replace(main_guard, planted + main_guard))
    said = run_test_lua(root, LUA51_LIB=str(work / "no_such_lua51.lib"))
    assert said == "planted0", f"the runner says {said}: test_lua.cmd did not build with check_gates' stamp"


def test_luajit_cmd_packs_only_the_luajit_objects(work):
    # a LuaJIT of three sources and an empty lj_vm.obj (an x64 COFF header without sections): what the runner packs
    # into lua51_test.lib, not what LuaJIT does. This tree has no engine-ci: check_gates --lj-vm names engine's lj_vm.obj.
    root = work / "mod"
    (root / "tools").mkdir(parents=True)
    for name in ("test_luajit.cmd", "check_gates.py", "check_layers.py"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    lj = root / "engine" / "src" / "3rd party" / "luajit-2" / "src"
    files = {
        lj / "lj_one.c": "int lj_one(void) { return 1; }\n",
        lj / "lib_two.c": "int lib_two(void) { return 2; }\n",
        lj / "xr_alloc.c": "int xr_alloc_three(void) { return 3; }\n",
        lj / "lj_bcdef.h": "/* generated */\n",
        root / "tests" / "luajit" / "test_pack.c":
            "int lj_one(void);\nint lib_two(void);\nint xr_alloc_three(void);\n"
            "int main(void) { return lj_one() + lib_two() + xr_alloc_three() == 6 ? 0 : 1; }\n",
    }
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="ascii", newline="\n")
    empty_object = struct.pack("<HHIIIHH", 0x8664, 0, 0, 0, 0, 0, 0)
    (lj / "lj_vm.obj").write_bytes(empty_object)
    # build_tests.cmd keeps its objects in <COOP_TEST_OUT>\obj; a parallel agent sets COOP_TEST_OUT for both runners
    out = work / "out"
    (out / "obj").mkdir(parents=True)
    (out / "obj" / "test_planted.obj").write_bytes(b"an object of build_tests.cmd, not of LuaJIT")
    # an object the runner did not build, left in its own folder (an older LuaJIT's source, another run): a valid object,
    # so only the runner's list of what it built keeps it out of the library
    (out / "luajit_obj").mkdir()
    (out / "luajit_obj" / "lj_stray.obj").write_bytes(empty_object)
    done = subprocess.run(["cmd", "/d", "/c", str(root / "tools" / "test_luajit.cmd")], capture_output=True, text=True,
                          errors="replace", timeout=600, env=cmd_env(COOP_TEST_OUT=str(out)))
    assert done.returncode == 0 and "test_pack: PASS" in done.stdout, done.stdout + done.stderr
    packed = sorted(archive_members(out / "lua51_test.lib"))
    assert packed == ["lib_two.obj", "lj_one.obj", "lj_vm.obj", "xr_alloc.obj"], f"lua51_test.lib packs {packed}"


def test_luajit_cmd_stops_and_names_a_missing_lj_vm_obj(work, monkeypatch):
    monkeypatch.delenv("LJ_VM_OBJ", raising=False)
    root = work / "mod"
    (root / "tools").mkdir(parents=True)
    for name in ("test_luajit.cmd", "check_gates.py", "check_layers.py"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    done = subprocess.run(["cmd", "/d", "/c", str(root / "tools" / "test_luajit.cmd")], capture_output=True, text=True,
                          errors="replace", timeout=120, env=cmd_env(COOP_TEST_OUT=str(work / "out")))
    assert done.returncode == 2, done.stdout + done.stderr
    assert f'lj_vm.obj not found: "{gates.lj_vm_obj(root)}"' in done.stdout and "LJ_VM_OBJ" in done.stdout, done.stdout


def test_identity_api_slice_links_the_lib_check_gates_resolves(work, monkeypatch):
    # the slice's build step, recorded instead of run: it must link the one lua51.lib check_gates resolves
    monkeypatch.delenv("LUA51_LIB", raising=False)
    lib = gates.lua51_lib(ROOT)
    assert lib.is_file(), f"the engine's lua51.lib is required (LUA51_LIB): {lib}"
    builds: list[list[Path]] = []

    def record(build_work, command, sources, exe, includes=(), libs=()):
        builds.append(list(libs))
        raise StopIteration  # the slice stops here: nothing is compiled or run

    monkeypatch.setattr(identity, "build", record)
    try:
        identity.test_registered_player_digest_uses_existing_identity_and_access_rules(work)
    except StopIteration:
        pass
    assert builds == [[lib]], builds


def test_msvc_env_is_read_from_the_vcvars_check_gates_resolves(work, monkeypatch):
    # every engine slice builds in the environment of the caller's vcvars64.bat (VCVARS), read once per process
    vcvars = work / "vcvars64.bat"
    vcvars.write_text("@set VCToolsInstallDir=planted\n@set P1_PLANTED=yes\n", encoding="ascii")
    monkeypatch.setenv("VCVARS", str(vcvars))
    assert gates.vcvars() == vcvars
    env = native_slice.msvc_env.__wrapped__()
    assert env.get("P1_PLANTED") == "yes" and env.get("VCToolsInstallDir") == "planted", env