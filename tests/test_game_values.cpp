// Anomaly Coop unit tests: the engine's part of "Game settings" that needs no engine (coop_game_values.h;
// docs/GAME_SETTINGS.md §1.2, §3.4, §3.5): the white list of the 19 game rules, the layer that sets them over the
// machine's console values and gives them back, the new game that waits in memory, and the world's group.
#include "test_util.h"

#include "coop_game_values.h"

#include <map>
#include <string>
#include <vector>

using namespace coop::game;

namespace
{
// The engine's console as the layer sees it: a map of values, every set recorded.
struct FakeConsole : CvarConsole
{
	std::map<std::string, std::string> values;
	std::vector<std::string> sets; // "name=value", in the order of the calls
	std::vector<std::string> gets;

	bool get(const std::string& name, std::string& value) override
	{
		gets.push_back(name);
		const auto it = values.find(name);
		if (it == values.end())
			return false;
		value = it->second;
		return true;
	}

	void set(const std::string& name, const std::string& value) override
	{
		sets.push_back(name + "=" + value);
		const auto it = values.find(name);
		if (it != values.end())
			it->second = value;
	}
};

std::string repeat(char c, size_t n) { return std::string(n, c); }
} // namespace

// §1.2: the white list is the 19 rules of the table, nothing else, each once. The last two are the split-levels rules of
// F3a (docs/plans/2026-10-24-f3a-split-levels.md §3): the engine registers them (coop_split_levels, coop_story_together).
TEST(game_values_cvar_list_is_the_nineteen_rules)
{
	const char* expected[] = {
		"coop_friendly_fire", "coop_max_new_characters", "coop_share_rewards", "coop_death_mode", "coop_death_drop",
		"coop_bleedout", "coop_revive_health", "coop_respawn_delay", "coop_contusion", "coop_death_money",
		"coop_death_wear", "coop_death_rank", "coop_hardcore_new_kit", "coop_checkpoints_group",
		"coop_autosave_interval", "coop_autosave_count", "coop_death_share", "coop_split_levels", "coop_story_together",
	};
	CHECK_EQ(kGameCvarCount, size_t(19));
	CHECK_EQ(sizeof(expected) / sizeof(expected[0]), kGameCvarCount);
	for (size_t i = 0; i < kGameCvarCount; ++i)
	{
		CHECK_EQ(std::string(kGameCvars[i]), std::string(expected[i]));
		CHECK(cvar_allowed(expected[i]));
		for (size_t j = i + 1; j < kGameCvarCount; ++j)
			CHECK(kGameCvars[i] != kGameCvars[j]);
	}
}

// The two rules of split levels are on/off flags: a game record writes "0" / "1", and the layer takes them like the others
// (the machine's value is remembered once and given back when the level is left).
TEST(game_values_split_levels_rules_apply_and_release)
{
	CHECK(cvar_allowed("coop_split_levels"));
	CHECK(cvar_allowed("coop_story_together"));
	CHECK(!cvar_allowed("Coop_Split_Levels")); // exact names only
	CHECK(!cvar_allowed("coop_max_map_servers")); // a machine setting (the host's PC), not a rule of the game
	CHECK(!cvar_allowed("coop_mapserver_linger"));
	CHECK(cvar_value_valid("0"));
	CHECK(cvar_value_valid("1"));

	FakeConsole con;
	con.values["coop_split_levels"] = "1";
	con.values["coop_story_together"] = "1";
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_split_levels", "0") == CvarVerdict::Applied);
	CHECK(layer.apply(con, "coop_story_together", "0") == CvarVerdict::Applied);
	CHECK_EQ(con.values["coop_split_levels"], std::string("0"));
	CHECK_EQ(con.values["coop_story_together"], std::string("0"));
	CHECK_EQ(layer.release(con), size_t(2));
	CHECK_EQ(con.values["coop_split_levels"], std::string("1"));
	CHECK_EQ(con.values["coop_story_together"], std::string("1"));

	// An engine that does not know the rules yet refuses them, never fatal (the list may run ahead of the console).
	FakeConsole old;
	CHECK(layer.apply(old, "coop_split_levels", "1") == CvarVerdict::Unknown);
	CHECK(old.sets.empty());
}

