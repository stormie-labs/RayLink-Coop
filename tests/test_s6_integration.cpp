// Anomaly Coop unit tests: the S6 integration's leftovers in the lead's files (temp\w9b_lead.md, build 57). The engine files
// cannot run here; what each step asks for is read from the sources:
// - A-S6-E-surv2b: a map server's survival handlers are wired by the map server's mode, not chosen inside the Core installers
//   (docs/MODES.md section 4: each mode installs its own handler tables); the final tables are the same as before;
// - A-S6-L-worldb: coop.my_level() is a top-level binding of the guarded getter (nil while the world is built or torn down),
//   so the Core's flare cast (coop_world_fx) reads its level without the server's table coop.levels;
// - A-S6-E-econ2b: the obsolete money::server_balance declaration (its definition went with the old LevelMap path) is gone.
#include "test_util.h"

#include <fstream>
#include <sstream>
#include <string>

namespace
{
std::string engine_file(const char* rel)
{
	std::string path = __FILE__;
	const size_t slash = path.find_last_of("/\\");
	path = slash == std::string::npos ? "tests/" : path.substr(0, slash + 1);
	std::ifstream in(path + "../engine/src/" + rel, std::ios::binary);
	std::ostringstream out;
	out << in.rdbuf();
	std::string text = out.str();
	// the engine files use CRLF: compare on LF
	std::string lf;
	lf.reserve(text.size());
	for (char c : text)
		if (c != '\r')
			lf += c;
	return lf;
}

// from `signature` to the first line that is a closing brace at column 0 (a function at namespace scope) or at one tab (a member)
std::string body(const std::string& code, const std::string& signature, size_t from = 0, const char* end_mark = "\n}")
{
	const size_t start = code.find(signature, from);
	REQUIRE(start != std::string::npos);
	const size_t end = code.find(end_mark, start);
	REQUIRE(end != std::string::npos);
	return code.substr(start, end - start);
}

size_t at(const std::string& text, const char* what)
{
	return text.find(what);
}
} // namespace

TEST(s6_integration_map_server_mode_wires_its_survival_handlers)
{
	const std::string survival = engine_file("xrGame/coop/coop_survival.cpp");
	REQUIRE(!survival.empty());
	// the Core installers choose nothing by mode: the co-op's and the world server's tables, always
	const std::string server = body(survival, "void install_server(Session& s)");
	const std::string client = body(survival, "void install_client(Endpoint& e)");
	CHECK(server.find("mode().level()") == std::string::npos);
	CHECK(server.find("install_level_server") == std::string::npos);
	CHECK(server.find("Msg::PlayerWounded, &server_on_state") != std::string::npos);
	CHECK(server.find("Msg::PlayerRevive, &server_on_revive") != std::string::npos);
	CHECK(server.find("Msg::NewCharacter, &on_new_character_msg") != std::string::npos);
	CHECK(client.find("mode().level()") == std::string::npos);
	CHECK(client.find("install_level_client") == std::string::npos);
	CHECK(client.find("Msg::PlayerWounded, &client_on_state") != std::string::npos);
	CHECK(client.find("Msg::PlayerRevive, &client_on_revive") != std::string::npos);
	CHECK(client.find("Msg::PlayerRules, &on_rules_msg") != std::string::npos);
	// the map server's own functions still register the three level handlers (Session::on replaces a handler)
	const std::string level_server = body(survival, "void install_level_server(Session& s)");
	const std::string level_client = body(survival, "void install_level_client(Endpoint& e)");
	CHECK(level_server.find("Msg::PlayerWounded, &map_on_state") != std::string::npos);
	CHECK(level_client.find("Msg::PlayerWounded, &map_on_state_relay") != std::string::npos);
	CHECK(level_client.find("Msg::PlayerRevive, &map_on_revive") != std::string::npos);
	CHECK(level_client.find("Msg::PlayerRules, &map_on_rules") != std::string::npos);

	const std::string modes = engine_file("xrGame/coop/srv/coop_srv_mode.cpp");
	REQUIRE(!modes.empty());
	const size_t map_class = modes.find("class MapServerMode final");
	REQUIRE(map_class != std::string::npos);
	const std::string map_install = body(modes, "void install(ModeTables& tables) override", map_class, "\n\t}");
	// right after the Core's tables, in the place the Core's dispatch had them: the same final handler of each message
	const size_t core_server = at(map_install, "sync::install_server(tables.session);");
	const size_t level_srv = at(map_install, "survival::install_level_server(tables.session);");
	const size_t xfer_srv = at(map_install, "levels::xfer_install_server(tables.session);");
	const size_t core_client = at(map_install, "sync::install_client(tables.world);");
	const size_t level_cli = at(map_install, "survival::install_level_client(tables.world);");
	const size_t map_cli = at(map_install, "mapserver::install_client(tables.world);");
	CHECK(core_server != std::string::npos && level_srv != std::string::npos && core_server < level_srv && level_srv < xfer_srv);
	CHECK(core_client != std::string::npos && level_cli != std::string::npos && core_client < level_cli && level_cli < map_cli);
	// nobody else installs them: the world server's mode, the server player's
	const std::string world_install = body(modes, "void install(ModeTables& tables) override", modes.find("class WorldServerMode final"),
	    "\n\t}");
	CHECK(world_install.find("install_level_") == std::string::npos);
	size_t calls = 0;
	for (size_t p = modes.find("survival::install_level_"); p != std::string::npos; p = modes.find("survival::install_level_", p + 1))
	{
		CHECK(p > map_class && p < map_class + modes.substr(map_class).find("\n};"));
		++calls;
	}
	CHECK(calls == 2);
	const std::string hostplay = engine_file("xrGame/coop/hostplay/coop_hostplay_mode.cpp");
	CHECK(!hostplay.empty() && hostplay.find("install_level_") == std::string::npos);
}

