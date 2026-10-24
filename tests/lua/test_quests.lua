-- Anomaly Coop W4 "quests" temp test: coop_tasks + coop_quests_* on a simulated host and client.
-- Run: tools\test_lua.cmd quests   (VERBOSE = true for machine logs)
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party", "coop_quests_story", "coop_quests_pda" }

-- ---------------------------------------------------------------- world setup (same on both machines)
local function setup_world(M)
	local e = M.env
	-- task ini
	M.ini.bounty_t = { on_job_descr = "%=setup_bounty_task(bounty_t)%", job_descr = "bounty_t_descr" }
	M.ini.fetch_t = { fetch_descr = "fetch_t_fetch_descr", fetch_func = "%=setup_fetch_task(fetch_t_fetch:x:1:2)%", job_descr = "fetch_t_job" }
	M.ini.assault_t = { on_job_descr = "%=setup_assault_task(assault_t)%", job_descr = "assault_t_descr" }
	M.ini.measure_t = { status_functor = "measure_task" }
	M.ini.has_t = { status_functor = "has_item_sf" }
	M.ini.story_t = {}
	-- NPCs: trader 700 (non-sim), bounty target 710 in squad 711
	M.npc = M.new_obj(700, "esc_m_trader", vec(5, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = M.npc }
	M.new_obj(710, "sim_default_bandit_1", vec(300, 0, 0), { _stalker = true, _group = 711 })
	M.new_obj(711, "squad", vec(300, 0, 0))
	M.new_obj(720, "anomaly", vec(100, 0, 0)) -- measure target
	M.npc_tasks = { [700] = { "bounty_t", "fetch_t", "assault_t" } }
	-- on_job_descr / fetch effects (stock-like): vars + a deferred offer line
	e.xr_effects.setup_bounty_task = function(actor, npc, p)
		local giver = e.mob_trade.GetTalkingNpc()
		e.axr_task_manager.bounties_by_id[p[1]] = 710
		e.save_var(e.db.actor, p[1], { target_id = 710, lvl_target = "l02", giver = giver and giver:id() or -1 })
		e.CreateTimeEvent(0, "setup_bounty_task", 0, function()
			e.db.actor:give_talk_message2("Bounty", "Kill name_710", "icon_710", "iconed_answer_item")
			return true
		end)
	end
	e.xr_effects.setup_fetch_task = function(actor, npc, p)
		local spk = e.get_speaker(true)
		M.fetch_speaker = spk and spk:id()
		e.save_var(e.db.actor, p[1], "medkit")
		e.save_var(e.db.actor, p[1] .. "_count", 2)
		e.dialogs._FETCH_TEXT = e.ui_item.get_sec_name("medkit")
		e.CreateTimeEvent(0, "setup_fetch_task", 0, e.tasks_fetch.postpone_fetch_for_next_frame, p[1], "medkit", 2)
	end
	e.xr_effects.setup_assault_task = function(actor, npc, p)
		e.save_var(e.db.actor, p[1], { squad_id = 711, smart_id = 5 })
	end
	e.xr_effects.remove_item = function(actor, npc, p)
		local left = tonumber(p[2]) or 1
		e.db.actor:iterate_inventory(function(_, it)
			if left > 0 and it._sec == p[1] then e.alife_release_id(it._id) left = left - 1 end
		end)
	end
	-- status functors
	e.task_status_functor.has_item_sf = function(tsk, id)
		tsk.stage = e.db.actor:object("quest_doc") and 1 or 0
	end
	e.task_status_functor.measure_task = function(tsk, id)
		local var = e.load_var(e.db.actor, id)
		if not var then return end
		if not var.given then
			local se = e.alife_create_item("measure_device", e.db.actor)
			var.given = true
			var.item_1_id = se and se._id
			e.save_var(e.db.actor, id, var)
			return
		end
		local d = e.alife_object(720).position:distance_to(e.db.actor:position())
		M.measure_seen_lv = e.db.actor:level_vertex_id()
		tsk.stage = d <= 10 and 2 or 1
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
local proxy = Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true }) -- client's character on the host
local host_av = Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true }) -- host's character on the client
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0) -- the client stands at the trader
boot(Hm)
boot(Cm)
check(Hm.handlers["quests.offer_req"] and Cm.handlers["quests.offer"] and Hm.handlers["quests.act"], "event handlers registered")

-- ---------------------------------------------------------------- core codec
print("== core codec")
do
	local qc = Hm.env.coop_quests_core
	local v = { a = 1, b = "x;y=z:s5:", c = { 1, 2, { deep = true } }, [7] = false, f = function() end }
	local s = qc.ser(v)
	local back = qc.des(s)
	check(back and back.a == 1 and back.b == "x;y=z:s5:" and back.c[3].deep == true and back[7] == false and back.f == nil,
		"nested round trip (functions dropped)")
	check(qc.des("s5:abc") == nil and qc.des("{s1:a") == nil and qc.des("n12") == nil and qc.des("") == nil and qc.des("Tx") == nil,
		"malformed input refused")
	local deep = {}
	local cur = deep
	for i = 1, 12 do cur.n = {} cur = cur.n end
	check(qc.ser(deep) ~= nil and qc.des(qc.ser(deep)) ~= nil, "too deep tables are cut, not an error")
end

