-- The arena's board at Arnie (coop_hud_arena): owner 2026-11-24 (TZ R88, 6.19) "the accept window as at a transition: people
-- walk up, and the one who decided to start holds F to go with those near". The script only shows what coop_arena tells this
-- player (coop_arena.gather_view) and gives the held key back to it (coop_arena.start_pressed): the board of the starter at
-- Arnie with the key, the board of one who goes with him, the reminder of the starter away from Arnie and of an invited player,
-- the compass mark on Arnie; the key as the transition's (1 s, the press or the hold events of G.A.M.M.A., the HUD hidden,
-- let go), never while the crosshair is on Arnie, never under a transition's placard. Real coop_hud_transition (its layout),
-- real ui_coop_transition.xml nodes through the UI fake, real eng and rus strings.
-- Run: tools\test_lua.cmd arena_board
dofile("tests/lua/support/harness_npc.lua")
local HUD = dofile("tests/lua/support/hud_fake.lua")
local modes = dofile("tests/lua/support/modes.lua")

local DIK_F, DIK_G, USE = 33, 34, 7
local ARNIE = 920
local VIEW, PRESSED, HUD_ON, TARGET, TRANS = nil, 0, true, nil, nil
local SOURCES = {}

reset_world()
local M = machine("host", 0, { [0] = 0, [1] = 500, [2] = 501 })
local E = M.env
local ui = HUD.install(E)
E.key_bindings = { kUSE = USE }
E.dik_to_bind = function(dik) return dik == DIK_F and USE or 0 end
E.main_hud_shown = function() return HUD_ON end
E.level.get_target_obj = function() return TARGET end
E.coop_arena = {
	gather_view = function() return VIEW end,
	start_pressed = function() PRESSED = PRESSED + 1 end,
}
E.coop_hud_markers = { add_source = function(name, fn) SOURCES[name] = fn return true end }
E.coop_allies = { color = function(peer) return 10 + peer, 20, 30 end }
E.coop_core_hud = { distance_text = function(peer) return peer == 2 and "31 m" or nil end }
E.coop_core_chat = { system = function() end }
if not E.coop_trust then load_script(M, "coop_trust") end
E.coop_npc_players = load_script(M, "coop_npc_players")
modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
E.coop_mods_core = load_script(M, "coop_mods_core")
local T = load_script(M, "coop_hud_transition")
T.current = function() return TRANS end
local B = load_script(M, "coop_hud_arena")
check(type(B) == "table" and type(B.on_game_start) == "function", "coop_hud_arena loads")
B.on_game_start()

local function frame(ms)
	NOW = NOW + (ms or 0)
	E.SendScriptCallback("actor_on_update")
	local w = B.get_window()
	if w then w:Update() end
	return w
end
-- the key held for `ms` in 50 ms frames; `events`: only its hold events (G.A.M.M.A.: another script took the press)
local function hold(ms, events)
	if not events then E.SendScriptCallback("on_key_press", DIK_F) end
	local t = 0
	repeat
		if events then E.SendScriptCallback("on_key_hold", DIK_F) end
		frame(50)
		t = t + 50
	until t >= ms
end
-- `ms` of 50 ms frames
local function run(ms)
	local t = 0
	repeat
		frame(50)
		t = t + 50
	until t >= ms
end
local function release()
	E.SendScriptCallback("on_key_release", DIK_F)
	frame(50)
end
local function shown(w, field) return w and w[field] and w[field]:IsShown() == true end

local LEAD = { a = "lead", n = 3, w = "p0", s = 0, c = 2, t = 3, near = { 0, 1 }, far = { 2 }, arnie = ARNIE,
	pos = vec(149, 1, 74), dist = 2 }
local WITH = { a = "with", n = 3, w = "p1", s = 1, c = 2, t = 3, near = { 1, 0 }, far = { 2 }, arnie = ARNIE, pos = vec(149, 1, 74), dist = 6 }
local INVITE = { a = "invite", n = 3, w = "p1", s = 1, c = 2, t = 3, near = { 1, 2 }, far = { 0 }, arnie = ARNIE, pos = vec(149, 1, 74), dist = 42 }
local FAR = { a = "lead_far", n = 5, w = "p0", s = 0, c = 1, t = 2, near = { 1 }, far = { 0 }, arnie = ARNIE, pos = vec(149, 1, 74), dist = 30 }

