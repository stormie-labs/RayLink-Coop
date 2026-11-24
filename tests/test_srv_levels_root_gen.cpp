// Anomaly Coop unit tests: the generation at the root of an object (TZ Р68-3, Р68-2; Р32 A6, A16, §8a A17), xrCoop/srv/
// coop_levels_root_gen.h. A map server names the root of every per-object entry with the gen its Holder holds that root under
// (srv/coop_levels_xfer.cpp held_gen_of -> root_gen); the world checks it with the gen its Keeper says that sender holds it under
// (srv/coop_levels_alife.cpp same_as -> root_gen). Both read the root and its kind with writing::root_facts_of. The Keeper and the
// Holder run the real transfer protocol here, packets delivered by hand, as test_levels_adopt.cpp does; the acceptance is
// coop_levels_accept.h, filled as host_apply_fact fills it.
//
// The defect (reports #1743-#1752, Dev 59): a lone stalker a GAMMA task made (tasks_recover_item_on_corpse) was granted to map
// server 4 and died there. Its Holder keeps the body (no Joined, no release), so the map server named the body's things with the
// hold's gen G; the world gave every root that is no living unit gen 0 and refused the wear of the loot, the PDA put down, the
// pickups into the player's character as "another object" (Identity). The things stayed in the corpse on the world, the repair put
// them back there on the map server too, and the Duty task (its PDA) never moved on.
//
// Server mode only (the world server and its map servers); the co-op has no map servers, no Holder, no journal. The file is a
// test_srv_* one: a change of the srv layer alone may come with it (docs/MODES.md section 10, tools/check_gates.py).
#include "test_util.h"

#include "coop_writer_rules.h"
#include "srv/coop_levels_accept.h"
#include "srv/coop_levels_keeper.h"
#include "srv/coop_levels_root_gen.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <vector>

using namespace coop;
using namespace coop::levels;

namespace
{
namespace w = coop::writer;
namespace acc = coop::levels::accept;
namespace jr = coop::levels::journal;
using H = wire::LevelEntityHead;
using Kind = w::RootKind;

constexpr uint32_t kBridgeA = 0x101; // the session peer of map server A on the world server
constexpr uint32_t kBridgeB = 0x102; // another map server, of another map
constexpr uint16_t kMapA = 5;
constexpr uint16_t kMapB = 6;
constexpr uint16_t kLone = 0x3000; // a lone stalker (no squad) the world grants to A: the corpse of the rioc task
constexpr uint16_t kS1 = 0x2000; // a squad A holds
constexpr uint16_t kM = 0x2001; // its member that leaves it alive (A17) and dies later
constexpr uint16_t kChar = 0x1f5; // a player's character on A's map
constexpr uint16_t kGun = 0x2a00; // a thing a creature carries
constexpr uint16_t kCrc = 0x5151;

const w::Process kWS{w::ProcessKind::World, w::kNoLevel, kHostPeer};

xfer::Bytes bytes(uint8_t v) { return xfer::Bytes{v, uint8_t(v + 1), uint8_t(v + 2)}; }

// The world's keeper and map server A's Holder (and B's, which holds nothing).
struct Rig
{
	Keeper keeper;
	xfer::Holder holder{7};
	xfer::Holder holder_b{8};
	uint64_t now = 1000;

	Rig()
	{
		keeper.connect(kBridgeA);
		keeper.connect(kBridgeB);
	}

	void to_map(const std::vector<xfer::Packet>& down)
	{
		for (const xfer::Packet& p : down)
		{
			xfer::Packet c = p;
			c.from = xfer::kWorld;
			c.to = holder.self();
			to_world(holder.on_packet(c, now));
		}
	}
	void to_world(const std::vector<xfer::Packet>& up, const xfer::Bytes* fresh = nullptr)
	{
		for (const xfer::Packet& p : up)
			to_map(keeper.on_up(kBridgeA, p, fresh, now));
		keeper.take_changes();
	}
	// The world grants `id` to A, A commits (a unit near its player).
	void take(uint16_t id, uint8_t v)
	{
		const xfer::Bytes fresh = bytes(v);
		to_world(holder.want_online(id, now), &fresh);
		holder.take_events();
	}
	// The Left of `member` from `unit`, alive: A's hook (Holder::adopt), the world's apply (Keeper::adopt).
	bool left(uint16_t unit, uint16_t member)
	{
		const bool map = holder.adopt(member, unit, xfer::Bytes(), now);
		const bool world = keeper.adopt(member, unit, kBridgeA, bytes(9));
		keeper.take_changes();
		return map && world;
	}

