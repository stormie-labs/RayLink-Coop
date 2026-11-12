// Anomaly Coop unit tests: the dedicated host brings its session up by itself and runs hidden (docs/plans/2026-11-12-split-levels-no-reloads.md
// stage 1, xrCoop/coop_dedicated_rules.h), and why a player was not kept in the host's soft move (stage 1b, xrCoop/coop_soft_move.h).
#include "test_util.h"

#include "coop_dedicated_rules.h"
#include "coop_soft_move.h"
#include "coop_world_server_rules.h"

#include <cstring>
#include <string>

using namespace coop;
using namespace coop::dedicated;

namespace
{
WorldFacts world_ready()
{
	WorldFacts f;
	f.level = true;
	f.ready = true;
	f.precache = false;
	f.alife = true;
	f.alife_actor = true;
	f.client_actor = true;
	f.alive = true;
	return f;
}
} // namespace

// ---------------------------------------------------------------- the console line

TEST(dedicated_start_a_bom_before_the_first_line_of_a_pipe_is_not_part_of_the_command)
{
	const Parsed p = parse_line("\xEF\xBB\xBF" "coop_status\r\n");
	CHECK(p.kind == Line::Command);
	CHECK_EQ(p.text, std::string("coop_status"));
	CHECK(parse_line("\xEF\xBB\xBF" "quit").kind == Line::Quit);
	CHECK(parse_line("\xEF\xBB\xBF").kind == Line::Empty);
	CHECK(parse_line("\xEF\xBB\xBF  \r\n").kind == Line::Empty);
	const Parsed say = parse_line("\xEF\xBB\xBF" "say hi");
	CHECK(say.kind == Line::Chat);
	CHECK_EQ(say.text, std::string("hi"));
}

TEST(dedicated_start_a_bom_inside_a_line_stays_text)
{
	const Parsed p = parse_line("say a\xEF\xBB\xBF" "b");
	CHECK(p.kind == Line::Chat);
	CHECK_EQ(p.text, std::string("a\xEF\xBB\xBF" "b"));
}

// ---------------------------------------------------------------- -coop_hidden

TEST(dedicated_start_the_hidden_key_is_a_whole_word)
{
	CHECK(has_hidden_key("-coop_dedicated 27960 -coop_new -coop_hidden"));
	CHECK(has_hidden_key("-coop_hidden -coop_dedicated"));
	CHECK(!has_hidden_key("-coop_dedicated -coop_new"));
	CHECK(!has_hidden_key("-coop_hiddenx -coop_dedicated"));
	CHECK(!has_hidden_key(nullptr));
	CHECK(!has_hidden_key(""));
}

TEST(dedicated_start_hidden_key_does_not_disturb_the_other_keys)
{
	Args a;
	std::string why;
	CHECK(parse_args("-coop_dedicated 27970 -coop_hidden -coop_load last", a, why));
	CHECK_EQ(int(a.port), 27970);
	CHECK(a.world == World::Load);
	CHECK_EQ(a.save, std::string("last"));
	CHECK(parse_args("-coop_dedicated -coop_load my save -coop_hidden", a, why));
	CHECK_EQ(a.save, std::string("my save"));
}

TEST(dedicated_start_the_window_stays_as_it_was_without_the_key)
{
	const ConsolePlan with_pipe = console_plan(false, true);
	CHECK(with_pipe.window);
	CHECK(with_pipe.read_input);
	CHECK(!with_pipe.eof_quits); // as before: the window is the operator's, the end of a pipe means nothing
	const ConsolePlan alone = console_plan(false, false);
	CHECK(alone.window);
	CHECK(!alone.read_input);
	CHECK(!alone.eof_quits);
}

TEST(dedicated_start_hidden_has_no_window_reads_its_pipe_and_its_end_is_quit)
{
	const ConsolePlan p = console_plan(true, true);
	CHECK(!p.window);
	CHECK(p.read_input);
	CHECK(p.eof_quits); // the launcher or the host's game died: save the world and go
	const ConsolePlan none = console_plan(true, false);
	CHECK(!none.window);
	CHECK(!none.read_input);
	CHECK(!none.eof_quits);
}

// ---------------------------------------------------------------- why the world is not up

TEST(dedicated_start_the_world_is_up_when_every_condition_holds)
{
	CHECK(world_wait(world_ready()) == Wait::None);
}

