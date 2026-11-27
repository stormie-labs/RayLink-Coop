// Anomaly Coop unit tests: the world's acceptance of a map server's journal (TZ Р32, temp/r30/design/R32-final.md §1 W2b, W3,
// §6 test_levels_accept.cpp; R32-addendum-gaps2.md P1): xrCoop/srv/coop_levels_accept.h over the writer rule of
// xrCoop/coop_writer_rules.h, the way srv/coop_levels_alife.cpp host_apply_fact fills it on the world server.
//
// Server mode only (the world server and its map servers); the co-op has no map servers and no journal.
#include "test_util.h"
#include "coop_writer_rules.h"
#include "srv/coop_levels_accept.h"

#include <cstdint>
#include <string>

namespace w = coop::writer;
namespace acc = coop::levels::accept;
namespace jr = coop::levels::journal;
using H = coop::levels::wire::LevelEntityHead;

namespace
{
constexpr uint16_t kA = 5; // led by the map server behind kBridgeA
constexpr uint16_t kB = 7; // led by the map server behind kBridgeB
constexpr uint16_t kU = 11; // no server leads it
constexpr coop::PeerId kBridgeA = 101, kBridgeB = 102;

const w::Process kWS{w::ProcessKind::World, w::kNoLevel, coop::kHostPeer};
const w::MapLead kLedA{w::Lead::Leads, kBridgeA};
const w::MapLead kStoppingA{w::Lead::Stopping, kBridgeA};
const w::MapLead kLedB{w::Lead::Leads, kBridgeB};
const w::MapLead kUnled{w::Lead::None, coop::kInvalidPeer};

// The world server's writer of a root, as world_writer_of (srv/coop_srv_mode.cpp) fills the seat.
w::Writer resident(uint16_t id, uint16_t level, w::MapLead lead)
{
	w::Seat s;
	s.map = lead;
	return w::writer_of(w::RootFacts{w::RootKind::Resident, id, level}, kWS, s);
}

w::Writer unit_held_by(uint16_t id, coop::PeerId bridge, uint16_t level)
{
	w::Seat s;
	s.hold = w::Hold::Held;
	s.holder = bridge;
	s.holder_level = level;
	return w::writer_of(w::RootFacts{w::RootKind::Unit, id, level}, kWS, s);
}

w::Writer unit_home(uint16_t id, uint16_t level)
{
	return w::writer_of(w::RootFacts{w::RootKind::Unit, id, level}, kWS, w::Seat{});
}

// A player's character standing on `level`; `from`: the map he left while his move fence is open.
w::Writer character(uint16_t id, uint16_t level, w::MapLead lead, uint16_t from = w::kNoLevel, w::MapLead from_lead = w::MapLead{})
{
	w::Seat s;
	s.map = lead;
	s.from = from;
	s.from_map = from_lead;
	return w::writer_of(w::RootFacts{w::RootKind::Character, id, level}, kWS, s);
}

// An entry from map server A (level kA) about an object the world has, same identity, no fence.
acc::Facts from_a(uint8_t op, w::Writer writer)
{
	acc::Facts f;
	f.op = op;
	f.sender = kBridgeA;
	f.sender_level = kA;
	f.epoch = 7;
	f.exists = true;
	f.same = true;
	f.writer = writer;
	return f;
}

bool refused_for(const acc::Verdict& v, jr::Why why) { return !v.ok && v.why == uint8_t(why); }
} // namespace

