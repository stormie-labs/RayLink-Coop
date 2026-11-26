// Anomaly Coop unit tests: a spawn whose id a game object on its way out still holds waits for it (TZ P104; Dev 64 crash
// 2026-11-25, Server mode, client "urbanist": "Object with ID already exists! ID=19465 self=sim_default_stalker_019465
// other=sim_default_stalker_019465", the same for 19468, then the process died in the stock soft fail of the half-made
// stalker). Rules: xrCoop/coop_spawn_wait_rules.h; engine: coop_events.cpp client_spawn_gate, Level_network_spawn.cpp
// cl_Process_Spawn (re-queues a waiting M_SPAWN into game_events).
// The decision has no mode input: a Coop client and a Server player both stand in a mirror world (join::world_is_mirror),
// and the guard is Ядро. The scenarios give the facts each mode's client meets at each of the two callers of
// cl_Process_Spawn: ProcessGameEvents (Level.cpp, the direct M_SPAWN: no prefetch, an item without a visual, the loading
// screen) and ProcessSpawnEvents (Level.cpp, an M_SPAWN that waited for its models: stalkers, the crash's path).
#include "test_util.h"

#include "coop_spawn_wait_rules.h"

namespace sw = coop::spawn_wait;
namespace ident = coop::identity;

namespace
{
// client_spawn_gate with the facts it reads: the server entity under the id (entity_here, same_section), the level's game
// object under the id (present, destroying, same_kind: its section is the spawn's), the holder's game object
// (holder_leaving) and the frames this id waited already.
sw::Verdict gate(bool mirror, bool entity_here, bool same_section, bool present, bool destroying, bool same_kind,
    bool holder_leaving, uint32_t waited)
{
	const sw::Holder self = sw::holder_of(present, destroying, same_kind);
	const ident::Spawn v = ident::spawn_verdict(mirror, entity_here, same_section, self == sw::Holder::SameKind);
	return sw::decide(mirror, v, self, holder_leaving, waited);
}

// The spawn of an entity that is here, of its section, with no holder: only the object under the id differs.
sw::Verdict free_entity(bool present, bool destroying, bool same_kind, uint32_t waited)
{
	return gate(true, true, true, present, destroying, same_kind, false, waited);
}
} // namespace

TEST(spawn_wait_holder_of)
{
	CHECK_EQ(sw::holder_of(false, false, false), sw::Holder::None);
	CHECK_EQ(sw::holder_of(false, true, true), sw::Holder::None);
	CHECK_EQ(sw::holder_of(true, true, true), sw::Holder::Leaving);
	CHECK_EQ(sw::holder_of(true, true, false), sw::Holder::Leaving);
	CHECK_EQ(sw::holder_of(true, false, true), sw::Holder::SameKind);
	CHECK_EQ(sw::holder_of(true, false, false), sw::Holder::OtherKind);
}

// Coop mode, the direct caller (ProcessGameEvents): the co-op host switched a rookie squad offline and online again, the
// client applied both EntitySwitch words in one pump, its own server sent GE_DESTROY and M_SPAWN of 19465, and the level ran
// both in one ProcessGameEvents. Before P104 the guard said Make (the object was marked, not live) and the stock check
// failed. Now the spawn waits; the destroy queue takes the old object at the frame's end, the next frame makes it.
TEST(spawn_wait_coop_client_switch_pair_in_one_pump_waits_then_is_made)
{
	sw::WaitBook book;
	const uint16_t stalker = 19465;
	uint32_t frame = 5000;
	CHECK_EQ(free_entity(true, true, true, book.waited(stalker, frame)), sw::Verdict::Wait);
	book.wait(stalker, frame);
	++frame; // the destroy queue ran: no object under the id
	CHECK_EQ(book.waited(stalker, frame), 1u);
	CHECK_EQ(free_entity(false, false, false, book.waited(stalker, frame)), sw::Verdict::Make);
	book.done(stalker);
	CHECK_EQ(book.waited(stalker, frame), 0u);
	CHECK_EQ(book.size(), size_t(0));
}

