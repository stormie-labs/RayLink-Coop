// Anomaly Coop unit tests: the game UI is never laid out on a degenerate window size (xrEngine/ui_size_policy.h;
// owner 2026-11-08: "the minimap sometimes sits top-left, over the party panel").
//   - layout_family = ui_core::screenmode(): which XML variant a UI file loads (file.xml / file_16.xml / file_21.xml);
//     the stock thresholds, unchanged, written out here by hand for real resolutions.
//   - reset_action: CRenderDevice::Reset in a window (rs_screenmode windowed) takes the client rectangle, 0x0 while
//     the window is minimised; such a reset is deferred instead of laying the UI out on nothing.
//   - resume_deferred_reset: the deferred reset runs once the window is back, so the UI ends on the final size.
//   - hud_rebuild_allowed: CHUDManager::OnScreenResolutionChanged refuses a degenerate device size.
#include "test_util.h"

#include "../engine/src/xrEngine/ui_size_policy.h"

#include <string>

namespace
{
using namespace ui_size_policy;

struct SizeRow
{
	std::uint32_t w, h;
	std::uint8_t family; // 0 = file.xml, 1 = file_16.xml, 2 = file_21.xml
	const char* what;
};

// Expected families by hand: aspect > 1.8 -> 2, aspect > 1024/768 + 0.01 (1.34333) -> 1, else 0.
const SizeRow kSizes[] = {
	{800, 600, 0, "4:3"},
	{1024, 768, 0, "4:3"},
	{1600, 1200, 0, "4:3"},
	{1280, 1024, 0, "5:4"},
	{1375, 1024, 0, "1.3428, just under the 4:3 limit"},
	{1376, 1024, 1, "1.34375, just over the 4:3 limit"},
	{1280, 800, 1, "16:10"},
	{1680, 1050, 1, "16:10"},
	{1366, 768, 1, "16:9 laptop"},
	{1920, 1080, 1, "16:9"},
	{2560, 1440, 1, "16:9"},
	{3840, 2160, 1, "16:9"},
	{1800, 1000, 1, "exactly 1.8 stays 16:9 (strictly greater is 21:9)"},
	{1904, 1041, 2, "client area of a 1920x1080 window with a frame and a caption: 1.829"},
	{1264, 681, 2, "client area of a 1280x720 window: 1.856"},
	{2560, 1080, 2, "21:9 (64:27)"},
	{3440, 1440, 2, "21:9 (43:18)"},
	{5120, 1440, 2, "32:9"},
	{0, 0, 0, "degenerate: no division, the 4:3 family"},
	{1920, 0, 0, "degenerate: no division, the 4:3 family"},
};
} // namespace

TEST(ui_size_layout_family_table)
{
	for (const SizeRow& r : kSizes)
	{
		const std::uint8_t got = layout_family(r.w, r.h);
		if (got != r.family)
			t::report_failure(__FILE__, __LINE__,
				std::to_string(r.w) + "x" + std::to_string(r.h) + " (" + r.what + "): expected family " +
					std::to_string(r.family) + ", got " + std::to_string(got));
	}
}

TEST(ui_size_layout_suffix)
{
	CHECK_EQ(std::string(layout_suffix(0)), std::string(""));
	CHECK_EQ(std::string(layout_suffix(1)), std::string("_16"));
	CHECK_EQ(std::string(layout_suffix(2)), std::string("_21"));
	CHECK_EQ(std::string(layout_suffix(7)), std::string("?"));
}

TEST(ui_size_usable)
{
	CHECK(!usable(0, 0));       // GetClientRect of a minimised window
	CHECK(!usable(160, 28));    // the size Windows parks a minimised window at
	CHECK(!usable(319, 240));
	CHECK(!usable(320, 239));
	CHECK(usable(320, 240));
	CHECK(usable(800, 600));
	CHECK(usable(1904, 1041));
	CHECK(usable(5120, 1440));
}

TEST(ui_size_reset_in_a_window)
{
	// rs_screenmode windowed: the swap chain takes the client rectangle (CHW::selectResolution).
	CHECK(reset_action(kWindowed, true, 0, 0) == ResetAction::defer);         // minimised: 0x0
	CHECK(reset_action(kWindowed, true, 1904, 1041) == ResetAction::defer);   // minimised, a stale rectangle: still not
	CHECK(reset_action(kWindowed, false, 0, 0) == ResetAction::defer);        // shown but 0x0 (transitional)
	CHECK(reset_action(kWindowed, false, 160, 28) == ResetAction::defer);
	CHECK(reset_action(kWindowed, false, 1904, 1041) == ResetAction::run);    // a normal window
	CHECK(reset_action(kWindowed, false, 320, 240) == ResetAction::run);
}

