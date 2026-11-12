// Anomaly Coop unit tests: the operator of a world server (docs/plans/2026-11-12-split-levels-native.md §2, stage 1).
// Pure rules of xrCoop/coop_operator.h (the token, the verdict on a Hello, the list of console lines), then real Sessions over
// 127.0.0.1 in one process: a loopback Hello with the token makes the operator, a second key does not, an OperatorCommand from
// anybody else or off the list is refused, the rate and the length are limited. Ports 38200+n.
#include "test_util.h"
#include "coop_debug_rules.h"
#include "coop_limits.h"
#include "coop_operator.h"

#include <cstring>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

using namespace coop;

static_assert(op::kMaxLine == debug::kMaxConsoleLine, "the operator's line is a console line");
static_assert(sizeof(op::Token) == kHelloTokenSize, "the token travels in HelloMsg::token");
static_assert(std::is_same<op::Key, PlayerKey>::value, "the token is bound to a player key");

namespace
{
using t::Node;

op::Token token_of(uint8_t seed)
{
	op::Token t{};
	for (size_t i = 0; i < t.size(); ++i)
		t[i] = uint8_t(seed + i * 7 + 1);
	return t;
}

void present(Node& n, const op::Token& t) { std::memcpy(n.cfg.hello_token.data(), t.data(), t.size()); }

bool join(Node& host, Node& c, uint16_t port, Session* other = nullptr)
{
	std::string err;
	if (!c.connect(port, &err))
		return false;
	const auto done = [&] { return c.welcomed || c.rejected; };
	const bool ok = other ? t::pump_until({&host.s, &c.s, other}, 5000, done) : t::pump_until({&host.s, &c.s}, 5000, done);
	return ok && c.welcomed;
}

const PeerInfo* host_side(const Node& host, PeerId id)
{
	return host.s.peer(id);
}

struct Commands
{
	std::vector<std::pair<PeerId, std::string>> got;
	void attach(Node& host)
	{
		host.s.on_operator_command = [this](PeerId from, const std::string& line) { got.emplace_back(from, line); };
	}
};
} // namespace

// ============================================================================ the token

TEST(operator_token_parse)
{
	op::Token t{};
	CHECK(op::parse_token("00112233445566778899aabbccddeeff", t));
	CHECK(t[0] == 0x00 && t[1] == 0x11 && t[15] == 0xff);
	CHECK(op::parse_token("00112233445566778899AABBCCDDEEFF -dbg", t)); // either case, ends at a blank
	CHECK(t[10] == 0xaa);
	op::Token keep = token_of(3);
	op::Token u = keep;
	CHECK(!op::parse_token("00112233445566778899aabbccddeef", u)); // 31 digits
	CHECK(!op::parse_token("00112233445566778899aabbccddeeff0", u)); // 33
	CHECK(!op::parse_token("0011223344556677889gaabbccddeeff", u)); // not hex
	CHECK(!op::parse_token("00000000000000000000000000000000", u)); // zeros are no token
	CHECK(!op::parse_token("", u));
	CHECK(!op::parse_token(nullptr, u));
	CHECK(u == keep); // a refusal leaves it alone
}

TEST(operator_token_on_the_command_line)
{
	op::Token t{};
	CHECK(op::find_token("-fsltx x.ltx -coop_dedicated 27960 -coop_operator 00112233445566778899aabbccddeeff -dbg", t));
	CHECK(t[15] == 0xff);
	CHECK(op::find_token("-coop_operator   0f112233445566778899aabbccddeeff", t)); // first on the line, more blanks
	CHECK(t[0] == 0x0f);
	CHECK(!op::find_token("-coop_dedicated 27960", t));
	CHECK(!op::find_token("-coop_operatorx 00112233445566778899aabbccddeeff", t)); // a longer key
	CHECK(!op::find_token("x-coop_operator 00112233445566778899aabbccddeeff", t)); // not a word of its own
	CHECK(!op::find_token("-coop_operator", t)); // no token
	CHECK(!op::find_token("-coop_operator 1234", t)); // a short one
	CHECK(!op::find_token(nullptr, t));
}