// Server mode, the prefetch caller (ProcessSpawnEvents): the player's map server decides the switches of its level and they
// reach the player as the same EntitySwitch words; the stalkers' M_SPAWNs waited for their models and ran sorted, both
// top-level spawns first, in the frame whose ProcessGameEvents ran their GE_DESTROYs. The crash log's order: 19465, then
// 19468. Each waits on its own; the next frame makes both.
TEST(spawn_wait_server_client_two_prefetched_stalkers_in_one_frame_wait_each)
{
	sw::WaitBook book;
	const uint16_t first = 19465, second = 19468;
	uint32_t frame = 9000;
	CHECK_EQ(free_entity(true, true, true, book.waited(first, frame)), sw::Verdict::Wait);
	book.wait(first, frame);
	CHECK_EQ(free_entity(true, true, true, book.waited(second, frame)), sw::Verdict::Wait);
	book.wait(second, frame);
	CHECK_EQ(book.size(), size_t(2));
	frame += 2; // the re-queued M_SPAWN goes through the prefetch again: a frame or two later
	CHECK_EQ(free_entity(false, false, false, book.waited(first, frame)), sw::Verdict::Make);
	book.done(first);
	CHECK_EQ(free_entity(false, false, false, book.waited(second, frame)), sw::Verdict::Make);
	book.done(second);
	CHECK_EQ(book.size(), size_t(0));
}

// Both modes: online, offline, online, offline, online in one pump queues two M_SPAWNs of one id behind two GE_DESTROYs.
// The frame counts once; the next frame the first spawn is made and the second is the guard's Duplicate.
TEST(spawn_wait_two_spawns_of_one_id_in_a_frame_count_once_and_make_one_object)
{
	sw::WaitBook book;
	const uint16_t stalker = 19468;
	const uint32_t frame = 300;
	CHECK_EQ(free_entity(true, true, true, book.waited(stalker, frame)), sw::Verdict::Wait);
	book.wait(stalker, frame);
	CHECK_EQ(free_entity(true, true, true, book.waited(stalker, frame)), sw::Verdict::Wait);
	book.wait(stalker, frame);
	CHECK_EQ(book.waited(stalker, frame + 1), 1u);
	CHECK_EQ(free_entity(false, false, false, book.waited(stalker, frame + 1)), sw::Verdict::Make);
	book.done(stalker);
	// the first one is the level's object of the entity now
	CHECK_EQ(free_entity(true, false, true, book.waited(stalker, frame + 1)), sw::Verdict::Refuse);
}

// Both modes, both callers: a stalker's item comes online with it. Its own id is free (the old copy of the item went with
// the old stalker, or it is new), but its holder's object under the holder's id is the old, dying stalker: made now, its
// GE_OWNERSHIP_TAKE would go to that one and the item would die with it. It waits with its holder.
TEST(spawn_wait_item_waits_for_its_dying_holder)
{
	sw::WaitBook book;
	const uint16_t item = 19466;
	const uint32_t frame = 70;
	CHECK_EQ(gate(true, true, true, false, false, false, /*holder_leaving*/ true, book.waited(item, frame)), sw::Verdict::Wait);
	book.wait(item, frame);
	// next frame: the old stalker is gone (the new one is made first, or comes after: the stock order of the queues)
	CHECK_EQ(gate(true, true, true, false, false, false, false, book.waited(item, frame + 1)), sw::Verdict::Make);
	// an item whose own old copy is still marked waits for that too
	CHECK_EQ(gate(true, true, true, true, true, true, true, 0), sw::Verdict::Wait);
}

// Both modes: RL-UGYE-3WGE's other half. A stale item of another section outlived its entity under the id, the ammo box of
// the reused id comes. The identity guard says Make, but the stock net_Spawn refuses the box while the item holds the id
// (after half-making it). The box waits for the item to go, and is not made after kMaxWaitFrames (as the stock would end,
// without the half-made object).
TEST(spawn_wait_stale_object_of_another_kind_holds_the_spawn_back_bounded)
{
	CHECK_EQ(ident::spawn_verdict(true, true, true, false), ident::Spawn::Make);
	CHECK_EQ(free_entity(true, false, false, 0), sw::Verdict::Wait);
	CHECK_EQ(free_entity(true, false, false, sw::kMaxWaitFrames - 1), sw::Verdict::Wait);
	CHECK_EQ(free_entity(true, false, false, sw::kMaxWaitFrames), sw::Verdict::GiveUp);
	// the stale item went in time: the box is made
	CHECK_EQ(free_entity(false, false, false, 3), sw::Verdict::Make);
}

