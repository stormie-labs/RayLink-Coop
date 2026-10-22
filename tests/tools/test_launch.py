"""tools/launch.ps1 on a fake test root, with -NoStart: everything is prepared, the game is not started."""
import os
import subprocess
from pathlib import Path

from conftest import ROOT

LAUNCH = ROOT / "tools" / "launch.ps1"
CP1251 = "cp1251"

LOADOUTS = """[loadout_base]
[stalker_loadout]:loadout_base
gamma_test_knife = false, 1
device_pda_1 = false, 1
paid_item = true, 1, 100
[stalker_money]
money = 777
"""


def make_root(work: Path) -> Path:
    root = work / "stand"
    for bin_dir in ("bin", "bin_b"):
        (root / bin_dir).mkdir(parents=True)
        (root / bin_dir / "AnomalyCoopDX11AVX.exe").write_bytes(b"MZ")
    configs = root / "gamedata" / "configs"
    (configs / "items" / "settings").mkdir(parents=True)
    (configs / "items" / "settings" / "new_game_loadouts.ltx").write_text(LOADOUTS, encoding=CP1251)
    return root


def launch(root: Path, *args: str) -> str:
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(LAUNCH), *args,
           "-GameDir", str(root), "-NoStart"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


def test_no_start_prints_the_command(work):
    root = make_root(work)
    out = launch(root, "b", "-Connect", "127.0.0.1")
    assert "-fsltx fsgame_b.ltx" in out
    assert "-coop_connect 127.0.0.1" in out
    assert str(root / "bin_b" / "AnomalyCoopDX11AVX.exe") in out


def test_new_game_uses_the_stands_own_loadouts(work):
    root = make_root(work)
    out = launch(root, "a", "-NewGame")
    assert "gamma_test_knife" in out and "777 RU" in out
    opt = (root / "gamedata" / "configs" / "axr_options.ltx").read_text(encoding=CP1251)
    assert "new_game_loadout = gamma_test_knife,device_pda_1" in opt


def test_options_never_written_through_a_hard_link(work):
    root = make_root(work)
    original = work / "gamma_mod_axr_options.ltx"
    original.write_text("[options]\n        video/hud/show_minimap           = false\n", encoding=CP1251)
    os.link(original, root / "gamedata" / "configs" / "axr_options.ltx")
    launch(root, "a", "-NewGame")
    assert original.read_text(encoding=CP1251) == "[options]\n        video/hud/show_minimap           = false\n"
    opt = (root / "gamedata" / "configs" / "axr_options.ltx").read_text(encoding=CP1251)
    assert "show_minimap           = true" in opt and "[character_creation]" in opt


def test_minimap_option_never_written_through_a_hard_link(work):
    root = make_root(work)
    original = work / "gamma_mod_axr_options.ltx"
    original.write_text("[options]\n        video/hud/show_minimap           = false\n", encoding=CP1251)
    os.link(original, root / "gamedata" / "configs" / "axr_options.ltx")
    launch(root, "b", "-Connect", "127.0.0.1")
    assert original.read_text(encoding=CP1251) == "[options]\n        video/hud/show_minimap           = false\n"
    opt = (root / "gamedata" / "configs" / "axr_options.ltx").read_text(encoding=CP1251)
    assert "show_minimap           = true" in opt
