-- Anomaly Coop test (split levels, F3a task 3): the two new game rules and the new default in the catalog
-- gamedata\scripts\coop_game_schema.script (docs\GAME_SETTINGS.md 1.2, 3.6, 8.2; docs\plans\2026-10-24-f3a-split-levels.md 3):
--   c|coop_split_levels      on / off, the switch of the split levels, on by default
--   c|coop_story_together    on / off, only while the levels are split, on by default
--   o|coop/coop_session/join_spawn   a new player appears at the base of the world's faction by default
-- The catalog is loaded into a sealed environment (the standard library and nothing of the engine). The list of 19 console
-- variables is also held against the engine's white list in engine\src\xrCoop\coop_game_values.h when that file is there.
-- Not shipped. Run: tools\test_lua.cmd game_schema
local PASSES, FAILS = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local function finish()
	print(string.format("%d passed, %d failed", PASSES, FAILS))
	os.exit(FAILS == 0 and 0 or 1)
end

-- ------------------------------------------------------------------------------------------------ sealed loader
local SAFE = {}
for _, n in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset",
	"select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "string", "table", "math" }) do
	SAFE[n] = _G[n]
end
SAFE._G = SAFE

local function load_module(name)
	local fh = io.open("gamedata/scripts/" .. name .. ".script", "rb")
	if not fh then return nil, "gamedata/scripts/" .. name .. ".script is missing" end
	local src = fh:read("*a")
	fh:close()
	local f, err = loadstring(src, "@" .. name .. ".script")
	if not f then return nil, err end
	local this = setmetatable({}, { __index = SAFE })
	setfenv(f, this)
	local ok, err2 = pcall(f)
	if not ok then return nil, err2 end
	return this
end

local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local function index_of(list, v)
	for i, x in ipairs(list) do
		if x == v then return i end
	end
	return nil
end

local schema, serr = load_module("coop_game_schema")
check(schema ~= nil, "coop_game_schema loads in the sealed environment" .. (serr and (": " .. tostring(serr)) or ""))
if not schema then finish() end

local SPLIT, STORY = "c|coop_split_levels", "c|coop_story_together"
local JOIN = "o|coop/coop_session/join_spawn"

-------------------------------------------------------------------------------
print("== the 19 console variables")
local FIRST_17 = { "coop_friendly_fire", "coop_max_new_characters", "coop_share_rewards", "coop_death_mode", "coop_death_drop",
	"coop_bleedout", "coop_revive_health", "coop_respawn_delay", "coop_contusion", "coop_death_money", "coop_death_wear",
	"coop_death_rank", "coop_hardcore_new_kit", "coop_checkpoints_group", "coop_autosave_interval", "coop_autosave_count",
	"coop_death_share" }
