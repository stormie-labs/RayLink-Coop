// Anomaly Coop unit tests: TZ R32 W8.1/W8.2, the decider's deliberate write and the owner's report field by field
// (coop_owner_rules.h over coop_item_tags.h). Closes gap-g4 F1 (FDDA charge) and F3 (combat-heal dose) at the rule level.
// WP6 fix round: the uses are a counter (a dose eaten inside the round trip of a debit stays spent, finding 4); a late report is
// judged like an owned one (finding 3); the engine glue that calls these rules is read from the sources (finding 6: the model below
// alone would pass without it).
#include "test_util.h"

#include "coop_item_tags.h"
#include "coop_owner_rules.h"

#include <cstdint>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using namespace coop;

namespace
{
// Same field names as ItemData in coop_items.cpp (the templates read exactly these).
struct Item
{
	bool has_cond = false;
	std::uint16_t cond = 0;
	bool has_upgrades = false;
	std::vector<std::string> upgrades;
	bool has_box = false;
	std::uint16_t box = 0;
	bool has_addons = false;
	std::uint8_t addons = 0;
	bool has_scope = false;
	std::uint8_t scope = 0;
	bool has_main = false;
	std::uint16_t main_count = 0;
	std::uint8_t main_type = 0;
	bool has_launcher = false;
	std::uint16_t gl_count = 0;
	std::uint8_t gl_type = 0;
	bool has_uses = false;
	std::uint8_t uses = 0;
};

bool same_list(const std::vector<std::string>& a, const std::vector<std::string>& b) { return a == b; }

Item medkit(std::uint16_t cond, std::uint8_t uses)
{
	Item i;
	i.has_cond = true;
	i.cond = cond;
	i.has_uses = true;
	i.uses = uses;
	return i;
}

// The engine's apply of a state onto a copy (coop_items.cpp apply_object): every tag the state carries.
void apply(Item& copy, const Item& s)
{
	if (s.has_cond)
	{
		copy.has_cond = true;
		copy.cond = s.cond;
	}
	if (s.has_uses)
	{
		copy.has_uses = true;
		copy.uses = s.uses;
	}
	if (s.has_main)
	{
		copy.has_main = true;
		copy.main_count = s.main_count;
		copy.main_type = s.main_type;
	}
}

// A decider's push as it leaves (coop_items.cpp host_push_decider): the baseline's tags, its latest versions, the change of the
// latest version of the uses when its history has it (blob tag 13).
struct Push
{
	std::uint32_t mask = 0;
	Item state;
	itemtags::FieldVersions versions;
	bool has_delta = false;
	int delta = 0;
};

// The decider (coop_items.cpp host side): its copy (the game object), its baseline (Owned.data), its latest versions, the changes
// of its recent writes of the uses (g_uses_history).
struct Decider
{
	Item copy;
	Item baseline;
	itemtags::FieldVersions latest;
	owner::CounterHistory uses_history;
	int max_uses = 255;
	std::vector<std::uint32_t> pushes; // tags pushed to the owner, in order
	std::vector<Push> sent; // the same pushes, as they left
	bool last_rebased = false;

	Push push(std::uint32_t mask) const
	{
		Push p;
		p.mask = mask;
		p.state = itemtags::only_tags(baseline, mask);
		p.versions = latest;
		p.has_delta = p.state.has_uses && uses_history.delta_of(latest.get(itemtags::Uses), p.delta);
		return p;
	}

	// A script's setter (script_game_object.cpp SetCondition, script_game_object3.cpp SetRemainingUses).
	void setter(owner::Setter s, std::uint16_t value, bool applying_owner_state = false)
	{
		if (s == owner::Setter::Condition)
			copy.cond = value;
		else
			copy.uses = std::uint8_t(value);
		if (!owner::deliberate(true, true, applying_owner_state))
			return;
		const std::uint32_t mask = owner::tags_of(s);
		const Item before = baseline;
		baseline = owner::adopt(baseline, copy, mask);
		itemtags::bump(latest, mask);
		if ((mask & itemtags::Uses) && before.has_uses && copy.has_uses) // decider_wrote
			uses_history.record(latest.get(itemtags::Uses), int(copy.uses) - int(before.uses));
		pushes.push_back(mask);
		sent.push_back(push(mask));
	}
	// host_enforce: engine drift on the copy goes back to the baseline.
	bool enforce()
	{
		if (!itemtags::diverged(copy, baseline, same_list))
			return false;
		apply(copy, baseline);
		return true;
	}
	// host_on_state: the owner's report (Access::Owned, `late` false) or the report of an item that has just left his hands
	// (Access::Late, `late` true: judged the same, no push, no baseline: he holds it no more); returns the tags refused.
	std::uint32_t report(const Item& r, const itemtags::FieldVersions& v, bool late = false)
	{
		const std::uint32_t carried = (r.has_cond ? itemtags::Cond : 0u) | (r.has_uses ? itemtags::Uses : 0u) |
		    (r.has_main ? itemtags::Main : 0u);
		const owner::ReportVerdict verdict = owner::judge_report(latest, v, carried, uses_history, int(r.uses), max_uses);
		last_rebased = verdict.rebased;
		Item taken = r;
		if (verdict.rebased)
			taken.uses = std::uint8_t(verdict.uses);
		taken = itemtags::only_tags(taken, carried & ~verdict.refused);
		apply(copy, taken);
		if (late)
			return verdict.refused;
		apply(baseline, taken);
		// The refused tags and rebased uses go back to him (their own push is usually ahead of this one: he takes it as a repeat).
		const std::uint32_t back = verdict.refused | (verdict.rebased ? std::uint32_t(itemtags::Uses) : 0u);
		if (back)
		{
			pushes.push_back(back);
			sent.push_back(push(back));
		}
		return verdict.refused;
	}

