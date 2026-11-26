-- Anomaly Coop test: the dedicated host's half in Lua (gamedata\scripts\coop_srv_dedicated.script, coop_dedicated before step S4,
-- docs\DEDICATED_HOST.md). A new world gets what the faction-select screen would write, except the start map (the actor stays on
-- fake_start) and what is for a character; a world that is loaded gets nothing; stock IsTestMode no longer takes the service level for
-- a test map. A window host is left alone. Step S4 (A-S4D): that work runs from coop_mode.when_srv; the real facade coop_mode and the
-- real server layer coop_srv_mode run here as axr_main runs them (by name), and on a -coop_dedicated process the layer answers from
-- the start, before the session: the work is done inside the loop of on_game_start, before the stock reads [character_creation].
-- The audit's fixes in other scripts: the rule "the host decides", the reward group, the choice of a start, the window's new game.
-- Not shipped. Run: tools\test_lua.cmd srv_dedicated
PASSES, FAILS = 0, 0
function check(cond, what)
	if cond then
		PASSES = PASSES + 1
	else
		FAILS = FAILS + 1
		print("  FAIL " .. tostring(what))
	end
end

local function read(path)
	local fh = assert(io.open(path, "rb"), "no " .. path)
	local text = fh:read("*a")
	fh:close()
	return text
end

-- One script as the engine loads a module: its own table over _G, named in _G.
local function module(name)
	local chunk = assert(loadstring(read("gamedata/scripts/" .. name .. ".script"), name))
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	_G[name] = env
	return env
end

-- A fresh Lua state at a world start: the facade, the server layer and this script, their on_game_start in axr_main's order (by
-- name: coop_mode, coop_srv_dedicated, coop_srv_mode). The engine before the session (-coop_dedicated: the session starts after the
-- world is up): no phase, so no role and no seat. `p` (optional): { active, map_server, host, split } of the engine. Returns what was
-- written to [character_creation] and what was written by the time coop_srv_dedicated's own on_game_start was over.
local function fresh(dedicated, new_world, p)
	p = p or {}
	local written = {}
	IsTestMode = function() return true end
	printf = function() end
	RegisterScriptCallback = function() end
	axr_main = {
		config = {
			w_value = function(_, section, key, value)
				check(section == "character_creation", "only the section of a new game: " .. tostring(section))
				written[key] = value == nil and "removed" or value
			end,
		},
	}
	coop = dedicated == nil and nil or {
		is_dedicated = function() return dedicated end,
		dedicated_new_world = function() return new_world end,
		is_active = function() return p.active == true end,
		is_host = function() return p.host == true end,
		is_map_server = function() return p.map_server == true end,
		self_id = function() return p.active and 0 or -1 end,
		players = function() return {} end,
		levels = { split = function() return p.split == true end },
	}
	module("coop_util") -- coop_mode registers its coop_status lines there
	local facade, script, layer = module("coop_mode"), module("coop_srv_dedicated"), module("coop_srv_mode")
	facade.on_game_start()
	script.on_game_start()
	local before = {}
	for k, v in pairs(written) do before[k] = v end
	local test_before = IsTestMode()
	layer.on_game_start()
	return written, before, test_before
end

-- ------------------------------------------------------------------------------------------------ a new world
do
	local w, before, test_before = fresh(true, true)
	check(next(before) == nil and test_before == true,
		"S4: its own on_game_start only waits in coop_mode.when_srv (axr_main runs coop_srv_mode after it)")
	check(w.new_game_faction == "stalker", "a new world has a faction: the storyline hangs on it")
	check(w.new_game_story_mode == true, "story mode is on")
	check(w.new_game_difficulty == 1 and w.new_game_economy == 1, "the screen's defaults")
	check(w.new_game_map == "removed", "no start map: the actor stays on fake_start")
	check(w.new_game_test == "removed", "no test map: it would create a world with no population")
	check(w.new_game_money == "removed" and w.new_game_loadout == "removed", "nothing for a character")
	check(IsTestMode() == false, "the service level is no test map")
end

-- ------------------------------------------------------------------------------------------------ a loaded world
do
	local w = fresh(true, false)
	check(next(w) == nil, "a loaded world: the keys would give the ghost a new start on every load")
	check(IsTestMode() == false, "the service level is no test map after a load either")
end

-- ------------------------------------------------------------------------------------------------ a window host, an exe without co-op
do
	local w = fresh(false, true)
	check(next(w) == nil, "a window host chooses in its own screen")
	check(IsTestMode() == true, "stock IsTestMode stays on a window host")
	w = fresh(nil)
	check(next(w) == nil, "no coop table: nothing happens")
	check(IsTestMode() == true, "no coop table: stock IsTestMode")
	-- S4: the other processes the server layer answers in run the when_srv function, and it does nothing there
	w = fresh(false, true, { active = true, map_server = true })
	check(next(w) == nil and IsTestMode() == true, "a map server (not -coop_dedicated): nothing written, stock IsTestMode")
	w = fresh(false, true, { active = true, split = true })
	check(next(w) == nil and IsTestMode() == true, "a player's machine of a server world: nothing written, stock IsTestMode")
	w = fresh(false, true, { active = true, host = true })
	check(next(w) == nil and IsTestMode() == true, "a co-op host in its session: nothing written, stock IsTestMode")