TEST(operator_token_compare)
{
	const op::Token a = token_of(1), b = token_of(2);
	CHECK(op::token_equal(a.data(), a.data()));
	CHECK(!op::token_equal(a.data(), b.data()));
	op::Token last = a;
	last[15] ^= 1;
	CHECK(!op::token_equal(a.data(), last.data()));
	CHECK(op::token_none(op::Token{}));
	CHECK(!op::token_none(a));
}

// ============================================================================ the verdict on a Hello

TEST(operator_verdict_rules)
{
	const PlayerKey creator = generate_player_key(), other = generate_player_key();
	// not from this PC: the token is not looked at, matched or not, bound or not
	CHECK(op::operator_verdict(false, true, nullptr, creator) == op::Verdict::NotLoopback);
	CHECK(op::operator_verdict(false, false, nullptr, creator) == op::Verdict::NotLoopback);
	CHECK(op::operator_verdict(false, true, &creator, creator) == op::Verdict::NotLoopback);
	// from this PC
	CHECK(op::operator_verdict(true, false, nullptr, creator) == op::Verdict::NoMatch);
	CHECK(op::operator_verdict(true, false, &creator, creator) == op::Verdict::NoMatch); // his key, no token: nothing
	CHECK(op::operator_verdict(true, true, nullptr, creator) == op::Verdict::Operator); // first use: binds
	CHECK(op::operator_verdict(true, true, &creator, creator) == op::Verdict::Operator); // he comes back after a crash
	CHECK(op::operator_verdict(true, true, &creator, other) == op::Verdict::OtherKey); // another key with the same token
	CHECK_EQ(std::string(op::verdict_name(op::Verdict::OtherKey)), std::string("other_key"));
}

// ============================================================================ the console lines

TEST(operator_allowed_lines)
{
	for (const char* yes : {"coop_kick 3", "coop_kick Alice", "coop_time", "coop_time 12 30", "coop_restore", "coop_restore 2",
	         "coop_autosave_now", "coop_players", "coop_status", "coop_debug on", "coop_debug off", "coop_dbg", "coop_dbg god 1",
	         "coop_dbg tp 2", "/go", "say hello all", "say привет", "coop_game_set c|coop_split_levels 1",
	         "coop_game_set mcm/foo/bar some value"})
		CHECK_EQ(std::string(yes) + (op::allowed(yes) ? " allowed" : " refused"), std::string(yes) + " allowed");
	for (const char* no : {"", "quit", "exit", "stop", "coop_world new", "coop_host 27960", "run_string os.exit()",
	         "cfg_save", "cfg_load x", "load mysave", "save ../../x", "coop_kick", "coop_debug", "coop_debug 1", "coop_debug on now",
	         "coop_autosave_now x", "/go now", "say", "coop_game_set", "coop_game_set key", "coop_game_set k$y 1",
	         " coop_status", "coop_status ", "coop_kick  3", "coop_kick 3\nquit", "coop_kick 3; quit", "coop_time\t1",
	         "coop_kicks 3", "COOP_KICK 3", "/goo", "sayhello"})
		CHECK_EQ(std::string(no) + (op::allowed(no) ? " allowed" : " refused"), std::string(no) + " refused");
	std::string del = "coop_kick 3";
	del += char(0x7F);
	CHECK(!op::allowed(del));
	// the length: up to kMaxLine
	std::string longest = "say " + std::string(op::kMaxLine - 4, 'a');
	CHECK(op::allowed(longest));
	CHECK(!op::allowed(longest + "a"));
}

