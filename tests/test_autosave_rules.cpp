// Anomaly Coop unit tests: the host's autosave rotation (coop_autosave_rules.h; F3 Task 5, CHECKPOINTS_DEATH.md §7):
// slot names, which slot the next save goes to, and the timer that waits while the host is busy.
#include "test_util.h"

#include "coop_autosave_rules.h"

using namespace coop::autosave;

namespace
{
constexpr uint32_t kMinute = 60000;

std::vector<SlotInfo> slots(std::initializer_list<uint32_t> indices, uint64_t time_base = 1000)
{
	std::vector<SlotInfo> v;
	for (const uint32_t i : indices)
		v.push_back({i, time_base + i});
	return v;
}

std::vector<SlotInfo> range(uint32_t first, uint32_t last, uint64_t time_base = 1000)
{
	std::vector<SlotInfo> v;
	for (uint32_t i = first; i <= last; ++i)
		v.push_back({i, time_base + i});
	return v;
}
} // namespace

TEST(autosave_names)
{
	CHECK_EQ(slot_name(3), std::string("coop_auto_3"));
	CHECK_EQ(slot_name(1), std::string("coop_auto_1"));
	CHECK_EQ(slot_name(10), std::string("coop_auto_10"));

	uint32_t i = 0;
	REQUIRE(parse_slot("coop_auto_7", i));
	CHECK_EQ(i, uint32_t(7));
	REQUIRE(parse_slot("coop_auto_10", i));
	CHECK_EQ(i, uint32_t(10));
	REQUIRE(parse_slot("coop_auto_123456789", i));
	CHECK_EQ(i, uint32_t(123456789));

	// What slot_name makes, parse_slot reads back.
	for (uint32_t k = 1; k <= 25; ++k)
	{
		uint32_t back = 0;
		REQUIRE(parse_slot(slot_name(k), back));
		CHECK_EQ(back, k);
	}

	// Anything else is not ours.
	const char* bad[] = {
		"coop_auto_0", "coop_auto_", "coop_auto_3a", "quicksave", "", "x", "coop_auto_x", "coop_auto", "coop_auto_-1",
		"coop_auto_07", "coop_auto_3.sav", " coop_auto_3", "coop_auto_3 ", "Coop_Auto_3", "coop_autosave_3",
		"xcoop_auto_3", "coop_auto_3_4", "coop_auto_1234567890", "coop_auto_99999999999999999999",
		// F3 T12: the name a save is written under before it is moved to its slot (coop_autosave.cpp kTempStem): never a slot
		"coop_auto_tmp", "coop_auto_tmp.scop",
	};
	for (const char* name : bad)
	{
		uint32_t keep = 4242;
		if (parse_slot(name, keep))
			t::report_failure(__FILE__, __LINE__, std::string("parse_slot accepted \"") + name + "\"");
		if (keep != 4242)
			t::report_failure(__FILE__, __LINE__, std::string("parse_slot changed the index on \"") + name + "\"");
	}
	CHECK(!parse_slot(std::string("coop_auto_1\0", 12), i));
}

TEST(autosave_next_slot_fills_gaps)
{
	CHECK_EQ(next_slot(slots({1, 2, 4}), 10), uint32_t(3));
	CHECK_EQ(next_slot({}, 10), uint32_t(1));
	CHECK_EQ(next_slot(slots({1, 2, 3}), 10), uint32_t(4));
	CHECK_EQ(next_slot(slots({2, 3, 4}), 10), uint32_t(1));
	CHECK_EQ(next_slot(range(2, 10), 10), uint32_t(1));
	CHECK_EQ(next_slot(range(1, 9), 10), uint32_t(10));
	// The order of the list does not matter.
	CHECK_EQ(next_slot(slots({4, 1, 2}), 10), uint32_t(3));
	// A gap wins over age: slot 3 is free although slot 1 is the oldest.
	std::vector<SlotInfo> v = {{1, 1}, {2, 500}, {4, 900}};
	CHECK_EQ(next_slot(v, 10), uint32_t(3));
}