-- ---------------------------------------------------------------- condlist depth
print("== condlist depth")
do
	local qc = Cm.env.coop_quests_core
	local inside
	Cm.env.xr_effects.probe = function() inside = qc.in_condlist() end
	Cm.env.xr_logic.pick_section_from_condlist(nil, nil, { src = "%=probe%" })
	check(inside == true and not qc.in_condlist(), "in_condlist true only inside a condlist")
	Cm.env.xr_effects.boom = function() error("boom") end
	local ok = pcall(Cm.env.xr_logic.pick_section_from_condlist, nil, nil, { src = "%=boom%" })
	check(not ok and not qc.in_condlist(), "an error inside a condlist propagates and resets the depth")
end

do
	local holds = {}
	Cm.env.coop.story_hold_infos = function(on) holds[#holds + 1] = on return true end -- W5 contract: true = held
	local pick = Cm.env.xr_logic.pick_section_from_condlist
	pick(nil, nil, { { "", {}, { { "latch", 1 }, { "create_squad", 3, {} } } } })
	check(holds[1] == true and holds[2] == false, "client: a condlist with a squad spawn keeps its infos local (engine hold on/off)")
	holds = {}
	pick(nil, nil, { { "", {}, { { "latch", 1 }, { "reward_money", 3, {} } } } })
	check(#holds == 0, "client: other condlists are not held")
	Cm.env.coop.story_hold_infos = nil
end

-- ---------------------------------------------------------------- offers
print("== host-prepared offers (R-7.3)")
Cm.env.EVENTS.used_npc_id = 700
Cm.talk_npc = Cm.npc
Hm.original_talker = nil
local host_cte = Hm.env.CreateTimeEvent
fire(Cm, "GUI_on_show", "Dialog")
local req = last_sent(Cm, "quests.offer_req")
check(req and req.n == 700 and req.k == "dyn", "dialog open asks the host for the NPC's offer")
pump()
check(Hm.gen_calls == 1 and Hm.gen_talking == true and Hm.gen_speaker == Hm.npc, "host generated as if its actor talked to the NPC")
check(Hm.fetch_speaker == 700, "get_speaker() was the NPC during the host's fetch setup")
check(Hm.env.db.actor:is_talking() == false and Hm.env.mob_trade.GetTalkingNpc() == nil and Hm.env.CreateTimeEvent == host_cte,
	"host talk shims put back")
check(Hm.talk_msgs == nil and (Hm.game_news or 0) == 0, "nothing shown on the host's screen")
check(type(Hm.env.load_var(Hm.actor, "bounty_t")) == "table" and Hm.env.load_var(Hm.actor, "fetch_t_fetch") == "medkit",
	"host has the offer vars")
check(count_sent(Hm, "quests.offer_t") == 3 and count_sent(Hm, "quests.offer") == 1, "three task offers + the list sent")

-- client uses the host's list and texts
Cm.env.axr_task_manager.generate_available_tasks(Cm.npc, nil)
local av = Cm.env.axr_task_manager.available_tasks[700]
check(av and av[1] == "bounty_t" and av[2] == "fetch_t" and #av == 3, "client list = host's list")
check(Cm.gen_calls == nil, "client did not generate locally")
local txt = Cm.env.dialogs.text_npc_has_task(Cm.actor, Cm.npc)
check(txt == "T(bounty_t_descr)", "job description text")
check(type(Cm.env.load_var(Cm.actor, "bounty_t")) == "table" and Cm.env.load_var(Cm.actor, "bounty_t").target_id == 710
	and Cm.env.axr_task_manager.bounties_by_id.bounty_t == 710, "host's task vars and bounty target on the client")
check((Cm.local_text or 0) == 0, "stock local text (on_job_descr) not run on the client")
run_timers(Cm)
check(Cm.talk_msgs and Cm.talk_msgs[1][1] == "Bounty" and Cm.talk_msgs[1][2] == "Kill name_710", "host's offer line shown on the client")
-- skip to the fetch task
table.remove(av, 1)
Cm.talk_msgs = nil
txt = Cm.env.dialogs.text_npc_has_task(Cm.actor, Cm.npc)
check(txt == "T(fetch_t_fetch_descr)" and Cm.env.dialogs._FETCH_TEXT == "N(medkit)", "fetch text with the host's item")
run_timers(Cm)
check(Cm.talk_msgs and #Cm.talk_msgs == 1 and Cm.talk_msgs[1][1] == "needs" and Cm.talk_msgs[1][2] == "medkit x2",
	"fetch line drawn locally (client language), host's fetch line not sent")

-- client takes the bounty task: vars travel, host pins the target squad
print("== client takes an offered task")
Cm.env.task_manager.get_task_manager():give_task("bounty_t", 700)
pump()
check(Hm.tm.task_info.bounty_t ~= nil and Hm.env.coop_tasks.taker("bounty_t") == 1, "host gave the task, taker = client")
check(Hm.env.sim_offline_combat.task_squads[711] == true, "bounty target squad pinned on the host")
-- assault: given by the client with its own var (local generation path)
Cm.env.save_var(Cm.actor, "assault_t", { squad_id = 711, smart_id = 5 })
Hm.env.sim_offline_combat.task_squads[711] = nil
Cm.env.task_manager.get_task_manager():give_task("assault_t", 700)
pump()
check(Hm.env.sim_offline_combat.task_squads[711] == true, "assault target squad pinned after the client's give")
-- a task taken by the group is not offered again
NOW = NOW + 2000
tick(Hm)
pump()
fire(Cm, "GUI_on_show", "Dialog")
pump()
Cm.env.axr_task_manager.generate_available_tasks(Cm.npc, nil)
av = Cm.env.axr_task_manager.available_tasks[700]
check(#av == 1 and av[1] == "fetch_t", "tasks the group has are not offered")
-- other kind of list (sim) -> local generation
Cm.env.axr_task_manager.generate_available_tasks(Cm.npc, true)
check(Cm.gen_calls == 1, "no host list of that kind: stock local generation")
-- host refuses a far requester
proxy._pos = vec(500, 0, 0)
NOW = NOW + 2000
fire(Cm, "GUI_on_show", "Dialog")
pump()
check(has_log(Cm, "host refused the offer"), "far requester refused")
proxy._pos = vec(4, 0, 0)

-- host after-give: no var from the client -> host runs on_job_descr itself
print("== host prepares a task the client brought no var for")
Hm.env.save_var(Hm.actor, "bounty_t2", nil)
Hm.ini.bounty_t2 = { on_job_descr = "%=setup_bounty_task(bounty_t2)%" }
Cm.ini.bounty_t2 = Hm.ini.bounty_t2
Cm.env.task_manager.get_task_manager():give_task("bounty_t2", 700)
pump()
check(type(Hm.env.load_var(Hm.actor, "bounty_t2")) == "table" and Hm.env.load_var(Hm.actor, "bounty_t2").giver == 700,
	"host ran on_job_descr with the giver as the talking NPC")

-- ---------------------------------------------------------------- group items and positions (R-7.5)
print("== task checks with the group (host)")
Hm.env.task_manager.get_task_manager():give_task("has_t", 700)
Hm.give_item(proxy, "quest_doc")
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.has_t.stage == 1, "status functor finds the quest item in the client's character")
check(Hm.actor:object("quest_doc") == nil, "db.actor:object is the plain one again after the check")
-- measure task taken by the client: device to its character, position of the nearest player
Cm.env.task_manager.get_task_manager():give_task("measure_t", 700)
pump()
Hm.env.save_var(Hm.actor, "measure_t", { item_1_sec = "measure_device", target_id = 720 })
Hm.env.task_manager.get_task_manager():update()
check(proxy:object("measure_device") ~= nil and Hm.actor:object("measure_device") == nil, "device handed out to the taker's character")
local saw = false
for _, n in ipairs(Hm.news) do if n == "in:measure_devicex1" then saw = true end end
check(not saw, "item news not shown on the host")
proxy._pos = vec(95, 0, 0)
proxy._lv = 77
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.measure_t.stage == 2 and Hm.measure_seen_lv == 77, "client at the anomaly advances the stage (its position and vertex)")
check(Hm.actor:position().x == 0 and Hm.actor:level_vertex_id() == 1, "host actor position restored")
proxy._pos = vec(4, 0, 0)
Hm.env.task_manager.get_task_manager():update()
check(Hm.tm.task_info.measure_t.stage == 1, "nobody there: back to stage 1")
-- has_item_by_id / conditions
local doc = proxy:object("quest_doc")
check(Hm.env.utils_item.has_item_by_id(nil, doc._id, "quest_doc") == true, "has_item_by_id: item of the client's character counts")
check(Hm.env.xr_conditions.actor_has_item(Hm.actor, nil, { "quest_doc" }) == true, "actor_has_item counts the group (host)")
Cm.give_item(host_av, "host_doc")
check(Cm.env.xr_conditions.actor_has_item(Cm.actor, nil, { "host_doc" }) == true, "actor_has_item counts the group (client)")
-- client remove_item: what it lacks is taken from the group by the host
print("== client removal takes the rest from the group")
Hm.give_item(Hm.actor, "vodka")
Cm.env.xr_effects.remove_item = Cm.env.xr_effects.remove_item -- installed wrapper
Cm.env.xr_effects.remove_item(Cm.actor, nil, { "vodka", 1 })
pump()
check(Hm.count(Hm.actor, "vodka") == 0, "host removed the item the client did not have")
pump()
local got_news = false
for _, n in ipairs(Cm.news) do if n == "out:vodkax1" then got_news = true end end
check(got_news and not (function() for _, n in ipairs(Hm.news) do if n == "out:vodkax1" then return true end end end)(),
	"the requester sees the item news, not the host")

-- RF target mirrored
print("== RF targets")
Hm.env.item_radio = { RF_targets = {}, add_target = function(id, f, d) Hm.env.item_radio.RF_targets[id] = { freq = f, dist = d } end,
	clear_target = function(id) Hm.env.item_radio.RF_targets[id] = nil end }
Cm.env.item_radio = { RF_targets = {} }
Hm.env.coop_quests_party = Hm.env.coop_quests_party -- (module)
-- patch_rf ran at install time without item_radio: install it now through a fresh first update
do
	local p = load_script(Hm, "coop_quests_party")
	p.on_game_start()
	fire(Hm, "actor_on_first_update")
end
Hm.env.item_radio.add_target(4242, 171, 75)
pump()
check(Cm.env.item_radio.RF_targets[4242] and Cm.env.item_radio.RF_targets[4242].freq == 171, "host's RF target added on the client")

-- measurement HUD on the client
print("== client measurement HUD")
local hud = {}
Cm.env.tasks_measure = { start_measurement_hud = function(id) hud.on = id end, close_measurement_hud = function() hud.on = false end }
local dev = Cm.give_item(Cm.actor, "measure_device")
Cm.actor._detector = dev
Cm.env.save_var(Cm.actor, "measure_t", { item_1_sec = "measure_device", item_1_id = dev._id, target_id = 720 })
Cm.tm.task_info.measure_t = Cm.tm.task_info.measure_t or { id = "measure_t" }
Cm.actor._pos = vec(98, 0, 0)
tick(Cm)
check(hud.on == "measure_t", "HUD started near the anomaly with the device")
Cm.actor._pos = vec(4, 0, 0)
NOW = NOW + 1000
tick(Cm)
check(hud.on == false, "HUD closed when the player walks away")
Cm.actor._detector = nil

-- ---------------------------------------------------------------- story effects
print("== story effects")
Cm.env.xr_effects.reward_money = function(a, n, p) Cm.env.dialogs.relocate_money(Cm.actor, tonumber(p[1]), "in") end
Hm.env.xr_effects.reward_money = function(a, n, p) Hm.env.dialogs.relocate_money(Hm.actor, tonumber(p[1]), "in") end
Hm.env.game_difficulties = { get_eco_factor = function() return 1 end }
Cm.env.game_difficulties = Hm.env.game_difficulties
-- reinstall story wrappers over the new effects
for _, M in ipairs({ Hm, Cm }) do
	local s = load_script(M, "coop_quests_story")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
-- Money of a client's character is the host's: the host grants it (coop.money_grant), the client's Lua adds none.
local function grants(M)
	local out = {}
	for _, c in ipairs(M.money_calls) do
		if c.fn == "money_grant" and c.ok then out[#out + 1] = { c.peer, c.n } end
	end
	return out
end
local cm0 = Cm.actor._money
Cm.env.xr_logic.pick_section_from_condlist(nil, nil, { src = "%=reward_money(300)%" })
check(Cm.actor._money == cm0, "client: condlist reward skipped (the host's run counts)")
Cm.env.xr_effects.reward_money(nil, nil, { 50 })
check(Cm.actor._money == cm0 + 50, "client: dialog / script reward runs for the speaker")
cm0 = Cm.actor._money
local hm0 = Hm.actor._money
Hm.env.xr_logic.pick_section_from_condlist(nil, nil, { src = "%=reward_money(300)%" })
pump()
local gr = grants(Hm)
check(Hm.actor._money == hm0 + 300 and Cm.actor._money == cm0 and #gr == 1 and gr[1][1] == 1 and gr[1][2] == 300,
	"host: story condlist reward for every player (the client's share is coop.money_grant(1, 300))")
-- inside a task's rewards: not shared
Hm.on_complete = { story_t = function() Hm.env.xr_logic.pick_section_from_condlist(nil, nil, { src = "%=reward_money(100)%" }) end }
Hm.env.task_manager.get_task_manager():give_task("story_t", 700)
cm0, hm0 = Cm.actor._money, Hm.actor._money
Cm.env.task_manager.get_task_manager():set_task_completed("story_t")
pump()
local t = Hm.engine_tasks.story_t
Hm.env.task_manager.task_callback(t, Hm.env.task.completed)
pump()
gr = grants(Hm)
check(Hm.actor._money == hm0 and Cm.actor._money == cm0 and #gr == 2 and gr[2][1] == 1 and gr[2][2] == 100,
	"task reward only to the player who turned it in (coop.money_grant(1, 100))")
-- world spawns
print("== story world spawns")
local spawned = {}
Hm.env.xr_effects.spawn_strelok_notes = function() spawned.host = (spawned.host or 0) + 1 end
Cm.env.xr_effects.spawn_strelok_notes = function() spawned.client = (spawned.client or 0) + 1 end
for _, M in ipairs({ Hm, Cm }) do
	local s = load_script(M, "coop_quests_story")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
Cm.env.xr_effects.spawn_strelok_notes(Cm.actor, Cm.npc)
pump()
check(spawned.client == nil and spawned.host == 1, "client dialog spawn runs on the host")
Cm.env.xr_logic.pick_section_from_condlist(nil, nil, { src = "%=spawn_strelok_notes%" })
pump()
check(spawned.host == 1 and spawned.client == nil, "client condlist spawn skipped (host's logic spawns)")
-- psi helmets
print("== psi helmets")
local function bought(M)
	return function() M.env.alife_create_item("bad_psy_helmet", M.actor) end
end
Hm.env.dialogs_yantar = { give_player_bad_psi_helmet = bought(Hm) }
Cm.env.dialogs_yantar = { give_player_bad_psi_helmet = bought(Cm) }
for _, M in ipairs({ Hm, Cm }) do
	local s = load_script(M, "coop_quests_story")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
Cm.env.dialogs_yantar.give_player_bad_psi_helmet()
pump()
check(Hm.actor:object("bad_psy_helmet") ~= nil and proxy:object("bad_psy_helmet") == nil, "host got a helmet, the buyer's character not a second one")
-- client guards
Hm.env.xr_conditions.validate_smart_control_task = function() return true end
Cm.env.xr_conditions.validate_smart_control_task = function() return true end
for _, M in ipairs({ Hm, Cm }) do
	local s = load_script(M, "coop_quests_story")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
check(Cm.env.xr_conditions.validate_smart_control_task() == false and Hm.env.xr_conditions.validate_smart_control_task() == true,
	"host-cache precondition false on the client only")
-- DAO flash mine
print("== DAO flash mine")
local function dao(M)
	M.env.drx_da_main = { anomalies_hit_functions = {
		zone_mine_flash = function(s_hit, b, f, actor)
			M.env.level.change_game_time(0, 5, 10)
			M.env.CreateTimeEvent("zone_mine_flash", "zone_mine_flash", 0.1, function() M.flash_after = true return true end)
		end } }
end
dao(Hm)
dao(Cm)
for _, M in ipairs({ Hm, Cm }) do
	local s = load_script(M, "coop_quests_story")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
local zone = Cm.new_obj(900, "zone_mine_flash", vec(0, 0, 0))
Hm.new_obj(900, "zone_mine_flash", vec(0, 0, 0))
fire(Cm, "actor_on_before_hit", { draftsman = zone }, 1, 0)
pump()
check((Cm.time_jumps or 0) == 0 and Hm.time_jumps == 1, "client's flash hit: the host jumps the clock")
run_timers(Cm)
check(Cm.flash_after == true, "the flash's delayed part runs on the client")
fire(Cm, "actor_on_before_hit", { draftsman = zone }, 1, 0)
pump()
check(Hm.time_jumps == 1, "same mine within the window: no second jump")

-- DAO behaviours (audit C2): what a behaviour leaves running is this player's on a client
print("== DAO behaviours run for the client's actor")
local function dao_full(M)
	local da = { anomalies_hit_functions = {}, callbacks = {}, ticks = 0 }
	-- drx_da_main.script register_callback L295-311 / unregister_callback L313-321, actor_on_update L2891-2898
	function da.register_callback(callback, fn, on_end, key)
		if key and da.callbacks[key] then M.env.UnregisterScriptCallback(da.callbacks[key].callback, da.callbacks[key].func) end
		local k = key or (#da.callbacks + 1)
		da.callbacks[k] = { callback = callback, func = fn, on_end = on_end }
		M.env.RegisterScriptCallback(callback, fn)
		return k
	end
	function da.actor_on_update() da.ticks = da.ticks + 1 end
	M.env.drx_da_main = da
	M.env.UnregisterScriptCallback = function(name, f)
		local list = M.callbacks[name] or {}
		for i = #list, 1, -1 do if list[i] == f then table.remove(list, i) end end
	end
	return da
end
local function source_of(f) return debug.getinfo(f, "S").source end
local function has(M, name, f)
	for _, g in ipairs(M.callbacks[name] or {}) do if g == f then return true end end
	return false
end
local Hd, Cd = dao_full(Hm), dao_full(Cm)
-- an anomaly spawned with the level registered its update before the coop patch (bind_anomaly_field net_spawn L2733)
local spawned_hits = 0
local level_anomaly = function() spawned_hits = spawned_hits + 1 end
Cd.register_callback("actor_on_update", level_anomaly, nil, "anomaly_900_update")
local host_anomaly = function() end
Hd.register_callback("actor_on_update", host_anomaly, nil, "anomaly_900_update")
for _, M in ipairs({ Hm, Cm }) do
	M.callbacks.actor_on_update = {}
	if M == Cm then M.env.RegisterScriptCallback("actor_on_update", level_anomaly) end
	if M == Hm then M.env.RegisterScriptCallback("actor_on_update", host_anomaly) end
	local s = load_script(M, "coop_quests_story")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
local again = Cd.callbacks.anomaly_900_update and Cd.callbacks.anomaly_900_update.func
check(again ~= nil and again ~= level_anomaly and not has(Cm, "actor_on_update", level_anomaly) and has(Cm, "actor_on_update", again),
	"client: a handler registered before the patch is registered again")
check(again and source_of(again):find("coop_quests_story", 1, true) ~= nil,
	"client: it is a function of coop_quests_story now (the router runs it here)")
again()
check(spawned_hits == 1, "client: it still calls DAO's own")
check(Hd.callbacks.anomaly_900_update.func == host_anomaly and has(Hm, "actor_on_update", host_anomaly),
	"host: DAO's handlers stay as they are")
-- a behaviour registers a handler during play (zone_mine_sphere L2087-2098)
local resisted = 0
local sphere = function(s_hit) resisted = resisted + 1 end
Cd.register_callback("actor_on_before_hit", sphere, nil, "zone_mine_sphere")
local reg = Cd.callbacks.zone_mine_sphere.func
check(reg ~= sphere and source_of(reg):find("coop_quests_story", 1, true) ~= nil, "client: a behaviour's handler runs on this machine")
fire(Cm, "actor_on_before_hit", { type = 6 }, 1, 0)
check(resisted == 1, "client: the behaviour's effect reaches this player's hits")
Hd.register_callback("actor_on_before_hit", sphere, nil, "zone_mine_sphere")
check(Hd.callbacks.zone_mine_sphere.func == sphere, "host: a behaviour's handler is DAO's own")
-- the timed effects: driven here on a live client only
local before_c, before_h = Cd.ticks, Hd.ticks
fire(Cm, "actor_on_update")
fire(Hm, "actor_on_update")
check(Cd.ticks == before_c + 1, "client: DAO's timed effects are driven for this player")
check(Hd.ticks == before_h, "host: DAO drives its own (not twice)")

-- ---------------------------------------------------------------- PDA
print("== encyclopedia and achievements")
local function ency(M)
	M.callbacks.actor_on_achievement_earned = {} -- drop the first boot's listener (the module is loaded again below)
	local unl = {}
	M.ency_unl = unl
	M.env.ui_pda_encyclopedia_tab = {
		is_unlocked_article = function(s) return unl[s] == true end,
		is_unlocked_note = function(s) return unl[s] == true end,
		set_article = function() M.set_article = (M.set_article or 0) + 1 end,
		unlock_article = function(s) if unl[s] then return false end unl[s] = true M.env.ui_pda_encyclopedia_tab.set_article(s) M.env.actor_menu.set_notification() return true end,
		unlock_note = function(s) if unl[s] then return false end unl[s] = true M.env.actor_menu.set_notification() return true end,
	}
	M.env.actor_menu = { set_notification = function() M.notif = (M.notif or 0) + 1 end }
	M.achv = {}
	M.env.game_statistics = { has_actor_achievement = function(n) return M.achv[n] == true end }
	M.env.game_achievements = { iron_curtain_rewards = function()
		M.actor:give_money(40000)
		M.env.SendScriptCallback("actor_on_achievement_earned", "iron_curtain", "msg")
	end }
	M.env.RegisterScriptCallback("actor_on_achievement_earned", function(n) M.achv[n] = true end)
end
ency(Hm)
ency(Cm)
for _, M in ipairs({ Hm, Cm }) do
	local s = load_script(M, "coop_quests_pda")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
Cm.env.ui_pda_encyclopedia_tab.unlock_article("art_1")
pump()
check(Hm.ency_unl.art_1 == true and (Hm.set_article or 0) == 0 and (Hm.notif or 0) == 0, "client's article unlocked on the host, silently")
check(count_sent(Hm, "quests.ency") == 0, "host does not echo it back to its sender")
Hm.env.ui_pda_encyclopedia_tab.unlock_note("encyclopedia__notes_x")
pump()
check(Cm.ency_unl["encyclopedia__notes_x"] == true and (Cm.notif or 0) >= 1, "host's note unlocked on the client with the note signal")
local hmoney = Hm.actor._money
local g_ach = #grants(Hm)
Cm.env.SendScriptCallback("actor_on_achievement_earned", "iron_curtain", "msg")
pump()
check(Hm.achv.iron_curtain == true and Hm.actor._money == hmoney + 40000, "client's achievement earned by the host with its reward")
check(count_sent(Hm, "quests.achv") == 0, "no echo loop")
local ga = grants(Hm)
check(#ga == g_ach + 1 and ga[#ga][1] == 1 and ga[#ga][2] == 40000, "the earner gets its 40000 from the host: exactly one coop.money_grant(1, 40000)")

-- Money of achievements is the host's (F2 T6): the client's stock iron_curtain_rewards would give_money(40000) locally
-- (a Script-bucket income); on a client that part is dropped, the earned callback (news) stays, the host grants.
local function reboot_pda()
	ency(Hm)
	ency(Cm)
	for _, M in ipairs({ Hm, Cm }) do
		local s = load_script(M, "coop_quests_pda")
		s.on_game_start()
		fire(M, "actor_on_first_update")
	end
end
print("== achievement money is the host's")
reboot_pda()
do
	-- the client earns it through its own stock function
	local hm0, cm0, gb = Hm.actor._money, Cm.actor._money, #grants(Hm)
	Cm.env.game_achievements.iron_curtain_rewards()
	check(Cm.achv.iron_curtain == true and Cm.actor._money == cm0, "client: the earned callback fires, no local give_money")
	pump()
	local g = grants(Hm)
	check(Hm.achv.iron_curtain == true and Hm.actor._money == hm0 + 40000, "host: earned too, with its own money")
	check(#g == gb + 1 and g[#g][1] == 1 and g[#g][2] == 40000, "earner: exactly one coop.money_grant(1, 40000)")
	check(Cm.actor._money == cm0 and #Cm.money_calls == 0, "the client's Lua never adds the money or calls the ledger")
	-- the same claim again (a client that repeats it): no second grant for that character
	Cm.env.coop_quests_core.send("achv_got", { a = "iron_curtain" }, 0)
	Cm.env.coop_quests_core.send("achv", { a = "iron_curtain" }, 0)
	pump()
	check(#grants(Hm) == gb + 1, "one money reward per character and achievement")
end
reboot_pda()
do
	-- the host earns it: every client applies it without the money and the host grants after the client says it has it
	local hm0, cm0, gb = Hm.actor._money, Cm.actor._money, #grants(Hm)
	Hm.env.game_achievements.iron_curtain_rewards()
	pump()
	local g = grants(Hm)
	check(Hm.actor._money == hm0 + 40000, "host earner: its own stock reward")
	check(Cm.achv.iron_curtain == true and Cm.actor._money == cm0, "client: earned with the news, no local money")
	check(#g == gb + 1 and g[#g][1] == 1 and g[#g][2] == 40000, "host earner: exactly one coop.money_grant(1, 40000) for the client")
end
reboot_pda()
do
	-- a client that has the achievement already is not paid again
	Cm.achv.iron_curtain = true
	local gb = #grants(Hm)
	Hm.env.game_achievements.iron_curtain_rewards()
	pump()
	check(#grants(Hm) == gb, "client with the achievement already: no money")
	-- only the achievements with a money reward, only from a client
	Cm.env.coop_quests_core.send("achv_got", { a = "bookworm_food" }, 0)
	Cm.env.coop_quests_core.send("achv_got", { a = "../x" }, 0)
	pump()
	check(#grants(Hm) == gb, "an achievement without a money reward, a bad name: nothing")
	check(#grants(Cm) == 0, "a client never grants")
end

-- F2 T6b: the client's claim (achv_got) is repeated until the host answers it (achv_ack), at most once in 5 s and 10
-- times; the host pays and answers only if it has the achievement itself.
print("== achievement claim is retried until the host answers")
local function claims_sent(M) return count_sent(M, "quests.achv_got") end
reboot_pda()
do
	local gb, acks = #grants(Hm), count_sent(Hm, "quests.achv_ack")
	local real = Hm.handlers["quests.achv_got"]
	Hm.handlers["quests.achv_got"] = function() end -- the host is not ready: the claim is lost
	local c0 = claims_sent(Cm)
	Hm.env.game_achievements.iron_curtain_rewards() -- the host earns it, the client applies it and claims
	pump()
	check(Cm.achv.iron_curtain == true and claims_sent(Cm) == c0 + 1, "the client claims once at once")
	check(#grants(Hm) == gb, "the lost claim paid nothing")
	NOW = NOW + 4900
	fire(Cm, "actor_on_update")
	pump()
	check(claims_sent(Cm) == c0 + 1, "not again before 5 s")
	NOW = NOW + 200
	fire(Cm, "actor_on_update")
	fire(Cm, "actor_on_update")
	pump()
	check(claims_sent(Cm) == c0 + 2, "after 5 s once, not twice for two updates")
	-- the client is not in the host's world (a world load): the claim waits
	Cm.env.coop.is_live = function() return false end
	NOW = NOW + 60000
	fire(Cm, "actor_on_update")
	pump()
	check(claims_sent(Cm) == c0 + 2, "a client that is not live sends nothing")
	Cm.env.coop.is_live = function() return true end
	-- the host is ready: the next claim is paid once and answered, and the client stops
	Hm.handlers["quests.achv_got"] = real
	fire(Cm, "actor_on_update")
	pump()
	local g = grants(Hm)
	check(claims_sent(Cm) == c0 + 3 and #g == gb + 1 and g[#g][1] == 1 and g[#g][2] == 40000,
		"the claim that got through is paid: exactly one coop.money_grant(1, 40000)")
	check(count_sent(Hm, "quests.achv_ack") == acks + 1 and last_sent(Hm, "quests.achv_ack").a == "iron_curtain",
		"the host answers the claim it paid")
	NOW = NOW + 60000
	fire(Cm, "actor_on_update")
	pump()
	check(claims_sent(Cm) == c0 + 3 and #grants(Hm) == gb + 1, "answered: no more claims, no more money")
end
reboot_pda()
do
	-- T6b review M3: a claim belongs to the host it was made to; another host (a new session) never gets it
	Hm.handlers["quests.achv_got"] = function() end
	local c0 = claims_sent(Cm)
	Hm.env.game_achievements.iron_curtain_rewards()
	pump()
	check(claims_sent(Cm) == c0 + 1, "claimed to this host")
	Cm.players[2].nick = "another host"
	NOW = NOW + 6000
	fire(Cm, "actor_on_update")
	pump()
	check(claims_sent(Cm) == c0 + 1, "the host is another one now: no claim to it")
	check(has_log(Cm, "another session"), "the dropped claim is in the log")
	Cm.players[2].nick = nil
	NOW = NOW + 60000
	fire(Cm, "actor_on_update")
	pump()
	check(claims_sent(Cm) == c0 + 1, "and it stays dropped")
end
reboot_pda()
do
	-- the host never answers: ten attempts, five seconds apart, then the client gives up
	Hm.handlers["quests.achv_got"] = function() end
	local c0 = claims_sent(Cm)
	Hm.env.game_achievements.iron_curtain_rewards()
	pump()
	for _ = 1, 30 do
		NOW = NOW + 5000
		fire(Cm, "actor_on_update")
		pump()
	end
	check(claims_sent(Cm) == c0 + 10, "ten attempts and no more (" .. tostring(claims_sent(Cm) - c0) .. ")")
	check(has_log(Cm, "gave up"), "the client says it gave up")
end
reboot_pda()
do
	-- the host pays only what it has itself
	local gb, acks = #grants(Hm), count_sent(Hm, "quests.achv_ack")
	Hm.achv.iron_curtain = nil
	Cm.env.coop_quests_core.send("achv_got", { a = "iron_curtain" }, 0)
	pump()
	check(#grants(Hm) == gb and count_sent(Hm, "quests.achv_ack") == acks, "the host has no such achievement: no payment, no answer")
	Hm.achv.iron_curtain = true
	Cm.env.coop_quests_core.send("achv_got", { a = "iron_curtain" }, 0)
	pump()
	check(#grants(Hm) == gb + 1 and count_sent(Hm, "quests.achv_ack") == acks + 1, "it has it now: paid and answered")
	Cm.env.coop_quests_core.send("achv_got", { a = "iron_curtain" }, 0)
	pump()
	check(#grants(Hm) == gb + 1 and count_sent(Hm, "quests.achv_ack") == acks + 2,
		"a repeated claim is answered again and not paid again")
	-- the earner is paid the same way: after the host applied the achievement, and only if the host has it
	local ge = #grants(Hm)
	Hm.env.game_statistics.has_actor_achievement = function() return false end
	Cm.env.coop_quests_core.send("achv", { a = "iron_curtain" }, 0)
	pump()
	check(#grants(Hm) == ge, "an earner is not paid for an achievement the host could not set")
end

print("== NPC PDA messages, stash reveal, box")
Hm.env.ui_pda_npc_tab = { register_pda = function(npc, sec, id)
	Hm.env.se_save_var(id, nil, "info", { state = "default", contact = { name = "Petro" }, msg = { { topic_title = "t", stash = 950 } } })
end }
Cm.env.ui_pda_npc_tab = { register_pda = function() Cm.client_reg = true end }
Hm.new_obj(960, "itm_pda_common", vec(0, 0, 0))
Cm.new_obj(960, "itm_pda_common", vec(0, 0, 0))
for _, M in ipairs({ Hm, Cm }) do
	local s = load_script(M, "coop_quests_pda")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
local corpse = Hm.new_obj(701, "sim_default_stalker_1", vec(6, 0, 0), { _stalker = true, _dead = true })
Hm.env.ui_pda_npc_tab.register_pda(Hm.npc, "itm_pda_common", 961) -- alive owner: not broadcast
pump()
check(Cm.se_vars[961] == nil, "a living stalker's PDA is not broadcast")
Hm.env.ui_pda_npc_tab.register_pda(corpse, "itm_pda_common", 960)
Cm.env.ui_pda_npc_tab.register_pda(Cm.npc, "itm_pda_common", 960)
pump()
local info = Cm.se_vars[960] and Cm.se_vars[960].info
check(info and info.contact.name == "Petro" and info.msg[1].stash == 950 and Cm.client_reg == nil,
	"PDA messages are the host's on the client (no local roll)")
local filled = {}
Hm.env.treasure_manager = { caches = {}, set_random_stash = function(spot, hint, b, id) filled[id] = spot end,
	try_spawn_treasure = function(box) filled.box = box:id() end }
Hm.env.coop_quests_core.request_host_action = Hm.env.coop_quests_core.request_host_action
Cm.env.coop_quests_core.request_host_action("stash", { b = 950, s = "treasure", h = "hint" })
Hm.new_obj(950, "inventory_box", vec(3, 0, 0), { _box = true })
pump()
check(filled[950] == "treasure", "stash revealed on a client is filled by the host")
local box_c = Cm.new_obj(950, "inventory_box", vec(3, 0, 0), { _box = true })
fire(Cm, "physic_object_on_use_callback", box_c, Cm.actor)
proxy._pos = vec(3, 0, 0)
pump()
check(filled.box == 950, "opening a stash box on a client fills it on the host")
proxy._pos = vec(4, 0, 0)

print("== rankings")
Hm.env.pda = {
	calculate_rankings = function() end,
	get_coc_ranking_list = function() return { 0, 500, 710 } end,
	get_rankings_array_size = function() return 3 end,
	coc_rankings_set_name = function(i) return "stock" .. i end,
	coc_rankings_can_show = function() return true end,
}
Cm.env.pda = {
	calculate_rankings = function() Cm.stock_rank = (Cm.stock_rank or 0) + 1 end,
	get_rankings_array_size = function() return 3 end,
	coc_rankings_set_name = function(i) return "stock" .. i end,
	coc_rankings_can_show = function() return true end,
}
Hm.env.alife = function() return { object = function(_, id)
	local o = Hm.objects[id]
	if not (o and o._stalker) then return nil end
	return { id = id, character_name = function() return "se_" .. id end, rank = function() return id end,
		community = function() return "stalker" end, reputation = function() return 0 end,
		character_icon = function() return "ic" end, clsid = function() return 1 end, alive = function() return true end }
end } end
Hm.env.IsStalker = function(o, cls) if cls then return true end return type(o) == "table" and o._stalker == true end
Hm.env.ranks = { get_obj_rank_name = function() return "novice" end, get_se_obj_rank_name = function() return "veteran" end }
Cm.env.ranks = Hm.env.ranks
Hm.env.utils_obj = { get_reputation_name = function() return "st_reputation_neutral" end }
Cm.env.utils_obj = Hm.env.utils_obj
Hm.env.story_objects = { story_id_by_object_id = {} }
for _, M in ipairs({ Hm, Cm }) do
	local s = load_script(M, "coop_quests_pda")
	s.on_game_start()
	fire(M, "actor_on_first_update")
end
Cm.env.pda.calculate_rankings()
check(Cm.stock_rank == 1, "stock list until the host answers")
pump()
check(Cm.env.pda.coc_rankings_set_name(3) == "3. se_710" and Cm.env.pda.coc_rankings_set_name(2):find("name_0", 1, true),
	"client draws the host's list (its own row by its own name)")

-- ---------------------------------------------------------------- coop_tasks additions
print("== coop_tasks additions")
Cm.env.save_var(Cm.actor, "x_task_1", { a = 1 })
Cm.env.save_var(Cm.actor, "x_task_1_fetch", "bread")
Cm.env.save_var(Cm.actor, "x_task_10_fetch", "vodka")
Hm.ini.x_task_1 = {}
Cm.ini.x_task_1 = {}
Cm.env.task_manager.get_task_manager():give_task("x_task_1", 700)
pump()
check(Hm.env.load_var(Hm.actor, "x_task_1_fetch") == "bread" and Hm.env.load_var(Hm.actor, "x_task_10_fetch") == nil,
	"task vars: another task's keys with the same prefix are not sent")
check(Cm.env.coop_tasks.set_local_task("pw_task") == false, "personal task refused without the engine side")
Cm.env.coop.story_local_task = function() return true end
check(Cm.env.coop_tasks.set_local_task("pw_task") == true, "personal task accepted with coop.story_local_task")
Cm.ini.pw_task = {}
local before = count_sent(Cm, "coop_tq")
Cm.env.task_manager.get_task_manager():give_task("pw_task", nil)
check(Cm.on_init.pw_task == 1 and count_sent(Cm, "coop_tq") == before, "personal task given locally, not sent to the host")

-- ---------------------------------------------------------------- single player
print("== no session")
for _, M in ipairs({ Hm, Cm }) do M.active = false end
Cm.gen_calls = 0
Cm.env.axr_task_manager.generate_available_tasks(Cm.npc, nil)
check(Cm.gen_calls == 1, "offers: stock generation without a session")
local hm1 = Hm.actor._money
Hm.env.xr_logic.pick_section_from_condlist(nil, nil, { src = "%=reward_money(10)%" })
check(Hm.actor._money == hm1 + 10 and count_sent(Hm, "coop_trw") == count_sent(Hm, "coop_trw"), "rewards: stock without a session")
Hm.checks = 0
Hm.env.task_manager.get_task_manager():update()
check(Hm.checks > 0 and Hm.actor:object("quest_doc") == nil, "task checks: stock without a session")

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
