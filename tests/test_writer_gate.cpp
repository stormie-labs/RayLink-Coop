// Anomaly Coop unit tests: the writer gate on the script paths (TZ Р32, temp/r30/design/R32-final.md §1 W2a, W9; §6
// test_writer_gate.cpp; §8, §8a A8, A9) and W9's "no fallback" where an id is taken.
//
// - the golden table: today's calls::decide for the co-op host and a co-op client on every gated script write (alife():create,
//   create_ammo, register, clone_weapon, release, give_info, disable_info; level.spawn_item), and the writer gate over it under the
//   hostplay answers (tests/support/fake_mode.h): the same verdict, in both settings of coop_writer_gate;
// - the world server's and a map server's rows: level code, a decision, an unknown scope, an ask, an order, the ghost; log only
//   counts, enforce refuses (an ask and an order have no path in the engine yet: today's code, counted);
// - the router domain -> code scope map, the writer of a create's new root, the census (one line per call and script);
// - W9: what a map server does with no id of its pool left (refused at the start of a create under enforce, a stock id only
//   inside a stock chain that is already running), and the engine sources that take ids (xrServer.h PerformIDgen,
//   xrServer_process_spawn.cpp, alife_simulator_script.cpp, level_script.cpp) read as text.
#include "test_util.h"
#include "coop_calls.h"
#include "coop_writer_rules.h"
#include "coop_mode.h"
#include "support/fake_mode.h"

#include <filesystem>
#include <fstream>
#include <iterator>
#include <regex>
#include <string>
#include <vector>

namespace w = coop::writer;
namespace c = coop::calls;

