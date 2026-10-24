-- Anomaly Coop: the net graph (scripts\coop_hud_netgraph.script), a CS2-style block at the top right: FPS, ping, packet
-- loss, (the host) the number of players. Real scripts (coop_hud_layout, coop_menu_options, coop_hud_netgraph), the real
-- ui_coop_netgraph.xml paths, the real mod_system_coop.ltx numbers, real eng / rus strings. The engine is stubbed.
-- Covers: thresholds -> colours at the boundaries, the host shows the worst client and the player count, a client shows
-- the host, hidden when the option is off / outside a session / with the main HUD hidden, the update rate (4 Hz), the
-- player option (off by default), the strings, the place on the screen.
-- Run: tools\test_lua.cmd netgraph   (VERBOSE=1 for logs)
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

-- a section that dies is a FAIL line (RED by assertion), not a silent stop
local function section(name, fn)
	print("== " .. name)
	local ok, err = pcall(fn)
	if not ok then
		FAILS = FAILS + 1
		print("  FAIL section '" .. name .. "' crashed: " .. tostring(err))
	end
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
local XML, XML_OK = {}, {}
XML["ui_coop_netgraph.xml"], XML_OK["ui_coop_netgraph.xml"] = xml_nodes(ROOT .. "configs/ui/ui_coop_netgraph.xml")
local WIDE_NODES, WIDE_OK = xml_nodes(ROOT .. "configs/ui/ui_coop_netgraph_16.xml")
MISSING = {}

-- strings: eng table (translate_string answers it, "<id>" for anything else); rus is read raw for the id check
local function string_ids(path)
	local ids, texts = {}, {}
	for id, text in (readfile(path) or ""):gmatch('<string id="([%w_]+)">%s*<text>(.-)</text>') do
		ids[id] = true
		texts[id] = text
	end
	return ids, texts
end
local ENG_IDS, STR = string_ids(ROOT .. "configs/text/eng/st_coop_netgraph.xml")
local RUS_IDS, RUS = string_ids(ROOT .. "configs/text/rus/st_coop_netgraph.xml")

-- ---------------------------------------------------------------- engine stand-ins
local NOW = 100000
local DEV = { width = 1920, height = 1080 }

local function window(path, a)
	a = a or {}
	local w = { path = path, children = {}, visible = true, text = "", sets = 0,
		x = tonumber(a.x) or 0, y = tonumber(a.y) or 0, w = tonumber(a.width) or 0, h = tonumber(a.height) or 0 }
	function w:SetText(t)
		self.text = tostring(t)
		self.sets = self.sets + 1
	end
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
	function w:SetEllipsis(b) self.ellipsis = b end
	function w:AdjustWidthToText() self.w = #self.text * 7 * 1024 / DEV.width end
	function w:SetFont() end
	function w:SetTextAlignment(al) self.align = al end
	function w:SetAutoDelete() end
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
local SCRIPTS = { "coop_hud_layout", "coop_menu_options", "coop_hud_netgraph" }

local function machine(self_peer, opts)
	opts = opts or {}
	local M = { peer = self_peer, log = {}, cb = {}, hud = {}, players = {}, options = {}, players_calls = 0 }
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
	env.game = { translate_string = function(id) return STR[id] or id end }
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.CScriptXmlInit = function() return xml_stub() end
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
	env.axr_main = { config = {
		r_value = function(_, sec, key, typ, def)
			local v = M.options[key]
			if v == nil then return def end
			return v
		end,
		w_value = function(_, sec, key, v) M.options[key] = v end,
		save = function() end,
	} }
	M.actor = { id = function() return 0 end }
	env.db = { actor = M.actor }
	M.active = opts.active ~= false
	env.coop = (not opts.bare) and {
		is_active = function() return M.active end,
		is_host = function() return M.active and self_peer == 0 end,
		is_client = function() return M.active and self_peer ~= 0 end,
		is_live = function() return M.active and M.loading ~= true end,
		self_id = function() return self_peer end,
		players = function()
			M.players_calls = M.players_calls + 1
			if M.players_error then error("boom") end
			return M.players
		end,
	} or nil
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
	M.layout, M.menu, M.net = env.coop_hud_layout, env.coop_menu_options, env.coop_hud_netgraph
	for _, name in ipairs(SCRIPTS) do
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

