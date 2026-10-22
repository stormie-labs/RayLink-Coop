// Anomaly Coop unit tests: what the host checks in a client's ReqSpawn before it builds the entity (R3 В6):
// the wire layout (coop_spawn.h), the lines a class constructor reads, and the order of upgrades the engine can
// install without a FATAL (coop_upgrades.h).
#include "test_util.h"

#include "coop_spawn.h"
#include "coop_upgrades.h"

#include <algorithm>
#include <string>
#include <vector>

using namespace coop;

namespace
{
std::vector<uint8_t> state_request(uint32_t seq, uint16_t parent, const std::string& section, size_t state_size)
{
	const float pos[3] = {1.f, 2.f, 3.f};
	std::vector<uint8_t> state(state_size, 0x5A);
	Writer w;
	spawn::write_state(w, seq, parent, pos, section, state.data(), state.size());
	return w.data();
}

bool has_line(const std::vector<const char*>& lines, const char* name)
{
	return std::find_if(lines.begin(), lines.end(), [&](const char* s) { return std::string(s) == name; }) !=
	    lines.end();
}

upgrades::Upgrade up(const char* id, const char* group, std::vector<std::string> needs = {}, bool in_tree = true)
{
	upgrades::Upgrade u;
	u.id = id;
	u.group = group;
	u.needs_groups = std::move(needs);
	u.in_tree = in_tree;
	return u;
}
} // namespace

TEST(spawn_request_roundtrip)
{
	const std::vector<uint8_t> msg = state_request(77, 0x1234, "wpn_ak74", 12);
	REQUIRE(spawn::detect(msg.data(), msg.size()) == spawn::Layout::State);
	Reader r(msg.data(), msg.size());
	CHECK_EQ(r.u32(), 77u); // seq: read by the common request header
	spawn::Request q;
	REQUIRE(spawn::read_body(r, spawn::Layout::State, q));
	CHECK_EQ(q.parent, 0x1234);
	CHECK(q.pos[0] == 1.f && q.pos[1] == 2.f && q.pos[2] == 3.f);
	CHECK(q.section == "wpn_ak74");
	CHECK_EQ(q.state_size, size_t(12));
	REQUIRE(q.state != nullptr);
	CHECK(q.state[0] == 0x5A && q.state[11] == 0x5A);
	CHECK_EQ(r.remaining(), size_t(0));

	// No item state (a rocket, a fake missile): n = 0.
	const std::vector<uint8_t> bare = state_request(1, 5, "wpn_rpg7_missile", 0);
	Reader rb(bare.data(), bare.size());
	rb.u32();
	REQUIRE(spawn::read_body(rb, spawn::Layout::State, q));
	CHECK_EQ(q.state_size, size_t(0));
	CHECK(q.section == "wpn_rpg7_missile");
}

TEST(spawn_request_state_size_limits)
{
	// The largest blob passes; one byte more is refused even when it is all there.
	const std::vector<uint8_t> max_ok = state_request(1, 2, "ammo_9x18_fmj", kMaxItemState);
	Reader ok(max_ok.data(), max_ok.size());
	ok.u32();
	spawn::Request q;
	CHECK(spawn::read_body(ok, spawn::Layout::State, q));
	const std::vector<uint8_t> too_big = state_request(1, 2, "ammo_9x18_fmj", kMaxItemState + 1);
	Reader big(too_big.data(), too_big.size());
	big.u32();
	CHECK(!spawn::read_body(big, spawn::Layout::State, q));

	// n claims more bytes than the message has.
	std::vector<uint8_t> short_msg = state_request(1, 2, "ammo_9x18_fmj", 10);
	short_msg.resize(short_msg.size() - 1);
	Reader sr(short_msg.data(), short_msg.size());
	sr.u32();
	CHECK(!spawn::read_body(sr, spawn::Layout::State, q));
}

