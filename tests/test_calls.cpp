// Anomaly Coop unit tests: the call router's table and gate (xrCoop/coop_calls.h, F2 T12, MOD_LAYER.md §2.3).
// The engine half (coop_callgate.cpp: the object's owner, the applying flags, ltx loading, the log) is compile-checked;
// its decisions are these pure functions (decide, the own_* rules of the call sites).
#include "test_util.h"

#include "coop_calls.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <set>
#include <string>
#include <utility>
#include <vector>

using namespace coop::calls;

namespace
{
// The repository root: tests\ is next to this source file.
std::string repo_root()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return ".";
	here.resize(slash); // ...\tests
	return here + "/..";
}

// tests\lua_exports.txt: the engine exports Lua can reach, written by tools/list_exports.py --write from the export
// sources (alife, game_object, level_script.cpp modules, CCar, CHelicopter, CPhysicObject, CConsole, hanging_lamp,
// CZoneCampfire, the cse_* server objects ...).
std::vector<std::string> read_exports()
{
	std::vector<std::string> out;
	std::ifstream in(repo_root() + "/tests/lua_exports.txt");
	std::string line;
	while (std::getline(in, line))
	{
		if (!line.empty() && line.back() == '\r')
			line.pop_back();
		if (line.empty() || line[0] == '#')
			continue;
		out.push_back(line);
	}
	return out;
}

// What a client in the host's world does with `name` on a target that is or is not its own (the gate the engine asks,
// outside a host command, with good arguments).
Gate on_client(std::string_view name, bool own)
{
	return decide(class_of(name), true, false, own, has_request_path(name, own), true);
}

std::string lower(std::string s)
{
	for (char& c : s)
		if (c >= 'A' && c <= 'Z')
			c = char(c - 'A' + 'a');
	return s;
}
} // namespace

TEST(calls_class_of)
{
	CHECK_EQ(class_of("alife:create"), CallClass::World);
	CHECK_EQ(class_of("game_object:position"), CallClass::Read);
	CHECK_EQ(class_of("level:add_pp_effector"), CallClass::View);
	CHECK_EQ(class_of("game_object:give_money"), CallClass::World);
	CHECK_EQ(class_of("game_object:change_health"), CallClass::Owner);
	// unknown: a modded exe's export, a typo, no namespace, nothing
	CHECK_EQ(class_of("game_object:no_such_function"), CallClass::Read);
	CHECK_EQ(class_of("give_money"), CallClass::Read);
	CHECK_EQ(class_of(""), CallClass::Read);
	// letter case does not matter: an ltx reader may lowercase keys, and the engine has GetBulletCheckVisual
	CHECK_EQ(class_of("GAME_OBJECT:Give_Money"), CallClass::World);
	CHECK_EQ(class_of("game_object:setbulletcheckvisual"), CallClass::World);
	CHECK(has_row("level:set_weather"));
	CHECK(!has_row("level:no_such_function"));
	// review round 1: properties, other classes, reclassified rows
	CHECK_EQ(class_of("game_object:health"), CallClass::Owner);
	CHECK_EQ(class_of("game_object:bleeding"), CallClass::Owner);
	CHECK_EQ(class_of("game_object:affect_cover"), CallClass::Read);
	CHECK_EQ(class_of("game_object:use"), CallClass::View);
	CHECK_EQ(class_of("weather:set_value_numric"), CallClass::View);
	CHECK_EQ(class_of("level:patrol_path_add"), CallClass::View);
	CHECK_EQ(class_of("game_object:play_cycle"), CallClass::View);
	CHECK_EQ(class_of("game_object:buy_condition"), CallClass::View);
	CHECK_EQ(class_of("CCar:SetfHealth"), CallClass::World);
	CHECK_EQ(class_of("CHelicopter:GetfHealth"), CallClass::Read);
	CHECK_EQ(class_of("CZoneCampfire:turn_on"), CallClass::World);
	CHECK_EQ(class_of("hanging_lamp:turn_off"), CallClass::World);
	CHECK_EQ(class_of("CConsole:execute"), CallClass::World);
	CHECK_EQ(class_of("_G:get_console"), CallClass::Read);
	CHECK_EQ(class_of("cse_abstract:position"), CallClass::World);
	CHECK_EQ(class_of("cse_alife_object:online"), CallClass::Read);
}

