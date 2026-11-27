"""tools/check_gates.py: which layers a change touches and which stand marks it needs (docs/MODES.md section 10).

Fake repositories: a temporary folder with `git init` (the mod) and engine/ inside it (its own repository), the
tools/ inputs of a tiny layer map, an exe file and marks written as the stand runners write them. The holes the
adversarial review found in the gate (temp/modes_review/attack_gates.py and gtrees/: rename, merge, relayer, marks;
srv headers that Ядро includes; server functions that Ядро calls without srv_entry.txt) are rebuilt here as commits,
and so are the second review's (temp/modes_review2/new_attacks.py N1-N4, N10-N14; quoted paths; the stand's tracked
scenarios and HEAD's gamedata: tools/stand/stand_head.py on a fake stand, no game is started) and the third's
(temp/modes_review3/review3.md: the release rule and tests.ok, C5-C12, the stand's leftovers, profiles and folder S1-S3;
engine-ci is a git worktree of the fake engine, its exe a few bytes). The classification tests judge a range with
--per-commit (the early warning); without it a range follows the release rule.
Run: python -m pytest tests\\tools\\test_gates.py -q
"""
import hashlib
import json
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

import check_gates as gates
from conftest import ROOT

LAYERS = """\
stock-list tools/stock_files.txt
stock engine/src/**
core engine/src/xrGame/coop/**
core engine/src/xrCoop/**
srv engine/src/xrGame/coop/coop_mapserver.cpp
srv engine/src/xrGame/coop/coop_levels_xfer.cpp
srv engine/src/xrGame/coop/coop_trunk.cpp
srv engine/src/xrGame/coop/coop_mapserver_stats.cpp
srv engine/src/xrGame/coop/coop_far.cpp
srv engine/src/xrCoop/coop_scope.h
srv engine/src/xrCoop/coop_scope_detail.h
hostplay engine/src/xrCoop/coop_local_link.h
srv engine/src/xrGame/coop/srv/**
srv engine/src/xrCoop/srv/**
dying engine/src/xrCoop/coop_soft_move.h
srv gamedata/scripts/coop_srv_*.script
hostplay gamedata/scripts/coop_hostplay_*.script
srv gamedata/scripts/coop_storyline.script
gate-core gamedata/scripts/coop_storyline.script
"""
ALLOW = """\
# ceiling: 1
L1|engine/src/xrGame/coop/coop_mapserver_mixed.cpp|if (is_map_server()) x();|1
"""
FILES = {
    "engine/src/xrGame/coop/coop_items.cpp": "int items() { return 1; }\n",
    "engine/src/xrGame/coop/coop_mapserver.cpp": "int ms() { return 2; }\n",
    "engine/src/xrGame/coop/coop_mapserver_mixed.cpp": "void f() { if (is_map_server()) x(); }\n",
    "engine/src/xrGame/coop/coop_levels_xfer.cpp": "namespace coop::levels {\nbool online_at_server(u16 id)\n{\n\treturn id != 0;\n}\n}\n",
    "engine/src/xrCoop/coop_local_link.h": "#pragma once\n",
    "engine/src/xrCoop/coop_protocol.h": "constexpr int kProtocolVersion = 32;\n",
    "engine/src/xrCoop/coop_soft_move.h": "#pragma once\n",
    "engine/src/xrGame/Level.cpp": "void CLevel::f() {}\n",
    # a srv header that an Ядро file includes, and one that it includes in turn (compiled into Ядро too)
    "engine/src/xrCoop/coop_scope.h": "#pragma once\n#include \"coop_scope_detail.h\"\ninline bool reaches() { return true; }\n",
    "engine/src/xrCoop/coop_scope_detail.h": "#pragma once\ninline int detail() { return 1; }\n",
    "engine/src/xrGame/coop/coop_router.cpp": "#include \"xrCoop/coop_scope.h\"\n#include \"xrCoop/coop_local_link.h\"\n"
                                              "int route() { return reaches() ? 1 : 0; }\n",
    # server code that runs in the co-op process although srv_entry.txt does not name it: mapserver::host_incoming
    # (the engine's coop_levels.cpp:505) and mapserver_stats_frame (coop_manager.cpp:910)
    "engine/src/xrGame/coop/coop_trunk.cpp": "namespace coop\n{\nnamespace mapserver\n{\nbool host_incoming(int from)\n{\n"
                                             "\treturn from != 0;\n}\n}\n}\n",
    "engine/src/xrGame/coop/coop_levels.cpp": "namespace coop::levels\n{\nbool incoming(int from)\n{\n"
                                              "\treturn mapserver::host_incoming(from);\n}\n}\n",
    "engine/src/xrGame/coop/coop_mapserver_stats.cpp": "namespace coop\n{\nvoid mapserver_stats_frame()\n{\n}\n}\n",
    "engine/src/xrGame/coop/coop_manager.cpp": "namespace coop\n{\nvoid frame()\n{\n\tmapserver_stats_frame();\n}\n}\n",
    # server code that nothing of Ядро reaches
    "engine/src/xrGame/coop/coop_far.cpp": "namespace coop::far\n{\nint far_only() { return 3; }\n}\n",
}
MOD_FILES = {
    "gamedata/scripts/coop_items.script": "function f() end\n",
    "gamedata/scripts/coop_srv_far.script": "function f() end\n",
    "gamedata/scripts/coop_hostplay_menu.script": "function f() end\n",
    "gamedata/scripts/coop_storyline.script": "function f() end\n",
    "gamedata/configs/coop_route_npc.ltx": "[route_scripts]\ncoop_npc_adapters = host\nxr_x = view\n",
    "docs/NOTES.md": "notes\n",
    "tests/test_items.cpp": "TEST(a)\n{\n}\nTEST(b)\n{\n}\n",
    "tests/lua/test_items.lua": "-- t\n",
}


def sh(cwd: Path, *args: str) -> str:
    done = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    return done.stdout.strip()


def write(base: Path, rel: str, text: str) -> None:
    path = base / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def init(repo: Path) -> None:
    sh(repo, "init", "-q", "-b", "main")
    sh(repo, "config", "user.name", "t")
    sh(repo, "config", "user.email", "t@example.invalid")
    sh(repo, "config", "core.autocrlf", "false")
    sh(repo, "config", "core.quotePath", "true")  # git's default: a non-ASCII path is printed quoted (B11)


def commit(repo: Path, message: str) -> str:
    sh(repo, "add", "-A")
    sh(repo, "commit", "-q", "--allow-empty", "-m", message)
    return sh(repo, "rev-parse", "HEAD")


@pytest.fixture
def repos(work):
    root = work / "mod"
    engine = root / "engine"
    engine.mkdir(parents=True)
    init(root)
    init(engine)
    write(root, ".gitignore", "engine/\nengine-ci/\ntemp/\n")
    write(root, "tools/layers.txt", LAYERS)
    write(root, "tools/layers_allow.txt", ALLOW)
    write(root, "tools/srv_entry.txt", "online_at_server\n")
    write(root, "tools/stock_files.txt", "engine/src/xrGame/Level.cpp\n")
    for rel, text in MOD_FILES.items():
        write(root, rel, text)
    for rel, text in FILES.items():
        write(engine, rel[len("engine/"):], text)
    commit(root, "base")
    commit(engine, "base")
    sh(root, "tag", "base")
    sh(engine, "tag", "base")
    stand = work / "stand"
    (stand / "gamedata").mkdir(parents=True)
    write(stand, ".raylink-stand.json", json.dumps({"format": 1, "entries": []}))
    exe = gates.stand_exe(stand)
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b"MZ the stand exe")
    return root, engine, exe


def mark(root: Path, engine: Path, stand_exe: Path, which: str, drop: tuple[str, ...] = (), **override: str) -> None:
    exe = stand_exe
    values = {
        "mode": which,
        "mod_head": sh(root, "rev-parse", "HEAD"),
        "engine_head": sh(engine, "rev-parse", "HEAD"),
        "exe": str(exe),
        "exe_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
        "time": "2026-11-18T14:00:00+05:00",
        "scenarios": ",".join(gates.SCENARIOS[which]),
        "dirty": "0",
        # what the runner deployed and ran: the scenario files and the gamedata of both HEADs (B12, B13)
        "scenarios_sha256": gates.scenarios_digest(root, "HEAD"),
        "gamedata_sha256": gates.gamedata_digest(root, engine, "HEAD", "HEAD"),
        # review 3: the exe is engine-ci's build of engine HEAD (C12), the stand and its profiles (S1-S3)
        "exe_source": sh(engine, "rev-parse", "HEAD"),
        "stand_fingerprint": gates.stand_fingerprint(exe.parent.parent),
        "stand_extra": "0",
        "stand_foreign": "",
        "profile_sha256": gates.profile_digest(root, "HEAD"),
    }
    values.update(override)
    write(root, f"temp/gates/{which}.ok", "".join(f"{k}={v}\n" for k, v in values.items() if k not in drop))


def write_tests_mark(root: Path, engine: Path, drop: tuple[str, ...] = (), **override: str) -> None:
    """temp/gates/tests.ok as tools/run_all_tests.cmd writes it after a clean green run of N and L."""
    values = {"mode": "tests", "mod_head": sh(root, "rev-parse", "HEAD"), "engine_head": sh(engine, "rev-parse", "HEAD"),
              "time": "2026-11-18T14:00:00+05:00", "dirty": "0", "native": "0", "lua": "0"}
    values.update(override)
    write(root, "temp/gates/tests.ok", "".join(f"{k}={v}\n" for k, v in values.items() if k not in drop))


def run(root: Path, exe: Path, capsys, *args: str) -> tuple[int, str]:
    code = gates.main(["--root", str(root), "--exe", str(exe), "--stand", str(exe.parent.parent), *args])
    return code, capsys.readouterr().out


def ci_sync(engine: Path, ci: Path, build: int = 0) -> None:
    """engine-ci as tools/ci_sync.py --committed leaves it: a worktree of the engine with the committed sources of
    engine HEAD copied over (never deleting) and the build number in its raylink_build.h."""
    if not ci.exists():
        sh(engine, "worktree", "add", "-q", "--detach", str(ci), "HEAD")
    for rel, _ in gates.tree_blobs(engine, "HEAD", ["src"]):
        data = subprocess.run(["git", "-C", str(engine), "show", f"HEAD:{rel}"], capture_output=True).stdout
        if rel == gates.CI_BUILD_HEADER:
            data = re.sub(rb"#define RAYLINK_BUILD \d+", b"#define RAYLINK_BUILD %d" % build, data)
        target = ci / rel
        if not target.is_file() or target.read_bytes() != data:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)


def ci_exe(ci: Path, exe: Path, data: bytes = b"MZ the stand exe") -> None:
    """The build: engine-ci's exe written after its sources; the stand's exe is a copy of it."""
    built = ci.joinpath(*gates.CI_EXE)
    built.parent.mkdir(parents=True, exist_ok=True)
    built.write_bytes(data)
    exe.write_bytes(data)
    later = time.time() + 120
    os.utime(built, (later, later))


def ci_build(root: Path, engine: Path, exe: Path) -> Path:
    ci = root / "engine-ci"
    ci_sync(engine, ci)
    ci_exe(ci, exe)
    return ci


def required(out: str) -> str:
    return out.split("required:", 1)[1].splitlines()[0]


# --- classification ---------------------------------------------------------------------------------------------------

@pytest.mark.parametrize(("path", "layer", "why"), [
    ("engine/src/xrGame/coop/coop_items.cpp", "core", "core"),
    ("engine/src/xrGame/coop/coop_mapserver.cpp", "srv", "srv"),
    ("engine/src/xrCoop/coop_local_link.h", "hostplay", "hostplay"),
    ("engine/src/xrGame/Level.cpp", "core", "stock"),
    ("engine/src/xrGame/ui/UIRayPanel.cpp", "core", "core"),  # a new file of ours outside the coop folders
    ("engine/src/xrCoop/coop_soft_move.h", "core", "dying"),
    ("engine/src/xrCoop/coop_protocol.h", "core", "protocol"),
    ("engine/src/xrGame/coop/coop_mapserver_mixed.cpp", "core", "allow-list"),
    ("engine/src/xrGame/coop/coop_levels_xfer.cpp", "core", "entry point"),
    ("gamedata/scripts/coop_storyline.script", "core", "H4"),
    ("gamedata/scripts/coop_srv_far.script", "srv", "srv"),
    ("gamedata/scripts/coop_hostplay_menu.script", "hostplay", "hostplay"),
    ("gamedata/scripts/coop_items.script", "core", "core"),
    ("docs/NOTES.md", "none", "outside"),
    ("tests/test_items.cpp", "none", "outside"),
    ("tools/package.ps1", "none", "outside"),
    # the engine's product is its sources and its gamedata: README or CI edits need no stand
    ("engine/README.md", "none", "outside"),
    ("engine/.github/workflows/build.yml", "none", "outside"),
    ("engine/gamedata/scripts/axr_main.script", "core", "core"),
    # review 3, C5: the facade and its two layers decide in which process when_srv code runs
    ("gamedata/scripts/coop_mode.script", "core", "when_srv"),
    ("gamedata/scripts/coop_srv_mode.script", "core", "when_srv"),
    ("gamedata/scripts/coop_hostplay_mode.script", "core", "when_srv"),
    ("tools/run_all_tests.cmd", "core", "test runner"),
])
def test_classify(repos, path, layer, why):
    root, _, _ = repos
    layers = gates.read_layers(root / "tools/layers.txt")
    got = gates.classify(path, layers, gates.allow_paths(root / "tools/layers_allow.txt"),
                         gates.entry_files(root, ["online_at_server"]), lambda p: ("", ""))
    assert got[0] == layer and why in got[1], got


@pytest.mark.parametrize("name", ["tools/layers.txt", "tools/layers_allow.txt", "tools/srv_entry.txt",
                                  "tools/persisted_keys.txt", "tools/stock_files.txt", "tools/check_layers.py",
                                  "tools/check_gates.py", "tools/release.py", "tools/stand_common.ps1",
                                  "tools/stand_hostplay.ps1", "tools/stand_srv.ps1",
                                  # B10: the co-op test runners; B12: the stand's scenarios and probes
                                  "tools/test_lua.cmd", "tools/build_tests.cmd", "tests/lua/run_all.lua",
                                  "tools/ded_check.ps1", "tools/stand/carry_group.ps1", "tools/stand/run_guarded.ps1",
                                  "tools/stand/coop_zz_squads.script", "tools/stand/stand_head.py",
                                  # round 5: stand_head writes into the stand through it (R21)
                                  "tools/mo2_stand.py"])
def test_lists_and_checkers_are_core(repos, name):
    # item 3: a one-line list edit could turn an Ядро file into srv; the checkers decide what a change needs
    root, _, _ = repos
    got = gates.classify(name, gates.read_layers(root / "tools/layers.txt"), set(), set(), lambda p: ("", ""))
    assert got[0] == "core", got


ROUTE_BASE = "[route_callbacks_forced]\nsave_state = host\n[route_scripts]\ncoop_npc_adapters = host\nxr_x = view\n"


@pytest.mark.parametrize(("new", "neutral"), [
    (ROUTE_BASE.replace("coop_npc_adapters = host", "coop_npc_adapters = level"), True),   # a host <-> level swap
    (ROUTE_BASE.replace("xr_x = view", "xr_x = view ; a comment"), True),                    # the same data
    (ROUTE_BASE.replace("xr_x = view", "xr_x = owner"), False),                              # another value
    (ROUTE_BASE + "xr_y = level\n", False),                                                  # a key added
    # review 3, C10: the forced callback route removed and the key added under [route_scripts] as `level`: the lines
    # still pair host <-> level, but the key moved to another section
    ("[route_callbacks_forced]\n[route_scripts]\nsave_state = level\ncoop_npc_adapters = host\nxr_x = view\n", False),
    (ROUTE_BASE.replace("[route_scripts]", "[route_scripts]:base"), False),                   # a parent added
])
def test_route_table_is_read_as_data(new, neutral):
    assert gates.route_neutral(ROUTE_BASE, new) is neutral


# --- the working tree ---------------------------------------------------------------------------------------------------

def test_clean_tree_needs_nothing(repos, capsys):
    root, _, exe = repos
    code, out = run(root, exe, capsys)
    assert code == 0, out
    assert "required: nothing" in out


def test_docs_only_needs_nothing(repos, capsys):
    root, _, exe = repos
    write(root, "docs/NOTES.md", "more\n")
    code, out = run(root, exe, capsys)
    assert code == 0, out


def test_uncommitted_core_change_needs_both_marks_and_a_commit(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 2; }\n")
    mark(root, engine, exe, "hostplay")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys)
    assert code == 1, out
    assert "required: hostplay.ok, srv.ok" in out
    assert "uncommitted product file" in out


def test_staged_rename_of_core_to_srv_counts_the_old_path(repos, capsys):
    # item 1 in the working tree: git diff --no-renames lists the deleted Ядро path
    root, _, exe = repos
    sh(root, "mv", "gamedata/scripts/coop_items.script", "gamedata/scripts/coop_srv_items.script")
    code, out = run(root, exe, capsys)
    assert "core     gamedata/scripts/coop_items.script" in out, out
    assert required(out).startswith(" hostplay.ok, srv.ok"), out


# --- committed ranges and the marks -----------------------------------------------------------------------------------

def test_srv_commit_needs_the_server_mark(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 3; }\n")
    commit(engine, "srv fix")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "required: srv.ok, unchanged co-op tests" in out
    assert "srv.ok missing" in out
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out
    assert "srv.ok OK" in out and "co-op tests 3 -> 3 (unchanged)" in out


def test_mark_of_other_ids_or_other_exe_does_not_count(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 3; }\n")
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv", engine_head="0" * 40)
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "engine 00000000 !=" in out, out
    mark(root, engine, exe, "srv")
    exe.write_bytes(b"MZ another build")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "exe " in out and "does not count" in out, out


@pytest.mark.parametrize(("drop", "override", "why"), [
    (("mode",), {}, "mode missing"),                                  # a mark without mode=
    ((), {"mode": "hostplay"}, "mode hostplay"),                      # the other runner's mark under this name
    ((), {"dirty": "7"}, "dirty=7"),                                  # the stand ran an exe of uncommitted code
    (("dirty",), {}, "dirty=missing"),
    ((), {"scenarios": "ded_check"}, "base_server, carry_server, taskboard_ws, phantoms_server, "
                                 "allymark_server, companions_server, weather_server, cover_server, "
                                 "ms_crash_server, save_handover_server, creator10_server, "
                                 "feed_server, vehicle_server, progress_server did not run"),  # a part
    (("scenarios",), {}, "did not run"),
    # B12: the scenario files that ran are HEAD's (tools/stand is tracked; a relaxed check is a change of HEAD)
    (("scenarios_sha256",), {}, "scenarios_sha256 missing"),
    ((), {"scenarios_sha256": "0" * 64}, "scenario files 00000000 !="),
    # B13: the stand ran HEAD's gamedata (the runner deploys it first)
    (("gamedata_sha256",), {}, "gamedata_sha256 missing"),
    ((), {"gamedata_sha256": "0" * 64}, "gamedata 00000000 !="),
    # review 3, C12: the stand's exe was shown to be engine-ci's build of engine HEAD
    (("exe_source",), {}, "exe_source=missing"),
    ((), {"exe_source": "none"}, "exe_source=none"),
    ((), {"exe_source": "0" * 40}, "exe_source=00000000"),
    # S1: no leftover of our layers on the stand
    (("stand_extra",), {}, "stand_extra=missing"),
    ((), {"stand_extra": "1"}, "stand_extra=1"),
    # S2: the profiles ran with HEAD's mode cvars
    (("profile_sha256",), {}, "profile_sha256 missing"),
    ((), {"profile_sha256": "0" * 64}, "profile cvars 00000000 !="),
    # S3: a run on another folder with the same exe, or a stand made again or changed since the run
    ((), {"exe": r"D:\some\other\stand\bin\AnomalyCoopDX11AVX.exe"}, "not the stand's"),
    ((), {"stand_fingerprint": "0" * 64}, "the stand changed since the run"),
    (("stand_fingerprint",), {}, "stand_fingerprint missing"),
])
def test_mark_without_mode_dirty_or_partial_does_not_count(repos, capsys, drop, override, why):
    # item 6
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 3; }\n")
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv", drop, **override)
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "srv.ok does not count" in out and why in out, out


@pytest.mark.parametrize(("mode", "scenario", "other_scenario"), [
    ("hostplay", "vehicle_group", "vehicle_server"),
    ("srv", "vehicle_server", "vehicle_group"),
    ("hostplay", "progress_group", "progress_server"),
    ("srv", "progress_server", "progress_group"),
])
def test_scenario_is_required_in_its_own_mode(work, mode, scenario, other_scenario):
    mark_path = work / f"{mode}.ok"
    mod_head, engine_head, exe_hash = "a" * 40, "b" * 40, "c" * 64
    fields = (f"mode={mode}\nmod_head={mod_head}\nengine_head={engine_head}\nexe_source={engine_head}\n"
              f"exe_sha256={exe_hash}\ndirty=0\nstand_extra=0\n")
    other_runs = [name for name in gates.SCENARIOS[mode] if name not in (scenario, other_scenario)]

    for ran in (other_runs, [*other_runs, other_scenario]):
        mark_path.write_text(fields + f"scenarios={','.join(ran)}\n", encoding="utf-8")
        ok, reason = gates.check_mark(mode, work, mod_head, engine_head, exe_hash)
        assert not ok and f"{scenario} did not run" in reason, reason

    mark_path.write_text(fields + f"scenarios={','.join([*other_runs, scenario])}\n", encoding="utf-8")
    ok, reason = gates.check_mark(mode, work, mod_head, engine_head, exe_hash)
    assert ok, reason


def test_stand_runners_list_the_scenarios_the_gate_demands():
    # the marks name the scenarios the runner ran; the gate demands every scenario of tools/stand_<mode>.ps1
    for mode, names in gates.SCENARIOS.items():
        text = (ROOT / "tools" / f"stand_{mode}.ps1").read_text(encoding="utf-8")
        assert tuple(re.findall(r"@\{ Name = '([^']+)'", text)) == names, mode


@pytest.mark.parametrize(("mode", "own", "foreign"), [
    ("hostplay", "progress_group", "progress_server"),
    ("srv", "progress_server", "progress_group"),
])
def test_progress_scenario_runs_only_in_its_own_stand(mode, own, foreign):
    text = (ROOT / "tools" / f"stand_{mode}.ps1").read_text(encoding="utf-8")
    names = re.findall(r"@\{ Name = '([^']+)'", text)
    assert names.count(own) == 1 and foreign not in names


