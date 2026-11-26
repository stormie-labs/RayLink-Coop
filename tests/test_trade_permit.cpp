// Anomaly Coop unit tests: remote trade through a concrete trading computer (Dev 57 G6-3, review m23:3, Gadgets for Hideout
// Furniture). xrCoop/coop_trade_permit.h: the decider's permit (player, computer, trader, expiry, reach), the window rule of the
// player's machine, and the bounds of every number that comes out of Lua. The wiring in coop_trade.cpp is read in the source
// (the engine is not built here), like test_trade_window_cost.cpp does.
#include "test_util.h"

#include "coop_trade_permit.h"

#include <cmath>
#include <fstream>
#include <iterator>
#include <limits>
#include <regex>
#include <string>

using namespace coop::trade_permit;

namespace
{
constexpr uint32_t kPlayer = 1;
constexpr uint32_t kOther = 2;
constexpr uint16_t kComputer = 900;
constexpr uint16_t kTrader = 700;
constexpr uint64_t kNow = 100000;
constexpr uint64_t kTtl = 60000;

Facts facts(uint32_t player, uint16_t trader, uint64_t now, float to_computer)
{
	Facts f;
	f.player = player;
	f.trader = trader;
	f.now = now;
	f.to_computer = to_computer;
	return f;
}

// engine/src/xrGame/<name>, next to this source file (tests\ -> ..\engine\src\xrGame)
std::string game_source(const char* name)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../engine/src/xrGame/" + name, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// The trade module: the deals, the views, the Lua window, and last the declarations they share (a head finds its definition first).
std::string trade_module()
{
	return game_source("coop/coop_trade.cpp") + game_source("coop/coop_trade_views.cpp") +
	    game_source("coop/coop_trade_window_lua.cpp") + game_source("coop/coop_trade_impl.h");
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

// The permit is valid only for its player, its computer's trader and before it expires; the player stands at the computer.
TEST(trade_permit_valid_only_for_its_player_trader_and_before_expiry)
{
	Book book;
	REQUIRE(book.issue(kPlayer, kComputer, kTrader, kNow, kTtl, 6.f));
	const Permit* p = book.find(kPlayer);
	REQUIRE(p != nullptr);
	CHECK_EQ(p->computer, kComputer);
	CHECK_EQ(p->trader, kTrader);
	CHECK_EQ(p->expires, kNow + kTtl);

	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + 1000, 2.f)), Verdict::Granted);
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + kTtl - 1, 2.f)), Verdict::Granted); // the last ms
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + kTtl, 2.f)), Verdict::Expired);    // at expiry: gone
	CHECK_EQ(book.judge(facts(kPlayer, 701, kNow + 1000, 2.f)), Verdict::OtherTrader);     // any other NPC: the stock reach
	CHECK_EQ(book.judge(facts(kOther, kTrader, kNow + 1000, 2.f)), Verdict::None);         // another player holds none
	CHECK_EQ(judge(p, facts(kOther, kTrader, kNow + 1000, 2.f)), Verdict::OtherPlayer);    // his permit is not another's
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + 1000, 6.f)), Verdict::Granted);    // the reach is inclusive
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + 1000, 6.5f)), Verdict::FarFromComputer);
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + 1000, -1.f)), Verdict::NoComputer); // the computer is not here
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + 1000, std::numeric_limits<float>::quiet_NaN())), Verdict::NoComputer);
	CHECK(book.covers(kPlayer, kTrader, kNow + 1000));
	CHECK(!book.covers(kPlayer, 701, kNow + 1000));
	CHECK(!book.covers(kOther, kTrader, kNow + 1000));
	CHECK(!book.covers(kPlayer, kTrader, kNow + kTtl));
}

