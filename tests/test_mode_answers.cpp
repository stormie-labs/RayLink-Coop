// Anomaly Coop unit tests: the interface of the two modes (docs/MODES.md section 4, xrCoop/coop_mode.h, step S4 of
// docs/plans/2026-11-18-two-modes.md).
//
// - none (no session) and the holder: none before a session, one mode per session, none again after it;
// - the answer table of the six process kinds (tests/support/fake_mode.h, MODE_CASES), cell by cell, as docs/MODES.md section 4 and
//   the Lua contract (docs/contracts/coop_mode_api.md section 2) give it;
// - the real modes' rows (hostplay/coop_hostplay_mode.cpp, srv/coop_srv_mode.cpp, `constexpr ModeAnswers k<Name>{...}`) are the
//   rows of that table: the engine files cannot run here, their answers are read from the source;
// - the Core's shape the step asks for, read from the sources: net::host_broadcast / host_stream / client_send forward to the mode
//   in one line (P-B); the Manager installs no handler table of its own on a host (each mode its own; the co-op host's install
//   names no server table); the frame of the levels runs only through the mode (P-E); a map server's weather is its mode's own step;
//   a client's mode comes from the Welcome, not from the first LevelMap; the switchboard names each layer once.
#include "test_util.h"
#include "coop_mode.h"
#include "coop_roles.h"
#include "support/fake_mode.h"

#include <fstream>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using namespace coop;
using t::ModeCase;

namespace
{
// engine/src, found next to this source file (tests\ -> ..\engine\src)
std::string engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	// tests\ or temp\s4c\ (while the test is written)
	std::ifstream probe(here + "/../engine/src/xrCoop/coop_mode.h");
	if (probe)
		return here + "/../engine/src";
	return here + "/../../engine/src";
}

std::string read_text(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The source with // and /* */ comments blanked (string literals kept).
std::string code_of(const std::string& src)
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

// The body (between its braces) of the first function whose head matches `head` (a regex ending at the name); "" and a failure of
// the test when there is none.
std::string body_of(const std::string& code, const std::string& head)
{
	std::smatch m;
	const std::regex rx(head + R"(\s*\([^;{]*\)\s*(?:const\s*)?(?:override\s*)?(?:final\s*)?\{)");
	if (!std::regex_search(code, m, rx))
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return "";
	}
	size_t i = size_t(m.position(0) + m.length(0));
	const size_t start = i;
	int depth = 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : code.substr(start, i - 1 - start);
}

// Statements of a body, white space collapsed.
std::vector<std::string> statements(const std::string& body)
{
	std::vector<std::string> out;
	std::string cur;
	for (const char c : body)
	{
		if (c == ';')
		{
			std::string s = std::regex_replace(cur, std::regex(R"(\s+)"), " ");
			s = std::regex_replace(s, std::regex(R"(^ | $)"), "");
			if (!s.empty())
				out.push_back(s);
			cur.clear();
		}
		else
			cur += c;
	}
	return out;
}

