-- Anomaly Coop: the opt-in timing of gamedata\scripts\coop_route.script (docs\MEASURE.md): routed handlers and the
-- timing_sites of the watched modules (coop_mods_core: what wrap replaced; coop_mode: what it lists). Off, everything
-- behaves and counts as without it; on, each is counted and timed by a stand-in for the engine's profile_timer (TICK,
-- microseconds); off again, every function is back.
-- coop_route is Core: the cases run under every answer set of the facade coop_mode. Run: tools\test_lua.cmd route_timing

local modes = dofile("tests/lua/support/modes.lua")

-- profile_timer as the engine has it (script_engine_script.cpp): start/stop with a recursion mark, time() in microseconds
TICK = 0
local function fake_profile_timer()
	local t = { acc = 0, mark = 0, at = 0 }
	function t:start()
		self.mark = self.mark + 1
		if self.mark == 1 then self.at = TICK end
	end
	function t:stop()
		if self.mark == 0 then return end
		self.mark = self.mark - 1
		if self.mark == 0 then self.acc = self.acc + (TICK - self.at) end
	end
	function t:time() return self.acc end
	return t
end

local function boot(mode, set)
	MODE = mode
	local passes, fails = PASSES or 0, FAILS or 0
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
	profile_timer = fake_profile_timer
	TICK = 0
	coop_native.reset_counts()
	AddScriptCallback("actor_on_item_use")
	load_script_file("coop_mode")
	modes.install(coop_mode, set)
	-- coop_mode lists two of its questions as a watched module does (the generic path of timing_sites)
	coop_mode.timing_sites = { [coop_mode] = { leads_here = "leads_here", where = "where" } }
	load_script_file("coop_mods_core")
	load_script_file("coop_route")
	assert(coop_route.install() == true, "the shim installs")
end

local function find(list, group, key)
	for _, e in ipairs(list) do
		if e.group == group and e.key == key then return e end
	end
	return nil
end

-- the scene of every case: a handler, a wrapped mod function, the questions of coop_mode
local function scene()
	local s = { runs = 0 }
	s.handler = function(x)
		s.runs = s.runs + 1
		TICK = TICK + 250
		return x
	end
	TIMING_HANDLER = s.handler
	RegisterScriptCallback("actor_on_item_use",
		from_script("some_unknown_mod", "return function(x) return TIMING_HANDLER(x) end"))
	fake_mod_timing = { f = function(a) TICK = TICK + 40; return a * 2 end }
	coop_mods_core.wrap(fake_mod_timing, "f", "fake_mod_timing.f", function(o) return function(a) return o(a) + 1 end end)
	s.mod_fn = fake_mod_timing.f
	s.leads_here = coop_mode.leads_here
	s.where = coop_mode.where
	return s
end

