-- Anomaly Coop test: gamedata\scripts\coop_world_stage_file.script, the writer of the new world's staging file
-- (coop_new_world.ltx, engine\src\xrCoop\coop_world_stage.h is the contract; split levels plan 2026-11-12 sections 3.1, 4.2).
-- native_coop.cpp does not expose the engine's parser, so the text is compared with the canonical form of the header's
-- write() (the same order, the same quoting), and every refusal of the header's parse is refused before writing.
-- Not shipped. Run: tools\test_lua.cmd world_stage_file
dofile("tests/lua/support/menu_stubs.lua")

local sf = load_module("coop_world_stage_file")
check(type(sf.build) == "function", "coop_world_stage_file.build exists")

-- a record as coop_game_record.new makes it
local function record()
	return {
		id = "6553f1a2-00ff", name = "Strelok", title = "With Kent", faction = "stalker",
		world = { story = true, routes = false, difficulty = 2, economy = 3 },
	}
end

print("== the canonical text of the header")
do
	local values = { ["c|coop_split_levels"] = "1", ["c|coop_death_mode"] = "checkpoint", ["o|gameplay/diff/b"] = 2,
		["s|flag"] = true }
	local creator = { name = "Strelok", icon = "ui_icon_1", loadout = { "wpn_pm", "ammo_9x18_fmj", "ammo_9x18_fmj" }, money = 5000,
		map = "esc_start", bare = false }
	local text, why = sf.build(record(), values, creator)
	check(text ~= nil, "a full record is written (" .. tostring(why) .. ")")
	local want = table.concat({
		"[world]",
		"faction = stalker",
		"id = 6553f1a2-00ff",
		"name = Strelok",
		"title = With Kent",
		"story = 1",
		"routes = 0",
		"difficulty = 2",
		"economy = 3",
		"",
		"[values]",
		"\"c|coop_death_mode\" = checkpoint",
		"\"c|coop_split_levels\" = 1",
		"\"o|gameplay/diff/b\" = 2",
		"\"s|flag\" = true",
		"",
		"[creator]",
		"name = Strelok",
		"icon = ui_icon_1",
		"loadout = wpn_pm,ammo_9x18_fmj,ammo_9x18_fmj",
		"money = 5000",
		"map = esc_start",
		"bare = 0",
		"",
	}, "\n")
	check(text == want, "the text is the header's write() form, values sorted by key")
	if text ~= want then print(text) end
end

print("== optional parts")
do
	local r = { faction = "bandit", name = "", world = {} }
	local text = sf.build(r, {}, nil)
	check(text == "[world]\nfaction = bandit\nname = \ntitle = \n", "no id, no flags, no values, no creator: only [world]")
	local t2 = sf.build({ faction = "ecolog", name = "  padded ", title = "x" }, {}, { name = "A", loadout = {}, money = 0, bare = true })
	check(t2 and t2:find("\nname = \"  padded \"\n", 1, true) ~= nil, "a value with blanks at its ends is quoted")
	check(t2 and t2:find("\n%[creator%]\nname = A\nicon = \nloadout = \nmoney = 0\nmap = \nbare = 1\n") ~= nil, "an empty kit chosen: bare = 1")
	local t3 = sf.build({ faction = "stalker", name = "\207\240\232\226\229\242", title = "\204\238\233 \236\232\240" }, {}, nil)
	check(t3 and t3:find("title = \204\238\233 \236\232\240\n", 1, true) ~= nil, "cp1251 text passes as it is; inner blanks need no quotes")
	local t4 = sf.build({ faction = "stalker", world = { story = false, difficulty = 1 } }, { ["g|f"] = 1.5 }, nil)
	check(t4 and t4:find("story = 0\ndifficulty = 1\n", 1, true) ~= nil and t4:find("\"g|f\" = 1.5\n", 1, true) ~= nil, "flags and numbers")
end

print("== refused before writing")
local function refused(what, r, values, creator, pat)
	local text, why = sf.build(r, values or {}, creator)
	check(text == nil and type(why) == "string" and (pat == nil or why:find(pat, 1, true) ~= nil),
		what .. " (" .. tostring(why) .. ")")
