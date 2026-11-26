-- coop_route's opt-in timing (docs\MEASURE.md) over the questions coop_mode lists in its own timing_sites: off, every
-- question is the facade's own function (nothing on its path); on, each question is counted under the clock group
-- "mode" with the same answers; off again, every question is back.
-- coop_mode is Core: the cases run under every answer set of the facade. Run: tools\test_lua.cmd mode_timing

local modes = dofile("tests/lua/support/modes.lua")

-- profile_timer as the engine has it: start/stop with a recursion mark, time() in microseconds
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

-- every question once, with an argument where it takes one; what they answer, as one line
local CALLS = {
	{ "where", 1 }, { "decider", 1 }, { "actor_is_player" }, { "decides_world" }, { "leads_here" }, { "is_player_mirror" },
	{ "seat_plays", 1 }, { "group_travels" }, { "leads_for_world_elsewhere" }, { "writes", 100 }, { "presence", "l01", nil },
	{ "op_done", { origin = 1, seq = 1 }, "ok" }, { "from_level", 0x101 }, { "facts_of", 1 }, { "hook", "x" }, { "far" },
}

local function ask_all(F)
	local out = {}
	for _, c in ipairs(CALLS) do
		local v = F[c[1]](c[2], c[3])
		out[#out + 1] = type(v) == "table" and "table" or tostring(v)
	end
	return table.concat(out, ",")
end

local function find(list, group, key)
	for _, e in ipairs(list) do
		if e.group == group and e.key == key then return e end
	end
	return nil
end

for _, set in ipairs(modes.names()) do
	print("== mode_timing " .. set)
	MODE = "host"
	local passes, fails = PASSES or 0, FAILS or 0
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
	profile_timer = fake_profile_timer
	local F = load_script_file("coop_mode")
	modes.install(F, set)
	load_script_file("coop_mods_core")
	load_script_file("coop_route")
	check(coop_route.install() == true, set .. ": the shim installs")

	local own = {}
	for _, c in ipairs(CALLS) do own[c[1]] = F[c[1]] end
	local answer_off = ask_all(F)
	local leads = F.leads_here()
	check(coop_route.timing() == false and #coop_route.timing_top() == 0, set .. ": timing is off, no clock")

	check(coop_route.timing(true) == true, set .. ": timing switches on")
	local swapped = true
	for _, c in ipairs(CALLS) do swapped = swapped and F[c[1]] ~= own[c[1]] end
	check(swapped, set .. ": on, every question is a timed copy")
	local answer_on = ask_all(F)
	check(answer_on == answer_off, set .. ": on, the same answers (" .. answer_on .. ")")
	local top = coop_route.timing_top(100, "calls")
	local counted = true
	for _, c in ipairs(CALLS) do
		local e = find(top, "mode", c[1])
		-- leads_for_world_elsewhere asks leads_here, and decides_world when it leads here: those count their own calls too
		local want = 1
		if c[1] == "leads_here" then want = 2 end
		if c[1] == "decides_world" and leads then want = 2 end
		counted = counted and e ~= nil and e.calls == want
		if not counted then
			print("   " .. c[1] .. ": " .. tostring(e and e.calls))
			break
		end
	end
	check(counted, set .. ": every question is counted under the group mode")

	check(coop_route.timing(false) == false, set .. ": timing switches off")
	local back = true
	for _, c in ipairs(CALLS) do back = back and F[c[1]] == own[c[1]] end
	check(back and ask_all(F) == answer_off, set .. ": off again, every question is the facade's own function")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
