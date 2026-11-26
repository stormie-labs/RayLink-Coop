#include "test_util.h"

#include "srv/coop_mapserver_rules.h"
#include "srv/coop_session_srv.h"

// The game header's other declarations use X-Ray types supplied by its PCH.
using u8 = uint8_t;
using u16 = uint16_t;
using s64 = int64_t;
using LPCSTR = const char*;
using xr_string = std::string;
#include "../engine/src/xrGame/coop/coop_script.h"

namespace
{
using namespace coop;
using t::Node;
using script::WorldEventReservations;

constexpr char kReserved[] = "test.relay.reserved";
constexpr char kOrdinary[] = "test.relay.ordinary";
constexpr int32_t kAll = -1;

void send_event(Session& session, PeerId to, PeerId origin, int32_t target, const std::string& name,
    const std::string& payload)
{
	Writer w;
	w.u32(origin);
	w.i32(target);
	w.str(name);
	w.str(payload);
	session.send(to, Lane::Reliable, Msg::ScriptEvent, w);
}

struct Event
{
	PeerId from;
	std::string name, payload;
};

struct Relay
{
	WorldEventReservations reserved;
	std::vector<Event> inbox;
	unsigned dropped = 0;

	// Real Session ingress and egress around the admission policy shared with coop_script.cpp.
	void bind(Session& session, PeerId listener)
	{
		session.on(Msg::ScriptEvent, [&, listener](PeerId from, Reader& r) {
			(void)r.u32(); // the sender's identity comes from the session
			const int32_t target = r.i32();
			const auto name = r.str();
			const auto payload = r.str();
			REQUIRE(r.ok());
			const bool link = from != kHostPeer && session.joined(from) && !session.peer(from);
			if (reserved.blocks_relay(link, name))
			{
				++dropped;
				return;
			}
			if (target == kAll || target == int32_t(listener))
				send_event(session, listener, link ? kHostPeer : from, target, name, payload);
			if (target == kAll || target == int32_t(kHostPeer))
				inbox.push_back({from, name, payload});
		});
	}
};

void receive_at(Node& node, std::vector<Event>& inbox)
{
	node.s.on(Msg::ScriptEvent, [&](PeerId from, Reader& r) {
		REQUIRE(from == kHostPeer);
		const PeerId origin = r.u32();
		(void)r.i32();
		auto name = r.str();
		auto payload = r.str();
		REQUIRE(r.ok());
		inbox.push_back({origin, std::move(name), std::move(payload)});
	});
}
} // namespace

TEST(world_events_server_relay_preserves_sender_rules)
{
	const uint16_t port = t::port(38951);
	Node world("World", port), map("Map", port), sender("Sender", port), listener("Listener", port);
	world.cfg.host_plays = false;
	world.cfg.mode = SessionMode::Server;
	REQUIRE(world.host());
	map.cfg.hello_role = kHelloRoleMapServer;
	map.cfg.hello_token.fill(42);
	constexpr uint32_t map_index = 1;
	srv::SessionSrv(world.s).issue_bridge(map_index, map.cfg.hello_token);
	REQUIRE(map.connect(port));
	REQUIRE(sender.connect(port));
	REQUIRE(listener.connect(port));
	const std::initializer_list<Session*> sessions = {&world.s, &map.s, &sender.s, &listener.s};
	REQUIRE(t::pump_until(sessions, 5000, [&] {
		return map.welcomed && sender.welcomed && listener.welcomed;
	}));
	const PeerId peer = listener.s.self();
	Relay relay;
	REQUIRE(relay.reserved.reserve(kReserved, sizeof(kReserved) - 1));
	relay.bind(world.s, peer);
	std::vector<Event> received;
	receive_at(listener, received);

	// The reliable ordinary broadcast is a barrier for all the previous sends from the map.
	for (const int32_t target : {kAll, int32_t(peer), int32_t(kHostPeer)})
		send_event(map.s, kHostPeer, map.s.self(), target, kReserved, "map");
	send_event(map.s, kHostPeer, map.s.self(), kAll, kOrdinary, "barrier");
	REQUIRE(t::pump_until(sessions, 5000, [&] {
		return !received.empty() && received.back().payload == "barrier";
	}));
	CHECK_EQ(relay.dropped, 3u);
	REQUIRE(received.size() == 1);
	CHECK_EQ(received.front().from, kHostPeer);
	CHECK_EQ(received.front().name, kOrdinary);
	REQUIRE(relay.inbox.size() == 1);
	CHECK_EQ(relay.inbox.front().from, mapserver::bridge_peer(map_index));
	CHECK_EQ(relay.inbox.front().name, kOrdinary);

	send_event(sender.s, kHostPeer, sender.s.self(), kAll, kReserved, "player");
	REQUIRE(t::pump_until(sessions, 5000, [&] { return received.size() == 2; }));
	CHECK_EQ(received.back().from, sender.s.self());
	CHECK_EQ(received.back().name, kReserved);
	REQUIRE(relay.inbox.size() == 2);
	CHECK_EQ(relay.inbox.back().from, sender.s.self());

	send_event(world.s, peer, kHostPeer, int32_t(peer), kReserved, "world");
	REQUIRE(t::pump_until(sessions, 5000, [&] { return received.size() == 3; }));
	CHECK_EQ(received.back().from, kHostPeer);
	CHECK_EQ(received.back().name, kReserved);
	CHECK_EQ(received.back().payload, "world");
}

