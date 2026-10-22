// Anomaly Coop unit tests: the shared sleep decision (coop_rest_rules.h; F3 Task 5, CHECKPOINTS_DEATH.md §4): sleep
// starts only when everybody present rests, nobody fights, nobody is dead and the world allows it.
#include "test_util.h"

#include "coop_rest_rules.h"

using namespace coop::rest;

namespace
{
Member member(uint16_t id, State state, uint8_t hours, bool in_combat = false, bool alive = true)
{
	return Member{id, state, hours, in_combat, alive};
}
} // namespace

TEST(rest_state_names)
{
	CHECK_EQ(std::string(state_name(State::Awake)), std::string("awake"));
	CHECK_EQ(std::string(state_name(State::Resting)), std::string("resting"));
	CHECK_EQ(std::string(state_name(State::Sleeping)), std::string("sleeping"));
}

TEST(rest_all_resting_starts)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Resting, 5)}, false);
	CHECK(d.start);
	CHECK_EQ(int(d.hours), 5); // the shortest wish: nobody sleeps longer than they asked
	CHECK(d.block == Block::None);

	// The order of the members does not matter.
	const Decision r = decide({member(2, State::Resting, 5), member(1, State::Resting, 8)}, false);
	CHECK(r.start);
	CHECK_EQ(int(r.hours), 5);

	const Decision three = decide({member(1, State::Resting, 12), member(2, State::Resting, 4), member(3, State::Resting, 9)}, false);
	CHECK(three.start);
	CHECK_EQ(int(three.hours), 4);
}

TEST(rest_one_awake_waits)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Awake, 8)}, false);
	CHECK(!d.start);
	CHECK(d.block == Block::NotAll);
	CHECK_EQ(int(d.hours), 0);
}

TEST(rest_newcomer_blocks)
{
	// Review Focus 5: two are resting, a third joins awake: the sleep does not start until they rest too.
	const Decision before = decide({member(1, State::Resting, 8), member(2, State::Resting, 8)}, false);
	CHECK(before.start);
	const Decision after = decide({member(1, State::Resting, 8), member(2, State::Resting, 8), member(3, State::Awake, 8)}, false);
	CHECK(!after.start);
	CHECK(after.block == Block::NotAll);
	const Decision joined = decide(
		{member(1, State::Resting, 8), member(2, State::Resting, 8), member(3, State::Resting, 6)}, false);
	CHECK(joined.start);
	CHECK_EQ(int(joined.hours), 6);
}

TEST(rest_already_sleeping_does_not_restart)
{
	// Somebody already asleep is not "resting": the decision is made once, on the transition.
	const Decision d = decide({member(1, State::Sleeping, 8), member(2, State::Sleeping, 8)}, false);
	CHECK(!d.start);
	CHECK(d.block == Block::NotAll);
	const Decision m = decide({member(1, State::Sleeping, 8), member(2, State::Resting, 8)}, false);
	CHECK(!m.start);
}

TEST(rest_combat_blocks)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Resting, 8, true)}, false);
	CHECK(!d.start);
	CHECK(d.block == Block::Combat);
	CHECK_EQ(int(d.hours), 0);
}

TEST(rest_world_blocks)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Resting, 8)}, true);
	CHECK(!d.start);
	CHECK(d.block == Block::World);
	CHECK_EQ(int(d.hours), 0);
	// A single player too.
	CHECK(decide({member(1, State::Resting, 8)}, true).block == Block::World);
}

TEST(rest_dead_blocks)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Resting, 8, false, false)}, false);
	CHECK(!d.start);
	CHECK(d.block == Block::Dead);
	CHECK_EQ(int(d.hours), 0);
	// A dead player who is "awake" blocks as dead, not as "not all".
	CHECK(decide({member(1, State::Resting, 8), member(2, State::Awake, 8, false, false)}, false).block == Block::Dead);
}

TEST(rest_block_priority)
{
	// Dead > Combat > World > NotAll.
	const std::vector<Member> all = {
		member(1, State::Resting, 8, true, true),   // fighting
		member(2, State::Awake, 8, false, false),   // dead
		member(3, State::Awake, 8, false, true),    // not resting
	};
	CHECK(decide(all, true).block == Block::Dead);

	const std::vector<Member> no_dead = {
		member(1, State::Resting, 8, true, true),
		member(3, State::Awake, 8, false, true),
	};
	CHECK(decide(no_dead, true).block == Block::Combat);

	const std::vector<Member> no_fight = {
		member(1, State::Resting, 8, false, true),
		member(3, State::Awake, 8, false, true),
	};
	CHECK(decide(no_fight, true).block == Block::World);
	CHECK(decide(no_fight, false).block == Block::NotAll);
}

TEST(rest_single_player)
{
	const Decision d = decide({member(7, State::Resting, 3)}, false);
	CHECK(d.start);
	CHECK_EQ(int(d.hours), 3);
	CHECK(d.block == Block::None);
	CHECK(!decide({member(7, State::Awake, 3)}, false).start);
}

TEST(rest_nobody_present)
{
	const Decision d = decide({}, false);
	CHECK(!d.start);
	CHECK_EQ(int(d.hours), 0);
	CHECK(d.block == Block::NotAll);
	CHECK(decide({}, true).block == Block::World);
}

TEST(rest_hours_clamp)
{
	CHECK_EQ(int(clamp_hours(0)), 1);
	CHECK_EQ(int(clamp_hours(30)), 24);
	CHECK_EQ(int(clamp_hours(-5)), 1);
	CHECK_EQ(int(clamp_hours(1)), 1);
	CHECK_EQ(int(clamp_hours(12)), 12);
	CHECK_EQ(int(clamp_hours(24)), 24);
	CHECK_EQ(int(clamp_hours(25)), 24);
	CHECK_EQ(int(clamp_hours(1000000)), 24);
	CHECK_EQ(int(clamp_hours(-1000000)), 1);
}

TEST(rest_hours_of_the_decision_are_in_range)
{
	// A member who sent 0 or too much does not make the whole group sleep 0 or 255 hours.
	const Decision zero = decide({member(1, State::Resting, 0), member(2, State::Resting, 8)}, false);
	CHECK(zero.start);
	CHECK_EQ(int(zero.hours), 1);
	const Decision big = decide({member(1, State::Resting, 200), member(2, State::Resting, 255)}, false);
	CHECK(big.start);
	CHECK_EQ(int(big.hours), 24);
}
