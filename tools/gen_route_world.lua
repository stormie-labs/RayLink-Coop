-- Anomaly Coop: generates gamedata\configs\coop_route_stock.ltx and coop_route_gamma.ltx (rulings F2-28, F2-29):
-- a script that calls world functions does not run on a client, as before F2 T10.
-- Usage (repository root; tools\test_lua.cmd builds the runner):
--   set GAMMA_SCRIPTS=E:\AnomalyCoopGamma\gamedata\scripts&& temp\lua\runlua.exe tools\gen_route_world.lua
-- STOCK_SCRIPTS (default ..\anomaly-ref\unpacked\scripts, the unpacked Anomaly 1.5.3 db) overlaid by
-- engine\gamedata\scripts (monolith) and gamedata\scripts (ours) gives the stock set; GAMMA_SCRIPTS is GAMMA's loose
-- scripts folder (without it only coop_route_stock.ltx is written).
-- A script (key as the engine's routes::script_key gives it) is written "= host" when
--   1. its file calls a WORLD function below (a plain, case-sensitive substring);
--   2. it has no [route_scripts] rule of its own in the other configs\coop_route*.ltx / coop_compat_*.ltx;
--   3. the Lua filter before F2 T10 did not run it on a client: it keyed a file by its base name and took that name's
--      [route_scripts] rule (the same entries now; its blocked is host), a name without a rule was host.
-- Registrations do not matter for the choice (a function is routed by the file that defines it, whoever registers it,
-- literally or not); the comment of a line lists the literal ones: RegisterScriptCallback("<callback>"), AddUniqueCall
-- (unique_call), CreateTimeEvent (time_event). A GAMMA key already in coop_route_stock.ltx is not repeated. Comments are
-- left out of the scan (review N2).
-- Rerun after a GAMMA or Anomaly update or a change of the other route files, then run tools\test_lua.cmd (its
-- route_shim_generated_lists_do_not_shadow_rules check fails when a hand rule matches a generated key, review N1).
local BS = string.char(92)
local CFG = "gamedata" .. BS .. "configs" .. BS
local OUT_STOCK, OUT_GAMMA = "coop_route_stock.ltx", "coop_route_gamma.ltx"

local function env_dir(name, default)
	local v = os.getenv(name) or default
	if not v then return nil end
	v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\]+$", "") -- cmd's "set X=... && ..." keeps the blank
	return v ~= "" and v or nil
end
local STOCK = env_dir("STOCK_SCRIPTS", ".." .. BS .. "anomaly-ref" .. BS .. "unpacked" .. BS .. "scripts")
local GAMMA = env_dir("GAMMA_SCRIPTS")
local STOCK_DIRS = { STOCK, "engine" .. BS .. "gamedata" .. BS .. "scripts", "gamedata" .. BS .. "scripts" }

ROUTE_SKIP_FILES = { [OUT_STOCK] = true, [OUT_GAMMA] = true }
dofile("tests/lua/support/stubs.d/route.lua")
route_stub_load()
if #ROUTE_ERRORS > 0 then
	print("coop_route*.ltx has errors: " .. table.concat(ROUTE_ERRORS, " | "))
	os.exit(3)
end

-- F2-28's list, plus (F2-29 review I1) a release through the simulator or safe_release_manager and an NPC logic
-- switch (logic_enforcer, release_body_manager, safe_release_manager).
local WORLD = { "alife():create", "alife_create", "alife():release", "alife_release", "create_squad", "SIMBOARD",
	"give_info", "disable_info", "set_community_goodwill", "change_faction_relations", "set_relation", "transfer_item",
	":kill(", "sim:release(", "safe_release_manager.release", "xr_logic.switch_to_section" }

