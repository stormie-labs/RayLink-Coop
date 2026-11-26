// Anomaly Coop unit tests: TZ R32 W8.3, uses in an entity's client_data in the exact stock format (coop_initial_rules.h).
// The stock writer and reader below are line-by-line transcriptions of the engine's (the engine itself does not link here):
//   CEatableItemObject::save = CPhysicItem::save (CPhysicsShellHolder::save: CGameObject::save writes nothing, then u8 enable state)
//                              then CEatableItem::save (CInventoryItem::save: u16 place, float condition, u8 0 for a held item;
//                              then u8 m_iRemainingUses)
//   CEatableItemObject::load = the same reads in the same order (CInventoryItem::load returns after a 0 sync-items count)
// NET_Packet::w_u16 / w_float / w_u8 write the raw little-endian bytes.
// WP6 fix round (finding 1): a scripted section (its binder's bytes follow the uses) takes the writer's own bytes of its object; with
// none, the world refuses the fact whole (no Applied for a half-applied one); a create with no object stages the uses.
#include "test_util.h"

#include "coop_initial_rules.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using namespace coop;

namespace
{
struct StockPacket // the part of NET_Packet the save uses
{
	std::vector<std::uint8_t> B;
	void w_u8(std::uint8_t v) { B.push_back(v); }
	void w_u16(std::uint16_t v)
	{
		B.push_back(std::uint8_t(v & 0xFF));
		B.push_back(std::uint8_t(v >> 8));
	}
	void w_float(float v)
	{
		std::uint8_t b[4];
		std::memcpy(b, &v, 4);
		B.insert(B.end(), b, b + 4);
	}
};

struct StockReader // the part of IReader the load uses
{
	const std::vector<std::uint8_t>& B;
	size_t pos = 0;
	std::uint8_t r_u8() { return B[pos++]; }
	std::uint16_t r_u16()
	{
		const std::uint16_t v = std::uint16_t(B[pos] | (B[pos + 1] << 8));
		pos += 2;
		return v;
	}
	float r_float()
	{
		float v;
		std::memcpy(&v, &B[pos], 4);
		pos += 4;
		return v;
	}
};

struct StockEatable // the fields of CEatableItemObject the save writes
{
	std::uint8_t st_enable_state = 2; // stNotDefitnite: no active shell (an item in an inventory)
	std::uint16_t place = 0;
	float condition = 1.f;
	bool has_parent = true;
	std::uint8_t remaining_uses = 0;

	void save(StockPacket& packet) const
	{
		// CPhysicsShellHolder::save
		packet.w_u8(st_enable_state);
		// CInventoryItem::save
		packet.w_u16(place);
		packet.w_float(condition);
		if (has_parent)
			packet.w_u8(0);
		// (an item on the ground would write its sync-items count and physics state here)
		// CEatableItem::save
		packet.w_u8(remaining_uses);
	}
	void load(StockReader& packet)
	{
		st_enable_state = packet.r_u8();
		place = packet.r_u16();
		condition = packet.r_float();
		const std::uint8_t tmp = packet.r_u8();
		has_parent = tmp == 0;
		remaining_uses = packet.r_u8();
	}
};
} // namespace

TEST(item_baseline_client_data_matches_the_stock_save)
{
	initial::HeldEatable h;
	h.place = 0;
	h.condition = 0.75f;
	h.uses = 1;
	StockEatable stock;
	stock.condition = 0.75f;
	stock.remaining_uses = 1;
	StockPacket p;
	stock.save(p);
	CHECK(initial::make_held_eatable(h) == p.B);
	CHECK_EQ(p.B.size(), initial::kHeldEatableSize);
}

TEST(item_baseline_client_data_round_trips_through_the_stock_load)
{
	initial::HeldEatable h;
	h.place = 0x0123;
	h.condition = 0.5f;
	h.uses = 2;
	const std::vector<std::uint8_t> cd = initial::make_held_eatable(h);
	StockEatable loaded;
	loaded.remaining_uses = 99;
	StockReader r{cd};
	loaded.load(r);
	CHECK_EQ(r.pos, cd.size());
	CHECK_EQ(int(loaded.remaining_uses), 2);
	CHECK_EQ(loaded.place, std::uint16_t(0x0123));
	CHECK(loaded.condition == 0.5f);
	CHECK(loaded.has_parent);
	CHECK_EQ(int(loaded.st_enable_state), int(initial::kEnableNotDefinite));
	initial::HeldEatable back;
	CHECK(initial::read_held_eatable(cd, back));
	CHECK_EQ(int(back.uses), 2);
	CHECK_EQ(back.place, std::uint16_t(0x0123));
}

