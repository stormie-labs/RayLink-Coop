// Anomaly Coop unit tests: TZ P50 (Dev 58), players under the map in the narrow tunnel of Cordon -> Garbage
// (xrCoop/coop_player_touch_rules.h, xrCoop/coop_arrival.h).
// The owner, 2026-11-22: in a group transition "the ones that do not fit just spawn under the map"; his decision: at level
// exits and at the places where players appear, player-player collision is off, and it comes back when the player moves a set
// distance away. Both modes: every machine that plays an actor collides it with the other players' avatars (Coop: the host
// and each client; Server: each client), so the rule is one and is asked by that machine for its own actor.
#include "test_util.h"

#include "coop_arrival.h"
#include "coop_player_touch_rules.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <utility>
#include <vector>

using namespace coop;

namespace
{
// A level graph for arrival::place: ground by 0.7 m cell (the AI map's cell), missing cells are walls or off the map.
struct FakeGround
{
	std::map<std::pair<int, int>, float> cells;
	void set(float x, float z, float y) { cells[key(x, z)] = y; }
	void set_cell(int i, int j, float y) { cells[{i, j}] = y; }
	static std::pair<int, int> key(float x, float z) { return {int(std::floor(x / 0.7f)), int(std::floor(z / 0.7f))}; }
	arrival::Ground fn() const
	{
		return [this](float x, float probe_y, float z, float& ground_y, uint32_t& vertex)
		{
			const auto it = cells.find(key(x, z));
			if (it == cells.end() || it->second > probe_y)
				return false;
			ground_y = it->second;
			vertex = uint32_t(it->first.first * 1000 + it->first.second + 500000);
			return true;
		};
	}
};

// A tunnel along x, 1.4 m wide (two AI cells, z in [-0.7, 0.7)), floor at y = 0, from x = 80 to x = 120. The level
// changer's point (the host's anchor) is in its middle.
FakeGround tunnel()
{
	FakeGround g;
	for (float x = 80.f; x < 120.f; x += 0.7f)
	{
		g.set(x + 0.35f, -0.35f, 0.f);
		g.set(x + 0.35f, 0.35f, 0.f);
	}
	return g;
}

float dist(const arrival::Point& a, const arrival::Point& b)
{
	const float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
	return std::sqrt(dx * dx + dy * dy + dz * dz);
}

bool same(const arrival::Point& a, const arrival::Point& b) { return dist(a, b) < 1e-3f; }

// The host's ring of coop_join.cpp host_place_movers: where it writes each mover's character, at the point's height.
const float kRing[][2] = {{1.5f, 0.f}, {0.f, 1.5f}, {-1.5f, 0.f}, {0.f, -1.5f}, {1.5f, 1.5f}, {-1.5f, -1.5f}, {1.5f, -1.5f}};

const float kInf = std::numeric_limits<float>::infinity();

// A tunnel along the diagonal x = z (no wall along a world axis), about 1.4 m wide (the AI cells (i, j) with |i - j| <= 1), floor
// at y = 0, around the point (100, 0, 100). The four axis spots of the host's ring are in its walls, the two diagonal ones in it.
FakeGround diagonal_tunnel()
{
	FakeGround g;
	for (int i = 120; i < 170; ++i)
		for (int j = i - 1; j <= i + 1; ++j)
			g.set_cell(i, j, 0.f);
	return g;
}

// Two capsules touch at about 0.75 m (actor 0.35 m, avatar 0.4 m): closer, the actor's body is pushed out of the avatar's.
constexpr float kTouch = 0.75f;

// One player of a group transition, as another machine sees him: where that machine's world spawns his character (the host's
// blind spot, written into the level change's save) and where his own machine puts his actor (the spot his snapshots tell).
struct Arrived
{
	arrival::Point spawned;
	arrival::Point at;
};

// The host and the movers of one group transition (coop_join.cpp host_place_movers, then each mover's machine
// on_alife_registered: arrival::place). The host stands on the point; mover i gets the ring spot i at the point's height.
std::vector<Arrived> group_arrival(const FakeGround& g, const arrival::Point& anchor, int movers)
{
	std::vector<Arrived> out;
	out.push_back({anchor, anchor});
	for (int i = 0; i < movers; ++i)
	{
		const arrival::Point own{anchor.x + kRing[i % 7][0], anchor.y, anchor.z + kRing[i % 7][1]};
		const arrival::Placed p = arrival::place(own, anchor, g.fn());
		out.push_back({own, p.at});
	}
	return out;
}

// One machine's pair through the arrival, frame by frame as coop_player_touch.cpp frame() runs it: both appeared; the avatar
// stands where it spawned here while its player still loads (no snapshot of his has placed it); then his snapshots put it on
// his spot. True when the two bodies collide on that spot.
bool collides_after_arrival(const arrival::Point& me, const Arrived& him)
{
	bool off = false;
	player_touch::appeared(off);
	for (int frame = 0; frame < 3; ++frame)
		player_touch::collides(off, false, false, player_touch::apart_known(false, dist(me, him.spawned)));
	return player_touch::collides(off, false, false, player_touch::apart_known(true, dist(me, him.at)));
}

// Every machine of the group, every avatar on it: the pairs that stand one in the other with their bodies on (the actor is
// pushed into the walls), and how many of the overlapping pairs had the avatar spawn kApart or more away (the case at stake).
int pushed_pairs(const std::vector<Arrived>& v, int& spawned_far)
{
	int pushed = 0;
	spawned_far = 0;
	for (size_t i = 0; i < v.size(); ++i)
		for (size_t j = 0; j < v.size(); ++j)
		{
			if (i == j || !(dist(v[i].at, v[j].at) < kTouch))
				continue;
			if (dist(v[i].at, v[j].spawned) >= player_touch::kApart)
				++spawned_far;
			if (collides_after_arrival(v[i].at, v[j]))
				++pushed;
		}
	return pushed;
}
} // namespace

TEST(player_touch_tunnel_arrival_puts_the_ones_that_do_not_fit_on_one_spot)
{
	// The cause in Coop, as the code places today (no change here): each mover's machine snaps its own character
	// (arrival::place); a ring spot in the tunnel wall falls back to the FIRST ring spot with ground, the same for all of them.
	const FakeGround g = tunnel();
	const arrival::Point anchor{100.f, 0.f, 0.f};
	arrival::Placed p[4];
	for (int i = 0; i < 4; ++i)
	{
		const arrival::Point own{anchor.x + kRing[i][0], anchor.y, anchor.z + kRing[i][1]};
		p[i] = arrival::place(own, anchor, g.fn());
	}
	CHECK(p[0].how == arrival::How::Snapped);
	CHECK(p[1].how == arrival::How::Moved); // his spot (z +1.5) is in the wall
	CHECK(p[2].how == arrival::How::Snapped);
	CHECK(p[3].how == arrival::How::Moved); // z -1.5: the other wall
	CHECK(same(p[1].at, p[0].at)); // on the first mover
	CHECK(same(p[3].at, p[0].at)); // and the fourth too: three capsules in one place
	for (const arrival::Placed& q : p)
		CHECK(std::fabs(q.at.y - (0.f + arrival::kLift)) < 1e-3f); // every one stands on the AI map's ground, none in the wall
}

