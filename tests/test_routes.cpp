// Anomaly Coop unit tests: callback route table (coop_routes.h, MOD_LAYER.md §2.2, F2 T9).
#include "test_util.h"

#include "coop_routes.h"

#include <cctype>
#include <fstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

using namespace coop::routes;

namespace
{
using Lines = std::vector<std::pair<std::string, std::string>>;

Override script_rule(const char* script, Domain d) { return Override{Override::Script, "", script, d}; }
Override callback_rule(const char* callback, Domain d) { return Override{Override::Callback, callback, "", d}; }
Override forced_rule(const char* callback, Domain d) { return Override{Override::Forced, callback, "", d}; }
Override pair_rule(const char* callback, const char* script, Domain d)
{
	return Override{Override::Pair, callback, script, d};
}

bool mentions(const std::vector<std::string>& errors, const char* needle)
{
	for (const std::string& e : errors)
		if (e.find(needle) != std::string::npos)
			return true;
	return false;
}

// One stock callback of axr_main.script's `intercepts` table and the "--// Group" header above it.
struct StockEntry
{
	std::string name, group;
	bool commented;
};

// axr_main.script of the engine's gamedata, found next to this source file (tests\ -> ..\engine\gamedata\scripts).
std::string axr_main_path()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/gamedata/scripts/axr_main.script";
	here.resize(slash); // ...\tests
	return here + "/../engine/gamedata/scripts/axr_main.script";
}

// Reads the `local intercepts = { ... }` block: every `name = {}` row, commented-out rows included (the brief counts
// 147 = 140 live + 7 disabled), each with its group header.
std::vector<StockEntry> read_intercepts(const std::string& path)
{
	std::vector<StockEntry> out;
	std::ifstream in(path);
	std::string line, group;
	bool inside = false;
	while (std::getline(in, line))
	{
		if (!inside)
		{
			inside = line.find("local intercepts = {") != std::string::npos;
			continue;
		}
		if (line == "}" || line == "}\r")
			break;
		size_t i = line.find_first_not_of(" \t");
		if (i == std::string::npos)
			continue;
		if (line.compare(i, 4, "--//") == 0)
		{
			group = line.substr(i + 4);
			const size_t g = group.find_first_not_of(" \t");
			const size_t e = group.find_last_not_of(" \t\r");
			group = g == std::string::npos ? std::string() : group.substr(g, e - g + 1);
			continue;
		}
		bool commented = false;
		if (line.compare(i, 2, "--") == 0)
		{
			commented = true;
			i = line.find_first_not_of(" \t", i + 2);
			if (i == std::string::npos)
				continue;
		}
		size_t j = i;
		while (j < line.size() && (std::isalnum(static_cast<unsigned char>(line[j])) || line[j] == '_'))
			++j;
		if (j == i)
			continue;
		const size_t eq = line.find_first_not_of(" \t", j);
		if (eq == std::string::npos || line[eq] != '=')
			continue;
		const size_t brace = line.find_first_not_of(" \t", eq + 1);
		if (brace == std::string::npos || line.compare(brace, 2, "{}") != 0)
			continue;
		out.push_back({line.substr(i, j - i), group, commented});
	}
	return out;
}
} // namespace

