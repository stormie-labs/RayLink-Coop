-- The guide job for every player (coop_quests_missions), the pump station's aggro and the spy's position (coop_quests_party).
-- Run: tools\test_lua.cmd mission_guide
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party", "coop_quests_story",
	"coop_quests_missions" }

-- the stock module's shape: two table locals, read and rebound by its functions (GAMMA tasks_guide.script)
local function stock_guide(M)
	local e = M.env
	M.reputation = 0
	e.game_statistics = { increment_reputation = function(n) M.reputation = M.reputation + n end }
	local guid, curr_guid = {}, {}
	e.coop_mods_core = {
		find_local = function(_, name) return name == "guid" and guid or name == "curr_guid" and curr_guid or nil end,
	}
	M.guide = { offer = function() return guid end, job = function() return curr_guid end }
	e.tasks_guide = {
		prec_1 = function(squad_id) return squad_id == guid.squad_id or squad_id == curr_guid.squad_id end,
		activate = function()
			curr_guid = {}
			for k, v in pairs(guid) do curr_guid[k] = v end
			guid = {}
			M.activated = (M.activated or 0) + 1
		end,
		complete = function()
			e.dialogs.relocate_money(e.db.actor, curr_guid.zarplata, "in")
			curr_guid = {}
			M.completed = (M.completed or 0) + 1
		end,
		fail_complete_late = function()
			if e.db.actor:money() >= curr_guid.neustoika then
				e.dialogs.relocate_money(e.db.actor, curr_guid.neustoika, "out")
			else
				e.dialogs.relocate_money(e.db.actor, e.db.actor:money(), "out")
			end
			curr_guid = {}
			M.failed = (M.failed or 0) + 1
		end,
		fail_partial_late = function() curr_guid.zarplata = curr_guid.zarplata / 2; e.game_statistics.increment_reputation(-100) end,
		squad_on_npc_death = function()
			e.game_statistics.increment_reputation(-1000)
			M.escort_deaths = (M.escort_deaths or 0) + 1
		end,
	}
end

local function setup_world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	M.on_complete = {}
	M.npc = M.new_obj(700, "stalker_guide", vec(5, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = M.npc }
	e.dialogs = e.dialogs or {}
	e.dialogs.relocate_money = function(who, n, typ)
		M.money_moves = M.money_moves or {}
		M.money_moves[#M.money_moves + 1] = { who = who:id(), n = n, typ = typ }
	end
	e.news_manager = e.news_manager or {}
	e.news_manager.send_tip = function(_, str) M.tips = M.tips or {}; M.tips[#M.tips + 1] = str end
	e.game.translate_string = function(s) return s == "st_jg_14" and "%s|%s|%s" or s end
	e.alife_object = e.alife_object or function() end
	stock_guide(M)
	e.get_object_squad = function() return { id = M.guide.job().squad_id or M.guide.offer().squad_id } end
	e.npe_actions = {}
	e.coop.story_local_task = function(id) M.local_task = id return true end
	M.spots = {}
	e.level.map_add_object_spot_ser = function(id) M.spots[id] = true end
	e.level.map_remove_object_spot = function(id) M.spots[id] = nil end
	e.tasks_guide.prec_5 = function() return M.at_target ~= false end
	M.ini.spy_t = { status_functor = "spy_task_status_functor" }
	-- the stock aggro asks about enemy id 0 only (tasks_pump_station_defense.script:193)
	M.pump = { M = { commander_id = 710, guards = { [711] = true } } }
	e.tasks_pump_station_defense = { aggro = function() return M.pump.stock end }
	local find = e.coop_mods_core.find_local
	e.coop_mods_core.find_local = function(m, name)
		if name == "M" then return M.pump.M end
		return find(m, name)
	end
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do M.env[n].on_game_start() end
	fire(M, "actor_on_first_update")
end

print("== setup")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup_world(Hm)
setup_world(Cm)
Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true })
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0)
boot(Hm)
boot(Cm)

