-- Anomaly Coop live fix 2026-10-23: Useful Idiots' own init ("idiots_on_start") runs on a co-op client.
-- Live FATAL on the GAMMA client: illish\patches\xr_combat_ignore.lua:206 "attempt to compare two nil values" in
-- PATCH.getNightMultiplier. PATCH.CONFIG is filled only by the mod's idiots_on_start listener; z_idiots_patches'
-- on_game_start sends that callback on every machine (axr_main calls on_game_start directly), but the client filter
-- names a function by its file's base name: illish\patches\xr_combat_ignore.lua -> "xr_combat_ignore", the stock AI
-- script, host by default (axr_companions and surge_manager are host explicitly). So all six listeners were skipped
-- on the client, the engine still called xr_combat_ignore.is_enemy there and it read the empty config.
-- Fix: idiots_on_start is in [callbacks_always] (configs\coop_domains_npc.ltx). What the listeners register in turn
-- keeps its own file's domain. Run: tools\test_lua.cmd idiots_start
local CFG = "gamedata/configs/"
FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
function bit_or(a, b) return a + b end
function getFS()
	return { file_list_open = function()
		local files = {}
		local p = io.popen('dir /b "' .. CFG:gsub("/", "\\") .. 'coop_domains_*.ltx" 2>nul')
		for line in p:lines() do files[#files + 1] = line end
		p:close()
		return { Size = function() return #files end, GetAt = function(_, i) return files[i + 1] end, Free = function() end }
	end }
end

-- a chunk defined in a Useful Idiots package file (debug.getinfo source = the .lua path inside the scripts folder)
local function from_lua(rel, body, ...)
	local f = assert(loadstring(body, "@.\\gamedata\\scripts\\" .. rel .. ".lua"))
	return f(...)
end

local OTHERS = { "xr_combat", "xr_corpse_detection", "xr_danger", "surge_manager", "axr_companions" }

-- A fresh Lua world per role (stubs: axr_main, coop; then coop_main), the check counters kept.
local function boot(mode)
	MODE = mode
	local passes, fails = PASSES or 0, FAILS or 0
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
	RAN, CONFIG, EVAL, STOCK_HIT = {}, nil, 0, 0
	load_coop_main()
	-- z_idiots_patches.script, file scope
	AddScriptCallback("idiots_on_start")
	AddScriptCallback("on_enemy_eval")
	AddScriptCallback("npc_on_hit_callback")
	-- illish\patches\xr_combat_ignore.lua: the init reads the config, then registers a handler of the same file
	local eval = from_lua("illish\\patches\\xr_combat_ignore", "return function() EVAL = EVAL + 1 end")
	RegisterScriptCallback("idiots_on_start", from_lua("illish\\patches\\xr_combat_ignore", [[
		local eval = ...
		return function()
			CONFIG = { nightMinHour = 18, nightMaxHour = 21, nightMultiplier = 1 }
			RAN.xr_combat_ignore = true
			RegisterScriptCallback("on_enemy_eval", eval)
		end]], eval))
	-- the other five listeners of the mod (file names of stock scripts)
	for _, name in ipairs(OTHERS) do
		RegisterScriptCallback("idiots_on_start",
			from_lua("illish\\patches\\" .. name, "return function() RAN['" .. name .. "'] = true end"))
	end
	-- a stock world callback of the same script name stays host-only on a client
	RegisterScriptCallback("npc_on_hit_callback",
		from_script("xr_combat_ignore", "return function() STOCK_HIT = STOCK_HIT + 1 end"))
	coop_main.on_game_start()
	-- z_idiots_patches.on_game_start()
	SendScriptCallback("idiots_on_start")
end

-- The comparison that failed live (PATCH.getNightMultiplier: hr1 > hr2 with both nil).
local function night_check_ok()
	local c = CONFIG or {}
	return (pcall(function() return c.nightMinHour > c.nightMaxHour end))
end

boot("client")
check(RAN.xr_combat_ignore == true and CONFIG ~= nil, "client: xr_combat_ignore.lua's init ran (PATCH.CONFIG filled)")
check(night_check_ok(), "client: the night check compares numbers, not nil")
local missing = {}
for _, name in ipairs(OTHERS) do
	if not RAN[name] then missing[#missing + 1] = name end
end
check(#missing == 0, "client: every idiots_on_start listener of the mod ran (missing: " .. table.concat(missing, ", ") .. ")")
SendScriptCallback("on_enemy_eval")
check(EVAL == 0, "client: a handler the init registers keeps its file's domain (host, skipped)")
SendScriptCallback("npc_on_hit_callback")
check(STOCK_HIT == 0, "client: stock xr_combat_ignore world callbacks stay host-only")

boot("host")
check(RAN.xr_combat_ignore == true and RAN.axr_companions == true and night_check_ok(), "host: listeners run as before")
SendScriptCallback("on_enemy_eval")
check(EVAL == 1, "host: the handler the init registers runs")

print(string.format("IDIOTS_START: %d passed, %d failed", PASSES, FAILS))