TEST(player_touch_players_put_on_one_spot_do_not_collide_until_apart)
{
	// RED before the rule: the stub of today collides every pair always, and the actor is pushed out of the other body
	// (PHSimpleCharacter.cpp InitContact, PHActorCharacter.cpp restrictors, PHMovementControl.cpp UpdateObjectBox) into the
	// walls and the floor of the tunnel.
	bool off = false;
	player_touch::appeared(off); // the second one came into this machine's world on the first one
	CHECK(!player_touch::collides(off, false, false, 0.f));
	CHECK(!player_touch::collides(off, false, false, 0.5f)); // still inside the other capsule
	CHECK(!player_touch::collides(off, false, false, 2.9f)); // walking out of the tunnel one after the other
	CHECK(player_touch::collides(off, false, false, player_touch::kApart)); // 3 m apart: bodies again
	CHECK(!off);
}

TEST(player_touch_collision_back_stays_when_they_come_close_again)
{
	bool off = false;
	player_touch::appeared(off);
	CHECK(player_touch::collides(off, false, false, 10.f)); // he appeared far from me: bodies at once
	CHECK(player_touch::collides(off, false, false, 0.6f)); // later they walk into each other: they bump, as in a usual game
	CHECK(player_touch::collides(off, false, false, 0.f));
}

TEST(player_touch_at_a_level_exit_players_pass_through_each_other)
{
	using namespace player_touch;
	// The near flag of one player: within 4 m of the exit's shape (or inside it) is at the exit, past 4 m is away. Re-review 3
	// 2026-11-24: no band (it was in at 2 m, out past 4 m): a band is a memory, and the memory of his own machine and of another
	// one whose pair with him started later differ (player_touch_one_at_an_exit_when_the_other_came_holds_the_pair_alike).
	CHECK(!near_exit(false, kInf)); // no exit on the level
	CHECK(near_exit(false, 2.5f)); // walking up to it: at it within 4 m, whatever he was before
	CHECK(near_exit(false, 2.f));
	CHECK(near_exit(false, 0.f)); // inside the exit's zone
	CHECK(near_exit(true, 3.9f)); // walking off: at it up to 4 m
	CHECK(near_exit(true, 4.f));
	CHECK(near_exit(false, 4.f));
	CHECK(!near_exit(true, 4.1f));
	CHECK(!near_exit(false, 4.1f));
	// The pair: off while either of the two is at an exit, whatever the distance between them.
	bool off = false;
	player_touch::appeared(off);
	CHECK(collides(off, false, false, 5.f));
	CHECK(!collides(off, true, false, 0.4f)); // I walk into the exit's queue where he stands
	CHECK(!collides(off, false, true, 0.4f)); // he is in the queue, I am not
	CHECK(off);
	CHECK(!collides(off, false, false, 1.f)); // both left the exit together: not yet, they are still one in the other
	CHECK(collides(off, false, false, kApart));
}

TEST(player_touch_appearing_again_switches_the_pair_off)
{
	bool off = false;
	player_touch::appeared(off);
	CHECK(player_touch::collides(off, false, false, 20.f));
	player_touch::appeared(off); // he went to another level and came back, or my actor arrived anew
	CHECK(!player_touch::collides(off, false, false, 1.f));
	CHECK(player_touch::collides(off, false, false, 3.5f));
}

TEST(player_touch_numbers_that_are_not_numbers_never_switch_collision_on)
{
	const float nan = std::numeric_limits<float>::quiet_NaN();
	bool off = false;
	player_touch::appeared(off);
	CHECK(!player_touch::collides(off, false, false, nan));
	CHECK(off);
	CHECK(player_touch::near_exit(true, nan)); // no information: the flag stays as it was
	CHECK(!player_touch::near_exit(false, nan));
}

TEST(player_touch_an_avatar_its_player_has_not_placed_yet_keeps_the_pair_off)
{
	// Review 2026-11-23: an avatar stands where this machine's world spawned it (in a group arrival the host's blind ring spot)
	// until its player's snapshots are played; that spot is not where the player is, and an on pair stays on however close.
	using namespace player_touch;
	bool off = false;
	appeared(off);
	CHECK(!collides(off, false, false, apart_known(false, 3.35f))); // spawned 3.35 m off, its player still loading
	CHECK(off);
	CHECK(!collides(off, false, false, apart_known(false, 40.f))); // however far: not his place yet
	CHECK(!collides(off, false, false, apart_known(true, 0.f))); // his snapshots put it on my spot: one in the other
	CHECK(!collides(off, false, false, apart_known(true, 2.9f)));
	CHECK(collides(off, false, false, apart_known(true, kApart))); // 3 m apart where they really stand: bodies again
	CHECK(collides(off, false, false, apart_known(true, 0.f))); // and they bump as in a usual game
	bool lone = false;
	appeared(lone); // an arrival alone, 10 m from me, his first snapshot played
	CHECK(collides(lone, false, false, apart_known(true, 10.f)));
}

TEST(player_touch_group_arrival_in_a_diagonal_tunnel_pushes_nobody_into_the_walls)
{
	// The P50 case itself: host and 4 movers into a 1.4 m tunnel that is not along a world axis. All four ring spots of the
	// movers are in the walls, so each mover's machine puts him on the first ring spot with ground: all four on one spot. On a
	// mover's machine the avatars of movers 2 and 3 spawn on their blind spots 3.36 m away, then come onto his spot.
	const FakeGround g = diagonal_tunnel();
	const arrival::Point anchor{100.f, 0.f, 100.f};
	const std::vector<Arrived> v = group_arrival(g, anchor, 4);
	for (int i = 1; i <= 4; ++i)
		CHECK(v[i].at.y > 0.f && dist(v[i].at, v[1].at) < 1e-3f); // on the ground, all on one spot
	int spawned_far = 0;
	CHECK_EQ(pushed_pairs(v, spawned_far), 0);
	CHECK_EQ(spawned_far, 6); // (0,2) (0,3) (1,2) (1,3) (2,3) (3,2): the case is there
}

TEST(player_touch_group_arrival_of_six_in_a_straight_tunnel_pushes_nobody_into_the_walls)
{
	// A tunnel along x: with 6 movers the ring spot 5 (-1.5, -1.5) is 3.35 m from the spot 0 where five of them stand.
	const FakeGround g = tunnel();
	const arrival::Point anchor{100.f, 0.f, 0.f};
	const std::vector<Arrived> v = group_arrival(g, anchor, 6);
	int spawned_far = 0;
	CHECK_EQ(pushed_pairs(v, spawned_far), 0);
	CHECK_EQ(spawned_far, 4); // mover 5's avatar on the machines of movers 0, 1, 3 and 4
}

// --- TZ P75 (the owner 2026-11-23: "они все равно толкаются друг в друга ... место перехода и место спавна отличаются"):
// the places where players arrive on a level are zones of their own, besides the level exits. Re-review 2026-11-24: they are the
// same on every machine (the destination points of the level changers that lead here, from all.spawn): one machine with the pair
// off and the other with it on while the bodies touch is one player who walks through the other while the other one's actor is
// pushed out of an avatar that never yields.

