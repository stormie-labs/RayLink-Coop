// Anomaly Coop unit tests: death rules (coop_death_rules.h; F3 Task 4, CHECKPOINTS_DEATH.md §3): the host rules and
// their wire form, which items a death takes, the wipe test and the per-player death tracker.
#include "test_util.h"

#include "coop_death_rules.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>

using namespace coop::death;

namespace
{
// The wire order of Rules, written out by hand so that a test can send values the host would never send itself.
std::vector<uint8_t> pack(uint8_t mode, uint8_t drop, uint32_t bleedout, float revive, uint32_t delay,
	uint32_t contusion, uint8_t money, uint8_t wear, uint8_t rank)
{
	coop::Writer w;
	w.u8(mode);
	w.u8(drop);
	w.u32(bleedout);
	w.f32(revive);
	w.u32(delay);
	w.u32(contusion);
	w.u8(money);
	w.u8(wear);
	w.u8(rank);
	return w.data();
}

bool read_rules(const std::vector<uint8_t>& bytes, Rules& out)
{
	coop::Reader r(bytes.data(), bytes.size());
	return out.read(r);
}

std::vector<Candidate> items(size_t n, uint8_t category, uint16_t first_id)
{
	std::vector<Candidate> v;
	for (size_t i = 0; i < n; ++i)
		v.push_back({uint16_t(first_id + i), category});
	return v;
}

Shares shares(float s)
{
	Shares a;
	a.fill(s);
	return a;
}

Shares only(uint8_t category, float s)
{
	Shares a;
	a.fill(0.0f);
	a[category] = s;
	return a;
}

std::vector<uint16_t> sorted(std::vector<uint16_t> v)
{
	std::sort(v.begin(), v.end());
	return v;
}

size_t count_in(const std::vector<uint16_t>& picked, uint16_t lo, uint16_t hi) // ids lo..hi
{
	size_t n = 0;
	for (const uint16_t id : picked)
		if (id >= lo && id <= hi)
			++n;
	return n;
}
} // namespace

TEST(death_rules_defaults)
{
	const Rules r;
	CHECK(r.mode == Mode::Checkpoint);
	CHECK(r.drop == Drop::Drop);
	CHECK_EQ(r.bleedout_ms, uint32_t(60000));
	CHECK_EQ(r.revive_health, 0.3f);
	CHECK_EQ(r.delay_ms, uint32_t(30000)); // T
	CHECK_EQ(r.contusion_s, uint32_t(600));
	CHECK_EQ(int(r.money_pct), 10);
	CHECK_EQ(int(r.wear_pct), 10);
	CHECK_EQ(int(r.rank_pct), 0);
}

TEST(death_rules_wire_roundtrip)
{
	// The defaults.
	{
		const Rules a;
		coop::Writer w;
		a.write(w);
		coop::Reader rd(w.ptr(), w.size());
		Rules b;
		b.mode = Mode::Hardcore; // to see that read overwrites
		b.delay_ms = 1;
		REQUIRE(b.read(rd));
		CHECK(a == b);
		CHECK_EQ(rd.remaining(), size_t(0));
	}
	// Changed values.
	{
		Rules a;
		a.mode = Mode::Hardcore;
		a.drop = Drop::Lose;
		a.bleedout_ms = 90000;
		a.revive_health = 0.5f;
		a.delay_ms = 45000;
		a.contusion_s = 120;
		a.money_pct = 25;
		a.wear_pct = 40;
		a.rank_pct = 5;
		coop::Writer w;
		a.write(w);
		Rules b;
		coop::Reader rd(w.ptr(), w.size());
		REQUIRE(b.read(rd));
		CHECK(a == b);
		CHECK(b.mode == Mode::Hardcore);
		CHECK(b.drop == Drop::Lose);
		CHECK_EQ(b.bleedout_ms, uint32_t(90000));
		CHECK_EQ(b.revive_health, 0.5f);
		CHECK_EQ(b.delay_ms, uint32_t(45000));
		CHECK_EQ(b.contusion_s, uint32_t(120));
		CHECK_EQ(int(b.money_pct), 25);
		CHECK_EQ(int(b.wear_pct), 40);
		CHECK_EQ(int(b.rank_pct), 5);
	}
	// Corpse mode, too.
	{
		Rules a;
		a.drop = Drop::Corpse;
		coop::Writer w;
		a.write(w);
		Rules b;
		coop::Reader rd(w.ptr(), w.size());
		REQUIRE(b.read(rd));
		CHECK(b.drop == Drop::Corpse);
	}
}

TEST(death_rules_equality)
{
	const Rules base;
	CHECK(base == Rules());
	Rules r = base;
	r.mode = Mode::Hardcore;
	CHECK(!(r == base));
	r = base;
	r.drop = Drop::Corpse;
	CHECK(!(r == base));
	r = base;
	r.bleedout_ms += 1;
	CHECK(!(r == base));
	r = base;
	r.revive_health = 0.31f;
	CHECK(!(r == base));
	r = base;
	r.delay_ms += 1;
	CHECK(!(r == base));
	r = base;
	r.contusion_s += 1;
	CHECK(!(r == base));
	r = base;
	r.money_pct += 1;
	CHECK(!(r == base));
	r = base;
	r.wear_pct += 1;
	CHECK(!(r == base));
	r = base;
	r.rank_pct += 1;
	CHECK(!(r == base));
}