@pytest.mark.parametrize("name", ["progress_group", "progress_server"])
def test_progress_stand_verdict_requires_correlated_evidence(name, work):
    # Replay the blind review's log probe against the real judge, with no game or stand.
    script = ROOT / "tools" / "stand" / f"{name}.ps1"
    replay = work / "replay.ps1"
    replay.write_text(r"""
param($Path, $Name)
$ErrorActionPreference = 'Stop'
$tokens = $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$main = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and
    $n.Body.Extent.Text.Contains("Set-ProgressStep 'walk'") }, $false)
$statements = $main.Body.Statements
$start = ($statements | Where-Object { $_.Extent.Text.Contains('client ready map=') } | Select-Object -First 1).Extent.StartOffset
$judge = [scriptblock]::Create($ast.Extent.Text.Substring($start, $main.Body.Extent.EndOffset - 1 - $start))
. ([scriptblock]::Create(($ast.Extent.Text -split '\r?\n' | Where-Object { $_ -match '^\$mark = ' }) -join "`n"))
function Assert-ProgressHealthy {}
function Start-Sleep {}
function Add-Log($File, $Line) { Add-Content -LiteralPath $File -Value $Line -Encoding Ascii }
function Wait-ProgressLine([string[]]$Files, [string]$Pattern, [int]$Seconds, [int]$After = 0) {
    if ($Pattern.Contains('progress_rank') -and $Seconds -ne 30) { throw 'rank timeout must be 30 seconds' }
    $hit = Select-String -LiteralPath $Files -Pattern $Pattern | Where-Object LineNumber -gt $After | Select-Object -First 1
    if ($hit) { return $hit }
    throw "waiting for $Pattern"
}
function Set-ProgressStep([string]$Step) {
    switch -Regex ($Step) {
        '^walk$' { Add-Log $clientLog '[progress-stand] client walked 15 steps, 300.0 m' }
        '^spawn$' { Add-Log $authority '[progress-stand] corpse map=l01_escape id=123' }
        '^search 123$' {
            $delta = if ($case -eq 'allowance') { '25.000000' } else { '45.000000' }
            Add-Log $clientLog "[progress-stand] client searched id=123 xp=56.000000 delta=$delta"
            $meters = if ($case -eq 'no_steps') { '0.0' } else { '295.0' }
            $searches = if ($case -eq 'no_search') { 0 } else { 1 }
            Add-Log $hostLog "[progress-stand] keeper facts peer=4 character=42 step_m=$meters corpse_search=$searches rank=veteran"
        }
        '^honest 56\.000000$' {
            Add-Log $clientLog '[progress-stand] client honest report xp=56.000000'
            if ($case -eq 'late_honest_warning') {
                Add-Log $hostLog '[progress-stand] honest accepted peer=4 character=42 xp=56.000000 checked=40 failed=1 refused=0'
            } else {
                Add-Log $hostLog '[progress-stand] honest accepted peer=4 character=42 xp=56.000000 checked=40 failed=0 refused=0'
            }
        }
        '^skills$' {
            if ($case -eq 'late_honest_warning') {
                Add-Log $hostLog '[coop-trust] ! progress_skills: progress check failed: survival: budget (would be refused: let through, 1 of 1 failed)'
            }
            Add-Log $clientLog '[progress-stand] client added 5000 scavenging XP and reported'
            Add-Log $hostLog '[coop-trust] ! progress_skills: progress check failed: scavenging: budget (would be refused: let through, 1 of 1 failed)'
            $delta = if ($case -eq 'wrong_xp_delta') { 4999 } else { 5000 }
            $peer = if ($case -eq 'wrong_skill_peer') { 7 } else { 4 }
            Add-Log $hostLog "[progress-stand] skills budget failed peer=$peer character=42 delta=$delta"
        }
        '^rank$' {
            Add-Log $clientLog '[progress-stand] client added 5000 rank'
            $peer = if ($case -eq 'wrong_rank_peer') { 7 } else { 4 }
            $character = if ($case -eq 'wrong_rank_character') { 43 } else { 42 }
            Add-Log $hostLog "[coop-trust] progress_rank would refuse: peer $peer, character ${character}: rank 0 -> 5000 (+5000), budget 25: let through (1 of 1 failed)"
        }
        default { throw "unexpected command $Step" }
    }
}
$hostLog = Join-Path $PSScriptRoot 'keeper.log'
$worldLog = $hostLog
$clientLog = Join-Path $PSScriptRoot 'client.log'
$mapLogs = @(Join-Path $PSScriptRoot 'map.log')
$authority = if ($Name -eq 'progress_server') { $mapLogs[0] } else { $hostLog }
foreach ($case in 'honest', 'allowance', 'no_steps', 'no_search', 'late_honest_warning', 'wrong_xp_delta',
                  'wrong_skill_peer', 'wrong_rank_peer', 'wrong_rank_character') {
    Set-Content -LiteralPath $hostLog '[progress-stand] keeper ready peer=4 character=42' -Encoding Ascii
    Set-Content -LiteralPath $clientLog '[progress-stand] client ready map=l01_escape' -Encoding Ascii
    Set-Content -LiteralPath $mapLogs[0] '' -Encoding Ascii
    try { $null = . $judge; Write-Output "$case accepted" }
    catch { Write-Output "$case rejected: $_" }
}
""", encoding="utf-8")
    result = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(replay),
                             str(script), name], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0 and not result.stderr, result.stdout + result.stderr
    verdicts = [line for line in result.stdout.splitlines() if re.match(r"^\w+ (accepted|rejected:)", line)]
    assert len(verdicts) == 9 and verdicts[0] == "honest accepted", verdicts
    assert all(" rejected: " in line for line in verdicts[1:]), verdicts


PROGRESS_HEALTH_REPLAY = r"""
param($Path, $Root)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'tools\stand_common.ps1')
$tokens = $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$keeper = Join-Path $PSScriptRoot 'keeper.log'
$clientLog = Join-Path $PSScriptRoot 'client.log'
$worldLog = $hostLog = $keeper
$logs = @($keeper, $clientLog)
$world = $client = $hostGame = $null
$assignments = '^\$(mark|trust|badLine|keeperLog|expectedTrust|expectFrom) = '
. ([scriptblock]::Create(($ast.Extent.Text -split '\r?\n' | Where-Object { $_ -match $assignments }) -join "`n"))
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($f.Name -in 'Test-ProgressExpected', 'Assert-ProgressHealthy', 'Write-ProgressExcerpt') { . ([scriptblock]::Create($f.Extent.Text)) }
}
$ready = '[progress-stand] keeper ready peer=4 character=42'
$honest = '[progress-stand] honest accepted peer=4 character=42 xp=72.000000 checked=262 failed=0 refused=0'
$deliberate = '[coop-trust] ! progress_skills: progress check failed: scavenging: budget (would be refused: let through, 1 of 116 failed)'
$cases = [ordered]@{
    deliberate = @{ Keeper = @($ready, $honest, $deliberate); From = 2 }
    timestamped = @{ Keeper = @($ready, $honest, "[08:13:16.700] $deliberate"); From = 2 }
    before_skills = @{ Keeper = @($ready, $honest, $deliberate); From = 0 }
    during_honest = @{ Keeper = @($ready, $deliberate, $honest); From = 3 }
    second_failure = @{ Keeper = @($ready, $honest, $deliberate.Replace('1 of 116', '2 of 117')); From = 2 }
    other_skill = @{ Keeper = @($ready, $honest, $deliberate.Replace('scavenging', 'survival')); From = 2 }
    refused = @{ Keeper = @($ready, $honest, $deliberate.Replace('would be refused: let through', 'refused')); From = 2 }
    client_log = @{ Keeper = @($ready, $honest); Client = @('a', 'b', 'c', $deliberate); From = 2 }
}
foreach ($case in $cases.Keys) {
    Set-Content -LiteralPath $keeper -Value $cases[$case].Keeper -Encoding Ascii
    $clientLines = if ($cases[$case].Client) { $cases[$case].Client } else { @('[progress-stand] client ready map=l01_escape') }
    Set-Content -LiteralPath $clientLog -Value $clientLines -Encoding Ascii
    $expectFrom = $cases[$case].From
    try { Assert-ProgressHealthy; Write-Output "$case ok" } catch { Write-Output "$case flagged" }
    if ($case -in 'deliberate', 'second_failure') {
        $excerpt = @(Write-ProgressExcerpt $keeper 6>&1 | ForEach-Object { "$_" })
        $flagged = @($excerpt | Where-Object { Test-StandErrorLine $_ }).Count
        $kept = @($excerpt | Where-Object { $_ -match '^\[coop-trust\] progress_skills: ' }).Count
        Write-Output "excerpt $case flagged=$flagged kept=$kept"
    }
}
"""


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
@pytest.mark.parametrize("name", ["progress_group", "progress_server"])
def test_progress_stand_expects_only_its_own_budget_failure(name, work):
    # b57g Server stand (2026-11-21): the probe's deliberate +5000 scavenging report (step 'skills') makes the keeper's
    # log-only check write "[coop-trust] ! progress_skills: ... scavenging: budget", which the stand's error pattern flags.
    # That one line is expected: the keeper's first progress_skills failure, after the honest report was accepted. Any
    # other trust failure, a second one, a refusal or the line in another log still fails the scenario.
    script = ROOT / "tools" / "stand" / f"{name}.ps1"
    replay = work / "health.ps1"
    replay.write_text(PROGRESS_HEALTH_REPLAY, encoding="utf-8")
    result = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(replay),
                             str(script), str(ROOT)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0 and not result.stderr, result.stdout + result.stderr
    verdicts = dict(line.split(" ", 1) for line in result.stdout.splitlines() if re.match(r"^\w+ (ok|flagged)$", line))
    assert verdicts == {"deliberate": "ok", "timestamped": "ok", "before_skills": "flagged", "during_honest": "flagged",
                        "second_failure": "flagged", "other_skill": "flagged", "refused": "flagged",
                        "client_log": "flagged"}, result.stdout
    # the runner judges the excerpt: the expected line is kept without its "!", a second failure stays an error line
    assert "excerpt deliberate flagged=0 kept=1" in result.stdout, result.stdout
    assert "excerpt second_failure flagged=1 kept=0" in result.stdout, result.stdout


# A scenario of tools/stand that no runner runs is one the gate never demands. Only these are run by no gate runner, each
# with the reason; any other scenario belongs to tools/stand_<mode>.ps1.
NOT_A_GATED_SCENARIO = {
    "soak_hour_server": "one hour: weekly batch, run alone through tools\\stand\\run_guarded.ps1",
    "perf": "a measurement (docs/MEASURE.md), run by hand before and after an optimization: it measures, it judges nothing",
    "run_guarded": "the guard every scenario runs under (tools/stand_common.ps1 Invoke-Scenario)",
    "hybrid_save": "the hybrid's save scenario: the hybrid is removed (docs/plans/2026-11-18-two-modes.md), so is it",
    "stand_dump": "a helper scenarios dot-source (the dump of a process that hangs), not a scenario",
}


def test_every_stand_scenario_is_run_by_a_runner_of_its_mode():
    ran = {}
    for mode in gates.SCENARIOS:
        text = (ROOT / "tools" / f"stand_{mode}.ps1").read_text(encoding="utf-8")
        for script in re.findall(r"Script = '([^']+)'", text):
            ran[Path(script).stem] = mode
    scenarios = {p.stem for p in (ROOT / "tools" / "stand").glob("*.ps1")}
    assert scenarios - set(ran) == set(NOT_A_GATED_SCENARIO), "a scenario no runner runs: add it to " \
        "tools/stand_<mode>.ps1 and check_gates.SCENARIOS (its mode: *_group co-op, *_server the server)"
    for stem, mode in ran.items():
        if stem.endswith("_group"):
            assert mode == "hostplay", stem
        elif stem.endswith("_server"):
            assert mode == "srv", stem


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
def test_stand_dirty_count_includes_untracked_product_files(work):
    # item 6: a new .script deployed to the stand but never committed makes the mark dirty
    root = work / "mod"
    (root / "tools").mkdir(parents=True)
    (root / "engine").mkdir()
    shutil.copy2(ROOT / "tools" / "stand_common.ps1", root / "tools" / "stand_common.ps1")
    for repo in (root, root / "engine"):
        init(repo)
    write(root, ".gitignore", "engine/\n")
    write(root, "gamedata/scripts/coop_items.script", "function f() end\n")
    write(root / "engine", "src/x.cpp", "int x;\n")
    commit(root, "base")
    commit(root / "engine", "base")
    write(root, "gamedata/scripts/coop_new.script", "function g() end\n")  # untracked
    write(root / "engine", "src/y.cpp", "int y;\n")                       # untracked
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                           f". '{root / 'tools' / 'stand_common.ps1'}'; Get-DirtyProductCount"],
                          capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    assert done.stdout.strip().splitlines()[-1] == "2", done.stdout + done.stderr