// The virtual methods a server object class gets from its luabind_class_* macro: one rule for every cse_* class
// (kMacroVirtuals), an exact row wins, other namespaces never get them.
TEST(calls_macro_virtuals)
{
	CHECK_EQ(class_of("cse_alife_item_weapon:switch_online"), CallClass::World);
	CHECK_EQ(class_of("CSE_ALIFE_ITEM:STATE_Write"), CallClass::Read);
	CHECK_EQ(class_of("cse_alife_creature_actor:on_register"), CallClass::World);
	CHECK_EQ(class_of("cse_alife_monster_base:g_team"), CallClass::Read);
	CHECK(has_row("cse_alife_trader:STATE_Read"));
	CHECK(has_row("CSE_AbstractVisual:init"));
	// an exact row wins: cse_alife_object's can_switch_online has a setter overload
	CHECK_EQ(class_of("cse_alife_object:can_switch_online"), CallClass::World);
	CHECK_EQ(class_of("cse_alife_item:can_switch_online"), CallClass::Read);
	// not a server object: no virtuals
	CHECK(!has_row("CCar:switch_online"));
	CHECK_EQ(class_of("game_object:STATE_Read"), CallClass::Read);
	CHECK(!has_row("cse_alife_item:no_such_virtual"));
	// every macro virtual has one entry
	std::set<std::string> seen;
	for (const Call& v : kMacroVirtuals)
		if (!seen.insert(lower(std::string(v.name))).second)
			::t::report_failure(__FILE__, __LINE__, "two kMacroVirtuals entries: " + std::string(v.name));
	CHECK(seen.size() >= 25);
}

// 4 classes x host/client x own/another's target x request path or not. Host: everything runs. Client: read and view
// run; owner runs on its own target and is a world call on another's; a world call becomes a request where the engine
// has a path to the host, else it is refused.
TEST(calls_gate_matrix)
{
	struct Row
	{
		CallClass cls;
		bool client, own, path;
		Gate expect;
	};
	const CallClass W = CallClass::World, O = CallClass::Owner, V = CallClass::View, R = CallClass::Read;
	const Gate Run = Gate::Run, Req = Gate::Request, No = Gate::Refuse;
	static const Row rows[] = {
		// host
		{W, false, false, false, Run}, {W, false, false, true, Run}, {W, false, true, false, Run}, {W, false, true, true, Run},
		{O, false, false, false, Run}, {O, false, false, true, Run}, {O, false, true, false, Run}, {O, false, true, true, Run},
		{V, false, false, false, Run}, {V, false, false, true, Run}, {V, false, true, false, Run}, {V, false, true, true, Run},
		{R, false, false, false, Run}, {R, false, false, true, Run}, {R, false, true, false, Run}, {R, false, true, true, Run},
		// client
		{W, true, false, false, No}, {W, true, false, true, Req}, {W, true, true, false, No}, {W, true, true, true, Req},
		{O, true, false, false, No}, {O, true, false, true, Req}, {O, true, true, false, Run}, {O, true, true, true, Run},
		{V, true, false, false, Run}, {V, true, false, true, Run}, {V, true, true, false, Run}, {V, true, true, true, Run},
		{R, true, false, false, Run}, {R, true, false, true, Run}, {R, true, true, false, Run}, {R, true, true, true, Run},
	};
	static_assert(sizeof(rows) / sizeof(rows[0]) == 32, "4 classes x 2 machines x 2 targets x 2 paths");
	for (const Row& r : rows)
	{
		const Gate g = gate(r.cls, r.client, r.own, r.path);
		if (g != r.expect)
			::t::report_failure(__FILE__, __LINE__,
				std::string("gate(") + class_name(r.cls) + (r.client ? ", client" : ", host") + (r.own ? ", own" : ", another's") +
					(r.path ? ", path" : ", no path") + ") = " + gate_name(g) + ", expected " + gate_name(r.expect));
	}
}

