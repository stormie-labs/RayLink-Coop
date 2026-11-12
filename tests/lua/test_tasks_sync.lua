-- Tasks for every player, no host-only exceptions (temp\tasks_sync_audit_core.md): the shared vars never wipe a client (C2),
-- statistics, rank and reputation of a task go to the player who turned it in (C3), a dead host still runs the tasks (C4),
-- a stub answers like a task object (C5), the storyline fade reaches clients (C6), each player keeps his active task (C8),
-- stash coordinates go to the finisher (C9), a client's absolute write stays absolute (C10), a stub always has a stage
-- (C11), long task lists travel in parts (C12), a script's task belongs to the nearest player (C13), multifetch item marks
-- on a client (C14), a client's effects survive a missed event (C15), one pstor walk per scan (C16).
-- Run: tools\test_lua.cmd tasks_sync
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_reward_group", "coop_tasks", "coop_quests_news", "coop_quests_pda" }

local function setup_world(M)
	local e = M.env
	M.share = 0
	e.get_console = function()
		return { get_integer = function(_, name) return name == "coop_share_rewards" and M.share or 0 end }
	end
	M.ObjMT.money = function(self) return self._money or 0 end
	M.on_complete = {}
	for _, id in ipairs({ "t_a", "t_b", "t_c", "t_d", "t_e", "t_f", "t_fs", "t_g", "a", "a_b", "a0", "t_mf", "t_story" }) do M.ini[id] = {} end
	M.ini.t_story.storyline = true
	M.ini.t_mf = { status_functor = "multifetch_status_functor", required_item_1 = "bread", required_item_2 = "vodka",
		optional_item_1 = "medkit" }
	e.task_manager.task_ini.r_bool_ex = function(_, id, key, def)
		local v = M.ini[id] and M.ini[id][key]
		if v == nil then return def end
		return v == true
	end
	e.task_manager.task_ini.line_exist = function(_, id, key) return M.ini[id] ~= nil and M.ini[id][key] ~= nil end
	M.storage_state = {}
	e.alife_storage_manager = { get_state = function() return M.storage_state end }

	-- what the stock task callback and the stock effects do to the statistics
	M.stats, M.rank, M.rept = {}, 0, 0
	e.game_statistics = {
		increment_statistic = function(name) M.stats[#M.stats + 1] = name end,
		increment_rank = function(v) M.rank = M.rank + v end,
		increment_reputation = function(v) M.rept = M.rept + v end,
	}
	local stock_cb = e.task_manager.task_callback
	e.task_manager.task_callback = function(tsk, state)
		local rt = M.tm.task_info[tsk:get_id()]
		if rt then
			local name = state == e.task.completed and "tasks_completed"
				or rt.cancelled_by_actor and "tasks_cancelled" or "tasks_failed"
			e.game_statistics.increment_statistic(name)
		end
		return stock_cb(tsk, state)
	end
	e.xr_effects.increase_rank = function(a, n, p) e.game_statistics.increment_rank(tonumber(p[1])) end
	e.xr_effects.decrease_rep = function(a, n, p) e.game_statistics.increment_reputation(-tonumber(p[1])) end
	e.xr_effects.give_task = function(actor, obj, p) M.tm:give_task(p[1]) end
	e.xr_effects.drx_sl_change_factions = function(a, n, p) M.faction = p[1] end

	M.fades = {}
	e.actor_menu = { set_fade_msg = function(msg, t, _, snd) M.fades[#M.fades + 1] = { msg = msg, snd = snd } end }

	-- stock stashes: the spot and the line, inside treasure_manager.set_random_stash
	M.treasure_lines = {}
	e.news_manager.send_treasure = function(param, text)
		M.treasure_lines[#M.treasure_lines + 1] = { param = param, text = text }
	end
	e.treasure_manager = {
		set_random_stash = function(no_spot, hint, bonus, id)
			e.news_manager.send_treasure(0)
			return id or 4242
		end,
	}
	e.dynamic_news_helper = { GetPointDescription = function(obj) return "near " .. tostring(obj and obj.id) end }

	M.unique_calls = {}
	e.AddUniqueCall = function(f) M.unique_calls[#M.unique_calls + 1] = f end
	e.task_objects.CGeneralTask.get_title = function() return "" end
	M.active_task = nil
	M.ObjMT.is_active_task = function(_, t) return t ~= nil and M.active_task == t end
	M.ObjMT.set_active_task = function(_, t) M.active_task = t end
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do M.env[n].on_game_start() end
	fire(M, "actor_on_first_update")
	fire(M, "actor_on_reinit")
end

print("== setup")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup_world(Hm)
setup_world(Cm)
Hm.new_obj(500, "coop_player_avatar", vec(100, 0, 0), { _stalker = true })
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(100, 0, 0)
boot(Hm)
boot(Cm)

local HP, CP = Hm.env.db.storage[0].pstor, Cm.env.db.storage[0].pstor

-- CGameTaskManager::UpdateTasks
local function engine_check(M)
	for id, t in pairs(M.engine_tasks) do
		if t.state == "in" then
			if M.env.task_manager.task_complete(id) then
				t.state = "done"
				M.env.task_manager.task_callback(t, M.env.task.completed)
			elseif M.env.task_manager.task_fail(id) then
				t.state = "fail"
				M.env.task_manager.task_callback(t, M.env.task.fail)
			end
		end
	end
end

local function max_payload(M, name)
	local n, biggest = 0, 0
	for _, s in ipairs(M.sent) do
		if s.name == name then
			n = n + 1
			if #s.payload > biggest then biggest = #s.payload end
		end
	end
	return n, biggest
end

local function shared_count(ps, prefix)
	local n = 0
	for k in pairs(ps) do if k:sub(1, #prefix) == prefix then n = n + 1 end end
	return n
end

-- ---------------------------------------------------------------- C2
print("== C2: past the size of one message the shared vars are split, a client's keys are never wiped")
do
	-- the join save brought a key the host still has and one it has dropped
	CP.drx_sl_task_giver_1 = 2
	CP.drx_sl_old_key = 1
	HP.drx_sl_task_giver_1 = 2
	tick(Hm)
	pump()
	check(CP.drx_sl_old_key == 1, "a delta does not touch a key nobody changed")
	for i = 1, 500 do HP["drx_sl_npc_stored_task_" .. i] = string.rep("x", 40) .. i end
	check(#tostring(table.concat({ string.rep("y", 60 * 500) })) > 12000, "the set is over the old cap")
	Hm.sent = {}
	tick(Hm)
	pump()
	local n, biggest = max_payload(Hm, "coop_tv")
	check(n >= 2 and biggest <= 15800, "split over several events under the payload limit (" .. n .. " events, " .. biggest .. " characters)")
	check(shared_count(CP, "drx_sl_npc_stored_task_") == 500, "every key reached the client")
	check(CP.drx_sl_task_giver_1 == 2, "the client's other keys stay")

	-- one key changes: one small event, not the whole set
	Hm.sent = {}
	HP.drx_sl_npc_stored_task_7 = "changed"
	tick(Hm)
	pump()
	n, biggest = max_payload(Hm, "coop_tv")
	check(n == 1 and biggest < 200, "one change goes as one small event")
	check(CP.drx_sl_npc_stored_task_7 == "changed", "the change arrived")

	-- one key removed
	HP.drx_sl_npc_stored_task_8 = nil
	tick(Hm)
	pump()
	check(CP.drx_sl_npc_stored_task_8 == nil, "a removal arrived")

	-- a full sync (join): the stale key goes only with the last part
	local stale_during = {}
	local real = Cm.handlers.coop_tv
	Cm.handlers.coop_tv = function(p, f, nm)
		real(p, f, nm)
		stale_during[#stale_during + 1] = CP.drx_sl_old_key or false
	end
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	Cm.handlers.coop_tv = real
	check(#stale_during >= 2, "the full set came in parts (" .. #stale_during .. ")")
	check(stale_during[#stale_during - 1] == 1 and stale_during[#stale_during] == false, "the stale key was dropped by the last part only")
	check(shared_count(CP, "drx_sl_npc_stored_task_") == 499, "the full set kept every key")

	-- a lost part drops nothing
	CP.drx_sl_old_key = 1
	Hm.sent = {}
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	local kept = {}
	for _, e in ipairs(QUEUE) do
		if not (e.name == "coop_tv" and e.payload:find("_p=n1", 1, true)) then kept[#kept + 1] = e end
	end
	for i = #QUEUE, 1, -1 do QUEUE[i] = nil end
	pump() -- the request itself is still queued
	for i = #QUEUE, 1, -1 do
		if QUEUE[i].name == "coop_tv" and QUEUE[i].payload:find("_p=n1", 1, true) then table.remove(QUEUE, i) end
	end
	pump()
	check(CP.drx_sl_old_key == 1, "a full set with a part missing drops nothing")
	CP.drx_sl_old_key = nil
	-- a value too long for any message is kept on the client
	HP.drx_sl_huge = string.rep("z", 13000)
	CP.drx_sl_huge = "old"
	tick(Hm)
	pump()
	check(CP.drx_sl_huge == "old", "a value over the message size is not sent")
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	check(CP.drx_sl_huge == "old", "and a full sync does not drop it")
	check(has_log(Hm, "too long"), "the host says so")
	HP.drx_sl_huge = nil
	for i = 1, 500 do HP["drx_sl_npc_stored_task_" .. i] = nil end
	tick(Hm)
	pump()
	check(shared_count(CP, "drx_sl_npc_stored_task_") == 0, "removed in one go too")
end

-- ---------------------------------------------------------------- C10
print("== C10: a client's absolute write stays absolute, only the giver counters are deltas")
do
	HP.drx_sl_current_task_number = 5
	tick(Hm)
	pump()
	HP.drx_sl_current_task_number = 6 -- the host moved on, the client has not heard yet
	Cm.env.save_var(Cm.actor, "drx_sl_current_task_number", 1) -- reset by a dialog
	pump()
	check(HP.drx_sl_current_task_number == 1, "an absolute write arrives as a value, not as a delta against a stale mirror")
	HP.drx_sl_task_giver_9 = 4
	tick(Hm)
	pump()
	Cm.env.save_var(Cm.actor, "drx_sl_task_giver_9", 5)
	pump()
	check(HP.drx_sl_task_giver_9 == 5, "a giver counter is a delta")
	-- an unrelated change on the host does not put an unanswered local write back
	CP.drx_sl_local_write = "mine"
	HP.drx_sl_unrelated = 1
	tick(Hm)
	pump()
	check(CP.drx_sl_local_write == "mine", "an unrelated push leaves other keys alone")
	CP.drx_sl_local_write = nil
end

-- ---------------------------------------------------------------- C3
print("== C3: statistics, rank and reputation go to the player who turned the task in")
do
	-- rep_share "taker": the task's personal effects are the finisher's (the default "everyone": see rep_share below)
	Hm.env.coop_economy_core = { rule = function(k) return k == "rep_share" and "taker" or nil end }
	local function run(share)
		Hm.share = share
		local hs, cs = #Hm.stats, #Cm.stats
		Cm.tm:give_task("t_a", 9)
		pump()
		Cm.tm:set_task_completed("t_a")
		pump()
		engine_check(Hm)
		pump()
		check(#Hm.stats == hs, "mode " .. share .. ": rep_share taker keeps the statistics off the host, also with shared money")
		check(#Cm.stats == cs + 1 and Cm.stats[#Cm.stats] == "tasks_completed", "mode " .. share .. ": counted on the finisher's machine")
		Hm.tm.task_info.t_a = nil
		Hm.engine_tasks.t_a = nil
		tick(Hm)
		pump()
	end
	for _, share in ipairs({ 0, 1, 2, 3 }) do run(share) end
	Hm.share = 0

	-- failed and cancelled
	Cm.tm:give_task("t_b", 9)
	pump()
	Cm.tm:set_task_failed("t_b")
	pump()
	engine_check(Hm)
	pump()
	check(Cm.stats[#Cm.stats] == "tasks_failed", "a failed task counts on the finisher's machine")
	Cm.tm:give_task("t_c", 9)
	pump()
	Cm.tm:set_task_cancelled("t_c")
	pump()
	Hm.tm.task_info.t_c.cancelled_by_actor = true
	engine_check(Hm)
	pump()
	check(Cm.stats[#Cm.stats] == "tasks_cancelled", "a cancelled task counts on the finisher's machine")

	-- rank and reputation effects of the task's on_complete
	Cm.tm:give_task("t_d", 9)
	pump()
	Hm.on_complete.t_d = function()
		Hm.env.xr_effects.increase_rank(Hm.actor, nil, { "40" })
		Hm.env.xr_effects.decrease_rep(Hm.actor, nil, { "15" })
	end
	Cm.tm:set_task_completed("t_d")
	pump()
	engine_check(Hm)
	pump()
	check(Hm.rank == 0 and Hm.rept == 0, "the task's rank and reputation effects leave the host's actor alone")
	check(Cm.rank == 40 and Cm.rept == -15, "and run on the finisher's machine")

	-- the host's own task stays the host's
	local hs = #Hm.stats
	Hm.tm:give_task("t_e", 9)
	Hm.tm:set_task_completed("t_e")
	engine_check(Hm)
	check(#Hm.stats == hs + 1 and Hm.stats[#Hm.stats] == "tasks_completed", "the host's own task counts on the host")
	Hm.env.coop_economy_core = nil
end

-- ---------------------------------------------------------------- C15
print("== C15: effects on a player's character survive a missed event")
do
	Cm.tm:give_task("t_f", 9)
	pump()
	Hm.on_complete.t_f = function() Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "army" }) end
	Cm.tm:set_task_completed("t_f")
	pump()
	local actor = Cm.env.db.actor
	Cm.env.db.actor = nil -- level change: the client's actor is not there when the events arrive
	local stats0 = #Cm.stats
	engine_check(Hm)
	pump()
	Cm.env.db.actor = actor
	check(Cm.faction == nil and #Cm.stats == stats0, "nothing ran while the client had no actor")
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	check(Cm.faction == "army", "the faction change came with the next sync")
	check(#Cm.stats == stats0 + 1, "and the statistics")
	Cm.faction = nil
	-- a sync that crossed the answer brings an effect that ran already
	local last
	for _, e in ipairs(Hm.sent) do
		if e.name == "coop_trw" and e.payload:find("k=sstat", 1, true) then last = e.payload end
	end
	Cm.handlers.coop_trw(last, 0, "coop_trw")
	check(#Cm.stats == stats0 + 1, "an effect that ran already does not run twice")
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	check(Cm.faction == nil and #Cm.stats == stats0 + 1, "answered effects are not sent again")
end

print("== C15: what waits for an answer goes with the host's save")
do
	Cm.tm:give_task("t_fs", 9)
	pump()
	Hm.on_complete.t_fs = function() Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "ecolog" }) end
	Cm.tm:set_task_completed("t_fs")
	pump()
	local actor = Cm.env.db.actor
	Cm.env.db.actor = nil
	engine_check(Hm)
	pump()
	Cm.env.db.actor = actor
	local saved = {}
	fire(Hm, "save_state", saved)
	check(type(saved.coop_task_fx) == "table", "the host's save holds the effect nobody answered")
	fire(Hm, "load_state", {})
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	check(Cm.faction ~= "ecolog", "a save without it: nothing waits")
	fire(Hm, "load_state", saved)
	check(saved.coop_task_fx == nil, "the key is read once")
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	check(Cm.faction == "ecolog", "after the host's restart the effect reaches the player")
	Cm.faction = nil
end

-- ---------------------------------------------------------------- C4
print("== C4: while the host's actor is dead the task engine goes on")
do
	Hm.tm:give_task("t_g", 9)
	tick(Hm)
	pump()
	check(#Hm.unique_calls >= 1 and #Cm.unique_calls >= 1, "a frame call that does not depend on the actor binder is registered")
	local tick_dead = Hm.unique_calls[1]
	Hm.actor._dead = true
	local checks = Hm.checks or 0
	Hm.sent = {}
	Hm.tm.task_info.t_g.stage = 3
	NOW = NOW + 600
	check(tick_dead() == false, "the call stays registered")
	check((Hm.checks or 0) > checks, "task_manager:update runs without the actor binder")
	pump()
	check(Cm.tm.task_info.t_g.stage == 3, "the stage reached the client")
	Hm.actor._dead = nil
	checks = Hm.checks or 0
	NOW = NOW + 600
	tick_dead()
	check((Hm.checks or 0) == checks, "the live actor's binder does the update itself")
	Hm.tm.task_info.t_g = nil
	Hm.engine_tasks.t_g = nil
	tick(Hm)
	pump()
end

-- ---------------------------------------------------------------- C5
print("== C5: a stub answers t, current_target and storyline")
do
	Cm.engine_tasks.t_story = { state = "in", get_id = function() return "t_story" end,
		get_map_object_id = function() return 777 end }
	Hm.tm:give_task("t_story", 9)
	tick(Hm)
	pump()
	local stub = Cm.tm.task_info.t_story
	check(stub.coop_stub == true, "a stub")
	check(stub.t == Cm.engine_tasks.t_story, "t is the engine task")
	check(stub.current_target == 777, "current_target is the target of its spot")
	check(stub.storyline == true, "storyline")
	Cm.engine_tasks.t_story.get_map_object_id = function() return 65535 end
	check(stub.current_target == nil, "no spot, no target")
	Cm.engine_tasks.t_story = nil
	check(stub.t == nil and stub.current_target == nil, "no engine task yet: nil")
	check(Cm.tm.task_info.t_story.get_title ~= nil, "methods still answer")
	Cm.tm.task_info.t_story.current_target = nil
end

-- ---------------------------------------------------------------- C6
print("== C6: the storyline 'New task' fade and sound reach every player")
do
	local n = #Cm.fades
	Hm.env.coop_tasks.host_note("t_story", "taker", 0)
	-- the host's actor callback sends the line; the constructor of the task object shows the fade on the host
	local stub_task = { get_id = function() return "t_story" end, get_title = function() return "story_title" end,
		get_icon_name = function() return nil end }
	Hm.env.news_manager.send_task(Hm.actor, "new", stub_task)
	pump()
	check(#Cm.fades == n + 1, "one fade on the client")
	check(Cm.fades[#Cm.fades].msg:find("T(story_title)", 1, true) ~= nil, "with the task's title")
	check(Cm.fades[#Cm.fades].snd == "interface\\horror_notify_02", "and the stock sound")
	-- a secondary task: no fade
	NOW = NOW + 5000
	n = #Cm.fades
	local plain = { get_id = function() return "t_a" end, get_title = function() return "x" end, get_icon_name = function() return nil end }
	Hm.env.news_manager.send_task(Hm.actor, "new", plain)
	pump()
	check(#Cm.fades == n, "a secondary task has no fade")
	Hm.tm.task_info.t_story = nil
	Hm.engine_tasks.t_story = nil
	tick(Hm)
	pump()
end

-- ---------------------------------------------------------------- C8
print("== C8: each player keeps his active task")
do
	-- the host works on t_a; a client takes t_b: the host's active task stays
	Hm.tm:give_task("t_a", 9)
	local mine = Hm.engine_tasks.t_a
	Hm.active_task = mine
	-- GiveGameTaskToActor ends in SetActiveTask
	setmetatable(Hm.engine_tasks, { __newindex = function(t, k, v)
		rawset(t, k, v)
		Hm.active_task = v
	end })
	Cm.tm:give_task("t_b", 9)
	pump()
	check(Hm.active_task == mine, "a task a client took leaves the host's active task")
	Hm.engine_tasks.t_c = nil
	Hm.tm:give_task("t_c", 9)
	check(Hm.active_task == Hm.engine_tasks.t_c, "a task of the host's own takes the place, as in the stock game")
	Hm.tm.task_info.t_c = nil
	Hm.engine_tasks.t_c = nil
	setmetatable(Hm.engine_tasks, nil)
	Hm.active_task = mine
	-- the client who asked for it makes it his active task when the engine copy arrives
	Cm.engine_tasks.t_b = { state = "in", get_id = function() return "t_b" end }
	Cm.active_task = nil
	NOW = NOW + 1500
	fire(Cm, "actor_on_update")
	check(Cm.active_task == Cm.engine_tasks.t_b, "the one who took it gets it as his active task")
	-- the host learns it (guider spots)
	pump()
	check(Hm.env.coop_tasks.active_of(1) == "t_b", "the host knows the client's active task")
	for _, id in ipairs({ "t_a", "t_b" }) do
		Hm.tm.task_info[id] = nil
		Hm.engine_tasks[id] = nil
	end
	Cm.engine_tasks.t_b = nil
	tick(Hm)
	pump()
end

-- ---------------------------------------------------------------- C9
print("== C9: the stash coordinates line goes to the player who turned the task in")
do
	Cm.tm:give_task("t_c", 9)
	pump()
	Cm.new_obj(4321, "inv_box", vec(1, 0, 1))
	Hm.on_complete.t_c = function() Hm.env.treasure_manager.set_random_stash(nil, nil, nil, 4321) end
	local hl, cl_ = #Hm.treasure_lines, #Cm.treasure_lines
	Cm.tm:set_task_completed("t_c")
	pump()
	engine_check(Hm)
	pump()
	check(#Hm.treasure_lines == hl, "no line on the host")
	check(#Cm.treasure_lines == cl_ + 1 and Cm.treasure_lines[#Cm.treasure_lines].param == 0, "the line on the finisher's machine")
	check(Cm.treasure_lines[#Cm.treasure_lines].text == "near 4321", "with the place of the stash, computed on his machine")
	-- a host's own stash keeps the stock path
	Hm.tm:give_task("t_d", 9)
	Hm.on_complete.t_d = function() Hm.env.treasure_manager.set_random_stash(nil, nil, nil, 4322) end
	hl = #Hm.treasure_lines
	Hm.tm:set_task_completed("t_d")
	engine_check(Hm)
	check(#Hm.treasure_lines == hl + 1, "the host's own task: the line on the host")
end

-- ---------------------------------------------------------------- C11
print("== C11: a stub always has a stage")
do
	Hm.env.coop.send_event("coop_tl", "i=st_a", 1)
	pump()
	check(Cm.tm.task_info.t_a.stage == 0, "a record without a stage gives 0")
	Cm.tm.task_info.t_a = nil
end

print("== a task with more vars than one message keeps the client's vars")
do
	Hm.tm:give_task("t_d2", 9)
	Hm.ini.t_d2, Cm.ini.t_d2 = {}, {}
	HP.t_d2_fetch = "bread"
	tick(Hm)
	pump()
	check(CP.t_d2_fetch == "bread", "(a var mirrored)")
	HP.t_d2_huge = string.rep("q", 13000)
	tick(Hm)
	pump()
	check(CP.t_d2_fetch == "bread" and CP.t_d2_huge == nil, "the state went out without the vars, the client's stay")
	HP.t_d2_huge, HP.t_d2_fetch = nil, nil
	Hm.tm.task_info.t_d2 = nil
	Hm.engine_tasks.t_d2 = nil
	tick(Hm)
	pump()
end

-- ---------------------------------------------------------------- C12
print("== C12: more task records than one message holds")
do
	for i = 1, 450 do
		local id = "mass_task_" .. i
		Hm.ini[id], Cm.ini[id] = {}, {}
		Hm.tm.task_info[id] = setmetatable({ id = id, stage = 0, status = "selected" }, Hm.env.task_objects.CGeneralTask)
	end
	Hm.sent = {}
	tick(Hm)
	pump()
	NOW = NOW + 11000
	Hm.sent = {}
	Cm.tm.task_info.stray_here = {} -- a stray: the host does not have it
	tick(Hm)
	local n, biggest = max_payload(Hm, "coop_tl_list")
	check(n >= 3 and biggest <= 15800, "the digest list went in parts (" .. n .. " events, " .. biggest .. " characters)")
	check(not has_log(Hm, "digest check skipped"), "no skipped digest check")
	pump()
	check(Cm.tm.task_info.stray_here == nil, "the list as a whole dropped the stray")
	check(Cm.tm.task_info.mass_task_450 ~= nil and Cm.tm.task_info.mass_task_1 ~= nil, "no listed task dropped by a part")
	Cm.sent = {}
	NOW = NOW + 11000
	fire(Cm, "actor_on_update")
	check(count_sent(Cm, "coop_tl_req") == 0, "the client is synced: no sync loop")
	for i = 1, 450 do Hm.tm.task_info["mass_task_" .. i] = nil end
	tick(Hm)
	pump()
end

-- ---------------------------------------------------------------- C13
print("== C13: a task a script gave belongs to the player nearest to its giver")
do
	Hm.npc = Hm.new_obj(700, "npc", vec(95, 0, 0), { _stalker = true })
	Hm.tm:give_task("t_e", 700) -- no request, no dialog
	check(Hm.env.coop_tasks.taker("t_e") == 1, "the client stands next to the giver")
	Hm.tm.task_info.t_e = nil
	Hm.engine_tasks.t_e = nil
	Hm.npc._pos = vec(1, 0, 0)
	Hm.tm:give_task("t_e", 700)
	check(Hm.env.coop_tasks.taker("t_e") == 0, "the host stands next to the giver")
	Hm.tm.task_info.t_e = nil
	Hm.engine_tasks.t_e = nil
	-- a restrictor's condlist: the zone is the npc of the effect
	local zone = Hm.new_obj(701, "zone", vec(99, 0, 0))
	Hm.env.xr_effects.give_task(Hm.actor, zone, { "t_e" })
	check(Hm.env.coop_tasks.taker("t_e") == 1, "the zone of the effect counts as the giver")
	local news_by = Hm.env.coop_tasks.news_actor("new", "t_e")
	check(news_by == nil, "the news still say nobody did it")
	Hm.tm.task_info.t_e = nil
	Hm.engine_tasks.t_e = nil
	-- the host talks: its dialog
	Hm.talking = true
	Hm.tm:give_task("t_e", 700)
	Hm.talking = false
	check(Hm.env.coop_tasks.taker("t_e") == 0, "the host's dialog stays the host's")
	Hm.tm.task_info.t_e = nil
	Hm.engine_tasks.t_e = nil
	tick(Hm)
	pump()
end

-- ---------------------------------------------------------------- C14
print("== C14: multifetch item marks on a client")
do
	Hm.tm:give_task("t_mf", 9)
	tick(Hm)
	pump()
	local data = Cm.storage_state.multifetch_data
	check(data ~= nil and data.t_mf ~= nil, "the client's multifetch table knows the task")
	check(data.t_mf.required_items[1].sec == "bread" and data.t_mf.required_items[2].sec == "vodka", "required items, as the stock icon reads them")
	check(data.t_mf.optional_items[1].sec == "medkit", "optional items")
	Hm.tm.task_info.t_mf = nil
	Hm.engine_tasks.t_mf = nil
	tick(Hm)
	pump()
	check(Cm.storage_state.multifetch_data.t_mf == nil, "gone with the task")
end

-- ---------------------------------------------------------------- C16
print("== C16: one pstor walk per scan, the same vars per task")
do
	Hm.tm:give_task("a", 9)
	Hm.tm:give_task("a_b", 9)
	Hm.tm:give_task("a0", 9)
	HP.a = 1
	HP.a_fetch = "bread"
	HP.a_b_fetch = "vodka"
	HP.a0_fetch = "medkit"
	tick(Hm)
	pump()
	check(CP.a == 1 and CP.a_fetch == "bread" and CP.a_b_fetch == "vodka" and CP.a0_fetch == "medkit", "every task var mirrored")
	Hm.tm.task_info.a0 = nil
	Hm.engine_tasks.a0 = nil
	HP.a0_fetch = "medkit2"
	tick(Hm)
	pump()
	check(CP.a0_fetch == nil, "a task's vars go with it")
	check(CP.a_b_fetch == "vodka", "an id that is a prefix of another keeps its keys")
	Hm.tm.task_info.a = nil
	Hm.engine_tasks.a = nil
	tick(Hm)
	pump()
	check(CP.a_b_fetch == "vodka", "the longer id's key stays when the prefix id goes")
	Hm.tm.task_info.a_b = nil
	Hm.engine_tasks.a_b = nil
	HP.a, HP.a_fetch, HP.a_b_fetch, HP.a0_fetch = nil, nil, nil, nil
	tick(Hm)
	pump()
end

-- ---------------------------------------------------------------- C7
print("== C7: a language mismatch is told once")
do
	local lines = 0
	Cm.env.coop_quests_news.show_language = function() lines = lines + 1 end
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	check(lines == 0, "the same language: nothing")
	Hm.env.game.translate_string = function(s) return "RU(" .. tostring(s) .. ")" end
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	check(lines == 1, "another language: told")
	Cm.env.coop.send_event("coop_tl_req", "", 0)
	pump()
	check(lines == 1, "once")
end

-- ---------------------------------------------------------------- side note
print("== stage writes from the network stay in range")
do
	Cm.tm:give_task("t_f", 9)
	pump()
	Cm.env.coop.send_event("coop_tq", "op=sstage;i=st_f;st=n7000", 0)
	pump()
	check(Hm.tm.task_info.t_f.stage == 0, "a stage out of range is refused")
	Cm.env.coop.send_event("coop_tq", "op=sstage;i=st_f;st=n1.5", 0)
	pump()
	check(Hm.tm.task_info.t_f.stage == 0, "a fractional stage is refused")
	Cm.env.coop.send_event("coop_tq", "op=sstage;i=st_f;st=n2", 0)
	pump()
	check(Hm.tm.task_info.t_f.stage == 2, "a real one passes")
end

print("== the host's move: he stayed in his world, the world server's Lua is new")
do
	local sent_before = #Cm.sent
	Hm.tm.task_info.t_g = Hm.tm.task_info.t_g
	fire(Cm, "coop_world_back")
	local asked = false
	for i = sent_before + 1, #Cm.sent do
		if Cm.sent[i].name == "coop_tl_req" then asked = true end
	end
	check(asked, "he asks for the whole list: that also tells the new Lua who he is")
	pump()
end

print("== recipient scopes: absent avatars, nested recipients, error unwinding")
do
	local before_host, before_client = Hm.rept, Cm.rept
	local avatar_of = Hm.env.coop.avatar_of
	Hm.env.coop.avatar_of = function(peer) if peer ~= 1 then return avatar_of(peer) end end
	Hm.env.coop_tasks.with_recipient(1, function() Hm.env.game_statistics.increment_reputation(-140) end)
	check(Hm.rept == before_host, "missing client avatar must not redirect a personal penalty to the host")
	local saved = {}
	Hm.env.coop_tasks.save_effects(saved)
	check(saved.coop_task_fx ~= nil, "an absent client's personal effect is retained for acknowledgement")
	Hm.env.coop.avatar_of = avatar_of
	pump()
	check(Cm.rept == before_client - 140, "the queued personal penalty reaches the intended client")
	before_host, before_client = Hm.rept, Cm.rept
	Hm.env.coop_tasks.with_recipient(1, function()
		Hm.env.game_statistics.increment_reputation(10)
		Hm.env.coop_tasks.with_recipient(0, function() Hm.env.game_statistics.increment_reputation(20) end)
		Hm.env.game_statistics.increment_reputation(30)
	end)
	pump()
	check(Hm.rept == before_host + 20 and Cm.rept == before_client + 40,
		"nested host/client scopes restore their recipient instead of crediting the outer player")
	local ok = pcall(Hm.env.coop_tasks.with_recipient, 1, function() error("scope unwind probe") end)
	before_host = Hm.rept
	Hm.env.game_statistics.increment_reputation(7)
	pump()
	check(not ok and Hm.rept == before_host + 7, "an error cannot leave subsequent host events addressed to a client")
end

print("== disconnected recipient cannot become host")
do
	local T, E = Hm.env.coop_tasks, Hm.env
	local before = Hm.rept
	local avatar = E.coop.avatar_of
	T.with_recipient(1, function() end) -- remember the character while it is online
	E.coop.avatar_of = function() return nil end
	if T.recipient_body then
		local body = T.recipient_body(1)
		check(body and body:id() == 500, "recipient identity survives an absent avatar")
	else check(false, "recipient identity survives an absent avatar") end
	T.with_task_owner("t_f", function() E.game_statistics.increment_reputation(-99) end)
	check(Hm.rept == before, "timer of a client's task cannot fall back to host")
	E.coop.avatar_of = avatar
	local saved = {}; T.save_effects(saved)
	check(saved.coop_task_fx and saved.coop_task_fx.characters and saved.coop_task_fx.characters[1] == 500,
		"persistent effect queue stores character addresses, not reusable peer slots")
end

print("== shared task roster survives disconnect and peer reuse")
do
	local T, E = Hm.env.coop_tasks, Hm.env
	Hm.ini.rep_roster = {}; Hm.share = 3
	T.run_as(1, function() Hm.tm:give_task("rep_roster", 9) end)
	pump()
	local old_players, old_members = Hm.players, E.coop.members
	Hm.new_obj(501, "coop_player_avatar", vec())
	Hm.players = { {id=0,is_self=true,avatar_id=0}, {id=1,avatar_id=501} }
	E.coop.members = function() return {{id=500}, {id=501,peer=1,in_world=true}} end
	local hs, cs = #Hm.stats, #Cm.stats
	E.task_manager.task_callback({get_id=function() return "rep_roster" end}, E.task.fail)
	pump()
	check(#Hm.stats == hs + 1, "shared failure counts for the participating host")
	check(#Cm.stats == cs, "the new occupant of a peer slot receives no old participant's penalty")
	local saved={}; T.save_effects(saved)
	check(saved.coop_task_fx.wait and saved.coop_task_fx.wait[500] and not saved.coop_task_fx.wait[501],
		"offline participant's penalty waits under the original character")
	T.load_effects(saved)
	Hm.players, E.coop.members = old_players, old_members
	Cm.env.coop.send_event("coop_tl_req", "", 0); pump()
	check(#Cm.stats == cs + 1 and Cm.stats[#Cm.stats] == "tasks_failed", "original participant receives the saved penalty on return")
	Cm.env.coop.send_event("coop_tl_req", "", 0); pump()
	check(#Cm.stats == cs + 1, "repeated sync cannot duplicate the penalty")
	Hm.share = 0
end

print("== map-server personal effects pass through the world authority")
do
	local map = machine("client", 0x101)
	setup_world(map)
	map.env.coop.is_map_server = function() return true end
	map.players = {{id=0,avatar_id=10}, {id=1,avatar_id=500}}
	boot(map); pump()
	local before = Cm.rept
	map.env.coop_tasks.with_character(500, function() map.env.game_statistics.increment_reputation(-25) end)
	pump()
	check(Cm.rept == before - 25, "map-server penalty reaches the player once through host")
	local packet
	for _, message in ipairs(map.sent) do if message.name == "coop_rep_map" then packet = message.payload end end
	if packet then Hm.handlers.coop_rep_map(packet, 0x101); pump() end
	check(packet and Cm.rept == before - 25, "duplicate map-server penalty is acknowledged without a second application")
	if packet then Hm.handlers.coop_rep_map(packet, 1); pump() end
	check(Cm.rept == before - 25, "ordinary client cannot impersonate a map authority")
	local saved = {}; Hm.env.coop_tasks.save_effects(saved); Hm.env.coop_tasks.load_effects(saved)
	if packet then Hm.handlers.coop_rep_map(packet, 0x101); pump() end
	check(Cm.rept == before - 25, "map effect deduplication survives host save/load")
	local host_before, ghost_before = Hm.rept, map.rept
	map.env.coop_tasks.with_character(0, function() map.env.game_statistics.increment_reputation(-15) end)
	pump()
	check(Hm.rept == host_before - 15 and map.rept == ghost_before,
		"host player on another level receives his penalty, not the map server's ghost actor")
	map.env.coop_tasks.with_character(500, function()
		map.env.xr_effects.drx_sl_change_factions(map.actor, nil, {"freedom"})
	end)
	map.env.coop_tasks.with_character(0, function()
		map.env.xr_effects.drx_sl_change_factions(map.actor, nil, {"dolg"})
	end)
	pump()
	check(Cm.faction == "freedom" and Hm.faction == "dolg" and map.faction == nil,
		"personal faction changes on map server reach their real host/client characters")
end

print("== deferred guide fine follows the original character")
do
	local T, E = Hm.env.coop_tasks, Hm.env
	local original_players, original_members = Hm.players, E.coop.members
	local original_grant, original_money = E.coop.money_grant, E.coop.money_of
	local charged = {}
	E.coop.money_grant = function(peer, delta) charged[#charged+1] = {peer, delta}; return true end
	E.coop.money_of = function() return 700 end
	Hm.players = {{id=0,is_self=true,avatar_id=0}, {id=1,avatar_id=501}}
	E.coop.members = function() return {{id=500}, {id=501,peer=1,in_world=true}} end
	if T.fine_character then
		T.fine_character(500, 1500)
		check(#charged == 0, "offline fine is not charged to a reused peer slot")
		local saved={}; T.save_effects(saved); T.load_effects(saved)
		Hm.players = {{id=0,is_self=true,avatar_id=0}, {id=2,avatar_id=500}}
		E.coop.members = function() return {{id=500,peer=2,in_world=true}} end
		T.flush_fines(); T.flush_fines()
		check(#charged == 1 and charged[1][1] == 2 and charged[1][2] == -700,
			"saved fine follows character to new peer, capped by balance and charged once")
	else check(false, "offline guide fine requires a persistent character recipient") end
	Hm.players, E.coop.members = original_players, original_members
	E.coop.money_grant, E.coop.money_of = original_grant, original_money
end

print("== rep_share: task reputation goes to everyone in game, apart from the money rule")
do
	local T, E = Hm.env.coop_tasks, Hm.env
	local rules = {}
	local saved_core = E.coop_economy_core
	E.coop_economy_core = { rule = function(k) return rules[k] end }
	local base_players, base_members = Hm.players, E.coop.members
	Hm.new_obj(502, "coop_player_avatar", vec(50, 0, 0), { _stalker = true })
	local function waiting(char)
		local saved = {}
		T.save_effects(saved)
		local w = saved.coop_task_fx.wait and saved.coop_task_fx.wait[char]
		local n = 0
		for _, e in ipairs(w or {}) do if type(e.s) == "string" and e.s:find("rept", 1, true) then n = n + 1 end end
		return n
	end
	local seq = 0
	-- accept with `at_accept` players in game, finish with `at_end` players, the client (peer 1) takes it
	local function run(share, mode, at_accept, at_end)
		seq = seq + 1
		local id = "rep_share_" .. seq
		Hm.ini[id], Cm.ini[id] = {}, {}
		rules.rep_share, Hm.share = mode, share
		Hm.players, E.coop.members = at_accept.players, function() return at_accept.members end
		T.run_as(1, function() Hm.tm:give_task(id, 9) end)
		pump()
		Hm.on_complete[id] = function() E.xr_effects.decrease_rep(Hm.actor, nil, { "15" }) end
		Hm.players, E.coop.members = at_end.players, function() return at_end.members end
		local r = { host = Hm.rept, client = Cm.rept, hs = #Hm.stats, cs = #Cm.stats, w502 = waiting(502) }
		E.task_manager.task_callback({ get_id = function() return id end }, E.task.completed)
		pump()
		r.host, r.client = Hm.rept - r.host, Cm.rept - r.client
		r.hs, r.cs, r.w502 = #Hm.stats - r.hs, #Cm.stats - r.cs, waiting(502) - r.w502
		Hm.players, E.coop.members = base_players, base_members
		return r
	end
	local two = { players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } },
		members = { { id = 500, peer = 1, in_world = true } } }
	local three = { players = { two.players[1], two.players[2], { id = 2, is_self = false, avatar_id = 502 } },
		members = { { id = 500, peer = 1, in_world = true }, { id = 502, peer = 2, in_world = true } } }
	local gone = { players = two.players, members = { { id = 500, peer = 1, in_world = true }, { id = 502 } } }
	for _, share in ipairs({ 0, 3 }) do
		local r = run(share, "everyone", two, two)
		check(r.host == -15 and r.client == -15, "everyone, money " .. share .. ": the task's reputation reaches every character once")
		check(r.hs == 1 and r.cs == 1, "everyone, money " .. share .. ": the task statistics count for both characters")
		r = run(share, "taker", two, two)
		check(r.host == 0 and r.client == -15, "taker, money " .. share .. ": only the player who turned it in")
		check(r.hs == 0 and r.cs == 1, "taker, money " .. share .. ": the statistics stay the taker's")
		r = run(share, "everyone", two, three)
		check(r.host == -15 and r.client == -15 and r.w502 == 1,
			"everyone, money " .. share .. ": a player who joined after the accept and is in game at the end gets it")
		r = run(share, "everyone", three, gone)
		check(r.host == -15 and r.client == -15 and r.w502 == 1,
			"everyone, money " .. share .. ": a player who left after the accept gets it on his character")
		r = run(share, "taker", three, three)
		check(r.host == 0 and r.client == -15 and r.w502 == 0, "taker, money " .. share .. ": the others get nothing")
	end
	local r = run(0, nil, two, two)
	check(r.host == -15 and r.client == -15, "a world that never set the rule shares the task's reputation (everyone)")
	r = run(0, "garbage", two, two)
	check(r.host == -15 and r.client == -15, "an unknown rule value falls back to everyone")
	-- a task accepted before this rule existed (no captured roster in the save): taker plus who is in game at the end
	seq = seq + 1
	local id = "rep_share_" .. seq
	Hm.ini[id], Cm.ini[id] = {}, {}
	rules.rep_share, Hm.share = "everyone", 0
	T.run_as(1, function() Hm.tm:give_task(id, 9) end)
	pump()
	local saved = {}
	T.save_effects(saved)
	for _, field in ipairs({ "rep_party", "participants" }) do
		if saved.coop_task_fx[field] then saved.coop_task_fx[field][id] = nil end
	end
	T.load_effects(saved)
	Hm.on_complete[id] = function() E.xr_effects.decrease_rep(Hm.actor, nil, { "15" }) end
	local h0, c0 = Hm.rept, Cm.rept
	E.task_manager.task_callback({ get_id = function() return id end }, E.task.completed)
	pump()
	check(Hm.rept - h0 == -15 and Cm.rept - c0 == -15, "an old save's task shares its reputation with who is in game")
	-- failure consequences stay as they are (the players in game at the accept), whatever rep_share says
	seq = seq + 1
	id = "rep_share_" .. seq
	Hm.ini[id], Cm.ini[id] = {}, {}
	rules.rep_share = "taker"
	T.run_as(1, function() Hm.tm:give_task(id, 9) end)
	pump()
	local hs, cs = #Hm.stats, #Cm.stats
	E.task_manager.task_callback({ get_id = function() return id end }, E.task.fail)
	pump()
	check(#Hm.stats == hs + 1 and #Cm.stats == cs + 1, "a failed task's consequences keep their own roster under taker")
	rules.rep_share, Hm.share = nil, 0
	E.coop_economy_core = saved_core
	Hm.players, E.coop.members = base_players, base_members
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
