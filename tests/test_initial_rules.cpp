// Anomaly Coop unit tests: TZ R32 W8.4, the initial state of an item that rides its create (coop_initial_rules.h).
// The wire layout is tested here, and the EntitySpawn tail that carries it (initial_state_rides_the_entity_spawn_tail, wired by WP5).
// WP6 fix round, finding 5: uses only for an eatable class.
#include "test_util.h"

#include "coop_initial_rules.h"
#include "coop_spawn.h"

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using namespace coop;

namespace
{
std::vector<std::uint8_t> written(const initial::State& s)
{
	Writer w;
	initial::write(w, s);
	return w.data();
}

bool read_back(const std::vector<std::uint8_t>& bytes, initial::State& s)
{
	Reader r(bytes.data(), bytes.size());
	return initial::read(r, s) && r.remaining() == 0;
}
} // namespace

TEST(initial_rules_the_tail_layout_round_trips_uses_and_condition)
{
	initial::State s;
	s.has_uses = true;
	s.uses = 1;
	s.has_cond = true;
	s.cond = initial::quant(0.5f);
	initial::State back;
	CHECK(read_back(written(s), back));
	CHECK(back.has_uses && back.uses == 1);
	CHECK(back.has_cond && back.cond == initial::quant(0.5f));
	CHECK(!back.has_ammo);
	CHECK_EQ(back.versions_mask, 0u);
	CHECK(initial::dequant(back.cond) > 0.4999f && initial::dequant(back.cond) < 0.5001f);
}

TEST(initial_rules_ammo_count_is_unchanged)
{
	initial::State s;
	s.has_ammo = true;
	s.ammo = 30;
	initial::State back;
	CHECK(read_back(written(s), back));
	CHECK(back.has_ammo && back.ammo == 30);
	CHECK(!back.has_uses && !back.has_cond);
	// A tail without ammo leaves the box as the spawn packet made it: has_ammo stays false.
	initial::State u;
	u.has_uses = true;
	u.uses = 2;
	CHECK(read_back(written(u), back));
	CHECK(!back.has_ammo);
}

TEST(initial_rules_nothing_is_one_byte)
{
	initial::State s;
	CHECK(s.empty());
	const std::vector<std::uint8_t> b = written(s);
	CHECK_EQ(b.size(), size_t(1));
	initial::State back;
	back.has_uses = true;
	CHECK(read_back(b, back));
	CHECK(back.empty());
}

TEST(initial_rules_the_decider_versions_ride_with_the_item)
{
	initial::State s;
	s.has_uses = true;
	s.uses = 3;
	s.versions.set(itemtags::Uses, 7);
	s.versions.set(itemtags::Cond, 2);
	s.versions_mask = itemtags::Uses | itemtags::Cond;
	initial::State back;
	CHECK(read_back(written(s), back));
	CHECK_EQ(back.versions_mask, std::uint32_t(itemtags::Uses | itemtags::Cond));
	CHECK_EQ(back.versions.get(itemtags::Uses), std::uint16_t(7));
	CHECK_EQ(back.versions.get(itemtags::Cond), std::uint16_t(2));
	CHECK_EQ(back.versions.get(itemtags::Main), std::uint16_t(0));
	// Versions alone (an item a script wrote, nothing else to say) are a state too.
	initial::State v;
	v.versions.set(itemtags::Cond, 1);
	v.versions_mask = itemtags::Cond;
	CHECK(!v.empty());
	CHECK(read_back(written(v), back));
	CHECK_EQ(back.versions.get(itemtags::Cond), std::uint16_t(1));
}

TEST(initial_rules_malformed_tails_are_refused_and_skipped)
{
	// Unknown flag: refused, the reader is past the body (what follows the tail still reads).
	{
		Writer w;
		w.varu(2);
		w.u8(0x40);
		w.u8(1);
		w.u16(0xBEEF);
		Reader r(w.ptr(), w.size());
		initial::State s;
		CHECK(!initial::read(r, s));
		CHECK(s.empty());
		CHECK_EQ(r.u16(), std::uint16_t(0xBEEF));
	}
	// Bytes left over in the body.
	{
		Writer w;
		w.varu(3);
		w.u8(initial::kHasUses);
		w.u8(1);
		w.u8(9);
		Reader r(w.ptr(), w.size());
		initial::State s;
		CHECK(!initial::read(r, s));
	}
	// Cut body.
	{
		Writer w;
		w.varu(3);
		w.u8(initial::kHasCond);
		w.u8(1);
		Reader r(w.ptr(), w.size());
		initial::State s;
		CHECK(!initial::read(r, s));
	}
	// A versions flag with an empty mask says nothing: refused.
	{
		Writer w;
		w.varu(2);
		w.u8(initial::kHasVersions);
		w.u8(0);
		Reader r(w.ptr(), w.size());
		initial::State s;
		CHECK(!initial::read(r, s));
	}
	// Longer than any initial state.
	{
		Writer w;
		w.varu(initial::kMaxInitial + 1);
		for (size_t i = 0; i < initial::kMaxInitial + 1; ++i)
			w.u8(0);
		Reader r(w.ptr(), w.size());
		initial::State s;
		CHECK(!initial::read(r, s));
		CHECK_EQ(r.remaining(), size_t(0));
	}
}

