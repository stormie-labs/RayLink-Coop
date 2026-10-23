// Anomaly Coop unit tests: the rules of split levels (coop_levels_rules.h; docs/plans/2026-10-24-f3a-split-levels.md
// §1.1, §1.5, §1.10, §3). Who leads a level (the host's process, a background map server, nobody), which players a
// level's messages reach, how a gate folds with the two game rules, the verdict on a move, the life of one map server
// (start, pause, return during the pause, crash, timeouts) and the flush round before a save.
#include "test_util.h"

#include "coop_levels_rules.h"

#include <vector>

using namespace coop::levels;

namespace
{
using Peers = std::vector<uint32_t>;

Seat seat(uint32_t peer, uint16_t level, bool in_world = true, bool plays = true)
{
	Seat s;
	s.peer = peer;
	s.level = level;
	s.in_world = in_world;
	s.plays = plays;
	return s;
}

constexpr uint64_t kT0 = 5000;
} // namespace

// ---------------------------------------------------------------- who leads a level

// The host's process leads its own level even when a client was there first, and a client's level is a map server's.
TEST(authority_host_process_first)
{
	Table t;
	t.set(seat(1, 5)); // a client on level 5 first
	t.set(seat(0, 5)); // then the host comes to the same level
	CHECK(t.server_of(5) == Server::HostProcess);

	t.set(seat(0, 7)); // the host goes to level 7: its process leads 7, level 5 now needs a map server
	CHECK(t.server_of(7) == Server::HostProcess);
	CHECK(t.server_of(5) == Server::MapServer);

	// The host that is not in the world yet (his process is loading the level) still leads the level it loads.
	t.set(seat(0, 9, /*in_world*/ false));
	CHECK(t.server_of(9) == Server::HostProcess);
}

TEST(authority_map_server)
{
	Table t;
	t.set(seat(0, 1)); // the host on level 1
	t.set(seat(2, 3));
	t.set(seat(3, 3));
	CHECK(t.server_of(3) == Server::MapServer);
	CHECK(t.server_of(1) == Server::HostProcess);

	// A player on his way (loading the level) already needs its server.
	t.set(seat(4, 6, /*in_world*/ false));
	CHECK(t.server_of(6) == Server::MapServer);

	// plays = false is the future console host: he is a host that does not play, so his level is a map server's.
	Table c;
	c.set(seat(0, 2, true, /*plays*/ false));
	c.set(seat(1, 2));
	CHECK(c.server_of(2) == Server::MapServer);
}

TEST(authority_none)
{
	Table t;
	CHECK(t.server_of(0) == Server::None);
	CHECK(t.server_of(kNoLevel) == Server::None);

	t.set(seat(0, 1));
	t.set(seat(2, 3));
	CHECK(t.server_of(2) == Server::None); // a level nobody is on
	CHECK(t.server_of(kNoLevel) == Server::None);

	// A seat that is not on any level (the player is choosing a character) leads nothing.
	t.set(seat(5, kNoLevel, false));
	CHECK(t.server_of(kNoLevel) == Server::None);

	// Seats that do not play (the ghost actor of a map server, a console host) do not make a level served.
	t.set(seat(9, 8, true, /*plays*/ false));
	CHECK(t.server_of(8) == Server::None);

	// The last player leaves: his level is nobody's again.
	t.remove(2);
	CHECK(t.server_of(3) == Server::None);
	t.clear();
	CHECK(t.server_of(1) == Server::None);
}

TEST(map_server_levels_and_players)
{
	Table t;
	t.set(seat(0, 1)); // the host's level: led by the host's process, no map server
	t.set(seat(1, 1));
	t.set(seat(2, 4));
	t.set(seat(3, 4, /*in_world*/ false)); // loading into 4
	t.set(seat(4, 9));
	t.set(seat(5, 9, true, /*plays*/ false)); // a ghost: not a player

	CHECK_EQ(t.population(1), uint32_t(2));
	CHECK_EQ(t.population(4), uint32_t(2));
	CHECK_EQ(t.population(9), uint32_t(1));
	CHECK_EQ(t.population(7), uint32_t(0));

	CHECK_EQ(t.map_players(1), uint32_t(0)); // the host's process serves them, not a map server
	CHECK_EQ(t.map_players(4), uint32_t(2)); // the one who is loading counts: the server must be there for him
	CHECK_EQ(t.map_players(9), uint32_t(1));
	CHECK_EQ(t.map_players(7), uint32_t(0));

	CHECK_EQ(t.map_server_levels(), (std::vector<uint16_t>{4, 9}));
}

