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
		spawn::SectionFacts wrong_parent = facts(10);
		wrong_parent.parent_ok = false;
		CHECK(spawn::judge(rule, nullptr, wrong_parent, b, policy, 0) == SpawnVerdict::WrongParent);
		CHECK(spawn::judge(rule, nullptr, facts(10, false, false, true), b, policy, 0) == SpawnVerdict::Denied);
		CHECK(spawn::judge(rule, nullptr, facts(10, true), b, policy, 0) == SpawnVerdict::QuestItem);
		CHECK(!b.started); // refusals before the budget leave it alone
		CHECK(spawn::judge(rule, nullptr, facts(10, false, true), b, policy, 0) == SpawnVerdict::Allow);
		CHECK(!b.started); // an allow-listed section does not touch it either
		spawn::SectionFacts behind = facts(10);
		behind.queue_waiting = true; // earlier requests of the character wait: this one goes behind them
		CHECK(spawn::judge(rule, nullptr, behind, b, policy, 0) == SpawnVerdict::OverBudget);
		CHECK(!b.started);
		CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), b, policy, 0) == SpawnVerdict::Allow);
		CHECK(spawn::judge(rule, nullptr, facts(10), b, policy, 0) == SpawnVerdict::OverBudget);
	}

	// The order: an earlier check wins over every later one.
	spawn::CostBudget b;
	spawn::SectionFacts everything = facts(policy.cost_burst + 1, true, true, true);
	everything.parent_ok = false;
	everything.queue_waiting = true;
	CHECK(spawn::judge(nullptr, "cost", everything, b, policy, 0) == SpawnVerdict::UnknownClass);
	CHECK(spawn::judge(rule, "cost", everything, b, policy, 0) == SpawnVerdict::MissingLine);
	CHECK(spawn::judge(rule, nullptr, everything, b, policy, 0) == SpawnVerdict::WrongParent);
	everything.parent_ok = true;
	CHECK(spawn::judge(rule, nullptr, everything, b, policy, 0) == SpawnVerdict::Denied); // deny beats allow
	spawn::SectionFacts allowed = facts(policy.cost_burst + 1, true, true);
	allowed.queue_waiting = true;
	CHECK(spawn::judge(rule, nullptr, allowed, b, policy, 0) == SpawnVerdict::Allow); // allow beats quest and budget
	spawn::SectionFacts quest = facts(policy.cost_burst + 1, true);
	quest.queue_waiting = true;
	CHECK(spawn::judge(rule, nullptr, quest, b, policy, 0) == SpawnVerdict::QuestItem); // quest beats budget
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
// on the client). Allowed only with all three: the item goes to the asking player's own character, he holds a talk
// lock right now, and his character stands within talk reach of that NPC on the host (round 2 minor, as host_try_lock).
// It still costs the budget.
TEST(spawn_quest_item_in_dialog)
{
	const spawn::SpawnPolicy policy;
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);
	const uint16_t me = 0x1234, other = 0x2222;
	const float near = 2.f;

	CHECK(spawn::quest_gift(true, near, me, me));
	CHECK(!spawn::quest_gift(false, near, me, me)); // no talk lock
	CHECK(!spawn::quest_gift(true, near, other, me)); // into somebody else's (or a box, or one of his own items)
	CHECK(!spawn::quest_gift(true, near, 0xffff, 0xffff)); // no character
	CHECK(spawn::quest_gift(true, spawn::kTalkReach, me, me)); // right at talk reach (coop_dialog kTalkReach)
	CHECK(!spawn::quest_gift(true, spawn::kTalkReach + 0.01f, me, me)); // walked away from the NPC
	CHECK(!spawn::quest_gift(true, 1e30f, me, me)); // the NPC or the character is not in the host's world

	spawn::CostBudget b;
	spawn::SectionFacts f = facts(500, true);
	f.in_dialog_to_own_actor = spawn::quest_gift(true, near, me, me);
	CHECK(spawn::judge(rule, nullptr, f, b, policy, 0) == SpawnVerdict::Allow);
	CHECK(b.started && b.tokens == double(policy.cost_burst - 500)); // charged like any item
	f.in_dialog_to_own_actor = spawn::quest_gift(false, near, me, me);
	CHECK(spawn::judge(rule, nullptr, f, b, policy, 0) == SpawnVerdict::QuestItem);
	f.in_dialog_to_own_actor = spawn::quest_gift(true, near, other, me);
	CHECK(spawn::judge(rule, nullptr, f, b, policy, 0) == SpawnVerdict::QuestItem);
	f.in_dialog_to_own_actor = spawn::quest_gift(true, 7.f, me, me);
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