	// coop_items.cpp writer_set_staged with no owner known yet: uses staged for an item with no object are set on its object when
	// it spawns (`before`: what it read from the save); the version moves on with the change, nothing is pushed (no owner).
	void staged(std::uint8_t uses)
	{
		const int before = copy.uses;
		copy.uses = uses;
		baseline.uses = uses;
		itemtags::bump(latest, itemtags::Uses);
		uses_history.record(latest.get(itemtags::Uses), int(uses) - before);
	}
};

// The owner (coop_items.cpp client side, client_apply with kFlagDecider): his copy and the versions he has applied.
struct Owner
{
	Item copy;
	itemtags::FieldVersions applied;

	std::uint32_t take(const Push& p)
	{
		const std::uint32_t a = owner::push_applies(applied, p.versions, p.mask);
		Item part = itemtags::only_tags(p.state, a);
		if (part.has_uses)
			part.uses = std::uint8_t(owner::owner_takes_uses(applied.get(itemtags::Uses), p.versions.get(itemtags::Uses), p.has_delta,
			    p.delta, int(part.uses), copy.has_uses, int(copy.uses), 255));
		apply(copy, part);
		itemtags::take(applied, p.versions, a);
		return a;
	}
	// The decider's push of `mask` as it would leave now.
	std::uint32_t take(const Decider& d, std::uint32_t mask) { return take(d.push(mask)); }
};
} // namespace

TEST(owner_rules_a_deliberate_setter_is_adopted_and_pushed)
{
	Decider d;
	d.copy = d.baseline = medkit(65535, 3);
	Owner o;
	o.copy = medkit(65535, 3);
	d.setter(owner::Setter::Uses, 2); // combat heal: one dose off the player's medkit
	CHECK_EQ(int(d.baseline.uses), 2);
	CHECK_EQ(d.latest.get(itemtags::Uses), std::uint16_t(1));
	CHECK_EQ(d.latest.get(itemtags::Cond), std::uint16_t(0)); // only the written field moves on
	CHECK_EQ(d.pushes.size(), size_t(1));
	CHECK_EQ(d.pushes[0], std::uint32_t(itemtags::Uses));
	CHECK(!d.enforce()); // the baseline is the decider's write: nothing to undo
	CHECK_EQ(o.take(d, d.pushes[0]), std::uint32_t(itemtags::Uses));
	CHECK_EQ(int(o.copy.uses), 2);
	CHECK(o.applied == d.latest);
}

TEST(owner_rules_firing_wear_is_reverted)
{
	Decider d;
	Item gun;
	gun.has_cond = true;
	gun.cond = 60000;
	gun.has_main = true;
	gun.main_count = 30;
	d.copy = d.baseline = gun;
	d.copy.cond = 59000; // the avatar fires for show: the engine wears the decider's copy, no setter ran
	CHECK(d.enforce());
	CHECK_EQ(int(d.copy.cond), 60000);
	CHECK(d.pushes.empty());
	CHECK_EQ(d.latest.get(itemtags::Cond), std::uint16_t(0));
}

TEST(owner_rules_the_apply_of_the_owner_state_is_no_deliberate_write)
{
	CHECK(owner::deliberate(true, true, false));
	CHECK(!owner::deliberate(true, true, true)); // a callback inside the apply of his report
	CHECK(!owner::deliberate(false, true, false)); // not the decider: a mirror's setter is its own business
	CHECK(!owner::deliberate(true, false, false)); // the decider's own item or a world item: no owner to push to
	Decider d;
	d.copy = d.baseline = medkit(65535, 3);
	d.setter(owner::Setter::Condition, 1000, /*applying_owner_state*/ true);
	CHECK(d.pushes.empty());
	CHECK_EQ(int(d.baseline.cond), 65535);
	CHECK(d.enforce()); // and it is undone like any drift
}

