-- Mission fixes, part 5 (coop_quests_missions): the allow-listed "run this module.function on the host for this player" relay for
-- dialog actions (audit B finding 4, A items 6 and T4), a status functor's kill reaches every player (A T4), the Semenov tissue
-- counter counts every player's kill (B finding 6 / A item 8).
-- Run: tools\test_lua.cmd mission_relay
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party", "coop_quests_story",
	"coop_quests_missions" }

local RELAYED = {
	"tasks_pump_station_defense.give_before_attack_talk", "tasks_mystery_of_the_swamps.start_task",
	"tasks_defense.barrier_defense_monolith_start", "tasks_defense.barrier_defense_zombie_start",
	"tasks_defense.barrier_defense_monolith_complete", "tasks_defense.barrier_defense_zombie_complete",
	"dialogs_lostzone.set_impending_doom_timer",
}

local function setup_world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	M.on_complete = {}
	M.ini.barrier_defense_monolith = {}
	M.ini.barrier_defense_zombie = {}
	M.ini.task_mystery_of_the_swamps = {}
	M.ini.kill_t = { status_functor = "kill_sf" }
	M.npc = M.new_obj(700, "esc_m_trader", vec(5, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = M.npc }
	M.calls = {}
	-- the stock module functions: every one records where it ran, for whom, and with what
	local function record(name)
		return function(a, b)
			M.calls[#M.calls + 1] = {
				name = name, a = a and a:id(), b = b and b:id(), reward_peer = e.coop_tasks.reward_peer and e.coop_tasks.reward_peer(),
			}
			if name:find("start", 1, true) or name:find("start_task", 1, true) then
				local tid = name:find("mystery", 1, true) and "task_mystery_of_the_swamps"
					or name:find("zombie", 1, true) and "barrier_defense_zombie" or "barrier_defense_monolith"
				e.task_manager.get_task_manager():give_task(tid, b and b:id())
			end
			local done = name:match("barrier%.(%w+)_complete")
			local info = done and e.task_manager.get_task_manager().task_info["barrier_defense_" .. done]
			if info then info.forced_status = "complete" end
		end
	end
	e.tasks_pump_station_defense = { give_before_attack_talk = record("pump.give_before_attack_talk") }
	e.tasks_mystery_of_the_swamps = { start_task = record("mystery.start_task") }
	e.tasks_defense = {
		barrier_defense_monolith_start = record("barrier.monolith_start"), barrier_defense_zombie_start = record("barrier.zombie_start"),
		barrier_defense_monolith_complete = record("barrier.monolith_complete"),
		barrier_defense_zombie_complete = record("barrier.zombie_complete"),
	}
	e.dialogs_lostzone = { set_impending_doom_timer = record("doom.timer") }
	e.load_ctime = function() return M.doom_timer end
	-- an effect the relay must refuse to name
	e.xr_effects.kill_actor = function() M.killed = (M.killed or 0) + 1 end
	e.xr_effects.danger = function() M.danger = true end
	-- a task whose status functor kills (lttz_ms_decisive_blow after the deadline)
	e.task_status_functor.kill_sf = function(tsk, id) e.xr_effects.kill_actor() end
	-- tissue samples
	e.IsMonster = function(o) return o._monster == true end
	e.get_story_object = function(sid) if M.semenov and sid == "yan_ecolog_semenov" then return {} end end
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
Hm.semenov = true
local proxy = Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true })
local host_av = Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0)
boot(Hm)
boot(Cm)
check(Hm.handlers["quests.act"] ~= nil, "the host handles quests.act")

local function acts(M) return count_sent(M, "quests.act") end

