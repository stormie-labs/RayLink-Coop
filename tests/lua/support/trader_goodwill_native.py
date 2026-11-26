"""Execute the production relation transfer and readpoint in isolated native worlds."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tests" / "tools"))
from native_slice import build, definition, scratch  # noqa: E402

game = ROOT / "engine/src/xrGame"
story = (game / "coop/coop_story.cpp").read_text(encoding="utf-8-sig")
relations = (game / "coop/coop_story_relations.cpp").read_text(encoding="utf-8-sig")
impl = (game / "coop/coop_story_impl.h").read_text(encoding="utf-8-sig")
registry = (game / "relation_registry.cpp").read_text(encoding="utf-8-sig")
binding = (game / "level_script.cpp").read_text(encoding="utf-8-sig")
join = (game / "coop/coop_join.h").read_text(encoding="utf-8-sig")
header = (game / "coop/coop_story.h").read_text(encoding="utf-8-sig")
source = Path(__file__).with_name("trader_goodwill_native.cpp").read_text(encoding="utf-8")
source = source.replace("// GOODWILL_ENUM", definition(header, "enum class GoodwillOp") + ";")
source = source.replace("// RELATION_CODES", definition(impl[impl.index("// First byte"):], "enum : u8") + ";")
source = source.replace("// RELATION_KEY", definition(impl, "struct RelKey") + ";")
source = source.replace("// JOIN_MAPPING", "\n".join(definition(join, name) for name in (
    "inline u16 to_local(", "inline u16 to_host(")))
source = source.replace("// STORY_FUNCTIONS", "\n".join(
    [definition(story, name) for name in ("u16 host_id_of(", "u16 local_id_of(")]
    + [definition(relations, name) for name in (
        "bool community_ok(", "RELATION_DATA& rel_data(", "int rel_value(", "void client_swap_relations(",
        "bool client_relation_request(", "void host_on_relation_request(", "bool on_community_goodwill(",
        "void host_flush_relations(", "void client_set_community(")]))
source = source.replace("// REGISTRY_FUNCTIONS", "\n".join(definition(registry, name) for name in (
    "CHARACTER_GOODWILL RELATION_REGISTRY::GetCommunityGoodwill(",
    "void RELATION_REGISTRY::SetCommunityGoodwill(", "void RELATION_REGISTRY::ChangeCommunityGoodwill(")))
bindings = definition(binding, "int g_community_goodwill(")
if "--host-id-only" in sys.argv:
    bindings = bindings.replace("u16(_entity_id)", "u16(current->host ? 0 : _entity_id)")
bindings += "\n" + "\n".join(definition(binding, name) for name in (
    "void g_set_community_goodwill(", "void g_change_community_goodwill("))
source = source.replace("// LUA_BINDINGS", bindings)
include = ROOT / "engine/src/xrCoop"
with scratch("trader_goodwill") as work:
    fixture = work / "readpoint.cpp"
    fixture.write_text(source, encoding="utf-8")
    runner = build(work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture, include / "coop_wire.cpp"],
                   work / "readpoint.exe", includes=[include])
    code = subprocess.run([str(runner), str(Path(sys.argv[1]).resolve())], cwd=ROOT, timeout=30).returncode
sys.exit(code)