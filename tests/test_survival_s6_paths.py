"""Compile the survival paths that depend on xrGame against a small test harness.

Run with python -I tests/test_survival_s6_paths.py [--head]. The latter reads
the original engine sources from HEAD without changing the working tree.
"""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "tools"))
from native_slice import block, build, scratch  # noqa: E402
ENGINE = ROOT / "engine"


def source(name, head):
    relative = f"src/xrGame/coop/{name}.cpp"
    if head:
        data = subprocess.check_output(["git", "-C", str(ENGINE), "show", f"HEAD:{relative}"])
        return data.decode("utf-8").replace("\r\n", "\n")
    return (ENGINE / relative).read_text(encoding="utf-8")


def function(code, signature):
    return block(code, signature)


HARNESS = r'''
#include "coop_checkpoint_base_rules.h"
#include "coop_lua_errors.h"
#include "coop_revive_hold.h"
#include "support/fake_mode.h"

#include <algorithm>
#include <cstdio>
#include <limits>

using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using xr_string = std::string;
template<class T> using xr_vector = std::vector<T>;

void Msg(const char*, ...) {}

namespace coop {
t::FakeMode* current_mode;
Mode& mode() { return *current_mode; }
bool is_map_server() { return mode().level() != nullptr; }
bool is_map_authority() { return mode().decides_world() || is_map_server(); }
bool legacy_elsewhere;
bool legacy_on_level;
unsigned legacy_story_queries;
unsigned character_lookups;
bool local_link;

namespace levels {
bool host_character_elsewhere(u16)
{
    ++legacy_story_queries;
    return legacy_elsewhere;
}
bool on_host_level(PeerId) { return legacy_on_level; }
}

namespace mapserver {
struct TrunkPeers {
    struct Body { u16 proxy; };
    std::map<PeerId, Body> peers;
    const auto& on() const { return peers; }
};
TrunkPeers& trunk_peers()
{
    static TrunkPeers trunk;
    return trunk;
}
}

struct PeerInfo { std::string nick; };
struct Session {
    const PeerInfo* peer(PeerId from) const
    {
        static const PeerInfo admitted{"Canonical"};
        return from == 17 ? &admitted : nullptr;
    }
};
struct Manager {
    bool is_host() const { return mode().decides_world(); }
    const Session& session() const
    {
        static const Session s;
        return s;
    }
};
Manager mgr() { return {}; }

u16 character_of_peer(PeerId from)
{
    ++character_lookups;
    if (LevelSide* level = mode().level())
        return level->level_character_of(from);
    if (from == kHostPeer && local_link)
        return 0;
    return from == 17 ? 42 : u16(0xffff);
}

struct CGameObject {};
CGameObject local;
bool object_present, living, parked, on_friendly_base;
namespace world {
CGameObject* object_here(u16 id) { return id == 42 && object_present ? &local : nullptr; }
bool is_parked(u16) { return parked; }
}
namespace net { void host_broadcast(Msg, Writer&, Lane, PeerId) {} }
namespace survival {
enum class Life : u8 { Alive, Wounded, Dead, Spectating, Respawning };
Life life_of(u16 id) { return living && id == 42 ? Life::Alive : Life::Dead; }
using revive::OpRequest;
using revive::OpBegin;
using revive::OpCancel;
unsigned revive_requests, worn_reports, remote_reports;
u16 seen_id, seen_seq;
u32 seen_left;
std::string seen_nick;
void host_on_revive_request(u16, PeerId, u16, u16, u16) { ++revive_requests; }
void host_on_revive_begin(u16, PeerId, const revive::BeginMsg&) {}
void host_on_revive_cancel(u16, u16, u16) {}
void host_read_worn(u16, u16, Reader& r)
{
    if (r.u8() == 0xA5 && r.ok())
        ++worn_reports;
}
void apply_remote_state(u16 id, Life, u16 seq, u32 left, const char* nick)
{
    ++remote_reports;
    seen_id = id;
    seen_seq = seq;
    seen_left = left;
    seen_nick = nick;
}
void host_on_state(u16, Life, u16) {}
void write_state(Writer&, u16, Life, u16, u32, const char*) {}

@SURVIVAL@
}

namespace checkpoints {
using checkpoint::Kind;
using checkpoint::StoryFrom;
using checkpoint::kNoSource;
struct { std::vector<u16> in_world{42}; } g_host;
struct { unsigned stories = 0; } g_stat;
constexpr u64 kLogBurst = 10;
StoryFrom written;
bool far_write;
Kind written_kind;
unsigned writes;
bool ensure_loaded() { return mode().decides_world(); }
checkpoint::Record record_here(const CGameObject*, Kind kind, u16)
{
    checkpoint::Record result;
    result.kind = kind;
    result.pos[0] = 1;
    return result;
}
checkpoint::Record record_far(u16, Kind kind, u16)
{
    auto result = record_here(nullptr, kind, 0);
    result.pos[0] = 2;
    return result;
}
namespace sources {
struct {
    std::map<u16, checkpoint::base::Key> foot_current;
    u64 next_scan_ms;
} g;
constexpr u64 kScanMs = 1000;
unsigned scans;
bool world_ready;
bool ensure_world() { return world_ready; }
void scan_level(u64) { ++scans; }

@SCAN@

bool base_bed_record(u16, checkpoint::Record& out)
{
    out.kind = Kind::Rest;
    return on_friendly_base;
}
}
bool host_set(u16, const checkpoint::Record& record, bool elsewhere = false)
{
    written = record.pos[0] == 2 ? StoryFrom::Body : StoryFrom::Object;
    written_kind = record.kind;
    far_write = elsewhere;
    ++writes;
    return true;
}

@STORY@
}
}

using namespace coop;
using checkpoint::Kind;
using checkpoint::StoryFrom;
using t::FakeMode;
using t::Spot;
unsigned passed, failed;

void expect(const char* test, bool result)
{
    std::printf("%s %s\n", result ? "PASS" : "FAIL", test);
    result ? ++passed : ++failed;
}

bool story_row(const t::ModeCase& row)
{
    using namespace checkpoints;
    FakeMode m(row);
    current_mode = &m;
    m.character(42, 17);
    m.place(17, Spot::Here);
    // Deliberately disagree with the facade, even with a stale local object.
    legacy_elsewhere = m.decider_of(42) != Decider::Other;
    legacy_story_queries = 0;
    bool ok = true;
    for (unsigned inputs = 0; inputs < 8; ++inputs)
    {
        living = (inputs & 1) != 0;
        object_present = (inputs & 2) != 0;
        parked = (inputs & 4) != 0;
        on_friendly_base = false;
        writes = 0;
        written = StoryFrom::Nothing;
        const bool result = checkpoints::host_story("test");
        const StoryFrom expected = !m.decides_world() || !living || parked ? StoryFrom::Nothing :
            std::string(row.name) == "world_server" ? StoryFrom::Body :
            object_present ? StoryFrom::Object : StoryFrom::Nothing;
        ok = ok && written == expected && result == (expected != StoryFrom::Nothing)
            && writes == unsigned(result) && (!result || far_write == (expected == StoryFrom::Body));
    }
    living = object_present = on_friendly_base = true;
    parked = false;
    writes = 0;
    const bool bed = checkpoints::host_story("test");
    ok = ok && bed == m.decides_world() && (!bed || (writes == 1 && written_kind == Kind::Rest &&
        far_write == (std::string(row.name) == "world_server")));
    m.place(17, Spot::Joining);
    object_present = on_friendly_base = false;
    writes = 0;
    const bool unplaced = checkpoints::host_story("test");
    return ok && !unplaced && writes == 0 && legacy_story_queries == 0;
}

bool revive_row(const t::ModeCase& row)
{
    using namespace survival;
    FakeMode m(row);
    current_mode = &m;
    local_link = std::string(row.name) == "coop_host";
    m.side().trunk[17] = 42;
    bool ok = true;
    for (const Spot spot : {Spot::Self, Spot::Here, Spot::Elsewhere, Spot::Joining, Spot::Stranger})
    {
        const PeerId from = spot == Spot::Self ? kHostPeer : 17;
        m.place(from, spot);
        legacy_on_level = !m.decides_world() || m.where(from) != Where::Away || from == kHostPeer;
        character_lookups = revive_requests = 0;
        Writer packet;
        packet.u8(OpRequest);
        packet.u16(43);
        packet.u16(9);
        packet.u16(66);
        Reader reader(packet.ptr(), packet.size());
        server_on_revive(from, reader);
        const bool lookup = (m.decides_world() && legacy_on_level) || m.level() != nullptr;
        const bool request = lookup && (from != kHostPeer || local_link);
        ok = ok && character_lookups == unsigned(lookup) && revive_requests == unsigned(request);
    }
    return ok;
}

void wounded_packet()
{
    using namespace survival;
    FakeMode m(t::mode_case("map_server"));
    current_mode = &m;
    m.side().trunk[17] = 42;
    m.side().trunk[18] = 43;
    const auto report = [](PeerId from, u8 life, u32 ms, const std::string& nick, bool truncate) {
        Writer packet;
        packet.u16(888); // Packet's claimed id must never identify the player.
        packet.u8(life);
        packet.u16(65535); // Sequence numbers use the whole wire range.
        packet.u32(ms);
        packet.str(nick);
        if (life == u8(Life::Dead))
            packet.u8(0xA5);
        Reader reader(packet.ptr(), packet.size() - size_t(truncate));
        @MAP_STATE@(from, reader);
    };
    const auto wounded = u8(Life::Wounded);
    remote_reports = worn_reports = 0;
    report(17, wounded, std::numeric_limits<u32>::max(), std::string(5000, 'x'), false);
    expect("map Wounded clamps wire countdown", seen_left == 600000);
    expect("map Wounded uses canonical sender name", seen_nick == "Canonical");
    expect("map Wounded uses sender character and keeps sequence", remote_reports == 1 && seen_id == 42 && seen_seq == 65535);
    report(17, wounded, 9876, "fake", false);
    expect("map Wounded keeps an in-range countdown", remote_reports == 2 && seen_left == 9876);
    report(17, u8(Life::Dead), 0, "fake", false);
    expect("map Dead reads the worn tail after the nickname", remote_reports == 3 && worn_reports == 1);
    report(17, wounded, 0, "short", true);
    report(17, 255, 0, "", false);
    report(99, wounded, 0, "", false);
    expect("map Wounded refuses short, invalid life, and unknown sender", remote_reports == 3);
    report(18, wounded, 0, "forged", false);
    expect("map Wounded missing roster name cannot trust packet", remote_reports == 4 && seen_nick == "?");
}

void checkpoint_scan()
{
    using namespace checkpoints::sources;
    FakeMode m(t::mode_case("map_server"));
    current_mode = &m;
    m.side().trunk[17] = 42;
    mapserver::trunk_peers().peers[18] = {43};
    g.foot_current = {{42, checkpoint::base::kNoBase}, {43, checkpoint::base::kNoBase}};
    g.next_scan_ms = 20;
    world_ready = true;
    scans = 0;
    map_server_scan(19);
    expect("map scan drops migrated footing before its next geometry scan",
        g.foot_current.count(42) == 1 && g.foot_current.count(43) == 0 && scans == 0);
    map_server_scan(20);
    map_server_scan(21);
    expect("map scan keeps the existing geometry cadence", scans == 1 && g.next_scan_ms == 20 + kScanMs);
}

int main()
{
#define CHECK_ROLE(role) \
    expect("story production " #role, story_row(t::mode_case(#role))); \
    expect("revive five sender states " #role, revive_row(t::mode_case(#role)));
    MODE_CASES(CHECK_ROLE)
#undef CHECK_ROLE
    wounded_packet();
    checkpoint_scan();
    std::printf("%u passed, %u failed\n", passed, failed);
    return failed ? 1 : 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", action="store_true")
    args = parser.parse_args()

    survival = source("coop_survival", args.head)
    checkpoints = source("coop_checkpoints", args.head)
    sources = source("coop_checkpoint_sources", args.head)
    state = "map_on_state" if "\nvoid map_on_state(" in survival else "server_on_state"
    functions = [
        function(survival, f"void {state}(PeerId from, Reader& r)"),
        function(survival, "void server_on_revive(PeerId from, Reader& r)"),
    ]
    cpp = (HARNESS.replace("@SURVIVAL@", "\n\n".join(functions))
           .replace("@MAP_STATE@", state)
           .replace("@SCAN@", function(sources, "void map_server_scan(u64 now_ms)"))
           .replace("@STORY@", function(checkpoints, "bool host_story(const char* reason)")))
    coop = ENGINE / "src/xrCoop"
    with scratch("survival_paths") as work:
        (work / "paths.cpp").write_text(cpp, encoding="utf-8")
        runner = build(work, "cl /nologo /std:c++17 /EHsc /utf-8", [work / "paths.cpp", coop / "coop_wire.cpp"],
                       work / "paths.exe", includes=[ROOT / "tests", coop])
        return subprocess.run([str(runner)], cwd=work, timeout=30).returncode


if __name__ == "__main__":
    raise SystemExit(main())
