"""Run the engine's local_zone_release (personal map zones of a client) over stubs: report #859.

The function is cut out of engine/src/xrGame/coop/coop_local_zones.cpp; the zone book and the lease pool are the real headers.
A client only: the zones are personal (xrCoop/coop_local_zones.h), in both modes.
"""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition


@pytest.fixture(scope="module")
def zone_runner(module_work):
    requests = ROOT / "engine/src/xrGame/coop/coop_local_zones.cpp"
    (module_work / "local_zone_release.inc").write_text(
        definition(requests, "bool local_zone_release("), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/local_zone_release.cpp"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture],
                 module_work / "local_zone_release.exe", includes=[module_work, ROOT / "engine/src/xrCoop"])


@pytest.mark.parametrize("scenario", [
    "ready-ours", "ready-online", "not-ours", "world-going", "world-going-gone", "world-going-not-ours",
])
def test_personal_zone_release(zone_runner, scenario):
    run = subprocess.run([str(zone_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
