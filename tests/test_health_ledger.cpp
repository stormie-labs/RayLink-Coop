// Anomaly Coop unit tests: the own actor's health ledger (xrCoop/coop_health_ledger.h, glue in xrGame/coop/coop_health_ledger.cpp).
// Live 2026-11-09 (G.A.M.M.A., 6 players): a client's health fell 0.018/s for 2.5 min without a hit from the host, and no
// log said who lowered it. Every 15 s window in which the own actor's health fell by 0.02 or more gets one line: the scripts
// that wrote it (by file:line), the hits, the co-op's own writes, the condition update, and what none of them explains.
#include "test_util.h"

#include "coop_health_ledger.h"

#include <cmath>
#include <string>

using namespace coop;
using health_ledger::Ledger;
using health_ledger::Vitals;

namespace
{
constexpr uintptr_t kActor = 7;

Vitals calm()
{
	Vitals v;
	v.satiety = 0.611f;
	v.psy = 1.f;
	return v;
}

bool contains(const std::string& s, const std::string& part)
{
	const bool ok = s.find(part) != std::string::npos;
	if (!ok)
		std::printf("    line: %s\n    want: %s\n", s.c_str(), part.c_str());
	return ok;
}

// One window from `from` to `to` health; `events` runs between its first and its last frame. Returns the line ("" if none).
template <class Events>
std::string window(Ledger& l, uint64_t& now, float from, float to, Events events)
{
	std::string line;
	l.frame(now, kActor, from, line, calm); // opens the window (or closes the previous one at this health)
	line.clear();
	events();
	now += health_ledger::kWindowMs;
	l.frame(now, kActor, to, line, calm);
	return line;
}
} // namespace

TEST(health_ledger_caller_key_is_the_script_file_and_line)
{
	CHECK_EQ(health_ledger::caller_key("...\\gamedata\\scripts\\grok_actor_damage_balancer.script", 751),
	    std::string("grok_actor_damage_balancer.script:751"));
	CHECK_EQ(health_ledger::caller_key("gamedata/scripts/perk_based_artefacts.script", 1087),
	    std::string("perk_based_artefacts.script:1087"));
	CHECK_EQ(health_ledger::caller_key("bind_stalker.script", 3), std::string("bind_stalker.script:3"));
	CHECK_EQ(health_ledger::caller_key("", 5), std::string("?"));
	CHECK_EQ(health_ledger::caller_key(nullptr, 5), std::string("?"));
}

TEST(health_ledger_reports_a_drop_of_0_02_after_15_s)
{
	Ledger l;
	std::string line;
	CHECK(!l.frame(1000, kActor, 0.709f, line, calm)); // the first frame only opens the window
	for (int i = 0; i < 14; ++i)
		l.script("perk_based_artefacts.script:1087", -0.25f / 14);
	l.script("grok_actor_damage_balancer.script:751", -0.02f);
	CHECK(!l.frame(15999, kActor, 0.439f, line, calm)); // not 15 s yet
	CHECK(line.empty());
	REQUIRE(l.frame(16000, kActor, 0.439f, line, calm));
	CHECK_EQ(line,
	    std::string("health 0.709 -> 0.439 in 15 s: scripts -0.270 (perk_based_artefacts.script:1087 -0.250 x14, "
	                "grok_actor_damage_balancer.script:751 -0.020 x1), hits 0 applied (power 0.000, health 0.000), coop applies "
	                "0.000, condition 0.000 (bleeding 0.0000, radiation 0.000, satiety 0.611, psy 1.000, boosters: none), other 0.000"));
	CHECK_EQ(l.lines(), 1u);
}

TEST(health_ledger_no_line_for_a_small_drop_or_a_rise)
{
	Ledger l;
	uint64_t now = 1000;
	CHECK_EQ(window(l, now, 0.9f, 0.881f, [] {}), std::string("")); // 0.019
	CHECK_EQ(window(l, now, 0.881f, 0.95f, [] {}), std::string("")); // a rise
	CHECK_EQ(l.lines(), 0u);
	// The window that just closed at 0.95 is where the next one starts: 0.95 -> 0.92 is a drop of 0.03.
	std::string line;
	now += health_ledger::kWindowMs;
	CHECK(l.frame(now, kActor, 0.92f, line, calm));
	CHECK(contains(line, "health 0.950 -> 0.920 in 15 s"));
	CHECK(contains(line, "other -0.030"));
}

