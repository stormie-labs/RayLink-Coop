// Anomaly Coop unit tests (TZ R90): a player's trade window is the host's window. The engine files cannot be linked into this exe, so
// the wiring is read in their sources: CUIGameSP::StartTrade still asks coop::trade::lua_trade_window_allowed(), which lets a copy
// (is_mirror) have Anomaly's Lua window once scripts\coop_trade_window.script sends that window's trades to the decider
// (coop.trade_deal -> one TradeOp Deal), and the decider checks the sums that window showed, the deal's price (TZ R92), against the
// window's own Lua formula (host_price), computed as for the decider itself.
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

// The trade module: the deals, the views, the Lua window, and last the declarations they share (a head finds its definition first).
std::string trade_module()
{
	return repo_file("engine/src/xrGame/coop/coop_trade.cpp") + repo_file("engine/src/xrGame/coop/coop_trade_views.cpp") +
	    repo_file("engine/src/xrGame/coop/coop_trade_window_lua.cpp") + repo_file("engine/src/xrGame/coop/coop_trade_impl.h");
}
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
	const std::string src = trade_module();
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

// The deal of a Lua window carries flag 2; the decider checks it with the window's formula, the engine window's deal too (TZ R92).
TEST(trade_window_lua_deal_is_priced_by_the_window_formula)
{
	const std::string src = trade_module();
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
	const std::string ask = body_of(src, "trade_window::Answer ask_host_price(");
	CHECK(has(ask, "call_trade_window(\"host_price\""));
	// nothing at all (no script, no function) is told apart from a refusal (nil and why)
	CHECK(has(ask, "trade_window::Answer::NoFormula"));
	CHECK(has(ask, "trade_window::Answer::Refused"));
}

// Review of 2026-11-25, TZ R92: the formula is the decider's own window's, whichever flag came. The engine window's deal (flag 0) is
// priced with CTrade, which is what that window showed, and goes at it once the decider's Lua formula agrees within that window's
// tolerance. The Lua window's deal gets no new item check (item->CanTrade() of a stalker trader is can_sell: false NotTraded).
TEST(trade_window_engine_window_deal_meets_the_lua_formula_too)
{
	const std::string src = trade_module();
	REQUIRE(src.size() > 20000);
	const std::string apply = body_of(src, "u8 host_apply(PeerId from, Deal& d, s64& delta)");
	REQUIRE(!apply.empty());
	const size_t engine = apply.find("case trade_window::Pricing::Engine:");
	const size_t ctrade = apply.find("CTrade pricing(trader);", engine);
	const size_t shown = apply.find("d.sell_shown = d.sell_total;", ctrade);
	const size_t lua = apply.find("lua_price_deal(proxy_id, trader_id, d)", shown);
	CHECK(engine != std::string::npos && ctrade != std::string::npos && shown != std::string::npos && lua != std::string::npos);
	const size_t lua_case = apply.find("case trade_window::Pricing::Lua:");
	REQUIRE(lua_case != std::string::npos && lua_case < engine);
	const std::string lua_branch = apply.substr(lua_case, engine - lua_case);
	CHECK(has(lua_branch, "lua_price_deal(proxy_id, trader_id, d)"));
	CHECK(!has(lua_branch, "price_list(") && !has(lua_branch, "CanTrade"));
	const std::string lua_price = body_of(src, "u8 lua_price_deal(");
	CHECK(has(lua_price, "trade_window::check_of(d.lua_prices,"));
	CHECK(has(lua_price, "trade_window::Check::EngineOnly"));
	CHECK(has(lua_price, "return PriceChanged;"));
}

