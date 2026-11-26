-- Anomaly Coop: the glare of another player's head torch (scripts\coop_hud_glare.script). The pure strength and fade, the
-- overlay on a stub engine (who shines, walls and the 100 ms ray limit, the fade, what hides it), the assets it names
-- (ui_coop_glare.xml, textures_descr, the DDS), the route it gets, the engine export it calls.
-- Game objects here are userdata, as in the game (support\luabind_like.lua): a `type(x) == "table"` on them is false.
-- Run: tools\test_lua.cmd hud_glare   (VERBOSE=1 for logs)
dofile("tests/lua/support/luabind_like.lua")
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

-- a section that dies is a FAIL line, not a silent stop
local function section(name, fn)
	print("== " .. name)
	local ok, err = pcall(fn)
	if not ok then
		FAILS = FAILS + 1
		print("  FAIL section '" .. name .. "' crashed: " .. tostring(err))
	end
end

local function near(a, b, eps) return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-6) end

-- ---------------------------------------------------------------- the stand
local NOW = 100000
local UNKNOWN = {}
local DEV = { width = 1920, height = 1080 }

local function vec(x, y, z)
	local t = { x = x or 0, y = y or 0, z = z or 0 }
	function t:set(a, b, c)
		self.x, self.y, self.z = a, b, c
		return self
	end
	return luabind_object(t)
end

local function window(path)
	local w = { path = path, children = {}, x = 0, y = 0, w = 0, h = 0, visible = true }
	function w:SetWndPos(v) self.x, self.y = v.x, v.y end
	function w:SetWndSize(v) self.w, self.h = v.x, v.y end
	function w:Show(b) self.visible = b end
	function w:IsShown() return self.visible end
	function w:SetTextureColor(c) self.tcolor = c end
	return w
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

