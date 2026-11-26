// Anomaly Coop unit tests: the S6 contract (A-S6-IF, docs/contracts/coop_mode_api.md section 7, xrCoop/coop_mode.h): the hooks the S6
// groups ask the session's mode, one answer per process kind.
//
// - none: the real NoneMode (Mode's "not mine" answers) runs here;
// - every other kind: the fixed answers of tests/support/fake_mode.h (MODE_CASES), cell by cell, and the real mode's answer of each hook
//   read from its source (hostplay/coop_hostplay_mode.cpp, srv/coop_srv_mode.cpp: the engine files cannot run here), so that the fake
//   answers what the real modes answer;
// - a map server's side of its level (srv MapLevelSide, Mode::level()): its book of balances as the fake keeps it, and its body read from
//   the source;
// - the process's hooks of the layers (place_ghost, console_line): the switchboard asks every layer, the server's answers them, the
//   co-op's has none.
#include "test_util.h"
#include "coop_mode.h"
#include "srv/coop_ghost_rules.h"
#include "srv/coop_scope.h"
#include "coop_wire.h"
#include "support/fake_mode.h"

#include <fstream>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using namespace coop;

namespace
{
// engine/src next to this source file (tests\ -> ..\engine\src)
std::string s6_engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	return here + "/../engine/src";
}

std::string s6_read(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The source with // and /* */ comments blanked (string literals kept).
std::string s6_code(const std::string& src)
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

std::string s6_collapse(const std::string& s)
{
	std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

// The text between the brace at `open` and its partner; "" when they do not close.
std::string s6_braced(const std::string& code, size_t open)
{
	int depth = 1;
	size_t i = open + 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : code.substr(open + 1, i - 2 - open);
}

std::string s6_class(const std::string& code, const std::string& name)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(R"(\bclass\s+)" + name + R"(\b[^;{]*\{)")))
	{
		t::report_failure(__FILE__, __LINE__, "no class " + name);
		return "";
	}
	return s6_braced(code, size_t(m.position(0) + m.length(0) - 1));
}

// The collapsed body of the override `name` in a class body; "<none>" when the class has none.
std::string s6_hook(const std::string& cls, const std::string& name)
{
	std::smatch m;
	const std::regex rx(R"(\b)" + name + R"(\s*\([^;{)]*\)\s*(?:const\s*)?override\s*\{)");
	if (!std::regex_search(cls, m, rx))
		return "<none>";
	return s6_collapse(s6_braced(cls, size_t(m.position(0) + m.length(0) - 1)));
}

// The collapsed body of the first free function whose head matches `head`.
std::string s6_function(const std::string& code, const std::string& head)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(head + R"(\s*\([^;{)]*\)\s*\{)")))
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return "";
	}
	return s6_collapse(s6_braced(code, size_t(m.position(0) + m.length(0) - 1)));
}

bool s6_has(const std::string& text, const std::string& what) { return text.find(what) != std::string::npos; }

// The hooks of the S6 groups (xrCoop/coop_mode.h), in the order of the rows below.
const char* const kS6Hooks[] = {"level", "reaches", "deliver_links", "led_elsewhere", "to_level_of", "join_from_bridge", "join_save",
    "level_ready", "on_world_live", "load_text", "ghost_said"};
constexpr size_t kS6HookCount = sizeof(kS6Hooks) / sizeof(kS6Hooks[0]);

using HookRow = std::vector<std::string>;

// The real answers, as each mode's class writes them (collapsed bodies; a "~" prefix: the body contains that text).
const std::map<std::string, HookRow>& s6_real_rows()
{
	static const HookRow not_mine = {"return nullptr;", "return true;", "", "return false;", "return false;", "return false;",
	    "return false;", "return true;", "", "return nullptr;", "return false;"};
	static const std::map<std::string, HookRow> rows = {
		{"CoopHostMode",
		    {"return nullptr;", "return true;", "Session& s = mgr().session(); if (s.local()) s.send(kHostPeer, lane, type, payload);",
		        "return false;", "return false;", "return false;", "return false;", "return true;", "", "return nullptr;", "return false;"}},
		{"CoopClientMode", not_mine},
		{"WorldServerMode",
		    {"return nullptr;", "return levels::passes_to(type, peer);", "to_bridges(type, payload, lane, kInvalidPeer);",
		        "return level_bridge(peer) != kInvalidPeer;", "~net::to_peer(bridge, type, payload, lane); return true;",
		        "return mapserver::is_bridge(from);", "~entities::host_send_place(bridge, &proxy); return true;",
		        "return mapserver::host_ready(level);", "", "return nullptr;", "return false;"}},
		{"MapServerMode", // no link (review A-REV-E-1, finding 2: its level session has no LocalLink)
		    {"return &map_level_side();", "return levels::passes_to(type, peer);", "", "return false;", "return false;",
		        "return false;", "return false;", "return true;", "world::host_scan_proxies();",
		        "return server_load_text(screen_level, world_up);", "return ghost::about_actor(s);"}},
		{"ServerClientMode",
		    {"return nullptr;", "return true;", "", "return false;", "return false;", "return false;", "return false;", "return true;", "",
		        "return server_load_text(screen_level, world_up);", "return false;"}},
	};
	return rows;
}

