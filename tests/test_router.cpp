// Anomaly Coop unit tests: the pure half of the callback router (coop_routes.h script keys and counters, F2 T10).
// The engine half (coop_router.cpp: ltx loading, the Lua API) is covered by tests/lua/test_route_shim.lua.
#include "test_util.h"

#include "coop_routes.h"

#include <string>
#include <utility>
#include <vector>

using namespace coop::routes;

// A .script is keyed by its base name; a .lua by its path under the scripts folder with dots (live bug 2026-10-23:
// GAMMA's illish\patches\xr_combat_ignore.lua was taken for the stock host-only xr_combat_ignore).
TEST(router_script_key)
{
	CHECK_EQ(script_key("@D:\\Games\\Anomaly\\gamedata\\scripts\\xr_combat_ignore.script"), std::string("xr_combat_ignore"));
	CHECK_EQ(script_key("@.\\gamedata\\scripts\\illish\\patches\\xr_combat_ignore.lua"),
		std::string("illish.patches.xr_combat_ignore"));
	CHECK(script_key("@D:\\Games\\Anomaly\\gamedata\\scripts\\xr_combat_ignore.script") !=
		script_key("@E:\\AnomalyCoopGamma\\gamedata\\scripts\\illish\\patches\\xr_combat_ignore.lua"));
	CHECK_EQ(script_key("@..\\gamedata\\scripts\\illish\\lib\\util.lua"), std::string("illish.lib.util"));
	CHECK_EQ(script_key("@E:/Games/GAMMA/gamedata/scripts/illish/patches/utils_obj.lua"),
		std::string("illish.patches.utils_obj"));
	// letter case and the separators do not matter
	CHECK_EQ(script_key("@D:\\Games\\Anomaly\\GameData\\Scripts\\Coop_Main.SCRIPT"), std::string("coop_main"));
	// a .lua in the scripts root is its name, like a .script
	CHECK_EQ(script_key("@.\\gamedata\\scripts\\global.lua"), std::string("global"));
	// the last "\gamedata\scripts\" counts; without one the last "\scripts\"; without both the relative path
	CHECK_EQ(script_key("@C:\\scripts\\games\\gamedata\\scripts\\mymod\\scripts\\x.lua"),
		std::string("mymod.scripts.x"));
	CHECK_EQ(script_key("@C:\\mods\\scripts\\mymod\\x.lua"), std::string("mymod.x"));
	CHECK_EQ(script_key("@scripts\\mymod\\x.lua"), std::string("mymod.x"));
	CHECK_EQ(script_key("@.\\illish\\patches\\rx_ff.lua"), std::string("illish.patches.rx_ff"));
	CHECK_EQ(script_key("@C:\\elsewhere\\x.lua"), std::string("elsewhere.x"));
	CHECK_EQ(script_key("x.lua"), std::string("x"));
	// a .script in a folder is still its name (the engine loads scripts by name)
	CHECK_EQ(script_key("@C:\\a\\b\\some_mod.script"), std::string("some_mod"));
	// no file: unknown
	CHECK_EQ(script_key("=[C]"), std::string("?"));
	CHECK_EQ(script_key("@console_command"), std::string("?"));
	CHECK_EQ(script_key("return function() end"), std::string("?"));
	CHECK_EQ(script_key(""), std::string("?"));
	CHECK_EQ(script_key("@.script"), std::string("?"));
	CHECK_EQ(script_key("@D:\\gamedata\\scripts\\.lua"), std::string("?"));
}

// The point of path keys: a stock rule does not reach a mod's file of the same name.
TEST(router_script_key_rules)
{
	Table t;
	t.add(Override{Override::Script, "", "xr_combat_ignore", Domain::Host});
	t.add(Override{Override::Script, "", "utils_*", Domain::View});
	t.add(Override{Override::Script, "", "illish.patches.surge_manager", Domain::Host});
	const std::string stock = script_key("@D:\\Games\\Anomaly\\gamedata\\scripts\\xr_combat_ignore.script");
	const std::string patch = script_key("@.\\gamedata\\scripts\\illish\\patches\\xr_combat_ignore.lua");
	CHECK_EQ(t.route("actor_on_update", stock), Domain::Host);
	CHECK_EQ(t.route("actor_on_update", patch), Domain::Owner); // the callback's default
	CHECK_EQ(t.route("npc_on_hit_callback", patch), Domain::Host);
	CHECK_EQ(t.route("GUI_on_show", script_key("@.\\gamedata\\scripts\\utils_obj.lua")), Domain::View);
	CHECK_EQ(t.route("actor_on_update", script_key("@.\\gamedata\\scripts\\illish\\patches\\utils_obj.lua")),
		Domain::Owner); // utils_* does not catch illish.patches.utils_obj
	CHECK_EQ(t.route("actor_on_first_update", script_key("@.\\gamedata\\scripts\\illish\\patches\\surge_manager.lua")),
		Domain::Host);
}

TEST(router_outcome_parse)
{
	Outcome o = Outcome::Ran;
	CHECK(parse_outcome("ran", o) && o == Outcome::Ran);
	CHECK(parse_outcome("skipped", o) && o == Outcome::Skipped);
	CHECK(parse_outcome(" Error ", o) && o == Outcome::Error);
	CHECK(!parse_outcome("run", o));
	CHECK(!parse_outcome("", o));
}