-- three item uses, three mod calls, two questions: what the scene answers
local function play(s)
	for _ = 1, 3 do SendScriptCallback("actor_on_item_use", "medkit") end
	local out = { fake_mod_timing.f(1), fake_mod_timing.f(2), fake_mod_timing.f(3) }
	out[#out + 1] = tostring(coop_mode.leads_here())
	out[#out + 1] = tostring(coop_mode.where(1))
	out[#out + 1] = s.runs
	return table.concat(out, ",")
end

for _, mode in ipairs({ "client", "host" }) do
	for _, set in ipairs(modes.names()) do
		local tag = mode .. "/" .. set

		print("== route_timing_off " .. tag)
		boot(mode, set)
		local s = scene()
		local answer_off = play(s)
		local ran_off = select(1, coop_native.counts("owner"))
		check(coop_route.timing() == false, tag .. ": timing is off by default")
		check(#coop_route.timing_top() == 0, tag .. ": off, no clock has a call")
		check(fake_mod_timing.f == s.mod_fn and coop_mode.leads_here == s.leads_here and coop_mode.where == s.where,
			tag .. ": off, the wrapped function and the questions are the ones the game has")
		check(s.runs == 3, tag .. ": off, the handler ran three times (got " .. s.runs .. ")")

		print("== route_timing_on " .. tag)
		boot(mode, set)
		s = scene()
		check(coop_route.timing(true) == true, tag .. ": timing switches on")
		check(fake_mod_timing.f ~= s.mod_fn and coop_mode.leads_here ~= s.leads_here,
			tag .. ": on, the wrapped function and the questions are timed copies")
		local answer_on = play(s)
		check(answer_on == answer_off, tag .. ": on, every answer is the same (" .. answer_on .. " vs " .. answer_off .. ")")
		local ran_on = select(1, coop_native.counts("owner"))
		check(ran_on == ran_off, tag .. ": on, the engine counts the same runs (" .. tostring(ran_on) .. ")")
		local top = coop_route.timing_top()
		local h = find(top, "route", "actor_on_item_use@some_unknown_mod")
		check(h and h.calls == 3 and math.abs(h.ms - 0.75) < 1e-9,
			tag .. ": the handler: 3 calls, 0.75 ms (got " .. (h and (h.calls .. ", " .. h.ms) or "none") .. ")")
		local m = find(top, "mods", "fake_mod_timing.f")
		check(m and m.calls == 3 and math.abs(m.ms - 0.12) < 1e-9,
			tag .. ": the wrapped mod function: 3 calls, 0.12 ms (got " .. (m and (m.calls .. ", " .. m.ms) or "none") .. ")")
		local q = find(top, "mode", "leads_here")
		check(q and q.calls == 1, tag .. ": the question leads_here: one call")
		check(find(top, "mode", "where") and find(top, "mode", "where").calls == 1, tag .. ": the question where: one call")
		check(top[1].group == "route", tag .. ": by time the handler comes first")
		local by_calls = coop_route.timing_top(2, "calls")
		check(#by_calls == 2 and by_calls[1].calls == 3, tag .. ": timing_top(2, \"calls\"): the two most called")

		print("== route_timing_error " .. tag)
		local fail_with = "timing test: broken handler"
		TIMING_BROKEN = function() TICK = TICK + 5; error(fail_with, 0) end
		RegisterScriptCallback("actor_on_item_use",
			from_script("broken_mod_timing", "return function() return TIMING_BROKEN() end"))
		local ok, err = pcall(SendScriptCallback, "actor_on_item_use", "bandage")
		if mode == "client" then
			check(ok, tag .. ": a client catches the handler's error as without timing")
		else
			check(not ok and err == fail_with, tag .. ": the host raises the same error as without timing (" .. tostring(err) .. ")")
		end
		pcall(SendScriptCallback, "actor_on_item_use", "bandage")
		local b = find(coop_route.timing_top(), "route", "actor_on_item_use@broken_mod_timing")
		check(b and b.calls == 2 and math.abs(b.ms - 0.01) < 1e-9,
			tag .. ": the clock of a failing handler does not stay running (got " .. (b and (b.calls .. ", " .. b.ms) or "none") .. ")")

		print("== route_timing_print " .. tag)
		NOW = NOW + 2000
		local before = #LOG
		check(pcall(coop_route.print_status), tag .. ": print_status runs with the timing lines")
		local longest, lines, rated = 0, 0, false
		for i = before + 1, #LOG do
			if LOG[i]:find("timing by", 1, true) then lines = lines + 1 end
			if LOG[i]:find("timing by ms #1 route actor_on_item_use@some_unknown_mod", 1, true) then
				local calls, rate = LOG[i]:match("(%d+) calls, [%d.]+ us/call, [%d.]+ ms/s, ([%d.]+) calls/s")
				rated = calls ~= nil and math.abs(tonumber(rate) - tonumber(calls) / 2) < 0.06
			end
			longest = math.max(longest, #LOG[i])
		end
		check(lines >= 2 and longest < 900, tag .. ": the timing lines are printed one per function, each short")
		check(rated, tag .. ": the first line by time is the handler, with its calls per second over the 2 s window")

		print("== route_timing_back_off " .. tag)
		check(coop_route.timing(false) == false, tag .. ": timing switches off")
		check(fake_mod_timing.f == s.mod_fn and coop_mode.leads_here == s.leads_here and coop_mode.where == s.where,
			tag .. ": off again, the wrapped function and the questions are the game's own again")
		local calls_before = find(coop_route.timing_top(), "route", "actor_on_item_use@some_unknown_mod").calls
		TIMING_BROKEN = function() end
		play(s)
		h = find(coop_route.timing_top(), "route", "actor_on_item_use@some_unknown_mod")
		check(h and h.calls == calls_before, tag .. ": off again, nothing is counted")
		coop_route.timing_reset()
		check(#coop_route.timing_top() == 0, tag .. ": timing_reset zeroes every clock")
		play(s)
		check(coop_route.timing(true) == true and #coop_route.timing_top() == 0, tag .. ": switching on again starts a new window")
		coop_route.timing(false)
	end
end

print("== route_timing_without_profile_timer")
boot("client", modes.names()[1])
profile_timer = nil
check(coop_route.timing(true) == false and coop_route.timing() == false, "an exe without profile_timer: timing stays off")

print(string.format("%d passed, %d failed", PASSES, FAILS))
