// Anomaly Coop unit tests: the item and request lines of the reports of builds 55-58 (O7). coop_items.cpp and coop_requests_moves.cpp are
// engine files and cannot be linked into this exe; the engine-slice tests run the logic over stubs
// (tests/tools/test_items_gift_late.py: the giver's grace; test_trade_delivery.py: host_transfer_item; test_local_zone_release.py).
// This guard keeps the wiring of the lines in the native suite (comments dropped, white space folded):
//   - #480: an ItemState of a peer whose rejoin is under way (join::host_rejoin_peer: his character is nobody's) is counted
//     (rejoin_dropped) without a red line; one with no character and no join under way is still refused with one;
//   - a report host_access refused as Denied that is the giver's last word on a gift (late_report_of_gift) is counted (gift_late)
//     without a line, before the "not owner" refusal;
//   - #1513: "the weapon is already empty here" carries the host's count and the asked rounds;
//   - #705/#708: host_transfer_item counts a dying item and a move done already without a line, lets a move to the holder the
//     item has fall through to the stock pair, and its refusal line names the section and the holder the item has now.
// The mode does not enter: the co-op host and the map server of the level (and the world server for its own script moves) run the
// same code. COOP_ITEMS_CPP / COOP_REQUESTS_CPP / COOP_REQUESTS_CORE_CPP=<file> read those copies instead of the tree's (mutation checks).
#include "test_util.h"

#include <cstdlib>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>

namespace
{
std::string o7_source(const char* env, const char* file)
{
	std::string path;
	if (const char* other = std::getenv(env))
		path = other;
	else
	{
		const std::string here = __FILE__;
		const size_t slash = here.find_last_of("/\\");
		path = (slash == std::string::npos ? std::string(".") : here.substr(0, slash) + "/..") + "/engine/src/xrGame/coop/" + file;
	}
	std::ifstream in(path, std::ios::binary);
	if (!in.good())
		t::report_failure(__FILE__, __LINE__, "cannot read " + path);
	std::ostringstream out;
	out << in.rdbuf();
	return out.str();
}

// One top-level function (it closes at the start of a line), comments dropped, white space folded. Empty when absent.
std::string o7_function(const std::string& source, const char* signature)
{
	const size_t start = source.find(signature);
	if (start == std::string::npos)
		return std::string();
	const size_t end = source.find("\n}", start);
	if (end == std::string::npos)
		return std::string();
	std::string body = std::regex_replace(source.substr(start, end + 2 - start), std::regex(R"(//[^\n]*)"), "");
	return std::regex_replace(body, std::regex(R"(\s+)"), " ");
}

size_t o7_at(const std::string& where, const std::string& code, const std::string& fragment)
{
	const size_t at = code.find(fragment);
	if (at == std::string::npos)
		t::report_failure(__FILE__, __LINE__, where + ": missing \"" + fragment + "\"");
	return at;
}

void o7_before(const std::string& where, const std::string& code, const std::string& first, const std::string& then)
{
	const size_t a = o7_at(where, code, first);
	const size_t b = o7_at(where, code, then);
	if (a != std::string::npos && b != std::string::npos && a >= b)
		t::report_failure(__FILE__, __LINE__, where + ": \"" + first + "\" must come before \"" + then + "\"");
}

const std::string& o7_items()
{
	static const std::string code = o7_source("COOP_ITEMS_CPP", "coop_items.cpp");
	return code;
}

const std::string& o7_requests()
{
	static const std::string code = o7_source("COOP_REQUESTS_CPP", "coop_requests_moves.cpp");
	return code;
}

const std::string& o7_requests_core()
{
	static const std::string code = o7_source("COOP_REQUESTS_CORE_CPP", "coop_requests.cpp");
	return code;
}
} // namespace

TEST(o7_item_state_of_a_rejoining_peer_is_counted_without_a_line)
{
	const std::string on_state = o7_function(o7_items(), "void host_on_state(");
	REQUIRE(!on_state.empty());
	o7_before("host_on_state", on_state,
	    "if (proxy == kNoId && sync::host_peer_joining(from)) { ++g_stats.rejoin_dropped; return; }",
	    "if (proxy == kNoId || sync::host_peer_joining(from)) { reject(Reason::NoProxy, from, id, nullptr); return; }");
	o7_at("print_status", o7_function(o7_items(), "void print_status("), "s.rejoin_dropped");
}