// ---------------------------------------------------------------- whom a level's messages reach

TEST(receivers_same_level)
{
	Table t;
	t.set(seat(0, 1)); // the host
	t.set(seat(1, 1));
	t.set(seat(2, 2));
	t.set(seat(3, 1, /*in_world*/ false)); // loading: cannot take map messages yet
	t.set(seat(4, 1, true, /*plays*/ false)); // a ghost
	t.set(seat(5, 1));

	CHECK_EQ(t.on(1), (Peers{0, 1, 5}));
	CHECK_EQ(t.receivers(1, 1), (Peers{0, 5})); // everybody but the sender
	CHECK_EQ(t.receivers(1, 0), (Peers{1, 5})); // the host is a player like the others (peer 0)
	CHECK_EQ(t.receivers(1, 99), (Peers{0, 1, 5})); // the excepted peer is not on the level: nobody is left out
	CHECK_EQ(t.receivers(2, 2), Peers{});
	CHECK_EQ(t.receivers(2, 0), (Peers{2}));
	CHECK_EQ(t.receivers(9, 0), Peers{});
	CHECK_EQ(t.receivers(kNoLevel, 0), Peers{});

	// Moving a player moves him between the lists; the order of the others does not change.
	t.set(seat(1, 2));
	CHECK_EQ(t.on(1), (Peers{0, 5}));
	CHECK_EQ(t.on(2), (Peers{1, 2}));
	// He gets into the world: now he is a receiver.
	t.set(seat(3, 1, true));
	CHECK_EQ(t.on(1), (Peers{0, 3, 5}));
}

TEST(observes_other_level_false)
{
	Table t;
	t.set(seat(1, 1));
	t.set(seat(2, 2));
	t.set(seat(3, 1, /*in_world*/ false));
	t.set(seat(4, 1, true, /*plays*/ false));

	CHECK(t.observes(1, 1));
	CHECK(!t.observes(1, 2)); // a player sees the events of his own level only
	CHECK(t.observes(2, 2));
	CHECK(!t.observes(2, 1));
	CHECK(!t.observes(3, 1)); // not in the world yet
	CHECK(!t.observes(4, 1)); // does not play
	CHECK(!t.observes(99, 1)); // nobody
	CHECK(!t.observes(1, kNoLevel));

	t.set(seat(1, 2)); // he goes to level 2
	CHECK(!t.observes(1, 1));
	CHECK(t.observes(1, 2));
}

// ---------------------------------------------------------------- gates

TEST(gate_fold)
{
	// Split levels on: the gate stands; with "story maps together" off, Together is only a suggestion.
	CHECK(effective_gate(Gate::Free, true, true) == Gate::Free);
	CHECK(effective_gate(Gate::BetterTogether, true, true) == Gate::BetterTogether);
	CHECK(effective_gate(Gate::Together, true, true) == Gate::Together);
	CHECK(effective_gate(Gate::Free, true, false) == Gate::Free);
	CHECK(effective_gate(Gate::BetterTogether, true, false) == Gate::BetterTogether);
	CHECK(effective_gate(Gate::Together, true, false) == Gate::BetterTogether);

	// Split levels off (Phase 3): the group moves as one through the waiting point at every exit.
	for (Gate g : {Gate::Free, Gate::BetterTogether, Gate::Together})
	{
		CHECK(effective_gate(g, false, true) == Gate::Together);
		CHECK(effective_gate(g, false, false) == Gate::Together);
	}
}

