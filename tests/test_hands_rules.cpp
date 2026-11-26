// Anomaly Coop unit tests: what a puppet's hands show on a player's machine (xrCoop/coop_hands_rules.h).
// The case: an NPC at a campfire plays the guitar on the host, and a co-op player sees a pistol in its hand. Every guitar
// state asks the weapon "strapped": a strappable best weapon goes on the back, a pistol (no strap bones) is hidden.
// A: the host holds and straps a rifle while the puppet still has its pistol active: the forced global Strapped
//    property left the planner only "unstrapping", which waits for a torso animation callback a puppet never gets.
// B: the host holds nothing: the puppet's pistol waits for a hide that may never finish on a puppet.
// The engine side (coop_entities.cpp apply_creature_flags, drive_mirror) is checked in its source text at the end.
#include "test_util.h"

#include "coop_hands_rules.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>

using coop::hands::Decision;
using coop::hands::decide;
using coop::hands::first_snapshot_wait_ms;
using coop::hands::kHideGraceMs;
using coop::hands::kNoId;
using coop::hands::kStuckWaitMs;
using coop::hands::kStuckWaitSteps;
using coop::hands::kWaitStepMs;
using coop::hands::Seen;
using coop::hands::Wait;
using coop::hands::wait_check;
using coop::hands::wait_had_stall;
using coop::hands::wait_is_slow;
using coop::hands::wait_is_stuck;
using coop::hands::wait_was_starved;

namespace
{
constexpr uint16_t kRifle = 2101; // a weapon with strap bones (strap_bone0)
constexpr uint16_t kPistol = 2102; // a weapon without: never on the back
constexpr uint16_t kOtherRifle = 2103;
constexpr uint16_t kDevice = 2104; // a held item the object planner cannot put in hands (not a weapon, not a missile)

// The host's word and the puppet's active item here. held_can_strap: the held item has strap bones; planned: the
// planner can put it in hands (a weapon or a missile); ms: the caller's clock of a wrong item visible.
Seen seen(bool holds, bool strapped, uint16_t held, uint16_t active, bool hidden, bool can_strap, uint32_t ms = 0,
          bool held_can_strap = false, bool planned = true)
{
	Seen s;
	s.want_holds = holds;
	s.want_strapped = strapped;
	s.held_id = held;
	s.active_id = active;
	s.active_hidden = hidden;
	s.active_can_strap = can_strap;
	s.ms_wrong_item_visible = ms;
	s.held_can_strap = held_can_strap;
	s.held_planned = planned;
	return s;
}

// anomaly-coop/<rel>, the project root above this source file (tests\ -> ..), without '\r' (a checkout may have CRLF)
std::string project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

// The text from `from` to the first `to` after it; "" if `from` is missing.
std::string between(const std::string& src, const std::string& from, const std::string& to)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find(to, at + from.size());
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}
} // namespace

// The rifle the host straps is the puppet's active item, so the planner's world says strapped (the strapping animation's
// end never comes on a puppet) and weapon_bones puts it on the back, out of the hand.
TEST(npc_hands_the_held_strappable_rifle_in_hands_goes_on_the_back)
{
	const Decision d = decide(seen(true, true, kRifle, kRifle, false, true, 0, true));
	CHECK(d.strap);
	CHECK(!d.put_away);
	CHECK(d.done);
}

// A: the global Strapped property is not forced while another item is still active: Hide needs it false.
TEST(npc_hands_a_pistol_in_hands_while_the_host_straps_a_rifle_is_not_strapped)
{
	const Decision d = decide(seen(true, true, kRifle, kPistol, false, false, 0, true));
	CHECK(!d.strap);
	CHECK(!d.put_away); // the planner swaps it first: hide the pistol, show the rifle
	CHECK(!d.done);
}

TEST(npc_hands_another_strappable_weapon_in_hands_is_not_strapped_either)
{
	const Decision d = decide(seen(true, true, kRifle, kOtherRifle, false, true, 0, true));
	CHECK(!d.strap);
	CHECK(!d.done);
}

TEST(npc_hands_a_hidden_pistol_still_active_is_not_strapped)
{
	const Decision d = decide(seen(true, true, kRifle, kPistol, true, false, 60000, true));
	CHECK(!d.strap);
	CHECK(!d.put_away); // already hidden: nothing to push
	CHECK(!d.done);
}

