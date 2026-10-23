-- Anomaly Coop F3 test: the stock item_tent on a co-op client and on the host (scripts\coop_tent_guard.script; the claims and
-- the tips are scripts\coop_checkpoints.script, tested in test_checkpoints.lua). Not shipped.
-- Stock facts (anomaly-ref item_tent.script): on a client alife_create without a parent returns nil, so itm_tent_func (a
-- level.add_call functor, no pcall) indexes nil -> FATAL; the sleeping bag branch of the local actor_on_item_use fails the
-- same way; func_use_tent / func_use_bag free the used item themselves (CreateTimeEvent 0) about 4 s BEFORE a tent would be put
-- up. Since F3 T13 a client asks the host (coop.checkpoint.claim_tent) and never touches the item: the host takes it (and
-- answers "no_item" when it is gone). The wrappers replace the entry points of the item_tent module table on a client and leave
-- host / single player alone (the host only tells the engine about what the stock put up).
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/item_tent_stock.lua")

local ENTRY = { "start_timer", "itm_tent_func", "itm_tent_bag_func", "use_compression_bag", "func_use_bag", "func_use_tent" }

-- ------------------------------------------------------------------ stand-ins
ADD_CALLS = {}
level.add_call = function(cond, f) ADD_CALLS[#ADD_CALLS + 1] = f end
level.map_add_object_spot_ser = function() end
ANIMATIONS = false
ui_options = { get = function() return ANIMATIONS end }
actor_effects = { play_item_fx = function() end }
function hide_hud_inventory() end

-- coop.checkpoint as the engine registers it: only the claims matter here
CLAIMS = {}
coop.checkpoint = {
	claim_tent = function(x, y, z, what) CLAIMS[#CLAIMS + 1] = { x = x, y = y, z = z, what = what }; return true end,
}

-- the stock module registers its local use callback; keep our own list so that each test starts from a clean one
-- (set semantics like axr_main.callback_set: the same function twice is one entry). The guard's own host callback for the
-- use of an item (coop_tent_guard.on_item_use) is not the stock callback and is kept out of the list.
USE_CB = {}
local real_register, real_unregister = RegisterScriptCallback, UnregisterScriptCallback
local function own_callback(f) return rawget(_G, "coop_tent_guard") ~= nil and f == coop_tent_guard.on_item_use end
function RegisterScriptCallback(name, f)
	if name ~= "actor_on_item_use" then return real_register(name, f) end
	if own_callback(f) then return end
	for _, g in ipairs(USE_CB) do if g == f then return end end
	USE_CB[#USE_CB + 1] = f
end
function UnregisterScriptCallback(name, f)
	if name ~= "actor_on_item_use" then return real_unregister(name, f) end
	for i = #USE_CB, 1, -1 do if USE_CB[i] == f then table.remove(USE_CB, i) end end
end
local function fire_use(obj) local list = {}; for i, f in ipairs(USE_CB) do list[i] = f end; for _, f in ipairs(list) do f(obj) end end

-- what the player sees (a tip over the game; the inventory is closed first, as itms_manager does)
EV = {}
utils_xml = { hide_menu = function() EV[#EV + 1] = "hide" end }
actor_menu.set_msg = function(_, t) HUD = t; EV[#EV + 1] = "msg" end

-- alife_create as a client's engine answers it: a spawn without a parent is the host's job, the result is nil
local world_create = alife_create
ALIFE_CREATE = 0
function alife_create(sec, pos, lv, gv, parent)
	ALIFE_CREATE = ALIFE_CREATE + 1
	if MODE == "client" and parent == nil then return nil end
	return world_create(sec, pos, lv, gv, parent)
end

TR = {}      -- string table: id -> text
game.translate_string = function(id) return TR[id] or id end

local function reset()
	CREATED, RELEASED, ADD_CALLS, TIMEEV, LOG, USE_CB, CLAIMS = {}, {}, {}, {}, {}, {}, {}
	ALIFE_CREATE, HUD, EV = 0, nil, {}
	SE, OBJ = {}, {}
	make_actor(vec3(0, 0, 0))
	TR = {}
	MODE = "host"
	ANIMATIONS = false
	NEAR_TENT, NEAR_BAG = nil, nil
	SPAWNED_BAGS = {}
	coop_checkpoints = nil -- the claim in flight of the last test is not this test's
	-- stock items_tools.ltx: the compression bag and the tent bag stay after use (remove_after_use = false), the tent and
	-- the sleeping bag are eaten (default true, one use)
	INI = { compression_bag = { remove_after_use = false }, itm_tent_bag = { remove_after_use = false } }
end

local function item(sec)
	local se, o = spawn(sec, vec3(0, 0, 0), 0)
	return se, o
end

-- CInventory::Eat: UseBy, then the use callback, then the item is deleted when remove_after_use is true (default) and no use
-- is left (max_uses, default 1). Call it right before the callback / the function the callback reaches.
local function engine_eat(o)
	local cfg = INI[o:section()] or {}
	if cfg.remove_after_use == false or (cfg.max_uses or 1) > 1 then return false end
	SE[o:id()], OBJ[o:id()] = nil, nil
	return true
end

local function count_sec(sec)
	local n = 0
	for _, se in pairs(SE) do if se._sec == sec then n = n + 1 end end
	return n
end

local function created_secs()
	local t = {}
	for _, c in ipairs(CREATED) do t[#t + 1] = c.sec .. "<" .. tostring(c.parent) end
	return table.concat(t, ",")
end

local function claims()
	local t = {}
	for _, c in ipairs(CLAIMS) do t[#t + 1] = c.what end
	return table.concat(t, ",")
end

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
	m.get_spawned_sleepbags = function() return SPAWNED_BAGS end
	m.on_game_start = function() ON_START = (ON_START or 0) + 1 end
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
	run_time_events(100)
	check(HUD == nil and #CREATED == 0 and ALIFE_CREATE == 0 and #CLAIMS == 0, mode .. ": no message, nothing spawned, no claim by the guard")
end

print("== client: stock never runs, the host is asked, the item stays")
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
	for k in pairs(TIMEEV) do check(not k:find("release", 1, true), "no 'release the item' event is left (" .. k .. ")") end
	check(#CLAIMS == 1 and CLAIMS[1].what == "tent", "func_use_tent: the host is asked for a tent (" .. claims() .. ")")
end
do
	-- the animation: the claim goes when the stock tent would appear, the item is untouched all the while
	reset()
	MODE = "client"
	ANIMATIONS = true
	local se, o = item("itm_tent")
	item_tent.func_use_tent(o)
	run_time_events(3000)
	check(#CLAIMS == 0 and SE[se.id] ~= nil and #RELEASED == 0, "animation: 3 s in, no claim yet, the item is there")
	run_time_events(2000)
	check(#CLAIMS == 1 and SE[se.id] ~= nil and #RELEASED == 0, "animation: after 4 s the claim is sent, the item is still there")
end
do
	-- an unknown item: the stock function would free it, so it is not called; the player is told
	reset()
	MODE = "client"
	local se, o = item("bolts_pack")
	item_tent.func_use_tent(o)
	run_time_events(300)
	check(#CALLS == 0 and #CLAIMS == 0 and SE[se.id] ~= nil and #RELEASED == 0, "an unknown section: nothing is called, sent or freed")
	check(HUD == "st_coop_cp_unsupported", "the player is told (" .. tostring(HUD) .. ")")
	check(#EV == 2 and EV[1] == "hide" and EV[2] == "msg", "the inventory is closed first, then the message (" .. table.concat(EV, ",") .. ")")
	-- no utils_xml (or it throws): the message still comes
	reset()
	MODE = "client"
	local saved = utils_xml
	utils_xml = { hide_menu = function() error("no hud") end }
	item_tent.func_use_tent(arg_obj("bolts_pack"))
	check(HUD == "st_coop_cp_unsupported", "a failing hide_menu does not swallow the message")
	utils_xml = nil
	reset()
	MODE = "client"
	item_tent.func_use_tent(arg_obj("bolts_pack"))
	check(HUD == "st_coop_cp_unsupported", "no utils_xml at all: the message still comes")
	utils_xml = saved
end
do
	reset()
	MODE = "client"
	TR.st_coop_cp_unsupported = "TRANSLATED"
	item_tent.func_use_tent(arg_obj("bolts_pack"))
	check(HUD == "TRANSLATED", "the translated message is shown")
end
do
	reset()
	MODE = "client"
	local se, o = item("itm_sleepbag")
	item_tent.func_use_bag(o)
	run_time_events(300)
	check(#CALLS == 0 and ALIFE_CREATE == 0 and #CREATED == 0, "func_use_bag: stock not called, nothing spawned")
	check(SE[se.id] ~= nil and #RELEASED == 0, "func_use_bag: the sleeping bag stays")
	check(#CLAIMS == 1 and CLAIMS[1].what == "sleepbag", "func_use_bag: the host is asked for a sleeping bag (" .. claims() .. ")")
end
do
	reset()
	MODE = "client"
	item_tent.func_use_tent(nil)
	check(#CALLS == 1 and CALLS[1].name == "func_use_tent", "func_use_tent(nil): stock call as is (it does nothing for nil)")
	CALLS = {}
end
-- start_timer is reached from the use callback: the engine has already used the item. A tent is eaten (remove_after_use true by
-- default): it is created again, then the host takes it. A tent bag stays (remove_after_use = false): not given back.
do
	reset()
	MODE = "client"
	local se, o = item("itm_tent")
	check(engine_eat(o), "model: the engine eats itm_tent")
	item_tent.start_timer(o)
	check(#CALLS == 0 and #ADD_CALLS == 0, "start_timer(itm_tent): no timer functor is queued, stock not called")
	check(ALIFE_CREATE == 0, "start_timer(itm_tent): alife_create is not called")
	check(created_secs() == "itm_tent<0" and count_sec("itm_tent") == 1, "start_timer(itm_tent): eaten, so exactly one copy is returned (" .. created_secs() .. ")")
	check(#CLAIMS == 0, "start_timer(itm_tent): the claim waits for the item to reach the host")
	run_time_events(2000)
	check(#CLAIMS == 1 and CLAIMS[1].what == "tent", "start_timer(itm_tent): then the host is asked")
end
do
	reset()
	MODE = "client"
	local se, o = item("itm_tent_bag")
	check(not engine_eat(o) and SE[se.id] ~= nil, "model: itm_tent_bag stays in the inventory after use")
	item_tent.start_timer(o)
	run_time_events(300)
	check(#CALLS == 0 and #ADD_CALLS == 0 and ALIFE_CREATE == 0, "start_timer(itm_tent_bag): stock not called, no timer, no alife_create")
	check(#CREATED == 0 and count_sec("itm_tent_bag") == 1 and #RELEASED == 0, "start_timer(itm_tent_bag): not eaten, so nothing is given back: the original stays, no duplicate")
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack", "start_timer(itm_tent_bag): a pack-up claim")
end
do
	-- a multi-use item survives a use even with remove_after_use true
	reset()
	MODE = "client"
	INI.itm_tent = { max_uses = 3 }
	local se, o = item("itm_tent")
	check(not engine_eat(o), "model: a three-use tent is not deleted by one use")
	item_tent.start_timer(o)
	check(#CREATED == 0 and count_sec("itm_tent") == 1, "start_timer(itm_tent, max_uses 3): not given back")
end
do
	reset()
	MODE = "client"
	item_tent.start_timer(arg_obj("bolts_pack"))
	check(#CALLS == 1 and CALLS[1].name == "start_timer" and HUD == nil and #CREATED == 0 and #CLAIMS == 0, "start_timer of another section: stock call, no message, no item, no claim")
	CALLS = {}
end
do
	-- the compression bag: the client cannot know which sleeping bag is near (its list is a snapshot), the host decides
	reset()
	MODE = "client"
	local _, o = item("compression_bag")
	local _, bag = spawn("ph_sleepbag", vec3(1, 0, 0))
	SPAWNED_BAGS[bag:id()] = true
	check(not engine_eat(o), "model: the compression bag stays in the inventory after use")
	item_tent.use_compression_bag(o, 1.5)
	run_time_events(300)
	check(#CALLS == 0 and ALIFE_CREATE == 0 and #RELEASED == 0, "use_compression_bag: stock not called, nothing released")
	check(#CREATED == 0 and count_sec("compression_bag") == 1, "use_compression_bag: not eaten, so nothing is given back, the original stays")
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack", "use_compression_bag: a pack-up claim")
	item_tent.use_compression_bag(nil, 1.5)
	check(#CALLS == 0 and #CREATED == 0 and #CLAIMS == 1, "use_compression_bag(nil): nothing")
end
do
	reset()
	MODE = "client"
	item_tent.itm_tent_func()
	item_tent.itm_tent_bag_func()
	check(#CALLS == 0 and ALIFE_CREATE == 0 and #CREATED == 0 and #RELEASED == 0 and #CLAIMS == 0, "the timer functors do nothing on a client")
end
do
	-- the engine refuses to give the item back: the guard must not throw out of the use handler
	reset()
	MODE = "client"
	local real = alife_create_item
	alife_create_item = function() error("no parent") end
	local _, o = item("itm_tent")
	engine_eat(o)
	local ok2 = pcall(item_tent.start_timer, o)
	alife_create_item = real
	check(ok2, "a failed give-back does not throw")
end

print("== role switches at call time")
reset()
CALLS = {}
MODE = "client"
item_tent.func_use_tent(arg_obj("itm_tent"))
check(#CALLS == 0 and #CLAIMS == 0, "client: blocked until the claim goes")
run_time_events(100)
check(#CALLS == 0 and #CLAIMS == 1, "client: a claim, the stock is not called")
MODE = "host"
item_tent.func_use_tent(arg_obj("itm_tent"))
check(#CALLS == 1, "the same wrapper passes through on the host")
MODE = "sp"
item_tent.func_use_tent(arg_obj("itm_tent"))
check(#CALLS == 2, "and in single player")

print("== a mod that overwrites an entry later")
reset()
CALLS = {}
OTHER = 0
item_tent.func_use_tent = function() OTHER = OTHER + 1 end
local mine = item_tent.func_use_tent
coop_tent_guard.on_game_start()
check(item_tent.func_use_tent ~= mine, "the overwritten entry point is wrapped again")
MODE = "client"
item_tent.func_use_tent(arg_obj("itm_tent"))
run_time_events(100)
check(OTHER == 0 and #CLAIMS == 1, "client: the mod's function does not run, the host is asked")
MODE = "host"
item_tent.func_use_tent(arg_obj("itm_tent"))
check(OTHER == 1, "host: the mod's function runs")
local again = item_tent.func_use_tent
coop_tent_guard.on_game_start()
check(item_tent.func_use_tent == again, "an untouched wrapper is not wrapped a third time")

print("== item_tent.on_game_start is still the stock one")
ON_START = 0
MODE = "client"
local okg, errg = pcall(item_tent.on_game_start)
check(okg and ON_START == 1, "the stock on_game_start runs once through its wrapper, nothing to swap is no error (" .. tostring(errg) .. ")")

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
-- support\item_tent_stock.lua is a faithful miniature of item_tent.script (same names, same globals, same file locals, same
-- local actor_on_item_use that on_game_start registers), loaded the way the engine loads a script, so that the lookup of
-- start_timer & co. from inside the local function goes through the module table the guard writes to.
print("== stock shape: module environment")

-- the engine runs the level.add_call functors on a later frame with no pcall: an error is fatal
local function run_add_calls()
	local list = ADD_CALLS
	ADD_CALLS = {}
	for _, f in ipairs(list) do f() end
end

-- a fresh stock module + the guard script loaded (axr_main loads every script first, then runs every on_game_start)
local function boot(mode)
	reset()
	SLEEP_ENABLE, SLEEP_PLACEABLE, NON_PLACEABLE = nil, nil, nil
	load_mini()
	coop_tent_guard = nil
	load_script("coop_tent_guard")
	MODE = mode or "host"
end
local function start_all_scripts()
	coop_tent_guard.on_game_start()
	item_tent.on_game_start()
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
SLEEP_ENABLE, SLEEP_PLACEABLE = nil, nil
load_mini()
item_tent.on_game_start()
MODE = "client"
do
	local _, o = item("itm_sleepbag")
	local ok3 = pcall(item_tent.func_use_bag, o)
	check(not ok3, "unguarded client: the sleeping bag branch fails on the nil")
end
reset()
SLEEP_ENABLE, SLEEP_PLACEABLE = nil, nil
load_mini()
item_tent.on_game_start()
MODE = "client"
do
	-- the stock callback on an eaten itm_sleepbag: the error goes into the router's pcall and the item is gone
	local _, o = item("itm_sleepbag")
	engine_eat(o)
	local ok3 = pcall(fire_use, o)
	check(not ok3 and count_sec("itm_sleepbag") == 0, "unguarded client: the stock use callback fails on itm_sleepbag and the item is lost")
end

print("== stock shape: GAMMA action functors (client)")
boot("client")
start_all_scripts()
do
	local se, o = item("itm_tent")
	item_tent.func_use_tent(o)
	run_time_events(300)
	local ok3, err3 = pcall(run_add_calls)
	check(ok3 and #ADD_CALLS == 0, "func_use_tent: no timer functor, nothing fatal (" .. tostring(err3) .. ")")
	check(ALIFE_CREATE == 0 and #CREATED == 0, "func_use_tent: nothing spawned")
	check(SE[se.id] ~= nil and #RELEASED == 0, "func_use_tent: the tent is not released")
	check(claims() == "tent", "func_use_tent: the host is asked (" .. claims() .. ")")
end
boot("client")
start_all_scripts()
do
	local se, o = item("itm_sleepbag")
	local ok3, err3 = pcall(item_tent.func_use_bag, o)
	run_time_events(300)
	check(ok3, "func_use_bag: no error (" .. tostring(err3) .. ")")
	check(ALIFE_CREATE == 0 and #CREATED == 0, "func_use_bag: ph_sleepbag and compression_bag are not created")
	check(SE[se.id] ~= nil and #RELEASED == 0, "func_use_bag: the sleeping bag is not released")
	check(claims() == "sleepbag", "func_use_bag: the host is asked (" .. claims() .. ")")
end

print("== stock shape: use callback (items the engine eats) on a client")
boot("client")
start_all_scripts()
do
	-- itm_tent_bag next to a tent: a pack-up claim. The tent bag stays after use (remove_after_use = false): nothing is
	-- given back. The foreign tent is not released (the host decides what is near).
	local _, tent = spawn("ph_tent", vec3(1, 0, 0))
	NEAR_TENT = tent:id()
	local se, o = item("itm_tent_bag")
	engine_eat(o)
	local ok3, err3 = pcall(fire_use, o)
	run_time_events(300)
	check(ok3, "itm_tent_bag callback: no error (" .. tostring(err3) .. ")")
	check(#ADD_CALLS == 0, "itm_tent_bag callback: no timer functor")
	check(#CREATED == 0 and count_sec("itm_tent_bag") == 1 and SE[se.id] ~= nil, "itm_tent_bag callback: the original stays, nothing is given back (" .. created_secs() .. ")")
	check(#RELEASED == 0 and OBJ[tent:id()] ~= nil, "itm_tent_bag callback: the foreign tent is not released (no duplicate)")
	check(claims() == "pack", "itm_tent_bag callback: a pack-up claim (" .. claims() .. ")")
end
boot("client")
start_all_scripts()
do
	-- itm_tent through the callback (no functor on this item): eaten, so it comes back once, then the host takes it
	local _, o = item("itm_tent")
	engine_eat(o)
	local ok3, err3 = pcall(fire_use, o)
	check(ok3 and #ADD_CALLS == 0, "itm_tent callback: no error, no timer functor (" .. tostring(err3) .. ")")
	check(created_secs() == "itm_tent<0" and count_sec("itm_tent") == 1, "itm_tent callback: exactly one tent in the inventory (" .. created_secs() .. ")")
	run_time_events(2000)
	check(claims() == "tent", "itm_tent callback: then the host is asked (" .. claims() .. ")")
end
boot("client")
start_all_scripts()
do
	-- compression bag next to a placed sleeping bag: the bag stays (remove_after_use = false), the placed one is not released
	local _, bag = spawn("ph_sleepbag", vec3(1, 0, 0))
	item_tent.get_spawned_sleepbags()[bag:id()] = true
	local _, o = item("compression_bag")
	engine_eat(o)
	local ok3, err3 = pcall(fire_use, o)
	run_time_events(300)
	check(ok3 and #RELEASED == 0, "compression_bag callback: no error, the placed sleeping bag is not released (" .. tostring(err3) .. ")")
	check(#CREATED == 0 and count_sec("compression_bag") == 1 and count_sec("itm_sleepbag") == 0,
		"compression_bag callback: the original stays, no itm_sleepbag, no second compression bag (" .. created_secs() .. ")")
	check(claims() == "pack", "compression_bag callback: a pack-up claim (" .. claims() .. ")")
end
boot("client")
start_all_scripts()
do
	-- the client cannot tell whether a sleeping bag is near: it asks, once, and clicking again changes nothing (no duplicates)
	local _, o = item("compression_bag")
	engine_eat(o)
	local ok3 = pcall(fire_use, o)
	check(ok3 and #CREATED == 0 and count_sec("compression_bag") == 1, "compression_bag callback with no sleeping bag in reach: the bag stays")
	fire_use(o)
	fire_use(o)
	run_time_events(300)
	check(claims() == "pack" and count_sec("compression_bag") == 1, "clicking it again and again: one claim, no duplicates (" .. claims() .. ")")
end

print("== stock shape: the sleeping bag branch of the use callback (stock Anomaly, the engine eats itm_sleepbag)")
boot("client")
start_all_scripts()
do
	check(#USE_CB == 1, "exactly one use callback is registered")
	local _, o = item("itm_sleepbag")
	check(engine_eat(o), "model: the engine eats itm_sleepbag")
	local ok3, err3 = pcall(fire_use, o)
	check(ok3, "client: no error out of the callback (" .. tostring(err3) .. ")")
	check(ALIFE_CREATE == 0, "client: alife_create is not called")
	check(created_secs() == "itm_sleepbag<0" and count_sec("itm_sleepbag") == 1, "client: the eaten sleeping bag is given back once (" .. created_secs() .. ")")
	check(count_sec("ph_sleepbag") == 0 and count_sec("compression_bag") == 0, "client: no ph_sleepbag and no compression_bag")
	check(#CLAIMS == 0, "client: the claim waits for the bag to reach the host")
	run_time_events(2000)
	check(claims() == "sleepbag", "client: then the host is asked (" .. claims() .. ")")
end
boot("client")
start_all_scripts()
do
	local _, o = item("sleep_bag")
	engine_eat(o)
	fire_use(o)
	run_time_events(2000)
	check(created_secs() == "sleep_bag<0" and claims() == "sleepbag", "client: the other sleeping bag section is handled too (" .. created_secs() .. ")")
end
boot("client")
SLEEP_ENABLE = false
start_all_scripts()
do
	local _, o = item("itm_sleepbag")
	engine_eat(o)
	local ok3 = pcall(fire_use, o)
	run_time_events(2000)
	check(ok3 and HUD == nil and #CREATED == 0 and #CLAIMS == 0, "client, sleeping bags disabled in the stock: the stock callback does nothing, no claim")
end
boot("client")
SLEEP_PLACEABLE = false
start_all_scripts()
do
	local _, o = item("itm_sleepbag")
	engine_eat(o)
	pcall(fire_use, o)
	check(NON_PLACEABLE == 1 and HUD == nil and #CLAIMS == 0, "client, use_placeable = false: not the broken branch, the stock callback handles it")
end
boot("client")
start_all_scripts()
do
	local _, o = item("bolts_pack")
	local ok3 = pcall(fire_use, o)
	check(ok3 and HUD == nil and #CREATED == 0 and #CLAIMS == 0, "client: an unrelated item goes through the stock callback untouched")
end
for _, mode in ipairs({ "host", "sp" }) do
	boot(mode)
	start_all_scripts()
	local _, o = item("itm_sleepbag")
	engine_eat(o)
	fire_use(o)
	check(ALIFE_CREATE == 1 and count_sec("ph_sleepbag") == 1 and count_sec("compression_bag") == 1 and count_sec("itm_sleepbag") == 0 and HUD == nil,
		mode .. ": the stock callback places the sleeping bag (" .. created_secs() .. ")")
end

print("== stock shape: the callback swap")
boot("host")
do
	-- the stock on_game_start runs through its wrapper: the guard replaces the callback it just registered
	item_tent.on_game_start()
	local guard_cb = USE_CB[1]
	coop_tent_guard.on_game_start()
	check(#USE_CB == 1 and USE_CB[1] == guard_cb, "guard second: still one callback")
	-- the stock on_game_start once more registers its own function again: the wrapper swaps it again
	item_tent.on_game_start()
	check(#USE_CB == 1 and USE_CB[1] == guard_cb, "the stock on_game_start twice: one callback, the guard's")
end
reset()
SLEEP_ENABLE, SLEEP_PLACEABLE = nil, nil
load_mini()
item_tent.on_game_start() -- the stock callback is registered before the guard script is even loaded
MODE = "client"
do
	local stock_cb = USE_CB[1]
	coop_tent_guard = nil
	load_script("coop_tent_guard")
	check(USE_CB[1] == stock_cb, "guard loaded late: the stock callback is still the registered one")
	local saved = rawget(_G, "coop_main")
	coop_main = { callback_registered = function(_, f) for _, g in ipairs(USE_CB) do if g == f then return true end end return false end }
	coop_tent_guard.on_game_start()
	coop_main = saved
	check(#USE_CB == 1 and USE_CB[1] ~= stock_cb, "guard's on_game_start swaps a stock callback that is registered already")
	local _, o = item("itm_sleepbag")
	engine_eat(o)
	local ok3 = pcall(fire_use, o)
	run_time_events(2000)
	check(ok3 and created_secs() == "itm_sleepbag<0" and claims() == "sleepbag", "and the client is handled there too")
end
boot("client")
do
	-- the client filter says the stock callback is not registered (an MCM toggle): nothing is swapped
	local saved = rawget(_G, "coop_main")
	coop_main = { callback_registered = function() return false end }
	start_all_scripts()
	coop_main = saved
	local cb_count = #USE_CB
	local _, o = item("itm_sleepbag")
	engine_eat(o)
	pcall(fire_use, o)
	check(cb_count == 1 and ALIFE_CREATE == 1 and HUD == nil and #CLAIMS == 0, "callback_registered == false: the stock callback is left as it is")
end

print("== stock shape: host runs the stock logic")
boot("host")
start_all_scripts()
do
	local _, o = item("itm_tent")
	item_tent.func_use_tent(o)
	check(#ADD_CALLS == 1, "host: func_use_tent queues the stock timer functor")
	run_add_calls()
	run_time_events(300)
	check(ALIFE_CREATE == 1 and created_secs():find("ph_tent<nil", 1, true) and created_secs():find("itm_tent_bag<0", 1, true),
		"host: ph_tent is created and the bag is given (" .. created_secs() .. ")")
	check(#RELEASED == 1 and RELEASED[1].sec == "itm_tent", "host: the used tent item is released like stock")
	check(HUD == nil and #EV == 0, "host: no message")
	check(claims() == "tent", "host: the engine is told about the tent that was put up (" .. claims() .. ")")
end
boot("sp")
start_all_scripts()
do
	local _, o = item("itm_sleepbag")
	item_tent.func_use_bag(o)
	run_time_events(300)
	check(created_secs():find("ph_sleepbag", 1, true) and created_secs():find("compression_bag<0", 1, true), "single player: the sleeping bag is placed (" .. created_secs() .. ")")
	check(HUD == nil and #CLAIMS == 0, "single player: no message, no claim")
end
boot("host")
start_all_scripts()
do
	-- the host still packs a placed sleeping bag away with the compression bag
	local _, bag = spawn("ph_sleepbag", vec3(1, 0, 0))
	item_tent.get_spawned_sleepbags()[bag:id()] = true
	local _, o = item("compression_bag")
	fire_use(o)
	check(#RELEASED == 2 and count_sec("itm_sleepbag") == 1, "host: the compression bag still packs the placed sleeping bag up")
	check(#CLAIMS == 0, "host: packing up claims nothing")
end

done("TENT_GUARD")
