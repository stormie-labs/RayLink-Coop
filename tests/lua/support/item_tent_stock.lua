-- Anomaly Coop test support: a faithful miniature of the stock item_tent.script (anomaly-ref/unpacked/scripts/item_tent.script),
-- shared by test_tent_guard.lua and test_checkpoints.lua. Same names, same globals, same file locals, same local
-- actor_on_item_use that on_game_start registers, loaded the way the engine loads a script (module table = environment,
-- __index = _G), so that the lookup of start_timer & co. from inside the local function goes through the module table
-- that coop_tent_guard writes to. Not shipped.
--
-- Globals the miniature reads (set them in the test): NEAR_TENT (id get_nearby_tent returns), SLEEP_ENABLE /
-- SLEEP_PLACEABLE (false turns the ltx setting off), ADD_CALLS (level.add_call functors are collected there).
-- It writes NON_PLACEABLE (counts the non-placeable sleeping bag branch).
-- Needs from the harness: alife_create, alife_create_item, alife_object, alife_release, level.object_by_id,
-- level.map_add_object_spot_ser, actor_effects.play_item_fx, hide_hud_inventory, CreateTimeEvent, RegisterScriptCallback.

ITEM_TENT_MINI = [[
local spawned_tents = {}
local spawned_sleepbags = {}
local SleepBagEnable, SleepBagPlaceable, SleepBagSections

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
	for id, v in pairs(spawned_sleepbags) do
		local obj = level.object_by_id(id)
		if obj and (v == true) then
			local sec = obj:section()
			if (sec == "ph_sleepbag") then
				local sp_distance = obj:position():distance_to(db.actor:position())
				if (sp_distance < dist) then
					local se_comp = obj_c and obj_c:id() and alife_object(obj_c:id())
					local se_sleepbag = alife_object(id)
					if se_comp and se_sleepbag then
						alife_create_item("itm_sleepbag", db.actor)
						alife_release(se_comp)
						alife_release(se_sleepbag)
						spawned_sleepbags[id] = nil
						break
					end
				end
			end
		end
	end
end

function get_spawned_tents() return spawned_tents end
function get_spawned_sleepbags() return spawned_sleepbags end

local function actor_on_item_use(obj)
	local sec = obj:section()
	if (sec == "itm_tent") or (sec == "itm_tent_bag" and get_nearby_tent(3.5, true)) then
		actor_effects.play_item_fx("itm_sleepbag")
		start_timer(obj)
	end
	if (SleepBagEnable and SleepBagSections[sec]) then
		if (SleepBagPlaceable) then
			local se_obj = alife_create("ph_sleepbag", db.actor:position(), db.actor:level_vertex_id(), db.actor:game_vertex_id())
			level.map_add_object_spot_ser(se_obj.id, "ui_pda2_actor_sleep_location", "bag")
			spawned_sleepbags[se_obj.id] = true
			alife_create_item("compression_bag", db.actor)
		else
			local se_obj = alife_create_item(sec, db.actor)
			_G.NON_PLACEABLE = (_G.NON_PLACEABLE or 0) + 1
		end
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
	SleepBagEnable = SLEEP_ENABLE ~= false
	SleepBagPlaceable = SleepBagEnable and SLEEP_PLACEABLE ~= false
	SleepBagSections = SleepBagEnable and { itm_sleepbag = true, sleep_bag = true }
	RegisterScriptCallback("actor_on_item_use", actor_on_item_use)
end
]]

-- Loads a fresh stock module into the global item_tent and returns it.
function load_mini()
	local header = 'local this = {} item_tent = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	local f = assert(loadstring(header .. ITEM_TENT_MINI, "@D:\\Games\\Anomaly\\gamedata\\scripts\\item_tent.script"))
	f()
	return item_tent
end
