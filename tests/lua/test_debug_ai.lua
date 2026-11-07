-- Anomaly Coop: the server's debug, work package 4 (docs\DEBUG_DESIGN.md B.9): a player with the personal flag "invisible" (4) is
-- nobody's enemy on the authority of his level. The engine leaves him out of every creature's memory there (coop_ai.cpp
-- npc_ai::debug_unseen, as the stock ai_ignore_actor) and answers coop.debug.unseen(id); here the stock xr_combat_ignore.is_enemy
-- (wrapped by coop_npc_combat) says "no enemy" for him, as the stock xrs_debug_tools.debug_invis does for the actor under DEV_DEBUG.
-- Loads the REAL stock xr_combat_ignore / xr_conditions (anomaly-ref) on a fake host + client, then coop_npc_players + coop_npc_combat.
-- Run: tools\test_lua.cmd debug_ai
dofile("tests/lua/support/harness_npc.lua")
local REF = "../anomaly-ref/unpacked/scripts/"

-- ---------------------------------------------------------------- the stock scripts on a fake engine (as test_npc_w11)
local function install_class(E)
	E.super = function() end
	E.class = function(name)
		local env = getfenv(2)
		local cls = {}
		cls.__index = cls
		setmetatable(cls, { __call = function(c, ...)
			local o = setmetatable({}, c)
			if c.__init then c.__init(o, ...) end
			return o
		end })
		env[name] = cls
		return function(base)
			if base then getmetatable(cls).__index = base end
		end
	end
end

local function load_stock(M, name)
	local fh = assert(io.open(REF .. name .. ".script", "r"))
	local src = fh:read("*a")
	fh:close()
	local header = "local this = {} " .. name .. " = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. src, "@" .. name .. ".script"))
	setfenv(f, M.env)
	f()
	return M.env[name]
end

local SQUADS = {}

local function setup(role)
	reset_world()
	NOW = 100000
	local M
	if role == "single" then
		M = machine("single", 0, {})
	elseif role == "client" then
		M = machine("client", 1, { [0] = 500, [1] = 0 })
	else
		M = machine("host", 0, { [0] = 0, [1] = 500 })
	end
	local E = M.env
	install_class(E)
	E.xr_logic = { pick_section_from_condlist = function() return nil end }
	E.coop_npc_players = load_script(M, "coop_npc_players")
	E.game_object = { friend = 0, neutral = 1, enemy = 2 }
	E.clsid = { crow = 99 }
	local a = E.db.actor
	a._rel = {}
	function a:clsid() return 1 end
	function a:critically_wounded() return false end
	function a:memory_time() return NOW end
	E.IsStalker = function(o) return o and o._monster ~= true end
	E.IsMonster = function(o) return o and o._monster == true end
	E.character_community = function(o) return o:character_community() end
	E.get_object_squad = function(o) return SQUADS[o:id()] end
	E.get_object_story_id = function() return nil end
	E.device = function() return { precache_frame = 0 } end
	E.alife = function() return { object = function(_, id) return { id = id, group_id = 65535 } end } end
	E.xr_gulag = { get_npc_smart = function() return nil end }
	E.axr_task_manager = { hostages_by_id = {} }
	E.utils_obj = { npc_in_zone = function() return false end }
	E.xr_bribe = nil
	E.xr_conditions = { surge_started = function() return false end }
	E.level.get_time_hours = function() return 12 end
	E.level.rain_factor = function() return 0 end
	E.xr_combat_ignore = load_stock(M, "xr_combat_ignore")
	E.xr_combat_ignore.on_game_start()
	return M
end

local function npc_obj(M, id, x, extra)
	local o = M.add(make_obj(id, x, 0, 0, extra))
	o._rel = o._rel or {}
	function o:clsid() return 1 end
	function o:critically_wounded() return self._crit == true end
	function o:memory_time() return NOW end
	return o
end

local function stalker_ready(M, npc)
	M.env.db.storage[npc:id()] = { object = npc }
	return M.env.db.storage[npc:id()]
end

local function start(M, name)
	local mod = load_script(M, name)
	M.env[name] = mod
	mod.on_game_start()
	return mod
end