// A has the same safety net as B: the wrong item still seen a grace later is put away (the host holds another one, so
// this does not fight it; the planner then shows the held item).
TEST(npc_hands_a_pistol_still_seen_past_the_grace_while_the_host_holds_a_rifle_is_put_away)
{
	Decision d = decide(seen(true, true, kRifle, kPistol, false, false, kHideGraceMs - 1, true));
	CHECK(!d.put_away);
	d = decide(seen(true, true, kRifle, kPistol, false, false, kHideGraceMs, true));
	CHECK(d.put_away);
	CHECK(!d.strap);
	CHECK(!d.done);
}

// Nothing active yet and the host straps a strappable rifle: strapped at once, so it shows straight on the back (no flash
// in the hand before it goes there). Nothing else can be stuck as "strapped": no other weapon is active.
TEST(npc_hands_nothing_active_and_a_strappable_held_rifle_is_strapped_at_once)
{
	const Decision d = decide(seen(true, true, kRifle, kNoId, false, false, 0, true));
	CHECK(d.strap);
	CHECK(!d.done); // done once it is the active, shown item
}

TEST(npc_hands_the_held_item_not_shown_yet_is_not_strapped_unless_strappable_and_nothing_active)
{
	// nothing active, the held item has no strap bones (a pistol the host somehow straps): never strapped
	Decision d = decide(seen(true, true, kPistol, kNoId, false, false, 0, false));
	CHECK(!d.strap);
	CHECK(!d.done);
	// the rifle active but still hidden (its show not under way): not strapped yet
	d = decide(seen(true, true, kRifle, kRifle, true, true, 0, true));
	CHECK(!d.strap);
	CHECK(!d.done);
}

// B: the host's hands are empty (a pistol is hidden at the guitar); the puppet's planner hides its pistol itself.
TEST(npc_hands_no_holds_and_a_pistol_just_seen_waits_for_the_planners_hide)
{
	Decision d = decide(seen(false, false, kNoId, kPistol, false, false, 0));
	CHECK(!d.put_away);
	CHECK(!d.done);
	CHECK(!d.strap);
	d = decide(seen(false, false, kNoId, kPistol, false, false, kHideGraceMs - 1));
	CHECK(!d.put_away);
	CHECK(!d.done);
}

TEST(npc_hands_no_holds_and_a_pistol_visible_past_the_grace_is_put_away)
{
	Decision d = decide(seen(false, false, kNoId, kPistol, false, false, kHideGraceMs));
	CHECK(d.put_away);
	CHECK(!d.done); // done once it is hidden or gone
	CHECK(!d.strap);
	d = decide(seen(false, false, kNoId, kPistol, false, false, 60000));
	CHECK(d.put_away);
}

TEST(npc_hands_no_holds_and_nothing_visible_is_done)
{
	Decision d = decide(seen(false, false, kNoId, kNoId, false, false));
	CHECK(d.done);
	CHECK(!d.put_away);
	CHECK(!d.strap);
	d = decide(seen(false, false, kNoId, kPistol, true, false, 60000)); // hidden, its active slot not cleared yet
	CHECK(d.done);
	CHECK(!d.put_away);
}

TEST(npc_hands_strapped_wanted_on_a_non_strappable_held_item_keeps_it_in_hands)
{
	const Decision d = decide(seen(true, true, kPistol, kPistol, false, false, 0, false));
	CHECK(!d.strap);
	CHECK(d.done);
}

TEST(npc_hands_strapped_without_holds_never_straps)
{
	// malformed (Strapped rides with Holds only): nothing to strap, the active item is hidden as with no Holds
	Decision d = decide(seen(false, true, kNoId, kRifle, false, true, 0));
	CHECK(!d.strap);
	CHECK(!d.done);
	CHECK(!d.put_away);
	d = decide(seen(false, true, kNoId, kRifle, false, true, kHideGraceMs));
	CHECK(!d.strap);
	CHECK(d.put_away);
	d = decide(seen(false, true, kNoId, kNoId, false, false, 0, true));
	CHECK(!d.strap);
	CHECK(d.done);
}

TEST(npc_hands_a_held_rifle_not_strapped_stays_in_hands)
{
	const Decision d = decide(seen(true, false, kRifle, kRifle, false, true, 0, true));
	CHECK(!d.strap);
	CHECK(d.done);
}

