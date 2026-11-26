"""Compile the NPC production paths with a local xrGame fixture.

Run with python -I tests/test_s6_npc_paths.py. Use --head to check behavioral
parity against engine HEAD, or --source-dir for a copy with probe edits.
"""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "tools"))
from native_slice import block, build, scratch  # noqa: E402
ENGINE = ROOT / "engine"
SOURCE = ENGINE / "src/xrGame/coop"
COOP = ENGINE / "src/xrCoop"
FIXTURE = Path(__file__).with_suffix(".inc")


def definitions(source, *heads, indent=""):
    return "\n\n".join(block(source, head, indent) for head in heads)


def fixture(source):
    entities = source("coop_entities.cpp")
    events = source("coop_events.cpp")
    level_mode = source("srv/coop_srv_mode.cpp")
    dispatch = definitions(level_mode, "void level_entity_up(", indent="\t")
    xfer = source("srv/coop_levels_xfer.cpp")
    parts = {
        "OBSERVER": definitions(source("coop_alife.cpp"), "float observer_distance("),
        "APPLY": definitions(entities, "bool client_applying(", "ClientApply::ClientApply(", "ClientApply::~ClientApply("),
        "SPAWN": definitions(entities, "bool online_here(", "bool read_packet(", "void read_placement(",
                             "void client_on_spawn("),
        "ENTITY_HOOKS": definitions(entities, "bool host_records(", "void host_on_entity_registered(",
                                    "void host_on_entity_released("),
        "EVENT_RECORDS": definitions(events, "struct ParentChange", "struct Death"),
        "EVENT_HOOKS": definitions(events, "void host_on_parent_changed(", "void host_on_death("),
        "UP_RECORD": definitions(xfer, "struct Up", indent="\t"),
        "UP_HOOKS": definitions(xfer, "void up_spawned(", "void xfer_on_released(", "void up_parent(", "void up_died("),
        "LEVEL_DISPATCH": dispatch,
    }
    cpp = FIXTURE.read_text(encoding="utf-8")
    for name, body in parts.items():
        marker = f"// PRODUCTION_{name}"
        assert cpp.count(marker) == 1, marker
        cpp = cpp.replace(marker, body)
    return cpp


def build_runner(work, code):
    cpp = work / "npc_paths.cpp"
    cpp.write_text(code, encoding="utf-8")
    return build(work, "cl /nologo /std:c++17 /EHsc /utf-8 /W4", [cpp, COOP / "coop_wire.cpp"], work / "npc_paths.exe",
                 includes=[ROOT / "tests", COOP])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--head", action="store_true")
    sources.add_argument("--source-dir", type=Path, default=SOURCE)
    args = parser.parse_args()

    def source(name):
        if args.head:
            path = f"src/xrGame/coop/{name}"
            data = subprocess.check_output(["git", "-C", str(ENGINE), "show", f"HEAD:{path}"])
            return data.decode("utf-8-sig").replace("\r\n", "\n")
        return (args.source_dir / name).read_text(encoding="utf-8-sig")

    code = fixture(source)
    with scratch("npc_paths") as work:
        runner = build_runner(work, code)
        return subprocess.run([str(runner)], cwd=work, timeout=30).returncode


if __name__ == "__main__":
    raise SystemExit(main())
