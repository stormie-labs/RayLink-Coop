// Anomaly Coop unit tests: the F5 vehicle messages in the protocol tables (F5-PROTO; build 57, protocol 33; docs/VEHICLES.md,
// layouts xrCoop/coop_vehicle_rules.h). Their wire ids (a range of their own, no id of another message reused), the names for
// logs and stats, who may send each one (msg_sender, checked by the Session on receipt), their scope and route, their row in
// the world gate.
//
// They concern a body on a level (Scope::Map). The same tables give both modes (Core):
//   Co-op   the host's process leads the only map: everything is handled there (route_incoming with split off), a real
//           session over the loopback below;
//   Server  the world server leads no map: a player's VehicleReq / VehicleInput go through the tunnel to the map server of his
//           level and are never handled on the world server; the world server's own broadcast never carries the decider's two
//           to a map server or to a player of another level.
#include "test_util.h"
#include "coop_protocol.h"
#include "support/scope_listed.h"
#include "srv/coop_mapserver_rules.h"
#include "coop_world_gate.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace coop;

namespace
{
const char* f5_sender_name(MsgSender s)
{
	switch (s)
	{
	case MsgSender::HostOnly: return "host only";
	case MsgSender::ClientOnly: return "client only";
	case MsgSender::Either: return "either";
	case MsgSender::TrunkOnly: return "trunk only";
	}
	return "?";
}

const char* f5_need_name(wgate::Need n)
{
	switch (n)
	{
	case wgate::Need::Unclassified: return "unclassified";
	case wgate::Need::Free: return "free";
	case wgate::Need::Drop: return "drop";
	case wgate::Need::Hold: return "hold";
	}
	return "?";
}

struct F5Msg
{
	Msg type;
	uint16_t wire;
	const char* name;
	MsgSender sender;
	wgate::Need need;
};

// F5 range 0x01F0..0x01FF (F3a ends at 0x01DF; 0x01E0.. stays free, test_protocol_f3a.cpp).
const F5Msg kF5[] = {
	// a player asks: enter / exit / switch seat (Reliable); a request that changes the world: it waits in the decider's hole
	{Msg::VehicleReq, 0x01F0, "VehicleReq", MsgSender::ClientOnly, wgate::Need::Hold},
	// the decider's answer to the players of the level: granted / released / refused (Reliable); an ordered delta
	{Msg::VehicleSeat, 0x01F1, "VehicleSeat", MsgSender::HostOnly, wgate::Need::Hold},
	// the driver's keys and aim (Unreliable, sequenced): the next one replaces it
	{Msg::VehicleInput, 0x01F2, "VehicleInput", MsgSender::ClientOnly, wgate::Need::Drop},
	// the car's engine, lights, gear, damage to every copy: the decider sends it again
	{Msg::VehicleState, 0x01F3, "VehicleState", MsgSender::HostOnly, wgate::Need::Drop},
};

bool unnamed(uint32_t v) { return std::strncmp(msg_name(static_cast<Msg>(v)), "Msg_0x", 6) == 0; }

std::string hex(uint32_t v)
{
	char b[16];
	std::snprintf(b, sizeof(b), "0x%04X", v);
	return b;
}

bool kicked_for(const t::Node& n, const std::string& why)
{
	return n.disconnected && n.disc_reason.find(reject_reason_name(RejectReason::Malformed)) != std::string::npos &&
		n.disc_reason.find(why) != std::string::npos;
}
} // namespace

// ---------------------------------------------------------------------------------------------- ids, names, senders

TEST(protocol_f5_values)
{
	// The ids are the wire format: append only, never renumber.
	for (const F5Msg& m : kF5)
		CHECK_EQ(std::string(m.name) + " = " + hex(static_cast<uint16_t>(m.type)), std::string(m.name) + " = " + hex(m.wire));
}

TEST(protocol_f5_names)
{
	for (const F5Msg& m : kF5)
		CHECK_EQ(std::string(msg_name(m.type)), std::string(m.name));
}

