// Anomaly Coop unit tests: the caller side of the death losses (coop_death_items.h; F3 Task 9, CHECKPOINTS_DEATH.md
// §3.3): which of a dead character's items are candidates (quest items filtered out by the caller, a stable id order),
// their categories from the ltx kinds, what goes into a death stash, the drop point (Review Focus 4), DeathMarker on
// the wire, and that configs\mod_system_coop_death.ltx holds what the engine reads.
#include "test_util.h"

#include "coop_death_items.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <limits>
#include <map>
#include <set>

using namespace coop::death;

namespace
{
ItemFacts item(uint16_t id, const char* kind)
{
	ItemFacts f;
	f.id = id;
	f.kind = kind ? kind : "";
	return f;
}

ItemFacts with(ItemFacts f, bool ItemFacts::*flag, bool v = true)
{
	f.*flag = v;
	return f;
}

KindTable stock_kinds()
{
	KindTable k;
	k.add("i_part", "materials");
	k.add("w_ammo", "ammo");
	k.add("i_food", "consumables");
	k.add("i_medical", "consumables");
	k.add("w_rifle", "gear");
	k.add("i_arty", "artefacts");
	k.add("i_tool", "tools");
	return k;
}

std::vector<uint16_t> ids_of(const std::vector<Candidate>& c)
{
	std::vector<uint16_t> v;
	for (const Candidate& x : c)
		v.push_back(x.id);
	return v;
}

Shares all_shares(float s)
{
	Shares a;
	a.fill(s);
	return a;
}

std::vector<uint8_t> pack_marker(uint16_t character, uint16_t object, uint8_t drop)
{
	coop::Writer w;
	w.u16(character);
	w.u16(object);
	w.u8(drop);
	return w.data();
}

bool near(float a, float b) { return std::fabs(a - b) < 1e-4f; }

// configs\mod_system_coop_death.ltx, found next to this source file (tests\ -> ..\gamedata\configs).
std::string ltx_path()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "gamedata/configs/mod_system_coop_death.ltx";
	here.resize(slash);
	return here + "/../gamedata/configs/mod_system_coop_death.ltx";
}

std::string trim(const std::string& s)
{
	const size_t a = s.find_first_not_of(" \t\r");
	if (a == std::string::npos)
		return std::string();
	const size_t b = s.find_last_not_of(" \t\r");
	return s.substr(a, b - a + 1);
}

// A minimal ltx reader: section header line (with its parent) -> key = value lines, comments cut at ';'.
struct Ltx
{
	std::map<std::string, std::vector<std::pair<std::string, std::string>>> sections;
	std::map<std::string, std::string> parents;
	bool opened = false;
};

Ltx read_ltx(const std::string& path)
{
	Ltx out;
	std::ifstream in(path);
	out.opened = in.good();
	std::string line, section;
	while (std::getline(in, line))
	{
		const size_t semi = line.find(';');
		if (semi != std::string::npos)
			line.resize(semi);
		line = trim(line);
		if (line.empty())
			continue;
		if (line[0] == '[')
		{
			const size_t close = line.find(']');
			section = line.substr(1, close - 1);
			out.sections[section];
			const size_t colon = line.find(':', close);
			if (colon != std::string::npos)
				out.parents[section] = trim(line.substr(colon + 1));
			continue;
		}
		const size_t eq = line.find('=');
		if (eq == std::string::npos)
			out.sections[section].push_back({trim(line), std::string()});
		else
			out.sections[section].push_back({trim(line.substr(0, eq)), trim(line.substr(eq + 1))});
	}
	return out;
}
} // namespace

// Carried from the T3-5 review: the caller filters quest items before pick_losses. Not one of them is ever offered,
// even with every share at 1.
TEST(death_items_quest_filtered_by_caller)
{
	const KindTable kinds = stock_kinds();
	std::vector<ItemFacts> in;
	in.push_back(item(10, "i_part"));
	in.push_back(with(item(11, "i_part"), &ItemFacts::quest)); // IsQuestItem()
	in.push_back(item(12, "i_quest"));
	in.push_back(item(13, "i_letter"));
	in.push_back(with(item(14, "i_device"), &ItemFacts::pda));
	in.push_back(with(item(15, "i_part"), &ItemFacts::helper));
	in.push_back(with(item(16, "i_part"), &ItemFacts::world, false)); // a host-only object (NPC supply bolt)
	in.push_back(item(17, "w_ammo"));

	const std::vector<Candidate> c = loss_candidates(in, kinds, true);
	CHECK((ids_of(c) == std::vector<uint16_t>{10, 17}));
	const std::vector<uint16_t> picked = pick_losses(c, all_shares(1.0f), 99);
	CHECK_EQ(picked.size(), size_t(2));
	for (const uint16_t id : picked)
		CHECK(id == 10 || id == 17);

	CHECK(kept_kind("i_quest"));
	CHECK(kept_kind("i_letter"));
	CHECK(!kept_kind("i_part"));
	CHECK(!kept_kind(""));
	CHECK(never_lost(with(item(1, "i_food"), &ItemFacts::quest)));
	CHECK(never_lost(item(1, "i_quest")));
	CHECK(never_lost(with(item(1, ""), &ItemFacts::pda)));
	CHECK(never_lost(item(0xffff, "i_food"))); // no id
	CHECK(!never_lost(item(1, "i_food")));
}