TEST(dedicated_start_each_missing_condition_has_its_own_reason)
{
	WorldFacts f = world_ready();
	f.level = false;
	CHECK(world_wait(f) == Wait::NoLevel);
	f = world_ready();
	f.ready = false;
	CHECK(world_wait(f) == Wait::Loading);
	f = world_ready();
	f.precache = true;
	CHECK(world_wait(f) == Wait::Precache);
	f = world_ready();
	f.alife = false;
	CHECK(world_wait(f) == Wait::NoAlife);
	f = world_ready();
	f.alife_actor = false;
	CHECK(world_wait(f) == Wait::NoAlifeActor);
	f = world_ready();
	f.client_actor = false;
	CHECK(world_wait(f) == Wait::NoClientActor); // hypothesis 2 of the plan shows by its own words
	f = world_ready();
	f.alive = false;
	CHECK(world_wait(f) == Wait::ActorDead);
	// no level says nothing of the rest
	WorldFacts none;
	CHECK(world_wait(none) == Wait::NoLevel);
}

TEST(dedicated_start_every_reason_has_words)
{
	for (int w = int(Wait::None); w <= int(Wait::Refused); ++w)
	{
		const char* text = wait_text(Wait(w));
		CHECK(text != nullptr && std::strlen(text) > 3);
	}
	CHECK(std::string(wait_text(Wait::NoClientActor)).find("g_actor") != std::string::npos);
}

// ---------------------------------------------------------------- the autostart retries

TEST(dedicated_start_tries_as_soon_as_the_world_is_up)
{
	HostAutostart a;
	const HostAutostart::Step s = a.tick(1000, Wait::None);
	CHECK(s.act == HostAutostart::Do::Try);
}

TEST(dedicated_start_waits_and_says_each_reason_once)
{
	HostAutostart a;
	HostAutostart::Step s = a.tick(0, Wait::NoLevel);
	CHECK(s.act == HostAutostart::Do::Nothing);
	CHECK(s.say);
	CHECK(s.reason == Wait::NoLevel);
	CHECK(!a.tick(10, Wait::NoLevel).say);
	s = a.tick(20, Wait::Loading);
	CHECK(s.say);
	CHECK(s.reason == Wait::Loading);
	CHECK(!a.tick(30, Wait::Loading).say);
	CHECK(!a.tick(40000, Wait::Loading).say);
	s = a.tick(40010, Wait::NoClientActor);
	CHECK(s.say);
	CHECK(s.act == HostAutostart::Do::Nothing);
	s = a.tick(40020, Wait::None);
	CHECK(s.act == HostAutostart::Do::Try);
}

TEST(dedicated_start_a_refusal_is_tried_again_later_not_every_frame)
{
	HostAutostart a;
	CHECK(a.tick(1000, Wait::None).act == HostAutostart::Do::Try);
	a.refused(1000); // a busy port, a refusal of host_can_start
	HostAutostart::Step s = a.tick(1016, Wait::None);
	CHECK(s.act == HostAutostart::Do::Nothing);
	CHECK(s.reason == Wait::Refused);
	CHECK(s.say);
	CHECK(!a.tick(3000, Wait::None).say);
	CHECK(a.tick(1000 + kHostRetryMs - 1, Wait::None).act == HostAutostart::Do::Nothing);
	CHECK(a.tick(1000 + kHostRetryMs, Wait::None).act == HostAutostart::Do::Try);
	// the next waits grow, up to a ceiling
	a.refused(10000);
	CHECK(a.tick(10000 + 2 * kHostRetryMs - 1, Wait::None).act == HostAutostart::Do::Nothing);
	CHECK(a.tick(10000 + 2 * kHostRetryMs, Wait::None).act == HostAutostart::Do::Try);
	for (int i = 0; i < 10; ++i)
		a.refused(100000);
	CHECK(a.tick(100000 + kHostRetryMaxMs - 1, Wait::None).act == HostAutostart::Do::Nothing);
	CHECK(a.tick(100000 + kHostRetryMaxMs, Wait::None).act == HostAutostart::Do::Try);
}

TEST(dedicated_start_once_up_it_does_nothing_more)
{
	HostAutostart a;
	CHECK(a.tick(0, Wait::None).act == HostAutostart::Do::Try);
	a.up();
	CHECK(a.done());
	const HostAutostart::Step s = a.tick(10, Wait::None);
	CHECK(s.act == HostAutostart::Do::Nothing);
	CHECK(!s.say);
	CHECK(a.tick(kHostGiveUpMs * 2, Wait::Loading).act == HostAutostart::Do::Nothing);
}