TEST(ui_size_reset_borderless_and_fullscreen_run)
{
	// Borderless and exclusive fullscreen take vid_mode, never the window: a reset is never degenerate there
	// (and CHW::Reset shows the fullscreen window itself).
	CHECK(reset_action(kBorderless, true, 0, 0) == ResetAction::run);
	CHECK(reset_action(kBorderless, false, 1920, 1080) == ResetAction::run);
	CHECK(reset_action(kFullscreen, true, 0, 0) == ResetAction::run);
	CHECK(reset_action(kFullscreen, false, 2560, 1080) == ResetAction::run);
	CHECK(reset_action(7, true, 0, 0) == ResetAction::run); // only windowed (0) reads the client rectangle
}

TEST(ui_size_resume_deferred_reset)
{
	CHECK(!resume_deferred_reset(false, kWindowed, false, 1904, 1041)); // nothing owed
	CHECK(!resume_deferred_reset(false, kFullscreen, false, 1920, 1080));
	CHECK(!resume_deferred_reset(true, kWindowed, true, 0, 0));         // still minimised
	CHECK(!resume_deferred_reset(true, kWindowed, false, 0, 0));        // restoring, not sized yet
	CHECK(resume_deferred_reset(true, kWindowed, false, 1904, 1041));   // back: run it now
	CHECK(resume_deferred_reset(true, kFullscreen, true, 0, 0));        // switched to fullscreen meanwhile: run
}

TEST(ui_size_hud_rebuild_allowed)
{
	CHECK(!hud_rebuild_allowed(0, 0));
	CHECK(!hud_rebuild_allowed(1920, 0));
	CHECK(!hud_rebuild_allowed(160, 28));
	CHECK(hud_rebuild_allowed(1024, 768));
	CHECK(hud_rebuild_allowed(1904, 1041));
}

TEST(ui_size_minimised_vid_restart_scenario)
{
	// A windowed 1920x1080 game (client 1904x1041) is minimised and a reset arrives (vid_restart from a settings
	// menu, a driver's DXGI_ERROR_DEVICE_RESET). Stock: the reset read 0x0, Device became 0x0, the HUD was rebuilt
	// on it and layout_family(0,0) picked zone_map.xml, the 4:3 file (top-left on GAMMA). Now:
	std::uint32_t dev_w = 1904, dev_h = 1041;
	bool deferred = false;
	int hud_builds = 0;

	auto reset = [&](std::uint32_t rs, bool iconic, std::uint32_t cw, std::uint32_t ch) {
		if (reset_action(rs, iconic, cw, ch) == ResetAction::defer)
		{
			deferred = true;
			return;
		}
		deferred = false;
		const bool changed = cw != dev_w || ch != dev_h;
		dev_w = cw;
		dev_h = ch;
		if (changed && hud_rebuild_allowed(dev_w, dev_h))
			++hud_builds;
	};

	reset(kWindowed, true, 0, 0); // minimised
	CHECK(deferred);
	CHECK_EQ(dev_w, 1904u);
	CHECK_EQ(dev_h, 1041u);
	CHECK_EQ(hud_builds, 0);
	CHECK_EQ(int(layout_family(dev_w, dev_h)), 2); // the UI stays as it was built

	// The window is restored: the frame loop sees it and runs the owed reset on the real client size.
	if (resume_deferred_reset(deferred, kWindowed, false, 1904, 1041))
		reset(kWindowed, false, 1904, 1041);
	CHECK(!deferred);
	CHECK_EQ(dev_w, 1904u);
	CHECK_EQ(hud_builds, 0); // same size: nothing to rebuild

	// vid_mode changed while minimised: applied, and the HUD rebuilt, only after the restore.
	reset(kWindowed, true, 0, 0);
	CHECK(deferred);
	if (resume_deferred_reset(deferred, kWindowed, false, 1264, 681))
		reset(kWindowed, false, 1264, 681);
	CHECK_EQ(dev_w, 1264u);
	CHECK_EQ(dev_h, 681u);
	CHECK_EQ(hud_builds, 1);
}
