// Anomaly Coop unit tests: the pure part of the checkpoint sources on the host (coop_checkpoint_source_rules.h; F3
// Task 7, CHECKPOINTS_DEATH.md §2.2): the settings and their bounds, the CheckpointClaim message, the nearest source,
// the objects mods declare as camps and the book of tents and claims.
#include "test_util.h"

#include "coop_checkpoint_source_rules.h"

#include <limits>

using namespace coop;
using namespace coop::checkpoint;

namespace
{
TentSeen tent(uint16_t id, float x, float z = 0.0f)
{
	TentSeen t;
	t.id = id;
	t.pos[0] = x;
	t.pos[1] = 0.0f;
	t.pos[2] = z;
	return t;
}

SourceSpot spot(uint16_t id, Kind kind, float x, float radius)
{
	SourceSpot s;
	s.id = id;
	s.kind = kind;
	s.pos[0] = x;
	s.pos[1] = 0.0f;
	s.pos[2] = 0.0f;
	s.radius = radius;
	return s;
}

const float kAt0[3] = {0.0f, 0.0f, 0.0f};

bool claim_read(const Writer& w, float out[3])
{
	Reader rd(w.ptr(), w.size());
	return read_claim(rd, out);
}

bool has(const std::vector<uint16_t>& v, uint16_t id)
{
	for (uint16_t x : v)
		if (x == id)
			return true;
	return false;
}
} // namespace

// ---------------------------------------------------------------- settings

TEST(cpsrc_settings_defaults)
{
	// the numbers of the plan (F3 Task 7 step 1), used for a line the ltx does not have
	const SourceSettings s;
	CHECK_EQ(s.campfire_radius, 3.0f);
	CHECK_EQ(s.campfire_dwell_ms, 5000u);
	CHECK_EQ(s.combat_radius, 50.0f);
	REQUIRE(s.tent_sections.size() == 2);
	CHECK_EQ(s.tent_sections[0], std::string("ph_tent"));
	CHECK_EQ(s.tent_sections[1], std::string("ph_sleepbag"));
	CHECK_EQ(s.tent_rest_radius, 2.0f);
	CHECK_EQ(s.tent_claim_radius, 4.0f);
	CHECK_EQ(s.tent_claim_ms, 15000u);
	CHECK_EQ(s.cover_list, std::string("misc\\surge_manager.ltx"));
}

TEST(cpsrc_bounds)
{
	CHECK(radius_ok(3.0f));
	CHECK(radius_ok(kMaxSourceRadius));
	CHECK(!radius_ok(0.0f));
	CHECK(!radius_ok(-1.0f));
	CHECK(!radius_ok(kMaxSourceRadius + 1.0f));
	CHECK(!radius_ok(std::numeric_limits<float>::quiet_NaN()));
	CHECK(!radius_ok(std::numeric_limits<float>::infinity()));
	CHECK(period_ok(0.0));
	CHECK(period_ok(15000.0));
	CHECK(!period_ok(double(kMaxSourcePeriodMs) + 1.0));
	CHECK(!period_ok(-1.0));
	CHECK(!period_ok(std::numeric_limits<double>::quiet_NaN()));
}

TEST(cpsrc_split_names)
{
	const std::vector<std::string> two = split_names("ph_tent, ph_sleepbag");
	REQUIRE(two.size() == 2);
	CHECK_EQ(two[0], std::string("ph_tent"));
	CHECK_EQ(two[1], std::string("ph_sleepbag"));

	// blanks trimmed, empty items, repeats and malformed names skipped, order kept
	const std::vector<std::string> v = split_names("  b_1 ,, a ,b_1,ph tent, x|y ,\tc\t");
	REQUIRE(v.size() == 3);
	CHECK_EQ(v[0], std::string("b_1"));
	CHECK_EQ(v[1], std::string("a"));
	CHECK_EQ(v[2], std::string("c"));

	CHECK(split_names("").empty());
	CHECK(split_names(std::string(65, 'a')).empty()); // longer than a section name may be
	CHECK_EQ(split_names(std::string(64, 'a')).size(), size_t(1));

	std::string many;
	for (int i = 0; i < 20; ++i)
		many += "s" + std::to_string(i) + ",";
	const std::vector<std::string> cut = split_names(many);
	CHECK_EQ(cut.size(), kMaxTentSections);
	CHECK_EQ(cut.back(), std::string("s15"));
	CHECK_EQ(split_names(many, 3).size(), size_t(3));
}