TEST(autosave_next_slot_oldest)
{
	// All ten taken, 6 is the oldest.
	std::vector<SlotInfo> v = range(1, 10, 5000);
	v[5].file_time = 100; // index 6
	CHECK_EQ(next_slot(v, 10), uint32_t(6));

	// The newest is the last one written: the next goes round to the oldest, not to the lowest.
	std::vector<SlotInfo> w = range(1, 10, 1000);
	w[9].file_time = 9999; // 10 is the newest
	w[0].file_time = 2000; // 1 is not the oldest any more
	w[1].file_time = 900;  // 2 is
	CHECK_EQ(next_slot(w, 10), uint32_t(2));

	// Equal times: the lowest index.
	std::vector<SlotInfo> e;
	for (uint32_t i = 1; i <= 10; ++i)
		e.push_back({i, 777});
	CHECK_EQ(next_slot(e, 10), uint32_t(1));
}

TEST(autosave_next_slot_count_shrunk)
{
	// Ten files on disk, the host now keeps five: the oldest among 1..5, whatever the others are.
	std::vector<SlotInfo> v = range(1, 10, 5000);
	v[7].file_time = 1; // slot 8 is the oldest of all, but out of range
	v[2].file_time = 50; // slot 3 is the oldest of 1..5
	CHECK_EQ(next_slot(v, 5), uint32_t(3));

	// A free place inside the range is used even if the files outside are old.
	std::vector<SlotInfo> g = {{1, 10}, {2, 20}, {8, 1}, {9, 2}};
	CHECK_EQ(next_slot(g, 5), uint32_t(3));

	// The range grew: the new places are free.
	CHECK_EQ(next_slot(range(1, 5), 10), uint32_t(6));

	// Index 0 is not a slot.
	std::vector<SlotInfo> z = {{0, 1}, {1, 5}};
	CHECK_EQ(next_slot(z, 3), uint32_t(2));

	// No place at all is no place: one slot is the least that rotates.
	CHECK_EQ(next_slot({}, 0), uint32_t(1));
	CHECK_EQ(next_slot(slots({1}), 0), uint32_t(1));
}

TEST(autosave_timer)
{
	Schedule s;
	constexpr uint32_t kBusyLimit = 120000;
	CHECK(!timer_due(s, 0, 10, false, kBusyLimit));
	CHECK(!timer_due(s, 599999, 10, false, kBusyLimit));
	CHECK(timer_due(s, 600000, 10, false, kBusyLimit));
	CHECK_EQ(s.last_ms, uint64_t(600000));
	CHECK_EQ(s.busy_since, uint64_t(0));

	// The next term is one interval after the save, not after the call that noticed it.
	CHECK(!timer_due(s, 600001, 10, false, kBusyLimit));
	CHECK(!timer_due(s, 1199999, 10, false, kBusyLimit));
	CHECK(timer_due(s, 1200000, 10, false, kBusyLimit));
	CHECK_EQ(s.last_ms, uint64_t(1200000));

	// A late call: the save is due, and the clock restarts from that call.
	Schedule late;
	CHECK(timer_due(late, 700000, 10, false, kBusyLimit));
	CHECK_EQ(late.last_ms, uint64_t(700000));
	CHECK(!timer_due(late, 1299999, 10, false, kBusyLimit));
	CHECK(timer_due(late, 1300000, 10, false, kBusyLimit));

	// The interval is read at every call.
	Schedule sh;
	CHECK(!timer_due(sh, 299999, 5, false, kBusyLimit));
	CHECK(timer_due(sh, 300000, 5, false, kBusyLimit));
	CHECK(!timer_due(sh, 300001, 20, false, kBusyLimit));
	CHECK(timer_due(sh, 300000 + 20 * kMinute, 20, false, kBusyLimit));
}

