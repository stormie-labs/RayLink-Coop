// Anomaly Coop unit tests: the barrier of the simultaneous load (coop_load_barrier.h; docs/plans/2026-10-24-f3a-split-levels.md
// §1.5). Everybody who leaves (the host included) goes to the loading screen and waits there; when all have said they are
// loaded - and the new map server is up, if one is needed - the screens come off together. A laggard does not hold the
// others longer than kLoadWaitMs and enters alone when he is ready. A message of an older transition is not an answer.
#include "test_util.h"

#include "coop_load_barrier.h"

#include <vector>

using namespace coop::levels;

namespace
{
using Peers = std::vector<uint32_t>;
constexpr uint64_t kT0 = 20000;
} // namespace

TEST(barrier_all_ready_enter)
{
	LoadBarrier b;
	b.start(5, {0, 1, 2}, /*wait_server*/ false, kT0);
	CHECK(b.active());
	CHECK_EQ(b.epoch(), uint32_t(5));
	CHECK(!b.enter(kT0));
	CHECK_EQ(b.waiting(), (Peers{0, 1, 2}));

	b.ready(2, 5);
	b.ready(1, 5);
	CHECK(!b.enter(kT0 + 100));
	CHECK_EQ(b.waiting(), (Peers{0})); // in the order of the movers, for the line "Waiting for: ..."

	b.ready(1, 5); // a repeated "ready" is harmless
	CHECK(!b.enter(kT0 + 200));

	b.ready(0, 5);
	CHECK(b.enter(kT0 + 300));
	CHECK(b.waiting().empty());
	CHECK(b.enter(kT0 + 300 + 10 * kLoadWaitMs)); // and it stays open
}

// A new map server loads at the same time as the player: both are waited for.
TEST(barrier_server_needed)
{
	LoadBarrier b;
	b.start(6, {1}, /*wait_server*/ true, kT0);
	CHECK(b.waiting_server());
	b.ready(1, 6);
	CHECK(b.waiting().empty()); // no player is missing...
	CHECK(!b.enter(kT0 + 100)); // ...but the map has no server yet
	CHECK(b.waiting_server());

	// The player's 60 s do not open the barrier onto a map nobody leads.
	CHECK(!b.enter(kT0 + kLoadWaitMs + 1000));
	CHECK(!b.enter(kT0 + 10 * kLoadWaitMs));

	b.server_ready(6);
	CHECK(!b.waiting_server());
	CHECK(b.enter(kT0 + 10 * kLoadWaitMs));

	// The server first, the player after.
	LoadBarrier c;
	c.start(7, {1, 2}, true, kT0);
	c.server_ready(7);
	CHECK(!c.enter(kT0 + 100)); // the players are still loading
	c.ready(1, 7);
	c.ready(2, 7);
	CHECK(c.enter(kT0 + 200));

	// A server that is not needed: its ready changes nothing and its absence does not hold.
	LoadBarrier d;
	d.start(8, {1}, false, kT0);
	CHECK(!d.waiting_server());
	d.server_ready(8);
	CHECK(!d.enter(kT0));
	d.ready(1, 8);
	CHECK(d.enter(kT0));
}

// kLoadWaitMs after the start the barrier opens for those who are ready; the laggard enters alone when he is ready.
TEST(barrier_timeout_leaves_laggard)
{
	LoadBarrier b;
	b.start(9, {0, 1, 2}, false, kT0);
	b.ready(0, 9);
	b.ready(1, 9);
	CHECK_EQ(kLoadWaitMs, uint32_t(60000));
	CHECK(!b.enter(kT0 + kLoadWaitMs - 1));
	CHECK(b.enter(kT0 + kLoadWaitMs)); // the others go in without peer 2
	CHECK_EQ(b.waiting(), (Peers{2}));
	CHECK(b.is_ready(0));
	CHECK(b.is_ready(1));
	CHECK(!b.is_ready(2));

	// He loads at last: the barrier is open, he enters at once and by himself.
	b.ready(2, 9);
	CHECK(b.is_ready(2));
	CHECK(b.waiting().empty());
	CHECK(b.enter(kT0 + kLoadWaitMs + 5000));

	// Nobody is ready and the time is up: the barrier opens on nobody, everybody enters as he loads.
	LoadBarrier c;
	c.start(10, {1, 2}, false, kT0);
	CHECK(c.enter(kT0 + kLoadWaitMs));
	CHECK_EQ(c.waiting(), (Peers{1, 2}));
}

