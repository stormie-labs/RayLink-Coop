-- Server task authority belongs to an active world. Map servers mirror its task journal.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function load_mode(M)
	local function load(name) return load_script(M, name) end
	modes.live(load("coop_mode"), load)
	load("coop_quests_core")
	return load("coop_tasks")
end

print("== a map server mirrors the world's group tasks")
do
	local M = machine("client", 0x101)
	M.env.coop.is_map_server = function() return true end
	M.env.coop.levels = { split = function() return true end }
	local tasks = load_mode(M)
	local calls = 0
	M.env.xr_effects.test_map_task_fx = function() calls = calls + 1 end
	M.env.coop_tasks_rewards.forward_allow("test_map_task_fx")
	tasks.on_game_start()
	M.ini.test_shared = {}
	M.tm:give_task("test_shared", 777)
	check(M.on_init.test_shared == nil, "the map server does not run the stock group task initializer")
	check(last_sent(M, "coop_tq") ~= nil, "the map server routes the give to the world")
	local vars = M.env.coop_main.encode({ drx_sl_probe_counter = 4 })
	M.handlers.coop_tv(vars, 1)
	check(M.env.load_var(M.actor, "drx_sl_probe_counter") == nil, "a player cannot set map server task vars")
	M.handlers.coop_tv(vars, 0)
	check(M.env.load_var(M.actor, "drx_sl_probe_counter") == 4, "the map server applies the world's task counter")
	tasks.load_effects({ coop_task_fx_done = { [42] = true } })
	M.handlers.coop_trw("k=sfx;f=stest_map_task_fx;q=n42", 0)
	check(calls == 0 and last_sent(M, "coop_trw_ok") ~= nil, "the map server acknowledges a previously run effect without repeating it")
	M.handlers.coop_trw("k=sfx;f=stest_map_task_fx;q=n43", 0)
	local saved = {}
	tasks.save_effects(saved)
	check(calls == 1 and saved.coop_task_fx_done and saved.coop_task_fx_done[42] and saved.coop_task_fx_done[43],
		"the map server runs new effects once and saves the mirror's receipts")
	check(saved.coop_task_fx == nil, "the map server never saves the world's reward ledger")
end

print("== a world process can answer before its session, but its task authority is session-only")
do
	local W = machine("host", 0)
	W.active = false
	W.env.coop.is_host = function() return W.active end
	W.env.coop.is_dedicated = function() return true end
	local tasks = load_mode(W)
	local trust = load_script(W, "coop_quests_trust")
	trust.on_game_start()
	local task_manager = W.env.task_manager
	local get_tm, lookups = task_manager.get_task_manager, 0
	task_manager.get_task_manager = function() lookups = lookups + 1; return get_tm() end
	local saved = { coop_task_facts = false }
	check(W.env.coop_mode.decides_world(), "the facade recognises the world process before its session")
	fire(W, "actor_on_update")
	check(lookups == 0, "startup does not scan the world's task facts")
	fire(W, "save_state", saved)
	check(saved.coop_task_facts == false, "startup leaves the saved facts alone")
	local function stock(value) return value, tasks.in_reward_scope() end
	local value, scoped = tasks.with_recipient(nil, stock, "recipient")
	check(value == "recipient" and not scoped, "startup keeps the stock recipient callback even without a player")
	value, scoped = tasks.with_participants({}, 0, stock, "participants")
	check(value == "participants" and not scoped, "startup keeps the stock participants callback outside a coop reward scope")
	local money = W.actor._money
	W.env.coop_tasks_items.give_to_peer(0, -7)
	check(W.actor._money == money, "startup does not give the world ghost a story payout")
	W.active = true
	W.players = { { id = 1, avatar_id = 500 } }
	fire(W, "actor_on_update")
	check(lookups == 1, "the world scans right when its session starts")
	fire(W, "save_state", saved)
	check(type(saved.coop_task_facts) == "table", "the active world owns and saves its task facts")
	value, scoped = tasks.with_recipient(1, stock, "recipient")
	check(value == "recipient" and scoped, "the active world runs the recipient callback in its reward scope")
	value, scoped = tasks.with_participants({ 500 }, 1, stock, "participants")
	check(value == "participants" and scoped, "the active world runs the participants callback in its reward scope")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