TEST(owner_rules_a_stale_owner_field_is_refused_while_his_newer_field_is_kept)
{
	Decider d;
	d.copy = d.baseline = medkit(65535, 3);
	Owner o;
	o.copy = medkit(65535, 3);
	d.setter(owner::Setter::Condition, 30000); // the decider's write of the condition, version 1 of it
	// The owner's report made before the push came: his uses changed (his own dose, on the latest version of the uses), his
	// condition still says 65535 (made on version 0: stale).
	Item report = o.copy;
	report.uses = 2;
	o.copy.uses = 2;
	const std::uint32_t refused = d.report(report, o.applied);
	CHECK_EQ(refused, std::uint32_t(itemtags::Cond));
	CHECK(!d.last_rebased);
	CHECK_EQ(int(d.baseline.cond), 30000); // the write is not undone
	CHECK_EQ(int(d.copy.cond), 30000);
	CHECK_EQ(int(d.baseline.uses), 2); // his own dose is taken
	CHECK_EQ(int(d.copy.uses), 2);
	// The push (then the push of the refused field) reach him; his uses stay his.
	CHECK_EQ(o.take(d.sent[0]), std::uint32_t(itemtags::Cond));
	CHECK_EQ(int(o.copy.cond), 30000);
	CHECK_EQ(int(o.copy.uses), 2);
	CHECK_EQ(o.take(d.sent.back()), 0u); // the re-push of a version he has applied changes nothing
	// He eats one more dose on the latest versions: his eating is never lost.
	o.copy.uses = 1;
	CHECK_EQ(d.report(o.copy, o.applied), 0u);
	CHECK_EQ(int(d.baseline.uses), 1);
	CHECK(!d.enforce());
}

TEST(owner_rules_g4_f1_fdda_debit_is_not_undone_by_a_lost_answer)
{
	// gap-g4 F1: the decider commits a battery extraction (set_condition on the device to c_zero). The Lua answer is lost; the
	// engine's push still makes it the device's state at both ends, and enforce keeps it there.
	Decider d;
	Item device;
	device.has_cond = true;
	device.cond = 26214; // 0.4
	d.copy = d.baseline = device;
	Owner o;
	o.copy = device;
	d.setter(owner::Setter::Condition, 7); // c_zero
	for (int i = 0; i < 4; ++i)
		CHECK(!d.enforce()); // before: every 500 ms back to 0.4
	CHECK_EQ(int(d.copy.cond), 7);
	// His periodic report from before the push (0.4 on version 0) is stale.
	CHECK_EQ(d.report(o.copy, o.applied), std::uint32_t(itemtags::Cond));
	CHECK_EQ(int(d.copy.cond), 7); // a second press sees 0.0001: check() refuses the second extraction
	CHECK_EQ(o.take(d, itemtags::Cond), std::uint32_t(itemtags::Cond));
	CHECK_EQ(int(o.copy.cond), 7);
}

TEST(owner_rules_g4_f3_heal_dose_stays_spent_without_the_receipt)
{
	Decider d;
	d.copy = d.baseline = medkit(65535, 2);
	Owner o;
	o.copy = medkit(65535, 2);
	d.setter(owner::Setter::Uses, 1); // complete_heal: uses - 1; the receipt never arrives
	CHECK(!d.enforce());
	// His report still says 2, made before the debit: rebased over it (2 - 1), never taken as 2.
	CHECK_EQ(d.report(o.copy, o.applied), 0u);
	CHECK(d.last_rebased);
	CHECK_EQ(int(d.copy.uses), 1);
	CHECK_EQ(int(d.baseline.uses), 1);
	CHECK_EQ(o.take(d.sent[0]), std::uint32_t(itemtags::Uses));
	CHECK_EQ(int(o.copy.uses), 1);
}

TEST(owner_rules_a12_versions_travel_with_the_item_to_a_new_decider)
{
	Decider a;
	a.copy = a.baseline = medkit(65535, 5);
	Owner o;
	o.copy = medkit(65535, 5);
	a.setter(owner::Setter::Uses, 4);
	a.setter(owner::Setter::Uses, 3);
	a.setter(owner::Setter::Uses, 2);
	o.take(a, itemtags::Uses);
	CHECK_EQ(o.applied.get(itemtags::Uses), std::uint16_t(3));
	// The item moves to decider b (a level move, a map server restart): its state and its versions travel.
	Decider b;
	b.copy = b.baseline = a.baseline;
	owner::arrive(b.latest, a.latest, owner::versions_mask(a.latest));
	CHECK(b.latest == a.latest);
	o.copy.uses = 1; // he eats on the latest version
	CHECK_EQ(b.report(o.copy, o.applied), 0u);
	CHECK_EQ(int(b.baseline.uses), 1);
	// A stale report (version 2: from before the last debit) is refused at b too.
	itemtags::FieldVersions old;
	old.set(itemtags::Uses, 2);
	Item stale = o.copy;
	stale.uses = 3;
	CHECK_EQ(b.report(stale, old), std::uint32_t(itemtags::Uses));
	CHECK_EQ(int(b.baseline.uses), 1);
}