check(#schema.CVARS == 19, "CVARS holds 19 names (" .. #schema.CVARS .. ")")
local same = true
for i, n in ipairs(FIRST_17) do
	if schema.CVARS[i] ~= n then same = false end
end
check(same, "the first 17 names keep their order")
check(schema.CVARS[18] == "coop_split_levels" and schema.CVARS[19] == "coop_story_together", "rows 18 and 19 are the split-levels rules")
for _, n in ipairs({ "coop_split_levels", "coop_story_together" }) do
	local c = schema.CVAR[n]
	check(c ~= nil and c.kind == "int" and c.min == 0 and c.max == 1 and c.def == 1, n .. ": an on/off console flag, on by default")
end

-- the engine's white list (coop::game::kGameCvars) is the same list in the same order
local header = read_file("engine/src/xrCoop/coop_game_values.h")
if header then
	local body = header:match("kGameCvars%[%]%s*=%s*{(.-)};")
	local names = {}
	for n in (body or ""):gmatch('"([%w_]+)"') do names[#names + 1] = n end
	local equal = #names == #schema.CVARS
	for i, n in ipairs(names) do
		if schema.CVARS[i] ~= n then equal = false end
	end
	check(#names == 19 and equal, "coop_game_values.h kGameCvars is the catalog's CVARS (" .. #names .. " names)")
else
	print("  skip the engine sources are not checked out: kGameCvars is not compared")
end

local c_items = 0
for _, k in ipairs(schema.keys()) do
	if k:find("^c|") then c_items = c_items + 1 end
end
check(c_items == 19, "all 19 console variables, and only they, are catalog items of source c (" .. c_items .. ")")

-------------------------------------------------------------------------------
print("== the two switches")
for _, key in ipairs({ SPLIT, STORY }) do
	local it = schema.item(key)
	check(it ~= nil, key .. " is in the catalog")
	if it then
		check(it.tab == "party" and it.kind == "check" and it.src == "c" and it.cvar == key:sub(3), key .. ": a check on the group tab, a console variable")
		check(it.def == true, key .. ": on by default")
		check(it.when == "session" and schema.editable(key, true) and schema.editable(key, false),
			key .. ": changed between sessions, editable on an existing game")
		check(it.applies == "load", key .. ": starts to act when the game is loaded (" .. tostring(it.applies) .. ")")
		check(it.range and it.range[1] == 0 and it.range[2] == 1 and it.int == true, key .. ": 0..1, whole")
		check(schema.default(key) == true, key .. ": default()")
	end
end
check(schema.item(SPLIT) ~= nil and schema.item(SPLIT).shown_if == nil, "the switch of the split levels is always shown")
local shown = (schema.item(STORY) or {}).shown_if
check(shown and shown.key == SPLIT and #shown.any == 1 and shown.any[1] == true,
	"story levels together is shown while the levels are split")

local party = {}
for i, it in ipairs(schema.items("party")) do party[i] = it.key end
local i_split, i_story, i_join = index_of(party, SPLIT), index_of(party, STORY), index_of(party, JOIN)
check(i_split and i_story and i_join and i_split < i_story and i_story < i_join,
	"on the group tab: split levels, story levels together, then where a new player appears")
check(i_split ~= nil and index_of(party, "c|coop_max_new_characters") < i_split, "after the limit of new characters")

-- values: a console flag is "1" / "0"
check(schema.normalize(SPLIT, "1") == true and schema.normalize(SPLIT, "0") == false, "normalize: 1 / 0")
check(schema.normalize(STORY, true) == true and schema.normalize(STORY, false) == false, "normalize: a boolean stays one")
check(schema.normalize(SPLIT, "2") == nil and schema.normalize(SPLIT, "maybe") == nil and schema.normalize(SPLIT, "") == nil, "normalize: not a flag")
check(schema.to_raw(SPLIT, true) == "1" and schema.to_raw(SPLIT, false) == "0" and schema.to_raw(STORY, false) == "0",
	"to_raw: the console form")
check(schema.canon(SPLIT, "ON") == "1" and schema.canon(STORY, " 0 ") == "0", "canon: a console flag")
local vals = (schema.item(SPLIT) or {}).values or {}
check(#vals == 2 and vals[1][1] == true and vals[1][2] == "st_coop_game_on" and vals[2][1] == false and vals[2][2] == "st_coop_game_off",
	"the values are the stock on / off strings")

-------------------------------------------------------------------------------
print("== join_spawn: at the faction's base by default")
local join = schema.item(JOIN)
check(join ~= nil and join.def == "faction_start", "the default is faction_start (" .. tostring(join and join.def) .. ")")
check(schema.default(JOIN) == "faction_start", "default(join_spawn)")
check(join.values[1][1] == "host" and join.values[2][1] == "faction_start" and #join.values == 2, "both values stay: host and faction_start")
check(schema.normalize(JOIN, "host") == "host" and schema.normalize(JOIN, "faction_start") == "faction_start"
	and schema.normalize(JOIN, "somewhere") == nil, "normalize: the two tokens only")
check(schema.to_raw(JOIN, "faction_start") == "faction_start", "to_raw")

-------------------------------------------------------------------------------
print("== strings")
local ids = schema.text_ids()
local want = { "st_coop_game_split_levels", "st_coop_game_story_together", "st_coop_game_join_spawn",
	"st_coop_game_join_spawn_host", "st_coop_game_join_spawn_faction_start" }
for _, id in ipairs(want) do
	check(index_of(ids, id) ~= nil, "text_ids names " .. id)
end
for _, lang in ipairs({ "eng", "rus" }) do
	local have = {}
	for _, file in ipairs({ "st_coop_game.xml", "st_coop_levels.xml" }) do
		local src = read_file("gamedata/configs/text/" .. lang .. "/" .. file)
		for id in (src or ""):gmatch('<string%s+id="([^"]+)"') do have[id] = (have[id] or 0) + 1 end
	end
	local missing = {}
	for _, id in ipairs(want) do
		if not have[id] then missing[#missing + 1] = id end
	end
	check(#missing == 0, lang .. ": the strings of the two switches and of join_spawn exist (missing: " .. table.concat(missing, ",") .. ")")
	check(have.st_coop_game_split_levels == 1 and have.st_coop_game_story_together == 1, lang .. ": each switch string is defined once")
end

finish()