TEST(gate_names)
{
	// The words of configs/coop_levels_together.ltx.
	CHECK_EQ(std::string(gate_name(Gate::Free)), std::string("free"));
	CHECK_EQ(std::string(gate_name(Gate::BetterTogether)), std::string("suggest"));
	CHECK_EQ(std::string(gate_name(Gate::Together)), std::string("together"));
	CHECK_EQ(std::string(gate_name(static_cast<Gate>(9))), std::string());

	Gate g = Gate::Free;
	CHECK(parse_gate("together", g) && g == Gate::Together);
	CHECK(parse_gate("suggest", g) && g == Gate::BetterTogether);
	CHECK(parse_gate("free", g) && g == Gate::Free);

	// Anything else is refused and the output stays as it was.
	g = Gate::Together;
	CHECK(!parse_gate("", g) && g == Gate::Together);
	CHECK(!parse_gate("Together", g) && g == Gate::Together);
	CHECK(!parse_gate("together ", g) && g == Gate::Together);
	CHECK(!parse_gate("nil", g) && g == Gate::Together);
}

// ---------------------------------------------------------------- the verdict on a move

TEST(decide_move_cap)
{
	// A free level that needs a new map server: Go while there is room, refused at the cap.
	CHECK(decide_move(Gate::Free, true, 0, 3) == MoveVerdict::Go);
	CHECK(decide_move(Gate::Free, true, 2, 3) == MoveVerdict::Go);
	CHECK(decide_move(Gate::Free, true, 3, 3) == MoveVerdict::RefuseCap);
	CHECK(decide_move(Gate::Free, true, 7, 3) == MoveVerdict::RefuseCap); // more running than the cap (the cap was lowered)
	CHECK(decide_move(Gate::BetterTogether, true, 3, 3) == MoveVerdict::RefuseCap); // a suggestion does not lift the cap

	// A level that is already served needs nothing: the cap does not matter.
	CHECK(decide_move(Gate::Free, false, 3, 3) == MoveVerdict::Go);
	CHECK(decide_move(Gate::Free, false, 7, 0) == MoveVerdict::Go);
	CHECK(decide_move(Gate::BetterTogether, false, 3, 3) == MoveVerdict::Go);

	// Cap 0: no map servers at all, any move to a level nobody leads is refused.
	CHECK(decide_move(Gate::Free, true, 0, 0) == MoveVerdict::RefuseCap);
	CHECK(decide_move(Gate::Free, false, 0, 0) == MoveVerdict::Go);

	// A gate that is not one of the three is invalid, whatever the room.
	CHECK(decide_move(static_cast<Gate>(7), true, 0, 3) == MoveVerdict::RefuseInvalid);
	CHECK(decide_move(static_cast<Gate>(7), false, 0, 3) == MoveVerdict::RefuseInvalid);
}

TEST(decide_move_together)
{
	// A "together" level is entered through the waiting point, by the whole group: no server of its own, no cap.
	CHECK(decide_move(Gate::Together, false, 0, 3) == MoveVerdict::Board);
	CHECK(decide_move(Gate::Together, true, 0, 3) == MoveVerdict::Board);
	CHECK(decide_move(Gate::Together, true, 3, 3) == MoveVerdict::Board);
	CHECK(decide_move(Gate::Together, true, 9, 0) == MoveVerdict::Board);

	// "Better together" is a hint on the client's screen: the move itself goes at once.
	CHECK(decide_move(Gate::BetterTogether, true, 0, 3) == MoveVerdict::Go);
	CHECK(decide_move(Gate::BetterTogether, false, 0, 3) == MoveVerdict::Go);

	// With split levels off every gate is Together (effective_gate) and so every move waits at the board.
	CHECK(decide_move(effective_gate(Gate::Free, false, true), true, 3, 3) == MoveVerdict::Board);
	// With "story maps together" off a Together level is only a suggestion: the move goes.
	CHECK(decide_move(effective_gate(Gate::Together, true, false), false, 0, 3) == MoveVerdict::Go);
}

// ---------------------------------------------------------------- the life of one map server

TEST(server_life_defaults)
{
	CHECK_EQ(kStartTimeoutMs, uint32_t(120000));
	CHECK_EQ(kStopTimeoutMs, uint32_t(15000));
	CHECK_EQ(kDefaultLingerMs, uint32_t(60000)); // coop_mapserver_linger, 60 s
	CHECK_EQ(kFlushTimeoutMs, uint32_t(3000));
	CHECK_EQ(kMaxStartFailures, uint32_t(3));
	CHECK_EQ(kHealthyRunMs, uint32_t(30000));

	ServerLife life;
	CHECK(life.state() == ServerState::Off);
	CHECK_EQ(life.linger_ms, kDefaultLingerMs);
	CHECK(!life.want_start());
	CHECK(!life.want_stop(kT0));
	CHECK(!life.running());
	CHECK(!life.gave_up());
	CHECK_EQ(life.failures(), uint32_t(0));
}

