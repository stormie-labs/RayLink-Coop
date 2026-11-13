-- The PDA taskboard of a client (coop_quests_offer patch_taskboard): a row's title, text and picture.
-- Live, 2026-11-13, build 48: every "bring me an item" offer on the board had "-" for a title and the noise picture for an
-- icon, with the right description under it. The stock board steals the task script's deferred "needs:" line; on a client
-- the task script does not run (the host prepared the offer), so nobody drew the line: get_details answered nil.
-- Run: tools\test_lua.cmd taskboard_offer
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_tasks", "coop_quests_offer" }

local function setup_world(M)
	local e = M.env
	M.ini.bounty_t = { on_job_descr = "%=setup_bounty_task(bounty_t)%", job_descr = "bounty_t_descr" }
	M.ini.fetch_t = { fetch_descr = "fetch_t_fetch_descr", fetch_func = "%=setup_fetch_task(fetch_t_fetch:x:1:2)%", job_descr = "fetch_t_job" }
	M.ini.plain_t = { job_descr = "plain_t_descr" }
	M.npc = M.new_obj(700, "esc_m_trader", vec(5, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = M.npc }
	M.new_obj(710, "sim_default_bandit_1", vec(300, 0, 0), { _stalker = true, _group = 711 })
	M.new_obj(711, "squad", vec(300, 0, 0))
	M.npc_tasks = { [700] = { "bounty_t", "fetch_t", "plain_t" } }
	e.xr_effects.setup_bounty_task = function(actor, npc, p)
		e.axr_task_manager.bounties_by_id[p[1]] = 710
		e.save_var(e.db.actor, p[1], { target_id = 710 })
		e.CreateTimeEvent(0, "setup_bounty_task", 0, function()
			e.db.actor:give_talk_message2("Bounty", "Kill name_710", "icon_710", "iconed_answer_item")
			return true
		end)
	end
	e.xr_effects.setup_fetch_task = function(actor, npc, p)
		e.save_var(e.db.actor, p[1], "medkit")
		e.save_var(e.db.actor, p[1] .. "_count", 2)
		e.dialogs._FETCH_TEXT = e.ui_item.get_sec_name("medkit")
		e.CreateTimeEvent(0, "setup_fetch_task", 0, e.tasks_fetch.postpone_fetch_for_next_frame, p[1], "medkit", 2)
	end
end

-- the board's two modules, in the shape the pack has them (pda_taskboard.script, ui_pda_taskboard_tab.script)
local function add_board(M)
	local e = M.env
	M.board = { stock_prepared = 0, refreshed = 0 }
	local Tab = { task_list = { RemoveAll = function() end, GetSelectedItem = function() return nil end } }
	Tab.OnBtnRefreshClicked = function() M.board.stock_refresh = true end
	Tab.OnTaskClicked = function() end
	Tab.DrawCategoryList = function() end
	e.ui_pda_taskboard_tab = { pda_taskboard_tab = Tab }
	e.pda_taskboard = {
		-- stock: runs on_job_descr and the fetch function of the task (world effects), the board steals their deferred line
		prepare_task = function(task_data) M.board.stock_prepared = M.board.stock_prepared + 1 end,
		-- stock: the stolen line by its id; a task whose script drew none has no id
		get_details = function(task_info) return nil end,
		get_long_task_description = function(task_data) return "long " .. tostring(task_data.task_id) end,
		get_nearby_npcs = function() return { M.npc } end,
		refresh_tasks = function() M.board.refreshed = M.board.refreshed + 1 end,
	}
	M.tab = Tab
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
add_board(Cm)
Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true })
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0)
boot(Hm)
boot(Cm)
local pt = Cm.env.pda_taskboard

print("== the board asks the host for the offers of the NPCs around")
Cm.tab:OnBtnRefreshClicked()
check(Cm.board.stock_refresh == nil, "the stock refresh did not run: the rows are the host's")
pump()
check(Cm.board.refreshed == 1, "the board is filled once the host answered")

print("== a row of a task that asks for an item")
local fetch_row = { task_id = "fetch_t", npc_id = 700 }
pt.prepare_task(fetch_row)
check(Cm.board.stock_prepared == 0, "the task's own script is not run on the client")
check(fetch_row.task_description == "long fetch_t", "the description is the board's own, with the host's item")
check(Cm.env.load_var(Cm.actor, "fetch_t_fetch") == "medkit", "the host's item is this player's task var")
Cm.talk_msgs = nil
local d = pt.get_details(fetch_row)
check(type(d) == "table", "the row has details")
check(d and d.task_title == "needs", "its title is the \"needs\" caption, in this player's language")
check(d and d.task_details == "medkit x2", "its text names the item and the number")
check(d and d.task_icon == "ico", "its picture is the task's icon, not the noise")
check(Cm.talk_msgs == nil, "the line is not written into a talk window: nobody is talking")
local again = pt.get_details(fetch_row)
check(again and again.task_details == "medkit x2", "asked again, the same answer")

print("== a row of a task whose line the host drew")
local bounty_row = { task_id = "bounty_t", npc_id = 700 }
pt.prepare_task(bounty_row)
d = pt.get_details(bounty_row)
check(d and d.task_title == "Bounty" and d.task_details == "Kill name_710" and d.task_icon == "icon_710", "the host's line is the row's details")

print("== a row of a task with no line at all")
local plain_row = { task_id = "plain_t", npc_id = 700 }
pt.prepare_task(plain_row)
check(pt.get_details(plain_row) == nil, "no details: the board shows its plain row")

print("== details the stock board has are left alone")
pt.prepare_task(fetch_row)
local stock_details = { task_title = "stock", task_details = "stock", task_icon = "stock" }
local orig = Cm.env.pda_taskboard.get_details
check(orig == pt.get_details, "the patched function is the board's")
-- the stock answer wins when there is one: rebuild the board with a stock that answers
Cm.active = false
check(pt.get_details(fetch_row) == nil, "out of a session: the stock answer, nothing of ours")
Cm.active = true

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
