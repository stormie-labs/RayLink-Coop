-- Anomaly Coop W3c temp test: coop_tasks.script on a simulated host + client (two Lua environments).
-- Not shipped. Run: tools\test_lua.cmd tasks
local modes = dofile("tests/lua/support/modes.lua")
dofile("tests/lua/support/stubs.d/money.lua") -- install_money_stubs: coop.money_* of the host ledger (F2 T1)
dofile("tests/lua/support/luabind_like.lua")

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
	-- the engine loads a script on the first use of its name: coop_util and the parts of coop_tasks come that way, into this machine
	local env = setmetatable({}, { __index = function(_, k)
		if type(k) == "string" and (k == "coop_util" or k:find("^coop_tasks_")) then return M.load(k) end
		return _G[k]
	end })
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
		inc_goodwill_by_tasker_comm = function(a, npc, p) -- the stock: the task's var, else the NPC the actor talks to
			local var = env.load_var(actor, p[1])
			local comm = type(var) == "table" and var.task_giver_comm
			if not comm and actor:is_talking() then comm = "of_the_talk" end
			M.tasker_comm = M.tasker_comm or {}
			M.tasker_comm[#M.tasker_comm + 1] = comm or "none"
		end,
		give_actor = function(a, npc, p) -- the stock: alife_create(section, ..., AC_ID), not alife_create_item
			for _, v in pairs(p) do
				M.give_item(actor, v)
				env.news_manager.relocate_item(actor, "in", v)
			end
		end,
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
	local ini = { fetch_1 = true, fetch_2 = true, story_1 = true, cf_1 = true, stage_t = true, bounty_1 = true, dawn_1 = true,
		ghost_1 = true, cord_1 = true, owl_1 = true, comm_1 = true, rest_1 = true }
	M.on_init = {}
	M.on_complete = {}
	local CRandomTask = {}
	CRandomTask.__index = CRandomTask
	function CRandomTask:give_task(id, giver)
		M.on_init[id] = (M.on_init[id] or 0) + 1
		-- the stock (CRandomTask:give_task): the task object is in task_info BEFORE its give_task runs on_init and gives the task to
		-- the actor; the giver is written after. An on_init that dies leaves the object behind.
		self.task_info[id] = { id = id, stage = 0, status = "selected", status_functor = "actor_has_fetch_item" }
		if M.init_fx and M.init_fx[id] then M.init_fx[id]() end
		self.task_info[id].task_giver_id = giver
		M.engine_tasks[id] = { state = "in", get_id = function() return id end,
			get_title = function() return "title_" .. id end, get_icon_name = function() return nil end }
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
	local tm_instance = setmetatable({ task_info = luabind_task_table() }, CRandomTask)
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
			env.news_manager.send_task(actor, "fail", tsk) -- the stock task_manager.task_callback sends the fail line itself
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
					env.news_manager.send_task(actor, "complete", t) -- bind_stalker_ext.actor_on_task_callback sends the line first
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

	-- Load scripts as the engine does (module table with the machine's globals).
	local function load(name)
		local f = assert(loadfile("gamedata/scripts/" .. name .. ".script"))
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		setfenv(f, mod)()
		return mod
	end
	modes.live(load("coop_mode"), load)
	M.load = load
	M.mod = load("coop_tasks")
	MACHINES[#MACHINES + 1] = M
	return M
end

local function server_dialogue(M, levels)
	M.env.coop.is_dedicated = levels and function() return true end or nil
	M.env.coop.levels = levels
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
check(H.env.coop_tasks_items.party_count("medkit") == 2 and H.env.coop_tasks_items.party_has("medkit", 2), "party_count sees the proxy inventory")
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
check((H.goodwill[500] or 0) == 50 and (H.goodwill[0] or 0) == 50,
	"goodwill reaches the finisher's character and, by the default rep_share everyone, the host's")
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

-- ---------------------------------------------------------------- the seat of a world server plays no character
print("== coop_share_rewards 1: the ghost actor of a seat that plays no character gets no share")
-- The quest audit, 2026-11-13: online_peers() began with peer 0 whatever the seat is; on a world server the ghost got a share.
do
	H.share = 1
	H.env.coop.is_dedicated = function() return true end
	C.tm:give_task("ghost_1", 5)
	pump()
	H.on_complete.ghost_1 = function() H.env.dialogs.relocate_money(H.actor, 1001, "in") end
	local hm0, n0 = H.actor._money, #money_calls(H, "money_grant")
	C.tm:set_task_completed("ghost_1")
	pump()
	H.engine_check()
	pump()
	local g = money_calls(H, "money_grant")
	check(H.actor._money == hm0, "nothing lands on the ghost")
	check(#g == n0 + 1 and g[#g][1] == 1 and g[#g][2] == 1001, "the players share the whole sum: coop.money_grant(1, 1001)")
	H.env.coop.is_dedicated = nil
	H.share = 0
end

-- ---------------------------------------------------------------- the remainder of a split
print("== coop_share_rewards 1: the remainder when the player the reward is for is not among the sharers")
-- n RU over k sharers leaves n % k. It goes to the player the reward is for when he shares, else to the first sharer: the
-- parts always add up to the reward.
do
	H.new_obj(620)
	H.new_obj(630)
	local players0, talking0 = H.players, H.talking
	H.players = { players0[1], players0[2], { id = 2, is_self = false, avatar_id = 620 },
		{ id = 3, is_self = false, avatar_id = 630 } }
	H.talking = false
	H.share = 1
	H.on_complete.rest_1 = function() H.env.dialogs.relocate_money(H.actor, 1001, "in") end
	-- The task is given by peer `taker` (nil: by a script nobody is located for, so its taker is the seat 0) and ended by a
	-- script, so the reward is for its taker. Peer 3 is on his loading screen when it ends. Returns the reward's recipient and
	-- the RU each peer got (0: the host's actor).
	local function payout(taker)
		H.players[4].avatar_id = 630
		if taker then H.mod.run_as(taker, function() H.tm:give_task("rest_1", 5) end) else H.tm:give_task("rest_1", 5) end
		pump()
		H.players[4].avatar_id = nil
		local rcpt = H.mod.recipient("rest_1")
		local hm0, n0 = H.actor._money, #money_calls(H, "money_grant")
		H.tm:set_task_completed("rest_1")
		H.engine_check()
		pump()
		local got, g = { [0] = H.actor._money - hm0 }, money_calls(H, "money_grant")
		for i = n0 + 1, #g do got[g[i][1]] = (got[g[i][1]] or 0) + g[i][2] end
		return rcpt, got
	end
	local function sum(got)
		local s = 0
		for _, n in pairs(got) do s = s + n end
		return s
	end

	-- Server: the world server's seat 0 plays no character, so it is never a sharer
	H.env.coop.is_dedicated = function() return true end
	local rcpt, got = payout(nil)
	check(rcpt == 0, "Server: the reward of a task nobody took is for the seat 0")
	check(sum(got) == 1001 and got[0] == 0, "Server, the seat 0: the parts add up to 1001 (" .. sum(got) .. "), the ghost gets none")
	check(got[1] == 501 and got[2] == 500 and got[3] == nil, "Server, the seat 0: the remainder goes to the first sharer, peer 1")
	rcpt, got = payout(3)
	check(rcpt == 3, "Server: the reward is for peer 3, who is off the level")
	check(sum(got) == 1001 and got[0] == 0 and got[3] == nil,
		"Server, peer 3 off the level: the parts add up to 1001 (" .. sum(got) .. "), he gets none")
	check(got[1] == 501 and got[2] == 500, "Server, peer 3 off the level: the remainder goes to the first sharer, peer 1")

	-- Coop: the host plays seat 0 and is the first sharer, so the remainder is his as before
	H.env.coop.is_dedicated = nil
	rcpt, got = payout(3)
	check(rcpt == 3, "Coop: the reward is for peer 3, who is off the level")
	check(sum(got) == 1001 and got[0] == 335 and got[1] == 333 and got[2] == 333 and got[3] == nil,
		"Coop, peer 3 off the level: 333 each and the remainder 2 to the host, the first sharer")

	H.on_complete.rest_1 = nil
	H.players, H.talking = players0, talking0
	H.share = 0
end

-- ---------------------------------------------------------------- goodwill by the faction of the giver
print("== inc_goodwill_by_tasker_comm at a turn-in nobody of the host talks at")
-- The quest audit, 2026-11-13: the stock takes the giver's faction from the task's var (only delivery tasks write it) or from the NPC
-- the actor talks to. A task a client turns in ends in the host's task callback, where nobody talks: 15 tasks gave no goodwill.
do
	H.env.alife_object = function(id)
		if id == 77 then return { id = 77, community = function() return "dolg" end } end
		return nil
	end
	H.on_complete.comm_1 = function() H.env.xr_effects.inc_goodwill_by_tasker_comm(H.actor, nil, { "comm_1", 50 }) end
	C.tm:give_task("comm_1", 77)
	pump()
	H.tasker_comm = {}
	C.tm:set_task_completed("comm_1")
	pump()
	H.engine_check()
	pump()
	check(#H.tasker_comm == 1 and H.tasker_comm[1] == "dolg", "the faction of the task's giver, from his record")
	check(H.env.load_var(H.actor, "comm_1") == nil, "the task's var is left as it was")
	-- a var the task keeps, with its own word: the stock's
	H.env.save_var(H.actor, "comm_1", { task_giver_comm = "freedom", n = 1 })
	H.tasker_comm = {}
	H.env.xr_effects.inc_goodwill_by_tasker_comm(H.actor, nil, { "comm_1", 50 })
	check(H.tasker_comm[1] == "freedom", "a faction the task wrote itself wins")
	H.env.save_var(H.actor, "comm_1", nil)
	-- the host's own talk: the stock
	H.tm.task_info.comm_1 = { id = "comm_1", stage = 0, status = "selected", task_giver_id = 77 }
	H.talking = true
	H.tasker_comm = {}
	H.env.xr_effects.inc_goodwill_by_tasker_comm(H.actor, nil, { "comm_1", 50 })
	H.talking = false
	check(H.tasker_comm[1] == "of_the_talk", "the host's player who talks: the NPC of his talk, as in the stock")
	H.tm.task_info.comm_1 = nil
	H.env.alife_object = nil
end

-- ---------------------------------------------------------------- give_actor of a task's start
print("== give_actor in a task's on_init: the item is the taker's")
-- The quest audit, 2026-11-13: xr_effects.give_actor makes the task's PDA with alife_create(..., AC_ID), past the redirect of
-- alife_create_item: it lay in the host's own inventory (a world server's ghost) while the taker read "item received".
do
	H.init_fx = { owl_1 = function() H.env.xr_effects.give_actor(H.actor, nil, { "owl_pda" }) end }
	local news0 = #H.news
	C.tm:give_task("owl_1", 5)
	pump()
	check(H.tm.task_info.owl_1 ~= nil, "given")
	check(H.actor:object("owl_pda") == nil, "not into the host's own inventory")
	check(proxy_on_host:object("owl_pda") ~= nil, "into the character of the player who took the task")
	check(#H.news == news0, "and the line about it is his, not the host's")
	-- the host's own talk: the stock
	H.tm.task_info.owl_1 = nil
	H.engine_tasks.owl_1 = nil
	tick(H)
	pump()
	H.talking = true
	H.tm:give_task("owl_1", 5)
	H.talking = false
	check(H.actor:object("owl_pda") ~= nil, "a task the host's player takes: his item, as in the stock")
	H.init_fx = nil
	H.tm.task_info.owl_1 = nil
	H.engine_tasks.owl_1 = nil
	tick(H)
	pump()
end

-- ---------------------------------------------------------------- the speaker of a give
print("== a task given from a talk: its on_init has the NPC the player talks to")
-- The quest audit, 2026-11-13: lttz_ll_medical_supplies (on_init = setup_fetch_task) asks get_speaker() for the NPC; on the host nobody
-- talked, ranks.get_obj_rank_name(nil) died and the task could never be turned in.
do
	local cord_c, cord_h = C.new_obj(88), H.new_obj(88)
	C.env.get_speaker = function() return cord_c end
	local stock_speaker = function() return nil end -- the host: nobody talks to its actor
	H.env.get_speaker = stock_speaker
	local talked = { [88] = true }
	H.env.coop.talk_recent = function(from, id) return from == 1 and talked[id] == true end
	local seen
	H.init_fx = { cord_1 = function() seen = H.env.get_speaker(true) end }
	C.talking = true
	C.tm:give_task("cord_1") -- a story dialog: no giver in the call
	C.talking = false
	pump()
	check(H.tm.task_info.cord_1 ~= nil, "given")
	check(seen == cord_h, "get_speaker() of the task's on_init is the NPC of the player's talk")
	check(H.env.get_speaker == stock_speaker, "and the stock one is back after the give")
	-- a speaker the player did not talk to is nobody's word
	H.tm.task_info.cord_1 = nil
	H.engine_tasks.cord_1 = nil
	tick(H)
	pump()
	talked[88] = nil
	seen = "unset"
	NOW = NOW + 2000
	C.talking = true
	C.tm:give_task("cord_1")
	C.talking = false
	pump()
	check(seen == nil, "an NPC the host did not see him talk to is not taken for the speaker")
	H.init_fx = nil
	H.env.coop.talk_recent = nil
	H.tm.task_info.cord_1 = nil
	H.engine_tasks.cord_1 = nil
	tick(H)
	pump()
end

-- ---------------------------------------------------------------- a give the host could not do
print("== a give the host could not do: the player is told, the dialog that asked for it opens again")
-- "The Last Dawn" (cs_task0_ambush_renegade_story), 2026-11-13: the host's give died in the task's on_init. The requester's stub was
-- dropped in silence, and the info the dialog phrase gave (<give_info>: the engine gives it after the phrase's action, in the same
-- frame) had closed the dialog (dont_has_info) for good: the task could not be asked for again by anybody.
do
	local msgs = {}
	C.env.actor_menu = { set_msg = function(_, text) msgs[#msgs + 1] = text end }
	if rawget(C.env, "game") == nil then C.env.game = { translate_string = function(s) return s end } end
	local infos = { old_info = true }
	C.actor.give_info_portion = function(_, i) infos[i] = true end
	C.actor.disable_info_portion = function(_, i) infos[i] = nil end
	C.actor.has_info = function(_, i) return infos[i] == true end
	local function phrase(info) -- the engine: the info of a phrase, and what bind_stalker tells of it
		C.actor:give_info_portion(info)
		C.callbacks.actor_on_info_callback(C.actor, info)
	end
	check(type(C.callbacks.actor_on_info_callback) == "function", "the client listens to the infos its actor gets")
	H.init_fx = { dawn_1 = function() error("bad argument #1 to 'string_gmatch' (string expected, got nil)") end }
	C.talking = true
	C.tm:give_task("dawn_1", 77) -- the action of the phrase "I'm in"
	phrase("dawn_start") -- its <give_info>
	C.talking = false
	check(C.tm.task_info.dawn_1 ~= nil, "a provisional stub while the host is asked")
	pump()
	check(H.tm.task_info.dawn_1 == nil, "the host gave nothing: no half-made task is left in its journal")
	check(H.engine_tasks.dawn_1 == nil, "(and no task of the engine)")
	check(C.tm.task_info.dawn_1 == nil, "the stub is gone")
	check(#msgs == 1 and msgs[1] == "st_coop_news_task_not_given", "the player is told that the task was not given")
	check(infos.dawn_start == nil, "the info of the phrase is taken back: the dialog offers the task again")
	check(infos.old_info == true, "an info of another moment stays")

	-- the second try, the host is well: nothing is told, nothing is taken back
	H.init_fx = nil
	NOW = NOW + 2000
	C.talking = true
	C.tm:give_task("dawn_1", 77)
	phrase("dawn_start")
	C.talking = false
	pump()
	pump()
	check(H.tm.task_info.dawn_1 ~= nil and C.tm.task_info.dawn_1 ~= nil, "given at the second try")
	check(#msgs == 1 and infos.dawn_start == true, "a give that went well keeps the phrase's info and says nothing")

	-- a task that is simply gone on the host (its removal, not a refused give) says nothing
	H.tm.task_info.dawn_1 = nil
	H.engine_tasks.dawn_1 = nil
	tick(H)
	pump()
	check(C.tm.task_info.dawn_1 == nil and #msgs == 1 and infos.dawn_start == true, "a removal is not a refusal")

	-- an info given outside a talk (a condlist: %=give_task(x) +info%) is not a phrase's: it stays, or the condlist would ask forever
	H.init_fx = { dawn_1 = function() error("no") end }
	NOW = NOW + 2000
	C.tm:give_task("dawn_1", 77)
	phrase("by_condlist")
	pump()
	check(C.tm.task_info.dawn_1 == nil and #msgs == 2, "refused again, told again")
	check(infos.by_condlist == true, "an info given outside a talk is not taken back")
	H.init_fx = nil
end

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

-- ---------------------------------------------------------------- TZ 6.4 #1: who may end a task, the engine's turn-in
print("== TZ 6.4 #1: fail / cancel only by the taker; the engine's turn-in through the host's checks (coop_trust)")
do
	local trust = setmetatable({}, { __index = H.env })
	local fh = assert(io.open("gamedata/scripts/coop_trust.script", "r"))
	local tsrc = fh:read("*a")
	fh:close()
	local tf = assert(loadstring(tsrc, "@coop_trust.script"))
	setfenv(tf, trust)
	tf()
	H.env.coop_trust = trust
	trust.reset_for_test({ default = "log" })
	local function lines(name)
		local n = 0
		for _, l in ipairs(H.log) do if l:find("[coop-trust] ! " .. name .. ":", 1, true) then n = n + 1 end end
		return n
	end
	local function last_line()
		for i = #H.log, 1, -1 do if H.log[i]:find("[coop-trust]", 1, true) then return H.log[i] end end
		return ""
	end
	-- a second client (peer 2, character 600) who did not take bounty_1 (client 1 took it, character 500)
	local C2 = machine("client", 2)
	H.new_obj(600)
	H.players[#H.players + 1] = { id = 2, is_self = false, avatar_id = 600, nick = "two" }
	H.players[2].nick = "one"
	C2.players = { { id = 2, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
	local function req(m, op, id) m.env.coop.send_event("coop_tq", "op=s" .. op .. ";i=s" .. id, 0); pump() end
	local bt = H.tm.task_info.bounty_1
	check(bt ~= nil and H.mod.taker("bounty_1") == 1, "bounty_1 runs, client 1 took it")

	-- log: the request of a player who did not take it goes through as today, the host's log says what it would refuse
	req(C2, "fail", "bounty_1")
	check(bt.forced_status == "fail", "log: a fail by another player still goes through")
	check(lines("task_fail") == 1 and last_line():find("two", 1, true) and last_line():find("bounty_1", 1, true)
		and last_line():find("one", 1, true), "log: one task_fail line naming the requester, the task and its taker")
	bt.forced_status = nil
	req(C2, "cancel", "bounty_1")
	check(bt.cancelled_by_actor == true and lines("task_cancel") == 1, "log: a cancel by another player goes through, task_cancel logged")
	bt.forced_status, bt.cancelled_by_actor = nil, nil

	-- refuse: nothing changes, the requester gets the host's view back
	trust.reset_for_test({ default = "log", task_fail = "refuse", task_cancel = "refuse" })
	local function to_two()
		local n = 0
		for _, e in ipairs(H.sent) do if e.name == "coop_tl" and e.target == 2 then n = n + 1 end end
		return n
	end
	local sent0 = to_two()
	req(C2, "fail", "bounty_1")
	req(C2, "cancel", "bounty_1")
	check(bt.forced_status == nil and bt.cancelled_by_actor == nil, "refuse: a fail / cancel by another player changes nothing")
	check(to_two() >= sent0 + 2, "refuse: the requester is sent the host's state of the task")
	-- the save keeps who took it
	local saved = {}
	H.mod.save_effects(saved)
	H.mod.load_effects(saved)
	req(C2, "fail", "bounty_1")
	check(bt.forced_status == nil, "after the host's save and load the taker is still known")
	-- a map server's logic (a timer, a target that died on its level) is no player: it is not asked who took it
	local n0 = lines("task_fail")
	H.handlers.coop_tq("op=sfail;i=sbounty_1", 0x100)
	check(bt.forced_status == "fail" and lines("task_fail") == n0, "a map server's fail goes through, no line")
	bt.forced_status = nil
	-- the taker himself
	req(C, "fail", "bounty_1")
	check(bt.forced_status == "fail" and lines("task_fail") == n0, "the taker's own fail goes through, no line")
	bt.forced_status = nil
	-- a task with no recorded taker (a save from before the record): nobody to compare with, ok
	local keep = {}
	H.mod.save_effects(keep) -- (load_effects takes its record out of m_data)
	local s2 = {}
	H.mod.save_effects(s2)
	s2.coop_task_fx.takers, s2.coop_task_fx.taker_char = {}, {}
	H.mod.load_effects(s2)
	req(C2, "fail", "bounty_1")
	check(bt.forced_status == "fail" and lines("task_fail") == n0, "no recorded taker: ok")
	bt.forced_status = nil
	H.mod.load_effects(keep)

	-- the engine's request (TaskReqState): coop_story.cpp asks coop_tasks.host_state_verdict before it finishes the task
	check(type(H.mod.host_state_verdict) == "function", "host_state_verdict exported for the engine")
	local V = H.mod.host_state_verdict or function() return nil end
	trust.reset_for_test({ default = "log", task_complete = "refuse", task_fail = "refuse" })
	H.env.db.storage[0].pstor["bounty_1_fetch"] = "vodka"
	H.env.db.storage[0].pstor["bounty_1_fetch_count"] = 1
	check(V("bounty_1", 2, 1, false, false) == false, "engine complete: the group holds no vodka, refused")
	check(lines("task_complete") == 1 and last_line():find("0 of 1", 1, true), "task_complete line says what is missing")
	local vodka = H.give_item(proxy_on_host, "vodka")
	bt.last_check_task = "complete" -- (round 2, F2: the host's own check of the task found it complete as well)
	check(V("bounty_1", 2, 1, false, false) == true and lines("task_complete") == 1, "engine complete with the vodka in the group: ok")
	H.env.alife_release_id(vodka._id)
	bt.status_functor = "drx_sl_money_task_status"
	H.env.db.storage[0].pstor["bounty_1_fetch"] = 5000
	local stock_money_of = H.env.coop.money_of
	H.env.coop.money_of = function(p) return p == 1 and 1200 or nil end
	check(V("bounty_1", 2, 1, false, false) == false and last_line():find("1200", 1, true), "engine complete of a money task he cannot pay: refused, balance logged")
	H.env.coop.money_of = function(p) return p == 1 and 9000 or nil end
	check(V("bounty_1", 2, 1, false, false) == true, "engine complete of a money task he can pay: ok")
	bt.last_check_task = nil
	H.env.coop.money_of = stock_money_of
	bt.status_functor = "actor_has_fetch_item"
	H.env.db.storage[0].pstor["bounty_1_fetch"] = nil
	H.env.db.storage[0].pstor["bounty_1_fetch_count"] = nil
	-- engine fail: by the taker, a map server, or a timer the host sees run out too
	check(V("bounty_1", 0, 2, false, false) == false and lines("task_fail") > n0, "engine fail by another player: refused")
	check(V("bounty_1", 0, 2, false, true) == true, "engine fail by another player whose timer ran out (the host sees it): ok")
	check(V("bounty_1", 0, 0x100, true, false) == true, "engine fail by a map server: ok")
	check(V("bounty_1", 0, 1, false, false) == true, "engine fail by the taker: ok")
	trust.reset_for_test({ default = "log" })
	check(V("bounty_1", 0, 2, false, false) == true, "log: the engine fail of another player is let through")
	check(V("nope", 2, 2, false, false) == true, "a task the Lua manager does not run: nothing to check, ok")
	check(bt.forced_status == nil, "the verdict itself changes no task")

	-- the engine's handler asks before it notes the finisher or changes the task, on both branches (explicit or not)
	local ef = io.open("engine/src/xrGame/coop/coop_story_tasks.cpp", "r")
	local esrc = ef and ef:read("*a") or ""
	if ef then ef:close() end
	local body = esrc:match("void host_on_task_state%(PeerId from, Reader& r%)(.-)\n}\n") or ""
	local ask = body:find("lua_task_state_ok(", 1, true)
	local fin = body:find("g_finisher[id] = from", 1, true)
	check(ask ~= nil and fin ~= nil and ask < fin,
		"coop_story_tasks.cpp host_on_task_state asks lua_task_state_ok before the finisher note")
	H.players[#H.players] = nil
	H.env.coop_trust = nil
	for i = #MACHINES, 1, -1 do if MACHINES[i] == C2 then table.remove(MACHINES, i) end end
end

-- ---------------------------------------------------------------- TZ 6.4 #1, round 2
print("== TZ 6.4 #1 round 2: the ends a player's own stock logic sends (F5), a talk (F5), the host's own reckoning (F2)")
do
	local trust = setmetatable({}, { __index = H.env })
	local fh = assert(io.open("gamedata/scripts/coop_trust.script", "r"))
	local tf = assert(loadstring(fh:read("*a"), "@coop_trust.script"))
	fh:close()
	setfenv(tf, trust)
	tf()
	H.env.coop_trust = trust
	trust.reset_for_test({ default = "log" })
	local function lines(name)
		local n = 0
		for _, l in ipairs(H.log) do if l:find("[coop-trust] ! " .. name .. ":", 1, true) then n = n + 1 end end
		return n
	end
	local function failed(name) return (trust.status()[name] or { failed = 0 }).failed end
	local function mentions(m, text)
		local n = 0
		for _, l in ipairs(m.log) do if l:find(text, 1, true) then n = n + 1 end end
		return n
	end
	local function status_line(m, text)
		local keep = #m.log
		m.mod.print_status()
		local found = nil
		for i = keep + 1, #m.log do if m.log[i]:find(text, 1, true) then found = m.log[i] end end
		return found
	end
	-- a second client (peer 2, character 600) who takes nothing
	local C2 = machine("client", 2)
	H.new_obj(600)
	H.players[#H.players + 1] = { id = 2, is_self = false, avatar_id = 600, nick = "two" }
	H.players[2].nick = "one"
	C2.players = { { id = 2, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
	C2.mod.on_game_start()
	for _, m in ipairs({ H, C, C2 }) do
		local ti = m.env.task_manager.task_ini
		local known = ti.section_exist
		ti.section_exist = function(s, id)
			return id == "drx_sl_x" or id == "faction_base_defense" or id == "cord_2" or id == "story_2" or known(s, id)
		end
	end
	local function req(m, op, id, extra)
		m.env.coop.send_event("coop_tq", "op=s" .. op .. ";i=s" .. id .. (extra or ""), 0)
		pump()
	end
	-- client 1 takes them: a DRX task, the surge's base defense, a task of NPC 777, a story task with no giver
	for _, g in ipairs({ { "drx_sl_x", 777 }, { "faction_base_defense", 778 }, { "cord_2", 777 }, { "story_2" } }) do
		C.tm:give_task(g[1], g[2])
		pump()
	end
	local drx, def, cord, story = H.tm.task_info.drx_sl_x, H.tm.task_info.faction_base_defense, H.tm.task_info.cord_2,
		H.tm.task_info.story_2
	check(drx and def and cord and story and H.mod.taker("drx_sl_x") == 1, "client 1 took the four tasks")

	-- F5 (a): a faction change cancels every DRX task on that machine (xr_effects.drx_sl_cancel_questlines: a fail and a cancel
	-- per task); (d) surge_manager's level change cancels faction_base_defense. From a player who did not take them: round 3
	-- (R2-B2), their own check "task_auto_end" through coop_trust. "log" (build 57): they go through exactly as before round 1,
	-- counted in coop_status, no trust line each and no task_fail / task_cancel failure.
	local function trust_said(from)
		local n = 0
		for i = from + 1, #H.log do if H.log[i]:find("[coop-trust]", 1, true) then n = n + 1 end end
		return n
	end
	local logs0 = #H.log
	for _ = 1, 10 do
		req(C2, "fail", "drx_sl_x")
		req(C2, "cancel", "drx_sl_x")
	end
	req(C2, "cancel", "faction_base_defense")
	check(drx.forced_status == "fail" and drx.cancelled_by_actor == true and def.cancelled_by_actor == true,
		"log mode: another player's DRX / base defense ends from his own stock logic go through as before round 1")
	check(failed("task_fail") == 0 and failed("task_cancel") == 0, "not counted as a task_fail / task_cancel failure")
	check(trust_said(logs0) == 0, "no coop-trust line for each (" .. trust_said(logs0) .. ")")
	local sl = status_line(H, "task_auto_end")
	check(sl ~= nil and sl:find("21", 1, true) ~= nil and sl:find("[log]", 1, true) ~= nil and sl:find("refused 0", 1, true) ~= nil,
		"coop_status counts them under task_auto_end [log]: " .. tostring(sl))
	drx.forced_status, drx.cancelled_by_actor, def.forced_status, def.cancelled_by_actor = nil, nil, nil, nil
	-- the owner switches task_auto_end to "refuse" later: then they change nothing, still without a line each
	trust.reset_for_test({ default = "log", task_auto_end = "refuse" })
	logs0 = #H.log
	req(C2, "fail", "drx_sl_x")
	req(C2, "cancel", "drx_sl_x")
	req(C2, "cancel", "faction_base_defense")
	check(drx.forced_status == nil and drx.cancelled_by_actor == nil and def.cancelled_by_actor == nil,
		"task_auto_end = refuse: they change nothing")
	check(trust_said(logs0) == 0 and failed("task_fail") == 0 and failed("task_cancel") == 0, "refuse: still no line each")
	sl = status_line(H, "task_auto_end")
	check(sl ~= nil and sl:find("24", 1, true) ~= nil and sl:find("[refuse]", 1, true) ~= nil and sl:find("refused 3", 1, true) ~= nil,
		"coop_status: 24 counted, 3 refused: " .. tostring(sl))
	trust.reset_for_test({ default = "log", task_auto_end = "off" })
	req(C2, "cancel", "faction_base_defense")
	check(def.cancelled_by_actor == true and (status_line(H, "task_auto_end") or ""):find("24", 1, true) ~= nil,
		"task_auto_end = off: through, not counted")
	def.forced_status, def.cancelled_by_actor = nil, nil
	trust.reset_for_test({ default = "log" })
	-- the taker's own machine ends them as before
	req(C, "fail", "drx_sl_x")
	check(drx.forced_status == "fail", "the taker's own DRX fail goes through")
	drx.forced_status = nil

	-- F5 (b, c): a player who did not take it talks to its giver a moment ago (dialogs.npc_cancel_task at the giver), or, for a
	-- task with no giver, to the NPC of the dialog (dialogs_lostzone.fail_task_lttz_hb_4_1_crossfire): his choice, it goes through
	trust.reset_for_test({ default = "log", task_fail = "refuse", task_cancel = "refuse" })
	local npc777, npc779 = C2.new_obj(777), C2.new_obj(779)
	local speaker = npc777
	C2.env.get_speaker = function() return speaker end
	H.env.coop.talk_recent = function(peer, npc, ms) return peer == 2 and (npc == 777 or npc == 779) and ms <= 60000 end
	C2.talking = true
	C2.tm:set_task_cancelled("cord_2")
	pump()
	check(cord.cancelled_by_actor == true and failed("task_cancel") == 0, "a cancel at the task's giver he talks to: goes through")
	cord.forced_status, cord.cancelled_by_actor = nil, nil
	speaker = npc779
	C2.tm:set_task_failed("story_2")
	pump()
	check(story.forced_status == "fail" and failed("task_fail") == 0, "a story fail in a dialog (a task with no giver): goes through")
	story.forced_status = nil
	-- the giver is known and he talks to somebody else: refused, and he is told who can (the texts of the mod's eng file)
	local told = {}
	C2.actor.give_game_news = function(_, caption, text) told[#told + 1] = text end
	local texts = {}
	local xf = assert(io.open("gamedata/configs/text/eng/st_coop_news.xml", "r"))
	for sid, text in xf:read("*a"):gmatch('<string id="([%w_]+)">%s*<text>(.-)</text>') do texts[sid] = text end
	xf:close()
	check(texts.st_coop_task_only_taker and texts.st_coop_task_only_taker:find("%s", 1, true)
		and texts.st_coop_task_only_taker_anon and texts.st_coop_task_only_taker_caption, "the texts of the line are in the eng file")
	C2.env.game = { translate_string = function(s) return texts[s] or s end }
	C2.tm:set_task_cancelled("cord_2")
	pump()
	check(cord.cancelled_by_actor == nil and failed("task_cancel") == 1, "a cancel of a task of NPC 777 while talking to 779: refused")
	check(#told == 1 and told[1]:find("one", 1, true) ~= nil, "the refused player is told who can: " .. tostring(told[1]))
	-- not talking: refused, told
	C2.talking = false
	C2.tm:set_task_cancelled("cord_2")
	pump()
	check(cord.cancelled_by_actor == nil and #told == 2, "no talk: refused and told")
	-- the host did not see the talk (a claim of a speaker): refused
	H.env.coop.talk_recent = function() return false end
	C2.talking = true
	speaker = npc777
	C2.tm:set_task_cancelled("cord_2")
	pump()
	check(cord.cancelled_by_actor == nil and #told == 3, "a talk the host did not see: refused")
	C2.talking = false
	H.env.coop.talk_recent = nil
	-- log mode: a failed check goes through as round 1, and nobody is told
	trust.reset_for_test({ default = "log" })
	req(C2, "cancel", "cord_2")
	check(cord.cancelled_by_actor == true and #told == 3, "log mode: let through, nobody told")
	cord.forced_status, cord.cancelled_by_actor = nil, nil
	-- a nick that came over the network never becomes the format of the line
	local stock_nick = H.players[2].nick
	H.players[2].nick = "%s%n%d"
	trust.reset_for_test({ default = "log", task_cancel = "refuse" })
	req(C2, "cancel", "cord_2")
	check(#told == 4 and told[4]:find("%s%n%d", 1, true) ~= nil, "a nick with % signs is shown as it is: " .. tostring(told[4]))
	H.players[2].nick = stock_nick

	-- round 3 (R2-S3), Server: a player on a map server's level is judged by that server's word "he is in some dialog", which
	-- names no partner. The dialog's exception then holds only for a task without a giver.
	trust.reset_for_test({ default = "log", task_fail = "refuse", task_cancel = "refuse" })
	H.env.coop_quests_core = { is_far_peer = function(p) return p == 2 end }
	server_dialogue(H, { talking = function(p) return p == 2 end })
	H.env.coop.talk_recent = function() return false end -- (the world server has no talk lock of his: he is on another level)
	C2.talking = true
	speaker = npc777
	local refused0 = failed("task_cancel")
	C2.tm:set_task_cancelled("cord_2")
	pump()
	check(cord.cancelled_by_actor == nil and failed("task_cancel") == refused0 + 1,
		"Server: a cancel naming the task's giver while 'in some dialog': refused (his partner is not known there)")
	speaker = npc779
	C2.tm:set_task_failed("story_2")
	pump()
	check(story.forced_status == "fail" and failed("task_fail") == 0,
		"Server: a story fail in some dialog (a task without a giver): goes through")
	story.forced_status = nil
	H.env.coop.levels.talking = function() return false end
	C2.tm:set_task_failed("story_2")
	pump()
	check(story.forced_status == "fail" and failed("task_fail") == 0,
		"Server, round 6: a dialog he was in a moment ago (the host's 15 s window, as the co-op's talk_recent): goes through")
	story.forced_status = nil
	NOW = NOW + 16000
	C2.tm:set_task_failed("story_2")
	pump()
	check(story.forced_status == nil and failed("task_fail") == 1, "Server: the same 16 s after his last dialog: refused")
	server_dialogue(H)
	H.env.coop_quests_core, H.env.coop.talk_recent = nil, nil
	C2.talking = false
	trust.reset_for_test({ default = "log" })

	-- F2: the engine's turn-in of a task the host runs: refused while the host's own check says it is still running
	trust.reset_for_test({ default = "log", task_complete = "refuse" })
	local V = H.mod.host_state_verdict
	local n0 = lines("task_complete")
	check(V("cord_2", 2, 1, false, false, true) == false, "explicit engine complete of a task still running by the host's check: refused")
	check(lines("task_complete") == n0 + 1 and H.log[#H.log]:find("running", 1, true) ~= nil, "the line says the host's check: running")
	check(V("cord_2", 2, 1, false, false, false) == false, "the same by the client's own task check (not explicit): refused")
	cord.last_check_task = "complete"
	check(V("cord_2", 2, 1, false, false, true) == true, "the host's check found it complete: ok")
	cord.last_check_task = nil
	cord.forced_status = "complete" -- a turn-in on the host is on its way
	check(V("cord_2", 2, 1, false, false, true) == true, "a turn-in the host forced: ok")
	cord.forced_status = nil
	check(V("cord_2", 2, 0x100, true, false, true) == true,
		"a map server's turn-in: the facts of the task are on its level, the world server does not judge them (ok)")
	-- the engine passes the explicit flag
	local ef = io.open("engine/src/xrGame/coop/coop_story_tasks.cpp", "r")
	local esrc = ef and ef:read("*a") or ""
	if ef then ef:close() end
	local call = 'luafn::call_named(ai().script_engine().lua(), "coop_tasks", "host_state_verdict", nullptr,'
	check(esrc:find(call, 1, true) ~= nil
		and esrc:find("lua_pushboolean(L, explicit_call ? 1 : 0);", 1, true) ~= nil
		and esrc:find("return 6;", 1, true) ~= nil
		and esrc:find("task_time_ran_out(t), explicit_call))", 1, true) ~= nil,
		"coop_story_tasks.cpp gives host_state_verdict the explicit flag")

	-- F2: a stage goes only up, one step at a time (check task_stage). Round 3 (R2-S2): a step also needs his talk a moment ago,
	-- which the host saw, with the task's giver or with the NPC the task points to now (its target, the NPC or his squad):
	-- aysd (Ashot and Yar) steps +1 in a talk with Ashot while the task points to Ashot's squad, with Yar (its giver) while it
	-- points to Yar's.
	trust.reset_for_test({ default = "log", task_stage = "refuse" })
	H.env.coop.talk_recent = function(peer, npc) return peer == 1 and (npc == 777 or npc == 779 or npc == 780) end
	-- (an engine without coop.talk_lock_of: the host cannot tell one talk from the next, the round 4 rule "one step per talk"
	-- has no facts here and holds; it is tested below with the locks)
	local stock_lock_of = H.env.coop.talk_lock_of
	H.env.coop.talk_lock_of = nil
	cord.stage = 1
	req(C, "stage", "cord_2", ";st=n2;sp=n777")
	check(cord.stage == 2 and failed("task_stage") == 0, "one step up in a talk with its giver: ok")
	req(C, "stage", "cord_2", ";st=n2")
	check(cord.stage == 2 and failed("task_stage") == 0, "the same stage again: ok (nothing changes, no talk asked)")
	req(C, "stage", "cord_2", ";st=n3")
	check(cord.stage == 2 and failed("task_stage") == 1, "one step up, no talk named: refused")
	req(C, "stage", "cord_2", ";st=n3;sp=n779")
	local stage_line = ""
	for i = #H.log, 1, -1 do
		if H.log[i]:find("[coop-trust] ! task_stage:", 1, true) then stage_line = H.log[i] break end
	end
	check(cord.stage == 2 and failed("task_stage") == 2 and stage_line:find("779", 1, true) ~= nil,
		"one step up in a talk with an NPC that is neither its giver nor its target: refused, the line names him")
	H.env.alife_object = function(id) if id == 779 then return { id = 779, group_id = 7790 } end end
	cord.current_target = 7790 -- the host's last look: the task points to 779's squad
	req(C, "stage", "cord_2", ";st=n3;sp=n779")
	check(cord.stage == 3 and failed("task_stage") == 2, "a step in a talk with a member of the squad the task points to: ok")
	-- where the task points now is its target functor's word (the host's last look may be a second old): aysd's alternates
	H.env.task_functor = { tf_cord = function(id, field, p, tsk) return tsk.stage % 2 == 0 and 7790 or 777 end }
	cord.target_functor = "tf_cord"
	req(C, "stage", "cord_2", ";st=n4;sp=n779")
	check(cord.stage == 3 and failed("task_stage") == 3,
		"a second step at the same NPC: refused (at stage 3 the task points to its giver, the last look still said 779's squad)")
	req(C, "stage", "cord_2", ";st=n4;sp=n777")
	check(cord.stage == 4 and failed("task_stage") == 3, "the step at its giver: ok")
	req(C, "stage", "cord_2", ";st=n6;sp=n779")
	check(cord.stage == 4 and failed("task_stage") == 4, "two steps up in a talk: refused")
	req(C, "stage", "cord_2", ";st=n0;sp=n777")
	check(cord.stage == 4 and failed("task_stage") == 5, "down: refused")
	H.env.coop.talk_recent = function() return false end
	req(C, "stage", "cord_2", ";st=n5;sp=n779")
	check(cord.stage == 4 and failed("task_stage") == 6, "a talk the host did not see: refused")
	-- the client's stage write in a dialog names the NPC of the talk (as a fail or a cancel does)
	H.env.coop.talk_recent = function(peer, npc) return peer == 1 and npc == 779 end
	local npc779c = C.new_obj(779)
	C.env.get_speaker = function() return npc779c end
	C.talking = true
	C.tm.task_info.cord_2.stage = 5
	pump()
	check(cord.stage == 5 and failed("task_stage") == 6, "a dialog's stage write on the client names his partner: ok")
	C.talking = false

	-- Round 4 (blocker 1 of the round 3 review). (a) The giver's talk counts only while the task points to the giver: the
	-- review's probe, 30 steps asked in a talk with giver 777 while the task points to 779's squad on even stages.
	H.env.coop.talk_recent = function(peer, npc) return peer == 1 and (npc == 777 or npc == 779 or npc == 780) end
	local f0 = failed("task_stage")
	cord.stage = 10
	for _ = 1, 30 do req(C, "stage", "cord_2", ";st=n" .. (cord.stage + 1) .. ";sp=n777") end
	check(cord.stage == 10 and failed("task_stage") == f0 + 30,
		"30 steps in a talk with the giver while the task points to another squad: none (stage " .. cord.stage .. ")")
	-- (b) One step per talk the host saw (coop.talk_lock_of: the lock he holds; a new lock is a new talk). (Fresh counters: a
	-- check writes its first 8 lines, then every 64th.)
	trust.reset_for_test({ default = "log", task_stage = "refuse" })
	local lock = {}
	H.env.coop.talk_lock_of = function(peer) return lock[peer] end
	H.env.task_functor.tf_fixed = function() return 7790 end
	cord.target_functor = "tf_fixed" -- the task points to 779's squad whatever the stage
	lock[1] = 779
	f0 = failed("task_stage")
	req(C, "stage", "cord_2", ";st=n11;sp=n779")
	check(cord.stage == 11 and failed("task_stage") == f0, "a step in a new talk with 779: ok")
	req(C, "stage", "cord_2", ";st=n12;sp=n779")
	check(cord.stage == 11 and failed("task_stage") == f0 + 1, "a second step in the same talk: refused")
	local said = ""
	for i = #H.log, 1, -1 do
		if H.log[i]:find("[coop-trust] ! task_stage:", 1, true) then said = H.log[i] break end
	end
	check(said:find("one step per talk", 1, true) ~= nil, "the line says one step per talk: " .. said)
	lock[1] = nil
	tick(H) -- the host's look: the talk ended
	req(C, "stage", "cord_2", ";st=n12;sp=n779")
	check(cord.stage == 11 and failed("task_stage") == f0 + 2,
		"the talk ended a moment ago (talk_recent still says yes), no new one: refused")
	lock[1] = 779
	tick(H) -- a new talk with him
	req(C, "stage", "cord_2", ";st=n12;sp=n779")
	check(cord.stage == 12 and failed("task_stage") == f0 + 2, "a new talk with him: ok")
	-- aysd's honest round trip: the task points to 779's squad on even stages, to its giver 777 on odd ones; each step in a talk
	-- of its own, and a talk with 779 that a step used is not used again across the talk with 777
	cord.target_functor = "tf_cord"
	lock[1] = nil
	tick(H)
	lock[1] = 779
	tick(H)
	req(C, "stage", "cord_2", ";st=n13;sp=n779")
	check(cord.stage == 13, "aysd: a step at Ashot's squad (even stage), in its own talk: ok")
	lock[1] = 777
	tick(H)
	req(C, "stage", "cord_2", ";st=n14;sp=n777")
	check(cord.stage == 14 and failed("task_stage") == f0 + 2, "aysd: the step back at the giver (odd stage), in its own talk: ok")
	lock[1] = nil
	tick(H)
	req(C, "stage", "cord_2", ";st=n15;sp=n779")
	check(cord.stage == 14 and failed("task_stage") == f0 + 3,
		"the talk with 779 that a step used, recent again after the talk with 777: refused")
	lock[1] = 779
	tick(H)
	req(C, "stage", "cord_2", ";st=n15;sp=n779")
	check(cord.stage == 15 and failed("task_stage") == f0 + 3, "a new talk with 779: ok")
	lock[1] = nil
	tick(H)
	-- (c) A task with neither a target nor a giver: only an NPC its own target condlist names, or nobody
	f0 = failed("task_stage")
	story.stage = 0
	req(C, "stage", "story_2", ";st=n1;sp=n779")
	check(story.stage == 0 and failed("task_stage") == f0 + 1, "no giver, no target, a condlist that names nobody: refused")
	story.target = "{+story_2_info} story_npc_a, story_npc_b %=give_info(x)%"
	H.env.get_story_object_id = function(sid) return ({ story_npc_a = 7700, story_npc_b = 779 })[sid] end
	req(C, "stage", "story_2", ";st=n1;sp=n780")
	check(story.stage == 0 and failed("task_stage") == f0 + 2, "an NPC its condlist does not name: refused")
	req(C, "stage", "story_2", ";st=n1;sp=n779")
	check(story.stage == 1 and failed("task_stage") == f0 + 2, "the NPC its condlist names (any branch): ok")
	-- (d) Server: his map server says only "in some dialog". A step is judged ok only for a task with neither a giver nor a
	-- target (the partner needs a field in LevelBodyFacts: a protocol change, the owner's decision); one step per dialog.
	H.env.coop_quests_core = { is_far_peer = function(p) return p == 1 end }
	local talking = true
	server_dialogue(H, { talking = function(p) return p == 1 and talking end })
	H.env.coop.talk_recent = function() return false end -- (the world server holds no talk lock of his)
	trust.reset_for_test({ default = "log", task_stage = "refuse" })
	f0 = failed("task_stage")
	req(C, "stage", "cord_2", ";st=n16;sp=n779")
	said = ""
	for i = #H.log, 1, -1 do
		if H.log[i]:find("[coop-trust] ! task_stage:", 1, true) then said = H.log[i] break end
	end
	check(cord.stage == 15 and failed("task_stage") == f0 + 1 and said:find("Server", 1, true) ~= nil,
		"Server: a step of a task with a giver and a target: refused, the line says why: " .. said)
	talking = false
	tick(H)
	talking = true
	tick(H)
	req(C, "stage", "story_2", ";st=n2;sp=n779")
	check(story.stage == 2 and failed("task_stage") == f0 + 1, "Server: a task with neither, the NPC its condlist names, in a dialog: ok")
	req(C, "stage", "story_2", ";st=n3;sp=n779")
	check(story.stage == 2 and failed("task_stage") == f0 + 2, "Server: a second step in the same dialog: refused")
	talking = false
	tick(H)
	req(C, "stage", "story_2", ";st=n3;sp=n779")
	check(story.stage == 2 and failed("task_stage") == f0 + 3, "Server: in no dialog: refused")
	talking = true
	tick(H)
	req(C, "stage", "story_2", ";st=n3;sp=n779")
	check(story.stage == 3 and failed("task_stage") == f0 + 3, "Server: a new dialog: ok")
	server_dialogue(H)
	H.env.coop_quests_core, H.env.coop.talk_lock_of, H.env.get_story_object_id = nil, stock_lock_of, nil
	story.target, story.stage = nil, 0
	H.env.task_functor, H.env.alife_object, H.env.coop.talk_recent = nil, nil, nil
	cord.target_functor, cord.current_target = nil, nil
	trust.reset_for_test({ default = "log" })
	req(C, "stage", "cord_2", ";st=n9")
	check(cord.stage == 9 and lines("task_stage") >= 1, "log mode: a jump goes through, logged")

	-- Round 4 (S1 of the round 3 review): the Lua turn-in (ops.complete) checked money and items only. A talk with the giver alone
	-- cannot be asked for: the honest turn-ins are a dialog's with the giver (axr_task_manager, DRX), with the NPC the task points to
	-- (tasks_delivery complete_simulation_task: the parcel's receiver), or with an NPC of a task without a giver (dialogs_lostzone,
	-- tasks_defense). Check task_complete_talk asks for that talk, which the host saw; Server: "in some dialog" (the partner is not
	-- reported there). "log" in build 57.
	trust.reset_for_test({ default = "log", task_complete_talk = "refuse" })
	H.env.coop.talk_recent = function(peer, npc) return peer == 1 and (npc == 777 or npc == 779 or npc == 780) end
	local function turned(tsk)
		local yes = tsk.forced_status == "complete"
		tsk.forced_status = nil
		return yes
	end
	req(C, "complete", "cord_2", ";sp=n777")
	check(turned(cord) and failed("task_complete_talk") == 0, "a turn-in in a talk with its giver: ok")
	req(C, "complete", "cord_2")
	local tline = ""
	for i = #H.log, 1, -1 do
		if H.log[i]:find("[coop-trust] ! task_complete_talk:", 1, true) then tline = H.log[i] break end
	end
	check(not turned(cord) and failed("task_complete_talk") == 1 and tline:find("one", 1, true) ~= nil,
		"a turn-in that names no talk: refused, the line names the player: " .. tline)
	req(C, "complete", "cord_2", ";sp=n779")
	check(not turned(cord) and failed("task_complete_talk") == 2, "in a talk with an NPC that is neither its giver nor its target: refused")
	H.env.alife_object = function(id) if id == 779 then return { id = 779, group_id = 7790 } end end
	cord.current_target = 7790 -- a delivery: the task points to the receiver (his squad)
	req(C, "complete", "cord_2", ";sp=n779")
	check(turned(cord) and failed("task_complete_talk") == 2, "in a talk with the NPC the task points to (a delivery's receiver): ok")
	cord.current_target = nil
	req(C, "complete", "story_2", ";sp=n780")
	check(turned(story) and failed("task_complete_talk") == 2, "a task without a giver, in a talk with any NPC: ok")
	H.env.coop.talk_recent = function() return false end
	req(C, "complete", "story_2", ";sp=n780")
	check(not turned(story) and failed("task_complete_talk") == 3, "a talk the host did not see: refused")
	-- Server: his map server's word "in some dialog"
	H.env.coop_quests_core = { is_far_peer = function(p) return p == 1 end }
	local in_dialog = true
	server_dialogue(H, { talking = function(p) return p == 1 and in_dialog end })
	req(C, "complete", "cord_2", ";sp=n779")
	check(turned(cord) and failed("task_complete_talk") == 3, "Server: in some dialog (the partner is not reported there): ok")
	in_dialog = false
	NOW = NOW + 1000
	req(C, "complete", "cord_2", ";sp=n779")
	check(turned(cord) and failed("task_complete_talk") == 3,
		"Server, round 6 (S2): a turn-in 1 s after the dialog closed (z_gavrilenko_tasks_fix): the host's 15 s window, ok")
	NOW = NOW + 16000
	req(C, "complete", "cord_2", ";sp=n779")
	check(not turned(cord) and failed("task_complete_talk") == 4, "Server: 16 s after his last dialog: refused")
	server_dialogue(H)
	H.env.coop_quests_core = nil
	-- the client's turn-in in a dialog names his partner
	H.env.coop.talk_recent = function(peer, npc) return peer == 1 and npc == 777 end
	local npc777c = C.new_obj(777)
	C.env.get_speaker = function() return npc777c end
	C.talking = true
	C.tm:set_task_completed("cord_2")
	pump()
	C.talking = false
	check(turned(cord) and failed("task_complete_talk") == 4, "the client's turn-in in a dialog with the giver names him: ok")
	-- log mode: through as before, logged
	trust.reset_for_test({ default = "log" })
	H.env.coop.talk_recent = function() return false end
	req(C, "complete", "cord_2", ";sp=n777")
	check(turned(cord) and lines("task_complete_talk") >= 1, "log mode: a turn-in without a talk goes through, logged")
	H.env.coop.talk_recent, H.env.alife_object = nil, nil

	-- Round 5 (blocker 2 of the round 4 review): the Lua turn-in of a task whose objective is not about items asks the host's own
	-- state of the task (check task_complete_state), as the engine path does (host.still_running). The honest turn-ins: the stock
	-- and DRX turn-in dialogs and z_gavrilenko_tasks_fix turn in a task at its stage_complete (the client's stub has the host's
	-- stage); the host's own check found it done; a dialog completes one named task directly (its own precondition).
	print("== R5 B2: the Lua turn-in asks the host's own state of the task")
	H.env.coop.talk_recent = function(peer, npc) return peer == 1 and (npc == 777 or npc == 780) end
	-- (round 6: a bounty also asks its target dead, test_trust_r6_tasks; here a task of another functor)
	cord.status_functor, cord.stage, cord.last_check_task, cord.forced_status = "fate_task", 0, nil, nil
	trust.reset_for_test({ default = "log", task_complete = "refuse", task_complete_state = "refuse" })
	check(H.mod.host_state_verdict("cord_2", 2, 1, false, false, true) == false, "(the engine path refuses a bounty still running)")
	req(C, "complete", "cord_2", ";sp=n777")
	local sline = ""
	for i = #H.log, 1, -1 do
		if H.log[i]:find("[coop-trust] ! task_complete_state:", 1, true) then sline = H.log[i] break end
	end
	check(not turned(cord) and failed("task_complete_state") == 1 and sline:find("one", 1, true) ~= nil
		and sline:find("254", 1, true) ~= nil, "the review's probe C1: the Lua turn-in in a talk with its giver, refused: " .. sline)
	cord.stage = 254
	req(C, "complete", "cord_2", ";sp=n777")
	check(turned(cord) and failed("task_complete_state") == 1,
		"at its stage_complete (254 without one in its ini: the stock and DRX turn-in dialogs): ok")
	local tini = H.env.task_manager.task_ini
	tini.r_float_ex = function(_, id, key) if id == "cord_2" and key == "stage_complete" then return 3 end end
	cord.stage = 3
	req(C, "complete", "cord_2", ";sp=n777")
	check(turned(cord) and failed("task_complete_state") == 1, "at the stage_complete of its ini (z_gavrilenko_tasks_fix reads it too): ok")
	cord.stage = 2
	req(C, "complete", "cord_2", ";sp=n777")
	check(not turned(cord) and failed("task_complete_state") == 2, "a stage below it: refused")
	tini.r_float_ex = nil
	cord.stage, cord.last_check_task = 0, "complete"
	req(C, "complete", "cord_2", ";sp=n777")
	check(turned(cord) and failed("task_complete_state") == 2, "the host's own check found it done: ok")
	cord.last_check_task = nil
	-- a dialog that completes one named task directly (dialogs_lostzone's crossfire at Hernandez): its precondition is the objective
	for _, m in ipairs({ H, C }) do
		local ti = m.env.task_manager.task_ini
		local known = ti.section_exist
		ti.section_exist = function(s, id) return id == "lttz_hb_task_4_1_crossfire" or known(s, id) end
	end
	C.tm:give_task("lttz_hb_task_4_1_crossfire")
	pump()
	local cf = H.tm.task_info.lttz_hb_task_4_1_crossfire
	cf.status_functor = nil
	-- round 6 (blocker 6 of the round 5 review): such a task asks its own dialog's condition, not any stage (host.DIALOG_TURN_INS;
	-- every entry: test_trust_r6_tasks). Crossfire: at the ISG leader, the group holds Strelok's pendrive.
	req(C, "complete", "lttz_hb_task_4_1_crossfire", ";sp=n780")
	check(not turned(cf) and failed("task_complete_state") == 3,
		"round 6: crossfire at an NPC who is not the ISG leader, no pendrive: refused")
	H.env.get_story_object_id = function(sid) return sid == "jup_depo_isg_leader" and 780 or nil end
	req(C, "complete", "lttz_hb_task_4_1_crossfire", ";sp=n780")
	check(not turned(cf) and failed("task_complete_state") == 4, "round 6: at the ISG leader, nobody holds the pendrive: refused")
	local pendrive = H.give_item(proxy_on_host, "strelok_pendrive")
	req(C, "complete", "lttz_hb_task_4_1_crossfire", ";sp=n780")
	check(turned(cf) and failed("task_complete_state") == 4, "round 6: at the ISG leader, the pendrive with the group: ok")
	H.env.alife_release_id(pendrive._id)
	H.env.get_story_object_id = nil
	-- an item task is the money and item checks' (a DRX money task: the taker's ledger pays it)
	cord.status_functor = "drx_sl_money_task_status"
	req(C, "complete", "cord_2", ";sp=n777")
	check(turned(cord) and failed("task_complete_state") == 4 and trust.status().task_complete_state.checked == 8,
		"a money task: not judged by its state (" .. trust.status().task_complete_state.checked .. " checked)")
	-- log mode: through as before, a line
	cord.status_functor = "fate_task"
	trust.reset_for_test({ default = "log" })
	req(C, "complete", "cord_2", ";sp=n777")
	check(turned(cord) and lines("task_complete_state") >= 3, "log mode: a turn-in of a task still running goes through, logged")
	H.tm.task_info.lttz_hb_task_4_1_crossfire, H.engine_tasks.lttz_hb_task_4_1_crossfire = nil, nil

	-- Round 5 (S1 of the round 4 review): DRX gives a task with the giver's squad id (dialogs.drx_sl_give_sl_task: giver_id =
	-- se_obj.group_id), and its stock turn-in accepts any member of that squad (axr_task_manager.get_first_finished_task)
	print("== R5 S1: a member of the giver's squad counts as the giver")
	trust.reset_for_test({ default = "log", task_complete_talk = "refuse", task_cancel = "refuse", task_stage = "refuse" })
	H.env.alife_object = function(id)
		if id == 779 then return { id = 779, group_id = 7790 } end
		if id == 781 then return { id = 781, group_id = 7810 } end
	end
	H.env.coop.talk_recent = function(peer, npc) return (peer == 1 or peer == 2) and (npc == 779 or npc == 781) end
	local stock_lock = H.env.coop.talk_lock_of
	H.env.coop.talk_lock_of = nil
	cord.task_giver_id, cord.target_functor, cord.current_target, cord.stage = 7790, nil, nil, 254
	req(C, "complete", "cord_2", ";sp=n779")
	check(turned(cord) and failed("task_complete_talk") == 0,
		"the review's probe C4: a turn-in at a member of the giver squad, the task pointing nowhere: ok")
	req(C, "complete", "cord_2", ";sp=n781")
	check(not turned(cord) and failed("task_complete_talk") == 1, "a member of another squad: refused")
	req(C2, "cancel", "cord_2", ";sp=n779")
	check(cord.cancelled_by_actor == true and failed("task_cancel") == 0,
		"another player's cancel in a talk with the giver's squad member (dialogs.npc_cancel_task): his choice, ok")
	cord.forced_status, cord.cancelled_by_actor = nil, nil
	cord.stage = 20
	req(C, "stage", "cord_2", ";st=n21;sp=n779")
	check(cord.stage == 21 and failed("task_stage") == 0, "a stage step at the giver's squad member, the task pointing nowhere: ok")
	req(C, "stage", "cord_2", ";st=n22;sp=n781")
	check(cord.stage == 21 and failed("task_stage") == 1, "at a member of another squad: refused")
	cord.task_giver_id = 777

	-- Round 5 (S4 of the round 4 review): z_gavrilenko_tasks_fix turns the task in 1 s after the dialog opens, the dialog may be
	-- closed by then. The client keeps the NPC of its last talk for the host's window (15 s) and names him.
	print("== R5 S4: a turn-in a moment after the dialog closed names the NPC of the last talk")
	trust.reset_for_test({ default = "log", task_complete_talk = "refuse" })
	H.env.coop.talk_recent = function(peer, npc) return peer == 1 and npc == 777 end
	local gav = C.new_obj(777)
	C.env.get_speaker = function() return gav end
	C.talking = true
	C.callbacks.GUI_on_show("Dialog")
	C.talking = false
	C.callbacks.GUI_on_hide("Dialog")
	NOW = NOW + 1000
	C.tm:set_task_completed("cord_2")
	pump()
	check(turned(cord) and failed("task_complete_talk") == 0, "1 s after the dialog opened, it closed meanwhile: he names 777, ok")
	NOW = NOW + 16000
	C.tm:set_task_completed("cord_2")
	pump()
	check(not turned(cord) and failed("task_complete_talk") == 1, "16 s after the talk: no partner named, refused")

	-- Round 5 (S5 of the round 4 review): a dialog closed and opened again with the same NPC between two looks of the host's scan
	-- (0.5 s) is a new talk. The engine asks coop_npc_meet.talk_verdict before it grants a client's lock (coop_dialog.cpp
	-- host_try_lock): a lock granted while he does not hold this NPC's is a new talk; a request repeated while he holds it is not.
	print("== R5 S5: a quick re-talk with the same NPC is a new talk")
	trust.reset_for_test({ default = "log", task_stage = "refuse" })
	local lock = {}
	H.env.coop.talk_lock_of = function(peer) return lock[peer] end
	H.env.coop.talk_recent = function(peer, npc) return peer == 1 and npc == 779 end
	H.env.task_functor = { tf_s5 = function() return 7790 end }
	cord.target_functor = "tf_s5"
	local granted = true
	H.env.coop_npc_meet = { talk_verdict = function(npc, who)
		if granted then return true, nil end
		return false, "busy"
	end }
	local stock_verdict = H.env.coop_npc_meet.talk_verdict
	tick(H) -- the host's scan
	local verdict = H.env.coop_npc_meet.talk_verdict
	check(verdict ~= stock_verdict, "the host watches the talks it grants (coop_npc_meet.talk_verdict)")
	local a1, a2 = verdict(H.new_obj(5779), proxy_on_host)
	check(a1 == true and a2 == nil, "the verdict's answer is the stock one")
	local npc779h = H.new_obj(779)
	verdict(npc779h, proxy_on_host)
	lock[1] = 779
	tick(H)
	cord.stage = 30
	req(C, "stage", "cord_2", ";st=n31;sp=n779")
	check(cord.stage == 31 and failed("task_stage") == 0, "a step in his talk with 779: ok")
	lock[1] = nil
	verdict(npc779h, proxy_on_host) -- closed and opened again before the host looked
	lock[1] = 779
	req(C, "stage", "cord_2", ";st=n32;sp=n779")
	check(cord.stage == 32 and failed("task_stage") == 0, "a quick re-talk with 779 between two looks: a new talk, ok")
	verdict(npc779h, proxy_on_host) -- a client that asks for the lock again while he holds it
	req(C, "stage", "cord_2", ";st=n33;sp=n779")
	check(cord.stage == 32 and failed("task_stage") == 1, "the lock asked again while he holds it: no new talk, refused")
	lock[1] = nil
	granted = false
	check(verdict(npc779h, proxy_on_host) == false, "(the meet rules say no)")
	granted = true
	lock[1] = 779
	req(C, "stage", "cord_2", ";st=n33;sp=n779")
	check(cord.stage == 32 and failed("task_stage") == 2, "a talk the host did not grant: no new talk, refused")
	lock[1] = nil
	tick(H)
	H.env.coop_npc_meet, H.env.task_functor, H.env.alife_object, H.env.coop.talk_recent = nil, nil, nil, nil
	H.env.coop.talk_lock_of = stock_lock
	cord.target_functor, cord.status_functor, cord.stage = nil, "actor_has_fetch_item", 0
	trust.reset_for_test({ default = "log" })

	for _, id in ipairs({ "drx_sl_x", "faction_base_defense", "cord_2", "story_2" }) do
		H.tm.task_info[id] = nil
		H.engine_tasks[id] = nil
	end
	tick(H)
	pump()
	H.players[#H.players] = nil
	H.env.coop_trust = nil
	for i = #MACHINES, 1, -1 do if MACHINES[i] == C2 then table.remove(MACHINES, i) end end
end

-- ---------------------------------------------------------------- S5 (A-S5T): the partner of a talk on another level
-- Server (build 57, protocol 33): the map server of a player's level names the NPC he talks to there (LevelBodyFacts.partner, coop
-- levels.talk_partner); coop_mode.facts_of hands it to the Core. The world server then judges a stage
-- step, a turn-in and a dialog's end as the co-op host does: the talk with that NPC now or in the last 15 s. An older engine
-- reports only whether the player is in a dialog.
print("== S5 (A-S5T), Server: the NPC a player talks to on a map server's level is named, his steps and turn-ins are judged as in the co-op")
do
	local trust = setmetatable({}, { __index = H.env })
	local fh = assert(io.open("gamedata/scripts/coop_trust.script", "r"))
	local tf = assert(loadstring(fh:read("*a"), "@coop_trust.script"))
	fh:close()
	setfenv(tf, trust)
	tf()
	H.env.coop_trust = trust
	local function failed(name) return (trust.status()[name] or { failed = 0 }).failed end
	for _, m in ipairs({ H, C }) do
		local ti = m.env.task_manager.task_ini
		local known = ti.section_exist
		ti.section_exist = function(s, id) return id == "s5_talk" or id == "s5_story" or known(s, id) end
	end
	local function req(op, id, extra)
		C.env.coop.send_event("coop_tq", "op=s" .. op .. ";i=s" .. id .. (extra or ""), 0)
		pump()
	end
	local function turned(tsk)
		local yes = tsk.forced_status == "complete"
		tsk.forced_status = nil
		return yes
	end
	C.tm:give_task("s5_talk", 777)
	pump()
	C.tm:give_task("s5_story")
	pump()
	local tk, st = H.tm.task_info.s5_talk, H.tm.task_info.s5_story
	check(tk ~= nil and st ~= nil and tk.task_giver_id == 777, "(client 1 took a task of NPC 777 and a story task with no giver)")
	-- client 1 stands on a map server's level: the world server holds no talk lock of his
	local partner = nil
	H.env.coop_quests_core = { is_far_peer = function(p) return p == 1 end }
	server_dialogue(H, {
		talking = function(p) return p == 1 and partner ~= nil end,
		talk_partner = function(p) if p == 1 then return partner end end,
	})
	H.env.coop.talk_recent = function() return false end
	trust.reset_for_test({ default = "log", task_stage = "refuse", task_complete_talk = "refuse" })

	partner = 777
	req("stage", "s5_talk", ";st=n1;sp=n777")
	check(tk.stage == 1 and failed("task_stage") == 0,
		"Server, partner named: a step of a task with a giver, in his talk with the giver: ok (vague before: refused)")
	req("stage", "s5_talk", ";st=n2;sp=n777")
	check(tk.stage == 1 and failed("task_stage") == 1, "Server, partner named: a second step in the same talk: refused (one step per talk)")
	partner = 779
	req("stage", "s5_talk", ";st=n2;sp=n779")
	check(tk.stage == 1 and failed("task_stage") == 2, "Server, partner named: a step in a talk with 779, who is not its giver: refused")
	NOW = NOW + 16000
	req("stage", "s5_talk", ";st=n2;sp=n777")
	check(tk.stage == 1 and failed("task_stage") == 3, "Server, partner named: 16 s after the talk with 777 he talks to 779: a step at 777 is refused")

	partner = 777
	req("complete", "s5_talk", ";sp=n777")
	check(turned(tk) and failed("task_complete_talk") == 0, "Server, partner named: a turn-in in his talk with the giver: ok")
	partner = nil
	NOW = NOW + 1000
	req("complete", "s5_talk", ";sp=n777")
	check(turned(tk) and failed("task_complete_talk") == 0, "Server, partner named: 1 s after that talk closed (z_gavrilenko_tasks_fix): ok")
	partner = 779
	req("complete", "s5_talk", ";sp=n779")
	check(not turned(tk) and failed("task_complete_talk") == 1,
		"Server, partner named: a turn-in in a talk with 779, neither its giver nor its target: refused (vague before: ok)")
	partner = 780
	req("complete", "s5_story", ";sp=n780")
	check(turned(st) and failed("task_complete_talk") == 1, "Server, partner named: a task without a giver, in a talk with any NPC: ok")
	partner = 781
	NOW = NOW + 16000
	req("complete", "s5_story", ";sp=n780")
	check(not turned(st) and failed("task_complete_talk") == 2,
		"Server, partner named: he names 780, his map server says he talks to 781 and his talk with 780 is 16 s old: refused")

	-- Review A-REV-E-2 finding 5: he closed the dialog with 777 and opened it again between two of his map server's body reports
	-- (the partner stays 777; the world server's looks never saw him talk to nobody). The map server's word "a new talk granted"
	-- (coop_srv_tasks -> coop_tasks.far_talk_new) makes the next step a step of a new talk; one step in it, as in any talk.
	partner = 777
	tk.stage = 1
	local s0 = failed("task_stage")
	req("stage", "s5_talk", ";st=n2;sp=n777")
	check(tk.stage == 1 and failed("task_stage") == s0 + 1, "(the talk with 777 a step used: a second step is refused)")
	local T = H.env.coop_tasks
	check(type(H.env.coop_tasks_requests.far_talk_new) == "function", "the Core takes a map server's word of a new talk (coop_tasks_requests.far_talk_new)")
	if type(H.env.coop_tasks_requests.far_talk_new) == "function" then
		for _, junk in ipairs({ { 1, 0 }, { 1, 65535 }, { 1, 1.5 }, { 1, "777" }, { 0, 777 }, { 2, 777 }, { "1", 777 }, { 1.5, 777 } }) do
			H.env.coop_tasks_requests.far_talk_new(junk[1], junk[2])
		end
		req("stage", "s5_talk", ";st=n2;sp=n777")
		check(tk.stage == 1 and failed("task_stage") == s0 + 2, "a word with junk ids or of another player renews nothing")
		H.env.coop_tasks_requests.far_talk_new(1, 779)
		req("stage", "s5_talk", ";st=n2;sp=n777")
		check(tk.stage == 1 and failed("task_stage") == s0 + 3, "a new talk with another NPC renews nothing with 777")
		H.env.coop_tasks_requests.far_talk_new(1, 777)
		req("stage", "s5_talk", ";st=n2;sp=n777")
		check(tk.stage == 2 and failed("task_stage") == s0 + 3, "a step in the talk with 777 his map server granted again: ok")
		req("stage", "s5_talk", ";st=n3;sp=n777")
		check(tk.stage == 2 and failed("task_stage") == s0 + 4, "one step in that talk: a second is refused")
	end
	tk.stage = 1

	-- An older engine has no partner binding.
	H.env.coop.levels.talk_partner = nil
	NOW = NOW + 16000
	partner = 779
	local f0 = failed("task_stage")
	req("stage", "s5_talk", ";st=n2;sp=n777")
	check(tk.stage == 1 and failed("task_stage") == f0 + 1, "no partner fact on an older engine: a step of a task with a giver is refused")
	req("complete", "s5_talk", ";sp=n779")
	check(turned(tk) and failed("task_complete_talk") == 2, "no partner fact on an older engine: a turn-in in some dialog is still accepted")

	server_dialogue(H)
	H.env.coop_quests_core, H.env.coop.talk_recent = nil, nil
	for _, id in ipairs({ "s5_talk", "s5_story" }) do
		H.tm.task_info[id], H.engine_tasks[id], C.tm.task_info[id] = nil, nil, nil
	end
	trust.reset_for_test({ default = "log" })
	H.env.coop_trust = nil
end

-- ---------------------------------------------------------------- F2 round 7, P-STALE (temp\f2_r7\review7.json)
-- host.give_own, "refuse": the host cannot make its own pick (no NPC of the give here: a giver id that is an item, a squad on another
-- level). It returned `want.job and false or bt`, which Lua reads as `(want.job and false) or bt`: always his bt. So the dead target he
-- named stayed the host's, or, when he named none, the last run's dead target in bounties_by_id, and the bounty turned in at once.
print("== F2 round 7 P-STALE: a bounty the host cannot make for him keeps no dead target (refuse); log as build 56")
do
	local trust = setmetatable({}, { __index = H.env })
	local fh = assert(io.open("gamedata/scripts/coop_trust.script", "r"))
	local tf = assert(loadstring(fh:read("*a"), "@coop_trust.script"))
	fh:close()
	setfenv(tf, trust)
	tf()
	H.env.coop_trust = trust
	for _, m in ipairs({ H, C }) do
		local ti = m.env.task_manager.task_ini
		local known = ti.section_exist
		ti.section_exist = function(s, id) return id == "s5_bty" or known(s, id) end
	end
	local made = 0
	H.env.coop_quests_offer = {
		offers_of = function() return nil end, -- no offer of his giver
		-- the task's own generator: his target is no pick of its setup; the host's own run is a bounty's ("job")
		own_pick = function(id, vars, bt) return false, "a target the bounty's setup does not pick", { bt = "job" }, { job = true } end,
		host_make = function() made = made + 1 error("no NPC of the give here") end,
	}
	local hb, cb = H.env.axr_task_manager.bounties_by_id, C.env.axr_task_manager.bounties_by_id
	local function again()
		H.tm.task_info.s5_bty, H.engine_tasks.s5_bty, C.tm.task_info.s5_bty = nil, nil, nil
		hb.s5_bty, cb.s5_bty = nil, nil
	end
	trust.reset_for_test({ default = "log", task_give_offer = "refuse" })
	cb.s5_bty = 4702 -- a target he killed already; his giver id 8800 is an item, no talker
	C.tm:give_task("s5_bty", 8800)
	pump()
	check(H.tm.task_info.s5_bty ~= nil and made == 1, "(refuse: given; the host tried to make its own and could not)")
	check(hb.s5_bty == nil, "refuse, P-STALE F3b: the dead target he named (4702) is not the host's target: " .. tostring(hb.s5_bty))
	again()
	hb.s5_bty = 4700 -- the last run's dead target, still in the host's table
	C.tm:give_task("s5_bty", 8800)
	pump()
	check(H.tm.task_info.s5_bty ~= nil and hb.s5_bty == nil,
		"refuse, P-STALE F3: he names none; the last run's dead target (4700) is not kept: " .. tostring(hb.s5_bty))
	again()
	trust.reset_for_test({ default = "log" })
	cb.s5_bty = 4702
	C.tm:give_task("s5_bty", 8800)
	pump()
	check(hb.s5_bty == 4702, "log: his target is written as in build 56 (a line only): " .. tostring(hb.s5_bty))
	again()
	H.env.coop_quests_offer, H.env.coop_trust = nil, nil
end

-- ---------------------------------------------------------------- A-REV-E-2 F4: give prepares the task before spending the offer
print("== F4, Co-op: a give keeps the offer through host_after_give")
do
	local id, giver = "f4_give", 777
	local ti = H.env.task_manager.task_ini
	local known = ti.section_exist
	ti.section_exist = function(self, tid) return tid == id or known(self, tid) end
	local offer = { {} }
	local pending = offer
	local prepared_with_offer
	local offers = {}
	function offers.offers_of(peer, tid)
		if peer == 1 and tid == id then return pending, { { npc = giver } } end
	end
	function offers.host_after_give(tid, peer, npc)
		prepared_with_offer = npc == giver and offers.offers_of(peer, tid) == offer
	end
	function offers.offer_given(peer, tid)
		if peer == 1 and tid == id then pending = nil end
	end
	H.env.coop_quests_offer = offers

	C.env.coop.send_event("coop_tq", "op=sgive;i=s" .. id .. ";g=n" .. giver, 0)
	pump()
	check(H.tm.task_info[id] ~= nil and prepared_with_offer == true, "the host prepares the given task with the player's offer still available")
	check(offers.offers_of(1, id) == nil, "the give spends the offer after preparing the task")

	H.tm.task_info[id], H.engine_tasks[id], C.tm.task_info[id] = nil, nil, nil
	H.env.coop_quests_offer, ti.section_exist = nil, known
end

print("== Coop: every group reward is rolled before it leaves the host")
do
	local host = machine("host", 0)
	local env = host.env
	local guest = host.new_obj(500)
	local absent = { id = 501 }
	host.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, avatar_id = 500 } }
	env.coop.members = function() return { { id = 500, peer = 1, in_world = true }, { id = absent.id } } end
	env.alife_object = function(id) if id == absent.id then return absent end end
	env.get_console = function()
		return { get_integer = function(_, name) return name == "coop_share_rewards" and 3 or 0 end }
	end
	env.ini_sys = {
		r_bool_ex = function() return false end,
		r_float_ex = function(_, section, key) if section == "bandage_pack" and key == "max_uses" then return 3 end end,
	}
	local draws, rolls, staged = 0, {}, {}
	env.math = setmetatable({ random = function(lo, hi)
		assert(lo == 1 and hi == 3)
		draws = draws + 1
		return draws
	end }, { __index = math })
	local create = env.alife_create_item
	local offline_item, offline_id = nil, 7000
	local processor = { Uses = {}, Cond = {}, Ammo = {}, Remove = {} }
	env.device = function() return { frame = 1 } end
	env.itms_manager = {
		get_item_processor = function() return processor end,
		create_item = function(sec, owner)
			if owner == absent then
				offline_id = offline_id + 1
				offline_item = { id = offline_id, parent = owner.id, section = sec }
				return offline_item
			end
			local item = create(sec, owner)
			return item and { id = item:id() }
		end,
		process_item = function(_, id, state) processor.Uses[id], rolls[id] = state.uses, state.uses end,
		-- The stock relocate effect counts the requested amount as uses and sets the last partial kit after create.
		relocate_item_to_actor = function(actor, _, sec, amount)
			local se = env.alife_create_item(sec, actor)
			env.itms_manager.process_item(sec, se.id, { uses = amount })
		end,
	}
	env.coop.items = { set_initial = function(id, state)
		assert(offline_item and id == offline_item.id)
		staged[id] = state.uses
		return true
	end }
	env.alife_create_item = function(...) return env.itms_manager.create_item(...) end
	env.alife_process_item = function(...) return env.itms_manager.process_item(...) end
	-- The stock reward_item makes one entity and then rolls the uses on the entity returned to it.
	env.xr_effects.reward_item = function(actor, _, p)
		local se = env.alife_create_item(p[1], actor)
		if se then env.alife_process_item(p[1], se.id, { uses = env.math.random(1, 3) }) end
	end
	host.load("coop_reward_group")
	host.load("coop_item_entity_state").on_game_start()
	host.mod.on_game_start()
	host.tm.task_info.fetch_1 = { id = "fetch_1" }
	host.on_complete.fetch_1 = function() env.xr_effects.reward_item(host.actor, nil, { "bandage_pack" }) end
	env.task_manager.task_callback({ get_id = function() return "fetch_1" end }, env.task.completed)
	local a, b = host.actor._inv[1], guest._inv[1]
	check(a and b and a:section() == "bandage_pack" and b:section() == "bandage_pack",
		"the host and the other group member each get one reward copy")
	check(a and b and rolls[a:id()] and rolls[b:id()] and rolls[a:id()] ~= rolls[b:id()] and draws == 3,
		"the stock reward rolls once for each copy, including copies it never gets back")
	check(offline_item and offline_item.parent == 501 and offline_item.section == "bandage_pack"
		and staged[offline_item.id] == rolls[offline_item.id] and staged[offline_item.id] ~= nil
		and processor.Uses[offline_item.id] == nil,
		"the absent member's copy has its own staged uses before the task callback returns")

	host.tm.task_info.fetch_1 = { id = "fetch_1" }
	host.on_complete.fetch_1 = function()
		env.itms_manager.relocate_item_to_actor(host.actor, nil, "bandage_pack", 2)
	end
	env.task_manager.task_callback({ get_id = function() return "fetch_1" end }, env.task.completed)
	a, b = host.actor._inv[2], guest._inv[2]
	check(a and b and rolls[a:id()] == 2 and rolls[b:id()] == 2 and staged[offline_item.id] == 2 and draws == 3,
		"an explicitly apportioned stock reward gives the requested uses to every group member")

	-- Dev 58 Lua fix: a plain alife_create_item at a task's end (no stock reward effect around it) is made as stock makes
	-- that one item, unrolled, and so is every copy
	host.tm.task_info.fetch_1 = { id = "fetch_1" }
	host.on_complete.fetch_1 = function() env.alife_create_item("bandage_pack", host.actor) end
	env.task_manager.task_callback({ get_id = function() return "fetch_1" end }, env.task.completed)
	a, b = host.actor._inv[3], guest._inv[3]
	check(a and b and a:section() == "bandage_pack" and b:section() == "bandage_pack" and rolls[a:id()] == nil
		and rolls[b:id()] == nil and draws == 3, "a plain create at a task's end rolls no copy: the stock path rolls none")
	-- a story share (coop_quests_story share_reward -> give_to_peer) is rolled only when the stock effect that made it rolls
	local held = #guest._inv
	host.env.coop_tasks_items.give_to_peer(1, 0, { "bandage_pack" }, "give_actor")
	local given = guest._inv[held + 1]
	check(given and given:section() == "bandage_pack" and rolls[given:id()] == nil and draws == 3,
		"a client's copy of a give_actor share is made as stock makes it: no roll")
	host.env.coop_tasks_items.give_to_peer(1, 0, { "bandage_pack" }, "reward_item")
	given = guest._inv[held + 2]
	check(given and rolls[given:id()] ~= nil and draws == 4, "a client's copy of a reward_item share gets the stock roll")
end

-- ---------------------------------------------------------------- single player untouched
print("== no session")
H.env.coop.is_active = function() return false end
local before = H.on_init.fetch_1
H.tm:give_task("fetch_1", 1)
check(H.on_init.fetch_1 == before + 1, "single player: give runs normally")
H.env.coop.is_active = function() return true end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