print("== nothing to show: no board, no key")
do
	local w = frame(16)
	check(w ~= nil, "the overlay is on the HUD in a session")
	check(not shown(w, "g_board") and not shown(w, "g_remind"), "no view: nothing shown")
	hold(1500)
	release()
	check(PRESSED == 0, "the key does nothing without a board")
end

print("== the starter at Arnie: the board with the key")
do
	VIEW = LEAD
	local w = frame(16)
	frame(200)
	check(B.kind_of(LEAD) == "board" and B.hint_of(LEAD) == "start", "the starter at Arnie: a board with the key")
	check(shown(w, "g_board") and not shown(w, "g_remind"), "the board is shown")
	check(B.head_text(LEAD) == "ARENA" and B.title_text(LEAD):find("3", 1, true) ~= nil and B.count_text(LEAD) == "2 / 3",
		"the head, the fight and the count near / on the map (" .. B.title_text(LEAD) .. ", " .. B.count_text(LEAD) .. ")")
	local rows = B.row_texts(LEAD)
	check(#rows == 3 and rows[1].peer == 0 and rows[1].nick == "p0" and rows[1].ready and rows[2].peer == 1 and rows[2].ready
		and rows[3].peer == 2 and not rows[3].ready and rows[3].text == "31 m",
		"the rows: the two near Arnie first, the far one with the team panel's metres")
	check(rows[1].rgb[1] == 10 and rows[2].rgb[1] == 11, "each nick in his palette colour")
	check(B.hint_text("start"):find("$$ACTION_USE$$", 1, true) == nil and #B.hint_text("start") > 0, "the hint names the key (" .. B.hint_text("start") .. ")")
end

print("== the key: 1 s held starts it, once; less, or let go, does not")
do
	VIEW = LEAD
	hold(900)
	release()
	check(PRESSED == 0, "900 ms and let go: nothing")
	hold(1100)
	check(PRESSED == 1, "1 s held: coop_arena.start_pressed, once")
	hold(2000)
	check(PRESSED == 1, "held on: still once")
	release()
	PRESSED = 0
	E.SendScriptCallback("on_key_press", DIK_G)
	run(1200)
	check(PRESSED == 0, "another key does nothing")
end

print("== G.A.M.M.A.: only the hold events reach this script; their end is the release")
do
	VIEW = LEAD
	PRESSED = 0
	hold(1100, true)
	check(PRESSED == 1, "the hold events alone: it starts after 1 s")
	run(400) -- no more events: let go
	PRESSED = 0
	hold(600, true)
	run(800)
	check(PRESSED == 0, "the hold events stop after 600 ms (its release went to another script): nothing")
	hold(600, true)
	run(400)
	hold(600, true)
	check(PRESSED == 0, "two holds of 600 ms with a gap: nothing")
	run(400)
	hold(1100, true)
	check(PRESSED == 1, "the next full hold after a release that went elsewhere starts it again")
	run(400)
end

print("== the HUD hidden (the dialog with Arnie, the inventory) ends the hold")
do
	VIEW = LEAD
	PRESSED = 0
	E.SendScriptCallback("on_key_press", DIK_F)
	run(300)
	HUD_ON = false
	run(400)
	HUD_ON = true
	run(800)
	release()
	check(PRESSED == 0, "hidden 400 ms in the middle: no start")
	E.SendScriptCallback("on_key_press", DIK_F)
	run(300)
	HUD_ON = false
	run(100)
	HUD_ON = true
	run(800)
	check(PRESSED == 1, "a flash of 100 ms (a window popping up) does not end it")
	release()
end

print("== the crosshair on Arnie: the key talks to him, no hold")
do
	VIEW = LEAD
	PRESSED = 0
	TARGET = make_obj(ARNIE, 149, 1, 74, { _name = "bar_arena_manager" })
	hold(1500)
	release()
	check(PRESSED == 0, "looking at Arnie: no start")
	TARGET = make_obj(4321, 0, 0, 0, {})
	hold(1100)
	release()
	check(PRESSED == 1, "looking at something else: it starts")
	TARGET = nil
end

print("== the board changes under the key: the hold ends")
do
	VIEW = LEAD
	PRESSED = 0
	E.SendScriptCallback("on_key_press", DIK_F)
	run(500)
	VIEW = WITH
	run(700)
	VIEW = LEAD
	run(600)
	release()
	check(PRESSED == 0, "the key went to another starter in the middle: no start")
end

print("== one who goes with the starter: the board, no key")
do
	VIEW = WITH
	PRESSED = 0
	local w = frame(300)
	check(B.kind_of(WITH) == "board" and B.hint_of(WITH) == nil, "a board without a key")
	check(B.status_text(WITH):find("p1", 1, true) ~= nil, "it says with whom he goes (" .. B.status_text(WITH) .. ")")
	check(shown(w, "g_board"), "shown")
	hold(1500)
	release()
	check(PRESSED == 0, "his key does nothing")
end

print("== invited, away from Arnie: the reminder and the compass mark on Arnie")
do
	VIEW = INVITE
	local w = frame(300)
	local r = B.reminder(INVITE)
	check(B.kind_of(INVITE) == "remind" and r and r.nick == "p1" and r.text:find("42", 1, true) and r.text:find("3", 1, true),
		"the reminder: who waits, the fight, my metres to Arnie (" .. tostring(r and r.text) .. ")")
	check(shown(w, "g_remind") and not shown(w, "g_board"), "the reminder is shown, not the board")
	local src = SOURCES.arena
	local marks = src and src() or {}
	check(#marks == 1 and marks[1].pos.x == 149 and marks[1].label == "p1" and marks[1].color[1] == 11, "the compass: a mark on Arnie with his nick")
	VIEW = WITH
	marks = src and src() or {}
	check(#marks == 0, "at Arnie: no mark")
end

print("== the starter away from Arnie: come back, no key")
do
	VIEW = FAR
	PRESSED = 0
	local r = B.reminder(FAR)
	check(B.kind_of(FAR) == "remind" and B.hint_of(FAR) == nil and r and r.text:find("30", 1, true), "come back to Arnie . 30 m")
	hold(1500)
	release()
	check(PRESSED == 0, "no key away from Arnie")
end

print("== a transition's placard wins: no arena board, the key is the transition's")
do
	VIEW = LEAD
	PRESSED = 0
	TRANS = { state = "waiting", kind = "exit", me = { in_zone = true } }
	local w = frame(300)
	check(not shown(w, "g_board") and not shown(w, "g_remind"), "the arena's board is off")
	hold(1500)
	release()
	check(PRESSED == 0, "the key does not start the arena")
	TRANS = nil
end

print("== the strings: eng and rus")
do
	local function ids(path)
		local fh = io.open(path, "rb")
		local s = fh and fh:read("*a") or ""
		if fh then fh:close() end
		local t = {}
		for id, text in s:gmatch('<string id="([%w_]+)">%s*<text>(.-)</text>') do t[id] = text end
		return t, s
	end
	local eng = ids("gamedata/configs/text/eng/st_coop_arena.xml")
	local rus, raw = ids("gamedata/configs/text/rus/st_coop_arena.xml")
	local fh = io.open("gamedata/scripts/coop_hud_arena.script", "rb")
	local src = fh and fh:read("*a") or ""
	if fh then fh:close() end
	local missing, n = {}, 0
	for id in src:gmatch('"(st_coop_arena_[%w_]+)"') do
		n = n + 1
		if not (eng[id] and rus[id]) then missing[#missing + 1] = id end
	end
	check(n >= 8 and #missing == 0, "every string of the board is in eng and rus (" .. n .. "; missing " .. table.concat(missing, ", ") .. ")")
	check(eng.st_coop_arena_hint_start and eng.st_coop_arena_hint_start:find("$$ACTION_USE$$", 1, true) ~= nil,
		"the hint names the use key the game's way ($$ACTION_USE$$)")
	check(raw:find('encoding="windows-1251"', 1, true) ~= nil, "rus is windows-1251")
end

print("== outside a session: no overlay")
do
	M.set_session(false)
	frame(100)
	check(B.get_window() == nil, "the overlay is off")
	M.set_session(true)
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
