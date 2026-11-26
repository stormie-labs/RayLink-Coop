"""Engine slices: the shared helpers of the tests that cut engine functions out of engine/src and build them with MSVC
over stubs (tests/tools/test_*.py and the scripts tests/test_*.py, which run without pytest, so nothing here imports it).

  definition(where, signature)   the text from `signature` through its matching closing brace
  declaration(where, signature)  the text from `signature` through the first ';' (a constant, a variable)
  block(source, head, indent)    a definition laid out from column `indent`: its first line starts with `head`, it ends
                                 at the line that is only the closing brace at that column (plus a ';' after it)
  scratch(name)                  a fresh folder for one build, removed afterwards
  build(work, command, sources, exe, includes, libs)
                                 runs `command` (a "cl /nologo ..." line, the flags of this slice) on the sources with the
                                 MSVC environment of vcvars64.bat, which is read once per process (msvc_env)
`where` is the source text, a file, or a folder: a folder is searched (every .cpp and .h under it) for the one file that
holds the signature, so a function that moves to another file of the folder is still found."""
import contextlib
import functools
import os
import re
import shutil
import stat
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Iterable, Iterator, Union

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import check_gates  # noqa: E402  (the one resolver of vcvars64.bat)

# what a brace inside does not count for: comments, string and character literals
TOKENS = re.compile(r"""//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|[{}]""", re.S)
Where = Union[str, Path]


@functools.cache
def _text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def _source(where: Where, signature: str) -> str:
    if isinstance(where, str):
        return where
    if where.is_file():
        return _text(where)
    holders = [p for p in sorted(where.rglob("*")) if p.suffix in (".cpp", ".h") and signature in _text(p)]
    assert len(holders) == 1, f"{signature!r}: {len(holders)} file(s) under {where} hold it {[str(p) for p in holders]}"
    return _text(holders[0])


def definition(where: Where, signature: str) -> str:
    source = _source(where, signature)
    start = source.index(signature)
    depth = 0
    for match in TOKENS.finditer(source, start):
        if match.group() == "{":
            depth += 1
        elif match.group() == "}":
            depth -= 1
            if depth == 0:
                return source[start:match.end()]
    raise ValueError(f"unclosed definition {signature}")


def declaration(where: Where, signature: str) -> str:
    source = _source(where, signature)
    start = source.index(signature)
    return source[start:source.index(";", start) + 1]


def block(source: str, head: str, indent: str = "") -> str:
    # the first line that starts with the head and opens a definition: a declaration of the same name is passed over
    for match in re.finditer("^" + re.escape(indent + head), source, re.M):
        start = match.start()
        first_end = source.find("\n", start)
        if first_end < 0:
            break
        if source[first_end - 1] == "}":
            return source[start:first_end]
        if source.startswith(f"\n{indent}{{", first_end):
            end = source.index(f"\n{indent}}}", first_end) + len(indent) + 2
            return source[start:end + 1 if source[end:end + 1] == ";" else end]
    raise AssertionError(f"no definition laid out from column {len(indent)}: {head}")


def _force(func, path, _exc):
    os.chmod(path, stat.S_IWRITE | stat.S_IREAD)  # read-only files a test made
    func(path)


@contextlib.contextmanager
def scratch(name: str = "slice") -> Iterator[Path]:
    """A fresh folder under the project's temp\\ (the same volume as the repository), one per call, so parallel runs
    never share one; it is removed when the block ends."""
    path = ROOT / "temp" / "pytest_tools" / f"{name}-{uuid.uuid4().hex[:8]}"
    path.mkdir(parents=True)
    try:
        yield path
    finally:
        shutil.rmtree(path, onexc=_force)


@functools.cache
def msvc_env() -> dict[str, str]:
    """The environment vcvars64.bat sets up (cl, link, INCLUDE, LIB), read once per process: a call costs seconds."""
    vcvars = check_gates.vcvars()
    assert vcvars and vcvars.is_file(), f"vcvars64.bat not found ({vcvars}): install the MSVC x64 tools or set VCVARS"
    done = subprocess.run(f'cmd /d /c "call "{vcvars}" >nul && set"', capture_output=True, text=True, errors="replace",
                          stdin=subprocess.DEVNULL, timeout=600)
    env = dict(line.split("=", 1) for line in done.stdout.splitlines() if "=" in line and not line.startswith("="))
    assert done.returncode == 0 and "VCToolsInstallDir" in env, f"vcvars64.bat failed: {done.stdout}{done.stderr}"
    return env


def build(work: Path, command: str, sources: Iterable[Path], exe: Path, includes: Iterable[Path] = (),
          libs: Iterable[Path] = ()) -> Path:
    env = msvc_env()
    words = command.split()
    cl = shutil.which(words[0], path=env["PATH"])
    assert cl, f"{words[0]} is not on the vcvars64.bat PATH"
    args = [cl, *words[1:], *(f"/I{p}" for p in includes), *map(str, sources), *map(str, libs), f"/Fe{exe}"]
    done = subprocess.run(args, cwd=work, env=env, capture_output=True, text=True, errors="replace", timeout=300)
    assert done.returncode == 0, done.stdout + done.stderr
    return exe