TEST(item_baseline_uses_patch_the_stock_bytes_in_place)
{
	// The client_data a stock save left (place, enable state and the binder's bytes after it) keeps all but the uses.
	StockEatable stock;
	stock.st_enable_state = 1;
	stock.place = 0x0042;
	stock.condition = 0.9f;
	stock.remaining_uses = 3;
	StockPacket p;
	stock.save(p);
	p.w_u8(0xAB); // a binder's byte
	p.w_u8(0xCD);
	std::vector<std::uint8_t> cd = p.B;
	CHECK(initial::write_uses(cd, 1, nullptr, false));
	StockEatable loaded;
	StockReader r{cd};
	loaded.load(r);
	CHECK_EQ(int(loaded.remaining_uses), 1);
	CHECK_EQ(loaded.place, std::uint16_t(0x0042));
	CHECK_EQ(int(loaded.st_enable_state), 1);
	CHECK(loaded.condition == 0.9f);
	CHECK_EQ(cd.size(), p.B.size());
	CHECK_EQ(int(cd[cd.size() - 2]), 0xAB);
	CHECK_EQ(int(cd[cd.size() - 1]), 0xCD);
	const float cond = 0.25f;
	CHECK(initial::write_uses(cd, 0, &cond, false));
	StockReader r2{cd};
	loaded.load(r2);
	CHECK(loaded.condition == 0.25f);
	CHECK_EQ(int(loaded.remaining_uses), 0);
	std::uint8_t uses = 9;
	CHECK(initial::read_uses(cd, uses) && uses == 0);
}

TEST(item_baseline_empty_client_data_is_made_only_without_a_binder)
{
	std::vector<std::uint8_t> cd;
	CHECK(!initial::write_uses(cd, 2, nullptr, false)); // a section with a script binding: its binder's bytes would be missing
	CHECK(cd.empty());
	const float cond = 0.6f;
	CHECK(initial::write_uses(cd, 2, &cond, true));
	StockEatable loaded;
	StockReader r{cd};
	loaded.load(r);
	CHECK_EQ(int(loaded.remaining_uses), 2);
	CHECK(loaded.condition == 0.6f);
	CHECK_EQ(loaded.place, std::uint16_t(0)); // eItemPlaceUndefined: what a fresh object has
	CHECK_EQ(r.pos, cd.size());
}

TEST(item_baseline_an_item_on_the_ground_is_not_patched)
{
	// CInventoryItem::save of an item with no holder writes a non-zero count and its physics state: the uses byte is elsewhere.
	std::vector<std::uint8_t> cd = {2, 0, 0, 0, 0, 0x80, 0x3F, 1, 0x11, 0x22, 0x33, 4};
	const std::vector<std::uint8_t> before = cd;
	CHECK(!initial::is_held_eatable(cd));
	CHECK(!initial::write_uses(cd, 1, nullptr, true));
	CHECK(cd == before);
	std::uint8_t uses = 0;
	CHECK(!initial::read_uses(cd, uses));
	std::vector<std::uint8_t> shortcd = {2, 0, 0};
	CHECK(!initial::write_uses(shortcd, 1, nullptr, true));
}

// ---------------------------------------------------------------- WP6 fix round, finding 1: a scripted eatable on the world

namespace
{
// G.A.M.M.A.'s multi-use family inherits [booster_multi] (script_binding = bind_item.bind, max_uses 2..5: repair kits, vodka): its
// stock client_data is the eatable's save, then the Lua binder's bytes (save markers). A map server's object saves all of it.
std::vector<std::uint8_t> booster_multi_save(std::uint8_t uses, std::uint16_t place)
{
	StockEatable stock;
	stock.place = place;
	stock.condition = 0.8f;
	stock.remaining_uses = uses;
	StockPacket p;
	stock.save(p);
	p.w_u16(0x0002); // the binder's save marker and what its object_binder.save wrote
	p.w_u16(0x0004);
	return p.B;
}

// CGameObject::net_Save into a packet of its own: u16 chunk size, then the body.
std::vector<std::uint8_t> net_save_chunk(const std::vector<std::uint8_t>& body)
{
	std::vector<std::uint8_t> packet;
	packet.push_back(std::uint8_t(body.size() & 0xFF));
	packet.push_back(std::uint8_t(body.size() >> 8));
	packet.insert(packet.end(), body.begin(), body.end());
	return packet;
}
} // namespace

