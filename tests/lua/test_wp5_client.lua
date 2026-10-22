MODE = "client"
dofile("tests/lua/support/stubs.lua")
print("== client")

C = {}
local function bump(k) C[k] = (C[k] or 0) + 1 end
_G.bump = bump

-- registered before coop_main loads (must be reclassified by the rescan)
local pre_host = from_script("treasure_manager", "return function() bump('pre_host') end")
local pre_view = from_script("ui_extra", "return function() bump('pre_view') end")
RegisterScriptCallback("actor_on_update", pre_host)
RegisterScriptCallback("actor_on_update", pre_view)

load_coop_main()
check(DEV_DEBUG == false, "DEV_DEBUG forced off on the client")

-- sim_board has no rule: since F2 T10 it follows the callback (actor_on_update = owner) and runs on a client, its
-- world calls go to the host through the engine (review R5 I4; before, an unlisted script was host by default).
local host_fn = from_script("sim_board", "return function() bump('host') end")
local host_listed = from_script("death_manager", "return function() bump('host_listed') end") -- [route_scripts] host
local owner_fn = from_script("actor_effects", "return function() bump('owner') end")
local err_fn = from_script("ui_inventory", "return function() bump('err'); error('boom') end")
local blocked_fn = from_script("ui_debug_launcher", "return function() bump('blocked') end")
local load_host = from_script("treasure_manager", "return function() bump('load_host') end")
local squad_view = from_script("ui_pda_npc_tab", "return function() bump('squad_view') end")
local obj = from_script("ui_obj", "return { actor_on_update = function(self) bump(self.tag) end, tag = 'obj' }")

RegisterScriptCallback("actor_on_update", host_fn)
RegisterScriptCallback("actor_on_update", host_listed)
RegisterScriptCallback("actor_on_update", owner_fn)
RegisterScriptCallback("actor_on_update", err_fn)
RegisterScriptCallback("on_key_press", blocked_fn)
RegisterScriptCallback("load_state", load_host)
RegisterScriptCallback("squad_on_update", squad_view)
RegisterScriptCallback("actor_on_update", obj)
coop_main.on_game_start()

SendScriptCallback("actor_on_update")
check(C.pre_host == nil, "pre-registered host callback skipped")
check(C.pre_view == 1, "pre-registered view callback runs")
check(C.host == 1, "an unlisted script's actor_on_update runs on a client (owner by the callback)")
check(C.host_listed == nil, "host-domain callback skipped")
check(C.owner == 1, "owner callback runs")
check(C.err == 1, "erroring view callback ran and its error was caught")
check(C.obj == 1, "object callback runs with self")
SendScriptCallback("on_key_press", 1)
check(C.blocked == nil, "blocked (debug) callback skipped")
SendScriptCallback("load_state", {})
check(C.load_host == 1, "load_state of a host script runs (callbacks_always)")
SendScriptCallback("squad_on_update")
check(C.squad_view == nil, "squad_on_update of a view script skipped (callbacks_host)")

local before = axr_main.count("actor_on_update")
UnregisterScriptCallback("actor_on_update", owner_fn)
check(axr_main.count("actor_on_update") == before - 1, "unregister removes the wrapper")
SendScriptCallback("actor_on_update")
check(C.owner == 1, "unregistered callback no longer runs")
UnregisterScriptCallback("actor_on_update", obj)
check(axr_main.count("actor_on_update") == before - 2, "unregister of an object callback")

-- unique calls and time events
local uc_host = from_script("surge_manager", "return function() bump('uc_host') return false end")
local uc_err = from_script("xrs_dyn_music", "return function() error('loop broken') end")
AddUniqueCall(uc_host)
AddUniqueCall(uc_err)
check(UNIQUE[#UNIQUE - 1]() == false and C.uc_host == nil, "host unique call skipped, stays registered")
check(UNIQUE[#UNIQUE]() == true, "broken view unique call returns true (unregisters)")
local n = #UNIQUE
RemoveUniqueCall(uc_host)
check(#UNIQUE == n - 1, "RemoveUniqueCall finds the wrapper")
local te_host = from_script("death_manager", "return function() bump('te_host') end")
CreateTimeEvent("x", "y", 1, te_host)
check(TIMEEV[#TIMEEV].f() == true and C.te_host == nil, "host time event skipped and removed")

-- save / load / debug gates
local flags = { ret = false }
SendScriptCallback("on_before_save_input", flags, 1, "save")
check(flags.ret == true, "save input blocked")
flags = { ret = false }
SendScriptCallback("on_before_load_input", 1, 2, flags)
check(flags.ret == true, "quick load blocked")
ui_main_menu.main_menu.OnButton_save_clicked({})
check(SAVED_DIALOG == nil, "main menu save button blocked")
ui_debug_launcher.start_debug_main()
check(DEBUG_OPENED == nil, "debug menu entry stubbed")

-- payloads
local t = coop_main.decode(coop_main.encode({ a = "x;y=z%", n = 12.5, b = true, f = false }))
check(t.a == "x;y=z%" and t.n == 12.5 and t.b == true and t.f == false, "encode/decode round trip")

-- emission mirror
check(surge_manager.CSurgeManager.kill_objects_at_pos ~= nil, "surge class still has methods")
coop_main.on_event("coop_env", coop_main.encode({ s = true, sg = 300, p = false, pg = 0, tf = 10, c = false }), 0)
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
local sm = surge_manager.get_surge_manager()
check(sm.started == true, "client surge mirror started")
check(#SURGE_LOG == 1 and SURGE_LOG[1].cover == false, "update ran with the host cover verdict (outside)")
check(_EVENT.current_safe_cover == nil, "local cover value restored after the update")
check(NPC_KILLS == nil and ORIG_KILL_ALL == nil, "NPC killing / kill_all_unhided disabled on the client")
sm:launch_rockets()
psi_storm_manager.get_psi_storm_manager():launch_rockets()
check(ROCKETS_LAUNCHED == nil, "launch_rockets of the surge and the psi storm disabled on the client (R5 I2)")
check(TF == 10, "time factor follows the host")
check(math.abs((GAME_MS - SURGE_LOG[1].inited) / 1000 - 310) < 1, "elapsed game seconds = host value + extrapolation")
coop_main.on_event("coop_env", coop_main.encode({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true }), 0)
NOW = NOW + 300
SendScriptCallback("actor_on_update")
check(sm.started == false and SURGE_ENDED == 1, "surge mirror ended with the host")
coop_main.on_event("coop_env_kill", coop_main.encode({ kind = "surge" }), 0)
check(KILLED == 1, "host kill decision kills the local actor")
coop_main.on_event("coop_env_kill", "", 3)
check(KILLED == 1, "kill from a non-host sender ignored")

-- events, chat, errors in handlers
coop_main.add_event_handler("bad", function() error("handler bug") end)
coop_main.on_event("bad", "", 0)
coop_main.on_chat("bob", "hello")
check(NEWS[1] == "Co-op: bob: hello", "chat shown as PDA news")
check(SENT[1] and SENT[1].name == "coop_env_req" and SENT[1].target == 0, "client asked the host for the emission state")

coop_main.print_status()
print(string.format("CLIENT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
