-- Split levels: a player on a map server's level and the tasks of the world server: the far view at its entry points, the death relay, the
-- actions that go to the map server, a map server is no player. Real scripts over the quests harness: the host (world server, level 1),
-- a client on level 2, the map server of level 2. Run: tools\test_lua.cmd far_tasks
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_levels_share", "coop_quests_far", "coop_tasks", "coop_quests_offer", "coop_quests_party",
	"coop_quests_story", "coop_quests_missions", "coop_quests_pda" }
local BRIDGE = 0x101
local LEVEL_NAMES = { "l01_escape", "k00_marsh" }

local function vector_of()
	return { set = function(_, x, y, z) return vec(x, y, z) end }
end

local records = {} -- the world's records of what stands on level 2: id -> fields

local function world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	e.game_graph = function()
		return { vertex = function(_, v) return { level_id = function() return v end } end }
	end
	local sim = {}
	function sim:level_name(l) return LEVEL_NAMES[l] end
	function sim:switch_distance() return 150 end
	function sim:actor() return { id = 0, m_game_vertex_id = 1, position = vec(0, 0, 0) } end
	function sim:has_info() return false end
	e.alife = function() return sim end
	e.vector = vector_of
	e.db.anomaly_by_name = {}
	e.db.zone_by_name = {}
	local stock_object = e.alife_object
	e.alife_object = function(id)
		local r = records[id]
		if r then return r end
		local se = stock_object(id)
		if se then se.m_game_vertex_id = 1 end
		return se
	end
	e.IsStalker = function(o, cls)
		if type(o) == "table" and o.far then return o:clsid() == 44 end
		return type(o) == "table" and o._stalker == true
	end
	e.IsMonster = function(o, cls)
		if cls then return cls == 55 end
		return type(o) == "table" and o.clsid and o:clsid() == 55
	end
	e.coop.levels = {
		split = function() return true end,
		my_level = function() return M.my_level end,
		level_of_player = function(peer) return peer == 1 and 2 or 1 end,
		bridge_of_player = function(peer) return peer == 1 and BRIDGE or nil end,
		map_servers = function() return { { bridge = BRIDGE, level = 2 } } end,
		carried = function() return {} end,
		talking = function(peer) return M.talking_players and M.talking_players[peer] == true end,
	}
	e.coop_mods_core = { find_local = function(m, name) return m["_local_" .. name] end }
	e.axr_companions = { companion_squads = {} }
	-- the stock of what coop_quests_party mirrors and coop_quests_pda shares
	e.dialogs_darkvalley = { bandit_companion_task_1_complete = function() return "stock" end }
	e.dialogs_jupiter = {
		jup_b32_anomaly_has_af = function()
			local z = e.db.anomaly_by_name.jup_b32_anomal_zone
			return z ~= nil and z.spawned_count > 0
		end,
		jup_b32_anomaly_do_not_has_af = function() return false end,
	}
	M.unlocked = {}
	e.ui_pda_encyclopedia_tab = {
		unlock_note = function(s) M.unlocked[s] = true end,
		unlock_article = function(s) M.unlocked[s] = true end,
		is_unlocked_note = function(s) return M.unlocked[s] == true end,
		is_unlocked_article = function(s) return M.unlocked[s] == true end,
	}
	M.earned = {}
	e.game_statistics = { has_actor_achievement = function(n) return M.earned[n] == true end }
	-- the stock of what logic asks of the actor
	M.ObjMT.relation = function(self, who) return self._rel and self._rel[who:id()] or 1 end
	for name, want in pairs({ actor_friend = 0, actor_true_friend = 0, actor_neutral = 1, actor_true_neutral = 1 }) do
		e.xr_conditions[name] = function(actor, npc) return npc:relation(actor) == want end
	end
	e.xr_conditions.actor_enemy = function(actor, npc) return npc:relation(actor) >= 2 end
	e.xr_conditions.actor_true_enemy = e.xr_conditions.actor_enemy
	e.utils_data = { CTime_from_table = function(t) return t end }
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		if M.env[n].on_game_start then M.env[n].on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

local Hm = machine("host", 0)
local Cm = machine("client", 1)
local Ms = machine("client", BRIDGE)
Hm.my_level, Cm.my_level, Ms.my_level = 1, 2, 2
world(Hm); world(Cm); world(Ms)
Ms.env.coop.is_map_server = function() return true end

records[500] = { id = 500, parent_id = 65535, m_game_vertex_id = 2, m_level_vertex_id = 5, position = vec(10, 0, 10), online = true,
	section_name = function() return "coop_player_avatar" end, clsid = function() return 44 end, name = function() return "player" end,
	community = function() return "stalker" end }
records[700] = { id = 700, parent_id = 65535, m_game_vertex_id = 2, m_level_vertex_id = 6, position = vec(12, 0, 10), online = true, group_id = 65535,
	section_name = function() return "stalker_trader" end, clsid = function() return 44 end, name = function() return "npc700" end,
	community = function() return "stalker" end, rank = function() return 10 end, alive = function() return true end }
records[701] = { id = 701, parent_id = 65535, m_game_vertex_id = 2, m_level_vertex_id = 6, position = vec(300, 0, 300), online = true, group_id = 65535,
	section_name = function() return "stalker_far" end, clsid = function() return 44 end, name = function() return "npc701" end,
	alive = function() return true end }
records[710] = { id = 710, parent_id = 65535, m_game_vertex_id = 2, m_level_vertex_id = 6, position = vec(40, 0, 10), online = true,
	section_name = function() return "bloodsucker_strong" end, clsid = function() return 55 end, name = function() return "bs" end,
	alive = function() return false end }
records[711] = { id = 711, parent_id = 65535, m_game_vertex_id = 2, position = vec(40, 0, 10), online = true,
	section_name = function() return "dog" end, clsid = function() return 55 end, name = function() return "dog" end, alive = function() return false end }

