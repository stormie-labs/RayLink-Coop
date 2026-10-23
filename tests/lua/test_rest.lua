-- Anomaly Coop F3 task 14 stub test: the Lua side of the shared sleep (scripts\coop_rest.script: the wrappers of the stock
-- ui_sleep_dialog, the doze window of configs\ui\ui_coop_rest.xml, the sleep effects without a time skip, the prompts), the
-- party panel line of scripts\coop_allies.script and the string tables configs\text\{eng,rus}\st_coop_rest.xml.
-- Not shipped. Run: tools\test_lua.cmd rest
--
-- The engine is a stand-in: coop.rest (lie_down / get_up / state_of / hours_of / waiting_for / block / set_world_block) is a
-- recorder whose answers the test gives by hand, the callbacks coop_rest_changed / coop_rest_sleep / coop_rest_refused are
-- fired by hand, ui_sleep_dialog is a stub with the shape of the stock module (UISleep with TestAndShow / OnButtonSleep,
-- sleep_forced, sleep_bag), level.* effectors and the actor's infos are recorders, the windows are menu_stubs.lua's.
-- Roles: "host", "client" and "sp" (no session); the script asks coop.is_active() at every call.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/menu_stubs.lua") -- UI stand-ins (class, CUIScriptWnd, CScriptXmlInit, click)

