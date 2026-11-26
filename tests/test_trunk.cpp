// Anomaly Coop unit tests: the trunk between the host's process and a map server (F3a, plan §1.3) on real sessions over the loopback:
// Hello role MapServer (the token, no player slot), TrunkOnly from a bridge alone, and the two sessions of a map server: the
// connection to the world server and the host of its level, whose players are virtual peers behind Msg::Tunnel. The rig does what
// coop_trunk.cpp does in the game: the host's in-filter tunnels a map message, the Tunnel handlers of both sides unwrap it. A client
// talks to the host's process alone and his session has no idea that a map server exists.
#include "test_util.h"

#include "srv/coop_mapserver_rules.h"
#include "srv/coop_session_srv.h"

#include <chrono>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using namespace coop;

namespace
{
using srv::SessionSrv;
using t::Node;
using levels::wire::TunnelMsg;

constexpr uint32_t kMs = 2; // the number of the map server of the rig

mapserver::Token token_of(uint8_t first)
{
	mapserver::Token out{};
	for (size_t i = 0; i < out.size(); ++i)
		out[i] = uint8_t(first + 3 * i);
	return out;
}

// The host's process, a map server (its connection `world` and the host of its level `map`), and clients.
struct Trunk
{
	explicit Trunk(uint16_t port) : host("Boss", port), world("ms", port), port_(port)
	{
		host.s.on(Msg::Tunnel, [this](PeerId from, Reader& r) {
			// coop_trunk.cpp host_on_tunnel
			TunnelMsg m;
			if (m.read(r))
			{
				Writer w(m.packet.size());
				w.bytes(m.packet.data() + 2, m.packet.size() - 2);
				host.s.send(m.peer, mapserver::tunnel_lane(m.flags), m.type(), w);
				last_bridge = from;
			}
		});
		world.s.on(Msg::Tunnel, [this](PeerId, Reader& r) {
			// coop_trunk.cpp server_on_tunnel
			TunnelMsg m;
			if (m.read(r))
				SessionSrv(map).virtual_receive(m.peer, mapserver::tunnel_lane(m.flags), m.packet.data(), m.packet.size());
		});
		map.set_log([this](const char* line) { world.log.emplace_back(line); });
		host_filter_self() = this;
		host.s.set_in_filter(&Trunk::in_filter);
	}
	~Trunk() { host_filter_self() = nullptr; }

	static Trunk*& host_filter_self()
	{
		static Trunk* self = nullptr;
		return self;
	}

	// coop_trunk.cpp host_incoming: every player of the rig stands on the map server's level.
	static bool in_filter(PeerId from, Msg type, Lane lane, const uint8_t* packet, size_t size)
	{
		return host_filter_self()->incoming(from, type, lane, packet, size);
	}
	bool incoming(PeerId from, Msg type, Lane lane, const uint8_t* packet, size_t size)
	{
		const mapserver::Incoming go = mapserver::route_incoming(type, true, false, SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(kMs)));
		if (go.tunnel)
		{
			TunnelMsg m;
			m.peer = from;
			m.flags = mapserver::tunnel_lane_flags(lane);
			m.packet.assign(packet, packet + size);
			Writer w(size + 8);
			if (m.write(w))
				host.s.send(mapserver::bridge_peer(kMs), lane, Msg::Tunnel, w);
		}
		return go.here;
	}

	void pump_once()
	{
		const uint64_t now = t::now_ms();
		host.s.update(now);
		world.s.update(now);
		map.update(now);
		for (auto& c : clients)
			c->s.update(now);
	}
	bool pump(uint32_t timeout_ms, const std::function<bool()>& done)
	{
		const uint64_t start = t::now_ms();
		for (;;)
		{
			pump_once();
			if (done())
				return true;
			if (t::now_ms() - start > timeout_ms)
				return false;
			std::this_thread::sleep_for(std::chrono::milliseconds(1));
		}
	}

	bool start()
	{
		std::string err;
		host.cfg.mode = SessionMode::Coop;
		return host.host(&err);
	}

	// The map server connects with the token its command line would carry, then hosts its level.
	bool connect_server()
	{
		SessionSrv(host.s).issue_bridge(kMs, token_of(7));
		world.cfg.hello_role = kHelloRoleMapServer;
		world.cfg.hello_token = token_of(7);
		world.cfg.mode = SessionMode::Server;
		std::string err;
		if (!world.connect(port_, &err))
			return false;
		if (!pump(5000, [this] { return world.s.is_active(); }))
			return false;
		return SessionSrv(map).host_virtual(world.cfg, world.s, &err);
	}

