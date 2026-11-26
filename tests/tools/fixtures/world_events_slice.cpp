// Run the production script event handler with in-process Lua and transport stubs.
#include "xrCoop/coop_lua_errors.h"
#include "xrCoop/coop_protocol.h"
#include "xrCoop/coop_wire.h"

#include <atomic>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <optional>
#include <utility>
#include <vector>

// X-Ray's PCH provides these types when the engine includes coop_script.h.
using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using s32 = int32_t;
using s64 = int64_t;
using LPCSTR = const char*;
using xr_string = std::string;
#include "xrGame/coop/coop_script.h"

#define CHECK(condition) do { if (!(condition)) { std::cerr << #condition << '\n'; std::exit(1); } } while (0)

void Msg(const char*, ...) {}

constexpr int LUA_TNUMBER = 3;
constexpr int LUA_TSTRING = 4;
struct lua_State
{
    int type;
    std::string value;
    std::optional<bool> result;
};

int lua_type(lua_State* state, int) { return state->type; }
const char* lua_tolstring(lua_State* state, int, size_t* size)
{
    // Lua also converts a number to a string here. The production binding must reject it first.
    *size = state->value.size();
    return state->value.data();
}
void lua_pushboolean(lua_State* state, int value) { state->result = value != 0; }

namespace coop
{
constexpr PeerId kGuest = 1;
constexpr PeerId kListener = 2;
constexpr PeerId kBridge = 0x101;
struct PeerInfo { PeerId id = kInvalidPeer; };

class Session
{
public:
    bool host_plays = false;
    bool bridge_joined = false;