TEST(router_counters)
{
	Counters c;
	c.note(Domain::Host, Outcome::Skipped, "treasure_manager");
	c.note(Domain::Host, Outcome::Skipped, "treasure_manager");
	c.note(Domain::Host, Outcome::Skipped, "death_manager");
	c.note(Domain::Owner, Outcome::Ran, "");
	c.note(Domain::Owner, Outcome::Ran, "");
	c.note(Domain::Owner, Outcome::Error, "actor_effects");
	c.note(Domain::None, Outcome::Skipped, "cheat_menu");
	CHECK_EQ(c.totals(Domain::Host).skipped, uint64_t(3));
	CHECK_EQ(c.totals(Domain::Host).ran, uint64_t(0));
	CHECK_EQ(c.totals(Domain::Owner).ran, uint64_t(2));
	CHECK_EQ(c.totals(Domain::Owner).errors, uint64_t(1));
	CHECK_EQ(c.totals(Domain::None).skipped, uint64_t(1));
	CHECK_EQ(c.totals(Domain::View).ran, uint64_t(0));

	// most skips first, a tie by name; at most n
	const std::vector<std::pair<std::string, uint64_t>> top = c.top_skipped(10);
	CHECK_EQ(top.size(), size_t(3));
	if (top.size() == 3)
	{
		CHECK_EQ(top[0].first, std::string("treasure_manager"));
		CHECK_EQ(top[0].second, uint64_t(2));
		CHECK_EQ(top[1].first, std::string("cheat_menu"));
		CHECK_EQ(top[2].first, std::string("death_manager"));
	}
	CHECK_EQ(c.top_skipped(1).size(), size_t(1));
	CHECK_EQ(c.top_skipped(0).size(), size_t(0));

	// a skip without a script name counts in the domain only
	c.note(Domain::Host, Outcome::Skipped, "");
	CHECK_EQ(c.totals(Domain::Host).skipped, uint64_t(4));
	CHECK_EQ(c.top_skipped(10).size(), size_t(3));

	c.clear();
	CHECK_EQ(c.totals(Domain::Host).skipped, uint64_t(0));
	CHECK_EQ(c.totals(Domain::Owner).ran, uint64_t(0));
	CHECK_EQ(c.top_skipped(10).size(), size_t(0));
}

// The per-pair table is bounded: pairs past the limit only count in the domain totals.
TEST(router_counters_bounded)
{
	Counters c;
	for (size_t i = 0; i < Counters::kMaxPairs + 50; ++i)
		c.note(Domain::Host, Outcome::Skipped, "script_" + std::to_string(i));
	CHECK_EQ(c.totals(Domain::Host).skipped, uint64_t(Counters::kMaxPairs + 50));
	CHECK_EQ(c.pairs_tracked(), Counters::kMaxPairs);
	CHECK_EQ(c.pairs_dropped(), uint64_t(50));
	c.note(Domain::Host, Outcome::Skipped, "script_0"); // a known name still counts
	const std::vector<std::pair<std::string, uint64_t>> top = c.top_skipped(1);
	CHECK(top.size() == 1 && top[0].first == "script_0" && top[0].second == 2);
	c.note(Domain::Host, Outcome::Skipped, "script_0", "actor_on_update"); // a new pair of a known script: no room
	CHECK_EQ(c.pairs_dropped(), uint64_t(51));
}

// Review M2: skips are kept per (callback, script) pair, named like a [route_pairs] key. A handler skipped every frame
// tops "most skipped"; a rare one (a use, a key) shows in "latest new skips", the pairs skipped for the first time last.
TEST(router_counters_pairs)
{
	Counters c;
	for (int i = 0; i < 100; ++i)
		c.note(Domain::Host, Outcome::Skipped, "guards_spawner", "actor_on_update");
	c.note(Domain::Host, Outcome::Skipped, "campfire_placeable", "actor_on_item_use");
	for (int i = 0; i < 50; ++i)
		c.note(Domain::Host, Outcome::Skipped, "guards_spawner", "actor_on_update");
	c.note(Domain::Host, Outcome::Skipped, "guards_spawner", "on_key_press");
	const std::vector<std::pair<std::string, uint64_t>> top = c.top_skipped(10);
	CHECK_EQ(top.size(), size_t(3));
	if (top.size() == 3)
	{
		CHECK_EQ(top[0].first, std::string("actor_on_update@guards_spawner"));
		CHECK_EQ(top[0].second, uint64_t(150));
		CHECK_EQ(top[1].first, std::string("actor_on_item_use@campfire_placeable")); // a tie of 1: by name
		CHECK_EQ(top[2].first, std::string("on_key_press@guards_spawner"));
	}
	const std::vector<std::string> latest = c.latest_new_skips(2);
	CHECK_EQ(latest.size(), size_t(2));
	if (latest.size() == 2)
	{
		CHECK_EQ(latest[0], std::string("on_key_press@guards_spawner"));
		CHECK_EQ(latest[1], std::string("actor_on_item_use@campfire_placeable"));
	}
	CHECK_EQ(c.pairs_tracked(), size_t(3));
	c.clear();
	CHECK_EQ(c.latest_new_skips(5).size(), size_t(0));
}
