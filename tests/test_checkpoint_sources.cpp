// Anomaly Coop unit tests: the pure part of the checkpoint sources on the host (coop_checkpoint_source_rules.h; F3
// Task 7, CHECKPOINTS_DEATH.md §2.2): the settings and their bounds, the CheckpointClaim message, the nearest source,
// the objects mods declare as camps, the sections behind source ids, the mark a tent carries in its custom data, the
// item a tent is paid with and the book of tents and claims.
#include "test_util.h"

#include "coop_checkpoint_source_rules.h"

#include <limits>

using namespace coop;
using namespace coop::checkpoint;

namespace
{
const std::string kKeyA = "aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000"; // digests are 64 hex
const std::string kKeyB = "bbbb1111bbbb1111bbbb1111bbbb1111bbbb1111bbbb1111bbbb1111bbbb1111";

TentSeen tent(uint16_t id, float x, float z = 0.0f, uint8_t what = 0)
{
	TentSeen t;
	t.id = id;
	t.pos[0] = x;
	t.pos[1] = 0.0f;
	t.pos[2] = z;
	t.what = what;
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

ItemSeen item(uint16_t id, const char* section)
{
	ItemSeen i;
	i.id = id;
	i.section = section;
	return i;
}

const float kAt0[3] = {0.0f, 0.0f, 0.0f};

bool claim_read(const Writer& w, ClaimWhat& what, float out[3])
{
	Reader rd(w.ptr(), w.size());
	return read_claim(rd, what, out);
}

bool has(const std::vector<uint16_t>& v, uint16_t id)
{
	for (uint16_t x : v)
		if (x == id)
			return true;
	return false;
}

// A claim for a tent (what = Tent) of `key`.
bool claim_tent(TentBook& b, uint16_t character, const std::string& key, uint64_t now, const float* at = kAt0)
{
	return b.claim(character, key, ClaimWhat::Tent, at, now, 15000);
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
	// round 1 (Ruling F3-6, I-1): what the host puts up, and where the items it takes for it are listed
	CHECK_EQ(s.tent_section, std::string("ph_tent"));
	CHECK_EQ(s.sleepbag_section, std::string("ph_sleepbag"));
	CHECK(name_listed(s.tent_section, s.tent_sections));
	CHECK(name_listed(s.sleepbag_section, s.tent_sections));
	CHECK(!name_listed("ph_tent_x", s.tent_sections));
	CHECK_EQ(s.item_lists, std::string("items\\settings\\itms_manager.ltx"));
	CHECK(claim_period_ok(double(s.tent_claim_ms)));
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

TEST(cpsrc_claim_period_bounds)
{
	// R1 M-11: a claim that expires before the next scan never finds its tent
	CHECK(!claim_period_ok(0.0));
	CHECK(!claim_period_ok(double(kMinClaimMs) - 1.0));
	CHECK(claim_period_ok(double(kMinClaimMs)));
	CHECK(claim_period_ok(15000.0));
	CHECK(claim_period_ok(double(kMaxSourcePeriodMs)));
	CHECK(!claim_period_ok(double(kMaxSourcePeriodMs) + 1.0));
	CHECK(!claim_period_ok(15000.5));
	CHECK(!claim_period_ok(std::numeric_limits<double>::quiet_NaN()));
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
	for (const ClaimWhat w : {ClaimWhat::Tent, ClaimWhat::Sleepbag, ClaimWhat::Pack})
	{
		Writer wr;
		write_claim(wr, w, p);
		CHECK_EQ(wr.size(), size_t(1 + 12));
		ClaimWhat what = ClaimWhat::Tent;
		float out[3] = {0, 0, 0};
		REQUIRE(claim_read(wr, what, out));
		CHECK(what == w);
		CHECK_EQ(out[0], 12.5f);
		CHECK_EQ(out[1], -3.25f);
		CHECK_EQ(out[2], 1000.0f);
	}
}

TEST(cpsrc_claim_malformed)
{
	const float good[3] = {1.0f, 2.0f, 3.0f};
	float out[3] = {7.0f, 7.0f, 7.0f};
	ClaimWhat what = ClaimWhat::Sleepbag;

	for (const uint8_t w : {uint8_t(0), uint8_t(4), uint8_t(255)}) // not one of ClaimWhat (F3-6: 1, 2, 3 only)
	{
		Writer bad;
		bad.u8(w);
		bad.vec3(good);
		CHECK(!claim_read(bad, what, out));
	}

	const float nan[3] = {1.0f, std::numeric_limits<float>::quiet_NaN(), 3.0f};
	Writer w_nan;
	write_claim(w_nan, ClaimWhat::Tent, nan);
	CHECK(!claim_read(w_nan, what, out));

	const float inf[3] = {std::numeric_limits<float>::infinity(), 0.0f, 0.0f};
	Writer w_inf;
	write_claim(w_inf, ClaimWhat::Tent, inf);
	CHECK(!claim_read(w_inf, what, out));

	const float far[3] = {0.0f, 0.0f, kMaxCoord * 2.0f};
	Writer w_far;
	write_claim(w_far, ClaimWhat::Tent, far);
	CHECK(!claim_read(w_far, what, out));

	Writer w_tail; // a byte after the position
	write_claim(w_tail, ClaimWhat::Tent, good);
	w_tail.u8(0);
	CHECK(!claim_read(w_tail, what, out));

	Writer w_short; // what only
	w_short.u8(uint8_t(ClaimWhat::Tent));
	CHECK(!claim_read(w_short, what, out));

	CHECK_EQ(out[0], 7.0f); // untouched on every failure
	CHECK_EQ(out[1], 7.0f);
	CHECK_EQ(out[2], 7.0f);
	CHECK(what == ClaimWhat::Sleepbag);
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
	CHECK(m.add(100, 4.0f, "campfire_mod"));
	CHECK(m.has(100));
	CHECK(!m.add(0xffff, 4.0f, "x"));
	CHECK(!m.add(101, 0.0f, "x"));
	CHECK(!m.add(101, std::numeric_limits<float>::quiet_NaN(), "x"));
	CHECK(!m.add(101, kMaxSourceRadius * 2.0f, "x"));
	CHECK(!m.has(101));
	CHECK(m.add(100, 6.0f, "campfire_mod2")); // a known id takes the new radius and section
	REQUIRE(m.all().count(100) == 1);
	CHECK_EQ(m.all().at(100).radius, 6.0f);
	CHECK_EQ(m.all().at(100).section, std::string("campfire_mod2"));

	for (size_t i = 0; i + 1 < kMaxModSources; ++i) // 100 is in already
		REQUIRE(m.add(uint16_t(1000 + i), 3.0f, "s"));
	REQUIRE(m.all().size() == kMaxModSources);
	CHECK(!m.add(5000, 3.0f, "s")); // over the bound
	CHECK(m.add(100, 2.0f, "s")); // a known one still changes
	CHECK(m.remove(100));
	CHECK(!m.remove(100));
	CHECK(m.add(5000, 3.0f, "s")); // room again
}

// ---------------------------------------------------------------- the sections behind ids (R1 M-4)

TEST(cpsrc_source_sections)
{
	SourceSections s;
	CHECK(s.same(10, "campfire")); // first met: remembered
	CHECK(s.same(10, "campfire"));
	CHECK(!s.same(10, "wpn_ak74")); // the id names another object now
	CHECK(s.same(11, "ph_tent"));
	CHECK_EQ(s.size(), size_t(2));
	s.retain({11});
	CHECK_EQ(s.size(), size_t(1));
	CHECK(s.same(10, "wpn_ak74")); // forgotten, met anew
	s.forget(11);
	CHECK(s.same(11, "anything"));

	SourceSections full;
	for (uint16_t id = 0; id < kMaxRememberedSources; ++id)
		REQUIRE(full.same(id, "a"));
	REQUIRE(full.size() == kMaxRememberedSources);
	CHECK(full.same(60000, "a")); // over the bound: not remembered, taken as the same
	CHECK(full.same(60000, "b"));
	CHECK_EQ(full.size(), kMaxRememberedSources);
}

// ---------------------------------------------------------------- the mark of a tent (R1 I-2)

TEST(cpsrc_owner_keys)
{
	CHECK(owner_key_ok(kKeyA));
	CHECK(owner_key_ok(kHostOwner));
	CHECK(owner_key_ok("#123"));
	CHECK(!owner_key_ok(""));
	CHECK(!owner_key_ok("a b"));
	CHECK(!owner_key_ok("a=b"));
	CHECK(!owner_key_ok("a\nb"));
	CHECK(!owner_key_ok(std::string(kMaxOwnerKey + 1, 'a')));
	CHECK(owner_key_ok(std::string(kMaxOwnerKey, 'a')));
}

TEST(cpsrc_tent_mark_roundtrip_keeps_other_lines)
{
	// the stock ph_tent custom data (scripts\ph_tent.ltx) stays as it is
	std::string text = "[logic]\r\ncfg = scripts\\ph_tent.ltx\r\n";
	TentMark m;
	m.owner = kKeyA;
	m.item = "itm_tent";
	tent_mark_to_ini(text, m);
	CHECK(text.find("[logic]") == 0);
	CHECK(text.find("cfg = scripts\\ph_tent.ltx") != std::string::npos);
	TentMark back;
	REQUIRE(tent_mark_from_ini(text, back));
	CHECK_EQ(back.owner, kKeyA);
	CHECK_EQ(back.item, std::string("itm_tent"));

	// the host's own tent: no item to give back
	TentMark host;
	host.owner = kHostOwner;
	tent_mark_to_ini(text, host);
	TentMark h;
	REQUIRE(tent_mark_from_ini(text, h));
	CHECK_EQ(h.owner, std::string(kHostOwner));
	CHECK(h.item.empty());

	// nobody's
	TentMark none;
	CHECK(!tent_mark_from_ini("[logic]\r\n", none));
	CHECK(!tent_mark_from_ini("", none));
}

TEST(cpsrc_tent_mark_rejects)
{
	std::string text;
	TentMark bad;
	bad.owner = "a b"; // not a key: nothing written
	bad.item = "itm_tent";
	tent_mark_to_ini(text, bad);
	CHECK(text.empty());

	TentMark out;
	CHECK(!tent_mark_from_ini("[coop_tent]\nowner = a b c\nitm = x\n", out)); // a malformed owner is no owner
	REQUIRE(tent_mark_from_ini("[coop_tent]\nowner = host\nitem = itm tent\n", out)); // a malformed item is none
	CHECK_EQ(out.owner, std::string("host"));
	CHECK(out.item.empty());
}

// ---------------------------------------------------------------- the item a tent is paid with (R1 I-1)

TEST(cpsrc_pick_item)
{
	const std::vector<std::string> tents{"itm_tent", "tent_bag"};
	CHECK_EQ(pick_item({}, tents), kNoSource);
	CHECK_EQ(pick_item({item(5, "itm_sleepbag"), item(6, "wpn_ak74")}, tents), kNoSource);
	CHECK_EQ(pick_item({item(9, "tent_bag"), item(3, "wpn_ak74"), item(7, "itm_tent")}, tents), uint16_t(7));
	CHECK_EQ(pick_item({item(9, "tent_bag"), item(2, "itm_tent_bag")}, tents), uint16_t(9)); // the bag is no tent
	CHECK_EQ(pick_item({item(4, "itm_tent")}, {}), kNoSource);
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
	CHECK(claim_tent(b, 0, kHostOwner, 2500, at1));
	CHECK(b.match({tent(1, 0.0f), tent(2, 10.0f)}, 4.0f, 15000).empty()); // the old one is nobody's new tent
	CHECK(b.has_claim(0));

	const float at2[3] = {9.0f, 0.0f, 0.0f};
	CHECK(claim_tent(b, 0, kHostOwner, 2600, at2)); // replaces his first claim
	CHECK_EQ(b.claims(), size_t(1));
	const std::vector<TentMatch> m = b.match({tent(1, 0.0f), tent(2, 10.0f)}, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].character, uint16_t(0));
	CHECK_EQ(m[0].tent, uint16_t(2));
	CHECK(m[0].what == ClaimWhat::Tent);
	CHECK_EQ(b.owner_of(2), std::string(kHostOwner));
	CHECK(!b.has_claim(0));
	CHECK(b.owner_of(1).empty());
}

TEST(cpsrc_claim_takes_the_nearest_tent_nobody_owns)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	const std::vector<TentSeen> seen{tent(5, 1.0f), tent(6, 2.0f), tent(7, 3.5f), tent(8, 30.0f)};
	b.observe(seen, 1000);
	CHECK(b.set_owner(5, kKeyB)); // somebody's already
	CHECK(claim_tent(b, 3, kKeyA, 1200));
	const std::vector<TentMatch> m = b.match(seen, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].character, uint16_t(3));
	CHECK_EQ(m[0].tent, uint16_t(6)); // 5 is owned, 6 is nearer than 7, 8 is out of reach
	CHECK_EQ(b.owner_of(5), kKeyB);
	CHECK_EQ(b.owner_of(6), kKeyA); // the claimant's key, not his id
	CHECK_EQ(b.owned_by(kKeyA), size_t(1));
	CHECK_EQ(b.owned_by(kKeyB), size_t(1));
}

