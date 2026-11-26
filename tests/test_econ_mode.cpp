// The engine handlers cannot be linked into this native test binary. Check their
// authority and placement guards in source, and exercise the answers under each mode.
#include "test_util.h"
#include "support/fake_mode.h"

#include <fstream>
#include <iterator>
#include <regex>

namespace
{
std::string econ_source(const char* name, const char* function = nullptr)
{
	const std::string here = __FILE__;
	const size_t slash = here.find_last_of("/\\");
	const std::string root = slash == std::string::npos ? "." : here.substr(0, slash) + "/..";
	std::ifstream in(root + "/engine/src/xrGame/coop/" + name);
	REQUIRE(in.good());
	std::ostringstream out;
	out << in.rdbuf();
	std::string source = out.str();
	if (function)
	{
		const size_t start = source.find(function);
		REQUIRE(start != std::string::npos);
		// These top-level engine functions close at the start of a line.
		const size_t end = source.find("\n}", start);
		REQUIRE(end != std::string::npos);
		source = std::regex_replace(source.substr(start, end - start), std::regex(R"(//[^\n]*)"), "");
	}
	return std::regex_replace(source, std::regex(R"(\s+)"), " ");
}

void check_guard(const std::string& source, const std::string& guard)
{
	if (source.find(guard) == std::string::npos)
		t::report_failure(__FILE__, __LINE__, "missing economy guard: " + guard);
}

void check_econ_answers(const char* name, bool leads_trade, bool decides_world, bool mirror,
    coop::Where placed, coop::Where away, coop::Where joining, bool has_level_side)
{
	using namespace coop;
	const t::ModeCase& row = t::mode_case(name);
	REQUIRE(std::string(row.name) == name);
	t::FakeMode mode(row);
	mode.place(7, t::Spot::Here);
	mode.place(8, t::Spot::Elsewhere);
	mode.place(9, t::Spot::Joining);

	CHECK_EQ(mode.leads_level(), leads_trade);
	CHECK_EQ(mode.decides_world(), decides_world);
	CHECK_EQ(mode.level() != nullptr, has_level_side);
	CHECK_EQ(has(mode.roles(), ProcessRole::Mirror), mirror);
	CHECK_EQ(mode.where(7), placed);
	CHECK_EQ(mode.where(8), away);
	CHECK_EQ(mode.where(9), joining);
}
} // namespace

TEST(econ_trade_is_judged_only_on_the_loaded_level)
{
	const std::string code = econ_source("coop_trade.cpp") + econ_source("coop_trade_views.cpp");
	check_guard(code, "case Op::Deal: if (mode().leads_level() && from != kHostPeer) host_on_deal");
	check_guard(code, "if (mode().leads_level()) host_on_container");
	check_guard(code, "if (!mode().leads_level() || id == kNoId)");
	check_guard(code, "if (!mode().leads_level() || !trade || !trade->pThis.inv_owner)");
	check_guard(code, "void send_container(bool open, u8 kind, u16 local_id) { if (mode().leads_level())");
	check_guard(code, "void print_status() { if (mode().leads_level())");
}

TEST(econ_ammo_and_leases_ask_for_player_placement)
{
	check_guard(econ_source("coop_items.cpp"), "op == Op::SpawnAmmo && mode().where(from) != Where::Away");
	check_guard(econ_source("coop_requests_leases.cpp"),
	    "sync::host_peer_joining(p.id) || mode().where(p.id) == Where::Away");
}

TEST(econ_equipment_carry_is_for_player_mirrors)
{
	const std::string code = econ_source("coop_equip.cpp");
	check_guard(code, "CActor* actor = is_mirror() && g_pGameLevel ?");
	check_guard(code, "if (g_pGameLevel && is_mirror() && join::client_loading_world()");
	check_guard(code, "if (!g_carry.have || !mgr().active() || !is_mirror() || !join::client_loading_world()");
}

