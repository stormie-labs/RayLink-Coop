// Test runner for the hub slices compiled from xrGame by test_s6_hub_paths.py.
#include "test_util.h"
#include "support/fake_mode.h"
#include "coop_limits.h"
#include "coop_lua_errors.h"
#include "srv/coop_mapserver_rules.h"
#include "coop_roster.h"
#include "../engine/src/xrGame/coop/coop_net.h"

#include <atomic>
#include <cmath>
#include <deque>
#include <limits>
#include <string_view>

using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using s32 = int32_t;
using s64 = int64_t;
using LPCSTR = const char*;
using xr_string = std::string;
#include "../engine/src/xrGame/coop/coop_script.h"

void Msg(const char*, ...) {}

constexpr int LUA_TNIL = 0, LUA_TNUMBER = 3, LUA_TSTRING = 4;
using lua_Number = double;
struct lua_State
{
	std::string line;
	bool result = false;
	std::string error;
	int target_type = LUA_TNIL;
	lua_Number target = 0;
};
int lua_type(lua_State* L, int index)
{
	return index == 1 ? LUA_TSTRING : (index == 3 ? L->target_type : LUA_TNIL);
}
bool lua_isnoneornil(lua_State* L, int index) { return lua_type(L, index) == LUA_TNIL; }
bool lua_isstring(lua_State* L, int index) { return lua_type(L, index) == LUA_TSTRING; }
lua_Number lua_tonumber(lua_State* L, int) { return L->target; }
const char* lua_tolstring(lua_State* L, int, size_t* length)
{
	*length = L->line.size();
	return L->line.c_str();
}
void lua_pushboolean(lua_State* L, int value) { L->result = value != 0; }
void lua_pushstring(lua_State* L, const char* value) { L->error = value; }

namespace coop
{
constexpr PeerId kGuest = 1, kListener = 2;
constexpr PeerId kBridge = mapserver::bridge_peer(1);
bool g_pGameLevel = true, g_actor = true, g_coop_dedicated = false;
PeerId g_joining = kInvalidPeer;
std::vector<PeerInfo> rows;
bool has_local_link = false, bridge_connected = false;
Role session_role = Role::None;
bool operator_rights = false, operator_transport = false;
std::vector<std::string> operator_attempts;
LocalLink local_link;

// The game paths read the roster and transport facts from this test Session.
struct Session::Impl {};
Session::Session() = default;
Session::~Session() = default;
void Session::on(Msg, Handler) {}
const PeerInfo* Session::peer(PeerId id) const
{
	for (const auto& row : rows)
		if (row.id == id)
			return &row;
	return nullptr;
}
std::vector<PeerInfo> Session::peers() const { return rows; }
bool Session::joined(PeerId id) const { return peer(id) || (bridge_connected && id == kBridge); }
LocalLink* Session::local() const { return has_local_link ? &local_link : nullptr; }
Role Session::role() const { return session_role; }
bool Session::self_host_rights() const { return operator_rights; }
bool Session::send_operator_command(const std::string& line)
{
	operator_attempts.push_back(line);
	return operator_transport;
}

struct Manager
{
	bool active_flag = false;
	bool live_client = false;
	bool old_host = false;
	bool old_client = false;
	bool old_map_server = false;
	PeerId peer = kInvalidPeer;
	Session data;

