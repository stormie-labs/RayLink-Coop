// Anomaly Coop unit tests: the checkpoint at the bed of a base (coop_checkpoint_base_rules.h; Build 57, owner 2026-11-18,
// docs/CHECKPOINTS_DEATH.md §2.4): the base keys, who is on a base, the entry dwell, the record of a base (a sleep zone, or a
// start location without a sleeping place), the record a lie-down writes, overlapping bases, the owners and hostility, the
// start locations of new_game_start_locations.ltx, the footing a map server reports, the respawn past a hostile bed and the
// [coop_bases] row.
#include "test_util.h"

#include "coop_checkpoint_base_rules.h"

#include <cmath>
#include <map>
#include <string>
#include <vector>

using namespace coop::checkpoint;
using namespace coop::checkpoint::base;

namespace
{
Spot spot(Key id, float x, float z, float radius = 50.0f, const char* level = "l05_bar", float y = 0.0f)
{
	Spot s;
	s.id = id;
	s.bed = is_zone_key(id) ? zone_of(id) : kNoSource;
	s.level = level;
	s.pos[0] = x;
	s.pos[1] = y;
	s.pos[2] = z;
	s.radius = radius;
	return s;
}

Record make(Kind kind, uint16_t source, const char* level = "l05_bar", float x = 1.0f, float y = 0.0f, float z = 0.0f)
{
	Record r;
	r.level = level;
	r.pos[0] = x;
	r.pos[1] = y;
	r.pos[2] = z;
	r.level_vertex = 100;
	r.game_vertex = 7;
	r.kind = kind;
	r.source = source;
	r.game_time_ms = 1000;
	return r;
}

Start start(const char* id, uint16_t level, float x, float z, std::vector<std::string> owners, float y = 0.0f)
{
	Start s;
	s.id = id;
	s.level = level;
	s.pos[0] = x;
	s.pos[1] = y;
	s.pos[2] = z;
	s.lvid = 10;
	s.gvid = 20;
	s.owners = std::move(owners);
	return s;
}
} // namespace

// The key of a base: a sleep zone by its object id (0..0xfffe), a start location by 0x10000 + its index; kNoBase: none.
TEST(cp_base_keys)
{
	CHECK_EQ(zone_key(0), Key(0));
	CHECK_EQ(zone_key(0xfffe), Key(0xfffe));
	CHECK_EQ(zone_key(kNoSource), kNoBase);
	CHECK_EQ(start_key(0), Key(0x10000));
	CHECK_EQ(start_key(kMaxStarts - 1), Key(0x10000 + kMaxStarts - 1));
	CHECK_EQ(start_key(kMaxStarts), kNoBase);
	CHECK(is_zone_key(0) && is_zone_key(0xfffe) && !is_zone_key(0xffff) && !is_zone_key(kNoBase));
	CHECK(is_start_key(kStartKeyBase) && !is_start_key(kStartKeyBase + Key(kMaxStarts)) && !is_start_key(kNoBase));
	CHECK(!is_zone_key(kStartKeyBase) && !is_start_key(0xfffe));
	CHECK_EQ(zone_of(Key(77)), uint16_t(77));
	CHECK_EQ(zone_of(start_key(3)), kNoSource);
	CHECK_EQ(start_of(start_key(3)), size_t(3));
	CHECK_EQ(start_of(Key(77)), kMaxStarts);
	CHECK_EQ(start_of(kNoBase), kMaxStarts);
	CHECK(!is_base_key(kNoBase) && is_base_key(0) && is_base_key(start_key(0)) && !is_base_key(0x20000));
}

// "On a base": the same level, within the radius horizontally and 10 m in height; once on it he stays until radius + 10 m
// (or 15 m in height); of several bases the one he is on, else the nearest friendly one. A start base works the same way.
TEST(cp_base_at)
{
	const std::vector<Spot> bar = {spot(10, 0, 0)};
	const float at49[3] = {49, 0, 0}, at55[3] = {55, 0, 0}, at61[3] = {61, 0, 0}, at51[3] = {51, 0, 0};
	CHECK_EQ(base_at(bar, "l05_bar", at49, kNoBase), Key(10)); // entering at 49 m
	CHECK_EQ(base_at(bar, "l05_bar", at51, kNoBase), kNoBase); // 51 m from outside: not yet
	CHECK_EQ(base_at(bar, "l05_bar", at55, 10), Key(10)); // 55 m after he entered: still on it
	CHECK_EQ(base_at(bar, "l05_bar", at61, 10), kNoBase); // 61 m: he left
	CHECK_EQ(base_at(bar, "l05_bar", at55, kNoBase), kNoBase);
	CHECK_EQ(base_at(bar, "l01_escape", at49, kNoBase), kNoBase); // another level
	CHECK_EQ(base_at(bar, "l01_escape", at49, 10), kNoBase);
	// the margin of the ltx
	CHECK_EQ(base_at(bar, "l05_bar", at55, 10, 3.0f), kNoBase);
	// the height: a floor 10 m up is the base, 11 m is not; after entering 15 m holds, 16 m does not
	const float up10[3] = {0, 10, 0}, up11[3] = {0, 11, 0}, up15[3] = {0, -15, 0}, up16[3] = {0, 16, 0};
	CHECK_EQ(base_at(bar, "l05_bar", up10, kNoBase), Key(10));
	CHECK_EQ(base_at(bar, "l05_bar", up11, kNoBase), kNoBase);
	CHECK_EQ(base_at(bar, "l05_bar", up15, 10), Key(10));
	CHECK_EQ(base_at(bar, "l05_bar", up16, 10), kNoBase);
	// two bases: the nearest
	const std::vector<Spot> two = {spot(20, 0, 0), spot(21, 60, 0)};
	const float at40[3] = {40, 0, 0}, at20[3] = {20, 0, 0};
	CHECK_EQ(base_at(two, "l05_bar", at40, kNoBase), Key(21));
	CHECK_EQ(base_at(two, "l05_bar", at20, kNoBase), Key(20));
	// ... but the one he is on holds while he is within its leave range (no flicker between two close zones)
	CHECK_EQ(base_at(two, "l05_bar", at40, 20), Key(20));
	const float at62[3] = {62, 0, 0};
	CHECK_EQ(base_at(two, "l05_bar", at62, 20), Key(21));
	// a hostile base is no base for him, and does not hide a friendly one behind it
	std::vector<Spot> mixed = {spot(30, 0, 0), spot(31, 30, 0)};
	mixed[0].hostile = true;
	const float at5[3] = {5, 0, 0};
	CHECK_EQ(base_at(mixed, "l05_bar", at5, kNoBase), Key(31));
	CHECK_EQ(base_at(mixed, "l05_bar", at5, 30), Key(31)); // it turned hostile while he was on it
	mixed[1].hostile = true;
	CHECK_EQ(base_at(mixed, "l05_bar", at5, kNoBase), kNoBase);
	// a spot without a key is never a base, nor one with a key that names nothing
	std::vector<Spot> none = {spot(kNoBase, 0, 0), spot(0x20000, 0, 0)};
	CHECK_EQ(base_at(none, "l05_bar", at5, kNoBase), kNoBase);
	CHECK_EQ(base_at(none, "l05_bar", at5, 0x20000), kNoBase);
	// a start base (no sleeping place): its key
	const std::vector<Spot> camp = {spot(start_key(4), 100, 100)};
	const float at_camp[3] = {120, 0, 100};
	CHECK_EQ(base_at(camp, "l05_bar", at_camp, kNoBase), start_key(4));
	// garbage in the position: not on a base
	const float bad[3] = {std::nanf(""), 0, 0};
	CHECK_EQ(base_at(bar, "l05_bar", bad, kNoBase), kNoBase);
	// stands_on: a tent of his on the base (strict radius)
	CHECK(stands_on(bar[0], "l05_bar", at49));
	CHECK(!stands_on(bar[0], "l05_bar", at55));
	CHECK(!stands_on(bar[0], "l01_escape", at49));
}