-- A machine with a friend (peer 1, character 300) 5 m ahead of my camera, looking straight at me with his head torch on.
local function machine(opts)
	opts = opts or {}
	local M = {
		log = {}, cb = {}, hud = {}, made = {}, asked = {}, rays = {}, life = {},
		peers = { { id = 0, nick = "me", avatar_id = 0, is_self = true }, { id = 1, nick = "friend", avatar_id = 300 } },
		lamps = { [300] = { 0, 0, -1 } },
		heads = { [300] = { 0, 1.7, 5 } },
		cam = vec(0, 1.7, 0),
		view = vec(0, 0, 1),
		session = true,
	}
	local env = setmetatable({}, { __index = function(_, k)
		local v = _G[k]
		if v == nil then UNKNOWN[k] = true end
		return v
	end })
	env._G = env
	M.env = env
	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		M.log[#M.log + 1] = ok and line or tostring(fmt)
		if os.getenv("VERBOSE") then print("    " .. M.log[#M.log]) end
	end
	env.time_global = function() return NOW end
	env.game = {
		world2ui = function(p, hud, offscreen)
			M.w2ui_args = { hud = hud, offscreen = offscreen }
			if M.off_screen or p.z <= M.cam.z then return { x = -9999, y = 0 } end
			return { x = 512 + (p.x - M.cam.x) * 40, y = 384 - (p.y - M.cam.y) * 40 }
		end,
	}
	env.GetARGB = function(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
	env.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	env.vector = function() return vec() end
	env.CScriptXmlInit = function()
		local x = {}
		function x:ParseFile(f) M.xml_file = f end
		function x:InitStatic(path, parent)
			local w = window(path)
			M.made[#M.made + 1] = w
			if parent and parent.children then parent.children[#parent.children + 1] = w end
			return w
		end
		return x
	end
	env.device = function()
		return { width = DEV.width, height = DEV.height, cam_pos = M.cam, cam_dir = M.view }
	end
	env.class = class_stub
	env.super = function() end
	env.CUIScriptWnd = { Update = function() end }
	env.get_hud = function()
		return { AddDialogToRender = function(_, w) M.hud[w] = true end, RemoveDialogToRender = function(_, w) M.hud[w] = nil end }
	end
	env.main_hud_shown = function() return M.hud_shown ~= false end
	env.RegisterScriptCallback = function(name, f)
		M.cb[name] = M.cb[name] or {}
		table.insert(M.cb[name], f)
	end
	M.actor = luabind_object({ id = function() return 0 end })
	env.db = { actor = M.actor }
	env.level = {
		object_by_id = function(id)
			local h = M.heads[id]
			if not h then return nil end
			return luabind_object({
				id = function() return id end,
				bone_position = function(_, bone)
					M.bone = bone
					return vec(h[1], h[2], h[3])
				end,
			})
		end,
	}
	-- the ray: M.ray(r) -> false (nothing on the way) | true, object | nil (hit the level's geometry)
	env.ray_pick = function()
		local r = {}
		function r:set_flags(v) self.flags = v end
		function r:set_range(v) self.range = v end
		function r:set_position(v) self.pos = { x = v.x, y = v.y, z = v.z } end
		function r:set_direction(v) self.dir = { x = v.x, y = v.y, z = v.z } end
		function r:set_ignore_object(o) self.ignore = o end
		function r:query()
			M.rays[#M.rays + 1] = self
			if M.ray_fails then error("no such overload") end
			if not M.ray then return false end
			local hit, obj = M.ray(self)
			self.obj = obj
			return hit
		end
		function r:get_object() return self.obj end
		return luabind_object(r)
	end
	if not opts.no_engine then
		local api = {
			is_active = function() return M.session end,
			is_host = function() return M.session end,
			is_live = function() return M.session end,
			players = function()
				local list = {}
				for i, p in ipairs(M.peers) do list[i] = p end
				return list
			end,
			life_of = function(id) return M.life[id] or "alive" end,
		}
		if not opts.old_engine then
			api.avatar_headlamp = function(id)
				M.asked[id] = (M.asked[id] or 0) + 1
				local l = M.lamps[id]
				if not l then return false end
				return true, l[1], l[2], l[3]
			end
		end
		env.coop = api
	end
	for _, name in ipairs({ "coop_util", "coop_hud_kit", "coop_mode", "coop_hostplay_mode", "coop_srv_mode", "coop_hud_glare" }) do
		local src = assert(readfile(ROOT .. "scripts/" .. name .. ".script"), "no " .. name .. ".script")
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		local f = assert(loadstring(src, "@" .. name .. ".script"))
		setfenv(f, mod)
		f()
	end
	env.coop_hostplay_mode.on_game_start()
	env.coop_srv_mode.on_game_start()
	M.g = env.coop_hud_glare
	M.g.on_game_start()
	return M
end

local function frames(M, ms)
	local stop = NOW + ms
	while NOW < stop do
		NOW = NOW + 16
		for _, f in ipairs(M.cb.actor_on_update or {}) do f() end
		for w in pairs(M.hud) do w:Update() end
	end
end

local function spots(M)
	local list = {}
	for _, w in ipairs(M.made) do
		if w.path == "coop_glare:spot" and w.visible then list[#list + 1] = w end
	end
	return list
end

local function alpha(w) return math.floor(w.tcolor / 16777216) end

local function fired(cb, M)
	for _, f in ipairs(M.cb[cb] or {}) do f() end
end

-- ---------------------------------------------------------------- pure logic (one state for all of it)
local P = machine().g
local RANGE, ALPHA, FADE = P.RANGE, P.MAX_ALPHA, P.FADE_MS

section("constants of the request", function()
	check(RANGE == 20, "range 20 m")
	check(near(ALPHA, 0.45), "at most 0.45 opaque")
	check(FADE == 150, "the fade takes 150 ms")
	check(P.RAY_GAP_MS == 100, "one ray in 100 ms")
end)

local function at(x, y, z) return { x = x, y = y, z = z } end
local CAM, VIEW = at(0, 1.7, 0), at(0, 0, 1)

-- the lamp `d` m ahead on my view line, its beam and my view `beam_deg` / `view_deg` off the straight line between us
local function s_at(d, beam_deg, view_deg)
	local b, v = math.rad(beam_deg or 0), math.rad(view_deg or 0)
	return P.strength(CAM, at(math.sin(v), 0, math.cos(v)), at(0, 1.7, d), at(math.sin(b), 0, -math.cos(b)))
end

section("strength: the two angles and the distance", function()
	check(near(s_at(2), 1), "2 m, right in the face: full")
	check(near(s_at(3), 1), "3 m: still full")
	check(s_at(20) == 0, "20 m: nothing")
	check(s_at(25) == 0, "25 m: nothing")
	local s5, s10, s15, s19 = s_at(5), s_at(10), s_at(15), s_at(19)
	check(s5 > s10 and s10 > s15 and s15 > s19 and s19 > 0, "closer is stronger, smoothly (" ..
		table.concat({ s5, s10, s15, s19 }, " ") .. ")")
	check(s_at(5, 180) == 0, "his lamp shines away from me: nothing")
	check(s_at(5, 90) == 0, "his lamp shines to the side: nothing")
	check(s_at(5, 45) == 0, "45 deg off his beam: nothing")
	check(s_at(5, 0, 180) == 0, "I look away from him: nothing")
	check(s_at(5, 0, 90) == 0, "he is at the edge of my view: nothing")
	check(s_at(5, 0, 45) == 0, "45 deg off my view: nothing")
	local b15, b0 = s_at(5, 15), s_at(5, 0)
	check(b15 > 0 and b15 < b0, "15 deg off his beam: weaker, not gone (" .. b15 .. ")")
	local v15 = s_at(5, 0, 15)
	check(v15 > 0 and v15 < b0, "15 deg off my view: weaker, not gone (" .. v15 .. ")")
	check(s_at(5, 15, 15) < math.min(b15, v15), "both angles count at once")
	check(near(s_at(5, 15), s_at(5, -15)) and near(s_at(5, 0, 15), s_at(5, 0, -15)), "left and right are the same")
	check(s_at(0) == 0, "the same point has no direction: 0, not NaN")
	local nan = 0 / 0
	check(P.strength(CAM, VIEW, at(0, 1.7, 5), at(nan, nan, nan)) == 0, "a NaN beam: 0")
	check(P.strength(CAM, VIEW, at(nan, 1.7, 5), at(0, 0, -1)) == 0, "a NaN lamp: 0")
end)

section("fade, opacity, size", function()
	check(near(P.fade(0, 1, FADE / 2), 0.5), "half way up in half the time")
	check(near(P.fade(0, 1, FADE), 1), "all the way up in 150 ms")
	check(near(P.fade(1, 0, FADE / 2), 0.5), "half way down in half the time")
	check(near(P.fade(1, 0, FADE), 0), "all the way down in 150 ms")
	check(P.fade(0, 0.3, 500) == 0.3 and P.fade(0.8, 0.3, 500) == 0.3, "never past the target")
	check(P.fade(0.4, 1, -50) == 0.4 and P.fade(0.4, 1, 0) == 0.4, "time going back changes nothing")
	check(near(P.opacity(1), 0.45) and P.opacity(0) == 0 and near(P.opacity(0.5), 0.225), "opacity: value * 0.45")
	check(P.opacity(1.5) <= 0.45 + 1e-9, "never over 0.45")
	check(P.spot_size(0) > 0 and P.spot_size(1) > P.spot_size(0.5) and P.spot_size(0.5) > P.spot_size(0), "a stronger glare is a bigger spot")
	check(P.spot_size(1) <= 768 / 3, "at most a third of the screen's height: the friend stays visible")
end)

-- ---------------------------------------------------------------- the overlay
section("a lamp in my face", function()
	local M = machine()
	frames(M, 16)
	check(next(M.hud) ~= nil, "the overlay is on the HUD in a session")
	check(M.xml_file == "ui_coop_glare.xml", "layout ui_coop_glare.xml")
	frames(M, 48)
	local l = spots(M)
	check(#l == 1, "one spot")
	local rising = l[1] and alpha(l[1]) or 0
	check(rising > 0, "it starts to show (alpha " .. rising .. ")")
	frames(M, 150)
	l = spots(M)
	local a = l[1] and alpha(l[1]) or -1
	check(a > rising and a <= math.floor(255 * ALPHA), "it grew, no more than 0.45 (alpha " .. a .. ")")
	check(a >= 100, "at 5 m right in the face it is close to the most (alpha " .. a .. ")")
	frames(M, 500)
	check(spots(M)[1] and alpha(spots(M)[1]) == a, "and stays")
	local w = spots(M)[1]
	check(M.bone == "bip01_head", "the head bone")
	check(M.w2ui_args and M.w2ui_args.hud == false and M.w2ui_args.offscreen == false, "world2ui of the world, off screen = none")
	check(near(w.x + w.w / 2, 512, 2), "centred on him horizontally (" .. (w.x + w.w / 2) .. ")")
	check(near(w.y + w.h / 2, 384, 8), "at his head (" .. (w.y + w.h / 2) .. ")")
	check(near(w.w / w.h, 1024 * DEV.height / (768 * DEV.width), 1e-6), "round on a wide screen")
	check(w.tcolor % 16777216 == 0xFFFFFF, "no tint: the texture's own warm white")
end)

section("who shines", function()
	local M = machine()
	M.lamps[300] = nil
	frames(M, 300)
	check(#spots(M) == 0, "his lamp is off: nothing")

	M = machine()
	M.peers = { M.peers[1] }
	M.lamps[0] = { 0, 0, -1 }
	M.heads[0] = { 0, 1.7, 5 }
	frames(M, 300)
	check(#spots(M) == 0 and not M.asked[0], "my own lamp: not even asked")

	M = machine()
	M.lamps[400] = { 0, 0, -1 } -- an NPC: on the level, shining, not in coop.players()
	M.heads[400] = { 0, 1.7, 5 }
	M.lamps[300] = nil
	frames(M, 300)
	check(#spots(M) == 0 and not M.asked[400], "an NPC's lamp: not even asked")

	M = machine()
	M.peers[2].avatar_id = nil -- a player still loading
	frames(M, 300)
	check(#spots(M) == 0, "a player with no character here: nothing")

	M = machine()
	M.heads[300] = nil -- on another level
	frames(M, 300)
	check(#spots(M) == 0, "his character is not on this level: nothing")

	M = machine()
	M.peers[3] = { id = 2, nick = "other", avatar_id = 301 }
	M.lamps[301] = { 0, 0, -1 }
	M.heads[301] = { 1, 1.7, 8 }
	frames(M, 300)
	check(#spots(M) == 2, "two friends: two spots")
	M.peers[3] = nil
	frames(M, 150)
	check(#spots(M) == 1, "one left the session: his spot goes")
end)

section("walls", function()
	local M = machine()
	M.ray = function() return true, nil end -- the level's geometry
	frames(M, 300)
	check(#spots(M) == 0, "behind a wall: nothing")
	check(#M.rays > 0, "the ray was cast")
	local r = M.rays[1]
	check(near(r.pos.x, 0) and near(r.pos.y, 1.7) and near(r.pos.z, 0), "the ray starts at my camera")
	check(near(r.dir.z, 1, 0.01) and near(r.dir.x * r.dir.x + r.dir.y * r.dir.y + r.dir.z * r.dir.z, 1), "a unit ray toward him")
	check(r.range > 4 and r.range < 5, "it stops short of his head (" .. r.range .. ")")
	check(r.flags == 3, "the level and objects (rqtBoth, 3)")
	check(r.ignore == M.actor, "my own body does not count")

	M.ray = nil
	frames(M, 300)
	check(#spots(M) == 1, "the wall is gone: the spot comes back")

	M.ray = function() return true, luabind_object({ id = function() return 77 end }) end
	frames(M, 300)
	check(#spots(M) == 0, "somebody stands between us: nothing")

	M.ray = function() return true, luabind_object({ id = function() return 300 end }) end
	frames(M, 300)
	check(#spots(M) == 1, "the ray hit his own body: it is no wall")

	M.ray_fails = true
	frames(M, 300)
	check(#spots(M) == 0, "a ray that fails shows nothing")
	local logged = 0
	for _, line in ipairs(M.log) do if line:find("glare", 1, true) then logged = logged + 1 end end
	check(logged == 1, "and says so once (" .. logged .. ")")
end)

section("the ray limit", function()
	local M = machine()
	frames(M, 1000)
	check(#M.rays >= 9 and #M.rays <= 11, "one player: one ray in 100 ms (" .. #M.rays .. " in 1 s)")

	M = machine()
	M.peers[3] = { id = 2, nick = "other", avatar_id = 301 }
	M.lamps[301] = { 0, 0, -1 }
	M.heads[301] = { 1, 1.7, 8 }
	frames(M, 1000)
	check(#M.rays >= 18 and #M.rays <= 22, "two players: one ray each in 100 ms (" .. #M.rays .. " in 1 s)")

	M = machine()
	M.lamps[300] = { 0, 0, 1 }
	frames(M, 500)
	check(#M.rays == 0, "his lamp shines away: no ray")

	M = machine()
	M.view:set(0, 0, -1)
	frames(M, 500)
	check(#M.rays == 0, "I look away: no ray")

	M = machine()
	M.heads[300] = { 0, 1.7, 30 }
	frames(M, 500)
	check(#M.rays == 0, "too far: no ray")

	M = machine()
	M.lamps[300] = nil
	frames(M, 500)
	check(#M.rays == 0, "lamp off: no ray")

	M = machine()
	M.hud_shown = false
	frames(M, 500)
	check(#M.rays == 0, "HUD hidden: no ray")
end)

section("the fade on the screen", function()
	local M = machine()
	frames(M, 500)
	local full = alpha(spots(M)[1])
	M.lamps[300] = nil
	frames(M, 64)
	local l = spots(M)
	local mid = l[1] and alpha(l[1]) or -1
	check(mid > 0 and mid < full, "the lamp went off: it fades (" .. mid .. " of " .. full .. ")")
	frames(M, 112)
	check(#spots(M) == 0, "gone in about 150 ms")

	-- no blinking when a ray says "blocked" for one moment
	M = machine()
	frames(M, 500)
	M.ray = function() return true, nil end
	frames(M, 16)
	M.ray = nil
	local lowest = 255
	for _ = 1, 8 do
		frames(M, 16)
		local s = spots(M)[1]
		lowest = math.min(lowest, s and alpha(s) or 0)
	end
	check(lowest > 0, "a blocked ray for one moment does not blink it to nothing (lowest " .. lowest .. ")")
end)

section("what hides it", function()
	local function hidden_by(what, set, clear)
		local M = machine()
		frames(M, 300)
		check(#spots(M) == 1, what .. ": it was on")
		set(M)
		frames(M, 16)
		check(#spots(M) == 0, what .. ": gone at once")
		frames(M, 200)
		check(#spots(M) == 0, what .. ": stays gone")
		clear(M)
		frames(M, 300)
		check(#spots(M) == 1, what .. ": back after it")
	end
	hidden_by("HUD hidden (menu, PDA, inventory)", function(M) M.hud_shown = false end, function(M) M.hud_shown = true end)
	hidden_by("I am down", function(M) M.life[0] = "wounded" end, function(M) M.life[0] = nil end)
	hidden_by("I am dead", function(M) M.life[0] = "dead" end, function(M) M.life[0] = nil end)
	hidden_by("I am spectating", function(M) M.life[0] = "spectating" end, function(M) M.life[0] = nil end)
	hidden_by("I am respawning", function(M) M.life[0] = "respawning" end, function(M) M.life[0] = nil end)
	hidden_by("no actor", function(M) M.env.db.actor = nil end, function(M) M.env.db.actor = M.actor end)

	local function faded_by(what, set)
		local M = machine()
		frames(M, 300)
		set(M)
		frames(M, 200)
		check(#spots(M) == 0, what .. ": no glare from him")
	end
	faded_by("he is down", function(M) M.life[300] = "wounded" end)
	faded_by("he is dead", function(M) M.life[300] = "dead" end)
	faded_by("he is respawning", function(M) M.life[300] = "respawning" end)

	local M = machine()
	frames(M, 300)
	M.off_screen = true
	frames(M, 16)
	check(#spots(M) == 0, "off the screen: no spot")
end)

section("the session and old engines", function()
	local M = machine()
	frames(M, 300)
	check(next(M.hud) ~= nil, "in a session: on the HUD")
	M.session = false
	frames(M, 16)
	check(next(M.hud) == nil, "the session ended: off the HUD")
	M.session = true
	frames(M, 16)
	check(next(M.hud) ~= nil, "a new session: back on the HUD")
	fired("actor_on_net_destroy", M)
	check(next(M.hud) == nil, "the level goes: off the HUD")

	M = machine({ old_engine = true })
	frames(M, 300)
	check(next(M.cb) == nil and next(M.hud) == nil, "an exe without coop.avatar_headlamp: nothing runs")
	M = machine({ no_engine = true })
	frames(M, 300)
	check(next(M.cb) == nil and next(M.hud) == nil, "an exe without co-op: nothing runs")

	M = machine()
	frames(M, 300)
	M.env.level.object_by_id = function() error("boom") end
	frames(M, 300)
	local logged = 0
	for _, line in ipairs(M.log) do if line:find("glare", 1, true) then logged = logged + 1 end end
	check(logged == 1, "a frame that fails is logged once and rests (" .. logged .. ")")
	check(#spots(M) == 0, "and leaves nothing on the screen")
end)

section("frame cost", function()
	local M = machine()
	M.peers = { M.peers[1] }
	for i = 1, 7 do
		M.peers[#M.peers + 1] = { id = i, nick = "p" .. i, avatar_id = 300 + i }
		M.lamps[300 + i] = { 0, 0, -1 }
		M.heads[300 + i] = { i * 0.1, 1.7, 5 }
	end
	local f = 3000
	local t0 = os.clock()
	frames(M, f * 16)
	local per_frame = (os.clock() - t0) * 1000 / f
	check(per_frame < 0.5, string.format("seven lit friends: well under 0.5 ms a frame in the stubs (%.3f ms)", per_frame))
	check(#spots(M) == 7, "seven spots")
end)

-- ---------------------------------------------------------------- the files it names
local function xml_nodes(file)
	local raw = readfile(file)
	if not raw then return {} end
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
	return nodes, src
end

section("layout and texture", function()
	local layout = ROOT .. "configs/ui/ui_coop_glare.xml"
	local nodes, src = xml_nodes(layout)
	check(nodes["coop_glare"] ~= nil, "layout: the root node")
	check(nodes["coop_glare:spot"] and nodes["coop_glare:spot"].stretch == "1", "layout: a stretched spot")
	local tex = src and src:match("<spot.-<texture>([%w_]+)</texture>")
	check(tex == "coop_glare_spot", "layout: the texture id (" .. tostring(tex) .. ")")

	local descr = ROOT .. "configs/ui/textures_descr/ui_coop_glare.xml"
	local raw_descr = readfile(descr)
	check(raw_descr and raw_descr:find('<file name="ui\\coop\\ui_coop_glare">', 1, true) ~= nil, "textures_descr: the file")
	local x, y, w, h = (raw_descr or ""):match('<texture id="coop_glare_spot" x="(%d+)" y="(%d+)" width="(%d+)" height="(%d+)"')
	check(x == "0" and y == "0" and w == "128" and h == "128", "textures_descr: the whole image")

	for _, f in ipairs({ layout, descr }) do
		local raw = readfile(f) or ""
		check(raw:sub(1, 2) == "<?" and raw:find('encoding="windows-1251"', 1, true) ~= nil, f .. ": cp1251 header")
		check(raw:find("\r\n", 1, true) ~= nil and not raw:gsub("\r\n", ""):find("\n", 1, true), f .. ": CRLF")
	end

	local dds = readfile(ROOT .. "textures/ui/coop/ui_coop_glare.dds")
	check(dds ~= nil, "the DDS exists")
	if not dds then return end
	local function u32(at_)
		local a, b, c, d = dds:byte(at_ + 1, at_ + 4)
		return a + b * 256 + c * 65536 + d * 16777216
	end
	check(dds:sub(1, 4) == "DDS " and u32(4) == 124, "DDS magic")
	check(u32(12) == 128 and u32(16) == 128, "128x128")
	check(#dds == 128 + 128 * 128 * 4, "one level, no mips")
	check(u32(84) == 0 and u32(88) == 32, "uncompressed, 32 bits")
	check(u32(92) == 0xFF0000 and u32(96) == 0xFF00 and u32(100) == 0xFF and u32(104) == 0xFF000000, "A8R8G8B8")
	local function px(ix, iy)
		local o = 128 + (iy * 128 + ix) * 4
		local b, g, r, a = dds:byte(o + 1, o + 4)
		return r, g, b, a
	end
	local _, _, _, centre = px(64, 64)
	check(centre > 200, "a bright centre (" .. centre .. ")")
	local edge = 0
	for i = 0, 127 do
		edge = math.max(edge, select(4, px(i, 0)), select(4, px(i, 127)), select(4, px(0, i)), select(4, px(127, i)))
	end
	check(edge == 0, "nothing on the border: no square shows")
	local falling, prev = true, 256
	for i = 64, 127 do
		local a = select(4, px(i, 64))
		if a > prev then falling = false end
		prev = a
	end
	check(falling, "alpha falls off from the centre")
	local r, g, b = px(64, 64)
	check(r == 255 and r > g and g > b, "warm white (" .. r .. "," .. g .. "," .. b .. ")")
	local r0, g0, b0 = px(0, 0)
	check(r0 == r and g0 == g and b0 == b, "the same colour under alpha 0: no dark fringe")
end)

local function ltx_section(raw, name)
	local out, inside = {}, false
	for line in (raw or ""):gmatch("[^\r\n]+") do
		local clean = line:gsub(";.*$", "")
		local s = clean:match("^%s*%[([%w_]+)%]")
		if s then
			inside = s == name
		elseif inside then
			local k, v = clean:match("^%s*([%w_%*@%.]+)%s*=%s*(%S*)")
			if k then out[k] = v end
		end
	end
	return out
end

section("the route: every machine runs it", function()
	local main = readfile(ROOT .. "configs/coop_route.ltx")
	check(ltx_section(main, "route_scripts")["coop_*"] == "view", "coop_* = view: host and clients")
	local pipe = io.popen("dir /b gamedata\\configs\\coop_route*.ltx 2>nul")
	local n = 0
	for line in pipe:lines() do
		n = n + 1
		local raw = readfile(ROOT .. "configs/" .. line:gsub("\r", ""))
		for key in pairs(ltx_section(raw, "route_scripts")) do
			local stem = key:gsub("%*$", "")
			if key ~= "coop_*" and ("coop_hud_glare"):sub(1, #stem) == stem then
				check(false, line .. ": " .. key .. " takes the script off view")
			end
		end
		local forced = ltx_section(raw, "route_callbacks_forced")
		check(forced.actor_on_update == nil and forced.actor_on_net_destroy == nil, line .. ": its callbacks are not forced")
	end
	pipe:close()
	check(n >= 2, "the route files were read (" .. n .. ")")
end)

section("the engine export", function()
	local src = (readfile("engine/src/xrGame/coop/coop_script.cpp") or ""):gsub("\r\n", "\n") -- a checkout may have either line end
	check(src:find('{"avatar_headlamp", &l_avatar_headlamp}', 1, true) ~= nil, "coop.avatar_headlamp is registered")
	local body = src:match("int l_avatar_headlamp%(lua_State%* L%)(.-)\n}\n") or ""
	check(body:find("arg_local_id", 1, true) ~= nil, "a wrong argument gives false, not an error")
	check(body:find("players::avatar_headlamp", 1, true) ~= nil, "the torch flag of coop_equip")
	check(body:find("players::avatar_view", 1, true) ~= nil, "the view of the character")
	check(body:find("setHP(yaw, -pitch)", 1, true) ~= nil, "the beam's direction, as place_light aims it")
	local equip = readfile("engine/src/xrGame/coop/coop_equip.cpp") or ""
	check(equip:find("dir.setHP(view_yaw, -view_pitch);", 1, true) ~= nil, "place_light still aims it so")
	local api = readfile("docs/COOP_API.md") or ""
	check(api:find("coop.avatar_headlamp", 1, true) ~= nil, "documented in docs\\COOP_API.md")
end)

section("the script reads no unknown globals", function()
	local list = {}
	for k in pairs(UNKNOWN) do
		if k ~= "profile_timer" and k ~= "coop_hud_markers" then list[#list + 1] = tostring(k) end
	end
	table.sort(list)
	check(#list == 0, "no reads of undefined globals (" .. table.concat(list, ", ") .. ")")
end)

print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
