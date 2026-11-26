-- A revive is what the engine reports: coop_actor_revived on the revived player's machine gives the listeners of
-- coop_mods_core one "actor_revived" with the reviver and the medkit. Health alone is not a revive: a medkit used at 2%
-- health and a respawn on the same actor both jump from near zero to well above it in one frame, and a revive event
-- there makes the BHS adapter end the player's concussion. coop_mods_core is Core: the same under every answer set of
-- the facade. Run as client (default) or host (test_mods_revive_host.lua).
local which = MODE_ARG or "client"
MODE = which
dofile("tests/lua/support/stubs_mods.lua")

LIFE = "alive"
coop.life_of = function(id) return id == 0 and LIFE or nil end

local actor = make_actor()
actor.health = 1
start_all()
local C = coop_mods_core
local modes = dofile("tests/lua/support/modes.lua")

local revived, respawned = {}, 0
C.listen("actor_revived", function(peer, section) revived[#revived + 1] = { peer = peer, section = section } end)
C.listen("actor_respawned", function() respawned = respawned + 1 end)

-- n frames of 100 ms at health h
local function frames(h, n)
	for _ = 1, n do
		actor.health = h
		NOW = NOW + 100
		SendScriptCallback("actor_on_update")
	end
end

print("== revive (" .. which .. ")")
for _, name in ipairs(modes.names()) do
	modes.install(coop_mode, name)
	local tag = which .. "/" .. name .. ": "

	-- 1. a medkit at 2% health: two seconds near zero, then 0.6 in one frame
	revived = {}
	NOW = NOW + 60000
	frames(1, 3)
	frames(0.02, 20)
	frames(0.6, 3)
	check(#revived == 0, tag .. "a medkit from 2% health is not a revive (" .. #revived .. " events)")

	-- 2. a respawn on the same actor: dead at health 0, then alive at 1
	revived, respawned = {}, 0
	NOW = NOW + 60000
	LIFE = "dead"
	frames(0, 20)
	LIFE = "alive"
	frames(1, 3)
	check(#revived == 0, tag .. "a respawn is not a revive (" .. #revived .. " events)")
	check(respawned == 1, tag .. "a respawn is one actor_respawned (" .. respawned .. ")")

	-- 3. a teammate's revive: down near zero, the engine lifts health and reports the revive from its frame queue
	revived = {}
	NOW = NOW + 60000
	LIFE = "wounded"
	frames(0.02, 20)
	LIFE = "alive"
	frames(0.3, 1)
	SendScriptCallback("coop_actor_revived", 1, "medkit")
	frames(0.3, 3)
	check(#revived == 1, tag .. "the engine's revive is one actor_revived (" .. #revived .. " events)")
	local ev = revived[1]
	check(ev ~= nil and ev.peer == 1 and ev.section == "medkit",
		tag .. "it names the reviver and the medkit (" .. tostring(ev and ev.peer) .. ", " .. tostring(ev and ev.section) .. ")")
end

check(C.stats.errors == 0, "no Lua errors (" .. C.stats.errors .. ")")
done("REVIVE " .. which:upper())