TEST(accept_kinds_of_every_journal_op)
{
	for (uint8_t op : {H::Destroy, H::Parent, H::Died, H::State, H::Item, H::Spawn, H::Tent, H::Stash, H::Logic, H::Joined, H::Left,
	         H::Info})
		CHECK(acc::kind_of(op) == acc::Kind::Fact);
	CHECK(acc::kind_of(H::Ask) == acc::Kind::Ask);
	for (uint8_t op : {H::Money, H::IdAsk, H::Carry, H::Done, H::Flushed})
		CHECK(acc::kind_of(op) == acc::Kind::Own);
	// every op a journal carries has a kind; the journal's own pass the acceptance (their own rules decide them)
	for (uint8_t op = 0; op <= jr::kLastOp; ++op)
		if (jr::known_op(op) && acc::kind_of(op) == acc::Kind::Own)
		{
			acc::Facts f;
			f.op = op;
			CHECK(acc::accepts(f).ok);
		}
}

// D1, G3, cleanup M2: the holder's release of a member of a squad it holds is applied (the root is the squad, the writer its holder).
TEST(accept_holder_destroy_of_held_member)
{
	const acc::Facts f = from_a(H::Destroy, unit_held_by(900, kBridgeA, kA));
	CHECK(acc::accepts(f).ok);
	// another map server's squad, a squad at home: not A's to release
	CHECK(refused_for(acc::accepts(from_a(H::Destroy, unit_held_by(900, kBridgeB, kB))), jr::NotWriter));
	CHECK(refused_for(acc::accepts(from_a(H::Destroy, unit_home(900, kA))), jr::NotWriter));
}

// A ground item, a box, a body on A's own map: A writes them while it leads or stops (§8a A4); on an unled map the world does.
TEST(accept_resident_by_the_lead_of_its_map)
{
	CHECK(acc::accepts(from_a(H::Destroy, resident(300, kA, kLedA))).ok);
	CHECK(acc::accepts(from_a(H::Destroy, resident(300, kA, kStoppingA))).ok);
	CHECK(refused_for(acc::accepts(from_a(H::Destroy, resident(300, kB, kLedB))), jr::NotWriter));
	CHECK(refused_for(acc::accepts(from_a(H::Destroy, resident(300, kU, kUnled))), jr::NotWriter));
}

// cleanup M3: a death of another object under a reused id (its section differs) is refused, as any fact of another object.
TEST(accept_died_of_another_object_refused)
{
	acc::Facts f = from_a(H::Died, unit_held_by(900, kBridgeA, kA));
	f.same = acc::identity(0x1111, 0x2222, 0, 0, 0);
	CHECK(refused_for(acc::accepts(f), jr::Identity));
	f.same = acc::identity(0x1111, 0x1111, 0, 0, 0);
	CHECK(acc::accepts(f).ok);
}

// A unit granted again since: the old grant's gen is another object.
TEST(accept_identity_by_keeper_generation)
{
	CHECK(acc::identity(0x10, 0x10, 5, 5, 0));
	CHECK(!acc::identity(0x10, 0x10, 6, 5, 0)); // granted again since
	CHECK(!acc::identity(0x10, 0x10, 5, 0, 0)); // gen 0 for a unit that is no spawn of the sender
	// its own spawn, named before the world's Ack reached it, and not moved since
	CHECK(acc::identity(0x10, 0x10, 9, 0, 9));
	CHECK(!acc::identity(0x10, 0x10, 12, 0, 9)); // it moved since its spawn: the gen-0 word is stale
	CHECK(!acc::identity(0x10, 0x11, 9, 0, 9)); // another section all the same
}

// W4: the old writer's facts after its fence are refused, whatever the writer rule says.
TEST(accept_entry_past_the_fence_refused)
{
	acc::Facts f = from_a(H::Destroy, resident(300, kA, kLedA));
	f.fence = 10;
	f.epoch = 10;
	CHECK(acc::accepts(f).ok);
	f.epoch = 11;
	CHECK(refused_for(acc::accepts(f), jr::PastFence));
	f.op = H::Ask;
	f.writer = w::this_process();
	f.root_level = kA;
	CHECK(refused_for(acc::accepts(f), jr::PastFence));
}