print("== the offer reaches a client")
local guid_h = Hm.guide.offer()
guid_h.squad_id, guid_h.target_level, guid_h.zarplata, guid_h.neustoika, guid_h.id_smart = 900, "l02_garbage", 1000, 1500, 333
local function host_tick()
	NOW = NOW + 2500
	fire(Hm, "actor_on_update")
	pump()
end
Hm.env.alife_object = function(id)
	if id == 900 then return { commander_id = function() return 700 end } end
end
Hm.env.dynamic_news_helper = { GetPointDescription = function() return "at the bridge" end }
host_tick()
check(Cm.env.tasks_guide.prec_1(900) == true, "the client's dialog sees the offer: the stock test reads the mirrored table")
check(Cm.guide.offer().zarplata == 1000, "with its numbers")
local walking = { has_info = function(_, i) return i == "npcx_is_companion" end }
check(Cm.env.tasks_guide.prec_1(900, walking) == false, "a companion of the group does not get the offer's line again and again")
check(Cm.env.tasks_guide.prec_1(900, { has_info = function() return false end }) == true, "a stranger does")
check(Cm.tips and Cm.tips[1] == "l02_garbage|at the bridge|name_700", "the news of the offer on the client's PDA")
local sends = #Hm.sent
host_tick()
check(#Hm.sent == sends, "nothing changed: nothing is sent")

print("== a client takes the job")
local Rq = Cm.env.tasks_guide.activate
Rq(Cm.actor, Cm.npc)
check(Cm.activated == nil, "the client's stock function does not run")
Cm.npc._pos, Hm.npc._pos = vec(5, 0, 0), vec(5, 0, 0)
pump()
check(Hm.activated == 1, "the host moves the offer into the job")
check(Hm.guide.job().coop_taker == 1, "and remembers who took it")
host_tick()
check(Cm.env.tasks_guide.prec_1(900) == true and Cm.guide.job().squad_id == 900, "the client's dialog sees the running job")
check(Cm.guide.offer().squad_id == nil, "the offer is gone everywhere")
local squad_of = Cm.env.get_object_squad
Cm.env.get_object_squad = function() return { id = 900 } end
check(Cm.env.tasks_guide.prec_1(900, walking) == true, "the guide of the running job keeps his line")
Cm.env.get_object_squad = squad_of
check(Cm.spots[333] == true, "the target's map spot on the client")
NOW = NOW + 2000
Rq(Cm.actor, Cm.npc)
pump()
check(Hm.activated == 1, "the second take: the guard refuses it")

print("== a late job's fine comes from the taker")
local before_h, before_c = Hm.reputation, Cm.reputation
local salary = Hm.guide.job().zarplata
Hm.env.tasks_guide.fail_partial_late(); pump()
check(Hm.reputation == before_h - 100 and Cm.reputation == before_c - 100,
	"escort deadline reputation penalty is shared by the participants")
check(Hm.guide.job().zarplata == salary / 2, "shared penalty runs world/job state changes once")
before_h, before_c = Hm.reputation, Cm.reputation
Hm.env.tasks_guide.squad_on_npc_death(); pump()
check(Hm.reputation == before_h - 1000 and Cm.reputation == before_c - 1000 and Hm.escort_deaths == 1,
	"escort death penalty reaches both participants while the death handler runs once")
local grants = {}
Hm.env.coop.money_grant = function(peer, n) grants[#grants + 1] = { peer, n } return true end
Hm.env.coop.money_of = function(peer) return peer == 1 and 2000 or nil end
Hm.actor._money = 0
Hm.env.tasks_guide.fail_complete_late()
check(Hm.failed == 1, "the stock function ran")
check(#grants == 1 and grants[1][1] == 1 and grants[1][2] == -1500, "the fine is the taker's, against his ledger")
check(Hm.money_moves == nil or #Hm.money_moves == 0, "the host's money is untouched")

print("== a taker on a map server's level: no object of his here, the fine is still his")
guid_h = Hm.guide.offer()
Hm.env.tasks_guide.activate()
local far_job = Hm.guide.job()
far_job.squad_id, far_job.neustoika, far_job.coop_taker = 903, 1500, 1
far_job.coop_character = 500
local far_body = Hm.objects[500]
Hm.objects[500] = nil
Hm.actor._money = 5000
Hm.money_moves = {}
grants = {}
Hm.env.tasks_guide.fail_complete_late()
Hm.objects[500] = far_body
check(#grants == 1 and grants[1][1] == 1 and grants[1][2] == -1500, "the fine comes from him")
check(#Hm.money_moves == 0, "the host pays nothing")

print("== a host's own job: stock")
guid_h = Hm.guide.offer()
Hm.env.tasks_guide.activate()
local job = Hm.guide.job()
job.squad_id, job.neustoika = 901, 100
Hm.actor._money = 500
grants = {}
Hm.env.tasks_guide.fail_complete_late()
check(#grants == 0 and Hm.money_moves and Hm.money_moves[1].typ == "out", "no taker: the stock fine on the host")

print("== the client's turn-in pays him")
Hm.env.tasks_guide.activate()
job = Hm.guide.job()
job.squad_id, job.zarplata, job.coop_taker = 902, 1000, 1
job.coop_character = 500
host_tick()
Hm.money_moves = {}
grants = {}
Hm.at_target = false
NOW = NOW + 2000
Cm.env.tasks_guide.complete(Cm.actor, Cm.npc)
pump()
check(Hm.completed == nil, "not at the target: the host refuses, whatever the client's dialog said")
Hm.at_target = nil
NOW = NOW + 2000
Cm.env.tasks_guide.complete(Cm.actor, Cm.npc)
pump()
check(Hm.completed == 1, "the host runs the turn-in")
check(#grants == 1 and grants[1][1] == 1 and grants[1][2] == 1000, "the pay goes to the player who turned in")
host_tick()
check(Cm.spots[333] == nil, "the job is over: the spot goes")

print("== NPE tutorials are personal")
check(Hm.local_task == "task_npe_actions_default" and Cm.local_task == "task_npe_actions_default", "the tutorial task stays on each machine")

print("== pump station: shooting the guards is every player's")
Hm.objects = Hm.objects or {}
local pump_st = Hm.pump
local commander = Hm.new_obj(710, "pump_commander", vec(6, 0, 0), { _stalker = true })
local guard = Hm.new_obj(711, "pump_guard", vec(7, 0, 0), { _stalker = true })
local avatar = Hm.env.level.object_by_id(500)
commander.best_enemy = function() return nil end
guard.best_enemy = function() return nil end
check(not Hm.env.tasks_pump_station_defense.aggro(), "nobody shoots: no aggro")
guard.best_enemy = function() return avatar end
check(Hm.env.tasks_pump_station_defense.aggro() == true, "a guard is after a client: aggro, like the host")
guard.best_enemy = function() return commander end
Hm.env.db.storage[710] = { enemy_id = 500 }
check(Hm.env.tasks_pump_station_defense.aggro() == true, "the commander's stored enemy is a client")
Hm.env.db.storage[710] = { enemy_id = 711 }
check(not Hm.env.tasks_pump_station_defense.aggro(), "an NPC's enemy is nobody's business")
pump_st.stock = true
check(Hm.env.tasks_pump_station_defense.aggro() == true, "the host's own aggro stands")
pump_st.stock = nil

print("== the spy: \"the actor\" is the player nearest to him")
Hm.new_obj(720, "spy", vec(4, 0, 1), { _stalker = true })
Hm.env.alife_object = function(id) if id == 720 then return { position = vec(4, 0, 1), parent_id = 65535 } end end
Hm.env.save_var(Hm.actor, "spy_t", { target_id = 720 })
Hm.actor._pos = vec(1000, 0, 0)
local seen
Hm.env.task_status_functor.spy_task_status_functor = function() seen = Hm.env.db.actor:position() end
Hm.tm:give_task("spy_t", 700)
Hm.tm.task_info.spy_t:check_task(Hm.tm)
check(seen and seen.x == 4, "the task reads the client near the spy, not the far host")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
