-- Anomaly Coop HUD v2 (docs\HUD_V2.md) stub test: the compass bar, the marker data of the core, the ping, the team
-- panel (variant B), the player's switches and the Tactical Compass adapter. Real scripts (coop_allies, coop_allies_map,
-- coop_core_hud, coop_hud_markers, coop_hud_compass, coop_hud_ping, coop_hud_tc, coop_menu_options, modxml_coop_hud),
-- real ui_coop_core.xml / ui_coop_compass.xml paths, real mod_system_coop.ltx palette, real eng strings.
-- Run: tools\test_lua.cmd hud_v2   (VERBOSE=1 for logs)
local ROOT = "gamedata/"
os.execute("mkdir temp\\lua 2>NUL")

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

local function readfile(p)
	local fh = io.open(p, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local function near(a, b, eps) return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-6) end

-- ---------------------------------------------------------------- tiny XML reader (element paths -> attributes)
local function xml_nodes(file)
	local raw = readfile(file)
	if not raw then return {}, false end
	local src = raw:gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
	local nodes, stack = {}, {}
	for close, tag, attrs, selfclose in src:gmatch("<(/?)([%w_]+)([^>]-)(/?)>") do
		if close == "/" then
			table.remove(stack)
		else
			stack[#stack + 1] = tag
			local a = {}
			for k, v in attrs:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do a[k] = v end
			local path = table.concat(stack, ":", 2)
			nodes[path] = nodes[path] or a
			if selfclose == "/" then table.remove(stack) end
		end
	end
	return nodes, true
end
local XML = {
	["ui_coop_core.xml"] = xml_nodes(ROOT .. "configs/ui/ui_coop_core.xml"),
	["ui_coop_compass.xml"] = xml_nodes(ROOT .. "configs/ui/ui_coop_compass.xml"),
}
MISSING = {}

-- strings: eng tables of the HUD (translate_string answers them, "<id>" for anything else)
STR = {}
for _, f in ipairs({ "st_coop_hud.xml", "st_coop_allies.xml", "st_coop_checkpoints.xml", "st_coop_rest.xml" }) do
	local s = readfile(ROOT .. "configs/text/eng/" .. f) or ""
	for id, text in s:gmatch('<string id="([%w_]+)">%s*<text>(.-)</text>') do STR[id] = text end
end

-- ---------------------------------------------------------------- engine stand-ins
local NOW = 100000
local DEV = { width = 1920, height = 1080 }

local VecMT = {}
VecMT.__index = VecMT
local function vec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VecMT) end
function VecMT:set(x, y, z)
	if type(x) == "table" then x, y, z = x.x, x.y, x.z end
	self.x, self.y, self.z = x, y, z
	return self
end
function VecMT:distance_to(o)
	local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end
