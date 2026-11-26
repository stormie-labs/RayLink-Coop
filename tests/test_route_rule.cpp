// Anomaly Coop unit tests: routes::Table::rule, the one answer of coop.route.of and coop.route.rule_of (coop_router.cpp asks it for
// every handler it routes): the table's route, raised from Host to Level for the behaviour of an object online on a level, and
// nothing else changed.
#include "test_util.h"

#include "coop_routes.h"

#include <string>
#include <utility>
#include <vector>

using coop::routes::Domain;
using coop::routes::Override;
using coop::routes::Table;
using coop::routes::parse_section;

namespace
{
Table table_with_level_rules()
{
	Table t;
	std::vector<std::string> errors;
	const std::vector<std::pair<std::string, std::string>> scripts = {
		{"sim_board", "host"}, {"xr_motivator", "host"}, {"hud_mod", "view"}, {"quiet_mod", "none"}};
	for (const Override& o : parse_section("route_scripts", scripts, &errors))
		t.add(o);
	const std::vector<std::pair<std::string, std::string>> pairs = {{"npc_on_update@pair_mod", "owner"}};
	for (const Override& o : parse_section("route_pairs", pairs, &errors))
		t.add(o);
	CHECK(errors.empty());
	t.add_level_script("xr_motivator");
	t.add_level_callback("npc_on_update");
	return t;
}
} // namespace

TEST(route_rule_raises_host_to_level_for_the_behaviour_of_online_objects)
{
	const Table t = table_with_level_rules();
	// a listed script: Level for every callback the table sends to the host
	CHECK(t.route("npc_on_update", "xr_motivator") == Domain::Host);
	CHECK(t.rule("npc_on_update", "xr_motivator") == Domain::Level);
	CHECK(t.route("save_state", "xr_motivator") == Domain::Host);
	CHECK(t.rule("save_state", "XR_Motivator") == Domain::Level); // names compare case-insensitively
	// a listed callback of a script without a rule of its own: its stock default is Host, so Level
	CHECK(t.route("npc_on_update", "some_mod") == Domain::Host);
	CHECK(t.rule("npc_on_update", "some_mod") == Domain::Level);
	CHECK(t.rule("NPC_on_update", "some_mod") == Domain::Level);
}

TEST(route_rule_keeps_every_other_answer_of_the_table)
{
	const Table t = table_with_level_rules();
	// a world script keeps the host whatever it listens to
	CHECK(t.rule("npc_on_update", "sim_board") == Domain::Host);
	// a Host answer for a callback and a script nobody listed stays Host
	CHECK(t.route("save_state", "some_mod") == Domain::Host);
	CHECK(t.rule("save_state", "some_mod") == Domain::Host);
	// what is not Host is never raised: owner, view, none
	CHECK(t.rule("actor_on_update", "some_mod") == Domain::Owner);
	CHECK(t.rule("npc_on_update", "hud_mod") == Domain::View);
	CHECK(t.rule("npc_on_update", "quiet_mod") == Domain::None);
	CHECK(t.rule("npc_on_update", "pair_mod") == Domain::Owner); // a pair rule wins, and it is no Host
	// an empty callback asks for the script alone (coop.route.of("", f)): the same rule
	CHECK(t.rule("", "xr_motivator") == Domain::Level);
	CHECK(t.rule("", "hud_mod") == Domain::View);
}

TEST(route_rule_of_an_empty_table_is_the_route)
{
	const Table t;
	for (const char* callback : {"npc_on_update", "actor_on_update", "save_state", "on_key_press", "a_mods_own_callback", ""})
		CHECK(t.rule(callback, "some_mod") == t.route(callback, "some_mod"));
}