// ---------------------------------------------------------------- fix round 2 (review Important 1, Ruling F2-21)

// Important 1: inside one of the player's items (parent is not his character) the host creates only what that item's
// GE_OWNERSHIP_TAKE handler takes: a rocket in a rocket launcher (CRocketLauncher::AttachRocket casts the child to
// CCustomRocket unchecked), a missile of the same section in a missile (CMissile::OnEvent casts it to CMissile
// unchecked). Anything else into an item (bread into his bolt) was a host AV.
TEST(spawn_child_in_item)
{
	using spawn::GameClass;
	const auto ok = [](const char* parent_clsid, const char* parent_section, const char* child_clsid,
	                    const char* child_section)
	{
		const spawn::ClassRule* parent = spawn::class_rule(parent_clsid);
		const spawn::ClassRule* child = spawn::class_rule(child_clsid);
		REQUIRE(parent && child);
		return spawn::child_allowed(parent->game, parent_section, child->game, child_section, 0, 0);
	};
	// A launcher's rocket: the grenade launcher's fake missile, an RPG-7 rocket, RG-6 and SSRS shells.
	CHECK(ok("WP_AK74", "wpn_ak74", "G_FAKE", "wpn_fake_missile"));
	CHECK(ok("WP_GROZA", "wpn_groza", "G_FAKE", "wpn_fake_missile"));
	CHECK(ok("WP_RPG7", "wpn_rpg7", "G_RPG7", "wpn_rpg7_missile"));
	CHECK(ok("WP_RG6", "wpn_rg6", "G_FAKE", "wpn_fake_missile2"));
	CHECK(ok("_WP_SSRS", "wpn_ssrs", "G_RPG7", "wpn_ssrs_missile"));
	// A grenade's or bolt's fake missile: the same section.
	CHECK(ok("G_F1_S", "grenade_f1", "G_F1_S", "grenade_f1"));
	CHECK(ok("G_RGD5", "grenade_rgd5", "G_RGD5", "grenade_rgd5"));
	CHECK(ok("II_BOLT", "bolt", "II_BOLT", "bolt"));

	// Everything else into an item.
	CHECK(!ok("II_BOLT", "bolt", "II_FOOD", "bread")); // the review's crash: bread into his bolt
	CHECK(!ok("G_F1_S", "grenade_f1", "G_F1_S", "grenade_gd-05")); // another grenade
	CHECK(!ok("G_F1_S", "grenade_f1", "G_RGD5_S", "grenade_rgd5"));
	CHECK(!ok("WP_AK74", "wpn_ak74", "AMMO_S", "ammo_5.45x39_fmj")); // ammo into a weapon
	CHECK(!ok("WP_AK74", "wpn_ak74", "G_F1_S", "grenade_f1")); // a missile into a launcher
	CHECK(!ok("W_FN2000", "wpn_fn2000", "G_FAKE", "wpn_fake_missile")); // CWeaponFN2000 has no rocket launcher
	CHECK(!ok("WP_LR300", "wpn_lr300", "G_FAKE", "wpn_fake_missile"));
	CHECK(!ok("WP_KNIFE", "wpn_knife", "G_FAKE", "wpn_fake_missile"));
	CHECK(!ok("G_FAKE", "wpn_fake_missile", "G_FAKE", "wpn_fake_missile")); // a rocket is no launcher
	CHECK(!ok("E_STLK", "stalker_outfit", "AF_GRAVI", "af_gravi"));
	CHECK(!ok("SCRPTART", "af_medusa", "SCRPTART", "af_medusa")); // same section, but no missile
	CHECK(!ok("D_PDA", "device_pda", "II_DOC", "zat_b40_notebook"));

	// The verdict: WrongParent after the class and line checks, before the lists.
	const spawn::SpawnPolicy policy;
	spawn::CostBudget b;
	spawn::SectionFacts f = facts(10, false, true); // even allow-listed
	f.parent_ok = false;
	CHECK(spawn::judge(item_rule(), nullptr, f, b, policy, 0) == SpawnVerdict::WrongParent);
	CHECK(!b.started);
}

