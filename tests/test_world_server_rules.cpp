// Anomaly Coop unit tests: the world server and its parent (plan 2026-11-12 stage 2, xrCoop/coop_world_server_rules.h). The @rl lines of its
// standard output, the queue that never holds the game's main thread, the conversion of the game's text, where its data folder is and where
// its saves go. Plus what of the dedicated host's own rules this needs (coop_dedicated_rules.h: console_plan's output, wait_code).
#include "test_util.h"

#include "coop_dedicated_rules.h"
#include "coop_operator.h"
#include "coop_world_server_rules.h"

#include <string>
#include <vector>

using namespace coop;
using namespace coop::world_server;

namespace
{
Record parsed(const std::string& line)
{
	Record r;
	CHECK(parse(line, r));
	return r;
}

Record round(const Record& r)
{
	const std::string line = format(r);
	CHECK(line.compare(0, 4, "@rl ") == 0);
	CHECK(line.find('\n') == std::string::npos);
	CHECK(line.find('\r') == std::string::npos);
	return parsed(line);
}
} // namespace

// ---------------------------------------------------------------- the @rl lines

TEST(world_server_phase_lines_are_the_plans)
{
	CHECK_EQ(format(Record::of_phase(Phase::Starting)), std::string("@rl phase starting"));
	CHECK_EQ(format(Record::of_phase(Phase::World)), std::string("@rl phase world"));
	CHECK_EQ(format(Record::of_phase(Phase::Session)), std::string("@rl phase session"));
	CHECK_EQ(format(Record::of_phase(Phase::Ready)), std::string("@rl phase ready"));
	CHECK_EQ(format(Record::of_phase(Phase::Saving)), std::string("@rl phase saving"));
	CHECK_EQ(format(Record::of_phase(Phase::Down)), std::string("@rl phase down"));
	for (Phase p : {Phase::Starting, Phase::World, Phase::Session, Phase::Ready, Phase::Saving, Phase::Down})
	{
		const Record r = round(Record::of_phase(p));
		CHECK(r.event == Event::Phase);
		CHECK(r.phase == p);
	}
}

TEST(world_server_ready_players_mapserver_round_trip)
{
	CHECK_EQ(format(Record::of_ready(27960)), std::string("@rl ready port=27960"));
	CHECK_EQ(round(Record::of_ready(27960)).port, 27960);
	CHECK_EQ(format(Record::of_players(3)), std::string("@rl players n=3"));
	CHECK_EQ(round(Record::of_players(0)).players, 0u);
	CHECK_EQ(round(Record::of_players(7)).players, 7u);
	CHECK_EQ(format(Record::of_mapserver("k00_marsh", MapState::Serving)), std::string("@rl mapserver level=k00_marsh state=serving"));
	for (MapState s : {MapState::Loading, MapState::Ready, MapState::Serving, MapState::Gone})
	{
		const Record r = round(Record::of_mapserver("l01_escape", s));
		CHECK(r.event == Event::MapServer);
		CHECK_EQ(r.level, std::string("l01_escape"));
		CHECK(r.state == s);
	}
}

TEST(world_server_wait_and_error_carry_a_code_and_a_text_with_spaces)
{
	CHECK_EQ(format(Record::of_wait("loading", "the level is loading")), std::string("@rl wait loading the level is loading"));
	Record w = round(Record::of_wait("no_level", "no level yet: coop_world, or the level is being created"));
	CHECK(w.event == Event::Wait);
	CHECK_EQ(w.code, std::string("no_level"));
	CHECK_EQ(w.text, std::string("no level yet: coop_world, or the level is being created"));
	w = round(Record::of_wait("precache", ""));
	CHECK_EQ(w.code, std::string("precache"));
	CHECK_EQ(w.text, std::string());

	const Record e = round(Record::of_error("gave_up", "gave up after 900 s: the level is loading  (two blanks, \"quotes\", a=b)"));
	CHECK(e.event == Event::Error);
	CHECK_EQ(e.code, std::string("gave_up"));
	CHECK_EQ(e.text, std::string("gave up after 900 s: the level is loading  (two blanks, \"quotes\", a=b)"));
}

TEST(world_server_a_text_never_breaks_the_line)
{
	const std::string line = format(Record::of_error("no_save", "first\r\nsecond\tthird\n"));
	CHECK_EQ(line, std::string("@rl error no_save first  second third "));
	// a code is a word: whatever is not [a-z0-9_] becomes _
	CHECK_EQ(format(Record::of_error("Bad Code!", "x")), std::string("@rl error bad_code_ x"));
	CHECK_EQ(format(Record::of_error("", "x")), std::string("@rl error unknown x"));
}