TEST(death_rules_clamp)
{
	Rules r;
	// A normal packet passes unchanged.
	REQUIRE(read_rules(pack(0, 0, 60000, 0.3f, 30000, 600, 10, 10, 0), r));
	CHECK(r == Rules());

	// Too big.
	REQUIRE(read_rules(pack(0, 0, 9999999, 2.0f, 999999, 99999, 250, 255, 101), r));
	CHECK_EQ(r.bleedout_ms, uint32_t(600000));
	CHECK_EQ(r.revive_health, 1.0f);
	CHECK_EQ(r.delay_ms, uint32_t(300000));
	CHECK_EQ(r.contusion_s, uint32_t(3600));
	CHECK_EQ(int(r.money_pct), 100);
	CHECK_EQ(int(r.wear_pct), 100);
	CHECK_EQ(int(r.rank_pct), 100);

	// Too small.
	REQUIRE(read_rules(pack(1, 2, 0, 0.0f, 0, 0, 0, 0, 0), r));
	CHECK(r.mode == Mode::Hardcore);
	CHECK(r.drop == Drop::Lose);
	CHECK_EQ(r.bleedout_ms, uint32_t(5000));
	CHECK_EQ(r.revive_health, 0.05f);
	CHECK_EQ(r.delay_ms, uint32_t(0));
	CHECK_EQ(r.contusion_s, uint32_t(0));
	CHECK_EQ(int(r.money_pct), 0);
	CHECK_EQ(int(r.wear_pct), 0);
	CHECK_EQ(int(r.rank_pct), 0);
	REQUIRE(read_rules(pack(0, 0, 60000, -3.0f, 30000, 600, 10, 10, 0), r));
	CHECK_EQ(r.revive_health, 0.05f);

	// The edges themselves.
	REQUIRE(read_rules(pack(0, 0, 5000, 0.05f, 300000, 3600, 100, 100, 100), r));
	CHECK_EQ(r.bleedout_ms, uint32_t(5000));
	CHECK_EQ(r.revive_health, 0.05f);
	CHECK_EQ(r.delay_ms, uint32_t(300000));
	CHECK_EQ(r.contusion_s, uint32_t(3600));
	CHECK_EQ(int(r.money_pct), 100);
	REQUIRE(read_rules(pack(0, 0, 600000, 1.0f, 0, 0, 0, 0, 0), r));
	CHECK_EQ(r.bleedout_ms, uint32_t(600000));
	CHECK_EQ(r.revive_health, 1.0f);
}

TEST(death_rules_reject)
{
	const float nan = std::numeric_limits<float>::quiet_NaN();
	const float inf = std::numeric_limits<float>::infinity();
	const Rules sentinel = [] {
		Rules s;
		s.mode = Mode::Hardcore;
		s.drop = Drop::Corpse;
		s.delay_ms = 12345;
		s.money_pct = 77;
		return s;
	}();

	const std::vector<uint8_t> bad[] = {
		pack(2, 0, 60000, 0.3f, 30000, 600, 10, 10, 0),    // mode 2
		pack(255, 0, 60000, 0.3f, 30000, 600, 10, 10, 0),  // mode 255
		pack(0, 3, 60000, 0.3f, 30000, 600, 10, 10, 0),    // drop 3
		pack(0, 0, 60000, nan, 30000, 600, 10, 10, 0),     // revive NaN
		pack(0, 0, 60000, inf, 30000, 600, 10, 10, 0),     // revive +inf
		pack(0, 0, 60000, -inf, 30000, 600, 10, 10, 0),    // revive -inf
	};
	for (const std::vector<uint8_t>& bytes : bad)
	{
		Rules r = sentinel;
		if (read_rules(bytes, r))
			t::report_failure(__FILE__, __LINE__, "Rules::read accepted a bad packet");
		if (!(r == sentinel))
			t::report_failure(__FILE__, __LINE__, "Rules::read changed the rules on a bad packet");
	}

	// A packet cut anywhere.
	const std::vector<uint8_t> whole = pack(0, 0, 60000, 0.3f, 30000, 600, 10, 10, 0);
	for (size_t n = 0; n < whole.size(); ++n)
	{
		const std::vector<uint8_t> cut(whole.begin(), whole.begin() + std::ptrdiff_t(n));
		Rules r = sentinel;
		if (read_rules(cut, r))
			t::report_failure(__FILE__, __LINE__, "Rules::read accepted a packet cut to " + std::to_string(n));
		if (!(r == sentinel))
			t::report_failure(__FILE__, __LINE__, "Rules::read changed the rules on a cut packet");
	}
}