	bool active() const { return active_flag; }
	bool is_host() const { return old_host; }
	bool is_client() const { return old_client; }
	bool is_live_client() const { return live_client; }
	PeerId self() const { return peer; }
	u64 now_ms() const { return 1000; }
	Session& session() { return data; }
	const Session& session() const { return data; }
};

Manager& mgr()
{
	static Manager instance;
	return instance;
}

ModeSlot mode_slot;
Mode& mode() { return mode_slot.get(); }
bool is_map_server() { return mgr().old_map_server; }

namespace sync
{
bool host_peer_joining(PeerId peer) { return g_joining == peer; }
// PRODUCTION_SYNC
}

namespace net
{
// PRODUCTION_NET
enum class Path { Broadcast, Target, Up };
struct Send
{
	Path path;
	PeerId peer;
	Msg type;
	Lane lane;
	std::vector<uint8_t> data;
};
std::vector<Send> sends;
void host_broadcast(Msg type, const Writer& w, Lane lane, PeerId except)
{
	sends.push_back({Path::Broadcast, except, type, lane, w.data()});
}
void host_send(PeerId to, Msg type, const Writer& w, Lane lane)
{
	sends.push_back({Path::Target, to, type, lane, w.data()});
}
void client_send(Msg type, const Writer& w, Lane lane)
{
	sends.push_back({Path::Up, kHostPeer, type, lane, w.data()});
}
}

namespace syncapi
{
constexpr size_t kMaxOutbox = 1024;
constexpr u64 kLogBurst = 10;
// PRODUCTION_SYNCAPI_TYPES
std::deque<Out> g_out, g_level_out;
Stats g_stats;
// PRODUCTION_SYNCAPI
}

namespace script
{
constexpr size_t kMaxPayload = 16 * 1024;
constexpr size_t kMaxOutbox = 512;
constexpr size_t kMaxInbox = 4096, kMaxInboxBytes = 4 * 1024 * 1024;
constexpr s32 kTargetAll = -1;
constexpr u64 kLogBurst = 10;
// PRODUCTION_SCRIPT_TYPES
Stats g_stats;
WorldEventReservations g_world_events;
std::deque<Incoming> g_inbox;
std::deque<Outgoing> g_outbox;
size_t g_inbox_bytes = 0;
u32 g_lost_events = 0;
std::atomic<u64> g_tick{0};
limits::Pacer g_pacer;
// PRODUCTION_SCRIPT
}

namespace
{
struct Expected
{
	bool active, decides, client, level, host_seat, self_plays;
};
constexpr Expected coop_host    {true, true,  false, false, true,  true};
constexpr Expected coop_client  {true, false, true,  false, true,  true};
constexpr Expected world_server {true, true,  false, false, false, false};
constexpr Expected map_server   {true, false, true,  true,  true,  true};
constexpr Expected server_client{true, false, true,  false, false, true};
constexpr Expected none         {false,false, false, false, true,  true};

void setup(Mode& answers, const Expected& e)
{
	mode_slot.reset();
	REQUIRE(mode_slot.install(answers));
	mgr().active_flag = e.active;
	mgr().live_client = e.client;
	mgr().old_host = e.decides;
	mgr().old_client = e.client;
	mgr().old_map_server = e.level;
	mgr().peer = !e.active ? kInvalidPeer : (e.decides ? kHostPeer : (e.level ? kBridge : kGuest));
	g_coop_dedicated = e.decides && !e.host_seat;
	has_local_link = e.decides && e.host_seat;
	bridge_connected = e.decides && !e.host_seat;
	session_role = e.decides || e.level ? Role::Host : (e.client ? Role::Client : Role::None);
	operator_rights = operator_transport = false;
	operator_attempts.clear();
	rows.clear();
	for (const PeerId id : {kGuest, kListener})
	{
		if (!e.active || id == mgr().self())
			continue;
		PeerInfo row;
		row.id = id;
		row.plays = true;
		row.state = PeerState::Joined;
		rows.push_back(row);
	}
	if (e.client && !e.level)
	{
		PeerInfo row;
		row.id = kHostPeer;
		row.plays = e.host_seat;
		row.state = PeerState::Joined;
		rows.push_back(row);
	}
	g_pGameLevel = g_actor = true;
	g_joining = kInvalidPeer;
	syncapi::g_out.clear();
	syncapi::g_level_out.clear();
	net::sends.clear();
	script::g_pacer.reset();
	script::g_outbox.clear();
	script::g_inbox.clear();
	script::g_inbox_bytes = 0;
	script::g_stats = {};
}

void check_cast(const Expected& e)
{
	Writer w;
	w.u8(123);
	syncapi::cast_to(kListener, std::move(w));
	CHECK(net::sends.empty());
	syncapi::host_flush();
	CHECK_EQ(net::sends.size(), e.decides ? 1u : 0u);
	syncapi::level_flush();
	REQUIRE(net::sends.size() == (e.decides || e.level ? 1u : 0u));
	if (!net::sends.empty())
	{
		const auto& send = net::sends.front();
		CHECK_EQ(send.path, net::Path::Target);
		CHECK_EQ(send.peer, kListener);
		CHECK_EQ(send.type, Msg::SyncCast);
		CHECK_EQ(send.lane, Lane::Reliable);
		CHECK(send.data == std::vector<uint8_t>{123});
	}
}

void check_event_wire(const net::Send& send, net::Path path, PeerId peer, PeerId origin, s32 target)
{
	CHECK_EQ(send.path, path);
	CHECK_EQ(send.peer, peer);
	CHECK_EQ(send.type, Msg::ScriptEvent);
	CHECK_EQ(send.lane, Lane::Reliable);
	Reader wire(send.data.data(), send.data.size());
	CHECK_EQ(wire.u32(), origin);
	CHECK_EQ(wire.i32(), target);
	CHECK_EQ(wire.str(), "hub.event");
	CHECK_EQ(wire.str(), "data");
	CHECK(wire.ok() && wire.remaining() == 0);
}

void check_event_outbox(const Expected& e)
{
	net::sends.clear();
	script::g_outbox.push_back({-1, "hub.event", "data"});
	script::flush_outbox();
	REQUIRE(net::sends.size() == (e.level ? 2u : (e.active ? 1u : 0u)));
	if (e.decides)
		check_event_wire(net::sends[0], net::Path::Broadcast, kHostPeer, kHostPeer, -1);
	else if (e.level)
	{
		check_event_wire(net::sends[0], net::Path::Up, kHostPeer, kBridge, kGuest);
		check_event_wire(net::sends[1], net::Path::Up, kHostPeer, kBridge, kListener);
	}
	else if (e.client)
		check_event_wire(net::sends[0], net::Path::Up, kHostPeer, kGuest, -1);
}

void check_event_ingress(const Expected& e)
{
	Writer packet;
	script::write_event(packet, kBridge, kHostPeer, "hub.event", "data");
	Reader world(packet.ptr(), packet.size());
	script::server_on_script_event(kGuest, world);
	REQUIRE(script::g_inbox.size() == (e.decides ? 1u : 0u));
	if (e.decides)
		CHECK_EQ(script::g_inbox.back().from, kGuest); // the player cannot choose the wire origin
	Reader stranger(packet.ptr(), packet.size());
	script::client_on_script_event(kListener, stranger);
	CHECK_EQ(script::g_inbox.size(), e.decides ? 1u : 0u);
	Reader host(packet.ptr(), packet.size());
	script::client_on_script_event(kHostPeer, host);
	REQUIRE(script::g_inbox.size() == (e.decides || e.client ? 1u : 0u));
	if (e.client)
		CHECK_EQ(script::g_inbox.back().from, kBridge); // only the authenticated host relays an origin
}

void check_operator(const std::string& line, const char* error)
{
	lua_State args{line, false, {}};
	CHECK_EQ(script::l_operator_command(&args), error ? 2 : 1);
	CHECK_EQ(args.result, error == nullptr);
	CHECK_EQ(args.error, error ? error : "");
}

void check_operator_transport(const char* name, const Expected& e)
{
	t::FakeMode answers(t::mode_case(name));
	setup(answers, e);
	check_operator("coop_dbg status; quit", "not_operator");
	operator_rights = true;
	check_operator("coop_dbg status; quit", "bad_line");
	CHECK(operator_attempts.empty());
	check_operator("coop_dbg status", "not_joined");
	CHECK((operator_attempts == std::vector<std::string>{"coop_dbg status"}));
	operator_transport = true;
	check_operator("coop_dbg status", nullptr);
	CHECK((operator_attempts == std::vector<std::string>{"coop_dbg status", "coop_dbg status"}));
	mode_slot.reset();
}

void check_process(const char* name, const Expected& e)
{
	t::FakeMode answers(t::mode_case(name));
	setup(answers, e);
	CHECK_EQ(sync::alife_frozen(), e.client);
	CHECK_EQ(syncapi::client(), e.client);
	CHECK_EQ(syncapi::in_world(kHostPeer), e.decides && e.host_seat);
	CHECK_EQ(syncapi::in_world(kListener), e.active);
	g_joining = kListener;
	CHECK(!syncapi::in_world(kListener));
	g_joining = kInvalidPeer;
	CHECK_EQ(script::host_seat_plays(), e.host_seat);
	CHECK_EQ(script::self_row(mgr().self()).plays, e.self_plays);
	CHECK_EQ(script::lua_ready(), e.active);
	g_pGameLevel = false;
	CHECK(!script::lua_ready());
	g_pGameLevel = true;
	check_cast(e);
	check_event_outbox(e);
	check_event_ingress(e);
	check_operator(std::string(1025, 'x'), "bad_line");
	check_operator("coop_dbg status", session_role == Role::Client ? "not_operator" : "not_joined");
	if (std::string_view(name) == "server_client")
	{
		operator_rights = operator_transport = true;
		check_operator("coop_dbg status", nullptr);
		check_operator("coop_dbg status; quit", "bad_line");
	}
	mode_slot.reset();
}

#define HUB_CASE(name) TEST(hub_parity_##name) { check_process(#name, name); }
MODE_CASES(HUB_CASE)
#undef HUB_CASE

TEST(hub_operator_keeps_coop_client_validation_and_send)
{
	check_operator_transport("coop_client", coop_client);
}

TEST(hub_operator_keeps_server_player_validation_and_send)
{
	check_operator_transport("server_client", server_client);
}

TEST(hub_host_mode_installed_before_session_is_live)
{
	t::FakeMode answers(t::mode_case("coop_host"));
	setup(answers, coop_host);
	mgr().active_flag = false;
	mgr().old_host = false;
	CHECK(!script::lua_ready());
	CHECK(!syncapi::in_world(kHostPeer));
	check_cast(none);
	mode_slot.reset();
}

TEST(hub_connecting_before_welcome_is_a_world_client)
{
	t::FakeMode answers(t::mode_case("none"));
	setup(answers, none);
	mgr().active_flag = mgr().old_client = true;
	CHECK(sync::alife_frozen());
	CHECK(syncapi::client());
	CHECK(!script::lua_ready());
	mode_slot.reset();
}

#ifndef COOP_HUB_BASELINE
TEST(hub_dispatch_uses_current_mode_answers)
{
	t::FakeMode host(t::mode_case("coop_host"));
	setup(host, coop_host);
	g_coop_dedicated = true;
	CHECK(script::host_seat_plays());
	CHECK(script::self_row(mgr().self()).plays);
	mgr().old_host = false;
	CHECK(script::lua_ready());
	CHECK(syncapi::in_world(kHostPeer));
	check_cast(coop_host);
	check_event_outbox(coop_host);

	t::FakeMode map(t::mode_case("map_server"));
	setup(map, map_server);
	mgr().old_client = mgr().old_map_server = false;
	CHECK(sync::alife_frozen());
	CHECK(syncapi::client());
	check_cast(map_server);
	check_event_outbox(map_server);
	mode_slot.reset();
}

void check_world_ingress_answer(const char* name, const Expected& e)
{
	t::FakeMode answers(t::mode_case(name));
	setup(answers, e);
	mgr().old_host = !e.decides;
	Writer packet;
	script::write_event(packet, kBridge, kHostPeer, "hub.event", "data");
	Reader wire(packet.ptr(), packet.size());
	script::server_on_script_event(kListener, wire);
	CHECK_EQ(script::g_inbox.size(), e.decides ? 1u : 0u);
	if (!script::g_inbox.empty())
		CHECK_EQ(script::g_inbox.back().from, kListener);
	mode_slot.reset();
}

void check_event_rejects_trailing_bytes(const char* name, const Expected& e)
{
	t::FakeMode answers(t::mode_case(name));
	setup(answers, e);
	Writer packet;
	script::write_event(packet, kGuest, e.decides ? -1 : s32(kListener), "hub.event", "data");
	packet.u8(0);
	Reader wire(packet.ptr(), packet.size());
	if (e.decides)
		script::server_on_script_event(kGuest, wire);
	else
		script::client_on_script_event(kHostPeer, wire);
	CHECK(script::g_inbox.empty());
	CHECK(net::sends.empty());
	CHECK_EQ(script::g_stats.drop_invalid, 1u);
	CHECK_EQ(script::g_stats.received, 0u);
	mode_slot.reset();
}

void check_event_target_bounds(const char* name, const Expected& e)
{
	t::FakeMode answers(t::mode_case(name));
	setup(answers, e);
	const auto inf = std::numeric_limits<lua_Number>::infinity();
	for (const lua_Number target : {-2.0, -0.5, 2.5, 257.5, inf, -inf,
	    std::numeric_limits<lua_Number>::quiet_NaN(), 2147483648.0, 4294967553.0})
	{
		lua_State args{"hub.event", false, {}, LUA_TNUMBER, target};
		CHECK_EQ(script::l_send_event(&args), 2);
		CHECK(!args.result);
		CHECK_EQ(args.error, "bad target");
	}
	CHECK(script::g_outbox.empty());
	for (const lua_Number target : {-1.0, 0.0, 2.0})
	{
		lua_State args{"hub.event", false, {}, LUA_TNUMBER, target};
		CHECK_EQ(script::l_send_event(&args), 1);
		CHECK(args.result);
		REQUIRE(!script::g_outbox.empty());
		CHECK_EQ(script::g_outbox.back().target, s32(target));
	}
	mode_slot.reset();
}

#define HUB_EVENT_CASE(name) \
	TEST(hub_world_ingress_facade_##name) { check_world_ingress_answer(#name, name); }
MODE_CASES(HUB_EVENT_CASE)
#undef HUB_EVENT_CASE

TEST(hub_no_session_refuses_world_ingress_even_if_the_raw_host_flag_is_set)
{
	t::FakeMode answers(t::mode_case("none"));
	setup(answers, none);
	mgr().old_host = true;
	has_local_link = true;
	Writer packet;
	script::write_event(packet, kHostPeer, kHostPeer, "hub.event", "data");
	Reader wire(packet.ptr(), packet.size());
	script::server_on_script_event(kHostPeer, wire);
	CHECK(script::g_inbox.empty());
	mode_slot.reset();
}

#define HUB_WIRE_CASE(name) \
	TEST(hub_event_requires_complete_payload_##name) { check_event_rejects_trailing_bytes(#name, name); }
HUB_WIRE_CASE(coop_host)
HUB_WIRE_CASE(coop_client)
HUB_WIRE_CASE(world_server)
HUB_WIRE_CASE(server_client)
#undef HUB_WIRE_CASE

TEST(hub_event_target_bounds_coop_client) { check_event_target_bounds("coop_client", coop_client); }
TEST(hub_event_target_bounds_world_server) { check_event_target_bounds("world_server", world_server); }
#endif
} // namespace
} // namespace coop

namespace t
{
std::vector<TestCase>& registry() { static std::vector<TestCase> cases; return cases; }
int& failures_in_test() { static int failures; return failures; }
void report_failure(const char* file, int line, const std::string& what)
{
	++failures_in_test();
	std::printf("  %s:%d: %s\n", file, line, what.c_str());
}
}

int main()
{
	unsigned failed = 0;
	for (const auto& test : t::registry())
	{
		std::printf("[RUN ] %s\n", test.name);
		t::failures_in_test() = 0;
		try { test.fn(); }
		catch (const t::Abort&) {}
		failed += t::failures_in_test() != 0;
	}
	std::printf("%zu passed, %u failed\n", t::registry().size() - failed, failed);
	return failed ? 1 : 0;
}
