-- Anomaly Coop test (co-op window "Chronicle + map"): gamedata\scripts\coop_games.script, the data of the window: the games
-- with their display titles, the saves of a game read over several frames, old saves, the route, the map and the art.
-- The real script over stand-ins for coop_game_settings, coop_saves, the saves folder and the file system. Not shipped.
-- Run: tools\test_lua.cmd games
dofile("tests/lua/support/menu_stubs.lua")

STRINGS = {}
do
	local fh = assert(io.open(ROOT .. "configs/text/eng/st_coop_menu.xml", "r"))
	for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
	fh:close()
end
STRINGS.l01_escape, STRINGS.k00_marsh = "Cordon", "Swamps"
game = { translate_string = function(id) return STRINGS[id] or id end }

FS = { FS_ListFiles = 1, FS_RootOnly = 2, FS_sort_by_modif_down = 5 }
function bit_or(a, b) return a + b end
FILES, LISTED = {}, 0 -- { file, modif, stamp, size }
EXIST = {}
function getFS()
	return {
		file_list_open_ex = function(_, alias, flags, mask)
			LISTED = LISTED + 1
			local items = {}
			for _, s in ipairs(FILES) do items[#items + 1] = s end
			local list = {}
			function list:Size() return #items end
			function list:Sort() table.sort(items, function(a, b) return a.modif > b.modif end) end
			function list:GetAt(i)
				local s = items[i + 1]
				return { NameFull = function() return s.file end, ModifDigitOnly = function() return s.stamp end,
					Size = function() return s.size end }
			end
			return list
		end,
		exist = function(_, alias, name) return alias == "$game_textures$" and EXIST[name] or nil end,
	}
end

BLOCKS, READ = {}, {}
GAMES = {}
coop_game_settings = {
	list_games = function() return GAMES end,
	game_of_save = function(stem)
		READ[#READ + 1] = stem
		local b = BLOCKS[stem]
		if not b then return nil end
		return b.id, b
	end,
}
DETAILS, DETAIL_LEVEL = {}, {}
coop_saves = {
	details = function(e)
		DETAILS[#DETAILS + 1] = e.name
		local d = DETAIL_LEVEL[e.name]
		if d == "bad" then e.damaged = true; return e end
		e.level, e.level_text, e.game_time_str = d, STRINGS[d] or d, "15/03/2012 07:05"
		return e
	end,
}
INFO = { active = false }
coop = { is_active = function() return INFO.active end }

local cg = load_module("coop_games")

print("== titles and dates")
check(cg.display_title({ title = "With Kent", created = "2026-10-29 20:31" }) == "With Kent", "the player's title")
check(cg.display_title({ title = "   ", created = "2026-10-29 20:31" }):find("29 Oct", 1, true) ~= nil, "no title: the game of its date")
check(cg.display_title({ title = "", created = "2026-10-29 20:31" }) == (STRINGS.st_coop_menu_game_from:gsub("%%s", "29 Oct")), "the string table's wording")
check(cg.display_title({}) ~= "" and cg.display_title({}) ~= nil, "not even a date: still a name")
check(cg.day_text("2026-10-29 20:31", 2026) == "29 Oct", "the card's stamp")
check(cg.day_text("29/10/2026 23:38", 2026) == "29 Oct", "the file's stamp")
check(cg.day_text("29/10/2025 23:38", 2026) == "29 Oct 2025", "another year says so")
check(cg.time_text("29/10/2026 23:38") == "23:38" and cg.time_text("2026-10-29 07:05") == "07:05", "the time")
check(cg.gap_text("30/10/2026 19:21", "29/10/2026 23:38", 30, 2026) == "29 Oct", "the day changes: the older one's own date")
check(cg.gap_text("30/10/2026 00:10", "29/10/2026 23:50", 30, 2026) == "29 Oct", "even a minute over midnight")
check(cg.gap_text("29/10/2025 19:21", "29/10/2024 19:21", 30, 2026) == "29 Oct 2024", "and the year, another one")
check(cg.gap_text("29/10/2026 23:38", "29/10/2026 23:28", 30, 2026) == nil, "ten minutes on one day: nothing")
check(cg.gap_text("29/10/2026 23:38", "29/10/2026 23:08", 30, 2026) == nil, "thirty neither")
check(cg.gap_text("29/10/2026 23:38", "29/10/2026 23:03", 30, 2026) == "35 min without saves", "a long gap")
check(cg.gap_text("29/10/2026 21:45", "29/10/2026 20:33", 30, 2026) == "1 h 12 min without saves", "a longer one")
check(cg.gap_text("29/10/2026 21:45", "29/10/2026 20:33", nil, 2026) == nil, "the day only, when asked so")
check(cg.gap_text("junk", "29/10/2026 20:33", 30, 2026) == nil, "a stamp it does not know")
check(cg.time_text("junk") == "" and cg.day_text("junk", 2026) == "junk" and cg.day_text(nil, 2026) == "", "a stamp it does not know")
check(cg.clean_title("  Name  ") == "Name" and cg.clean_title("a%b\\c") == "a?b?c", "a title: trimmed, no format characters")
check(#cg.clean_title(string.rep("x", 200)) <= 48, "a title has a limit")
check(cg.clean_title(nil) == "", "no title is allowed")

print("== games")
GAMES = {
	{ id = "g1", name = "Stalker", title = "With Kent", faction = "stalker", created = "2026-10-29 20:31", last_played = "2026-10-29 23:38" },
	{ id = "g2", name = "Stalker", faction = "dolg", created = "2026-10-24 10:00" },
}
local function at(level, extra)
	local a = { level = level, game_time = "15/03/2012 07:05", real_time = 1000, players = { "stormie", "kent" } }
	for k, v in pairs(extra or {}) do a[k] = v end
	return a
end
FILES = {
	{ file = "coop_auto_g1_1.scop", modif = 500, stamp = "29/10/2026 23:38", size = 5000000 },
	{ file = "coop_auto_g1_2.scop", modif = 490, stamp = "29/10/2026 23:28", size = 5000000 },
	{ file = "coop_auto_g2_1.scop", modif = 480, stamp = "27/10/2026 22:10", size = 5000000 },
	{ file = "quicksave.scop", modif = 470, stamp = "27/10/2026 20:00", size = 5000000 }, -- a single player save
	{ file = "coop_auto_tmp.scop", modif = 600, stamp = "29/10/2026 23:39", size = 5000000 }, -- on its way to a slot
	{ file = "coop_auto_bak.scop", modif = 599, stamp = "29/10/2026 23:39", size = 5000000 },
	{ file = "coop_auto_g1_3.scop", modif = 460, stamp = "29/10/2026 22:53", size = 100 }, -- cut short
}
BLOCKS = {
	coop_auto_g1_1 = { id = "g1", at = at("k00_marsh") },
	coop_auto_g1_2 = { id = "g1", at = at("l01_escape") },
	coop_auto_g2_1 = { id = "g2", at = at("l01_escape") },
	coop_auto_g1_3 = { id = "g1", at = at("l01_escape") },
}
local games = cg.list()
check(#games == 2 and games[1].title == "With Kent" and games[1].faction == "stalker", "the games of the cards")
check(games[2].title:find("24 Oct", 1, true) ~= nil, "a game without a title gets its date")
check(games[1].count == 0, "no saves known before a scan")

print("== the saves of a game, over several frames")
READ, LISTED = {}, 0
cg.scan_begin()
check(LISTED == 1 and #READ == 0, "opening: the folder is listed once and nothing is read")
local done, touched = cg.scan_step(2)
check(not done and #READ == 2, "a step reads a couple of files (" .. #READ .. ")")
check(touched.g1 and not touched.g2, "and says which games got a save")
check(#cg.saves_of("g1") == 2 and cg.saves_of("g1")[1].name == "coop_auto_g1_1", "what is known is there already, newest first")
done = cg.scan_step(2)
check(not done and #READ == 4, "the next frame goes on")
done = cg.scan_step(2)
check(done and #READ == 5, "and comes to the end: the temporary names are not read")
local n = #READ
done, touched = cg.scan_step(2)
check(done and #READ == n and next(touched) == nil, "after the end nothing is read")
local s1 = cg.saves_of("g1")
check(#s1 == 3 and s1[1].name == "coop_auto_g1_1" and s1[2].name == "coop_auto_g1_2" and s1[3].name == "coop_auto_g1_3", "the saves of a game, newest first")
check(#cg.saves_of("g2") == 1 and #cg.saves_of("nope") == 0, "another game has its own; an unknown one none")
check(s1[1].level == "k00_marsh" and s1[1].level_text == "Swamps" and s1[1].game_time == "15/03/2012 07:05" and s1[1].players[2] == "kent", "the block's data")
check(s1[1].t == "23:38" and s1[1].legacy == nil, "the time of the row")
check(s1[3].damaged == true and s1[1].damaged == false, "a file below the smallest plausible size is damaged")
check(cg.usable("g1").name == "coop_auto_g1_1", "the newest save that can be loaded")
FILES[1].size = 1
READ = {}
cg.scan_begin(); cg.scan_finish()
check(#READ == 5 and cg.usable("g1").name == "coop_auto_g1_2", "a damaged newest save is passed over; a click can finish the scan")
FILES[1].size = 5000000
cg.scan_begin(); cg.scan_finish()
games = cg.list()
check(games[1].count == 3 and games[1].level == "k00_marsh" and games[1].level_text == "Swamps" and games[1].stamp == "29/10/2026 23:38", "the summary of a game")
check(games[2].count == 1 and games[2].level == "l01_escape", "of each game")

print("== the old ring: a game's saves are found by their blocks, whatever their names")
FILES = {
	{ file = "coop_auto_g1_1.scop", modif = 500, stamp = "29/10/2026 23:38", size = 5000000 },
	{ file = "coop_auto_7.scop", modif = 400, stamp = "28/10/2026 22:00", size = 5000000 }, -- written before the game had a ring
}
BLOCKS = { coop_auto_g1_1 = { id = "g1", at = at("k00_marsh") }, coop_auto_7 = { id = "g1", at = at("l01_escape") } }
cg.scan_begin(); cg.scan_finish()
check(#cg.saves_of("g1") == 2 and cg.saves_of("g1")[2].name == "coop_auto_7", "an older coop_auto_N of the same game is in its chronicle")

print("== old saves: no `at` in the block")
FILES = {
	{ file = "old_3.scop", modif = 300, stamp = "20/10/2026 21:00", size = 5000000 },
	{ file = "old_2.scop", modif = 200, stamp = "20/10/2026 20:50", size = 5000000 },
	{ file = "old_1.scop", modif = 100, stamp = "20/10/2026 20:40", size = 5000000 },
	{ file = "old_cut.scop", modif = 90, stamp = "20/10/2026 20:30", size = 100 },
}
BLOCKS = { old_3 = { id = "g1" }, old_2 = { id = "g1" }, old_1 = { id = "g1" }, old_cut = { id = "g1" } }
DETAIL_LEVEL = { old_3 = "k00_marsh", old_2 = "l01_escape", old_1 = "bad" }
DETAILS = {}
cg.scan_begin(); cg.scan_finish()
local s = cg.saves_of("g1")
check(#DETAILS == 0 and s[1].legacy == true and s[1].level == nil, "the scan opens no save")
INFO.active = true
check(cg.legacy_step("g1") == false and #DETAILS == 0, "in a session no save is opened")
INFO.active = false
check(cg.legacy_step("g1") == true and #DETAILS == 1 and DETAILS[1] == "old_3" and s[1].level == "k00_marsh", "outside: one per step, newest first")
check(cg.legacy_step("g2") == false and #DETAILS == 1, "only the game that is asked for")
cg.legacy_step("g1")
check(#DETAILS == 2 and s[2].level_text == "Cordon", "the next one")
cg.legacy_step("g1")
check(#DETAILS == 3 and s[3].damaged == true, "a file that cannot be read turns out damaged")
check(cg.legacy_step("g1") == false and #DETAILS == 3, "a damaged file is never opened")
DETAILS = {}
cg.scan_begin(); cg.scan_finish()
s = cg.saves_of("g1")
check(s[1].level == "k00_marsh" and s[1].level_text == "Swamps", "the next window has them without a read")
cg.legacy_step("g1")
check(#DETAILS == 0, "read once per name, time and size")
FILES[1].stamp = "20/10/2026 21:05"
cg.scan_begin(); cg.scan_finish()
cg.legacy_step("g1")
check(#DETAILS == 1 and DETAILS[1] == "old_3", "a file written since is read again")
do
	local keep = coop_saves
	coop_saves = { details = function() error("boom") end }
	FILES = { { file = "x.scop", modif = 1, stamp = "20/10/2026 21:00", size = 5000000 } }
	BLOCKS = { x = { id = "g1" } }
	cg.scan_begin(); cg.scan_finish()
	check(pcall(cg.legacy_step, "g1"), "details that throw do not stop the window")
	coop_saves = keep
end

print("== route: one stop per run of a level, oldest first")
local LEVELS = { k00_marsh = { .1, .8 }, l01_escape = { .4, .7 }, l02_garbage = { .5, .6 }, l05_bar = { .4, .5 } }
function cg.level_uv(level)
	local p = LEVELS[level]
	if p then return p[1], p[2] end
	return nil
end
local function save(level, t) return { level = level, t = t, name = "s" .. t } end
local saves = { -- as d.js: newest first
	save("k00_marsh", "23:38"), save("k00_marsh", "23:28"), save("k00_marsh", "22:53"), save("l01_escape", "22:45"),
	save("l01_escape", "22:35"), save("l01_escape", "22:25"), save("l02_garbage", "22:15"), save("l02_garbage", "22:05"),
	save("l05_bar", "21:55"), save("l05_bar", "21:45"),
}
local stops = cg.route_of(saves)
check(#stops == 4, "four runs, four stops (" .. #stops .. ")")
check(stops[1].level == "l05_bar" and stops[4].level == "k00_marsh", "oldest first")
check(stops[1].pick == 9 and stops[1].t == "21:55", "a stop picks the newest save of its run")
check(stops[4].pick == 1 and stops[4].t == "23:38", "the last stop is the newest save")
check(stops[1].u == .4 and stops[1].v == .5, "a stop knows its place on the map")
check(#cg.route_of({ save("k00_marsh", "1"), save("l01_escape", "2"), save("k00_marsh", "3") }) == 3, "back to a place: a stop of its own")
saves = { save("k00_marsh", "3"), save(nil, "2"), save("nowhere", "2b"), save("k00_marsh", "1") }
stops = cg.route_of(saves)
check(#stops == 1 and stops[1].pick == 1, "a save without a known level is no stop and does not cut a run")
check(#cg.route_of({}) == 0, "no saves: no stops")

print("== map: positions from game_maps_single.ltx")
function ini_file(name)
	check(name == "game_maps_single.ltx", "the file the engine reads the global map from")
	return ini_over(REF .. "configs/game_maps_single.ltx")
end
cg = load_module("coop_games")
local u, v = cg.level_uv("l01_escape") -- 358,2022,564,2434 on a 1024 x 2634 map
check(math.abs(u - 461 / 1024) < 1e-6 and math.abs(v - 2228 / 2634) < 1e-6, "the middle of global_rect over bound_rect (" .. tostring(u) .. ", " .. tostring(v) .. ")")
check(cg.level_uv("no_such_level") == nil, "an unknown level: nothing")
check(cg.level_uv(nil) == nil, "no level: nothing")
check(cg.map_texture() == "ui\\ui_global_map", "the texture of the global map")
do
	local mm = load_module("coop_games")
	ini_file = function()
		return { section_exist = function() return false end, line_exist = function() return false end }
	end
	check(mm.level_uv("l01_escape") == nil and mm.map_texture() == nil, "no [global_map]: no stops, no crash")
	local m2 = load_module("coop_games")
	ini_file = function() error("no such file") end
	check(m2.level_uv("l01_escape") == nil, "a file that cannot be opened: no crash")
	local m3 = load_module("coop_games")
	ini_file = function()
		return { section_exist = function(_, s) return true end, line_exist = function() return true end,
			r_string = function(_, s, k) return k == "bound_rect" and "0, 0, 0, 0" or "junk" end }
	end
	check(m3.level_uv("l01_escape") == nil, "a broken bound_rect: no crash")
	cg = load_module("coop_games")
	ini_file = function()
		return { section_exist = function(_, s) return s == "global_map" or s == "out" end, line_exist = function() return true end,
			r_string = function(_, s, k)
				if k == "bound_rect" then return "0, 0, 100, 100" end
				if k == "texture" then return "ui\\map" end
				return "500, 500, 600, 600"
			end }
	end
	check(cg.level_uv("out") == nil, "a rectangle outside the map: no stop")
end

print("== art of a level")
local rule = { pattern = "intro\\intro_%s_%d", max_n = 9, levels = { special = "ui\\my_art" }, fallback = { "intro\\spare_1", "intro\\spare_2" } }
EXIST = { ["intro\\intro_l01_escape_1.dds"] = true, ["intro\\intro_l01_escape_3.dds"] = true, ["intro\\intro_l01_escape_7.dds"] = true,
	["intro\\intro_k00_marsh_2.dds"] = true, ["intro\\spare_2.dds"] = true }
local art = cg.art_of("l01_escape", rule)
check(art == "intro\\intro_l01_escape_1" or art == "intro\\intro_l01_escape_3" or art == "intro\\intro_l01_escape_7", "one of the files that exist (" .. tostring(art) .. ")")
local same = true
for _ = 1, 5 do if cg.art_of("l01_escape", rule) ~= art then same = false end end
check(same, "the same one every time")
local fresh = load_module("coop_games")
check(fresh.art_of("l01_escape", rule) == art, "in a fresh Lua state too: chosen by the level's name")
cg = fresh
check(cg.art_of("k00_marsh", rule) == "intro\\intro_k00_marsh_2", "the only file of a level")
check(cg.art_of("special", rule) == "ui\\my_art", "a level the theme names itself")
check(cg.art_of("no_art_here", rule) == "intro\\spare_2", "no art: the fallback that exists")
check(cg.art_of(nil, rule) == "intro\\spare_2", "no level: the fallback")
EXIST = {}
check(load_module("coop_games").art_of("l01_escape", rule) == nil, "nothing at all: no art, no crash")
local PATCHES = { prefix = "ui_mm_faction_", known = { dolg = true, stalker = true }, fallback = "stalker" }
check(cg.patch_of("dolg", PATCHES) == "ui_mm_faction_dolg", "the patch of a faction")
check(cg.patch_of("unknown", PATCHES) == "ui_mm_faction_stalker", "an unknown faction: the fallback patch")
check(cg.patch_of(nil, PATCHES) == "ui_mm_faction_stalker", "no faction")

print("== a new game's title on its way to the record")
cg.set_new_title("  My game ")
check(cg.take_new_title() == "My game" and cg.take_new_title() == nil, "taken once")
cg.set_new_title("   ")
check(cg.take_new_title() == nil, "an empty name is no title")

print("== a frame reads by time, a click stops at the answer")
FILES = {
	{ file = "coop_auto_g1_1.scop", modif = 500, stamp = "29/10/2026 23:38", size = 5000000 },
	{ file = "coop_auto_g1_2.scop", modif = 490, stamp = "29/10/2026 23:28", size = 5000000 },
	{ file = "coop_auto_g2_1.scop", modif = 480, stamp = "27/10/2026 22:10", size = 5000000 },
	{ file = "quicksave.scop", modif = 470, stamp = "27/10/2026 20:00", size = 5000000 },
	{ file = "coop_auto_g1_3.scop", modif = 460, stamp = "29/10/2026 22:53", size = 5000000 },
}
BLOCKS = {
	coop_auto_g1_1 = { id = "g1", at = at("k00_marsh") },
	coop_auto_g1_2 = { id = "g1", at = at("l01_escape") },
	coop_auto_g2_1 = { id = "g2", at = at("l01_escape") },
	coop_auto_g1_3 = { id = "g1", at = at("l01_escape") },
}
local tick = 5000 -- microseconds a file costs
profile_timer = function()
	local spent = 0
	return { start = function() end, stop = function() spent = spent + tick end, time = function() return spent end }
end
READ = {}
cg.scan_begin()
cg.scan_step()
check(#READ == 1, "a slow file takes the whole share of a frame (" .. #READ .. ")")
tick = 1000
cg.scan_step()
check(#READ == 4, "quick files share it (" .. #READ .. ")")
profile_timer = nil
READ = {}
cg.scan_begin()
cg.scan_step()
check(#READ == 1, "without a clock a frame reads one file (" .. #READ .. ")")
READ = {}
cg.scan_begin()
local found = cg.scan_until_usable("g2")
check(found and found.name == "coop_auto_g2_1" and #READ == 3 and not cg.scan_done(), "a click reads up to the newest good save of its game (" .. #READ .. ")")
check(cg.scan_until_usable("nope") == nil and cg.scan_done(), "with no such save the whole folder is read")

print(string.format("%d passed, %d failed", PASSES, FAILS))