namespace
{
void put(float out[3], const arrival::Point& p)
{
	out[0] = p.x;
	out[1] = p.y;
	out[2] = p.z;
}

struct P3
{
	float v[3];
};

P3 lerp(const P3& a, const P3& b, float k)
{
	return {{a.v[0] + (b.v[0] - a.v[0]) * k, a.v[1] + (b.v[1] - a.v[1]) * k, a.v[2] + (b.v[2] - a.v[2]) * k}};
}

// A walk through the points, `steps` frames a leg.
std::vector<P3> walk(const std::vector<P3>& pts, int steps)
{
	std::vector<P3> out;
	for (size_t i = 0; i + 1 < pts.size(); ++i)
		for (int s = 0; s < steps; ++s)
			out.push_back(lerp(pts[i], pts[i + 1], float(s) / float(steps)));
	out.push_back(pts.back());
	return out;
}

// One machine, as coop_player_touch.cpp keeps it: the arrival places of the level (read_places: the same on every machine), its
// actor's flags (g_me_near at a level exit, g_me_at_place at an arrival place), and one pair per other player's avatar (track).
// One frame of a pair is the rule's own player_touch::pair_frame, as frame() runs it. exits: level exits as points (a shape of
// no size: the distance to its point is the distance to its shape), the same on every machine.
struct Machine
{
	std::vector<float> places;
	std::vector<float> exits;
	bool my_at_place = false;
	bool my_near_exit = false;
	std::map<int, player_touch::Pair> pairs;

	explicit Machine(std::vector<float> level_places = {}, std::vector<float> level_exits = {})
	    : places(std::move(level_places)), exits(std::move(level_exits))
	{
	}
	// my actor appears here: every pair starts anew
	void my_spawn(const P3&, uint64_t)
	{
		my_at_place = false;
		my_near_exit = false;
		for (auto& it : pairs)
			player_touch::pair_start(it.second);
	}
	// his avatar appears here
	void his_spawn(int who, uint64_t) { player_touch::pair_start(pairs[who]); }
	float to_place(const P3& p) const { return player_touch::to_places(places.data(), places.size() / 3, p.v); }
	float to_exit(const P3& p) const { return player_touch::to_places(exits.data(), exits.size() / 3, p.v); }
	// my actor's flags, once a frame (frame() does it before the pairs)
	void tick(const P3& me)
	{
		my_near_exit = player_touch::near_exit(my_near_exit, to_exit(me));
		my_at_place = player_touch::near_spawn(my_at_place, to_place(me));
	}
	bool frame(int who, const P3& me, const P3& him, bool placed)
	{
		tick(me); // the same position twice gives the same flags
		return player_touch::pair_frame(pairs[who], me.v, my_near_exit || my_at_place, him.v, placed, to_exit(him), to_place(him));
	}
	bool frame(int who, const P3& me, const P3& him, float his_exit = std::numeric_limits<float>::infinity(), bool my_near = false)
	{
		tick(me);
		return player_touch::pair_frame(pairs[who], me.v, my_near || my_at_place, him.v, true, his_exit, to_place(him));
	}
};

std::vector<float> place_at(const P3& p) { return {p.v[0], p.v[1], p.v[2]}; }

struct Both
{
	int touching = 0; // frames the two bodies touch
	int one_sided = 0; // ... with the pair on on one machine and off on the other
	int on_both = 0; // ... with the pair on on both (they bump, as in a usual game)
};

// The pair of a (on machine ma) and b (on mb), frame by frame along their walks.
Both both_machines(Machine& ma, int a, Machine& mb, int b, const std::vector<P3>& wa, const std::vector<P3>& wb)
{
	Both r;
	for (size_t i = 0; i < wa.size() && i < wb.size(); ++i)
	{
		const bool on_a = ma.frame(b, wa[i], wb[i]);
		const bool on_b = mb.frame(a, wb[i], wa[i]);
		if (player_touch::distance3(wa[i].v, wb[i].v) < kTouch)
		{
			++r.touching;
			r.one_sided += on_a != on_b ? 1 : 0;
			r.on_both += on_a && on_b ? 1 : 0;
		}
	}
	return r;
}

constexpr int kA = 1, kB = 2;
} // namespace

TEST(player_touch_spawn_zone_is_8_m_and_has_no_memory)
{
	// Re-review 3 2026-11-24: the zone had a band (in at 6 m, out past 8 m). One who came by P and stepped off to 6-8 m was at the
	// place on his own machine and not on the machine of one whose pair with him started later: the pair one-sided while the
	// bodies touch. The flag is a function of where he stands: within 8 m of a place he is at it, past 8 m he is away.
	using namespace player_touch;
	const float nan = std::numeric_limits<float>::quiet_NaN();
	CHECK(near_spawn(true, 0.f)); // on the arrival point
	CHECK(near_spawn(false, 0.f));
	CHECK(near_spawn(true, 7.9f)); // walking off: at it up to 8 m
	CHECK(near_spawn(true, kSpawnFar));
	CHECK(!near_spawn(true, 8.1f)); // past 8 m: away
	CHECK(near_spawn(false, 6.5f)); // walking back: at it again within 8 m, whatever he was before
	CHECK(near_spawn(false, 7.9f));
	CHECK(near_spawn(false, kSpawnFar));
	CHECK(!near_spawn(false, 8.1f));
	CHECK(near_spawn(true, nan)); // no information: the flag stays as it was
	CHECK(!near_spawn(false, nan));

	// The level's places: the nearest one counts, none is infinity away.
	const float places[] = {100.f, 0.f, 0.f, 140.f, 0.f, 0.f};
	const float p[3] = {131.f, 0.f, 0.f};
	CHECK(std::fabs(to_places(places, 2, p) - 9.f) < 1e-4f);
	CHECK(std::fabs(to_places(places, 1, p) - 31.f) < 1e-4f);
	CHECK(std::isinf(to_places(places, 0, p)));

	// He arrives on the point x = 100, I stand 40 m off: his flag follows the loop, mine stays away.
	Machine m(place_at(P3{{100.f, 0.f, 0.f}}));
	const P3 me{{140.f, 0.f, 0.f}};
	m.his_spawn(kB, 0);
	const float xs[] = {100.f, 105.f, 107.9f, 108.1f, 93.5f, 94.f, 92.1f, 91.9f, 140.f};
	const bool in[] = {true, true, true, false, true, true, true, false, false};
	for (int i = 0; i < 9; ++i)
	{
		m.frame(kB, me, P3{{xs[i], 0.f, 0.f}});
		CHECK(m.pairs[kB].at_place == in[i]);
		CHECK(!m.my_at_place);
	}
	// His avatar not placed by his snapshots yet: where it stands says nothing, the flag keeps what it was.
	m.his_spawn(kB, 0);
	CHECK(!m.frame(kB, me, P3{{100.f, 0.f, 0.f}}, false));
	CHECK(!m.pairs[kB].at_place);
}