// Ruling F2-21 (1): an item dearer than the whole burst costs the burst; it is not refused for ever.
TEST(spawn_expensive_item)
{
	const spawn::SpawnPolicy policy;
	CHECK_EQ(spawn::charge_of(253200, policy), policy.cost_burst); // gauss_sight
	CHECK_EQ(spawn::charge_of(400000, policy), policy.cost_burst); // af_tlf_prometheus
	CHECK_EQ(spawn::charge_of(1500, policy), uint32_t(1500));
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);
	spawn::CostBudget b;
	CHECK(spawn::judge(rule, nullptr, facts(400000), b, policy, 0) == SpawnVerdict::Allow); // a full budget
	CHECK(b.tokens == 0.0);
	CHECK(spawn::judge(rule, nullptr, facts(1), b, policy, 0) == SpawnVerdict::OverBudget);
	CHECK(spawn::judge(rule, nullptr, facts(400000), b, policy, 99999) == SpawnVerdict::OverBudget); // 199 998 back
	CHECK(spawn::judge(rule, nullptr, facts(400000), b, policy, 100000) == SpawnVerdict::Allow); // 200 000: full

	// A refund (the engine refused what was charged) gives back the charge, up to the burst.
	spawn::CostBudget r;
	CHECK(spawn::charge(r, 400000, policy, 0));
	spawn::refund(r, 400000, policy);
	CHECK(r.tokens == double(policy.cost_burst));
	spawn::refund(r, 1000, policy);
	CHECK(r.tokens == double(policy.cost_burst)); // never above the burst
	CHECK(spawn::charge(r, 1000, policy, 0));
	CHECK(r.tokens == double(policy.cost_burst - 1000));
}

namespace
{
// A request in the tests: what the host's queue keeps of it (spawn::QueuedRequest, data only) and test switches
// for what the host would find when its turn comes.
struct Wanted
{
	int id = 0;
	uint32_t cost = 0;
	bool engine_refuses = false; // the holder is gone, or the engine refuses the entity
	bool quest = false; // a quest item
	bool deny_now = false; // the host's deny list has it when its turn comes
	spawn::QueuedRequest req;
};

// The host's flow for a request (coop_requests host_on_spawn): judge, then queue an OverBudget one behind the others.
// Returns: 1 created now, 0 queued, -1 refused.
int ask(spawn::SpawnQueue<Wanted>& queue, spawn::BudgetBook& book, const std::string& key, Wanted w,
    std::vector<int>& created, uint64_t now)
{
	const spawn::SpawnPolicy policy;
	spawn::SectionFacts f = facts(w.cost, w.quest);
	f.in_dialog_to_own_actor = w.req.quest_gift;
	f.queue_waiting = queue.waiting(key);
	const SpawnVerdict v = spawn::judge(item_rule(), nullptr, f, book.of(key), policy, now);
	if (v == SpawnVerdict::Allow)
	{
		created.push_back(w.id);
		return 1;
	}
	if (v == SpawnVerdict::OverBudget && queue.push(key, w))
		return 0;
	return -1;
}

// The host's turn for the front request (coop_requests create_queued): judged again from what the host knows now, with
// the quest gift decided when it was asked; Wait while the budget does not hold it; what the engine refuses after the
// charge is refunded.
spawn::Turn turn(spawn::BudgetBook& book, const std::string& key, Wanted& w, std::vector<int>& created, uint64_t now)
{
	const spawn::SpawnPolicy policy;
	const spawn::SectionFacts f = facts(w.cost, w.quest, false, w.deny_now);
	const SpawnVerdict v = spawn::judge_queued(item_rule(), nullptr, f, w.req, book.of(key), policy, now);
	if (v == SpawnVerdict::OverBudget)
		return spawn::Turn::Wait;
	if (v != SpawnVerdict::Allow)
		return spawn::Turn::Refused;
	if (w.engine_refuses)
	{
		if (!spawn::budget_free(f))
			spawn::refund(book.of(key), w.cost, policy);
		return spawn::Turn::Refused;
	}
	created.push_back(w.id);
	return spawn::Turn::Created;
}

// The turns at `now`, for SpawnQueue::pump.
auto at(spawn::BudgetBook& book, const std::string& key, std::vector<int>& created, uint64_t now)
{
	return [&book, &key, &created, now](Wanted& w) { return turn(book, key, w, created, now); };
}
} // namespace