TEST(spawn_request_raw_and_truncated)
{
	// The old layout with raw M_SPAWN bytes (marker 0xC5) is recognised and never parsed.
	Writer w;
	w.u32(9);
	w.u8(spawn::kMarkerRaw);
	w.u16(3);
	const float pos[3] = {0.f, 0.f, 0.f};
	w.vec3(pos);
	w.u16(4);
	w.u32(0xDEADBEEF);
	REQUIRE(spawn::detect(w.ptr(), w.size()) == spawn::Layout::Raw);
	CHECK(spawn::has_seq(spawn::Layout::Raw));
	Reader rr(w.ptr(), w.size());
	rr.u32();
	spawn::Request q;
	CHECK(!spawn::read_body(rr, spawn::Layout::Raw, q));

	// Cut inside the section name.
	const std::vector<uint8_t> full = state_request(1, 2, "medkit_army", 0);
	const size_t section_at = 4 + 1 + 2 + 12; // seq, marker, parent, pos
	const std::vector<uint8_t> cut(full.begin(), full.begin() + section_at + 4);
	REQUIRE(spawn::detect(cut.data(), cut.size()) == spawn::Layout::State);
	Reader cr(cut.data(), cut.size());
	cr.u32();
	CHECK(!spawn::read_body(cr, spawn::Layout::State, q));

	// Too short to hold a marker: the legacy layout, which then fails on its own.
	const uint8_t tiny[3] = {2, 'a', 'b'};
	CHECK(spawn::detect(tiny, sizeof(tiny)) == spawn::Layout::Legacy);
	CHECK(!spawn::has_seq(spawn::Layout::Legacy));
	Reader tr(tiny, sizeof(tiny));
	CHECK(!spawn::read_body(tr, spawn::Layout::Legacy, q));
}

TEST(spawn_request_legacy)
{
	Writer w;
	w.str("bread");
	w.u16(42);
	const float pos[3] = {4.f, 5.f, 6.f};
	w.vec3(pos);
	REQUIRE(spawn::detect(w.ptr(), w.size()) == spawn::Layout::Legacy);
	Reader r(w.ptr(), w.size());
	spawn::Request q;
	REQUIRE(spawn::read_body(r, spawn::Layout::Legacy, q));
	CHECK(q.section == "bread");
	CHECK_EQ(q.parent, 42);
	CHECK(q.pos[2] == 6.f);
	CHECK_EQ(q.state_size, size_t(0));
}

TEST(spawn_class_lines)
{
	// Engine ids and Anomaly's script ids of classes whose constructors read their lines unchecked.
	CHECK(spawn::item_kind("WP_AK74") == spawn::ItemKind::Weapon);
	CHECK(spawn::item_kind("W_AK74") == spawn::ItemKind::Weapon);
	CHECK(spawn::item_kind("WP_KNIFE") == spawn::ItemKind::Weapon);
	CHECK(spawn::item_kind("WP_ASHTG") == spawn::ItemKind::Weapon);
	CHECK(spawn::item_kind("_WP_SSRS") == spawn::ItemKind::Weapon);
	CHECK(spawn::item_kind("AMMO") == spawn::ItemKind::Ammo);
	CHECK(spawn::item_kind("AMMO_S") == spawn::ItemKind::Ammo);
	CHECK(spawn::item_kind("S_OG7B") == spawn::ItemKind::Ammo);
	CHECK(spawn::item_kind("D_SIMDET") == spawn::ItemKind::Detector);
	CHECK(spawn::item_kind("DET_ELIT") == spawn::ItemKind::Detector);
	CHECK(spawn::item_kind("E_STLK") == spawn::ItemKind::Outfit);
	CHECK(spawn::item_kind("EQU_EXO") == spawn::ItemKind::Outfit);
	CHECK(spawn::item_kind("WP_AK74 ") == spawn::ItemKind::Weapon); // trailing blanks of an ini value
	// Addons, helmets, rockets, food...: plain items.
	CHECK(spawn::item_kind("WP_SCOPE") == spawn::ItemKind::Other);
	CHECK(spawn::item_kind("WP_SILEN") == spawn::ItemKind::Other);
	CHECK(spawn::item_kind("W_STMGUN") == spawn::ItemKind::Other);
	CHECK(spawn::item_kind("E_HLMET") == spawn::ItemKind::Other);
	CHECK(spawn::item_kind("G_FAKE") == spawn::ItemKind::Other);
	CHECK(spawn::item_kind("II_FOOD") == spawn::ItemKind::Other);
	CHECK(spawn::item_kind("") == spawn::ItemKind::Other);
	CHECK(spawn::item_kind("wp_ak74") == spawn::ItemKind::Other); // ids are case-sensitive

	const std::vector<const char*> other = spawn::required_lines(spawn::ItemKind::Other);
	CHECK_EQ(other.size(), size_t(2));
	CHECK(has_line(other, "inv_weight") && has_line(other, "cost"));
	const std::vector<const char*> weapon = spawn::required_lines(spawn::ItemKind::Weapon);
	for (const char* line : {"inv_weight", "cost", "hit_power", "hit_type", "ammo_class", "scope_status",
	         "silencer_status", "grenade_launcher_status"})
		CHECK(has_line(weapon, line));
	CHECK(has_line(spawn::required_lines(spawn::ItemKind::Ammo), "box_size"));
	CHECK(has_line(spawn::required_lines(spawn::ItemKind::Detector), "ef_detector_type"));
	CHECK(has_line(spawn::required_lines(spawn::ItemKind::Outfit), "ef_equipment_type"));
	CHECK(has_line(spawn::required_lines(spawn::ItemKind::Outfit), "cost"));
}

