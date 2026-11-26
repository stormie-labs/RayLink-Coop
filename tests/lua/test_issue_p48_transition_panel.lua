-- TZ P48 (Dev 58, owner 2026-11-22: "wrong readings on the transition or on the players", screenshot temp\r48\transition_panel.webp).
-- The transition board (scripts\coop_hud_transition.script) and the team panel (scripts\coop_core_hud.script) show one player
-- the same way: the same metres in the same frame, the same "loading" for a player whose character is not in this world yet,
-- the same death; the board's segments are its count. Per mode:
--   Coop    the host player's machine and a client's: the board (the engine's coop.transition()) and the panel together;
--   Server  a player's machine of a split world: the engine has no board there (no waiting point: coop_levels_rules.h
--           effective_gate folds every gate out of Together, coop_srv_join.cpp refuses a Board verdict), the panel alone;
--   single player (no session): neither window.
-- Real scripts: coop_mode, coop_hostplay_mode, coop_srv_mode, coop_hud_layout, coop_allies, coop_allies_map, coop_core_hud,
-- coop_hud_transition; real eng strings and mod_system_coop.ltx.
-- Run: tools\test_lua.cmd issue_p48   (VERBOSE=1 for logs)
local ROOT = "gamedata/"

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

-- ---------------------------------------------------------------- strings, ltx
local STR = {}
for _, f in ipairs({ "st_coop_hud.xml", "st_coop_allies.xml", "st_coop_transition.xml" }) do
	for id, text in (readfile(ROOT .. "configs/text/eng/" .. f) or ""):gmatch('<string id="([%w_]+)">%s*<text>(.-)</text>') do STR[id] = text end
end
local LEVELS = { l01_escape = "Cordon" }
check(STR.st_coop_transition_row_loading ~= nil and STR.st_coop_allies_m ~= nil, "the eng strings are read")

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
	}
end
local INI = ltx(ROOT .. "configs/mod_system_coop.ltx")

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

local function window(path)
	local w = { path = path, children = {}, visible = true, text = "", x = 0, y = 0, w = 0, h = 0, heading = 0 }
	function w:SetText(t) self.text = tostring(t) end
	function w:GetText() return self.text end
	function w:SetTextColor(c) self.color = c end
	function w:SetWndPos(v) self.x, self.y = v.x, v.y end
	function w:SetWndSize(v) self.w, self.h = v.x, v.y end
	function w:GetWidth() return self.w end
	function w:GetHeight() return self.h end
	function w:Show(b) self.visible = b end
	function w:IsShown() return self.visible end
	function w:InitTexture(t) self.texture = t end
	function w:SetStretchTexture() end
	function w:SetTextureColor(c) self.tcolor = c end
	function w:SetTextAlignment() end
	function w:SetEllipsis() end
	function w:AdjustWidthToText() self.w = #self.text * 7 * 1024 / DEV.width end
	function w:EnableHeading() end
	function w:SetHeading(r) self.heading = r end
	function w:GetHeading() return self.heading end
	function w:SetAutoDelete() end
	return w
end

