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
		// F3 T12: the names a save is written under (kTempStem) and the old pair of a slot is put aside under (kBackupStem): never slots
		"coop_auto_tmp", "coop_auto_tmp.scop", "coop_auto_bak", "coop_auto_bak.scop",
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

// ---------------------------------------------------------------- F3 T12 fix round 1

TEST(autosave_next_slot_skips_failed)
{
	// M2: a slot whose old files cannot be replaced (read-only, locked) must not stop the rotation: the next one.
	std::vector<SlotInfo> v = range(1, 5, 1000);
	v[2].file_time = 10; // slot 3: the oldest
	v[3].file_time = 20; // slot 4: the next oldest
	CHECK_EQ(next_slot_skipping(v, 5, {}), uint32_t(3)); // nothing skipped: next_slot
	CHECK_EQ(next_slot_skipping(v, 5, {3}), uint32_t(4));
	CHECK_EQ(next_slot_skipping(v, 5, {3, 4}), uint32_t(1));

	// A free slot that fails is skipped too, the next free one is taken.
	CHECK_EQ(next_slot_skipping(slots({1, 2}), 5, {3}), uint32_t(4));

	// Nothing left: 0, never a slot that failed.
	CHECK_EQ(next_slot_skipping(range(1, 3), 3, {1, 2, 3}), uint32_t(0));
	CHECK_EQ(next_slot_skipping({}, 2, {2, 1}), uint32_t(0));

	// Numbers outside 1..count skip nothing.
	CHECK_EQ(next_slot_skipping(range(1, 3), 3, {7, 0}), next_slot(range(1, 3), 3));
}

TEST(autosave_pause_lease)
{
	// I1: the Restore window pauses the autosaves with a lease it has to renew; a window closed in any way stops renewing.
	Pause p;
	CHECK(!pause_holds(p, 1000));
	CHECK(!pause_lapsed(p, 1000));

	pause_hold(p, 1000, 3000);
	CHECK(pause_holds(p, 1000));
	CHECK(pause_holds(p, 3999));
	CHECK(!pause_lapsed(p, 3999));
	CHECK(!pause_holds(p, 4000));
	CHECK(pause_lapsed(p, 4000)); // the lease ran out: reported once
	CHECK(!pause_lapsed(p, 4001));
	CHECK(!pause_holds(p, 4001));
}

TEST(autosave_pause_renew_and_release)
{
	Pause p;
	pause_hold(p, 0, 3000);
	pause_hold(p, 2500, 3000); // renewed
	CHECK(pause_holds(p, 5499));
	CHECK(!pause_holds(p, 5500));

	pause_hold(p, 6000, 3000);
	CHECK(pause_release(p)); // let go on purpose
	CHECK(!pause_holds(p, 6001));
	CHECK(!pause_release(p)); // nothing to let go
	CHECK(!pause_lapsed(p, 99999)); // and not "lapsed" later: released is not expired
}

TEST(autosave_pause_clock_back)
{
	// A clock that went back does not hold a pause for ever.
	Pause p;
	pause_hold(p, 5000, 3000);
	CHECK(!pause_holds(p, 1000));
	CHECK(pause_lapsed(p, 1000));
}

// ---------------------------------------------------------------- one ring per game (menu Task 1)
//
// The host's ring used to be one for every game on the machine: two games rotated over the same coop_auto_1..N and
// overwrote each other. A game id (lower case [0-9a-z-], 1..32) puts its slots in a namespace of their own:
// coop_auto_<id>_<N>. No id keeps the old coop_auto_<N>. coop_auto_tmp / coop_auto_bak stay shared and are no slot anywhere.

namespace
{
const char* const kNamespaces[] = {"", "a", "abc", "ab", "5", "51", "1", "tmp", "bak", "a-1", "1-2", "5-1", "-", "0"};

bool parses(const std::string& stem, const std::string& game, uint32_t* out = nullptr)
{
	uint32_t index = 0;
	const bool ok = parse_slot(stem, index, game);
	if (ok && out)
		*out = index;
	return ok;
}
} // namespace

