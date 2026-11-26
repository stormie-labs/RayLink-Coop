// Anomaly Coop unit tests: R32 §8a A21 E-2 (WP12, Server), the stock roll of a reward copy the world server creates for a player
// whose map a map server leads.
// Before: coop_item_entity_state.script stages the ItemProcessor's roll (uses, condition, rounds) with coop.items.set_initial in the
// create's frame, and the world server, which does not write an item in the inventory of a player on a led map (the map server
// does), answered "not written here": that copy kept no roll.
// Now items::set_initial (xrGame/coop/coop_initial_state.cpp) also takes the creator's own create of this frame on a process that does
// not write the item: no game object of it here, and its Registered host event still queued, not one this process applied for
// another (entities::host_own_spawn_unsent). The state goes into the entity (versions_mask 0); the EntitySpawn the world sends at its
// next entities::frame carries it in its tail (write_spawn -> items::write_initial) to the map server that writes the item, whose
// client_on_spawn -> read_initial applies it to the new entity. Every other case keeps "not written here".
// Coop: the co-op host writes everything it creates (writer_of Whole: This), so the queue never changes its answer there: unchanged.
// The engine's files cannot run here: the pure parts run (initial::set_path, the writer answers, the tail), the wiring is read from the
// sources, as tests/test_initial_rules.cpp does.
#include "test_util.h"

#include "coop_initial_rules.h"
#include "coop_writer_rules.h"
#include "srv/coop_writer_seats.h"

#include <cstdint>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using namespace coop;

namespace
{
constexpr uint16_t kLedMap = 7; // the map the player stands on, led by a map server
constexpr uint16_t kGhostMap = 1; // the world server's own seat (the ghost on fake_start)
constexpr uint16_t kCharacter = 501; // the player's character
constexpr PeerId kPlayer = 3;
constexpr PeerId kBridge = 9; // the bridge of the map server of kLedMap, as the world server names it

// The world server's tables (srv/coop_writer_seats.h world_seat): the player stands on the led map, its server leads.
struct WorldTables
{
	PeerId player_of(uint16_t character) const { return character == kCharacter ? kPlayer : kInvalidPeer; }
	uint16_t seat_of(PeerId player) const { return player == kPlayer ? kLedMap : writer::kNoLevel; }
	uint16_t own_map() const { return kGhostMap; }
	writer::MapLead lead_of_map(uint16_t level) const
	{
		return level == kLedMap ? writer::MapLead{writer::Lead::Leads, kBridge} : writer::MapLead{};
	}
	PeerId holder_of(uint16_t) const { return kInvalidPeer; }
	uint16_t map_of_bridge(PeerId bridge) const { return bridge == kBridge ? kLedMap : writer::kNoLevel; }
	PeerId maker_of(uint16_t) const { return kInvalidPeer; }
};

// The map server's tables (map_seat): the player plays here.
struct MapTables
{
	bool plays_here(uint16_t character) const { return character == kCharacter; }
	bool authors(uint16_t) const { return false; }
	bool born(uint16_t) const { return false; }
	bool made_here(uint16_t) const { return false; }
};

// What set_initial answered before E-2: the writer only.
initial::SetPath before_e2(bool writes_here, bool object_here)
{
	if (!writes_here)
		return initial::SetPath::NotWrittenHere;
	return object_here ? initial::SetPath::Object : initial::SetPath::Entity;
}

bool writes(const writer::Writer& w) { return w.is == writer::WriterIs::This; }

// ------------------------------------------------------------------------------------------------ read from the engine sources
std::string e2_engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	return here + "/../engine/src";
}

