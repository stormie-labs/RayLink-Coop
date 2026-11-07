-- A co-op respawn is a fresh body (live 2026-11-08: a G.A.M.M.A. player killed by psi stood at his respawn point with the
-- head and torso of the Body Health System red and his health going down, died again and again). The stock never respawns,
-- so the mods never reset what killed him: the BHS parts (head/torso at zero: the mod sets health to -1) and arszi_psy's psy
-- health (at or below 0.001 it sets health to 0 every in-game second). Every respawn (camp: coop_respawned; a new character
-- of a hardcore run and a lost callback: the life going from respawning/dead/spectating to alive) gives them back, in the
-- mod, in the pstor and in the per-player records; a teammate's revive keeps the damage. Run as client (default) or host.
local which = MODE_ARG or "client"
MODE = which
dofile("tests/lua/support/stubs_mods.lua")

local PARTS = { "head", "torso", "leftarm", "rightarm", "leftleg", "rightleg" }
local KEY = "coop_bhs_parts"

utils_obj = {
	save_var = function(o, k, v)
		local st = db.storage[o:id()]
		st.pstor = st.pstor or {}
		st.pstor[k] = v
	end,
	load_var = function(o, k, d)
		local st = db.storage[o:id()]
		local v = st and st.pstor and st.pstor[k]
		if v == nil then return d end
		return v
	end,
}

local function fake_bhs()
	local M = {
		maxhp = { head = 11, torso = 11, leftarm = 5, rightarm = 5, leftleg = 5, rightleg = 5 },
		health = {}, timedhp = {}, medkits = {},
	}
	for _, k in ipairs(PARTS) do
		M.health[k] = M.maxhp[k]
		M.timedhp[k] = 0
	end
	local init = false
	function M.actor_on_update()
		if init then return end
		for _, k in ipairs(PARTS) do
			M.health[k] = utils_obj.load_var(db.actor, "health." .. k) or M.maxhp[k]
			M.timedhp[k] = utils_obj.load_var(db.actor, "timedhp." .. k) or 0
		end
		init = true
	end
	function M.reset() init = false end
	return M
end

-- arszi_psy's shape: a file-local psy table behind a getter and a setter (the setter caps at 1, not below 0).
local function fake_psy()
	local psy = { health = 1, loads = 0, ppe_removed = 0 }
	return {
		get_psy_health = function() return psy.health end,
		set_psy_health = function(v) psy.health = v < 1 and v or 1 end,
		on_game_load = function() psy.loads = psy.loads + 1 end,
		remove_all_psy_ppe_effects = function() psy.ppe_removed = psy.ppe_removed + 1 end,
		_psy = psy,
	}
end

