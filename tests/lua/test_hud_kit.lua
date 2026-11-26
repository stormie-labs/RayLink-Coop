-- coop_hud_kit and coop_hud_hold (Core): the widget kit answers what the overlays' copies answer, and the hold machine
-- goes through the same states, fires on the same frames and drops for the same reasons as the arena board's copy
-- (coop_hud_arena.script, written out below as the oracle), over random key and frame sequences. live() asks the facade
-- outside a pcall: a failing engine stamp in the facade must not raise out of it.
-- Runs under every test answer set (tests\lua\support\modes.lua, COOP_LUA_MODE). Not shipped.
-- Run: tools\test_lua.cmd hud_kit
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")
local K = load_script("coop_hud_kit")
local Hd = load_script("coop_hud_hold")

local calls = {}
local function window()
	local w = { shown = false }
	function w:Show(on) calls[#calls + 1] = "show " .. tostring(on); self.shown = on end
	function w:SetTextureColor(c) calls[#calls + 1] = "color " .. tostring(c) end
	function w:SetWndPos(v) calls[#calls + 1] = "pos " .. v.x .. "," .. v.y end
	function w:SetWndSize(v) calls[#calls + 1] = "size " .. v.x .. "," .. v.y end
	return w
end
function GetARGB(a, r, g, b) return ((a * 256 + r) * 256 + g) * 256 + b end
function vector2()
	local v = {}
	function v:set(x, y) self.x, self.y = x, y return self end
	return v
end

-- golden: the overlays' live() (coop_hud_arena:100 and five more, the same body)
local api = coop
local function old_live()
	if not api then return false end
	local ok, on = pcall(function() return api.is_active() and (coop_mode.decides_world() or api.is_live()) end)
	return ok and on == true
end

-- golden: coop_hud_arena's key and hold machine (drop_hold, step_hold's key and HUD steps, start, press, hold, release)
local function arena_machine(gap, ms)
	local m = { key = { down = false, events_at = nil, seen = false, latched = false }, hold = nil, out = {} }
	local key = m.key
	local function drop_hold(tg, why)
		if not m.hold then return end
		if not m.hold.fired and why then m.out[#m.out + 1] = string.format("drop %d %s", tg - m.hold.since, why) end
		m.hold = nil
		if key.down then key.latched = true end
	end
	function m.frame(tg, visible)
		if key.down and key.seen and key.events_at and tg - key.events_at > gap then
			key.down, key.seen, key.latched = false, false, false
			drop_hold(tg, "the key's events stopped")
		end
		if not m.hold then return end
		local hold = m.hold
		if visible then
			hold.hidden_at = nil
		elseif not hold.hidden_at then
			hold.hidden_at = tg
		elseif tg - hold.hidden_at > gap then
			drop_hold(tg, "the HUD is hidden")
			return
		end
		if not hold.fired and tg - hold.since >= ms then
			hold.fired = true
			m.out[#m.out + 1] = "fire " .. (tg - hold.since)
		end
	end
	local function start_hold(tg)
		if m.hold or key.latched then return end
		m.hold = { since = tg, fired = false }
	end
	function m.press(tg)
		key.down, key.events_at, key.seen, key.latched = true, tg, false, false
		start_hold(tg)
	end
	function m.hold_event(tg)
		if not key.down then key.down, key.latched = true, false end
		key.events_at, key.seen = tg, true
		start_hold(tg)
	end
	function m.release(tg)
		key.down, key.seen, key.latched = false, false, false
		if m.hold then drop_hold(tg, string.format("let go after %d ms", tg - m.hold.since)) end
	end
	function m.fraction(tg)
		if not (m.hold and not m.hold.fired) then return 0 end
		return math.max(0, math.min(1, (tg - m.hold.since) / ms))
	end
	return m
end

-- the same board on coop_hud_hold
local function kit_machine(gap, ms)
	local m = { out = {} }
	local h = Hd.new(gap, function(hold, tg, why) m.out[#m.out + 1] = string.format("drop %d %s", tg - hold.since, why) end)
	m.h = h
	function m.frame(tg, visible)
		if not h:key_step(tg) then return end
		if h:hidden_step(tg, visible, "the HUD is hidden") then return end
		if h:due(tg, ms) then m.out[#m.out + 1] = "fire " .. (tg - h.hold.since) end
	end
	function m.press(tg)
		h:press(tg)
		if h:may_start() then h:start(tg) end
	end
	function m.hold_event(tg)
		h:hold_event(tg)
		if h:may_start() then h:start(tg) end
	end
	function m.release(tg)
		h:release(tg, h.hold and string.format("let go after %d ms", tg - h.hold.since))
	end
	function m.fraction(tg) return h:fraction(tg, ms) end
	return m
end

local function same_state(a, b)
	local ka, kb = a.key, b.h.key
	if ka.down ~= kb.down or ka.events_at ~= kb.events_at or ka.seen ~= kb.seen or ka.latched ~= kb.latched then return false end
	local ha, hb = a.hold, b.h.hold
	if (ha == nil) ~= (hb == nil) then return false end
	if ha and (ha.since ~= hb.since or ha.fired ~= hb.fired or ha.hidden_at ~= hb.hidden_at) then return false end
	return true
end

local function run(name)
	print("== " .. name .. ": live")
	local same = true
	for _, mode in ipairs({ "host", "client", "sp" }) do
		MODE = mode
		for _, is_live in ipairs({ true, false }) do
			coop.is_live = function() return is_live end
			same = same and K.live() == old_live()
		end
		coop.is_live = function() error("no exe export") end
		same = same and K.live() == old_live()
	end
	coop.is_active = function() error("engine fault") end
	same = same and K.live() == false and old_live() == false
	coop.is_active = function() return MODE ~= "sp" end
	coop.is_live = function() return true end
	MODE = "host"
	check(same, "live() = the overlays' live() in every session state")

	print("== " .. name .. ": widgets")
	local t = K.el(window())
	calls = {}
	K.show(t, 1)
	K.show(t, true)
	K.show(t, nil)
	K.tint(t, 127.6, { 1, 2, 3 })
	K.tint(t, 128, { 1, 2, 3 })
	K.tint(t, 300, { 1, 2, 3 })
	K.put(t, 1, 2)
	K.put(t, 1, 2, 3, 4)
	K.put(t, 1, 2, 3, 4)
	local want = { "show true", "show false", "color " .. GetARGB(128, 1, 2, 3), "color " .. GetARGB(255, 1, 2, 3), "pos 1,2",
		"size 3,4" }
	same = #calls == #want
	for i = 1, #want do same = same and calls[i] == want[i] end
	check(same, "show by the flag, tint rounds and clamps, put only on a change: one engine call per change")

	print("== " .. name .. ": hold")
	math.randomseed(7)
	same = true
	local fired, dropped = 0, 0
	for _ = 1, 300 do
		local a, b = arena_machine(300, 1000), kit_machine(300, 1000)
		local tg = 1000
		for _ = 1, 60 do
			tg = tg + 50 * math.random(0, 8) -- steps of 50 ms: the edges (300, 1000) are hit exactly
			local r = math.random(1, 10)
			local visible = math.random(1, 4) > 1
			if r == 1 then a.press(tg); b.press(tg)
			elseif r == 2 then a.release(tg); b.release(tg)
			elseif r <= 5 then a.hold_event(tg); b.hold_event(tg)
			else a.frame(tg, visible); b.frame(tg, visible) end
			same = same and same_state(a, b) and a.fraction(tg) == b.fraction(tg)
		end
		same = same and #a.out == #b.out
		for i = 1, #a.out do
			same = same and a.out[i] == b.out[i]
			if a.out[i]:find("^fire") then fired = fired + 1 else dropped = dropped + 1 end
		end
		b.h:reset()
		same = same and b.h.hold == nil and not b.h.key.down and b.h.key.events_at == nil
	end
	check(same and fired > 20 and dropped > 20, "300 random sequences: the same states, fires and drops as the arena's machine")
	local m = kit_machine(300, 1000)
	m.press(0)
	m.h:latch()
	m.h:drop(10)
	check(not m.h:may_start() and #m.out == 0, "latch: no new hold until the key is let go; a drop without a reason logs nothing")
	m.release(20)
	check(m.h:may_start(), "let go: a new hold may start")
	local idle = Hd.new(300, function() error("a drop without a hold") end)
	local ok, r = pcall(idle.hidden_step, idle, 10, false, "the HUD is hidden")
	local ok2, r2 = pcall(idle.hidden_step, idle, 1000, false, "the HUD is hidden")
	check(ok and ok2 and r == false and r2 == false and idle.hold == nil, "hidden_step with no hold: nothing changes, false")

	print("== " .. name .. ": live with a failing coop.mode_stamp")
	coop.mode_stamp = function() error("stamp fault", 0) end
	local broken = load_script("coop_mode") -- the global coop_mode the kit asks
	coop.mode_stamp = nil
	modes.install(broken, name)
	same = true
	for _, mode in ipairs({ "host", "client", "sp" }) do
		MODE = mode
		local ok_live, v = pcall(K.live)
		same = same and ok_live and v == old_live()
	end
	MODE = "host"
	coop_mode = facade
	check(same, "the facade's questions never raise: live() answers as the overlays' copies")
end

modes.each(facade, run)

-- golden: the boards' copies the kit replaces (coop_hud_transition / coop_hud_arena / coop_hud_revive, the same bodies)
local function old_alpha_step(a, target, dt, in_ms, out_ms)
	dt = dt or 0
	if target > a then return math.min(target, a + (in_ms > 0 and dt / in_ms or 1)) end
	return math.max(target, a - (out_ms > 0 and dt / out_ms or 1))
end
local function old_nick_of(state, peer)
	peer = tonumber(peer)
	if not peer then return "?" end
	local tg = time_global()
	if not state.at or tg - state.at > 500 or tg < state.at then
		state.at, state.map = tg, {}
		local ok, list = pcall(coop.players)
		if ok and type(list) == "table" then
			for _, p in ipairs(list) do
				if type(p) == "table" and tonumber(p.id) then state.map[tonumber(p.id)] = tostring(p.nick or "") end
			end
		end
	end
	local nick = state.map[peer]
	if nick and nick ~= "" then
		nick = nick:gsub("%%", "")
		if #nick > 24 then nick = nick:sub(1, 23) .. "." end
		return nick
	end
	return "player " .. tostring(peer)
end

print("== the kit's other parts")
local same = true
for _, a in ipairs({ 0, 0.25, 0.9, 1 }) do
	for _, target in ipairs({ 0, 1 }) do
		for _, dt in ipairs({ 0, 16, 60, 500 }) do
			for _, ms in ipairs({ { 120, 200 }, { 0, 150 }, { 150, 0 } }) do
				same = same and K.alpha_step(a, target, dt, ms[1], ms[2]) == old_alpha_step(a, target, dt, ms[1], ms[2])
			end
		end
	end
end
check(same and K.alpha_step(0.5, 1, nil, 120, 200) == 0.5, "alpha_step: the boards' fades; no dt is no step")

local W, H = 1920, 1080
function device() return { width = W, height = H } end
local m1 = K.metrics()
local m2 = K.metrics()
W = 2560
local m3 = K.metrics()
check(m1 == m2 and m1.W == 1920 and m1.H == 1080 and m1.kx == 1024 * 1080 / (768 * 1920) and m1.px == 1024 / 1920
	and m1.py == 768 / 1080 and m3 ~= m1 and m3.W == 2560, "metrics: one table while the screen stays, a new one when it changes")

local function text_window(log_)
	local w = {}
	function w:SetText(s) log_[#log_ + 1] = "text " .. s end
	function w:SetTextColor(c) log_[#log_ + 1] = "tcolor " .. c end
	function w:SetWndPos(v) log_[#log_ + 1] = "pos " .. v.x .. "," .. v.y end
	function w:SetWndSize(v) log_[#log_ + 1] = "size " .. v.x .. "," .. v.y end
	function w:Show(on) log_[#log_ + 1] = "show " .. tostring(on) end
	return w
end
local tlog = {}
local xml = { InitTextWnd = function() return text_window(tlog) end }
local t = K.new_text(xml, nil, "node")
K.text_set(t, "hi", 200, { 1, 2, 3 })
K.text_set(t, "hi", 200, { 1, 2, 3 })
K.text_place(t, 10, 20, 30, 40, { px = 0.5, py = 0.7 })
K.text_show(t, true)
K.text_show(t, true)
local want = { "text hi", "text hi", "tcolor " .. GetARGB(200, 1, 2, 3), "tcolor " .. GetARGB(140, 0, 0, 0), "pos 10,20", "size 30,40",
	"pos 10.5,20.7", "size 30,40", "show true", "show true" }
same = #tlog == #want
for i = 1, #want do same = same and tlog[i] == want[i] end
check(same, "a text with its shadow: set once per change, the shadow black at 0.7 of the alpha, one pixel right and down")

calls = {}
local e = K.el(window(), 0, 0, 0, 0)
K.put(e, 0, 0)
K.color(e, 5)
K.color(e, 5)
K.put(e, 1, 0)
check(#calls == 2 and calls[1] == "color 5" and calls[2] == "pos 1,0", "el with the place it stands at: put skips it; color once per value")

local self_id = 3
coop.self_id = function() return self_id end
local mine = K.my_peer()
self_id = -1
local none = K.my_peer()
coop.self_id = function() error("no session") end
check(mine == 3 and none == nil and K.my_peer() == nil, "my_peer: the peer id, nil for a negative one or an engine fault")

coop_allies = { color = function(peer) if peer == 9 then error("bad") end return 10 + peer, 20, 30 end }
local c1, c2, c3 = K.peer_color(2, "fb"), K.peer_color(9, "fb"), K.peer_color("x", "fb")
coop_allies = nil
check(c1[1] == 12 and c1[2] == 20 and c1[3] == 30 and c2 == "fb" and c3 == "fb" and K.peer_color(1, "fb") == "fb",
	"peer_color: the palette, else the caller's fallback")

local roster = { { id = 1, nick = "Strelok" }, { id = 2, nick = "100%_" .. string.rep("x", 30) }, { id = 4, nick = "" } }
coop.players = function() return roster end
local kit_nick, state = K.nick_labels(500), {}
same = true
for _, step in ipairs({ 0, 100, 501, 0, 600 }) do
	NOW = (NOW or 0) + step
	if step == 501 then roster = { { id = 1, nick = "Renamed" } } end
	for _, peer in ipairs({ 1, 2, 3, 4, "x", nil }) do same = same and kit_nick(peer) == old_nick_of(state, peer) end
end
check(same and kit_nick(1) == "Renamed" and K.clean_nick(nil) == "?", "nick_labels: the boards' nicks, read again when 500 ms old")

dik_to_bind = function(dik) if dik == 1 then return 7 end if dik == 2 then error("no bind") end return 0 end
key_bindings = { kUSE = 7 }
check(Hd.is_use_key(1) and not Hd.is_use_key(2) and not Hd.is_use_key(3), "is_use_key: the key bound to use; a fault is not it")
done("HUD_KIT")