TEST(player_touch_two_on_the_spawn_place_3_to_4_m_apart_pass_through_until_both_leave_it)
{
	// RED before P75: the group ring puts movers 0 and 2 3.0 m apart and the diagonal spots 4.24 m apart; kApart (3 m) switched
	// such a pair on at its first frame, and the two bump at the spawn place as soon as one walks to the other.
	using namespace player_touch;
	const arrival::Point anchor{100.f, 0.f, 0.f};
	const float pairs[][2][2] = {{{kRing[0][0], kRing[0][1]}, {kRing[2][0], kRing[2][1]}}, // 3.0 m
	    {{kRing[4][0], kRing[4][1]}, {kRing[5][0], kRing[5][1]}}}; // 4.24 m
	for (const auto& pr : pairs)
	{
		P3 me{{anchor.x + pr[0][0], anchor.y, anchor.z + pr[0][1]}};
		P3 him{{anchor.x + pr[1][0], anchor.y, anchor.z + pr[1][1]}};
		Machine m(place_at(P3{{anchor.x, anchor.y, anchor.z}}));
		m.my_spawn(me, 1000);
		m.his_spawn(kB, 1500); // he came 0.5 s after me
		CHECK(distance3(me.v, him.v) >= kApart);
		CHECK(!m.frame(kB, me, him)); // both on their spots, 3+ m apart: still off
		P3 close{{me.v[0] + 0.3f, me.v[1], me.v[2]}}; // he walks to me at the spawn place
		CHECK(!m.frame(kB, me, close));
		P3 off3{{me.v[0] + 3.5f, me.v[1], me.v[2]}}; // he walks off 3.5 m, I stay on my spot
		CHECK(!m.frame(kB, me, off3));
		P3 me_far{{me.v[0] - 13.f, me.v[1], me.v[2]}}; // I walk 13 m off (past 8 m of the point), he is still at the place
		CHECK(!m.frame(kB, me_far, off3));
		P3 him_far{{me.v[0] + 13.f, me.v[1], me.v[2]}}; // both away from the place, 26 m apart: bodies again
		CHECK(m.frame(kB, me_far, him_far));
		CHECK(!m.pairs[kB].off);
	}
}

TEST(player_touch_spawn_zone_and_exit_zone_keep_their_own_flags)
{
	// Review 2026-11-24: the arrival place is a zone of its own (8 m), not the exits' flag (4 m) with another number.
	Machine m(place_at(P3{{0.f, 0.f, 0.f}}));
	const P3 me{{0.f, 0.f, 50.f}}; // I stand 50 m off the point: only his flags count
	m.my_spawn(me, 1000);
	m.his_spawn(kB, 900000);
	// He arrived on the point, 1 m from an exit's shape: at both places.
	CHECK(!m.frame(kB, me, P3{{0.f, 0.f, 0.f}}, 1.f));
	CHECK(m.pairs[kB].at_exit && m.pairs[kB].at_place);
	// 5 m off: away from the exit (past 4 m), still at the arrival place: the pair stays off.
	CHECK(!m.frame(kB, me, P3{{5.f, 0.f, 0.f}}, 5.f));
	CHECK(!m.pairs[kB].at_exit && m.pairs[kB].at_place);
	// 9 m off the point and 1.5 m from another exit: at that exit only.
	CHECK(!m.frame(kB, me, P3{{9.f, 0.f, 0.f}}, 1.5f));
	CHECK(m.pairs[kB].at_exit && !m.pairs[kB].at_place);
	// 7 m from the point and 4.5 m from that exit: at the place again (within 8 m), away from the exit (past 4 m).
	CHECK(!m.frame(kB, me, P3{{7.f, 0.f, 0.f}}, 4.5f));
	CHECK(!m.pairs[kB].at_exit && m.pairs[kB].at_place);
	// 8.5 m from the point and 3 m from the exit: at the exit, not at the place.
	CHECK(!m.frame(kB, me, P3{{8.5f, 0.f, 0.f}}, 3.f));
	CHECK(m.pairs[kB].at_exit && !m.pairs[kB].at_place);
	// Away from both: the pair is on again.
	CHECK(m.frame(kB, me, P3{{12.f, 0.f, 0.f}}, 4.5f));
}

TEST(player_touch_the_pair_is_alike_on_both_machines)
{
	// RED with a spawn place per player (review 2026-11-24, probe scratchpad/review-collide/asym_probe.cpp): the machine my world
	// came to gave the one who was there before a place of his own where he stood, his own machine did not.
	using namespace player_touch;
	const std::vector<float> P = place_at(P3{{0.f, 0.f, 0.f}}); // the arrival point of the exit both take
	{
		// Server: A came to the level long ago and waits 9 m from the arrival point P (outside the place); B arrives on P, walks
		// past A to 13 m and comes back up to him (0.6 m). Walking past, B is at the place, then less than 3 m from A: off on both
		// machines. When B comes back from 4 m off, both machines have the pair on and they bump.
		Machine ma(P), mb(P);
		ma.my_spawn(P3{{200.f, 0.f, 0.f}}, 1000);
		ma.his_spawn(kB, 600000);
		mb.my_spawn(P3{{0.f, 0.f, 0.f}}, 600000);
		mb.his_spawn(kA, 600300);
		const std::vector<P3> b = walk({{{0.f, 0.f, 0.f}}, {{13.f, 0.f, 0.f}}, {{9.6f, 0.f, 0.f}}}, 40);
		const std::vector<P3> a(b.size(), P3{{9.f, 0.f, 0.f}});
		const Both r = both_machines(ma, kA, mb, kB, a, b);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
		CHECK(r.on_both > 0 && r.on_both < r.touching);
	}
	{
		// Server: A waits on P itself (5 m off it); B arrives, walks off 11 m and back up to A: both at the place, off on both.
		Machine ma(P), mb(P);
		ma.my_spawn(P3{{0.f, 0.f, 0.f}}, 1000);
		ma.his_spawn(kB, 600000);
		mb.my_spawn(P3{{0.f, 0.f, 0.f}}, 600000);
		mb.his_spawn(kA, 600300);
		const std::vector<P3> b = walk({{{0.f, 0.f, 0.f}}, {{11.f, 0.f, 0.f}}, {{5.6f, 0.f, 0.f}}}, 40);
		const std::vector<P3> a(b.size(), P3{{5.f, 0.f, 0.f}});
		const Both r = both_machines(ma, kA, mb, kB, a, b);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
		CHECK_EQ(r.on_both, 0);
	}
	{
		// Coop: latecomer C appears at the host + 1.5 m (no arrival point there); the host steps 7.5 m aside; C walks round and up
		// to him: the pair comes on 3 m apart on both machines, as P50 had it.
		Machine mh, mc;
		mh.my_spawn(P3{{300.f, 0.f, 0.f}}, 1000);
		mh.his_spawn(kB, 700000);
		mc.my_spawn(P3{{1.5f, 0.f, 0.f}}, 700000);
		mc.his_spawn(kA, 700100);
		const std::vector<P3> c =
		    walk({{{1.5f, 0.f, 0.f}}, {{-8.f, 0.f, 0.f}}, {{-8.f, 0.f, 10.f}}, {{8.2f, 0.f, 10.f}}, {{8.2f, 0.f, 0.f}}}, 40);
		std::vector<P3> h = walk({{{0.f, 0.f, 0.f}}, {{7.5f, 0.f, 0.f}}}, 40);
		h.resize(c.size(), P3{{7.5f, 0.f, 0.f}});
		const Both r = both_machines(mh, kA, mc, kB, h, c);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// Server: A waits 40 m from P when B arrives: B walks out of the place and up to A: they bump on both machines.
		Machine ma(P), mb(P);
		ma.my_spawn(P3{{200.f, 0.f, 0.f}}, 1000);
		ma.his_spawn(kB, 600000);
		mb.my_spawn(P3{{0.f, 0.f, 0.f}}, 600000);
		mb.his_spawn(kA, 600300);
		const std::vector<P3> b = walk({{{0.f, 0.f, 0.f}}, {{39.6f, 0.f, 0.f}}}, 120);
		const std::vector<P3> a(b.size(), P3{{40.f, 0.f, 0.f}});
		const Both r = both_machines(ma, kA, mb, kB, a, b);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
		CHECK_EQ(r.on_both, r.touching);
	}
}