-- The engine's answer: unseen[id] = true for a character the authority's AI leaves out (debug on, flag 4).
local function engine_debug(M, unseen)
	M.unseen_asked = 0
	M.env.coop.debug = {
		unseen = function(id)
			M.unseen_asked = M.unseen_asked + 1
			return unseen[id] == true
		end,
	}
end

-- ================================================================ host: a client's proxy and the host player's actor
print("== the host: an invisible player is no enemy, the others are as ever")
local H = setup("host")
local proxy = npc_obj(H, 500, 20, { _name = "coop_player_avatar500", _comm = "actor_stalker" })
local CB = start(H, "coop_npc_combat")
H.fire("actor_on_update")
local CI = H.env.xr_combat_ignore
local guard = npc_obj(H, 200, 10, { _name = "esc_bandit", _comm = "bandit" })
stalker_ready(H, guard)
guard._rel[500] = 2
guard._rel[0] = 2
local unseen = {}
engine_debug(H, unseen)

check(CI.is_enemy(guard, proxy) == true, "debug flag off: the hostile client is an enemy (as before)")
check(CI.is_enemy(guard, H.env.db.actor) == true, "debug flag off: the hostile host player is an enemy (stock)")
check(CB._state().fighting[200] and CB._state().fighting[200][500] == true, "the bandit fights the client")
check(H.unseen_asked >= 2, "the engine is asked about the enemy")

unseen[500] = true
check(CI.is_enemy(guard, proxy) == false, "the client with the flag invisible: no enemy")
check(CB._state().fighting[200] == nil, "...and the bandit fights him no more")
check(CI.is_enemy(guard, H.env.db.actor) == true, "the host player without the flag: still an enemy")

-- a grudge for a hit (stock xr_combat_ignore_enabled for the actor) ends as for the actor out of the enemies
local action = CI.action_process_enemy(guard, H.env.db.storage[200])
action:hit_callback(guard, 0.3, nil, proxy, 11)
check(CB._state().attacked[200] and CB._state().attacked[200][500] == true, "the client hit the bandit: a grudge")
check(CI.is_enemy(guard, proxy) == false, "invisible after a hit: still no enemy")
check(CB._state().attacked[200][500] == nil, "...and the grudge is gone")

-- the host player's actor goes through the stock enemy_callback: its bookkeeping of the actor ends too
unseen[500] = nil
unseen[0] = true
local cb = CI.action_process_enemy(guard, H.env.db.storage[200])
CI.fighting_with_actor_npcs[200] = true
check(cb:enemy_callback(guard, H.env.db.actor) == false, "the host player with the flag: the engine's enemy callback says no")
check(CI.fighting_with_actor_npcs[200] == nil, "...the stock forgets the fight with the actor")
check(CI.is_enemy(guard, proxy) == true, "the client without the flag: an enemy again")

-- a critically wounded NPC takes anybody for an enemy in the stock (before its debug_invis): not an invisible player
guard._crit = true
check(CI.is_enemy(guard, H.env.db.actor) == false, "critically wounded: the invisible player is still nobody")
check(CI.is_enemy(guard, proxy) == true, "critically wounded: the visible client is an enemy (stock)")
guard._crit = nil

-- no debug: the engine answers false for everybody
unseen[0] = nil
check(CI.is_enemy(guard, H.env.db.actor) == true and CI.is_enemy(guard, proxy) == true, "flag taken back: both are enemies again")

-- an exe without coop.debug (older engine): stock
H.env.coop.debug = nil
check(CI.is_enemy(guard, proxy) == true and CI.is_enemy(guard, H.env.db.actor) == true, "no coop.debug: as before")

-- the engine is asked about the enemy, not about the NPC that judges
engine_debug(H, { [200] = true })
check(CI.is_enemy(guard, proxy) == true, "the judging NPC's own id is not what is asked")

-- ================================================================ single player
print("== single player: stock")
local S = setup("single")
start(S, "coop_npc_combat")
S.fire("actor_on_update")
local sg = npc_obj(S, 300, 5, { _name = "g", _comm = "bandit" })
stalker_ready(S, sg)
sg._rel[0] = 2
engine_debug(S, {})
check(S.env.xr_combat_ignore.is_enemy(sg, S.env.db.actor) == true, "single player: the actor is an enemy (stock)")

print(string.format("\nRESULT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("tests failed") end
