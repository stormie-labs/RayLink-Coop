// Anomaly Coop unit tests (TZ R90): a player's trade window is the host's window. The engine files cannot be linked into this exe, so
// the wiring is read in their sources: CUIGameSP::StartTrade still asks coop::trade::lua_trade_window_allowed(), which lets a copy
// (is_mirror) have Anomaly's Lua window once scripts\coop_trade_window.script sends that window's trades to the decider
// (coop.trade_deal -> one TradeOp Deal), and the decider prices such a deal with the window's own Lua formula (host_price).
// The pure rules are in xrCoop/coop_trade_window_rules.h (test_trade_window_rules.cpp).
#include "test_util.h"

#include <fstream>
#include <iterator>
#include <regex>
#include <string>

namespace
{
// <root>/<path>, the root being this file's folder's parent (tests\ -> ..)
std::string repo_file(const std::string& path)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + path, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// From `head` to the closing brace at column 0, comments dropped, blanks squeezed; "" if `head` is missing.
std::string body_of(const std::string& src, const std::string& head)
{
	const size_t at = src.find(head);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find("\n}", at);
	std::string body = src.substr(at, end == std::string::npos ? std::string::npos : end - at);
	body = std::regex_replace(body, std::regex(R"(//[^\n]*)"), "");
	return std::regex_replace(body, std::regex(R"(\s+)"), " ");
}

bool has(const std::string& text, const char* what) { return text.find(what) != std::string::npos; }
} // namespace

// StartTrade keeps one question; the Lua window comes first, the engine window stays the fallback.
TEST(trade_window_start_trade_asks_the_coop_gate)
{
	const std::string src = repo_file("engine/src/xrGame/UIGameSP.cpp");
	REQUIRE(src.size() > 5000);
	const std::string start = body_of(src, "void CUIGameSP::StartTrade(");
	REQUIRE(!start.empty());
	const size_t gate = start.find("coop::trade::lua_trade_window_allowed()");
	const size_t lua = start.find("actor_menu_inventory.CUIActorMenu_OnMode_Trade");
	const size_t engine = start.find("SetMenuMode(mmTrade)");
	CHECK(gate != std::string::npos && lua != std::string::npos && gate < lua);
	CHECK(engine != std::string::npos && lua < engine);
}

// The gate: a copy gets the Lua window only when the Lua adapter says its trade buttons reach the decider; the log says which window.
TEST(trade_window_gate_asks_the_lua_adapter)
{
	const std::string src = repo_file("engine/src/xrGame/coop/coop_trade.cpp");
	REQUIRE(src.size() > 20000);
	const std::string gate = body_of(src, "bool lua_trade_window_allowed()");
	REQUIRE(!gate.empty());
	CHECK(!has(gate, "{ return !is_mirror(); }"));
	CHECK(has(gate, "is_mirror()"));
	CHECK(has(gate, "\"ready\""));
	CHECK(has(gate, "trade_window::choose("));
	CHECK(has(gate, "::Msg("));
}

// coop.trade_deal is the Lua window's way to the decider.
TEST(trade_window_lua_api_registers_trade_deal)
{
	const std::string src = repo_file("engine/src/xrGame/coop/coop_script.cpp");
	REQUIRE(src.size() > 20000);
	CHECK(has(src, "{\"trade_deal\", &coop::trade::lua_trade_deal}"));
	const std::string header = repo_file("engine/src/xrGame/coop/coop_trade.h");
	CHECK(has(header, "int lua_trade_deal(lua_State* L);"));
}

// The deal of a Lua window carries flag 2; the decider prices it with the window's formula, the engine window's deal as before.
TEST(trade_window_lua_deal_is_priced_by_the_window_formula)
{
	const std::string src = repo_file("engine/src/xrGame/coop/coop_trade.cpp");
	REQUIRE(src.size() > 20000);
	const std::string send = body_of(src, "void send_deal_locked(");
	CHECK(has(send, "kDealLuaPrices"));
	// the engine window's deals and the Lua window's queue go out under one lock, in the order of their seq
	const std::string engine_send = body_of(src, "void client_send_deal(");
	CHECK(has(engine_send, "std::lock_guard<std::mutex> lock(g_deal_lock);"));
	CHECK(has(engine_send, "send_queued_locked();"));
	const std::string on_deal = body_of(src, "void host_on_deal(PeerId from, Reader& r)");
	CHECK(has(on_deal, "kDealLuaPrices"));
	const std::string apply = body_of(src, "u8 host_apply(PeerId from, Deal& d, s64& delta)");
	REQUIRE(!apply.empty());
	CHECK(has(apply, "trade_window::pricing_of("));
	CHECK(has(apply, "CTrade pricing(trader);"));
	CHECK(has(apply, "lua_price_deal("));
	const std::string lua_price = body_of(src, "u8 lua_price_deal(");
	CHECK(has(lua_price, "ask_host_price(proxy_id, trader_id, d, raw, why)"));
	CHECK(has(lua_price, "trade_window::host_total("));
	const std::string ask = body_of(src, "bool ask_host_price(");
	CHECK(has(ask, "call_trade_window(\"host_price\""));
}

