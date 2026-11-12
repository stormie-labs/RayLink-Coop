-- Anomaly Coop test: the dedicated host's half in Lua (gamedata\scripts\coop_dedicated.script, docs\DEDICATED_HOST.md). A new world gets what the
-- faction-select screen would write, except the start map (the actor stays on fake_start) and what is for a character; a world that is
-- loaded gets nothing; stock IsTestMode no longer takes the service level for a test map. A window host is left alone.
-- The audit's fixes in other scripts: the rule "the host decides", the reward group, the choice of a start, the window's new game.
-- Not shipped. Run: tools\test_lua.cmd dedicated
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

local function fresh(dedicated, new_world)
	local written = {}
	IsTestMode = function() return true end
	printf = function() end
	axr_main = {
		config = {
			w_value = function(_, section, key, value)
				check(section == "character_creation", "only the section of a new game: " .. tostring(section))
				written[key] = value == nil and "removed" or value
			end,
		},
	}
	coop = dedicated == nil and nil or { is_dedicated = function() return dedicated end, dedicated_new_world = function() return new_world end }
	local chunk = assert(loadstring(read("gamedata/scripts/coop_dedicated.script"), "coop_dedicated"))
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	env.on_game_start()
	return written
end

-- ------------------------------------------------------------------------------------------------ a new world
do
	local w = fresh(true, true)
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
end

-- ------------------------------------------------------------------------------------------------ the audit's fixes, by their text
do
	local group = read("gamedata/scripts/coop_economy_group.script")
	check(group:find('rule == "host" and api and api.is_dedicated', 1, true) ~= nil, "no host to decide: the players vote")
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
	return load_mod("coop_dedicated")
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
	STAGED = nil
	ok = d.stage_new_world("x", { world = { faction = "stalker" }, values = { ["c|coop_split_levels"] = "0" } })
	sv = STAGED and STAGED.values["c|coop_split_levels"]
	check(ok == true and (sv == true or tonumber(sv) == 1), "also when the file says 0 (" .. tostring(sv) .. ")")

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

do
	local d = staging()
	ACTIVE = { faction = "bandit", creator = { loadout = { "wpn_pm", "wpn_pm" }, money = 10, used = false, bare = false } }
	local f = d.creator_facts()
	check(f.creator == true and f.used == false and f.loadout == "wpn_pm,wpn_pm" and f.count == 2 and f.bare == false,
		"the creator's facts for the engine")
	check(d.creator() == ACTIVE.creator, "his record for the plan")
	check(d.creator_made() == true and ACTIVE.creator.used == true and d.creator_facts().used == true, "made once: marked")
	ACTIVE = { faction = "bandit" }
	check(d.creator_facts().creator == false and d.creator() == nil and d.creator_made() == false, "no creator in the record")
	ACTIVE = nil
	check(d.creator_facts().creator == false, "no record at all")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
