// Anomaly Coop unit tests: what the Core's story (xrGame/coop/coop_story.cpp) takes for granted since it stopped naming the server's
// bridges (A-S5S, docs/MODES.md section 3, rules L1/L3).
//
// 1. A connection that is no player. The story's audience check (may_see) and the task-state verdict (lua_task_state_ok) asked
//    mapserver::is_bridge(peer); they ask the session now: a connection of this session (Session::joined) that is none of its players
//    (Session::peer is null). In a server world that is a map server's connection and nothing else; in the co-op there is none; a
//    player who left is neither (no audience lets him in). resend_tasks never resent to a bridge: it resends only to one of peers().
//    Checked on real sessions over 127.0.0.1 (ports 38771+n): a world server with a bridge and a player, a co-op host with a player.
// 2. Such a connection is in every task's audience (the audience names players' characters; a map server runs every task's logic); a
//    player's seat is in it only as a member.
// 3. The map server's reputation step of the story frame and its ghost frame ran on is_map_server() in the branch of a process that does
//    not decide the world; they run on mode().leads_level() there now. coop_quests_pda.script (Lua): a map server's word goes up with its
//    level's name on coop_mode.leads_here() and not coop_mode.decides_world(). Checked on the six process kinds of
//    tests/support/fake_mode.h (whose rows test_mode_answers.cpp compares with the real modes).
#include "test_util.h"

#include "support/fake_mode.h"

#include "srv/coop_mapserver_rules.h"
#include "coop_roles.h"
#include "coop_task_audience.h"
#include "srv/coop_session_srv.h"

#include <array>
#include <cstring>
#include <string>

using namespace coop;

namespace
{
using t::Node;
using Token = std::array<uint8_t, kHelloTokenSize>;

// coop_story.cpp no_player_connection(): a connection of this session that is none of its players.
bool no_player_connection(const Session& s, PeerId peer) { return peer != kHostPeer && s.joined(peer) && !s.peer(peer); }

Token token_of(uint8_t first)
{
	Token out{};
	for (size_t i = 0; i < out.size(); ++i)
		out[i] = uint8_t(first + 3 * i + 2);
	return out;
}

bool join(Node& host, Node& c, uint16_t port)
{
	std::string err;
	if (!c.connect(port, &err))
		return false;
	return t::pump_until({&host.s, &c.s}, 5000, [&] { return c.welcomed || c.rejected; }) && c.welcomed;
}
} // namespace

// Server: the world server's session has a map server's bridge and a player; only the bridge is a connection that is no player.
TEST(story_bridges_a_bridge_is_the_world_servers_connection_that_is_no_player)
{
	Node world("world", t::port(38771)), ms("ms", t::port(38771)), player("Ann", t::port(38771));
	world.cfg.host_plays = false; // its seat plays no character
	std::string err;
	world.cfg.mode = SessionMode::Server;
	REQUIRE(world.host(&err));
	srv::SessionSrv(world.s).issue_bridge(2, token_of(11));
	ms.cfg.hello_role = kHelloRoleMapServer;
	const Token tok = token_of(11);
	std::memcpy(ms.cfg.hello_token.data(), tok.data(), tok.size());
	REQUIRE(join(world, ms, t::port(38771)));
	REQUIRE(join(world, player, t::port(38771)));
	REQUIRE(t::pump_until({&world.s, &ms.s, &player.s}, 5000,
	    [&] { return world.s.joined(mapserver::bridge_peer(2)) && world.s.peer(player.s.self()) != nullptr; }));
	const PeerId bridge = mapserver::bridge_peer(2);
	CHECK(no_player_connection(world.s, bridge));
	CHECK(!no_player_connection(world.s, player.s.self()));
	CHECK(!no_player_connection(world.s, kHostPeer)); // its own seat: nobody's connection
	CHECK(!no_player_connection(world.s, mapserver::bridge_peer(3))); // a map server that is not connected
	CHECK(!no_player_connection(world.s, kInvalidPeer));
	// every id the session could hand a handler: the bridge alone
	int found = 0;
	for (uint32_t id = 0; id <= 0x1ffu; ++id)
		if (no_player_connection(world.s, PeerId(id)))
		{
			CHECK(mapserver::is_bridge(PeerId(id)));
			++found;
		}
	CHECK(found == 1);
}

// Co-op: a co-op host's session has players only; a player who left is no connection at all.
TEST(story_bridges_a_coop_host_has_no_connection_that_is_no_player)
{
	Node host("host", t::port(38772)), ann("Ann", t::port(38772));
	std::string err;
	host.cfg.mode = SessionMode::Coop;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, ann, t::port(38772)));
	const PeerId slot = ann.s.self();
	REQUIRE(t::pump_until({&host.s, &ann.s}, 5000, [&] { return host.s.peer(slot) != nullptr; }));
	for (uint32_t id = 0; id <= 0x1ffu; ++id)
		CHECK(!no_player_connection(host.s, PeerId(id)));
	ann.s.shutdown("bye");
	REQUIRE(t::pump_until({&host.s, &ann.s}, 5000, [&] { return host.s.peer(slot) == nullptr; }));
	CHECK(!no_player_connection(host.s, slot)); // gone: in no audience by this rule either
}

TEST(story_bridges_a_connection_that_is_no_player_is_in_every_audience)
{
	using task_audience::kNoCharacter;
	using task_audience::Table;
	Table t;
	REQUIRE(t.set("drx_sl_task_1", {500, 502}) == Table::Set::Added);
	// a map server's connection: no character of its own (world::avatar_of answers kNoCharacter), every task
	CHECK(t.allowed("drx_sl_task_1", kNoCharacter, true));
	// a player's seat: only as a member, also before he has a character
	CHECK(t.allowed("drx_sl_task_1", 500, false));
	CHECK(!t.allowed("drx_sl_task_1", 501, false));
	CHECK(!t.allowed("drx_sl_task_1", kNoCharacter, false));
	// a task with no audience is everybody's
	CHECK(t.allowed("esc_task", 501, false));
	CHECK(t.allowed("esc_task", kNoCharacter, true));
}

// story::frame: the branch of a process that does not decide the world (mgr().is_host() false) ran ghost_frame and
// host_flush_rep_deltas on is_map_server(); it asks mode().leads_level() now. coop_quests_pda.script: announce_ency / on_earned send a
// map server's word up on coop_mode.leads_here() and not coop_mode.decides_world().
TEST(story_bridges_map_server_steps_run_where_is_map_server_did)
{
	int map_servers = 0;
	for (const t::ModeCase& c : t::mode_cases())
	{
		const t::FakeMode m(c);
		const bool map_server = has(m.roles(), ProcessRole::MapServer);
		const bool deciders_branch = has(m.roles(), ProcessRole::WorldServer); // mgr().is_host()
		if (!deciders_branch)
		{
			const bool runs = m.leads_level();
			if (runs != map_server)
				std::printf("    %s: leads_level %d, map server %d\n", c.name, int(runs), int(map_server));
			CHECK(runs == map_server);
		}
		CHECK((m.leads_level() && !m.decides_world()) == map_server);
		map_servers += map_server ? 1 : 0;
	}
	CHECK(map_servers == 1); // the one process kind whose reputation deltas go to the players of its map
}
