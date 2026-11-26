// Anomaly Coop unit tests, Server mode only: TZ 6.28 (P99, 2026-11-26), ONE process answers a player's repair (StateDumpRequest).
// Before: a player on a map server's level had his StateDumpRequest kept and answered by the world server (kept_from_every_level)
// and tunnelled to and answered by the map server of his level; each answer stamped a magazined weapon with its own process's
// instance (write_clone_initial -> clone_export), so he got two EntitySpawns with two stamps. Now (srv/coop_mapserver_rules.h
// answered_by_his_map_server, route_incoming; the caller xrGame/coop/srv/coop_trunk.cpp host_incoming) the map server of his level
// answers alone while its bridge is up, the world server alone while it is not; the world still answers what a map server asks it.
// The rule rows, then the trunk on real sessions over the loopback (the rig of test_trunk.cpp: the world server's in-filter does what
// coop_trunk.cpp host_incoming does), with the four entities of the task: an item on his map, an item in his inventory, an entity of
// another map, the world server's own. Co-op (split off) is not touched: its rows are checked unchanged at the end.
// What the rig proves: the ROUTING only - who gets a player's repair and how many answers come back. Its handlers are stubs (an
// answer is u16 id, u8 who, u32 stamp; a "stamp" is a number each stub keeps), not the engine's host_on_entity_request, write_spawn,
// write_clone_initial or the Lua stamps; the engine is not built into this exe. The world's stub of trunk_host_on_tunnel also takes
// the stamp of a map server's spawn (review D1) the way the engine's does (requests::adopt_spawn_stamp -> clone_take_stamp, the stamp
// alone: while the world has none or the same one); that Lua end runs in tests/lua/test_srv_rider_stamp.lua, the engine's code is
// checked by reading its source (the wiring cases at the end). The known gap of the one answerer (review D4) is pinned as a case of
// its own.
#include "test_util.h"

#include "coop_reconcile.h"
#include "srv/coop_mapserver_rules.h"
#include "srv/coop_session_srv.h"
#include "support/scope_listed.h"

#include <algorithm>
#include <chrono>
#include <fstream>
#include <functional>
#include <initializer_list>
#include <iterator>
#include <map>
#include <memory>
#include <regex>
#include <string>
#include <thread>
#include <vector>

using namespace coop;

