"""Gate: which layers a change touches and which stand runs it needs before it ships (docs/MODES.md sections 3 and 10).

  python -I tools/check_gates.py [RANGE] [--engine-range RANGE] [--per-commit] [--release] [--layers]
                                 [--root DIR] [--marks DIR] [--exe PATH] [--stand DIR] [--ci DIR]
  python -I tools/check_gates.py --exe-source [--exe PATH] [--ci DIR]
  python -I tools/check_gates.py --tests-mark begin | write --state FILE --native N --lua N
  python -I tools/check_gates.py --lua-stamp [--root DIR]

RANGE is a git range of this repository (`dev-57..HEAD`), --engine-range one of engine/ (its own repository; the
default is RANGE: release tags exist in both repositories; when the engine does not know them, pass --engine-range).
Without RANGE: the working tree against HEAD in both repositories (staged, unstaged and untracked files).
Renames count with both paths (git --no-renames): moving an Ядро file to a srv name is an Ядро change. A merge commit
counts with its diff against its first parent (git --diff-merges=first-parent): an edit made while merging is seen;
the side branch's own commits are in the range too. Every git call runs with core.quotePath=false (a non-ASCII path
comes raw); a quoted path is a GateError (exit 2), never "outside the product". No git call writes an index
(GIT_OPTIONAL_LOCKS=0).

THE RELEASE RULE (the third review: classification has holes, a release must not depend on it). In range mode (a RANGE
without --per-commit; tools/release.py verify) any change of a product file needs BOTH stand marks and the tests mark,
whatever the files' layers: hostplay.ok, srv.ok and tests.ok. With --release (tools/release.py) the exe ships, so the
three marks are needed even when no product file changed, and the exe itself must be engine-ci's build of engine HEAD
(exe_source below). The per-file layers below decide only the early warning: the working tree and --per-commit (a range
judged commit by commit, as a developer checks his own commits).

Layer of a changed file (tools/layers.txt through tools/check_layers.py), with these files counted as Ядро (core)
whatever their row says:
  - the lists and the tools that decide layers and gates: tools/layers.txt, layers_allow.txt, srv_entry.txt,
    persisted_keys.txt, stock_files.txt, check_layers.py, check_gates.py, release.py, stand_common.ps1,
    stand_hostplay.ps1, stand_srv.ps1 (a one-line list edit could otherwise turn an Ядро file into srv); the runners of
    the co-op tests tools/test_lua.cmd, tools/build_tests.cmd, tools/run_all_tests.cmd, tests/lua/run_all.lua; the
    stand's scenarios and probes (everything under tools/stand/, and tools/ded_check.ps1);
  - the facade gamedata/scripts/coop_mode.script and its two layers coop_srv_mode.script and coop_hostplay_mode.script:
    they decide in which process the when_srv code runs (review 3, C5);
  - a file with entries in tools/layers_allow.txt (critique H9: an edit under an allowed line is an Ядро edit);
  - a stock engine file (rule 8) and a hybrid file of the `dying` layer (removing it changes co-op);
  - xrCoop/coop_protocol.h (one protocol for both modes);
  - a route table gamedata/configs/coop_route*.ltx, unless both versions hold the same (section, key) pairs and every
    changed value only turns `host` into `level` or back (both run on the co-op host: then srv); a key moved to another
    section, added or removed is Ядро (critique H6, review 3 C10: the table is read as data, not as diff lines);
  - a `gate-core` row of layers.txt (the 9 server scripts until step S4, critique H4);
  - the file that defines a function of tools/srv_entry.txt (critique H5);
  - a srv or hostplay file that Ядро, stock (also the stock-patch scripts of engine/gamedata/scripts and
    gamedata_gamma/scripts) or dying code reaches (tools/check_layers.core_reach, on the working tree): included by it
    (transitively: its code is compiled into Ядро), defining a function it calls (`ns::f`, `Class::f`, a bare call in
    its namespaces; an overload of an Ядро function counts too), a script it names (Lua, also a plain string of a
    dispatch table; a C++ string like lua_getglobal(L, "coop_dedicated"); a config's `coop_x.fn`), defining a global
    it declares `extern`, defining a member (function or static data) of a class only it defines or of a class declared
    in a reached file, or holding a static initializer that calls a function or a constructor (that runs in every
    process). Then, to a fixed point, whatever such a reached file (or a gate-core / srv_entry file) includes, calls or
    names is reached too. That code runs in both modes, so an edit of it is an Ядро edit until the reference goes
    through mode() (step S4).
Paths outside the product (docs/, tests/, temp/, the other tools/, *.md, engine/README.md, engine/.github, ...) need no
gate: the product is gamedata/, gamedata_gamma/, engine/src/ and engine/gamedata/.

Early warning (working tree, --per-commit): Ядро -> both stand marks; srv -> the server stand mark, an unchanged SET of
co-op tests (the names of the native TEST( in tests/*.cpp and the Lua files tests/lua/test_*.lua, both without
test_srv_*) and no edit of any other file under tests/ or of the test runners (only test_srv_* files may come with a
srv-only change); hostplay -> the co-op stand mark. One commit that touches hostplay and srv without Ядро is refused:
split it (a merge is exempt: its side commits are checked one by one).

The marks, in temp/gates/ (--marks): hostplay.ok and srv.ok, written by tools/stand_hostplay.ps1 and tools/stand_srv.ps1
on success:
  mode=hostplay|srv  mod_head=<id>  engine_head=<id>  exe=<path>  exe_sha256=<hex>  time=<ISO time>  scenarios=<names>
  dirty=<uncommitted product files, tracked or not, when the stand ran>
  scenarios_sha256=<the scenario files that ran>  gamedata_sha256=<the gamedata the runner deployed from HEAD>
  exe_source=<the engine HEAD the stand's exe was shown to be built from, or none>
  stand_fingerprint=<the stand's manifest and the coop scripts a mod ships there>  stand_extra=<leftover files>
  stand_foreign=<coop scripts a GAMMA mod ships>  profile_sha256=<the mode cvars written into the stand's profiles>
A stand mark counts only with its own mode, dirty=0, every scenario of its runner (SCENARIOS below), the same two HEAD
ids (the range's ends), the same exe (--exe, default the stand's exe) at the stand's own path (--stand, default
E:\\RayLinkGames\\GAMMA\\game-dev: a run on another folder does not count), exe_source equal to engine HEAD, stand_extra=0,
stand_fingerprint equal to the stand's now, scenarios_sha256 equal to the digest of HEAD's blobs of SCENARIO_PATHS
(the scenarios, the runners, and check_gates.py / check_layers.py, which the runner imports), gamedata_sha256 equal to
the digest of HEAD's deployable gamedata (gamedata, gamedata_gamma, the engine's gamedata) and profile_sha256 equal to
the digest of HEAD's tools/stand/stand_profile.ltx. tests.ok, written by tools/run_all_tests.cmd when the native tests
(tools/build_tests.cmd, tools/test_luajit.cmd, every engine slice) and tools/test_lua.cmd passed and the Lua runner
holds the stamp of its sources and its lua51.lib now (--lua-stamp), counts with mode=tests, dirty=0 before and after
the run, native=0, lua=0 and the same two HEAD ids. Uncommitted product changes are never covered by a mark (the stand
ran HEAD's build; its runner refuses to start on a dirty tree).

exe_source (C12): the exe is engine-ci's build (byte for byte its _build/_game/bin_dbg/AnomalyDX11AVX.exe) and was built
from engine HEAD: engine/src has no uncommitted file, every file of engine HEAD's src/ is in engine-ci with HEAD's
content (raylink_build.h up to its build number; xrGame.vcxproj(.filters), which tools/ci_sync.py patches, aside), no
source file engine HEAD lacks is left in engine-ci, and no engine-ci source changed after the exe was written. Nothing
is trusted from a stamp: the CI tree is compared with HEAD (git's index of the engine-ci worktree names what is
unchanged; only changed files are read).

Exit 0: every required mark is there. 1: a mark is missing or does not count, a commit is refused, a srv-only change
moved or edited the co-op tests, or (--release) the exe is not engine HEAD's build. 2: git or an input file failed, or
git printed a quoted path. 3 (--layers): tools/check_layers.py failed on the tree (printed first; the gate did not run).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from typing import Callable, Optional, Sequence

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))  # -I leaves the script's folder out
import check_layers  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_STAND = pathlib.Path(r"E:\RayLinkGames\GAMMA\game-dev")
STAND_EXE = ("bin", "AnomalyCoopDX11AVX.exe")
DEFAULT_EXE = DEFAULT_STAND.joinpath(*STAND_EXE)
# engine-ci: the worktree tools/ci_sync.py fills and temp/build_guarded_fast.ps1 builds; the exe MSBuild writes
CI_EXE = ("_build", "_game", "bin_dbg", "AnomalyDX11AVX.exe")
CI_BUILD_HEADER = "src/xrCore/raylink_build.h"  # ci_sync writes the build number into the CI copy
CI_BUILD_DEFINE = re.compile(rb"^#define RAYLINK_BUILD[ \t]+\d+[ \t]*$", re.M)
CI_PATCHED = frozenset({"src/xrgame/xrgame.vcxproj", "src/xrgame/xrgame.vcxproj.filters"})  # ci_sync / vcxproj_add
CI_SOURCE_EXT = (".cpp", ".h", ".hpp", ".inl", ".c", ".rc")
# what the build reads from engine-ci: the sources and the SDK (its headers and libraries; review 4, B4/E4)
CI_TREES = ("src", "sdk")
PROTOCOL = "engine/src/xrCoop/coop_protocol.h"
ROUTE = re.compile(r"^gamedata/configs/coop_route[^/]*\.ltx$", re.I)
# the product: our gamedata layers and the engine's sources and gamedata (an engine README or CI edit needs no stand)
PRODUCT = re.compile(r"^(engine/(?:src|gamedata)/|gamedata/|gamedata_gamma/)", re.I)
MARKS = ("hostplay", "srv")
TESTS = "tests"
# the lists and tools that decide what a change is and what it needs, the runners of the co-op tests (B10) and the
# stand's scenarios (B12): an edit of them is an Ядро change
GATE_FILES = frozenset([f"tools/{name}" for name in (
    "layers.txt", "layers_allow.txt", "srv_entry.txt", "persisted_keys.txt", "stock_files.txt", "check_layers.py",
    "mod_names.txt", "gen_mod_names.py",
    "check_gates.py", "release.py", "stand_common.ps1", "stand_hostplay.ps1", "stand_srv.ps1", "ded_check.ps1",
    "mo2_stand.py", "test_lua.cmd", "build_tests.cmd", "run_all_tests.cmd")] + ["tests/lua/run_all.lua"])
GATE_DIRS = ("tools/stand/",)
# the facade and its two layers: they decide in which process when_srv code runs (review 3, C5)
MODE_FILES = frozenset({"gamedata/scripts/coop_mode.script", "gamedata/scripts/coop_srv_mode.script",
                        "gamedata/scripts/coop_hostplay_mode.script"})
# what a stand mark certifies: the scenario files that ran (tools/stand is tracked; temp/stand keeps the run history),
# the runners, the two checkers the runner imports for the dirty check and the digests (review 3, S3) and the file
# helpers it writes into the stand with (tools/mo2_stand.py: replace_file never writes through a hard link, R21)
SCENARIO_PATHS = ("tools/stand", "tools/stand_common.ps1", "tools/stand_hostplay.ps1", "tools/stand_srv.ps1",
                  "tools/ded_check.ps1", "tools/check_gates.py", "tools/check_layers.py", "tools/mo2_stand.py")
# the mode cvars every stand profile runs with (tools/stand/stand_head.py writes them before each scenario; S2)
PROFILE = "tools/stand/stand_profile.ltx"
# the co-op tests and their runners: a srv-only change may add or edit only test_srv_* files there (B10)
TEST_PATHS = ("tests", "tools/test_lua.cmd", "tools/build_tests.cmd", "tools/run_all_tests.cmd")
# what tests.ok certifies: N and L ran on these, committed (both repositories)
TESTS_DIRTY = (("mod", ("gamedata", "gamedata_gamma") + TEST_PATHS), ("engine", ("src", "gamedata")))
# what tools/stand/stand_head.py deploys to the stand: HEAD's gamedata of the three layers, without the files the game
# writes itself (axr_options.ltx) and without leftovers (as tools/stand_overlay.py)
GAMEDATA_SOURCES = (("mod", "gamedata"), ("mod", "gamedata_gamma"), ("engine", "gamedata"))
DEPLOY_SKIP_NAMES = frozenset({"axr_options.ltx", "cache_dbg.ltx"})
DEPLOY_SKIP_EXT = frozenset({".bak", ".tmp", ".log", ".orig"})
# every scenario of each stand runner (tools/stand_hostplay.ps1, tools/stand_srv.ps1; tests/tools/test_gates.py keeps
# the two in step): a mark of a part of the stand does not count
SCENARIOS = {
    # guard round 8 (the review of round 7, R7): companions_group (F5-CMP-1) and phantoms_server (S3) were in no runner
    "hostplay": ("carry_group", "base_group", "sil_group", "squads_group", "sp_smoke", "companions_group", "cover_group",
                 "vehicle_group", "progress_group"),
    "srv": (
        "ded_check", "base_server", "carry_server", "taskboard_ws", "phantoms_server",
        "allymark_server", "companions_server", "weather_server", "cover_server",
        "ms_crash_server", "save_handover_server", "creator10_server", "feed_server", "vehicle_server", "progress_server",
    ),
}


class GateError(Exception):
    pass


# ---- the layer map (tools/check_layers.py reads the same files) ---------------------------------------------------

def read_layers(path: pathlib.Path) -> check_layers.LayerMap:
    try:
        return check_layers.parse_layers(path.read_text(encoding="utf-8"), path.resolve().parent.parent)
    except check_layers.InputError as error:
        raise GateError(str(error)) from None


def allow_paths(path: pathlib.Path) -> set[str]:
    paths = set()
    if path.is_file():
        for raw in path.read_text(encoding="utf-8").splitlines():
            if raw and not raw.startswith("#") and raw.count("|") >= 3:
                paths.add(raw.split("|", 2)[1].strip().lower())
    return paths


def entry_files(root: pathlib.Path, names: list[str]) -> set[str]:
    """Files under engine/src that define a function of srv_entry.txt (`ns::name` needs that namespace in the file)."""
    found: set[str] = set()
    engine = root / "engine" / "src"
    if not engine.is_dir() or not names:
        return found
    folders = [engine / "xrGame" / "coop", engine / "xrCoop", engine / "xrEngine"]
    for folder in folders:
        if not folder.is_dir():
            continue
        for path in sorted(folder.rglob("*.cpp")) + sorted(folder.rglob("*.h")):
            text = path.read_bytes().decode("utf-8", "replace")
            for name in names:
                ns, _, short_name = name.rpartition("::")
                if ns and not re.search(rf"\bnamespace\s+(?:[\w:]*::)?{re.escape(ns)}\b", text):
                    continue
                # a definition: at the start of a line, a return type, the name, a parameter list, no `;` before `{`
                if re.search(rf"(?m)^[A-Za-z_][\w:<>\s\*&]*\b{re.escape(short_name)}\s*\([^;{{]*\)\s*(?:const\s*)?\{{", text) or \
                        re.search(rf"(?m)^[A-Za-z_][\w:<>\s\*&]*\b{re.escape(short_name)}\s*\([^;{{]*\)\s*(?:const\s*)?\n\s*\{{", text):
                    found.add(path.relative_to(root).as_posix().lower())
    return found


# ---- git ----------------------------------------------------------------------------------------------------------

GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0")  # git status / diff never write a refreshed index


def git(repo: pathlib.Path, *args: str) -> str:
    # core.quotePath=false: a non-ASCII path comes as it is, not as "gamedata/\320\277..." that matches no row (B11)
    done = subprocess.run(["git", "-C", str(repo), "-c", "core.quotePath=false", *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", env=GIT_ENV)
    if done.returncode != 0:
        raise GateError(f"git {' '.join(args)} in {repo}: {done.stderr.strip()[:300]}")
    return done.stdout


def git_show(repo: pathlib.Path, spec: str) -> str:
    """The text of `git show <rev>:<path>`, "" when that file does not exist there."""
    done = subprocess.run(["git", "-C", str(repo), "-c", "core.quotePath=false", "show", spec], capture_output=True,
                          env=GIT_ENV)
    return done.stdout.decode("utf-8", "replace") if done.returncode == 0 else ""


def tree_blobs(repo: pathlib.Path, ref: str, paths: Sequence[str], prefix: str = "") -> list[tuple[str, str]]:
    """(path, blob id) of every file under paths at ref (git ls-tree -r -z: raw paths)."""
    out = []
    for item in git(repo, "ls-tree", "-r", "-z", ref, "--", *paths).split("\0"):
        meta, _, path = item.partition("\t")
        parts = meta.split()
        if len(parts) == 3 and parts[1] == "blob":
            out.append((prefix + path, parts[2]))
    return out


def digest(entries: Sequence[tuple[str, str]]) -> str:
    """SHA-256 of the sorted `path<TAB>blob id` lines (the stand runner computes the same from what it deployed)."""
    return hashlib.sha256("".join(f"{p}\t{b}\n" for p, b in sorted(entries)).encode("utf-8")).hexdigest()


def deployable(path: str) -> bool:
    """A gamedata file the stand gets (tools/stand_overlay.py's rules)."""
    parts = path.split("/")
    name = parts[-1]
    return not (name in DEPLOY_SKIP_NAMES or pathlib.PurePosixPath(name).suffix.lower() in DEPLOY_SKIP_EXT
                or "temp" in parts[1:] or "__pycache__" in parts)


def gamedata_entries(root: pathlib.Path, engine: Optional[pathlib.Path], mod_ref: str,
                     engine_ref: Optional[str]) -> list[tuple[str, str]]:
    """(project path, blob id) of the gamedata the stand runs: gamedata and gamedata_gamma of the project at mod_ref, the
    engine's gamedata at engine_ref (as engine/gamedata/...)."""
    entries = []
    for repo_name, folder in GAMEDATA_SOURCES:
        if repo_name == "mod":
            entries += tree_blobs(root, mod_ref, [folder])
        elif engine is not None and engine_ref:
            entries += tree_blobs(engine, engine_ref, [folder], "engine/")
    return [(p, b) for p, b in entries if deployable(p)]


def gamedata_digest(root: pathlib.Path, engine: Optional[pathlib.Path], mod_ref: str, engine_ref: Optional[str]) -> str:
    return digest(gamedata_entries(root, engine, mod_ref, engine_ref))


def scenarios_digest(root: pathlib.Path, ref: str) -> str:
    """The scenario files of both stands at ref (tools/stand, the runners and the two checkers they import)."""
    return digest(tree_blobs(root, ref, list(SCENARIO_PATHS)))


def profile_digest(root: pathlib.Path, ref: str) -> str:
    """tools/stand/stand_profile.ltx at ref: the mode cvars the stand's profiles run with (S2)."""
    return digest(tree_blobs(root, ref, [PROFILE]))


def head(repo: pathlib.Path, ref: str = "HEAD") -> str:
    return git(repo, "rev-parse", "--verify", ref + "^{commit}").strip()


def worktree_files(repo: pathlib.Path) -> list[str]:
    files = set(git(repo, "diff", "--name-only", "--no-renames", "HEAD").splitlines())
    files |= set(git(repo, "ls-files", "--others", "--exclude-standard").splitlines())
    return sorted(f for f in files if f)


def dirty_lines(repo: pathlib.Path, paths: Sequence[str]) -> list[str]:
    """`git status --porcelain` lines of uncommitted files under paths, tracked or not."""
    return [l for l in git(repo, "status", "--porcelain", "--untracked-files=all", "--", *paths).splitlines() if l.strip()]


def range_files(repo: pathlib.Path, rng: str) -> list[tuple[str, list[str], bool]]:
    """(commit, files, is a merge) of every commit of the range, oldest first, in one git call. Both paths of a rename;
    a merge with its diff against its first parent."""
    out: list[tuple[str, list[str], bool]] = []
    for line in git(repo, "log", "--reverse", "--diff-merges=first-parent", "--no-renames", "--format=@@%H %P",
                    "--name-only", rng).splitlines():
        if line.startswith("@@"):
            ids = line[2:].split()
            out.append((ids[0], [], len(ids) > 2))
        elif line.strip() and out:
            out[-1][1].append(line.strip())
    return out


def engine_base(engine: pathlib.Path, base: str, end: str) -> str:
    """The engine's release tags point to a public snapshot commit (its tree on top of the public main, message
    "Source tree: <id>"), not to a commit of the source branch: use that source id when the tag is no ancestor of end."""
    sha = head(engine, base)
    done = subprocess.run(["git", "-C", str(engine), "merge-base", "--is-ancestor", sha, end], capture_output=True,
                          env=GIT_ENV)
    if done.returncode == 0:
        return sha
    m = re.search(r"Source tree:\s*([0-9a-f]{40})", git(engine, "log", "-1", "--format=%B", sha))
    if not m:
        raise GateError(f"engine: {base} is not an ancestor of {end} and names no source tree; pass --engine-range")
    return m.group(1)


# ---- route tables (critique H6, review 3 C10) -------------------------------------------------------------------------

def ltx_entries(text: str) -> dict[tuple[str, str], list[str]]:
    """An ltx file as data: (section, key) -> its values in order, `;` comments and blank lines dropped. Every section
    has the key ':parents' (`[s]:a, b` -> 'a,b'); a line without `=` is a key with the value ''."""
    out: dict[tuple[str, str], list[str]] = defaultdict(list)
    section = ""
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        m = re.match(r"^\[([^\]]*)\]\s*(?::\s*(.*))?$", line)
        if m:
            section = m.group(1).strip()
            out[(section, ":parents")].append(re.sub(r"\s+", "", m.group(2) or ""))
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            out[(section, key.strip())].append(value.strip())
        else:
            out[(section, line)].append("")
    return dict(out)


def route_neutral(old: str, new: str) -> bool:
    """True when a route table's two versions hold the same (section, key) pairs and every value differs at most by
    `host` <-> `level` (route domains that both run on the co-op host). A key moved to another section, added or
    removed, and any other value change, is not neutral."""
    a, b = ltx_entries(old), ltx_entries(new)
    if set(a) != set(b):
        return False
    swap = re.compile(r"\b(host|level)\b")
    for key, values in a.items():
        other = b[key]
        if len(values) != len(other) or any(swap.sub("D", x) != swap.sub("D", y) for x, y in zip(values, other)):
            return False
    return True


# ---- classification -----------------------------------------------------------------------------------------------

@dataclass
class Unit:
    """One commit (or the working tree) and the layers of its files."""
    label: str
    files: dict[str, tuple[str, str]] = field(default_factory=dict)  # path -> (layer, why)
    merge: bool = False

    def layers(self) -> set[str]:
        return {layer for layer, _ in self.files.values() if layer != "none"}


def classify(path: str, layers: check_layers.LayerMap, allowed: set[str], entries: set[str],
             versions_of: Callable[[str], tuple[str, str]], reach: Optional[dict[str, str]] = None) -> tuple[str, str]:
    """(layer, why) of a changed file; versions_of(path) gives (old text, new text) of a route table."""
    if path.startswith('"'):
        raise GateError(f"a quoted path from git (core.quotePath): {path}; the gate reads raw paths only")
    low = path.lower()
    if low in GATE_FILES or low.startswith(GATE_DIRS):
        return "core", "decides layers and gates (a list, a checker, a test runner or a stand scenario)"
    if low in MODE_FILES:
        return "core", "the facade coop_mode and its layers decide in which process when_srv code runs (C5)"
    if not PRODUCT.match(path):
        return "none", "outside the product"
    if ROUTE.match(path):
        old, new = versions_of(path)
        return ("srv", "route table: only host <-> level") if route_neutral(old, new) else ("core", "route table (H6)")
    if low == PROTOCOL.lower():
        return "core", "protocol header"
    if low in allowed:
        return "core", "has allow-list entries (H9)"
    if low in entries:
        return "core", "defines a server entry point (H5)"
    if layers.gate_row(path) == "gate-core":
        return "core", "server script that still runs in co-op (H4)"
    layer = layers.layer_of(path)
    if layer == "stock":
        return "core", "stock engine file (rule 8)"
    if layer == "dying":
        return "core", "hybrid code (dying)"
    if reach and low in reach:
        return "core", f"runs in both modes: {reach[low]}"
    return layer, layer


def coop_tests(repo: pathlib.Path, ref: Optional[str]) -> Counter[str]:
    """The co-op tests: names of the native TEST( in tests/*.cpp and the Lua files tests/lua/test_*.lua, both without
    test_srv_*; at ref, or on disk."""
    def is_coop(name: str) -> bool:
        return not name.rsplit("/", 1)[-1].startswith("test_srv_")

    def native(text: str) -> list[str]:
        return [f"TEST({m.group(1).strip()})" for m in re.finditer(r"(?m)^\s*TEST\s*\(\s*([^)]*?)\s*\)", text)]

    names: Counter[str] = Counter()
    if ref is None:
        tests = repo / "tests"
        for path in sorted(tests.glob("*.cpp")) if tests.is_dir() else []:
            if is_coop(path.name):
                names.update(native(path.read_text(encoding="utf-8", errors="replace")))
        lua = tests / "lua"
        names.update(f"lua:{p.name}" for p in (lua.glob("test_*.lua") if lua.is_dir() else []) if is_coop(p.name))
        return names
    for name in git(repo, "ls-tree", "-r", "--name-only", ref, "--", "tests").splitlines():
        if re.fullmatch(r"tests/[^/]+\.cpp", name) and is_coop(name):
            names.update(native(git(repo, "show", f"{ref}:{name}")))
        elif re.fullmatch(r"tests/lua/test_[^/]+\.lua", name) and is_coop(name):
            names[f"lua:{name.rsplit('/', 1)[-1]}"] += 1
    return names


# ---- the exe: built from engine HEAD (review 3, C12) ------------------------------------------------------------------

def sha256_of(path: pathlib.Path) -> Optional[str]:
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def short(value: Optional[str]) -> str:
    return (value or "-")[:8]


def blob_ids(data: bytes) -> tuple[str, str]:
    """The git blob id of the bytes as they are and with CRLF read as LF (a core.autocrlf checkout)."""
    return tuple(hashlib.sha1(b"blob %d\0" % len(d) + d).hexdigest()  # type: ignore[return-value]
                 for d in (data, data.replace(b"\r\n", b"\n")))


def ci_index(ci: pathlib.Path, trees: Sequence[str] = CI_TREES) -> Optional[tuple[dict[str, str], set[str], set[str]]]:
    """(index blob of every tracked file under trees, files that differ from the index, untracked files) of the
    engine-ci worktree; None when engine-ci is not a git worktree (then every file is read)."""
    if not (ci / ".git").exists():
        return None
    index: dict[str, str] = {}
    for item in git(ci, "ls-files", "-s", "-z", "--", *trees).split("\0"):
        meta, _, path = item.partition("\t")
        parts = meta.split()
        if len(parts) == 3 and parts[2] == "0" and parts[0] != "160000":
            index[path] = parts[1]
    changed = {p for p in git(ci, "diff-files", "--name-only", "-z", "--", *trees).split("\0") if p}
    others = {p for p in git(ci, "ls-files", "--others", "--exclude-standard", "-z", "--", *trees).split("\0") if p}
    return index, changed, others


# the one-line items tools/vcxproj_add.py writes into engine-ci's xrGame.vcxproj for our coop sources
VCX_COOP_ITEM = re.compile(r'^\s*<(ClCompile|ClInclude) Include="coop\\([^"]+)" />\s*$')


def vcxproj_problems(engine: pathlib.Path, ci: pathlib.Path) -> list[str]:
    """engine-ci's xrGame.vcxproj builds what engine HEAD's does (review 4, B4/E3): the same text once the one-line coop
    items tools/vcxproj_add.py writes are set aside (their order differs), the same set of coop sources compiled
    (ClCompile; a ClInclude only lists a header), and each of them a file of engine HEAD. A define, a compiler option or a
    source outside src/xrGame/coop that engine-ci alone compiles is a difference."""
    rel = "src/xrGame/xrGame.vcxproj"
    head_text = git_show(engine, f"HEAD:{rel}")
    path = ci / rel
    if not head_text:
        return []
    if not path.is_file():
        return [f"engine-ci has no {rel}"]

    def split(text: str) -> tuple[list[str], set[str]]:
        rest, compiled = [], set()
        for line in text.lstrip("﻿").replace("\r\n", "\n").split("\n"):
            m = VCX_COOP_ITEM.match(line)
            if m is None:
                rest.append(line.rstrip())
            elif m.group(1) == "ClCompile":
                compiled.add(m.group(2).replace("\\", "/").lower())  # coop\srv\x.cpp -> srv/x.cpp
        while rest and not rest[-1]:
            rest.pop()  # a final line break (engine-ci's copy has none) builds the same
        return rest, compiled

    head_rest, head_compiled = split(head_text)
    ci_rest, ci_compiled = split(path.read_bytes().decode("utf-8", "replace"))
    problems = []
    if head_rest != ci_rest:
        changed = sum(1 for a, b in zip(head_rest, ci_rest) if a != b) + abs(len(head_rest) - len(ci_rest))
        problems.append(f"engine-ci's {rel} differs from engine HEAD's beyond the coop items vcxproj_add writes "
                        f"({changed} line(s)): a define, an option or a source only engine-ci builds")
    heads = {p.lower() for p, _ in tree_blobs(engine, "HEAD", ["src/xrGame/coop"])}
    only_ci = sorted(n for n in ci_compiled - head_compiled if f"src/xrgame/coop/{n}" not in heads)
    if only_ci:
        problems.append(f"engine-ci's {rel} compiles {len(only_ci)} coop source(s) engine HEAD does not have: "
                        + ", ".join(only_ci[:5]))
    lacking = sorted(head_compiled - ci_compiled)
    if lacking:
        problems.append(f"engine-ci's {rel} does not compile {len(lacking)} coop source(s) of engine HEAD: "
                        + ", ".join(lacking[:5]))
    return problems


def exe_source(engine: Optional[pathlib.Path], exe: pathlib.Path, ci: pathlib.Path) -> tuple[str, list[str]]:
    """(engine HEAD, []) when exe is engine-ci's build of engine HEAD's committed sources; ("", why) otherwise."""
    if engine is None or not (engine / ".git").exists():
        return "", ["no engine repository"]
    engine_head = head(engine)
    problems = []
    dirty = dirty_lines(engine, list(CI_TREES))
    if dirty:
        problems.append(f"engine/{dirty[0][3:].split('/')[0]} has {len(dirty)} uncommitted file(s) ({dirty[0][3:]} ...): "
                        "the exe must come from committed sources")
    ci_exe = ci.joinpath(*CI_EXE)
    if not ci_exe.is_file():
        return "", problems + [f"no engine-ci build {ci_exe}"]
    if not exe.is_file():
        return "", problems + [f"no exe {exe}"]
    if os.path.normcase(str(exe.resolve())) != os.path.normcase(str(ci_exe.resolve())):
        have, ci_hash = sha256_of(exe), sha256_of(ci_exe)
        if have != ci_hash:
            problems.append(f"the exe {short(have)} is not engine-ci's build {short(ci_hash)}: copy the build "
                            "(tools/stand_overlay.py) or build again")
    built = ci_exe.stat().st_mtime
    heads = dict(tree_blobs(engine, "HEAD", list(CI_TREES)))
    known = ci_index(ci)
    differ: list[str] = []
    missing: list[str] = []
    newer: list[str] = []
    for path, blob in sorted(heads.items()):
        low = path.lower()
        target = ci / path
        # review 4, B4/E2: every file is stat'ed before git's index is trusted: a build from an uncommitted edit that
        # `git checkout` then put back matches the index again, but the checkout gave it a time after the exe's
        try:
            mtime = target.stat().st_mtime
        except OSError:
            missing.append(path)
            continue
        if mtime > built:
            newer.append(path)
        if low in CI_PATCHED:
            continue  # vcxproj_problems below
        if known is not None and path in known[0] and path not in known[1] and low != CI_BUILD_HEADER.lower():
            if known[0][path] != blob:
                differ.append(path)
            continue  # unchanged since engine-ci's checkout: git's index holds its blob
        try:
            data = target.read_bytes()
        except OSError:
            missing.append(path)
            continue
        if low == CI_BUILD_HEADER.lower():
            want = git_show(engine, f"HEAD:{path}").encode("utf-8").replace(b"\r\n", b"\n")
            if CI_BUILD_DEFINE.sub(b"#define RAYLINK_BUILD N", data.replace(b"\r\n", b"\n")) != \
                    CI_BUILD_DEFINE.sub(b"#define RAYLINK_BUILD N", want):
                differ.append(path)
        elif blob not in blob_ids(data):
            differ.append(path)
    heads_low = {p.lower() for p in heads}
    extra = []
    if known is not None:
        candidates = set(known[0]) | known[2]
    else:
        candidates = set()
        for tree in CI_TREES:
            base = ci / tree
            if base.is_dir():
                candidates |= {p.relative_to(ci).as_posix() for p in base.rglob("*") if p.is_file()}
    for path in sorted(candidates):
        low = path.lower()
        if low in heads_low or not (ci / path).is_file():
            continue
        # src: a source file the build may compile; sdk: any file (a library or a header the build links or includes)
        if low.endswith(CI_SOURCE_EXT) or low.startswith("sdk/"):
            extra.append(path)
    problems += vcxproj_problems(engine, ci)

    def names(items: list[str]) -> str:
        return ", ".join(items[:5]) + (f" (+{len(items) - 5})" if len(items) > 5 else "")

    if differ:
        problems.append(f"engine-ci differs from engine HEAD in {len(differ)} file(s): {names(differ)} "
                        "(python tools/ci_sync.py --committed, then build)")
    if missing:
        problems.append(f"engine-ci lacks {len(missing)} file(s) of engine HEAD: {names(missing)}")
    if extra:
        problems.append(f"engine-ci holds {len(extra)} source file(s) engine HEAD does not have: {names(extra)} "
                        "(ci_sync never deletes: remove them, or the build may compile them)")
    if newer:
        problems.append(f"{len(newer)} engine-ci file(s) changed after the exe was built: {names(newer)} (build again)")
    return ("" if problems else engine_head), problems


# ---- the stand ----------------------------------------------------------------------------------------------------

def stand_exe(stand: pathlib.Path) -> pathlib.Path:
    return stand.joinpath(*STAND_EXE)


def stand_fingerprint(stand: pathlib.Path) -> str:
    """SHA-256 of the stand's manifest (.raylink-stand.json: which mod gave which file) and of every coop_*.script on
    the stand that is not a probe of tools/stand (coop_zz_*): a mark of another folder, of a stand made again, or of a
    stand whose coop scripts (ours, or one a GAMMA mod ships) changed since the run does not count (S1, S3)."""
    h = hashlib.sha256()
    manifest = stand / ".raylink-stand.json"
    h.update(b"manifest\0" + (manifest.read_bytes() if manifest.is_file() else b"none") + b"\0")
    scripts = stand / "gamedata" / "scripts"
    if scripts.is_dir():
        for path in sorted(scripts.glob("coop_*.script"), key=lambda p: p.name.lower()):
            if not path.name.lower().startswith("coop_zz_"):
                h.update(path.name.lower().encode("utf-8") + b"\0" + hashlib.sha256(path.read_bytes()).digest())
    return h.hexdigest()


def same_path(a: str, b: pathlib.Path) -> bool:
    return bool(a) and os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(str(b)))


