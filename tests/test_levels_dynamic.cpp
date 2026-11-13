// Anomaly Coop unit tests: the dynamic mode of the map servers (coop_levels_dynamic.h; docs/SPLIT_LEVELS.md, "Жизнь Mk"). The owner's
// idea for build 50: as many maps as players + 1; a map nobody stands on makes room for a map somebody wants; an empty map leaves after
// a while. The lead's contract: the cap, no refusal while an empty map exists (the one empty longest goes), one warm map with the long
// linger and a short one for the others, no linger at all when the machine is short of memory.
#include "test_util.h"

#include "coop_levels_dynamic.h"

#include <vector>

using namespace coop::levels;

namespace
{
constexpr uint64_t kT0 = 5000;

Seat seat(uint32_t peer, uint16_t level, bool in_world = true, bool plays = true)
{
	Seat s;
	s.peer = peer;
	s.level = level;
	s.in_world = in_world;
	s.plays = plays;
	return s;
}

MapSlot slot(uint16_t level, bool running, bool empty, uint64_t since = 0)
{
	MapSlot s;
	s.level = level;
	s.running = running;
	s.empty = empty;
	s.empty_since = since;
	return s;
}

// A server that came up for `n` players at `at`.
ServerLife serving(uint32_t n, uint64_t at)
{
	ServerLife life;
	life.players(n, at);
	life.started(at);
	life.ready();
	return life;
}
} // namespace

TEST(dynamic_defaults)
{
	// the machine's ceiling by default: a group of five has its "players + 1", and the world keeps 13 600 free ids (seven slices of
	// ids for map servers would leave it 9 500 over GAMMA's 27 300 objects)
	CHECK_EQ(kDefaultMaxMapServers, uint32_t(6));
	CHECK(kDefaultMaxMapServers <= coop::mapserver::kMaxBridges);
	CHECK_EQ(kDefaultLingerMs, uint32_t(600000)); // coop_mapserver_linger, the warm map: 10 min
	CHECK_EQ(kColdLingerMs, uint32_t(60000)); // every other empty map
	CHECK_EQ(kLowMemoryBytes, uint64_t(2) * 1024 * 1024 * 1024);
	CHECK(kMemoryBackBytes > kLowMemoryBytes);
}

// cap = min(players + 1, the machine's ceiling, kMaxBridges).
TEST(dynamic_cap)
{
	CHECK_EQ(map_server_cap(0, 7), uint32_t(1));
	CHECK_EQ(map_server_cap(1, 7), uint32_t(2)); // one player: his map and a warm one
	CHECK_EQ(map_server_cap(3, 7), uint32_t(4));
	CHECK_EQ(map_server_cap(6, 7), uint32_t(7));
	CHECK_EQ(map_server_cap(10, 7), uint32_t(7));
	CHECK_EQ(map_server_cap(3, 2), uint32_t(2)); // the machine's ceiling wins
	CHECK_EQ(map_server_cap(3, 0), uint32_t(0)); // 0: no map servers at all
	CHECK_EQ(map_server_cap(20, 99), coop::mapserver::kMaxBridges); // never over the slices of ids there are
}

// The players of the cap: everybody who plays and stands on (or loads into) a level; the seat of a world server that plays no
// character is nobody, nor is a player who is still choosing his character.
TEST(dynamic_players_now)
{
	Table t;
	CHECK_EQ(t.players(), uint32_t(0));
	t.set(seat(0, 3, true, false)); // the dedicated world server's own seat
	CHECK_EQ(t.players(), uint32_t(0));
	t.set(seat(1, 5));
	t.set(seat(2, 6, false)); // loading
	t.set(seat(3, kNoLevel, false)); // choosing a character
	CHECK_EQ(t.players(), uint32_t(2));
}

// What the rules see of a server: a slot. Empty = loaded and nobody on it, by the table (a player on his way counts).
TEST(dynamic_slot_of)
{
	ServerLife life = serving(1, kT0);
	MapSlot s = slot_of(4, life, 1, false);
	CHECK(s.running && !s.empty);

	life.players(0, kT0 + 1000); // Draining
	s = slot_of(4, life, 0, false);
	CHECK(s.running && s.empty);
	CHECK_EQ(s.empty_since, kT0 + 1000);

	// The life still says Draining, but the table has a player on his way to it already (host_player_moves sat him there): not empty.
	s = slot_of(4, life, 1, false);
	CHECK(!s.empty);

	// Kept through the host's move: not ours to stop.
	s = slot_of(4, life, 0, true);
	CHECK(!s.empty);

	// Starting, even with nobody (the players went back while it loads): not empty, only a loaded map is.
	ServerLife starting;
	starting.players(1, kT0);
	starting.started(kT0);
	starting.players(0, kT0 + 10);
	s = slot_of(9, starting, 0, false);
	CHECK(s.running && !s.empty);

	// Stopping: it holds no slot.
	life.stopping(kT0 + 2000);
	s = slot_of(4, life, 0, false);
	CHECK(!s.running && !s.empty);
}