TEST(item_baseline_a_scripted_eatable_with_empty_client_data_takes_the_writers_bytes)
{
	// verify scenario: 2 of the 5 portions of a repair kit used on a map server; the world's entity of the player's kit has empty
	// client_data (a player's item came up from a map server) and the section has a script binding.
	const std::vector<std::uint8_t> body = booster_multi_save(3, 0x0005);
	const std::vector<std::uint8_t> packet = net_save_chunk(body);
	std::vector<std::uint8_t> stock;
	CHECK(initial::client_data_of_save(packet.data(), packet.size(), stock));
	CHECK(stock == body);
	std::vector<std::uint8_t> cd; // the world's
	CHECK(initial::uses_store(cd, &stock, 3, /*held*/ true, /*may_make*/ false) == initial::UsesStore::Stock);
	CHECK(initial::store_uses(cd, initial::UsesStore::Stock, &stock, 3, nullptr, false));
	CHECK_EQ(cd.size(), body.size());
	// The stock load reads the uses, the binder's bytes are all there, and the slot of the writer's copy is not taken.
	StockEatable loaded;
	StockReader r{cd};
	loaded.load(r);
	CHECK_EQ(int(loaded.remaining_uses), 3);
	CHECK(loaded.condition == 0.8f);
	CHECK_EQ(loaded.place, std::uint16_t(0));
	CHECK_EQ(r.pos, initial::kHeldEatableSize);
	CHECK(std::vector<std::uint8_t>(cd.begin() + initial::kHeldEatableSize, cd.end()) ==
	    std::vector<std::uint8_t>(body.begin() + initial::kHeldEatableSize, body.end()));
	// A client_data the world had already keeps its place.
	std::vector<std::uint8_t> had = booster_multi_save(5, 0x0102);
	const std::vector<std::uint8_t> fresh = booster_multi_save(2, 0x0005);
	CHECK(initial::uses_store(had, &fresh, 2, true, false) == initial::UsesStore::Stock);
	CHECK(initial::store_uses(had, initial::UsesStore::Stock, &fresh, 2, nullptr, false));
	StockReader r2{had};
	loaded.load(r2);
	CHECK_EQ(int(loaded.remaining_uses), 2);
	CHECK_EQ(loaded.place, std::uint16_t(0x0102));
}

TEST(item_baseline_without_the_writers_bytes_a_scripted_eatable_is_refused)
{
	// Nothing can be stored in the client_data: the store says Refuse and leaves it as it was (the caller stages the uses).
	std::vector<std::uint8_t> cd;
	CHECK(initial::uses_store(cd, nullptr, 3, true, false) == initial::UsesStore::Refuse);
	CHECK(!initial::store_uses(cd, initial::UsesStore::Refuse, nullptr, 3, nullptr, false));
	CHECK(cd.empty());
	// Bytes that do not fit the facts are no bytes of this state.
	const std::vector<std::uint8_t> other_uses = booster_multi_save(4, 0);
	CHECK(initial::uses_store(cd, &other_uses, 3, true, false) == initial::UsesStore::Refuse);
	const std::vector<std::uint8_t> ground = {2, 0, 0, 0, 0, 0x80, 0x3F, 1, 0x11, 0x22, 0x33, 4};
	CHECK(initial::uses_store(cd, &ground, 3, true, false) == initial::UsesStore::Refuse);
	const std::vector<std::uint8_t> good = booster_multi_save(3, 0);
	CHECK(initial::uses_store(cd, &good, 3, /*held*/ false, false) == initial::UsesStore::Refuse); // the world's item lies on the ground
	std::vector<std::uint8_t> too_long(initial::kMaxClientData + 1, 0);
	too_long[0] = 2;
	too_long[initial::kUsesAt] = 3;
	CHECK(initial::uses_store(cd, &too_long, 3, true, false) == initial::UsesStore::Refuse);
	// With no binder the world makes it, with a held client_data it patches it: as before.
	CHECK(initial::uses_store(cd, nullptr, 3, true, true) == initial::UsesStore::Make);
	std::vector<std::uint8_t> held = booster_multi_save(5, 0);
	CHECK(initial::uses_store(held, nullptr, 3, true, false) == initial::UsesStore::Patch);
	CHECK(initial::store_uses(held, initial::UsesStore::Patch, nullptr, 3, nullptr, false));
	CHECK_EQ(int(held[initial::kUsesAt]), 3);
}

TEST(item_baseline_the_chunk_of_a_net_save)
{
	std::vector<std::uint8_t> out;
	const std::vector<std::uint8_t> body = booster_multi_save(1, 0);
	std::vector<std::uint8_t> packet = net_save_chunk(body);
	CHECK(initial::client_data_of_save(packet.data(), packet.size(), out) && out == body);
	packet.push_back(0); // bytes after the chunk (a physics object's bones): not exactly the chunk
	CHECK(!initial::client_data_of_save(packet.data(), packet.size(), out));
	CHECK(out.empty());
	const std::uint8_t empty_chunk[2] = {0, 0};
	CHECK(!initial::client_data_of_save(empty_chunk, 2, out));
	CHECK(!initial::client_data_of_save(nullptr, 0, out));
	const std::uint8_t cut[3] = {5, 0, 1};
	CHECK(!initial::client_data_of_save(cut, 3, out));
}

