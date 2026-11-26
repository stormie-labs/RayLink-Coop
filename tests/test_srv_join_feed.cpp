// Anomaly Coop unit tests: the server's part of the join (A-S6J, S6 pattern P-G: srv/coop_srv_join.cpp; temp/b58/s6_map/net.md) and the
// feed lines of a server world (S5, TZ R7: "went to <level>" / "came from <level>" for the other players; srv/coop_srv_feed_rules.h).
//
// Per mode:
// - Server: the rule of the feed lines (feed::Watch over the world server's table of seats as a player's machine sees it), the text of a
//   line (feed::fill, feed::shown_nick: no printf, no markup from a nick), the strings (st_srv_feed.xml, eng and rus), and, read in the
//   sources, that the server's join answers its bridges and a player's LevelMove, and that the Core asks the mode's H-JOIN answers where
//   the server's own lines were.
// - Co-op: read in the sources, the Core's join installs no LevelMove handler and names nothing of the server (no map server, no
//   dedicated host, no split levels), and the co-op's mode calls nothing of the server's join: the group moves together, no feed.
// - none: an empty table and an unknown own level give no line.
#include "test_util.h"

#include "srv/coop_srv_feed_rules.h"

#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using namespace coop::srv;

namespace
{
using feed::Kind;
using feed::Line;
using feed::Row;
using feed::Watch;

constexpr uint16_t kA = 1; // l01_escape, say
constexpr uint16_t kB = 2;
constexpr uint16_t kC = 3;

std::string sj_root()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	return here + "/..";
}

std::string sj_read(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The source with // and /* */ comments blanked (string literals kept), so that a word in a comment is no code.
std::string sj_code(const std::string& src)
{
	std::string out = src;
	enum class St
	{
		Code,
		Line,
		Block,
		Str,
		Chr
	} st = St::Code;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		switch (st)
		{
		case St::Code:
			if (c == '/' && n == '/')
			{
				st = St::Line;
				out[i] = out[i + 1] = ' ';
				++i;
			}
			else if (c == '/' && n == '*')
			{
				st = St::Block;
				out[i] = out[i + 1] = ' ';
				++i;
			}
			else if (c == '"')
				st = St::Str;
			else if (c == '\'')
				st = St::Chr;
			break;
		case St::Line:
			if (c == '\n')
				st = St::Code;
			else
				out[i] = ' ';
			break;
		case St::Block:
			if (c == '*' && n == '/')
			{
				out[i] = out[i + 1] = ' ';
				++i;
				st = St::Code;
			}
			else if (c != '\n')
				out[i] = ' ';
			break;
		case St::Str:
			if (c == '\\')
				++i;
			else if (c == '"')
				st = St::Code;
			break;
		case St::Chr:
			if (c == '\\')
				++i;
			else if (c == '\'')
				st = St::Code;
			break;
		}
	}
	return out;
}

std::string sj_engine(const std::string& rel) { return sj_code(sj_read(sj_root() + "/engine/src/" + rel)); }
// The join module: coop_join.cpp and the files it is split into.
std::string sj_join()
{
	return sj_engine("xrGame/coop/coop_join.cpp")
	    + sj_engine("xrGame/coop/coop_join_characters.cpp")
	    + sj_engine("xrGame/coop/coop_join_transition.cpp")
	    + sj_engine("xrGame/coop/coop_join_transition_load.cpp")
	    + sj_engine("xrGame/coop/coop_join_swap.cpp");
}

// The body of the function whose definition matches `head` (a regex up to its parameter list), braces matched; "" if none.
std::string sj_body(const std::string& code, const std::string& head)
{
	std::smatch m;
	const std::regex re(head + R"(\s*\([^;{]*\)\s*(const\s*)?(override\s*)?\{)");
	if (!std::regex_search(code, m, re))
		return std::string();
	const size_t open = size_t(m.position(0) + m.length(0) - 1);
	int depth = 0;
	for (size_t i = open; i < code.size(); ++i)
	{
		if (code[i] == '{')
			++depth;
		else if (code[i] == '}' && --depth == 0)
			return code.substr(open, i - open + 1);
	}
	return std::string();
}

bool sj_has(const std::string& text, const std::string& what) { return text.find(what) != std::string::npos; }

