// Ядро: без проверок режима (docs/MODES.md)
// Anomaly Coop unit tests: which release a seated player gets when his peer leaves the session of the process that seated him
// (VEH-DISC; docs/VEHICLES.md section 9; review rv_F5-VEH-7, blocker 2), mode by mode.
//
// - Server, a map server: a player who quits the world while seated is released as Disconnect, one who goes to another map as
//   LeftLevel. Both drop his virtual peer from the level's session; the map server tells them apart by its world's LevelMap at that
//   moment (xrCoop/srv/coop_srv_departure_rules.h, coop_trunk.cpp server_on_map), answers the fact through the mode (Mode::departure),
//   and the Core's rule reads it (coop_vehicle_drive_rules.h session_facts, release_reason). The fact goes when he comes back.
// - A replaced character keeps its own case, as before VEH-DISC.
// - Co-op: a client's quit is a disconnect, a rejoin of the world LeftLevel, as before.
// - The other kinds (a co-op client, the world server, a server player) and none (single player) answer Disconnected.
// - The real modes' answers and the server's and the Core's lines, read from their sources (the engine files cannot run here).
#include "test_util.h"
#include "srv/coop_mapserver_rules.h"
#include "coop_mode.h"
#include "coop_vehicle_drive_rules.h"
#include "srv/coop_srv_departure_rules.h"
#include "support/fake_mode.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <map>
#include <regex>
#include <string>
#include <vector>

using coop::Departure;
using coop::PeerId;
namespace v = coop::vehicles;
namespace dep = coop::srv::departure;
namespace wire = coop::levels::wire;

namespace
{
constexpr uint16_t kLevel = 5; // the level of the map server under test
constexpr uint16_t kOther = 6; // another level of its world
constexpr uint16_t kNone = 0xffff; // join::proxy_of_peer of a peer with no character

wire::LevelMapMsg::Player dep_row(PeerId peer, uint16_t level, uint16_t proxy)
{
	wire::LevelMapMsg::Player p;
	p.peer = peer;
	p.level = level;
	p.in_world = 1;
	p.proxy = proxy;
	return p;
}

// What coop_trunk.cpp server_on_map does with a LevelMap of its world, its departure part: the characters of the level before the
// table, the table's change, each one who left classified by that table before his virtual peer leaves, each one who came dropped
// from the book. Returns the change (left: the virtual peers that leave the level's session; came: the ones that join it).
coop::mapserver::VirtualPeers::Change dep_on_map(coop::mapserver::VirtualPeers& peers, dep::Book& book,
    const std::vector<wire::LevelMapMsg::Player>& rows)
{
	const std::map<PeerId, coop::mapserver::Visitor> before = peers.on();
	const coop::mapserver::VirtualPeers::Change c = peers.update(kLevel, rows);
	for (const PeerId peer : c.left)
	{
		const auto was = before.find(peer);
		book.left(peer, was == before.end() ? wire::kNoObject : was->second.proxy, dep::classify(kLevel, peer, rows));
	}
	for (const coop::mapserver::Visitor& came : c.came)
		book.came(came.peer);
	return c;
}

// What release_by_facts (coop_vehicles_seat.cpp) decides for one seated player whose body and car are well: the session's facts
// (`joined`: his peer is a joined peer of the session; `plays`: the character his peer plays now) and the mode's answers.
v::Release dep_release(const coop::Mode& m, PeerId peer, uint16_t character, bool joined, uint16_t plays)
{
	v::SitterFacts f;
	v::session_facts(f, m, peer, character, joined, plays);
	return v::release_reason(f);
}

const char* dep_name(v::Release r) { return r == v::Release(0) ? "stays" : v::release_name(r); }

#define DEP_EXPECT(got, want) CHECK_EQ(std::string(dep_name(got)), std::string(dep_name(want)))

// anomaly-coop/<rel> (tests\ -> ..), without '\r'
std::string dep_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

// The text with // comments blanked and every run of blanks one space.
std::string dep_code(const std::string& src)
{
	const std::string no_comments = std::regex_replace(src, std::regex(R"(//[^\n]*)"), "");
	return std::regex_replace(no_comments, std::regex(R"(\s+)"), " ");
}

// The text between the brace at `open` and its partner; "" when they do not close.
std::string dep_braced(const std::string& code, size_t open)
{
	int depth = 1;
	size_t i = open + 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? std::string() : code.substr(open + 1, i - 2 - open);
}

// The body of class `name` in collapsed code; "" when there is none.
std::string dep_class(const std::string& code, const std::string& name)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(R"(\bclass )" + name + R"(\b[^;{]*\{)")))
		return std::string();
	return dep_braced(code, size_t(m.position(0) + m.length(0) - 1));
}