	// The gen the world checks a head of `bridge` with: root_gen of the root as the world sees it now, over its Keeper (same_as).
	uint32_t world_gen(Kind on_world, uint16_t root, uint32_t bridge, uint32_t& spawn) const
	{
		return root_gen(on_world, keeper.gen_held_by(root, bridge, spawn));
	}
	// The gen a map server names the root with: root_gen of the root as it sees it now, over its Holder (held_gen_of).
	static uint32_t map_gen(Kind on_map, uint16_t root, const xfer::Holder& map) { return root_gen(on_map, map.gen(root)); }

	// The world's identity check of a head (A6).
	bool same(Kind on_world, Kind on_map, uint16_t root, uint32_t bridge, const xfer::Holder& map) const
	{
		uint32_t spawn = 0;
		const uint32_t here = world_gen(on_world, root, bridge, spawn);
		return acc::identity(kCrc, kCrc, here, map_gen(on_map, root, map), spawn);
	}
	bool same(Kind on_world, Kind on_map, uint16_t root) const { return same(on_world, on_map, root, kBridgeA, holder); }

	// The world's writer of a root as world_writer_of fills the seat: a unit from the keeper, the rest from who leads the map.
	w::Writer writer_of(Kind kind, uint16_t root, uint16_t level) const
	{
		w::Seat s;
		s.map = w::MapLead{w::Lead::Leads, PeerId(level == kMapB ? kBridgeB : kBridgeA)};
		if (kind == Kind::Unit && keeper.holder_of(root) != Keeper::kNoSession)
		{
			s.hold = w::Hold::Held;
			s.holder = PeerId(keeper.holder_of(root));
			s.holder_level = kMapA;
		}
		return w::writer_of(w::RootFacts{kind, root, level}, kWS, s);
	}

	// The world's acceptance of an entry of `bridge` about an object whose root is `root`. A Parent moves it into `to` (a player's
	// character on A's map): its new root's writer is asked too.
	acc::Verdict accepts(uint8_t op, Kind on_world, Kind on_map, uint16_t root, uint32_t bridge, const xfer::Holder& map) const
	{
		acc::Facts f;
		f.op = op;
		f.sender = PeerId(bridge);
		f.sender_level = bridge == kBridgeB ? kMapB : kMapA;
		f.exists = true;
		f.same = same(on_world, on_map, root, bridge, map);
		f.writer = writer_of(on_world, root, kMapA);
		if (op == H::Parent)
		{
			f.two_roots = true;
			f.writer_new = writer_of(Kind::Character, kChar, kMapA);
		}
		return acc::accepts(f);
	}
	acc::Verdict accepts(uint8_t op, Kind on_world, Kind on_map, uint16_t root) const
	{
		return accepts(op, on_world, on_map, root, kBridgeA, holder);
	}
};

void check_taken(const acc::Verdict& v)
{
	CHECK(v.ok);
	CHECK_EQ(int(v.why), 0);
}

// What writing::root_facts_of reads of the ALife objects, as rows: the parent, a creature's squad (m_group_id), the kind facts.
struct Row
{
	uint16_t parent;
	uint16_t squad;
	w::KindFacts facts;
};

// writing::root_facts_of over the rows: writer::root_of (up the parents, then a creature's squad), and the kind of that root's own row.
w::RootFacts root_facts_of(const std::map<uint16_t, Row>& rows, uint16_t id)
{
	const auto parent_of = [&rows](uint16_t i) {
		const auto it = rows.find(i);
		return it == rows.end() ? w::kNoId : it->second.parent;
	};
	const auto squad_of = [&rows](uint16_t i) {
		const auto it = rows.find(i);
		return it == rows.end() ? w::kNoId : it->second.squad;
	};
	w::RootFacts f{Kind::None, id, w::kNoLevel};
	f.root = w::root_of(id, parent_of, squad_of);
	const auto r = rows.find(f.root);
	if (r != rows.end())
	{
		f.kind = w::kind_of(r->second.facts);
		f.level = kMapA;
	}
	return f;
}
} // namespace

