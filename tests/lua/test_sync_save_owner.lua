-- Anomaly Coop: who keeps coop.sync in its save (gamedata\scripts\coop_sync.script). The process that decides the world,
-- and a game without a session, save it, load it and clear it for a new world; a client of the world (a player's machine,
-- a map server) keeps only what the decider sends. The script asks the session and the facade (coop_util.active,
-- coop_mode.decides_world). Each row below is one process in one phase with the engine's own answer for it:
-- coop.is_client() is the role WorldClient, which client_roles() and map_server_roles() have and host_roles() and
-- dedicated_roles() have not (xrCoop\coop_roles.h); a process has its roles from the start of its session to its end and
-- none outside it (Manager::set_phase). The script must skip exactly where the engine says "a client of the world".
-- coop_sync is Core: every answer set of the facade coop_mode has its rows (docs\MODES.md section 4).
-- Not shipped. Run: tools\test_lua.cmd sync_save_owner
MODE = "host"
dofile("tests/lua/support/stubs.lua")
local modes = dofile("tests/lua/support/modes.lua")
AddScriptCallback("save_state") -- the stock axr_main has it; the stub knows only a few callbacks
local facade = load_script_file("coop_mode")

-- a player's machine: the layer of its session answers "a mirror that decides nothing"
local PLAYER = { decides_world = function() return false end, leads_here = function() return false end,
	is_player_mirror = function() return true end }

-- set -> { the process and its phase, a session is running, the engine calls it a client of the world, layer overrides }
local ROWS = {
	hostplay = {
		{ "the host's game before it starts a session", false, false },
		{ "the co-op host", true, false },
		{ "a co-op player's machine", true, true, PLAYER },
	},
	srv_world = {
		{ "the world server loading its world, before its session", false, false },
		{ "the world server", true, false },
	},
	srv_map = {
		{ "a map server before its session starts", false, false },
		{ "a map server", true, true },
		{ "a player's machine of a server world", true, true, PLAYER },
	},
	none = {
		{ "single player", false, false },
		{ "a joining player's machine no layer answers for yet", true, true },
	},
}

local calls
local role_asked = 0
coop.sync = {
	export = function()
		calls.exported = calls.exported + 1
		return { scopes = 0 }
	end,
	import = function(saved)
		if saved == nil then calls.cleared = calls.cleared + 1 else calls.loaded = calls.loaded + 1 end
		return true
	end,
}
coop.saving_for_join = function() return false end
local shim = load_script_file("coop_sync")

for _, set in ipairs(modes.names()) do
	print("== sync_save_owner " .. set)
	for _, row in ipairs(ROWS[set]) do
		local what, active, client = row[1], row[2], row[3]
		modes.install(facade, set, row[4])
		coop.is_active = function() return active end
		coop.is_client = function()
			role_asked = role_asked + 1
			return client
		end
		local keeps = client and 0 or 1 -- a client of the world keeps nothing in its save

		calls = { exported = 0, cleared = 0, loaded = 0 }
		shim.on_game_start()
		check(calls.cleared == keeps and calls.loaded == 0, set .. ": " .. what .. ": on_game_start "
			.. (client and "leaves the decider's copy alone" or "starts an empty world"))

		SendScriptCallback("load_state", { coop_sync = { scopes = 1 } })
		check(calls.loaded == keeps and calls.cleared == keeps, set .. ": " .. what .. ": load_state "
			.. (client and "imports nothing" or "imports the save's coop.sync"))

		local m_data = {}
		SendScriptCallback("save_state", m_data)
		check(calls.exported == keeps and (m_data.coop_sync ~= nil) == not client, set .. ": " .. what .. ": save_state "
			.. (client and "leaves m_data alone" or "puts coop.sync into the save"))
	end
end
check(role_asked == 0, "the script asks the facade and the session, never the engine's client role")

print(string.format("%d passed, %d failed", PASSES, FAILS))