// Carried from the T3-5 review: candidates go in a stable order, by id, each id once. Whatever order the inventory
// lists the items in, the same seed takes the same items.
TEST(death_items_candidates_stable_order)
{
	const KindTable kinds = stock_kinds();
	std::vector<ItemFacts> in;
	const uint16_t ids[] = {907, 12, 455, 13, 300, 14, 12, 98, 1000, 2};
	const char* const k[] = {"i_part", "w_ammo", "i_food", "i_part", "w_rifle", "i_tool", "w_ammo", "i_arty", "i_part",
		"i_medical"};
	for (size_t i = 0; i < 10; ++i)
		in.push_back(item(ids[i], k[i]));

	const std::vector<Candidate> c = loss_candidates(in, kinds, true);
	CHECK((ids_of(c) == std::vector<uint16_t>{2, 12, 13, 14, 98, 300, 455, 907, 1000}));

	std::vector<ItemFacts> reversed(in.rbegin(), in.rend());
	std::vector<ItemFacts> rotated = in;
	std::rotate(rotated.begin(), rotated.begin() + 4, rotated.end());
	const Shares s = all_shares(0.5f);
	for (uint32_t seed = 1; seed < 200; ++seed)
	{
		const std::vector<uint16_t> a = pick_losses(loss_candidates(in, kinds, true), s, seed);
		CHECK(a == pick_losses(loss_candidates(reversed, kinds, true), s, seed));
		CHECK(a == pick_losses(loss_candidates(rotated, kinds, true), s, seed));
	}
}

TEST(death_items_candidates_bounded)
{
	const KindTable kinds = stock_kinds();
	std::vector<ItemFacts> in;
	for (uint16_t id = 5000; id > 1000; --id) // 4000 items, highest first
		in.push_back(item(id, "i_part"));
	const std::vector<Candidate> c = loss_candidates(in, kinds, true);
	REQUIRE(c.size() == kMaxCandidates);
	CHECK_EQ(c.front().id, uint16_t(1001));
	CHECK_EQ(c.back().id, uint16_t(1001 + kMaxCandidates - 1));
	CHECK_EQ(stash_ids(in, kinds, true, true).size(), kMaxCandidates);
	CHECK(loss_candidates({}, kinds, true).empty());
}

// Plan T9 step 2: CWeaponAmmo -> Ammo; else the ltx kind; else an outfit or a helmet in the backpack -> Gear; else
// Other.
TEST(death_items_category)
{
	const KindTable kinds = stock_kinds();
	CHECK_EQ(category_of(with(item(1, "i_food"), &ItemFacts::ammo), kinds), uint8_t(Ammo)); // the class wins
	CHECK_EQ(category_of(with(item(1, ""), &ItemFacts::ammo), kinds), uint8_t(Ammo));
	CHECK_EQ(category_of(item(1, "i_part"), kinds), uint8_t(Materials));
	CHECK_EQ(category_of(item(1, "i_medical"), kinds), uint8_t(Consumables));
	CHECK_EQ(category_of(item(1, "w_rifle"), kinds), uint8_t(Gear));
	CHECK_EQ(category_of(item(1, "i_arty"), kinds), uint8_t(Artefacts));
	CHECK_EQ(category_of(item(1, "i_tool"), kinds), uint8_t(Tools));
	CHECK_EQ(category_of(with(item(1, "o_medium"), &ItemFacts::outfit), kinds), uint8_t(Gear)); // kind not mapped
	CHECK_EQ(category_of(with(item(1, "i_tool"), &ItemFacts::outfit), kinds), uint8_t(Tools)); // the kind first
	CHECK_EQ(category_of(item(1, "o_medium"), kinds), uint8_t(Other));
	CHECK_EQ(category_of(item(1, ""), kinds), uint8_t(Other));
	CHECK_EQ(category_of(item(1, "I_PART"), kinds), uint8_t(Other)); // kinds are matched exactly, as the ltx has them

	for (uint8_t i = 0; i < kCategories; ++i)
	{
		uint8_t back = 0xff;
		CHECK(category_from_name(category_name(i), back));
		CHECK_EQ(back, i);
	}
	CHECK_EQ(std::string(category_name(kCategories)), std::string("?"));

	const std::vector<Candidate> c = loss_candidates({item(3, "i_tool"), with(item(2, ""), &ItemFacts::ammo)}, kinds, true);
	REQUIRE(c.size() == 2);
	CHECK_EQ(c[0].id, uint16_t(2));
	CHECK_EQ(c[0].category, uint8_t(Ammo));
	CHECK_EQ(c[1].id, uint16_t(3));
	CHECK_EQ(c[1].category, uint8_t(Tools));
}