TEST(cpsrc_claim_takes_its_own_kind)
{
	// R1 F3-6: a sleeping bag is no answer to a tent claim, and the other way round; another tent section answers both
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	const std::vector<TentSeen> seen{tent(1, 0.5f, 0.0f, uint8_t(ClaimWhat::Sleepbag)),
		tent(2, 1.5f, 0.0f, uint8_t(ClaimWhat::Tent))};
	b.observe(seen, 100);
	CHECK(b.claim(4, kKeyA, ClaimWhat::Tent, kAt0, 200, 15000));
	std::vector<TentMatch> m = b.match(seen, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].tent, uint16_t(2)); // the nearer one is a sleeping bag

	CHECK(b.claim(5, kKeyB, ClaimWhat::Sleepbag, kAt0, 300, 15000));
	m = b.match(seen, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].tent, uint16_t(1));
	CHECK(m[0].what == ClaimWhat::Sleepbag);

	const std::vector<TentSeen> other{tent(3, 0.5f)}; // a mod's tent section: either kind
	b.observe(other, 400);
	CHECK(b.claim(6, kKeyB, ClaimWhat::Sleepbag, kAt0, 500, 15000));
	m = b.match(other, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].tent, uint16_t(3));

	CHECK(!b.claim(7, kKeyA, ClaimWhat::Pack, kAt0, 600, 15000)); // packing never waits for a tent
}

