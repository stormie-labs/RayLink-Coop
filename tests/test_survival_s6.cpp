#include "test_util.h"
#include <fstream>
#include <sstream>
#include <string>

namespace
{
std::string source(const char* file)
{
	std::string path = __FILE__;
	const size_t slash = path.find_last_of("/\\");
	path = slash == std::string::npos ? "tests/" : path.substr(0, slash + 1);
	std::ifstream in(path + "../engine/src/xrGame/coop/" + file);
	std::ostringstream out;
	out << in.rdbuf();
	return out.str();
}

std::string function(const std::string& code, const char* signature)
{
	const size_t start = code.find(signature);
	REQUIRE(start != std::string::npos);
	const size_t end = code.find("\n}", start);
	REQUIRE(end != std::string::npos);
	return code.substr(start, end - start);
}
} // namespace

// The standalone production-path probe runs host_story with opposing Mode and legacy answers.
TEST(survival_s6_story_path_reads_the_decider)
{
	const auto story = function(source("coop_checkpoints.cpp"), "bool host_story(");
	CHECK(story.find("mode().decider_of(c)") != std::string::npos);
	CHECK(story.find("levels::host_character_elsewhere") == std::string::npos);
}

TEST(survival_s6_map_handlers_are_installed_separately)
{
	const auto survival = source("coop_survival.cpp");
	const auto world = function(survival, "void server_on_state(");
	const auto mirror = function(survival, "void client_on_state(");
	const auto order = function(survival, "void client_on_revive(");
	const auto rules = function(survival, "void on_rules_msg(");
	CHECK(world.find("is_map_server()") == std::string::npos);
	CHECK(mirror.find("peer_of_character") == std::string::npos);
	CHECK(order.find("host_apply_losses") == std::string::npos);
	CHECK(order.find("host_move_to_stash") == std::string::npos);
	CHECK(rules.find("g_world_rules") == std::string::npos);
	const auto level_server = function(survival, "void install_level_server(");
	const auto level_client = function(survival, "void install_level_client(");
	CHECK(level_server.find("Msg::PlayerWounded, &map_on_state") != std::string::npos);
	CHECK(level_client.find("Msg::PlayerWounded, &map_on_state_relay") != std::string::npos);
	CHECK(level_client.find("Msg::PlayerRevive, &map_on_revive") != std::string::npos);
	CHECK(level_client.find("Msg::PlayerRules, &map_on_rules") != std::string::npos);
}

TEST(survival_s6_map_stash_completion_keeps_the_queued_report_order)
{
	const auto survival = source("coop_survival.cpp");
	const auto frame = function(survival, "void frame()");
	const auto stash = function(source("coop_survival_newchar.cpp"), "void level_stash_frame()");
	const auto transfer = function(source("srv/coop_levels_xfer.cpp"), "void up_stash(");
	const auto level_branch = frame.find("else if (mode().level())");
	const auto finish = frame.find("level_stash_frame()");
	const auto local = frame.find("local_actor()");
	CHECK(level_branch != std::string::npos && level_branch < finish && finish < local);
	const auto pending = stash.find("death::StashOutcome::Pending");
	const auto report = stash.find("levels::up_stash(");
	const auto erase = stash.find("g_stashing.erase");
	CHECK(pending != std::string::npos && pending < report && report < erase);
	CHECK(transfer.find("g.up.push_back(") != std::string::npos);
}

TEST(survival_s6_map_checkpoint_facts_stay_in_body_report_order)
{
	const auto sources = source("coop_checkpoint_sources.cpp");
	const auto scan = function(sources, "void map_server_scan(");
	const auto footing = function(sources, "void map_server_footing(");
	const auto status = function(sources, "void print_status()");
	const auto report = function(source("srv/coop_levels_xfer.cpp"), "void client_body(");
	CHECK(sources.find("coop_mapserver.h") == std::string::npos);
	CHECK(scan.find("level_peer_of(") != std::string::npos);
	CHECK(footing.find("is_map_server()") == std::string::npos);
	CHECK(status.find("is_map_server()") == std::string::npos);
	const auto scan_at = report.find("::map_server_scan(");
	const auto footing_at = report.find("::map_server_footing(");
	const auto write_at = report.find("facts.write(w)");
	CHECK(scan_at != std::string::npos && scan_at < footing_at && footing_at < write_at);
}

// The native runner cannot link xrGame. Guard the routing boundary directly: the Core cannot resolve or send to a bridge itself.
TEST(survival_s6_core_routes_losses_and_stashes_through_the_mode)
{
	const std::string survival = source("coop_survival.cpp");
	REQUIRE(!survival.empty());
	CHECK(survival.find("mapserver::bridge_of") == std::string::npos);
	CHECK(survival.find("bridge_of_body(") == std::string::npos);
	CHECK(survival.find("mode().to_level_of(") != std::string::npos);
}

TEST(survival_s6_checkpoint_write_requires_an_explicit_location)
{
	const std::string checkpoints = source("coop_checkpoints.h");
	const size_t start = checkpoints.find("bool host_set(");
	REQUIRE(start != std::string::npos);
	const size_t end = checkpoints.find(';', start);
	REQUIRE(end != std::string::npos);
	CHECK(checkpoints.substr(start, end - start).find('=') == std::string::npos);
}