	Node& add_client(const std::string& nick)
	{
		clients.push_back(std::make_unique<Node>(nick, port_));
		Node& c = *clients.back();
		std::string err;
		REQUIRE(c.connect(port_, &err));
		REQUIRE(pump(5000, [&c] { return c.s.is_active(); }));
		return c;
	}

	Node host;
	Node world;
	Session map;
	PeerId last_bridge = kInvalidPeer;
	std::vector<std::unique_ptr<Node>> clients;

private:
	uint16_t port_;
};

Writer payload(uint32_t v)
{
	Writer w;
	w.u32(v);
	return w;
}
} // namespace

// ---------------------------------------------------------------- Hello

TEST(trunk_hello_only_loopback_token)
{
	Trunk k(t::port(37201));
	REQUIRE(k.start());
	// a token the session did not issue
	Node stranger("x", t::port(37201));
	stranger.cfg.hello_role = kHelloRoleMapServer;
	stranger.cfg.hello_token = token_of(9);
	std::string err;
	REQUIRE(stranger.connect(t::port(37201), &err));
	const auto both = [&] {
		k.host.s.update(t::now_ms());
		stranger.s.update(t::now_ms());
		return stranger.rejected;
	};
	SessionSrv(k.host.s).issue_bridge(kMs, token_of(7));
	const uint64_t start = t::now_ms();
	while (!both() && t::now_ms() - start < 5000)
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	CHECK(stranger.rejected);
	CHECK(SessionSrv(k.host.s).bridges().empty());
	CHECK(k.host.s.peers().empty());

	// the issued one: a bridge, not a player
	REQUIRE(k.connect_server());
	CHECK_EQ(k.world.s.self(), mapserver::bridge_peer(kMs));
	CHECK_EQ(k.map.self(), mapserver::bridge_peer(kMs));
	REQUIRE(SessionSrv(k.host.s).bridges().size() == 1);
	CHECK_EQ(SessionSrv(k.host.s).bridges()[0], mapserver::bridge_peer(kMs));
	CHECK(SessionSrv(k.host.s).bridge_connected(mapserver::bridge_peer(kMs)));
	CHECK(k.host.s.peers().empty());
	CHECK(k.host.s.players().empty());
}

TEST(trunk_a_token_is_good_once)
{
	Trunk k(t::port(37202));
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node again("x", t::port(37202));
	again.cfg.hello_role = kHelloRoleMapServer;
	again.cfg.hello_token = token_of(7);
	std::string err;
	REQUIRE(again.connect(t::port(37202), &err));
	CHECK(k.pump(5000, [&] {
		again.s.update(t::now_ms());
		return again.rejected;
	}));
	CHECK_EQ(SessionSrv(k.host.s).bridges().size(), size_t(1));
}

TEST(trunk_a_revoked_token_is_no_token)
{
	Trunk k(t::port(37203));
	REQUIRE(k.start());
	SessionSrv(k.host.s).issue_bridge(kMs, token_of(7));
	SessionSrv(k.host.s).revoke_bridge(kMs);
	Node late("x", t::port(37203));
	late.cfg.hello_role = kHelloRoleMapServer;
	late.cfg.hello_token = token_of(7);
	std::string err;
	REQUIRE(late.connect(t::port(37203), &err));
	CHECK(k.pump(5000, [&] {
		late.s.update(t::now_ms());
		return late.rejected;
	}));
	CHECK(SessionSrv(k.host.s).bridges().empty());
}

TEST(trunk_a_map_server_takes_no_player_slot)
{
	Trunk k(t::port(37204));
	k.host.cfg.max_players = 2;
	REQUIRE(k.start());
	k.add_client("Al");
	Node late("Bo", t::port(37204)); // the session is full ...
	std::string err;
	REQUIRE(late.connect(t::port(37204), &err));
	CHECK(k.pump(5000, [&] {
		late.s.update(t::now_ms());
		return late.rejected;
	}));
	CHECK(late.reject.reason == RejectReason::SessionFull);
	REQUIRE(k.connect_server()); // ... and a map server still comes
	CHECK_EQ(k.host.s.peers().size(), size_t(1));
}