std::string collapse(const std::string& s)
{
	std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

const ModeCase& row(const char* name)
{
	const ModeCase& c = t::mode_case(name);
	CHECK_EQ(std::string(c.name), std::string(name));
	return c;
}

// The rows `constexpr ModeAnswers k<Name>{...}` of a mode file: name -> answers (roles from the coop_roles.h function named).
std::map<std::string, ModeAnswers> rows_of(const std::string& path, std::vector<std::string>& problems)
{
	std::map<std::string, ModeAnswers> out;
	const std::string code = code_of(read_text(path));
	if (code.empty())
	{
		problems.push_back("cannot read " + path);
		return out;
	}
	const std::regex rx(R"(constexpr\s+ModeAnswers\s+k(\w+)\s*\{([^}]*)\})");
	for (std::sregex_iterator it(code.begin(), code.end(), rx), end; it != end; ++it)
	{
		std::vector<std::string> parts;
		std::stringstream ss((*it)[2].str());
		std::string part;
		while (std::getline(ss, part, ','))
			parts.push_back(collapse(part));
		if (parts.size() != 5)
		{
			problems.push_back("k" + (*it)[1].str() + ": " + std::to_string(parts.size()) + " fields, 5 expected");
			continue;
		}
		ModeAnswers a{};
		bool* flags[4] = {&a.actor_is_player, &a.decides_world, &a.leads_level, &a.group_travels};
		bool ok = true;
		for (int i = 0; i < 4; ++i)
		{
			if (parts[size_t(i)] == "true")
				*flags[i] = true;
			else if (parts[size_t(i)] == "false")
				*flags[i] = false;
			else
				ok = false;
		}
		const std::string roles = parts[4];
		if (roles == "host_roles()")
			a.roles = host_roles();
		else if (roles == "client_roles()")
			a.roles = client_roles();
		else if (roles == "dedicated_roles()")
			a.roles = dedicated_roles();
		else if (roles == "map_server_roles()")
			a.roles = map_server_roles();
		else
			ok = false;
		if (!ok)
		{
			problems.push_back("k" + (*it)[1].str() + ": a field is not a literal / a coop_roles.h function");
			continue;
		}
		out[(*it)[1].str()] = a;
	}
	return out;
}

bool same(const ModeAnswers& a, const ModeAnswers& b)
{
	return a.actor_is_player == b.actor_is_player && a.decides_world == b.decides_world && a.leads_level == b.leads_level &&
	    a.group_travels == b.group_travels && a.roles == b.roles;
}

class Plain final : public ModeWithAnswers
{
public:
	explicit Plain(const ModeAnswers& a) : ModeWithAnswers(a) {}
	const char* name() const override { return "plain"; }
	Where where(PeerId) const override { return Where::Here; }
	Decider decider_of(uint16_t) const override { return Decider::This; }
	bool facts_of(uint16_t, levels::BodyFacts&) const override { return false; }
	void deliver(Msg, const Writer&, Lane, PeerId) override {}
	void stream(Msg, const Writer&, PeerId) override {}
	void up(Msg, const Writer&, Lane) override {}
	void configure(SessionConfig&) const override {}
	void install(ModeTables&) override {}
	void frame() override {}
	void session_over() override {}
	bool online_elsewhere(uint16_t) const override { return false; }
	bool binder_may_update(CGameObject*) override { return true; }
	void held_update() override {}
	void switched_offline(uint16_t) override {}
	bool takes_own_ids() const override { return false; }
	uint16_t own_free_id() override { return 0xffff; }
};
} // namespace

TEST(mode_none_answers_single_player)
{
	NoneMode none;
	CHECK_EQ(std::string(none.name()), std::string("none"));
	for (const PeerId p : {PeerId(0), PeerId(1), PeerId(15), kInvalidPeer})
		CHECK(none.where(p) == Where::Away);
	for (const uint16_t c : {uint16_t(0), uint16_t(1), uint16_t(0xfffe), uint16_t(0xffff)})
		CHECK(none.decider_of(c) == Decider::Nobody);
	CHECK(none.actor_is_player()); // single player: the actor is the player
	CHECK(!none.decides_world());
	CHECK(!none.leads_level());
	CHECK(!none.group_travels());
	CHECK_EQ(int(none.roles()), 0);
	CHECK(!none.online_elsewhere(5));
	CHECK(none.binder_may_update(nullptr));
	CHECK(!none.takes_own_ids());
	CHECK_EQ(int(none.own_free_id()), 0xffff);
}

TEST(mode_with_answers_gives_its_row)
{
	for (const ModeCase& c : t::mode_cases())
	{
		Plain p(c.answers);
		CHECK_EQ(p.actor_is_player(), c.answers.actor_is_player);
		CHECK_EQ(p.decides_world(), c.answers.decides_world);
		CHECK_EQ(p.leads_level(), c.answers.leads_level);
		CHECK_EQ(p.group_travels(), c.answers.group_travels);
		CHECK_EQ(int(p.roles()), int(c.answers.roles));
	}
}

TEST(mode_slot_one_mode_per_session)
{
	ModeSlot slot;
	CHECK(!slot.installed());
	CHECK_EQ(std::string(slot.get().name()), std::string("none")); // before a session
	Plain a(kNoSessionAnswers), b(kNoSessionAnswers);
	CHECK(slot.install(a));
	CHECK(slot.installed());
	CHECK(&slot.get() == &a);
	CHECK(slot.install(a)); // the same mode again (a client's map server Welcome): it stays
	CHECK(!slot.install(b)); // another one is refused while the session runs
	CHECK(&slot.get() == &a);
	slot.reset(); // set_phase(Off)
	CHECK(!slot.installed());
	CHECK_EQ(std::string(slot.get().name()), std::string("none"));
	CHECK(slot.install(b)); // the next session
	CHECK(&slot.get() == &b);
	const ModeSlot& cs = slot;
	CHECK(&cs.get() == &b);
}

