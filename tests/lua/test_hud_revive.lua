-- Anomaly Coop HUD v2 part 2 (docs\HUD_V2.md, "Поднятие союзника") stub test: the revive overlay of
-- scripts\coop_hud_revive.script on top of coop.revive_progress(): the reviver's ring of 3 segments, the downed player's
-- bleed-out ring, the lifter's ring, the give-up ring, cancel, success, nothing outside a session, the assets it names.
-- Real scripts (coop_allies for the palette, coop_hud_revive), real ui_coop_revive.xml / textures_descr / strings / ltx.
-- Run: tools\test_lua.cmd hud_revive   (VERBOSE=1 for logs)
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

-- ---------------------------------------------------------------- tiny readers
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

local function ltx(paths)
	local data = {}
	for _, path in ipairs(paths) do
		local sec
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
	end
	return {
		section_exist = function(_, s) return data[s] ~= nil end,
		line_exist = function(_, s, k) return data[s] ~= nil and data[s][k] ~= nil end,
		r_string = function(_, s, k) return data[s][k] end,
		data = data,
	}
end

local function string_ids(file)
	local ids = {}
	for id, text in (readfile(file) or ""):gmatch('<string id="([%w_]+)">%s*<text>(.-)</text>') do ids[id] = text end
	return ids
end

local XML = { ["ui_coop_revive.xml"] = xml_nodes(ROOT .. "configs/ui/ui_coop_revive.xml") }
local TEXTURE_OF = {} -- "coop_revive:arc" -> "coop_rev_arc"
for tag, tex in (readfile(ROOT .. "configs/ui/ui_coop_revive.xml") or ""):gmatch("<([%w_]+)[^>]*>%s*<texture>([%w_]+)</texture>") do
	TEXTURE_OF["coop_revive:" .. tag] = tex
end
local INI = ltx({ ROOT .. "configs/mod_system_coop.ltx", ROOT .. "configs/mod_system_coop_revive.ltx" })
local STR_ENG = string_ids(ROOT .. "configs/text/eng/st_coop_revive.xml")
local STR_RUS = string_ids(ROOT .. "configs/text/rus/st_coop_revive.xml")
local MISSING = {}

-- ---------------------------------------------------------------- engine stand-ins
local NOW = 100000
local DEV = { width = 1920, height = 1080 }
local CREATED = 0 -- windows made by the XML stub: after the overlay is built, a frame never makes one

local function window(path, a)
	a = a or {}
	CREATED = CREATED + 1
	local w = { path = path, children = {}, visible = true, text = "", heading = 0, texture = TEXTURE_OF[path],
		x = tonumber(a.x) or 0, y = tonumber(a.y) or 0, w = tonumber(a.width) or 0, h = tonumber(a.height) or 0 }
	function w:SetText(t) self.text = tostring(t) end
	function w:SetTextColor(c) self.color = c end
	function w:SetWndPos(v) self.x, self.y = v.x, v.y end
	function w:SetWndSize(v) self.w, self.h = v.x, v.y end
	function w:Show(b) self.visible = b end
	function w:IsShown() return self.visible end
	function w:InitTexture(t) self.texture = t end
	function w:SetStretchTexture(b) self.stretch = b end
	function w:SetTextureColor(c) self.tcolor = c; self.tcolor_calls = (self.tcolor_calls or 0) + 1 end
	function w:EnableHeading(b) self.heading_on = b end
	function w:SetHeading(r) self.heading = r end
	function w:GetHeading() return self.heading end
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
	x.InitStatic, x.InitTextWnd = init, init
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

local VecMT = {}
VecMT.__index = VecMT
local function vec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VecMT) end