namespace
{
using srv::SessionSrv;
using t::Node;
using levels::wire::TunnelMsg;

constexpr uint32_t kMs = 3; // the number of the map server of the rig

// ---------------------------------------------------------------- the four entities, as both processes' registries hold them

// Every machine keeps the same registry under the same ids (srv/coop_scope.h, reaches_every_level), so both processes have all four
// and each would answer for any of them (host_on_entity_request answers what its registry holds, it does not ask who writes it).
// `world` and `map` are the instance each process's Lua holds for the weapon and writes into its answer: clone_export keeps the first
// stamp a process gave or adopted (gamedata/scripts/coop_economy_mdata.script clone_export). The two of his map carry the split P99
// saw (each process stamped its own when both answered); the map server holds the other two as a client of its world, under the
// world's stamp. Who writes each (the map server of his level: the first two; another map server; the world) is the root's
// (srv/coop_writer_seats.h) and changes nothing here: the routing looks at the message only.
struct Entity
{
	uint16_t id;
	const char* what;
	uint32_t world;
	uint32_t map;
};

constexpr uint32_t kWorldStamp = 0x57000000u, kMapStamp = 0x4D000000u;

const Entity kEntities[] = {
	{20345, "an item on his map (a weapon in a corpse)", kWorldStamp | 1, kMapStamp | 1},
	{30329, "an item in his inventory", kWorldStamp | 2, kMapStamp | 2},
	{28593, "an entity of another map", kWorldStamp | 3, kWorldStamp | 3},
	{18942, "the world server's own entity", kWorldStamp | 4, kWorldStamp | 4},
};

const Entity* entity_of(uint16_t id)
{
	for (const Entity& e : kEntities)
		if (e.id == id)
			return &e;
	return nullptr;
}

// Review D4: an entity the world holds and the map server of his level does not (yet): one the world made a moment ago and has not
// relayed, or one the map server's copy lost. `map` is unused: the map server has no such entity.
constexpr Entity kOnlyAtWorld = {24680, "an entity the map server lacks", kWorldStamp | 5, 0};

// what the world server's copy holds: the four, and that one
const Entity* world_entity_of(uint16_t id) { return id == kOnlyAtWorld.id ? &kOnlyAtWorld : entity_of(id); }

constexpr uint8_t kByWorld = 'W', kByMap = 'M';

// An answer as a repair's EntitySpawn carries it here: the id, who wrote it, the weapon's stamp.
struct Answer
{
	uint16_t id = 0;
	uint8_t by = 0;
	uint32_t stamp = 0;
};

Writer spawn_of(uint16_t id, uint8_t by, uint32_t stamp)
{
	Writer w(8);
	w.u16(id);
	w.u8(by);
	w.u32(stamp);
	return w;
}

bool read_answer(Reader& r, Answer& out)
{
	out.id = r.u16();
	out.by = r.u8();
	out.stamp = r.u32();
	return r.ok();
}

Writer repair_of(uint16_t id, uint8_t what)
{
	Writer w(4);
	w.u16(id); // StateDumpRequest: u16 id[, u8 what] (coop_protocol.h)
	w.u8(what);
	return w;
}

mapserver::Token token_of(uint8_t first)
{
	mapserver::Token out{};
	for (size_t i = 0; i < out.size(); ++i)
		out[i] = uint8_t(first + 3 * i);
	return out;
}

// ---------------------------------------------------------------- the rig: the world server, one map server, one player

struct Rig
{
	explicit Rig(uint16_t port) : host("World", port), world("ms", port), port_(port)
	{
		// coop_trunk.cpp trunk_host_on_tunnel: what the map server sends a player of its level comes up and goes on to him; the world's
		// copy takes the stamp of a map server's spawn first (review D1, world_takes_spawn_stamp), before the spawn goes on
		host.s.on(Msg::Tunnel, [this](PeerId, Reader& r) {
			TunnelMsg m;
			if (!m.read(r))
				return;
			if (m.type() == Msg::EntitySpawn && world_takes_spawn_stamps)
			{
				Reader spawn(m.packet.data() + 2, m.packet.size() - 2);
				Answer a;
				if (read_answer(spawn, a))
					world_takes(a.id, a.stamp);
			}
			Writer w(m.packet.size());
			w.bytes(m.packet.data() + 2, m.packet.size() - 2);
			host.s.send(m.peer, mapserver::tunnel_lane(m.flags), m.type(), w);
		});
		// coop_trunk.cpp trunk_server_on_tunnel
		world.s.on(Msg::Tunnel, [this](PeerId, Reader& r) {
			TunnelMsg m;
			if (m.read(r))
				SessionSrv(map).virtual_receive(m.peer, mapserver::tunnel_lane(m.flags), m.packet.data(), m.packet.size());
		});
		// the world server's handler (coop_entities.cpp install_server -> coop_roster.cpp host_on_entity_request): answers whoever asks, from its copy
		// (which also holds an entity its map server lacks: review D4)
		host.s.on(Msg::StateDumpRequest, [this](PeerId from, Reader& r) {
			const uint16_t id = r.u16();
			const Entity* e = world_entity_of(id);
			if (from == mapserver::bridge_peer(kMs))
				++world_answered_its_map_server;
			else
				++world_answered_a_player;
			if (e)
				host.s.send(from, Lane::Reliable, Msg::EntitySpawn, spawn_of(id, kByWorld, e->world));
		});
		// the map server's handler, the same code in its process (leads_level): its answer goes to the virtual peer, up the trunk
		map.on(Msg::StateDumpRequest, [this](PeerId from, Reader& r) {
			const uint16_t id = r.u16();
			const Entity* e = entity_of(id);
			++map_answered;
			if (e)
				map.send(from, Lane::Reliable, Msg::EntitySpawn, spawn_of(id, kByMap, e->map));
		});
		// what the world answers the map server's own ask (R32 W5, map_server_asks_the_world)
		world.s.on(Msg::EntitySpawn, [this](PeerId, Reader& r) {
			Answer a;
			if (read_answer(r, a))
				at_map_server.push_back(a);
		});
		// his data the world keeps for the save goes both ways (kept_from_every_level): it is no repair
		host.s.on(Msg::PlayerVitals, [this](PeerId, Reader&) { ++vitals_at_world; });
		map.on(Msg::PlayerVitals, [this](PeerId, Reader&) { ++vitals_at_map; });
		// review D1: his item rider (jam, camo) goes to the world's Lua in a ScriptEvent (Scope::World, the world alone). The stub's
		// rider is u16 id, u32 the stamp his copy holds; the world takes it only under the stamp its copy holds, an unstamped copy's
		// instance being the weapon's name (0 here): coop_economy_mdata.script item_instance, the strict check of the rider lane
		host.s.on(Msg::ScriptEvent, [this](PeerId, Reader& r) {
			const uint16_t id = r.u16();
			const uint32_t stamp = r.u32();
			const auto it = world_stamp.find(id);
			if (r.ok() && (it == world_stamp.end() ? 0u : it->second) == stamp)
				++riders_taken;
			else
				++riders_refused;
		});
		map.on(Msg::ScriptEvent, [this](PeerId, Reader&) { ++riders_at_map; });
		self() = this;
		host.s.set_in_filter(&Rig::in_filter);
	}
	~Rig() { self() = nullptr; }