// ---------------------------------------------------------------- read from the engine sources
namespace
{
std::string engine_src_dir()
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

std::string text_of(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	const std::string a = std::regex_replace(s.str(), std::regex(R"(//[^\n]*)"), " ");
	return std::regex_replace(a, std::regex(R"(\s+)"), " ");
}

std::string function_body(const std::string& code, const std::string& head)
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
	return depth ? "" : code.substr(start, i - 1 - start);
}

size_t where_in(const std::string& body, const std::string& what)
{
	const size_t p = body.find(what);
	if (p == std::string::npos)
		t::report_failure(__FILE__, __LINE__, "lacks: " + what);
	return p;
}
} // namespace

TEST(item_baseline_the_world_stages_uses_its_entity_cannot_keep)
{
	// host_take_item_facts decides the store before anything is written. What the entity cannot keep (a scripted section with no
	// client_data, an item on the ground: the map servers' loot of G.A.M.M.A. drinks and kits) waits in g_staged_uses for the item's
	// next spawn, as apply_to_entity does; the entry is taken, not refused, and the entity's client_data stays as it was.
	const std::string src = engine_src_dir();
	const std::string items = text_of(src + "/xrGame/coop/coop_items.cpp");
	const std::string facts = function_body(items, R"(bool\s+host_take_item_facts)");
	const size_t decide = where_in(facts, "const initial::UsesStore how = initial::uses_store(cd, stock, facts.uses, e->ID_Parent != 0xffff, may_make);");
	const size_t stage = where_in(facts, "stage = !initial::store_uses(cd, how, stock, facts.uses, &cond, may_make);");
	const size_t first_apply = where_in(facts, "apply_entity(e, facts, false);");
	const size_t staged = where_in(facts, "if (store && stage) stage_uses(id, facts.uses); else if (store) {");
	const size_t store = where_in(facts, "e->client_data.assign(cd.begin(), cd.end());");
	CHECK(decide < stage);
	CHECK(stage < first_apply);
	CHECK(first_apply < staged);
	CHECK(staged < store);
	CHECK(facts.find("the uses cannot be stored") == std::string::npos);
	where_in(facts, "const std::vector<u8>* stock = d.has_client_data ? &d.client_data : nullptr;");
	// The map server sends its held eatable's own bytes with the facts.
	const std::string state = function_body(items, R"(bool\s+level_item_state)");
	where_in(state, "attach_client_data(item, d);");
	const std::string attach = function_body(items, R"(void\s+attach_client_data)");
	where_in(attach, "item->object().CGameObject::net_Save(p);");
	where_in(attach, "initial::client_data_of_save(p.B.data, p.B.count, cd)");
	// The world's journal receiver: a false is a refusal.
	const std::string alife = text_of(src + "/xrGame/coop/srv/coop_levels_alife.cpp");
	const size_t facts_call = where_in(alife, ": items::host_take_item_facts(b.item, b.section.c_str(), b.blob.data(), b.blob.size(), no);");
	const size_t row = alife.find("if (!taken) return refuse(author, e.op, h.id, journal::Refused, why, no);", facts_call == std::string::npos ? 0 : facts_call);
	CHECK(row != std::string::npos);
	CHECK(row != std::string::npos && facts_call != std::string::npos && row - facts_call < 200);
}

TEST(item_baseline_a_create_with_no_object_stages_what_its_entity_cannot_keep)
{
	// set_initial / read_initial with no game object of a scripted eatable: the uses wait for the object (stock ItemProcessor does
	// the same), set the first frame it exists here, after its net_Spawn read the stock bytes; the spawn tail reads the staged value.
	const std::string src = engine_src_dir();
	const std::string items = text_of(src + "/xrGame/coop/coop_items.cpp");
	const std::string staged = function_body(items, R"(void\s+apply_staged_uses)");
	where_in(staged, "eat->SetRemainingUses(uses);");
	where_in(staged, "writer_set_staged(item, before, uses);");
	const std::string writer = function_body(items, R"(void\s+writer_set_staged)");
	where_in(writer, "decider_wrote(item, owner::Setter::Uses);");
	where_in(writer, "g_uses_history[id].record(latest.get(itemtags::Uses), int(uses) - int(before));");
	where_in(function_body(items, R"(void\s+frame)"), "apply_staged_uses();");
	const std::string state = text_of(src + "/xrGame/coop/coop_initial_state.cpp");
	where_in(function_body(state, R"(initial::State\s+state_of)"), "s.has_uses = staged_uses(e->ID, s.uses) || initial::read_uses(cd, s.uses);");
}
