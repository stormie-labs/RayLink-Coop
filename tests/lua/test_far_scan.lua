-- Split levels: the far view works on what the task scripts read while they run. This reads the scripts of the GAMMA profile
-- (E:\GAMMA, the winner of each file by modlist.txt, the stock under it) and fails on what would slip past it:
--   a script that keeps level.object_by_id, level.name and the like in a file-scope local before coop_quests_core wraps them;
--   a file-scope local of db.anomaly_by_name (the far view swaps that table for one call) or of alife (the same);
--   `.online` of a smart in a task script that no rewrite of coop_npc_compat covers: it is a field of a C++ class;
--   a rewrite of coop_npc_compat that does not fit the profile's version.
-- Without E:\GAMMA the test says so and passes. Run: tools\test_lua.cmd far_scan
PASSES, FAILS = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local BS = string.char(92)
-- the MO2 folder of the profile: where the launcher keeps it now, then where it was before the move (2026-11)
local ROOTS = { "E:" .. BS .. "RayLinkGames" .. BS .. "GAMMA" .. BS .. "mo2", "E:" .. BS .. "GAMMA" }
local GAMMA = ROOTS[1]
local STOCK = ".." .. BS .. "anomaly-ref" .. BS .. "unpacked" .. BS .. "scripts"
local PROFILES = { "G.A.M.M.A original 920", "G.A.M.M.A. original 920", "G.A.M.M.A" }

local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local modlist = nil
for _, root in ipairs(ROOTS) do
	for _, name in ipairs(PROFILES) do
		if not modlist then
			modlist = read(root .. BS .. "profiles" .. BS .. name .. BS .. "modlist.txt")
			if modlist then GAMMA = root end
		end
	end
end
if not modlist then
	print("  (" .. GAMMA .. " not found: the scan is skipped)")
	print("0 passed, 0 failed")
	return
end

local mods = {} -- the first wins: MO2 writes the highest priority first
for line in modlist:gmatch("[^\r\n]+") do
	if line:sub(1, 1) == "+" then mods[#mods + 1] = line:sub(2) end
end

local function winner(name)
	for _, m in ipairs(mods) do
		local s = read(GAMMA .. BS .. "mods" .. BS .. m .. BS .. "gamedata" .. BS .. "scripts" .. BS .. name .. ".script")
		if s then return s end
	end
	return read(STOCK .. BS .. name .. ".script")
end

-- every tasks_*.script any mod or the stock has
local names = { task_functor = true, task_status_functor = true, nta_utils = true, new_tasks_addon_tasks_utils = true }
local function add_names(cmd)
	local pipe = io.popen(cmd)
	if not pipe then return end
	for line in pipe:lines() do
		local n = line:match("([%w_]+)%.script%s*$")
		if n then names[n] = true end
	end
	pipe:close()
end
add_names('dir /b "' .. STOCK .. BS .. 'tasks_*.script" 2>nul')
add_names('dir /b "E:' .. BS .. 'AnomalyCoopGamma' .. BS .. 'gamedata' .. BS .. 'scripts' .. BS .. 'tasks_*.script" 2>nul')
add_names('dir /b "E:' .. BS .. 'RayLinkGames' .. BS .. 'GAMMA' .. BS .. 'game-dev' .. BS .. 'gamedata' .. BS .. 'scripts' .. BS .. 'tasks_*.script" 2>nul')

local sources = {}
local count = 0
for n in pairs(names) do
	sources[n] = winner(n)
	if sources[n] then count = count + 1 end
end
check(count >= 20, "the task scripts of the profile are found (" .. count .. ")")

-- The rewrites of coop_npc_compat, from its source: a table of plain pairs, read as Lua.
local compat = assert(read("gamedata" .. BS .. "scripts" .. BS .. "coop_npc_compat.script"))
local body = compat:match("local REWRITES = (%b{})")
assert(body, "REWRITES not found in coop_npc_compat")
local REWRITES = assert(loadstring("return " .. body))()

local function rewritten(name, src)
	for _, pr in ipairs(REWRITES[name] or {}) do
		local out, at = {}, 1
		local n = 0
		while true do
			local i, j = src:find(pr[1], at, true)
			if not i then break end
			n = n + 1
			out[#out + 1] = src:sub(at, i - 1)
			out[#out + 1] = pr[2]
			at = j + 1
		end
		out[#out + 1] = src:sub(at)
		check(n >= 1 and (pr.all or n == 1), name .. ": a rewrite does not fit the profile: " .. pr[1])
		src = table.concat(out)
	end
	return src
end

local CAUGHT_LOCAL = { "level%.object_by_id", "level%.name", "level%.vertex_id" }
local SWAPPED_LOCAL = { "db%.anomaly_by_name", "alife%s*$", "alife%s*,", "simulation_objects%.is_on_the_actor_level" }
local WRAPPED_BY = "coop_quests_core"

for name, src in pairs(sources) do
	for line in src:gmatch("[^\r\n]+") do
		local value = line:match("^local%s+[%w_,%s]+=%s*(.+)$")
		if value then
			if name < WRAPPED_BY then
				for _, pat in ipairs(CAUGHT_LOCAL) do
					check(not value:find(pat), name .. " keeps it in a local before the far view is there: " .. line)
				end
			end
			for _, pat in ipairs(SWAPPED_LOCAL) do
				check(not value:find(pat), name .. " keeps in a local what the far view swaps: " .. line)
			end
		end
	end
	local after = rewritten(name, src)
	for var in after:gmatch("([%w_]*sm[a-z]*t)%.online") do
		check(false, name .. ": " .. var .. ".online is not rewritten")
	end
	-- a smart under another name (tasks_assault walks SIMBOARD.smarts_by_names with `v`)
	for line in after:gmatch("[^\r\n]+") do
		if line:find("smarts_by_names", 1, true) and line:find(".online", 1, true) then
			check(false, name .. ": a smart's .online: " .. line)
		end
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
