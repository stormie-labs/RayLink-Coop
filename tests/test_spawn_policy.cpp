// Anomaly Coop unit tests: what a client may ask the host to create (F2 T2, coop_spawn.h): the class table (engine and
// script item classes only), the lines each class's server entity reads unchecked, and the verdict on a ReqSpawn:
// deny/allow lists, quest items and a cost budget per character for the whole session (Ruling F2-11).
#include "test_util.h"

#include "coop_ledger.h"
#include "coop_spawn.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <vector>

using namespace coop;
using spawn::CseClass;
using spawn::SpawnVerdict;

namespace
{
bool has_line(const std::vector<const char*>& lines, const char* name)
{
	return std::find_if(lines.begin(), lines.end(), [&](const char* s) { return std::string(s) == name; }) !=
	    lines.end();
}

bool is_class(std::string_view clsid, CseClass cse)
{
	const spawn::ClassRule* rule = spawn::class_rule(clsid);
	return rule && rule->cse == cse;
}

spawn::SectionFacts facts(uint32_t cost, bool quest = false, bool allow = false, bool deny = false)
{
	spawn::SectionFacts f;
	f.quest_item = quest;
	f.cost = cost;
	f.allow_listed = allow;
	f.deny_listed = deny;
	return f;
}

const spawn::ClassRule* item_rule() { return spawn::class_rule("II_FOOD"); }
} // namespace

TEST(spawn_class_table)
{
	// The brief's anchors: engine ids, Anomaly's script ids, and things that are not items.
	CHECK(is_class("WP_AK74", CseClass::WeaponMagazinedWGL));
	CHECK(is_class("W_KNIFE", CseClass::Weapon));
	CHECK(is_class("AMMO", CseClass::Ammo));
	CHECK(is_class("E_STLK", CseClass::CustomOutfit));
	CHECK(is_class("D_SIMDET", CseClass::Detector));
	CHECK(is_class("II_FOOD", CseClass::Item));
	CHECK(spawn::class_rule("AI_STL_S") == nullptr); // script stalker
	CHECK(spawn::class_rule("ZS_MBALD") == nullptr); // script anomaly

	// Each server class of the table.
	CHECK(is_class("W_LR300", CseClass::WeaponMagazined));
	CHECK(is_class("WP_BM16", CseClass::WeaponShotGun));
	CHECK(is_class("WP_ASHTG", CseClass::WeaponAutoShotGun)); // se_weapon_automatic_shotgun
	CHECK(is_class("G_F1_S", CseClass::Grenade));
	CHECK(is_class("II_EXPLO", CseClass::Explosive));
	CHECK(is_class("II_BOLT", CseClass::Bolt));
	CHECK(is_class("SCRPTART", CseClass::Artefact));
	CHECK(is_class("AF_GRAVI", CseClass::Artefact));
	CHECK(is_class("DET_ELIT", CseClass::Detector));
	CHECK(is_class("EQU_EXO", CseClass::CustomOutfit));
	CHECK(is_class("E_HLMET", CseClass::Helmet)); // script helmet: se_helmet (cse_alife_item_helmet)
	CHECK(is_class("EQ_HLMET", CseClass::Item)); // engine helmet: CSE_ALifeItem
	CHECK(is_class("TORCH_S", CseClass::Torch));
	CHECK(is_class("S_PDA", CseClass::PDA));
	CHECK(is_class("II_DOC", CseClass::Document));
	CHECK(is_class("S_OG7B", CseClass::Ammo));
	CHECK(is_class("WP_SCOPE", CseClass::Item));
	CHECK(is_class("_W_SSRS", CseClass::WeaponMagazined));
	CHECK(is_class("_WP_SSRS", CseClass::WeaponMagazined)); // class_registrator_modded_exes.script (engine layer)
	// A launcher's rocket (CSE_Temporary) is asked for as a child of the weapon: the client's launch needs it.
	CHECK(is_class("G_RPG7", CseClass::Temporary));
	CHECK(is_class("G_FAKE", CseClass::Temporary));

	// Not items, or not registered in a game that is not a dedicated server.
	CHECK(spawn::class_rule("W_STMGUN") == nullptr); // mounted gun
	CHECK(spawn::class_rule("S_INVBOX") == nullptr); // inventory box
	CHECK(spawn::class_rule("O_PHYS_S") == nullptr); // physics object
	CHECK(spawn::class_rule("SM_BLOOD") == nullptr); // monster
	CHECK(spawn::class_rule("ON_OFF_S") == nullptr); // squad
	CHECK(spawn::class_rule("WP_MAGAZ") == nullptr); // commented out in class_registrator.script
	CHECK(spawn::class_rule("_S_STMGU") == nullptr); // modded exes' mounted gun
	CHECK(spawn::class_rule("WP_AK47") == nullptr); // a GAMMA section's class that nothing registers

	// Ini values: trailing blanks go, the case stays (TEXT2CLSID is case-sensitive).
	CHECK(is_class("WP_AK74 ", CseClass::WeaponMagazinedWGL));
	CHECK(is_class("WP_AK74\t", CseClass::WeaponMagazinedWGL));
	CHECK(spawn::class_rule("wp_ak74") == nullptr);
	CHECK(spawn::class_rule("") == nullptr);
	CHECK(spawn::class_rule(" ") == nullptr);
	CHECK(spawn::class_rule("WP_AK74X") == nullptr);
	CHECK(spawn::class_rule("WP_AK7") == nullptr);

	// The table itself: unique ids of 1..8 characters without blanks (MK_CLSID).
	std::set<std::string> seen;
	for (const spawn::ClassRule& rule : spawn::kClassRules)
	{
		CHECK(!rule.clsid.empty() && rule.clsid.size() <= 8);
		CHECK(rule.clsid.find(' ') == std::string_view::npos);
		CHECK(seen.insert(std::string(rule.clsid)).second);
		CHECK(spawn::class_rule(rule.clsid) == &rule);
	}
	CHECK(seen.size() > 80);
}

