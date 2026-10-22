-- Anomaly Coop F3 task 16 temp test: tasks when the whole group is dead (scripts\coop_wipe.script, configs\coop_wipe_tasks.ltx)
-- and the F3 script domains (configs\coop_domains_checkpoints.ltx). Not shipped.
-- Stand-ins: task_manager (task_info + set_task_failed like the stock CRandomTask) and "the engine" (engine_poll() does what
-- the engine and task_manager.task_callback do after a forced failure: on_fail, then stage 255 or the record is dropped).
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")

-- ------------------------------------------------------------------ stand-ins
TM = { task_info = {} }
FAILED = {}   -- ids set_task_failed was called for, in order
ON_FAIL = {}  -- ids the stock fail callback ran for
ENGINE = {}   -- id -> true while the engine's own task object is still in progress
function TM:set_task_failed(id)
	FAILED[#FAILED + 1] = id
	if self.task_info[id] then self.task_info[id].forced_status = "fail" end
end
STAGE_COMPLETE = {} -- id -> stage_complete of the task ini stub (stock: task_manager.task_ini, misc\task\task_manager.ltx)
task_manager = {
	get_task_manager = function() return TM end,
	task_ini = { r_float_ex = function(_, id, key) if key == "stage_complete" then return STAGE_COMPLETE[id] end end },
}
db.actor = { get_task = function(_, id, only_active) return (only_active and ENGINE[id]) and {} or nil end }

local function task(id, functor, extra)
	local t = { id = id, status_functor = functor, status = "selected", stage = 0, repeat_timeout = 86400 }
	for k, v in pairs(extra or {}) do t[k] = v end
	TM.task_info[id] = t
	return t
end

-- task_manager.task_callback(fail) as the stock code runs it: on_fail, then the repeat-timeout record (stage 255)
-- or no record at all
local function engine_poll()
	local ids = {}
	for id in pairs(TM.task_info) do ids[#ids + 1] = id end
	for _, id in ipairs(ids) do
		local tsk = TM.task_info[id]
		if tsk.forced_status == "fail" then
			ON_FAIL[#ON_FAIL + 1] = id
			tsk.forced_status = nil
			tsk.status = "fail"
			if tsk.repeat_timeout then
				tsk.t = nil
				tsk.stage = 255
			else
				TM.task_info[id] = nil
			end
		end
	end
end

local function failed_ids()
	local copy = {}
	for i, id in ipairs(FAILED) do copy[i] = id end
	table.sort(copy)
	return table.concat(copy, ",")
end

local function reset()
	TM.task_info = {}
	FAILED, ON_FAIL, ENGINE, STAGE_COMPLETE = {}, {}, {}, {}
	MODE = "host"
	coop_wipe.reload()
end

local function wipe() SendScriptCallback("coop_group_wipe") end
local function update() SendScriptCallback("actor_on_update") end

-- a table-backed ini with the calls coop_wipe uses: sections = { name = { {key, value}, ... } }
local function mini_ini(sections)
	local o = {}
	function o:section_exist(s) return sections[s] ~= nil end
	function o:line_count(s) return sections[s] and #sections[s] or 0 end
	function o:r_line(s, i) local kv = sections[s][i + 1]; return true, kv[1], kv[2] end
	function o:line_exist(s, k) for _, kv in ipairs(sections[s] or {}) do if kv[1] == k then return true end end return false end
	function o:r_string(s, k) for _, kv in ipairs(sections[s] or {}) do if kv[1] == k then return kv[2] end end end
	return o
end

coop_wipe.on_game_start()

-- ------------------------------------------------------------------ the shipped table
print("== assault_bounty_hostage_fail")
reset()
task("sim_default_stalker_task_1", "assault_task_status_functor")
task("sim_default_bandit_task_2", "bounty_task")
task("simulation_task_26", "hostage_task")
wipe()
check(failed_ids() == "sim_default_bandit_task_2,sim_default_stalker_task_1,simulation_task_26",
	"set_task_failed for the assault, bounty and hostage tasks (got " .. failed_ids() .. ")")
check(TM.task_info.simulation_task_26.forced_status == "fail", "the stock forced status is what the engine polls")
check(coop_wipe.pending_count() == 3, "the failed ids are remembered for the retake")

print("== defense_rescue_fail")
reset()
task("mar_smart_terrain_base_stalker_leader_marsh_task_4", "gd_task_status_functor")
task("bar_dolg_leader_task_4", "spy_task_status_functor")
wipe()
check(failed_ids() == "bar_dolg_leader_task_4,mar_smart_terrain_base_stalker_leader_marsh_task_4",
	"the pump station defence and the agent rescue are failed (got " .. failed_ids() .. ")")

print("== escort_by_id_fail")
reset()
local escorts = { "jup_b6_scientist_tech_task_1", "mar_base_owl_stalker_trader_task_3", "sim_default_bandit_trader_task_4",
	"sim_default_csky_trader_task_3", "sim_default_ecolog_trader_task_1", "val_smart_terrain_7_4_bandit_trader_stalker_task_3" }
for _, id in ipairs(escorts) do
	check(coop_wipe.action_for(id, nil) == "fail", "action_for: stock escort task " .. id .. " (no functor) -> fail")
	task(id, nil)
end
task("barrier_defense_monolith", nil, { repeat_timeout = false })
task("barrier_defense_zombie", nil, { repeat_timeout = false })
check(coop_wipe.action_for("barrier_defense_monolith", nil) == "keep" and coop_wipe.action_for("barrier_defense_zombie", nil) == "keep",
	"action_for: the barrier defence stays")
wipe()
check(failed_ids() == table.concat(escorts, ","), "the six escort tasks are failed, the barrier defence is not (got " .. failed_ids() .. ")")
engine_poll()
update()
check(TM.task_info.sim_default_bandit_trader_task_4 == nil and TM.task_info.barrier_defense_zombie ~= nil, "escorts are retaken at once, the barrier is untouched")

print("== ready_to_turn_in_keep")
reset()
STAGE_COMPLETE.order_done = 1
STAGE_COMPLETE.order_hunting = 1
STAGE_COMPLETE.sweep_done = 3
STAGE_COMPLETE.sweep_midway = 3
task("order_done", "bounty_task", { stage = 1 })           -- target killed, waits for the turn-in dialog
task("order_hunting", "bounty_task", { stage = 0 })        -- still hunting
task("sweep_done", "assault_task_status_functor", { stage = 3 })
task("sweep_midway", "assault_task_status_functor", { stage = 2 })
task("plain_ready", "assault_task_status_functor", { stage = 254 }) -- no stage_complete key: 254
task("plain_hunting", "assault_task_status_functor", { stage = 1 })
local function log_line(id, pat)
	for i = #LOG, 1, -1 do
		if LOG[i]:find(id, 1, true) and LOG[i]:find(pat, 1, true) then return LOG[i] end
	end
end
LOG = {}
wipe()
check(failed_ids() == "order_hunting,plain_hunting,sweep_midway", "only the tasks short of stage_complete are failed (got " .. failed_ids() .. ")")
check(TM.task_info.order_done.forced_status == nil and TM.task_info.sweep_done.forced_status == nil
	and TM.task_info.plain_ready.forced_status == nil, "the tasks ready to turn in get no forced status")
check(coop_wipe.pending_count() == 3, "and are not remembered for the retake")
check(log_line("order_done", "ready to turn in") ~= nil, "a ready task is logged as 'ready to turn in'")
check(log_line("plain_ready", "ready to turn in") ~= nil, "stage 254 without a stage_complete key is ready too")
check(log_line("order_hunting", "ready to turn in") == nil and log_line("order_hunting", "fail") ~= nil, "a task short of the stage is logged as fail")
check(log_line("group wipe", "3 ready to turn in") ~= nil and log_line("group wipe", "3 failed") ~= nil, "the summary counts them apart")

print("== fetch_keep")
reset()
task("esc_fetch_1", "actor_has_fetch_item")
task("bar_delivery_1", "delivery_task")
task("jup_measure_1", "measure_task")
wipe()
check(#FAILED == 0, "fetch, delivery and measure tasks are not touched")
check(coop_wipe.pending_count() == 0 and TM.task_info.esc_fetch_1.forced_status == nil, "nothing is remembered and no status is forced")
check(coop_wipe.action_for("esc_fetch_1", "actor_has_fetch_item") == "keep", "action_for: fetch -> keep")
check(coop_wipe.action_for("x", "assault_task_status_functor") == "fail", "action_for: assault -> fail")

print("== lttz_prefix_wins")
reset()
task("lttz_hb_x", "assault_task_status_functor")
task("plain_assault", "assault_task_status_functor")
check(coop_wipe.action_for("lttz_hb_x", "assault_task_status_functor") == "keep", "action_for: lttz_ prefix beats the functor")
check(coop_wipe.action_for("LTTZ_hb_x", "bounty_task") == "keep", "prefix and id match without regard to case")
wipe()
check(failed_ids() == "plain_assault", "Lost to the Zone task is left alone, the same functor elsewhere fails (got " .. failed_ids() .. ")")

print("== by_id_wins")
reset()
coop_wipe.reload(mini_ini({
	settings = { { "default", "keep" } },
	by_functor = { { "assault_task_status_functor", "fail" } },
	by_prefix = { { "lttz_", "keep" }, { "lttz_hb_", "fail" } },
	by_id = { { "lttz_hb_force", "keep" }, { "never_assault", "keep" }, { "force_fail", "fail" } },
}))
check(coop_wipe.action_for("never_assault", "assault_task_status_functor") == "keep", "[by_id] keep beats [by_functor] fail")
check(coop_wipe.action_for("force_fail", "fetch_nothing") == "fail", "[by_id] fail beats the default")
check(coop_wipe.action_for("lttz_hb_force", "bounty_task") == "keep", "[by_id] beats [by_prefix]")
check(coop_wipe.action_for("lttz_hb_other", nil) == "fail", "the longest matching prefix wins")
check(coop_wipe.action_for("lttz_ll_other", nil) == "keep", "a shorter prefix still applies elsewhere")
check(coop_wipe.action_for("other", "assault_task_status_functor") == "fail", "[by_functor] when nothing above matches")
task("never_assault", "assault_task_status_functor")
task("force_fail", "")
task("another", "assault_task_status_functor")
wipe()
check(failed_ids() == "another,force_fail", "the wipe pass follows the same precedence (got " .. failed_ids() .. ")")
coop_wipe.reload()
check(coop_wipe.action_for("never_assault", "assault_task_status_functor") == "fail", "reload() without an ini reads the shipped table again")

print("== unknown_keep")
reset()
task("drx_sl_main_1", "drx_sl_quest_item_task_status")
task("lostzone_x", "special_steps_for_lostzone_tasks")
task("no_functor_1", nil)
task("empty_functor_1", "")
task("dominance_1", "dominance_task_status_functor")
wipe()
check(#FAILED == 0, "unlisted functors and tasks without a functor are not touched")
check(coop_wipe.action_for(nil, nil) == "keep" and coop_wipe.action_for(42, 7) == "keep", "garbage arguments -> keep")
coop_wipe.reload(mini_ini({
	settings = { { "default", "perhaps" } },
	by_functor = { { "bounty_task", "faill" }, { "hostage_task", "FAIL" } },
}))
check(coop_wipe.action_for("a", "bounty_task") == "keep", "a misspelled action is read as keep")
check(coop_wipe.action_for("a", "hostage_task") == "fail", "the action is read without regard to case")
check(coop_wipe.action_for("a", "nothing") == "keep", "a bad default is keep")
check(log_has("faill") ~= nil, "the bad line is logged")
coop_wipe.reload(mini_ini({}))
check(coop_wipe.action_for("a", "assault_task_status_functor") == "keep", "an ini without sections touches nothing")
coop_wipe.reload()

print("== retake_at_once")
reset()
local hunt = task("hunt_1", "assault_task_status_functor")
wipe()
update()
check(TM.task_info.hunt_1 == hunt, "the record stays until the stock fail callback has run")
engine_poll()
check(#ON_FAIL == 1 and ON_FAIL[1] == "hunt_1", "the stock on_fail path ran once")
check(hunt.stage == 255 and TM.task_info.hunt_1 == hunt, "stock leaves a repeat-timeout record at stage 255")
update()
check(TM.task_info.hunt_1 == nil, "the record is gone on the next update: the task can be taken again at once")
check(coop_wipe.pending_count() == 0, "nothing is remembered any more")
update()
check(TM.task_info.hunt_1 == nil, "a further update changes nothing")

print("== retake_waits_for_engine_task")
reset()
local waiting = task("hunt_2", "bounty_task")
wipe()
engine_poll()
ENGINE.hunt_2 = true
update()
check(TM.task_info.hunt_2 == waiting, "the record stays while the engine's own task is still in progress")
ENGINE.hunt_2 = nil
update()
check(TM.task_info.hunt_2 == nil, "and goes once the engine task is over")
reset()
local never_ends = task("hunt_2b", "bounty_task")
wipe()
engine_poll()
ENGINE.hunt_2b = true
NOW = NOW + 200000
update()
check(TM.task_info.hunt_2b == never_ends and coop_wipe.pending_count() == 0, "an engine task that never ends is given up on after two minutes")

print("== retake_no_timeout_or_replaced")
reset()
task("hunt_3", "bounty_task", { repeat_timeout = false })
wipe()
engine_poll()
check(TM.task_info.hunt_3 == nil, "stock drops a task without repeat_timeout itself")
check(coop_wipe.pending_count() == 1, "and the id is still remembered")
local again = task("hunt_3", "bounty_task", { repeat_timeout = false })
update()
check(TM.task_info.hunt_3 == again and coop_wipe.pending_count() == 0, "a task given again meanwhile is not removed")

print("== retake_gives_up")
reset()
local stuck = task("hunt_4", "assault_task_status_functor")
wipe()
NOW = NOW + 60000
update()
check(coop_wipe.pending_count() == 1, "still waiting a minute after the wipe")
NOW = NOW + 120000
update()
check(coop_wipe.pending_count() == 0 and TM.task_info.hunt_4 == stuck, "forgotten after two minutes, the record is left to stock")

print("== finished_untouched")
reset()
local done_task = task("done_1", "assault_task_status_functor", { status = "completed", stage = 255, timeout = 5 })
local timer_task = task("timer_1", "bounty_task", { status = "fail", stage = 255, timeout = 5 })
local cancelled = task("cancel_1", "assault_task_status_functor", { forced_status = "fail", cancelled_by_actor = true })
local completing = task("complete_1", "hostage_task", { forced_status = "complete" })
local live = task("live_1", "assault_task_status_functor")
wipe()
check(failed_ids() == "live_1", "only the task in progress is failed (got " .. failed_ids() .. ")")
engine_poll()
update()
check(TM.task_info.done_1 == done_task and TM.task_info.timer_1 == timer_task, "finished tasks keep their repeat timer")
check(TM.task_info.cancel_1 == cancelled and TM.task_info.complete_1 == completing, "a status somebody else forced is not overridden")
check(TM.task_info.live_1 == nil, "the failed one is retaken at once")

print("== log_every_decision")
reset()
task("log_a", "assault_task_status_functor")
task("log_b", "actor_has_fetch_item")
task("log_c", "mystery_functor")
task("log_d", "bounty_task", { status = "completed", stage = 255 })
LOG = {}
wipe()
check(log_has("log_a") and log_has("log_a"):find("fail", 1, true), "a fail decision is logged with the task id")
check(log_has("log_b") and log_has("log_b"):find("keep", 1, true), "a keep decision is logged")
check(log_has("log_c") and log_has("log_c"):find("default", 1, true), "an unknown task is logged as the default rule")
check(log_has("1 failed") ~= nil, "one summary line with the counts")

print("== client_ignores")
reset()
task("c_1", "assault_task_status_functor")
MODE = "client"
wipe()
update()
check(#FAILED == 0 and TM.task_info.c_1.forced_status == nil and coop_wipe.pending_count() == 0, "a client does nothing")
MODE = "sp"
wipe()
check(#FAILED == 0 and coop_wipe.pending_count() == 0, "outside a session nothing happens either")
MODE = "host"
wipe()
check(failed_ids() == "c_1", "the same wipe on the host fails the task")
MODE = "client"
update()
engine_poll()
update()
check(TM.task_info.c_1 ~= nil, "a client does not remove records either")
MODE = "host"

print("== callbacks_registered")
check(axr_main.count("coop_group_wipe") == 1, "coop_group_wipe has one subscriber")
check(axr_main.count("actor_on_update") >= 1, "actor_on_update is subscribed for the retake")

-- ------------------------------------------------------------------ the F3 script domains
print("== domains_listed")
local dom = ini_file("coop_domains_checkpoints.ltx")
local function names(sec)
	local out = {}
	if dom:section_exist(sec) then
		for i = 0, dom:line_count(sec) - 1 do
			local _, key = dom:r_line(sec, i, "", "")
			out[#out + 1] = key
		end
	end
	table.sort(out)
	return table.concat(out, ",")
end
check(names("view") == "coop_checkpoints,coop_saves", "view: checkpoints and saves (got " .. names("view") .. ")")
check(names("owner") == "coop_death,coop_rest", "owner: rest and death (got " .. names("owner") .. ")")
check(names("host") == "coop_wipe", "host: wipe (got " .. names("host") .. ")")
check(names("blocked") == "", "nothing blocked")

print("== domains_route_client")
do
	local base_getFS = getFS
	function getFS() -- the stub lists a fixed set of coop_domains_*.ltx; add this file
		local fs = base_getFS()
		local base_list = fs.file_list_open
		fs.file_list_open = function(self, alias, path, flags)
			local list = base_list(self, alias, path, flags)
			if alias == "$game_config$" and type(path) == "number" then
				local found = {}
				for i = 0, list:Size() - 1 do found[#found + 1] = list:GetAt(i) end
				found[#found + 1] = "coop_domains_checkpoints.ltx"
				return { Size = function() return #found end, GetAt = function(_, i) return found[i + 1] end, Free = function() end }
			end
			return list
		end
		return fs
	end
end
MODE = "client"
SELF = 1
make_actor()
load_script("coop_main")
coop_main.on_game_start()
RAN = {}
for _, n in ipairs({ "coop_checkpoints", "coop_saves", "coop_rest", "coop_death", "coop_wipe" }) do
	RegisterScriptCallback("actor_on_update", from_script(n, "return function() RAN['" .. n .. "'] = true end"))
end
update()
check(RAN.coop_checkpoints and RAN.coop_saves, "coop_checkpoints and coop_saves run on a client (view)")
check(RAN.coop_rest and RAN.coop_death, "coop_rest and coop_death run on a client (owner)")
check(RAN.coop_wipe == nil, "coop_wipe is skipped on a client (host)")
MODE = "host"
RAN = {}
update()
check(RAN.coop_wipe == true, "coop_wipe runs on the host")

done("WIPE")
