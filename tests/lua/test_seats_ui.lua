-- F5-SEAT-2 (TZ 6.7): the interface for 16 seats. A server shows up to 16 players, the co-op keeps 8.
-- Every limit comes from the session (coop.session_info().max_players: the co-op 8, a server 16); outside a session the
-- co-op's. Real scripts: coop_allies, coop_allies_map, coop_hud_layout, coop_core_hud (the team panel), coop_hud_glare,
-- coop_economy_money (the inventory menu), coop_debug_cmds (the peer argument), the facade coop_mode under the test answer
-- sets; the real mod_system_coop.ltx and the engine's palette size (coop_presence.cpp kPaletteSize).
--   co-op session (8): colours 0..7 as before, 7 panel rows at the HUD v2 pitch, 7 glare spots, 8 menu entries at their
--     old places, debug peers 0..7;
--   server session (16): colours 1..16 distinct, spot types 0..16, the panel takes 15 rows in the compact layout, 15 glare
--     spots, a money list of 16, debug peers 0..16;
--   the fallbacks that said 8 (coop_menu, coop_main_menu, coop_srv_companions): the session's seats, else the co-op's 8 in the
--     menus and the server's 16 in the server's companion transfer.
-- SEATS_ROOT / SEATS_ENGINE point the test at another copy of gamedata / engine\src (the HEAD copy, to see it fail first).
-- Run: tools\test_lua.cmd seats_ui   (VERBOSE=1 for logs)
local ROOT = os.getenv("SEATS_ROOT") or "gamedata/"
local ENGINE = os.getenv("SEATS_ENGINE") or "engine/src/"
local modes = dofile("tests/lua/support/modes.lua")

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

-- a section that dies is a FAIL line, not a silent stop
local function section(name, fn)
	print("== " .. name)
	local ok, err = pcall(fn)
	if not ok then
		FAILS = FAILS + 1
		print("  FAIL section '" .. name .. "' crashed: " .. tostring(err))
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

-- ---------------------------------------------------------------- the ltx
local function ltx(path)
	local data, order, sec = {}, {}, nil
	for line in (readfile(path) or ""):gmatch("[^\r\n]+") do
		line = line:gsub(";.*$", "")
		local s = line:match("^%s*%[([%w_]+)%]")
		if s then
			sec = s
			data[sec] = data[sec] or {}
			order[sec] = order[sec] or {}
		elseif sec then
			local k, v = line:match("^%s*([%w_%$]+)%s*=%s*(.-)%s*$")
			if k then
				data[sec][k] = v
				table.insert(order[sec], k)
			end
		end
	end
	return {
		section_exist = function(_, s) return data[s] ~= nil end,
		line_exist = function(_, s, k) return data[s] ~= nil and data[s][k] ~= nil end,
		r_string = function(_, s, k) return data[s][k] end,
		data = data,
		order = order,
	}
end
local INI = ltx(ROOT .. "configs/mod_system_coop.ltx")
local NO_INI = ltx("")

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

