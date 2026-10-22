-- Anomaly Coop Lua stub-test driver. Started by tools\test_lua.cmd with the engine's LuaJIT (runlua.exe), cwd = repo root.
-- Runs every tests\lua\test_*.lua in its own Lua state (one runlua.exe process each), reads the "<n> passed, <m> failed"
-- summary line the test printed, prints one row per file and exits with the number of failed files.
-- A file fails when: the process exit code is not 0, the output has SYNTAX/RUNTIME ERROR, any "  FAIL " line,
-- a non-zero failed count, or no summary line at all (a test that dies silently must not look green).
-- Environment: COOP_LUA_RUNLUA (runner exe, default temp\lua\runlua.exe), COOP_LUA_FILTER (space-separated substrings
-- of the file name without "test_" / ".lua"; empty = everything).
local BS = string.char(92)
local RUNLUA = os.getenv("COOP_LUA_RUNLUA") or ("temp" .. BS .. "lua" .. BS .. "runlua.exe")
local OUT_DIR = "temp" .. BS .. "lua" .. BS .. "out"
local TEST_DIR = "tests" .. BS .. "lua"
local FILTER = os.getenv("COOP_LUA_FILTER") or ""

local function filters()
	local list = {}
	for word in FILTER:gmatch("%S+") do list[#list + 1] = word:lower() end
	return list
end

local function wanted(stem, list)
	if #list == 0 then return true end
	for _, word in ipairs(list) do
		if stem:lower():find(word, 1, true) then return true end
	end
	return false
end

local function list_tests()
	local names = {}
	local pipe = assert(io.popen("dir /b /on " .. TEST_DIR .. BS .. "test_*.lua 2>nul"))
	for line in pipe:lines() do
		line = line:gsub("\r", "")
		if line:match("^test_.+%.lua$") then names[#names + 1] = line end
	end
	pipe:close()
	return names
end

local function read_all(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

-- Returns passed, failed (numbers or nil), problems (array of strings), fail_lines (array of strings).
local function judge(text, rc)
	local passed, failed
	for p, f in text:gmatch("(%d+) passed, (%d+) failed") do passed, failed = tonumber(p), tonumber(f) end
	local problems, fail_lines = {}, {}
	if rc ~= 0 then problems[#problems + 1] = "exit code " .. tostring(rc) end
	for line in text:gmatch("[^\r\n]+") do
		if line:find("^%s*FAIL ") then fail_lines[#fail_lines + 1] = line end
		if line:find("SYNTAX ERROR:", 1, true) or line:find("RUNTIME ERROR:", 1, true) then
			problems[#problems + 1] = line
		end
	end
	if not passed then
		problems[#problems + 1] = "no '<n> passed, <m> failed' summary line"
	elseif failed > 0 then
		problems[#problems + 1] = failed .. " failed"
	elseif #fail_lines > 0 then
		problems[#problems + 1] = #fail_lines .. " FAIL line(s) with a clean summary"
	end
	return passed, failed, problems, fail_lines
end

os.execute("mkdir " .. OUT_DIR .. " 2>nul")
local list = filters()
local files_run, files_failed, total_passed, total_failed = 0, 0, 0, 0
local width = 0
local tests = {}
for _, name in ipairs(list_tests()) do
	local stem = name:match("^test_(.+)%.lua$")
	if wanted(stem, list) then
		tests[#tests + 1] = { name = name, stem = stem }
		width = math.max(width, #stem)
	end
end
if #tests == 0 then
	print("[test_lua] no tests match '" .. FILTER .. "'")
	os.exit(1)
end

for _, t in ipairs(tests) do
	local out = OUT_DIR .. BS .. t.stem .. ".txt"
	local rc = os.execute(RUNLUA .. " " .. TEST_DIR .. BS .. t.name .. " > " .. out .. " 2>&1")
	local text = read_all(out) or ""
	local passed, failed, problems, fail_lines = judge(text, rc)
	files_run = files_run + 1
	local counts = passed and string.format("%4d passed, %d failed", passed, failed) or "   - no result"
	if #problems == 0 then
		total_passed = total_passed + passed
		total_failed = total_failed + failed
		print(string.format("  ok    %-" .. width .. "s  %s", t.stem, counts))
	else
		files_failed = files_failed + 1
		total_passed = total_passed + (passed or 0)
		total_failed = total_failed + (failed or 0)
		print(string.format("  FAIL  %-" .. width .. "s  %s", t.stem, counts))
		for _, p in ipairs(problems) do print("          " .. p) end
		for i = 1, math.min(#fail_lines, 10) do print("          " .. fail_lines[i]:gsub("^%s+", "")) end
		if #fail_lines > 10 then print("          ... " .. (#fail_lines - 10) .. " more FAIL lines") end
		print("          full output: " .. out)
	end
end

print(string.format("[test_lua] %d files, %d failed; %d checks passed, %d failed", files_run, files_failed, total_passed, total_failed))
os.exit(files_failed)
