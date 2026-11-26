#include "test_util.h"

#include <fstream>
#include <sstream>
#include <string>

namespace
{
std::string source(const char* file)
{
	const std::string self = __FILE__;
	const size_t slash = self.find_last_of("/\\");
	const std::string tests = slash == std::string::npos ? "tests" : self.substr(0, slash);
	std::ifstream in(tests + "/../engine/src/xrGame/coop/" + file);
	REQUIRE(in.is_open());
	std::ostringstream out;
	out << in.rdbuf();
	return out.str();
}

std::string body(const std::string& code, const char* signature)
{
	const size_t start = code.find(signature);
	REQUIRE(start != std::string::npos);
	const size_t end = code.find("\n}", start);
	REQUIRE(end != std::string::npos);
	return code.substr(start, end - start);
}
} // namespace

// Source checks for the migration. The per-process production paths run via test_s6_npc_paths.py.
TEST(npc_s6_entity_reports_keep_kind_payload_and_order)
{
	const auto entities = source("coop_entities.cpp");
	const auto events = source("coop_events.cpp");
	const auto spawned = body(entities, "void host_on_entity_registered(");
	const auto released = body(entities, "void host_on_entity_released(");
	const auto parent = body(events, "void host_on_parent_changed(");
	const auto died = body(events, "void host_on_death(");
	const auto spawn_report = spawned.find("level_entity_up(EntityUp::Spawned, e->ID, kNoId)");
	const auto release_report = released.find("level_entity_up(EntityUp::Released, id, kNoId)");
	const auto parent_guard = parent.find("if (!entities::host_records())");
	const auto death_guard = died.find("if (!entities::host_records())");
	CHECK(spawn_report != std::string::npos && spawned.find("HostEventKind::Registered") < spawn_report);
	CHECK(release_report != std::string::npos && released.find("HostEventKind::Released") < release_report);
	CHECK(parent_guard != std::string::npos && parent.find("level_entity_up(EntityUp::Parent, item, new_parent)") < parent_guard);
	CHECK(death_guard != std::string::npos && died.find("level_entity_up(EntityUp::Died, victim, killer)") < death_guard);
	for (const auto* action : {&spawned, &released, &parent, &died})
		CHECK(action->find("mode().level()") != std::string::npos);
}

TEST(npc_s6_placement_and_hashes_consume_mode_answers)
{
	const auto entities = source("coop_entities.cpp");
	const auto spawn = body(entities, "void client_on_spawn(");
	CHECK(spawn.find("levels::wire::kSpawnOnlineAtYourLevel || mode().where(kHostPeer) == Where::Here") != std::string::npos);
	CHECK(spawn.find("in_level_registry, flag_of_this_level, switches_alone") != std::string::npos);
	CHECK(body(source("coop_roster.cpp"), "void host_reconcile(").find("mode().reaches(p.id, Msg::EntityHash)") != std::string::npos);
}

TEST(npc_s6_world_authority_and_level_bridge_keep_their_paths)
{
	const std::string authority = "mode().decides_world() || mode().leads_level()";
	for (const auto* file : {"coop_ai.cpp", "coop_entities.cpp", "coop_events.cpp", "coop_monster_fx.cpp", "coop_objects.cpp",
	         "coop_players.cpp", "coop_presence.cpp"})
	{
		const auto code = source(file);
		CHECK(code.find(authority) != std::string::npos || code.find("mode().decides_here()") != std::string::npos);
		CHECK(code.find("is_map_authority()") == std::string::npos);
	}
	const auto events = source("coop_events.cpp");
	CHECK(body(events, "bool client_filter(").find("!mgr().active() || mode().decides_world()") != std::string::npos);
	CHECK(body(events, "bool filter_event(").find("mode().leads_level() && type != GE_MONEY") != std::string::npos);
}

TEST(npc_s6_only_the_authority_without_the_map_consults_remote_seats)
{
	const auto alife = source("coop_alife.cpp");
	const auto observer = body(alife, "float observer_distance(");
	CHECK(observer.find("!current.decides_world() && !current.leads_level()") != std::string::npos);
	CHECK(observer.find("check_remote_seats = !current.leads_level()") != std::string::npos);
	CHECK(observer.find("check_remote_seats && current.where(peer) == Where::Away") != std::string::npos);
	const auto players = source("coop_players.cpp");
	CHECK(body(players, "void host_on_player_state(").find("!mode().leads_level() && mode().where(from) == Where::Away") !=
	    std::string::npos);
}
