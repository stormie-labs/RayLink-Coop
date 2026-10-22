-- Anomaly Coop F3 hotfix temp test: tents and sleeping bags on a co-op client (scripts\coop_tent_guard.script,
-- configs\text\{eng,rus}\st_coop_tent.xml). Not shipped.
-- Stock facts (anomaly-ref item_tent.script): on a client alife_create without a parent returns nil, so itm_tent_func
-- (a level.add_call functor, no pcall) indexes nil -> FATAL; the sleeping bag branch of the local actor_on_item_use fails the
-- same way. The guard replaces the entry points of the item_tent module table on a client and leaves host / single player alone.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")

local ENTRY = { "start_timer", "itm_tent_func", "itm_tent_bag_func", "use_compression_bag", "func_use_bag", "func_use_tent" }

-- ------------------------------------------------------------------ stand-ins
ADD_CALLS = {}
level.add_call = function(cond, f) ADD_CALLS[#ADD_CALLS + 1] = f end
level.map_add_object_spot_ser = function() end
ui_options = { get = function() return false end }
actor_effects = { play_item_fx = function() end }
function hide_hud_inventory() end

-- the stock module registers its local use callback; keep our own list so that each test starts from a clean one
USE_CB = {}
local real_register = RegisterScriptCallback
function RegisterScriptCallback(name, f)
	if name == "actor_on_item_use" then USE_CB[#USE_CB + 1] = f else real_register(name, f) end
end
local function fire_use(obj) for _, f in ipairs(USE_CB) do f(obj) end end

-- alife_create as a client's engine answers it: a spawn without a parent is the host's job, the result is nil
local world_create = alife_create
ALIFE_CREATE = 0
function alife_create(sec, pos, lv, gv, parent)
	ALIFE_CREATE = ALIFE_CREATE + 1
	if MODE == "client" and parent == nil then return nil end
	return world_create(sec, pos, lv, gv, parent)
end

TR = {}      -- string table: id -> text
ASKED = {}   -- ids the script asked game.translate_string for
game.translate_string = function(id) ASKED[#ASKED + 1] = id; return TR[id] or id end

local function reset()
	CREATED, RELEASED, ADD_CALLS, TIMEEV, LOG, USE_CB = {}, {}, {}, {}, {}, {}
	ALIFE_CREATE, HUD, ASKED = 0, nil, {}
	SE, OBJ = {}, {}
	make_actor(vec3(0, 0, 0))
	TR = {}
	MODE = "host"
	NEAR_TENT, NEAR_BAG = nil, nil
end

local function item(sec)
	local se, o = spawn(sec, vec3(0, 0, 0), 0)
	return se, o
end

local function created_secs()
	local t = {}
	for _, c in ipairs(CREATED) do t[#t + 1] = c.sec .. "<" .. tostring(c.parent) end
	return table.concat(t, ",")
end

-- the text the guard shows when nothing is translated (fallback) must be a real sentence, not the string id
local function hud_is_fallback() return type(HUD) == "string" and #HUD > 20 and HUD ~= "st_coop_tent_blocked" end

-- ------------------------------------------------------------------ part 1: the wrappers around recorder functions
print("== guard loaded before the module exists")
reset()
load_script("coop_tent_guard")
check(type(coop_tent_guard) == "table", "coop_tent_guard loads")
local ok, e = pcall(coop_tent_guard.on_game_start)
check(ok, "on_game_start without item_tent does not throw (" .. tostring(e) .. ")")

-- a module with the stock public shape; every entry point records its calls and returns something
CALLS = {}
local function recorder_module()
	local m = {}
	for _, name in ipairs(ENTRY) do
		m[name] = function(...)
			CALLS[#CALLS + 1] = { name = name, n = select("#", ...), ... }
			return name .. ":ret", 2
		end
	end
	m.get_nearby_tent = function() return "nearby" end
	m.get_spawned_tents = function() return { [7] = true } end
	m.on_game_start = function() end
	return m
end
local ORIG = recorder_module()
item_tent = ORIG
local before = {}
for _, name in ipairs(ENTRY) do before[name] = item_tent[name] end

print("== installed by on_game_start when the module shows up later")
local gnt, gst = ORIG.get_nearby_tent, ORIG.get_spawned_tents
coop_tent_guard.on_game_start()
for _, name in ipairs(ENTRY) do
	check(item_tent[name] ~= before[name] and type(item_tent[name]) == "function", name .. " is wrapped")
end
check(item_tent.get_nearby_tent == gnt and item_tent.get_spawned_tents == gst,
	"get_nearby_tent / get_spawned_tents stay (the sleep dialogs read them)")
local first = {}
for _, name in ipairs(ENTRY) do first[name] = item_tent[name] end
coop_tent_guard.on_game_start()
local twice = true
for _, name in ipairs(ENTRY) do if item_tent[name] ~= first[name] then twice = false end end
check(twice, "a second on_game_start does not wrap again")

print("== installed at load time when the module is already there")
reset()
item_tent = recorder_module()
local plain = {}
for _, name in ipairs(ENTRY) do plain[name] = item_tent[name] end
coop_tent_guard = nil
load_script("coop_tent_guard")
local at_load = true
for _, name in ipairs(ENTRY) do if item_tent[name] == plain[name] then at_load = false end end
check(at_load, "all six entry points are wrapped as soon as the script loads")
coop_tent_guard.on_game_start()
local at_start = true
for _, name in ipairs(ENTRY) do if item_tent[name] == plain[name] then at_start = false end end
check(at_start and item_tent.start_timer ~= nil, "on_game_start keeps them wrapped")

-- the wrappers sit on top of the recorders; call them
local orig_of = {}
for _, name in ipairs(ENTRY) do orig_of[name] = plain[name] end

local function arg_obj(sec) local _, o = item(sec); return o end

print("== host: stock behaviour untouched")
for _, mode in ipairs({ "host", "sp" }) do
	reset()
	MODE = mode
	CALLS = {}
	local o = arg_obj("itm_tent")
	local r1, r2 = item_tent.func_use_tent(o)
	check(#CALLS == 1 and CALLS[1].name == "func_use_tent" and CALLS[1][1] == o, mode .. ": func_use_tent reaches the stock function with the item")
	check(r1 == "func_use_tent:ret" and r2 == 2, mode .. ": its return values come back")
	item_tent.func_use_bag(arg_obj("itm_sleepbag"))
	item_tent.start_timer(arg_obj("itm_tent"))
	item_tent.start_timer(arg_obj("itm_tent_bag"))
	item_tent.use_compression_bag(arg_obj("compression_bag"), 1.5)
	item_tent.itm_tent_func()
	item_tent.itm_tent_bag_func()
	local names = {}
	for _, c in ipairs(CALLS) do names[#names + 1] = c.name end
	check(table.concat(names, ",") == "func_use_tent,func_use_bag,start_timer,start_timer,use_compression_bag,itm_tent_func,itm_tent_bag_func",
		mode .. ": all seven calls reach the stock functions (" .. table.concat(names, ",") .. ")")
	check(CALLS[5][2] == 1.5 and CALLS[5].n == 2, mode .. ": use_compression_bag keeps its second argument")
	check(HUD == nil and #CREATED == 0 and ALIFE_CREATE == 0, mode .. ": no message, nothing spawned by the guard")
end

print("== client: stock never runs")
reset()
MODE = "client"
CALLS = {}
do
	local se, o = item("itm_tent")
	local r = item_tent.func_use_tent(o)
	run_time_events(300)
	check(#CALLS == 0, "func_use_tent: the stock function is not called")
	check(r == nil, "func_use_tent returns nothing")
	check(ALIFE_CREATE == 0 and #CREATED == 0, "func_use_tent: alife_create is not called, nothing is created")
	check(SE[se.id] ~= nil and OBJ[se.id] ~= nil and #RELEASED == 0, "func_use_tent: the tent stays in the inventory")
	check(hud_is_fallback(), "func_use_tent: the player gets a message (fallback text: " .. tostring(HUD) .. ")")
	check(ASKED[1] == "st_coop_tent_blocked", "the message is the string st_coop_tent_blocked")
end
do
	reset()
	MODE = "client"
	TR.st_coop_tent_blocked = "TRANSLATED"
	local se, o = item("itm_sleepbag")
	item_tent.func_use_bag(o)
	run_time_events(300)
	check(#CALLS == 0 and ALIFE_CREATE == 0 and #CREATED == 0, "func_use_bag: stock not called, nothing spawned")
	check(SE[se.id] ~= nil and #RELEASED == 0, "func_use_bag: the sleeping bag stays")
	check(HUD == "TRANSLATED", "func_use_bag: the translated message is shown")
end
do
	reset()
	MODE = "client"
	item_tent.func_use_tent(nil)
	check(#CALLS == 1 and CALLS[1].name == "func_use_tent", "func_use_tent(nil): stock call as is (it does nothing for nil)")
	CALLS = {}
end
for _, sec in ipairs({ "itm_tent", "itm_tent_bag" }) do
	reset()
	MODE = "client"
	local se, o = item(sec)
	item_tent.start_timer(o)
	check(#CALLS == 0 and #ADD_CALLS == 0, "start_timer(" .. sec .. "): no timer functor is queued, stock not called")
	check(ALIFE_CREATE == 0, "start_timer(" .. sec .. "): alife_create is not called")
	check(created_secs() == sec .. "<0", "start_timer(" .. sec .. "): the engine has eaten the item, one copy is returned (" .. created_secs() .. ")")
	check(hud_is_fallback(), "start_timer(" .. sec .. "): message shown")
end
do
	reset()
	MODE = "client"
	item_tent.start_timer(arg_obj("bolts_pack"))
	check(#CALLS == 1 and CALLS[1].name == "start_timer" and HUD == nil and #CREATED == 0, "start_timer of another section: stock call, no message, no item")
	CALLS = {}
end
do
	reset()
	MODE = "client"
	local _, o = item("compression_bag")
	item_tent.use_compression_bag(o, 1.5)
	check(#CALLS == 0 and ALIFE_CREATE == 0 and #RELEASED == 0, "use_compression_bag: stock not called, nothing released")
	check(created_secs() == "compression_bag<0", "use_compression_bag: the compression bag is returned (" .. created_secs() .. ")")
	check(hud_is_fallback(), "use_compression_bag: message shown")
	reset()
	MODE = "client"
	item_tent.use_compression_bag(nil, 1.5)
	check(#CALLS == 0 and #CREATED == 0 and hud_is_fallback(), "use_compression_bag(nil): message, no item invented")
end
do
	reset()
	MODE = "client"
	item_tent.itm_tent_func()
	item_tent.itm_tent_bag_func()
	check(#CALLS == 0 and ALIFE_CREATE == 0 and #CREATED == 0 and #RELEASED == 0, "the timer functors do nothing on a client")
end
do
	-- the engine refuses to give the item back: the guard must not throw out of the use handler
	reset()
	MODE = "client"
	local real = alife_create_item
	alife_create_item = function() error("no parent") end
	local _, o = item("itm_tent")
	local ok2 = pcall(item_tent.start_timer, o)
	alife_create_item = real
	check(ok2, "a failed give-back does not throw")
end

print("== role switches at call time")
reset()
CALLS = {}
MODE = "client"
item_tent.func_use_tent(arg_obj("itm_tent"))
check(#CALLS == 0, "client: blocked")
MODE = "host"
item_tent.func_use_tent(arg_obj("itm_tent"))
check(#CALLS == 1, "the same wrapper passes through on the host")
MODE = "sp"
item_tent.func_use_tent(arg_obj("itm_tent"))
check(#CALLS == 2, "and in single player")

print("== exe without co-op: nothing is wrapped")
do
	local saved = coop
	coop = nil
	item_tent = recorder_module()
	local p = {}
	for _, name in ipairs(ENTRY) do p[name] = item_tent[name] end
	coop_tent_guard = nil
	load_script("coop_tent_guard")
	coop_tent_guard.on_game_start()
	local same = true
	for _, name in ipairs(ENTRY) do if item_tent[name] ~= p[name] then same = false end end
	check(same, "no co-op API: the module is left alone")
	coop = saved
end

-- ------------------------------------------------------------------ part 2: the stock logic in a real module environment
-- A faithful miniature of item_tent.script (same names, same globals, same local actor_on_item_use) loaded the way the
-- engine loads a script (module table = environment, __index = _G), so that the lookup of start_timer & co. from inside
-- the local function goes through the module table the guard writes to.
print("== stock shape: module environment")
local MINI = [[
local spawned_tents = {}
local spawned_sleepbags = {}

function start_timer(obj)
	local iTimer = time_global()
	local function check_timer() return time_global() > iTimer end
	if (obj:section() == "itm_tent") then level.add_call(check_timer, itm_tent_func) end
	if (obj:section() == "itm_tent_bag") then level.add_call(check_timer, itm_tent_bag_func) end
end

function itm_tent_func()
	local pos = db.actor:position()
	local se_obj = alife_create("ph_tent", pos, 1, db.actor:game_vertex_id())
	level.map_add_object_spot_ser(se_obj.id, "ui_pda2_actor_sleep_location", "tent")
	spawned_tents[se_obj.id] = true
	alife_create_item("itm_tent_bag", db.actor)
end

function get_nearby_tent(dist, result)
	if NEAR_TENT then return result and NEAR_TENT or true end
end

function itm_tent_bag_func()
	local id = get_nearby_tent(3.5, true)
	local se_obj = id and alife_object(id)
	if se_obj then
		local obj_tent = db.actor:object("itm_tent_bag")
		local se_tent = obj_tent and obj_tent:id() and alife_object(obj_tent:id())
		if se_tent then
			alife_create_item("itm_tent", db.actor)
			alife_release(se_obj)
			alife_release(se_tent)
			spawned_tents[id] = nil
		end
	end
end

function use_compression_bag(obj_c, dist)
	if NEAR_BAG then
		local se_comp = obj_c and obj_c:id() and alife_object(obj_c:id())
		local se_sleepbag = alife_object(NEAR_BAG)
		if se_comp and se_sleepbag then
			alife_create_item("itm_sleepbag", db.actor)
			alife_release(se_comp)
			alife_release(se_sleepbag)
		end
	end
end

function get_spawned_tents() return spawned_tents end

local function actor_on_item_use(obj)
	local sec = obj:section()
	if (sec == "itm_tent") or (sec == "itm_tent_bag" and get_nearby_tent(3.5, true)) then
		actor_effects.play_item_fx("itm_sleepbag")
		start_timer(obj)
	end
	if (sec == "itm_sleepbag") then
		local se_obj = alife_create("ph_sleepbag", db.actor:position(), db.actor:level_vertex_id(), db.actor:game_vertex_id())
		level.map_add_object_spot_ser(se_obj.id, "ui_pda2_actor_sleep_location", "bag")
		spawned_sleepbags[se_obj.id] = true
		alife_create_item("compression_bag", db.actor)
	end
	if (sec == "compression_bag") then use_compression_bag(obj, 1.5) end
end

local function release_later(obj)
	CreateTimeEvent(0, "release_" .. obj:id(), 0, function(x)
		local se = alife_object(x)
		_ = se and alife_release(se)
		return true
	end, obj:id())
end

function func_use_bag(obj)
	if obj then actor_on_item_use(obj); release_later(obj) end
end
function func_use_tent(obj)
	if obj then actor_on_item_use(obj); release_later(obj) end
end

function on_game_start()
	RegisterScriptCallback("actor_on_item_use", actor_on_item_use)
end
]]

local function load_mini()
	local header = 'local this = {} item_tent = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	local f = assert(loadstring(header .. MINI, "@D:\\Games\\Anomaly\\gamedata\\scripts\\item_tent.script"))
	f()
	return item_tent
end

-- the engine runs the level.add_call functors on a later frame with no pcall: an error is fatal
local function run_add_calls()
	local list = ADD_CALLS
	ADD_CALLS = {}
	for _, f in ipairs(list) do f() end
end

-- before the guard: the client breaks exactly where the recon says it does
reset()
load_mini()
MODE = "client"
do
	local _, o = item("itm_tent")
	item_tent.func_use_tent(o)
	check(#ADD_CALLS == 1, "unguarded client: the tent timer functor is queued")
	local ok3, err3 = pcall(run_add_calls)
	check(not ok3 and tostring(err3):find("nil", 1, true) ~= nil, "unguarded client: itm_tent_func indexes the nil from alife_create (" .. tostring(err3) .. ")")
end
reset()
load_mini()
MODE = "client"
do
	local _, o = item("itm_sleepbag")
	local ok3 = pcall(item_tent.func_use_bag, o)
	check(not ok3, "unguarded client: the sleeping bag branch fails on the nil")
end

-- with the guard (installed over the module the way coop_tent_guard.on_game_start does it)
reset()
load_mini()
coop_tent_guard = nil
load_script("coop_tent_guard")
coop_tent_guard.on_game_start()
item_tent.on_game_start() -- the stock module registers its local use callback

print("== stock shape: GAMMA action functors (client)")
MODE = "client"
do
	local se, o = item("itm_tent")
	item_tent.func_use_tent(o)
	run_time_events(300)
	local ok3, err3 = pcall(run_add_calls)
	check(ok3 and #ADD_CALLS == 0, "func_use_tent: no timer functor, nothing fatal (" .. tostring(err3) .. ")")
	check(ALIFE_CREATE == 0 and #CREATED == 0, "func_use_tent: nothing spawned")
	check(SE[se.id] ~= nil and #RELEASED == 0, "func_use_tent: the tent is not released")
	check(hud_is_fallback(), "func_use_tent: message shown")
end
reset()
load_mini()
coop_tent_guard = nil
load_script("coop_tent_guard")
item_tent.on_game_start()
MODE = "client"
do
	local se, o = item("itm_sleepbag")
	local ok3, err3 = pcall(item_tent.func_use_bag, o)
	run_time_events(300)
	check(ok3, "func_use_bag: no error (" .. tostring(err3) .. ")")
	check(ALIFE_CREATE == 0 and #CREATED == 0, "func_use_bag: ph_sleepbag and compression_bag are not created")
	check(SE[se.id] ~= nil and #RELEASED == 0, "func_use_bag: the sleeping bag is not released")
	check(hud_is_fallback(), "func_use_bag: message shown")
end

print("== stock shape: use callback (items the engine eats) on a client")
reset()
load_mini()
coop_tent_guard = nil
load_script("coop_tent_guard")
item_tent.on_game_start()
MODE = "client"
do
	-- itm_tent_bag next to a tent: start_timer inside the local callback reaches the wrapper through the module table
	local _, tent = spawn("ph_tent", vec3(1, 0, 0))
	NEAR_TENT = tent:id()
	local _, o = item("itm_tent_bag")
	local ok3, err3 = pcall(fire_use, o)
	check(ok3, "itm_tent_bag callback: no error (" .. tostring(err3) .. ")")
	check(#ADD_CALLS == 0, "itm_tent_bag callback: no timer functor")
	check(created_secs() == "itm_tent_bag<0", "itm_tent_bag callback: the bag is returned (" .. created_secs() .. ")")
	check(#RELEASED == 0 and OBJ[tent:id()] ~= nil, "itm_tent_bag callback: the foreign tent is not released (no duplicate)")
	check(hud_is_fallback(), "itm_tent_bag callback: message shown")
end
reset()
load_mini()
coop_tent_guard = nil
load_script("coop_tent_guard")
item_tent.on_game_start()
MODE = "client"
do
	local _, bag = spawn("ph_sleepbag", vec3(1, 0, 0))
	NEAR_BAG = bag:id()
	local _, o = item("compression_bag")
	local ok3, err3 = pcall(fire_use, o)
	check(ok3 and #RELEASED == 0, "compression_bag callback: no error, the placed sleeping bag is not released (" .. tostring(err3) .. ")")
	check(created_secs() == "compression_bag<0", "compression_bag callback: the compression bag is returned, no itm_sleepbag (" .. created_secs() .. ")")
	check(hud_is_fallback(), "compression_bag callback: message shown")
end

print("== stock shape: host runs the stock logic")
reset()
load_mini()
coop_tent_guard = nil
load_script("coop_tent_guard")
item_tent.on_game_start()
MODE = "host"
do
	local _, o = item("itm_tent")
	item_tent.func_use_tent(o)
	check(#ADD_CALLS == 1, "host: func_use_tent queues the stock timer functor")
	run_add_calls()
	run_time_events(300)
	check(ALIFE_CREATE == 1 and created_secs():find("ph_tent<nil", 1, true) and created_secs():find("itm_tent_bag<0", 1, true),
		"host: ph_tent is created and the bag is given (" .. created_secs() .. ")")
	check(#RELEASED == 1 and RELEASED[1].sec == "itm_tent", "host: the used tent item is released like stock")
	check(HUD == nil, "host: no message")
end
reset()
load_mini()
coop_tent_guard = nil
load_script("coop_tent_guard")
item_tent.on_game_start()
MODE = "sp"
do
	local _, o = item("itm_sleepbag")
	item_tent.func_use_bag(o)
	run_time_events(300)
	check(created_secs():find("ph_sleepbag", 1, true) and created_secs():find("compression_bag<0", 1, true), "single player: the sleeping bag is placed (" .. created_secs() .. ")")
	check(HUD == nil, "single player: no message")
end

-- ------------------------------------------------------------------ the string tables
print("== string tables")
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end
local HEADER = '<?xml version="1.0" encoding="windows-1251"?>'
for _, lang in ipairs({ "eng", "rus" }) do
	local path = "gamedata/configs/text/" .. lang .. "/st_coop_tent.xml"
	local raw = read(path)
	check(raw ~= nil, lang .. ": st_coop_tent.xml exists")
	if raw then
		check(raw:sub(1, #HEADER) == HEADER, lang .. ": windows-1251 header")
		check(not raw:gsub("\r\n", ""):find("\n", 1, true), lang .. ": CRLF line ends only")
		local text = raw:match('<string id="st_coop_tent_blocked">%s*<text>(.-)</text>')
		check(text ~= nil and #text > 20, lang .. ": st_coop_tent_blocked has a text")
		if lang == "rus" then
			check(text and text:find("[\192-\255]") ~= nil and not text:find("[\208\209][\128-\191]"), "rus: the text is cp1251 Cyrillic, not UTF-8")
		else
			check(text and not text:find("[\128-\255]"), "eng: ASCII only")
		end
	end
end

done("TENT_GUARD")