TEST(routes_defaults)
{
	// Brief rows.
	CHECK_EQ(default_of("actor_on_item_use"), Domain::Owner);
	CHECK_EQ(default_of("npc_on_death_callback"), Domain::Host);
	CHECK_EQ(default_of("on_key_press"), Domain::View);
	CHECK_EQ(default_of("save_state"), Domain::Host);
	CHECK_EQ(default_of("load_state"), Domain::View);
	CHECK_EQ(default_of("my_mod_cb"), Domain::Owner);

	// A mod's own callback (AddScriptCallback + SendScriptCallback): GAMMA Useful Idiots sends idiots_on_start and its
	// handler fills the config the rest of the mod reads. Unknown name -> owner -> it runs on the client too; the
	// live crash came from the handler being skipped there (PATCH.CONFIG empty, xr_combat_ignore.lua:206).
	CHECK_EQ(default_of("idiots_on_start"), Domain::Owner);
	CHECK(runs_here(default_of("idiots_on_start"), false));
	CHECK_EQ(Table().route("idiots_on_start", "some_mod_script"), Domain::Owner);

	// Names outside the intercepts table: the brief's prefixes, then owner.
	CHECK_EQ(default_of("actor_on_weapon_zoom_type_changed"), Domain::Owner); // monolith callbacks_gameobject.script
	CHECK_EQ(default_of("npc_on_custom_mod_event"), Domain::Host);
	CHECK_EQ(default_of("squad_on_register"), Domain::Host);
	CHECK_EQ(default_of("GUI_on_custom_window"), Domain::View);
	CHECK_EQ(default_of("on_key_custom"), Domain::View);
	CHECK_EQ(default_of("on_xml_read"), Domain::View); // modxml_core's callback, named by the brief
	CHECK_EQ(default_of("game_object_on_net_spawn"), Domain::Owner);
	CHECK_EQ(default_of(""), Domain::Owner);

	// unique_call / time_event: routed by the handler's script, owner by default.
	CHECK_EQ(default_of(kUniqueCall), Domain::Owner);
	CHECK_EQ(default_of(kTimeEvent), Domain::Owner);
	{
		Table t;
		t.add(script_rule("treasure_manager", Domain::Host));
		CHECK_EQ(t.route(kTimeEvent, "treasure_manager"), Domain::Host);
		CHECK_EQ(t.route(kUniqueCall, "unknown_mod"), Domain::Owner);
	}

	// Stock names whose group is not covered by a brief prefix.
	CHECK_EQ(default_of("on_level_changing"), Domain::Owner);          // Player
	CHECK_EQ(default_of("anomaly_on_before_activate"), Domain::Host);  // NPCs
	CHECK_EQ(default_of("burer_on_before_weapon_drop"), Domain::Host); // Mutants
	CHECK_EQ(default_of("on_try_respawn"), Domain::Host);              // smart_terrain.script
	CHECK_EQ(default_of("se_actor_on_STATE_Read"), Domain::Host);      // Server objects
	CHECK_EQ(default_of("map_spot_menu_add_property"), Domain::View);  // GUI
	CHECK_EQ(default_of("main_menu_on_init"), Domain::View);           // GUI
	CHECK_EQ(default_of("on_console_execute"), Domain::View);          // Technical
	CHECK_EQ(default_of("on_before_key_press"), Domain::View);         // Technical
	CHECK_EQ(default_of("on_game_load"), Domain::View);
	CHECK_EQ(default_of("on_pstor_save_all"), Domain::Host);           // Files
	CHECK_EQ(default_of("on_pstor_load_all"), Domain::View);           // Files
	CHECK_EQ(default_of("on_before_surge"), Domain::Host);             // Others
	CHECK_EQ(default_of("on_enemy_eval"), Domain::Host);
	CHECK_EQ(default_of("on_get_item_cost"), Domain::View);
	CHECK_EQ(default_of("bullet_on_hit"), Domain::View);

	// Names compare case-insensitively (an ltx reader may lowercase keys).
	CHECK_EQ(default_of("gui_on_show"), Domain::View);
	CHECK_EQ(default_of("NPC_ON_UPDATE"), Domain::Host);
}

// Every row of axr_main.script's intercepts (lines 49-233) has an explicit entry, and the entry agrees with its group.
TEST(routes_stock_matches_axr_main)
{
	const std::vector<StockEntry> stock = read_intercepts(axr_main_path());
	REQUIRE(stock.size() == 147);
	size_t commented = 0;
	for (const StockEntry& e : stock)
	{
		if (e.commented)
			++commented;
		Domain d = Domain::None;
		if (!stock_domain(e.name, d))
		{
			::t::report_failure(__FILE__, __LINE__, "no stock entry for " + e.name);
			continue;
		}
		CHECK_EQ(d, default_of(e.name));
		Domain want = d;
		if (e.group == "Player")
			want = Domain::Owner;
		else if (e.group == "NPCs" || e.group == "Mutants" || e.group == "Physical objects" || e.group == "Vehicles" ||
			e.group == "Squads" || e.group == "smart_terrain.script" || e.group == "Server objects")
			want = Domain::Host;
		else if (e.group == "GUI" || e.group == "Technical")
			want = Domain::View;
		else if (e.group == "Files")
			want = (e.name == "save_state" || e.name == "on_pstor_save_all") ? Domain::Host : Domain::View;
		else if (e.group == "Others")
			want = (e.name == "on_get_item_cost" || e.name == "bullet_on_hit") ? Domain::View : Domain::Host;
		else
			::t::report_failure(__FILE__, __LINE__, "unknown group '" + e.group + "' for " + e.name);
		if (d != want)
			::t::report_failure(__FILE__, __LINE__, e.name + " (" + e.group + "): " + domain_name(d) + " != " +
				domain_name(want));
	}
	CHECK_EQ(commented, size_t(7));
	// The table holds the 147 stock names plus on_xml_read, unique_call and time_event; nothing else.
	CHECK_EQ(stock_count(), size_t(150));
}