// gap-mk F1: a level's logic asks the world to release a world record of that level (xcv's phantoms that went home).
TEST(accept_ask_on_its_own_map_only)
{
	acc::Facts f = from_a(H::Ask, w::this_process());
	f.root_level = kA;
	CHECK(acc::accepts(f).ok);
	f.root_level = kB;
	CHECK(refused_for(acc::accepts(f), jr::NotOwnLevel));
	f.root_level = w::kNoLevel; // an object of no map: money, story, records
	CHECK(refused_for(acc::accepts(f), jr::NotOwnLevel));
	// a map server's object is asked of that map server, not of the world
	f.root_level = kA;
	f.writer = w::other(kBridgeA);
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	f.writer = w::this_process();
	f.same = false;
	CHECK(refused_for(acc::accepts(f), jr::Identity));
	f.same = true;
	f.exists = false;
	CHECK(refused_for(acc::accepts(f), jr::Unknown));
	// a map server that leads no map has no map to ask about
	f.exists = true;
	f.sender_level = w::kNoLevel;
	f.root_level = w::kNoLevel;
	CHECK(refused_for(acc::accepts(f), jr::NotOwnLevel));
}

// F1 (role-guards): a map server's spawn under a root it does not write; its id slice; a repeat.
TEST(accept_spawn_root_slice_and_repeat)
{
	acc::Facts f = from_a(H::Spawn, w::other(kBridgeA));
	f.exists = false;
	f.id_in_slice = true;
	CHECK(acc::accepts(f).ok);
	// into the inventory of a squad another map server holds, into a box of another map
	f.writer = unit_held_by(900, kBridgeB, kB);
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	f.writer = resident(301, kB, kLedB);
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	// under an id of another slice
	f.writer = w::other(kBridgeA);
	f.id_in_slice = false;
	CHECK(refused_for(acc::accepts(f), jr::IdRange));
	// the world has it: the same object is a repeat (taken, nothing changes), another object under that id is refused
	f.id_in_slice = true;
	f.exists = true;
	f.same = true;
	const acc::Verdict again = acc::accepts(f);
	CHECK(again.ok && again.repeat);
	f.same = false;
	CHECK(refused_for(acc::accepts(f), jr::IdRange));
	// nothing is made under the ghost
	f.exists = false;
	f.ghost = true;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
}

TEST(accept_spawn_stands_on_the_senders_map)
{
	CHECK(acc::spawn_on_senders_map(kA, kA));
	CHECK(acc::spawn_on_senders_map(w::kNoLevel, kA)); // a unit born at no vertex yet
	CHECK(!acc::spawn_on_senders_map(kB, kA));
	CHECK(!acc::spawn_on_senders_map(kA, w::kNoLevel)); // no map of its own: nothing is its to make
}

// A Parent changes two roots: both must be the sender's (an item taken from A's box into a squad B holds is not A's alone).
TEST(accept_parent_needs_both_roots)
{
	acc::Facts f = from_a(H::Parent, resident(300, kA, kLedA)); // from a box on A
	f.two_roots = true;
	f.writer_new = unit_held_by(900, kBridgeA, kA); // into an NPC of a squad A holds
	CHECK(acc::accepts(f).ok);
	f.writer_new = unit_held_by(901, kBridgeB, kB);
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	f.writer_new = w::other(kBridgeA); // put down on A's map
	f.writer = unit_home(902, kA); // out of a squad at home in the world
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
}

