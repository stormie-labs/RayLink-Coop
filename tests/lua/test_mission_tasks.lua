-- Mission fixes, part 2 (coop_tasks, coop_quests_party): money tasks read the taker's balance (audit B finding 2 / A item 7),
-- multifetch counts and takes from the whole party (B finding 5), a dialog hand-over a client cannot cover alone is taken from
-- the group (B section 7), the task_target_anomaly vars are the group's (B section 7), the Sakharov upgrade wait starts when the
-- host gives the task (A T5).
-- Run: tools\test_lua.cmd mission_tasks
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party", "coop_quests_story" }

local function setup_world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	M.on_complete = {}
	M.ini.cf_task = { status_functor = "drx_sl_money_task_status" }
	M.ini.mf_task = { status_functor = "multifetch_status_functor" }
	M.ini.helm_task = { status_functor = "check_if_enough_time_passed" }
	M.ini.other_task = {}
	M.npc = M.new_obj(700, "esc_m_trader", vec(5, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = M.npc }
	-- DRX money task: stock reads the money of db.actor
	e.task_status_functor.drx_sl_money_task_status = function(tsk, id)
		local need = tonumber(e.load_var(e.db.actor, id .. "_fetch", 0))
		tsk.stage = e.db.actor:money() >= need and 1 or 0
	end
	e.xr_effects.drx_sl_money_task_payment = function(a, npc, p)
		e.db.actor:give_money(-(tonumber(e.load_var(e.db.actor, p[1], 0))))
	end
	e.xr_effects.drx_sl_change_factions = function(a, npc, p) M.faction = p[1] end
	-- tasks_multifetch: 3 bread, counted, taken and paid through db.actor:iterate_inventory
	e.task_status_functor.multifetch_status_functor = function(tsk, id)
		local found = 0
		e.db.actor:iterate_inventory(function(_, it) if it:section() == "bread" then found = found + 1 end end, e.db.actor)
		tsk.stage = found >= 3 and 1 or 0
	end
	e.xr_effects.multifetch_remove = function(a, b, c)
		local todel, payout = {}, 0
		e.db.actor:iterate_inventory(function(_, it)
			if it:section() == "bread" and #todel < 3 then todel[#todel + 1] = it:id(); payout = payout + 100 end
		end, e.db.actor)
		for _, id in ipairs(todel) do e.alife_release_id(id) end
		M.mf_taken = #todel
		e.db.actor:give_money(payout)
		e.news_manager.relocate_money(e.db.actor, "in", payout)
	end
	e.xr_effects.multifetch_task_trigger_extra_items_condlist = function(a, b, c)
		local n = 0
		e.db.actor:iterate_inventory(function(_, it) if it:section() == "bread" then n = n + 1 end end, e.db.actor)
		M.mf_extra_seen = n
	end
	-- Sakharov's wait
	M.ctimes = {}
	e.save_ctime = function(obj, k, v) M.ctimes[k] = v end
	e.load_ctime = function(obj, k) return M.ctimes[k] end
	-- itms_manager: the relocate the dialogs use
	e.itms_manager = {
		relocate_item_from_actor = function(actor, npc, section, amount)
			M.reloc = M.reloc or {}
			local left = amount
			actor:iterate_inventory(function(_, it)
				if left > 0 and it:section() == section then actor:transfer_item(it, npc); left = left - 1 end
			end, nil)
			if left > 0 then M.reloc_short = (M.reloc_short or 0) + left end
			M.reloc[#M.reloc + 1] = { section, amount }
		end,
	}
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
local proxy = Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true })
local host_av = Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0)
-- the host ledger (coop.money_of): balances per peer, the host's actor money is peer 0
local BAL = { [0] = 0, [1] = 0 }
Hm.env.coop.money_of = function(peer) return BAL[peer] end
boot(Hm)
boot(Cm)

