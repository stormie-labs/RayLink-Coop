-- Anomaly Coop test: a client's charges keep working while the process that decides the world has no client online.
-- coop_npc_world keeps the charges clients planted (host_on_mine) and saves them with the game. A timer charge goes off at
-- its time and a contact charge reacts to an NPC or a monster with the planter gone or after a load with nobody joined
-- yet. Run once per answer set of the facade (support\modes.lua). "none" (no session) decides nothing: the charges stay
-- put. Not shipped.
-- Run: tools\test_lua.cmd npc_mines_host_alone
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
	return M, W, avatars
end

local function tick(M)
	NOW = NOW + 300 -- past the 250 ms step of actor_on_update
	M.fire("actor_on_update")
end

local function client_leaves(M, avatars)
	avatars[1] = nil
	M.objects[CLIENT_CHARACTER] = nil
	M.env.coop_npc_players.invalidate()
end

local function charge(M, id, x) return M.add(make_obj(id, x, 0, 0, { _section = "mine_new_blow" })) end

for _, set in ipairs(modes.names()) do
	local decides = set ~= "none"
	local fires = decides and "goes off" or "stays (nothing decides here)"

	print("== " .. set .. ": the client planted a timer and a contact charge, then left")
	local M, W, avatars = world(set)
	local timer, contact = charge(M, 900, 50), charge(M, 901, 80)
	-- what host_on_mine keeps for a client's charge: armed at `exp` game seconds, set off as its planter
	W._mines()[900] = { exp = 60, mode = MODE_TIMER, planter = CLIENT_CHARACTER, active = true }
	W._mines()[901] = { exp = 30, mode = MODE_PROX, planter = CLIENT_CHARACTER, active = true }
	tick(M)
	check(not timer._exploded and not contact._exploded, set .. ": client online, before their time: nothing goes off")
	client_leaves(M, avatars)
	tick(M)
	check(not timer._exploded, set .. ": host alone, timer charge before its time: waits")
	M.game_ms = 61000
	tick(M)
	check(W._mines()[900] ~= nil and (timer._exploded == true) == decides, set .. ": host alone, timer charge at its time " .. fires)
	local npc = M.add(make_obj(300, 120, 0, 0, { _name = "npc" }))
	M.fire("npc_on_update", npc)
	check(not contact._exploded, set .. ": an NPC 40 m from the contact charge: it waits")
	npc._pos = vec(81, 0, 0)
	M.fire("npc_on_update", npc)
	check((contact._exploded == true) == decides, set .. ": host alone, an NPC steps on the contact charge: it " .. fires)
	if set == "hostplay" then
		local own = charge(M, 902, 30)
		W._mines()[902] = { exp = 0, mode = MODE_PROX, planter = CLIENT_CHARACTER, active = true }
		M.env.db.actor._pos = vec(31, 0, 0)
		tick(M)
		check(own._exploded == true, set .. ": host alone, his own character steps on a client's contact charge: it goes off")
	end
	check(M.env.coop_npc_players.error_count("world") == 0, set .. ": no errors reported")

	print("== " .. set .. ": a save with a client's charges, loaded with nobody joined")
	M, W, avatars = world(set)
	client_leaves(M, avatars)
	timer, contact = charge(M, 910, 50), charge(M, 911, 80)
	M.fire("load_state", { coop_npc_mines = {
		[910] = { exp = 60, mode = MODE_TIMER, planter = CLIENT_CHARACTER },
		[911] = { exp = 30, mode = MODE_PROX, planter = CLIENT_CHARACTER },
	} })
	M.game_ms = 61000
	tick(M)
	check((timer._exploded == true) == decides, set .. ": loaded timer charge past its time " .. fires)
	local monster = M.add(make_obj(301, 80, 0, 1, { _name = "monster" }))
	M.fire("monster_on_update", monster)
	check((contact._exploded == true) == decides, set .. ": a monster on the loaded contact charge: it " .. fires)
	check(M.env.coop_npc_players.error_count("world") == 0, set .. ": no errors reported")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
