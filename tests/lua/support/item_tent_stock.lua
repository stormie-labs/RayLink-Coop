-- Anomaly Coop test support: the stock item_tent.script (anomaly-ref/unpacked/scripts/item_tent.script) as the tests run it,
-- shared by test_tent_guard.lua and test_checkpoints.lua. Not shipped. The function bodies are the stock ones (F3 T13 round 1,
-- review M-8: the earlier miniature simplified get_nearby_tent, which hid review I-2); what differs is marked "TEST:".
-- Same names, same globals, same file locals, same local actor_on_item_use / physic_object_on_use_callback that on_game_start
-- registers, loaded the way the engine loads a script (module table = environment, __index = _G), so that the lookup of
-- start_timer & co. from inside the local functions goes through the module table that coop_tent_guard writes to.
--
-- Globals the module reads (set them in the test): SLEEP_ENABLE / SLEEP_PLACEABLE / TENT_PLACEABLE (false turns the ltx setting
-- off), ADD_CALLS (level.add_call functors are collected there), ANIMATIONS (ui_options). It writes NON_PLACEABLE (counts the
-- non-placeable sleeping bag branch) and SLEPT (ui_sleep_dialog.sleep_bag calls).
-- Needs from the harness: alife_create, alife_create_item, alife_object, alife_release, level.object_by_id,
-- level.map_add_object_spot_ser, actor_effects.play_item_fx, hide_hud_inventory, CreateTimeEvent, RegisterScriptCallback,
-- ui_options, db.actor.