TEST(death_category_names)
{
	const char* names[] = {"materials", "ammo", "consumables", "gear", "artefacts", "tools", "other"};
	for (uint8_t i = 0; i < kCategories; ++i)
	{
		uint8_t c = 255;
		REQUIRE(category_from_name(names[i], c));
		CHECK_EQ(int(c), int(i));
	}
	uint8_t c = 42;
	CHECK(!category_from_name("weapons", c));
	CHECK(!category_from_name("", c));
	CHECK(!category_from_name("Ammo", c));
	CHECK(!category_from_name("ammo ", c));
	CHECK(!category_from_name(nullptr, c));
	CHECK_EQ(int(c), 42); // untouched on failure
	static_assert(int(kCategories) == 7, "the loss shares are kept for seven categories");
}

TEST(death_losses_counts)
{
	// 10 materials at 0.5: exactly 5, for every seed.
	for (uint32_t seed = 1; seed <= 100; ++seed)
		CHECK_EQ(pick_losses(items(10, Materials, 1), only(Materials, 0.5f), seed).size(), size_t(5));

	// 0 takes nothing, 1 takes everything.
	CHECK_EQ(pick_losses(items(10, Materials, 1), only(Materials, 0.0f), 7).size(), size_t(0));
	CHECK_EQ(pick_losses(items(10, Materials, 1), only(Materials, 1.0f), 7).size(), size_t(10));

	// 0.1 of 10 is one (10 * 0.1f is not exactly 1 in a float; it must still be one, never two).
	for (uint32_t seed = 1; seed <= 100; ++seed)
		CHECK_EQ(pick_losses(items(10, Materials, 1), only(Materials, 0.1f), seed).size(), size_t(1));
	// Likewise 0.25 of 4 and 0.1 of 30.
	for (uint32_t seed = 1; seed <= 100; ++seed)
	{
		CHECK_EQ(pick_losses(items(4, Ammo, 1), only(Ammo, 0.25f), seed).size(), size_t(1));
		CHECK_EQ(pick_losses(items(30, Gear, 1), only(Gear, 0.1f), seed).size(), size_t(3));
	}

	// Categories are counted apart: 4 ammo at 0.5 and 10 materials at 0.1 give 2 and 1.
	std::vector<Candidate> all = items(10, Materials, 100); // ids 100..109
	const std::vector<Candidate> ammo = items(4, Ammo, 200); // ids 200..203
	all.insert(all.end(), ammo.begin(), ammo.end());
	Shares s;
	s.fill(0.0f);
	s[Materials] = 0.1f;
	s[Ammo] = 0.5f;
	for (uint32_t seed = 1; seed <= 100; ++seed)
	{
		const std::vector<uint16_t> picked = pick_losses(all, s, seed);
		CHECK_EQ(picked.size(), size_t(3));
		CHECK_EQ(count_in(picked, 100, 109), size_t(1));
		CHECK_EQ(count_in(picked, 200, 203), size_t(2));
	}

	// A category with no share loses nothing even if the others do.
	std::vector<Candidate> mixed = items(6, Gear, 1);
	const std::vector<Candidate> art = items(6, Artefacts, 50);
	mixed.insert(mixed.end(), art.begin(), art.end());
	const std::vector<uint16_t> only_art = pick_losses(mixed, only(Artefacts, 1.0f), 3);
	CHECK_EQ(only_art.size(), size_t(6));
	CHECK_EQ(count_in(only_art, 50, 55), size_t(6));

	// A share outside 0..1 is cut to the range; NaN loses nothing.
	CHECK_EQ(pick_losses(items(5, Tools, 1), only(Tools, 3.0f), 1).size(), size_t(5));
	CHECK_EQ(pick_losses(items(5, Tools, 1), only(Tools, -1.0f), 1).size(), size_t(0));
	CHECK_EQ(pick_losses(items(5, Tools, 1), only(Tools, std::numeric_limits<float>::quiet_NaN()), 1).size(), size_t(0));
}

TEST(death_losses_fraction)
{
	// 3 items at 0.5 is 1.5: one, and a second one with probability one half.
	size_t total = 0;
	for (uint32_t seed = 1; seed <= 1000; ++seed)
	{
		const size_t n = pick_losses(items(3, Consumables, 1), only(Consumables, 0.5f), seed).size();
		if (n != 1 && n != 2)
			t::report_failure(__FILE__, __LINE__, "3 items at 0.5 gave " + std::to_string(n));
		total += n;
	}
	const double mean = double(total) / 1000.0;
	if (mean < 1.45 || mean > 1.55)
		t::report_failure(__FILE__, __LINE__, "mean of 3 items at 0.5 is " + std::to_string(mean));

	// 1 item at 0.25: none or it, three times in four it stays.
	size_t lost = 0;
	for (uint32_t seed = 1; seed <= 1000; ++seed)
	{
		const size_t n = pick_losses(items(1, Other, 9), only(Other, 0.25f), seed).size();
		if (n > 1)
			t::report_failure(__FILE__, __LINE__, "1 item at 0.25 gave " + std::to_string(n));
		lost += n;
	}
	if (lost < 200 || lost > 300)
		t::report_failure(__FILE__, __LINE__, "1 item at 0.25 was lost " + std::to_string(lost) + " times in 1000");
}