function VecMT:add(o) self.x, self.y, self.z = self.x + o.x, self.y + o.y, self.z + o.z return self end
function VecMT:sub(o) self.x, self.y, self.z = self.x - o.x, self.y - o.y, self.z - o.z return self end
function VecMT:mul(k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k return self end
function VecMT:mad(a, b, k)
	if k == nil then a, b, k = self, a, b end
	self.x, self.y, self.z = a.x + b.x * k, a.y + b.y * k, a.z + b.z * k
	return self
end
function VecMT:magnitude() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
function VecMT:normalize()
	local m = self:magnitude()
	if m > 0 then self:mul(1 / m) end
	return self
end

-- camera: position and direction of the device (heading in degrees, N = +z, E = +x)
local CAM = { pos = vec(0, 1.7, 0), dir = vec(0, 0, 1) }
local function look(deg)
	local r = math.rad(deg)
	CAM.dir = vec(math.sin(r), 0, math.cos(r))
end
-- a point at bearing `deg`, `dist` m away from the camera's ground point, height y
local function at(deg, dist, y)
	local r = math.rad(deg)
	return vec(CAM.pos.x + math.sin(r) * dist, y or 0, CAM.pos.z + math.cos(r) * dist)
end

local function window(path, a)
	a = a or {}
	local w = { path = path, children = {}, visible = true, text = "", heading = 0,
		x = tonumber(a.x) or 0, y = tonumber(a.y) or 0, w = tonumber(a.width) or 0, h = tonumber(a.height) or 0 }
	function w:SetText(t) self.text = tostring(t) end
	function w:GetText() return self.text end
	function w:SetTextColor(c) self.color = c end
	function w:GetHeight() return self.h end
	function w:GetWidth() return self.w end
	function w:SetWndPos(v) self.x, self.y = v.x, v.y end
	function w:GetWndPos() return { x = self.x, y = self.y } end
	function w:SetWndSize(v) self.w, self.h = v.x, v.y end
	function w:Show(b) self.visible = b end
	function w:IsShown() return self.visible end
	function w:InitTexture(t) self.texture = t end
	function w:SetStretchTexture(b) self.stretch = b end
	function w:SetTextureColor(c) self.tcolor = c end
	function w:SetProgressPos(p) self.progress = p end
	function w:SetEllipsis(b) self.ellipsis = b end
	function w:AdjustWidthToText() self.w = #self.text * 7 * 1024 / DEV.width end -- ~7 px per glyph
	function w:SetFont() end
	function w:SetTextAlignment(al) self.align = al end
	function w:EnableHeading(b) self.heading_on = b end
	function w:SetHeading(r) self.heading = r end
	function w:GetHeading() return self.heading end
	function w:SetAutoDelete() end
	return w
end

local function xml_stub()
	local x = { nodes = {} }
	function x:ParseFile(f) self.file = f; self.nodes = XML[f] or {} end
	local function init(self, path, parent)
		if not self.nodes[path] then MISSING[#MISSING + 1] = tostring(self.file) .. ":" .. path end
		local w = window(path, self.nodes[path])
		w.heading_on = self.nodes[path] and self.nodes[path].heading == "1" or false
		if parent and parent.children then parent.children[#parent.children + 1] = w end
		return w
	end
	x.InitStatic, x.InitTextWnd, x.InitProgressBar = init, init, init
	function x:NodeExist(name) return name:match("^coop_ally_%d$") ~= nil or name == "coop_ally_down" or name == "coop_ally_dead" end
	return x
end

local function class_stub(name)
	local env = getfenv(2)
	return function(base)
		local c = {}
		c.__index = c
		setmetatable(c, {
			__index = base,
			__call = function(cls, ...)
				local o = setmetatable({}, cls)
				if cls.__init then cls.__init(o, ...) end
				return o
			end,
		})
		env[name] = c
	end
end
local CUIScriptWnd = { Update = function() end }

-- minimal ltx reader for mod_system_coop.ltx (sections, k = v, ; comments)
local function ltx(path)
	local data, sec = {}, nil
	for line in (readfile(path) or ""):gmatch("[^\r\n]+") do
		line = line:gsub(";.*$", "")
		local s = line:match("^%s*%[([%w_]+)%]")
		if s then
			sec = s
			data[sec] = data[sec] or {}
		elseif sec then
			local k, v = line:match("^%s*([%w_%$]+)%s*=%s*(.-)%s*$")
			if k then data[sec][k] = v end
		end
	end
	return {
		section_exist = function(_, s) return data[s] ~= nil end,
		line_exist = function(_, s, k) return data[s] ~= nil and data[s][k] ~= nil end,
		r_string = function(_, s, k) return data[s][k] end,
		data = data,
	}
end
local INI = ltx(ROOT .. "configs/mod_system_coop.ltx")

-- ---------------------------------------------------------------- the machine
local SCRIPTS = { "coop_hud_layout", "coop_allies", "coop_allies_map", "coop_core_hud", "coop_hud_markers", "coop_hud_compass", "coop_hud_ping",
	"coop_hud_tc", "coop_menu_options", "modxml_coop_hud" }
local NET = {} -- machines of the session, by peer id
local MOUSE_5, CHAT_TEAM = 341, 77

local function machine(self_peer, opts)
	opts = opts or {}
	local M = { peer = self_peer, log = {}, cb = {}, spots = {}, hud = {}, players = {}, objects = {}, sent = {}, handlers = {},
		sounds = {}, console = {}, options = {}, life = {}, bleed = {}, rest = {}, binds = {} }
	local env = setmetatable({}, { __index = function(_, k)
		local v = _G[k]
		if v == nil then
			UNKNOWN = UNKNOWN or {}
			UNKNOWN[k] = true
		end
		return v
	end })
	env._G = env
	M.env = env
	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if os.getenv("VERBOSE") then print("    [" .. self_peer .. "] " .. line) end
	end
	env.time_global = function() return NOW end
	env.game = {
		translate_string = function(id) return STR[id] or id end,
		world2ui = function(p)
			if M.w2ui then return M.w2ui(p) end
			return { x = -9999, y = 0 }
		end,
	}
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.vector = function() return vec() end
	env.CScriptXmlInit = function() return xml_stub() end
	env.device = function()
		return { width = DEV.width, height = DEV.height, cam_pos = CAM.pos, cam_dir = CAM.dir, f_time_delta = 0.016 }
	end
	env.class = class_stub
	env.super = function() end
	env.CUIScriptWnd = CUIScriptWnd
	env.get_hud = function()
		return { AddDialogToRender = function(_, w) M.hud[w] = true end, RemoveDialogToRender = function(_, w) M.hud[w] = nil end }
	end
	env.main_hud_shown = function() return M.hud_shown ~= false end
	env.ini_sys = INI
	env.RegisterScriptCallback = function(name, f)
		M.cb[name] = M.cb[name] or {}
		table.insert(M.cb[name], f)
	end
	env.UnregisterScriptCallback = function(name, f)
		for i, g in ipairs(M.cb[name] or {}) do if g == f then table.remove(M.cb[name], i) break end end
	end
	env.AddScriptCallback = function() end
	env.DIK_keys = { MOUSE_5 = MOUSE_5, DIK_F15 = 102 }
	env.key_bindings = { kCHAT = 42, kCHAT_TEAM = CHAT_TEAM }
	env.dik_to_bind = function(dik) return M.binds[dik] or 999 end
	env.bind_to_dik = function(action)
		for dik, a in pairs(M.binds) do if a == action then return dik end end
		return 0
	end
	env.exec_console_cmd = function(c)
		M.console[#M.console + 1] = c
		local act, key = c:match("^bind (%S+) (%S+)$")
		if act == "chat_team" and key == "mouse5" then M.binds[MOUSE_5] = CHAT_TEAM end
	end
	env.Check_UI = function() return M.ui_open == true end
	env.sound_object = function(path)
		local s = { path = path }
		function s:play() M.sounds[#M.sounds + 1] = path end
		return s
	end
	env.axr_main = { config = {
		r_value = function(_, sec, key, typ, def)
			local v = M.options[key]
			if v == nil then return def end
			return v
		end,
		w_value = function(_, sec, key, v) M.options[key] = v end,
		save = function() M.saved = (M.saved or 0) + 1 end,
	} }
	env.ui_options = nil

	-- objects: the actor (0) and avatars
	local ObjMT = {}
	ObjMT.__index = ObjMT
	function ObjMT:position() return vec(self._p.x, self._p.y, self._p.z) end
	function ObjMT:character_icon() return "ui_npc_icon" end
	function ObjMT:character_community() return "actor_stalker" end
	function ObjMT:alive() return self._alive ~= false end
	function ObjMT:id() return self._id end
	function ObjMT:parent() return self._parent end
	function ObjMT:is_active_task(t) return t and t._active == true end
	M.actor = setmetatable({ _id = 0, _p = vec(0, 0, 0), health = 1 }, ObjMT)
	M.objects[0] = M.actor
	function M.object(id, p) M.objects[id] = setmetatable({ _id = id, _p = p }, ObjMT) return M.objects[id] end
	env.db = { actor = M.actor, storage = {} }
	env.level = {
		present = function() return true end,
		name = function() return M.level or "l01_escape" end,
		object_by_id = function(id) return M.objects[id] end,
		map_has_object_spot = function(id, t) return M.spots[t .. "@" .. id] and 1 or 0 end,
		map_add_object_spot = function(id, t, h) M.spots[t .. "@" .. id] = h end,
		map_change_spot_hint = function(id, t, h) M.spots[t .. "@" .. id] = h end,
		map_remove_object_spot = function(id, t) M.spots[t .. "@" .. id] = nil end,
		map_get_object_spot_static = function() return nil end,
		map_get_object_minimap_spot_static = function() return nil end,
		get_target_dist = function() return M.target_dist or 0 end,
		get_target_pos = function() return M.target_pos or vec(0, 0, 0) end,
	}
	M.active = opts.active ~= false
	env.coop = {
		is_active = function() return M.active end,
		is_host = function() return M.active and self_peer == 0 end,
		is_client = function() return M.active and self_peer ~= 0 end,
		is_live = function() return M.active end,
		self_id = function() return self_peer end,
		players = function() return M.players end,
		send_event = function(name, payload, target)
			M.sent[#M.sent + 1] = { name = name, payload = payload, target = target }
			return true
		end,
		spot_is_local = function(t) return t:sub(1, 5) == "coop_" end,
		life_of = function(id) return M.life[id] end,
		bleed_left = function(id) return M.bleed[id] end,
		rest = { state_of = function(id) return M.rest[id] or "awake" end, hours_of = function() return 0 end },
		checkpoint = { get = function(lid) return lid == 0 and M.camp or nil end },
	}
	-- coop_main stand-in: the flat codec + handler registry
	local cm = {}
	local function esc(s) return (s:gsub("[%%;=]", function(c) return string.format("%%%02X", c:byte()) end)) end
	local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
	function cm.encode(t)
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
	function cm.decode(str)
		local t = {}
		for pair in tostring(str):gmatch("[^;]+") do
			local k, v = pair:match("^([^=]*)=(.*)$")
			if k then
				k, v = unesc(k), unesc(v)
				local tag, body = v:sub(1, 1), v:sub(2)
				t[k] = tag == "n" and tonumber(body) or tag == "b" and body == "1" or body
			end
		end
		return t
	end
	function cm.add_event_handler(name, f) M.handlers[name] = f end
	env.coop_main = cm
	for _, name in ipairs(SCRIPTS) do
		local src = readfile(ROOT .. "scripts/" .. name .. ".script")
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		if src then
			local f, err = loadstring(src, "@" .. name .. ".script")
			if f then
				setfenv(f, mod)
				local ok, e = pcall(f)
				if not ok then print("  load error " .. name .. ": " .. tostring(e)) end
			else
				print("  syntax error " .. name .. ": " .. tostring(err))
			end
		else
			M.missing_script = (M.missing_script or "") .. " " .. name
		end
	end
	M.allies, M.hudm, M.markers, M.compass, M.ping, M.tc = env.coop_allies, env.coop_core_hud, env.coop_hud_markers,
		env.coop_hud_compass, env.coop_hud_ping, env.coop_hud_tc
	for _, name in ipairs(SCRIPTS) do
		local m = env[name]
		if rawget(m, "on_game_start") then
			local ok, e = pcall(m.on_game_start)
			if not ok then print("  on_game_start " .. name .. ": " .. tostring(e)) end
		end
	end
	NET[self_peer] = M
	return M
end

local function fire(M, name, ...)
	for _, f in ipairs(M.cb[name] or {}) do f(...) end
end

-- the engine's script event transport: a client reaches the host (target 0), the host one peer (N) or everybody (-1)
local function deliver()
	local moved = true
	while moved do
		moved = false
		for peer, M in pairs(NET) do
			local q = M.sent
			M.sent = {}
			M.sent_all = M.sent_all or {}
			for _, e in ipairs(q) do
				M.sent_all[#M.sent_all + 1] = e
				for p2, M2 in pairs(NET) do
					if p2 ~= peer and (e.target == -1 or e.target == nil or e.target == p2) then
						local h = M2.handlers[e.name]
						if h then h(e.payload, peer, e.name) moved = true end
					end
				end
			end
		end
	end
end

-- frames: 60 fps for ms milliseconds on every machine of the session
local function run(ms, only)
	local t_end = NOW + (ms or 0)
	repeat
		for _, M in pairs(only and { only } or NET) do
			fire(M, "actor_on_update")
			for w in pairs(M.hud) do w:Update() end
		end
		deliver()
		NOW = NOW + 16
	until NOW >= t_end
end

local function status(M, peer, s, h, b)
	local t = { h = h or 1, s = s, f = "actor_stalker", i = "" }
	if b then t.b = b end
	M.handlers["core.status"](M.env.coop_main.encode(t), peer)
end

local function count_log(M, pat)
	local n = 0
	for _, s in ipairs(M.log) do if s:find(pat, 1, true) then n = n + 1 end end
	return n
end

local function by_kind(list, kind, field, value)
	local out = {}
	for _, m in ipairs(list or {}) do
		if m.kind == kind and (field == nil or m[field] == value) then out[#out + 1] = m end
	end
	return out
end

local function alpha_of(c) return c and math.floor(c / 16777216) or nil end
local function rgb_of(c)
	if not c then return nil end
	local v = c % 16777216
	return math.floor(v / 65536), math.floor(v / 256) % 256, v % 256
end

-- Geometry dump for a visual check against docs\hud\hud_v2_mockup.png (temp\lua\hud_v2_<name>.txt, read by
-- temp\hud_v2\render_dump.py): every visible static / text window under `root`, in 1024x768 units, tab separated.
local function dump(name, windows)
	local fh = io.open("temp/lua/hud_v2_" .. name .. ".txt", "wb")
	if not fh then return end
	local TAB = string.char(9)
	for _, w in ipairs(windows) do
		if w.visible then
			local text = (w.text or ""):gsub("%c", " ")
			fh:write(table.concat({ w.path, ("%.3f"):format(w.ax or w.x), ("%.3f"):format(w.ay or w.y), ("%.3f"):format(w.w),
				("%.3f"):format(w.h), tostring(w.tcolor or ""), tostring(w.color or ""), w.texture or "", text,
				("%.4f"):format(w.heading or 0) }, TAB) .. string.char(10))
		end
	end
	fh:close()
end
local function flatten(root, ox, oy, out)
	out = out or {}
	for _, c in ipairs(root.children or {}) do
		c.ax, c.ay = (ox or 0) + c.x, (oy or 0) + c.y
		out[#out + 1] = c
		flatten(c, c.ax, c.ay, out)
	end
	return out
end

-- ================================================================ 1. strip math
print("== strip math")
NET = {}
local M = machine(0, { active = false })
check(M.missing_script == nil, "all HUD v2 scripts exist (missing:" .. tostring(M.missing_script) .. ")")
local C = M.compass
local ok_api = type(C.heading_of) == "function" and type(C.place) == "function" and type(C.tick_list) == "function"
check(ok_api, "compass math helpers exported")
if ok_api then
	check(near(C.heading_of(vec(0, 0, 1)), 0) and near(C.heading_of(vec(1, 0, 0)), 90) and near(C.heading_of(vec(0, 0, -1)), 180)
		and near(C.heading_of(vec(-1, 0, 0)), 270), "heading: N = +z 0, E = +x 90, S 180, W 270")
	check(C.heading_of(vec(0, 1, 0)) == nil, "looking straight up: no heading")
	check(near(C.bearing(vec(0, 0, 0), vec(10, 5, 10)), 45), "bearing ignores height (NE = 45)")
	check(near(C.rel_angle(10, 350), 20) and near(C.rel_angle(350, 10), -20) and near(C.rel_angle(190, 0), -170) and near(C.rel_angle(180, 0), 180),
		"relative angle wraps to (-180, 180]")
	local x, side = C.place(0, 160, 200, 10)
	check(near(x, 0) and side == 0, "centre maps to 0")
	x, side = C.place(40, 160, 200, 10)
	check(near(x, 100) and side == 0, "40 deg of a 160 deg field = half of the half width")
	x, side = C.place(-40, 120, 200, 10)
	check(near(x, -133.333, 0.01) and side == 0, "FOV 120: -40 deg -> -2/3 of the half width")
	x, side = C.place(79, 160, 200, 10)
	check(near(x, 190) and side == 1, "beyond the field minus the edge pad: pinned to the right edge")
	x, side = C.place(-170, 160, 200, 10)
	check(near(x, -190) and side == -1, "behind on the left: pinned to the left edge")
	check(near(C.edge_alpha(0, 200, 0.16), 1) and near(C.edge_alpha(200, 200, 0.16), 0) and near(C.edge_alpha(168, 200, 0.16), 0.5),
		"edge fade over the last 16 % of the width")
	local ticks = {}
	local n = C.tick_list(247, 160, ticks)
	local letters, mids = {}, 0
	for i = 1, n do
		if ticks[i].letter then letters[#letters + 1] = ticks[i].deg end
		if ticks[i].mid then mids = mids + 1 end
	end
	check(n == 32 and table.concat(letters, ",") == "180,225,270,315", "heading 247, FOV 160: 32 marks, letters S SW W NW (" .. n .. ", " .. table.concat(letters, ",") .. ")")
	check(mids == 6, "15 deg marks between the letters: 6 (" .. mids .. ")")
	check(near(C.smooth_k(16, 50), 1 - math.exp(-16 / 50)), "frame interpolation factor 1 - exp(-dt / tau)")
	check(near(C.step_alpha(0, 1, 75, 150), 0.5) and near(C.step_alpha(1, 0, 300, 150), 0), "fade in / out: linear 150 ms")
	local items = { { x = 0, w = 40, pri = 30, want = true }, { x = 10, w = 40, pri = 50, want = true }, { x = 150, w = 40, pri = 10, want = true },
		{ x = 160, w = 10, pri = 5, want = false } }
	C.pick_labels(items, 4)
	check(items[2].show and not items[1].show and items[3].show and not items[4].show, "labels: higher priority wins a collision, a far one stays")
	check(C.fov_of("200") == 200 and C.fov_of(130) == 160 and C.fov_of(nil) == 160 and C.fov_of(120) == 120, "FOV option: 120 / 160 / 200, else 160")
end

-- ================================================================ 2. marker sources
print("== marker sources")
NET = {}
NOW = 200000
M = machine(2)
local MK = M.markers
M.players = {
	{ id = 0, nick = "hosty", avatar_id = 500, is_self = false },
	{ id = 1, nick = "p1", avatar_id = 501, is_self = false },
	{ id = 2, nick = "me", avatar_id = 0, is_self = true },
	{ id = 3, nick = "p3", avatar_id = 503, is_self = false },
	{ id = 4, nick = "p4", avatar_id = 504, is_self = false },
	{ id = 5, nick = "p5", avatar_id = 505, is_self = false },
	{ id = 6, nick = "p6", avatar_id = 506, is_self = false },
	{ id = 7, nick = "p7", avatar_id = nil, is_self = false },
}
M.object(500, vec(20, 0, 20))
M.object(501, vec(0, 0, -30))
M.object(503, vec(-10, 0, 0))
M.object(504, vec(-10, 0, 5))
M.object(505, vec(5, 0, 50))
M.object(506, vec(6, 0, 60))
status(M, 0, "alive", 1)
status(M, 1, "down", 0.01, 40)
status(M, 3, "dead", 0)
status(M, 4, "spec", 1)
status(M, 6, "respawn", 1)
NOW = NOW - 16000
status(M, 5, "alive", 1) -- reported 16 s ago: no signal
NOW = NOW + 16000
-- tasks
local function task(active) return { _active = active } end
M.env.task_manager = { get_task_manager = function() return M.tm end }
M.tm = { task_info = {
	t_active = { t = task(true), current_target = 900, status = "selected" },
	t_other = { t = task(false), current_target = 901, status = "normal" },
	t_done = { t = task(false), current_target = 902, status = "completed" },
	t_gone = { t = task(false), current_target = 903, status = "normal" }, -- no object here
} }
M.object(900, vec(100, 0, 0))
M.object(901, vec(0, 0, 200))
M.object(902, vec(0, 0, 10))
-- camp
M.camp = { kind = "tent", source = 960, level = "l01_escape" }
M.object(960, vec(-50, 0, -50))
run(300, M)
local list = (type(MK.list) == "function") and MK.list() or {}
local allies = by_kind(list, "ally")
local function ally(peer) for _, m in ipairs(allies) do if m.peer == peer then return m end end end
check(#allies == 6, "an ally marker for every other player with an avatar (6, got " .. #allies .. ")")
local a0, a1, a3, a4, a5, a6 = ally(0), ally(1), ally(3), ally(4), ally(5), ally(6)
local A = M.allies
local function same_rgb(c, r, g, b) return c and c[1] == r and c[2] == g and c[3] == b end
check(a0 and a0.state == "alive" and a0.label == "hosty" and same_rgb(a0.color, A.color(0)) and a0.priority == 30 and near(a0.pos.x, 20),
	"alive ally: his colour, nick, priority 30, avatar position")
check(a1 and a1.state == "down" and same_rgb(a1.color, A.state_color("down")) and a1.priority == 40, "down ally: red, priority 40 (above an ally)")
check(a3 and a4 and a6 and a3.state == "dead" and a4.state == "spec" and a6.state == "respawn" and same_rgb(a3.color, A.state_color("dead"))
	and same_rgb(a4.color, A.state_color("dead")) and same_rgb(a6.color, A.state_color("dead")), "dead / spectating / returning: grey")
check(a5 and a5.state == "unknown" and same_rgb(a5.color, A.color(5)), "no signal: his colour (the position is live)")
local tasks = by_kind(list, "task")
local ta, to = by_kind(tasks, "task", "state", "active")[1], by_kind(tasks, "task", "state", "other")[1]
check(#tasks == 2 and ta and to and ta.priority == 20 and to.priority == 10 and near(ta.pos.x, 100) and near(to.pos.z, 200),
	"tasks: the active one (priority 20) and the others (10); done ones and targets not here are skipped")
local camp = by_kind(list, "camp")[1]
check(camp and camp.state == "tent" and near(camp.pos.x, -50) and same_rgb(camp.color, 146, 190, 154), "own camp: tent, sage colour")
-- death marks: the engine's callback on every machine; the mark lives while the host's PDA spot is on the object
M.object(950, vec(30, 0, 0))
M.spots["secondary_task_location@950"] = "x"
fire(M, "coop_death_marker", 501, 950, "corpse")
M.object(951, vec(31, 0, 0))
fire(M, "coop_death_marker", 503, 951, "drop")
run(1100, M)
list = MK.list()
local deaths = by_kind(list, "death")
local d1 = by_kind(deaths, "death", "state", "corpse")[1]
check(#deaths == 2 and d1 and d1.label == "p1" and near(d1.pos.x, 30), "death marks: corpse (nick of the fallen) and drop")
check(by_kind(deaths, "death", "state", "drop")[1] ~= nil, "a drop mark before the host's spot came: kept for the grace time")
M.spots["secondary_task_location@950"] = nil
run(11000, M)
list = MK.list()
check(#by_kind(list, "death") == 0, "the host's spot is gone (picked up / emptied): the marks go")
-- camp of another kind / level
M.camp = { kind = "arrival", source = 960, level = "l01_escape" }
run(1100, M)
check(#by_kind(MK.list(), "camp") == 0, "an arrival point has no camp marker")
M.camp = { kind = "campfire", source = 960, level = "l02_garbage" }
run(1100, M)
check(#by_kind(MK.list(), "camp") == 0, "a camp on another level: no marker")
M.camp = { kind = "campfire", source = 960, level = "l01_escape" }
run(1100, M)
check((by_kind(MK.list(), "camp")[1] or {}).state == "campfire", "campfire camp")
-- a mod's source
local calls = 0
local okadd = MK.add_source and MK.add_source("mymod", function()
	calls = calls + 1
	return { { key = "a", kind = "poi", pos = vec(1, 2, 3), color = { 10, 20, 30 }, label = "Hut" },
		{ key = "bad", kind = "poi" } } -- no position: dropped and counted
end)
check(okadd == true, "add_source accepts a mod's source")
calls = 0
for _ = 1, 62 do MK.list(); NOW = NOW + 16 end -- ~1 s of frames
local poi = by_kind(MK.list(), "poi")[1]
check(poi and poi.key == "mymod/a" and poi.label == "Hut" and poi.priority == 10, "mod marker: key prefixed with the source, default priority 10")
check(calls >= 9 and calls <= 11, "sources are asked ~10 times a second, not every frame (" .. calls .. ")")
check((MK.bad_count and MK.bad_count("mymod") or 0) > 0, "a marker without a position is dropped and counted")
MK.add_source("broken", function() error("boom") end)
run(300, M)
list = MK.list()
check(#by_kind(list, "ally") == 6 and (MK.error_count and MK.error_count("broken") or 0) > 0, "a failing source is counted, the others still come")
check(count_log(M, "broken") >= 1 and count_log(M, "broken") <= 2, "a failing source is logged once, not every refresh")
MK.remove_source("broken")
MK.remove_source("mymod")
-- outside a session: tasks and camps stay, allies and pings go
M.active = false
run(1100, M)
list = MK.list()
check(#by_kind(list, "ally") == 0 and #by_kind(list, "task") == 2 and #by_kind(list, "camp") == 1, "single player: tasks and camp, no allies")
M.active = true

-- ================================================================ 3. the compass bar
print("== compass")
NET = {}
NOW = 300000
M = machine(2)
M.players = {
	{ id = 0, nick = "player_a", avatar_id = 500, is_self = false },
	{ id = 1, nick = "Guest", avatar_id = 501, is_self = false },
	{ id = 2, nick = "me", avatar_id = 0, is_self = true },
}
look(247)
M.object(500, at(255, 26)) -- 8 deg right of the centre (the mockup has 11: outside the 10 deg of the spec)
M.object(501, at(30, 71))
status(M, 0, "alive", 0.86)
status(M, 1, "down", 0.18, 42)
M.env.task_manager = { get_task_manager = function() return M.tm end }
M.tm = { task_info = {
	a = { t = task(true), current_target = 900, status = "selected" },
	b = { t = task(false), current_target = 901, status = "normal" },
} }
M.object(900, at(212, 312))
M.object(901, at(296, 150, 20)) -- 20 m above
run(400, M)
local W = M.compass.get_window and M.compass.get_window()
check(W ~= nil and M.hud[W] == true, "compass window on the HUD")
check(#MISSING == 0, "compass and cards built from the XML (missing: " .. table.concat(MISSING, ", ") .. ")")
local CW = 1024 * 0.38
local KX = 1024 * DEV.height / (768 * DEV.width) -- px@768 -> units across
if W then
	check(W.heading and W.heading.text == "247" .. string.char(176), "heading text 247 deg (" .. tostring(W.heading and W.heading.text) .. ")")
	local bx = W.bar_x and W.bar_x or -1
	check(near(W.bar_w, CW, 0.5) and near(bx, (1024 - CW) / 2, 0.5), "bar: 38 % of the width, centred (owner: a bit smaller)")
	check(near(W.bar_y, 20) and near(W.bar_h, 24), "bar: 20 down from the top, 24 high (1024x768 units)")
	-- the scale is white (owner 2026-10-23): plate #0C0D0A ~0.33, white line ~0.8 through the bar, white ticks under it
	local PY = 768 / DEV.height
	local line_y = math.floor((20 + 15) / PY + 0.5) * PY
	check(W.bg.tcolor == M.env.GetARGB(84, 12, 13, 10), "plate #0C0D0A at ~0.33 (" .. tostring(alpha_of(W.bg.tcolor)) .. ")")
	check(W.line.tcolor == M.env.GetARGB(204, 244, 245, 246) and near(W.line.y, line_y) and near(W.line.h, PY),
		"a white line #F4F5F6 at ~0.8, one screen pixel, 15 under the bar's top")
	local cx = bx + CW / 2
	local half = CW / 2
	local function shown_letter(deg) local t = W.letters and W.letters[deg] return t and t.visible and t end
	local sw = shown_letter(225)
	check(shown_letter(180) and sw and shown_letter(270) and shown_letter(315) and not shown_letter(0) and not shown_letter(90),
		"letters on screen: S SW W NW")
	check(sw and near(sw.x + sw.w / 2, cx + (225 - 247) / 80 * half, 1), "SW at its angle")
	local lr, lg, lb = rgb_of(W.letters[225].color)
	check(lr == 244 and lg == 245 and lb == 246 and W.letters[225].y < line_y, "letters white, above the line")
	check(W.letter_shadows and W.letter_shadows[225].visible and select(1, rgb_of(W.letter_shadows[225].color)) == 0
		and near(W.letter_shadows[225].x - W.letters[225].x, 1024 / DEV.width), "letters with a 1 px shadow")
	local nt, white, below, lens = 0, true, true, {}
	for _, t in ipairs(W.ticks or {}) do
		if t.visible then
			nt = nt + 1
			local r, g, b = rgb_of(t.tcolor)
			white = white and r == 244 and g == 245 and b == 246
			below = below and t.y > line_y - 1e-6
			lens[string.format("%.0f", t.h)] = true
		end
	end
	check(nt == 32, "a tick every 5 deg within the field: 32 (" .. nt .. ")")
	check(white and below, "ticks white, down from the line")
	check(lens["2"] and lens["4"] and lens["5"], "ticks 2 / 4 / 5 px for 5 / 15 / 45 deg")
	local sh_n = 0
	for _, t in ipairs(W.tick_shadows or {}) do if t.visible then sh_n = sh_n + 1 end end
	check(sh_n == nt, "every tick has its 1 px shadow")
	check(W.notch.y >= line_y and near(W.notch.x + W.notch.w / 2, (1024 - CW) / 2 + CW / 2, 0.01)
		and W.notch.tcolor % 16777216 == M.env.GetARGB(0, 244, 245, 246), "white notch under the line at the centre")
	check(W.heading.color % 16777216 == M.env.GetARGB(0, 244, 245, 246) and W.heading.y < 20, "heading white, above the bar")
	-- markers
	local function slot(key_part)
		for _, s in ipairs(W.slots or {}) do
			if s.key and s.key:find(key_part, 1, true) and s.icon.visible then return s end
		end
	end
	dump("compass", flatten(W.root, W.root.x, W.root.y))
	local s0 = slot("ally:0")
	check(s0 and s0.icon.texture == "coop_hud_chevron", "ally: chevron")
	check(s0 and near(s0.icon.y + s0.icon.h / 2, 20 + 9) and near(s0.icon.h, 12), "markers 12 px, on the line (a bit above it)")
	check(s0 and select(1, rgb_of(s0.icon.tcolor)) == 217, "ally: in his colour (sand)")
	local x0 = s0 and (s0.icon.x + s0.icon.w / 2) or 0
	check(near(x0, cx + (255 - 247) / 80 * half, 1.5), "ally at his bearing (x " .. string.format("%.1f", x0) .. ")")
	check(s0 and s0.label.visible and s0.label.text == "player_a  26 m", "ally within 10 deg of the centre: nick and distance (" .. tostring(s0 and s0.label.text) .. ")")
	local s1 = slot("ally:1")
	check(s1 and s1.icon.texture == "coop_hud_down", "downed ally: ring with a cross")
	check(s1 and s1.side.visible and s1.side.texture == "coop_hud_tri_right" and s1.icon.x + s1.icon.w / 2 > cx + half * 0.9,
		"downed ally behind on the right: pinned to the right edge with an arrow")
	check(s1 and not s1.label.visible, "a pinned marker has no label")
	local a_s1 = s1 and alpha_of(s1.icon.tcolor)
	run(240, M)
	check(s1 and alpha_of(s1.icon.tcolor) ~= a_s1, "downed ally pulses")
	local st = slot("task:a")
	check(st and st.icon.texture == "coop_hud_diamond" and st.label.visible and st.label.text == "310 m", "active task: diamond + distance (" .. tostring(st and st.label.text) .. ")")
	local so = slot("task:b")
	check(so and so.icon.texture == "coop_hud_diamond_hollow" and alpha_of(so.icon.tcolor) <= 160 and alpha_of(so.icon.tcolor) >= 140,
		"other task: hollow diamond, alpha ~0.6 (" .. tostring(so and alpha_of(so.icon.tcolor)) .. ")")
	check(so and not so.label.visible, "other task: no label off the centre")
	-- height: the other task is 20 m above; turn to it so its label shows
	look(296)
	run(300, M)
	check(so.label.visible and so.updown.visible and so.updown.texture == "coop_hud_tri_up", "20 m above, looked at: distance with an up arrow")
	look(247)
	run(300, M)
	-- draw order: the higher priority is attached later (drawn on top)
	local i0, i1
	for i, s in ipairs(W.slots) do if s == s0 then i0 = i end if s == s1 then i1 = i end end
	check(i0 and i1 and i1 > i0, "a downed ally draws above an ally")
	-- interpolation: the ally moves 10 m sideways; the icon follows over a few frames
	local before = s0.icon.x
	M.objects[500]._p = at(265, 26)
	run(120, M) -- the next marker refresh
	local mid = s0.icon.x
	run(500, M)
	local after = s0.icon.x
	local target = cx + (265 - 247) / 80 * half - s0.icon.w / 2
	check(mid > before and mid < after - 0.5 and near(after, target, 1.5), "movement is interpolated over frames (" ..
		string.format("%.1f -> %.1f -> %.1f, target %.1f", before, mid, after, target) .. ")")
	-- fade in / out
	M.tm.task_info.c = { t = task(false), current_target = 902, status = "normal" }
	M.object(902, at(250, 80))
	run(112, M)
	local sc = slot("task:c")
	local fa = sc and alpha_of(sc.icon.tcolor) or 255
	run(300, M)
	check(sc and fa < alpha_of(sc.icon.tcolor), "a new marker fades in (" .. tostring(fa) .. " -> " .. tostring(sc and alpha_of(sc.icon.tcolor)) .. ")")
	M.tm.task_info.c = nil
	run(112, M)
	check(sc and sc.icon.visible, "a gone marker fades out, not cut")
	run(300, M)
	check(not (sc and sc.icon.visible and sc.key and sc.key:find("task:c", 1, true)), "faded out after ~150 ms")
	-- labels never overlap: a ping next to the ally hides the ally's label
	local ping_m = { key = "p", kind = "ping", pos = at(266, 30), color = { 217, 177, 96 }, priority = 50 }
	M.markers.add_source("t", function() return { ping_m } end)
	run(300, M)
	local sp = slot("t/p")
	check(sp and sp.icon.texture == "coop_hud_ring" and sp.core and sp.core.visible and sp.core.texture == "coop_hud_dot", "ping: ring + dot")
	check(sp and sp.label.visible and not s0.label.visible, "ping next to the ally: the ping's label shows, the ally's is hidden")
	M.markers.remove_source("t")
	-- FOV option
	M.compass.set_fov(120)
	run(200, M)
	check(near(s0.icon.x + s0.icon.w / 2, cx + (265 - 247) / 60 * half, 1.5), "FOV 120: the ally moves outwards")
	M.compass.set_fov(160)
	-- hidden with the main HUD, removed when switched off
	M.hud_shown = false
	run(150, M)
	check(not W.root.visible, "hidden with the main HUD (inventory, PDA)")
	M.hud_shown = true
	run(150, M)
	check(W.root.visible, "back with the HUD")
	M.compass.set_enabled(false)
	run(100, M)
	check(M.hud[W] == nil and M.compass.get_window() == nil, "switched off: the window goes")
	M.compass.set_enabled(true)
	run(100, M)
	check(M.compass.get_window() ~= nil, "switched on again")
	-- single player: the compass stays (tasks)
	M.active = false
	run(1200, M)
	W = M.compass.get_window()
	local any_task, any_ally = false, false
	for _, s in ipairs(W and W.slots or {}) do
		if s.icon.visible and s.key then
			if s.key:find("task:", 1, true) then any_task = true end
			if s.key:find("ally:", 1, true) then any_ally = true end
		end
	end
	check(W and any_task and not any_ally, "single player: the compass shows tasks, no allies")
	M.active = true
	-- frame time counter for coop_status
	M.hudm.print_status()
	check(count_log(M, "hud v2: frame") >= 1, "coop_status line with the HUD frame time")
end

-- ================================================================ 4. ping
print("== ping")
NET = {}
NOW = 400000
local H = machine(0)
local CL = machine(2)
local roster = {
	{ id = 0, nick = "hosty", avatar_id = 500 },
	{ id = 2, nick = "guest", avatar_id = 502 },
}
local function roster_for(Mx)
	local l = {}
	for _, p in ipairs(roster) do
		l[#l + 1] = { id = p.id, nick = p.nick, avatar_id = (p.id == Mx.peer) and 0 or p.avatar_id, is_self = p.id == Mx.peer }
	end
	return l
end
H.players, CL.players = roster_for(H), roster_for(CL)
H.object(502, vec(5, 0, 5))
CL.object(500, vec(0, 0, 0))
look(0)
CL.binds[MOUSE_5] = CHAT_TEAM
H.binds[MOUSE_5] = CHAT_TEAM
run(200)
-- target point: the hit point, or 300 m along the view when nothing is hit within 300 m
CL.target_dist, CL.target_pos = 50, vec(0, 0, 50)
local tp = CL.ping.target_point and CL.ping.target_point()
check(tp and near(tp.z, 50), "target: what the camera hits")
CL.target_dist = 0
tp = CL.ping.target_point()
check(tp and near(tp.z, 300) and near(tp.y, 1.7), "nothing hit: 300 m along the view")
CL.target_dist, CL.target_pos = 500, vec(0, 0, 500)
tp = CL.ping.target_point()
check(tp and near(tp.z, 300), "hit beyond 300 m: 300 m along the view")
-- the key
CL.target_dist, CL.target_pos = 40, vec(0, 0, 40)
fire(CL, "on_key_press", MOUSE_5)
local req
for _, e in ipairs(CL.sent) do if e.name == "core.ping_req" then req = e end end
check(req and req.target == 0, "ping key: a request to the host")
run(32)
local hp = H.ping.active()
local cp = CL.ping.active()
check(#hp == 1 and hp[1].peer == 2 and near(hp[1].pos.z, 40), "host keeps the client's ping")
check(#cp == 1 and cp[1].peer == 2, "the author gets it back from the host")
check(#CL.sounds >= 1 and #H.sounds >= 1, "a quiet click on arrival")
local relayed = 0
for _, e in ipairs(H.sent_all or {}) do if e.name == "core.ping" and e.target == -1 then relayed = relayed + 1 end end
check(relayed == 1, "host relays to everybody")
-- client limit
local ok, why = CL.ping.request()
check(ok == false and why == "rate", "second ping within 2 s: refused by the client (" .. tostring(why) .. ")")
run(2000)
ok = CL.ping.request()
check(ok == true, "after 2 s: sent")
run(32)
check(#H.ping.active() == 2, "two pings live")
-- host limit (a client without its own limit)
H.handlers["core.ping_req"](H.env.coop_main.encode({ x = 1, y = 0, z = 1, l = "l01_escape" }), 2)
check(#H.ping.active() == 2, "host: a request within 2 s of the last one is dropped")
-- bad requests
local n0 = #H.ping.active()
NOW = NOW + 2100
H.handlers["core.ping_req"](H.env.coop_main.encode({ x = 1e9, y = 0, z = 1, l = "l01_escape" }), 2)
H.handlers["core.ping_req"](H.env.coop_main.encode({ x = 1, y = 0, z = 1, l = "l02_garbage" }), 2)
H.handlers["core.ping_req"](H.env.coop_main.encode({ y = 0, z = 1, l = "l01_escape" }), 2)
check(#H.ping.active() == n0, "bad coordinates / another level / no x: dropped")
-- a client takes pings only from the host
CL.handlers["core.ping"](CL.env.coop_main.encode({ x = 1, y = 0, z = 1, p = 3, n = 1, l = "l01_escape" }), 3)
check(#CL.ping.active() == 2, "a client ignores a ping that did not come from the host")
-- the host's own ping
H.target_dist, H.target_pos = 10, vec(10, 0, 0)
fire(H, "on_key_press", MOUSE_5)
run(32)
check(#H.ping.active() == 3 and #CL.ping.active() == 3, "host's own ping: kept and sent to everybody")
-- at most 3 pings per author
for _ = 1, 2 do
	run(2050)
	CL.ping.request()
end
run(32)
local mine = 0
for _, p in ipairs(H.ping.active()) do if p.peer == 2 then mine = mine + 1 end end
check(mine == 3, "at most 3 live pings per author (" .. mine .. ")")
-- on the compass with the highest priority
local pm = by_kind(CL.markers.refresh(), "ping", "peer", 2)
check(#pm >= 1 and pm[1].priority == 50 and pm[1].color[1] == select(1, CL.allies.color(2)), "ping marker: priority 50, in the author's colour")
-- in the world: a ring over the point
CL.w2ui = function(p) return { x = 512, y = 300 } end
run(50)
local WW = CL.ping.get_world_window and CL.ping.get_world_window()
local shown = 0
for _, r in ipairs(WW and WW.rings or {}) do if r.visible then shown = shown + 1 end end
check(WW and shown >= 1, "a ring over the pinged point (game.world2ui)")
local r1 = WW and WW.rings[1]
check(r1 and near(r1.x + r1.w / 2, 512, 0.5) and near(r1.y + r1.h / 2, 300, 0.5), "ring centred on the projected point")
check(WW and WW.labels[1].visible and WW.labels[1].text:find(" m", 1, true), "distance under the ring")
CL.w2ui = function() return { x = -9999, y = 0 } end
run(50)
shown = 0
for _, r in ipairs(WW and WW.rings or {}) do if r.visible then shown = shown + 1 end end
check(shown == 0, "off screen: no ring")
-- lifetime
run(21000)
check(#H.ping.active() == 0 and #CL.ping.active() == 0, "20 s later every ping is gone")
-- outside a session
CL.active = false
run(32)
ok, why = CL.ping.request()
check(ok == false and why == "off", "single player: no ping")
CL.active = true

-- ================================================================ 5. team panel (variant B: rows bottom left)
print("== team panel")
NET = {}
NOW = 500000
M = machine(2)
M.players = {
	{ id = 0, nick = "player_a", avatar_id = 500, is_self = false },
	{ id = 1, nick = "Guest", avatar_id = 501, is_self = false },
	{ id = 2, nick = "me", avatar_id = 0, is_self = true },
	{ id = 3, nick = "p3", avatar_id = 503, is_self = false },
}
look(0)
M.object(500, at(90, 26))
M.object(501, at(180, 71))
M.object(503, at(270, 15))
status(M, 0, "alive", 0.86)
status(M, 1, "alive", 0.18)
status(M, 3, "alive", 1)
run(600, M)
local P
for w in pairs(M.hud) do if w.team_panel then P = w end end
check(P ~= nil, "team panel on the HUD")
local function fill_w(r, part)
	local w = 0
	for _, s in ipairs(r.segs) do if s[part or "fill"].e.visible then w = w + s[part or "fill"].e.w end end
	return w
end
local SEG = 30 * KX
if P then
	local r1, r2, r3 = P.rows[1], P.rows[2], P.rows[3]
	check(r1.base.e.visible and r2.base.e.visible and r3.base.e.visible and not P.rows[4].base.e.visible, "one row per other player")
	check(r1.name.e.text == "player_a" and r2.name.e.text == "Guest" and r3.name.e.text == "p3", "sorted by peer: host on top")
	check(near(r1.base.e.x, 18 * KX) and near(r1.base.e.y, 20) and near(r2.base.e.y, 20 + 36) and near(r3.base.e.y, 20 + 72),
		"top left (owner 2026-10-23: bottom left covered the PDA news): the block goes down from 20, 36 apart")
	check(r1.strip.e.tcolor % 16777216 == M.allies.argb(0) % 16777216 and near(r1.strip.e.w, 2 * KX) and near(r1.strip.e.h, 22),
		"2 px bar in his colour")
	local nr, ng, nb = rgb_of(r1.name.e.color)
	check(nr == 244 and ng == 245 and nb == 246 and r1.name_sh.e.text == "player_a" and select(1, rgb_of(r1.name_sh.e.color)) == 0,
		"nick white with a shadow")
	check(r1.host.e.visible and r1.host.e.texture == "coop_hud_star" and not r2.host.e.visible, "host star on the host only")
	check(r1.host.e.tcolor and r1.host.e.tcolor % 16777216 == M.allies.argb(0) % 16777216, "the star in the host's colour")
	check(r1.dist.e.text == "26 m" and r1.dist.e.x > r1.host.e.x and r2.dist.e.text == "71 m", "distance after the nick (" .. r1.dist.e.text .. ")")
	check(near(r1.arrow.e.heading, -math.pi / 2, 0.02) and near(math.abs(r2.arrow.e.heading), math.pi, 0.02) and near(r3.arrow.e.heading, math.pi / 2, 0.02),
		"direction arrow turned relative to the camera (right / behind / left)")
	look(90)
	run(50, M)
	check(near(r1.arrow.e.heading, 0, 0.02), "the arrow follows the camera every frame")
	look(0)
	-- health: 4 segments of 25 %, 30x5, 3 apart
	local s1, s2 = r1.segs[1], r1.segs[2]
	check(near(s1.bg.e.w, SEG) and near(s1.bg.e.h, 5) and near(s2.bg.e.x - s1.bg.e.x, 33 * KX), "segments 30x5 px, 3 px apart")
	check(alpha_of(s1.bg.e.tcolor) == 46 and select(1, rgb_of(s1.bg.e.tcolor)) == 244, "the empty part white at ~0.18")
	check(near(fill_w(r1), SEG * 4 * 0.86, 0.05) and near(r1.segs[4].fill.e.w, SEG * 0.44, 0.05), "86 %: three full segments and 0.44 of the fourth")
	check(select(1, rgb_of(r1.segs[1].fill.e.tcolor)) == 244, "fill white")
	local r_, g_, b_ = rgb_of(r2.segs[1].fill.e.tcolor)
	check(r_ == 226 and g_ == 58 and b_ == 48 and not r2.segs[2].fill.e.visible, "18 %: red, under one segment")
	check(not r1.icon.e.visible and not r1.timer.e.visible, "a well player: no icon, no words")
	-- healed: the gain flashes white for 0.4 s
	status(M, 1, "alive", 0.5)
	run(600, M)
	local fl = fill_w(r2, "flash")
	check(fl > 0 and alpha_of(r2.segs[2].flash.e.tcolor) > 0, "healed 18 -> 50 %: the gain flashes (" .. string.format("%.1f", fl) .. ")")
	run(500, M)
	check(fill_w(r2, "flash") == 0, "the flash is over after 0.4 s")
	-- down: the segments are the bleed-out timer
	status(M, 1, "down", 0.01, 42)
	run(600, M)
	local rows_all = {}
	for _, rr in ipairs(P.rows) do if rr.base.e.visible then flatten(rr.base.e, rr.base.e.x, rr.base.e.y, rows_all) end end
	dump("team", rows_all)
	local w0 = fill_w(r2)
	r_, g_, b_ = rgb_of(r2.segs[1].fill.e.tcolor)
	check(r_ == 226 and near(w0, SEG * 4, 1.5), "down: red full bar at the start of the bleed-out (" .. string.format("%.1f", w0) .. ")")
	check(r2.icon.e.visible and r2.icon.e.texture == "coop_hud_cross", "a cross right of the segments")
	local arcs = 0
	for _, a in ipairs(r2.arcs) do if a.e.visible then arcs = arcs + 1 end end
	check(arcs == 8, "in a full ring of 8 arcs (" .. arcs .. ")")
	check(r2.timer.e.visible and r2.timer.e.text:match("^0:4[12]$") and r2.timer.e.x > r2.icon.e.x, "0:42 after the cross (" .. r2.timer.e.text .. ")")
	local sa = alpha_of(r2.strip.e.tcolor)
	run(300, M)
	check(sa ~= alpha_of(r2.strip.e.tcolor), "the row breathes at 1 Hz")
	run(10000, M)
	status(M, 1, "down", 0.01, 32) -- he keeps reporting (a status older than 15 s is "no signal")
	run(10400, M)
	local w1 = fill_w(r2)
	arcs = 0
	for _, a in ipairs(r2.arcs) do if a.e.visible then arcs = arcs + 1 end end
	check(w1 < w0 * 0.55 and w1 > w0 * 0.4 and r2.segs[1].fill.e.visible and not r2.segs[4].fill.e.visible,
		"half the time gone: the red melted right to left to about half (" .. string.format("%.1f of %.1f", w1, w0) .. ")")
	check(arcs == 4 or arcs == 5, "the ring melts with it (" .. arcs .. " arcs)")
	-- part 2 seam: being revived fills the red in the reviver's colour
	M.hudm.set_revive(1, 0.5, 0)
	run(50, M)
	local ov = fill_w(r2, "over")
	r_ = rgb_of(r2.segs[1].over.e.tcolor)
	check(near(ov, w1 * 0.5, 2) and r_ == 217, "set_revive(peer, 0.5, host): half of the red in the host's colour (" .. string.format("%.1f", ov) .. ")")
	M.hudm.set_revive(1, nil)
	-- back on his feet: the whole bar flashes
	status(M, 1, "alive", 0.3)
	run(600, M)
	check(fill_w(r2, "flash") > SEG, "revived: the bar flashes white")
	check(not r2.icon.e.visible and not r2.timer.e.visible, "cross and timer gone")
	-- dead / returning
	status(M, 1, "dead", 0)
	run(600, M)
	r_, g_, b_ = rgb_of(r2.segs[1].fill.e.tcolor)
	check(r_ == 120 and g_ == 120 and near(fill_w(r2), SEG * 4, 0.5) and r2.icon.e.texture == "coop_hud_skull", "dead: grey segments and a skull")
	check(not r2.timer.e.visible, "no respawn time known: no timer")
	local resp_end = NOW + 21000
	M.env.coop.respawn_left = function(id) return id == 501 and math.max(0, resp_end - NOW) or nil end
	status(M, 1, "respawn", 1)
	run(600, M)
	local o0 = fill_w(r2, "over")
	run(10000, M)
	local o1 = fill_w(r2, "over")
	r_ = rgb_of(r2.segs[1].over.e.tcolor)
	check(o1 > o0 and near(o1, SEG * 4 * 10.6 / 21, 6) and r_ == 244, "the respawn countdown fills the grey back in white (" ..
		string.format("%.1f -> %.1f", o0, o1) .. ")")
	check(r2.timer.e.visible and r2.timer.e.text:match("^0:1%d$"), "returning timer (" .. r2.timer.e.text .. ")")
	M.env.coop.respawn_left = nil
	-- spectating, sleeping, no signal
	status(M, 1, "spec", 1)
	run(600, M)
	check(r2.icon.e.texture == "coop_hud_eye" and select(1, rgb_of(r2.segs[1].fill.e.tcolor)) == 120, "spectating: eye, grey segments")
	status(M, 1, "alive", 1)
	M.rest[501] = "sleeping"
	run(600, M)
	check(r2.icon.e.visible and r2.icon.e.texture == "coop_hud_z", "sleeping: z")
	local ba = alpha_of(r2.segs[1].fill.e.tcolor)
	run(750, M)
	local bb = alpha_of(r2.segs[1].fill.e.tcolor)
	check(ba ~= bb and ba >= 0.5 * 230 - 2 and ba <= 0.8 * 230 + 2 and bb >= 0.5 * 230 - 2 and bb <= 0.8 * 230 + 2,
		"sleeping: the segments breathe 0.5..0.8 (" .. ba .. " -> " .. bb .. ")")
	M.rest[501] = nil
	run(16000, M)
	check(r1.icon.e.visible and r1.icon.e.texture == "coop_hud_warn", "status stopped coming: amber !")
	r_, g_, b_ = rgb_of(r1.icon.e.tcolor)
	check(r_ > 200 and g_ > 120 and g_ < 200 and b_ < 100, "the ! is amber")
	check(alpha_of(r1.name.e.color) <= 130, "the nick dimmed")
	status(M, 0, "alive", 1)
	status(M, 1, "alive", 1)
	status(M, 3, "alive", 1)
	run(600, M)
	-- F3 T13: a tent for 10 s after his checkpoint changed
	local at_cp = NOW
	M.env.coop_checkpoints = { last_update = function(id) return id == 501 and at_cp or nil end }
	run(600, M)
	r_, g_, b_ = rgb_of(r2.icon.e.tcolor)
	check(r2.icon.e.visible and r2.icon.e.texture == "coop_hud_tent" and r_ == 146 and g_ == 190, "checkpoint changed: a sage tent (no words)")
	run(10000, M)
	check(not r2.icon.e.visible, "10 s later it is gone")
	M.env.coop_checkpoints = nil
	-- switches and visibility
	M.hudm.set_party_enabled(false)
	run(100, M)
	check(not r1.base.e.visible, "panel switched off")
	M.hudm.set_party_enabled(true)
	run(600, M)
	M.hud_shown = false
	run(40, M)
	check(not r1.base.e.visible, "hidden with the main HUD")
	M.hud_shown = true
	M.active = false
	run(100, M)
	local still = false
	for w in pairs(M.hud) do if w.team_panel then still = true end end
	check(not still, "single player: no team panel")
	M.active = true
	run(600, M)
	for w in pairs(M.hud) do if w.team_panel then P = w end end
	r1, r3 = P.rows[1], P.rows[3]
	-- several resolutions: the same place in units, never stretched
	for _, res in ipairs({ { 1280, 720 }, { 1024, 768 }, { 2560, 1440 }, { 3440, 1440 } }) do
		DEV.width, DEV.height = res[1], res[2]
		run(600, M)
		local kx = 1024 * res[2] / (768 * res[1])
		check(near(r1.base.e.x, 18 * kx) and near(r1.base.e.y, 20) and near(r1.segs[1].bg.e.w, 30 * kx),
			("%dx%d: rows at x %.1f units, segments %.1f wide"):format(res[1], res[2], r1.base.e.x, r1.segs[1].bg.e.w))
	end
	DEV.width, DEV.height = 1920, 1080
	-- the owner's next "smaller": one line of [coop_hud_layout] in mod_system_coop.ltx
	check(INI.data.coop_hud_layout and INI.data.coop_hud_layout.team_x == "18" and INI.data.coop_hud_layout.bar_bg_alpha == "0.33",
		"mod_system_coop.ltx has [coop_hud_layout] with the defaults")
	INI.data.coop_hud_layout.team_x = "40"
	INI.data.coop_hud_layout.bar_bg_alpha = "0.5"
	INI.data.coop_hud_layout.bar_top = "garbage"
	M.env.coop_hud_layout.reload()
	run(600, M)
	local Wc = M.compass.get_window()
	check(near(r1.base.e.x, 40 * KX, 0.01), "team_x = 40 in the ltx: the rows move right")
	INI.data.coop_hud_layout.team_top = "-1"
	M.env.coop_hud_layout.reload()
	run(600, M)
	check(near(r3.base.e.y + 22, 590) and near(r1.base.e.y, 590 - 22 - 72),
		"team_top = -1: the old place, hanging from team_bottom (590) upwards")
	check(INI.data.coop_hud_layout.team_bottom == "590", "team_bottom stays in the ltx for that mode")
	INI.data.coop_hud_layout.team_top = "20"
	check(Wc and alpha_of(Wc.bg.tcolor) == 128 and near(Wc.bar_y, 20), "bar_bg_alpha = 0.5 applied; a broken line keeps the default")
	INI.data.coop_hud_layout.team_x = "18"
	INI.data.coop_hud_layout.bar_bg_alpha = "0.33"
	INI.data.coop_hud_layout.bar_top = "20"
	M.env.coop_hud_layout.reload()
end

-- ================================================================ 6. player options, key, Tactical Compass
print("== options")
NET = {}
NOW = 600000
M = machine(2)
local page = M.env.coop_menu_options.build_page()
local opts = {}
for _, gr in ipairs(page.gr) do
	if gr.id == "coop_player" then for _, o in ipairs(gr.gr) do opts[o.id] = o end end
end
check(opts.compass_hud and opts.compass_hud.type == "check" and opts.compass_hud.def == true, "player option: compass on/off (on)")
check(opts.party_hud and opts.party_hud.def == true, "player option: team panel on/off kept")
local fov = opts.compass_fov
local vals = {}
for _, c in ipairs(fov and fov.content or {}) do vals[#vals + 1] = c[1] end
check(fov and fov.type == "list" and fov.def == "160" and table.concat(vals, ",") == "120,160,200", "player option: compass field 120 / 160 / 200 (160)")
check(opts.ping_note and opts.ping_note.type == "desc", "player options: a line about the ping key")
M.options["coop/coop_player/compass_hud"] = false
M.options["coop/coop_player/compass_fov"] = "200"
M.env.coop_menu_options.apply_player_flags()
check(M.compass.is_enabled() == false and M.compass.get_fov() == 200, "options applied to the compass")
M.options["coop/coop_player/compass_hud"] = nil
M.env.coop_menu_options.apply_player_flags()
check(M.compass.is_enabled() == true, "absent option: compass on")
-- the key entry in Options > Controls > Common
local ins, groups = {}, { { kids = {} } }
local xobj = {
	query = function(_, q)
		if q == "group[name=kb_grp_common]" then return groups end
		if q == "command[id=kb_coop_ping]" then return ins end
		return {}
	end,
	insertFromXMLString = function(_, s) ins[#ins + 1] = s end,
}
M.env.modxml_coop_hud.on_xml_read()
fire(M, "on_xml_read", [[ui\ui_keybinding.xml]], xobj)
fire(M, "on_xml_read", [[ui\ui_keybinding.xml]], xobj)
fire(M, "on_xml_read", [[ui\ui_hud.xml]], xobj)
check(#ins == 1 and ins[1]:find('exe="chat_team"', 1, true) and ins[1]:find('id="kb_coop_ping"', 1, true), "Co-op: ping in the key list, once")
-- default binding: mouse 5 (free in GAMMA), once
M.binds = {}
fire(M, "actor_on_first_update")
check(M.console[1] == "bind chat_team mouse5" and M.options["coop/coop_player/ping_key_set"] == true, "ping key bound to mouse 5 once")
M.binds = {}
fire(M, "actor_on_first_update")
check(#M.console == 1, "not again after the player cleared it")
M2 = machine(3)
M2.binds[MOUSE_5] = 55
fire(M2, "actor_on_first_update")
check(#M2.console == 0, "mouse 5 taken by something else: left unbound")
-- Tactical Compass adapter: TC installed and our compass off -> allies and pings go to tc_markers as companions
print("== tactical compass adapter")
NET = {}
NOW = 700000
M = machine(2)
M.players = {
	{ id = 0, nick = "hosty", avatar_id = 500, is_self = false },
	{ id = 2, nick = "me", avatar_id = 0, is_self = true },
}
M.object(500, vec(10, 0, 10))
local tcl = { list = {} }
local tc_m = {}
tc_m.list = tcl.list
function tc_m.add(id, spot, cat)
	tc_m.list[id] = tc_m.list[id] or {}
	tc_m.list[id][spot] = { id = id, spot = spot, category = cat }
end
function tc_m.remove(id, spot)
	if tc_m.list[id] then tc_m.list[id][spot] = nil if next(tc_m.list[id]) == nil then tc_m.list[id] = nil end end
end
function tc_m.drop_stale_spots()
	for id, spots in pairs(tc_m.list) do
		for spot in pairs(spots) do
			if M.env.level.map_has_object_spot(id, spot) == 0 then tc_m.remove(id, spot) end
		end
	end
end
local tc_u = { get_world_coordinates = function(id) return id == 77 and vec(7, 7, 7) or nil end }
M.env.tc_markers, M.env.tc_utils = tc_m, tc_u
run(300, M)
check(next(tc_m.list) == nil, "our compass on: nothing goes to Tactical Compass")
M.compass.set_enabled(false)
run(600, M)
check(tc_m.list[500] and tc_m.list[500].coop_hud_ally and tc_m.list[500].coop_hud_ally.category == "companion", "ally -> tc_markers.add(avatar, spot, 'companion')")
tc_m.drop_stale_spots()
check(tc_m.list[500] ~= nil, "Tactical Compass's stale-spot sweep keeps our entries")
M.target_dist, M.target_pos = 20, vec(0, 0, 20)
M.binds[MOUSE_5] = CHAT_TEAM
-- the session's host relays: here a ping comes from the host directly
M.handlers["core.ping"](M.env.coop_main.encode({ x = 0, y = 0, z = 20, p = 0, n = 1, l = "l01_escape" }), 0)
run(600, M)
local fake
for id, spots in pairs(tc_m.list) do if spots.coop_hud_ping then fake = id end end
check(fake and fake > 65535 and fake % 65536 == 65535, "ping -> a fake id the engine reads as 'no object' (" .. tostring(fake) .. ")")
local wp = fake and tc_u.get_world_coordinates(fake)
check(wp and near(wp.z, 20), "Tactical Compass gets the ping's position for the fake id")
check(near(tc_u.get_world_coordinates(77).x, 7), "other ids go to Tactical Compass's own lookup")
tc_m.drop_stale_spots()
check(fake and tc_m.list[fake] ~= nil, "the ping survives the stale sweep")
run(21000, M)
check(fake and tc_m.list[fake] == nil, "the ping leaves Tactical Compass when it expires")
M.compass.set_enabled(true)
run(300, M)
check(next(tc_m.list) == nil, "our compass back on: our entries leave Tactical Compass")
M.compass.set_enabled(false)
M.active = false
run(600, M)
check(next(tc_m.list) == nil, "single player: no allies in Tactical Compass")

-- ================================================================ 7. performance (Lua side, stubs): 8 players, 20 markers
print("== frame cost")
NET = {}
NOW = 800000
M = machine(7)
M.players = {}
for p = 0, 7 do
	M.players[#M.players + 1] = { id = p, nick = "p" .. p, avatar_id = p == 7 and 0 or 500 + p, is_self = p == 7 }
	if p ~= 7 then
		M.object(500 + p, at(p * 45, 20 + p * 10))
	end
end
for p = 0, 6 do status(M, p, p == 3 and "down" or "alive", 0.8, p == 3 and 60 or nil) end
M.env.task_manager = { get_task_manager = function() return M.tm end }
M.tm = { task_info = {} }
for i = 1, 13 do
	M.tm.task_info["t" .. i] = { t = task(i == 1), current_target = 900 + i, status = "normal" }
	M.object(900 + i, at(i * 27, 100 + i * 20))
end
run(500, M)
local n_markers = #M.markers.list()
local t0 = os.clock()
local frames = 300
for _ = 1, frames do
	look((NOW / 20) % 360)
	fire(M, "actor_on_update")
	for w in pairs(M.hud) do w:Update() end
	NOW = NOW + 16
end
local per_frame_ms = (os.clock() - t0) * 1000 / frames
print(("  info %d markers, %.3f ms per frame in the stubs (the engine adds luabind calls)"):format(n_markers, per_frame_ms))
check(n_markers >= 20, "20 markers on the bar (" .. n_markers .. ")")
check(per_frame_ms < 1.0, "Lua side of a frame well under a millisecond in the stubs (" .. string.format("%.3f", per_frame_ms) .. " ms)")

-- ================================================================
local unk = {}
for k in pairs(UNKNOWN or {}) do unk[#unk + 1] = tostring(k) end
table.sort(unk)
local allowed = { axr_companions = true, profile_timer = true, task_manager = true, coop_checkpoints = true, tc_markers = true, tc_utils = true }
local bad = {}
for _, k in ipairs(unk) do if not allowed[k] then bad[#bad + 1] = k end end
check(#bad == 0, "no reads of undefined globals (" .. table.concat(bad, ", ") .. ")")
print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
