// Anomaly Coop unit tests: the host's memory of a player's recent talk locks (xrCoop/coop_talks.h, Ruling F2-34,
// F2 T12 round 2). coop_dialog.cpp records every lock that ends; coop.talk_recent answers coop_npc_companions' recruit
// check from it.
#include "test_util.h"

#include "coop_talks.h"

#include <cstdint>

using namespace coop::talks;

namespace
{
constexpr uint16_t kNone = 0xffff;
}

// Holding the lock now, or a lock that ended no more than the window ago.
TEST(talks_recent_window)
{
	Recent r;
	const uint64_t t0 = 100000;
	CHECK(!talked_recently(kNone, r, 201, t0, 5000)); // never talked
	CHECK(talked_recently(201, r, 201, t0, 5000));    // holds it now
	CHECK(!talked_recently(202, r, 201, t0, 5000));   // holds another NPC's
	r.ended(201, t0);
	CHECK(talked_recently(kNone, r, 201, t0 + 2000, 5000)); // ended 2 s ago
	CHECK(talked_recently(kNone, r, 201, t0 + 5000, 5000)); // exactly the window
	CHECK(!talked_recently(kNone, r, 201, t0 + 10000, 5000)); // 10 s ago
	CHECK(!talked_recently(kNone, r, 202, t0 + 1000, 5000)); // not that NPC
	CHECK(talked_recently(kNone, r, 201, t0 - 10, 5000));    // a clock read before the end: still recent
	CHECK(!talked_recently(kNone, r, kNone, t0, 5000));      // "no NPC" never matches
	CHECK(!talked_recently(kNone, r, 201, t0 + 1, 0));       // a zero window: only holding now counts
}

// Bounded: the last kKept ends are kept, the same NPC keeps one entry with its latest end.
TEST(talks_recent_bounded)
{
	Recent r;
	static_assert(Recent::kKept == 2, "two last talks per player");
	r.ended(201, 1000);
	r.ended(202, 2000);
	r.ended(203, 3000); // drops the oldest (201)
	CHECK_EQ(r.size(), size_t(2));
	CHECK(!r.within(201, 3000, 5000));
	CHECK(r.within(202, 3000, 5000));
	CHECK(r.within(203, 3000, 5000));
	r.ended(202, 9000); // the same NPC again: its time moves, nothing else is dropped
	CHECK_EQ(r.size(), size_t(2));
	CHECK(r.within(202, 13000, 5000));
	CHECK(r.within(203, 7000, 5000));
	r.ended(kNone, 9500); // "no NPC" is not recorded
	CHECK_EQ(r.size(), size_t(2));
	CHECK(r.within(203, 7000, 5000));
	r.clear();
	CHECK_EQ(r.size(), size_t(0));
	CHECK(!r.within(202, 9000, 5000));
}
