// Anomaly Coop unit tests: the server's debug (docs/DEBUG_DESIGN.md §B, work package 1): the message DebugState (protocol 29),
// the world server's state, the gate of coop.dbg.* requests, the flags a player's machine sets on its own actor, the engine's local
// cheats in a session, the console of the world server (coop_debug, coop_dbg). xrCoop/coop_debug_rules.h.
#include "test_util.h"
#include "coop_debug_rules.h"
#include "coop_local_link.h"
#include "coop_mapserver_rules.h"
#include "coop_scope.h"
#include "coop_world_gate.h"

#include <cstring>
#include <string>
#include <vector>

using namespace coop;
using namespace coop::debug;

namespace
{
std::vector<uint8_t> bytes_of(const StateMsg& m)
{
	Writer w;
	write_state(w, m);
	return w.data();
}

bool reads(const std::vector<uint8_t>& b, StateMsg& out)
{
	Reader r(b.data(), b.size());
	return read_state(r, out);
}

// A message written by hand, field by field, to make the malformed ones.
std::vector<uint8_t> raw(uint8_t on, uint8_t source, uint32_t serial, uint64_t n, const std::vector<std::pair<uint32_t, uint8_t>>& rows)
{
	Writer w;
	w.u8(on);
	w.u8(source);
	w.u32(serial);
	w.varu(n);
	for (const auto& r : rows)
	{
		w.u32(r.first);
		w.u8(r.second);
	}
	return w.data();
}

bool parse(const char* line, ConsoleLine& out, std::string& why)
{
	out = ConsoleLine();
	why.clear();
	return parse_console_line(line, out, why);
}
} // namespace

// ============================================================================ the message

TEST(debug_state_round_trip)
{
	StateMsg m;
	m.on = true;
	m.source = Source::Console;
	m.serial = 7;
	m.rows = {{0, kFlagGod}, {3, uint8_t(kFlagGod | kFlagInvisible)}};
	const std::vector<uint8_t> b = bytes_of(m);
	// u8 on, u8 source, u32 serial, varu n, n x {u32 peer, u8 flags}
	CHECK_EQ(b.size(), size_t(1 + 1 + 4 + 1 + 2 * 5));
	StateMsg back;
	REQUIRE(reads(b, back));
	CHECK(back.on);
	CHECK(back.source == Source::Console);
	CHECK_EQ(back.serial, 7u);
	REQUIRE(back.rows.size() == 2);
	CHECK_EQ(back.rows[0].peer, 0u);
	CHECK_EQ(back.rows[1].peer, 3u);
	CHECK_EQ(back.flags_of(3), uint8_t(kFlagGod | kFlagInvisible));
	CHECK_EQ(back.flags_of(0), kFlagGod);
	CHECK_EQ(back.flags_of(5), uint8_t(0)); // no row
	CHECK_EQ(back.flags_of(kInvalidPeer), uint8_t(0));

	StateMsg off;
	off.serial = 8;
	StateMsg off_back;
	REQUIRE(reads(bytes_of(off), off_back));
	CHECK(!off_back.on);
	CHECK(off_back.source == Source::Off);
	CHECK_EQ(off_back.serial, 8u);
	CHECK(off_back.rows.empty());

	// every player slot has a row: the most a message carries
	StateMsg full;
	full.on = true;
	full.source = Source::LaunchKey;
	for (PeerId p = 0; p < kMaxPlayers; ++p)
		full.rows.push_back({p, kFlagsAll});
	StateMsg full_back;
	REQUIRE(reads(bytes_of(full), full_back));
	CHECK_EQ(full_back.rows.size(), size_t(kMaxPlayers));
	CHECK(full_back.source == Source::LaunchKey);
}

TEST(debug_state_flags_of_an_off_state_are_none)
{
	// a row that is still there in an off state (no writer makes it, read_state refuses it) means nothing
	StateMsg m;
	m.rows = {{2, kFlagGod}};
	CHECK_EQ(m.flags_of(2), uint8_t(0));
}

