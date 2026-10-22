MODE = "host"
dofile("tests/lua/support/stubs.lua")
print("== host")

C = {}
_G.bump = function(k) C[k] = (C[k] or 0) + 1 end
load_coop_main()
check(DEV_DEBUG == true, "host keeps debug mode")
local host_fn = from_script("sim_board", "return function() bump('host') end")
RegisterScriptCallback("actor_on_update", host_fn)
coop_main.on_game_start()

SendScriptCallback("actor_on_update")
check(C.host == 1, "host callbacks are not filtered on the host")
local flags = { ret = false }
SendScriptCallback("on_before_save_input", flags, 1, "save")
check(flags.ret == false, "host can save")

-- idle state is announced to the client
check(#SENT == 1 and SENT[1].name == "coop_env" and SENT[1].target == 1, "idle emission state sent to the client")
local st = coop_main.decode(SENT[1].payload)
check(st.s == false and st.p == false and st.c == true, "idle state content")

-- an emission starts on the host
local sm = surge_manager.get_surge_manager()
sm.started = true
sm.inited_time = game.get_game_time()
GAME_MS = GAME_MS + 120000
PROXY_POS.cover = false
NOW = NOW + 300
SendScriptCallback("actor_on_update")
st = coop_main.decode(SENT[#SENT].payload)
check(st.s == true and math.abs(st.sg - 120) < 0.01 and st.c == false, "active state with elapsed time and cover verdict")

-- the stock surge reaches its kill moment
sm:kill_all_unhided()
check(ORIG_KILL_ALL == 1, "original kill_all_unhided still runs on the host")
check(SENT[#SENT].name == "coop_env_kill" and SENT[#SENT].target == 1, "kill decision sent to the uncovered player")
local n = #SENT
sm:kill_all_unhided()
check(#SENT == n, "one kill per emission")

-- signal rockets stay a host job that keeps working there (R5 I2: only clients lose them)
sm:launch_rockets()
psi_storm_manager.get_psi_storm_manager():launch_rockets()
check(ROCKETS_LAUNCHED == 2, "launch_rockets of the surge and the psi storm still run on the host")

-- covered player is not killed in the next emission
sm.started = false
NOW = NOW + 300
SendScriptCallback("actor_on_update")
sm.started = true
NOW = NOW + 300
SendScriptCallback("actor_on_update")
PROXY_POS.cover = true
n = #SENT
sm:kill_all_unhided()
check(#SENT == n, "sheltered player is not killed")

coop_main.on_event("coop_env_req", "", 1)
NOW = NOW + 300
n = #SENT
SendScriptCallback("actor_on_update")
check(#SENT == n + 1, "state re-sent on request")

coop_main.print_status()
print(string.format("HOST: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
