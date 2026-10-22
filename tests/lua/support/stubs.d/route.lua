-- Anomaly Coop test stand-ins: the engine's callback router API `coop.route` (coop_router.cpp register_lua, F2 T10),
-- built over the runner's native module coop_native (tests/lua/native_coop.cpp), so the script keys, the route table
-- and the counters are the engine's own C++ (coop_routes.h). Not shipped.
--   coop.route.of(callback, func) -> domain, script   script key of debug.getinfo(func, "S").source; "[C]" for a C
--                                                     function, "?" for a non-function
--   coop.route.runs(domain) -> bool                   outside a session (is_active() false) every domain runs
--   coop.route.note(domain, outcome[, script[, callback]])   outcome "ran" | "skipped" | "error" (coop_native.note)
--   coop.route.none_functions() -> {"module.function", ...}
-- The overrides are the real gamedata\configs\coop_route.ltx, then every coop_route_*.ltx and coop_compat_*.ltx by
-- name, read on the first of() / none_functions() like the engine's load_overrides. route_stub_load() forces that read
-- (it resets coop_native first); a test adds its own rules after it with coop_native.add(section, {name = domain}).
-- ROUTE_CALLS counts the calls of each function. ROUTE_SKIP_FILES = { ["name.ltx"] = true } leaves files out (set it
-- before the load; tools\gen_route_gamma.lua leaves out its own output). After a load ROUTE_SCRIPT_RULES maps every
-- [route_scripts] key (lowercase, a prefix with its *) to its domain, ROUTE_FORCED every forced callback to its domain.
ROUTE_CALLS = { of = 0, runs = 0, note = 0, none_functions = 0 }
ROUTE_NONE_FUNCTIONS = {}
ROUTE_FILES = {}
ROUTE_ERRORS = {}
ROUTE_SCRIPT_RULES = {}
ROUTE_FORCED = {}
ROUTE_SKIP_FILES = ROUTE_SKIP_FILES or {}
local loaded = false

local BS = string.char(92)
local CFG = "gamedata" .. BS .. "configs" .. BS
local SECTIONS = { route_scripts = true, route_callbacks = true, route_callbacks_forced = true, route_pairs = true }

local function list(mask)
	local out = {}
	local pipe = io.popen("dir /b /on " .. CFG .. mask .. " 2>nul")
	if not pipe then return out end
	for line in pipe:lines() do
		line = line:gsub("\r", "")
		if line ~= "" then out[#out + 1] = line end
	end
	pipe:close()
	table.sort(out, function(a, b) return a:lower() < b:lower() end)
	return out
end

-- The files in the engine's order: coop_route.ltx, coop_route_*.ltx, coop_compat_*.ltx.
local function route_files()
	local files = {}
	local fh = io.open(CFG .. "coop_route.ltx", "r")
	if fh then
		fh:close()
		files[1] = "coop_route.ltx"
	end
	for _, n in ipairs(list("coop_route_*.ltx")) do files[#files + 1] = n end
	for _, n in ipairs(list("coop_compat_*.ltx")) do files[#files + 1] = n end
	return files
end

-- name -> { section -> { {key, value}, ... } } in file order; ";" starts a comment, a line without "=" is a bare key.
local function read_ltx(name)
	local out, cur = {}, nil
	local fh = io.open(CFG .. name, "r")
	if not fh then return out end
	for line in fh:lines() do
		line = line:gsub(";.*$", "")
		local sec = line:match("^%s*%[([^%]]+)%]")
		if sec then
			cur = out[sec] or {}
			out[sec] = cur
		elseif cur then
			local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
			if not k then
				k, v = line:match("^%s*(.-)%s*$"), ""
			end
			if k and k ~= "" then cur[#cur + 1] = { k, v } end
		end
	end
	fh:close()
	return out
end

function route_stub_load()
	loaded = true
	coop_native.reset()
	ROUTE_NONE_FUNCTIONS, ROUTE_FILES, ROUTE_ERRORS, ROUTE_SCRIPT_RULES, ROUTE_FORCED = {}, {}, {}, {}, {}
	local files = {}
	for _, name in ipairs(route_files()) do
		if not ROUTE_SKIP_FILES[name] then files[#files + 1] = name end
	end
	for _, name in ipairs(files) do
		ROUTE_FILES[#ROUTE_FILES + 1] = name
		for sec, lines in pairs(read_ltx(name)) do
			if SECTIONS[sec] then
				local map = {}
				for _, l in ipairs(lines) do
					map[l[1]] = l[2]
					if sec == "route_scripts" then ROUTE_SCRIPT_RULES[l[1]:lower()] = l[2]:lower() end
					if sec == "route_callbacks_forced" then ROUTE_FORCED[l[1]:lower()] = l[2]:lower() end
				end
				local n, errs = coop_native.add(sec, map)
				if n > 0 then
					for _, e in ipairs(errs) do ROUTE_ERRORS[#ROUTE_ERRORS + 1] = name .. ": " .. e end
				end
			elseif sec == "route_none_functions" then
				for _, l in ipairs(lines) do ROUTE_NONE_FUNCTIONS[#ROUTE_NONE_FUNCTIONS + 1] = l[1] end
			end
		end
	end
end

local function script_of(f)
	if type(f) ~= "function" then return "?" end
	local info = debug.getinfo(f, "S")
	if not info then return "?" end
	if info.what == "C" then return "[C]" end
	return coop_native.script_key(info.source or "")
end

-- install_route_stubs(coop_table [, opts])
--   opts.is_host    function() -> bool (default coop.is_host)
--   opts.is_active  function() -> bool (default coop.is_active, true when missing)
function install_route_stubs(c, opts)
	opts = opts or {}
	local function ask(name, default)
		local f = c[name]
		if type(f) == "function" then return f() end
		return default
	end
	local function is_host()
		if opts.is_host then return opts.is_host() end
		return ask("is_host", false)
	end
	local function is_active()
		if opts.is_active then return opts.is_active() end
		return ask("is_active", true)
	end
	c.route = {
		of = function(callback, f)
			if type(callback) ~= "string" then return nil end
			if not loaded then route_stub_load() end
			ROUTE_CALLS.of = ROUTE_CALLS.of + 1
			local script = script_of(f)
			return coop_native.route(callback, script), script
		end,
		runs = function(domain)
			ROUTE_CALLS.runs = ROUTE_CALLS.runs + 1
			if not is_active() then return true end
			return coop_native.runs_here(domain, is_host() == true)
		end,
		note = function(domain, outcome, script, callback)
			ROUTE_CALLS.note = ROUTE_CALLS.note + 1
			coop_native.note(domain, outcome, script, callback)
		end,
		none_functions = function()
			if not loaded then route_stub_load() end
			ROUTE_CALLS.none_functions = ROUTE_CALLS.none_functions + 1
			local out = {}
			for i, v in ipairs(ROUTE_NONE_FUNCTIONS) do out[i] = v end
			return out
		end,
	}
	return c
end

-- A global `coop` that exists when this file is loaded (stubs.lua, stubs_mods.lua) gets the stand-ins at once.
if type(rawget(_G, "coop")) == "table" and type(rawget(_G, "coop_native")) == "table" then
	install_route_stubs(coop)
end