TEST(s6_integration_coop_my_level_is_the_guarded_getter)
{
	const std::string script = engine_file("xrGame/coop/coop_script.cpp");
	REQUIRE(!script.empty());
	const std::string raw = body(script, "void register_raw(lua_State* L)");
	CHECK(raw.find("{\"my_level\", &levels::lua_my_level}") != std::string::npos);
	// one function answers coop.my_level and coop.levels.my_level: the getter, nil for no level
	const std::string levels = engine_file("xrGame/coop/coop_levels.cpp");
	CHECK(body(levels, "void register_lua(lua_State* L)").find("{\"my_level\", &lua_my_level}") != std::string::npos);
	CHECK(body(levels, "int lua_my_level(lua_State* L)").find("push_level(L, my_level())") != std::string::npos);
	const std::string push = body(levels, "void push_level(lua_State* L, LevelId level)");
	CHECK(push.find("wire::kNoLevel") != std::string::npos);
	CHECK(push.find("lua_pushnil(L)") != std::string::npos);
	// the getter it reads answers nothing while the world is built or torn down
	const std::string getter = body(levels, "LevelId my_level()");
	CHECK(getter.find("if (!world_up() || !ai().get_alife())") != std::string::npos);
	CHECK(getter.find("return wire::kNoLevel;") != std::string::npos);
}

// Review A-S6-E-econ2 (a gap HEAD had): a map server's Money is bounded before it reaches the world's balance. The trade byte is 0
// or 1, and the s64 delta is capped to what a u32 balance can take, so money::adjust's s64(balance) + delta cannot overflow;
// capped_balance gives a delta beyond +-UINT32_MAX the same result, so an honest report changes nothing. R32 WP4: the Money comes in
// the map server's journal and the world's one apply takes it (coop_levels_alife.cpp apply_money, its refusal counted and logged);
// a LevelEntity Money is no longer applied (coop_levels_xfer.cpp host_on_level_entity keeps Report alone).
TEST(s6_integration_level_money_report_is_bounded)
{
	const std::string alife = engine_file("xrGame/coop/srv/coop_levels_alife.cpp");
	REQUIRE(!alife.empty());
	const size_t start = alife.find("ApplyVerdict apply_money(");
	REQUIRE(start != std::string::npos);
	const std::string money = alife.substr(start, alife.find("return applied(e.op);", start) - start);
	const size_t read_trade = money.find("const u8 trade = r.u8();");
	const size_t refuse = money.find("trade > 1");
	const size_t cap = money.find("kMaxLevelMoneyDelta");
	const size_t adjust = money.find("money::host_adjust(PeerId(peer), bounded,");
	CHECK(read_trade != std::string::npos && refuse != std::string::npos && read_trade < refuse);
	CHECK(cap != std::string::npos && adjust != std::string::npos && cap < adjust && refuse < adjust);
	CHECK(money.find("const bool trade = r.u8() != 0;") == std::string::npos);
	CHECK(money.find("constexpr s64 kMaxLevelMoneyDelta = s64(0xffffffffu);") != std::string::npos);
	CHECK(money.find("return refuse(author, e.op, wire::kNoObject, journal::Malformed, why);") != std::string::npos);
	const std::string xfer = engine_file("xrGame/coop/srv/coop_levels_xfer.cpp");
	REQUIRE(!xfer.empty());
	CHECK(xfer.find("money::host_adjust(") == std::string::npos);
}

TEST(s6_integration_money_has_no_server_balance)
{
	CHECK(engine_file("xrGame/coop/coop_money.h").find("server_balance") == std::string::npos);
	CHECK(engine_file("xrGame/coop/coop_money.cpp").find("server_balance") == std::string::npos);
}