	static Rig*& self()
	{
		static Rig* rig = nullptr;
		return rig;
	}

	// coop_trunk.cpp host_incoming: a bridge's message is the world server's own business; a player's goes by route_incoming
	static bool in_filter(PeerId from, Msg type, Lane lane, const uint8_t* packet, size_t size)
	{
		return self()->incoming(from, type, lane, packet, size);
	}
	bool incoming(PeerId from, Msg type, Lane lane, const uint8_t* packet, size_t size)
	{
		if (mapserver::is_bridge(from))
			return true;
		const PeerId bridge = mapserver::bridge_peer(kMs);
		// every player of the rig stands on the level of the map server (the world server stands on none of LevelMap)
		const mapserver::Incoming go = mapserver::route_incoming(type, true, false, SessionSrv(host.s).bridge_connected(bridge));
		if (go.tunnel)
		{
			TunnelMsg m;
			m.peer = from;
			m.flags = mapserver::tunnel_lane_flags(lane);
			m.packet.assign(packet, packet + size);
			Writer w(size + 8);
			if (m.write(w))
				host.s.send(bridge, lane, Msg::Tunnel, w);
		}
		return go.here;
	}

	void pump_once()
	{
		const uint64_t now = t::now_ms();
		host.s.update(now);
		world.s.update(now);
		map.update(now);
		if (player)
			player->s.update(now);
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
	void pump_for(uint32_t ms)
	{
		const uint64_t start = t::now_ms();
		pump(ms + 1000, [&] { return t::now_ms() - start >= ms; });
	}

	bool start()
	{
		std::string err;
		host.cfg.mode = SessionMode::Coop;
		return host.host(&err);
	}
	bool connect_map_server()
	{
		SessionSrv(host.s).issue_bridge(kMs, token_of(11));
		world.cfg.hello_role = kHelloRoleMapServer;
		world.cfg.hello_token = token_of(11);
		world.cfg.mode = SessionMode::Server;
		std::string err;
		if (!world.connect(port_, &err))
			return false;
		if (!pump(5000, [this] { return world.s.is_active(); }))
			return false;
		return SessionSrv(map).host_virtual(world.cfg, world.s, &err);
	}
	Node& add_player(const std::string& nick)
	{
		player = std::make_unique<Node>(nick, port_);
		Node& c = *player;
		std::string err;
		REQUIRE(c.connect(port_, &err));
		REQUIRE(pump(5000, [&c] { return c.s.is_active(); }));
		c.s.on(Msg::EntitySpawn, [this](PeerId, Reader& r) {
			Answer a;
			if (read_answer(r, a))
				at_player[a.id].push_back(a);
		});
		return c;
	}

	// Each of the four asked once, `what` as the roster's repair or a handler's ask; true when every one has an answer, then a
	// while more so that a second answer, from wherever, has time to come.
	bool ask_all(uint8_t what)
	{
		for (const Entity& e : kEntities)
			player->s.send(kHostPeer, Lane::Reliable, Msg::StateDumpRequest, repair_of(e.id, what));
		const bool all = pump(5000, [this] {
			for (const Entity& e : kEntities)
				if (at_player[e.id].empty())
					return false;
			return true;
		});
		pump_for(300);
		return all;
	}

	// Review D1, the world's copy takes the stamp of a map server's spawn (requests::adopt_spawn_stamp -> clone_take_stamp): while it
	// holds none of that weapon or the same one; a weapon it stamped otherwise keeps the world's.
	void world_takes(uint16_t id, uint32_t stamp)
	{
		const auto it = world_stamp.find(id);
		if (it != world_stamp.end() && it->second != stamp)
		{
			++stamps_refused;
			return;
		}
		world_stamp[id] = stamp;
		++stamps_taken;
	}
	// his rider of weapon `id` under the stamp his copy holds (the one of the answer he got)
	void send_rider(uint16_t id, uint32_t stamp)
	{
		Writer w(8);
		w.u16(id);
		w.u32(stamp);
		player->s.send(kHostPeer, Lane::Reliable, Msg::ScriptEvent, w);
	}

	Node host; // the world server's process: its session is the players' host
	Node world; // the map server's connection to its world
	Session map; // the map server's host of its level: the players of the level are virtual peers on it
	std::unique_ptr<Node> player;
	std::map<uint16_t, std::vector<Answer>> at_player;
	std::vector<Answer> at_map_server;
	uint32_t world_answered_a_player = 0, world_answered_its_map_server = 0, map_answered = 0;
	uint32_t vitals_at_world = 0, vitals_at_map = 0;
	bool world_takes_spawn_stamps = true; // review D1 (false: the trunk before the fix, which only marked and forwarded)
	std::map<uint16_t, uint32_t> world_stamp; // the stamp the world's Lua holds per weapon; none: its instance is the name (0)
	uint32_t stamps_taken = 0, stamps_refused = 0;
	uint32_t riders_taken = 0, riders_refused = 0, riders_at_map = 0;

private:
	uint16_t port_;
};

// ---------------------------------------------------------------- source

constexpr size_t npos = std::string::npos;

// anomaly-coop/<rel>, the project root above this source file, without '\r'
std::string project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

// // and /* */ comments dropped
std::string code_of(const std::string& src)
{
	const std::string a = std::regex_replace(src, std::regex(R"(/\*[\s\S]*?\*/)"), " ");
	return std::regex_replace(a, std::regex(R"(//[^\n]*)"), " ");
}

// The body of the function whose definition starts with `head` (up to its closing brace at the start of a line), "" if missing.
std::string body_of(const std::string& code, const std::string& head)
{
	const size_t at = code.find(head);
	if (at == npos)
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return std::string();
	}
	const size_t end = code.find("\n}", at);
	return code.substr(at, end == npos ? npos : end - at);
}

std::string answers_text(const std::vector<Answer>& got)
{
	std::string s = std::to_string(got.size()) + " answer(s)";
	for (const Answer& a : got)
		s += std::string(" by ") + (a.by == kByMap ? "the map server" : a.by == kByWorld ? "the world server" : "?");
	return s;
}
} // namespace