TEST(world_server_values_with_spaces_and_quotes_are_quoted)
{
	CHECK_EQ(format(Record::of_mapserver("my level", MapState::Ready)), std::string("@rl mapserver level=\"my level\" state=ready"));
	CHECK_EQ(round(Record::of_mapserver("my level", MapState::Ready)).level, std::string("my level"));
	const std::string odd = "a \"b\" \\c\\ d=e";
	CHECK_EQ(round(Record::of_mapserver(odd, MapState::Loading)).level, odd);
	CHECK_EQ(round(Record::of_mapserver("", MapState::Gone)).level, std::string());
	// by hand: either order, quoted or bare
	const Record r = parsed("@rl mapserver state=gone level=\"x y\"");
	CHECK_EQ(r.level, std::string("x y"));
	CHECK(r.state == MapState::Gone);
}

TEST(world_server_unknown_keys_and_events_are_ignored)
{
	Record r = parsed("@rl ready port=27961 build=\"rl 1.2\" extra=1");
	CHECK(r.event == Event::Ready);
	CHECK_EQ(r.port, 27961);
	r = parsed("@rl players since=12 n=4");
	CHECK_EQ(r.players, 4u);
	// a newer server's event: a valid line the parent does not know, never an error
	r = parsed("@rl memory mb=4096");
	CHECK(r.event == Event::Unknown);
	CHECK_EQ(r.name, std::string("memory"));
	// a newer phase or state: known event, unknown value
	r = parsed("@rl phase migrating");
	CHECK(r.event == Event::Phase);
	CHECK(r.phase == Phase::Unknown);
	r = parsed("@rl mapserver level=a state=frozen");
	CHECK(r.state == MapState::Unknown);
}

TEST(world_server_a_line_that_is_not_rl_is_not_parsed)
{
	Record r;
	CHECK(!parse("", r));
	CHECK(!parse("[coop] dedicated: the session is up on port 27960, 12 s after the level came", r));
	CHECK(!parse("! [coop] @rl phase ready", r));
	CHECK(!parse(" @rl phase ready", r));
	CHECK(!parse("@rlphase ready", r));
	CHECK(!parse("@rl", r));
	CHECK(!parse("@rl ", r));
	CHECK(!parse("@RL phase ready", r));
	CHECK(is_rl("@rl phase ready"));
	CHECK(!is_rl("@rlx"));
	CHECK(!is_rl("[coop] x"));
}

TEST(world_server_broken_known_lines_are_not_parsed)
{
	Record r;
	CHECK(!parse("@rl ready", r));
	CHECK(!parse("@rl ready port=0", r));
	CHECK(!parse("@rl ready port=65536", r));
	CHECK(!parse("@rl ready port=27x", r));
	CHECK(!parse("@rl players", r));
	CHECK(!parse("@rl players n=-1", r));
	CHECK(!parse("@rl mapserver state=ready", r));
	CHECK(!parse("@rl mapserver level=a", r));
	CHECK(!parse("@rl mapserver level=\"open state=ready", r)); // no closing quote
	CHECK(!parse("@rl phase", r));
	CHECK(!parse("@rl wait", r));
	CHECK(!parse("@rl error", r));
}

TEST(world_server_a_line_of_a_pipe_may_end_with_cr)
{
	const Record r = parsed("@rl ready port=27960\r");
	CHECK_EQ(r.port, 27960);
	const Record e = parsed("@rl error gave_up some text\r");
	CHECK_EQ(e.text, std::string("some text"));
}

// ---------------------------------------------------------------- the game's text on the pipe

TEST(world_server_cp1251_becomes_utf8)
{
	CHECK_EQ(cp1251_to_utf8("plain [coop] text"), std::string("plain [coop] text"));
	// "Привет" in cp1251
	CHECK_EQ(cp1251_to_utf8("\xCF\xF0\xE8\xE2\xE5\xF2"), std::string("\xD0\x9F\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82"));
	CHECK_EQ(cp1251_to_utf8("\xA8\xB8"), std::string("\xD0\x81\xD1\x91")); // Ё ё
	CHECK_EQ(cp1251_to_utf8("\xB9"), std::string("\xE2\x84\x96")); // №
	CHECK_EQ(cp1251_to_utf8("\x98"), std::string("\xEF\xBF\xBD")); // not in the code page
}

TEST(world_server_output_line_is_one_line)
{
	CHECK_EQ(output_line("a\r\nb\nc"), std::string("a  b c\n"));
	CHECK_EQ(output_line(""), std::string("\n"));
	CHECK_EQ(output_line("\xC0"), std::string("\xD0\x90\n"));
}

// ---------------------------------------------------------------- the queue between the game and the pipe

TEST(world_server_queue_keeps_the_order)
{
	OutputQueue q(4, 4);
	q.push("a", false);
	q.push("@rl phase world", true);
	q.push("b", false);
	std::string s;
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("a"));
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("@rl phase world"));
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("b"));
	CHECK(!q.pop(s));
	CHECK(q.empty());
}