local function money_grants(M)
	local out = {}
	for _, c in ipairs(M.money_calls) do
		if c.fn == "money_grant" and c.ok then out[#out + 1] = { c.peer, c.n } end
	end
	return out
end

local function fx_events(M)
	local n = 0
	for _, s in ipairs(M.sent) do
		if s.name == "coop_trw" and s.payload:find("fx", 1, true) then n = n + 1 end
	end
	return n
end

local function turn_in(id, peer)
	-- what the engine does for a finished task: finisher noted, then the task callback with the stock on_complete
	Hm.env.coop_tasks.host_note(id, "finisher", peer)
	local tsk = { get_id = function() return id end }
	Hm.env.task_manager.task_callback(tsk, Hm.env.task.completed)
end

-- ---------------------------------------------------------------- money tasks
print("== money task: the taker's balance decides the stage")
Hm.env.save_var(Hm.actor, "cf_task_fetch", 700)
Cm.env.task_manager.get_task_manager():give_task("cf_task", 700)
pump()
check(Hm.env.coop_tasks.taker("cf_task") == 1, "the client took the task")
Hm.actor._money = 5000 -- a rich host
BAL[0], BAL[1] = 5000, 100
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.cf_task.stage == 0, "poor taker, rich host: the task is not ready")
Hm.actor._money = 0 -- a poor host
BAL[0], BAL[1] = 0, 900
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.cf_task.stage == 1, "rich taker, poor host: the task is ready")
check(Hm.actor:money() == 0, "the host's actor money is the host's again after the check")

print("== money task: the host's own task reads the host")
Hm.ini.cf_host = { status_functor = "drx_sl_money_task_status" }
Cm.ini.cf_host = Hm.ini.cf_host
Hm.env.save_var(Hm.actor, "cf_host_fetch", 500)
Hm.env.task_manager.get_task_manager():give_task("cf_host", 700)
Hm.actor._money = 600
BAL[0], BAL[1] = 600, 0
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.cf_host.stage == 1, "taker = host: enough money, ready")
Hm.actor._money = 100
BAL[0] = 100
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.cf_host.stage == 0, "taker = host: short, not ready")
Hm.tm.task_info.cf_host = nil

print("== money task: a client without the money cannot turn it in")
BAL[1] = 100
Cm.env.task_manager.get_task_manager():set_task_completed("cf_task")
pump()
check(Hm.tm.task_info.cf_task.forced_status == nil, "a short finisher: the host does not complete the task")
check(has_log(Hm, "not enough money") , "...and says why")
BAL[1] = 900
Cm.env.task_manager.get_task_manager():set_task_completed("cf_task")
pump()
check(Hm.tm.task_info.cf_task.forced_status == "complete", "enough money: the turn-in goes through")
Hm.tm.task_info.cf_task.forced_status = nil

print("== money task: payment taken from the finisher's ledger, nothing for a short one")
Hm.on_complete.cf_task = function()
	Hm.env.xr_effects.drx_sl_money_task_payment(Hm.actor, nil, { "cf_task_fetch" })
	Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" })
end
local g0, f0 = #money_grants(Hm), fx_events(Hm)
turn_in("cf_task", 1)
local g = money_grants(Hm)
check(#g == g0 + 1 and g[#g][1] == 1 and g[#g][2] == -700, "enough money: coop.money_grant(1, -700)")
pump()
check(fx_events(Hm) == f0 + 1 and Cm.faction == "dolg", "enough money: the faction changes on the finisher's machine")
-- the same turn-in when the balance dropped meanwhile: no payment, no free faction
Cm.faction = nil
Hm.tm.task_info.cf_task = { id = "cf_task", stage = 1 }
BAL[1] = 100
g0, f0 = #money_grants(Hm), fx_events(Hm)
turn_in("cf_task", 1)
pump()
check(#money_grants(Hm) == g0, "short at the callback: nothing taken")
check(fx_events(Hm) == f0 and Cm.faction == nil, "short at the callback: no faction change for free")
-- the host turns a task of its own in: untouched stock
Hm.faction = nil
Hm.actor._money = 1000
Hm.env.save_var(Hm.actor, "cf_host_fetch", 400)
Hm.on_complete.cf_host = function()
	Hm.env.xr_effects.drx_sl_money_task_payment(Hm.actor, nil, { "cf_host_fetch" })
	Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "army" })