TEST(spawn_required_lines)
{
	// CSE_ALifeInventoryItem reads inv_weight and cost for every item.
	for (uint8_t i = 0; i < spawn::kCseClassCount; ++i)
	{
		const std::vector<const char*> lines = spawn::required_lines(CseClass(i));
		CHECK(has_line(lines, "inv_weight"));
		CHECK(has_line(lines, "cost"));
	}
	// CSE_ALifeItemWeapon and every weapon below it.
	for (const CseClass weapon : {CseClass::Weapon, CseClass::WeaponMagazined, CseClass::WeaponMagazinedWGL,
	         CseClass::WeaponShotGun, CseClass::WeaponAutoShotGun})
	{
		const std::vector<const char*> lines = spawn::required_lines(weapon);
		for (const char* line : {"hit_power", "hit_type", "ammo_class", "scope_status", "silencer_status",
		         "grenade_launcher_status"})
			CHECK(has_line(lines, line));
		CHECK_EQ(lines.size(), size_t(8));
	}
	CHECK(has_line(spawn::required_lines(CseClass::Ammo), "box_size"));
	CHECK_EQ(spawn::required_lines(CseClass::Ammo).size(), size_t(3));
	CHECK(has_line(spawn::required_lines(CseClass::Detector), "ef_detector_type"));
	CHECK_EQ(spawn::required_lines(CseClass::Detector).size(), size_t(3));
	CHECK(has_line(spawn::required_lines(CseClass::CustomOutfit), "ef_equipment_type"));
	CHECK_EQ(spawn::required_lines(CseClass::CustomOutfit).size(), size_t(3));
	// Classes whose own constructors read nothing unchecked: only the inventory item's two lines.
	for (const CseClass plain : {CseClass::Item, CseClass::Grenade, CseClass::Explosive, CseClass::Bolt,
	         CseClass::Artefact, CseClass::Torch, CseClass::PDA, CseClass::Document, CseClass::Helmet,
	         CseClass::Temporary})
		CHECK_EQ(spawn::required_lines(plain).size(), size_t(2));
	CHECK(!has_line(spawn::required_lines(CseClass::Item), "hit_power"));
	CHECK(!has_line(spawn::required_lines(CseClass::Ammo), "hit_power"));
}