TEST(world_server_queue_drops_old_log_lines_never_rl_lines_and_says_so)
{
	OutputQueue q(2, 8);
	q.push("1", false);
	q.push("@rl phase world", true);
	q.push("2", false);
	q.push("3", false); // "1" goes
	q.push("4", false); // "2" goes
	q.push("@rl phase session", true);
	CHECK_EQ(q.dropped(), 2u);
	std::string s;
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("[coop] stdout: 2 line(s) of the log dropped, the parent did not read"));
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("@rl phase world"));
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("3"));
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("4"));
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("@rl phase session"));
	CHECK(!q.pop(s));
	CHECK_EQ(q.dropped(), 0u);
}

TEST(world_server_queue_bounds_rl_lines_too)
{
	OutputQueue q(2, 2);
	q.push("@rl players n=1", true);
	q.push("@rl players n=2", true);
	q.push("@rl players n=3", true); // the oldest @rl goes: the newest state is what counts
	std::string s;
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("[coop] stdout: 1 line(s) of the log dropped, the parent did not read"));
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("@rl players n=2"));
	CHECK(q.pop(s));
	CHECK_EQ(s, std::string("@rl players n=3"));
}

// ---------------------------------------------------------------- the folders

TEST(world_server_world_dir_stands_next_to_the_games)
{
	CHECK_EQ(world_dir("D:\\Games\\Anomaly\\appdata"), std::string("D:\\Games\\Anomaly\\appdata_world\\"));
	CHECK_EQ(world_dir("D:\\Games\\Anomaly\\appdata\\"), std::string("D:\\Games\\Anomaly\\appdata_world\\"));
	CHECK_EQ(world_dir("D:\\Games\\Anomaly\\appdata\\\\"), std::string("D:\\Games\\Anomaly\\appdata_world\\"));
	CHECK_EQ(world_dir("D:/Games/Anomaly/appdata/"), std::string("D:\\Games\\Anomaly\\appdata_world\\"));
	CHECK_EQ(world_dir("D:\\My Games\\S.T.A.L.K.E.R. Anomaly\\appdata"), std::string("D:\\My Games\\S.T.A.L.K.E.R. Anomaly\\appdata_world\\"));
	CHECK_EQ(world_dir("C:\\Users\\x\\profiles\\player one/gamma\\"), std::string("C:\\Users\\x\\profiles\\player one\\gamma_world\\"));
	CHECK_EQ(world_dir("appdata"), std::string("appdata_world\\"));
	CHECK_EQ(world_dir(""), std::string());
	CHECK_EQ(world_dir("\\"), std::string());
}

TEST(world_server_saves_go_to_the_creators_folder)
{
	const std::string text = "$app_data_root$         = true \t| false\t| $fs_root$\t\t | appdata\\\r\n"
	                         "$logs$                  = true \t| false\t| $app_data_root$| logs\\\r\n"
	                         "$game_saves$            = true \t| false\t| $app_data_root$| savedgames\\\t\t| *.scop;*.scoc\r\n"
	                         "$downloads$             = false\t| false\t| $app_data_root$\r\n";
	std::string out;
	CHECK(rewrite_saves(text, "D:\\My Games\\Anomaly\\appdata\\savedgames\\", out));
	const std::string want = "$app_data_root$         = true \t| false\t| $fs_root$\t\t | appdata\\\r\n"
	                         "$logs$                  = true \t| false\t| $app_data_root$| logs\\\r\n"
	                         "$game_saves$            = true \t| false\t| D:\\My Games\\Anomaly\\appdata\\| savedgames\\| *.scop;*.scoc\r\n"
	                         "$downloads$             = false\t| false\t| $app_data_root$\r\n";
	CHECK_EQ(out, want);
	// / and no trailing separator: the same line
	std::string out2;
	CHECK(rewrite_saves(text, "D:/My Games/Anomaly/appdata/savedgames", out2));
	CHECK_EQ(out2, want);
}

TEST(world_server_saves_line_without_the_rest_and_at_the_end)
{
	std::string out;
	CHECK(rewrite_saves("$game_saves$ = true | false | $app_data_root$ | savedgames\\", "E:\\p\\saves\\", out));
	CHECK_EQ(out, std::string("$game_saves$ = true | false | E:\\p\\| saves\\"));
	CHECK(rewrite_saves(";$game_saves$ = x\n  $game_saves$=true|false|$app_data_root$|savedgames\\|*.scop\n", "E:\\s", out));
	CHECK_EQ(out, std::string(";$game_saves$ = x\n  $game_saves$=true|false|E:\\| s\\|*.scop\n"));
}

TEST(world_server_saves_refuse_what_the_fsgame_cannot_hold)
{
	std::string out = "untouched";
	CHECK(!rewrite_saves("$logs$ = true | false | $app_data_root$ | logs\\\r\n", "D:\\s\\", out)); // no such line
	CHECK(!rewrite_saves("$game_saves$ = true | false | $app_data_root$ | savedgames\\", "savedgames", out)); // no folder above it
	CHECK(!rewrite_saves("$game_saves$ = true | false | $app_data_root$ | savedgames\\", "D:\\a|b\\s", out)); // | splits the fields
	CHECK(!rewrite_saves("$game_saves$ = true | false | $app_data_root$ | savedgames\\", "D:\\a=b\\s", out)); // = splits the line
	CHECK(!rewrite_saves("$game_saves$ = true | false | $app_data_root$ | savedgames\\", "", out));
	CHECK(!rewrite_saves("$game_saves$ = true | false", "D:\\a\\s", out)); // fewer than 3 fields: the engine asserts on it anyway
	CHECK_EQ(out, std::string("untouched"));
}