end
Hm.tm.task_info.cf_host = { id = "cf_host", stage = 1 }
Hm.env.coop_tasks.host_note("cf_host", "finisher", 0)
Hm.env.task_manager.task_callback({ get_id = function() return "cf_host" end }, Hm.env.task.completed)
check(Hm.actor._money == 600 and Hm.faction == "army", "the host's own turn-in: stock payment and faction")

-- ---------------------------------------------------------------- multifetch
print("== multifetch: the whole party counts")
Hm.tm.task_info = {}
Hm.actor._inv = {}
proxy._inv = {}
Cm.env.task_manager.get_task_manager():give_task("mf_task", 700)
pump()
Hm.give_item(Hm.actor, "bread")
Hm.give_item(proxy, "bread")
Hm.give_item(proxy, "bread")
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.mf_task.stage == 1, "1 bread with the host and 2 with the client: ready")
check(Hm.actor.iterate_inventory ~= nil and Hm.count(Hm.actor, "bread") == 1, "db.actor:iterate_inventory is the plain one again after the check")
proxy._inv = {}
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.mf_task.stage == 0, "the client gave the bread away: back to not ready")

print("== multifetch: the turn-in takes and pays from the party")
Hm.give_item(proxy, "bread")
Hm.give_item(proxy, "bread")
Hm.env.task_manager.get_task_manager():update()
Hm.on_complete.mf_task = function()
	Hm.env.xr_effects.multifetch_remove(Hm.actor, nil, { "mf_task", "true" })
