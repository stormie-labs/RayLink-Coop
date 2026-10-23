// Anomaly Coop unit tests: when the game keeps the mouse cursor inside its window (xrEngine/cursor_policy.h;
// owner request 2026-10-23: "the cursor must leave the game window freely"). The policy is a pure function of four
// inputs; CRenderDevice::UpdateCursorClip turns the answer into ClipCursor calls.
//   mode 0 = stock: clipped whenever the window is active.
//   mode 1 = default: exclusive fullscreen (screenmode 2) is stock; windowed (0) and borderless (1) clip only while no
//            UI cursor is shown, i.e. in gameplay, so a menu, the inventory, the PDA and dialogs let the cursor out.
#include "test_util.h"

#include "../engine/src/xrEngine/cursor_policy.h"

namespace
{
constexpr std::uint32_t kWindowed = 0;
constexpr std::uint32_t kBorderless = 1;
constexpr std::uint32_t kFullscreen = 2;
constexpr std::uint32_t kStock = 0;
constexpr std::uint32_t kFree = 1;

struct Row
{
	bool window_active;
	std::uint32_t screenmode;
	bool ui_cursor_visible;
	std::uint32_t mode;
	bool expect_clip;
};

// Every combination of the four inputs, written out by hand (not derived from the rule under test).
const Row kTable[] = {
	// ---- mode 0 (stock): clipped exactly while the window is active; screenmode and the UI cursor do not matter
	{true, kWindowed, false, kStock, true},
	{true, kWindowed, true, kStock, true},
	{true, kBorderless, false, kStock, true},
	{true, kBorderless, true, kStock, true},
	{true, kFullscreen, false, kStock, true},
	{true, kFullscreen, true, kStock, true},
	{false, kWindowed, false, kStock, false},
	{false, kWindowed, true, kStock, false},
	{false, kBorderless, false, kStock, false},
	{false, kBorderless, true, kStock, false},
	{false, kFullscreen, false, kStock, false},
	{false, kFullscreen, true, kStock, false},

	// ---- mode 1 (default), window active: windowed / borderless follow the UI cursor, exclusive fullscreen is stock
	{true, kWindowed, false, kFree, true},      // gameplay (mouse look): clipped
	{true, kWindowed, true, kFree, false},      // menu / inventory / PDA / dialog: free
	{true, kBorderless, false, kFree, true},    // gameplay: clipped
	{true, kBorderless, true, kFree, false},    // menu: free
	{true, kFullscreen, false, kFree, true},    // exclusive fullscreen: as stock
	{true, kFullscreen, true, kFree, true},     // exclusive fullscreen menu: still as stock

	// ---- mode 1, window inactive: never clipped
	{false, kWindowed, false, kFree, false},
	{false, kWindowed, true, kFree, false},
	{false, kBorderless, false, kFree, false},
	{false, kBorderless, true, kFree, false},
	{false, kFullscreen, false, kFree, false},
	{false, kFullscreen, true, kFree, false},
};
} // namespace

TEST(cursor_policy_full_table)
{
	int n = 0;
	for (const Row& r : kTable)
	{
		const bool got = cursor_should_clip(r.window_active, r.screenmode, r.ui_cursor_visible, r.mode);
		if (got != r.expect_clip)
			t::report_failure(__FILE__, __LINE__,
				"row " + std::to_string(n) + " (active=" + std::to_string(r.window_active) + " screenmode=" +
					std::to_string(r.screenmode) + " ui_cursor=" + std::to_string(r.ui_cursor_visible) + " mode=" +
					std::to_string(r.mode) + "): expected clip=" + std::to_string(r.expect_clip) +
					", got " + std::to_string(got));
		++n;
	}
	CHECK_EQ(n, 24); // 2 modes x 2 activity states x 3 screen modes x 2 UI cursor states
}

TEST(cursor_policy_named_scenarios)
{
	// Gameplay in a window: the mouse look must stay inside, exactly as before.
	CHECK(cursor_should_clip(true, kWindowed, false, kFree));
	CHECK(cursor_should_clip(true, kBorderless, false, kFree));

	// Pause menu, inventory, PDA, dialog (the UI cursor is shown): the cursor leaves the window.
	CHECK(!cursor_should_clip(true, kWindowed, true, kFree));
	CHECK(!cursor_should_clip(true, kBorderless, true, kFree));

	// Exclusive fullscreen: the cursor stays inside everywhere (there is nowhere else to go).
	CHECK(cursor_should_clip(true, kFullscreen, true, kFree));
	CHECK(cursor_should_clip(true, kFullscreen, false, kFree));

	// An inactive window releases the cursor in every mode (alt-tab, another application in front).
	CHECK(!cursor_should_clip(false, kFullscreen, false, kFree));
	CHECK(!cursor_should_clip(false, kWindowed, false, kStock));
}

TEST(cursor_policy_stock_mode_ignores_ui_cursor)
{
	// g_free_cursor 0 gives the old behaviour back whatever the UI does.
	for (std::uint32_t screenmode = 0; screenmode <= kFullscreen; ++screenmode)
		for (const bool ui : {false, true})
		{
			CHECK(cursor_should_clip(true, screenmode, ui, kStock));
			CHECK(!cursor_should_clip(false, screenmode, ui, kStock));
		}
}

TEST(cursor_policy_out_of_range_values)
{
	// g_free_cursor is limited to 0..1 by the console; a stray value must not turn the feature off by accident:
	// any non-zero mode behaves like 1, and any screenmode other than 2 is a window.
	CHECK(!cursor_should_clip(true, kWindowed, true, 2));
	CHECK(cursor_should_clip(true, kWindowed, false, 2));
	CHECK(cursor_should_clip(true, kFullscreen, true, 2));
	CHECK(!cursor_should_clip(true, 7, true, kFree));
	CHECK(cursor_should_clip(true, 7, false, kFree));
}