void s6_check_real(const char* cls_name)
{
	const std::string src = s6_engine_src();
	const bool coop = std::string(cls_name).rfind("Coop", 0) == 0;
	const std::string code =
	    s6_code(s6_read(src + (coop ? "/xrGame/coop/hostplay/coop_hostplay_mode.cpp" : "/xrGame/coop/srv/coop_srv_mode.cpp")));
	REQUIRE(!code.empty());
	// both co-op modes answer what they share in their common base (CoopModeBase), after their own overrides
	const std::string cls = s6_class(code, cls_name) + (coop ? s6_class(code, "CoopModeBase") : std::string());
	REQUIRE(!cls.empty());
	const HookRow& want = s6_real_rows().at(cls_name);
	REQUIRE(want.size() == kS6HookCount);
	for (size_t i = 0; i < kS6HookCount; ++i)
	{
		const std::string got = s6_hook(cls, kS6Hooks[i]);
		const bool part = !want[i].empty() && want[i][0] == '~';
		const bool ok = part ? s6_has(got, want[i].substr(1)) : got == want[i];
		if (!ok)
			t::report_failure(__FILE__, __LINE__, std::string(cls_name) + "::" + kS6Hooks[i] + " is '" + got + "', not '" + want[i] + "'");
	}
}

// A message whose scope is a map's, and that does not reach every level (a world server sends it to the players of that map only).
Msg s6_map_message()
{
	for (int v = 0; v < 0x10000; ++v)
	{
		Scope s = Scope::Core;
		if (scope_row(Msg(v), s) && s == Scope::Map && !reaches_every_level(Msg(v)))
			return Msg(v);
	}
	t::report_failure(__FILE__, __LINE__, "no message of a map's scope");
	return Msg::Hello;
}

// A character / a registry the hooks under test never read (an engine type: incomplete here). Bound to storage, never to null.
CSE_ALifeHumanStalker& s6_any_character()
{
	alignas(16) static unsigned char storage[64] = {};
	return *reinterpret_cast<CSE_ALifeHumanStalker*>(storage);
}

CALifeObjectRegistry& s6_any_registry()
{
	alignas(16) static unsigned char storage[64] = {};
	return *reinterpret_cast<CALifeObjectRegistry*>(storage);
}

ghost::Said s6_said_of_actor()
{
	ghost::Said s;
	s.first = ghost::kActor; // a goodwill of the actor towards object 42
	s.second = 42;
	return s;
}

ghost::Said s6_said_of_others()
{
	ghost::Said s;
	s.first = 41;
	s.second = 42;
	return s;
}

// The cells of one kind: the fake's answers for a player here, a player on another map, a stranger.
struct S6Want
{
	bool level_side;
	bool reaches_elsewhere; // a map's message to a player on another map
	size_t links; // deliver_links: what it recorded
	bool led_elsewhere; // a player on another map whose map server is up
	bool join_from_bridge; // a known bridge
	bool join_save_elsewhere;
	bool level_ready_unknown; // a level nobody said is up
	int lives; // on_world_live
	bool loading_line; // load_text before the world is up, for a level the world server is not on
	bool ghost_word; // ghost_said of the actor
};