TEST(health_ledger_each_window_has_only_its_own_changes)
{
	Ledger l;
	uint64_t now = 1000;
	const std::string first = window(l, now, 1.f, 0.9f, [&] { l.script("a.script:1", -0.1f); });
	CHECK(contains(first, "scripts -0.100 (a.script:1 -0.100 x1)"));
	std::string line;
	l.condition(-0.05f, true);
	now += health_ledger::kWindowMs;
	REQUIRE(l.frame(now, kActor, 0.85f, line, calm));
	CHECK(contains(line, "health 0.900 -> 0.850 in 15 s: scripts 0.000, hits 0 applied"));
	CHECK(contains(line, "condition -0.050 ("));
}

TEST(health_ledger_scripts_keep_the_top_three_callers_and_sum_the_rest)
{
	Ledger l;
	uint64_t now = 1000;
	const std::string line = window(l, now, 1.f, 0.915f, [&] {
		l.script("a.script:1", -0.1f);
		l.script("b.script:2", -0.03f);
		l.script("b.script:2", -0.02f);
		l.script("c.script:3", 0.08f); // a heal counts by its size too
		l.script("d.script:4", -0.004f);
		l.script("d.script:4", -0.003f);
		l.script("d.script:4", -0.003f);
		l.script("e.script:5", -0.005f);
	});
	CHECK(contains(line, "scripts -0.085 (a.script:1 -0.100 x1, c.script:3 0.080 x1, b.script:2 -0.050 x2, others -0.015 x4)"));
	CHECK(contains(line, "other 0.000"));
}

TEST(health_ledger_too_many_callers_go_to_the_others)
{
	Ledger l;
	uint64_t now = 1000;
	const std::string line = window(l, now, 1.f, 0.9f, [&] {
		for (int i = 0; i < 100; ++i)
			l.script("s.script:" + std::to_string(i), -0.001f);
	});
	CHECK(contains(line, "scripts -0.100 ("));
	CHECK(contains(line, "others -0.097 x97)"));
	CHECK(contains(line, "other 0.000"));
}

TEST(health_ledger_change_health_counts_for_its_script_not_the_condition)
{
	Ledger l;
	uint64_t now = 1000;
	// change_health(-0.03) only queues: the next condition update applies it with its own -0.005 (bleeding).
	const std::string line = window(l, now, 0.8f, 0.765f, [&] {
		l.script_queued("x.script:5", -0.03f);
		l.condition(-0.035f, true);
	});
	CHECK(contains(line, "scripts -0.030 (x.script:5 -0.030 x1)"));
	CHECK(contains(line, "condition -0.005 ("));
	CHECK(contains(line, "other 0.000"));
}

TEST(health_ledger_a_queue_the_condition_update_did_not_apply_waits)
{
	Ledger l;
	uint64_t now = 1000;
	const std::string line = window(l, now, 0.8f, 0.77f, [&] {
		l.script_queued("x.script:5", -0.03f);
		l.condition(0.f, false); // health <= 0: CEntityCondition::UpdateCondition returned at once, the queue stays
		l.condition(-0.03f, true);
	});
	CHECK(contains(line, "scripts -0.030 (x.script:5 -0.030 x1)"));
	CHECK(contains(line, "condition 0.000 ("));
	CHECK(contains(line, "other 0.000"));
}

TEST(health_ledger_damage_inside_a_hit_is_the_hits_not_the_condition)
{
	Ledger l;
	uint64_t now = 1000;
	const std::string line = window(l, now, 0.9f, 0.777f, [&] {
		l.hit_begin(0.45f);
		CHECK(l.in_hit());
		l.script("grok_actor_damage_balancer.script:751", -0.1f); // actor_on_before_hit: power 0, set_health_ex
		l.condition(-0.02f, true); // CEntityAlive::CalcCondition -> UpdateCondition inside CActor::Hit
		l.hit_end();
		CHECK(!l.in_hit());
		l.condition(-0.003f, true); // the scheduled update
	});
	CHECK(contains(line, "scripts -0.100 (grok_actor_damage_balancer.script:751 -0.100 x1), hits 1 applied (power 0.450, "
	                     "health -0.020), coop applies 0.000, condition -0.003 ("));
	CHECK(contains(line, "other 0.000"));
}