// Ruling F2-21 (2): over the budget a request waits on the host and is created when the budget has refilled for it,
// in the order asked; later requests of the same character go behind it even when they would fit.
TEST(spawn_queue_order)
{
	const spawn::SpawnPolicy policy;
	spawn::SpawnQueue<Wanted> queue;
	spawn::BudgetBook book;
	const std::string key(64, 'q');
	std::vector<int> created;
	CHECK_EQ(ask(queue, book, key, {1, policy.cost_burst}, created, 0), 1); // the whole burst at once
	CHECK_EQ(ask(queue, book, key, {2, 2000}, created, 0), 0);
	CHECK_EQ(ask(queue, book, key, {3, 2000}, created, 0), 0);
	CHECK_EQ(ask(queue, book, key, {4, 2000}, created, 0), 0);
	CHECK_EQ(queue.size(key), size_t(3));
	CHECK(queue.waiting(key));
	CHECK_EQ(queue.total(), size_t(3));

	CHECK_EQ(queue.pump(key, at(book, key, created, 999)), size_t(0)); // 1 998 back: not enough yet
	CHECK_EQ(queue.pump(key, at(book, key, created, 1000)), size_t(1)); // 2 000: the first one
	// A cheap request of the same character while two wait: behind them, though 0 would fit.
	CHECK_EQ(ask(queue, book, key, {5, 0}, created, 1000), 0);
	CHECK_EQ(queue.pump(key, at(book, key, created, 3000)), size_t(3)); // 4 000: two more, then the free one
	CHECK(!queue.waiting(key));
	CHECK((created == std::vector<int>{1, 2, 3, 4, 5}));
	CHECK_EQ(ask(queue, book, key, {6, 1}, created, 3000), 0); // the budget is empty again: it waits
	CHECK_EQ(queue.pump(key, at(book, key, created, 3001)), size_t(1));
	CHECK((created == std::vector<int>{1, 2, 3, 4, 5, 6}));

	// Another character is not behind this one's queue.
	const std::string other(64, 'o');
	CHECK_EQ(ask(queue, book, key, {7, policy.cost_burst}, created, 3001), 0);
	CHECK_EQ(ask(queue, book, other, {8, 100}, created, 3001), 1);
}

// At most kMaxQueued requests wait per character: the 257th is refused (RateLimited on the host).
TEST(spawn_queue_full)
{
	static_assert(spawn::kMaxQueued == 256, "Ruling F2-21: 256 per character");
	const spawn::SpawnPolicy policy;
	spawn::SpawnQueue<Wanted> queue;
	spawn::BudgetBook book;
	const std::string key(64, 'f');
	std::vector<int> created;
	CHECK_EQ(ask(queue, book, key, {0, policy.cost_burst}, created, 0), 1);
	for (int i = 1; i <= 256; ++i)
		CHECK_EQ(ask(queue, book, key, {i, 1000}, created, 0), 0);
	CHECK_EQ(queue.size(key), size_t(256));
	CHECK_EQ(ask(queue, book, key, {257, 1000}, created, 0), -1); // full
	CHECK_EQ(queue.size(key), size_t(256));
	// Another character has a queue of his own.
	CHECK_EQ(ask(queue, book, std::string(64, 'g'), {258, policy.cost_burst}, created, 0), 1);
	CHECK_EQ(ask(queue, book, std::string(64, 'g'), {259, 1}, created, 0), 0);
}

