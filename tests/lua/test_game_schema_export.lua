-- Anomaly Coop test: tools\export_game_schema.lua, the game's settings catalog as gamedata\configs\coop\game_schema.json for the
-- launcher's "new world" form (format 1: factions, world presets and defaults, tabs, items with their raw values).
--   (a) the generator's pure parts: JSON escaping, cp1251 -> UTF-8 of a label, a check item is two options off / on, shown_if is
--       carried, a kind the export does not know is refused, a missing string is refused;
--   (b) the committed JSON file is what the generator makes of the catalog now;
--   (c) every exported key and each of its options' raw values goes through coop_dedicated.stage_new_world unchanged into the record
--       (the launcher writes "<key>" = <raw> into [values] of coop_new_world.ltx).
-- Not shipped. Run: tools\test_lua.cmd game_schema_export
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
local function eq(got, want, what)
	check(got == want, what .. (got == want and "" or (": got [" .. tostring(got) .. "] want [" .. tostring(want) .. "]")))
end
local function finish()
	print(string.format("%d passed, %d failed", PASSES, FAILS))
	os.exit(FAILS == 0 and 0 or 1)
end

local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

EXPORT_GAME_SCHEMA_AS_LIBRARY = true
local okx, X = pcall(dofile, "tools/export_game_schema.lua")
check(okx and type(X) == "table", "tools/export_game_schema.lua loads as a library" .. (okx and "" or (": " .. tostring(X))))
if not (okx and type(X) == "table") then finish() end

-------------------------------------------------------------------------------
print("== (a) pure parts")
eq(X.json_string('a"b\\c\nd\te\1'), '"a\\"b\\\\c\\nd\\te\\u0001"', "JSON string escaping")
eq(X.json_string("\208\148\208\190\208\187\208\179"), '"\208\148\208\190\208\187\208\179"', "UTF-8 bytes stay as they are")
local box = X.sandbox()
local card = box.load("coop_json_card")
-- "Долг" in cp1251 and «» (0xAB / 0xBB)
eq(card.utf8("\196\238\235\227"), "\208\148\208\190\208\187\208\179", "cp1251 -> UTF-8 of a label (coop_json_card.utf8)")
local st = X.parse_strings('<?xml version="1.0" encoding="windows-1251"?>\n<string_table>\n'
	.. '<!--string id="a"><text>old</text></string-->\n'
	.. '<string id="a">\n\t\t<text>\171\196\238\235\227\187 &amp; &lt;x&gt;</text>\n\t</string>\n'
	.. '<string id="a"><text>second</text></string>\n'
	.. '<string id="e"><text></text></string>\n</string_table>', card.utf8)
eq(st.a, "\194\171\208\148\208\190\208\187\208\179\194\187 & <x>", "string table: comments skipped, cp1251 converted, entities decoded, the first definition wins")
eq(st.e, "", "an empty text is an empty string")
local st8 = X.parse_strings('<?xml version="1.0" encoding="utf-8"?><string id="u"><text>\208\148</text></string>', card.utf8)
eq(st8.u, "\208\148", "a UTF-8 file is not converted twice")

local sc = box.load("coop_game_schema")
local function tr_all(id)
	return { rus = "R:" .. id, eng = "E:" .. id }
end
local kit = X.export_item(sc, sc.item("c|coop_hardcore_new_kit"), tr_all)
check(kit.kind == "check" and #kit.options == 2 and kit.options[1].raw == "0" and kit.options[2].raw == "1",
	"a check (console) is two options, off then on: 0, 1")
eq(kit.options[1].label.eng, "E:st_coop_game_off", "the off label is the catalog's off string")
eq(kit.default, "0", "the default of the new kit is off")
check(kit.shownIf and kit.shownIf.key == "c|coop_death_mode" and #kit.shownIf.any == 1 and kit.shownIf.any[1] == "hardcore",
	"shown_if is carried as raw values")
local loot = X.export_item(sc, sc.item("o|coop/coop_session/loot_claim"), tr_all)
check(loot.options[1].raw == "false" and loot.options[2].raw == "true" and loot.default == "true", "a check (option): false, true")
local story = X.export_item(sc, sc.item("c|coop_story_together"), tr_all)
check(story.shownIf and story.shownIf.any[1] == "1", "shown_if of a console flag: \"1\"")
local share = X.export_item(sc, sc.item("c|coop_death_share"), tr_all)
check(share.kind == "list" and #share.options == 4 and share.options[1].raw == "50" and share.default == "100"
	and share.shownIf.any[1] == "drop" and share.shownIf.any[2] == "lose", "a list: raws in the catalog's order, default, shown_if")
local revive = X.export_item(sc, sc.item("c|coop_revive_health"), tr_all)
eq(revive.options[1].raw, "0.1", "a fraction's raw is the canonical text")
eq(revive.hint, "", "no note: the hint is \"\"")
local emi = X.export_item(sc, sc.item("o|alife/event/emission_frequency"), tr_all)
check(type(emi.hint) == "table" and emi.hint.eng == "E:st_coop_game_applies_next_emission", "a note is the hint")