TEST(cpsrc_claim_fresh_window)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	b.observe({tent(1, 0.0f)}, 1000); // appeared at 1 s

	CHECK(claim_tent(b, 2, kKeyA, 17000)); // 16 s later: not the tent of this claim
	CHECK(b.match({tent(1, 0.0f)}, 4.0f, 15000).empty());
	CHECK(claim_tent(b, 2, kKeyA, 16000)); // exactly 15 s later: still it
	CHECK_EQ(b.match({tent(1, 0.0f)}, 4.0f, 15000).size(), size_t(1));

	// a tent that appears after the claim answers it
	TentBook c;
	c.new_world();
	c.observe({}, 0);
	CHECK(claim_tent(c, 4, kKeyA, 5000));
	c.observe({tent(3, 1.0f)}, 9000);
	const std::vector<TentMatch> m = c.match({tent(3, 1.0f)}, 4.0f, 15000);
	REQUIRE(m.size() == 1);
	CHECK_EQ(m[0].tent, uint16_t(3));

	// a tent the book has not observed is no answer
	TentBook d;
	d.new_world();
	d.observe({}, 0);
	CHECK(claim_tent(d, 4, kKeyA, 5000));
	CHECK(d.match({tent(3, 1.0f)}, 4.0f, 15000).empty());
}