// ---------------------------------------------------------------- CheckpointClaim

TEST(cpsrc_claim_roundtrip)
{
	const float p[3] = {12.5f, -3.25f, 1000.0f};
	Writer w;
	write_claim(w, p);
	CHECK_EQ(w.size(), size_t(1 + 12));
	float out[3] = {0, 0, 0};
	REQUIRE(claim_read(w, out));
	CHECK_EQ(out[0], 12.5f);
	CHECK_EQ(out[1], -3.25f);
	CHECK_EQ(out[2], 1000.0f);
}

TEST(cpsrc_claim_malformed)
{
	const float good[3] = {1.0f, 2.0f, 3.0f};
	float out[3] = {7.0f, 7.0f, 7.0f};

	Writer what2; // not a tent
	what2.u8(2);
	what2.vec3(good);
	CHECK(!claim_read(what2, out));

	const float nan[3] = {1.0f, std::numeric_limits<float>::quiet_NaN(), 3.0f};
	Writer w_nan;
	write_claim(w_nan, nan);
	CHECK(!claim_read(w_nan, out));

	const float inf[3] = {std::numeric_limits<float>::infinity(), 0.0f, 0.0f};
	Writer w_inf;
	write_claim(w_inf, inf);
	CHECK(!claim_read(w_inf, out));

	const float far[3] = {0.0f, 0.0f, kMaxCoord * 2.0f};
	Writer w_far;
	write_claim(w_far, far);
	CHECK(!claim_read(w_far, out));

	Writer w_tail; // a byte after the position
	write_claim(w_tail, good);
	w_tail.u8(0);
	CHECK(!claim_read(w_tail, out));

	Writer w_short; // what only
	w_short.u8(kClaimTent);
	CHECK(!claim_read(w_short, out));

	CHECK_EQ(out[0], 7.0f); // untouched on every failure
	CHECK_EQ(out[1], 7.0f);
	CHECK_EQ(out[2], 7.0f);
}

// ---------------------------------------------------------------- nearest source

TEST(cpsrc_nearest_spot)
{
	std::vector<SourceSpot> spots;
	CHECK(nearest_spot(spots, kAt0) == nullptr);

	spots.push_back(spot(10, Kind::Campfire, 2.5f, 3.0f)); // reaches
	spots.push_back(spot(11, Kind::Campfire, 3.5f, 3.0f)); // too far for its radius
	spots.push_back(spot(12, Kind::Mod, 6.0f, 10.0f)); // far, but its own radius reaches
	const SourceSpot* s = nearest_spot(spots, kAt0);
	REQUIRE(s != nullptr);
	CHECK_EQ(s->id, uint16_t(10));

	spots[0].pos[0] = 9.0f; // now out of its 3 m
	s = nearest_spot(spots, kAt0);
	REQUIRE(s != nullptr);
	CHECK_EQ(s->id, uint16_t(12));
	CHECK(s->kind == Kind::Mod);

	// a tie goes to the lower id, whatever the order
	std::vector<SourceSpot> tie{spot(30, Kind::Campfire, -1.0f, 3.0f), spot(20, Kind::Campfire, 1.0f, 3.0f)};
	s = nearest_spot(tie, kAt0);
	REQUIRE(s != nullptr);
	CHECK_EQ(s->id, uint16_t(20));

	// the edge of the radius counts, a spot without a usable radius never does
	std::vector<SourceSpot> edge{spot(40, Kind::Campfire, 3.0f, 3.0f), spot(41, Kind::Mod, 0.0f, 0.0f)};
	s = nearest_spot(edge, kAt0);
	REQUIRE(s != nullptr);
	CHECK_EQ(s->id, uint16_t(40));

	const float nan_at[3] = {std::numeric_limits<float>::quiet_NaN(), 0.0f, 0.0f};
	CHECK(nearest_spot(edge, nan_at) == nullptr);
}

// ---------------------------------------------------------------- mod sources