TEST(debug_state_refuses_malformed)
{
	StateMsg out;
	// a cut message, at every length
	const std::vector<uint8_t> good = raw(1, 2, 5, 2, {{0, 1}, {4, 6}});
	REQUIRE(reads(good, out));
	for (size_t n = 0; n < good.size(); ++n)
	{
		const std::vector<uint8_t> cut(good.begin(), good.begin() + std::ptrdiff_t(n));
		if (reads(cut, out))
			t::report_failure(__FILE__, __LINE__, "a message cut to " + std::to_string(n) + " bytes was read");
	}
	CHECK(!reads(raw(2, 2, 1, 0, {}), out)); // on is 0 or 1
	CHECK(!reads(raw(1, 3, 1, 0, {}), out)); // no such source
	CHECK(!reads(raw(1, 0, 1, 0, {}), out)); // on, but its source is "off"
	CHECK(!reads(raw(0, 2, 1, 0, {}), out)); // off, but a source
	CHECK(!reads(raw(0, 0, 1, 1, {{1, 1}}), out)); // off clears every flag: no rows
	CHECK(!reads(raw(1, 1, 1, 1, {{1, 8}}), out)); // flags & ~7
	CHECK(!reads(raw(1, 1, 1, 1, {{1, 0xFF}}), out));
	CHECK(!reads(raw(1, 1, 1, 1, {{kMaxPlayers, 1}}), out)); // no player slot
	CHECK(!reads(raw(1, 1, 1, 1, {{kInvalidPeer, 1}}), out));
	CHECK(!reads(raw(1, 1, 1, 2, {{2, 1}, {2, 2}}), out)); // one row per player
	// n > kMaxPlayers, with the rows there or not
	std::vector<std::pair<uint32_t, uint8_t>> nine;
	for (uint32_t p = 0; p < 9; ++p)
		nine.push_back(std::make_pair(p % kMaxPlayers, uint8_t(1)));
	CHECK(!reads(raw(1, 1, 1, 9, nine), out));
	CHECK(!reads(raw(1, 1, 1, uint64_t(1) << 40, {}), out));
	// what the reader says no to leaves nothing half-read behind for a caller that ignores the answer
	StateMsg keep;
	keep.on = true;
	keep.source = Source::Console;
	keep.serial = 99;
	keep.rows = {{1, 1}};
	StateMsg into = keep;
	CHECK(!reads(raw(1, 1, 3, 1, {{1, 8}}), into));
	CHECK(into.on && into.serial == 99u && into.rows.size() == 1);
}

TEST(debug_state_is_a_message_of_the_world_server_to_everybody)
{
	CHECK_EQ(uint16_t(Msg::DebugState), uint16_t(0x01A1));
	CHECK_EQ(std::string(msg_name(Msg::DebugState)), std::string("DebugState"));
	CHECK(msg_sender(Msg::DebugState) == MsgSender::HostOnly); // a client that sends it is kicked
	CHECK(scope_of(Msg::DebugState) == Scope::World);
	CHECK(mapserver::bridge_takes(Msg::DebugState)); // a broadcast of the world server reaches every map server
	CHECK(level_passes(Msg::DebugState, true, false)); // and every player, whatever level he is on
	CHECK(link_enabled(Msg::DebugState)); // the host player gets it over the internal channel, as every client
	CHECK(wgate::need_of(Msg::DebugState) == wgate::Need::Free); // kept, applied without a world
	CHECK_EQ(kProtocolVersion, 31u); // 30: atomic weapon replacement and initial spawn metadata
}

// ============================================================================ the receiver

TEST(debug_state_news_by_serial)
{
	CHECK(is_news(false, 0, 0)); // the first message, whatever its serial: an off server that never changed sends 0
	CHECK(is_news(false, 0, 5));
	CHECK(is_news(true, 4, 5));
	CHECK(!is_news(true, 5, 5)); // the same state twice (queued at the join and sent at its end)
	CHECK(!is_news(true, 6, 5)); // an older one
}

// ============================================================================ the world server's state