local function xml_stub()
	local x = {}
	function x:ParseFile(f) self.file = f end
	local function init(self, path, parent)
		local w = window(path)
		if parent and parent.children then parent.children[#parent.children + 1] = w end
		return w
	end
	x.InitStatic, x.InitTextWnd, x.InitProgressBar = init, init, init
	function x:NodeExist() return true end
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

local SCRIPTS = { "coop_util", "coop_hud_kit", "coop_hud_hold", "coop_mode", "coop_hostplay_mode", "coop_srv_mode", "coop_hud_layout", "coop_allies", "coop_allies_map",
	"coop_core_hud", "coop_hud_transition" }

-- A machine. opts.split: a player's machine of a server world (coop.levels.split() true); opts.active = false: single player.
local function machine(self_peer, opts)
	opts = opts or {}
	local M = { peer = self_peer, log = {}, cb = {}, hud = {}, players = {}, objects = {}, life = {}, handlers = {}, t = nil }
	local env = setmetatable({}, { __index = _G })
	env._G = env
	M.env = env
	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if os.getenv("VERBOSE") then print("    [" .. self_peer .. "] " .. line) end
	end
	env.time_global = function() return NOW end
	env.game = { translate_string = function(id) return STR[id] or LEVELS[id] or id end }
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.vector = function() return vec() end
	env.CScriptXmlInit = function() return xml_stub() end
	env.device = function()
		return { width = DEV.width, height = DEV.height, cam_pos = vec(0, 1.7, 0), cam_dir = vec(0, 0, 1), f_time_delta = 0.016 }
	end
	env.class = class_stub
	env.super = function() end
	env.CUIScriptWnd = CUIScriptWnd
	env.get_hud = function()
		return { AddDialogToRender = function(_, w) M.hud[w] = true end, RemoveDialogToRender = function(_, w) M.hud[w] = nil end }
	end
	env.main_hud_shown = function() return true end
	env.ini_sys = INI
	env.RegisterScriptCallback = function(name, f)
		M.cb[name] = M.cb[name] or {}
		table.insert(M.cb[name], f)
	end
	env.UnregisterScriptCallback = function() end
	env.AddScriptCallback = function() end
	env.exec_console_cmd = function() end
	env.DIK_keys = {}
	env.key_bindings = { kUSE = 10 }
	env.dik_to_bind = function() return 0 end
	env.coop_hud_markers = { add_source = function() return true end }
	env.coop_srv_levels = { elsewhere_text = function(peer) return M.maps and M.maps[peer] and ("on another map: " .. M.maps[peer]) or "" end }

	local ObjMT = {}
	ObjMT.__index = ObjMT
	function ObjMT:position() return vec(self._p.x, self._p.y, self._p.z) end
	function ObjMT:character_icon() return "ui_npc_icon" end
	function ObjMT:character_community() return "actor_stalker" end
	function ObjMT:alive() return true end
	function ObjMT:id() return self._id end
	M.actor = setmetatable({ _id = 0, _p = vec(0, 0, 0), health = 1 }, ObjMT)
	M.objects[0] = M.actor
	function M.object(id, p) M.objects[id] = setmetatable({ _id = id, _p = p }, ObjMT) return M.objects[id] end
	env.db = { actor = M.actor, storage = {} }
	env.level = {
		present = function() return true end,
		name = function() return "l07_military" end,
		object_by_id = function(id) return M.objects[id] end,
		map_has_object_spot = function() return 0 end,
		map_add_object_spot = function() end,
		map_change_spot_hint = function() end,
		map_remove_object_spot = function() end,
		add_pp_effector = function() end,
	}
	M.active = opts.active ~= false
	env.coop = {
		is_active = function() return M.active end,
		is_host = function() return M.active and self_peer == 0 and not opts.split end,
		is_client = function() return M.active and (self_peer ~= 0 or opts.split == true) end,
		is_live = function() return M.active end,
		self_id = function() return self_peer end,
		levels = { split = function() return opts.split == true end },
		players = function() return M.players end,
		send_event = function() return true end,
		life_of = function(id) return M.life[id] or "alive" end,
		transition = function() return M.t end,
	}
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
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		local src = readfile(ROOT .. "scripts/" .. name .. ".script")
		local f, err = src and loadstring(src, "@" .. name .. ".script")
		if f then
			setfenv(f, mod)
			local ok, e = pcall(f)
			if not ok then print("  load error " .. name .. ": " .. tostring(e)) end
		else
			print("  script error " .. name .. ": " .. tostring(err or "missing"))
		end
	end
	for _, name in ipairs(SCRIPTS) do
		local m = env[name]
		if rawget(m, "on_game_start") then
			local ok, e = pcall(m.on_game_start)
			if not ok then print("  on_game_start " .. name .. ": " .. tostring(e)) end
		end
	end
	M.T, M.H = env.coop_hud_transition, env.coop_core_hud
	return M
end

local function status(M, peer, s, h)
	M.handlers["core.status"](M.env.coop_main.encode({ h = h or 1, s = s, f = "actor_stalker", i = "" }), peer)
end

-- one frame: the callbacks, then every HUD window, as the engine does
local function frame(M)
	for _, f in ipairs(M.cb.actor_on_update or {}) do f() end
	for w in pairs(M.hud) do w:Update() end
	NOW = NOW + 16
end

local function run(M, ms)
	local t_end = NOW + ms
	repeat frame(M) until NOW >= t_end
end

local function panel(M)
	for w in pairs(M.hud) do if w.team_panel then return w end end
end

local function board_win(M) return M.T.get_window() end

-- the panel's row of `nick`: { dist text or "" when hidden, nick alpha, fill shown, icon texture or nil }
local function panel_row(M, nick)
	local P = panel(M)
	if not P then return nil end
	for _, r in ipairs(P.rows) do
		if r.base.e.visible and r.name.e.text == nick then
			local fill = false
			for _, s in ipairs(r.segs) do if s.fill.e.visible then fill = true end end
			return {
				dist = r.dist.e.visible and r.dist.e.text or "",
				nick_a = r.name.e.color and math.floor(r.name.e.color / 16777216) or nil,
				dist_c = r.dist.e.color,
				fill = fill,
				icon = r.icon.e.visible and r.icon.e.texture or nil,
			}
		end
	end
end

-- the board's row of `nick`: its right-hand text, nil when the board does not list him
local function board_row(M, nick)
	local W = board_win(M)
	if not (W and W.g_board.visible) then return nil end
	for _, r in ipairs(W.rows) do
		if r.nick.tx.e.visible and r.nick.tx.e.text == nick then return r.state.tx.e.text end
	end
end

local function segments(M)
	local W = board_win(M)
	local on, all = 0, 0
	for _, s in ipairs(W.segs) do
		if s.e.visible then
			all = all + 1
			if s.e.tcolor and math.floor(s.e.tcolor / 16777216) >= 250 then on = on + 1 end
		end
	end
	return all, on
end

-- ================================================================ Coop: the owner's screenshot (the host player banan4ik)
print("== Coop: the host player at the exit to Cordon (the owner's screenshot)")
local H0 = machine(0)
H0.players = {
	{ id = 0, nick = "banan4ik", avatar_id = 0, is_self = true },
	{ id = 1, nick = "slave", avatar_id = 501, is_self = false }, -- loading: the host keeps his character out of the world (W9)
	{ id = 2, nick = "stormie", avatar_id = 502, is_self = false },
	{ id = 3, nick = "enforcer", avatar_id = 503, is_self = false },
	{ id = 4, nick = "c3n50r3d", avatar_id = 504, is_self = false },
}
H0.object(502, vec(0, 0, 89)) -- dead, 89 m from me
H0.life[502] = "dead"
local enforcer = H0.object(503, vec(29, 0, 0)) -- 29 m from me
H0.object(504, vec(0, 0, -84)) -- 84 m from me
status(H0, 2, "dead", 0)
status(H0, 3, "alive", 1)
status(H0, 4, "alive", 1)
-- the board as the engine gives it: its metres are to the exit's shapes (the host's view), 31 and 82 on the screenshot
H0.t = {
	state = "waiting", kind = "exit", level = "l01_escape", changer = 16601, ready = 1, total = 4, load_ms = 0,
	rows = { { peer = 0, mark = "ready", dist = 0 }, { peer = 1, mark = "loading" }, { peer = 2, mark = "down", dist = 89 },
		{ peer = 3, mark = "away", dist = 31 }, { peer = 4, mark = "away", dist = 82 } },
	me = { peer = 0, host = true, in_zone = true, ready = true, dist = 0, confirm = false, consent = false },
	pos = { x = 0, y = 0, z = -2 },
}
run(H0, 700)
check(panel(H0) ~= nil and board_win(H0) ~= nil and board_win(H0).g_board.visible, "the panel and the board are both on the HUD")

