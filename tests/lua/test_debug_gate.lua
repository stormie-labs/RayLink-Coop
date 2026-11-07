-- Anomaly Coop test: R-6.6 on every machine of a session (docs/DEBUG_DESIGN.md B.8). DEV_DEBUG is off in a session on the host
-- too, and comes back when the session ends; the stock debug entry points of [route_none_functions] say "F7" in any session,
-- the host's included, and work as in the stock outside one. Not shipped. Run: tools\test_lua.cmd debug_gate
MODE = "host"
dofile("tests/lua/support/stubs.lua")
print("== host in a session")

SESSION = true
coop.is_active = function() return SESSION end
NEWS = {}
function news_manager_send(...) end
actor_menu = { set_msg = function(_, text) NEWS[#NEWS + 1] = text end }
ui_debug_launcher = { start_debug_main = function() DEBUG_OPENED = (DEBUG_OPENED or 0) + 1 end }
DEV_DEBUG, DEV_DEBUG_DEV = true, true
coop.route = coop.route or {}
coop.route.none_functions = function() return { "ui_debug_launcher.start_debug_main" } end

load_coop_main()
check(DEV_DEBUG == false and DEV_DEBUG_DEV == false, "host in a session: DEV_DEBUG is off (R-6.6 on every machine)")
coop_main.on_game_start()

ui_debug_launcher.start_debug_main()
check(DEBUG_OPENED == nil, "host in a session: the stock debug menu entry is stubbed")

print("== the session ends")
SESSION = false
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
check(DEV_DEBUG == true and DEV_DEBUG_DEV == true, "after the session DEV_DEBUG is what it was before")
ui_debug_launcher.start_debug_main()
check(DEBUG_OPENED == 1, "outside a session the stock debug menu opens")

print("== a session starts later in this Lua state")
SESSION = true
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
check(DEV_DEBUG == false, "a session that starts later turns DEV_DEBUG off")
ui_debug_launcher.start_debug_main()
check(DEBUG_OPENED == 1, "and the stub holds again")

print("== single player that never had -dbg")
SESSION = false
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
check(DEV_DEBUG == true, "restored")

print(string.format("DEBUG_GATE: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