// The whole decision of the engine's gate (callgate decide): a client in the host's world only; a host command being
// applied runs (our mirrors call world functions); bad arguments are refused on a client even then; else the matrix.
TEST(calls_decide)
{
	struct Row
	{
		CallClass cls;
		bool client, applying, own, path, args_ok;
		Gate expect;
		const char* what;
	};
	const CallClass W = CallClass::World, O = CallClass::Owner, V = CallClass::View;
	const Gate Run = Gate::Run, Req = Gate::Request, No = Gate::Refuse;
	static const Row rows[] = {
		{W, false, false, false, false, false, Run, "host: bad arguments are the host's own"},
		{W, false, true, false, false, true, Run, "host"},
		{W, true, false, false, false, true, No, "world, no path"},
		{W, true, true, false, false, true, Run, "world while a host command is applied"},
		{W, true, true, false, true, true, Run, "world with a path while applying: the engine code runs"},
		{W, true, false, true, true, true, Req, "world with a path"},
		{W, true, false, true, true, false, No, "a NaN never goes to the host"},
		{W, true, true, true, true, false, No, "a NaN is refused while applying too"},
		{O, true, false, true, false, true, Run, "own"},
		{O, true, false, true, false, false, No, "own with a NaN position"},
		{O, true, false, false, false, true, No, "another's creature"},
		{O, true, true, false, false, true, Run, "another's creature while applying"},
		{V, true, false, false, false, true, Run, "view"},
		{V, true, false, false, false, false, No, "view with a bad argument"},
	};
	for (const Row& r : rows)
	{
		const Gate g = decide(r.cls, r.client, r.applying, r.own, r.path, r.args_ok);
		if (g != r.expect)
			::t::report_failure(__FILE__, __LINE__,
				std::string(r.what) + ": " + gate_name(g) + ", expected " + gate_name(r.expect));
	}
}

// The "own target" of each gated call site (engine code passes these to client_gate_own).
TEST(calls_own_rules)
{
	// transfer_item / take_item: our actor on one side (the item is ours or it comes to us: Ruling F2-30)
	CHECK(own_move(true, false));
	CHECK(own_move(false, true));
	CHECK(own_move(true, true));
	CHECK(!own_move(false, false));
	// alife:create / clone_weapon: register now only into our inventory; a temporary object passes (its register is
	// gated), so create(..., false) keeps returning the temporary object as before
	CHECK(own_spawn(true, true));
	CHECK(!own_spawn(true, false));
	CHECK(own_spawn(false, false));
	CHECK(own_spawn(false, true));
	// alife:release: an item under our actor, never our actor itself
	CHECK(own_release(false, true));
	CHECK(!own_release(true, true));
	CHECK(!own_release(false, false));
	// destroy_object: as the event router (on_destroy): ours or a free item go to the host, an object outside the host's
	// world is local; anything else is the host's
	CHECK(own_destroy(true, true, false));
	CHECK(own_destroy(true, false, true));
	CHECK(own_destroy(false, false, false));
	CHECK(!own_destroy(true, false, false));
}