// The rule itself: a unit and the body it left name one gen, the hold's, on both sides; nothing held names 0; a player's character
// never names a hold (no side holds one: host_may_give, adopts_at_left), as before.
TEST(srv_levels_root_gen_the_hold_names_a_unit_and_its_body_alike)
{
	uint32_t held = 7u; // not a constant: the checks run at run time (C4127)
	CHECK_EQ(root_gen(Kind::Unit, held), held);
	CHECK_EQ(root_gen(Kind::Resident, held), held); // Р68-3: the body of a held unit that died
	CHECK_EQ(root_gen(Kind::None, held), held);
	CHECK_EQ(root_gen(Kind::Character, held), 0u);
	for (const Kind k : {Kind::Unit, Kind::Resident, Kind::None, Kind::Character})
		CHECK_EQ(root_gen(k, 0u), 0u);
	// what decides the head (the map server after on_death) and the check (the world before its Died) is the same gen
	held = 9u;
	CHECK_EQ(root_gen(Kind::Resident, held), root_gen(Kind::Unit, held));
}

// (2) The Died of a lone unit the world gave A: A writes its head after the stock on_death (fHealth -1: the body is a resident to
// it), the world applies it while the creature still lives there (a unit). Both name G: taken. The variant "a dead lone unit names
// 0" (review of R68, tasks) would refuse it as Identity.
TEST(srv_levels_root_gen_died_of_a_lone_unit_the_world_gave_is_taken)
{
	Rig r;
	r.take(kLone, 1);
	REQUIRE(r.holder.authors(kLone));
	REQUIRE(r.holder.gen(kLone) != 0u);
	CHECK(r.same(Kind::Unit, Kind::Resident, kLone));
	check_taken(r.accepts(H::Died, Kind::Unit, Kind::Resident, kLone));
}

// (1) After that Died the body is a resident on the world, held by A on both sides (no Joined, no release: the world's mark stays,
// A's Holder keeps it). The wear of its loot (ItemFacts), the PDA put down, the pickups into the player's character (Parent): taken.
// Before the fix the world named the root 0 and refused all of them as "another object" (#1743-#1746, #1751, #1752).
TEST(srv_levels_root_gen_things_in_the_body_of_a_lone_unit_are_taken_after_its_death)
{
	Rig r;
	r.take(kLone, 1);
	REQUIRE(r.accepts(H::Died, Kind::Unit, Kind::Resident, kLone).ok);
	CHECK(r.keeper.away(kLone)); // the world keeps its mark at A
	CHECK(r.holder.authors(kLone)); // A keeps its hold
	uint32_t spawn = 0;
	CHECK_EQ(r.world_gen(Kind::Resident, kLone, kBridgeA, spawn), r.holder.gen(kLone));
	CHECK(r.same(Kind::Resident, Kind::Resident, kLone));
	check_taken(r.accepts(H::Item, Kind::Resident, Kind::Resident, kLone));
	check_taken(r.accepts(H::Parent, Kind::Resident, Kind::Resident, kLone)); // into the player's character
	check_taken(r.accepts(H::State, Kind::Resident, Kind::Resident, kLone)); // the body itself
}

