-- Anomaly Coop Lua stub-test driver. Started by tools\test_lua.cmd with the engine's LuaJIT (runlua.exe), cwd = repo root.
-- Runs every tests\lua\test_*.lua in its own Lua state (one runlua.exe process each), reads the "<n> passed, <m> failed"
-- summary line the test printed, prints one row per file and exits with the number of failed files.
-- A file fails when: the process exit code is not 0, the output has SYNTAX/RUNTIME ERROR, any "  FAIL " line,
-- a non-zero failed count, or no summary line at all (a test that dies silently must not look green).
-- The runs are independent processes, so they go in parallel: JOBS lanes (cmd processes) work through one list, and a
-- lane takes a run by creating its claim folder (mkdir succeeds for one lane only). Everything a run writes is its own:
-- its output, its exit code and its scratch folder (COOP_LUA_SCRATCH, tests\lua\support\scratch.lua) live in this run's
-- folder <out>\run_<random>, and the rows are judged from there only, so a second run at the same time, even with the same
-- <out>, never judges another run's output. The outputs are then moved to <out>\<row>.txt and the run folder is removed.
-- Environment: COOP_LUA_RUNLUA (runner exe, default temp\lua\runlua.exe), COOP_LUA_FILTER (space-separated substrings
-- of the file name without "test_" / ".lua"; empty = everything), COOP_LUA_OUT (per-file output folder, default
-- temp\lua\out), COOP_LUA_JOBS (lanes, default the number of processors, at most 8: other agents' runs share the machine).
local BS = string.char(92)
local RUNLUA = os.getenv("COOP_LUA_RUNLUA") or ("temp" .. BS .. "lua" .. BS .. "runlua.exe")
local OUT_DIR = os.getenv("COOP_LUA_OUT") or ("temp" .. BS .. "lua" .. BS .. "out")
if not OUT_DIR:match("^[%w_%.\\/:%-]+$") then error("COOP_LUA_OUT: letters, digits and _ . - \\ / : only") end
OUT_DIR = OUT_DIR:gsub("/", BS)
local TEST_DIR = "tests" .. BS .. "lua"
local FILTER = os.getenv("COOP_LUA_FILTER") or ""
local JOBS = tonumber(os.getenv("COOP_LUA_JOBS") or "") or math.min(tonumber(os.getenv("NUMBER_OF_PROCESSORS") or "") or 4, 8)

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
	if rc == nil then
		problems[#problems + 1] = "no exit code: the run did not finish"
	elseif rc ~= 0 then
		problems[#problems + 1] = "exit code " .. tostring(rc)
	end
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

-- A Core test that loops over the answer sets (modes.names( / modes.each(, tests/lua/support/modes.lua) runs once per set of the facade coop_mode
-- (docs/MODES.md section 10, COOP_LUA_MODE), its row named <stem>@<set>. Every other test runs once, without the variable.
local SETS = { "hostplay", "srv_world", "srv_map", "none" }
local function runs_of(list)
	local out = {}
	for _, t in ipairs(list) do
		local text = read_all(TEST_DIR .. BS .. t.name) or ""
		if text:find("modes.names(", 1, true) or text:find("modes.each(", 1, true) then
			for _, set in ipairs(SETS) do out[#out + 1] = { name = t.name, stem = t.stem .. "@" .. set, set = set } end
		else
			out[#out + 1] = t
		end
	end
	return out
end

-- This run's own folder: mkdir fails when it exists, so two runs never share one.
local function run_folder()
	local seed = os.time() + math.floor(os.clock() * 1000000) + (tonumber(tostring({}):match("0x(%x+)") or "0", 16) or 0)
	math.randomseed(seed % 2147483647)
	for _ = 1, 20 do
		local dir = OUT_DIR .. BS .. "run_" .. string.format("%08x", math.random(0, 2147483646))
		if os.execute('mkdir "' .. dir .. '" 2>nul') == 0 then return dir end
	end
	error("cannot create a run folder in " .. OUT_DIR)
end

-- One cmd line per run: claim it, then run it with its answer set and its scratch folder, its exit code to <row>.rc.
local function lane_script(runs, dir)
	local lines = { "@echo off", "setlocal EnableDelayedExpansion" }
	for i, t in ipairs(runs) do
		local o = dir .. BS .. "o" .. BS .. t.stem
		lines[#lines + 1] = string.format(
			'mkdir "%s\\c\\%d" 2>nul && (set "COOP_LUA_MODE=%s"& set "COOP_LUA_SCRATCH=%s\\s\\%s"& ' ..
			'%s %s\\%s > "%s.txt" 2>&1 & >"%s.rc" echo !errorlevel!)',
			dir, i, t.set or "", dir, t.stem, RUNLUA, TEST_DIR, t.name, o, o)
	end
	local path = dir .. BS .. "lane.cmd"
	local fh = assert(io.open(path, "wb"))
	fh:write(table.concat(lines, "\r\n"), "\r\n")
	fh:close()
	return path
end

os.execute('mkdir "' .. OUT_DIR .. '" 2>nul')
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

local runs = runs_of(tests)
local dir = run_folder()
os.execute('mkdir "' .. dir .. BS .. 'c" "' .. dir .. BS .. 'o" "' .. dir .. BS .. 's" 2>nul')
local lane = lane_script(runs, dir)
local lanes = math.max(1, math.min(JOBS, #runs))
print(string.format("[test_lua] %d runs in %d lanes", #runs, lanes))
local pipes = {}
for i = 1, lanes do pipes[i] = assert(io.popen(lane)) end
for _, pipe in ipairs(pipes) do -- a lane's pipe ends when the lane has no run left to claim
	pipe:read("*a")
	pipe:close()
end

for _, t in ipairs(runs) do
	local o = dir .. BS .. "o" .. BS .. t.stem
	local out = OUT_DIR .. BS .. t.stem .. ".txt"
	local text = read_all(o .. ".txt") or ""
	local rc = tonumber((read_all(o .. ".rc") or ""):match("%-?%d+"))
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
os.execute('move /y "' .. dir .. BS .. 'o' .. BS .. '*.txt" "' .. OUT_DIR .. '" >nul 2>nul')
os.execute('rd /s /q "' .. dir .. '" 2>nul')

print(string.format("[test_lua] %d files, %d failed; %d checks passed, %d failed", files_run, files_failed, total_passed, total_failed))
os.exit(files_failed)
