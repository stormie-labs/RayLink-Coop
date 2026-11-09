// Anomaly Coop unit tests: where a client's clone of its weapon goes (coop_clone_slot.h).
// Live report 2026-11-08 (stable 41.6, G.A.M.M.A.): a client fitted a scope to the SR-3M in his slot, the new weapon went
// into the backpack. Stock _g.alife_clone_weapon releases the old weapon before it registers the clone, so the clone finds
// the slot free; on a client the old weapon stays until the host's destroy (its release goes with the clone), the clone
// spawned beside it and the engine put it into the backpack.
#include "test_util.h"

#include "coop_clone_slot.h"

using namespace coop;

namespace
{
constexpr std::uint16_t kRifle = 2;
}

TEST(clone_slot_clone_takes_its_source_slot)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK_EQ(b.size(), 1u);
	CHECK_EQ(b.spawn_slot(901, true), cloneslot::kNone); // another item: the engine's default
	CHECK_EQ(b.spawn_slot(900, true), kRifle);
	CHECK_EQ(b.peek(900), cloneslot::kNone);
	CHECK_EQ(b.spawn_slot(900, true), cloneslot::kNone); // once
	CHECK_EQ(b.size(), 1u); // kept until the host's final answer
}

TEST(clone_slot_peek_does_not_use_the_plan)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK_EQ(b.peek(900), kRifle);
	CHECK_EQ(b.peek(901), cloneslot::kNone);
	CHECK_EQ(b.size(), 1u);
	CHECK(b.refused(900, 1100));
	CHECK_EQ(b.peek(900), cloneslot::kNone); // refused: its slot is the source's again
}

TEST(clone_slot_taken_slot_leaves_the_engine_default)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK_EQ(b.spawn_slot(900, false), cloneslot::kNone); // something else took it meanwhile: never overwritten
	CHECK_EQ(b.size(), 1u); // refusal still has to restore the source's placement
}

TEST(clone_slot_refused_clone_gives_the_slot_back_to_its_source)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK(b.refused(900, 1100));
	CHECK(!b.refused(901, 1100)); // no plan
	std::uint16_t source = 0, slot = 0;
	CHECK(!b.restore(source, slot)); // GE_DESTROY may still be queued
	b.restored(800); // no early acknowledgement may lose the rollback
	b.removed(900, 1200);
	CHECK(b.restore(source, slot));
	CHECK_EQ(source, 800);
	CHECK_EQ(slot, kRifle);
	b.restored(800);
	CHECK(!b.restore(source, slot));
	CHECK_EQ(b.size(), 0u);
}

TEST(clone_slot_spawned_clone_can_be_refused)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK_EQ(b.spawn_slot(900, true), kRifle);
	CHECK(b.refused(900, 1100)); // a local spawn is speculative until the host answers
	std::uint16_t source = 0, slot = 0;
	CHECK(!b.restore(source, slot));
	b.removed(900, 1200);
	CHECK(b.restore(source, slot));
	CHECK_EQ(source, 800);
	CHECK_EQ(slot, kRifle);
	b.restored(800);
	CHECK_EQ(b.size(), 0u);
}

TEST(clone_slot_unresolved_plans_survive_long_queues)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	b.plan(902, 802, 3, 1000);
	b.plan(904, 804, 4, 1000);
	CHECK_EQ(b.spawn_slot(904, true), 4);
	CHECK(b.refused(902, 1000));
	b.expire(1000 + cloneslot::kKeepMs - 1);
	CHECK_EQ(b.size(), 3u);
	b.expire(1000 + cloneslot::kKeepMs + 1);
	CHECK_EQ(b.size(), 3u); // neither a pending answer nor an unfinished destroy may lose the plan
}

TEST(clone_slot_confirmation_discards_a_spawned_plan)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK_EQ(b.spawn_slot(900, true), kRifle);
	b.confirmed(901); // another item cannot settle this plan
	CHECK_EQ(b.size(), 1u);
	b.confirmed(900);
	b.confirmed(900); // duplicate answer
	CHECK_EQ(b.size(), 0u);
	CHECK(!b.refused(900, 1100));
}

TEST(clone_slot_confirmation_before_spawn_keeps_the_placement)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	b.confirmed(900);
	b.expire(1000 + cloneslot::kKeepMs + 1);
	CHECK_EQ(b.peek(900), kRifle);
	CHECK(!b.refused(900, 1100));
	CHECK_EQ(b.spawn_slot(900, true), kRifle);
	CHECK_EQ(b.size(), 0u);
}

TEST(clone_slot_refusal_waits_for_removal_even_if_the_slot_is_free)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK_EQ(b.spawn_slot(900, false), cloneslot::kNone); // the clone went to the backpack
	CHECK(b.refused(900, 1100));
	b.confirmed(900); // an incompatible late outcome cannot undo the refusal
	std::uint16_t source = 0, slot = 0;
	CHECK(!b.restore(source, slot));
	b.removed(900, 1200);
	CHECK(b.restore(source, slot));
	CHECK_EQ(source, 800);
	CHECK_EQ(slot, kRifle);
}

TEST(clone_slot_one_teardown_does_not_block_another_ready_restore)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	b.plan(902, 802, 3, 1000);
	CHECK(b.refused(900, 1100));
	CHECK(b.refused(902, 1100));
	b.removed(901, 1200); // unknown removal
	b.removed(902, 1200);
	std::uint16_t source = 0, slot = 0;
	CHECK(b.restore(source, slot));
	CHECK_EQ(source, 802);
	CHECK_EQ(slot, 3);
	b.restored(source);
	CHECK(!b.restore(source, slot));
	CHECK_EQ(b.size(), 1u);
}

TEST(clone_slot_only_finished_rollbacks_expire_from_the_removal_time)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK(b.refused(900, 1100));
	b.removed(900, 100000);
	b.removed(900, 130000); // duplicate removal must not extend the deadline
	b.expire(99999); // no unsigned clock underflow
	CHECK_EQ(b.size(), 1u);
	b.expire(160000);
	std::uint16_t source = 0, slot = 0;
	CHECK(b.restore(source, slot)); // an occupied slot may be retried throughout the grace period
	b.expire(160001);
	CHECK(!b.restore(source, slot));
	CHECK_EQ(b.size(), 0u);
}

TEST(clone_slot_removal_before_the_answer_does_not_restore_an_accepted_source)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	b.removed(900, 1100);
	CHECK_EQ(b.spawn_slot(900, true), cloneslot::kNone);
	std::uint16_t source = 0, slot = 0;
	CHECK(!b.restore(source, slot));
	b.confirmed(900);
	CHECK_EQ(b.size(), 0u);
}

TEST(clone_slot_clear)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	b.clear();
	CHECK_EQ(b.size(), 0u);
	CHECK_EQ(b.spawn_slot(900, true), cloneslot::kNone);
}