// P1: a placement (tent, furniture, campfire) is the object's Spawn plus the item's Destroy; the Destroy may come after the player's
// move. While his move fence is open the map he left still writes him and his items: its Destroy is taken. After the fence the new
// map writes him: the old map's word is refused, and an entry after its Flushed is past the fence.
TEST(accept_p1_item_destroy_after_the_players_move)
{
	// he stands on B now, A is behind his open move fence
	const w::Writer during = character(2001, kB, kLedB, kA, kLedA);
	CHECK(during == w::other(kBridgeA));
	acc::Facts item = from_a(H::Destroy, during); // the item's root is his character
	CHECK(acc::accepts(item).ok);
	// the placed object itself: a resident of A, A's to make
	acc::Facts tent = from_a(H::Spawn, w::other(kBridgeA));
	tent.exists = false;
	tent.id_in_slice = true;
	CHECK(acc::accepts(tent).ok);
	// the fence is through: B writes him
	item.writer = character(2001, kB, kLedB);
	CHECK(refused_for(acc::accepts(item), jr::NotWriter));
	// A's entry came after its Flushed for that move
	item.writer = during;
	item.fence = 6;
	CHECK(refused_for(acc::accepts(item), jr::PastFence));
	// A stopping still writes until its Stopped (§8a A4)
	item.fence = w::kNoFence;
	item.writer = character(2001, kB, kLedB, kA, kStoppingA);
	CHECK(acc::accepts(item).ok);
}

// world-view D3: a member joins a squad: the creature's old root and the squad both are the sender's; a Left needs the squad.
TEST(accept_joined_and_left)
{
	acc::Facts f = from_a(H::Joined, unit_held_by(950, kBridgeA, kA)); // a lone creature A holds
	f.two_roots = true;
	f.writer_new = unit_held_by(900, kBridgeA, kA);
	CHECK(acc::accepts(f).ok);
	f.writer = unit_home(950, kA); // a creature at home in the world
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	acc::Facts left = from_a(H::Left, unit_held_by(900, kBridgeA, kA));
	CHECK(acc::accepts(left).ok);
	left.writer = unit_held_by(900, kBridgeB, kB);
	CHECK(refused_for(acc::accepts(left), jr::NotWriter));
	left.exists = false;
	CHECK(refused_for(acc::accepts(left), jr::Unknown));
}

// W1.5: the ghost (actor 0 where the actor plays nobody) is nobody's: no fact about it is taken.
TEST(accept_nothing_of_the_ghost)
{
	acc::Facts f = from_a(H::Info, w::nobody());
	f.ghost = true;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
	f.op = H::Destroy;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
	f.op = H::Ask;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
}

// The reasons come in one order: no object, the ghost, another object, then who writes it.
TEST(accept_reasons_in_order)
{
	acc::Facts f = from_a(H::State, character(2001, kB, kLedB));
	f.exists = false;
	f.same = false;
	CHECK(refused_for(acc::accepts(f), jr::Unknown));
	f.exists = true;
	CHECK(refused_for(acc::accepts(f), jr::Identity));
	f.same = true;
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	f.writer = character(2001, kA, kLedA);
	CHECK(acc::accepts(f).ok);
	// every reason has a name for the log and is a reason the Ack may carry
	for (uint8_t why = 1; why <= jr::kLastWhy; ++why)
		CHECK(jr::why_name(why)[0] != '?');
}

// ---------------------------------------------------------------- R32 fix package A (levels)

namespace
{
// A root-less Spawn from map server A (level kA) as host_apply_fact fills it: the world's writer of the residents of the map the
// object stands on (of A's own map for one at no vertex) and whether A writes its own map's residents now.
acc::Facts rootless_from_a(uint16_t at, w::MapLead lead_of_a)
{
	acc::Facts f = from_a(H::Spawn, w::nobody());
	f.exists = false;
	f.id_in_slice = true;
	f.rootless = true;
	f.spawn_level = at;
	const w::Writer of_a = resident(0x9001, kA, lead_of_a);
	f.sender_leads = of_a == w::other(kBridgeA);
	f.writer = acc::spawn_on_senders_map(at, kA) ? of_a : resident(0x9001, at, at == kB ? kLedB : kUnled);
	return f;
}
} // namespace