// The trimmed body of the override `departure` in a class body; "<none>" when the class has none.
std::string dep_answer(const std::string& cls)
{
	std::smatch m;
	if (!std::regex_search(cls, m, std::regex(R"(\bDeparture departure ?\([^;{)]*\) ?const ?override ?\{)")))
		return "<none>";
	const std::string body = dep_braced(cls, size_t(m.position(0) + m.length(0) - 1));
	return std::regex_replace(body, std::regex(R"(^ | $)"), "");
}

// The trimmed body of the free function whose head matches `head` in collapsed code; "" when there is none.
std::string dep_function(const std::string& code, const std::string& head)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(head + R"( ?\([^;{)]*\) ?\{)")))
		return std::string();
	return std::regex_replace(dep_braced(code, size_t(m.position(0) + m.length(0) - 1)), std::regex(R"(^ | $)"), "");
}

bool dep_has(const std::string& text, const std::string& what) { return text.find(what) != std::string::npos; }
} // namespace

// ---------------------------------------------------------------------------------------------- Server: a map server

// The regression of rv_F5-VEH-7 (blocker 2): the client quits the session while seated. The world server removes his seat; the map
// server's next LevelMap lists him nowhere; his virtual peer leaves the level's session. Before VEH-DISC the Core saw only "gone, and
// the mode does not place him here" and released LeftLevel; the release is Disconnect (docs/VEHICLES.md section 9).
TEST(vehicle_departure_server_quit_is_disconnect)
{
	coop::mapserver::VirtualPeers peers;
	dep::Book book;
	dep_on_map(peers, book, {dep_row(7, kLevel, 0x2a), dep_row(8, kLevel, 0x2b)});
	const coop::mapserver::VirtualPeers::Change c = dep_on_map(peers, book, {dep_row(8, kLevel, 0x2b)}); // 7 quit the world
	REQUIRE(c.left.size() == 1 && c.left[0] == 7 && c.came.empty());
	CHECK(dep::classify(kLevel, 7, {dep_row(8, kLevel, 0x2b)}) == Departure::Disconnected);
	CHECK(book.of(7, 0x2a) == Departure::Disconnected);

	t::FakeMode m(t::mode_case("map_server"));
	m.place(8, t::Spot::Here); // 7 is nobody of its session any more: a stranger, Away
	m.departed(7, 0x2a, book.of(7, 0x2a));
	CHECK(m.where(7) == coop::Where::Away);
	DEP_EXPECT(dep_release(m, 7, 0x2a, false, kNone), v::Release::Disconnect);
	// the one who stays stays
	DEP_EXPECT(dep_release(m, 8, 0x2b, true, 0x2b), v::Release(0));
}

