// Anomaly Coop unit tests: the world server and its parent (plan 2026-11-12 stage 2, xrCoop/coop_world_server_rules.h). The @rl lines of its
// standard output, the queue that never holds the game's main thread, the conversion of the game's text, where its data folder is and where
// its saves go. Plus what of the dedicated host's own rules this needs (coop_dedicated_rules.h: console_plan's output, wait_code).
#include "test_util.h"

#include "coop_dedicated_rules.h"
#include "coop_world_server_rules.h"

#include <string>

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