// [call_classes] lines of coop_route*.ltx / coop_compat_*.ltx: `namespace:function = class`.
TEST(calls_parse_override)
{
	std::vector<std::string> errors;
	const std::vector<Override> rules = parse_overrides(
		{
			{"game_object:give_money", "world"},
			{" level:set_weather ", " View "},
			{"alife:create", "host"},          // a callback domain, not a call class
			{"alife:release", ""},             // no class
			{"give_money", "read"},            // no namespace
			{"game_object:", "read"},          // no function
			{":kill", "read"},                 // no namespace
			{"a:b:c", "read"},                 // two colons
			{"game_object:my func", "read"},   // a blank inside
			{"game_object:my_new_export", "OWNER"}, // a function the table does not know (a modded exe)
		},
		&errors);
	REQUIRE(rules.size() == 3);
	CHECK(rules[0].name == "game_object:give_money");
	CHECK_EQ(rules[0].cls, CallClass::World);
	CHECK(rules[1].name == "level:set_weather");
	CHECK_EQ(rules[1].cls, CallClass::View);
	CHECK(rules[2].name == "game_object:my_new_export");
	CHECK_EQ(rules[2].cls, CallClass::Owner);
	REQUIRE(errors.size() == 7);
	CHECK(errors[0].find("alife:create") != std::string::npos);
	CHECK(errors[0].find("unknown class") != std::string::npos);
	CHECK(errors[1].find("unknown class") != std::string::npos);
	for (size_t i = 2; i < errors.size(); ++i)
		CHECK(errors[i].find("expected namespace:function") != std::string::npos);
	// the error list is optional
	CHECK_EQ(parse_overrides({{"x", "y"}}, nullptr).size(), size_t(0));

	CallClass c = CallClass::Read;
	CHECK(parse_class("world", c) && c == CallClass::World);
	CHECK(parse_class(" Owner\t", c) && c == CallClass::Owner);
	CHECK(parse_class("VIEW", c) && c == CallClass::View);
	CHECK(parse_class("read", c) && c == CallClass::Read);
	CHECK(!parse_class("blocked", c));
	CHECK(!parse_class("", c));

	// the table with overrides: an override wins, a later one replaces an earlier one, letter case does not matter
	Classes classes;
	for (const Override& o : rules)
		classes.add(o);
	CHECK_EQ(classes.size(), size_t(3));
	CHECK_EQ(classes.class_of("level:set_weather"), CallClass::View);
	CHECK_EQ(classes.class_of("LEVEL:Set_Weather"), CallClass::View);
	CHECK_EQ(classes.class_of("game_object:my_new_export"), CallClass::Owner);
	CHECK_EQ(classes.class_of("game_object:position"), CallClass::Read); // no override: the table
	CHECK_EQ(classes.class_of("alife:kill_entity"), CallClass::World);
	CHECK_EQ(classes.class_of("game_object:unknown_too"), CallClass::Read);
	CHECK_EQ(classes.class_of("cse_alife_item:switch_online"), CallClass::World); // the macro virtual rule
	CHECK(classes.overridden("level:set_weather"));
	CHECK(!classes.overridden("alife:kill_entity"));
	classes.add({"level:set_weather", CallClass::World});
	CHECK_EQ(classes.class_of("level:set_weather"), CallClass::World);
	CHECK_EQ(classes.size(), size_t(3));
	classes.clear();
	CHECK_EQ(classes.class_of("level:set_weather"), CallClass::World);
	CHECK_EQ(classes.size(), size_t(0));
}