TEST(autosave_game_id_valid)
{
	const char* good[] = {"a", "0", "-", "tmp", "bak", "5", "abc-def-123", "a-1", "--", "9z", "z9"};
	for (const char* id : good)
		if (!valid_game_id(id))
			t::report_failure(__FILE__, __LINE__, std::string("valid_game_id refused \"") + id + "\"");
	CHECK(valid_game_id(std::string(32, 'a')));
	CHECK(valid_game_id(std::string(32, '7')));
	CHECK(valid_game_id(std::string(31, 'a') + "-"));

	CHECK(!valid_game_id(""));
	CHECK(!valid_game_id(std::string(33, 'a')));
	CHECK(!valid_game_id(std::string(100, 'a')));
	const char* bad[] = {"A", "aB", "a_b", "_", "a b", " a", "a ", "a.b", ".", "..", "a/b", "a\\b", "../x", "a:b", "a*",
	                     "a?", "a\n", "a\t", "a\"", "a<", "a|", "\xC3\xA9", "\xD0\xB8\xD0\xB3\xD1\x80\xD0\xB0", "a%41",
	                     "con.", "a+b", "a=b", "a~1"};
	for (const char* id : bad)
		if (valid_game_id(id))
			t::report_failure(__FILE__, __LINE__, std::string("valid_game_id accepted \"") + id + "\"");
	CHECK(!valid_game_id(std::string("a\0b", 3)));
	CHECK(!valid_game_id(std::string("\0", 1)));
	CHECK(!valid_game_id(std::string("abc\0", 4)));
}

TEST(autosave_game_slot_names)
{
	CHECK_EQ(slot_name(3, "abc"), std::string("coop_auto_abc_3"));
	CHECK_EQ(slot_name(1, "abc"), std::string("coop_auto_abc_1"));
	CHECK_EQ(slot_name(12, "a-b-1"), std::string("coop_auto_a-b-1_12"));
	CHECK_EQ(slot_name(7, "5"), std::string("coop_auto_5_7"));
	CHECK_EQ(slot_name(2, "tmp"), std::string("coop_auto_tmp_2"));
	// No id, or an id that is none: the old name.
	CHECK_EQ(slot_name(3, ""), std::string("coop_auto_3"));
	CHECK_EQ(slot_name(3), std::string("coop_auto_3"));
	CHECK_EQ(slot_name(3, "ABC"), std::string("coop_auto_3"));
	CHECK_EQ(slot_name(3, "a_b"), std::string("coop_auto_3"));
	CHECK_EQ(slot_name(3, "../x"), std::string("coop_auto_3"));
	CHECK_EQ(slot_name(3, std::string(33, 'a')), std::string("coop_auto_3"));
}

TEST(autosave_game_parse_own_slots)
{
	uint32_t i = 0;
	REQUIRE(parse_slot("coop_auto_abc_3", i, "abc"));
	CHECK_EQ(i, uint32_t(3));
	REQUIRE(parse_slot("coop_auto_abc_10", i, "abc"));
	CHECK_EQ(i, uint32_t(10));
	REQUIRE(parse_slot("coop_auto_abc_123456789", i, "abc"));
	CHECK_EQ(i, uint32_t(123456789));
	REQUIRE(parse_slot("coop_auto_a-b-1_12", i, "a-b-1"));
	CHECK_EQ(i, uint32_t(12));
	const std::string longest = std::string(32, 'z');
	REQUIRE(parse_slot("coop_auto_" + longest + "_4", i, longest));
	CHECK_EQ(i, uint32_t(4));

	// What slot_name makes, parse_slot reads back, in the same namespace, for every id.
	for (const char* game : kNamespaces)
		for (uint32_t k = 1; k <= 25; ++k)
		{
			uint32_t back = 0;
			const std::string stem = slot_name(k, game);
			if (!parse_slot(stem, back, game) || back != k)
				t::report_failure(__FILE__, __LINE__, "slot \"" + stem + "\" does not come back in namespace \"" + game + "\"");
		}
}

