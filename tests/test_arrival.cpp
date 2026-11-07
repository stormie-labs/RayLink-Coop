// Anomaly Coop unit tests: where a client's character stands and how healthy it is when it arrives on a new level
// (coop_arrival.h).
// Live report 2026-11-07 (owner, a client of a G.A.M.M.A. session): "he walked through a level changer with the group, lost
// health and his leg broke". Two co-op causes, both absent in single player:
//  - the host puts each moving client's character 1.5 m beside the level changer's point at the point's height
//    (coop_join.cpp host_place_movers): the host still stands on the old level and has no ground of the new one. On a slope
//    or at a wall the client's actor spawns in the air (a fall) or under the ground (it drops through the level);
//  - the client's actor spawned with the health of its NPC proxy on the host (an unharmable stalker: 1.0) and only after
//    going live was set to the player's own health (coop_equip.cpp client_restore_vitals): a drop of up to 0.95 in one
//    frame, which GAMMA's Body Health System books as a hit on a random body part (a leg breaks at 5 points).
#include "test_util.h"

#include "coop_arrival.h"

#include <cmath>
#include <map>
#include <string>
#include <utility>

using namespace coop;
using namespace coop::arrival;

namespace
{
// A level graph for the rule: ground by 1.5 m cell, missing cells are off the AI map.
struct FakeGround
{
	std::map<std::pair<int, int>, float> cells;
	void set(float x, float z, float y) { cells[key(x, z)] = y; }
	static std::pair<int, int> key(float x, float z)
	{
		return {int(std::floor(x / 0.7f)), int(std::floor(z / 0.7f))};
	}
	Ground fn() const
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

bool near(float a, float b) { return std::fabs(a - b) < 1e-3f; }
} // namespace

TEST(arrival_flat_ground_puts_the_character_on_it)
{
	FakeGround g;
	g.set(101.5f, 50.f, 10.f);
	g.set(100.f, 50.f, 10.f);
	const Point own{101.5f, 10.f, 50.f};
	const Point anchor{100.f, 10.f, 50.f};
	const Placed p = place(own, anchor, g.fn());
	CHECK(p.how == How::Snapped);
	CHECK(near(p.at.x, 101.5f) && near(p.at.z, 50.f));
	CHECK(near(p.at.y, 10.f + kLift));
	CHECK(near(p.ground_y, 10.f));
}

TEST(arrival_downhill_offset_no_longer_spawns_in_the_air)
{
	// The level changer's point is on a slope; 1.5 m to the side the ground is 2.4 m lower: before, a 2.4 m fall.
	FakeGround g;
	g.set(100.f, 50.f, 10.f);
	g.set(101.5f, 50.f, 7.6f);
	const Placed p = place(Point{101.5f, 10.f, 50.f}, Point{100.f, 10.f, 50.f}, g.fn());
	CHECK(p.how == How::Snapped);
	CHECK(near(p.at.y, 7.6f + kLift));
	CHECK(near(p.drop, 2.4f)); // what the old placement would have dropped him
}

TEST(arrival_uphill_offset_no_longer_spawns_under_the_ground)
{
	// 1.2 m higher ground beside the point: before, the actor's feet were 1.2 m inside the hill and he fell through it.
	FakeGround g;
	g.set(100.f, 50.f, 10.f);
	g.set(101.5f, 50.f, 11.2f);
	const Placed p = place(Point{101.5f, 10.f, 50.f}, Point{100.f, 10.f, 50.f}, g.fn());
	CHECK(p.how == How::Snapped);
	CHECK(near(p.at.y, 11.2f + kLift));
	CHECK(near(p.drop, -1.2f));
}

TEST(arrival_offset_off_the_map_moves_next_to_the_point)
{
	// Beside the point is a wall or a cliff (no AI vertex there, or the ground far below): another place around the point.
	FakeGround g;
	g.set(100.f, 50.f, 10.f);
	g.set(100.f, 51.5f, 10.1f); // the second place of the ring (0, +1.5)
	g.set(101.5f, 50.f, 2.f); // 8 m below: the foot of a cliff, not the place
	const Placed p = place(Point{101.5f, 10.f, 50.f}, Point{100.f, 10.f, 50.f}, g.fn());
	CHECK(p.how == How::Moved);
	CHECK(near(p.at.x, 100.f) && near(p.at.z, 51.5f));
	CHECK(near(p.at.y, 10.1f + kLift));
}

TEST(arrival_falls_back_to_the_point_itself)
{
	FakeGround g;
	g.set(100.f, 50.f, 10.f); // only the level changer's own point has ground
	const Placed p = place(Point{101.5f, 10.f, 50.f}, Point{100.f, 10.f, 50.f}, g.fn());
	CHECK(p.how == How::Moved);
	CHECK(near(p.at.x, 100.f) && near(p.at.z, 50.f));
	CHECK(near(p.at.y, 10.f + kLift));
}

TEST(arrival_without_any_ground_keeps_the_point)
{
	FakeGround g;
	const Placed p = place(Point{101.5f, 10.f, 50.f}, Point{100.f, 10.f, 50.f}, g.fn());
	CHECK(p.how == How::NoGround);
	CHECK(near(p.at.x, 101.5f) && near(p.at.y, 10.f) && near(p.at.z, 50.f));
}

TEST(arrival_basement_under_the_road_is_not_the_place)
{
	// The only vertex in the column is 5 m lower (a cellar under the road): the ring around the point is tried instead.
	FakeGround g;
	g.set(100.f, 50.f, 10.f);
	g.set(101.5f, 50.f, 5.f);
	const Placed p = place(Point{101.5f, 10.f, 50.f}, Point{100.f, 10.f, 50.f}, g.fn());
	CHECK(p.how == How::Moved);
	CHECK(near(p.at.y, 10.f + kLift));
}

TEST(arrival_vitals_line_gives_the_players_own_health)
{
	float v[kVitalsCount] = {};
	CHECK(parse_vitals("[coop]\nkey = abc\nvitals = 0.420,0.800,0.100,1.000,0.900,0.000\n", v));
	CHECK(near(v[0], 0.42f) && near(v[1], 0.8f) && near(v[2], 0.1f) && near(v[5], 0.f));
	CHECK(!parse_vitals("[coop]\nkey = abc\n", v));
	CHECK(!parse_vitals(nullptr, v));
	CHECK(!parse_vitals("vitals = 0.5,0.5", v));
}

TEST(arrival_actor_spawns_with_his_own_health_not_the_proxys)
{
	// RED before the fix: the role swap gave the actor the proxy's 1.0, the restore after going live took it to 0.3 in a frame.
	CHECK(near(spawn_health("[coop]\nvitals = 0.300,1.000,0.000,1.000,1.000,0.000\n", 1.f), 0.3f));
	CHECK(near(spawn_health("[coop]\nnick = a\n", 0.77f), 0.77f)); // a new character: the proxy's, as before
	CHECK(near(spawn_health("[coop]\nvitals = 0.010,1,0,1,1,0\n", 1.f), kMinSpawnHealth)); // same floor as the restore
	CHECK(near(spawn_health("[coop]\nvitals = 7,1,0,1,1,0\n", 1.f), 1.f));
	CHECK(near(spawn_health("[coop]\nvitals = nan,1,0,1,1,0\n", 0.6f), 0.6f));
}

TEST(arrival_marker_is_set_read_and_cleared)
{
	std::string text = "[coop]\nkey = k\nvitals = 0.5,1,0,1,1,0\n";
	CHECK(!placed_by_host(text));
	mark_placed(text);
	CHECK(placed_by_host(text));
	CHECK(text.find("vitals = 0.5") != std::string::npos);
	clear_placed(text);
	CHECK(!placed_by_host(text));
	CHECK(text.find("key = k") != std::string::npos);
}

TEST(arrival_journal_tells_where_the_health_went)
{
	Journal j;
	Vitals4 before;
	before.health = 0.6f;
	before.bleeding = 0.f;
	before.radiation = 0.1f;
	before.satiety = 0.7f;
	j.begin("group exit", "l02_garbage", before, 1000);
	CHECK(j.active());
	j.apply("swap", 1.f, 0.6f); // the spawn health
	j.frame(0.6f, 2000);
	j.place("snapped [1.0 2.0 3.0] ground 1.8");
	j.hit("fall", 0.3f, "self", 0, false);
	j.frame(0.45f, 2100); // the hit took 0.15
	j.frame(0.44f, 2200); // the condition's own update (bleeding): -0.01
	j.hit("wound", 0.1f, "dog_strong", 12, true); // behind the held screen: dropped
	j.frame(0.44f, 2300);
	j.arrived(2300);
	CHECK(!j.due(2300 + kWindowMs - 1));
	CHECK(j.due(2300 + kWindowMs));
	Vitals4 after;
	after.health = 0.44f;
	after.bleeding = 0.02f;
	after.radiation = 0.1f;
	after.satiety = 0.69f;
	const std::string line = j.finish(after);
	CHECK(!j.active());
	CHECK(line.find("group exit") != std::string::npos);
	CHECK(line.find("l02_garbage") != std::string::npos);
	CHECK(line.find("before hp 0.600") != std::string::npos);
	CHECK(line.find("after hp 0.440") != std::string::npos);
	CHECK(line.find("hits -0.150") != std::string::npos);
	CHECK(line.find("own -0.010") != std::string::npos);
	CHECK(line.find("coop 0.000") != std::string::npos); // the swap happened before the first frame: no jump
	CHECK(line.find("fall 0.300 by self bone 0") != std::string::npos);
	CHECK(line.find("1 dropped") != std::string::npos);
	CHECK(line.find("snapped") != std::string::npos);
}

TEST(arrival_journal_books_a_coop_apply_after_spawn)
{
	// The old order: spawned at 1.0, set to 0.3 after going live. The jump is booked to the co-op apply, not to hits.
	Journal j;
	Vitals4 before;
	before.health = 0.3f;
	j.begin("group exit", "l03_agroprom", before, 0);
	j.frame(1.f, 10);
	j.apply("restore", 1.f, 0.3f);
	j.frame(0.3f, 20);
	j.arrived(20);
	Vitals4 after;
	after.health = 0.3f;
	const std::string line = j.finish(after);
	CHECK(line.find("coop -0.700") != std::string::npos);
	CHECK(line.find("hits 0.000") != std::string::npos);
	CHECK(line.find("restore 1.000->0.300") != std::string::npos);
}

TEST(arrival_journal_keeps_its_notes_bounded)
{
	Journal j;
	j.begin("join", "x", Vitals4(), 0);
	for (int i = 0; i < 100; ++i)
		j.hit("wound", 0.01f, "rat", 1, false);
	j.arrived(0);
	const std::string line = j.finish(Vitals4());
	CHECK(line.size() < 1200);
	CHECK(line.find("+") != std::string::npos); // "... +N more"
}