// The client paths that exist in the engine (MOD_LAYER §2.3). A path for own targets only is no path for another's.
TEST(calls_request_paths)
{
	// a path whatever the target (for infos and relations: the story forwards our actor's infos and relations with a
	// player; with an NPC alone the call stays in this machine's mirror, counted as requested)
	for (const char* n : {"game_object:give_info_portion", "game_object:disable_info_portion", "game_object:set_relation",
			 "game_object:set_goodwill", "game_object:force_set_goodwill", "game_object:change_goodwill",
			 "game_object:set_community_goodwill", "relation_registry:set_community_goodwill",
			 "relation_registry:change_community_goodwill", "relation_registry:set_community_relation",
			 "level:change_game_time", "game_object:give_task", "game_object:set_task_state"})
	{
		CHECK(has_request_path(n, true));
		if (!has_request_path(n, false))
			::t::report_failure(__FILE__, __LINE__, std::string(n) + ": no path for another's target");
	}
	// a path for our own target only (ReqSpawn into our inventory, client_destroy, ReqTransfer, the money journal, the
	// story path of our actor's infos)
	for (const char* n : {"alife:create", "alife:create_ammo", "alife:clone_weapon", "alife:register", "alife:release",
			 "alife:give_info", "alife:disable_info", "game_object:transfer_item", "game_object:take_item",
			 "game_object:give_money", "game_object:transfer_money", "game_object:destroy_object", "level:spawn_item"})
	{
		CHECK(has_request_path(n, true));
		if (has_request_path(n, false))
			::t::report_failure(__FILE__, __LINE__, std::string(n) + ": a path for another's target");
	}
	for (const char* n : {"alife:kill_entity", "alife:teleport_object", "level:set_weather", "game_object:kill",
			 "game_object:position", "alife:set_interactive", "level:set_game_difficulty", "level:spawn_phantom",
			 "game_object:buy_supplies", "game_object:enable_level_changer", "no:such"})
		CHECK(!has_request_path(n, true));
	CHECK(has_request_path("ALIFE:Create", true));
	// every path is a world row of the table
	for (const RequestPath& p : kRequestPaths)
	{
		if (!has_row(p.name) || class_of(p.name) != CallClass::World)
			::t::report_failure(__FILE__, __LINE__, std::string(p.name) + ": a request path that is not a world row");
	}
}

// What a client does with each gated call (MOD_LAYER §2.3 minimal coverage, review round 1 additions).
TEST(calls_minimal_coverage)
{
	struct Row
	{
		const char* name;
		Gate own, others;
	};
	const Gate Run = Gate::Run, Req = Gate::Request, No = Gate::Refuse;
	static const Row rows[] = {
		{"alife:create", Req, No}, // ReqSpawn into our own inventory; a world spawn is the host's
		{"alife:create_ammo", Req, No},
		{"alife:register", Req, No},
		{"alife:clone_weapon", Req, No},
		{"alife:release", Req, No}, // client_destroy of an own item
		{"alife:kill_entity", No, No},
		{"alife:teleport_object", No, No},
		{"alife:set_switch_online", No, No},
		{"alife:set_switch_offline", No, No},
		{"game_object:give_info_portion", Req, Req}, // story
		{"game_object:disable_info_portion", Req, Req},
		{"game_object:transfer_item", Req, No}, // ReqTransfer
		{"game_object:give_money", Req, No},    // our actor: the journal; an NPC: refused
		{"game_object:set_relation", Req, Req}, // story Relation
		{"game_object:set_goodwill", Req, Req},
		{"game_object:change_goodwill", Req, Req},
		{"game_object:set_community_goodwill", Req, Req},
		{"game_object:kill", Run, No},
		{"game_object:set_npc_position", Run, No},
		{"level:set_weather", No, No},
		{"level:set_weather_fx", No, No},
		{"level:set_weather_smooth", No, No},
		{"level:set_weather_weight", No, No},
		{"level:start_weather_fx_from_time", No, No},
		{"level:stop_weather_fx", No, No},
		{"level:change_game_time", Req, Req}, // TimeRequest
		{"game_object:attach_vehicle", No, No}, // a car (the engine asks only for cars)
		// review round 1
		{"alife:give_info", Req, No}, // our actor (id 0): the story path; another's registry: refused
		{"alife:disable_info", Req, No},
		{"alife:set_interactive", No, No},
		{"alife:add_in_restriction", No, No},
		{"alife:add_out_restriction", No, No},
		{"alife:remove_in_restriction", No, No},
		{"alife:remove_out_restriction", No, No},
		{"alife:remove_all_restrictions", No, No},
		{"game_object:transfer_money", Req, No}, // our actor pays: the journal; else refused
		{"game_object:take_item", Req, No},      // as transfer_item
		{"game_object:enable_level_changer", No, No},
		{"level:set_game_difficulty", No, No},
		{"game_object:health", Run, No}, // our actor's needs run; another's creature: refused
		{"game_object:psy_health", Run, No},
		{"game_object:power", Run, No},
		{"game_object:satiety", Run, No},
		{"game_object:radiation", Run, No},
		{"game_object:morale", Run, No},
		{"game_object:bleeding", Run, No},
		{"game_object:change_health", Run, No},
		{"game_object:change_psy_health", Run, No}, // round 2 (R1-M1)
		{"game_object:change_power", Run, No},
		{"game_object:change_satiety", Run, No},
		{"game_object:change_radiation", Run, No},
		{"game_object:change_morale", Run, No},
		{"game_object:set_health_ex", Run, No},
		{"level:spawn_item", Req, No},          // as alife:create (filter_spawn)
		{"level:spawn_phantom", No, No},        // a world spawn
		{"game_object:buy_supplies", No, No},   // a trader's stock
		{"game_object:destroy_object", Req, No}, // as the event router's on_destroy
		// read and view run everywhere
		{"game_object:position", Run, Run},
		{"level:add_pp_effector", Run, Run},
		{"alife:object", Run, Run},
		{"game_object:use", Run, Run},
	};
	for (const Row& r : rows)
	{
		REQUIRE(has_row(r.name));
		const Gate own = on_client(r.name, true), others = on_client(r.name, false);
		if (own != r.own || others != r.others)
			::t::report_failure(__FILE__, __LINE__,
				std::string(r.name) + ": own " + gate_name(own) + ", another's " + gate_name(others) + "; expected " +
					gate_name(r.own) + ", " + gate_name(r.others));
		// the host runs every one of them
		CHECK_EQ(decide(class_of(r.name), false, false, false, has_request_path(r.name, false), true), Gate::Run);
	}
}