-- menu_stubs.lua prints every log line; keep them quiet (VERBOSE=1 shows them)
function printf(fmt, ...)
	local ok, line = pcall(string.format, fmt, ...)
	line = ok and line or tostring(fmt)
	LOG[#LOG + 1] = line
	if os.getenv("VERBOSE") then print("    log: " .. line) end
end

local ENG = "gamedata/configs/text/eng/st_coop_rest.xml"
local RUS = "gamedata/configs/text/rus/st_coop_rest.xml"
local UI_XML = "gamedata/configs/ui/ui_coop_rest.xml"

-- ------------------------------------------------------------------ files
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local function strings_of(path)
	local t = {}
	local src = read(path)
	if src then
		for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do t[id] = text end
	end
	return t
end

local STR = strings_of(ENG)
game.translate_string = function(id) return STR[id] or id end
XML_FILES["ui_coop_rest.xml"] = xml_paths(UI_XML)

-- st_coop_rest_x with %s / %d filled in order, the way the script does it
local function fmt(s, ...)
	local args, i = { ... }, 0
	return (tostring(s):gsub("%%[sd]", function()
		i = i + 1
		return tostring(args[i] == nil and "" or args[i])
	end))
end

-- ------------------------------------------------------------------ callbacks: what a script registers is kept by name
HANDLERS = {}
ADDED = {}
function RegisterScriptCallback(n, f)
	HANDLERS[n] = HANDLERS[n] or {}
	for _, g in ipairs(HANDLERS[n]) do if g == f then return end end -- set semantics, like axr_main.callback_set
	table.insert(HANDLERS[n], f)
end
function UnregisterScriptCallback(n, f)
	local list = HANDLERS[n]
	if not list then return end
	for i = #list, 1, -1 do if list[i] == f then table.remove(list, i) end end
end
function AddScriptCallback(n) ADDED[n] = true end
local function fire(n, ...)
	local list = {}
	for i, f in ipairs(HANDLERS[n] or {}) do list[i] = f end
	for _, f in ipairs(list) do f(...) end
end
SendScriptCallback = fire
local function registered(n) return #(HANDLERS[n] or {}) end

-- ------------------------------------------------------------------ engine stand-ins
MSGS, CAMS, PPES, EXEC, EFFECTS, CGT, GUIREG = {}, {}, {}, {}, {}, 0, {}
actor_menu.set_msg = function(_, text) MSGS[#MSGS + 1] = text end

level.add_cam_effector = function(anm, id, loop, cb) CAMS[#CAMS + 1] = { anm = anm, id = id, loop = loop, cb = cb } end
level.add_pp_effector = function(name, id, loop) PPES[#PPES + 1] = name end
level.change_game_time = function(d, h, m) CGT = CGT + 1 end
function exec_console_cmd(c) EXEC[#EXEC + 1] = c end
function get_console_cmd(typ, name) return name == "snd_volume_music" and "0.6" or "0.8" end
function save_var() end
xr_effects = {
	disable_ui = function() EFFECTS[#EFFECTS + 1] = "disable_ui" end,
	enable_ui = function() EFFECTS[#EFFECTS + 1] = "enable_ui" end,
}
function Register_UI(name) GUIREG[name] = true end
function Unregister_UI(name) GUIREG[name] = nil end
EVENTS = {}
function GetEvent(k) return EVENTS[k] end
item_tent = { get_nearby_tent = function() return false end }
USE_DIK = 99
key_bindings = { kUSE = 1000 }
function dik_to_bind(dik) return dik == USE_DIK and 1000 or 0 end

-- the emission managers: is_started() is all the script asks
SURGE_ON, PSI_ON = false, false
surge_manager = { is_started = function() return SURGE_ON end }
psi_storm_manager = { is_started = function() return PSI_ON end }

-- the actor's infos, power and slots
INFOS, SLOTS = {}, {}
local function dress_actor(a)
	a.bleeding, a.radiation, a.power = 0, 0, 0.3
	function a:give_info_portion(id) INFOS[id] = true; return true end
	function a:disable_info_portion(id) INFOS[id] = nil; return true end
	function a:has_info(id) return INFOS[id] == true end
	function a:activate_slot(n) SLOTS[#SLOTS + 1] = n end
	return a
end

-- coop.players: the host (me or not) and "Wolf", whose character is local object 7
local function wolf_players()
	coop.players = function()
		return {
			{ id = 0, nick = "hoster", is_self = MODE == "host", avatar_id = MODE == "host" and 0 or 500, rtt = 0 },
			{ id = 2, nick = "Wolf", is_self = false, avatar_id = 7, rtt = 30 },
			{ id = 1, nick = "joiner", is_self = MODE == "client", avatar_id = MODE == "client" and 0 or 500, rtt = 12 },
		}
	end
end

-- coop.checkpoint: only the claims matter (the fold button)
CLAIMS = {}
coop.checkpoint = {
	get = function() return nil end,
	claim_tent = function(x, y, z, what) CLAIMS[#CLAIMS + 1] = { x = x, y = y, z = z, what = what }; return true end,
	tent_owner = function() return nil end,
}

-- coop.rest as the engine registers it (coop_rest.cpp): every call is recorded, the answers are the test's
REST = {}
local function install_rest_api()
	REST = { calls = {}, lie = {}, ups = 0, worlds = {}, states = {}, hours = {}, waiting = {}, block = "none", lie_ok = true }
	coop.rest = {
		lie_down = function(hours, forced)
			REST.lie[#REST.lie + 1] = { hours = hours, forced = forced }
			REST.calls[#REST.calls + 1] = "lie_down"
			return REST.lie_ok
		end,
		get_up = function() REST.ups = REST.ups + 1; REST.calls[#REST.calls + 1] = "get_up"; return true end,
		state_of = function(id) return REST.states[id] or "awake" end,
		hours_of = function(id) return REST.hours[id] or 0 end,
		waiting_for = function() return REST.waiting end,
		block = function() return REST.block end,
		set_world_block = function(reason) REST.worlds[#REST.worlds + 1] = reason; return true end,
	}
end

-- the stock ui_sleep_dialog (stock Anomaly ui_sleep_dialog.script:95-133, 153-200, 272-290) in the shape the wrappers see:
-- the module table with UISleep, sleep_forced, sleep_bag, sleep; the shelter check, the stock dialog and the stock sleep
STOCK = {}
local function stock_sleep()
	STOCK = { sleeps = 0, shows = 0, forced = {}, bags = {} }
	local cls = {}
	cls.__index = cls
	function cls:IsShown() return self.shown == true end
	function cls:ShowDialog() self.shown = true end
	function cls:HideDialog() self.shown = false end
	function cls:Initialize() end
	function cls:TestAndShow(force)
		if force ~= true then
			if db.actor.bleeding > 0 or db.actor.radiation > 0 then
				actor_menu.set_msg(1, game.translate_string("st_sleep_bleeding"), 4)
				db.actor:disable_info_portion("sleep_active")
				return
			end
			local hide = GetEvent("current_safe_cover") and true or false
			if not hide then hide = item_tent.get_nearby_tent(1.5) end
			if not hide then
				actor_menu.set_msg(1, game.translate_string("st_cant_sleep_find_shelter_mlr"), 4)
				db.actor:disable_info_portion("sleep_active")
				return
			end
		end
		STOCK.shows = STOCK.shows + 1
		self:Initialize()
		self:ShowDialog(true)
		Register_UI("UISleep", "ui_sleep_dialog")
	end
	function cls:OnButtonSleep()
		STOCK.sleeps = STOCK.sleeps + 1
		if self:IsShown() then
			self:HideDialog()
			Unregister_UI("UISleep")
		end
		level.add_cam_effector("camera_effects\\sleep.anm", 10, false, "ui_sleep_dialog.dream_callback")
		level.change_game_time(0, self.time_track:GetIValue(), 0) -- dream_callback
		exec_console_cmd("save x - sleep") -- dream_callback2
	end
	local m = { UISleep = cls }
	function m.sleep_forced(hours) STOCK.forced[#STOCK.forced + 1] = hours end
	function m.sleep_bag(id, sec)
		STOCK.bags[#STOCK.bags + 1] = id
		local ui = setmetatable({ time_track = { GetIValue = function() return 1 end } }, cls)
		m.GUI = ui
		ui:TestAndShow() -- stock: GUI:TestAndShow()
	end
	function m.sleep(force)
		local ui = setmetatable({ time_track = { GetIValue = function() return 1 end } }, cls)
		m.GUI = ui
		ui:TestAndShow(force)
	end
	ui_sleep_dialog = m
	return m
end

-- a stock sleep dialog with the slider at `hours`
local function stock_ui(hours)
	local ui = setmetatable({ time_track = { GetIValue = function() return hours end } }, ui_sleep_dialog.UISleep)
	ui_sleep_dialog.GUI = ui
	return ui
end

local function rest() return rawget(_G, "coop_rest") end
local function win() return rest().window() end

-- a clean world, the script loaded the way axr_main loads it (load, then on_game_start)
local function fresh(mode, opts)
	opts = opts or {}
	MODE = mode
	SELF = mode == "client" and 1 or 0
	SE, OBJ, CREATED, RELEASED, TIMEEV = {}, {}, {}, {}, {}
	NOW = NOW + 1000000
	LOG = {}
	MSGS, CAMS, PPES, EXEC, EFFECTS, CGT, GUIREG, CLAIMS, SLOTS = {}, {}, {}, {}, {}, 0, {}, {}, {}
	INFOS, EVENTS, SURGE_ON, PSI_ON = {}, {}, false, false
	MISSING_PATHS = {}
	HANDLERS, ADDED = {}, {}
	wolf_players()
	install_rest_api()
	if opts.no_api then coop.rest = nil end
	dress_actor(make_actor(vec3(0, 0, 0)))
	stock_sleep()
	RATES = {}
	actor_status_sleep = { set_rest_per_hour = function(r) RATES[#RATES + 1] = r end }
	coop_rest, coop_checkpoints, coop_allies = nil, nil, nil
	load_script("coop_rest")
	coop_rest.on_game_start()
end

local function case(name, f)
	print("== " .. name)
	local ok, err = pcall(f)
	if not ok then
		FAILS = FAILS + 1
		print("  FAIL " .. name .. " crashed: " .. tostring(err))
	end
end

-- time passes: engine updates every `step` ms
local function advance(ms, step)
	step = step or 500
	local to = NOW + ms
	while NOW < to do
		NOW = math.min(NOW + step, to)
		fire("actor_on_update")
	end
end

local function count_of(list, pred)
	local n = 0
	for _, v in ipairs(list) do
		if pred(v) then n = n + 1 end
	end
	return n
end

local function count_eq(list, value) return count_of(list, function(v) return v == value end) end

-- the engine says: my own rest is `state` now (the mirror, then the callback)
local function engine_says(id, state, hours)
	REST.states[id] = state
	REST.hours[id] = hours or 0
	fire("coop_rest_changed", id, state, hours or 0)
end

local function last(list) return list[#list] end

-- ------------------------------------------------------------------ the button asks the engine, nothing else
case("sleep_button_asks_engine", function()
	fresh("host")
	local ui = stock_ui(6)
	ui.shown = true
	ui:OnButtonSleep()
	check(#REST.lie == 1 and REST.lie[1].hours == 6 and REST.lie[1].forced == false, "in a session the button calls coop.rest.lie_down(6, false)")
	check(STOCK.sleeps == 0, "the stock sleep did not run")
	check(CGT == 0, "level.change_game_time was not called")
	check(count_of(EXEC, function(c) return c:find("^save") ~= nil end) == 0, "no save was made")
	check(#CAMS == 0 and #EFFECTS == 0, "no dream yet: no camera effector, the UI stays")
	check(ui.shown == false, "the stock slider dialog is closed")
	local w = win()
	check(w ~= nil and w:IsShown(), "the doze window is open")
	check(INFOS.actor_is_sleeping == true, "actor_is_sleeping is given: the body dozes")
	check(GUIREG.UICoopDoze == true and GUIREG.UISleep == nil, "the doze window is a registered UI, the stock one is not")
	check(#MISSING_PATHS == 0, "every element the window asks for is in ui_coop_rest.xml (" .. table.concat(MISSING_PATHS, ",") .. ")")
	-- hours are the slider's: 24 and 1 pass, a rest the engine does not take is not a doze
	fresh("host")
	REST.lie_ok = false
	stock_ui(3):OnButtonSleep()
	check(win() == nil, "lie_down said false: no window")
	check(last(MSGS) == STR.st_coop_rest_refused, "and a tip: " .. tostring(last(MSGS)))
	check(not log_has("failed"), "no error in the log")
end)

case("forced_sleep_dozes", function()
	fresh("host")
	ui_sleep_dialog.sleep_forced(4)
	check(#REST.lie == 1 and REST.lie[1].hours == 4 and REST.lie[1].forced == true, "sleep_forced(4) -> lie_down(4, true)")
	check(#STOCK.forced == 0, "the stock forced sleep did not run")
	check(win() ~= nil and win():IsShown(), "a faint dozes in the window too")
	fresh("host")
	ui_sleep_dialog.sleep_forced(nil)
	check(#REST.lie == 1 and REST.lie[1].forced == true and REST.lie[1].hours >= 3 and REST.lie[1].hours <= 9,
		"without hours the stock draws 3..9 (" .. tostring(REST.lie[1] and REST.lie[1].hours) .. ")")
	-- the sleep that follows is the stock faint: surge animations, no weapon hiding
	fire("coop_rest_sleep", 4)
	check(CAMS[1] and CAMS[1].anm:find("surge_02", 1, true) ~= nil, "forced: the faint animation (surge_02.anm)")
	check(#SLOTS == 0, "forced: the weapon is not put away")
	coop_rest.dream_mid()
	check(CAMS[2] and CAMS[2].anm:find("surge_01", 1, true) ~= nil and CAMS[2].cb == "coop_rest.dream_end", "forced: surge_01.anm to wake up, callback dream_end")
	coop_rest.dream_end()
	-- a rest already on does not start another
	fresh("host")
	ui_sleep_dialog.sleep_forced(5)
	ui_sleep_dialog.sleep_forced(6)
	check(#REST.lie == 1, "a second faint while the first dozes is not asked")
end)

case("shelter_check_skipped_in_session", function()
	fresh("host")
	local ui = stock_ui(6)
	ui:TestAndShow()
	check(ui:IsShown() and STOCK.shows == 1, "in a session, away from shelter and tents, the dialog opens")
	check(count_of(MSGS, function(m) return m == "st_cant_sleep_find_shelter_mlr" end) == 0, "and no 'find a shelter' tip")
	-- the checks that stay
	fresh("host")
	db.actor.bleeding = 0.5
	ui = stock_ui(6)
	ui:TestAndShow()
	check(not ui:IsShown() and last(MSGS) == "st_sleep_bleeding", "bleeding still forbids sleep")
	check(not INFOS.sleep_active, "and sleep_active is off")
	fresh("host")
	db.actor.radiation = 1
	INFOS.sleep_active = true
	ui = stock_ui(6)
	ui:TestAndShow()
	check(not ui:IsShown() and last(MSGS) ~= nil, "radiation still forbids sleep")
	check(not INFOS.sleep_active, "sleep_active (given by sleep_in_zone before the dialog) is taken off")
	-- a caller that forces the dialog (the debug sleep) is left alone
	fresh("host")
	db.actor.bleeding = 1
	ui = stock_ui(6)
	ui:TestAndShow(true)
	check(ui:IsShown(), "TestAndShow(true) is the stock's: no check at all")
	-- sleep_bag opens the dialog through TestAndShow, away from shelter too
	fresh("host")
	spawn("ph_sleepbag", vec3(1, 0, 0), nil, { id = 777 })
	ui_sleep_dialog.sleep_bag(777, "itm_sleepbag")
	check(STOCK.bags[1] == 777 and ui_sleep_dialog.GUI:IsShown(), "sleep_bag (stock call) opens the dialog without a shelter")
	-- while one rests, nobody opens a second dialog
	fresh("host")
	stock_ui(6):OnButtonSleep()
	local second = stock_ui(2)
	second:TestAndShow()
	check(not second:IsShown(), "a doze is on: the sleep dialog does not open again")
end)

case("outside_session_stock", function()
	fresh("sp")
	local ui = stock_ui(4)
	ui:TestAndShow()
	check(not ui:IsShown() and last(MSGS) == "st_cant_sleep_find_shelter_mlr", "no session: the stock shelter check runs")
	ui.shown = true
	ui:OnButtonSleep()
	check(STOCK.sleeps == 1 and CGT == 1, "no session: the stock sleep runs and changes the game time")
	check(#REST.lie == 0 and win() == nil, "no session: coop.rest is not asked, no window")
	ui_sleep_dialog.sleep_forced(3)
	check(#STOCK.forced == 1 and STOCK.forced[1] == 3 and #REST.lie == 0, "no session: the stock sleep_forced")
	-- an engine without coop.rest is not a session of ours
	fresh("host", { no_api = true })
	ui = stock_ui(4)
	ui:OnButtonSleep()
	check(STOCK.sleeps == 1 and CGT == 1 and win() == nil, "an engine without coop.rest: the stock sleep")
	-- running the installer twice puts the wrappers on once
	fresh("host")
	coop_rest.on_game_start()
	stock_ui(5):OnButtonSleep()
	check(#REST.lie == 1, "on_game_start twice: one lie_down per click (" .. #REST.lie .. ")")
	check(registered("coop_rest_changed") == 1 and registered("coop_rest_sleep") == 1 and registered("coop_rest_refused") == 1
		and registered("actor_on_update") == 1, "and the callbacks are registered once")
	check(ADDED.coop_rest_changed and ADDED.coop_rest_sleep and ADDED.coop_rest_refused, "the engine callbacks are declared")
end)

-- ------------------------------------------------------------------ the sleep itself: the stock effects, no time skip
case("sleep_event_runs_stock_effects", function()
	fresh("host")
	local slept = {}
	RegisterScriptCallback("actor_on_sleep", function(h) slept[#slept + 1] = h end)
	stock_ui(5):OnButtonSleep()
	engine_says(0, "resting", 5)
	engine_says(0, "sleeping", 5)
	fire("coop_rest_sleep", 5)
	check(win() == nil or not win():IsShown(), "the doze window gives way to the dream")
	check(count_eq(EFFECTS, "disable_ui") == 1, "the UI is disabled")
	check(CAMS[1] and CAMS[1].anm:find("sleep.anm", 1, true) ~= nil and CAMS[1].id == 10 and CAMS[1].cb == "coop_rest.dream_mid",
		"the sleep camera effector, its callback is ours (coop_rest.dream_mid)")
	check(count_eq(PPES, "sleep_fade.ppe") == 1 and count_eq(PPES, "surge_fade.ppe") == 1, "the stock fade effectors")
	check(count_eq(EXEC, "snd_volume_music 0") >= 1 and count_eq(EXEC, "snd_volume_eff 0") >= 1, "the sound is muted")
	check(SLOTS[1] == 0, "the weapon is put away")
	check(INFOS.actor_is_sleeping == true, "actor_is_sleeping stays through the dream")
	check(#slept == 0 and CGT == 0, "nothing has happened to the clock or the sleepiness yet")
	-- the first camera effector ends: the effects, the waking-up animation
	coop_rest.dream_mid()
	check(#slept == 1 and slept[1] == 5, "actor_on_sleep went out with 5 hours")
	check(db.actor.power == 1, "the stamina is full")
	check(#RATES == 0, "no Immersive Sleep (no get_immersive_sleep_hours): the rest per hour is left alone")
	check(CAMS[2] and CAMS[2].cb == "coop_rest.dream_end", "the second effector ends in dream_end")
	check(INFOS.actor_is_sleeping == true, "still dozing until the end")
	-- the end
	coop_rest.dream_end()
	check(#slept == 1, "actor_on_sleep went out once")
	check(CGT == 0, "level.change_game_time was never called")
	check(count_of(EXEC, function(c) return c:find("^save") ~= nil end) == 0, "no save was made")
	check(count_eq(EFFECTS, "enable_ui") == 1, "the UI is enabled again")
	check(count_eq(EXEC, "snd_volume_music 0.6") == 1 and count_eq(EXEC, "snd_volume_eff 0.8") == 1, "the sound is back")
	check(win() == nil or not win():IsShown(), "the window is closed")
	check(not INFOS.actor_is_sleeping and not INFOS.sleep_active and not INFOS.tutorial_sleep, "the infos are taken off")
	check(rawget(_G, "mus_vol") == 0 and rawget(_G, "amb_vol") == 0, "mus_vol / amb_vol are reset like the stock does")
	check(last(MSGS) == fmt(STR.st_coop_rest_woke, 5), "and the player is told: " .. tostring(last(MSGS)))
	coop_rest.dream_end()
	check(#slept == 1 and count_eq(EFFECTS, "enable_ui") == 1, "a second dream_end changes nothing")
	-- only the end callback arrives (the first one was lost): the effects still happen, once
	fresh("host")
	slept = {}
	RegisterScriptCallback("actor_on_sleep", function(h) slept[#slept + 1] = h end)
	stock_ui(5):OnButtonSleep()
	fire("coop_rest_sleep", 5)
	coop_rest.dream_end()
	check(#slept == 1 and slept[1] == 5 and db.actor.power == 1 and not INFOS.actor_is_sleeping,
		"dream_end alone: actor_on_sleep(5), power 1, infos off")
	check(CGT == 0, "and still no clock call")
	-- a dream whose callbacks never come ends by itself
	fresh("host")
	stock_ui(5):OnButtonSleep()
	fire("coop_rest_sleep", 5)
	advance(30000, 1000)
	check(count_eq(EFFECTS, "enable_ui") == 0, "30 s: the effects still run")
	advance(40000, 1000)
	check(count_eq(EFFECTS, "enable_ui") == 1 and not INFOS.actor_is_sleeping, "70 s: lost callbacks do not keep the UI disabled")
	-- bad hours are not a sleep
	fresh("host")
	fire("coop_rest_sleep", "x")
	fire("coop_rest_sleep", nil)
	check(#CAMS == 0 and count_eq(EFFECTS, "disable_ui") == 0, "garbage hours: no dream")
	fresh("host")
	fire("coop_rest_sleep", 99)
	coop_rest.dream_end()
	check(last(MSGS) == fmt(STR.st_coop_rest_woke, 24), "hours are cut to 24")
	-- the sleep of a client
	fresh("client")
	stock_ui(2):OnButtonSleep()
	fire("coop_rest_sleep", 2)
	coop_rest.dream_end()
	check(CGT == 0 and count_eq(EFFECTS, "enable_ui") == 1, "a client sleeps the same way, without a clock call")
end)

-- ------------------------------------------------------------------ the doze window
case("doze_clears_sleep_active", function()
	fresh("host")
	INFOS.sleep_active = true -- sleep_in_zone gave it before the dialog
	local ui = stock_ui(3)
	ui:TestAndShow()
	check(not INFOS.sleep_active, "an open sleep dialog does not freeze the host's time events (sleep_active off)")
	INFOS.sleep_active = true
	ui:OnButtonSleep()
	check(not INFOS.sleep_active, "the doze window opens with sleep_active off")
	check(INFOS.actor_is_sleeping == true, "and actor_is_sleeping on")
end)

case("doze_window_texts", function()
	fresh("host")
	REST.waiting = { "Wolf", "joiner" }
	stock_ui(7):OnButtonSleep()
	local w = win()
	check(w.hours_txt and w.hours_txt.text == fmt(STR.st_coop_rest_hours, 7), "the hours: " .. tostring(w.hours_txt and w.hours_txt.text))
	check(w.waiting.text == fmt(STR.st_coop_rest_waiting, "Wolf, joiner"), "who is waited for: " .. tostring(w.waiting.text))
	REST.waiting = { "joiner" }
	advance(1000, 500)
	check(w.waiting.text == fmt(STR.st_coop_rest_waiting, "joiner"), "the list is read again every second")
	REST.waiting = {}
	advance(1000, 500)
	check(w.waiting.text == STR.st_coop_rest_all_ready, "nobody is waited for: the sleep begins")
	check(w.reason.text == "", "no block: no reason")
	REST.block = "combat"
	advance(1000, 500)
	check(w.reason.text == STR.st_coop_rest_block_combat, "block combat: " .. tostring(w.reason.text))
	REST.block = "world"
	advance(1000, 500)
	check(w.reason.text == STR.st_coop_rest_block_world, "block world: " .. tostring(w.reason.text))
	REST.block = "dead"
	advance(1000, 500)
	check(w.reason.text == STR.st_coop_rest_block_dead, "block dead: " .. tostring(w.reason.text))
	REST.block = "not_all"
	advance(1000, 500)
	check(w.reason.text == "", "not_all is the waiting line's business")
	REST.block = "something_new"
	advance(1000, 500)
	check(w.reason.text == "" and not log_has("failed"), "a block the script does not know is no reason and no error")
	-- the window's own Update drives the same tick
	fresh("host")
	REST.waiting = { "Wolf" }
	stock_ui(2):OnButtonSleep()
	w = win()
	REST.waiting = { "joiner" }
	NOW = NOW + 1000
	w:Update()
	check(w.waiting.text == fmt(STR.st_coop_rest_waiting, "joiner"), "Update() of the window refreshes the line too")
end)

case("doze_closes_on_awake", function()
	fresh("host")
	stock_ui(6):OnButtonSleep()
	local w = win()
	-- the engine has not answered yet: a state read of 'awake' is not the end of the rest
	advance(3000, 1000)
	check(w:IsShown(), "3 s without an answer: the window waits (the client's own pacing and the round trip)")
	engine_says(0, "resting", 6)
	advance(2000, 1000)
	check(w:IsShown() and INFOS.actor_is_sleeping == true, "resting: the window stays")
	REST.states[0] = "awake" -- the callback was lost; the poll is what closes the window
	advance(1000, 500)
	check(not w:IsShown() and win() == nil, "state_of(0) is 'awake' again: the window closes")
	check(not INFOS.actor_is_sleeping and GUIREG.UICoopDoze == nil, "and the info and the registration go with it")
	check(#MSGS == 0, "no tip: the player got up or the group woke")
	-- by the callback, without waiting for a poll
	fresh("host")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	engine_says(0, "awake", 0)
	check(win() == nil, "coop_rest_changed(0, 'awake') closes it at once")
	-- the engine never answers: the window does not stay for ever
	fresh("host")
	stock_ui(6):OnButtonSleep()
	advance(5500, 500)
	check(win() ~= nil, "5.5 s with no answer: still waiting")
	advance(1500, 500)
	check(win() == nil, "7 s with no answer: closed")
	check(last(MSGS) == STR.st_coop_rest_refused_lost, "with a word to the player: " .. tostring(last(MSGS)))
	check(not INFOS.actor_is_sleeping, "and the body is awake")
	-- T14 review I-2: a lie-down that reaches the host late must not leave the player resting unseen
	check(REST.ups == 1, "the late lie-down is taken back: coop.rest.get_up() (" .. REST.ups .. ")")
	-- the session ends (state_of answers 'awake' outside a session, no callback comes)
	fresh("host")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	MODE = "sp"
	advance(1000, 500)
	check(win() == nil and not INFOS.actor_is_sleeping, "the session ended: the window closes")
	-- sleeping: the window waits for the dream
	fresh("host")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	engine_says(0, "sleeping", 6)
	advance(3000, 500)
	check(win() ~= nil and win():IsShown(), "'sleeping' is not the end: the window stays until coop_rest_sleep")
	fire("coop_rest_sleep", 6)
	check(win() == nil and CAMS[1] ~= nil, "coop_rest_sleep: the window gives way to the dream")
	engine_says(0, "awake", 0) -- 12 s after the start the engine says awake while the dream may still run
	advance(3000, 500)
	check(count_eq(EFFECTS, "enable_ui") == 0 and INFOS.actor_is_sleeping == true,
		"'awake' during the dream does not cut it: the effects end on dream_end")
	coop_rest.dream_end()
	check(count_eq(EFFECTS, "enable_ui") == 1 and not INFOS.actor_is_sleeping, "the dream ends on dream_end")
end)

case("doze_get_up", function()
	fresh("host")
	stock_ui(6):OnButtonSleep()
	local w = win()
	engine_says(0, "resting", 6)
	click(w, "btn_getup")
	check(REST.ups == 1, "the button calls coop.rest.get_up()")
	check(win() == nil and not w:IsShown() and not INFOS.actor_is_sleeping, "and the window closes, the body is awake")
	-- keys: ESC and USE
	fresh("host")
	stock_ui(6):OnButtonSleep()
	w = win()
	check(w:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED) == true and REST.ups == 1 and win() == nil, "ESC gets up")
	fresh("host")
	stock_ui(6):OnButtonSleep()
	w = win()
	w:OnKeyboard(5, ui_events.WINDOW_KEY_PRESSED)
	check(REST.ups == 0 and win() ~= nil, "another key does nothing")
	w:OnKeyboard(USE_DIK, ui_events.WINDOW_KEY_PRESSED)
	check(REST.ups == 1 and win() == nil, "USE gets up")
	-- a second ask right after getting up is held back: the session takes one a second
	fresh("host")
	local ui = stock_ui(6)
	ui:OnButtonSleep()
	click(win(), "btn_getup")
	NOW = NOW + 400
	local again = stock_ui(3)
	again.shown = true
	again:OnButtonSleep()
	check(#REST.lie == 1 and again.shown == true and last(MSGS) == STR.st_coop_rest_slow,
		"lie down again within a second: not sent, the dialog stays open, a tip (" .. tostring(last(MSGS)) .. ")")
	NOW = NOW + 700
	again:OnButtonSleep()
	check(#REST.lie == 2 and REST.lie[2].hours == 3 and again.shown == false and win() ~= nil, "a second later it goes")
	-- getting up is never held back
	click(win(), "btn_getup")
	check(REST.ups == 2, "get_up is sent whenever the player asks")
end)

case("refused_tip", function()
	fresh("host")
	stock_ui(6):OnButtonSleep()
	fire("coop_rest_refused", "place")
	check(last(MSGS) == STR.st_coop_rest_refused_place and STR.st_coop_rest_refused_place ~= nil, "place -> st_coop_rest_refused_place: " .. tostring(last(MSGS)))
	check(win() == nil and not INFOS.actor_is_sleeping, "the refusal closes the doze window")
	for _, r in ipairs({ "combat", "dead", "busy", "camp" }) do
		MSGS = {}
		fire("coop_rest_refused", r)
		check(last(MSGS) == STR["st_coop_rest_refused_" .. r] and STR["st_coop_rest_refused_" .. r] ~= nil, r .. " has its own text")
	end
	-- any other reason (a later engine may add one) is a generic line, never an error
	for _, r in ipairs({ "consent", "weird thing", "", "x_" .. string.rep("y", 80) }) do
		MSGS = {}
		fire("coop_rest_refused", r)
		check(last(MSGS) == STR.st_coop_rest_refused, "unknown reason '" .. r:sub(1, 12) .. "': the generic line")
	end
	MSGS = {}
	fire("coop_rest_refused", nil)
	check(last(MSGS) == STR.st_coop_rest_refused, "no reason: the generic line")
	check(not log_has("failed"), "no error in the log")
	-- a refusal while the dream runs does not touch the dream
	fresh("host")
	stock_ui(6):OnButtonSleep()
	fire("coop_rest_sleep", 6)
	fire("coop_rest_refused", "busy")
	check(INFOS.actor_is_sleeping == true and count_eq(EFFECTS, "enable_ui") == 0, "a refusal in the middle of a dream does not stop it")
	-- combat wakes a resting player: the host cancels, the window goes, the tip says why
	fresh("host")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	fire("coop_rest_refused", "combat")
	engine_says(0, "awake", 0)
	check(win() == nil and last(MSGS) == STR.st_coop_rest_refused_combat, "combat: the window is closed with the reason")
	-- in the other order too (host and client differ, T11 review M4)
	fresh("host")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	engine_says(0, "awake", 0)
	fire("coop_rest_refused", "combat")
	check(win() == nil and last(MSGS) == STR.st_coop_rest_refused_combat, "the other order: the same")
end)

-- T11 round 1: a refused lie-down is 'awake' first and the reason after it; 'camp' = no camp could be made here; 'place' can also
-- come at the start of the group sleep, without a new lie-down (the resting player walked away from his place)
case("refused_after_changed", function()
	fresh("host")
	stock_ui(6):OnButtonSleep()
	fire("coop_rest_changed", 0, "awake", 0) -- the refusal's first message; nothing was ever 'resting'
	check(win() ~= nil, "'awake' before any 'resting': the window waits for the reason, it is not the end yet")
	fire("coop_rest_refused", "camp")
	check(win() == nil and last(MSGS) == STR.st_coop_rest_refused_camp and STR.st_coop_rest_refused_camp ~= nil,
		"camp: the window closes with st_coop_rest_refused_camp (" .. tostring(last(MSGS)) .. ")")
	check(not INFOS.actor_is_sleeping and #REST.lie == 1, "the body is awake, nothing was asked again")
	fresh("host")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	advance(2000, 1000)
	check(win() ~= nil, "(resting, waiting for the others)")
	engine_says(0, "awake", 0) -- the group sleep starts: I am not at my place any more
	fire("coop_rest_refused", "place")
	check(win() == nil and last(MSGS) == STR.st_coop_rest_refused_place, "place at the start of the sleep: the window closes with the place text")
	check(not INFOS.actor_is_sleeping and #CAMS == 0 and count_eq(EFFECTS, "disable_ui") == 0, "and no dream starts")
	-- the same on a client
	fresh("client")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	engine_says(0, "awake", 0)
	fire("coop_rest_refused", "place")
	check(win() == nil and last(MSGS) == STR.st_coop_rest_refused_place, "a client: the same")
end)

case("prompt_for_others", function()
	fresh("host")
	REST.states[7], REST.hours[7] = "resting", 8
	fire("coop_rest_changed", 7, "resting", 8)
	check(#MSGS == 1 and MSGS[1] == fmt(STR.st_coop_rest_prompt, "Wolf", 8), "an ally rests: his nick and the hours: " .. tostring(MSGS[1]))
	check(MSGS[1]:find("Wolf", 1, true) ~= nil and MSGS[1]:find("8", 1, true) ~= nil, "(nick and 8 are in the text)")
	fire("coop_rest_changed", 7, "resting", 10)
	check(#MSGS == 1, "the same rest again (hours changed): no second tip")
	fire("coop_rest_changed", 7, "sleeping", 10)
	check(#MSGS == 1, "sleeping is no news")
	REST.states[7] = "awake"
	fire("coop_rest_changed", 7, "awake", 0)
	REST.states[7], REST.hours[7] = "resting", 4
	fire("coop_rest_changed", 7, "resting", 4)
	check(#MSGS == 2 and MSGS[2] == fmt(STR.st_coop_rest_prompt, "Wolf", 4), "he got up and lay down again: a new tip")
	-- the queue replays a rest that is over (a load): the state is read again, no tip for it
	fresh("host")
	REST.states[7] = "awake"
	fire("coop_rest_changed", 7, "resting", 8)
	check(#MSGS == 0, "a stale 'resting' (the state says awake): nothing")
	-- I rest myself: the window says who is awake, no tip over it
	fresh("host")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	REST.states[7], REST.hours[7] = "resting", 8
	fire("coop_rest_changed", 7, "resting", 8)
	check(#MSGS == 0, "while I rest the ally's rest is not announced")
	-- my own rest is nobody's prompt, an unknown id has a placeholder
	fresh("host")
	engine_says(0, "resting", 6)
	check(#MSGS == 0, "my own change is not announced to me")
	engine_says(0, "awake", 0)
	REST.states[9], REST.hours[9] = "resting", 2
	fire("coop_rest_changed", 9, "resting", 2)
	check(#MSGS == 1 and MSGS[1] == fmt(STR.st_coop_rest_prompt, "?", 2), "a player the list does not know: '?'")
	fire("coop_rest_changed", "x", "resting", 2)
	fire("coop_rest_changed", 7, nil, nil)
	check(not log_has("failed"), "garbage arguments do not raise")
end)

case("world_block_reports_emission", function()
	fresh("host")
	advance(1000, 500)
	check(#REST.worlds >= 1 and last(REST.worlds) == "", "no emission: set_world_block('') (" .. tostring(last(REST.worlds)) .. ")")
	SURGE_ON = true
	advance(1000, 500)
	check(last(REST.worlds) == "emission", "the emission starts: set_world_block('emission')")
	local before = #REST.worlds
	advance(4000, 500)
	check(#REST.worlds - before >= 4 and last(REST.worlds) == "emission", "and it is said every second, not only when it starts (" .. (#REST.worlds - before) .. " in 4 s)")
	SURGE_ON = false
	advance(1000, 500)
	check(last(REST.worlds) == "", "the emission is over: set_world_block('')")
	PSI_ON = true
	advance(1000, 500)
	check(last(REST.worlds) == "emission", "a psi-storm holds the sleep too")
	PSI_ON = false
	advance(1000, 500)
	check(last(REST.worlds) == "", "and lets it go")
	-- an emission manager that throws is no emission
	surge_manager.is_started = function() error("boom") end
	advance(1000, 500)
	check(last(REST.worlds) == "" and not log_has("failed"), "a failing manager reads as no emission")
	surge_manager.is_started = function() return SURGE_ON end
	-- the host's job only
	fresh("client")
	SURGE_ON = true
	advance(3000, 500)
	check(#REST.worlds == 0, "a client does not report the world")
	fresh("sp")
	advance(3000, 500)
	check(#REST.worlds == 0, "no session: nothing")
end)

-- ------------------------------------------------------------------ the fold button
-- T14 review I-1: GAMMA's Immersive Sleep sets the rest per hour by comfort before the stock sleep
-- (ui_sleep_dialog.get_immersive_sleep_hours); the co-op sleep does not call it, so it sets the same rates itself
case("immersive_sleep_rest_rate", function()
	fresh("host")
	ui_sleep_dialog.get_immersive_sleep_hours = function(h) return h end
	stock_ui(5):OnButtonSleep()
	engine_says(0, "resting", 5)
	engine_says(0, "sleeping", 5)
	fire("coop_rest_sleep", 5)
	coop_rest.dream_mid()
	check(RATES[1] == 980 and #RATES == 1, "no sleeping bag: 980 per hour, set once (" .. table.concat(RATES, ",") .. ")")
	coop_rest.dream_end()
	fresh("client")
	ui_sleep_dialog.get_immersive_sleep_hours = function(h) return h end
	spawn("ph_sleepbag", vec3(2, 0, 1), nil, { id = 777 })
	ui_sleep_dialog.sleep_bag(777, "itm_sleepbag")
	local ui = ui_sleep_dialog.GUI
	ui.time_track = { GetIValue = function() return 6 end }
	ui:OnButtonSleep()
	engine_says(SELF, "resting", 6)
	engine_says(SELF, "sleeping", 6)
	fire("coop_rest_sleep", 6)
	coop_rest.dream_mid()
	check(RATES[#RATES] == 1120, "in a sleeping bag: 1120 per hour (" .. table.concat(RATES, ",") .. ")")
end)

case("fold_button", function()
	fresh("client")
	spawn("ph_sleepbag", vec3(2, 0, 1), nil, { id = 777 })
	ui_sleep_dialog.sleep_bag(777, "itm_sleepbag")
	local ui = ui_sleep_dialog.GUI
	check(ui:IsShown(), "the client uses his bag: the slider")
	ui.time_track = { GetIValue = function() return 6 end }
	ui:OnButtonSleep()
	local w = win()
	check(w ~= nil and w.btn_fold:IsShown(), "the doze window offers 'Fold' at a bag of his")
	check(w.btn_fold.enabled == true, "(enabled)")
	-- the claim: coop_checkpoints asks the host after the delay, with the position of the bag, not of the player
	click(w, "btn_fold")
	check(REST.ups == 1 and win() == nil, "Fold gets up and closes the window")
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack", "a pack claim went to the engine")
	check(CLAIMS[1] and math.abs(CLAIMS[1].x - 2) < 1e-6 and math.abs(CLAIMS[1].z - 1) < 1e-6,
		"at the bag's position, not the player's (" .. tostring(CLAIMS[1] and CLAIMS[1].x) .. "," .. tostring(CLAIMS[1] and CLAIMS[1].z) .. ")")
	-- no key in the player's custom data (T13 M-12): the claim is sent all the same, the host judges the owner
	check(db.actor.spawn_ini == nil or db.actor:spawn_ini() == nil, "(the actor has no [coop] key to read)")
	-- no bag: no button
	fresh("client")
	stock_ui(3):OnButtonSleep()
	check(win() ~= nil and not win().btn_fold:IsShown(), "no bag: no Fold")
	-- the bag is too far
	fresh("client")
	spawn("ph_sleepbag", vec3(30, 0, 0), nil, { id = 778 })
	ui_sleep_dialog.sleep_bag(778, "itm_sleepbag")
	ui_sleep_dialog.GUI:OnButtonSleep()
	check(win() ~= nil and not win().btn_fold:IsShown(), "a bag 30 m away: no Fold")
	-- a tent object, a placeable-less bag (the argument is a server object), a bag that is gone
	fresh("client")
	spawn("ph_tent", vec3(1, 0, 0), nil, { id = 779 })
	ui_sleep_dialog.sleep_bag(779, "x")
	ui_sleep_dialog.GUI:OnButtonSleep()
	check(win() ~= nil and not win().btn_fold:IsShown(), "an object that is not a sleeping bag: no Fold")
	fresh("client")
	local se = spawn("itm_sleepbag", vec3(0, 0, 0), 0, { id = 780 })
	ui_sleep_dialog.sleep_bag(se, "itm_sleepbag")
	ui_sleep_dialog.GUI:OnButtonSleep()
	check(win() ~= nil and not win().btn_fold:IsShown(), "a bag that is only an item (use_placeable off): no Fold")
	fresh("client")
	spawn("ph_sleepbag", vec3(1, 0, 0), nil, { id = 781 })
	ui_sleep_dialog.sleep_bag(781, "itm_sleepbag")
	release_id(781)
	ui_sleep_dialog.GUI:OnButtonSleep()
	check(win() ~= nil and not win().btn_fold:IsShown(), "a bag that is gone: no Fold")
	-- the host folds with the stock compression bag: no claim, no button
	fresh("host")
	spawn("ph_sleepbag", vec3(1, 0, 0), nil, { id = 782 })
	ui_sleep_dialog.sleep_bag(782, "itm_sleepbag")
	ui_sleep_dialog.GUI:OnButtonSleep()
	check(win() ~= nil and not win().btn_fold:IsShown(), "the host: no Fold")
	-- the bag is forgotten once the rest is over: another sleep at a tent has no Fold
	fresh("client")
	spawn("ph_sleepbag", vec3(1, 0, 0), nil, { id = 783 })
	ui_sleep_dialog.sleep_bag(783, "itm_sleepbag")
	ui_sleep_dialog.GUI:OnButtonSleep()
	click(win(), "btn_getup")
	NOW = NOW + 1500
	stock_ui(2):OnButtonSleep()
	check(win() ~= nil and not win().btn_fold:IsShown(), "the next rest does not remember the old bag")
end)

-- ------------------------------------------------------------------ the party panel line
case("panel_rest_line", function()
	fresh("host")
	load_script("coop_allies")
	check(type(coop_allies.rest_mark) == "function", "coop_allies.rest_mark exists")
	check(coop_allies.rest_mark(7) == nil, "awake: no line")
	REST.states[7], REST.hours[7] = "resting", 8
	check(coop_allies.rest_mark(7) == fmt(STR.st_coop_rest_panel, 8), "resting: 'resting 8 h' (" .. tostring(coop_allies.rest_mark(7)) .. ")")
	REST.states[7] = "sleeping"
	check(coop_allies.rest_mark(7) == nil, "sleeping: no line (the sleep lasts a few seconds)")
	REST.states[7] = "resting"
	REST.hours[7] = 0
	check(coop_allies.rest_mark(7) == nil, "resting with unknown hours: no wrong number")
	check(coop_allies.rest_mark(nil) == nil and coop_allies.rest_mark("x") == nil, "no player, garbage: nothing")
	REST.hours[7] = 3
	coop.rest.state_of = function() error("boom") end
	check(coop_allies.rest_mark(7) == nil, "a failing engine: nothing, no error")
	coop.rest = nil
	check(coop_allies.rest_mark(7) == nil, "an engine without coop.rest: nothing")
	-- the panel asks for it (scripts\coop_core_hud.script, info_text)
	local hud = read("gamedata/scripts/coop_core_hud.script") or ""
	check(hud:find("allies().rest_mark(", 1, true) ~= nil, "coop_core_hud.info_text shows the rest line")
	local at_rest, at_camp = hud:find("rest_mark(", 1, true), hud:find("checkpoint_mark(", 1, true)
	check(at_rest and at_camp and at_rest < at_camp, "and before the camp mark")
end)

-- ------------------------------------------------------------------ a new world
case("world_entry_cleans_infos", function()
	fresh("host")
	INFOS.actor_is_sleeping, INFOS.sleep_active = true, true -- a save written while the window was open
	fire("actor_on_first_update")
	check(not INFOS.actor_is_sleeping and not INFOS.sleep_active, "a loaded save does not keep a sleeping body")
	-- a window open when the level changes is forgotten
	fresh("host")
	stock_ui(6):OnButtonSleep()
	fire("actor_on_first_update")
	check(win() == nil and not INFOS.actor_is_sleeping, "the window of the old world is forgotten")
end)

-- ------------------------------------------------------------------ strings and layout
case("strings_and_layout", function()
	local rus = strings_of(RUS)
	local keys = {}
	for id in pairs(STR) do keys[#keys + 1] = id end
	table.sort(keys)
	check(#keys >= 20, "the English table has the strings (" .. #keys .. ")")
	local missing, empty, latin = {}, {}, {}
	for _, id in ipairs(keys) do
		if not rus[id] then missing[#missing + 1] = id end
		if STR[id] == "" or (rus[id] or "") == "" then empty[#empty + 1] = id end
		-- the Russian text is Russian: at least one Cyrillic byte of windows-1251
		if rus[id] and not rus[id]:find("[\192-\255]") then latin[#latin + 1] = id end
	end
	check(#missing == 0, "every string has a Russian twin (" .. table.concat(missing, ",") .. ")")
	check(#empty == 0, "no empty string (" .. table.concat(empty, ",") .. ")")
	check(#latin == 0, "the Russian strings are in Cyrillic (" .. table.concat(latin, ",") .. ")")
	local extra = {}
	for id in pairs(rus) do if not STR[id] then extra[#extra + 1] = id end end
	check(#extra == 0, "and no Russian string without an English twin (" .. table.concat(extra, ",") .. ")")
	-- placeholders match between the languages
	local mismatch = {}
	for _, id in ipairs(keys) do
		local a = select(2, STR[id]:gsub("%%[sd]", ""))
		local b = select(2, (rus[id] or ""):gsub("%%[sd]", ""))
		if a ~= b then mismatch[#mismatch + 1] = id end
	end
	check(#mismatch == 0, "the same %s / %d in both languages (" .. table.concat(mismatch, ",") .. ")")
	-- every literal key the script asks for is there; every string id of the layout too
	local src = read("gamedata/scripts/coop_rest.script") or ""
	local absent = {}
	for _, fn in ipairs({ "text", "tell" }) do
		for key in src:gmatch("[^%w_]" .. fn .. '%("([%w_]+)"%s*[,%)]') do
			if not STR["st_coop_rest_" .. key] then absent[#absent + 1] = key end
		end
	end
	check(#absent == 0, "every text() / tell() key of the script is a string (" .. table.concat(absent, ",") .. ")")
	local xml = read(UI_XML) or ""
	local xml_absent = {}
	for id in xml:gmatch("(st_coop_rest_[%w_]+)") do if not STR[id] then xml_absent[#xml_absent + 1] = id end end
	check(#xml_absent == 0 and xml ~= "", "every string id of ui_coop_rest.xml is a string (" .. table.concat(xml_absent, ",") .. ")")
	for _, id in ipairs({ "st_coop_rest_refused_place", "st_coop_rest_refused_combat", "st_coop_rest_refused_dead", "st_coop_rest_refused_busy", "st_coop_rest_refused_camp",
		"st_coop_rest_block_combat", "st_coop_rest_block_world", "st_coop_rest_prompt", "st_coop_rest_panel" }) do
		check(STR[id] ~= nil, id .. " exists (named in the brief)")
	end
	check((STR.st_coop_rest_prompt or ""):find("%%s") ~= nil and (STR.st_coop_rest_prompt or ""):find("%%d") ~= nil, "the prompt takes a nick and the hours")
	-- the layout parts the script initialises
	local paths = xml_paths(UI_XML)
	for _, p in ipairs({ "doze_shade", "doze", "doze:frame", "doze:cap", "doze:hours", "doze:waiting", "doze:reason", "doze:hint",
		"doze:btn_getup", "doze:btn_fold" }) do
		check(paths[p] == true, "ui_coop_rest.xml has <" .. p .. ">")
	end
	-- the routing files already name the script
	check((read("gamedata/configs/coop_route_f3.ltx") or ""):find("coop_rest%s*=%s*owner") ~= nil, "the route of coop_rest is 'owner' (every machine, own player)")
end)

done("REST")