def test_core_commit_needs_both_marks(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/Level.cpp", "void CLevel::f() { coop::x(); }\n")  # a stock file
    commit(engine, "stock hook")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "hostplay.ok missing" in out
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out


def test_edit_in_an_allow_listed_srv_file_is_core(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver_mixed.cpp", "void f() { if (is_map_server()) y(); }\n")
    commit(engine, "under an allowed line")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "hostplay.ok missing" in out, out
    assert "has allow-list entries (H9)" in out


def test_hostplay_commit_needs_the_coop_mark(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_hostplay_menu.script", "function g() end\n")
    commit(root, "menu")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "required: hostplay.ok" in out and "srv.ok" not in required(out), out
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out


def test_one_commit_with_hostplay_and_srv_is_refused(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_hostplay_menu.script", "function g() end\n")
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    commit(root, "both modes")
    mark(root, engine, exe, "hostplay")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "split the commit" in out


def test_srv_change_that_moves_the_coop_test_count_fails(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/test_items.cpp", "TEST(a)\n{\n}\n")  # a co-op test removed with a server change
    commit(root, "srv and a test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "co-op tests 3 -> 2" in out and "removed TEST(b)" in out


def test_srv_change_that_swaps_a_coop_test_fails(repos, capsys):
    # item 7: one co-op test removed and another added keeps the count; the set of names moved
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/test_items.cpp", "TEST(a)\n{\n}\nTEST(c)\n{\n}\n")
    commit(root, "srv and a swapped test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "co-op tests 3 -> 3" in out and "removed TEST(b)" in out and "added TEST(c)" in out
    # a server test of its own (test_srv_*) may come with a server change
    sh(root, "tag", "swap")
    sh(engine, "tag", "swap")
    write(root, "tests/test_srv_far.cpp", "TEST(far)\n{\n}\n")
    write(root, "gamedata/scripts/coop_srv_far.script", "function h() end\n")
    commit(root, "srv and its own test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "swap..HEAD", "--per-commit")
    assert code == 0, out


def test_route_swap_commit_is_srv_and_other_route_edit_is_core(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_scripts]\ncoop_npc_adapters = level\nxr_x = view\n")
    commit(root, "swap")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out
    sh(root, "tag", "swap")
    sh(engine, "tag", "swap")
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_scripts]\ncoop_npc_adapters = level\nxr_x = owner\n")
    commit(root, "owner")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "swap..HEAD", "--per-commit")
    assert code == 1 and "route table (H6)" in out and "hostplay.ok missing" in out, out


def test_output_hides_long_hex(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 5; }\n")
    commit(engine, "core")
    mark(root, engine, exe, "srv")
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out
    assert not re.search(r"[0-9a-f]{32}", out), out


def test_bad_range_is_exit_2(repos, capsys):
    root, _, exe = repos
    code, out = run(root, exe, capsys, "nosuchtag..HEAD")
    assert code == 2, out


def test_engine_snapshot_tag_uses_its_source_tree(repos, capsys):
    # the engine's release tag points to a public snapshot (its tree on the public main, "Source tree: <id>"), not to a
    # commit of the source branch: the range starts at that source id, not at the root of the history
    root, engine, exe = repos
    source = sh(engine, "rev-parse", "HEAD")
    tree = sh(engine, "rev-parse", "HEAD^{tree}")
    snapshot = sh(engine, "commit-tree", tree, "-m", "RayLink Engine dev 1\n\nSource tree: " + source)
    sh(engine, "tag", "rel", snapshot)
    sh(root, "tag", "rel")
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 4; }\n")
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "rel..HEAD", "--per-commit")
    assert code == 0, out
    assert "1 commit(s)" in out and "coop_items.cpp" not in out


# --- the review's gate holes (temp/modes_review/attack_gates.py, gtrees/) --------------------------------------------

def test_rename_of_core_to_srv_is_core(repos, capsys):
    # item 1 (gtrees/rename): git mv coop_items.script coop_srv_items.script plus an edit was srv-only
    root, engine, exe = repos
    sh(root, "mv", "gamedata/scripts/coop_items.script", "gamedata/scripts/coop_srv_items.script")
    write(root, "gamedata/scripts/coop_srv_items.script", "function f() end\nfunction extra() end\n")
    commit(root, "rename")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "core     gamedata/scripts/coop_items.script" in out and "hostplay.ok missing" in out, out


def test_merge_that_edits_core_is_core(repos, capsys):
    # item 2 (gtrees/merge): the side branches touch srv only, the merge's own resolution edits Ядро. A merge counts
    # with its diff against its first parent (--diff-merges=first-parent)
    root, engine, exe = repos
    sh(root, "checkout", "-q", "-b", "side")
    write(root, "gamedata/scripts/coop_srv_a.script", "x = 1\n")
    commit(root, "side srv")
    sh(root, "checkout", "-q", "main")
    write(root, "gamedata/scripts/coop_srv_b.script", "y = 1\n")
    commit(root, "main srv")
    subprocess.run(["git", "merge", "--no-commit", "-q", "side"], cwd=root, capture_output=True)
    write(root, "gamedata/scripts/coop_items.script", "function f() return false end\n")
    commit(root, "merge side")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "(merge): core     gamedata/scripts/coop_items.script" in out and "hostplay.ok missing" in out, out


def test_merge_of_separate_hostplay_and_srv_commits_is_not_refused(repos, capsys):
    # a merge brings both layers at once against its first parent; its side commits are checked one by one
    root, engine, exe = repos
    sh(root, "checkout", "-q", "-b", "side")
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    commit(root, "srv")
    write(root, "gamedata/scripts/coop_hostplay_menu.script", "function g() end\n")
    commit(root, "hostplay")
    sh(root, "checkout", "-q", "main")
    write(root, "docs/NOTES.md", "main\n")
    commit(root, "docs")
    sh(root, "merge", "-q", "--no-edit", "side")
    mark(root, engine, exe, "srv")
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert "split the commit" not in out, out
    assert code == 0, out


def test_layers_txt_reclassification_is_core(repos, capsys):
    # item 3 (gtrees/relayer): a row `srv gamedata/scripts/coop_items.script` and an edit of it in one commit
    root, engine, exe = repos
    write(root, "tools/layers.txt", LAYERS + "srv gamedata/scripts/coop_items.script\n")
    write(root, "gamedata/scripts/coop_items.script", "function f() return false end\n")
    commit(root, "relayer")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "core     tools/layers.txt" in out and "hostplay.ok missing" in out, out


@pytest.mark.parametrize(("path", "text", "why"), [
    ("src/xrCoop/coop_scope.h", "#pragma once\n#include \"coop_scope_detail.h\"\ninline bool reaches() { return false; }\n",
     "included by engine/src/xrGame/coop/coop_router.cpp"),
    ("src/xrCoop/coop_scope_detail.h", "#pragma once\ninline int detail() { return 2; }\n",
     "included by engine/src/xrGame/coop/coop_router.cpp (through engine/src/xrCoop/coop_scope.h)"),
    ("src/xrCoop/coop_local_link.h", "#pragma once\n// changed\n", "included by engine/src/xrGame/coop/coop_router.cpp"),
])
def test_srv_or_hostplay_header_that_core_includes_is_core(repos, capsys, path, text, why):
    # item 4: its inline code and macros are compiled into Ядро
    root, engine, exe = repos
    write(engine, path, text)
    commit(engine, "header")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert why in out and "hostplay.ok missing" in out, out


@pytest.mark.parametrize(("path", "text", "why"), [
    ("src/xrGame/coop/coop_trunk.cpp", "namespace coop\n{\nnamespace mapserver\n{\nbool host_incoming(int from)\n{\n"
     "\treturn from > 1;\n}\n}\n}\n", "defines mapserver::host_incoming, called from engine/src/xrGame/coop/coop_levels.cpp:5"),
    ("src/xrGame/coop/coop_mapserver_stats.cpp", "namespace coop\n{\nvoid mapserver_stats_frame()\n{\n\tint n = 0;\n}\n}\n",
     "defines coop::mapserver_stats_frame, called from engine/src/xrGame/coop/coop_manager.cpp:5"),
])
def test_srv_function_called_from_core_is_core_without_srv_entry(repos, capsys, path, text, why):
    # item 5: srv_entry.txt does not name host_incoming or mapserver_stats_frame; the call index finds them
    root, engine, exe = repos
    write(engine, path, text)
    commit(engine, "srv code that runs in co-op")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert why in out and "hostplay.ok missing" in out, out


def test_srv_file_nothing_of_core_reaches_stays_srv(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_far.cpp", "namespace coop::far\n{\nint far_only() { return 4; }\n}\n")
    commit(engine, "far")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out
    assert "srv      engine/src/xrGame/coop/coop_far.cpp" in out


def test_real_srv_entry_names_the_two_co_op_paths():
    # item 5: the two server functions the review found running in the co-op process are listed
    names = gates.check_layers.parse_names((ROOT / "tools" / "srv_entry.txt").read_text(encoding="utf-8"))
    assert "mapserver::host_incoming" in names and "mapserver_stats_frame" in names


# --- the second review (temp/modes_review2): srv code that runs in the co-op process, tests, quoting, the stand -----

def setup_more(root: Path, engine: Path, mod_files: dict, engine_files: dict, stock: tuple[str, ...] = ()) -> None:
    """More files in both repositories, committed and tagged b2 (the base of the attack's later srv-only edit)."""
    for rel, text in mod_files.items():
        write(root, rel, text)
    for rel, text in engine_files.items():
        write(engine, rel[len("engine/"):], text)
    if stock:
        path = root / "tools" / "stock_files.txt"
        path.write_text(path.read_text(encoding="utf-8") + "".join(s + "\n" for s in stock), encoding="utf-8", newline="\n")
    commit(root, "setup")
    commit(engine, "setup")
    sh(root, "tag", "b2")
    sh(engine, "tag", "b2")


ALIFE = "engine/src/xrGame/alife_switch_manager.cpp"
KEEPER_XFER = ("#include \"xrCoop/srv/coop_keeper.h\"\nnamespace coop::levels {\nbool online_at_server(u16 id)\n{\n"
               "\treturn id != 0 && keeper_marked() != 0;\n}\n}\n")
POLICY_H = "#pragma once\nnamespace coop\n{\nstruct FarPolicy\n{\n\tbool keep_online(u16 id) const;\n};\nFarPolicy& far_policy();\n}\n"
POLICY_CPP = ("#include \"coop_far_policy.h\"\nnamespace coop\n{\nbool may_switch_offline(u16 id)\n{\n"
              "\treturn !far_policy().keep_online(id);\n}\n}\n")
POLICY_SRV = "#include \"../coop_far_policy.h\"\nnamespace coop\n{\nbool FarPolicy::keep_online(u16 id) const\n{\n\treturn false;\n}\n}\n"
HOOKS_H = "#pragma once\nnamespace coop::hooks\n{\nusing SkipFn = bool (*)(u16);\nvoid set_skip(SkipFn fn);\n}\n"
SKIP_SRV = ("#include \"../coop_hooks.h\"\nnamespace coop::srvfar\n{\nstatic bool far_skip(u16 id)\n{\n\treturn false;\n}\n"
            "static const bool registered = (coop::hooks::set_skip(&far_skip), true);\n}\n")
FARREAD = "extern bool g_far_world;\nnamespace coop::farread\n{\nbool may_give(u16 id)\n{\n\treturn !g_far_world && id;\n}\n}\n"
WORLD_SRV = "bool g_far_world = false;\nnamespace coop::srvworld\n{\nint n() { return 1; }\n}\n"
FARCALL = ("namespace coop::farcall\n{\nbool keep(lua_State* L)\n{\n\tlua_getglobal(L, \"coop_srv_far\");\n"
           "\treturn lua_toboolean(L, -1) != 0;\n}\n}\n")


@pytest.mark.parametrize(("case", "mod_files", "engine_files", "stock", "edit", "why"), [
    # N1 / B1: a srv header that only a REACHED srv .cpp includes (coop_levels_keeper.h under online_at_server, which
    # stock alife_switch_manager.cpp calls in the co-op host): the reach goes on from every reached srv file
    ("N1", {}, {"engine/src/xrCoop/srv/coop_keeper.h": "#pragma once\ninline int keeper_marked() { return 0; }\n",
                "engine/src/xrGame/coop/coop_levels_xfer.cpp": KEEPER_XFER,
                ALIFE: "void CALifeSwitchManager::f(u16 id)\n{\n\tif (coop::levels::online_at_server(id)) return;\n}\n"},
     (ALIFE,), ("engine/src/xrCoop/srv/coop_keeper.h", "#pragma once\ninline int keeper_marked() { return 1; }\n"),
     "included by the reached engine/src/xrGame/coop/coop_levels_xfer.cpp"),
    # N2 / B2: a srv file defines a member of a class only Ядро defines; Ядро calls it through an object
    ("N2", {}, {"engine/src/xrGame/coop/coop_far_policy.h": POLICY_H, "engine/src/xrGame/coop/coop_far_policy.cpp": POLICY_CPP,
                "engine/src/xrGame/coop/srv/coop_far_policy_srv.cpp": POLICY_SRV}, (),
     ("engine/src/xrGame/coop/srv/coop_far_policy_srv.cpp", POLICY_SRV.replace("return false;", "return id != 0;")),
     "a member of the Ядро class FarPolicy"),
    # N2 with a stock class (CLevel of a stock header without "coop" bytes)
    ("N2s", {}, {"engine/src/xrGame/Level.h": "#pragma once\nclass CLevel\n{\npublic:\n\tvoid frame();\n};\n",
                 "engine/src/xrGame/coop/srv/coop_level_far.cpp": "#include \"../Level.h\"\nvoid CLevel::far_frame()\n{\n}\n"},
     ("engine/src/xrGame/Level.h",),
     ("engine/src/xrGame/coop/srv/coop_level_far.cpp", "#include \"../Level.h\"\nvoid CLevel::far_frame()\n{\n\tint n = 1;\n}\n"),
     "a member of the Ядро class CLevel"),
    # N3 / B3: a static initializer in a srv file registers a hook into an Ядро registry in every process
    ("N3", {}, {"engine/src/xrGame/coop/coop_hooks.h": HOOKS_H, "engine/src/xrGame/coop/srv/coop_far_skip.cpp": SKIP_SRV}, (),
     ("engine/src/xrGame/coop/srv/coop_far_skip.cpp", SKIP_SRV.replace("return false;", "return id >= 0x9000;")),
     "a static initializer with a call"),
    # N4 / B4: Ядро reads `extern bool g_far_world`, a srv file defines it
    ("N4", {}, {"engine/src/xrGame/coop/coop_farread.cpp": FARREAD, "engine/src/xrGame/coop/srv/coop_srv_world.cpp": WORLD_SRV},
     (), ("engine/src/xrGame/coop/srv/coop_srv_world.cpp", WORLD_SRV.replace("= false", "= true")),
     "defines g_far_world, declared extern by engine/src/xrGame/coop/coop_farread.cpp"),
    # N10 / B7: Ядро C++ names a srv script in a string (lua_getglobal)
    ("N10", {}, {"engine/src/xrGame/coop/coop_farcall.cpp": FARCALL}, (),
     ("gamedata/scripts/coop_srv_far.script", "function keep(id) return id > 0 end\n"),
     "named in a string by engine/src/xrGame/coop/coop_farcall.cpp:5"),
    # N11 / B8: a dialog of the configs names a srv script's function
    ("N11", {"gamedata/configs/gameplay/dialogs_coop_far.xml":
             "<game_dialogs>\n<dialog id=\"far\">\n<precondition>coop_srv_far.can_trade</precondition>\n</dialog>\n</game_dialogs>\n"},
     {}, (), ("gamedata/scripts/coop_srv_far.script", "function can_trade() return false end\n"),
     "named by gamedata/configs/gameplay/dialogs_coop_far.xml:3"),
    ("N11ltx", {}, {"engine/gamedata/configs/scripts/far_logic.ltx": "[logic]\non_info = {=coop_srv_far.can_trade} far\n"},
     (), ("gamedata/scripts/coop_srv_far.script", "function can_trade() return false end\n"),
     "named by engine/gamedata/configs/scripts/far_logic.ltx:2"),
    # N12 / B9: a stock-patch script (engine/gamedata/scripts) calls a srv script
    ("N12", {"gamedata/scripts/coop_srv_boot.script": "function on_start() return end\n"},
     {"engine/gamedata/scripts/axr_main.script": "function on_game_start()\n\tif coop_srv_boot then coop_srv_boot.on_start() end\nend\n"},
     (), ("gamedata/scripts/coop_srv_boot.script", "function on_start() alife():set_switch_distance(150) end\n"),
     "named by engine/gamedata/scripts/axr_main.script:2"),
    ("N12g", {"gamedata/scripts/coop_srv_boot.script": "function on_start() return end\n",
              "gamedata_gamma/scripts/coop_menu_theme.script": "function apply()\n\tcoop_srv_boot.on_start()\nend\n"},
     {}, (), ("gamedata/scripts/coop_srv_boot.script", "function on_start() alife():set_switch_distance(150) end\n"),
     "named by gamedata_gamma/scripts/coop_menu_theme.script:2"),
])
def test_srv_code_the_co_op_process_runs_is_core(repos, capsys, case, mod_files, engine_files, stock, edit, why):
    # the review's N1-N4, N10-N12: a later srv-only edit of server code that runs in the co-op process needed srv.ok only
    root, engine, exe = repos
    setup_more(root, engine, mod_files, engine_files, stock)
    path, text = edit
    if path.startswith("engine/"):
        write(engine, path[len("engine/"):], text)
        commit(engine, f"{case}: a server fix")
    else:
        write(root, path, text)
        commit(root, f"{case}: a server fix")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "b2..HEAD", "--per-commit")
    assert code == 1, out
    assert f"core     {path}" in out and why in out and "hostplay.ok missing" in out, out


def test_srv_script_named_only_in_a_config_comment_stays_srv(repos, capsys):
    root, engine, exe = repos
    setup_more(root, engine, {"gamedata/configs/gameplay/dialogs_coop_far.xml":
                              "<game_dialogs>\n<!-- coop_srv_far.can_trade -->\n</game_dialogs>\n",
                              "gamedata/configs/far.ltx": "[x]\n; coop_srv_far.can_trade\n"}, {})
    write(root, "gamedata/scripts/coop_srv_far.script", "function can_trade() return false end\n")
    commit(root, "srv")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "b2..HEAD", "--per-commit")
    assert code == 0, out
    assert "srv      gamedata/scripts/coop_srv_far.script" in out, out


@pytest.mark.parametrize(("path", "text"), [
    ("tests/test_items.cpp", "TEST(a)\n{\n\t// CHECK_EQ(placement(), 1); flaky after the server fix\n}\nTEST(b)\n{\n}\n"),  # N13
    ("tests/lua/stub_coop.lua", "COOP_LUA_MODES = { \"srv\" }\n"),                                               # N14
])
def test_srv_change_that_edits_co_op_tests_fails(repos, capsys, path, text):
    # B10: the set of TEST names stays the same; the bodies or the Lua support of the co-op tests changed
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, path, text)
    commit(root, "srv and a co-op test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "co-op tests 3 -> 3 (unchanged)" in out and "edited co-op tests or their runner" in out and path in out, out


def test_srv_change_that_edits_co_op_tests_in_the_working_tree_fails(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/lua/test_items.lua", "-- weaker\n")
    code, out = run(root, exe, capsys)
    assert code == 1 and "edited co-op tests or their runner" in out and "tests/lua/test_items.lua" in out, out


def test_srv_change_with_its_own_srv_test_passes(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/lua/test_srv_far.lua", "-- the server's own\n")
    commit(root, "srv and its test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out


def test_test_runner_edit_needs_both_marks(repos, capsys):
    # B10 / N14: tests/lua/run_all.lua, tools/test_lua.cmd and tools/build_tests.cmd decide which co-op tests run
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/lua/run_all.lua", "COOP_LUA_MODES = { \"srv\" }\n")
    commit(root, "srv and the runner")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "core     tests/lua/run_all.lua" in out and "hostplay.ok missing" in out, out


def test_non_ascii_product_path_is_classified(repos, capsys):
    # B11: git quotes a non-ASCII path unless core.quotePath=false; a quoted path never matched PRODUCT
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_предметы.script", "function pick() return false end\n")
    write(root, "gamedata/scripts/coop_srv_x.script", "x = 1\n")
    commit(root, "cyrillic")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "core     gamedata/scripts/coop_предметы.script" in out, out
    assert required(out).startswith(" hostplay.ok, srv.ok"), out
    write(root, "gamedata/scripts/coop_предметы.script", "function pick() return true end\n")
    code, out = run(root, exe, capsys)
    assert "core     gamedata/scripts/coop_предметы.script" in out and required(out).startswith(" hostplay.ok, srv.ok"), out


def test_quoted_path_is_a_gate_error(repos):
    root, _, _ = repos
    with pytest.raises(gates.GateError, match="quoted"):
        gates.classify('"gamedata/scripts/coop_\\320\\277.script"', gates.read_layers(root / "tools/layers.txt"), set(),
                       set(), lambda p: "")


# --- the stand: tracked scenarios, HEAD's gamedata (B12, B13) ---------------------------------------------------------

STAND = ROOT / "tools" / "stand"


def test_stand_scenarios_and_probes_are_tracked_in_tools_stand():
    # B12: every scenario the runners name, the guard and every probe a scenario deploys live in tools/stand (tracked);
    # temp/stand (ignored) keeps the run history only
    for mode, names in gates.SCENARIOS.items():
        text = (ROOT / "tools" / f"stand_{mode}.ps1").read_text(encoding="utf-8")
        for script in re.findall(r"Script = '([^']+)'", text):
            assert (STAND / script).resolve().is_file(), (mode, script)
    for name in ("run_guarded.ps1", "hybrid_save.ps1", "stand_head.py"):
        assert (STAND / name).is_file(), name
    for scenario in STAND.glob("*.ps1"):
        text = scenario.read_text(encoding="utf-8", errors="replace")
        for probe in re.findall(r"(coop_zz_\w+\.script)'", text):
            if re.search(rf"Copy-Item -LiteralPath \(Join-Path \$PSScriptRoot '{probe}'\)", text) or \
                    re.search(rf"\$p in @\([^)]*'{probe}'", text):
                assert (STAND / probe).is_file(), (scenario.name, probe)
        assert "Join-Path $PSScriptRoot \"${Tag}" not in text, scenario.name  # logs go to temp\stand, not here
    common = (ROOT / "tools" / "stand_common.ps1").read_text(encoding="utf-8")
    assert "tools\\stand" in common and "stand_head.py" in common


def scenario_repo(work: Path) -> tuple[Path, Path]:
    """A fake mod repository (with engine/) holding the stand tooling: tools/check_gates.py, check_layers.py,
    stand_common.ps1, tools/stand/ (stand_head.py and one probe), gamedata in all three layers; and a fake stand."""
    root = work / "mod"
    engine = root / "engine"
    engine.mkdir(parents=True)
    init(root)
    init(engine)
    write(root, ".gitignore", "engine/\nengine-ci/\ntemp/\ngamedata/scripts/coop_local.script\n")
    (root / "tools" / "stand").mkdir(parents=True)
    for name in ("check_gates.py", "check_layers.py", "stand_common.ps1", "stand_hostplay.ps1", "stand_srv.ps1",
                 "ded_check.ps1", "mo2_stand.py"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    for path in STAND.iterdir():
        if path.is_file():
            shutil.copy2(path, root / "tools" / "stand" / path.name)
    write(root, "gamedata/scripts/coop_items.script", "function pick() return 1 end\n")
    write(root, "gamedata/configs/axr_options.ltx", "[x]\n")  # written by the game: never deployed
    write(root, "gamedata_gamma/scripts/coop_menu_theme.script", "function apply() end\n")
    write(engine, "gamedata/scripts/axr_main.script", "function on_game_start() end\n")
    write(engine, "gamedata/configs/mod_by_engine.ltx", "[engine]\n")
    write(engine, "gamedata/configs/mod_by_a_mod.ltx", "[engine]\n")
    write(engine, "src/x.cpp", "int x;\n")
    commit(root, "base")
    commit(engine, "base")
    write(root, "gamedata/scripts/coop_local.script", "-- ignored, never committed\n")
    stand = work / "stand"
    (stand / "gamedata" / "configs").mkdir(parents=True)
    (stand / "bin").mkdir()
    write(stand, "gamedata/scripts/coop_items.script", "function pick() return 0 end\n")      # an older Core file
    write(stand, "gamedata/configs/mod_by_engine.ltx", "[old engine]\n")                      # from the Engine layer
    write(stand, "gamedata/configs/mod_by_a_mod.ltx", "[a mod overrides it]\n")               # a mod wins over Engine
    write(stand, "gamedata/configs/axr_options.ltx", "[the player's]\n")
    entries = [{"rel": "gamedata/configs/mod_by_engine.ltx", "source": "B:\\dev-1\\Anomaly Coop - Engine/gamedata\\configs\\mod_by_engine.ltx"},
               {"rel": "gamedata/configs/mod_by_a_mod.ltx", "source": "B:\\mo2\\mods\\12- A mod\\gamedata\\configs\\mod_by_a_mod.ltx"},
               {"rel": "gamedata/scripts/coop_items.script", "source": "B:\\dev-1\\Anomaly Coop - Core/gamedata\\scripts\\coop_items.script"}]
    (stand / ".raylink-stand.json").write_text(json.dumps({"format": 1, "entries": entries}), encoding="utf-8")
    # engine-ci built from engine HEAD; the stand's exe is its copy (C12)
    ci_sync(engine, root / "engine-ci")
    ci_exe(root / "engine-ci", gates.stand_exe(stand), b"MZ stand exe")
    return root, stand


def add_manifest(stand: Path, *entries: dict) -> None:
    path = stand / ".raylink-stand.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    data["entries"] += list(entries)
    path.write_text(json.dumps(data), encoding="utf-8")


def stand_head(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(root / "tools" / "stand" / "stand_head.py"), *args],
                          capture_output=True, text=True, encoding="utf-8", errors="replace", cwd=root)


def values(out: str) -> dict:
    return dict(l.split("=", 1) for l in out.splitlines() if re.match(r"^[a-z_0-9]+=", l))


def test_stand_head_deploys_heads_gamedata_and_prints_the_digests(work):
    # B13: the stand runs HEAD's gamedata: Core and GAMMA always, the Engine layer where no mod overrides it
    root, stand = scenario_repo(work)
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout + done.stderr
    got = values(done.stdout)
    assert got["gamedata_sha256"] == gates.gamedata_digest(root, root / "engine", "HEAD", "HEAD")
    assert got["scenarios_sha256"] == gates.scenarios_digest(root, "HEAD")
    assert got["mod_head"] == sh(root, "rev-parse", "HEAD") and got["engine_head"] == sh(root / "engine", "rev-parse", "HEAD")
    read = lambda rel: (stand / rel).read_text(encoding="utf-8")  # noqa: E731
    assert read("gamedata/scripts/coop_items.script") == "function pick() return 1 end\n"
    assert read("gamedata/scripts/coop_menu_theme.script") == "function apply() end\n"         # GAMMA layer on top
    assert read("gamedata/configs/mod_by_engine.ltx") == "[engine]\n"                          # Engine layer, its file
    assert read("gamedata/configs/mod_by_a_mod.ltx") == "[a mod overrides it]\n"               # the mod still wins
    assert read("gamedata/scripts/axr_main.script") == "function on_game_start() end\n"        # new engine file
    assert read("gamedata/configs/axr_options.ltx") == "[the player's]\n"                      # never deployed
    assert not (stand / "gamedata/scripts/coop_local.script").exists()                         # not in HEAD
    assert (work / "backup" / "gamedata/scripts/coop_items.script").read_text(encoding="utf-8") == "function pick() return 0 end\n"
    check = stand_head(root, "check", "--stand", str(stand))
    assert check.returncode == 0 and values(check.stdout)["gamedata_sha256"] == got["gamedata_sha256"], check.stdout
    write(stand, "gamedata/scripts/coop_items.script", "function pick() return 2 end\n")  # changed during the run
    check = stand_head(root, "check", "--stand", str(stand))
    assert check.returncode == 1 and "coop_items.script" in check.stdout, check.stdout


@pytest.mark.parametrize(("rel", "text"), [
    ("gamedata/scripts/coop_items.script", "function pick() return 5 end\n"),   # a product change
    ("gamedata/scripts/coop_new.script", "x = 1\n"),                            # an untracked product file
    ("tools/stand/coop_zz_probe.script", "-- relaxed\n"),                       # a scenario file not at HEAD
    ("engine/gamedata/scripts/axr_main.script", "-- engine change\n"),
])
def test_stand_head_refuses_a_dirty_tree(work, rel, text):
    # B13: the runner refuses to start while the working tree has product (or scenario) changes
    root, stand = scenario_repo(work)
    write(root, rel, text)
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 1 and "refused" in done.stdout and rel.split("/")[-1] in done.stdout, done.stdout
    assert (stand / "gamedata/scripts/coop_items.script").read_text(encoding="utf-8") == "function pick() return 0 end\n"


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
def test_stand_runner_deploys_first_and_writes_the_digests_into_the_mark(work):
    # B12/B13 through the runner's own functions (no game starts): Invoke-HeadDeploy, then Write-GateMark
    root, stand = scenario_repo(work)
    exe = stand / "bin" / "AnomalyCoopDX11AVX.exe"
    exe.write_bytes(b"MZ stand exe")
    script = (f". '{root / 'tools' / 'stand_common.ps1'}'; $h = Invoke-HeadDeploy -Stand '{stand}'; "
              f"Write-GateMark -Mode srv -Exe '{exe}' -Names @({','.join(repr(s) for s in gates.SCENARIOS['srv'])}) -Head $h")
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                          capture_output=True, text=True)
    assert done.returncode == 0, done.stdout + done.stderr
    ok, text = gates.check_mark("srv", root / "temp" / "gates", sh(root, "rev-parse", "HEAD"),
                                sh(root / "engine", "rev-parse", "HEAD"), hashlib.sha256(exe.read_bytes()).hexdigest(),
                                root, root / "engine", stand)
    assert ok, text
    written = gates.read_mark(root / "temp" / "gates" / "srv.ok")
    assert written["exe_source"] == sh(root / "engine", "rev-parse", "HEAD") and written["stand_extra"] == "0", written
    write(root, "gamedata/scripts/coop_items.script", "function pick() return 9 end\n")
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                           f". '{root / 'tools' / 'stand_common.ps1'}'; Invoke-HeadDeploy -Stand '{stand}'"],
                          capture_output=True, text=True)
    assert done.returncode != 0 and "refused" in (done.stdout + done.stderr), done.stdout + done.stderr


# --- review 3: the release rule and tests.ok ---------------------------------------------------------------------------

FAR_SRV = "namespace coop::far\n{\nint far_only() { return 4; }\n}\n"  # srv code nothing of Ядро reaches


def test_range_needs_both_stands_and_the_tests_for_any_product_change(repos, capsys):
    # the release rule: a srv-only commit is srv for the early warning, but the range needs everything
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_far.cpp", FAR_SRV)
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0 and required(out) == " srv.ok, unchanged co-op tests", out
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1, out
    assert required(out) == " hostplay.ok, srv.ok, tests.ok", out
    assert "release rule: a product file changed in the range" in out
    assert "hostplay.ok missing" in out and "tests.ok missing" in out
    mark(root, engine, exe, "hostplay")
    write_tests_mark(root, engine)
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0, out
    assert "tests.ok OK" in out
    assert not re.search(r"[0-9a-f]{32}", out), out


def test_range_without_a_product_change_needs_nothing_but_a_release_ships_the_exe(repos, capsys):
    root, engine, exe = repos
    write(root, "docs/NOTES.md", "more\n")
    commit(root, "docs")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0 and "required: nothing" in out, out
    ci = ci_build(root, engine, exe)
    code, out = run(root, exe, capsys, "base..HEAD", "--release", "--ci", str(ci))
    assert code == 1 and required(out) == " hostplay.ok, srv.ok, tests.ok", out
    assert "the release ships the exe" in out
    for which in gates.MARKS:
        mark(root, engine, exe, which)
    write_tests_mark(root, engine)
    code, out = run(root, exe, capsys, "base..HEAD", "--release", "--ci", str(ci))
    assert code == 0 and "engine-ci's build of engine" in out, out


@pytest.mark.parametrize(("drop", "override", "why"), [
    (("mode",), {}, "mode missing"),
    ((), {"dirty": "2"}, "dirty=2"),
    ((), {"native": "1"}, "build_tests.cmd did not pass"),
    (("lua",), {}, "lua=missing"),
    ((), {"engine_head": "0" * 40}, "engine 00000000 !="),
    ((), {"mod_head": "0" * 40}, "mod 00000000 !="),
])
def test_tests_mark_does_not_count_unless_clean_green_and_of_both_heads(repos, capsys, drop, override, why):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_items.script", "function f() return 1 end\n")
    commit(root, "core")
    for which in gates.MARKS:
        mark(root, engine, exe, which)
    write_tests_mark(root, engine, drop, **override)
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1 and "tests.ok does not count" in out and why in out, out


def engine_slices() -> list[str]:
    """The engine slices of this repository: the Python tests under tests/ that cut engine functions out of engine/src
    and build them over stubs with MSVC (their compile step runs cl /nologo). This file names the pattern itself."""
    this = Path(__file__).resolve()
    return sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "tests").rglob("test_*.py")
                  if p.resolve() != this and "cl /nologo" in p.read_text(encoding="utf-8", errors="replace"))


def gate_slices() -> set[str]:
    """The tests/ files tools/run_all_tests.cmd runs, as repository paths."""
    text = (ROOT / "tools" / "run_all_tests.cmd").read_text(encoding="utf-8")
    return {m.replace("\\", "/") for m in re.findall(r'"%ROOT%\\(tests\\[\w\\]+\.py)"', text)}


def test_every_engine_slice_runs_in_run_all_tests():
    # a slice outside tools\run_all_tests.cmd is run by nobody, and a regression in its engine path ships
    slices = engine_slices()
    assert slices, "no engine slice found under tests/"
    missing = [s for s in slices if s not in gate_slices()]
    assert not missing, f"tools\\run_all_tests.cmd does not run {len(missing)} engine slice(s): {', '.join(missing)}"


def test_tests_mark_is_written_only_after_a_clean_green_run_of_both_heads(repos, capsys):
    root, engine, _ = repos
    marks = root / "temp" / "gates"
    state = marks / "tests.state"

    def begin() -> int:
        code = gates.main(["--root", str(root), "--tests-mark", "begin"])
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(capsys.readouterr().out, encoding="utf-8")
        return code

    def finish(native: int, lua: int) -> tuple[int, str]:
        code = gates.main(["--root", str(root), "--tests-mark", "write", "--state", str(state), "--native", str(native),
                           "--lua", str(lua)])
        return code, capsys.readouterr().out

    write_tests_mark(root, engine)
    fake_lua_runner(root)
    assert begin() == 0 and not (marks / "tests.ok").exists()  # an old mark never outlives a new run
    code, out = finish(0, 1)
    assert code == 1 and "test_lua.cmd failed" in out and not (marks / "tests.ok").exists(), out
    assert begin() == 0
    code, out = finish(0, 0)
    assert code == 0 and (marks / "tests.ok").exists(), out
    head_ids = (sh(root, "rev-parse", "HEAD"), sh(engine, "rev-parse", "HEAD"))
    assert gates.check_mark("tests", marks, *head_ids, None)[0]
    # a file the tests read changed during the run
    assert begin() == 0
    write(root, "tests/lua/test_items.lua", "-- weaker\n")
    code, out = finish(0, 0)
    assert code == 1 and "not clean" in out and not (marks / "tests.ok").exists(), out
    sh(root, "checkout", "--", "tests/lua/test_items.lua")
    # a HEAD moved during the run
    assert begin() == 0
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 3; }\n")
    commit(engine, "during the run")
    code, out = finish(0, 0)
    assert code == 1 and "engine_head moved" in out, out


@pytest.mark.skipif(shutil.which("cmd") is None, reason="cmd.exe is not here")
def test_run_all_tests_cmd_writes_tests_ok_only_when_both_suites_pass(repos):
    root, engine, _ = repos
    for name in ("check_gates.py", "check_layers.py", "run_all_tests.cmd"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    write(root, "tools/build_tests.cmd", "@exit /b 0\n")
    write(root, "tools/test_lua.cmd", "@exit /b %STUB_LUA%\n")
    write(root, "tools/test_luajit.cmd", "@exit /b %STUB_LUAJIT%\n")
    write(root, "tools/persisted_keys.txt", "# no saved names in this tree\n")
    # every engine slice of this repository, and every other test file the runner names, as a stub that fails when
    # STUB_SLICE names it (run by pytest or as a script)
    slices = engine_slices()
    for rel in sorted(set(slices) | gate_slices()):
        fails = f"os.environ.get('STUB_SLICE') == {posixpath.basename(rel)[:-3]!r}"
        write(root, rel, f"import os\nimport sys\n\n\ndef test_slice():\n    assert not {fails}\n\n\n"
                         f"if __name__ == '__main__':\n    sys.exit(3 if {fails} else 0)\n")
    commit(root, "the runners")
    fake_lua_runner(root)
    env = dict(os.environ, PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ.get("PATH", ""))
    env.pop("COOP_SKIP_LAYERS", None)
    env["STUB_LUAJIT"] = "0"
    mark_path = root / "temp" / "gates" / "tests.ok"
    done = subprocess.run(["cmd", "/c", str(root / "tools" / "run_all_tests.cmd")], capture_output=True, text=True,
                          env=dict(env, STUB_LUA="0"))
    assert done.returncode == 0 and mark_path.is_file(), done.stdout + done.stderr
    assert gates.read_mark(mark_path)["engine_head"] == sh(engine, "rev-parse", "HEAD")
    # the engine's LuaJIT tests (tools\test_luajit.cmd, build 57's lua_setupvalue barrier) count as native tests
    done = subprocess.run(["cmd", "/c", str(root / "tools" / "run_all_tests.cmd")], capture_output=True, text=True,
                          env=dict(env, STUB_LUA="0", STUB_LUAJIT="4"))
    assert done.returncode == 1 and not mark_path.exists(), done.stdout + done.stderr
    # so does every engine slice: one under tests/tools (pytest) and one under tests/ (a script)
    for failing in (min(s for s in slices if s.startswith("tests/tools/")),
                    min(s for s in slices if not s.startswith("tests/tools/"))):
        done = subprocess.run(["cmd", "/c", str(root / "tools" / "run_all_tests.cmd")], capture_output=True, text=True,
                              env=dict(env, STUB_LUA="0", STUB_SLICE=posixpath.basename(failing)[:-3]))
        assert done.returncode == 1 and not mark_path.exists(), failing + ": " + done.stdout + done.stderr
    done = subprocess.run(["cmd", "/c", str(root / "tools" / "run_all_tests.cmd")], capture_output=True, text=True,
                          env=dict(env, STUB_LUA="3"))
    assert done.returncode == 1 and not mark_path.exists(), done.stdout + done.stderr
    done = subprocess.run(["cmd", "/c", str(root / "tools" / "run_all_tests.cmd")], capture_output=True, text=True,
                          env=dict(env, STUB_LUA="0", COOP_SKIP_LAYERS="1"))
    assert done.returncode == 0 and not mark_path.exists() and "NO tests.ok" in done.stdout, done.stdout


# --- review 3, C12: the exe is engine-ci's build of engine HEAD ----------------------------------------------------------

def built_from_head(root: Path, engine: Path, exe: Path) -> Path:
    """engine HEAD moved on from the commit engine-ci was checked out at (a file added, one edited, one deleted, the
    build number header), then ci_sync and a build: the good state."""
    ci = root / "engine-ci"
    ci_sync(engine, ci)
    write(engine, "src/xrGame/coop/coop_new.cpp", "int fresh() { return 1; }\n")
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 7; }\n")
    write(engine, "src/xrCore/raylink_build.h", "#pragma once\n#define RAYLINK_BUILD 0\n")
    (engine / "src/xrGame/coop/coop_far.cpp").unlink()
    commit(engine, "work")
    ci_sync(engine, ci, build=57)
    (ci / "src/xrGame/coop/coop_far.cpp").unlink()  # gone from HEAD: the good state has no copy of it either
    ci_exe(ci, exe)
    return ci