TEST(initial_rules_a_script_sets_uses_within_the_section)
{
	CHECK(initial::uses_ok(0, 2));
	CHECK(initial::uses_ok(2, 2));
	CHECK(!initial::uses_ok(3, 2));
	CHECK(!initial::uses_ok(256, 300));
	CHECK_EQ(initial::quant(-1.f), std::uint16_t(0));
	CHECK_EQ(initial::quant(2.f), std::uint16_t(65535));
}

// ---------------------------------------------------------------- WP6 fix round, finding 5: which sections have uses

TEST(initial_rules_only_an_eatable_class_has_uses)
{
	for (const char* c : {"II_MEDKI", "II_BANDG", "II_ANTIR", "II_FOOD", "II_BOTTL", "S_FOOD", "II_FOOD ", "II_FOOD	"})
		CHECK(initial::is_eatable_class(c));
	for (const char* c : {"WP_AK74", "W_AK74", "AMMO", "D_PDA", "D_CUSTOM", "ARTEFACT", "II_DOC", "II_ATTCH", "", "II_FOO", "ii_food"})
		CHECK(!initial::is_eatable_class(c));
	// Each eatable class has an entry in coop_spawn.h with a plain item entity.
	for (const char* c : {"II_MEDKI", "II_BANDG", "II_ANTIR", "II_FOOD", "II_BOTTL", "S_FOOD"})
	{
		const spawn::ClassRule* rule = spawn::class_rule(c);
		CHECK(rule != nullptr);
		if (rule)
		{
			CHECK(rule->cse == spawn::CseClass::Item);
			CHECK(rule->game == spawn::GameClass::InventoryItem);
		}
	}
}

TEST(initial_rules_a_weapons_client_data_looks_like_an_eatables)
{
	// Why the layout alone cannot say it (finding 5): CInventoryItem::save writes 0 for every held item, and CWeapon::save goes on
	// with iAmmoElapsed and more where an eatable has its uses byte. Only the class tells them apart.
	std::vector<std::uint8_t> weapon = {2, 0, 0, 0, 0, 0x80, 0x3F, 0, 30, 0, 0, 0, 1, 0, 0, 0, 0, 0};
	CHECK(initial::is_held_eatable(weapon));
	std::uint8_t uses = 0;
	CHECK(initial::read_uses(weapon, uses) && uses == 30); // what state_of read as "uses" before the class check
	CHECK(!initial::is_eatable_class("WP_AK74"));
}

// ---------------------------------------------------------------- read from the engine sources
namespace
{
std::string engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	std::ifstream probe(here + "/../engine/src/xrCoop/coop_initial_rules.h");
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

// // and /* */ comments dropped (good enough for the calls looked for here: no string literal holds them).
std::string without_comments(const std::string& src)
{
	const std::string a = std::regex_replace(src, std::regex(R"(/\*[\s\S]*?\*/)"), " ");
	return std::regex_replace(a, std::regex(R"(//[^\n]*)"), " ");
}

std::string collapse(const std::string& s)
{
	const std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

std::string body_of(const std::string& code, const std::string& head)
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
	return depth ? "" : collapse(code.substr(start, i - 1 - start));
}

void expect_in(const std::string& where, const std::string& body, const std::string& what)
{
	if (body.find(collapse(what)) == std::string::npos)
		t::report_failure(__FILE__, __LINE__, where + " lacks: " + what);
}
} // namespace

