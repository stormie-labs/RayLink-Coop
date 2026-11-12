// Anomaly Coop unit tests: the staging file of a new world, coop_new_world.ltx (xrCoop/coop_world_stage.h, docs/plans/2026-11-12-split-levels-
// native.md section 4.2, stage 5): what the game and the launcher write, what the world server reads, and what it refuses.
#include "test_util.h"

#include "coop_world_stage.h"

#include <string>

using namespace coop::world_stage;

namespace
{
const char* kFull = "; written by the game\r\n"
                    "[world]\r\n"
                    "id = 65190f3a-9c41\r\n"
                    "name = Strelok\r\n"
                    "title = With Kent\r\n"
                    "faction = bandit\r\n"
                    "story = 1\r\n"
                    "routes = 0\r\n"
                    "difficulty = 2\r\n"
                    "economy = 3\r\n"
                    "\r\n"
                    "[values]\r\n"
                    "\"o|alife/event/emission_frequency\" = 48\r\n"
                    "\"g|hit_power\" = 1.5\r\n"
                    "c|coop_death_mode = hardcore\r\n"
                    "\r\n"
                    "[creator]\r\n"
                    "name = Strelok\r\n"
                    "icon = ui_inGame2_bandit_1\r\n"
                    "loadout = wpn_pm, ammo_9x18_fmj,wpn_pm,,novice_outfit\r\n"
                    "money = 5000\r\n"
                    "map = esc_m_trader\r\n"
                    "bare = 0\r\n";

bool parsed(const std::string& text, Stage& s, std::string& why) { return parse(text, s, why); }

bool refused(const std::string& text, const char* why_has = nullptr)
{
	Stage s;
	std::string why;
	const bool ok = parse(text, s, why);
	if (ok)
		return false;
	return why_has == nullptr || why.find(why_has) != std::string::npos;
}
} // namespace

TEST(world_stage_reads_every_key_of_the_contract)
{
	Stage s;
	std::string why;
	CHECK(parsed(kFull, s, why));
	CHECK_EQ(s.world.id, std::string("65190f3a-9c41"));
	CHECK_EQ(s.world.name, std::string("Strelok"));
	CHECK_EQ(s.world.title, std::string("With Kent"));
	CHECK_EQ(s.world.faction, std::string("bandit"));
	CHECK(s.world.story == Flag::On && s.world.routes == Flag::Off);
	CHECK_EQ(s.world.difficulty, 2);
	CHECK_EQ(s.world.economy, 3);
	CHECK_EQ(s.values.size(), size_t(3));
	CHECK_EQ(s.values[0].first, std::string("o|alife/event/emission_frequency"));
	CHECK_EQ(s.values[0].second, std::string("48"));
	CHECK_EQ(s.values[1].first, std::string("g|hit_power"));
	CHECK_EQ(s.values[2].first, std::string("c|coop_death_mode"));
	CHECK_EQ(s.values[2].second, std::string("hardcore"));
	CHECK(s.creator.present);
	CHECK_EQ(s.creator.name, std::string("Strelok"));
	CHECK_EQ(s.creator.icon, std::string("ui_inGame2_bandit_1"));
	CHECK_EQ(s.creator.loadout.size(), size_t(4)); // the empty entry is dropped, a copy is a copy
	CHECK_EQ(s.creator.loadout[1], std::string("ammo_9x18_fmj"));
	CHECK_EQ(s.creator.money, int64_t(5000));
	CHECK_EQ(s.creator.map, std::string("esc_m_trader"));
	CHECK(!s.creator.bare);
}

TEST(world_stage_a_written_stage_reads_back_the_same)
{
	Stage s;
	std::string why;
	CHECK(parsed(kFull, s, why));
	const std::string text = write(s);
	Stage back;
	CHECK(parsed(text, back, why));
	CHECK(back == s);
	CHECK_EQ(write(back), text);
}

TEST(world_stage_the_minimum_is_a_faction)
{
	Stage s;
	std::string why;
	CHECK(parsed("[world]\nfaction = stalker\n", s, why));
	CHECK(s.world.story == Flag::Absent && s.world.routes == Flag::Absent);
	CHECK_EQ(s.world.difficulty, 0); // absent: the game's default
	CHECK(!s.creator.present && s.values.empty());
	CHECK(refused("[world]\nname = x\n", "faction"));
	CHECK(refused("[creator]\nloadout = wpn_pm\n", "[world]"));
	CHECK(refused("", "[world]"));
}

TEST(world_stage_unknown_sections_and_keys_are_ignored)
{
	Stage s;
	std::string why;
	CHECK(parsed("[launcher]\nwhatever = { not ours\n[world]\nfaction = stalker\nweather = rain\n[creator]\nhat = yes\nmoney = 1\n",
	    s, why));
	CHECK_EQ(s.world.faction, std::string("stalker"));
	CHECK(s.creator.present && s.creator.money == 1);
}

TEST(world_stage_a_bom_comments_and_blanks)
{
	Stage s;
	std::string why;
	CHECK(parsed("\xEF\xBB\xBF# a comment\n  ; another\n\n  [world]  \n\tfaction\t=\tecolog  \n", s, why));
	CHECK_EQ(s.world.faction, std::string("ecolog"));
}

TEST(world_stage_quoted_values_keep_their_blanks)
{
	Stage s;
	std::string why;
	CHECK(parsed("[world]\nfaction = stalker\ntitle = \"  two  words \"\n[values]\n\"m|a/b\" = \" x \"\n", s, why));
	CHECK_EQ(s.world.title, std::string("  two  words "));
	CHECK_EQ(s.values[0].second, std::string(" x "));
}