TEST(death_items_kind_table)
{
	KindTable k;
	CHECK(k.add("i_part", "materials"));
	CHECK(!k.add("i_x", "junk")); // unknown category
	CHECK(!k.add("i_x", "Materials")); // category names are lower case, as in the ltx
	CHECK(!k.add("", "ammo"));
	CHECK(!k.add(nullptr, "ammo"));
	CHECK(!k.add("i_x", nullptr));
	CHECK(!k.add(std::string(KindTable::kMaxKindLength + 1, 'k').c_str(), "ammo"));
	CHECK(k.add(std::string(KindTable::kMaxKindLength, 'k').c_str(), "ammo"));
	CHECK_EQ(k.size(), size_t(2));

	uint8_t c = 0xff;
	CHECK(k.find("i_part", c));
	CHECK_EQ(c, uint8_t(Materials));
	CHECK(k.add("i_part", "tools")); // a later line wins (DLTX override)
	CHECK(k.find("i_part", c));
	CHECK_EQ(c, uint8_t(Tools));
	CHECK_EQ(k.size(), size_t(2));
	c = 0xff;
	CHECK(!k.find("i_x", c));
	CHECK_EQ(c, uint8_t(0xff)); // untouched

	KindTable full;
	for (size_t i = 0; i < KindTable::kMaxKinds; ++i)
		CHECK(full.add(("kind_" + std::to_string(i)).c_str(), "other"));
	CHECK(!full.add("one_more", "other"));
	CHECK(full.add("kind_7", "gear")); // replacing an existing kind needs no room
	CHECK_EQ(full.size(), KindTable::kMaxKinds);
	full.clear();
	CHECK_EQ(full.size(), size_t(0));
}

// A client's proxy: the host cannot see what its player has on, so nothing he may wear is offered. The host's own
// actor: its backpack is exact, gear and artefacts in it can go.
TEST(death_items_proxy_keeps_wearable)
{
	const KindTable kinds = stock_kinds();
	std::vector<ItemFacts> in;
	in.push_back(item(1, "i_part"));
	in.push_back(with(with(item(2, "o_heavy"), &ItemFacts::outfit), &ItemFacts::wearable));
	in.push_back(with(item(3, "w_rifle"), &ItemFacts::wearable));
	in.push_back(with(item(4, "i_arty"), &ItemFacts::wearable)); // belt
	in.push_back(item(5, "w_ammo"));

	CHECK((ids_of(loss_candidates(in, kinds, false)) == std::vector<uint16_t>{1, 5}));
	CHECK((ids_of(loss_candidates(in, kinds, true)) == std::vector<uint16_t>{1, 2, 3, 4, 5}));
	CHECK((stash_ids(in, kinds, false, false) == std::vector<uint16_t>{1, 5}));
	CHECK((stash_ids(in, kinds, false, true) == std::vector<uint16_t>{1, 2, 3, 4, 5}));
}