// Without a permit nothing changes: the deal keeps the stock rules (judge says None, the caller applies the stock reach).
TEST(trade_permit_none_keeps_the_stock_rules)
{
	Book book;
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow, 1.f)), Verdict::None);
	CHECK_EQ(judge(nullptr, facts(kPlayer, kTrader, kNow, 1.f)), Verdict::None);
	CHECK(!granted(Verdict::None));
	CHECK(granted(Verdict::Granted));
	for (Verdict v : {Verdict::OtherPlayer, Verdict::OtherTrader, Verdict::Expired, Verdict::NoComputer, Verdict::FarFromComputer})
		CHECK(!granted(v));
	CHECK(std::string(verdict_name(Verdict::Granted)) == "granted");
	CHECK(std::string(verdict_name(Verdict::FarFromComputer)) == "far from the computer");
}

// A permit with a bad field is never kept; the time and the reach are bounded.
TEST(trade_permit_issue_refuses_bad_fields_and_bounds_time_and_reach)
{
	Book book;
	CHECK(!book.issue(0, kComputer, kTrader, kNow, kTtl, 6.f)); // seat 0 trades locally, never through a deal
	CHECK(!book.issue(kNoPlayer, kComputer, kTrader, kNow, kTtl, 6.f));
	CHECK(!book.issue(kPlayer, kNoObject, kTrader, kNow, kTtl, 6.f));
	CHECK(!book.issue(kPlayer, kComputer, kNoObject, kNow, kTtl, 6.f));
	CHECK(!book.issue(kPlayer, 0, kTrader, kNow, kTtl, 6.f)); // 0: the decider's own actor, no computer
	CHECK(!book.issue(kPlayer, kComputer, 0, kNow, kTtl, 6.f));
	CHECK(!book.issue(kPlayer, kTrader, kTrader, kNow, kTtl, 6.f)); // the trader is no computer
	CHECK(!book.issue(kPlayer, kComputer, kTrader, kNow, 0, 6.f));
	CHECK(!book.issue(kPlayer, kComputer, kTrader, kNow, kTtl, 0.f));
	CHECK(!book.issue(kPlayer, kComputer, kTrader, kNow, kTtl, -1.f));
	CHECK(!book.issue(kPlayer, kComputer, kTrader, kNow, kTtl, std::numeric_limits<float>::quiet_NaN()));
	CHECK(!book.issue(kPlayer, kComputer, kTrader, kNow, kTtl, std::numeric_limits<float>::infinity()));
	CHECK_EQ(book.size(), size_t(0));

	REQUIRE(book.issue(kPlayer, kComputer, kTrader, kNow, kMaxTtlMs * 10, 50.f));
	const Permit* p = book.find(kPlayer);
	REQUIRE(p != nullptr);
	CHECK_EQ(p->expires, kNow + kMaxTtlMs); // never longer than the maximum
	CHECK(p->reach == kMaxReach);           // never farther than the maximum
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + 1, kMaxReach + 0.5f)), Verdict::FarFromComputer);

	// a clock at the end of its range does not wrap the expiry around
	Book late;
	const uint64_t end = std::numeric_limits<uint64_t>::max() - 10;
	REQUIRE(late.issue(kPlayer, kComputer, kTrader, end, kTtl, 6.f));
	CHECK_EQ(late.judge(facts(kPlayer, kTrader, end + 5, 1.f)), Verdict::Granted);
}