namespace
{
constexpr uint16_t kA = 5; // a led map
constexpr uint16_t kB = 7; // another led map
constexpr coop::PeerId kBridgeA = 101, kBridgeB = 102;

// The gated script writes of WP7 and what each does to its target.
struct Gated
{
	const char* name;
	w::WriteOp op;
};
const Gated kGated[] = {
	{"alife:create", w::WriteOp::Create},       {"alife:create_ammo", w::WriteOp::Create}, {"alife:register", w::WriteOp::Create},
	{"alife:clone_weapon", w::WriteOp::Create}, {"level:spawn_item", w::WriteOp::Create},  {"alife:release", w::WriteOp::Release},
	{"alife:give_info", w::WriteOp::Info},      {"alife:disable_info", w::WriteOp::Info},
};

const w::CodeScope kScopes[] = {w::CodeScope::LevelCode, w::CodeScope::Decision, w::CodeScope::Unknown};
const c::WriterGate kSettings[] = {c::WriterGate::Log, c::WriterGate::Enforce};

std::string gate_said(const std::string& at, c::Gate g) { return at + ": " + c::gate_name(g); }
#define GATE_EQ(at, got, want) CHECK_EQ(gate_said(at, got), gate_said(at, want))

std::string act_name(c::WriteAct a)
{
	switch (a)
	{
	case c::WriteAct::KeepCallGate: return "keep call gate";
	case c::WriteAct::Refuse: return "refuse";
	case c::WriteAct::Ask: return "ask";
	case c::WriteAct::Order: return "order";
	}
	return "?";
}
#define ACT_EQ(at, got, want) CHECK_EQ(std::string(at) + ": " + act_name(got), std::string(at) + ": " + act_name(want))

// Today's verdict of a co-op client for these calls, written out (MOD_LAYER §2.3 and coop_calls.h kCalls / kRequestPaths): every one is
// a world call with a request path for an own target only. A bad argument is refused even while applying; a host command being applied
// runs; an own target goes down the request path; another's is refused. The co-op host runs them all.
c::Gate golden_client(bool applying, bool own, bool args_ok)
{
	if (!args_ok)
		return c::Gate::Refuse;
	if (applying)
		return c::Gate::Run;
	return own ? c::Gate::Request : c::Gate::Refuse;
}

// The roots a co-op host's or client's write may name (their answers do not look at the facts: the host writes everything, a client
// asks its host).
const w::RootFacts kRoots[] = {
	{w::RootKind::Resident, 0x700, kA},
	{w::RootKind::Unit, 0x300, kA},
	{w::RootKind::Character, 0x12, kA},
	{w::RootKind::Character, w::kGhostId, kA},
	{w::RootKind::None, 0x900, w::kNoLevel},
};

std::string read_engine(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../engine/src/" + rel, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// The body of the function whose definition starts with `head` (the text between its braces, brace-matched); empty when not found.
std::string body_of(const std::string& src, const std::string& head)
{
	const size_t at = src.find(head);
	if (at == std::string::npos)
		return {};
	const size_t open = src.find('{', at);
	if (open == std::string::npos)
		return {};
	int depth = 0;
	for (size_t i = open; i < src.size(); ++i)
	{
		if (src[i] == '{')
			++depth;
		else if (src[i] == '}' && --depth == 0)
			return src.substr(open + 1, i - open - 1);
	}
	return {};
}

// `first` comes before `second` in `text` (both there).
bool before(const std::string& text, const std::string& first, const std::string& second)
{
	const size_t a = text.find(first), b = text.find(second);
	return a != std::string::npos && b != std::string::npos && a < b;
}
} // namespace

// ------------------------------------------------------------------------------------------------- the golden table (Coop)

TEST(writer_gate_golden_table_of_today)
{
	// today's calls::decide for every gated call, written out: a regression of the call matrix would show here first
	for (const Gated& g : kGated)
	{
		const c::CallClass cls = c::class_of(g.name);
		CHECK_EQ(std::string(g.name) + " " + c::class_name(cls), std::string(g.name) + " world");
		for (bool applying : {false, true})
			for (bool own : {false, true})
				for (bool args_ok : {false, true})
				{
					const std::string at = std::string(g.name) + (applying ? " applying" : "") + (own ? " own" : " another's") +
					    (args_ok ? "" : " bad args");
					GATE_EQ("host " + at, c::decide(cls, false, applying, own, c::has_request_path(g.name, own), args_ok), c::Gate::Run);
					GATE_EQ("client " + at, c::decide(cls, true, applying, own, c::has_request_path(g.name, own), args_ok),
					    golden_client(applying, own, args_ok));
				}
	}
}

TEST(writer_gate_coop_verdicts_identical_under_hostplay_answers)
{
	// the co-op host and a co-op client, with their answer sets: whatever the writer gate is asked, the call site keeps today's verdict,
	// in both settings (the host writes everything: Run; a client keeps today's verdict: Mirror)
	for (const char* name : {"coop_host", "coop_client"})
	{
		t::FakeMode m(t::mode_case(name));
		CHECK_EQ(std::string(m.name()), std::string(name));
		const w::ProcessKind kind = m.process().kind;
		const bool client = std::string(name) == "coop_client";
		CHECK(kind == (client ? w::ProcessKind::Mirror : w::ProcessKind::Whole));
		for (const Gated& g : kGated)
			for (const w::RootFacts& r : kRoots)
				for (w::CodeScope s : kScopes)
					for (c::WriterGate setting : kSettings)
						for (bool applying : {false, true})
							for (bool own : {false, true})
								for (bool args_ok : {false, true})
								{
									const c::Gate today =
									    c::decide(c::class_of(g.name), client, applying, own, c::has_request_path(g.name, own), args_ok);
									const c::WriteFacts f{kind, m.writer_of(r), s, false, c::is_ghost(r, m.actor_is_player()), false};
									const c::WriteDecision d = c::decide_writer_gate(f, g.op, today, setting);
									const std::string at = std::string(name) + " " + g.name + " " + c::writer_gate_name(setting);
									CHECK(d.verdict == (client ? w::GateVerdict::Mirror : w::GateVerdict::Run));
									ACT_EQ(at, d.act, c::WriteAct::KeepCallGate);
									GATE_EQ(at, d.gate, today);
									GATE_EQ(at, d.gate, client ? golden_client(applying, own, args_ok) : c::Gate::Run);
									CHECK(!c::census_counts(d.verdict));
									CHECK(!c::census_note(kind, f.writer, g.op, s, d.verdict).counted); // nothing counted in Coop
								}
		// a create with no parent: the new root is a resident or a unit of the host's map; the host writes it, a client asks
		for (c::Target t : {c::Target::NewResident, c::Target::NewUnit})
		{
			const w::Writer nw = c::new_root_writer(kind, t, false, m.writer_of(w::RootFacts{w::RootKind::Resident, w::kNoId, kA}));
			CHECK(nw.is == (client ? w::WriterIs::Other : w::WriterIs::This));
		}
	}
}

TEST(writer_gate_single_player_runs_everything)
{
	t::FakeMode m(t::mode_case("none"));
	CHECK(m.process().kind == w::ProcessKind::Whole);
	for (const Gated& g : kGated)
		for (w::CodeScope s : kScopes)
			for (c::WriterGate setting : kSettings)
			{
				const c::WriteFacts f{w::ProcessKind::Whole, m.writer_of(kRoots[0]), s, false, false, false};
				const c::WriteDecision d = c::decide_writer_gate(f, g.op, c::Gate::Run, setting);
				GATE_EQ(std::string("none ") + g.name, d.gate, c::Gate::Run);
			}
}

// ------------------------------------------------------------------------------------------------- the world server's rows

TEST(writer_gate_world_server_rows)
{
	t::FakeMode m(t::mode_case("world_server"));
	m.lead(kA, w::Lead::Leads, kBridgeA);
	const w::ProcessKind kind = m.process().kind;
	CHECK(kind == w::ProcessKind::World);
	const w::RootFacts box_on_a{w::RootKind::Resident, 0x700, kA};
	const w::Writer mk = m.writer_of(box_on_a);
	CHECK(mk.is == w::WriterIs::Other && mk.peer == kBridgeA);
	for (c::WriterGate setting : kSettings)
	{
		const bool enforce = setting == c::WriterGate::Enforce;
		for (w::WriteOp op : {w::WriteOp::Create, w::WriteOp::Release, w::WriteOp::State, w::WriteOp::Info})
		{
			// level code: that map server runs its own copy of it: refused (log: counted, today's runs)
			const c::WriteDecision lc = c::decide_writer_gate(c::WriteFacts{kind, mk, w::CodeScope::LevelCode, false, false, false}, op,
			    c::Gate::Run, setting);
			CHECK(lc.verdict == w::GateVerdict::Refuse);
			CHECK(c::census_counts(lc.verdict));
			ACT_EQ(std::string("level code ") + w::op_name(op), lc.act, enforce ? c::WriteAct::Refuse : c::WriteAct::KeepCallGate);
			GATE_EQ(std::string("level code ") + w::op_name(op), lc.gate, enforce ? c::Gate::Refuse : c::Gate::Run);
		}
		for (w::CodeScope s : {w::CodeScope::Decision, w::CodeScope::Unknown})
		{
			const std::string sn = c::scope_name(s);
			// a decision, or an unknown scope (counts as one on the world server): a create runs, the spawn goes down
			const c::WriteDecision cr =
			    c::decide_writer_gate(c::WriteFacts{kind, mk, s, false, false, false}, w::WriteOp::Create, c::Gate::Run, setting);
			CHECK(cr.verdict == w::GateVerdict::Run);
			GATE_EQ(sn + " create", cr.gate, c::Gate::Run);
			// release, state, info: the far order to that map server; no path in the engine yet: today's code, counted
			for (w::WriteOp op : {w::WriteOp::Release, w::WriteOp::State, w::WriteOp::Info})
			{
				const c::WriteDecision od = c::decide_writer_gate(c::WriteFacts{kind, mk, s, false, false, false}, op, c::Gate::Run, setting);
				CHECK(od.verdict == w::GateVerdict::Order);
				CHECK(c::census_counts(od.verdict));
				ACT_EQ(sn + " " + w::op_name(op), od.act, enforce ? c::WriteAct::Order : c::WriteAct::KeepCallGate);
				GATE_EQ(sn + " " + w::op_name(op), od.gate, c::Gate::Run);
			}
		}
		// its own objects (a unit at home, a box of a map nobody leads): run, nothing counted
		const w::Writer own = m.writer_of(w::RootFacts{w::RootKind::Resident, 0x701, kB});
		CHECK(own.is == w::WriterIs::This);
		for (w::CodeScope s : kScopes)
		{
			const c::WriteDecision d =
			    c::decide_writer_gate(c::WriteFacts{kind, own, s, false, false, false}, w::WriteOp::Release, c::Gate::Run, setting);
			CHECK(d.verdict == w::GateVerdict::Run);
			CHECK(!c::census_counts(d.verdict));
		}
	}
}

// ------------------------------------------------------------------------------------------------- a map server's rows

TEST(writer_gate_map_server_rows)
{
	t::FakeMode m(t::mode_case("map_server"));
	m.own_level(kA);
	m.lead(kA, w::Lead::Leads);
	const w::ProcessKind kind = m.process().kind;
	CHECK(kind == w::ProcessKind::Level);
	const w::Writer world = m.writer_of(w::RootFacts{w::RootKind::Unit, 0x300, kA}); // a squad at home in the world
	CHECK(world.is == w::WriterIs::Other);
	const w::Writer mine = m.writer_of(w::RootFacts{w::RootKind::Resident, 0x700, kA}); // a box of its map
	CHECK(mine.is == w::WriterIs::This);
	for (c::WriterGate setting : kSettings)
	{
		const bool enforce = setting == c::WriterGate::Enforce;
		for (w::CodeScope s : kScopes)
		{
			// its own map's object it does not write: release, info -> an ask to its world (no path in the engine yet: today's, counted)
			for (w::WriteOp op : {w::WriteOp::Release, w::WriteOp::Info})
			{
				const c::WriteDecision d = c::decide_writer_gate(c::WriteFacts{kind, world, s, true, false, false}, op, c::Gate::Run, setting);
				CHECK(d.verdict == w::GateVerdict::Ask);
				ACT_EQ(std::string("ask ") + w::op_name(op), d.act, enforce ? c::WriteAct::Ask : c::WriteAct::KeepCallGate);
				GATE_EQ(std::string("ask ") + w::op_name(op), d.gate, c::Gate::Run);
			}
			// create or state under a root it does not write, or anything on another map: refused
			for (w::WriteOp op : {w::WriteOp::Create, w::WriteOp::State})
			{
				const c::WriteDecision d = c::decide_writer_gate(c::WriteFacts{kind, world, s, true, false, false}, op, c::Gate::Run, setting);
				CHECK(d.verdict == w::GateVerdict::Refuse);
				GATE_EQ(std::string("own map ") + w::op_name(op), d.gate, enforce ? c::Gate::Refuse : c::Gate::Run);
			}
			for (w::WriteOp op : {w::WriteOp::Create, w::WriteOp::Release, w::WriteOp::State, w::WriteOp::Info})
			{
				const c::WriteDecision d = c::decide_writer_gate(c::WriteFacts{kind, world, s, false, false, true}, op, c::Gate::Run, setting);
				CHECK(d.verdict == w::GateVerdict::Refuse);
				// a create there is refused under Log as well: the world refuses its Spawn anyway (calls::world_refuses_anyway)
				GATE_EQ(std::string("another map ") + w::op_name(op), d.gate,
				    enforce || op == w::WriteOp::Create ? c::Gate::Refuse : c::Gate::Run);
			}
			// what it writes: run
			for (w::WriteOp op : {w::WriteOp::Create, w::WriteOp::Release, w::WriteOp::State, w::WriteOp::Info})
			{
				const c::WriteDecision d = c::decide_writer_gate(c::WriteFacts{kind, mine, s, true, false, false}, op, c::Gate::Run, setting);
				CHECK(d.verdict == w::GateVerdict::Run);
				GATE_EQ(std::string("its own ") + w::op_name(op), d.gate, c::Gate::Run);
			}
		}
	}
}

// cover_server (Dev 65 and 66): the map server of l05_bar ran a mod's create of a map marker on each of some 30 places of other maps
// (level code, alife_create_item); under Log every create ran, and the world refused each Spawn as not the writer ("Spawn of object 37003
// from map server 1 refused: not the writer"), its repair releasing it here a round trip later. A create on another map is refused in
// both settings; anything else under Log still runs, and so does a create at no map (a psy phantom: its maker's, writer::map_seat).
TEST(writer_gate_map_server_create_on_another_map_is_refused_in_both_settings)
{
	t::FakeMode m(t::mode_case("map_server"));
	m.own_level(kA);
	m.lead(kA, w::Lead::Leads);
	const w::ProcessKind kind = m.process().kind;
	const w::Writer elsewhere = m.writer_of(w::RootFacts{w::RootKind::Resident, w::kNoId, kB}); // a new root on another map
	CHECK(elsewhere.is == w::WriterIs::Other);
	for (c::WriterGate setting : kSettings)
		for (w::CodeScope s : kScopes)
		{
			const std::string at = std::string(c::writer_gate_name(setting)) + " " + c::scope_name(s);
			const c::WriteFacts f{kind, elsewhere, s, false, false, true};
			const c::WriteDecision cr = c::decide_writer_gate(f, w::WriteOp::Create, c::Gate::Run, setting);
			CHECK(cr.verdict == w::GateVerdict::Refuse);
			ACT_EQ("create " + at, cr.act, c::WriteAct::Refuse);
			GATE_EQ("create " + at, cr.gate, c::Gate::Refuse);
			CHECK(c::census_note(kind, elsewhere, w::WriteOp::Create, s, cr.verdict).counted); // still counted in coop_status
			// release, state, info there: Log keeps today's code (the gate's rule of those is the enforce step's)
			for (w::WriteOp op : {w::WriteOp::Release, w::WriteOp::State, w::WriteOp::Info})
			{
				const c::WriteDecision d = c::decide_writer_gate(f, op, c::Gate::Run, setting);
				GATE_EQ(std::string(w::op_name(op)) + " " + at, d.gate,
				    setting == c::WriterGate::Enforce ? c::Gate::Refuse : c::Gate::Run);
			}
			// on its own map, or at no map: not this exception
			for (bool own : {true, false})
			{
				const c::WriteDecision d =
				    c::decide_writer_gate(c::WriteFacts{kind, elsewhere, s, own, false, false}, w::WriteOp::Create, c::Gate::Run, setting);
				GATE_EQ(std::string(own ? "own map " : "no map ") + at, d.gate,
				    setting == c::WriterGate::Enforce ? c::Gate::Refuse : c::Gate::Run);
			}
		}
	// the world server, the co-op host and client never take this exception
	for (const w::ProcessKind other : {w::ProcessKind::World, w::ProcessKind::Whole, w::ProcessKind::Mirror})
	{
		const c::WriteFacts f{other, elsewhere, w::CodeScope::LevelCode, false, false, true};
		CHECK(!c::world_refuses_anyway(f, w::WriteOp::Create, w::GateVerdict::Refuse));
	}
	// the engine fills it from the root's map (coop_router.cpp writer_refuses)
	const std::string router = read_engine("xrGame/coop/coop_router.cpp");
	CHECK(router.find("const bool on_other_level = kind == writer::ProcessKind::Level && root.level != writer::kNoLevel && root.level != own;") !=
	    std::string::npos);
	CHECK(router.find("calls::is_ghost(root, mode().actor_is_player()), on_other_level};") != std::string::npos);
}

TEST(writer_gate_the_ghost)
{
	// W1.5, A9: nothing is created into actor 0 of the world server or a map server, no info is given to it
	const w::RootFacts ghost{w::RootKind::Character, w::kGhostId, kA};
	for (const char* name : {"world_server", "map_server"})
	{
		t::FakeMode m(t::mode_case(name));
		if (std::string(name) == "map_server")
			m.own_level(kA);
		m.lead(kA, w::Lead::Leads, kBridgeA);
		CHECK(c::is_ghost(ghost, m.actor_is_player()));
		const w::ProcessKind kind = m.process().kind;
		for (c::WriterGate setting : kSettings)
			for (w::CodeScope s : kScopes)
				for (w::WriteOp op : {w::WriteOp::Create, w::WriteOp::Info})
				{
					const c::WriteDecision d =
					    c::decide_writer_gate(c::WriteFacts{kind, m.writer_of(ghost), s, true, true, false}, op, c::Gate::Run, setting);
					CHECK(d.verdict == w::GateVerdict::Refuse);
					GATE_EQ(std::string(name) + " ghost " + w::op_name(op), d.gate,
					    setting == c::WriterGate::Enforce ? c::Gate::Refuse : c::Gate::Run);
				}
	}
	// a process whose actor plays has no ghost; neither has another character
	CHECK(!c::is_ghost(ghost, true));
	CHECK(!c::is_ghost(w::RootFacts{w::RootKind::Character, 0x12, kA}, false));
	CHECK(!c::is_ghost(w::RootFacts{w::RootKind::Unit, w::kGhostId, kA}, false));
}

TEST(writer_gate_refusal_needs_enforce_and_a_refuse)
{
	// the composition at the call site: only Refuse under enforce turns today's gate into Refuse
	for (c::Gate today : {c::Gate::Run, c::Gate::Request, c::Gate::Refuse})
		for (w::GateVerdict v : {w::GateVerdict::Run, w::GateVerdict::Mirror, w::GateVerdict::Refuse, w::GateVerdict::Ask,
			     w::GateVerdict::Order})
		{
			GATE_EQ(std::string("log ") + w::verdict_name(v), c::decide_write(today, c::write_act(v, c::WriterGate::Log)), today);
			const c::Gate enforced = c::decide_write(today, c::write_act(v, c::WriterGate::Enforce));
			GATE_EQ(std::string("enforce ") + w::verdict_name(v), enforced, v == w::GateVerdict::Refuse ? c::Gate::Refuse : today);
		}
}

// ------------------------------------------------------------------------------------------------- scope, new roots, setting

TEST(writer_gate_scope_of_router_domains)
{
	CHECK(c::scope_of_domain("host") == w::CodeScope::Decision);
	CHECK(c::scope_of_domain("HOST") == w::CodeScope::Decision);
	CHECK(c::scope_of_domain("level") == w::CodeScope::LevelCode);
	CHECK(c::scope_of_domain("owner") == w::CodeScope::LevelCode);
	CHECK(c::scope_of_domain("view") == w::CodeScope::LevelCode);
	CHECK(c::scope_of_domain("none") == w::CodeScope::Unknown);
	CHECK(c::scope_of_domain(c::kUnknownScope) == w::CodeScope::Unknown);
	CHECK(c::scope_of_domain("") == w::CodeScope::Unknown);
	CHECK(c::scope_of_domain("blocked") == w::CodeScope::Unknown);
	CHECK_EQ(std::string(c::scope_name(w::CodeScope::LevelCode)), std::string("level code"));
	CHECK_EQ(std::string(c::scope_name(w::CodeScope::Decision)), std::string("decision"));
	CHECK_EQ(std::string(c::scope_name(w::CodeScope::Unknown)), std::string("unknown"));
}

TEST(writer_gate_new_root_of_a_create_without_parent)
{
	const w::Writer mk = w::other(kBridgeA), world = w::other(coop::kHostPeer), here = w::this_process();
	// the world server: a unit it makes is its own (W1.d), a resident goes to whoever writes its map's residents
	CHECK(c::new_root_writer(w::ProcessKind::World, c::Target::NewUnit, false, mk) == here);
	CHECK(c::new_root_writer(w::ProcessKind::World, c::Target::NewResident, false, mk) == mk);
	CHECK(c::new_root_writer(w::ProcessKind::World, c::Target::NewResident, false, here) == here);
	// a map server: a unit it makes on its own map is born its own (W1.2b), even while it starts; never on another map
	CHECK(c::new_root_writer(w::ProcessKind::Level, c::Target::NewUnit, true, world) == here);
	CHECK(c::new_root_writer(w::ProcessKind::Level, c::Target::NewUnit, false, world) == world);
	CHECK(c::new_root_writer(w::ProcessKind::Level, c::Target::NewResident, true, here) == here);
	CHECK(c::new_root_writer(w::ProcessKind::Level, c::Target::NewResident, false, world) == world);
	// the co-op host, single player and a player's machine: the answer for the map's residents
	CHECK(c::new_root_writer(w::ProcessKind::Whole, c::Target::NewUnit, false, here) == here);
	CHECK(c::new_root_writer(w::ProcessKind::Mirror, c::Target::NewUnit, false, world) == world);
}

TEST(writer_gate_setting_names)
{
	c::WriterGate g = c::WriterGate::Enforce;
	CHECK(c::parse_writer_gate("log", g) && g == c::WriterGate::Log);
	CHECK(c::parse_writer_gate(" ENFORCE ", g) && g == c::WriterGate::Enforce);
	CHECK(!c::parse_writer_gate("on", g) && g == c::WriterGate::Enforce);
	CHECK(!c::parse_writer_gate("", g));
	CHECK_EQ(std::string(c::writer_gate_name(c::WriterGate::Log)), std::string("log"));
	CHECK_EQ(std::string(c::writer_gate_name(c::WriterGate::Enforce)), std::string("enforce"));
	// a process starts in log (it counts only) until its console command says otherwise: the router keeps the setting
	CHECK(read_engine("xrGame/coop/coop_router.cpp").find("std::atomic<calls::WriterGate> g_writer_gate{calls::WriterGate::Log};") !=
	      std::string::npos);
}

// ------------------------------------------------------------------------------------------------- the census

TEST(writer_gate_census_one_line_per_call_and_script)
{
	c::WriterCensus census;
	CHECK(census.note(c::CensusKind::Refuse, "alife:create", "sim_squad_scripted"));
	CHECK(!census.note(c::CensusKind::Refuse, "alife:create", "sim_squad_scripted"));
	CHECK(!census.note(c::CensusKind::Refuse, "alife:create", "sim_squad_scripted"));
	CHECK(census.note(c::CensusKind::Refuse, "alife:create", "xr_effects")); // another script: its own line
	CHECK(census.note(c::CensusKind::Order, "alife:create", "xr_effects")); // another verdict: its own line
	CHECK(census.note(c::CensusKind::Ask, "alife:release", "xcv_phantoms"));
	CHECK_EQ(census.totals().refuse, uint64_t(4));
	CHECK_EQ(census.totals().order, uint64_t(1));
	CHECK_EQ(census.totals().ask, uint64_t(1));
	CHECK_EQ(census.keys(), size_t(4));
	const std::vector<std::pair<std::string, uint64_t>> top = census.top(2);
	CHECK_EQ(top.size(), size_t(2));
	CHECK_EQ(top[0].first, std::string("refuse alife:create @ sim_squad_scripted"));
	CHECK_EQ(top[0].second, uint64_t(3));
	CHECK_EQ(top[1].second, uint64_t(1));
	CHECK(c::census_kind(w::GateVerdict::Refuse) == c::CensusKind::Refuse);
	CHECK(c::census_kind(w::GateVerdict::Ask) == c::CensusKind::Ask);
	CHECK(c::census_kind(w::GateVerdict::Order) == c::CensusKind::Order);
	census.clear();
	CHECK_EQ(census.keys(), size_t(0));
	CHECK(census.note(c::CensusKind::Refuse, "alife:create", "sim_squad_scripted")); // a new session: a new line
}

TEST(writer_gate_census_is_bounded)
{
	c::WriterCensus census;
	for (size_t i = 0; i < c::WriterCensus::kMaxKeys; ++i)
		CHECK(census.note(c::CensusKind::Refuse, "alife:create", "s" + std::to_string(i)));
	CHECK(!census.note(c::CensusKind::Refuse, "alife:create", "one_too_many")); // counted, no line, no key
	CHECK_EQ(census.keys(), c::WriterCensus::kMaxKeys);
	CHECK_EQ(census.dropped(), uint64_t(1));
	CHECK_EQ(census.totals().refuse, uint64_t(c::WriterCensus::kMaxKeys + 1));
}

// Verifier E finding 1 (§9.2, §2 row A): the census lists the world server's writes into a led level from code that may run on that
// level's map server as well. Such a create runs (the table's "decision, unknown: create -> Run"), so the verdicts alone (Refuse, Ask,
// Order) never named it: an unrouted path that doubles an item or a squad left the census at refuse 0 / ask 0 / order 0.
TEST(writer_gate_census_sees_world_creates_into_a_led_map)
{
	t::FakeMode m(t::mode_case("world_server"));
	m.lead(kA, w::Lead::Leads, kBridgeA);
	const w::ProcessKind kind = m.process().kind;
	const w::Writer mk = m.writer_of(w::RootFacts{w::RootKind::Resident, 0x700, kA}); // a box on a led map, or a new root there
	const w::Writer own = m.writer_of(w::RootFacts{w::RootKind::Resident, 0x701, kB}); // a map nobody leads: the world's own
	CHECK(mk.is == w::WriterIs::Other && own.is == w::WriterIs::This);
	for (c::WriterGate setting : kSettings)
	{
		const std::string sn = c::writer_gate_name(setting);
		// an unknown scope (a time event of no known scope, a C++ to Lua path) creating under a root a map server writes: it runs in
		// both settings, and the census names it
		const c::WriteDecision unknown =
		    c::decide_writer_gate(c::WriteFacts{kind, mk, w::CodeScope::Unknown, false, false, false}, w::WriteOp::Create, c::Gate::Run, setting);
		CHECK(unknown.verdict == w::GateVerdict::Run);
		GATE_EQ(sn + " unknown create into a led map", unknown.gate, c::Gate::Run);
		const c::CensusNote un = c::census_note(kind, mk, w::WriteOp::Create, w::CodeScope::Unknown, unknown.verdict);
		CHECK(un.counted);
		CHECK(un.kind == c::CensusKind::RunIntoLed);
		// level code making a new unit there: the unit is the world's own (new_root_writer), so it runs; that map's server runs the same
		// level code: counted, with the writer of the map (before new_root_writer) as the reason
		const c::WriteDecision first =
		    c::decide_writer_gate(c::WriteFacts{kind, mk, w::CodeScope::LevelCode, false, false, false}, w::WriteOp::Create, c::Gate::Run, setting);
		CHECK(first.verdict == w::GateVerdict::Refuse);
		const w::Writer unit_writer = c::new_root_writer(kind, c::Target::NewUnit, false, mk);
		const c::WriteDecision unit = c::decide_writer_gate(c::WriteFacts{kind, unit_writer, w::CodeScope::LevelCode, false, false, false},
		    w::WriteOp::Create, c::Gate::Run, setting);
		CHECK(unit.verdict == w::GateVerdict::Run);
		const c::CensusNote un2 = c::census_note(kind, mk, w::WriteOp::Create, w::CodeScope::LevelCode, unit.verdict);
		CHECK(un2.counted);
		CHECK(un2.kind == c::CensusKind::RunIntoLed);
		// a decision (the host domain, which the router keeps off the map server): the spawn goes down, nothing doubles, not counted
		const c::WriteDecision dec =
		    c::decide_writer_gate(c::WriteFacts{kind, mk, w::CodeScope::Decision, false, false, false}, w::WriteOp::Create, c::Gate::Run, setting);
		CHECK(dec.verdict == w::GateVerdict::Run);
		CHECK(!c::census_note(kind, mk, w::WriteOp::Create, w::CodeScope::Decision, dec.verdict).counted);
		// the world's own roots: never counted, whatever the scope
		for (w::CodeScope s : kScopes)
		{
			const c::WriteDecision d =
			    c::decide_writer_gate(c::WriteFacts{kind, own, s, false, false, false}, w::WriteOp::Create, c::Gate::Run, setting);
			CHECK(d.verdict == w::GateVerdict::Run);
			CHECK(!c::census_note(kind, own, w::WriteOp::Create, s, d.verdict).counted);
		}
		// a counted verdict keeps its own kind (an unknown release into a led map is an order)
		const c::WriteDecision rel =
		    c::decide_writer_gate(c::WriteFacts{kind, mk, w::CodeScope::Unknown, false, false, false}, w::WriteOp::Release, c::Gate::Run, setting);
		const c::CensusNote rn = c::census_note(kind, mk, w::WriteOp::Release, w::CodeScope::Unknown, rel.verdict);
		CHECK(rn.counted && rn.kind == c::CensusKind::Order);
		const c::CensusNote lc = c::census_note(kind, mk, w::WriteOp::Create, w::CodeScope::LevelCode, first.verdict);
		CHECK(lc.counted && lc.kind == c::CensusKind::Refuse);
	}
	// a map server's own creates on its map, and the processes that never reach the census: not counted
	{
		t::FakeMode mk_mode(t::mode_case("map_server"));
		mk_mode.own_level(kA);
		mk_mode.lead(kA, w::Lead::Leads);
		const w::Writer mine = mk_mode.writer_of(w::RootFacts{w::RootKind::Resident, 0x700, kA});
		CHECK(mine.is == w::WriterIs::This);
		for (w::CodeScope s : kScopes)
			CHECK(!c::census_note(w::ProcessKind::Level, mine, w::WriteOp::Create, s, w::GateVerdict::Run).counted);
	}
	for (w::CodeScope s : kScopes)
	{
		CHECK(!c::census_note(w::ProcessKind::Whole, w::other(kBridgeA), w::WriteOp::Create, s, w::GateVerdict::Run).counted);
		CHECK(!c::census_note(w::ProcessKind::Mirror, w::other(coop::kHostPeer), w::WriteOp::Create, s, w::GateVerdict::Mirror).counted);
	}
	// its own line and total in coop_status
	c::WriterCensus census;
	CHECK(census.note(c::CensusKind::RunIntoLed, "alife:create", "se_smart_terrain"));
	CHECK(!census.note(c::CensusKind::RunIntoLed, "alife:create", "se_smart_terrain"));
	CHECK(census.note(c::CensusKind::Refuse, "alife:create", "se_smart_terrain")); // another kind: its own line
	CHECK_EQ(census.totals().led, uint64_t(2));
	CHECK_EQ(census.totals().refuse, uint64_t(1));
	CHECK_EQ(std::string(c::census_name(c::CensusKind::RunIntoLed)), std::string("run into led"));
	CHECK_EQ(census.top(1)[0].first, std::string("run into led alife:create @ se_smart_terrain"));
}

// The engine half: writer_refuses counts through census_note with the writer of the root as Mode::writer_of gave it, before
// new_root_writer turned a new unit into the world's own (else the level-code squad on a led map would read as the world's write).
TEST(writer_gate_router_counts_what_runs_into_a_led_map)
{
	const std::string s = read_engine("xrGame/coop/coop_router.cpp");
	CHECK(!s.empty());
	const std::string b = body_of(s, "bool writer_refuses(const char* call, writer::WriteOp op, const calls::WriteTarget& target)");
	CHECK(!b.empty());
	CHECK(b.find("calls::census_note(") != std::string::npos);
	CHECK(b.find("census_counts(d.verdict)") == std::string::npos);
	CHECK(before(b, "const writer::Writer root_writer = mode().writer_of(root);", "calls::new_root_writer("));
	CHECK(before(b, "calls::new_root_writer(", "calls::census_note(kind, root_writer,"));
	const std::string status = body_of(s, "void print_status()");
	CHECK(status.find("c.led") != std::string::npos);
}

// Verifier E finding 3: the kind of a create with no parent is read from the section's class without building a scratch object (a
// script class's constructor, sim_squad_scripted:__init -> init_squad, evaluates a condlist), once per class.
TEST(writer_gate_kind_of_a_new_object_of_a_class)
{
	// a new creature lives (CSE_ALifeCreatureAbstract starts with health 1): a squad or a monster is a unit, anything else a resident
	CHECK(c::new_kind_of_class(true, false) == c::Target::NewUnit);
	CHECK(c::new_kind_of_class(false, true) == c::Target::NewUnit);
	CHECK(c::new_kind_of_class(false, false) == c::Target::NewResident);
	const std::string s = read_engine("xrGame/coop/coop_router.cpp");
	const std::string b = body_of(s, "calls::Target section_kind(const char* section)");
	CHECK(!b.empty());
	CHECK(b.find("r_clsid(section, \"class\")") != std::string::npos);
	CHECK(b.find("line_exist(section, \"class\")") != std::string::npos);
	// the answer kept per class first, then a live object of the class in this world; a scratch only when the world has none
	CHECK(before(b, "class_kinds.find(", "objects().objects()"));
	CHECK(before(b, "objects().objects()", "F_entity_Create("));
	CHECK(b.find("class_kinds.emplace(") != std::string::npos);
	CHECK(b.find("kind = class_kind(") != std::string::npos);
	const std::string k = body_of(s, "calls::Target class_kind(CSE_Abstract* e)");
	CHECK(k.find("calls::new_kind_of_class(") != std::string::npos);
}

// ------------------------------------------------------------------------------------------------- W9: no id left

TEST(writer_gate_no_id_left_decision)
{
	// the start of a create (a script create before any stock code, a new entity of a spawn packet) is refused under enforce
	CHECK(c::no_id(c::WriterGate::Enforce, c::IdStep::Start) == c::NoId::Refuse);
	// log: nothing is refused; the stock generator's id, logged loudly (the world refuses its Spawn, the repair releases it)
	CHECK(c::no_id(c::WriterGate::Log, c::IdStep::Start) == c::NoId::StockId);
	// a stock chain already running (the supplies of an object being made) cannot be refused by any caller: the stock callers dereference
	// what spawn_item returns (alife_monster_base.cpp, alife_trader_abstract.cpp)
	CHECK(c::no_id(c::WriterGate::Enforce, c::IdStep::Chain) == c::NoId::StockId);
	CHECK(c::no_id(c::WriterGate::Log, c::IdStep::Chain) == c::NoId::StockId);
}

TEST(writer_gate_perform_idgen_never_hands_out_a_silent_stock_id)
{
	const std::string h = read_engine("xrGame/xrServer.h");
	CHECK(!h.empty());
	const std::string gen = body_of(h, "IC u16 PerformIDgen(u16 ID)");
	CHECK(!gen.empty());
	// a map server asks its own pool first; an empty pool goes through the logged W9 step, never straight to the stock generator
	CHECK(before(gen, "own_free_id()", "CoopTookStockId("));
	CHECK(gen.find("if (ID == 0xffff)") != std::string::npos);
	// the start of a create is asked before (Process_spawn, the script paths): declared next to it
	CHECK(h.find("bool CoopMayCreate(const char* what);") != std::string::npos);
	CHECK(h.find("void CoopTookStockId(u16 id);") != std::string::npos);
}

TEST(writer_gate_process_spawn_refuses_before_any_id)
{
	const std::string s = read_engine("xrGame/xrServer_process_spawn.cpp");
	CHECK(!s.empty());
	const std::string spawn = body_of(s, "CSE_Abstract* xrServer::Process_spawn(");
	CHECK(!spawn.empty());
	// a new entity without an id is asked about before the phantom's or its own id is taken, and a refusal is the stock "not created"
	const size_t ask = spawn.find("CoopMayCreate(");
	const size_t first_id = spawn.find("PerformIDgen(");
	CHECK(ask != std::string::npos && first_id != std::string::npos && ask < first_id);
	const size_t destroy = spawn.find("F_entity_Destroy(E);", ask);
	const size_t null_back = spawn.find("return NULL;", ask);
	CHECK(destroy != std::string::npos && destroy < first_id);
	CHECK(null_back != std::string::npos && destroy < null_back && null_back < first_id);
	CHECK(spawn.find("!tpExistedEntity") != std::string::npos); // a switch online keeps its id: never asked
	const std::string may = body_of(s, "bool xrServer::CoopMayCreate(const char* what)");
	CHECK(!may.empty());
	CHECK(may.find("own_free_id()") != std::string::npos);
	CHECK(may.find("calls::no_id(") != std::string::npos);
	CHECK(may.find("IdStep::Start") != std::string::npos);
	const std::string took = body_of(s, "void xrServer::CoopTookStockId(u16 id)");
	CHECK(!took.empty());
	CHECK(took.find("calls::no_id(") != std::string::npos);
	CHECK(took.find("Msg(") != std::string::npos);
	// verifier E finding 5: under enforce a stock id is not only a stock chain's: a create that never asked CoopMayCreate (coop's own
	// C++ creates) takes one the same way, and the line must not name a cause it cannot know
	CHECK(took.find("did not ask CoopMayCreate") != std::string::npos);
	CHECK(took.find("? \"a stock chain that already runs (the supplies of an object being made)\"") == std::string::npos);
}

// Verifier E finding 4: alife():register(nil) is the stock "nothing" back, never a C++ access violation (under enforce create(..., false)
// returns nil in new cases: a writer refusal, an empty id pool; a script that hands it to register would take the process down).
TEST(writer_gate_register_of_nil_is_nothing)
{
	const std::string s = read_engine("xrGame/alife_simulator_script.cpp");
	const std::string reg = body_of(s, "CSE_Abstract* reprocess_spawn(CALifeSimulator* self, CSE_Abstract* object)");
	CHECK(!reg.empty());
	const size_t guard = reg.find("if (!object)");
	CHECK(guard != std::string::npos);
	CHECK(before(reg, "if (!object)", "coop_spawn_gate("));
	CHECK(before(reg, "if (!object)", "object->ID"));
	CHECK(guard != std::string::npos && reg.find("return nullptr;", guard) < reg.find("coop_spawn_gate("));
}

TEST(writer_gate_script_creates_ask_before_stock_code)
{
	const std::string s = read_engine("xrGame/alife_simulator_script.cpp");
	CHECK(!s.empty());
	struct Site
	{
		const char* head;
		const char* stock; // the first stock line that takes an id
	};
	// one helper asks the writer and the pool of a create, one runs the call gate and then that helper
	const std::string refused = body_of(s, "static bool coop_create_refused(CALifeSimulator* self");
	CHECK(before(refused, "coop_writer_refuses(", "CoopMayCreate("));
	CHECK(refused.find("WriteOp::Create") != std::string::npos);
	const std::string gated = body_of(s, "static coop::calls::Gate coop_create_gate(CALifeSimulator* self");
	CHECK(before(gated, "coop_spawn_gate(", "coop_create_refused("));
	const Site sites[] = {
		{"CSE_ALifeDynamicObject* CALifeSimulator__create(CALifeSimulator* self, ALife::_SPAWN_ID spawn_id)", "self->create(object, spawn, spawn_id);"},
		{"CSE_Abstract* CALifeSimulator__spawn_item(CALifeSimulator* self", "self->spawn_item("},
		{"CSE_Abstract* CALifeSimulator__spawn_item2(CALifeSimulator* self", "self->spawn_item("},
		{"CSE_Abstract* CALifeSimulator__spawn_ammo(CALifeSimulator* self", "self->spawn_item("},
		{"CSE_Abstract* try_to_clone_object(CALifeSimulator* self", "self->spawn_item("},
	};
	for (const Site& site : sites)
	{
		const std::string b = body_of(s, site.head);
		CHECK_EQ(std::string(site.head).substr(0, 40) + (b.empty() ? " missing" : " found"),
		    std::string(site.head).substr(0, 40) + " found");
		CHECK(before(b, "coop_create_", site.stock)); // coop_create_gate, or coop_create_refused after its own call gate
	}
	// spawn_item3 with reg goes to spawn_item2 before any gate (asked there, once); its own paths ask after that
	const std::string b3 = body_of(s, "CSE_Abstract* CALifeSimulator__spawn_item3(CALifeSimulator* self");
	CHECK(before(b3, "return CALifeSimulator__spawn_item2(", "coop_create_gate("));
	CHECK(b3.find("coop_spawn_gate(") == std::string::npos);
	CHECK(before(b3, "coop_create_gate(", "self->spawn_item("));
	// register makes no id of its own (create(..., false) took it): the writer gate only
	const std::string reg = body_of(s, "CSE_Abstract* reprocess_spawn(CALifeSimulator* self, CSE_Abstract* object)");
	CHECK(before(reg, "coop_writer_refuses(", "Process_spawn("));
	CHECK(reg.find("WriteOp::Create") != std::string::npos);
	// release and the infos
	const std::string rel = body_of(s, "void CALifeSimulator__release(CALifeSimulator* self, CSE_Abstract* object, bool)");
	CHECK(before(rel, "coop_writer_refuses(", "self->release(object, true);"));
	CHECK(rel.find("WriteOp::Release") != std::string::npos);
	for (const char* head : {"void AlifeGiveInfo(", "void AlifeRemoveInfo("})
	{
		const std::string b = body_of(s, head);
		CHECK(before(b, "coop_writer_refuses(", "known_info"));
		CHECK(b.find("WriteOp::Info") != std::string::npos);
	}
}

TEST(writer_gate_level_spawn_item_asks_the_writer)
{
	const std::string s = read_engine("xrGame/level_script.cpp");
	CHECK(!s.empty());
	const std::string b = body_of(s, "void spawn_section(LPCSTR sSection, Fvector3 vPosition, u32 LevelVertexID, u16 ParentID, bool bReturnItem");
	CHECK(!b.empty());
	CHECK(before(b, "writer_refuses(", "Level().spawn_item("));
	CHECK(b.find("WriteOp::Create") != std::string::npos);
}

// The setting can be switched: coop_writer_gate is registered with the other coop commands (coop_console.cpp, before user.ltx is
// read), and its value starts at log (the first build: the census only, nothing refused).
TEST(writer_gate_setting_is_a_registered_console_command)
{
	const std::string console = read_engine("xrGame/coop/coop_console.cpp");
	const std::string commands = body_of(console, "void register_console_commands()");
	CHECK(commands.find("router::register_console();") != std::string::npos);
	CHECK(console.find("#include \"coop_router.h\"") != std::string::npos);
	CHECK(read_engine("xrGame/coop/coop_router.h").find("void register_console();") != std::string::npos);
	const std::string router = read_engine("xrGame/coop/coop_router.cpp");
	CHECK(body_of(router, "void register_console()").find("CMD1(CCC_WriterGate, \"coop_writer_gate\");") != std::string::npos);
	CHECK(router.find("std::atomic<calls::WriterGate> g_writer_gate{calls::WriterGate::Log};") != std::string::npos);
}

// Review R32 B finding 4 / §8a A22: the world's and a map server's writer_of read join's peers, the session's peers, the seats and the
// map servers' books without a lock, and this gate asks it on the ALife thread (mt_alife: CALifeUpdateManager::update goes to
// Device.seqParallel). Safe only while the engine's frame keeps the two apart: seqParallel runs in XRay::Engine::GameThread, which
// CRenderDevice::on_idle starts after FrameMove (whose seqFrame runs coop::on_frame, where those books change: the network pump, the
// levels' frame) and joins before it returns; meanwhile the main thread only renders, and no coop code puts work there or on another
// parallel sequence. A change of the frame loop, or coop work beside the game thread, fails here before it races.
TEST(writer_gate_the_alife_thread_never_runs_beside_the_frame_that_changes_the_books)
{
	const std::string device = read_engine("xrEngine/device.cpp");
	const std::string idle = body_of(device, "void CRenderDevice::on_idle()");
	REQUIRE(!idle.empty());
	const size_t move = idle.find("FrameMove();");
	const size_t game = idle.find("secondary_tasks.run(&XRay::Engine::GameThread);");
	const size_t wait = idle.find("secondary_tasks.wait();");
	REQUIRE(move != std::string::npos && game != std::string::npos && wait != std::string::npos);
	CHECK(move < game);
	CHECK(game < wait);
	CHECK(idle.find("FrameMove();", move + 1) == std::string::npos); // one FrameMove a call, before the game thread
	CHECK(idle.substr(game, wait - game).find("return") == std::string::npos); // no way out between the start and the join
	CHECK(body_of(device, "void CRenderDevice::FrameMove()").find("Device.seqFrame.Process(rp_Frame);") != std::string::npos);

	// seqParallel runs in the game thread and nowhere else; with mt_alife the ALife update is put there
	const std::string threads = read_engine("xrEngine/EngineThreading.cpp");
	CHECK(body_of(threads, "void XRay::Engine::GameThread()").find("Device.seqParallel[pit]();") != std::string::npos);
	CHECK(device.find("seqParallel[") == std::string::npos);
	const std::string alife = read_engine("xrGame/alife_update_manager.cpp");
	const std::string sched = body_of(alife, "void CALifeUpdateManager::shedule_Update(u32 dt)");
	CHECK(sched.find("g_mt_config.test(mtALife)") != std::string::npos);
	CHECK(sched.find("Device.seqParallel.push_back(") != std::string::npos);

	// the books change in coop::on_frame: first in CGamePersistent::OnFrame, a member of the main thread's seqFrame
	CHECK(body_of(read_engine("xrGame/GamePersistent.cpp"), "void CGamePersistent::OnFrame()").find("coop::on_frame();") !=
	    std::string::npos);
	CHECK(read_engine("xrEngine/IGame_Persistent.cpp").find("RDEVICE.seqFrame.Add(this, REG_PRIORITY_HIGH + 1);") != std::string::npos);

	// no coop file puts work beside the game thread (the render side, a parallel sequence, the game thread's own frame)
	namespace fs = std::filesystem;
	std::string here = __FILE__;
	here.resize(here.find_last_of("\\/"));
	const std::regex beside(R"(seqRender\s*\.\s*Add|seqParallel|seqFrameMT|AddSeqFrame\s*\([^;]*,\s*true\s*\)|secondary_tasks)");
	std::vector<std::string> found;
	for (const char* dir : {"/../engine/src/xrGame/coop", "/../engine/src/xrCoop"})
		for (const fs::directory_entry& f : fs::recursive_directory_iterator(here + dir))
		{
			if (!f.is_regular_file() || (f.path().extension() != ".cpp" && f.path().extension() != ".h"))
				continue;
			std::ifstream in(f.path(), std::ios::binary);
			const std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
			const std::string code = std::regex_replace(text, std::regex(R"(//[^\n]*)"), " ");
			if (std::regex_search(code, beside))
				found.push_back(f.path().filename().string());
		}
	CHECK_EQ(found.size(), size_t(0));
	for (const std::string& name : found)
		CHECK_EQ(name, std::string("(no coop work beside the game thread)"));
}