TEST(cpsrc_one_tent_two_claims)
{
	TentBook b;
	b.new_world();
	b.observe({}, 0);
	CHECK(claim_tent(b, 7, kKeyA, 100));
	CHECK(claim_tent(b, 8, kKeyB, 200));
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
	CHECK(b.claim(5, kKeyA, ClaimWhat::Sleepbag, kAt0, 1000, 15000));
	CHECK(b.expire(15999).empty());
	const std::vector<ClaimEnd> gone = b.expire(16000);
	REQUIRE(gone.size() == 1);
	CHECK_EQ(gone[0].character, uint16_t(5));
	CHECK(gone[0].what == ClaimWhat::Sleepbag); // the answer names what was claimed
	CHECK(!b.has_claim(5));
	b.observe({tent(1, 0.0f)}, 16500);
	CHECK(b.match({tent(1, 0.0f)}, 4.0f, 15000).empty());
}

TEST(cpsrc_claim_bound_and_bad_claims)
{
	TentBook b;
	b.new_world();
	for (uint16_t c = 1; c <= kMaxClaims; ++c)
		REQUIRE(claim_tent(b, c, kKeyA, 10));
	CHECK(!claim_tent(b, 1000, kKeyA, 10)); // a new character over the bound
	CHECK(claim_tent(b, 1, kKeyA, 20)); // a known one replaces his own
	CHECK_EQ(b.claims(), kMaxClaims);

	TentBook c;
	CHECK(!claim_tent(c, 1, "", 10)); // no owner key
	CHECK(!claim_tent(c, 1, "a b", 10));
	const float nan_at[3] = {std::numeric_limits<float>::quiet_NaN(), 0.0f, 0.0f};
	CHECK(!claim_tent(c, 1, kKeyA, 10, nan_at));
	CHECK_EQ(c.claims(), size_t(0));
}