TEST(trunk_a_lost_bridge_is_told_and_a_new_process_takes_its_number)
{
	Trunk k(t::port(37205));
	std::vector<PeerId> came, went;
	SessionSrv(k.host.s).on_bridge_joined([&](PeerId id) { came.push_back(id); });
	SessionSrv(k.host.s).on_bridge_left([&](PeerId id, const std::string&) { went.push_back(id); });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	CHECK(k.pump(5000, [&] { return came.size() == 1; }));
	k.map.shutdown("over");
	k.world.s.shutdown("over");
	CHECK(k.pump(5000, [&] { return went.size() == 1; }));
	CHECK(SessionSrv(k.host.s).bridges().empty());
	SessionSrv(k.host.s).issue_bridge(kMs, token_of(40));
	Node next("ms", t::port(37205));
	next.cfg.hello_role = kHelloRoleMapServer;
	next.cfg.hello_token = token_of(40);
	std::string err;
	REQUIRE(next.connect(t::port(37205), &err));
	CHECK(k.pump(5000, [&] {
		next.s.update(t::now_ms());
		return next.s.is_active();
	}));
	CHECK_EQ(next.s.self(), mapserver::bridge_peer(kMs));
}

TEST(trunk_seven_map_servers_stand_beside_a_full_session)
{
	Trunk k(t::port(37209));
	REQUIRE(k.start());

	for (int i = 0; i < 7; ++i)
		k.add_client("P" + std::to_string(i));
	std::vector<std::unique_ptr<Node>> servers;
	std::string err;
	for (uint32_t n = 1; n <= mapserver::kMaxBridges; ++n)
	{
		SessionSrv(k.host.s).issue_bridge(n, token_of(uint8_t(20 + n)));
		servers.push_back(std::make_unique<Node>("ms", uint16_t(t::port(37209))));
		servers.back()->cfg.hello_role = kHelloRoleMapServer;
		servers.back()->cfg.hello_token = token_of(uint8_t(20 + n));
		REQUIRE(servers.back()->connect(t::port(37209), &err));
	}
	CHECK(k.pump(10000, [&] {
		for (auto& s : servers)
			s->s.update(t::now_ms());
		return SessionSrv(k.host.s).bridges().size() == mapserver::kMaxBridges;
	}));
	CHECK_EQ(k.host.s.peers().size(), size_t(7));
	for (uint32_t n = 1; n <= mapserver::kMaxBridges; ++n)
		CHECK_EQ(servers[n - 1]->s.self(), mapserver::bridge_peer(n));
}

// ---------------------------------------------------------------- TrunkOnly

TEST(trunk_only_messages_pass_from_a_bridge_and_kick_anybody_else)
{
	Trunk k(t::port(37206));
	std::vector<PeerId> at_host;
	k.host.s.on(Msg::LevelXferUp, [&at_host](PeerId from, Reader&) { at_host.push_back(from); });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& player = k.add_client("Al");

	k.world.s.send(kHostPeer, Lane::Reliable, Msg::LevelXferUp, Writer());
	CHECK(k.pump(5000, [&] { return !at_host.empty(); }));
	REQUIRE(at_host.size() == 1);
	CHECK_EQ(at_host[0], mapserver::bridge_peer(kMs));
	CHECK(!k.world.disconnected);

	player.s.send(kHostPeer, Lane::Reliable, Msg::LevelXferUp, Writer());
	CHECK(k.pump(5000, [&] { return player.disconnected || player.rejected; }));
	CHECK_EQ(at_host.size(), size_t(1));
}

TEST(trunk_a_tunnel_from_a_player_is_refused)
{
	Trunk k(t::port(37207));
	bool ran = false;
	REQUIRE(k.start());
	k.host.s.on(Msg::Tunnel, [&ran](PeerId, Reader&) { ran = true; });
	Node& player = k.add_client("Al");
	TunnelMsg m;
	m.peer = 1;
	m.packet = {uint8_t(uint16_t(Msg::PlayerState) & 0xff), uint8_t(uint16_t(Msg::PlayerState) >> 8)};
	Writer w;
	REQUIRE(m.write(w));
	player.s.send(kHostPeer, Lane::Reliable, Msg::Tunnel, w);
	CHECK(k.pump(5000, [&] { return player.disconnected || player.rejected; }));
	CHECK(!ran);
}

TEST(trunk_a_bridge_is_not_filtered_nor_limited)
{
	Trunk k(t::port(37208));
	uint32_t heard = 0;
	k.host.s.on(Msg::LevelHash, [&heard](PeerId, Reader&) { ++heard; });
	k.host.s.limit_rate(Msg::LevelHash, 1, 100000);
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	for (int i = 0; i < 20; ++i)
		k.world.s.send(kHostPeer, Lane::Reliable, Msg::LevelHash, Writer());
	CHECK(k.pump(5000, [&] { return heard == 20; }));
}

