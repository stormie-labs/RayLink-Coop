-- Anomaly Coop test: the client of the co-op debug (docs/DEBUG_DESIGN.md B.5, B.8, C, D; work package 3).
-- F7 in a session opens the co-op debug window on every machine (the host player's too); outside a session it is the stock F7.
-- Server debug off: view panels only, nothing that changes the world. On: the v1 actions, each one a coop.sync.request to
-- coop.dbg.<class> with arguments gathered by the stock formulas (target in host numbering, the point by the camera ray).
-- In a session no stock world function runs locally. The window, the XML and the strings are the real ones. Not shipped.
-- Run: tools\test_lua.cmd debug_client
dofile("tests/lua/support/menu_stubs.lua")
XML_FILES["ui_coop_debug.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_debug.xml")

local function table_of(lang)
	local T = {}
	local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_debug.xml", "rb"))
	for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do T[id] = text end
	fh:close()
	return T
end
local EN, RU = table_of("eng"), table_of("rus")
local T = EN
ASKED = {} -- every st_coop_dbg_* id the scripts asked for while the test ran
game = { translate_string = function(id)
	if type(id) == "string" and id:find("^st_coop_dbg_") then ASKED[id] = true end
	return T[id] or (ITEM_NAMES and ITEM_NAMES[id]) or id
end }

-------------------------------------------------------------------------------
-- Engine stand-ins
-------------------------------------------------------------------------------
local function vec(x, y, z)
	local v = { x = x or 0, y = y or 0, z = z or 0 }
	function v:set(a, b, c)
		if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z else self.x, self.y, self.z = a, b, c end
		return self
	end
	function v:add(o) self.x, self.y, self.z = self.x + o.x, self.y + o.y, self.z + o.z; return self end
	function v:mul(k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k; return self end
	function v:distance_to(o) return math.sqrt((self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2) end
	return v
end
function vector() return vec() end

CAM_DIR = { x = .6, y = -.2, z = .8 }
local device0 = device
function device()
	local d = device0()
	d.cam_dir = vec(CAM_DIR.x, CAM_DIR.y, CAM_DIR.z) -- a fresh one each time, like the engine's copy
	d.cam_pos = vec(100, 6.7, 200)
	return d
end

SPY = {}
local function spy(name) return function(...) SPY[name] = (SPY[name] or 0) + 1 end end

local ACTOR_POS = { x = 100, y = 5, z = 200 }
local actor = {
	id = function() return 0 end,
	alive = function() return true end,
	position = function() return vec(ACTOR_POS.x, ACTOR_POS.y, ACTOR_POS.z) end,
	level_vertex_id = function() return 1234 end,
	game_vertex_id = function() return 77 end,
	name = function() return "actor" end,
	give_money = spy("give_money"),
	set_actor_position = spy("set_actor_position"),
	transfer_money = spy("transfer_money"),
}
db = { actor = actor, storage = {} }

local function npc(id, name)
	return {
		id = function() return id end, name = function() return name end, section = function() return "stalker_bandit" end,
		clsid = function() return 7 end, character_name = function() return "Sanya" end,
		character_community = function() return "bandit" end, character_rank = function() return 1500 end,
		character_reputation = function() return 200 end, position = function() return vec(110, 5, 205) end,
		alive = function() return true end,
	}
end
TARGET = npc(42, "bandit_42")
TARGET_DIST = 10
level = {
	present = function() return true end,
	name = function() return "l01_escape" end,
	get_target_obj = function() return TARGET end,
	get_target_dist = function() return TARGET_DIST end,
	vertex_id = function(p) LAST_VERTEX_POS = { x = p.x, y = p.y, z = p.z }; return 5555 end,
	vertex_position = function() return vec(ACTOR_POS.x, ACTOR_POS.y, ACTOR_POS.z) end,
	object_by_id = function(id) if id == 42 then return TARGET end end,
	get_time_hours = function() return 14 end,
	get_time_minutes = function() return 5 end,
	get_time_factor = function() return 10 end,
	get_weather = function() return "w_clear1" end,
	change_game_time = spy("change_game_time"),
	set_weather = spy("set_weather"),
	set_weather_fx = spy("set_weather_fx"),
	set_time_factor = spy("set_time_factor"),
}
alife_create_item = spy("alife_create_item")
alife_create = spy("alife_create")
alife_release = spy("alife_release")
alife_release_id = spy("alife_release_id")
function alife() return { create = spy("alife:create"), release = spy("alife:release"), object = function() end } end
give_info = spy("give_info")
disable_info = spy("disable_info")
surge_manager = { start_surge = spy("start_surge"), stop_surge = spy("stop_surge") }

key_bindings = { kCUSTOM17 = 117, kCONSOLE = 2 }
DIK_F7 = 65
function dik_to_bind(k) if k == DIK_F7 then return key_bindings.kCUSTOM17 end return 0 end
DIK_keys.DIK_F7 = DIK_F7

CALLBACKS = {}
function RegisterScriptCallback(name, f) CALLBACKS[name] = CALLBACKS[name] or {}; table.insert(CALLBACKS[name], f) end
function UnregisterScriptCallback() end
local function fire(name, ...)
	for _, f in ipairs(CALLBACKS[name] or {}) do f(...) end
end

CONSOLE = {}
function exec_console_cmd(line) CONSOLE[#CONSOLE + 1] = line end
function get_console() return { execute = function(_, line) CONSOLE[#CONSOLE + 1] = line end } end

-- the system ini for the catalogs: items of every category (with icons), squads, a mutant, a thing without a class
SECTIONS = { wpn_ak74 = { class = "WP_AK74", inv_weight = "3", inv_name = "st_ak74", inv_grid_x = "10", inv_grid_y = "4", inv_grid_width = "5", inv_grid_height = "2" },
	wpn_ak74u = { class = "WP_AK74", inv_weight = "2.7", inv_name = "st_ak74u", inv_grid_width = "4", inv_grid_height = "2" },
	wpn_ak74_alt = { class = "WP_AK74", inv_weight = "3", parent_section = "wpn_ak74" }, -- a variant: not listed (the stock rule)
	medkit = { class = "II_MEDKI", inv_weight = ".1", inv_name = "st_medkit", inv_grid_width = "1", inv_grid_height = "1" },
	["ammo_5.45x39_fmj"] = { class = "AMMO", inv_weight = ".01", inv_name = "st_ammo545" },
	stalker_outfit = { class = "EQU_STLK", inv_weight = "5", inv_name = "st_outfit" },
	af_medusa = { class = "ARTEFACT", inv_weight = ".5", inv_name = "st_medusa" },
	wpn_addon_scope = { class = "WP_SCOPE", inv_weight = ".2", inv_name = "st_scope" },
	device_torch = { class = "D_FLALIT", inv_weight = ".2", inv_name = "st_torch" },
	mp_wpn_ak74 = { class = "WP_AK74", inv_weight = "3" }, -- multiplayer: not listed
	simulation_bandit_3 = { class = "ON_OFF_S" }, sim_squad_bandit = { class = "ON_OFF_S", faction = "bandit" },
	sim_squad_bloodsucker = { class = "ON_OFF_S", faction = "monster" }, bloodsucker_weak = { class = "SM_BLOOD" },
	story_squad = { class = "ON_OFF_S", faction = "bandit", story_id = "x" }, actor_condition = {} }
-- names; the medkit's is Russian in cp1251 ("Aptechka" in capitals and small letters)
ITEM_NAMES = { st_ak74 = "AK-74", st_ak74u = "AKS-74U", st_medkit = "\192\239\242\229\247\234\224", st_ammo545 = "5.45x39 FMJ",
	st_outfit = "Stalker suit", st_medusa = "Medusa", st_scope = "PSO-1", st_torch = "Torch", l01_escape = "Cordon", l02_garbage = "Garbage",
	l03_agroprom = "Agroprom" }
ini_sys = {}
function ini_sys:section_exist(s) return SECTIONS[s] ~= nil end
function ini_sys:line_exist(s, k) return SECTIONS[s] ~= nil and SECTIONS[s][k] ~= nil end
function ini_sys:section_for_each(f) for s in pairs(SECTIONS) do f(s) end end
function ini_sys:r_string_ex(s, k) return SECTIONS[s] and SECTIONS[s][k] end
-- the levels (game.ltx [level_maps_single]) and the stock helper that reads them
function game_ini() return { tag = "game" } end
utils_data = { collect_section = function(ini, sec)
	if sec == "level_maps_single" then return { "l01_escape", "l02_garbage", "l03_agroprom" } end
	return {}
end }
-- the machine's options (axr_options): the window keeps its place, size and settings there
axr_main = { config = config_stub() }
-- the cursor in the 1024 x 768 UI space, and the mouse events of a window
CURSOR = { x = 0, y = 0 }
function GetCursorPosition() return { x = CURSOR.x, y = CURSOR.y } end
ui_events.WINDOW_LBUTTON_DOWN, ui_events.WINDOW_LBUTTON_UP, ui_events.WINDOW_MOUSE_MOVE = 61, 62, 63
ui_events.WINDOW_LBUTTON_DB_CLICK = 64
RENDERER = "renderer_r4"
function get_console_cmd(typ, name) if name == "renderer" then return RENDERER end end

-- coop_main: the event table of the scripts and the flat payloads
EVENT = {}
coop_main = {
	add_event_handler = function(name, f) EVENT[name] = f end,
	decode = function(s)
		local t = {}
		for k, v in tostring(s):gmatch("([^;=]+)=([^;]*)") do t[k] = v end
		return t
	end,
}

-- coop: the engine API of the co-op exe (contract: DEBUG_DESIGN E, B.2)
SESSION = true
ROLE = "client" -- "client" | "host"
DEBUG = { on = false, source = 0 }
OPERATOR = false
FLAGS = 0
REQUESTS = {}
coop = {
	is_active = function() return SESSION end,
	is_host = function() return ROLE == "host" end,
	is_client = function() return ROLE == "client" end,
	self_id = function() return ROLE == "host" and 0 or 2 end,
	players = function()
		return {
			{ id = 0, nick = "Host", is_self = ROLE == "host", avatar_id = ROLE == "host" and 0 or 501, rtt = 0 },
			{ id = 2, nick = "Bob", is_self = ROLE == "client", avatar_id = ROLE == "client" and 0 or 502, rtt = 38 },
		}
	end,
	to_host_id = function(id) return ROLE == "host" and id or id + 9000 end,
	life_of = function() return "alive" end,
	debug = {
		state = function() return { on = DEBUG.on, source = DEBUG.source, serial = 1 } end,
		flags = function(peer) return FLAGS end,
		is_operator = function() return OPERATOR end,
	},
	sync = {
		request = function(name, args, cb)
			REQUESTS[#REQUESTS + 1] = { name = name, args = args, cb = cb }
			return true
		end,
	},
}

local client = load_module("coop_debug_client")
local dui = load_module("coop_debug_ui")
client.on_game_start()

local function reset()
	REQUESTS, SPY, CONSOLE = {}, {}, {}
	client.reset_feed()
	dui.close()
end

local function press_f7()
	fire("on_key_release", DIK_F7)
	return dui.window()
end

local function action_buttons(dlg)
	local out = {}
	for name, w in pairs(dlg.registered) do
		local id = name:match("^btn_act_(.+)$")
		if id then out[id] = w end
	end
	return out
end

-------------------------------------------------------------------------------
print("== F7: the co-op window in a session (host and client), the stock one outside")
for _, role in ipairs({ "client", "host" }) do
	reset()
	ROLE = role
	local w = press_f7()
	check(w ~= nil and w.shown == true, role .. ": F7 opens the co-op debug window")
	check(press_f7() == nil, role .. ": F7 again closes it")
end
reset()
SESSION = false
check(press_f7() == nil, "outside a session the co-op window stays shut (the stock F7 has the key)")
SESSION = true
ROLE = "client"

-------------------------------------------------------------------------------
print("== F7 the way the engine delivers it: the level's callback, then the dialog on top (Level_input.cpp)")
ui_events.WINDOW_KEY_RELEASED = ui_events.WINDOW_KEY_RELEASED or 2
-- One press and release of F7. CLevel::IR_OnKeyboardPress / IR_OnKeyboardRelease call the actor's script callback
-- first (on_key_press / on_key_release), then CurrentGameUI()->IR_UIOnKeyboard*, which reaches the dialog shown right
-- now: a window shown from the level's release callback gets that same release. ui_first: the other order.
local function keystroke_f7(ui_first)
	NOW = NOW + 400 -- a person's keystrokes are this far apart at least
	local function to_dialog(action)
		local top = dui.window()
		if top and top.shown then top:OnKeyboard(DIK_F7, action) end
	end
	if ui_first then to_dialog(ui_events.WINDOW_KEY_PRESSED) end
	fire("on_key_press", DIK_F7)
	if not ui_first then to_dialog(ui_events.WINDOW_KEY_PRESSED) end
	if ui_first then to_dialog(ui_events.WINDOW_KEY_RELEASED) end
	fire("on_key_release", DIK_F7)
	if not ui_first then to_dialog(ui_events.WINDOW_KEY_RELEASED) end
	return dui.window()
end
for _, order in ipairs({ { "engine order", false }, { "dialog first", true } }) do
	for _, role in ipairs({ "client", "host" }) do
		reset()
		ROLE = role
		local tag = role .. ", " .. order[1]
		local w = keystroke_f7(order[2])
		check(w ~= nil and w.shown == true, tag .. ": one F7 keystroke leaves the window open (its own release does not shut it)")
		check(keystroke_f7(order[2]) == nil and (w == nil or w.shown == false), tag .. ": the next F7 keystroke closes it")
		local w2 = keystroke_f7(order[2])
		check(w2 ~= nil and w2.shown == true, tag .. ": a third F7 keystroke opens it again")
	end
end
reset()
ROLE = "client"

-------------------------------------------------------------------------------
print("== server debug off: view only")
reset()
DEBUG.on = false
local w = press_f7()
local pages = w:page_ids()
check(table.concat(pages, ",") == "overview,help", "off: the pages are overview and help (" .. table.concat(pages, ",") .. ")")
local changing = {}
for id, b in pairs(action_buttons(w)) do
	local a = client.action(id)
	if not a or a.cls ~= "view" then changing[#changing + 1] = id end
end
check(#changing == 0, "off: no action that changes the world is in the window (" .. table.concat(changing, ",") .. ")")
local ok, why = client.run("kill", { target = TARGET })
check(ok == false and why == "debug_off" and #REQUESTS == 0, "off: a changing action is refused here and nothing is sent")
check(action_buttons(w).can_see ~= nil, "off: 'can it see me' (a view request) is there")
click(w, "btn_act_can_see")
check(#REQUESTS == 1 and REQUESTS[1].name == "coop.dbg.view" and REQUESTS[1].args.cmd == "can_see"
	and REQUESTS[1].args.t == 9042 and REQUESTS[1].args.v == 1, "off: can_see goes to coop.dbg.view with the host's id of the target")
check(w.state_word == EN.st_coop_dbg_state_off and w.state_text.text == EN.st_coop_dbg_head_off, "off: the title bar says so, short")
check(w.title.text == EN.st_coop_dbg_title and w.grip_dots == nil, "the title bar: a plain title, no grip, no long state line")
check(w.toggle == nil or w.toggle.kind == "ghost", "the operator switch is a quiet button")
check(next(w.lists) == nil and w.pages.spawn == nil, "off: no catalog is built")
check(w.registered.btn_server_toggle == nil, "not the server: no on/off button")

-------------------------------------------------------------------------------
print("== the operator's switch is the server console")
reset()
ROLE, OPERATOR = "host", true
w = press_f7()
check(w.registered.btn_server_toggle ~= nil, "operator: the on/off button is there")
click(w, "btn_server_toggle")
check(CONSOLE[1] == "coop_debug on", "operator: the button runs the console command coop_debug on (" .. tostring(CONSOLE[1]) .. ")")
check(w.state_word == EN.st_coop_dbg_state_pending, "operator: waiting for the server after the click")
DEBUG.on, DEBUG.source = true, 2
fire("coop_debug_changed", true, 2)
w = dui.window()
check(w ~= nil and w.state_word == EN.st_coop_dbg_state_on, "the new state rebuilds the open window: on")
check(table.concat(w:page_ids(), ",") == "overview,spawn,npc,levels,favs,target,me,world,help",
	"on: overview, items, npc, levels, favourites, target, me, world, help (" .. table.concat(w:page_ids(), ",") .. ")")
click(w, "btn_server_toggle")
check(CONSOLE[#CONSOLE] == "coop_debug off", "operator: the button now turns it off")
ROLE, OPERATOR = "client", false

-------------------------------------------------------------------------------
print("== server debug on: requests")
reset()
DEBUG.on = true
w = press_f7()
check(action_buttons(w).kill ~= nil and action_buttons(w).kill.enabled, "on: kill is in the window")
click(w, "btn_act_kill")
local r = REQUESTS[1]
check(r and r.name == "coop.dbg.target" and r.args.cmd == "kill" and r.args.t == 9042 and r.args.v == 1,
	"kill -> coop.dbg.target {v=1, cmd=kill, t=host id}")

-- a destructive action asks first
REQUESTS = {}
click(w, "btn_act_release")
check(#REQUESTS == 0 and w.modal == "release", "delete asks before it sends")
click(w, "btn_modal_ok")
check(#REQUESTS == 1 and REQUESTS[1].args.cmd == "release" and REQUESTS[1].args.ok == true, "confirmed: sent with ok=true")

-- the point of the stock formula (ui_debug_launcher.script:1461-1467)
local p = client.aim_point()
check(math.abs(p.x - 106) < 1e-6 and math.abs(p.z - 208) < 1e-6 and p.y == 5 and p.lv == 5555,
	string.format("the point: actor + cam_dir * target distance, the actor's height (%.2f %.2f %.2f lv %s)", p.x, p.y, p.z, tostring(p.lv)))
check(LAST_VERTEX_POS.x == p.x and LAST_VERTEX_POS.z == p.z and LAST_VERTEX_POS.y == 5, "lv is level.vertex_id of that point")
TARGET_DIST = nil
p = client.aim_point()
check(math.abs(p.x - 101.8) < 1e-6 and math.abs(p.z - 202.4) < 1e-6, "no target distance: 3 m, as in the stock")
TARGET_DIST = 10

REQUESTS = {}
ok = client.run("spawn_item", { sec = "wpn_ak74", n = 2, at = "inv" })
r = REQUESTS[1]
check(ok and r.name == "coop.dbg.spawn" and r.args.cmd == "spawn_item" and r.args.sec == "wpn_ak74" and r.args.n == 2
	and r.args.at == "inv" and r.args.x == nil, "spawn in the inventory: sec, n, at=inv, no point")
REQUESTS = {}
client.run("spawn_item", { sec = "wpn_ak74", n = 1, at = "point" })
r = REQUESTS[1]
check(r.args.at == "point" and math.abs(r.args.x - 106) < 1e-6 and r.args.y == 5 and math.abs(r.args.z - 208) < 1e-6
	and r.args.lv == 5555, "spawn at the crosshair: the client's point and vertex")
REQUESTS = {}
check(select(2, client.run("spawn_item", { sec = "", n = 1, at = "inv" })) == "no_section" and #REQUESTS == 0,
	"no section: nothing sent")
check(select(2, client.run("spawn_item", { sec = "wpn_ak74", n = 50, at = "inv" })) == nil and REQUESTS[1].args.n == 20,
	"the count is at most 20")

-- the item catalog: search, pick, then one click; the request is the one run() makes from the same arguments
local function same_args(a, b)
	for k, v in pairs(a) do if b[k] ~= v then return false, k end end
	for k, v in pairs(b) do if a[k] ~= v then return false, k end end
	return true
end
SAME_ARGS = same_args
local function request_of(id, ctx)
	local keep = REQUESTS
	REQUESTS = {}
	client.run(id, ctx)
	local r1 = REQUESTS[1]
	REQUESTS = keep
	return r1
end
REQUEST_OF = request_of
REQUESTS = {}
w:select_page("spawn")
local LS = w.lists.spawn
LS.edit:SetText("ak74")
NOW = NOW + 200
w:Update()
check(LS.list[1].sec == "wpn_ak74" and LS.list[2].sec == "wpn_ak74u" and #LS.list == 2, "the item search finds the items by a part of the name")
click(w, "btn_row_spawn_1")
click(w, "btn_go_spawn")
r = REQUESTS[1]
local want = request_of("spawn_item", { sec = "wpn_ak74", n = 1, at = "inv" })
check(r and r.name == want.name and same_args(r.args, want.args), "the spawn button sends what spawn_item always sent (sec, n, at=inv)")
REQUESTS = {}
click(w, "btn_n_spawn_5")
click(w, "btn_where_spawn_point")
click(w, "btn_go_spawn")
want = request_of("spawn_item", { sec = "wpn_ak74", n = 5, at = "point" })
check(REQUESTS[1] and same_args(REQUESTS[1].args, want.args) and REQUESTS[1].args.lv == 5555, "count 5 at the crosshair: the same request with the point")
-- an object from the NPC catalog: a squad near me
REQUESTS = {}
w:select_page("npc")
local LN = w.lists.npc
click(w, "btn_cat_npc_squads_stalker")
check(#LN.list == 1 and LN.list[1].sec == "sim_squad_bandit", "NPC: the stalker squads (story squads and odd names left out, as in the stock)")
click(w, "btn_row_npc_1")
click(w, "btn_where_npc_near")
click(w, "btn_go_npc")
want = request_of("spawn_object", { sec = "sim_squad_bandit", at = "near" })
check(REQUESTS[1] and REQUESTS[1].name == "coop.dbg.spawn" and same_args(REQUESTS[1].args, want.args), "a squad near me: spawn_object as always")
check(LN.where[1].shown == false, "an object never goes into an inventory: that choice is not offered")
-- a level from the levels catalog
REQUESTS = {}
w:select_page("levels")
local LL = w.lists.levels
check(#LL.list == 3 and LL.list[1].name == "Agroprom" and LL.list[2].name == "Cordon", "levels: localized names, sorted")
click(w, "btn_row_levels_3")
click(w, "btn_go_levels")
want = request_of("level", { level = "l02_garbage" })
check(REQUESTS[1] and REQUESTS[1].args.cmd == "level" and same_args(REQUESTS[1].args, want.args), "a level: the same request the typed level sent")
w:select_page("overview")

-- personal flags read the server's table: on -> the button turns it off
REQUESTS = {}
FLAGS = 1
w:select_page("me")
click(w, "btn_act_god")
check(REQUESTS[1].name == "coop.dbg.self" and REQUESTS[1].args.cmd == "god" and REQUESTS[1].args.on == false,
	"god is on for me: the button asks to turn it off")
REQUESTS = {}
FLAGS = 0
click(w, "btn_act_god")
check(REQUESTS[1].args.on == true, "god is off: the button asks to turn it on")
FLAGS = { invis = true }
check(client.flag_on("invis") and not client.flag_on("god"), "flags as a table are read too")
FLAGS = 0

-- teleport to another player by his node
REQUESTS = {}
click(w, "btn_tp_peer_1")
check(REQUESTS[1].args.cmd == "tp_to_player" and REQUESTS[1].args.p == 0, "teleport to a player: tp_to_player {p = his node}")

-- the faction of the target's squad from the chips, the time speed from the chips, the hour
REQUESTS = {}
w:select_page("target")
click(w, "btn_faction_freedom")
click(w, "btn_act_faction")
local want2 = REQUEST_OF("faction", { target = TARGET, c = "freedom" })
check(REQUESTS[1] and SAME_ARGS(REQUESTS[1].args, want2.args), "faction picked from the chips: faction {t, c} as always")
REQUESTS = {}
w:select_page("world")
click(w, "btn_factor_5")
click(w, "btn_act_time_factor")
want2 = REQUEST_OF("time_factor", { f = 20 })
check(REQUESTS[1] and SAME_ARGS(REQUESTS[1].args, want2.args), "time speed x20: time_factor {f = 20}")
REQUESTS = {}
click(w, "btn_hour_plus")
click(w, "btn_act_time_to")
want2 = REQUEST_OF("time_to", { h = 7, m = 0 })
check(REQUESTS[1] and SAME_ARGS(REQUESTS[1].args, want2.args), "the hour 07:00: time_to {h = 7, m = 0}")
-- a destructive action without the question when the setting says so: the same confirmed request
REQUESTS = {}
dui.get_settings().confirm = false
w:select_page("target")
click(w, "btn_act_release")
check(w.modal == nil and REQUESTS[1] and REQUESTS[1].args.cmd == "release" and REQUESTS[1].args.ok == true, "confirmations off: sent at once, with ok=true")
dui.get_settings().confirm = true

-------------------------------------------------------------------------------
print("== in a session nothing of the stock world runs here")
reset()
local ctx = { target = TARGET, sec = "wpn_ak74", n = 1, at = "point", h = 6, m = 0, f = 10, w = "w_storm1", a = 1000,
	what = "articles", info = "some_info", p = 0, on = true, c = "bandit", level = "l02_garbage" }
local sent, kinds = 0, {}
for _, a in ipairs(client.ACTIONS) do
	ctx.sec = a.id == "spawn_object" and "simulation_bandit_3" or "wpn_ak74"
	local ok2 = client.run(a.id, ctx, nil, true)
	if ok2 then sent = sent + 1 end
	kinds[a.cls] = true
end
local touched = {}
for k, n in pairs(SPY) do touched[#touched + 1] = k .. "=" .. n end
check(#touched == 0, "no stock world call ran locally (" .. table.concat(touched, ",") .. ")")
check(sent == #client.ACTIONS and #REQUESTS == sent, "every action became one request (" .. sent .. "/" .. #client.ACTIONS .. ")")
local names = {}
for _, q in ipairs(REQUESTS) do names[q.name] = true end
check(names["coop.dbg.view"] and names["coop.dbg.world"] and names["coop.dbg.self"] and names["coop.dbg.spawn"]
	and names["coop.dbg.target"], "all five handlers are used")
local bad = {}
for _, q in ipairs(REQUESTS) do
	if q.name ~= "coop.dbg." .. client.action(q.args.cmd_id or q.args.cmd).cls then bad[#bad + 1] = q.args.cmd end
	for k, v in pairs(q.args) do
		if type(v) == "table" or type(v) == "function" or (type(v) == "string" and #v > 64) then bad[#bad + 1] = q.args.cmd .. "." .. k end
	end
end
check(#bad == 0, "every request is a flat table of its class (" .. table.concat(bad, ",") .. ")")

-- The contract with the server's registry (coop_debug_cmds, package 2): every request names a command of that class, and
-- its arguments pass the server's own schema check.
local okr, R = pcall(load_module, "coop_debug_cmds")
check(okr and type(R) == "table" and type(R.validate) == "function", "the server's command registry loads (" .. tostring(okr and "" or R) .. ")")
if okr and type(R) == "table" and type(R.validate) == "function" then
	local wrong = {}
	for _, q in ipairs(REQUESTS) do
		local c = R.get(q.args.cmd)
		local good, code, why = R.validate(q.args.cmd, q.args)
		if not c or "coop.dbg." .. c.class ~= q.name or not good then
			wrong[#wrong + 1] = q.args.cmd .. ":" .. tostring(c and c.class) .. ":" .. tostring(code) .. ":" .. tostring(why)
		end
	end
	check(#wrong == 0, "every request is a command of the registry with valid arguments (" .. table.concat(wrong, " | ") .. ")")
	local mine = {}
	for _, a in ipairs(client.ACTIONS) do mine[a.cmd] = true end
	local confirm_missing = {}
	for _, a in ipairs(client.ACTIONS) do
		local c = R.get(a.cmd)
		if c and c.confirm and not a.confirm then confirm_missing[#confirm_missing + 1] = a.id end
	end
	check(#confirm_missing == 0, "what the registry marks confirm is asked in the window (" .. table.concat(confirm_missing, ",") .. ")")
	local not_in = {}
	for _, id in ipairs(R.list()) do if not mine[id] then not_in[#not_in + 1] = id end end
	print("    registry commands without a button: " .. table.concat(not_in, ", "))
	-- with the registry the kinds follow its classes: an item class, a squad class, nothing
	check(client.section_kind("wpn_ak74") == "item" and client.section_kind("simulation_bandit_3") == "object"
		and client.section_kind("actor_condition") == nil, "section kinds follow the registry's class tables")
end

-------------------------------------------------------------------------------
print("== answers: pending, ok, refusals in the player's words")
for _, lang in ipairs({ "eng", "rus" }) do
	T = lang == "eng" and EN or RU
	reset()
	w = press_f7()
	client.run("kill", { target = TARGET })
	local f = client.feed()
	check(f[1].kind == "pending", lang .. ": a sent request waits")
	REQUESTS[1].cb(false, "too_far")
	f = client.feed()
	check(f[1].kind == "err" and f[1].text:find(T.st_coop_dbg_err_too_far, 1, true) ~= nil,
		lang .. ": a refusal code is shown translated (" .. tostring(f[1].text) .. ")")
	check(w.feed_rows[1].text.text:find(T.st_coop_dbg_err_too_far, 1, true) ~= nil, lang .. ": the window shows it in its answers")
	client.run("kill", { target = TARGET })
	REQUESTS[2].cb(false, "rate limited")
	check(client.feed()[1].text:find(T.st_coop_dbg_err_rate_limited, 1, true) ~= nil, lang .. ": the engine's 'rate limited' too")
	client.run("time_add", { h = 6 })
	REQUESTS[3].cb(true, { msg = "time +6 h" })
	check(client.feed()[1].kind == "ok" and client.feed()[1].text:find("time +6 h", 1, true) ~= nil, lang .. ": a success shows the server's line")
	client.run("spawn_item", { sec = "wpn_ak74", n = 1, at = "inv" })
	REQUESTS[4].cb(true, "forwarded")
	check(client.feed()[1].kind == "pending" and client.feed()[1].text:find(T.st_coop_dbg_forwarded, 1, true) ~= nil,
		lang .. ": forwarded to a map server: still waiting")
	EVENT["coop.dbg.note"]("ok=1;msg=AK-74 x1", 0)
	check(client.feed()[1].kind == "ok" and client.feed()[1].text:find("AK-74 x1", 1, true) ~= nil, lang .. ": the map server's result comes as a note")
	local n = #client.feed()
	EVENT["coop.dbg.note"]("ok=1;msg=fake", 3)
	check(#client.feed() == n, lang .. ": a note from another player is ignored")
end
T = EN

-------------------------------------------------------------------------------
print("== the server's order: a level change on this machine (registry `level`, K38)")
JUMPS = {}
function JumpToLevel(name) JUMPS[#JUMPS + 1] = name; return name ~= level.name() end
EVENT["coop.dbg.order"]("k=level;name=l02_garbage", 3)
check(#JUMPS == 0, "an order from another player is ignored")
EVENT["coop.dbg.order"]("k=other;name=l02_garbage", 0)
check(#JUMPS == 0, "an order of an unknown kind is ignored")
EVENT["coop.dbg.order"]("k=level;name=../../x", 0)
check(#JUMPS == 0, "a level name that is not a name is ignored")
EVENT["coop.dbg.order"]("k=level;name=l02_garbage", 0)
check(JUMPS[1] == "l02_garbage" and client.feed()[1].kind == "ok", "the server's order runs the stock level change (JumpToLevel)")
EVENT["coop.dbg.order"]("k=level;name=l01_escape", 0)
check(client.feed()[1].kind == "err", "the same level: the stock refuses, the player reads why")

-- Live 2026-11-08 (RL-AMY4-AZXY, heap corruption 0xC0000374 on the new level's script start): the window stayed open
-- through the level change. The stock debug closes its window first (ui_debug_main.script debug_ui:JumpLevel -> OnQuit).
print("== a level change never happens with the co-op window open")
reset()
local open_at_jump
function JumpToLevel(name) open_at_jump = dui.window() ~= nil; JUMPS[#JUMPS + 1] = name; return true end
check(press_f7() ~= nil, "the window is open")
EVENT["coop.dbg.order"]("k=level;name=l05_bar", 0)
check(open_at_jump == false, "the server's level order closes the window before JumpToLevel")
for _, cb in ipairs({ "on_before_level_changing", "on_level_changing" }) do
	reset()
	check(press_f7() ~= nil, cb .. ": the window is open")
	fire(cb)
	check(dui.window() == nil, cb .. " closes the window (a walk through a level changer, a story teleport)")
end
reset()

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
print("== the panel: drag and resize math, clamped to the screen")
do
	local V = { left = -420, top = 0, right = 2340, bottom = 1080 } -- 21:9 in design pixels
	local r0 = { x = 1000, y = 150, w = 872, h = 640 }
	local r = dui.drag_rect(r0, 5000, -900, V)
	check(r.x == V.right - 872 and r.y == 0 and r.w == 872 and r.h == 640, "a drag past the corner stops at the screen's edges, the size kept")
	r = dui.drag_rect(r0, -3000, 2000, V)
	check(r.x == V.left and r.y == 1080 - 640, "past the other corner too (the margin of a wide screen is reachable)")
	r = dui.resize_rect(r0, "l", 600, 0, V)
	check(r.w == dui.MIN_W and r.x + r.w == 1872, "the left edge stops at the least width, the right edge stays")
	r = dui.resize_rect(r0, "rb", 5000, 5000, V)
	check(r.x == 1000 and r.y == 150 and r.x + r.w == V.right and r.y + r.h == V.bottom, "the corner grows to the screen's edges, not past them")
	r = dui.resize_rect(r0, "t", 0, -400, V)
	check(r.y == 0 and r.y + r.h == 790, "the top edge stops at the screen's top, the bottom stays")
	r = dui.clamp_rect({ x = 0, y = 0, w = 9000, h = 9000 }, V)
	check(r.w == 2760 and r.h == 1080 and r.x == V.left, "a size larger than the screen is the screen")
	local small = { left = 0, top = 0, right = 500, bottom = 380 }
	r = dui.clamp_rect({ x = 0, y = 0, w = 900, h = 700 }, small)
	check(r.w == 500 and r.h == 380, "a screen smaller than the least size: the panel is the screen")
	check(dui.hit_zone(r0, 1100, 160, 1600) == "move" and dui.hit_zone(r0, 1700, 160, 1600 - 1000) == "inside",
		"the title bar moves the panel left of its buttons, not over them")
	check(dui.hit_zone(r0, 1001, 400) == "l" and dui.hit_zone(r0, 1870, 400) == "r" and dui.hit_zone(r0, 1500, 788) == "b"
		and dui.hit_zone(r0, 1866, 784) == "rb" and dui.hit_zone(r0, 1001, 151) == "lt", "the edges and the corners resize")
	check(dui.hit_zone(r0, 500, 500) == nil and dui.hit_zone(r0, 1500, 500) == "inside", "outside: nothing; inside: the controls")
end

-------------------------------------------------------------------------------
print("== the panel by the mouse: drag the title, resize the corner, kept on this machine")
reset()
DEBUG.on = true
dui.reset_settings_cache()
w = press_f7()
local L0 = w.ui.L
local function ui_of(px, py) return (px * L0.s + L0.ox) * L0.kx, (py * L0.s + L0.oy) * L0.ky end
local E = ui_events
local r0 = { x = w.rect.x, y = w.rect.y, w = w.rect.w, h = w.rect.h }
CURSOR.x, CURSOR.y = ui_of(r0.x + 60, r0.y + 12)
w:OnMouse(CURSOR.x, CURSOR.y, E.WINDOW_LBUTTON_DOWN)
check(w.drag and w.drag.zone == "move", "a press on the title bar starts a drag")
CURSOR.x, CURSOR.y = ui_of(r0.x - 300, r0.y + 112)
w:OnMouse(CURSOR.x, CURSOR.y, E.WINDOW_MOUSE_MOVE)
check(math.abs(w.rect.x - (r0.x - 360)) < 1e-6 and math.abs(w.rect.y - (r0.y + 100)) < 1e-6, string.format("the panel follows the cursor (%.1f %.1f)", w.rect.x, w.rect.y))
w:OnMouse(CURSOR.x, CURSOR.y, E.WINDOW_LBUTTON_UP)
check(w.drag == nil and tonumber(axr_main.config.data["coop_debug_ui&x"]) == w.rect.x, "the release ends it and the place is saved on this machine")
local r1 = { x = w.rect.x, y = w.rect.y, w = w.rect.w, h = w.rect.h }
CURSOR.x, CURSOR.y = ui_of(r1.x + r1.w - 4, r1.y + r1.h - 4)
w:OnMouse(CURSOR.x, CURSOR.y, E.WINDOW_LBUTTON_DOWN)
check(w.drag and w.drag.zone == "rb", "a press on the corner grip starts a resize")
CURSOR.x, CURSOR.y = ui_of(r1.x + r1.w - 4 - 200, r1.y + r1.h - 4 - 120)
NOW = NOW + 100
w:OnMouse(CURSOR.x, CURSOR.y, E.WINDOW_MOUSE_MOVE)
w:OnMouse(CURSOR.x, CURSOR.y, E.WINDOW_LBUTTON_UP)
check(math.abs(w.rect.w - (r1.w - 200)) < 1e-6 and math.abs(w.rect.h - (r1.h - 120)) < 1e-6 and w.rect.x == r1.x, "the corner makes it smaller, the top left stays")
local saved = { x = w.rect.x, y = w.rect.y, w = w.rect.w, h = w.rect.h }
dui.close()
dui.reset_settings_cache()
w = press_f7()
check(math.abs(w.rect.x - saved.x) < 1e-6 and math.abs(w.rect.w - saved.w) < 1e-6 and math.abs(w.rect.h - saved.h) < 1e-6,
	"a new window (and a new game: the cache dropped) opens where it was left, at its size")
check(axr_main.config.data["options&coop/coop_debug_ui/x"] == nil, "kept in its own section of the options, not under the host-shared [options]")

-------------------------------------------------------------------------------
print("== reflow: every page at several screens and sizes, nothing overlaps, nothing leaves the body")
local function overlap(a, b)
	return a.x < b.x + b.w - .01 and b.x < a.x + a.w - .01 and a.y < b.y + b.h - .01 and b.y < a.y + a.h - .01
end
local screens = { { 1024, 768, "4:3" }, { 1680, 1050, "16:10" }, { 1920, 1080, "16:9" }, { 2560, 1080, "21:9" }, { 3840, 2160, "4K" } }
local bad_layout, layouts = {}, 0
for _, sc in ipairs(screens) do
	SCREEN.w, SCREEN.h = sc[1], sc[2]
	for _, dens in ipairs({ "compact", "normal", "large" }) do
		reset()
		dui.reset_settings_cache()
		local S = dui.get_settings()
		S.density = dens
		w = press_f7()
		local V = w.view
		for _, size in ipairs({ { 0, 0 }, { 872, 640 }, { 9999, 9999 }, { 700, 900 } }) do
			w:SetRect({ x = V.left + 10, y = V.top + 10, w = size[1], h = size[2] }, true)
			local r = w.rect
			if r.x < V.left - 1e-6 or r.y < V.top - 1e-6 or r.x + r.w > V.right + 1e-6 or r.y + r.h > V.bottom + 1e-6 then
				bad_layout[#bad_layout + 1] = sc[3] .. " panel off the screen"
			end
			for _, pid in ipairs(w:page_ids()) do
				w:select_page(pid)
				layouts = layouts + 1
				local B = w.body_rect
				local list = w.placed[pid] or {}
				for i, a in ipairs(list) do
					if a.x < -1e-6 or a.y < -1e-6 or a.x + a.w > B.w + 1e-6 or a.y + a.h > B.h + 1e-6 then
						bad_layout[#bad_layout + 1] = string.format("%s %s %dx%d %s: %s outside (%.0f,%.0f %.0fx%.0f in %.0fx%.0f)", sc[3], dens,
							r.w, r.h, pid, a.name, a.x, a.y, a.w, a.h, B.w, B.h)
					end
					for j = i + 1, #list do
						if overlap(a, list[j]) then
							bad_layout[#bad_layout + 1] = string.format("%s %s %dx%d %s: %s over %s", sc[3], dens, r.w, r.h, pid, a.name, list[j].name)
						end
					end
				end
			end
		end
	end
end
SCREEN.w, SCREEN.h = 1920, 1080
check(#bad_layout == 0, "every page laid out " .. layouts .. " times without overlaps and inside its body (" .. table.concat(bad_layout, " | ", 1, math.min(#bad_layout, 6)) .. ")")
reset()
dui.reset_settings_cache()
w = press_f7()
w:SetRect({ x = 0, y = 0, w = 0, h = 0 }, true)
w:select_page("spawn")
local LS2 = w.lists.spawn
check(#LS2.rows == LS2.vis and LS2.vis >= 3, "the list keeps a pool of the visible rows only (" .. #LS2.rows .. ")")
w:SetRect({ x = 0, y = 0, w = 9999, h = 9999 }, true)
check(LS2.vis > 20 and #LS2.rows == LS2.vis, "a taller panel shows more rows: the pool grows to them (" .. LS2.vis .. ")")

-------------------------------------------------------------------------------
print("== catalogs: filled from the system ini, categories, search (Cyrillic too), sort, favourites")
dui.reset_catalogs()
local cats = {}
for _, e in ipairs(dui.catalog("items")) do cats[e.sec] = e.cat end
check(cats.wpn_ak74 == "weapons" and cats["ammo_5.45x39_fmj"] == "ammo" and cats.stalker_outfit == "outfits" and cats.af_medusa == "artefacts"
	and cats.medkit == "consumables" and cats.wpn_addon_scope == "addons" and cats.device_torch == "other",
	"every item category is filled from the classes")
check(cats.wpn_ak74_alt == nil and cats.mp_wpn_ak74 == nil and cats.sim_squad_bandit == nil, "weapon variants, multiplayer sections and squads are not items")
local ak = nil
for _, e in ipairs(dui.catalog("items")) do if e.sec == "wpn_ak74" then ak = e end end
check(ak and ak.name == "AK-74" and ak.icon and ak.icon.x == 500 and ak.icon.y == 200 and ak.icon.w == 250 and ak.icon.h == 100
	and ak.icon.tex == "ui\\ui_icon_equipment", "an item has its name and its inventory icon (inv_grid_* x 50 on ui_icon_equipment)")
local npcs = {}
for _, e in ipairs(dui.catalog("npc")) do npcs[e.sec] = e.cat end
check(npcs.sim_squad_bandit == "squads_stalker" and npcs.sim_squad_bloodsucker == "squads_mutant" and npcs.bloodsucker_weak == "mutants"
	and npcs.story_squad == nil, "NPC: stalker squads, mutant squads, mutants; story squads left out")
check(#dui.filter("items", "weapons", "", "name") == 2 and #dui.filter("items", "all", "ak 74u", "name") == 1,
	"a category and a query of several words")
local ru = dui.filter("items", "all", "\224\239\242\229\247\234\224", "name") -- "aptechka" in small Cyrillic letters
check(#ru == 1 and ru[1].sec == "medkit", "the search finds a Russian name typed in small letters")
local by_sec = dui.filter("items", "all", "", "section")
check(by_sec[1].sec == "af_medusa" and dui.filter("items", "all", "", "name")[1].sec == "ammo_5.45x39_fmj", "sort by section or by name")
check(dui.toggle_fav("i:medkit") == true and dui.toggle_fav("l:l02_garbage") == true, "a star on an item and on a level")
dui.reset_settings_cache()
local favs = dui.catalog("favs")
check(#favs == 2 and #dui.filter("items", "fav", "", "name") == 1, "the starred ones are kept on this machine and listed in Favourites")
reset()
w = press_f7()
w:select_page("favs")
check(#w.lists.favs.list == 2, "the Favourites page lists them")
click(w, "btn_row_favs_1")
click(w, "btn_fav_favs")
check(#dui.catalog("favs") == 1, "the star turns off from the details pane")
dui.toggle_fav("l:l02_garbage")

-- the speed of the catalogs on thousands of sections: built once, filtered fast
local keep_sections = SECTIONS
SECTIONS = {}
for k, v in pairs(keep_sections) do SECTIONS[k] = v end
for i = 1, 6000 do
	SECTIONS["wpn_test_" .. i] = { class = (i % 3 == 0) and "AMMO" or (i % 3 == 1 and "II_MEDKI" or "WP_AK74"), inv_weight = "1", inv_name = "st_test",
		inv_grid_width = "2", inv_grid_height = "1" }
end
dui.reset_catalogs()
local t0 = os.clock()
local n_items = #dui.catalog("items")
local t_build = (os.clock() - t0) * 1000
t0 = os.clock()
for _ = 1, 10 do dui.filter("items", "all", "test_12", "name") end
local t_filter = (os.clock() - t0) * 100
t0 = os.clock()
dui.catalog("items")
local t_again = (os.clock() - t0) * 1000
print(string.format("    catalog of %d items: built in %.1f ms, a search in %.2f ms, the second look %.3f ms", n_items, t_build, t_filter, t_again))
check(n_items > 6000 and t_build < 400 and t_filter < 25 and t_again < 1, "6000+ sections: built once in < 400 ms, a search < 25 ms, then cached")
SECTIONS = keep_sections
dui.reset_catalogs()

-------------------------------------------------------------------------------
print("== settings: opacity, blur (only when the renderer has it), density, walking while open")
reset()
dui.reset_settings_cache()
dui.reset_blur_probe()
local base_window = window
window = function(path)
	local x = base_window(path)
	if path == "tpl_image" then
		function x:GetTextureSize()
			local k = self.texture and tonumber(tostring(self.texture):match("^%$user%$blur_(%d)$"))
			if k then return { x = SCREEN.w / k, y = SCREEN.h / k } end
			return { x = 0, y = 0 }
		end
	end
	return x
end
w = press_f7()
check(w.blur_on == true and w.blur_img.texture == "$user$blur_4" and w.blur_img.shown ~= false, "R4: the medium blur is the renderer's quarter-size blurred frame")
local L1 = w.ui.L
local x1, y1, x2, y2 = L1:rect(w.rect.x, w.rect.y, w.rect.w, w.rect.h)
local tr_ = w.blur_img.trect
check(tr_ and math.abs(tr_.x1 - x1 * 1920 / 1024 / 4) < 1e-6 and math.abs(tr_.y2 - y2 * 1080 / 768 / 4) < 1e-6,
	"only the part of the frame under the panel (its screen pixels / 4), never the whole screen")
click(w, "btn_settings")
check(w.popover == true and w.pop.root.shown ~= false, "the View button opens the settings popover")
click(w, "btn_set_op_60")
click(w, "btn_set_blur_3")
check(dui.get_settings().opacity == 60 and w.blur_img.texture == "$user$blur_8" and axr_main.config.data["coop_debug_ui&blur"] == "3",
	"opacity and blur strength apply at once and are saved")
click(w, "btn_set_move_0")
check(dui.get_settings().move == false and axr_main.config.data["coop_debug_ui&move"] == "false", "walking while open: a setting")
click(w, "btn_set_dens_compact")
w:Update()
local w2 = dui.window()
check(w2 ~= w and w2 ~= nil and w2.D.row == dui.DENSITY.compact.row, "density: the window is built again, denser")
w = w2
RENDERER = "renderer_r1"
dui.reset_blur_probe()
reset()
w = press_f7()
check(w.blur_on == false and w.blur_img.shown == false, "R1 (no blurred frame): tinted glass only")
click(w, "btn_settings")
check(w.pop.blur.btns[2].enabled == false and w.pop.blur.note.shown ~= false, "the blur choices say they are not available here")
RENDERER = "renderer_r4"
window = base_window
dui.reset_blur_probe()
dui.get_settings().density, dui.get_settings().move, dui.get_settings().opacity, dui.get_settings().blur = "normal", true, 80, 2

-------------------------------------------------------------------------------
print("== the feed: the server's reason in full")
reset()
w = press_f7()
client.run("kill", { target = TARGET })
REQUESTS[1].cb(false, { code = "bad_args", msg = "n must be 1..20, got 50" })
local f1 = client.feed()[1]
check(f1.kind == "err" and f1.text:find(EN.st_coop_dbg_err_bad_args, 1, true) and f1.text:find("n must be 1..20, got 50", 1, true),
	"a refusal with the server's words: the player's line and the words (" .. f1.text .. ")")
client.run("kill", { target = TARGET })
REQUESTS[2].cb(false, "too_far: 312 m, the limit is 150 m and this has to be a long reason so that it does not fit in one line of the feed")
check(client.feed()[1].text:find("312 m", 1, true) ~= nil, "a refusal 'code: why' keeps the why")
w:BindFeed()
check(w.feed_rows[1].full.shown ~= false and w.feed_rows[1].text.shown == false and w.feed_rows[1].full.text:find("one line of the feed", 1, true),
	"the newest long refusal is shown whole on two lines, not cut")

print("== the window's strings exist in both tables")
local used = {}
for _, name in ipairs({ "coop_debug_client", "coop_debug_ui" }) do
	local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "rb"))
	for id in fh:read("*a"):gmatch('"(st_coop_dbg_[%w_]+)"') do used[id] = true end
	fh:close()
end
for _, a in ipairs(client.ACTIONS) do used["st_coop_dbg_a_" .. a.id] = true end
for _, code in ipairs(client.ERROR_CODES) do used["st_coop_dbg_err_" .. code] = true end
for id in pairs(ASKED) do used[id] = true end
for _, a in ipairs(client.ACTIONS) do if a.confirm then used["st_coop_dbg_confirm_" .. a.id] = true end end
used.st_coop_dbg_say_prefix = true
for _, list in pairs(dui.CATS) do for _, c in ipairs(list) do used["st_coop_dbg_cat_" .. c] = true end end
for _, id in ipairs(dui.PAGES_ON) do used["st_coop_dbg_page_" .. id] = true end
for _, d in ipairs({ "compact", "normal", "large" }) do used["st_coop_dbg_set_dens_" .. d] = true end
for i = 1, 3 do used["st_coop_dbg_set_blur_" .. i] = true end -- coop_debug_server (package 2) prefixes the chat announcements with it
local missing = {}
for id in pairs(used) do
	if not id:match("_$") and (not EN[id] or not RU[id]) then missing[#missing + 1] = id end
end
table.sort(missing)
check(#missing == 0, "every st_coop_dbg_* id is in eng and rus (" .. table.concat(missing, ",") .. ")")
check(#MISSING_PATHS == 0, "every template the window asks for is in ui_coop_debug.xml (" .. table.concat(MISSING_PATHS, ",") .. ")")

print(string.format("DEBUG_CLIENT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