TEST(dedicated_start_gives_up_loudly_after_the_limit_with_the_reason)
{
	HostAutostart a;
	a.tick(5000, Wait::Loading); // the clock starts with a level
	CHECK(a.tick(5000 + kHostGiveUpMs - 1, Wait::NoClientActor).act == HostAutostart::Do::Nothing);
	const HostAutostart::Step s = a.tick(5000 + kHostGiveUpMs, Wait::NoClientActor);
	CHECK(s.act == HostAutostart::Do::GiveUp);
	CHECK(s.say);
	CHECK(s.reason == Wait::NoClientActor);
	CHECK_EQ(s.waited_ms, kHostGiveUpMs);
	CHECK(a.gave_up());
	const HostAutostart::Step after = a.tick(5000 + kHostGiveUpMs + 10, Wait::None);
	CHECK(after.act == HostAutostart::Do::Nothing);
	CHECK(!after.say);
}

TEST(dedicated_start_no_level_yet_is_the_choice_of_the_operator_and_never_gives_up)
{
	// no -coop_new / -coop_load: the window waits for coop_world as long as it takes
	HostAutostart a;
	a.tick(0, Wait::NoLevel);
	CHECK(a.tick(kHostGiveUpMs * 3, Wait::NoLevel).act == HostAutostart::Do::Nothing);
	// a level comes: its clock starts now
	CHECK(a.tick(kHostGiveUpMs * 3 + 1, Wait::Loading).act == HostAutostart::Do::Nothing);
	CHECK(a.tick(kHostGiveUpMs * 3 + 2, Wait::None).act == HostAutostart::Do::Try);
}

TEST(dedicated_start_a_port_that_stays_busy_gives_up_too)
{
	HostAutostart a;
	uint64_t now = 0;
	bool gave_up = false;
	for (int i = 0; i < 2000 && !gave_up; ++i)
	{
		const HostAutostart::Step s = a.tick(now, Wait::None);
		if (s.act == HostAutostart::Do::Try)
			a.refused(now);
		if (s.act == HostAutostart::Do::GiveUp)
		{
			gave_up = true;
			CHECK(s.reason == Wait::Refused);
		}
		now += 1000;
	}
	CHECK(gave_up);
}

// ---------------------------------------------------------------- 1b: why a player is not kept in the soft move

namespace
{
softmove::Facts kept_player()
{
	softmove::Facts f;
	f.joined = true;
	f.known = true;
	f.proxy = true;
	f.server_ready = true;
	f.server = softmove::ServerVerdict::Kept;
	return f;
}
} // namespace

TEST(soft_why_the_server_verdict_agrees_with_keeps_server)
{
	for (int soft = 0; soft < 2; ++soft)
		for (int ready = 0; ready < 2; ++ready)
			for (int same = 0; same < 2; ++same)
			{
				const uint16_t level = 7, target = same ? 7 : 8;
				const softmove::ServerVerdict v = softmove::server_verdict(soft != 0, ready != 0, level, target);
				CHECK_EQ(v == softmove::ServerVerdict::Kept, softmove::keeps_server(soft != 0, ready != 0, level, target));
			}
	CHECK(softmove::server_verdict(false, true, 7, 8) == softmove::ServerVerdict::SwitchOff);
	CHECK(softmove::server_verdict(true, true, 8, 8) == softmove::ServerVerdict::Target);
	CHECK(softmove::server_verdict(true, false, 7, 8) == softmove::ServerVerdict::NotLeading);
}

TEST(soft_why_a_kept_player_stays)
{
	CHECK(softmove::stays(kept_player()));
	CHECK(softmove::why_reloads(kept_player()) == softmove::Reload::Stays);
}