TEST(health_ledger_nested_hits_count_each_and_never_underflow)
{
	Ledger l;
	uint64_t now = 1000;
	const std::string line = window(l, now, 0.9f, 0.8f, [&] {
		l.hit_begin(0.2f);
		l.hit_begin(0.1f); // a script's hit from inside actor_on_before_hit
		l.hit_end();
		CHECK(l.in_hit());
		l.condition(-0.1f, true);
		l.hit_end();
		l.hit_end(); // one too many: no wrap-around
		CHECK(!l.in_hit());
	});
	CHECK(contains(line, "hits 2 applied (power 0.300, health -0.100)"));
	CHECK(contains(line, "condition 0.000 ("));
}

TEST(health_ledger_coop_applies_are_their_own_bucket)
{
	Ledger l;
	uint64_t now = 1000;
	const std::string line = window(l, now, 0.5f, 0.05f, [&] {
		l.condition(-0.5f, true); // down to 0
		l.coop(0.05f); // the condition hook: wounded at kDownHealth, not dead
	});
	CHECK(contains(line, "coop applies 0.050, condition -0.500 ("));
	CHECK(contains(line, "other 0.000"));
}

TEST(health_ledger_condition_part_lists_vitals_and_boosters)
{
	Ledger l;
	std::string line;
	unsigned asked = 0;
	auto vitals = [&] {
		++asked;
		Vitals v;
		v.bleeding = 0.0012f;
		v.radiation = 0.25f;
		v.satiety = 0.6f;
		v.psy = 0.9f;
		v.boosters.push_back({"health_restore", 0.0005f});
		v.boosters.push_back({"radiation_restore", 0.002f});
		return v;
	};
	l.frame(1000, kActor, 0.9f, line, vitals);
	l.frame(16000, kActor, 0.89f, line, vitals); // 0.01: no line, the vitals are not even read
	CHECK_EQ(asked, 0u);
	REQUIRE(l.frame(31000, kActor, 0.8f, line, vitals));
	CHECK_EQ(asked, 1u);
	CHECK(contains(line, "(bleeding 0.0012, radiation 0.250, satiety 0.600, psy 0.900, boosters: health_restore 0.0005, "
	                     "radiation_restore 0.0020)"));
}

TEST(health_ledger_a_new_actor_starts_over)
{
	Ledger l;
	std::string line;
	l.frame(1000, kActor, 0.9f, line, calm);
	l.script("a.script:1", -0.5f);
	l.script_queued("q.script:2", -0.03f); // never applied to the new actor
	CHECK(!l.frame(16000, kActor + 1, 1.f, line, calm)); // a new actor: its first frame opens a window
	l.condition(-0.03f, true);
	REQUIRE(l.frame(31000, kActor + 1, 0.97f, line, calm));
	CHECK(contains(line, "health 1.000 -> 0.970 in 15 s: scripts 0.000"));
	CHECK(contains(line, "condition -0.030 ("));
}

TEST(health_ledger_stop_ends_the_window_without_a_line)
{
	Ledger l;
	std::string line;
	l.frame(1000, kActor, 0.9f, line, calm);
	l.script("a.script:1", -0.5f);
	l.stop(); // no world, no actor
	CHECK(!l.frame(16000, kActor, 0.4f, line, calm)); // opens a new window
	CHECK(!l.frame(31000, kActor, 0.4f, line, calm));
	CHECK(line.empty());
	CHECK(!l.frame(32000, kActor, std::nanf(""), line, calm)); // not a number: no line, the window starts over
	CHECK(!l.frame(47000, kActor, 0.3f, line, calm));
}

TEST(health_ledger_writes_at_most_300_lines_per_process)
{
	Ledger l;
	std::string line;
	uint64_t now = 1000;
	float health = 1.f;
	l.frame(now, kActor, health, line, calm);
	unsigned written = 0;
	std::string last;
	for (int i = 0; i < 400; ++i) // about 10 drops in 11 windows
	{
		now += health_ledger::kWindowMs;
		health = health > 0.5f ? health - 0.05f : 1.f;
		line.clear();
		if (l.frame(now, kActor, health, line, calm))
		{
			++written;
			last = line;
		}
	}
	CHECK_EQ(written, health_ledger::kMaxLines);
	CHECK_EQ(l.lines(), health_ledger::kMaxLines);
	CHECK(contains(last, "; the last health line of this process"));
}
