-- coop_util (Core, docs\CODE_RULES.md LUA-1): each helper answers what the copies it replaces answer. The old copies are
-- written out below as the oracles (golden), and every helper is compared with them on the same inputs. Runs under every
-- test answer set (tests\lua\support\modes.lua, COOP_LUA_MODE): the helpers never ask the facade, except the two session
-- roles (decides_in_session, live_mirror), which are compared with their copies under each set's answers.
-- Not shipped. Run: tools\test_lua.cmd test_util
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")
local U = load_script("coop_util")
local guard = dofile("tests/lua/support/roster_guard.lua")

-- the string table: "known" has a text, "blank" an empty one, "boom" raises, anything else comes back as the id
local TEXTS = { known = "Known %s and %s", blank = "" }
local real_game = game
game = {
	translate_string = function(id)
		if id == "boom" then error("no string table") end
		local s = TEXTS[id]
		if s == nil then return id end
		return s
	end,
}

-- golden: the copies the helpers replace, as they are written in the scripts
local old = {}
-- coop_core_player:51, coop_core_world:78, coop_allies_map:63 (the same body)
function old.tr_a(id, fallback)
	local ok, s = pcall(game.translate_string, id)
	if not ok or type(s) ~= "string" or s == id then return fallback or id end
	return s
end
-- coop_economy_core:133
function old.tr_d(id, fallback)
	local g = rawget(_G, "game")
	if g and g.translate_string then
		local ok, s = pcall(g.translate_string, id)
		if ok and type(s) == "string" and s ~= id then return s end
	end
	return fallback or id
end
-- coop_debug_client:36, coop_srv_levels:14 (no fallback)
function old.tr_g(id)
	local ok, text = pcall(function() return game.translate_string(id) end)
	return (ok and type(text) == "string") and text or id
end
-- coop_hud_arena:74, coop_hud_revive:253, coop_hud_transition:167
function old.tr_c(id, fallback)
	local ok, s = pcall(function() return game.translate_string(id) end)
	if ok and type(s) == "string" and s ~= "" and s ~= id then return s end
	return fallback or id
end
-- coop_ui:41 T
function old.T(id, fallback, ...)
	local s
	local g = rawget(_G, "game")
	if g and g.translate_string then
		local ok, r = pcall(g.translate_string, id)
		if ok and type(r) == "string" and r ~= id and r ~= "" then s = r end
	end
	s = s or fallback
	if select("#", ...) > 0 then
		local args, i = { ... }, 0
		s = s:gsub("%%s", function()
			i = i + 1
			return tostring(args[i])
		end)
	end
	return s
end
-- coop_progress_community:20 bare
function old.bare(f)
	if type(f) ~= "string" then return nil end
	f = f:gsub("^actor_", "")
	return f ~= "" and f or nil
end
-- coop_bounty:93, coop_npc_sim_target:26
function old.level_of(gvid)
	if type(gvid) ~= "number" then return nil end
	local ok, lid = pcall(function() return game_graph():vertex(gvid):level_id() end)
	if ok then return lid end
	return nil
end
-- coop_hostplay_mode:21, coop_srv_mode:34
function old.call(f, ...)
	if type(f) ~= "function" then return nil end
	local ok, v = pcall(f, ...)
	if ok then return v end
	return nil
end
-- coop_mods_core.mod
local fs_cache = {}
function old.mod(name)
	if type(name) ~= "string" then return nil end
	local m = rawget(_G, name)
	if m == nil then
		local known = fs_cache[name]
		if known == nil then
			local ok, ex = pcall(function() return getFS():exist("$game_scripts$", name .. ".script") end)
			known = (not ok) or (ex ~= nil and ex ~= false)
			fs_cache[name] = known
		end
		if not known then return nil end
		local ok, r = pcall(function() return _G[name] end)
		m = ok and r or nil
	end
	return type(m) == "table" and m or nil
end
-- leads_level of the world scripts (coop_core_world_news, _mloot, _trader); coop_quests_missions:515 and coop_arena:153
-- (authority) ask the same three questions
function old.leads_level()
	return (coop ~= nil and coop.is_active()) and (coop_mode.decides_world() or coop_mode.leads_here())
end
-- live_player of the world scripts (coop_core_world_news, _mloot, _stash, _trader); coop_mods_core:135 live_client asks the
-- same three questions
function old.live_player()
	return (coop ~= nil and coop.is_active()) and coop_mode.is_player_mirror() and coop.is_live()
end
-- coop_tasks:4141 nick_of (a nick, else "#peer"), coop_arena:1135 (by character id)
function old.nick_of(peer, list)
	for _, p in ipairs(list) do
		if p.id == peer and type(p.nick) == "string" and p.nick ~= "" then return p.nick end
	end
	return "#" .. tostring(peer)
