-- Anomaly Coop temp test harness: minimal stand-ins for the engine/Anomaly globals coop_main uses.
-- Not shipped. MODE must be set ("client" / "host") before dofile.
ROOT = "gamedata/"
LOG = {}
function printf(fmt, ...)
	local line = string.format(fmt, ...)
	LOG[#LOG + 1] = line
	print(line)
end

-- clock
NOW = 100000
function time_global() return NOW end

-- coop engine API
SENT = {}
coop = {
	is_active = function() return true end,
	is_host = function() return MODE == "host" end,
	is_client = function() return MODE == "client" end,
	is_live = function() return true end,
	self_id = function() return MODE == "host" and 0 or 1 end,
	players = function()
		return {
			{ id = 0, nick = "host", is_self = MODE == "host", avatar_id = MODE == "host" and 0 or 500, rtt = 0 },
			{ id = 1, nick = "client", is_self = MODE == "client", avatar_id = MODE == "client" and 0 or 500, rtt = 12 },
		}
	end,
	send_event = function(name, payload, target)
		SENT[#SENT + 1] = { name = name, payload = payload, target = target }
		return true
	end,
	send_chat = function() return true end,
}

-- axr_main core, same structure as the shipped one (local intercepts + next_index, priority order)
axr_main = {}
do
	local intercepts = {
		actor_on_update = {}, on_before_save_input = {}, on_before_load_input = {}, load_state = {},
		squad_on_update = {}, on_key_press = {}, actor_on_interaction = {},
	}
	local next_index = {}
	for k in pairs(intercepts) do next_index[k] = 1 end
	function axr_main.callback_add(name)
		if not intercepts[name] then
			intercepts[name] = {}
			next_index[name] = 1
		else
			print("callback_add: exists " .. name)
		end
	end
	function axr_main.callback_set(name, f)
		if f == nil then return end
		if intercepts[name] then
			intercepts[name][f] = next_index[name]
			next_index[name] = next_index[name] + 1
		else
			print("callback_set: no callback " .. name)
		end
	end
	function axr_main.callback_unset(name, f)
		if intercepts[name] then intercepts[name][f] = nil end
	end
	function axr_main.make_callback(name, ...)
		local t = intercepts[name]
		if not t then return end
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return t[a] < t[b] end)
		for _, fu in ipairs(keys) do
			if t[fu] then
				if type(fu) == "function" then
					fu(...)
				elseif fu[name] then
					fu[name](fu, ...)
				end
			end
		end
	end
	function axr_main.count(name)
		local n = 0
		for _ in pairs(intercepts[name] or {}) do n = n + 1 end
		return n
	end
end
function RegisterScriptCallback(n, f) axr_main.callback_set(n, f) end
function UnregisterScriptCallback(n, f) axr_main.callback_unset(n, f) end
function SendScriptCallback(n, ...) axr_main.make_callback(n, ...) end
function AddScriptCallback(n) axr_main.callback_add(n) end

-- unique calls / time events
UNIQUE = {}
function AddUniqueCall(f) UNIQUE[#UNIQUE + 1] = f end
function RemoveUniqueCall(f)
	for i = #UNIQUE, 1, -1 do if UNIQUE[i] == f then table.remove(UNIQUE, i) end end
end
TIMEEV = {}
function CreateTimeEvent(ev, act, timer, f, ...) TIMEEV[#TIMEEV + 1] = { f = f, p = { ... } } end

-- ini_file over the real LTX
function ini_file(name)
	local data = {}
	local fh = io.open(ROOT .. "configs/" .. name, "r")
	if fh then
		local cur
		for line in fh:lines() do
			line = line:gsub(";.*$", "")
			local sec = line:match("^%s*%[([^%]]+)%]")
			if sec then
				cur = { keys = {}, vals = {} }
				data[sec] = cur
			elseif cur then
				local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
				if not k then
					k = line:match("^%s*(.-)%s*$")
					v = ""
				end
				if k and k ~= "" then
					cur.keys[#cur.keys + 1] = k
					cur.vals[k] = v
				end
			end
		end
		fh:close()
	end
	local o = {}
	function o:section_exist(s) return data[s] ~= nil end
	function o:line_count(s) return data[s] and #data[s].keys or 0 end
	function o:r_line(s, i) local d = data[s]; local k = d.keys[i + 1]; return true, k, d.vals[k] end
	function o:line_exist(s, k) return data[s] ~= nil and data[s].vals[k] ~= nil end
	function o:r_string(s, k) return data[s].vals[k] end
	return o
end

-- world
_EVENT = {}
function GetEvent(k) return _EVENT[k] end
function SetEvent(k, v) _EVENT[k] = v end
VARS = {}
function load_var(obj, k, def) local v = VARS[k]; if v == nil then return def end return v end
AC_ID = 0
actor_menu = { set_msg = function(t, text) MSG = text end }
KILLED = 0
NEWS = {}
db = {
	actor = {
		alive = function() return KILLED == 0 end,
		kill = function() KILLED = KILLED + 1 end,
		give_game_news = function(self, cap, text) NEWS[#NEWS + 1] = cap .. ": " .. text end,
	},
}
TF = 6
GAME_MS = 1000000
local CTimeMT = {}
CTimeMT.__index = CTimeMT
function CTimeMT:setHMSms(h, m, s, ms) self.ms = ((h * 60 + m) * 60 + s) * 1000 + ms end
function CTimeMT:sub(o) self.ms = self.ms - o.ms end
function CTimeMT:diffSec(o) return (self.ms - o.ms) / 1000 end
game = {
	CTime = function() return setmetatable({ ms = 0 }, CTimeMT) end,
	get_game_time = function() return setmetatable({ ms = GAME_MS }, CTimeMT) end,
}
PROXY_POS = { x = 1 }
level = {
	get_time_factor = function() return TF end,
	set_time_factor = function(v) TF = v end,
	object_by_id = function(id)
		if id == 500 then return { position = function() return PROXY_POS end, alive = function() return true end } end
	end,
}

-- surge / psi managers: plain "classes" (method lookup through the class table, like luabind)
local function class(name)
	local c = {}
	c.__index = c
	return c
end
CSurge = class()
SURGE_LOG = {}
function CSurge:update() SURGE_LOG[#SURGE_LOG + 1] = { cover = GetEvent("current_safe_cover"), inited = self.inited_time.ms } ; self:kill_objects_at_pos(); self:kill_all_unhided() end
function CSurge:initialize() self.surge_time = 222 end
function CSurge:finalize() end
function CSurge:end_surge() self.started = false; SURGE_ENDED = (SURGE_ENDED or 0) + 1; self:kill_all_unhided() end
function CSurge:kill_objects_at_pos() NPC_KILLS = (NPC_KILLS or 0) + 1 end
function CSurge:kill_all_unhided() ORIG_KILL_ALL = (ORIG_KILL_ALL or 0) + 1 end
function CSurge:kill_actor_at_pos() end
function CSurge:kill_crows_at_pos() end
function CSurge:launch_rockets() ROCKETS_LAUNCHED = (ROCKETS_LAUNCHED or 0) + 1 end
function CSurge:pos_in_cover(pos) return pos.cover == true end
function CSurge:init_surge_covers() end
local surge_instance = setmetatable({ _state_loaded = true, started = false }, CSurge)
surge_manager = { CSurgeManager = CSurge, get_surge_manager = function() return surge_instance end }
CPsi = class()
function CPsi:update() end
function CPsi:initialize() end
function CPsi:finish() self.started = false end
function CPsi:launch_rockets() ROCKETS_LAUNCHED = (ROCKETS_LAUNCHED or 0) + 1 end
local psi_instance = setmetatable({ _state_loaded = true, started = false }, CPsi)
psi_storm_manager = { CPsiStormManager = CPsi, get_psi_storm_manager = function() return psi_instance end }
ui_main_menu = { main_menu = { OnButton_save_clicked = function() SAVED_DIALOG = true end } }
ui_debug_launcher = { start_debug_main = function() DEBUG_OPENED = true end }
DEV_DEBUG = true

-- a function defined in a given script file (debug.getinfo source)
function from_script(script, body)
	local f = assert(loadstring(body, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. script .. ".script"))
	return f()
end

-- loads gamedata\scripts\<name>.script the way CScriptStorage does (file_header_old); returns the module
function load_script_file(name)
	local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "r"))
	local src = fh:read("*a")
	fh:close()
	local header = 'local function script_name() return "' .. name .. '" end local this = {} ' .. name ..
		' = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	local f = assert(loadstring(header .. src, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. name .. ".script"))
	f()
	return rawget(_G, name)
end

-- loads coop_main; first the router shim it installs (coop_route: the engine loads a script on its first use, this
-- harness has no such lookup)
function load_coop_main()
	load_script_file("coop_route")
	load_script_file("coop_main")
end

FAILS, PASSES = 0, 0
function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		print("  FAIL " .. what)
		FAILS = FAILS + 1
	end
end

-- Optional stand-ins live in stubs.d/*.lua, one topic per file, loaded in alphabetical order (the working directory
-- is the repository root, as for every test).
do
	local BS = string.char(92)
	local pipe = assert(io.popen("dir /b /on tests" .. BS .. "lua" .. BS .. "support" .. BS .. "stubs.d" .. BS .. "*.lua 2>nul"))
	for line in pipe:lines() do
		line = line:gsub("\r", "")
		if line:match("%.lua$") then dofile("tests/lua/support/stubs.d/" .. line) end
	end
	pipe:close()
end