TEST(npc_hands_the_held_item_itself_is_never_put_away)
{
	const Decision d = decide(seen(true, false, kRifle, kRifle, false, true, 60000, true));
	CHECK(!d.put_away);
	CHECK(d.done);
}

TEST(npc_hands_holds_naming_no_item_is_never_done)
{
	const Decision d = decide(seen(true, true, kNoId, kNoId, false, false));
	CHECK(!d.strap);
	CHECK(!d.done);
}

// A held item the object planner cannot put in hands (only weapons and missiles have its operators, as coop_equip's
// "planned" for avatars): the puppet never activates it, so waiting for it would re-apply every 100 ms forever. Done once
// nothing wrong is seen; a wrong item seen past the grace is still put away.
TEST(npc_hands_a_held_item_the_planner_cannot_show_is_done_with_empty_hands)
{
	Decision d = decide(seen(true, false, kDevice, kNoId, false, false, 0, false, false));
	CHECK(d.done);
	CHECK(!d.strap);
	d = decide(seen(true, false, kDevice, kPistol, false, false, 0, false, false));
	CHECK(!d.done);
	CHECK(!d.put_away);
	d = decide(seen(true, false, kDevice, kPistol, false, false, kHideGraceMs, false, false));
	CHECK(d.put_away);
}

// The grace outlasts the start of the planner's own hide and stays short: the host clears Holds only after its hide
// ended, and the puppet's body already played that hide, so a longer wait is only lag.
static_assert(kHideGraceMs >= 300u && kHideGraceMs <= 1000u, "the put-away grace is short: the host's hide already ended");

// A wait of the copy's hands, counted in the copy's own time (hands::Wait). `run` begins a wait and adds checks after
// it, each `gap_ms` after the one before over `frames` frames, against the retry `due_ms`, until it is stuck or `limit`
// checks; it gives the wall clock at the last check.
namespace
{
constexpr uint32_t kHandsRetry = 100; // coop_entities.cpp kHandsRetryMs: the retry of a wait under way

uint32_t run(Wait& w, uint32_t gap_ms, uint32_t due_ms, uint32_t limit, uint32_t frames = 1)
{
	wait_check(w, 0, due_ms, 0, 0);
	uint32_t ms = 0;
	while (!wait_is_stuck(w) && w.checks < limit)
	{
		wait_check(w, gap_ms, due_ms, frames, 0);
		ms += gap_ms;
	}
	return ms;
}
} // namespace

// The check that begins a wait counts no time; each later one adds its gap, no more than one slowest step.
TEST(npc_hands_a_wait_counts_the_gaps_between_its_checks)
{
	Wait w;
	wait_check(w, 5000, 100, 300, 0); // the first: its gap is the time before the wait
	CHECK(w.checks == 1u && w.own_ms == 0u && w.late_ms == 0u);
	wait_check(w, 100, 100, 6, 0);
	CHECK(w.checks == 2u && w.own_ms == 100u && w.late_ms == 0u);
	wait_check(w, 4000, 100, 200, 0); // the copy's turn came late: one step
	CHECK(w.own_ms == 100u + kWaitStepMs);
	CHECK(w.late_ms == 3900u && w.late_frames == 200u);
	wait_check(w, 300, 100, 20, 0); // a later, smaller lateness keeps the latest
	CHECK(w.late_ms == 3900u && w.late_frames == 200u);
	CHECK(wait_was_starved(w) && w.starved_ms == 3900u);
	CHECK(!wait_had_stall(w));
}

// A frame of seconds, or the scheduler reaching the copy late, is one step: a wait across it is not stuck.
TEST(npc_hands_a_wait_across_a_stall_is_not_stuck)
{
	Wait w;
	wait_check(w, 0, 100, 0, 0);
	for (int i = 0; i < 6; ++i)
		wait_check(w, 100, 100, 6, 0);
	wait_check(w, 60000, 100, 1, 0); // one frame of a minute
	CHECK(!wait_is_stuck(w));
	CHECK(w.late_frames == 1u); // a long frame, not the copy left out
	CHECK(wait_had_stall(w) && w.stall_ms == 59900u);
	CHECK(!wait_was_starved(w));
}

