// Anomaly Coop unit tests: a co-op client's mirror of the host's world (xrCoop/coop_mirror.h, B2 live 2026-10-23:
// FATAL "child registered but not found" in xrServer::Perform_destroy on a client leaving the game).
#include "test_util.h"

#include "coop_mirror.h"

using coop::mirror::lost_child;
using coop::mirror::LostChild;
using coop::mirror::placement;
using coop::mirror::Placement;

// B2: a child follows its holder HERE, not the host's flag. The host has a child offline when its holder is offline
// there (our own character while we load the world, an NPC that switched offline in the same host frame); here the
// holder may be online. Left offline, the child sits in the online holder's children with no server entity, and the
// holder's next teardown on the server (switch offline, level exit) is the FATAL.
TEST(mirror_child_follows_holder_here)
{
	// the bug: offline on the host, the holder online and on the server here
	CHECK_EQ(placement(true, false, true, true), Placement::WithHolder);
	// online on the host, the same
	CHECK_EQ(placement(true, true, true, true), Placement::WithHolder);
	// the holder offline here: the child stays offline in it, whatever the host's flag (it comes online with it)
	CHECK_EQ(placement(true, true, false, true), Placement::Offline);
	CHECK_EQ(placement(true, false, false, true), Placement::Offline);
	CHECK_EQ(placement(true, true, false, false), Placement::Offline);
	CHECK_EQ(placement(true, false, false, false), Placement::Offline);
}

// A holder that says online but has no server entity cannot take a child online: it is told apart for the log.
TEST(mirror_child_of_a_broken_holder)
{
	CHECK_EQ(placement(true, true, true, false), Placement::HolderBroken);
	CHECK_EQ(placement(true, false, true, false), Placement::HolderBroken);
}

// A free entity: the host's online set decides (the switch manager brings it in), the holder flags mean nothing.
TEST(mirror_free_entity_follows_the_host)
{
	for (int holder = 0; holder < 4; ++holder)
	{
		const bool online = (holder & 1) != 0, on_server = (holder & 2) != 0;
		CHECK_EQ(placement(false, true, online, on_server), Placement::SwitchVote);
		CHECK_EQ(placement(false, false, online, on_server), Placement::Offline);
	}
}

// Single player and the host keep the stock assert: there a lost child is a real corruption of the world.
TEST(mirror_lost_child_fatal_outside_a_mirror)
{
	for (int bits = 0; bits < 16; ++bits)
		CHECK_EQ(lost_child(false, (bits & 1) != 0, (bits & 2) != 0, (bits & 4) != 0, (bits & 8) != 0),
		    LostChild::Fatal);
}

// A mirror: no FATAL. An offline item of this very holder is detached the ALife way (else its ID_Parent would still
// name a holder that does not list it, and the next release of it asserts in CSE_ALifeDynamicObject::detach); any other
// id only leaves the list.
TEST(mirror_lost_child_on_a_mirror)
{
	CHECK_EQ(lost_child(true, true, false, true, true), LostChild::Detach);
	CHECK_EQ(lost_child(true, true, true, true, true), LostChild::Drop);    // online flag without a server entity
	CHECK_EQ(lost_child(true, true, false, false, true), LostChild::Drop);  // held by another (a stale id here)
	CHECK_EQ(lost_child(true, true, false, true, false), LostChild::Drop);  // not an item of an ALife holder
	CHECK_EQ(lost_child(true, false, false, false, false), LostChild::Drop); // gone from ALife too
	CHECK_EQ(lost_child(true, false, false, true, true), LostChild::Drop);
}