TEST(o7_the_givers_late_report_is_counted_without_a_line)
{
	const std::string on_state = o7_function(o7_items(), "void host_on_state(");
	REQUIRE(!on_state.empty());
	o7_at("host_on_state", on_state,
	    "if (access == Access::Denied) { if (late_report_of_gift(from, proxy, id)) { ++g_stats.gift_late; return; } "
	    "reject(Reason::NotOwner, from, id, e->s_name.c_str()); return; }");
	o7_at("print_status", o7_function(o7_items(), "void print_status("), "s.gift_late");
	// host_push keeps a giver's grace (test_items_gift_late.py runs it)
	o7_at("host_push", o7_function(o7_items(), "void host_push("), "if (left != g_left.end() && left->second.peer == peer) g_left.erase(left);");
}

TEST(o7_an_empty_weapon_line_says_the_counts)
{
	const std::string ammo = o7_function(o7_items(), "void host_on_spawn_ammo(");
	REQUIRE(!ammo.empty());
	const size_t empty = o7_at("host_on_spawn_ammo", ammo, "if (!avail) {");
	if (empty == std::string::npos)
		return;
	const std::string branch = ammo.substr(empty, ammo.find("return; }", empty) - empty);
	o7_at("host_on_spawn_ammo: empty", branch, "the weapon is already empty here");
	o7_at("host_on_spawn_ammo: empty", branch, "have, used, u32(rounds)");
	o7_at("host_on_spawn_ammo: empty", branch, "reject(Reason::Moved, from, weapon_id, detail);");
}

TEST(o7_script_moves_of_this_process)
{
	const std::string move = o7_function(o7_requests(), "bool host_transfer_item(");
	REQUIRE(!move.empty());
	o7_before("host_transfer_item", move, "if (item_dying(item)) { ++g_script_moves.dying; return true; }",
	    "admitted_move(item, from, to, nullptr, refused)");
	o7_before("host_transfer_item", move,
	    "if (e && e->ID_Parent == from && from == to) { ++g_script_moves.in_place; return false; }",
	    "if (e && e->ID_Parent == to) { ++g_script_moves.already; return true; }");
	o7_at("host_transfer_item", move, "log_script_move_refused(item, from, to, why, refused);");
	if (move.find("::Msg(") != std::string::npos)
		t::report_failure(__FILE__, __LINE__, "host_transfer_item: its one line is log_script_move_refused's");
	const std::string line = o7_function(o7_requests(), "void log_script_move_refused(");
	REQUIRE(!line.empty());
	o7_at("log_script_move_refused", line, "! [coop] script transfer item %u [%s] from %u to %u refused: %s%s%s; it is in %u [%s]");
	o7_at("print_status", o7_function(o7_requests_core(), "void print_status("), "g_script_moves.in_place");
}

// Verifier finding (O7, low): the engine-slice fixture stubs these two helpers, so their real bodies need a pin here.
// item_dying is the first gate of host_transfer_item: inverted, it would swallow every script move as 'dying'. The refusal
// line exists to print the item's CURRENT holder (reports #705, #708, #1709), not the move's source.
TEST(o7_the_helpers_of_host_transfer_item_keep_their_meaning)
{
	const std::string dying = o7_function(o7_requests(), "bool item_dying(");
	REQUIRE(!dying.empty());
	o7_at("item_dying", dying, "return o && o->getDestroy();");
	if (dying.find("!(") != std::string::npos || dying.find("!o") != std::string::npos)
		t::report_failure(__FILE__, __LINE__, "item_dying: a dying item is one whose game object is marked getDestroy, nothing else");
	const std::string line = o7_function(o7_requests(), "void log_script_move_refused(");
	REQUIRE(!line.empty());
	o7_at("log_script_move_refused", line, "const u16 holder = e ? e->ID_Parent : o && o->H_Parent() ? u16(o->H_Parent()->ID()) : kNoId;");
	o7_at("log_script_move_refused", line, "const char* section = e ? e->s_name.c_str() : o ? o->cNameSect_str() : nullptr;");
}
