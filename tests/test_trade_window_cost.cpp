// Anomaly Coop unit tests: what a trade window rebuild costs on a client, read in the engine source. On a client every
// trade goes through the engine trade window (G.A.M.M.A.'s Lua window builds no engine cells), so its list fills are
// what a purchase costs (live 2026-10-29, b29: a hitch on every purchase at a G.A.M.M.A. trader).
#include "test_util.h"

#include <fstream>
#include <iterator>
#include <string>

namespace
{
// engine/src/xrGame/<name>, next to this source file (tests\ -> ..\engine\src\xrGame)
std::string game_source(const char* name)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../engine/src/xrGame/" + name, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// From `head` to the closing brace at column 0; "" if `head` is missing.
std::string function_body(const std::string& src, const std::string& head)
{
	const size_t at = src.find(head);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find("\n}", at);
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}
} // namespace

// Every cell with a condition_bar loaded actor_menu_item.xml and ran it through G.A.M.M.A.'s DXML in Lua.
TEST(trade_cell_condition_bar_xml_parsed_once)
{
	const std::string src = game_source("ui/UICellCustomItems.cpp");
	REQUIRE(src.size() > 5000);
	const std::string ctor = function_body(src, "CUIInventoryCellItem::CUIInventoryCellItem(CInventoryItem* itm)");
	REQUIRE(ctor.find("\"condition_bar\"") != std::string::npos);
	CHECK(ctor.find("static CUIXml") != std::string::npos);
	const size_t ready = ctor.find("if (!isXmlReady)");
	const size_t load = ctor.find("uiXml.Load(");
	CHECK(ready != std::string::npos && load != std::string::npos && ready < load);
}

// An accepted deal rebuilds the lists only for an item that did not arrive; a refused one still undoes the cells.
TEST(trade_accepted_deal_rebuilds_only_on_a_missing_item)
{
	const std::string src = game_source("coop/coop_trade.cpp");
	REQUIRE(src.size() > 20000);
	const std::string result = function_body(src, "void client_on_result(Reader& r)");
	REQUIRE(!result.empty());
	CHECK(result.find("kSettleMs") == std::string::npos);
	CHECK(result.find("on_container_move(kNoId, trader_local, di.id)") != std::string::npos);
	CHECK(result.find("on_container_move(kNoId, a->ID(), di.id)") != std::string::npos);
	CHECK(result.find("request_rebuild(now_ms()); // undo the optimistic move") != std::string::npos);
}

// Grouping cells: the cheap compare runs before the ini lookups of every pair.
TEST(trade_cell_grouping_compares_before_ini_lookups)
{
	const std::string src = game_source("ui/UIDragDropListEx.cpp");
	REQUIRE(src.size() > 5000);
	const std::string body = function_body(src, "CUICellItem* CUICellContainer::FindSimilar(CUICellItem* itm)");
	REQUIRE(!body.empty());
	const size_t equal = body.find("EqualTo(itm)");
	const size_t ini = body.find("dont_stack");
	CHECK(equal != std::string::npos && ini != std::string::npos && equal < ini);
}
