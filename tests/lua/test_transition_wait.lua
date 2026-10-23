-- Anomaly Coop, the waiting point of a level change (docs\hud\transition_wait_mockup.png): the placard of
-- scripts\coop_hud_transition.script on top of coop.transition(): the board (the level's name, who is ready, who is missing,
-- who is loading), the countdown, the reminder line of a player who is not at the exit, the guide trip, the keys held at the
-- exit (host: go now, player: cancel, guide: agree), the feed lines, the compass mark through coop_hud_markers.add_source,
-- nothing outside a session, the assets the script names (XML nodes, atlas textures, eng and rus strings).
-- Real scripts (coop_allies for the palette, coop_hud_transition), real ui_coop_transition.xml / strings / ltx.
-- Run: tools\test_lua.cmd transition   (VERBOSE=1 for logs)
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

local XML = { ["ui_coop_transition.xml"] = xml_nodes(ROOT .. "configs/ui/ui_coop_transition.xml") }
local TEXTURE_OF = {}
for tag, tex in (readfile(ROOT .. "configs/ui/ui_coop_transition.xml") or ""):gmatch("<([%w_]+)[^>]*>%s*<texture>([%w_]+)</texture>") do
	TEXTURE_OF["coop_transition:" .. tag] = tex
end
local INI = ltx({ ROOT .. "configs/mod_system_coop.ltx" })
local STR_ENG = string_ids(ROOT .. "configs/text/eng/st_coop_transition.xml")
local STR_RUS = string_ids(ROOT .. "configs/text/rus/st_coop_transition.xml")
-- the stock level names the script asks the string table for (configs\text\eng\st_levels.xml of the game)
local LEVELS_ENG = { l01_escape = "Cordon", zaton = "Zaton", k00_marsh = "Great Swamps" }
local LEVELS_RUS = { l01_escape = "RUS_CORDON", zaton = "RUS_ZATON" }
local MISSING = {}

-- ---------------------------------------------------------------- engine stand-ins
local NOW = 100000
local DEV = { width = 1920, height = 1080 }
local CREATED = 0

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
	function w:SetTextAlignment(a) self.align = a end
	return w
end

