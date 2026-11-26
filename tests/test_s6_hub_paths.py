"""Compile the hub's production functions against native per-process fixtures."""

import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "tools"))
from native_slice import block, build, scratch  # noqa: E402
ENGINE = ROOT / "engine"
SOURCE = ENGINE / "src/xrGame/coop"
COOP = ENGINE / "src/xrCoop"
FIXTURE = Path(__file__).with_suffix(".inc")


def definitions(source, *heads, optional=()):
    """The blocks of `heads`, in order; a head in `optional` that the source lacks is left out."""
    present = [h for h in heads if h not in optional or re.search("^" + re.escape(h), source, re.M)]
    return "\n\n".join(block(source, head) for head in present)


def fixture(read, head):
    syncapi = read("coop_sync_api.cpp")
    script = read("coop_script.cpp")
    parts = {
        "NET": definitions(
            (SOURCE / "coop_net.cpp").read_text(encoding="utf-8-sig"),
            "bool live()", "bool host()", "bool client()",
        ),
        "SYNC": definitions(read("coop_sync.cpp"), "bool alife_frozen("),
        "SYNCAPI_TYPES": definitions(syncapi, "struct Out\n", "struct Stats\n"),
        "SYNCAPI": definitions(
            syncapi, "bool decides_sync_store(", "bool client(", "bool in_world(",
            "void push_out(", "void out_to(", "void cast_to(", "void level_flush(", "void host_flush(",
            optional=("bool decides_sync_store(",),
        ),
        "SCRIPT_TYPES": definitions(script, "struct Outgoing\n", "struct Incoming\n", "struct Stats\n"),
        "SCRIPT": definitions(
            script, "bool valid_name(", "bool decides_world()", "bool lua_ready()",
            "void write_event(", "void deliver_later(", "void host_relay(", "bool read_event(",
            "void server_on_script_event(", "void client_on_script_event(", "void flush_outbox(",
            "bool host_seat_plays(", "PeerInfo self_row(", "int fail2(lua_State* L, const char* why)\n",
            "int l_operator_command(", "int send_fail(", "int l_send_event(",
            optional=("bool decides_world()",),
        ),
    }
    code = FIXTURE.read_text(encoding="utf-8")
    for name, body in parts.items():
        marker = "// PRODUCTION_" + name + "\n"
        assert code.count(marker) == 1, marker
        code = code.replace(marker, body + "\n")
    return ("#define COOP_HUB_BASELINE\n" if head else "") + code


def build_runner(work, code):
    cpp = work / "hub_paths.cpp"
    cpp.write_text(code, encoding="utf-8")
    return build(work, "cl /nologo /std:c++17 /EHsc /utf-8 /W4", [cpp, COOP / "coop_wire.cpp"], work / "hub_paths.exe",
                 includes=[ROOT / "tests", COOP])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", action="store_true", help="run behavioral tests on engine HEAD")
    args = parser.parse_args()

    def read(name):
        if args.head:
            path = f"src/xrGame/coop/{name}"
            data = subprocess.check_output(["git", "-C", str(ENGINE), "show", f"HEAD:{path}"])
            return data.decode("utf-8-sig").replace("\r\n", "\n")
        return (SOURCE / name).read_text(encoding="utf-8-sig")

    code = fixture(read, args.head)
    with scratch("hub_paths") as work:
        runner = build_runner(work, code)
        return subprocess.run([str(runner)], cwd=work, timeout=30).returncode


if __name__ == "__main__":
    raise SystemExit(main())