TEST(cpsrc_mod_sources)
{
	ModSources m;
	CHECK(m.add(100, 4.0f));
	CHECK(m.has(100));
	CHECK(!m.add(0xffff, 4.0f));
	CHECK(!m.add(101, 0.0f));
	CHECK(!m.add(101, std::numeric_limits<float>::quiet_NaN()));
	CHECK(!m.add(101, kMaxSourceRadius * 2.0f));
	CHECK(!m.has(101));
	CHECK(m.add(100, 6.0f)); // a known id takes the new radius
	REQUIRE(m.all().count(100) == 1);
	CHECK_EQ(m.all().at(100), 6.0f);

	for (uint16_t id = 1000; m.all().size() < kMaxModSources; ++id)
		REQUIRE(m.add(id, 3.0f));
	CHECK(!m.add(5000, 3.0f)); // over the bound
	CHECK(m.add(100, 2.0f)); // a known one still changes
	CHECK(m.remove(100));
	CHECK(!m.remove(100));
	CHECK(m.add(5000, 3.0f)); // room again
}

// ---------------------------------------------------------------- tents and claims

TEST(cpsrc_tents_of_the_served_world_are_old)
{
	TentBook b;
	b.new_world();
	CHECK(b.observe({tent(1, 0.0f)}, 1000)); // stood when the world was served
	CHECK(b.observe({tent(1, 0.0f), tent(2, 10.0f)}, 2000)); // put up since
	CHECK_EQ(b.tents(), size_t(2));

	const float at1[3] = {1.0f, 0.0f, 0.0f};
	CHECK(b.claim(0, at1, 2500, 15000));
	CHECK(b.match({tent(1, 0.0f), tent(2, 10.0f)}, 4.0f, 15000).empty()); // the old one is nobody's new tent
	CHECK(b.has_claim(0));

	const float at2[3] = {9.0f, 0.0f, 0.0f};
	CHECK(b.claim(0, at2, 2600, 15000)); // replaces his first claim
	CHECK_EQ(b.claims(), size_t(1));
	const std::vector<TentMatch> m = b.match({tent(1, 0.0f), tent(2, 10.0f)}, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].character, uint16_t(0));
	CHECK_EQ(m[0].tent, uint16_t(2));
	CHECK_EQ(b.owner_of(2), uint16_t(0));
	CHECK(!b.has_claim(0));
	CHECK_EQ(b.owner_of(1), uint16_t(0xffff));
}

TEST(cpsrc_claim_takes_the_nearest_tent_nobody_owns)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	const std::vector<TentSeen> seen{tent(5, 1.0f), tent(6, 2.0f), tent(7, 3.5f), tent(8, 30.0f)};
	b.observe(seen, 1000);
	CHECK(b.set_owner(5, 9)); // somebody's already
	CHECK(b.claim(3, kAt0, 1200, 15000));
	const std::vector<TentMatch> m = b.match(seen, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].character, uint16_t(3));
	CHECK_EQ(m[0].tent, uint16_t(6)); // 5 is owned, 6 is nearer than 7, 8 is out of reach
	CHECK_EQ(b.owner_of(5), uint16_t(9));
	CHECK_EQ(b.owned_by(3), size_t(1));
	CHECK_EQ(b.owned_by(9), size_t(1));
}

TEST(cpsrc_claim_fresh_window)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	b.observe({tent(1, 0.0f)}, 1000); // appeared at 1 s

	CHECK(b.claim(2, kAt0, 17000, 15000)); // 16 s later: not the tent of this claim
	CHECK(b.match({tent(1, 0.0f)}, 4.0f, 15000).empty());
	CHECK(b.claim(2, kAt0, 16000, 15000)); // exactly 15 s later: still it
	CHECK_EQ(b.match({tent(1, 0.0f)}, 4.0f, 15000).size(), size_t(1));

	// a tent that appears after the claim answers it
	TentBook c;
	c.new_world();
	c.observe({}, 0);
	CHECK(c.claim(4, kAt0, 5000, 15000));
	c.observe({tent(3, 1.0f)}, 9000);
	const std::vector<TentMatch> m = c.match({tent(3, 1.0f)}, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].tent, uint16_t(3));

	// a tent the book has not observed is no answer
	TentBook d;
	d.new_world();
	d.observe({}, 0);
	CHECK(d.claim(4, kAt0, 5000, 15000));
	CHECK(d.match({tent(3, 1.0f)}, 4.0f, 15000).empty());
}

