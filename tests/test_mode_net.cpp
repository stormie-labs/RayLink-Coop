// S6 network migration: preserve the authority and receiver for each process kind.
#include "test_util.h"
#include "coop_calls.h"
#include "srv/coop_levels_wire.h"
#include "coop_load_barrier.h"
#include "coop_newchar.h"
#include "coop_routes.h"
#include "support/fake_mode.h"
#include "../engine/src/xrGame/coop/coop_net.h"

#include <fstream>
#include <iterator>
#include <string_view>

namespace
{
using namespace coop;
using levels::LevelMapCheck;
using levels::wire::LevelMapMsg;

void check_routes(const t::ModeCase& kind)
{
	const t::FakeMode mode(kind);
	const std::string_view name(kind.name);
	const bool in_session = name != "none";
	const bool world = name == "coop_host" || name == "world_server";
	const bool level = world || name == "map_server";
	const auto runs = [&](routes::Domain domain) {
		return net::route_runs_here(domain, in_session, mode);
	};
	CHECK_EQ(runs(routes::Domain::Host), !in_session || world);
	CHECK_EQ(runs(routes::Domain::Level), !in_session || level);
	CHECK(runs(routes::Domain::Owner));
	CHECK(runs(routes::Domain::View));
	CHECK_EQ(runs(routes::Domain::None), !in_session);

	// Only the non-deciders in the world enter the client call gate. Of those, the map server can
	// run a valid local level call. Neither bad arguments nor an existing request path are overridden.
	if (in_session && !world)
	{
		constexpr auto call = "game_object:set_npc_position";
		const auto gate = [&](calls::Gate base, bool valid) {
			return mode.leads_level() ? calls::decide_leading(call, base, valid) : base;
		};
		CHECK_EQ(gate(calls::Gate::Refuse, true), name == "map_server" ? calls::Gate::Run : calls::Gate::Refuse);
		CHECK_EQ(gate(calls::Gate::Refuse, false), calls::Gate::Refuse);
		CHECK_EQ(gate(calls::Gate::Request, true), calls::Gate::Request);
	}
	if (world)
	{
		CHECK(newchar::point_usable(true, true, !mode.leads_level()));
		CHECK_EQ(newchar::point_usable(true, false, !mode.leads_level()), name == "world_server");
		CHECK(!newchar::point_usable(false, true, !mode.leads_level()));
	}
}

Writer map_packet(uint16_t player_level = 7, uint16_t server_level = 7, uint16_t gate_level = 7,
    uint8_t in_world = 0)
{
	LevelMapMsg m;
	m.flags = LevelMapMsg::Split;
	m.players.push_back({1, player_level, in_world, 0xffff, 0});
	m.servers.push_back({server_level});
	m.gates.push_back({gate_level, 1, "st_coop_levels"});
	Writer w;
	REQUIRE(m.write(w));
	return w;
}

struct MapReceiver
{
	LevelMapMsg view;
	std::vector<std::pair<LevelMapCheck, bool>> checks;

	bool receive(const Writer& payload, PeerId from, bool active, const Mode& mode, bool welcomed)
	{
		Reader r(payload.ptr(), payload.size());
		return levels::receive_level_map(from, net::client(active, mode), welcomed, r, view,
		    [this](LevelMapCheck check, bool ok) { checks.emplace_back(check, ok); });
	}
};

void check_level_map(const t::ModeCase& kind)
{
	const t::FakeMode mode(kind);
	const std::string_view name(kind.name);
	const bool active = name != "none";
	const bool takes_map = name == "coop_client" || name == "map_server" || name == "server_client";
	MapReceiver receiver;
	const auto packet = map_packet();
	CHECK_EQ(receiver.receive(packet, kHostPeer, active, mode, active), takes_map);
	REQUIRE(receiver.view.players.size() == (takes_map ? size_t(1) : size_t(0)));
	if (takes_map)
		CHECK_EQ(receiver.view.players[0].level, 7u);
}

// The native target does not link xrGame. Keep a source check at each boundary exercised through
// facts above so that a fallback to the legacy role queries cannot silently bypass the contract.
std::string game_source(const char* file)
{
	const std::string here = __FILE__;
	const auto slash = here.find_last_of("\\/");
	const auto dir = slash == std::string::npos ? std::string(".") : here.substr(0, slash);
	std::ifstream in(dir + "/../engine/src/xrGame/coop/" + file, std::ios::binary);
	return {std::istreambuf_iterator<char>(in), {}};
}

std::string_view section(std::string_view source, std::string_view start, std::string_view end)
{
	const size_t first = source.find(start);
	REQUIRE(first != std::string_view::npos);
	const size_t last = source.find(end, first + start.size());
	REQUIRE(last != std::string_view::npos);
	return source.substr(first, last - first);
}

void asks(std::string_view code, std::string_view answer)
{
	CHECK(code.find(answer) != std::string_view::npos);
}
} // namespace

