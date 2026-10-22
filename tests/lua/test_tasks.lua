-- Anomaly Coop W3c temp test: coop_tasks.script on a simulated host + client (two Lua environments).
-- Not shipped. Run: tools\test_lua.cmd tasks
local SCRIPT = "gamedata/scripts/coop_tasks.script"
dofile("tests/lua/support/stubs.d/money.lua") -- install_money_stubs: coop.money_* of the host ledger (F2 T1)

FAILS, PASSES = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local NOW = 100000
local QUEUE = {} -- { to = machine, name, payload, from }
local MACHINES = {}

local next_item_id = 1000

-- ---------------------------------------------------------------- one machine
local function machine(role, self_peer)
	local M = { role = role, self_peer = self_peer, log = {}, handlers = {}, sent = {} }
	local env = setmetatable({}, { __index = _G })
	env._G = env
	M.env = env

	function env.printf(fmt, ...)
		local line = string.format(fmt, ...)
		M.log[#M.log + 1] = line
		print("    [" .. role .. "] " .. line)
	end
	function env.time_global() return NOW end

	-- objects and inventories
	local objects = {}
	local ObjMT = {}
	ObjMT.__index = ObjMT
	function ObjMT:id() return self._id end
	function ObjMT:section() return self._sec end
	function ObjMT:condition() return self._cond or 1 end
	function ObjMT:get_remaining_uses() return self._uses or 1 end
	function ObjMT:iterate_inventory(f, x)
		local copy = {}
		for _, it in ipairs(self._inv) do copy[#copy + 1] = it end
		for _, it in ipairs(copy) do
			if f(x, it) == true then return end
		end
	end
	function ObjMT:object(sec)
		for _, it in ipairs(self._inv) do if it._sec == sec then return it end end
	end
	function ObjMT:transfer_item(item, to)
		for i, it in ipairs(self._inv) do
			if it == item then
				table.remove(self._inv, i)
				to._inv[#to._inv + 1] = item
				item._parent = to
				M.transfers = (M.transfers or 0) + 1
				return
			end
		end
	end
	function ObjMT:give_money(n) self._money = (self._money or 0) + n end
	function ObjMT:money() return self._money or 0 end
	function ObjMT:is_talking() return M.talking == true end
	function ObjMT:get_task(id, active_only)
		local t = M.engine_tasks[id]
		if not t then return nil end
		if active_only and t.state ~= "in" then return nil end
		return t
	end
	function M.new_obj(id, inv)
		local o = setmetatable({ _id = id, _inv = inv or {}, _money = 0 }, ObjMT)
		objects[id] = o
		return o
	end
	function M.give_item(owner, sec, opts)
		next_item_id = next_item_id + 1
		local it = setmetatable({ _id = next_item_id, _sec = sec, _inv = {}, _parent = owner }, ObjMT)
		if opts then
			it._cond = opts.cond
			it._uses = opts.uses
		end
		owner._inv[#owner._inv + 1] = it
		objects[it._id] = it
		return it
	end
	function M.count(owner, sec)
		local n = 0
		for _, it in ipairs(owner._inv) do if it._sec == sec then n = n + 1 end end
		return n
	end
	M.engine_tasks = {}

	local actor = M.new_obj(0)
	M.actor = actor
	env.db = { actor = actor, storage = { [0] = { pstor = {} } } }
	env.AC_ID = 0
	env.level = { object_by_id = function(id) return objects[id] end }
	function env.alife_release_id(id)
		local o = objects[id]
		if o and o._parent then
			for i, it in ipairs(o._parent._inv) do
				if it == o then table.remove(o._parent._inv, i) break end
			end
		end
		objects[id] = nil
		M.released = (M.released or 0) + 1
	end
	function env.alife_create_item(sec, obj)
		local owner = obj
		if type(obj) == "table" and type(obj.id) == "function" then owner = objects[obj:id()] end
		M.created = M.created or {}
		M.created[#M.created + 1] = { sec = sec, owner = owner and owner._id }
		if owner then return M.give_item(owner, sec) end
	end
	function env.IsItem(kind, sec)
		if kind == "multiuse" and sec == "bandage_pack" then return 3 end
		return nil
	end
	function env.load_var(obj, k, def)
		local v = env.db.storage[obj:id()].pstor[k]
		if v == nil then return def end
		return v
	end
	function env.save_var(obj, k, v) env.db.storage[obj:id()].pstor[k] = v end

	-- coop engine API
	M.share = 0
	env.get_console = function()
		return { get_integer = function(_, name) return name == "coop_share_rewards" and M.share or 0 end }
	end
	env.coop = {
		is_active = function() return true end,
		is_host = function() return role == "host" end,
		is_client = function() return role == "client" end,
		is_live = function() return true end,
		self_id = function() return self_peer end,
		players = function() return M.players end,
		avatar_of = function(peer)
			for _, p in ipairs(M.players) do if p.id == peer then return p.avatar_id end end
		end,
		to_host_id = function(id) return id end,
		to_local_id = function(id) return id end,
		send_event = function(name, payload, target)
			M.sent[#M.sent + 1] = { name = name, payload = payload, target = target }
			for _, other in ipairs(MACHINES) do
				if other ~= M then
					local to_it = (target == -1 or target == nil) or (target == other.self_peer)
					if to_it then QUEUE[#QUEUE + 1] = { to = other, name = name, payload = payload, from = self_peer } end
				end
			end
			return true
		end,
	}
	M.money_calls = {} -- the host ledger: every coop.money_* call of this machine
	install_money_stubs(env.coop, { calls = M.money_calls, is_host = function() return role == "host" end })
	env.coop_main = {
		add_event_handler = function(name, f) M.handlers[name] = f end,
	}
	M.callbacks = {}
	env.RegisterScriptCallback = function(name, f) M.callbacks[name] = f end
	M.timers = {}
	env.CreateTimeEvent = function(ev, act, t, f, ...)
		M.timers[#M.timers + 1] = { f = f, p = { ... } }
	end

	-- news / money / goodwill
	M.news = {}
	M.money_news = {}
	env.news_manager = {
		relocate_item = function(a, typ, sec, n) M.news[#M.news + 1] = typ .. ":" .. sec .. "x" .. tostring(n) return true end,
		relocate_money = function(a, typ, n) M.money_news[#M.money_news + 1] = typ .. ":" .. n end,
		send_task = function(a, typ, t) M.task_news = (M.task_news or "") .. typ .. ";" end,
	}
	env.dialogs = {
		relocate_money = function(victim, n, typ)
			if typ == "in" then actor:give_money(n) end
			env.news_manager.relocate_money(actor, typ, n)
		end,
	}
	-- stock payouts that do not use dialogs.relocate_money: db.actor:give_money + the news line (tasks_multifetch.script
	-- remove_items_and_pay, tasks_defense.script barrier_defense_*_complete)
	env.xr_effects_multifetch_pay = 900
	env.tasks_defense = {
		barrier_defense_monolith_complete = function(a, b)
			env.news_manager.relocate_money(actor, "in", 40000)
			actor:give_money(40000)
		end,
		barrier_defense_zombie_complete = function(a, b)
			env.news_manager.relocate_money(actor, "in", 25000)
			actor:give_money(25000)
		end,
	}
	env.dialogs_mlr = { show_goodwill_change_message = function(c) M.gw_msg = c end }
	env.axr_task_manager = { bounties_by_id = {} }
	M.goodwill = {}
	env.task = { completed = 2, fail = 0, in_progress = 1 }
	env.xr_effects = {
		inc_faction_goodwill_to_actor = function(a, npc, p)
			local id = a:id()
			M.goodwill[id] = (M.goodwill[id] or 0) + tonumber(p[2])
			if p[3] then M.gw_msg = p[1] end
		end,
		dec_faction_goodwill_to_actor = function(a, npc, p)
			local id = a:id()
			M.goodwill[id] = (M.goodwill[id] or 0) - tonumber(p[2])
		end,
		drx_sl_money_task_payment = function(a, npc, p)
			actor:give_money(-(tonumber(env.load_var(actor, p[1], 0)) or 0))
		end,
		drx_sl_change_factions = function(a, npc, p) M.faction = p[1] end,
		multifetch_remove = function(a, npc, p)
			actor:give_money(env.xr_effects_multifetch_pay)
			env.news_manager.relocate_money(actor, "in", env.xr_effects_multifetch_pay)
		end,
		remove_item = function(a, npc, p)
			local left = tonumber(p[2]) or 1
			actor:iterate_inventory(function(_, it)
				if left > 0 and it._sec == p[1] then env.alife_release_id(it._id); left = left - 1 end
			end)
		end,
		remove_fetch_item = function(a, npc, p)
			local sec = env.load_var(actor, p[1])
			if sec and actor:object(sec) then env.xr_effects.remove_item(a, npc, { sec, 1 }) end
		end,
		remove_artefact_item = function(a, npc, p)
			local sec = env.load_var(actor, p[1])
			local o = actor:object(sec)
			if o then env.alife_release_id(o._id) end
		end,
	}
	-- stock-like fetch reward: one second later, takes the items from the actor and pays
	env.xr_effects.fetch_reward_and_remove = function(a, npc, p)
		local sec = env.load_var(actor, p[1])
		env.CreateTimeEvent(0, "delay_reward", 1, function()
			local need = env.load_var(actor, p[1] .. "_count") or 1
			local got = 0
			actor:iterate_inventory(function(_, it)
				if got < need and it._sec == sec then env.alife_release_id(it._id); got = got + 1 end
			end)
			if got == 0 then M.fetch_failed = true return true end
			env.dialogs.relocate_money(actor, 1000, "in")
			env.news_manager.relocate_item(actor, "out", sec, got)
			return true
		end)
	end
	env.task_status_functor = {
		actor_has_fetch_item = function(tsk, task_id)
			local sec = env.load_var(actor, task_id .. "_fetch")
			if not sec then return end
			local need = env.load_var(actor, task_id .. "_fetch_count") or 1
			tsk.stage = (M.count(actor, sec) >= need) and 1 or 0
		end,
	}

	-- task manager (luabind-like class: methods looked up in the class table)
	local ini = { fetch_1 = true, fetch_2 = true, story_1 = true, cf_1 = true, stage_t = true, bounty_1 = true }
	M.on_init = {}
	M.on_complete = {}
	local CRandomTask = {}
	CRandomTask.__index = CRandomTask
	function CRandomTask:give_task(id, giver)
		M.on_init[id] = (M.on_init[id] or 0) + 1
		self.task_info[id] = { id = id, stage = 0, status = "selected", task_giver_id = giver, status_functor = "actor_has_fetch_item" }
		M.engine_tasks[id] = { state = "in", get_id = function() return id end }
	end
	function CRandomTask:set_task_completed(id) if self.task_info[id] then self.task_info[id].forced_status = "complete" end end
	function CRandomTask:set_task_failed(id) if self.task_info[id] then self.task_info[id].forced_status = "fail" end end
	function CRandomTask:set_task_cancelled(id)
		if self.task_info[id] then self.task_info[id].forced_status = "fail"; self.task_info[id].cancelled_by_actor = true end
	end
	function CRandomTask:update()
		M.updates = (M.updates or 0) + 1
		for id, t in pairs(self.task_info) do
			local f = t.status_functor and env.task_status_functor[t.status_functor]
			if f then f(t, id) end
		end
	end
	function CRandomTask:task_complete(id)
		local t = self.task_info[id]
		if t == nil then return true end
		if t.forced_status == "complete" then t.forced_status = nil return true end
		return false
	end
	function CRandomTask:task_fail(id)
		local t = self.task_info[id]
		if t and t.forced_status == "fail" then t.forced_status = nil return true end
		return false
	end
	local tm_instance = setmetatable({ task_info = {} }, CRandomTask)
	env.task_manager = {
		CRandomTask = CRandomTask,
		task_ini = { section_exist = function(_, id) return ini[id] == true end },
		get_task_manager = function() return tm_instance end,
	}
	env.task_manager.task_complete = function(id) return tm_instance:task_complete(id) end
	env.task_manager.task_fail = function(id) return tm_instance:task_fail(id) end
	env.task_manager.task_callback = function(tsk, state)
		local id = tsk:get_id()
		local rt = tm_instance.task_info[id]
		if not rt then return end
		if state == env.task.completed then
			local f = M.on_complete[id]
			if f then f() end
			tm_instance.task_info[id] = nil
		elseif state == env.task.fail then
			env.xr_effects.inc_faction_goodwill_to_actor(actor, nil, { "stalker", -25 })
			tm_instance.task_info[id] = nil
		end
	end
	M.tm = tm_instance

	-- engine task check (host): what CGameTaskManager::UpdateTasks does with the Lua functors
	function M.engine_check()
		for id, t in pairs(M.engine_tasks) do
			if t.state == "in" then
				if env.task_manager.task_complete(id) then
					t.state = "done"
					env.task_manager.task_callback(t, env.task.completed)
				elseif env.task_manager.task_fail(id) then
					t.state = "fail"
					env.task_manager.task_callback(t, env.task.fail)
				end
			end
		end
	end
	function M.run_timers()
		local list = M.timers
		M.timers = {}
		for _, t in ipairs(list) do t.f(unpack(t.p)) end
	end

	-- load the script like CScriptStorage (module table, __index = globals)
	local fh = assert(io.open(SCRIPT, "r"))
	local src = fh:read("*a")
	fh:close()
	local f = assert(loadstring(src, "@coop_tasks.script"))
	local mod = setmetatable({}, { __index = env })
	env.coop_tasks = mod
	setfenv(f, mod)
	f()
	M.mod = mod
	MACHINES[#MACHINES + 1] = M
	return M
end

local function pump()
	local guard = 0
	while #QUEUE > 0 and guard < 1000 do
		guard = guard + 1
		local e = table.remove(QUEUE, 1)
		local h = e.to.handlers[e.name]
		if h then h(e.payload, e.from, e.name) end
	end
end

local function tick(m)
	NOW = NOW + 600
	if m.callbacks.actor_on_update then m.callbacks.actor_on_update() end
end

-- Calls of one coop.money_* function on a machine: { { peer, n }, ... }
local function money_calls(m, fn)
	local out = {}
	for _, c in ipairs(m.money_calls) do
		if c.fn == fn and c.ok then out[#out + 1] = { c.peer, c.n } end
	end
	return out
end

-- coop_trw events that still carry money (k=money): none since F2 T6
local function money_events(m)
	local n = 0
	for _, e in ipairs(m.sent) do
		if e.name == "coop_trw" and e.payload:find("k=smoney", 1, true) then n = n + 1 end
	end
	return n
end

local function count_sent(m, name)
	local n = 0
	for _, s in ipairs(m.sent) do if s.name == name then n = n + 1 end end
	return n
end

-- ---------------------------------------------------------------- setup
print("== setup")
local H = machine("host", 0)
local C = machine("client", 1)
-- host world: client's character = proxy 500; client world: host's character = avatar 500
local proxy_on_host = H.new_obj(500)
local host_on_client = C.new_obj(500)
H.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
C.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
-- a task object the client got with the join save that the host no longer has
C.tm.task_info.old_task = { id = "old_task", stage = 0, status = "selected" }

H.mod.on_game_start()
C.mod.on_game_start()
check(H.handlers.coop_tq and C.handlers.coop_tl and C.handlers.coop_trw, "event handlers registered")
check(H.env.coop.party_has ~= nil, "coop.party_has exported")
check(H.env.task_manager.CRandomTask.give_task ~= nil, "class patched")

-- ---------------------------------------------------------------- codec
print("== payload codec")
do
	-- reach the module's local codec through a round trip of task vars
	local id = "fetch_1"
	C.env.db.storage[0].pstor["fetch_1_weird"] = "a;b=c,d:e%f"
	C.env.db.storage[0].pstor["fetch_1_tbl"] = { [1] = "x", [2] = 3, k = true, kk = "q;:," }
end

-- ---------------------------------------------------------------- client takes a task
print("== client takes a task (R-7.8, item 4)")
C.env.db.storage[0].pstor["fetch_1_fetch"] = "medkit"
C.env.db.storage[0].pstor["fetch_1_fetch_count"] = 2
C.env.db.storage[0].pstor["other_var"] = "not sent"
C.tm:give_task("fetch_1", 77)
check(C.on_init.fetch_1 == nil, "client did not run the task locally (no on_init)")
local stub = C.tm.task_info.fetch_1
check(stub ~= nil and stub.status == "selected" and stub.stage == 0, "provisional stub on the client")
check(count_sent(C, "coop_tq") == 1, "give request sent to the host")
pump()
check(H.on_init.fetch_1 == 1, "host ran the give once")
check(H.env.db.storage[0].pstor["fetch_1_fetch"] == "medkit" and H.env.db.storage[0].pstor["fetch_1_fetch_count"] == 2,
	"dialog vars reached the host's pstor")
check(H.env.db.storage[0].pstor["fetch_1_weird"] == "a;b=c,d:e%f", "escaped string survives")
local tbl = H.env.db.storage[0].pstor["fetch_1_tbl"]
check(type(tbl) == "table" and tbl[1] == "x" and tbl[2] == 3 and tbl.k == true and tbl.kk == "q;:,", "flat table var survives (number keys too)")
check(H.env.db.storage[0].pstor["other_var"] == nil, "unrelated vars are not sent")
check(H.tm.task_info.fetch_1.task_giver_id == 77, "giver id kept")
check(H.mod.recipient("fetch_1") == 1, "taker recorded")
pump()
stub = C.tm.task_info.fetch_1
check(stub.coop_stub and stub.pending_at == nil and stub.task_giver_id == 77, "client stub confirmed by the host state")
C.engine_tasks.fetch_1 = { state = "in" } -- what coop_story (WP4) mirrors on the engine side

-- ---------------------------------------------------------------- client never evaluates
print("== client does not evaluate tasks")
C.tm:update()
check((C.updates or 0) == 0, "client task_manager:update skipped")
check(C.env.task_manager.task_complete("fetch_1") == false and C.env.task_manager.task_complete("nope") == false,
	"client task_complete is always false (unknown tasks too)")

-- ---------------------------------------------------------------- party items (R-7.5)
print("== quest items in another player's inventory (R-7.5)")
H.give_item(proxy_on_host, "medkit")
H.give_item(proxy_on_host, "medkit")
check(H.mod.party_count("medkit") == 2 and H.mod.party_has("medkit", 2), "party_count sees the proxy inventory")
H.tm:update()
check(H.tm.task_info.fetch_1.stage == 1, "fetch status functor completes from the group inventory")
tick(H)
pump()
check(C.tm.task_info.fetch_1.stage == 1, "client sees the stage (turn-in becomes available)")
check(C.env.db.storage[0].pstor["fetch_1_fetch"] == "medkit", "task vars mirrored to the client")

-- ---------------------------------------------------------------- client turns in (R-7.6)
print("== client turns the task in (R-7.6)")
H.on_complete.fetch_1 = function()
	H.env.xr_effects.fetch_reward_and_remove(H.actor, nil, { "fetch_1_fetch" })
	H.env.alife_create_item("af_reward", H.actor)
	H.env.news_manager.relocate_item(H.actor, "in", "af_reward", 1)
	H.env.xr_effects.inc_faction_goodwill_to_actor(H.actor, nil, { "stalker", 50, true })
end
H.money_before = H.actor._money
C.tm:set_task_completed("fetch_1")
check(C.tm.task_info.fetch_1.status == "completed", "optimistic status on the client")
pump()
check(H.tm.task_info.fetch_1.forced_status == "complete", "host marked it complete")
H.engine_check()
check(H.transfers == 2, "the finisher's items were moved to the host actor for the stock reward")
H.run_timers()
check(H.fetch_failed == nil and H.count(H.actor, "medkit") == 0, "stock fetch reward found and took the items")
check(H.actor._money == H.money_before, "host got no money")
check(proxy_on_host:object("af_reward") ~= nil and H.actor:object("af_reward") == nil, "reward item spawned into the finisher's character")
check((H.goodwill[500] or 0) == 50 and (H.goodwill[0] or 0) == 0, "goodwill keyed to the finisher's character")
pump()
local g1 = money_calls(H, "money_grant")
check(#g1 == 1 and g1[1][1] == 1 and g1[1][2] == 1000, "the host granted the stock fetch money to the finisher: coop.money_grant(1, 1000)")
check(C.actor._money == 0 and #C.money_calls == 0, "the client did not touch its money or the ledger")
check(money_events(H) == 0, "no coop_trw event carries money")
check(C.money_news[1] == "in:1000", "the finisher still sees the money news")
check(C.gw_msg == "stalker", "client shows the goodwill message")
local got_in, got_out = false, false
for _, n in ipairs(C.news) do
	if n == "in:af_rewardx1" then got_in = true end
	if n == "out:medkitx2" then got_out = true end
end
check(got_in and got_out, "item news shown on the finisher's machine")
check(C.task_news == "complete;", "client shows the task completion news")
tick(H)
pump()
check(C.tm.task_info.fetch_1 == nil, "finished task removed from the client's task_manager")
check(C.env.db.storage[0].pstor["fetch_1_fetch"] == nil, "its mirrored vars removed")

-- ---------------------------------------------------------------- list reconcile
print("== digest list")
NOW = NOW + 20000
tick(H)
pump()
check(C.tm.task_info.old_task == nil, "stale join-time task dropped by the host's list")

-- ---------------------------------------------------------------- reward_money_is_a_host_grant
print("== reward_money_is_a_host_grant")
do
	C.tm:give_task("story_1", 9)
	pump()
	H.on_complete.story_1 = function() H.env.dialogs.relocate_money(H.actor, 1200, "in") end
	local hm0, cm0 = H.actor._money, C.actor._money
	local g0, ev0, news0 = #H.money_calls, money_events(H), #C.money_news
	C.tm:set_task_completed("story_1")
	pump()
	H.engine_check()
	pump()
	local g = money_calls(H, "money_grant")
	check(#H.money_calls == g0 + 1 and g[#g][1] == 1 and g[#g][2] == 1200, "1200 for the one who turned it in: coop.money_grant(1, 1200)")
	check(money_events(H) == ev0, "no coop_trw event with k=money")
	check(H.actor._money == hm0 and C.actor._money == cm0 and #C.money_calls == 0, "neither actor's money was changed by Lua")
	check(#C.money_news == news0 + 1 and C.money_news[#C.money_news] == "in:1200", "the news line still comes from the finisher's machine")
	-- a grant the host ledger refuses is not announced
	H.env.coop.money_grant = function(peer, n) H.money_calls[#H.money_calls + 1] = { fn = "money_grant", peer = peer, n = n, ok = false, why = "no character" } return false, "no character" end
	C.tm:give_task("story_1", 9)
	pump()
	news0 = #C.money_news
	C.tm:set_task_completed("story_1")
	pump()
	H.engine_check()
	pump()
	check(#C.money_news == news0, "refused grant: no news line")
	install_money_stubs(H.env.coop, { calls = H.money_calls, is_host = function() return true end })
end

-- ---------------------------------------------------------------- share setting
print("== coop_share_rewards 1")
H.share = 1
H.tm:give_task("fetch_2", 5)
H.env.db.storage[0].pstor["fetch_2_fetch"] = "bread"
H.give_item(H.actor, "bread")
tick(H)
pump()
H.on_complete.fetch_2 = function()
	H.env.dialogs.relocate_money(H.actor, 1001, "in")
	H.env.alife_create_item("knife", H.actor)
end
local hm, cm = H.actor._money, C.actor._money
local g_before = #money_calls(H, "money_grant")
C.tm:set_task_completed("fetch_2")
pump()
H.engine_check()
pump()
local gs = money_calls(H, "money_grant")
check(H.actor._money - hm == 500 and #gs == g_before + 1 and gs[#gs][1] == 1 and gs[#gs][2] == 501 and C.actor._money == cm,
	"money split: the host keeps 500, coop.money_grant(1, 501) for the finisher (remainder)")
check(proxy_on_host:object("knife") ~= nil, "item still to the finisher")
H.share = 0

-- ---------------------------------------------------------------- host turns in a client's task
print("== host turns in a task the client took")
C.tm:give_task("story_1", 9)
pump()
check(H.mod.recipient("story_1") == 1, "client is the taker")
H.on_complete.story_1 = function()
	H.env.dialogs.relocate_money(H.actor, 300, "in")
	H.tm:give_task("fetch_2", 1) -- a follow-up task given by the reward
end
hm, cm = H.actor._money, C.actor._money
H.talking = true
H.tm:set_task_completed("story_1")
H.talking = false
H.engine_check()
pump()
check(H.actor._money - hm == 300 and C.actor._money == cm, "reward to the host who turned it in (dialog)")
check(H.mod.recipient("fetch_2") == 0, "follow-up task of the host's reward belongs to the host")

print("== a host script completes a client's task on its own")
C.tm:give_task("story_1", 9)
pump()
H.on_complete.story_1 = function()
	H.env.dialogs.relocate_money(H.actor, 200, "in")
	H.tm:give_task("stage_t", 1)
end
hm, cm = H.actor._money, C.actor._money
local g200_before = #money_calls(H, "money_grant")
H.tm:set_task_completed("story_1") -- not talking: a scheme / info reaction
H.engine_check()
pump()
local g200 = money_calls(H, "money_grant")
check(H.actor._money == hm and C.actor._money == cm and #g200 == g200_before + 1 and g200[#g200][1] == 1
	and g200[#g200][2] == 200, "reward to the player who took it: exactly one coop.money_grant(1, 200)")
check(H.mod.recipient("stage_t") == 1, "follow-up task belongs to that player")
H.tm.task_info.stage_t = nil
H.engine_tasks.stage_t = nil
tick(H)
pump()

-- ---------------------------------------------------------------- engine-path finisher note + payment + faction
print("== engine request path, money task payment, faction change")
C.tm:give_task("cf_1", 4)
pump()
H.env.db.storage[0].pstor["cf_1_fetch"] = 700
H.on_complete.cf_1 = function()
	H.env.xr_effects.drx_sl_money_task_payment(H.actor, nil, { "cf_1_fetch" })
	H.env.xr_effects.drx_sl_change_factions(H.actor, nil, { "army" })
end
H.mod.host_note("cf_1", "finisher", 1) -- what coop_story.cpp does for TaskReqState
H.tm:set_task_completed("cf_1")
check(H.mod.recipient("cf_1") == 1, "engine note keeps the client as finisher")
hm, cm = H.actor._money, C.actor._money
local gp_before = #money_calls(H, "money_grant")
H.engine_check()
pump()
local gp = money_calls(H, "money_grant")
check(H.actor._money == hm and C.actor._money == cm and #gp == gp_before + 1 and gp[#gp][1] == 1 and gp[#gp][2] == -700
	and money_events(H) == 0, "payment taken from the finisher on the host ledger: exactly one coop.money_grant(1, -700)")
check(C.money_news[#C.money_news] == "out:700", "the payment news line is shown to the payer")
check(C.faction == "army" and H.faction == nil, "faction change runs on the finisher's machine")

-- ---------------------------------------------------------------- stock payouts through db.actor:give_money
print("== stock task payouts (multifetch_remove, barrier defense) go to the one who turned the task in")
do
	local function one_grant(since, peer, n, what)
		local g = money_calls(H, "money_grant")
		check(#g == since + 1 and g[#g][1] == peer and g[#g][2] == n, what)
	end
	-- a client turns in a task whose on_complete is multifetch_remove: the 900 are the client's, not the host actor's
	C.tm:give_task("story_1", 9)
	pump()
	H.on_complete.story_1 = function() H.env.xr_effects.multifetch_remove(H.actor, nil, { "story_1", "true" }) end
	local hm1, cm1 = H.actor._money, C.actor._money
	local gb, hn, cn = #money_calls(H, "money_grant"), #H.money_news, #C.money_news
	C.tm:set_task_completed("story_1")
	pump()
	H.engine_check()
	pump()
	one_grant(gb, 1, 900, "multifetch_remove for a client's turn-in: exactly one coop.money_grant(1, 900)")
	check(H.actor._money == hm1 and C.actor._money == cm1, "the host's actor got no money, the client's Lua added none")
	check(#H.money_news == hn, "no 'money received' line on the host")
	check(#C.money_news == cn + 1 and C.money_news[#C.money_news] == "in:900", "the finisher sees the line instead")
	-- the host turns in its own task: the money is the host's
	H.tm:give_task("story_1", 1)
	H.on_complete.story_1 = function() H.env.xr_effects.multifetch_remove(H.actor, nil, { "story_1", "true" }) end
	hm1, gb, hn = H.actor._money, #money_calls(H, "money_grant"), #H.money_news
	H.tm:set_task_completed("story_1")
	H.engine_check()
	pump()
	check(H.actor._money == hm1 + 900 and #money_calls(H, "money_grant") == gb and #H.money_news == hn + 1,
		"the host's own turn-in: the host gets the money and the line, no grant")
	-- coop_share_rewards 1: split like every other task money (the host keeps 450)
	H.share = 1
	C.tm:give_task("story_1", 9)
	pump()
	H.on_complete.story_1 = function() H.env.xr_effects.multifetch_remove(H.actor, nil, { "story_1", "true" }) end
	hm1, gb = H.actor._money, #money_calls(H, "money_grant")
	C.tm:set_task_completed("story_1")
	pump()
	H.engine_check()
	pump()
	one_grant(gb, 1, 450, "shared payout: coop.money_grant(1, 450)")
	check(H.actor._money == hm1 + 450, "shared payout: the host keeps 450")
	H.share = 0
	-- barrier defense (a dialog action, run here in the reward scope of a client): 40 000 and 25 000
	hm1, gb = H.actor._money, #money_calls(H, "money_grant")
	H.mod.with_recipient(1, H.env.tasks_defense.barrier_defense_monolith_complete, H.actor, nil)
	one_grant(gb, 1, 40000, "barrier_defense_monolith_complete for a client: coop.money_grant(1, 40000)")
	gb = #money_calls(H, "money_grant")
	H.mod.with_recipient(1, H.env.tasks_defense.barrier_defense_zombie_complete, H.actor, nil)
	one_grant(gb, 1, 25000, "barrier_defense_zombie_complete for a client: coop.money_grant(1, 25000)")
	check(H.actor._money == hm1, "the host's actor got nothing from either")
	-- outside a reward scope (the host talks to the NPC itself) it is the host's money, as before
	gb, hn = #money_calls(H, "money_grant"), #H.money_news
	H.env.tasks_defense.barrier_defense_monolith_complete(H.actor, nil)
	check(H.actor._money == hm1 + 40000 and #money_calls(H, "money_grant") == gb and #H.money_news == hn + 1,
		"the host's own dialog action pays the host")
	-- on a client the dialog action runs on its machine: untouched (the engine ledger takes the change)
	local cm2, cg = C.actor._money, #C.money_calls
	C.env.tasks_defense.barrier_defense_zombie_complete(C.actor, nil)
	check(C.actor._money == cm2 + 25000 and #C.money_calls == cg, "a client's own dialog action is not redirected")
end

-- ---------------------------------------------------------------- stage writes, cancel, bad requests
print("== stage write, cancel, refused requests")
C.tm:give_task("stage_t", 3)
pump()
tick(H)
pump()
C.tm.task_info.stage_t.stage = 2
pump()
check(H.tm.task_info.stage_t.stage == 2, "dialog stage write reached the host")
C.tm:set_task_cancelled("stage_t")
pump()
check(H.tm.task_info.stage_t.cancelled_by_actor == true, "cancel reached the host")
H.engine_check()
check((H.goodwill[500] or 0) == 50 - 25, "cancel penalty keyed to the canceller")
local refused_before = #C.sent
C.env.coop.send_event("coop_tq", "op=sgive;i=sbogus_task", 0)
pump()
local found = false
for _, l in ipairs(H.log) do if l:find("bad task request", 1, true) then found = true end end
check(found, "unknown task id refused")
C.tm:set_task_completed("fetch_1") -- not running any more
pump()
check(C.tm.task_info.fetch_1 == nil, "refused turn-in: the requester gets the host's view back")

-- ---------------------------------------------------------------- bounty target chosen in the client's dialog
print("== bounty target travels with the task")
C.env.axr_task_manager.bounties_by_id.bounty_1 = 4242 -- setup_bounty_task ran in the client's dialog
C.tm:give_task("bounty_1", 6)
pump()
check(H.env.axr_task_manager.bounties_by_id.bounty_1 == 4242, "host knows the bounty target")
H.env.axr_task_manager.bounties_by_id.bounty_1 = 4343
tick(H)
pump()
check(C.env.axr_task_manager.bounties_by_id.bounty_1 == 4343, "client mirrors the host's bounty target")

-- ---------------------------------------------------------------- shared DRX bookkeeping vars
print("== shared task bookkeeping vars (drx_sl_*)")
C.env.save_var(C.actor, "drx_sl_task_giver_77", 1) -- what the giving dialog does on the client
C.env.save_var(C.actor, "unrelated_var", 5)
pump()
check(H.env.db.storage[0].pstor["drx_sl_task_giver_77"] == 1, "client's giver counter reached the host")
check(H.env.db.storage[0].pstor["unrelated_var"] == nil, "other vars stay local")
H.env.db.storage[0].pstor["drx_sl_task_giver_77"] = 2 -- the host's own dialog counted too
C.env.save_var(C.actor, "drx_sl_task_giver_77", 2) -- client counts again from its (old) view: +1
pump()
check(H.env.db.storage[0].pstor["drx_sl_task_giver_77"] == 3, "counters merge as deltas")
tick(H)
pump()
check(C.env.db.storage[0].pstor["drx_sl_task_giver_77"] == 3, "client mirrors the group's value")
H.env.db.storage[0].pstor["drx_sl_task_giver_77"] = nil -- on_complete unregistered it on the host
H.env.db.storage[0].pstor["drx_sl_current_task"] = "story_x"
tick(H)
pump()
check(C.env.db.storage[0].pstor["drx_sl_task_giver_77"] == nil and C.env.db.storage[0].pstor["drx_sl_current_task"] == "story_x",
	"removals and new keys mirrored")

-- ---------------------------------------------------------------- remove_item from the group
print("== quest item removal from the group")
H.give_item(proxy_on_host, "q_item")
H.env.xr_effects.remove_item(H.actor, nil, { "q_item", 1 })
check(proxy_on_host:object("q_item") == nil, "host took the quest item from the client's character")

-- ---------------------------------------------------------------- single player untouched
print("== no session")
H.env.coop.is_active = function() return false end
local before = H.on_init.fetch_1
H.tm:give_task("fetch_1", 1)
check(H.on_init.fetch_1 == before + 1, "single player: give runs normally")
H.env.coop.is_active = function() return true end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