end

-- ------------------------------------------------------------------------------------------------ the audit's fixes, by their text
do
	local modes = read("gamedata/scripts/coop_newgame_modes.script")
	check(modes:find("%-coop_dedicated", 1, true) ~= nil, "a dedicated host's new game is a co-op host's")
	local char = read("gamedata/scripts/coop_menu_char.script")
	check(char:find('level == ""', 1, true) ~= nil, "an offer with no level: every start of the faction")
end

-- ------------------------------------------------------------------------------------------------ a world from a staging file (plan 2026-11-12 stage 5)
local function load_mod(name)
	local chunk = assert(loadstring(read("gamedata/scripts/" .. name .. ".script"), name))
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	return env
end
-- The dedicated launcher starts the world before coop.session_info() reports a host.
do
	local stock = { new_game_hardcore_mode = "true", new_game_azazel_mode = "true", new_game_faction = "stalker" }
	local saves = 0
	coop = { session_info = function() return { active = false, host = false } end }
	function command_line() return "RayLinkServer.exe -coop_dedicated 27960 -coop_new" end
	axr_main = { config = {
		r_string_ex = function(_, _, key) return stock[key] end,
		w_value = function(_, section, key, value)
			check(section == "character_creation", "clear the stock mode in [character_creation]")
			stock[key] = value
		end,
		save = function() saves = saves + 1 end,
	} }
	load_mod("coop_newgame_modes").on_game_start()
	check(stock.new_game_hardcore_mode == nil and stock.new_game_azazel_mode == nil and saves == 1,
		"a dedicated new world clears the saved stock modes before its session starts")
	check(stock.new_game_faction == "stalker", "clearing stock modes keeps the world's faction")
end