TEST(upgrades_plan_order)
{
	using upgrades::Verdict;
	// Tree: root -> group A {a1, a2}; a1 -> group B {b1, b2}; b1 -> group C {c1}.
	const std::vector<upgrades::Upgrade> wanted = {
	    up("b1", "B", {"A"}), // its parent group has nothing yet: the engine would FATAL (result_e_parents)
	    up("a1", "A"),
	    up("a2", "A"), // A is taken: FATAL (result_e_group)
	    up("b1", "B", {"A"}),
	    up("b2", "B", {"A"}), // B is taken
	    up("c1", "C", {"B"}),
	    up("a1", "A"), // already in the list
	    up("zz", "Z", {}, false), // not in this item's tree
	};
	const std::vector<Verdict> v = upgrades::plan({}, wanted);
	REQUIRE(v.size() == wanted.size());
	CHECK(v[0] == Verdict::NoParent);
	CHECK(v[1] == Verdict::Install);
	CHECK(v[2] == Verdict::GroupTaken);
	CHECK(v[3] == Verdict::Install);
	CHECK(v[4] == Verdict::GroupTaken);
	CHECK(v[5] == Verdict::Install);
	CHECK(v[6] == Verdict::Installed);
	CHECK(v[7] == Verdict::Unknown);
}

TEST(upgrades_plan_installed_and_many_parents)
{
	using upgrades::Verdict;
	// The item already has a1 (group A).
	const std::vector<upgrades::Upgrade> installed = {up("a1", "A")};
	const std::vector<upgrades::Upgrade> wanted = {
	    up("a1", "A"), // installed: skipped, not an error
	    up("a2", "A"), // A is taken by the installed one
	    up("b1", "B", {"A"}),
	    up("d1", "D", {"B", "C"}), // a group under two upgrades needs both parents' groups
	    up("c1", "C", {"A"}),
	    up("d1", "D", {"B", "C"}),
	};
	const std::vector<Verdict> v = upgrades::plan(installed, wanted);
	REQUIRE(v.size() == wanted.size());
	CHECK(v[0] == Verdict::Installed);
	CHECK(v[1] == Verdict::GroupTaken);
	CHECK(v[2] == Verdict::Install);
	CHECK(v[3] == Verdict::NoParent);
	CHECK(v[4] == Verdict::Install);
	CHECK(v[5] == Verdict::Install);

	// An installed upgrade unknown here (other mod set) neither blocks nor satisfies anything.
	const std::vector<upgrades::Upgrade> odd = {up("x1", "X", {}, false)};
	const std::vector<Verdict> v2 = upgrades::plan(odd, {up("x2", "X"), up("y1", "Y", {"X"})});
	CHECK(v2[0] == Verdict::Install);
	CHECK(v2[1] == Verdict::Install);
	CHECK(upgrades::plan({}, {}).empty());
}

TEST(upgrades_plan_section_defaults)
{
	using upgrades::Verdict;
	// A new entity: init_install puts the section's installed_upgrades on before the list (stock wpn_beretta_camo:
	// up_fiftha, up_thirda, up_thirdd; up_thirdc shares group thirdcd with up_thirdd).
	const std::vector<upgrades::Upgrade> defaults = {
	    up("up_fiftha", "fifthab"), up("up_thirda", "thirdab"), up("up_thirdd", "thirdcd")};
	const std::vector<upgrades::Upgrade> wanted = {
	    up("up_thirda", "thirdab"), // a default the client names: kept, nothing to install
	    up("up_thirdc", "thirdcd"), // its group is taken by the default up_thirdd: the engine would FATAL
	    up("up_fourta", "fourtab", {"thirdab"}), // needs the default's group: fine
	    up("up_thirda", "thirdab"), // a repeat in the list
	};
	const std::vector<Verdict> v = upgrades::plan({}, wanted, defaults);
	REQUIRE(v.size() == wanted.size());
	CHECK(v[0] == Verdict::Default);
	CHECK(v[1] == Verdict::GroupTaken);
	CHECK(v[2] == Verdict::Install);
	CHECK(v[3] == Verdict::Installed);

	// A list taken from a server entity has no defaults (loading installs send no GE_INSTALL_UPGRADE): stock
	// wpn_m4a1_camo has up_fourta by default, the player added up_fourtc (group fourtcd under up_fourta's group).
	const std::vector<Verdict> clone =
	    upgrades::plan({}, {up("up_fourtc", "fourtcd", {"fourtab"})}, {up("up_fourta", "fourtab")});
	CHECK(clone[0] == Verdict::Install);
	// Without the defaults the same list would lose the upgrade.
	CHECK(upgrades::plan({}, {up("up_fourtc", "fourtcd", {"fourtab"})})[0] == Verdict::NoParent);

	// Defaults not in the tree are skipped (counted as refused); defaults never show up unasked.
	const std::vector<Verdict> odd = upgrades::plan({}, {up("a1", "A")}, {up("zz", "A", {}, false)});
	CHECK(odd[0] == Verdict::Install);
	CHECK(upgrades::plan({}, {}, defaults).empty());
}