// One permit per player: a new one replaces his old one; closing the window revokes it; the book is bounded.
TEST(trade_permit_one_per_player_revoked_and_bounded)
{
	Book book;
	REQUIRE(book.issue(kPlayer, kComputer, kTrader, kNow, kTtl, 6.f));
	REQUIRE(book.issue(kOther, kComputer, kTrader, kNow, kTtl, 6.f));
	REQUIRE(book.issue(kPlayer, kComputer, 701, kNow + 10, kTtl, 6.f));
	CHECK_EQ(book.size(), size_t(2));
	CHECK_EQ(book.judge(facts(kPlayer, kTrader, kNow + 20, 1.f)), Verdict::OtherTrader);
	CHECK_EQ(book.judge(facts(kPlayer, 701, kNow + 20, 1.f)), Verdict::Granted);
	CHECK(book.revoke(kPlayer));
	CHECK(!book.revoke(kPlayer));
	CHECK_EQ(book.judge(facts(kPlayer, 701, kNow + 20, 1.f)), Verdict::None);
	CHECK_EQ(book.judge(facts(kOther, kTrader, kNow + 20, 1.f)), Verdict::Granted);
	book.clear();
	CHECK_EQ(book.size(), size_t(0));

	for (uint32_t i = 1; i <= kMaxPermits; ++i)
		REQUIRE(book.issue(i, kComputer, kTrader, kNow, kTtl, 6.f));
	CHECK(!book.issue(kMaxPermits + 1, kComputer, kTrader, kNow, kTtl, 6.f)); // full of live permits
	CHECK(book.issue(kMaxPermits + 1, kComputer, kTrader, kNow + kTtl, kTtl, 6.f)); // the expired ones make room
	CHECK_EQ(book.size(), size_t(1));
}

// Numbers out of Lua (the decider's grant, the player's window grant): whole ids in range, finite positive times and reaches.
TEST(trade_permit_lua_numbers_are_bounded)
{
	const double nan = std::numeric_limits<double>::quiet_NaN();
	const double inf = std::numeric_limits<double>::infinity();
	CHECK_EQ(object_of(900.0), uint16_t(900));
	CHECK_EQ(object_of(1.0), uint16_t(1));
	CHECK_EQ(object_of(65534.0), uint16_t(65534));
	for (double bad : {0.0, -1.0, 65535.0, 70000.0, 900.5, nan, inf, -inf})
		CHECK_EQ(object_of(bad), kNoObject);
	CHECK_EQ(ttl_of(15000.0), uint64_t(15000));
	CHECK_EQ(ttl_of(1e12), kMaxTtlMs);
	for (double bad : {0.0, -5.0, 0.5, nan, inf})
		CHECK_EQ(ttl_of(bad), uint64_t(0));
	CHECK(reach_of(4.0) == 4.f);
	CHECK(reach_of(100.0) == kMaxReach);
	for (double bad : {0.0, -2.0, nan, inf})
		CHECK(reach_of(bad) == 0.f);
}

// The player's own trade window: beyond the stock 3 m from the trader it stays open only for the granted trader, before the
// grant runs out, while his actor stands at the computer (the stock 3 m, measured from the computer).
TEST(trade_permit_window_keeps_open_only_at_the_computer)
{
	const Window w = window_of(kTrader, 900.0, 30000.0, kNow);
	CHECK_EQ(w.computer, kComputer);
	CHECK_EQ(w.trader, kTrader);
	CHECK_EQ(w.until, kNow + 30000);
	CHECK(window_keeps(w, kTrader, kNow + 1, 2.f));
	CHECK(window_keeps(w, kTrader, kNow + 1, kWindowReach));
	CHECK(!window_keeps(w, kTrader, kNow + 1, kWindowReach + 0.1f)); // walked away from the computer
	CHECK(!window_keeps(w, 701, kNow + 1, 1.f));                       // another trader's window
	CHECK(!window_keeps(w, kTrader, kNow + 30000, 1.f));               // the grant ran out
	CHECK(!window_keeps(w, kTrader, kNow + 1, -1.f));                  // the computer is gone
	CHECK(!window_keeps(Window(), kTrader, kNow, 1.f));                // no grant: the stock rule
	const Window bad = window_of(kTrader, 900.5, 30000.0, kNow);
	CHECK(!window_keeps(bad, kTrader, kNow + 1, 1.f));
	const Window none = window_of(kTrader, 900.0, 0.0, kNow);
	CHECK(!window_keeps(none, kTrader, kNow + 1, 1.f));
	const Window same = window_of(kTrader, double(kTrader), 30000.0, kNow);
	CHECK(!window_keeps(same, kTrader, kNow + 1, 1.f)); // the trader is no computer
	CHECK_EQ(window_of(kTrader, 900.0, 1e12, kNow).until, kNow + kMaxTtlMs);
}