def test_exe_source_is_engine_head_for_engine_cis_build_of_heads_sources(repos, capsys):
    root, engine, exe = repos
    ci = built_from_head(root, engine, exe)
    assert gates.exe_source(engine, exe, ci) == (sh(engine, "rev-parse", "HEAD"), [])
    assert gates.exe_source(engine, ci.joinpath(*gates.CI_EXE), ci)[1] == []
    code = gates.main(["--root", str(root), "--exe-source", "--exe", str(exe), "--ci", str(ci)])
    assert code == 0 and "exe_source=" + sh(engine, "rev-parse", "HEAD") in capsys.readouterr().out


@pytest.mark.parametrize(("case", "why"), [
    ("edited", "differs from engine HEAD in 1 file(s): src/xrGame/coop/coop_items.cpp"),
    ("lacks", "lacks 1 file(s) of engine HEAD: src/xrGame/coop/coop_new.cpp"),
    ("extra", "holds 1 source file(s) engine HEAD does not have: src/xrGame/coop/coop_far.cpp"),
    ("untracked_extra", "engine HEAD does not have: src/xrGame/coop/coop_stale.cpp"),
    ("synced_after", "changed after the exe was built: src/xrGame/coop/coop_items.cpp"),
    ("dirty", "engine/src has 1 uncommitted file(s)"),
    ("other_exe", "is not engine-ci's build"),
])
def test_exe_source_names_why_the_exe_is_not_heads_build(repos, case, why):
    root, engine, exe = repos
    ci = built_from_head(root, engine, exe)
    if case == "edited":
        write(ci, "src/xrGame/coop/coop_items.cpp", "int items() { return 8; }\n")
        ci_exe(ci, exe)
    elif case == "lacks":
        (ci / "src/xrGame/coop/coop_new.cpp").unlink()
        ci_exe(ci, exe)
    elif case == "extra":
        write(ci, "src/xrGame/coop/coop_far.cpp", "int far_only() { return 3; }\n")  # tracked in engine-ci's index
        ci_exe(ci, exe)
    elif case == "untracked_extra":
        write(ci, "src/xrGame/coop/coop_stale.cpp", "int stale() { return 1; }\n")
        ci_exe(ci, exe)
    elif case == "synced_after":
        target = ci / "src/xrGame/coop/coop_items.cpp"
        later = time.time() + 600
        os.utime(target, (later, later))
    elif case == "dirty":
        write(engine, "src/xrGame/coop/coop_wip.cpp", "int wip() { return 1; }\n")
    else:
        exe.write_bytes(b"MZ another build")
    source, problems = gates.exe_source(engine, exe, ci)
    assert source == "" and any(why in p for p in problems), problems


def test_release_mode_refuses_an_exe_not_built_from_engine_head(repos, capsys):
    root, engine, exe = repos
    ci = built_from_head(root, engine, exe)
    for which in gates.MARKS:
        mark(root, engine, exe, which)
    write_tests_mark(root, engine)
    code, out = run(root, exe, capsys, "base..HEAD", "--release", "--ci", str(ci))
    assert code == 0 and "engine-ci's build of engine" in out, out
    write(ci, "src/xrGame/coop/coop_items.cpp", "int items() { return 9; }\n")  # an edit after the build
    code, out = run(root, exe, capsys, "base..HEAD", "--release", "--ci", str(ci))
    assert code == 1 and "the exe was not built from engine HEAD" in out and "coop_items.cpp" in out, out


# --- review 3: the gate's reach (C6-C9, C11) and the route table read as data (C10) ------------------------------------

HOOKS_REG_SRV = ("#include \"../coop_hooks.h\"\nnamespace coop::srvfar\n{\nstatic bool far_skip(u16 id)\n{\n\treturn false;\n}\n"
                 "struct Registrar\n{\n\tRegistrar() { coop::hooks::set_skip(&far_skip); }\n};\nstatic Registrar s_registrar;\n}\n")
LIMITS_H = ("#pragma once\nstruct FarLimits\n{\n\tstatic u32 squads_per_player;\n};\n"
            "inline u32 far_squads() { return FarLimits::squads_per_player; }\n")
LIMITS_SRV = "#include \"../coop_far_limits.h\"\nu32 FarLimits::squads_per_player = 4;\n"
SWITCH_CORE = ("namespace coop\n{\nbool may_switch(u16 id)\n{\n\treturn id != 0;\n}\nbool switch_ok(u16 id, const FarGroup& g)\n"
               "{\n\treturn may_switch(id) && may_switch(g);\n}\n}\n")
SWITCH_SRV = "namespace coop\n{\nbool may_switch(const FarGroup& g)\n{\n\treturn g.members > 1;\n}\n}\n"
BOOK_H = "#pragma once\nnamespace op\n{\nstruct Book\n{\n\tbool may_run(int line) const;\n};\n}\n"
BOOK_CORE = ("#include \"xrCoop/srv/coop_book.h\"\nnamespace coop\n{\nop::Book& operator_book()\n{\n\tstatic op::Book book;\n"
             "\treturn book;\n}\nbool run_line(int line)\n{\n\treturn operator_book().may_run(line);\n}\n}\n")
BOOK_SRV = ("#include \"../../../xrCoop/srv/coop_book.h\"\nnamespace op\n{\nbool Book::may_run(int line) const\n{\n"
            "\treturn line > 0;\n}\n}\n")


@pytest.mark.parametrize(("case", "mod_files", "engine_files", "edit", "why"), [
    # C6: a dispatch table of Ядро names the srv script in a plain string
    ("C6", {"gamedata/scripts/coop_price_hooks.script":
            "local HOOKS = { \"coop_items\", \"coop_srv_far\" }\nfunction factor(i) return rawget(_G, HOOKS[2]).f(i) end\n"},
     {}, ("gamedata/scripts/coop_srv_far.script", "function f(i) return 1.5 end\n"),
     "named by gamedata/scripts/coop_price_hooks.script:1"),
    # C7: a static object whose constructor registers a hook runs in every process
    ("C7", {}, {"engine/src/xrGame/coop/coop_hooks.h": HOOKS_H, "engine/src/xrGame/coop/srv/coop_far_reg.cpp": HOOKS_REG_SRV},
     ("engine/src/xrGame/coop/srv/coop_far_reg.cpp", HOOKS_REG_SRV.replace("return false;", "return id > 1;")),
     "a static initializer with a call"),
    # C8: a static member of an Ядро class defined in a srv file
    ("C8", {}, {"engine/src/xrGame/coop/coop_far_limits.h": LIMITS_H,
                "engine/src/xrGame/coop/srv/coop_far_limits_srv.cpp": LIMITS_SRV},
     ("engine/src/xrGame/coop/srv/coop_far_limits_srv.cpp", LIMITS_SRV.replace("= 4", "= 2")),
     "defines the static member FarLimits::squads_per_player"),
    # C9: an overload in a srv file of a function Ядро defines and calls
    ("C9", {}, {"engine/src/xrGame/coop/coop_far_switch.cpp": SWITCH_CORE,
                "engine/src/xrGame/coop/srv/coop_far_switch_srv.cpp": SWITCH_SRV},
     ("engine/src/xrGame/coop/srv/coop_far_switch_srv.cpp", SWITCH_SRV.replace("> 1", "< 2")),
     "defines coop::may_switch, called from engine/src/xrGame/coop/coop_far_switch.cpp"),
    # C11: a member of a class declared in a srv header Ядро includes
    ("C11", {}, {"engine/src/xrCoop/srv/coop_book.h": BOOK_H, "engine/src/xrGame/coop/coop_debug.cpp": BOOK_CORE,
                 "engine/src/xrGame/coop/srv/coop_book.cpp": BOOK_SRV},
     ("engine/src/xrGame/coop/srv/coop_book.cpp", BOOK_SRV.replace("line > 0", "line > 1")),
     "a member of the class Book declared in the reached engine/src/xrCoop/srv/coop_book.h"),
])
def test_review3_srv_code_the_co_op_process_runs_is_core(repos, capsys, case, mod_files, engine_files, edit, why):
    root, engine, exe = repos
    setup_more(root, engine, mod_files, engine_files)
    path, text = edit
    if path.startswith("engine/"):
        write(engine, path[len("engine/"):], text)
        commit(engine, f"{case}: a server fix")
    else:
        write(root, path, text)
        commit(root, f"{case}: a server fix")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "b2..HEAD", "--per-commit")
    assert code == 1, out
    assert f"core     {path}" in out and why in out and "hostplay.ok missing" in out, out


def test_route_key_moved_to_another_section_is_core(repos, capsys):
    # C10: save_state leaves the forced callbacks and comes back under [route_scripts] as `level`
    root, engine, exe = repos
    setup_more(root, engine, {"gamedata/configs/coop_route_npc.ltx":
                              "[route_callbacks_forced]\nsave_state = host\n[route_scripts]\ncoop_npc_adapters = host\n"}, {})
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_callbacks_forced]\n[route_scripts]\nsave_state = level\n"
                                                       "coop_npc_adapters = host\n")
    commit(root, "a server fix of the routes")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "b2..HEAD", "--per-commit")
    assert code == 1 and "route table (H6)" in out and "hostplay.ok missing" in out, out
    # the working tree reads the file on disk against HEAD the same way
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_callbacks_forced]\n[route_scripts]\nsave_state = level\n"
                                                       "coop_npc_adapters = level\n")
    code, out = run(root, exe, capsys)
    assert "srv      gamedata/configs/coop_route_npc.ltx (route table: only host <-> level)" in out, out


# --- review 3: the stand's leftovers, its profiles and its folder (S1-S3) ---------------------------------------------

def test_stand_head_moves_leftovers_of_our_layers_and_check_names_them(work):
    root, stand = scenario_repo(work)
    backup = work / "backup"
    add_manifest(stand, {"rel": "gamedata/scripts/coop_compat_old.script",
                         "source": "B:\\dev-1\\Anomaly Coop - Core/gamedata\\scripts\\coop_compat_old.script"},
                 {"rel": "gamedata/scripts/some_mod.script", "source": "B:\\mo2\\mods\\7- A mod\\gamedata\\scripts\\some_mod.script"})
    write(stand, "gamedata/scripts/coop_compat_old.script", "-- our Core layer of dev-1, gone from HEAD\n")
    write(stand, "gamedata/scripts/coop_handmade.script", "-- copied by hand, no manifest names it\n")
    write(stand, "gamedata/scripts/coop_zz_stale.script", "-- a probe no scenario has\n")
    write(stand, "gamedata/scripts/some_mod.script", "-- a GAMMA mod's own script\n")
    shutil.copy2(STAND / "coop_zz_squads.script", stand / "gamedata/scripts/coop_zz_squads.script")  # HEAD's probe
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(backup))
    assert done.returncode == 0, done.stdout + done.stderr
    got = values(done.stdout)
    assert got["removed"] == "3" and got["stand_extra"] == "0", done.stdout
    for name in ("coop_compat_old.script", "coop_handmade.script", "coop_zz_stale.script"):
        assert not (stand / "gamedata/scripts" / name).exists() and (backup / "removed/gamedata/scripts" / name).is_file()
    assert (stand / "gamedata/scripts/some_mod.script").is_file()
    assert (stand / "gamedata/scripts/coop_zz_squads.script").is_file()
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(backup))
    assert check.returncode == 0, check.stdout
    # a leftover that comes back: check names it and removes nothing
    write(stand, "gamedata/scripts/coop_compat_old.script", "-- back again\n")
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(backup))
    assert check.returncode == 1 and "coop_compat_old.script" in check.stdout and "HEAD does not have" in check.stdout
    assert (stand / "gamedata/scripts/coop_compat_old.script").is_file()


def test_stand_head_keeps_a_coop_script_a_mod_ships_names_it_and_binds_its_bytes(work):
    # the stand's coop_compat_alq.script comes from the GAMMA mod "Alife CENSORED", not from our layers
    root, stand = scenario_repo(work)
    add_manifest(stand, {"rel": "gamedata/scripts/coop_compat_alq.script",
                         "source": "B:\\mo2\\mods\\Alife CENSORED\\gamedata\\scripts\\coop_compat_alq.script"})
    write(stand, "gamedata/scripts/coop_compat_alq.script", "-- A-Life Quests: the RayLink co-op layer\n")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout
    got = values(done.stdout)
    assert got["stand_foreign"] == "gamedata/scripts/coop_compat_alq.script" and got["stand_extra"] == "0", done.stdout
    assert "kept gamedata/scripts/coop_compat_alq.script: a GAMMA mod ships it" in done.stdout
    assert (stand / "gamedata/scripts/coop_compat_alq.script").is_file()
    assert got["stand_fingerprint"] == gates.stand_fingerprint(stand)
    write(stand, "gamedata/scripts/coop_compat_alq.script", "-- edited on the stand\n")
    assert gates.stand_fingerprint(stand) != got["stand_fingerprint"]


def test_stand_head_profile_writes_the_mode_cvars_from_head(work):
    root, stand = scenario_repo(work)
    write(stand, "appdata_t/user.ltx", "bind jump kSPACE\r\ncoop_world_server 1\r\ncoop_split_levels 1\r\n"
                                       "coop_nick tester\r\ncoop_mapserver_linger 5\r\n")
    write(stand, "appdata_other/user.ltx", "coop_world_server 1\n")  # a folder the template does not name
    done = stand_head(root, "profile", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout
    text = (stand / "appdata_t/user.ltx").read_bytes()
    # S2 removed coop_world_server, coop_split_levels, coop_story_together and coop_soft_host_move from the engine: a
    # profile line of theirs goes, and the template writes none
    assert b"coop_world_server" not in text and b"coop_split_levels" not in text, text
    assert b"coop_max_map_servers 6\r\n" in text and b"coop_mapserver_linger 600\r\n" in text and b"linger 5" not in text
    assert text.startswith(b"bind jump kSPACE\r\n") and b"coop_nick tester\r\n" in text
    assert (stand / "appdata_other/user.ltx").read_text(encoding="utf-8") == "coop_world_server 1\n"
    assert (work / "backup/profiles/appdata_t/user.ltx").read_bytes().count(b"coop_world_server 1") == 1
    assert values(done.stdout)["profile_sha256"] == gates.profile_digest(root, "HEAD")
    again = stand_head(root, "profile", "--stand", str(stand), "--backup", str(work / "backup"))
    assert again.returncode == 0 and (stand / "appdata_t/user.ltx").read_bytes() == text


def test_stand_head_profile_removes_the_srv_names_the_engine_saves(work):
    # review A-REV-E-1 finding 7 (FIX-AREV1): the engine saves the map-server settings under their srv_* names only
    # (coop_srv_console.cpp CCC_SrvOldName); a profile line of those names comes from an earlier run and goes too, so the
    # template's lines are the profile's only mode lines
    root, stand = scenario_repo(work)
    write(stand, "appdata_t/user.ltx", "bind jump kSPACE\r\nsrv_max_map_servers 2\r\nsrv_map_servers_rev 0\r\n"
                                       "srv_mapserver_linger 5\r\ncoop_nick tester\r\n")
    done = stand_head(root, "profile", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout
    text = (stand / "appdata_t/user.ltx").read_bytes()
    assert b"srv_max_map_servers" not in text and b"srv_map_servers_rev" not in text and b"srv_mapserver_" not in text, text
    assert b"coop_max_map_servers 6\r\n" in text and b"coop_mapserver_linger 600\r\n" in text, text
    assert text.startswith(b"bind jump kSPACE\r\n") and b"coop_nick tester\r\n" in text, text


def test_the_checkers_the_runner_imports_are_part_of_the_stand_digest(work):
    # S3: stand_head imports check_gates.py and check_layers.py (the dirty check, the digests)
    assert {"tools/check_gates.py", "tools/check_layers.py"} <= set(gates.SCENARIO_PATHS)
    root, stand = scenario_repo(work)
    path = root / "tools" / "check_layers.py"
    path.write_text(path.read_text(encoding="utf-8") + "\n# relaxed\n", encoding="utf-8", newline="\n")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 1 and "check_layers.py" in done.stdout, done.stdout


def test_stand_profile_template_names_only_mode_cvars():
    text = (STAND / "stand_profile.ltx").read_text(encoding="utf-8")
    rows = [l.split(";", 1)[0].strip() for l in text.splitlines()]
    rows = [r for r in rows if r]
    assert rows[0] == "[appdata_t]" and "[appdata_server]" in rows
    for row in rows:
        # the mode cvars the engine still has after S2 (docs/plans/2026-11-18-two-modes.md: coop_split_levels,
        # coop_world_server, coop_story_together and coop_soft_host_move are gone; an unknown cvar in user.ltx is noise)
        assert row.startswith("[") or re.match(r"coop_(max_map_servers|map_servers_rev|mapserver_\w+) ", row), row


def test_stand_head_profile_refuses_a_cvar_s2_removed(work):
    root, stand = scenario_repo(work)
    template = root / "tools" / "stand" / "stand_profile.ltx"
    template.write_text(template.read_text(encoding="utf-8") + "[appdata_ms2]\ncoop_story_together 1\n", encoding="utf-8",
                        newline="\n")
    write(stand, "appdata_t/user.ltx", "coop_nick tester\n")
    done = stand_head(root, "profile", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 1 and "coop_story_together" in done.stdout and "S2" in done.stdout, done.stdout
    assert (stand / "appdata_t/user.ltx").read_text(encoding="utf-8") == "coop_nick tester\n"


# --- round 5 (TZ.md R21): the stand's files are hard links to the mods' own files ----------------------------------------
# Real hard links (os.link) in the test folder, on the repository's volume: the launcher builds the stand
# E:\RayLinkGames\GAMMA\game-dev the same way from E:\RayLinkGames\GAMMA\mo2\mods. A write into a stand file in place
# would change the mod's file for everything that links it; clearing its read-only attribute would change the mod's.

def set_source(stand: Path, rel: str, source: str, **more) -> None:
    """The manifest names source as where the launcher took the stand's rel from (one entry per path); more: copy,
    size, modified as the launcher writes them."""
    path = stand / ".raylink-stand.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    data["entries"] = [e for e in data["entries"] if e["rel"].lower() != rel.lower()] + [{"rel": rel, "source": source,
                                                                                          **more}]
    path.write_text(json.dumps(data), encoding="utf-8")


def mod_link(work: Path, stand: Path, rel: str, data: bytes, readonly: bool = True,
             mod: str = "12- A mod") -> Path:
    """A mod's own file under work/mo2/mods and the stand's name for it as a hard link (the launcher's way), read-only
    like the files of some GAMMA mods; the manifest names the mod as its source (copy=false, its size and time, as the
    launcher writes a link's entry). Returns the mod's file."""
    original = work / "mo2" / "mods" / mod / rel
    original.parent.mkdir(parents=True, exist_ok=True)
    original.write_bytes(data)
    target = stand / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    os.link(original, target)
    if readonly:
        os.chmod(original, stat.S_IREAD)
    st = os.stat(original)
    set_source(stand, rel, str(original), copy=False, size=st.st_size, modified=st.st_mtime_ns)
    return original


def mod_copy(work: Path, stand: Path, rel: str, data: bytes, mod: str = "30- A mod") -> Path:
    """A mod's own file and the stand's COPY of it (copy=true: the launcher copies the places the game writes, the
    gamedata and gamedata\\configs roots). Returns the mod's file."""
    original = work / "mo2" / "mods" / mod / rel
    original.parent.mkdir(parents=True, exist_ok=True)
    original.write_bytes(data)
    target = stand / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(original, target)
    st = os.stat(original)
    set_source(stand, rel, str(original), copy=True, size=st.st_size, modified=st.st_mtime_ns)
    return original


def untouched(original: Path, data: bytes, readonly: bool = True) -> bool:
    return original.read_bytes() == data and (not os.access(original, os.W_OK)) == readonly


MOD_ITEMS = b"-- the mod's own coop_items: GAMMA's, not ours\n"
MOD_USER = b"coop_world_server 1\r\ncoop_nick tester\r\n"


def test_deploy_replaces_a_linked_stand_file_and_never_writes_through_it(work):
    root, stand = scenario_repo(work)
    items = mod_link(work, stand, "gamedata/scripts/coop_items.script", MOD_ITEMS)
    user = mod_link(work, stand, "appdata_t/user.ltx", MOD_USER)
    assert os.stat(items).st_nlink == 2 and os.stat(user).st_nlink == 2
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout + done.stderr
    got = values(done.stdout)
    assert got["replaced_links"] == "1" and "replaced a hard link: gamedata/scripts/coop_items.script" in done.stdout
    # the stand holds HEAD's bytes in a file of its own; the mod's file keeps its bytes and its read-only attribute
    assert (stand / "gamedata/scripts/coop_items.script").read_text(encoding="utf-8") == "function pick() return 1 end\n"
    assert untouched(items, MOD_ITEMS) and os.stat(items).st_nlink == 1
    assert os.stat(stand / "gamedata/scripts/coop_items.script").st_nlink == 1
    # profile (S2): user.ltx gets the template's mode cvars as a new file, the mod's user.ltx is the same
    profile_text = (stand / "appdata_t/user.ltx").read_bytes()
    assert b"coop_world_server" not in profile_text and b"coop_max_map_servers 6" in profile_text, profile_text
    assert untouched(user, MOD_USER) and os.stat(user).st_nlink == 1
    assert (work / "backup/gamedata/scripts/coop_items.script").read_bytes() == MOD_ITEMS
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "backup"))
    assert check.returncode == 0, check.stdout


def test_deploy_restores_the_mods_file_when_head_drops_our_override(work):
    # review 4, B3 (q4_stand N2): our layer overrode a mod's file, then HEAD dropped the override
    root, stand = scenario_repo(work)
    write(root, "gamedata_gamma/configs/mod_by_a_mod_too.ltx", "[our override]\n")
    commit(root, "override a mod's file")
    original = mod_link(work, stand, "gamedata/configs/mod_by_a_mod_too.ltx", b"[the mod's]\n")
    backup = work / "backup"
    assert stand_head(root, "deploy", "--stand", str(stand), "--backup", str(backup)).returncode == 0
    assert (stand / "gamedata/configs/mod_by_a_mod_too.ltx").read_bytes() == b"[our override]\n"
    assert untouched(original, b"[the mod's]\n")
    (root / "gamedata_gamma/configs/mod_by_a_mod_too.ltx").unlink()
    commit(root, "drop the override")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(backup))
    assert done.returncode == 0, done.stdout
    assert values(done.stdout)["restored"] == "1", done.stdout
    assert (stand / "gamedata/configs/mod_by_a_mod_too.ltx").read_bytes() == b"[the mod's]\n"
    assert untouched(original, b"[the mod's]\n")
    assert stand_head(root, "check", "--stand", str(stand), "--backup", str(backup)).returncode == 0
    # the stand still runs our dropped override: check names it and fails
    mo2_stand_tool().replace_file(stand / "gamedata/configs/mod_by_a_mod_too.ltx", b"[our override]\n")
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(backup))
    assert check.returncode == 1 and "dropped override" in check.stdout and "mod_by_a_mod_too.ltx" in check.stdout


