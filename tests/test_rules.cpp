// Anomaly Coop unit tests: story rules shared by the engine layer and the tests (coop_rules.h).
#include "test_util.h"

#include "coop_rules.h"

using coop::rules::is_machine_info;

// R4 1: info portions that describe what ONE machine's UI / body is doing stay on that machine.
TEST(rules_machine_info)
{
	// Exact names.
	CHECK(is_machine_info("ui_pda"));
	CHECK(is_machine_info("actor_is_sleeping"));
	CHECK(is_machine_info("sleep_active"));

	// Prefix `ui_talk*`: the bare prefix and anything after it.
	CHECK(is_machine_info("ui_talk"));
	CHECK(is_machine_info("ui_talk_trade"));
	CHECK(is_machine_info("ui_talk_free_dialog"));
	CHECK(is_machine_info("ui_talk_"));

	// Suffix `*_wnd_open`.
	CHECK(is_machine_info("inventory_wnd_open"));
	CHECK(is_machine_info("trade_wnd_open"));
	CHECK(is_machine_info("ui_car_body_wnd_open"));
	CHECK(is_machine_info("pda_wnd_open"));

	// Story infos are shared.
	CHECK(!is_machine_info("esc_trader_task_1_done"));
	CHECK(!is_machine_info("pda_found"));
	CHECK(!is_machine_info("ui")); // no suffix
	CHECK(!is_machine_info("ui_"));
	CHECK(!is_machine_info("ui_tal")); // shorter than the prefix
}

// The patterns are a prefix, a suffix and exact names — nothing looser.
TEST(rules_machine_info_boundaries)
{
	// Exact names do not match as prefixes or suffixes.
	CHECK(!is_machine_info("ui_pda_found"));
	CHECK(!is_machine_info("my_ui_pda"));
	CHECK(!is_machine_info("actor_is_sleeping_not"));
	CHECK(!is_machine_info("actor_is_sleep"));
	CHECK(!is_machine_info("sleep_active2"));
	CHECK(!is_machine_info("not_sleep_active"));
	CHECK(!is_machine_info("sleep"));

	// `ui_talk*` is a prefix only.
	CHECK(!is_machine_info("my_ui_talk"));
	CHECK(!is_machine_info("xui_talk_trade"));

	// `*_wnd_open` is a suffix only, with its underscore.
	CHECK(!is_machine_info("trade_wnd_open_x"));
	CHECK(!is_machine_info("wnd_open"));
	CHECK(!is_machine_info("trade_wnd_opened"));
	CHECK(!is_machine_info("trade_wnd_ope"));

	// Ids are case-sensitive, like the engine's shared strings.
	CHECK(!is_machine_info("UI_PDA"));
	CHECK(!is_machine_info("UI_TALK_trade"));
	CHECK(!is_machine_info("trade_WND_OPEN"));

	// No id at all is not a machine info.
	CHECK(!is_machine_info(nullptr));
	CHECK(!is_machine_info(""));
}
