// Anomaly Coop unit tests: TZ P45 (Dev 58, report RL-89RT-DQYR #1664, temp/r45/report-1664.txt), Server. The world server died on
// FATAL R_ASSERT l_tpALifeMonsterAbstract->children.empty() in CALifeCombatManager::kill_entity: scripts\coop_srv_quests_far.script
// carried out an order "kill" on a record (its map server gone or silent) with alife():kill_entity, on the corpse a recover-item task
// had made with the quest item inside.
//   1. Why kill_entity may not be asked for a body that holds something: it detaches the inventory first, the stock's detach does
//      nothing for a stalker or a monster, and then it asserts that the body holds nothing.
//   2. The world server's way instead, srv.kill_record (srv/coop_srv_script.cpp): only in the world server's process, only a living
//      creature that is not a player's character, killed the way the world applies a death a map server reports (the journal's Died
//      entry in srv/coop_levels_alife.cpp: levels::host_apply_death, then events::host_on_death); the body keeps what it holds.
// Coop: srv.kill_record answers false in a co-op process (dedicated::on() is false there) and the co-op's scripts never ask for it.
// The engine's files cannot run here: what they do is read from the sources, as tests/test_mode_review_e1.cpp does.
#include "test_util.h"

#include <fstream>
#include <regex>
#include <sstream>
#include <string>

namespace
{
// engine/src, found next to this source file (tests\ -> ..\engine\src)
std::string p45_engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	return here + "/../engine/src";
}

std::string p45_read(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The source with // and /* */ comments blanked (string literals kept).
std::string p45_code(const std::string& src)
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

std::string p45_collapse(const std::string& s)
{
	const std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

bool p45_has(const std::string& text, const std::string& what) { return text.find(what) != std::string::npos; }

// The body between the braces that open at `open` (the index of '{'); "" when they do not close.
std::string p45_braced(const std::string& code, size_t open)
{
	int depth = 1;
	size_t i = open + 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : code.substr(open + 1, i - 2 - open);
}

// The collapsed body of the first function whose head matches `head` (a regex ending at the name); "<none>" and a failure when none.
std::string p45_body(const std::string& code, const std::string& head)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(head + R"(\s*\([^;{]*\)\s*(?:const\s*)?\{)")))
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return "<none>";
	}
	return p45_collapse(p45_braced(code, size_t(m.position(0) + m.length(0) - 1)));
}

// The collapsed text of a `case <label>:` up to the next case of the same switch (or its end).
std::string p45_case(const std::string& code, const std::string& label)
{
	const size_t at = code.find("case " + label + ":");
	if (at == std::string::npos)
	{
		t::report_failure(__FILE__, __LINE__, "no case " + label);
		return "<none>";
	}
	const size_t next = code.find("\tcase ", at + 1);
	return p45_collapse(code.substr(at, next == std::string::npos ? std::string::npos : next - at));
}

size_t p45_at(const std::string& text, const std::string& what)
{
	const size_t at = text.find(what);
	return at == std::string::npos ? size_t(-1) : at;
}
} // namespace

// 1. CALifeCombatManager::kill_entity: vfDetachAll(), then R_ASSERT(children.empty()). A stalker's vfDetachAll is his brain's
// detach_all, empty in the stock; a monster's is empty too. Any body that holds one item stops the process: no script of ours may ask.
TEST(p45_kill_entity_asserts_on_a_body_that_holds_something)
{
	const std::string src = p45_engine_src();
	const std::string combat = p45_code(p45_read(src + "/xrGame/alife_combat_manager.cpp"));
	REQUIRE(!combat.empty());
	const std::string kill = p45_body(combat, R"(void\s+CALifeCombatManager::kill_entity)");
	const size_t detach = p45_at(kill, "l_tpALifeMonsterAbstract->vfDetachAll();");
	const size_t assert_empty = p45_at(kill, "R_ASSERT(l_tpALifeMonsterAbstract->children.empty());");
	CHECK(detach != size_t(-1));
	CHECK(assert_empty != size_t(-1));
	CHECK(detach < assert_empty);

	const std::string human = p45_code(p45_read(src + "/xrGame/alife_human_abstract.cpp"));
	REQUIRE(!human.empty());
	CHECK_EQ(p45_body(human, R"(void\s+CSE_ALifeHumanAbstract::vfDetachAll)"), std::string("brain().objects().detach_all(bFictitious);"));
	const std::string handler = p45_code(p45_read(src + "/xrGame/alife_human_object_handler.cpp"));
	REQUIRE(!handler.empty());
	CHECK_EQ(p45_body(handler, R"(void\s+CALifeHumanObjectHandler::detach_all)"), std::string(""));
	const std::string monsters = p45_code(p45_read(src + "/xrServerEntities/xrServer_Objects_ALife_Monsters.h"));
	REQUIRE(!monsters.empty());
	CHECK_EQ(p45_body(monsters, R"(virtual\s+void\s+vfDetachAll)"), std::string("")); // CSE_ALifeMonsterAbstract's, the first one
}

// 2. srv.kill_record: registered in the table srv, the world server's process only, and the same two steps as the journal's Died
// entry; kill_entity is not named in the file.
TEST(p45_srv_kill_record_applies_a_death_as_the_world_applies_a_map_server_s)
{
	const std::string src = p45_engine_src();
	const std::string code = p45_code(p45_read(src + "/xrGame/coop/srv/coop_srv_script.cpp"));
	REQUIRE(!code.empty());
	CHECK(p45_has(p45_collapse(code), "{\"kill_record\", &l_kill_record}"));
	CHECK(!p45_has(code, "kill_entity"));

	const std::string body = p45_body(code, R"(int\s+l_kill_record)");
	CHECK(p45_has(body, "dedicated::on() && is_world_server()")); // a co-op host's roles hold WorldServer too (test_mode_review_e1.cpp)
	const size_t apply = p45_at(body, "levels::host_apply_death(victim, killer, std::vector<u8>());");
	const size_t tell = p45_at(body, "events::host_on_death(victim, killer);");
	CHECK(apply != size_t(-1));
	CHECK(tell != size_t(-1));
	CHECK(apply < tell);
	CHECK(p45_has(body, "lua_pushboolean(L, dead); return 1;"));

	// only a living creature, never a player's character: his death is his own map's fact
	const std::string living = p45_body(code, R"(CSE_ALifeCreatureAbstract\s*\*\s*living_record)");
	CHECK(p45_has(living, "c->g_Alive()"));
	CHECK(p45_has(living, "!world::is_player_character(c)"));
	CHECK(p45_has(living, "world_up()"));
	// an id is a whole number below 0xffff, anything else is nobody
	CHECK(p45_has(body, "u16 victim = 0xffff, killer = 0xffff;"));
	CHECK(p45_has(body, "lua_api::arg_object_id(L, 1, victim);"));
	CHECK(p45_has(body, "lua_api::arg_object_id(L, 2, killer);"));

	// the journal's Died entry takes the same two steps: when it gains one, srv.kill_record needs it too
	const std::string alife = p45_code(p45_read(src + "/xrGame/coop/srv/coop_levels_alife.cpp"));
	REQUIRE(!alife.empty());
	const std::string died = p45_case(alife, "H::Died");
	CHECK(p45_has(died, "host_apply_death(victim, killer, st);"));
	CHECK(p45_has(died, "events::host_on_death(victim, killer);"));
}