// `first` and `then` are both in `text`, `first` before `then`.
bool sj_order(const std::string& text, const std::string& first, const std::string& then)
{
	const size_t a = text.find(first);
	const size_t b = text.find(then);
	return a != std::string::npos && b != std::string::npos && a < b;
}

bool same(const std::vector<Line>& got, const std::vector<Line>& want)
{
	if (got.size() != want.size())
		return false;
	for (size_t i = 0; i < got.size(); ++i)
		if (got[i].peer != want[i].peer || got[i].kind != want[i].kind || got[i].level != want[i].level)
			return false;
	return true;
}
} // namespace

// ---------------------------------------------------------------- Server: the rule of the feed lines

// A partner leaves my level for another one: "went to <his new level>". The first sight of a player says nothing.
TEST(srv_feed_went_to_when_a_partner_leaves)
{
	Watch w;
	CHECK(w.step({{1, kA}, {2, kA}}, kA).empty()); // the first table: nobody moved
	CHECK(same(w.step({{1, kB}, {2, kA}}, kA), {{1, Kind::WentTo, kB}}));
	CHECK(w.step({{1, kB}, {2, kA}}, kA).empty()); // the same table again: once
}

// A partner comes onto my level: "came from <the level he left>".
TEST(srv_feed_came_from_onto_my_level)
{
	Watch w;
	CHECK(w.step({{1, kA}}, kB).empty());
	CHECK(same(w.step({{1, kB}}, kB), {{1, Kind::CameFrom, kA}}));
}

// A partner who moves between two levels that are not mine: where he went (I see where to find him).
TEST(srv_feed_went_to_between_other_levels)
{
	Watch w;
	CHECK(w.step({{1, kA}}, kC).empty());
	CHECK(same(w.step({{1, kB}}, kC), {{1, Kind::WentTo, kB}}));
	// two at once, in the order of the table
	CHECK(w.step({{1, kB}, {2, kA}}, kC).empty());
	CHECK(same(w.step({{1, kC}, {2, kB}}, kC), {{1, Kind::CameFrom, kB}, {2, Kind::WentTo, kB}}));
}

// My own move says nothing of the others: their rows did not change.
TEST(srv_feed_my_own_move_is_no_line)
{
	Watch w;
	CHECK(w.step({{1, kA}, {2, kB}}, kA).empty());
	CHECK(w.step({{1, kA}, {2, kB}}, kB).empty());
	CHECK(w.step({{1, kA}, {2, kB}}, kC).empty());
}

// A row whose level is not known (a joiner the world server has not seated yet) keeps what was known; his next known level counts
// from there.
TEST(srv_feed_unknown_level_keeps_the_last_known)
{
	Watch w;
	CHECK(w.step({{1, feed::kNoLevel}}, kA).empty()); // never known: nothing
	CHECK(w.step({{1, kA}}, kA).empty()); // first known: nothing
	CHECK(w.step({{1, feed::kNoLevel}}, kA).empty());
	CHECK_EQ(w.known(), size_t(1));
	CHECK(same(w.step({{1, kB}}, kA), {{1, Kind::WentTo, kB}}));
}

// While my own level is not known (my machine loads a world: no actor, no feed) nothing is compared and nothing forgotten: the next
// table is compared with the last one I saw, so a partner who went A -> B -> C meanwhile is one line.
TEST(srv_feed_waits_while_my_level_is_unknown)
{
	Watch w;
	CHECK(w.step({{1, kA}}, kA).empty());
	CHECK(w.step({{1, kB}}, feed::kNoLevel).empty());
	CHECK(w.step({}, feed::kNoLevel).empty()); // not even who left
	CHECK(same(w.step({{1, kC}}, kB), {{1, Kind::WentTo, kC}}));
}

// A player who left the session is forgotten: when he comes back on another level it is a first sight (his join), no line.
TEST(srv_feed_forgets_who_left)
{
	Watch w;
	CHECK(w.step({{1, kA}, {2, kA}}, kA).empty());
	CHECK(w.step({{2, kA}}, kA).empty());
	CHECK_EQ(w.known(), size_t(1));
	CHECK(w.step({{1, kB}, {2, kA}}, kA).empty());
	w.reset(); // a new session
	CHECK_EQ(w.known(), size_t(0));
	CHECK(w.step({{1, kC}, {2, kC}}, kA).empty());
}