namespace
{
// What the engine does for a client's proxy (coop_death.cpp carried_of): with the owner's list of what he has on,
// every item of the proxy is offered except those on the list (`worn`, layout known); without it (an old client, a
// dropped packet) only the backpack is seen and nothing he may wear is offered (the pre-T8b rule).
std::vector<uint16_t> offered(std::vector<ItemFacts> in, const KindTable& kinds, const std::vector<uint16_t>* worn)
{
	if (!worn)
		return ids_of(loss_candidates(in, kinds, false));
	mark_worn(in, *worn);
	return ids_of(loss_candidates(in, kinds, true));
}

// A client's proxy as the host sees it (m_all): the NPC put the player's things into its own slots in its own order.
std::vector<ItemFacts> proxy_items()
{
	std::vector<ItemFacts> in;
	in.push_back(item(1, "i_part"));
	in.push_back(with(with(item(2, "o_heavy"), &ItemFacts::outfit), &ItemFacts::wearable)); // the outfit he wears
	in.push_back(with(item(3, "w_rifle"), &ItemFacts::wearable)); // the gun in his hands
	in.push_back(with(item(4, "i_arty"), &ItemFacts::wearable)); // on his belt
	in.push_back(item(5, "w_ammo"));
	in.push_back(with(item(6, "w_rifle"), &ItemFacts::wearable)); // a spare gun: in the NPC's slot, in his backpack
	in.push_back(with(item(7, "i_arty"), &ItemFacts::wearable)); // a spare artefact in his backpack
	in.push_back(with(item(8, "i_part"), &ItemFacts::quest)); // never
	return in;
}
} // namespace

// F3 T8b (Ruling F3-4): the same items of a client's proxy, different lists of what he has on, different losses. What
// is on the list stays; the spare gun and the spare artefact (not on it) can go as the host's own would. No list: the
// old rule, nothing he may wear is offered.
TEST(death_items_worn_list)
{
	const KindTable kinds = stock_kinds();
	const std::vector<ItemFacts> in = proxy_items();

	const std::vector<uint16_t> on_him{2, 3, 4};
	CHECK((offered(in, kinds, &on_him) == std::vector<uint16_t>{1, 5, 6, 7}));
	const std::vector<uint16_t> nothing_on;
	CHECK((offered(in, kinds, &nothing_on) == std::vector<uint16_t>{1, 2, 3, 4, 5, 6, 7})); // an empty list is a list
	const std::vector<uint16_t> spares{6, 7};
	CHECK((offered(in, kinds, &spares) == std::vector<uint16_t>{1, 2, 3, 4, 5}));
	CHECK((offered(in, kinds, nullptr) == std::vector<uint16_t>{1, 5})); // as before T8b

	// The list as it comes from a client: unsorted, repeated ids, ids he does not carry. Only what is in the items
	// counts.
	const std::vector<uint16_t> messy{4, 3, 2, 3, 999, 2, 0xffff};
	CHECK((offered(in, kinds, &messy) == std::vector<uint16_t>{1, 5, 6, 7}));
	std::vector<ItemFacts> marked = in;
	CHECK_EQ(mark_worn(marked, messy), size_t(3));
	CHECK_EQ(mark_worn(marked, messy), size_t(3)); // again: the same
	CHECK(marked[1].worn && marked[2].worn && marked[3].worn);
	CHECK(!marked[0].worn && !marked[4].worn && !marked[5].worn && !marked[6].worn && !marked[7].worn);
	CHECK_EQ(mark_worn(marked, nothing_on), size_t(0)); // a new list replaces the old marks
	CHECK(!marked[1].worn && !marked[2].worn && !marked[3].worn);

	// T8b review N1: only what can be worn counts as worn. A client naming his parts and ammo "on him" keeps nothing.
	const std::vector<uint16_t> materials{1, 5};
	CHECK((offered(in, kinds, &materials) == std::vector<uint16_t>{1, 2, 3, 4, 5, 6, 7}));
	std::vector<ItemFacts> named = in;
	CHECK_EQ(mark_worn(named, materials), size_t(0));

	// A quest item on the list or off it is never offered; a list cannot make a never-lost item lost.
	const std::vector<uint16_t> quest_on{8};
	CHECK((offered(in, kinds, &quest_on) == std::vector<uint16_t>{1, 2, 3, 4, 5, 6, 7}));

	// Whatever the seed, with every share at 1 a pick never takes what the list names, and takes every other candidate.
	for (uint32_t seed = 1; seed < 100; ++seed)
	{
		std::vector<ItemFacts> m = in;
		mark_worn(m, on_him);
		std::vector<uint16_t> picked = pick_losses(loss_candidates(m, kinds, true), all_shares(1.0f), seed);
		std::sort(picked.begin(), picked.end());
		CHECK((picked == std::vector<uint16_t>{1, 5, 6, 7}));
	}

	// The corpse stash takes the same set; a hardcore retirement (everything) takes all, list or not.
	std::vector<ItemFacts> m = in;
	mark_worn(m, on_him);
	CHECK((stash_ids(m, kinds, false, true) == std::vector<uint16_t>{1, 5, 6, 7}));
	CHECK((stash_ids(m, kinds, true, true) == std::vector<uint16_t>{1, 2, 3, 4, 5, 6, 7, 8}));
	CHECK((stash_ids(in, kinds, false, false) == std::vector<uint16_t>{1, 5}));
}