// Fix A2 (W1.2c, §8a A4): a root-less Spawn on the sender's map, or of a unit it bore at no vertex, is the sender's only while it
// leads its map or stops: a map server still Starting (in session, Ready not said) writes no resident of it yet.
TEST(accept_fixa_rootless_spawn_needs_the_lead)
{
	const w::MapLead starting{w::Lead::Starting, kBridgeA};
	for (const uint16_t at : {kA, w::kNoLevel})
	{
		CHECK(refused_for(acc::accepts(rootless_from_a(at, starting)), jr::NotWriter));
		CHECK(acc::accepts(rootless_from_a(at, kLedA)).ok);
		CHECK(acc::accepts(rootless_from_a(at, kStoppingA)).ok);
		CHECK(refused_for(acc::accepts(rootless_from_a(at, kUnled)), jr::NotWriter)); // its server is Off or Lost here
	}
	// another map is never the sender's, whatever it leads
	CHECK(refused_for(acc::accepts(rootless_from_a(kB, kLedA)), jr::NotWriter));
	CHECK(refused_for(acc::accepts(rootless_from_a(kU, kLedA)), jr::NotWriter));
	// a bridge that leads no map makes nothing that stands nowhere: the world writes what stands on no map (host_apply_fact asks
	// writer_of for a resident of no level), whatever its lead flag says
	acc::Facts nowhere = rootless_from_a(w::kNoLevel, kLedA);
	nowhere.sender_level = w::kNoLevel;
	nowhere.writer = resident(0x9001, w::kNoLevel, kUnled);
	CHECK(nowhere.sender_leads);
	CHECK(refused_for(acc::accepts(nowhere), jr::NotWriter));
	// the rule before the fix: "on its map, so its own" took a Starting server's create
	acc::Facts before = rootless_from_a(kA, starting);
	before.rootless = false;
	before.writer = w::other(kBridgeA);
	CHECK(acc::accepts(before).ok);
	CHECK(!acc::accepts(rootless_from_a(kA, starting)).ok);
}

// Fix A2: the writer the rule names for a root-less Spawn.
TEST(accept_fixa_rootless_spawn_writer)
{
	CHECK(acc::rootless_spawn_writer(rootless_from_a(kA, kLedA)) == w::other(kBridgeA));
	CHECK(acc::rootless_spawn_writer(rootless_from_a(w::kNoLevel, kStoppingA)) == w::other(kBridgeA));
	CHECK(acc::rootless_spawn_writer(rootless_from_a(kA, w::MapLead{w::Lead::Starting, kBridgeA})) == w::this_process());
	CHECK(acc::rootless_spawn_writer(rootless_from_a(kB, kLedA)) == w::other(kBridgeB));
}

// Fix A5: release_here's decision (srv/coop_levels_alife.cpp): a player's character or the ghost never; an object online elsewhere
// only as a member of a squad here, at its own vertex or its squad's, after its online mark is cleared; anything else as it is.
TEST(accept_fixa_release_plan)
{
	acc::ReleaseFacts f;
	f.player = true;
	f.online = true;
	f.member = true;
	f.own_vertex = true;
	acc::ReleasePlan p = acc::release_plan(f);
	CHECK(!p.release);
	CHECK(p.why != nullptr && std::string(p.why) == "a player's character");
	f.player = false;
	f.online = false;
	f.member = false;
	f.own_vertex = false; // offline here: the stock release, wherever it stands
	p = acc::release_plan(f);
	CHECK(p.release && !p.clear_online && !p.take_squad_vertex && p.why == nullptr);
	f.online = true; // a held unit itself: its holder's Destroy on the transfer lane releases it
	p = acc::release_plan(f);
	CHECK(!p.release);
	CHECK(p.why != nullptr && std::string(p.why) == "online elsewhere, not a member");
	f.member = true; // a held squad's member at no vertex, its squad at none either
	p = acc::release_plan(f);
	CHECK(!p.release);
	CHECK(p.why != nullptr && std::string(p.why) == "a member at no vertex");
	f.squad_vertex = true; // ... its squad at one: it is released there
	p = acc::release_plan(f);
	CHECK(p.release && p.take_squad_vertex && p.clear_online);
	f.own_vertex = true; // at its own vertex: that one stays
	p = acc::release_plan(f);
	CHECK(p.release && !p.take_squad_vertex && p.clear_online);
}