// none: an empty table, or no level of mine, gives nothing.
TEST(srv_feed_none_without_a_table)
{
	Watch w;
	CHECK(w.step({}, kA).empty());
	CHECK(w.step({}, feed::kNoLevel).empty());
	CHECK_EQ(w.known(), size_t(0));
}

// The text: the template's {nick} and {level} filled, nothing else read: a '%' of the template or of the nick is no format, a nick
// keeps no markup ('%' starts a colour of a UI text) nor a line break, and is cut to kMaxNick bytes.
TEST(srv_feed_text_is_filled_not_formatted)
{
	CHECK_EQ(feed::fill("{nick} went to {level}", "Vasya", "Cordon"), std::string("Vasya went to Cordon"));
	CHECK_EQ(feed::fill("{level}: {nick}, {nick}", "a", "b"), std::string("b: a, a"));
	CHECK_EQ(feed::fill("%s {nick} %d", "x", "y"), std::string("%s x %d"));
	CHECK_EQ(feed::fill("{nick} {lev", "x", "y"), std::string("x {lev"));
	CHECK_EQ(feed::fill("", "x", "y"), std::string());
	CHECK_EQ(feed::shown_nick("%c[255,255,0,0]Red\nLine\t1"), std::string("c[255,255,0,0]RedLine1"));
	CHECK_EQ(feed::shown_nick(std::string(80, 'n')).size(), feed::kMaxNick);
	CHECK_EQ(feed::shown_nick(""), std::string("?"));
	CHECK_EQ(feed::shown_nick("%%%"), std::string("?"));
	// the bytes of a cp1251 or UTF-8 nick stay as they are
	CHECK_EQ(feed::shown_nick("\xC2\xE0\xF1\xFF"), std::string("\xC2\xE0\xF1\xFF"));
}

// The strings of the lines, eng and rus: the three ids, both placeholders in each line, the format of the game's text files.
TEST(srv_feed_strings_in_both_languages)
{
	for (const char* lang : {"eng", "rus"})
	{
		const std::string xml = sj_read(sj_root() + "/gamedata/configs/text/" + lang + "/st_srv_feed.xml");
		REQUIRE(!xml.empty());
		CHECK(xml.rfind("<?xml version=\"1.0\" encoding=\"windows-1251\"?>", 0) == 0);
		std::string crlf = xml;
		for (size_t at = crlf.find("\r\n"); at != std::string::npos; at = crlf.find("\r\n", at))
			crlf.erase(at, 2);
		CHECK(crlf.find('\n') == std::string::npos); // CRLF line ends
		for (const char* id : {"st_srv_feed_went", "st_srv_feed_came"})
		{
			const size_t at = xml.find(std::string("<string id=\"") + id + "\">");
			REQUIRE(at != std::string::npos);
			const size_t end = xml.find("</string>", at);
			const std::string row = xml.substr(at, end - at);
			CHECK(sj_has(row, "{nick}"));
			CHECK(sj_has(row, "{level}"));
			CHECK(!sj_has(row, "%"));
		}
		CHECK(sj_has(xml, "<string id=\"st_srv_feed_caption\">"));
	}
}

// ---------------------------------------------------------------- Server: the server's join, read in the sources