// The host's own actor: its backpack is exact. No list ever marks anything there, and what it has in its backpack is
// offered whether or not its ltx lets it wear it.
TEST(death_items_worn_host_exact)
{
	const KindTable kinds = stock_kinds();
	const std::vector<ItemFacts> in = proxy_items();
	CHECK((ids_of(loss_candidates(in, kinds, true)) == std::vector<uint16_t>{1, 2, 3, 4, 5, 6, 7}));
	for (const ItemFacts& f : in)
		CHECK(!f.worn);
}

// Corpse: the backpack (as the candidates). Hardcore retirement (everything): all of it, worn and quest items too;
// never helper items or host-only objects.
TEST(death_items_stash_ids)
{
	const KindTable kinds = stock_kinds();
	std::vector<ItemFacts> in;
	in.push_back(item(40, "i_part"));
	in.push_back(with(item(30, "i_part"), &ItemFacts::quest));
	in.push_back(item(20, "i_letter"));
	in.push_back(with(item(10, ""), &ItemFacts::pda));
	in.push_back(with(item(50, "w_rifle"), &ItemFacts::wearable));
	in.push_back(with(item(60, ""), &ItemFacts::helper));
	in.push_back(with(item(70, ""), &ItemFacts::world, false));
	in.push_back(item(40, "i_part")); // listed twice
	in.push_back(item(0xffff, "i_part")); // no id

	CHECK((stash_ids(in, kinds, false, true) == std::vector<uint16_t>{40, 50}));
	CHECK((stash_ids(in, kinds, true, false) == std::vector<uint16_t>{10, 20, 30, 40, 50}));
	CHECK((stash_ids(in, kinds, true, true) == std::vector<uint16_t>{10, 20, 30, 40, 50}));
	CHECK(stash_ids({}, kinds, true, true).empty());
}

TEST(death_items_seed)
{
	CHECK_EQ(loss_seed(5, 3, 0x100000007ull), uint32_t(5u ^ (3u << 16) ^ 7u)); // the high bits of the time go
	CHECK_EQ(loss_seed(0, 0, 0), uint32_t(0));
	CHECK_EQ(loss_seed(0xffff, 0xffff, 0xffffffffull), uint32_t(0xffffu ^ 0xffff0000u ^ 0xffffffffu));
	CHECK(loss_seed(7, 1, 1000) != loss_seed(7, 2, 1000)); // another death of the same player
	CHECK(loss_seed(7, 1, 1000) != loss_seed(8, 1, 1000)); // another player
}

// Review Focus 4: what falls must stay reachable.
TEST(death_items_drop_place)
{
	const Point vertex{10.0f, 5.0f, 20.0f};
	// On the ground: the items fall from the body.
	DropPlace d = drop_place(Point{10.2f, 5.1f, 19.8f}, true, true, vertex);
	CHECK(!d.moved);
	CHECK(near(d.at.x, 10.2f) && near(d.at.y, 5.1f) && near(d.at.z, 19.8f));
	// On a roof above the vertex: still the body.
	CHECK(!drop_place(Point{10.0f, 12.0f, 20.0f}, true, true, vertex).moved);
	// Exactly 1 m below: still the body (more than 1 m moves).
	CHECK(!drop_place(Point{10.0f, 4.0f, 20.0f}, true, true, vertex).moved);
	// Fell through the ground: 0.3 m above the vertex.
	d = drop_place(Point{10.5f, 3.5f, 20.5f}, true, true, vertex);
	CHECK(d.moved);
	CHECK(near(d.at.x, 10.0f) && near(d.at.y, 5.3f) && near(d.at.z, 20.0f));
	// Own vertex not valid: the nearest one, whatever the height.
	d = drop_place(Point{10.5f, 9.0f, 20.5f}, false, true, vertex);
	CHECK(d.moved);
	CHECK(near(d.at.y, 5.0f + kAboveVertexM));
	// No level graph: nothing better than the body.
	d = drop_place(Point{1.0f, 2.0f, 3.0f}, false, false, vertex);
	CHECK(!d.moved);
	CHECK(near(d.at.x, 1.0f) && near(d.at.y, 2.0f) && near(d.at.z, 3.0f));
	// A body position that is not a number: the vertex.
	const float nan = std::numeric_limits<float>::quiet_NaN();
	d = drop_place(Point{nan, nan, nan}, true, true, vertex);
	CHECK(d.moved);
	CHECK(near(d.at.y, 5.3f));
}

