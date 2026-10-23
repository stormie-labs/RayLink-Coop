// Anomaly Coop unit tests: the "viewers" of the host's scheduler (xrCoop/coop_viewers.h).
// Owner, live test of build 10 (2026-10-24): "far from the host, A-Life lives wrongly: when a client walks up to somebody,
// they walk slowly". Cause (by code): the host updates an object by its distance to the HOST'S CAMERA
// (CObject::shedule_Scale = distance / 200; an object that is neither within 30 m of the camera nor visible within 60 m is
// also updated by UpdateCL only once per scheduler step, and a movement step is capped at 100 ms). An NPC 300 m from the
// host but next to a client thinks every 625 ms and walks at ~1/6 of its speed. The fix: the host's camera plus the
// character of every player in the world are "viewers"; an object is updated by its distance to the NEAREST one.
// The rule is a pure function here; xrEngine (sheduler_viewers.h) and the NPC classes of xrGame call it.
#include "test_util.h"

#include "coop_viewers.h"

#include <algorithm>
#include <cmath>
#include <limits>

using namespace coop;
using viewers::Point;

namespace
{
bool near_f(float a, float b, float eps = 1e-4f) { return a - b <= eps && b - a <= eps; }

Point at_x(float x) { return Point{x, 0.f, 0.f}; }

// The scheduler's own arithmetic (xrEngine/xrSheduler.cpp, CSheduler::ProcessStep), copied here to show what a scale means
// for an NPC (CCustomMonster: t_min 100, t_max 250). Documentation of the cause, not a test of the engine.
unsigned shedule_interval_ms(unsigned t_min, unsigned t_max, float scale)
{
	const unsigned lo = std::max(30u, t_min);
	const unsigned hi = (1000u + t_max) / 2u;
	long upd = long(lo) + long(std::floor(float(hi - lo) * scale));
	upd = std::max<long>(std::max<long>(lo, 20), std::min<long>(upd, hi));
	return unsigned(upd);
}

// CCustomMonster::UpdateCL moves an NPC by min(time since its last UpdateCL, 100 ms) of walking each time it runs.
float walking_share(unsigned update_cl_period_ms)
{
	return std::min(1.f, float(viewers::kMovementStepCapMs) / float(update_cl_period_ms));
}
} // namespace

TEST(viewers_without_viewers_the_scale_is_the_stock_camera_scale)
{
	// Single player and a session without other players: the answer is bit for bit the stock one (distance / 200).
	for (float cam : {0.f, 1.f, 29.9f, 60.f, 137.5f, 200.f, 300.f, 1234.5f})
	{
		const float got = viewers::shedule_scale(viewers::nearest_distance(cam, nullptr, 0, at_x(0.f), 100.f));
		CHECK(got == cam / 200.f);
	}
	const Point none[1] = {at_x(5.f)};
	CHECK(viewers::nearest_distance(80.f, none, 0, at_x(0.f), 100.f) == 80.f); // count 0: the array is not read
}

TEST(viewers_the_nearest_viewer_sets_the_distance)
{
	const Point v[3] = {at_x(500.f), at_x(40.f), at_x(120.f)};
	const Point npc = at_x(20.f);
	// the camera is 300 m away, the viewers 480, 20 and 100 m: the second one wins
	CHECK(near_f(viewers::nearest_distance(300.f, v, 3, npc, 1000.f), 20.f));
	// the camera closer than every viewer stays the answer (the host looks at it)
	CHECK(near_f(viewers::nearest_distance(5.f, v, 3, npc, 1000.f), 5.f));
	// the order of the list does not matter
	const Point w[3] = {at_x(120.f), at_x(500.f), at_x(40.f)};
	CHECK(near_f(viewers::nearest_distance(300.f, w, 3, npc, 1000.f), 20.f));
}

TEST(viewers_range_limits_which_viewers_count)
{
	const Point v[1] = {at_x(100.f)};
	// the NPC is 90 m from the viewer, the host's camera 300 m: with range 100 the viewer counts...
	CHECK(near_f(viewers::nearest_distance(300.f, v, 1, at_x(10.f), 100.f), 90.f));
	// ...and exactly at the range too, but not one metre beyond it: then only the camera counts
	CHECK(near_f(viewers::nearest_distance(300.f, v, 1, at_x(0.f), 100.f), 100.f));
	CHECK(near_f(viewers::nearest_distance(300.f, v, 1, at_x(-1.f), 100.f), 300.f));
	// range 0 (or less, or NaN) switches the viewers off: the camera alone, as in stock
	CHECK(near_f(viewers::nearest_distance(300.f, v, 1, at_x(100.f), 0.f), 300.f));
	CHECK(near_f(viewers::nearest_distance(300.f, v, 1, at_x(100.f), -5.f), 300.f));
	CHECK(near_f(viewers::nearest_distance(300.f, v, 1, at_x(100.f), std::numeric_limits<float>::quiet_NaN()), 300.f));
}