// R32 W8.4 (§8a A12, WP5): the EntitySpawn tail carries the item's initial state after the clone's replacement state. The two
// writers of that layout (write_spawn: the world's spawns and repairs; write_entity: a map server's journal Spawn) put it last, the
// one reader (client_on_spawn: a client, a map server, the world server taking a map server's spawn) reads it in that order.
TEST(initial_state_rides_the_entity_spawn_tail)
{
	// the order on the wire, as the three functions write and read it: the clone's varu-sized snapshot (none: 0), then the state
	initial::State s;
	s.has_uses = true;
	s.uses = 3;
	s.has_cond = true;
	s.cond = initial::quant(0.5f);
	Writer w;
	w.varu(0); // write_clone_initial of an item that is no magazined weapon
	initial::write(w, s);
	Reader r(w.data().data(), w.data().size());
	CHECK_EQ(r.varu(), uint64_t(0));
	initial::State back;
	CHECK(initial::read(r, back));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK(back.has_uses && back.uses == 3 && back.has_cond && back.cond == s.cond);

	const std::string src = engine_src();
	const std::string entities = without_comments(read_text(src + "/xrGame/coop/coop_entities.cpp"));
	expect_in("write_spawn", body_of(entities, R"(bool\s+write_spawn)"),
	    "return requests::write_clone_initial(w, e) && items::write_initial(w, e);");
	expect_in("write_entity", body_of(entities, R"(bool\s+write_entity)"),
	    "return requests::write_clone_initial(w, e) && items::write_initial(w, e);");
	const std::string spawn = body_of(entities, R"(void\s+client_on_spawn)");
	const size_t clone = spawn.find("requests::read_clone_initial(r, id, initial)");
	const size_t tail = spawn.find("if (!items::read_initial(r, nullptr)) return;");
	const size_t id = spawn.find("e->ID = alife_rw().server().PerformIDgen(id);");
	const size_t apply = spawn.find("items::read_initial(state, e);");
	const size_t registered = spawn.find("alife_rw().register_object(e, true);");
	CHECK(clone != std::string::npos && tail != std::string::npos && id != std::string::npos && apply != std::string::npos &&
	    registered != std::string::npos);
	CHECK(clone < tail); // the clone's snapshot first
	CHECK(id < apply); // into the new entity under its id (the versions and the staged uses are kept by id)
	CHECK(apply < registered); // before its object can come online: net_Spawn reads the stock bytes
	// a repeat: the writer's own state stands, a game object's too; an offline copy takes the writer's state and versions together
	// (verify-D finding 6, reconcile::repeat_takes_state)
	CHECK(spawn.find("reconcile::repeat_takes_state(writing::writes(id), game_object_here(id));") != std::string::npos);
	CHECK(spawn.find("items::read_initial(state, takes ? known : nullptr);") != std::string::npos);

	// and nobody else calls them: the layout has one writer pair and one reader
	namespace fs = std::filesystem;
	std::vector<std::string> callers;
	for (const fs::directory_entry& f : fs::recursive_directory_iterator(src))
	{
		if (!f.is_regular_file())
			continue;
		const std::string ext = f.path().extension().string();
		if (ext != ".cpp" && ext != ".h")
			continue;
		const std::string name = f.path().filename().string();
		if (name == "coop_initial_state.cpp" || name == "coop_initial_state.h")
			continue;
		const std::string text = read_text(f.path().string());
		if (text.find("write_initial") == std::string::npos && text.find("read_initial") == std::string::npos)
			continue; // the cheap look first: thousands of files
		if (std::regex_search(without_comments(text), std::regex(R"(\b(write_initial|read_initial)\s*\()")))
			callers.push_back(name);
	}
	CHECK_EQ(callers.size(), size_t(1));
	for (const std::string& c : callers)
		CHECK_EQ(c, std::string("coop_entities.cpp"));
}

TEST(initial_state_uses_only_for_an_eatable_section)
{
	// Finding 5 in the engine: the entity paths decide "has uses" by the section's class, as the object path does.
	const std::string src = engine_src();
	const std::string state = without_comments(read_text(src + "/xrGame/coop/coop_initial_state.cpp"));
	expect_in("state_of", body_of(state, R"(initial::State\s+state_of)"), "else if (!item && is_eatable_section(e->s_name))");
	const std::string apply = body_of(state, R"(bool\s+apply_to_entity)");
	expect_in("apply_to_entity", apply, "if (s.has_uses && !is_eatable_section(e->s_name)) { why = \"uses for a non-eatable\";");
	expect_in("apply_to_entity", apply, "if (s.has_uses && !entity_write_uses(e, s.uses)) stage_uses(e->ID, s.uses);");
	const std::string items = without_comments(read_text(src + "/xrGame/coop/coop_items.cpp"));
	expect_in("entity_write_uses", body_of(items, R"(bool\s+entity_write_uses)"),
	    "if (!ii || !is_eatable_section(e->s_name) || !initial::uses_ok(uses, section_max_uses(e->s_name))) return false;");
}