TEST(owner_rules_a12_without_the_versions_the_new_decider_refuses_and_heals)
{
	// Why A12 is needed: a decider that did not get the versions refuses every versioned field of the owner, and its push of
	// the refused field brings the owner back to its versions (the decider's state wins: no restored debit).
	Decider a;
	a.copy = a.baseline = medkit(65535, 3);
	Owner o;
	o.copy = medkit(65535, 3);
	a.setter(owner::Setter::Uses, 2);
	o.take(a, itemtags::Uses);
	Decider b; // versions all 0
	b.copy = b.baseline = a.baseline;
	o.copy.uses = 1;
	CHECK_EQ(b.report(o.copy, o.applied), std::uint32_t(itemtags::Uses));
	CHECK_EQ(int(b.baseline.uses), 2);
	CHECK_EQ(o.take(b, itemtags::Uses), std::uint32_t(itemtags::Uses));
	CHECK_EQ(o.applied.get(itemtags::Uses), std::uint16_t(0));
	CHECK_EQ(b.report(o.copy, o.applied), 0u); // from now on his reports count
}

TEST(owner_rules_untouched_items_behave_as_before)
{
	// No deliberate write: every version is 0, every report field is fresh, nothing rides the wire.
	itemtags::FieldVersions latest, report;
	CHECK_EQ(owner::report_takes(latest, report, itemtags::kAll), itemtags::kAll);
	CHECK_EQ(owner::report_refuses(latest, report, itemtags::kAll), 0u);
	CHECK_EQ(owner::versions_mask(latest), 0u);
	CHECK_EQ(owner::push_applies(latest, report, itemtags::kAll), 0u);
}

TEST(owner_rules_versions_are_compared_not_ordered_across_the_wrap)
{
	itemtags::FieldVersions latest, report;
	latest.set(itemtags::Cond, 0xFFFFu);
	itemtags::bump(latest, itemtags::Cond);
	CHECK_EQ(latest.get(itemtags::Cond), std::uint16_t(1)); // 0 stays "never written"
	report.set(itemtags::Cond, 0xFFFFu);
	CHECK_EQ(owner::report_takes(latest, report, itemtags::Cond), 0u);
	report.set(itemtags::Cond, 1);
	CHECK_EQ(owner::report_takes(latest, report, itemtags::Cond), std::uint32_t(itemtags::Cond));
	CHECK_EQ(owner::versions_mask(latest), std::uint32_t(itemtags::Cond));
	CHECK_EQ(owner::tags_of(owner::Setter::Condition), std::uint32_t(itemtags::Cond));
	CHECK_EQ(owner::tags_of(owner::Setter::Uses), std::uint32_t(itemtags::Uses));
}

// ---------------------------------------------------------------- WP6 fix round: the uses are a counter (finding 4)

TEST(owner_rules_a_concurrent_debit_and_eat_end_at_one_on_both_sides)
{
	// verify probe1: a 3-dose medkit; the decider's combat heal (3 -> 2, version 1) is in flight when the player eats one dose
	// himself (3 -> 2, his report on version 0). Two doses spent from 3: both sides must end at 1 (before: 2 at both ends).
	Decider d;
	d.copy = d.baseline = medkit(65535, 3);
	Owner o;
	o.copy = medkit(65535, 3);
	d.setter(owner::Setter::Uses, 2);
	const Push heal = d.sent.back();
	CHECK(heal.has_delta && heal.delta == -1);
	o.copy.uses = 2; // his own dose, before the push arrives
	CHECK_EQ(d.report(o.copy, o.applied), 0u); // stale uses: rebased (2 - 1), not refused
	CHECK(d.last_rebased);
	CHECK_EQ(int(d.baseline.uses), 1);
	CHECK_EQ(int(d.copy.uses), 1);
	CHECK_EQ(d.pushes.size(), size_t(2)); // the rebased uses go back too, behind the heal's own push
	CHECK_EQ(o.take(heal), std::uint32_t(itemtags::Uses));
	CHECK_EQ(int(o.copy.uses), 1); // the heal's change onto his own value
	CHECK_EQ(o.take(d.sent.back()), 0u); // the push behind it is a repeat of the version he has now
	CHECK_EQ(d.report(o.copy, o.applied), 0u); // his next report is on the latest version and agrees
	CHECK(!d.last_rebased);
	CHECK_EQ(int(d.baseline.uses), 1);
	CHECK(!d.enforce());
}

TEST(owner_rules_two_doses_eaten_inside_the_round_trip_both_stay_spent)
{
	Decider d;
	d.copy = d.baseline = medkit(65535, 3);
	Owner o;
	o.copy = medkit(65535, 3);
	d.setter(owner::Setter::Uses, 2); // a heal: 3 -> 2, version 1
	const Push heal = d.sent.back();
	o.copy.uses = 2;
	CHECK_EQ(d.report(o.copy, o.applied), 0u); // two scans, two reports on version 0
	o.copy.uses = 1;
	CHECK_EQ(d.report(o.copy, o.applied), 0u);
	CHECK_EQ(int(d.baseline.uses), 0); // 3 - 1 heal - 2 eaten
	o.take(heal);
	CHECK_EQ(int(o.copy.uses), 0);
	CHECK_EQ(d.report(o.copy, o.applied), 0u);
	CHECK_EQ(int(d.baseline.uses), 0);
}

