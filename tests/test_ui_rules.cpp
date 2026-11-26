// Anomaly Coop unit tests: what the UI and the input keep across a level (coop_ui_rules.h).
// Live 2026-10-31: a cursor stayed on the screen after a level change, and Esc on a held loading screen let a player fall
// into a main menu nobody had seen open.
#include "test_util.h"

#include "coop_ui_rules.h"

using namespace coop::ui_rules;

namespace
{
constexpr int kLoadScreenRenderPriority = 0; // CLoadScreenRenderer
constexpr int kCursorRenderPriority = -3; // CUICursor
} // namespace

TEST(ui_cursor_goes_with_the_level)
{
	CHECK(!cursor_outlives_level(false)); // the PDA was open at the go: its window dies without closing, the sprite must not stay
}

TEST(ui_cursor_stays_for_a_main_menu_that_is_open)
{
	CHECK(cursor_outlives_level(true)); // quitting from the main menu: the menu is what it points at
}

TEST(ui_cursor_comes_back_for_a_dialog_that_wants_it)
{
	CHECK(cursor_back_after_menu(true, true));
}

TEST(ui_cursor_stays_off_when_nothing_wants_it)
{
	CHECK(!cursor_back_after_menu(true, false)); // the level it was shown for is gone, or a stale cursor: the menu heals it
	CHECK(!cursor_back_after_menu(false, true));
	CHECK(!cursor_back_after_menu(false, false));
}

TEST(ui_menu_lies_where_the_stock_put_it)
{
	CHECK_EQ(menu_render_priority(false), kMenuRenderPriority);
}

TEST(ui_menu_over_a_held_loading_screen)
{
	// seqRender runs from high to low: the last one drawn is on top
	CHECK(menu_render_priority(true) < kLoadScreenRenderPriority);
	CHECK(menu_render_priority(false) > kLoadScreenRenderPriority);
	CHECK(menu_render_priority(true) > kCursorRenderPriority); // the cursor over the menu it points at
}

TEST(ui_input_flag_of_the_old_world_stays_there)
{
	// a mod's animation had level.disable_input on at the go; its script is gone with the old Lua state
	CHECK(!input_off_after_hold(true, 3, 4));
}

TEST(ui_input_flag_comes_back_in_the_same_world)
{
	CHECK(input_off_after_hold(true, 3, 3)); // the hold fell through on the old level: the script is still there to clear it
	CHECK(!input_off_after_hold(false, 3, 3));
	CHECK(!input_off_after_hold(false, 3, 4));
}

TEST(ui_tutorials_xml_is_kept_within_one_lua_state)
{
	CHECK(tutorials_xml_reusable(true, true, 3, 3)); // the campfire stutter of a read on every prompt stays fixed
}

TEST(ui_tutorials_xml_is_read_the_first_time)
{
	CHECK(!tutorials_xml_reusable(false, true, 0, 0));
}

TEST(ui_tutorials_xml_is_read_during_a_load)
{
	CHECK(!tutorials_xml_reusable(true, false, 3, 3)); // single player's "press any key" read, the stock path
}

TEST(ui_tutorials_xml_goes_with_its_lua_state)
{
	// Live 2026-10-31: the boot logo read it in the main menu's Lua state; a client never gets "press any key", the one read
	// of a load, so the XML kept pointing at functions of a state that was gone and no use prompt was ever drawn.
	CHECK(!tutorials_xml_reusable(true, true, 0, 1));
	CHECK(!tutorials_xml_reusable(true, true, 3, 4)); // the next level the same
}