TEST(autosave_timer_postpone)
{
	// Review Focus 3: the host is dead (or fighting) when the term comes. The save waits up to max_postpone, then is
	// written anyway.
	Schedule s;
	constexpr uint32_t kBusyLimit = 120000;
	CHECK(!timer_due(s, 599999, 10, true, kBusyLimit)); // not due yet: busy changes nothing
	CHECK_EQ(s.busy_since, uint64_t(0));
	CHECK(!timer_due(s, 600000, 10, true, kBusyLimit)); // due, busy: postponed
	CHECK_EQ(s.busy_since, uint64_t(600000));
	CHECK_EQ(s.last_ms, uint64_t(0));
	CHECK(!timer_due(s, 660000, 10, true, kBusyLimit));
	CHECK(!timer_due(s, 719000, 10, true, kBusyLimit)); // 119 s
	CHECK(timer_due(s, 720000, 10, true, kBusyLimit));  // the 120th second
	CHECK_EQ(s.last_ms, uint64_t(720000));
	CHECK_EQ(s.busy_since, uint64_t(0));

	// The next interval counts from the save.
	CHECK(!timer_due(s, 1319999, 10, false, kBusyLimit));
	CHECK(timer_due(s, 1320000, 10, false, kBusyLimit));
}

TEST(autosave_timer_postpone_ends_when_free)
{
	Schedule s;
	constexpr uint32_t kBusyLimit = 120000;
	CHECK(!timer_due(s, 600000, 10, true, kBusyLimit));
	CHECK(!timer_due(s, 650000, 10, true, kBusyLimit));
	// The host is alive again after 50 s: the save is written at once.
	CHECK(timer_due(s, 650001, 10, false, kBusyLimit));
	CHECK_EQ(s.last_ms, uint64_t(650001));
	CHECK_EQ(s.busy_since, uint64_t(0));

	// A new term, a new wait of its own (the old one does not eat the new one).
	CHECK(!timer_due(s, 650001 + 600000, 10, true, kBusyLimit));
	CHECK(!timer_due(s, 650001 + 600000 + 119999, 10, true, kBusyLimit));
	CHECK(timer_due(s, 650001 + 600000 + 120000, 10, true, kBusyLimit));
}

TEST(autosave_timer_no_postpone)
{
	// max_postpone 0: busy never delays the save.
	Schedule s;
	CHECK(timer_due(s, 600000, 10, true, 0));
	CHECK_EQ(s.last_ms, uint64_t(600000));
}

TEST(autosave_interval_zero_off)
{
	Schedule s;
	CHECK(!timer_due(s, 0, 0, false, 120000));
	CHECK(!timer_due(s, 600000, 0, false, 120000));
	CHECK(!timer_due(s, 99999999, 0, false, 120000));
	CHECK(!timer_due(s, 99999999, 0, true, 120000));
	CHECK(!timer_due(s, 999999999, 0, true, 0));
	CHECK_EQ(s.last_ms, uint64_t(0));
	CHECK_EQ(s.busy_since, uint64_t(0));

	// Turned on later: the term counts from the start of the clock.
	CHECK(timer_due(s, 600000, 10, false, 120000));
}

TEST(autosave_timer_clock_back)
{
	// The host clock went back (a loaded save): no save out of nothing; the count restarts from the new time.
	Schedule s;
	REQUIRE(timer_due(s, 600000, 10, false, 120000));
	CHECK(!timer_due(s, 1000, 10, false, 120000));
	CHECK(!timer_due(s, 600999, 10, false, 120000));
	CHECK(timer_due(s, 601000, 10, false, 120000));
}

namespace
{
std::vector<uint32_t> prune(const std::vector<SlotInfo>& v, uint32_t count, uint32_t keep)
{
	return slots_to_prune(v, count, keep);
}
} // namespace