TEST(death_losses_deterministic)
{
	const std::vector<Candidate> in = items(20, Materials, 1);
	const Shares s = only(Materials, 0.5f);

	// One seed, one answer.
	for (uint32_t seed = 1; seed <= 10; ++seed)
		CHECK(pick_losses(in, s, seed) == pick_losses(in, s, seed));

	// The seed matters.
	std::set<std::vector<uint16_t>> sets;
	for (uint32_t seed = 1; seed <= 10; ++seed)
		sets.insert(sorted(pick_losses(in, s, seed)));
	CHECK(sets.size() >= 5);

	// A seed of zero is fine too.
	CHECK_EQ(pick_losses(in, s, 0).size(), size_t(10));
	CHECK(pick_losses(in, s, 0) == pick_losses(in, s, 0));

	// Every item can be taken and every item can be spared: nothing is favoured.
	size_t taken[20] = {};
	for (uint32_t seed = 1; seed <= 1000; ++seed)
		for (const uint16_t id : pick_losses(in, s, seed))
			++taken[id - 1];
	for (int i = 0; i < 20; ++i)
		if (taken[i] < 400 || taken[i] > 600)
			t::report_failure(__FILE__, __LINE__,
				"item " + std::to_string(i + 1) + " was taken " + std::to_string(taken[i]) + " times in 1000");
}

// F3 review round 1, finding 3: fixed answers for fixed inputs. The scrambled seed, the xorshift32 steps, the order of
// the draws and the shuffle are all part of the answer; an accidental change of any of them breaks these vectors. Change
// them only on purpose, together with the algorithm.
TEST(death_losses_pinned_vectors)
{
	// 10 materials, ids 1..10, share 0.5 (exactly five).
	{
		const std::vector<Candidate> in = items(10, Materials, 1);
		const Shares s = only(Materials, 0.5f);
		CHECK((pick_losses(in, s, 1) == std::vector<uint16_t>{2, 4, 3, 6, 1}));
		CHECK((pick_losses(in, s, 12345) == std::vector<uint16_t>{1, 3, 6, 4, 9}));
	}
	// Three categories in the order of the enum: materials 10..15 at 0.5 (three), ammo 20..23 at 0.25 (one), gear 30..34
	// at 0.1 (0.5 of an item: none or one by the draw).
	{
		std::vector<Candidate> in = items(6, Materials, 10);
		const std::vector<Candidate> ammo = items(4, Ammo, 20);
		const std::vector<Candidate> gear = items(5, Gear, 30);
		in.insert(in.end(), ammo.begin(), ammo.end());
		in.insert(in.end(), gear.begin(), gear.end());
		Shares s;
		s.fill(0.0f);
		s[Materials] = 0.5f;
		s[Ammo] = 0.25f;
		s[Gear] = 0.1f;
		CHECK((pick_losses(in, s, 7) == std::vector<uint16_t>{12, 10, 14, 23, 31}));
		CHECK((pick_losses(in, s, 4242) == std::vector<uint16_t>{11, 12, 14, 20}));
		CHECK((pick_losses(in, s, 0xdeadbeefu) == std::vector<uint16_t>{12, 11, 14, 21, 33}));
	}
	// 3 consumables at 0.5 (one, and a second by the draw): seed 5 stays at one, seed 1 takes two.
	{
		const std::vector<Candidate> in = items(3, Consumables, 100);
		const Shares s = only(Consumables, 0.5f);
		CHECK((pick_losses(in, s, 1) == std::vector<uint16_t>{100, 101}));
		CHECK((pick_losses(in, s, 5) == std::vector<uint16_t>{102}));
	}
}

TEST(death_losses_subset)
{
	std::vector<Candidate> in = items(8, Materials, 10);
	const std::vector<Candidate> b = items(8, Gear, 100);
	in.insert(in.end(), b.begin(), b.end());
	std::set<uint16_t> known;
	for (const Candidate& c : in)
		known.insert(c.id);

	for (uint32_t seed = 1; seed <= 200; ++seed)
	{
		const std::vector<uint16_t> out = pick_losses(in, shares(0.6f), seed);
		std::set<uint16_t> seen;
		for (const uint16_t id : out)
		{
			if (!known.count(id))
				t::report_failure(__FILE__, __LINE__, "an id that was not offered: " + std::to_string(id));
			if (!seen.insert(id).second)
				t::report_failure(__FILE__, __LINE__, "a repeated id: " + std::to_string(id));
		}
	}

	CHECK(pick_losses({}, shares(1.0f), 5).empty());
	CHECK(pick_losses({}, shares(0.5f), 0).empty());

	// An id offered twice is taken at most once.
	std::vector<Candidate> dup = items(3, Ammo, 1);
	dup.push_back({2, Ammo});
	const std::vector<uint16_t> all = pick_losses(dup, only(Ammo, 1.0f), 1);
	CHECK_EQ(all.size(), size_t(3));
	CHECK_EQ(sorted(all).size(), size_t(3));

	// A category that does not exist is not touched.
	std::vector<Candidate> odd = items(3, Ammo, 1);
	odd.push_back({99, 200});
	odd.push_back({98, kCategories});
	const std::vector<uint16_t> r = pick_losses(odd, shares(1.0f), 1);
	CHECK_EQ(r.size(), size_t(3));
	CHECK_EQ(count_in(r, 98, 99), size_t(0));
}

