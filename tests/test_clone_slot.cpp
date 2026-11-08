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
	CHECK_EQ(b.spawn_slot(900, true), cloneslot::kNone); // once
	CHECK_EQ(b.size(), 0u);
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
	CHECK_EQ(b.size(), 0u);
}

TEST(clone_slot_refused_clone_gives_the_slot_back_to_its_source)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK(b.refused(900, 1100));
	CHECK(!b.refused(901, 1100)); // no plan
	std::uint16_t source = 0, slot = 0;
	CHECK(b.restore(source, slot));
	CHECK_EQ(source, 800);
	CHECK_EQ(slot, kRifle);
	b.restored(800);
	CHECK(!b.restore(source, slot));
	CHECK_EQ(b.size(), 0u);
}

TEST(clone_slot_spawned_clone_is_not_restored)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	CHECK_EQ(b.spawn_slot(900, true), kRifle);
	CHECK(!b.refused(900, 1100)); // the slot is the clone's: rolled back, its source goes to the engine default
	std::uint16_t source = 0, slot = 0;
	CHECK(!b.restore(source, slot));
}

TEST(clone_slot_old_plans_expire)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	b.plan(902, 802, 3, 1000);
	CHECK(b.refused(902, 1000));
	b.expire(1000 + cloneslot::kKeepMs - 1);
	CHECK_EQ(b.size(), 2u);
	b.expire(1000 + cloneslot::kKeepMs + 1);
	CHECK_EQ(b.size(), 0u);
	std::uint16_t source = 0, slot = 0;
	CHECK(!b.restore(source, slot));
}

TEST(clone_slot_clear)
{
	cloneslot::Book b;
	b.plan(900, 800, kRifle, 1000);
	b.clear();
	CHECK_EQ(b.size(), 0u);
	CHECK_EQ(b.spawn_slot(900, true), cloneslot::kNone);
}