-- the metres: one source, the same words
local p_enf, b_enf = panel_row(H0, "enforcer"), board_row(H0, "enforcer")
check(p_enf and p_enf.dist == "29 m", "panel: enforcer 29 m from me (" .. tostring(p_enf and p_enf.dist) .. ")")
check(b_enf == (p_enf and p_enf.dist), "board: enforcer shows the panel's metres (board '" .. tostring(b_enf) .. "', panel '" ..
	tostring(p_enf and p_enf.dist) .. "')")
local p_c3, b_c3 = panel_row(H0, "c3n50r3d"), board_row(H0, "c3n50r3d")
check(b_c3 ~= nil and b_c3 == (p_c3 and p_c3.dist), "board: c3n50r3d shows the panel's metres (board '" .. tostring(b_c3) .. "', panel '" ..
	tostring(p_c3 and p_c3.dist) .. "')")

-- a runner: the two windows never disagree in any frame
do
	local frames, differ, first = 0, 0, nil
	for _ = 1, 180 do -- 3 s at 60 fps, 5 m/s away from me
		enforcer._p.x = enforcer._p.x + 0.08
		frame(H0)
		local p, b = panel_row(H0, "enforcer"), board_row(H0, "enforcer")
		frames = frames + 1
		if not (p and b == p.dist) then
			differ = differ + 1
			first = first or ("board '" .. tostring(b) .. "', panel '" .. tostring(p and p.dist) .. "'")
		end
	end
	check(differ == 0, ("a runner: the board and the panel show the same metres in every frame (%d of %d differ%s)"):format(differ, frames,
		first and (", first: " .. first) or ""))