local function xml_stub()
	local x = { nodes = {} }
	function x:ParseFile(f) self.file = f; self.nodes = XML[f] or {} end
	local function init(self, path, parent)
		if not self.nodes[path] then MISSING[#MISSING + 1] = tostring(self.file) .. ":" .. path end
		local w = window(path, self.nodes[path])
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

local DIK_F, DIK_G = 33, 34
local BIND_USE, BIND_OTHER = 10, 11

-- A machine: the engine stand-ins and the real scripts. opts.coop = false: an exe without the co-op namespace.
local function machine(self_peer, opts)
	opts = opts or {}
	local M = { peer = self_peer, log = {}, cb = {}, cb_added = {}, hud = {}, console = {}, feed = {}, sources = {}, polls = 0 }
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
	local LEVELS = opts.rus and LEVELS_RUS or LEVELS_ENG
	env.game = { translate_string = function(id) return STR[id] or LEVELS[id] or id end }
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.CScriptXmlInit = function() return xml_stub() end
	env.device = function()
		if M.break_device then error("device() is gone") end
		return { width = DEV.width, height = DEV.height }
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
	env.exec_console_cmd = function(cmd) M.console[#M.console + 1] = cmd end
	env.DIK_keys = { DIK_F = DIK_F, DIK_G = DIK_G }
	env.key_bindings = { kUSE = BIND_USE }
	env.dik_to_bind = function(dik) return dik == DIK_F and BIND_USE or BIND_OTHER end
	env.db = { actor = { id = function() return 0 end } }
	M.active = opts.active ~= false
	if opts.coop ~= false then
		env.coop = {
			is_active = function() return M.active end,
			is_host = function() return M.active and self_peer == 0 end,
			is_client = function() return M.active and self_peer ~= 0 end,
			is_live = function() return M.active end,
			self_id = function() return self_peer end,
			players = function()
				return { { id = 0, nick = "player_a", is_self = self_peer == 0 }, { id = 1, nick = "player_b", is_self = self_peer == 1 },
					{ id = 2, nick = "Guest", is_self = self_peer == 2 } }
			end,
			transition = function()
				M.polls = M.polls + 1
				if M.fail then error("the engine is gone") end
				return M.t
			end,
		}
	end
	env.coop_core_chat = { system = function(text) M.feed[#M.feed + 1] = text end }
	env.coop_hud_markers = {
		add_source = function(name, fn, every) M.sources[name] = { fn = fn, every = every } return true end,
	}
	for _, name in ipairs({ "coop_allies", "coop_hud_transition" }) do
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
	M.A, M.T = env.coop_allies, env.coop_hud_transition
	for _, name in ipairs({ "coop_allies", "coop_hud_transition" }) do
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

local function win(M) return M.T.get_window() end

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

-- every visible window of the overlay: { path, text, x, y, w, h, color, tcolor, texture }
local function visible(M)
	local out = {}
	local function walk(node, ox, oy)
		for _, c in ipairs(node.children or {}) do
			if c.visible then
				local ax, ay = ox + c.x, oy + c.y
				out[#out + 1] = { path = c.path, text = c.text, x = ax, y = ay, w = c.w, h = c.h, color = c.color, tcolor = c.tcolor,
					texture = c.texture, node = c }
				walk(c, ax, ay)
			end
		end
	end
	local w = win(M)
	if w then walk(w.root, 0, 0) end
	return out
end

local function texts(M)
	local set, list = {}, {}
	for _, e in ipairs(visible(M)) do
		if e.text and e.text ~= "" then
			set[e.text] = (set[e.text] or 0) + 1
			list[#list + 1] = e.text
		end
	end
	return set, list
end

local function count_path(M, path)
	local n = 0
	for _, e in ipairs(visible(M)) do if e.path == path then n = n + 1 end end
	return n
end

-- the text window itself, not its 1 px shadow (black)
local function find_text(M, text)
	for _, e in ipairs(visible(M)) do
		if e.text == text and e.color then
			local r, g, b = rgb_of(e.color)
			if r + g + b > 0 then return e end
		end
	end
end

-- a board as the engine reports it
local function board(M, o)
	o = o or {}
	local me = o.me or { peer = M.peer, host = M.peer == 0, in_zone = true, ready = true, dist = 3, confirm = false }
	local t = {
		state = o.state or "waiting", kind = o.kind or "exit", level = o.level or "l01_escape", changer = 16601,
		ready = o.ready or 2, total = o.total or 3, countdown_ms = o.countdown_ms or 0, load_ms = o.load_ms or 0,
		rows = o.rows or { { peer = 0, mark = "ready", dist = 2 }, { peer = 1, mark = "ready", dist = 3 }, { peer = 2, mark = "away", dist = 118 } },
		me = me, pos = (o.pos ~= false) and { x = 10, y = 2, z = 30 } or nil,
	}
	if o.kind == "guide" then t.changer, t.pos = nil, nil end
	return t
end

local C_WHITE = { 244, 245, 246 }
local KX = function() return 1024 * DEV.height / (768 * DEV.width) end

-- ================================================================ 1. what the script names exists
print("== assets")
local c_before = CREATED
local M0 = machine(0)
M0.t = board(M0)
run(M0, 300)
local OVERLAY_WINDOWS = CREATED - c_before
local W0 = win(M0)
check(W0 ~= nil, "in a session the overlay is on the HUD")
check(#MISSING == 0, "every XML node the script asks for exists in ui_coop_transition.xml (" .. table.concat(MISSING, ", ") .. ")")
check(next(XML["ui_coop_transition.xml"]) ~= nil, "ui_coop_transition.xml is read")
do
	local x16 = xml_nodes(ROOT .. "configs/ui/ui_coop_transition_16.xml")
	local same = next(x16) ~= nil
	for path, a in pairs(XML["ui_coop_transition.xml"]) do
		if not x16[path] then same = false end
		for k, v in pairs(a) do if x16[path] and x16[path][k] ~= v then same = false end end
	end
	check(same, "ui_coop_transition_16.xml has the same nodes and attributes")
end
do
	local descr = readfile(ROOT .. "configs/ui/textures_descr/ui_coop_hud.xml") or ""
	local DESCR = {}
	for id in descr:gmatch('<texture id="([%w_]+)"') do DESCR[id] = true end
	local xml_src = readfile(ROOT .. "configs/ui/ui_coop_transition.xml") or ""
	local used, undefined = 0, {}
	for id in xml_src:gmatch("<texture>([%w_]+)</texture>") do
		used = used + 1
		if not DESCR[id] then undefined[#undefined + 1] = id end
	end
	check(used >= 5 and #undefined == 0, "every texture of the XML is in the HUD atlas (" .. used .. " used, missing: " .. table.concat(undefined, ", ") .. ")")
	local fonts_ok = true
	for tag in xml_src:gmatch("<text [^>]*>") do if not tag:find('font="', 1, true) then fonts_ok = false end end
	check(fonts_ok, "every text node names a font")
end
do
	local script = readfile(ROOT .. "scripts/coop_hud_transition.script") or ""
	local ids = {}
	for id in script:gmatch('"(st_coop_transition_[%w_]+)"') do ids[id] = true end
	local miss_e, miss_r = {}, {}
	for id in pairs(ids) do
		if not STR_ENG[id] then miss_e[#miss_e + 1] = id end
		if not STR_RUS[id] then miss_r[#miss_r + 1] = id end
	end
	check(next(ids) ~= nil and #miss_e == 0 and #miss_r == 0, "every st_coop_transition_* id of the script is in eng and rus (" .. table.concat(miss_e, ",") .. "|" .. table.concat(miss_r, ",") .. ")")
	local unused = {}
	for id in pairs(STR_ENG) do if not ids[id] then unused[#unused + 1] = id end end
	check(#unused == 0, "and the tables hold nothing the script does not use (" .. table.concat(unused, ",") .. ")")
	local keys_ok = true
	for _, id in ipairs({ "st_coop_transition_hint_cancel", "st_coop_transition_hint_go", "st_coop_transition_hint_confirm" }) do
		keys_ok = keys_ok and (STR_ENG[id] or ""):find("$$ACTION_USE$$", 1, true) ~= nil and (STR_RUS[id] or ""):find("$$ACTION_USE$$", 1, true) ~= nil
	end
	check(keys_ok, "the key hints take the use key from the engine ($$ACTION_USE$$), not a hard-coded F")
	local raw = readfile(ROOT .. "configs/text/rus/st_coop_transition.xml") or ""
	check(raw:find("\207\197\208\197\213\206\196", 1, true) ~= nil, "rus strings are cp1251 (the head \"ПЕРЕХОД\")")
	check(raw:find("\r\n", 1, true) ~= nil and not raw:gsub("\r\n", ""):find("\n", 1, true), "and have CRLF line ends")
end

-- ================================================================ 2. the pure parts
print("== pure parts")
local T = M0.T
check(T.level_title("l01_escape") == "Cordon" and T.level_title("zaton") == "Zaton" and T.level_title("") == "?" and T.level_title(nil) == "?"
	and T.level_title("some_mod_level") == "some_mod_level", "the level's title: the string table's name, the raw name if it has none, ? if unknown")
check(T.head_text({ kind = "exit" }) == STR_ENG.st_coop_transition_head and T.head_text({ kind = "guide" }) == STR_ENG.st_coop_transition_head_guide,
	"the head: TRANSITION, TRANSITION . GUIDE")
check(T.count_text({ ready = 2, total = 3 }) == "2 / 3" and T.count_text({ ready = 0, total = 0 }) == "0 / 0", "the count: ready / total")
check(T.status_text({ state = "waiting", kind = "exit" }) == STR_ENG.st_coop_transition_waiting
	and T.status_text({ state = "waiting", kind = "guide" }) == STR_ENG.st_coop_transition_waiting_guide
	and T.status_text({ state = "counting", kind = "exit" }) == STR_ENG.st_coop_transition_all_here, "the status line: waiting, waiting for the answer, everyone is here")
check(T.countdown_digit({ countdown_ms = 5000 }) == 5 and T.countdown_digit({ countdown_ms = 4001 }) == 5 and T.countdown_digit({ countdown_ms = 1 }) == 1
	and T.countdown_digit({ countdown_ms = 0 }) == 0 and T.countdown_digit({ countdown_ms = -50 }) == 0 and T.countdown_digit({}) == 0, "the countdown digit: seconds left, rounded up")

local ROWS = T.row_texts(board(M0, { rows = {
	{ peer = 0, mark = "ready", dist = 2 }, { peer = 1, mark = "away", dist = 118.4 }, { peer = 2, mark = "loading" },
	{ peer = 3, mark = "down" }, { peer = 4, mark = "elsewhere", dist = 40 }, { peer = 5, mark = "away" } }, load_ms = 41200 }))
check(#ROWS == 6 and ROWS[1].text == STR_ENG.st_coop_transition_row_ready and ROWS[1].tone == "ready", "a ready row: here, bright")
check(ROWS[2].text == "118 m" and ROWS[2].tone == "dim" and not ROWS[2].ready, "a missing one: the metres to the exit, dim")
check(ROWS[3].text == string.format(STR_ENG.st_coop_transition_row_loading_left, 42), "a loading one: loading and the seconds left of the minute (rounded up, 41.2 s shows 42)")
check(ROWS[3].tone == "amber", "... in amber")
check(ROWS[4].text == STR_ENG.st_coop_transition_row_down and ROWS[4].tone == "muted", "a downed one: not waited for")
check(ROWS[5].text == STR_ENG.st_coop_transition_row_elsewhere, "one at another exit says so")
check(ROWS[6].text == "..." or ROWS[6].text == "?" or ROWS[6].text:find("^%.%.%.") ~= nil, "no distance known: dots, not a made-up number")
check(ROWS[1].nick == "player_a" and ROWS[2].nick == "player_b" and ROWS[3].nick == "Guest" and ROWS[4].nick == "player 3", "nicks come from coop.players(), a stranger is player N")
do
	local r0, g0, b0 = M0.A.color(0)
	local r2, g2, b2 = M0.A.color(2)
	check(ROWS[1].rgb[1] == r0 and ROWS[1].rgb[2] == g0 and ROWS[1].rgb[3] == b0 and ROWS[3].rgb[1] == r2 and ROWS[3].rgb[2] == g2 and ROWS[3].rgb[3] == b2,
		"each in his slot's colour of the palette")
end
local loading_nominute = T.row_texts(board(M0, { rows = { { peer = 2, mark = "loading" } }, load_ms = 0 }))
check(loading_nominute[1].text == STR_ENG.st_coop_transition_row_loading, "loading without a running minute: just loading")
local guide_rows = T.row_texts(board(M0, { kind = "guide", rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "away" } } }))
check(guide_rows[1].text == STR_ENG.st_coop_transition_row_asked and guide_rows[2].text == STR_ENG.st_coop_transition_row_agreed
	and guide_rows[3].text == STR_ENG.st_coop_transition_row_wait, "a guide trip: the host asked, the others agreed, the rest owe an answer")

-- the key hint
local function me(o)
	local m = { peer = 1, host = false, in_zone = true, ready = true, confirm = false }
	for k, v in pairs(o or {}) do m[k] = v end
	return m
end
check(T.hint_kind(board(M0, { me = me({ host = true, peer = 0 }) })) == "go", "host at an exit: hold to go now")
check(T.hint_kind(board(M0, { me = me() })) == "cancel", "a player at an exit: hold to cancel")
check(T.hint_kind(board(M0, { me = me({ in_zone = false, ready = false }) })) == nil, "not at the exit: no key")
check(T.hint_kind(board(M0, { kind = "guide", me = me({ in_zone = false, ready = false, confirm = true }) })) == "confirm", "a guide trip I have not answered: hold to agree")
check(T.hint_kind(board(M0, { kind = "guide", me = me({ in_zone = false, ready = true }) })) == "cancel", "... once I agreed: hold to cancel")
check(T.hint_kind(board(M0, { kind = "guide", me = me({ host = true, peer = 0, in_zone = false, ready = true }) })) == "go", "the host of a guide trip: go now")
check(T.hint_kind(nil) == nil, "no board, no key")
check(T.hold_ms("go") == 1500 and T.hold_ms("cancel") == 1000 and T.hold_ms("confirm") == 1000 and T.hold_ms("nope") == nil,
	"the holds: the host's go is 1.5 s like the revive, the others 1 s")
check(T.hint_text("go") == STR_ENG.st_coop_transition_hint_go and T.hint_text("cancel") == STR_ENG.st_coop_transition_hint_cancel
	and T.hint_text("confirm") == STR_ENG.st_coop_transition_hint_confirm, "the hint texts")

-- the reminder of a player who is not at the exit
local away = board(M0, { me = me({ in_zone = false, ready = false, dist = 118.4 }), rows = { { peer = 0, mark = "away" }, { peer = 1, mark = "away" }, { peer = 2, mark = "ready", dist = 3 } } })
local rem = T.reminder(away)
check(rem and rem.nick == "Guest" and rem.text == string.format(STR_ENG.st_coop_transition_remind, "Cordon", 118), "the reminder: who waits, where, how far (118.4 m shows 118)")
local two = board(M0, { me = me({ in_zone = false, ready = false, dist = 10 }), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "away" }, { peer = 2, mark = "ready" } } })
rem = T.reminder(two)
check(rem and rem.nick:find("player_a", 1, true) and rem.nick:find("1", 1, true), "two waiting: the first and 'and 1 more'")
local nodist = T.reminder(board(M0, { me = me({ in_zone = false, ready = false, dist = nil }), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "away" } } }))
check(nodist and not nodist.text:find("m$"), "a distance not known: no distance in the line")
check(T.reminder(board(M0, { me = me() })) == nil, "at the exit myself: the board, not the reminder")
check(T.reminder(board(M0, { kind = "guide", me = me({ in_zone = false, ready = false, confirm = true }), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "away" } } })) == nil,
	"a guide trip is a board for everybody, not a reminder")
check(T.reminder(nil) == nil, "no board, no reminder")
check(T.shows_board(board(M0)) == true and T.shows_board(away) == false and T.shows_board(board(M0, { kind = "guide", me = me({ in_zone = false, ready = false, confirm = true }) })) == true
	and T.shows_board(nil) == false, "the board is for the ones at the exit and for a guide trip")

-- the feed
local function feed(prev, cur, who)
	return T.feed_events(prev, cur, who or 1)
end
local p0 = board(M0, { me = me(), rows = { { peer = 0, mark = "away" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "away" } } })
local p1 = board(M0, { me = me(), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "away" } } })
local ev = feed(nil, p1)
check(#ev == 1 and ev[1] == "player_a waits at the exit to Cordon", "the first board: the other one who is ready is announced (not me)")
ev = feed(p0, p1)
check(#ev == 1 and ev[1] == "player_a waits at the exit to Cordon", "a player gets ready: his line")
check(#feed(p1, p1) == 0, "nothing new: nothing said")
local c1 = board(M0, { state = "counting", ready = 3, total = 3, countdown_ms = 5000, me = me(), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "ready" } } })
ev = feed(p1, c1)
local joined = table.concat(ev, "|")
check(joined:find(string.format(STR_ENG.st_coop_transition_feed_all, 5), 1, true), "all ready: the countdown line with the seconds")
check(joined:find("waits at the exit", 1, true) ~= nil, "(player_b / Guest who got ready in the same step are announced too)")
local c2 = board(M0, { state = "counting", ready = 3, total = 3, countdown_ms = 2600, me = me(), rows = c1.rows })
check(#feed(c1, c2) == 0, "the countdown running: nothing more")
ev = feed(c2, p1)
check(#ev == 1 and ev[1] == "Transition cancelled", "back to waiting during the countdown: cancelled")
ev = feed(c2, nil)
check(#ev == 1 and ev[1] == "Transition cancelled", "the board gone during the countdown (left the zone, everybody): cancelled")
local c3 = board(M0, { state = "counting", ready = 3, total = 3, countdown_ms = 300, me = me(), rows = c1.rows })
check(#feed(c3, nil) == 0, "the board gone with 0.3 s left: the group went, not cancelled")
local g1 = board(M0, { kind = "guide", level = "zaton", me = me({ in_zone = false, ready = false, confirm = true }), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "away" } } })
ev = feed(nil, g1)
check(#ev == 1 and ev[1] == "player_a suggests moving to Zaton (guide)", "a guide trip: who suggests it")
check(#feed(nil, board(M0, { me = me({ host = true, peer = 0 }), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "away" } } }), 0) == 0, "my own readiness is not announced to me")

-- the compass mark
local marks = T.marks(away)
check(#marks == 1 and marks[1].kind == "transition" and near(marks[1].pos[1], 10) and near(marks[1].pos[2], 2) and near(marks[1].pos[3], 30) and marks[1].label == "Guest"
	and marks[1].priority and marks[1].priority > 30 and marks[1].key == "exit" and marks[1].range == 0, "the exit as a compass mark: a transition at its place, labelled with the waiting player, above the allies")
do
	local r2, g2, b2 = M0.A.color(2)
	check(marks[1].color[1] == r2 and marks[1].color[2] == g2 and marks[1].color[3] == b2, "in his colour")
end
check(#T.marks(board(M0, { me = me() })) == 0, "at the exit myself: no mark")
check(#T.marks(board(M0, { kind = "guide", pos = false, me = me({ in_zone = false, ready = false }) })) == 0, "a guide trip has no place: no mark")
check(#T.marks(nil) == 0, "no board: no marks")
check(M0.sources.transition ~= nil and type(M0.sources.transition.fn) == "function", "the source is added to coop_hud_markers at start")
M0.t = away
check(#M0.sources.transition.fn(NOW) == 1, "and gives the mark from the live board")
M0.t = nil
check(#M0.sources.transition.fn(NOW) == 0, "nothing when nobody waits")

-- ================================================================ 3. the board
print("== board")
local M = machine(1)
M.t = nil
run(M, 200)
local w = win(M)
check(w ~= nil and not w.g_board.visible and not w.g_remind.visible, "nobody waits: nothing on screen")
check(M.polls > 5, "the overlay asks the engine every frame (" .. M.polls .. ")")
M.t = board(M, { me = me() })
run(M, 16)
check(w.g_board.visible and (alpha_of(w.bg.e.tcolor) or 0) < 80, "a board appears: it fades in, not at once")
run(M, 300)
local set = texts(M)
check(w.g_board.visible and not w.g_remind.visible, "waiting at the exit: the board is on, the reminder is not")
check(set[STR_ENG.st_coop_transition_head] and set["Cordon"] and set["2 / 3"] and set[STR_ENG.st_coop_transition_waiting], "head, the level's name, 2 / 3 and the status line are on it")
check(set["player_a"] and set["player_b"] and set["Guest"], "all three players are listed")
check(set[STR_ENG.st_coop_transition_row_ready] == 4, "'here' for the two who are ready (a text and its shadow each)")
check(set["118 m"] and set[STR_ENG.st_coop_transition_hint_cancel], "the missing one with the metres, the hint to cancel")
check(count_path(M, "coop_transition:stripe") == 3, "a stripe per player")
local nick_a = find_text(M, "player_a")
check(nick_a and is_rgb(nick_a.color, { M.A.color(0) }) and alpha_of(nick_a.color) == 255, "the host's nick in his colour, bright")
local nick_c = find_text(M, "Guest")
check(nick_c and is_rgb(nick_c.color, { M.A.color(2) }) and alpha_of(nick_c.color) < 255 and alpha_of(nick_c.color) > 120, "the missing one's nick dimmed")
check(count_path(M, "coop_transition:seg") == 3, "a segment per player")
local on, off = 0, 0
for _, e in ipairs(visible(M)) do
	if e.path == "coop_transition:seg" then
		if (alpha_of(e.tcolor) or 0) >= 250 then on = on + 1 elseif (alpha_of(e.tcolor) or 0) > 20 and (alpha_of(e.tcolor) or 0) < 80 then off = off + 1 end
	end
end
check(on == 2 and off == 1, "two white segments, one dim")
check(not find_text(M, "5") and count_path(M, "coop_transition:big") == 0, "no big countdown digit while waiting")
-- placement: centred under the compass, in 1024x768 units
do
	local bg
	for _, e in ipairs(visible(M)) do if e.path == "coop_transition:bg" then bg = e end end
	local lay = T.layout()
	local kx = KX()
	check(bg and near(bg.x + bg.w / 2, 512, 1.5), "the placard is centred on the screen (" .. tostring(bg and (bg.x + bg.w / 2)) .. ")")
	check(bg and bg.y >= lay.top - lay.pad_y - 0.5 and bg.y <= lay.top, "its top is under the compass bar (top " .. tostring(lay.top) .. ")")
	local head
	for _, e in ipairs(visible(M)) do if e.path == "coop_transition:head" and e.text == STR_ENG.st_coop_transition_head then head = e end end
	check(head and near(head.x, 512 - lay.width * kx / 2 + 16 * kx, 1.5), "the left edge of the column is width/2 * kx left of the middle (nothing stretches on a wide screen)")
end
-- the level is renamed: the string table decides
local lvl = find_text(M, "Cordon")
check(lvl ~= nil, "the level name is the string table's (\"Cordon\")")

-- the countdown: big digit on the right, the status says everyone is here
M.t = board(M, { state = "counting", ready = 3, total = 3, countdown_ms = 3200, me = me(), rows = c1.rows })
run(M, 300)
set = texts(M)
check(set["4"] and not set["2 / 3"] and not set["3 / 3"], "counting: the digit (3.2 s left shows 4) instead of the count")
check(set[STR_ENG.st_coop_transition_all_here] ~= nil, "... and 'everyone is here'")
check(count_path(M, "coop_transition:big") == 2, "the big digit is its own window (a text and its shadow)")
M.t = board(M, { state = "counting", ready = 3, total = 3, countdown_ms = 700, me = me(), rows = c1.rows })
run(M, 32)
set = texts(M)
check(set["1"] ~= nil, "0.7 s left: 1")
-- loading player with the minute running
M.t = board(M, { ready = 2, total = 3, load_ms = 33000, me = me(), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "loading" } } })
run(M, 300)
local _, list = texts(M)
local joined_texts = table.concat(list, "|")
check(joined_texts:find("loading", 1, true) and joined_texts:find("33", 1, true), "a loading player: 'loading', 33 s of his minute")
-- a row more or less
M.t = board(M, { ready = 1, total = 1, me = me(), rows = { { peer = 1, mark = "ready" } } })
run(M, 300)
check(count_path(M, "coop_transition:stripe") == 1, "one player: one row")
M.t = board(M, { me = me(), total = 8, ready = 3, rows = (function()
	local r = {}
	for i = 0, 7 do r[#r + 1] = { peer = i, mark = i < 3 and "ready" or "away", dist = 10 * i } end
	return r
end)() })
run(M, 300)
check(count_path(M, "coop_transition:stripe") == 8 and count_path(M, "coop_transition:seg") == 8, "eight players: eight rows and eight segments")
M.t = board(M, { me = me(), total = 12, ready = 3, rows = (function()
	local r = {}
	for i = 0, 11 do r[#r + 1] = { peer = i, mark = "away" } end
	return r
end)() })
run(M, 300)
check(count_path(M, "coop_transition:stripe") <= 8, "a corrupt board with more rows than the session holds: eight at most, no window made")
local made_before = CREATED
M.t = board(M, { me = me() })
run(M, 600)
check(CREATED == made_before, "a frame never makes a window (the pools are built with the overlay)")

-- ================================================================ 4. the reminder
print("== reminder")
M.t = away
run(M, 400)
set = texts(M)
w = win(M)
check(w.g_remind.visible and not w.g_board.visible, "not at the exit: the reminder, no board")
check(set["Guest"] and set[string.format(STR_ENG.st_coop_transition_remind, "Cordon", 118)], "his nick and the line with the place and the metres")
local rn = find_text(M, "Guest")
check(rn and is_rgb(rn.color, { M.A.color(2) }) and alpha_of(rn.color) == 255, "the nick in his colour")
-- the player comes to the exit: the reminder gives way to the board
M.t = board(M, { me = me() })
run(M, 600)
check(win(M).g_board.visible and not win(M).g_remind.visible, "he reaches the exit: the board")
-- hud hidden (inventory, PDA): nothing on top
M.hud_shown = false
run(M, 400)
check(not win(M).g_board.visible and not win(M).g_remind.visible, "an open inventory / PDA: no overlay on top")
M.hud_shown = true
run(M, 400)
check(win(M).g_board.visible, "and it is back when it closes")

-- ================================================================ 5. a guide trip
print("== guide")
M.t = g1
run(M, 400)
set = texts(M)
check(win(M).g_board.visible and set[STR_ENG.st_coop_transition_head_guide] and set["Zaton"], "a guide trip: the board even for one who is not at an exit; 'Zaton'")
check(set[STR_ENG.st_coop_transition_waiting_guide] and set[STR_ENG.st_coop_transition_hint_confirm], "waiting for the answers; hold to agree")
check(set[STR_ENG.st_coop_transition_row_asked] and set[STR_ENG.st_coop_transition_row_wait], "the host 'asked', I owe an answer")

-- ================================================================ 6. the keys
print("== keys")
local MK = machine(1)
MK.t = board(MK, { me = me() })
run(MK, 400)
fire(MK, "on_key_press", DIK_G)
run(MK, 1500)
check(#MK.console == 0, "another key does nothing")
fire(MK, "on_key_press", DIK_F)
local hs = MK.T.hold_state()
check(hs and hs.kind == "cancel" and hs.fraction == 0, "the use key held at an exit starts a hold to cancel")
run(MK, 500)
hs = MK.T.hold_state()
check(hs and near(hs.fraction, 0.5, 0.08), "half way after 0.5 s of the 1 s")
local bar_fill
for _, e in ipairs(visible(MK)) do if e.path == "coop_transition:bar" and e.w > 0 and (alpha_of(e.tcolor) or 0) > 200 then bar_fill = e end end
check(bar_fill ~= nil, "the bar over the hint is filling")
fire(MK, "on_key_release", DIK_F)
run(MK, 1500)
check(#MK.console == 0 and MK.T.hold_state() == nil, "let go early: nothing happens, the hold is gone")
fire(MK, "on_key_press", DIK_F)
run(MK, 1100)
check(#MK.console == 1 and MK.console[1] == "coop_transition_cancel", "held for a second: coop_transition_cancel, once")
run(MK, 1500)
check(#MK.console == 1, "still held: it is not repeated")
fire(MK, "on_key_release", DIK_F)
MK.console = {}
-- the host: 1.5 s, go now
local MH = machine(0)
MH.t = board(MH, { me = me({ host = true, peer = 0 }) })
run(MH, 400)
fire(MH, "on_key_press", DIK_F)
run(MH, 1300)
check(#MH.console == 0, "the host's go takes 1.5 s: not at 1.3")
run(MH, 400)
check(#MH.console == 1 and MH.console[1] == "coop_transition_go", "the host held 1.5 s: coop_transition_go")
fire(MH, "on_key_release", DIK_F)
-- a guide trip to agree to
local MG = machine(1)
MG.t = g1
run(MG, 400)
fire(MG, "on_key_press", DIK_F)
run(MG, 1100)
check(#MG.console == 1 and MG.console[1] == "coop_transition_confirm", "agreeing to a guide trip: coop_transition_confirm")
fire(MG, "on_key_release", DIK_F)
-- not at the exit: the key is the game's own
local MN = machine(1)
MN.t = away
run(MN, 400)
fire(MN, "on_key_press", DIK_F)
run(MN, 2000)
check(#MN.console == 0 and MN.T.hold_state() == nil, "not at the exit: the use key is left alone")
-- the board goes while the key is held
local MZ = machine(1)
MZ.t = board(MZ, { me = me() })
run(MZ, 400)
fire(MZ, "on_key_press", DIK_F)
run(MZ, 300)
MZ.t = nil
run(MZ, 2000)
check(#MZ.console == 0 and MZ.T.hold_state() == nil, "the board went away while the key was held: no command")
-- an inventory open: the key belongs to it
local MI = machine(1)
MI.t = board(MI, { me = me() })
run(MI, 400)
MI.hud_shown = false
fire(MI, "on_key_press", DIK_F)
run(MI, 1500)
check(#MI.console == 0, "an open inventory / PDA: the key is not taken")

-- ================================================================ 7. the feed, live
print("== feed")
local MF = machine(1)
MF.t = board(MF, { me = me(), rows = { { peer = 0, mark = "away" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "away" } } })
run(MF, 200)
check(#MF.feed == 0, "I arrive alone: nothing to say")
MF.t = board(MF, { me = me(), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "away" } } })
run(MF, 200)
check(#MF.feed == 1 and MF.feed[1] == "player_a waits at the exit to Cordon", "a player arrives: one line in the feed")
run(MF, 2000)
check(#MF.feed == 1, "and only one")
MF.t = board(MF, { state = "counting", ready = 3, total = 3, countdown_ms = 5000, me = me(), rows = c1.rows })
run(MF, 200)
local last = MF.feed[#MF.feed]
check(last and last:find("moving in", 1, true) ~= nil, "everyone is here: the countdown line")
MF.t = board(MF, { me = me(), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "away" } } })
run(MF, 200)
check(MF.feed[#MF.feed] == "Transition cancelled", "a player steps back: cancelled")
local n = #MF.feed
-- a player who flaps does not fill the feed
for i = 1, 6 do
	MF.t = board(MF, { me = me(), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "ready" }, { peer = 2, mark = (i % 2 == 0) and "ready" or "away" } } })
	run(MF, 400)
end
local flap_lines = 0
for i = n + 1, #MF.feed do if MF.feed[i]:find("Guest waits", 1, true) then flap_lines = flap_lines + 1 end end
check(flap_lines <= 1, "a player who steps in and out is announced once in ten seconds, not each time (" .. flap_lines .. ")")

-- ================================================================ 8. outside a session, errors, rus
print("== robustness")
local MO = machine(0, { active = false })
MO.t = board(MO)
run(MO, 400)
check(win(MO) == nil and next(MO.hud) == nil, "no session: no overlay")
local MX = machine(0, { coop = false })
run(MX, 200)
check(win(MX) == nil and MX.sources.transition == nil, "an exe without co-op: nothing runs")
local ME = machine(1)
ME.t = board(ME, { me = me() })
run(ME, 300)
ME.fail = true
run(ME, 400)
check(win(ME) ~= nil and not win(ME).g_board.visible, "the engine call fails: the board goes, nothing raises")
ME.fail = false
run(ME, 400)
check(win(ME).g_board.visible, "and it is back when the call works again")
ME.break_device = true
local ok_dev = pcall(run, ME, 600)
check(ok_dev, "a broken device() does not take the frame down")
ME.break_device = false
local MR = machine(1, { rus = true })
MR.t = board(MR, { me = me() })
run(MR, 400)
local rset = texts(MR)
check(rset[STR_RUS.st_coop_transition_head] and rset[STR_RUS.st_coop_transition_waiting] and rset["RUS_CORDON"], "the russian strings and the russian level name")
check(rset[STR_RUS.st_coop_transition_hint_cancel] ~= nil, "... and the key hint")
MR.T.print_status()
check(#MR.log > 0 and MR.log[#MR.log]:find("transition: overlay", 1, true) ~= nil, "print_status says what the overlay did")
-- the session ends: the overlay goes
M.active = false
run(M, 400)
check(win(M) == nil and next(M.hud) == nil, "the session ends: the overlay is taken off the HUD")
M.active = true
M.t = board(M, { me = me() })
run(M, 400)
check(win(M) ~= nil, "a new session: the overlay is back")
fire(M, "actor_on_net_destroy")
check(win(M) == nil, "a level change (actor_on_net_destroy): the overlay is taken off")

-- ================================================================ 8b. geometry for a visual check against the mockup
-- temp/lua/hud_transition_<name>.txt, read by temp/transition_wait/render_dump.py: every visible static / text window under the
-- overlay's root, in 1024x768 units, tab separated (path, x, y, w, h, texture colour, text colour, texture, text).
local function dump(name, MM)
	local fh = io.open("temp/lua/hud_transition_" .. name .. ".txt", "wb")
	if not fh then return end
	local TAB, NL = string.char(9), string.char(10)
	fh:write(("screen" .. TAB .. "%d" .. TAB .. "%d" .. NL):format(DEV.width, DEV.height))
	for _, e in ipairs(visible(MM)) do
		local text = (e.text or ""):gsub("%c", " ")
		fh:write(table.concat({ e.path, ("%.3f"):format(e.x), ("%.3f"):format(e.y), ("%.3f"):format(e.w), ("%.3f"):format(e.h),
			tostring(e.tcolor or ""), tostring(e.color or ""), e.texture or "", text }, TAB) .. NL)
	end
	fh:close()
end
do
	local MV = machine(1)
	MV.t = board(MV, { me = me(), ready = 2, total = 3 })
	run(MV, 500)
	dump("board", MV)
	MV.t = board(MV, { state = "counting", ready = 3, total = 3, countdown_ms = 3000, me = me(), rows = c1.rows })
	run(MV, 500)
	dump("counting", MV)
	MV.t = board(MV, { ready = 2, total = 3, load_ms = 42000, me = me(), rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "ready" }, { peer = 2, mark = "loading" } } })
	run(MV, 500)
	dump("loading", MV)
	MV.t = away
	run(MV, 500)
	dump("reminder", MV)
	MV.t = g1
	run(MV, 500)
	dump("guide", MV)
end

-- ================================================================ 9. cost
print("== cost")
local MP = machine(1)
MP.t = board(MP, { me = me() })
run(MP, 400)
local t0 = os.clock()
local frames = 400
for i = 1, frames do
	MP.t = board(MP, { state = (i % 300 < 100) and "counting" or "waiting", countdown_ms = 5000 - (i % 100) * 50, me = me(),
		rows = { { peer = 0, mark = "ready", dist = 2 }, { peer = 1, mark = "ready", dist = i % 9 }, { peer = 2, mark = "away", dist = 100 + i % 50 } } })
	fire(MP, "actor_on_update")
	for w2 in pairs(MP.hud) do w2:Update() end
	NOW = NOW + 16
end
local per_frame = (os.clock() - t0) * 1000 / frames
print(("  info %.3f ms per frame in the stubs"):format(per_frame))
check(per_frame < 0.5, "the Lua side of a frame is well under half a millisecond in the stubs (" .. string.format("%.3f", per_frame) .. " ms)")

-- ================================================================
local unk = {}
for k in pairs(UNKNOWN or {}) do unk[#unk + 1] = tostring(k) end
table.sort(unk)
local allowed = { profile_timer = true, system_ini = true, coop_core_player = true, coop_hud_ping = true }
local bad = {}
for _, k in ipairs(unk) do if not allowed[k] then bad[#bad + 1] = k end end
check(#bad == 0, "no reads of undefined globals (" .. table.concat(bad, ", ") .. ")")
print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