// Fix round 2 of package A (verifier findings 2 and 4): what the world does with a Left it accepted (srv/coop_levels_alife.cpp
// leave_squad). A living bound member of the squad, by the map server's own Left: §8a A17, held by that map server on its own. One a
// newer word bound in another squad first (that squad's Spawn listed it: a squad made and joined in the frame of the Left): only this
// squad's list forgets it, nothing of the creature changes. The audit's heal of a member list: today's way home (the map server's
// Holder never adopted it). Not listed: nothing to do.
TEST(accept_fixa_leave_plan)
{
	acc::LeaveFacts f;
	CHECK(acc::leave_plan(f) == acc::Leave::NotMember);
	f.listed = true;
	f.bound = true;
	f.living = true;
	CHECK(acc::leave_plan(f) == acc::Leave::Adopt); // the map server's own Left of a living member: it holds it on its own now
	// the same frame's new squad bound it first: out of this list only (before the fix: adopted, its m_group_id cleared, the new
	// squad's binding broken, the creature nobody's)
	f.bound_elsewhere = true;
	CHECK(acc::leave_plan(f) == acc::Leave::Unlist);
	f.living = false;
	CHECK(acc::leave_plan(f) == acc::Leave::Unlist);
	f.living = true;
	f.heal = true;
	CHECK(acc::leave_plan(f) == acc::Leave::Unlist); // bound elsewhere wins over the heal too: its new squad has it
	f.bound_elsewhere = false;
	CHECK(acc::leave_plan(f) == acc::Leave::Home); // the audit's heal: the map server has no hold of it, it goes home here
	f.heal = false;
	f.living = false;
	CHECK(acc::leave_plan(f) == acc::Leave::Home); // a dead member (its body is a resident) or one in a holder: today's way
	f.living = true;
	f.bound = false;
	CHECK(acc::leave_plan(f) == acc::Leave::Home); // an id never bound to its object: coop_leave_member drops the id
	f.bound_elsewhere = true;
	CHECK(acc::leave_plan(f) == acc::Leave::Home);
	f.listed = false;
	CHECK(acc::leave_plan(f) == acc::Leave::NotMember);
}