// A player heads to a level nobody leads: the process is wanted; it loads; it serves.
TEST(server_life_start)
{
	ServerLife life;
	life.players(1, kT0);
	CHECK(life.want_start());
	CHECK(life.state() == ServerState::Off); // nothing has happened yet: the caller launches the process and says so

	life.started(kT0);
	CHECK(life.state() == ServerState::Starting);
	CHECK(!life.want_start()); // not twice
	CHECK(!life.want_stop(kT0 + kStartTimeoutMs - 1));

	life.ready();
	CHECK(life.state() == ServerState::Serving);
	CHECK(!life.want_start());
	CHECK(!life.want_stop(kT0 + 10 * kStartTimeoutMs)); // a server with a player is never stopped for idling

	// More players, fewer players: still serving.
	life.players(3, kT0 + 1000);
	life.players(1, kT0 + 2000);
	CHECK(life.state() == ServerState::Serving);
	CHECK_EQ(life.count(), uint32_t(1));
}

// The process that does not come up in kStartTimeoutMs is given up on.
TEST(server_life_start_timeout)
{
	ServerLife life;
	life.players(2, kT0);
	life.started(kT0);
	CHECK(!life.want_stop(kT0 + kStartTimeoutMs - 1));
	CHECK(life.want_stop(kT0 + kStartTimeoutMs)); // the caller kills the process and reports it lost
	life.lost();
	CHECK(life.state() == ServerState::Lost);
	CHECK(life.want_start()); // the players still wait: a second try
	life.started(kT0 + kStartTimeoutMs + 10);
	CHECK(life.state() == ServerState::Starting);
	CHECK(!life.want_stop(kT0 + kStartTimeoutMs + 10 + kStartTimeoutMs - 1)); // the clock of the new try
	life.ready();
	CHECK(life.state() == ServerState::Serving);
}

// The last player leaves: the server waits out the pause (linger) and then it is stopped.
TEST(server_life_pause)
{
	ServerLife life;
	life.linger_ms = 8000;
	life.players(2, kT0);
	life.started(kT0);
	life.ready();

	life.players(1, kT0 + 1000);
	CHECK(life.state() == ServerState::Serving);
	life.players(0, kT0 + 2000); // the pause begins
	CHECK(life.state() == ServerState::Draining);
	CHECK(!life.want_stop(kT0 + 2000));
	CHECK(!life.want_stop(kT0 + 2000 + 8000 - 1));
	CHECK(life.want_stop(kT0 + 2000 + 8000));

	// The heartbeat of the same empty count does not restart the pause.
	life.players(0, kT0 + 6000);
	life.players(0, kT0 + 9000);
	CHECK(life.want_stop(kT0 + 2000 + 8000));

	// The caller sends Stop; the server hands everything over and exits.
	life.stopping(kT0 + 10000);
	CHECK(life.state() == ServerState::Stopping);
	CHECK(!life.want_stop(kT0 + 10000 + kStopTimeoutMs - 1));
	life.stopped();
	CHECK(life.state() == ServerState::Off);
	CHECK(!life.want_start());
	CHECK(!life.want_stop(kT0 + 99999999));

	// The default pause is 60 s.
	ServerLife d;
	d.players(1, kT0);
	d.started(kT0);
	d.ready();
	d.players(0, kT0 + 100);
	CHECK(!d.want_stop(kT0 + 100 + 59999));
	CHECK(d.want_stop(kT0 + 100 + 60000));
}

// A player comes back before the pause is over: the server stays, and the next pause counts from the next departure.
TEST(server_life_return_during_pause)
{
	ServerLife life;
	life.linger_ms = 10000;
	life.players(1, kT0);
	life.started(kT0);
	life.ready();

	life.players(0, kT0 + 1000);
	CHECK(life.state() == ServerState::Draining);
	life.players(1, kT0 + 6000); // back after 5 s
	CHECK(life.state() == ServerState::Serving);
	CHECK(!life.want_stop(kT0 + 1000 + 10000)); // the old pause is void
	CHECK(!life.want_stop(kT0 + 99999));

	life.players(0, kT0 + 20000); // leaves again
	CHECK(!life.want_stop(kT0 + 20000 + 9999));
	CHECK(life.want_stop(kT0 + 20000 + 10000));
}