coop_game_schema = load_mod("coop_game_schema")
coop_game_record = load_mod("coop_game_record")
STAGED, ACTIVE, STAGE_OK = nil, nil, true
coop_game_settings = {
	stage_new = function(r) STAGED = r; if STAGE_OK then return true end return false, "refused by the engine" end,
	active = function() return ACTIVE end,
}
local LOGS = {}
local function staging()
	printf = function(fmt, ...) LOGS[#LOGS + 1] = string.format(fmt, ...) end
	coop = { is_dedicated = function() return true end, dedicated_new_world = function() return true end }
	return load_mod("coop_srv_dedicated")
end
local function logged(pat)
	for _, l in ipairs(LOGS) do if l:find(pat, 1, true) then return true end end
	return false
end

do
	local d = staging()
	local stage = {
		world = { id = "65190f3a-9c41", name = "Strelok", title = "With Kent", faction = "bandit", story = false, routes = true,
			difficulty = 2, economy = 3 },
		values = { ["o|alife/event/emission_frequency"] = "48", ["g|hit_power"] = "1.5", ["e|buy"] = "true", ["s|junk"] = "abc" },
		creator = { name = "Strelok", icon = "ui_icon", loadout = { "wpn_pm", "ammo_9x18_fmj", "wpn_pm" }, money = 5000,
			map = "esc_m_trader", bare = false },
	}
	local ok, why = d.stage_new_world("D:/w/coop_new_world.ltx", stage)
	check(ok == true, "a stage builds the record: " .. tostring(why))
	local r = STAGED
	check(r and r.id == "65190f3a-9c41" and r.faction == "bandit" and r.name == "Strelok" and r.title == "With Kent",
		"the record has the file's id, faction, name and title")
	check(r and r.world.story == false and r.world.routes == true and r.world.difficulty == 2 and r.world.economy == 3,
		"and the world's flags of the file")
	check(r and r.values["o|alife/event/emission_frequency"] == "48" and r.values["g|hit_power"] == 1.5 and r.values["e|buy"] == true,
		"text for o|m|c, a number or a boolean for g|e|s")
	check(r and r.values["s|junk"] == nil and logged("s|junk"), "a factor that is no number is dropped with a log line")
	check(r and r.creator and r.creator.used == false and #r.creator.loadout == 3 and r.creator.money == 5000
		and r.creator.map == "esc_m_trader" and r.creator.bare == false, "the creator is in the record, not used yet")
	-- live 2026-11-13: the launcher's card of a world made by a world server said "split": false (the file had no [values])
	local sv = r and r.values["c|coop_split_levels"]
	check(sv == true or tonumber(sv) == 1, "a world a world server stages is a world of split levels (" .. tostring(sv) .. ")")
	local wv = r and r.values["c|coop_world_server"]
	check(wv == true or tonumber(wv) == 1, "and a world of the new mode: the world as a separate process (" .. tostring(wv) .. ")")
	STAGED = nil
	ok = d.stage_new_world("x", { world = { faction = "stalker" }, values = { ["c|coop_split_levels"] = "0", ["c|coop_world_server"] = "0" } })
	sv = STAGED and STAGED.values["c|coop_split_levels"]
	wv = STAGED and STAGED.values["c|coop_world_server"]
	check(ok == true and (sv == true or tonumber(sv) == 1), "also when the file says 0 (" .. tostring(sv) .. ")")
	check(ok == true and (wv == true or tonumber(wv) == 1), "the world server value too (" .. tostring(wv) .. ")")

	STAGED = nil
	ok = d.stage_new_world("x", { world = { faction = "stalker", name = "" }, creator = { name = "Mark", loadout = {} } })
	check(ok == true and STAGED.name == "Mark", "no world name: the creator's")
	check(STAGED.world.story == coop_game_schema.default("w|story") and STAGED.world.difficulty == coop_game_schema.default("w|difficulty"),
		"absent flags: the game's defaults")
	check(STAGED.id ~= nil and STAGED.id ~= "", "no id: the record makes one")
	STAGED = nil
	ok = d.stage_new_world("x", { world = { faction = "stalker" } })
	check(ok == true and STAGED.creator == nil, "no [creator]: no creator in the record")

	STAGED = nil
	ok, why = d.stage_new_world("x", { world = { name = "x" } })
	check(ok == false and STAGED == nil and type(why) == "string", "no faction: refused, nothing staged")
	ok, why = d.stage_new_world("x", nil)
	check(ok == false and type(why) == "string", "no stage: refused")
	STAGE_OK = false
	ok, why = d.stage_new_world("x", { world = { faction = "stalker" } })
	check(ok == false and why:find("refused", 1, true) ~= nil, "the engine refuses the record: refused with its reason")
	STAGE_OK = true
end

do
	ACTIVE = { faction = "bandit", world = { story = false, routes = true, difficulty = 2, economy = 3 } }
	local w = fresh(true, true)
	check(w.new_game_faction == "bandit" and w.new_game_difficulty == 2 and w.new_game_economy == 3 and w.new_game_economy_treasure == 3,
		"a staged world: [character_creation] of the server from the file's [world]")
	check(w.new_game_story_mode == "removed" and w.new_game_opened_routes == true, "story and routes as the file says")
	check(w.new_game_character_name == "server", "the ghost is still nobody")
	check(w.new_game_loadout == "removed" and w.new_game_money == "removed" and w.new_game_map == "removed",
		"the creator's loadout, money and map are not the ghost's")
	ACTIVE = nil
	w = fresh(true, true)
	check(w.new_game_faction == "stalker" and w.new_game_difficulty == 1 and w.new_game_opened_routes == nil,
		"no staged world: exactly as before")
end

-- S4 (A-S4D): the creator's facts read the record only, the same in both modes, and the Core asks them (coop_join.cpp
-- host_make_creator, coop_menu_char's exact plan): they live in the Core's coop_game_settings (tests\lua\test_game_settings.lua),
-- so no Core file names this server script.
do
	local d = staging()
	check(d.creator == nil and d.creator_facts == nil and d.creator_made == nil, "the creator's functions are not here any more")
end

-- A world server never loads a world of a host who plays in it: that save's actor is the host's own character, and a world server
-- turns the save's actor into its ghost (owner 2026-11-13: the old split mode stays, old worlds are not carried over).
do
	local d = staging()
	local SAVES = {
		ws_world = { "6af611d5-a8f5", { id = "6af611d5-a8f5", values = { ["c|coop_split_levels"] = "1", ["c|coop_world_server"] = "1" } } },
		old_split = { "65190f3a-9c41", { id = "65190f3a-9c41", values = { ["c|coop_split_levels"] = "1" } } },
		plain_host = { "65190f3a-0001", { id = "65190f3a-0001", values = {} } },
		off_again = { "65190f3a-0002", { id = "65190f3a-0002", values = { ["c|coop_world_server"] = "0" } } },
	}
	coop_game_settings.game_of_save = function(stem)
		if stem == "broken" then error("cannot read it") end
		local s = SAVES[stem]
		if s then return s[1], s[2] end
		return nil
	end
	check(type(d.load_allowed) == "function", "coop_srv_dedicated.load_allowed exists")
	if type(d.load_allowed) == "function" then
		check(d.load_allowed("ws_world") == true, "a world made for a world server loads")
		local ok, why = d.load_allowed("old_split")
		check(ok == false and type(why) == "string" and why:find("old_split", 1, true) ~= nil, "a world of the old split mode is refused, with the save's name")
		check(d.load_allowed("plain_host") == false and d.load_allowed("off_again") == false, "so is a plain host's world, and one with the value off")
		check(logged("a world server does not load it"), "and the log says why")
		check(d.load_allowed("no_record") == true, "a save without a game record passes: nothing says whose it is")
		check(d.load_allowed("broken") == true, "a save whose record cannot be read passes: the guard never stops a server by its own error")
		coop_game_settings.game_of_save = nil
		check(d.load_allowed("old_split") == true, "no way to ask: passes")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