// R90 review, blocking 2 (protocol 35): a Lua window's deal carries the sums its window showed after the lists; the decider settles
// each side against them (trade_window::settle_side): a sale pays the smaller sum, a purchase costs the larger.
TEST(trade_window_lua_deal_carries_the_shown_sums)
{
	const std::string src = repo_file("engine/src/xrGame/coop/coop_trade.cpp");
	REQUIRE(src.size() > 20000);
	const std::string send = body_of(src, "void send_deal_locked(");
	REQUIRE(!send.empty());
	const size_t lists = send.find("write_list(w, deal.buy);");
	const size_t shown = send.find("if (deal.lua_prices) { w.u32(deal.sell_total); w.u32(deal.buy_total); }");
	CHECK(lists != std::string::npos && shown != std::string::npos && lists < shown);
	const std::string on_deal = body_of(src, "void host_on_deal(PeerId from, Reader& r)");
	CHECK(has(on_deal, "d.sell_shown = r.u32();"));
	CHECK(has(on_deal, "d.buy_shown = r.u32();"));
	const std::string lua_price = body_of(src, "u8 lua_price_deal(");
	CHECK(has(lua_price, "trade_window::settle_side(!d.sell.empty(), true,"));
	CHECK(has(lua_price, "trade_window::settle_side(!d.buy.empty(), false,"));
	CHECK(has(lua_price, "d.sell_shown"));
	CHECK(has(lua_price, "d.buy_shown"));
	// the window's sums come from the script (coop.trade_deal arguments 7 and 8: what the window showed, GetCellCost)
	const std::string deal = body_of(src, "int lua_trade_deal(lua_State* L)");
	CHECK(has(deal, "lua_type(L, 7) == LUA_TNUMBER"));
	CHECK(has(deal, "lua_type(L, 8) == LUA_TNUMBER"));
	const std::string header = repo_file("engine/src/xrGame/coop/coop_trade.h");
	CHECK(has(header, "u32 sell_shown, u32 buy_shown"));
}

// R90 review, blocking 1: G.A.M.M.A. binds Sell and Buy once, when the window is made (InitCallbacks); the adapter binds them again in
// ready(). That works because this engine's AddCallback replaces the binding of a control and event instead of adding a second one
// (the stock X-Ray kept the first).
TEST(trade_window_add_callback_replaces_a_binding)
{
	const std::string src = repo_file("engine/src/xrGame/ui/UIScriptWnd.cpp");
	REQUIRE(src.size() > 500);
	const std::string add = body_of(src, "void CUIDialogWndEx::AddCallback(");
	REQUIRE(!add.empty());
	const size_t replace = add.find("cb->m_callback.set(functor, object); return;");
	const size_t append = add.find("NewCallback();");
	CHECK(replace != std::string::npos && append != std::string::npos && replace < append);
	const std::string script = repo_file("gamedata/scripts/coop_trade_window.script");
	CHECK(has(script, "gui:AddCallback(\"sell\", clicked, cls.TMode_Sell, gui)"));
	CHECK(has(script, "gui:AddCallback(\"buy\", clicked, cls.TMode_Buy, gui)"));
}

// The answer reaches the Lua window (its buttons wait for it); the engine window's own handling stays.
TEST(trade_window_result_reaches_the_lua_window)
{
	const std::string src = repo_file("engine/src/xrGame/coop/coop_trade.cpp");
	const std::string result = body_of(src, "void client_on_result(Reader& r)");
	REQUIRE(!result.empty());
	CHECK(has(result, "deal.lua"));
	CHECK(has(result, "\"on_result\""));
	CHECK(has(result, "request_rebuild(now_ms());")); // the engine window undoes its optimistic move of the cells
}

// The Lua window tells the decider of the trader it shows (ReqContainer ContTrader: the trader's money, its items' states, a permit).
TEST(trade_window_lua_window_opens_the_trader)
{
	const std::string src = repo_file("engine/src/xrGame/coop/coop_trade.cpp");
	const std::string search = body_of(src, "int lua_search_window(lua_State* L)");
	REQUIRE(!search.empty());
	CHECK(has(search, "lua_isnumber(L, 2)"));
	const std::string frame = body_of(src, "static void search_frame()");
	REQUIRE(!frame.empty());
	CHECK(has(frame, "search_kind("));
	CHECK(has(frame, "search_step_kind("));
	const std::string items = repo_file("gamedata/scripts/coop_trade_window.script");
	CHECK(has(items, "search_window(gui.npc_id, TRADER_VIEW)"));
}

// The adapter is a Core script with the answers the engine asks for.
TEST(trade_window_lua_adapter_is_core)
{
	const std::string src = repo_file("gamedata/scripts/coop_trade_window.script");
	REQUIRE(src.size() > 2000);
	CHECK(src.rfind("-- \xD0\xAF\xD0\xB4\xD1\x80\xD0\xBE: ", 0) == 0); // "-- Ядро: " on the first line
	CHECK(has(src, "\nfunction ready("));
	CHECK(has(src, "\nfunction on_result("));
	CHECK(has(src, "\nfunction host_price("));
	CHECK(!has(src, "is_host(") && !has(src, "is_client("));
}