TEST(game_values_cvar_apply_remembers_machine_once)
{
	FakeConsole con;
	con.values["coop_bleedout"] = "0";
	CvarLayer layer;

	CHECK(layer.apply(con, "coop_bleedout", "1") == CvarVerdict::Applied);
	CHECK_EQ(con.values["coop_bleedout"], std::string("1"));
	CHECK(layer.apply(con, "coop_bleedout", "2") == CvarVerdict::Applied);
	CHECK_EQ(con.values["coop_bleedout"], std::string("2"));
	CHECK_EQ(layer.held(), size_t(1));

	// The second apply did not take the first game value for the machine's.
	const std::string* machine = layer.machine("coop_bleedout");
	REQUIRE(machine != nullptr);
	CHECK_EQ(*machine, std::string("0"));

	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_bleedout"], std::string("0"));
}

TEST(game_values_cvar_release_restores_all_and_clears)
{
	FakeConsole con;
	con.values["coop_bleedout"] = "60";
	con.values["coop_death_mode"] = "checkpoint";
	con.values["coop_friendly_fire"] = "1";
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_bleedout", "30") == CvarVerdict::Applied);
	CHECK(layer.apply(con, "coop_death_mode", "hardcore") == CvarVerdict::Applied);
	CHECK(layer.apply(con, "coop_friendly_fire", "0") == CvarVerdict::Applied);
	CHECK_EQ(layer.held(), size_t(3));

	CHECK_EQ(layer.release(con), size_t(3));
	CHECK_EQ(con.values["coop_bleedout"], std::string("60"));
	CHECK_EQ(con.values["coop_death_mode"], std::string("checkpoint"));
	CHECK_EQ(con.values["coop_friendly_fire"], std::string("1"));
	CHECK_EQ(layer.held(), size_t(0));
	CHECK(layer.machine("coop_bleedout") == nullptr);

	// A second release has nothing to give back: not one more console call, and a value the player has changed
	// since (menu, console) is not written over.
	con.values["coop_bleedout"] = "99";
	const size_t calls = con.sets.size();
	CHECK_EQ(layer.release(con), size_t(0));
	CHECK_EQ(con.sets.size(), calls);
	CHECK_EQ(con.values["coop_bleedout"], std::string("99"));
}

// A new activation after a release takes the machine's value of that moment, not the one of the first activation.
TEST(game_values_cvar_apply_after_release_remembers_again)
{
	FakeConsole con;
	con.values["coop_autosave_count"] = "10";
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_autosave_count", "3") == CvarVerdict::Applied);
	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_autosave_count"], std::string("10"));

	con.values["coop_autosave_count"] = "20"; // the player changed it in the main menu
	CHECK(layer.apply(con, "coop_autosave_count", "5") == CvarVerdict::Applied);
	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_autosave_count"], std::string("20"));
}

TEST(game_values_cvar_not_whitelisted_refused)
{
	FakeConsole con;
	con.values["coop_nick"] = "Stalker";
	con.values["fov"] = "67.5";
	con.values["coop_money_max"] = "1000";
	con.values["coop_friendly_fire"] = "1";
	CvarLayer layer;

	CHECK(layer.apply(con, "coop_nick", "Hacker") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "fov", "120") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "coop_money_max", "9") == CvarVerdict::NotAllowed); // a technical limit, not a game rule
	CHECK(layer.apply(con, "", "1") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "quit", "1") == CvarVerdict::NotAllowed);
	// The name is exact: one console command must not be held under two spellings (the second would take the game
	// value of the first for the machine's).
	CHECK(layer.apply(con, "Coop_Friendly_Fire", "0") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "coop_friendly_fire ", "0") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "coop_friendly_fire;quit", "0") == CvarVerdict::NotAllowed);

	CHECK(con.sets.empty());
	CHECK(con.gets.empty());
	CHECK_EQ(layer.held(), size_t(0));
	CHECK_EQ(con.values["coop_nick"], std::string("Stalker"));
	CHECK_EQ(con.values["fov"], std::string("67.5"));
}