// The server that came up when its player had gone already (he cancelled the move, he dropped) is idle: Ready, and it
// follows the same pause.
TEST(server_life_ready_idle)
{
	ServerLife life;
	life.linger_ms = 5000;
	life.players(1, kT0);
	life.started(kT0);
	life.players(0, kT0 + 500); // the player is gone while the map loads
	CHECK(life.state() == ServerState::Starting); // the process is still launching
	life.players(0, kT0 + 3000);
	life.ready(); // clock of the last call: kT0 + 3000
	CHECK(life.state() == ServerState::Ready);
	CHECK(!life.want_stop(kT0 + 3000 + 4999));
	CHECK(life.want_stop(kT0 + 3000 + 5000));

	// Somebody comes: it serves.
	life.players(1, kT0 + 4000);
	CHECK(life.state() == ServerState::Serving);
	CHECK(!life.want_stop(kT0 + 99999));
}

// A stop that does not end in kStopTimeoutMs is forced; a player who comes back meanwhile waits for the exit.
TEST(server_life_stop_timeout_and_return)
{
	ServerLife life;
	life.linger_ms = 1000;
	life.players(1, kT0);
	life.started(kT0);
	life.ready();
	life.players(0, kT0 + 100);
	life.stopping(kT0 + 1100);
	CHECK(life.state() == ServerState::Stopping);

	life.players(1, kT0 + 2000); // a player wants the level again while it is going down
	CHECK(life.state() == ServerState::Stopping); // the stop is not cancelled
	CHECK(!life.want_start()); // there is still a process
	CHECK(!life.want_stop(kT0 + 1100 + kStopTimeoutMs - 1));
	CHECK(life.want_stop(kT0 + 1100 + kStopTimeoutMs)); // the process is stuck: the caller kills it

	life.stopped(); // it exits at last
	CHECK(life.state() == ServerState::Off);
	CHECK(life.want_start()); // and the player gets a fresh one
}

// A stop is ordered for a server that has players too (the host moves: every map server hands its level over).
TEST(server_life_forced_stop_with_players)
{
	ServerLife life;
	life.players(2, kT0);
	life.started(kT0);
	life.ready();
	life.stopping(kT0 + 5000);
	CHECK(life.state() == ServerState::Stopping);
	life.stopped();
	CHECK(life.state() == ServerState::Off);
	CHECK(life.want_start()); // the players are still on that level (their map is led by a new server)
}

// A server that dies: at once a new one is wanted while there are players; with nobody, nothing is started. (Each of the
// servers here lives kHealthyRunMs after it is ready, so none of the deaths counts as a failed start.)
TEST(server_life_crash)
{
	uint64_t t = kT0;
	ServerLife life;
	life.players(2, t);
	life.started(t);
	life.ready();
	t += kHealthyRunMs;
	life.players(2, t);

	life.lost();
	CHECK(life.state() == ServerState::Lost);
	CHECK(life.want_start());
	CHECK(!life.want_stop(t + 99999999));

	t += 1000;
	life.started(t);
	life.ready();
	t += kHealthyRunMs;
	life.players(2, t);
	CHECK(life.state() == ServerState::Serving);

	// The same when the process dies while it is loading, or while the pause runs.
	life.lost();
	t += 1000;
	life.started(t);
	life.lost();
	CHECK(life.state() == ServerState::Lost);
	CHECK(life.want_start());
	t += 1000;
	life.started(t);
	life.ready();
	t += kHealthyRunMs;
	life.players(2, t);
	life.players(0, t + 1000);
	CHECK(life.state() == ServerState::Draining);
	life.lost();
	CHECK(life.state() == ServerState::Lost);
	CHECK(!life.want_start()); // the pause was running: nobody is left to want it
	CHECK(!life.want_stop(t + 99999999));
	life.players(1, t + 5000);
	CHECK(life.want_start());

	// A process that exits by itself (the game closed, the window killed) is a loss too.
	ServerLife b;
	b.players(1, kT0);
	b.started(kT0);
	b.ready();
	b.stopped(); // nobody ordered it
	CHECK(b.state() == ServerState::Lost);
	CHECK(b.want_start());
}