TEST(mode_cases_are_the_six_process_kinds)
{
	std::vector<std::string> names;
#define T_MODE_NAME(n) names.push_back(#n);
	MODE_CASES(T_MODE_NAME)
#undef T_MODE_NAME
	REQUIRE(names.size() == t::mode_cases().size());
	for (size_t i = 0; i < names.size(); ++i)
		CHECK_EQ(std::string(t::mode_cases()[i].name), names[i]);
	CHECK_EQ(std::string(t::mode_case("no such kind").name), std::string("none"));
}

// docs/MODES.md section 4, column by column; the Lua contract docs/contracts/coop_mode_api.md section 2 for the rows it adds.
TEST(mode_answer_table)
{
	const ModeCase& ch = row("coop_host");
	const ModeCase& cc = row("coop_client");
	const ModeCase& ws = row("world_server");
	const ModeCase& ms = row("map_server");
	const ModeCase& sc = row("server_client");
	const ModeCase& no = row("none");

	// actor_is_player: true / true / false (ghost) / false / true / true (single player)
	CHECK(ch.answers.actor_is_player && cc.answers.actor_is_player && !ws.answers.actor_is_player && !ms.answers.actor_is_player &&
	      sc.answers.actor_is_player && no.answers.actor_is_player);
	// decides_world: the co-op host and the world server
	CHECK(ch.answers.decides_world && !cc.answers.decides_world && ws.answers.decides_world && !ms.answers.decides_world &&
	      !sc.answers.decides_world && !no.answers.decides_world);
	// leads_level: the co-op host and a map server; NOT the world server (fake_start)
	CHECK(ch.answers.leads_level && !cc.answers.leads_level && !ws.answers.leads_level && ms.answers.leads_level &&
	      !sc.answers.leads_level && !no.answers.leads_level);
	// group_travels: the co-op only
	CHECK(ch.answers.group_travels && cc.answers.group_travels && !ws.answers.group_travels && !ms.answers.group_travels &&
	      !sc.answers.group_travels && !no.answers.group_travels);
	// the roles of today's processes (xrCoop/coop_roles.h): is_map_authority() = decides_world() || leads_level() in every column
	CHECK_EQ(int(ch.answers.roles), int(host_roles()));
	CHECK_EQ(int(cc.answers.roles), int(client_roles()));
	CHECK_EQ(int(ws.answers.roles), int(dedicated_roles()));
	CHECK_EQ(int(ms.answers.roles), int(map_server_roles()));
	CHECK_EQ(int(sc.answers.roles), int(client_roles()));
	CHECK_EQ(int(no.answers.roles), 0);
	for (const ModeCase& c : t::mode_cases())
	{
		CHECK_EQ(has(c.answers.roles, ProcessRole::MapAuthority), c.answers.decides_world || c.answers.leads_level);
		CHECK_EQ(has(c.answers.roles, ProcessRole::WorldServer), c.answers.decides_world);
		CHECK_EQ(has(c.answers.roles, ProcessRole::Player), c.answers.actor_is_player && c.answers.roles != 0);
	}

	// where(peer): co-op Here for every seated one (Joining while his character loads); world server Away (Joining before he is
	// placed, its own seat a ghost); a map server Here for the players of its map; none Away
	CHECK(ch.where_self == Where::Here && ch.where_here == Where::Here && ch.where_elsewhere == Where::Here &&
	      ch.where_joining == Where::Joining && ch.where_stranger == Where::Here);
	CHECK(cc.where_self == Where::Here && cc.where_here == Where::Here && cc.where_elsewhere == Where::Here &&
	      cc.where_joining == Where::Here && cc.where_stranger == Where::Here);
	CHECK(ws.where_self == Where::Away && ws.where_here == Where::Away && ws.where_elsewhere == Where::Away &&
	      ws.where_joining == Where::Joining && ws.where_stranger == Where::Joining);
	CHECK(ms.where_self == Where::Away && ms.where_here == Where::Here && ms.where_elsewhere == Where::Away &&
	      ms.where_joining == Where::Joining && ms.where_stranger == Where::Away);
	CHECK(sc.where_self == Where::Here && sc.where_here == Where::Here && sc.where_elsewhere == Where::Away &&
	      sc.where_stranger == Where::Away);
	CHECK(no.where_self == Where::Away && no.where_here == Where::Away && no.where_elsewhere == Where::Away &&
	      no.where_joining == Where::Away && no.where_stranger == Where::Away);
	// levels::on_host_level(p) == (where(p) != Away) on the processes that host (temp/b58/s6_map/README.md): the co-op host always,
	// the world server only before a player is placed (and for a stranger), a map server for its players
	CHECK(ch.where_elsewhere != Where::Away && ch.where_stranger != Where::Away);
	CHECK(ws.where_joining != Where::Away && ws.where_here == Where::Away);

	// decider_of(character): co-op host This, world server Other (This while nobody leads his map yet), map server This for its
	// map, a client Other; a stranger and a ghost nobody's
	CHECK(ch.decider_self == Decider::This && ch.decider_here == Decider::This && ch.decider_elsewhere == Decider::This &&
	      ch.decider_joining == Decider::This);
	CHECK(cc.decider_self == Decider::Other && cc.decider_here == Decider::Other && cc.decider_elsewhere == Decider::Other);
	CHECK(ws.decider_self == Decider::Nobody && ws.decider_here == Decider::Other && ws.decider_elsewhere == Decider::Other &&
	      ws.decider_joining == Decider::This);
	CHECK(ms.decider_self == Decider::Nobody && ms.decider_here == Decider::This && ms.decider_elsewhere == Decider::Other);
	CHECK(sc.decider_self == Decider::Other && sc.decider_here == Decider::Other && sc.decider_elsewhere == Decider::Other);
	for (const ModeCase& c : t::mode_cases())
		CHECK(c.decider_stranger == Decider::Nobody);
	CHECK(no.decider_self == Decider::Nobody && no.decider_here == Decider::Nobody && no.decider_joining == Decider::Nobody);
	// levels::host_character_elsewhere(c) == (decider_of(c) == Other) on the processes that host: never on the co-op host
	CHECK(ch.decider_elsewhere != Decider::Other && ws.decider_elsewhere == Decider::Other);

	// delivery: a world change reaches somebody from the co-op host, the world server, a map server; `up` reaches the decider
	// from every process but the world server (it decides) and none
	CHECK(ch.delivers && !cc.delivers && ws.delivers && ms.delivers && !sc.delivers && !no.delivers);
	CHECK(ch.sends_up && cc.sends_up && !ws.sends_up && ms.sends_up && sc.sends_up && !no.sends_up);
}