TEST(spawn_judge_order)
{
	const spawn::SpawnPolicy policy;
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);

	// Each verdict on its own input.
	{
		spawn::CostBudget b;
		CHECK(spawn::judge(nullptr, nullptr, facts(10), b, policy, 0) == SpawnVerdict::UnknownClass);
		CHECK(spawn::judge(rule, "cost", facts(10), b, policy, 0) == SpawnVerdict::MissingLine);
		CHECK(spawn::judge(rule, nullptr, facts(10, false, false, true), b, policy, 0) == SpawnVerdict::Denied);
		CHECK(spawn::judge(rule, nullptr, facts(10, true), b, policy, 0) == SpawnVerdict::QuestItem);
		CHECK(!b.started); // refusals before the budget leave it alone
		CHECK(spawn::judge(rule, nullptr, facts(10, false, true), b, policy, 0) == SpawnVerdict::Allow);
		CHECK(!b.started); // an allow-listed section does not touch it either
		CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst + 1), b, policy, 0) == SpawnVerdict::OverBudget);
		CHECK(spawn::judge(rule, nullptr, facts(10), b, policy, 0) == SpawnVerdict::Allow);
	}

	// The order: an earlier check wins over every later one.
	spawn::CostBudget b;
	const spawn::SectionFacts everything = facts(policy.cost_burst + 1, true, true, true);
	CHECK(spawn::judge(nullptr, "cost", everything, b, policy, 0) == SpawnVerdict::UnknownClass);
	CHECK(spawn::judge(rule, "cost", everything, b, policy, 0) == SpawnVerdict::MissingLine);
	CHECK(spawn::judge(rule, nullptr, everything, b, policy, 0) == SpawnVerdict::Denied); // deny beats allow
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst + 1, true, true), b, policy, 0) ==
	    SpawnVerdict::Allow); // allow beats quest and budget
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst + 1, true), b, policy, 0) ==
	    SpawnVerdict::QuestItem); // quest beats budget
	CHECK(!b.started);
}

TEST(spawn_budget)
{
	const spawn::SpawnPolicy policy;
	CHECK_EQ(policy.cost_burst, uint32_t(200000));
	CHECK_EQ(policy.cost_per_sec, uint32_t(2000));
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);
	spawn::CostBudget b;
	const uint64_t t0 = 5000000;

	// 200 000 in a row (100 x 2 000) at one moment, then nothing.
	for (int i = 0; i < 100; ++i)
		CHECK(spawn::judge(rule, nullptr, facts(2000), b, policy, t0) == SpawnVerdict::Allow);
	CHECK(spawn::judge(rule, nullptr, facts(1), b, policy, t0) == SpawnVerdict::OverBudget);
	CHECK(spawn::judge(rule, nullptr, facts(0), b, policy, t0) == SpawnVerdict::Allow); // a free item costs nothing

	// A second later 2 000 came back: 2 001 is too much (and a refusal costs nothing), 2 000 fits.
	CHECK(spawn::judge(rule, nullptr, facts(2001), b, policy, t0 + 1000) == SpawnVerdict::OverBudget);
	CHECK(spawn::judge(rule, nullptr, facts(2000), b, policy, t0 + 1000) == SpawnVerdict::Allow);
	CHECK(spawn::judge(rule, nullptr, facts(1), b, policy, t0 + 1000) == SpawnVerdict::OverBudget);

	// A clock that goes back refills nothing.
	CHECK(spawn::judge(rule, nullptr, facts(1), b, policy, t0) == SpawnVerdict::OverBudget);
	CHECK(spawn::judge(rule, nullptr, facts(1), b, policy, t0 + 1000) == SpawnVerdict::OverBudget);

	// The refill stops at the burst: a long pause gives 200 000, not more.
	const uint64_t later = t0 + 1000 + 3600000;
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst + 1), b, policy, later) == SpawnVerdict::OverBudget);
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), b, policy, later) == SpawnVerdict::Allow);
	CHECK(spawn::judge(rule, nullptr, facts(1), b, policy, later) == SpawnVerdict::OverBudget);

	// Another policy (host settings).
	spawn::SpawnPolicy small;
	small.cost_burst = 100;
	small.cost_per_sec = 10;
	spawn::CostBudget s;
	CHECK(spawn::judge(rule, nullptr, facts(100), s, small, 0) == SpawnVerdict::Allow); // starts full
	CHECK(spawn::judge(rule, nullptr, facts(5), s, small, 400) == SpawnVerdict::OverBudget); // 4 came back
	CHECK(spawn::judge(rule, nullptr, facts(4), s, small, 400) == SpawnVerdict::Allow);
	CHECK_EQ(s.at, uint64_t(400));
}

