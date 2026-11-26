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
done("HUD_KIT")