# ---- marks --------------------------------------------------------------------------------------------------------

def read_mark(path: pathlib.Path) -> Optional[dict[str, str]]:
    if not path.is_file():
        return None
    out = {}
    for raw in path.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        if "=" in raw:
            k, v = raw.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def check_tests_mark(marks: pathlib.Path, mod_head: str, engine_head: str) -> tuple[bool, str]:
    """tests.ok counts with mode=tests, dirty=0, native=0, lua=0 and both HEAD ids."""
    mark = read_mark(marks / f"{TESTS}.ok")
    if mark is None:
        return False, "tests.ok missing (run tools\\run_all_tests.cmd: N and L on the committed tree)"
    problems = []
    if mark.get("mode") != TESTS:
        problems.append(f"mode {mark.get('mode') or 'missing'}")
    if mark.get("dirty") != "0":
        problems.append(f"the tests ran on a dirty tree (dirty={mark.get('dirty') or 'missing'})")
    for key, what in (("native", "tools\\build_tests.cmd"), ("lua", "tools\\test_lua.cmd")):
        if mark.get(key) != "0":
            problems.append(f"{what} did not pass ({key}={mark.get(key) or 'missing'})")
    if mark.get("mod_head", "").lower() != mod_head.lower():
        problems.append(f"mod {short(mark.get('mod_head'))} != {short(mod_head)}")
    if mark.get("engine_head", "").lower() != engine_head.lower():
        problems.append(f"engine {short(mark.get('engine_head'))} != {short(engine_head)}")
    if problems:
        return False, "tests.ok does not count: " + ", ".join(problems)
    return True, f"tests.ok OK (mod {short(mod_head)}, engine {short(engine_head)}, {mark.get('time', '?')})"