class held:
    """A handle on the file that shares reading only (no FILE_SHARE_DELETE), as a running game holds its files: no name
    of the file can be deleted while it is open."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def __enter__(self):
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateFileW.restype = wintypes.HANDLE
        k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                                    wintypes.DWORD, wintypes.HANDLE]
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        self.k32 = k32
        self.handle = k32.CreateFileW(str(self.path), 0x80000000, 0x1, None, 3, 0, None)  # GENERIC_READ, SHARE_READ
        assert self.handle not in (None, ctypes.c_void_p(-1).value), ctypes.WinError(ctypes.get_last_error())
        return self

    def __exit__(self, *exc) -> None:
        self.k32.CloseHandle(self.handle)


@pytest.mark.skipif(sys.platform != "win32", reason="Windows sharing modes")
def test_deploy_refuses_before_any_write_when_a_linked_file_cannot_be_unlinked(work):
    root, stand = scenario_repo(work)
    items = mod_link(work, stand, "gamedata/scripts/coop_items.script", MOD_ITEMS)
    # a game running from the stand holds the file through the stand's name (no FILE_SHARE_DELETE): that name cannot
    # be deleted. (NTFS checks sharing per name: a handle through the mod's own name does not block the stand's.)
    with held(stand / "gamedata/scripts/coop_items.script"):
        done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
        assert done.returncode == 1 and "cannot be replaced without writing through them" in done.stdout, done.stdout
        assert "coop_items.script" in done.stdout
        probe = stand_head(root, "links", "--stand", str(stand), "--backup", str(work / "backup"))
        assert probe.returncode == 1 and "blocked=1" in probe.stdout, probe.stdout
    assert untouched(items, MOD_ITEMS) and os.stat(items).st_nlink == 2  # the stand's name is still the link
    assert not (stand / "gamedata/scripts/coop_menu_theme.script").exists()  # nothing was deployed
    probe = stand_head(root, "links", "--stand", str(stand), "--backup", str(work / "backup"))
    assert probe.returncode == 0, probe.stdout
    got = values(probe.stdout)
    assert got["would_replace_links"] == "1" and got["blocked"] == "0" and got["head_files_linked"] == "1", probe.stdout
    assert untouched(items, MOD_ITEMS) and os.stat(items).st_nlink == 2  # the probe wrote nothing


@pytest.mark.skipif(sys.platform != "win32", reason="Windows sharing modes")
def test_deploy_refuses_before_any_write_when_a_profile_is_held(work):
    root, stand = scenario_repo(work)
    user = mod_link(work, stand, "appdata_t/user.ltx", MOD_USER)
    with held(stand / "appdata_t/user.ltx"):
        done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 1 and "appdata_t/user.ltx" in done.stdout, done.stdout
    assert (stand / "gamedata/scripts/coop_items.script").read_text(encoding="utf-8") == "function pick() return 0 end\n"
    assert untouched(user, MOD_USER) and os.stat(user).st_nlink == 2


def test_a_read_only_linked_leftover_leaves_without_touching_its_original(work):
    root, stand = scenario_repo(work)
    rel = "gamedata/scripts/coop_compat_old.script"
    original = mod_link(work, stand, rel, b"-- our Core layer of dev-1, gone from HEAD\n", mod="Anomaly Coop - Core")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout
    assert not (stand / rel).exists() and (work / "backup/removed" / rel).is_file()
    assert untouched(original, b"-- our Core layer of dev-1, gone from HEAD\n")


def test_a_head_file_the_manifest_does_not_list_leaves_when_head_drops_it(work):
    # review 4, B2 (q4_stand N1): stand_overlay.py put HEAD's DXML hook and DLTX patch there; the manifest knows neither
    root, stand = scenario_repo(work)
    hook, patch = "gamedata/scripts/modxml_coop_x.script", "gamedata/configs/scripts/bunker/mod_bun_psi_coop_x.ltx"
    write(root, hook, "-- a DXML hook\n")
    write(root, patch, "![bunker]\n")
    commit(root, "a hook and a patch")
    write(stand, hook, "-- a DXML hook\n")             # HEAD's bytes already there
    write(stand, patch, "![bunker] an older overlay\n")  # an older version of ours: no mod has the path either
    backup = work / "backup"
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(backup))
    assert done.returncode == 0 and values(done.stdout)["listed"] == "2", done.stdout
    (root / hook).unlink()
    (root / patch).unlink()
    commit(root, "drop both")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(backup))
    assert done.returncode == 0, done.stdout
    assert not (stand / hook).exists() and not (stand / patch).exists(), done.stdout
    got = values(done.stdout)
    assert got["stand_extra"] == "0" and got["removed"] == "2", done.stdout
    write(stand, hook, "-- back again\n")
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(backup))
    assert check.returncode == 1 and "modxml_coop_x.script" in check.stdout


# --- review 5, B3 and B4: what HEAD does not have leaves the stand without any memory of the run ------------------------
# B3 (temp/modes_review5b/attacks5.txt A1): stand_overlay.py copies the working tree, untracked files included; a file
# HEAD never had that is not coop_*.script (a DLTX mod_system_*_coop_*.ltx, a DXML modxml_*.script) stayed after the tree
# was cleaned, and deploy and check passed with stand_extra=0. B4 (A2): the deploy's memory lived only in
# temp\stand\head_backup; with it cleaned (or another worktree), a dropped hook and a dropped override of a mod's file
# stayed. Now: a stand file under gamedata that the manifest does not list and HEAD does not have is a leftover; a
# linked mod file whose link was replaced, or a copied mod file that holds a blob of our repositories, comes back from
# the mod when HEAD does not override it; and the memory lives in the stand itself (.raylink-head-deploy.json).

def test_review5_b3_unlisted_files_head_lacks_leave_the_stand(work):
    root, stand = scenario_repo(work)
    extra = {"gamedata/configs/mod_system_zz_coop_extra.ltx": "![extra]\n",
             "gamedata/scripts/modxml_zz_extra.script": "-- a DXML hook HEAD never had\n",
             "gamedata/configs/text/eng/st_zz_extra.xml": "<string_table/>\n",
             "gamedata/scripts/temp/zz_hidden.script": "-- under a temp folder\n"}
    for rel, text in extra.items():
        write(stand, rel, text)
    write(stand, "gamedata/configs/localization.ltx", "[string_table]\nlanguage = rus\n")  # the game writes it
    write(stand, "gamedata/configs/zz_old.ltx.bak", "a backup a tool left: the game never reads it\n")
    backup = work / "backup"  # empty: no memory of an earlier run
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(backup))
    assert done.returncode == 0, done.stdout + done.stderr
    got = values(done.stdout)
    assert got["removed"] == str(len(extra)) and got["stand_extra"] == "0", done.stdout
    for rel in extra:
        assert not (stand / rel).exists() and (backup / "removed" / rel).is_file(), rel
    assert (stand / "gamedata/configs/localization.ltx").is_file()
    assert (stand / "gamedata/configs/zz_old.ltx.bak").is_file()
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "other"))
    assert check.returncode == 0, check.stdout
    write(stand, "gamedata/configs/mod_system_zz_coop_extra.ltx", "![back]\n")
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "other"))
    assert check.returncode == 1 and "mod_system_zz_coop_extra.ltx" in check.stdout, check.stdout


def test_review5_b3_the_overlays_untracked_files_leave_once_the_tree_is_clean(work):
    root, stand = scenario_repo(work)
    shutil.copy2(ROOT / "tools" / "stand_overlay.py", root / "tools" / "stand_overlay.py")
    cfg = "gamedata/configs/zz_root_cfg.ltx"
    mod_cfg = mod_copy(work, stand, cfg, b"[the mod's root config]\n")
    write(root, "gamedata/configs/mod_system_zz_coop_untracked.ltx", "![untracked]\n")
    write(root, "gamedata_gamma/configs/zz_root_cfg.ltx", "[an untracked override of a mod's file]\n")
    done = subprocess.run([sys.executable, "-I", str(root / "tools" / "stand_overlay.py"), str(stand),
                           str(work / "overlay_bk"), "--no-exe"], capture_output=True, text=True)
    assert done.returncode == 0, done.stdout + done.stderr
    assert (stand / "gamedata/configs/mod_system_zz_coop_untracked.ltx").is_file()
    assert (stand / cfg).read_bytes() == b"[an untracked override of a mod's file]\n"
    # the tree is clean again; the stand runs from a backup folder that knows nothing of the overlay
    (root / "gamedata/configs/mod_system_zz_coop_untracked.ltx").unlink()
    (root / "gamedata_gamma/configs/zz_root_cfg.ltx").unlink()
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "fresh"))
    assert done.returncode == 0, done.stdout
    assert not (stand / "gamedata/configs/mod_system_zz_coop_untracked.ltx").exists(), done.stdout
    assert (stand / cfg).read_bytes() == b"[the mod's root config]\n", done.stdout
    assert mod_cfg.read_bytes() == b"[the mod's root config]\n"
    assert values(done.stdout)["stand_extra"] == "0"
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "fresh2"))
    assert check.returncode == 0, check.stdout


HOOK = "gamedata/scripts/modxml_coop_hook.script"
LINKED_CFG = "gamedata/configs/mod_by_a_mod_too.ltx"
COPIED_CFG = "gamedata/configs/zz_root_cfg.ltx"


def b4_stand(work: Path) -> tuple[Path, Path, Path, Path]:
    """HEAD has a DXML hook no mod has, and overrides a linked mod file and a copied one; deployed once (backup a)."""
    root, stand = scenario_repo(work)
    write(root, HOOK, "-- a DXML hook\n")
    write(root, "gamedata_gamma/configs/mod_by_a_mod_too.ltx", "[our override]\n")
    write(root, "gamedata_gamma/configs/zz_root_cfg.ltx", "[our root override]\n")
    commit(root, "a hook and two overrides")
    linked = mod_link(work, stand, LINKED_CFG, b"[the mod's]\n")
    copied = mod_copy(work, stand, COPIED_CFG, b"[the mod's root config]\n")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "a"))
    assert done.returncode == 0, done.stdout
    assert (stand / LINKED_CFG).read_bytes() == b"[our override]\n" and (stand / COPIED_CFG).read_bytes() == \
        b"[our root override]\n"
    for rel in (HOOK, "gamedata_gamma/configs/mod_by_a_mod_too.ltx", "gamedata_gamma/configs/zz_root_cfg.ltx"):
        (root / rel).unlink()
    commit(root, "drop all three")
    return root, stand, linked, copied


def test_review5_b4_the_deploys_memory_travels_with_the_stand(work):
    root, stand, linked, copied = b4_stand(work)
    assert (stand / ".raylink-head-deploy.json").is_file()
    # temp\stand cleaned, or the stand run from another worktree: a backup folder that knows nothing
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "b"))
    assert done.returncode == 0, done.stdout
    assert not (stand / HOOK).exists(), done.stdout
    assert (stand / LINKED_CFG).read_bytes() == b"[the mod's]\n" and (stand / COPIED_CFG).read_bytes() == \
        b"[the mod's root config]\n", done.stdout
    assert untouched(linked, b"[the mod's]\n") and copied.read_bytes() == b"[the mod's root config]\n"
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "c"))
    assert check.returncode == 0, check.stdout
    write(stand, HOOK, "-- back again\n")
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "c"))
    assert check.returncode == 1 and "modxml_coop_hook.script" in check.stdout, check.stdout


def test_review5_b4_without_any_memory_the_manifest_and_our_history_decide(work):
    root, stand, linked, copied = b4_stand(work)
    (stand / ".raylink-head-deploy.json").unlink()  # even the stand's own memory is gone
    links = stand_head(root, "links", "--stand", str(stand), "--backup", str(work / "b"))
    assert links.returncode == 0 and values(links.stdout)["would_remove"] == "1", links.stdout
    assert values(links.stdout)["would_restore"] == "2", links.stdout
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "b"))
    assert check.returncode == 1 and "modxml_coop_hook.script" in check.stdout, check.stdout
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "b"))
    assert done.returncode == 0, done.stdout
    assert not (stand / HOOK).exists(), done.stdout                                   # unlisted, not HEAD's
    assert (stand / LINKED_CFG).read_bytes() == b"[the mod's]\n", done.stdout          # its link was replaced
    assert (stand / COPIED_CFG).read_bytes() == b"[the mod's root config]\n", done.stdout  # a blob of our history
    assert untouched(linked, b"[the mod's]\n")
    assert stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "c")).returncode == 0


def test_review5_b4_a_file_the_game_writes_into_a_copied_mod_file_stays(work):
    # the game rewrites some copied files (caches in gamedata\configs): bytes no repository of ours has are not ours
    root, stand = scenario_repo(work)
    cache = "gamedata/configs/zz_laser_cache.ltx"
    original = mod_copy(work, stand, cache, b"[cache as the mod ships it]\n")
    write(stand, cache, "[cache the game wrote while running]\n")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "b"))
    assert done.returncode == 0 and values(done.stdout)["restored"] == "0", done.stdout
    assert (stand / cache).read_text(encoding="utf-8") == "[cache the game wrote while running]\n"
    assert original.read_bytes() == b"[cache as the mod ships it]\n"
    assert stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "b")).returncode == 0


@pytest.mark.skipif(sys.platform != "win32", reason="junctions are a Windows thing")
def test_review5_a_junction_in_the_stand_is_refused_before_any_write(work):
    # hardening of review 5 (S14): a folder of the stand that is a junction into a mod's folder: deploy would delete
    # the mod's own file and write ours into the mod's folder
    import _winapi

    root, stand = scenario_repo(work)
    write(root, "gamedata_gamma/configs/sub/zz_sub.ltx", "[ours]\n")
    commit(root, "a file under a sub folder")
    mod_dir = work / "mo2" / "mods" / "40- A mod" / "gamedata" / "configs" / "sub"
    write(mod_dir, "zz_sub.ltx", "[the mod's]\n")
    _winapi.CreateJunction(str(mod_dir), str(stand / "gamedata" / "configs" / "sub"))
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "b"))
    assert done.returncode == 1 and "junction" in done.stdout and "configs/sub" in done.stdout, done.stdout
    assert (mod_dir / "zz_sub.ltx").read_text(encoding="utf-8") == "[the mod's]\n"
    assert (stand / "gamedata/scripts/coop_items.script").read_text(encoding="utf-8") == "function pick() return 0 end\n"
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(work / "b"))
    assert check.returncode == 1 and "junction" in check.stdout, check.stdout
    shutil.copy2(ROOT / "tools" / "stand_overlay.py", root / "tools" / "stand_overlay.py")
    over = subprocess.run([sys.executable, "-I", str(root / "tools" / "stand_overlay.py"), str(stand), str(work / "obk"),
                           "--no-exe"], capture_output=True, text=True)
    assert over.returncode != 0 and "junction" in over.stdout + over.stderr, over.stdout + over.stderr
    assert (mod_dir / "zz_sub.ltx").read_text(encoding="utf-8") == "[the mod's]\n"
    os.rmdir(stand / "gamedata" / "configs" / "sub")  # the junction itself (rmtree would follow it)


def mo2_stand_tool():
    import mo2_stand
    return mo2_stand


def test_stand_overlay_replaces_a_linked_stand_file_without_writing_through_it(work):
    root = work / "mod"
    (root / "tools").mkdir(parents=True)
    for name in ("stand_overlay.py", "mo2_stand.py"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    write(root, "gamedata/scripts/coop_items.script", "function pick() return 1 end\n")
    stand = work / "stand"
    (stand / "bin").mkdir(parents=True)
    (stand / ".raylink-stand.json").write_text(json.dumps({"format": 1, "entries": []}), encoding="utf-8")
    items = mod_link(work, stand, "gamedata/scripts/coop_items.script", MOD_ITEMS)
    done = subprocess.run([sys.executable, "-I", str(root / "tools" / "stand_overlay.py"), str(stand), str(work / "bk"),
                           "--no-exe"], capture_output=True, text=True)
    assert done.returncode == 0, done.stdout + done.stderr
    assert (stand / "gamedata/scripts/coop_items.script").read_text(encoding="utf-8") == "function pick() return 1 end\n"
    assert untouched(items, MOD_ITEMS) and os.stat(items).st_nlink == 1


def load_tool(path: Path, name: str):
    """A tool module loaded from its file under a name of its own (not the repository's copy)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # its dataclasses look their module up there
    spec.loader.exec_module(module)
    return module


@pytest.mark.skipif(sys.platform != "win32", reason="junctions are a Windows thing")
def test_round8_stand_head_put_makes_no_folder_through_a_junction(work):
    # guard round 8 (review of round 7, R3): put() made the target's folder before replace_file refused, so a direct
    # call left an empty folder in the mod behind a junction
    import _winapi

    head = load_tool(ROOT / "tools" / "stand" / "stand_head.py", "stand_head_r8")
    mod_dir = work / "mo2" / "mods" / "40- A mod" / "gamedata" / "configs"
    mod_dir.mkdir(parents=True)
    stand = work / "stand"
    (stand / "gamedata").mkdir(parents=True)
    _winapi.CreateJunction(str(mod_dir), str(stand / "gamedata" / "configs"))
    try:
        with pytest.raises(head.Refused, match="junction"):
            head.put(stand, "gamedata/configs/zz_new/zz_sub.ltx", b"[ours]\n")
        assert list(mod_dir.iterdir()) == [], "a folder was made in the mod"
    finally:
        os.rmdir(stand / "gamedata" / "configs")  # the junction itself (rmtree would follow it)


@pytest.mark.skipif(sys.platform != "win32", reason="junctions are a Windows thing")
def test_round8_stand_overlay_makes_no_folder_through_a_junction(work, monkeypatch):
    # R3 for tools/stand_overlay.py: the same mkdir before replace_file. Today the stand's record or the per-file check
    # comes first; with both out of the way the write itself must refuse before it makes a folder
    import _winapi

    root = work / "mod"
    (root / "tools").mkdir(parents=True)
    for name in ("stand_overlay.py", "mo2_stand.py"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    write(root, "gamedata/configs/zz_new/zz_sub.ltx", "[ours]\n")
    real = work / "mo2_mods_folder"
    (real / "stand" / "gamedata").mkdir(parents=True)
    (real / "stand" / "bin").mkdir()
    _winapi.CreateJunction(str(real), str(work / "through"))
    overlay = load_tool(root / "tools" / "stand_overlay.py", "stand_overlay_r8")
    monkeypatch.setattr(overlay.mo2_stand, "remember_on_stand", lambda *a, **k: None)
    monkeypatch.setattr(overlay.mo2_stand, "link_folder", lambda *a, **k: None)
    monkeypatch.setattr(sys, "argv", ["stand_overlay.py", str(work / "through" / "stand"), str(work / "bk"), "--no-exe"])
    try:
        with pytest.raises(OSError, match="junction"):
            overlay.main()
        assert not (real / "stand" / "gamedata" / "configs").exists(), "a folder was made behind the junction"
    finally:
        os.rmdir(work / "through")


PS_HELPERS = r"""
$ErrorActionPreference = 'Stop'
. '{common}'
$cp = [System.Text.Encoding]::GetEncoding(1251)
Write-StandLines -Path '{stand}\appdata_h\user.ltx' -Lines @('coop_nick hoster', 'bind jump kSPACE') -Encoding $cp
Write-StandText -Path '{stand}\fsgame_h.ltx' -Text "new fsgame`r`n" -Encoding $cp
Copy-StandFile -From '{src}\coop_zz_probe.script' -To '{stand}\gamedata\scripts\coop_zz_probe.script'
Remove-StandFile -Path '{stand}\gamedata\scripts\coop_zz_old.script'
Copy-StandTree -From '{src}\appdata_t\..\appdata_t' -To '{stand}\appdata_h2' -ExcludeFiles @('coop_player.key') -ExcludeDirs @('logs')
Write-StandBytes -Path '{stand}\gamedata\configs\axr_options.ltx' -Bytes ([byte[]](65, 66))
'helpers done'
"""


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
def test_powershell_stand_helpers_never_write_through_a_link(work):
    stand, src = work / "stand", work / "src"
    write(src, "coop_zz_probe.script", "-- the probe\n")
    write(src, "appdata_t/shaders.ltx", "[new shaders]\n")
    write(src, "appdata_t/coop_player.key", "secret\n")
    write(src, "appdata_t/logs/xray.log", "log\n")
    linked = {
        "appdata_h/user.ltx": b"coop_world_server 1\r\n",
        "fsgame_h.ltx": b"[fsgame of the mod]\r\n",
        "gamedata/scripts/coop_zz_probe.script": b"-- a mod's script of that name\n",
        "gamedata/scripts/coop_zz_old.script": b"-- a read-only link to remove\n",
        "appdata_h2/shaders.ltx": b"[the mod's shaders]\n",
        "gamedata/configs/axr_options.ltx": b"[the mod's options]\n",
    }
    (stand / ".raylink-stand.json").parent.mkdir(parents=True, exist_ok=True)
    (stand / ".raylink-stand.json").write_text(json.dumps({"format": 1, "entries": []}), encoding="utf-8")
    originals = {rel: mod_link(work, stand, rel, data) for rel, data in linked.items()}
    script = PS_HELPERS.format(common=ROOT / "tools" / "stand_common.ps1", stand=stand, src=src)
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                          capture_output=True, text=True)
    assert done.returncode == 0 and "helpers done" in done.stdout, done.stdout + done.stderr
    for rel, data in linked.items():
        assert untouched(originals[rel], data), rel
        assert os.stat(originals[rel]).st_nlink == 1, rel
    assert (stand / "appdata_h/user.ltx").read_bytes() == b"coop_nick hoster\r\nbind jump kSPACE\r\n"
    assert (stand / "fsgame_h.ltx").read_bytes() == b"new fsgame\r\n"
    assert (stand / "gamedata/scripts/coop_zz_probe.script").read_bytes() == b"-- the probe\n"
    assert os.access(stand / "gamedata/scripts/coop_zz_probe.script", os.W_OK)  # a copy of our own, writable
    assert not (stand / "gamedata/scripts/coop_zz_old.script").exists()
    assert (stand / "appdata_h2/shaders.ltx").read_bytes() == b"[new shaders]\n"
    assert not (stand / "appdata_h2/coop_player.key").exists() and not (stand / "appdata_h2/logs").exists()
    assert (stand / "gamedata/configs/axr_options.ltx").read_bytes() == b"AB"


PS_JUNCTION = r"""
$ErrorActionPreference = 'Stop'
. '{common}'
$cp = [System.Text.Encoding]::GetEncoding(1251)
foreach ($step in @(
    {{ Copy-StandTree -From '{src}' -To '{stand}\appdata_server' }},
    {{ Write-StandText -Path '{stand}\appdata_server\presets\a.ltx' -Text "ours" -Encoding $cp }})) {{
    try {{ & $step; 'wrote' }} catch {{ "refused: $($_.Exception.Message)" }}
}}
"""


@pytest.mark.skipif(shutil.which("powershell") is None or sys.platform != "win32", reason="Windows PowerShell")
def test_powershell_stand_helpers_never_write_through_a_junction(work):
    # review 5 (S14, hardening): a stand folder that is a junction into a mod's folder
    import _winapi

    stand, src = work / "stand", work / "src"
    write(src, "presets/a.ltx", "[new preset]\n")
    mod_presets = work / "mo2" / "mods" / "50- A mod" / "appdata" / "presets"
    write(mod_presets, "a.ltx", "[the mod's preset]\n")
    (stand / "appdata_server").mkdir(parents=True)
    _winapi.CreateJunction(str(mod_presets), str(stand / "appdata_server" / "presets"))
    script = PS_JUNCTION.format(common=ROOT / "tools" / "stand_common.ps1", stand=stand, src=src)
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                          capture_output=True, text=True)
    assert done.returncode == 0, done.stdout + done.stderr
    lines = [l for l in done.stdout.splitlines() if l.startswith(("wrote", "refused"))]
    assert len(lines) == 2 and all(l.startswith("refused") and "junction" in l for l in lines), done.stdout
    assert (mod_presets / "a.ltx").read_text(encoding="utf-8") == "[the mod's preset]\n"
    os.rmdir(stand / "appdata_server" / "presets")


