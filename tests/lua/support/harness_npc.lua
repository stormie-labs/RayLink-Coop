-- Anomaly Coop W4 "npc" temp test harness (not shipped): a small fake engine with two machines.
-- Each machine gets its own global environment; scripts load like CScriptStorage does (module table,
-- __index to the machine environment). Events are queued and delivered by pump().
ROOT = "gamedata/"

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

-- ---------------------------------------------------------------- vectors
local V = {}
V.__index = V
function vector() return setmetatable({ x = 0, y = 0, z = 0 }, V) end
function V:set(x, y, z)
	if type(x) == "table" then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x, y, z end
	return self
end
function V:distance_to_sqr(o) local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z return dx * dx + dy * dy + dz * dz end
function V:distance_to(o) return math.sqrt(self:distance_to_sqr(o)) end
function vec(x, y, z) return vector():set(x, y or 0, z or 0) end

-- ---------------------------------------------------------------- game objects
local O = {}
O.__index = O
function O:id() return self._id end
function O:position() return self._pos end
function O:alive() return self._alive ~= false end
function O:see(o) return self._sees[o:id()] == true end
function O:name() return self._name or ("obj" .. self._id) end
function O:section() return self._section or "stalker" end
function O:character_community() return self._comm or "stalker" end
function O:has_info(i) return self._info[i] == true end
function O:give_info_portion(i) self._info[i] = true end
function O:disable_info_portion(i) self._info[i] = nil end
function O:active_item() return self._active end
function O:object(sec) for _, it in ipairs(self._inv) do if it._section == sec then return it end end end
function O:enable_talk() self._talk = true end
function O:disable_talk() self._talk = false end
function O:is_talk_enabled() return self._talk == true end
function O:enable_trade() self._trade = true end
function O:disable_trade() self._trade = false end
function O:set_tip_text(t) self._tip = t end
function O:is_talking() return self._talking == true end
function O:set_start_dialog(d) self._dialog = d end
function O:restore_default_start_dialog() self._dialog = "" end
function O:relation(o) return (self._rel and self._rel[o:id()]) or 1 end
function O:best_enemy() return self._enemy end
function O:inside(pos) return self._radius ~= nil and self._pos:distance_to(pos) <= self._radius end
function O:explode() self._exploded = true end
function O:character_name() return "Name" .. self._id end
function O:character_icon() return "icon" end
function O:level_vertex_id() return 7 end
function O:game_vertex_id() return 8 end
function O:hit(h) self._hits = self._hits or {}; self._hits[#self._hits + 1] = h end
function O:kill() self._alive = false; self._killed = true end
function O:set_actor_position(p) self._pos = vector():set(p) end
function O:spawn_ini() return self._spawn_ini end
function O:parent() return self._parent end

function make_obj(id, x, y, z, extra)
	local o = setmetatable({ _id = id, _pos = vec(x, y, z), _sees = {}, _info = {}, _inv = {}, health = 1 }, O)
	for k, v in pairs(extra or {}) do o[k] = v end
	return o
end

-- ---------------------------------------------------------------- ini from a table: { sec = { {key, value}, ... } }
function make_ini(t)
	local o = { _t = t }
	function o:section_exist(s) return self._t[s] ~= nil end
	function o:line_count(s) return self._t[s] and #self._t[s] or 0 end
	function o:r_line(s, i) local l = self._t[s][i + 1]; return true, l[1], l[2] end
	function o:line_exist(s, k) for _, l in ipairs(self._t[s] or {}) do if l[1] == k then return true end end return false end
	function o:r_string_ex(s, k) for _, l in ipairs(self._t[s] or {}) do if l[1] == k then return l[2] end end end
	function o:r_string(s, k) return self:r_string_ex(s, k) end
	function o:r_float_ex(s, k) local v = self:r_string_ex(s, k) return v and tonumber(v) end
	function o:section_for_each(f)
		local names = {}
		for k in pairs(self._t) do names[#names + 1] = k end
		table.sort(names)
		for _, n in ipairs(names) do
			local r = f(n)
			assert(type(r) == "boolean", "section_for_each functor must return a boolean")
			if r then return end
		end
	end
	return o
end

-- ini_file over a real LTX in gamedata\configs
function real_ini(name)
	local data = {}
	local fh = io.open(ROOT .. "configs/" .. name, "r")
	if fh then
		local cur
		for line in fh:lines() do
			line = line:gsub(";.*$", "")
			local sec = line:match("^%s*%[([^%]]+)%]")
			if sec then
				cur = {}
				data[sec] = cur
			elseif cur then
				local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
				if not k then k, v = line:match("^%s*(.-)%s*$"), "" end
				if k and k ~= "" then cur[#cur + 1] = { k, v } end
			end
		end
		fh:close()
	end
	return make_ini(data)
end

-- ---------------------------------------------------------------- machines
MACHINES = {}

-- role: "host" | "client" | "single"; peer: own peer id; avatars: { [peer] = local avatar id }
function machine(role, peer, avatars)
	local M = { role = role, peer = peer, log = {}, sent = {}, handlers = {}, objects = {}, callbacks = {} }
	local E = setmetatable({}, { __index = _G })
	E._G = E
	M.env = E
	MACHINES[peer] = M

	E.printf = function(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		M.log[#M.log + 1] = ok and line or fmt
	end
	E.time_global = function() return NOW end
	E.AC_ID = 0
	E.db = { storage = {}, zone_by_name = {}, actor_inside_zones = {}, OnlineStalkers = {} }

	-- objects
	function M.add(o)
		M.objects[o:id()] = o
		return o
	end
	E.level = {
		object_by_id = function(id) return M.objects[id] end,
		name = function() return "l01_escape" end,
		get_time_factor = function() return 6 end,
		get_start_time = function() return E.game.get_game_time() end,
		add_cam_effector = function(path, id, loop, cb, fov) M.cam = { path, id, loop, cb, fov } end,
		remove_cam_effector = function(id) M.cam_removed = id end,
		add_complex_effector = function(s, id) M.pp = { s, id } end,
		remove_complex_effector = function(id) M.pp_removed = id end,
		enable_input = function() M.input = true end,
		disable_input = function() M.input = false end,
	}
	local actor = M.add(make_obj(0, 0, 0, 0, { _name = "actor", _comm = "actor_stalker" }))
	E.db.actor = actor

	-- coop engine API
	local session = role ~= "single"
	E.coop = {
		is_active = function() return session end,
		is_host = function() return role == "host" end,
		is_client = function() return role == "client" end,
		is_live = function() return true end,
		self_id = function() return peer end,
		players = function()
			if not session then return {} end
			local list = {}
			for p, av in pairs(avatars) do
				list[#list + 1] = { id = p, nick = "p" .. p, is_self = p == peer, avatar_id = (p == peer) and 0 or av, rtt = 1 }
			end
			table.sort(list, function(a, b) return a.id < b.id end)
			return list
		end,
		avatar_of = function(p) if p == peer then return 0 end return avatars[p] end,
		peer_of_avatar = function(id) for p, av in pairs(avatars) do if p ~= peer and av == id then return p end end end,
		to_host_id = function(id) return M.to_host and M.to_host(id) or id end,
		to_local_id = function(id) return M.to_local and M.to_local(id) or id end,
		send_event = function(name, payload, target)
			M.sent[#M.sent + 1] = { name = name, payload = payload, target = target }
			QUEUE[#QUEUE + 1] = { from = peer, name = name, payload = payload, target = target }
			return true
		end,
	}
	function M.set_session(v) session = v end

	-- coop_main stand-in: handlers + flat encode/decode (same format as the real one)
	local function esc(s) return (tostring(s):gsub("[%%;=]", function(c) return string.format("%%%02X", c:byte()) end)) end
	local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
	E.coop_main = {
		add_event_handler = function(name, f)
			M.handlers[name] = M.handlers[name] or {}
			M.handlers[name][#M.handlers[name] + 1] = f
			return true
		end,
		encode = function(t)
			local keys = {}
			for k in pairs(t) do keys[#keys + 1] = tostring(k) end
			table.sort(keys)
			local out = {}
			for _, k in ipairs(keys) do
				local v, s = t[k], nil
				if type(v) == "number" then s = "n" .. tostring(v) elseif type(v) == "boolean" then s = v and "b1" or "b0" else s = "s" .. tostring(v) end
				out[#out + 1] = esc(k) .. "=" .. esc(s)
			end
			return table.concat(out, ";")
		end,
		decode = function(str)
			local t = {}
			for pair in str:gmatch("[^;]+") do
				local k, v = pair:match("^([^=]*)=(.*)$")
				k, v = unesc(k), unesc(v)
				local tag, body = v:sub(1, 1), v:sub(2)
				if tag == "n" then t[k] = tonumber(body) elseif tag == "b" then t[k] = body == "1" else t[k] = body end
			end
			return t
		end,
	}

	-- script callbacks
	E.RegisterScriptCallback = function(name, f)
		M.callbacks[name] = M.callbacks[name] or {}
		M.callbacks[name][#M.callbacks[name] + 1] = f
	end
	E.UnregisterScriptCallback = function() end
	E.AddScriptCallback = function() end
	E.SendScriptCallback = function(name, ...)
		for _, f in ipairs(M.callbacks[name] or {}) do f(...) end
	end
	function M.fire(name, ...) E.SendScriptCallback(name, ...) end
	E.CreateTimeEvent = function(a, b, t, f, ...) M.timers = M.timers or {}; M.timers[#M.timers + 1] = { f = f, p = { ... } } end
	E.ini_file = function(name) return real_ini(name) end
	E.ui_options = { get = function(k) return (M.options or {})[k] end }

	-- pstor
	E.save_var = function(obj, k, v) obj._pstor = obj._pstor or {}; obj._pstor[k] = v end
	E.load_var = function(obj, k, def) local v = obj._pstor and obj._pstor[k]; if v == nil then return def end return v end

	-- game time
	local CT = {}
	CT.__index = CT
	function CT:diffSec(o) return (self.ms - o.ms) / 1000 end
	E.game = { get_game_time = function() return setmetatable({ ms = M.game_ms or 0 }, CT) end, translate_string = function(s) return s end }
	return M
end

function load_script(M, name)
	local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "r"))
	local src = fh:read("*a")
	fh:close()
	local header = "local this = {} " .. name .. " = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. src, "@" .. name .. ".script"))
	setfenv(f, M.env)
	f()
	return M.env[name]
end

-- Delivers queued events: target nil/-1 = everybody else, N = peer N. from = sender peer.
function pump()
	local n = 0
	while #QUEUE > 0 do
		local q = table.remove(QUEUE, 1)
		for p, M in pairs(MACHINES) do
			if p ~= q.from and (q.target == nil or q.target == -1 or q.target == p) then
				for _, f in ipairs(M.handlers[q.name] or {}) do f(q.payload, q.from, q.name) end
				n = n + 1
			end
		end
	end
	return n
end

function reset_world()
	MACHINES, QUEUE = {}, {}
end

function sent_named(M, name)
	local list = {}
	for _, s in ipairs(M.sent) do if s.name == name then list[#list + 1] = s end end
	return list
end