// The world server's own handlers (srv/coop_srv_join.cpp join_install_world): LevelMove is its own, and a JoinRequest / WorldLoaded of a
// bridge is served there before the Core's player path; a map server's SessionReset ends its process.
TEST(srv_join_answers_its_bridges_and_level_move)
{
	const std::string srv = sj_engine("xrGame/coop/srv/coop_srv_join.cpp");
	REQUIRE(!srv.empty());
	const std::string install = sj_body(srv, R"(void\s+join_install_world)");
	REQUIRE(!install.empty());
	CHECK(sj_has(install, "Msg::LevelMove"));
	CHECK(sj_has(install, "Msg::JoinRequest"));
	CHECK(sj_has(install, "Msg::WorldLoaded"));
	const std::string request = sj_body(srv, R"(void\s+world_on_join_request)");
	const std::string loaded = sj_body(srv, R"(void\s+world_on_world_loaded)");
	REQUIRE(!request.empty() && !loaded.empty());
	CHECK(sj_order(request, "mapserver::is_bridge(from)", "join::player_join_request(from, r)"));
	CHECK(sj_order(loaded, "mapserver::is_bridge(from)", "join::player_world_loaded(from, r)"));
	// the world a map server loads: the save its held players loaded, unless its level's logic came after it
	const std::string serve = sj_body(srv, R"(void\s+serve_bridge)");
	CHECK(sj_has(serve, "join::held_save()"));
	CHECK(sj_has(serve, "levels::logic_came_since(mapserver::level_of_bridge(bridge)"));
	CHECK(sj_has(serve, "join::world_save_ready()"));
	CHECK(sj_has(sj_body(srv, R"(void\s+join_install_map)"), "Msg::SessionReset"));
	CHECK(sj_has(sj_body(srv, R"(void\s+map_on_session_reset)"), "mapserver::server_session_over()"));
	// a lone move: the decider judges it, the character moves, the player joins again; a refusal names nothing of the client's
	const std::string move = sj_body(srv, R"(void\s+on_level_move)");
	REQUIRE(!move.empty());
	CHECK(sj_has(move, "levels::host_judge_move(from, target)"));
	CHECK(sj_order(move, "levels::host_player_moves(from, target)", "teleport_object("));
	CHECK(sj_order(move, "teleport_object(", "join::host_rejoin_peer(from"));
	CHECK(sj_has(move, "join::host_player_in_world(proxy_id)"));
	CHECK(sj_has(move, "join::group_moves()"));
}

// The Core asks the H-JOIN answers (xrCoop/coop_mode.h) where the server's lines were.
TEST(srv_join_core_asks_the_mode)
{
	const std::string join = sj_join();
	REQUIRE(!join.empty());
	CHECK(sj_has(sj_body(join, R"(void\s+player_join_request)"), "mode().join_from_bridge(from, Msg::JoinRequest)"));
	CHECK(sj_has(sj_body(join, R"(void\s+player_world_loaded)"), "mode().join_from_bridge(from, Msg::WorldLoaded)"));
	const std::string save = sj_body(join, R"(bool\s+host_send_save)");
	REQUIRE(!save.empty());
	CHECK(sj_order(save, "mode().join_save(from, *proxy)", "mode().level_ready(level)"));
	CHECK(sj_has(sj_body(join, R"(void\s+host_held_step)"), "mode().level_ready(h.level)"));
	CHECK(sj_has(sj_body(join, R"(void\s+client_go_live)"), "mode().on_world_live()"));
	CHECK(sj_has(sj_body(join, R"(void\s+load_screen_line)"), "mode().load_text(g_load.screen_level"));
	CHECK(sj_has(sj_body(join, R"(void\s+on_alife_objects_loaded)"), "coop::place_ghost(objects)"));
	// who leads no level of a player (the world server) puts nobody "next to the host", has no level for a joiner, names none in the
	// offer; whose actor is a ghost is nobody in AvatarList, waits at no exit and arrives nowhere
	CHECK(sj_has(sj_body(join, R"(StartPoint\s+host_place)"), "valid && (here || !mode().leads_level())"));
	CHECK(sj_has(sj_body(join, R"(bool\s+host_fall_back_to_level)"), "if (!mode().leads_level())"));
	CHECK(sj_has(sj_body(join, R"(bool\s+host_offer_character)"), "g_pGameLevel && mode().leads_level()"));
	CHECK(sj_has(sj_body(join, R"(void\s+host_send_owners)"), "if (mode().actor_is_player())"));
	const std::string waits = sj_body(join, R"(bool\s+group_waits_here)");
	CHECK(sj_order(waits, "!mode().actor_is_player()", "mode().decides_world() ? host_has_company() : mgr().is_live_client()"));
	CHECK(sj_has(sj_body(join, R"(void\s+arrival_begin)"), "!mode().actor_is_player()"));
}

TEST(srv_join_map_exits_even_on_malformed_session_reset)
{
	const auto handler = sj_body(sj_engine("xrGame/coop/srv/coop_srv_join.cpp"), R"(void\s+map_on_session_reset)");
	REQUIRE(!handler.empty());
	CHECK(sj_order(handler, "from != kHostPeer", "r.str()"));
	CHECK(sj_order(handler, "if (!r.ok())", "malformed SessionReset"));
	CHECK(sj_order(handler, "malformed SessionReset", "mapserver::server_session_over()"));
	const size_t malformed = handler.find("if (!r.ok())");
	const size_t quit = handler.find("mapserver::server_session_over()", malformed);
	REQUIRE(quit != std::string::npos);
	CHECK(!sj_has(handler.substr(malformed, quit - malformed), "return"));
	CHECK(!sj_has(handler, "mgr().stop("));
}

