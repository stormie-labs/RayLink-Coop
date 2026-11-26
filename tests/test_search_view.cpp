// Anomaly Coop unit tests: when the host hears of a search in the Lua inventory (xrCoop/coop_search_view.h; coop_trade_views.cpp search_frame sends
// what these answers ask for).
#include "test_util.h"

#include "coop_search_view.h"

using namespace coop::trade;

namespace
{
constexpr uint16_t kNone = 0xffff;
}

TEST(search_step_nothing_while_nothing_changes)
{
	CHECK(!search_step(kNone, kNone, kNone).open);
	CHECK(!search_step(kNone, kNone, kNone).close);
	CHECK(!search_step(700, 700, kNone).open);
	CHECK(!search_step(700, 700, kNone).close);
}

TEST(search_step_a_window_opens)
{
	const SearchStep s = search_step(kNone, 700, kNone);
	CHECK(s.open);
	CHECK(!s.close);
}

TEST(search_step_a_window_closes)
{
	const SearchStep s = search_step(700, kNone, kNone);
	CHECK(s.close);
	CHECK(!s.open);
}

TEST(search_step_the_next_window_takes_the_place_of_the_last)
{
	const SearchStep s = search_step(700, 701, kNone);
	CHECK(s.open);
	CHECK(!s.close);
}