// Under the cap nothing is stopped.
TEST(dynamic_room_under_cap)
{
	std::vector<uint16_t> stop = {99};
	const std::vector<MapSlot> slots = {slot(1, true, false), slot(2, true, true, kT0)};
	CHECK(room_for_one(slots, 3, stop));
	CHECK(stop.empty());
	CHECK(decide_move(Gate::Free, true, slots, 3, stop) == MoveVerdict::Go);
	CHECK(stop.empty());
}

// At the cap the server empty the longest goes; never one with a player, never one that loads.
TEST(dynamic_room_longest_empty)
{
	std::vector<uint16_t> stop;
	const std::vector<MapSlot> slots = {slot(1, true, false), slot(2, true, true, kT0 + 500), slot(3, true, true, kT0 + 100),
	    slot(4, true, false) /* Starting for a player on his way */};
	CHECK(decide_move(Gate::Free, true, slots, 4, stop) == MoveVerdict::Go);
	CHECK_EQ(stop.size(), size_t(1));
	CHECK_EQ(stop[0], uint16_t(3));
	CHECK(decide_move(Gate::BetterTogether, true, slots, 4, stop) == MoveVerdict::Go);
	CHECK_EQ(stop.size(), size_t(1));

	// Two emptied at the same moment: the lower level goes (the choice is the same every time).
	const std::vector<MapSlot> tie = {slot(5, true, true, kT0), slot(2, true, true, kT0)};
	CHECK(room_for_one(tie, 2, stop));
	CHECK_EQ(stop.size(), size_t(1));
	CHECK_EQ(stop[0], uint16_t(2));
}

// Every server has a player: refused, nothing stopped.
TEST(dynamic_room_all_busy)
{
	std::vector<uint16_t> stop = {7};
	const std::vector<MapSlot> slots = {slot(1, true, false), slot(2, true, false)};
	CHECK(decide_move(Gate::Free, true, slots, 2, stop) == MoveVerdict::RefuseCap);
	CHECK(stop.empty());
	CHECK(!room_for_one(slots, 2, stop));
}

// The cap fell under the running count (a player left the session): as many empties as it takes go, or none.
TEST(dynamic_room_cap_fell)
{
	std::vector<uint16_t> stop;
	const std::vector<MapSlot> two = {slot(1, true, false), slot(2, true, true, kT0), slot(3, true, true, kT0 + 1)};
	CHECK(decide_move(Gate::Free, true, two, 2, stop) == MoveVerdict::Go); // 3 running, cap 2: 2 must go
	CHECK_EQ(stop.size(), size_t(2));
	CHECK_EQ(stop[0], uint16_t(2));
	CHECK_EQ(stop[1], uint16_t(3));

	const std::vector<MapSlot> one = {slot(1, true, false), slot(2, true, false), slot(3, true, true, kT0)};
	CHECK(decide_move(Gate::Free, true, one, 2, stop) == MoveVerdict::RefuseCap); // only one empty for two places
	CHECK(stop.empty());
}

// Servers that do not run take no place and are no victims.
TEST(dynamic_room_not_running)
{
	std::vector<uint16_t> stop;
	const std::vector<MapSlot> slots = {slot(1, true, false), slot(2, false, false) /* Stopping */};
	CHECK(decide_move(Gate::Free, true, slots, 2, stop) == MoveVerdict::Go);
	CHECK(stop.empty());
}

// What the dynamic verdict leaves as it was: a served level, a Together move, an invalid gate, cap 0.
TEST(dynamic_room_unchanged)
{
	std::vector<uint16_t> stop;
	const std::vector<MapSlot> full = {slot(1, true, true, kT0), slot(2, true, false)};
	CHECK(decide_move(Gate::Free, false, full, 2, stop) == MoveVerdict::Go);
	CHECK(stop.empty());
	CHECK(decide_move(Gate::Together, true, full, 2, stop) == MoveVerdict::Board);
	CHECK(stop.empty());
	CHECK(decide_move(static_cast<Gate>(7), true, full, 2, stop) == MoveVerdict::RefuseInvalid);
	CHECK(stop.empty());
	const std::vector<MapSlot> none;
	CHECK(decide_move(Gate::Free, true, none, 0, stop) == MoveVerdict::RefuseCap); // coop_max_map_servers 0
	CHECK(stop.empty());
	CHECK(decide_move(Gate::Free, true, full, 0, stop) == MoveVerdict::RefuseCap); // stopping helps nothing under cap 0
	CHECK(stop.empty());
}

