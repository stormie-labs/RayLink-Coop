// Anomaly Coop unit tests: the call router's table and gate (xrCoop/coop_calls.h, F2 T12, MOD_LAYER.md §2.3).
// The engine half (coop_callgate.cpp: the object's owner, argument checks, ltx loading, the log) is compile-checked;
// its decisions are these pure functions.
#include "test_util.h"

#include "coop_calls.h"

#include <cstddef>
#include <cstdint>
#include <fstream>
#include <set>
#include <string>
#include <utility>
#include <vector>

using namespace coop::calls;

namespace
{
// tests\lua_exports.txt next to this source file: the engine functions Lua can call, written by
// tools/list_exports.py --write from the export sources (alife_simulator_script.cpp, script_game_object_script*.cpp,
// level_script.cpp).
std::string exports_path()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "tests/lua_exports.txt";
	here.resize(slash);
	return here + "/lua_exports.txt";
}

std::vector<std::string> read_exports()
{
	std::vector<std::string> out;
	std::ifstream in(exports_path());
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

// What a client does with `name` on a target that is or is not its own (the gate the engine asks).
Gate on_client(std::string_view name, bool own)
{
	return gate(class_of(name), true, own, has_request_path(name, own));
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
	for (const char* n : {"game_object:give_info_portion", "game_object:disable_info_portion", "game_object:set_relation",
			 "game_object:set_goodwill", "game_object:force_set_goodwill", "game_object:change_goodwill",
			 "game_object:set_community_goodwill", "relation_registry:set_community_goodwill",
			 "relation_registry:change_community_goodwill", "relation_registry:set_community_relation",
			 "level:change_game_time"})
	{
		CHECK(has_request_path(n, true));
		if (!has_request_path(n, false))
			::t::report_failure(__FILE__, __LINE__, std::string(n) + ": no path for another's target");
	}
	// ReqSpawn only for an item into our own inventory (client_forward_spawn): the parent is the target
	for (const char* n : {"alife:create", "alife:create_ammo", "alife:clone_weapon", "alife:register", "alife:release",
			 "game_object:transfer_item", "game_object:give_money"})
	{
		CHECK(has_request_path(n, true));
		if (has_request_path(n, false))
			::t::report_failure(__FILE__, __LINE__, std::string(n) + ": a path for another's target");
	}
	for (const char* n : {"alife:kill_entity", "alife:teleport_object", "level:set_weather", "game_object:kill",
			 "game_object:position", "no:such"})
		CHECK(!has_request_path(n, true));
	CHECK(has_request_path("ALIFE:Create", true));
	// every path is a world row of the table
	for (const RequestPath& p : kRequestPaths)
	{
		if (!has_row(p.name) || class_of(p.name) != CallClass::World)
			::t::report_failure(__FILE__, __LINE__, std::string(p.name) + ": a request path that is not a world row");
	}
}

// The minimal coverage of MOD_LAYER §2.3 / the brief: what a client does with each call.
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
		// read and view run everywhere
		{"game_object:position", Run, Run},
		{"level:add_pp_effector", Run, Run},
		{"alife:object", Run, Run},
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
		CHECK_EQ(gate(class_of(r.name), false, false, has_request_path(r.name, false)), Gate::Run);
	}
}

// Every engine function Lua can call has a row (tools/list_exports.py --check also checks it and that the list file
// is current), and every row is such a function.
TEST(calls_every_export_classified)
{
	const std::vector<std::string> exports = read_exports();
	REQUIRE(exports.size() >= 800); // 870 on 2026-10-23: alife 39, game_object 646, level 119, other modules 66
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
	CHECK_EQ(rows, exports.size());
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
	CHECK(seen.size() >= 800);
}

// coop_status: refused and requested calls, the ten most refused names, the first ten refusals logged.
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

	// the log takes the first kLoggedRefusals refusals since clear()
	Counters l;
	size_t logged = 0;
	for (size_t i = 0; i < Counters::kLoggedRefusals + 5; ++i)
		if (l.take_log_line())
			++logged;
	CHECK_EQ(logged, Counters::kLoggedRefusals);
	static_assert(Counters::kLoggedRefusals == 10, "the first 10 refusals are logged");

	// bounded: names past kMaxNames count in the totals only
	Counters b;
	for (size_t i = 0; i < Counters::kMaxNames + 3; ++i)
		b.note("ns:f" + std::to_string(i), Gate::Refuse);
	CHECK_EQ(b.totals().refused, uint64_t(Counters::kMaxNames + 3));
	CHECK_EQ(b.names_tracked(), Counters::kMaxNames);
	CHECK_EQ(b.names_dropped(), uint64_t(3));

	c.clear();
	CHECK_EQ(c.totals().refused, uint64_t(0));
	CHECK_EQ(c.top_refused(10).size(), size_t(0));
	CHECK(c.take_log_line());
}