// ---------------------------------------------------------------- the rule (srv/coop_mapserver_rules.h)

TEST(srv_repair_answer_rule_one_process_per_request)
{
	// split on, a player on a map server's level (the world server stands on none of LevelMap: fake_start, xray_banan4ik2.log:6953)
	const mapserver::Incoming up = mapserver::route_incoming(Msg::StateDumpRequest, true, false, true);
	CHECK(up.tunnel); // the map server of his level answers ...
	CHECK(!up.here); // ... and the world server keeps silent
	const mapserver::Incoming down = mapserver::route_incoming(Msg::StateDumpRequest, true, false, false);
	CHECK(down.here); // his map server is not connected: nobody else would answer, the world's copy does
	CHECK(!down.tunnel);
	CHECK(up.here != up.tunnel);
	CHECK(down.here != down.tunnel);
	// his roster ask was the map server's alone already: the digest he compares comes from it (EntityHash does not pass to him
	// from the world server), so the repair it leads to is answered from the same copy
	const mapserver::Incoming roster = mapserver::route_incoming(Msg::EntityResync, true, false, true);
	CHECK(roster.tunnel && !roster.here);
	CHECK(!level_passes(Msg::EntityHash, true, false));
}

TEST(srv_repair_answer_rule_only_the_repair_is_silenced)
{
	std::string answered;
	for (uint32_t v = 0; v <= 0xffff; ++v)
	{
		const Msg m = Msg(uint16_t(v));
		if (scope_listed(m) && mapserver::answered_by_his_map_server(m))
			answered += (answered.empty() ? "" : ", ") + std::string(msg_name(m));
	}
	CHECK_EQ(answered, std::string("StateDumpRequest"));
	// his own data the world keeps for the save and the HUD still goes both ways
	for (const Msg m : {Msg::PlayerVitals, Msg::PlayerEquip, Msg::ItemState, Msg::IdLeaseAck})
	{
		const mapserver::Incoming a = mapserver::route_incoming(m, true, false, true);
		CHECK_EQ(std::string(msg_name(m)) + (a.here && a.tunnel ? " both" : " not both"), std::string(msg_name(m)) + " both");
	}
	// the world messages that touch his body: here and to the authority of his level, as before
	for (const Msg m : {Msg::PlayerWounded, Msg::PlayerRevive, Msg::PlayerDied, Msg::CheckpointClaim, Msg::RestRequest})
	{
		const mapserver::Incoming a = mapserver::route_incoming(m, true, false, true);
		CHECK(a.here && a.tunnel);
	}
	// a map server still asks its world for what it misses, and the world answers it (it is no player's repair)
	CHECK(mapserver::map_server_asks_the_world(Msg::StateDumpRequest));
	CHECK(mapserver::map_server_sends(Msg::StateDumpRequest));
	// the world keeps the request for the case nobody else can answer it
	CHECK(kept_from_every_level(Msg::StateDumpRequest));
}

