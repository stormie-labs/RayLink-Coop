#include "test_util.h"
#include "srv/coop_dedicated_rules.h"
#include "support/fake_mode.h"

#include <fstream>
#include <iterator>
#include <string_view>

namespace
{
// The native suite cannot link the stock engine translation units. Check the stock
// call sites and the actual mode overrides at that boundary.
std::string stock_source(const char* path)
{
	const std::string here = __FILE__;
	const auto slash = here.find_last_of("\\/");
	const auto root = slash == std::string::npos ? std::string(".") : here.substr(0, slash);
	std::ifstream file(root + "/../engine/src/" + path, std::ios::binary);
	REQUIRE(file.good());
	return {std::istreambuf_iterator<char>(file), {}};
}

bool contains(std::string_view src, std::string_view code)
{
	return src.find(code) != std::string_view::npos;
}

std::string_view block(std::string_view src, std::string_view start, std::string_view end)
{
	const auto first = src.find(start);
	REQUIRE(first != std::string_view::npos);
	const auto last = src.find(end, first + start.size());
	REQUIRE(last != std::string_view::npos);
	return src.substr(first, last - first);
}

void check_spawn_routes()
{
	const std::string alife = stock_source("xrGame/alife_simulator_script.cpp");
	const auto item2 = block(alife, "CSE_Abstract* CALifeSimulator__spawn_item2(", "\n}");
	const auto item3 = block(alife, "CSE_Abstract* CALifeSimulator__spawn_item3(", "\n}");
	const auto ammo = block(alife, "CSE_Abstract* CALifeSimulator__spawn_ammo(", "\n}");
	const std::string_view condition = "!object->m_bOnline || coop::mode().online_elsewhere(object->ID))";
	CHECK(contains(item2, std::string("if (") + std::string(condition)));
	CHECK(contains(item3, std::string("if (") + std::string(condition)));
	CHECK(contains(ammo, std::string("if (!object || ") + std::string(condition)));
}

struct StockCase
{
	const char* source;
	const char* mode;
	const char* command_line;
	bool console_boot;
	bool consults_transfer_book;
};

void check_stock_mode(const StockCase& kind)
{
	CHECK_EQ(coop::dedicated::has_key(kind.command_line), kind.console_boot);
	const std::string source = stock_source(kind.source);
	// both co-op modes answer it in their common base (CoopModeBase)
	const bool co = std::string_view(kind.mode).rfind("Coop", 0) == 0;
	if (co)
		CHECK(contains(source, std::string("class ") + kind.mode + " final : public CoopModeBase"));
	const auto mode = co ? block(source, "class CoopModeBase : public ModeWithAnswers", "\n};") :
	                       block(source, std::string("class ") + kind.mode + " final", "\n};");
	const auto answer = block(mode, "bool online_elsewhere(", "\n");
	CHECK(contains(answer,
	    kind.consults_transfer_book ? "return levels::online_at_server(id);" : "return false;"));
	check_spawn_routes();
}
} // namespace

#define STOCK_coop_host "xrGame/coop/hostplay/coop_hostplay_mode.cpp", "CoopHostMode", "-coop_host", false, false
#define STOCK_coop_client "xrGame/coop/hostplay/coop_hostplay_mode.cpp", "CoopClientMode", "-coop_connect", false, false
#define STOCK_world_server "xrGame/coop/srv/coop_srv_mode.cpp", "WorldServerMode", "-coop_dedicated 27960", true, true
#define STOCK_map_server "xrGame/coop/srv/coop_srv_mode.cpp", "MapServerMode", "-coop_mapserver 1 2 27960", false, false
#define STOCK_server_client "xrGame/coop/srv/coop_srv_mode.cpp", "ServerClientMode", "-coop_connect", false, false
#define STOCK_none "xrCoop/coop_mode.h", "NoneMode", "", false, false

#define STOCK_MODE_TEST(kind) TEST(mode_stock_##kind) { check_stock_mode({STOCK_##kind}); }
MODE_CASES(STOCK_MODE_TEST)
#undef STOCK_MODE_TEST

TEST(mode_stock_render_uses_the_flag_set_before_the_session)
{
	const std::string boot = stock_source("xrEngine/x_ray.cpp");
	CHECK(contains(boot, "g_dedicated_server = true;"));
	CHECK(contains(boot, "use_reshade = !g_dedicated_server && init_reshade();"));
	const std::string device = stock_source("xrEngine/device.cpp");
	CHECK(contains(device, "if (!m_hWnd || g_dedicated_server)"));
	const std::string level = stock_source("xrGame/Level.cpp");
	CHECK(contains(level, "if (spawn_antifreeze && g_bootComplete && (!g_dedicated_server || g_actor))"));
}

TEST(mode_stock_ai_and_scripts_run_in_windowless_processes)
{
	const char* const simulation_files[] = {
	    "xrGame/Actor.cpp", "xrGame/Actor_Network.cpp", "xrGame/GameObject.cpp", "xrGame/Level.cpp",
	    "xrGame/Level_network.cpp", "xrGame/ai_space.cpp", "xrGame/game_sv_base.cpp",
	};
	for (const char* path : simulation_files)
	{
		const std::string code = stock_source(path);
		if (contains(code, "!g_dedicated_server || g_coop_headless") ||
		    contains(code, "g_dedicated_server && !g_coop_headless"))
			t::report_failure(__FILE__, __LINE__, std::string(path) + " still gates stock simulation");
	}
}
