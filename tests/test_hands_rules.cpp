// Anomaly Coop unit tests: what a puppet's hands show on a player's machine (xrCoop/coop_hands_rules.h, TZ R71).
// Live: an NPC at a campfire plays the guitar on the host, and a co-op player sees a pistol in its hand. Every guitar
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
using coop::hands::kHideGraceMs;
using coop::hands::kNoId;
using coop::hands::Seen;

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

// The b21 "beer" fix stays: the rifle the host straps is the puppet's active item, so the planner's world says strapped
// (the strapping animation's end never comes on a puppet) and weapon_bones puts it on the back.
TEST(npc_hands_the_held_strappable_rifle_in_hands_goes_on_the_back)
{
	const Decision d = decide(seen(true, true, kRifle, kRifle, false, true, 0, true));
	CHECK(d.strap);
	CHECK(!d.put_away);
	CHECK(d.done);
}

// R71 A: the global Strapped property must not be forced while another item is still active: Hide needs it false.
TEST(npc_hands_r71a_a_pistol_in_hands_while_the_host_straps_a_rifle_is_not_strapped)
{
	const Decision d = decide(seen(true, true, kRifle, kPistol, false, false, 0, true));
	CHECK(!d.strap);
	CHECK(!d.put_away); // the planner swaps it first: hide the pistol, show the rifle
	CHECK(!d.done);
}

TEST(npc_hands_r71a_another_strappable_weapon_in_hands_is_not_strapped_either)
{
	const Decision d = decide(seen(true, true, kRifle, kOtherRifle, false, true, 0, true));
	CHECK(!d.strap);
	CHECK(!d.done);
}

TEST(npc_hands_r71a_a_hidden_pistol_still_active_is_not_strapped)
{
	const Decision d = decide(seen(true, true, kRifle, kPistol, true, false, 60000, true));
	CHECK(!d.strap);
	CHECK(!d.put_away); // already hidden: nothing to push
	CHECK(!d.done);
}

// R71 A has the same safety net as B: the wrong item still seen a grace later is put away (the host holds another one,
// so this does not fight it; the planner then shows the held item).
TEST(npc_hands_r71a_a_pistol_still_seen_past_the_grace_while_the_host_holds_a_rifle_is_put_away)
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

// R71 B: the host's hands are empty (a pistol is hidden at the guitar); the puppet's planner hides its pistol itself.
TEST(npc_hands_r71b_no_holds_and_a_pistol_just_seen_waits_for_the_planners_hide)
{
	Decision d = decide(seen(false, false, kNoId, kPistol, false, false, 0));
	CHECK(!d.put_away);
	CHECK(!d.done);
	CHECK(!d.strap);
	d = decide(seen(false, false, kNoId, kPistol, false, false, kHideGraceMs - 1));
	CHECK(!d.put_away);
	CHECK(!d.done);
}

TEST(npc_hands_r71b_no_holds_and_a_pistol_visible_past_the_grace_is_put_away)
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
	CHECK(early.find("track.waiting = false") != std::string::npos);
	CHECK(src.find("track.hands.retry_soon ? 100 : 1000") != std::string::npos);
}