TEST(debug_server_state_switches)
{
	ServerState s;
	CHECK(!s.on());
	CHECK(s.source() == Source::Off);
	CHECK_EQ(s.serial(), 0u);
	CHECK(s.switch_on(Source::LaunchKey));
	CHECK(s.on());
	CHECK(s.source() == Source::LaunchKey);
	CHECK_EQ(s.serial(), 1u);
	CHECK(!s.switch_on(Source::Console)); // already on: the source of the switch stays
	CHECK(s.source() == Source::LaunchKey);
	CHECK_EQ(s.serial(), 1u);
	CHECK(!s.switch_on(Source::Off)); // "on" by nobody is no switch
	CHECK(s.switch_off());
	CHECK(!s.on());
	CHECK(s.source() == Source::Off);
	CHECK_EQ(s.serial(), 2u);
	CHECK(!s.switch_off());
	CHECK_EQ(s.serial(), 2u);
	CHECK(s.switch_on(Source::Console));
	CHECK(s.source() == Source::Console);
	CHECK_EQ(s.serial(), 3u);
	s.reset();
	CHECK(!s.on());
	CHECK_EQ(s.serial(), 0u);
}

TEST(debug_server_state_flags)
{
	ServerState s;
	CHECK(s.set_flags(1, kFlagGod) == ServerState::FlagsResult::DebugOff);
	CHECK_EQ(s.flags(1), uint8_t(0));
	REQUIRE(s.switch_on(Source::Console));
	const uint32_t at_on = s.serial();
	CHECK(s.set_flags(1, kFlagGod) == ServerState::FlagsResult::Changed);
	CHECK_EQ(s.serial(), at_on + 1);
	CHECK(s.set_flags(1, kFlagGod) == ServerState::FlagsResult::Same);
	CHECK_EQ(s.serial(), at_on + 1);
	CHECK(s.set_flags(1, 8) == ServerState::FlagsResult::BadFlags);
	CHECK(s.set_flags(kMaxPlayers, kFlagGod) == ServerState::FlagsResult::BadPeer);
	CHECK(s.set_flags(kInvalidPeer, kFlagGod) == ServerState::FlagsResult::BadPeer);
	CHECK(s.set_flags(0, uint8_t(kFlagAmmo | kFlagInvisible)) == ServerState::FlagsResult::Changed); // the host player too
	CHECK_EQ(s.flags(0), uint8_t(kFlagAmmo | kFlagInvisible));
	CHECK_EQ(s.flags(1), kFlagGod);

	// the message: on, its source, its serial, a row per player with flags, in the order of the peers
	StateMsg m = s.message();
	CHECK(m.on);
	CHECK(m.source == Source::Console);
	CHECK_EQ(m.serial, s.serial());
	REQUIRE(m.rows.size() == 2);
	CHECK_EQ(m.rows[0].peer, 0u);
	CHECK_EQ(m.rows[1].peer, 1u);

	// flags 0: no row
	CHECK(s.set_flags(0, 0) == ServerState::FlagsResult::Changed);
	CHECK_EQ(s.message().rows.size(), size_t(1));
	// a player who left
	const uint32_t before_leave = s.serial();
	CHECK(s.drop_peer(1));
	CHECK_EQ(s.serial(), before_leave + 1);
	CHECK(!s.drop_peer(1));
	CHECK(!s.drop_peer(5));
	CHECK_EQ(s.serial(), before_leave + 1);
	CHECK(s.message().rows.empty());

	// switching off clears every flag
	CHECK(s.set_flags(2, kFlagGod) == ServerState::FlagsResult::Changed);
	CHECK(s.switch_off());
	CHECK_EQ(s.flags(2), uint8_t(0));
	CHECK(s.message().rows.empty());
	CHECK(!s.message().on);
	// and on again starts with none
	CHECK(s.switch_on(Source::Console));
	CHECK_EQ(s.flags(2), uint8_t(0));

	// what the server writes, a client reads
	CHECK(s.set_flags(6, kFlagsAll) == ServerState::FlagsResult::Changed);
	StateMsg back;
	REQUIRE(reads(bytes_of(s.message()), back));
	CHECK_EQ(back.flags_of(6), kFlagsAll);
	CHECK_EQ(back.serial, s.serial());
}