TEST(owner_rules_two_debits_and_a_dose_inside_the_round_trip)
{
	Decider d;
	d.copy = d.baseline = medkit(65535, 4);
	Owner o;
	o.copy = medkit(65535, 4);
	d.setter(owner::Setter::Uses, 3); // version 1
	d.setter(owner::Setter::Uses, 2); // version 2
	const Push first = d.sent[0];
	const Push second = d.sent[1];
	o.copy.uses = 3; // he eats one before either push
	CHECK_EQ(d.report(o.copy, o.applied), 0u); // rebased over both changes: 3 - 1 - 1
	CHECK_EQ(int(d.baseline.uses), 1);
	o.take(first);
	CHECK_EQ(int(o.copy.uses), 2);
	o.copy.uses = 1; // and one more between the two pushes: his report on version 1
	CHECK_EQ(d.report(o.copy, o.applied), 0u); // rebased over version 2 only
	CHECK_EQ(int(d.baseline.uses), 0);
	o.take(second);
	CHECK_EQ(int(o.copy.uses), 0); // 4 - 2 debits - 2 eaten
	CHECK_EQ(d.report(o.copy, o.applied), 0u);
	CHECK_EQ(int(d.baseline.uses), 0);
}

TEST(owner_rules_a_rebase_never_goes_below_zero_or_over_the_most)
{
	Decider d;
	d.max_uses = 3;
	d.copy = d.baseline = medkit(65535, 1);
	Owner o;
	o.copy = medkit(65535, 1);
	d.setter(owner::Setter::Uses, 0); // the last dose taken by a heal
	o.copy.uses = 0; // and eaten by him at once
	CHECK_EQ(d.report(o.copy, o.applied), 0u);
	CHECK_EQ(int(d.baseline.uses), 0);
	o.take(d.sent.back());
	CHECK_EQ(int(o.copy.uses), 0);
	CHECK_EQ(owner::clamp_counter(7, 3), 3);
	CHECK_EQ(owner::clamp_counter(-2, 3), 0);
}

TEST(owner_rules_a_uses_change_unknown_to_the_history_is_refused_as_stale)
{
	// Older than the history holds, or another decider's numbering: no rebase, the field is refused and pushed back (the decider's
	// value wins, as before).
	owner::CounterHistory h;
	for (std::uint16_t v = 1; v <= std::uint16_t(owner::kCounterHistory + 2); ++v)
		h.record(v, -1);
	int out = 0;
	const std::uint16_t latest = std::uint16_t(owner::kCounterHistory + 2);
	CHECK(owner::rebase_counter(h, std::uint16_t(latest - owner::kCounterHistory), latest, 9, 255, out));
	CHECK_EQ(out, 9 - int(owner::kCounterHistory));
	CHECK(!owner::rebase_counter(h, 1, latest, 9, 255, out)); // version 2 fell out of the history
	CHECK(!owner::rebase_counter(owner::CounterHistory(), 0, 1, 3, 255, out)); // no history at all
	CHECK(owner::rebase_counter(owner::CounterHistory(), 4, 4, 3, 255, out) && out == 3); // made on the latest: as reported
	int d = 0;
	CHECK(!h.delta_of(0, d)); // version 0 is no write
	itemtags::FieldVersions latest_v, report_v;
	latest_v.set(itemtags::Uses, 5);
	report_v.set(itemtags::Uses, 2);
	const owner::ReportVerdict v = owner::judge_report(latest_v, report_v, itemtags::Uses, owner::CounterHistory(), 3, 255);
	CHECK_EQ(v.refused, std::uint32_t(itemtags::Uses));
	CHECK(!v.rebased);
}

TEST(owner_rules_the_owner_takes_a_push_as_a_change_only_after_the_version_before_it)
{
	// The next version with its change: onto his own value.
	CHECK_EQ(owner::owner_takes_uses(3, 4, true, -1, 7, true, 5, 9), 4);
	// A version further on (pushes arrive in order, so this is another decider's numbering or a heal): the value.
	CHECK_EQ(owner::owner_takes_uses(3, 6, true, -1, 7, true, 5, 9), 7);
	// No change carried, no object to read his value from, or the push of version 0 (a heal after a decider change): the value.
	CHECK_EQ(owner::owner_takes_uses(3, 4, false, 0, 7, true, 5, 9), 7);
	CHECK_EQ(owner::owner_takes_uses(3, 4, true, -1, 7, false, 0, 9), 7);
	CHECK_EQ(owner::owner_takes_uses(0xFFFF, 0, true, -1, 7, true, 5, 9), 7);
	// Across the wrap: after 65535 comes 1.
	CHECK_EQ(owner::owner_takes_uses(0xFFFF, 1, true, 2, 0, true, 5, 9), 7);
	CHECK_EQ(owner::owner_takes_uses(0xFFFF, 1, true, 9, 0, true, 5, 9), 9); // clamped to the most
}

