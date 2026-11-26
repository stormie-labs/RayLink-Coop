// Anomaly Coop unit tests: the pause stock puts on a single player level that finished loading in a window without the focus
// (coop_device_rules.h, xrEngine/device.cpp Pause(..., "application start")).
// b57j stand, sp_smoke (2026-11-21): the new game loaded behind another window and stood paused for 2.5 minutes with
// g_always_active on; the probe's steps never came. Always-active keeps a window without the focus running everywhere else
// (CRenderDevice::OnWM_Activate), and now at the start too, with the same exception: fullscreen (g_screenmode 2).
#include "test_util.h"

#include "coop_device_rules.h"

using coop::device::pauses_at_start;

TEST(a_single_player_load_in_a_window_without_the_focus_pauses_as_stock)
{
	REQUIRE(pauses_at_start(true, false, false, 1));
	REQUIRE(pauses_at_start(true, false, false, 0));
	REQUIRE(pauses_at_start(true, false, false, 2));
}

TEST(always_active_keeps_it_running_except_in_fullscreen)
{
	REQUIRE(!pauses_at_start(true, false, true, 0));
	REQUIRE(!pauses_at_start(true, false, true, 1));
	REQUIRE(pauses_at_start(true, false, true, 2)); // OnWM_Activate does not keep a fullscreen window active either
}

TEST(no_pause_with_the_focus_or_outside_single_player)
{
	REQUIRE(!pauses_at_start(true, true, false, 1));
	REQUIRE(!pauses_at_start(true, true, true, 2));
	REQUIRE(!pauses_at_start(false, false, false, 1));
	REQUIRE(!pauses_at_start(false, false, true, 2));
}