// Review of 2026-11-25: a refusal for its price carries the decider's prices of both sides (protocol 35, the same Dev build: no new
// number). TZ R92: for the log and the text only. The engine window's player is told the side beyond the tolerance (price_tell); the
// Lua window gets both prices (on_result keeps its signature) and tells its own text.
TEST(trade_window_price_refusal_carries_the_decider_prices)
{
	const std::string src = trade_module();
	REQUIRE(src.size() > 20000);
	CHECK(has(src, "PriceChanged = 10,"));
	CHECK(has(src, "static_assert(PriceChanged == trade_window::kPriceChanged"));
	const std::string send = body_of(src, "void host_send_result(PeerId to, const LastResult& r)");
	REQUIRE(!send.empty());
	const size_t money = send.find("w.u32(r.trader_money);");
	const size_t tail = send.find("if (r.code == PriceChanged) { w.u32(r.decider_sell); w.u32(r.decider_buy); }");
	CHECK(money != std::string::npos && tail != std::string::npos && money < tail);
	const std::string on_deal = body_of(src, "void host_on_deal(PeerId from, Reader& r)");
	CHECK(has(on_deal, "last.decider_sell = d.sell_decider;"));
	CHECK(has(on_deal, "last.decider_buy = d.buy_decider;"));
	const std::string result = body_of(src, "void client_on_result(Reader& r)");
	REQUIRE(!result.empty());
	const size_t read = result.find("if (code == PriceChanged) { decider_sell = r.u32(); decider_buy = r.u32(); }");
	const size_t ok = result.find("if (!r.ok()) return;");
	CHECK(read != std::string::npos && ok != std::string::npos && read < ok);
	CHECK(has(result, "if (!deal.lua) switch (trade_window::price_tell("));
	CHECK(has(result, "\"st_coop_trade_price_buy\""));
	CHECK(has(result, "\"st_coop_trade_price_sell\""));
	CHECK(has(result, "window_on_result(seq, code, delta, result_name(code), decider_sell, decider_buy);"));
	const std::string window = body_of(src, "void window_on_result(");
	CHECK(has(window, "lua_pushnumber(L, lua_Number(decider_sell));"));
	CHECK(has(window, "lua_pushnumber(L, lua_Number(decider_buy));"));
	const std::string header = repo_file("engine/src/xrGame/coop/coop_trade.h");
	CHECK(has(header, "code 10 only: u32 decider_sell, u32 decider_buy"));
	// both strings, English and Russian (windows-1251: "Сделка отменена")
	for (const char* lang : {"eng", "rus"})
	{
		const std::string xml = repo_file(std::string("gamedata/configs/text/") + lang + "/st_coop_economy.xml");
		REQUIRE(xml.size() > 1000);
		CHECK(has(xml, "<string id=\"st_coop_trade_price_buy\">"));
		CHECK(has(xml, "<string id=\"st_coop_trade_price_sell\">"));
		const size_t buy = xml.find("<string id=\"st_coop_trade_price_buy\">");
		const size_t end = xml.find("</string>", buy);
		CHECK(buy != std::string::npos && end != std::string::npos && xml.substr(buy, end - buy).find("%u") != std::string::npos);
	}
	const std::string rus = repo_file("gamedata/configs/text/rus/st_coop_economy.xml");
	CHECK(has(rus, "\xD1\xE4\xE5\xEB\xEA\xE0 \xEE\xF2\xEC\xE5\xED\xE5\xED\xE0"));
}

// Review of 2026-11-25 (TZ R92, lua_flow#1, lua_flow#2): a refusal for its price brings the trader's items and money ahead of the Result
// (host_send_trader_view, once per answer: a repeat sends the stored Result alone), so the Lua window takes the trader's data again
// without closing its view (a close revokes a trading computer's permit, whose grant is taken once). With the window closed, the Lua
// side tells the refusal on the HUD: the engine still tells no text for a Lua window's deal.
TEST(trade_window_price_refusal_sends_the_trader_first)
{
	const std::string src = trade_module();
	REQUIRE(src.size() > 20000);
	const std::string view = body_of(src, "void host_send_trader_view(PeerId to, u16 trader_id)");
	REQUIRE(!view.empty());
	CHECK(has(view, "if (sync::host_peer_joining(to) || !may_see_contents(to, ContTrader, trader_id)) return;"));
	const size_t contents = view.find("items::host_send_contents(to, trader_id);");
	const size_t money = view.find("host_send_trader_money(to, trader_id);");
	CHECK(contents != std::string::npos && money != std::string::npos && contents < money);
	const std::string send_money = body_of(src, "void host_send_trader_money(PeerId to, u16 trader_id)");
	const size_t write = send_money.find("write_trader_money(w, trader_id, trader->get_money());");
	const size_t send = send_money.find("net::host_send(to, Msg::TradeOp, w);");
	CHECK(write != std::string::npos && send != std::string::npos && write < send);
	const std::string on_deal = body_of(src, "void host_on_deal(PeerId from, Reader& r)");
	REQUIRE(!on_deal.empty());
	const size_t repeat = on_deal.find("if (last.have && d.seq == last.seq) { host_send_result(from, last); return; }");
	const size_t first = on_deal.find("if (code == PriceChanged) host_send_trader_view(from, d.trader);");
	const size_t answer = on_deal.rfind("host_send_result(from, last);");
	CHECK(repeat != std::string::npos && first != std::string::npos && answer != std::string::npos);
	CHECK(repeat < first && first < answer);
	// Re-review of 2026-11-25: "the trader's states before the Result" holds only while ItemState and TradeOp share one lane (the
	// default, Reliable): both sends name no lane.
	const std::string items_src = repo_file("engine/src/xrGame/coop/coop_items.cpp");
	REQUIRE(items_src.size() > 20000);
	const std::string state = body_of(items_src, "void host_send_state(PeerId to, u16 id)");
	REQUIRE(!state.empty());
	CHECK(has(state, "net::host_send(to, Msg::ItemState, w);"));
	CHECK(has(body_of(src, "void host_send_result(PeerId to, const LastResult& r)"), "net::host_send(to, Msg::TradeOp, w);"));
	// may_see_contents is defined before host_on_deal (the helper uses it)
	const size_t see = src.find("bool may_see_contents(PeerId from, u8 kind, u16 id)");
	CHECK(see != std::string::npos && see < src.find("void host_on_deal(PeerId from, Reader& r)"));
	const std::string script = repo_file("gamedata/scripts/coop_trade_window.script");
	REQUIRE(script.size() > 2000);
	CHECK(!has(script, "REOPEN_MS") && !has(script, "local reopen"));
	CHECK(has(script, "tell_on_hud(STALE_TEXT, STALE_FALLBACK)"));
	CHECK(has(script, "pcall(core.hud, text, fallback)"));
	// lua_flow#3: TMode_UpdatePrice is watched (its sum kept), never replaced by a price of the decider
	CHECK(has(script, "local function watch_price(cls)"));
	CHECK(has(script, "if moved_since_drawn(self, cc, shown) then return end"));
	const std::string result = body_of(src, "void client_on_result(Reader& r)");
	CHECK(has(result, "if (!deal.lua) switch (trade_window::price_tell("));
}