TEST(autosave_prune_oldest_beyond_count)
{
	// F3 T12 round 1: the host keeps `count` slot files. Five on disk, count 3, the save just went to slot 1 (newest):
	// the three newest stay (1, 5, 4), the oldest go, oldest first.
	const std::vector<SlotInfo> v = {{1, 1006}, {2, 1002}, {3, 1003}, {4, 1004}, {5, 1005}};
	const std::vector<uint32_t> gone = prune(v, 3, 1);
	REQUIRE(gone.size() == size_t(2));
	CHECK_EQ(gone[0], uint32_t(2));
	CHECK_EQ(gone[1], uint32_t(3));

	// The count shrunk from 10 to 5 (files 1..10, slot 10 the newest, the save went to slot 1): keeps 1, 10, 9, 8, 7.
	std::vector<SlotInfo> w = range(1, 10, 1000);
	w[0].file_time = 2000;
	const std::vector<uint32_t> six = prune(w, 5, 1);
	REQUIRE(six.size() == size_t(5));
	for (size_t i = 0; i < six.size(); ++i)
		CHECK_EQ(six[i], uint32_t(i + 2)); // 2, 3, 4, 5, 6

	// Count 1: only the file just written stays.
	const std::vector<uint32_t> one = prune(v, 1, 4);
	REQUIRE(one.size() == size_t(4));
	for (const uint32_t i : one)
		CHECK(i != 4);
}

TEST(autosave_prune_nothing_to_do)
{
	CHECK(prune({}, 10, 1).empty());
	CHECK(prune(range(1, 3), 3, 1).empty()); // exactly count
	CHECK(prune(range(1, 3), 10, 3).empty()); // fewer than count
	CHECK(prune(range(1, 10), 10, 4).empty()); // the full ring
}

TEST(autosave_prune_keeps_the_written_slot)
{
	// The slot just written stays even when the clock cannot tell it from the others (file times are seconds): equal
	// times, the lower index counts as older (the order next_slot overwrites in).
	const std::vector<SlotInfo> tie = {{3, 1000}, {5, 1000}, {7, 1000}, {9, 1000}};
	const std::vector<uint32_t> a = prune(tie, 2, 7);
	REQUIRE(a.size() == size_t(2));
	CHECK_EQ(a[0], uint32_t(3));
	CHECK_EQ(a[1], uint32_t(5));

	// ... and even when its file looks the oldest of all.
	const std::vector<SlotInfo> odd = {{1, 10}, {2, 500}, {3, 600}};
	const std::vector<uint32_t> b = prune(odd, 2, 1);
	REQUIRE(b.size() == size_t(1));
	CHECK_EQ(b[0], uint32_t(2));

	// A slot that is not in the list protects nobody.
	const std::vector<uint32_t> c = prune(range(1, 4, 100), 2, 99);
	REQUIRE(c.size() == size_t(2));
	CHECK_EQ(c[0], uint32_t(1));
	CHECK_EQ(c[1], uint32_t(2));
}

TEST(autosave_prune_edges)
{
	// A slot listed twice counts once, with its newer time.
	const std::vector<SlotInfo> twice = {{1, 100}, {2, 200}, {2, 50}, {3, 300}};
	const std::vector<uint32_t> a = prune(twice, 2, 3);
	REQUIRE(a.size() == size_t(1));
	CHECK_EQ(a[0], uint32_t(1));

	// Count 0 is taken as 1, like next_slot.
	const std::vector<uint32_t> z = prune(range(1, 3), 0, 2);
	REQUIRE(z.size() == size_t(2));
	CHECK(z[0] != 2 && z[1] != 2);

	// Index 0 is not a slot: never deleted, never counted.
	const std::vector<SlotInfo> zero = {{0, 1}, {1, 5}, {2, 6}};
	const std::vector<uint32_t> b = prune(zero, 1, 2);
	REQUIRE(b.size() == size_t(1));
	CHECK_EQ(b[0], uint32_t(1));
}