// The entry: 3 s on a friendly base, not in a fight, and the base's record becomes his checkpoint, once; nothing when it is his
// checkpoint already or his own tent stands there; the tent folded, the base again after the dwell.
TEST(cp_base_decision)
{
	constexpr uint32_t kDwell = 3000;
	// outside a base: the campfires as today
	{
		Visit v;
		CHECK(step(v, kNoBase, false, false, 0, kDwell) == Step::Outside);
	}
	// a campfire on the base is no source (the caller skips it on OnBase); 3 s: the bed; then nothing
	{
		Visit v;
		CHECK(step(v, 10, false, false, 0, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 2999, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 3000, kDwell) == Step::SetBed);
		CHECK(step(v, 10, false, false, 3500, kDwell) == Step::OnBase); // the store has not answered yet: once
		CHECK(step(v, 10, true, false, 4000, kDwell) == Step::OnBase); // now it is his bed
		CHECK(step(v, 10, true, false, 60000, kDwell) == Step::OnBase);
		CHECK_EQ(v.base, Key(10));
	}
	// a fight restarts the count
	{
		Visit v;
		CHECK(step(v, 10, false, false, 0, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, true, 2000, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 4999, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 5000, kDwell) == Step::SetBed);
	}
	// the bed is his checkpoint already (he comes back): nothing, however long he stays
	{
		Visit v;
		for (uint64_t t = 0; t <= 20000; t += 500)
			CHECK(step(v, 10, true, false, t, kDwell) == Step::OnBase);
	}
	// his own tent on this base is his checkpoint: nothing; he folds it (the record rolls back): the bed 3 s later
	{
		Visit v;
		CHECK(step(v, 10, true, false, 0, kDwell) == Step::OnBase);
		CHECK(step(v, 10, true, false, 10000, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 10500, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 12999, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 13000, kDwell) == Step::SetBed);
	}
	// a story checkpoint on the base after the bed: the bed takes over again after the dwell
	{
		Visit v;
		CHECK(step(v, 10, true, false, 0, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 500, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 3500, kDwell) == Step::SetBed);
	}
	// leaving ends the visit; coming back counts anew
	{
		Visit v;
		CHECK(step(v, 10, false, false, 0, kDwell) == Step::OnBase);
		CHECK(step(v, kNoBase, false, false, 2000, kDwell) == Step::Outside);
		CHECK_EQ(v.base, kNoBase);
		CHECK(step(v, 10, false, false, 2500, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 5499, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 5500, kDwell) == Step::SetBed);
	}
	// another base (a start base this time): its own count
	{
		Visit v;
		CHECK(step(v, 10, false, false, 0, kDwell) == Step::OnBase);
		CHECK(step(v, start_key(2), false, false, 2000, kDwell) == Step::OnBase);
		CHECK(step(v, start_key(2), false, false, 4999, kDwell) == Step::OnBase);
		CHECK(step(v, start_key(2), false, false, 5000, kDwell) == Step::SetBed);
	}
	// the clock going back never fires early
	{
		Visit v;
		CHECK(step(v, 10, false, false, 10000, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 100, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 3099, kDwell) == Step::OnBase);
		CHECK(step(v, 10, false, false, 3100, kDwell) == Step::SetBed);
	}
}

// The record of a base: kind Rest; a sleep zone base names the zone as its object, a start base has no object and is told by
// its place (the same level, within kSamePlaceM in 3D of its point).
TEST(cp_base_record)
{
	const Spot zone = spot(10, 0, 0);
	CHECK(is_base_record(make(Kind::Rest, 10), zone));
	CHECK(!is_base_record(make(Kind::Rest, 11), zone));
	CHECK(!is_base_record(make(Kind::Campfire, 10), zone));
	CHECK(!is_base_record(make(Kind::Rest, kNoSource, "l05_bar", 0.0f), zone)); // a zone base is told by its object
	CHECK(!is_base_record(Record(), zone));
	const Spot camp = spot(start_key(1), 100, 50, 50.0f, "l01_escape", 2.0f);
	CHECK(is_base_record(make(Kind::Rest, kNoSource, "l01_escape", 100.0f, 2.0f, 50.0f), camp));
	CHECK(is_base_record(make(Kind::Rest, kNoSource, "l01_escape", 106.0f, 10.0f, 50.0f), camp)); // 10 m in 3D
	CHECK(!is_base_record(make(Kind::Rest, kNoSource, "l01_escape", 107.0f, 10.0f, 50.0f), camp));
	CHECK(!is_base_record(make(Kind::Rest, kNoSource, "l05_bar", 100.0f, 2.0f, 50.0f), camp)); // another level
	CHECK(!is_base_record(make(Kind::Rest, 10, "l01_escape", 100.0f, 2.0f, 50.0f), camp)); // a record with an object
	CHECK(!is_base_record(make(Kind::Story, kNoSource, "l01_escape", 100.0f, 2.0f, 50.0f), camp));
	// a spot that names no base has no record
	Spot nothing = camp;
	nothing.id = kNoBase;
	CHECK(!is_base_record(make(Kind::Rest, kNoSource, "l01_escape", 100.0f, 2.0f, 50.0f), nothing));
	Spot zone_without_bed = zone;
	zone_without_bed.bed = kNoSource;
	CHECK(!is_base_record(make(Kind::Rest, kNoSource), zone_without_bed));
}

// Lying down on a base writes the base's record, not the spot he lies at - unless he lies at his own tent. Who may lie down
// is not this rule's (rest_place answers that, unchanged). A start base's record has no object.
TEST(cp_base_lie_down_record)
{
	const Record fire = make(Kind::Campfire, 5, "l05_bar", 3.0f);
	const Record bed = make(Kind::Rest, 10, "l05_bar", 0.0f);
	const Record tent = make(Kind::Tent, 77, "l05_bar", 8.0f);
	CHECK(lie_down_record(fire, false, &bed).source == 10);
	CHECK(lie_down_record(fire, false, &bed).kind == Kind::Rest);
	CHECK(lie_down_record(tent, true, &bed).source == 77); // his own tent: his choice
	CHECK(lie_down_record(fire, false, nullptr).source == 5); // not on a base: as today
	CHECK(lie_down_record(fire, false, &fire).source == 5);
	const Record broken;
	CHECK(lie_down_record(fire, false, &broken).source == 5); // no usable record: as today
	// a start base: kind Rest without an object, its point
	const Record point = make(Kind::Rest, kNoSource, "l05_bar", 40.0f);
	const Record lay = lie_down_record(fire, false, &point);
	CHECK(lay.kind == Kind::Rest && lay.source == kNoSource && lay.pos[0] == 40.0f);
	// a second lie-down on the base is the same place: nothing to write, nothing to announce
	Slot s;
	CHECK(set(s, lie_down_record(fire, false, &bed)) == SetOutcome::New);
	CHECK(set(s, lie_down_record(make(Kind::Campfire, 6, "l05_bar", 20.0f), false, &bed)) == SetOutcome::Same);
	Slot c;
	CHECK(set(c, lie_down_record(fire, false, &point)) == SetOutcome::New);
	CHECK(set(c, lie_down_record(make(Kind::Campfire, 6, "l05_bar", 20.0f), false, &point)) == SetOutcome::Same);
}

// Two bases overlap: the same level, closer horizontally than both radii and both leave margins, and within twice the height a
// base reaches. accept() builds the list of one level: a candidate on the ground of an accepted one is not added.
TEST(cp_base_overlaps_and_accept)
{
	const float m = 10.0f;
	CHECK(overlaps(spot(1, 0, 0), spot(2, 119, 0), m)); // 50 + 50 + 20
	CHECK(!overlaps(spot(1, 0, 0), spot(2, 120, 0), m));
	CHECK(!overlaps(spot(1, 0, 0), spot(2, 10, 0, 50.0f, "l01_escape"), m));
	CHECK(overlaps(spot(1, 0, 0), spot(2, 10, 0, 50.0f, "l05_bar", 30.0f), m)); // 2 * (10 + 5)
	CHECK(!overlaps(spot(1, 0, 0), spot(2, 10, 0, 50.0f, "l05_bar", 31.0f), m));
	CHECK(overlaps(spot(1, 0, 0, 20.0f), spot(2, 0, 69, 30.0f), m)); // radii differ: 20 + 30 + 20
	CHECK(!overlaps(spot(1, 0, 0, 20.0f), spot(2, 0, 70, 30.0f), m));
	Spot nan = spot(2, 0, 0);
	nan.pos[0] = std::nanf("");
	CHECK(!overlaps(spot(1, 0, 0), nan, m));

	// Agroprom: the wagon and the tunnel of one camp; a start location in the camp; another one far away
	std::vector<Spot> list;
	CHECK_EQ(accept(list, spot(500, 0, 0, 50.0f, "l03_agroprom"), m), kAdded);
	CHECK_EQ(accept(list, spot(501, 60, 0, 50.0f, "l03_agroprom"), m), size_t(0)); // the tunnel: dropped, overlaps the wagon
	CHECK_EQ(accept(list, spot(start_key(0), 20, 20, 50.0f, "l03_agroprom"), m), size_t(0));
	CHECK_EQ(accept(list, spot(start_key(1), 400, 0, 50.0f, "l03_agroprom"), m), kAdded);
	CHECK_EQ(accept(list, spot(start_key(2), 450, 0, 50.0f, "l03_agroprom"), m), size_t(1)); // on the earlier start base
	CHECK_EQ(list.size(), size_t(2));
	CHECK_EQ(list[0].id, Key(500));
	CHECK_EQ(list[1].id, start_key(1));
	// a spot that names no base is never added
	CHECK_EQ(accept(list, spot(kNoBase, 2000, 0, 50.0f, "l03_agroprom"), m), kNotAdded);
	Spot bad = spot(7, 2000, 0, 50.0f, "l03_agroprom");
	bad.pos[2] = std::nanf("");
	CHECK_EQ(accept(list, bad, m), kNotAdded);
	CHECK_EQ(list.size(), size_t(2));
}