    const PeerId* peer(PeerId from) const
    {
        if (from == kGuest) return &kGuest;
        if (from == kListener) return &kListener;
        return nullptr;
    }
    const PeerId* local() const { return host_plays ? &kHostPeer : nullptr; }
    std::vector<PeerInfo> peers() const { return {PeerInfo{kGuest}, PeerInfo{kListener}}; }
    bool joined(PeerId from) const { return peer(from) || (from == kBridge && bridge_joined); }
};

struct Manager
{
    Session session_data;
    const Session& session() const { return session_data; }
    bool is_host() const { return true; }
    bool is_client() const { return false; }
    u64 now_ms() const { return 1000; }
};
Manager& mgr()
{
    static Manager manager;
    return manager;
}

namespace sync
{
bool host_peer_joining(PeerId) { return false; }
}

// coop_script.cpp's own helper (A-S6-E-hub): the process that decides the world takes events from the session
bool decides_world() { return mgr().is_host(); }

namespace net
{
bool client() { return mgr().is_client(); }
struct Delivery
{
    std::vector<uint8_t> bytes;
    std::optional<PeerId> to;
    std::optional<PeerId> except;
};
std::vector<Delivery> deliveries;

void host_broadcast(Msg kind, const Writer& wire, Lane lane, PeerId except)
{
    CHECK(kind == Msg::ScriptEvent && lane == Lane::Reliable);
    deliveries.push_back({wire.data(), std::nullopt, except});
}
void host_send(PeerId to, Msg kind, const Writer& wire)
{
    CHECK(kind == Msg::ScriptEvent);
    deliveries.push_back({wire.data(), to, std::nullopt});
}
}

namespace script
{
namespace
{
constexpr size_t kMaxPayload = 16 * 1024;
constexpr size_t kMaxInbox = 4096;
constexpr size_t kMaxInboxBytes = 4 * 1024 * 1024;
constexpr u64 kRejectShadowMs = 3000;
constexpr s32 kTargetAll = -1;

#include "world_events_types.inc"

Stats g_stats;
WorldEventReservations g_world_events;
std::deque<Incoming> g_inbox;
size_t g_inbox_bytes = 0;
u32 g_lost_events = 0;
std::atomic<u64> g_tick{0};

struct
{
    bool user_stop = false;
    int port = 0;
    u64 rejected_ms = 0;
    std::string address, last_code, last_error;
} g_menu;
struct
{
    bool pending = false;
    std::string code, text;
} g_end;
bool g_pGameLevel = false;
bool g_menu_notified = false;
void menu_error(const char*, const char*, bool) { g_menu_notified = true; }
void pump_sync() {}
}

#include "world_events_methods.inc"

namespace
{
constexpr char kReserved[] = "coop_set";
constexpr char kOrdinary[] = "test.world_events.ordinary";
const std::string kPayload("a\0b", 3);

bool reserve(std::string name, int type = LUA_TSTRING)
{
    lua_State state{type, std::move(name), std::nullopt};
    CHECK(l_reserve_world_event(&state) == 1);
    CHECK(state.result.has_value());
    return *state.result;
}

void ingress(PeerId sender, s32 target, const std::string& name, PeerId claimed_origin = kHostPeer)
{
    Writer wire;
    wire.u32(claimed_origin);
    wire.i32(target);
    wire.str(name);
    wire.str(kPayload);
    Reader reader(wire.ptr(), wire.size());
    server_on_script_event(sender, reader);
}

void check_delivery(PeerId origin, s32 target, const std::string& name, PeerId sender)
{
    CHECK(net::deliveries.size() == 1);
    const auto& sent = net::deliveries.front();
    if (target == -1)
    {
        CHECK(!sent.to && sent.except == sender);
    }
    else
    {
        CHECK(sent.to == PeerId(target) && !sent.except);
    }
    Reader reader(sent.bytes.data(), sent.bytes.size());
    CHECK(reader.u32() == origin);
    CHECK(reader.i32() == target);
    CHECK(reader.str() == name);
    CHECK(reader.str() == kPayload);
    CHECK(reader.ok() && reader.remaining() == 0);
}

void check_reserved_bridge_drop(s32 target)
{
    ingress(kBridge, target, kReserved);
    CHECK(net::deliveries.empty());
    CHECK(g_inbox.empty());
    CHECK(g_stats.received == 0 && g_stats.drop_world_only == 1);
}

void check_coop_event(PeerId sender)
{
    mgr().session_data.host_plays = true;
    ingress(sender, -1, kReserved, sender == kHostPeer ? kGuest : kHostPeer);
    check_delivery(sender, -1, kReserved, sender);
    CHECK(g_stats.drop_world_only == 0);
    if (sender == kHostPeer)
    {
        CHECK(g_inbox.empty());
    }
    else
    {
        CHECK(g_inbox.size() == 1);
        CHECK(g_inbox.front().from == sender && g_inbox.front().name == kReserved);
    }
}

void check_cleanup(bool after_refusal)
{
    check_reserved_bridge_drop(kListener);
    if (after_refusal)
        g_menu.rejected_ms = mgr().now_ms() - 1;
    on_session_end("test session ended", nullptr);
    CHECK(g_menu_notified == !after_refusal);

    ingress(kBridge, kListener, kReserved);
    check_delivery(kHostPeer, kListener, kReserved, kBridge);
    CHECK(g_stats.drop_world_only == 1);
}
}

int run(std::string_view scenario)
{
    CHECK(reserve(kReserved));
    mgr().session_data.bridge_joined = scenario != "coop-guest" && scenario != "coop-host";

    if (scenario == "reserved-broadcast") check_reserved_bridge_drop(-1);
    else if (scenario == "reserved-player") check_reserved_bridge_drop(kListener);
    else if (scenario == "reserved-world") check_reserved_bridge_drop(kHostPeer);
    else if (scenario == "ordinary-bridge")
    {
        ingress(kBridge, kListener, kOrdinary, kGuest);
        check_delivery(kHostPeer, kListener, kOrdinary, kBridge);
        CHECK(g_inbox.empty());

        ingress(kBridge, kHostPeer, kOrdinary, kGuest);
        CHECK(net::deliveries.size() == 1);
        CHECK(g_inbox.size() == 1);
        CHECK(g_inbox.front().from == kBridge && g_inbox.front().payload == kPayload);
        CHECK(g_stats.drop_world_only == 0);
    }
    else if (scenario == "coop-guest") check_coop_event(kGuest);
    else if (scenario == "coop-host") check_coop_event(kHostPeer);
    else if (scenario == "lua-registration")
    {
        CHECK(!reserve("123", LUA_TNUMBER));
        CHECK(!reserve(std::string("a\0b", 3)));
        CHECK(reserve(std::string(64, 'x')));
        CHECK(!reserve(std::string(65, 'x')));
    }
    else if (scenario == "session-end") check_cleanup(false);
    else if (scenario == "session-end-after-refusal") check_cleanup(true);
    else return 2;
    return 0;
}
}
}

int main(int argc, char** argv) { return argc == 2 ? coop::script::run(argv[1]) : 2; }