TEST(death_items_spread)
{
	const Point first = spread(0);
	CHECK(near(first.x, 0.0f) && near(first.y, 0.0f) && near(first.z, 0.0f));
	std::set<std::pair<int, int>> cells;
	for (size_t i = 0; i < 2000; ++i)
	{
		const Point p = spread(i);
		CHECK(std::isfinite(p.x) && std::isfinite(p.z));
		CHECK(near(p.y, 0.0f)); // on the ground plane: the vertex height decides
		CHECK(std::sqrt(p.x * p.x + p.z * p.z) <= kSpreadMaxM + 1e-4f);
		if (i < 16)
			cells.insert({int(std::lround(p.x * 1000.0f)), int(std::lround(p.z * 1000.0f))});
	}
	CHECK_EQ(cells.size(), size_t(16)); // the first items of a drop do not share a spot
	for (size_t i = 1; i < 16; ++i)
	{
		const Point p = spread(i);
		CHECK(std::sqrt(p.x * p.x + p.z * p.z) >= 0.1f); // away from the first one
	}
}

TEST(death_marker_wire)
{
	Marker m;
	m.character = 0x1234;
	m.object = 0x0567;
	m.drop = Drop::Corpse;
	coop::Writer w;
	write(w, m);
	CHECK_EQ(w.data().size(), kMarkerSize);
	CHECK((w.data() == pack_marker(0x1234, 0x0567, 1)));

	Marker back;
	{
		coop::Reader r(w.data().data(), w.data().size());
		CHECK(read(r, back));
	}
	CHECK_EQ(back.character, uint16_t(0x1234));
	CHECK_EQ(back.object, uint16_t(0x0567));
	CHECK(back.drop == Drop::Corpse);

	const auto rejects = [](const std::vector<uint8_t>& bytes) {
		Marker x;
		x.character = 7;
		x.object = 8;
		coop::Reader r(bytes.data(), bytes.size());
		const bool ok = read(r, x);
		return !ok && x.character == 7 && x.object == 8 && x.drop == Drop::Drop; // unchanged
	};
	{
		const std::vector<uint8_t> ok = pack_marker(0, 9, 0);
		Marker x;
		coop::Reader r(ok.data(), ok.size());
		CHECK(read(r, x));
		CHECK(x.drop == Drop::Drop);
		CHECK_EQ(x.character, uint16_t(0)); // the host's own character
	}
	CHECK(rejects(pack_marker(1, 2, 2))); // Lose has no marker
	CHECK(rejects(pack_marker(1, 2, 3))); // unknown mode
	CHECK(rejects(pack_marker(1, 2, 0xff)));
	CHECK(rejects(pack_marker(0xffff, 2, 0))); // no character
	CHECK(rejects(pack_marker(1, 0xffff, 1))); // no marker object
	const std::vector<uint8_t> full = pack_marker(1, 2, 1);
	for (size_t n = 0; n < full.size(); ++n)
		CHECK(rejects(std::vector<uint8_t>(full.begin(), full.begin() + n)));

	CHECK_EQ(std::string(marker_kind(Drop::Drop)), std::string("drop"));
	CHECK_EQ(std::string(marker_kind(Drop::Corpse)), std::string("corpse"));
}