// Hostility toward this player: the game's own sum, community relation + the community's goodwill to him, enemy at
// <= -1000 (stock game_relations.ENEMIES; coop_task_audience.script hostile()). A base is hostile only when it has at least
// one owner the game knows and every one of them is his enemy; a base without an owner never is.
TEST(cp_base_hostile)
{
	CHECK(!hostile(false, -5000, -5000)); // owner "none"
	CHECK(hostile(true, -1000, 0));
	CHECK(hostile(true, -500, -500));
	CHECK(!hostile(true, -999, 0));
	CHECK(!hostile(true, -1500, 600)); // goodwill earned with them
	CHECK(!hostile(true, 0, 0));
	CHECK(!all_hostile(0, 0)); // nobody's
	CHECK(all_hostile(1, 1));
	CHECK(all_hostile(3, 3));
	CHECK(!all_hostile(3, 2)); // one owner is his friend: the base is his too
	CHECK(!all_hostile(2, 0));
	CHECK(!all_hostile(1, 2)); // more hostile than owners: a caller's mistake, not hostile
	CHECK_EQ(true_faction("actor_dolg"), std::string("dolg"));
	CHECK_EQ(true_faction("dolg"), std::string("dolg"));
	CHECK_EQ(true_faction("actor"), std::string("actor"));
	CHECK_EQ(true_faction("actor_"), std::string("actor_"));
	CHECK_EQ(true_faction(""), std::string(""));
	// Build 57 round 3 (lead's ruling on review B1): the first owner of a row is its holder; the base is hostile when the holder
	// is his enemy, or when every owner the game knows is
	CHECK(base_hostile(true, 3, 1)); // the guards shoot him: hostile, whatever the other factions of the camp think
	CHECK(base_hostile(true, 1, 1));
	CHECK(!base_hostile(false, 3, 2)); // the holder is no enemy of his
	CHECK(base_hostile(false, 3, 3)); // every owner is (the holder can only be false here when the row's first name is unknown)
	CHECK(!base_hostile(false, 0, 0)); // nobody's
	CHECK(!base_hostile(true, 0, 0)); // nobody's, whatever the caller says of a holder
	// Round 3 (lead's ruling on review S4): the community the guards judge him by is his own (the actor_<f> column) while the
	// relation table has a row for it; else the NPC community <f>; else none
	CHECK_EQ(judged_community(24, 9, 32), 24); // actor_killer, not killer
	CHECK_EQ(judged_community(0, 9, 32), 0);
	CHECK_EQ(judged_community(31, 9, 32), 31);
	CHECK_EQ(judged_community(32, 9, 32), 9); // no row for his own: the NPC community's
	CHECK_EQ(judged_community(-1, 9, 32), 9);
	CHECK_EQ(judged_community(-1, -1, 32), -1);
	CHECK_EQ(judged_community(40, 40, 32), -1);
	CHECK_EQ(judged_community(5, 9, 0), -1); // no table at all
}

namespace
{
// The stand's configs\creatures\game_relations.ltx (G.A.M.M.A. game-dev, read 2026-11-18 by temp\tests_bed\relations_table_r3.py),
// [communities_relations]: the rows of the owner communities of [coop_bases] in the actor_<f> columns, the relation of that
// owner's guards to a player of <f> (RELATION_REGISTRY::GetCommunityRelation(owner, his community)). On the stand the actor_<f>
// column and the NPC <f> column of these rows agree on "enemy" everywhere (relations_r3.py).
const char* const kStandColumns[10] = {"actor_stalker", "actor_bandit", "actor_dolg", "actor_freedom", "actor_csky",
	"actor_ecolog", "actor_killer", "actor_army", "actor_monolith", "actor_renegade"};
struct StandRow
{
	const char* owner;
	int to[10];
};
const StandRow kStandRows[] = {
	{"stalker", {0, -2000, 0, 0, 0, 0, -2000, -2000, -2000, -2000}}, // line 69
	{"csky", {0, -2000, -2000, 0, 300, 0, 0, -2000, -2000, -2000}}, // line 71
	{"ecolog", {0, -2000, 0, 0, 0, 300, 0, 0, -2000, -2000}}, // line 63
	{"dolg", {0, -2000, 300, -2000, -2000, 0, -2000, 0, -2000, -2000}}, // line 62
	{"freedom", {0, 0, -2000, 300, 0, 0, 0, -2000, -2000, -2000}}, // line 64
	{"bandit", {-2000, 300, -2000, 0, -2000, -2000, 0, -2000, -2000, 300}}, // line 61
	{"killer", {-2000, 0, -2000, 0, 0, 0, 300, -2000, -2000, -2000}}, // line 65
	{"army", {-2000, -2000, 0, -2000, -2000, 0, -2000, 300, -2000, -2000}}, // line 66
};

int stand_relation(const std::string& owner, const std::string& player)
{
	for (const StandRow& r : kStandRows)
		if (owner == r.owner)
			for (int c = 0; c < 10; ++c)
				if (player == kStandColumns[c])
					return r.to[c];
	return 1000000; // a mistake of the test itself: CHECKed below never to happen
}

// What hostile_to does in the engine, on the stand's numbers: each owner by hostile() (relation + his goodwill with it), the
// first owner the holder.
bool stand_hostile(const std::vector<std::string>& owners, const char* player, int goodwill = 0)
{
	size_t n = 0;
	bool holder = false;
	for (size_t i = 0; i < owners.size(); ++i)
	{
		const bool h = hostile(true, stand_relation(owners[i], player), goodwill);
		n += h ? 1 : 0;
		holder = holder || (i == 0 && h);
	}
	return base_hostile(holder, owners.size(), n);
}

bool stand_all_hostile(const std::vector<std::string>& owners, const char* player)
{
	size_t n = 0;
	for (const std::string& o : owners)
		n += hostile(true, stand_relation(o, player), 0) ? 1 : 0;
	return all_hostile(owners.size(), n);
}
} // namespace

