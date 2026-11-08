// Anomaly Coop unit tests: one id, one object on a co-op client (xrCoop/coop_object_identity.h; live RL-UGYE-3WGE
// 2026-11-09: FATAL "Beer from the creator of 'AMMO_S'" in xrServer::Process_update on a client, object 52480, 3 bytes
// read where the game object wrote 1).
#include "test_util.h"

#include "coop_object_identity.h"

using coop::identity::export_verdict;
using coop::identity::OncePerId;
using coop::identity::spawn_verdict;
using coop::identity::update_verdict;
namespace id = coop::identity;

// The crash: a postponed M_SPAWN of an item (an inventory item, 1 byte of update) ran after the id went to an ammo box
// (3 bytes): the game object must not be made, it would write the wrong format under the box's id for ever.
TEST(identity_spawn_after_the_id_was_reused_is_not_made)
{
	CHECK_EQ(spawn_verdict(true, true, false, false), id::Spawn::OtherKind);
	CHECK_EQ(spawn_verdict(true, true, false, true), id::Spawn::OtherKind);
}

// The spawn outlived its destroy: the GE_DESTROY found no object (the spawn waited for its models) and was dropped.
TEST(identity_spawn_without_its_entity_is_not_made)
{
	CHECK_EQ(spawn_verdict(true, false, false, false), id::Spawn::Stale);
	CHECK_EQ(spawn_verdict(true, false, true, true), id::Spawn::Stale);
}

// Two spawns of one id (online, offline, online again before the models came): the second object would never get a
// destroy (the event finds the registered one only) and stays as an orphan under the id.
TEST(identity_second_live_object_under_an_id_is_not_made)
{
	CHECK_EQ(spawn_verdict(true, true, true, true), id::Spawn::Duplicate);
}

TEST(identity_normal_spawn_is_made)
{
	CHECK_EQ(spawn_verdict(true, true, true, false), id::Spawn::Make);
}

// The crash's other half: an item outlived its entity under 52480, the box comes. The box is made (it registers under
// the id; the stale item is no longer the id's object and its export is held back), not held back by the stale item.
TEST(identity_stale_object_of_another_kind_does_not_hold_the_new_one_back)
{
	CHECK_EQ(spawn_verdict(true, true, true, /*live_same_kind*/ false), id::Spawn::Make);
	CHECK_EQ(export_verdict(true, /*registered*/ false, true, /*same_section*/ false), id::Export::NotRegistered);
}

// Single player and the host: the stock code, whatever the facts.
TEST(identity_spawn_outside_a_mirror_is_stock)
{
	for (int m = 0; m < 8; ++m)
		CHECK_EQ(spawn_verdict(false, (m & 1) != 0, (m & 2) != 0, (m & 4) != 0), id::Spawn::Make);
}

// The crash again, on the export side: the stale item is the level's object for the id (the box is offline here) but
// the entity there is the box: its 1 byte would be read as 3.
TEST(identity_export_of_another_kind_is_held_back)
{
	CHECK_EQ(export_verdict(true, true, true, false), id::Export::OtherKind);
}

// The box is online too: the level registered the box under the id, the stale item is not the id's object any more.
TEST(identity_export_of_an_unregistered_copy_is_held_back)
{
	CHECK_EQ(export_verdict(true, false, true, true), id::Export::NotRegistered);
	CHECK_EQ(export_verdict(true, false, true, false), id::Export::NotRegistered);
	CHECK_EQ(export_verdict(true, false, false, false), id::Export::NotRegistered);
}

// The object of the id, and an object with no entity (the server skips an unknown id's chunk, as the stock code does).
TEST(identity_export_of_the_ids_object_is_sent)
{
	CHECK_EQ(export_verdict(true, true, true, true), id::Export::Send);
	CHECK_EQ(export_verdict(true, true, false, false), id::Export::Send);
}

TEST(identity_export_outside_a_mirror_is_stock)
{
	for (int m = 0; m < 8; ++m)
		CHECK_EQ(export_verdict(false, (m & 1) != 0, (m & 2) != 0, (m & 4) != 0), id::Export::Send);
}

// The last line: a mismatch on a mirror is skipped (and logged, the host asked), never FATAL; the stock FATAL elsewhere.
TEST(identity_update_mismatch_on_a_mirror_is_skipped)
{
	CHECK_EQ(update_verdict(true, 3, 1), id::Update::Skip); // RL-UGYE-3WGE: r_tell 3675 - pos 3672 = 3, size 1
	CHECK_EQ(update_verdict(true, 0, 5), id::Update::Skip);
	CHECK_EQ(update_verdict(true, 3, 3), id::Update::Ok);
}

TEST(identity_update_mismatch_outside_a_mirror_is_fatal)
{
	CHECK_EQ(update_verdict(false, 3, 1), id::Update::Fatal);
	CHECK_EQ(update_verdict(false, 3, 3), id::Update::Ok);
}

TEST(identity_once_per_id)
{
	OncePerId once;
	CHECK(once.first(52480));
	CHECK(!once.first(52480));
	CHECK(once.first(0));
	CHECK(once.first(65535));
	CHECK(!once.first(65535));
	once.reset();
	CHECK(once.first(52480));
}
