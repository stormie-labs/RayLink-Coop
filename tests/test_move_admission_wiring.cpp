// Anomaly Coop unit tests: the wiring of admitted_move (engine/src/xrGame/coop/coop_requests_moves.cpp) for a move into a player's
// character (R32 WP18 P4, temp/r30/design/R32-final.md section 8a A21 E-3).
//
// coop_requests_moves.cpp is an engine file and cannot be linked into this exe. tests/tools/test_move_admission_wiring.py runs the
// real admitted_move and player_move over stubs (pytest; tools\run_all_tests.cmd runs it too); this guard keeps the same wiring in
// the native suite that run_all_tests.cmd runs. It reads the two functions (comments dropped, white space folded) and checks:
//   - admitted_move routes by the destination first: the ground asks nothing, a destination whose root is a player goes to
//     player_move, any other container to the admission book below the switch;
//   - player_move asks the move rules with nothing pending, never settles, holds or releases the book, and a refusal is
//     Reason::NotAllowed with the rule's text (admission::refusal_text) and no apply_move.
// The rule (route_of / judge / refusal_text) is tested in tests/test_move_admission_player.cpp.
// COOP_REQUESTS_CPP=<file> reads that copy instead of the tree's (mutation checks).
#include "test_util.h"

#include <cstdlib>
#include <fstream>
#include <regex>
#include <string>

namespace
{
std::string requests_source()
{
	std::string path;
	if (const char* other = std::getenv("COOP_REQUESTS_CPP"))
		path = other;
	else
	{
		const std::string here = __FILE__;
		const size_t slash = here.find_last_of("/\\");
		path = (slash == std::string::npos ? std::string(".") : here.substr(0, slash) + "/..") +
		       "/engine/src/xrGame/coop/coop_requests_moves.cpp";
	}
	std::ifstream in(path, std::ios::binary);
	if (!in.good())
		t::report_failure(__FILE__, __LINE__, "cannot read " + path);
	std::ostringstream out;
	out << in.rdbuf();
	return out.str();
}

// One top-level function of coop_requests_moves.cpp (it closes at the start of a line), comments dropped, white space folded.
// Empty when the source has no such function.
std::string function_of(const std::string& source, const char* signature)
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

void expect_has(const std::string& code, const char* what, const char* fragment)
{
	if (code.find(fragment) == std::string::npos)
		t::report_failure(__FILE__, __LINE__, std::string(what) + ": missing \"" + fragment + "\"");
}

void expect_not(const std::string& code, const char* what, const char* fragment)
{
	if (code.find(fragment) != std::string::npos)
		t::report_failure(__FILE__, __LINE__, std::string(what) + ": must not have \"" + fragment + "\"");
}
} // namespace

// A21 E-3: the destination decides the question, before anything else in admitted_move.
TEST(move_admission_wiring_admitted_move_routes_a_player_destination_to_the_rules)
{
	const std::string code = function_of(requests_source(), "Reason admitted_move(");
	REQUIRE(!code.empty());
	const char* what = "admitted_move";
	// The switch is the first statement: no early return of the stock move before it (the old line).
	expect_has(code, what,
	    "Reason admitted_move(u16 item, u16 src, u16 dst, const Fvector* drop_pos, xr_string& refused) { "
	    "switch (admission::route_of(dst, dst != kNoId && is_player(events::root_of(dst)))) {");
	expect_has(code, what, "case admission::Route::Stock: return apply_move(item, src, dst, drop_pos);");
	expect_has(code, what, "case admission::Route::Ask: return player_move(item, src, dst, drop_pos, refused);");
	expect_has(code, what, "case admission::Route::AskAndHold: break; }");
	expect_not(code, what, "is_player(events::root_of(dst))) return apply_move");
	// The container path below the switch is the book's, as before.
	expect_has(code, what, "g_admission.settle(dst, now, &admission_track);");
	expect_has(code, what, "ask_move_rules(item, src, dst, g_admission.pending(dst), text)");
}

// A move into a player: asked with nothing pending, the book untouched, a refusal is NotAllowed without apply_move.
TEST(move_admission_wiring_player_move_refuses_without_the_book)
{
	const std::string code = function_of(requests_source(), "Reason player_move(");
	REQUIRE(!code.empty());
	const char* what = "player_move";
	expect_has(code, what, "ask_move_rules(item, src, dst, admission::Pending{}, text)");
	expect_has(code, what, "admission::judge(g_admission, admission::Route::Ask, answer, dst, item,");
	expect_has(code, what, "!= admission::Verdict::Full) return apply_move(item, src, dst, drop_pos);");
	expect_has(code, what, "refused = admission::refusal_text(text.c_str()); return Reason::NotAllowed; }");
	expect_not(code, what, "g_admission.settle");
	expect_not(code, what, "g_admission.hold");
	expect_not(code, what, "g_admission.release");
	expect_not(code, what, "g_admission.pending");
	expect_not(code, what, "admission::decide(");
	expect_not(code, what, "Route::AskAndHold");
}
