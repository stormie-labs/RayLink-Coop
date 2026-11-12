-- Anomaly Coop test (split levels, F3a task 3): the two new game rules and the new default in the catalog
-- gamedata\scripts\coop_game_schema.script (docs\GAME_SETTINGS.md 1.2, 3.6, 8.2; docs\plans\2026-10-24-f3a-split-levels.md 3):
--   c|coop_split_levels      on / off, the switch of the split levels, in the menu, off by default
--   c|coop_story_together    on / off, only while the levels are split, on by default
--   o|coop/coop_session/join_spawn   a new player appears at the base of the world's faction by default
-- The catalog is loaded into a sealed environment (the standard library and nothing of the engine). The list of 21 console
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
print("== the 21 console variables")
local FIRST_17 = { "coop_friendly_fire", "coop_max_new_characters", "coop_share_rewards", "coop_death_mode", "coop_death_drop",
	"coop_bleedout", "coop_revive_health", "coop_respawn_delay", "coop_contusion", "coop_death_money", "coop_death_wear",
	"coop_death_rank", "coop_hardcore_new_kit", "coop_checkpoints_group", "coop_autosave_interval", "coop_autosave_count",
	"coop_death_share" }
check(#schema.CVARS == 21, "CVARS holds 21 names (" .. #schema.CVARS .. ")")
local same = true
for i, n in ipairs(FIRST_17) do
	if schema.CVARS[i] ~= n then same = false end
end
check(same, "the first 17 names keep their order")
check(schema.CVARS[18] == "coop_split_levels" and schema.CVARS[19] == "coop_story_together", "rows 18 and 19 are the split-levels rules")
check(schema.CVARS[20] == "coop_npc_finish_downed", "row 20 is the NPC AI rule: stalkers finish a downed player")
check(schema.CVARS[21] == "coop_world_server", "row 21 is the new split mode: the world as a separate process (owner 2026-11-13)")
for n, def in pairs({ coop_split_levels = 0, coop_story_together = 1, coop_world_server = 0 }) do
	local c = schema.CVAR[n]
	check(c ~= nil and c.kind == "int" and c.min == 0 and c.max == 1 and c.def == def, n .. ": an on/off console flag, default " .. def)
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
	check(#names == 21 and equal, "coop_game_values.h kGameCvars is the catalog's CVARS (" .. #names .. " names)")
else
	print("  skip the engine sources are not checked out: kGameCvars is not compared")
end

local c_items = 0
for _, k in ipairs(schema.keys()) do
	if k:find("^c|") then c_items = c_items + 1 end
end
check(c_items == 21, "all 21 console variables, and only they, are catalog items of source c (" .. c_items .. ")")

-------------------------------------------------------------------------------
print("== the two switches")
for _, key in ipairs({ SPLIT, STORY }) do
	local it = schema.item(key)
	check(it ~= nil, key .. " is in the catalog")
	if it then
		check(it.tab == "party" and it.kind == "check" and it.src == "c" and it.cvar == key:sub(3), key .. ": a check on the group tab, a console variable")
		check(it.def == (key == STORY), key .. ": default")
		check(it.when == "session" and schema.editable(key, true) and schema.editable(key, false),
			key .. ": changed between sessions, editable on an existing game")
		check(it.applies == "load", key .. ": starts to act when the game is loaded (" .. tostring(it.applies) .. ")")
		check(it.range and it.range[1] == 0 and it.range[2] == 1 and it.int == true, key .. ": 0..1, whole")
		check(schema.default(key) == (key == STORY), key .. ": default()")
	end
end
local own = (schema.item(SPLIT) or {}).shown_if
check(own == nil, "the switch of the split levels is in the menu of every game")
local shown = (schema.item(STORY) or {}).shown_if
check(shown and shown.key == SPLIT and #shown.any == 1 and shown.any[1] == true,
	"story levels together is shown while the levels are split")

local party = {}
for i, it in ipairs(schema.items("party")) do party[i] = it.key end
local i_split, i_story, i_join = index_of(party, SPLIT), index_of(party, STORY), index_of(party, JOIN)
check(i_split and i_story and i_join and i_split < i_story and i_story < i_join,
	"on the group tab: split levels, story levels together, then where a new player appears")
check(i_split ~= nil and index_of(party, "c|coop_max_new_characters") < i_split, "after the limit of new characters")

-- the new split mode (owner 2026-11-13): a check right under the split levels, shown while they are on, off by default
local WSK = "c|coop_world_server"
local wsi = schema.item(WSK)
check(wsi ~= nil and wsi.tab == "party" and wsi.kind == "check" and wsi.src == "c" and wsi.cvar == "coop_world_server",
	"world server: a check on the group tab, a console variable")
check(wsi and wsi.def == false and schema.default(WSK) == false, "world server: off by default")
-- which process runs a world is decided once: its save's actor is either the creator's own character (the old mode) or the
-- server's ghost (the new one), so the value cannot be turned on or off on a world that exists
check(wsi and wsi.when == "create" and wsi.applies == "create", "world server: chosen when the world is created")
check(schema.editable(WSK, false) == true and schema.editable(WSK, true) == false, "world server: not editable on an existing game")
check(wsi and wsi.range and wsi.range[1] == 0 and wsi.range[2] == 1 and wsi.int == true and schema.to_raw(WSK, true) == "1",
	"world server: 0..1, the console form")
local wshown = wsi and wsi.shown_if
check(wshown and wshown.key == SPLIT and #wshown.any == 1 and wshown.any[1] == true, "world server: shown while the levels are split")
check(i_split and index_of(party, WSK) == i_split + 1, "world server: right under the split levels")

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
print("== two rules of the 2026-10-31 night: foreign loot, stalkers finish a downed player")
local LOOT, FINISH = "o|coop/coop_session/loot_claim", "c|coop_npc_finish_downed"
local loot = schema.item(LOOT)
check(loot ~= nil and loot.tab == "party" and loot.kind == "check" and loot.src == "o" and loot.def == true,
	"Foreign loot: a check on the group tab, on by default")
check(loot and loot.when == "session" and schema.editable(LOOT, true) and schema.editable(LOOT, false),
	"Foreign loot: changed between sessions, editable on an existing game")
check(schema.normalize(LOOT, "false") == false and schema.normalize(LOOT, "true") == true and schema.normalize(LOOT, "maybe") == nil
	and schema.to_raw(LOOT, false) == "false", "Foreign loot: an option flag is true / false")
local downed = schema.item(FINISH)
check(downed ~= nil and downed.tab == "death" and downed.kind == "check" and downed.src == "c" and downed.cvar == "coop_npc_finish_downed"
	and downed.def == false, "finish a downed player: a check on the death tab, a console variable, off by default (owner 2026-11-02)")
check(downed and downed.range and downed.range[1] == 0 and downed.range[2] == 1 and downed.int == true
	and schema.to_raw(FINISH, false) == "0" and schema.to_raw(FINISH, true) == "1", "finish a downed player: 0..1, the console form")
check(downed and downed.shown_if == nil, "finish a downed player: always shown")

-------------------------------------------------------------------------------
print("== strings")
local ids = schema.text_ids()
local want = { "st_coop_game_split_levels", "st_coop_game_story_together", "st_coop_game_join_spawn",
	"st_coop_game_loot_claim", "st_coop_game_npc_finish_downed", "st_coop_game_world_server",
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
	check(have.st_coop_game_world_server == 1 and have.st_coop_game_world_server_hint == 1,
		lang .. ": the world server setting has its title and its hint, once each")
end

finish()