// The ltx the engine reads: every share known and in 0..1, every kind mapped to a category the engine knows, and the
// stash section inherits the stock backpack stash (plan T9 step 1).
TEST(death_items_ltx)
{
	const Ltx ltx = read_ltx(ltx_path());
	REQUIRE(ltx.opened);

	REQUIRE(ltx.sections.count("coop_death_drop") == 1);
	const auto& drop = ltx.sections.at("coop_death_drop");
	std::set<std::string> seen;
	for (const auto& line : drop)
	{
		uint8_t c = 0;
		CHECK(category_from_name(line.first.c_str(), c));
		seen.insert(line.first);
		const float v = std::stof(line.second);
		CHECK(v >= 0.0f && v <= 1.0f);
	}
	CHECK_EQ(seen.size(), size_t(kCategories));
	const std::map<std::string, float> expected = {{"materials", 0.5f}, {"ammo", 0.5f}, {"consumables", 0.5f},
		{"gear", 0.25f}, {"artefacts", 0.1f}, {"tools", 0.1f}, {"other", 0.25f}};
	for (const auto& line : drop)
		CHECK(near(std::stof(line.second), expected.at(line.first)));

	REQUIRE(ltx.sections.count("coop_death_kinds") == 1);
	const auto& kinds = ltx.sections.at("coop_death_kinds");
	CHECK_EQ(kinds.size(), size_t(25));
	KindTable table;
	for (const auto& line : kinds)
		CHECK(table.add(line.first.c_str(), line.second.c_str()));
	CHECK_EQ(table.size(), kinds.size());
	uint8_t c = 0xff;
	CHECK(table.find("w_ammo", c) && c == Ammo);
	CHECK(table.find("i_mutant_belt", c) && c == Artefacts);
	CHECK(table.find("w_sniper", c) && c == Gear);
	CHECK(!table.find("i_quest", c)); // story items are never mapped: they are never lost

	REQUIRE(ltx.sections.count("coop_death_stash") == 1);
	CHECK_EQ(ltx.parents.count("coop_death_stash"), size_t(1));
	if (ltx.parents.count("coop_death_stash"))
		CHECK_EQ(ltx.parents.at("coop_death_stash"), std::string("inv_backpack"));
}

// T9 fix round 1, review I1 and minor 1: a pending stash checks that it is still for the same character. Task 10
// rewrites the key of a retiring character while its player is still there; a player who leaves keeps the key on his
// parked character but loses his peer. Only both changed means another character got the id.
TEST(death_stash_same_owner)
{
	StashOwner then;
	then.peer = 3;
	then.key = "a1b2";
	StashOwner now = then;
	CHECK(same_owner(then, now));

	now.key = ""; // Task 10 removed the key line ("retired = 1"): the same player still plays it
	CHECK(same_owner(then, now));

	now = then;
	now.peer = 0xffffffffu; // the player left: the parked character keeps its key
	CHECK(same_owner(then, now));
	now.peer = 5; // he came back under another peer id
	CHECK(same_owner(then, now));

	// T8b, review R1: when both sides have a key, the keys decide alone. The same peer number with another key is
	// another character (the id was released and given to a new proxy of a player who took the same number).
	now = then;
	now.key = "ffff";
	CHECK(!same_owner(then, now));
	now.peer = 0xffffffffu;
	CHECK(!same_owner(then, now));

	now = then;
	now.peer = 5; // another player and another key: the id belongs to another character
	now.key = "ffff";
	CHECK(!same_owner(then, now));
	now.peer = 0xffffffffu;
	now.key = "";
	CHECK(!same_owner(then, now));

	// No identity at all is no match: an empty key never equals an empty key, nobody never equals nobody.
	StashOwner none;
	CHECK(!same_owner(none, none));
	StashOwner keyless;
	keyless.peer = 4;
	StashOwner other_keyless;
	other_keyless.peer = 6;
	CHECK(!same_owner(keyless, other_keyless));
	CHECK(same_owner(keyless, keyless));

	// Only one side has a key: the peer is all there is to compare (the key did not exist when the stash was made, or
	// Task 10 took it away).
	StashOwner late_key;
	late_key.peer = 4;
	late_key.key = "c0de";
	CHECK(same_owner(keyless, late_key));
	late_key.peer = 6;
	CHECK(!same_owner(keyless, late_key));

	// The host's own character: peer 0 for good.
	StashOwner host;
	host.peer = 0;
	CHECK(same_owner(host, host));
}