local fake = { key = "c|coop_bleedout", kind = "slider", values = {}, def = 60 }
local okk, errk = pcall(X.export_item, sc, fake, tr_all)
check(not okk and tostring(errk):find("slider", 1, true) ~= nil, "a kind the export does not know is refused (" .. tostring(errk) .. ")")
local bad = { key = "c|coop_bleedout", kind = "list", values = { { 30, "x" }, { 7777, "y" } }, def = 30 }
local okb, errb = pcall(X.export_item, sc, bad, tr_all)
check(not okb and tostring(errb):find("canon", 1, true) ~= nil, "an option whose raw does not survive canon is refused (" .. tostring(errb) .. ")")
local tr_missing = X.translator({ rus = { a = "A" }, eng = {} })
local okm, errm = pcall(tr_missing, "a")
check(not okm and tostring(errm):find("'a'", 1, true) ~= nil and tostring(errm):find("eng", 1, true) ~= nil,
	"a text id without a string in a language is refused (" .. tostring(errm) .. ")")

-------------------------------------------------------------------------------
print("== (b) the committed file is the catalog now")
local okg, text = pcall(X.generate)
if not okg and tostring(text):find(X.NO_STOCK, 1, true) then
	print("  skip the stock string table is not on this machine: " .. tostring(text))
else
	check(okg, "the generator runs" .. (okg and "" or (": " .. tostring(text))))
	local file = read_file(X.OUT)
	check(file ~= nil, X.OUT .. " exists (run tools\\export_game_schema.cmd)")
	check(okg and file == text, X.OUT .. " is what the generator makes of the catalog now: if not, run tools\\export_game_schema.cmd")
	check(file and file:sub(1, 3) ~= "\239\187\191", "no BOM")
end

-------------------------------------------------------------------------------
print("== (c) the server takes every exported value as it is")
local file = read_file(X.OUT) or ""
local items = {}
local in_items = false
for line in file:gmatch("[^\n]+") do
	if line:find('^  "items": %[') then in_items = true
	elseif in_items and line:find("^  %]") then in_items = false
	elseif in_items then
		local key = line:match('^%s*{"key":"([^"]+)"')
		local opts = line:match('"options":%[(.-)%]')
		local raws = {}
		for raw in (opts or ""):gmatch('"raw":"([^"]*)"') do raws[#raws + 1] = raw end
		local def = line:match('"default":"([^"]*)"')
		items[#items + 1] = { key = key, raws = raws, def = def, line = line }
	end
end
check(#items > 0, "the file has items (" .. #items .. ")")

-- coop_dedicated in an environment of its own, with the real catalog and record, as tests\lua\test_dedicated.lua loads it
local SAFE = {}
for _, n in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset",
	"select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "string", "table", "math" }) do
	SAFE[n] = _G[n]
end
SAFE.os = { time = os.time, date = os.date, clock = os.clock }
SAFE._G = SAFE
SAFE.printf = function() end
local STAGED
SAFE.coop_game_settings = { stage_new = function(r) STAGED = r; return true end, active = function() return nil end }
local function load_mod(name)
	local src = assert(read_file("gamedata/scripts/" .. name .. ".script"), name)
	local f = assert(loadstring(src, "@" .. name .. ".script"))
	local env = setmetatable({}, { __index = SAFE })
	setfenv(f, env)
	f()
	SAFE[name] = env
	return env
end
load_mod("coop_game_schema")
load_mod("coop_game_record")
local ded = load_mod("coop_dedicated")
local bad_keys = {}
local n_pairs = 0
for _, it in ipairs(items) do
	if not it.key or #it.raws < 2 or not it.def then
		bad_keys[#bad_keys + 1] = "unreadable line: " .. it.line
	else
		local has_def = false
		for _, raw in ipairs(it.raws) do
			if raw == it.def then has_def = true end
			STAGED = nil
			local ok = ded.stage_new_world("test", { world = { faction = "stalker" }, values = { [it.key] = raw } })
			n_pairs = n_pairs + 1
			local got = STAGED and STAGED.values and STAGED.values[it.key]
			if not ok or got ~= raw then bad_keys[#bad_keys + 1] = it.key .. " = " .. raw .. " -> " .. tostring(got) end
		end
		if not has_def then bad_keys[#bad_keys + 1] = it.key .. ": the default is not one of its options" end
	end
end
check(#bad_keys == 0, n_pairs .. " key/raw pairs reach the record unchanged" .. (#bad_keys > 0 and (": " .. table.concat(bad_keys, "; ")) or ""))
-- the world's presets and flags go to [world]: the record keeps the numbers
STAGED = nil
ded.stage_new_world("test", { world = { faction = "dolg", story = false, routes = true, difficulty = 3, economy = 2 } })
check(STAGED and STAGED.faction == "dolg" and STAGED.world.difficulty == 3 and STAGED.world.economy == 2 and STAGED.world.routes == true
	and STAGED.world.story == false, "[world]: faction, presets and flags reach the record")
local ids = {}
for id in (file:match('"factions": %[(.-)%]') or ""):gmatch('{"id":"([^"]+)"') do ids[#ids + 1] = id end
eq(table.concat(ids, ","), "stalker,bandit,csky,dolg,freedom,killer,army,ecolog,monolith", "factions: the stock screen's nine, in its grid order")

finish()