TEST(spawn_allow_list_bypasses_budget)
{
	const spawn::SpawnPolicy policy;
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);
	spawn::CostBudget b;
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), b, policy, 100) == SpawnVerdict::Allow);
	CHECK(spawn::judge(rule, nullptr, facts(1), b, policy, 100) == SpawnVerdict::OverBudget); // empty
	const double tokens = b.tokens;
	for (int i = 0; i < 10; ++i)
		CHECK(spawn::judge(rule, nullptr, facts(1000000, false, true), b, policy, 100) == SpawnVerdict::Allow);
	CHECK(b.tokens == tokens); // nothing taken
	CHECK(spawn::judge(rule, nullptr, facts(1), b, policy, 100) == SpawnVerdict::OverBudget); // still empty
	// The deny list beats the allow list; the allow list does not open an unknown class.
	CHECK(spawn::judge(rule, nullptr, facts(1, false, true, true), b, policy, 100) == SpawnVerdict::Denied);
	CHECK(spawn::judge(nullptr, nullptr, facts(1, false, true), b, policy, 100) == SpawnVerdict::UnknownClass);
}

// Ruling F2-11: the budget belongs to the character for the whole session. A peer that leaves and joins again as the
// same character (a new connection, maybe a new peer id) refills nothing; only a new session clears it. A character
// the host has not seen yet starts with the full burst. (Its key: spawn_budget_by_character_key.)
TEST(spawn_budget_survives_rejoin)
{
	const spawn::SpawnPolicy policy;
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);
	spawn::BudgetBook book;
	const std::string character(64, 'c'); // the character's key (ledger::character_key)
	uint64_t now = 1000;

	// Peer 3 plays the character and spends the whole burst.
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(character), policy, now) ==
	    SpawnVerdict::Allow);
	CHECK(spawn::judge(rule, nullptr, facts(1), book.of(character), policy, now) == SpawnVerdict::OverBudget);

	// Peer 3 leaves; 100 ms later the same player joins again as peer 5 and gets the same character back.
	now += 100;
	CHECK(spawn::judge(rule, nullptr, facts(201), book.of(character), policy, now) == SpawnVerdict::OverBudget);
	CHECK(spawn::judge(rule, nullptr, facts(200), book.of(character), policy, now) == SpawnVerdict::Allow);
	CHECK_EQ(book.size(), size_t(1));

	// A new character (a new player key) starts full.
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(std::string(64, 'd')), policy, now) ==
	    SpawnVerdict::Allow);
	CHECK_EQ(book.size(), size_t(2));

	// A new session: everything is full again.
	book.clear();
	CHECK_EQ(book.size(), size_t(0));
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(character), policy, now) ==
	    SpawnVerdict::Allow);
}

// ---------------------------------------------------------------- fix round 1 (Rulings F2-16, F2-17, F2-18)

namespace
{
// A section as the host's pSettings shows it: own lines, and the other sections a line may name (immunities_sect).
struct FakeIni
{
	std::map<std::string, std::string> lines;
	std::map<std::string, std::map<std::string, std::string>> others;

	bool has(const char* line) const { return lines.count(line) != 0; }
	long long number(const char* line) const // r_s32 / r_u32: atoi
	{
		const auto it = lines.find(line);
		return it == lines.end() ? 0 : std::atoll(it->second.c_str());
	}
	bool flag(const char* line) const // r_bool: the first 7 characters, lowercase, are on / yes / true / 1
	{
		const auto it = lines.find(line);
		if (it == lines.end())
			return false;
		std::string v = it->second.substr(0, 7);
		for (char& c : v)
			c = char(std::tolower(static_cast<unsigned char>(c)));
		return v == "on" || v == "yes" || v == "true" || v == "1";
	}
	bool ref_exists(const char* line) const
	{
		const auto it = lines.find(line);
		return it != lines.end() && others.count(it->second) != 0;
	}
	bool ref_has(const char* line, const char* other_line) const
	{
		const auto it = lines.find(line);
		if (it == lines.end())
			return false;
		const auto sec = others.find(it->second);
		return sec != others.end() && sec->second.count(other_line) != 0;
	}
};

// Every line any rule of the class could ask for, so nothing is missing; numbers and flags are set by the tests.
FakeIni complete(const spawn::ClassRule& rule)
{
	FakeIni ini;
	for (const char* line : spawn::required_lines(rule.cse))
		ini.lines[line] = "1";
	for (const spawn::GameLine& g : spawn::game_lines(rule.game))
		ini.lines[g.line] = "1";
	ini.lines["immunities_sect"] = "imm";
	for (const spawn::GameLine& g : spawn::kImmunityLines)
		ini.others["imm"][g.line] = "1";
	return ini;
}

bool is_missing(const spawn::Missing& m, const char* line) { return m.line && std::string(m.line) == line; }

spawn::Missing missing_with(const spawn::ClassRule& rule, std::initializer_list<const char*> cut,
    const std::map<std::string, std::string>& set)
{
	FakeIni ini = complete(rule);
	for (const char* line : cut)
		ini.lines.erase(line);
	for (const auto& kv : set)
		ini.lines[kv.first] = kv.second;
	return spawn::missing_line(rule, ini);
}
} // namespace

