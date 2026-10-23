-- Anomaly Coop F3 task 13 stub test: the Lua side of the checkpoints (scripts\coop_checkpoints.script, the item_tent
-- adapter scripts\coop_tent_guard.script, the party panel mark of scripts\coop_allies.script, the string tables
-- configs\text\{eng,rus}\st_coop_checkpoints.xml). Not shipped. Run: tools\test_lua.cmd checkpoints
--
-- The engine is a stand-in: coop.checkpoint (get / story / claim_tent / tent_owner), the callbacks coop_checkpoint_changed /
-- coop_checkpoint_refused / coop_tent_placed fired by hand, level.map_* spots, the stock item_tent (support\item_tent_stock.lua).
-- Roles: "host", "client" and "sp" (no session); the scripts ask coop.is_client() / is_host() at every call.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/item_tent_stock.lua")

local SPOT = "ui_pda2_actor_sleep_location"

-- ------------------------------------------------------------------ string tables (the real ones)
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

local STR = strings_of("gamedata/configs/text/eng/st_coop_checkpoints.xml")
game.translate_string = function(id) return STR[id] or id end

-- ------------------------------------------------------------------ callbacks: what a script registers is kept by name
HANDLERS = {}
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
function AddScriptCallback() end
local function fire(n, ...)
	local list = {}
	for i, f in ipairs(HANDLERS[n] or {}) do list[i] = f end
	for _, f in ipairs(list) do f(...) end
end
local function registered(n) return #(HANDLERS[n] or {}) end

