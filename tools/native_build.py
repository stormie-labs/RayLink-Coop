"""The build and run step of tools/build_tests.cmd: compiles coop_tests.exe incrementally and runs it.

    python -I tools/native_build.py --root <repo> --out <dir> [test-name-substring ...]

build_tests.cmd calls it after vcvars64.bat, so cl and link come from PATH. Four groups of sources, each compiled with one
cl call (/MP6: the machine runs several agents' builds at once, so one build takes at most six cores):
  enet   the vendored ENet C sources                      -> <out>/obj_enet
  coop   the xrCoop sources the tests link                -> <out>/obj
  pch    test_util.h precompiled (every test includes it) -> <out>/obj/test_util.pch
  tests  tests/test_*.cpp over that header (/Yu, /FI)     -> <out>/obj
A source is compiled again when its object is missing, its group's flags differ, or any input's size or modification
time in nanoseconds differs. The inputs are the source, the headers cl /sourceDependencies reports in
<out>/<group dir>/deps/<source>.json and the test_util.pch a test reads. <group>.built.json records each object's
flags and input stamps. An input that changes during compilation leaves the object due for another compile.
Objects of sources that are gone are deleted, and the exe is linked from the current objects only.
One run at a time per <out>: <out>/build.lock is held (an OS file lock, released when the process ends) from the first
compile to the end of the test run; a second run on the same folder waits for it. Different COOP_TEST_OUT folders share
nothing.
Exit code: the failing cl or link exit code, else coop_tests.exe's."""
import argparse
import hashlib
import json
import msvcrt
import os
import pathlib
import subprocess
import sys
import time
from dataclasses import dataclass, field

JOBS = "/MP6"
LOCK_WAIT_S = 1800  # a build plus a test run of another process on the same folder takes a few minutes
ENET_SOURCES = ("callbacks.c", "compress.c", "host.c", "list.c", "packet.c", "peer.c", "protocol.c", "win32.c")
COOP_SOURCES = ("coop_wire.cpp", "coop_protocol.cpp", "coop_transport.cpp", "coop_session.cpp")
PCH_HEADER = "test_util.h"
PCH_SOURCE = f'#include "{PCH_HEADER}"\n'
LIBS = ("ws2_32.lib", "winmm.lib", "bcrypt.lib")
DEFINES = ("/DNDEBUG", "/DWIN32", "/D_WINDOWS", "/D_CRT_SECURE_NO_WARNINGS", "/D_WINSOCK_DEPRECATED_NO_WARNINGS")
InputStamps = dict[str, list[int] | None]


def say(text: str) -> None:
    print(f"[build_tests] {text}", flush=True)


@dataclass
class Group:
    name: str
    folder: pathlib.Path
    flags: list[str]
    sources: list[pathlib.Path]
    parallel: bool = True
    extra: list[pathlib.Path] = field(default_factory=list)  # outputs besides the objects (the .pch)

    @property
    def deps(self) -> pathlib.Path:
        return self.folder / "deps"

    @property
    def record(self) -> pathlib.Path:
        return self.folder / f"{self.name}.built.json"

    def obj(self, source: pathlib.Path) -> pathlib.Path:
        return self.folder / (source.stem + ".obj")

    def flags_id(self) -> str:
        # the compiler version is part of the flags: a new toolset compiles everything again
        text = "\n".join(self.flags + [os.environ.get("VCToolsVersion", "")])
        return hashlib.sha1(text.encode("utf-8")).hexdigest()[:16]


def groups(root: pathlib.Path, out: pathlib.Path) -> list[Group]:
    src = root / "engine" / "src"
    coop, enet, tests = src / "xrCoop", src / "3rd party" / "enet", root / "tests"
    obj = out / "obj"
    pch = obj / "test_util.pch"
    cpp = ["/nologo", "/c", "/std:c++17", "/EHsc", "/MD", "/O2", "/W4", "/utf-8", *DEFINES,
           f"/I{coop}", f"/I{enet / 'include'}", f"/I{tests}"]
    # ENet is upstream C code: its warnings are not ours to fix
    enet_flags = ["/nologo", "/c", "/O2", "/MD", "/W3", *DEFINES, "/wd4005", "/wd4244", "/wd4267", "/wd4018",
                  "/wd4146", "/wd4996", "/wd5287", f"/I{enet / 'include'}"]
    return [
        Group("enet", out / "obj_enet", enet_flags, [enet / name for name in ENET_SOURCES]),
        Group("coop", obj, cpp, [coop / name for name in COOP_SOURCES]),
        Group("pch", obj, cpp + [f"/Yc{PCH_HEADER}", f"/Fp{pch}"], [obj / "pch_test_util.cpp"], parallel=False,
              extra=[pch]),
        # /FI puts the header first in every test, so a test whose first include is another header still compiles
        Group("tests", obj, cpp + [f"/Yu{PCH_HEADER}", f"/FI{PCH_HEADER}", f"/Fp{pch}"],
              sorted(tests.glob("test_*.cpp"))),
    ]


def input_stamp(path: pathlib.Path, cache: InputStamps) -> list[int] | None:
    key = str(path).lower()
    if key not in cache:
        try:
            info = path.stat()
            cache[key] = [info.st_size, info.st_mtime_ns]
        except OSError:
            cache[key] = None
    return cache[key]