TEST(soft_why_each_reason_of_a_reload_has_its_verdict)
{
	using softmove::Reload;
	struct Case
	{
		int change;
		Reload want;
	};
	const Case cases[] = {
	    {0, Reload::NotJoined}, {1, Reload::NotInWorld}, {2, Reload::NoCharacter}, {3, Reload::Loading}, {4, Reload::Joining},
	    {5, Reload::Choosing}, {6, Reload::OnTarget}, {7, Reload::SwitchOff}, {8, Reload::NoServer}, {9, Reload::ServerNotLeading},
	    {10, Reload::OnTarget}, {11, Reload::ServerNotKept},
	};
	for (const Case& c : cases)
	{
		softmove::Facts f = kept_player();
		switch (c.change)
		{
		case 0: f.joined = false; break;
		case 1: f.known = false; f.proxy = false; break;
		case 2: f.proxy = false; break;
		case 3: f.loading = true; break;
		case 4: f.joining = true; break;
		case 5: f.choosing = true; break;
		case 6: f.on_target = true; break;
		case 7: f.server_ready = false; f.server = softmove::ServerVerdict::SwitchOff; break;
		case 8: f.server_ready = false; f.server = softmove::ServerVerdict::None; break;
		case 9: f.server_ready = false; f.server = softmove::ServerVerdict::NotLeading; break;
		case 10: f.server_ready = false; f.server = softmove::ServerVerdict::Target; break;
		case 11: f.server_ready = false; f.server = softmove::ServerVerdict::Kept; break; // facts that disagree: said plainly
		}
		CHECK(!softmove::stays(f));
		CHECK(softmove::why_reloads(f) == c.want);
	}
}

TEST(soft_why_the_first_reason_wins)
{
	softmove::Facts f = kept_player();
	f.choosing = true;
	f.server_ready = false;
	f.server = softmove::ServerVerdict::SwitchOff;
	CHECK(softmove::why_reloads(f) == softmove::Reload::Choosing);
}

TEST(soft_why_every_verdict_has_words)
{
	for (int r = int(softmove::Reload::Stays); r <= int(softmove::Reload::ServerNotKept); ++r)
	{
		const char* text = softmove::reload_text(softmove::Reload(r));
		CHECK(text != nullptr && std::strlen(text) > 3);
	}
	CHECK(std::string(softmove::reload_text(softmove::Reload::SwitchOff)).find("coop_soft_host_move") != std::string::npos);
}

// ---------------------------------------------------------------- -coop_stage (plan 2026-11-12 stage 5)

TEST(dedicated_start_the_stage_key_takes_one_bare_word)
{
	Args a;
	std::string why;
	CHECK(parse_args("-coop_dedicated 27960 -coop_hidden -coop_new -coop_stage D:/w/coop_new_world.ltx -coop_operator x", a, why));
	CHECK(a.world == World::New);
	CHECK_EQ(a.stage, std::string("D:/w/coop_new_world.ltx"));
	CHECK(parse_args("-coop_dedicated -coop_new", a, why));
	CHECK(a.stage.empty()); // without the key everything stays as it was
}

TEST(dedicated_start_the_stage_key_belongs_to_a_new_world)
{
	Args a;
	a.port = 1;
	std::string why;
	CHECK(!parse_args("-coop_dedicated -coop_load last -coop_stage x.ltx", a, why));
	CHECK(why.find("-coop_stage") != std::string::npos);
	CHECK_EQ(int(a.port), 1); // a refusal leaves Args as they were
	CHECK(!parse_args("-coop_dedicated -coop_stage x.ltx", a, why));
	CHECK(!parse_args("-coop_dedicated -coop_new -coop_stage", a, why));
	CHECK(why.find("-coop_stage") != std::string::npos);
	CHECK(!parse_args("-coop_dedicated -coop_new -coop_stage -coop_hidden", a, why)); // the next key is no file
	CHECK(!parse_args("-coop_dedicated -coop_new -coop_stage \"a b.ltx\"", a, why)); // the engine reads one bare word
	CHECK(!parse_args("-coop_dedicated -coop_new -coop_stagex a.ltx", a, why) || a.stage.empty());
}

