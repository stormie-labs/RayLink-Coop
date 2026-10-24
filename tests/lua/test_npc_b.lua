-- Anomaly Coop W4 "npc" temp test B: coop_npc_meet, _companions, _disguise, _world, _compat on a fake host + client.
-- Run: tools\test_lua.cmd npc_b
dofile("tests/lua/support/harness_npc.lua")

local function pair()
	reset_world()
	local H = machine("host", 0, { [0] = 0, [1] = 500 })
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	local function swap(id) if id == 0 then return 500 elseif id == 500 then return 0 end return id end
	C.to_host, C.to_local = swap, swap
	for _, M in ipairs({ H, C }) do
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
	end
	local proxy = H.add(make_obj(500, 10, 0, 0, { _name = "proxy1" }))
	local hav = C.add(make_obj(500, 0, 0, 0, { _name = "host_avatar" }))
	return H, C, proxy, hav
end

local function common(M)
	local E = M.env
	E.xr_logic = {
		pick_section_from_condlist = function(actor, npc, condlist)
			for _, c in ipairs(condlist or {}) do
				if not c.cond or c.cond(actor, npc) then return c.section end
			end
		end,
		parse_func_params = function(s) local t = {} for p in s:gmatch("[^:]+") do t[#t + 1] = tonumber(p) or p end return t end,
	}
	E.character_community = function(o) return o:character_community() end
	E.game_relations = {
		is_factions_enemies = function(a, b) return (M.enemies or {})[a .. "/" .. b] == true end,
		is_faction_unaffected = function() return false end,
		is_faction_pair_unaffected = function() return false end,
		change_faction_relations = function(a, b, v) M.rel_hits = (M.rel_hits or 0) + 1 end,
		change_factions_community_num = function(a, b, v) M.goodwill_hits = (M.goodwill_hits or 0) + 1 end,
	}
	E.game_object = { enemy = 2, friend = 0, neutral = 1 }
	E.IsWounded = function(o) return o._wounded == true end
	E.IsWeapon = function(o) return o and o._weapon == true end
	E.xr_corpse_detection = { is_under_corpse_detection = function() return false end }
	E.xr_help_wounded = { is_under_help_wounded = function() return false end }
	E.task_manager = { get_task_manager = function() return { task_info = {} } end }
	E.tasks_delivery = { is_delivery_task = function() return false end }
	E.state_mgr = { is_npc_in_combat = function() return false end, set_state = function() end, get_state = function() return "idle" end }
	E.xr_sound = { set_sound_play = function(id, snd) M.voices = (M.voices or 0) + 1 end }
end

print("== coop_npc_meet: talk flags per client, wounded state, help-wounded")
local H, C, proxy, hav = pair()
common(H)
common(C)
local function meet_stock(M)
	local E = M.env
	local cm = {}
	E.xr_meet = {
		Cmeet_manager = { update = function() end, update_state = function() end, set_start_distance = function() end },
		evaluator_contact = { evaluate = function() return false end },
		action_meet_wait = { execute = function() end },
		process_npc_usability = function(npc) M.stock_usability = (M.stock_usability or 0) + 1 end,
	}
	E.xr_conditions = { actor_is_safemode = function() return "stock" end }
	E.xr_wounded = { unlock_medkit = function(npc) M.unlocked = npc:id() end }
	E.dialogs = {
		who_is_npc = function(a, b) return a:id() == 0 and b or a end,
		transfer_medkit = function(a, b) M.stock_medkit = true end,
		transfer_bandage = function(a, b) M.stock_bandage = true end,
	}
end
meet_stock(H)
meet_stock(C)
local MH = load_script(H, "coop_npc_meet")
local MC = load_script(C, "coop_npc_meet")
MH.on_game_start()
MC.on_game_start()
H.fire("actor_on_update")
local npc = H.add(make_obj(200, 15, 0, 0, { _name = "trader" }))
local puppet = C.add(make_obj(200, 15, 0, 0, { _name = "trader" }))
local use_true = { { section = "true" } }
H.env.db.storage[200] = { meet = { meet_manager = { a = { use = use_true, trade_enable = use_true, meet_section = "nil" } } } }
NOW = NOW + 1
QUEUE, H.sent = {}, {}
H.env.xr_meet.process_npc_usability(npc)
check(H.stock_usability == 1, "stock usability still runs for the host's player")
check(#sent_named(H, "npc.talk") == 1, "talk flags sent to the client near the NPC")
pump()
check(puppet._talk == true and puppet._trade == true and puppet._tip == "character_use", "client puppet: talkable, trader, tip")
NOW = NOW + 600
H.sent = {}
H.env.xr_meet.process_npc_usability(npc)
check(#sent_named(H, "npc.talk") == 0, "unchanged flags are not sent again")
H.enemies = { ["stalker/stalker"] = true }
NOW = NOW + 600
H.env.xr_meet.process_npc_usability(npc)
pump()
check(puppet._talk == false and puppet._trade == false, "enemy faction for this player -> no talk, no trade")
H.enemies = {}
npc._wounded = true
H.env.db.storage[200].wounded = { enable_talk = true }
H.env.save_var(npc, "wounded_state", "true")
C.env.db.storage[200] = { wounded = { wound_manager = { state = "nil" } } }
NOW = NOW + 600
H.env.xr_meet.process_npc_usability(npc)
pump()
check(puppet._talk == true and puppet._trade == false, "wounded NPC with enable_talk: talk, no trade")
check(C.env.load_var(puppet, "wounded_state") == "true" and C.env.db.storage[200].wounded.wound_manager.state == "true",
	"wounded state mirrored to the client")
proxy._pos = vec(500, 0, 0)
NOW = NOW + 600
H.sent = {}
H.env.xr_meet.process_npc_usability(npc)
check(#sent_named(H, "npc.talk") == 0, "client far from the NPC: nothing sent")
proxy._pos = vec(16, 0, 0)
check(H.env.xr_conditions.actor_is_safemode(proxy, npc) == true, "proxy without a weapon in hands: safe mode")
proxy._active = { _weapon = true }
check(H.env.xr_conditions.actor_is_safemode(proxy, npc) == false, "proxy with a weapon: not safe")
check(H.env.xr_conditions.actor_is_safemode(H.env.db.actor, npc) == "stock", "host's own player: stock")
C.env.db.actor._pos = vec(15, 0, 1)
proxy._pos = vec(15, 0, 1)
QUEUE = {}
C.env.dialogs.transfer_medkit(C.env.db.actor, puppet)
check(C.stock_medkit, "client: stock help-wounded action runs (item and relation through the engine)")
pump()
check(H.unlocked == 200, "host unlocked the wounded NPC's medkit")
proxy._pos = vec(400, 0, 0)
H.unlocked = nil
C.env.dialogs.transfer_medkit(C.env.db.actor, puppet)
pump()
check(H.unlocked == nil, "help from far away refused")

print("== coop_npc_companions: a client's companion follows that client")
H, C, proxy, hav = pair()
common(H)
common(C)
local squad = { id = 300, members = { 201 } }
function squad:squad_members()
	local i = 0
	return function() i = i + 1; local id = self.members[i]; if id then return { id = id } end end
end
local function comp_stock(M)
	local E = M.env
	E.get_object_squad = function(o) return o:id() == 201 and squad or nil end
	E.alife_object = function(id) return id == 300 and squad or nil end
	E.axr_companions = { companion_squads = {} }
	E.dialogs_axr_companion = {
		become_actor_companion = function(actor, npc)
			M.became = { actor_id = actor:id(), db_actor = E.db.actor:id() }
			E.axr_companions.companion_squads[300] = squad
			npc:give_info_portion("npcx_is_companion")
		end,
		remove_companions_from_squad = function(actor, npc)
			E.axr_companions.companion_squads[300] = nil
			npc:disable_info_portion("npcx_is_companion")
		end,
		set_companion_to_wait_state = function(actor, npc) npc:give_info_portion("npcx_beh_wait") end,
	}
	E.axr_beh = { action_beh = { execute = function(self) M.beh_actor = E.db.actor:id() end } }
end
comp_stock(H)
comp_stock(C)
local CH = load_script(H, "coop_npc_companions")
local CC = load_script(C, "coop_npc_companions")
CH.on_game_start()
CC.on_game_start()
H.fire("actor_on_update")
local comp = H.add(make_obj(201, 12, 0, 0, { _name = "comp" }))
local comp_c = C.add(make_obj(201, 12, 0, 0, { _name = "comp" }))
-- Ruling F2-34: the host takes a recruit only right after a talk (here the client holds the talk lock of the NPC)
H.env.coop.talk_recent = function(peer, npc_id, ms) return peer == 1 and npc_id == 201 end
QUEUE = {}
C.env.dialogs_axr_companion.become_actor_companion(C.env.db.actor, comp_c)
check(C.became == nil, "client: recruit not run locally")
pump()
check(H.became and H.became.actor_id == 0, "host ran the recruit for the client (stock action, NPC picked by who_is_npc)")
check(CH._leaders()[300] == 500, "squad led by the client's proxy")
check(comp_c:has_info("npcx_is_companion"), "companion flag mirrored to the leader's machine")
C.env.dialogs_axr_companion.set_companion_to_wait_state(C.env.db.actor, comp_c)
pump()
check(comp:has_info("npcx_beh_wait") and comp_c:has_info("npcx_beh_wait"), "order applied on the host, flag mirrored")
NOW = NOW + 1
H.env.axr_beh.action_beh.execute({ object = comp })
check(H.beh_actor == 500, "companion thinks with 'actor' = its leader's proxy")
H.env.db.actor._pos = vec(12, 0, 1)
H.env.dialogs_axr_companion.remove_companions_from_squad(H.env.db.actor, comp) -- the host dismisses it directly (stock)
NOW = NOW + 3000
H.fire("actor_on_update")
check(CH._leaders()[300] == nil, "leader forgotten once the squad is no longer a companion squad")
proxy._pos = vec(300, 0, 0)
C.env.dialogs_axr_companion.become_actor_companion(C.env.db.actor, comp_c)
H.became = nil
pump()
check(H.became == nil, "recruit from far away refused")

print("== coop_npc_companions: a recruit needs a talk with the squad in the last 5 s (Ruling F2-34)")
H, C, proxy, hav = pair()
common(H)
common(C)
squad.members = { 201, 202 }
comp_stock(H)
comp_stock(C)
CH = load_script(H, "coop_npc_companions")
CC = load_script(C, "coop_npc_companions")
CH.on_game_start()
CC.on_game_start()
H.fire("actor_on_update")
comp = H.add(make_obj(201, 12, 0, 0, { _name = "comp" }))
H.add(make_obj(202, 13, 0, 0, { _name = "comp2" }))
comp_c = C.add(make_obj(201, 12, 0, 0, { _name = "comp" }))
-- the host's dialog module: [peer][npc] = true while the lock is held, else the time it ended
local talks = {}
local asked = {}
H.env.coop.talk_recent = function(peer, npc_id, ms)
	asked[#asked + 1] = { peer = peer, npc = npc_id, ms = ms }
	local t = talks[peer] and talks[peer][npc_id]
	if t == true then return true end
	return t ~= nil and NOW - t <= ms
end
local function recruit()
	H.became = nil
	QUEUE = {}
	C.env.dialogs_axr_companion.become_actor_companion(C.env.db.actor, comp_c)
	pump()
	return H.became ~= nil
end
local function dismiss()
	H.env.dialogs_axr_companion.remove_companions_from_squad(H.env.db.actor, comp)
	NOW = NOW + 3000
	H.fire("actor_on_update")
end
local function refusals()
	local n = 0
	for _, line in ipairs(H.log) do
		if line:find("recruit", 1, true) and line:find("refused", 1, true) then n = n + 1 end
	end
	return n
end
check(not recruit(), "no talk: the recruit is refused")
check(CH._leaders()[300] == nil, "no talk: no leader")
check(CH._stats().refused_talk == 1, "no talk: counted (coop_status)")
check(refusals() == 1, "no talk: a log line")
check(#asked >= 1 and asked[1].peer == 1 and asked[1].npc == 201 and asked[1].ms == 5000,
	"asked the engine about this player, the NPC recruited through, 5000 ms")
talks[1] = { [201] = NOW - 2000 }
check(recruit(), "a talk that ended 2 s ago: recruited")
check(CH._leaders()[300] == 500, "the recruiter's proxy leads the squad")
dismiss()
talks[1] = { [201] = NOW - 10000 }
check(not recruit(), "a talk that ended 10 s ago: refused")
check(CH._stats().refused_talk == 2, "counted again")
talks[1] = { [202] = NOW - 1000 }
check(recruit(), "a talk with another member of the squad: recruited")
dismiss()
talks = { [7] = { [201] = true } }
check(not recruit(), "another player's talk does not count")
talks = { [1] = { [201] = true } }
check(recruit(), "the talk lock held now: recruited")

print("== coop_npc_disguise: the host judges a disguised client")
H, C, proxy, hav = pair()
common(H)
common(C)
local function disg_stock(M)
	local E = M.env
	M.options = { ["gameplay/disguise/active_item"] = true, ["gameplay/disguise/active_item_factor"] = 1 }
	E.gameplay_disguise = {
		is_actor_disguised = function() return M.disguised == true end,
		get_default_comm = function() return "stalker" end,
		examinate_active_item = function() return 0 end,
		examinate_speed = function() return 1 end,
		get_npc_awareness = function() return 1.3 end,
		set_msg = function(s) M.msg = s end,
		set_comm = function(c) M.comm = c; M.disguised = false end,
		hud_val_to_str = function() return "==" end,
		anybody_see = function() return "stock_see" end,
		anybody_remember = function() return "stock_rem" end,
		hud_update = function() M.stock_hud = true end,
	}
	E.game_statistics = { increment_reputation = function(v) M.rep = (M.rep or 0) + v end }
	E.game_achievements = { has_achievement = function() return false end }
	E.ui_options = { get = function(k) return M.options[k] end }
end
disg_stock(H)
disg_stock(C)
local DH = load_script(H, "coop_npc_disguise")
local DC = load_script(C, "coop_npc_disguise")
DH.on_game_start()
DC.on_game_start()
H.fire("actor_on_update")
C.disguised = true
C.env.db.actor._comm = "actor_dolg"
QUEUE = {}
C.fire("actor_on_update")
pump()
local ps = DH._players_state()[1]
check(ps and ps.d == true and ps.c == "dolg" and ps.def == "stalker" and ps.itm == 100, "client's disguise report reached the host")
local watcher = H.add(make_obj(210, 12, 0, 0, { _name = "dolg_guard", _comm = "dolg", _section = "dolg_3" }))
watcher._sees[500] = true
proxy._pos = vec(13, 0, 0)
H.game_ms = 1000000
QUEUE = {}
for i = 1, 3 do
	H.game_ms = H.game_ms + 30000
	DH._npc_on_update(watcher)
end
check(#sent_named(H, "npc.disg_expose") == 1, "suspicion over the break point exposes the client")
check(H.goodwill_hits == 1, "host applied the faction goodwill hit")
pump()
check(C.comm == "stalker" and C.rep == -100, "client dropped the disguise and took the reputation hit")
C.disguised = true
NOW = NOW + 3000
H.fire("actor_on_update")
pump()
check(C.env.gameplay_disguise.anybody_see() == true, "client: 'somebody sees me' comes from the host")
check(C.env.gameplay_disguise.anybody_remember() == true, "client: 'somebody remembers me' comes from the host")
check(H.env.gameplay_disguise.anybody_see() == "stock_see", "host's own player: stock")

print("== coop_npc_world: mines, campfires, dynamic anomalies, music")
H, C, proxy, hav = pair()
common(H)
common(C)
local created = {}
local function world_stock(M)
	local E = M.env
	E.txr_mines = { plant_bomb = function() M.stock_plant = true end, _mines = {}, generic_on_update = function(o) M.gen_upd = (M.gen_upd or 0) + 1 end,
		trigger_mine = function(id) M.stock_trigger = id end }
	E.actor_effects = { play_item_fx = function(f) M.item_fx = f end, play_continuous_effect = function() end }
	E.alife_release_id = function(id) M.released = id end
	E.alife_create = function(sec, pos, lv, gv)
		local id = 900 + #created
		created[#created + 1] = sec
		M.add(make_obj(id, pos.x, pos.y, pos.z, { _section = sec }))
		return { id = id }
	end
	E.alife_object = function(id) return M.objects[id] and { id = id } or nil end
	E.game.get_game_time = function() return setmetatable({ ms = M.game_ms or 0 }, { __index = { diffSec = function(a, b) return (a.ms - b.ms) / 1000 end } }) end
	E.level.get_start_time = function() return setmetatable({ ms = 0 }, { __index = { diffSec = function(a, b) return (a.ms - b.ms) / 1000 end } }) end
	E.bind_campfire = { campfires_all = {}, rain_pass = function() return true end, get_nearby_campfire = function() return nil end }
	E.bind_campfire.campfire_go_on = function(obj, cf)
		if E.bind_campfire.rain_pass() then M.local_turn_on = true end
	end
	E.bind_campfire.campfire_go_off = function(cf) end
	E.bind_anomaly_field = {
		dyn_anomalies = { l01_escape = { [700] = true } },
		dyn_anomalies_update = function() M.stock_dyn = true end,
		pulse_anomaly_update = function() M.stock_pulse = true end,
		add_marker = function() end,
	}
	E.itms_manager = { use_guitar = function() M.stock_guitar = true end }
	E.sound_object = setmetatable({ s3d = 1 }, { __call = function(_, path)
		return { length = function() return 1000 end, play_no_feedback = function() M.music_local = path end,
			play_at_pos = function(_, who) M.music_at = { path, who:id() } end }
	end })
end
world_stock(H)
world_stock(C)
local WH = load_script(H, "coop_npc_world")
local WC = load_script(C, "coop_npc_world")
WH.on_game_start()
WC.on_game_start()
H.fire("actor_on_update")
local item = C.add(make_obj(777, 0, 0, 0, { _section = "mine_new" }))
C.env.db.actor._pos = vec(10, 0, 0)
proxy._pos = vec(10, 0, 0)
QUEUE = {}
C.env.txr_mines.plant_bomb(item, 1, 10)
check(not C.stock_plant and C.item_fx == "mine" and C.released == 777, "client: plant sent to the host, item released, effect played")
H.game_ms = 0
pump()
local armed
for id, m in pairs(WH._mines()) do armed = { id = id, m = m } end
check(armed and created[1] == "mine_new_blow" and armed.m.mode == 1 and armed.m.planter == 500, "host created and armed a timer charge for the client")
H.game_ms = 61000 * 1 -- 10 s * time factor 6 = 60 game s
NOW = NOW + 300
H.fire("actor_on_update")
check(H.objects[armed.id]._exploded, "timer charge exploded on the host")
-- the blast hits an NPC "from" the planter
local victim = H.add(make_obj(220, 11, 0, 0))
local flags = { ret_value = true }
H.env.hit = function(h) local c = {} for k, v in pairs(h or {}) do c[k] = v end return c end
H.fire("npc_on_before_hit", victim, { draftsman = H.objects[armed.id], power = 1 }, 0, flags)
check(flags.ret_value == false and victim._hits and victim._hits[1].draftsman == proxy, "client's charge blames the client's proxy")
-- proximity charge triggered by the proxy
WH._mines()[armed.id] = nil
QUEUE = {}
C.env.txr_mines.plant_bomb(C.add(make_obj(778, 0, 0, 0, { _section = "ied_new" })), 0)
pump()
local prox
for id, m in pairs(WH._mines()) do prox = id end
proxy._pos = vec(40, 0, 0)
H.game_ms = H.game_ms + 31000
NOW = NOW + 300
H.fire("actor_on_update")
check(not H.objects[prox]._exploded, "armed proximity charge waits")
proxy._pos = vec(11, 0, 0)
NOW = NOW + 300
H.fire("actor_on_update")
check(H.objects[prox]._exploded, "proximity charge triggered by the client's proxy")
check((H.gen_upd or 0) == 0, "stock generic_on_update not fed while the stock list is empty")
H.env.txr_mines._mines[5] = {}
NOW = NOW + 300
H.fire("actor_on_update")
check(H.gen_upd == 1, "stock proximity charges get the proxies fed")
H.env.txr_mines._mines[5] = nil
-- R3 В2 review: with the engine's coop.explode_as every charge goes off as its planter (friendly fire in the engine)
local as_calls = {}
local as_result = true
H.env.coop.explode_as = function(id, by) as_calls[#as_calls + 1] = { id = id, by = by } return as_result end
WH._mines()[prox] = nil
QUEUE = {}
C.env.txr_mines.plant_bomb(C.add(make_obj(779, 0, 0, 0, { _section = "mine_new" })), 1, 10)
pump()
local timer
for id, m in pairs(WH._mines()) do timer = id end
H.game_ms = H.game_ms + 61000
NOW = NOW + 300
H.fire("actor_on_update")
check(#as_calls == 1 and as_calls[1].id == timer and as_calls[1].by == 500, "client's charge set off as the client's proxy")
check(not H.objects[timer]._exploded, "no stock explode when the engine set it off")
check(WH._stats().as_planter == 1, "counted as set off by its planter")
-- the engine refuses (planter offline): the stock explode, the charge is its own initiator
as_result = false
WH._mines()[timer] = nil
QUEUE = {}
C.env.txr_mines.plant_bomb(C.add(make_obj(780, 0, 0, 0, { _section = "mine_new" })), 1, 10)
pump()
for id, m in pairs(WH._mines()) do timer = id end
H.game_ms = H.game_ms + 61000
NOW = NOW + 300
H.fire("actor_on_update")
check(#as_calls == 2 and H.objects[timer]._exploded, "engine refused: stock explode")
-- the host's own stock charge goes off as the host's character
as_result = true
H.env.txr_mines._mines[901] = { active = true }
H.stock_trigger = nil
H.env.txr_mines.trigger_mine(901)
check(as_calls[3] and as_calls[3].id == 901 and as_calls[3].by == 0, "host's stock charge set off as the host's character")
check(H.stock_trigger == nil and H.env.txr_mines._mines[901].active == false, "stock trigger skipped, charge disarmed")
H.env.txr_mines._mines[901] = nil
-- without the engine function: stock trigger and stock explode
H.env.coop.explode_as = nil
H.env.txr_mines.trigger_mine(902)
check(H.stock_trigger == 902 and #as_calls == 3, "no coop.explode_as: stock trigger_mine")
-- a client never sets charges off itself
C.env.coop.explode_as = function() as_calls[#as_calls + 1] = { client = true } return true end
C.env.txr_mines.trigger_mine(903)
check(C.stock_trigger == 903 and #as_calls == 3, "client: stock trigger_mine (the host detonates)")
C.env.coop.explode_as = nil
-- campfire
local cf = { on = false }
function cf:is_on() return self.on end
function cf:turn_on() self.on = true end
function cf:turn_off() self.on = false end
local cf_obj = H.add(make_obj(600, 11, 0, 0))
H.env.bind_campfire.campfires_all[600] = { campfire = cf, object = cf_obj }
local cf_c = {}
C.env.bind_campfire.campfires_all[600] = { campfire = cf_c, object = C.add(make_obj(600, 11, 0, 0)) }
QUEUE = {}
C.env.bind_campfire.campfire_go_on(nil, cf_c)
pump()
check(cf.on == true, "client lighting a campfire: the host lit it")
C.env.bind_campfire.rain_pass = function() return false end
cf.on = false
C.env.bind_campfire.campfire_go_on(nil, cf_c)
pump()
check(cf.on == false, "rain put the match out: no request")
-- dynamic anomalies
local ano = H.add(make_obj(700, 11, 0, 0))
ano.enable_anomaly = function(self) self._en = true end
ano.disable_anomaly = function(self) self._dis = true end
proxy._pos = vec(12, 0, 0)
H.env.db.actor._pos = vec(300, 0, 0)
NOW = NOW + 1
H.env.bind_anomaly_field.dyn_anomalies_update()
check(not ano._en and not H.stock_dyn, "dynamic anomaly next to the client is not switched")
proxy._pos = vec(200, 0, 0)
NOW = NOW + 1
H.env.bind_anomaly_field.dyn_anomalies_update()
check(ano._en == true, "switched once nobody is near")
-- zone artefact picked up by the client
local taken = {}
local zone = { on_artefact_take = function(self, obj) taken[#taken + 1] = obj:id(); H.env.bind_anomaly_zone.parent_zones_by_artefact_id[obj:id()] = nil end }
H.env.bind_anomaly_zone = { parent_zones_by_artefact_id = { [800] = zone, [801] = zone } }
H.add(make_obj(800, 0, 0, 0, { _parent = proxy }))
H.add(make_obj(801, 0, 0, 0))
NOW = NOW + 2500
H.fire("actor_on_update")
check(#taken == 1 and taken[1] == 800, "zone forgets an artefact held by a client's proxy, keeps the free one")
-- music
QUEUE = {}
C.env.itms_manager.use_guitar({})
pump()
check(C.music_local and H.music_at and H.music_at[2] == 500 and H.music_at[1] == C.music_local, "client's guitar heard at its proxy on the host")

print("== coop_npc_compat: rewrite text")
H, C, proxy, hav = pair()
local K = load_script(H, "coop_npc_compat")
local out = K.rewrite_text("a\nif (killer_id ~= 0) then return end\nb", { { "if (killer_id ~= 0) then return end", "X" } })
check(out == "a\nX\nb", "single literal rewritten")
local none, why = K.rewrite_text("nothing here", { { "if (killer_id ~= 0) then return end", "X" } })
check(none == nil and why:find("0 times"), "missing literal: untouched (all-or-nothing)")
local twice = K.rewrite_text("A A", { { "A", "B" } })
check(twice == nil, "ambiguous literal: untouched")
local chained = K.rewrite_text("x = 1 y = 2", { { "x = 1", "x = 3" }, { "y = 2", "y = 4" } })
check(chained == "x = 3 y = 4", "pairs applied in order")
local every = K.rewrite_text("A x A", { { "A", "B", all = true } })
check(every == "B x B", "all = true: every occurrence (audit D2)")
check(K.rewrite_text("x", { { "A", "B", all = true } }) == nil, "all = true needs at least one")

print("== coop_npc_compat: a rewritten script that wraps another module at load runs twice without wrapping itself")
-- trader_autoinject's shape: it captures trade_manager.update into a global of its own, then wraps it
local wrap_src = "TraderUpdate = trade_manager.update\n" ..
	"function trade_manager.update(npc, force) TraderUpdate(npc, force) return 'wrapped' end\n"
local function first_load(m)
	local chunk = assert(loadstring(wrap_src))
	setfenv(chunk, m)
	chunk()
end
local function fresh(name)
	local calls = { n = 0 }
	H.env.trade_manager = { update = function() calls.n = calls.n + 1 end }
	local m = setmetatable({}, { __index = H.env })
	H.env[name] = m
	first_load(m) -- what the engine did when it loaded the script
	return m, calls
end
-- control: a second run with nothing put back wraps the wrapper, which then calls itself
local m0, calls0 = fresh("some_other_mod")
local ok0 = K._rerun("some_other_mod", m0, wrap_src, "some_other_mod.script")
local ok0_call, err0 = pcall(H.env.trade_manager.update, {}, false)
check(ok0 and not ok0_call and tostring(err0):find("stack overflow"), "control: a plain second run overflows the stack")
-- trader_autoinject: the original goes back first, so the second run wraps the original once
local m1, calls1 = fresh("trader_autoinject")
local ok1 = K._rerun("trader_autoinject", m1, wrap_src, "trader_autoinject.script")
local ok1_call, res1 = pcall(H.env.trade_manager.update, {}, false)
check(ok1 and ok1_call and res1 == "wrapped" and calls1.n == 1, "trader_autoinject rerun: the original is called exactly once")
H.env.trade_manager, H.env.some_other_mod, H.env.trader_autoinject = nil, nil, nil

print("== coop_npc_compat: NPCs do not loot next to any player (audit B5)")
H, C, proxy, hav = pair()
H.env.ui_options = { get = function(k) if k == "gameplay/general/npc_loot_distance" then return 10 end end }
H.env.xr_corpse_detection = { near_actor = function(obj) return obj:position():distance_to(H.env.db.actor:position()) < 10 end }
H.env.xr_gather_items = { near_actor = function() return false end }
local KL = load_script(H, "coop_npc_compat")
KL.on_game_start()
KL._set_host_on(true)
local body = H.add(make_obj(777, proxy:position().x + 3, 0, proxy:position().z, { _name = "corpse" }))
check(H.env.xr_corpse_detection.near_actor(body) == true, "a corpse 3 m from a client's character is 'near the player'")
local far_body = H.add(make_obj(778, proxy:position().x + 300, 0, proxy:position().z, { _name = "far corpse" }))
check(H.env.xr_corpse_detection.near_actor(far_body) == false, "far from every player: lootable")
KL._set_host_on(false)
check(H.env.xr_corpse_detection.near_actor(body) == false, "no clients: the stock rule alone")
H.env.xr_corpse_detection, H.env.xr_gather_items, H.env.ui_options = nil, nil, nil

print("== coop_npc_compat: squads and smart respawns keep away from every player (audit B3, B4)")
H, C, proxy, hav = pair()
local SQ = {}
SQ.check_online_status = function(self)
	if self.position:distance_to(H.env.db.actor:position()) <= 75 then self.forced_online_status = false else self.forced_online_status = nil end
end
local SM = {}
SM.try_respawn = function(self) self.respawned = true end
H.env.sim_squad_scripted = { sim_squad_scripted = SQ }
H.env.smart_terrain = { se_smart_terrain = SM }
local KS = load_script(H, "coop_npc_compat")
KS.on_game_start()
KS._set_host_on(true)
H.env.db.actor._pos = vector():set(5000, 0, 5000) -- the host far away: only the client's character can keep the squad off
local squad = { online = false, position = vector():set(proxy:position().x + 20, 0, proxy:position().z) }
SQ.check_online_status(squad)
check(squad.forced_online_status == false, "a squad 20 m from a client's character stays offline")
local far_squad = { online = false, position = vector():set(proxy:position().x + 900, 0, proxy:position().z + 900) }
SQ.check_online_status(far_squad)
check(far_squad.forced_online_status == nil, "far from every player: no rule")
local smart = { position = vector():set(proxy:position().x + 30, 0, proxy:position().z), respawn_radius = 150 }
SM.try_respawn(smart)
check(smart.respawned == nil, "no respawn 30 m from a client")
local far_smart = { position = vector():set(proxy:position().x + 900, 0, proxy:position().z + 900), respawn_radius = 150 }
SM.try_respawn(far_smart)
check(far_smart.respawned == true, "far from every player: respawns")
H.env.sim_squad_scripted, H.env.smart_terrain = nil, nil

print("== coop_npc_compat: helicopters hunt every player as the actor (audit B7)")
H, C, proxy, hav = pair()
common(H)
proxy._comm = "stalker"
local HC = {}
HC.is_enemy = function(self, obj) H.stock_heli_enemy = (H.stock_heli_enemy or 0) + 1; return "stock" end
HC.set_enemy_from_custom_data = function(self, combat_enemy)
	if combat_enemy == "actor" then self.st.enemy_id = 0 end
end
local HF = {}
HF.set_enemy = function(self) self.picked = self.enemy_id or "actor" end
H.env.heli_combat = { heli_combat = HC }
H.env.heli_fire = { heli_fire = HF }
H.env.AC_ID = 0
H.env.xr_combat_ignore = { ignore_enemy_by_overrides = function() return false end }
H.env.alife_object = function(id) return id == 900 and { community = "army" } or nil end
local KH = load_script(H, "coop_npc_compat")
KH.on_game_start()
KH._set_host_on(true)
local heli_obj = make_obj(900, 0, 50, 0, { _name = "heli" })
local hc = setmetatable({ object = heli_obj, st = {}, actor_always_enemy = false }, { __index = HC })
check(HC.is_enemy(hc, proxy) == false, "a client's character is no enemy without his flag or actor_always_enemy")
H.env.db.storage[500] = { heli_enemy_flag = true }
check(HC.is_enemy(hc, proxy) == true, "his own heli flag (he shot it) makes him an enemy, as the actor's")
H.env.db.storage[500] = {}
hc.actor_always_enemy = true
check(HC.is_enemy(hc, proxy) == true, "actor_always_enemy covers a client's character too")
proxy._comm = "army"
check(HC.is_enemy(hc, proxy) == false, "the heli's own community is spared")
proxy._comm = "stalker"
proxy._wounded = true
check(HC.is_enemy(hc, proxy) == false, "a wounded player is not a target")
proxy._wounded = nil
local n = H.stock_heli_enemy or 0
local npc_b = make_obj(300, 5, 0, 5)
check(HC.is_enemy(hc, npc_b) == "stock" and H.stock_heli_enemy == n + 1, "an NPC goes to the stock rule")
KH._set_host_on(false)
check(HC.is_enemy(hc, proxy) == "stock", "single player / no clients: the stock rule")
KH._set_host_on(true)

H.env.db.actor._pos = vector():set(3000, 0, 3000) -- the host far away, the client's character near the heli
HC.set_enemy_from_custom_data(hc, "actor")
check(hc.st.enemy_id == 500, "combat_enemy = actor: the nearest player (a client's character)")
H.env.db.actor._pos = vector():set(1, 0, 1)
hc.st.enemy_id = nil
HC.set_enemy_from_custom_data(hc, "actor")
check(hc.st.enemy_id == 0, "the host's actor when he is the nearest")

local visible = { [500] = true }
heli_obj.get_helicopter = function() return { isVisible = function(_, o) return visible[o:id()] == true end } end
local hf = setmetatable({ obj = heli_obj, enemy_ = "actor", flag_by_enemy = true }, { __index = HF })
HF.set_enemy(hf)
check(hf.picked == 500, "heli_fire enemy = actor: the nearest player it sees (the client's character)")
visible = { [0] = true, [500] = true }
hf.enemy_id, hf.flag_by_enemy = nil, true
HF.set_enemy(hf)
check(hf.picked == "actor", "the host's actor when he is the nearest seen (the stock's pick)")
visible = {}
hf.enemy_id, hf.flag_by_enemy = 500, true
HF.set_enemy(hf)
check(hf.picked == "actor", "nobody seen: the stock's actor")
hf.enemy_id, hf.flag_by_enemy = 500, false
HF.set_enemy(hf)
check(hf.picked == 500, "a kept target stays (no pick while flag_by_enemy is off)")
H.env.heli_combat, H.env.heli_fire = nil, nil

print(string.format("\nRESULT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("tests failed") end