def load(path: pathlib.Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save(path: pathlib.Path, data: dict) -> None:
    part = path.with_suffix(".tmp")
    part.write_text(json.dumps(data, indent=0, sort_keys=True), encoding="utf-8")
    os.replace(part, path)


def quoted(arg: str) -> str:
    """One argument of a cl/link response file: quoted when it has a space; a backslash before the closing quote is
    doubled, or it would escape the quote."""
    if " " not in arg:
        return arg
    return '"' + (arg + "\\" if arg.endswith("\\") else arg) + '"'


def input_stamps(group: Group, source: pathlib.Path, cache: InputStamps) -> InputStamps | None:
    made = load(group.deps / (source.name + ".json")).get("Data")
    if not made:
        return None
    inputs = [source, *map(pathlib.Path, made.get("Includes", []))]
    if made.get("PCH"):
        inputs.append(pathlib.Path(made["PCH"]))
    return {str(path).lower(): input_stamp(path, cache) for path in inputs}


def stale(group: Group, built: dict, cache: InputStamps) -> list[pathlib.Path]:
    """The sources of the group whose objects must be compiled again."""
    flags = group.flags_id()
    todo = []
    for source in group.sources:
        obj = group.obj(source)
        entry = built.get(obj.name)
        if not entry or entry.get("flags") != flags or not obj.is_file() or any(
                not out.is_file() for out in group.extra):
            todo.append(source)
            continue
        inputs = input_stamps(group, source, cache)
        if inputs is None or None in inputs.values() or inputs != entry.get("inputs"):
            todo.append(source)
    return todo


def compile_group(group: Group, cache: InputStamps) -> int:
    group.folder.mkdir(parents=True, exist_ok=True)
    group.deps.mkdir(exist_ok=True)
    built = load(group.record)
    names = {group.obj(source).name for source in group.sources}
    for name in [name for name in built if name not in names]:  # the source is gone: so is its object
        (group.folder / name).unlink(missing_ok=True)
        del built[name]
    todo = stale(group, built, cache)
    if not todo:
        save(group.record, built)
        return 0
    say(f"{group.name}: compiling {len(todo)} of {len(group.sources)} source(s)")
    for source in todo:
        built.pop(group.obj(source).name, None)
    save(group.record, built)
    rsp = group.folder / f"{group.name}.rsp"
    args = group.flags + ([JOBS] if group.parallel and len(todo) > 1 else []) + [
        f"/Fo{group.folder}\\"] + [str(s) for s in todo]
    # an option and its value stay on one line of a response file
    lines = [*map(quoted, args), "/sourceDependencies " + quoted(str(group.deps))]
    rsp.write_text("\n".join(lines), encoding="utf-8")
    before: InputStamps = {}
    for source in todo:
        if input_stamps(group, source, before) is None:
            input_stamp(source, before)
    start = time.time_ns()
    rc = subprocess.run(["cl", f"@{rsp}"], cwd=group.folder).returncode
    cache.clear()  # cl can replace test_util.pch, which every test reads
    flags = group.flags_id()
    for source in todo:
        obj = group.obj(source)
        try:
            fresh = obj.stat().st_mtime_ns >= start and (group.deps / (source.name + ".json")).stat().st_mtime_ns >= start
        except OSError:
            fresh = False
        inputs = input_stamps(group, source, cache) if fresh else None
        if inputs is None:
            continue
        observed = time.time_ns()
        # cl names newly discovered headers only after compilation, so their write times cover that interval.
        if any(stamp is None or (stamp != before[path] if path in before else start <= stamp[1] <= observed)
               for path, stamp in inputs.items()):
            continue
        built[obj.name] = {"flags": flags, "inputs": inputs}
    save(group.record, built)
    return rc


def hold(lock: pathlib.Path):
    lock.parent.mkdir(parents=True, exist_ok=True)
    handle = open(lock, "a+b")
    waited = 0
    while True:
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            return handle
        except OSError:
            if waited == 0:
                say(f"another run is using {lock.parent}: waiting for it (COOP_TEST_OUT=<dir> runs apart)")
            if waited >= LOCK_WAIT_S:
                say(f"{lock.parent} is still in use after {LOCK_WAIT_S} s: no build")
                sys.exit(2)
            time.sleep(1)
            waited += 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("filters", nargs="*", help="test-name substrings passed to coop_tests.exe")
    args = ap.parse_args()
    root, out = pathlib.Path(args.root).resolve(), pathlib.Path(args.out).resolve()
    lock = hold(out / "build.lock")
    exe = out / "coop_tests.exe"
    exe.unlink(missing_ok=True)  # a failed build leaves no exe of an older one
    all_groups = groups(root, out)
    pch_source = out / "obj" / "pch_test_util.cpp"
    pch_source.parent.mkdir(parents=True, exist_ok=True)
    if not pch_source.is_file() or pch_source.read_text(encoding="utf-8") != PCH_SOURCE:
        pch_source.write_text(PCH_SOURCE, encoding="utf-8")
    began = time.monotonic()
    cache: InputStamps = {}
    for group in all_groups:
        rc = compile_group(group, cache)
        if rc:
            say(f"{group.name}: compile failed ({rc})")
            return rc
    objs = [str(group.obj(source)) for group in all_groups for source in group.sources]
    rsp = out / "link.rsp"
    rsp.write_text("\n".join(map(quoted, objs)), encoding="utf-8")
    rc = subprocess.run(["link", "/nologo", f"/OUT:{exe}", f"@{rsp}", *LIBS], cwd=out).returncode
    if rc:
        say(f"link failed ({rc})")
        return rc
    say(f"built in {time.monotonic() - began:.1f} s")
    say(f'running "{exe}" {" ".join(args.filters)}'.rstrip())
    rc = subprocess.run([str(exe), *args.filters]).returncode
    lock.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
