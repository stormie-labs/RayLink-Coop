-- Anomaly Coop W6 (allies UI) stub test: coop_allies + coop_allies_map + coop_core_hud on one machine that sees
-- 1..7 other players. Real scripts, real ui_coop_core.xml / ui_hud.xml coordinates, real mod_system_coop.ltx palette.
-- HUD v2 (variant B) replaced W6's party panel: its rows are checked here briefly, in depth in test_hud_v2.lua.
-- Run: tools\test_lua.cmd allies   (VERBOSE=1 for logs)
local ROOT = "gamedata/"
local REF = "../anomaly-ref/unpacked/configs/ui/"
local OUT = "temp/lua/" -- scratch dumps (temp/ is git-ignored); the runner creates it
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
	local fh = assert(io.open(p, "rb"))
	local s = fh:read("*a")
	fh:close()
	return s
end

-- ---------------------------------------------------------------- tiny XML reader (element paths -> attributes)
local function xml_nodes(file)
	local src = readfile(file):gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
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
	return nodes
end
local CORE = xml_nodes(ROOT .. "configs/ui/ui_coop_core.xml")
local HUDX = xml_nodes(REF .. "ui_hud.xml")
MISSING = {}

-- ---------------------------------------------------------------- engine stand-ins
local NOW = 100000
local DEV = { width = 1920, height = 1080 }

