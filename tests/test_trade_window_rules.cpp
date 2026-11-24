// Anomaly Coop unit tests (TZ R90): the pure rules of the trade window (xrCoop/coop_trade_window_rules.h) - which window a process
// shows, how a deal from Anomaly's Lua window is checked before it leaves, how the decider prices it, and what the Lua inventory
// tells the decider it shows. The window choice runs under every process kind (MODE_CASES): only a player's copy keeps the engine
// window, and only while the Lua adapter is not in place.
#include "test_util.h"
#include "support/fake_mode.h"

#include "coop_search_view.h"
#include "coop_trade_window_rules.h"

#include <cmath>
#include <limits>
#include <string>
#include <vector>

namespace
{
using namespace coop::trade_window;
constexpr uint16_t kNone = 0xffff;
constexpr size_t kMax = 1024;

void check_window_choice(const char* name, bool copy)
{
	const t::ModeCase& row = t::mode_case(name);
	REQUIRE(std::string(row.name) == name);
	const bool mirror = coop::has(row.answers.roles, coop::ProcessRole::Mirror);
	CHECK_EQ(mirror, copy);
	// without the adapter a copy keeps the engine window; every other process trades in the Lua window, as single player does
	CHECK(choose(mirror, false) == (copy ? Window::Engine : Window::Lua));
	// with it a copy gets the host's window too
	CHECK(choose(mirror, true) == Window::Lua);
	CHECK(std::string(why(mirror, false)).size() > 10);
	CHECK(std::string(why(mirror, true)) != std::string(why(mirror, false)) || !mirror);
}
} // namespace

#define TRADE_WINDOW_COPY_coop_host false
#define TRADE_WINDOW_COPY_coop_client true
#define TRADE_WINDOW_COPY_world_server false
#define TRADE_WINDOW_COPY_map_server false
#define TRADE_WINDOW_COPY_server_client true
#define TRADE_WINDOW_COPY_none false

