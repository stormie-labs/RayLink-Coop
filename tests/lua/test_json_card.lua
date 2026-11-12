-- Anomaly Coop test: gamedata\scripts\coop_json_card.script, the readable twin of a game's card ($game_saves$\<id>.cgame.json) for
-- the launcher, which cannot read the marshal of <id>.cgame (docs\plans\2026-11-12-split-levels-native.md section 6.3). Pure logic:
-- the module is loaded into a sealed environment that has the Lua standard library and nothing of the engine. Not shipped.
-- Run: tools\test_lua.cmd json_card
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

local function load_module(name)
	local fh = io.open("gamedata/scripts/" .. name .. ".script", "rb")
	if not fh then return nil, "gamedata/scripts/" .. name .. ".script is missing" end
	local src = fh:read("*a")
	fh:close()
	local f, err = loadstring(src, "@" .. name .. ".script")
	if not f then return nil, err end
	local env = {}
	for _, n in ipairs({ "assert", "error", "ipairs", "next", "pairs", "pcall", "select", "tonumber", "tostring", "type", "unpack",
		"string", "table", "math" }) do
		env[n] = _G[n]
	end
	env._G = env
	setfenv(f, env)
	f()
	return env
end

local J, why = load_module("coop_json_card")
if not J then
	print("  FAIL coop_json_card loads: " .. tostring(why))
	print("0 passed, 1 failed")
	os.exit(1)
end

-- ------------------------------------------------------------------------------------------------ cp1251 -> UTF-8
eq(J.utf8("Zone 1"), "Zone 1", "ASCII stays")
eq(J.utf8("\204\232\240"), "\208\156\208\184\209\128", "cp1251 'Mir' in Russian letters becomes UTF-8")
eq(J.utf8("\168\184"), "\208\129\209\145", "the letters IO: U+0401 and U+0451")
eq(J.utf8("\192\255"), "\208\144\209\143", "the first and the last letter of the alphabet block")
eq(J.utf8("\171x\187"), "\194\171x\194\187", "angle quotes are two-byte")
eq(J.utf8("\150\151\133"), "\226\128\147\226\128\148\226\128\166", "the dashes and the ellipsis are three-byte")
eq(J.utf8("\185"), "\226\132\150", "the numero sign")
eq(J.utf8("\152"), "\239\191\189", "the one undefined byte of cp1251 is the replacement character")
eq(J.utf8(""), "", "an empty string")
eq(J.utf8(nil), "", "nil is an empty string")

-- ------------------------------------------------------------------------------------------------ a JSON string
eq(J.str("a"), "\"a\"", "a plain string is quoted")
eq(J.str("a\"b\\c"), "\"a\\\"b\\\\c\"", "the quote and the backslash are escaped")
eq(J.str("a\nb\tc\r"), "\"a\\nb\\tc\\r\"", "the usual control characters by name")
eq(J.str("\1\31"), "\"\\u0001\\u001f\"", "the other control characters by number")
eq(J.str("\127"), "\"\\u007f\"", "DEL by number")
eq(J.str("\204\232\240"), "\"\208\156\208\184\209\128\"", "cp1251 goes out as UTF-8")

-- ------------------------------------------------------------------------------------------------ the card
local full = J.encode({
	id = "0a1b2c3d-00ff", name = "\204\232\240", title = "With \"Kent\"", faction = "stalker", created = "2026-11-12 23:40",
	last_played = "2026-11-12 23:55", last_save = "coop_auto_0a1b2c3d-00ff_3", rev = 7,
	values = { ["c|coop_split_levels"] = "1", ["c|coop_world_server"] = "1", ["c|coop_other"] = "5" },
	players = { "Kent", "\204\232\240" },
})
eq(full,
	"{\"format\":1,\"id\":\"0a1b2c3d-00ff\",\"name\":\"\208\156\208\184\209\128\",\"title\":\"With \\\"Kent\\\"\",\"faction\":\"stalker\"," ..
	"\"created\":\"2026-11-12 23:40\",\"last_played\":\"2026-11-12 23:55\",\"last_save\":\"coop_auto_0a1b2c3d-00ff_3\",\"split\":true,\"world_server\":true," ..
	"\"rev\":7,\"players\":[\"Kent\",\"\208\156\208\184\209\128\"]}",
	"a full card: a fixed order of keys, UTF-8, split from the game's value")

eq(J.encode({ id = "x", name = "", values = {} }), "{\"format\":1,\"id\":\"x\",\"name\":\"\",\"split\":false,\"world_server\":false}",
	"a bare card: what is missing is left out, split is false")
eq(J.encode({ id = "x", values = { ["c|coop_split_levels"] = 0 } }), "{\"format\":1,\"id\":\"x\",\"name\":\"\",\"split\":false,\"world_server\":false}",
	"split 0 is false, a missing name is empty")
eq(J.encode({ id = "x", values = { ["c|coop_split_levels"] = true } }), "{\"format\":1,\"id\":\"x\",\"name\":\"\",\"split\":true,\"world_server\":false}",
	"split true is true")
eq(J.encode({ id = "x", values = { ["c|coop_split_levels"] = "0" } }), "{\"format\":1,\"id\":\"x\",\"name\":\"\",\"split\":false,\"world_server\":false}",
	"split \"0\" is false")
eq(J.encode({ id = "x", rev = "12", players = {} }), "{\"format\":1,\"id\":\"x\",\"name\":\"\",\"split\":false,\"world_server\":false,\"rev\":12}",
	"rev is a number, an empty list of players is left out")
eq(J.encode({ id = "x", rev = 1.5, title = 5, players = { 1, "a", {}, "" } }),
	"{\"format\":1,\"id\":\"x\",\"name\":\"\",\"split\":false,\"world_server\":false,\"players\":[\"a\"]}",
	"a rev that is not a whole number, a title that is not a string and players that are not names are left out")
eq(J.encode({ id = "x", values = { ["c|coop_world_server"] = true } }),
	"{\"format\":1,\"id\":\"x\",\"name\":\"\",\"split\":false,\"world_server\":true}", "world_server is read as split is: true")
eq(J.encode({ id = "x", values = { ["c|coop_split_levels"] = "1", ["c|coop_world_server"] = "0" } }),
	"{\"format\":1,\"id\":\"x\",\"name\":\"\",\"split\":true,\"world_server\":false}", "the old split mode: split true, world_server false")
check(J.encode(nil) == nil, "no card: nil")
check(J.encode({}) == nil, "a card without an id: nil")
check(J.encode({ id = 5 }) == nil, "an id that is not a string: nil")
eq(J.FILE_EXT, ".cgame.json", "the file's extension")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