// Build 57 round 3 (lead's ruling on review B1): the five cases of the review on the stand's relations. A mercenary or a soldier
// at Rookie Village, the Agroprom stalker camp, Skadovsk, Yanov or the Pripyat stalkers' base is among enemies (their stalker
// guards); nobody who lives there becomes hostile; the Yantar bunker's holder is ecolog (its smart spawns only ecolog squads).
TEST(cp_base_holder_on_stand_relations)
{
	for (const StandRow& r : kStandRows)
		for (const char* c : kStandColumns)
			CHECK(stand_relation(r.owner, c) != 1000000);
	const std::vector<std::string> rookie = {"stalker", "csky", "ecolog"}; // esc_basement_sleep_area
	const std::vector<std::string> agr_camp = {"stalker", "csky", "ecolog"}; // agr_sr_sleep_wagon
	const std::vector<std::string> yantar = {"ecolog", "stalker", "csky"}; // yan_bunker_sleep_restrictor (round 3: ecolog first)
	const std::vector<std::string> skadovsk = {"stalker", "csky", "dolg"}; // zat_a2_sr_sleep
	const std::vector<std::string> yanov = {"stalker", "freedom", "ecolog"}; // jup_a6_sr_sleep
	const std::vector<std::string> pri_a16 = {"stalker", "bandit", "csky", "dolg", "freedom"}; // pri_a16_sr_sleep
	// 1. Rookie Village: killer and army are its guards' enemies (the old rule called it theirs: csky / ecolog are not)
	CHECK(stand_hostile(rookie, "actor_killer"));
	CHECK(stand_hostile(rookie, "actor_army"));
	CHECK(!stand_all_hostile(rookie, "actor_killer") && !stand_all_hostile(rookie, "actor_army")); // what the old rule said
	CHECK(stand_hostile(rookie, "actor_bandit"));
	for (const char* friendly : {"actor_stalker", "actor_csky", "actor_ecolog", "actor_dolg", "actor_freedom"})
		CHECK(!stand_hostile(rookie, friendly));
	// goodwill earned with the stalkers counts as in the game: a mercenary at +1500 with them is let in
	CHECK(!stand_hostile(rookie, "actor_killer", 1500));
	// 2. the Agroprom stalker camp the same; the Yantar bunker is held by the ecologists, who do not shoot mercenaries and soldiers
	CHECK(stand_hostile(agr_camp, "actor_killer") && stand_hostile(agr_camp, "actor_army"));
	CHECK(!stand_hostile(yantar, "actor_killer") && !stand_hostile(yantar, "actor_army"));
	CHECK(stand_hostile(yantar, "actor_bandit") && stand_hostile(yantar, "actor_monolith"));
	for (const char* friendly : {"actor_stalker", "actor_csky", "actor_ecolog", "actor_dolg", "actor_freedom"})
		CHECK(!stand_hostile(yantar, friendly));
	// 3. Skadovsk: army and killer (dolg / csky are no enemies of theirs); its dolg and csky stay welcome
	CHECK(stand_hostile(skadovsk, "actor_army") && stand_hostile(skadovsk, "actor_killer"));
	CHECK(!stand_all_hostile(skadovsk, "actor_army") && !stand_all_hostile(skadovsk, "actor_killer"));
	for (const char* friendly : {"actor_stalker", "actor_csky", "actor_dolg", "actor_freedom", "actor_ecolog"})
		CHECK(!stand_hostile(skadovsk, friendly));
	// 4. Yanov: bandit, killer, army; its freedom and ecolog stay welcome
	CHECK(stand_hostile(yanov, "actor_bandit") && stand_hostile(yanov, "actor_killer") && stand_hostile(yanov, "actor_army"));
	CHECK(!stand_all_hostile(yanov, "actor_bandit"));
	for (const char* friendly : {"actor_stalker", "actor_freedom", "actor_ecolog", "actor_dolg", "actor_csky"})
		CHECK(!stand_hostile(yanov, friendly));
	// 5. pri_a16 (five owners): friendly to almost everyone before; now its stalker guards decide
	CHECK(stand_hostile(pri_a16, "actor_bandit") && stand_hostile(pri_a16, "actor_killer") &&
		stand_hostile(pri_a16, "actor_army") && stand_hostile(pri_a16, "actor_renegade"));
	CHECK(!stand_all_hostile(pri_a16, "actor_bandit") && !stand_all_hostile(pri_a16, "actor_killer"));
	for (const char* friendly : {"actor_stalker", "actor_csky", "actor_dolg", "actor_freedom", "actor_ecolog"})
		CHECK(!stand_hostile(pri_a16, friendly));
	// a single-owner base is what it was: the Bar is Duty's, a Freedom player is its enemy, a Duty one is home
	CHECK(stand_hostile({"dolg"}, "actor_freedom") && !stand_hostile({"dolg"}, "actor_dolg"));
}

// Respawn: the current record is the bed of a base hostile to him now -> the previous record (on this level) is used;
// without one, today's behaviour (the bed).
TEST(cp_base_respawn_skips_hostile_bed)
{
	const Record bed = make(Kind::Rest, 10, "l05_bar", 0.0f);
	const Record fire = make(Kind::Campfire, 5, "l05_bar", 200.0f);
	{
		Slot s;
		s.cur = bed;
		s.prev = fire;
		CHECK(skip_hostile_bed(s, "l05_bar", true, false) == BedChoice::UsePrev);
		CHECK(s.cur.source == 5 && !s.prev.valid());
		CHECK(resolve(s, "l05_bar", nullptr, nullptr, bed.pos).pick == Pick::Current);
	}
	{
		Slot s;
		s.cur = bed;
		s.prev = fire;
		CHECK(skip_hostile_bed(s, "l05_bar", false, false) == BedChoice::Keep); // friendly: the bed
		CHECK(s.cur.source == 10);
	}
	// Build 57 round 2 (lead's ruling on review S2): no previous record on his level: the hostile record is not used, the
	// respawn goes where a player without a checkpoint goes (resolve: the anchor, the arrival point, the body).
	const float anchor[3] = {500.0f, 0.0f, 500.0f};
	{
		Slot s;
		s.cur = bed;
		CHECK(hostile_bed_choice(s, "l05_bar", true, false) == BedChoice::DropCur);
		CHECK(skip_hostile_bed(s, "l05_bar", true, false) == BedChoice::DropCur); // nothing before it
		CHECK(!s.cur.valid() && !s.prev.valid());
		CHECK(resolve(s, "l05_bar", anchor, nullptr, bed.pos).pick == Pick::Anchor);
		CHECK(resolve(s, "l05_bar", nullptr, nullptr, bed.pos).pick == Pick::Body);
	}
	{
		Slot s;
		s.cur = bed;
		s.prev = make(Kind::Campfire, 5, "l01_escape", 200.0f);
		CHECK(skip_hostile_bed(s, "l05_bar", true, false) == BedChoice::DropCur); // the previous one is on another level: no use here
		CHECK(!s.cur.valid());
		CHECK(s.prev.level == "l01_escape"); // the slot copy keeps it; resolve skips it on this level
		CHECK(resolve(s, "l05_bar", anchor, nullptr, bed.pos).pick == Pick::Anchor);
	}
	// the decision itself, without changing anything
	{
		Slot s;
		s.cur = bed;
		s.prev = fire;
		CHECK(hostile_bed_choice(s, "l05_bar", true, false) == BedChoice::UsePrev);
		CHECK(hostile_bed_choice(s, "l05_bar", false, false) == BedChoice::Keep);
		CHECK(s.cur.source == 10 && s.prev.source == 5);
		// a hostile record of another level is not where he comes back here anyway: kept as it is
		Slot o;
		o.cur = make(Kind::Rest, 10, "l01_escape", 0.0f);
		CHECK(hostile_bed_choice(o, "l05_bar", true, false) == BedChoice::Keep);
		CHECK(skip_hostile_bed(o, "l05_bar", true, false) == BedChoice::Keep);
		CHECK(o.cur.valid());
		// no record: nothing to drop
		Slot e;
		CHECK(hostile_bed_choice(e, "l05_bar", true, true) == BedChoice::Keep);
	}
	// Build 57 round 3 (lead's ruling on review S1): the previous record is used only when it is not a hostile base's record too.
	// A Freedom player: the Bar's bed now, before it the bed of another Duty base of the same level; Duty is hostile to him now.
	const Record duty_post = make(Kind::Rest, 11, "l05_bar", 120.0f);
	{
		Slot s;
		s.cur = bed;
		s.prev = duty_post;
		CHECK(hostile_bed_choice(s, "l05_bar", true, true) == BedChoice::DropCur);
		CHECK(skip_hostile_bed(s, "l05_bar", true, true) == BedChoice::DropCur);
		CHECK(!s.cur.valid() && !s.prev.valid()); // neither: resolve must not take the previous one
		CHECK(resolve(s, "l05_bar", anchor, nullptr, bed.pos).pick == Pick::Anchor);
		CHECK(resolve(s, "l05_bar", nullptr, nullptr, bed.pos).pick == Pick::Body);
	}
	{
		// the current record is friendly: it is used, the hostile previous one does not matter
		Slot s;
		s.cur = fire;
		s.prev = duty_post;
		CHECK(skip_hostile_bed(s, "l05_bar", false, true) == BedChoice::Keep);
		CHECK(resolve(s, "l05_bar", anchor, nullptr, bed.pos).pick == Pick::Current);
	}
	{
		// the current record is on another level, resolve would take the previous one of his level: a hostile base's is dropped
		Slot s;
		s.cur = make(Kind::Campfire, 5, "l01_escape", 200.0f);
		s.prev = duty_post;
		CHECK(resolve(s, "l05_bar", anchor, nullptr, bed.pos).pick == Pick::Previous); // what it would do
		CHECK(hostile_bed_choice(s, "l05_bar", false, true) == BedChoice::DropPrev);
		CHECK(skip_hostile_bed(s, "l05_bar", false, true) == BedChoice::DropPrev);
		CHECK(s.cur.level == "l01_escape" && !s.prev.valid());
		CHECK(resolve(s, "l05_bar", anchor, nullptr, bed.pos).pick == Pick::Anchor);
		// a friendly previous one is kept
		Slot f;
		f.cur = make(Kind::Campfire, 5, "l01_escape", 200.0f);
		f.prev = duty_post;
		CHECK(skip_hostile_bed(f, "l05_bar", false, false) == BedChoice::Keep);
		CHECK(resolve(f, "l05_bar", anchor, nullptr, bed.pos).pick == Pick::Previous);
		// a hostile previous one of another level: not his place here anyway
		Slot o;
		o.cur = make(Kind::Campfire, 5, "l01_escape", 200.0f);
		o.prev = make(Kind::Rest, 11, "l02_garbage", 0.0f);
		CHECK(hostile_bed_choice(o, "l05_bar", false, true) == BedChoice::Keep);
	}
}