-- ------------------------------------------------------------------ engine stand-ins
MSG, MSGS, EV = nil, {}, {}
actor_menu.set_msg = function(_, text) MSG = text; MSGS[#MSGS + 1] = text; EV[#EV + 1] = "msg" end
utils_xml = { hide_menu = function() EV[#EV + 1] = "hide" end }
ANIMATIONS = true
ui_options = { get = function() return ANIMATIONS end }
FX = {}
actor_effects = { play_item_fx = function(n) FX[#FX + 1] = n end }
function hide_hud_inventory() end
EXEC = {}
function exec_console_cmd(c) EXEC[#EXEC + 1] = c end
ADD_CALLS = {}
level.add_call = function(cond, f) ADD_CALLS[#ADD_CALLS + 1] = f end

-- level.map_*: one spot per (object, type) is wanted; the engine adds a second one if asked twice (CMapManager::AddMapLocation).
-- A serializable spot (map_add_object_spot_ser) is in the save and comes back after a load, any other is gone (reload_world).
SPOTS, SPOT_ADDS, SPOT_REMOVES, SPOT_HINTS = {}, {}, {}, {}
local function add_spot(ser)
	return function(id, typ, hint)
		SPOT_ADDS[id] = (SPOT_ADDS[id] or 0) + 1
		SPOTS[id] = { typ = typ, hint = hint, n = (SPOTS[id] and SPOTS[id].n or 0) + 1, ser = ser }
	end
end
level.map_add_object_spot_ser = add_spot(true)
level.map_add_object_spot = add_spot(false)
level.map_remove_object_spot = function(id, typ) SPOT_REMOVES[id] = (SPOT_REMOVES[id] or 0) + 1; SPOTS[id] = nil end
level.map_has_object_spot = function(id, typ) return SPOTS[id] and 1 or 0 end -- the engine returns a u16, not a bool
level.map_change_spot_hint = function(id, typ, hint) SPOT_HINTS[id] = hint; if SPOTS[id] then SPOTS[id].hint = hint end end
-- a save and a load: what is in the save (CMapManager::save writes the serializable spots only) is what is there afterwards
local function reload_world()
	for id, spot in pairs(SPOTS) do
		if not spot.ser then SPOTS[id] = nil end
	end
end

-- the custom data of an object (obj:spawn_ini()), by object id: { section = { key = value } }
CUSTOM = {}
local function custom_ini(data)
	local ini = {}
	function ini:section_exist(sec) return data[sec] ~= nil end
	function ini:line_exist(sec, key) return data[sec] ~= nil and data[sec][key] ~= nil end
	function ini:r_string(sec, key) return data[sec][key] end
	return ini
end
do
	local GOmt = getmetatable(make_actor(vec3(0, 0, 0)))
	function GOmt.spawn_ini(self)
		local data = CUSTOM[self:id()]
		return data and custom_ini(data) or nil
	end
end

-- coop.checkpoint as the engine registers it (coop_checkpoints_lua.cpp); every call is recorded
CP_RECORD, OWNERS, STORIES, CLAIMS, CLAIM_OK = {}, {}, {}, {}, true
coop.checkpoint = {
	get = function(id) return CP_RECORD[id] end,
	story = function(reason) STORIES[#STORIES + 1] = { reason = reason }; return true end,
	claim_tent = function(x, y, z, what) CLAIMS[#CLAIMS + 1] = { x = x, y = y, z = z, what = what }; return CLAIM_OK end,
	tent_owner = function(id) return OWNERS[id] end,
}
-- alife():iterate_objects (demonized engine export) over the stand-in world
do
	local base = alife
	function alife()
		local a = base()
		a.iterate_objects = function(_, f) for _, se in pairs(SE) do if f(se) then break end end end
		return a
	end
end

ORIG_STORY = 0

-- CInventory::Eat: the item is deleted when remove_after_use is true (default) and no use is left (max_uses, default 1)
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

local function item(sec)
	local se, o = spawn(sec, vec3(0, 0, 0), 0)
	return se, o
end

local function run_add_calls()
	local list = ADD_CALLS
	ADD_CALLS = {}
	for _, f in ipairs(list) do f() end
end

local function ck() return rawget(_G, "coop_checkpoints") end

-- a clean world, the scripts loaded the way axr_main loads them (load, then every on_game_start)
local function fresh(mode, opts)
	opts = opts or {}
	MODE = mode
	SE, OBJ, CREATED, RELEASED, TIMEEV, ADD_CALLS = {}, {}, {}, {}, {}, {}
	MSG, MSGS, EV, EXEC, FX, STORIES, CLAIMS = nil, {}, {}, {}, {}, {}, {}
	SPOTS, SPOT_ADDS, SPOT_REMOVES, SPOT_HINTS = {}, {}, {}, {}
	CP_RECORD, OWNERS, CLAIM_OK, CUSTOM, SLEPT = {}, {}, true, {}, {}
	HANDLERS = {}
	ORIG_STORY = 0
	SLEEP_ENABLE, SLEEP_PLACEABLE, TENT_PLACEABLE, NON_PLACEABLE = nil, nil, nil, nil
	ANIMATIONS = opts.animations ~= false
	INI = { compression_bag = { remove_after_use = false }, itm_tent_bag = { remove_after_use = false } }
	NOW = NOW + 100000
	make_actor(vec3(0, 0, 0))
	xr_effects = { scenario_autosave = function(actor, npc, p)
		ORIG_STORY = ORIG_STORY + 1
		exec_console_cmd("save " .. tostring(p and p[1]))
	end }
	itms_manager = nil
	coop_checkpoints, coop_tent_guard, coop_allies = nil, nil, nil
	load_mini()
	load_script("coop_checkpoints")
	load_script("coop_tent_guard")
	coop_checkpoints.on_game_start()
	coop_tent_guard.on_game_start()
	item_tent.on_game_start()
end

-- the scripts are loaded again, the world (spots, objects) stays: the Lua state of a new level or a new session
local function reload_scripts()
	HANDLERS = {}
	coop_checkpoints, coop_tent_guard = nil, nil
	load_mini()
	load_script("coop_checkpoints")
	load_script("coop_tent_guard")
	coop_checkpoints.on_game_start()
	coop_tent_guard.on_game_start()
	item_tent.on_game_start()
end

local function case(name, f)
	print("== " .. name)
	local ok, err = pcall(f)
	if not ok then
		FAILS = FAILS + 1
		print("  FAIL " .. name .. " crashed: " .. tostring(err))
	end
end

local function ally_text(nick) return ((STR.st_coop_cp_ally or "?"):gsub("%%s", nick)) end

-- itms_manager.ini_manager stand-in: data = { section = { "key", ... } | { key = value } }
local function make_ini(data)
	local ini = {}
	function ini:section_exist(s) return data[s] ~= nil end
	function ini:line_count(s)
		local d = data[s]
		if not d then return 0 end
		local n = 0
		for _ in pairs(d) do n = n + 1 end
		return n
	end
	function ini:r_line(s, i)
		local d = data[s]
		if #d > 0 then return true, d[i + 1], "" end
		local k = 0
		for key, v in pairs(d) do
			if k == i then return true, key, tostring(v) end
			k = k + 1
		end
	end
	function ini:r_bool_ex(s, k, def)
		local d = data[s]
		local v = d and d[k]
		if v == nil then return def end
		return v == "true"
	end
	function ini:r_string_ex() return nil end
	return ini
end

-- loads coop_checkpoints again (it reads the item lists once per Lua state)
local function reload_checkpoints()
	coop_checkpoints = nil
	load_script("coop_checkpoints")
end

-- ------------------------------------------------------------------ story checkpoints
case("story_calls_engine", function()
	fresh("host")
	xr_effects.scenario_autosave(nil, nil, { "st_save_x" })
	check(#STORIES == 1 and STORIES[1].reason == "st_save_x", "host in a session: coop.checkpoint.story('st_save_x')")
	check(#EXEC == 0 and ORIG_STORY == 0, "the stock function is not called, exec_console_cmd('save ...') is not called")
	xr_effects.scenario_autosave(nil, nil, { string.rep("x", 300) })
	check(#STORIES == 2 and #STORIES[2].reason == 128, "a reason over 128 bytes is cut, the checkpoint is still set")
	xr_effects.scenario_autosave(nil, nil, {})
	xr_effects.scenario_autosave(nil, nil, nil)
	xr_effects.scenario_autosave(db.actor, nil, { 42 })
	check(#STORIES == 5 and STORIES[3].reason == nil and STORIES[5].reason == nil, "no or a bad save name: story() without a reason, no error")
	check(#EXEC == 0, "still no console command")
	fresh("client")
	xr_effects.scenario_autosave(nil, nil, { "st_save_x" })
	check(#STORIES == 0 and #EXEC == 0 and ORIG_STORY == 0, "client in a session: nothing (the host sets the story checkpoint)")
	local wrapped = xr_effects.scenario_autosave
	ck().on_game_start()
	check(xr_effects.scenario_autosave == wrapped, "a second on_game_start does not wrap again")
	fire("actor_on_first_update")
	check(xr_effects.scenario_autosave == wrapped, "nor does the first update")
	local mod_fn = function() end
	xr_effects.scenario_autosave = mod_fn
	fire("actor_on_first_update")
	check(xr_effects.scenario_autosave ~= mod_fn, "a mod that replaced it is wrapped again")
end)

case("story_outside_session_original", function()
	fresh("sp")
	xr_effects.scenario_autosave(nil, nil, { "st_save_x" })
	check(ORIG_STORY == 1 and #STORIES == 0, "no session: the original function runs")
	check(EXEC[1] == "save st_save_x", "with its own arguments (" .. tostring(EXEC[1]) .. ")")
	local saved = coop
	coop = nil
	xr_effects = { scenario_autosave = function() ORIG_STORY = ORIG_STORY + 1 end }
	local stock = xr_effects.scenario_autosave
	coop_checkpoints = nil
	load_script("coop_checkpoints")
	local ok = pcall(coop_checkpoints.on_game_start)
	coop = saved
	check(ok and xr_effects.scenario_autosave == stock, "an exe without co-op: nothing is wrapped, no error")
end)

-- ------------------------------------------------------------------ the player's own checkpoint: tip and PDA spot
case("changed_own_tip_and_spot", function()
	for _, mode in ipairs({ "host", "client" }) do
		fresh(mode)
		fire("coop_checkpoint_changed", 0, "campfire", 123, false, "l01_escape")
		check(MSG == STR.st_coop_cp_updated_campfire and MSG ~= nil and MSG ~= "st_coop_cp_updated_campfire",
			mode .. ": the tip is the translation of st_coop_cp_updated_campfire (" .. tostring(MSG) .. ")")
		check(SPOTS[123] ~= nil and SPOTS[123].typ == SPOT, mode .. ": the PDA spot ui_pda2_actor_sleep_location is on 123")
		check(SPOTS[123] and SPOTS[123].hint == STR.st_coop_cp_spot, mode .. ": with the hint st_coop_cp_spot")
		check(ck().last_update(0) == NOW, mode .. ": last_update(0) is the time of the update")
		check(ck().last_update(7) == nil, mode .. ": last_update of an unknown player is nil")
		fire("coop_checkpoint_changed", 0, "campfire", 124, false, "l01_escape")
		check(SPOTS[123] == nil and SPOTS[124] ~= nil, mode .. ": the camp moved to 124: the spot on 123 is gone, one is on 124")
		check(SPOT_ADDS[123] == 1 and SPOT_REMOVES[123] == 1, mode .. ": added once, removed once")
	end
	fresh("host")
	local kinds = { "campfire", "rest", "tent", "arrival", "story", "mod" }
	for i, kind in ipairs(kinds) do
		MSG = nil
		fire("coop_checkpoint_changed", 0, kind, 200 + i, false, "l01_escape")
		check(MSG == STR["st_coop_cp_updated_" .. kind] and MSG ~= nil, "the tip of the kind " .. kind)
	end
	MSG = nil
	fire("coop_checkpoint_changed", 0, "campfire", 124, false, "l01_escape")
	MSG = nil
	fire("coop_checkpoint_changed", 0, "campfire", 124, false, "l01_escape")
	check(MSG == STR.st_coop_cp_updated_campfire, "the same camp rested at again is news again (outside the entry window)")
	local ok = pcall(fire, "coop_checkpoint_changed", "bad", {}, nil, nil, nil)
	ok = ok and pcall(fire, "coop_checkpoint_changed", 0, "no_such_kind", 5, false, "x")
	ok = ok and pcall(fire, "coop_checkpoint_changed", nil, nil, nil, nil, nil)
	check(ok, "garbage arguments do not throw")
end)

case("changed_rollback_tip", function()
	fresh("host")
	fire("coop_checkpoint_changed", 0, "tent", 301, false, "l01_escape")
	fire("coop_checkpoint_changed", 0, "campfire", 123, false, "l01_escape")
	MSG = nil
	fire("coop_checkpoint_changed", 0, "tent", 301, true, "l01_escape")
	check(MSG == STR.st_coop_cp_rollback and MSG ~= nil, "rollback = true: st_coop_cp_rollback (" .. tostring(MSG) .. ")")
	check(SPOTS[301] ~= nil and SPOTS[123] == nil, "back at the previous camp: its spot is there, the lost one's is not")
	MSG = nil
	fire("coop_checkpoint_changed", 0, "none", -1, true, nil)
	check(MSG == STR.st_coop_cp_rollback_none and MSG ~= nil, "rolled back to nothing: st_coop_cp_rollback_none")
	check(SPOTS[301] == nil, "and the spot is gone")
	MSG = nil
	fire("coop_checkpoint_changed", 0, "none", -1, false, nil)
	check(MSG == nil, "'none' again (the list at world entry): no tip")
end)

case("arrival_no_spot", function()
	fresh("host")
	fire("coop_checkpoint_changed", 0, "arrival", -1, false, "l02_garbage")
	check(MSG == STR.st_coop_cp_updated_arrival and MSG ~= nil, "arrival: a tip")
	check(next(SPOTS) == nil and next(SPOT_ADDS) == nil, "arrival: no PDA spot")
	fire("coop_checkpoint_changed", 0, "story", -1, false, "l02_garbage")
	check(MSG == STR.st_coop_cp_updated_story and next(SPOT_ADDS) == nil, "story: a tip, no spot")
	fire("coop_checkpoint_changed", 0, "story", 77, false, "l02_garbage")
	fire("coop_checkpoint_changed", 0, "arrival", 78, false, "l02_garbage")
	check(next(SPOT_ADDS) == nil, "arrival and story never get a spot, whatever the source")
end)

case("group_spot", function()
	for _, case_ in ipairs({ { "host", "joiner" }, { "client", "hoster" } }) do
		local mode, nick = case_[1], case_[2]
		fresh(mode)
		fire("coop_checkpoint_changed", 500, "tent", 301, false, "l01_escape")
		check(SPOTS[301] ~= nil and SPOTS[301].typ == SPOT, mode .. ": an ally's camp: a spot on its source")
		check(SPOTS[301] and SPOTS[301].hint == ally_text(nick) and ally_text(nick):find(nick, 1, true),
			mode .. ": with the hint st_coop_cp_ally and his nick (" .. tostring(SPOTS[301] and SPOTS[301].hint) .. ")")
		check(MSG == nil, mode .. ": no tip for an ally")
		check(ck().last_update(500) == NOW and ck().last_update(0) == nil, mode .. ": last_update is per player")
		fire("coop_checkpoint_changed", 500, "campfire", 302, false, "l01_escape")
		check(SPOTS[301] == nil and SPOTS[302] ~= nil, mode .. ": his camp moved: the old spot is gone")
		fire("coop_checkpoint_changed", 500, "none", -1, false, nil)
		check(SPOTS[302] == nil and ck().last_update(500) == nil, mode .. ": his camp is gone (the group view was turned off): no spot, no update time")
	end
	-- two players at one campfire: one spot, it stays while any of them is there
	fresh("host")
	fire("coop_checkpoint_changed", 0, "campfire", 400, false, "l01_escape")
	fire("coop_checkpoint_changed", 500, "campfire", 400, false, "l01_escape")
	check(SPOT_ADDS[400] == 1 and SPOTS[400] and SPOTS[400].n == 1, "a shared campfire: one spot, not two")
	check(SPOTS[400].hint == STR.st_coop_cp_spot, "the own camp's hint wins")
	fire("coop_checkpoint_changed", 0, "campfire", 401, false, "l01_escape")
	check(SPOTS[400] ~= nil and SPOTS[401] ~= nil, "I left: the ally is still there, his spot stays")
	check(SPOTS[400].hint == ally_text("joiner"), "and it is his now")
	fire("coop_checkpoint_changed", 500, "campfire", 402, false, "l01_escape")
	check(SPOTS[400] == nil, "he left too: the spot is gone")
	-- a spot somebody else put there (the stock tent, a replicated one) is not added twice and not removed by us
	fresh("host")
	SPOTS[500] = { typ = SPOT, hint = "stock", n = 1 }
	fire("coop_checkpoint_changed", 0, "tent", 500, false, "l01_escape")
	check(SPOT_ADDS[500] == nil and SPOTS[500].hint == "stock", "an existing spot is left alone")
	fire("coop_checkpoint_changed", 0, "campfire", 501, false, "l01_escape")
	check(SPOTS[500] ~= nil and SPOT_REMOVES[500] == nil, "and it is not removed when the camp moves on")
end)

-- ------------------------------------------------------------------ a world is entered: read again, no false news
case("first_update_reread", function()
	fresh("client")
	CP_RECORD[0] = { kind = "campfire", level = "l01_escape", x = 1, y = 2, z = 3, source = 123 }
	CP_RECORD[500] = { kind = "tent", level = "l01_escape", x = 1, y = 2, z = 3, source = 301 }
	fire("actor_on_first_update")
	check(SPOTS[123] ~= nil and SPOTS[301] ~= nil, "the world is read again: the own and the ally's spots are set")
	check(MSG == nil and ck().last_update(0) == nil and ck().last_update(500) == nil, "silently: no tip, no 'just updated'")
	fire("coop_checkpoint_changed", 0, "campfire", 123, false, "l01_escape")
	fire("coop_checkpoint_changed", 500, "tent", 301, false, "l01_escape")
	check(MSG == nil and ck().last_update(0) == nil, "the host's list right after the entry repeats it: no news")
	NOW = NOW + 1000
	fire("coop_checkpoint_changed", 0, "rest", 9, false, "l01_escape")
	check(MSG == STR.st_coop_cp_updated_rest, "a different camp in the window is news")
	-- the list comes after the first update: nothing was read, the first callback of each player is the list
	fresh("client")
	fire("actor_on_first_update")
	fire("coop_checkpoint_changed", 0, "none", -1, false, nil)
	check(MSG == nil, "the entry list for a player with no camp ('none'): no error, no tip")
	NOW = NOW + 2000
	fire("coop_checkpoint_changed", 0, "tent", 301, false, "l01_escape")
	fire("coop_checkpoint_changed", 500, "campfire", 302, false, "l01_escape")
	check(MSG == nil and SPOTS[301] ~= nil and SPOTS[302] ~= nil, "the entry list that comes a moment late: spots, no tip")
	check(ck().last_update(0) == nil and ck().last_update(500) == nil, "and no panel mark for it")
	NOW = NOW + 10000
	fire("coop_checkpoint_changed", 0, "campfire", 303, false, "l01_escape")
	check(MSG == STR.st_coop_cp_updated_campfire, "later the same player's change is news")
	check(ck().last_update(0) == NOW, "and it is the time of the update")
	-- the old world's records are forgotten
	fresh("client")
	fire("coop_checkpoint_changed", 0, "campfire", 123, false, "l01_escape")
	CP_RECORD[0] = nil
	fire("actor_on_first_update")
	check(ck().last_update(0) == nil, "a new world starts without the old times")
	-- no coop.checkpoint at all (an old engine): nothing breaks
	fresh("host")
	local cp = coop.checkpoint
	coop.checkpoint = nil
	local ok = pcall(fire, "actor_on_first_update")
	coop.checkpoint = cp
	check(ok, "no coop.checkpoint: the first update is harmless")
end)

-- ------------------------------------------------------------------ tents on a client: a claim to the host, the item stays
case("tent_claim_sent", function()
	fresh("client")
	db.actor._pos = vec3(10, 2, 5)
	local se, o = item("itm_tent")
	local r = item_tent.func_use_tent(o)
	check(r == nil and #CLAIMS == 0, "the use only starts the put-up animation: no claim yet")
	check(FX[1] == "itm_sleepbag", "the stock animation plays")
	run_time_events(3000)
	check(#CLAIMS == 0, "still waiting (the stock tent appears after 4 s)")
	run_time_events(2000)
	check(#CLAIMS == 1, "after the animation the claim is sent")
	local c = CLAIMS[1]
	check(c and c.x == 10 and c.y == 2 and c.z == 8 and c.what == "tent", "claim_tent(x, y, z, 'tent') 3 m ahead of the actor, as stock puts it ("
		.. tostring(c and c.x) .. "," .. tostring(c and c.y) .. "," .. tostring(c and c.z) .. "," .. tostring(c and c.what) .. ")")
	-- the item is the host's to take: the client never frees it
	run_time_events(500)
	check(SE[se.id] ~= nil and OBJ[se.id] ~= nil and #RELEASED == 0, "after the claim the tent item is still in the inventory")
	check(#CREATED == 0, "the client creates nothing")
	for k in pairs(TIMEEV) do check(not k:find("release", 1, true), "no 'release the item' time event is left (" .. k .. ")") end
	check(#ADD_CALLS == 0, "no stock timer functor was queued (it would be fatal on a client)")
	fire("coop_checkpoint_changed", 0, "tent", 301, false, "l01_escape")
	check(MSG == STR.st_coop_cp_updated_tent and SPOTS[301] ~= nil, "the host's answer: the tent is the camp, tip and PDA spot")
	check(SE[se.id] ~= nil and #RELEASED == 0, "and the client still did not touch the item (the host takes it)")
	-- one claim at a time
	local _, o2 = item("itm_tent")
	item_tent.func_use_tent(o2)
	run_time_events(4500)
	check(#CLAIMS == 2, "after the answer a new use sends a new claim")
end)

case("tent_claim_without_animation", function()
	fresh("client", { animations = false })
	local se, o = item("itm_tent")
	item_tent.func_use_tent(o)
	run_time_events(100)
	check(#CLAIMS == 1 and CLAIMS[1].what == "tent", "animations off: the claim goes at once")
	check(SE[se.id] ~= nil and #RELEASED == 0, "the item stays")
end)

case("sleepbag_claim_sent", function()
	fresh("client")
	db.actor._pos = vec3(1, 0, 1)
	local se, o = item("itm_sleepbag")
	item_tent.func_use_bag(o)
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "sleepbag", "func_use_bag: claim_tent(..., 'sleepbag')")
	check(CLAIMS[1] and CLAIMS[1].x == 1 and CLAIMS[1].z == 1, "at the actor's position (the stock bag lies under the player)")
	check(SE[se.id] ~= nil and #RELEASED == 0 and #CREATED == 0, "the sleeping bag item stays; nothing is created or freed")
	fresh("client")
	local _, o2 = item("sleep_bag")
	item_tent.func_use_bag(o2)
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "sleepbag", "the other sleeping bag section too")
end)

case("claim_pending_and_timeout", function()
	fresh("client")
	local _, o = item("itm_sleepbag")
	item_tent.func_use_bag(o)
	run_time_events(200)
	check(#CLAIMS == 1, "claim sent")
	MSG = nil
	item_tent.func_use_bag(o)
	run_time_events(200)
	check(#CLAIMS == 1 and MSG == STR.st_coop_cp_claim_busy, "a second use while the host has not answered: no second claim, 'wait' tip")
	NOW = NOW + 4000
	fire("actor_on_update")
	MSG = nil
	item_tent.func_use_bag(o)
	check(MSG == STR.st_coop_cp_claim_busy, "4 s after the claim it still waits")
	NOW = NOW + 1500
	fire("actor_on_update")
	MSG = nil
	item_tent.func_use_bag(o)
	run_time_events(200)
	check(#CLAIMS == 2 and MSG == nil, "after about 5 s with no answer the wait ends, quietly (nothing was taken from the client)")
	check(SE[o:id()] ~= nil and #RELEASED == 0, "and the item is still there")
	-- a claim whose time event was lost (it never went out) does not block the next one for ever
	fresh("client")
	local _, o6 = item("itm_sleepbag")
	item_tent.func_use_bag(o6)
	TIMEEV = {}
	NOW = NOW + 14000
	fire("actor_on_update")
	MSG = nil
	item_tent.func_use_bag(o6)
	check(MSG == STR.st_coop_cp_claim_busy, "an unsent claim still holds the wait at 14 s")
	NOW = NOW + 2000
	fire("actor_on_update")
	MSG = nil
	item_tent.func_use_bag(o6)
	run_time_events(200)
	check(#CLAIMS == 1 and MSG == nil, "and lets go after 15 s")
	-- a refused claim ends the wait at once, with the reason
	fresh("client")
	local _, o3 = item("itm_sleepbag")
	item_tent.func_use_bag(o3)
	run_time_events(200)
	fire("coop_checkpoint_refused", "no_item", "sleepbag")
	check(MSG == STR.st_coop_cp_refused_no_item and MSG ~= nil, "refused: its tip")
	item_tent.func_use_bag(o3)
	run_time_events(200)
	check(#CLAIMS == 2, "and the next use is sent")
	-- the engine would not send (too soon / no session)
	fresh("client")
	CLAIM_OK = false
	local _, o4 = item("itm_sleepbag")
	item_tent.func_use_bag(o4)
	run_time_events(200)
	check(#CLAIMS == 1 and MSG == STR.st_coop_cp_claim_busy, "claim_tent returned false: a tip")
	CLAIM_OK = true
	item_tent.func_use_bag(o4)
	run_time_events(200)
	check(#CLAIMS == 2, "and nothing stays waiting")
	-- the player died while the animation was running
	fresh("client")
	local _, o5 = item("itm_tent")
	item_tent.func_use_tent(o5)
	db.actor._alive = false
	run_time_events(5000)
	check(#CLAIMS == 0, "a dead player sends no claim")
	db.actor._alive = true
	item_tent.func_use_tent(o5)
	run_time_events(5000)
	check(#CLAIMS == 1, "and is not left waiting for it")
end)

case("pack_claims", function()
	fresh("client")
	db.actor._pos = vec3(4, 0, 4)
	local _, bag = item("itm_tent_bag")
	check(not engine_eat(bag), "model: the tent bag stays in the inventory after use")
	fire("actor_on_item_use", bag)
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack" and CLAIMS[1].x == 4 and CLAIMS[1].z == 4, "using the tent bag: claim_tent(..., 'pack') at the actor")
	check(#CREATED == 0 and #RELEASED == 0 and count_sec("itm_tent_bag") == 1, "the bag is not touched")
	check(#ADD_CALLS == 0, "no stock pack timer (the client's spawned_tents is a stale snapshot)")
	-- success has no answer of its own: the item comes into the inventory
	MSG = nil
	local _, back = item("itm_tent")
	fire("actor_on_item_take", back)
	local _, o2 = item("compression_bag")
	item_tent.use_compression_bag(o2, 1.5)
	run_time_events(200)
	check(#CLAIMS == 2 and CLAIMS[2].what == "pack", "the item came: the wait ended, the compression bag sends the next claim")
	-- an unrelated item taken does not end the wait
	item_tent.use_compression_bag(o2, 1.5)
	check(#CLAIMS == 2, "waiting")
	local _, junk = item("bolts_pack")
	fire("actor_on_item_take", junk)
	item_tent.use_compression_bag(o2, 1.5)
	check(#CLAIMS == 2, "an unrelated item taken: still waiting")
	fire("actor_on_item_take", nil)
	-- ~5 s with nothing: the wait ends and nothing happens
	NOW = NOW + 5200
	fire("actor_on_update")
	MSG = nil
	item_tent.use_compression_bag(o2, 1.5)
	run_time_events(200)
	check(#CLAIMS == 3 and MSG == nil, "no answer for 5 s: the wait ends, no tip")
	-- far = nothing of mine here
	fire("coop_checkpoint_refused", "far", "pack")
	check(MSG == STR.st_coop_cp_refused_far_pack and MSG ~= STR.st_coop_cp_refused_far, "refused far for a pack-up: 'no tent of yours near' text")
	fire("coop_checkpoint_refused", "far", "tent")
	check(MSG == STR.st_coop_cp_refused_far and MSG ~= nil, "refused far for a tent: 'out of reach' text")
	-- using your own tent packs it up
	fresh("client")
	db.actor._pos = vec3(2, 0, 2)
	local _, tent = spawn("ph_tent", vec3(3, 0, 2))
	local _, foreign = spawn("ph_tent", vec3(30, 0, 2))
	fire("physic_object_on_use_callback", tent, db.actor)
	run_time_events(200)
	check(#CLAIMS == 0, "a tent that is not my camp: nothing")
	fire("coop_checkpoint_changed", 0, "tent", tent:id(), false, "l01_escape")
	fire("coop_checkpoint_refused", "failed", "tent")
	fire("physic_object_on_use_callback", foreign, db.actor)
	run_time_events(200)
	check(#CLAIMS == 0, "another tent while mine is the camp: nothing")
	fire("physic_object_on_use_callback", tent, db.actor)
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack", "using my own tent: claim_tent(..., 'pack')")
	local _, sb = spawn("ph_sleepbag", vec3(3, 0, 2))
	fire("coop_checkpoint_refused", "failed", "pack")
	fire("physic_object_on_use_callback", sb, db.actor)
	run_time_events(200)
	check(#CLAIMS == 1, "a sleeping bag is used to sleep, not packed")
	-- another player's use of my tent is not mine to answer
	fresh("client")
	local _, tent2 = spawn("ph_tent", vec3(3, 0, 2))
	fire("coop_checkpoint_changed", 0, "tent", tent2:id(), false, "l01_escape")
	local _, other = spawn("actor_proxy", vec3(3, 0, 3))
	fire("physic_object_on_use_callback", tent2, other)
	run_time_events(200)
	check(#CLAIMS == 0, "another player used my tent: nothing")
	fire("physic_object_on_use_callback", tent2, db.actor)
	run_time_events(200)
	check(#CLAIMS == 1, "I used it: a pack-up claim")
	-- an engine without claim_tent: the click is explained, nothing is touched
	fresh("client")
	local cp = coop.checkpoint
	coop.checkpoint = { get = cp.get }
	local se4, o4 = item("itm_tent")
	item_tent.func_use_tent(o4)
	run_time_events(5000)
	coop.checkpoint = cp
	check(#CLAIMS == 0 and MSG == STR.st_coop_cp_unsupported and SE[se4.id] ~= nil and #RELEASED == 0,
		"no claim_tent in the engine: a tip, the item is untouched")
	fresh("host")
	local _, ht = spawn("ph_tent", vec3(3, 0, 2))
	fire("coop_checkpoint_changed", 0, "tent", ht:id(), false, "l01_escape")
	fire("physic_object_on_use_callback", ht, db.actor)
	run_time_events(200)
	check(#CLAIMS == 0, "the host uses the stock bag: no claim")
end)

case("client_item_cases", function()
	-- an item that is none of the tents: the stock function would free it, so it is not called; a tip
	fresh("client")
	local se, o = item("bolts_pack")
	local r = item_tent.func_use_tent(o)
	run_time_events(500)
	check(#CLAIMS == 0 and SE[se.id] ~= nil and #RELEASED == 0, "an unknown section: nothing sent, the item stays")
	check(MSG == STR.st_coop_cp_unsupported and MSG ~= nil, "with a tip")
	local ok = pcall(item_tent.func_use_tent, nil)
	check(ok and #CLAIMS == 0, "func_use_tent(nil) does nothing")
	-- the ltx switches placing off: the stock handles it (it recreates the item and sleeps)
	fresh("client")
	SLEEP_PLACEABLE = false
	itms_manager = { ini_manager = make_ini({ sleeping_bag = { enable = "true", use_placeable = "false" } }) }
	reload_checkpoints()
	item_tent.on_game_start()
	local _, o2 = item("itm_sleepbag")
	item_tent.func_use_bag(o2)
	run_time_events(100)
	itms_manager = nil
	check(NON_PLACEABLE == 1 and #CLAIMS == 0, "use_placeable = false: the stock branch, no claim")
	-- engine eats the bag (stock Anomaly, no use1_action_functor): give it back once, then claim
	fresh("client")
	local _, o3 = item("itm_sleepbag")
	check(engine_eat(o3), "model: the engine eats itm_sleepbag")
	local okc, err = pcall(fire, "actor_on_item_use", o3)
	check(okc, "the callback does not throw (" .. tostring(err) .. ")")
	check(created_secs() == "itm_sleepbag<0" and count_sec("itm_sleepbag") == 1, "the eaten sleeping bag is given back once (" .. created_secs() .. ")")
	check(count_sec("ph_sleepbag") == 0 and count_sec("compression_bag") == 0, "no ph_sleepbag, no compression bag from the client")
	check(#CLAIMS == 0, "the claim waits for the item to reach the host")
	run_time_events(2000)
	check(#CLAIMS == 1 and CLAIMS[1].what == "sleepbag", "then claim_tent(..., 'sleepbag')")
	-- the stock callback on a tent bag next to a tent
	fresh("client")
	local _, tent = spawn("ph_tent", vec3(1, 0, 0))
	item_tent.get_spawned_tents()[tent:id()] = true
	local _, bag = item("itm_tent_bag")
	fire("actor_on_item_use", bag)
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack" and #RELEASED == 0, "the stock callback with a tent near: a pack claim, the foreign tent is not released")
	-- the timer functors do nothing on a client
	fresh("client")
	item_tent.itm_tent_func()
	item_tent.itm_tent_bag_func()
	check(#CREATED == 0 and #RELEASED == 0 and #CLAIMS == 0, "the stock timer functors do nothing on a client")
	-- start_timer reached by a mod
	fresh("client")
	local _, t5 = item("itm_tent")
	engine_eat(t5)
	item_tent.start_timer(t5)
	run_time_events(5000)
	check(created_secs() == "itm_tent<0" and #CLAIMS == 1 and #ADD_CALLS == 0, "start_timer(itm_tent) after the engine ate it: given back, claimed, no functor")
end)

-- ------------------------------------------------------------------ the host: the stock puts the tent up, the claim names it
case("host_own_tent_and_bag", function()
	fresh("host")
	local _, o = item("itm_tent")
	item_tent.func_use_tent(o)
	check(#ADD_CALLS == 1 and #CLAIMS == 0, "host: the stock timer functor is queued")
	run_add_calls()
	run_time_events(100)
	check(count_sec("ph_tent") == 1 and created_secs():find("ph_tent<nil", 1, true), "the stock created the tent (" .. created_secs() .. ")")
	check(#CLAIMS == 1 and CLAIMS[1].what == "tent", "claim_tent(..., 'tent') for it")
	local tent_se
	for _, se in pairs(SE) do if se._sec == "ph_tent" then tent_se = se end end
	check(CLAIMS[1] and tent_se and CLAIMS[1].x == tent_se.position.x and CLAIMS[1].z == tent_se.position.z, "at the tent's own position")
	check(#RELEASED == 1 and RELEASED[1].sec == "itm_tent", "the stock freed the used item")
	-- GAMMA: the sleeping bag through the action functor
	fresh("host")
	db.actor._pos = vec3(6, 0, 6)
	local _, b = item("itm_sleepbag")
	item_tent.func_use_bag(b)
	run_time_events(100)
	check(#CLAIMS == 1 and CLAIMS[1].what == "sleepbag", "func_use_bag: claim_tent(..., 'sleepbag')")
	check(count_sec("ph_sleepbag") == 1 and count_sec("compression_bag") == 1, "the stock placed the bag and gave the compression bag")
	-- stock Anomaly: the engine eats it and the stock callback places it
	fresh("host")
	local _, b2 = item("itm_sleepbag")
	engine_eat(b2)
	fire("actor_on_item_use", b2)
	run_time_events(100)
	check(#CLAIMS == 1 and CLAIMS[1].what == "sleepbag", "the use callback: one claim (callback and functor never both claim)")
	-- a tent that was there before is not claimed again
	fresh("host")
	local _, old_tent = spawn("ph_tent", vec3(1, 0, 1))
	item_tent.get_spawned_tents()[old_tent:id()] = true
	local _, o3 = item("itm_tent")
	coop_tent_guard.on_game_start()
	item_tent.func_use_tent(o3)
	run_add_calls()
	run_time_events(100)
	check(#CLAIMS == 1, "only the new tent is claimed, not the one that was already known")
	-- no session / client: nothing
	fresh("sp")
	local _, o4 = item("itm_tent")
	item_tent.func_use_tent(o4)
	run_add_calls()
	local _, o5 = item("itm_sleepbag")
	item_tent.func_use_bag(o5)
	run_time_events(100)
	check(#CLAIMS == 0 and count_sec("ph_tent") == 1 and count_sec("ph_sleepbag") == 1, "single player: the stock works, no claims")
	-- the host packs with the stock bag: nothing is claimed
	fresh("host")
	local _, tent = spawn("ph_tent", vec3(1, 0, 0))
	item_tent.get_spawned_tents()[tent:id()] = true
	local _, bag = item("itm_tent_bag")
	item_tent.itm_tent_bag_func()
	check(#CLAIMS == 0 and #RELEASED >= 1, "the host's stock pack-up runs as it is")
end)

case("host_refused_is_a_tip", function()
	fresh("host")
	fire("coop_checkpoint_refused", "combat", "tent")
	check(MSG == STR.st_coop_cp_refused_combat and MSG ~= nil, "the host's own claim refused: the tip")
end)

case("tent_placed_for_a_client", function()
	fresh("host")
	local _, t = spawn("ph_tent", vec3(5, 0, 5))
	local _, s = spawn("ph_sleepbag", vec3(6, 0, 5))
	fire("coop_tent_placed", t:id(), 500)
	fire("coop_tent_placed", s:id(), 500)
	check(item_tent.get_spawned_tents()[t:id()] == true and item_tent.get_spawned_sleepbags()[s:id()] == true,
		"a client's tent and sleeping bag go into the stock lists, so the host's bag can pack them")
	check(item_tent.get_spawned_sleepbags()[t:id()] == nil and item_tent.get_spawned_tents()[s:id()] == nil, "each into its own list")
	check(#CLAIMS == 0, "and they are not claimed as the host's own")
	fire("coop_tent_placed", 99999, 500)
	fire("coop_tent_placed", "x", 500)
	fire("coop_tent_placed", nil, nil)
	check(true, "an unknown object or garbage: no error")
	local _, other = spawn("bolts_pack", vec3(0, 0, 0))
	fire("coop_tent_placed", other:id(), 500)
	check(item_tent.get_spawned_tents()[other:id()] == nil and item_tent.get_spawned_sleepbags()[other:id()] == nil, "another section is not added")
	-- the callback queue is lossy: the first update checks again by the owner the engine knows
	fresh("host")
	local _, t1 = spawn("ph_tent", vec3(5, 0, 5))
	local _, t2 = spawn("ph_tent", vec3(7, 0, 5))
	local _, s1 = spawn("ph_sleepbag", vec3(9, 0, 5))
	local _, s2 = spawn("ph_sleepbag", vec3(11, 0, 5))
	OWNERS[t1:id()], OWNERS[s1:id()] = 500, 500
	fire("actor_on_first_update")
	local tents, bags = item_tent.get_spawned_tents(), item_tent.get_spawned_sleepbags()
	check(tents[t1:id()] == true and bags[s1:id()] == true, "first update: the objects tent_owner() names are in the stock lists")
	check(tents[t2:id()] == nil and bags[s2:id()] == nil, "nobody's tents and bags are not")
	check(#CLAIMS == 0, "no claims from it")
	fresh("client")
	local _, ct = spawn("ph_tent", vec3(5, 0, 5))
	OWNERS[ct:id()] = 500
	fire("actor_on_first_update")
	check(item_tent.get_spawned_tents()[ct:id()] == nil, "a client does not touch the stock lists")
	fresh("host")
	local co = coop.checkpoint
	coop.checkpoint = { get = co.get }
	local okr = pcall(fire, "actor_on_first_update")
	coop.checkpoint = co
	check(okr, "no tent_owner in the engine: harmless")
end)


-- ------------------------------------------------------------------ review round 1
-- I-1: the spots of a camp are not in the save, so a loaded world does not carry the spots of the old camps
case("spots_after_a_load", function()
	for _, variant in ipairs({ "same Lua state", "new Lua state" }) do
		fresh("host")
		fire("coop_checkpoint_changed", 0, "campfire", 123, false, "l01_escape")
		check(SPOTS[123] ~= nil and SPOTS[123].ser == false, variant .. ": the camp's spot is not serializable (it is not saved)")
		reload_world()
		if variant == "new Lua state" then reload_scripts() end
		CP_RECORD[0] = { kind = "campfire", level = "l01_escape", x = 1, y = 2, z = 3, source = 123 }
		fire("actor_on_first_update")
		check(SPOTS[123] ~= nil, variant .. ": after the load the world is read again: the spot is back")
		fire("coop_checkpoint_changed", 0, "campfire", 124, false, "l01_escape")
		check(SPOTS[123] == nil and SPOTS[124] ~= nil, variant .. ": the camp moves on: no spot is left on the old campfire")
	end
	-- a level change: the allies' spots too
	fresh("client")
	fire("coop_checkpoint_changed", 500, "campfire", 300, false, "l01_escape")
	reload_world()
	CP_RECORD[500] = { kind = "campfire", level = "l01_escape", x = 1, y = 2, z = 3, source = 300 }
	fire("actor_on_first_update")
	fire("coop_checkpoint_changed", 500, "tent", 301, false, "l01_escape")
	check(SPOTS[300] == nil and SPOTS[301] ~= nil, "an ally's old campfire spot is not left behind either")
	-- the stock puts the same spot on every sleep zone (pda.script) and on tents: those stay, saved or not
	fresh("host")
	SPOTS[900] = { typ = SPOT, hint = "st_ui_pda_sleep_place", n = 1, ser = true }
	fire("coop_checkpoint_changed", 0, "rest", 900, false, "l01_escape")
	reload_world()
	reload_scripts()
	CP_RECORD[0] = { kind = "rest", level = "l01_escape", x = 1, y = 2, z = 3, source = 900 }
	fire("actor_on_first_update")
	fire("coop_checkpoint_changed", 0, "campfire", 124, false, "l01_escape")
	check(SPOTS[900] ~= nil and SPOT_REMOVES[900] == nil and SPOT_ADDS[900] == nil, "a sleep zone keeps its stock spot")
	-- an exe that has no non-serializable spot call falls back to the serializable one
	fresh("host")
	local plain = level.map_add_object_spot
	level.map_add_object_spot = nil
	fire("coop_checkpoint_changed", 0, "campfire", 125, false, "l01_escape")
	level.map_add_object_spot = plain
	check(SPOTS[125] ~= nil, "no map_add_object_spot: map_add_object_spot_ser is used")
	-- M-4: resting at the same place again leaves the spot alone
	fresh("host")
	fire("coop_checkpoint_changed", 0, "campfire", 123, false, "l01_escape")
	fire("coop_checkpoint_changed", 0, "campfire", 123, false, "l01_escape")
	check(SPOT_ADDS[123] == 1 and SPOT_REMOVES[123] == nil and SPOTS[123] ~= nil, "the same camp again: the spot is not taken off and put on again")
	fire("coop_checkpoint_changed", 0, "rest", 123, false, "l01_escape")
	check(SPOT_ADDS[123] == 1 and SPOTS[123] ~= nil, "the same source with another kind: still the same spot")
end)

-- I-2: the clients' tents are in the stock list now; the stock get_nearby_tent looks at the first online tent only
case("get_nearby_tent_two_tents", function()
	local IDS = {}
	for id = 3000, 3011 do IDS[#IDS + 1] = id end
	local function put_tents(host_id, other_id, other_z)
		SE, OBJ = {}, {}
		make_actor(vec3(0, 0, 0))
		spawn("ph_tent", vec3(0, 0, 1), nil, { id = host_id })
		spawn("ph_tent", vec3(0, 0, other_z), nil, { id = other_id })
		local tents = item_tent.get_spawned_tents()
		for k in pairs(tents) do tents[k] = nil end
		tents[host_id], tents[other_id] = true, true
		OWNERS[host_id], OWNERS[other_id] = 0, 500
	end
	-- the control: the stock alone, in the same world, loses the host's tent in some orders (so the stand-in is the stock)
	fresh("host")
	local stock_fails = 0
	load_mini()
	item_tent.on_game_start()
	for _, a in ipairs(IDS) do
		for _, b in ipairs(IDS) do
			if a ~= b then
				put_tents(a, b, 5)
				if item_tent.get_nearby_tent(3.5, true) ~= a then stock_fails = stock_fails + 1 end
			end
		end
	end
	check(stock_fails > 0, "control: the stock get_nearby_tent loses the host's tent in " .. stock_fails .. " of 132 orders")
	-- the adapter
	fresh("host")
	local bad, total = 0, 0
	for _, a in ipairs(IDS) do
		for _, b in ipairs(IDS) do
			if a ~= b then
				total = total + 1
				put_tents(a, b, 5)
				if item_tent.get_nearby_tent(3.5, true) ~= a or item_tent.get_nearby_tent(3.5) ~= true or item_tent.get_nearby_tent(0.5) ~= false then
					bad = bad + 1
				end
			end
		end
	end
	check(bad == 0 and total == 132, "host: his own tent is found whatever the order (" .. bad .. " of " .. total .. " wrong)")
	-- the host's bag packs his own tent, not the client's
	local released_ok = true
	for _, pair in ipairs({ { 3000, 3001 }, { 3001, 3000 }, { 3005, 3002 }, { 3002, 3005 } }) do
		put_tents(pair[1], pair[2], 5)
		RELEASED = {}
		item("itm_tent_bag")
		item_tent.itm_tent_bag_func()
		local ids = {}
		for _, r in ipairs(RELEASED) do ids[r.id] = true end
		if not ids[pair[1]] or ids[pair[2]] then released_ok = false end
	end
	check(released_ok, "the host's tent bag releases his tent, not the one of the client next to it")
	-- a client's tent alone near the host: the host may pack it (CHECKPOINTS_DEATH 10.2)
	put_tents(3000, 3001, 2)
	SE[3000], OBJ[3000] = nil, nil
	check(item_tent.get_nearby_tent(3.5, true) == 3001, "only the client's tent in reach: it is found (the host's bag can pack it)")
	-- no tent online: nil, as stock; one online and far: false, as stock
	SE, OBJ = {}, {}
	make_actor(vec3(0, 0, 0))
	check(item_tent.get_nearby_tent(3.5, true) == nil, "no tent online: nil as stock")
	spawn("ph_tent", vec3(0, 0, 50), nil, { id = 3003 })
	item_tent.get_spawned_tents()[3003] = true
	check(item_tent.get_nearby_tent(3.5, true) == false, "an online tent out of reach: false as stock")
	-- a client: my tent first, and mine even when the snapshot of the host's list has not got it
	fresh("client")
	SE, OBJ = {}, {}
	make_actor(vec3(0, 0, 0))
	spawn("ph_tent", vec3(0, 0, 0.5), nil, { id = 3100 }) -- the host's, nearer
	spawn("ph_tent", vec3(0, 0, 1.5), nil, { id = 3101 }) -- mine, not in the snapshot
	item_tent.get_spawned_tents()[3100] = true
	check(item_tent.get_nearby_tent(1.0, true) == 3100, "client, my tent unknown: any tent in reach is a shelter")
	fire("coop_checkpoint_changed", 0, "tent", 3101, false, "l01_escape")
	check(item_tent.get_nearby_tent(2.0, true) == 3101, "client: my own tent first, though it is farther")
	SE[3100], OBJ[3100] = nil, nil
	check(item_tent.get_nearby_tent(2.0) == true and item_tent.get_nearby_tent(1.0) == false, "client: my tent counts although the snapshot has not got it")
	-- single player: the stock function, untouched
	fresh("sp")
	SE, OBJ = {}, {}
	make_actor(vec3(0, 0, 0))
	spawn("ph_tent", vec3(0, 0, 1), nil, { id = 3200 })
	item_tent.get_spawned_tents()[3200] = true
	check(item_tent.get_nearby_tent(3.5, true) == 3200 and item_tent.get_nearby_tent(0.5) == false, "single player: the stock result")
	local ok = pcall(item_tent.get_nearby_tent, nil, nil)
	check(not ok, "single player: the stock function is called as it is (it fails for no distance, like stock)")
end)

-- I-3, Ruling F3-11: a client packs up any tent of his by using it (the host knows whose it is and gives the item back)
case("pack_any_own_tent", function()
	fresh("client")
	db.actor._pos = vec3(2, 0, 2)
	local _, t1 = spawn("ph_tent", vec3(3, 0, 2))
	local _, t2 = spawn("ph_tent", vec3(3.5, 0, 6))
	fire("coop_checkpoint_changed", 0, "tent", t1:id(), false, "l01_escape")
	fire("coop_checkpoint_changed", 0, "tent", t2:id(), false, "l01_escape")
	check(ck().own_tent_source() == t2:id(), "model: the second tent is the camp now")
	fire("physic_object_on_use_callback", t1, db.actor)
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack", "the first tent, which is no longer the camp: a pack-up claim")
	check(CLAIMS[1] and CLAIMS[1].x == 3 and CLAIMS[1].z == 2, "at that tent's position (the engine packs the one at that spot)")
	fire("coop_checkpoint_refused", "failed", "pack")
	fire("physic_object_on_use_callback", t2, db.actor)
	run_time_events(200)
	check(#CLAIMS == 2 and CLAIMS[2].x == 3.5 and CLAIMS[2].z == 6, "and the second one at its own position")
	-- somebody else's tent: nothing
	fire("coop_checkpoint_refused", "failed", "pack")
	local _, foreign = spawn("ph_tent", vec3(2, 0, 3))
	CUSTOM[foreign:id()] = { coop_tent = { owner = "f00dfeed" } }
	CUSTOM[0] = { coop = { key = "c0ffee11" } }
	fire("physic_object_on_use_callback", foreign, db.actor)
	run_time_events(200)
	check(#CLAIMS == 2, "a tent whose owner key is another player's: nothing")
	-- after a load only the camp is known: the older tent is told apart by its owner key on its custom data
	CP_RECORD[0] = { kind = "tent", level = "l01_escape", x = 1, y = 2, z = 3, source = t2:id() }
	fire("actor_on_first_update")
	CUSTOM[t1:id()] = { coop_tent = { owner = "c0ffee11" } }
	fire("physic_object_on_use_callback", t1, db.actor)
	run_time_events(200)
	check(#CLAIMS == 3 and CLAIMS[3].x == 3 and CLAIMS[3].z == 2, "after a load: the tent with my key on it is mine")
	fire("coop_checkpoint_refused", "failed", "pack")
	fire("physic_object_on_use_callback", foreign, db.actor)
	run_time_events(200)
	check(#CLAIMS == 3, "and the other player's is not")
	local _, nokey = spawn("ph_tent", vec3(2, 0, 4))
	fire("physic_object_on_use_callback", nokey, db.actor)
	run_time_events(200)
	check(#CLAIMS == 3, "a tent with no key at all (the host's stock tent): not mine")
	-- no key of my own readable: the camp is still known, the rest is not guessed
	fresh("client")
	local _, t3 = spawn("ph_tent", vec3(3, 0, 2))
	CUSTOM[t3:id()] = { coop_tent = { owner = "c0ffee11" } }
	fire("physic_object_on_use_callback", t3, db.actor)
	run_time_events(200)
	check(#CLAIMS == 0, "no key of my own to compare with: nothing is guessed")
	-- a sleeping bag is used to sleep (stock); it is packed by the compression bag, or by pack_nearby() from the sleep window
	fresh("client")
	db.actor._pos = vec3(2, 0, 2)
	local _, bag = spawn("ph_sleepbag", vec3(2, 0, 2.5))
	fire("coop_checkpoint_changed", 0, "tent", bag:id(), false, "l01_escape")
	fire("physic_object_on_use_callback", bag, db.actor)
	run_time_events(200)
	check(#CLAIMS == 0 and #SLEPT == 1, "using my sleeping bag: the stock sleep, no pack-up")
	check(type(ck().pack_nearby) == "function", "coop_checkpoints.pack_nearby exists (a button of the sleep window can call it)")
	check(ck().pack_nearby() == true, "pack_nearby() asks")
	run_time_events(200)
	check(#CLAIMS == 1 and CLAIMS[1].what == "pack" and CLAIMS[1].x == 2 and CLAIMS[1].z == 2, "a pack-up claim at the player's position (the bag is within reach)")
	fire("coop_checkpoint_refused", "failed", "pack")
	local _, comp = item("compression_bag")
	item_tent.use_compression_bag(comp, 1.5)
	run_time_events(200)
	check(#CLAIMS == 2 and CLAIMS[2].what == "pack", "the compression bag does it as before")
	fire("coop_checkpoint_refused", "failed", "pack")
	-- the sleep window's «Fold» passes the bag the player sleeps in (T13 review M-11: the claim has no kind or id)
	check(ck().pack_nearby(vec3(2, 0, 2.5)) == true, "pack_nearby(at) asks")
	run_time_events(200)
	check(#CLAIMS == 3 and CLAIMS[3].what == "pack" and CLAIMS[3].z == 2.5, "pack_nearby(at): the claim is at the bag, not at the player")
	-- the host: nothing
	fresh("host")
	check(ck().pack_nearby() == false, "pack_nearby() on the host: nothing (he has the stock bag)")
end)

-- M-1: a mod that wrapped scenario_autosave after us must not turn the wrappers into a loop
case("story_wrapper_chain", function()
	for _, mode in ipairs({ "sp", "host" }) do
		fresh(mode)
		local before = xr_effects.scenario_autosave
		local MOD = 0
		local prev = xr_effects.scenario_autosave
		xr_effects.scenario_autosave = function(a, n, p) MOD = MOD + 1; if MOD > 100 then error("loop") end; return prev(a, n, p) end
		local mod_fn = xr_effects.scenario_autosave
		fire("actor_on_first_update")
		check(xr_effects.scenario_autosave ~= mod_fn and xr_effects.scenario_autosave ~= before, mode .. ": the mod's wrapper is wrapped, not a loop")
		local ok, err = pcall(xr_effects.scenario_autosave, nil, nil, { "st_save_x" })
		check(ok, mode .. ": calling it does not overflow the stack or hang (" .. tostring(err) .. ")")
		if mode == "sp" then
			check(MOD == 1 and ORIG_STORY == 1, "outside a session: the mod's function and the original run once each (" .. MOD .. "," .. ORIG_STORY .. ")")
		else
			check(#STORIES == 1 and ORIG_STORY == 0 and #EXEC == 0, "in a session: one story checkpoint, nothing saved")
		end
		local once = xr_effects.scenario_autosave
		fire("actor_on_first_update")
		ck().on_game_start()
		check(xr_effects.scenario_autosave == once, mode .. ": our own wrapper is never wrapped again")
	end
	-- a chain that comes back to us: the call ends, the second visit does nothing
	fresh("sp")
	local top
	local CALLS_ = 0
	local inner = xr_effects.scenario_autosave
	xr_effects.scenario_autosave = function(a, n, p)
		CALLS_ = CALLS_ + 1
		if CALLS_ > 200 then error("loop") end -- would loop for ever
		if CALLS_ < 50 then return top(a, n, p) end
		return inner(a, n, p)
	end
	fire("actor_on_first_update")
	top = xr_effects.scenario_autosave
	local ok = pcall(top, nil, nil, { "st_save_x" })
	check(ok and CALLS_ < 50, "a mod that calls back into the top function: the loop ends at once (" .. CALLS_ .. " calls)")
	CALLS_ = 100
	local ok2 = pcall(top, nil, nil, { "st_save_x" })
	check(ok2 and CALLS_ >= 100 and ORIG_STORY >= 1, "and the wrappers work again afterwards")
	-- an error in the original: the flag is let go
	fresh("sp")
	local boom = true
	xr_effects.scenario_autosave = function() if boom then error("boom") end end
	fire("actor_on_first_update")
	check(not pcall(xr_effects.scenario_autosave, nil, nil, {}), "an error of the original comes through")
	boom = false
	check(pcall(xr_effects.scenario_autosave, nil, nil, {}), "and the next call works (the guard flag was let go)")
end)

-- M-2: use_placeable = false for the tent: the client does not lose the item, nothing is claimed
case("tent_not_placeable_on_a_client", function()
	fresh("client")
	TENT_PLACEABLE = false
	itms_manager = { ini_manager = make_ini({ tent_i_bag = { use_placeable = "false" } }) }
	reload_checkpoints()
	item_tent.on_game_start()
	local _, o = item("itm_tent")
	item_tent.func_use_tent(o)
	local okc, errc = pcall(function() run_add_calls(); run_time_events(5000) end)
	itms_manager = nil
	check(okc, "the stock functor runs without an error (" .. tostring(errc) .. ")")
	check(#CLAIMS == 0, "no claim")
	check(count_sec("itm_tent") == 1 and count_sec("ph_tent") == 0, "the player still has exactly one tent item, nothing is put up (" .. created_secs() .. ")")
end)

-- M-3: a mod that replaces an entry point after our on_game_start is wrapped at the first update
case("adapter_installed_again", function()
	fresh("client")
	local mod_calls = 0
	item_tent.func_use_tent = function() mod_calls = mod_calls + 1 end
	local mine_ = item_tent.func_use_tent
	fire("actor_on_first_update")
	check(item_tent.func_use_tent ~= mine_, "the replaced func_use_tent is wrapped again at the first update")
	local _, o = item("itm_tent")
	item_tent.func_use_tent(o)
	run_time_events(5000)
	check(mod_calls == 0 and #CLAIMS == 1, "and a client's use asks the host, the mod's function does not run")
end)

-- ------------------------------------------------------------------ refusals
case("refused_tip", function()
	fresh("client")
	fire("coop_checkpoint_refused", "combat", "tent")
	check(MSG == STR.st_coop_cp_refused_combat and MSG ~= nil and MSG ~= "st_coop_cp_refused_combat", "refused 'combat': st_coop_cp_refused_combat")
	for _, r in ipairs({ "dead", "far", "combat", "limit", "no_item", "failed" }) do
		MSG = nil
		fire("coop_checkpoint_refused", r, "sleepbag")
		check(MSG == STR["st_coop_cp_refused_" .. r] and MSG ~= nil, "the reason " .. r .. " has its own text")
	end
	MSG = nil
	fire("coop_checkpoint_refused", "no_such_reason", "tent")
	check(MSG == STR.st_coop_cp_refused_failed, "an unknown reason reads as 'failed'")
	MSG = nil
	local ok = pcall(fire, "coop_checkpoint_refused", nil, nil)
	check(ok and MSG == STR.st_coop_cp_refused_failed, "no arguments: no error")
	-- the menu is closed so that the tip is seen
	EV = {}
	fire("coop_checkpoint_refused", "limit", "tent")
	check(EV[1] == "hide" and EV[2] == "msg", "the inventory is closed first, then the tip (" .. table.concat(EV, ",") .. ")")
end)

-- ------------------------------------------------------------------ the party panel mark
case("panel_mark", function()
	fresh("host")
	load_script("coop_allies")
	check(type(coop_allies.checkpoint_mark) == "function", "coop_allies.checkpoint_mark exists")
	check(coop_allies.checkpoint_mark(500, NOW) == nil, "no checkpoint update: no mark")
	fire("coop_checkpoint_changed", 500, "campfire", 123, false, "l01_escape")
	local at = NOW
	check(coop_allies.checkpoint_mark(500, at + 1000) == STR.st_coop_cp_panel and STR.st_coop_cp_panel ~= nil, "right after: the mark 'camp'")
	check(coop_allies.checkpoint_mark(500, at + 9900) == STR.st_coop_cp_panel, "still there at 9.9 s")
	check(coop_allies.checkpoint_mark(500, at + 10100) == nil, "gone after 10 s")
	check(coop_allies.checkpoint_mark(501, at + 1000) == nil and coop_allies.checkpoint_mark(nil, at) == nil, "another player, no player: nothing")
	check(coop_allies.checkpoint_mark("x", at) == nil and coop_allies.checkpoint_mark(500, at - 5000) == nil, "garbage and a time before the update: nothing")
	local saved = coop_checkpoints
	coop_checkpoints = { last_update = function() error("boom") end }
	check(coop_allies.checkpoint_mark(500, at) == nil, "a failing last_update: nothing, no error")
	coop_checkpoints = nil
	local ok = pcall(coop_allies.checkpoint_mark, 500, at)
	coop_checkpoints = saved
	check(ok, "no coop_checkpoints script: no error")
end)

-- ------------------------------------------------------------------ item lists
case("lists_from_the_ltx", function()
	fresh("client")
	check(ck().item_kind("itm_tent") == "tent" and ck().item_kind("tent_bag") == "tent", "tents: itm_tent, tent_bag")
	check(ck().item_kind("itm_sleepbag") == "sleepbag" and ck().item_kind("sleep_bag") == "sleepbag", "sleeping bags: itm_sleepbag, sleep_bag")
	check(ck().item_kind("itm_tent_bag") == "pack" and ck().item_kind("compression_bag") == "pack", "pack-up tools: itm_tent_bag, compression_bag")
	check(ck().item_kind("bolts_pack") == nil and ck().item_kind(nil) == nil, "anything else: nothing")
	check(ck().object_kind("ph_tent") == "tent" and ck().object_kind("ph_sleepbag") == "sleepbag" and ck().object_kind("x") == nil, "object kinds")
	-- the stock ini (itms_manager.ini_manager) wins over the defaults
	fresh("client")
	local data = {
		sleeping_bag = { enable = "true", use_placeable = "true" },
		sleeping_bag_sections = { "my_sleepbag" },
		sleeping_bag_ph_sections = { "my_ph_bag" },
		tent_i_bag_sections = { "my_tent" },
		tent_i_bag_ph_sections = { "my_ph_tent" },
	}
	itms_manager = { ini_manager = make_ini(data) }
	reload_checkpoints()
	check(ck().item_kind("my_tent") == "tent" and ck().item_kind("my_sleepbag") == "sleepbag", "item lists are read from itms_manager.ini_manager")
	check(ck().item_kind("itm_tent") == nil, "the stock names are not added on top")
	check(ck().object_kind("my_ph_tent") == "tent" and ck().object_kind("my_ph_bag") == "sleepbag", "object lists too")
	check(ck().placeable("sleepbag") == true and ck().placeable("tent") == true, "use_placeable defaults to true")
	data.sleeping_bag.enable = "false"
	reload_checkpoints()
	check(ck().item_kind("my_sleepbag") == nil, "sleeping bags switched off in the ltx: not one of ours")
	data.sleeping_bag.enable = "true"
	data.sleeping_bag.use_placeable = "false"
	reload_checkpoints()
	check(ck().placeable("sleepbag") == false, "use_placeable = false is read")
	-- an ini with the section missing keeps the stock defaults
	itms_manager = { ini_manager = make_ini({}) }
	reload_checkpoints()
	check(ck().item_kind("itm_tent") == "tent" and ck().object_kind("ph_sleepbag") == "sleepbag", "missing sections: the stock names")
	itms_manager = nil
end)

-- ------------------------------------------------------------------ the script lists and the callbacks they register
case("registration", function()
	fresh("host")
	check(registered("coop_checkpoint_changed") == 1 and registered("coop_checkpoint_refused") == 1, "the two engine callbacks are registered once")
	check(registered("coop_tent_placed") == 1, "and coop_tent_placed")
	check(registered("actor_on_first_update") >= 1 and registered("actor_on_update") >= 1, "first update and update")
	local before = registered("coop_checkpoint_changed")
	ck().on_game_start()
	check(registered("coop_checkpoint_changed") == before, "a second on_game_start does not register again")
end)

-- ------------------------------------------------------------------ the string tables
case("string_tables", function()
	local IDS = {
		"st_coop_cp_updated_campfire", "st_coop_cp_updated_rest", "st_coop_cp_updated_tent", "st_coop_cp_updated_arrival",
		"st_coop_cp_updated_story", "st_coop_cp_updated_mod", "st_coop_cp_rollback", "st_coop_cp_rollback_none",
		"st_coop_cp_ally", "st_coop_cp_spot", "st_coop_cp_panel",
		"st_coop_cp_refused_combat", "st_coop_cp_refused_dead", "st_coop_cp_refused_far", "st_coop_cp_refused_far_pack",
		"st_coop_cp_refused_limit", "st_coop_cp_refused_no_item", "st_coop_cp_refused_failed",
		"st_coop_cp_claim_busy", "st_coop_cp_unsupported",
	}
	local HEADER = '<?xml version="1.0" encoding="windows-1251"?>'
	for _, lang in ipairs({ "eng", "rus" }) do
		local path = "gamedata/configs/text/" .. lang .. "/st_coop_checkpoints.xml"
		local raw = read(path)
		check(raw ~= nil, lang .. ": st_coop_checkpoints.xml exists")
		if raw then
			check(raw:sub(1, #HEADER) == HEADER, lang .. ": windows-1251 header")
			check(not raw:gsub("\r\n", ""):find("\n", 1, true), lang .. ": CRLF line ends only")
			local t = strings_of(path)
			for _, id in ipairs(IDS) do
				check(type(t[id]) == "string" and #t[id] > 0, lang .. ": " .. id .. " has a text")
			end
			check((t.st_coop_cp_ally or ""):find("%s", 1, true) ~= nil, lang .. ": st_coop_cp_ally has a place for the nick")
			if lang == "rus" then
				local all = {}
				for _, id in ipairs(IDS) do all[#all + 1] = t[id] or "" end
				local joined = table.concat(all, "\n")
				check(joined:find("[\192-\255]") ~= nil and not joined:find("[\208\209][\128-\191]"), "rus: cp1251 Cyrillic, not UTF-8")
				check(t.st_coop_cp_updated_campfire ~= STR.st_coop_cp_updated_campfire, "rus: translated, not a copy of the English text")
			else
				local all = {}
				for _, id in ipairs(IDS) do all[#all + 1] = t[id] or "" end
				check(not table.concat(all):find("[\128-\255]"), "eng: ASCII only")
			end
		end
	end
	-- every string id the scripts ask for is in the table
	for _, name in ipairs({ "coop_checkpoints", "coop_tent_guard" }) do
		local src = read("gamedata/scripts/" .. name .. ".script") or ""
		local missing = {}
		for key in src:gmatch('tell%("([%w_]+)"%s*[,%)]') do
			if not STR["st_coop_cp_" .. key] then missing[#missing + 1] = key end
		end
		for key in src:gmatch('text%("([%w_]+)"%s*[,%)]') do
			if not STR["st_coop_cp_" .. key] then missing[#missing + 1] = key end
		end
		check(#missing == 0, name .. ": every literal tell()/text() key is a string (" .. table.concat(missing, ",") .. ")")
	end
end)

done("CHECKPOINTS")
