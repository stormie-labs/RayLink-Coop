"""Exercise the production teardown poll and slot restore with a live clone in the rucksack."""
from pathlib import Path
import subprocess

from native_slice import ROOT, build, definition


def test_clone_teardown_precedes_slot_restore(work):
    coop = ROOT / "engine/src/xrGame/coop"
    methods = definition(coop / "coop_requests_clone.cpp", "void clone_slots_frame(")
    poll = definition(coop / "coop_requests_leases.cpp", "for (auto it = g_give_back_wait.begin();")
    methods += "\nvoid poll_removals(u64 now) {\n" + poll + "\n}\n"
    fixture = Path(__file__).parent / "fixtures/clone_placement_hooks.cpp"
    source = fixture.read_text(encoding="utf-8").replace("// SLOT_METHODS", methods)
    (work / "clone_placement_hooks.cpp").write_text(source, encoding="utf-8")
    runner = build(work, "cl /nologo /EHsc /std:c++17 /W4 /Od /utf-8", [work / "clone_placement_hooks.cpp"],
                   work / "clone_placement_hooks.exe", includes=[ROOT / "engine/src/xrCoop"])
    result = subprocess.run([str(runner)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