TEST(viewers_distance_is_three_dimensional_like_the_camera_distance)
{
	const Point up{0.f, 30.f, 0.f}; // a viewer on a roof / a hill, 30 m above the NPC
	const Point npc{40.f, 0.f, 0.f};
	CHECK(near_f(viewers::nearest_distance(900.f, &up, 1, npc, 100.f), 50.f)); // 3-4-5 triangle
}

TEST(viewers_the_owners_case_an_npc_far_from_the_host_next_to_a_client)
{
	// The NPC stands 300 m from the host's camera and 20 m from a client's character.
	const Point client = at_x(1000.f);
	const Point npc = at_x(1020.f);
	const float stock = viewers::shedule_scale(300.f);
	const float with_viewer = viewers::shedule_scale(viewers::nearest_distance(300.f, &client, 1, npc, 100.f));
	CHECK(near_f(stock, 1.5f));
	CHECK(near_f(with_viewer, 0.1f));

	// What that means for a CCustomMonster (stalker, mutant): t_min 100 ms, t_max 250 ms.
	CHECK_EQ(shedule_interval_ms(100, 250, stock), 625u); // thinks every 625 ms (the cap (1000 + 250) / 2)
	CHECK_EQ(shedule_interval_ms(100, 250, with_viewer), 152u); // 100 + 525 * 0.1
	// Outside the camera's 30 m (and 60 m visible) circle UpdateCL runs once per scheduler step, and a walking step is
	// capped at 100 ms: the NPC covers 100 ms of walking per 625 ms.
	CHECK(near_f(walking_share(625), 0.16f, 1e-3f));
	// Next to the client it is updated every frame (below), so it walks at full speed.
	CHECK(viewers::within(&client, 1, npc, viewers::frame_radius(100.f, viewers::kDefaultFrameRadius)));
}

TEST(viewers_within_marks_the_npcs_that_are_updated_every_frame)
{
	const Point v[2] = {at_x(0.f), at_x(300.f)};
	CHECK(viewers::within(v, 2, at_x(59.f), 60.f));
	CHECK(viewers::within(v, 2, at_x(60.f), 60.f)); // the border counts, like nearest_distance
	CHECK(!viewers::within(v, 2, at_x(61.f), 60.f));
	CHECK(viewers::within(v, 2, at_x(330.f), 60.f)); // near the second viewer
	CHECK(!viewers::within(v, 2, at_x(150.f), 60.f)); // between the two
	CHECK(!viewers::within(nullptr, 0, at_x(0.f), 60.f)); // nobody around: stock
	CHECK(!viewers::within(v, 0, at_x(0.f), 60.f));
	CHECK(!viewers::within(v, 2, at_x(0.f), 0.f)); // radius 0 = off
	CHECK(!viewers::within(v, 2, at_x(0.f), -1.f));
	CHECK(!viewers::within(v, 2, at_x(0.f), std::numeric_limits<float>::quiet_NaN()));
}

TEST(viewers_frame_radius_never_exceeds_the_range)
{
	CHECK(near_f(viewers::frame_radius(100.f, 60.f), 60.f)); // defaults: 60 m, what the camera gives to what it sees
	CHECK(near_f(viewers::frame_radius(40.f, 60.f), 40.f)); // a short range shortens it
	CHECK(near_f(viewers::frame_radius(0.f, 60.f), 0.f)); // range 0 switches everything off
	CHECK(near_f(viewers::frame_radius(100.f, 0.f), 0.f)); // radius 0: only the scale is changed
	CHECK(near_f(viewers::frame_radius(-3.f, 60.f), 0.f));
	CHECK(near_f(viewers::frame_radius(100.f, -3.f), 0.f));
	CHECK(near_f(viewers::frame_radius(std::numeric_limits<float>::quiet_NaN(), 60.f), 0.f));
}

TEST(viewers_a_list_that_is_not_refreshed_goes_stale)
{
	// The host rewrites the list every frame; if the writer stops (session over, level torn down) the engine must fall
	// back to the camera alone instead of holding the last positions.
	CHECK(viewers::fresh(1000u, 1000u));
	CHECK(viewers::fresh(1000u + viewers::kFreshMs, 1000u));
	CHECK(!viewers::fresh(1000u + viewers::kFreshMs + 1u, 1000u));
	// the millisecond clock wraps after 49 days: the age is taken as an unsigned difference
	CHECK(viewers::fresh(5u, 0xFFFFFFF0u));
	CHECK(!viewers::fresh(viewers::kFreshMs + 100u, 0xFFFFFFF0u));
	// a stamp from the "future" (the clock stepped back) is not fresh
	CHECK(!viewers::fresh(100u, 5000u));
}

TEST(viewers_defaults_are_inside_their_limits)
{
	CHECK(viewers::kDefaultRange > 0.f && viewers::kDefaultRange <= viewers::kMaxRange);
	CHECK(viewers::kDefaultFrameRadius > 0.f && viewers::kDefaultFrameRadius <= viewers::kMaxFrameRadius);
	CHECK(viewers::kMaxViewers >= 7u); // a host plus seven clients: the host's camera is not in the list
	CHECK(viewers::kScaleDistance == 200.f); // CObject::shedule_Scale: distance / 200
}