// R90 review, blocking 2 (protocol 35): a Lua window's deal carries the sums its window showed after the lists. TZ R92: they are its
// price; the decider compares each side with its own formula's sum within the tolerance (trade_window::settle_side, tolerance_of) and
// the side goes at the shown sum (settle_side's out is the deal's total).
TEST(trade_window_lua_deal_carries_the_shown_sums)
{
	const std::string src = trade_module();
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
	CHECK(has(lua_price, "trade_window::settle_side(!d.sell.empty(), decider[0], d.sell_shown, sell_tolerance, d.sell_total)"));
	CHECK(has(lua_price, "trade_window::settle_side(!d.buy.empty(), decider[1], d.buy_shown, buy_tolerance, d.buy_total)"));
	// the tolerance of the window that sent the deal (the engine window's CTrade sums floor twice an item)
	CHECK(has(lua_price, "trade_window::tolerance_of(d.lua_prices, d.sell.size())"));
	CHECK(has(lua_price, "trade_window::tolerance_of(d.lua_prices, d.buy.size())"));
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
	const std::string src = trade_module();
	const std::string result = body_of(src, "void client_on_result(Reader& r)");
	REQUIRE(!result.empty());
	CHECK(has(result, "deal.lua"));
	CHECK(has(result, "window_on_result("));
	CHECK(has(body_of(src, "void window_on_result("), "\"on_result\""));
	CHECK(has(result, "request_rebuild(mgr().now_ms());")); // the engine window undoes its optimistic move of the cells
}

// The Lua window tells the decider of the trader it shows (ReqContainer ContTrader: the trader's money, its items' states, a permit).
TEST(trade_window_lua_window_opens_the_trader)
{
	const std::string src = trade_module();
	const std::string search = body_of(src, "int lua_search_window(lua_State* L)");
	REQUIRE(!search.empty());
	CHECK(has(search, "lua_isnumber(L, 2)"));
	const std::string frame = body_of(src, "void search_frame()");
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

// TZ R92: the decider computes the window's formula as for itself: no player character put in (coop_npc_players.with_identity) and no
// item wrapped to look held by the actor (as_actors); the engine side of the contract (host_price -> two sums or nil and why) stays.
TEST(trade_window_decider_puts_no_player_character_in)
{
	const std::string src = repo_file("gamedata/scripts/coop_trade_window.script");
	REQUIRE(src.size() > 2000);
	// Lua comments dropped: long ones (--[[ ]], --[==[ ]==]) first, then the rest of a line after --
	const std::string no_long = std::regex_replace(src, std::regex(R"(--\[(=*)\[[\s\S]*?\]\1\])"), "");
	const std::string code = std::regex_replace(no_long, std::regex(R"(--[^\n]*)"), "");
	CHECK(has(code, "\nfunction host_price("));
	CHECK(!has(code, "with_identity"));
	CHECK(!has(code, "as_actors"));
}