TEST(srv_repair_answer_rule_coop_rows_unchanged)
{
	// Co-op: no map servers, split off: the host answers every repair itself, as always (the bridge flag means nothing there)
	for (const bool has : {false, true})
	{
		const mapserver::Incoming hostplay = mapserver::route_incoming(Msg::StateDumpRequest, false, false, has);
		CHECK(hostplay.here && !hostplay.tunnel);
		// a player on the level the receiving process leads: handled there, whatever the mode
		const mapserver::Incoming same = mapserver::route_incoming(Msg::StateDumpRequest, true, true, has);
		CHECK(same.here && !same.tunnel);
	}
}

// ---------------------------------------------------------------- the trunk on real sessions

TEST(srv_repair_answer_one_spawn_per_request_for_the_four_entities)
{
	Rig k(t::port(38361));
	REQUIRE(k.start());
	REQUIRE(k.connect_map_server());
	Node& al = k.add_player("Al");
	SessionSrv(k.map).virtual_join(al.s.self(), "Al");
	k.pump_once();
	// a repair of the roster (Spawn | Switch | State as client_on_roster asks one) and a handler's ask (kAskMissing)
	for (const uint8_t what : {uint8_t(reconcile::Spawn | reconcile::Switch | reconcile::State), reconcile::kAskMissing})
	{
		k.at_player.clear();
		const uint32_t map_before = k.map_answered;
		REQUIRE(k.ask_all(what));
		for (const Entity& e : kEntities)
		{
			const std::vector<Answer>& got = k.at_player[e.id];
			CHECK_EQ(std::string(e.what) + ": " + answers_text(got), std::string(e.what) + ": 1 answer(s) by the map server");
			if (got.size() != 1)
				continue;
			// one stamp per request: the map server's, the one it keeps for every later answer; never a second one beside it
			CHECK_EQ(got[0].stamp, e.map);
		}
		CHECK_EQ(k.map_answered - map_before, uint32_t(sizeof(kEntities) / sizeof(kEntities[0])));
	}
	CHECK_EQ(k.world_answered_a_player, 0u); // the world server's handler never ran for his repair
	CHECK(k.at_map_server.empty()); // nor did it go to the map server any other way
}

TEST(srv_repair_answer_without_his_map_server_the_world_answers_once)
{
	Rig k(t::port(38362));
	REQUIRE(k.start());
	k.add_player("Al"); // seated on a level whose map server is not connected (starting, or gone): no bridge
	REQUIRE(k.ask_all(reconcile::kAskMissing));
	for (const Entity& e : kEntities)
	{
		const std::vector<Answer>& got = k.at_player[e.id];
		CHECK_EQ(std::string(e.what) + ": " + answers_text(got), std::string(e.what) + ": 1 answer(s) by the world server");
		if (got.size() == 1)
			CHECK_EQ(got[0].stamp, e.world);
	}
	CHECK_EQ(k.world_answered_a_player, uint32_t(sizeof(kEntities) / sizeof(kEntities[0])));
	CHECK_EQ(k.map_answered, 0u);
}

TEST(srv_repair_answer_the_world_still_answers_its_map_server_and_keeps_his_data)
{
	Rig k(t::port(38363));
	REQUIRE(k.start());
	REQUIRE(k.connect_map_server());
	Node& al = k.add_player("Al");
	SessionSrv(k.map).virtual_join(al.s.self(), "Al");
	k.pump_once();
	// R32 W5: the map server asks its world for an entity of another map and for the world's own (map_server_asks_the_world)
	for (const uint16_t id : {kEntities[2].id, kEntities[3].id})
		k.world.s.send(kHostPeer, Lane::Reliable, Msg::StateDumpRequest, repair_of(id, reconcile::kAskMissing));
	REQUIRE(k.pump(5000, [&k] { return k.at_map_server.size() >= 2; }));
	k.pump_for(300);
	REQUIRE(k.at_map_server.size() == 2);
	for (const Answer& a : k.at_map_server)
	{
		CHECK_EQ(a.by, kByWorld);
		const Entity* e = entity_of(a.id);
		REQUIRE(e != nullptr);
		CHECK_EQ(a.stamp, e->world);
	}
	CHECK_EQ(k.world_answered_its_map_server, 2u);
	CHECK_EQ(k.map_answered, 0u); // never tunnelled back to a map server
	CHECK(k.at_player.empty()); // and no answer of it reached a player
	// his vitals: still the world's (the save, the others' HUD) and his map server's
	Writer vitals(4);
	vitals.u32(1);
	al.s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, vitals);
	CHECK(k.pump(5000, [&k] { return k.vitals_at_world == 1 && k.vitals_at_map == 1; }));
}

