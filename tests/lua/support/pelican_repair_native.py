"""Run the Lua repair outcomes through the production native ItemState methods.

python -B tests/lua/support/pelican_repair_native.py <outcomes file>   (tests/lua/support/pelican_repair_actions.lua)"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tests" / "tools"))
from native_slice import build, scratch  # noqa: E402
# the ammo slice's production state, types and methods: one list there, kept in step with coop_items.cpp
import test_client_ammo_reload as extraction  # noqa: E402

source = (ROOT / "engine/src/xrGame/coop/coop_items.cpp").read_text(encoding="utf-8-sig")
# Its CEatableItem keeps the engine's portions and their bound (eatable_item.h).
types = extraction.item_types(source)
methods = extraction.item_methods(source)
harness = (ROOT / "tests/tools/fixtures/client_ammo_reload.cpp").read_text(encoding="utf-8")
harness = harness[:harness.index("int main(")]
harness = harness.replace("// ITEM_TYPES", types).replace("// ENGINE_METHODS", methods)
case_source = Path(__file__).with_name("pelican_repair_native.cpp").read_text(encoding="utf-8")
include = ROOT / "engine/src/xrCoop"
with scratch("pelican_repair") as work:
    fixture = work / "repair.cpp"
    fixture.write_text(harness + case_source, encoding="utf-8")
    runner = build(work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture, include / "coop_wire.cpp"],
                   work / "repair.exe", includes=[include])
    code = subprocess.run([str(runner), str(Path(sys.argv[1]).resolve())], cwd=ROOT, timeout=30).returncode
sys.exit(code)