// Reports that do not fit the state (late, duplicated, from an old process) change nothing.
TEST(server_life_stale_signals_ignored)
{
	ServerLife life;
	life.ready(); // nothing was started
	CHECK(life.state() == ServerState::Off);
	life.stopped();
	CHECK(life.state() == ServerState::Off);
	life.lost();
	CHECK(life.state() == ServerState::Off);
	life.stopping(kT0);
	CHECK(life.state() == ServerState::Off);

	life.players(1, kT0);
	life.started(kT0);
	life.started(kT0 + 1); // a second launch of a running process
	CHECK(life.state() == ServerState::Starting);
	life.ready();
	life.ready(); // a duplicate
	CHECK(life.state() == ServerState::Serving);
	life.started(kT0 + 2);
	CHECK(life.state() == ServerState::Serving);

	// A clock that goes back (two sources) never makes a pause longer or shorter than it should.
	life.players(0, kT0 + 10000);
	life.players(0, kT0 + 1000);
	CHECK(life.want_stop(kT0 + 10000 + life.linger_ms));
	CHECK(!life.want_stop(kT0 + 10000 + life.linger_ms - 1));
}

// A process that dies again and again before it serves anybody is not started for ever: after kMaxStartFailures in a row
// the world server gives up, want_start() stays false and the caller returns the movers to where they were.
TEST(server_life_crash_loop_gives_up)
{
	uint64_t t = kT0;
	ServerLife life;
	life.players(1, t);

	// 1: dies while it loads.
	CHECK(life.want_start());
	life.started(t);
	life.lost();
	CHECK_EQ(life.failures(), uint32_t(1));
	CHECK(!life.gave_up());

	// 2: loads, takes the player, dies at once.
	CHECK(life.want_start());
	t += 1000;
	life.started(t);
	life.ready();
	life.players(1, t + 2000);
	life.lost();
	CHECK_EQ(life.failures(), uint32_t(2));
	CHECK(!life.gave_up());
	CHECK(life.want_start());

	// 3: loads with nobody on the map (the player gave up waiting), dies in the pause: nobody was served on it.
	t += 5000;
	life.started(t);
	life.players(0, t + 100);
	life.ready();
	CHECK(life.state() == ServerState::Ready);
	life.lost();
	CHECK_EQ(life.failures(), uint32_t(3));
	CHECK(life.gave_up());

	// Given up: no more launches, whatever the players want.
	life.players(2, t + 6000);
	CHECK(life.state() == ServerState::Lost);
	CHECK(!life.want_start());
	CHECK(!life.running());

	// A stale report of the dead process counts for nothing.
	life.lost();
	life.stopped();
	CHECK_EQ(life.failures(), uint32_t(3));

	// The hung start is a failure as well (the caller kills it and reports it lost).
	ServerLife h;
	h.players(1, kT0);
	for (uint32_t i = 0; i < kMaxStartFailures; ++i)
	{
		CHECK(!h.gave_up());
		CHECK(h.want_start());
		h.started(kT0 + i * kStartTimeoutMs);
		CHECK(h.want_stop(kT0 + (i + 1) * kStartTimeoutMs));
		h.lost();
	}
	CHECK(h.gave_up() && !h.want_start());

	// The way back: the players are gone (the movers went back), then somebody tries again - a fresh series.
	h.players(0, kT0 + 9 * kStartTimeoutMs);
	CHECK(!h.gave_up());
	CHECK_EQ(h.failures(), uint32_t(0));
	h.players(1, kT0 + 9 * kStartTimeoutMs + 5000);
	CHECK(h.want_start());

	// ... or the caller allows it at once, with players still waiting.
	ServerLife r;
	r.players(1, kT0);
	for (uint32_t i = 0; i < kMaxStartFailures; ++i)
	{
		r.started(kT0 + i);
		r.lost();
	}
	CHECK(r.gave_up() && !r.want_start());
	r.retry_allowed();
	CHECK(!r.gave_up() && r.want_start());
	CHECK_EQ(r.failures(), uint32_t(0));
}