TEST(game_values_cvar_value_validated)
{
	// Valid: a number, a token name, a signed number, the longest allowed.
	CHECK(cvar_value_valid("0"));
	CHECK(cvar_value_valid("0.3"));
	CHECK(cvar_value_valid("-1"));
	CHECK(cvar_value_valid("60."));
	CHECK(cvar_value_valid("checkpoint"));
	CHECK(cvar_value_valid(repeat('1', 64)));

	// Not valid: nothing, too long, a second command (';'), a line break, anything that splits the console line.
	CHECK(!cvar_value_valid(""));
	CHECK(!cvar_value_valid(repeat('1', 65)));
	CHECK(!cvar_value_valid("1;quit"));
	CHECK(!cvar_value_valid("1\nquit"));
	CHECK(!cvar_value_valid("1\r"));
	CHECK(!cvar_value_valid("1 2"));
	CHECK(!cvar_value_valid(" 1"));
	CHECK(!cvar_value_valid("1\t"));
	CHECK(!cvar_value_valid("\"1\""));
	CHECK(!cvar_value_valid(std::string("1\0" "2", 3)));
	CHECK(!cvar_value_valid("\xD0\xBF")); // not ASCII
	// What atof reads as a NaN or an infinity: a NaN would pass the console's range check.
	CHECK(!cvar_value_valid("nan"));
	CHECK(!cvar_value_valid("NaN"));
	CHECK(!cvar_value_valid("-nan"));
	CHECK(!cvar_value_valid("inf"));
	CHECK(!cvar_value_valid("+Infinity"));
	CHECK(cvar_value_valid("na")); // short of the word
	CHECK(cvar_value_valid("hardcore"));
	CHECK(cvar_value_valid("lose"));

	FakeConsole con;
	con.values["coop_bleedout"] = "60";
	CvarLayer layer;
	const char* bad[] = {"", "1;quit", "1\nquit", "1 2"};
	for (const char* v : bad)
		CHECK(layer.apply(con, "coop_bleedout", v) == CvarVerdict::BadValue);
	CHECK(layer.apply(con, "coop_bleedout", repeat('9', 65)) == CvarVerdict::BadValue);
	CHECK(con.sets.empty());
	CHECK(con.gets.empty());
	CHECK_EQ(layer.held(), size_t(0));
	CHECK_EQ(con.values["coop_bleedout"], std::string("60"));
}

// A rule the console does not know (coop_death_share before its build lands) is refused, never fatal.
TEST(game_values_cvar_unknown_command_refused)
{
	FakeConsole con; // knows nothing
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_death_share", "150") == CvarVerdict::Unknown);
	CHECK(con.sets.empty());
	CHECK_EQ(layer.held(), size_t(0));
	CHECK_EQ(layer.release(con), size_t(0));

	// The others of the same call still go through.
	con.values["coop_bleedout"] = "60";
	CHECK(layer.apply(con, "coop_death_share", "150") == CvarVerdict::Unknown);
	CHECK(layer.apply(con, "coop_bleedout", "30") == CvarVerdict::Applied);
	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_bleedout"], std::string("60"));
}

// A machine value that cannot be given back (a token that shows "?", an empty status) is not touched at all:
// release would have nothing valid to write.
TEST(game_values_cvar_unrestorable_machine_value_refused)
{
	FakeConsole con;
	con.values["coop_death_drop"] = "?";
	con.values["coop_death_mode"] = "";
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_death_drop", "lose") == CvarVerdict::Unknown);
	CHECK(layer.apply(con, "coop_death_mode", "hardcore") == CvarVerdict::Unknown);
	CHECK(con.sets.empty());
	CHECK_EQ(layer.held(), size_t(0));
}

TEST(game_values_cvar_machine_value_lookup)
{
	FakeConsole con;
	con.values["coop_revive_health"] = "0.3";
	CvarLayer layer;
	CHECK(layer.machine("coop_revive_health") == nullptr); // nothing held: the console shows the machine's value
	CHECK(layer.machine("coop_nick") == nullptr);

	CHECK(layer.apply(con, "coop_revive_health", "0.5") == CvarVerdict::Applied);
	const std::string* m = layer.machine("coop_revive_health");
	REQUIRE(m != nullptr);
	CHECK_EQ(*m, std::string("0.3"));
	CHECK(layer.machine("coop_bleedout") == nullptr);

	layer.release(con);
	CHECK(layer.machine("coop_revive_health") == nullptr);
}

TEST(game_values_pending_take_clears)
{
	Pending p;
	std::string payload, faction;
	CHECK(!p.staged());
	CHECK(!p.take(payload, faction)); // nothing staged

	CHECK(p.stage("record-1", "stalker"));
	CHECK(p.staged());
	CHECK_EQ(p.faction(), std::string("stalker"));
	REQUIRE(p.take(payload, faction));
	CHECK_EQ(payload, std::string("record-1"));
	CHECK_EQ(faction, std::string("stalker"));

	// Taken once: the second take is empty, and so is what the world start reads.
	payload = "left";
	faction = "left";
	CHECK(!p.take(payload, faction));
	CHECK(!p.staged());
	CHECK_EQ(p.faction(), std::string());
}