// ============================================================================ the player's machine: its own actor

TEST(debug_apply_local_takes_back_only_its_own)
{
	// nothing before, god wanted: set, and it is ours
	LocalApply a = apply_local(0, kFlagGod, 0);
	CHECK_EQ(a.set, kFlagGod);
	CHECK_EQ(a.clear, uint8_t(0));
	CHECK_EQ(a.applied, kFlagGod);
	// no longer wanted: ours, so cleared
	a = apply_local(kFlagGod, 0, kFlagGod);
	CHECK_EQ(a.set, uint8_t(0));
	CHECK_EQ(a.clear, kFlagGod);
	CHECK_EQ(a.applied, uint8_t(0));
	// the player had god before the session (g_god outside it): wanted now, nothing to set and not ours; not wanted: it stays his
	a = apply_local(0, kFlagGod, kFlagGod);
	CHECK_EQ(a.set, uint8_t(0));
	CHECK_EQ(a.applied, uint8_t(0));
	a = apply_local(0, 0, kFlagGod);
	CHECK_EQ(a.clear, uint8_t(0));
	// ours, still wanted, still on: kept, nothing to do
	a = apply_local(uint8_t(kFlagGod | kFlagAmmo), uint8_t(kFlagGod | kFlagAmmo), uint8_t(kFlagGod | kFlagAmmo));
	CHECK_EQ(a.set, uint8_t(0));
	CHECK_EQ(a.clear, uint8_t(0));
	CHECK_EQ(a.applied, uint8_t(kFlagGod | kFlagAmmo));
	// one of two dropped
	a = apply_local(uint8_t(kFlagGod | kFlagAmmo), kFlagAmmo, uint8_t(kFlagGod | kFlagAmmo));
	CHECK_EQ(a.clear, kFlagGod);
	CHECK_EQ(a.applied, kFlagAmmo);
	// ours, but something switched it off meanwhile, and it is still wanted: set again
	a = apply_local(kFlagGod, kFlagGod, 0);
	CHECK_EQ(a.set, kFlagGod);
	CHECK_EQ(a.applied, kFlagGod);
	// ours, switched off meanwhile and not wanted any more: nothing to clear
	a = apply_local(kFlagGod, 0, 0);
	CHECK_EQ(a.clear, uint8_t(0));
	CHECK_EQ(a.applied, uint8_t(0));
	// invisibility is the authority's (the AI's enemy test), never a flag of the player's actor
	a = apply_local(0, kFlagInvisible, 0);
	CHECK_EQ(a.set, uint8_t(0));
	CHECK_EQ(a.applied, uint8_t(0));
	a = apply_local(kFlagsAll, 0, kFlagsAll);
	CHECK_EQ(a.clear, kLocalFlags);
}

TEST(debug_wanted_flags_of_this_machine)
{
	StateMsg m;
	m.on = true;
	m.source = Source::Console;
	m.rows = {{0, kFlagGod}, {2, kFlagAmmo}};
	CHECK_EQ(wanted_local(m, 2, true), kFlagAmmo);
	CHECK_EQ(wanted_local(m, 0, true), kFlagGod); // the host player: his client half, over the link
	CHECK_EQ(wanted_local(m, 3, true), uint8_t(0)); // no row
	// a process without a player of its own (a map server, the dedicated host): its ghost keeps what it has
	CHECK_EQ(wanted_local(m, 0, false), uint8_t(0));
	m.on = false;
	CHECK_EQ(wanted_local(m, 2, true), uint8_t(0));
}

// ============================================================================ the gate of the requests