// The departure flood (Server, 2026-11-26; world log xray_banan4ik2.log: every printed "Parent ... not the writer" reads "parent X,
// moved to X", 1-3 lines after a player left or took an exit). A map server switched the leaving player's character offline, each item
// rejected and taken back, and sent a Parent of each into the same character; the world had parked him (nobody plays him: the world
// writes him) and refused each, and each repair made the item again on that map server. A Parent into the holder the object has here
// already is a repeat, whoever sent it; a real move and a put-down still need the writer, and the fence, the object, the ghost and its
// identity still come first (srv/coop_levels_alife.cpp fills `unchanged`, tests/test_srv_journal.cpp plays the departure).
TEST(accept_unchanged_parent_is_a_repeat)
{
	constexpr uint16_t kNoObject = coop::levels::wire::kNoObject;
	CHECK(acc::unchanged_parent(2001, 2001));
	CHECK(!acc::unchanged_parent(2001, 2002)); // a real move
	CHECK(!acc::unchanged_parent(kNoObject, kNoObject)); // a put-down carries a place: never unchanged
	CHECK(!acc::unchanged_parent(2001, kNoObject));

	const w::Writer parked = character(2001, kA, kUnled); // his player left: no seat, the world writes him
	CHECK(parked == w::this_process());
	acc::Facts f = from_a(H::Parent, parked); // an item of his, from map server A
	f.two_roots = true;
	f.writer_new = parked; // ... into the same character
	CHECK(!acc::sender_writes(f));
	CHECK(refused_for(acc::accepts(f), jr::NotWriter)); // what the log shows (no `unchanged` before the fix)
	f.unchanged = true;
	acc::Verdict v = acc::accepts(f);
	CHECK(v.ok);
	CHECK(v.repeat); // nothing to apply, nothing refused, nothing for A to repair

	// the reasons before the writer still win
	f.fence = 6; // the entry came after A's Flushed (W4)
	CHECK(refused_for(acc::accepts(f), jr::PastFence));
	f.fence = w::kNoFence;
	f.same = false;
	CHECK(refused_for(acc::accepts(f), jr::Identity));
	f.same = true;
	f.ghost = true;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
	f.ghost = false;
	f.exists = false;
	CHECK(refused_for(acc::accepts(f), jr::Unknown));
	f.exists = true;

	// a real move of his item still needs the writer of both roots (the departure race, TRACE 5C: not covered here)
	f.unchanged = false;
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	// only a Parent: another fact about his item is the writer's alone
	f.unchanged = true;
	f.op = H::Destroy;
	f.two_roots = false;
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));

	// the writer's own Parent into the same holder: a repeat as well (host_apply_parent changed nothing for it before either); its real
	// move is taken and applied
	f = from_a(H::Parent, character(2001, kA, kLedA));
	f.two_roots = true;
	f.writer_new = character(2001, kA, kLedA);
	CHECK(acc::sender_writes(f));
	f.unchanged = true;
	v = acc::accepts(f);
	CHECK(v.ok && v.repeat);
	f.unchanged = false;
	v = acc::accepts(f);
	CHECK(v.ok && !v.repeat);
	// one root A writes, the other the world: refused as before
	f.writer_new = parked;
	CHECK(!acc::sender_writes(f));
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
}

// A body report of a player's character from the map server he has just left. The world parked him at his move (nobody plays him:
// the world writes him), and the report that map server journaled before it heard of the move arrived after it. The acceptance
// still refuses it as not the writer, and hands it to his seat (wire::body_report_verdict), which drops it as a crossing; without
// that it was refused with a "!" line on every departure whose report crossed the move. Other reasons and other objects stay
// refusals.
TEST(accept_body_report_of_a_character_its_sender_left_goes_to_his_seat)
{
	acc::Facts f = from_a(H::State, character(2001, w::kNoLevel, kUnled)); // parked: the world's
	f.character = true;
	CHECK(f.writer == w::this_process());
	acc::Verdict v = acc::accepts(f);
	CHECK(refused_for(v, jr::NotWriter));
	CHECK(acc::body_report_by_seat(f, v));
	f.writer = character(2001, kB, kLedB); // seated on map B already
	v = acc::accepts(f);
	CHECK(refused_for(v, jr::NotWriter) && acc::body_report_by_seat(f, v));
	// taken from the map server that writes him: no hand-over
	f.writer = character(2001, kA, kLedA);
	v = acc::accepts(f);
	CHECK(v.ok && !acc::body_report_by_seat(f, v));
	// not a character, not a State, or another reason: the refusal stands
	f.writer = character(2001, kB, kLedB);
	f.character = false;
	CHECK(!acc::body_report_by_seat(f, acc::accepts(f)));
	f.character = true;
	f.op = H::Item;
	CHECK(!acc::body_report_by_seat(f, acc::accepts(f)));
	f.op = H::State;
	f.same = false;
	v = acc::accepts(f);
	CHECK(refused_for(v, jr::Identity) && !acc::body_report_by_seat(f, v));
	f.same = true;
	f.exists = false;
	v = acc::accepts(f);
	CHECK(refused_for(v, jr::Unknown) && !acc::body_report_by_seat(f, v));
}

