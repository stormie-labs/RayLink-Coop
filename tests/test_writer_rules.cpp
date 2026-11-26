// Anomaly Coop unit tests: one writer per object: the pure rules of xrCoop/coop_writer_rules.h and the Mode's writer answer of xrCoop/coop_mode.h.
//
// - writer_of for the six process kinds (the co-op host H, a co-op client C, the world server WS, the map server of the root's map,
//   the map server of another map, no session) against every kind of root: a character placed, loading, mid-move; a unit held,
//   held from its birth, at home; a squad member through its squad (root_of); a resident on a led, a starting and an unled map;
//   an object of no map; the ghost;
// - fence_admits, same_object on a reused id;
// - the gate table row by row, then under the hostplay, srv and none answer sets (tests/support/fake_mode.h, MODE_CASES);
// - the Mode's new members (none's answers, the fake's answers through the pure rule) and the EntityUp kinds.
#include "test_util.h"
#include "coop_writer_rules.h"
#include "coop_levels_rules.h"
#include "coop_mode.h"
#include "coop_roles.h"
#include "support/fake_mode.h"

#include <string>
#include <vector>

namespace w = coop::writer;

namespace
{
// The maps of these tests and the bridges the world server names their servers by.
constexpr uint16_t kA = 5; // led: its server serves players
constexpr uint16_t kB = 7; // led: another server
constexpr uint16_t kS = 9; // its server is starting (loading its world: save + tail)
constexpr uint16_t kU = 11; // no server leads it
constexpr coop::PeerId kBridgeA = 101, kBridgeB = 102, kBridgeS = 103;

const w::Process kH{w::ProcessKind::Whole, w::kNoLevel, coop::kHostPeer};
const w::Process kC{w::ProcessKind::Mirror, w::kNoLevel, coop::kHostPeer};
const w::Process kWS{w::ProcessKind::World, w::kNoLevel, coop::kHostPeer};
const w::Process kMkA{w::ProcessKind::Level, kA, coop::kHostPeer};
const w::Process kMkB{w::ProcessKind::Level, kB, coop::kHostPeer};
const w::Process kMkS{w::ProcessKind::Level, kS, coop::kHostPeer};
const w::Process kNone{w::ProcessKind::Whole, w::kNoLevel, coop::kHostPeer};

const w::MapLead kLedA{w::Lead::Leads, kBridgeA};
const w::MapLead kLedB{w::Lead::Leads, kBridgeB};
const w::MapLead kStartingS{w::Lead::Starting, kBridgeS};
const w::MapLead kUnled{w::Lead::None, coop::kInvalidPeer};

std::string said(const char* what, const w::Writer& wr)
{
	std::string s = std::string(what) + ": " + w::writer_name(wr.is);
	if (wr.is == w::WriterIs::Other)
		s += "(" + std::to_string(wr.peer) + ")";
	return s;
}

#define WRITER_IS(what, got, want) CHECK_EQ(said(what, got), said(what, want))

// What the six kinds answer for one root: H and none write everything, a client asks its host, the rest as given.
struct Expect
{
	w::Writer ws, level_mk, other_mk;
};

void check_kinds(const char* what, const w::RootFacts& r, const w::Seat& s, const w::Process& level_mk, const w::Process& other_mk,
    const Expect& e)
{
	WRITER_IS(what, w::writer_of(r, kH, s), w::this_process());
	WRITER_IS(what, w::writer_of(r, kC, s), w::other(coop::kHostPeer));
	WRITER_IS(what, w::writer_of(r, kWS, s), e.ws);
	WRITER_IS(what, w::writer_of(r, level_mk, s), e.level_mk);
	WRITER_IS(what, w::writer_of(r, other_mk, s), e.other_mk);
	WRITER_IS(what, w::writer_of(r, kNone, s), w::this_process());
}

w::Seat on_map(const w::MapLead& m)
{
	w::Seat s;
	s.map = m;
	return s;
}

w::Seat held(w::Hold how, uint16_t level, coop::PeerId holder)
{
	w::Seat s;
	s.hold = how;
	s.holder_level = level;
	s.holder = holder;
	return s;
}

const w::WriteOp kOps[] = {w::WriteOp::Create, w::WriteOp::Release, w::WriteOp::State, w::WriteOp::Info};
const w::CodeScope kScopes[] = {w::CodeScope::LevelCode, w::CodeScope::Decision, w::CodeScope::Unknown};
const w::ProcessKind kKinds[] = {w::ProcessKind::Whole, w::ProcessKind::Mirror, w::ProcessKind::World, w::ProcessKind::Level};

std::string verdict(const char* what, w::GateVerdict v) { return std::string(what) + ": " + w::verdict_name(v); }
#define GATE_IS(what, got, want) CHECK_EQ(verdict(what, got), verdict(what, want))
} // namespace