TEST(autosave_game_parse_rejects_malformed)
{
	const char* bad[] = {
		"coop_auto_abc_0", "coop_auto_abc_", "coop_auto_abc", "coop_auto_abc_3a", "coop_auto_abc_03", "coop_auto_abc__3",
		"coop_auto_abc_3_4", "coop_auto_abc3", "coop_auto_abc_-3", "coop_auto_abc_+3", "coop_auto_abc_3.sav",
		"coop_auto_abc_1234567890", "coop_auto_abc_99999999999999999999", "Coop_Auto_abc_3", "coop_auto_ABC_3",
		" coop_auto_abc_3", "coop_auto_abc_3 ", "xcoop_auto_abc_3", "coop_autosave_abc_3", "coop_auto__3", "coop_auto_abc _3",
		"coop_auto_abc_3.scop",
	};
	for (const char* name : bad)
	{
		uint32_t keep = 4242;
		if (parse_slot(name, keep, "abc"))
			t::report_failure(__FILE__, __LINE__, std::string("parse_slot accepted \"") + name + "\"");
		if (keep != 4242)
			t::report_failure(__FILE__, __LINE__, std::string("parse_slot changed the index on \"") + name + "\"");
	}
	uint32_t i = 4242;
	CHECK(!parse_slot(std::string("coop_auto_abc_1\0", 16), i, "abc"));
	CHECK(!parse_slot(std::string("coop_auto_abc_\0" "1", 16), i, "abc"));
	CHECK_EQ(i, uint32_t(4242));
}

TEST(autosave_game_namespaces_are_apart)
{
	// Every slot a namespace makes is a slot of that namespace and of no other (including the old one with no id): the
	// matrix over ids that are prefixes of each other ("a"/"ab"/"abc", "5"/"51", "1"/"1-2"), digits only ("5", "51", "0"),
	// dashes, and the names of the shared files ("tmp", "bak").
	for (const char* maker : kNamespaces)
		for (uint32_t k : {1u, 2u, 5u, 9u, 10u, 51u, 100u})
		{
			const std::string stem = slot_name(k, maker);
			for (const char* reader : kNamespaces)
			{
				uint32_t got = 0;
				const bool ok = parses(stem, reader, &got);
				const bool mine = std::string(reader) == maker;
				if (ok != mine || (ok && got != k))
					t::report_failure(__FILE__, __LINE__,
					    "\"" + stem + "\" read in namespace \"" + reader + "\": " + (ok ? "a slot" : "not a slot"));
			}
		}
}

TEST(autosave_game_digit_ids_do_not_leak_into_the_old_ring)
{
	// id "5": coop_auto_5_1 must not read as slot 5 (or anything) of the old ring, and the old coop_auto_5 is not a slot of
	// game "5". The old rule rejects everything but digits after the prefix; it must keep doing it.
	CHECK(!parses("coop_auto_5_1", ""));
	CHECK(!parses("coop_auto_51", "5"));
	CHECK(!parses("coop_auto_5", "5"));
	CHECK(!parses("coop_auto_5_", "5"));
	CHECK(!parses("coop_auto_12_3", ""));
	uint32_t i = 0;
	REQUIRE(parses("coop_auto_5", "", &i));
	CHECK_EQ(i, uint32_t(5));
	REQUIRE(parses("coop_auto_5_1", "5", &i));
	CHECK_EQ(i, uint32_t(1));
	// "5" is a prefix of "51" and of "5-1": a game's slots are not read in the shorter id's namespace.
	CHECK(!parses("coop_auto_51_2", "5"));
	CHECK(!parses("coop_auto_5-1_2", "5"));
	CHECK(!parses("coop_auto_5_12", "51"));
	REQUIRE(parses("coop_auto_5_12", "5", &i));
	CHECK_EQ(i, uint32_t(12));
}