// One row of [coop_bases]: <sleep zone> = <radius>, <owner community>[, <owner>...] (up to kMaxOwners) or none.
TEST(cp_bases_ltx)
{
	Row r;
	CHECK(parse_row("bar_actor_sleep_zone", "50, dolg", r));
	CHECK_EQ(r.zone, std::string("bar_actor_sleep_zone"));
	CHECK(std::fabs(r.radius - 50.0f) < 0.001f);
	CHECK(r.owners == std::vector<std::string>({"dolg"}));
	CHECK(parse_row("esc_basement_sleep_area", " 35.5 ,none ", r));
	CHECK(std::fabs(r.radius - 35.5f) < 0.001f);
	CHECK(r.owners.empty());
	CHECK(parse_row("x", "60", r)); // no owner: none
	CHECK(r.owners.empty() && std::fabs(r.radius - 60.0f) < 0.001f);
	CHECK(parse_row("x", "", r)); // nothing: the default radius, no owner
	CHECK(std::fabs(r.radius - kDefaultRadius) < 0.001f && r.owners.empty());
	CHECK(parse_row("x", ", killer", r));
	CHECK(std::fabs(r.radius - kDefaultRadius) < 0.001f && r.owners == std::vector<std::string>({"killer"}));
	CHECK(parse_row("x", "50,", r) && r.owners.empty());
	// Build 57 round 2 (lead's ruling 2): several owners, as the game's simulation data gives them
	CHECK(parse_row("pri_a16_sr_sleep", "50, stalker, bandit, csky, dolg, freedom", r));
	CHECK(r.owners == std::vector<std::string>({"stalker", "bandit", "csky", "dolg", "freedom"}));
	CHECK(parse_row("x", "50, a, b, c, d, e, f", r) && r.owners.size() == kMaxOwners); // six: the bound
	CHECK(parse_row("x", "50, stalker, csky, stalker", r)); // twice: once
	CHECK(r.owners == std::vector<std::string>({"stalker", "csky"}));
	Row keep;
	keep.zone = "kept";
	CHECK(!parse_row("x", "-5, dolg", keep)); // not a radius
	CHECK(!parse_row("x", "0, dolg", keep));
	CHECK(!parse_row("x", "501, dolg", keep));
	CHECK(!parse_row("x", "nan, dolg", keep));
	CHECK(!parse_row("x", "fifty, dolg", keep));
	CHECK(!parse_row("x", "50, a, b, c, d, e, f, g", keep)); // seven owners
	CHECK(!parse_row("x", "50, dolg, none", keep)); // none is alone or not at all
	CHECK(!parse_row("x", "50, dolg, , freedom", keep)); // an empty owner between two
	CHECK(!parse_row("x", "50, dolg,", keep));
	CHECK(!parse_row("x", "50, do lg", keep));
	CHECK(!parse_row("x", "50, dolg|x", keep));
	CHECK(!parse_row("", "50, dolg", keep)); // no zone name
	CHECK(!parse_row("bad zone", "50, dolg", keep));
	CHECK(!parse_row(std::string(65, 'a'), "50, dolg", keep));
	CHECK_EQ(keep.zone, std::string("kept")); // a bad row leaves `out` as it was
}

// A start location of new_game_start_locations.ltx: its section's lvid, gvid, x, y, z as plain numbers, the position within
// 100 km; the factions whose lists name it are its owners.
TEST(cp_base_start_parse)
{
	Start s;
	CHECK(parse_start("car_park", "436975", "440", "106.27", "-2.86", "-1.75", s));
	CHECK_EQ(s.id, std::string("car_park"));
	CHECK_EQ(s.lvid, uint32_t(436975));
	CHECK_EQ(s.gvid, uint16_t(440));
	CHECK(std::fabs(s.pos[0] - 106.27f) < 0.001f && std::fabs(s.pos[1] + 2.86f) < 0.001f && std::fabs(s.pos[2] + 1.75f) < 0.001f);
	CHECK(!s.merged && s.owners.empty() && s.level == kNoLevel);
	Start keep;
	keep.id = "kept";
	CHECK(!parse_start("car_park", "abc", "440", "1", "2", "3", keep));
	CHECK(!parse_start("car_park", "-1", "440", "1", "2", "3", keep));
	CHECK(!parse_start("car_park", "4294967295", "440", "1", "2", "3", keep)); // no vertex
	CHECK(!parse_start("car_park", "5", "65535", "1", "2", "3", keep)); // no game vertex
	CHECK(!parse_start("car_park", "5", "70000", "1", "2", "3", keep));
	CHECK(!parse_start("car_park", "5", "440", "100000", "2", "3", keep)); // |x| < 100 km
	CHECK(!parse_start("car_park", "5", "440", "1", "2", "-100000", keep));
	CHECK(!parse_start("car_park", "5", "440", "1", "100000", "3", keep));
	CHECK(!parse_start("car_park", "5", "440", "nan", "2", "3", keep));
	CHECK(!parse_start("car_park", "5", "440", "1", "", "3", keep));
	CHECK(!parse_start("car park", "5", "440", "1", "2", "3", keep)); // not a name
	CHECK(!parse_start("", "5", "440", "1", "2", "3", keep));
	CHECK_EQ(keep.id, std::string("kept"));
	CHECK(parse_start("x", "0", "0", "-99999.5", "0", "99999.5", s));

}

// Build 57 round 2 (lead's ruling on review B1): start locations are bases only by a row of [coop_start_bases]:
// <start location id> = <owner community>[, <owner>...] or none. The owners come from that row, never from the factions
// whose lists name the place; the position from the start locations file.
TEST(cp_base_start_rows)
{
	StartRow r;
	CHECK(parse_start_row("car_park", "bandit", r));
	CHECK_EQ(r.id, std::string("car_park"));
	CHECK(r.owners == std::vector<std::string>({"bandit"}));
	CHECK(parse_start_row("x", " none ", r) && r.owners.empty());
	CHECK(parse_start_row("x", "", r) && r.owners.empty());
	CHECK(parse_start_row("x", "army, ecolog", r));
	CHECK(r.owners == std::vector<std::string>({"army", "ecolog"}));
	StartRow keep;
	keep.id = "kept";
	CHECK(!parse_start_row("bad id", "bandit", keep));
	CHECK(!parse_start_row("x", "ban dit", keep));
	CHECK(!parse_start_row("x", "bandit, none", keep));
	CHECK(!parse_start_row("x", "a, b, c, d, e, f, g", keep));
	CHECK(!parse_start_row("x", "bandit,", keep));
	CHECK_EQ(keep.id, std::string("kept"));

	// the places of the file (owners there, if any, are what the faction lists would say: not used)
	std::vector<Start> located = {
	    start("rookie_village", kNoLevel, 0, 0, {"csky", "stalker"}),
	    start("car_park", kNoLevel, 10, 0, {"bandit", "freedom"}),
	    start("truck_cemetery_bandits_post", kNoLevel, 20, 0, {"bandit", "freedom"}),
	};
	std::vector<StartRow> rows(3);
	CHECK(parse_start_row("truck_cemetery_bandits_post", "bandit", rows[0]));
	CHECK(parse_start_row("car_park", "bandit", rows[1]));
	CHECK(parse_start_row("not_a_location", "army", rows[2]));
	std::vector<std::string> missing;
	const std::vector<Start> bases = start_bases(rows, located, missing);
	CHECK_EQ(bases.size(), size_t(2)); // rookie_village has no row: no base; not_a_location has no place: skipped
	CHECK_EQ(bases[0].id, std::string("truck_cemetery_bandits_post")); // in the order of the rows
	CHECK(bases[0].owners == std::vector<std::string>({"bandit"})); // the row's owner, not bandit + freedom
	CHECK(std::fabs(bases[0].pos[0] - 20.0f) < 0.001f); // the place from the file
	CHECK_EQ(bases[1].id, std::string("car_park"));
	CHECK(bases[1].owners == std::vector<std::string>({"bandit"}));
	CHECK(missing == std::vector<std::string>({"not_a_location"}));
	CHECK_EQ(find_start(bases, "rookie_village"), bases.size());
	// a row twice: the first one
	std::vector<StartRow> twice(2);
	CHECK(parse_start_row("car_park", "bandit", twice[0]));
	CHECK(parse_start_row("car_park", "army", twice[1]));
	missing.clear();
	const std::vector<Start> one = start_bases(twice, located, missing);
	CHECK(one.size() == 1 && one[0].owners == std::vector<std::string>({"bandit"}) && missing.empty());
	// at most kMaxStarts
	std::vector<Start> many_places;
	std::vector<StartRow> many_rows;
	for (size_t i = 0; i < kMaxStarts + 3; ++i)
	{
		many_places.push_back(start(("loc_" + std::to_string(i)).c_str(), kNoLevel, float(i) * 1000.0f, 0, {}));
		StartRow sr;
		CHECK(parse_start_row("loc_" + std::to_string(i), "army", sr));
		many_rows.push_back(sr);
	}
	missing.clear();
	CHECK_EQ(start_bases(many_rows, many_places, missing).size(), kMaxStarts);
}