TEST(protocol_f5_ids_collide_with_no_other_message)
{
	// msg_name is one switch over every Msg: a value that two messages share does not build (a doubled case), and a value a
	// message took from another shows here as the other's name. Every value of the protocol: each F5 name once, at its id.
	for (const F5Msg& m : kF5)
	{
		std::vector<uint32_t> at;
		for (uint32_t v = 0; v <= 0xFFFFu; ++v)
			if (std::strcmp(msg_name(static_cast<Msg>(v)), m.name) == 0)
				at.push_back(v);
		CHECK_EQ(std::string(m.name) + " at " + std::to_string(at.size()) + " value(s), first " + (at.empty() ? "-" : hex(at[0])),
		    std::string(m.name) + " at 1 value(s), first " + hex(m.wire));
	}
	// the four are different values, all in the F5 range, and the rest of the range is nobody's yet
	for (size_t i = 0; i < sizeof(kF5) / sizeof(kF5[0]); ++i)
	{
		CHECK(kF5[i].wire >= 0x01F0 && kF5[i].wire <= 0x01FF);
		for (size_t j = i + 1; j < sizeof(kF5) / sizeof(kF5[0]); ++j)
			CHECK(kF5[i].wire != kF5[j].wire);
	}
	for (uint32_t v = 0x01F4; v <= 0x01FF; ++v)
		CHECK_EQ(hex(v) + (unnamed(v) ? " is free" : " is taken"), hex(v) + " is free");
	// the neighbours keep their own: F3a ends at LoadReady, 0x01E0..0x01EF stays free
	CHECK_EQ(std::string(msg_name(uint16_t(0x01DF))), std::string("LoadReady"));
	CHECK(unnamed(0x01E2)); // 0x01E0/0x01E1: R32 LevelJournal / LevelJournalAck
	CHECK(unnamed(0x01EF));
}

TEST(protocol_f5_senders)
{
	// A player's two (ClientOnly: a host or a map server's level session takes them; a client logs and ignores one from the
	// host), the decider's two (HostOnly: a client that sends one is kicked as malformed before any handler).
	for (const F5Msg& m : kF5)
		CHECK_EQ(std::string(m.name) + ": " + f5_sender_name(msg_sender(m.type)), std::string(m.name) + ": " + f5_sender_name(m.sender));
}

// ---------------------------------------------------------------------------------------------- scope and route

TEST(protocol_f5_scope_is_the_map_of_the_sender)
{
	for (const F5Msg& m : kF5)
	{
		CHECK_EQ(std::string(m.name) + (scope_listed(m.type) ? " has a scope row" : " has no scope row"),
		    std::string(m.name) + " has a scope row");
		CHECK_EQ(std::string(m.name) + " is " + scope_name(scope_of(m.type)), std::string(m.name) + " is Map");
		CHECK(route(scope_of(m.type), false) == Route::TunnelToServer);
		// a seat on a level means nothing on another one: not every level's (a spawn is), not kept by the world server for the
		// save and the HUD (vitals are), not a world message that also goes to the authority (wounded is)
		CHECK_EQ(std::string(m.name) + (reaches_every_level(m.type) ? " reaches every level" : " stays on its level"),
		    std::string(m.name) + " stays on its level");
		CHECK_EQ(std::string(m.name) + (kept_from_every_level(m.type) ? " is kept by the world server" : " is not kept"),
		    std::string(m.name) + " is not kept");
		CHECK(!also_to_level_authority(m.type));
	}
}

TEST(protocol_f5_server_the_world_server_tunnels_and_never_handles)
{
	// Server: a player on the level of a map server (split on, not on a level the world server leads; it leads none). His
	// request and his keys go through the tunnel to the map server of his level; the world server's handler never runs.
	for (const F5Msg& m : kF5)
	{
		if (m.sender != MsgSender::ClientOnly)
			continue;
		const mapserver::Incoming go = mapserver::route_incoming(m.type, true, false, true);
		CHECK_EQ(std::string(m.name) + (go.here ? " is handled here" : " is not handled here") + (go.tunnel ? ", tunneled" : ", not tunneled"),
		    std::string(m.name) + " is not handled here, tunneled");
		// his map server is not connected (it is starting): nobody acts on it, as on any stream of a map; the client times out
		const mapserver::Incoming none = mapserver::route_incoming(m.type, true, false, false);
		CHECK(!none.here && !none.tunnel);
	}
	for (const F5Msg& m : kF5)
	{
		// the decider's two come down the tunnel from the map server to the players of its level; a broadcast of the world
		// server never carries any of the four to a map server's bridge, and a map server's ghost never sends one up as its own
		CHECK(!mapserver::bridge_takes(m.type));
		CHECK(!mapserver::map_server_sends(m.type));
		// the world server's filters for a player on another level (split on, not the same level)
		CHECK(!level_passes(m.type, true, false));
		CHECK(!kept_from_every_level(m.type));
	}
	CHECK(msg_sender(Msg::Tunnel) == MsgSender::Either); // the carrier both ways
}