std::string e2_read(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// // and /* */ comments dropped, whitespace collapsed (no string literal looked for here holds a comment marker).
std::string e2_collapse(const std::string& s)
{
	const std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

std::string e2_code(const std::string& src)
{
	const std::string a = std::regex_replace(src, std::regex(R"(/\*[\s\S]*?\*/)"), " ");
	return std::regex_replace(a, std::regex(R"(//[^\n]*)"), " ");
}

// The collapsed body of the first function whose head matches `head` (a regex up to the name).
std::string e2_body(const std::string& code, const std::string& head)
{
	std::smatch m;
	const std::regex rx(head + R"(\s*\([^;{]*\)\s*\{)");
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
	return depth ? "" : e2_collapse(code.substr(start, i - 1 - start));
}

size_t e2_at(const std::string& where, const std::string& body, const std::string& what)
{
	const size_t at = body.find(e2_collapse(what));
	if (at == std::string::npos)
		t::report_failure(__FILE__, __LINE__, where + " lacks: " + what);
	return at;
}
} // namespace

// The world server creates a reward copy in the inventory of a player on a led map and the script stages the stock roll in the same
// frame: set_initial takes it into the entity, and the EntitySpawn tail brings it whole to the map server that writes the item.
TEST(initial_set_e2_world_reward_copy_for_a_led_map_rides_the_spawn_tail)
{
	const writer::RootFacts item_root{writer::RootKind::Character, kCharacter, kLedMap};
	// the world does not write it: the map server of the player's map does
	const writer::Writer on_world = writer::world_answer(item_root, WorldTables{});
	CHECK(on_world == writer::other(kBridge));
	// its own create of this frame, no game object on the world (the character is offline there), the spawn not sent yet
	CHECK(initial::set_path(writes(on_world), false, true) == initial::SetPath::Entity);
	CHECK(before_e2(writes(on_world), false) == initial::SetPath::NotWrittenHere); // what it answered before

	// into the world's entity, as apply_to_entity stores it: a section with no script binding, no client_data yet (Make)
	const std::uint8_t rolled_uses = 2;
	const float rolled_cond = 0.85f;
	std::vector<std::uint8_t> world_cd;
	CHECK(initial::uses_store(world_cd, nullptr, rolled_uses, true, true) == initial::UsesStore::Make);
	CHECK(initial::store_uses(world_cd, initial::UsesStore::Make, nullptr, rolled_uses, &rolled_cond, true));

	// write_spawn at the world's next frame: the clone's snapshot (none), then state_of the entity
	initial::State sent;
	sent.has_cond = true;
	sent.cond = initial::quant(rolled_cond);
	sent.has_uses = initial::read_uses(world_cd, sent.uses);
	sent.versions_mask = 0; // set_initial sets values; the versions are the item engine's
	CHECK(sent.has_uses && sent.uses == rolled_uses);
	Writer tail;
	tail.varu(0);
	initial::write(tail, sent);

	// the map server: client_on_spawn reads the tail whole, read_initial applies it to the new entity before register_object
	Reader r(tail.data().data(), tail.data().size());
	CHECK_EQ(r.varu(), uint64_t(0));
	initial::State got;
	CHECK(initial::read(r, got));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK(got.has_uses && got.uses == rolled_uses);
	CHECK(got.has_cond && got.cond == initial::quant(rolled_cond));
	CHECK(!got.has_ammo && got.versions_mask == 0u);
	std::vector<std::uint8_t> map_cd;
	const float cond_there = initial::dequant(got.cond);
	CHECK(initial::store_uses(map_cd, initial::uses_store(map_cd, nullptr, got.uses, true, true), nullptr, got.uses, &cond_there, true));
	std::uint8_t uses_there = 0;
	CHECK(initial::read_uses(map_cd, uses_there) && uses_there == rolled_uses);

	// and there it is the writer's own item: its later set_initial goes the writer's way, whatever its queue holds
	const writer::Writer on_map = writer::map_answer(item_root, kLedMap, writer::Lead::Leads, MapTables{});
	CHECK(writes(on_map));
	for (const bool unsent : {false, true})
	{
		CHECK(initial::set_path(writes(on_map), false, unsent) == initial::SetPath::Entity);
		CHECK(initial::set_path(writes(on_map), true, unsent) == initial::SetPath::Object);
	}
}

// Once the world's EntitySpawn left (host_process_events drained the queue), the copy is the map server's: "not written here" again.
// The same for a game object here (a copy's object is never set) and for a player's machine (no host events at all).
TEST(initial_set_e2_after_the_spawn_left_the_world_answers_not_written_here)
{
	const writer::RootFacts item_root{writer::RootKind::Character, kCharacter, kLedMap};
	const bool world_writes = writes(writer::world_answer(item_root, WorldTables{}));
	CHECK(!world_writes);
	CHECK(initial::set_path(world_writes, false, false) == initial::SetPath::NotWrittenHere); // the spawn has left
	CHECK(initial::set_path(world_writes, true, true) == initial::SetPath::NotWrittenHere); // a game object here
	CHECK(initial::set_path(world_writes, true, false) == initial::SetPath::NotWrittenHere);
	// a player's machine (co-op client, server player): a copy of its host's; host_records() is false there, nothing is queued
	const writer::Writer mirror = writer::writer_of(item_root, writer::Process{writer::ProcessKind::Mirror, writer::kNoLevel, kHostPeer}, {});
	CHECK(mirror == writer::other(kHostPeer));
	CHECK(initial::set_path(writes(mirror), false, false) == initial::SetPath::NotWrittenHere);
	CHECK(initial::set_path(writes(mirror), true, false) == initial::SetPath::NotWrittenHere);
}

// Coop: the co-op host (and single player) is Whole and writes every object, so set_initial answers as before whatever the queue
// holds; and every case without an own unsent create keeps today's answer in every process.
TEST(initial_set_e2_the_coop_host_is_unchanged)
{
	const writer::Process whole{writer::ProcessKind::Whole, writer::kNoLevel, kHostPeer};
	for (const writer::RootKind kind :
	    {writer::RootKind::Character, writer::RootKind::Unit, writer::RootKind::Resident, writer::RootKind::None})
	{
		const writer::RootFacts root{kind, kCharacter, kLedMap};
		CHECK(writes(writer::writer_of(root, whole, {})));
	}
	for (const bool object_here : {false, true})
		for (const bool unsent : {false, true})
			CHECK(initial::set_path(true, object_here, unsent) == before_e2(true, object_here));
	for (const bool writes_here : {false, true})
		for (const bool object_here : {false, true})
			CHECK(initial::set_path(writes_here, object_here, false) == before_e2(writes_here, object_here));
}

// The wiring in the engine: set_initial asks the writer first and the queue only for an item with no game object here; the queue
// answers only for a Registered event this process did not apply for another; the queue leaves with the spawn.
TEST(initial_set_e2_set_initial_asks_the_queue_only_for_its_own_unsent_create)
{
	const std::string src = e2_engine_src();
	const std::string state = e2_code(e2_read(src + "/xrGame/coop/coop_initial_state.cpp"));
	const std::string set = e2_body(state, R"(bool\s+set_initial)");
	const size_t item = e2_at("set_initial", set, "CInventoryItem* const item = object_of(id);");
	const size_t path = e2_at("set_initial", set,
	    "const initial::SetPath path = initial::set_path(writing::writes(id), item != nullptr, entities::host_own_spawn_unsent(id));");
	const size_t refused = e2_at("set_initial", set, "if (path == initial::SetPath::NotWrittenHere) { why = \"not written here\";");
	const size_t object = e2_at("set_initial", set, "if (path == initial::SetPath::Object) {");
	const size_t entity = e2_at("set_initial", set, "entity_state.versions_mask = 0;");
	e2_at("set_initial", set, "return apply_to_entity(e, entity_state, why);");
	CHECK(item < path && path < refused && refused < object && object < entity);
	CHECK(set.find("if (!writing::writes(id))") == std::string::npos); // the old refusal of every non-writer is gone
	CHECK(state.find("#include \"coop_entities.h\"") != std::string::npos);

	const std::string entities = e2_code(e2_read(src + "/xrGame/coop/coop_entities.cpp"));
	const std::string unsent = e2_body(entities, R"(bool\s+host_own_spawn_unsent)");
	e2_at("host_own_spawn_unsent", unsent, "for (const HostEvent& ev : g_host_events)");
	e2_at("host_own_spawn_unsent", unsent, "if (ev.kind == HostEventKind::Registered && ev.id == id && !ev.applied) return true;");
	e2_at("host_own_spawn_unsent", unsent, "return false;");
	const std::string registered = e2_body(entities, R"(void\s+host_on_entity_registered)");
	const size_t mark = e2_at("host_on_entity_registered", registered, "ev.applied = g_applying > 0;");
	const size_t push = e2_at("host_on_entity_registered", registered, "g_host_events.push_back(ev);");
	CHECK(mark < push);
	const std::string process = e2_body(entities, R"(void\s+host_process_events)");
	const size_t swap = e2_at("host_process_events", process, "events.swap(g_host_events);");
	const size_t send = e2_at("host_process_events", process, "host_send_spawn(e);");
	CHECK(swap < send); // the queue is empty before the spawn goes: after it, the create is no longer unsent
	e2_at("write_spawn", e2_body(entities, R"(bool\s+write_spawn)"),
	    "return requests::write_clone_initial(w, e) && items::write_initial(w, e);");
	e2_at("frame", e2_body(entities, R"(void\s+frame)"), "host_process_events();");

	const std::string header = e2_code(e2_read(src + "/xrGame/coop/coop_entities.h"));
	CHECK(e2_collapse(header).find("bool host_own_spawn_unsent(u16 id);") != std::string::npos);
}