// The character leaving (or the world replaced) empties his queue: nothing of it is created later.
TEST(spawn_queue_drop)
{
	const spawn::SpawnPolicy policy;
	spawn::SpawnQueue<Wanted> queue;
	spawn::BudgetBook book;
	const std::string key(64, 'l'), other(64, 'm');
	std::vector<int> created;
	CHECK_EQ(ask(queue, book, key, {1, policy.cost_burst}, created, 0), 1);
	CHECK_EQ(ask(queue, book, key, {2, 1000}, created, 0), 0);
	CHECK_EQ(ask(queue, book, key, {3, 1000}, created, 0), 0);
	CHECK_EQ(ask(queue, book, other, {4, policy.cost_burst}, created, 0), 1);
	CHECK_EQ(ask(queue, book, other, {5, 1000}, created, 0), 0);

	std::vector<int> dropped;
	CHECK_EQ(queue.drop(key, [&](Wanted& w) { dropped.push_back(w.id); }), size_t(2));
	CHECK((dropped == std::vector<int>{2, 3}));
	CHECK(!queue.waiting(key));
	CHECK_EQ(queue.total(), size_t(1));
	CHECK_EQ(queue.pump(key, at(book, key, created, 100000)), size_t(0)); // nothing left of his
	CHECK_EQ(queue.pump(other, at(book, other, created, 100000)), size_t(1));
	CHECK((created == std::vector<int>{1, 4, 5}));

	// Only some of a queue: the ones of an older world, by a predicate.
	CHECK_EQ(ask(queue, book, other, {6, policy.cost_burst}, created, 100000), 0);
	CHECK_EQ(ask(queue, book, other, {7, 1}, created, 100000), 0);
	dropped.clear();
	const auto older = [](const Wanted& w) { return w.id == 6; };
	CHECK_EQ(queue.drop_if(other, older, [&](Wanted& w) { dropped.push_back(w.id); }), size_t(1));
	CHECK((dropped == std::vector<int>{6}));
	CHECK_EQ(queue.size(other), size_t(1));

	// A new session: everything goes.
	dropped.clear();
	queue.clear([&](Wanted& w) { dropped.push_back(w.id); });
	CHECK((dropped == std::vector<int>{7}));
	CHECK_EQ(queue.total(), size_t(0));
}

// Ruling F2-21 (3): what the engine refused after the charge goes back to the budget; the queue goes on.
TEST(spawn_queue_refund)
{
	const spawn::SpawnPolicy policy;
	spawn::SpawnQueue<Wanted> queue;
	spawn::BudgetBook book;
	const std::string key(64, 'r');
	std::vector<int> created;
	CHECK_EQ(ask(queue, book, key, {1, policy.cost_burst}, created, 0), 1);
	CHECK_EQ(ask(queue, book, key, {2, 5000, true}, created, 0), 0); // the engine will refuse it
	CHECK_EQ(ask(queue, book, key, {3, 5000}, created, 0), 0);
	// 10 000 came back; the engine refuses #2 (its holder is gone): its 5 000 come back, #3 is created.
	CHECK_EQ(queue.pump(key, at(book, key, created, 5000)), size_t(1));
	CHECK((created == std::vector<int>{1, 3}));
	CHECK(book.of(key).tokens == 5000.0); // 10 000 - 5 000 (#3); #2's charge came back
}

// ---------------------------------------------------------------- fix round 3 (Ruling F2-22)