TEST(player_touch_three_on_one_spot_of_a_tunnel_walk_out_without_pushing_anybody)
{
	// The P50 tunnel with the P75 complaint. Host and 4 movers into the straight 1.4 m tunnel: movers 0, 1 and 3 stand on one
	// spot (the first test of this file). They walk out one after the other: mover 0 stops 5 m on to wait, mover 1 walks into
	// his back and waits there, mover 3 behind them; then all three walk out of the tunnel. Host and mover 2 stay where they
	// appeared. Every machine (each one's actor), every avatar on it, every 100 ms: no pair is on while the two bodies touch, and
	// no pair is on on one machine and off on the other.
	// RED before P75: mover 0 was 3.75 m ahead of mover 1 when 1 started, so their pair came on; then 1 walked into him (0.4 m).
	using namespace player_touch;
	const FakeGround g = tunnel();
	const arrival::Point anchor{100.f, 0.f, 0.f};
	const std::vector<Arrived> v = group_arrival(g, anchor, 4);
	CHECK(same(v[1].at, v[2].at) && same(v[1].at, v[4].at)); // three on one spot
	struct Leg
	{
		float t0, t1, x; // walks from where he is at t0 to x at t1
	};
	struct Walker
	{
		arrival::Point spot;
		int appears; // his load ends: the frame (100 ms) he appears in the world
		std::vector<Leg> legs;
	};
	const float x0 = v[1].at.x;
	const std::vector<Walker> w = {
	    {v[0].at, 0, {}}, // the host stays on the exit's point
	    {v[1].at, 5, {{2.f, 5.33f, x0 + 5.f}, {12.f, 20.33f, x0 + 17.5f}}}, // mover 0
	    {v[2].at, 10, {{4.5f, 7.57f, x0 + 4.6f}, {13.f, 19.27f, x0 + 14.f}}}, // mover 1: into mover 0's back (0.4 m)
	    {v[3].at, 15, {}}, // mover 2 stays
	    {v[4].at, 20, {{6.f, 8.67f, x0 + 4.f}, {14.f, 18.33f, x0 + 10.5f}}}, // mover 3: 0.6 m behind mover 1
	};
	auto where = [&](size_t i, float t)
	{
		float x = w[i].spot.x;
		for (const Leg& l : w[i].legs)
		{
			if (t <= l.t0)
				break;
			const float k = t >= l.t1 ? 1.f : (t - l.t0) / (l.t1 - l.t0);
			x = x + (l.x - x) * k;
			if (t < l.t1)
				break;
		}
		return P3{{x, w[i].spot.y, w[i].spot.z}};
	};
	std::vector<Machine> mach(w.size(), Machine({anchor.x, anchor.y, anchor.z}));
	int touching = 0, pushed = 0, one_sided = 0;
	bool on[8][8] = {};
	for (int f = 0; f <= 250; ++f)
	{
		const uint64_t now = uint64_t(f) * 100;
		const float t = f * 0.1f;
		// who appears where this frame: a machine's own load brings the ones already there, then its actor; one who comes later
		// appears on every machine that is up
		for (size_t m = 0; m < w.size(); ++m)
		{
			if (f == w[m].appears)
			{
				for (size_t j = 0; j < w.size(); ++j)
					if (j != m && w[j].appears < f)
						mach[m].his_spawn(int(j), now);
				float s[3];
				put(s, w[m].spot);
				mach[m].my_spawn(P3{{s[0], s[1], s[2]}}, now);
			}
			else if (f > w[m].appears)
				for (size_t j = 0; j < w.size(); ++j)
					if (j != m && w[j].appears == f)
						mach[m].his_spawn(int(j), now);
		}
		for (size_t m = 0; m < w.size(); ++m)
			for (size_t j = 0; j < w.size(); ++j)
				if (j != m && f >= w[m].appears && f >= w[j].appears)
					on[m][j] = mach[m].frame(int(j), where(m, t), where(j, t));
		for (size_t m = 0; m < w.size(); ++m)
			for (size_t j = m + 1; j < w.size(); ++j)
			{
				if (f < w[m].appears || f < w[j].appears)
					continue;
				const P3 a = where(m, t), b = where(j, t);
				if (distance3(a.v, b.v) < kTouch)
				{
					++touching;
					pushed += (on[m][j] ? 1 : 0) + (on[j][m] ? 1 : 0);
					one_sided += on[m][j] != on[j][m] ? 1 : 0;
				}
			}
	}
	// The three walked out: 10.5 m and more from their spot, 3.5 m and more apart: bodies again among them.
	const size_t walkers[] = {1, 2, 4};
	for (const size_t m : walkers)
		for (const size_t j : walkers)
			if (j != m)
				CHECK(on[m][j]);
	// Host and mover 2 stand where they appeared: off with everybody, on every machine.
	for (size_t m = 1; m < w.size(); ++m)
		CHECK(!on[m][0] && !on[0][m]);
	CHECK(!on[1][3] && !on[3][1]);
	CHECK(touching > 0); // the case is there
	CHECK_EQ(pushed, 0);
	CHECK_EQ(one_sided, 0);
}

