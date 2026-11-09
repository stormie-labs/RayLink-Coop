"""Execute the production relation transfer and readpoint in isolated native worlds."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("trader_native_extract", ROOT / "tests/tools/test_client_ammo_reload.py")
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
definition = extract.definition
game = ROOT / "engine/src/xrGame"
story = (game / "coop/coop_story.cpp").read_text(encoding="utf-8-sig")
registry = (game / "relation_registry.cpp").read_text(encoding="utf-8-sig")
binding = (game / "level_script.cpp").read_text(encoding="utf-8-sig")
join = (game / "coop/coop_join.h").read_text(encoding="utf-8-sig")
header = (game / "coop/coop_story.h").read_text(encoding="utf-8-sig")
source = Path(__file__).with_name("trader_goodwill_native.cpp").read_text(encoding="utf-8")
source = source.replace("// GOODWILL_ENUM", definition(header, "enum class GoodwillOp") + ";")
source = source.replace("// RELATION_CODES", definition(story[story.index("// First byte"):], "enum : u8") + ";")
source = source.replace("// RELATION_KEY", definition(story, "struct RelKey") + ";")
source = source.replace("// JOIN_MAPPING", "\n".join(definition(join, name) for name in (
    "inline u16 to_local(", "inline u16 to_host(")))
source = source.replace("// STORY_FUNCTIONS", "\n".join(definition(story, name) for name in (
    "u16 host_id_of(", "u16 local_id_of(", "bool community_ok(", "RELATION_DATA& rel_data(",
    "int rel_value(", "void client_swap_relations(", "bool client_relation_request(",
    "void host_on_relation_request(", "bool on_community_goodwill(", "void host_flush_relations(",
    "void client_set_community(")))
source = source.replace("// REGISTRY_FUNCTIONS", "\n".join(definition(registry, name) for name in (
    "CHARACTER_GOODWILL RELATION_REGISTRY::GetCommunityGoodwill(",
    "void RELATION_REGISTRY::SetCommunityGoodwill(", "void RELATION_REGISTRY::ChangeCommunityGoodwill(")))
bindings = definition(binding, "int g_community_goodwill(")
if "--host-id-only" in sys.argv:
    bindings = bindings.replace("u16(_entity_id)", "u16(current->host ? 0 : _entity_id)")
bindings += "\n" + "\n".join(definition(binding, name) for name in (
    "void g_set_community_goodwill(", "void g_change_community_goodwill("))
source = source.replace("// LUA_BINDINGS", bindings)
work = ROOT / "temp/trader_reputation/native" / uuid.uuid4().hex[:8]
work.mkdir(parents=True)
fixture, runner = work / "readpoint.cpp", work / "readpoint.exe"
fixture.write_text(source, encoding="utf-8")
include = ROOT / "engine/src/xrCoop"
vcvars = Path(r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat")
command = work / "compile.cmd"
command.write_text(
    f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
    f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{include}" "{fixture}" "{include / "coop_wire.cpp"}" /Fe"{runner}"\n'
    'exit /b %ERRORLEVEL%\n', encoding="utf-8")
build = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work, capture_output=True, text=True, timeout=120)
if build.returncode:
    print(build.stdout + build.stderr)
    sys.exit(build.returncode)
sys.exit(subprocess.run([str(runner), str(Path(sys.argv[1]).resolve())], cwd=ROOT, timeout=30).returncode)