local LOGS = {}
local base_printf = printf
printf = function(fmt, ...)
	local ok, line = pcall(string.format, fmt, ...)
	LOGS[#LOGS + 1] = ok and line or tostring(fmt)
	if base_printf then return base_printf(fmt, ...) end
end
local function logged(pat)
	for i = #LOGS, 1, -1 do if LOGS[i]:find(pat) then return LOGS[i] end end
	return nil
end

local KEYS_PUSHED = 0
coop_economy_mdata = { send_player_keys = function() KEYS_PUSHED = KEYS_PUSHED + 1 end }

LIFE = "alive"
coop.life_of = function(id) return id == 0 and LIFE or nil end

zzz_player_injuries = fake_bhs()
arszi_psy = fake_psy()
local B, A = zzz_player_injuries, arszi_psy
local actor = make_actor()
actor.psy_health, actor.radiation, actor.bleeding = 0.2, 0, 0
start_all()
db.storage[0] = db.storage[0] or {}
db.storage[0].pstor = db.storage[0].pstor or {}
SendScriptCallback("actor_on_first_update")
B.actor_on_update()
SendScriptCallback("actor_on_update")

local function hurt()
	B.health.head, B.health.torso, B.health.leftleg, B.health.rightarm = 0, 0, 2, 3
	B.timedhp.leftleg, B.timedhp.rightarm = 1, 2
	utils_obj.save_var(db.actor, "health.head", 0)
	utils_obj.save_var(db.actor, "health.torso", 0)
	A.set_psy_health(-0.6)
	NOW = NOW + 1500
	SendScriptCallback("actor_on_update") -- a client reports the hurt parts within a second: the host's record is the dead body
end

local function whole(what)
	local ok = true
	for _, k in ipairs(PARTS) do
		ok = ok and B.health[k] == B.maxhp[k] and B.timedhp[k] == 0
			and db.storage[0].pstor["health." .. k] == B.maxhp[k] and db.storage[0].pstor["timedhp." .. k] == 0
	end
	check(ok, what)
end

local function fresh_count() return coop_mods_misc._fresh_count() end

print("== respawn (" .. which .. ")")

-- 1. psi killed him at his camp: the camp respawn (the engine's coop_respawned) gives every part and the psy health back
hurt()
NOW = NOW + 60000
SENT = {}
KEYS_PUSHED = 0
SendScriptCallback("coop_respawned", "campfire", 60, 10, 0, 1)
whole("camp respawn: every BHS part whole, timed healing gone, in the mod and in the pstor")
check(A.get_psy_health() == 1, "camp respawn: arszi psy health back to 1 (was -0.6: dead again every in-game second)")
check(A._psy.loads >= 1 and A._psy.ppe_removed >= 1, "camp respawn: arszi stage reset and its psy effects removed")
check(fresh_count() == 1, "one fresh body for one respawn")
local line = logged("fresh body: before")
check(line and line:find("arszi %-0%.600", 1) and line:find("head/torso 0/0", 1) and line:find("after .*arszi 1%.000")
	and line:find("after .*head/torso 11/11") and line:find("radiation") and line:find("bleeding"),
	"the respawn's log line: health, psy, radiation, bleeding, head/torso before and after (" .. tostring(line) .. ")")
if which == "client" then
	local piece = sent("mods.pd")
	local d = piece and coop_mods_core.deser(piece.d)
	local rec = d and d[KEY]
	check(rec and rec.h.head == 11 and rec.h.torso == 11 and rec.t.leftleg == 0,
		"client: the whole parts go to the host at once (a level change right after must not bring the dead ones back)")
	check(KEYS_PUSHED >= 1, "client: the psy table goes to the host at once (not in 15 s)")
else
	check(sent("mods.pd") == nil, "host: nothing to report, the parts are in its own save")
end

-- 2. the same fall's order again (RTT window): nothing more
SendScriptCallback("coop_respawned", "campfire", 60, 10, 0, 1)
check(fresh_count() == 1, "a repeated order of the same respawn is not a second fresh body")

-- 3. a teammate's revive is NOT a respawn: the damage stays (only head/torso are lifted off zero by the revive itself)
NOW = NOW + 60000
hurt()
LIFE = "wounded"
SendScriptCallback("actor_on_update")
LIFE = "alive"
SendScriptCallback("coop_actor_revived", 1, nil)
SendScriptCallback("actor_on_update")
check(B.health.leftleg == 2 and B.health.rightarm == 3 and B.timedhp.rightarm == 2, "revive: the limbs keep their damage")
check(B.health.head == 1 and B.health.torso == 1, "revive: head and torso just above zero (the revive's own rule)")
check(A.get_psy_health() == -0.6, "revive: the psy health is not this file's to reset")
check(fresh_count() == 1, "revive: no fresh body")

-- 4. a new character after a hardcore run (no coop_respawned): the life goes respawning -> alive
NOW = NOW + 60000
hurt()
LIFE = "spectating"
SendScriptCallback("actor_on_update")
LIFE = "respawning"
SendScriptCallback("actor_on_update")
LIFE = "alive"
SendScriptCallback("actor_on_update")
whole("new character: every part whole")
check(A.get_psy_health() == 1, "new character: psy health 1")
check(fresh_count() == 2, "new character: one fresh body")
-- the engine's coop_respawned right behind the poll (a camp respawn seen by both): once
SendScriptCallback("coop_respawned", "campfire", 60, 10, 0, 2)
check(fresh_count() == 2, "poll and callback of the same respawn: one fresh body")

-- 5. a camp respawn whose callback was lost (the engine's queue is bounded): dead -> alive
NOW = NOW + 60000
hurt()
LIFE = "dead"
SendScriptCallback("actor_on_update")
LIFE = "alive"
SendScriptCallback("actor_on_update")
whole("lost callback: the life poll gives every part back")
check(fresh_count() == 3, "lost callback: one fresh body")

if which == "client" then
	-- 6. the respawn crossed a world change: the new world's load brought his record from before (dead parts); the order
	-- comes before the actor's first update: the record must not put the dead parts back afterwards
	NOW = NOW + 60000
	local m = { coop_mods_pdata = { ["500"] = { t = "T9", d = { [KEY] = {
		h = { head = 0, torso = 0, leftarm = 5, rightarm = 5, leftleg = 1, rightleg = 5 }, t = {} } } } } }
	STASH = {}
	alife_storage_manager.CALifeStorageManager_load(m)
	db.storage[0].pstor = { ["health.head"] = 11 }
	B.reset()
	SendScriptCallback("coop_respawned", "campfire", 60, 10, 0, 1)
	SendScriptCallback("actor_on_first_update")
	B.actor_on_update()
	SendScriptCallback("actor_on_update")
	whole("respawn before the first update of a new world: whole, not the record from before the death")
end

coop_main.print_status()
check(coop_mods_core.stats.errors == 0, "no Lua errors (" .. coop_mods_core.stats.errors .. ")")
done("RESPAWN " .. which:upper())