// LoadReady of an older (or a later) transition is not an answer to this one.
TEST(barrier_stale_epoch_ignored)
{
	LoadBarrier b;
	b.start(8, {1}, false, kT0);
	b.ready(1, 7); // the transition before
	CHECK(!b.enter(kT0 + 10));
	CHECK(!b.is_ready(1));
	b.ready(1, 9); // one that does not exist yet
	CHECK(!b.enter(kT0 + 10));
	b.ready(1, 0);
	CHECK(!b.enter(kT0 + 10));

	// A peer that is not leaving cannot open the barrier either.
	b.ready(99, 8);
	CHECK(!b.enter(kT0 + 10));
	CHECK_EQ(b.waiting(), (Peers{1}));

	// A new transition replaces the barrier: what was ready for the old one is not ready for the new one.
	b.ready(1, 8);
	CHECK(b.enter(kT0 + 20));
	b.start(10, {1, 2}, false, kT0 + 1000);
	CHECK_EQ(b.epoch(), uint32_t(10));
	CHECK(!b.enter(kT0 + 1001));
	CHECK(!b.is_ready(1));
	b.ready(1, 8); // a repeat of the old answer
	b.ready(2, 8);
	CHECK(!b.enter(kT0 + 1002));
	CHECK_EQ(b.waiting(), (Peers{1, 2}));
	b.ready(1, 10);
	b.ready(2, 10);
	CHECK(b.enter(kT0 + 1003));

	// The clock of the new barrier is its own.
	LoadBarrier c;
	c.start(1, {1}, false, kT0);
	c.start(2, {1}, false, kT0 + 50000);
	CHECK(!c.enter(kT0 + kLoadWaitMs)); // 10 s into the second barrier, not 60
	CHECK(c.enter(kT0 + 50000 + kLoadWaitMs));
}

// The host is a player of the barrier like the others: he is ready when his own world is up (through the local link).
TEST(barrier_host_player_ready_by_world_up)
{
	LoadBarrier b;
	b.start(11, {0, 1}, false, kT0); // peer 0: the host, who reloads his world for this transition
	b.ready(1, 11); // the client loaded before the host's world came up
	CHECK(!b.enter(kT0 + 100));
	CHECK_EQ(b.waiting(), (Peers{0}));

	b.world_up(10); // the world of another transition
	CHECK(!b.enter(kT0 + 200));
	b.world_up(11);
	CHECK(b.is_ready(0));
	CHECK(b.enter(kT0 + 300));

	// A transition where the host stays on his map: his world coming up is nothing to the barrier.
	LoadBarrier c;
	c.start(12, {1}, true, kT0);
	c.world_up(12);
	CHECK(!c.is_ready(0));
	CHECK(!c.enter(kT0));
	c.ready(1, 12);
	c.server_ready(12);
	CHECK(c.enter(kT0));

	// The host that is not peer 0 (a barrier of another numbering) is named when the barrier is made.
	LoadBarrier d(/*host_peer*/ 4);
	d.start(13, {4, 5}, false, kT0);
	d.world_up(13);
	CHECK(d.is_ready(4));
	d.ready(5, 13);
	CHECK(d.enter(kT0));
}

// A player who drops out while the screens are up does not hold the others.
TEST(barrier_leaver_does_not_hold)
{
	LoadBarrier b;
	b.start(14, {0, 1, 2}, false, kT0);
	b.ready(0, 14);
	b.ready(1, 14);
	CHECK(!b.enter(kT0 + 100));
	b.drop(2);
	CHECK(b.enter(kT0 + 100));
	CHECK(b.waiting().empty());
	b.ready(2, 14); // he is not a mover any more
	CHECK(!b.is_ready(2));

	// Everybody dropped: nobody to wait for.
	LoadBarrier c;
	c.start(15, {1}, false, kT0);
	c.drop(1);
	c.drop(1);
	c.drop(77);
	CHECK(c.enter(kT0));

	// ... except for the server that was asked for them.
	LoadBarrier d;
	d.start(16, {1}, true, kT0);
	d.drop(1);
	CHECK(!d.enter(kT0));
	d.server_ready(16);
	CHECK(d.enter(kT0));
}

TEST(barrier_edge_cases)
{
	// Never started: nothing to enter.
	LoadBarrier b;
	CHECK(!b.active());
	CHECK(!b.enter(kT0));
	CHECK(b.waiting().empty());
	b.ready(1, 0);
	b.world_up(0);
	b.server_ready(0);
	b.server_lost(0);
	CHECK(!b.server_wait_exceeded(kT0 + 10 * kLoadWaitMs));
	CHECK(!b.enter(kT0));

	// Nobody leaves and no server is needed: open at once (a transition of no one is no wait).
	b.start(3, {}, false, kT0);
	CHECK(b.active());
	CHECK(b.enter(kT0));

	// A mover listed twice is one mover.
	b.start(4, {1, 1, 2, 1}, false, kT0);
	CHECK_EQ(b.waiting(), (Peers{1, 2}));
	b.ready(1, 4);
	b.ready(2, 4);
	CHECK(b.enter(kT0));

	// The caller is finished with the barrier.
	b.clear();
	CHECK(!b.active());
	CHECK(!b.enter(kT0 + 10 * kLoadWaitMs));
	b.ready(1, 4);
	CHECK(!b.is_ready(1));

	// Epoch 0 is an epoch like another.
	b.start(0, {1}, false, kT0);
	b.ready(1, 0);
	CHECK(b.enter(kT0));
}