-- The [route_scripts] rule of a name: the exact key, else the longest prefix (a key ending in *); nil without one.
local function rule_of(name)
	local d = ROUTE_SCRIPT_RULES[name]
	if d then return d end
	local best
	for key, dom in pairs(ROUTE_SCRIPT_RULES) do
		if key:sub(-1) == "*" then
			local p = key:sub(1, -2)
			if name:sub(1, #p) == p and (not best or #p > #best[1]) then best = { p, dom } end
		end
	end
	return best and best[2] or nil
end

local function list(dir, recursive)
	local out = {}
	local s = recursive and "/s " or ""
	local pipe = assert(io.popen('dir /b ' .. s .. '"' .. dir .. BS .. '*.script" "' .. dir .. BS .. '*.lua" 2>nul'))
	for line in pipe:lines() do
		line = line:gsub("\r", "")
		if line ~= "" then out[#out + 1] = recursive and line or (dir .. BS .. line) end
	end
	pipe:close()
	return out
end

local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return "" end
	local s = fh:read("*a")
	fh:close()
	return s
end

-- The code of a Lua file without its comments (review N2): --[[ ... ]] / --[==[ ... ]==] blocks, then -- to the end of
-- the line. A "--" inside a string literal cuts that line short, which only makes the scan see less.
local function code_of(src)
	src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "")
	return (src:gsub("%-%-[^\n]*", ""))
end

local function world_calls(src)
	local n = 0
	for _, w in ipairs(WORLD) do
		local at = 1
		while true do
			local s, e = src:find(w, at, true)
			if not s then break end
			n = n + 1
			at = e + 1
		end
	end
	return n
end

local function registrations(src)
	local set, out = {}, {}
	for cb in src:gmatch("RegisterScriptCallback%s*%(%s*[\"']([%w_]+)[\"']") do set[cb] = true end
	if src:find("AddUniqueCall%s*%(") then set.unique_call = true end
	if src:find("CreateTimeEvent%s*%(") then set.time_event = true end
	for cb in pairs(set) do out[#out + 1] = cb end
	table.sort(out)
	return out
end

-- files: { key -> path } (a later path replaces an earlier one). Returns rows, scanned, with_world, with_rule.
local function survey(files, skip_keys)
	local keys = {}
	for k in pairs(files) do keys[#keys + 1] = k end
	table.sort(keys)
	local rows, with_world, with_rule = {}, 0, 0
	for _, key in ipairs(keys) do
		local path = files[key]
		local src = code_of(read(path))
		local calls = world_calls(src)
		if calls > 0 and not skip_keys[key] then
			with_world = with_world + 1
			local base = (path:match("([^\\/]+)%.[sS][cC][rR][iI][pP][tT]$") or path:match("([^\\/]+)%.[lL][uU][aA]$") or "?"):lower()
			local old = rule_of(base)
			if rule_of(key) then
				with_rule = with_rule + 1
			elseif not (old == "owner" or old == "view") then
				rows[#rows + 1] = { key = key, calls = calls, regs = registrations(src) }
			end
		end
	end
	return rows, #keys, with_world, with_rule
end

local function write(name, title, source_line, rows, scanned, with_world, with_rule)
	local out = {}
	local function add(s) out[#out + 1] = s end
	local literal = 0
	for _, r in ipairs(rows) do if #r.regs > 0 then literal = literal + 1 end end
	add("; Anomaly Coop - " .. title .. " that stay on the host (rulings F2-28, F2-29), read by the engine after")
	add("; configs\\coop_route.ltx like every coop_route_*.ltx (same sections and rules, see there).")
	add(";")
	add("; GENERATED by tools\\gen_route_world.lua - do not edit by hand. Rerun it after a GAMMA or Anomaly update or a")
	add("; change of the other route files, then run tools\\test_lua.cmd:")
	add(";   set GAMMA_SCRIPTS=E:\\AnomalyCoopGamma\\gamedata\\scripts&& temp\\lua\\runlua.exe tools\\gen_route_world.lua")
	add("; Since F2 T10 a script without a rule follows its callback (actor_* owner: runs on a client, review R5 I4); before,")
	add("; it was host. A script below calls a world function (alife():create / alife_create / ..._release, create_squad,")
	add("; SIMBOARD, give_info / disable_info, relations, transfer_item, :kill, sim:release, safe_release_manager.release,")
	add("; xr_logic.switch_to_section), has no rule of its own and did not run on a client before T10, so it keeps that:")
	add("; until the call router (F2 T12) gates world calls a client running it could")
	add("; duplicate items, artefacts or infos.")
	add("; A client that needs one of them shows it in coop_status ([coop] routes: most skipped / latest new skips). Give")
	add("; that script its own rule in a configs\\coop_compat_<mod>.ltx: those are read last and win over this file, and")
	add("; the next run of the generator leaves the script out.")
	add(string.format("; Generated %s from %s:", os.date("%Y-%m-%d"), source_line))
	add(string.format(";   %d scripts, %d call world functions, %d of those have a rule; %d below (%d register a handler",
		scanned, with_world, with_rule, #rows, literal))
	add(";   literally, the others are routed when somebody else registers their functions).")
	add("; Comment of a line: world calls in the file | literal registrations (unique_call / time_event: timers).")
	add("")
	add("[route_scripts]")
	for _, r in ipairs(rows) do
		local regs = {}
		for i = 1, math.min(#r.regs, 4) do regs[i] = r.regs[i] end
		local more = #r.regs > 4 and (" +" .. (#r.regs - 4)) or ""
		add(string.format("%-40s = host   ; %3d | %s%s", r.key, r.calls, #regs > 0 and table.concat(regs, " ") or "-", more))
	end
	add("")
	local fh = assert(io.open(CFG .. name, "wb"))
	fh:write(table.concat(out, "\n"))
	fh:close()
	print(string.format("%s: %d scripts = host (%d scanned, %d with world calls, %d of those have a rule, %d register "
		.. "a handler literally)", CFG .. name, #rows, scanned, with_world, with_rule, literal))
end

-- stock: the db, then monolith's and our loose scripts over it
local stock_files = {}
for _, dir in ipairs(STOCK_DIRS) do
	for _, path in ipairs(list(dir, false)) do stock_files[coop_native.script_key("@" .. path)] = path end
end
local n = 0
for _ in pairs(stock_files) do n = n + 1 end
if n < 100 then
	print("too few stock scripts (" .. n .. ") under " .. STOCK .. ": set STOCK_SCRIPTS to the unpacked Anomaly scripts")
	os.exit(4)
end
local stock_rows, s_scanned, s_world, s_rule = survey(stock_files, {})
write(OUT_STOCK, "stock Anomaly scripts", STOCK .. " + engine\\gamedata\\scripts + gamedata\\scripts", stock_rows,
	s_scanned, s_world, s_rule)

if not GAMMA then
	print("GAMMA_SCRIPTS not set: " .. OUT_GAMMA .. " left as it is")
	return
end
local gamma_files = {}
for _, path in ipairs(list(GAMMA, true)) do gamma_files[coop_native.script_key("@" .. path)] = path end
local in_stock = {}
for _, r in ipairs(stock_rows) do in_stock[r.key] = true end
local gamma_rows, g_scanned, g_world, g_rule = survey(gamma_files, in_stock)
write(OUT_GAMMA, "GAMMA's loose scripts", GAMMA .. " (keys already in " .. OUT_STOCK .. " left out)", gamma_rows,
	g_scanned, g_world, g_rule)
