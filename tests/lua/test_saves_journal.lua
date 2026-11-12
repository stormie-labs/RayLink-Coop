-- Anomaly Coop: the journal of a world's saves for the launcher's chronicle, gamedata\scripts\coop_saves_journal.script.
-- Pure logic: the entry's line, reading the lines back, merging (a slot written again replaces its line), the file's text.
-- The modules are loaded into a sealed environment that has the Lua standard library and nothing of the engine. Not shipped.
-- Run: tools\test_lua.cmd saves_journal
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

local function load_module(name, extra)
	local fh = assert(io.open("gamedata/scripts/" .. name .. ".script", "rb"), "gamedata/scripts/" .. name .. ".script is missing")
	local src = fh:read("*a")
	fh:close()
	local f = assert(loadstring(src, "@" .. name .. ".script"))
	local env = {}
	for _, n in ipairs({ "assert", "error", "ipairs", "next", "pairs", "pcall", "rawget", "select", "tonumber", "tostring", "type", "unpack",
		"string", "table", "math" }) do
		env[n] = _G[n]
	end
	for k, v in pairs(extra or {}) do env[k] = v end
	env._G = env
	setfenv(f, env)
	f()
	return env
end

local j = load_module("coop_saves_journal", { coop_json_card = load_module("coop_json_card") })

print("== why")
check(j.why_of(0) == "timer" and j.why_of(1) == "sleep" and j.why_of(2) == "level" and j.why_of(3) == "end" and j.why_of(4) == "transfer"
	and j.why_of(5) == "manual", "the engine's reasons by their numbers, in the order of coop_autosave_rules.h")
check(j.why_of("save") == "save" and j.why_of("end") == "end", "the words pass")
check(j.why_of(6) == "" and j.why_of("hack") == "" and j.why_of(nil) == "" and j.why_of({}) == "", "anything else is no reason")

print("== an entry's line")
local line = j.entry_line({ stem = "coop_auto_6a01c2d4-0e11_3", when = "2026-11-12 22:15", why = 3, game_time = "14/05/2012 21:40",
	players = { { nick = "serge", level = "l05_bar" }, { nick = "bob", level = "l02_garbage" }, { nick = "" }, "junk", { level = "x" } } })
check(line == '{"stem":"coop_auto_6a01c2d4-0e11_3","when":"2026-11-12 22:15","why":"end","game_time":"14/05/2012 21:40",'
	.. '"players":[{"nick":"serge","level":"l05_bar"},{"nick":"bob","level":"l02_garbage"}]}', "the whole entry: " .. tostring(line))
check(j.entry_line({ stem = "s", when = "2026-11-12 22:15" }) == '{"stem":"s","when":"2026-11-12 22:15"}', "nothing but the stem and the time")
check(j.entry_line({ stem = "s", when = "w", why = "nonsense", players = {} }) == '{"stem":"s","when":"w"}', "an unknown reason and nobody: left out")
check(j.entry_line({ when = "w" }) == nil and j.entry_line({ stem = "" }) == nil and j.entry_line("s") == nil, "no stem: no line")
-- a nick is what a player typed: quotes, a backslash, a line break and cp1251 letters stay inside its JSON string, on one line
local odd = j.entry_line({ stem = "s", when = "w", players = { { nick = 'a"b\\c\nd', level = "l01_escape" }, { nick = "\204\229\247\229\237\251\233", level = "" } } })
check(odd == '{"stem":"s","when":"w","players":[{"nick":"a\\"b\\\\c\\nd","level":"l01_escape"},{"nick":"\208\156\208\181\209\135\208\181\208\189\209\139\208\185","level":""}]}',
	"escaped, and cp1251 as UTF-8: " .. tostring(odd))
check(not odd:find("\n", 1, true), "an entry is one line whatever a player typed")

print("== reading the lines back")
local text = j.encode("6a01c2d4-0e11", { j.entry_line({ stem = "a_1", when = "t1" }), j.entry_line({ stem = "a_2", when = "t2", why = "timer" }) })
check(text == '{"format":1,"id":"6a01c2d4-0e11","saves":[\n{"stem":"a_1","when":"t1"},\n{"stem":"a_2","when":"t2","why":"timer"}\n]}\n', "the file: " .. text)
local lines = j.lines_of(text)
check(#lines == 2 and lines[1] == '{"stem":"a_1","when":"t1"}' and lines[2] == '{"stem":"a_2","when":"t2","why":"timer"}', "the entries, without the commas between them")
check(#j.lines_of(text:gsub("\n", "\r\n")) == 2, "CRLF too")
check(#j.lines_of("") == 0 and #j.lines_of(nil) == 0 and #j.lines_of("{\"format\":1}") == 0 and #j.lines_of("{\"stem\":\"cut off") == 0, "what is not a journal has no entries")
check(j.encode("g", {}) == '{"format":1,"id":"g","saves":[]}\n' and #j.lines_of(j.encode("g", {})) == 0, "an empty journal")
check(j.stem_key('{"stem":"a_1","when":"t1"}') == '"a_1"' and j.stem_key("]}") == nil and j.stem_key(5) == nil, "the stem of a line")

print("== merging")
local merged = j.merge(lines, j.entry_line({ stem = "a_1", when = "t3", why = "end" }), 10)
check(#merged == 2 and merged[1] == lines[2] and merged[2] == '{"stem":"a_1","when":"t3","why":"end"}', "a slot written again: its older line goes, the new one is last")
check(#lines == 2 and lines[1] == '{"stem":"a_1","when":"t1"}', "the list given is not changed")
merged = j.merge(merged, j.entry_line({ stem = "a_3", when = "t4" }), 2)
check(#merged == 2 and j.stem_key(merged[1]) == '"a_1"' and j.stem_key(merged[2]) == '"a_3"', "the oldest beyond the limit go")
check(#j.merge(merged, "not a line", 2) == 2 and #j.merge(nil, j.entry_line({ stem = "x", when = "t" }), 5) == 1, "a line that is no entry adds nothing; no list is an empty one")
local many = {}
for i = 1, j.MAX + 5 do many = j.merge(many, j.entry_line({ stem = "s_" .. i, when = "t" })) end
check(#many == j.MAX and j.stem_key(many[#many]) == '"s_' .. (j.MAX + 5) .. '"' and j.MAX >= 50, "the journal keeps MAX entries, no fewer than the largest ring")
-- round trip through the file
local again = j.lines_of(j.encode("g", many))
check(#again == #many and again[1] == many[1] and again[#again] == many[#many], "written and read back: the same lines")

print(string.format("%d passed, %d failed", PASSES, FAILS))