// A map server that never comes up: the barrier does not open, and after kLoadWaitMs the caller is told to give the move up
// (the movers go back where they were) instead of leaving them on the loading screen for good.
TEST(barrier_server_never_ready_aborts)
{
	LoadBarrier b;
	b.start(20, {1}, /*wait_server*/ true, kT0);
	b.ready(1, 20); // the player is loaded, the server is not
	CHECK(!b.server_wait_exceeded(kT0));
	CHECK(!b.server_wait_exceeded(kT0 + kLoadWaitMs - 1));
	CHECK(b.server_wait_exceeded(kT0 + kLoadWaitMs));
	CHECK(b.server_wait_exceeded(kT0 + 10 * kLoadWaitMs)); // and it stays so
	CHECK(!b.enter(kT0 + 10 * kLoadWaitMs)); // the barrier itself does not open onto a map nobody leads
	CHECK(b.waiting_server());

	// The server comes up late, before the caller has given up: the way out is closed again.
	b.server_ready(20);
	CHECK(!b.server_wait_exceeded(kT0 + 10 * kLoadWaitMs));
	CHECK(b.enter(kT0 + 10 * kLoadWaitMs));

	// No server asked for, none to wait for; not started, or finished: nothing.
	LoadBarrier c;
	CHECK(!c.server_wait_exceeded(kT0 + 10 * kLoadWaitMs));
	c.start(21, {1}, false, kT0);
	CHECK(!c.server_wait_exceeded(kT0 + 10 * kLoadWaitMs));
	LoadBarrier d;
	d.start(22, {1}, true, kT0);
	d.clear();
	CHECK(!d.server_wait_exceeded(kT0 + 10 * kLoadWaitMs));

	// The clock is the barrier's own: a new one restarts the wait.
	LoadBarrier e;
	e.start(23, {1}, true, kT0);
	e.start(24, {1}, true, kT0 + 50000);
	CHECK(!e.server_wait_exceeded(kT0 + kLoadWaitMs));
	CHECK(e.server_wait_exceeded(kT0 + 50000 + kLoadWaitMs));
}

// A map server can die after it said Ready and before the screens came off: the barrier closes again.
TEST(barrier_server_lost_after_ready_closes)
{
	LoadBarrier b;
	b.start(30, {1}, true, kT0);
	b.ready(1, 30);
	b.server_ready(30);
	CHECK(b.enter(kT0 + 100));
	CHECK(!b.waiting_server());

	b.server_lost(30);
	CHECK(!b.enter(kT0 + 200));
	CHECK(b.waiting_server());
	CHECK(!b.server_wait_exceeded(kT0 + 200));
	CHECK(b.server_wait_exceeded(kT0 + kLoadWaitMs)); // the way out works for a lost server as well

	// A new server of the same level comes up: open again.
	b.server_ready(30);
	CHECK(b.enter(kT0 + 300));
	CHECK(!b.server_wait_exceeded(kT0 + 10 * kLoadWaitMs));

	// The report of another transition's server, or one for a barrier that waits for none, changes nothing.
	b.server_lost(29);
	b.server_lost(31);
	CHECK(b.enter(kT0 + 400));
	LoadBarrier c;
	c.start(32, {1}, false, kT0);
	c.ready(1, 32);
	c.server_lost(32);
	CHECK(c.enter(kT0));
	LoadBarrier d; // not started
	d.server_lost(0);
	CHECK(!d.enter(kT0));
}

// A barrier belongs to one transition and is fed only by its own server: a Ready of another epoch is not its server's.
TEST(barrier_stale_server_ready_ignored)
{
	LoadBarrier b;
	b.start(40, {1}, true, kT0);
	b.ready(1, 40);
	b.server_ready(39); // the server of the transition before
	b.server_ready(41); // one that does not exist yet
	b.server_ready(0);
	CHECK(!b.enter(kT0 + 100));
	CHECK(b.waiting_server());
	b.server_ready(40);
	CHECK(b.enter(kT0 + 100));

	// A new transition: the old server's Ready does not open it.
	b.start(41, {1}, true, kT0 + 1000);
	b.ready(1, 41);
	b.server_ready(40);
	CHECK(!b.enter(kT0 + 1100));
	b.server_ready(41);
	CHECK(b.enter(kT0 + 1100));
}