-- frames for `ms` milliseconds, one every `dt` ms
local function run(M, ms, dt)
	dt = dt or 16
	local t_end = NOW + ms
	repeat
		fire(M, "actor_on_update")
		for w in pairs(M.hud) do w:Update() end
		NOW = NOW + dt
	until NOW >= t_end
end

local function the_window(M)
	for w in pairs(M.hud) do return w end
	return nil
end

local function rgb_of(c)
	if not c then return nil end
	local v = c % 16777216
	return math.floor(v / 65536), math.floor(v / 256) % 256, v % 256
end
local function alpha_of(c) return c and math.floor(c / 16777216) or nil end
local function same_rgb(c, t)
	local r, g, b = rgb_of(c)
	return t ~= nil and r == t[1] and g == t[2] and b == t[3]
end

-- one row of the window: label, number
local function row(W, i)
	local r = W and W.rows and W.rows[i]
	if not r then return { label = "?", text = "?", shown = false } end
	return { label = r.label.text, text = r.num.text, color = r.num.color, shown = r.num.visible and r.label.visible, r = r }
end

-- a session: me (peer `me`) and the others { id, rtt, loss }
local function roster(me, others)
	local list = { { id = me, nick = "me", rtt = 0, loss = 0, is_self = true } }
	for _, o in ipairs(others) do
		list[#list + 1] = { id = o.id, nick = "p" .. o.id, avatar_id = 500 + o.id, rtt = o.rtt, loss = o.loss, is_self = false }
	end
	return list
end

local function settle(M) run(M, 700) end -- two refreshes and a bit

-- ================================================================ 1. the script and its pure helpers
local M0
section("grades and colours", function()
	NOW = 100000
	M0 = machine(0, { active = false })
	check(M0.missing_script == nil, "all scripts exist (missing:" .. tostring(M0.missing_script) .. ")")
	local N = M0.net
	check(N and type(N.grade_ping) == "function" and type(N.grade_loss) == "function" and type(N.grade_fps) == "function"
		and type(N.color_of) == "function", "grade helpers exported")
	if not (N and N.grade_ping) then error("no grade helpers") end
	-- the thresholds are constants at the top of the script
	check(N.PING_WARN == 80 and N.PING_BAD == 150, "ping thresholds 80 / 150 ms")
	check(N.LOSS_WARN == 1 and N.LOSS_BAD == 5, "loss thresholds 1 / 5 %")
	check(N.FPS_OK == 50 and N.FPS_BAD == 30, "fps thresholds 50 / 30")
	-- ping: ok < 80, warn < 150, bad >= 150
	check(N.grade_ping(0) == "ok" and N.grade_ping(79) == "ok", "ping 0 and 79 ms: ok")
	check(N.grade_ping(80) == "warn" and N.grade_ping(149) == "warn", "ping 80 and 149 ms: warn")
	check(N.grade_ping(150) == "bad" and N.grade_ping(999) == "bad", "ping 150 and 999 ms: bad")
	-- loss (percent): ok < 1, warn < 5, bad >= 5
	check(N.grade_loss(0) == "ok" and N.grade_loss(0.9) == "ok" and N.grade_loss(0.99) == "ok", "loss 0, 0.9, 0.99 %: ok")
	check(N.grade_loss(1) == "warn" and N.grade_loss(4.9) == "warn" and N.grade_loss(4.99) == "warn", "loss 1, 4.9, 4.99 %: warn")
	check(N.grade_loss(5) == "bad" and N.grade_loss(100) == "bad", "loss 5 and 100 %: bad")
	-- fps: ok >= 50, warn >= 30, bad < 30 (graded as shown: a whole number)
	check(N.grade_fps(144) == "ok" and N.grade_fps(50) == "ok", "fps 144 and 50: ok")
	check(N.grade_fps(49) == "warn" and N.grade_fps(30) == "warn", "fps 49 and 30: warn")
	check(N.grade_fps(29) == "bad" and N.grade_fps(1) == "bad", "fps 29 and 1: bad")
	check(N.grade_fps(49.6) == "ok" and N.grade_fps(29.6) == "warn", "fps is graded as shown (49.6 shows 50, 29.6 shows 30)")
	-- colours: green / amber / red, distinct, and the labels dim
	local g, a, r = N.color_of("ok"), N.color_of("warn"), N.color_of("bad")
	check(g and a and r and g[2] > g[1] and g[2] > g[3], "ok is green")
	check(a and a[1] > 200 and a[2] > 140 and a[2] < a[1] and a[3] < 120, "warn is amber")
	check(r and r[1] > 200 and r[2] < 90 and r[3] < 90, "bad is red")
	check(N.color_of("nonsense") ~= nil and N.color_of(nil) ~= nil, "an unknown grade still has a colour (dim)")
	check(near(N.fps_of(15, 250), 60) and near(N.fps_of(10, 500), 20) and N.fps_of(0, 250) == 0 and N.fps_of(5, 0) == nil,
		"fps_of: frames per second from a bucket (no time: nil)")
end)

-- ================================================================ 2. what the numbers are
section("summary of the session", function()
	local N = M0.net
	if not (N and N.summarize) then error("no summarize") end
	-- host: the worst of the clients, the count of everybody
	local host = N.summarize(roster(0, { { id = 1, rtt = 40, loss = 0.002 }, { id = 2, rtt = 160, loss = 0.07 },
		{ id = 3, rtt = 90, loss = 0.01 } }), true)
	check(host.players == 4 and host.ping == 160 and near(host.loss, 7), "host: 4 players, worst ping 160 ms, worst loss 7 %")
	local lone = N.summarize(roster(0, {}), true)
	check(lone.players == 1 and lone.ping == nil and lone.loss == nil, "host alone: 1 player, no ping, no loss")
	-- client: the host's line only (peer 0), not the other clients' (the host does not know their numbers for us)
	local cl = N.summarize(roster(1, { { id = 0, rtt = 35, loss = 0.004 }, { id = 2, rtt = 300, loss = 0.5 } }), false)
	check(cl.ping == 35 and near(cl.loss, 0.4, 1e-6), "client: the host's 35 ms / 0.4 %, the other client is ignored")
	local nohost = N.summarize(roster(1, { { id = 2, rtt = 300, loss = 0.5 } }), false)
	check(nohost.ping == nil and nohost.loss == nil, "client without the host in the list: nothing to show")
	-- a list from an older exe has no loss field: 0, not an error
	local old = N.summarize({ { id = 0, rtt = 0, is_self = true }, { id = 1, rtt = 55, is_self = false } }, true)
	check(old.ping == 55 and old.loss == 0, "a player entry without loss counts as 0 %")
	-- garbage does not crash and does not show
	local bad = N.summarize({ { id = 1, rtt = "x", loss = 0 / 0, is_self = false }, "junk", { id = 2, rtt = -5, loss = -1 } }, true)
	check(type(bad) == "table" and (bad.ping or 0) >= 0 and (bad.loss or 0) >= 0, "garbage entries: no crash, nothing negative")
	check(N.summarize(nil, true).players == 0, "no list: 0 players")
end)

-- ================================================================ 3. the window: a client
section("client window", function()
	NOW = 200000
	local M = machine(1)
	M.players = roster(1, { { id = 0, rtt = 45, loss = 0.0 }, { id = 2, rtt = 20, loss = 0.0 } })
	run(M, 300)
	check(the_window(M) == nil and M.net.get_window() == nil and M.net.is_enabled() == false, "default: the option is off, no window")
	check(M.players_calls == 0, "off: the player list is not even asked for")
	M.net.set_enabled(true)
	run(M, 100)
	local W = the_window(M)
	check(W ~= nil and M.net.get_window() == W, "enabled in a session: the window is on the HUD")
	check(#MISSING == 0, "every XML node the window asks for exists (" .. table.concat(MISSING, ", ") .. ")")
	if not W then error("no window") end
	settle(M)
	local fps, ping, loss, fourth = row(W, 1), row(W, 2), row(W, 3), row(W, 4)
	check(fps.label == "FPS" and ping.label == "PING" and loss.label == "LOSS", "client rows: FPS, PING, LOSS (" .. fps.label .. ", " .. ping.label .. ", " .. loss.label .. ")")
	check(not fourth.shown, "client: no fourth row (the player count is the host's)")
	check(ping.text == "45 ms" and same_rgb(ping.color, M.net.color_of("ok")), "ping 45 ms is green (" .. ping.text .. ")")
	check(loss.text == "0.0%" and same_rgb(loss.color, M.net.color_of("ok")), "loss 0.0% is green (" .. loss.text .. ")")
	local n = tonumber(fps.text)
	check(n and n >= 61 and n <= 64 and same_rgb(fps.color, M.net.color_of("ok")), "16 ms frames show ~62 fps in green (" .. fps.text .. ")")
	-- values change colour at the thresholds (the host's entry is the client's ping)
	local function with(rtt, lossf)
		M.players = roster(1, { { id = 0, rtt = rtt, loss = lossf }, { id = 2, rtt = 20, loss = 0.0 } })
		run(M, 300)
		return row(W, 2), row(W, 3)
	end
	local p, l = with(79, 0.0099)
	check(p.text == "79 ms" and same_rgb(p.color, M.net.color_of("ok")) and l.text == "0.9%" and same_rgb(l.color, M.net.color_of("ok")),
		"79 ms / 0.99 %: green (" .. p.text .. ", " .. l.text .. ")")
	p, l = with(80, 0.01)
	check(same_rgb(p.color, M.net.color_of("warn")) and l.text == "1.0%" and same_rgb(l.color, M.net.color_of("warn")),
		"80 ms / 1 %: amber (" .. p.text .. ", " .. l.text .. ")")
	p, l = with(149, 0.0499)
	check(same_rgb(p.color, M.net.color_of("warn")) and l.text == "4.9%" and same_rgb(l.color, M.net.color_of("warn")),
		"149 ms / 4.99 %: amber (" .. p.text .. ", " .. l.text .. ")")
	p, l = with(150, 0.05)
	check(same_rgb(p.color, M.net.color_of("bad")) and l.text == "5.0%" and same_rgb(l.color, M.net.color_of("bad")),
		"150 ms / 5 %: red (" .. p.text .. ", " .. l.text .. ")")
	-- fps follows the frame time
	run(M, 800, 25)
	local f = row(W, 1)
	check(f.text == "40" and same_rgb(f.color, M.net.color_of("warn")), "25 ms frames: 40 fps, amber (" .. f.text .. ")")
	run(M, 800, 50)
	f = row(W, 1)
	check(f.text == "20" and same_rgb(f.color, M.net.color_of("bad")), "50 ms frames: 20 fps, red (" .. f.text .. ")")
	run(M, 800, 10)
	f = row(W, 1)
	check(f.text == "100" and same_rgb(f.color, M.net.color_of("ok")), "10 ms frames: 100 fps, green (" .. f.text .. ")")
	-- the labels are dim and the same for every state; the numbers are opaque
	local lab = W.rows[2].label
	check(lab.color and alpha_of(lab.color) > 150 and not same_rgb(lab.color, M.net.color_of("ok")), "labels are dim, not the traffic-light colours")
	check(alpha_of(W.rows[2].num.color) == 255, "numbers are opaque")
end)

-- ================================================================ 4. the window: the host
section("host window", function()
	NOW = 300000
	local M = machine(0)
	M.net.set_enabled(true)
	M.players = roster(0, { { id = 1, rtt = 40, loss = 0.002 }, { id = 2, rtt = 160, loss = 0.07 }, { id = 3, rtt = 90, loss = 0.01 } })
	run(M, 900)
	local W = the_window(M)
	check(W ~= nil, "host: the window is on the HUD")
	if not W then error("no window") end
	local ping, loss, pl = row(W, 2), row(W, 3), row(W, 4)
	check(row(W, 1).label == "FPS" and ping.label == "PING max" and loss.label == "LOSS max" and pl.label == "PLAYERS",
		"host rows: FPS, PING max, LOSS max, PLAYERS (" .. ping.label .. ", " .. loss.label .. ", " .. pl.label .. ")")
	check(ping.text == "160 ms" and same_rgb(ping.color, M.net.color_of("bad")), "the worst client's ping (160 ms) in red (" .. ping.text .. ")")
	check(loss.text == "7.0%" and same_rgb(loss.color, M.net.color_of("bad")), "the worst client's loss (7 %) in red (" .. loss.text .. ")")
	check(pl.shown and pl.text == "4", "the player count: 4 (" .. pl.text .. ")")
	-- the worst one leaves: the rest are green
	M.players = roster(0, { { id = 1, rtt = 40, loss = 0.002 } })
	run(M, 300)
	ping, loss, pl = row(W, 2), row(W, 3), row(W, 4)
	check(ping.text == "40 ms" and same_rgb(ping.color, M.net.color_of("ok")) and loss.text == "0.2%" and pl.text == "2",
		"the worst client is gone: 40 ms, 0.2 %, 2 players (" .. ping.text .. ", " .. loss.text .. ", " .. pl.text .. ")")
	-- alone: nothing to measure, a dash in the dim colour, 1 player
	M.players = roster(0, {})
	run(M, 300)
	ping, loss, pl = row(W, 2), row(W, 3), row(W, 4)
	check(ping.text == "-" and loss.text == "-" and pl.text == "1", "alone: '-' for ping and loss, 1 player")
	check(not same_rgb(ping.color, M.net.color_of("ok")) and not same_rgb(ping.color, M.net.color_of("bad")), "a dash is not a verdict (neither green nor red)")
	-- the engine's list fails: the graph shows dashes and the game goes on
	M.players_error = true
	run(M, 300)
	check(row(W, 2).text == "-" and the_window(M) == W, "the player list fails: dashes, the window stays")
	M.players_error = nil
end)

-- ================================================================ 5. when it is hidden
section("hidden", function()
	NOW = 400000
	local M = machine(1)
	M.players = roster(1, { { id = 0, rtt = 45, loss = 0.0 } })
	M.net.set_enabled(true)
	run(M, 400)
	local W = the_window(M)
	check(W ~= nil and W.root.visible, "shown")
	if not W then error("no window") end
	-- the main HUD is hidden (inventory, PDA, a dialogue): like the other HUD windows
	M.hud_shown = false
	run(M, 150)
	check(the_window(M) == W and not W.root.visible, "hidden with the main HUD")
	M.hud_shown = true
	run(M, 150)
	check(W.root.visible, "back with the HUD")
	run(M, 600)
	check(row(W, 2).text == "45 ms", "... and shows current numbers again")
	-- the option is switched off
	M.net.set_enabled(false)
	run(M, 100)
	check(the_window(M) == nil and M.net.get_window() == nil, "option off: the window goes off the HUD")
	M.net.set_enabled(true)
	run(M, 100)
	W = the_window(M)
	check(W ~= nil, "option on again: it is back")
	-- not in a session: gone
	M.active = false
	run(M, 100)
	check(the_window(M) == nil, "no session: hidden")
	M.active = true
	run(M, 100)
	W = the_window(M)
	check(W ~= nil, "a session again: shown")
	-- a client that has not finished loading the host's world
	M.loading = true
	run(M, 100)
	check(the_window(M) == nil, "client still loading: hidden")
	M.loading = nil
	run(M, 100)
	check(the_window(M) ~= nil, "loaded: shown")
	-- no actor (main menu, loading screen)
	local actor = M.env.db.actor
	M.env.db.actor = nil
	run(M, 100)
	check(the_window(M) == nil, "no actor: hidden")
	M.env.db.actor = actor
	run(M, 100)
	-- the level is left: the window goes with the actor
	fire(M, "actor_on_net_destroy")
	check(the_window(M) == nil, "actor destroyed: the window is removed")
end)

-- ================================================================ 6. the update rate
section("update rate", function()
	NOW = 500000
	local M = machine(1)
	M.players = roster(1, { { id = 0, rtt = 45, loss = 0.0 } })
	M.net.set_enabled(true)
	run(M, 100)
	local W = the_window(M)
	if not W then error("no window") end
	M.players_calls = 0
	local sets = {}
	for i = 1, 3 do sets[i] = W.rows[i].num.sets end
	run(M, 2000) -- 125 frames at 16 ms
	check(M.players_calls >= 7 and M.players_calls <= 9, "2 s of frames ask for the player list ~4 times a second (" .. M.players_calls .. ")")
	-- constant numbers are not re-set: the ping text is set once, not 125 times
	check(W.rows[2].num.sets - sets[2] <= 1, "an unchanged ping is not written again (" .. (W.rows[2].num.sets - sets[2]) .. " writes)")
	check(W.rows[3].num.sets - sets[3] <= 1, "an unchanged loss is not written again (" .. (W.rows[3].num.sets - sets[3]) .. " writes)")
	-- the text follows a change within a quarter of a second, not sooner (start right after a refresh)
	local calls = M.players_calls
	repeat run(M, 16) until M.players_calls ~= calls
	M.players = roster(1, { { id = 0, rtt = 120, loss = 0.0 } })
	run(M, 16)
	check(row(W, 2).text == "45 ms", "a change shows at the next refresh, not in the same frame")
	run(M, 300)
	check(row(W, 2).text == "120 ms", "... within ~300 ms")
	check(M.net.REFRESH_MS == 250, "REFRESH_MS = 250 (4 Hz)")
	-- the fps uses a ~0.5 s window: a one-frame stall does not flash red
	run(M, 1000, 16)
	run(M, 60, 60) -- one 60 ms frame
	run(M, 300, 16)
	check(tonumber(row(W, 1).text) >= 50, "a single slow frame does not turn the fps red (" .. row(W, 1).text .. ")")
end)

-- ================================================================ 7. the player option
section("option", function()
	NOW = 600000
	local M = machine(1)
	M.players = roster(1, { { id = 0, rtt = 45, loss = 0.0 } })
	local page = M.menu.build_page()
	local opts = {}
	for _, gr in ipairs(page.gr) do
		if gr.id == "coop_player" then for _, o in ipairs(gr.gr) do opts[o.id] = o end end
	end
	check(opts.netgraph and opts.netgraph.type == "check" and opts.netgraph.def == false and opts.netgraph.cmd == nil,
		"the Co-op page has a check box 'netgraph', off by default, stored in axr_options like the other player options")
	check(opts.compass_hud and opts.compass_hud.def == true and opts.party_hud and opts.party_hud.def == true,
		"the other player options keep their defaults (on)")
	-- stored as coop/coop_player/netgraph; absent = off
	M.menu.apply_player_flags()
	check(M.net.is_enabled() == false, "no stored value: the net graph is off")
	M.options["coop/coop_player/netgraph"] = true
	M.menu.apply_player_flags()
	check(M.net.is_enabled() == true, "stored true: on")
	run(M, 100)
	check(the_window(M) ~= nil, "... and the window appears")
	M.options["coop/coop_player/netgraph"] = false
	M.menu.apply_player_flags()
	run(M, 100)
	check(M.net.is_enabled() == false and the_window(M) == nil, "stored false: off, the window is gone")
	M.options["coop/coop_player/netgraph"] = nil
	M.options["coop/coop_player/compass_hud"] = nil
	M.menu.apply_player_flags()
	check(M.net.is_enabled() == false, "removed: off again (the default is not 'on' like the compass's)")
	-- the change reaches the graph when the options window is accepted and at the first update
	M.options["coop/coop_player/netgraph"] = true
	fire(M, "on_option_change")
	check(M.net.is_enabled() == true, "on_option_change applies it")
	M.options["coop/coop_player/netgraph"] = false
	fire(M, "actor_on_first_update")
	check(M.net.is_enabled() == false, "actor_on_first_update applies it")
	-- an exe without the co-op namespace: nothing is registered, nothing breaks
	local bare = machine(1, { bare = true })
	check(bare.net and bare.cb.actor_on_update == nil and bare.cb.actor_on_net_destroy == nil and the_window(bare) == nil,
		"no co-op engine: the net graph registers nothing")
	bare.menu.apply_player_flags()
	check(true, "... and the options page can still apply its flags")
end)

-- ================================================================ 8. place on the screen, layout lines
section("place on the screen", function()
	NOW = 700000
	for _, dev in ipairs({ { 1920, 1080 }, { 1024, 768 }, { 2560, 1440 } }) do
		DEV.width, DEV.height = dev[1], dev[2]
		local M = machine(0)
		M.players = roster(0, { { id = 1, rtt = 45, loss = 0.0 } })
		M.net.set_enabled(true)
		run(M, 600)
		local W = the_window(M)
		local tag = dev[1] .. "x" .. dev[2]
		check(W ~= nil and W.bg ~= nil, tag .. ": window with a plate")
		if W and W.bg then
			local kx = 1024 * dev[2] / (768 * dev[1])
			local L = M.layout.get()
			local x0, y0, x1, y1 = W.bg.x, W.bg.y, W.bg.x + W.bg.w, W.bg.y + W.bg.h
			check(x1 <= 1024 - 1 and x1 >= 1024 - (L.net_right + 2) * kx and x0 > 700, tag .. ": in the right corner (" .. string.format("%.0f..%.0f", x0, x1) .. ")")
			check(y0 >= 66 and y0 <= 120, tag .. ": under the stock timers (hud_timer ends at 66), y " .. string.format("%.0f", y0))
			-- the compass bar (38 % of the width, centred, 20 + 24 high, its labels 3 + 12 under it) and the team panel
			local bar_x1 = 512 + 1024 * L.bar_width_pct / 100 / 2
			check(x0 > bar_x1 + 20, tag .. ": clear of the compass bar (" .. string.format("%.0f > %.0f", x0, bar_x1) .. ")")
			check(x0 > L.team_x + 240, tag .. ": clear of the team panel at the left")
			-- every row inside the plate
			local inside = true
			for i = 1, 4 do
				local r = W.rows[i]
				if r and r.num.visible then
					local ry = r.num.y
					if r.num.x < x0 or r.num.x + r.num.w > x1 + 0.01 or ry < y0 or ry + r.num.h > y1 + 0.01 then inside = false end
					if r.label.x < x0 or r.label.x + r.label.w > r.num.x + 0.01 then inside = false end
				end
			end
			check(inside, tag .. ": rows inside the plate, label left of the number")
			check(alpha_of(W.bg.tcolor) > 60 and alpha_of(W.bg.tcolor) < 140, tag .. ": a light dark plate (alpha " .. tostring(alpha_of(W.bg.tcolor)) .. ")")
		end
	end
	DEV.width, DEV.height = 1920, 1080
	-- a resolution change moves the block
	local M = machine(0)
	M.players = roster(0, { { id = 1, rtt = 45, loss = 0.0 } })
	M.net.set_enabled(true)
	run(M, 600)
	local W = the_window(M)
	local before = W and W.bg.x
	DEV.width, DEV.height = 1280, 1024 -- 5:4: not the same kx as 16:9
	run(M, 300)
	check(W and before and not near(W.bg.x, before, 0.5) and W.bg.x + W.bg.w <= 1024, "a new resolution re-places it")
	DEV.width, DEV.height = 1920, 1080
	-- the layout lines: the defaults are the ltx numbers
	local Ld = M.layout.DEFAULTS
	local keys = { "net_right", "net_top", "net_w", "net_pad", "net_row", "net_label_w", "net_bg_alpha" }
	local bad = {}
	for _, k in ipairs(keys) do
		local line = INI.data.coop_hud_layout and tonumber(INI.data.coop_hud_layout[k])
		if not (Ld[k] and line and near(Ld[k], line)) then bad[#bad + 1] = k end
	end
	check(#bad == 0, "net_* sizes are in DEFAULTS and in [coop_hud_layout] with the same numbers (" .. table.concat(bad, ", ") .. ")")
	INI.data.coop_hud_layout.net_top = "300"
	M.layout.reload()
	M.net.set_enabled(false)
	run(M, 100)
	M.net.set_enabled(true)
	run(M, 600)
	W = the_window(M)
	check(W and near(W.bg.y, 300, 0.5), "[coop_hud_layout] net_top moves the block (one line)")
	INI.data.coop_hud_layout.net_top = tostring(Ld.net_top)
	M.layout.reload()
end)

-- ================================================================ 9. files: XML, strings
section("files", function()
	check(XML_OK["ui_coop_netgraph.xml"] and WIDE_OK, "ui_coop_netgraph.xml and ui_coop_netgraph_16.xml exist")
	local same = true
	for path in pairs(XML["ui_coop_netgraph.xml"] or {}) do if not WIDE_NODES[path] then same = false end end
	for path in pairs(WIDE_NODES) do if not (XML["ui_coop_netgraph.xml"] or {})[path] then same = false end end
	check(same and next(WIDE_NODES) ~= nil, "the 16:9 copy has the same nodes")
	-- every text node names a font (engine FATAL pTmpFont otherwise); no child window is named 'text'
	local raw = readfile(ROOT .. "configs/ui/ui_coop_netgraph.xml") or ""
	local fonts_ok, n_text = true, 0
	for attrs in raw:gmatch("<text%s([^>]*)/?>") do
		n_text = n_text + 1
		if not attrs:find('font="[%w_]+"') then fonts_ok = false end
	end
	check(n_text > 0 and fonts_ok, "every <text> of ui_coop_netgraph.xml has font= (" .. n_text .. " text nodes)")
	check(not raw:find("<text%s+x=") and not raw:find("<text%s+width="), "no child window is named 'text'")
	-- strings used by the script exist in eng and rus
	local src = readfile(ROOT .. "scripts/coop_hud_netgraph.script") or ""
	local used = {}
	for id in src:gmatch('"(st_coop_netgraph_[%w_]+)"') do used[id] = true end
	used["ui_mm_coop_coop_player_netgraph"] = true
	used["ui_mm_coop_coop_player_netgraph_desc"] = true
	local n, miss_eng, miss_rus = 0, {}, {}
	for id in pairs(used) do
		n = n + 1
		if not ENG_IDS[id] then miss_eng[#miss_eng + 1] = id end
		if not RUS_IDS[id] then miss_rus[#miss_rus + 1] = id end
	end
	check(n >= 8 and #miss_eng == 0, "every string the script and the option use is in eng (" .. n .. " ids; missing: " .. table.concat(miss_eng, ", ") .. ")")
	check(#miss_rus == 0, "... and in rus (missing: " .. table.concat(miss_rus, ", ") .. ")")
	local rus = readfile(ROOT .. "configs/text/rus/st_coop_netgraph.xml") or ""
	check(rus:find('<?xml version="1.0" encoding="windows-1251"?>', 1, true) == 1 and rus:find("\r\n", 1, true) ~= nil, "rus: windows-1251, CRLF")
	-- the texts fit their columns: glyph widths of letterica16 (4:3 units; on a wide screen text and window shrink alike)
	local font = dofile("tests/lua/support/font_letterica.lua")
	local Ld = M0.layout.DEFAULTS
	local num_w = Ld.net_w - 2 * Ld.net_pad - Ld.net_label_w
	for _, lang in ipairs({ { "eng", STR }, { "rus", RUS } }) do
		local tbl = lang[2]
		local worst_label, worst_name = 0, ""
		for _, id in ipairs({ "fps", "ping", "ping_max", "loss", "loss_max", "players" }) do
			local text = tbl["st_coop_netgraph_" .. id]
			local w = text and font.width(font.W16, text) or 9999
			if w > worst_label then worst_label, worst_name = w, id end
		end
		check(worst_label <= Ld.net_label_w, lang[1] .. ": the longest label '" .. worst_name .. "' (" .. worst_label .. " units) fits the label column ("
			.. Ld.net_label_w .. ")")
		local widest = math.max(font.width(font.W16, string.format(tbl.st_coop_netgraph_ms or "%d", 999)),
			font.width(font.W16, "100.0%"), font.width(font.W16, "999"))
		check(widest <= num_w, lang[1] .. ": the widest number (" .. widest .. " units) fits the number column (" .. num_w .. ")")
	end
	check(raw:find('align="r"', 1, true) ~= nil and raw:find('align="l"', 1, true) ~= nil, "labels are left-aligned, numbers right-aligned")
	check(STR.ui_mm_coop_coop_player_netgraph == "Net graph", "eng option caption: 'Net graph'")
	local caption = rus:match('<string id="ui_mm_coop_coop_player_netgraph">%s*<text>(.-)</text>')
	check(caption == "\209\229\242\229\226\238\233 \227\240\224\244\232\234", "rus option caption: 'Сетевой график' (cp1251)")
end)

-- ================================================================
local unk = {}
for k in pairs(UNKNOWN or {}) do unk[#unk + 1] = tostring(k) end
table.sort(unk)
local bad = {}
for _, k in ipairs(unk) do bad[#bad + 1] = k end
check(#bad == 0, "no reads of undefined globals (" .. table.concat(bad, ", ") .. ")")
print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