TEST(upgrades_added_by_a_client)
{
	using upgrades::Verdict;
	// GE_INSTALL_UPGRADE from a client (task 10b): the server entity's list has no section defaults, the next
	// net_Spawn from scratch installs the defaults, then that list, then the new one.
	const std::vector<upgrades::Upgrade> beretta_defaults = {
	    up("up_fiftha", "fifthab"), up("up_thirda", "thirdab"), up("up_thirdd", "thirdcd")};
	// Into a group a default already took: refused (FATAL result_e_group at the next spawn).
	CHECK(upgrades::verdict_of_added({}, up("up_thirdc", "thirdcd"), beretta_defaults) == Verdict::GroupTaken);
	// Needs the group of a default: fine.
	CHECK(upgrades::verdict_of_added({}, up("up_fourta", "fourtab", {"thirdab"}), beretta_defaults) ==
	    Verdict::Install);
	// Needs the group of an earlier one from the entity's list: fine; before it: refused.
	CHECK(upgrades::verdict_of_added({up("up_fourta", "fourtab", {"thirdab"})}, up("up_fourtc", "fourtcd", {"fourtab"}),
	          beretta_defaults) == Verdict::Install);
	CHECK(upgrades::verdict_of_added({}, up("up_fourtc", "fourtcd", {"fourtab"}), beretta_defaults) ==
	    Verdict::NoParent);
	// Already there: from the entity's list, or a default. Neither is relayed.
	CHECK(upgrades::verdict_of_added({up("up_fourta", "fourtab", {"thirdab"})}, up("up_fourta", "fourtab", {"thirdab"}),
	          beretta_defaults) == Verdict::Installed);
	CHECK(upgrades::verdict_of_added({}, up("up_thirdd", "thirdcd"), beretta_defaults) == Verdict::Default);
	CHECK(upgrades::verdict_of_added({up("up_thirdd", "thirdcd")}, up("up_thirdd", "thirdcd"), beretta_defaults) ==
	    Verdict::Installed);
	CHECK(upgrades::verdict_of_added({}, up("zz", "Z", {}, false), beretta_defaults) == Verdict::Unknown);
	// F0 final review (task 10b): an upgrade the entity's list names is there, whatever the replay made of that
	// mention (CSE add_upgrade is FATAL on a duplicate id). Here b1 stands before its parent group's a1 in the list:
	// the replay refuses that mention, and on its own it would install the same b1 again.
	CHECK(upgrades::verdict_of_added({up("b1", "B", {"A"}), up("a1", "A")}, up("b1", "B", {"A"}), {}) ==
	    Verdict::Installed);
	CHECK(upgrades::verdict_of_added({up("zz", "Z", {}, false)}, up("zz", "Z", {}, false), {}) == Verdict::Installed);
}

TEST(upgrades_broken_section_defaults)
{
	// A section whose own installed_upgrades break the tree rules: init_install would FATAL on any spawn of it.
	size_t refused = 99;
	upgrades::plan({}, {}, {up("a1", "A"), up("b1", "B", {"A"})}, &refused);
	CHECK_EQ(refused, size_t(0));
	upgrades::plan({}, {}, {up("a1", "A"), up("a2", "A")}, &refused); // same group twice
	CHECK_EQ(refused, size_t(1));
	upgrades::plan({}, {}, {up("b1", "B", {"A"}), up("a1", "A")}, &refused); // child before its parent
	CHECK_EQ(refused, size_t(1));
	upgrades::plan({}, {}, {up("zz", "Z", {}, false)}, &refused); // not in the tree
	CHECK_EQ(refused, size_t(1));
	upgrades::plan({}, {}, {up("a1", "A"), up("a1", "A")}, &refused); // a repeat: the engine skips it (installed)
	CHECK_EQ(refused, size_t(0));
	CHECK(upgrades::defaults_ok({up("a1", "A"), up("b1", "B", {"A"})}));
	CHECK(!upgrades::defaults_ok({up("a1", "A"), up("a2", "A")}));
	CHECK(upgrades::defaults_ok({}));
}
