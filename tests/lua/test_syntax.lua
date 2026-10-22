-- Anomaly Coop: every shipped Lua script (gamedata\scripts\*.script) compiles on the engine's LuaJIT 2.0.4.
-- This was the old "runlua.exe -c" syntax pass, now one check per file. Run: tools\test_lua.cmd syntax
local BS = string.char(92)
local PASSES, FAILS = 0, 0

local pipe = assert(io.popen("dir /b /on gamedata" .. BS .. "scripts" .. BS .. "*.script 2>nul"))
local names = {}
for line in pipe:lines() do
	line = line:gsub("\r", "")
	if line ~= "" then names[#names + 1] = line end
end
pipe:close()

if #names == 0 then
	print("  FAIL no scripts found in gamedata/scripts (run from the repository root)")
	FAILS = FAILS + 1
end
for _, name in ipairs(names) do
	local f, err = loadfile("gamedata/scripts/" .. name)
	if f then
		PASSES = PASSES + 1
	else
		FAILS = FAILS + 1
		print("  FAIL " .. name .. ": " .. tostring(err))
	end
end
print(string.format("%d passed, %d failed", PASSES, FAILS))