# Review 6, B1 (round 7): Assert-NoJunction looked only at the target's own folder. With the stand's gamedata a junction
# into a mod's gamedata, Write-StandText on gamedata\configs\axr_options.ltx replaced the mod's read-only file and cleared
# its attribute, and Copy-StandFile + Remove-StandFile on gamedata\scripts\coop_zz_base.script deleted the mod's own file
# (temp\modes_review6\hl6.txt, N3a / N3b). Every folder from the volume root down to the target is checked now: the game
# root, the folders above it and every folder below it.
PS_JUNCTION_ABOVE = r"""
$ErrorActionPreference = 'Stop'
. '{common}'
$cp = [System.Text.Encoding]::GetEncoding(1251)
$steps = [ordered]@{{
    'text' = {{ Write-StandText -Path '{stand}\gamedata\configs\axr_options.ltx' -Text "ours" -Encoding $cp }}
    'lines' = {{ Write-StandLines -Path '{stand}\gamedata\configs\deeper\new.ltx' -Lines @('ours') -Encoding $cp }}
    'bytes' = {{ Write-StandBytes -Path '{stand}\gamedata\scripts\coop_zz_new.script' -Bytes ([byte[]](65, 66)) }}
    'copy' = {{ Copy-StandFile -From '{src}\coop_zz_base.script' -To '{stand}\gamedata\scripts\coop_zz_base.script' }}
    'remove' = {{ Remove-StandFile -Path '{stand}\gamedata\scripts\coop_zz_base.script' }}
    'remove_missing' = {{ Remove-StandFile -Path '{stand}\gamedata\scripts\coop_zz_none.script' }}
    'tree' = {{ Copy-StandTree -From '{src}\tree' -To '{stand}\gamedata\configs\sub' }}
    'mirror' = {{ Copy-StandTree -From '{src}\tree' -To '{stand}\gamedata\scripts' -Mirror }}
    'tree_into' = {{ Copy-StandTree -From '{src}\withgamedata' -To '{stand}' }}
    'root_text' = {{ Write-StandText -Path '{stand_j}\fsgame_h.ltx' -Text "ours" -Encoding $cp }}
    'root_remove' = {{ Remove-StandFile -Path '{stand_j}\fsgame.ltx' }}
    'root_deep' = {{ Write-StandText -Path '{stand_j}\appdata\user.ltx' -Text "ours" -Encoding $cp }}
}}
foreach ($name in $steps.Keys) {{
    try {{ & $steps[$name]; "wrote ${{name}}" }} catch {{ "refused ${{name}}: $($_.Exception.Message)" }}
}}
"""


def folder_state(folder: Path) -> dict:
    """Every file and folder under folder: bytes and read-only attribute (folders: None)."""
    out = {}
    for path in sorted(folder.rglob("*")):
        rel = path.relative_to(folder).as_posix()
        out[rel] = None if path.is_dir() else (path.read_bytes(), not os.access(path, os.W_OK))
    return out


@pytest.mark.skipif(shutil.which("powershell") is None or sys.platform != "win32", reason="Windows PowerShell")
def test_powershell_stand_helpers_refuse_a_junction_anywhere_above_the_target(work):
    import _winapi

    stand, src, stand_j = work / "stand", work / "src", work / "stand_j"
    write(src, "coop_zz_base.script", "-- our probe\n")
    write(src, "tree/a.ltx", "[ours a]\n")
    write(src, "withgamedata/gamedata/configs/axr_options.ltx", "[ours]\n")
    mod = work / "mo2" / "mods" / "60- A mod"
    write(mod, "gamedata/configs/axr_options.ltx", "[the mod's options]\n")
    write(mod, "gamedata/scripts/coop_zz_base.script", "-- the mod's script of that name\n")
    write(mod, "gamedata/scripts/other.script", "-- the mod's other script\n")
    root_mod = work / "mo2" / "mods" / "70- A root mod"
    write(root_mod, "fsgame.ltx", "[the mod's fsgame]\n")
    write(root_mod, "appdata/user.ltx", "[the mod's user]\n")
    for path in [*mod.rglob("*"), *root_mod.rglob("*")]:
        if path.is_file():
            os.chmod(path, stat.S_IREAD)
    before = {"mod": folder_state(mod), "root_mod": folder_state(root_mod)}
    stand.mkdir()
    _winapi.CreateJunction(str(mod / "gamedata"), str(stand / "gamedata"))  # one level above the target's folder
    _winapi.CreateJunction(str(root_mod), str(stand_j))  # the game root itself
    try:
        script = PS_JUNCTION_ABOVE.format(common=ROOT / "tools" / "stand_common.ps1", stand=stand, src=src,
                                          stand_j=stand_j)
        done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                              capture_output=True, text=True, timeout=120)
        assert done.returncode == 0, done.stdout + done.stderr
        lines = [l for l in done.stdout.splitlines() if l.startswith(("wrote", "refused"))]
        assert len(lines) == 12, done.stdout + done.stderr
        wrote = [l for l in lines if not (l.startswith("refused") and "junction" in l)]
        assert not wrote, "\n".join(wrote)
        assert {"mod": folder_state(mod), "root_mod": folder_state(root_mod)} == before
    finally:
        os.rmdir(stand / "gamedata")
        os.rmdir(stand_j)


# Every PowerShell file of tools/ is a stand writer (review 5, B1: tools/stand_server.ps1 was in no list, wrote
# fsgame_server.ltx with [IO.File]::WriteAllText and ran robocopy appdata -> appdata_server, and changed 2 mod files
# through hard links). Round 7 (review 6): the files are found when the test runs, not when pytest collects (a scenario
# added meanwhile, such as companions_group.ps1 or phantoms_server.ps1, is checked too), every *.ps1 / *.psm1 under
# tools/ counts whatever it names, and only NOT_A_GAME_ROOT_WRITER may leave one out, with its reason: never a file of
# tools/stand, never a file that takes or names a game root (GAME_ROOT_PS; stand_common.ps1 is the helpers' own file,
# tested by what it does).
GAME_ROOT_PS = re.compile(r"\$(?:Stand|GameDir|TestRoot|GameRoot|Game)\b|RayLinkGames|game-dev", re.I)
NOT_A_GAME_ROOT_WRITER = {
    "tools/package.ps1": "writes only inside the repository (Assert-Inside): the package's stage and releases\\",
    "tools/stand_common.ps1": "the helpers' own file (test_powershell_stand_helpers_never_write_through_a_link, "
                              "..._refuse_a_junction_anywhere_above_the_target)",
}
PS_SUFFIXES = (".ps1", ".psm1")


def powershell_files(tools: Path) -> list[Path]:
    return sorted(p for p in tools.rglob("*") if p.suffix.lower() in PS_SUFFIXES and p.is_file()
                  and "__pycache__" not in p.parts)


def stand_writers(tools: Path) -> list[Path]:
    """Every PowerShell file under tools (found now) but the ones NOT_A_GAME_ROOT_WRITER names."""
    return [p for p in powershell_files(tools) if p.relative_to(tools.parent).as_posix() not in NOT_A_GAME_ROOT_WRITER]


def test_every_powershell_tool_is_a_stand_writer_unless_named_with_its_reason():
    tools = ROOT / "tools"
    writers = {p.relative_to(ROOT).as_posix() for p in stand_writers(tools)}
    every = {p.relative_to(ROOT).as_posix() for p in powershell_files(tools)}
    assert every - writers == set(NOT_A_GAME_ROOT_WRITER), "NOT_A_GAME_ROOT_WRITER names a missing file"
    assert {f"tools/stand/{p.name}" for p in (tools / "stand").glob("*.ps1")} <= writers  # every scenario, always
    assert {"tools/stand_server.ps1", "tools/ded_check.ps1", "tools/ded_probe.ps1", "tools/split_test.ps1",
            "tools/deploy.ps1", "tools/launch.ps1", "tools/stand_hostplay.ps1", "tools/stand_srv.ps1"} <= writers
    for rel in NOT_A_GAME_ROOT_WRITER:
        assert not rel.startswith("tools/stand/"), f"{rel}: a scenario is always linted"
        if rel != "tools/stand_common.ps1":
            assert not GAME_ROOT_PS.search((ROOT / rel).read_text(encoding="utf-8", errors="replace")), \
                f"{rel} takes or names a game root: it is a stand writer, not an exception"


# The rule for a write in a stand writer (round 7). The helpers of stand_common.ps1 (Write-Stand*, Copy-Stand*,
# Remove-StandFile) are the way into a stand. Any other write (Copy-Item, Set-/Add-/Clear-Content, Out-File, Tee-Object,
# Export-*, Remove-Item -Force, Move-/Rename-Item, [IO.File]::WriteAll* / AppendAll* / AppendText / Create* / Open* /
# Copy / Move / Replace, StreamWriter / FileStream / BinaryWriter, .Write() / .CopyTo() / .MoveTo() / .Delete() and
# the like, -OutFile, -RedirectStandardOutput / -Error, > and >>) is allowed only when what it writes, deletes or moves
# lies in the repository:
#   - a copy OUT of the stand into the repository is allowed: a copy's source may be a stand file (a copy only reads
#     it), its destination must be the repository's;
#   - "the repository's": a variable whose every assignment in the file (a parameter: its default) is a Join-Path from
#     $PSScriptRoot, from stand_common.ps1's repository folders ($script:Root, $script:StandDir, $script:MarkDir,
#     $script:ScenarioDir: only in a file that dot-sources stand_common.ps1 and does not assign them itself), or from
#     another such variable, and whose path stays inside the repository; or a Join-Path of such a variable and a child
#     that stays inside (a child's variables count as one plain name: the lint judges the code, not what a caller
#     passes); or such a path with a suffix ($outPath + '.err');
#   - a write into a process's standard input (a StreamWriter on .StandardInput, $in.WriteLine) is allowed;
#   - robocopy, xcopy and cmd's copy never are (Copy-StandTree).
# Round 8 (the review of round 7, R1 and R2): Remove-Item without -Force is a write too (through a junction folder it
# deleted the mod's own file; the scenarios use Remove-StandFile); so are New-Item of a file (or of a link with -Force),
# XmlDocument.Save, an attribute set (.IsReadOnly / .Attributes =, Set-ItemProperty IsReadOnly, attrib),
# [IO.Directory]::Delete / Move; code the lint cannot read (a [IO.File] kept in a variable, Invoke-Expression, a child
# PowerShell's -Command) is refused. A variable set by foreach, Set-Variable or as a parameter without a default is no
# repository folder, and a variable child that the file assigns a ".." is no plain name.

def ps_code(text: str) -> list[tuple[int, str]]:
    """(first line number, code) per logical line: comments and <# #> blocks out, here-strings emptied, a line ending
    in ` or | joined with the next. String literals stay as they are."""
    physical: list[str] = []
    state = None  # None | "block" | "'" / '"' (inside a here-string)
    for line in text.splitlines():
        code, i, n = [], 0, len(line)
        if state in ("'", '"'):
            if not line.startswith(state + "@"):
                physical.append("")
                continue
            code.append(state * 2)
            i, state = 2, None
        while i < n:
            if state == "block":
                j = line.find("#>", i)
                if j < 0:
                    break
                state, i = None, j + 2
                continue
            ch = line[i]
            if line.startswith("<#", i):
                state, i = "block", i + 2
                continue
            if ch == "#" and (i == 0 or line[i - 1] in " \t;({|"):
                break
            if ch == "@" and i + 1 < n and line[i + 1] in "'\"" and not line[i + 2:].strip():
                state = line[i + 1]
                code.append(state * 2)
                break
            if ch in "'\"":
                j = string_end(line, i)
                code.append(line[i:j])
                i = j
                continue
            code.append(ch)
            i += 1
        physical.append("".join(code))
    out: list[tuple[int, str]] = []
    start, acc = None, ""
    for number, code in enumerate(physical, 1):
        start = number if start is None else start
        acc += " " + code
        if blank_strings(code).rstrip().endswith(("`", "|")):
            acc = acc.rstrip().rstrip("`") + " "
            continue
        out.append((start, acc.strip()))
        start, acc = None, ""
    if start is not None:
        out.append((start, acc.strip()))
    return out


def string_end(s: str, i: int) -> int:
    """The index after the string literal that starts at s[i] ('...' with '' inside, "..." with `x and "")."""
    q, j = s[i], i + 1
    while j < len(s):
        if q == '"' and s[j] == "`":
            j += 2
            continue
        if s[j] == q:
            if j + 1 < len(s) and s[j + 1] == q:
                j += 2
                continue
            return j + 1
        j += 1
    return len(s)


def blank_strings(s: str) -> str:
    """s with every string literal's inside replaced by _ (same length: positions stay)."""
    out, i = [], 0
    while i < len(s):
        if s[i] in "'\"":
            j = string_end(s, i)
            out.append(s[i] + "_" * max(0, j - i - 2) + (s[i] if j - i >= 2 else ""))
            i = j
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def statements(code: str) -> list[str]:
    """The statements of a logical line: split at ; { } outside strings and parentheses."""
    out, depth, start, i = [], 0, 0, 0
    while i < len(code):
        ch = code[i]
        if ch in "'\"":
            i = string_end(code, i)
            continue
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth = max(0, depth - 1)
        elif ch in ";{}" and depth == 0:
            out.append(code[start:i])
            start = i + 1
        i += 1
    out.append(code[start:])
    return [s.strip() for s in out if s.strip()]


def var_key(name: str) -> str:
    name = name.lower()
    for scope in ("script:", "local:", "private:"):
        if name.startswith(scope):
            return name[len(scope):]
    return name


def take_expr(s: str, i: int) -> tuple[str, int]:
    """The expression that starts at s[i] (spaces skipped): a $variable with its member / index tail, a (...) group, a
    [type]::call(...), a quoted string or a bare word; and the index after it."""
    while i < len(s) and s[i] in " \t":
        i += 1
    start = i
    if i >= len(s):
        return "", i
    if s[i] in "'\"":
        j = string_end(s, i)
        return s[start:j], j
    if s[i] in "$([":
        depth = 0
        while i < len(s):
            ch = s[i]
            if ch in "'\"":
                i = string_end(s, i)
                continue
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                if depth == 0:
                    break
                depth -= 1
                if depth == 0 and s[start] == "(" and ch == ")" and not s[i + 1:i + 2] in (".", "["):
                    return s[start:i + 1], i + 1
            elif depth == 0 and (ch in " \t,;|" or (ch == "-" and s[i - 1] in " \t")):
                break
            i += 1
        return s[start:i], i
    while i < len(s) and s[i] not in " \t,;)|":
        i += 1
    return s[start:i], i


def split_args(inner: str) -> list[str]:
    """The comma-separated arguments inside a call's parentheses (commas inside strings or groups do not count)."""
    args, depth, start, i = [], 0, 0, 0
    while i < len(inner):
        ch = inner[i]
        if ch in "'\"":
            i = string_end(inner, i)
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(inner[start:i].strip())
            start = i + 1
        i += 1
    args.append(inner[start:].strip())
    return [a for a in args if a]


def unwrap(expr: str) -> str:
    expr = expr.strip()
    while expr.startswith("(") and expr.endswith(")"):
        group, end = take_expr(expr, 0)
        if end != len(expr):
            return expr
        expr = group[1:-1].strip()
    return expr


def split_plus(expr: str) -> list[str]:
    """The terms of a top-level + concatenation (one term when there is none; [] when it is not one)."""
    terms, i = [], 0
    while True:
        term, j = take_expr(expr, i)
        if not term:
            return []
        terms.append(term)
        rest = expr[j:].lstrip()
        if not rest:
            return terms
        if not rest.startswith("+"):
            return []
        i = len(expr) - len(rest) + 1


CLIMB = "@climb"  # the key of `known` that holds the variables a ".." was assigned to (no variable name has an @)


def name_part(term: str, known: "dict | None" = None) -> "str | None":
    """One term of a child name as a "/"-path: a quoted literal ($var / $(...) inside it read as one plain name), or a
    variable ($x, $x.Name, $x.BaseName: one plain name, unless the file assigns it a text with ".."; round 8, R2);
    None otherwise."""
    term = term.strip()
    if len(term) >= 2 and term[0] in "'\"" and term[-1] == term[0]:
        body = term[1:-1]
        if term[0] == '"':
            body = re.sub(r"\$\((?:[^()]|\([^()]*\))*\)|\$\{[^}]*\}|\$[\w:]+(?:\.\w+)*", "x", body)
        return body.replace("\\", "/")
    m = re.fullmatch(r"\$([\w:]+)(?:\.(?:Name|BaseName))?", term)
    if m:
        return None if known and var_key(m.group(1)) in known.get(CLIMB, ()) else "x"
    return None


def literal_child(expr: str, known: "dict | None" = None) -> "str | None":
    """A Join-Path child: a name part or a (...) + concatenation of name parts."""
    terms = split_plus(unwrap(expr))
    parts = [name_part(t, known) for t in terms]
    return None if not parts or any(p is None for p in parts) else "".join(parts)


def repo_path(expr: "str | None", known: dict, root: str) -> "str | None":
    """The "/"-path expr names when it is a repository path by the rule above, else None."""
    if not expr:
        return None
    expr = unwrap(expr)
    terms = split_plus(expr)
    if len(terms) > 1:  # a path with a suffix ($outPath + '.err'): the suffix may not leave the file's folder
        base, tail = repo_path(terms[0], known, root), [name_part(t, known) for t in terms[1:]]
        return None if base is None or any(t is None or "/" in t for t in tail) else base + "".join(tail)
    m = re.fullmatch(r"\(Resolve-Path\s+(?:-LiteralPath\s+|-Path\s+)?(.+)\)\.(?:Path|ProviderPath)", expr, re.S | re.I)
    if m:
        return repo_path(m.group(1), known, root)
    m = re.fullmatch(r"\$([\w:]+)", expr)
    if m:
        return known.get(var_key(m.group(1)))
    m = re.match(r"Join-Path\s+(?:-Path\s+)?", expr, re.I)
    if not m:
        return None
    base_expr, i = take_expr(expr, m.end())
    rest = re.sub(r"^-ChildPath\s+", "", expr[i:].strip(), flags=re.I)
    child_expr, j = take_expr(rest, 0)
    if rest[j:].strip():
        return None  # more than one child, or a switch: not this rule's
    base, child = repo_path(base_expr, known, root), literal_child(child_expr, known)
    if base is None or child is None or re.match(r"^(?:[A-Za-z]:|/)", child):
        return None
    path = posixpath.normpath(posixpath.join(base, child))
    return path if path == root or path.startswith(root + "/") else None


ASSIGN = re.compile(r"\$([\w:]+)\s*([-+*/%]?)=(?!=)")


def assignment_rhs(s: str, i: int) -> str:
    """An assignment's right side: up to ; or an unmatched ) } ] at depth 0."""
    depth, j = 0, i
    while j < len(s):
        ch = s[j]
        if ch in "'\"":
            j = string_end(s, j)
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif ch in ";," and depth == 0:
            break
        j += 1
    return s[i:j].strip()


STAND_COMMON_SOURCED = re.compile(r"^\s*\.\s+\(?\s*Join-Path\s+\$PSScriptRoot\s+'((?:\.\.\\)*stand_common\.ps1)'",
                                  re.I | re.M)


FOREACH_VAR = re.compile(r"\bforeach\s*\(\s*\$([\w:]+)\s+in\b", re.I)
SET_VARIABLE = re.compile(r"(?<![\w$@.:\\/-])(?:Set-Variable|sv|New-Variable|nv)(?![\w-])([^;|]*)", re.I)
PARAM_LIST = re.compile(r"\bparam\s*\(|\bfunction\s+[\w:-]+\s*\(", re.I)


def unknown_assignments(code: str) -> set[str]:
    """Variables a file sets without `$x = ...` (round 8, R2): a foreach variable, Set-Variable / New-Variable, and a
    parameter without a default (of the script's param() or of a function: the caller passes it)."""
    out = {var_key(m.group(1)) for m in FOREACH_VAR.finditer(blank_strings(code))}
    for m in SET_VARIABLE.finditer(code):
        args = m.group(1)
        named = re.search(r"-Name\s+['\"]?([\w:]+)", args, re.I)
        first = re.match(r"\s+(?!-)['\"]?([\w:]+)", args)
        if named or first:
            out.add(var_key((named or first).group(1)))
    blank = blank_strings(code)
    for m in PARAM_LIST.finditer(blank):
        group, _ = take_expr(blank, m.end() - 1)
        for arg in split_args(group[1:-1]):
            depth, name, i = 0, None, 0
            while i < len(arg):  # the parameter's name: the first $name outside [attributes]
                if arg[i] == "[":
                    depth += 1
                elif arg[i] == "]":
                    depth -= 1
                elif arg[i] == "$" and depth == 0:
                    name = re.match(r"\$([\w:]+)", arg[i:])
                    break
                i += 1
            if name and not re.match(r"\s*=", arg[i + len(name.group(0)):]):
                out.add(var_key(name.group(1)))
    return out


def repo_vars(lines: list[tuple[int, str]], script_dir: str, root: str, text: str) -> tuple[dict, set]:
    """(repository variables: name -> "/"-path, and under CLIMB the variables a ".." is assigned to; the variables
    that hold a process's standard input)."""
    assigned: dict[str, list[str]] = {}
    for _, code in lines:
        for m in ASSIGN.finditer(blank_strings(code)):  # never an "$x = " inside a string
            assigned.setdefault(var_key(m.group(1)), []).append("" if m.group(2) else assignment_rhs(code, m.end()))
    for name in unknown_assignments("\n".join(code for _, code in lines)):
        assigned.setdefault(name, []).append("")  # set in a way the lint does not follow: never a repository path
    bases = {"psscriptroot": script_dir}
    sourced = STAND_COMMON_SOURCED.search(text)  # the real stand_common.ps1, not a file of that name elsewhere
    if sourced and posixpath.normpath(posixpath.join(script_dir, sourced.group(1).replace("\\", "/"))) == \
            root + "/tools/stand_common.ps1":
        bases.update(root=root, standdir=root + "/temp/stand", markdir=root + "/temp/gates",
                     scenariodir=root + "/tools/stand")
    known: dict = {k: v for k, v in bases.items() if k not in assigned}
    known[CLIMB] = frozenset(name for name, rhss in assigned.items() if any(".." in r for r in rhss))
    changed = True
    while changed:
        changed = False
        for name, rhss in assigned.items():
            if name not in known:
                paths = [repo_path(r, known, root) for r in rhss]
                if paths and all(p is not None for p in paths):
                    known[name], changed = paths[0], True
    stdin = {name for name, rhss in assigned.items() if rhss and all(re.search(r"\.StandardInput\b", r) for r in rhss)}
    return known, stdin


# robocopy / xcopy / cmd's copy, also when the command line is a string (cmd /c "copy ...", Start-Process robocopy.exe);
# a statement that only prints or throws a text naming them is no copy
COPY_TOOL = re.compile(r"\b(?:robocopy|xcopy)\b|\bcmd(?:\.exe)?\b.*[\s'\"]/[ck]\b.*\b(?:copy|move|ren|rename|del|erase|"
                       r"type|echo|mklink)\b", re.I)