TEST(trunk_a_bridge_knows_the_players_and_the_players_do_not_know_it)
{
	Trunk k(t::port(37219));
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	REQUIRE(k.pump(5000, [&] { return k.world.s.peer(a.s.self()) != nullptr; }));
	CHECK_EQ(k.world.s.peer(a.s.self())->nick, std::string("Al"));
	CHECK_EQ(a.s.peers().size(), size_t(1)); // the host, nobody else
}

// ---------------------------------------------------------------- the two sessions of a map server

TEST(virtual_a_players_map_message_runs_on_the_map_server_as_his)
{
	Trunk k(t::port(37210));
	std::vector<uint32_t> at_map;
	std::vector<PeerId> from_map;
	bool here = false;
	k.host.s.on(Msg::PlayerShot, [&here](PeerId, Reader&) { here = true; });
	k.map.on(Msg::PlayerShot, [&](PeerId from, Reader& r) {
		from_map.push_back(from);
		at_map.push_back(r.u32());
	});
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	SessionSrv(k.map).virtual_join(a.s.self(), "Al");
	k.pump_once();
	a.s.send(kHostPeer, Lane::Reliable, Msg::PlayerShot, payload(4711));
	REQUIRE(k.pump(5000, [&] { return !at_map.empty(); }));
	CHECK_EQ(at_map[0], 4711u);
	CHECK_EQ(from_map[0], a.s.self());
	CHECK(!here); // the world server does not act on the stream of another level
}

TEST(virtual_what_the_map_server_sends_reaches_the_player_from_the_host)
{
	Trunk k(t::port(37211));
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	std::vector<uint32_t> got;
	std::vector<PeerId> from;
	a.s.on(Msg::ReqResult, [&](PeerId f, Reader& r) {
		from.push_back(f);
		got.push_back(r.u32());
	});
	SessionSrv(k.map).virtual_join(a.s.self(), "Al");
	k.map.send(a.s.self(), Lane::Reliable, Msg::ReqResult, payload(99));
	REQUIRE(k.pump(5000, [&] { return !got.empty(); }));
	CHECK_EQ(got[0], 99u);
	CHECK_EQ(from[0], kHostPeer); // his session talks to the host, there is nothing else for it
	CHECK_EQ(k.last_bridge, mapserver::bridge_peer(kMs));
}

TEST(virtual_two_clients_on_one_level_see_each_other_through_the_map_server)
{
	Trunk k(t::port(37212));
	k.map.on(Msg::PlayerShot, [&k](PeerId from, Reader& r) {
		Writer w;
		w.u32(r.u32());
		k.map.broadcast(Lane::Reliable, Msg::PlayerShot, w, from); // the host's code of a level: to the others
	});
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	Node& b = k.add_client("Bo");
	std::vector<uint32_t> at_a, at_b;
	a.s.on(Msg::PlayerShot, [&at_a](PeerId, Reader& r) { at_a.push_back(r.u32()); });
	b.s.on(Msg::PlayerShot, [&at_b](PeerId, Reader& r) { at_b.push_back(r.u32()); });
	SessionSrv(k.map).virtual_join(a.s.self(), "Al");
	SessionSrv(k.map).virtual_join(b.s.self(), "Bo");
	k.pump_once();
	CHECK_EQ(k.map.peers().size(), size_t(2));
	a.s.send(kHostPeer, Lane::Reliable, Msg::PlayerShot, payload(5));
	REQUIRE(k.pump(5000, [&] { return !at_b.empty(); }));
	CHECK_EQ(at_b[0], 5u);
	CHECK(at_a.empty());
}

TEST(virtual_an_unreliable_stream_keeps_its_lane)
{
	Trunk k(t::port(37213));
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	std::vector<uint32_t> got;
	a.s.on(Msg::EntitySnapshot, [&got](PeerId, Reader& r) { got.push_back(r.u32()); });
	SessionSrv(k.map).virtual_join(a.s.self(), "Al");
	k.map.send(a.s.self(), Lane::Unreliable, Msg::EntitySnapshot, payload(1));
	CHECK(k.pump(5000, [&] { return !got.empty(); }));
	CHECK_EQ(k.world.s.stats(uint16_t(Msg::Tunnel)).sent_count, 1ull);
}