void s6_check_fake(const char* kind, const S6Want& w)
{
	t::FakeMode m(t::mode_case(kind));
	CHECK_EQ(std::string(m.name()), std::string(kind));
	m.place(1, t::Spot::Here);
	m.place(2, t::Spot::Elsewhere);
	m.place(3, t::Spot::Elsewhere);
	m.map_down(3); // his map has no map server now
	m.bridge(0x101);
	m.level_up(5);
	m.world_level(9);
	const Msg map_msg = s6_map_message();
	CHECK_EQ(m.level() != nullptr, w.level_side);
	// H-REACH: everything reaches a player here and a stranger; a map's message reaches a player on another map only without a filter
	CHECK(m.reaches(1, map_msg));
	CHECK(m.reaches(77, map_msg));
	CHECK_EQ(m.reaches(2, map_msg), w.reaches_elsewhere);
	CHECK(m.reaches(2, Msg::Chat)); // the session's own: everywhere
	// deliver_links
	Writer payload(8);
	payload.u8(7);
	m.deliver_links(map_msg, payload, Lane::Reliable);
	CHECK_EQ(m.linked.size(), w.links);
	// P-B
	CHECK(!m.led_elsewhere(1));
	CHECK_EQ(m.led_elsewhere(2), w.led_elsewhere);
	CHECK(!m.led_elsewhere(3)); // nobody leads his map now: here, or refused
	CHECK(!m.led_elsewhere(77));
	CHECK_EQ(m.to_level_of(2, Msg::PlayerRevive, payload, Lane::Reliable), w.led_elsewhere);
	CHECK(!m.to_level_of(1, Msg::PlayerRevive, payload, Lane::Reliable));
	CHECK(!m.to_level_of(3, Msg::PlayerRevive, payload, Lane::Reliable));
	CHECK_EQ(m.to_levels.size(), size_t(w.led_elsewhere ? 1 : 0));
	// H-JOIN
	CHECK_EQ(m.join_from_bridge(0x101, Msg::JoinRequest), w.join_from_bridge);
	CHECK(!m.join_from_bridge(1, Msg::JoinRequest)); // a player is never a bridge
	CHECK_EQ(m.join_save(2, s6_any_character()), w.join_save_elsewhere); // the fake never reads the character
	CHECK(!m.join_save(1, s6_any_character()));
	CHECK(m.level_ready(5));
	CHECK_EQ(m.level_ready(6), w.level_ready_unknown);
	m.on_world_live();
	CHECK_EQ(m.lives, w.lives);
	// H-LOADTEXT: only before the world is up, only for a level the world server is not on
	const char* line = m.load_text(4, false);
	CHECK_EQ(line != nullptr, w.loading_line);
	if (line)
		CHECK_EQ(std::string(line), std::string("st_coop_load_server"));
	CHECK(m.load_text(4, true) == nullptr);
	CHECK(m.load_text(9, false) == nullptr);
	// H-GHOSTSAID
	CHECK_EQ(m.ghost_said(s6_said_of_actor()), w.ghost_word);
	CHECK(!m.ghost_said(s6_said_of_others()));
}
} // namespace

// none: the real NoneMode, Mode's "not mine" answers
TEST(s6_none_answers_not_mine)
{
	NoneMode none;
	const Msg map_msg = s6_map_message();
	CHECK(none.level() == nullptr);
	CHECK(none.reaches(0, map_msg) && none.reaches(7, map_msg) && none.reaches(kInvalidPeer, Msg::Chat));
	Writer w(4);
	w.u8(1);
	none.deliver_links(map_msg, w, Lane::Reliable); // nothing to send to, nothing happens
	CHECK(!none.led_elsewhere(7));
	CHECK(!none.to_level_of(7, Msg::PlayerRevive, w, Lane::Reliable));
	CHECK(!none.join_from_bridge(0x101, Msg::JoinRequest));
	CHECK(!none.join_save(7, s6_any_character()));
	CHECK(none.level_ready(3));
	none.on_world_live();
	CHECK(none.load_text(3, false) == nullptr);
	CHECK(!none.ghost_said(s6_said_of_actor()));
	// and the fake's "none" row is the same
	s6_check_fake("none", {false, true, 0, false, false, false, true, 0, false, false});
}

TEST(s6_coop_host_answers)
{
	// one map, his own books; his only link is the host player's
	s6_check_fake("coop_host", {false, true, 1, false, false, false, true, 0, false, false});
	s6_check_real("CoopHostMode");
}

TEST(s6_coop_client_answers)
{
	s6_check_fake("coop_client", {false, true, 0, false, false, false, true, 0, false, false});
	s6_check_real("CoopClientMode");
}

TEST(s6_world_server_answers)
{
	// no player's map: the level filter, the bridges as its links, P-B to the map server of his map, the joins of other maps
	s6_check_fake("world_server", {false, false, 1, true, true, true, false, 0, false, false});
	s6_check_real("WorldServerMode");
}