// ---------------------------------------------------------------- the dedicated host's own rules

TEST(world_server_output_is_written_only_hidden_and_redirected)
{
	CHECK(!dedicated::console_plan(false, true, true).write_output); // the window as it was: nothing on stdout
	CHECK(!dedicated::console_plan(false, false, false).write_output);
	CHECK(!dedicated::console_plan(true, true, false).write_output); // hidden, stdout nobody's: as today
	CHECK(dedicated::console_plan(true, true, true).write_output);
	CHECK(dedicated::console_plan(true, false, true).write_output);
	CHECK(!dedicated::console_plan(true, true).write_output); // the old two-argument call: no output
}

TEST(world_server_every_wait_has_a_code)
{
	using dedicated::Wait;
	CHECK_EQ(std::string(dedicated::wait_code(Wait::None)), std::string("none"));
	CHECK_EQ(std::string(dedicated::wait_code(Wait::NoLevel)), std::string("no_level"));
	CHECK_EQ(std::string(dedicated::wait_code(Wait::Loading)), std::string("loading"));
	CHECK_EQ(std::string(dedicated::wait_code(Wait::Precache)), std::string("precache"));
	CHECK_EQ(std::string(dedicated::wait_code(Wait::NoAlife)), std::string("no_alife"));
	CHECK_EQ(std::string(dedicated::wait_code(Wait::NoAlifeActor)), std::string("no_alife_actor"));
	CHECK_EQ(std::string(dedicated::wait_code(Wait::NoClientActor)), std::string("no_client_actor"));
	CHECK_EQ(std::string(dedicated::wait_code(Wait::ActorDead)), std::string("actor_dead"));
	CHECK_EQ(std::string(dedicated::wait_code(Wait::Refused)), std::string("refused"));
	// a wait line as the game writes it
	const Record r = round(Record::of_wait(dedicated::wait_code(Wait::Loading), dedicated::wait_text(Wait::Loading)));
	CHECK_EQ(r.code, std::string("loading"));
}

// ---------------------------------------------------------------- stage 6a: the game starts its own world server

TEST(world_server_token_hex_is_32_lower_digits)
{
	const uint8_t t[16] = {0x00, 0x01, 0xab, 0xCD, 0xef, 0x10, 0x99, 0xff, 0x7f, 0x80, 0x0a, 0xa0, 0x5c, 0x22, 0x20, 0x3d};
	CHECK_EQ(token_hex(t, 16), std::string("0001abcdef1099ff7f800aa05c22203d"));
	CHECK_EQ(token_hex(t, 16).size(), size_t(32));
}

TEST(world_server_quote_arg_follows_the_windows_rules)
{
	CHECK_EQ(quote_arg("C:\\Games\\Anomaly\\bin\\AnomalyDX11.exe"), std::string("\"C:\\Games\\Anomaly\\bin\\AnomalyDX11.exe\""));
	CHECK_EQ(quote_arg("D:\\My Games\\S.T.A.L.K.E.R. Anomaly\\bin\\x.exe"), std::string("\"D:\\My Games\\S.T.A.L.K.E.R. Anomaly\\bin\\x.exe\""));
	// a backslash before the closing quote is doubled, a quote inside is escaped with the backslashes before it doubled
	CHECK_EQ(quote_arg("D:\\dir\\"), std::string("\"D:\\dir\\\\\""));
	CHECK_EQ(quote_arg("a\"b"), std::string("\"a\\\"b\""));
	CHECK_EQ(quote_arg("a\\\"b"), std::string("\"a\\\\\\\"b\""));
	CHECK_EQ(quote_arg(""), std::string("\"\""));
}

TEST(world_server_bare_args_hold_no_blank_and_no_quote)
{
	CHECK(bare_arg_ok("fsgame_world.ltx"));
	CHECK(bare_arg_ok("..\\fsgame_world.ltx"));
	CHECK(bare_arg_ok("D:\\G\\Anomaly\\fsgame_world.ltx"));
	CHECK(!bare_arg_ok(""));
	CHECK(!bare_arg_ok("D:\\My Games\\fsgame_world.ltx"));
	CHECK(!bare_arg_ok("D:\\G\tx\\f.ltx"));
	CHECK(!bare_arg_ok("D:\\G\\\"f.ltx"));
	CHECK(!bare_arg_ok("D:\\G\\f.ltx\n"));
	CHECK(!bare_arg_ok("-coop_new"));
}