TEST(cpsrc_one_tent_two_claims)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	CHECK(b.claim(7, kAt0, 100, 15000));
	CHECK(b.claim(8, kAt0, 200, 15000));
	b.observe({tent(1, 0.5f)}, 300);
	const std::vector<TentMatch> m = b.match({tent(1, 0.5f)}, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].character, uint16_t(7)); // the older claim
	CHECK(b.has_claim(8)); // the other one waits for its own tent
	b.observe({tent(1, 0.5f), tent(2, -0.5f)}, 400);
	const std::vector<TentMatch> m2 = b.match({tent(1, 0.5f), tent(2, -0.5f)}, 4.0f, 15000);
	REQUIRE(m2.size() == 1);
	CHECK_EQ(m2[0].character, uint16_t(8));
	CHECK_EQ(m2[0].tent, uint16_t(2));
}

TEST(cpsrc_claim_expires)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	CHECK(b.claim(5, kAt0, 1000, 15000));
	CHECK(b.expire(15999).empty());
	const std::vector<uint16_t> gone = b.expire(16000);
	REQUIRE(gone.size() == 1);
	CHECK_EQ(gone[0], uint16_t(5));
	CHECK(!b.has_claim(5));
	b.observe({tent(1, 0.0f)}, 16500);
	CHECK(b.match({tent(1, 0.0f)}, 4.0f, 15000).empty());
}

TEST(cpsrc_claim_bound)
{
	TentBook b;
	b.new_world();
	for (uint16_t c = 1; c <= kMaxClaims; ++c)
		REQUIRE(b.claim(c, kAt0, 10, 15000));
	CHECK(!b.claim(1000, kAt0, 10, 15000)); // a new character over the bound
	CHECK(b.claim(1, kAt0, 20, 15000)); // a known one replaces his own
	CHECK_EQ(b.claims(), kMaxClaims);
}

TEST(cpsrc_claims_of_absent_players_dropped)
{
	TentBook b;
	b.new_world();
	CHECK(b.claim(0, kAt0, 10, 15000));
	CHECK(b.claim(5, kAt0, 10, 15000));
	CHECK(b.claim(6, kAt0, 10, 15000));
	const std::vector<uint16_t> dropped = b.keep_claims_of({0, 6});
	REQUIRE(dropped.size() == 1);
	CHECK_EQ(dropped[0], uint16_t(5));
	CHECK(b.has_claim(0));
	CHECK(!b.has_claim(5));
	CHECK(b.has_claim(6));
}

TEST(cpsrc_tent_forget_and_new_world)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	b.observe({tent(1, 0.0f), tent(2, 1.0f)}, 100);
	CHECK(b.set_owner(1, 4));
	CHECK(b.set_owner(77, 4)); // a tent on another level: owned, not seen here
	CHECK_EQ(b.owned_by(4), size_t(2));
	b.forget(1);
	CHECK_EQ(b.owner_of(1), uint16_t(0xffff));
	CHECK_EQ(b.tents(), size_t(1));
	const std::vector<uint16_t> k = b.known();
	CHECK(has(k, 2));
	CHECK(has(k, 77)); // owned ones are checked too
	CHECK(!has(k, 1));

	CHECK(b.claim(4, kAt0, 200, 15000));
	b.new_world();
	CHECK_EQ(b.claims(), size_t(0));
	CHECK_EQ(b.owners(), size_t(0));
	b.observe({tent(2, 1.0f), tent(3, 2.0f)}, 300); // both stood when this world was served
	CHECK(b.claim(4, kAt0, 400, 15000));
	CHECK(b.match({tent(2, 1.0f), tent(3, 2.0f)}, 4.0f, 15000).empty());
}

TEST(cpsrc_tent_bound)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	std::vector<TentSeen> many;
	for (uint16_t id = 1; id <= kMaxTents + 5; ++id)
		many.push_back(tent(id, float(id)));
	CHECK(!b.observe(many, 100)); // some not kept
	CHECK_EQ(b.tents(), kMaxTents);
	for (uint16_t id = 1; b.owners() < kMaxTents; ++id)
		REQUIRE(b.set_owner(id, 1));
	CHECK(!b.set_owner(60000, 1));
	CHECK(b.set_owner(1, 2)); // a known tent changes hands
	CHECK_EQ(b.owner_of(1), uint16_t(2));
}
