-- Anomaly Coop W4 "quests" temp test harness: host + client machines with stubbed Anomaly/engine APIs,
-- coop_tasks.script and coop_quests_*.script loaded like CScriptStorage modules. Not shipped.
local SCRIPTS = "gamedata/scripts/"
dofile("tests/lua/support/stubs.d/money.lua") -- install_money_stubs: coop.money_* of the host ledger (F2 T1)

H = {}
FAILS, PASSES = 0, 0
function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

NOW = 100000
QUEUE = {}
MACHINES = {}
local next_id = 2000

-- ------------------------------------------------------------------ vectors
local VecMT = {}
VecMT.__index = VecMT
function vec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VecMT) end
function VecMT:set(a, b, c)
	if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z else self.x, self.y, self.z = a, b, c end
	return self
end
function VecMT:distance_to_sqr(o) local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z return dx * dx + dy * dy + dz * dz end
function VecMT:distance_to(o) return math.sqrt(self:distance_to_sqr(o)) end

-- ------------------------------------------------------------------ simple flat codec (coop_main copy)
local function esc(s) return (tostring(s):gsub("[%%;=]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function encode(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = tostring(k) end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		local v = t[k]
		local s = type(v) == "number" and ("n" .. tostring(v)) or type(v) == "boolean" and (v and "b1" or "b0") or ("s" .. tostring(v))
		out[#out + 1] = esc(k) .. "=" .. esc(s)
	end
	return table.concat(out, ";")
end
local function decode(str)
	local t = {}
	if type(str) ~= "string" then return t end
	for pair in str:gmatch("[^;]+") do
		local k, v = pair:match("^([^=]*)=(.*)$")
		if k then
			k, v = unesc(k), unesc(v)
			local tag, body = v:sub(1, 1), v:sub(2)
			if tag == "n" then t[k] = tonumber(body) elseif tag == "b" then t[k] = body == "1" else t[k] = body end
		end
	end
	return t
end

-- ------------------------------------------------------------------ one machine
function machine(role, self_peer)
	local M = { role = role, self_peer = self_peer, log = {}, handlers = {}, sent = {}, callbacks = {}, timers = {} }
	local env = setmetatable({}, { __index = _G })
	env._G = env
	M.env = env
	M.active = true

	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if VERBOSE then print("    [" .. role .. "] " .. line) end
	end
	env.printe = env.printf
	function env.time_global() return NOW end
	env.strformat = string.format
	env.empty_table = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.unpack = unpack

	-- objects
	local objects = {}
	M.objects = objects
	local ObjMT = {}
	ObjMT.__index = ObjMT
	-- luabind: game_object has no ==; two different objects raise (live 2026-10-24, coop_mods_core as_player)
	ObjMT.__eq = function() error("No such operator __eq defined in class [game_object]", 2) end
	M.ObjMT = ObjMT
	function ObjMT:id() return self._id end
	function ObjMT:section() return self._sec end
	function ObjMT:name() return self._name or self._sec end
	function ObjMT:position() return self._pos end
	function ObjMT:level_vertex_id() return self._lv or 1 end
	function ObjMT:game_vertex_id() return self._gv or 1 end
	function ObjMT:alive() return self._dead ~= true end
	function ObjMT:condition() return self._cond or 1 end
	function ObjMT:get_remaining_uses() return self._uses or 1 end
	function ObjMT:parent() return self._parent end
	function ObjMT:clsid() return self._cls or 1 end
	function ObjMT:iterate_inventory(f, x)
		local copy = {}
		for _, it in ipairs(self._inv) do copy[#copy + 1] = it end
		for _, it in ipairs(copy) do if f(x, it) == true then return end end
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
				return
			end
		end
	end
	function ObjMT:give_money(n) self._money = (self._money or 0) + n end
	function ObjMT:is_talking() return M.talking == true end
	function ObjMT:give_talk_message2(c, t, i, p) M.talk_msgs = M.talk_msgs or {} M.talk_msgs[#M.talk_msgs + 1] = { c, t, i, p } end
	function ObjMT:give_game_news(...) M.game_news = (M.game_news or 0) + 1 end
	function ObjMT:get_task(id, active_only)
		local t = M.engine_tasks[id]
		if not t then return nil end
		if active_only and t.state ~= "in" then return nil end
		return t
	end
	function ObjMT:active_detector() return self._detector end
	function ObjMT:character_name() return self._cname or ("name_" .. self._id) end
	function ObjMT:character_rank() return self._rank or 0 end
	function ObjMT:character_community() return self._comm or "stalker" end
	function ObjMT:character_reputation() return self._rep or 0 end
	function ObjMT:character_icon() return "icon_" .. self._id end
	function ObjMT:give_info_portion(i) M.infos[i] = true end
	function ObjMT:disable_info_portion(i) M.infos[i] = nil end

	function M.new_obj(id, sec, pos, opts)
		local o = setmetatable({ _id = id, _sec = sec or "obj", _inv = {}, _money = 0, _pos = pos or vec(0, 0, 0) }, ObjMT)
		for k, v in pairs(opts or {}) do o[k] = v end
		objects[id] = o
		return o
	end
	function M.give_item(owner, sec, opts)
		next_id = next_id + 1
		local it = M.new_obj(next_id, sec, owner._pos, opts)
		it._parent = owner
		owner._inv[#owner._inv + 1] = it
		return it
	end
	function M.count(owner, sec)
		local n = 0
		for _, it in ipairs(owner._inv) do if it._sec == sec then n = n + 1 end end
		return n
	end
	M.engine_tasks = {}
	M.infos = {}

	local actor = M.new_obj(0, "actor", vec(0, 0, 0))
	M.actor = actor
	env.AC_ID = 0
	env.db = { actor = actor, storage = { [0] = { pstor = {}, object = actor } } }
	env.level = {
		object_by_id = function(id) return objects[id] end,
		name = function() return "l01_escape" end,
		map_has_object_spot = function() return 0 end,
		change_game_time = function(d, h, m) M.time_jumps = (M.time_jumps or 0) + 1 end,
	}
	function env.alife_object(id)
		local o = objects[id]
		if not o then return nil end
		return {
			id = id, parent_id = o._parent and o._parent._id or 65535, position = o._pos, group_id = o._group or 65535,
			commander_id = function() return o._commander end,
			stay_time = nil, _o = o,
		}
	end
	function env.alife_release_id(id)
		local o = objects[id]
		if o and o._parent then
			for i, it in ipairs(o._parent._inv) do if it == o then table.remove(o._parent._inv, i) break end end
		end
		objects[id] = nil
		M.released = (M.released or 0) + 1
	end
	function env.alife_create_item(sec, obj)
		local owner = obj
		if type(obj) == "table" and type(obj.id) == "function" then owner = objects[obj:id()] end
		M.created = M.created or {}
		M.created[#M.created + 1] = { sec = sec, owner = owner and owner._id }
		if owner and owner._inv then return M.give_item(owner, sec) end
	end
	function env.alife_create(sec, pos)
		M.world_spawns = M.world_spawns or {}
		M.world_spawns[#M.world_spawns + 1] = sec
		next_id = next_id + 1
		return M.new_obj(next_id, sec, pos)
	end
	function env.IsStalker(o) return type(o) == "table" and o._stalker == true end
	function env.IsInvbox(o) return type(o) == "table" and o._box == true end
	function env.IsItem(kind, sec) return nil end
	env.ini_sys = { section_exist = function(_, s) return type(s) == "string" end }
	function env.load_var(obj, k, def)
		local st = env.db.storage[obj:id()]
		local v = st and st.pstor and st.pstor[k]
		if v == nil then return def end
		return v
	end
	function env.save_var(obj, k, v)
		local st = env.db.storage[obj:id()]
		st.pstor = st.pstor or {}
		st.pstor[k] = v
	end
	M.se_vars = {}
	function env.se_load_var(id, name, k) return M.se_vars[id] and M.se_vars[id][k] end
	function env.se_save_var(id, name, k, v) M.se_vars[id] = M.se_vars[id] or {} M.se_vars[id][k] = v end
	function env.has_alife_info(i) return M.infos[i] == true end
	env.EVENTS = {}
	function env.GetEvent(k) return env.EVENTS[k] end
	function env.SetEvent(k, v) env.EVENTS[k] = v end
	function env.get_speaker() return M.original_speaker end
	function env.get_story_se_item(sec)
		for id, o in pairs(objects) do if o._sec == sec then return env.alife_object(id) end end
	end
	env.game = { translate_string = function(s) return "T(" .. tostring(s) .. ")" end, get_game_time = function() return NOW end }
	env.ui_item = { get_sec_name = function(s) return "N(" .. s .. ")" end }
	env.vector = function() return vec() end
	env.SIMBOARD = { smarts_by_names = {} }
	env.sim_offline_combat = { task_squads = {} }
	env.get_console = function() return { get_integer = function() return 0 end } end

	-- callbacks, time events
	env.RegisterScriptCallback = function(name, f)
		M.callbacks[name] = M.callbacks[name] or {}
		table.insert(M.callbacks[name], f)
	end
	env.SendScriptCallback = function(name, ...)
		for _, f in ipairs(M.callbacks[name] or {}) do f(...) end
	end
	env.CreateTimeEvent = function(ev, act, t, f, ...)
		M.timers[#M.timers + 1] = { f = f, p = { ... }, ev = ev, act = act, t = t }
	end
	M.real_cte = env.CreateTimeEvent

	-- coop engine API
	env.coop = {
		is_active = function() return M.active end,
		is_host = function() return role == "host" end,
		is_client = function() return role == "client" end,
		is_live = function() return true end,
		self_id = function() return self_peer end,
		players = function() return M.players end,
		avatar_of = function(peer) for _, p in ipairs(M.players) do if p.id == peer then return p.avatar_id end end end,
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
		add_event_handler = function(name, f) M.handlers[name] = f return true end,
		encode = encode, decode = decode,
	}

	-- news, money
	M.news, M.money_news = {}, {}
	env.news_manager = {
		relocate_item = function(a, typ, sec, n) M.news[#M.news + 1] = typ .. ":" .. sec .. "x" .. tostring(n) return true end,
		relocate_money = function(a, typ, n) M.money_news[#M.money_news + 1] = typ .. ":" .. n end,
		send_task = function() end,
	}
	env.dialogs = {
		relocate_money = function(victim, n, typ)
			if typ == "in" then actor:give_money(n) end
			env.news_manager.relocate_money(actor, typ, n)
		end,
		who_is_npc = function(a, b) return M.talk_npc end,
	}
	env.dialogs.text_npc_has_task = function(a, b)
		M.local_text = (M.local_text or 0) + 1
		return "LOCAL TEXT"
	end
	env.dialogs_mlr = { show_goodwill_change_message = function() end }
	env.task = { completed = 2, fail = 0 }

	-- task manager with a luabind-like class
	local ini_data = {}
	M.ini = ini_data
	env.task_manager = {
		task_ini = {
			section_exist = function(_, id) return ini_data[id] ~= nil end,
			r_string_ex = function(_, id, key) return ini_data[id] and ini_data[id][key] end,
		},
	}
	local CRandomTask = {}
	CRandomTask.__index = CRandomTask
	M.on_init = {}
	function CRandomTask:give_task(id, giver)
		M.on_init[id] = (M.on_init[id] or 0) + 1
		local t = setmetatable({ id = id, stage = 0, status = "selected", task_giver_id = giver,
			status_functor = ini_data[id] and ini_data[id].status_functor }, env.task_objects.CGeneralTask)
		self.task_info[id] = t
		M.engine_tasks[id] = { state = "in", get_id = function() return id end }
	end
	function CRandomTask:set_task_completed(id) if self.task_info[id] then self.task_info[id].forced_status = "complete" end end
	function CRandomTask:set_task_failed(id) if self.task_info[id] then self.task_info[id].forced_status = "fail" end end
	function CRandomTask:set_task_cancelled(id) if self.task_info[id] then self.task_info[id].forced_status = "fail" end end
	function CRandomTask:update()
		for id, t in pairs(self.task_info) do t:check_task(self) end
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
	env.task_manager.CRandomTask = CRandomTask
	env.task_manager.get_task_manager = function() return tm_instance end
	env.task_manager.task_complete = function(id) return tm_instance:task_complete(id) end
	env.task_manager.task_fail = function(id) return tm_instance:task_fail(id) end
	env.task_manager.task_callback = function(tsk, state)
		local id = tsk:get_id()
		local rt = tm_instance.task_info[id]
		if not rt then return end
		if state == env.task.completed then
			if M.on_complete and M.on_complete[id] then M.on_complete[id]() end
			tm_instance.task_info[id] = nil
		else
			tm_instance.task_info[id] = nil
		end
	end
	M.tm = tm_instance

	local CGeneralTask = {}
	CGeneralTask.__index = CGeneralTask
	function CGeneralTask:check_task(tm)
		M.checks = (M.checks or 0) + 1
		local f = self.status_functor and env.task_status_functor[self.status_functor]
		if f then f(self, self.id) end
	end
	env.task_objects = { CGeneralTask = CGeneralTask }
	env.task_status_functor = {}
	env.task_functor = {}

	-- logic
	env.xr_logic = {
		parse_condlist = function(npc, sec, field, src) return { src = src } end,
		pick_section_from_condlist = function(a, b, cond)
			-- "%=name(p1:p2)%" effects, run in order
			for name, args in tostring(cond.src):gmatch("=([%w_]+)%(?([^%)%%]*)%)?") do
				local p = {}
				for x in args:gmatch("[^:]+") do p[#p + 1] = x end
				local f = env.xr_effects[name]
				if f then f(a, b, p) end
			end
			return nil
		end,
	}
	env.xr_effects = {}
	env.xr_conditions = {
		actor_has_item = function(actor_, npc, p) return p[1] ~= nil and env.db.actor:object(p[1]) ~= nil end,
	}
	env.utils_item = {
		has_item_by_id = function(npc, id, sec)
			local o = id and objects[id]
			local pr = o and o._parent
			return pr ~= nil and pr._id == ((npc and npc:id()) or 0) and (not sec or o._sec == sec)
		end,
	}
	env.mob_trade = { GetTalkingNpc = function() return M.original_talker end }

	-- axr_task_manager
	env.axr_task_manager = {
		available_tasks = {}, bounties_by_id = {},
		clear_skipped_tasks = function() end,
		generate_available_tasks = function(npc, is_sim)
			M.gen_calls = (M.gen_calls or 0) + 1
			M.gen_talking = env.db.actor:is_talking()
			M.gen_speaker = env.mob_trade.GetTalkingNpc()
			local list = {}
			for _, tid in ipairs(M.npc_tasks and M.npc_tasks[npc:id()] or {}) do
				if tm_instance.task_info[tid] == nil then list[#list + 1] = tid end
			end
			env.axr_task_manager.available_tasks[npc:id()] = list
		end,
		trigger_fetch_func = function(tid)
			local f = ini_data[tid] and ini_data[tid].fetch_func
			if f then env.xr_logic.pick_section_from_condlist(env.db.actor, env.db.actor, { src = f }) end
		end,
	}
	env.tasks_fetch = {
		postpone_fetch_for_next_frame = function(var, sec, cnt)
			env.db.actor:give_talk_message2("needs", sec .. " x" .. tostring(cnt), "ico", "iconed_answer_item")
			return true
		end,
	}

	MACHINES[#MACHINES + 1] = M
	return M
end

-- loads gamedata\scripts\<name>.script into machine M as module <name>
function load_script(M, name)
	local fh = assert(io.open(SCRIPTS .. name .. ".script", "r"))
	local src = fh:read("*a")
	fh:close()
	local f = assert(loadstring(src, "@" .. name .. ".script"))
	local mod = setmetatable({}, { __index = M.env })
	M.env[name] = mod
	setfenv(f, mod)
	f()
	return mod
end

function pump()
	local guard = 0
	while #QUEUE > 0 and guard < 5000 do
		guard = guard + 1
		local e = table.remove(QUEUE, 1)
		local h = e.to.handlers[e.name]
		if h then h(e.payload, e.from, e.name) end
	end
end

function run_timers(M)
	local list = M.timers
	M.timers = {}
	for _, t in ipairs(list) do t.f(unpack(t.p)) end
end

function fire(M, name, ...)
	for _, f in ipairs(M.callbacks[name] or {}) do f(...) end
end

function tick(M)
	NOW = NOW + 600
	fire(M, "actor_on_update")
end

function count_sent(M, name)
	local n = 0
	for _, s in ipairs(M.sent) do if s.name == name then n = n + 1 end end
	return n
end

function last_sent(M, name)
	for i = #M.sent, 1, -1 do if M.sent[i].name == name then return decode(M.sent[i].payload) end end
end

function has_log(M, pat)
	for _, l in ipairs(M.log) do if l:find(pat, 1, true) then return true end end
	return false
end

H.decode = decode
H.encode = encode
H.vec = vec