local function window(M, path)
	local w = { path = path, visible = true, text = "", x = 0, y = 0, w = 0, h = 0, heading = 0 }
	function w:SetText(t) self.text = tostring(t) end
	function w:GetText() return self.text end
	function w:SetTextColor(c) self.color = c end
	function w:GetWidth() return self.w end
	function w:GetHeight() return self.h end
	function w:SetWndPos(v) self.x, self.y = v.x, v.y end
	function w:SetWndSize(v) self.w, self.h = v.x, v.y end
	function w:Show(b) self.visible = b end
	function w:IsShown() return self.visible end
	function w:InitTexture(t) self.texture = t end
	function w:SetStretchTexture() end
	function w:SetTextureColor(c) self.tcolor = c end
	function w:SetEllipsis() end
	function w:AdjustWidthToText() self.w = #self.text * 7 * 1024 / DEV.width end
	function w:EnableHeading() end
	function w:SetHeading(r) self.heading = r end
	M.made[#M.made + 1] = w
	return w
end

local function xml_stub(M)
	local x = {}
	function x:ParseFile(f) self.file = f end
	function x:InitStatic(path) return window(M, path) end
	x.InitTextWnd = x.InitStatic
	function x:NodeExist(name) return name:match("^coop_ally_%d+$") ~= nil or name == "coop_ally_down" or name == "coop_ally_dead" end
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

local SCRIPTS = { "coop_util", "coop_hud_kit", "coop_hud_hold", "coop_mode", "coop_hud_layout", "coop_allies", "coop_allies_map", "coop_core_hud", "coop_hud_glare",
	"coop_economy_money", "coop_debug_cmds" }

-- A process of a session.
--   opts.seats    what coop.session_info().max_players says (nil: the engine says none)
--   opts.set      the facade's answer set: "hostplay" (a co-op player), "srv_player" (a server player: srv_map's answers,
--                 everybody here), "srv_world", "none"
--   opts.self     own peer id; opts.others: the other players' peer ids
--   opts.ini      the system ini (default: the real mod_system_coop.ltx)
local function machine(opts)
	local M = { log = {}, made = {}, hud = {}, cb = {}, objects = {}, players = {}, lamps = {} }
	local env = setmetatable({}, { __index = _G })
	env._G = env
	M.env = env
	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if os.getenv("VERBOSE") then print("    " .. line) end
	end
	env.time_global = function() return NOW end
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.vector = function() return vec() end
	env.CScriptXmlInit = function() return xml_stub(M) end
	env.device = function() return { width = DEV.width, height = DEV.height, cam_pos = vec(0, 1.7, 0), cam_dir = vec(0, 0, 1) } end
	env.class = class_stub
	env.super = function() end
	env.CUIScriptWnd = CUIScriptWnd
	env.get_hud = function()
		return { AddDialogToRender = function(_, w) M.hud[w] = true end, RemoveDialogToRender = function(_, w) M.hud[w] = nil end }
	end
	env.main_hud_shown = function() return true end
	env.ini_sys = opts.ini or INI
	env.RegisterScriptCallback = function(name, f) M.cb[name] = M.cb[name] or {}; table.insert(M.cb[name], f) end
	env.UnregisterScriptCallback = function() end
	env.AddScriptCallback = function() end
	env.CreateTimeEvent = function() end
	env.game = {
		translate_string = function(id) return id end,
		world2ui = function() return { x = 512, y = 384 } end,
	}
	local ObjMT = {}
	ObjMT.__index = ObjMT
	function ObjMT:position() return vec(self._p.x, self._p.y, self._p.z) end
	function ObjMT:character_icon() return "ui_npc_icon" end
	function ObjMT:id() return self._id end
	function ObjMT:bone_position() return vec(self._p.x, self._p.y + 1.6, self._p.z) end
	M.actor = setmetatable({ _id = 0, _p = vec(0, 0, 0), health = 1 }, ObjMT)
	env.db = { actor = M.actor, storage = {} }
	env.level = {
		present = function() return true end,
		object_by_id = function(id) return M.objects[id] end,
		map_has_object_spot = function() return 0 end,
		map_add_object_spot = function() end,
		map_change_spot_hint = function() end,
		map_remove_object_spot = function() end,
	}
	env.ray_pick = function()
		local r = {}
		function r:set_flags() end
		function r:set_range() end
		function r:set_position() end
		function r:set_direction() end
		function r:set_ignore_object() end
		function r:query() return false end
		return r
	end
	local api = {
		is_active = function() return opts.set ~= "none" end,
		is_player = function() return true end,
		is_live = function() return opts.set ~= "none" end,
		self_id = function() return opts.self end,
		players = function() return M.players end,
		spot_is_local = function(t) return t:sub(1, 5) == "coop_" end,
		life_of = function() return nil end,
		bleed_left = function() return nil end,
		avatar_headlamp = function(id)
			local l = M.lamps[id]
			if not l then return false end
			return true, l[1], l[2], l[3]
		end,
		send_event = function() return true end,
	}
	if opts.session_info ~= false then
		api.session_info = function() return { max_players = opts.seats, players = M.players } end
	end
	env.coop = api
	-- the players: me and the others, each with a character here 5 m ahead of my camera (shining his lamp at me)
	M.players[#M.players + 1] = { id = opts.self, nick = "me", avatar_id = 0, is_self = true }
	for i, peer in ipairs(opts.others or {}) do
		local id = 500 + peer
		M.players[#M.players + 1] = { id = peer, nick = "p" .. peer, avatar_id = id, is_self = false }
		M.objects[id] = setmetatable({ _id = id, _p = vec(0, 0, 5 + i * 0.01) }, ObjMT)
		M.lamps[id] = { 0, 0, -1 }
	end
	table.sort(M.players, function(a, b) return a.id < b.id end)
	-- coop_main stand-in (the HUD registers its event handler)
	env.coop_main = { add_event_handler = function() return true end, encode = function() return "" end, decode = function() return {} end }
	-- coop_economy_core stand-in: what coop_economy_money asks
	local inv_cls = { InitProperties = function() return "stock" end }
	M.inv_cls = inv_cls
	env.ui_inventory = { UIInventory = inv_cls }
	env.coop_economy_core = {
		live = function() return opts.set ~= "none" end,
		engine = function() return true end,
		players = function()
			local list = {}
			for _, p in ipairs(M.players) do
				local o = M.objects[p.avatar_id]
				list[#list + 1] = { id = p.id, nick = p.nick, is_self = p.is_self, avatar_id = p.avatar_id, obj = o,
					pos = o and o:position() or nil }
			end
			return list
		end,
		position_of_id = function() return vec(0, 0, 0) end,
		rule = function() return nil end,
		dist = function() return 1 end,
		mod = function(name) if name == "ui_inventory" then return { UIInventory = inv_cls } end end,
		tr = function(id, def) return def or id end,
		fmt = function(id, def, ...) return string.format(def or id, ...) end,
		log = function() end,
		tip = function() end,
		on = function() end,
		self_id = function() return opts.self end,
	}
	for _, name in ipairs(SCRIPTS) do
		local src = assert(readfile(ROOT .. "scripts/" .. name .. ".script"), "no " .. name .. ".script")
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		local f = assert(loadstring(src, "@" .. name .. ".script"))
		setfenv(f, mod)
		f()
	end
	local set = opts.set or "hostplay"
	if set == "srv_player" then
		modes.install(env.coop_mode, "srv_map", {
			where = function() return "here" end, actor_is_player = function() return true end,
			is_player_mirror = function() return true end, leads_here = function() return false end,
		})
	else
		modes.install(env.coop_mode, set)
	end
	env.coop_economy_money.on_game_start()
	return M
end

local function others(from, to)
	local list = {}
	for p = from, to do list[#list + 1] = p end
	return list
end

-- ================================================================ the palette
section("palette: 17 colours, the 8 of W6 unchanged", function()
	local W6 = { [0] = "217,177,96", "83,140,224", "146,190,154", "206,202,253", "211,117,79", "111,211,203", "224,218,164",
		"161,134,178" }
	local cols = INI.data.coop_player_colors or {}
	for s = 0, 7 do check(cols["color_" .. s] == W6[s], "color_" .. s .. " stays " .. W6[s] .. " (players know it)") end
	local n, seen, dup = 0, {}, false
	for k in pairs(cols) do if k:match("^color_%d+$") then n = n + 1 end end
	check(n == 17, "[coop_player_colors] has 17 colours color_0..16 (" .. n .. ")")
	for s = 0, 16 do
		local v = cols["color_" .. s]
		check(type(v) == "string" and v:match("^%d+,%d+,%d+$") ~= nil, "color_" .. s .. " is r,g,b (" .. tostring(v) .. ")")
		if v then
			if seen[v] then dup = true end
			seen[v] = true
		end
	end
	check(not dup, "the 17 colours are distinct strings")
	check(cols.down == "226,58,48" and cols.dead == "150,150,150", "down and dead stay")

	local M = machine({ seats = 16, set = "srv_player", self = 1, others = {} })
	local A = M.env.coop_allies
	check(A.SLOTS == 17, "coop_allies.SLOTS = 17 (" .. tostring(A.SLOTS) .. ")")
	local server = {}
	for peer = 1, 16 do
		check(A.slot(peer) == peer, "server: peer " .. peer .. " has slot " .. peer .. " (" .. tostring(A.slot(peer)) .. ")")
		local key = table.concat({ A.color(peer) }, ",")
		check(key == cols["color_" .. peer], "peer " .. peer .. " colour = ltx color_" .. peer .. " (" .. key .. ")")
		server[key] = (server[key] or 0) + 1
	end
	local distinct = 0
	for _ in pairs(server) do distinct = distinct + 1 end
	check(distinct == 16, "server: the 16 players 1..16 have 16 different colours (" .. distinct .. ")")
	check(A.slot(17) == 0 and A.slot(18) == 1, "ids >= 17 wrap")
	-- co-op: 0..7 as today
	local C = machine({ seats = 8, set = "hostplay", self = 0, others = {} }).env.coop_allies
	for peer = 0, 7 do
		check(table.concat({ C.color(peer) }, ",") == W6[peer], "co-op: peer " .. peer .. " keeps " .. W6[peer])
	end
	-- the built-in defaults are the ltx's (a missing section)
	local D = machine({ seats = 16, set = "srv_player", self = 1, others = {}, ini = NO_INI }).env.coop_allies
	for s = 0, 16 do
		check(table.concat({ D.slot_color(s) }, ",") == cols["color_" .. s], "no ltx: slot " .. s .. " default = the shipped ltx value")
	end
end)

section("palette: the engine's name tags take the same 17", function()
	local src = readfile(ENGINE .. "xrGame/coop/coop_presence.cpp") or ""
	local proto = readfile(ENGINE .. "xrCoop/coop_protocol.h") or ""
	local max = tonumber(proto:match("constexpr uint32_t kMaxPlayers = (%d+);"))
	local slots = proto:find("constexpr uint32_t kMaxPeerSlots = kMaxPlayers + 1;", 1, true) and max and max + 1
	local expr = src:match("constexpr u32 kPaletteSize = ([^;]+);")
	local size = expr and (tonumber(expr) or (expr:match("^%s*kMaxPeerSlots%s*$") and slots)
		or (expr:match("^%s*kMaxPlayers%s*%+%s*1%s*$") and max and max + 1))
	check(size == 17, "coop_presence.cpp kPaletteSize = 17 (" .. tostring(expr) .. ", kMaxPlayers " .. tostring(max) .. ")")
	check(src:find('xr_sprintf(key, "color_%u", i);', 1, true) ~= nil, "it reads color_<i> for i < kPaletteSize")
end)

section("palette: the check script's numbers", function()
	local rep = readfile("temp/b58/f5_seat2/report.txt")
	if not rep then
		print("  (temp\\b58\\f5_seat2\\report.txt not there: python temp\\b58\\f5_seat2\\palette17.py writes it)")
		return
	end
	local norm = tonumber(rep:match("\n  norm%s+([%d%.]+)"))
	check(norm and norm >= 8, "min CIEDE2000 of the 17 for normal vision >= 8 (" .. tostring(norm) .. ")")
	check(not rep:find("CLOSER", 1, true) and rep:find("rules (muted", 1, true) and not rep:find("BROKEN", 1, true),
		"no new colour closer to down / dead than the old 8; the rules hold")
	for s = 8, 16 do
		local line = rep:match("color_" .. s .. "%s*=%s*([%d ,]+)")
		local v = line and line:gsub("%s", "")
		check(v == (INI.data.coop_player_colors or {})["color_" .. s], "report color_" .. s .. " = ltx (" .. tostring(v) .. ")")
	end
end)

-- ================================================================ map spot types
section("map spot types for slots 0..16", function()
	local M = machine({ seats = 16, set = "srv_player", self = 1, others = {} })
	local xml = M.env.coop_allies_map.spot_xml()
	local A = M.env.coop_allies
	for s = 0, 16 do
		local t = "coop_ally_" .. s
		local r, g, b = A.slot_color(s)
		check(xml:find("<" .. t .. ' hint=""><level_map spot="' .. t .. '_lvl" pointer="' .. t .. '_lptr"/>', 1, true) ~= nil,
			t .. " exists")
		check(xml:find("<" .. t .. '_mini width="16" height="16" heading="1" stretch="1" alignment="c" location_level="12">'
			.. string.format('<texture r="%d" g="%d" b="%d">coop_ally_arrow_32</texture>', r, g, b), 1, true) ~= nil,
			t .. " minimap arrow in slot " .. s .. "'s colour")
	end
	check(not xml:find("coop_ally_17", 1, true), "no type past 16")
	-- the engine must keep every one local (coop_story replicates the others): the last slot is asked too
	local asked = {}
	M.env.coop.spot_is_local = function(t) asked[t] = true return t:sub(1, 5) == "coop_" end
	M.env.coop_allies_map.sync({}, true)
	check(asked.coop_ally_16 and asked.coop_ally_0, "readiness asks coop.spot_is_local for coop_ally_0 and coop_ally_16")
end)

-- ================================================================ the session's seats
section("seats from the session", function()
	local function seats(opts)
		local A = machine(opts).env.coop_allies
		if type(A.seats) ~= "function" or type(A.others_max) ~= "function" then return nil end
		return A.seats(), A.others_max(), A
	end
	local s, o = seats({ seats = 8, set = "hostplay", self = 0 })
	check(s == 8 and o == 7, "co-op 8: 7 others")
	s, o = seats({ seats = 16, set = "srv_player", self = 3 })
	check(s == 16 and o == 15, "server 16: 15 others")
	local A
	s, o, A = seats({ seats = nil, set = "none", self = 0 })
	check(s == 8 and A and A.COOP_SEATS == 8, "the engine says none (outside a session): the co-op's 8")
	s, o = seats({ seats = 12, set = "srv_player", self = 3 })
	check(s == 12 and o == 11, "any number the session says (12): no fixed 16")
end)

-- ================================================================ the team panel
local function panel(M)
	local H = M.env.coop_core_hud
	local P = H.UICoopParty()
	P:Refresh(NOW)
	local shown = {}
	for i, r in ipairs(P.rows) do if r.base.e.visible then shown[#shown + 1] = r end end
	return P, shown
end

section("team panel, co-op: 7 rows at the Visor pitch", function()
	local M = machine({ seats = 8, set = "hostplay", self = 0, others = others(1, 7) })
	local P, shown = panel(M)
	local L = M.env.coop_hud_layout.get()
	local PITCH = 58 * 768 / 1080 -- Visor (R61): 58 px at 1080, straight down
	check(M.env.coop_core_hud.row_pitch and near(M.env.coop_core_hud.row_pitch(L, 7), PITCH), "row_pitch: 58 px at 1080 for 7 rows")
	check(#P.rows == 7, "7 rows made (" .. #P.rows .. ")")
	check(#shown == 7, "7 rows shown (" .. #shown .. ")")
	for i = 2, #shown do
		check(near(shown[i].top - shown[i - 1].top, PITCH), "row " .. i .. " is 58 px below row "
			.. (i - 1) .. " (" .. tostring(shown[i].top - shown[i - 1].top) .. ")")
		check(near(shown[i].base.e.x, shown[1].base.e.x), "row " .. i .. " straight under row 1 (no stair)")
	end
	check(near(shown[1].top, L.team_top) and near(shown[7].top, L.team_top + 6 * PITCH), "rows from team_top, 58 px apart")
	for i, r in ipairs(shown) do
		check(table.concat(r.color, ",") == table.concat({ M.env.coop_allies.color(i) }, ","), "row " .. i .. " in peer " .. i .. "'s colour")
	end
end)

section("team panel, server: 15 rows in the compact layout", function()
	local M = machine({ seats = 16, set = "srv_player", self = 1, others = others(2, 16) })
	local P, shown = panel(M)
	local L = M.env.coop_hud_layout.get()
	local H = M.env.coop_core_hud
	check(#P.rows == 15, "15 rows made (" .. #P.rows .. ")")
	check(#shown == 15, "15 other players: 15 rows shown (" .. #shown .. ")")
	local pitch = H.compact_pitch and H.compact_pitch(L)
	local FULL = 58 * 768 / 1080
	check(pitch and pitch < FULL, "a compact pitch below the full 58 px (" .. tostring(pitch) .. " < " .. FULL .. ")")
	-- one row's own height: the bracket (42 px at 1080) holds the nick, the segments, the badge and the timer
	local height = 42 * 768 / 1080
	check(pitch and pitch >= height - 1e-9, "rows do not overlap (pitch " .. tostring(pitch) .. " >= row height " .. height .. ")")
	for i = 2, #shown do
		check(pitch and near(shown[i].top - shown[i - 1].top, pitch), "row " .. i .. " follows at the compact pitch")
	end
	local bottom = shown[15] and shown[15].top + height
	check(bottom and bottom < 768 and bottom < L.team_bottom, "the 15th row ends on the screen (" .. tostring(bottom) .. ")")
	local peers = {}
	for i, r in ipairs(shown) do peers[i] = r.view and r.view.peer end
	check(peers[1] == 2 and peers[15] == 16, "sorted by peer: 2 .. 16")
	local B = P.bounds
	check(B and near(B.t, L.team_top) and near(B.b, bottom), "the panel's bounds follow the compact rows")
	-- 7 others on a server: the full pitch, the same look as the co-op
	local M7 = machine({ seats = 16, set = "srv_player", self = 1, others = others(2, 8) })
	local P7, shown7 = panel(M7)
	check(#shown7 == 7 and near(shown7[2].top - shown7[1].top, FULL), "server with 7 others: the full 58 px pitch")
	check(#P7.rows == 15, "and rows for 15 are there")
end)

section("team panel: the seats a Welcome says after the panel was made", function()
	local M = machine({ seats = nil, set = "srv_player", self = 1, others = others(2, 12) })
	local P, shown = panel(M)
	check(#shown == 7, "no seats said: the co-op's 7 rows (" .. #shown .. ")")
	M.env.coop.session_info = function() return { max_players = 16 } end
	P:Refresh(NOW + 1000)
	shown = {}
	for _, r in ipairs(P.rows) do if r.base.e.visible then shown[#shown + 1] = r end end
	check(#shown == 11 and #P.rows == 15, "16 seats said: rows for 15, the 11 others shown (" .. #shown .. ")")
end)

-- ================================================================ glare
local function glare_spots(M)
	local made, shown = 0, 0
	for _, w in ipairs(M.made) do
		if w.path == "coop_glare:spot" then
			made = made + 1
			if w.visible then shown = shown + 1 end
		end
	end
	return made, shown
end

local function glare_run(M)
	local G = M.env.coop_hud_glare.UICoopGlare()
	G:Frame(NOW)
	G:Frame(NOW + 200)
	G:Frame(NOW + 400)
	return G
end

section("glare: a spot per other player of the session", function()
	local M = machine({ seats = 8, set = "hostplay", self = 0, others = others(1, 7) })
	glare_run(M)
	local made, shown = glare_spots(M)
	check(made == 7 and shown == 7, "co-op: 7 friends shining at me, 7 spots (made " .. made .. ", shown " .. shown .. ")")
	local G = M.env.coop_hud_glare
	check(type(G.spots_max) == "function" and G.spots_max() == 7, "co-op: at most 7")
	M = machine({ seats = 16, set = "srv_player", self = 1, others = others(2, 16) })
	glare_run(M)
	made, shown = glare_spots(M)
	check(made == 15 and shown == 15, "server: 15 friends shining at me, 15 spots (made " .. made .. ", shown " .. shown .. ")")
	G = M.env.coop_hud_glare
	check(type(G.spots_max) == "function" and G.spots_max() == 15, "server: at most 15")
end)

-- ================================================================ money and items
local function menu(M)
	local inv = setmetatable({ properties = {} }, { __index = M.inv_cls })
	inv:InitProperties({}, "actor_bag")
	local give, money = {}, {}
	for k, v in pairs(inv.properties) do
		local i = tonumber(k:match("^coop_eco_give_(%d+)$"))
		if i then give[i] = v.index end
		i = tonumber(k:match("^coop_eco_money_(%d+)$"))
		if i then money[i] = v.index end
	end
	return inv, give, money
end

section("money: the transfer list follows the seats", function()
	local M = machine({ seats = 8, set = "hostplay", self = 0, others = others(1, 7) })
	local inv, give, money = menu(M)
	check(#give == 8 and #money == 8, "co-op: 8 entries of each (" .. #give .. ", " .. #money .. ")")
	check(give[1] == 41 and give[8] == 48 and money[1] == 51 and money[8] == 58, "co-op: at 41..48 and 51..58 as before")
	check(inv:coop_eco_CondMoney({}, "actor_bag", "", 7) and not inv:coop_eco_CondMoney({}, "actor_bag", "", 8),
		"co-op: 7 others, 7 money entries on")

	M = machine({ seats = 16, set = "srv_player", self = 1, others = others(2, 16) })
	inv, give, money = menu(M)
	check(#give == 16 and #money == 16, "server: 16 entries of each (" .. #give .. ", " .. #money .. ")")
	local E = M.env.coop_economy_money
	check(type(E.slots_max) == "function" and E.slots_max() == 16, "server: the list takes 16")
	local top_give, low_money = 0, math.huge
	for i = 1, 16 do
		top_give = math.max(top_give, give[i] or 0)
		low_money = math.min(low_money, money[i] or 0)
	end
	check(top_give < low_money, "every 'Give to' before every 'Give money to' (" .. top_give .. " < " .. low_money .. ")")
	local on = 0
	for i = 1, 16 do if inv:coop_eco_CondMoney({}, "actor_bag", "", i) then on = on + 1 end end
	check(on == 15, "server: 15 others, 15 money entries on (" .. on .. ")")
	check(inv:coop_eco_NameMoney(0, "actor_bag", "", 15):find("p16", 1, true) ~= nil, "the 15th names peer 16")
end)

-- ================================================================ debug: the peer argument
section("debug: the peer argument follows the session", function()
	local function ok_peer(M, p)
		return M.env.coop_debug_cmds.validate("tp_to_player", { p = p }) == true
	end
	local M = machine({ seats = 8, set = "hostplay", self = 0 })
	check(ok_peer(M, 0) and ok_peer(M, 7) and not ok_peer(M, 8), "co-op: peers 0..7, not 8")
	M = machine({ seats = 16, set = "srv_world", self = 0 })
	check(ok_peer(M, 1) and ok_peer(M, 16) and not ok_peer(M, 17), "world server: peers up to 16, not 17")
	M = machine({ seats = 16, set = "srv_player", self = 1 })
	check(ok_peer(M, 16) and not ok_peer(M, 17), "server player's window: up to 16")
	M = machine({ seats = nil, set = "none", self = 0, session_info = false })
	check(ok_peer(M, 7) and not ok_peer(M, 8), "no session: the co-op's 0..7")
end)

-- ================================================================ the fallbacks "or 8" (the integrator's note)
-- A script loaded on its own (every other global a do-nothing stand-in), and a local of it found through the upvalues of its
-- functions: coop_menu.max_players, the line under the main menu's Co-op button, coop_srv_companions' player peer.
local function stub_value()
	local t
	t = setmetatable({}, { __index = function() return t end, __call = function() return t end })
	return t
end

local function load_alone(name, api, globals)
	local env = setmetatable({}, { __index = function(_, k)
		local v = rawget(_G, k)
		if v ~= nil then return v end
		return stub_value()
	end })
	env._G = env
	env.coop = api
	for k, v in pairs(globals or {}) do env[k] = v end
	local src = assert(readfile(ROOT .. "scripts/" .. name .. ".script"), "no " .. name .. ".script")
	local f = assert(loadstring(src, "@" .. name .. ".script"))
	setfenv(f, env)
	f()
	return env
end

-- the function `want` (a local of the script): searched through the upvalues of its global functions and their tables
local function local_of(env, want)
	local seen, queue, i = {}, {}, 1
	for _, v in pairs(env) do
		if type(v) == "function" or (type(v) == "table" and getmetatable(v) == nil) then queue[#queue + 1] = v end
	end
	while queue[i] do
		local v = queue[i]
		i = i + 1
		if not seen[v] then
			seen[v] = true
			if type(v) == "function" then
				for n = 1, 200 do
					local name, u = debug.getupvalue(v, n)
					if not name then break end
					if name == want and type(u) == "function" then return u end
					if type(u) == "function" or (type(u) == "table" and getmetatable(u) == nil) then queue[#queue + 1] = u end
				end
			else
				for _, u in pairs(v) do if type(u) == "function" then queue[#queue + 1] = u end end
			end
		end
	end
	return nil
end

local function set_upvalue(f, want, value)
	for n = 1, 200 do
		local name = debug.getupvalue(f, n)
		if not name then return false end
		if name == want then
			debug.setupvalue(f, n, value)
			return true
		end
	end
	return false
end

section("fallbacks: the menus follow the session, else the co-op's 8", function()
	local INFO = { max_players = 16 }
	local api = { session_info = function() return INFO end }
	local menu = load_alone("coop_menu", api)
	check(menu.max_players() == 16, "coop_menu.max_players: a server session 16 (" .. tostring(menu.max_players()) .. ")")
	INFO = { max_players = 8 }
	check(menu.max_players() == 8, "coop_menu.max_players: a co-op session 8")
	INFO = {}
	check(menu.max_players() == 8 and menu.COOP_SEATS == 8, "coop_menu.max_players: no seats said (outside a session): the co-op's 8")
	local bare = load_alone("coop_menu", {})
	check(bare.max_players() == 8, "coop_menu.max_players: an engine without session_info: the co-op's 8")

	-- the line under the main menu's Co-op button: "no games yet, up to <seats>"
	menu.game = { translate_string = function(id) return id .. " %s" end } -- the main menu's words are coop_menu.tr's
	local mm = load_alone("coop_main_menu", api, { coop_menu = menu })
	local sub = local_of(mm, "coop_sub")
	check(type(sub) == "function", "coop_main_menu's coop_sub found")
	if not sub then return end
	check(set_upvalue(sub, "G", { list = function() return {} end }), "its games list stood in")
	INFO = { max_players = 16 }
	check(sub() == "st_coop_mm_sub_coop_none 16", "main menu, a server session: up to 16 (" .. tostring(sub()) .. ")")
	INFO = {}
	check(sub() == "st_coop_mm_sub_coop_none 8", "main menu, outside a session: up to the co-op's 8 (" .. tostring(sub()) .. ")")
	mm.coop_menu = { max_players = function() error("no menu") end }
	check(sub() == "", "main menu, coop_menu cannot say: no number of its own (" .. tostring(sub()) .. ")")
end)

section("fallbacks: a server's companion transfer takes peers 1 .. the session's seats", function()
	local INFO = { max_players = 16 }
	local env = load_alone("coop_srv_companions", { session_info = function() return INFO end })
	local peer_ok = local_of(env, "player_peer")
	check(type(peer_ok) == "function", "coop_srv_companions' player_peer found")
	if not peer_ok then return end
	check(peer_ok(1) and peer_ok(16) and not peer_ok(0) and not peer_ok(17) and not peer_ok(2.5) and not peer_ok("3"),
		"session 16: 1 .. 16, not 0, 17, 2.5, \"3\"")
	INFO = { max_players = 12 }
	check(peer_ok(12) and not peer_ok(13), "session 12: 1 .. 12 (no fixed 16)")
	INFO = {}
	check(peer_ok(9) and peer_ok(16) and not peer_ok(17), "the engine says no seats: the server's 16 (srv/coop_srv_mode.cpp), not the co-op's 8")
end)

print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
