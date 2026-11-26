-- Anomaly Coop (split levels, docs\SPLIT_LEVELS.md 7b): the emission on a map server. It follows the world server's phase like a client,
-- but it is the authority of its level: the stock kills stay on and the verdict on the players of its level is its own. Its ghost is
-- always in a shelter and no hide task is given to it.
-- Real coop_main and mode layers. Not shipped. Run: tools\test_lua.cmd env_map_server
MODE = "client" -- is_client() is true on a map server: for the world it is a client
dofile("tests/lua/support/stubs.lua")
local modes = dofile("tests/lua/support/modes.lua")

OPTS = { ["alife/event/emission_fate"] = "kill_at_wave", ["alife/event/psi_storm_fate"] = "kill_at_vortex" }
ui_options = { get = function(name) return OPTS[name] end }
vector = function()
	return { set = function(self, x, y, z) self.x, self.y, self.z = x, y, z; return self end }
end
level.name = function() return "l02_garbage" end
level_weathers = { valid_levels = { l02_garbage = true } }

coop.is_map_server = function() return true end
coop.is_mirror = function() return false end
coop.is_live = function() return true end
coop.levels = { split = function() return true end }
coop.players = function()
	return { { id = 0x101, nick = "ms", is_self = true, avatar_id = 0 }, { id = 2, nick = "far", is_self = false, avatar_id = 501 } }
end
SENT = {}
coop.send_event = function(name, payload, target)
	SENT[#SENT + 1] = { name = name, t = coop_main.decode(payload), to = target }
	return true
end
local function sent(name, to)
	for i = #SENT, 1, -1 do
		if SENT[i].name == name and SENT[i].to == to then return SENT[i].t end
	end
end

local KILLED = {}
local POS = { x = 0, y = 0, z = 0, cover = false }
OBJECTS = { [501] = { position = function() return POS end, alive = function() return true end } }
level.object_by_id = function(id) return OBJECTS[id] end

GIVEN_TASKS = 0
STOCK_KILLS, ZOMBIES = 0, 0
function CSurge:kill_objects_at_pos() STOCK_KILLS = STOCK_KILLS + 1 end
function CSurge:turn_to_zombie() ZOMBIES = ZOMBIES + 1 end
function CSurge:explode() end
function CSurge:give_surge_hide_task() GIVEN_TASKS = GIVEN_TASKS + 1 end
function CPsi:give_psi_storm_hide_task() GIVEN_TASKS = GIVEN_TASKS + 1 end
function CSurge:displayIndicators() INDICATORS = true end
local cover_seen = {}
function CSurge:kill_actor_at_pos() cover_seen[#cover_seen + 1] = GetEvent("current_safe_cover") end
function CSurge:update()
	self:kill_objects_at_pos(0, "kill_at_wave")
	self:turn_to_zombie()
	self:give_surge_hide_task()
	self:displayIndicators(1)
	self:kill_actor_at_pos(0)
end

print("== env_map_server")
load_coop_main()
load_script_file("coop_mode")
load_script_file("coop_trust")
load_script_file("coop_srv_world")
coop_main.on_game_start()
coop_env.on_game_start()
coop_route.on_game_start() -- the tick service runs the emission tick
modes.live(coop_mode)
coop_mode.on_game_start()
coop_srv_world.on_game_start()
local sm = surge_manager.get_surge_manager()
local function phase(t)
	coop_main.on_event("coop_env", coop_main.encode(t), 0)
	NOW = NOW + 1500
	SendScriptCallback("actor_on_update")
end

phase({ s = true, sg = 30, p = false, pg = 0, tf = 10, c = true })
check(sm.started == true, "the world server's phase starts the emission here: NPCs hide, zones hear it")
check(STOCK_KILLS == 1 and ZOMBIES == 1, "the stock consequences stay on: this process is the authority of its level")
check(GIVEN_TASKS == 0, "nobody here to give a hide task to")
check(not INDICATORS, "and no HUD to show")
check(cover_seen[1] == true, "its ghost is in a shelter: the stock never kills it")

-- the verdict on the players of its level is its own
local kill = sent("coop_env_kill", 2)
check(kill and kill.kind == "surge", "a player outside a shelter on its level is told so, by the map server")
check(sent("coop_env_kill", 0x101) == nil, "its ghost is nobody")
SENT = {}
phase({ s = true, sg = 40, p = false, pg = 0, tf = 10, c = true })
check(sent("coop_env_kill", 2) == nil, "once per emission")

-- a new emission, a player in a shelter by his own report through the world server
phase({ s = false, sg = 0, p = false, pg = 0, tf = 10, c = true })
check(sm.started == false, "the world server's phase ends it here")
coop_main.on_event("coop_env_cover", coop_main.encode({ c = true, peer = 2 }), 0)
SENT = {}
phase({ s = true, sg = 30, p = false, pg = 0, tf = 10, c = true })
coop_main.on_event("coop_env_cover", coop_main.encode({ c = true, peer = 2 }), 0)
NOW = NOW + 1500
SendScriptCallback("actor_on_update")
check(sent("coop_env_kill", 2) == nil, "his fresh report of a shelter spares him")

-- what he reports of his wave runs here
STOCK_KILLS = 0
coop_main.on_event("coop_env_npc_kill", coop_main.encode({ k = "s", z = 5, peer = 2 }), 0)
check(STOCK_KILLS == 1, "his wave kills the NPCs around him here")
coop_main.on_event("coop_env_npc_kill", coop_main.encode({ k = "s", z = 5, peer = 9 }), 0)
check(STOCK_KILLS == 1, "a player who is not on this level kills nobody")

print(string.format("%d passed, %d failed", PASSES, FAILS))
