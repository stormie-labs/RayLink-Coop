-- Anomaly Coop temp test harness for the W4 "mods" scripts (not shipped).
-- Set MODE ("host" / "client" / "sp") before dofile. Scripts load like CScriptStorage does (file_header_old),
-- unknown globals load gamedata\scripts\<name>.script on demand, fake mods are plain tables in _G.
ROOT = "gamedata/"
MODE = MODE or "host"
LOG = {}
VERBOSE = VERBOSE or false
function printf(fmt, ...)
	local ok, line = pcall(string.format, fmt, ...)
	line = ok and line or tostring(fmt)
	LOG[#LOG + 1] = line
	if VERBOSE then print(line) end
end
printe = printf
function log_has(pat)
	for i = #LOG, 1, -1 do if LOG[i]:find(pat, 1, true) then return LOG[i] end end
	return nil
end

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
function time_global() return NOW end
function callstack() end
function bit_or(a, b) return a + b end
function bit_and(a, b) return 0 end
FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
AC_ID = 0
function clamp(v, a, b) return math.max(a, math.min(b, v)) end
function is_empty(t) return next(t) == nil end
_GUIs = {}

-------------------------------------------------------------------------------
-- vectors
-------------------------------------------------------------------------------
local V = {}
V.__index = V
function vector() return setmetatable({ x = 0, y = 0, z = 0 }, V) end
function V:set(x, y, z)
	if type(x) == "table" then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x, y, z end
	return self
end
function V:distance_to_sqr(o) return (self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2 end
function V:distance_to(o) return math.sqrt(self:distance_to_sqr(o)) end
function vec3(x, y, z) return vector():set(x, y, z) end

-------------------------------------------------------------------------------
-- world: server objects SE[id], game objects OBJ[id]
-------------------------------------------------------------------------------
SE, OBJ = {}, {}
NEXT_ID = 1000
RELEASED = {}
INI = {} -- section -> { key = value }

ini_sys = {}
function ini_sys:section_exist(s) return INI[s] ~= nil end
function ini_sys:r_string_ex(s, k, d) local t = INI[s]; local v = t and t[k]; if v == nil then return d end return tostring(v) end
function ini_sys:r_bool_ex(s, k, d) local t = INI[s]; local v = t and t[k]; if v == nil then return d end return v == true or v == "true" end
function ini_sys:r_float_ex(s, k, d) local t = INI[s]; local v = t and tonumber(t[k]); if v == nil then return d end return v end

local GO = {}
GO.__index = GO
function GO:id() return self._id end
function GO:section() return self._sec end
function GO:position() return vector():set(self._pos) end
function GO:direction() return vector():set(0, 0, 1) end
function GO:alive() return self._alive ~= false end
function GO:condition() return self._cond or 1 end
function GO:set_condition(c) self._cond = c end
function GO:level_vertex_id() return 7 end
function GO:game_vertex_id() return 8 end
function GO:parent()
	local se = SE[self._id]
	return se and se.parent_id ~= 65535 and OBJ[se.parent_id] or nil
end
function GO:object(sec)
	for id, se in pairs(SE) do
		if se.parent_id == self._id and se._sec == sec then return OBJ[id] end
	end
end
function GO:is_inv_box_empty()
	for _, se in pairs(SE) do if se.parent_id == self._id then return false end end
	return true
end
function GO:use(who) self._used_by = who end
function GO:kill(who) self._killed = (self._killed or 0) + 1 end
function GO:set_actor_position(p) self._tp = vector():set(p) end
function GO:bone_position() return vector():set(self._pos) end
function GO:get_hanging_lamp() return { is_on = function() return true end } end
function GO:get_physics_shell() return { apply_force = function(_, x, y, z) self._force = { x, y, z } end } end
function GO:give_game_news() end
function GO:explode() self._exploded = true end
function GO:get_ammo_in_magazine() return self._ammo or 0 end
function GO:force_unload_magazine() self._ammo = 0 end
function GO:transfer_item(item, to) SE[item:id()].parent_id = to:id() end
function GO:set_tip_text(t) self._tip = t end
function GO:iterate_inventory(f, o)
	for id, se in pairs(SE) do if se.parent_id == self._id and OBJ[id] then f(o, OBJ[id]) end end
end

local SEM = {}
SEM.__index = SEM
function SEM:section_name() return self._sec end
function SEM:clsid() return 0 end

-- Creates a server object (and its online game object unless offline).
function spawn(sec, pos, parent, opts)
	opts = opts or {}
	local id = opts.id or NEXT_ID
	if not opts.id then NEXT_ID = NEXT_ID + 1 end
	local se = setmetatable({ id = id, _sec = sec, parent_id = parent or 65535, position = vector():set(pos or vec3(0, 0, 0)),
		m_game_vertex_id = 8 }, SEM)
	SE[id] = se
	if not opts.offline then
		OBJ[id] = setmetatable({ _id = id, _sec = sec, _pos = vector():set(pos or vec3(0, 0, 0)), _alive = opts.alive,
			_cond = opts.cond, _kind = opts.kind, health = opts.health or 1 }, GO)
	end
	return se, OBJ[id]
end

function release_id(id)
	if SE[id] then RELEASED[#RELEASED + 1] = { id = id, sec = SE[id]._sec } end
	SE[id], OBJ[id] = nil, nil
end

function alife_object(id) return SE[id] end
function alife()
	return {
		object = function(_, id) return SE[id] end,
		release = function(_, se) release_id(se.id) end,
		level_name = function() return "l01_escape" end,
	}
end
function game_graph() return { vertex = function() return { level_id = function() return 1 end } end } end
CREATED = {}
function alife_create(sec, pos, lv, gv, parent)
	local p = pos
	if type(pos) == "table" and pos._id then p = pos:position() end
	local se = spawn(sec, p, parent)
	CREATED[#CREATED + 1] = { sec = sec, id = se.id, parent = parent }
	return se
end
function alife_create_item(sec, obj, t)
	local se, o = spawn(sec, obj:position(), obj:id())
	if t and t.cond and o then o._cond = t.cond end
	CREATED[#CREATED + 1] = { sec = sec, id = se.id, parent = obj:id(), cond = t and t.cond }
	return se
end
function alife_release_id(id) release_id(id) end
function alife_release(se)
	if type(se.id) == "function" then release_id(se:id()) else release_id(se.id) end
end
function get_object_by_id(id) return OBJ[id] end

function IsStalker(o) return o and o._kind == "stalker" end
function IsMonster(o) return o and o._kind == "monster" end
function IsInvbox(o) return o and o._kind == "box" end
function IsWeapon(o) return o and o._kind == "weapon" end
function IsAmmo(o) return o and o._kind == "ammo" end

level = {
	object_by_id = function(id) return OBJ[id] end,
	iterate_nearest = function(pos, r, f)
		for _, o in pairs(OBJ) do
			if o:position():distance_to_sqr(pos) <= r * r and f(o) then return end
		end
	end,
	name = function() return "l01_escape" end,
	add_cam_effector = function(anm, id) CAMS = (CAMS or 0) + 1 end,
	remove_cam_effector = function(id) CAMS = (CAMS or 0) - 1 end,
	get_time_factor = function() return 6 end,
	set_time_factor = function() end,
}
db = { storage = {} }
function make_actor(pos)
	local se, o = spawn("actor", pos or vec3(0, 0, 0), nil, { id = 0 })
	o._kind = "stalker"
	db.actor = o
	return o
end
game = {
	translate_string = function(s) return s end,
	get_game_time = function() return { diffSec = function() return 0 end } end,
	hud_motion_allowed = function() return true end,
	only_movekeys_allowed = function() return false end,
	world2ui = function() return { x = 500, y = 300 } end,
}
SOUNDS = {}
local SND = {}
SND.__index = SND
function SND:play_at_pos(obj, pos) self._playing = true; SOUNDS[#SOUNDS + 1] = { name = self._name, at = obj and obj:id() } end
function SND:play(obj) self._playing = true; SOUNDS[#SOUNDS + 1] = { name = self._name, at = obj and obj:id() } end
function SND:stop() self._playing = false end
function SND:playing() return self._playing == true end
function SND:length() return 3000 end
sound_object = setmetatable({ s2d = 1, s3d = 2 }, { __call = function(_, name) return setmetatable({ _name = name }, SND) end })
xr_sound = { get_safe_sound_object = function(n) return sound_object(n) end }
actor_menu = { set_msg = function(_, t) HUD = t end }
news_manager = { send_tip = function() end }

-------------------------------------------------------------------------------
-- callbacks (axr_main shape: local intercepts, reachable as an upvalue of callback_set)
-------------------------------------------------------------------------------
axr_main = {}
do
	local intercepts = {}
	local next_index = {}
	for _, k in ipairs({ "actor_on_update", "actor_on_first_update", "on_key_press", "load_state", "save_state",
		"on_before_save_input", "on_before_load_input", "npc_on_before_hit", "monster_on_before_hit",
		"ActorMenu_on_item_drag_drop", "actor_on_item_take", "npc_on_use", "on_option_change" }) do
		intercepts[k] = {}
		next_index[k] = 1
	end
	function axr_main.callback_add(name)
		if not intercepts[name] then intercepts[name] = {}; next_index[name] = 1 end
	end
	function axr_main.callback_set(name, f)
		if f == nil then return end
		if intercepts[name] then
			intercepts[name][f] = next_index[name]
			next_index[name] = next_index[name] + 1
		else
			printf("callback_set: no callback %s", name)
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
				if type(fu) == "function" then fu(...) elseif fu[name] then fu[name](fu, ...) end
			end
		end
	end
	function axr_main.count(name)
		local n = 0
		for _ in pairs(intercepts[name] or {}) do n = n + 1 end
		return n
	end
	function axr_main.has(name, f) return intercepts[name] and intercepts[name][f] ~= nil end
end
function RegisterScriptCallback(n, f) axr_main.callback_set(n, f) end
function UnregisterScriptCallback(n, f) axr_main.callback_unset(n, f) end
function SendScriptCallback(n, ...) axr_main.make_callback(n, ...) end
function AddScriptCallback(n) axr_main.callback_add(n) end

TIMEEV = {}
function CreateTimeEvent(ev, act, timer, f, ...)
	TIMEEV[tostring(ev) .. ":" .. tostring(act)] = { f = f, p = { ... }, at = NOW + (timer or 0) * 1000 }
end
function RemoveTimeEvent(ev, act) TIMEEV[tostring(ev) .. ":" .. tostring(act)] = nil end
function ResetTimeEvent(ev, act, timer)
	local e = TIMEEV[tostring(ev) .. ":" .. tostring(act)]
	if e then e.at = NOW + timer * 1000 end
end
-- Runs due time events (repeatedly until quiet), like the engine's queue on updates.
function run_time_events(ms)
	local stop = NOW + (ms or 0)
	repeat
		for k, e in pairs(TIMEEV) do
			if TIMEEV[k] == e and e.at <= NOW then
				if e.f(unpack(e.p)) then TIMEEV[k] = nil end
			end
		end
		NOW = NOW + 50
	until NOW > stop
end
UNIQUE = {}
function AddUniqueCall(f) UNIQUE[#UNIQUE + 1] = f end
function RemoveUniqueCall(f) end

-------------------------------------------------------------------------------
-- m_data (alife_storage_manager shape: module env lookup of on_before_load_state)
-------------------------------------------------------------------------------
do
	local this = {}
	alife_storage_manager = this
	setmetatable(this, { __index = _G })
	local f = loadstring([[
		local m_data = { se_object = {}, game_object = {} }
		function on_before_load_state() BEFORE_LOAD = (BEFORE_LOAD or 0) + 1 end
		function CALifeStorageManager_load(data)
			m_data = data
			on_before_load_state()
			SendScriptCallback("load_state", m_data)
		end
		function get_state() return m_data end
	]], "@alife_storage_manager.script")
	setfenv(f, this)
	f()
end

-------------------------------------------------------------------------------
-- coop engine API
-------------------------------------------------------------------------------
SENT = {}
STASH = {}
SELF = MODE == "client" and 1 or 0
PROXY = 500 -- the client's character in host numbering (peer 1)
coop = {
	is_active = function() return MODE ~= "sp" end,
	is_host = function() return MODE == "host" end,
	is_client = function() return MODE == "client" end,
	is_live = function() return true end,
	self_id = function() return MODE == "sp" and -1 or SELF end,
	players = function()
		if MODE == "sp" then return {} end
		return {
			{ id = 0, nick = "hoster", is_self = MODE == "host", avatar_id = MODE == "host" and 0 or 500, rtt = 0 },
			{ id = 1, nick = "joiner", is_self = MODE == "client", avatar_id = MODE == "client" and 0 or 500, rtt = 12 },
		}
	end,
	avatar_of = function(peer)
		if peer == SELF then return 0 end
		if peer == 0 or peer == 1 then return 500 end
		return nil
	end,
	peer_of_avatar = function(id)
		if id == 0 then return SELF end
		if id == 500 then return MODE == "host" and 1 or 0 end
		return nil
	end,
	to_host_id = function(id)
		if MODE ~= "client" then return id end
		if id == 0 then return PROXY elseif id == PROXY then return 0 end
		return id
	end,
	to_local_id = function(id)
		if MODE ~= "client" then return id end
		if id == PROXY then return 0 elseif id == 0 then return PROXY end
		return id
	end,
	send_event = function(name, payload, target)
		SENT[#SENT + 1] = { name = name, payload = payload, target = target }
		return true
	end,
	send_chat = function() return true end,
	stash_set = function(k, v) STASH[k] = v; return true end,
	stash_get = function(k) return STASH[k] end,
}
-- F2 T10: coop.route (the engine's callback router) over coop_native, rules from configs\coop_route*.ltx
dofile("tests/lua/support/stubs.d/route.lua")

-- last sent event of a name (decoded)
function sent(name)
	for i = #SENT, 1, -1 do
		if SENT[i].name == name then return coop_main.decode(SENT[i].payload), SENT[i] end
	end
end
function sent_count(name)
	local n = 0
	for _, s in ipairs(SENT) do if s.name == name then n = n + 1 end end
	return n
end
-- deliver a captured event to this machine as if it came from `from`
function deliver(s, from) coop_main.on_event(s.name, s.payload, from) end

-------------------------------------------------------------------------------
-- engine bits coop_main needs
-------------------------------------------------------------------------------
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
				if not k then k = line:match("^%s*(.-)%s*$"); v = "" end
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

local function file_exists(p)
	local fh = io.open(p, "r")
	if fh then fh:close() return true end
	return false
end

SOUND_DIRS = {} -- path -> { "a.ogg", ... }
function getFS()
	return {
		exist = function(_, alias, file)
			if alias == "$game_scripts$" then
				local name = file:gsub("%.script$", "")
				return (rawget(_G, name) ~= nil or file_exists(ROOT .. "scripts/" .. file)) and {} or nil
			end
			return nil
		end,
		file_list_open_ex = function(_, alias, flags, mask)
			local list = {}
			for _, g in ipairs({ "core", "economy", "menu", "mods", "npc", "quests" }) do
				local n = "coop_domains_" .. g .. ".ltx"
				if file_exists(ROOT .. "configs/" .. n) then list[#list + 1] = n end
			end
			return {
				Size = function() return #list end,
				GetAt = function(_, i) return { NameFull = function() return list[i + 1] end } end,
			}
		end,
		file_list_open = function(_, alias, path, flags)
			-- coop_main (since f709fa6) lists configs\coop_domains_*.ltx with file_list_open(alias, flags): names
			if alias == "$game_config$" and type(path) == "number" then
				local names = {}
				for _, g in ipairs({ "core", "economy", "menu", "mods", "npc", "quests" }) do
					local n = "coop_domains_" .. g .. ".ltx"
					if file_exists(ROOT .. "configs/" .. n) then names[#names + 1] = n end
				end
				return { Size = function() return #names end, GetAt = function(_, i) return names[i + 1] end, Free = function() end }
			end
			local list = SOUND_DIRS[path] or {}
			return { Size = function() return #list end, GetAt = function(_, i) return list[i + 1] end }
		end,
	}
end

-- file_header_old: module = table with __index = _G
LOADING = {}
function load_script(name)
	local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "r"), name)
	local src = fh:read("*a")
	fh:close()
	local header = 'local this = {} ' .. name .. ' = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	local f = assert(loadstring(header .. src, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. name .. ".script"))
	LOADING[name] = true
	f()
	LOADING[name] = nil
	return rawget(_G, name)
end
setmetatable(_G, { __index = function(t, k)
	if type(k) == "string" and not LOADING[k] and k:match("^[%w_]+$") and file_exists(ROOT .. "scripts/" .. k .. ".script") then
		return load_script(k)
	end
	return nil
end })

-- a function defined in a given script file (debug.getinfo source)
function from_script(script, body)
	local f = assert(loadstring(body, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. script .. ".script"))
	return f()
end

-- Loads coop_main + all coop_mods_* and runs their on_game_start in file order.
MODS_FILES = { "coop_mods_core", "coop_mods_hf", "coop_mods_items", "coop_mods_mags", "coop_mods_misc",
	"coop_mods_nta", "coop_mods_pdata", "coop_mods_perks", "coop_mods_radio" }
function start_all()
	load_script("coop_main")
	for _, n in ipairs(MODS_FILES) do load_script(n) end
	coop_main.on_game_start()
	for _, n in ipairs(MODS_FILES) do _G[n].on_game_start() end
end

function done(tag)
	print(string.format("%s: %d passed, %d failed", tag, PASSES, FAILS))
	if FAILS > 0 then error(tag .. " FAILED") end
end