end

-- the count and its segments: the group waits for four (the dead one is not waited for), so four segments, one white
local all, on = segments(H0)
check(board_win(H0).t_slot.tx.e.text == "1 / 4", "the count says 1 / 4 (" .. tostring(board_win(H0).t_slot.tx.e.text) .. ")")
check(all == 4 and on == 1, ("the segments are the count: 4, one white (%d, %d white)"):format(all, on))

-- loading: the board's word, and the panel's for the same player
local b_slave, p_slave = board_row(H0, "slave"), panel_row(H0, "slave")
check(b_slave == STR.st_coop_transition_row_loading, "board: slave is loading (" .. tostring(b_slave) .. ")")
check(p_slave and p_slave.dist == STR.st_coop_transition_row_loading, "panel: slave says the same word, not an empty row (" ..
	tostring(p_slave and p_slave.dist) .. ")")
check(p_slave and not p_slave.fill and p_slave.icon == nil, "panel: no health bar filled and no state icon for a player with no data")
check(p_slave and p_slave.nick_a and p_slave.nick_a <= 130, "panel: his nick dimmed (" .. tostring(p_slave and p_slave.nick_a) .. ")")
do
	local c = p_slave and p_slave.dist_c
	local r, g, b = c and math.floor(c / 65536) % 256, c and math.floor(c / 256) % 256, c and c % 256
	check(c and r > 200 and g > 120 and g < 200 and b < 100, "panel: the word in amber, as on the board")
end

-- death: the engine's survival state in both
local p_st, b_st = panel_row(H0, "stormie"), board_row(H0, "stormie")
check(p_st and p_st.icon == "coop_hud_skull" and b_st == STR.st_coop_transition_row_down,
	"stormie: a skull on the panel, 'not waited for' on the board (" .. tostring(p_st and p_st.icon) .. ", " .. tostring(b_st) .. ")")

-- he is in: his character comes into the world, his status follows; the board's next word for him is the panel's metres
H0.object(501, vec(-12, 0, 5))
status(H0, 1, "alive", 0.9)
H0.t.rows[2] = { peer = 1, mark = "away", dist = 15 }
H0.t.total = 4
run(H0, 600)
p_slave, b_slave = panel_row(H0, "slave"), board_row(H0, "slave")
check(p_slave and p_slave.dist == "13 m" and p_slave.fill, "panel: slave in the world: 13 m, his health (" .. tostring(p_slave and p_slave.dist) .. ")")
check(b_slave == "13 m", "board: slave 13 m, the panel's metres (" .. tostring(b_slave) .. ")")

