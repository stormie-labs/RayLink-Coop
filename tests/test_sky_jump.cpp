// Anomaly Coop unit tests: the sky after a jump of the game clock (xrCoop/coop_sky_jump.h).
// Live report 41.4 (2026-11-08): after a shared sleep the clock said 10:30 and the sky was night; it turned to day by itself at
// about 11:00. The stock model below is CEnvironment (xrEngine/Environment.cpp): TimeWeight, the step of SelectEnvs(gt) with
// sections already chosen, and its "first or forced start" (the forced level.set_weather of level_weathers).
#include "test_util.h"

#include "coop_sky_jump.h"

#include <cmath>
#include <vector>

using namespace coop;

namespace
{
constexpr float kHour = 3600.f;
constexpr long long kHourMs = 3600LL * 1000;

struct Section
{
	int hour; // the "HH:00:00" of the section
	float exec_time;
};

// An Anomaly weather cycle: 24 sections, one per hour, sorted by exec time (as CEnvironment loads them).
std::vector<Section> hourly_cycle()
{
	std::vector<Section> c;
	for (int h = 0; h < 24; ++h)
		c.push_back({h, float(h) * kHour});
	return c;
}

float exec_of(const Section& s) { return s.exec_time; }

float at(int h, int m) { return float(h) * kHour + float(m) * 60.f; }

// CEnvironment::TimeDiff / TimeWeight (Environment.cpp:254-277).
float stock_diff(float prev, float cur) { return prev > cur ? (sky::kDaySec - prev) + cur : cur - prev; }

float stock_weight(float val, float t0, float t1)
{
	float w = 0.f;
	const float length = stock_diff(t0, t1);
	if (std::fabs(length) > 1e-4f)
	{
		if (t0 > t1)
		{
			if (val >= t0 || val <= t1)
				w = stock_diff(t0, val) / length;
		}
		else if (val >= t0 && val <= t1)
			w = stock_diff(t0, val) / length;
		w = w < 0.f ? 0.f : (w > 1.f ? 1.f : w);
	}
	return w;
}

// The sky of one machine: the two env sections it blends (Current[0], Current[1]) and its time of day (fGameTime).
struct Sky
{
	const std::vector<Section>* cycle = nullptr;
	size_t cur[2] = {0, 0};
	float gt = 0.f;

	const Section& s(int i) const { return (*cycle)[cur[i]]; }

	// SelectEnvs(gt) "first or forced start": the forced level.set_weather (Invalidate, then this).
	void forced_select()
	{
		const sky::Pair p = sky::pick_pair(*cycle, exec_of, sky::day_time(gt));
		REQUIRE(p.ok);
		cur[0] = p.i0;
		cur[1] = p.i1;
	}

	// SelectEnvs(gt) with sections chosen (Environment.cpp:477-498), what CEnvironment::lerp does every frame: one step on, only
	// when the time of day passed Current[1].
	void stock_frame()
	{
		const float t0 = s(0).exec_time, t1 = s(1).exec_time;
		const bool step = t0 > t1 ? (gt > t1 && gt < t0) : (gt > t1);
		if (!step)
			return;
		cur[0] = cur[1];
		// SelectEnv: the first section at or after gt, the first one past the end
		size_t i = 0;
		while (i < cycle->size() && (*cycle)[i].exec_time < gt)
			++i;
		cur[1] = i == cycle->size() ? 0 : i;
	}

	// The level.change_game_time / coop jump: CEnvironment::ChangeGameTime(delta % day).
	void jump(long long delta_ms) { gt = sky::day_time(gt + float(delta_ms % (24 * kHourMs)) / 1000.f); }

	// The section the sky shows most of: Current[1] past the middle of the blend, else Current[0].
	int shown_hour() const { return stock_weight(gt, s(0).exec_time, s(1).exec_time) >= 0.5f ? s(1).hour : s(0).hour; }
	float weight() const { return stock_weight(gt, s(0).exec_time, s(1).exec_time); }
};

// The co-op fix as coop_worldstate does it: the jump is noted where it happens (any thread), the next frame of the main thread
// takes it and chooses both sections again when the rule says so.
void coop_frame(Sky& sky, sky::JumpNote& note, bool frozen = false)
{
	long long jump = 0;
	if (note.take(jump) && sky::reselect_after_jump(jump, frozen))
		sky.forced_select();
	sky.gt = sky::day_time(sky.gt); // CLevel::OnFrame: CEnvironment::SetGameTime from the ALife clock, within one day
	sky.stock_frame();
}

bool is_night(int hour) { return hour >= 21 || hour < 5; }
} // namespace