TEST(death_stash_step)
{
	using P = Presence;
	using S = StashStep;
	const uint64_t deadline = 5000, give_up = 600000;
	// The character is here.
	CHECK(stash_step(true, P::Online, P::Online, 100, deadline, give_up) == S::Fill);
	CHECK(stash_step(true, P::Online, P::Between, 100, deadline, give_up) == S::Wait); // being spawned
	CHECK(stash_step(true, P::Online, P::Offline, 100, deadline, give_up) == S::Wait);
	CHECK(stash_step(true, P::Online, P::Between, 5000, deadline, give_up) == S::DropAtBody); // 5 s are over
	CHECK(stash_step(true, P::Online, P::Offline, 9000, deadline, give_up) == S::DropAtBody);
	CHECK(stash_step(true, P::Online, P::Gone, 100, deadline, give_up) == S::DropAtBody); // someone removed the stash
	CHECK(stash_step(true, P::Online, P::Online, 9000, deadline, give_up) == S::Fill); // online in the end: fill
	// The player left (his character is parked offline).
	CHECK(stash_step(true, P::Offline, P::Offline, 100, deadline, give_up) == S::MoveOffline);
	CHECK(stash_step(true, P::Offline, P::Offline, 700000, deadline, give_up) == S::MoveOffline);
	CHECK(stash_step(true, P::Offline, P::Online, 9000, deadline, give_up) == S::Wait); // someone is by the stash
	CHECK(stash_step(true, P::Offline, P::Between, 9000, deadline, give_up) == S::Wait);
	CHECK(stash_step(true, P::Offline, P::Online, 600000, deadline, give_up) == S::GiveUp); // stayed away too long
	CHECK(stash_step(true, P::Offline, P::Gone, 100, deadline, give_up) == S::GiveUp);
	// The character is switching.
	CHECK(stash_step(true, P::Between, P::Online, 9000, deadline, give_up) == S::Wait);
	CHECK(stash_step(true, P::Between, P::Offline, 9000, deadline, give_up) == S::Wait);
	CHECK(stash_step(true, P::Between, P::Online, 600000, deadline, give_up) == S::GiveUp);
	// Not his character any more, or no character.
	CHECK(stash_step(false, P::Online, P::Online, 100, deadline, give_up) == S::GiveUp);
	CHECK(stash_step(false, P::Offline, P::Offline, 100, deadline, give_up) == S::GiveUp);
	CHECK(stash_step(true, P::Gone, P::Online, 100, deadline, give_up) == S::GiveUp);
}

TEST(death_stash_presence)
{
	uint64_t deadline = 5000;
	bool away = false;
	stash_presence(deadline, away, Presence::Online, 1000); // here from the start: the first 5 s stand
	CHECK_EQ(deadline, uint64_t(5000));
	CHECK(!away);
	stash_presence(deadline, away, Presence::Offline, 2000); // he left
	CHECK(away);
	CHECK_EQ(deadline, uint64_t(5000));
	stash_presence(deadline, away, Presence::Between, 90000); // coming back online
	CHECK(away);
	stash_presence(deadline, away, Presence::Online, 120000); // back: 5 s from now
	CHECK(!away);
	CHECK_EQ(deadline, uint64_t(125000));
	stash_presence(deadline, away, Presence::Online, 121000);
	CHECK_EQ(deadline, uint64_t(125000));
	stash_presence(deadline, away, Presence::Gone, 122000);
	CHECK(away);
}

// T9 fix round 1: a stash that never came online drops its items where he died, not where the body is now (he left and
// came back, or was respawned at his camp meanwhile). Review Focus 4: within 3 m of the death spot.
TEST(death_stash_fallback_place)
{
	DropPlace died;
	died.at = Point{100.0f, 10.0f, 200.0f};
	DropPlace now;
	now.at = Point{101.0f, 10.0f, 201.5f};

	// The body is still there: the items fall from it as usual.
	DropPlace d = fallback_place(died, now, Point{101.0f, 10.0f, 201.5f});
	CHECK(!d.moved);
	CHECK(near(d.at.x, 101.0f) && near(d.at.z, 201.5f));
	// Exactly at the reach: still the body.
	CHECK(!fallback_place(died, now, Point{103.0f, 10.0f, 200.0f}).moved);
	// The body is at his camp: the items go to the death spot, 0.3 m up.
	now.at = Point{900.0f, 30.0f, -50.0f};
	d = fallback_place(died, now, Point{900.0f, 30.0f, -50.0f});
	CHECK(d.moved);
	CHECK(near(d.at.x, 100.0f) && near(d.at.y, 10.0f + kAboveVertexM) && near(d.at.z, 200.0f));
	// The death spot was already moved above a level vertex: kept as it is.
	died.moved = true;
	died.at = Point{100.0f, 10.3f, 200.0f};
	d = fallback_place(died, now, Point{900.0f, 30.0f, -50.0f});
	CHECK(d.moved);
	CHECK(near(d.at.y, 10.3f));
	// Height counts too: a body 5 m above the spot (on a roof) is not there.
	died.moved = false;
	died.at = Point{100.0f, 10.0f, 200.0f};
	now.at = Point{100.0f, 15.0f, 200.0f};
	CHECK(fallback_place(died, now, Point{100.0f, 15.0f, 200.0f}).moved);
	// A body position that is not a number is not within reach.
	const float nan = std::numeric_limits<float>::quiet_NaN();
	CHECK(fallback_place(died, now, Point{nan, nan, nan}).moved);
}