// The same drop of his virtual peer for a player who goes to another map of the world: the LevelMap lists him on that level.
TEST(vehicle_departure_server_move_is_left_level)
{
	coop::mapserver::VirtualPeers peers;
	dep::Book book;
	dep_on_map(peers, book, {dep_row(7, kLevel, 0x2a)});
	const coop::mapserver::VirtualPeers::Change c = dep_on_map(peers, book, {dep_row(7, kOther, 0x2a)});
	REQUIRE(c.left.size() == 1 && c.left[0] == 7 && c.came.empty());
	CHECK(book.of(7, 0x2a) == Departure::LeftLevel);
	// a row of his on no level (the world has him between levels) is still not a quit
	CHECK(dep::classify(kLevel, 7, {dep_row(7, wire::kNoLevel, 0x2a)}) == Departure::LeftLevel);

	t::FakeMode m(t::mode_case("map_server"));
	m.departed(7, 0x2a, book.of(7, 0x2a));
	DEP_EXPECT(dep_release(m, 7, 0x2a, false, kNone), v::Release::LeftLevel);
}

// A replaced character keeps its own case, as it was before VEH-DISC: his player stays on this level with another character (the
// LevelMap names him here with it: his virtual peer leaves and joins again in one table), or with none yet (the world sends him the
// world again: his virtual peer leaves until he has one). LeftLevel while the mode does not place him on this map, else Disconnect.
TEST(vehicle_departure_server_replacement_keeps_its_case)
{
	coop::mapserver::VirtualPeers peers;
	dep::Book book;
	dep_on_map(peers, book, {dep_row(7, kLevel, 0x2a)});
	CHECK(dep::classify(kLevel, 7, {dep_row(7, kLevel, 0x2b)}) == Departure::Replaced);
	coop::mapserver::VirtualPeers::Change c = dep_on_map(peers, book, {dep_row(7, kLevel, 0x2b)});
	REQUIRE(c.left.size() == 1 && c.came.size() == 1 && c.came[0].peer == 7);
	CHECK(book.size() == 0); // he is a player of the level again: nothing is kept of him

	t::FakeMode m(t::mode_case("map_server"));
	m.place(7, t::Spot::Here);
	DEP_EXPECT(dep_release(m, 7, 0x2a, true, 0x2b), v::Release::Disconnect); // his peer plays 0x2b here now
	DEP_EXPECT(dep_release(m, 7, 0x2a, true, kNone), v::Release::Disconnect); // ... before the map server places it
	m.place(7, t::Spot::Joining);
	DEP_EXPECT(dep_release(m, 7, 0x2a, true, 0x2b), v::Release::LeftLevel); // ... while it loads

	// his row on this level with no character: his virtual peer leaves, nothing comes
	coop::mapserver::VirtualPeers peers2;
	dep::Book book2;
	dep_on_map(peers2, book2, {dep_row(7, kLevel, 0x2a)});
	c = dep_on_map(peers2, book2, {dep_row(7, kLevel, wire::kNoObject)});
	REQUIRE(c.left.size() == 1 && c.came.empty());
	CHECK(book2.of(7, 0x2a) == Departure::Replaced);
	t::FakeMode m2(t::mode_case("map_server"));
	m2.departed(7, 0x2a, book2.of(7, 0x2a));
	DEP_EXPECT(dep_release(m2, 7, 0x2a, false, kNone), v::Release::LeftLevel); // as before: a gone peer is Away
}