TEST(mode_fake_answers_by_spot_and_records_sends)
{
	for (const ModeCase& c : t::mode_cases())
	{
		t::FakeMode m(c);
		m.place(0, t::Spot::Self);
		m.place(3, t::Spot::Here);
		m.place(4, t::Spot::Elsewhere);
		m.place(5, t::Spot::Joining);
		m.character(0x103, 3);
		m.character(0x104, 4);
		m.character(0x105, 5);
		CHECK(m.where(0) == c.where_self);
		CHECK(m.where(3) == c.where_here);
		CHECK(m.where(4) == c.where_elsewhere);
		CHECK(m.where(5) == c.where_joining);
		CHECK(m.where(9) == c.where_stranger);
		CHECK(m.decider_of(0) == c.decider_self);
		CHECK(m.decider_of(0x103) == c.decider_here);
		CHECK(m.decider_of(0x104) == c.decider_elsewhere);
		CHECK(m.decider_of(0x105) == c.decider_joining);
		CHECK(m.decider_of(0x999) == c.decider_stranger);
		Writer w(4);
		w.u32(7);
		m.deliver(Msg::GameBase, w, Lane::Reliable, 3);
		m.stream(Msg::GameBase, w, kInvalidPeer);
		m.up(Msg::GameBase, w, Lane::Reliable);
		CHECK_EQ(m.delivered.size(), size_t(c.delivers ? 2 : 0));
		CHECK_EQ(m.sent_up.size(), size_t(c.sends_up ? 1 : 0));
		if (c.delivers)
		{
			CHECK(m.delivered[0].except == 3 && !m.delivered[0].stream && m.delivered[0].lane == Lane::Reliable);
			CHECK(m.delivered[1].stream && m.delivered[1].lane == Lane::Unreliable);
		}
	}
}