TEST(autosave_game_shared_names_are_no_slot_anywhere)
{
	// coop_auto_tmp / coop_auto_bak (kTempStem, kBackupStem) are shared by every game and never a slot. That includes the
	// namespaces named "tmp" and "bak": their slots are coop_auto_tmp_<N>, a different name.
	for (const char* game : kNamespaces)
		for (const char* shared : {"coop_auto_tmp", "coop_auto_bak", "coop_auto_tmp.scop", "coop_auto_bak.scoc", "coop_auto_tmp_",
		                           "coop_auto_bak_", "coop_auto_tmp_0", "coop_auto_bak_0"})
			if (parses(shared, game))
				t::report_failure(__FILE__, __LINE__, std::string("\"") + shared + "\" is a slot in namespace \"" + game + "\"");

	uint32_t i = 0;
	REQUIRE(parses("coop_auto_tmp_1", "tmp", &i));
	CHECK_EQ(i, uint32_t(1));
	REQUIRE(parses("coop_auto_bak_2", "bak", &i));
	CHECK_EQ(i, uint32_t(2));
	// A game "tmp" still does not own the shared temporary pair, and the shared pair is not in its ring.
	CHECK(slot_name(1, "tmp") != "coop_auto_tmp");
	CHECK(slot_name(1, "bak") != "coop_auto_bak");
	CHECK(!parses("coop_auto_tmp", "tmp"));
}

TEST(autosave_game_invalid_id_is_no_id)
{
	// An id that is not valid is no id: the old names, whatever the caller had in mind. (The engine logs it.)
	const char* bad[] = {"ABC", "a_b", "a b", "../x", "a.b", "\xC3\xA9"};
	for (const char* id : bad)
	{
		uint32_t i = 0;
		if (!parse_slot("coop_auto_4", i, id) || i != 4)
			t::report_failure(__FILE__, __LINE__, std::string("the old slot is not read for the invalid id \"") + id + "\"");
		if (parse_slot("coop_auto_abc_4", i, id))
			t::report_failure(__FILE__, __LINE__, std::string("a game slot is read for the invalid id \"") + id + "\"");
		if (slot_name(4, id) != "coop_auto_4")
			t::report_failure(__FILE__, __LINE__, std::string("slot_name made a game name for the invalid id \"") + id + "\"");
	}
	uint32_t i = 0;
	CHECK(parse_slot("coop_auto_4", i, std::string(33, 'a')));
	// ... but a valid id keeps the old ring out.
	CHECK(!parse_slot("coop_auto_4", i, "abc"));
}

namespace
{
// A saves folder with the old ring, three games and the shared files. Times grow with the index inside a ring.
std::vector<NamedFile> mixed_folder()
{
	std::vector<NamedFile> f;
	for (uint32_t k = 1; k <= 10; ++k)
		f.push_back({"coop_auto_" + std::to_string(k), 100 + k}); // the old ring: full
	for (uint32_t k = 1; k <= 3; ++k)
		f.push_back({"coop_auto_alpha_" + std::to_string(k), 500 + k});
	for (uint32_t k = 1; k <= 10; ++k)
		f.push_back({"coop_auto_beta_" + std::to_string(k), 900 + k});
	f.push_back({"coop_auto_5_1", 700});
	f.push_back({"coop_auto_5_2", 701});
	f.push_back({"coop_auto_tmp", 999});
	f.push_back({"coop_auto_bak", 998});
	f.push_back({"quicksave", 1000});
	f.push_back({"vasya - autosave", 1001});
	f.push_back({"coop_auto_alpha_07", 1}); // not a slot
	f.push_back({"coop_auto_gamma_1", 3}); // a game that is not asked for
	return f;
}

std::vector<uint32_t> indices_of(const std::vector<SlotInfo>& v)
{
	std::vector<uint32_t> r;
	for (const SlotInfo& s : v)
		r.push_back(s.index);
	std::sort(r.begin(), r.end());
	return r;
}
} // namespace