// --- Re-review 2026-11-24 (probe scratchpad/rereview-collide/probe.cpp): the two machines of a pair must hold it in the same
// state while the bodies touch, also when the first one walks off between his going live and the second one's, when two join
// a few seconds apart, and when one sat in a car while the other came. Time runs by 100 ms; each machine plays its actor
// (frames from its live on, none while it sits in a car: no body), the avatars appear on it when its world gets them, and an
// avatar is placed from its player's snapshots from his live on (0.2 s late: interpolation and network), not while he sits.
namespace
{
struct Way
{
	double t;
	float x, z;
};

struct Walker
{
	double spawn = 0; // his actor appears on his machine
	double live = 0; // his screen is off: his frames run, his snapshots flow, he may move
	std::vector<Way> path;
	double seat0 = -1, seat1 = -1; // sits in a car: no actor body on his machine
	bool seated(double t) const { return t >= seat0 && t < seat1; }
	P3 at(double t) const
	{
		if (t <= path.front().t)
			return P3{{path.front().x, 0.f, path.front().z}};
		for (size_t i = 1; i < path.size(); ++i)
			if (t <= path[i].t)
			{
				const float k = float((t - path[i - 1].t) / (path[i].t - path[i - 1].t));
				return P3{{path[i - 1].x + (path[i].x - path[i - 1].x) * k, 0.f, path[i - 1].z + (path[i].z - path[i - 1].z) * k}};
			}
		return P3{{path.back().x, 0.f, path.back().z}};
	}
};

struct Run
{
	int touching = 0, one_sided = 0;
	int on_both = 0; // touching frames with the pair on on both machines (they bump, as in a usual game)
};

// appear[x][y]: the second y's avatar appears on x's machine (before x's spawn: in x's load); < 0: never. exits: the level's
// exits as points (Machine::exits).
Run play(const std::vector<Walker>& w, const std::vector<std::vector<double>>& appear, double end,
    const std::vector<float>& places, const std::vector<float>& exits = {})
{
	const size_t n = w.size();
	std::vector<Machine> m(n, Machine(places, exits));
	std::vector<std::vector<bool>> present(n, std::vector<bool>(n, false)), placed = present, on = present;
	Run r;
	const double dt = 0.1, lag = 0.2;
	for (int f = 0; f * dt <= end; ++f)
	{
		const double t = f * dt;
		const uint64_t now = uint64_t(std::llround(t * 1000.0));
		auto at = [&](double ev) { return ev >= 0 && std::fabs(ev - t) < dt / 2; };
		for (size_t x = 0; x < n; ++x)
		{
			for (size_t y = 0; y < n; ++y)
				if (y != x && at(appear[x][y]))
				{
					present[x][y] = true;
					placed[x][y] = false;
					m[x].his_spawn(int(y), now);
				}
			if (at(w[x].spawn))
				m[x].my_spawn(w[x].at(t), now);
		}
		for (size_t x = 0; x < n; ++x)
		{
			if (t < w[x].live || w[x].seated(t))
				continue; // no frame of his machine's touch pass: no world up yet, or no actor body
			const P3 me = w[x].at(t);
			m[x].tick(me);
			for (size_t y = 0; y < n; ++y)
			{
				if (y == x || !present[x][y])
					continue;
				if (!w[y].seated(t) && t >= w[y].live + lag)
					placed[x][y] = true;
				on[x][y] = m[x].frame(int(y), me, w[y].at(t - lag), placed[x][y]);
			}
		}
		for (size_t x = 0; x < n; ++x)
			for (size_t y = x + 1; y < n; ++y)
			{
				if (!present[x][y] || !present[y][x] || t < w[x].live || t < w[y].live || w[x].seated(t) || w[y].seated(t))
					continue;
				if (!(player_touch::distance3(w[x].at(t).v, w[y].at(t).v) < kTouch))
					continue;
				++r.touching;
				r.one_sided += on[x][y] != on[y][x] ? 1 : 0;
				r.on_both += on[x][y] && on[y][x] ? 1 : 0;
			}
	}
	return r;
}

constexpr double kNever = -1;
} // namespace

TEST(player_touch_first_one_walks_off_before_the_second_goes_live)
{
	// Server, B and C take one exit 1-15 s apart (P at 0). B goes live 3 s after his spawn and walks off to wait 6-14 m from P;
	// C's avatar reaches B at C's live, B's reaches C in C's load. C walks straight up to B. RED on the pair's spot taken from
	// where the first one stood when the second one's machine first placed him: 11 of 140 cases one-sided.
	int cases = 0, bad = 0, touching = 0;
	for (double d : {1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 12.0, 15.0})
		for (float stop : {6.f, 8.f, 9.f, 10.f, 11.f, 12.f, 14.f})
			for (float speed : {2.f, 4.f})
			{
				Walker b, c;
				b.spawn = 20;
				b.live = 23;
				b.path = {{0, 0, 0}, {23, 0, 0}, {23 + stop / speed, stop, 0}};
				c.spawn = 20 + d;
				c.live = 23 + d;
				const double go = c.live + 1;
				c.path = {{0, 0, 0}, {go, 0, 0}, {go + (stop - 0.6f) / 2.0, stop - 0.6f, 0}};
				const Run r = play({b, c}, {{kNever, c.live}, {c.spawn - 1, kNever}}, go + stop / 2.0 + 5, {0.f, 0.f, 0.f});
				++cases;
				touching += r.touching;
				bad += r.one_sided > 0 ? 1 : 0;
			}
	CHECK_EQ(cases, 140);
	CHECK(touching > 0);
	CHECK_EQ(bad, 0);
}

TEST(player_touch_two_who_join_3_s_apart_hold_the_pair_alike)
{
	// Coop, two friends join the host 3 s apart; both are put at the host + 1.5 m (the host stands 20 m away). L1 walks off to
	// wait 12 m away, L2 walks up to him. RED: L1's machine had the pair on, L2's off, 74 frames.
	Walker h, l1, l2;
	h.spawn = 0;
	h.live = 1;
	h.path = {{0, -20, 0}};
	l1.spawn = 100;
	l1.live = 103;
	l1.path = {{0, 0, 0}, {103, 0, 0}, {109, 12, 0}};
	l2.spawn = 103;
	l2.live = 106;
	l2.path = {{0, 0, 0}, {107, 0, 0}, {107 + 5.7, 11.4f, 0}};
	// the level's arrival point is elsewhere (60 m off): the host + 1.5 m is none
	const Run r = play({h, l1, l2}, {{kNever, 103.1, 106.1}, {99, kNever, 106.1}, {99, 103.1, kNever}}, 120, {60.f, 0.f, 0.f});
	CHECK(r.touching > 0);
	CHECK_EQ(r.one_sided, 0);
}

TEST(player_touch_one_who_sat_in_a_car_when_the_other_came_holds_the_pair_alike)
{
	// Y drives (seated since before X came); X arrives at (0, 0), walks 30 m off and waits; Y drives up, gets out 4 m from X and
	// walks up to him. RED: Y's machine took X's spot where X stood when Y got out (30 m off), 67 frames one-sided.
	Walker x, y;
	x.spawn = 10;
	x.live = 12;
	x.path = {{0, 0, 0}, {12, 0, 0}, {27, 30, 0}};
	y.spawn = 0;
	y.live = 1;
	y.path = {{0, 60, 40}, {50, 60, 40}, {60, 34, 0}, {61, 34, 0}, {63.5, 30.6f, 0}};
	y.seat0 = 2;
	y.seat1 = 60.05;
	const Run r = play({x, y}, {{kNever, 5}, {12, kNever}}, 70, {0.f, 0.f, 0.f}); // X came by the exit whose point is (0, 0)
	CHECK(r.touching > 0);
	CHECK_EQ(r.one_sided, 0);
}

