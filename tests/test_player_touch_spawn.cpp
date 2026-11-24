// Anomaly Coop unit tests: TZ P75 (review 2026-11-24), the snapshots that may place another player's avatar that has just
// appeared on this machine (xrCoop/coop_player_touch_rules.h snapshot_counts, used by coop_players.cpp on_object_spawn).
// The race: players::drive_avatar holds the newest snapshot it has. On the host of Coop a client's snapshots outlive the
// host's own world change (players::reset does not run there), so his avatar that appears on the new level was put, for a
// frame, where he stood on the old one: its first distance switched the pair on, then his real spot was the host's.
// Server: a player who stayed on a level keeps the snapshots of one who left it until he comes back (same local id).
#include "test_util.h"

#include "coop_player_touch_rules.h"

#include <cmath>
#include <cstdint>
#include <deque>
#include <limits>

using namespace coop;

namespace
{
// The stream gap of coop_players.cpp (kStreamGapMs): no state for this long = the stream ended.
constexpr uint64_t kGapMs = 3000;

struct Snap
{
	uint64_t at; // local time (players.cpp Sample::local_time)
	float x; // where he stood, along one axis
};

// coop_players.cpp on_object_spawn: what is left of an avatar's snapshots when its object appears here at `now` (the same
// player_touch::drop_stale it calls on its deque of samples).
void cull(std::deque<Snap>& snaps, uint64_t now)
{
	player_touch::drop_stale(snaps, now, kGapMs, [](const Snap& s) { return s.at; });
}

// One frame of my pair with his avatar: drive_avatar places it from the newest snapshot (it holds the newest one), and the
// distance counts once it has placed it (apart_known). I stand at x = 0; no exit and no spawn place near either of us.
bool frame(const std::deque<Snap>& snaps, bool& placed, bool& off)
{
	float x = 0.f;
	if (!snaps.empty())
	{
		x = snaps.back().x;
		placed = true;
	}
	return player_touch::collides(off, false, false, player_touch::apart_known(placed, std::fabs(x)));
}
} // namespace

TEST(player_touch_snapshot_of_the_stream_before_the_avatar_appeared_does_not_place_it)
{
	using player_touch::snapshot_counts;
	const uint64_t spawn = 100000;
	CHECK(!snapshot_counts(spawn - 25000, spawn, kGapMs)); // his last one on the old level, a load ago
	CHECK(!snapshot_counts(spawn - kGapMs - 1, spawn, kGapMs));
	CHECK(snapshot_counts(spawn - kGapMs, spawn, kGapMs)); // the stream gap itself is still the same stream
	CHECK(snapshot_counts(spawn - 200, spawn, kGapMs)); // came a moment before his object did: he is there now
	CHECK(snapshot_counts(spawn + 40, spawn, kGapMs)); // a clock offset that drifted a little ahead
	CHECK(snapshot_counts(0, 0, kGapMs)); // the start of the clock
}

TEST(player_touch_avatar_placed_from_an_old_level_does_not_switch_the_pair_on)
{
	// RED before P75 (probe temp/r68/collide/probe/touch_probe.exe): appeared -> not placed -> first placed from the old snapshot
	// 20 m off -> ON -> his real spot 0.3 m from me -> they collide, and my actor is pushed out of his avatar.
	std::deque<Snap> snaps = {{70000, 20.f}, {70050, 20.1f}}; // his last states on the level we both left
	const uint64_t spawn = 100000; // the host loaded, he loaded, his avatar appears here
	bool placed = false, off = false;
	player_touch::appeared(off);
	cull(snaps, spawn);
	CHECK(snaps.empty());
	CHECK(!frame(snaps, placed, off)); // not placed: it stands where it spawned, the pair stays off
	CHECK(!placed);
	snaps.push_back({spawn + 300, 0.3f}); // his first state from the new level: on my spot
	CHECK(!frame(snaps, placed, off)); // one in the other: pass through
	CHECK(placed);
	snaps.push_back({spawn + 2000, 3.5f}); // he walks off
	CHECK(frame(snaps, placed, off));
}

TEST(player_touch_fresh_snapshot_that_came_before_the_avatar_is_kept)
{
	// The review's warning: do not drop everything at the spawn. A player's state may come before his character does (Server:
	// the map server streams his states while the world brings his character here); it tells where he is now.
	std::deque<Snap> snaps = {{50000, 40.f}, {99800, 12.f}, {99850, 12.1f}}; // an old one, then the stream he sends now
	const uint64_t spawn = 100000;
	cull(snaps, spawn);
	CHECK_EQ(snaps.size(), size_t(2));
	bool placed = false, off = false;
	player_touch::appeared(off);
	CHECK(frame(snaps, placed, off)); // placed at once where he is, 12 m from me: bodies, as in a usual arrival far away
	CHECK(placed);
}
