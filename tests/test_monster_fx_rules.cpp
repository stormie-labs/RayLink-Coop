// Unit tests: the deadlines of a monster ability's hold of the local actor (coop_monster_fx_rules.h).
#include "test_util.h"

#include "coop_monster_fx_rules.h"

using namespace coop::monster_fx;

TEST(monster_fx_hold_numbers)
{
	CHECK_EQ(kTubePrepareMs, 15000u);
	CHECK_EQ(kTubeSlackMs, 5000u);
	CHECK_EQ(kGripMaxMs, 12000u);
}

TEST(monster_fx_hold_off_never_expires)
{
	ActorHold hold;
	CHECK(!hold.on());
	CHECK(!hold.expired(0));
	CHECK(!hold.expired(0xffffffffu));
}

TEST(monster_fx_hold_expires_after_its_deadline)
{
	ActorHold hold;
	hold.start(1000, kGripMaxMs);
	CHECK(hold.on());
	CHECK(!hold.expired(1000 + kGripMaxMs)); // the deadline itself still holds
	CHECK(hold.expired(1000 + kGripMaxMs + 1));
	hold.stop();
	CHECK(!hold.on());
	CHECK(!hold.expired(1000 + kGripMaxMs + 1));
}

TEST(monster_fx_hold_extend_moves_the_deadline_only)
{
	ActorHold hold;
	hold.extend(0, 10); // a stage of a hold that was never started starts nothing
	CHECK(!hold.on());
	CHECK(!hold.expired(100));

	hold.start(0, kTubePrepareMs);
	hold.extend(100, kTubeSlackMs); // an end: the deadline may come earlier than the preparation's
	CHECK(hold.on());
	CHECK(!hold.expired(100 + kTubeSlackMs));
	CHECK(hold.expired(100 + kTubeSlackMs + 1));
}

TEST(monster_fx_hold_wraps_as_unsigned_time)
{
	// Device.dwTimeGlobal + ms in u32, as the stock time arithmetic does
	ActorHold hold;
	hold.start(0xfffffff0u, 0x20u);
	CHECK(hold.expired(0x11u));
	CHECK(!hold.expired(0x10u));
}