// The fact is for that player with that character, and it goes when he comes back to the level.
TEST(vehicle_departure_server_fact_clears_on_rejoin)
{
	coop::mapserver::VirtualPeers peers;
	dep::Book book;
	dep_on_map(peers, book, {dep_row(7, kLevel, 0x2a)});
	dep_on_map(peers, book, {dep_row(7, kOther, 0x2a)}); // to another level
	CHECK(book.of(7, 0x2a) == Departure::LeftLevel);
	CHECK(book.of(7, 0x2b) == Departure::Disconnected); // another character of his: nothing was said of it
	CHECK(book.of(9, 0x2a) == Departure::Disconnected); // nobody said anything of 9
	const coop::mapserver::VirtualPeers::Change back = dep_on_map(peers, book, {dep_row(7, kLevel, 0x2a)}); // he comes back
	REQUIRE(back.came.size() == 1 && back.left.empty());
	CHECK(book.size() == 0);
	CHECK(book.of(7, 0x2a) == Departure::Disconnected);
	dep_on_map(peers, book, {}); // and quits
	CHECK(book.of(7, 0x2a) == Departure::Disconnected);
	CHECK(book.size() == 1);

	// one fact per player, the last one; the others' facts stay; never more than kKept
	dep::Book b;
	b.left(7, 0x2a, Departure::LeftLevel);
	b.left(8, 0x2b, Departure::Disconnected);
	b.left(7, 0x2a, Departure::Replaced);
	CHECK(b.size() == 2);
	CHECK(b.of(7, 0x2a) == Departure::Replaced && b.of(8, 0x2b) == Departure::Disconnected);
	b.came(8);
	CHECK(b.size() == 1 && b.of(7, 0x2a) == Departure::Replaced);
	for (PeerId p = 100; p < 100 + 3 * dep::Book::kKept; ++p)
		b.left(p, uint16_t(p), Departure::LeftLevel);
	CHECK(b.size() == dep::Book::kKept);
	CHECK(b.of(PeerId(100 + 3 * dep::Book::kKept - 1), uint16_t(100 + 3 * dep::Book::kKept - 1)) == Departure::LeftLevel);
	CHECK(b.of(7, 0x2a) == Departure::Disconnected); // the oldest went
	CHECK_EQ(std::string(dep::text(Departure::Disconnected)), std::string("he left the world"));
	CHECK_EQ(std::string(dep::text(Departure::LeftLevel)), std::string("he went to another level"));

	// the fake map server keeps its book the same way
	t::FakeMode m(t::mode_case("map_server"));
	m.departed(7, 0x2a, Departure::LeftLevel);
	CHECK(m.departure(7, 0x2a) == Departure::LeftLevel);
	CHECK(m.departure(7, 0x2b) == Departure::Disconnected);
	m.came(7);
	CHECK(m.departure(7, 0x2a) == Departure::Disconnected);
}

// ---------------------------------------------------------------------------------------------- Co-op: unchanged

// The co-op host's session is the world's and everybody stands on his one map: a client who quits while seated is Disconnect (his
// peer is no stranger to where(): Here); a rejoin of the world (coop_join.cpp host_rejoin_peer: no character, joining) LeftLevel;
// his group's move releases before it starts (release_all_seats(LeftLevel), not this rule).
TEST(vehicle_departure_coop_host_unchanged)
{
	t::FakeMode m(t::mode_case("coop_host"));
	m.place(3, t::Spot::Here);
	m.character(0x103, 3);
	m.departed(3, 0x103, Departure::LeftLevel); // the co-op keeps no fact: nothing changes its answer
	CHECK(m.departure(3, 0x103) == Departure::Disconnected);
	DEP_EXPECT(dep_release(m, 3, 0x103, true, 0x103), v::Release(0)); // all well
	DEP_EXPECT(dep_release(m, 9, 0x103, false, kNone), v::Release::Disconnect); // he quit: a stranger, Here
	m.place(3, t::Spot::Joining);
	DEP_EXPECT(dep_release(m, 3, 0x103, true, kNone), v::Release::LeftLevel); // he loads the world again for a character
	DEP_EXPECT(dep_release(m, 3, 0x103, true, 0x103), v::Release::LeftLevel); // in the session, not on the map yet
	m.place(3, t::Spot::Here);
	DEP_EXPECT(dep_release(m, 3, 0x103, true, 0x104), v::Release::Disconnect); // he plays another character on the map
	// the rule as it was: gone from the session (or another character) -> Disconnect where the mode places him here, else LeftLevel
	for (const bool here : {true, false})
	{
		v::SitterFacts f;
		f.in_session = true;
		f.same_character = false;
		f.on_map = here;
		DEP_EXPECT(v::release_reason(f), here ? v::Release::Disconnect : v::Release::LeftLevel);
	}
}