TEST(operator_command_verdict)
{
	CHECK(op::command_verdict(true, "coop_status") == op::Command::Run);
	CHECK(op::command_verdict(false, "coop_status") == op::Command::NotOperator); // whatever the line
	CHECK(op::command_verdict(true, "quit") == op::Command::NotAllowed);
	CHECK(op::command_verdict(true, "say " + std::string(op::kMaxLine, 'a')) == op::Command::TooLong);
	CHECK(op::command_verdict(false, std::string(op::kMaxLine + 1, 'a')) == op::Command::NotOperator);
}

TEST(operator_command_rate_row)
{
	const limits::RateRule* r = limits::client_rule(Msg::OperatorCommand);
	REQUIRE(r != nullptr);
	CHECK_EQ(r->burst, uint32_t(4));
	CHECK_EQ(r->refill_ms, uint32_t(1000));
}

// ============================================================================ the session

TEST(operator_loopback_token_makes_the_operator)
{
	const op::Token tok = token_of(5);
	Node host("server", 38201), creator("Creator", 38201), friend_("Friend", 38201);
	host.cfg.host_plays = false;
	host.cfg.operator_token = tok;
	present(creator, tok);
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, creator, 38201));
	REQUIRE(join(host, friend_, 38201, &creator.s));
	REQUIRE(t::pump_until({&host.s, &creator.s, &friend_.s}, 5000,
	    [&] { return creator.s.peers().size() == 2 && friend_.s.peers().size() == 2 && creator.s.self_host_rights(); }));

	const PeerInfo* c = host_side(host, creator.welcome.slot);
	const PeerInfo* f = host_side(host, friend_.welcome.slot);
	REQUIRE(c && f);
	CHECK(c->host_rights);
	CHECK(!f->host_rights);
	CHECK(host.logged("operator: peer " + std::to_string(creator.welcome.slot)));
	// the creator knows he holds the rights; the friend sees the bit on the creator's row and none of his own
	CHECK(creator.s.self_host_rights());
	CHECK(!friend_.s.self_host_rights());
	const PeerInfo* seen = friend_.s.peer(creator.welcome.slot);
	REQUIRE(seen != nullptr);
	CHECK(seen->host_rights);
	// the host's seat does not play: the clients learn it from the Welcome
	CHECK(!(creator.welcome.flags & WelcomeMsg::HostSeatPlays));
	const PeerInfo* zero = friend_.s.peer(kHostPeer);
	REQUIRE(zero != nullptr);
	CHECK(!zero->plays);
	CHECK(!zero->host_rights);
	// the token itself never travels to anybody: the friend's Welcome is the creator's but for the slot
	CHECK_EQ(friend_.welcome.flags, creator.welcome.flags);
	CHECK_EQ(friend_.welcome.host_nick, creator.welcome.host_nick);
}

TEST(operator_wrong_token_is_an_ordinary_player)
{
	Node host("server", 38202), c("Guess", 38202);
	host.cfg.host_plays = false;
	host.cfg.operator_token = token_of(5);
	present(c, token_of(6));
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, c, 38202));
	t::pump_for({&host.s, &c.s}, 200);
	CHECK(!c.rejected);
	CHECK(c.s.is_active());
	CHECK(!c.s.self_host_rights());
	REQUIRE(host_side(host, c.welcome.slot) != nullptr);
	CHECK(!host_side(host, c.welcome.slot)->host_rights);
	CHECK(!host.logged("operator: peer"));
}

TEST(operator_no_token_on_the_server_makes_nobody_operator)
{
	// A server started without -coop_operator: a player's zeros, or any token, give nothing.
	Node host("server", 38203), zeros("Zeros", 38203), any("Any", 38203);
	host.cfg.host_plays = false;
	present(any, token_of(9));
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, zeros, 38203));
	REQUIRE(join(host, any, 38203, &zeros.s));
	t::pump_for({&host.s, &zeros.s, &any.s}, 200);
	for (const PeerInfo& p : host.s.peers())
		CHECK(!p.host_rights);
	CHECK(!zeros.s.self_host_rights() && !any.s.self_host_rights());
}