OUTPUT_ONLY = re.compile(r"^(?:Write-(?:Host|Output|Warning|Verbose|Error|Information|Debug)|throw)\b", re.I)
CMD = r"(?<![\w$@.:\\/-])"  # a command name starts here (not $copy, @copy, .Move, the tail of Copy-StandFile)
WRITES = {
    "copy-item": re.compile(CMD + r"(?:Copy-Item|copy|cp|cpi)(?![\w-])", re.I),
    "content": re.compile(CMD + r"(?:Set-Content|sc|Add-Content|ac|Clear-Content|clc|Out-File|Tee-Object|tee|"
                          r"Export-Csv|epcsv|Export-Clixml)(?![\w-])", re.I),
    # round 8 (R1): every delete counts, not only -Force (through a junction folder Remove-Item deleted a mod's file)
    "move": re.compile(CMD + r"(?:(?:Remove-Item|rm|del|erase|ri|rd|rmdir)(?![\w-])|"
                       r"(?:Move-Item|move|mv|mi|Rename-Item|ren|rni)(?![\w-]))", re.I),
    "file-method": re.compile(r"\[(?:System\.)?IO\.(?:File|FileInfo)\]::(WriteAll\w*|AppendAll\w*|AppendText|Create\w*|"
                              r"Open\w*|Copy|Move|Replace|Encrypt|Decrypt|SetAttributes|Delete)\s*\(", re.I),
    "stream": re.compile(r"\[(?:System\.)?IO\.(?:StreamWriter|FileStream|BinaryWriter)\]::new\s*\(|New-Object\s+"
                         r"(?:-TypeName\s+)?(?:System\.)?IO\.(?:StreamWriter|FileStream|BinaryWriter)\b", re.I),
    "member": re.compile(r"\.(Write|WriteLine|WriteAllText|CopyTo|MoveTo|Create|CreateText|AppendText|Delete|"
                         r"Encrypt|Decrypt|Save)\s*\(", re.I),
    # round 8 (R2): New-Item of a file (-ItemType File or none) truncates an existing one with -Force, a link with -Force
    # replaces the name; an attribute set on a file is set for every link of it; [IO.Directory] deletes and moves;
    # code the lint cannot read (a type kept in a variable, Invoke-Expression, a child PowerShell's -Command)
    "new-item": re.compile(CMD + r"(?:New-Item|ni)(?![\w-])", re.I),
    "attribute": re.compile(r"\.(?:IsReadOnly|Attributes)\s*(?:[-+*/]?=)(?!=)|" + CMD + r"attrib(?:\.exe)?(?![\w-])|"
                            + CMD + r"(?:Set-ItemProperty|sp)(?![\w-])(?=[^;|]*-Name\s+['\"]?(?:IsReadOnly|Attributes)\b)",
                            re.I),
    "dir-method": re.compile(r"\[(?:System\.)?IO\.(?:Directory|DirectoryInfo)\]::(Delete|Move)\s*\(", re.I),
    "unreadable": re.compile(r"=\s*\[(?:System\.)?IO\.(?:File|FileInfo|Directory|DirectoryInfo|StreamWriter|FileStream|"
                             r"BinaryWriter)\]\s*$|" + CMD + r"(?:Invoke-Expression|iex)(?![\w-])|" + CMD
                             + r"(?:powershell|pwsh)(?:\.exe)?(?![\w-])(?=[^;|]*\s-(?:Command|c|EncodedCommand|enc|e)\b)",
                             re.I),
    "out-param": re.compile(r"\s-(?:OutFile|RedirectStandardOutput|RedirectStandardError)\s*:?\s+", re.I),
    "redirect": re.compile(r"(?<![-<>=])(?:\d|\*)?>>?(?![>&])"),
}


def param_value(stmt: str, names: str, start: int = 0) -> "str | None":
    m = re.compile(rf"\s-(?:{names})\s*:?\s+", re.I).search(stmt, start)
    return take_expr(stmt, m.end())[0] if m else None


def call_args(stmt: str, at: int) -> list[str]:
    """The arguments of the call whose ( is at stmt[at]."""
    group, _ = take_expr(stmt, at)
    return split_args(group[1:-1]) if group.startswith("(") and group.endswith(")") else []


def write_problems(stmt: str, known: dict, stdin: set, root: str) -> list[str]:
    """Why each write of a statement is not allowed ([]: it writes only into the repository or a process's stdin)."""
    blank = blank_strings(stmt)
    ok = lambda expr: repo_path(expr, known, root) is not None  # noqa: E731
    out = []
    if COPY_TOOL.search(stmt) and not OUTPUT_ONLY.match(stmt):
        out.append("robocopy / xcopy / cmd copy write into existing files: use Copy-StandTree / Copy-StandFile")
    for kind, rx in WRITES.items():
        for m in rx.finditer(blank):
            if kind == "copy-item" and not ok(param_value(stmt, "Destination", m.end())):
                out.append("Copy-Item into a stand: Copy-StandFile (a copy OUT of the stand goes to a repository path)")
            elif kind == "content":
                if re.fullmatch(r"Tee-Object|tee", m.group(0), re.I) and re.search(r"\s-Variable\b", stmt[m.end():], re.I):
                    continue  # into a variable
                if not ok(param_value(stmt, "LiteralPath|Path|FilePath", m.end())):
                    out.append("writes a file in place: Write-StandText / Write-StandLines")
            elif kind == "move":
                paths = [param_value(stmt, "LiteralPath|Path", m.end())]
                if re.search(r"\s-Destination\b", stmt[m.end():], re.I):
                    paths.append(param_value(stmt, "Destination", m.end()))
                if not all(ok(p) for p in paths):
                    out.append("deletes or moves a stand file: Remove-StandFile")
            elif kind == "file-method":
                args, method = call_args(stmt, m.end() - 1), m.group(1).lower()
                targets = args[1:2] if method == "copy" else args[:2] if method in ("move", "replace") else args[:1]
                if not targets or not all(ok(t) for t in targets):
                    out.append(f"[IO.File]::{m.group(1)} into a stand: the helpers of stand_common.ps1")
            elif kind == "stream":
                if stmt[m.end() - 1] == "(":  # [IO.StreamWriter]::new(...)
                    args = call_args(stmt, m.end() - 1)
                else:  # New-Object IO.StreamWriter <arguments> / -ArgumentList <arguments>
                    given = param_value(stmt, "ArgumentList|Args", m.end()) or take_expr(stmt, m.end())[0]
                    args = split_args(unwrap(given)) if given.startswith("(") and "," in blank_strings(given) \
                        else [given]
                first = args[0] if args else ""
                if not (re.search(r"\.StandardInput\b", first) or ok(first)):
                    out.append("a stream written into a file: Write-StandBytes / Write-StandText")
            elif kind == "member":
                method = m.group(1).lower()
                receiver = re.search(r"(\$[\w:]+(?:\.\w+)*)$", blank[:m.start()])
                parts = receiver.group(1).split(".") if receiver else []
                if method in ("write", "writeline") and parts and (
                        var_key(parts[0][1:]) in stdin or "standardinput" in [p.lower() for p in parts[1:]]):
                    continue
                if method in ("copyto", "save"):  # FileInfo.CopyTo(destination), XmlDocument.Save(path): our file
                    args = call_args(stmt, m.end() - 1)
                    if args and ok(args[0]):
                        continue
                out.append(f".{m.group(1)}() of something that is not a process's standard input or a repository file")
            elif kind == "new-item":
                kind_ = (param_value(stmt, "ItemType|Type", m.end()) or "File").strip("'\"").lower()
                force = re.search(r"\s-Force\b", stmt[m.end():], re.I)
                if kind_ == "directory" or (kind_ in ("hardlink", "symboliclink", "junction") and not force):
                    continue  # a folder, or a new link name (a scenario's bin_b): no file's bytes change
                path = param_value(stmt, "LiteralPath|Path", m.end()) or take_expr(stmt, m.end())[0]
                if not ok(path):
                    out.append("New-Item makes or truncates a stand file: Write-StandText / Write-StandBytes")
            elif kind == "attribute":
                path = param_value(stmt, "LiteralPath|Path", m.end())
                if not (path and ok(path)):
                    out.append("sets a file's attributes, which every hard link of it shares: never on a stand file")
            elif kind == "dir-method":
                args, method = call_args(stmt, m.end() - 1), m.group(1).lower()
                targets = args[:2] if method == "move" else args[:1]
                if not targets or not all(ok(t) for t in targets):
                    out.append(f"[IO.Directory]::{m.group(1)} in a stand: Remove-StandFile")
            elif kind == "unreadable":
                out.append("code the lint cannot read (a type kept in a variable, Invoke-Expression, a child "
                           "PowerShell's -Command): write it out with the helpers of stand_common.ps1")
            elif kind == "out-param" and not ok(take_expr(stmt, m.end())[0]):
                out.append("a file written by -OutFile / -RedirectStandard*: point it into the repository")
            elif kind == "redirect":
                target = take_expr(stmt, m.end())[0]
                if target.lower() != "$null" and not ok(target):
                    out.append("a redirection into a file: Write-StandText")
    return out


def lint_ps(text: str, script_dir: str, root: str) -> list[tuple[int, str, str]]:
    """(line, statement, why) for every write in a stand writer that the rule above does not allow."""
    lines = ps_code(text)
    known, stdin = repo_vars(lines, script_dir, root, text)
    return [(number, stmt, why) for number, code in lines for stmt in statements(code)
            for why in write_problems(stmt, known, stdin, root)]


def stand_writer_problems(tools: Path) -> list[str]:
    root = tools.parent.as_posix()
    return [f"{p.relative_to(tools.parent).as_posix()}:{number}: {why}: {stmt[:160]}"
            for p in stand_writers(tools)
            for number, stmt, why in lint_ps(p.read_text(encoding="utf-8", errors="replace"), p.parent.as_posix(), root)]


def test_stand_scripts_write_into_the_stand_only_through_the_helpers():
    bad = stand_writer_problems(ROOT / "tools")
    assert not bad, "a write into a stand that is not one of stand_common.ps1's helpers (docs/MODES.md section 5):\n" \
        + "\n".join(bad)


# The lint's own cases (round 7): each text is a scenario of tools\stand that dot-sources stand_common.ps1 (HEADER).
HEADER = "param([string]$Stand = 'E:\\RayLinkGames\\GAMMA\\game-dev', [string]$Tag = 'b57')\n" \
         ". (Join-Path $PSScriptRoot '..\\stand_common.ps1')\n"
LINT_BAD = {
    "by-name": "$fixture = Join-Path $Stand 'zz.txt'\n"
               "Copy-Item -LiteralPath $a -Destination (Join-Path $fixture 'y') -Force\n",
    "outdir-moved": "$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n$OutDir = $Stand\n"
                    "Copy-Item -LiteralPath $a -Destination (Join-Path $OutDir 'x.log') -Force\n",
    "outdir-escapes": "$OutDir = Join-Path $PSScriptRoot '..\\..\\..\\..\\elsewhere'\n"
                      "Copy-Item -LiteralPath $a -Destination (Join-Path $OutDir 'x.log') -Force\n",
    "child-climbs": "$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n"
                    "Copy-Item -LiteralPath $a -Destination (Join-Path $OutDir '..\\..\\..\\x.log')\n",
    "redirect": "'ours' > (Join-Path $Stand 'gamedata\\configs\\axr_options.ltx')\n",
    "append": "$log = Join-Path $Stand 'appdata\\logs\\x.log'\n'ours' >> $log\n",
    "tee": "Get-Content $a | Tee-Object -FilePath (Join-Path $Stand 'fsgame_h.ltx')\n",
    "streamwriter": "$w = [System.IO.StreamWriter]::new((Join-Path $Stand 'user.ltx'))\n",
    "new-object": "$w = New-Object System.IO.StreamWriter (Join-Path $Stand 'user.ltx')\n",
    "create": "[System.IO.File]::Create((Join-Path $Stand 'd.txt')).Close()\n",
    "createtext": "$w = [IO.File]::CreateText((Join-Path $Stand 'd.txt'))\n",
    "appendtext": "$w = [IO.File]::AppendText((Join-Path $Stand 'd.txt'))\n",
    "writeall": "[IO.File]::WriteAllText(\"$Stand\\x.ltx\", 'y')\n",
    "cmd-copy": "cmd /c copy /y a.txt \"$Stand\\x.txt\"\n",
    "xcopy": "xcopy $src $Stand /e /y\n",
    "robocopy": "robocopy $src $Stand /E\n",
    "copy-into": "Copy-Item -LiteralPath $a -Destination $Stand\n",
    "split-line": "Copy-Item -LiteralPath $a `\n    -Destination (Join-Path $Stand 'x')\n",
    "set-content": "Set-Content -Path (Join-Path $Stand 'x') -Value 1\n",
    "remove-force": "Remove-Item -LiteralPath (Join-Path $Stand 'x') -Force\n",
    "move": "Move-Item -LiteralPath $a -Destination (Join-Path $Stand 'x')\n",
    "outfile": "Invoke-WebRequest -Uri $u -OutFile (Join-Path $Stand 'x')\n",
    "copyto": "$f = Get-Item (Join-Path $Stand 'x')\n$f.CopyTo((Join-Path $Stand 'y'), $true)\n",
    "after-block-comment": "<# a note #> Copy-Item -LiteralPath $a -Destination $Stand\n",
    "redirect-stdout": "Start-Process x -RedirectStandardOutput (Join-Path $Stand 'o.txt')\n",
}
LINT_GOOD = {
    "copy-out": "$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n"
                "Copy-Item -LiteralPath (Join-Path $Stand 'appdata\\logs\\x.log') -Destination "
                "(Join-Path $OutDir \"${Tag}_x_$($pair[1]).log\") -Force\n",
    "copy-out-concat": "$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n"
                       "Copy-Item -LiteralPath $l -Destination (Join-Path $OutDir (\"${Tag}_h_\" + $_.Name + '.log'))\n",
    "copy-out-keep": "$keep = Join-Path $script:StandDir 'axr_options.before.ltx'\n"
                     "if (-not (Test-Path -LiteralPath $keep)) { Copy-Item -LiteralPath $opt -Destination $keep }\n",
    "stdin": "$in = [System.IO.StreamWriter]::new($p.StandardInput.BaseStream, $enc)\n"
             "foreach ($l in @('a', 'b')) { $in.WriteLine($l); Start-Sleep 1 }\n$in.Close()\n",
    "stdin-direct": "$server.StandardInput.WriteLine('quit')\n",
    "null": "& git status 2>$null\n$x = foo 2>&1\nbar *>&1 | Out-Null\nbaz > $null\n",
    "strings": "Write-Host \"a -> b > c\"\n$l = $l -replace '[0-9a-f]{32,}', '<hidden>'\n",
    "comments": "# Copy-Item -Force into $Stand, robocopy\n<# robocopy $a $Stand\n Set-Content x #>\n",
    "here-string": "$t = @'\nSet-Content -Path $Stand\nrobocopy a b\n'@\n",
    "fixture": "$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\\..')).Path\n"
               "$fixture = Join-Path $repo \"tests\\fixtures\\saves\\$Save\"\n"
               "[System.IO.File]::WriteAllLines((Join-Path $fixture 'README.md'), $lines, $enc)\n"
               "foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $fixture $f.Name) -Force }\n",
    "param-default": "param([string]$OutDir = (Join-Path $PSScriptRoot '..\\..\\temp\\stand'), [string]$Out = 'o')\n"
                     "$outPath = Join-Path $OutDir $Out\n$errPath = $outPath + '.err'\n"
                     "Start-Process x -RedirectStandardOutput $outPath -RedirectStandardError $errPath\n",
    "helpers": "Write-StandText -Path (Join-Path $Stand 'fsgame_h.ltx') -Text 'x' -Encoding $cp\n"
               "Copy-StandFile -From $log -To (Join-Path $Stand 'y')\nRemove-StandFile -Path $probe\n"
               "Copy-StandTree @copy\n$copy = @{ From = $a; To = $b }\n",
    "split-line-out": "$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n"
                      "Copy-Item -LiteralPath $log `\n    -Destination (Join-Path $OutDir 'x.log') -Force\n",
    "two-writes": "$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n"
                  "foreach ($p in $pairs) { Copy-Item -LiteralPath $p -Destination (Join-Path $OutDir 'a'); "
                  "Copy-Item -LiteralPath $p -Destination (Join-Path $OutDir 'b') }\n",
    "tee-variable": "$x = Get-Content $a | Tee-Object -Variable seen\n",
    "string-text": "Write-Host \"$OutDir = $Stand; Copy-Item -Destination $Stand\"\n",
}
LINT_BAD["second-write"] = ("$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n"
                            "foreach ($p in $pairs) { Copy-Item -LiteralPath $p -Destination (Join-Path $OutDir 'a'); "
                            "Copy-Item -LiteralPath $p -Destination (Join-Path $Stand 'b') }\n")
LINT_BAD["string-assignment"] = ("$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n$OutDir = \"$Stand\"\n"
                                 "Copy-Item -LiteralPath $a -Destination (Join-Path $OutDir 'x')\n")
LINT_BAD["alias"] = "copy $a (Join-Path $Stand 'x')\ndel (Join-Path $Stand 'y') -Force\nsc -Path $Stand -Value 1\n"
LINT_BAD["cmd-quoted"] = "cmd /c \"copy /y a.txt $Stand\\x.txt\"\n"
LINT_BAD["start-robocopy"] = "Start-Process -FilePath 'robocopy.exe' -ArgumentList \"$a $Stand /E\" -Wait\n"
LINT_BAD["start-cmd"] = "Start-Process cmd -ArgumentList '/c copy a b' -Wait\n"
LINT_GOOD["message"] = "Write-Host 'robocopy is not used here: Copy-StandTree'\nif ($x) { throw \"no xcopy\" }\n"
# Guard round 8 (the review of round 7, R1): Remove-Item without -Force deleted a mod's read-write file through a
# junction folder; every delete is a write now, and a stand file goes through Remove-StandFile
OUT_DIR = "$OutDir = Join-Path $PSScriptRoot '..\\..\\temp\\stand'\n"
LINT_BAD["remove-plain"] = "Remove-Item -LiteralPath (Join-Path $Stand 'x')\n"
LINT_BAD["remove-test-path"] = ("$log = Join-Path $Stand 'appdata\\logs\\x.log'\n"
                                "if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }\n")
LINT_BAD["remove-alias"] = "del (Join-Path $Stand 'y')\nri -Path (Join-Path $Stand 'z')\n"
LINT_GOOD["remove-own"] = OUT_DIR + "Remove-Item -LiteralPath (Join-Path $OutDir 'x.out') -ErrorAction SilentlyContinue\n"
# R2: writes the lint did not see (each one changed a hard-linked mod file in the review's harness, or could)
LINT_BAD["new-item-file"] = "New-Item -ItemType File -Force -Path (Join-Path $Stand 'gamedata\\configs\\x.ltx') | Out-Null\n"
LINT_BAD["new-item-default"] = "New-Item -Path (Join-Path $Stand 'x.txt') -Value 'ours' -Force\n"
LINT_BAD["new-link-force"] = "New-Item -ItemType HardLink -Force -Path (Join-Path $Stand 'x') -Target $a\n"
LINT_BAD["xml-save"] = "$xml = [xml](Get-Content $a)\n$xml.Save((Join-Path $Stand 'gamedata\\configs\\x.xml'))\n"
LINT_BAD["isreadonly"] = "(Get-Item (Join-Path $Stand 'x')).IsReadOnly = $false\n"
LINT_BAD["set-itemproperty"] = "Set-ItemProperty -LiteralPath (Join-Path $Stand 'x') -Name IsReadOnly -Value $false\n"
LINT_BAD["attrib"] = "attrib -r (Join-Path $Stand 'x')\n"
LINT_BAD["attributes"] = "$f = Get-Item (Join-Path $Stand 'x')\n$f.Attributes = 'Normal'\n"
LINT_BAD["directory-delete"] = "[System.IO.Directory]::Delete((Join-Path $Stand 'gamedata\\x'), $true)\n"
LINT_BAD["directory-move"] = "[IO.Directory]::Move((Join-Path $Stand 'a'), (Join-Path $Stand 'b'))\n"
LINT_BAD["foreach-reassign"] = (OUT_DIR + "foreach ($OutDir in @($Stand)) "
                                "{ Copy-Item -LiteralPath $a -Destination (Join-Path $OutDir 'x') }\n")
LINT_BAD["set-variable"] = (OUT_DIR + "Set-Variable -Name OutDir -Value $Stand\n"
                            "Copy-Item -LiteralPath $a -Destination (Join-Path $OutDir 'x')\n")
LINT_BAD["function-parameter"] = ("function Put([string]$StandDir) "
                                  "{ Copy-Item -LiteralPath $a -Destination (Join-Path $StandDir 'x') }\nPut $Stand\n")
LINT_BAD["param-in-function"] = ("function Put {\n    param([string]$StandDir)\n"
                                 "    Copy-Item -LiteralPath $a -Destination (Join-Path $StandDir 'x')\n}\n")
LINT_BAD["child-var-climbs"] = (OUT_DIR + "$up = '..\\..\\..\\..\\game-dev\\gamedata\\x.ltx'\n"
                                "Copy-Item -LiteralPath $a -Destination (Join-Path $OutDir $up)\n")
LINT_BAD["io-file-in-variable"] = "$f = [IO.File]\n$f::WriteAllText((Join-Path $Stand 'x'), 'y')\n"
LINT_BAD["iex"] = "iex \"Set-Content -Path $Stand\\x -Value 1\"\n"
LINT_BAD["invoke-expression"] = "Invoke-Expression $cmd\n"
LINT_BAD["child-powershell"] = "powershell -NoProfile -Command \"Set-Content -Path '$Stand\\x' -Value 1\"\n"
LINT_BAD["child-pwsh-encoded"] = "pwsh -EncodedCommand $b64\n"
LINT_GOOD["new-item-dir"] = "New-Item -ItemType Directory -Force -Path (Join-Path $Stand 'appdata_t') | Out-Null\n"
LINT_GOOD["new-link"] = "New-Item -ItemType HardLink -Path (Join-Path $Stand 'bin_b\\x.dll') -Target $a | Out-Null\n"
LINT_GOOD["new-item-own-file"] = OUT_DIR + "New-Item -ItemType File -Force -Path (Join-Path $OutDir 'x.txt') | Out-Null\n"
LINT_GOOD["xml-save-own"] = OUT_DIR + "$xml.Save((Join-Path $OutDir 'x.xml'))\n"
LINT_GOOD["child-var-plain"] = OUT_DIR + "$name = 'x.log'\nCopy-Item -LiteralPath $a -Destination (Join-Path $OutDir $name)\n"
LINT_GOOD["powershell-file"] = "$o = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard -Script $s)\n"
LINT_GOOD["function-parameter-own"] = ("function Put([string]$Name) "
                                       "{ Copy-StandFile -From $a -To (Join-Path $Stand $Name) }\nPut 'x'\n")


@pytest.mark.parametrize("case", sorted(LINT_BAD))
def test_powershell_write_lint_catches(case):
    script_dir = (ROOT / "tools" / "stand").as_posix()
    bad = lint_ps(HEADER + LINT_BAD[case], script_dir, ROOT.as_posix())
    assert bad, f"the lint let this write into the stand pass:\n{LINT_BAD[case]}"


@pytest.mark.parametrize("case", sorted(LINT_GOOD))
def test_powershell_write_lint_allows_the_repository_and_stdin(case):
    script_dir = (ROOT / "tools" / "stand").as_posix()
    assert lint_ps(HEADER + LINT_GOOD[case], script_dir, ROOT.as_posix()) == []


def test_powershell_write_lint_needs_stand_common_for_its_folders():
    # without the dot-sourced stand_common.ps1, $script:Root / $script:StandDir name nothing known
    text = "param([string]$Root)\nCopy-Item -LiteralPath $a -Destination (Join-Path $Root 'temp\\x')\n" \
           "Copy-Item -LiteralPath $a -Destination (Join-Path $script:StandDir 'x')\n"
    assert len(lint_ps(text, (ROOT / "tools").as_posix(), ROOT.as_posix())) == 2
    # a stand_common.ps1 that is not tools\stand_common.ps1 (a file of that name next to a scenario) names nothing
    other = ". (Join-Path $PSScriptRoot 'stand_common.ps1')\n" \
            "Copy-Item -LiteralPath $a -Destination (Join-Path $script:StandDir 'x')\n"
    assert len(lint_ps(other, (ROOT / "tools" / "stand").as_posix(), ROOT.as_posix())) == 1
    assert lint_ps(other, (ROOT / "tools").as_posix(), ROOT.as_posix()) == []


def test_a_new_stand_script_is_linted_without_being_listed(tmp_path):
    # a scenario nobody added to any list: found and checked when the test runs (not when pytest collected)
    tools = tmp_path / "tools"
    (tools / "stand").mkdir(parents=True)
    (tools / "stand" / "zz_new_scenario.ps1").write_text(HEADER + LINT_BAD["redirect"], encoding="utf-8")
    (tools / "new_tool.ps1").write_text("param([string]$Game)\nSet-Content -Path (Join-Path $Game 'x') -Value 1\n",
                                        encoding="utf-8")
    (tools / "sub").mkdir()
    (tools / "sub" / "helper.psm1").write_text("function f { robocopy a b }\n", encoding="utf-8")
    found = {p.relative_to(tmp_path).as_posix() for p in stand_writers(tools)}
    assert found == {"tools/stand/zz_new_scenario.ps1", "tools/new_tool.ps1", "tools/sub/helper.psm1"}
    bad = stand_writer_problems(tools)
    assert {line.split(":", 1)[0] for line in bad} == found, bad


# The Python tools of tools/ that can write into a game root (they take --stand / --game / an output root, name the
# stand, or write through tools/mo2_stand.py): no in-place write. A stand file goes through mo2_stand.replace_file /
# remove_file; what stays below writes into our own folders or a file it has just made, each line named with its reason.
GAME_ROOT_PY = re.compile(r"--stand\b|--game\b|RayLinkGames|game-dev|import mo2_stand", re.I)
IN_PLACE_PY = re.compile(r"\.write_(?:bytes|text)\(|\bopen\([^\n]*['\"](?![^'\"]*x)[rbt]*[wa+][rbt+]*['\"]|"
                         r"\bshutil\.(?:copy\w*|move)\(|\bos\.(?:chmod|utime|truncate)\(|\.(?:chmod|touch)\(")