// Every engine export Lua can reach (tests/lua_exports.txt) is classified: a row, or a server object's macro virtual.
// Every row is such an export.
TEST(calls_every_export_classified)
{
	const std::vector<std::string> exports = read_exports();
	REQUIRE(exports.size() >= 2000); // 2029 on 2026-10-23: 864 of them server-object macro virtuals
	std::set<std::string> listed;
	for (const std::string& n : exports)
	{
		listed.insert(lower(n));
		if (!has_row(n))
			::t::report_failure(__FILE__, __LINE__, "unclassified export: " + n);
	}
	size_t rows = 0;
	for (const Call& c : kCalls)
	{
		++rows;
		if (!listed.count(lower(std::string(c.name))))
			::t::report_failure(__FILE__, __LINE__, "a row for no export: " + std::string(c.name));
	}
	CHECK(rows >= 1100);
}

// tools/list_exports.py --check on the live sources: a new export of the engine (a method, a field, a property) that
// has no row fails the unit tests, not only a later run of the script by hand (review M3).
TEST(calls_export_list_is_live)
{
	const std::string cmd = "python -I \"" + repo_root() + "/tools/list_exports.py\" --check 2>&1";
	FILE* p = _popen(cmd.c_str(), "r");
	REQUIRE(p != nullptr);
	std::string out;
	char buf[512];
	while (fgets(buf, sizeof(buf), p))
		out += buf;
	const int rc = _pclose(p);
	if (rc != 0)
		::t::report_failure(__FILE__, __LINE__,
			"tools/list_exports.py --check exit " + std::to_string(rc) +
				(rc == 9009 ? " (python is not on PATH)" : "") + ":\n" + out);
	CHECK(out.find(" 0 problem(s)") != std::string::npos);
}