// A co-op client seats nobody (its decider is the host); it answers Disconnected.
TEST(vehicle_departure_coop_client_answers_disconnected)
{
	t::FakeMode m(t::mode_case("coop_client"));
	m.departed(3, 0x103, Departure::LeftLevel);
	CHECK(m.departure(3, 0x103) == Departure::Disconnected);
	DEP_EXPECT(dep_release(m, 3, 0x103, false, kNone), v::Release::Disconnect);
}

// ---------------------------------------------------------------------------------------------- Server: the other kinds

// The world server leads no map (its vehicles decide nothing); a peer who leaves its session left the world, a move to another map
// keeps him its peer (LevelMove).
TEST(vehicle_departure_world_server_answers_disconnected)
{
	t::FakeMode m(t::mode_case("world_server"));
	CHECK_EQ(std::string(m.name()), std::string("world_server"));
	m.place(3, t::Spot::Elsewhere);
	m.departed(3, 0x103, Departure::LeftLevel);
	CHECK(m.departure(3, 0x103) == Departure::Disconnected);
	CHECK(!m.leads_level()); // the Core's decider of seats never runs there
	// only a map server keeps the facts of its world's table
	for (const t::ModeCase& c : t::mode_cases())
		CHECK_EQ(c.departure_facts, std::string(c.name) == "map_server");
}

// A server player seats nobody (the map server of his level decides); it answers Disconnected.
TEST(vehicle_departure_server_player_answers_disconnected)
{
	t::FakeMode m(t::mode_case("server_client"));
	CHECK_EQ(std::string(m.name()), std::string("server_client"));
	m.departed(3, 0x103, Departure::LeftLevel);
	CHECK(m.departure(3, 0x103) == Departure::Disconnected);
	DEP_EXPECT(dep_release(m, 3, 0x103, false, kNone), v::Release::Disconnect);
}

// ---------------------------------------------------------------------------------------------- single player: unchanged

// Outside a session nobody sits (the decider runs in a session only); none answers Disconnected, the real NoneMode as the fake.
TEST(vehicle_departure_none_answers_disconnected)
{
	const coop::NoneMode none;
	CHECK(none.departure(0, 0) == Departure::Disconnected);
	CHECK(none.departure(7, 0x2a) == Departure::Disconnected);
	t::FakeMode m(t::mode_case("none"));
	m.departed(7, 0x2a, Departure::LeftLevel);
	CHECK(m.departure(7, 0x2a) == Departure::Disconnected);
	DEP_EXPECT(dep_release(none, 7, 0x2a, false, kNone), v::Release::Disconnect);
}

// ---------------------------------------------------------------------------------------------- the real answers and lines

// Each mode writes its answer (docs/contracts/coop_mode_api.md, VEH-DISC row): the map server's is its book, every other one
// Disconnected; none keeps Mode's; the Core's header names no layer.
TEST(vehicle_departure_real_answers)
{
	const std::string header = dep_code(dep_file("engine/src/xrCoop/coop_mode.h"));
	REQUIRE(!header.empty());
	CHECK(dep_has(header, "virtual Departure departure(PeerId, uint16_t) const { return Departure::Disconnected; }"));
	CHECK(dep_has(header, "enum class Departure : uint8_t { Disconnected, LeftLevel, Replaced, };"));
	CHECK_EQ(dep_answer(dep_class(header, "NoneMode")), std::string("<none>"));

	const std::string coop = dep_code(dep_file("engine/src/xrGame/coop/hostplay/coop_hostplay_mode.cpp"));
	const std::string srv = dep_code(dep_file("engine/src/xrGame/coop/srv/coop_srv_mode.cpp"));
	REQUIRE(!coop.empty() && !srv.empty());
	const std::map<std::string, std::pair<const std::string*, std::string>> want = {
		{"CoopHostMode", {&coop, "return Departure::Disconnected;"}},
		{"CoopClientMode", {&coop, "return Departure::Disconnected;"}},
		{"WorldServerMode", {&srv, "return Departure::Disconnected;"}},
		{"MapServerMode", {&srv, "return mapserver::departure_of(peer, character);"}},
		{"ServerClientMode", {&srv, "return Departure::Disconnected;"}},
	};
	for (const auto& w : want)
	{
		// both co-op modes answer it in their common base (CoopModeBase), after their own overrides
		const std::string own = dep_class(*w.second.first, w.first);
		const std::string cls = own.empty() || w.first.rfind("Coop", 0) != 0 ? own : own + dep_class(coop, "CoopModeBase");
		if (cls.empty())
		{
			t::report_failure(__FILE__, __LINE__, "no class " + w.first);
			continue;
		}
		const std::string got = dep_answer(cls);
		if (got != w.second.second)
			t::report_failure(__FILE__, __LINE__, w.first + "::departure is '" + got + "', not '" + w.second.second + "'");
	}
	// the map server's answer is declared in its layer (coop_mapserver.h is not this unit's) and defined in coop_trunk.cpp
	CHECK(dep_has(srv, "namespace mapserver { Departure departure_of(PeerId peer, u16 character); }"));
}