#define TRADE_WINDOW_MODE_TEST(name) \
	TEST(trade_window_choice_##name) { check_window_choice(#name, TRADE_WINDOW_COPY_##name); }
MODE_CASES(TRADE_WINDOW_MODE_TEST)
#undef TRADE_WINDOW_MODE_TEST

TEST(trade_window_lists_are_checked_before_they_leave)
{
	const std::vector<uint16_t> none;
	CHECK(check_lists(none, none, false, kMax, kNone) == ListCheck::Empty);
	CHECK(check_lists({7}, none, false, kMax, kNone) == ListCheck::Ok);
	CHECK(check_lists(none, {8, 9}, false, kMax, kNone) == ListCheck::Ok);
	CHECK(check_lists({7}, {8}, false, kMax, kNone) == ListCheck::Ok); // a barter is one deal
	CHECK(check_lists({7, 7}, none, false, kMax, kNone) == ListCheck::Repeated);
	CHECK(check_lists({7}, {7}, false, kMax, kNone) == ListCheck::Repeated); // the same item on both sides
	CHECK(check_lists({7, kNone}, none, false, kMax, kNone) == ListCheck::BadId);
	CHECK(check_lists({7}, {8}, true, kMax, kNone) == ListCheck::GiftBuys); // a gift buys nothing
	CHECK(check_lists({7}, none, true, kMax, kNone) == ListCheck::Ok);
	std::vector<uint16_t> many;
	for (uint16_t i = 0; i < kMax; ++i)
		many.push_back(i);
	CHECK(check_lists(many, none, false, kMax, kNone) == ListCheck::Ok);
	CHECK(check_lists(many, {5000}, false, kMax, kNone) == ListCheck::TooMany);
	CHECK(std::string(list_check_name(ListCheck::Repeated)).size() > 3);
}

TEST(trade_window_lua_ids_are_whole_numbers_below_none)
{
	uint16_t id = 0;
	CHECK(id_of(7.0, kNone, id) && id == 7);
	CHECK(id_of(0.0, kNone, id) && id == 0);
	CHECK(!id_of(-1.0, kNone, id));
	CHECK(!id_of(7.5, kNone, id));
	CHECK(!id_of(65535.0, kNone, id));
	CHECK(!id_of(1e9, kNone, id));
	CHECK(!id_of(std::numeric_limits<double>::quiet_NaN(), kNone, id));
}

// TMode_UpdatePrice / TMode_Sell add the item prices up and floor once at the end.
TEST(trade_window_side_total_floors_once)
{
	uint32_t total = 99;
	CHECK(total_of({}, 1000, total) && total == 0);
	CHECK(total_of({0.4, 0.4, 0.4}, 1000, total) && total == 1); // not 0: one floor, not three
	CHECK(total_of({999.9}, 1000, total) && total == 999);
	CHECK(!total_of({600.0, 500.0}, 1000, total)); // over the most money there is
	CHECK(!total_of({-1.0}, 1000, total));
	CHECK(!total_of({std::numeric_limits<double>::quiet_NaN()}, 1000, total));
	CHECK(!total_of({std::numeric_limits<double>::infinity()}, 1000, total));
	CHECK_EQ(item_price(12.9), 12u);
	CHECK_EQ(item_price(-3.0), 0u);
	CHECK_EQ(item_price(std::numeric_limits<double>::quiet_NaN()), 0u);
}

TEST(trade_window_pricing_follows_the_flags)
{
	CHECK(pricing_of(true, false) == Pricing::Free);
	CHECK(pricing_of(true, true) == Pricing::Free); // a gift is free, whichever window
	CHECK(pricing_of(false, true) == Pricing::Lua);
	CHECK(pricing_of(false, false) == Pricing::Engine); // the engine window's deal, as before
	static_assert(kDealDonate == 1 && kDealLuaPrices == 2 && kDealFlags == 3, "TradeOp Deal flags (coop_trade.h)");
}

// What the decider makes of the Lua window's sum of one side (host_price): no answer, no number or nothing to pay for a list that
// is not empty refuses the deal; there is no fallback price.
TEST(trade_window_decider_total_of_a_side)
{
	const double nan = std::numeric_limits<double>::quiet_NaN();
	uint32_t out = 77;
	CHECK(host_total(false, true, 0.0, 1000, out) == PriceVerdict::Ok && out == 0);
	CHECK(host_total(false, false, nan, 1000, out) == PriceVerdict::Ok && out == 0); // an empty side costs nothing
	CHECK(host_total(true, false, 500.0, 1000, out) == PriceVerdict::NoAnswer);
	CHECK(host_total(true, true, nan, 1000, out) == PriceVerdict::BadNumber);
	CHECK(host_total(true, true, -5.0, 1000, out) == PriceVerdict::BadNumber);
	CHECK(host_total(true, true, 0.7, 1000, out) == PriceVerdict::Zero); // the window's button is off at 0 RU
	CHECK(host_total(true, true, 1500.0, 1000, out) == PriceVerdict::TooMuch);
	CHECK(host_total(true, true, 640.99, 1000, out) == PriceVerdict::Ok && out == 640);
	CHECK(std::string(price_verdict_name(PriceVerdict::Zero)).size() > 3);
}

// R90 review, blocking 2: the decider's formula and the player's window may disagree on a side. G.A.M.M.A.'s Weapon Parts Overhaul
// (a_wpo_parts.script) prices a part at the mechanic's own sale price when its owner's id is not 0: on the player's machine the actor
// (id 0) owns it and the window shows the worn price, on the decider his character does. A sale pays the smaller sum, a purchase costs
// the larger one: the player never gets more nor pays less than his window showed, nor than the decider's own price.
TEST(trade_window_settles_each_side_against_what_the_window_showed)
{
	uint32_t out = 7;
	// a worn prt_w_barrel_10 sold to a mechanic: the decider says 8250 RU (part_prices.ltx), the window showed 1237 RU
	CHECK(settle_side(true, true, 8250, 1237, out) == PriceVerdict::Ok && out == 1237);
	CHECK(settle_side(true, true, 900, 1000, out) == PriceVerdict::Ok && out == 900); // never over the decider's price
	CHECK(settle_side(true, true, 900, 900, out) == PriceVerdict::Ok && out == 900);
	CHECK(settle_side(true, false, 900, 500, out) == PriceVerdict::Ok && out == 900); // a purchase: never under the decider's price
	CHECK(settle_side(true, false, 900, 1000, out) == PriceVerdict::Ok && out == 1000); // nor under what the window showed
	CHECK(settle_side(false, true, 8250, 1237, out) == PriceVerdict::Ok && out == 0); // an empty side costs nothing
	CHECK(settle_side(false, false, 900, 1000, out) == PriceVerdict::Ok && out == 0);
	// the window's button is off at 0 RU: a sale the window showed for nothing is no sale
	CHECK(settle_side(true, true, 900, 0, out) == PriceVerdict::Zero && out == 0);
	CHECK(settle_side(true, false, 0, 0, out) == PriceVerdict::Zero && out == 0);
	// the window's sum travels as a whole number, floored once (total_of of the one sum)
	uint32_t shown = 0;
	CHECK(total_of({1237.0}, 0xffffffffu, shown) && shown == 1237);
	CHECK(total_of({1237.9}, 0xffffffffu, shown) && shown == 1237);
}

// What the Lua inventory shows of an object (coop.search_window(id, kind)): a box, a body, a trader in a trade window; the bag of a
// living companion is no view of the decider.
TEST(trade_window_search_kind)
{
	using namespace coop::trade;
	CHECK_EQ(search_kind(false, false, false, false, kViewTrader), kViewNone);
	CHECK_EQ(search_kind(true, true, false, false, kViewNone), kViewBox);
	CHECK_EQ(search_kind(true, false, true, false, kViewNone), kViewCorpse);
	CHECK_EQ(search_kind(true, false, true, false, kViewTrader), kViewNone); // a trader died under the trade window: no search
	CHECK_EQ(search_kind(true, true, false, false, kViewTrader), kViewNone); // a trade window shows no box
	CHECK_EQ(search_kind(true, false, true, true, kViewNone), kViewNone); // a companion's bag
	CHECK_EQ(search_kind(true, false, true, true, kViewTrader), kViewTrader);
	CHECK_EQ(search_kind(true, false, false, false, kViewTrader), kViewNone); // no inventory owner
}

TEST(trade_window_search_step_kind)
{
	using namespace coop::trade;
	const SearchStep same = search_step_kind(700, kViewTrader, 700, kViewTrader, kNone);
	CHECK(!same.open && !same.close);
	const SearchStep open = search_step_kind(kNone, kViewNone, 700, kViewTrader, kNone);
	CHECK(open.open && !open.close);
	const SearchStep changed = search_step_kind(700, kViewCorpse, 700, kViewTrader, kNone); // the same id, another view
	CHECK(changed.open && !changed.close);
	const SearchStep closed = search_step_kind(700, kViewTrader, kNone, kViewNone, kNone);
	CHECK(closed.close && !closed.open);
	// the old answer for a box keeps its meaning
	CHECK(search_step(700, 701, kNone).open);
}