end
local hm0, g1 = Hm.actor._money, #money_grants(Hm)
turn_in("mf_task", 1)
check(Hm.mf_taken == 3, "all 3 bread taken")
check(Hm.count(Hm.actor, "bread") == 0 and Hm.count(proxy, "bread") == 0, "from the host and from the client")
g = money_grants(Hm)
check(#g == g1 + 1 and g[#g][1] == 1 and g[#g][2] == 300, "the 300 for 3 bread go to the finisher through the ledger")
check(Hm.actor._money == hm0, "the host's actor got no money")
check(Hm.actor.iterate_inventory ~= nil, "db.actor:iterate_inventory is the plain one afterwards")

print("== multifetch: optional items are counted over the party too")
Hm.give_item(Hm.actor, "bread")
Hm.give_item(proxy, "bread")
Hm.env.xr_effects.multifetch_task_trigger_extra_items_condlist(Hm.actor, nil, { "mf_task" })
check(Hm.mf_extra_seen == 2, "optional items: the client's count too")

print("== multifetch: nobody else connected, the plain stock")
for _, M in ipairs({ Hm, Cm }) do M.active = false end
Hm.mf_extra_seen = nil
Hm.env.xr_effects.multifetch_task_trigger_extra_items_condlist(Hm.actor, nil, { "mf_task" })
check(Hm.mf_extra_seen == 1, "no session: the host's own inventory only")
for _, M in ipairs({ Hm, Cm }) do M.active = true end

-- ---------------------------------------------------------------- Sakharov's wait
print("== upgrade wait starts when the host gives the task")
Hm.tm.task_info = {}
Cm.env.task_manager.get_task_manager():give_task("helm_task", 700)
pump()
check(Hm.tm.task_info.helm_task ~= nil, "the host gave the task")
check(Hm.ctimes.helm_task ~= nil, "the wait is timed from the host's give (the client's own ctime cannot travel)")
-- a time the client's earlier give left among the task vars would be a stale wait: the give restamps
Hm.ctimes.helm_task = "stale"
Hm.tm.task_info.helm_task = nil
Hm.engine_tasks = Hm.engine_tasks or {}
Hm.engine_tasks.helm_task = nil
Cm.env.task_manager.get_task_manager():give_task("helm_task", 700)
pump()
check(Hm.ctimes.helm_task ~= "stale", "a second give restarts the wait")
Hm.tm.task_info.other_task = nil
Cm.env.task_manager.get_task_manager():give_task("other_task", 700)
pump()
check(Hm.ctimes.other_task == nil, "other tasks get no time")

-- ---------------------------------------------------------------- task_target_anomaly
print("== task_target_anomaly vars are the group's")
Hm.env.save_var(Hm.actor, "task_target_anomaly", "zone_x")
Hm.env.save_var(Hm.actor, "task_target_anomaly_level", "l01_escape")
tick(Hm)
pump()
check(Cm.env.load_var(Cm.actor, "task_target_anomaly") == "zone_x" and Cm.env.load_var(Cm.actor, "task_target_anomaly_level") == "l01_escape",
	"the host's target anomaly is mirrored to the client")
Cm.env.save_var(Cm.actor, "task_target_anomaly_analyzed", true)
pump()
check(Hm.env.load_var(Hm.actor, "task_target_anomaly_analyzed") == true, "a client's write goes to the host")
Hm.env.save_var(Hm.actor, "task_target_anomaly", nil)
Hm.env.db.storage[0].pstor.task_target_anomaly = nil
tick(Hm)
pump()
check(Cm.env.load_var(Cm.actor, "task_target_anomaly") == nil, "cleared on the host: cleared on the client")
Cm.env.save_var(Cm.actor, "task_target_anomalyx_other", 1)
check(Cm.env.load_var(Cm.actor, "task_target_anomalyx_other") == 1, "(prefix match is the whole contract: another key of that name is shared too)")

-- ---------------------------------------------------------------- dialog hand-over of a group item
print("== a hand-over a client cannot cover alone is taken from the group")
Hm.actor._inv, proxy._inv, Hm.npc._inv, Cm.actor._inv, Cm.npc._inv = {}, {}, {}, {}, {}
Cm.env.itms_manager.relocate_item_from_actor(Cm.actor, Cm.npc, "bread", 2)
check(Cm.reloc_short == nil, "the client's own relocate never runs short (no 'not enough item')")
Hm.give_item(Hm.actor, "bread")
Hm.give_item(Hm.actor, "bread")
pump()
check(Hm.count(Hm.npc, "bread") == 2 and Hm.count(Hm.actor, "bread") == 0, "the host handed the 2 bread of the group to the NPC")
-- the client has one of two: its own goes through the engine, the host adds the missing one
Cm.reloc, Cm.reloc_short = nil, nil
Cm.give_item(Cm.actor, "bread")
Hm.give_item(proxy, "bread") -- (the client's own copy on the host; the engine moves it with the client's transfer)
Hm.give_item(Hm.actor, "bread")
Cm.env.itms_manager.relocate_item_from_actor(Cm.actor, Cm.npc, "bread", 2)
pump()
check(Cm.reloc and Cm.reloc[1][2] == 1 and Cm.reloc_short == nil, "own part: relocated with the amount it has")
check(Hm.count(Hm.actor, "bread") == 0, "the missing one came from the host")
-- enough of its own: untouched
Cm.reloc = nil
Cm.give_item(Cm.actor, "bread")
Cm.give_item(Cm.actor, "bread")
local sent_before = count_sent(Cm, "quests.act")
Cm.env.itms_manager.relocate_item_from_actor(Cm.actor, Cm.npc, "bread", 2)
check(Cm.reloc and Cm.reloc[1][2] == 2 and count_sent(Cm, "quests.act") == sent_before, "enough of its own: stock, nothing asked")
-- not the client's own actor, or nobody to hand to: stock
sent_before = count_sent(Cm, "quests.act")
Cm.env.itms_manager.relocate_item_from_actor(Cm.actor, nil, "bread", 5)
check(count_sent(Cm, "quests.act") == sent_before, "no NPC to hand to: stock")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
