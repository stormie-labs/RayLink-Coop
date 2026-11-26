// Anomaly Coop unit tests: the server's modes call the server's part of the join (A-S6J, srv/coop_srv_join.cpp), read in
// srv/coop_srv_mode.cpp; the co-op's modes call none of it. Added together with temp/a_s6j/engine_coop_srv_mode.patch (the lead).
// Server: the world server installs its join handlers after the Core's, runs its bridges' wait every frame and asks its own facts at
// the autostart; a map server installs its SessionReset after the Core's client tables; a server player's session starts and runs the
// feed. Co-op: nothing of it in hostplay/coop_hostplay_mode.cpp.
// Stand b57h creator10_server: a level is left standing. Server: the world refuses a move of a player who is down, dead, out of the
// run or being respawned (srv::departure::may_leave), and his own game does not ask one. Co-op: none (no trip; the group transition
// counts the standing, join::host_player_alive).
#include "test_util.h"
#include "coop_death_rules.h"
#include "srv/coop_srv_departure_rules.h"

#include <fstream>
#include <regex>
#include <sstream>
#include <string>

namespace
{
std::string sjw_read(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream in(here + "/../engine/src/" + rel, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The text of class `cls` (from "class <cls> final" to the next "\nclass " or the end).
std::string sjw_class(const std::string& src, const std::string& cls)
{
	const size_t at = src.find("class " + cls);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find("\nclass ", at + 1);
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

// The body of member `name` in `cls` (its first "name(" with a body), braces matched.
std::string sjw_member(const std::string& cls, const std::string& head)
{
	std::smatch m;
	if (!std::regex_search(cls, m, std::regex(head + R"(\s*\([^;{]*\)\s*(const\s*)?(override\s*)?\{)")))
		return std::string();
	const size_t open = size_t(m.position(0) + m.length(0) - 1);
	int depth = 0;
	for (size_t i = open; i < cls.size(); ++i)
	{
		if (cls[i] == '{')
			++depth;
		else if (cls[i] == '}' && --depth == 0)
			return cls.substr(open, i - open + 1);
	}
	return std::string();
}

bool sjw_order(const std::string& text, const std::string& first, const std::string& then)
{
	const size_t a = text.find(first);
	const size_t b = text.find(then);
	return a != std::string::npos && b != std::string::npos && a < b;
}
} // namespace

TEST(srv_join_wired_in_the_server_modes)
{
	const std::string srv = sjw_read("xrGame/coop/srv/coop_srv_mode.cpp");
	REQUIRE(!srv.empty());
	CHECK(srv.find("#include \"coop/srv/coop_srv_join.h\"") != std::string::npos);
	const std::string world = sjw_class(srv, "WorldServerMode");
	REQUIRE(!world.empty());
	CHECK(sjw_order(sjw_member(world, R"(void\s+install)"), "join::install_server(tables.session)", "join_install_world(tables.session)"));
	CHECK(sjw_order(sjw_member(world, R"(void\s+frame)"), "levels::frame()", "join_world_frame()"));
	const std::string map = sjw_class(srv, "MapServerMode");
	REQUIRE(!map.empty());
	CHECK(sjw_order(sjw_member(map, R"(void\s+install)"), "join::install_client(tables.world)", "join_install_map(tables.world)"));
	const std::string player = sjw_class(srv, "ServerClientMode");
	REQUIRE(!player.empty());
	CHECK(sjw_member(player, R"(void\s+install)").find("feed_start()") != std::string::npos);
	CHECK(sjw_order(sjw_member(player, R"(void\s+frame)"), "levels::frame()", "feed_frame()"));
	CHECK(srv.find("const dedicated::WorldFacts facts = world_facts();") != std::string::npos);
	CHECK(srv.find("join::host_world_facts") == std::string::npos);
}

TEST(srv_join_not_wired_in_the_coop_modes)
{
	const std::string coop = sjw_read("xrGame/coop/hostplay/coop_hostplay_mode.cpp");
	REQUIRE(!coop.empty());
	for (const char* word : {"coop_srv_join", "join_install_world", "join_world_frame", "join_install_map", "feed_start", "feed_frame",
	         "world_facts"})
		CHECK(coop.find(word) == std::string::npos);
}

// b57h: the creator went down in the 3 s fade of a stock ChangeLevel and died; the trip went out after it, the world moved him and he
// arrived downed again (health 0.01, a new bleed-out) instead of being evacuated and respawned.
TEST(srv_join_a_level_is_left_standing)
{
	using namespace coop::death;
	CHECK(coop::srv::departure::may_leave(kLifeAlive));
	for (uint8_t life : {kLifeWounded, kLifeDead, kLifeSpectating, kLifeRespawning, uint8_t(5), uint8_t(255)})
		CHECK(!coop::srv::departure::may_leave(life));
	const std::string world = sjw_read("xrGame/coop/srv/coop_srv_join.cpp");
	REQUIRE(!world.empty());
	const std::string move = sjw_member(world, R"(void\s+on_level_move)");
	REQUIRE(!move.empty());
	CHECK(sjw_order(move, "srv::departure::may_leave(u8(life))", "levels::host_judge_move(from, target)"));
	CHECK(sjw_order(move, "srv::departure::may_leave(u8(life))", "alife_rw().teleport_object(proxy->ID"));
	const std::string core = sjw_read("xrGame/coop/coop_join_transition.cpp");
	REQUIRE(!core.empty());
	const std::string trip = sjw_member(core, R"(void\s+client_level_trip)");
	REQUIRE(!trip.empty());
	CHECK(sjw_order(trip, "survival::life_of(0) != survival::Life::Alive", "client_send_move(m, now)"));
}
