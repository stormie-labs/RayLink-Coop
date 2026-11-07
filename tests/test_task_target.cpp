// Anomaly Coop unit tests: when the host sends the place of a task's target (xrCoop/coop_task_target.h, tasks audit C1:
// a client's spot, edge pointer and compass stood at the place the target had when the client joined).
#include "test_util.h"

#include "coop_task_target.h"

using coop::task_target::due;
using coop::task_target::kMinGapMs;
using coop::task_target::moved;
using coop::task_target::Place;

namespace
{
Place at(float x, float y, float z, uint16_t vertex)
{
	Place p;
	p.x = x;
	p.y = y;
	p.z = z;
	p.game_vertex = vertex;
	return p;
}
} // namespace

// A new target goes out at once, whatever the clock says.
TEST(task_target_first_place_is_sent)
{
	const Place p = at(1, 2, 3, 7);
	CHECK(due(Place(), 0, p, 1));
	CHECK(due(Place(), 0, p, 500000));
}

// Standing still costs nothing.
TEST(task_target_standing_still_is_not_sent)
{
	const Place p = at(100, 0, 100, 7);
	CHECK(!due(p, 1000, p, 1000 + 10 * kMinGapMs));
	CHECK(!due(p, 1000, at(104, 0, 100, 7), 1000 + 10 * kMinGapMs));
}

TEST(task_target_a_walk_is_sent)
{
	const Place p = at(100, 0, 100, 7);
	CHECK(due(p, 1000, at(105, 0, 100, 7), 1000 + kMinGapMs));
	CHECK(due(p, 1000, at(100, 6, 100, 7), 1000 + kMinGapMs));
	CHECK(moved(p, at(103, 4, 100, 7))); // exactly 5 m
}

// A target that runs still goes out at most once per gap.
TEST(task_target_rate_limit)
{
	const Place p = at(100, 0, 100, 7);
	CHECK(!due(p, 1000, at(900, 0, 100, 7), 1000 + kMinGapMs - 1));
	CHECK(due(p, 1000, at(900, 0, 100, 7), 1000 + kMinGapMs));
}

// Another game vertex can be another level: the name of the map comes from it, however near the numbers are.
TEST(task_target_new_game_vertex_is_a_move)
{
	const Place p = at(100, 0, 100, 7);
	CHECK(moved(p, at(100, 0, 100, 8)));
	CHECK(due(p, 1000, at(100, 0, 100, 8), 1000 + kMinGapMs));
	CHECK(!due(p, 1000, at(100, 0, 100, 8), 1000 + kMinGapMs - 1));
}

// --- client: what it does with the host's place (owner 2026-11-07, GAMMA "General cleanup": the markers differ)
using coop::task_target::Here;
using coop::task_target::Take;
using coop::task_target::take;

namespace
{
Here here(bool known, bool online, bool level_object, bool map_authority)
{
	Here h;
	h.known = known;
	h.online = online;
	h.level_object = level_object;
	h.map_authority = map_authority;
	return h;
}
} // namespace

// A dominance task's target is a squad the host keeps online (squad.force_online). A squad has no game object of its own
// (CSE_ALifeOnlineOfflineGroup::switch_online brings its members online, not itself): the spot and the compass read the
// squad's server entity, and on a client nothing moves an online squad's entity (the commander's binder that copies his
// place into it, sim_squad_scripted:update, runs on the host only). The host's place is the only one there is.
TEST(task_target_online_squad_takes_the_hosts_place)
{
	CHECK(take(here(true, true, false, false)) == Take::Online);
}

// An online creature is a game object here: its spot follows that object, which the host's updates move.
TEST(task_target_online_object_follows_itself)
{
	CHECK(take(here(true, true, true, false)) == Take::Follow);
	CHECK(take(here(true, true, true, true)) == Take::Follow);
}

TEST(task_target_offline_copy_takes_the_hosts_place)
{
	CHECK(take(here(true, false, false, false)) == Take::Offline);
	CHECK(take(here(true, false, false, true)) == Take::Offline); // as before on a map server: offline is the world server's
}

// A map server computes its own level: the commander's binder runs there and moves the squad.
TEST(task_target_online_squad_of_a_map_server_is_its_own)
{
	CHECK(take(here(true, true, false, true)) == Take::Own);
}

TEST(task_target_unknown_here)
{
	CHECK(take(here(false, false, false, false)) == Take::Unknown);
	CHECK(take(here(false, true, true, true)) == Take::Unknown);
}

// An online item in a holder goes with its holder (its game object is the holder's business): not placed.
TEST(task_target_online_held_item_goes_with_its_holder)
{
	Here h = here(true, true, false, false);
	h.held = true;
	CHECK(take(h) == Take::Follow);
	h.online = false;
	CHECK(take(h) == Take::Offline); // offline it took the host's place before, and still does
}

// The "unknown here" line: the first one at once, then once a minute per id.
TEST(task_target_unknown_log_rate)
{
	using coop::task_target::kUnknownLogMs;
	using coop::task_target::log_due;
	CHECK(log_due(0, 5));
	CHECK(!log_due(1000, 1000 + kUnknownLogMs - 1));
	CHECK(log_due(1000, 1000 + kUnknownLogMs));
}