// The server's part: server_on_map classifies each one who leaves by the table it got, before his virtual peer leaves, and drops the
// fact of each one who comes; the answer reads that book.
TEST(vehicle_departure_server_lines)
{
	const std::string trunk = dep_code(dep_file("engine/src/xrGame/coop/srv/coop_trunk.cpp"));
	REQUIRE(!trunk.empty());
	CHECK(dep_has(trunk, "#include \"xrCoop/srv/coop_srv_departure_rules.h\""));
	const std::string on_map = dep_function(trunk, R"(void server_on_map)");
	REQUIRE(!on_map.empty());
	const size_t before = on_map.find("const std::map<PeerId, Visitor> before = trunk_peers().on();");
	const size_t update = on_map.find("trunk_peers().update(key().level, m.players);");
	const size_t why = on_map.find("const Departure why = srv::departure::classify(key().level, peer, m.players);");
	const size_t book = on_map.find("departures().left(peer, was == before.end() ? wire::kNoObject : was->second.proxy, why);");
	const size_t leave = on_map.find("level.virtual_leave(peer,");
	const size_t came = on_map.find("departures().came(v.peer);");
	const size_t join = on_map.find("level.virtual_join(v.peer,");
	CHECK(before != std::string::npos && update != std::string::npos && before < update);
	CHECK(why != std::string::npos && update < why);
	CHECK(book != std::string::npos && why < book);
	CHECK(leave != std::string::npos && book < leave);
	CHECK(came != std::string::npos && join != std::string::npos && came < join);
	CHECK_EQ(dep_function(trunk, R"(Departure departure_of)"), std::string("return departures().of(peer, character);"));
}

// The Core's part: release_by_facts gives the rule the session's facts and the mode's answers through session_facts, and asks the
// mode about the player only.
TEST(vehicle_departure_core_lines)
{
	const std::string seat = dep_code(dep_file("engine/src/xrGame/coop/coop_vehicles_seat.cpp"));
	REQUIRE(!seat.empty());
	const std::string rel = dep_function(seat, R"(void release_by_facts)");
	REQUIRE(!rel.empty());
	CHECK(dep_has(rel, "session_facts(f, mode(), s.peer, it.first, p && p->state == PeerState::Joined, join::proxy_of_peer(s.peer));"));
	CHECK(!dep_has(rel, "f.in_session ="));
	CHECK(!dep_has(rel, "f.on_map ="));
	const std::string rules = dep_code(dep_file("engine/src/xrCoop/coop_vehicle_drive_rules.h"));
	const std::string facts = dep_function(rules, R"(inline void session_facts)");
	CHECK(dep_has(facts, "f.gone = joined ? Departure::Disconnected : m.departure(peer, character);"));
	CHECK(!std::regex_search(rules, std::regex(R"(\b(?:srv|hostplay|mapserver)\s*::)")));
}