// A check more than a step late is a frame stall when the frames of its gap took a slowest step or more each on
// average (no update could have come sooner), and starvation when shorter frames ran without the copy's update. A check
// late by a step or less is neither: that is a far copy's own scheduler step.
TEST(npc_hands_a_late_check_is_a_stall_or_starvation_by_its_frames)
{
	Wait stall;
	wait_check(stall, 0, 100, 0, 0);
	wait_check(stall, 3000, 100, 3, 0); // three frames of a second each
	CHECK(wait_had_stall(stall) && !wait_was_starved(stall));
	Wait mixed;
	wait_check(mixed, 0, 100, 0, 0);
	wait_check(mixed, 60000, 100, 20, 0); // a frame of a minute among short ones: still the stall held it
	CHECK(wait_had_stall(mixed) && !wait_was_starved(mixed));
	Wait same_frame;
	wait_check(same_frame, 0, 100, 0, 0);
	wait_check(same_frame, 2000, 100, 0, 0); // the clock ran within one frame
	CHECK(wait_had_stall(same_frame) && !wait_was_starved(same_frame));
	Wait starved;
	wait_check(starved, 0, 100, 0, 0);
	wait_check(starved, 2000, 100, 60, 0); // 60 frames of 33 ms without the copy's update
	CHECK(wait_was_starved(starved) && !wait_had_stall(starved));
	Wait both;
	wait_check(both, 0, 100, 0, 0);
	wait_check(both, 2000, 100, 60, 0);
	wait_check(both, 5000, 100, 1, 0);
	CHECK(wait_was_starved(both) && wait_had_stall(both));
	CHECK(both.starved_ms == 1900u && both.stall_ms == 4900u);
	Wait far;
	wait_check(far, 0, 100, 0, 0);
	wait_check(far, kWaitStepMs, 100, 1, 0); // a far copy's step: late by less than a step
	wait_check(far, 100 + kWaitStepMs, 100, 40, 0); // late by exactly a step
	CHECK(!wait_had_stall(far) && !wait_was_starved(far));
}

// Near or far, a wait reads as stuck after the same 5 s of running frames, and never before the farthest copy had twice
// the four steps a swap through the put-away takes it.
TEST(npc_hands_stuck_means_the_same_near_and_far)
{
	constexpr uint32_t kCamera = 100, kAt30m = 178, kAt150m = 493, kFar = 625; // a creature's scheduler steps
	for (uint32_t step : {kCamera, kAt30m, kAt150m, kFar})
	{
		Wait w;
		const uint32_t ms = run(w, step, kHandsRetry, 100000);
		CHECK(wait_is_stuck(w));
		CHECK(ms >= kStuckWaitMs && ms < kStuckWaitMs + step);
		CHECK(!wait_had_stall(w) && !wait_was_starved(w));
	}
	Wait far;
	run(far, kFar, kHandsRetry, 1 + 4); // the four steps of a swap
	CHECK(!wait_is_stuck(far));
	static_assert(kStuckWaitSteps >= 2u * 4u, "twice the steps of a swap through the put-away");
}

// A copy that never gets there is flagged at every check rate the caller uses: 100 ms, 1 s (a torch not here yet), and a
// copy the scheduler keeps leaving out (each late check one step).
TEST(npc_hands_a_copy_that_never_gets_there_is_stuck)
{
	Wait hands;
	CHECK(run(hands, 100, kHandsRetry, 100000) <= kStuckWaitMs);
	Wait torch;
	CHECK(run(torch, 1000, 1000, 100000) == kStuckWaitSteps * 1000u);
	Wait starved;
	run(starved, 4000, kHandsRetry, 100000, 200);
	CHECK(wait_is_stuck(starved) && starved.checks == 1u + kStuckWaitSteps);
	CHECK(wait_was_starved(starved) && !wait_had_stall(starved));
}

// A copy's first snapshot is waited for from the first time it was driven here without a track, bounded by its
// appearance: a track that went and came again measures its own wait, not the time since the copy first appeared.
TEST(npc_hands_the_first_snapshot_wait_is_the_tracks_own)
{
	// appeared at 1000 and driven without a track from then; the first snapshot at 4000
	CHECK(first_snapshot_wait_ms(1000, 1000, 4000) == 3000u);
	CHECK(wait_is_slow(first_snapshot_wait_ms(1000, 1000, 4000)));
	// a snapshot came before it was ever driven: no wait
	CHECK(first_snapshot_wait_ms(1000, 0, 4000) == 0u);
	// its track went at 60000 (the client going live) and the next snapshot came at 60200: 200 ms, not 59 s
	CHECK(first_snapshot_wait_ms(1000, 60000, 60200) == 200u);
	CHECK(!wait_is_slow(first_snapshot_wait_ms(1000, 60000, 60200)));
	// a time left by an earlier object of this id counts nothing before this one appeared
	CHECK(first_snapshot_wait_ms(50000, 1000, 50300) == 300u);
	// a snapshot taken before that time (the same frame) is no wait
	CHECK(first_snapshot_wait_ms(1000, 5000, 4000) == 0u);
}