local function window(path, a)
	a = a or {}
	local w = { path = path, children = {}, visible = true, text = "",
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
	function w:GetProgressStatic() self.pstatic = self.pstatic or window(path .. ":progress") return self.pstatic end
	function w:SetEllipsis(b) self.ellipsis = b end
	function w:AdjustWidthToText() self.w = #self.text * 7 * 1024 / DEV.width end -- ~7 px per glyph
	function w:SetFont() end
	function w:EnableHeading(b) self.heading_on = b end
	function w:SetHeading(r) self.heading = r end
	return w
end

local function xml_stub(nodes)
	local x = {}
	function x:ParseFile(f) self.file = f end
	local function init(_, path, parent)
		if not nodes[path] then MISSING[#MISSING + 1] = path end
		local w = window(path, nodes[path])
		if parent and parent.children then parent.children[#parent.children + 1] = w end
		return w
	end
	x.InitStatic, x.InitTextWnd, x.InitProgressBar = init, init, init
	function x:NodeExist(name) return INJECTED == true and (name:match("^coop_ally_%d$") or name == "coop_ally_down" or name == "coop_ally_dead") ~= nil end
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
	for line in readfile(path):gmatch("[^\r\n]+") do
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
STR = {}
for id, text in readfile(ROOT .. "configs/text/eng/st_coop_allies.xml"):gmatch('<string id="([%w_]+)">%s*<text>(.-)</text>') do STR[id] = text end

-- ---------------------------------------------------------------- the machine
local SCRIPTS = { "coop_hud_layout", "coop_allies", "coop_allies_map", "coop_core_hud", "modxml_coop_allies" }

local function machine(self_peer)
	local M = { log = {}, cb = {}, spots = {}, spot_ops = {}, hud = {}, players = {}, objects = {}, sent = {},
		statics = {}, handlers = {}, life = {}, bleed = {} }
	UNKNOWN = UNKNOWN or {}
	local env = setmetatable({}, { __index = function(_, k)
		local v = _G[k]
		if v == nil then UNKNOWN[k] = true end
		return v
	end })
	env._G = env
	M.env = env
	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if os.getenv("VERBOSE") then print("    [log] " .. line) end
	end
	env.time_global = function() return NOW end
	env.game = { translate_string = function(id) return (REAL_STRINGS and STR[id]) or ("<" .. id .. ">") end }
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.CScriptXmlInit = function() return xml_stub(CORE) end
	env.utils_xml = { get_hud_xml = function() return xml_stub(HUDX) end }
	env.device = function() return { width = DEV.width, height = DEV.height } end
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
	-- objects: the actor (0) at x = 0, avatars at their x
	local ObjMT = {}
	ObjMT.__index = ObjMT
	function ObjMT:position()
		local p = { x = self._x or 0 }
		function p:distance_to(o) return math.abs(self.x - o.x) end
		return p
	end
	function ObjMT:character_icon() return self._icon or "ui_npc_icon" end
	function ObjMT:character_community() return "actor_stalker" end
	function ObjMT:alive() return self._alive ~= false end
	M.actor = setmetatable({ _x = 0, health = 1 }, ObjMT)
	M.objects[0] = M.actor
	function M.avatar(id, x) M.objects[id] = setmetatable({ _x = x }, ObjMT) end
	env.db = { actor = M.actor }
	env.level = {
		present = function() return true end,
		object_by_id = function(id) return M.objects[id] end,
		map_has_object_spot = function(id, t) return M.spots[t .. "@" .. id] and 1 or 0 end,
		map_add_object_spot = function(id, t, h)
			assert(type(id) == "number" and type(t) == "string" and type(h) == "string", "luabind types")
			assert(not M.spots[t .. "@" .. id], "AddMapLocation twice for " .. t .. "@" .. id)
			M.spots[t .. "@" .. id] = h
			M.spot_ops[#M.spot_ops + 1] = "+" .. t .. "@" .. id
		end,
		map_change_spot_hint = function(id, t, h)
			assert(M.spots[t .. "@" .. id], "hint of a missing spot")
			M.spots[t .. "@" .. id] = h
		end,
		map_remove_object_spot = function(id, t)
			M.spots[t .. "@" .. id] = nil
			M.spot_ops[#M.spot_ops + 1] = "-" .. t .. "@" .. id
		end,
		map_get_object_spot_static = function(id, t)
			if not M.spots[t .. "@" .. id] then return nil end
			M.statics["l" .. t .. id] = M.statics["l" .. t .. id] or window("lvl")
			return M.statics["l" .. t .. id]
		end,
		map_get_object_minimap_spot_static = function(id, t)
			if not M.spots[t .. "@" .. id] then return nil end
			M.statics["m" .. t .. id] = M.statics["m" .. t .. id] or window("mini")
			return M.statics["m" .. t .. id]
		end,
	}
	M.active = true
	env.coop = {
		is_active = function() return M.active end,
		is_host = function() return M.active and self_peer == 0 end,
		is_live = function() return M.active end,
		players = function() return M.players end,
		send_event = function(name, payload, target)
			M.sent[#M.sent + 1] = { name = name, payload = payload, target = target }
			return true
		end,
	}
	-- coop_main stand-in: the real flat codec + handler registry
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
		for pair in str:gmatch("[^;]+") do
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
		local f = assert(loadstring(readfile(ROOT .. "scripts/" .. name .. ".script"), "@" .. name .. ".script"))
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		setfenv(f, mod)
		f()
	end
	M.allies, M.map, M.hudm, M.modxml = env.coop_allies, env.coop_allies_map, env.coop_core_hud, env.modxml_coop_allies
	M.hudm.on_game_start()
	return M
end

local function fire(M, name, ...)
	for _, f in ipairs(M.cb[name] or {}) do f(...) end
end

-- frames: 60 fps for ms milliseconds
local function run(M, ms)
	local t_end = NOW + (ms or 0)
	repeat
		fire(M, "actor_on_update")
		for w in pairs(M.hud) do w:Update() end
		NOW = NOW + 16
	until NOW >= t_end
end

local function status(M, peer, s, h, b)
	local t = { h = h or 1, s = s, f = "actor_stalker", i = "ui_face_" .. peer }
	if b then t.b = b end
	M.handlers["core.status"](M.env.coop_main.encode(t), peer)
end

local function count_spots(M, pat)
	local n = 0
	for k in pairs(M.spots) do if k:match(pat) then n = n + 1 end end
	return n
end

local function count_log(M, pat)
	local n = 0
	for _, s in ipairs(M.log) do if s:find(pat, 1, true) then n = n + 1 end end
	return n
end

local function party_of(M)
	for w in pairs(M.hud) do if w.team_panel then return w end end
end

-- roster: me + n others (peers 0..n excluding me), avatar id 500 + peer, standing peer*10 m away
local function roster(M, me, n)
	M.players = {}
	local others = 0
	local peer = 0
	while others < n or peer == me do
		if peer == me then
			M.players[#M.players + 1] = { id = me, nick = "me", avatar_id = 0, rtt = 0, is_self = true }
		else
			others = others + 1
			M.players[#M.players + 1] = { id = peer, nick = "p" .. peer, avatar_id = 500 + peer, rtt = 30, is_self = false }
			M.avatar(500 + peer, peer * 10)
		end
		peer = peer + 1
	end
	if me >= peer then M.players[#M.players + 1] = { id = me, nick = "me", avatar_id = 0, rtt = 0, is_self = true } end
end

-- ================================================================ palette
print("== palette")
local M = machine(3)
local A = M.allies
local r, g, b = A.color(0)
check(r == 217 and g == 177 and b == 96, "host colour from mod_system_coop.ltx (sand)")
r, g, b = A.color(9)
check(r == 83 and g == 140 and b == 224 and A.slot(9) == 1, "peer 9 wraps to slot 1 (blue)")
check(A.text_tag(4) == "%c[255,211,117,79]", "text colour tag of slot 4")
check(select(1, A.state_color("down")) == 226 and select(1, A.state_color("spec")) == 150 and A.state_color("alive") == nil, "state colours")
local seen = {}
local dup = false
for s = 0, 7 do
	local key = table.concat({ A.slot_color(s) }, ",")
	if seen[key] then dup = true end
	seen[key] = true
	check(INI.data.coop_player_colors["color_" .. s] == key, "slot " .. s .. " = ltx " .. key)
end
check(not dup, "8 distinct colours")
INI.data.coop_player_colors.color_2 = "garbage"
A.reload_palette()
r, g, b = A.slot_color(2)
check(r == 146 and g == 190 and b == 154, "broken ltx line -> built-in default")
INI.data.coop_player_colors.color_2 = "146,190,154"
A.reload_palette()

-- ================================================================ map_spots.xml additions
print("== spot xml")
local ins = {}
local mobj = { query = function(_, q) return q == "coop_ally_0" and ins or {} end, insertFromXMLString = function(_, s) ins[#ins + 1] = s end }
M.modxml.on_xml_read()
fire(M, "on_xml_read", [[ui\map_spots_16.xml]], mobj)
fire(M, "on_xml_read", [[ui\map_spots.xml]], mobj)
fire(M, "on_xml_read", [[ui\pda.xml]], mobj)
check(#ins == 1, "injected once, only into map_spots*.xml")
local fh = assert(io.open(OUT .. "spot_xml_dump.xml", "wb"))
fh:write('<?xml version="1.0" encoding="windows-1251"?>\n<map_spots>\n' .. ins[1] .. "\n</map_spots>\n")
fh:close()
check(ins[1]:find('<coop_ally_3_mini width="16" height="16" heading="1" stretch="1" alignment="c" location_level="12"><texture r="206" g="202" b="253">coop_ally_arrow_32</texture>', 1, true) ~= nil,
	"slot 3 minimap arrow: 16 units, heading, stretched, lilac tint")
check(ins[1]:find('<mini_map spot="coop_ally_5_mini" pointer="coop_ally_5_mptr"/>', 1, true) ~= nil, "edge pointer declared per slot")
check(ins[1]:find('<coop_ally_down_mptr width="11" height="11" heading="1" stretch="1" alignment="c"><texture r="226" g="58" b="48">', 1, true) ~= nil, "red pointer for a downed ally")
check(not ins[1]:find("\\", 1, true), "texture ids only (no paths: no minimap crop)")

-- ================================================================ markers need the engine's local-spot answer
print("== markers: engine gate")
roster(M, 3, 2)
run(M, 1000)
check(next(M.spots) == nil and count_log(M, "coop.spot_is_local is missing") == 1, "no markers without coop.spot_is_local (logged once)")
local P = party_of(M)
check(P ~= nil and #MISSING == 0, "party panel built (missing xml paths: " .. table.concat(MISSING, ", ") .. ")")

M = machine(3)
M.env.coop.spot_is_local = function(t) return t == "coop_ally_0" end
roster(M, 3, 2)
run(M, 1000)
check(next(M.spots) == nil and count_log(M, "engine replicates spot type") == 1, "a replicated type keeps markers off")

-- ================================================================ 1..7 allies
print("== markers: 1..7 allies")
INJECTED = true
for n = 1, 7 do
	local me = (n == 7) and 7 or 3 -- a full session: me = the last client
	M = machine(me)
	M.env.coop.spot_is_local = function(t) return t:sub(1, 5) == "coop_" end
	roster(M, me, n)
	run(M, 300)
	local ok = count_spots(M, "^coop_ally_%d@") == n and count_spots(M, "@0$") == 0
	for _, p in ipairs(M.players) do
		if not p.is_self then
			local h = M.spots[("coop_ally_%d@%d"):format(p.id % 8, p.avatar_id)]
			ok = ok and h ~= nil and h:find(A.text_tag(p.id) .. p.nick, 1, true) ~= nil
		end
	end
	check(ok, n .. " allies: one arrow each, type by peer id, nick in his colour, none on me")
	local P2 = party_of(M)
	local rows = 0
	for _, rr in ipairs(P2.rows) do if rr.base.e.visible then rows = rows + 1 end end
	check(rows == n, n .. " allies: " .. rows .. " rows")
	if n == 7 then
		M.players[1].nick = "A_Very_Long_Nickname_Indeed"
		run(M, 600)
		local rr = P2.rows[1]
		check(rr.name.e.w <= 120 * 1024 * 1080 / (768 * 1920) + 0.001 and rr.name.e.ellipsis and rr.host.e.x >= rr.name.e.x + rr.name.e.w
			and rr.dist.e.x > rr.host.e.x, "a long nick is cut (ellipsis) before the host star and the distance")
	end
end

-- ================================================================ states
print("== states")
M = machine(2)
M.env.coop.spot_is_local = function(t) return t:sub(1, 5) == "coop_" end
roster(M, 2, 3) -- others: 0 (host), 1, 3
run(M, 300)
status(M, 1, "alive", 0.7)
status(M, 3, "alive", 0.9)
status(M, 0, "alive", 1)
run(M, 600)
P = party_of(M)
local function seg_fill(r)
	local w = 0
	for _, sg in ipairs(r.segs) do if sg.fill.e.visible then w = w + sg.fill.e.w end end
	return w
end
local SEGW = 30 * 1024 * 1080 / (768 * 1920)
check(P.rows[1].name.e.text == "p0" and P.rows[2].name.e.text == "p1" and P.rows[3].name.e.text == "p3", "panel sorted by peer: host first (on top)")
check(P.rows[1].host.e.visible and not P.rows[2].host.e.visible, "host star only on the host")
check(P.rows[2].strip.e.tcolor % 16777216 == A.argb(1) % 16777216, "colour bar in the player's colour")
check(math.abs(seg_fill(P.rows[2]) - SEGW * 4 * 0.7) < 0.05 and P.rows[2].dist.e.text == "10 <st_coop_allies_m>", "health in segments + distance")
-- F3 T13: for 10 s after his checkpoint changed (coop_checkpoints.last_update) a tent instead of nothing
do
	local at = NOW
	M.env.coop_checkpoints = { last_update = function(id) return id == 501 and at or nil end }
	run(M, 600)
	check(P.rows[2].icon.e.visible and P.rows[2].icon.e.texture == "coop_hud_tent", "checkpoint changed: a tent on his row")
	check(not P.rows[3].icon.e.visible, "another player's row is untouched")
	run(M, 10000)
	check(not P.rows[2].icon.e.visible, "10 s later the tent is gone")
	M.env.coop_checkpoints = nil
end
-- down
status(M, 1, "down", 0.01, 45)
run(M, 600)
local h1 = M.spots["coop_ally_1@501"]
check(M.spots["coop_ally_down@501"] ~= nil and h1 ~= nil, "down: arrow kept + needs-help overlay")
check(h1:find("<st_coop_allies_down>", 1, true) and h1:find("0:4", 1, true) and h1:find("%c[255,226,58,48]", 1, true), "hint: red state label + bleed-out timer")
check(P.rows[2].icon.e.visible and P.rows[2].icon.e.texture == "coop_hud_cross" and P.rows[2].timer.e.text:find("0:4", 1, true),
	"panel: cross + countdown, no word")
local a0 = M.statics["mcoop_ally_down501"] and M.statics["mcoop_ally_down501"].tcolor
run(M, 300)
local a1 = M.statics["mcoop_ally_down501"] and M.statics["mcoop_ally_down501"].tcolor
check(a0 and a1 and a0 ~= a1 and math.floor(a1 / 16777216) >= 139, "minimap overlay pulses (alpha changes every frame)")
check(M.statics["lcoop_ally_down501"] ~= nil, "PDA overlay pulses too")
local b0 = P.rows[2].strip.e.tcolor
run(M, 200)
check(b0 ~= P.rows[2].strip.e.tcolor, "panel row breathes")
-- countdown runs from the report time
local before = P.rows[2].timer.e.text
run(M, 3000)
check(P.rows[2].timer.e.text ~= before, "countdown advances without new status: " .. P.rows[2].timer.e.text)
-- dead
status(M, 1, "dead", 0)
run(M, 600)
check(M.spots["coop_ally_1@501"] == nil and M.spots["coop_ally_down@501"] == nil and M.spots["coop_ally_dead@501"] ~= nil, "dead: grey marker replaces arrow and overlay")
check(P.rows[2].icon.e.texture == "coop_hud_skull" and P.rows[2].segs[1].fill.e.tcolor % 16777216 == M.env.GetARGB(0, 120, 120, 120),
	"panel: skull, grey segments")
-- spectating / respawning
status(M, 1, "spec", 1)
run(M, 600)
check(M.spots["coop_ally_dead@501"] ~= nil and P.rows[2].icon.e.texture == "coop_hud_eye", "spectating: grey marker, eye on the row")
status(M, 1, "alive", 1)
run(M, 600)
check(M.spots["coop_ally_dead@501"] == nil and M.spots["coop_ally_1@501"] ~= nil, "back alive: arrow back")
-- status that stops coming
run(M, 16000)
check(P.rows[2].icon.e.visible and P.rows[2].icon.e.texture == "coop_hud_warn", "no status for 15 s: amber ! on the row")
check(M.spots["coop_ally_1@501"] and M.spots["coop_ally_1@501"]:find("<st_coop_allies_unknown>", 1, true), "hint says no signal, arrow stays (position is live)")
-- engine survival state wins
M.env.coop.life_of = function(id) return id == 503 and "wounded" or "alive" end
M.env.coop.bleed_left = function(id) return id == 503 and 30000 or 0 end
status(M, 3, "alive", 0.9)
run(M, 600)
check(M.spots["coop_ally_down@503"] ~= nil and P.rows[3].timer.e.text:find("0:30", 1, true), "coop.life_of/bleed_left override the reported state")
check(P.rows[3].icon.e.visible and P.rows[3].icon.e.texture == "coop_hud_cross", "down -> cross back after another icon")
M.env.coop.life_of, M.env.coop.bleed_left = nil, nil
status(M, 3, "alive", 0.9)
run(M, 600)
check(M.spots["coop_ally_down@503"] == nil, "overlay gone when the engine state is gone and the report says alive")

-- ================================================================ network input
print("== network input")
local bad0 = M.hudm.status_of(3)
status(M, 3, "flying", 0.5)
check(M.hudm.status_of(3) == bad0, "unknown state rejected")
M.handlers["core.status"](M.env.coop_main.encode({ h = 0.5, s = "down", b = 99999 }), 3)
check(M.hudm.status_of(3).s == "down" and M.hudm.status_of(3).b == nil, "bleed time out of range dropped")
M.handlers["core.status"](M.env.coop_main.encode({ h = 0.5, s = "alive", b = 30 }), 3)
check(M.hudm.status_of(3).b == nil, "bleed time only with down")
M.handlers["core.status"](M.env.coop_main.encode({ h = 0.5, s = "alive" }), "x")
check(M.hudm.status_of(3).s == "alive", "sender must be a peer id")

-- ================================================================ own status
print("== own status")
M.actor.health = 0.01
M.env.coop.bleed_left = function(id) return id == 0 and 42400 or nil end
run(M, 1100)
local last = M.sent[#M.sent]
local t = M.env.coop_main.decode(last.payload)
check(last.name == "core.status" and t.s == "down" and t.b == 42, "own down state + bleed seconds sent")
M.env.coop.life_of = function(id) return id == 0 and "spectating" or nil end
run(M, 1100)
t = M.env.coop_main.decode(M.sent[#M.sent].payload)
check(t.s == "spec" and t.b == nil, "own spectating state from the engine")
M.env.coop.life_of, M.env.coop.bleed_left = nil, nil
M.actor.health = 1

-- ================================================================ leave / rejoin
print("== leave / rejoin")
table.remove(M.players, 2) -- p1 leaves
run(M, 600)
check(count_spots(M, "@501$") == 0 and P.rows[3].base.e.visible == false, "left: markers removed, panel shrinks")
M.players[#M.players + 1] = { id = 1, nick = "p1", avatar_id = 520, rtt = 30, is_self = false } -- back, new avatar
M.avatar(520, 70)
run(M, 300)
check(M.spots["coop_ally_1@520"] ~= nil and count_spots(M, "@501$") == 0, "rejoined: same colour (peer 1), marker on the new avatar")
-- peer id taken by somebody else while away -> other colour, nick stays
M.players[#M.players].id = 4
run(M, 300)
check(M.spots["coop_ally_4@520"] ~= nil and M.spots["coop_ally_1@520"] == nil, "new peer id -> its slot type, old type removed")
-- avatar not spawned yet: panel only
M.players[#M.players].avatar_id = nil
run(M, 600)
check(count_spots(M, "@520$") == 0 and P.rows[3].name.e.text == "p1" and P.rows[3].base.e.visible and not P.rows[3].dist.e.visible, "no avatar yet: no marker, panel entry without distance")

-- ================================================================ toggles, HUD, session end
print("== toggles")
local n_before = count_spots(M, ".")
M.hudm.set_spots_enabled(false)
run(M, 300)
check(n_before > 0 and next(M.spots) == nil, "markers off: all removed")
M.hudm.set_spots_enabled(true)
run(M, 300)
check(count_spots(M, ".") == n_before, "markers on again")
M.hudm.set_party_enabled(false)
run(M, 600)
local any = false
for _, c in ipairs(P.rows) do any = any or c.base.e.visible end
check(not any, "party panel off")
M.hudm.set_party_enabled(true)
run(M, 600)
M.hud_shown = false
run(M, 40)
any = false
for _, c in ipairs(P.rows) do any = any or c.base.e.visible end
check(not any, "hidden with the main HUD within a frame or two (inventory/PDA/scope)")
M.hud_shown = true
M.active = false
run(M, 100)
check(next(M.spots) == nil and party_of(M) == nil, "session over: markers removed, panel removed")

-- ================================================================ host, no status yet (owner 2026-10-20 22:55)
print("== host sees a client before any status")
M = machine(0)
roster(M, 0, 1) -- the host + client #1, standing 10 m away, nothing received yet
run(M, 600)
local HP = party_of(M)
check(HP and HP.rows[1].base.e.visible and HP.rows[1].name.e.text == "p1", "host: a row for the client from coop.players() alone")
check(HP.rows[1].dist.e.text ~= "" and not HP.rows[1].icon.e.visible, "host: distance shown, state alive (no icon): " .. HP.rows[1].dist.e.text)
local sent_status = 0
for _, e in ipairs(M.sent) do if e.name == "core.status" and (e.target == nil or e.target == -1) then sent_status = sent_status + 1 end end
check(sent_status >= 1, "host broadcasts its own status to everybody (target -1)")
M.handlers["core.status"](M.env.coop_main.encode({ h = 0.5, s = "alive", f = "stalker", i = "" }), 1)
run(M, 600)
check(M.env.coop_core_hud.status_of(1) ~= nil and math.abs(seg_fill(HP.rows[1]) - SEGW * 2) < 0.05, "host accepts a status from a client (from = its peer id)")
M.env.coop_core_hud.print_status()
check(count_log(M, "hud: panel visible, 1 other player(s): #1 p1 alive, 10 m, status 1 s ago") == 1, "status line lists the panel's players")
M.hud_shown = false
M.env._GUIs = { UICoopChat = { path = "coop_core_chat" } }
run(M, 600)
M.env.coop_core_hud.print_status()
check(count_log(M, "hud: panel hidden: UI UICoopChat registered") == 1, "status line says why the panel is hidden")
M.hud_shown, M.env._GUIs = nil, nil

-- ================================================================ cadence
print("== cadence")
M = machine(0)
M.env.coop.spot_is_local = function(t) return t:sub(1, 5) == "coop_" end
roster(M, 0, 3)
local syncs, refreshes = 0, 0
local orig_sync = M.map.sync
M.map.sync = function(...) syncs = syncs + 1 return orig_sync(...) end
run(M, 100)
local PP = party_of(M)
local orig_refresh = PP.Refresh
PP.Refresh = function(...) refreshes = refreshes + 1 return orig_refresh(...) end
syncs = 0
run(M, 2000)
check(syncs >= 9 and syncs <= 11, "markers synced ~5 Hz (" .. syncs .. " in 2 s)")
check(refreshes >= 3 and refreshes <= 5, "panel refreshed ~2 Hz (" .. refreshes .. " in 2 s)")
local adds = 0
for _, op in ipairs(M.spot_ops) do if op:sub(1, 1) == "+" then adds = adds + 1 end end
check(adds == 3, "steady state: no re-adding of spots (" .. adds .. " adds)")

-- ================================================================ layout at several resolutions
print("== layout")
local report = {}
for _, res in ipairs({ { 1920, 1080 }, { 2560, 1440 }, { 3840, 2160 }, { 1280, 720 }, { 1024, 768 }, { 1600, 1200 }, { 3440, 1440 } }) do
	DEV.width, DEV.height = res[1], res[2]
	M = machine(0)
	roster(M, 0, 7)
	run(M, 600)
	local PL = party_of(M)
	local top, bottom = PL.rows[1].base.e.y, PL.rows[7].base.e.y + 22
	local kx = 1024 * res[2] / (768 * res[1])
	check(math.abs(PL.rows[1].base.e.x - 18 * kx) < 0.01 and math.abs(bottom - 590) < 0.01 and top > 340,
		("%dx%d, 7 players: rows y %.0f..%.0f units, above the own HUD"):format(res[1], res[2], top, bottom))
	report[#report + 1] = ("| %dx%d | 7 | x %.1f units | y %.0f..%.0f units |"):format(res[1], res[2], PL.rows[1].base.e.x, top, bottom)
end
DEV.width, DEV.height = 1920, 1080
local fh2 = assert(io.open(OUT .. "layout_report.txt", "wb"))
fh2:write(table.concat(report, "\n") .. "\n")
fh2:close()

-- HUD v2: the stock companion column is not moved any more (the old panel's shift is gone)
print("== companions")
M = machine(0)
roster(M, 0, 4)
local chud = { dialog = window("comp", { x = 949, y = 47 }), companion_info = {} }
M.env.axr_companions = { HUD = chud }
run(M, 600)
check(chud.dialog.x == 949, "companion column stays where it is")

local unk = {}
for k in pairs(UNKNOWN) do unk[#unk + 1] = tostring(k) end
table.sort(unk)
check(#unk == 0, "no reads of undefined globals (" .. table.concat(unk, ", ") .. ")")
print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
-- module fields after the whole run (accidental globals would show up here)
for _, name in ipairs(SCRIPTS) do
	local keys = {}
	for k in pairs(M.env[name]) do keys[#keys + 1] = k end
	table.sort(keys)
	print("  fields " .. name .. ": " .. table.concat(keys, " "))
end