TEST(autosave_game_listing_sees_only_its_ring)
{
	const std::vector<NamedFile> folder = mixed_folder();

	const std::vector<SlotInfo> alpha = slots_of_game(folder, "alpha");
	CHECK(indices_of(alpha) == (std::vector<uint32_t>{1, 2, 3}));
	for (const SlotInfo& s : alpha)
		CHECK_EQ(s.file_time, uint64_t(500 + s.index));

	CHECK(indices_of(slots_of_game(folder, "beta")).size() == size_t(10));
	CHECK(indices_of(slots_of_game(folder, "5")) == (std::vector<uint32_t>{1, 2}));
	CHECK(indices_of(slots_of_game(folder, "gamma")) == (std::vector<uint32_t>{1}));
	CHECK(indices_of(slots_of_game(folder, "nobody")).empty());

	// The old ring: only coop_auto_<N>; the game slots with digits in the id do not spill into it.
	const std::vector<SlotInfo> old = slots_of_game(folder, "");
	CHECK(old.size() == size_t(10));
	for (const SlotInfo& s : old)
		CHECK_EQ(s.file_time, uint64_t(100 + s.index));
	// An invalid id is no id.
	CHECK(slots_of_game(folder, "BAD").size() == size_t(10));
	CHECK(slots_of_game({}, "alpha").empty());
}

TEST(autosave_game_rotation_in_its_own_ring)
{
	const std::vector<NamedFile> folder = mixed_folder();

	// alpha has three of ten: the next save takes the free slot 4, although the old ring and beta are full.
	CHECK_EQ(next_slot(slots_of_game(folder, "alpha"), 10), uint32_t(4));
	// beta is full: the oldest of beta, 1 (not the older files of the old ring or of another game).
	CHECK_EQ(next_slot(slots_of_game(folder, "beta"), 10), uint32_t(1));
	// The old ring is full as well, and its oldest is its own 1.
	CHECK_EQ(next_slot(slots_of_game(folder, ""), 10), uint32_t(1));
	// A game with nothing yet starts at 1 whatever the others hold.
	CHECK_EQ(next_slot(slots_of_game(folder, "nobody"), 10), uint32_t(1));
	// Slots that failed are skipped inside the ring only.
	CHECK_EQ(next_slot_skipping(slots_of_game(folder, "alpha"), 10, {4}), uint32_t(5));

	// Pruning down to 2 after a save to alpha 3: alpha 1 goes, no file of another game or of the old ring is named.
	const std::vector<uint32_t> gone = slots_to_prune(slots_of_game(folder, "alpha"), 2, 3);
	REQUIRE(gone.size() == size_t(1));
	CHECK_EQ(gone[0], uint32_t(1));
	CHECK_EQ(slot_name(gone[0], "alpha"), std::string("coop_auto_alpha_1"));
	// Pruning beta (full, count 3, the save went to 1) names beta files only.
	const std::vector<uint32_t> beta_gone = slots_to_prune(slots_of_game(folder, "beta"), 3, 1);
	CHECK(beta_gone.size() == size_t(7));
	for (const uint32_t k : beta_gone)
	{
		const std::string name = slot_name(k, "beta");
		bool found = false;
		for (const NamedFile& f : folder)
			found = found || f.stem == name;
		if (!found || name.find("beta") == std::string::npos)
			t::report_failure(__FILE__, __LINE__, "pruning beta named " + name);
	}
}

TEST(autosave_game_legacy_files_stay_while_a_game_is_set)
{
	// With a game set, every file name the ring can touch (next_slot, slots_to_prune, slot_name) is a game name; a file of
	// the old ring is never one of them.
	const std::vector<NamedFile> folder = mixed_folder();
	for (const char* game : {"alpha", "beta", "5", "gamma"})
	{
		const std::vector<SlotInfo> mine = slots_of_game(folder, game);
		const uint32_t next = next_slot(mine, 10);
		std::vector<uint32_t> touched = slots_to_prune(mine, 1, next);
		touched.push_back(next);
		REQUIRE(touched.size() >= size_t(1));
		for (const uint32_t k : touched)
		{
			uint32_t back = 0;
			const std::string name = slot_name(k, game);
			if (parse_slot(name, back, ""))
				t::report_failure(__FILE__, __LINE__, "the old ring owns \"" + name + "\"");
			const std::string prefix = std::string("coop_auto_") + game + "_";
			if (name.compare(0, prefix.size(), prefix) != 0)
				t::report_failure(__FILE__, __LINE__, "\"" + name + "\" is not a slot of game " + game);
		}
	}
}