TEST(world_server_nick_is_one_word)
{
	CHECK_EQ(nick_word("My world"), std::string("My_world"));
	CHECK_EQ(nick_word("-coop_new"), std::string("_coop_new"));
	CHECK_EQ(nick_word("a\"b\tc\rd"), std::string("a_b_c_d"));
	CHECK_EQ(nick_word("\xCC\xE8\xF0"), std::string("\xCC\xE8\xF0")); // cp1251 stays as it is
	CHECK_EQ(nick_word(std::string(100, 'x')).size(), size_t(63)); // string64 with its NUL
	CHECK_EQ(nick_word(""), std::string());
}

namespace
{
LaunchArgs launch_new()
{
	LaunchArgs a;
	a.exe = "D:\\My Games\\Anomaly\\bin\\AnomalyDX11AVX.exe";
	a.fsltx = "..\\fsgame_world.ltx";
	a.port = 27960;
	a.world_load = false;
	a.token_hex = "0001abcdef1099ff7f800aa05c22203d";
	return a;
}
} // namespace

TEST(world_server_command_line_of_a_new_world)
{
	std::string line, why;
	CHECK(command_line(launch_new(), false, line, why));
	CHECK_EQ(line, std::string("\"D:\\My Games\\Anomaly\\bin\\AnomalyDX11AVX.exe\" -fsltx ..\\fsgame_world.ltx -coop_dedicated 27960 "
	                           "-coop_hidden -coop_operator 0001abcdef1099ff7f800aa05c22203d -silent_error_mode -coop_new"));
	// the staging file of stage 5, a nick and -dbg are passed on
	LaunchArgs a = launch_new();
	a.stage = "D:\\G\\appdata_world\\coop_new_world.ltx";
	a.nick = "Zone of two";
	a.dbg = true;
	CHECK(command_line(a, false, line, why));
	// the keys of the process stand before anything that comes from a value (security review 2026-11-12)
	CHECK_EQ(line, std::string("\"D:\\My Games\\Anomaly\\bin\\AnomalyDX11AVX.exe\" -fsltx ..\\fsgame_world.ltx -coop_dedicated 27960 "
	                           "-coop_hidden -coop_operator 0001abcdef1099ff7f800aa05c22203d -silent_error_mode -dbg "
	                           "-coop_new -coop_stage D:\\G\\appdata_world\\coop_new_world.ltx -coop_nick Zone_of_two"));
}

TEST(world_server_command_line_of_a_save)
{
	LaunchArgs a = launch_new();
	a.world_load = true;
	a.save = "stalker - autosave";
	std::string line, why;
	CHECK(command_line(a, false, line, why));
	// the name is never on the line as text: hex of its bytes (security review 2026-11-12)
	CHECK(line.find(" -coop_load_hex 7374616c6b6572202d206175746f73617665") != std::string::npos);
	CHECK(line.find("-coop_load \"") == std::string::npos);
	CHECK(line.find("autosave") == std::string::npos);
	CHECK(line.find("-coop_new") == std::string::npos);
	// the dedicated host reads the name back as it was (coop_dedicated_rules.h)
	dedicated::Args parsed_args;
	std::string parse_why;
	const std::string params = line.substr(line.find(" -fsltx") + 1);
	CHECK(dedicated::parse_args(params.c_str(), parsed_args, parse_why));
	CHECK(parsed_args.world == dedicated::World::Load);
	CHECK_EQ(parsed_args.save, std::string("stalker - autosave"));
	CHECK_EQ(parsed_args.port, uint16_t(27960));
	CHECK(dedicated::has_hidden_key(params.c_str()));
	// and the operator's token too (coop_operator.h)
	op::Token token{};
	CHECK(op::find_token(params.c_str(), token));
	CHECK_EQ(int(token[2]), 0xab);
	// "last" is the host's own word, not a name
	a.save = "last";
	CHECK(command_line(a, false, line, why));
	CHECK(line.find(" -coop_load last") != std::string::npos);
	CHECK(line.find("-coop_load_hex") == std::string::npos);
	const std::string last_params = line.substr(line.find(" -fsltx") + 1);
	CHECK(dedicated::parse_args(last_params.c_str(), parsed_args, parse_why));
	CHECK_EQ(parsed_args.save, std::string("last"));
	// a staging file belongs to a new world only
	a.stage = "D:\\x.ltx";
	CHECK(!command_line(a, false, line, why));
}

namespace
{
size_t count_of(const std::string& text, const char* what)
{
	size_t n = 0;
	for (size_t at = text.find(what); at != std::string::npos; at = text.find(what, at + 1))
		++n;
	return n;
}
} // namespace