// The real modes: their rows are the table's rows (one per process kind; none is NoneMode itself).
TEST(mode_rows_of_the_real_modes)
{
	std::vector<std::string> problems;
	const std::string src = engine_src();
	const auto coop = rows_of(src + "/xrGame/coop/hostplay/coop_hostplay_mode.cpp", problems);
	const auto srv = rows_of(src + "/xrGame/coop/srv/coop_srv_mode.cpp", problems);
	for (const std::string& p : problems)
		t::report_failure(__FILE__, __LINE__, p);
	const std::map<std::string, std::pair<const std::map<std::string, ModeAnswers>*, const char*>> want = {
		{"CoopHost", {&coop, "coop_host"}},
		{"CoopClient", {&coop, "coop_client"}},
		{"WorldServer", {&srv, "world_server"}},
		{"MapServer", {&srv, "map_server"}},
		{"ServerClient", {&srv, "server_client"}},
	};
	for (const auto& w : want)
	{
		const auto it = w.second.first->find(w.first);
		if (it == w.second.first->end())
		{
			t::report_failure(__FILE__, __LINE__, "no row k" + w.first);
			continue;
		}
		if (!same(it->second, row(w.second.second).answers))
			t::report_failure(__FILE__, __LINE__, "k" + w.first + " differs from the " + w.second.second + " row of the table");
	}
	// a layer has the rows of its own process kinds only: the co-op file names no server kind and the other way round
	CHECK_EQ(coop.size(), size_t(2));
	CHECK_EQ(srv.size(), size_t(3));
	const NoneMode none;
	CHECK(same({none.actor_is_player(), none.decides_world(), none.leads_level(), none.group_travels(), none.roles()},
	    row("none").answers));
}

// P-B: the three old functions forward to the mode in one line; their callers do not change.
TEST(mode_delivery_forwards_in_one_line)
{
	const std::string code = code_of(read_text(engine_src() + "/xrGame/coop/coop_net.cpp"));
	REQUIRE(!code.empty());
	const std::vector<std::string> b = statements(body_of(code, R"(void\s+host_broadcast)"));
	const std::vector<std::string> s = statements(body_of(code, R"(void\s+host_stream)"));
	const std::vector<std::string> c = statements(body_of(code, R"(void\s+client_send)"));
	REQUIRE(b.size() == 1 && s.size() == 1 && c.size() == 1);
	CHECK_EQ(b[0], std::string("mode().deliver(type, payload, lane, except)"));
	CHECK_EQ(s[0], std::string("mode().stream(type, payload, except)"));
	CHECK_EQ(c[0], std::string("mode().up(type, payload, lane)"));
	// the Core's delivery names no layer: no bridges, no map server filter, no level filter, no LocalLink
	for (const char* word : {"mapserver::", "bridge", "passes_to", "split", "local_link", "is_world_server", "is_map_server"})
		CHECK(code.find(word) == std::string::npos);
}

// P-E: each mode installs its own tables; the co-op start never installs a server table.
TEST(mode_tables_are_each_modes_own)
{
	const std::string src = engine_src();
	const std::string manager = code_of(read_text(src + "/xrGame/coop/coop_manager.cpp"));
	REQUIRE(!manager.empty());
	CHECK(manager.find("install_server(") == std::string::npos); // no host table of the Manager's own
	CHECK(manager.find("mapserver::install") == std::string::npos);
	const std::string coop = code_of(read_text(src + "/xrGame/coop/hostplay/coop_hostplay_mode.cpp"));
	REQUIRE(!coop.empty());
	for (const char* word : {"mapserver", "xfer_", "host_incoming", "on_operator_command", "dedicated", "srv::"})
		CHECK(coop.find(word) == std::string::npos);
	CHECK(!std::regex_search(coop, std::regex(R"(levels::(?!BodyFacts\b))"))); // nothing of the levels' table in co-op
	const std::string host_install = body_of(coop, R"(void\s+install)");
	CHECK(host_install.find("set_in_filter(nullptr)") != std::string::npos);
	CHECK(host_install.find("join::install_server(") != std::string::npos);
	CHECK(host_install.find("install_client(tables.link)") != std::string::npos);
	const std::string srv = code_of(read_text(src + "/xrGame/coop/srv/coop_srv_mode.cpp"));
	REQUIRE(!srv.empty());
	CHECK(srv.find("mapserver::install_server(") != std::string::npos);
	CHECK(srv.find("xfer_install_server(") != std::string::npos);
	CHECK(srv.find("xfer_install_client(") != std::string::npos);
	CHECK(srv.find("set_in_filter(&mapserver::host_incoming)") != std::string::npos);
	// levels::install_server / install_client keep no server table: the transfers and the in-filter are the server modes'
	const std::string levels = code_of(read_text(src + "/xrGame/coop/coop_levels.cpp"));
	REQUIRE(!levels.empty());
	CHECK(body_of(levels, R"(void\s+install_server)").find("xfer_") == std::string::npos);
	CHECK(body_of(levels, R"(void\s+install_client)").find("xfer_") == std::string::npos);
	CHECK(levels.find("set_in_filter") == std::string::npos);
}

