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
	return T[id] or id
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

-- the system ini for the section search: an item, a squad, a thing without a class
SECTIONS = { wpn_ak74 = { class = "WP_AK74", inv_weight = "3" }, wpn_ak74u = { class = "WP_AK74", inv_weight = "2.7" },
	medkit = { class = "II_MEDKI", inv_weight = ".1" }, simulation_bandit_3 = { class = "ON_OFF_S" }, actor_condition = {} }
ini_sys = {}
function ini_sys:section_exist(s) return SECTIONS[s] ~= nil end
function ini_sys:line_exist(s, k) return SECTIONS[s] ~= nil and SECTIONS[s][k] ~= nil end
function ini_sys:section_for_each(f) for s in pairs(SECTIONS) do f(s) end end
function ini_sys:r_string_ex(s, k) return SECTIONS[s] and SECTIONS[s][k] end

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
check(w.state_text.text == EN.st_coop_dbg_state_off, "off: the state line says so")
check(w.registered.btn_server_toggle == nil, "not the server: no on/off button")

-------------------------------------------------------------------------------
print("== the operator's switch is the server console")
reset()
ROLE, OPERATOR = "host", true
w = press_f7()
check(w.registered.btn_server_toggle ~= nil, "operator: the on/off button is there")
click(w, "btn_server_toggle")
check(CONSOLE[1] == "coop_debug on", "operator: the button runs the console command coop_debug on (" .. tostring(CONSOLE[1]) .. ")")
check(w.state_text.text == EN.st_coop_dbg_state_pending, "operator: waiting for the server after the click")
DEBUG.on, DEBUG.source = true, 2
fire("coop_debug_changed", true, 2)
w = dui.window()
check(w ~= nil and w.state_text.text == EN.st_coop_dbg_state_on, "the new state rebuilds the open window: on")
check(#w:page_ids() == 6, "on: overview, target, spawn, me, world, help")
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

-- the spawn page: search, then one click
REQUESTS = {}
w:select_page("spawn")
w.spawn_edit:SetText("ak74")
w:Update()
check(w.found[1] == "wpn_ak74" and w.found[2] == "wpn_ak74u" and #w.found == 2, "the section search finds the items by a part of the name")
click(w, "btn_found_1")
click(w, "btn_spawn_go")
r = REQUESTS[1]
check(r and r.args.cmd == "spawn_item" and r.args.sec == "wpn_ak74" and r.args.at == "inv", "the spawn button sends the picked item")
REQUESTS = {}
w.spawn_edit:SetText("simulation_bandit_3")
w:Update()
click(w, "btn_where_point")
click(w, "btn_spawn_go")
r = REQUESTS[1]
check(r and r.name == "coop.dbg.spawn" and r.args.cmd == "spawn_object" and r.args.at == "point" and r.args.lv == 5555,
	"a section without an inventory weight is an object: spawn_object at the point")

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

-------------------------------------------------------------------------------
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
used.st_coop_dbg_say_prefix = true -- coop_debug_server (package 2) prefixes the chat announcements with it
local missing = {}
for id in pairs(used) do
	if not id:match("_$") and (not EN[id] or not RU[id]) then missing[#missing + 1] = id end
end
table.sort(missing)
check(#missing == 0, "every st_coop_dbg_* id is in eng and rus (" .. table.concat(missing, ",") .. ")")
check(#MISSING_PATHS == 0, "every template the window asks for is in ui_coop_debug.xml (" .. table.concat(MISSING_PATHS, ",") .. ")")

print(string.format("DEBUG_CLIENT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
