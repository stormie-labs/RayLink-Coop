// Anomaly Coop unit tests (TZ R90): the pure rules of the trade window (xrCoop/coop_trade_window_rules.h) - which window a process
// shows, how a deal from Anomaly's Lua window is checked before it leaves, how the decider checks its price (TZ R92: the shown sums
// within a tolerance of the decider's formula, either way), and what the Lua inventory
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

// TZ R92 (the owner's choice of 2026-11-25, "as in single player"): the player pays and gets exactly what his window showed. The decider
// compares its own formula's sum of each side with the shown one, the sale and the purchase alike: within the tolerance the side goes at
// the shown sum, beyond it, either way, the deal is refused (a modified client, or a sync fault that moved the client's price).
TEST(trade_window_settles_each_side_at_what_the_window_showed)
{
	uint32_t out = 7;
	const uint32_t one = tolerance_of(true, 1); // a Lua window's deal of one item: 1 RU of rounding + 1 RU for its condition
	CHECK_EQ(one, 2u);
	// a purchase dearer on the decider within the tolerance costs what was shown
	CHECK(settle_side(true, 902, 900, one, out) == PriceVerdict::Ok && out == 900);
	// a purchase cheaper on the decider within the tolerance costs what was shown too, not the decider's sum
	CHECK(settle_side(true, 898, 900, one, out) == PriceVerdict::Ok && out == 900);
	// a sale cheaper on the decider within the tolerance pays what was shown
	CHECK(settle_side(true, 998, 1000, one, out) == PriceVerdict::Ok && out == 1000);
	// a sale dearer on the decider within the tolerance pays what was shown too
	CHECK(settle_side(true, 1002, 1000, one, out) == PriceVerdict::Ok && out == 1000);
	CHECK(settle_side(true, 900, 900, one, out) == PriceVerdict::Ok && out == 900);
	// beyond the tolerance, either way, the deal is refused and nothing is paid
	CHECK(settle_side(true, 903, 900, one, out) == PriceVerdict::Changed && out == 0); // the trader asks more than shown
	CHECK(settle_side(true, 897, 900, one, out) == PriceVerdict::Changed && out == 0); // a sync fault made the shown price higher
	CHECK(settle_side(true, 900, 1000, one, out) == PriceVerdict::Changed && out == 0); // the trader pays less than shown
	CHECK(settle_side(true, 1100, 1000, one, out) == PriceVerdict::Changed && out == 0); // the shown sale was too cheap
	// a worn prt_w_barrel_10 sold to a mechanic: a modified window claims 8250 RU (part_prices.ltx), the decider prices it 1237 RU
	CHECK(settle_side(true, 1237, 8250, one, out) == PriceVerdict::Changed && out == 0);
	CHECK(settle_side(true, 8250, 1237, one, out) == PriceVerdict::Changed && out == 0);
	// an empty side costs nothing, whatever the sums
	CHECK(settle_side(false, 8250, 1237, one, out) == PriceVerdict::Ok && out == 0);
	CHECK(settle_side(false, 0, 0, one, out) == PriceVerdict::Ok && out == 0);
	// the window's button is off at 0 RU: a side shown for nothing is no deal, even within the tolerance
	CHECK(settle_side(true, 1, 0, one, out) == PriceVerdict::Zero && out == 0);
	CHECK(settle_side(true, 0, 0, one, out) == PriceVerdict::Zero && out == 0);
	CHECK(settle_side(true, 2, 1, one, out) == PriceVerdict::Ok && out == 1);
	// no overflow at the ends of a u32
	CHECK(settle_side(true, 0xffffffffu, 0, one, out) == PriceVerdict::Changed && out == 0);
	CHECK(settle_side(true, 0, 0xffffffffu, one, out) == PriceVerdict::Changed && out == 0);
	CHECK(settle_side(true, 0xfffffffeu, 0xffffffffu, one, out) == PriceVerdict::Ok && out == 0xffffffffu);
	CHECK(settle_side(true, 0, 0xffffffffu, 0xffffffffu, out) == PriceVerdict::Ok && out == 0xffffffffu);
	CHECK(std::string(price_verdict_name(PriceVerdict::Changed)).size() > 10);
	// the window's sum travels as a whole number, floored once (total_of of the one sum)
	uint32_t shown = 0;
	CHECK(total_of({1237.0}, 0xffffffffu, shown) && shown == 1237);
	CHECK(total_of({1237.9}, 0xffffffffu, shown) && shown == 1237);
}

// Review of 2026-11-25, TZ R92: the formula is the decider's, not the player's choice of flag. Its own window's (the G.A.M.M.A. formula)
// checks every deal it can: a Lua window's deal against the sums it showed, an engine window's deal (flag 0) against the CTrade sums,
// which that window showed. The CTrade sums alone stand only where the decider has no Lua formula at all (its gamedata is older).
TEST(trade_window_the_decider_picks_the_formula)
{
	CHECK(check_of(true, Answer::Priced) == Check::Compare);
	CHECK(check_of(false, Answer::Priced) == Check::Compare); // flag 0 is no way around the G.A.M.M.A. formula
	CHECK(check_of(true, Answer::Refused) == Check::Refuse);
	CHECK(check_of(false, Answer::Refused) == Check::Refuse); // an item the host's window would not trade (busted WPO parts)
	CHECK(check_of(true, Answer::NoFormula) == Check::Refuse); // no fallback price for a Lua window's deal
	CHECK(check_of(false, Answer::NoFormula) == Check::EngineOnly); // as before R90
	static_assert(kPriceChanged == 10, "TradeResult PriceChanged (coop_trade.cpp), RESULT_PRICE (coop_trade_window.script)");
}