// One row per name, each `namespace:function`.
TEST(calls_table_rows_unique)
{
	std::set<std::string> seen;
	for (const Call& c : kCalls)
	{
		const std::string n(c.name);
		const size_t colon = n.find(':');
		if (colon == std::string::npos || colon == 0 || colon + 1 == n.size() || n.find(':', colon + 1) != std::string::npos)
			::t::report_failure(__FILE__, __LINE__, "not namespace:function: " + n);
		if (!seen.insert(lower(n)).second)
			::t::report_failure(__FILE__, __LINE__, "two rows: " + n);
	}
	CHECK(seen.size() >= 1100);
}

// coop_status: refused and requested calls, the ten most refused names; the log: the first refusals of each name.
TEST(calls_counters)
{
	Counters c;
	for (int i = 0; i < 3; ++i)
		c.note("level:set_weather", Gate::Refuse);
	c.note("alife:teleport_object", Gate::Refuse);
	c.note("alife:create", Gate::Request);
	c.note("alife:create", Gate::Request);
	c.note("game_object:kill", Gate::Run);
	CHECK_EQ(c.totals().refused, uint64_t(4));
	CHECK_EQ(c.totals().requested, uint64_t(2));
	CHECK_EQ(c.totals().ran, uint64_t(1));
	const std::vector<std::pair<std::string, uint64_t>> top = c.top_refused(10);
	REQUIRE(top.size() == 2);
	CHECK(top[0].first == "level:set_weather");
	CHECK_EQ(top[0].second, uint64_t(3));
	CHECK(top[1].first == "alife:teleport_object");
	CHECK_EQ(c.top_refused(1).size(), size_t(1));
	// a tie: by name
	c.note("alife:kill_entity", Gate::Refuse);
	const std::vector<std::pair<std::string, uint64_t>> tie = c.top_refused(10);
	REQUIRE(tie.size() == 3);
	CHECK(tie[1].first == "alife:kill_entity");
	CHECK(tie[2].first == "alife:teleport_object");

	// the log: the first kLoggedPerName refusals of each name since clear(); a noisy name does not hide another
	static_assert(Counters::kLoggedPerName == 10, "the first 10 refusals of a name are logged");
	Counters l;
	size_t weather = 0, kill = 0;
	for (size_t i = 0; i < Counters::kLoggedPerName + 5; ++i)
	{
		l.note("level:set_weather", Gate::Refuse);
		if (l.take_log_line("level:set_weather"))
			++weather;
	}
	l.note("alife:kill_entity", Gate::Refuse);
	if (l.take_log_line("alife:kill_entity"))
		++kill;
	CHECK_EQ(weather, Counters::kLoggedPerName);
	CHECK_EQ(kill, size_t(1));
	CHECK_EQ(l.logged("level:set_weather"), Counters::kLoggedPerName);
	CHECK_EQ(l.logged("alife:kill_entity"), size_t(1));
	CHECK_EQ(l.logged("no:refusal_noted"), size_t(0));
	CHECK(!l.take_log_line("no:refusal_noted")); // a name with no refusal has nothing to log

	// bounded: names past kMaxNames count in the totals only (and are not logged)
	Counters b;
	for (size_t i = 0; i < Counters::kMaxNames + 3; ++i)
		b.note("ns:f" + std::to_string(i), Gate::Refuse);
	CHECK_EQ(b.totals().refused, uint64_t(Counters::kMaxNames + 3));
	CHECK_EQ(b.names_tracked(), Counters::kMaxNames);
	CHECK_EQ(b.names_dropped(), uint64_t(3));
	CHECK(!b.take_log_line("ns:f" + std::to_string(Counters::kMaxNames + 1)));

	c.clear();
	CHECK_EQ(c.totals().refused, uint64_t(0));
	CHECK_EQ(c.top_refused(10).size(), size_t(0));
	c.note("level:set_weather", Gate::Refuse);
	CHECK(c.take_log_line("level:set_weather"));
}
