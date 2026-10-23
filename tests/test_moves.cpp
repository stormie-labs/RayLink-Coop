// Anomaly Coop unit tests: the host's rules for one side of a client's item move (xrCoop/coop_moves.h, Ruling F2-32,
// F2 T12 round 1). coop_requests.cpp host_move fills the sides from the game and answers NotOwner / NotAllowed.
#include "test_util.h"

#include "coop_moves.h"

#include <string>

using namespace coop::moves;

namespace
{
Side side(Side::Kind kind, bool closed = false, bool can_take = true, bool talking = false, bool companion = false)
{
	Side s;
	s.kind = kind;
	s.closed = closed;
	s.can_take = can_take;
	s.talking = talking;
	s.companion = companion;
	return s;
}

Side npc(bool talking, bool companion) { return side(Side::LiveNpc, false, true, talking, companion); }
} // namespace

// A live NPC's pockets only while the player talks to it (mechanic returning a repaired item, a dialog handing an item
// over); a stock scenario moving from a live NPC without a talk is refused and visible in the host's log.
TEST(moves_live_npc_needs_talk)
{
	const Side mine = side(Side::Mine);
	CHECK_EQ(check(side(Side::LiveNpc), mine), Verdict::NotOwner);
	CHECK_EQ(check(side(Side::LiveNpc, false, true, true), mine), Verdict::Ok);
	// another player's pockets: never (host_move refuses it before as well)
	CHECK_EQ(check(side(Side::Player), mine), Verdict::NotOwner);
	CHECK_EQ(check(side(Side::Player, false, true, true), mine), Verdict::NotOwner);
}

// Ruling F2-32b: a live NPC's inventory, out of it or into it, only while the player talks to it or when it is his own
// companion (its squad is led by his character: the stock companion inventory opens without a dialog). Another
// player's companion and a stranger without a talk are refused, both ways.
TEST(moves_live_npc_talk_or_own_companion)
{
	const Side mine = side(Side::Mine), world = side(Side::World);
	// out of a live NPC
	CHECK_EQ(check(npc(false, true), mine), Verdict::Ok);   // own companion, no talk
	CHECK_EQ(check(npc(true, false), mine), Verdict::Ok);   // a talk
	CHECK_EQ(check(npc(true, true), mine), Verdict::Ok);
	CHECK_EQ(check(npc(false, false), mine), Verdict::NotOwner); // a stranger or another player's companion
	CHECK_EQ(check(npc(false, false), world), Verdict::NotOwner);
	// into a live NPC
	CHECK_EQ(check(mine, npc(false, true)), Verdict::Ok);
	CHECK_EQ(check(mine, npc(true, false)), Verdict::Ok);
	CHECK_EQ(check(mine, npc(false, false)), Verdict::NotOwner);
	CHECK_EQ(check(world, npc(false, false)), Verdict::NotOwner);
	// "companion" means nothing for other kinds: a player's pockets stay closed, a lock stays a lock
	CHECK_EQ(check(side(Side::Player, false, true, true, true), mine), Verdict::NotOwner);
	CHECK_EQ(check(side(Side::Box, true, true, false, true), mine), Verdict::Locked);
	CHECK_EQ(check(mine, side(Side::Corpse, false, false, false, true)), Verdict::Locked);
}

// Box and corpse locks as the stock game keeps them (ActorInput / UIActorMenuDeadBodySearch): a closed one does not
// open; can_take = false refuses items put into it, taking out stays allowed.
TEST(moves_box_and_corpse_locks)
{
	const Side mine = side(Side::Mine), world = side(Side::World);
	for (const Side::Kind k : {Side::Box, Side::Corpse})
	{
		CHECK_EQ(check(side(k), mine), Verdict::Ok);
		CHECK_EQ(check(side(k, true), mine), Verdict::Locked);             // closed: nothing out
		CHECK_EQ(check(side(k, false, false), mine), Verdict::Ok);         // can_take off: taking out is fine
		CHECK_EQ(check(mine, side(k)), Verdict::Ok);
		CHECK_EQ(check(mine, side(k, true)), Verdict::Locked);             // closed: nothing in
		CHECK_EQ(check(mine, side(k, false, false)), Verdict::Locked);     // can_take off: nothing in
		CHECK_EQ(check(side(k, true), world), Verdict::Locked);
	}
	// a talk does not open a locked box or corpse
	CHECK_EQ(check(side(Side::Box, true, true, true), mine), Verdict::Locked);
}

// Our own inventory, the ground and other containers add no rule here (owner, reach and container are host_move's).
TEST(moves_plain_sides)
{
	const Side mine = side(Side::Mine), world = side(Side::World), other = side(Side::Other);
	CHECK_EQ(check(mine, world), Verdict::Ok);
	CHECK_EQ(check(world, mine), Verdict::Ok);
	CHECK_EQ(check(other, mine), Verdict::Ok);
	CHECK_EQ(check(mine, other), Verdict::Ok);
	CHECK(std::string(verdict_text(Verdict::NotOwner)).find("talk") != std::string::npos);
	CHECK(std::string(verdict_text(Verdict::Locked)).find("lock") != std::string::npos);
	CHECK(std::string(verdict_text(Verdict::Ok)) == "ok");
}