// Ruling F2-16: a quest item is given to a client's own actor while he talks to an NPC (the stock dialogs create it
// on the client). Allowed only with both: the item goes to the asking player's own character, and he holds a talk
// lock right now. It still costs the budget.
TEST(spawn_quest_item_in_dialog)
{
	const spawn::SpawnPolicy policy;
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);
	const uint16_t me = 0x1234, other = 0x2222;

	CHECK(spawn::quest_gift(true, me, me));
	CHECK(!spawn::quest_gift(false, me, me)); // no talk lock
	CHECK(!spawn::quest_gift(true, other, me)); // into somebody else's (or a box, or one of his own items)
	CHECK(!spawn::quest_gift(true, 0xffff, 0xffff)); // no character

	spawn::CostBudget b;
	spawn::SectionFacts f = facts(500, true);
	f.in_dialog_to_own_actor = spawn::quest_gift(true, me, me);
	CHECK(spawn::judge(rule, nullptr, f, b, policy, 0) == SpawnVerdict::Allow);
	CHECK(b.started && b.tokens == double(policy.cost_burst - 500)); // charged like any item
	f.in_dialog_to_own_actor = spawn::quest_gift(false, me, me);
	CHECK(spawn::judge(rule, nullptr, f, b, policy, 0) == SpawnVerdict::QuestItem);
	f.in_dialog_to_own_actor = spawn::quest_gift(true, other, me);
	CHECK(spawn::judge(rule, nullptr, f, b, policy, 0) == SpawnVerdict::QuestItem);

	// The exception changes nothing else: deny list, budget, an ordinary item in a dialog.
	spawn::SectionFacts denied = facts(1, true, false, true);
	denied.in_dialog_to_own_actor = true;
	CHECK(spawn::judge(rule, nullptr, denied, b, policy, 0) == SpawnVerdict::Denied);
	spawn::SectionFacts dear = facts(policy.cost_burst, true);
	dear.in_dialog_to_own_actor = true;
	CHECK(spawn::judge(rule, nullptr, dear, b, policy, 0) == SpawnVerdict::OverBudget);
	spawn::SectionFacts plain = facts(1);
	plain.in_dialog_to_own_actor = true;
	CHECK(spawn::judge(rule, nullptr, plain, b, policy, 0) == SpawnVerdict::Allow);
}

// Ruling F2-18: the budget's key is the character's player key (ledger::character_key of the proxy's custom data, as
// money uses), not the proxy id: loading an older save gives the same player's character another id.
TEST(spawn_budget_by_character_key)
{
	const spawn::SpawnPolicy policy;
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);
	const std::string digest(64, 'a');
	// The same player's character before and after loading an older save: proxy 812 then proxy 1907, one key.
	const std::string proxy_812 = "[coop]\nkey = " + digest + "\nnick = Al\n";
	const std::string proxy_1907 = "[coop]\nkey=" + digest + "\nnick = Al the second\n";
	REQUIRE(coop::ledger::character_key(proxy_812) == digest);
	REQUIRE(coop::ledger::character_key(proxy_1907) == digest);

	spawn::BudgetBook book;
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(coop::ledger::character_key(proxy_812)), policy,
	          0) == SpawnVerdict::Allow);
	CHECK(spawn::judge(rule, nullptr, facts(1), book.of(coop::ledger::character_key(proxy_1907)), policy, 0) ==
	    SpawnVerdict::OverBudget); // the spent budget stays with the key
	CHECK_EQ(book.size(), size_t(1));

	// A save from before R1 I1 keeps the key itself: the same digest, the same budget.
	coop::PlayerKey key{};
	for (size_t i = 0; i < key.size(); ++i)
		key[i] = uint8_t(i * 5 + 3);
	static const char* hex = "0123456789abcdef";
	std::string raw;
	for (uint8_t byte : key)
	{
		raw += hex[byte >> 4];
		raw += hex[byte & 15];
	}
	std::string key_digest;
	REQUIRE(coop::key_digest_hex(key, key_digest));
	const std::string old_save = "[coop]\nkey = " + raw + "\n";
	const std::string new_save = "[coop]\nkey = " + key_digest + "\n";
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(coop::ledger::character_key(old_save)), policy,
	          0) == SpawnVerdict::Allow);
	CHECK(spawn::judge(rule, nullptr, facts(1), book.of(coop::ledger::character_key(new_save)), policy, 0) ==
	    SpawnVerdict::OverBudget);

	// Another player's key starts full.
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(std::string(64, 'b')), policy, 0) ==
	    SpawnVerdict::Allow);
}