-- stock vector arithmetic (pos:add(dir:mul(3)) mutates and returns the vector); the harness vector has none
do
	local VM = getmetatable(vector())
	if not VM.add then
		function VM.add(self, o) self.x, self.y, self.z = self.x + o.x, self.y + o.y, self.z + o.z; return self end
		function VM.mul(self, k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k; return self end
	end
end
ui_item = ui_item or { get_sec_name = function(sec) return sec end }
SLEPT = {}
ui_sleep_dialog = ui_sleep_dialog or { sleep_bag = function(...) SLEPT[#SLEPT + 1] = { ... } end }
TENT_INI = { r_string_ex = function() return nil end } -- itms_manager.ini_manager without a placeable_section line

ITEM_TENT_MINI = [[
local ini_tent
local TentBagPlaceable
local SleepBagEnable, SleepBagPlaceable, SleepBagSections, SleepBagPlaceableSections

-- for m.data
local spawned_tents = {}
local spawned_sleepbags = {}

function start_timer(obj)
	local enabled_animations = ui_options.get("video/player/animations")
	local iTimer = enabled_animations and (time_global() + 4000) or time_global()
	local function check_timer()
		return time_global() > iTimer
	end
	if (obj:section() == "itm_tent") then
		level.add_call(check_timer, itm_tent_func)
	end
	if (obj:section() == "itm_tent_bag") then
		level.add_call(check_timer, itm_tent_bag_func)
	end
end

function itm_tent_func()
	local sec = "itm_tent"
	if (TentBagPlaceable) then
		local pos = db.actor:position()
		local dir = db.actor:direction()
		pos = pos:add(dir:mul(3))
		local ph_sec = ini_sys:r_string_ex(sec,"placeable_section")
		local se_obj = alife_create(ph_sec or "ph_tent", pos, 1, db.actor:game_vertex_id())
		level.map_add_object_spot_ser(se_obj.id, "ui_pda2_actor_sleep_location", ui_item.get_sec_name(sec))
		spawned_tents[se_obj.id] = true
		alife_create_item("itm_tent_bag", db.actor)
	else
		alife_create_item(sec, db.actor)
	end
	return
end

function get_nearby_tent(dist, result)
	for id, v in pairs(spawned_tents) do
		local obj = level.object_by_id(id)
		if obj and (v == true) then
			local sec = obj:section()
			if (sec == "ph_tent") then
				local tent_distance = obj:position():distance_to(db.actor:position())
				if (tent_distance < dist) then
					if (result == true) then
						return id
					else
						return true
					end
				end
				return false
			end
		end
	end
end

function itm_tent_bag_func()
	local id = get_nearby_tent(3.5,true)
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

function use_compression_bag(obj_c,dist)
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

function get_spawned_tents()
	return spawned_tents
end

function get_spawned_sleepbags()
	return spawned_sleepbags
end

local function actor_on_item_use(obj)
	local sec = obj:section()

	-- Tent or Tent bag0
	if (sec == "itm_tent") or (sec == "itm_tent_bag" and get_nearby_tent(3.5,true)) then
		actor_effects.play_item_fx("itm_sleepbag")
		start_timer(obj)
	end

	-- Sleeping bag
	if (SleepBagEnable and SleepBagSections[sec]) then
		if (SleepBagPlaceable) then
			local ph_sec = ini_tent:r_string_ex(sec,"placeable_section")
			local se_obj = alife_create(ph_sec or "ph_sleepbag",db.actor:position(),db.actor:level_vertex_id(),db.actor:game_vertex_id())
			level.map_add_object_spot_ser(se_obj.id, "ui_pda2_actor_sleep_location", ui_item.get_sec_name(sec))
			spawned_sleepbags[se_obj.id] = true
			alife_create_item("compression_bag", db.actor)
		else
			local se_obj = alife_create_item(sec, db.actor)
			_G.NON_PLACEABLE = (_G.NON_PLACEABLE or 0) + 1 -- TEST: counts this branch
			hide_hud_inventory()
			local ui = ui_sleep_dialog.sleep_bag(se_obj,sec)
		end
	end

	-- Compression bag
	if (sec == "compression_bag") then use_compression_bag(obj,1.5) end
end

local function physic_object_on_use_callback(obj,who) -- bind_physic_object use_callback
	if (SleepBagEnable and SleepBagPlaceableSections[obj:section()]) then
		hide_hud_inventory()
		ui_sleep_dialog.sleep_bag(obj:id(),SleepBagPlaceableSections[obj:section()])
	end
end

local function save_state(m_data)
	m_data.spawned_tents = spawned_tents
	m_data.spawned_sleepbags = spawned_sleepbags
end

local function load_state(m_data)
	spawned_tents = m_data.spawned_tents or {}
	spawned_sleepbags = m_data.spawned_sleepbags or {}
end

-- TEST: the stock names the event after obj:name(), which the harness objects do not have
local function release_later(obj)
	CreateTimeEvent(0, "release_" .. obj:id(), 0, function(x)
		local se = alife_object(x)
		_ = se and alife_release(se)
		return true
	end, obj:id())
end

function str_use() return 'st_item_use' end
function func_use_bag(obj)
	if obj then
		actor_on_item_use(obj)
		release_later(obj)
	end
end
function func_use_tent(obj)
	if obj then
		actor_on_item_use(obj)
		release_later(obj)
	end
end

-- TEST: the ltx reads are knobs (SLEEP_ENABLE, SLEEP_PLACEABLE, TENT_PLACEABLE)
function on_game_start()
	local m = rawget(_G, "itms_manager")
	ini_tent = m and m.ini_manager or TENT_INI

	TentBagPlaceable = TENT_PLACEABLE ~= false
	SleepBagEnable = SLEEP_ENABLE ~= false
	SleepBagPlaceable = SleepBagEnable and SLEEP_PLACEABLE ~= false
	SleepBagSections = SleepBagEnable and { itm_sleepbag = true, sleep_bag = true }
	SleepBagPlaceableSections = SleepBagEnable and { ph_sleepbag = "itm_sleepbag" }

	RegisterScriptCallback("actor_on_item_use",actor_on_item_use)
	RegisterScriptCallback("physic_object_on_use_callback",physic_object_on_use_callback)
	RegisterScriptCallback("save_state",save_state)
	RegisterScriptCallback("load_state",load_state)
end
]]

-- Loads a fresh stock module into the global item_tent and returns it.
function load_mini()
	local header = 'local this = {} item_tent = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	local f = assert(loadstring(header .. ITEM_TENT_MINI, "@D:\\Games\\Anomaly\\gamedata\\scripts\\item_tent.script"))
	f()
	return item_tent
end