TEST(econ_equipment_and_money_still_run_for_live_clients)
{
	const std::string equip = econ_source("coop_equip.cpp");
	check_guard(equip, "const bool live = mode().decides_world() || mgr().is_live_client();");
	check_guard(equip, "if (mode().decides_world() || mgr().is_live_client()) on_equip(from, r);");

	const std::string money = econ_source("coop_money.cpp");
	check_guard(money, "void frame() { if (mgr().is_live_client() || mode().decides_world())");
	check_guard(money, "void client_flush(bool paced) { if (!mgr().is_live_client() && !mode().decides_world()) return;");
}

TEST(econ_world_ledger_asks_for_remote_body_facts)
{
	check_guard(econ_source("coop_money.cpp"),
	    "dialog::host_lock_of(from) != kNoId || (mode().facts_of(join::proxy_of_peer(from), there) && there.talking)");
}

TEST(econ_level_balance_reads_keep_the_world_and_level_books_separate)
{
	const std::string code = econ_source("coop_money.cpp");
	check_guard(code, "if (const LevelSide* side = mode().level()) { "
	                  "if (arg_peer(L, 1, peer) && join::proxy_of_peer(peer) != kNoId) { "
	                  "side->level_balance(peer, balance); lua_pushnumber(L, lua_Number(balance)); } else lua_pushnil(L);");
	check_guard(code, "u32 host_balance(PeerId peer) { u32 balance = 0; "
	                  "if (const LevelSide* side = mode().level()) { side->level_balance(peer, balance); return balance; } "
	                  "const u16 holder = mode().decides_world() ? holder_of(peer) : kNoId;");
	check_guard(code, "int l_money_grant_to(lua_State* L) { if (!mode().decides_world())");
}

TEST(econ_level_balance_changes_and_requests_go_through_the_level_side)
{
	const std::string code = econ_source("coop_money.cpp");
	check_guard(code, "if (LevelSide* side = mode().level()) { side->level_money_change(peer, delta, trade); return true; } "
	                  "return adjust(peer, delta, why, trade ? Source::Trade : Source::Grant);");
	check_guard(code, "void host_send_balance(PeerId peer) { if (LevelSide* side = mode().level()) { "
	                  "side->level_money_change(peer, 0, false);");
	check_guard(econ_source("srv/coop_trunk.cpp"), "if (p.level == key().level) side->level_balance_heard(p.peer, p.money);");
}

TEST(econ_item_tell_keeps_the_item_state_broadcast_as_a_terminal_callback)
{
	const std::string tell = econ_source("coop_items.cpp", "void level_item_tell(");
	check_guard(tell, "void level_item_tell(u16 id, const std::string& section, "
	                  "const std::vector<u8>& blob) { Writer w(blob.size() + section.size() + 16); "
	                  "write_state(w, id, section.c_str(), 0, blob); net::host_broadcast(Msg::ItemState, w);");
	const std::regex broadcast(R"(net::host_broadcast\s*\()");
	CHECK_EQ(std::distance(std::sregex_iterator(tell.begin(), tell.end(), broadcast), std::sregex_iterator()), 1);

	const std::string loot = econ_source("srv/coop_levels_xfer.cpp", "void client_loot(");
	check_guard(loot, "items::level_item_tell(it->first, section, blob);");
	const std::regex callback(R"(items::level_item_tell\s*\()");
	CHECK_EQ(std::distance(std::sregex_iterator(loot.begin(), loot.end(), callback), std::sregex_iterator()), 1);
}

#define ECON_ANSWERS_coop_host true, true, false, Where::Here, Where::Here, Where::Joining, false
#define ECON_ANSWERS_coop_client false, false, true, Where::Here, Where::Here, Where::Here, false
#define ECON_ANSWERS_world_server false, true, false, Where::Away, Where::Away, Where::Joining, false
#define ECON_ANSWERS_map_server true, false, false, Where::Here, Where::Away, Where::Joining, true
#define ECON_ANSWERS_server_client false, false, true, Where::Here, Where::Away, Where::Here, false
#define ECON_ANSWERS_none false, false, false, Where::Away, Where::Away, Where::Away, false

#define ECON_MODE_TEST(name) \
	TEST(econ_mode_##name) \
	{ \
		using coop::Where; \
		check_econ_answers(#name, ECON_ANSWERS_##name); \
	}
MODE_CASES(ECON_MODE_TEST)
#undef ECON_MODE_TEST