TEST(debug_request_gate_matrix)
{
	CHECK(is_debug_request("coop.dbg.view"));
	CHECK(is_debug_request("coop.dbg.world"));
	CHECK(!is_debug_request("coop.dbgx"));
	CHECK(!is_debug_request("coop.sync.x"));
	CHECK(!is_debug_request("mymod.coop.dbg.world"));
	// off: the view passes, every other coop.dbg.* is refused, other names are not this gate's
	CHECK(!refuses_request("coop.dbg.view", false));
	for (const char* n : {"coop.dbg.world", "coop.dbg.self", "coop.dbg.spawn", "coop.dbg.target", "coop.dbg.", "coop.dbg.anything"})
		if (!refuses_request(n, false))
			t::report_failure(__FILE__, __LINE__, std::string("passes while off: ") + n);
	for (const char* n : {"coop.trade.x", "mymod.ask", "coop.dbg", "coop.dbgworld", "coop.dbg.view.x2"})
	{
		const bool refused = refuses_request(n, false);
		const bool want = std::strncmp(n, "coop.dbg.", 9) == 0; // coop.dbg.view.x2 is no view
		if (refused != want)
			t::report_failure(__FILE__, __LINE__, std::string("gate wrong for ") + n);
	}
	// on: everything passes
	for (const char* n : {"coop.dbg.view", "coop.dbg.world", "coop.dbg.self", "coop.dbg.spawn", "coop.dbg.target", "mymod.ask"})
		if (refuses_request(n, true))
			t::report_failure(__FILE__, __LINE__, std::string("refused while on: ") + n);
	CHECK_EQ(std::string(kRefusedOff), std::string("debug is off"));
}

// ============================================================================ the engine's local cheats

TEST(debug_local_cheats_by_role)
{
	const char* cheats[] = {"g_god", "g_unlimitedammo", "run_string", "run_script", "jump_to_level", "ph_gravity", "g_end_modif"};
	for (const char* c : cheats)
	{
		CHECK(is_local_cheat(c));
		// out of a session: the stock -dbg tools as always
		CHECK(local_cheat(c, false, false) == Cheat::Run);
		CHECK(local_cheat(c, false, true) == Cheat::Run);
		// a player's machine in a session (a client, a map server): refused, whatever its key
		CHECK(local_cheat(c, true, false) == Cheat::RefuseClient);
	}
	// the world server in a session: the personal flags go through the server's debug (F7, coop_dbg god), one path for everybody
	CHECK(local_cheat("g_god", true, true) == Cheat::ServerFlags);
	CHECK(local_cheat("g_unlimitedammo", true, true) == Cheat::ServerFlags);
	// the operator keeps his Lua and the rest of the key's tools
	for (const char* c : {"run_string", "run_script", "jump_to_level", "ph_gravity", "g_end_modif"})
		CHECK(local_cheat(c, true, true) == Cheat::Run);
	// not cheats: never this gate's
	for (const char* c : {"log_missing_ini", "time_factor", "g_god2", "", "coop_debug"})
	{
		CHECK(!is_local_cheat(c));
		CHECK(local_cheat(c, true, false) == Cheat::Run);
	}
}

// ============================================================================ the console of the world server

TEST(debug_console_switch_words)
{
	CHECK(parse_switch("") == Switch::Status);
	CHECK(parse_switch("   ") == Switch::Status);
	CHECK(parse_switch("on") == Switch::On);
	CHECK(parse_switch(" on ") == Switch::On);
	CHECK(parse_switch("1") == Switch::On);
	CHECK(parse_switch("off") == Switch::Off);
	CHECK(parse_switch("0") == Switch::Off);
	CHECK(parse_switch("yes") == Switch::Bad);
	CHECK(parse_switch("on off") == Switch::Bad);
}