// The map emptied last is the warm one: the long linger. Every other empty map: at most 60 s. Low memory: none.
TEST(dynamic_lingers)
{
	const uint32_t linger = 600000;
	const std::vector<MapSlot> slots = {slot(1, true, false), slot(2, true, true, kT0), slot(3, true, true, kT0 + 300000)};
	CHECK(!warm(slots, 2));
	CHECK(warm(slots, 3));
	CHECK(!warm(slots, 1)); // a busy server is not "warm": it does not linger at all
	CHECK_EQ(linger_of(slots, 3, linger, false), linger);
	CHECK_EQ(linger_of(slots, 2, linger, false), kColdLingerMs);
	CHECK_EQ(linger_of(slots, 1, linger, false), linger); // the pause of a busy one is not running: any value
	CHECK_EQ(linger_of(slots, 3, 30000, false), uint32_t(30000)); // a setting under 60 s is the cold one too
	CHECK_EQ(linger_of(slots, 2, 30000, false), uint32_t(30000));
	CHECK_EQ(linger_of(slots, 3, linger, true), uint32_t(0));
	CHECK_EQ(linger_of(slots, 2, linger, true), uint32_t(0));
	CHECK_EQ(linger_of(slots, 42, linger, false), linger); // a level with no slot

	// The only empty map is warm.
	const std::vector<MapSlot> one = {slot(1, true, false), slot(2, true, true, kT0)};
	CHECK(warm(one, 2));
	CHECK_EQ(linger_of(one, 2, linger, false), linger);
}

// The group goes A -> B -> C. A stays warm 10 min while they are on B; when they go on to C, B is the warm one and A, empty for
// longer than 60 s, leaves at once.
TEST(dynamic_lingers_walk)
{
	const uint32_t setting = kDefaultLingerMs;
	ServerLife a = serving(2, kT0);
	ServerLife b;

	// They go to B: A empties at kT0 + 1000, B starts for them.
	a.players(0, kT0 + 1000);
	b.players(2, kT0 + 1000);
	b.started(kT0 + 1000);
	auto slots = [&]() { return std::vector<MapSlot>{slot_of(1, a, a.count(), false), slot_of(2, b, b.count(), false)}; };
	a.linger_ms = linger_of(slots(), 1, setting, false);
	CHECK_EQ(a.linger_ms, setting);
	CHECK(!a.want_stop(kT0 + 1000 + 300000)); // five minutes later A is still there
	b.ready();
	CHECK(b.state() == ServerState::Serving);

	// Five minutes on B, then they go to C: B empties now.
	const uint64_t t = kT0 + 1000 + 300000;
	b.players(0, t);
	a.players(0, t);
	a.linger_ms = linger_of(slots(), 1, setting, false);
	b.linger_ms = linger_of(slots(), 2, setting, false);
	CHECK_EQ(b.linger_ms, setting);
	CHECK_EQ(a.linger_ms, kColdLingerMs);
	CHECK(a.want_stop(t)); // its 60 s are long over
	CHECK(!b.want_stop(t + setting - 1));
	CHECK(b.want_stop(t + setting));
}

// The memory guard: low under 2 GB available, back over 2.5 GB (no line per frame at the border).
TEST(dynamic_memory_low)
{
	const uint64_t gb = uint64_t(1024) * 1024 * 1024;
	CHECK(!memory_low(false, 8 * gb));
	CHECK(!memory_low(false, 2 * gb));
	CHECK(memory_low(false, 2 * gb - 1));
	CHECK(memory_low(true, 2 * gb + 1)); // still low until it is clearly back
	CHECK(memory_low(true, kMemoryBackBytes - 1));
	CHECK(!memory_low(true, kMemoryBackBytes));
	CHECK(memory_low(false, 0)); // nothing available is low
}

// One player, split levels: cap 2. On A, he goes to B: A stays warm. He goes on to C: A (empty, the only one) makes room.
TEST(dynamic_one_player)
{
	std::vector<uint16_t> stop;
	const uint32_t cap = map_server_cap(1, kDefaultMaxMapServers);
	CHECK_EQ(cap, uint32_t(2));
	// He is on A; B has no server: 1 running of 2, it goes.
	CHECK(decide_move(Gate::Free, true, {slot(1, true, false)}, cap, stop) == MoveVerdict::Go);
	CHECK(stop.empty());
	// He is on B now, A is empty: to C, A goes.
	CHECK(decide_move(Gate::Free, true, {slot(1, true, true, kT0), slot(2, true, false)}, cap, stop) == MoveVerdict::Go);
	CHECK_EQ(stop.size(), size_t(1));
	CHECK_EQ(stop[0], uint16_t(1));
	// Back to A while A still lingers: A is served, nothing is started, nothing stops.
	CHECK(decide_move(Gate::Free, false, {slot(1, true, true, kT0), slot(2, true, false)}, cap, stop) == MoveVerdict::Go);
	CHECK(stop.empty());
}