end

local IDS = { "known", "blank", "boom", "missing", "" }
local FALLBACKS = { "fb", nil }

local function run(name)
	print("== " .. name .. ": text")
	local same = true
	for _, id in ipairs(IDS) do
		for i = 1, 2 do
			local fb = FALLBACKS[i]
			same = same and U.tr(id, fb) == old.tr_a(id, fb) and U.tr(id, fb) == old.tr_d(id, fb)
			same = same and U.tr_nonempty(id, fb) == old.tr_c(id, fb)
			if fb ~= nil then same = same and U.trs(id, fb, "x", nil) == old.T(id, fb, "x", nil) end
			same = same and U.trs(id, "fb") == old.T(id, "fb")
		end
		same = same and U.tr(id) == old.tr_g(id)
	end
	check(same, "tr = the copies that keep an empty text, tr_nonempty = those that drop it, trs = coop_ui T")
	check(U.trs("known", "fb", "a", 7) == "Known a and 7", "trs fills %s in order")
	game = nil
	check(U.tr("known", "fb") == "fb" and U.tr("known") == "known" and U.trs("known", "fb") == "fb", "no game: the fallback")
	game = {
		translate_string = function(id)
			if id == "boom" then error("no string table") end
			local s = TEXTS[id]
			if s == nil then return id end
			return s
		end,
	}

	print("== " .. name .. ": data")
	local fs = { "actor_stalker", "stalker", "actor_", "", 7, nil, "actor_actor_x" }
	same = true
	for i = 1, 7 do same = same and U.bare_faction(fs[i]) == old.bare(fs[i]) end
	check(same, "bare_faction = the string normalizer of coop_progress_community")
	local real_graph = game_graph
	same = true
	for _, g in ipairs({ 5, "5" }) do same = same and U.level_of_gvid(g) == old.level_of(g) end
	game_graph = function() error("no graph") end
	same = same and U.level_of_gvid(5) == nil and old.level_of(5) == nil
	game_graph = real_graph
	check(same, "level_of_gvid = coop_bounty's level_of, a raising graph too")
	check(U.MAX_PEER == 16, "MAX_PEER is the last seat 16")

	print("== " .. name .. ": engine")
	same = true
	for _, f in ipairs({ function() return false end, function() return 3, 4 end, function() error("x") end, 5 }) do
		same = same and U.call(f) == old.call(f)
	end
	check(same and U.call(function() return false end) == false, "call = the layers' call (false stays false)")
	same = true
	for _, n in ipairs({ "coop_mode", "coop_no_such_script", 5, "coop_util" }) do same = same and U.module(n) == old.mod(n) end
	check(same and U.module("coop_mode") == facade, "module = coop_mods_core.mod")
	local was = MODE
	MODE = "sp"
	check(U.active() == false, "no session: not active")
	MODE = was
	check(U.active() == true, "a session: active")

	print("== " .. name .. ": session roles")
	-- every answer of the set's layer, a player's machine (the set with is_player_mirror) and a faulting layer; each with
	-- and without a session, in the world and not yet in it
	local real_live = coop.is_live
	local mirror = { decides_world = function() return false end, leads_here = function() return false end,
		is_player_mirror = function() return true end }
	local faulty = { decides_world = function() error("layer fault") end, leads_here = function() error("layer fault") end,
		is_player_mirror = function() error("layer fault") end }
	same = true
	local asked = 0
	for _, overrides in ipairs({ {}, mirror, faulty }) do
		modes.install(facade, name, overrides)
		for _, mode in ipairs({ "host", "client", "sp" }) do
			MODE = mode
			for _, live in ipairs({ true, false }) do
				coop.is_live = function() return live end
				same = same and U.decides_in_session() == old.leads_level() and U.live_mirror() == old.live_player()
				asked = asked + 1
			end
		end
	end
	check(same and asked == 18, "decides_in_session = the world scripts' leads_level, live_mirror = their live_player")
	coop.is_live = real_live
	modes.install(facade, name)
	local decides = { hostplay = true, srv_world = true, srv_map = true, none = false }
	MODE = "host"
	check(U.decides_in_session() == decides[name] and U.live_mirror() == false,
		"a session: the world's decider and a map's leader decide in it, neither is a player's machine")
	MODE = "sp"
	check(U.decides_in_session() == false and U.live_mirror() == false, "no session: nobody decides, whatever the layer answers")
	modes.install(facade, name, mirror)
	MODE = "client"
	check(U.decides_in_session() == false and U.live_mirror() == (name ~= "none"), "a player's machine in the world: a live mirror")
	coop.is_live = function() return false end
	check(U.live_mirror() == false, "a player's machine before it is in the world: not live")
	coop.is_live = real_live
	MODE = "sp"
	check(U.live_mirror() == false, "no session: no live mirror")
	MODE = was
	modes.install(facade, name)

	print("== " .. name .. ": players")
	NOW = NOW + 1
	local calls = 0
	local real_players = coop.players
	coop.players = function()
		calls = calls + 1
		return real_players()
	end
	local a = U.players()
	local b = U.players()
	check(calls == 1 and #a == 2 and a == b, "one coop.players() per frame, handed to every caller as the same table")
	local seal = guard.seal(a)
	for _ = 1, 3 do
		U.player_row(1)
		U.nick(0)
		U.nick_of_character(500)
		for _, p in ipairs(U.players()) do local _ = p.nick end
	end
	local sorted = U.players_by_id()
	local kept_ok, why = seal()
	check(kept_ok, "the readers and players_by_id leave the shared list as it was (" .. tostring(why) .. ")")
	check(sorted ~= a and #sorted == 2 and sorted[1].id == 0 and sorted[2].id == 1 and sorted[1] == a[1] and calls == 1,
		"players_by_id: a private copy of the frame's rows, by peer id")
	table.sort(sorted, function(x, y) return x.id > y.id end)
	check(seal() and U.players()[1].id == 0 and U.players_by_id()[1].id == 0, "sorting the private copy leaves the frame's list alone")
	-- the guard catches a caller that sorts the shared list in place (the mistake players_by_id is for)
	table.sort(a, function(x, y) return x.id > y.id end)
	local caught, what = seal()
	check(not caught and what:find("another row", 1, true), "the guard catches an in-place sort of the shared list")
	table.sort(a, function(x, y) return x.id < y.id end)
	a[1].nick = "changed"
	caught = seal()
	a[1].nick = "hoster"
	a[#a + 1] = { id = 9 }
	local grown = seal()
	a[#a] = nil
	check(not caught and not grown and seal(), "the guard catches a field write and an added row")
	-- the reversed list from the engine comes out sorted
	coop.players = function()
		calls = calls + 1
		local l = real_players()
		l[1], l[2] = l[2], l[1]
		return l
	end
	NOW = NOW + 1
	check(U.players()[1].id == 1 and U.players_by_id()[1].id == 0 and U.players()[1].id == 1,
		"players_by_id sorts a copy; the frame's list keeps the engine's order")
	coop.players = function()
		calls = calls + 1
		return real_players()
	end
	NOW = NOW + 1
	calls = 0
	same = true
	for _, p in ipairs({ 0, 1, 2 }) do same = same and (U.nick(p) or ("#" .. tostring(p))) == old.nick_of(p, real_players()) end
	check(same and calls == 1, "nick(peer) or the caller's fallback = coop_tasks' nick_of, from the frame's rows")
	check(U.nick_of_character(500) == "joiner" and U.nick_of_character(0) == "hoster" and U.nick_of_character(77) == nil and U.nick_of_character("500") == nil,
		"nick_of_character by the character's local id")
	NOW = NOW + 1
	U.players()
	check(calls == 2, "the next frame asks the engine again")
	coop.players = function() error("engine fault") end
	NOW = NOW + 1
	check(#U.players() == 0 and U.player_row(0) == nil and #U.players_by_id() == 0, "an engine fault: no players")
	NOW = NOW + 1
	check(U.players() == U.players(), "no players is one shared empty list too")
	coop.players = real_players
	NOW = NOW + 1

	print("== " .. name .. ": log, start, status")
	LOG = {}
	local log = U.logger("[coop-test]")
	log("n=%d", 5)
	log("bad %d", "x")
	check(LOG[1] == "[coop-test] n=5" and LOG[2] == "[coop-test] bad %d", "logger: the head, a format error prints fmt")
	LOG = {}
	check(U.start_step("coop_test", "install", function(v) assert(v == 3) end, 3) == true and #LOG == 0, "start_step runs f(...)")
	check(U.start_step("coop_test", "events", function() error("boom", 0) end) == false
		and LOG[1] == "! [coop_test] events failed: boom", "start_step: the old line of a fault")
	coop_test_status_a = { print_status = function() printf("a line") end }
	coop_test_status_b = { print_status = function() error("bad", 0) end }
	U.add_status("coop_test_status_a")
	U.add_status("coop_test_status_b")
	U.add_status("coop_test_status_a")
	U.add_status("coop_test_status_missing")
	LOG = {}
	U.print_statuses(function(fmt, ...) printf("[coop] " .. fmt, ...) end)
	check(#LOG == 2 and LOG[1] == "a line" and LOG[2] == "[coop] ! coop_test_status_b.print_status: bad",
		"print_statuses: once per name, in order, a fault logged as coop_main logs it")
end

modes.each(facade, run)
game = real_game
done("UTIL")