TEST(routes_precedence)
{
	Table t;
	t.add(script_rule("treasure_manager", Domain::Host));
	t.add(script_rule("surge_manager", Domain::Host));
	t.add(script_rule("debug_tools", Domain::None));
	t.add(callback_rule("actor_on_update", Domain::View));
	t.add(forced_rule("load_state", Domain::View));

	// A script beats the callback's default and the callback's ltx default.
	CHECK_EQ(t.route("actor_on_update", "treasure_manager"), Domain::Host);
	// The callback's ltx default beats default_of for scripts nobody listed.
	CHECK_EQ(t.route("actor_on_update", "unknown_mod"), Domain::View);
	CHECK_EQ(t.route("actor_on_item_use", "unknown_mod"), Domain::Owner);
	// A forced callback beats the script...
	CHECK_EQ(t.route("load_state", "surge_manager"), Domain::View);
	// ...but not a `none` script.
	CHECK_EQ(t.route("load_state", "debug_tools"), Domain::None);
	CHECK_EQ(t.route("actor_on_update", "debug_tools"), Domain::None);

	// A pair beats everything: the forced callback, the script, a `none` script.
	t.add(pair_rule("load_state", "surge_manager", Domain::Host));
	t.add(pair_rule("load_state", "debug_tools", Domain::View));
	t.add(pair_rule("actor_on_update", "treasure_manager", Domain::Owner));
	CHECK_EQ(t.route("load_state", "surge_manager"), Domain::Host);
	CHECK_EQ(t.route("load_state", "debug_tools"), Domain::View);
	CHECK_EQ(t.route("actor_on_update", "treasure_manager"), Domain::Owner);
	// The pair is only that pair.
	CHECK_EQ(t.route("save_state", "treasure_manager"), Domain::Host);
	CHECK_EQ(t.route("actor_on_first_update", "treasure_manager"), Domain::Host);

	// The live idiots_on_start failure: Useful Idiots' listeners live in illish\patches\xr_combat_ignore.lua & co, whose
	// base names are stock AI scripts listed as host, and a script rule beats the callback's owner default. Only a
	// forced callback (the old [callbacks_always]) brings them back to the client.
	t.add(script_rule("xr_combat_ignore", Domain::Host));
	CHECK_EQ(t.route("idiots_on_start", "xr_combat_ignore"), Domain::Host);
	t.add(forced_rule("idiots_on_start", Domain::View));
	CHECK_EQ(t.route("idiots_on_start", "xr_combat_ignore"), Domain::View);
	CHECK(runs_here(t.route("idiots_on_start", "xr_combat_ignore"), false));
	CHECK_EQ(t.route("npc_on_update", "xr_combat_ignore"), Domain::Host); // the script's other callbacks stay host

	// A later rule for the same key replaces the earlier one.
	t.add(script_rule("treasure_manager", Domain::View));
	CHECK_EQ(t.route("actor_on_first_update", "treasure_manager"), Domain::View);

	// Level is kept as level by the table (the router counts it); it behaves as host until F3a.
	t.add(script_rule("level_logic", Domain::Level));
	CHECK_EQ(t.route("actor_on_update", "level_logic"), Domain::Level);

	t.clear();
	CHECK_EQ(t.route("actor_on_update", "treasure_manager"), Domain::Owner);
	CHECK_EQ(t.route("load_state", "debug_tools"), Domain::View);
}

TEST(routes_prefix_longest)
{
	Table t;
	t.add(script_rule("ea_*", Domain::Owner));
	t.add(script_rule("ea_callbacks", Domain::View));
	t.add(script_rule("e*", Domain::Host));
	CHECK_EQ(t.route("npc_on_death_callback", "ea_callbacks"), Domain::View); // exact beats any prefix
	CHECK_EQ(t.route("npc_on_death_callback", "ea_other"), Domain::Owner);    // "ea_" is longer than "e"
	CHECK_EQ(t.route("actor_on_update", "eb_mod"), Domain::Host);
	CHECK_EQ(t.route("actor_on_update", "fa_mod"), Domain::Owner);            // no prefix: callback default
	CHECK_EQ(t.route("actor_on_update", "ea_"), Domain::Owner);               // a prefix matches itself
	CHECK_EQ(t.route("actor_on_update", "ea"), Domain::Host);                 // "ea" is shorter than "ea_"

	// Script names compare case-insensitively.
	t.add(script_rule("Treasure_Manager", Domain::Host));
	CHECK_EQ(t.route("actor_on_update", "treasure_manager"), Domain::Host);
	CHECK_EQ(t.route("actor_on_update", "EA_CALLBACKS"), Domain::View);
}