// P-E: the frame of the levels runs through the mode; a map server's weather is its own step, not the co-op host's.
TEST(mode_frames_are_each_modes_own)
{
	const std::string src = engine_src();
	const std::string sync = code_of(read_text(src + "/xrGame/coop/coop_sync.cpp"));
	REQUIRE(!sync.empty());
	const size_t table = sync.find("kFrame[] = {"); // the frame pass of the module table
	REQUIRE(table != std::string::npos);
	const std::string frame = sync.substr(table, sync.find("};", table) - table);
	CHECK(frame.find("mode().frame()") != std::string::npos);
	CHECK(frame.find("levels::frame") == std::string::npos);
	const std::string world = code_of(read_text(src + "/xrGame/coop/coop_worldstate.cpp"));
	REQUIRE(!world.empty());
	CHECK(body_of(world, R"(void\s+frame)").find("is_map_server") == std::string::npos);
	CHECK(body_of(world, R"(void\s+level_sky_frame)").find("host_weather_frame") == std::string::npos);
	const std::string srv = code_of(read_text(src + "/xrGame/coop/srv/coop_srv_mode.cpp"));
	CHECK(srv.find("level_sky_frame(") != std::string::npos);
	CHECK(srv.find("levels::frame()") != std::string::npos);
	const std::string coop = code_of(read_text(src + "/xrGame/coop/hostplay/coop_hostplay_mode.cpp"));
	CHECK(body_of(coop, R"(void\s+frame)").find_first_not_of(" \t\r\n") == std::string::npos); // nothing of the server in co-op
}

// Protocol 33 / S4: a client knows its session's mode from the Welcome; the first LevelMap no longer says it.
TEST(mode_of_a_client_from_the_welcome)
{
	const std::string src = engine_src();
	const std::string levels = code_of(read_text(src + "/xrGame/coop/coop_levels.cpp"));
	REQUIRE(!levels.empty());
	const std::string split = body_of(levels, R"(bool\s+split)");
	REQUIRE(!split.empty());
	CHECK(split.find("view") == std::string::npos);
	CHECK(split.find("LevelMapMsg::Split") == std::string::npos);
	CHECK(split.find("session_mode()") != std::string::npos);
	const std::string manager = code_of(read_text(src + "/xrGame/coop/coop_manager.cpp"));
	CHECK(manager.find("enter_mode_of_welcome(w.mode)") != std::string::npos); // on_welcome, before set_phase(Handshaked)
	CHECK(manager.find("mode_for(Entry::Client, said)") != std::string::npos);
}

// The switchboard: the one place of the Core that names the layers, each once.
TEST(mode_switchboard_names_each_layer_once)
{
	const std::string src = engine_src();
	const std::string board = code_of(read_text(src + "/xrGame/coop/coop_mode.cpp"));
	REQUIRE(!board.empty());
	auto count = [&board](const std::string& what)
	{
		size_t n = 0;
		for (size_t at = board.find(what); at != std::string::npos; at = board.find(what, at + 1))
			++n;
		return n;
	};
	CHECK_EQ(count("srv::layer()"), size_t(1));
	CHECK_EQ(count("hostplay::layer()"), size_t(1));
	// and nothing else of either: no predicate of a mode, no function of a layer
	for (const char* word : {"dedicated", "mapserver", "is_map_server", "is_world_server", "levels::", "Steam"})
		CHECK(board.find(word) == std::string::npos);
	// nobody else of the Core names a layer's mode entry
	for (const char* file : {"/xrGame/coop/coop_manager.cpp", "/xrGame/coop/coop_net.cpp", "/xrGame/coop/coop_sync.cpp",
	         "/xrGame/coop/coop_levels.cpp", "/xrGame/coop/coop_worldstate.cpp"})
	{
		const std::string code = code_of(read_text(src + file));
		CHECK(code.find("srv::") == std::string::npos);
		CHECK(code.find("hostplay::") == std::string::npos);
	}
}