// The engine never parses its command line into arguments: Core.Params is the raw text, lower-cased, and its readers search it (strstr
// "-dbg", "-load ", "-ltx ", cmd_param "-coop_connect"; "-$" anywhere runs a console command, Level_start.cpp). Quotes mean nothing to
// them. So a value is never on the line as text (security review 2026-11-12): a save's name goes as hex, the world's name as one word
// of letters, digits, '_' and '.'.
TEST(world_server_command_line_carries_no_key_of_a_value)
{
	const char* names[] = {"x -coop_operator 11111111111111111111111111111111", "x -coop_operator zz", "x -$cfg_load evil", "a -dbg",
	    "a -load b", "a-coop_connect 1.2.3.4", "-coop_new", "a -ltx evil.ltx", "w-$quit", "a -coop_stage b"};
	for (const char* name : names)
	{
		LaunchArgs a = launch_new();
		a.world_load = true;
		a.save = name;
		a.nick = name;
		std::string line, why;
		CHECK(command_line(a, false, line, why));
		const std::string params = line.substr(line.find(" -fsltx") + 1);
		for (const char* key : {"-$", "-dbg", "-load ", "-ltx ", "-coop_connect", "-coop_new", "-coop_stage", " evil", "$"})
			CHECK_EQ(std::string(name) + " leaves " + key + ": " + std::to_string(count_of(params, key)), std::string(name) + " leaves " + key + ": 0");
		CHECK_EQ(count_of(params, "-coop_operator"), size_t(1));
		op::Token token{};
		CHECK(op::find_token(params.c_str(), token));
		CHECK_EQ(int(token[2]), 0xab);
		dedicated::Args parsed;
		std::string parse_why;
		CHECK(dedicated::parse_args(params.c_str(), parsed, parse_why));
		CHECK(parsed.world == dedicated::World::Load);
		CHECK_EQ(parsed.save, std::string(name));
	}
}

TEST(world_server_paths_with_a_console_key_are_refused)
{
	std::string line = "untouched", why;
	LaunchArgs a = launch_new();
	a.fsltx = "D:\\x-$y\\fsgame_world.ltx"; // "-$" anywhere in the command line runs a console command (Level_start.cpp)
	CHECK(!command_line(a, false, line, why));
	a = launch_new();
	a.stage = "D:\\a-$b.ltx";
	CHECK(!command_line(a, false, line, why));
	CHECK_EQ(line, std::string("untouched"));
}

TEST(world_server_nick_is_one_plain_word)
{
	CHECK_EQ(nick_word("a-b$c"), std::string("a_b_c"));
	CHECK_EQ(nick_word("w-$quit"), std::string("w__quit"));
	CHECK_EQ(nick_word("v1.2_x"), std::string("v1.2_x"));
	CHECK_EQ(nick_word("a'b;c=d(e)"), std::string("a_b_c_d_e_"));
	CHECK_EQ(nick_word("\xCC\xE8\xF0-2"), std::string("\xCC\xE8\xF0_2")); // cp1251 letters stay
}

TEST(world_server_world_dir_of_a_drive_root_is_none)
{
	// "D:" + "_world\" would be a path relative to the drive's current folder (security review 2026-11-12)
	CHECK_EQ(world_dir("D:\\"), std::string());
	CHECK_EQ(world_dir("D:"), std::string());
	CHECK_EQ(world_dir("D:/"), std::string());
	CHECK_EQ(world_dir("D:\\\\"), std::string());
	CHECK_EQ(world_dir("D:\\a"), std::string("D:\\a_world\\"));
}

TEST(world_server_command_line_refuses_what_cannot_pass)
{
	std::string line = "untouched", why;
	LaunchArgs a = launch_new();
	a.fsltx = "D:\\My Games\\fsgame_world.ltx"; // the engine reads -fsltx up to the first blank (x_ray.cpp)
	CHECK(!command_line(a, false, line, why));
	CHECK(!why.empty());
	a = launch_new();
	a.port = 0;
	CHECK(!command_line(a, false, line, why));
	a = launch_new();
	a.token_hex = "0001abcd";
	CHECK(!command_line(a, false, line, why));
	a = launch_new();
	a.token_hex = "0001abcdef1099ff7f800aa05c22203g";
	CHECK(!command_line(a, false, line, why));
	a = launch_new();
	a.world_load = true;
	a.save = "";
	CHECK(!command_line(a, false, line, why));
	a.save = "a\"b";
	CHECK(!command_line(a, false, line, why));
	a.save = "..\\x";
	CHECK(!command_line(a, false, line, why));
	a = launch_new();
	a.stage = "D:\\My Games\\stage.ltx";
	CHECK(!command_line(a, false, line, why));
	CHECK_EQ(line, std::string("untouched"));
}

TEST(world_server_redacted_command_line_never_holds_the_token)
{
	std::string line, why;
	CHECK(command_line(launch_new(), true, line, why));
	CHECK(line.find("0001abcdef1099ff7f800aa05c22203d") == std::string::npos);
	CHECK(line.find("-coop_operator <hidden>") != std::string::npos);
}