TEST(debug_console_gates)
{
	// coop_debug on|off: the world server's console, in a session
	CHECK(switch_allowed(false, false) == Operator::NoSession);
	CHECK(switch_allowed(false, true) == Operator::NoSession);
	CHECK(switch_allowed(true, false) == Operator::NotServer); // a client, a map server
	CHECK(switch_allowed(true, true) == Operator::Ok);
	// coop_dbg: the same, and the debug must be on (as sv_cheats, owner 2026-11-07)
	CHECK(console_allowed(false, true, true, "spawn_item") == Operator::NoSession);
	CHECK(console_allowed(true, false, true, "spawn_item") == Operator::NotServer);
	CHECK(console_allowed(true, true, false, "spawn_item") == Operator::DebugOff);
	CHECK(console_allowed(true, true, false, "lua") == Operator::DebugOff);
	CHECK(console_allowed(true, true, true, "spawn_item") == Operator::Ok);
	// help changes nothing: it lists the commands while the debug is off too (coop_debug_server.script answers it the same way)
	CHECK(console_allowed(true, true, false, "help") == Operator::Ok);
	CHECK(console_allowed(true, false, false, "help") == Operator::NotServer);
	CHECK(console_allowed(false, true, false, "help") == Operator::NoSession);
}

TEST(debug_console_line_parse)
{
	ConsoleLine c;
	std::string why;
	REQUIRE(parse("spawn_item @Bob sec=wpn_ak74 at=inv", c, why));
	CHECK_EQ(c.cmd, std::string("spawn_item"));
	CHECK_EQ(c.player, std::string("Bob"));
	CHECK(!c.player_number);
	REQUIRE(c.keys.size() == 2);
	CHECK_EQ(c.keys[0].first, std::string("sec"));
	CHECK_EQ(c.keys[0].second, std::string("wpn_ak74"));
	REQUIRE(c.key("at") != nullptr);
	CHECK_EQ(*c.key("at"), std::string("inv"));
	CHECK(c.key("n") == nullptr);
	CHECK(c.words.empty());
	CHECK_EQ(c.rest, std::string("@Bob sec=wpn_ak74 at=inv"));

	// the command and the keys in any case (the console keeps the case of coop_dbg's line: a nick, a value, Lua code); a value as typed
	REQUIRE(parse("Spawn_Item @Bob SEC=Wpn_AK74", c, why));
	CHECK_EQ(c.cmd, std::string("spawn_item"));
	CHECK_EQ(c.player, std::string("Bob"));
	REQUIRE(c.key("sec") != nullptr);
	CHECK_EQ(*c.key("sec"), std::string("Wpn_AK74"));
	CHECK_EQ(c.rest, std::string("@Bob SEC=Wpn_AK74"));
	REQUIRE(parse("LUA Print(1)", c, why));
	CHECK_EQ(c.cmd, std::string("lua"));
	CHECK_EQ(c.rest, std::string("Print(1)"));

	// a peer number; the player may stand anywhere on the line
	REQUIRE(parse("spawn_item sec=medkit n=5 @2 at=near", c, why));
	CHECK_EQ(c.player, std::string("2"));
	CHECK(c.player_number);
	CHECK_EQ(c.peer, 2u);
	CHECK_EQ(c.keys.size(), size_t(3));

	// positional words, no player
	REQUIRE(parse("surge start", c, why));
	CHECK_EQ(c.cmd, std::string("surge"));
	CHECK(c.player.empty());
	REQUIRE(c.words.size() == 1);
	CHECK_EQ(c.words[0], std::string("start"));
	REQUIRE(parse("  time_to   h=6\t", c, why));
	CHECK_EQ(c.cmd, std::string("time_to"));
	CHECK_EQ(*c.key("h"), std::string("6"));
	CHECK_EQ(c.rest, std::string("h=6"));
	REQUIRE(parse("help", c, why));
	CHECK_EQ(c.cmd, std::string("help"));
	CHECK(c.rest.empty());
	REQUIRE(parse("help spawn_item", c, why));
	CHECK_EQ(c.words.size(), size_t(1));

	// another player as a value (tp_to_player @Bob p=@Alice): a value is a value
	REQUIRE(parse("tp_to_player @Bob p=@Alice", c, why));
	CHECK_EQ(c.player, std::string("Bob"));
	CHECK_EQ(*c.key("p"), std::string("@Alice"));
	// a value may hold '='
	REQUIRE(parse("x a=b=c", c, why));
	CHECK_EQ(*c.key("a"), std::string("b=c"));

	// quotes: a value or a word with blanks; a quoted '@' or '=' is no player and no key
	REQUIRE(parse("say_all msg=\"hello there\" \"@not a player\" \"k=v\" x\"y z\"", c, why));
	CHECK_EQ(*c.key("msg"), std::string("hello there"));
	CHECK(c.player.empty());
	REQUIRE(c.words.size() == 3);
	CHECK_EQ(c.words[0], std::string("@not a player"));
	CHECK_EQ(c.words[1], std::string("k=v"));
	CHECK_EQ(c.words[2], std::string("xy z"));
	REQUIRE(parse("w w=\"\"x", c, why)); // an empty quoted part next to text
	CHECK_EQ(*c.key("w"), std::string("x"));

	// the raw command: `lua <code>` keeps the rest as typed, nothing else is read from it
	REQUIRE(parse("lua printf(\"%s\", \"a b\") -- @x k=v", c, why));
	CHECK_EQ(c.cmd, std::string("lua"));
	CHECK_EQ(c.rest, std::string("printf(\"%s\", \"a b\") -- @x k=v"));
	CHECK(c.player.empty());
	CHECK(c.keys.empty());
	CHECK(c.words.empty());
	REQUIRE(parse("lua x = \"unclosed", c, why)); // its quotes are Lua's business

	// refused, each with a reason
	const char* bad[] = {
		"", // nothing
		"   ",
		"spawn-item", // a command is letters, digits and '_': the registry's ids
		"\"spawn\" x",
		"spawn @", // @ without a name
		"spawn @Bob @Alice", // two players
		"spawn sec=", // an empty value
		"spawn =x", // an empty key
		"spawn s-c=x", // a key too
		"spawn sec=a sec=b", // a key twice
		"spawn sec=a SEC=b", // in any case
		"spawn msg=\"unclosed", // a quote never closed
		"spawn \"\"", // an empty word
	};
	for (const char* l : bad)
	{
		if (parse(l, c, why))
			t::report_failure(__FILE__, __LINE__, std::string("parsed: '") + l + "'");
		else if (why.empty())
			t::report_failure(__FILE__, __LINE__, std::string("no reason for: '") + l + "'");
	}

	// lengths: a token of kMaxToken bytes passes, one more does not; a command of kMaxCommand; the line
	const std::string max_tok(kMaxToken, 'a');
	REQUIRE(parse(("x v=" + max_tok).c_str(), c, why));
	CHECK(!parse(("x v=" + max_tok + "a").c_str(), c, why));
	REQUIRE(parse(("x @" + max_tok).c_str(), c, why));
	CHECK(!parse(("x @" + max_tok + "a").c_str(), c, why));
	REQUIRE(parse(("x " + max_tok).c_str(), c, why));
	CHECK(!parse(("x " + max_tok + "a").c_str(), c, why));
	REQUIRE(parse(std::string(kMaxCommand, 'c').c_str(), c, why));
	CHECK(!parse(std::string(kMaxCommand + 1, 'c').c_str(), c, why));
	std::string keys = "x";
	for (size_t i = 0; i < kMaxKeys; ++i)
		keys += " k" + std::to_string(i) + "=1";
	REQUIRE(parse(keys.c_str(), c, why));
	CHECK(!parse((keys + " kz=1").c_str(), c, why));
	std::string words = "x";
	for (size_t i = 0; i < kMaxWords; ++i)
		words += " w";
	REQUIRE(parse(words.c_str(), c, why));
	CHECK(!parse((words + " w").c_str(), c, why));
	CHECK(parse(("lua " + std::string(kMaxConsoleLine - 5, 'x')).c_str(), c, why)); // a line of kMaxConsoleLine - 1 bytes
	CHECK(!parse(("lua " + std::string(kMaxConsoleLine, 'x')).c_str(), c, why));
	// a peer number is digits alone, three at most: a longer one is a name
	REQUIRE(parse("x @1234", c, why));
	CHECK(!c.player_number);
	REQUIRE(parse("x @12a", c, why));
	CHECK(!c.player_number);
}