// Ruling F2-17: the game object of each clsid (the client class the factory builds) and the lines its Load chain reads
// unchecked from the item's own section.
TEST(spawn_game_classes)
{
	using spawn::GameClass;
	const auto game_of = [](std::string_view clsid)
	{
		const spawn::ClassRule* r = spawn::class_rule(clsid);
		return r ? int(r->game) : -1;
	};
	CHECK_EQ(game_of("WP_AK74"), int(GameClass::WeaponMagazinedWGrenade)); // CWeaponAK74
	CHECK_EQ(game_of("W_FN2000"), int(GameClass::WeaponMagazined)); // CWeaponFN2000: no grenade launcher class
	CHECK_EQ(game_of("WP_RPG7"), int(GameClass::WeaponRPG7));
	CHECK_EQ(game_of("WP_RG6"), int(GameClass::WeaponRocket));
	CHECK_EQ(game_of("_WP_SSRS"), int(GameClass::WeaponRocket));
	CHECK_EQ(game_of("W_KNIFE"), int(GameClass::WeaponKnife));
	CHECK_EQ(game_of("WP_BINOC"), int(GameClass::WeaponBinoculars));
	CHECK_EQ(game_of("WP_ASHTG"), int(GameClass::WeaponMagazined));
	CHECK_EQ(game_of("AMMO_S"), int(GameClass::Ammo));
	CHECK_EQ(game_of("WP_GLAUN"), int(GameClass::GrenadeLauncher));
	CHECK_EQ(game_of("WP_SCOPE"), int(GameClass::InventoryItem));
	CHECK_EQ(game_of("II_FOOD"), int(GameClass::InventoryItem));
	CHECK_EQ(game_of("S_EXPLO"), int(GameClass::ExplosiveItem));
	CHECK_EQ(game_of("II_BOLT"), int(GameClass::Missile));
	CHECK_EQ(game_of("G_F1_S"), int(GameClass::Grenade));
	CHECK_EQ(game_of("G_FAKE"), int(GameClass::ExplosiveRocket));
	CHECK_EQ(game_of("E_STLK"), int(GameClass::CustomOutfit));
	CHECK_EQ(game_of("E_HLMET"), int(GameClass::Helmet));
	CHECK_EQ(game_of("EQ_HLMET"), int(GameClass::Helmet)); // engine helmet: CSE_ALifeItem, but a CHelmet object
	CHECK_EQ(game_of("EQ_BAKPK"), int(GameClass::Backpack));
	CHECK_EQ(game_of("TORCH_S"), int(GameClass::Torch));
	CHECK_EQ(game_of("SCRPTART"), int(GameClass::Artefact));
	CHECK_EQ(game_of("AF_BAST"), int(GameClass::BastArtefact));
	CHECK_EQ(game_of("AF_NEEDL"), int(GameClass::BlackGraviArtefact));
	CHECK_EQ(game_of("AF_MBALL"), int(GameClass::MercuryBall));
	CHECK_EQ(game_of("S_PDA"), int(GameClass::Pda));
	CHECK_EQ(game_of("D_FLARE"), int(GameClass::Flare));
	CHECK_EQ(game_of("D_FLALIT"), int(GameClass::CustomDevice));
	CHECK_EQ(game_of("DET_ELIT"), int(GameClass::CustomDetector));

	// Every group: the item's lines first; every line cites its read.
	for (uint8_t g = 0; g < spawn::kGameClassCount; ++g)
	{
		const std::vector<spawn::GameLine> lines = spawn::game_lines(spawn::GameClass(g));
		REQUIRE(lines.size() >= std::size(spawn::kInventoryItemLines));
		CHECK(std::string(lines[0].line) == "immunities_sect");
		for (const spawn::GameLine& line : lines)
		{
			const std::string src = line.src ? line.src : "";
			CHECK(src.find(".cpp:") != std::string::npos || src.find(".h:") != std::string::npos);
		}
	}
	const auto has_game_line = [](GameClass g, const char* name)
	{
		for (const spawn::GameLine& line : spawn::game_lines(g))
			if (std::string(line.line) == name)
				return true;
		return false;
	};
	for (const char* line :
	    {"inv_name", "inv_name_short", "description", "slot", "immunities_sect", "inv_weight", "cost"})
		CHECK(has_game_line(GameClass::InventoryItem, line));
	CHECK(!has_game_line(GameClass::InventoryItem, "hud"));
	for (const char* line : {"hud", "animation_slot", "rpm", "fire_point", "ammo_mag_size", "PDM_disp_base",
	         "scope_name", "silencer_light_color", "grenade_class", "launch_speed", "grenade_vel"})
		CHECK(has_game_line(GameClass::WeaponMagazinedWGrenade, line));
	CHECK(!has_game_line(GameClass::WeaponMagazined, "grenade_class"));
	CHECK(has_game_line(GameClass::WeaponRPG7, "rocket_class"));
	CHECK(has_game_line(GameClass::WeaponKnife, "splash_hit_divide_factor"));
	CHECK(!has_game_line(GameClass::WeaponKnife, "silencer_light_color")); // CWeapon::InitAddons loads no lights
	CHECK(has_game_line(GameClass::Ammo, "k_hit"));
	CHECK(has_game_line(GameClass::ExplosiveRocket, "blast"));
	CHECK(!has_game_line(GameClass::ExplosiveRocket, "hud")); // CCustomRocket is no HUD item
	CHECK(has_game_line(GameClass::Grenade, "force_min") && has_game_line(GameClass::Grenade, "explode_duration"));
	CHECK(has_game_line(GameClass::Artefact, "af_rank") && has_game_line(GameClass::Artefact, "can_be_controlled"));
	CHECK(has_game_line(GameClass::CustomDetector, "af_radius"));
	CHECK(has_game_line(GameClass::CustomOutfit, "full_icon_name"));
	CHECK(!has_game_line(GameClass::Helmet, "full_icon_name"));
}