def check_mark(mode: str, marks: pathlib.Path, mod_head: str, engine_head: str, exe_hash: Optional[str],
               root: Optional[pathlib.Path] = None, engine: Optional[pathlib.Path] = None,
               stand: Optional[pathlib.Path] = None) -> tuple[bool, str]:
    """A stand mark counts with its own mode, dirty=0, every scenario, both HEAD ids, the exe and its source (engine HEAD),
    no leftover on the stand; with root: the scenario files, the gamedata and the profile template of those HEADs
    (recomputed from HEAD's blobs); with stand: the stand's exe path and its fingerprint now."""
    if mode == TESTS:
        return check_tests_mark(marks, mod_head, engine_head)
    mark = read_mark(marks / f"{mode}.ok")
    if mark is None:
        return False, f"{mode}.ok missing (run tools\\stand_{mode}.ps1)"
    problems = []
    if root is not None:
        for key, what, want in (
                ("scenarios_sha256", "scenario files", lambda: scenarios_digest(root, mod_head)),
                ("gamedata_sha256", "gamedata", lambda: gamedata_digest(root, engine, mod_head, engine_head or None)),
                ("profile_sha256", "profile cvars", lambda: profile_digest(root, mod_head))):
            have = mark.get(key, "").lower()
            if not have:
                problems.append(f"{key} missing (a mark of an older runner)")
                continue
            try:
                expected = want()
            except GateError as error:
                problems.append(f"{what}: {error}")
                continue
            if have != expected:
                problems.append(f"{what} {short(have)} != HEAD's {short(expected)} (the stand ran other {what} than HEAD's)")
    if mark.get("mode") != mode:
        problems.append(f"mode {mark.get('mode') or 'missing'}")
    if mark.get("dirty") != "0":
        problems.append(f"the stand ran a dirty tree (dirty={mark.get('dirty') or 'missing'}): its exe may hold "
                        "uncommitted code")
    ran = {s.strip() for s in mark.get("scenarios", "").split(",") if s.strip()}
    missing = [s for s in SCENARIOS[mode] if s not in ran]
    if missing:
        problems.append(f"a part of the stand: {', '.join(missing)} did not run")
    if mark.get("mod_head", "").lower() != mod_head.lower():
        problems.append(f"mod {short(mark.get('mod_head'))} != {short(mod_head)}")
    if mark.get("engine_head", "").lower() != engine_head.lower():
        problems.append(f"engine {short(mark.get('engine_head'))} != {short(engine_head)}")
    if exe_hash is None:
        problems.append("the exe to compare with is missing")
    elif mark.get("exe_sha256", "").lower() != exe_hash.lower():
        problems.append(f"exe {short(mark.get('exe_sha256'))} != {short(exe_hash)}")
    if not engine_head or mark.get("exe_source", "").lower() != engine_head.lower():
        problems.append(f"the stand's exe was not shown to be built from engine HEAD "
                        f"(exe_source={short(mark.get('exe_source')) if mark.get('exe_source') else 'missing'})")
    if mark.get("stand_extra") != "0":
        problems.append(f"the stand held files HEAD does not have (stand_extra={mark.get('stand_extra') or 'missing'})")
    if stand is not None:
        want_exe = stand_exe(stand)
        if not same_path(mark.get("exe", ""), want_exe):
            problems.append(f"the mark names the exe {mark.get('exe') or 'missing'}, not the stand's {want_exe}")
        if mark.get("stand_fingerprint", "").lower() != stand_fingerprint(stand):
            problems.append(f"the stand changed since the run (stand_fingerprint "
                            f"{short(mark.get('stand_fingerprint')) if mark.get('stand_fingerprint') else 'missing'})")
    if problems:
        return False, f"{mode}.ok does not count: " + ", ".join(problems)
    return True, f"{mode}.ok OK (mod {short(mod_head)}, engine {short(engine_head)}, exe {short(exe_hash)}, {mark.get('time', '?')})"