TEST(s6_map_server_answers)
{
	// its side of its level; every player of its session on its map; no link (its reports go up through up()); its ghost's word is
	// its players'
	s6_check_fake("map_server", {true, true, 0, false, false, false, true, 1, true, true});
	s6_check_real("MapServerMode");
}

TEST(s6_server_client_answers)
{
	s6_check_fake("server_client", {false, true, 0, false, false, false, true, 0, true, false});
	s6_check_real("ServerClientMode");
}

// A map server's side of its level: the money book (the world's balance as last named, a change goes up first), the tents, the trunk
// table, the entity reports; the fake keeps the real one's rules, and the real one's bodies are read from its source.
TEST(s6_level_side_of_a_map_server)
{
	t::FakeMode m(t::mode_case("map_server"));
	LevelSide* side = m.level();
	REQUIRE(side != nullptr);
	uint32_t b = 1;
	CHECK(!side->level_balance(7, b) && b == 0); // the world named nothing yet
	side->level_money_change(7, 0, false); // asks the world for his balance: no entry of its own
	CHECK(!side->level_balance(7, b) && b == 0);
	side->level_balance_heard(7, 500);
	CHECK(side->level_balance(7, b) && b == 500);
	side->level_money_change(7, -200, true);
	CHECK(side->level_balance(7, b) && b == 300);
	side->level_money_change(7, -1000, false); // never below 0
	CHECK(side->level_balance(7, b) && b == 0);
	REQUIRE(m.side().money_up.size() == 3);
	CHECK(m.side().money_up[1].trade && m.side().money_up[1].delta == -200);
	CHECK(side->level_tent_limit(3, 3) && !side->level_tent_limit(2, 3));
	side->level_tent_placed(0x500, 0x2a);
	CHECK(side->level_tent_packed(0x500)); // the world's sweep rolls the camp back
	m.side().trunk[7] = 0x2a;
	m.side().in_world.insert(0x2a);
	CHECK_EQ(int(side->level_character_of(7)), 0x2a);
	CHECK_EQ(int(side->level_character_of(8)), 0xffff);
	CHECK_EQ(side->level_peer_of(0x2a), PeerId(7));
	CHECK_EQ(side->level_peer_of(0x2b), kInvalidPeer);
	CHECK(side->level_in_world(0x2a) && !side->level_in_world(0x2b));
	side->level_entity_up(EntityUp::Died, 0x300, 0xffff);
	REQUIRE(m.side().ups.size() == 1);
	CHECK(m.side().ups[0].kind == EntityUp::Died && m.side().ups[0].id == 0x300);
	// no other kind has a side of a level
	for (const t::ModeCase& c : t::mode_cases())
	{
		t::FakeMode k(c);
		CHECK_EQ(k.level() != nullptr, std::string(c.name) == "map_server");
	}

	const std::string code = s6_code(s6_read(s6_engine_src() + "/xrGame/coop/srv/coop_srv_mode.cpp"));
	const std::string cls = s6_class(code, "MapLevelSide");
	REQUIRE(!cls.empty());
	const std::string money = s6_hook(cls, "level_money_change");
	CHECK(money.find("levels::up_money(peer, delta, trade);") == 0); // up first, a change of nothing included
	CHECK(s6_has(money, "if (!delta) return;"));
	CHECK(s6_has(money, "_max<s64>(0, s64(balance) + delta)"));
	CHECK(s6_has(s6_hook(cls, "level_balance"), "return it != m_balances.end();"));
	CHECK_EQ(s6_hook(cls, "level_balance_heard"), std::string("m_balances[peer] = balance;"));
	CHECK_EQ(s6_hook(cls, "level_item_tell"), std::string("items::level_item_tell(id, section, blob);"));
	CHECK_EQ(s6_hook(cls, "level_tent_limit"), std::string("return world_tents >= limit;"));
	CHECK_EQ(s6_hook(cls, "level_tent_placed"), std::string("levels::up_tent(tent, character);"));
	CHECK_EQ(s6_hook(cls, "level_tent_packed"), std::string("return true;"));
	CHECK_EQ(s6_hook(cls, "level_in_world"), std::string("return join::host_player_in_world(character);"));
	CHECK(s6_has(s6_hook(cls, "level_marker"), "script::queue_callback(\"coop_death_marker\""));
	CHECK(s6_has(s6_hook(cls, "level_character_of"), "mapserver::trunk_peers().on()"));
	CHECK(s6_has(s6_hook(cls, "level_peer_of"), "mapserver::trunk_peers().on()"));
	const std::string up = s6_hook(cls, "level_entity_up");
	for (const char* call : {"levels::up_spawned(id);", "levels::xfer_on_released(id);", "levels::up_parent(id, other);",
	         "levels::up_died(id, other);"})
		CHECK(s6_has(up, call));
	// the bridge of a body and the server's loading line: today's conditions, word for word
	CHECK_EQ(s6_function(code, R"(PeerId\s+level_bridge)"),
	    std::string("return peer != kInvalidPeer && !levels::on_host_level(peer) ? mapserver::bridge_of(levels::level_of_player(peer)) "
	                ": kInvalidPeer;"));
	CHECK_EQ(s6_function(code, R"(const\s+char\s*\*\s*server_load_text)"),
	    std::string("return !world_up && screen_level != levels::level_of_player(kHostPeer) ? \"st_coop_load_server\" : nullptr;"));
}