// R32 W1 (design R32-final.md §1 W1.2, §8a A3-A8): every real mode says who writes an object; none is left to Mode's permissive
// default (This). The co-op host writes everything, a player's machine (co-op client, server player) nothing (its host does), the
// world server and a map server fill the writer rule's Seat from their own tables. Read from the sources: the engine files cannot
// run here (the pure rule itself is tests/test_writer_rules.cpp).
namespace
{
std::string class_body(const std::string& code, const std::string& name)
{
	const size_t at = code.find("class " + name + " final");
	if (at == std::string::npos)
		return "";
	size_t i = code.find('{', at);
	if (i == std::string::npos)
		return "";
	const size_t start = ++i;
	int depth = 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : code.substr(start, i - 1 - start);
}

void expect_in(const std::string& where, const std::string& text, const std::string& what)
{
	if (collapse(text).find(collapse(what)) == std::string::npos)
		t::report_failure(__FILE__, __LINE__, where + " lacks: " + what);
}
} // namespace

TEST(mode_writer_answers_of_the_real_modes)
{
	const std::string src = engine_src();
	const std::string coop = code_of(read_text(src + "/xrGame/coop/hostplay/coop_hostplay_mode.cpp"));
	const std::string srv = code_of(read_text(src + "/xrGame/coop/srv/coop_srv_mode.cpp"));
	CHECK(!coop.empty() && !srv.empty());
	expect_in("CoopHostMode", class_body(coop, "CoopHostMode"),
	    "writer::Writer writer_of(const writer::RootFacts&) const override { return writer::this_process(); }");
	expect_in("CoopClientMode", class_body(coop, "CoopClientMode"),
	    "writer::Writer writer_of(const writer::RootFacts&) const override { return writer::other(kHostPeer); }");
	expect_in("ServerClientMode", class_body(srv, "ServerClientMode"),
	    "writer::Writer writer_of(const writer::RootFacts&) const override { return writer::other(kHostPeer); }");
	expect_in("WorldServerMode", class_body(srv, "WorldServerMode"),
	    "writer::Writer writer_of(const writer::RootFacts& r) const override { return world_writer_of(r); }");
	expect_in("MapServerMode", class_body(srv, "MapServerMode"),
	    "writer::Writer writer_of(const writer::RootFacts& r) const override { return map_writer_of(r); }");
}

namespace
{
// The body of `struct <name>` in a source with its comments blanked ("" when there is none).
std::string struct_body(const std::string& code, const std::string& name)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(R"(\bstruct\s+)" + name + R"(\s*\{)")))
		return "";
	size_t i = size_t(m.position(0) + m.length(0));
	const size_t start = i;
	int depth = 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : code.substr(start, i - 1 - start);
}
} // namespace