# ---- tests.ok (tools/run_all_tests.cmd) -----------------------------------------------------------------------------

def tests_state(root: pathlib.Path) -> dict[str, str]:
    """Both HEAD ids and the uncommitted files N and L read (product, tests, runners) now."""
    engine = root / "engine"
    has_engine = (engine / ".git").exists()
    dirty: list[str] = []
    for repo_name, paths in TESTS_DIRTY:
        if repo_name == "mod":
            dirty += dirty_lines(root, paths)
        elif has_engine:
            dirty += [l[:3] + "engine/" + l[3:] for l in dirty_lines(engine, paths)]
    return {"mod_head": head(root), "engine_head": head(engine) if has_engine else "", "dirty": str(len(dirty)),
            "first_dirty": dirty[0].strip() if dirty else ""}


LUA_RUNNER = ("temp", "lua", "runlua.exe")
# the engine's static LuaJIT in engine-ci's build, the one build of the current engine sources
CI_LUA51 = ("_build", "_game", "bin_dbg", "x64", "Release-AVX", "lua51.lib")


def lua51_lib(root: pathlib.Path) -> pathlib.Path:
    """The lua51.lib the Lua runner and the native Lua tests link: LUA51_LIB when it is set, else engine-ci's build.
    There is no second choice: an older build (engine/_build) would test a LuaJIT the game no longer runs."""
    named = os.environ.get("LUA51_LIB")
    return pathlib.Path(named).absolute() if named else root.joinpath("engine-ci", *CI_LUA51)


