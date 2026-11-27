// Anomaly Coop unit tests: what the world server does with a map server's body report (srv/coop_levels_wire.h,
// body_report_verdict / body_crossing_age / body_crossing_verdict). Stand b57g creator10_server (2026-11-21): a report that
// crossed the player's level move was refused with a "!" line although nothing was wrong; a map server that never lets a
// player go must still be refused.
#include "test_util.h"
#include "srv/coop_levels_wire.h"

using namespace coop;
using namespace coop::levels::wire;

namespace
{
constexpr uint16_t kEscape = 2;
constexpr uint16_t kGarbage = 3;

BodyReport verdict(uint16_t seat, bool online_here = false, bool player = true, uint16_t body = kEscape,
    uint16_t sender = kEscape, bool read = true, bool known = true, bool position = true, bool sender_writes = true)
{
	return body_report_verdict(read, known, online_here, player, body, sender, seat, position, sender_writes);
}
} // namespace

TEST(levels_body_report_takes_a_player_on_his_senders_level)
{
	CHECK(verdict(kEscape) == BodyReport::Take);
}

TEST(levels_body_report_crossed_his_move)
{
	// his seat is on the Garbage already, the Cordon's map server still reports him
	CHECK(verdict(kGarbage) == BodyReport::Crossed);
	CHECK(verdict(kNoLevel) == BodyReport::Crossed); // between two levels
}

TEST(levels_body_report_faults_of_the_sender_stay_refused)
{
	CHECK(verdict(kEscape, true) == BodyReport::Refused);                                        // online here
	CHECK(verdict(kEscape, false, false) == BodyReport::Refused);                                // no player character
	CHECK(verdict(kEscape, false, true, kGarbage) == BodyReport::Refused);                       // vertex not on its level
	CHECK(verdict(kEscape, false, true, kEscape, kNoLevel) == BodyReport::Refused);              // a sender with no level
	CHECK(verdict(kEscape, false, true, kEscape, kEscape, false) == BodyReport::Refused);        // does not read
	CHECK(verdict(kEscape, false, true, kEscape, kEscape, true, false) == BodyReport::Refused);  // no such object
	CHECK(verdict(kEscape, false, true, kEscape, kEscape, true, true, false) == BodyReport::Refused); // not a number
	CHECK(verdict(kGarbage, true) == BodyReport::Refused); // a fault wins over a crossing
}

TEST(levels_body_report_a_crossing_is_honest_within_its_grace)
{
	BodyCrossing c;
	CHECK(body_crossing_age(c, kEscape, kGarbage, 1000) == 0);
	CHECK(body_crossing_verdict(body_crossing_age(c, kEscape, kGarbage, 2000)) == BodyReport::Crossed);
	uint64_t now = 2000;
	uint64_t age = 0;
	while (now < 1000 + kBodyCrossedGraceMs) // a report every second, as a map server sends them
	{
		now += 1000;
		age = body_crossing_age(c, kEscape, kGarbage, now);
	}
	CHECK(age == kBodyCrossedGraceMs && body_crossing_verdict(age) == BodyReport::Crossed);
	// a map server that never lets him go: its fault, refused with its line
	age = body_crossing_age(c, kEscape, kGarbage, now + 1000);
	CHECK(body_crossing_verdict(age) == BodyReport::Refused);
}

TEST(levels_body_report_a_new_run_starts_over)
{
	BodyCrossing c;
	body_crossing_age(c, kEscape, kGarbage, 1000);
	body_crossing_age(c, kEscape, kGarbage, 9000);
	CHECK(body_crossing_age(c, kEscape, kNoLevel, 10000) == 0);                         // another seat
	CHECK(body_crossing_age(c, kGarbage, kNoLevel, 11000) == 0);                        // another sender
	CHECK(body_crossing_age(c, kGarbage, kNoLevel, 11000 + kBodyCrossedGraceMs + 1) == 0); // a long gap
	CHECK(body_crossing_age(c, kGarbage, kNoLevel, 5000) == 0);                         // time went back
}

// The acceptance hands over a report whose sender does not write the character any more (accept::body_report_by_seat): his
// player left that map, so the world parked him or seated him elsewhere before the report arrived. It is a crossing, never a
// placement; a sender that reports the level of his seat without writing him is at fault.
TEST(levels_body_report_of_a_sender_that_does_not_write_him)
{
	const bool writes = false;
	CHECK(verdict(kNoLevel, false, true, kEscape, kEscape, true, true, true, writes) == BodyReport::Crossed); // parked, rejoining
	CHECK(verdict(kGarbage, false, true, kEscape, kEscape, true, true, true, writes) == BodyReport::Crossed); // seated elsewhere
	CHECK(verdict(kEscape, false, true, kEscape, kEscape, true, true, true, writes) == BodyReport::Refused);  // never taken
	CHECK(verdict(kNoLevel, true, true, kEscape, kEscape, true, true, true, writes) == BodyReport::Refused);  // a fault still wins
}
