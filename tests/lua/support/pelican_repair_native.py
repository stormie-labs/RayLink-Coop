"""Run the Lua repair outcomes through the production native ItemState methods."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[3]
work = ROOT / "temp/pelican_weapon_jam/native" / uuid.uuid4().hex[:8]
work.mkdir(parents=True)

# Reuse the existing extraction and registry fixture without changing its source.
spec = importlib.util.spec_from_file_location("ammo_extraction", ROOT / "tests/tools/test_client_ammo_reload.py")
extraction = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extraction)
definition = extraction.definition
source = (ROOT / "engine/src/xrGame/coop/coop_items.cpp").read_text(encoding="utf-8-sig")
types = "\n".join(definition(source, name) + ";" for name in (
    "struct ItemData", "struct TakeBase", "struct Owned", "struct Pending"))
methods = "\n".join(definition(source, name) for name in (
    "void put(", "void write_data(", "bool read_data(", "bool same_upgrades(",
    "u32 diverged_tags(", "void capture_object(", "void capture_blob(",
    "void set_current(", "void set_other(", "void apply_object(", "void apply_entity(",
    "void write_state(", "void send_state(", "u32 take_changes(", "u32 push_keeps(",
    "void scan_local(", "bool client_apply(", "void client_on_state(",
    "void process_pending(", "void host_on_state(", "void host_enforce("))
harness = (ROOT / "tests/tools/fixtures/client_ammo_reload.cpp").read_text(encoding="utf-8")
harness = harness[:harness.index("int main(")]
harness = harness.replace("// ITEM_TYPES", types).replace("// ENGINE_METHODS", methods)
harness = harness.replace(
    "struct CEatableItem : CInventoryItem { u8 GetRemainingUses() { return 0; } void SetRemainingUses(u8) {} };",
    "struct CEatableItem : CInventoryItem { u8 uses = 0; "
    "u8 GetRemainingUses() { return uses; } void SetRemainingUses(u8 value) { uses = value; } };")
case_source = Path(__file__).with_name("pelican_repair_native.cpp").read_text(encoding="utf-8")
fixture = work / "repair.cpp"
fixture.write_text(harness + case_source, encoding="utf-8")
runner = work / "repair.exe"
vcvars = Path(r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat")
include = ROOT / "engine/src/xrCoop"
wire = include / "coop_wire.cpp"
command = work / "compile.cmd"
command.write_text(
    f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
    f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{include}" "{fixture}" "{wire}" /Fe"{runner}"\n'
    'exit /b %ERRORLEVEL%\n', encoding="utf-8")
build = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work, capture_output=True, text=True, timeout=120)
if build.returncode:
    print(build.stdout + build.stderr)
    sys.exit(build.returncode)
sys.exit(subprocess.run([str(runner), str(Path(sys.argv[1]).resolve())], cwd=ROOT, timeout=30).returncode)