-- my own row (in the zone, the board has not caught up): my metres to the exit, this machine's (the reminder line's too)
H0.t.rows[1] = { peer = 0, mark = "away", dist = 4 }
H0.t.me = { peer = 0, host = true, in_zone = true, ready = false, dist = 3, confirm = false, consent = false }
H0.t.ready = 0
run(H0, 100)
check(board_row(H0, "banan4ik") == "3 m", "my own row: my metres to the exit (" .. tostring(board_row(H0, "banan4ik")) .. ")")

-- ================================================================ Coop: a client's machine (enforcer)
print("== Coop: a client's machine")
local C3 = machine(3)
C3.players = {
	{ id = 0, nick = "banan4ik", avatar_id = 600, is_self = false },
	{ id = 1, nick = "slave", is_self = false }, -- the host's AvatarList names only players in the world (coop_join.cpp send_owners)
	{ id = 3, nick = "enforcer", avatar_id = 0, is_self = true },
}
C3.actor._p = vec(31, 0, 0)
C3.object(600, vec(1, 0, 0)) -- the host at the exit, 30 m from me
status(C3, 0, "alive", 1)
C3.t = {
	state = "waiting", kind = "exit", level = "l01_escape", changer = 16601, ready = 1, total = 3, load_ms = 0,
	rows = { { peer = 0, mark = "ready", dist = 0 }, { peer = 1, mark = "loading" }, { peer = 3, mark = "away", dist = 31 } },
	me = { peer = 3, host = false, in_zone = false, ready = true, dist = 31, confirm = false, consent = true },
}
run(C3, 700)
local all3 = segments(C3)
check(all3 == 3 and board_win(C3).t_slot.tx.e.text == "1 / 3", "client: three segments for 1 / 3")
local ps = panel_row(C3, "slave")
check(ps and ps.dist == STR.st_coop_transition_row_loading and board_row(C3, "slave") == STR.st_coop_transition_row_loading,
	"client: slave loading on the panel and on the board (" .. tostring(ps and ps.dist) .. ")")
check(panel_row(C3, "banan4ik") and panel_row(C3, "banan4ik").dist == "30 m", "client: the host 30 m from me on the panel")

-- ================================================================ Server: a player's machine of a split world
print("== Server: a player's machine (no board in a server world)")
local S = machine(2, { split = true })
S.maps = { [4] = "Garbage" }
S.players = {
	{ id = 1, nick = "near", avatar_id = 501, is_self = false, level = 3, elsewhere = false },
	{ id = 2, nick = "me", avatar_id = 0, is_self = true, level = 3, elsewhere = false },
	{ id = 3, nick = "arriving", avatar_id = 503, is_self = false, level = 3, elsewhere = false }, -- on my map, not in yet
	{ id = 4, nick = "far", avatar_id = 504, is_self = false, level = 5, elsewhere = true },
	{ id = 5, nick = "joining", is_self = false }, -- no map yet
}
S.object(501, vec(0, 0, 40))
status(S, 1, "alive", 1)
S.t = nil -- coop.transition() is nil: the engine runs no board in a server world
run(S, 700)
local SW = board_win(S)
check(not (SW and SW.g_board.visible), "server: no transition board")
check(panel_row(S, "near") and panel_row(S, "near").dist == "40 m", "server: a player on my map: 40 m")
check(panel_row(S, "arriving") and panel_row(S, "arriving").dist == STR.st_coop_transition_row_loading,
	"server: a player whose character is not on my map yet: loading (" .. tostring(panel_row(S, "arriving") and panel_row(S, "arriving").dist) .. ")")
check(panel_row(S, "joining") and panel_row(S, "joining").dist == STR.st_coop_transition_row_loading, "server: a player with no map yet: loading")
check(panel_row(S, "far") and panel_row(S, "far").dist == "on another map: Garbage", "server: a player on another map: his map, not loading")

-- ================================================================ single player: neither window
print("== single player")
local SP = machine(0, { active = false })
run(SP, 300)
check(panel(SP) == nil and board_win(SP) == nil, "single player: no panel, no board")

print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