TEST(death_wipe)
{
	CHECK(!is_wipe({}));
	CHECK(!is_wipe({0, 2}));
	CHECK(is_wipe({2, 4}));
	CHECK(!is_wipe({1, 2}));
	CHECK(is_wipe({3, 2}));
	// The rest of the table.
	CHECK(!is_wipe({0}));
	CHECK(!is_wipe({1}));
	CHECK(is_wipe({2}));
	CHECK(is_wipe({3}));
	CHECK(is_wipe({4}));
	CHECK(is_wipe({2, 3, 4}));
	CHECK(!is_wipe({2, 3, 4, 0}));
	CHECK(!is_wipe({2, 3, 4, 1}));
	CHECK(!is_wipe({0, 0}));
}

TEST(death_tracker_once)
{
	Rules rules;
	Tracker tr;
	CHECK_EQ(tr.decided_seq, uint16_t(0xffff));
	CHECK(on_died(tr, 1, 1000, rules) == Action::LossesAndEvacuate);
	CHECK_EQ(tr.respawn_at, uint64_t(1000 + rules.delay_ms));
	CHECK(!tr.hardcore_out);

	// The same death reported again: nothing.
	CHECK(on_died(tr, 1, 5000, rules) == Action::None);
	CHECK_EQ(tr.respawn_at, uint64_t(1000 + rules.delay_ms)); // not pushed back

	// The next death is a new one.
	CHECK(on_died(tr, 2, 90000, rules) == Action::LossesAndEvacuate);
	CHECK_EQ(tr.respawn_at, uint64_t(90000 + rules.delay_ms));
	CHECK(on_died(tr, 2, 90001, rules) == Action::None);

	// The delay comes from the rules.
	Rules slow;
	slow.delay_ms = 120000;
	Tracker t2;
	CHECK(on_died(t2, 7, 500, slow) == Action::LossesAndEvacuate);
	CHECK_EQ(t2.respawn_at, uint64_t(500 + 120000));
}

TEST(death_tracker_due)
{
	Rules rules; // T = 30000
	Tracker tr;
	CHECK(!due(tr, 100000)); // nobody died
	REQUIRE(on_died(tr, 1, 1000, rules) == Action::LossesAndEvacuate);
	CHECK(!due(tr, 1000));
	CHECK(!due(tr, 30999));
	CHECK(due(tr, 31000));
	CHECK(!due(tr, 31001));
	CHECK(!due(tr, 99999));
	CHECK(!tr.respawn_due); // "due" is the evacuation timer, not the left-and-back flag

	// A late call still fires, once.
	Tracker late;
	REQUIRE(on_died(late, 1, 0, rules) == Action::LossesAndEvacuate);
	CHECK(due(late, 500000));
	CHECK(!due(late, 500001));

	// No delay: due on the same tick (also at tick 0 of the clock).
	Rules instant;
	instant.delay_ms = 0;
	Tracker now;
	REQUIRE(on_died(now, 1, 5000, instant) == Action::LossesAndEvacuate);
	CHECK(due(now, 5000));
	Tracker zero;
	REQUIRE(on_died(zero, 1, 0, instant) == Action::LossesAndEvacuate);
	CHECK(due(zero, 1));
}

TEST(death_tracker_left_return)
{
	// Review Focus 1: left while dead and came back.
	Rules rules;
	Tracker tr;
	REQUIRE(on_died(tr, 1, 1000, rules) == Action::LossesAndEvacuate);
	on_left(tr);
	CHECK(tr.respawn_due);
	CHECK_EQ(tr.respawn_at, uint64_t(0));
	CHECK(!due(tr, 1000000)); // the evacuation timer does not run while the player is away
	CHECK(on_returned(tr));
	CHECK(!on_returned(tr));
	// The same death does not take the items again.
	CHECK(on_died(tr, 1, 2000000, rules) == Action::None);
	CHECK(!tr.respawn_due);
	// A new death does.
	CHECK(on_died(tr, 2, 2000001, rules) == Action::LossesAndEvacuate);

	// Left and came back more than once before the host got to it: still one respawn.
	Tracker twice;
	REQUIRE(on_died(twice, 1, 0, rules) == Action::LossesAndEvacuate);
	on_left(twice);
	on_left(twice);
	CHECK(on_returned(twice));
	CHECK(!on_returned(twice));
}