TEST(routes_parse)
{
	Domain d = Domain::Host;
	CHECK(parse_domain("host", d) && d == Domain::Host);
	CHECK(parse_domain("owner", d) && d == Domain::Owner);
	CHECK(parse_domain("view", d) && d == Domain::View);
	CHECK(parse_domain("none", d) && d == Domain::None);
	d = Domain::Host;
	CHECK(parse_domain("blocked", d) && d == Domain::None);
	CHECK(parse_domain("level", d) && d == Domain::Level);
	CHECK(parse_domain(" View ", d) && d == Domain::View);
	CHECK(!parse_domain("hots", d));
	CHECK(!parse_domain("", d));
	for (Domain each : {Domain::Host, Domain::Owner, Domain::View, Domain::None, Domain::Level})
		CHECK(parse_domain(domain_name(each), d) && d == each);

	// Scripts: a trailing * is a prefix; an unknown domain is an error naming the line, the rest still parses.
	std::vector<std::string> errors;
	const std::vector<Override> scripts = parse_section("route_scripts",
		Lines{{"treasure_manager", "host"}, {"ea_*", "owner"}, {"bad_one", "hots"}, {"debug_tools", "blocked"}},
		&errors);
	REQUIRE(scripts.size() == 3);
	CHECK_EQ(errors.size(), size_t(1));
	CHECK(mentions(errors, "bad_one"));
	CHECK(mentions(errors, "route_scripts"));
	CHECK(scripts[0].kind == Override::Script && scripts[0].script == "treasure_manager" && scripts[0].domain == Domain::Host);
	CHECK(scripts[1].kind == Override::Script && scripts[1].script == "ea_*" && scripts[1].domain == Domain::Owner);
	CHECK(scripts[2].script == "debug_tools" && scripts[2].domain == Domain::None);

	// Each section gives its kind.
	errors.clear();
	const std::vector<Override> cbs = parse_section("route_callbacks", Lines{{"actor_on_update", "view"}}, &errors);
	const std::vector<Override> forced = parse_section("route_callbacks_forced", Lines{{"load_state", "view"}}, &errors);
	const std::vector<Override> pairs = parse_section("route_pairs", Lines{{"load_state@surge_manager", "none"}}, &errors);
	CHECK(errors.empty());
	REQUIRE(cbs.size() == 1 && forced.size() == 1 && pairs.size() == 1);
	CHECK(cbs[0].kind == Override::Callback && cbs[0].callback == "actor_on_update" && cbs[0].domain == Domain::View);
	CHECK(forced[0].kind == Override::Forced && forced[0].callback == "load_state");
	CHECK(pairs[0].kind == Override::Pair && pairs[0].callback == "load_state" && pairs[0].script == "surge_manager" &&
		pairs[0].domain == Domain::None);

	// Malformed names are errors, not rules that never match.
	errors.clear();
	CHECK(parse_section("route_pairs", Lines{{"load_state", "view"}}, &errors).empty());     // no @
	CHECK(parse_section("route_pairs", Lines{{"@surge_manager", "view"}}, &errors).empty()); // no callback
	CHECK(parse_section("route_pairs", Lines{{"load_state@", "view"}}, &errors).empty());    // no script
	CHECK(parse_section("route_pairs", Lines{{"load_state@ea_*", "view"}}, &errors).empty()); // pairs are exact
	CHECK(parse_section("route_scripts", Lines{{"*", "view"}}, &errors).empty());            // would take every script
	CHECK(parse_section("route_scripts", Lines{{"", "view"}}, &errors).empty());
	CHECK(parse_section("route_callbacks", Lines{{"actor_*", "view"}}, &errors).empty());     // callbacks are exact
	CHECK(parse_section("route_callbacks_forced", Lines{{"a@b", "view"}}, &errors).empty());
	CHECK_EQ(errors.size(), size_t(8));

	// An unknown section is one error; a null error list is allowed.
	errors.clear();
	CHECK(parse_section("route_typo", Lines{{"x", "host"}}, &errors).empty());
	CHECK_EQ(errors.size(), size_t(1));
	CHECK(mentions(errors, "route_typo"));
	CHECK(parse_section("route_scripts", Lines{{"x", "nope"}}, nullptr).empty());

	// Parsed rules feed the table.
	Table t;
	for (const Override& o : parse_section("route_scripts", Lines{{"treasure_manager", "host"}}, nullptr))
		t.add(o);
	for (const Override& o : parse_section("route_callbacks", Lines{{"gui_on_show", "none"}}, nullptr))
		t.add(o);
	CHECK_EQ(t.route("actor_on_update", "treasure_manager"), Domain::Host);
	CHECK_EQ(t.route("GUI_on_show", "ui_mod"), Domain::None); // a lowercased ltx key still matches
}

TEST(routes_runs_here)
{
	CHECK(runs_here(Domain::Host, true));
	CHECK(!runs_here(Domain::Host, false));
	CHECK(runs_here(Domain::Level, true));
	CHECK(!runs_here(Domain::Level, false));
	CHECK(runs_here(Domain::Owner, true));
	CHECK(runs_here(Domain::Owner, false));
	CHECK(runs_here(Domain::View, true));
	CHECK(runs_here(Domain::View, false));
	CHECK(!runs_here(Domain::None, true));
	CHECK(!runs_here(Domain::None, false));
}