// (3) A member that left A's squad alive (A17) is A's on its own under the squad's gen; it dies on A later. Its Died (A: a resident
// after on_death, the world: a loose living unit) and the Parent of its gun after that are taken.
TEST(srv_levels_root_gen_a_member_adopted_at_left_then_dead_keeps_its_hold)
{
	Rig r;
	r.take(kS1, 1);
	REQUIRE(r.left(kS1, kM));
	REQUIRE(r.holder.gen(kM) == r.holder.gen(kS1));
	check_taken(r.accepts(H::Died, Kind::Unit, Kind::Resident, kM));
	check_taken(r.accepts(H::Parent, Kind::Resident, Kind::Resident, kM));
	check_taken(r.accepts(H::Item, Kind::Resident, Kind::Resident, kM));
}

// (4) The same root, a sender that does not hold it: 0 on both sides, and the refusal is what it was before the fix.
//   a. A body nobody holds (a creature the world simulated and killed itself, never granted): A names 0, the world 0: taken, as
//      before (the resident of A's map is A's to write).
//   b. Map server B reports on the body A holds: B's Holder names 0, the world's Keeper 0 for B (the mark is A's): the same object,
//      and B is not its writer (NotWriter), as before.
TEST(srv_levels_root_gen_a_sender_that_does_not_hold_the_root_names_0_on_both_sides)
{
	Rig r;
	uint32_t spawn = 0;
	CHECK_EQ(r.world_gen(Kind::Resident, kLone, kBridgeA, spawn), 0u);
	CHECK_EQ(Rig::map_gen(Kind::Resident, kLone, r.holder), 0u);
	check_taken(r.accepts(H::Parent, Kind::Resident, Kind::Resident, kLone));

	r.take(kLone, 1);
	REQUIRE(r.accepts(H::Died, Kind::Unit, Kind::Resident, kLone).ok);
	CHECK_EQ(r.world_gen(Kind::Resident, kLone, kBridgeB, spawn), 0u);
	CHECK_EQ(Rig::map_gen(Kind::Resident, kLone, r.holder_b), 0u);
	CHECK(r.same(Kind::Resident, Kind::Resident, kLone, kBridgeB, r.holder_b));
	const acc::Verdict v = r.accepts(H::Parent, Kind::Resident, Kind::Resident, kLone, kBridgeB, r.holder_b);
	CHECK(!v.ok);
	CHECK_EQ(int(v.why), int(jr::NotWriter));
	// and a stale head of A for a root it gave up: the world's gen is 0, A names its old gen: another object, as before
	CHECK(!acc::identity(kCrc, kCrc, 0u, r.holder.gen(kLone), 0u));
}

// (5) A root that is a player's character: 0 on both sides, as before (no side holds a character), whatever a record says.
TEST(srv_levels_root_gen_a_players_character_names_0)
{
	Rig r;
	uint32_t spawn = 0;
	CHECK_EQ(r.world_gen(Kind::Character, kChar, kBridgeA, spawn), 0u);
	CHECK_EQ(Rig::map_gen(Kind::Character, kChar, r.holder), 0u);
	CHECK(r.same(Kind::Character, Kind::Character, kChar));
	CHECK_EQ(root_gen(Kind::Character, r.holder.gen(kS1) + 5u), 0u);
}

// (6) The world kills its record itself (coop_srv_quests_far.script ON_RECORD.kill -> srv.kill_record -> host_apply_death: the
// order found no map server that answers): its hold is not touched, A still holds the creature (alive there, or dead). The things in
// it are taken, and so is A's own Died when it comes (the world's body is dead already: nothing changes).
TEST(srv_levels_root_gen_a_record_the_world_killed_itself_keeps_the_hold)
{
	Rig r;
	r.take(kLone, 1);
	// no journal entry: the world's record is dead, its keeper mark and A's Holder unchanged
	CHECK(r.keeper.away(kLone));
	CHECK(r.holder.authors(kLone));
	check_taken(r.accepts(H::Parent, Kind::Resident, Kind::Unit, kLone)); // alive on A still
	check_taken(r.accepts(H::Item, Kind::Resident, Kind::Unit, kLone));
	check_taken(r.accepts(H::Died, Kind::Resident, Kind::Resident, kLone)); // A's Died afterwards
	check_taken(r.accepts(H::Parent, Kind::Resident, Kind::Resident, kLone));
}