// ---------------------------------------------------------------- review D1: the stamp of the map server's answer reaches the world

namespace
{
// A rig with the map server connected and Al on its level (the world's stamps set before by the caller).
Node& seat_al(Rig& k)
{
	REQUIRE(k.start());
	REQUIRE(k.connect_map_server());
	Node& al = k.add_player("Al");
	SessionSrv(k.map).virtual_join(al.s.self(), "Al");
	k.pump_once();
	return al;
}

constexpr uint32_t kEntityCount = uint32_t(sizeof(kEntities) / sizeof(kEntities[0]));
} // namespace

// The map server's answer stamps a weapon the world never stamped (loaded from the save: no stamp in the world's Lua), he takes that
// stamp, and his riders under it went to a world that did not know it: refused (the strict rider lane). Every answer of the map
// server comes up through the world's trunk before it reaches him, so the world's copy takes the stamp there first (review D1:
// coop_trunk.cpp world_takes_spawn_stamp); his riders under it are taken. Routing only (the rig's stubs): the Lua end of the take is
// tests/lua/test_srv_rider_stamp.lua. The with/without loop is a MODEL (review N1): `fixed` switches the rig's own stub of the
// trunk (world_takes_spawn_stamps), not the engine's code, so this case shows that every answer passes the world's trunk before it
// reaches him, and would not fail if coop_trunk.cpp lost its call; that call is pinned only by the source-reading wiring case below.
TEST(srv_repair_answer_the_world_takes_the_stamp_of_the_answer)
{
	for (const bool fixed : {false, true})
	{
		Rig k(fixed ? t::port(38365) : t::port(38364));
		k.world_takes_spawn_stamps = fixed;
		// the world's Lua: the two of his map are the save's (never stamped there); the map server holds the other two as a client
		// of the world, under the world's stamp
		k.world_stamp[kEntities[2].id] = kEntities[2].world;
		k.world_stamp[kEntities[3].id] = kEntities[3].world;
		seat_al(k);
		REQUIRE(k.ask_all(reconcile::kAskMissing));
		for (const Entity& e : kEntities)
		{
			REQUIRE(k.at_player[e.id].size() == 1u);
			k.send_rider(e.id, k.at_player[e.id][0].stamp); // his jam or camo, under the stamp of the answer he got
		}
		REQUIRE(k.pump(5000, [&k] { return k.riders_taken + k.riders_refused == kEntityCount; }));
		k.pump_for(200);
		CHECK_EQ(k.riders_at_map, 0u); // a rider goes to the world's Lua alone
		if (!fixed)
		{
			// the defect: the trunk only marked and forwarded, the two the map server stamped are refused at the world
			CHECK_EQ(k.stamps_taken, 0u);
			CHECK_EQ(k.riders_refused, 2u);
			CHECK_EQ(k.riders_taken, 2u);
			continue;
		}
		CHECK_EQ(k.stamps_taken, kEntityCount); // each answer came up through the trunk first: two new stamps, two the same
		CHECK_EQ(k.stamps_refused, 0u);
		for (const Entity& e : kEntities)
			CHECK_EQ(k.world_stamp[e.id], e.map);
		CHECK_EQ(k.riders_taken, kEntityCount);
		CHECK_EQ(k.riders_refused, 0u);
	}
	// a weapon the world stamped itself (its own answer while the map server was not connected) keeps the world's stamp: the trunk
	// counts and logs the refusal, and his rider under the map server's stamp stays refused at the world (the known limit)
	Rig k(t::port(38366));
	const uint16_t gun = kEntities[0].id;
	k.world_stamp[gun] = kWorldStamp | 0x77;
	seat_al(k);
	k.player->s.send(kHostPeer, Lane::Reliable, Msg::StateDumpRequest, repair_of(gun, reconcile::kAskMissing));
	REQUIRE(k.pump(5000, [&k, gun] { return !k.at_player[gun].empty(); }));
	CHECK_EQ(k.stamps_refused, 1u);
	CHECK_EQ(k.world_stamp[gun], kWorldStamp | 0x77);
	k.send_rider(gun, k.at_player[gun][0].stamp);
	REQUIRE(k.pump(5000, [&k] { return k.riders_refused == 1u; }));
	CHECK_EQ(k.riders_taken, 0u);
}