// A server that has lived kHealthyRunMs after Ready has proved itself: a death after that is a crash, not a failed start,
// and the failures before it are forgotten. Ready alone proves nothing (a map that loads and dies at the first player).
TEST(server_life_ready_resets_failures)
{
	uint64_t t = kT0;
	ServerLife life;
	life.players(1, t);

	// Two failed starts, then a server that comes up and lives.
	life.started(t);
	life.lost();
	life.started(t + 1000);
	life.lost();
	CHECK_EQ(life.failures(), uint32_t(2));
	t += 2000;
	life.started(t);
	life.ready();
	CHECK(life.state() == ServerState::Serving);
	CHECK_EQ(life.failures(), uint32_t(2)); // Ready alone does not clear them
	life.players(1, t + kHealthyRunMs - 1);
	CHECK_EQ(life.failures(), uint32_t(2));
	life.players(1, t + kHealthyRunMs);
	CHECK_EQ(life.failures(), uint32_t(0)); // it lived

	// A later crash starts a fresh series: it takes kMaxStartFailures new failures to give up.
	t += kHealthyRunMs + 1000;
	life.lost();
	CHECK_EQ(life.failures(), uint32_t(0));
	CHECK(life.want_start());
	for (uint32_t i = 0; i < kMaxStartFailures - 1; ++i)
	{
		life.started(t + i);
		life.lost();
	}
	CHECK(!life.gave_up());
	life.started(t + 10);
	life.lost();
	CHECK(life.gave_up());

	// A server that loads and dies at once does not reset anything: the loop is still counted.
	ServerLife loop;
	loop.players(1, kT0);
	for (uint32_t i = 0; i < kMaxStartFailures; ++i)
	{
		CHECK(loop.want_start());
		loop.started(kT0 + i * 1000);
		loop.ready();
		loop.players(1, kT0 + i * 1000 + 5000); // 5 s of life, not 30
		loop.lost();
	}
	CHECK(loop.gave_up());

	// A server that dies after living long, but the clock was not told (players() not called since): it is judged by the
	// last time the clock was told - a failure, the careful way.
	ServerLife blind;
	blind.players(1, kT0);
	blind.started(kT0);
	blind.ready();
	blind.lost();
	CHECK_EQ(blind.failures(), uint32_t(1));

	// A clean stop clears the series too.
	ServerLife clean;
	clean.players(1, kT0);
	clean.started(kT0);
	clean.lost();
	clean.started(kT0 + 10);
	clean.ready();
	clean.stopping(kT0 + 20);
	clean.stopped();
	CHECK(clean.state() == ServerState::Off);
	CHECK_EQ(clean.failures(), uint32_t(0));
}

// Which states count as "a map server is running" for the cap (decide_move's `running`).
TEST(server_life_running_counts)
{
	ServerLife life;
	CHECK(!life.running()); // Off
	life.players(1, kT0);
	CHECK(!life.running()); // wanted, not launched
	life.started(kT0);
	CHECK(life.state() == ServerState::Starting && life.running()); // a process is loading: it takes a place
	life.ready();
	CHECK(life.state() == ServerState::Serving && life.running());
	life.players(0, kT0 + 1000);
	CHECK(life.state() == ServerState::Draining && life.running()); // the pause: still there
	life.players(1, kT0 + 2000);
	life.stopping(kT0 + 3000);
	CHECK(life.state() == ServerState::Stopping && !life.running()); // it is on its way out: its place is free
	life.stopped();
	CHECK(life.state() == ServerState::Off && !life.running());

	life.started(kT0 + 4000);
	life.lost();
	CHECK(life.state() == ServerState::Lost && !life.running()); // dead

	ServerLife idle; // loaded with nobody on it
	idle.players(1, kT0);
	idle.started(kT0);
	idle.players(0, kT0 + 1);
	idle.ready();
	CHECK(idle.state() == ServerState::Ready && idle.running());
}

// ---------------------------------------------------------------- the flush round before a save