TEST(virtual_it_asks_the_world_server_as_a_client)
{
	Trunk k(t::port(37214));
	std::vector<PeerId> from;
	k.host.s.on(Msg::ReqMoney, [&from](PeerId f, Reader&) { from.push_back(f); });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	k.map.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, Writer());
	REQUIRE(k.pump(5000, [&] { return !from.empty(); }));
	CHECK_EQ(from[0], mapserver::bridge_peer(kMs));
}

TEST(virtual_a_player_who_left_is_nobody_here)
{
	Trunk k(t::port(37215));
	uint32_t ran = 0;
	k.map.on(Msg::PlayerShot, [&ran](PeerId, Reader&) { ++ran; });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	std::vector<PeerId> joined, left;
	k.map.on_peer_joined = [&](const PeerInfo& p) { joined.push_back(p.id); };
	k.map.on_peer_left = [&](PeerId id, const std::string&) { left.push_back(id); };
	SessionSrv(k.map).virtual_join(3, "Cy");
	k.pump_once();
	REQUIRE(joined.size() == 1);
	const uint8_t packet[6] = {uint8_t(uint16_t(Msg::PlayerShot) & 0xff), uint8_t(uint16_t(Msg::PlayerShot) >> 8), 1, 0, 0, 0};
	SessionSrv(k.map).virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	k.pump_once();
	CHECK_EQ(ran, 1u);
	SessionSrv(k.map).virtual_leave(3, "he moved");
	k.pump_once();
	REQUIRE(left.size() == 1);
	CHECK(k.map.peers().empty());
	SessionSrv(k.map).virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	k.pump_once();
	CHECK_EQ(ran, 1u);
}

TEST(virtual_a_message_only_the_host_sends_is_ignored_and_nobody_is_kicked)
{
	Trunk k(t::port(37216));
	uint32_t ran = 0;
	k.map.on(Msg::ReqResult, [&ran](PeerId, Reader&) { ++ran; });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	SessionSrv(k.map).virtual_join(3, "Cy");
	k.pump_once();
	const uint8_t packet[2] = {uint8_t(uint16_t(Msg::SessionReset) & 0xff), uint8_t(uint16_t(Msg::SessionReset) >> 8)};
	SessionSrv(k.map).virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	k.pump_once();
	CHECK_EQ(k.map.peers().size(), size_t(1));
	CHECK(k.world.s.is_active());
}

TEST(virtual_the_epoch_is_the_worlds)
{
	Trunk k(t::port(37217));
	k.host.s.set_world_epoch(4);
	REQUIRE(k.start());
	k.host.s.set_world_epoch(4);
	REQUIRE(k.connect_server());
	CHECK_EQ(k.world.s.world_epoch(), 4u);
	CHECK_EQ(k.map.world_epoch(), 4u);
	uint32_t ran = 0;
	k.map.on(Msg::PlayerShot, [&ran](PeerId, Reader&) { ++ran; });
	SessionSrv(k.map).virtual_join(3, "Cy");
	k.host.s.set_world_epoch(5);
	k.map.set_world_epoch(5); // the game does it at the SessionReset: both of its sessions move
	CHECK_EQ(k.world.s.world_epoch(), 5u);
	k.pump_once();
	const uint8_t packet[2] = {uint8_t(uint16_t(Msg::PlayerShot) & 0xff), uint8_t(uint16_t(Msg::PlayerShot) >> 8)};
	SessionSrv(k.map).virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	k.pump_once();
	CHECK_EQ(ran, 1u); // a virtual peer is in the world of its map server
}

TEST(virtual_a_broadcast_of_the_world_reaches_the_bridge_and_a_stream_does_not)
{
	Trunk k(t::port(37218));
	uint32_t world = 0, stream = 0;
	k.world.s.on(Msg::TimeSync, [&world](PeerId, Reader&) { ++world; });
	k.world.s.on(Msg::EntitySnapshot, [&stream](PeerId, Reader&) { ++stream; });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	uint32_t at_a = 0;
	a.s.on(Msg::EntitySnapshot, [&at_a](PeerId, Reader&) { ++at_a; });
	k.host.s.broadcast(Lane::Reliable, Msg::EntitySnapshot, Writer());
	k.host.s.broadcast(Lane::Reliable, Msg::TimeSync, Writer());
	CHECK(k.pump(5000, [&] { return world == 1 && at_a == 1; }));
	CHECK_EQ(stream, 0u);
}