TEST(death_tracker_left_while_alive)
{
	// A player who is not dead is not respawned when they come back.
	Rules rules;
	Tracker fresh;
	on_left(fresh);
	CHECK(!fresh.respawn_due);
	CHECK(!on_returned(fresh));

	// Died, stood up (respawned), left, came back.
	Tracker tr;
	REQUIRE(on_died(tr, 1, 0, rules) == Action::LossesAndEvacuate);
	REQUIRE(due(tr, 30000));
	on_alive(tr);
	on_left(tr);
	CHECK(!on_returned(tr));
	// The new actor's counter starts again: its first death carries seq 1 again and is a new death.
	CHECK(on_died(tr, 1, 100000, rules) == Action::LossesAndEvacuate);
}

TEST(death_tracker_world_replaced)
{
	// Review Focus 2: the host loaded another world while a player was dead.
	Rules rules;
	Tracker tr;
	REQUIRE(on_died(tr, 1, 1000, rules) == Action::LossesAndEvacuate);
	CHECK(on_world_replaced(tr));
	CHECK(on_died(tr, 1, 2000, rules) == Action::None);
	CHECK(!due(tr, 1000000)); // nothing left to wait for
	CHECK(!on_world_replaced(tr)); // already handled
	CHECK(!on_returned(tr));

	// Alive: nothing to do.
	Tracker alive;
	CHECK(!on_world_replaced(alive));
	Tracker stood_up;
	REQUIRE(on_died(stood_up, 4, 0, rules) == Action::LossesAndEvacuate);
	on_alive(stood_up);
	CHECK(!on_world_replaced(stood_up));

	// Left while dead, and the world was replaced before they came back: they are put on their camp now, and
	// the "respawn on return" is gone.
	Tracker away;
	REQUIRE(on_died(away, 3, 0, rules) == Action::LossesAndEvacuate);
	on_left(away);
	CHECK(on_world_replaced(away));
	CHECK(!on_returned(away));
	CHECK(on_died(away, 3, 5, rules) == Action::None);

	// The death after that is counted as a new one.
	CHECK(on_died(tr, 2, 3000, rules) == Action::LossesAndEvacuate);
}

TEST(death_tracker_hardcore)
{
	Rules rules;
	rules.mode = Mode::Hardcore;
	Tracker tr;
	CHECK(on_died(tr, 1, 1000, rules) == Action::Spectate);
	CHECK(tr.hardcore_out);
	CHECK_EQ(tr.respawn_at, uint64_t(0));
	CHECK(!tr.respawn_due);

	// Out is out: nothing brings the player back, whatever happens to the session.
	CHECK(!due(tr, 100000000));
	on_left(tr);
	CHECK(!tr.respawn_due);
	CHECK(!on_returned(tr));
	CHECK(!on_world_replaced(tr));
	CHECK(tr.hardcore_out);

	// The same death twice is still one decision.
	CHECK(on_died(tr, 1, 2000, rules) == Action::None);
}

TEST(death_tracker_alive)
{
	Rules rules;
	Tracker tr;
	REQUIRE(on_died(tr, 5, 1000, rules) == Action::LossesAndEvacuate);
	on_alive(tr);
	CHECK_EQ(tr.respawn_at, uint64_t(0));
	CHECK(!tr.respawn_due);
	CHECK_EQ(tr.decided_seq, uint16_t(0xffff)); // standing up clears the decision: the next death is a new one
	CHECK(!due(tr, 1000000));
	CHECK(on_died(tr, 5, 2000, rules) == Action::LossesAndEvacuate);
	CHECK(on_died(tr, 5, 2001, rules) == Action::None);
	CHECK(on_died(tr, 6, 3000, rules) == Action::LossesAndEvacuate);

	// Stood up after the player left and came back: nothing is pending.
	Tracker back;
	REQUIRE(on_died(back, 1, 0, rules) == Action::LossesAndEvacuate);
	on_left(back);
	on_alive(back);
	CHECK(!back.respawn_due);
	CHECK(!on_returned(back));
}

TEST(death_tracker_new_actor_same_seq)
{
	// F3 review round 1, finding 1: the client's counter starts from 0 with every new actor, so after the player has
	// stood up the next death can carry the same number as the last one. It is a new death and takes the items.
	Rules rules;
	Tracker tr;
	REQUIRE(on_died(tr, 1, 1000, rules) == Action::LossesAndEvacuate);
	on_alive(tr);
	CHECK(on_died(tr, 1, 100000, rules) == Action::LossesAndEvacuate);
	CHECK_EQ(tr.respawn_at, uint64_t(100000 + rules.delay_ms));
	CHECK(on_died(tr, 1, 100001, rules) == Action::None); // the same death again is still one decision

	// Over and over: die, stand up, die with the same number.
	Tracker again;
	for (int i = 0; i < 5; ++i)
	{
		CHECK(on_died(again, 1, 1000 + uint64_t(i) * 100000, rules) == Action::LossesAndEvacuate);
		on_alive(again);
	}

	// A reload of the world while dead is not standing up: the same number stays the same death
	// (death_tracker_world_replaced) until the player is alive again.
	Tracker replaced;
	REQUIRE(on_died(replaced, 1, 1000, rules) == Action::LossesAndEvacuate);
	REQUIRE(on_world_replaced(replaced));
	CHECK(on_died(replaced, 1, 2000, rules) == Action::None);
	on_alive(replaced);
	CHECK(on_died(replaced, 1, 3000, rules) == Action::LossesAndEvacuate);
}