// A child the parent item takes (child_allowed: a rocket in its launcher, a fake missile in its grenade or bolt) is a
// shot: the charge already left the client's inventory. It costs no budget and never waits in the queue; the parent
// check (WrongParent) and the deny list still apply.
TEST(spawn_launch_child_is_free)
{
	const spawn::SpawnPolicy policy;
	const spawn::ClassRule* rocket = spawn::class_rule("G_FAKE");
	const spawn::ClassRule* launcher = spawn::class_rule("WP_AK74");
	REQUIRE(rocket && launcher);
	spawn::SpawnQueue<Wanted> queue;
	spawn::BudgetBook book;
	const std::string key(64, 'k');
	std::vector<int> created;

	// The budget is used up and requests of the character wait.
	CHECK_EQ(ask(queue, book, key, {1, policy.cost_burst}, created, 0), 1);
	CHECK_EQ(ask(queue, book, key, {2, 1000}, created, 0), 0);
	const spawn::CostBudget before = book.of(key);

	// A rocket into his own grenade launcher: created at once, behind nothing, the budget as it was.
	spawn::SectionFacts shot = facts(150); // wpn_fake_missile costs 150
	shot.parent_ok = spawn::child_allowed(launcher->game, "wpn_ak74", rocket->game, "wpn_fake_missile", 0, 1);
	shot.launch_child = shot.parent_ok;
	shot.queue_waiting = queue.waiting(key);
	REQUIRE(shot.parent_ok && shot.queue_waiting);
	CHECK(spawn::budget_free(shot));
	CHECK(spawn::judge(rocket, nullptr, shot, book.of(key), policy, 0) == SpawnVerdict::Allow);
	CHECK(book.of(key).tokens == before.tokens);
	CHECK(book.of(key).at == before.at);
	CHECK_EQ(queue.size(key), size_t(1)); // the queue is as it was
	// Later too, while the queue waits: again and again, nothing taken.
	for (int i = 0; i < 20; ++i)
		CHECK(spawn::judge(rocket, nullptr, shot, book.of(key), policy, 10) == SpawnVerdict::Allow);
	CHECK(book.of(key).tokens == before.tokens);

	// Still refused: the same rocket into an item that does not take it, a deny-listed one.
	spawn::SectionFacts wrong = facts(150);
	wrong.parent_ok = spawn::child_allowed(spawn::GameClass::WeaponMagazined, "wpn_lr300", rocket->game,
	    "wpn_fake_missile", 0, 30);
	wrong.launch_child = wrong.parent_ok;
	CHECK(!wrong.parent_ok && !spawn::budget_free(wrong));
	CHECK(spawn::judge(rocket, nullptr, wrong, book.of(key), policy, 0) == SpawnVerdict::WrongParent);
	spawn::SectionFacts denied = shot;
	denied.deny_listed = true;
	CHECK(spawn::judge(rocket, nullptr, denied, book.of(key), policy, 0) == SpawnVerdict::Denied);

	// An ordinary item into his character still pays and queues.
	CHECK(!spawn::budget_free(facts(150)));
	CHECK_EQ(ask(queue, book, key, {3, 150}, created, 10), 0);
}

// ---------------------------------------------------------------- fix round 4 (review: Important 1 and 2, minors)

