"""Run the engine's host_track_proxies, host_push and late_report_of_gift (coop_items.cpp) over stubs: the giver's late report.

A player gives an item to another player; his last ItemState of it arrives after the gift and was refused as "not owner" with
a red line (an automatic error report) in builds 55-58. Within kGraceMs of the item leaving his character (g_left), or in the
very frame of the gift, it is dropped silently and counted. The deciding process is the co-op host or the map server of the
level (both receive ItemState); the rule has no mode check.
"""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition


@pytest.fixture(scope="module")
def gift_runner(module_work):
    items = ROOT / "engine/src/xrGame/coop/coop_items.cpp"
    parts = [definition(items, signature) for signature in
             ("bool late_report_of_gift(", "void host_push(", "void host_track_proxies(")]
    (module_work / "items_gift_late.inc").write_text("\n".join(parts), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/items_gift_late.cpp"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture], module_work / "items_gift_late.exe",
                 includes=[module_work])


@pytest.mark.parametrize("scenario", [
    "giver-first", "recipient-first", "same-frame", "expired", "expired-recipient-first", "given-back",
])
def test_giver_report_after_a_gift(gift_runner, scenario):
    run = subprocess.run([str(gift_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