// (7) A member counts as its squad on both sides (review of Р68-2): both read the root and its kind with writing::root_facts_of
// (the world in root_seen, the map server in held_gen_of), so a member's root is its squad (writer::root_of) and the kind is the
// squad's own row, a unit, whatever the member is. A player's character in a squad A holds (no script puts one there today) and the
// gun he carries are named with the squad's hold G on both sides. The kind read off the member (the map server before the review:
// a character) names 0, and the world refuses the entry as "another object". The engine's wiring is not in this exe: what is
// checked here is the rule both sides now share.
TEST(srv_levels_root_gen_a_member_counts_as_its_squad_on_both_sides)
{
	Rig r;
	r.take(kS1, 1);
	const uint32_t held = r.holder.gen(kS1);
	REQUIRE(held != 0u);
	const std::map<uint16_t, Row> rows = {
	    {kS1, Row{w::kNoId, w::kNoId, w::KindFacts{false, false, true, false, false, true}}}, // the squad
	    {kChar, Row{w::kNoId, kS1, w::KindFacts{false, true, false, true, true, true}}}, // a player's character in it
	    {kGun, Row{kChar, w::kNoId, w::KindFacts{false, false, false, false, false, true}}}, // his gun
	};
	for (const uint16_t id : {kChar, kGun})
	{
		const w::RootFacts f = root_facts_of(rows, id);
		CHECK_EQ(int(f.root), int(kS1));
		CHECK_EQ(int(f.kind), int(Kind::Unit));
		CHECK_EQ(Rig::map_gen(f.kind, f.root, r.holder), held);
		uint32_t spawn = 0;
		CHECK_EQ(r.world_gen(f.kind, f.root, kBridgeA, spawn), held);
		check_taken(r.accepts(H::Item, f.kind, f.kind, f.root));
	}
	// the kind of the member's own row names no hold: a character, 0 against the world's G
	const Kind member = w::kind_of(rows.at(kChar).facts);
	CHECK_EQ(int(member), int(Kind::Character));
	CHECK(!r.same(Kind::Unit, member, kS1));
	CHECK_EQ(int(r.accepts(H::Item, Kind::Unit, member, kS1).why), int(jr::Identity));
	// a player's character in no squad is his own root: a character on both sides, 0, as before
	const std::map<uint16_t, Row> alone = {{kChar, Row{w::kNoId, w::kNoId, w::KindFacts{false, true, false, true, true, true}}}};
	const w::RootFacts f = root_facts_of(alone, kChar);
	CHECK_EQ(int(f.root), int(kChar));
	CHECK_EQ(int(f.kind), int(Kind::Character));
	CHECK_EQ(Rig::map_gen(f.kind, f.root, r.holder), 0u);
}

// A16: a unit on its way home names the gen it was held under on both sides, whatever it is by then.
TEST(srv_levels_root_gen_on_its_way_home_both_sides_name_the_old_gen)
{
	Rig r;
	r.take(kLone, 1);
	const uint32_t held = r.holder.gen(kLone);
	REQUIRE(held != 0u);
	const std::vector<xfer::Packet> prepare = r.holder.want_offline(kLone, bytes(4), r.now);
	REQUIRE(!prepare.empty());
	for (const xfer::Packet& p : prepare)
		r.keeper.on_up(kBridgeA, p, nullptr, r.now); // the world's Ack stays on its way: A is Releasing
	uint32_t spawn = 0;
	CHECK_EQ(Rig::map_gen(Kind::Resident, kLone, r.holder), held);
	CHECK_EQ(r.world_gen(Kind::Resident, kLone, kBridgeA, spawn), held);
	CHECK(r.same(Kind::Resident, Kind::Resident, kLone));
	CHECK(r.same(Kind::Unit, Kind::Unit, kLone));
}
