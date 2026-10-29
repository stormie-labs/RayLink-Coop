#include "test_util.h"
#include "coop_save_policy.h"
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

namespace {
std::string source(const char* name) {
    std::string here = __FILE__;
    const auto slash = here.find_last_of("\\/");
    here.resize(slash == std::string::npos ? 0 : slash);
    std::ifstream f(here + "/../engine/src/xrGame/" + name, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), {});
}
std::string body(const std::string& src, const std::string& head) {
    for (auto at = src.find(head); at != std::string::npos; at = src.find(head, at + 1)) {
        const auto close = src.find(')', at);
        const auto next = close == std::string::npos ? close : src.find_first_not_of(" \t\r\n", close + 1);
        if (next == std::string::npos || src[next] != '{') continue;
        const auto end = src.find("\n}", next);
        if (end != std::string::npos) return src.substr(next, end - next + 2);
    }
    return {};
}
}
TEST(save_policy_truth_table) {
    using coop::save_policy::may_save_world;
    CHECK(may_save_world(false, false)); // standalone and host
    CHECK(!may_save_world(true, false)); // connecting or live client
    CHECK(!may_save_world(false, true)); // disconnected mirror
    CHECK(!may_save_world(true, true));
}
TEST(save_policy_reserved_stem_exact) {
    using namespace coop::save_policy;
    CHECK_EQ(std::string(kClientStem), std::string("__raylink_client_world"));
    CHECK_EQ(std::string(kCacheFile), std::string("raylink\\cache\\client_world"));
    CHECK_EQ(std::string(kLegacyStem), std::string("coop_session"));
    CHECK(is_client_cache(kClientStem));
    CHECK(is_client_cache("__RaYLiNk_ClIeNt_WoRlD"));
    for (std::string_view name : {"", "coop_session", "__raylink_client_world.scop", "__raylink_client_world.scoc", "x__raylink_client_world", "__raylink_client_world_1", "saves/__raylink_client_world", "saves\\__raylink_client_world", "client_world"})
        CHECK(!is_client_cache(name));
}
TEST(save_contract_guard_precedes_side_effects) {
    const auto s = body(source("alife_storage_manager.cpp"), "void CALifeStorageManager::save(LPCSTR");
    REQUIRE(!s.empty());
    const auto guard = s.find("!coop::join::may_save_world()");
    REQUIRE(guard != std::string::npos);
    CHECK(s.find("if", 0) < guard);
    CHECK(s.find("return", guard) < s.find("on_blocking_work"));
    for (const char* effect : {"on_blocking_work", "g_last_saved_game", "before_save", "w_open"}) {
        const auto pos = s.find(effect);
        CHECK(pos != std::string::npos && guard < pos);
    }
}
TEST(save_contract_client_cache_paths) {
    const auto s = body(source("coop/coop_join.cpp"), "void client_load_world(");
    REQUIRE(!s.empty());
    CHECK(s.find("client_cache_path(scop, \".scop\")") != std::string::npos);
    CHECK(s.find("client_cache_path(scoc, \".scoc\")") != std::string::npos);
    CHECK(s.find("save_path(") == std::string::npos);
}
TEST(save_contract_wrapper_and_last_save) {
    const auto wrapper = body(source("saved_game_wrapper.cpp"), "LPCSTR CSavedGameWrapper::saved_game_full_name(");
    REQUIRE(!wrapper.empty());
    const auto check = wrapper.find("is_client_cache_save(saved_game_name)");
    const auto path = wrapper.find("client_cache_path(result, SAVE_EXTENSION)");
    CHECK(check != std::string::npos && path != std::string::npos && check < path);
    const auto load = body(source("alife_storage_manager.cpp"), "bool CALifeStorageManager::load(");
    REQUIRE(!load.empty());
    CHECK(load.find("CSavedGameWrapper::saved_game_full_name(save_name, file_name)") != std::string::npos);
    const auto guarded = load.find("!coop::join::is_client_cache_save(save_name)");
    const auto last = load.find("g_last_saved_game");
    CHECK(guarded != std::string::npos && last != std::string::npos && guarded < last);
}
TEST(save_contract_prepare_at_startup) {
    const auto init = body(source("coop/coop_sync.cpp"), "void init(");
    REQUIRE(!init.empty());
    CHECK(init.find("join::prepare_client_cache()") != std::string::npos);
}
TEST(save_contract_outer_loader_keeps_last_user_save) {
    const auto load = body(source("alife_update_manager.cpp"), "void CALifeUpdateManager::load(");
    REQUIRE(!load.empty());
    const auto guard = load.find("!coop::join::is_client_cache_save(game_name)");
    const auto last = load.find("xr_strcpy(g_last_saved_game, game_name)");
    CHECK(guard != std::string::npos && last != std::string::npos && guard < last);
}
TEST(save_contract_malformed_and_scoc_failure_abort_load) {
    const auto s = body(source("coop/coop_join.cpp"), "void client_load_world(");
    REQUIRE(!s.empty());
    const auto malformed = s.find("!r.ok()");
    const auto malformed_return = s.find("return;", malformed);
    const auto scoc_write = s.find("write_file(scoc");
    const auto load = s.find("g.load_issued = true");
    CHECK(malformed != std::string::npos && malformed_return != std::string::npos && malformed_return < scoc_write);
    REQUIRE(scoc_write != std::string::npos && load != std::string::npos);
    const auto fail = s.rfind("!write_file(scoc", scoc_write);
    const auto abort = s.find("return;", scoc_write);
    CHECK(fail != std::string::npos && abort != std::string::npos && abort < load);
}