// Start locations of one level that overlap are one base: in list order a later one is merged into the earlier one and gives
// it its owners. Only the ltx and the level of the game vertex count, so every process gets the same list.
TEST(cp_base_merge_starts)
{
	std::vector<Start> s = {
	    start("rookie_village", 1, 0, 0, {"csky"}),
	    start("hidden_base", 2, 0, 0, {"csky"}),
	    start("car_park", 1, 30, 0, {"bandit", "csky"}),
	    start("pole_bandit_base", 1, 400, 0, {"bandit"}),
	    start("southern_checkpoint", 1, 500, 0, {"army"}),
	    start("far_post", 1, 610, 0, {"isg"}),
	    start("no_level", kNoLevel, 0, 0, {"army"}),
	};
	merge_starts(s, 50.0f, 10.0f);
	CHECK(!s[0].merged && !s[1].merged);
	CHECK(s[2].merged && s[2].into == 0);
	CHECK_EQ(s[0].owners.size(), size_t(2)); // csky, bandit
	CHECK_EQ(s[0].owners[1], std::string("bandit"));
	CHECK(!s[3].merged);
	CHECK(s[4].merged && s[4].into == 3); // 100 m: 50 + 50 + 20 > 100
	CHECK_EQ(s[3].owners.size(), size_t(2));
	CHECK(!s[5].merged); // 110 m from the merged one, 210 from the base it went into: compared with bases only
	CHECK(!s[6].merged); // a level the game does not know merges with nothing
	// the same input, the same answer
	std::vector<Start> again = {
	    start("rookie_village", 1, 0, 0, {"csky"}),
	    start("hidden_base", 2, 0, 0, {"csky"}),
	    start("car_park", 1, 30, 0, {"bandit", "csky"}),
	    start("pole_bandit_base", 1, 400, 0, {"bandit"}),
	    start("southern_checkpoint", 1, 500, 0, {"army"}),
	    start("far_post", 1, 610, 0, {"isg"}),
	    start("no_level", kNoLevel, 0, 0, {"army"}),
	};
	merge_starts(again, 50.0f, 10.0f);
	for (size_t i = 0; i < s.size(); ++i)
		CHECK(again[i].merged == s[i].merged && again[i].into == s[i].into && again[i].owners == s[i].owners);
}

// "He stands on the ground of a base", as the map server of his level reports it to the world server: none, a sleep zone base
// or a start base, with the base's point. Nothing of it is trusted before footing_ok.
TEST(cp_base_footing)
{
	Footing none;
	CHECK(footing_ok(none));
	CHECK_EQ(key_of(none), kNoBase);
	Footing z;
	CHECK(footing_of(Key(1234), z));
	CHECK_EQ(int(z.kind), int(kFootZone));
	CHECK_EQ(z.ref, uint16_t(1234));
	CHECK(footing_ok(z));
	CHECK_EQ(key_of(z), Key(1234));
	Footing st;
	CHECK(footing_of(start_key(5), st));
	CHECK_EQ(int(st.kind), int(kFootStart));
	CHECK_EQ(st.ref, uint16_t(5));
	CHECK_EQ(key_of(st), start_key(5));
	Footing n;
	CHECK(footing_of(kNoBase, n));
	CHECK_EQ(int(n.kind), int(kFootNone));
	CHECK_EQ(n.ref, uint16_t(0xffff));
	Footing keep = z;
	CHECK(!footing_of(Key(0x20000), keep)); // names nothing
	CHECK_EQ(keep.ref, uint16_t(1234));
	// what may come off the wire
	Footing bad = none;
	bad.kind = 3;
	CHECK(!footing_ok(bad));
	CHECK_EQ(key_of(bad), kNoBase);
	bad = none;
	bad.ref = 5; // "none" names nothing
	CHECK(!footing_ok(bad));
	bad = z;
	bad.ref = 0xffff;
	CHECK(!footing_ok(bad));
	bad = st;
	bad.ref = uint16_t(kMaxStarts);
	CHECK(!footing_ok(bad));
	CHECK_EQ(key_of(bad), kNoBase);
	bad = z;
	bad.pos[1] = std::nanf("");
	CHECK(!footing_ok(bad));
	bad = z;
	bad.pos[0] = INFINITY;
	CHECK(!footing_ok(bad));
	bad = z;
	bad.pos[2] = 2.0e6f; // beyond what a record holds
	CHECK(!footing_ok(bad));
}