TEST(spawn_missing_line)
{
	const spawn::ClassRule* ak = spawn::class_rule("WP_AK74");
	REQUIRE(ak);
	const FakeIni ini = complete(*ak);
	CHECK(!spawn::missing_line(*ak, ini).line);

	// A line of the server entity first, then of the game object.
	CHECK(is_missing(missing_with(*ak, {"cost"}, {}), "cost"));
	for (const char* line : {"inv_name", "description", "hud", "rpm", "fire_point", "grenade_class", "launch_speed"})
	{
		const spawn::Missing m = missing_with(*ak, {line}, {});
		CHECK(is_missing(m, line));
		CHECK(m.in == nullptr && !m.no_section);
	}

	// The immunities section the item names: it must exist and have the nine lines (CHitImmunity::LoadImmunities).
	spawn::Missing m = missing_with(*ak, {}, {{"immunities_sect", "nosuch"}});
	CHECK(is_missing(m, "immunities_sect") && m.no_section);
	FakeIni imm_cut = ini;
	imm_cut.others["imm"].erase("explosion_immunity");
	m = spawn::missing_line(*ak, imm_cut);
	CHECK(is_missing(m, "explosion_immunity") && m.in && std::string(m.in) == "immunities_sect" && !m.no_section);
}

TEST(spawn_missing_line_conditions)
{
	const spawn::ClassRule* ak = spawn::class_rule("WP_AK74");
	const spawn::ClassRule* knife = spawn::class_rule("WP_KNIFE");
	const spawn::ClassRule* food = spawn::class_rule("II_FOOD");
	const spawn::ClassRule* af = spawn::class_rule("SCRPTART");
	REQUIRE(ak && knife && food && af);

	// In a slot or on the belt: three more lines (inventory_item.cpp).
	const std::initializer_list<const char*> slot_lines = {
	    "default_to_ruck", "sprint_allowed", "control_inertion_factor"};
	CHECK(!missing_with(*food, slot_lines, {{"slot", "-1"}}).line);
	CHECK(is_missing(missing_with(*food, slot_lines, {{"slot", "2"}}), "default_to_ruck"));
	CHECK(is_missing(missing_with(*food, slot_lines, {{"slot", "-1"}, {"belt", "true"}}), "default_to_ruck"));
	CHECK(!missing_with(*food, slot_lines, {{"slot", "-1"}, {"belt", "false"}}).line);

	// Shot light unless light_disabled; the silencer's own lights for a permanent or attachable silencer.
	const std::initializer_list<const char*> lights = {"light_color", "light_range", "light_var_color",
	    "light_var_range", "light_time", "silencer_light_color", "silencer_light_range", "silencer_light_var_color",
	    "silencer_light_var_range", "silencer_light_time"};
	CHECK(!missing_with(*ak, lights, {{"light_disabled", "true"}}).line);
	CHECK(is_missing(missing_with(*ak, lights, {{"light_disabled", "false"}}), "light_color"));
	CHECK(is_missing(missing_with(*ak, lights, {}), "light_color"));
	CHECK(!missing_with(*ak, {"silencer_light_color"}, {{"silencer_status", "0"}}).line);
	CHECK(is_missing(missing_with(*ak, {"silencer_light_color"}, {{"silencer_status", "1"}}), "silencer_light_color"));
	CHECK(is_missing(missing_with(*ak, {"silencer_light_color"}, {{"silencer_status", "2"}}), "silencer_light_color"));
	CHECK(!missing_with(*knife, {"silencer_light_color"}, {{"silencer_status", "1"}}).line); // knife: no such lights

	// Addons attachable: their names and inventory offsets.
	CHECK(!missing_with(*ak, {"silencer_name", "silencer_x"}, {{"silencer_status", "1"}}).line);
	CHECK(is_missing(missing_with(*ak, {"silencer_name"}, {{"silencer_status", "2"}}), "silencer_name"));
	CHECK(!missing_with(*ak, {"grenade_launcher_name"}, {{"grenade_launcher_status", "1"}}).line);
	CHECK(is_missing(missing_with(*ak, {"grenade_launcher_y"}, {{"grenade_launcher_status", "2"}}),
	    "grenade_launcher_y"));
	// A permanent launcher: its grenade speed (CWeaponMagazinedWGrenade).
	CHECK(is_missing(missing_with(*ak, {"grenade_vel"}, {{"grenade_launcher_status", "1"}}), "grenade_vel"));
	CHECK(!missing_with(*ak, {"grenade_vel"}, {{"grenade_launcher_status", "2"}}).line);
	// An attachable scope: its own scope_name (no scopes_sect), or the modular group.
	CHECK(is_missing(missing_with(*ak, {"scope_name", "scopes_sect"}, {{"scope_status", "2"}}), "scope_name"));
	CHECK(!missing_with(*ak, {"scope_name"}, {{"scope_status", "2"}, {"scopes_sect", "wpn_sight_x"}}).line);
	CHECK(!missing_with(*ak, {"scope_name"}, {{"scope_status", "1"}}).line);
	CHECK(is_missing(
	    missing_with(*ak, {"modular_scope_group"}, {{"scope_status", "2"}, {"modular_attachments", "true"}}),
	    "modular_scope_group"));
	CHECK(!missing_with(*ak, {"scope_name"}, {{"scope_status", "2"}, {"modular_attachments", "on"}}).line); // no name
	// First bullet, shell particles.
	CHECK(!missing_with(*ak, {"first_bullet_dispertion"}, {{"use_first_bullet", "false"}}).line);
	CHECK(is_missing(missing_with(*ak, {"first_bullet_timeout"}, {{"use_first_bullet", "true"}}),
	    "first_bullet_timeout"));
	CHECK(!missing_with(*ak, {"shell_point", "shell_particles"}, {}).line);
	CHECK(is_missing(missing_with(*ak, {"shell_point"}, {{"shell_particles", "generic_shells"}}), "shell_point"));
	// An artefact's trail light.
	CHECK(!missing_with(*af, {"trail_light_color"}, {{"lights_enabled", "false"}}).line);
	CHECK(is_missing(missing_with(*af, {"trail_light_color"}, {{"lights_enabled", "true"}}), "trail_light_color"));
}
