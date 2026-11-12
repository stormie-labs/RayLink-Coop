-- Live 2026-11-12, the first test of the hidden world server: a Clear Sky base killed itself and shot the new loner in
-- its first minute, and no log said why (the world's save held neutral and friendly relations). coop_npc_why.script
-- says, where the AI runs, what an NPC holds against a player's character or a stalker of its own faction the first
-- time it has one for an enemy: one line per pair, a bounded number of lines, nothing changed.
-- Run: tools\test_lua.cmd npc_why
local CHECKS, FAILS = 0, 0
local function check(ok, what)
	CHECKS = CHECKS + 1
	if not ok then
		FAILS = FAILS + 1
		print("          FAIL " .. what)
	end
end

local LOGS = {}
printf = function(fmt, ...)
	local ok, line = pcall(string.format, fmt, ...)
	LOGS[#LOGS + 1] = ok and line or tostring(fmt)
end
local function lines_with(text)
	local n, last = 0, nil
	for _, l in ipairs(LOGS) do
		if l:find(text, 1, true) then n, last = n + 1, l end
	end
	return n, last
end

local NOW, HOST, CALLBACKS = 1000, true, {}
time_global = function() return NOW end
RegisterScriptCallback = function(name, f) CALLBACKS[name] = f end
coop = {} -- the engine namespace: an exe with co-op
local PLAYERS = { [900] = true }
coop_npc_players = {
	host_with_clients = function() return HOST end,
	is_proxy = function(id) return PLAYERS[id] == true end,
	report = function(tag, what, err) error(tostring(what) .. ": " .. tostring(err)) end,
}
local OBJ = {}
local PERSONAL, COMM_TO_HIM, COMM = {}, {}, { csky = { csky = 300, stalker = 0, bandit = -2000 } }
local function stalker(id, name, section, comm, squad)
	local o = { _id = id, _enemy = nil, _alive = true }
	function o:id() return id end
	function o:name() return name end
	function o:section() return section end
	function o:character_community() return comm end
	function o:alive() return self._alive end
	function o:best_enemy() return self._enemy end
	function o:goodwill(other) return PERSONAL[id .. ">" .. other:id()] or 0 end
	function o:general_goodwill(other)
		return self:goodwill(other) + (COMM_TO_HIM[comm .. ">" .. other:id()] or 0)
			+ ((COMM[comm] or {})[other:character_community()] or 0)
	end
	function o:relation(other) return self:general_goodwill(other) < -999 and 2 or 1 end
	o._squad = squad
	OBJ[id] = o
	return o
end
level = { object_by_id = function(id) return OBJ[id] end }
IsStalker = function(o) return o ~= nil and o._id ~= nil end
get_object_squad = function(npc) return npc._squad and { section_name = function() return npc._squad end } or nil end
relation_registry = {
	community_goodwill = function(comm, id) return COMM_TO_HIM[comm .. ">" .. id] or 0 end,
	community_relation = function(a, b) return (COMM[a] or {})[b] or 0 end,
}
db = { OnlineStalkers = {} }

local chunk = assert(loadfile("gamedata/scripts/coop_npc_why.script"))
local M = setmetatable({}, { __index = _G })
setfenv(chunk, M)
chunk()
M.on_game_start()
local update = CALLBACKS.actor_on_update
check(type(update) == "function", "the scan runs from the actor's update")
local function tick(ms)
	NOW = NOW + (ms or 1000)
	update()
end

print("-- nobody fights anybody: no line")
local guard = stalker(101, "sim_default_csky_3_101", "sim_default_csky_3", "csky", "csky_sim_squad_advanced")
local tech = stalker(102, "mar_base_stalker_tech", "mar_base_stalker_tech", "csky", nil)
local bandit = stalker(103, "bandit_1", "sim_default_bandit_1", "bandit", "bandit_squad")
local player = stalker(900, "coop_player_avatar900", "coop_player_avatar", "stalker", nil)
db.OnlineStalkers = { 101, 102, 103, 900 }
tick()
check(#LOGS == 0, "peace: nothing is written")

print("-- an enemy of another faction is the game's own business")
guard._enemy = bandit
tick()
check(#LOGS == 0, "Clear Sky against a bandit: no line")

print("-- an NPC has a player for an enemy: one line with what the attitude is made of")
PERSONAL["101>900"] = -1000
guard._enemy = player
tick()
local n, line = lines_with("[coop-npc:why] fights a player")
check(n == 1, "one line for the pair")
check(line ~= nil and line:find("sim_default_csky_3_101 [sim_default_csky_3] (101, csky, squad csky_sim_squad_advanced)", 1, true) ~= nil,
	"the NPC: name, section, id, faction, squad")
check(line ~= nil and line:find("coop_player_avatar900 [coop_player_avatar] (900, stalker) PLAYER", 1, true) ~= nil,
	"the enemy: name, section, id, faction, and that he is a player")
check(line ~= nil and line:find("relation 2, attitude -1000 = personal -1000 + his faction to him 0 + faction to faction 0", 1, true) ~= nil,
	"the parts: a forced personal goodwill is told from a faction's grudge and from the factions' relation")
tick() tick()
check(lines_with("[coop-npc:why]") == 1, "the same pair is not repeated")

print("-- a stalker fights its own faction")
COMM_TO_HIM["csky>101"] = -2000
tech._enemy = guard
tick()
n, line = lines_with("fights its own faction")
check(n == 1 and line:find("mar_base_stalker_tech [mar_base_stalker_tech] (102, csky, squad -)", 1, true) ~= nil,
	"a base NPC without a squad against a squad of its faction")
check(line ~= nil and line:find("personal 0 + his faction to him -2000 + faction to faction 300", 1, true) ~= nil
	and line:find("PLAYER", 1, true) == nil, "the faction's grudge against one of its own is seen as such")

print("-- the player's own character is nobody's subject, a dead NPC and a missing object are passed")
player._enemy = guard
guard._alive = false
db.OnlineStalkers = { 101, 102, 103, 900, 555 }
local before = #LOGS
tick()
check(#LOGS == before, "no new line")
guard._alive = true

print("-- only where the AI runs with a client in the session")
HOST = false
PERSONAL["103>900"] = -1000
bandit._enemy = player
tick()
check(lines_with("bandit_1") == 0, "a machine that does not lead the level writes nothing")
HOST = true
tick()
check(lines_with("bandit_1") == 1, "the authority does")

print("-- bounded: 60 lines per world, then one closing line")
for i = 1, 80 do
	local s = stalker(2000 + i, "npc_" .. i, "sim_default_csky_1", "csky", "sq")
	s._enemy = player
	PERSONAL[(2000 + i) .. ">900"] = -1000
	db.OnlineStalkers[#db.OnlineStalkers + 1] = 2000 + i
end
tick()
check(M._lines() == 60, "no more than 60 pairs are explained")
check(lines_with("60 lines written, no more in this world") == 1, "the end is said once")
before = #LOGS
tick() tick()
check(#LOGS == before, "and nothing after it")

print("-- a failing game object does not stop the scan")
M._reset()
LOGS = {}
local broken = stalker(3000, "broken", "s", "csky", nil)
broken.best_enemy = function() error("no such object") end
local angry = stalker(3001, "angry", "s", "csky", nil)
angry._enemy = player
PERSONAL["3001>900"] = -1000
db.OnlineStalkers = { 3000, 3001 }
tick()
check(lines_with("angry") == 1, "the NPC after a failing one is still looked at")

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