TEST(owner_rules_the_history_keeps_the_newest_changes)
{
	owner::CounterHistory h;
	h.record(1, -1);
	h.record(2, 3);
	int d = 0;
	CHECK(h.delta_of(1, d) && d == -1);
	CHECK(h.delta_of(2, d) && d == 3);
	for (std::uint16_t v = 3; v < std::uint16_t(3 + owner::kCounterHistory); ++v)
		h.record(v, 0);
	CHECK(!h.delta_of(1, d)); // the oldest go first
	CHECK(!h.delta_of(2, d));
	CHECK(h.delta_of(std::uint16_t(2 + owner::kCounterHistory), d) && d == 0);
	CHECK_EQ(int(h.used), int(owner::kCounterHistory));
	h.record(5, 40000); // a change is kept in an i16
	CHECK(h.delta_of(5, d) && d == 32767);
}

// ---------------------------------------------------------------- WP6 fix round: a late report is judged too (finding 3)

TEST(owner_rules_a_late_report_on_version_0_leaves_a_charge_debit_in_place)
{
	// gap-g4 F1 through the Late door: the decider commits an FDDA extraction (the device to c_zero, version 1); inside one round
	// trip the player stashes the device. His "left our hands" report carries the pre-debit charge on version 0.
	Decider d;
	Item device;
	device.has_cond = true;
	device.cond = 26214; // 0.4
	d.copy = d.baseline = device;
	Owner o;
	o.copy = device;
	d.setter(owner::Setter::Condition, 7);
	o.copy.cond = 26000; // it drained a little meanwhile: his blob changed, the report goes out
	const size_t pushes = d.pushes.size();
	CHECK_EQ(d.report(o.copy, o.applied, /*late*/ true), std::uint32_t(itemtags::Cond));
	CHECK_EQ(int(d.copy.cond), 7); // no second extraction
	CHECK_EQ(d.pushes.size(), pushes); // he holds it no more: nothing pushed
}

TEST(owner_rules_a_late_report_keeps_a_dose_debit_and_his_own_dose)
{
	Decider d;
	d.copy = d.baseline = medkit(65535, 3);
	Owner o;
	o.copy = medkit(65535, 3);
	d.setter(owner::Setter::Uses, 2); // a heal's dose
	o.copy.uses = 2; // his own dose, then he drops the medkit at once
	CHECK_EQ(d.report(o.copy, o.applied, /*late*/ true), 0u);
	CHECK(d.last_rebased);
	CHECK_EQ(int(d.copy.uses), 1); // both doses spent
}

// ---------------------------------------------------------------- WP6 fix round: the engine glue (finding 6)
// The model above would pass without the engine calling the rules. These read the engine sources (they cannot run here) for the
// calls that make the rules the item engine's: the setter hooks, the Applying guards, the access kinds the version check covers, the
// writer-only push, the owner's decider path, the world's upgrade list. Helpers as in test_mode_answers.cpp.
namespace
{
std::string engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	std::ifstream probe(here + "/../engine/src/xrCoop/coop_owner_rules.h");
	if (probe)
		return here + "/../engine/src";
	return here + "/../../engine/src";
}

std::string read_text(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The source with // and /* */ comments blanked (string literals kept).
std::string code_of(const std::string& src)
{
	std::string out = src;
	enum class St
	{
		Code,
		Line,
		Block,
		Str,
		Chr,
	};
	St st = St::Code;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		switch (st)
		{
		case St::Code:
			if (c == '/' && n == '/')
			{
				out[i] = out[i + 1] = ' ';
				++i;
				st = St::Line;
			}
			else if (c == '/' && n == '*')
			{
				out[i] = out[i + 1] = ' ';
				++i;
				st = St::Block;
			}
			else if (c == '"')
				st = St::Str;
			else if (c == '\'')
				st = St::Chr;
			break;
		case St::Line:
			if (c == '\n')
				st = St::Code;
			else
				out[i] = ' ';
			break;
		case St::Block:
			if (c == '*' && n == '/')
			{
				out[i] = out[i + 1] = ' ';
				++i;
				st = St::Code;
			}
			else if (c != '\n')
				out[i] = ' ';
			break;
		case St::Str:
			if (c == '\\')
				++i;
			else if (c == '"')
				st = St::Code;
			break;
		case St::Chr:
			if (c == '\\')
				++i;
			else if (c == '\'')
				st = St::Code;
			break;
		}
	}
	return out;
}