// Important 1 (F2-22): a free child only while its parent has room: a grenade or bolt holds one fake missile, a
// launcher one rocket, a revolver grenade launcher (CWeaponRG6, CWeaponSSRS: a rocket per loaded round) its magazine.
// A second "fake missile" into one grenade overwrote m_fake_missile, the first one came out by ReqDrop as a whole
// grenade that CMissile::OnEvent's reject never destroys: about 20 real grenades a second, free.
TEST(spawn_child_room)
{
	using spawn::GameClass;
	const auto fits = [](GameClass parent, const char* parent_section, GameClass child, const char* child_section,
	                      size_t children, long long mag_size)
	{ return spawn::child_allowed(parent, parent_section, child, child_section, children, mag_size); };

	// Two fake missiles in a row into one grenade: the second is refused.
	CHECK(fits(GameClass::Grenade, "grenade_f1", GameClass::Grenade, "grenade_f1", 0, 0));
	CHECK(!fits(GameClass::Grenade, "grenade_f1", GameClass::Grenade, "grenade_f1", 1, 0));
	CHECK(!fits(GameClass::Grenade, "grenade_f1", GameClass::Grenade, "grenade_f1", 1, 30)); // no magazine counts
	CHECK(fits(GameClass::Missile, "bolt", GameClass::Missile, "bolt", 0, 0));
	CHECK(!fits(GameClass::Missile, "bolt", GameClass::Missile, "bolt", 1, 0));
	// A grenade launcher, an RPG-7: one rocket, whatever ammo_mag_size says.
	CHECK(fits(GameClass::WeaponMagazinedWGrenade, "wpn_ak74", GameClass::ExplosiveRocket, "wpn_fake_missile", 0, 30));
	CHECK(!fits(GameClass::WeaponMagazinedWGrenade, "wpn_ak74", GameClass::ExplosiveRocket, "wpn_fake_missile", 1, 30));
	CHECK(fits(GameClass::WeaponRPG7, "wpn_rpg7", GameClass::ExplosiveRocket, "wpn_rpg7_missile", 0, 1));
	CHECK(!fits(GameClass::WeaponRPG7, "wpn_rpg7", GameClass::ExplosiveRocket, "wpn_rpg7_missile", 1, 1));
	// RG-6 / SSRS: up to the magazine of its section; 1 when the section shows none.
	for (size_t n = 0; n < 6; ++n)
		CHECK(fits(GameClass::WeaponRocket, "wpn_rg6", GameClass::ExplosiveRocket, "wpn_fake_missile2", n, 6));
	CHECK(!fits(GameClass::WeaponRocket, "wpn_rg6", GameClass::ExplosiveRocket, "wpn_fake_missile2", 6, 6));
	CHECK(fits(GameClass::WeaponRocket, "wpn_ssrs", GameClass::ExplosiveRocket, "wpn_ssrs_missile", 0, 0));
	CHECK(!fits(GameClass::WeaponRocket, "wpn_ssrs", GameClass::ExplosiveRocket, "wpn_ssrs_missile", 1, 0));
	CHECK(!fits(GameClass::WeaponRocket, "wpn_ssrs", GameClass::ExplosiveRocket, "wpn_ssrs_missile", 1, -5));
	CHECK_EQ(spawn::child_room(GameClass::WeaponRocket, 6), size_t(6));
	CHECK_EQ(spawn::child_room(GameClass::WeaponRocket, 0), size_t(1));
	CHECK_EQ(spawn::child_room(GameClass::Grenade, 6), size_t(1));

	// The verdict on the second: WrongParent, no budget asked.
	const spawn::SpawnPolicy policy;
	spawn::CostBudget b;
	spawn::SectionFacts second = facts(300);
	second.parent_ok = fits(GameClass::Grenade, "grenade_f1", GameClass::Grenade, "grenade_f1", 1, 0);
	second.launch_child = second.parent_ok;
	CHECK(spawn::judge(spawn::class_rule("G_F1_S"), nullptr, second, b, policy, 0) == SpawnVerdict::WrongParent);
	CHECK(!b.started);
}

// Minor: a launcher's rocket (CSE_Temporary) goes only into its launcher; straight into the character it is refused.
TEST(spawn_rocket_not_into_character)
{
	using spawn::GameClass;
	CHECK(!spawn::character_takes(GameClass::ExplosiveRocket));
	for (uint8_t g = 0; g < spawn::kGameClassCount; ++g)
		if (GameClass(g) != GameClass::ExplosiveRocket)
			CHECK(spawn::character_takes(GameClass(g)));
	const spawn::ClassRule* rocket = spawn::class_rule("G_RPG7");
	REQUIRE(rocket);
	const spawn::SpawnPolicy policy;
	spawn::CostBudget b;
	spawn::SectionFacts into_character = facts(200, false, true); // even allow-listed
	into_character.parent_ok = spawn::character_takes(rocket->game);
	CHECK(spawn::judge(rocket, nullptr, into_character, b, policy, 0) == SpawnVerdict::WrongParent);
}

