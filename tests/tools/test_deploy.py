"""tools/deploy.ps1 guards: the stock and the GAMMA stand never take each other's root (on a fake game)."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import ROOT

DEPLOY = ROOT / "tools" / "deploy.ps1"
FSGAME = "$app_data_root$         = true \t| false\t| $fs_root$\t\t | appdata\\\r\n"


@pytest.fixture
def game(work):
    g = work / "game"
    (g / "bin").mkdir(parents=True)
    (g / "bin" / "some.dll").write_bytes(b"dll")
    (g / "db").mkdir()
    (g / "fsgame.ltx").write_text(FSGAME, encoding="cp1251", newline="")
    exe = work / "AnomalyDX11AVX.exe"
    exe.write_bytes(b"MZ")
    engine = work / "engine_gd"
    (engine / "scripts").mkdir(parents=True)
    (engine / "scripts" / "e.script").write_text("engine", encoding="utf-8")
    return {"GameDir": g, "BuiltExe": exe, "EngineGamedata": engine, "ModGamedata": work / "no_mod_gamedata"}


def deploy(paths: dict, root: Path, *extra: str) -> subprocess.CompletedProcess:
    args = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(DEPLOY), "-TestRoot", str(root),
            "-SkipGameBin"]
    for key, value in paths.items():
        args += [f"-{key}", str(value)]
    return subprocess.run(args + list(extra), capture_output=True, text=True, timeout=120)


def test_stock_deploy_works_on_a_fresh_root(game, work):
    r = deploy(game, work / "stock")
    assert r.returncode == 0, r.stdout + r.stderr
    assert (work / "stock" / "gamedata" / "scripts" / "e.script").read_text(encoding="utf-8") == "engine"


def test_stock_deploy_refuses_a_gamma_stand(game, work):
    stand = work / "gamma_stand"
    (stand / "gamedata" / "scripts").mkdir(parents=True)
    (stand / ".mo2_stand.json").write_text("{}", encoding="utf-8")
    original = work / "gamma_mod_e.script"
    original.write_text("a GAMMA mod's file", encoding="utf-8")
    os.link(original, stand / "gamedata" / "scripts" / "e.script")
    r = deploy(game, stand)
    assert r.returncode != 0
    assert "mo2_stand" in r.stdout + r.stderr
    assert original.read_text(encoding="utf-8") == "a GAMMA mod's file"


@pytest.mark.skipif(sys.platform != "win32", reason="junctions are a Windows thing")
def test_profile_deploy_refuses_a_root_with_a_db_junction(game, work):
    import _winapi

    stock = work / "stock"
    stock.mkdir()
    _winapi.CreateJunction(str(game["GameDir"] / "db"), str(stock / "db"))
    r = deploy(game, stock, "-Profile", "G.A.M.M.A", "-Mo2Dir", str(work / "no_mo2"))
    assert r.returncode != 0
    assert "junction" in (r.stdout + r.stderr).lower()
    assert not (stock / ".mo2_stand.json").exists()