std::string collapse(const std::string& s)
{
	const std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

// The body (between its braces) of the first function whose head matches `head` (a regex ending at the name), white space
// collapsed; "" and a failure when there is none.
std::string body_of(const std::string& code, const std::string& head)
{
	std::smatch m;
	const std::regex rx(head + R"(\s*\([^;{]*\)\s*(?:const\s*)?\{)");
	if (!std::regex_search(code, m, rx))
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return "";
	}
	size_t i = size_t(m.position(0) + m.length(0));
	const size_t start = i;
	int depth = 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : collapse(code.substr(start, i - 1 - start));
}

// Where `what` (white space collapsed) is in `body`; npos and a failure naming `where` when it is not.
size_t at(const std::string& where, const std::string& body, const std::string& what)
{
	const size_t p = body.find(collapse(what));
	if (p == std::string::npos)
		t::report_failure(__FILE__, __LINE__, where + " lacks: " + what);
	return p;
}

// `first` comes before `then` in `body`.
void before(const std::string& where, const std::string& body, const std::string& first, const std::string& then)
{
	const size_t a = at(where, body, first);
	const size_t b = at(where, body, then);
	if (a != std::string::npos && b != std::string::npos && a >= b)
		t::report_failure(__FILE__, __LINE__, where + ": \"" + first + "\" must come before \"" + then + "\"");
}

size_t count_of(const std::string& text, const std::string& what)
{
	size_t n = 0;
	for (size_t p = text.find(what); p != std::string::npos; p = text.find(what, p + what.size()))
		++n;
	return n;
}

const std::string& items_code()
{
	static const std::string code = code_of(read_text(engine_src() + "/xrGame/coop/coop_items.cpp"));
	return code;
}
} // namespace

TEST(owner_glue_the_script_setters_call_decider_wrote_after_the_change)
{
	const std::string src = engine_src();
	const std::string cond =
	    body_of(code_of(read_text(src + "/xrGame/script_game_object.cpp")), R"(void\s+CScriptGameObject::SetCondition)");
	before("SetCondition", cond, "inventory_item->ChangeCondition(val);",
	    "coop::items::decider_wrote(inventory_item, coop::owner::Setter::Condition);");
	const std::string uses =
	    body_of(code_of(read_text(src + "/xrGame/script_game_object3.cpp")), R"(void\s+CScriptGameObject::SetRemainingUses)");
	before("SetRemainingUses", uses, "eItm->SetRemainingUses(value);", "coop::items::decider_wrote(IItm, coop::owner::Setter::Uses);");
}

TEST(owner_glue_the_applies_of_a_report_and_of_the_baseline_are_no_deliberate_write)
{
	const std::string& code = items_code();
	const std::string on_state = body_of(code, R"(void\s+host_on_state)");
	at("host_on_state", on_state,
	    "{ const Applying applying; if (item) apply_object(item, d, ammo_only); apply_entity(e, d, ammo_only); }");
	const std::string enforce = body_of(code, R"(void\s+host_enforce)");
	at("host_enforce", enforce, "const Applying applying; apply_object(item, it->second.data, false);");
	const std::string facts = body_of(code, R"(bool\s+host_take_item_facts)");
	at("host_take_item_facts", facts, "const Applying applying; if (item) apply_object(item, facts, false);");
	const std::string wrote = body_of(code, R"(void\s+decider_wrote)");
	before("decider_wrote", wrote, "if (g_applying > 0) return;", "itemtags::bump(latest, mask);");
}

TEST(owner_glue_the_version_check_covers_owned_and_late_reports)
{
	const std::string on_state = body_of(items_code(), R"(void\s+host_on_state)");
	before("host_on_state", on_state,
	    "if (access == Access::Owned || access == Access::Late) { const owner::ReportVerdict verdict = owner::judge_report(",
	    "{ const Applying applying;");
	at("host_on_state", on_state, "if (verdict.rebased) { d.uses = u8(verdict.uses);");
	at("host_on_state", on_state, "d = itemtags::only_tags(d, itemtags::kAll & ~refused);");
	// The push back of refused fields: only for an item he still holds, and only by the item's writer.
	const size_t owned = on_state.find("if (access == Access::Owned) {");
	const size_t push = on_state.find(
	    "const u32 push = refused | (rebased ? u32(itemtags::Uses) : 0u); if (push && writing::writes(id)) host_push_decider(id, from, push);");
	CHECK(owned != std::string::npos);
	CHECK(push != std::string::npos);
	CHECK(owned < push);
}

