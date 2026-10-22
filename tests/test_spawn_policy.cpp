// Anomaly Coop unit tests: what a client may ask the host to create (F2 T2, coop_spawn.h): the class table (engine and
// script item classes only), the lines each class's server entity reads unchecked, and the verdict on a ReqSpawn:
// deny/allow lists, quest items and a cost budget per character for the whole session (Ruling F2-11).
#include "test_util.h"

#include "coop_spawn.h"

#include <algorithm>
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

// Ruling F2-11: the budget belongs to the character (the player's proxy on the host) for the whole session. A peer
// that leaves and joins again as the same character (a new connection, maybe a new peer id) refills nothing; only a
// new session clears it. A character the host has not seen yet starts with the full burst.
TEST(spawn_budget_survives_rejoin)
{
	const spawn::SpawnPolicy policy;
	const spawn::ClassRule* rule = item_rule();
	REQUIRE(rule);
	spawn::BudgetBook book;
	const uint16_t character = 0x1234; // proxy id in the host world
	uint64_t now = 1000;

	// Peer 3 plays character 0x1234 and spends the whole burst.
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(character), policy, now) ==
	    SpawnVerdict::Allow);
	CHECK(spawn::judge(rule, nullptr, facts(1), book.of(character), policy, now) == SpawnVerdict::OverBudget);

	// Peer 3 leaves; 100 ms later the same player joins again as peer 5 and gets the same character back.
	now += 100;
	CHECK(spawn::judge(rule, nullptr, facts(201), book.of(character), policy, now) == SpawnVerdict::OverBudget);
	CHECK(spawn::judge(rule, nullptr, facts(200), book.of(character), policy, now) == SpawnVerdict::Allow);
	CHECK_EQ(book.size(), size_t(1));

	// A new character (a new player key) starts full.
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(0x1235), policy, now) == SpawnVerdict::Allow);
	CHECK_EQ(book.size(), size_t(2));

	// A new session: everything is full again.
	book.clear();
	CHECK_EQ(book.size(), size_t(0));
	CHECK(spawn::judge(rule, nullptr, facts(policy.cost_burst), book.of(character), policy, now) ==
	    SpawnVerdict::Allow);
}