// Review R32 B2-B4: the server's processes answer through the pure seats of xrCoop/srv/coop_writer_seats.h (world_seat, map_seat,
// world_character_seat; tests/test_writer_answers.cpp runs them row by row) and fill only the tables those ask; the world server's
// decider_of reads the same character seat as its writer answer, a map server's the same "a player of its session plays him".
TEST(mode_server_writer_reads_its_tables)
{
	const std::string srv = code_of(read_text(engine_src() + "/xrGame/coop/srv/coop_srv_mode.cpp"));
	const std::string lead = body_of(srv, R"(writer::MapLead\s+world_lead_of)");
	expect_in("world_lead_of", lead, "writer::lead_of(mapserver::host_life_of(level))"); // §8a A4: a stopping server writes
	expect_in("world_lead_of", lead, "mapserver::bridge_of(level)");
	CHECK(lead.find("host_ready") == std::string::npos); // §8a A4: never host_ready

	// who plays a character: a connected player of this session (a parked or retired character's player is none)
	const std::string played = body_of(srv, R"(PeerId\s+played_by)");
	expect_in("played_by", played, "if (character == writer::kGhostId) return kInvalidPeer;");
	expect_in("played_by", played, "join::peer_of_proxy(character)");
	expect_in("played_by", played, "peer != kInvalidPeer && mgr().session().peer(peer) ? peer : kInvalidPeer");

	const std::string wt = struct_body(srv, "WorldTables");
	CHECK(!wt.empty());
	expect_in("WorldTables", wt, "PeerId player_of(u16 character) const { return played_by(character); }");
	expect_in("WorldTables", wt, "u16 seat_of(PeerId player) const { return levels::level_of_player(player); }");
	expect_in("WorldTables", wt, "u16 own_map() const { return levels::my_level(); }");
	expect_in("WorldTables", wt, "writer::MapLead lead_of_map(u16 level) const { return world_lead_of(level); }");
	expect_in("WorldTables", wt, "PeerId holder_of(u16 root) const { return levels::holder_of(root); }");
	expect_in("WorldTables", wt, "u16 map_of_bridge(PeerId bridge) const { return mapserver::level_of_bridge(bridge); }");
	expect_in("world_writer_of", body_of(srv, R"(writer::Writer\s+world_writer_of)"), "return writer::world_answer(r, WorldTables{});");

	const std::string mt = struct_body(srv, "MapTables");
	CHECK(!mt.empty());
	expect_in("MapTables", mt, "bool plays_here(u16 character) const { return played_by(character) != kInvalidPeer; }");
	expect_in("MapTables", mt, "bool authors(u16 root) const { return levels::xfer_authors(root); }");
	// review R32 B3: srv/coop_levels_xfer.cpp defines it; where it is declared (coop_levels.h, or a local line until that header is
	// in) is the compiler's to check, not this test's
	expect_in("MapTables", mt, "bool born(u16 root) const { return levels::xfer_born(root); }");
	const std::string map = body_of(srv, R"(writer::Writer\s+map_writer_of)");
	expect_in("map_writer_of", map, "mapserver::server_leads() ? writer::Lead::Leads : writer::Lead::Starting");
	expect_in("map_writer_of", map, "return writer::map_answer(r, levels::my_level(), here, MapTables{});");

	// the deciders read the same tables (review R32 B2)
	const std::string wd = body_of(class_body(srv, "WorldServerMode"), R"(Decider\s+decider_of)");
	expect_in("WorldServerMode::decider_of", wd, "writer::world_character_seat(character, WorldTables{})");
	expect_in("WorldServerMode::decider_of", wd, "if (s.player == kInvalidPeer) return Decider::Nobody;");
	expect_in("WorldServerMode::decider_of", wd, "return s.map != writer::kNoLevel ? Decider::Other : Decider::This;");
	const std::string md = body_of(class_body(srv, "MapServerMode"), R"(Decider\s+decider_of)");
	expect_in("MapServerMode::decider_of", md, "if (MapTables{}.plays_here(character)) return Decider::This;");
}

// Review R32 B1: the Core names a root's kind with writer::kind_of from what it reads of the ALife object; a unit is a squad or a
// living monster (what the transfers move), so a crow or a phantom is its map's resident.
TEST(mode_core_root_kind_reads_the_object)
{
	const std::string core = code_of(read_text(engine_src() + "/xrGame/coop/coop_writer.cpp"));
	const std::string facts = body_of(core, R"(writer::RootFacts\s+root_facts_of)");
	expect_in("root_facts_of", facts, "f.kind = writer::kind_of(writer::KindFacts{f.root == writer::kGhostId, world::is_player_character(r),");
	expect_in("root_facts_of", facts, "smart_cast<const CSE_ALifeOnlineOfflineGroup*>(r) != nullptr, smart_cast<const CSE_ALifeMonsterAbstract*>(r) != nullptr,");
	expect_in("root_facts_of", facts, "c != nullptr && c->g_Alive(), f.level != writer::kNoLevel});");
	CHECK(facts.find("RootKind::Unit") == std::string::npos); // no kind decided beside kind_of
}

// §8a A7: the new EntityUp kinds have explicit cases on the map server (C4062 is off: a missing case would be silent), and the
// data-carrying ups are overridden there.
TEST(mode_map_server_ups_have_every_kind)
{
	const std::string srv = code_of(read_text(engine_src() + "/xrGame/coop/srv/coop_srv_mode.cpp"));
	const std::string up = body_of(srv, R"(void\s+level_entity_up)");
	for (const char* k : {"Spawned", "Released", "Parent", "Died", "Joined", "Left", "Info", "ItemFacts"})
		expect_in("level_entity_up", up, std::string("case EntityUp::") + k + ":");
	expect_in("MapLevelSide", class_body(srv, "MapLevelSide"), "void level_info_up(u16 id, const char* info, bool on) override");
	expect_in("MapLevelSide", class_body(srv, "MapLevelSide"), "void level_item_facts_up(u16 id) override");
}