TEST(world_server_environment_loses_every_steam_variable)
{
	const std::string block = std::string("=C:=C:\\Games") + '\0' + "PATH=C:\\Windows" + '\0' + "RAYLINK_STEAM_JOIN=C:\\t\\join.txt" + '\0' +
	                          "RAYLINK_STEAM_LOBBY=1234" + '\0' + "raylink_steam_lobby=5" + '\0' + "RAYLINK_STEAM_JOIN_EXTRA=x" + '\0' +
	                          "RAYLINK_STEAMWORKS=keep" + '\0' + "XRAYLINK_STEAM_JOIN=keep" + '\0' + "OTHER=RAYLINK_STEAM_JOIN=keep" + '\0' +
	                          "RAYLINK_STEAM_=x" + '\0' + "RAYLINK_HOME=keep" + '\0' + '\0';
	const std::string want = std::string("=C:=C:\\Games") + '\0' + "PATH=C:\\Windows" + '\0' + "RAYLINK_STEAMWORKS=keep" + '\0' +
	                         "XRAYLINK_STEAM_JOIN=keep" + '\0' + "OTHER=RAYLINK_STEAM_JOIN=keep" + '\0' + "RAYLINK_HOME=keep" + '\0' + '\0';
	CHECK_EQ(filter_environment(block.c_str(), "RAYLINK_STEAM_"), want);
	CHECK_EQ(filter_environment(block.c_str(), kSteamEnvPrefix), want);
	// wide, as GetEnvironmentStringsW gives it
	const std::wstring wblock = std::wstring(L"A=1") + L'\0' + L"RAYLINK_STEAM_JOIN=x" + L'\0' + L'\0';
	CHECK(filter_environment(wblock.c_str(), "RAYLINK_STEAM_") ==std::wstring(L"A=1") + L'\0' + L'\0');
	// nothing left: still a valid block of two NULs
	const std::string only = std::string("RAYLINK_STEAM_JOIN=x") + '\0' + '\0';
	CHECK_EQ(filter_environment(only.c_str(), "RAYLINK_STEAM_"), std::string(2, '\0'));
}

TEST(world_server_port_candidates_start_at_the_hosts_port)
{
	const std::vector<uint16_t> c = port_candidates(27960, 4);
	CHECK_EQ(c.size(), size_t(4));
	CHECK_EQ(c[0], uint16_t(27960));
	CHECK_EQ(c[3], uint16_t(27963));
	const std::vector<uint16_t> top = port_candidates(65534, 5); // never past 65535, never 0
	CHECK_EQ(top.size(), size_t(2));
	CHECK_EQ(top[1], uint16_t(65535));
	CHECK_EQ(port_candidates(0, 2)[0], uint16_t(27960)); // no port: the default of the dedicated host
}

TEST(world_server_lines_of_a_pipe_come_whole)
{
	LineSplitter s;
	std::vector<std::string> out;
	s.push("@rl phase sta", 13, out);
	CHECK(out.empty());
	s.push("rting\r\nline two\nthree", 21, out);
	CHECK_EQ(out.size(), size_t(2));
	CHECK_EQ(out[0], std::string("@rl phase starting"));
	CHECK_EQ(out[1], std::string("line two"));
	std::string rest;
	CHECK(s.flush(rest));
	CHECK_EQ(rest, std::string("three"));
	CHECK(!s.flush(rest));
	// a line longer than the bound is cut, not held forever
	out.clear();
	const std::string longer(LineSplitter::kMaxLine + 10, 'x');
	s.push(longer.data(), longer.size(), out);
	CHECK_EQ(out.size(), size_t(1));
	CHECK_EQ(out[0].size(), LineSplitter::kMaxLine);
	CHECK(s.flush(rest));
	CHECK_EQ(rest.size(), size_t(10));
}

TEST(world_server_utf8_comes_back_to_cp1251)
{
	CHECK_EQ(utf8_to_cp1251("plain"), std::string("plain"));
	const std::string cp = "\xCC\xE8\xF0 \xA8\xB8 \x96 \x85 \xB9";
	CHECK_EQ(utf8_to_cp1251(cp1251_to_utf8(cp)), cp);
	CHECK_EQ(utf8_to_cp1251("\xE4\xB8\xAD"), std::string("?")); // a CJK letter: no such byte
	CHECK_EQ(utf8_to_cp1251("a\xFF" "b"), std::string("a?b")); // broken UTF-8
	CHECK_EQ(utf8_to_cp1251("a\xD0"), std::string("a?")); // cut in the middle
}