# the engine's LuaJIT sources, the same path in engine/ and engine-ci/
LUAJIT_SRC = ("src", "3rd party", "luajit-2", "src")


def lj_vm_obj(root: pathlib.Path) -> pathlib.Path:
    """The LuaJIT VM object tools/test_luajit.cmd packs with the LuaJIT it compiles: LJ_VM_OBJ when it is set, else
    engine-ci's (the engine build generates it there from engine HEAD's LuaJIT sources), else the one
    gen_luajit_artifacts.bat generated in engine/ (git ignores it, so a fresh engine/ has none). When neither exists it is
    engine-ci's path: the runner names it and stops."""
    named = os.environ.get("LJ_VM_OBJ")
    if named:
        return pathlib.Path(named).absolute()
    places = [root.joinpath(tree, *LUAJIT_SRC, "lj_vm.obj") for tree in ("engine-ci", "engine")]
    return next((path for path in places if path.is_file()), places[0])


def luajit_stamp(root: pathlib.Path) -> str:
    """The stamp of the LuaJIT library tools/test_luajit.cmd builds: the SHA-1 of every file of the engine's LuaJIT
    sources folder it compiles or includes (*.c, *.h, by name), the lj_vm.obj it packs (lj_vm_obj) and test_luajit.cmd
    itself. The runner builds the library again only when the stamp beside it differs."""
    digest = hashlib.sha1()
    src = root.joinpath("engine", *LUAJIT_SRC)
    for path in sorted([*src.glob("*.c"), *src.glob("*.h")]) + [lj_vm_obj(root), root / "tools" / "test_luajit.cmd"]:
        digest.update(path.name.encode("utf-8"))
        try:
            digest.update(path.read_bytes())
        except OSError:
            digest.update(b"missing")
    return digest.hexdigest()[:16]


