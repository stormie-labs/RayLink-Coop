"""The P106 inventory generator, including the import's grep filters."""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import ROOT

SCRIPT = ROOT / "tools/gen_mod_names.py"


def write(root: Path, path: str, data: bytes = b"") -> None:
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)


@pytest.fixture
def inventory(tmp_path: Path) -> Path:
    (tmp_path / "stand scripts").mkdir()
    (tmp_path / "stock scripts").mkdir()
    write(tmp_path, "import.txt")
    write(tmp_path, "tools/layers.txt", b"stock-list tools/stock_files.txt\nstock engine/src/**\n")
    write(tmp_path, "tools/stock_files.txt", b"engine/src/stock.cpp\n")
    return tmp_path


def generate(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(SCRIPT), "--root", str(root),
         "--stand-scripts", str(root / "stand scripts"), "--stock-scripts", str(root / "stock scripts"),
         "--build", "fixture-b2", "--import-words", str(root / "import.txt")],
        capture_output=True, text=True, encoding="utf-8",
    )


def test_generator_filters_and_merges_idempotently(inventory: Path):
    hand = b"  name DAO  # a nickname \r\nignore beta_mod\t# generic word\n debt R1 zonepath  "
    seed = b"build fixture-b1 2026-11-25 old stand 10 1\nscript earlier_mod fixture-b1\n" + hand
    write(inventory, "tools/mod_names.txt", seed)
    write(inventory, "stock scripts/stock_only.script")
    write(inventory, "stock scripts/case_only.script")
    write(inventory, "engine/gamedata/scripts/fork_mod.script")
    write(inventory, "gamedata/scripts/coop_fixture.script")
    write(inventory, "gamedata_gamma/scripts/gamma_patch.script")
    for stem in ("stock_only", "Case_Only", "fork_mod", "coop_fixture", "gamma_patch", "engine_word",
                 "new_mod", "beta_mod", "hyphen-mod", "3starts_with_digit"):
        write(inventory, f"stand scripts/{stem}.script")
    write(inventory, "import.txt", b"engine_word\n")
    write(inventory, "engine/src/coop.cpp", b"beta_mod();\n// new_mod\n")
    write(inventory, "engine/src/stock.cpp", b"new_mod();\n")
    result = generate(inventory)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "engine_word" in result.stdout and "earlier_mod" in result.stdout
    path = inventory / "tools/mod_names.txt"
    first = path.read_bytes()
    assert hand in first
    assert b"build fixture-b1 2026-11-25 old stand 10 1\n" in first
    assert b"build fixture-b2 " in first
    assert [line for line in first.splitlines() if line.startswith(b"script ")] == [
        b"script beta_mod fixture-b2", b"script earlier_mod fixture-b1", b"script new_mod fixture-b2",
    ]
    result = generate(inventory)
    assert result.returncode == 0 and path.read_bytes() == first, result.stdout + result.stderr


@pytest.mark.parametrize("source", [b"clash_mod();\n", b'auto name = "clash_" "mod";\n'])
def test_generator_refuses_new_nonstock_collision(inventory: Path, source: bytes):
    write(inventory, "stand scripts/clash_mod.script")
    write(inventory, "engine/src/coop.cpp", source)
    result = generate(inventory)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "clash_mod" in result.stdout and "engine/src/coop.cpp:1" in result.stdout
    assert not (inventory / "tools/mod_names.txt").exists()


@pytest.mark.parametrize("row", ["name engine_word", "debt R1 engine_word"])
def test_generator_refuses_unscoped_hand_row_in_import(inventory: Path, row: str):
    write(inventory, "import.txt", b"engine_word\n")
    before = (row + "\n").encode()
    write(inventory, "tools/mod_names.txt", before)
    result = generate(inventory)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "engine_word" in result.stdout and "import" in result.stdout
    assert (inventory / "tools/mod_names.txt").read_bytes() == before


def test_generator_accepts_scoped_debt_for_an_import_word(inventory: Path):
    write(inventory, "import.txt", b"script_zone\n")
    write(inventory, "tools/mod_names.txt", b"debt R4 script_zone engine/src/coop.h\n")
    result = generate(inventory)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.skipif(not shutil.which("git") or not (ROOT / "engine/.git").exists(),
                    reason="the engine Git checkout is unavailable")
def test_generator_queries_real_gsc_import():
    from gen_mod_names import read_import_code_words, read_import_words

    engine = ROOT / "engine"
    commit = "ad9d8416"
    if subprocess.run(["git", "-C", str(engine), "cat-file", "-e", f"{commit}^{{commit}}"],
                      capture_output=True).returncode:
        pytest.skip("the GSC import is unavailable")
    names = {"3DSS", "script_zone", "drx_da_main"}
    assert read_import_words(engine, commit, names) == {"3DSS", "script_zone"}
    assert read_import_code_words(engine, commit, {"3DSS", "script_zone"}) == {"script_zone"}