// Slow is the wall clock past the put-away grace; the longest wrong item seen is kept.
TEST(npc_hands_a_slow_wait_and_the_wrong_item_it_showed)
{
	CHECK(!wait_is_slow(kHideGraceMs - 1));
	CHECK(wait_is_slow(kHideGraceMs));
	Wait w;
	wait_check(w, 0, 100, 0, 0);
	wait_check(w, 100, 100, 6, 650);
	wait_check(w, 100, 100, 6, 0); // put away: nothing wrong seen now
	CHECK(w.wrong_ms == 650u);
}

// The remedy comes first: a stuck line is for a wait the put-away did not end; a step is the slowest scheduler step of a
// creature, (1000 + t_max 250) / 2.
static_assert(kStuckWaitMs > kHideGraceMs, "the put-away has its chance before a wait reads as stuck");
static_assert(kWaitStepMs == (1000u + 250u) / 2u, "a step is a creature's slowest scheduler step");

// The engine side follows the rule: the planner's Strapped is the rule's, the put-away is the stock hide request and the
// end of the hide, a held item that is not here yet resets the clocks, and a hands-only wait retries shortly.
TEST(npc_hands_engine_wiring_follows_the_rule)
{
	const std::string src = project_file("engine/src/xrGame/coop/coop_entities.cpp");
	CHECK(!src.empty());
	const std::string fn = between(src, "bool apply_creature_flags(", "\nbool apply_attachments(");
	CHECK(!fn.empty());
	CHECK(fn.find("hands::decide(seen)") != std::string::npos);
	CHECK(fn.find("set_property(ObjectHandlerSpace::eWorldPropertyStrapped, rule.strap)") != std::string::npos);
	CHECK(fn.find("set_property(ObjectHandlerSpace::eWorldPropertyStrapped2Idle, false)") != std::string::npos);
	CHECK(fn.find("Activate(NO_ACTIVE_SLOT)") != std::string::npos);
	CHECK(fn.find("SwitchState(CHUDState::eHidden)") != std::string::npos);
	CHECK(fn.find("held_planned") != std::string::npos);
	CHECK(fn.find("held_can_strap") != std::string::npos);
	// a held item not here yet: the clocks restart before the early return
	const std::string early = between(fn, "if (!item)", "return false;");
	CHECK(early.find("track.wrong = false") != std::string::npos);
	CHECK(early.find("end_wait(obj, track, now, false)") != std::string::npos);
	CHECK(fn.find("track.retry_ms = kFlagsRetryMs") != std::string::npos);
	CHECK(fn.find("track.retry_ms = kHandsRetryMs") != std::string::npos);
	CHECK(src.find("constexpr u32 kHandsRetryMs = 100;") != std::string::npos);
	CHECK(src.find("track.flags_retry = now + track.hands.retry_ms") != std::string::npos);
}

// A wait lives in its MirrorTrack, and the track keeps its newest sample until it goes: drive_mirror's return for a copy
// with no sample (interpolate) cannot cut a wait short; a copy waits between checks only for its own update.
TEST(npc_hands_engine_a_wait_always_has_a_sample)
{
	const std::string src = project_file("engine/src/xrGame/coop/coop_entities.cpp");
	size_t pops = 0;
	for (size_t at = src.find("samples.pop_front()"); at != std::string::npos; at = src.find("samples.pop_front()", at + 1))
		++pops;
	CHECK(pops == 1u);
	CHECK(src.find("while (t.samples.size() > 24)\n\t\t\tt.samples.pop_front();") != std::string::npos);
	CHECK(src.find("samples.clear()") == std::string::npos);
	const std::string interp = between(src, "bool interpolate(MirrorTrack& t,", "\n}\n");
	CHECK(interp.find("if (t.samples.empty())\n\t\treturn false;") != std::string::npos);
}