// Build 57 round 2 (lead's ruling on review S5): the world server's check of a footing a map server reported, every refusal.
// The point is on the base's ground: horizontally within its radius plus the leave margin, in height within 2 x kHeight.
TEST(cp_base_footing_check)
{
	Footing start;
	CHECK(footing_of(start_key(2), start));
	start.pos[0] = 100.0f;
	start.pos[1] = 5.0f;
	start.pos[2] = 0.0f;
	start.gv = 77;
	FootBase b;
	b.known = true;
	b.level = 3;
	b.pos[0] = 70.0f; // the authored start position, 30 m from the reported point
	b.pos[1] = 0.0f;
	b.pos[2] = 0.0f;
	b.radius = 50.0f;
	const float body[3] = {95.0f, 1.0f, 3.0f}; // the body of the same report, near the bed point
	CHECK(footing_check(start, 3, 3, b, 10.0f, body) == FootCheck::Ok);
	// none: nothing to keep, nothing refused
	CHECK(footing_check(Footing(), 3, 3, b, 10.0f, body) == FootCheck::None);
	// not sound
	Footing bad = start;
	bad.kind = 7;
	CHECK(footing_check(bad, 3, 3, b, 10.0f, body) == FootCheck::NotSound);
	bad = Footing();
	bad.ref = 4; // "none" naming something
	CHECK(footing_check(bad, 3, 3, b, 10.0f, body) == FootCheck::NotSound);
	// its game vertex is not on the sender's level (or no level at all)
	CHECK(footing_check(start, 3, 4, b, 10.0f, body) == FootCheck::VertexOff);
	CHECK(footing_check(start, 3, kNoLevel, b, 10.0f, body) == FootCheck::VertexOff);
	CHECK(footing_check(start, kNoLevel, kNoLevel, b, 10.0f, body) == FootCheck::VertexOff);
	// the base is not one of this world's (unknown zone, merged or unknown start)
	FootBase unknown = b;
	unknown.known = false;
	CHECK(footing_check(start, 3, 3, unknown, 10.0f, body) == FootCheck::NoBase);
	// the base is on another level than the sender's
	FootBase other = b;
	other.level = 4;
	CHECK(footing_check(start, 3, 3, other, 10.0f, body) == FootCheck::OtherLevel);
	// the point is off its ground: horizontally beyond radius + margin, or too high
	Footing far_off = start;
	far_off.pos[0] = 70.0f + 60.5f;
	CHECK(footing_check(far_off, 3, 3, b, 10.0f, body) == FootCheck::OffGround);
	far_off.pos[0] = 70.0f + 59.5f; // within 50 + 10
	CHECK(footing_check(far_off, 3, 3, b, 10.0f, body) == FootCheck::Ok);
	Footing high = start;
	high.pos[1] = 2.0f * kHeight + 0.5f;
	CHECK(footing_check(high, 3, 3, b, 10.0f, body) == FootCheck::OffGround);
	high.pos[1] = -(2.0f * kHeight - 0.5f); // a cellar: within 2 x kHeight
	CHECK(footing_check(high, 3, 3, b, 10.0f, body) == FootCheck::Ok);
	// 3D would refuse this one (horizontal 59 m, 15 m down: 60.9 m), the ground rule takes it
	Footing slope = start;
	slope.pos[0] = 70.0f + 59.0f;
	slope.pos[1] = -15.0f;
	CHECK(footing_check(slope, 3, 3, b, 10.0f, body) == FootCheck::Ok);
	FootBase nan_base = b;
	nan_base.pos[0] = std::nanf("");
	CHECK(footing_check(start, 3, 3, nan_base, 10.0f, body) == FootCheck::OffGround);
	// an ordinary sleep zone also accepts a body near the reported bed
	Footing bed;
	CHECK(footing_of(zone_key(1234), bed));
	for (int i = 0; i < 3; ++i)
		bed.pos[i] = start.pos[i];
	bed.gv = 9;
	CHECK(footing_check(bed, 3, 3, b, 10.0f, body) == FootCheck::Ok);
	// Build 57 round 3 (lead's ruling on review S5): the body of the same report must stand on the base's ground too:
	// horizontally within radius + 2 x margin (50 + 20) of the base's position, within 2 x kHeight in height
	const float edge[3] = {70.0f + 69.5f, 0.0f, 0.0f};
	CHECK(footing_check(start, 3, 3, b, 10.0f, edge) == FootCheck::Ok);
	const float beyond[3] = {70.0f + 70.5f, 0.0f, 0.0f};
	CHECK(footing_check(start, 3, 3, b, 10.0f, beyond) == FootCheck::BodyOff);
	const float diagonal[3] = {70.0f + 50.0f, 0.0f, 50.0f}; // 70.7 m: beyond
	CHECK(footing_check(start, 3, 3, b, 10.0f, diagonal) == FootCheck::BodyOff);
	const float above[3] = {80.0f, 2.0f * kHeight + 0.5f, 0.0f};
	CHECK(footing_check(start, 3, 3, b, 10.0f, above) == FootCheck::BodyOff);
	const float cellar[3] = {80.0f, -(2.0f * kHeight - 0.5f), 0.0f};
	CHECK(footing_check(start, 3, 3, b, 10.0f, cellar) == FootCheck::Ok);
	const float nan_body[3] = {std::nanf(""), 0.0f, 0.0f};
	CHECK(footing_check(start, 3, 3, b, 10.0f, nan_body) == FootCheck::BodyOff);
	CHECK(footing_check(start, 3, 3, b, 10.0f, nullptr) == FootCheck::BodyOff);
	// a stale base of a map server: the footing names the Bar's bed, the body stands at the other end of the level
	const float elsewhere[3] = {900.0f, 0.0f, -400.0f};
	CHECK(footing_check(start, 3, 3, b, 10.0f, elsewhere) == FootCheck::BodyOff);
	// the footing's own refusals come first
	CHECK(footing_check(far_off, 3, 3, unknown, 10.0f, elsewhere) == FootCheck::NoBase);
	far_off.pos[0] = 70.0f + 60.5f;
	CHECK(footing_check(far_off, 3, 3, b, 10.0f, elsewhere) == FootCheck::OffGround);
	// "none" needs no body
	CHECK(footing_check(Footing(), 3, 3, b, 10.0f, nullptr) == FootCheck::None);
	// every refusal has a name for the log
	for (FootCheck c : {FootCheck::Ok, FootCheck::None, FootCheck::NotSound, FootCheck::VertexOff, FootCheck::NoBase,
	         FootCheck::OtherLevel, FootCheck::OffGround, FootCheck::BodyOff})
		CHECK(foot_check_name(c) != nullptr && *foot_check_name(c) != 0);
}

TEST(cp_base_footing_check_offset_zone_bed)
{
	Footing foot;
	REQUIRE(footing_of(zone_key(1234), foot));
	foot.pos[0] = 170.0f;
	foot.pos[1] = 5.0f;
	foot.gv = 77;

	FootBase zone;
	zone.known = true;
	zone.level = 3;
	zone.pos[0] = 100.0f;
	zone.pos[1] = 5.0f;
	zone.radius = 50.0f;

	CHECK_EQ(footing_check(foot, 3, 3, zone, 10.0f, foot.pos), FootCheck::Ok);
	const float outside[3] = {99.0f, 5.0f, 0.0f}; // 71 m from the bed, past radius + 2 x leave margin
	CHECK_EQ(footing_check(foot, 3, 3, zone, 10.0f, outside), FootCheck::BodyOff);
	CHECK_EQ(footing_check(foot, 3, 4, zone, 10.0f, foot.pos), FootCheck::VertexOff);
	zone.known = false;
	CHECK_EQ(footing_check(foot, 3, 3, zone, 10.0f, foot.pos), FootCheck::NoBase);
}

// Build 57 round 2 (lead's ruling on review S1): what the world server keeps of a map server's body report is usable only
// while it is fresh and came from the level the player is on now; a footing whose game vertex is not on the level of his
// entity is no base.
TEST(cp_base_stored_footing)
{
	CHECK(facts_current(3, 3, 1000, 1000, 5000));
	CHECK(facts_current(3, 3, 1000, 6000, 5000));
	CHECK(!facts_current(3, 3, 1000, 6001, 5000)); // stale
	CHECK(!facts_current(3, 4, 1000, 1000, 5000)); // he is on another level now
	CHECK(!facts_current(kNoLevel, kNoLevel, 1000, 1000, 5000)); // no level known
	CHECK(!facts_current(3, 3, 2000, 1000, 5000)); // the clock went back: not trusted
	CHECK(footing_on_level(3, 3));
	CHECK(!footing_on_level(3, 4));
	CHECK(!footing_on_level(kNoLevel, kNoLevel));
}

// Build 57 round 2 (lead's ruling on review S5): the far path's decision (the world server, a player on a map server's level)
// fed a sequence of footings: a friendly base, a hostile one, none, a stale one after a level change.
TEST(cp_base_far_sequence)
{
	Footing friendly;
	CHECK(footing_of(Key(1234), friendly));
	Footing hostile_one;
	CHECK(footing_of(start_key(1), hostile_one));
	Visit v;
	const uint32_t dwell = 3000;
	uint64_t t = 10000;
	// a friendly base: on it, its record after the dwell, once
	CHECK(far_step(v, friendly, true, false, false, false, t, dwell) == Step::OnBase);
	CHECK(far_step(v, friendly, true, false, false, false, t + 2999, dwell) == Step::OnBase);
	CHECK(far_step(v, friendly, true, false, false, false, t + 3000, dwell) == Step::SetBed);
	CHECK(far_step(v, friendly, true, false, true, false, t + 3500, dwell) == Step::OnBase); // settled now
	// a hostile base: no base for him (its campfires work)
	CHECK(far_step(v, hostile_one, true, true, false, false, t + 4000, dwell) == Step::Outside);
	CHECK(v.base == kNoBase);
	// none
	CHECK(far_step(v, Footing(), true, false, false, false, t + 4500, dwell) == Step::Outside);
	// back on the friendly base: a new visit
	CHECK(far_step(v, friendly, true, false, false, false, t + 5000, dwell) == Step::OnBase);
	// a stale footing after a level change (the facts are of the level he left): no base, the visit ends
	CHECK(far_step(v, friendly, false, false, false, false, t + 6000, dwell) == Step::Outside);
	CHECK(far_step(v, friendly, false, false, false, false, t + 9000, dwell) == Step::Outside);
	CHECK(v.base == kNoBase);
	// a fight on the base restarts the count
	Visit f;
	CHECK(far_step(f, friendly, true, false, false, false, t, dwell) == Step::OnBase);
	CHECK(far_step(f, friendly, true, false, false, true, t + 2000, dwell) == Step::OnBase);
	CHECK(far_step(f, friendly, true, false, false, false, t + 4999, dwell) == Step::OnBase);
	CHECK(far_step(f, friendly, true, false, false, false, t + 5000, dwell) == Step::SetBed);
	// a footing that is not sound names no base
	Footing bad = friendly;
	bad.kind = 9;
	Visit b;
	CHECK(far_step(b, bad, true, false, false, false, t, dwell) == Step::Outside);
}

