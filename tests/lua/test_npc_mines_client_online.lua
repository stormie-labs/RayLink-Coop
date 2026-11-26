-- Anomaly Coop test: a client's charges with that client online, on the process that decides the world or leads the map.
-- An NPC that steps on a contact charge sets it off, a timer charge goes off at its time, and a creature update with no
-- charges planted raises no error. Run once per answer set of the facade (support\modes.lua). "none" (no session) decides
-- nothing: the charges stay put. Not shipped.
-- Run: tools\test_lua.cmd npc_mines_client_online
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local MODE_PROX, MODE_TIMER = 0, 1
local CLIENT_CHARACTER = 500

-- The process of the set with one client online (peer 1, his character 500 at 10 m).
local function world(set)
	reset_world()
	local avatars = { [0] = 0, [1] = CLIENT_CHARACTER }
	local M = machine(set == "none" and "single" or "host", 0, avatars)
	local E = M.env
	E.coop_mode = load_script(M, "coop_mode")
	modes.install(E.coop_mode, set)
	E.coop_npc_players = load_script(M, "coop_npc_players")
	E.txr_mines = { plant_bomb = function() end, trigger_mine = function() end, _mines = {} }
	E.coop_mods_core = { mod = function() return nil end } -- no gameplay_silent_kills: not under test here
	E.alife_object = function(id) return M.objects[id] and { id = id } or nil end
	E.level.get_start_time = function() return { ms = 0 } end -- game seconds since the level started = game_ms / 1000
	M.game_ms = 0
	M.add(make_obj(CLIENT_CHARACTER, 10, 0, 0, { _name = "client's character" }))
	local W = load_script(M, "coop_npc_world")
	W.on_game_start()
	return M, W
end

local function tick(M)
	NOW = NOW + 300
	M.fire("actor_on_update")
end

for _, set in ipairs(modes.names()) do
	local decides = set ~= "none"

	-- a contact charge waits for somebody, then an NPC on it sets it off
	local M, W = world(set)
	local contact = M.add(make_obj(901, 80, 0, 0, { _section = "mine_new_blow" }))
	W._mines()[901] = { exp = 30, mode = MODE_PROX, planter = CLIENT_CHARACTER, active = true }
	M.game_ms = 31000
	tick(M)
	check(not contact._exploded, set .. ": a contact charge with nobody near waits")
	M.fire("npc_on_update", M.add(make_obj(300, 81, 0, 0, { _name = "npc" })))
	check((contact._exploded == true) == decides, set .. ": an NPC on a contact charge sets it off where the process decides")

	-- no charges planted: a creature update does nothing and raises nothing
	local M2 = world(set)
	tick(M2)
	M2.fire("npc_on_update", M2.add(make_obj(302, 1, 0, 0, {})))
	check(M2.env.coop_npc_players.error_count("world") == 0, set .. ": a creature update with no charges raises no error")

	-- a timer charge goes off at its time
	local M3, W3 = world(set)
	local timer = M3.add(make_obj(910, 50, 0, 0, { _section = "mine_new_blow" }))
	W3._mines()[910] = { exp = 60, mode = MODE_TIMER, planter = CLIENT_CHARACTER, active = true }
	M3.game_ms = 61000
	tick(M3)
	check((timer._exploded == true) == decides, set .. ": a timer charge goes off at its time where the process decides")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