TEST(operator_token_binds_to_the_first_key)
{
	const op::Token tok = token_of(7);
	Node host("server", 38204), creator("Creator", 38204), thief("Thief", 38204);
	host.cfg.host_plays = false;
	host.cfg.operator_token = tok;
	present(creator, tok);
	present(thief, tok); // the same token, another player key
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, creator, 38204));
	REQUIRE(join(host, thief, 38204, &creator.s));
	REQUIRE(t::pump_until({&host.s, &creator.s, &thief.s}, 5000, [&] { return thief.s.peers().size() == 2; }));
	CHECK(!thief.rejected); // an ordinary player, not a refusal
	CHECK(!thief.s.self_host_rights());
	REQUIRE(host_side(host, thief.welcome.slot) != nullptr);
	CHECK(!host_side(host, thief.welcome.slot)->host_rights);
	CHECK(host_side(host, creator.welcome.slot)->host_rights);
	CHECK(host.logged("another player key"));
}

TEST(operator_comes_back_with_his_key)
{
	// The creator's game crashed and he connects again: same key, same token, the rights again.
	const op::Token tok = token_of(8);
	Node host("server", 38205), creator("Creator", 38205), again("Creator", 38205);
	host.cfg.host_plays = false;
	host.cfg.operator_token = tok;
	present(creator, tok);
	present(again, tok);
	again.cfg.key = creator.cfg.key;
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, creator, 38205));
	t::pump_for({&host.s}, 4300); // his game is gone (silent longer than kReplaceSilentLinkMs)
	REQUIRE(join(host, again, 38205));
	REQUIRE(t::pump_until({&host.s, &again.s}, 5000, [&] { return again.s.self_host_rights(); }));
	REQUIRE(host_side(host, again.welcome.slot) != nullptr);
	CHECK(host_side(host, again.welcome.slot)->host_rights);
}

TEST(operator_command_reaches_the_hook)
{
	const op::Token tok = token_of(4);
	Node host("server", 38206), creator("Creator", 38206);
	host.cfg.host_plays = false;
	host.cfg.operator_token = tok;
	present(creator, tok);
	Commands cmds;
	cmds.attach(host);
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, creator, 38206));
	REQUIRE(t::pump_until({&host.s, &creator.s}, 5000, [&] { return creator.s.self_host_rights(); }));
	CHECK(creator.s.send_operator_command("coop_status"));
	CHECK(creator.s.send_operator_command("quit")); // the client sends; the server is the judge
	CHECK(creator.s.send_operator_command("/go"));
	REQUIRE(t::pump_until({&host.s, &creator.s}, 3000, [&] { return cmds.got.size() >= 2; }));
	t::pump_for({&host.s, &creator.s}, 100);
	REQUIRE(cmds.got.size() == 2);
	CHECK_EQ(cmds.got[0].first, creator.welcome.slot);
	CHECK_EQ(cmds.got[0].second, std::string("coop_status"));
	CHECK_EQ(cmds.got[1].second, std::string("/go"));
	CHECK_EQ(host.s.operator_refused(), uint64_t(1));
	CHECK(host.logged("not_allowed"));
	CHECK(creator.s.is_active()); // a refusal is no kick
}

TEST(operator_command_from_a_non_operator_is_refused)
{
	const op::Token tok = token_of(4);
	Node host("server", 38207), creator("Creator", 38207), other("Other", 38207);
	host.cfg.host_plays = false;
	host.cfg.operator_token = tok;
	present(creator, tok);
	Commands cmds;
	cmds.attach(host);
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, creator, 38207));
	REQUIRE(join(host, other, 38207, &creator.s));
	CHECK(other.s.send_operator_command("coop_kick 1"));
	t::pump_for({&host.s, &creator.s, &other.s}, 300);
	CHECK(cmds.got.empty());
	CHECK_EQ(host.s.operator_refused(), uint64_t(1));
	CHECK(host.logged("not_operator"));
	CHECK(other.s.is_active());
	CHECK(creator.s.is_active());
}