TEST(game_values_pending_stage_replaces_and_limits)
{
	Pending p;
	std::string payload, faction;

	CHECK(p.stage("first", "dolg"));
	CHECK(p.stage("second", "freedom")); // a new stage replaces the old one
	REQUIRE(p.take(payload, faction));
	CHECK_EQ(payload, std::string("second"));
	CHECK_EQ(faction, std::string("freedom"));

	// Binary payload: zero bytes stay.
	const std::string binary("a\0b\xFF", 4);
	CHECK(p.stage(binary, "stalker"));
	REQUIRE(p.take(payload, faction));
	CHECK(payload == binary);

	// 256 KiB is the limit, one more is refused.
	CHECK(p.stage(repeat('x', kMaxPendingPayload), "stalker"));
	REQUIRE(p.take(payload, faction));
	CHECK_EQ(payload.size(), kMaxPendingPayload);
	CHECK_EQ(kMaxPendingPayload, size_t(256 * 1024));
	CHECK(!p.stage(repeat('x', kMaxPendingPayload + 1), "stalker"));

	// A refused stage drops the game staged before it: the screen that failed to stage its game must not start the
	// world with the previous one.
	CHECK(p.stage("kept?", "stalker"));
	CHECK(!p.stage(repeat('x', kMaxPendingPayload + 1), "stalker"));
	CHECK(!p.staged());
	CHECK(!p.take(payload, faction));

	// Nothing to carry, or a faction that is not a name: refused (and the old one dropped, as above).
	CHECK(p.stage("kept?", "stalker"));
	CHECK(!p.stage("", "stalker"));
	CHECK(!p.staged());
	CHECK(p.stage("kept?", "stalker"));
	CHECK(!p.stage("x", "a b"));
	CHECK(!p.staged());
	CHECK(!p.stage("x", ""));
}

TEST(game_values_world_faction_name_checked)
{
	CHECK(world_faction_valid("stalker"));
	CHECK(world_faction_valid("csky"));
	CHECK(world_faction_valid("Some_Mod-faction.2"));
	CHECK(world_faction_valid(repeat('a', 64)));

	CHECK(!world_faction_valid(""));
	CHECK(!world_faction_valid("a b"));
	CHECK(!world_faction_valid(repeat('a', 65)));
	CHECK(!world_faction_valid("a/b"));
	CHECK(!world_faction_valid("a;b"));
	CHECK(!world_faction_valid("a\nb"));
	CHECK(!world_faction_valid(std::string("a\0b", 3)));
}

TEST(game_values_start_mode_names)
{
	CHECK(start_mode("new") == StartMode::New);
	CHECK(start_mode("load") == StartMode::Load);
	CHECK(start_mode("") == StartMode::Other);
	CHECK(start_mode("NEW") == StartMode::Other); // the engine compares exactly (alife_simulator.cpp)
	CHECK(start_mode("spawn") == StartMode::Other);
	CHECK(start_mode(nullptr) == StartMode::Other);
	CHECK_EQ(std::string(start_mode_name(StartMode::New)), std::string("new"));
	CHECK_EQ(std::string(start_mode_name(StartMode::Load)), std::string("load"));
}

// before_world_start: a new game takes the group of the staged game, a load drops what was staged.
TEST(game_values_world_start_new_takes_staged_faction)
{
	Pending p;
	std::string world = "old-game-faction";
	CHECK(p.stage("record", "monolith"));

	on_world_start(StartMode::New, p, world);
	CHECK_EQ(world, std::string("monolith"));
	// The group is read, the game stays staged: Lua takes it (coop.game.take_new) in the call that follows.
	std::string payload, faction;
	REQUIRE(p.take(payload, faction));
	CHECK_EQ(payload, std::string("record"));

	// A new game with nothing staged (single player, a console `start`) has no group, and the one of the last
	// game does not stay.
	world = "monolith";
	on_world_start(StartMode::New, p, world);
	CHECK_EQ(world, std::string());
}

TEST(game_values_world_start_load_drops_stale_pending)
{
	Pending p;
	std::string world = "monolith";
	CHECK(p.stage("record", "dolg"));

	on_world_start(StartMode::Load, p, world);
	CHECK(!p.staged()); // the staged game belongs to a start that never came
	std::string payload, faction;
	CHECK(!p.take(payload, faction));
	// The last game's group does not leak into the loaded one; Lua sets the loaded game's own.
	CHECK_EQ(world, std::string());
}

TEST(game_values_world_start_other_mode_changes_nothing)
{
	Pending p;
	std::string world = "monolith";
	CHECK(p.stage("record", "dolg"));
	on_world_start(StartMode::Other, p, world);
	CHECK(p.staged());
	CHECK_EQ(world, std::string("monolith"));
}