TEST(flush_round_all_reply)
{
	FlushRound r;
	CHECK(!r.active());
	CHECK(!r.done(kT0)); // nothing started: not "done" either

	CHECK(r.start(7, FlushWhy::Save, {10, 11, 12}, kT0));
	CHECK(r.active());
	CHECK_EQ(r.round(), uint32_t(7));
	CHECK(r.why() == FlushWhy::Save);
	CHECK(!r.done(kT0));
	CHECK_EQ(r.missing(), (Peers{10, 11, 12}));

	r.reply(11, 7);
	r.reply(10, 7);
	CHECK(!r.done(kT0 + 100));
	CHECK_EQ(r.missing(), (Peers{12}));
	r.reply(11, 7); // a duplicate changes nothing
	CHECK_EQ(r.missing(), (Peers{12}));
	r.reply(12, 7);
	CHECK(r.done(kT0 + 200));
	CHECK(r.complete());
	CHECK(!r.timed_out(kT0 + 200));
	CHECK(r.missing().empty());
}

// A map server that does not answer holds the save for kFlushTimeoutMs, then the save goes by its last stream.
TEST(flush_round_timeout_lists_laggards)
{
	FlushRound r;
	CHECK(r.start(3, FlushWhy::Move, {1, 2, 3}, kT0));
	r.reply(1, 3);
	r.reply(3, 3);
	CHECK(!r.done(kT0 + kFlushTimeoutMs - 1));
	CHECK(r.done(kT0 + kFlushTimeoutMs));
	CHECK(!r.complete());
	CHECK(r.timed_out(kT0 + kFlushTimeoutMs));
	CHECK_EQ(r.missing(), (Peers{2})); // for the log line

	// The late answer still counts (the caller may look again before it writes the save).
	r.reply(2, 3);
	CHECK(r.complete());
	CHECK(r.missing().empty());
}

// An answer to another round (a reply that was late for the one before) is not an answer to this one.
TEST(flush_round_stale_ignored)
{
	FlushRound r;
	CHECK(r.start(5, FlushWhy::Save, {1, 2}, kT0));
	r.reply(1, 4); // the round before
	r.reply(1, 6); // a round that was not asked
	r.reply(1, 0); // round 0 is the snapshot stream, not an answer
	r.reply(9, 5); // a server that was not asked
	CHECK_EQ(r.missing(), (Peers{1, 2}));
	CHECK(!r.done(kT0 + 1));

	// A new round supersedes the old one at once; the old round's answers do not count for it.
	CHECK(r.start(6, FlushWhy::Stop, {2, 3}, kT0 + 500));
	CHECK_EQ(r.round(), uint32_t(6));
	CHECK(r.why() == FlushWhy::Stop);
	r.reply(2, 5);
	CHECK_EQ(r.missing(), (Peers{2, 3}));
	CHECK(!r.done(kT0 + 500 + kFlushTimeoutMs - 1)); // the clock of the new round
	r.reply(2, 6);
	r.reply(3, 6);
	CHECK(r.done(kT0 + 600));
}

TEST(flush_round_empty_and_invalid)
{
	// No map server: nothing to wait for, the round is done at once.
	FlushRound r;
	CHECK(r.start(1, FlushWhy::HostMove, {}, kT0));
	CHECK(r.active());
	CHECK(r.done(kT0));
	CHECK(r.complete());

	// Round 0 is the stream, it cannot be started; the round before it stays as it was.
	FlushRound s;
	CHECK(s.start(2, FlushWhy::Save, {4}, kT0));
	CHECK(!s.start(0, FlushWhy::Save, {5}, kT0 + 10));
	CHECK_EQ(s.round(), uint32_t(2));
	CHECK_EQ(s.missing(), (Peers{4}));

	// A server listed twice is one server.
	FlushRound d;
	CHECK(d.start(9, FlushWhy::Save, {6, 6, 7, 6}, kT0));
	CHECK_EQ(d.missing(), (Peers{6, 7}));
	d.reply(6, 9);
	d.reply(7, 9);
	CHECK(d.done(kT0));

	// The caller is finished with the round.
	d.clear();
	CHECK(!d.active());
	CHECK(!d.done(kT0 + kFlushTimeoutMs));
}

TEST(flush_round_reasons)
{
	// The numbers of LevelFlush.why on the wire.
	CHECK_EQ(int(FlushWhy::Save), 1);
	CHECK_EQ(int(FlushWhy::Move), 2);
	CHECK_EQ(int(FlushWhy::Stop), 3);
	CHECK_EQ(int(FlushWhy::HostMove), 4);
}