// Important 2 (F2-21): the queue keeps data only - the section, the parent, its own copy of the item state, the world
// epoch, the quest gift decided when asked - never a built entity (a script class's server entity holds Lua references
// that a save load closes under it). The host builds and checks the entity again when the request's turn comes.
TEST(spawn_queue_keeps_data)
{
	static_assert(std::is_copy_constructible_v<spawn::QueuedRequest>, "plain data");
	static_assert(std::is_copy_assignable_v<spawn::QueuedRequest>, "plain data");
	std::vector<uint8_t> message = {1, 2, 3, 4, 5};
	std::string section = "wpn_ak74";
	const float pos[3] = {1.f, 2.f, 3.f};
	const spawn::QueuedRequest r =
	    spawn::queued_request(77, 3, 0x1234, 0x1234, pos, section, message.data(), message.size(), 9, true);
	// The message and the section text go away; the request keeps its own copies.
	message.assign(5, 0xEE);
	message.clear();
	section = "something_else";
	CHECK_EQ(r.seq, uint32_t(77));
	CHECK_EQ(r.peer, uint32_t(3));
	CHECK_EQ(r.character, uint16_t(0x1234));
	CHECK_EQ(r.parent, uint16_t(0x1234));
	CHECK(r.pos[0] == 1.f && r.pos[1] == 2.f && r.pos[2] == 3.f);
	CHECK_EQ(r.section, std::string("wpn_ak74"));
	CHECK((r.state == std::vector<uint8_t>{1, 2, 3, 4, 5}));
	CHECK_EQ(r.epoch, uint32_t(9));
	CHECK(r.quest_gift);
	const spawn::QueuedRequest empty = spawn::queued_request(1, 1, 2, 2, pos, "bread", nullptr, 0, 0, false);
	CHECK(empty.state.empty());
}

// ... and judges it again at its turn: what the host's configs say now decides; only the quest gift is the one decided
// when it was asked (the talk may be over by then).
TEST(spawn_queue_rechecked)
{
	const spawn::SpawnPolicy policy;
	spawn::SpawnQueue<Wanted> queue;
	spawn::BudgetBook book;
	const std::string key(64, 'c');
	std::vector<int> created;
	CHECK_EQ(ask(queue, book, key, {1, policy.cost_burst}, created, 0), 1);
	Wanted denied{2, 1000};
	denied.deny_now = true; // the host's deny list has it by its turn
	CHECK_EQ(ask(queue, book, key, denied, created, 0), 0);
	Wanted gift{3, 1000};
	gift.quest = true;
	gift.req.quest_gift = true; // asked during the talk
	CHECK_EQ(ask(queue, book, key, gift, created, 0), 0);
	Wanted quest{4, 1000};
	quest.quest = true; // a quest item: refused when asked already
	CHECK_EQ(ask(queue, book, key, quest, created, 0), -1);
	CHECK_EQ(ask(queue, book, key, {5, 1000}, created, 0), 0);

	// 10 000 back: #2 is refused at its turn (no charge), #3 the quest gift and #5 are created.
	CHECK_EQ(queue.pump(key, at(book, key, created, 5000)), size_t(2));
	CHECK((created == std::vector<int>{1, 3, 5}));
	CHECK(book.of(key).tokens == 8000.0);

	// The turn's verdict on its own: a quest item without the gift recorded is refused, whatever the facts say now.
	spawn::QueuedRequest none;
	spawn::SectionFacts f = facts(1, true);
	f.in_dialog_to_own_actor = true; // ignored: the request's own decision counts
	spawn::CostBudget b;
	CHECK(spawn::judge_queued(item_rule(), nullptr, f, none, b, policy, 0) == SpawnVerdict::QuestItem);
	f.queue_waiting = true; // ignored: it is the front of its queue
	none.quest_gift = true;
	CHECK(spawn::judge_queued(item_rule(), nullptr, f, none, b, policy, 0) == SpawnVerdict::Allow);
}