// ---------------------------------------------------------------- review D4: the known gap of the one answerer

// Not solved here. The map server answers what its copy holds (host_on_entity_request, coop_roster.cpp: no entity under the id ->
// only a Replace or a Gone ask is answered, with EntityDestroy). A handler's ask (kAskMissing = Spawn | Died, client_on_spawn's ask for
// a missing parent) for an id the map server lacks and the world holds gets NO answer while the bridge is up: the world keeps silent,
// the map server has nothing to send. Before P99 the world's copy answered it too. Without the bridge the world answers it.
TEST(srv_repair_answer_known_gap_an_id_his_map_server_lacks_gets_no_answer)
{
	{
		Rig k(t::port(38367));
		Node& al = seat_al(k);
		al.s.send(kHostPeer, Lane::Reliable, Msg::StateDumpRequest, repair_of(kOnlyAtWorld.id, reconcile::kAskMissing));
		REQUIRE(k.pump(5000, [&k] { return k.map_answered == 1u; })); // the map server's handler ran ...
		k.pump_for(300);
		CHECK(k.at_player[kOnlyAtWorld.id].empty()); // ... and had nothing to send; nobody answers him
		CHECK_EQ(k.world_answered_a_player, 0u);
	}
	Rig k(t::port(38368));
	REQUIRE(k.start());
	Node& al = k.add_player("Al"); // no map server connected: the world's copy answers
	al.s.send(kHostPeer, Lane::Reliable, Msg::StateDumpRequest, repair_of(kOnlyAtWorld.id, reconcile::kAskMissing));
	REQUIRE(k.pump(5000, [&k] { return !k.at_player[kOnlyAtWorld.id].empty(); }));
	CHECK_EQ(k.at_player[kOnlyAtWorld.id][0].by, kByWorld);
	// the engine's handler still answers nothing for a missing entity but a Replace or a Gone ask: the gap stands as pinned here
	const std::string roster = code_of(project_file("engine/src/xrGame/coop/coop_roster.cpp"));
	const std::string handler = body_of(roster, "void host_on_entity_request(PeerId from, Reader& r)");
	const size_t missing = handler.find("if (!e)");
	REQUIRE(missing != npos);
	const std::string branch = handler.substr(missing, handler.find("return;", missing) - missing);
	CHECK(branch.find("(what & reconcile::Replace) || ((what & reconcile::Gone) && !world::server_entity(id))") != npos);
	CHECK(branch.find("send_subtree") == npos);
}

// ---------------------------------------------------------------- the wiring: the Server layer decides, the Core's handler answers

TEST(srv_repair_answer_wiring_the_trunk_returns_the_rule_and_the_core_has_no_mode_word)
{
	const std::string trunk = code_of(project_file("engine/src/xrGame/coop/srv/coop_trunk.cpp"));
	const std::string in = body_of(trunk, "bool host_incoming(PeerId from, Msg type, Lane lane, const u8* packet, size_t size)");
	const size_t bridge = in.find("if (is_bridge(from))");
	const size_t routed = in.find("route_incoming(");
	CHECK(bridge != npos);
	CHECK(routed != npos);
	CHECK(bridge < routed); // a map server's own ask is answered by the world before any routing
	CHECK(in.find("return go.here;") != npos); // the silence reaches the world server's handler through the in-filter
	// the srv in-filter is the world server's only (coop_srv_mode.cpp); a co-op host has none
	const std::string srv_mode = code_of(project_file("engine/src/xrGame/coop/srv/coop_srv_mode.cpp"));
	CHECK(srv_mode.find("set_in_filter(&mapserver::host_incoming)") != npos);
	// the Core's handler answers whenever it runs: no mode check and no Server word was added to it for this
	const std::string entities = code_of(project_file("engine/src/xrGame/coop/coop_entities.cpp"));
	CHECK(code_of(project_file("engine/src/xrGame/coop/coop_roster.cpp")).find("answered_by_his_map_server") == npos);
	const std::string server = body_of(entities, "void install_server(Session& s)");
	CHECK(server.find("Msg::StateDumpRequest") != npos);
	CHECK(server.find("host_on_entity_request(from, r)") != npos);
}