static_assert(sw::kMaxWaitFrames >= 2u, "a spawn may wait more than the one frame the destroy queue needs");
static_assert(sw::kForgetAfterFrames > sw::kMaxWaitFrames, "a wait in progress is never forgotten");

TEST(spawn_wait_is_bounded)
{
	CHECK_EQ(free_entity(true, true, true, sw::kMaxWaitFrames - 1), sw::Verdict::Wait);
	CHECK_EQ(free_entity(true, true, true, sw::kMaxWaitFrames), sw::Verdict::GiveUp);
	CHECK_EQ(free_entity(true, true, true, sw::kMaxWaitFrames + 7), sw::Verdict::GiveUp);
	CHECK_EQ(gate(true, true, true, false, false, false, true, sw::kMaxWaitFrames), sw::Verdict::GiveUp);
}

// Both modes: what the identity guard refuses is refused at once, whatever holds the id; waiting would change nothing.
TEST(spawn_wait_never_for_a_spawn_the_identity_guard_refuses)
{
	// its entity is gone here (the spawn outlived its destroy), its old object still marked
	CHECK_EQ(gate(true, false, false, true, true, true, false, 0), sw::Verdict::Refuse);
	CHECK_EQ(gate(true, false, false, false, false, false, true, 0), sw::Verdict::Refuse);
	// the id belongs to an entity of another section now
	CHECK_EQ(gate(true, true, false, true, true, false, false, 0), sw::Verdict::Refuse);
	// a live object of it holds the id already (a repeated spawn)
	CHECK_EQ(gate(true, true, true, true, false, true, false, 0), sw::Verdict::Refuse);
	CHECK_EQ(gate(true, true, true, true, false, true, true, 0), sw::Verdict::Refuse);
}

TEST(spawn_wait_free_id_is_made_at_once)
{
	CHECK_EQ(free_entity(false, false, false, 0), sw::Verdict::Make);
	CHECK_EQ(gate(true, true, true, false, false, false, false, 0), sw::Verdict::Make);
}

// The co-op host and single player: the stock code (its soft fail stays theirs), whatever the facts.
TEST(spawn_wait_outside_a_mirror_is_stock)
{
	for (int m = 0; m < 64; ++m)
		CHECK_EQ(gate(false, (m & 1) != 0, (m & 2) != 0, (m & 4) != 0, (m & 8) != 0, (m & 16) != 0, (m & 32) != 0,
		             sw::kMaxWaitFrames + 1),
		    sw::Verdict::Make);
}

TEST(spawn_wait_book_counts_frames_and_forgets)
{
	sw::WaitBook book;
	CHECK_EQ(book.waited(7, 10), 0u);
	book.wait(7, 10);
	book.wait(7, 10);
	book.wait(7, 11);
	book.wait(7, 13);
	CHECK_EQ(book.waited(7, 14), 3u);
	CHECK_EQ(book.waited(8, 14), 0u);
	// a wait whose spawn never came back (the stock pipeline dropped it) is forgotten
	CHECK_EQ(book.waited(7, 13 + sw::kForgetAfterFrames), 3u);
	CHECK_EQ(book.waited(7, 14 + sw::kForgetAfterFrames), 0u);
	book.wait(7, 14 + sw::kForgetAfterFrames);
	CHECK_EQ(book.waited(7, 15 + sw::kForgetAfterFrames), 1u);
	book.done(7);
	CHECK_EQ(book.waited(7, 15 + sw::kForgetAfterFrames), 0u);
	book.wait(1, 1);
	book.wait(2, 1);
	CHECK_EQ(book.size(), size_t(2));
	book.reset();
	CHECK_EQ(book.size(), size_t(0));
	CHECK_EQ(book.waited(1, 2), 0u);
}