TEST(coop_join_level_move_refuses_with_the_requests_sequence)
{
	const auto source = sj_engine("xrGame/coop/hostplay/coop_hostplay_mode.cpp");
	const auto install = sj_body(source, R"(void\s+install)");
	CHECK(sj_has(install, "tables.session.on(Msg::LevelMove, &join::refuse_level_move)"));
	const auto handler = sj_body(sj_join(), R"(void\s+refuse_level_move)");
	CHECK(sj_order(handler, "if (!request.read(r))", "return;"));
	CHECK(sj_order(handler, "return;", "request.seq"));
	CHECK(sj_has(handler, "Result::Refused, Result::Invalid, levels::wire::kNoLevel"));
	CHECK(sj_order(handler, "result.write(w)", "send(from, Lane::Reliable, Msg::LevelMoveResult, w)"));
}

// ---------------------------------------------------------------- Server: the feed lines on a player's machine

// srv/coop_srv_join.cpp feed_frame: the world server's table as this machine sees it, the PDA feed, the texts of st_srv_feed.xml filled
// (never a format), nothing for this machine's own row nor for the world server's seat.
TEST(srv_feed_frame_in_the_source)
{
	const std::string srv = sj_engine("xrGame/coop/srv/coop_srv_join.cpp");
	REQUIRE(!srv.empty());
	const std::string frame = sj_body(srv, R"(void\s+feed_frame)");
	REQUIRE(!frame.empty());
	CHECK(sj_has(frame, "levels::level_of_player("));
	CHECK(sj_has(frame, "kHostPeer"));
	CHECK(sj_has(frame, "mgr().self()"));
	const std::string show = sj_body(srv, R"(void\s+feed_show)");
	REQUIRE(!show.empty());
	CHECK(sj_has(show, "\"st_srv_feed_went\""));
	CHECK(sj_has(show, "\"st_srv_feed_came\""));
	CHECK(sj_has(show, "feed::fill("));
	CHECK(sj_has(show, "feed::shown_nick("));
	CHECK(sj_has(show, "AddGameNews("));
	CHECK(!sj_has(show, "xr_sprintf"));
	CHECK(sj_has(sj_body(srv, R"(void\s+feed_start)"), "reset()"));
}

// ---------------------------------------------------------------- Co-op: nothing of the server in the Core's join

// The Core's join installs no LevelMove handler and names no part of the server: no map server, no dedicated host, no split levels.
// The co-op mode installs its own refusal and calls nothing of the server's join.
TEST(srv_join_coop_has_none_of_it)
{
	const std::string join = sj_join();
	REQUIRE(!join.empty());
	const std::string install = sj_body(join, R"(void\s+install_server)");
	REQUIRE(!install.empty());
	CHECK(!sj_has(install, "LevelMove"));
	CHECK(sj_has(install, "Msg::JoinRequest"));
	CHECK(sj_has(install, "Msg::WorldLoaded"));
	for (const char* word : {"mapserver::", "dedicated::", "is_map_server", "levels::split", "on_host_level", "coop_dedicated.h",
	         "coop_mapserver.h", "host_on_level_move", "host_serve_map_server", "host_world_facts"})
		CHECK(!sj_has(join, word));
	const std::string header = sj_engine("xrGame/coop/coop_join.h");
	REQUIRE(!header.empty());
	CHECK(!sj_has(header, "dedicated::"));
	const std::string coop = sj_engine("xrGame/coop/hostplay/coop_hostplay_mode.cpp");
	REQUIRE(!coop.empty());
	for (const char* word : {"join_install_world", "join_install_map", "feed_frame", "feed_start", "coop_srv_join"})
		CHECK(!sj_has(coop, word));
	// a player of the co-op asks the decider for a lone move only where the group does not travel together
	CHECK(sj_has(sj_body(join, R"(void\s+client_request_level_change)"), "!mode().group_travels()"));
	CHECK(sj_has(sj_body(join, R"(void\s+transition_step)"), "mode().group_travels() || g_load.move_board"));
}
