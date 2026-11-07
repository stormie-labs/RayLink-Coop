// Anomaly Coop unit tests: the server's debug, work package 4 (docs/DEBUG_DESIGN.md §B.9, A.2 p. 7).
//   - invisible to the AI: the authority of a player's level (the world server, a map server) leaves a player with the flag 4 out as the
//     stock ai_ignore_actor leaves out the actor (vision, hearing, hit memory) and takes him for no enemy;
//   - god: a monster's stamina blow (burer, controller) asks the server's flag of the player it lands on, not the process's GodMode().
// The pure rules are xrCoop/coop_debug_rules.h (ai_ignores, blow_spares). The wiring is read from the engine's sources: every stock
// aiIgnoreActor test has the per-player test beside it, the enemy choice and the two monsters ask the per-player rules.
#include "test_util.h"
#include "coop_debug_rules.h"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

using namespace coop;
using namespace coop::debug;

namespace
{
// engine/src/xrGame, found next to this source file (tests\ -> ..\engine\src\xrGame)
std::string xrgame_dir()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src/xrGame";
	here.resize(slash);
	return here + "/../engine/src/xrGame";
}

// The source with // and /* */ comments blanked; string and character literals kept.
std::string strip_comments(const std::string& src)
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
				out[i] = ' ';
			}
			else if (c == '/' && n == '*')
			{
				st = St::Block;
				out[i] = ' ';
				out[++i] = ' ';
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
				out[i] = ' ';
				out[++i] = ' ';
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

// A source of engine/src/xrGame without comments; empty if it cannot be read.
std::string code_of(const std::string& rel)
{
	std::ifstream in(xrgame_dir() + "/" + rel, std::ios::binary);
	if (!in)
		return std::string();
	std::stringstream ss;
	ss << in.rdbuf();
	return strip_comments(ss.str());
}

size_t count_of(const std::string& text, const std::string& what)
{
	size_t n = 0;
	for (size_t at = text.find(what); at != std::string::npos; at = text.find(what, at + what.size()))
		++n;
	return n;
}

// The body of the first function whose definition starts with `head` ("bool player_out_for("): from its '{' to the matching '}'.
std::string body_of(const std::string& code, const std::string& head)
{
	const size_t at = code.find(head);
	if (at == std::string::npos)
		return std::string();
	const size_t open = code.find('{', at);
	if (open == std::string::npos)
		return std::string();
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

StateMsg on_with(PeerId peer, uint8_t flags)
{
	StateMsg m;
	m.on = true;
	m.source = Source::Console;
	m.rows.push_back({peer, flags});
	return m;
}
} // namespace

// ---------------------------------------------------------------- invisible to the AI

TEST(debug_ai_an_invisible_player_is_left_out_on_the_authority)
{
	CHECK(ai_ignores(true, true, Body::OwnPlayer, kFlagInvisible)); // the host player's actor on the world server
	CHECK(ai_ignores(true, true, Body::Remote, kFlagInvisible)); // a client's proxy on the world server or on a map server
	CHECK(ai_ignores(true, true, Body::Remote, kFlagsAll));
	CHECK(!ai_ignores(true, true, Body::Remote, kFlagGod | kFlagAmmo)); // the other flags: seen as ever
	CHECK(!ai_ignores(true, true, Body::OwnPlayer, 0));
}

TEST(debug_ai_nobody_else_is_left_out)
{
	CHECK(!ai_ignores(true, true, Body::Other, kFlagsAll)); // an NPC, a parked character
	CHECK(!ai_ignores(true, true, Body::Ghost, kFlagsAll)); // a map server's / the dedicated host's actor: npc_ai::ghost already
	CHECK(!ai_ignores(true, false, Body::Remote, kFlagInvisible)); // a player's machine: its NPCs are puppets
	CHECK(!ai_ignores(true, false, Body::OwnPlayer, kFlagInvisible));
	CHECK(!ai_ignores(false, true, Body::OwnPlayer, kFlagInvisible)); // single player: the stock
}

TEST(debug_ai_the_flag_counts_while_the_debug_is_on_only)
{
	StateMsg m = on_with(2, kFlagInvisible);
	CHECK(ai_ignores(true, true, Body::Remote, m.flags_of(2)));
	CHECK(!ai_ignores(true, true, Body::Remote, m.flags_of(1))); // another player
	m.on = false;
	CHECK(!ai_ignores(true, true, Body::Remote, m.flags_of(2)));
	ServerState s;
	CHECK(s.switch_on(Source::Console));
	CHECK(s.set_flags(0, kFlagInvisible) == ServerState::FlagsResult::Changed);
	CHECK(ai_ignores(true, true, Body::OwnPlayer, s.flags(0))); // the host player: the world server's own book, no message
	CHECK(s.switch_off());
	CHECK(!ai_ignores(true, true, Body::OwnPlayer, s.flags(0)));
}

// ---------------------------------------------------------------- a monster's stamina blow and god

TEST(debug_ai_a_blow_asks_the_flag_of_the_player_it_lands_on)
{
	CHECK(blow_spares(true, Body::OwnPlayer, kFlagGod, false, false)); // his row, whatever this process's AF_GODMODE says
	CHECK(blow_spares(true, Body::Remote, kFlagGod, false, false));
	CHECK(!blow_spares(true, Body::Remote, 0, true, true)); // the authority's own god is not his
	CHECK(!blow_spares(true, Body::OwnPlayer, kFlagInvisible | kFlagAmmo, true, false)); // a g_god of before the session: no
	CHECK(blow_spares(true, Body::OwnPlayer, 0, false, true)); // a scene's god (AF_GODMODE_RT) on this machine's own actor
	CHECK(blow_spares(true, Body::Ghost, 0, false, false)); // a ghost is nobody: nothing lands
	CHECK(!blow_spares(true, Body::Other, kFlagGod, true, true)); // not a player
	CHECK(blow_spares(true, Body::OwnPlayer, on_with(0, kFlagGod).flags_of(0), false, false));
	StateMsg off = on_with(0, kFlagGod);
	off.on = false;
	CHECK(!blow_spares(true, Body::OwnPlayer, off.flags_of(0), false, false));
}

TEST(debug_ai_a_blow_out_of_a_session_is_the_stock)
{
	CHECK(blow_spares(false, Body::OwnPlayer, 0, true, false));
	CHECK(!blow_spares(false, Body::OwnPlayer, kFlagGod, false, true)); // GodMode() already holds the scene's god
	CHECK(!blow_spares(false, Body::Other, kFlagGod, false, false));
}

// ---------------------------------------------------------------- the wiring in the engine's sources

// The stock ai_ignore_actor (psAI_Flags aiIgnoreActor) is tested where a creature's memory takes an object: vision
// (CVisualMemoryManager::should_ignore_object), hearing (CSoundMemoryManager::feel_sound_new), hits (CHitMemoryManager::add, twice)
// and a smart cover's hit callback. The per-player test stands beside each, outside MASTER_GOLD.
TEST(debug_ai_every_stock_ignore_actor_has_the_players_test)
{
	const char* const files[] = {"visual_memory_manager.cpp", "sound_memory_manager.cpp", "hit_memory_manager.cpp",
	    "smart_cover_animation_planner.cpp"};
	size_t stock = 0;
	for (const char* f : files)
	{
		const std::string code = code_of(f);
		REQUIRE(!code.empty());
		const size_t tests = count_of(code, "psAI_Flags.test(aiIgnoreActor)");
		const size_t ours = count_of(code, "npc_ai::debug_unseen(");
		stock += tests;
		if (ours < tests)
			t::report_failure(__FILE__, __LINE__, std::string(f) + ": " + std::to_string(tests) + " stock test(s), " + std::to_string(ours) +
			    " per-player");
	}
	CHECK_EQ(stock, size_t(5)); // a broken scan is no pass
}

// The enemy choice (CEnemyManager::useful, need_update, on_enemy_change; a monster's enemy memory drops by useful) asks
// player_out_for: an invisible player is out for every creature. nearest_player (a poltergeist's senses, a phantom's target) skips him.
TEST(debug_ai_the_enemy_choice_drops_an_invisible_player)
{
	const std::string code = code_of("coop/coop_ai.cpp");
	REQUIRE(!code.empty());
	CHECK(count_of(body_of(code, "bool player_out_for("), "debug_unseen(") >= 1);
	CHECK(count_of(body_of(code, "CEntityAlive* nearest_player("), "debug_unseen(") >= 2); // this machine's actor and the others
	const std::string enemy = code_of("enemy_manager.cpp");
	CHECK(count_of(body_of(enemy, "bool CEnemyManager::useful("), "npc_ai::player_out_for(") == 1);
	// a poltergeist's senses fall back on the host's actor when nobody else is near: its actor-ignore covers him
	const std::string polter = code_of("ai/monsters/poltergeist/poltergeist.cpp");
	CHECK(count_of(body_of(polter, "bool CPoltergeist::get_actor_ignore("), "npc_ai::debug_unseen(") == 1);
}

// A.2 p. 7: the burer's and the controller's stamina blows asked the process's GodMode(); now the god of the player they land on.
TEST(debug_ai_burer_and_controller_ask_the_players_god)
{
	const std::string burer = code_of("ai/monsters/burer/burer.cpp");
	const std::string controller = code_of("ai/monsters/controller/controller.cpp");
	REQUIRE(!burer.empty() && !controller.empty());
	CHECK_EQ(count_of(burer, "GodMode()"), size_t(0));
	CHECK_EQ(count_of(controller, "GodMode()"), size_t(0));
	CHECK(count_of(body_of(burer, "void xr_stdcall CBurer::StaminaHit("), "npc_ai::player_god(") == 1);
	CHECK(count_of(body_of(controller, "void CController::stamina_hit_actor("), "npc_ai::player_god(") == 1);
	// the world server spares a god player the message too: his machine would only drop it
	CHECK(count_of(body_of(controller, "void CController::HitEntity("), "npc_ai::player_god(") == 1);
}