// TZ R92: the engine window's refusal for its price tells the side beyond the tolerance, the purchase first, and in which direction; a
// side the decider prices better for the player than shown is a stale window, not a dearer trader.
TEST(trade_window_price_refusal_tells_the_side_beyond_the_tolerance)
{
	// the engine window's tolerance of one item is 4 RU
	CHECK(price_tell(false, 0, 1, 0, 910, 0, 900) == PriceTell::Purchase); // the trader asks more
	CHECK(price_tell(false, 0, 1, 0, 890, 0, 900) == PriceTell::Stale); // the window showed more than the trader asks
	CHECK(price_tell(false, 1, 0, 890, 0, 900, 0) == PriceTell::Sale); // the trader pays less
	CHECK(price_tell(false, 1, 0, 910, 0, 900, 0) == PriceTell::Stale); // the window showed less than the trader pays
	// a barter: the purchase within its tolerance, the sale beyond it: the sale is told
	CHECK(price_tell(false, 1, 1, 800, 902, 900, 900) == PriceTell::Sale);
	CHECK(price_tell(false, 1, 1, 800, 1000, 900, 900) == PriceTell::Purchase); // both beyond: the purchase first
	// a Lua window's tolerance of one item is 2 RU
	CHECK(price_tell(true, 0, 1, 0, 903, 0, 900) == PriceTell::Purchase);
	CHECK(price_tell(true, 0, 1, 0, 902, 0, 900) == PriceTell::Stale); // within: nothing to blame the trader for
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

// TZ R92: the tolerance of a side. A Lua window's deal: 1 RU of rounding of the sum and 1 RU an item for its condition (a u16 each way,
// coop_items.cpp:308-309). An engine window's deal: CTrade floors every item twice where the formula floors a side once, 2 RU an item
// more. The reviewer's lists of 2026-11-25 (the real host_total and CTrade's floors): 640 against 641, 7775 against 7777, 5820 against
// 5821 RU; without the allowance the engine window, which cannot show the decider's price, could buy nothing.
TEST(trade_window_tolerance_of_a_side)
{
	CHECK_EQ(tolerance_of(true, 0), kRoundingRu);
	CHECK_EQ(tolerance_of(true, 9), kRoundingRu + 9u);
	CHECK_EQ(tolerance_of(false, 0), kRoundingRu);
	CHECK_EQ(tolerance_of(false, 3), kRoundingRu + 9u);
	// saturates at the most a u32 holds, no overflow
	CHECK_EQ(tolerance_of(true, size_t(0xfffffffeu)), 0xffffffffu);
	CHECK_EQ(tolerance_of(true, size_t(0xffffffffu)), 0xffffffffu);
	CHECK_EQ(tolerance_of(false, size_t(0x55555554u)), 0xfffffffdu);
	CHECK_EQ(tolerance_of(false, size_t(0x55555555u)), 0xffffffffu);
	CHECK_EQ(tolerance_of(false, size_t(0x80000000u)), 0xffffffffu);
	uint32_t out = 7;
	CHECK(settle_side(true, 641, 640, tolerance_of(false, 1), out) == PriceVerdict::Ok && out == 640);
	CHECK(settle_side(true, 7777, 7775, tolerance_of(false, 2), out) == PriceVerdict::Ok && out == 7775);
	CHECK(settle_side(true, 5821, 5820, tolerance_of(false, 1), out) == PriceVerdict::Ok && out == 5820);
	// a Lua window's deal of 2 items: 3 RU either way
	CHECK(settle_side(true, 7778, 7775, tolerance_of(true, 2), out) == PriceVerdict::Ok && out == 7775);
	CHECK(settle_side(true, 7779, 7775, tolerance_of(true, 2), out) == PriceVerdict::Changed && out == 0);
	CHECK(settle_side(true, 7771, 7775, tolerance_of(true, 2), out) == PriceVerdict::Changed && out == 0);
	// the engine window's deal of 9 items: 28 RU either way; more than CTrade's floors can make is another price
	CHECK(settle_side(true, 928, 900, tolerance_of(false, 9), out) == PriceVerdict::Ok && out == 900);
	CHECK(settle_side(true, 929, 900, tolerance_of(false, 9), out) == PriceVerdict::Changed && out == 0);
	CHECK(settle_side(true, 872, 900, tolerance_of(false, 9), out) == PriceVerdict::Ok && out == 900);
	CHECK(settle_side(true, 871, 900, tolerance_of(false, 9), out) == PriceVerdict::Changed && out == 0);
	CHECK(settle_side(true, 1000, 900, tolerance_of(false, 9), out) == PriceVerdict::Changed && out == 0);
}