// The error line is for a stuck wait only: every check is counted into the wait, the one "! [coop-hands]" line comes
// after hands::wait_is_stuck, and the put-away (the rule's remedy), the end of a slow wait and a late first snapshot are
// plain lines.
TEST(npc_hands_engine_error_line_only_for_a_stuck_wait)
{
	const std::string src = project_file("engine/src/xrGame/coop/coop_entities.cpp");
	const std::string fn = between(src, "bool apply_creature_flags(", "\nbool apply_attachments(");
	CHECK(!fn.empty());
	CHECK(fn.find("hands::wait_check(track.wait, gap, due, frames, seen.ms_wrong_item_visible)") != std::string::npos);
	const size_t stuck = fn.find("hands::wait_is_stuck(track.wait)");
	CHECK(stuck != std::string::npos);
	const size_t bang = fn.find("\"! [coop-hands]");
	CHECK(bang != std::string::npos && bang > stuck);
	CHECK(fn.find("\"! [coop-hands]", bang + 1) == std::string::npos);
	size_t lines = 0;
	for (size_t at = src.find("! [coop-hands]"); at != std::string::npos; at = src.find("! [coop-hands]", at + 1))
		++lines;
	CHECK(lines == 1u);
	CHECK(fn.find("\"[coop-hands] npc %u put away") != std::string::npos);
	CHECK(fn.find("end_wait(obj, track, now, true)") != std::string::npos);
	const std::string end = between(src, "void end_wait(", "\n}\n");
	CHECK(end.find("\"[coop-hands] npc %u %s after %u ms, %u checks") != std::string::npos);
	CHECK(end.find("\"hands as the host's\"") != std::string::npos);
	CHECK(src.find("\"[coop-hands] npc %u had no snapshot for %u ms after it came here without one") != std::string::npos);
	const std::string status = between(src, "void print_status()", "\n}\n");
	CHECK(status.find("NPC hands (R71): ") != std::string::npos);
	CHECK(status.find("%llu slow (%llu ended") != std::string::npos);
	CHECK(status.find("%llu dropped; %llu ended unseen; %llu under way") != std::string::npos);
	CHECK(status.find("%llu stretched by a frame stall, %llu starved") != std::string::npos);
}

// Every slow wait is counted once at its end: as the host's or dropped in end_wait, unseen when its track goes first
// (HandsTrack's destructor; a HandsTrack is never copied). Stalls and starvation are counted apart.
TEST(npc_hands_engine_every_slow_wait_is_counted_at_its_end)
{
	const std::string src = project_file("engine/src/xrGame/coop/coop_entities.cpp");
	const std::string end = between(src, "void end_wait(", "\n}\n");
	CHECK(end.find("++g_hands_slow_ended;") != std::string::npos);
	CHECK(end.find("++g_hands_slow_dropped;") != std::string::npos);
	const std::string track = between(src, "struct HandsTrack\n", "\n};\n");
	CHECK(track.find("HandsTrack(const HandsTrack&) = delete;") != std::string::npos);
	CHECK(track.find("if (waiting && slow)\n\t\t\t++g_hands_slow_unseen;") != std::string::npos);
	const std::string fn = between(src, "bool apply_creature_flags(", "\nbool apply_attachments(");
	CHECK(fn.find("hands::wait_had_stall(track.wait)") != std::string::npos);
	CHECK(fn.find("hands::wait_was_starved(track.wait)") != std::string::npos);
	CHECK(src.find("wait_lacked_updates") == std::string::npos);
}

// The first snapshot's wait starts when the copy is driven without a track and ends at its first check on a track.
TEST(npc_hands_engine_first_snapshot_wait_starts_without_a_track)
{
	const std::string src = project_file("engine/src/xrGame/coop/coop_entities.cpp");
	const std::string drive = between(src, "bool drive_mirror(", "\n}\n");
	CHECK(drive.find("if (!track)\n\t\t\tnote_trackless(obj, now);") != std::string::npos);
	CHECK(drive.find("note_first_snapshot(obj, track, book.since_ms, now)") != std::string::npos);
	const std::string note = between(src, "void note_first_snapshot(", "\n}\n");
	CHECK(note.find("hands::first_snapshot_wait_ms(appeared_at, trackless_at, track.first_sample_at)") != std::string::npos);
	CHECK(note.find("g_hands_trackless.erase(it)") != std::string::npos);
	const std::string reset = between(src, "\nvoid reset()", "\n}\n");
	CHECK(reset.find("g_hands_trackless.clear();") != std::string::npos);
}