TEST(player_touch_group_transition_latecomer_and_return_hold_the_pair_alike)
{
	// The cases the re-review found alike already: they stay so. Every walker's machine, every pair, every touching frame.
	const std::vector<float> P = {0.f, 0.f, 0.f};
	{
		// Coop group transition with the barrier: nobody moves before Enter (45 s); host loaded at 20, C1 at 30, C2 at 44. The
		// clients' avatars come at Enter; the host's is in every client's load. Ring spots.
		Walker h, c1, c2;
		h.spawn = 20, h.live = 45, h.path = {{0, 0, 0}, {47, 0, 0}, {52, 0, 0}, {60, 0, 0}};
		c1.spawn = 30, c1.live = 45, c1.path = {{0, 1.5f, 0}, {46, 1.5f, 0}, {50, 12, 0}, {55, 12, 10}, {62, 0.6f, 0.2f}};
		c2.spawn = 44, c2.live = 45, c2.path = {{0, 0, 1.5f}, {48, 0, 1.5f}, {53, -10, 12}, {58, -14, -2}, {64, -0.5f, 0.4f}};
		const double e = 45.1;
		const Run r = play({h, c1, c2}, {{kNever, e, e}, {19, kNever, e}, {19, e, kNever}}, 70, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// Coop: the laggard enters alone 60 s later; host and C1 walked off; he appears at his ring spot and walks to C1.
		Walker h, c1, c2;
		h.spawn = 20, h.live = 25, h.path = {{0, 0, 0}, {26, 0, 0}, {30, 7, 0}};
		c1.spawn = 22, c1.live = 25, c1.path = {{0, 1.5f, 0}, {26, 1.5f, 0}, {35, -10, 15}};
		c2.spawn = 84, c2.live = 86, c2.path = {{0, 0, 1.5f}, {88, 0, 1.5f}, {92, -6, 9}, {95, -9.4f, 14.6f}};
		const Run r = play({h, c1, c2}, {{kNever, 25.1, 86.1}, {19, kNever, 86.1}, {19, 21, kNever}}, 100, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// Coop latecomer: the host walked 20 m off the arrival point while the latecomer loaded (put at the host + 1.5 m when he
		// asked); he walks up to the host.
		Walker h, l;
		h.spawn = 0, h.live = 1, h.path = {{0, 0, 0}, {100, 0, 0}, {120, 20, 0}, {200, 20, 0}};
		l.spawn = 140, l.live = 143, l.path = {{0, 1.5f, 0}, {145, 1.5f, 0}, {150, 19.4f, 0}};
		const Run r = play({h, l}, {{kNever, 143.1}, {139, kNever}}, 160, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// Server: B comes back on P from the next map, walks 8 m off and back up to A, who waits at P.
		Walker a, b;
		a.spawn = 0, a.live = 1, a.path = {{0, 1, 0}};
		b.spawn = 90, b.live = 93, b.path = {{0, 0, 0}, {94, 0, 0}, {99, 8, 0}, {104, 1.6f, 0}};
		const Run r = play({a, b}, {{kNever, 93.1}, {89, kNever}}, 110, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// The executor's two leftovers of the round before: two arrive 5 s apart at points 30 m apart (two exits, both points on
		// every machine), and an avatar that reaches the newcomer 12 s after his spawn.
		Walker b, c;
		b.spawn = 20, b.live = 23, b.path = {{0, 0, 0}, {24, 0, 0}, {36, 24, 0}};
		c.spawn = 25, c.live = 28, c.path = {{0, 30, 0}, {40, 30, 0}, {42, 24.7f, 0}};
		const Run r1 = play({b, c}, {{kNever, 28}, {24, kNever}}, 50, {0.f, 0.f, 0.f, 30.f, 0.f, 0.f});
		CHECK(r1.touching > 0);
		CHECK_EQ(r1.one_sided, 0);
		Walker a, n;
		a.spawn = 0, a.live = 1, a.path = {{0, 20, 0}};
		n.spawn = 100, n.live = 103, n.path = {{0, 0, 0}, {104, 0, 0}, {113.7, 19.4f, 0}};
		const Run r2 = play({a, n}, {{kNever, 103}, {112, kNever}}, 120, P);
		CHECK(r2.touching > 0);
		CHECK_EQ(r2.one_sided, 0);
	}
}

TEST(player_touch_one_who_came_by_the_place_and_waits_6_to_8_m_off_holds_the_pair_alike)
{
	// Re-review 3 2026-11-24 (probe scratchpad/collide3-review/probe.cpp): "at an arrival place" had a band (in at 6 m, out past
	// 8 m), so a memory. One who came by P and stepped off to wait 6-8 m from it was at the place on his own machine (he walked
	// out from P) and not on the machine of one whose pair with him started later (that avatar's flag starts false and came in
	// only within 6 m): the pair off on the first machine, on on the second, while the bodies touch. One walks through the
	// other, and the other's actor is pushed out of an avatar that never yields. Who starts the pair later: one who comes by the
	// same exit (Server), the latecomer at the host + 1.5 m and the laggard of a group transition (Coop), one who comes back
	// from the next map. RED with the band: one-sided in every scene with the wait 6.5-7.9 m and in the tunnel.
	const std::vector<float> P = {0.f, 0.f, 0.f}; // the arrival point of the exit (all.spawn m_tNextPosition)
	{
		// Server: A came by P and stepped off to wait w m from it; B comes by P 60 s later, walks out north past 8 m, east, and
		// back south up to A from outside (0.6 m from him, farther from P than A). B's machine gets A's avatar in its load, A's
		// machine gets B's at B's live.
		int bad = 0;
		for (float wd : {5.5f, 6.f, 6.5f, 7.f, 7.5f, 7.9f})
		{
			Walker a, b;
			a.spawn = 0, a.live = 3, a.path = {{0, 0, 0}, {4, 0, 0}, {4 + wd / 2.0, wd, 0}};
			b.spawn = 60, b.live = 63, b.path = {{0, 0, 0}, {64, 0, 0}, {70, 0, 12}, {74, wd + 0.6f, 12}, {80, wd + 0.6f, 0}};
			const Run r = play({a, b}, {{kNever, 63.1}, {59, kNever}}, 90, P);
			CHECK(r.touching > 0);
			bad += r.one_sided > 0 ? 1 : 0;
			CHECK_EQ(r.on_both, 0); // A is at the place: they pass through each other on both machines
		}
		CHECK_EQ(bad, 0);
		// A waits 8.5 m off P (outside the place): they bump on both machines
		Walker a, b;
		a.spawn = 0, a.live = 3, a.path = {{0, 0, 0}, {4, 0, 0}, {8.25, 8.5f, 0}};
		b.spawn = 60, b.live = 63, b.path = {{0, 0, 0}, {64, 0, 0}, {70, 0, 12}, {74, 9.1f, 12}, {80, 9.1f, 0}};
		const Run r = play({a, b}, {{kNever, 63.1}, {59, kNever}}, 90, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
		CHECK_EQ(r.on_both, r.touching);
	}
	{
		// Server, control: A came to 7 m from P from 40 m away (never on P), the same walk of B.
		Walker a, b;
		a.spawn = 0, a.live = 3, a.path = {{0, 40, 0}, {4, 40, 0}, {20, 7, 0}};
		b.spawn = 60, b.live = 63, b.path = {{0, 0, 0}, {64, 0, 0}, {70, 0, 12}, {74, 7.6f, 12}, {80, 7.6f, 0}};
		const Run r = play({a, b}, {{kNever, 63.1}, {59, kNever}}, 90, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// Coop latecomer: the group came by P, the host stepped off to wait 7 m from P; L joins, is put at the host + 1.5 m (8.5 m
		// from P), walks 6 m off and comes back up to the host from outside.
		Walker h, l;
		h.spawn = 0, h.live = 1, h.path = {{0, 0, 0}, {2, 0, 0}, {5.5, 7, 0}};
		l.spawn = 100, l.live = 103, l.path = {{0, 8.5f, 0}, {104, 8.5f, 0}, {107, 12, 5}, {110, 7.6f, 0.2f}};
		const Run r = play({h, l}, {{kNever, 103.1}, {99, kNever}}, 120, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// Coop group transition and its laggard: host and C1 come by P together (ring spots), C1 waits 7 m off P; C2 enters alone
		// 60 s later on his ring spot, walks north out of the place, east, and back south up to C1.
		Walker h, c1, c2;
		h.spawn = 20, h.live = 25, h.path = {{0, 0, 0}, {26, 0, 0}, {35, -20, 0}};
		c1.spawn = 22, c1.live = 25, c1.path = {{0, 1.5f, 0}, {26, 1.5f, 0}, {29, 7, 0}};
		c2.spawn = 84, c2.live = 86, c2.path = {{0, 0, 1.5f}, {87, 0, 1.5f}, {92, 0, 12}, {95, 7.6f, 12}, {100, 7.6f, 0.2f}};
		const Run r = play({h, c1, c2}, {{kNever, 25.1, 86.1}, {19, kNever, 86.1}, {19, 21, kNever}}, 110, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// Server: B comes back by P from the next map while A, who came by P, waits 7.5 m off it; B walks round and up to A.
		Walker a, b;
		a.spawn = 0, a.live = 2, a.path = {{0, 0, 0}, {3, 0, 0}, {7, 0, 7.5f}};
		b.spawn = 200, b.live = 203, b.path = {{0, 0, 0}, {204, 0, 0}, {208, -9, 0}, {212, -9, 7.9f}, {216, -0.6f, 7.9f}};
		const Run r = play({a, b}, {{kNever, 203.1}, {199, kNever}}, 225, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
	{
		// Server, the owner's tunnel (Cordon -> Garbage, 1.4 m wide, P its arrival point): A comes by P, walks 7 m on and waits; B
		// comes 5 s later, walks past A to 11 m and waits; A walks on out of the tunnel, through where B stands.
		Walker a, b;
		a.spawn = 0, a.live = 3, a.path = {{0, 0, 0}, {3, 0, 0}, {6.5, 7, 0}, {25, 7, 0}, {28.5, 14, 0}};
		b.spawn = 8, b.live = 11, b.path = {{0, 0, 0.3f}, {12, 0, 0.3f}, {17.5, 11, 0.3f}};
		const Run r = play({a, b}, {{kNever, 11.1}, {7, kNever}}, 35, P);
		CHECK(r.touching > 0);
		CHECK_EQ(r.one_sided, 0);
	}
}

TEST(player_touch_one_at_an_exit_when_the_other_came_holds_the_pair_alike)
{
	// Re-review 3 2026-11-24, the same memory at the level exits (HEAD had it too: in at 2 m, out past 4 m). Server: A stood in
	// the queue at an exit (1 m from its shape) and stepped back to 3 m; B comes by an arrival point 40 m off 60 s later and walks
	// up to A. A's own machine had him at the exit (he walked out from 1 m), B's machine not (A's avatar 3 m off the exit, its
	// flag new): A passed through B, B's actor was pushed out of A's avatar. RED with the band: one-sided while they touch.
	const std::vector<float> E = {0.f, 0.f, 0.f}; // the exit (a shape of no size)
	const std::vector<float> P = {40.f, 0.f, 0.f}; // the arrival point B comes by
	Walker a, b;
	a.spawn = 0, a.live = 3, a.path = {{0, 1, 0}, {4, 1, 0}, {5, 3, 0}};
	b.spawn = 60, b.live = 63, b.path = {{0, 40, 0}, {64, 40, 0}, {64 + 36.4 / 2.0, 3.6f, 0}};
	const Run r = play({a, b}, {{kNever, 63.1}, {59, kNever}}, 90, P, E);
	CHECK(r.touching > 0);
	CHECK_EQ(r.one_sided, 0);
	CHECK_EQ(r.on_both, 0); // A is at the exit: they pass through each other on both machines
}

TEST(player_touch_only_bodies_of_two_players_pass_through)
{
	using player_touch::bodies_meet;
	// (a is a player, a passes players, b is a player, b passes players), as the engine's collide class bits read them
	CHECK(!bodies_meet(true, false, true, true)); // my actor and an avatar whose pair is off
	CHECK(!bodies_meet(true, true, true, false));
	CHECK(bodies_meet(true, false, true, false)); // my actor and an avatar whose pair is on
	CHECK(bodies_meet(false, false, true, true)); // an NPC and an avatar whose pair is off: untouched
	CHECK(bodies_meet(true, true, false, false)); // ... and the other way
	CHECK(bodies_meet(false, false, false, false)); // single player: no bits anywhere, stock
}

// The thresholds leave room for the group ring, the capsules and the delay of an avatar.
// The group ring: its four axis spots are within its diameter of each other. The diagonal ones are farther (up to 4.24 m), and
// an avatar's spawn spot may be one of them while its player stands on mine: apart_known, the group arrival tests above.
static_assert(player_touch::kApart >= 2.f * arrival::kRing, "kApart covers the axis spots of the host's ring");
// Two capsules touch at about 0.75 m (actor 0.35 m, avatar 0.4 m; the actor's restrictor 0.25 m + 0.4 m is less); the avatar
// is drawn up to ~200 ms late (100 ms interpolation + the network), 1.6 m at a sprint of 8 m/s.
static_assert(player_touch::kApart - 0.75f >= 1.6f, "kApart leaves room for the capsules and the avatar's delay");
// The queue in front of a narrow exit is two or three capsules deep (0.75 m each).
static_assert(player_touch::kExitFar >= 3.f * 0.75f, "the exit's zone holds its queue");
// TZ P75: one who has left his spawn place (past kSpawnFar of his spot) is kApart or more from every spot of the host's ring
// around it (they are within 2 * 1.5 * sqrt(2) = 4.24 m of each other), so a pair that comes on then is not one in the other.
static_assert(player_touch::kSpawnFar - 2.f * 1.4143f * arrival::kRing >= player_touch::kApart, "kSpawnFar clears the ring");
