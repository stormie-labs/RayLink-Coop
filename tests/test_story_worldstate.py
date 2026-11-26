"""Run the production story group's clock and sky receivers without xrGame.

Run with python -I tests/test_story_worldstate.py. Pass --source to test a
separate copy of coop_worldstate.cpp, for example a regression probe.
"""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "tools"))
from native_slice import block, build, scratch  # noqa: E402
COOP = ROOT / "engine/src/xrCoop"
SOURCE = ROOT / "engine/src/xrGame/coop/coop_worldstate.cpp"
FIXTURE = Path(__file__).with_name("test_story_worldstate.inc")


def build_runner(work, source):
    # these top-level definitions start and end at column one; a struct's block ends with its ';'
    types = (block(source, "struct " + name) for name in ("TimeState", "EnvRef", "WeatherState", "State"))
    handlers = (block(source, "void " + name + "(") for name in (
        "client_on_time_sync", "client_on_weather_sync", "client_on_thunderbolt"))
    cpp = work / "story_worldstate.cpp"
    cpp.write_text(FIXTURE.read_text(encoding="utf-8")
                   .replace("// WORLDSTATE_TYPES", "\n\n".join(types))
                   .replace("// WORLDSTATE_HANDLERS", "\n\n".join(handlers)), encoding="utf-8")
    return build(work, "cl /nologo /std:c++17 /EHsc /utf-8 /W4", [cpp, COOP / "coop_wire.cpp"],
                 work / "story_worldstate.exe", includes=[ROOT / "tests", COOP])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    args = parser.parse_args()
    with scratch("story_worldstate") as work:
        runner = build_runner(work, args.source.read_text(encoding="utf-8-sig"))
        return subprocess.run([str(runner)], cwd=work, timeout=30).returncode


if __name__ == "__main__":
    raise SystemExit(main())