TEST(autosave_ring_set_game)
{
	Ring r;
	CHECK(r.game.empty());
	CHECK(r.bad_slots.empty());

	// The first game: a change.
	SetGameResult s = ring_set_game(r, "alpha");
	CHECK(s.accepted);
	CHECK(s.changed);
	CHECK_EQ(r.game, std::string("alpha"));

	// The same game again, as often as wanted: nothing changes, the memory of bad slots stays.
	ring_mark_bad(r, "alpha", 3);
	ring_mark_bad(r, "alpha", 5);
	for (int i = 0; i < 3; ++i)
	{
		s = ring_set_game(r, "alpha");
		CHECK(s.accepted);
		CHECK(!s.changed);
	}
	CHECK(ring_bad(r, "alpha") == (std::vector<uint32_t>{3, 5}));

	// Another game: the bad slots of the first are not the second's.
	s = ring_set_game(r, "beta");
	CHECK(s.accepted);
	CHECK(s.changed);
	CHECK_EQ(r.game, std::string("beta"));
	CHECK(ring_bad(r, "beta").empty());
	CHECK(r.bad_slots.empty());

	// Back to the first one: it starts clean (the files may have been fixed meanwhile).
	ring_mark_bad(r, "beta", 2);
	s = ring_set_game(r, "alpha");
	CHECK(s.changed);
	CHECK(ring_bad(r, "alpha").empty());
}

TEST(autosave_ring_set_game_none)
{
	Ring r;
	// "" is a valid way to say "no game": the old ring.
	SetGameResult s = ring_set_game(r, "");
	CHECK(s.accepted);
	CHECK(!s.changed);
	ring_mark_bad(r, "", 4);
	s = ring_set_game(r, "");
	CHECK(!s.changed);
	CHECK(ring_bad(r, "") == (std::vector<uint32_t>{4}));

	s = ring_set_game(r, "alpha");
	CHECK(s.changed);
	ring_mark_bad(r, "alpha", 1);
	s = ring_set_game(r, "");
	CHECK(s.accepted);
	CHECK(s.changed);
	CHECK(r.game.empty());
	CHECK(r.bad_slots.empty());
}

TEST(autosave_ring_set_game_invalid)
{
	// An id that is not valid is no id: the old ring, and the caller is told (accepted = false) so the engine can log it.
	Ring r;
	ring_set_game(r, "alpha");
	ring_mark_bad(r, "alpha", 2);
	SetGameResult s = ring_set_game(r, "Bad_Id");
	CHECK(!s.accepted);
	CHECK(s.changed); // from "alpha" to the old ring
	CHECK(r.game.empty());
	CHECK(r.bad_slots.empty());

	// Already in the old ring: nothing changes, the memory of its bad slots stays, the answer is still "not accepted".
	ring_mark_bad(r, "", 7);
	s = ring_set_game(r, std::string(40, 'x'));
	CHECK(!s.accepted);
	CHECK(!s.changed);
	CHECK(ring_bad(r, "") == (std::vector<uint32_t>{7}));

	s = ring_set_game(r, std::string("a\0b", 3));
	CHECK(!s.accepted);
	CHECK(r.game.empty());
}

TEST(autosave_ring_bad_slots_belong_to_a_game)
{
	Ring r;
	ring_set_game(r, "alpha");
	ring_mark_bad(r, "alpha", 4);
	ring_mark_bad(r, "alpha", 4); // once
	ring_mark_bad(r, "alpha", 2);
	CHECK(ring_bad(r, "alpha") == (std::vector<uint32_t>{4, 2}));

	// A save that began in another game (the namespace changed under it) neither reads nor writes this ring's memory.
	CHECK(ring_bad(r, "beta").empty());
	CHECK(ring_bad(r, "").empty());
	ring_mark_bad(r, "beta", 9);
	ring_mark_bad(r, "", 8);
	CHECK(ring_bad(r, "alpha") == (std::vector<uint32_t>{4, 2}));
	CHECK(ring_bad(r, "beta").empty());

	// Index 0 is not a slot.
	ring_mark_bad(r, "alpha", 0);
	CHECK(ring_bad(r, "alpha").size() == size_t(2));
}