TEST(protocol_f5_coop_the_host_handles_all_four)
{
	// Co-op: one map, the host's process leads it: no split, nothing tunneled, everything handled here and sent to everybody.
	for (const F5Msg& m : kF5)
	{
		const mapserver::Incoming go = mapserver::route_incoming(m.type, false, false, false);
		CHECK_EQ(std::string(m.name) + (go.here ? " is handled here" : " is not handled here") + (go.tunnel ? ", tunneled" : ", not tunneled"),
		    std::string(m.name) + " is handled here, not tunneled");
		CHECK(level_passes(m.type, false, false));
		// a player on the level the receiving process leads is handled there too (the rule, whatever the mode)
		const mapserver::Incoming same = mapserver::route_incoming(m.type, true, true, true);
		CHECK(same.here && !same.tunnel);
	}
}

TEST(protocol_f5_world_gate_rows)
{
	// A request and the decider's ordered answer wait in the decider's hole (dropped on a client that is not in the world: the
	// decider sends the seats again to a player who comes to the map); the keys and the state are repeated by their sender.
	for (const F5Msg& m : kF5)
	{
		CHECK_EQ(std::string(m.name) + ": " + f5_need_name(wgate::need_of(m.type)), std::string(m.name) + ": " + f5_need_name(m.need));
		CHECK(wgate::decide(wgate::need_of(m.type), wgate::World::Up) == wgate::Act::Run);
		CHECK(wgate::decide(wgate::need_of(m.type), wgate::World::Absent) == wgate::Act::Drop);
	}
}

// ---------------------------------------------------------------------------------------------- a real session (co-op)

TEST(protocol_f5_session_enforces_the_directions)
{
	// The host takes a player's VehicleReq / VehicleInput and he takes its VehicleSeat / VehicleState; a client that forges the
	// decider's VehicleSeat is kicked before any handler; a client ignores (and logs) a VehicleReq that comes from the host.
	t::Node host("Boss", t::port(37590)), a("Al", t::port(37590)), b("Bo", t::port(37590));
	std::vector<uint16_t> at_host, at_b;
	for (const F5Msg& m : kF5)
	{
		const Msg type = m.type;
		host.s.on(type, [&at_host, type](PeerId, Reader&) { at_host.push_back(uint16_t(type)); });
		b.s.on(type, [&at_b, type](PeerId, Reader&) { at_b.push_back(uint16_t(type)); });
	}
	std::string err;
	host.cfg.mode = SessionMode::Coop;
	REQUIRE(host.host(&err));
	for (t::Node* c : {&a, &b})
	{
		REQUIRE(c->connect(t::port(37590), &err));
		REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return c->s.is_active(); }));
	}
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return host.s.peers().size() == 2 && b.s.peers().size() == 2; }));
	const PeerId bo = b.s.self();

	a.s.send(kHostPeer, Lane::Reliable, Msg::VehicleSeat, Writer()); // a client claims a seat as if he decided it
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return a.disconnected; }));
	CHECK(at_host.empty());
	CHECK(kicked_for(a, "unexpected VehicleSeat"));

	host.s.send(bo, Lane::Reliable, Msg::VehicleReq, Writer()); // only players ask: ignored by the client
	host.s.send(bo, Lane::Reliable, Msg::VehicleSeat, Writer()); // the right way, after it (reliable lane: in order)
	host.s.send(bo, Lane::Reliable, Msg::VehicleState, Writer());
	b.s.send(kHostPeer, Lane::Reliable, Msg::VehicleReq, Writer());
	b.s.send(kHostPeer, Lane::Unreliable, Msg::VehicleInput, Writer());
	REQUIRE(t::pump_until({&host.s, &b.s}, 3000, [&] { return at_b.size() == 2 && at_host.size() == 2; }));
	t::pump_for({&host.s, &b.s}, 100);
	CHECK(at_b == (std::vector<uint16_t>{uint16_t(Msg::VehicleSeat), uint16_t(Msg::VehicleState)}));
	std::sort(at_host.begin(), at_host.end()); // two lanes: the unreliable one keeps no order with the reliable one
	CHECK(at_host == (std::vector<uint16_t>{uint16_t(Msg::VehicleReq), uint16_t(Msg::VehicleInput)}));
	CHECK(b.logged("unexpected VehicleReq"));
	CHECK(b.s.is_active() && !b.disconnected);
}