TEST(owner_glue_only_the_writer_pushes_and_the_owner_takes_the_decider_path)
{
	const std::string& code = items_code();
	// host_push_decider: its definition and two calls, in host_on_state (under writing::writes) and in decider_wrote.
	CHECK_EQ(count_of(code, "host_push_decider("), size_t(3));
	const std::string wrote = body_of(code, R"(void\s+decider_wrote)");
	before("decider_wrote", wrote, "if (!writing::writes(id)) return;", "host_push_decider(id, peer, mask);");
	before("decider_wrote", wrote, "if (!mode().decides_here()) return;", "host_push_decider(id, peer, mask);");
	at("decider_wrote", wrote, "g_uses_history[id].record(latest.get(itemtags::Uses), int(now.uses) - int(before.uses));");
	const std::string push = body_of(code, R"(void\s+host_push_decider)");
	at("host_push_decider", push, "uses_history_in(id).delta_of(d.versions.get(itemtags::Uses), delta)");
	at("host_push_decider", push, "write_state(w, id, e->s_name.c_str(), u8(kFlagAuthority | kFlagDecider), blob);");
	const std::string apply = body_of(code, R"(bool\s+client_apply)");
	before("client_apply", apply, "if (flags & kFlagDecider) {", "if (!(flags & kFlagAuthority)) {");
	at("client_apply", apply, "const u32 takes = owner::push_applies(applied, d.versions, carried_tags(d));");
	before("client_apply", apply, "const int taken = owner::owner_takes_uses(", "itemtags::take(applied, d.versions, takes);");
}

TEST(owner_glue_a_map_server_sale_tells_the_world)
{
	// Finding 2: the writer's installed upgrade reaches the world by its ItemFacts (no owner report follows a sale).
	const std::string& code = items_code();
	at("host_upgrade_sold", body_of(code, R"(void\s+host_upgrade_sold)"), "note_facts(id, kFactsDecider);");
	// The world takes the writer's list whatever the source: the blob is the writer's own capture.
	const std::string facts = body_of(code, R"(bool\s+host_take_item_facts)");
	CHECK(facts.find("host_keeps_own_upgrades") == std::string::npos);
	at("host_take_item_facts", facts, "if (upgrades && !item) ii->m_upgrades = facts.upgrades;");
}

TEST(owner_rules_uses_staged_before_the_owner_joined_reach_him)
{
	// Coop (finding 1): a reward's uses set by coop.items.set_initial for a kit of a player who is not in the game; its section is
	// scripted, so they wait for the object and are set when it spawns, before his join makes him its owner. His copy comes from
	// the same save (5 doses); he eats one at once. His first report (version 0) is rebased onto the staged change and pushed back.
	Decider d;
	d.copy = d.baseline = medkit(65535, 5);
	d.staged(2);
	Owner o;
	o.copy = medkit(65535, 5);
	o.copy.uses = 4;
	CHECK_EQ(d.report(o.copy, o.applied), 0u);
	CHECK(d.last_rebased);
	CHECK_EQ(int(d.baseline.uses), 1); // 2 rolled, 1 eaten
	CHECK_EQ(o.take(d.sent.back()), std::uint32_t(itemtags::Uses)); // the push of the rebased uses: the change onto his value
	CHECK_EQ(int(o.copy.uses), 1);
	CHECK_EQ(d.report(o.copy, o.applied), 0u);
	CHECK(!d.last_rebased);
	CHECK_EQ(int(d.baseline.uses), 1);
}

TEST(owner_rules_a_foreign_report_never_names_a_living_holders_thing)
{
	// Server companions_server (and the same path in Coop): a companion's kit spawned on the player's copy has its uses staged set on
	// its object the first frame it exists (apply_staged_uses touches it). Its game object has no parent yet, its server entity
	// names the companion: the report went out as "a world item he changed" and the decider refused it ("not owner").
	using owner::Holder;
	CHECK(!owner::reports_foreign(Holder::Nobody, Holder::Living)); // the companion's kit, a frame after its spawn
	CHECK(!owner::reports_foreign(Holder::Living, Holder::Living)); // an NPC's gun
	CHECK(!owner::reports_foreign(Holder::Nobody, Holder::Me)); // his own item: his scan reports it
	CHECK(!owner::reports_foreign(Holder::Me, Holder::Me));
	CHECK(owner::reports_foreign(Holder::Other, Holder::Other)); // a corpse's gun he unloaded
	CHECK(owner::reports_foreign(Holder::Nobody, Holder::Other)); // a gun in a box, its game object not taken yet
	CHECK(owner::reports_foreign(Holder::Nobody, Holder::Nobody)); // on the ground
}

TEST(owner_glue_a_foreign_report_asks_both_chains)
{
	const std::string& code = items_code();
	at("send_foreign", body_of(code, R"(void\s+send_foreign)"),
	    "if (!item || !owner::reports_foreign(holder_by_object(item, actor), holder_by_entity(id, actor))) continue;");
	const std::string entity = body_of(code, R"(owner::Holder\s+holder_by_entity)");
	at("holder_by_entity", entity, "const u16 root = entity_root(e);");
	before("holder_by_entity", entity, "if (const CObject* o = g_pGameLevel ? Level().Objects.net_Find(root) : nullptr) return holder_of(o);",
	    "smart_cast<CSE_ALifeCreatureAbstract*>(world::alife_entity(root));");
}