local PLAYERS_H = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Hm.players = PLAYERS_H
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 400 } }
Ms.players = { { id = 1, is_self = false, avatar_id = 500 } }
Ms.new_obj(500, "coop_player_avatar", vec(10, 0, 10), { _stalker = true })
Ms.npc = Ms.new_obj(700, "stalker_trader", vec(12, 0, 10), { _stalker = true })
Cm.npc = Cm.new_obj(700, "stalker_trader", vec(12, 0, 10), { _stalker = true })

-- the stock functions the relay calls
local RELAYED = {}
Hm.env.dialogs_lostzone = { set_impending_doom_timer = function(a, b)
	RELAYED[#RELAYED + 1] = { a = a:id(), b = b:id(), far = b.far, name = Hm.env.level.name(), peer = Hm.env.coop_tasks.reward_peer() }
end }
Cm.env.dialogs_lostzone = { set_impending_doom_timer = function() end }
Ms.env.dialogs_lostzone = { set_impending_doom_timer = function() end }
Hm.env.load_ctime = function() return nil end
Cm.env.load_ctime = function() return nil end
Ms.env.load_ctime = function() return nil end

-- the stock of "wanna trade"
local function death_manager(M)
	local answers = {}
	M.env.death_manager = {
		get_items_by_npc = function(id) return answers[id] end,
		set_items_by_npc = function(id, v) answers[id] = v end,
		create_item_list = function(npc)
			M.stocked = (M.stocked or 0) + 1
			answers[npc:id()] = { "wpn" }
		end,
	}
	M.env.character_community = function(o) return o:character_community() end
	M.env.ranks = { get_obj_rank_name = function() return "novice" end }
end
death_manager(Hm); death_manager(Cm); death_manager(Ms)
Cm.env.dialogs.is_trade_accept = function() return "stock" end
Hm.env.dialogs.is_trade_accept = function() return "stock" end
Ms.env.dialogs.is_trade_accept = function() return "stock" end

-- the stock stash
Hm.env.treasure_manager = { caches = {}, create_random_stash = function(no_spot, hint, bonus, spawn_local)
	Hm.stash = { hint = hint, level = Hm.env.level.name(), actor_vertex = Hm.env.alife():actor().m_game_vertex_id }
end, set_random_stash = function(spot, hint, _, b) Hm.reveal = { spot = spot, b = b } end }
Cm.env.treasure_manager = { caches = {}, create_random_stash = function() end, set_random_stash = function() end }
Ms.env.treasure_manager = { caches = {}, create_random_stash = function() end, set_random_stash = function() end }

-- a ceasefire
local function bribe(M)
	M.env.xr_bribe = { _local_M_DATA = {}, at_peace = function(c) return M.env.xr_bribe._local_M_DATA[c] ~= nil end,
		npc_on_hit_callback = function(c) M.env.xr_bribe._local_M_DATA[c] = nil end }
	M.env.character_community = M.env.character_community or function(o) return o:character_community() end
end
bribe(Hm); bribe(Cm); bribe(Ms)

-- the stock entry points of an NPC's logic: what they are given is kept
local LOGIC = { "configure_schemes", "determine_section_to_activate", "activate_by_section", "switch_to_section" }
Hm.logic_ran = {}
for _, name in ipairs(LOGIC) do
	Hm.env.xr_logic[name] = function(npc)
		Hm.logic_ran[#Hm.logic_ran + 1] = name
		if npc.far then error("bad argument #1 to 'string_gmatch' (string expected, got nil)") end -- restrictor_manager, parse_names(nil)
		return "walker@job"
	end
end

boot(Hm); boot(Cm); boot(Ms)
pump()

local function step()
	NOW = NOW + 1500
	pump()
end

print("== two actions, two names: a reward's stash is not the reveal of a PDA message")
Hm.talking_players = { [1] = true }
Cm.env.treasure_manager.create_random_stash(nil, "the hint")
step()
check(Hm.stash and Hm.stash.hint == "the hint", "a reward's stash is made on the world server")
check(Hm.stash and Hm.stash.level == "k00_marsh", "on the level of who earned it")
check(Hm.stash and Hm.stash.actor_vertex == 2, "alife():actor() is he: box_in_same_map looks around him")
check(Hm.reveal == nil, "and it is not taken for a reveal")
Hm.env.alife_object_stock = nil
records[950] = { id = 950, parent_id = 65535, m_game_vertex_id = 2, position = vec(1, 0, 1) }
Cm.env.coop_quests_core.request_host_action("stash_reveal", { b = 950, s = "treasure", h = "hint" })
step()
check(Hm.reveal and Hm.reveal.b == 950, "the reveal of a PDA message has its own action")
Hm.stash = nil
Hm.talking_players = {}
Cm.env.treasure_manager.create_random_stash(nil, "no talk")
step()
check(Hm.stash == nil, "no talk on his level: refused")

print("== a dialog action of a player on a map server's level")
Hm.talking_players = { [1] = true }
Cm.env.dialogs_lostzone.set_impending_doom_timer(Cm.actor, Cm.npc)
step()
local c = RELAYED[1]
check(c ~= nil, "it runs on the world server, the data is its save's")
check(c and c.far == true and c.b == 700, "the NPC is a stand-in from the records")
check(c and c.name == "k00_marsh", "level.name is his")
check(c and c.peer == 1, "in his scope: rewards and tasks are his")
Hm.talking_players = {}
step()
Cm.env.dialogs_lostzone.set_impending_doom_timer(Cm.actor, Cm.npc)
step()
check(#RELAYED == 1, "no talk lock on his level: refused")
Hm.talking_players = { [1] = true }
step()
Cm.env.coop_quests_core.request_host_action("rly", { f = "dialogs_lostzone.set_impending_doom_timer", n = 701 })
step()
check(#RELAYED == 1, "an NPC out of reach of him: refused, measured on his level")
check(Hm.env.level.name() == "l01_escape", "the far view is closed again")

print("== what touches a live NPC goes to the map server")
Cm.env.dialogs.who_is_npc = function() return Cm.npc end
Ms.env.coop.talk_recent = function(from, id) return from == 1 and id == 700 end
Hm.env.coop.talk_recent = function() error("the world server has no talk lock of his") end
local yes = Cm.env.dialogs.is_trade_accept(Cm.actor, Cm.npc)
step()
if yes then
	check(Ms.stocked == 1, "the stalker who agreed gets his stock on the map server")
	check(Hm.stocked == nil, "not on the world server")
end
check(Ms.env.death_manager.get_items_by_npc(700) ~= nil, "the answer is kept where the NPC is")

print("== give_npc: under the far view")
Hm.created = nil
Hm.env.coop_tasks.party_take = function() return 1 end
Hm.env.ini_sys.section_exist = function() return true end
Hm.env.alife_create_item = function(sec, place) Hm.created = { sec = sec, far = type(place) == "table" and place.far, id = place[4] } end
Cm.env.coop_quests_core.request_host_action("give_npc", { s = "bread", n = 700, c = 1 })
step()
check(Hm.created and Hm.created.sec == "bread" and Hm.created.far == true and Hm.created.id == 700, "the group's item is made in his record")

print("== a task's logic on a map server is no player")
Hm.ini.logic_task = {}
local T = Hm.env.coop_tasks
Ms.env.coop.send_event("coop_tq", "", 0) -- nothing: a bad request must not break the handler
step()
check(T.player_of_request(BRIDGE, "logic_task") == 1, "the player of its level stands for it")
check(T.player_of_request(1, "logic_task") == 1, "a player is himself")
check(T.player_of_request(0x102, "logic_task") == 0, "a bridge with no level: the host")

print("== a task check looks at the level of its target")
Hm.ini.far_task = { status_functor = "far_sf" }
local seen = {}
Hm.env.task_status_functor.far_sf = function(tsk, id)
	seen.level = Hm.env.level.name()
	seen.npc = Hm.env.level.object_by_id(700)
	seen.host_actor = false
	for _, ch in ipairs(Hm.env.coop_quests_core.characters()) do seen.host_actor = seen.host_actor or ch.id == 0 end
end
Hm.tm:give_task("far_task", 700)
local tsk = Hm.tm.task_info.far_task
tsk.current_target = 700
Hm.env.task_manager.get_task_manager():update()
check(seen.level == "k00_marsh", "level.name is the level of the target")
check(seen.npc and seen.npc.far == true, "level.object_by_id finds it")
check(seen.host_actor == false, "the world server's actor is no character there")
check(Hm.env.level.name() == "l01_escape", "and it is closed after the check")

print("== a task that failed writes one line, a task that has ended opens no scope")
-- live 39.10: 21360 lines. The stock task_callback leaves last_check_task on a task that waits for its repeat timeout, and check_task
-- only returns early while it is nil: the wrapper opened a scope every frame and read what was left as a new fail.
local verdict = false
seen.far = 0
Hm.env.task_status_functor.far_sf = function(tk, id)
	if Hm.env.level.name() == "k00_marsh" then seen.far = seen.far + 1 end
	if verdict then tk.last_check_task = "fail" end
end
local function fail_lines(from)
	local n = 0
	for i = from + 1, #Hm.log do
		if Hm.log[i]:find("task far_task failed on k00_marsh", 1, true) then n = n + 1 end
	end
	return n
end
local function frames(n)
	for _ = 1, n do Hm.env.task_manager.get_task_manager():update() end
end
local before = #Hm.log
verdict = true
frames(1)
check(fail_lines(before) == 1, "a fail in a scope writes one line")
local says_stage = false
for i = before + 1, #Hm.log do says_stage = says_stage or Hm.log[i]:find("stage 0, giver 700", 1, true) ~= nil end
check(says_stage, "and what the check had in hand")
frames(5)
check(fail_lines(before) == 1, "the engine has not taken it yet: the same fail is no new line")
-- the engine took it: task_callback dropped the task and left the verdict
Hm.engine_tasks.far_task = nil
tsk.t = nil
tsk.timeout = {}
local far_before = seen.far
frames(20)
check(seen.far == far_before, "a task that waits for its repeat timeout opens no scope")
check(fail_lines(before) == 1, "and writes nothing")
tsk.last_check_task = nil
Hm.tm.task_info.far_task = nil
Hm.engine_tasks.far_task = nil

print("== the task of a player who is not in the world yet is not judged")
Hm.ini.away_task = { status_functor = "away_sf" }
local judged = 0
Hm.env.task_status_functor.away_sf = function() judged = judged + 1 end
T.run_as(1, function() Hm.tm:give_task("away_task", 700) end)
check(T.taker("away_task") == 1, "he took it")
frames(1)
check(judged == 1, "in the world: judged")
Hm.players = { PLAYERS_H[1], { id = 1, is_self = false } }
frames(1)
check(judged == 1, "on his loading screen: his things and his place cannot be read, nothing is judged")
Hm.players = { PLAYERS_H[1] }
frames(1)
check(judged == 2, "he left: the task goes on as before")
Hm.players = PLAYERS_H
Hm.tm.task_info.away_task = nil
Hm.engine_tasks.away_task = nil

print("== the death relay")
local far = Hm.env.coop_quests_far
local counted, level_ran = 0, 0
local function host_handler(victim, killer) counted = counted + 1 end
Hm.env.coop_route = { domain_handlers = function(cb, d) return cb == "monster_on_death_callback" and d == "host" and { host_handler } or {} end }
far.on_death(710, 500)
check(counted == 1, "one death on a map server: the task's handler of the domain host hears it once")
far.on_death(710, 500)
check(counted == 1, "the same Died again: not twice")
fire(Hm, "server_entity_on_unregister", { id = 710 })
far.on_death(710, 500)
check(counted == 2, "a new object under the same id is a new death")
far.on_death(4242, 500)
check(counted == 2, "an object that is no more: nothing")

print("== a stock handler that gives a stand-in to the engine: the relay takes the error, no window")
do
	local windows = 0
	Hm.env.COnLuaBindFatalError = function() windows = windows + 1 end
	local routed = Hm.env.coop_route
	Hm.env.coop_route = { domain_handlers = function(cb)
		return cb == "monster_on_death_callback" and { function() Hm.env.COnLuaBindFatalError("[Lua] see"); error("C++ exception") end } or {}
	end }
	fire(Hm, "server_entity_on_unregister", { id = 710 })
	far.on_death(710, 500)
	check(windows == 0, "inside the relay the window stays closed")
	Hm.env.COnLuaBindFatalError("[Lua] elsewhere")
	check(windows == 1, "outside it the engine's word stands")
	Hm.env.coop_route = routed
end

print("== Semenov's samples count a kill on a map server's level")
local TISSUE = "yan_ecolog_semenov_task_1_tissue_count"
Hm.env.save_var(Hm.actor, "yan_ecolog_semenov_task_1_tissue_need", 3)
Hm.env.get_story_object = function(sid) return sid == "yan_ecolog_semenov" and {} or nil end
Hm.env.coop_route = { domain_handlers = function() return {} end }
far.on_death(711, 500)
check(Hm.env.load_var(Hm.actor, TISSUE) == 1, "the counter is on the world server")
far.on_death(711, 500)
check(Hm.env.load_var(Hm.actor, TISSUE) == 1, "and counts once")
check(Ms.env.load_var(Ms.actor, TISSUE) == nil, "the map server counts nothing")

print("== a ceasefire holds on the map server and a hit there ends it")
Hm.env.xr_bribe._local_M_DATA.stalker = { distance = 50 }
for _ = 1, 3 do
	fire(Hm, "actor_on_update")
	step()
end
fire(Hm, "actor_on_update")
pump()
check(Ms.env.xr_bribe._local_M_DATA.stalker ~= nil, "the map server has it")
local flags = {}
Ms.env.coop_tasks = Ms.env.coop_tasks
local npc = Ms.npc
local player = Ms.objects[500]
fire(Ms, "on_enemy_eval", npc, player, flags)
check(flags.override == true and flags.result == false, "an NPC of that faction leaves a player alone there")
fire(Ms, "npc_on_hit_callback", npc, 1, nil, player)
step()
check(Ms.env.xr_bribe._local_M_DATA.stalker == nil, "a player's shot ends it there")
check(Hm.env.xr_bribe._local_M_DATA.stalker == nil, "and in the save")

print("== orders on the map server")
local ms_far = Ms.env.coop_quests_far
local killed = 0
Ms.ObjMT.kill = function(self, who) killed = killed + 1 end
local held = far.orders_held()
far.order(700, "kill")
check(far.orders_held() == held + 1, "held until the map server answers")
pump()
check(killed == 1, "the map server kills the NPC online there")
check(far.orders_held() == held, "and the answer ends it")
-- a resend after a lost answer changes nothing
local q_last = Hm.env.coop_main.decode(Hm.sent[#Hm.sent].payload)
Ms.handlers["quests.far_do"](Ms.env.coop_main.encode({ q = q_last.q, i = 700, v = "kill" }), 0)
check(killed == 1, "a repeat of the same order runs once")
far.order(701, "kill")
Ms.objects[701] = nil
pump()
check(far.orders_held() == held + 1, "an NPC not online there yet: the order waits for it")
Ms.new_obj(701, "stalker_far", vec(300, 0, 300), { _stalker = true })
killed = 0
NOW = NOW + 4000
Hm.env.coop_quests_far._tick()
pump()
check(killed == 1 and far.orders_held() == held, "it came online: the next try finds it")

print("== the host's move: the world server's numbers are new, the map server's memory of them goes")
do
	local killed_again = 0
	Ms.ObjMT.kill = function(self, who) killed_again = killed_again + 1 end
	far.order(700, "kill")
	pump()
	check(killed_again == 1, "an order")
	local q = Hm.env.coop_main.decode(Hm.sent[#Hm.sent].payload).q
	Ms.handlers["quests.far_do"](Ms.env.coop_main.encode({ q = q, i = 700, v = "kill" }), 0)
	check(killed_again == 1, "its repeat runs once")
	fire(Ms, "coop_world_back")
	Ms.handlers["quests.far_do"](Ms.env.coop_main.encode({ q = q, i = 700, v = "kill" }), 0)
	check(killed_again == 2, "the same number from the new Lua is a new order: it is not answered without being done")
	pump()
end

print("== a release of what a map server holds")
local released_ms = {}
Ms.env.safe_release_manager = { release = function(se) released_ms[#released_ms + 1] = se.id end }
Hm.env.safe_release_manager = { release = function(se) Hm.released_here = true end }
Ms.env.alife_object = function(id) return records[id] or { id = id } end
fire(Hm, "actor_on_first_update")
Hm.env.safe_release_manager.release(records[700])
pump()
check(released_ms[1] == 700 and not Hm.released_here, "it goes to the map server: the world server's own would be refused")
Hm.env.safe_release_manager.release({ id = 4000, online = false })
check(Hm.released_here == true, "what is not held stays here")
Hm.released_here = false
Hm.env.coop.levels.body_stays = function(id) return id == 4001 end
Hm.env.safe_release_manager.release({ id = 4001, online = false })
check(not Hm.released_here, "a body that fell online on a map server stays: the stock releases what it sees offline")
Hm.env.safe_release_manager.release({ id = 4002, online = false })
check(Hm.released_here == true, "what died offline goes as in the stock")
Hm.env.coop.levels.body_stays = nil

print("== hits only of what a task waits for")
local hit_seen = {}
Hm.env.coop_route = { domain_handlers = function(cb) return cb == "monster_on_before_hit" and { function(m, h, bone) hit_seen[#hit_seen + 1] = { m:id(), h.draftsman and h.draftsman:id(), bone } end } or {} end }
Hm.ini.yan_stalker_sakharov_task_brain_game = {}
Hm.tm:give_task("yan_stalker_sakharov_task_brain_game", 700)
for _ = 1, 3 do
	NOW = NOW + 6000
	fire(Hm, "actor_on_update")
	fire(Ms, "actor_on_update")
	pump()
end
Ms.new_obj(720, "controller_dark", vec(0, 0, 0))
Ms.new_obj(721, "dog_weak", vec(0, 0, 0))
local shooter = Ms.objects[500]
fire(Ms, "monster_on_before_hit", Ms.objects[721], { power = 1, type = 1, draftsman = shooter }, 31)
pump()
check(#hit_seen == 0, "a dog is nobody's task: nothing on the network")
records[720] = { id = 720, parent_id = 65535, m_game_vertex_id = 2, position = vec(0, 0, 0), online = true,
	section_name = function() return "controller_dark" end, clsid = function() return 55 end }
fire(Ms, "monster_on_before_hit", Ms.objects[720], { power = 1, type = 1, draftsman = shooter }, 31)
pump()
check(hit_seen[1] and hit_seen[1][1] == 720 and hit_seen[1][2] == 500 and hit_seen[1][3] == 31, "a controller for Brain Game: the bone and who struck reach the task")
Hm.tm.task_info.yan_stalker_sakharov_task_brain_game = nil

print("== the hand of who struck: an axe for Vengence Amplified")
Hm.ini.simulation_task_vengence_amplified = {}
Hm.tm:give_task("simulation_task_vengence_amplified", 700)
for _ = 1, 3 do
	NOW = NOW + 6000
	fire(Hm, "actor_on_update")
	fire(Ms, "actor_on_update")
	pump()
end
Ms.new_obj(722, "chimera_weak", vec(0, 0, 0))
records[722] = { id = 722, parent_id = 65535, m_game_vertex_id = 2, position = vec(0, 0, 0), online = true,
	section_name = function() return "chimera_weak" end, clsid = function() return 55 end }
shooter.active_item = function() return { section = function() return "wpn_axe" end } end
Hm.env.coop_route = { domain_handlers = function(cb) return {} end }
fire(Ms, "monster_on_before_hit", Ms.objects[722], { power = 1, type = 1, draftsman = shooter }, 1)
pump()
local player_far = Hm.env.coop_quests_far.object(500)
check(player_far:active_item() and player_far:active_item():section() == "wpn_axe", "nta_utils.is_axe reads it from the stand-in")
Hm.tm.task_info.simulation_task_vengence_amplified = nil

print("== a vehicle")
local cars = {}
Hm.env.coop_route = { domain_handlers = function(cb) return cb == "vehicle_on_death_callback" and { function(o) cars[#cars + 1] = o:id() end } or {} end }
fire(Ms, "vehicle_on_death_callback", Ms.npc)
pump()
check(cars[1] == 700, "its death reaches the task on the world server")

print("== the dialogs' mirror: a map server's level is told by its map server")
do
	-- "everybody" of a map server: the players of its level, through the world, from 0
	local send = Ms.env.coop.send_event
	Ms.env.coop.send_event = function(name, payload, target)
		if target == -1 or target == nil then
			Ms.sent[#Ms.sent + 1] = { name = name, payload = payload, target = -1 }
			QUEUE[#QUEUE + 1] = { to = Cm, name = name, payload = payload, from = 0 }
			return true
		end
		return send(name, payload, target)
	end
	local ids = { 730, 731 }
	local squad = {}
	function squad:squad_members()
		local i = 0
		return function() i = i + 1; return ids[i] and { id = ids[i] } or nil end
	end
	for i, id in ipairs(ids) do
		local o = Ms.new_obj(id, "bandit", vec(0, 0, 0), { _stalker = true })
		Ms.env.db.storage[id] = { object = o, pstor = { s_loot_count = i == 1 and 5 or 4 } }
	end
	for _, M in ipairs({ Hm, Ms }) do
		M.env.get_story_squad = function(sid) return sid == "bandit_companion_task_1" and squad or nil end
	end
	Ms.env.db.anomaly_by_name.jup_b32_anomal_zone = { spawned_count = 1 }
	for _ = 1, 3 do
		NOW = NOW + 1100
		fire(Ms, "actor_on_update")
		fire(Hm, "actor_on_update")
		pump()
	end
	check(count_sent(Ms, "quests.mirror") > 0, "the map server of the level sends what its zones and its NPCs hold")
	check(Cm.env.dialogs_jupiter.jup_b32_anomaly_has_af() == true, "the artefact in a zone of a map server's level is seen from the dialog")
	check(Cm.env.dialogs_darkvalley.bandit_companion_task_1_complete() == true, "the loot of the bandit companions on a map server's level is seen")
	local foreign = 0
	for _, s in ipairs(Hm.sent) do
		if s.name == "quests.mirror" then
			local k = Hm.env.coop_main.decode(s.payload).k
			if k == "bandit1" or tostring(k):find("b32:", 1, true) == 1 then foreign = foreign + 1 end
		end
	end
	check(foreign == 0, "the world server says nothing of zones and NPCs it does not have")
end

print("== the guide marker of a target for a player on a map server's level")
do
	local seen = {}
	function Hm.env.task_objects.CGeneralTask:check_level(target)
		seen[#seen + 1] = { target = target, level = Hm.env.level.name(), active = Hm.env.db.actor:is_active_task(self.t) }
	end
	records[960] = { id = 960, parent_id = 65535, m_game_vertex_id = 1, position = vec(0, 0, 0) }
	Hm.ini.far_marker_task = {}
	Hm.tm:give_task("far_marker_task", 700)
	local rt = Hm.tm.task_info.far_marker_task
	rt.current_target = 960
	Hm.handlers["coop_tq"]("op=sactive;i=sfar_marker_task", 1)
	NOW = NOW + 3000
	fire(Hm, "actor_on_update")
	check(seen[1] and seen[1].target == 960, "the stock check runs for his active task")
	check(seen[1] and seen[1].level == "k00_marsh", "from his level: the exit is on it")
	check(seen[1] and seen[1].active == true, "as the active task")
	Hm.tm.task_info.far_marker_task = nil
end

print("== the rating: a player on a map server's level is told which line is his")
do
	Hm.env.pda = {
		calculate_rankings = function() end,
		get_coc_ranking_list = function() return { 500 } end,
		get_rankings_array_size = function() return 1 end,
	}
	Hm.env.ranks = Hm.env.ranks or {}
	Hm.env.ranks.get_se_obj_rank_name = function() return "novice" end
	Hm.env.utils_obj = { get_reputation_name = function() return "rep" end }
	local r = records[500]
	r.character_name = function() return "player" end
	r.rank = function() return 100 end
	r.reputation = function() return 0 end
	r.character_icon = function() return "icon" end
	r.alive = function() return true end
	local sim = Hm.env.alife()
	function sim:object(id) return id == 500 and records[500] or nil end
	Hm.handlers["quests.rank_req"](Hm.env.coop_main.encode({ q = 1, r = 0 }), 1)
	local got = last_sent(Hm, "quests.rank")
	local list = got and Hm.env.coop_quests_core.des(got.d)
	check(list and list[1] and list[1].me == true, "the line of his record is marked")
end

print("== the rating of a world server whose seat plays no character: its ghost actor is nobody (owner 2026-11-13)")
do
	local qc = Hm.env.coop_quests_core
	local ghost = Hm.env.db.actor
	local rank0, name0 = ghost._rank, ghost._cname
	ghost._rank, ghost._cname = 99999, "server"
	Hm.env.pda.get_coc_ranking_list = function() return { 0, 500 } end
	Hm.env.pda.get_rankings_array_size = function() return 2 end
	local function ask()
		Hm.sent = {}
		Hm.handlers["quests.rank_req"](Hm.env.coop_main.encode({ q = 2, r = 0 }), 1)
		local got = last_sent(Hm, "quests.rank")
		return got and Hm.env.coop_quests_core.des(got.d) or {}, got and tonumber(got.w)
	end
	-- an ordinary host: its seat plays, its actor is the host player's character and stays in the list
	Hm.env.coop.is_dedicated = function() return false end
	check(qc.actor_is_nobody() == false, "an ordinary host's actor is somebody")
	local list, place = ask()
	check(#list == 2 and list[1].n == "server", "the playing host's character keeps its line")
	check(place == 2, "and counts above the player")
	-- a world server: the ghost has no line, no place above anyone
	Hm.env.coop.is_dedicated = function() return true end
	check(qc.actor_is_nobody() == true, "a world server's actor is nobody")
	list, place = ask()
	local named = false
	for _, e in ipairs(list) do if e.n == "server" then named = true end end
	check(not named and #list == 1 and list[1].me == true, "the ghost is not among the lines a client gets")
	check(place == 1, "the ghost's rank puts nobody lower")
	check(Ms.env.coop_quests_core.actor_is_nobody() == true, "a map server's actor is nobody")
	check(Cm.env.coop_quests_core.actor_is_nobody() == false, "a player's actor is somebody")
	Hm.env.coop.is_dedicated = nil
	ghost._rank, ghost._cname = rank0, name0
end

print("== the encyclopedia and the achievements of a map server's logic are the world's")
do
	Ms.players[1].nick = "fighter"
	fire(Hm, "actor_on_first_update")
	fire(Cm, "actor_on_first_update")
	fire(Ms, "actor_on_first_update")
	Ms.env.ui_pda_encyclopedia_tab.unlock_article("art_far")
	pump()
	check(Hm.unlocked.art_far == true, "an article its logic opened reaches the world server")
	check(Cm.unlocked.art_far == true, "and goes from there to the players")
	local relay = last_sent(Hm, "quests.ency")
	check(relay and relay.n == "fighter", "under the name of a player of that level, not the host's")
	fire(Ms, "actor_on_achievement_earned", "tourist")
	local up = last_sent(Ms, "quests.achv")
	check(up and up.n == "fighter", "an achievement goes the same way")
	local to_world = false
	for _, s in ipairs(Ms.sent) do if s.name == "quests.achv" and s.target == 0 then to_world = true end end
	check(to_world, "to the world server, not to its level alone")
end

print("== goodwill said of the actor lies on the players: what logic asks of the actor is theirs")
do
	local xc, npc = Ms.env.xr_conditions, Ms.npc
	local ghost = Ms.actor
	check(xc.actor_neutral(ghost, npc) == true and xc.actor_enemy(ghost, npc) == false, "nothing said yet: a neutral")
	npc._rel = { [500] = 2 }
	check(xc.actor_enemy(ghost, npc) == true, "an enemy of the player of the level is an enemy of the actor")
	check(xc.actor_true_enemy(ghost, npc) == true, "the invulnerable of story NPCs reads this one")
	check(xc.actor_neutral(ghost, npc) == false, "and no neutral")
	npc._rel = { [500] = 0 }
	check(xc.actor_friend(ghost, npc) == true and xc.actor_true_friend(ghost, npc) == true, "a friend of his is a friend")
	npc._rel = nil
	local proxy = Ms.objects[500]
	npc._rel = { [500] = 2 }
	check(xc.actor_enemy(proxy, npc) == true, "asked of a player: of him (combat_ignore passes the enemy)")
	npc._rel = nil
	check(Hm.env.xr_conditions.actor_enemy(Hm.actor, Cm.npc) == false, "on the world server stock")
end

print("== the end of a task runs where the player who ends it stands")
-- The quest audit, 2026-11-13: on_complete / on_fail / on_cancel ran on the world server "at home" (fake_start). The stock effects there
-- read the world around the actor: the giver's game object (inc_goodwill_by_tasker_id: 39 tasks without goodwill), the quest item to
-- take away (remove_quest_item), the actor's faction (the next DRX giver, 136 tasks), the first target of the task they give next.
do
	local ended = {}
	local function look(key)
		ended[key] = { level = Hm.env.level.name(), giver = Hm.env.level.object_by_id(700),
			storage = Hm.env.db.storage[700] and Hm.env.db.storage[700].object, peer = Hm.env.coop_tasks.reward_peer() }
	end
	Hm.ini.end_task = {}
	Cm.ini.end_task = {}
	Hm.on_complete = Hm.on_complete or {}
	Hm.on_complete.end_task = function() look("complete") end
	-- the player of level 2 took it from the NPC there and turns it in
	Cm.env.task_manager.get_task_manager():give_task("end_task", 700)
	pump()
	check(Hm.tm.task_info.end_task ~= nil and Hm.env.coop_tasks.taker("end_task") == 1, "the player's task is on the world server")
	Cm.env.task_manager.get_task_manager():set_task_completed("end_task")
	pump()
	Hm.env.task_manager.task_callback(Hm.engine_tasks.end_task, Hm.env.task.completed)
	pump()
	check(ended.complete ~= nil, "the stock end of the task ran")
	check(ended.complete and ended.complete.level == "k00_marsh", "level.name is the level of the player who turned it in")
	check(ended.complete and ended.complete.giver and ended.complete.giver.far == true, "the giver is found there")
	check(ended.complete and ended.complete.storage ~= nil, "and db.storage has him: goodwill by the tasker has whom to ask")
	check(ended.complete and ended.complete.peer == 1, "the rewards are still his")
	check(Hm.env.level.name() == "l01_escape", "the far view is closed after the end")

	-- a task nobody of a map server's level has to do with ends at home, as before
	Hm.ini.home_task = {}
	Hm.on_complete.home_task = function() look("home") end
	Hm.tm:give_task("home_task", 960)
	Hm.env.task_manager.task_callback(Hm.engine_tasks.home_task, Hm.env.task.completed)
	check(ended.home and ended.home.level == "l01_escape", "a task of the world server's own level ends at home")

	-- a failure too
	local failed
	local stock_callback = Hm.env.coop_tasks and Hm.env.task_manager.task_callback
	Hm.ini.fail_task = {}
	Cm.ini.fail_task = {}
	Cm.env.task_manager.get_task_manager():give_task("fail_task", 700)
	pump()
	Hm.on_fail = { fail_task = function() failed = Hm.env.level.name() end }
	Hm.env.task_manager.task_callback(Hm.engine_tasks.fail_task, Hm.env.task.fail)
	check(failed == "k00_marsh", "a task that failed ends on the level of the player who took it")
	check(stock_callback == Hm.env.task_manager.task_callback and Hm.env.level.name() == "l01_escape", "and the view is closed")
end

print("== what a task makes at its start is not on the level yet, and a stand-in has no logic to set up")
-- The world server's log of 2026-11-13: "! request give task_fanat_training_1: _g.script:932: bad argument #1 to 'string_gmatch' (string
-- expected, got nil)". The task's on_init makes a squad next to the player (create_squad). The far view answered db.storage[new id]
-- with a stand-in ("near a player = online"), the stock smart terrain (select_npc_job -> setup_logic) ran xr_logic on it and died in
-- restrictor_manager (parse_names(npc:out_restrictions())). The give was refused in silence: the KMB at Fanat never started, and
-- "The Last Dawn" (two squads in on_init) was never given.
do
	local sim = Hm.env.alife()
	local made = 0
	function sim:create(sec, pos, lv, gv)
		made = made + 1
		local id = 740 + made
		records[id] = { id = id, parent_id = 65535, m_game_vertex_id = gv, m_level_vertex_id = lv, position = pos, online = false,
			section_name = function() return sec end, clsid = function() return 55 end, name = function() return sec end,
			alive = function() return true end }
		return records[id]
	end
	-- the stock smart terrain, select_npc_job: "if NPC has storage, it is online, so switch logic"
	local function job_of(id)
		local st = Hm.env.db.storage[id]
		if st and st.object then
			Hm.env.xr_logic.configure_schemes(st.object)
			Hm.env.xr_logic.activate_by_section(st.object, nil, Hm.env.xr_logic.determine_section_to_activate(st.object))
		end
	end
	local seen
	Hm.ini.spawn_task = {}
	Cm.ini.spawn_task = {}
	Hm.init_fx = { spawn_task = function()
		local se = Hm.env.alife():create("boar_weak", vec(11, 0, 10), 6, 2)
		seen = { id = se.id, level = Hm.env.level.name(), store = Hm.env.db.storage[se.id], obj = Hm.env.level.object_by_id(se.id) }
		job_of(se.id)
	end }
	Hm.logic_ran = {}
	Cm.env.task_manager.get_task_manager():give_task("spawn_task", 700)
	pump()
	check(seen ~= nil and seen.level == "k00_marsh", "on_init ran in the far view of the player's level")
	check(seen and seen.store == nil, "db.storage has no store of what was made this moment")
	check(seen and seen.obj == nil, "level.object_by_id: nil, as the stock answers before the spawn")
	check(#Hm.logic_ran == 0, "the smart terrain set no logic on it")
	check(Hm.tm.task_info.spawn_task ~= nil and Hm.env.coop_tasks.taker("spawn_task") == 1, "the task is given to the player")

	-- what stood next to the player before, not taken by its map server yet, is found as it was: a functor waits for it
	records[770] = { id = 770, parent_id = 65535, m_game_vertex_id = 2, m_level_vertex_id = 6, position = vec(11, 0, 10), online = false,
		section_name = function() return "boar_weak" end, clsid = function() return 55 end, name = function() return "boar" end,
		alive = function() return true end }
	local older, err_logic
	Hm.logic_ran = {}
	Hm.env.coop_quests_core.with_level_of(1, function()
		older = Hm.env.level.object_by_id(770)
		-- a squad that is there joins a smart (assign_squad_to_smart -> register_npc): its logic is its map server's, not a stand-in's
		err_logic = select(2, pcall(job_of, 700))
	end)
	check(older ~= nil and older.far == true, "a record near the player is a stand-in, as before")
	check(err_logic == nil, "the logic of a stand-in is not set up: no error of the stock")
	check(#Hm.logic_ran == 0, "the stock entry points did not run with a stand-in")
	-- a live object of the world server's own level: the stock, untouched
	Hm.logic_ran = {}
	Hm.env.xr_logic.configure_schemes(Hm.actor)
	Hm.env.xr_logic.switch_to_section(Hm.actor)
	check(#Hm.logic_ran == 2, "with a live object the stock logic runs")
end

print("== a story reward of a map server's logic that comes twice in a moment is one reward")
-- The quest audit, 2026-11-13 (risk R1): a map server does not have an info it gave until the world server's echo, so a line
-- `{-x} %+x =reward_item(...)%` of its logic can run again inside that round trip, and every run goes up as "share".
do
	local runs = 0
	Hm.env.xr_effects.reward_item = function(actor, npc, p) runs = runs + 1 end
	local function says(first)
		Ms.env.coop_quests_core.send("share", { f = "reward_item", p1 = first }, 0)
	end
	says("medkit")
	says("medkit")
	pump()
	check(runs == 1, "the same reward from the same level twice at once: given once")
	says("bandage")
	pump()
	check(runs == 2, "another reward is another")
	NOW = NOW + 5000
	says("medkit")
	pump()
	check(runs == 3, "the same one later is a new one")
end

print("== the spy with no player on his level: \"the actor\" is the player who took the task, not the ghost")
-- tasks_agent_rescue brings an offline spy to db.actor:position(). With nobody on the spy's level the nearest player is nobody and the
-- stock read the world server's ghost: the squad went to fake_start (the followers analysis, 2026-11-13).
do
	Hm.env.coop.is_dedicated = function() return true end
	records[780] = { id = 780, parent_id = 65535, m_game_vertex_id = 1, m_level_vertex_id = 1, position = vec(50, 0, 50), online = false,
		section_name = function() return "spy" end, clsid = function() return 44 end, name = function() return "spy" end,
		alive = function() return true end }
	Hm.ini.spy_far = { status_functor = "spy_task_status_functor" }
	Cm.ini.spy_far = { status_functor = "spy_task_status_functor" }
	Hm.env.save_var(Hm.actor, "spy_far", { target_id = 780 })
	local at
	Hm.env.task_status_functor.spy_task_status_functor = function() at = Hm.env.db.actor:position() end
	Cm.env.task_manager.get_task_manager():give_task("spy_far", 700)
	pump()
	check(Hm.env.coop_tasks.taker("spy_far") == 1, "the player of level 2 took it")
	Hm.tm.task_info.spy_far:check_task(Hm.tm)
	check(at ~= nil and at.x == 10 and at.z == 10, "the task reads the place of the player who took it")
	Hm.env.coop.is_dedicated = nil
	Hm.tm.task_info.spy_far = nil
	records[780] = nil
end

print("== a task a script gives belongs to the player next to its giver, on the giver's level")
-- The quest audit, 2026-11-13: nearest_taker measured to the world server's own characters only; a task given by logic or a timer was
-- written on the ghost (peer 0) and its rewards went to nobody.
do
	Hm.ini.script_task = {}
	Hm.tm:give_task("script_task", 700) -- no talk, no request, no reward scope
	check(Hm.env.coop_tasks.taker("script_task") == 1, "the player of the giver's level, not the world server's ghost")
	Hm.ini.nowhere_task = {}
	Hm.tm:give_task("nowhere_task", 31337) -- a giver that is no more
	check(Hm.env.coop_tasks.taker("nowhere_task") == 0, "with nobody to measure to: as before")
end

print("== a world hurt by a give that died: the info of the dialog is taken back, once")
-- Worlds played on builds 45-49: the dialog phrase gave its info, the give died on the world server, the dialog is closed for good.
do
	local T = Hm.env.coop_tasks
	for _, id in ipairs({ "task_fanat_training_1", "cs_task0_ambush_renegade_story", "cs_task0_ambush_renegade_story2" }) do Hm.ini[id] = {} end
	Hm.infos.fanat_training_start_done = true -- the Fanat's dialog is closed, the training was never the group's
	Hm.infos.cs_story_task0_ambush_renegade_start = true -- "The Last Dawn": asked for ...
	Hm.infos.renegade_cs_story_squad_1_death = true -- ... and it ran: its squad is dead
	Hm.infos.cs_story_task0_ambush_renegade_done = true -- its second part: the phrase was said ...
	Hm.tm.task_info.cs_task0_ambush_renegade_story2 = { id = "cs_task0_ambush_renegade_story2", stage = 0, status = "selected" } -- ... and it is on
	check(T.heal_lost_gives() == 1, "one give that was lost")
	check(Hm.infos.fanat_training_start_done == nil, "the Fanat offers his training again")
	check(Hm.infos.cs_story_task0_ambush_renegade_start == true, "a task that ran is left alone")
	check(Hm.infos.cs_story_task0_ambush_renegade_done == true, "a task that is on is left alone")
	Hm.tm.task_info.cs_task0_ambush_renegade_story2 = nil
	-- once a world: a task the player drops later on is his choice, the stock keeps its dialog closed
	local pstor = Hm.env.db.storage[0].pstor
	check(pstor.coop_lost_gives == true, "the world server looked when it started, and the world keeps that")
	pstor.coop_lost_gives = nil -- a world of an older build
	Hm.infos.fanat_training_start_done = true
	T._heal_once()
	check(Hm.infos.fanat_training_start_done == nil and pstor.coop_lost_gives == true, "an older world is looked at once")
	Hm.infos.fanat_training_start_done = true
	T._heal_once()
	check(Hm.infos.fanat_training_start_done == true, "and not again in this world")
	Hm.infos.fanat_training_start_done = nil
end

print("== roles")
check(Ms.env.coop_quests_core.host_party() == true, "a map server's logic pays players")
local Q = Ms.env.coop_tasks
Ms.env.coop.money_grant = function(peer, n) Ms.granted = { peer, n } return true end
Q.give_to_peer(1, 0, { "bread" })
check(Ms.created == nil or Ms.created[1].owner == 500, "give_to_peer on a map server: into his avatar, not its ghost")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