// coop_trade.cpp: the deal takes the permit instead of the talk and the stock reach, and only then.
TEST(trade_permit_deal_check_uses_the_permit_instead_of_the_stock_reach)
{
	const std::string src = trade_module();
	REQUIRE(src.size() > 20000);
	CHECK(src.find("#include \"xrCoop/coop_trade_permit.h\"") != std::string::npos);
	const std::string apply = function_body(src, "u8 host_apply(PeerId from, Deal& d, s64& delta)");
	REQUIRE(!apply.empty());
	const size_t verdict = apply.find("permit_verdict(from, proxy, trader_id)");
	const size_t talk = apply.find("talks::may_trade_with(");
	const size_t reach = apply.find("within_reach(proxy, trader, kTradeReach)");
	REQUIRE(verdict != std::string::npos && talk != std::string::npos && reach != std::string::npos);
	CHECK(verdict < talk && talk < reach);
	CHECK(apply.find("|| remote", talk) != std::string::npos);               // the permit stands for the talk
	CHECK(apply.find("!remote && !trader->NeedOsoznanieMode()") != std::string::npos); // and for the stock reach
	CHECK(apply.find("stalker && stalker->wounded()") != std::string::npos);  // a wounded NPC still never trades
}

// coop_trade.cpp: the window binds the permit on the decider: its open takes the decider's Lua grant, its close revokes it;
// a player who left, a new world and a session end forget it; the contents of the permitted trader reach the window.
TEST(trade_permit_window_open_and_close_bind_the_permit)
{
	const std::string src = trade_module();
	REQUIRE(src.size() > 20000);
	CHECK(src.find("\"coop_mods_trade_computer\"") != std::string::npos);
	CHECK(src.find("\"take_grant\"") != std::string::npos);
	CHECK(src.find("\"window_grant\"") != std::string::npos);
	const std::string container = function_body(src, "void host_on_container(PeerId from, Reader& r)");
	REQUIRE(!container.empty());
	CHECK(container.find("host_take_permit(from, id)") != std::string::npos);
	CHECK(container.find("permits().revoke(from)") != std::string::npos);
	const std::string see = function_body(src, "bool may_see_contents(PeerId from, u8 kind, u16 id)");
	REQUIRE(!see.empty());
	CHECK(see.find("permits().covers(from, id, mgr().now_ms())") != std::string::npos);
	const std::string left = function_body(src, "void on_peer_left(PeerId id)");
	CHECK(left.find("g_permits.revoke(id)") != std::string::npos);
	const std::string reset = function_body(src, "void reset()");
	CHECK(reset.find("g_permits.clear()") != std::string::npos);
	const std::string shown = function_body(src, "void on_actor_menu_shown(CUIActorMenu& menu, bool shown)");
	CHECK(shown.find("client_take_window(") != std::string::npos);
	const std::string keeps = function_body(src, "bool keeps_trade_window(CInventoryOwner* partner)");
	REQUIRE(!keeps.empty());
	CHECK(keeps.find("trade_permit::window_keeps(") != std::string::npos);
}

TEST(trade_permit_every_container_close_revokes_the_senders_permit)
{
	const std::string container = function_body(trade_module(), "void host_on_container(PeerId from, Reader& r)");
	REQUIRE(!container.empty());
	// The close branch must revoke unconditionally before returning, even when the message names another kind of container.
	const std::regex close(R"(if\s*\(!open\)\s*\{\s*g_open\.erase\(from\);\s*permits\(\)\.revoke\(from\);[^\n]*\n\s*return;)");
	CHECK(std::regex_search(container, close));
}