print("== a client's dialog action runs on the host, for him")
Hm.calls = {}
for i, full in ipairs(RELAYED) do
	local mod, fn = full:match("^([%w_]+)%.([%w_]+)$")
	local before = acts(Cm)
	Cm.env[mod][fn](Cm.actor, Cm.npc)
	check(acts(Cm) == before + 1, full .. ": sent to the host")
	check(#Cm.calls == 0, full .. ": not run on the client")
	NOW = NOW + 1500 -- the same action from one player is paced
	pump()
	local c = Hm.calls[#Hm.calls]
	check(c and #Hm.calls == i, full .. ": run once on the host")
	check(c and c.a == 0 and c.b == 700, full .. ": the host's actor and the NPC as the two speakers")
	check(c and c.reward_peer == 1, full .. ": in the client's scope (rewards, companions and tasks are his)")
end
check(Hm.tm.task_info.task_mystery_of_the_swamps ~= nil and Hm.env.coop_tasks.taker("task_mystery_of_the_swamps") == 1,
	"Mystery of the Swamps: the task the host gave is the client's")
check(Hm.env.coop_tasks.taker("barrier_defense_monolith") == 1, "Barrier defense: the task the host gave is the client's")

print("== the order of the two speakers does not matter")
Hm.calls = {}
Cm.env.dialogs_lostzone.set_impending_doom_timer(Cm.npc, Cm.actor)
NOW = NOW + 1500
pump()
check(#Hm.calls == 1 and Hm.calls[1].b == 700, "(npc, actor): the NPC is found")

print("== a repeat changes nothing")
do
	local function again(fn, what)
		Hm.calls = {}
		Cm.env.tasks_defense[fn](Cm.actor, Cm.npc)
		NOW = NOW + 1500
		pump()
		check(#Hm.calls == 0, what)
	end
	again("barrier_defense_monolith_complete", "a task paid for pays no more")
	again("barrier_defense_zombie_complete", "the other one neither")
	again("barrier_defense_monolith_start", "a task given is not started again")
	Hm.doom_timer = 1
	Hm.calls = {}
	Cm.env.dialogs_lostzone.set_impending_doom_timer(Cm.actor, Cm.npc)
	NOW = NOW + 1500
	pump()
	check(#Hm.calls == 0, "the deadline does not move")
	Hm.doom_timer = nil
end

print("== the host's own dialog runs as it did")
Hm.calls = {}
Hm.env.tasks_pump_station_defense.give_before_attack_talk(Hm.actor, Hm.npc)
check(#Hm.calls == 1 and Hm.calls[1].reward_peer == nil, "the host's talk: the stock function, no relay")
check(acts(Hm) == 0, "...and nothing sent")

print("== only the list is run")
Hm.calls = {}
-- a request as a (modified) client could send it; each one a second later than the last unless same_time (the pacing);
-- extra = { n = false } leaves a field out
local function raw_act(f, extra, same_time)
	if not same_time then NOW = NOW + 1500 end
	local t = { a = "rly", f = f, n = 700 }
	for k, v in pairs(extra or {}) do if v == false then t[k] = nil else t[k] = v end end
	table.insert(QUEUE, { to = Hm, name = "quests.act", payload = H.encode(t), from = 1 })
	pump()
end
raw_act("xr_effects.kill_actor")
raw_act("xr_effects.danger")
raw_act("os.execute")
raw_act("tasks_defense.nothing_here")
raw_act("tasks_defense")
raw_act(42)
check(Hm.killed == nil and Hm.danger == nil and #Hm.calls == 0, "a name from the wire that is not on the list runs nothing")
check(has_log(Hm, "refused"), "...and is logged")

print("== the NPC has to be there")
raw_act("tasks_defense.barrier_defense_monolith_start", { n = 99999 })
check(#Hm.calls == 0, "no such NPC: refused")
raw_act("tasks_defense.barrier_defense_monolith_start", { n = false })
check(#Hm.calls == 0, "no NPC given: refused")
raw_act("tasks_defense.barrier_defense_monolith_start", { n = 0 })
check(#Hm.calls == 0, "the host's own character as the NPC: refused")
raw_act("tasks_defense.barrier_defense_monolith_start", { n = 500 })
check(#Hm.calls == 0, "the player's own character as the NPC: refused")
proxy._pos = vec(500, 0, 0)
raw_act("tasks_defense.barrier_defense_monolith_start")
check(#Hm.calls == 0, "the player is 500 m away from the NPC: refused")
proxy._pos = vec(4, 0, 0)
Hm.npc._dead = true
raw_act("tasks_defense.barrier_defense_monolith_start")
check(#Hm.calls == 0, "a dead NPC: refused")
Hm.npc._dead = nil

print("== a talk with the NPC (when the engine tells)")
Hm.env.coop.talk_recent = function(peer, npc_id, ms) return false end
raw_act("tasks_pump_station_defense.give_before_attack_talk")
check(#Hm.calls == 0, "no talk with that NPC in the last 5 s: refused")
local asked
Hm.env.coop.talk_recent = function(peer, npc_id, ms) asked = { peer, npc_id, ms } return peer == 1 and npc_id == 700 end
raw_act("tasks_pump_station_defense.give_before_attack_talk")
check(#Hm.calls == 1 and asked and asked[1] == 1 and asked[2] == 700 and asked[3] == 5000, "a talk that counts: run (peer, NPC, 5000 ms asked)")
Hm.env.coop.talk_recent = nil

print("== pacing")
Hm.calls = {}
raw_act("tasks_pump_station_defense.give_before_attack_talk")
raw_act("tasks_pump_station_defense.give_before_attack_talk", nil, true)
check(#Hm.calls == 1, "the same action twice at once: the second is dropped")
raw_act("tasks_pump_station_defense.give_before_attack_talk")
check(#Hm.calls == 2, "...and again after a second")

print("== without a session the stock functions run")
for _, M in ipairs({ Hm, Cm }) do M.active = false end
Cm.calls = {}
local sent_before = acts(Cm)
Cm.env.tasks_defense.barrier_defense_monolith_complete(Cm.actor, Cm.npc)
check(#Cm.calls == 1 and acts(Cm) == sent_before, "no session: run locally, nothing sent")
for _, M in ipairs({ Hm, Cm }) do M.active = true end

-- ---------------------------------------------------------------- a status functor's kill
print("== a status functor's kill_actor reaches every player")
Hm.tm.task_info = {}
Cm.env.task_manager.get_task_manager():give_task("kill_t", 700)
pump()
Hm.killed, Cm.killed = nil, nil
NOW = NOW + 1000
Hm.env.task_manager.get_task_manager():update()
pump()
check(Hm.killed == 1, "the host dies as before")
check(Cm.killed == 1, "the client dies too")
NOW = NOW + 500
Hm.env.task_manager.get_task_manager():update()
pump()
check(Cm.killed == 1, "the kill is passed on at most once in 2 s per player (the functor fires every check)")
NOW = NOW + 2500
Hm.env.task_manager.get_task_manager():update()
pump()
check(Cm.killed == 2 and Hm.killed == 3, "...and again later")
Hm.killed, Cm.killed = 0, 0
Hm.env.xr_effects.kill_actor(Hm.actor, nil, nil)
pump()
check(Cm.killed == 0 and Hm.killed == 1, "a kill outside a task check (a script, a condlist) is not relayed")
Hm.env.xr_effects.kill_actor(Hm.actor, { id = function() return 1 end }, {})
check(Cm.killed == 0, "a kill an NPC's logic names (a restrictor, handled by coop_npc_logic) is not relayed here")

-- ---------------------------------------------------------------- tissue samples
print("== Semenov's tissue samples count every player's mutant kill")
Hm.env.save_var(Hm.actor, "yan_ecolog_semenov_task_1_tissue_need", 5)
local function kill(killer, victim) fire(Hm, "monster_on_death_callback", victim, killer) end
local mutant = Hm.new_obj(900, "dog", vec(40, 0, 0), { _monster = true })
local count = function() return Hm.env.load_var(Hm.actor, "yan_ecolog_semenov_task_1_tissue_count", 0) end
kill(proxy, mutant)
check(count() == 1, "a client's kill counts")
kill(Hm.actor, mutant)
check(count() == 2, "the host's kill counts")
kill(Hm.new_obj(901, "stalker", vec(41, 0, 0), { _stalker = true }), mutant)
check(count() == 2, "an NPC's kill does not")
kill(proxy, Hm.new_obj(902, "bandit", vec(42, 0, 0), { _stalker = true }))
check(count() == 2, "a stalker is not a mutant")
kill(nil, mutant)
check(count() == 2, "no killer: nothing")
Hm.env.save_var(Hm.actor, "yan_ecolog_semenov_task_1_tissue_need", 0)
kill(proxy, mutant)
check(count() == 2, "the task is not running (need 0): nothing")
Hm.env.save_var(Hm.actor, "yan_ecolog_semenov_task_1_tissue_need", 5)
Hm.semenov = false
kill(proxy, mutant)
check(count() == 2, "Semenov is not in the world: nothing")
Hm.semenov = true
Hm.active = false
kill(proxy, mutant)
check(count() == 2, "no session: nothing (the mod itself counts then)")
Hm.active = true
fire(Cm, "monster_on_death_callback", mutant, host_av)
check(Cm.env.load_var(Cm.actor, "yan_ecolog_semenov_task_1_tissue_count", 0) == 0, "a client does not count anything itself")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
