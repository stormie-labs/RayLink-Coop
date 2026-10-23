-- Anomaly Coop test helper: runs a real mod's function on the stubs (not shipped). A mod script is too big to load whole
-- on the stubs (classes, MCM, file-level patches of a hundred modules), so a test takes the functions it needs out of
-- the real file by text and compiles them as one chunk in that script's module environment (a table with __index =
-- _G, the way CScriptStorage loads a script). The chunk name is the real file, so debug.getinfo(f, "S").source and the
-- router's script key are the mod's own.
--   mod_chunk(path, headers, module, tail) -> results of the chunk | nil, why
--       headers  lines that start each function, in file order ("function attach_scope(item, weapon)",
--                "local function check_scope(", "_G.alife_clone_weapon = function("); a function runs from its header
--                to the first line that is exactly "end" (column 0), as these files are written
--       module   module table name (created when missing); tail: Lua appended to the chunk ("return f")
--   GAMMA_DIR    the GAMMA scripts folder (env GAMMA_SCRIPTS, default E:\AnomalyCoopGamma\gamedata\scripts)
--   ENGINE_DIR   engine\gamedata\scripts (the modded exes' script layer, in this repository)
--   have_file(path) -> bool
local BS = string.char(92)
GAMMA_DIR = os.getenv("GAMMA_SCRIPTS") or ("E:" .. BS .. "AnomalyCoopGamma" .. BS .. "gamedata" .. BS .. "scripts")
ENGINE_DIR = "engine" .. BS .. "gamedata" .. BS .. "scripts"

function have_file(path)
	local fh = io.open(path, "r")
	if fh then fh:close() return true end
	return false
end

local function read_lines(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local lines = {}
	for line in fh:read("*a"):gmatch("([^\n]*)\n?") do lines[#lines + 1] = (line:gsub("\r$", "")) end
	fh:close()
	return lines
end

local function function_text(lines, header)
	for i, line in ipairs(lines) do
		if line:sub(1, #header) == header then
			local out = {}
			for j = i, #lines do
				out[#out + 1] = lines[j]
				if j > i and lines[j]:match("^end%s*$") then return table.concat(out, "\n") end
			end
			return nil, "no closing end for " .. header
		end
	end
	return nil, "not found: " .. header
end

function mod_chunk(path, headers, module, tail)
	local lines = read_lines(path)
	if not lines then return nil, "cannot read " .. path end
	local parts = {}
	for _, h in ipairs(headers) do
		local text, why = function_text(lines, h)
		if not text then return nil, why end
		parts[#parts + 1] = text
	end
	if tail then parts[#parts + 1] = tail end
	local f, err = loadstring(table.concat(parts, "\n"), "@" .. path)
	if not f then return nil, err end
	local env = rawget(_G, module)
	if type(env) ~= "table" then
		env = {}
		rawset(_G, module, env)
	end
	if getmetatable(env) == nil then setmetatable(env, { __index = _G }) end
	setfenv(f, env)
	return f()
end