#define NET_CASE(kind) \
	TEST(mode_net_routes_##kind) { check_routes(t::mode_case(#kind)); } \
	TEST(mode_net_level_map_##kind) { check_level_map(t::mode_case(#kind)); }
MODE_CASES(NET_CASE)
#undef NET_CASE

TEST(mode_net_before_welcome)
{
	const t::FakeMode player(t::mode_case("none")); // installed by the Welcome
	const t::FakeMode map(t::mode_case("map_server")); // installed at bridge startup
	const auto packet = map_packet();
	for (const Mode* mode : {static_cast<const Mode*>(&player), static_cast<const Mode*>(&map)})
	{
		CHECK(!net::route_runs_here(routes::Domain::Host, true, *mode));
		CHECK_EQ(net::route_runs_here(routes::Domain::Level, true, *mode), mode == &map);
		CHECK(net::route_runs_here(routes::Domain::Owner, true, *mode));
		CHECK(!net::route_runs_here(routes::Domain::None, true, *mode));
		MapReceiver receiver;
		CHECK(!receiver.receive(packet, kHostPeer, true, *mode, false));
		CHECK(receiver.view.players.empty());
		REQUIRE(!receiver.checks.empty());
		CHECK_EQ(receiver.checks.back().first, LevelMapCheck::Phase);
		CHECK(!receiver.checks.back().second);
	}
}

TEST(mode_net_level_map_refuses_transport_sender_and_accounts_before_return)
{
	const t::FakeMode mode(t::mode_case("map_server"));
	MapReceiver receiver;
	CHECK(!receiver.receive(map_packet(), 3, true, mode, true));
	CHECK(receiver.view.players.empty());
	REQUIRE(!receiver.checks.empty());
	CHECK_EQ(receiver.checks.back().first, LevelMapCheck::Sender);
	CHECK(!receiver.checks.back().second);
}

TEST(mode_net_level_map_requires_complete_payload)
{
	const t::FakeMode mode(t::mode_case("server_client"));
	MapReceiver receiver;
	REQUIRE(receiver.receive(map_packet(), kHostPeer, true, mode, true));
	auto trailing = map_packet(8);
	trailing.u8(0);
	CHECK(!receiver.receive(trailing, kHostPeer, true, mode, true));
	REQUIRE(!receiver.view.players.empty());
	CHECK_EQ(receiver.view.players[0].level, 7u);
	REQUIRE(!receiver.checks.empty());
	CHECK_EQ(receiver.checks.back().first, LevelMapCheck::Payload);
	CHECK(!receiver.checks.back().second);

	const auto truncated = map_packet(8);
	Writer short_packet;
	short_packet.bytes(truncated.ptr(), truncated.size() - 1);
	CHECK(!receiver.receive(short_packet, kHostPeer, true, mode, true));
	CHECK_EQ(receiver.view.players[0].level, 7u);
	CHECK_EQ(receiver.checks.back().first, LevelMapCheck::Payload);
	CHECK(!receiver.checks.back().second);
}

TEST(mode_net_level_map_level_ids_and_sentinels)
{
	const t::FakeMode mode(t::mode_case("map_server"));
	MapReceiver receiver;
	REQUIRE(receiver.receive(map_packet(0xffff, 255, 0), kHostPeer, true, mode, true));
	CHECK_EQ(receiver.view.players[0].level, 0xffffu);
	CHECK_EQ(receiver.view.servers[0].level, 255u);
	CHECK_EQ(receiver.view.gates[0].level, 0u);
	REQUIRE(receiver.receive(map_packet(255, 0, 255, 1), kHostPeer, true, mode, true));

	for (const auto& packet : {map_packet(256), map_packet(7, 256), map_packet(7, 7, 65534),
	        map_packet(0xffff, 7, 7, 1)})
	{
		CHECK(!receiver.receive(packet, kHostPeer, true, mode, true));
		CHECK_EQ(receiver.view.players[0].level, 255u);
		REQUIRE(!receiver.checks.empty());
		CHECK_EQ(receiver.checks.back().first, LevelMapCheck::LevelIds);
		CHECK(!receiver.checks.back().second);
	}
	for (const auto& packet : {map_packet(7, 0xffff), map_packet(7, 7, 0xffff)})
	{
		CHECK(!receiver.receive(packet, kHostPeer, true, mode, true));
		CHECK_EQ(receiver.view.players[0].level, 255u);
		CHECK_EQ(receiver.checks.back().first, LevelMapCheck::Payload);
		CHECK(!receiver.checks.back().second);
	}
}

TEST(mode_net_coop_load_opens_when_the_group_is_ready)
{
	coop::levels::LoadBarrier barrier;
	CHECK(!barrier.enter(0));
	barrier.start(7, {0, 8}, false, 0);
	barrier.world_up(7);
	CHECK(!barrier.enter(1));
	barrier.ready(8, 7);
	CHECK(barrier.enters(8, 2));
}

TEST(mode_net_server_load_needs_the_map_server_of_this_epoch)
{
	coop::levels::LoadBarrier barrier;
	barrier.start(7, {8}, true, 0);
	barrier.ready(8, 7);
	barrier.server_ready(6);
	CHECK(!barrier.enter(1));
	CHECK(barrier.waiting_server());
	barrier.server_ready(7);
	CHECK(barrier.enters(8, 2));
	barrier.start(8, {8}, true, 3);
	CHECK(barrier.waiting_server());
}

TEST(mode_net_engine_dispatch_asks_mode_for_authority)
{
	const auto router = game_source("coop_router.cpp");
	const auto runs = section(router, "bool runs_now(", "\n}");
	asks(runs, "net::route_runs_here(d, m.active(), mode())");
	const auto callgate = game_source("coop_callgate.cpp");
	const auto decide = section(callgate, "Gate decide(", "\n}");
	asks(decide, "requests::lua_client()");
	asks(decide, "if (mode().leads_level())");
	asks(decide, "calls::decide_leading");
}

TEST(mode_net_engine_receivers_keep_phase_and_authority_checks)
{
	const auto net = game_source("coop_net.h");
	asks(net, "active && !mode.decides_world()");
	const auto impl = game_source("coop_net.cpp");
	const auto client = section(impl, "bool client()", "\n");
	asks(client, "client(mgr().active(), mode())");
	const auto host = section(impl, "bool host()", "\n");
	asks(host, "mode().decides_world()");
	asks(host, "mode().leads_level()");
	const auto live = section(impl, "bool live()", "\n");
	asks(live, "mode().decides_world()");
	asks(live, "mgr().is_live_client()");

	const auto remote = game_source("coop_remote.cpp");
	const auto apply = section(remote, "bool apply(CGameObject*", "\n}");
	asks(apply, "net::client()");
	asks(apply, "net::host()");
	const auto die = section(remote, "void on_puppet_die(", "\n}");
	asks(die, "!net::client()");
	const auto manager = game_source("coop_manager.cpp");
	const auto left = section(manager, "m_session.on_peer_left =", "install_world_callbacks(m_session)");
	asks(left, "net::host()");
	const auto keypress = section(manager, "bool skip_keypress_on_load()", "\n}");
	asks(keypress, "net::client()");
}

TEST(mode_net_level_map_production_receiver_uses_transport_and_trust)
{
	const auto levels = game_source("coop_levels.cpp");
	const auto receive = section(levels, "void client_on_level_map(", "\n}");
	asks(receive, "receive_level_map(from, net::client(), mgr().world_session().is_active()");
	asks(receive, "account_level_map");
	asks(receive, "mapserver::server_on_map(g.view)");
	asks(levels, "e.on(Msg::LevelMap, &client_on_level_map)");
	asks(levels, "luafn::call_named(L, \"coop_trust\", \"pass\"");
}