TEST(world_events_coop_relay_preserves_player_and_host)
{
	const uint16_t port = t::port(38952);
	Node host("Host", port), sender("Sender", port), listener("Listener", port);
	host.cfg.mode = SessionMode::Coop;
	REQUIRE(host.host());
	REQUIRE(sender.connect(port));
	REQUIRE(listener.connect(port));
	const std::initializer_list<Session*> sessions = {&host.s, &sender.s, &listener.s};
	REQUIRE(t::pump_until(sessions, 5000, [&] { return sender.welcomed && listener.welcomed; }));
	const PeerId peer = listener.s.self();
	Relay relay;
	REQUIRE(relay.reserved.reserve(kReserved, sizeof(kReserved) - 1));
	relay.bind(host.s, peer);
	std::vector<Event> received;
	receive_at(listener, received);

	send_event(sender.s, kHostPeer, sender.s.self(), kAll, kReserved, "player");
	REQUIRE(t::pump_until(sessions, 5000, [&] { return received.size() == 1; }));
	CHECK_EQ(received.back().from, sender.s.self());
	CHECK_EQ(received.back().payload, "player");
	REQUIRE(relay.inbox.size() == 1);
	CHECK_EQ(relay.inbox.back().from, sender.s.self());
	send_event(host.s, peer, kHostPeer, int32_t(peer), kReserved, "host");
	REQUIRE(t::pump_until(sessions, 5000, [&] { return received.size() == 2; }));
	CHECK_EQ(received.back().from, kHostPeer);
	CHECK_EQ(received.back().payload, "host");
	CHECK_EQ(relay.dropped, 0u);
}

TEST(world_events_reservation_bounds_and_reset)
{
	WorldEventReservations set;
	const std::string longest(64, 'X'), too_long(65, 'X');
	CHECK(!set.reserve(nullptr, 0));
	CHECK(!set.reserve("", 0));
	CHECK(!set.reserve("has space", 9));
	CHECK(!set.reserve("a\0b", 3));
	CHECK(!set.reserve("\x7f", 1));
	CHECK(!set.reserve("\xff", 1));
	CHECK(!set.reserve(too_long.data(), too_long.size()));
	REQUIRE(set.reserve(longest.data(), longest.size()));
	for (unsigned i = 1; i < 64; ++i)
	{
		const std::string name = "event_" + std::to_string(i);
		REQUIRE(set.reserve(name.data(), name.size()));
	}
	CHECK(set.reserve(longest.data(), longest.size()));
	CHECK(!set.reserve("overflow", 8));
	CHECK(!set.blocks_relay(true, "overflow"));
	CHECK(!set.blocks_relay(false, longest));
	CHECK(set.blocks_relay(true, longest));
	set.clear();
	CHECK(!set.blocks_relay(true, longest));
	CHECK(set.reserve("overflow", 8));
}