TEST(cpsrc_claims_of_absent_players_dropped)
{
	TentBook b;
	b.new_world();
	CHECK(claim_tent(b, 0, kHostOwner, 10));
	CHECK(b.claim(5, kKeyA, ClaimWhat::Sleepbag, kAt0, 10, 15000));
	CHECK(claim_tent(b, 6, kKeyB, 10));
	const std::vector<ClaimEnd> dropped = b.keep_claims_of({0, 6});
	REQUIRE(dropped.size() == 1);
	CHECK_EQ(dropped[0].character, uint16_t(5));
	CHECK(dropped[0].what == ClaimWhat::Sleepbag);
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
	CHECK(b.set_owner(1, kKeyA));
	CHECK(b.set_owner(77, kKeyA)); // a tent on another level: owned, not seen here
	CHECK(!b.set_owner(78, "")); // no key, no owner
	CHECK_EQ(b.owned_by(kKeyA), size_t(2));
	b.forget(1);
	CHECK(b.owner_of(1).empty());
	CHECK_EQ(b.tents(), size_t(1));
	const std::vector<uint16_t> k = b.known();
	CHECK(has(k, 2));
	CHECK(has(k, 77)); // owned ones are checked too
	CHECK(!has(k, 1));

	CHECK(claim_tent(b, 4, kKeyA, 200));
	b.new_world();
	CHECK_EQ(b.claims(), size_t(0));
	CHECK_EQ(b.owners(), size_t(0));
	b.observe({tent(2, 1.0f), tent(3, 2.0f)}, 300); // both stood when this world was served
	CHECK(claim_tent(b, 4, kKeyA, 400));
	CHECK(b.match({tent(2, 1.0f), tent(3, 2.0f)}, 4.0f, 15000).empty());
}

TEST(cpsrc_player_tent_limit)
{
	// R1 I-2, M-10: the limit counts the tents and sleeping bags of a key, whatever his character id is now
	TentBook b;
	b.new_world();
	CHECK(b.may_place(kKeyA, 2));
	CHECK(b.set_owner(10, kKeyA));
	CHECK(b.may_place(kKeyA, 2));
	CHECK(b.set_owner(11, kKeyA));
	CHECK(!b.may_place(kKeyA, 2)); // two of two
	CHECK(b.may_place(kKeyB, 2)); // another player's count is his own
	b.forget(10); // packed up or gone
	CHECK(b.may_place(kKeyA, 2));
	CHECK(!b.may_place("", 2)); // no key: no tent
	CHECK(!b.may_place(kKeyA, 0));
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
	for (uint16_t id = 1; id <= kMaxTents; ++id)
		REQUIRE(b.set_owner(id, kKeyA));
	REQUIRE(b.owners() == kMaxTents);
	CHECK(!b.set_owner(60000, kKeyA));
	CHECK(b.set_owner(1, kKeyB)); // a known tent changes hands
	CHECK_EQ(b.owner_of(1), kKeyB);
}