def vcvars() -> Optional[pathlib.Path]:
    """vcvars64.bat of the MSVC every native test builds with (the runners and the engine slices): VCVARS when it is
    set, else the newest Visual Studio or Build Tools with the x64 C++ tools, as vswhere (the installer's locator, in
    its fixed place under %ProgramFiles(x86)%) finds it. None when there is no such install: the caller names VCVARS."""
    named = os.environ.get("VCVARS")
    if named:
        return pathlib.Path(named).absolute()
    vswhere = pathlib.Path(os.environ.get("ProgramFiles(x86)", "")) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    try:
        found = subprocess.run([str(vswhere), "-latest", "-products", "*", "-requires",
                                "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-find",
                                r"VC\Auxiliary\Build\vcvars64.bat"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    lines = found.stdout.strip().splitlines()
    return pathlib.Path(lines[0].strip()) if lines else None


def gamma_scripts() -> Optional[pathlib.Path]:
    """The real G.A.M.M.A. scripts the Lua tests and their helpers read: GAMMA_SCRIPTS when it is set, else the stand's
    (DEFAULT_STAND, the one place that names it). None when neither is there: the tests that need them fail and name
    GAMMA_SCRIPTS."""
    named = os.environ.get("GAMMA_SCRIPTS")
    scripts = pathlib.Path(named).absolute() if named else DEFAULT_STAND / "gamedata" / "scripts"
    return scripts if scripts.is_dir() else None


def lua_stamp(root: pathlib.Path) -> str:
    """The stamp tools/test_lua.cmd builds temp/lua/runlua.exe with (RUNLUA_STAMP; the cmd takes it from --lua-stamp):
    the first 8 hex digits of the SHA-1 of tests/lua/runlua.c, tests/lua/native_coop.cpp, every engine/src/xrCoop file
    native_coop.cpp names in a line that starts with #include (its second word, quotes off, when that file exists),
    tools/test_lua.cmd and the lua51.lib it links (lua51_lib), in that order ("missing0" for a file that cannot be
    read). The lib is part of it: a runner linked to another LuaJIT tests another VM."""
    def part(path: pathlib.Path) -> str:
        try:
            return hashlib.sha1(path.read_bytes()).hexdigest()[:8]
        except OSError:
            return "missing0"

    native = root / "tests" / "lua" / "native_coop.cpp"
    parts = [part(root / "tests" / "lua" / "runlua.c"), part(native)]
    try:
        lines = native.read_bytes().decode("latin-1").splitlines()
    except OSError:
        lines = []
    for line in lines:
        words = line.split() if line.startswith("#include") else []
        if len(words) >= 2:
            name = words[1][1:-1] if len(words[1]) >= 2 and words[1][0] == words[1][-1] == '"' else words[1]
            header = root / "engine" / "src" / "xrCoop" / name
            try:
                exists = header.is_file()
            except OSError:
                exists = False
            if exists:
                parts.append(part(header))
    parts.append(part(root / "tools" / "test_lua.cmd"))
    parts.append(part(lua51_lib(root)))
    return "".join(parts)


def lua_runner_stale(root: pathlib.Path) -> Optional[str]:
    """Why the shared Lua runner was not built from the sources and the lua51.lib now, or None. tools/test_lua.cmd runs
    the old temp/lua/runlua.exe and exits 0 when it cannot rebuild it, so the gate looks at the exe itself: its stamp
    must be lua_stamp, the whole string, not a longer one that starts with it."""
    exe = root.joinpath(*LUA_RUNNER)
    if not exe.is_file():
        return "there is no temp\\lua\\runlua.exe"
    want = lua_stamp(root)
    # RUNLUA_STAMP is a C string in the exe's data: no printable byte before it, its NUL after it
    whole = re.compile(rb"(?<![\x21-\x7e])" + re.escape(want.encode("ascii")) + rb"\x00", re.I)
    if not whole.search(exe.read_bytes()):
        return (f"temp\\lua\\runlua.exe was not built from the sources and the lua51.lib now (stamp {want[:16]}...): "
                "tools\\test_lua.cmd could not rebuild it and ran a stale runner (fix the build, or wait for another "
                "Lua run to end)")
    return None


def tests_mark(root: pathlib.Path, marks: pathlib.Path, command: str, state_file: Optional[pathlib.Path],
               native: Optional[int], lua: Optional[int]) -> int:
    """begin: drop the old tests.ok, print the state (both HEADs, dirty) for `write`. write: tests.ok when the native
    tests (tools/build_tests.cmd, tools/test_luajit.cmd and the engine slices) and the Lua tests passed on a fresh Lua
    runner, the tree was clean and neither HEAD moved. The gate reads exit codes only; it runs no test itself."""
    mark = marks / f"{TESTS}.ok"
    if command == "begin":
        if mark.exists():
            mark.unlink()
        state = tests_state(root)
        for key, value in state.items():
            print(f"{key}={value}")
        if state["dirty"] != "0":
            print(f"gates: {state['dirty']} uncommitted file(s) the tests read ({state['first_dirty']} ...): the run "
                  "will write no tests.ok")
        return 0
    if state_file is None or not state_file.is_file():
        print("gates: no tests.ok: the state of --tests-mark begin is missing")
        return 1
    before = read_mark(state_file) or {}
    now = tests_state(root)
    why = []
    if native != 0:
        why.append(f"the native tests failed ({native})")
    if lua != 0:
        why.append(f"tools\\test_lua.cmd failed ({lua})")
    else:
        stale = lua_runner_stale(root)
        if stale:
            why.append(stale)
    if before.get("dirty") != "0" or now["dirty"] != "0":
        why.append(f"the tree was not clean (dirty {before.get('dirty', '?')} before, {now['dirty']} after"
                   + (f": {now['first_dirty']}" if now["first_dirty"] else "") + ")")
    for key in ("mod_head", "engine_head"):
        if before.get(key) != now[key]:
            why.append(f"{key} moved during the run ({short(before.get(key))} -> {short(now[key])})")
    if why:
        print("gates: no tests.ok: " + "; ".join(why))
        return 1
    marks.mkdir(parents=True, exist_ok=True)
    lines = [f"mode={TESTS}", f"mod_head={now['mod_head']}", f"engine_head={now['engine_head']}",
             f"time={time.strftime('%Y-%m-%dT%H:%M:%S%z')}", "dirty=0", "native=0", "lua=0"]
    mark.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"gates: tests.ok written (mod {short(now['mod_head'])}, engine {short(now['engine_head'])})")
    return 0


# ---- main ---------------------------------------------------------------------------------------------------------

@dataclass
class Result:
    units: list[Unit]
    required: set[str]
    lines: list[str]
    failures: list[str]


def evaluate(root: pathlib.Path, rng: Optional[str], engine_rng: Optional[str], marks: pathlib.Path,
             exe: pathlib.Path, per_commit: bool = False, release: bool = False, stand: Optional[pathlib.Path] = None,
             ci: Optional[pathlib.Path] = None, model: Optional[check_layers.Model] = None) -> Result:
    tools = root / "tools"
    if not (tools / "layers.txt").is_file():
        raise GateError(f"missing input file layers.txt: {tools / 'layers.txt'}")
    layers = read_layers(tools / "layers.txt")
    allowed = allow_paths(tools / "layers_allow.txt")
    names = []
    if (tools / "srv_entry.txt").is_file():
        names = check_layers.parse_names((tools / "srv_entry.txt").read_text(encoding="utf-8"))
    entries = entry_files(root, names)
    if model is None:
        model = check_layers.build(root, layers, names)
    # the files the gate counts as Ядро for another reason (gate-core rows, the files of srv_entry.txt) run in the co-op
    # process too: what they include, call or name is reached as well
    roots = sorted(entries | {s.path for s in model.sources if layers.gate_row(s.path) == "gate-core"})
    reach = check_layers.core_reach(model, roots)
    engine = root / "engine"
    has_engine = (engine / ".git").exists()

    def sort(path: str, versions_of: Callable[[str], tuple[str, str]]) -> tuple[str, str]:
        return classify(path, layers, allowed, entries, versions_of, reach)

    def disk_versions(repo: pathlib.Path, prefix: str) -> Callable[[str], tuple[str, str]]:
        def versions(p: str) -> tuple[str, str]:
            rel = p[len(prefix):]
            disk = repo / rel
            return git_show(repo, f"HEAD:{rel}"), (disk.read_text(encoding="utf-8", errors="replace")
                                                    if disk.is_file() else "")
        return versions

    def commit_versions(repo: pathlib.Path, prefix: str, sha: str) -> Callable[[str], tuple[str, str]]:
        def versions(p: str) -> tuple[str, str]:
            rel = p[len(prefix):]
            return git_show(repo, f"{sha}^1:{rel}"), git_show(repo, f"{sha}:{rel}")
        return versions

    units: list[Unit] = []
    lines: list[str] = []
    dirty_product: list[str] = []
    if rng is None:
        unit = Unit("working tree")
        for repo, prefix in [(root, "")] + ([(engine, "engine/")] if has_engine else []):
            for f in worktree_files(repo):
                path = prefix + f
                unit.files[path] = sort(path, disk_versions(repo, prefix))
        units.append(unit)
        dirty_product = [p for p, (layer, _) in unit.files.items() if layer != "none"]
        mod_end = head(root)
        engine_end = head(engine) if has_engine else ""
        test_base, test_end = "HEAD", None
        lines.append(f"gates: working tree against HEAD (mod {short(mod_end)}, engine {short(engine_end)})")
    else:
        if ".." not in rng:
            raise GateError(f"a range is A..B, got {rng!r}")
        base, end = rng.split("..", 1)
        end = end or "HEAD"
        for sha, files, merge in range_files(root, rng):
            unit = Unit(f"mod {sha[:8]}" + (" (merge)" if merge else ""), merge=merge)
            for f in files:
                unit.files[f] = sort(f, commit_versions(root, "", sha))
            units.append(unit)
        mod_end = head(root, end)
        engine_end = ""
        if has_engine:
            erng = engine_rng or rng
            ebase, eend = erng.split("..", 1)
            eend = eend or "HEAD"
            erng = f"{engine_base(engine, ebase, eend)}..{eend}"
            for sha, files, merge in range_files(engine, erng):
                unit = Unit(f"engine {sha[:8]}" + (" (merge)" if merge else ""), merge=merge)
                for f in files:
                    path = "engine/" + f
                    unit.files[path] = sort(path, commit_versions(engine, "engine/", sha))
                units.append(unit)
            engine_end = head(engine, eend)
        test_base, test_end = base, end
        lines.append(f"gates: {rng} (mod {short(mod_end)}, engine {short(engine_end)}), {len(units)} commit(s)"
                     + (", judged commit by commit (--per-commit)" if per_commit else ""))

    failures: list[str] = []
    required: set[str] = set()   # hostplay, srv, tests (marks); cooptests: the srv-only rule on the co-op tests
    counts = {"core": 0, "srv": 0, "hostplay": 0, "none": 0}
    for unit in units:
        for path, (layer, why) in sorted(unit.files.items()):
            counts[layer if layer in counts else "core"] += 1
        got = unit.layers()
        if "hostplay" in got and "srv" in got and "core" not in got and not unit.merge:
            failures.append(f"gates: {unit.label} touches hostplay and srv without Ядро: split the commit "
                            "(docs/MODES.md section 10)")
        if "core" in got:
            required |= {"hostplay", "srv"}
        if "srv" in got:
            required |= {"srv", "cooptests"}
        if "hostplay" in got:
            required.add("hostplay")
    if "hostplay" in required:
        required.discard("cooptests")  # the co-op stand covers co-op; the test rule is for a server-only change
    lines.append(f"gates: core {counts['core']} file(s), srv {counts['srv']}, hostplay {counts['hostplay']}, "
                 f"outside the product {counts['none']}")
    for unit in units:
        for path, (layer, why) in sorted(unit.files.items()):
            if layer != "none":
                lines.append(f"gates:   {unit.label}: {layer:8s} {path} ({why})")
    product = any(layer != "none" for unit in units for layer, _ in unit.files.values())
    if rng is not None and not per_commit:
        # the release rule (review 3): classification is an early warning only; a range that ships needs everything
        if product or release:
            required = {"hostplay", "srv", TESTS}
            lines.append("gates: release rule: " + ("a product file changed in the range" if product else
                                                   "the release ships the exe") +
                         ": both stand marks and tests.ok, whatever the files' layers (docs/MODES.md section 10)")
        else:
            required = set()
    needs = [m for m in MARKS if m in required] + ([TESTS] if TESTS in required else [])
    if needs:
        lines.append("gates: required: " + ", ".join(f"{m}.ok" for m in needs) +
                     (", unchanged co-op tests" if "cooptests" in required else ""))
    else:
        lines.append("gates: required: nothing (no product file changed)")
    exe_hash = sha256_of(exe) if any(m in MARKS for m in needs) else None
    for mode in needs:
        ok, text = check_mark(mode, marks, mod_end, engine_end, exe_hash, root, engine if has_engine else None, stand)
        lines.append("gates: " + text)
        if not ok:
            failures.append("gates: " + text)
    if release:
        source, why = exe_source(engine if has_engine else None, exe, ci or root / "engine-ci")
        if why:
            failures.append("gates: the exe was not built from engine HEAD: " + "; ".join(why))
        else:
            lines.append(f"gates: the exe is engine-ci's build of engine {short(source)} (its sources are HEAD's, the "
                         "exe is newer)")
    if needs and dirty_product:
        failures.append(f"gates: {len(dirty_product)} uncommitted product file(s): a stand mark covers committed HEADs "
                        "only; commit, build, run the stand")
    if "cooptests" in required:
        before = coop_tests(root, test_base)
        after = coop_tests(root, test_end)
        gone = sorted((before - after).elements())
        new = sorted((after - before).elements())
        text = f"co-op tests {sum(before.values())} -> {sum(after.values())}"
        if gone or new:
            text += " (" + "; ".join(part for part in (
                "removed " + ", ".join(gone[:5]) + (" ..." if len(gone) > 5 else "") if gone else "",
                "added " + ", ".join(new[:5]) + (" ..." if len(new) > 5 else "") if new else "") if part) + ")"
        lines.append("gates: " + text + ("" if gone or new else " (unchanged)"))
        if gone or new:
            failures.append(f"gates: a srv-only change changed the co-op tests ({text}): the co-op stand and "
                            "both marks are needed")
        # the bodies and the support files of the co-op tests count too, not only their names (B10)
        edited = [p for p in changed_tests(root, test_base, test_end) if not p.rsplit("/", 1)[-1].startswith("test_srv_")]
        if edited:
            failures.append(f"gates: a srv-only change edited co-op tests or their runner ({', '.join(edited[:5])}"
                            f"{' ...' if len(edited) > 5 else ''}): the co-op stand and both marks are needed")
    return Result(units, required, lines, failures)


def changed_tests(repo: pathlib.Path, base: str, end: Optional[str]) -> list[str]:
    """Files of the co-op tests and their runners changed between base and end (end None: the working tree against
    base, untracked files too)."""
    if end is None:
        files = set(git(repo, "diff", "--name-only", "--no-renames", base, "--", *TEST_PATHS).splitlines())
        files |= set(git(repo, "ls-files", "--others", "--exclude-standard", "--", *TEST_PATHS).splitlines())
    else:
        files = set(git(repo, "diff", "--name-only", "--no-renames", base, end, "--", *TEST_PATHS).splitlines())
    return sorted(f for f in files if f)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("range", nargs="?", help="git range A..B of this repository (default: the working tree vs HEAD)")
    ap.add_argument("--engine-range", help="git range of engine/ (default: RANGE)")
    ap.add_argument("--per-commit", action="store_true",
                    help="judge a range commit by commit by the files' layers (the early warning), not by the release rule")
    ap.add_argument("--release", action="store_true",
                    help="the range ships (tools/release.py): every mark always, and the exe must be engine HEAD's build")
    ap.add_argument("--layers", action="store_true",
                    help="run tools/check_layers.py first on the same model (one model build instead of two)")
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--marks", help="folder of the marks (default <root>/temp/gates)")
    ap.add_argument("--exe", default=str(DEFAULT_EXE), help="the exe the marks must name (default: the stand's)")
    ap.add_argument("--stand", default=str(DEFAULT_STAND), help="the stand whose marks count (its exe path, its manifest)")
    ap.add_argument("--ci", help="the engine-ci worktree the exe is built in (default <root>/engine-ci)")
    ap.add_argument("--exe-source", action="store_true", help="print the engine HEAD the exe was built from, or why not")
    ap.add_argument("--tests-mark", choices=["begin", "write"], help="tools/run_all_tests.cmd: the tests mark")
    ap.add_argument("--state", help="--tests-mark write: the file --tests-mark begin printed into")
    ap.add_argument("--native", type=int,
                    help="--tests-mark write: the exit code of the native tests (build_tests, test_luajit, slices)")
    ap.add_argument("--lua", type=int, help="--tests-mark write: the exit code of tools/test_lua.cmd")
    ap.add_argument("--lua-stamp", action="store_true",
                    help="print lib=<the lua51.lib the Lua runner links> and stamp=<the stamp it is built with> "
                         "(tools/test_lua.cmd)")
    ap.add_argument("--lj-vm", action="store_true",
                    help="print lj_vm=<the LuaJIT VM object tools/test_luajit.cmd packs>")
    ap.add_argument("--luajit-stamp", action="store_true",
                    help="print luajit_stamp=<the stamp of the LuaJIT library tools/test_luajit.cmd builds>")
    ap.add_argument("--vcvars", action="store_true",
                    help="print vcvars=<the vcvars64.bat the native tests build with> (empty when there is none)")
    ap.add_argument("--gamma-scripts", action="store_true",
                    help="print gamma=<the G.A.M.M.A. scripts the Lua tests read> (empty when there are none)")
    args = ap.parse_args(argv)
    root = pathlib.Path(args.root).resolve()
    marks = pathlib.Path(args.marks) if args.marks else root / "temp" / "gates"
    ci = pathlib.Path(args.ci) if args.ci else root / "engine-ci"
    # the runners' inputs, printed as name=value lines for a cmd "for /f"; several may be asked at once
    if args.lua_stamp or args.lj_vm or args.luajit_stamp or args.vcvars or args.gamma_scripts:
        if args.lua_stamp:
            print(f"lib={lua51_lib(root)}")
            print(f"stamp={lua_stamp(root)}")
        if args.lj_vm:
            print(f"lj_vm={lj_vm_obj(root)}")
        if args.luajit_stamp:
            print(f"luajit_stamp={luajit_stamp(root)}")
        if args.vcvars:
            print(f"vcvars={vcvars() or ''}")
        if args.gamma_scripts:
            print(f"gamma={gamma_scripts() or ''}")
        return 0
    try:
        if args.tests_mark:
            return tests_mark(root, marks, args.tests_mark, pathlib.Path(args.state) if args.state else None,
                              args.native, args.lua)
        if args.exe_source:
            engine = root / "engine"
            source, why = exe_source(engine if (engine / ".git").exists() else None, pathlib.Path(args.exe), ci)
            print(f"exe_source={source or 'none'}")
            for line in why:
                print(f"gates: {line}")
            return 0 if source else 1
        model = None
        if args.layers:
            tools = root / "tools"
            if not (tools / "layers.txt").is_file():
                raise GateError(f"missing input file layers.txt: {tools / 'layers.txt'}")
            names = check_layers.parse_names((tools / "srv_entry.txt").read_text(encoding="utf-8")) \
                if (tools / "srv_entry.txt").is_file() else []
            model = check_layers.build(root, read_layers(tools / "layers.txt"), names)
            if check_layers.main(["--root", str(root)], model=model) != 0:
                print("gates: tools/check_layers.py failed on the tree (above): fix it first")
                return 3
        result = evaluate(root, args.range, args.engine_range, marks, pathlib.Path(args.exe), args.per_commit,
                          args.release, pathlib.Path(args.stand), ci, model)
    except GateError as error:
        print(f"gates: {error}")
        return 2
    for line in result.lines:
        print(line)
    for line in result.failures:
        if line not in result.lines:
            print(line)
    if result.failures:
        print(f"gates: FAIL ({len(result.failures)})")
        return 1
    print("gates: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