namespace
{
// Each of `tokens` found in `body` after the one before it: the order a writer and its reader keep.
bool in_order(const std::string& body, std::initializer_list<const char*> tokens)
{
	size_t at = 0;
	for (const char* token : tokens)
	{
		const size_t found = body.find(token, at);
		if (found == npos)
		{
			t::report_failure(__FILE__, __LINE__, std::string("not in order: ") + token);
			return false;
		}
		at = found + std::string(token).size();
	}
	return true;
}
} // namespace

// Review D1 and D5 in the engine's source (it is not built into this exe).
TEST(srv_repair_answer_wiring_the_world_takes_the_stamp_before_the_spawn_goes_on)
{
	const std::string trunk = code_of(project_file("engine/src/xrGame/coop/srv/coop_trunk.cpp"));
	// D5: a player on no level is nobody's of a map server: no "level 65535" line
	const std::string in = body_of(trunk, "bool host_incoming(PeerId from, Msg type, Lane lane, const u8* packet, size_t size)");
	CHECK(in.find("answered_by_his_map_server(type) && !home && level != levels::wire::kNoLevel") != npos);
	// D1: the world's copy takes the stamp of a map server's spawn before the spawn goes on to anybody
	const std::string tunnel = body_of(trunk, "void trunk_host_on_tunnel(PeerId from, Reader& r)");
	CHECK(in_order(tunnel, {"if (level == wire::kNoLevel)", "if (m.type() == Msg::EntitySpawn)", "world_takes_spawn_stamp(level, m.packet)",
	                           "mark_spawn_of_your_level(m.packet)", "mgr().session().send("}));
	const std::string takes = body_of(trunk, "void world_takes_spawn_stamp(u16 level, const std::vector<u8>& packet)");
	CHECK(takes.find("requests::adopt_spawn_stamp(packet.data(), packet.size(), id)") != npos);
	for (const char* outcome : {"SpawnStamp::Taken", "SpawnStamp::Refused", "SpawnStamp::NoEntity"})
		CHECK(takes.find(outcome) != npos); // each counted and logged
	// the Core's helper: reads the spawn as write_spawn writes it, then takes the stamp alone (review R1: clone_take_stamp, not the
	// whole adoption of stage_clone_initial -> clone_adopt, whose purge drops the item's held changes)
	const std::string requests = code_of(project_file("engine/src/xrGame/coop/coop_requests_clone.cpp"));
	const std::string adopt = body_of(requests, "SpawnStamp adopt_spawn_stamp(const u8* message, size_t size, u16& id_host)");
	CHECK(in_order(adopt, {"!= u16(Msg::EntitySpawn)", "id_host = r.u16();", "r.u16();", "r.u8();", "r.vec3(skipped);",
	                          "r.vec3(skipped);", "r.u32();", "r.u16();", "r.skip(r.u16());", "read_clone_initial(r, id, initial)",
	                          "if (initial.empty())", "world::server_entity(id)", "g_clone_prepared.count(id)",
	                          "replacement::decode(initial.data(), initial.size(), snapshot)", "clone_function(\"clone_take_stamp\", top)",
	                          "clone_return(L, top, 2)"}));
	CHECK(adopt.find("stage_clone_initial") == npos);
	CHECK(adopt.find("clone_adopt") == npos);
	for (const char* word : {"is_map_server", "is_world_server", "dedicated", "mapserver", "levels::", "split", "bridge"})
		CHECK(adopt.find(word) == npos); // the Core has no mode word
	// the layout the helper skips is the one write_spawn writes (coop_entities.cpp), field by field
	const std::string entities = code_of(project_file("engine/src/xrGame/coop/coop_entities.cpp"));
	CHECK(in_order(body_of(entities, "bool write_spawn(Writer& w, CSE_ALifeDynamicObject* e, NET_Packet& spawn, NET_Packet& update)"),
	    {"w.u16(e->ID);", "w.u16(e->ID_Parent);", "w.boolean(online_here(e));", "write_placement(w, e);", "write_packet(w, spawn);",
	        "write_packet(w, update);", "requests::write_clone_initial(w, e)"}));
	CHECK(in_order(body_of(entities, "void write_placement(Writer& w, const CSE_ALifeDynamicObject* e)"),
	    {"w.vec3(pos);", "w.vec3(ang);", "w.u32(e->m_tNodeID);", "w.u16(e->m_tGraphID);"}));
	CHECK(in_order(body_of(entities, "void write_packet(Writer& w, const NET_Packet& p)"),
	    {"w.u16(u16(p.B.count));", "w.bytes(p.B.data, p.B.count);"}));
}