TEST(operator_command_rate_and_length)
{
	const op::Token tok = token_of(2);
	Node host("server", 38208), creator("Creator", 38208);
	host.cfg.host_plays = false;
	host.cfg.operator_token = tok;
	present(creator, tok);
	for (const limits::RateRule& rule : limits::kClientRateRules)
		host.s.limit_rate(rule.type, rule.burst, rule.refill_ms);
	Commands cmds;
	cmds.attach(host);
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, creator, 38208));
	REQUIRE(t::pump_until({&host.s, &creator.s}, 5000, [&] { return creator.s.self_host_rights(); }));

	// the length first, alone in its bucket's time: over kMaxLine is refused (and takes a token)
	CHECK(creator.s.send_operator_command("say " + std::string(op::kMaxLine, 'a')));
	t::pump_for({&host.s, &creator.s}, 200);
	CHECK(cmds.got.empty());
	CHECK_EQ(host.s.operator_refused(), uint64_t(1));
	CHECK(host.logged("too_long"));

	// the rate: 4 in a row, then one per second; three tokens are left, 7 more go at once
	for (int i = 0; i < 7; ++i)
		CHECK(creator.s.send_operator_command("coop_status"));
	t::pump_for({&host.s, &creator.s}, 300);
	CHECK_EQ(cmds.got.size(), size_t(3));
	CHECK_EQ(host.s.stats(uint16_t(Msg::OperatorCommand)).rate_dropped, uint64_t(4));
	CHECK(creator.s.is_active());
}

TEST(operator_command_needs_a_joined_client)
{
	Session s;
	CHECK(!s.send_operator_command("coop_status")); // not connected
	Node host("Boss", 38209);
	std::string err;
	REQUIRE(host.host(&err));
	CHECK(!host.s.send_operator_command("coop_status")); // a host has its own console
	CHECK(!host.s.self_host_rights());
}

// ============================================================================ security review 2026-11-12

// coop_debug_cmds.script has one command of class "operator": "lua <code>", for the server's own console only. A network
// message is not that console, and coop_debug_server lowercases the command before it looks it up.
TEST(operator_dbg_never_runs_lua)
{
	for (const char* no : {"coop_dbg lua x", "coop_dbg LUA x", "coop_dbg Lua os.exit()", "coop_dbg lua", "coop_dbg lUa 1",
	         "coop_dbg lua=1", "coop_dbg l-ua x", "coop_dbg \"lua\" x", "coop_dbg ./lua x"})
		CHECK_EQ(std::string(no) + (op::allowed(no) ? " allowed" : " refused"), std::string(no) + " refused");
	for (const char* yes : {"coop_dbg", "coop_dbg god 1", "coop_dbg tp 2", "coop_dbg time_add h=1", "coop_dbg luas", "coop_dbg GOD 1"})
		CHECK_EQ(std::string(yes) + (op::allowed(yes) ? " allowed" : " refused"), std::string(yes) + " allowed");
}

// The creator's game presents its token only to this PC. The address is text from an invite, a console line or Lua: only a
// literal 127.a.b.c is this PC, a host name that begins with "127." is not.
TEST(operator_loopback_is_a_literal_address)
{
	for (const char* yes : {"127.0.0.1", "127.1.2.3", "127.255.255.255", "127.0.0.0"})
		CHECK_EQ(std::string(yes) + (op::loopback_literal(yes) ? " loopback" : " not"), std::string(yes) + " loopback");
	for (const char* no : {"", "127", "127.0.0", "127.0.0.1.evil.example", "127.0.0.1.", "127.0.0.1 ", " 127.0.0.1", "127.0.0.256",
	         "127.0.0.1:27960", "localhost", "128.0.0.1", "0127.0.0.1", "127.0.0.01", "127.0.0.-1", "127..0.1", "127.0.0.1x",
	         "127.o.0.1", "1270.0.0.1"})
		CHECK_EQ(std::string(no) + (op::loopback_literal(no) ? " loopback" : " not"), std::string(no) + " not");
	CHECK(!op::loopback_literal(nullptr));
}