// The one decision on a State (body_report), as host_take_body asks it: a body of map A's level reported by map server A.
namespace
{
acc::BodyFacts body_on_a(uint16_t seat)
{
	acc::BodyFacts b;
	b.read = true;
	b.known = true;
	b.player_character = true;
	b.body_level = kA;
	b.sender_level = kA;
	b.seat_level = seat;
	b.position_valid = true;
	return b;
}

bool decided(const acc::BodyDecision& d, acc::BodyOutcome outcome, uint8_t why, bool by_acceptance)
{
	return d.outcome == outcome && d.why == why && d.by_acceptance == by_acceptance;
}
} // namespace

// The writer's report is taken. A report of a character his sender no longer writes (the seat's rule made the world or the new
// map's server his writer at his move: parked, or seated on map B) crossed his move: Crossed, no refusal, within the grace; after
// the grace, a fault of its sender (Refused by the body verdict, journal::Refused). A report of his seat's own level from a sender
// that does not write him is no crossing: Refused.
TEST(accept_body_report_taken_crossed_or_refused)
{
	namespace lw = coop::levels::wire;
	lw::BodyCrossing run;
	acc::Facts f = from_a(H::State, character(2001, kA, kLedA));
	f.character = true;
	CHECK(decided(acc::body_report(f, body_on_a(kA), run, 1000), acc::BodyOutcome::Taken, 0, false));

	for (const uint16_t seat : {w::kNoLevel, kB})
	{
		// parked (the world writes him), or seated on map B (map server B writes him)
		f.writer = seat == w::kNoLevel ? character(2001, w::kNoLevel, kUnled) : character(2001, kB, kLedB);
		CHECK(!acc::sender_writes(f));
		lw::BodyCrossing r;
		uint64_t now = 1000;
		for (; now <= 1000 + lw::kBodyCrossedGraceMs; now += 1000)
			CHECK(decided(acc::body_report(f, body_on_a(seat), r, now), acc::BodyOutcome::Crossed, 0, false));
		const acc::BodyDecision late = acc::body_report(f, body_on_a(seat), r, now);
		CHECK(decided(late, acc::BodyOutcome::Refused, uint8_t(jr::Refused), false));
		CHECK(late.crossed_ms > lw::kBodyCrossedGraceMs);
	}

	// of the level of his seat, from a sender that does not write him (another server leads his seat's map)
	f.writer = character(2001, kA, kLedB);
	CHECK(!acc::sender_writes(f));
	lw::BodyCrossing r;
	CHECK(decided(acc::body_report(f, body_on_a(kA), r, 1000), acc::BodyOutcome::Refused, uint8_t(jr::Refused), false));
}

// A State of what is no player's character, and every reason but NotWriter, stays the acceptance's refusal, its reason unchanged.
TEST(accept_body_report_other_refusals_unchanged)
{
	namespace lw = coop::levels::wire;
	lw::BodyCrossing run;
	acc::Facts f = from_a(H::State, resident(300, kB, kLedB)); // no character: not the writer
	CHECK(decided(acc::body_report(f, body_on_a(w::kNoLevel), run, 1000), acc::BodyOutcome::Refused, uint8_t(jr::NotWriter), true));

	f = from_a(H::State, character(2001, kB, kLedB));
	f.character = true;
	f.exists = false;
	CHECK(decided(acc::body_report(f, body_on_a(kB), run, 1000), acc::BodyOutcome::Refused, uint8_t(jr::Unknown), true));
	f.exists = true;
	f.ghost = true;
	CHECK(decided(acc::body_report(f, body_on_a(kB), run, 1000), acc::BodyOutcome::Refused, uint8_t(jr::Ghost), true));
	f.ghost = false;
	f.same = false;
	CHECK(decided(acc::body_report(f, body_on_a(kB), run, 1000), acc::BodyOutcome::Refused, uint8_t(jr::Identity), true));
	f.same = true;
	f.fence = 6;
	CHECK(decided(acc::body_report(f, body_on_a(kB), run, 1000), acc::BodyOutcome::Refused, uint8_t(jr::PastFence), true));
	CHECK(run.since == 0 && run.last == 0); // no acceptance refusal starts a run of crossings
}