-- A machine: the engine stand-ins and the real scripts. opts.coop = false: an exe without the co-op namespace.
local function machine(self_peer, opts)
	opts = opts or {}
	local M = { peer = self_peer, log = {}, cb = {}, cb_added = {}, hud = {}, sounds = {}, panel = {}, files = {}, polls = 0 }
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
	local STR = opts.rus and STR_RUS or STR_ENG
	env.game = { translate_string = function(id) return STR[id] or id end }
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.vector = function() return vec() end
	env.CScriptXmlInit = function() return xml_stub() end
	env.device = function()
		if M.break_device then error("device() is gone") end
		return { width = DEV.width, height = DEV.height, cam_pos = vec(0, 0, 0), cam_dir = vec(0, 0, 1), f_time_delta = 0.016 }
	end
	env.class = class_stub
	env.super = function() end
	env.CUIScriptWnd = CUIScriptWnd
	env.get_hud = function()
		return { AddDialogToRender = function(_, w) M.hud[w] = true end, RemoveDialogToRender = function(_, w) M.hud[w] = nil end }
	end
	env.main_hud_shown = function() return M.hud_shown ~= false end
	env.ini_sys = opts.ini or INI
	env.RegisterScriptCallback = function(name, f)
		M.cb[name] = M.cb[name] or {}
		table.insert(M.cb[name], f)
	end
	env.AddScriptCallback = function(name) M.cb_added[#M.cb_added + 1] = name end
	env.sound_object = function(path)
		local s = { path = path }
		function s:play() M.sounds[#M.sounds + 1] = { path = path, volume = self.volume, frequency = self.frequency } end
		return s
	end
	env.getFS = function() return { exist = function(_, alias, file) return M.files[file] == true end } end
	env.db = { actor = { id = function() return 0 end } }
	M.active = opts.active ~= false
	if opts.coop ~= false then
		env.coop = {
			is_active = function() return M.active end,
			is_host = function() return M.active and self_peer == 0 end,
			is_client = function() return M.active and self_peer ~= 0 end,
			is_live = function() return M.active end,
			self_id = function() return self_peer end,
			revive_progress = function()
				M.polls = M.polls + 1
				if M.fail then error("the engine is gone") end
				return M.p
			end,
		}
	end
	env.coop_core_hud = { set_revive = function(peer, frac, by) M.panel[#M.panel + 1] = { peer = peer, frac = frac, by = by } end }
	for _, name in ipairs({ "coop_allies", "coop_hud_revive" }) do
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
		end
	end
	M.A, M.R = env.coop_allies, env.coop_hud_revive
	for _, name in ipairs({ "coop_allies", "coop_hud_revive" }) do
		local m = env[name]
		if rawget(m, "on_game_start") then
			local ok, e = pcall(m.on_game_start)
			if not ok then print("  on_game_start " .. name .. ": " .. tostring(e)) end
		end
	end
	return M
end

local function fire(M, name, ...)
	for _, f in ipairs(M.cb[name] or {}) do f(...) end
end

-- frames: 16 ms each for `ms` milliseconds
local function run(M, ms)
	local t_end = NOW + (ms or 0)
	repeat
		fire(M, "actor_on_update")
		for w in pairs(M.hud) do w:Update() end
		NOW = NOW + 16
	until NOW >= t_end
end

local function win(M) return M.R.get_window() end

-- Geometry dump for a visual check against docs\hud\revive_concept.png (temp\lua\hud_revive_<name>.txt, read by
-- temp\revive\render_dump.py): every visible static / text window under the overlay's root, in 1024x768 units, tab separated.
local function dump(name, M)
	local fh = io.open("temp/lua/hud_revive_" .. name .. ".txt", "wb")
	if not fh then return end
	local TAB, NL = string.char(9), string.char(10)
	local function walk(node, ox, oy)
		for _, c in ipairs(node.children or {}) do
			if c.visible then
				local ax, ay = ox + c.x, oy + c.y
				local text = (c.text or ""):gsub("%c", " ")
				fh:write(table.concat({ c.path, ("%.3f"):format(ax), ("%.3f"):format(ay), ("%.3f"):format(c.w), ("%.3f"):format(c.h),
					tostring(c.tcolor or ""), tostring(c.color or ""), c.texture or "", text, ("%.4f"):format(c.heading or 0) }, TAB) .. NL)
				walk(c, ax, ay)
			end
		end
	end
	fh:write(("screen" .. TAB .. "%d" .. TAB .. "%d" .. NL):format(DEV.width, DEV.height))
	walk(win(M).root, 0, 0)
	fh:close()
end

local function alpha_of(c) return c and math.floor(c / 16777216) or nil end
local function rgb_of(c)
	if not c then return nil end
	local v = c % 16777216
	return math.floor(v / 65536), math.floor(v / 256) % 256, v % 256
end
local function is_rgb(c, rgb)
	local r, g, b = rgb_of(c)
	return r == rgb[1] and g == rgb[2] and b == rgb[3]
end

-- sounds that are not the soft segment click (the one with `path`, if given)
local function other_sounds(M, path)
	local n = 0
	for _, snd in ipairs(M.sounds) do
		if snd.path ~= "interface\\inv_properties" and (path == nil or snd.path == path) then n = n + 1 end
	end
	return n
end

-- pieces of a ring that are on screen (shown, and not fully transparent)
local function lit(ring)
	local n = 0
	for _, p in ipairs(ring.pieces) do
		if p.w.e.visible and (alpha_of(p.w.e.tcolor) or 0) > 0 then n = n + 1 end
	end
	return n
end

local function hold(M, f, extra)
	local rev = { peer = 1, avatar_id = 501, nick = "guest", progress = f, ms_left = (1 - f) * 3000, item = "medkit",
		section = "medkit_army", sent = false }
	for k, v in pairs(extra or {}) do rev[k] = v end
	M.p = { reviving = rev }
end

local C_RED, C_AMBER, C_WHITE = { 232, 85, 58 }, { 240, 176, 76 }, { 244, 245, 246 }
local KX = function() return 1024 * DEV.height / (768 * DEV.width) end

-- ================================================================ 1. what the script names exists
print("== assets")
local c_before = CREATED
local M0 = machine(0)
run(M0, 200)
local OVERLAY_WINDOWS = CREATED - c_before
local W0 = win(M0)
check(W0 ~= nil, "in a session the overlay is on the HUD")
check(#MISSING == 0, "every XML node the script asks for exists in ui_coop_revive.xml (" .. table.concat(MISSING, ", ") .. ")")
check(next(XML["ui_coop_revive.xml"]) ~= nil, "ui_coop_revive.xml is read")
do
	local x16 = xml_nodes(ROOT .. "configs/ui/ui_coop_revive_16.xml")
	local same = true
	for path, a in pairs(XML["ui_coop_revive.xml"]) do
		if not x16[path] then same = false end
		for k, v in pairs(a) do if x16[path] and x16[path][k] ~= v then same = false end end
	end
	check(same, "ui_coop_revive_16.xml has the same nodes and attributes")
end

local descr = readfile(ROOT .. "configs/ui/textures_descr/ui_coop_revive.xml") or ""
local DESCR = {}
for id, x, y, w, h in descr:gmatch('<texture id="([%w_]+)" x="(%d+)" y="(%d+)" width="(%d+)" height="(%d+)"/>') do
	DESCR[id] = { tonumber(x), tonumber(y), tonumber(w), tonumber(h) }
end
local xml_src = readfile(ROOT .. "configs/ui/ui_coop_revive.xml") or ""
local used, undefined = 0, {}
for id in xml_src:gmatch("<texture>([%w_]+)</texture>") do
	used = used + 1
	if not DESCR[id] then undefined[#undefined + 1] = id end
end
check(used >= 12 and #undefined == 0, "every texture of the XML is in textures_descr/ui_coop_revive.xml (" .. used .. " used, missing: " .. table.concat(undefined, ", ") .. ")")
local inside = true
for id, r in pairs(DESCR) do
	if r[1] < 0 or r[2] < 0 or r[1] + r[3] > 256 or r[2] + r[4] > 256 then inside = false end
end
check(inside, "every texture rect is inside the 256x256 atlas")
local dds = readfile(ROOT .. "textures/ui/coop/ui_coop_revive.dds") or ""
local function u32(s, pos) local a, b, c, d = s:byte(pos, pos + 3) return a + b * 256 + c * 65536 + d * 16777216 end
check(#dds == 128 + 256 * 256 * 4 and dds:sub(1, 4) == "DDS " and u32(dds, 13) == 256 and u32(dds, 17) == 256,
	"ui_coop_revive.dds is a 256x256 A8R8G8B8 DDS without mips (" .. #dds .. " bytes)")
local rev_script = readfile(ROOT .. "scripts/coop_hud_revive.script") or ""
local sids = {}
for id in rev_script:gmatch('"(st_coop_revive_[%w_]+)"') do sids[id] = true end
sids["st_coop_revive_item_medkit"], sids["st_coop_revive_item_stimpack"] = true, true -- completed at run time
sids["st_coop_revive_item_"] = nil
local miss_e, miss_r = {}, {}
for id in pairs(sids) do
	if not STR_ENG[id] then miss_e[#miss_e + 1] = id end
	if not STR_RUS[id] then miss_r[#miss_r + 1] = id end
end
check(next(sids) ~= nil and #miss_e == 0 and #miss_r == 0, "every st_coop_revive_* id of the script is in eng and rus (" .. table.concat(miss_e, ",") .. "|" .. table.concat(miss_r, ",") .. ")")
check((STR_ENG.st_coop_revive_hold or ""):find("$$ACTION_USE$$", 1, true) and (STR_RUS.st_coop_revive_hold or ""):find("$$ACTION_USE$$", 1, true)
	and (STR_ENG.st_coop_revive_give_up or ""):find("$$ACTION_USE$$", 1, true) and (STR_RUS.st_coop_revive_give_up or ""):find("$$ACTION_USE$$", 1, true),
	"the key hints take the use key from the engine ($$ACTION_USE$$), not a hard-coded F")
do
	local raw = readfile(ROOT .. "configs/text/rus/st_coop_revive.xml") or ""
	check(raw:find("\239\238\228\237\232\236\224\254", 1, true) ~= nil, "rus strings are cp1251 (\"поднимаю\")")
end
local lay = M0.R.layout()
local same_keys = true
for k, v in pairs(M0.R.DEFAULTS) do
	if not near(lay[k], v, 1e-9) then same_keys = false end
	if INI.data.coop_hud_revive[k] == nil then same_keys = false end
end
for k in pairs(INI.data.coop_hud_revive) do
	if M0.R.DEFAULTS[k] == nil then same_keys = false end
end
check(same_keys, "[coop_hud_revive] in mod_system_coop_revive.ltx holds exactly the script's defaults")
check(M0.R.PIECES == 60 and #M0.R.piece_table("full") == 60 and #M0.R.piece_table("segments") == 57, "60 pieces of 6 deg, 3 x 19 in the revive ring")

-- ================================================================ 2. the pure parts
print("== pure parts")
local R = M0.R
check(R.seg_color(1)[1] == 232 and R.seg_color(2)[1] == 240 and R.seg_color(3)[1] == 244, "segments: red, amber, white")
check(R.seg_of(0) == 1 and R.seg_of(0.33) == 1 and R.seg_of(0.34) == 2 and R.seg_of(0.67) == 3 and R.seg_of(1) == 3 and R.seg_of(5) == 3 and R.seg_of(-1) == 1,
	"seg_of: a second each, clamped")
check(R.segments_done(0) == 0 and R.segments_done(0.33) == 0 and R.segments_done(1 / 3) == 1 and R.segments_done(0.7) == 2 and R.segments_done(1) == 3,
	"segments_done counts completed seconds")
check(R.format_timer(42000) == "0:42" and R.format_timer(41001) == "0:42" and R.format_timer(60000) == "1:00" and R.format_timer(0) == "0:00"
	and R.format_timer(-5) == "0:00" and R.format_timer(nil) == "0:00" and R.format_timer(125000) == "2:05", "timer: seconds rounded up, m:ss")
check(near(R.alpha_step(0, 1, 60, 120, 200), 0.5) and R.alpha_step(0.9, 1, 60, 120, 200) == 1 and near(R.alpha_step(1, 0, 100, 120, 200), 0.5)
	and R.alpha_step(0.1, 0, 100, 120, 200) == 0 and R.alpha_step(0.5, 1, 100, 0, 200) == 1, "alpha_step: 120 ms in, 200 ms out, never past the target")
check(near(R.piece_light(0, 3), 0.5) and R.piece_light(0, 6) == 1 and R.piece_light(0, 100) == 1 and R.piece_light(60, 30) == 0 and R.piece_light(60, 63) > 0.49,
	"piece_light: the piece the fill passes blends in")
local dx, dy = R.dot_offset(0, 26)
local ex, ey = R.dot_offset(0.25, 26)
local fx, fy = R.dot_offset(0.5, 26)
local gx, gy = R.dot_offset(0.75, 26)
check(near(dx, 0, 1e-9) and near(dy, -26, 1e-9) and near(ex, 26, 1e-9) and near(ey, 0, 1e-9) and near(fx, 0, 1e-9) and near(fy, 26, 1e-9)
	and near(gx, -26, 1e-9), "the dot runs clockwise from 12 o'clock: top, right, bottom, left")
local pt = R.piece_table("segments")
check(pt[1].a0 == 3 and pt[19].a0 == 111 and pt[20].a0 == 123 and pt[38].a0 == 231 and pt[39].a0 == 243 and pt[57].a0 == 351 and pt[19].seg == 1 and pt[20].seg == 2 and pt[57].seg == 3,
	"the revive ring's pieces: a 6 deg gap after each second")

-- ================================================================ 3. the one who revives
print("== reviver")
local M = machine(0)
run(M, 200)
local w = win(M)
check(w and not w.shown_rev and not w.shown_down and not w.g_rev.visible and not w.g_down.visible and lit(w.ring) == 0,
	"idle in a session: both groups hidden, nothing lit")
check(M.polls > 5, "the overlay asks the engine every frame (the engine's own text steps aside while it does) (" .. M.polls .. ")")
check(M.cb["coop_revive_done"] ~= nil and M.cb_added[1] == "coop_revive_done" and M.cb["actor_on_update"] ~= nil and M.cb["actor_on_net_destroy"] ~= nil,
	"the callback coop_revive_done is declared and handled")

hold(M, 0)
run(M, 16)
check(w.g_rev.visible and alpha_of(w.ring.shadow.e.tcolor) < 255, "a hold starts: the ring fades in (120 ms), not at once")
run(M, 200)
check(w.g_rev.visible and not w.g_down.visible, "reviving: the reviver's group is on, the downed player's is not")
check(lit(w.ring) == 0, "0 %: no segment lit, the dim ring only")
check(alpha_of(w.ring.track.e.tcolor) == math.floor(255 * 0.28 + 0.5) and is_rgb(w.ring.track.e.tcolor, C_WHITE), "the track under it: white at 0.28")
local kx = KX()
local d = 2 * 26 / (57 / 64)
check(near(w.ring.pieces[1].w.e.w, d, 1e-6) and near(w.ring.pieces[1].w.e.h, d, 1e-6) and near(w.ring.pieces[1].w.e.x, 512 - d / 2, 1e-6)
	and near(w.ring.pieces[1].w.e.y, 384 - d / 2, 1e-6), "a turned piece: a square box of 2R / (57/64) units centred on the crosshair")
check(near(w.ring.track.e.w, d * kx, 1e-6) and near(w.ring.track.e.h, d, 1e-6) and near(w.ring.track.e.x, 512 - d * kx / 2, 1e-6),
	"the track: the same box squeezed across (kx " .. string.format("%.3f", kx) .. ")")
check(near(w.ring.pieces[1].w.e.heading, -math.rad(6), 1e-9) and near(w.ring.pieces[20].w.e.heading, -math.rad(126), 1e-9)
	and w.ring.pieces[1].w.e.heading_on, "pieces turn clockwise by their middle (heading = -angle)")
check(near(w.dot.e.x, 512 - 6 * kx / 2, 1e-6) and near(w.dot.e.y, 384 - 26 - 3, 1e-6) and is_rgb(w.dot.e.tcolor, C_RED),
	"the running dot at 12 o'clock, red")

hold(M, 1 / 3)
run(M, 16)
check(lit(w.ring) == 19, "a third: the first segment is full (19 pieces), the second not started (" .. lit(w.ring) .. ")")
local p1, p19, p20 = w.ring.pieces[1].w.e, w.ring.pieces[19].w.e, w.ring.pieces[20].w.e
check(is_rgb(p1.tcolor, C_RED) and is_rgb(p19.tcolor, C_RED) and alpha_of(p1.tcolor) == 255 and not p20.visible, "the first second is red, opaque")
hold(M, 0.5)
run(M, 16)
check(lit(w.ring) == 29, "half: 19 + 10 pieces (29, got " .. lit(w.ring) .. ")")
check(is_rgb(w.ring.pieces[20].w.e.tcolor, C_AMBER) and is_rgb(w.ring.pieces[29].w.e.tcolor, C_AMBER), "the second second is amber")
check(near(w.dot.e.x, 512 + 0 - 6 * kx / 2, 1e-6) and near(w.dot.e.y, 384 + 26 - 3, 1e-6) and is_rgb(w.dot.e.tcolor, C_AMBER), "the dot at the bottom, amber")
hold(M, 0.9)
run(M, 16)
check(lit(w.ring) == 52, "90 %: 19 + 19 + 14 pieces (52, got " .. lit(w.ring) .. ")")
check(is_rgb(w.ring.pieces[39].w.e.tcolor, C_WHITE) and is_rgb(w.dot.e.tcolor, C_WHITE), "the third second is white")
hold(M, 0.25)
run(M, 16)
check(near(w.dot.e.x, 512 + 26 * kx - 6 * kx / 2, 1e-6) and near(w.dot.e.y, 384 - 3, 1e-6) and lit(w.ring) == 15,
	"a quarter: 15 pieces, the dot on the right of the ring (" .. lit(w.ring) .. ")")
hold(M, 0.8)
run(M, 200)
dump("reviver", M)
hold(M, 0.9)
run(M, 16)

-- texts: his nick in his colour, the line, the hint
check(w.t_nick.tx.e.text == "guest" and is_rgb(w.t_nick.tx.e.color, { M.A.color(1) }) and alpha_of(w.t_nick.tx.e.color) == 255,
	"under the ring: the downed player's nick in his palette colour")
check(w.t_line.tx.e.text == "reviving \183 medkit" and w.t_line.tx.e.visible, "\"reviving . medkit\"")
check(w.t_hint.tx.e.text == STR_ENG.st_coop_revive_hold and is_rgb(w.t_hint.tx.e.color, { 175, 177, 175 }), "\"hold [F]\" dim")
check(w.t_nick.sh.e.text == "guest" and alpha_of(w.t_nick.sh.e.color) < 255 and is_rgb(w.t_nick.sh.e.color, { 0, 0, 0 })
	and near(w.t_nick.sh.e.x - w.t_nick.tx.e.x, 1024 / DEV.width, 1e-6), "a 1 px shadow under the text")
check(w.badge.medkit.e.visible and not w.badge.stimpack.e.visible and near(w.badge.medkit.e.y, 384 - 26 - 8 - 14, 1e-6)
	and near(w.badge.medkit.e.x, 512 - 20 * kx / 2, 1e-6), "the medkit badge above the ring")
hold(M, 0.4, { item = "stimpack", section = "stimpack_army" })
run(M, 16)
check(not w.badge.medkit.e.visible and w.badge.stimpack.e.visible and w.t_line.tx.e.text == "reviving \183 stimpack", "a stimpack: its badge and word")
hold(M, 0.4, { nick = "Gu%c[255,1,2,3]est" })
run(M, 16)
check(not w.t_nick.tx.e.text:find("%", 1, true), "a nick cannot carry a colour tag into the text")
hold(M, 0.4, { nick = "an_extremely_long_nickname_indeed" })
run(M, 16)
check(#w.t_nick.tx.e.text <= 24, "a long nick is cut (" .. #w.t_nick.tx.e.text .. ")")

-- cancel: let go
hold(M, 0.6)
run(M, 200)
M.p = nil
run(M, 96)
local a_mid = alpha_of(w.ring.pieces[1].w.e.tcolor)
check(w.g_rev.visible and a_mid and a_mid > 0 and a_mid < 255, "let go: the ring fades out, not gone at once (alpha " .. tostring(a_mid) .. ")")
run(M, 200)
check(not w.g_rev.visible and lit(w.ring) == 0, "gone in 0.2 s")
check(M.panel[#M.panel] and M.panel[#M.panel].peer == 1 and M.panel[#M.panel].frac == nil, "the team panel is told the fill ended")

-- the team panel while the fill goes: the target's segments in my colour
M.panel = {}
hold(M, 0.2)
run(M, 16)
hold(M, 0.4)
run(M, 16)
local last = M.panel[#M.panel]
check(#M.panel == 2 and M.panel[1].peer == 1 and near(M.panel[1].frac, 0.2, 1e-9) and last.peer == 1 and near(last.frac, 0.4, 1e-9) and last.by == 0,
	"coop_core_hud.set_revive(target, fill, my peer) when the fill moves (2 calls, not one per frame)")
run(M, 100)
check(#M.panel == 2, "the same fill is not sent again")
M.p = nil
run(M, 300)

-- soft clicks at each segment
print("== clicks")
M.sounds = {}
hold(M, 0.1)
run(M, 48)
check(#M.sounds == 0, "no click before the first second ends")
hold(M, 0.34)
run(M, 48)
check(#M.sounds == 1 and M.sounds[1].path == "interface\\inv_properties" and M.sounds[1].volume < 0.3 and near(M.sounds[1].frequency, 1), "the first segment: one quiet stock click")
hold(M, 0.67)
run(M, 48)
check(#M.sounds == 2 and near(M.sounds[2].frequency, 1.18), "the second: a higher click")
hold(M, 1, { sent = true })
run(M, 160)
check(#M.sounds == 3 and near(M.sounds[3].frequency, 1.36), "the third, and no more while the ring waits full (" .. #M.sounds .. ")")
M.p = nil
run(M, 300)
hold(M, 0.02)
run(M, 48)
hold(M, 0.4)
run(M, 48)
check(#M.sounds == 4, "a new hold clicks again from the first segment (" .. #M.sounds .. ")")
M.p = nil
run(M, 300)

-- success
print("== success")
M.sounds, M.panel = {}, {}
M.files["interface\\item_usage\\medkit_use.ogg"] = true
hold(M, 1, { sent = true })
run(M, 160)
check(w.g_rev.visible and lit(w.ring) == 57 and is_rgb(w.ring.pieces[1].w.e.tcolor, C_RED), "the hold is over, the Request is out: the ring stays full, waiting")
check(M.panel[#M.panel] and near(M.panel[#M.panel].frac, 1, 1e-9), "the panel's segments are full too")
local n_before = #M.sounds
fire(M, "coop_revive_done", 1, "medkit_army")
check(#M.sounds == n_before + 1 and M.sounds[#M.sounds].path == "interface\\item_usage\\medkit_use" and M.sounds[#M.sounds].volume == 0.5,
	"the host revived him: the medkit sound (GAMMA's FDDA file)")
M.p = nil -- the engine drops `reviving` once the Done came
run(M, 16)
check(w.g_rev.visible and is_rgb(w.ring.pieces[1].w.e.tcolor, C_WHITE) and is_rgb(w.ring.pieces[40].w.e.tcolor, C_WHITE) and is_rgb(w.dot.e.tcolor, C_WHITE),
	"a white flash over the full ring")
run(M, 120)
local a_flash = alpha_of(w.ring.pieces[1].w.e.tcolor)
check(w.g_rev.visible and a_flash and a_flash > 0 and a_flash < 255, "the flash fades (alpha " .. tostring(a_flash) .. ")")
run(M, 500)
check(not w.g_rev.visible and lit(w.ring) == 0, "gone after done_ms (450)")
check(M.panel[#M.panel] and M.panel[#M.panel].frac == nil, "the panel is released")
M.files = {}
M.sounds = {}
hold(M, 1, { sent = true })
run(M, 100)
fire(M, "coop_revive_done", 1, "stimpack_army")
check(other_sounds(M, "interface\\inv_attach_addon") == 1 and other_sounds(M) == 1, "no FDDA sound file: a stock click instead")
M.p = nil
run(M, 700)

-- refused: no Done
M.sounds = {}
hold(M, 1, { sent = true })
run(M, 100)
M.p = nil
run(M, 100)
check(w.g_rev.visible and (alpha_of(w.ring.pieces[1].w.e.tcolor) or 0) < 255 and is_rgb(w.ring.pieces[1].w.e.tcolor, C_RED) and other_sounds(M) == 0,
	"refused (no Done): the ring just fades out in its own colours, no flash, no sound")
run(M, 300)
check(not w.g_rev.visible, "and is gone")

-- a hidden HUD (inventory, PDA, scope): no overlay of the reviver
M.hud_shown = false
hold(M, 0.5)
run(M, 300)
check(not w.g_rev.visible, "HUD hidden (inventory open): no ring over it")
M.hud_shown = true
run(M, 200)
check(w.g_rev.visible, "HUD back: the ring is there")
M.p = nil
run(M, 300)

-- ================================================================ 4. the downed player
print("== downed")
M.p = { bleed = { left_ms = 42000, total_ms = 60000 } }
run(M, 16)
check(w.g_down.visible and alpha_of(w.bleed.shadow.e.tcolor) < 255, "down: the overlay fades in")
run(M, 200)
local red = { M.A.state_color("down") }
check(w.g_down.visible and not w.g_rev.visible, "down: the downed player's group is on")
check(w.t_timer.tx.e.text == "0:42" and is_rgb(w.t_timer.tx.e.color, red) and w.t_timer.tx.e.visible, "\"0:42\" in the palette's red")
check(near(w.t_timer.tx.e.y, 384 - 30 - 6 - 18, 1e-6), "the timer over the outer ring")
check(lit(w.bleed) == 42 and is_rgb(w.bleed.pieces[1].w.e.tcolor, red), "the bleed-out ring: 70 % of it still bright (42 of 60 pieces), red")
check(alpha_of(w.bleed.track.e.tcolor) == math.floor(255 * 0.28 + 0.5) and is_rgb(w.bleed.track.e.tcolor, red), "the melted part is the dim track")
check(is_rgb(w.vig.e.tcolor, red) and alpha_of(w.vig.e.tcolor) == math.floor(255 * (0.55 + 0.3 * 0.3) + 0.5),
	"the red vignette, 0.64 at 70 % of the bleed-out left")
check(w.cross.e.visible and is_rgb(w.cross.e.tcolor, C_WHITE) and near(w.cross.e.w, 14 * kx, 1e-6), "a white plus in the middle")
check(lit(w.lift) == 0 and not w.t_by.tx.e.visible and not w.t_hang.tx.e.visible, "nobody revives him: no inner ring, no \"is reviving you\"")
check(w.t_give.tx.e.text == STR_ENG.st_coop_revive_give_up and near(w.t_give.tx.e.y, 384 + 150, 1e-6), "low on the screen: \"hold [F] to give up\"")
check(lit(w.give) == 0, "no give-up ring yet")
M.p = { bleed = { left_ms = 6000, total_ms = 60000 } }
run(M, 16)
check(alpha_of(w.vig.e.tcolor) == math.floor(255 * (0.55 + 0.3 * 0.9) + 0.5) and lit(w.bleed) == 6 and w.t_timer.tx.e.text == "0:06",
	"a few seconds left: the vignette is stronger, the ring nearly gone, \"0:06\"")
M.p = { bleed = { left_ms = 42000, total_ms = 60000 } }
run(M, 16)

-- a teammate holds USE on me
M.p = { bleed = { left_ms = 40000, total_ms = 60000 }, revived_by = { peer = 2, avatar_id = 502, nick = "pl_a", progress = 0.5, ms_left = 1500 } }
run(M, 16)
check(alpha_of(w.lift.pieces[1].w.e.tcolor) < 255, "his ring fades in")
run(M, 200)
local sage = { M.A.color(2) }
dump("downed_lifted", M)
check(lit(w.lift) == 30 and is_rgb(w.lift.pieces[1].w.e.tcolor, sage) and is_rgb(w.lift.track.e.tcolor, sage), "the inner ring in his colour, half full (30 of 60)")
check(near(w.lift.pieces[1].w.e.w, 2 * 24 / (57 / 64), 1e-6), "thinner, inside the outer one (R 24)")
check(w.t_by.tx.e.text == "pl_a  " .. STR_ENG.st_coop_revive_you and is_rgb(w.t_by.tx.e.color, sage) and w.t_by.tx.e.visible,
	"\"<nick> is reviving you\" in his colour")
check(w.t_hang.tx.e.text == STR_ENG.st_coop_revive_hang_on and w.t_hang.tx.e.visible, "\"hang on\"")
M.p = { bleed = { left_ms = 39000, total_ms = 60000 }, revived_by = { peer = 2, avatar_id = 502, nick = "pl_a", progress = 1, ms_left = 0 } }
run(M, 16)
check(lit(w.lift) == 60, "full when the hold is over")
M.p = { bleed = { left_ms = 39000, total_ms = 60000 } }
run(M, 300)
check(lit(w.lift) == 0 and not w.t_by.tx.e.visible and not w.t_hang.tx.e.visible and not w.lift_shown, "he let go: the inner ring and the lines are gone")

-- give up
M.p = { bleed = { left_ms = 30000, total_ms = 60000 }, give_up = { progress = 0.5, ms_left = 1500 } }
run(M, 16)
check(lit(w.give) == 30 and is_rgb(w.give.pieces[1].w.e.tcolor, { 150, 150, 150 }) and w.t_give.tx.e.text == STR_ENG.st_coop_revive_giving_up,
	"holding the key to give up: a grey ring fills (30 of 60), the line says so")
check(near(w.give.pieces[1].w.e.y, 384 + 150 - 8 - 9 - (2 * 9 / (57 / 64)) / 2, 1e-6), "the small ring sits over the hint")
M.p = { bleed = { left_ms = 30000, total_ms = 60000 } }
run(M, 300)
check(lit(w.give) == 0 and w.t_give.tx.e.text == STR_ENG.st_coop_revive_give_up, "let go: the ring is gone, the hint is back")

-- stood up / revived: it fades
M.p = nil
run(M, 100)
check(w.g_down.visible and (alpha_of(w.bleed.pieces[1].w.e.tcolor) or 0) < 255, "stood up: the overlay fades out")
run(M, 300)
check(not w.g_down.visible and lit(w.bleed) == 0 and lit(w.lift) == 0, "gone")
-- the HUD hidden does not hide a downed player's state
M.hud_shown = false
M.p = { bleed = { left_ms = 30000, total_ms = 60000 } }
run(M, 300)
check(w.g_down.visible, "the downed player's ring shows even with the main HUD hidden")
M.hud_shown = true
M.p = nil
run(M, 400)

-- russian strings
local MR = machine(0, { rus = true })
run(MR, 100)
MR.p = { bleed = { left_ms = 30000, total_ms = 60000 }, revived_by = { peer = 0, nick = "p0", progress = 0.5, ms_left = 100 } }
run(MR, 300)
local wr = win(MR)
check(wr.t_by.tx.e.text == "p0  " .. STR_RUS.st_coop_revive_you and wr.t_hang.tx.e.text == STR_RUS.st_coop_revive_hang_on, "rus: the lines come from the rus table")

-- ================================================================ 5. outside a session, errors, sizes
print("== robustness")
local MS = machine(0, { active = false })
MS.p = { bleed = { left_ms = 1000, total_ms = 2000 } }
run(MS, 300)
check(next(MS.hud) == nil and MS.R.get_window() == nil and MS.polls == 0 and MS.R.current() == nil, "outside a session: no overlay, the engine is not even asked")
MS.active = true
run(MS, 300)
check(MS.R.get_window() ~= nil and win(MS).g_down.visible, "the session starts: the overlay comes")
MS.active = false
MS.p = nil
run(MS, 100)
check(next(MS.hud) == nil and MS.R.get_window() == nil, "the session ends: the overlay is taken off the HUD")

local MN = machine(0, { coop = false })
run(MN, 100)
check(next(MN.cb) == nil and #MN.cb_added == 0 and next(MN.hud) == nil, "an exe without the co-op namespace: nothing registers, nothing runs")

-- the engine raising / vanishing never breaks the frame
M.fail = true
hold(M, 0.5)
run(M, 200)
check(not w.g_rev.visible, "revive_progress raising: treated as nothing to show")
M.fail = false
run(M, 200)
check(w.g_rev.visible, "and the overlay recovers when it answers again")
M.p = nil
run(M, 300)
M.break_device = true
local errors_before = 0
for _, l in ipairs(M.log) do if l:find("revive overlay frame failed", 1, true) then errors_before = errors_before + 1 end end
run(M, 1000)
local errors_now = 0
for _, l in ipairs(M.log) do if l:find("revive overlay frame failed", 1, true) then errors_now = errors_now + 1 end end
check(errors_now - errors_before == 1, "a Lua error in the frame is logged once and the overlay pauses (not a line every frame)")
M.break_device = false
run(M, 5200)
hold(M, 0.5)
run(M, 300)
check(w.g_rev.visible, "after 5 s the overlay is back")
M.p = nil
run(M, 300)

-- sizes follow the screen
local made = CREATED
DEV.width, DEV.height = 1920, 1200
hold(M, 0.5)
run(M, 200)
kx = KX()
check(near(w.ring.track.e.w, d * kx, 1e-6) and near(w.ring.pieces[1].w.e.w, d, 1e-6) and near(w.badge.medkit.e.w, 20 * kx, 1e-6),
	"another aspect ratio: widths are px * kx (" .. string.format("%.4f", kx) .. "), the turned pieces stay square in units")
DEV.width, DEV.height = 1024, 768
run(M, 100)
check(near(w.ring.track.e.w, d, 1e-6) and near(w.dot.e.w, 6, 1e-6), "4:3 1024x768: kx 1, px = units")
DEV.width, DEV.height = 1920, 1080
M.p = nil
run(M, 300)
check(CREATED == made, "no window is made after the overlay was built (pools, not per frame)")
check(OVERLAY_WINDOWS > 100 and OVERLAY_WINDOWS < 300, "the pools are bounded (" .. OVERLAY_WINDOWS .. " windows for the whole overlay)")

-- the sizes are the owner's: one line in the ltx
local INI2 = ltx({ ROOT .. "configs/mod_system_coop.ltx", ROOT .. "configs/mod_system_coop_revive.ltx" })
INI2.data.coop_hud_revive.ring_r = "40"
INI2.data.coop_hud_revive.badge_w = "bad"
local ML = machine(0, { ini = INI2 })
run(ML, 100)
ML.p = nil
hold(ML, 0.3)
run(ML, 200)
local wl = win(ML)
check(near(wl.ring.pieces[1].w.e.w, 2 * 40 / (57 / 64), 1e-6) and near(ML.R.layout().badge_w, 20), "[coop_hud_revive] ring_r = 40 is taken; a broken line keeps the default")

-- the other side: one machine reviving, the other down, the same palette
local MB = machine(1)
run(MB, 100)
MB.p = { bleed = { left_ms = 50000, total_ms = 60000 }, revived_by = { peer = 0, avatar_id = 700, nick = "hosty", progress = 0.4, ms_left = 1800 } }
run(MB, 300)
local wb = win(MB)
check(is_rgb(wb.t_by.tx.e.color, { MB.A.color(0) }) and wb.t_by.tx.e.text:find("hosty", 1, true), "a client downed, the host reviving: the host's sand colour and nick")

-- ================================================================ 6. cost
print("== cost")
local MP = machine(0)
run(MP, 100)
local t0 = os.clock()
local frames = 400
for i = 1, frames do
	local f = (i % 120) / 120
	if i % 240 < 120 then
		hold(MP, f)
	else
		MP.p = { bleed = { left_ms = 60000 - i * 100, total_ms = 60000 }, revived_by = { peer = 2, nick = "pl_a", progress = f, ms_left = 100 },
			give_up = i % 7 < 3 and { progress = f, ms_left = 100 } or nil }
	end
	fire(MP, "actor_on_update")
	for w2 in pairs(MP.hud) do w2:Update() end
	NOW = NOW + 16
end
local per_frame = (os.clock() - t0) * 1000 / frames
print(("  info %.3f ms per frame in the stubs while a ring moves (the engine adds luabind calls)"):format(per_frame))
check(per_frame < 0.5, "the Lua side of a frame is well under half a millisecond in the stubs (" .. string.format("%.3f", per_frame) .. " ms)")
-- a steady hold (the fade-in is over): a piece is recoloured when it appears, the one the fill is passing every frame
MP.p = nil
run(MP, 400)
local function ring_calls(M)
	local n = 0
	for _, pc in ipairs(win(M).ring.pieces) do n = n + (pc.w.e.tcolor_calls or 0) end
	return n
end
hold(MP, 0)
run(MP, 300)
local calls0 = ring_calls(MP)
for i = 1, 120 do
	hold(MP, i / 120)
	fire(MP, "actor_on_update")
	for w2 in pairs(MP.hud) do w2:Update() end
	NOW = NOW + 16
end
local calls = ring_calls(MP) - calls0
check(calls <= 57 + 125, "a full hold of 120 frames recolours 57 pieces once and the leading one each frame, not every piece every frame (" .. calls .. " SetTextureColor calls)")
MP.R.print_status()
check(#MP.log > 0 and MP.log[#MP.log]:find("revive: overlay on", 1, true) ~= nil, "print_status says what the overlay did")

-- ================================================================
local unk = {}
for k in pairs(UNKNOWN or {}) do unk[#unk + 1] = tostring(k) end
table.sort(unk)
local allowed = { profile_timer = true, coop_hud_markers = true, system_ini = true, coop_core_hud = false }
local bad = {}
for _, k in ipairs(unk) do if not allowed[k] then bad[#bad + 1] = k end end
check(#bad == 0, "no reads of undefined globals (" .. table.concat(bad, ", ") .. ")")
print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