// The process's hooks: the switchboard asks every layer (the server's first); the server's layer places the ghost of a map server and
// of the world server, and writes the world server's console line; the co-op's layer has neither.
TEST(s6_layer_hooks_of_the_process)
{
	const std::string src = s6_engine_src();
	const std::string board = s6_code(s6_read(src + "/xrGame/coop/coop_mode.cpp"));
	REQUIRE(!board.empty());
	CHECK_EQ(s6_function(board, R"(bool\s+place_ghost)"),
	    std::string("for (Layer* layer : layers().list) if (layer->place_ghost(objects)) return true; return false;"));
	CHECK_EQ(s6_function(board, R"(void\s+console_line)"),
	    std::string("if (!line) return; for (Layer* layer : layers().list) layer->console_line(line);"));
	const std::string srv = s6_class(s6_code(s6_read(src + "/xrGame/coop/srv/coop_srv_mode.cpp")), "ServerLayer");
	REQUIRE(!srv.empty());
	const std::string ghost = s6_hook(srv, "place_ghost");
	CHECK(s6_has(ghost, "if (is_map_server() && join::client_loading_world()) return place_map_ghost(objects);"));
	CHECK(s6_has(ghost, "if (!dedicated::on()) return false;"));
	CHECK(s6_has(ghost, "if (!dedicated::place_ghost(objects)) FATAL("));
	CHECK_EQ(s6_hook(srv, "console_line"),
	    std::string("if (!dedicated::on()) return; if (!dedicated::log_shown(line, coop_console::log_level())) coop_console::print(line); "
	                "dedicated::answer_line(line);"));
	const std::string map_ghost = s6_function(srv, R"(static\s+bool\s+place_map_ghost)");
	CHECK(s6_has(map_ghost, "const u16 vertex = mapserver::key().graph;"));
	CHECK(s6_has(map_ghost, "mgr().stop(\"the world has no place for this map server\");"));
	CHECK(s6_has(map_ghost, "actor->m_tGraphID = vertex;"));
	const std::string coop = s6_class(s6_code(s6_read(src + "/xrGame/coop/hostplay/coop_hostplay_mode.cpp")), "CoopLayer");
	REQUIRE(!coop.empty());
	CHECK_EQ(s6_hook(coop, "place_ghost"), std::string("<none>"));
	CHECK_EQ(s6_hook(coop, "console_line"), std::string("<none>"));
	// a Layer that writes neither answers none's: nothing taken, nothing written
	struct Quiet final : Layer
	{
		const char* name() const override { return "quiet"; }
		bool boot_frame() override { return false; }
		Mode* mode_of(Entry, SessionMode) override { return nullptr; }
	} quiet;
	CHECK(!quiet.place_ghost(s6_any_registry()));
	quiet.console_line("x");
}

// The Core asks the hooks, never the mode's name: the header names no layer, and none answers "not mine" by inheriting Mode's answers.
TEST(s6_contract_header_shape)
{
	const std::string header = s6_code(s6_read(s6_engine_src() + "/xrCoop/coop_mode.h"));
	REQUIRE(!header.empty());
	const std::string none = s6_class(header, "NoneMode");
	REQUIRE(!none.empty());
	for (size_t i = 0; i < kS6HookCount; ++i)
		CHECK_EQ(s6_hook(none, kS6Hooks[i]), std::string("<none>")); // Mode's own answer
	CHECK(s6_has(header, "virtual LevelSide* level() { return nullptr; }"));
	CHECK(!std::regex_search(header, std::regex(R"(\b(?:srv|hostplay)\s*::)")));
}