// Build 57 round 2 (lead's ruling on review S4): the record of the base could not be written: the visit counts again from now.
TEST(cp_base_retry_after_failed_write)
{
	Visit v;
	const Key k = Key(55);
	CHECK(step(v, k, false, false, 1000, 3000) == Step::OnBase);
	CHECK(step(v, k, false, false, 4000, 3000) == Step::SetBed);
	retry_visit(v, 4000); // host_set refused, or no record could be made
	CHECK(!v.fired && v.since == 4000 && v.base == k);
	CHECK(step(v, k, false, false, 6999, 3000) == Step::OnBase);
	CHECK(step(v, k, false, false, 7000, 3000) == Step::SetBed);
	// without the retry the visit is spent
	CHECK(step(v, k, false, false, 20000, 3000) == Step::OnBase);
}

// Build 57 round 3 (lead's ruling on review S3): an arrival onto a base. The base's record takes the place of an Arrival record
// of its level that lies on its ground; prev (the record before the arrival) is kept. Anything else is set() as before.
TEST(cp_base_arrival_onto_base)
{
	const Spot zone = spot(Key(300), 0.0f, 0.0f, 50.0f, "l01_escape");
	const Record bed = make(Kind::Rest, 300, "l01_escape", 0.0f);
	const Record tent = make(Kind::Tent, 77, "l01_escape", 400.0f);
	const Record arrival = make(Kind::Arrival, kNoSource, "l01_escape", 20.0f, 0.0f, 15.0f);
	{
		// his tent, then the arrival on the base (a level change), then the base 3 s later
		Slot s;
		CHECK(set(s, tent) == SetOutcome::New);
		CHECK(set(s, arrival) == SetOutcome::New);
		CHECK(s.cur.kind == Kind::Arrival && s.prev.kind == Kind::Tent);
		CHECK(set_on_base(s, bed, zone) == SetOutcome::Moved); // written and announced once, nothing pushed down
		CHECK(s.cur.kind == Kind::Rest && s.cur.source == 300);
		CHECK(s.prev.kind == Kind::Tent && s.prev.source == 77); // the older record is not lost
		CHECK(changes_slot(SetOutcome::Moved));
		// the base again: the same place
		CHECK(set_on_base(s, bed, zone) == SetOutcome::Same);
		CHECK(s.prev.kind == Kind::Tent);
	}
	{
		// what set() alone did (the review's case): prev = the worthless arrival, the tent lost
		Slot s;
		set(s, tent);
		set(s, arrival);
		CHECK(set(s, bed) == SetOutcome::New);
		CHECK(s.prev.kind == Kind::Arrival);
	}
	{
		// an arrival off the base's ground (60 m away): the base pushes it down as before
		Slot s;
		set(s, tent);
		set(s, make(Kind::Arrival, kNoSource, "l01_escape", 60.0f));
		CHECK(set_on_base(s, bed, zone) == SetOutcome::New);
		CHECK(s.prev.kind == Kind::Arrival);
		// above the ground (more than kHeight): off it
		Slot h;
		set(h, tent);
		set(h, make(Kind::Arrival, kNoSource, "l01_escape", 5.0f, kHeight + 1.0f));
		CHECK(set_on_base(h, bed, zone) == SetOutcome::New);
		// an arrival of another level
		Slot o;
		set(o, tent);
		set(o, make(Kind::Arrival, kNoSource, "l02_garbage", 0.0f));
		CHECK(set_on_base(o, bed, zone) == SetOutcome::New);
		CHECK(o.prev.level == "l02_garbage");
	}
	{
		// not an arrival: a campfire on the ground (a hostile base's, or one lit before the base was his) is pushed down
		Slot s;
		set(s, make(Kind::Campfire, 5, "l01_escape", 10.0f));
		CHECK(set_on_base(s, bed, zone) == SetOutcome::New);
		CHECK(s.prev.kind == Kind::Campfire);
		// a story record on the ground the same
		Slot t;
		set(t, make(Kind::Story, kNoSource, "l01_escape", 10.0f));
		CHECK(set_on_base(t, bed, zone) == SetOutcome::New);
	}
	{
		// not this base's record: set() as before
		Slot s;
		set(s, tent);
		set(s, arrival);
		CHECK(set_on_base(s, make(Kind::Rest, 301, "l01_escape", 0.0f), zone) == SetOutcome::New);
		CHECK(s.prev.kind == Kind::Arrival);
		// an invalid record is ignored
		Slot i;
		set(i, arrival);
		CHECK(set_on_base(i, Record(), zone) == SetOutcome::Ignored);
		CHECK(i.cur.kind == Kind::Arrival);
	}
	{
		// a start base: its record has no object, its ground is the start point's
		const Spot start_base = spot(start_key(2), 500.0f, 0.0f, 50.0f, "l01_escape");
		const Record point = make(Kind::Rest, kNoSource, "l01_escape", 500.0f);
		Slot s;
		set(s, tent);
		set(s, make(Kind::Arrival, kNoSource, "l01_escape", 530.0f));
		CHECK(set_on_base(s, point, start_base) == SetOutcome::Moved);
		CHECK(s.cur.kind == Kind::Rest && s.cur.source == kNoSource && s.prev.kind == Kind::Tent);
		// a new game that starts on the base: an arrival and nothing before it
		Slot n;
		set(n, make(Kind::Arrival, kNoSource, "l01_escape", 505.0f));
		CHECK(set_on_base(n, point, start_base) == SetOutcome::Moved);
		CHECK(n.cur.kind == Kind::Rest && !n.prev.valid());
	}
}

// Build 57 round 3 (lead's ruling on review S6): what a record is for the text its player reads, as the engine tells the Lua.
TEST(cp_base_mark)
{
	CHECK(mark_of(make(Kind::Rest, 300), 1, false) == Mark::Bed);
	CHECK(mark_of(make(Kind::Rest, 300), 0, false) == Mark::None); // a rest zone of no base, a surge cover
	CHECK(mark_of(make(Kind::Rest, 300), -1, false) == Mark::Unknown); // its object is not known on this machine
	CHECK(mark_of(make(Kind::Rest, kNoSource), -1, true) == Mark::Base);
	CHECK(mark_of(make(Kind::Rest, kNoSource), 1, false) == Mark::None); // no start base there (the debug "checkpoint here")
	CHECK(mark_of(make(Kind::Campfire, 300), 1, true) == Mark::None); // only rest records are told apart
	CHECK(mark_of(make(Kind::Arrival, kNoSource), 1, true) == Mark::None);
	CHECK(mark_of(Record(), 1, true) == Mark::None);
	CHECK_EQ(std::string(mark_name(Mark::Bed)), std::string("bed"));
	CHECK_EQ(std::string(mark_name(Mark::Base)), std::string("base"));
	CHECK_EQ(std::string(mark_name(Mark::None)), std::string("none"));
	CHECK(mark_name(Mark::Unknown) == nullptr);
}

// Round 3 review S1 (lead 2026-11-18): the hostile base's record was dropped at respawn, and the fallback points (his anchor,
// the host's arrival, his body) may lie on that same base: a point on its ground (with the leave margin) is not used.
TEST(cp_base_respawn_fallback_off_the_hostile_ground)
{
	Spot g;
	g.id = zone_key(77);
	g.bed = 77;
	g.level = "l01_escape";
	g.pos[0] = 0.f;
	g.pos[1] = 0.f;
	g.pos[2] = 0.f;
	g.radius = 50.f;
	const float on_base[3] = {20.f, 1.f, 10.f};
	const float at_edge[3] = {55.f, 0.f, 0.f}; // inside the leave margin: still the base for a player who was on it
	const float away[3] = {200.f, 0.f, 0.f};
	CHECK(!fallback_ok(&g, "l01_escape", on_base));
	CHECK(!fallback_ok(&g, "l01_escape", at_edge));
	CHECK(fallback_ok(&g, "l01_escape", away));
	CHECK(fallback_ok(&g, "k00_marsh", on_base)); // another level: not this base
	CHECK(fallback_ok(nullptr, "l01_escape", on_base)); // nothing was dropped
	CHECK(!fallback_ok(&g, "l01_escape", nullptr)); // no point: nothing to use
}