PY_WRITES_ALLOWED = [
    ("check_gates.py", r"^mark\.write_text\(", "the tests mark in the repository's temp\\gates"),
    ("mo2_stand.py", r"^shutil\.copy2\(src, dst\)$", "_place: the old name went first (_unlink): a new file"),
    ("mo2_stand.py", r"^os\.chmod\(dst, stat\.S_IWRITE \| stat\.S_IREAD\)", "_place: our own fresh copy"),
    ("mo2_stand.py", r"^tmp\.write_text\(json\.dumps\(state", "its manifest's temp file, unlinked first, then os.replace"),
    ("mo2_stand.py", r"^Path\(args\.report\)\.write_text\(", "the report, under the repository's temp"),
    ("stand_overlay.py", r"^keep\.write_bytes\(", "the backup folder (never a stand file)"),
    ("stand_overlay.py", r"^listed\.write_text\(", "the backup folder's list of added files"),
    ("stand_head.py", r"^\(backup / name\)\.write_text\(", "a list of the backup folder (the run history)"),
    ("stand_head.py", r"^keep\.write_bytes\(data\)$", "keep_copy: the backup folder"),
]
def py_stand_writers(tools: Path) -> list[Path]:
    """Found when the test runs (round 7), as the PowerShell ones are."""
    return sorted(p for p in tools.rglob("*.py") if "__pycache__" not in p.parts
                  and (p.name == "mo2_stand.py" or GAME_ROOT_PY.search(p.read_text(encoding="utf-8", errors="replace"))))


def test_python_stand_tools_never_write_in_place():
    writers = py_stand_writers(ROOT / "tools")
    names = {p.name for p in writers}
    assert {"stand_head.py", "stand_overlay.py", "mo2_stand.py", "check_gates.py"} <= names, names
    bad, used = [], set()
    for path in writers:
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            code = line.strip()
            if code.startswith("#") or not IN_PLACE_PY.search(code):
                continue
            hit = [i for i, (name, rx, _) in enumerate(PY_WRITES_ALLOWED) if name == path.name and re.search(rx, code)]
            if hit:
                used.update(hit)
            else:
                bad.append(f"{path.relative_to(ROOT).as_posix()}:{number}: {code}")
    assert not bad, "an in-place write in a tool that writes into a game root (use mo2_stand.replace_file):\n" + \
        "\n".join(bad)
    stale = [PY_WRITES_ALLOWED[i][:2] for i in range(len(PY_WRITES_ALLOWED)) if i not in used]
    assert not stale, f"PY_WRITES_ALLOWED names lines that are gone: {stale}"


SERVER_FSGAME = "$app_data_root$ = true | false | $fs_root$ | appdata\\\r\n$game_data$ = false| true| $fs_root$| gamedata\\\r\n"


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
def test_stand_server_never_writes_through_a_link(work):
    # review 5, B1: fsgame_server.ltx and appdata_server\ of a launcher-made stand may be hard links to the mods' files
    stand = work / "stand"
    (stand / "bin").mkdir(parents=True)
    (stand / ".raylink-stand.json").write_text(json.dumps({"format": 1, "entries": []}), encoding="utf-8")
    (stand / "fsgame.ltx").write_bytes(SERVER_FSGAME.encode("cp1251"))
    write(stand, "appdata/shaders.ltx", "[the mods' new shaders]\n")
    write(stand, "appdata/presets/a.ltx", "[preset a]\n")
    write(stand, "appdata/user.ltx", "coop_nick the player\n")
    linked = {
        "fsgame_server.ltx": b"[an old fsgame_server of a mod]\r\n",
        "appdata_server/shaders.ltx": b"[the mod's old shaders]\n",
        "appdata_server/presets/a.ltx": b"[the mod's preset a]\n",
    }
    originals = {rel: mod_link(work, stand, rel, data) for rel, data in linked.items()}
    args = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tools" / "stand_server.ps1"),
            "-Stand", str(stand)]
    done = subprocess.run(args, capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, done.stdout + done.stderr
    for rel, data in linked.items():
        assert untouched(originals[rel], data), rel
        assert os.stat(originals[rel]).st_nlink == 1, rel
    server = (stand / "fsgame_server.ltx").read_bytes().decode("cp1251")
    assert "appdata_server\\" in server and "$game_data$" in server, server
    assert (stand / "appdata_server/shaders.ltx").read_text(encoding="utf-8") == "[the mods' new shaders]\n"
    assert (stand / "appdata_server/presets/a.ltx").read_text(encoding="utf-8") == "[preset a]\n"
    user = (stand / "appdata_server/user.ltx").read_bytes()
    assert b"coop_nick server" in user and b"the player" not in user
    # again: the same bytes stay, user.ltx is kept
    (stand / "appdata_server/user.ltx").write_bytes(b"coop_nick server two\r\n")
    again = subprocess.run(args, capture_output=True, text=True, timeout=120)
    assert again.returncode == 0, again.stdout + again.stderr
    assert (stand / "appdata_server/user.ltx").read_bytes() == b"coop_nick server two\r\n"


# --- review 4, B1: a scenario's verdict is bound to this run ------------------------------------------------------------

B1_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
. '{tools}\stand_common.ps1'
function Invoke-HeadProfile {{ param([string]$Stand) }}  # no stand here: a no-op
$s = @{{ Name = 'fake_group'; Script = '{script}'; Args = ''; TagArg = $false; StandArg = $null;
    Pass = @('steps done: host True, client True', 'squads: PASS'); Bad = @('squads: FAIL') }}
$stale = Join-Path $script:StandDir 'b57_stand_fake_group.out'
New-Item -ItemType Directory -Force -Path $script:StandDir | Out-Null
[System.IO.File]::WriteAllLines($stale, [string[]]@('steps done: host True, client True', 'squads: PASS (an older run)'))
$lock = $null
if ('{lock}' -eq 'yes') {{ $lock = [System.IO.File]::Open($stale, 'Open', 'Write', 'Read') }}  # an orphaned scenario
try {{ $r = Invoke-Scenario -Scenario $s -Tag 'b57' -Stand '{stand}' }} finally {{ if ($lock) {{ $lock.Close() }} }}
"verdict Ok=$($r.Ok); problems: $($r.Problems -join ' | ')"
"""


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
@pytest.mark.parametrize(("script", "body", "lock", "ok", "why"), [
    # the older output of the same tag is held open: this run is not judged (before: Ok=True from the old .out)
    ("fake_group.ps1", "Write-Output 'squads: FAIL (this run)'\nexit 1\n", "yes", False, "could not be removed"),
    # the scenario fails and exits 1; the older PASS output must not count
    ("fake_group.ps1", "Write-Output 'squads: FAIL (this run)'\nexit 1\n", "no", False, "scenario exit code: 1"),
    # the scenario prints every pass line but throws at the end: a failed run
    ("fake_group.ps1", "Write-Output 'steps done: host True, client True'\nWrite-Output 'squads: PASS'\n"
                       "$ErrorActionPreference = 'Stop'\nthrow 'the server did not quit'\n", "no", False,
     "scenario exit code: 1"),
    # the guard cannot start the scenario (no such script): no 'run finished' from this run's file either
    ("missing_group.ps1", "", "no", False, "stderr"),
    # control: a passing scenario passes
    ("fake_group.ps1", "Write-Output 'steps done: host True, client True'\nWrite-Output 'squads: PASS'\n", "no", True, ""),
])
def test_scenario_verdict_is_bound_to_this_run(work, script, body, lock, ok, why):
    tools = work / "tools"
    (tools / "stand").mkdir(parents=True)
    shutil.copy2(ROOT / "tools" / "stand_common.ps1", tools / "stand_common.ps1")
    shutil.copy2(ROOT / "tools" / "stand" / "run_guarded.ps1", tools / "stand" / "run_guarded.ps1")
    write(tools, "stand/fake_group.ps1", body)
    code = B1_SCRIPT.format(tools=tools, script=script, lock=lock, stand=work / "nostand")
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", code],
                          capture_output=True, text=True)
    assert done.returncode == 0, done.stdout + done.stderr
    line = next(l for l in done.stdout.splitlines() if l.startswith("verdict"))
    assert line.startswith(f"verdict Ok={ok}"), done.stdout
    assert why in line, line


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
@pytest.mark.parametrize("profile", [False, True], ids=["stock", "profile"])
def test_deploy_ps1_never_builds_over_the_launchers_stand(work, profile):
    # R21: deploy.ps1's robocopy /MIR (stock) would purge the launcher's stand and write through its links
    game = work / "game"
    (game / "bin").mkdir(parents=True)
    (game / "fsgame.ltx").write_text("$app_data_root$ = true | false | $fs_root$ | appdata\\\r\n", encoding="cp1251")
    exe = work / "AnomalyDX11AVX.exe"
    exe.write_bytes(b"MZ")
    stand = work / "game-dev"
    (stand / "gamedata" / "scripts").mkdir(parents=True)
    (stand / ".raylink-stand.json").write_text(json.dumps({"format": 1, "entries": []}), encoding="utf-8")
    items = mod_link(work, stand, "gamedata/scripts/e.script", b"a GAMMA mod's file")
    args = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tools" / "deploy.ps1"),
            "-TestRoot", str(stand), "-SkipGameBin", "-GameDir", str(game), "-BuiltExe", str(exe),
            "-EngineGamedata", str(work), "-ModGamedata", str(work / "none")]
    if profile:
        args += ["-Profile", "G.A.M.M.A", "-Mo2Dir", str(work / "mo2")]
    done = subprocess.run(args, capture_output=True, text=True, timeout=120)
    assert done.returncode != 0 and "launcher's stand" in done.stdout + done.stderr, done.stdout + done.stderr
    assert untouched(items, b"a GAMMA mod's file") and (stand / "gamedata/scripts/e.script").is_file()


# --- review 4, B4: exe_source does not trust engine-ci's index; the project file and the SDK are compared -------------

VCXPROJ = ("<Project>\r\n  <ItemDefinitionGroup>\r\n    <PreprocessorDefinitions>XRGAME_EXPORTS;%(PreprocessorDefinitions)"
           "</PreprocessorDefinitions>\r\n  </ItemDefinitionGroup>\r\n  <ItemGroup>\r\n"
           "    <ClCompile Include=\"coop\\coop_items.cpp\" />\r\n    <ClCompile Include=\"coop\\coop_levels.cpp\" />\r\n"
           "    <ClCompile Include=\"Level.cpp\" />\r\n  </ItemGroup>\r\n  <ItemGroup>\r\n"
           "    <ClInclude Include=\"coop\\coop_items.h\" />\r\n  </ItemGroup>\r\n</Project>\r\n")


def built_with_project(root: Path, engine: Path, exe: Path) -> Path:
    write(engine, "src/xrGame/xrGame.vcxproj", VCXPROJ)
    write(engine, "sdk/include/dx_extra.h", "#pragma once\n")
    commit(engine, "the project file and the SDK")
    return built_from_head(root, engine, exe)


def rebuild(ci: Path, exe: Path) -> None:
    ci_exe(ci, exe)


def test_exe_source_stats_every_file_before_trusting_the_index(repos):
    # E2: built from an uncommitted edit, then `git checkout` put the file back: it matches the index again
    root, engine, exe = repos
    ci = built_with_project(root, engine, exe)
    assert gates.exe_source(engine, exe, ci)[1] == []
    rel = "src/xrGame/coop/coop_levels.cpp"
    assert rel not in sh(ci, "status", "--porcelain")  # unchanged since engine-ci's checkout: the index shortcut
    write(ci, rel, "// an uncommitted edit of Ядро\n")
    rebuild(ci, exe)
    # the build happened a while ago: every source is older than the exe, the exe older than now
    past = time.time() - 600
    for path in [p for tree in ("src", "sdk") for p in (ci / tree).rglob("*") if p.is_file()]:
        os.utime(path, (past, past))
    built = time.time() - 300
    os.utime(ci.joinpath(*gates.CI_EXE), (built, built))
    sh(ci, "checkout", "--", rel)  # no rebuild; the exe keeps the edit; git's index holds the file's new time
    assert rel not in sh(ci, "status", "--porcelain")
    source, problems = gates.exe_source(engine, exe, ci)
    assert source == "" and any("changed after the exe was built" in p and rel in p for p in problems), problems


@pytest.mark.parametrize(("case", "why"), [
    ("define", "differs from engine HEAD's beyond the coop items"),
    ("outside_coop", "differs from engine HEAD's beyond the coop items"),
    ("extra_coop", "compiles 1 coop source(s) engine HEAD does not have: coop_far_old.cpp"),
    ("lacking_coop", "does not compile 1 coop source(s) of engine HEAD: coop_levels.cpp"),
    ("reordered", None),  # vcxproj_add writes the coop items in its own order, and lists headers: the same build
])
def test_exe_source_compares_engine_cis_project_file(repos, case, why):
    # E3: engine-ci's xrGame.vcxproj was never compared: a define or a source outside src/ went through
    root, engine, exe = repos
    ci = built_with_project(root, engine, exe)
    text = (ci / "src/xrGame/xrGame.vcxproj").read_bytes().decode("utf-8")  # CRLF as MSBuild's file has it
    if case == "define":
        text = text.replace("XRGAME_EXPORTS;", "XRGAME_EXPORTS;COOP_SKIP_CHECKS;")
    elif case == "outside_coop":
        text = text.replace("    <ClCompile Include=\"Level.cpp\" />", "    <ClCompile Include=\"Level.cpp\" />\r\n"
                                                                          "    <ClCompile Include=\"..\\..\\sdk\\patch.cpp\" />")
    elif case == "extra_coop":
        text = text.replace("<ClCompile Include=\"Level.cpp\" />", "<ClCompile Include=\"Level.cpp\" />\r\n"
                                                                    "    <ClCompile Include=\"coop\\coop_far_old.cpp\" />")
    elif case == "lacking_coop":
        text = text.replace("    <ClCompile Include=\"coop\\coop_levels.cpp\" />\r\n", "")
    else:
        text = text.replace("    <ClCompile Include=\"coop\\coop_items.cpp\" />\r\n    <ClCompile Include=\"coop\\coop_levels.cpp\" />",
                            "    <ClCompile Include=\"coop\\coop_levels.cpp\" />\r\n    <ClCompile Include=\"coop\\coop_items.cpp\" />")
        text = text.replace("    <ClInclude Include=\"coop\\coop_items.h\" />", "    <ClInclude Include=\"coop\\coop_lamps.h\" />\r\n"
                                                                              "    <ClInclude Include=\"coop\\coop_items.h\" />")
    (ci / "src/xrGame/xrGame.vcxproj").write_bytes(text.encode("utf-8"))
    rebuild(ci, exe)
    source, problems = gates.exe_source(engine, exe, ci)
    if why is None:
        assert problems == [] and source == sh(engine, "rev-parse", "HEAD"), problems
    else:
        assert source == "" and any(why in p for p in problems), problems


@pytest.mark.parametrize(("case", "why"), [
    ("edited", "differs from engine HEAD in 1 file(s): sdk/include/dx_extra.h"),
    ("extra", "engine HEAD does not have: sdk/lib/extra.lib"),
])
def test_exe_source_compares_the_sdk(repos, case, why):
    # E4: sdk/ (headers and libraries the build reads) was never compared
    root, engine, exe = repos
    ci = built_with_project(root, engine, exe)
    if case == "edited":
        write(ci, "sdk/include/dx_extra.h", "#pragma once\n#define COOP_SKIP 1\n")
    else:
        (ci / "sdk/lib").mkdir(parents=True)
        (ci / "sdk/lib/extra.lib").write_bytes(b"!<arch>\n")
    rebuild(ci, exe)
    source, problems = gates.exe_source(engine, exe, ci)
    assert source == "" and any(why in p for p in problems), problems


# --- tests.ok never comes from a stale Lua runner (its sources or its lua51.lib changed) ------------------------------

def fake_lua_runner(root: Path, stamp: str = "") -> Path:
    """temp/lua/runlua.exe as tools/test_lua.cmd builds it: the source stamp is a string inside the exe."""
    exe = root.joinpath(*gates.LUA_RUNNER)
    exe.parent.mkdir(parents=True, exist_ok=True)
    exe.write_bytes(b"MZ\x00runlua\x00" + (stamp or gates.lua_stamp(root)).encode("ascii") + b"\x00")
    return exe


def run_tests_mark(root: Path, capsys) -> tuple[int, str]:
    """--tests-mark begin, then write after green suites: the exit code of write and what it printed."""
    state = root / "temp" / "gates" / "tests.state"
    assert gates.main(["--root", str(root), "--tests-mark", "begin"]) == 0
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(capsys.readouterr().out, encoding="utf-8")
    code = gates.main(["--root", str(root), "--tests-mark", "write", "--state", str(state), "--native", "0",
                       "--lua", "0"])
    return code, capsys.readouterr().out


def test_lua_stamp_is_the_one_test_lua_cmd_builds(work, monkeypatch):
    root = work / "mod"
    write(root, "tests/lua/runlua.c", "int main() { return 0; }\n")
    write(root, "tests/lua/native_coop.cpp", "#include \"lua.hpp\"\n#include \"coop_routes.h\"\n#include <string>\n"
                                             "  #include \"coop_indented.h\"\n#include \"coop_lua_fn.h\" // a comment\n")
    write(root, "engine/src/xrCoop/coop_routes.h", "#pragma once\n")
    write(root, "engine/src/xrCoop/coop_lua_fn.h", "#pragma once\nint f();\n")
    write(root, "engine/src/xrCoop/coop_indented.h", "#pragma once\n")  # only a line that starts with #include
    write(root, "tools/test_lua.cmd", "@echo off\n")
    write(work, "lib/lua51.lib", "!<arch>\nthe engine's LuaJIT\n")
    monkeypatch.setenv("LUA51_LIB", str(work / "lib" / "lua51.lib"))
    sha = lambda path: hashlib.sha1(path.read_bytes()).hexdigest()[:8]  # noqa: E731
    assert gates.lua_stamp(root) == "".join(sha(root / r) for r in (
        "tests/lua/runlua.c", "tests/lua/native_coop.cpp", "engine/src/xrCoop/coop_routes.h",
        "engine/src/xrCoop/coop_lua_fn.h", "tools/test_lua.cmd")) + sha(work / "lib" / "lua51.lib")


def test_lua51_lib_is_the_variable_or_engine_ci_build(work, monkeypatch):
    # one place resolves the lib the runner links, and no old build stands in for a missing one
    root = work / "mod"
    built = ("_build", "_game", "bin_dbg", "x64", "Release-AVX", "lua51.lib")
    write(root, "/".join(("engine",) + built), "!<arch>\nan old build\n")
    monkeypatch.delenv("LUA51_LIB", raising=False)
    ci = root.joinpath("engine-ci", *built)
    assert gates.lua51_lib(root) == ci
    assert gates.lua_stamp(root).endswith("missing0")
    write(root, "/".join(("engine-ci",) + built), "!<arch>\nengine-ci's build\n")
    assert gates.lua_stamp(root).endswith(hashlib.sha1(ci.read_bytes()).hexdigest()[:8])
    monkeypatch.setenv("LUA51_LIB", str(work / "gone.lib"))
    assert gates.lua51_lib(root) == work / "gone.lib" and gates.lua_stamp(root).endswith("missing0")


def test_lua_stamp_prints_the_lib_and_the_stamp_test_lua_cmd_reads(monkeypatch, capsys):
    # tests/tools/test_lua_runners.py builds a runner from these two lines
    monkeypatch.setenv("LUA51_LIB", str(ROOT / "tools" / "check_gates.py"))  # any file: only its bytes are hashed
    assert gates.main(["--root", str(ROOT), "--lua-stamp"]) == 0
    assert capsys.readouterr().out.splitlines() == [f"lib={ROOT / 'tools' / 'check_gates.py'}",
                                                    f"stamp={gates.lua_stamp(ROOT)}"]


def test_lj_vm_obj_is_the_variable_else_engine_ci_else_engine(work, monkeypatch, capsys):
    # one place resolves the LuaJIT VM object tools/test_luajit.cmd packs; with none, engine-ci's path is named
    root = work / "mod"
    rel = ("src", "3rd party", "luajit-2", "src", "lj_vm.obj")
    ci, own = root.joinpath("engine-ci", *rel), root.joinpath("engine", *rel)
    monkeypatch.delenv("LJ_VM_OBJ", raising=False)
    assert gates.lj_vm_obj(root) == ci
    write(root, "/".join(("engine",) + rel), "the VM object gen_luajit_artifacts.bat made in engine\n")
    assert gates.lj_vm_obj(root) == own
    write(root, "/".join(("engine-ci",) + rel), "the VM object of the engine build\n")
    assert gates.lj_vm_obj(root) == ci
    monkeypatch.setenv("LJ_VM_OBJ", str(work / "named.obj"))
    assert gates.lj_vm_obj(root) == work / "named.obj"
    assert gates.main(["--root", str(root), "--lj-vm"]) == 0
    assert capsys.readouterr().out.splitlines() == [f"lj_vm={work / 'named.obj'}"]


def test_lua_runner_of_this_repository_counts_exactly_when_it_says_the_stamp_of_check_gates():
    # the stamp the gate wants is the string the runner prints for -stamp, whole: never a part of it
    exe = ROOT.joinpath(*gates.LUA_RUNNER)
    said = subprocess.run([str(exe), "-stamp"], capture_output=True, text=True).stdout.strip() if exe.is_file() else ""
    want = gates.lua_stamp(ROOT)
    assert (gates.lua_runner_stale(ROOT) is None) == (said == want), f"the runner says {said}, check_gates wants {want}"


def test_tests_mark_refuses_a_run_on_a_stale_lua_runner(repos, capsys):
    root, engine, _ = repos
    marks = root / "temp" / "gates"
    write(root, "tests/lua/runlua.c", "int main() { return 0; }\n")
    write(root, "tests/lua/native_coop.cpp", "#include \"coop_routes.h\"\n")
    write(engine, "src/xrCoop/coop_routes.h", "#pragma once\n")
    commit(root, "runner sources")
    commit(engine, "a header")
    fake_lua_runner(root)
    write(engine, "src/xrCoop/coop_routes.h", "#pragma once\nint changed();\n")
    commit(engine, "the header changed: the runner must be rebuilt")

    code, out = run_tests_mark(root, capsys)  # test_lua.cmd could not rebuild: it ran the old runner, exit 0
    assert code == 1 and "stale runner" in out and not (marks / "tests.ok").exists(), out
    fake_lua_runner(root)  # rebuilt from the sources now
    code, out = run_tests_mark(root, capsys)
    assert code == 0 and (marks / "tests.ok").exists(), out
    (root.joinpath(*gates.LUA_RUNNER)).unlink()
    code, out = run_tests_mark(root, capsys)
    assert code == 1 and "no temp\\lua\\runlua.exe" in out, out


def test_tests_mark_refuses_a_runner_linked_to_another_lua51_lib(repos, capsys, monkeypatch):
    root, engine, _ = repos
    marks = root / "temp" / "gates"
    monkeypatch.delenv("LUA51_LIB", raising=False)
    lib = root.joinpath("engine-ci", "_build", "_game", "bin_dbg", "x64", "Release-AVX", "lua51.lib")
    lib.parent.mkdir(parents=True)
    lib.write_bytes(b"!<arch>\nthe LuaJIT of the engine build\n")
    write(root, "tests/lua/runlua.c", "int main() { return 0; }\n")
    write(root, "tests/lua/native_coop.cpp", "#include \"coop_routes.h\"\n")
    write(engine, "src/xrCoop/coop_routes.h", "#pragma once\n")
    commit(root, "runner sources")
    commit(engine, "a header")
    fake_lua_runner(root)
    code, out = run_tests_mark(root, capsys)
    assert code == 0 and (marks / "tests.ok").exists(), out
    # engine-ci was built again: the runner still holds the LuaJIT it was linked with
    lib.write_bytes(b"!<arch>\nthe LuaJIT of a newer engine build\n")
    code, out = run_tests_mark(root, capsys)
    assert code == 1 and "stale runner" in out and not (marks / "tests.ok").exists(), out
    # a runner stamp that only starts with the gate's (one part more, as a lib the gate did not hash) is another stamp
    fake_lua_runner(root, gates.lua_stamp(root) + "a6a7dcdf")
    code, out = run_tests_mark(root, capsys)
    assert code == 1 and "stale runner" in out and not (marks / "tests.ok").exists(), out
    fake_lua_runner(root)  # rebuilt with the new lib
    code, out = run_tests_mark(root, capsys)
    assert code == 0 and (marks / "tests.ok").exists(), out