// The engine logs its command line (x_ray.cpp, Level.cpp, the map server's key), logs go into reports: the value never does.
TEST(operator_token_is_not_in_a_logged_command_line)
{
	CHECK_EQ(op::redact("-fsltx a.ltx -coop_dedicated 27960 -coop_operator 000102030405060708090a0b0c0d0e0f -coop_hidden"),
		std::string("-fsltx a.ltx -coop_dedicated 27960 -coop_operator <hidden> -coop_hidden"));
	CHECK_EQ(op::redact("-coop_operator   abc"), std::string("-coop_operator   <hidden>"));
	CHECK_EQ(op::redact("-coop_operator\tabc def"), std::string("-coop_operator\t<hidden> def"));
	CHECK_EQ(op::redact("-coop_operator"), std::string("-coop_operator"));
	CHECK_EQ(op::redact("-coop_operator "), std::string("-coop_operator "));
	CHECK_EQ(op::redact("-coop_operatorx 1"), std::string("-coop_operatorx 1"));
	CHECK_EQ(op::redact("x-coop_operator 1"), std::string("x-coop_operator 1"));
	CHECK_EQ(op::redact("x -coop_operator a -coop_operator b"), std::string("x -coop_operator <hidden> -coop_operator <hidden>"));
	CHECK_EQ(op::redact(""), std::string(""));
	CHECK_EQ(op::redact(nullptr), std::string(""));
	// a map server's one-time token is a word of 32 hex digits, anywhere in the line
	CHECK_EQ(op::redact("-fsltx fsgame_ms1.ltx -coop_mapserver 1 0 27960 e779604846636dbc9308b4dd7b6ba59b -silent_error_mode"),
		std::string("-fsltx fsgame_ms1.ltx -coop_mapserver 1 0 27960 <hidden> -silent_error_mode"));
	CHECK_EQ(op::redact("E779604846636DBC9308B4DD7B6BA59B"), std::string("<hidden>"));
	CHECK_EQ(op::redact("e779604846636dbc9308b4dd7b6ba59 e779604846636dbc9308b4dd7b6ba59bb coop_auto_6af5e253-256d_1"),
		std::string("e779604846636dbc9308b4dd7b6ba59 e779604846636dbc9308b4dd7b6ba59bb coop_auto_6af5e253-256d_1"));
}

// A world server whose places are all taken by other players would have nobody who may kick or restore: while a token is
// set and its holder is not in, the last place is his.
TEST(operator_keeps_his_place_in_a_full_session)
{
	const op::Token tok = token_of(11);
	Node host("server", 38210), a("A", 38210), b("B", 38210), creator("Creator", 38210);
	host.cfg.host_plays = false;
	host.cfg.max_players = 2; // two seats that play, the server's own is not one of them
	host.cfg.operator_token = tok;
	present(creator, tok);
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, a, 38210));
	CHECK(!join(host, b, 38210, &a.s)); // the last place waits for the token's holder
	CHECK(b.rejected);
	REQUIRE(join(host, creator, 38210, &a.s));
	REQUIRE(host_side(host, creator.welcome.slot) != nullptr);
	CHECK(host_side(host, creator.welcome.slot)->host_rights);
	// he is in: the session is full for everybody now, and nobody else is turned away earlier than that
	Node c("C", 38210);
	CHECK(!join(host, c, 38210, &a.s));
	CHECK(c.rejected);
}

TEST(operator_place_is_nobodys_without_a_token)
{
	Node host("server", 38211), a("A", 38211), b("B", 38211);
	host.cfg.host_plays = false;
	host.cfg.max_players = 2;
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, a, 38211));
	REQUIRE(join(host, b, 38211, &a.s)); // no operator to wait for: both places are for players
}
