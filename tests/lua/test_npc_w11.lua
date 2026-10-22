-- Anomaly Coop W11 temp test: every player is a real participant for the NPC AI (Lua side).
-- Loads the REAL stock xr_conditions / xr_combat_ignore / xr_meet (anomaly-ref) on a fake host + client, then
-- coop_npc_players + coop_npc_combat + coop_npc_meet, and checks what NPCs do about a client's proxy.
-- Run: tools\test_lua.cmd npc_w11
dofile("tests/lua/support/harness_npc.lua")
local REF = "../anomaly-ref/unpacked/scripts/"

-- ---------------------------------------------------------------- mini luabind class + xr_logic condlists
local function install_class(E)
	E.super = function() end
	E.property_evaluator = { evaluate = function() return false end }
	E.action_base = { execute = function() end, initialize = function() end, finalize = function() end }
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

-- "{=a !b =c(1:2)} x, {=d} y, z" -> { {checks = {{name, want, params}}, section = "x"}, ... }
local function parse_condlist(str)
	local list = {}
	for part in (tostring(str) .. ","):gmatch("%s*([^,]*),") do
		local conds, rest = part:match("^{([^}]*)}%s*(.*)$")
		local item = { checks = {}, section = (conds and rest or part):gsub("^%s+", ""):gsub("%s+$", "") }
		for sign, name, params in (conds or ""):gmatch("([=!])([%w_]+)%(?([^%s%)]*)%)?") do
			local p = {}
			for v in params:gmatch("[^:]+") do p[#p + 1] = v end
			item.checks[#item.checks + 1] = { name = name, want = sign == "=", params = p }
		end
		list[#list + 1] = item
	end
	return list
end

local function install_logic(M)
	local E = M.env
	local xl = E.xr_logic or {}
	E.xr_logic = xl
	xl.parse_condlist = function(npc, sec, key, str) return parse_condlist(str) end
	xl.pick_section_from_condlist = function(actor, npc, condlist)
		for _, c in ipairs(condlist or {}) do
			local ok = true
			for _, ch in ipairs(c.checks or {}) do
				local f = E.xr_conditions[ch.name]
				assert(f, "no condition " .. ch.name)
				if (f(actor, npc, ch.params) and true or false) ~= ch.want then ok = false break end
			end
			if ok then return c.section end
		end
		return nil
	end
	xl.subscribe_action_for_events = function() end
	xl.issue_event = function() end
end

-- ini with r_string_to_condlist (meet sections)
local function meet_ini(t)
	local ini = make_ini(t)
	function ini:r_string_to_condlist(s, k, def)
		local v = self:r_string_ex(s, k)
		return parse_condlist(v or def)
	end
	return ini
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

-- ---------------------------------------------------------------- world
local SQUADS = {}
local function squad_of(o) return SQUADS[o:id()] end

local function setup(role_single)
	reset_world()
	NOW = 100000
	local H, C
	if role_single then
		H = machine("single", 0, {})
	else
		H = machine("host", 0, { [0] = 0, [1] = 500 })
		C = machine("client", 1, { [0] = 500, [1] = 0 })
		local function swap(id) if id == 0 then return 500 elseif id == 500 then return 0 end return id end
		C.to_host, C.to_local = swap, swap
	end
	for _, M in ipairs({ H, C }) do
		local E = M.env
		install_class(E)
		install_logic(M)
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
		E.IsWounded = function(o) return o._wounded == true end
		E.IsWeapon = function(o) return o and o._weapon == true end
		E.character_community = function(o) return o:character_community() end
		E.get_object_squad = squad_of
		E.get_object_story_id = function() return nil end
		E.get_story_object = function(s) if s == "actor" then return E.db.actor end end
		E.device = function() return { precache_frame = 0 } end
		E.alife = function() return { object = function(_, id) return { id = id, group_id = SQUADS[id] and SQUADS[id].id or 65535 } end,
			has_info = function() return false end, actor = function() return { id = 0 } end } end
		E.xr_gulag = { get_npc_smart = function() return nil end }
		E.axr_task_manager = { hostages_by_id = {} }
		E.utils_obj = { npc_in_zone = function() return false end, get_current_action_id = function() return 0 end }
		E.xr_actions_id = { animpoint_action = 100, stohe_meet_base = 200, alife = 1, state_mgr = 300 }
		E.xr_evaluators_id = { stohe_meet_base = 200 }
		E.xr_wounded = { is_wounded = function(o) return o._wounded == true end }
		E.xr_bribe = nil
		E.xr_abuse = { enable_abuse = function() end, disable_abuse = function() end }
		E.state_mgr = {
			is_npc_in_combat = function() return false end,
			get_state = function() return "idle" end,
			set_state = function(npc, state, a, b, ex) M.states = M.states or {}; M.states[#M.states + 1] = { npc = npc:id(), state = state, look = ex and ex.look_object and ex.look_object:id() } end,
		}
		E.xr_sound = { set_sound_play = function(id, snd) M.sounds = M.sounds or {}; M.sounds[#M.sounds + 1] = { id = id, snd = snd } end }
		E.level.get_time_hours = function() return 12 end
		E.level.rain_factor = function() return 0 end
		E.game_relations = {
			is_factions_enemies = function(a, b) return (M.fenemies or {})[a .. "/" .. b] == true end,
			get_npcs_relation = function(a, b) return a:relation(b) end,
		}
		E.game.actor_weapon_lowered = function() return true end
		E.time_global = function() return NOW end
		E.xr_conditions = load_stock(M, "xr_conditions")
		E.xr_combat_ignore = load_stock(M, "xr_combat_ignore")
		E.xr_meet = load_stock(M, "xr_meet")
		E.xr_danger = { set_script_danger = function(npc, t, who_id, pos) M.dangers = M.dangers or {}; M.dangers[#M.dangers + 1] = { npc = npc:id(), who = who_id } end }
		E.xr_combat_ignore.on_game_start()
		E.task_manager = { get_task_manager = function() return { task_info = {} } end }
		E.tasks_delivery = { is_delivery_task = function() return false end }
		E.xr_corpse_detection = { is_under_corpse_detection = function() return false end }
		E.xr_help_wounded = { is_under_help_wounded = function() return false end }
	end
	return H, C
end

-- extra game object methods the stock scripts use
local function npc_obj(M, id, x, extra)
	local o = M.add(make_obj(id, x, 0, 0, extra))
	o._rel = o._rel or {}
	function o:clsid() return 1 end
	function o:critically_wounded() return false end
	function o:memory_time() return NOW end
	function o:allow_break_talk_dialog() end
	function o:force_set_goodwill(v, who) self._rel[who:id()] = v <= -1000 and 2 or 1; self._forced = (self._forced or 0) + 1 end
	return o
end

local function stalker_ready(M, npc, logic)
	M.env.db.storage[npc:id()] = { object = npc, ini = meet_ini(logic or {}), overrides = nil }
	return M.env.db.storage[npc:id()]
end

local function start(M, name)
	local mod = load_script(M, name)
	M.env[name] = mod
	mod.on_game_start()
	return mod
end

-- ================================================================ combat
print("== coop_npc_combat: combat_ignore, conditions and hits treat a client's character like the actor")
local H, C = setup()
local proxy = npc_obj(H, 500, 20, { _name = "coop_player_avatar500", _comm = "actor_stalker" })
local CB = start(H, "coop_npc_combat")
start(C, "coop_npc_combat")
H.fire("actor_on_update")
local guard = npc_obj(H, 200, 10, { _name = "esc_village_guard", _comm = "stalker" })
local st = stalker_ready(H, guard)
-- the most common stock combat_ignore_cond of base NPCs (326 sections): fight only the actor if he is an enemy
st.overrides = { combat_ignore = { condlist = parse_condlist("{=actor_enemy =check_enemy_name(actor)} false, true") } }
st.combat_ignore = {}
local XC, CI = H.env.xr_conditions, H.env.xr_combat_ignore

guard._rel[500] = 1 -- neutral to the client
check(CI.is_enemy(guard, proxy) == false, "neutral client: ignored (as the neutral actor)")
guard._rel[500] = 2 -- the client is an enemy now
check(XC.check_enemy_name(proxy, guard, { "actor" }) == true, "check_enemy_name(actor) is true for a client's character")
check(XC.check_enemy_name(proxy, guard, { "sim_default" }) == false, "...and not for other names")
check(CI.is_enemy(guard, proxy) == true, "hostile client: fought despite combat_ignore_cond (was: ignored as a non-actor)")
check(st.enemy_id == 500, "pure enemy stored like for the actor")
check(XC.is_enemy_actor(proxy, guard) == true, "is_enemy_actor: client's character")
check(XC.is_enemy_actor_or_companion(proxy, guard) == true, "is_enemy_actor_or_companion: hostile client")
check(XC.is_enemy_fighting_actor(guard, nil) == true, "is_enemy_fighting_actor: the guard fights a player")

-- a hit by the client turns combat_ignore off against him (stock: only for hits by the actor)
local guard2 = npc_obj(H, 201, 12, { _name = "esc_trader_guard", _comm = "stalker" })
local st2 = stalker_ready(H, guard2)
st2.overrides = { combat_ignore = { condlist = parse_condlist("true") } } -- always ignore
st2.combat_ignore = {}
guard2._rel[500] = 1
check(CI.is_enemy(guard2, proxy) == false, "combat_ignore_cond = true: client ignored before any hit")
SQUADS[201] = { id = 900, commander_id = function() return 201 end }
SQUADS[202] = SQUADS[201]
SQUADS[201].squad_members = function(self)
	local list, i = { 201, 202 }, 0
	return function() i = i + 1; if list[i] then return { id = list[i] } end end
end
local mate = npc_obj(H, 202, 13, { _name = "esc_trader_guard2", _comm = "stalker" })
local st3 = stalker_ready(H, mate)
st3.overrides = { combat_ignore = { condlist = parse_condlist("true") } }
local action = H.env.xr_combat_ignore.action_process_enemy(guard2, st2)
action:hit_callback(guard2, 0.3, nil, proxy, 11)
check(CI.is_enemy(guard2, proxy) == true, "after the client's hit: the guard fights him")
check(CI.is_enemy(mate, proxy) == true, "...and his squad mate too")
check(CI.is_enemy(guard2, H.env.db.actor) == false, "the host's actor stays ignored (he did not shoot)")

-- conditions asked about the host's actor answer for every player (story triggers)
H.env.db.storage[201].hit = { who = 500 }
check(XC.hit_by_actor(H.env.db.actor, guard2) == true, "hit_by_actor: hit by a client")
H.env.db.storage[201].death = { killer = 500 }
check(XC.killed_by_actor(H.env.db.actor, guard2) == true, "killed_by_actor: killed by a client")
guard2._enemy = proxy
check(XC.has_actor_enemy(H.env.db.actor, guard2) == true, "has_actor_enemy: best enemy is a client")
st2.enemy_id = 500
check(XC.fighting_actor(H.env.db.actor, guard2) == true, "fighting_actor: fights a client")

-- danger: a client's shot hitting near a friendly NPC alarms it like the actor's would
local friend = npc_obj(H, 203, 30, { _name = "loner", _comm = "stalker" })
stalker_ready(H, friend)
H.env.db.storage[500] = { object = proxy }
friend._rel[500] = 0
H.fire("npc_on_hear_callback", friend, 500, "WPN_hit", 100, 1, vec(30, 0, 1))
check(H.dangers and #H.dangers == 1 and H.dangers[1].who == 500, "friendly NPC alarmed by a client's hit nearby")
H.fire("npc_on_hear_callback", friend, 500, "WPN_shoot", 100, 1, vec(30, 0, 1))
check(#H.dangers == 1, "...not by a plain shot sound (stock: hits and attacks only)")

-- killing a squad mate in front of them makes the squad hostile to that player
mate._sees[500] = true
guard2._alive = false
H.fire("npc_on_death_callback", guard2, proxy)
check(mate._rel[500] == 2, "squad mate that saw the client kill turns hostile to him")
check(friend._forced == nil, "an NPC of another squad is untouched")

-- wounded NPC calls the player it sees
local wnd_called = {}
H.env.xr_wounded.Cwound_manager = { process_hp_wound = function(self, hp)
	wnd_called[#wnd_called + 1] = H.env.db.actor:id()
	return "a", "b"
end }
CB._install_wounded()
local wnpc = npc_obj(H, 204, 22, { _name = "wounded" })
wnpc._sees[500] = true
H.env.xr_wounded.Cwound_manager.process_hp_wound({ npc = wnpc }, 0.1)
check(wnd_called[1] == 500, "wounded NPC that sees only the client asks him (db.actor = his character inside)")
check(H.env.db.actor:id() == 0, "db.actor restored")
wnpc._sees[0] = true
H.env.xr_wounded.Cwound_manager.process_hp_wound({ npc = wnpc }, 0.1)
check(wnd_called[2] == 0, "sees the host's actor: stock")

-- single player / no clients: stock
local S = setup(true)
local CBs = start(S, "coop_npc_combat")
S.fire("actor_on_update")
local sp = npc_obj(S, 300, 5, { _name = "coop_player_avatar300" })
local g = npc_obj(S, 301, 6, { _name = "g" })
local sst = stalker_ready(S, g)
sst.overrides = { combat_ignore = { condlist = parse_condlist("{=actor_enemy =check_enemy_name(actor)} false, true") } }
g._rel[300] = 2
check(S.env.xr_combat_ignore.is_enemy(g, sp) == false, "single player: stock (a non-actor stalker is ignored)")
check(S.env.xr_conditions.check_enemy_name(sp, g, { "actor" }) == false, "single player: stock check_enemy_name")

-- ================================================================ meet
print("== coop_npc_meet: NPCs meet, greet and stop for a client")
H, C = setup()
proxy = npc_obj(H, 500, 1.5, { _name = "coop_player_avatar500", _comm = "actor_stalker" })
start(H, "coop_npc_combat")
local MH = start(H, "coop_npc_meet")
start(C, "coop_npc_meet")
H.fire("actor_on_update")
H.env.db.actor._pos = vec(50, 0, 0) -- the host is far away
local function meet_npc(id, x, comm)
	local npc = npc_obj(H, id, x, { _name = "npc" .. id, _comm = comm or "stalker" })
	local s = stalker_ready(H, npc, { meet_sec = {} })
	s.meet = {}
	s.meet.meet_manager = H.env.xr_meet.Cmeet_manager(npc, s.meet)
	return npc, s
end
local commander, cst = meet_npc(210, 0)
commander._sees[500] = true
proxy._pos = vec(40, 0, 0) -- far away when the scheme starts (stock: no greeting for who is already there)
H.env.xr_meet.init_meet(commander, cst.ini, "meet_sec", cst.meet, nil)
local mm = cst.meet.meet_manager
proxy._pos = vec(1.5, 0, 0) -- walks up to him
NOW = NOW + 1000
mm:update()
local greeted = false
for _, s in ipairs(H.sounds or {}) do if s.id == 210 and (s.snd == "meet_hello" or s.snd == "meet_stop") then greeted = true end end
check(greeted, "squad commander greets the client standing 1.5 m in front of him")
check(mm.current_distance == "close" and mm.coop_focus == 500, "...and meets him (stops, focus = the client)")
H.states = {}
mm:update_state()
check(H.states[1] and H.states[1].look == 500, "...turns to the client (look_object = his character)")

-- the host is an enemy of the NPC's faction, the client is not: the client still gets the friendly meet
H, C = setup()
proxy = npc_obj(H, 500, 1.5, { _name = "coop_player_avatar500", _comm = "actor_stalker" })
start(H, "coop_npc_combat")
MH = start(H, "coop_npc_meet")
H.fire("actor_on_update")
H.env.db.actor._comm = "actor_bandit"
H.env.db.actor._pos = vec(50, 0, 0)
H.fenemies = { ["bandit/stalker"] = true }
commander, cst = meet_npc(211, 0)
commander._sees[500] = true
H.env.xr_meet.init_meet(commander, cst.ini, "meet_sec", cst.meet, nil)
mm = cst.meet.meet_manager
NOW = NOW + 1000
H.sounds = {}
mm:update()
check(mm.current_distance == "close" and mm.coop_focus == 500, "host bandit, client loner: the loner commander meets the client")

-- a client talking to the NPC (talk lock on the host) keeps it standing and facing him
H, C = setup()
proxy = npc_obj(H, 500, 6, { _name = "coop_player_avatar500", _comm = "actor_stalker" })
start(H, "coop_npc_combat")
MH = start(H, "coop_npc_meet")
H.fire("actor_on_update")
H.env.db.actor._pos = vec(50, 0, 0)
local trader, tst = meet_npc(212, 0)
trader._sees[500] = true
H.env.xr_meet.init_meet(trader, tst.ini, "meet_sec", tst.meet, nil)
mm = tst.meet.meet_manager
NOW = NOW + 1000
mm:update()
check(mm.current_distance == nil, "client 6 m away: no meet")
H.env.coop.talk_holder = function(id) if id == 212 then return 1 end end
NOW = NOW + 1000
mm:update()
check(mm.current_distance == "close" and mm.coop_focus == 500, "client talks to it: meet 'close' with focus on the client")
H.states = {}
mm:update_state()
check(H.states[1] and H.states[1].look == 500, "...faces the client while he talks")

print(string.format("\nRESULT: %d passed, %d failed", PASSES, FAILS))