end
local function rc(patch)
	local r = record()
	for k, v in pairs(patch) do r[k] = v end
	return r
end
refused("no faction", rc({ faction = false }), nil, nil, "faction")
refused("a faction that is not a word", rc({ faction = "a b" }), nil, nil, "faction")
refused("an id with a dot", rc({ id = "a.b" }), nil, nil, "id")
refused("a name over 64 bytes", rc({ name = string.rep("n", 65) }), nil, nil, "name")
refused("a title over 64 bytes", rc({ title = string.rep("t", 65) }), nil, nil, "title")
refused("a control character in the name", rc({ name = "a\nb" }), nil, nil, "name")
refused("a quote in the title", rc({ title = "say \"hi\"" }), nil, nil, "title")
refused("difficulty 4", rc({ world = { difficulty = 4 } }), nil, nil, "difficulty")
refused("a key without a source", record(), { ["x|a"] = "1" }, nil, "x|a")
refused("a key without a path", record(), { ["c|"] = "1" }, nil, "c|")
refused("a key with a quote", record(), { ["c|a\"b"] = "1" }, nil)
refused("a key with '='", record(), { ["c|a=b"] = "1" }, nil)
refused("a value with a quote", record(), { ["c|a"] = "x\"y" }, nil, "c|a")
refused("a value with a tab inside", record(), { ["c|a"] = "x\ty" }, nil, "c|a")
refused("a value over 1024 bytes", record(), { ["c|a"] = string.rep("v", 1025) }, nil, "c|a")
refused("a value that is a table", record(), { ["c|a"] = {} }, nil, "c|a")
do
	local many = {}
	for i = 1, 2049 do many["c|k" .. i] = "1" end
	refused("more than 2048 values", record(), many, nil, "2048")
end
refused("a creator's name over 64", record(), {}, { name = string.rep("c", 65), loadout = {} }, "name")
refused("an icon that is not a word", record(), {}, { name = "a", icon = "x y", loadout = {} }, "icon")
refused("a map that is not a word", record(), {}, { name = "a", map = "a/b", loadout = {} }, "map")
refused("a loadout entry that is not a word", record(), {}, { name = "a", loadout = { "wpn pm" } }, "loadout")
do
	local kit = {}
	for i = 1, 65 do kit[i] = "ammo_9x18_fmj" end
	refused("65 loadout entries", record(), {}, { name = "a", loadout = kit }, "64")
	kit[65] = nil
	check(sf.build(record(), {}, { name = "a", loadout = kit }) ~= nil, "64 entries are taken")
end
refused("money below 0", record(), {}, { name = "a", loadout = {}, money = -1 }, "money")
refused("money over 10000000", record(), {}, { name = "a", loadout = {}, money = 10000001 }, "money")
refused("money with a fraction", record(), {}, { name = "a", loadout = {}, money = 1.5 }, "money")
check(sf.build(record(), {}, { name = "a", loadout = {}, money = 10000000 }) ~= nil, "money 10000000 is taken")
check(sf.build(record(), {}, { name = "a", loadout = "wpn_pm,,ammo_9x18_fmj" }):find("loadout = wpn_pm,ammo_9x18_fmj\n", 1, true) ~= nil,
	"a loadout as the stock's csv string: empty entries dropped")

print("== writing the file")
do
	local dir = "temp/tests_s6b"
	os.execute("mkdir temp\\tests_s6b 2>nul")
	local path = dir .. "/coop_new_world.ltx"
	local ok, why = sf.write_file(path, "[world]\nfaction = stalker\n")
	check(ok == true, "the file is written (" .. tostring(why) .. ")")
	local fh = io.open(path, "rb")
	local back = fh and fh:read("*a")
	if fh then fh:close() end
	check(back == "[world]\nfaction = stalker\n", "bytes as they are, \\n line ends")
	os.remove(path)
	local ok2, why2 = sf.write_file(dir .. "/no/such/folder/x.ltx", "x")
	check(ok2 == false and type(why2) == "string", "a folder that is not there: false and why")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
