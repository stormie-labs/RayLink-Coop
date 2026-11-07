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
		lie_down = function(hours, forced, bag)
			REST.lie[#REST.lie + 1] = { hours = hours, forced = forced, bag = bag }
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
local function inv() local f = rest().invite_window; return f and f() or nil end

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
	-- is the player free for a window (the offer to lie down too): actor_menu.is_hud_free, the PDA
	HUD_FREE, PDA_SHOWN = true, false
	actor_menu.is_hud_free = function() return HUD_FREE end
	ActorMenu = { get_pda_menu = function() return { IsShown = function() return PDA_SHOWN end } end }
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
	-- live 2026-10-25: F on a sleeping bag on a client ("F does not press") - the engine keeps the use here and calls
	-- use_sleep_place, which opens the stock dialog for that bag; the lie-down names the bag, so the host lets one sleeper
	-- on it (owner: "if somebody took the bag, the second one hears: this sleeping bag is taken")
	fresh("host")
	local _, bag = spawn("ph_sleepbag", vec3(1, 0, 0), nil, { id = 778 }) -- the game object (the engine passes one)
	coop_rest.use_sleep_place(bag)
	check(STOCK.bags[1] == 778 and ui_sleep_dialog.GUI:IsShown(), "use_sleep_place opens the sleep dialog for that bag")
	ui_sleep_dialog.GUI:OnButtonSleep()
	check(REST.lie[1] and REST.lie[1].bag == 778, "the lie-down names the sleeping bag")
	fresh("host")
	stock_ui(6):OnButtonSleep()
	check(REST.lie[1] and REST.lie[1].bag == nil, "a rest away from a bag names none")
	check(coop_rest.use_sleep_place(nil) == false, "nothing to use: nothing opens")
	for _, lang in ipairs({ "eng", "rus" }) do
		local x = read("gamedata/configs/text/" .. lang .. "/st_coop_rest.xml") or ""
		check(x:find('id="st_coop_rest_refused_occupied"', 1, true) ~= nil, lang .. ": the 'sleeping bag is taken' line exists")
	end
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

-- an ally (local id `id`) lies down for `hours`: the mirror, then the callback
local function ally_rests(id, hours)
	REST.states[id], REST.hours[id] = "resting", hours
	fire("coop_rest_changed", id, "resting", hours)
end

local function ally_up(id)
	REST.states[id], REST.hours[id] = "awake", 0
	fire("coop_rest_changed", id, "awake", 0)
end

-- Owner 2026-11-07 (live report from vanilla: "there was no window to accept the time skip"): an ally who lies down is an
-- offer window for every other awake player, not only a tip.
case("prompt_for_others", function()
	fresh("host")
	ally_rests(7, 8)
	local w = inv()
	check(w ~= nil and w:IsShown(), "an ally rests: the offer window opens")
	check(w and w.question.text == fmt(STR.st_coop_rest_invite, "Wolf", 8), "his nick and the hours: " .. tostring(w and w.question.text))
	check(w and w.question.text:find("Wolf", 1, true) ~= nil and w.question.text:find("8", 1, true) ~= nil, "(nick and 8 are in the text)")
	check(#MSGS == 0, "the window is the news: no tip under it")
	fire("coop_rest_changed", 7, "resting", 10)
	check(inv() == w and #MSGS == 0, "the same rest again (hours changed): no second window, no tip")
	fire("coop_rest_changed", 7, "sleeping", 10)
	check(inv() == w, "sleeping is no news")
	click(w, "btn_no")
	ally_up(7)
	ally_rests(7, 4)
	check(inv() ~= nil and inv() ~= w and inv().question.text == fmt(STR.st_coop_rest_invite, "Wolf", 4), "he got up and lay down again: a new offer")
	-- the queue replays a rest that is over (a load): the state is read again, no offer for it
	fresh("host")
	REST.states[7] = "awake"
	fire("coop_rest_changed", 7, "resting", 8)
	check(inv() == nil and #MSGS == 0, "a stale 'resting' (the state says awake): nothing")
	-- I rest myself: the doze window says who is awake, no offer over it
	fresh("host")
	stock_ui(6):OnButtonSleep()
	engine_says(0, "resting", 6)
	ally_rests(7, 8)
	check(inv() == nil and #MSGS == 0, "while I rest the ally's rest is not offered")
	-- my own rest is nobody's offer, an unknown id has a placeholder
	fresh("host")
	engine_says(0, "resting", 6)
	check(inv() == nil and #MSGS == 0, "my own change is not offered to me")
	engine_says(0, "awake", 0)
	ally_rests(9, 2)
	check(inv() ~= nil and inv().question.text == fmt(STR.st_coop_rest_invite, "?", 2), "a player the list does not know: '?'")
	fire("coop_rest_changed", "x", "resting", 2)
	fire("coop_rest_changed", 7, nil, nil)
	check(not log_has("failed"), "garbage arguments do not raise")
	-- no session: nothing
	fresh("sp")
	REST.states[7] = "resting"
	fire("coop_rest_changed", 7, "resting", 8)
	check(inv() == nil, "no session: no offer")
	-- the window cannot be made (a broken layout): the old tip says it
	fresh("client")
	coop_rest.UICoopInvite = function() error("boom") end
	ally_rests(7, 8)
	check(inv() == nil and last(MSGS) == fmt(STR.st_coop_rest_prompt, "Wolf", 8), "no window: the tip '<nick> is tired, rest too' (" .. tostring(last(MSGS)) .. ")")
	check(GUIREG.UICoopInvite == nil, "and nothing is registered")
end)

case("invite_window", function()
	for _, mode in ipairs({ "client", "host" }) do
		fresh(mode)
		ally_rests(7, 8)
		local w = inv()
		check(w ~= nil and w:IsShown(), mode .. ": every awake player gets the offer")
		check(GUIREG.UICoopInvite == true, mode .. ": a registered UI (the stock HUD knows a window is up)")
		check(#MISSING_PATHS == 0, "every element the offer asks for is in ui_coop_rest.xml (" .. table.concat(MISSING_PATHS, ",") .. ")")
		check(#REST.lie == 0 and win() == nil, mode .. ": nothing is asked before the answer")
		check(w and w.reason.text == "", "no refusal yet: an empty reason line")
	end
end)

case("invite_accept", function()
	fresh("client")
	ally_rests(7, 8)
	click(inv(), "btn_yes")
	check(#REST.lie == 1 and REST.lie[1].hours == 8 and REST.lie[1].forced == false and REST.lie[1].bag == nil,
		"'Lie down too' -> coop.rest.lie_down(8, false) (his hours, no bag)")
	check(inv() == nil and GUIREG.UICoopInvite == nil, "the offer closes")
	local w = win()
	check(w ~= nil and w:IsShown() and w.hours_txt.text == fmt(STR.st_coop_rest_hours, 8), "the doze window opens for 8 h")
	check(INFOS.actor_is_sleeping == true and GUIREG.UICoopDoze == true, "the body dozes as after the stock dialog")
	-- from here it is the usual rest
	engine_says(0, "resting", 8)
	engine_says(0, "sleeping", 8)
	fire("coop_rest_sleep", 8)
	coop_rest.dream_end()
	check(last(MSGS) == fmt(STR.st_coop_rest_woke, 8) and CGT == 0, "the group sleep: the usual dream, no clock call")
	check(inv() == nil, "and no offer comes back")
end)

case("invite_accept_checks", function()
	-- the checks of the stock dialog the co-op keeps: bleeding, radiation (the stock texts); the window stays and says why
	local cases = {
		{ bleeding = 0.5, radiation = 0, key = "st_sleep_bleeding" },
		{ bleeding = 0, radiation = 1, key = "st_sleep_irradiated" },
		{ bleeding = 0.5, radiation = 1, key = "st_sleep_bleeding_irradiated" },
	}
	for _, c in ipairs(cases) do
		fresh("client")
		db.actor.bleeding, db.actor.radiation = c.bleeding, c.radiation
		ally_rests(7, 6)
		click(inv(), "btn_yes")
		check(#REST.lie == 0, c.key .. ": nothing is asked")
		check(inv() ~= nil and inv().reason.text == c.key, c.key .. ": the window says why (" .. tostring(inv() and inv().reason.text) .. ")")
		check(win() == nil and not INFOS.actor_is_sleeping, c.key .. ": no doze")
	end
	-- bandaged: the second press goes
	db.actor.bleeding, db.actor.radiation = 0, 0
	click(inv(), "btn_yes")
	check(#REST.lie == 1 and inv() == nil and win() ~= nil, "the reason is gone: 'Lie down too' lies down")
	-- the engine does not take the word
	fresh("client")
	REST.lie_ok = false
	ally_rests(7, 6)
	click(inv(), "btn_yes")
	check(inv() ~= nil and inv().reason.text == STR.st_coop_rest_refused and win() == nil, "lie_down said false: the generic refusal in the window")
	-- the session takes one word a second
	fresh("client")
	stock_ui(3):OnButtonSleep()
	click(win(), "btn_getup")
	ally_rests(7, 6)
	click(inv(), "btn_yes")
	check(#REST.lie == 1 and inv() ~= nil and inv().reason.text == STR.st_coop_rest_slow, "within a second of the last word: 'not so fast' in the window")
	NOW = NOW + 1100
	click(inv(), "btn_yes")
	check(#REST.lie == 2 and REST.lie[2].hours == 6 and inv() == nil and win() ~= nil, "a second later it goes")
end)

case("invite_host_refusal", function()
	-- the host judges the rest place: the refusal comes back to the offer with the stock-of-ours text
	for _, mode in ipairs({ "client", "host" }) do
		fresh(mode)
		ally_rests(7, 8)
		click(inv(), "btn_yes")
		fire("coop_rest_changed", 0, "awake", 0)
		fire("coop_rest_refused", "place")
		check(win() == nil and not INFOS.actor_is_sleeping, mode .. ": the refusal ends the doze")
		check(last(MSGS) == STR.st_coop_rest_refused_place, mode .. ": the tip as for any lie-down")
		local w = inv()
		check(w ~= nil and w:IsShown() and w.reason.text == STR.st_coop_rest_refused_place,
			mode .. ": the offer is back and says why (" .. tostring(w and w.reason.text) .. ")")
		check(w and w.question.text == fmt(STR.st_coop_rest_invite, "Wolf", 8), mode .. ": the same offer")
		NOW = NOW + 1100
		click(w, "btn_yes")
		check(#REST.lie == 2 and inv() == nil and win() ~= nil, mode .. ": he moved to a bed and tries again")
	end
	-- every reason of the engine has its text in the window
	for _, r in ipairs({ "combat", "dead", "busy", "camp", "occupied" }) do
		fresh("client")
		ally_rests(7, 8)
		click(inv(), "btn_yes")
		fire("coop_rest_refused", r)
		advance(1000, 500)
		check(inv() ~= nil and inv().reason.text == STR["st_coop_rest_refused_" .. r], r .. ": its own text in the offer")
	end
	-- the engine never answers: the late word is taken back, the offer comes back
	fresh("client")
	ally_rests(7, 8)
	click(inv(), "btn_yes")
	advance(7000, 500)
	check(win() == nil and REST.ups == 1, "7 s with no answer: get_up, the doze closes")
	check(inv() ~= nil and inv().reason.text == STR.st_coop_rest_refused_lost, "and the offer says the host did not answer")
	-- the ally got up meanwhile: no offer to come back to
	fresh("client")
	ally_rests(7, 8)
	click(inv(), "btn_yes")
	REST.states[7] = "awake"
	fire("coop_rest_refused", "place")
	check(inv() == nil and last(MSGS) == STR.st_coop_rest_refused_place, "his rest is over: only the tip")
	-- I got up by my own word: that is my answer
	fresh("client")
	ally_rests(7, 8)
	click(inv(), "btn_yes")
	engine_says(0, "resting", 8)
	click(win(), "btn_getup")
	advance(3000, 500)
	check(inv() == nil and win() == nil, "'Get up' after accepting: no offer again")
	-- a refusal of a lie-down of my own (a bed) is not the offer's business
	fresh("client")
	ally_rests(7, 8)
	click(inv(), "btn_no")
	NOW = NOW + 1100
	stock_ui(5):OnButtonSleep()
	fire("coop_rest_refused", "place")
	advance(2000, 500)
	check(inv() == nil, "my own bed refused after 'Not now': no offer")
end)

case("invite_decline", function()
	fresh("client")
	ally_rests(7, 8)
	click(inv(), "btn_no")
	check(inv() == nil and GUIREG.UICoopInvite == nil and #REST.lie == 0, "'Not now' closes it, nothing is asked")
	fire("coop_rest_changed", 7, "resting", 9)
	advance(3000, 500)
	check(inv() == nil and #MSGS == 0, "one window per rest: no second offer, no tip")
	-- ESC is 'Not now'
	fresh("client")
	ally_rests(7, 8)
	local w = inv()
	check(w:OnKeyboard(5, ui_events.WINDOW_KEY_PRESSED) == false and inv() == w, "another key does nothing")
	check(w:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED) == true and inv() == nil and #REST.lie == 0, "ESC: not now")
	-- a new rest is a new offer
	ally_up(7)
	ally_rests(7, 3)
	check(inv() ~= nil and inv().question.text == fmt(STR.st_coop_rest_invite, "Wolf", 3), "he lies down again later: a new offer")
	-- after 'Not now' the player may still lie down by himself
	click(inv(), "btn_no")
	stock_ui(3):OnButtonSleep()
	check(#REST.lie == 1 and win() ~= nil, "the bed works as before")
	-- 'Not now' to Wolf, then another ally lies down: his own offer; when he gets up the window does not go back to Wolf
	fresh("client")
	ally_rests(7, 8)
	click(inv(), "btn_no")
	ally_rests(9, 2)
	check(inv() ~= nil and inv().question.text == fmt(STR.st_coop_rest_invite, "?", 2), "a new rest after 'Not now': its own offer")
	ally_up(9)
	check(inv() == nil, "he gets up: the window closes, Wolf's rest was answered already")
end)

case("invite_waits_when_busy", function()
	-- a fight of the group (the host's word, coop.rest.block): only a tip; the window when it is over
	fresh("client")
	REST.block = "combat"
	ally_rests(7, 8)
	check(inv() == nil, "a fight: no window steals the input")
	check(last(MSGS) == fmt(STR.st_coop_rest_invite_later, "Wolf", 8), "a tip says the offer comes later: " .. tostring(last(MSGS)))
	advance(3000, 500)
	check(inv() == nil and count_eq(MSGS, fmt(STR.st_coop_rest_invite_later, "Wolf", 8)) == 1, "the tip is said once")
	REST.block = "none"
	advance(1000, 500)
	check(inv() ~= nil and inv():IsShown(), "the fight is over: the window opens")
	-- an inventory, a dialogue, another window, the PDA
	fresh("client")
	HUD_FREE = false
	ally_rests(7, 8)
	check(inv() == nil and last(MSGS) == fmt(STR.st_coop_rest_invite_later, "Wolf", 8), "the HUD is not free: the tip")
	HUD_FREE = true
	advance(1000, 500)
	check(inv() ~= nil, "the menu is closed: the window")
	fresh("client")
	PDA_SHOWN = true
	ally_rests(7, 8)
	check(inv() == nil, "the PDA is open: no window")
	PDA_SHOWN = false
	advance(1000, 500)
	check(inv() ~= nil, "the PDA is closed: the window")
	-- my own fight: I was hit or I shot a moment ago
	fresh("client")
	fire("actor_on_hit_callback", db.actor, 0.2, nil, nil, 0)
	ally_rests(7, 8)
	check(inv() == nil, "hit a moment ago: no window")
	advance(5000, 500)
	check(inv() == nil, "5 s later: still waiting")
	advance(6000, 500)
	check(inv() ~= nil, "10 s quiet: the window")
	fresh("client")
	fire("actor_on_weapon_fired", db.actor, nil, 10, 0, 0, 0)
	ally_rests(7, 8)
	check(inv() == nil, "a shot a moment ago: no window")
	advance(11000, 500)
	check(inv() ~= nil, "10 s quiet: the window")
	-- hit while the window is up: it gives way and comes back when it is quiet
	fresh("client")
	ally_rests(7, 8)
	fire("actor_on_hit_callback", db.actor, 0.3, nil, nil, 0)
	check(inv() == nil and GUIREG.UICoopInvite == nil, "a hit: the window goes at once")
	check(last(MSGS) == fmt(STR.st_coop_rest_invite_later, "Wolf", 8), "with the tip")
	advance(11000, 500)
	check(inv() ~= nil and #REST.lie == 0, "quiet again: the same offer, nothing was answered for him")
	-- dead: no window
	fresh("client")
	db.actor._alive = false
	ally_rests(7, 8)
	advance(2000, 500)
	check(inv() == nil, "a dead body gets no window")
end)

-- Live 2026-11-08 (RL-AMY4-AZXY): a Lua window open through a level change -> heap corruption on the new level's script start.
case("windows_close_on_level_change", function()
	for _, cb in ipairs({ "on_before_level_changing", "on_level_changing", "actor_on_net_destroy" }) do
		fresh("client")
		ally_rests(7, 8)
		check(inv() ~= nil, cb .. ": the offer window is open")
		fire(cb)
		check(inv() == nil and GUIREG.UICoopInvite == nil, cb .. " closes the offer window")
		fresh("host")
		stock_ui(6):OnButtonSleep()
		local w = win()
		check(w ~= nil, cb .. ": the doze window is open")
		fire(cb)
		check(win() == nil and not w:IsShown(), cb .. " closes the doze window")
	end
end)

case("invite_closes_when_rest_ends", function()
	fresh("client")
	ally_rests(7, 8)
	REST.states[7] = "awake" -- the callback was lost: the poll closes it
	advance(1000, 500)
	check(inv() == nil and GUIREG.UICoopInvite == nil, "his rest is over: the window closes by itself")
	fresh("client")
	ally_rests(7, 8)
	ally_up(7)
	check(inv() == nil, "by the callback: at once")
	-- a waiting offer goes too
	fresh("client")
	REST.block = "combat"
	ally_rests(7, 8)
	ally_up(7)
	REST.block = "none"
	advance(2000, 500)
	check(inv() == nil, "an offer that waited for the fight to end is gone with his rest")
	-- two allies rest: one window; the first gets up, the window names the other
	fresh("client")
	ally_rests(7, 8)
	ally_rests(9, 2)
	check(inv() ~= nil and inv().question.text == fmt(STR.st_coop_rest_invite, "Wolf", 8), "one window for the first")
	ally_up(7)
	check(inv() ~= nil and inv().question.text == fmt(STR.st_coop_rest_invite, "?", 2), "Wolf got up: the window names the one who still rests")
	ally_up(9)
	check(inv() == nil, "nobody rests: closed")
	-- I lie down another way (a faint): the offer goes, the doze opens
	fresh("client")
	ally_rests(7, 8)
	ui_sleep_dialog.sleep_forced(4)
	check(inv() == nil and GUIREG.UICoopInvite == nil and win() ~= nil, "a faint: the doze replaces the offer")
	-- the session ends, a new world
	fresh("client")
	ally_rests(7, 8)
	MODE = "sp"
	advance(1000, 500)
	check(inv() == nil, "the session ended: closed")
	fresh("client")
	ally_rests(7, 8)
	fire("actor_on_first_update")
	check(inv() == nil and GUIREG.UICoopInvite == nil, "a new world: closed")
end)

-- Task 1 of 2026-11-07: every stock sleep entry of VANILLA Anomaly (the real ui_sleep_dialog.script of anomaly-ref) in a session
-- goes to coop.rest.lie_down, never to the stock sleep and its level.change_game_time
local function real_stock_sleep()
	local path = REF .. "scripts/ui_sleep_dialog.script"
	local fh = io.open(path, "r")
	if not fh then return nil end
	fh:close()
	XML_FILES["ui_sleep_dialog.xml"] = xml_paths(REF .. "configs/ui/ui_sleep_dialog.xml")
	if not REAL_XML then
		REAL_XML = CScriptXmlInit
		CScriptXmlInit = function()
			local x = REAL_XML()
			function x:InitTrackBar(p)
				local w = window(p)
				w.value = 1
				function w:GetIValue() return self.value end
				function w:SetCurrentValue() self.value = 1 end
				return w
			end
			return x
		end
	end
	CUIScriptWnd.SetAutoDelete = CUIScriptWnd.SetAutoDelete or function() end
	if not SAVED_GLOBALS then -- put back by restore_globals(): the cases after this one see the harness as it was
		SAVED_GLOBALS = { getFS = getFS, utils_obj = rawget(_G, "utils_obj"), ui_load_dialog = rawget(_G, "ui_load_dialog"),
			ui_options = rawget(_G, "ui_options"), disable_info = rawget(_G, "disable_info"), give_info = rawget(_G, "give_info") }
	end
	level.get_time_hours = function() return 13 end
	function disable_info(id) INFOS[id] = nil end
	function give_info(id) INFOS[id] = true end
	IN_ZONE = nil
	utils_obj = { npc_in_zone = function(_, zone) return zone == IN_ZONE end }
	getFS = function() return { file_list_open_ex = function() return nil end } end
	ui_load_dialog = { saved_game_extension = ".scop" }
	ui_options = { get = function() return 3 end }
	ui_sleep_dialog = nil
	local m = load_module("ui_sleep_dialog", REF .. "scripts/")
	coop_rest.on_game_start() -- the wrappers on the real module (the stand-in of fresh() is gone)
	return m
end

local function restore_globals()
	local s = SAVED_GLOBALS
	if not s then return end
	for k, v in pairs({ "getFS", "utils_obj", "ui_load_dialog", "ui_options", "disable_info", "give_info" }) do
		rawset(_G, v, s[v])
	end
	SAVED_GLOBALS = nil
end

-- the stock sleep ran: its camera callback, or the clock
local function stock_slept()
	for _, c in ipairs(CAMS) do
		if c.cb == "ui_sleep_dialog.dream_callback" then return true end
	end
	return CGT > 0
end

case("vanilla_sleep_entries", function()
	fresh("client")
	if not real_stock_sleep() then
		check(false, "the stock ui_sleep_dialog.script is in " .. REF .. "scripts (anomaly-ref)")
		return
	end
	-- control: outside a session the real stock sleep runs and skips the time (the harness sees it)
	MODE = "sp"
	EVENTS.current_safe_cover = true -- the stock shelter check passes
	ui_sleep_dialog.sleep()
	check(ui_sleep_dialog.GUI:IsShown(), "control, no session: the stock slider opens in a shelter")
	ui_sleep_dialog.GUI.time_track.value = 5
	click(ui_sleep_dialog.GUI, "btn_sleep")
	check(stock_slept(), "control, no session: the stock sleep starts its dream (camera callback ui_sleep_dialog.dream_callback)")
	ui_sleep_dialog.dream_callback()
	check(CGT == 1, "control: and its dream skips the clock")
	for _, mode in ipairs({ "client", "host" }) do
		-- a bed: the restrictor's tutorial calls sleep_in_zone -> sleep() -> GUI:TestAndShow(); the slider; the button
		fresh(mode)
		real_stock_sleep()
		IN_ZONE = "bar_actor_sleep_zone"
		INFOS.sleep_active = nil
		ui_sleep_dialog.sleep_in_zone(db.actor, nil)
		local g = ui_sleep_dialog.GUI
		check(g ~= nil and g:IsShown(), mode .. ": a bed opens the stock slider")
		check(not INFOS.sleep_active, mode .. ": sleep_active is taken off (it freezes every time event)")
		g.time_track.value = 7
		click(g, "btn_sleep")
		check(#REST.lie == 1 and REST.lie[1].hours == 7 and REST.lie[1].forced == false, mode .. ": the button -> lie_down(7, false)")
		check(not stock_slept() and win() ~= nil, mode .. ": no stock sleep, no time skip: the doze window")
		click(win(), "btn_getup")
		-- the slider of the second sleep: the same instance (stock keeps GUI)
		NOW = NOW + 1100
		ui_sleep_dialog.sleep()
		check(ui_sleep_dialog.GUI == g and g:IsShown(), mode .. ": sleep() again: the same stock window")
		g.time_track.value = 2
		click(g, "btn_sleep")
		check(#REST.lie == 2 and REST.lie[2].hours == 2 and not stock_slept(), mode .. ": the second button press too")
		click(win(), "btn_getup")
		-- the slider's Cancel / ESC: nothing
		NOW = NOW + 1100
		ui_sleep_dialog.sleep()
		click(g, "btn_cancel")
		check(#REST.lie == 2 and not g:IsShown() and not stock_slept(), mode .. ": Cancel closes the stock window, nothing more")
		-- the faint of actor_status_sleep.force_sleep / actor_status_thirst: ui_sleep_dialog.sleep_forced()
		NOW = NOW + 1100
		ui_sleep_dialog.sleep_forced()
		check(#REST.lie == 3 and REST.lie[3].forced == true and REST.lie[3].hours >= 3 and REST.lie[3].hours <= 9,
			mode .. ": the stock faint -> lie_down(3..9, true)")
		check(not stock_slept(), mode .. ": the faint does not skip the time either")
		click(win(), "btn_getup")
		-- a sleeping bag on the ground (item_tent physic_object_on_use_callback) and an unplaced one (actor_on_item_use)
		NOW = NOW + 1100
		local _, bag = spawn("ph_sleepbag", vec3(1, 0, 0), nil, { id = 790 })
		ui_sleep_dialog.sleep_bag(bag:id(), "itm_sleepbag")
		check(ui_sleep_dialog.GUI:IsShown(), mode .. ": a sleeping bag opens the slider")
		click(ui_sleep_dialog.GUI, "btn_sleep")
		check(#REST.lie == 4 and REST.lie[4].bag == 790 and not stock_slept(), mode .. ": its button lies down on that bag")
		click(win(), "btn_getup")
		NOW = NOW + 1100
		local se = spawn("itm_sleepbag", vec3(0, 0, 0), 0, { id = 791 })
		ui_sleep_dialog.sleep_bag(se, "itm_sleepbag")
		click(ui_sleep_dialog.GUI, "btn_sleep")
		check(#REST.lie == 5 and REST.lie[5].bag == nil and not stock_slept(), mode .. ": an unplaced bag (a server object) lies down without a bag")
		click(win(), "btn_getup")
		-- the debug command (DEV_DEBUG) forces the slider without checks; its button is still ours
		NOW = NOW + 1100
		db.actor.bleeding = 1
		ui_sleep_dialog.sleep(true)
		click(ui_sleep_dialog.GUI, "btn_sleep")
		check(#REST.lie == 6 and not stock_slept(), mode .. ": sleep(true) of the debug menu: lie_down, no stock sleep")
		click(win(), "btn_getup")
		db.actor.bleeding = 0
		check(CGT == 0, mode .. ": level.change_game_time was never called")
		check(count_of(EXEC, function(c) return c:find("^save") ~= nil end) == 0, mode .. ": no stock sleep save")
		check(not log_has("failed"), mode .. ": no error")
	end
	restore_globals()
end)

-- The "rest too" news reaches every machine: the engine's callbacks of coop_rest are owner (every machine, the own player) by
-- the real router rules (configs\coop_route*.ltx), not host-only
case("callbacks_routed_everywhere", function()
	fresh("client")
	if not (coop.route and type(coop.route.of) == "function") then
		check(false, "coop.route.of is in the harness")
		return
	end
	local f = from_script("coop_rest", "return function() end")
	for _, cb in ipairs({ "coop_rest_changed", "coop_rest_sleep", "coop_rest_refused", "actor_on_update", "actor_on_first_update",
		"actor_on_hit_callback", "actor_on_weapon_fired" }) do
		local dom = coop.route.of(cb, f)
		check(dom == "owner", cb .. "@coop_rest runs on every machine (" .. tostring(dom) .. ")")
	end
	-- the strings of the news exist in both languages (strings_and_layout checks the twins)
	for _, id in ipairs({ "st_coop_rest_prompt", "st_coop_rest_invite", "st_coop_rest_invite_later", "st_coop_rest_invite_title",
		"st_coop_rest_invite_yes", "st_coop_rest_invite_no", "st_coop_rest_invite_hint", "st_coop_rest_invite_note" }) do
		check(STR[id] ~= nil, id .. " exists")
	end
	check((STR.st_coop_rest_invite or ""):find("%%s") ~= nil and (STR.st_coop_rest_invite or ""):find("%%d") ~= nil, "the offer takes a nick and the hours")
	check((STR.st_coop_rest_invite_later or ""):find("%%s") ~= nil and (STR.st_coop_rest_invite_later or ""):find("%%d") ~= nil, "the later tip too")
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
	-- HUD v2 (variant B, the owner's pick): the team row shows no words - a resting / sleeping player (coop.rest.state_of)
	-- gets a "z" and breathing segments, and that wins over the camp mark (scripts\coop_core_hud.script, UICoopParty:Fill)
	local hud = read("gamedata/scripts/coop_core_hud.script") or ""
	local at_rest, at_camp = hud:find("r.rest = ", 1, true), hud:find("r.camp = ", 1, true)
	check(at_rest ~= nil and hud:find("rest_state(v.avatar)", 1, true) ~= nil, "the team row asks coop.rest for the z")
	check(at_rest and at_camp and at_rest < at_camp and hud:find("if r.rest then", 1, true) ~= nil, "and the rest wins over the camp mark")
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
		"doze:btn_getup", "doze:btn_fold",
		"invite", "invite:frame", "invite:cap", "invite:question", "invite:note", "invite:reason", "invite:hint",
		"invite:btn_yes", "invite:btn_no" }) do
		check(paths[p] == true, "ui_coop_rest.xml has <" .. p .. ">")
	end
	-- the routing files already name the script
	check((read("gamedata/configs/coop_route_f3.ltx") or ""):find("coop_rest%s*=%s*owner") ~= nil, "the route of coop_rest is 'owner' (every machine, own player)")
end)

done("REST")