TEST(dedicated_start_the_stage_of_the_parents_command_line_comes_back)
{
	world_server::LaunchArgs l;
	l.exe = "C:\\Games\\Anomaly\\bin\\AnomalyDX11.exe";
	l.fsltx = "C:\\Users\\me\\AppData\\fsgame_world.ltx";
	l.port = 27961;
	l.stage = "C:\\Users\\me\\AppData\\coop_world\\coop_new_world.ltx";
	l.token_hex = "0123456789abcdef0123456789ABCDEF";
	l.nick = "My World";
	std::string line, why;
	CHECK(world_server::command_line(l, false, line, why));
	const size_t params = line.find(" -fsltx");
	CHECK(params != std::string::npos);
	Args a;
	CHECK(parse_args(line.c_str() + params, a, why));
	CHECK(a.world == World::New);
	CHECK_EQ(int(a.port), 27961);
	CHECK_EQ(a.stage, l.stage);

	// the engine's Core.Params is that line lower-cased in place (xrCore.cpp xr_strlwr): the same path at the same place
	std::string lowered = line;
	for (char& c : lowered)
		if (c >= 'A' && c <= 'Z')
			c = char(c - 'A' + 'a');
	Args low;
	CHECK(parse_args(lowered.c_str(), low, why));
	CHECK_EQ(low.stage, std::string("c:\\users\\me\\appdata\\coop_world\\coop_new_world.ltx"));
	CHECK_EQ(stage_original_case(lowered.c_str(), line.c_str(), low.stage), l.stage); // its own letters back from the raw line
	// commandline.txt appends keys the raw line does not have: the lower-case path stays
	const std::string appended = std::string("-coop_dedicated -coop_new") + " -coop_stage d:\\w\\s.ltx";
	Args app;
	CHECK(parse_args(appended.c_str(), app, why));
	CHECK_EQ(stage_original_case(appended.c_str(), "-coop_dedicated -coop_new", app.stage), app.stage);
	CHECK_EQ(stage_original_case(appended.c_str(), "-coop_dedicated -coop_new -coop_stage X:\\w\\s.ltx", app.stage), app.stage);
}

// Security review 2026-11-12: the parent never writes a save's name on the command line as text (the engine searches its raw command
// line, a name could read as a key): -coop_load_hex <hex of the name's bytes>.
TEST(dedicated_start_a_save_named_in_hex)
{
	Args a;
	std::string why;
	CHECK(parse_args("-coop_dedicated 27960 -coop_load_hex 7374616c6b6572202d206175746f73617665 -coop_hidden", a, why));
	CHECK(a.world == World::Load);
	CHECK_EQ(a.save, std::string("stalker - autosave"));
	CHECK(parse_args("-coop_dedicated -coop_load_hex 6A6b", a, why)); // the engine lower-cases its command line: either case
	CHECK_EQ(a.save, std::string("jk"));
	CHECK(parse_args("-coop_dedicated -coop_load_hex 78202d636f6f705f6e6577", a, why)); // "x -coop_new": a name, not a key
	CHECK(a.world == World::Load);
	CHECK_EQ(a.save, std::string("x -coop_new"));
	for (const char* bad : {"-coop_dedicated -coop_load_hex", "-coop_dedicated -coop_load_hex -coop_hidden", "-coop_dedicated -coop_load_hex 414",
	         "-coop_dedicated -coop_load_hex 41zz", "-coop_dedicated -coop_load_hex 4100", "-coop_dedicated -coop_load_hex 410a",
	         "-coop_dedicated -coop_load_hex 41 -coop_load b", "-coop_dedicated -coop_new -coop_load_hex 41", "-coop_dedicated -coop_load_hex 2e2e",
	         "-coop_dedicated -coop_load_hex 6128", "-coop_dedicated -coop_load_hex 612f62", "-coop_dedicated -coop_load_hex 6122"})
		CHECK_EQ(std::string(bad) + (parse_args(bad, a, why) ? " taken" : " refused"), std::string(bad) + " refused");
	CHECK(parse_args((std::string("-coop_dedicated -coop_load_hex ") + std::string(400, '4')).c_str(), a, why)); // 200 bytes
	CHECK_EQ(a.save.size(), size_t(200));
	CHECK(!parse_args((std::string("-coop_dedicated -coop_load_hex ") + std::string(402, '4')).c_str(), a, why));
}

// The parent writes the staging file into the server's own data folder and names it on the command line by its file name alone: a path
// of a player's profile may hold blanks ("C:\Users\First Last\..."), which the command line cannot carry.
TEST(dedicated_start_a_stage_that_is_a_name_is_a_file_of_the_servers_folder)
{
	CHECK(stage_is_name("coop_new_world.ltx"));
	CHECK(!stage_is_name("C:\\a\\coop_new_world.ltx"));
	CHECK(!stage_is_name("a\\b.ltx"));
	CHECK(!stage_is_name("a/b.ltx"));
	CHECK(!stage_is_name("c:b.ltx"));
	CHECK(!stage_is_name(""));
	CHECK(!stage_is_name(".."));
	CHECK(!stage_is_name("."));
	Args a;
	std::string why;
	CHECK(parse_args("-coop_dedicated 27960 -coop_hidden -coop_new -coop_stage coop_new_world.ltx", a, why));
	CHECK(stage_is_name(a.stage));
}