TEST(world_server_watch_follows_the_start_to_ready)
{
	Watch w;
	CHECK(summary(w, false) == Summary::Starting);
	w.line("@rl phase starting");
	w.line("[coop] dedicated host, port 27960");
	w.line("@rl phase world");
	w.line("@rl wait loading the level is loading");
	CHECK(w.phase == Phase::World);
	CHECK_EQ(w.wait_code, std::string("loading"));
	CHECK_EQ(w.wait_text, std::string("the level is loading"));
	CHECK(summary(w, false) == Summary::Starting);
	w.line("@rl phase session");
	w.line("@rl ready port=27961");
	w.line("@rl phase ready");
	CHECK(w.phase == Phase::Ready);
	CHECK_EQ(w.port, uint16_t(27961));
	CHECK(w.wait_code.empty());
	CHECK(summary(w, false) == Summary::Ready);
	w.line("@rl players n=2");
	w.line("@rl mapserver level=k00_marsh state=loading");
	w.line("@rl mapserver level=l01_escape state=serving");
	CHECK_EQ(w.players, 2u);
	CHECK_EQ(w.mapservers.size(), size_t(2));
	w.line("@rl mapserver level=k00_marsh state=gone");
	CHECK_EQ(w.mapservers.size(), size_t(1));
	CHECK(w.mapservers["l01_escape"] == MapState::Serving);
	// the log keeps the lines that are not @rl, never the @rl ones
	CHECK_EQ(w.lines.size(), size_t(1));
	CHECK_EQ(w.lines.back(), std::string("[coop] dedicated host, port 27960"));
	CHECK(summary(w, true) == Summary::Stopping);
}

TEST(world_server_watch_says_an_error_and_a_crash)
{
	Watch w;
	w.line("@rl phase starting");
	w.line("@rl phase world");
	w.line("@rl error gave_up the world did not come up in 15 minutes");
	CHECK_EQ(w.error_code, std::string("gave_up"));
	CHECK_EQ(w.error_text, std::string("the world did not come up in 15 minutes"));
	CHECK(summary(w, false) == Summary::Failed);
	w.exit(3);
	CHECK(w.exited);
	CHECK(w.crashed); // no "down": whatever the code
	CHECK_EQ(w.exit_code, 3u);
	CHECK(summary(w, false) == Summary::Crashed);

	Watch c;
	c.line("@rl phase ready");
	c.exit(0); // gone without "down", even with a clean code
	CHECK(c.crashed);
	CHECK(summary(c, true) == Summary::Crashed);
}

TEST(world_server_watch_after_down)
{
	Watch w(3);
	w.line("@rl phase ready");
	w.line("@rl phase saving");
	CHECK(summary(w, false) == Summary::Stopping);
	w.line("@rl phase down");
	w.line("[coop] after down 1");
	w.line("@rl phase ready"); // never back from down
	w.line("[coop] after down 2");
	CHECK(w.phase == Phase::Down);
	CHECK(w.down);
	CHECK_EQ(w.lines.size(), size_t(2));
	w.exit(0);
	CHECK(!w.crashed);
	CHECK(summary(w, false) == Summary::Down);
	// the log is bounded, the newest stay
	w.line("a");
	w.line("b");
	CHECK_EQ(w.lines.size(), size_t(3));
	CHECK_EQ(w.lines.front(), std::string("[coop] after down 2"));
	CHECK_EQ(w.lines.back(), std::string("b"));
	const std::vector<std::string> last2 = w.last(2);
	CHECK_EQ(last2.size(), size_t(2));
	CHECK_EQ(last2[0], std::string("a"));
	CHECK_EQ(w.last(10).size(), size_t(3));
	// a broken @rl line is a log line, not lost
	w.line("@rl ready port=0");
	CHECK_EQ(w.lines.back(), std::string("@rl ready port=0"));
}

TEST(world_server_fsgame_of_the_world)
{
	const std::string text = "$app_data_root$         = true \t| false\t| $fs_root$\t\t | appdata\\\r\n"
	                         "$game_saves$            = true \t| false\t| $app_data_root$| savedgames\\\t\t| *.scop;*.scoc\r\n";
	std::string out;
	CHECK(world_fsgame(text, "D:\\My Games\\Anomaly\\appdata\\savedgames\\", out));
	CHECK_EQ(out, std::string("$app_data_root$         = true \t| false\t| $fs_root$\t\t | appdata_world\\\r\n"
	                          "$game_saves$            = true \t| false\t| D:\\My Games\\Anomaly\\appdata\\| savedgames\\| *.scop;*.scoc\r\n"));
	// an absolute app data folder with blanks; a commented line is not the one
	const std::string abs = ";$app_data_root$ = x | y | z\n$app_data_root$=false|false|D:\\My Games\\appdata \n"
	                        "$game_saves$=true|false|$app_data_root$|savedgames\\\n";
	CHECK(world_fsgame(abs, "D:\\My Games\\appdata\\savedgames", out));
	CHECK_EQ(out, std::string(";$app_data_root$ = x | y | z\n$app_data_root$=false|false|D:\\My Games\\appdata_world\\ \n"
	                          "$game_saves$=true|false|D:\\My Games\\appdata\\| savedgames\\\n"));
	std::string kept = "untouched";
	CHECK(!world_fsgame("$game_saves$=true|false|$app_data_root$|savedgames\\\n", "D:\\s\\x", kept)); // no app data line
	CHECK(!world_fsgame("$app_data_root$=false|false|appdata\\\n", "D:\\s\\x", kept)); // no saves line
	CHECK_EQ(kept, std::string("untouched"));
}