// ------------------------------------------------------------------------------------------------- writer_of by root kind

TEST(writer_of_character_placed_loading_moving)
{
	const uint16_t him = 0x2a;
	// placed on A, whose server serves: that server; the world asks it, another map server asks its world
	check_kinds("placed on A", {w::RootKind::Character, him, kA}, on_map(kLedA), kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	// loading into A (RootFacts::level is the map he loads into): the same writer as once he stands on it
	check_kinds("loading into A", {w::RootKind::Character, him, kA}, on_map(kLedA), kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	// loading into S whose server is still starting: the world keeps him until it is up (his loading screen waits)
	check_kinds("loading into starting S", {w::RootKind::Character, him, kS}, on_map(kStartingS), kMkS, kMkA,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});
	// on a map nobody leads: the world
	check_kinds("on unled U", {w::RootKind::Character, him, kU}, on_map(kUnled), kMkA, kMkB,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});

	// mid-move A -> B: the old server keeps him until his move fence is through (W1.3, W4.2), whoever leads B
	w::Seat moving = on_map(kLedB);
	moving.from = kA;
	moving.from_map = kLedA;
	const w::RootFacts to_b{w::RootKind::Character, him, kB};
	check_kinds("mid-move A->B, fence open", to_b, moving, kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	// the fence is through: B's server
	check_kinds("moved A->B, fence through", to_b, on_map(kLedB), kMkB, kMkA,
	    {w::other(kBridgeB), w::this_process(), w::other(coop::kHostPeer)});
	// the old server stops while the fence is open: it still writes until its Stopped (W1.3)
	moving.from_map = {w::Lead::Stopping, kBridgeA};
	check_kinds("mid-move, old server stopping", to_b, moving, kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	// the old server is gone (lost) while the fence is open: nothing to wait for, B's server
	moving.from_map = {w::Lead::None, coop::kInvalidPeer};
	check_kinds("mid-move, old server lost", to_b, moving, kMkB, kMkA,
	    {w::other(kBridgeB), w::this_process(), w::other(coop::kHostPeer)});
	// mid-move into a starting map: the old server until the fence, then the world until the new one is up
	w::Seat into_s = on_map(kStartingS);
	into_s.from = kA;
	into_s.from_map = kLedA;
	check_kinds("mid-move A->S, fence open", {w::RootKind::Character, him, kS}, into_s, kMkA, kMkS,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	into_s.from = w::kNoLevel;
	check_kinds("moved A->S, S starting", {w::RootKind::Character, him, kS}, into_s, kMkS, kMkA,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});
}

TEST(writer_of_unit_held_born_home)
{
	const uint16_t squad = 0x300;
	// held by A's server (granted: the keeper has it away)
	check_kinds("unit held by A", {w::RootKind::Unit, squad, kA}, held(w::Hold::Held, kA, kBridgeA), kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	// the holder writes it wherever it stands: a held squad walking onto B is still A's until the hand-back
	w::Seat walked = held(w::Hold::Held, kA, kBridgeA);
	walked.map = kLedB;
	check_kinds("unit held by A, standing on B", {w::RootKind::Unit, squad, kB}, walked, kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	// made by A's server under its slice: held from its birth, also before the world answered its SpawnPrepare
	check_kinds("unit born on A", {w::RootKind::Unit, squad, kA}, held(w::Hold::Born, kA, kBridgeA), kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	// at home in the world (never granted, or handed back): the world simulates it, also on a led map (W1.2d)
	w::Seat home_on_a = on_map(kLedA);
	check_kinds("unit at home on led A", {w::RootKind::Unit, squad, kA}, home_on_a, kMkA, kMkB,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});
	check_kinds("unit at home on unled U", {w::RootKind::Unit, squad, kU}, on_map(kUnled), kMkA, kMkB,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});
}

TEST(writer_of_member_through_its_squad)
{
	// ids: squad 0x300 with member 0x301; 0x401 in the member's backpack inside its inventory box 0x400; a lone stalker 0x310
	// with an item 0x410; a ground item 0x420; the ghost's item 0x430; a chain of 10 parents 0x500 -> ... -> 0x509
	const auto parent_of = [](uint16_t id) -> uint16_t {
		switch (id)
		{
		case 0x401: return 0x400;
		case 0x400: return 0x301;
		case 0x410: return 0x310;
		case 0x430: return 0;
		default: break;
		}
		if (id >= 0x500 && id < 0x509)
			return uint16_t(id + 1);
		return w::kNoId;
	};
	const auto squad_of = [](uint16_t id) -> uint16_t { return id == 0x301 ? uint16_t(0x300) : w::kNoId; };

	CHECK_EQ(int(w::root_of(0x301, parent_of, squad_of)), 0x300); // a member: its squad
	CHECK_EQ(int(w::root_of(0x401, parent_of, squad_of)), 0x300); // what a member carries: its squad
	CHECK_EQ(int(w::root_of(0x300, parent_of, squad_of)), 0x300); // the squad itself
	CHECK_EQ(int(w::root_of(0x410, parent_of, squad_of)), 0x310); // a lone creature's item: the creature
	CHECK_EQ(int(w::root_of(0x420, parent_of, squad_of)), 0x420); // a ground item: itself
	CHECK_EQ(int(w::root_of(0x430, parent_of, squad_of)), 0); // the ghost's item: the ghost
	// at most kRootHops hops up
	static_assert(w::kRootHops == 8, "root_of walks 8 hops");
	CHECK_EQ(int(w::root_of(0x500, parent_of, squad_of)), 0x508);
	CHECK_EQ(int(w::root_of(0x501, parent_of, squad_of)), 0x509);

	// the member's writer is its squad's: the holder of the squad
	const uint16_t root = w::root_of(0x401, parent_of, squad_of);
	check_kinds("member's item, squad held by A", {w::RootKind::Unit, root, kA}, held(w::Hold::Held, kA, kBridgeA), kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	check_kinds("member's item, squad at home", {w::RootKind::Unit, root, kA}, on_map(kLedA), kMkA, kMkB,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});
}

TEST(writer_of_resident_led_starting_unled)
{
	const uint16_t box = 0x700;
	check_kinds("resident on led A", {w::RootKind::Resident, box, kA}, on_map(kLedA), kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	check_kinds("resident on starting S", {w::RootKind::Resident, box, kS}, on_map(kStartingS), kMkS, kMkA,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});
	check_kinds("resident on unled U", {w::RootKind::Resident, box, kU}, on_map(kUnled), kMkA, kMkB,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});
	// a stopping server writes its map's residents until its Stopped (its last journal is applied first, W1.3, W4.3)
	check_kinds("resident on stopping A", {w::RootKind::Resident, box, kA}, on_map({w::Lead::Stopping, kBridgeA}), kMkA, kMkB,
	    {w::other(kBridgeA), w::this_process(), w::other(coop::kHostPeer)});
	// no map (money, story, tasks, records): the world
	check_kinds("no map", {w::RootKind::None, 0xfff0, w::kNoLevel}, w::Seat{}, kMkA, kMkB,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});

	// the states of the life of a map server (coop_levels_rules.h ServerState) as the rule reads them
	using S = coop::levels::ServerState;
	CHECK(w::lead_of(S::Off) == w::Lead::None);
	CHECK(w::lead_of(S::Starting) == w::Lead::Starting);
	CHECK(w::lead_of(S::Ready) == w::Lead::Leads);
	CHECK(w::lead_of(S::Serving) == w::Lead::Leads);
	CHECK(w::lead_of(S::Draining) == w::Lead::Leads);
	CHECK(w::lead_of(S::Stopping) == w::Lead::Stopping);
	CHECK(w::lead_of(S::Lost) == w::Lead::None);
	CHECK(!w::writes(w::Lead::None));
	CHECK(!w::writes(w::Lead::Starting));
	CHECK(w::writes(w::Lead::Leads));
	CHECK(w::writes(w::Lead::Stopping));
	static_assert(w::kNoLevel == coop::levels::kNoLevel, "one 'no map' for the rules");
}

TEST(writer_of_the_ghost_is_nobody)
{
	// actor 0 of the world server and of a map server plays nobody (W1.5); a co-op host's and a client's own actor 0 plays
	const w::RootFacts ghost{w::RootKind::Character, w::kGhostId, kA};
	check_kinds("the ghost", ghost, on_map(kLedA), kMkA, kMkB, {w::nobody(), w::nobody(), w::nobody()});
	check_kinds("the ghost, no map", {w::RootKind::Character, w::kGhostId, w::kNoLevel}, w::Seat{}, kMkA, kMkB,
	    {w::nobody(), w::nobody(), w::nobody()});
	// a player's character with id 0 elsewhere is no ghost: only RootKind::Character counts
	check_kinds("object 0 of no map", {w::RootKind::None, 0, w::kNoLevel}, w::Seat{}, kMkA, kMkB,
	    {w::this_process(), w::other(coop::kHostPeer), w::other(coop::kHostPeer)});
}

TEST(writer_process_kind_from_the_answers)
{
	// the kinds of the six answer sets of tests/support/fake_mode.h
	CHECK(w::process_kind(false, true, true) == w::ProcessKind::Whole); // the co-op host
	CHECK(w::process_kind(true, false, false) == w::ProcessKind::Mirror); // a co-op client, a server player
	CHECK(w::process_kind(false, true, false) == w::ProcessKind::World); // the world server
	CHECK(w::process_kind(false, false, true) == w::ProcessKind::Level); // a map server
	CHECK(w::process_kind(false, false, false) == w::ProcessKind::Whole); // no session
	// a mirror writes nothing, whatever else it says (no answer of decides_world / leads_level makes it World, Level or Whole)
	CHECK(w::process_kind(true, true, true) == w::ProcessKind::Mirror);
	CHECK(w::process_kind(true, true, false) == w::ProcessKind::Mirror);
	CHECK(w::process_kind(true, false, true) == w::ProcessKind::Mirror);

	for (const t::ModeCase& c : t::mode_cases())
	{
		const t::FakeMode m(c);
		const std::string n = c.name;
		const w::ProcessKind k = m.process().kind;
		const w::ProcessKind want = n == "coop_client" || n == "server_client" ? w::ProcessKind::Mirror
		    : n == "world_server"                                              ? w::ProcessKind::World
		    : n == "map_server"                                                ? w::ProcessKind::Level
		                                                                       : w::ProcessKind::Whole;
		CHECK_EQ(n + ": " + w::kind_name(k), n + ": " + w::kind_name(want));
	}
}

// ------------------------------------------------------------------------------------------------- fences and identity

TEST(writer_fence_admits)
{
	// no fence: everything the sender sent is in
	CHECK(w::fence_admits(0, w::kNoFence));
	CHECK(w::fence_admits(1, w::kNoFence));
	CHECK(w::fence_admits(0xfffffffeu, w::kNoFence));
	CHECK(w::fence_admits(w::kNoFence, w::kNoFence));
	// a fence at the sender's entry 10 (its Flushed): everything up to it is in, nothing after it
	CHECK(w::fence_admits(9, 10));
	CHECK(w::fence_admits(10, 10));
	CHECK(!w::fence_admits(11, 10));
	CHECK(!w::fence_admits(0xfffffffeu, 10));
	// a fence before its first entry (entries count from 1): nothing of it is in
	CHECK(!w::fence_admits(1, 0));
}

TEST(writer_same_object_on_a_reused_id)
{
	const uint16_t medkit = 0x1d2b, bandage = 0x7c11;
	// the same object: its section and its keeper generation match (0 for an object that is no unit)
	CHECK(w::same_object(medkit, medkit, 0, 0));
	CHECK(w::same_object(bandage, bandage, 3, 3));
	// the id was released and given to another object: another section under it
	CHECK(!w::same_object(medkit, bandage, 0, 0));
	CHECK(!w::same_object(bandage, medkit, 3, 3));
	// the same section, but the unit was handed back and granted again: a fact of the older grant is another object's
	CHECK(!w::same_object(bandage, bandage, 4, 3));
	CHECK(!w::same_object(bandage, bandage, 3, 4));
}

// ------------------------------------------------------------------------------------------------- the W2a gate table

TEST(writer_gate_row_this_runs)
{
	// any | This | - | Run (stock): every kind, op, scope, map
	for (w::ProcessKind k : kKinds)
		for (w::WriteOp op : kOps)
			for (w::CodeScope s : kScopes)
				for (bool own : {false, true})
					GATE_IS(w::kind_name(k), w::gate(k, w::this_process(), op, s, own, false), w::GateVerdict::Run);
}

TEST(writer_gate_row_mirror_keeps_todays_verdict)
{
	// a player's machine (both modes) | Other | - | today's verdict, unchanged
	for (w::WriteOp op : kOps)
		for (w::CodeScope s : kScopes)
			for (bool own : {false, true})
				GATE_IS(w::op_name(op), w::gate(w::ProcessKind::Mirror, w::other(coop::kHostPeer), op, s, own, false),
				    w::GateVerdict::Mirror);
}

TEST(writer_gate_rows_world_server)
{
	const w::Writer mk = w::other(kBridgeA);
	for (bool own : {false, true})
	{
		// WS | a Mk | level, owner or view code | Refuse: that Mk runs its own copy of this code
		for (w::WriteOp op : kOps)
			GATE_IS(w::op_name(op), w::gate(w::ProcessKind::World, mk, op, w::CodeScope::LevelCode, own, false),
			    w::GateVerdict::Refuse);
		// WS | a Mk | a decision (host domain, a request handler, the far view, an engine apply) or an unknown scope |
		// create: Run (the spawn goes down); release, state, info: the numbered far order to that Mk
		for (w::CodeScope s : {w::CodeScope::Decision, w::CodeScope::Unknown})
		{
			GATE_IS("create", w::gate(w::ProcessKind::World, mk, w::WriteOp::Create, s, own, false), w::GateVerdict::Run);
			GATE_IS("release", w::gate(w::ProcessKind::World, mk, w::WriteOp::Release, s, own, false), w::GateVerdict::Order);
			GATE_IS("state", w::gate(w::ProcessKind::World, mk, w::WriteOp::State, s, own, false), w::GateVerdict::Order);
			GATE_IS("info", w::gate(w::ProcessKind::World, mk, w::WriteOp::Info, s, own, false), w::GateVerdict::Order);
		}
	}
}

TEST(writer_gate_rows_map_server)
{
	const w::Writer world = w::other(coop::kHostPeer);
	for (w::CodeScope s : kScopes)
	{
		// Mk | not This, root on its own map | release, info | Ask: a journal entry, the world executes it
		GATE_IS("release, own map", w::gate(w::ProcessKind::Level, world, w::WriteOp::Release, s, true, false), w::GateVerdict::Ask);
		GATE_IS("info, own map", w::gate(w::ProcessKind::Level, world, w::WriteOp::Info, s, true, false), w::GateVerdict::Ask);
		// Mk | not This | create or state | Refuse
		GATE_IS("create, own map", w::gate(w::ProcessKind::Level, world, w::WriteOp::Create, s, true, false), w::GateVerdict::Refuse);
		GATE_IS("state, own map", w::gate(w::ProcessKind::Level, world, w::WriteOp::State, s, true, false), w::GateVerdict::Refuse);
		// Mk | not This | any op on another map | Refuse: a Mk never writes another level
		for (w::WriteOp op : kOps)
			GATE_IS(w::op_name(op), w::gate(w::ProcessKind::Level, world, op, s, false, false), w::GateVerdict::Refuse);
	}
}

TEST(writer_gate_row_the_ghost)
{
	// WS or Mk | the ghost | create, give | Refuse (W1.5), whatever the caller found its writer to be
	for (w::ProcessKind k : {w::ProcessKind::World, w::ProcessKind::Level})
		for (w::CodeScope s : kScopes)
			for (bool own : {false, true})
				for (const w::Writer& wr : {w::nobody(), w::this_process()})
				{
					GATE_IS("create into the ghost", w::gate(k, wr, w::WriteOp::Create, s, own, true), w::GateVerdict::Refuse);
					GATE_IS("info to the ghost", w::gate(k, wr, w::WriteOp::Info, s, own, true), w::GateVerdict::Refuse);
				}
	// what is not in the row: the world server keeps its ghost in its save (it may clear what was put there), a map server's
	// ghost is a world object like any other it does not write
	for (w::CodeScope s : kScopes)
	{
		GATE_IS("WS release of the ghost's", w::gate(w::ProcessKind::World, w::nobody(), w::WriteOp::Release, s, true, true),
		    w::GateVerdict::Run);
		GATE_IS("WS state of the ghost's", w::gate(w::ProcessKind::World, w::nobody(), w::WriteOp::State, s, false, true),
		    w::GateVerdict::Run);
		GATE_IS("Mk release of the ghost's", w::gate(w::ProcessKind::Level, w::nobody(), w::WriteOp::Release, s, true, true),
		    w::GateVerdict::Ask);
		GATE_IS("Mk state of the ghost's", w::gate(w::ProcessKind::Level, w::nobody(), w::WriteOp::State, s, true, true),
		    w::GateVerdict::Refuse);
	}
	// a process whose actor plays has no ghost: the flag changes nothing there
	for (w::WriteOp op : kOps)
	{
		GATE_IS("host", w::gate(w::ProcessKind::Whole, w::this_process(), op, w::CodeScope::Unknown, true, true), w::GateVerdict::Run);
		GATE_IS("client", w::gate(w::ProcessKind::Mirror, w::other(coop::kHostPeer), op, w::CodeScope::Unknown, true, true),
		    w::GateVerdict::Mirror);
	}
}

TEST(writer_gate_one_writer_of_everything_never_defers)
{
	// the co-op host and no session write everything (their answer is This); an answer that is not cannot be deferred to
	// anybody: they run as today
	for (w::WriteOp op : kOps)
		for (w::CodeScope s : kScopes)
		{
			GATE_IS("whole, other", w::gate(w::ProcessKind::Whole, w::other(7), op, s, false, false), w::GateVerdict::Run);
			GATE_IS("whole, nobody", w::gate(w::ProcessKind::Whole, w::nobody(), op, s, false, false), w::GateVerdict::Run);
		}
}

// The table under each answer set: the fake mode of each process kind answers writer_of through the pure rule from the facts the
// test gives it, and gate() takes the kind those answers make.
TEST(writer_gate_under_the_answer_sets)
{
	const uint16_t box = 0x700, squad = 0x300;
	const w::RootFacts resident_a{w::RootKind::Resident, box, kA};
	const w::RootFacts home_unit_a{w::RootKind::Unit, squad, kA};
	const w::RootFacts ghost{w::RootKind::Character, w::kGhostId, kA};
	for (const t::ModeCase& c : t::mode_cases())
	{
		t::FakeMode m(c);
		const std::string n = c.name;
		m.lead(kA, w::Lead::Leads, kBridgeA);
		if (n == "map_server")
			m.own_level(kA);
		const w::ProcessKind k = m.process().kind;
		const auto run = [&](const w::RootFacts& r, w::WriteOp op, w::CodeScope s, bool own) {
			return w::gate(k, m.writer_of(r), op, s, own, r.kind == w::RootKind::Character && r.root == w::kGhostId && !m.actor_is_player());
		};
		for (w::WriteOp op : kOps)
			for (w::CodeScope s : kScopes)
			{
				const std::string at = n + " " + w::op_name(op);
				w::GateVerdict resident = w::GateVerdict::Run, unit = w::GateVerdict::Run, at_ghost = w::GateVerdict::Run;
				if (n == "coop_client" || n == "server_client")
					resident = unit = at_ghost = w::GateVerdict::Mirror;
				else if (n == "world_server")
				{
					// a box of A is A's server's; the squad at home and the ghost are the world's own
					resident = s == w::CodeScope::LevelCode ? w::GateVerdict::Refuse
					    : op == w::WriteOp::Create          ? w::GateVerdict::Run
					                                        : w::GateVerdict::Order;
					at_ghost = op == w::WriteOp::Create || op == w::WriteOp::Info ? w::GateVerdict::Refuse : w::GateVerdict::Run;
				}
				else if (n == "map_server")
				{
					// the box of its own map is its own; the squad at home on its map is the world's: release and info are asked
					unit = op == w::WriteOp::Release || op == w::WriteOp::Info ? w::GateVerdict::Ask : w::GateVerdict::Refuse;
					at_ghost = op == w::WriteOp::Release ? w::GateVerdict::Ask : w::GateVerdict::Refuse;
				}
				GATE_IS((at + " resident").c_str(), run(resident_a, op, s, true), resident);
				GATE_IS((at + " home unit").c_str(), run(home_unit_a, op, s, true), unit);
				GATE_IS((at + " ghost").c_str(), run(ghost, op, s, true), at_ghost);
			}
	}
}

// ------------------------------------------------------------------------------------------------- the Mode's members

TEST(writer_mode_none_answers)
{
	coop::NoneMode none;
	const coop::Mode& m = none;
	WRITER_IS("none", m.writer_of({w::RootKind::Resident, 0x700, kA}), w::this_process());
	WRITER_IS("none ghost id", m.writer_of({w::RootKind::Character, 0, w::kNoLevel}), w::this_process()); // its actor plays
	none.reconcile_world(); // nothing
	CHECK(none.save_ready(0));
	CHECK(none.save_ready(123456789));
	// the kinds of an object the world hears of (§8), in this order
	static_assert(int(coop::EntityUp::Spawned) == 0 && int(coop::EntityUp::Released) == 1 && int(coop::EntityUp::Parent) == 2 &&
	        int(coop::EntityUp::Died) == 3 && int(coop::EntityUp::Joined) == 4 && int(coop::EntityUp::Left) == 5 &&
	        int(coop::EntityUp::Info) == 6 && int(coop::EntityUp::ItemFacts) == 7,
	    "the kinds of §8 in order, the first four unchanged");
}

TEST(writer_mode_fake_answers_by_kind)
{
	const uint16_t him = 0x2a, squad = 0x300, box = 0x700;
	for (const t::ModeCase& c : t::mode_cases())
	{
		t::FakeMode m(c);
		const std::string n = c.name;
		m.lead(kA, w::Lead::Leads, kBridgeA);
		m.lead(kB, w::Lead::Leads, kBridgeB);
		m.lead(kS, w::Lead::Starting, kBridgeS);
		if (n == "map_server")
			m.own_level(kA);
		m.holds(squad, kA, kBridgeA);
		m.moving(him, kA);
		const w::RootFacts resident{w::RootKind::Resident, box, kA}, unit{w::RootKind::Unit, squad, kB},
		    moving{w::RootKind::Character, him, kB}, starting{w::RootKind::Resident, box, kS}, ghost{w::RootKind::Character, 0, kA};

		// what the pure rule answers for this kind with these facts
		w::Writer mine = w::this_process(), host = w::other(coop::kHostPeer);
		if (n == "coop_host" || n == "none")
		{
			for (const w::RootFacts& r : {resident, unit, moving, starting, ghost})
				WRITER_IS((n + " writes everything").c_str(), m.writer_of(r), mine);
		}
		else if (n == "coop_client" || n == "server_client")
		{
			for (const w::RootFacts& r : {resident, unit, moving, starting, ghost})
				WRITER_IS((n + " asks its host").c_str(), m.writer_of(r), host);
		}
		else if (n == "world_server")
		{
			WRITER_IS("WS resident of A", m.writer_of(resident), w::other(kBridgeA));
			WRITER_IS("WS unit held by A", m.writer_of(unit), w::other(kBridgeA));
			WRITER_IS("WS moving from A", m.writer_of(moving), w::other(kBridgeA));
			WRITER_IS("WS resident of starting S", m.writer_of(starting), mine);
			WRITER_IS("WS ghost", m.writer_of(ghost), w::nobody());
			m.moved(him);
			m.home(squad);
			WRITER_IS("WS moved to B", m.writer_of(moving), w::other(kBridgeB));
			WRITER_IS("WS unit at home", m.writer_of(unit), mine);
		}
		else if (n == "map_server")
		{
			WRITER_IS("Mk resident of its map", m.writer_of(resident), mine);
			WRITER_IS("Mk unit it holds", m.writer_of(unit), mine);
			WRITER_IS("Mk moving away", m.writer_of(moving), mine);
			WRITER_IS("Mk resident of S", m.writer_of(starting), host);
			WRITER_IS("Mk ghost", m.writer_of(ghost), w::nobody());
			m.moved(him);
			m.home(squad);
			WRITER_IS("Mk moved to B", m.writer_of(moving), host);
			WRITER_IS("Mk unit at home", m.writer_of(unit), host);
		}
		else
			CHECK(false); // a kind the test does not know

		// reconcile_world: a map server repairs towards its world; save_ready: a world server waits for its flush round
		m.reconcile_world();
		CHECK_EQ(n + " reconciles " + std::to_string(m.reconciles), n + " reconciles " + (n == "map_server" ? "1" : "0"));
		CHECK(m.save_ready(1));
		m.flush_pending(true);
		CHECK_EQ(n + (m.save_ready(2) ? " ready" : " waits"), n + (n == "world_server" ? " waits" : " ready"));
		m.flush_pending(false);
		CHECK(m.save_ready(3));
	}
}

TEST(writer_names_for_the_log)
{
	CHECK_EQ(std::string(w::writer_name(w::WriterIs::This)), std::string("this"));
	CHECK_EQ(std::string(w::writer_name(w::WriterIs::Other)), std::string("other"));
	CHECK_EQ(std::string(w::writer_name(w::WriterIs::Nobody)), std::string("nobody"));
	CHECK_EQ(std::string(w::verdict_name(w::GateVerdict::Run)), std::string("run"));
	CHECK_EQ(std::string(w::verdict_name(w::GateVerdict::Mirror)), std::string("mirror"));
	CHECK_EQ(std::string(w::verdict_name(w::GateVerdict::Refuse)), std::string("refuse"));
	CHECK_EQ(std::string(w::verdict_name(w::GateVerdict::Ask)), std::string("ask"));
	CHECK_EQ(std::string(w::verdict_name(w::GateVerdict::Order)), std::string("order"));
	CHECK_EQ(std::string(w::op_name(w::WriteOp::Create)), std::string("create"));
	CHECK_EQ(std::string(w::op_name(w::WriteOp::Release)), std::string("release"));
	CHECK_EQ(std::string(w::op_name(w::WriteOp::State)), std::string("state"));
	CHECK_EQ(std::string(w::op_name(w::WriteOp::Info)), std::string("info"));
	CHECK_EQ(std::string(w::kind_name(w::ProcessKind::Whole)), std::string("whole"));
	CHECK_EQ(std::string(w::kind_name(w::ProcessKind::Mirror)), std::string("mirror"));
	CHECK_EQ(std::string(w::kind_name(w::ProcessKind::World)), std::string("world"));
	CHECK_EQ(std::string(w::kind_name(w::ProcessKind::Level)), std::string("level"));
}