TEST(sky_pick_pair_is_select_envs_first_start)
{
	const std::vector<Section> c = hourly_cycle();
	sky::Pair p = sky::pick_pair(c, exec_of, at(10, 30));
	REQUIRE(p.ok);
	CHECK_EQ(c[p.i0].hour, 10);
	CHECK_EQ(c[p.i1].hour, 11);
	p = sky::pick_pair(c, exec_of, at(10, 0)); // lower_bound: a section exactly at gt is the next one, weight 1
	REQUIRE(p.ok);
	CHECK_EQ(c[p.i0].hour, 9);
	CHECK_EQ(c[p.i1].hour, 10);
	p = sky::pick_pair(c, exec_of, at(23, 30)); // past the last section: the last and the first
	REQUIRE(p.ok);
	CHECK_EQ(c[p.i0].hour, 23);
	CHECK_EQ(c[p.i1].hour, 0);
	p = sky::pick_pair(c, exec_of, 0.f); // at the first section: the last one before it
	REQUIRE(p.ok);
	CHECK_EQ(c[p.i0].hour, 23);
	CHECK_EQ(c[p.i1].hour, 0);
	p = sky::pick_pair(c, exec_of, at(0, 30));
	REQUIRE(p.ok);
	CHECK_EQ(c[p.i0].hour, 0);
	CHECK_EQ(c[p.i1].hour, 1);
}

TEST(sky_pick_pair_of_odd_cycles)
{
	const std::vector<Section> none;
	CHECK(!sky::pick_pair(none, exec_of, at(10, 0)).ok);
	const std::vector<Section> one{{12, at(12, 0)}};
	const sky::Pair p = sky::pick_pair(one, exec_of, at(3, 0));
	REQUIRE(p.ok);
	CHECK_EQ(p.i0, size_t(0));
	CHECK_EQ(p.i1, size_t(0));
	// Sections whose times a script moved (level.set_weather_weight = set_lerp): the times decide, not the names.
	std::vector<Section> moved = hourly_cycle();
	moved[10].exec_time = at(10, 20);
	moved[11].exec_time = at(11, 20);
	const sky::Pair q = sky::pick_pair(moved, exec_of, at(10, 10));
	REQUIRE(q.ok);
	CHECK_EQ(moved[q.i0].hour, 9);
	CHECK_EQ(moved[q.i1].hour, 10);
}

TEST(sky_day_time_wraps_into_one_day)
{
	CHECK(std::fabs(sky::day_time(at(10, 30)) - at(10, 30)) < 1e-2f);
	CHECK(std::fabs(sky::day_time(sky::kDaySec + at(10, 30)) - at(10, 30)) < 1e-2f);
	CHECK(std::fabs(sky::day_time(3.f * sky::kDaySec + at(1, 0)) - at(1, 0)) < 1e-1f);
	CHECK(std::fabs(sky::day_time(-kHour) - at(23, 0)) < 1e-2f);
	CHECK(sky::day_time(sky::kDaySec) < 1e-2f);
	const float t = sky::day_time(-1e-3f);
	CHECK(t >= 0.f && t < sky::kDaySec);
}

TEST(sky_reselect_rule_takes_a_jump_not_a_correction)
{
	CHECK(sky::reselect_after_jump(14 * kHourMs, false)); // the shared sleep
	CHECK(sky::reselect_after_jump(sky::kReselectJumpMs, false));
	CHECK(!sky::reselect_after_jump(sky::kReselectJumpMs - 1, false)); // a step of the stock crosses one section at most
	CHECK(!sky::reselect_after_jump(2000, false)); // a client following the host's clock
	CHECK(!sky::reselect_after_jump(-2000, false));
	CHECK(sky::reselect_after_jump(-2 * kHourMs, false)); // a client that was ahead of the host
	CHECK(!sky::reselect_after_jump(0, false));
	CHECK(!sky::reselect_after_jump(14 * kHourMs, true)); // a weather fx or the paused weather editor keeps its sections
}

TEST(sky_jump_note_sums_every_jump_and_gives_it_once)
{
	sky::JumpNote n;
	long long total = -1;
	CHECK(!n.take(total));
	CHECK_EQ(total, 0LL);
	n.note(14 * kHourMs);
	n.note(-1000);
	REQUIRE(n.take(total));
	CHECK_EQ(total, 14 * kHourMs + 1000);
	CHECK(!n.take(total));
	n.note(0);
	CHECK(!n.take(total));
	// two jumps that cancel out on the clock still moved it: the sky's sections are stale all the same
	n.note(3 * kHourMs);
	n.note(-3 * kHourMs);
	REQUIRE(n.take(total));
	CHECK(sky::reselect_after_jump(total, false));
	n.note(5 * kHourMs);
	n.clear();
	CHECK(!n.take(total));
}