TEST(world_stage_duplicates_are_refused)
{
	CHECK(refused("[world]\nfaction = stalker\nfaction = bandit\n", "twice"));
	CHECK(refused("[world]\nfaction = stalker\n[values]\no|a = 1\n\"o|a\" = 2\n", "twice"));
	CHECK(refused("[world]\nfaction = stalker\n[world]\nfaction = bandit\n", "twice"));
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nmoney = 1\n[creator]\nmoney = 2\n", "twice"));
}

TEST(world_stage_broken_lines_are_refused_with_their_number)
{
	CHECK(refused("[world]\nfaction = stalker\nno equals sign\n", "line 3"));
	CHECK(refused("faction = stalker\n[world]\n", "line 1"));
	CHECK(refused("[world\nfaction = stalker\n", "line 1"));
	CHECK(refused("[world]\nfaction = stalker\n = 5\n", "line 3"));
	CHECK(refused(std::string("[world]\nfaction = stal\0ker\n", 27), "line 2"));
}

TEST(world_stage_values_of_the_world_are_checked)
{
	CHECK(refused("[world]\nfaction = sta lker\n", "faction"));
	CHECK(refused("[world]\nfaction = stalker\ndifficulty = 4\n", "difficulty"));
	CHECK(refused("[world]\nfaction = stalker\neconomy = 0\n", "economy"));
	CHECK(refused("[world]\nfaction = stalker\nstory = maybe\n", "story"));
	CHECK(refused("[world]\nfaction = stalker\nid = a/b\n", "id"));
	Stage s;
	std::string why;
	CHECK(parsed("[world]\nfaction = stalker\nstory = true\nroutes = false\n", s, why));
	CHECK(s.world.story == Flag::On && s.world.routes == Flag::Off);
}

TEST(world_stage_the_values_keys_are_a_source_and_a_path)
{
	CHECK(refused("[world]\nfaction = stalker\n[values]\nx|a = 1\n", "source"));
	CHECK(refused("[world]\nfaction = stalker\n[values]\no| = 1\n", "path"));
	CHECK(refused("[world]\nfaction = stalker\n[values]\nfaction = 1\n", "source"));
	Stage s;
	std::string why;
	CHECK(parsed("[world]\nfaction = stalker\n[values]\ne|buy = 1.2\ns|trader_buy_condition_override = 0\n", s, why));
	CHECK_EQ(s.values.size(), size_t(2));
}

TEST(world_stage_the_creator_is_checked)
{
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nmoney = -1\n", "money"));
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nmoney = 10000001\n", "money"));
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nmoney = 5k\n", "money"));
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nbare = 2\n", "bare"));
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nloadout = wpn pm\n", "loadout"));
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nmap = ../x\n", "map"));
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nicon = a b\n", "icon"));
	Stage s;
	std::string why;
	CHECK(parsed("[world]\nfaction = stalker\n[creator]\nmoney = 10000000\nbare = 1\nloadout =\nmap =\n", s, why));
	CHECK(s.creator.present && s.creator.bare && s.creator.loadout.empty() && s.creator.map.empty());
	CHECK_EQ(s.creator.money, kMaxMoney);
}

TEST(world_stage_limits)
{
	std::string loadout;
	for (size_t i = 0; i < kMaxLoadout; ++i)
		loadout += (i ? "," : "") + std::string("wpn_pm");
	Stage s;
	std::string why;
	CHECK(parsed("[world]\nfaction = stalker\n[creator]\nloadout = " + loadout + "\n", s, why));
	CHECK_EQ(s.creator.loadout.size(), kMaxLoadout);
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nloadout = " + loadout + ",wpn_pm\n", "loadout"));

	CHECK(refused("[world]\nfaction = stalker\nname = " + std::string(kMaxName + 1, 'a') + "\n", "name"));
	CHECK(parsed("[world]\nfaction = stalker\nname = " + std::string(kMaxName, 'a') + "\n", s, why));
	CHECK(refused("[world]\nfaction = stalker\ntitle = " + std::string(kMaxTitle + 1, 'a') + "\n", "title"));
	CHECK(refused("[world]\nfaction = stalker\n[creator]\nname = " + std::string(kMaxName + 1, 'a') + "\n", "name"));

	CHECK(refused("[world]\nfaction = stalker\n; " + std::string(kMaxLineBytes, 'x') + "\n", "line 3"));
	CHECK(refused(std::string(kMaxFileBytes + 1, '\n'), "bytes"));

	std::string values = "[world]\nfaction = stalker\n[values]\n";
	for (size_t i = 0; i <= kMaxValues; ++i)
		values += "o|k" + std::to_string(i) + " = 1\n";
	CHECK(refused(values, "values"));
	CHECK(refused("[world]\nfaction = stalker\n[values]\no|" + std::string(kMaxKeyBytes, 'k') + " = 1\n", "key"));
	CHECK(refused("[world]\nfaction = stalker\n[values]\no|k = " + std::string(kMaxValueBytes + 1, 'v') + "\n", "value"));
}

TEST(world_stage_text_of_names_keeps_its_bytes_but_no_control_characters)
{
	Stage s;
	std::string why;
	CHECK(parsed("[world]\nfaction = stalker\nname = \xD0\x9C\xD0\xB5\xD1\x87\n", s, why)); // UTF-8 letters: bytes as they are
	CHECK_EQ(s.world.name, std::string("\xD0\x9C\xD0\xB5\xD1\x87"));
	CHECK(refused("[world]\nfaction = stalker\ntitle = a\x01" "b\n", "title"));
}