// ---------------------------------------------------------------- the host's death flow (F3 Task 8, fix round 1 I-2)

namespace
{
Rules hardcore_rules()
{
	Rules r;
	r.mode = Mode::Hardcore;
	return r;
}
} // namespace

TEST(death_alive_report_respawn_owed)
{
	Rules rules;

	// Nothing owed: a living player's report changes nothing.
	Tracker fresh;
	CHECK(on_alive_report(fresh, false, false) == AliveStep::None);

	// Review Focus 1: left while evacuated, back alive -> respawn, once (the tracker forgets the wait).
	Tracker left;
	REQUIRE(on_died(left, 3, 1000, rules) == Action::LossesAndEvacuate);
	on_left(left);
	CHECK(on_alive_report(left, false, false) == AliveStep::Respawn);
	CHECK(!left.respawn_due);
	CHECK_EQ(left.decided_seq, uint16_t(0xffff)); // on_alive ran: the next death of the new actor is a new one
	CHECK(on_alive_report(left, false, false) == AliveStep::None);

	// Review Focus 2: the world was replaced (a fresh tracker), the world still owes him the respawn -> respawn.
	Tracker replaced;
	CHECK(on_alive_report(replaced, true, false) == AliveStep::Respawn);

	// An Alive that crossed the order on the wire: no second order for the same seq.
	Tracker crossed;
	CHECK(on_alive_report(crossed, true, true) == AliveStep::None);
	Tracker crossed_left;
	REQUIRE(on_died(crossed_left, 4, 1000, rules) == Action::LossesAndEvacuate);
	on_left(crossed_left);
	CHECK(on_alive_report(crossed_left, false, true) == AliveStep::None);

	// Alive while the countdown runs is not a return: the death is forgotten, no respawn order (as WP8 did).
	Tracker standing;
	REQUIRE(on_died(standing, 5, 1000, rules) == Action::LossesAndEvacuate);
	CHECK(on_alive_report(standing, false, false) == AliveStep::None);
	CHECK_EQ(standing.respawn_at, uint64_t(0));
}

TEST(death_alive_report_hardcore_out)
{
	// Ruling F3-7 (fix round 1, I-1): out of a hardcore run stays out until F3 Task 10, whatever the mode is now.
	Tracker tr;
	REQUIRE(on_died(tr, 2, 1000, hardcore_rules()) == Action::Spectate);
	REQUIRE(tr.hardcore_out);

	// The host switched to checkpoint (the mode is not an input any more): an Alive report is answered by Spectate.
	CHECK(on_alive_report(tr, false, false) == AliveStep::Spectate);
	CHECK(tr.hardcore_out);

	// He leaves and rejoins as often as he likes: still out, never a respawn, even with a debt in the world.
	for (int i = 0; i < 3; ++i)
	{
		on_left(tr);
		CHECK(on_alive_report(tr, false, false) == AliveStep::Spectate);
		CHECK(tr.hardcore_out);
	}
	CHECK(on_alive_report(tr, true, false) == AliveStep::Spectate);
	CHECK(on_alive_report(tr, true, true) == AliveStep::Spectate);
	CHECK(tr.hardcore_out);
}

TEST(death_debt_lifecycle)
{
	// Set by a checkpoint death, not by a hardcore one, not by a repeated report of the same death.
	CHECK(debt_after_report(false, kLifeDead, Action::LossesAndEvacuate));
	CHECK(!debt_after_report(false, kLifeDead, Action::Spectate));
	CHECK(!debt_after_report(false, kLifeDead, Action::None));
	CHECK(debt_after_report(true, kLifeDead, Action::None));

	// Kept by every report until the owner applies the respawn.
	CHECK(debt_after_report(true, kLifeAlive, Action::None));
	CHECK(debt_after_report(true, kLifeWounded, Action::None));
	CHECK(debt_after_report(true, kLifeSpectating, Action::None));
	CHECK(!debt_after_report(false, kLifeAlive, Action::None));

	// Paid by Respawning: the order reached him and he applied it.
	CHECK(!debt_after_report(true, kLifeRespawning, Action::None));
	CHECK(!debt_after_report(false, kLifeRespawning, Action::None));

	// M-1: the respawn order went out, he applied it (Respawning reached the host), then left or the world changed
	// before the host saw him alive: no second respawn, no second wear.
	{
		Rules rules;
		Tracker tr;
		bool debt = debt_after_report(false, kLifeDead, on_died(tr, 7, 1000, rules));
		REQUIRE(debt);
		REQUIRE(due(tr, 1000 + rules.delay_ms));
		debt = debt_after_report(debt, kLifeRespawning, Action::None);
		on_left(tr);
		CHECK(on_alive_report(tr, debt, false) == AliveStep::None);
		Tracker new_world;
		CHECK(on_alive_report(new_world, debt, false) == AliveStep::None);
	}

	// The order went out but he left before applying it: the world still owes the respawn.
	{
		Rules rules;
		Tracker tr;
		const bool debt = debt_after_report(false, kLifeDead, on_died(tr, 8, 1000, rules));
		REQUIRE(due(tr, 1000 + rules.delay_ms));
		on_left(tr); // the tracker no longer waits (the window after due)
		CHECK(!tr.respawn_due);
		CHECK(on_alive_report(tr, debt, false) == AliveStep::Respawn);
		// ... and after a world change (a fresh tracker, the debt saved with the character) the same.
		Tracker new_world;
		CHECK(on_alive_report(new_world, debt, false) == AliveStep::Respawn);
	}

	// M-3: a new game or another save has fresh characters without the debt: nothing for whoever has that id now.
	{
		Tracker new_game;
		CHECK(on_alive_report(new_game, false, false) == AliveStep::None);
	}
}