// The live report: the group lies down at 22:30 and sleeps 12 h. The co-op host skips the time at the start of the sleep
// (coop_rest.cpp skip_time); its level_weathers sees the new hour at its next 3 s tick and selects deferred, and the forced
// change that actor_on_sleep (surge_manager) asks for arrives at dream_mid, seconds later: it waits for the next hour. Clients
// mirror the host's sections and never force. The sky stays on the 22:00 section until 11:00.
TEST(sky_stock_after_a_jump_past_midnight_keeps_the_night_until_the_next_forced_select)
{
	const std::vector<Section> c = hourly_cycle();
	Sky sky;
	sky.cycle = &c;
	sky.gt = at(22, 30);
	sky.forced_select();
	sky.stock_frame();
	CHECK_EQ(sky.s(0).hour, 22);
	sky.jump(12 * kHourMs);
	CHECK(std::fabs(sky.gt - at(10, 30)) < 1e-2f);
	sky.stock_frame(); // no step: 10:30 is before the window 22:00..23:00
	CHECK_EQ(sky.s(0).hour, 22);
	CHECK_EQ(sky.s(1).hour, 23);
	CHECK(sky.weight() < 1e-6f);
	CHECK(is_night(sky.shown_hour()));
	for (int m = 31; m < 60; ++m) // the clock runs to 10:59: still the night section
	{
		sky.gt = at(10, m);
		sky.stock_frame();
	}
	CHECK(is_night(sky.shown_hour()));
	sky.gt = at(11, 0) + 5.f; // the next hour tick of level_weathers with the forced flag: day "by itself"
	sky.forced_select();
	sky.stock_frame();
	CHECK_EQ(sky.shown_hour(), 11);
}

TEST(sky_coop_after_a_jump_past_midnight_is_day_at_once)
{
	const std::vector<Section> c = hourly_cycle();
	Sky sky;
	sky.cycle = &c;
	sky.gt = at(22, 30);
	sky.forced_select();
	sky::JumpNote note;
	sky.jump(12 * kHourMs);
	note.note(12 * kHourMs);
	coop_frame(sky, note);
	CHECK_EQ(sky.s(0).hour, 10);
	CHECK_EQ(sky.s(1).hour, 11);
	CHECK(std::fabs(sky.weight() - 0.5f) < 1e-3f);
	CHECK(!is_night(sky.shown_hour()));
	// and from there the stock steps on as always
	sky.gt = at(11, 0) + 1.f;
	coop_frame(sky, note);
	CHECK_EQ(sky.s(0).hour, 11);
	CHECK_EQ(sky.s(1).hour, 12);
}

// 01:30 + 9 h: the stock steps once and blends 02:00 (night) with 11:00; a forced select (the stock sleep) blends 10:00 with
// 11:00. The co-op jump does what the stock sleep does.
TEST(sky_coop_long_jump_inside_one_day_blends_the_sections_of_the_new_hour)
{
	const std::vector<Section> c = hourly_cycle();
	Sky stock, coop;
	stock.cycle = coop.cycle = &c;
	stock.gt = coop.gt = at(1, 30);
	stock.forced_select();
	coop.forced_select();
	stock.jump(9 * kHourMs);
	coop.jump(9 * kHourMs);
	sky::JumpNote note;
	note.note(9 * kHourMs);
	stock.stock_frame();
	coop_frame(coop, note);
	CHECK_EQ(stock.s(0).hour, 2); // what the coop host had before (6 % of the 02:00 night left in the blend)
	CHECK_EQ(stock.s(1).hour, 11);
	CHECK_EQ(coop.s(0).hour, 10);
	CHECK_EQ(coop.s(1).hour, 11);
}

TEST(sky_coop_small_corrections_leave_the_sections_to_the_stock)
{
	const std::vector<Section> c = hourly_cycle();
	Sky sky;
	sky.cycle = &c;
	sky.gt = at(10, 59) + 59.f;
	sky.forced_select();
	sky::JumpNote note;
	sky.jump(2000); // the client follows the host by 2 s, across 11:00
	note.note(2000);
	coop_frame(sky, note);
	CHECK_EQ(sky.s(0).hour, 11); // the stock's own step
	CHECK_EQ(sky.s(1).hour, 12);
	// a step back of 2 s just after the boundary: nothing chosen again (Current[0] is the 11:00 section the sky shows anyway)
	const size_t before0 = sky.cur[0], before1 = sky.cur[1];
	sky.jump(-3000);
	note.note(-3000);
	coop_frame(sky, note);
	CHECK_EQ(sky.cur[0], before0);
	CHECK_EQ(sky.cur[1], before1);
}

TEST(sky_coop_jump_over_days_and_during_an_fx)
{
	const std::vector<Section> c = hourly_cycle();
	Sky sky;
	sky.cycle = &c;
	sky.gt = at(22, 0);
	sky.forced_select();
	sky::JumpNote note;
	// coop_time / level.change_game_time(2, 3, 30): the time of day may stand past a day until the next frame of the level
	sky.gt = sky.gt + float(2 * 24 + 3) * kHour + 30.f * 60.f;
	note.note((2 * 24 + 3) * kHourMs + 30 * 60 * 1000LL);
	coop_frame(sky, note);
	CHECK_EQ(sky.s(0).hour, 1);
	CHECK_EQ(sky.s(1).hour, 2);
	// a weather fx owns its sections: the jump is not taken there
	Sky fx;
	fx.cycle = &c;
	fx.gt = at(20, 30);
	fx.forced_select();
	fx.jump(14 * kHourMs);
	note.note(14 * kHourMs);
	coop_frame(fx, note, true);
	CHECK_EQ(fx.s(0).hour, 20);
	long long left = 0;
	CHECK(!note.take(left)); // taken (and dropped) by that frame
}