TEST(death_worn_tail)
{
	const auto tail = [](const std::vector<uint16_t>& ids) {
		coop::Writer w;
		write_worn(w, ids);
		return w.data();
	};
	const auto parse = [](const std::vector<uint8_t>& bytes, std::vector<uint16_t>& out) {
		coop::Reader r(bytes.data(), bytes.size());
		return read_worn(r, out);
	};

	std::vector<uint16_t> out = {1, 2, 3};

	// No tail: the layout stays unknown.
	CHECK(parse({}, out) == WornTail::Absent);
	CHECK(out.empty());

	// Round trip: sorted, each once; an empty list is a list ("he wears nothing").
	CHECK(parse(tail({900, 12, 900, 7}), out) == WornTail::Ok);
	CHECK(out == std::vector<uint16_t>({7, 12, 900}));
	out = {1};
	CHECK(parse(tail({}), out) == WornTail::Ok);
	CHECK(out.empty());

	// The writer caps at kMaxWornIds; exactly kMaxWornIds is read back.
	std::vector<uint16_t> many;
	for (uint16_t i = 0; i < 60; ++i)
		many.push_back(uint16_t(100 + i));
	const std::vector<uint8_t> capped = tail(many);
	CHECK_EQ(capped.size(), size_t(1 + 2 * kMaxWornIds));
	CHECK(parse(capped, out) == WornTail::Ok);
	CHECK_EQ(out.size(), size_t(kMaxWornIds));
	REQUIRE(!out.empty());
	CHECK_EQ(out.front(), uint16_t(100));
	CHECK_EQ(out.back(), uint16_t(100 + kMaxWornIds - 1));

	// n over the bound: dropped whole, whatever follows.
	{
		coop::Writer w;
		w.u8(uint8_t(kMaxWornIds + 1));
		for (uint16_t i = 0; i <= kMaxWornIds; ++i)
			w.u16(i);
		out = {1};
		CHECK(parse(w.data(), out) == WornTail::Bad);
		CHECK(out.empty());
	}
	{
		coop::Writer w;
		w.u8(255);
		out = {1};
		CHECK(parse(w.data(), out) == WornTail::Bad);
		CHECK(out.empty());
	}

	// A short packet: fewer bytes than n ids, also half an id.
	{
		coop::Writer w;
		w.u8(3);
		w.u16(5);
		w.u16(6);
		out = {1};
		CHECK(parse(w.data(), out) == WornTail::Bad);
		CHECK(out.empty());
		std::vector<uint8_t> half = tail({5, 6});
		half.pop_back();
		out = {1};
		CHECK(parse(half, out) == WornTail::Bad);
		CHECK(out.empty());
	}

	// Bytes after the list are left to a newer writer.
	{
		std::vector<uint8_t> longer = tail({4, 2});
		longer.push_back(0xAB);
		coop::Reader r(longer.data(), longer.size());
		CHECK(read_worn(r, out) == WornTail::Ok);
		CHECK(out == std::vector<uint16_t>({2, 4}));
		CHECK_EQ(r.remaining(), size_t(1));
	}
}

TEST(death_hud_format_one_conversion)
{
	CHECK(one_conversion("Back at your camp in %d s", 'd'));
	CHECK(one_conversion("%d", 'd'));
	CHECK(one_conversion("Watching: %s", 's'));
	CHECK(!one_conversion("Watching: %s", 'd'));
	CHECK(!one_conversion("Back in %d s", 's'));
	CHECK(!one_conversion("no conversion", 'd'));
	CHECK(!one_conversion("%d of %d", 'd'));
	CHECK(!one_conversion("100%% in %d s", 'd'));
	CHECK(!one_conversion("trailing %", 'd'));
	CHECK(!one_conversion("", 'd'));
	CHECK(!one_conversion(nullptr, 'd'));
}
