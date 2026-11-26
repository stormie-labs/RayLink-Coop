-- Dev 57 G11-1. Exercise the mod entry points against the real Lua facade and event codec.
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
local hospital, forest = "l11_hospital", "l10_red_forest"
local map, mirror, late = forest, false, false
local info, lights, sounds, casts = {}, {}, {}, {}
local pp, pp_removed = 0, 0

MODE = mode == "none" and "sp" or "host"
coop.is_dedicated = function() return mode == "srv_world" and not mirror end
coop.is_map_server = function() return mode == "srv_map" and not mirror end
coop.players = function()
	local here = map == hospital and 10 or 11
	return {
		{ id = 1, avatar_id = 500, level = here },
		{ id = 2, avatar_id = 501, level = mode == "hostplay" and here or 12 },
		{ id = 3, avatar_id = late and 502 or nil, level = late and here or nil },
		{ id = 4, avatar_id = 503, level = here },
	}
end
coop.sync = { broadcast = function(name, data, opts)
	casts[#casts + 1] = { name = name, data = data, peer = opts and opts.to }
	return true
end }

local facade = coop_mode
local answers = modes.set(mode)
modes.install(facade, mode, {
	leads_here = function() return not mirror and answers.leads_here() end,
	decides_world = function() return not mirror and answers.decides_world() end,
	is_player_mirror = function() return mirror end,
	actor_is_player = function() return mirror or answers.actor_is_player() end,
	where = function(peer)
		if peer == 3 and not late then return "joining" end
		if peer == 2 and mode ~= "hostplay" then return "away" end
		return answers.where(peer)
	end,
})

level.name = function() return map end
local original_alife = alife
function alife()
	local sim = original_alife()
	sim.level_name = function(_, id) return ({ [10] = hospital, [11] = forest, [12] = "labx8" })[id] end
	return sim
end
function has_alife_info(name) return info[name] == true end
level.add_pp_effector = function() pp = pp + 1 end
level.remove_pp_effector = function() pp_removed = pp_removed + 1 end
level.add_cam_effector = function() end
level.remove_cam_effector = function() end
function script_light()
	local light = { set_position = function(self, pos) self.pos = pos end, update = function() end }
	lights[#lights + 1] = light
	return light
end
sound_object = setmetatable({ s3d = 2, looped = 4 }, {
	__call = function(_, path)
		return {
			play_at_pos = function(self, obj, pos, delay, flags)
				sounds[#sounds + 1] = { path = path, obj = obj:id(), delay = delay, flags = flags, sound = self }
			end,
			stop = function(self) self.stopped = true end,
		}
	end,
})

local function fixture(name, source)
	local env = setmetatable({}, { __index = _G })
	_G[name] = env
	setfenv(assert(loadstring(source, "@" .. name .. ".script")), env)()
	return env
end

fixture("nta_utils", [[
function spawn_pulse(pos)
	local l = script_light()
	l:set_position(pos)
	l.enabled = false
	l:update()
	return "stock pulse"
end]])
fixture("task_status_functor", [[
function special_steps_for_lostzone_tasks(task, id)
	if id ~= "lttz_ms_hospital_assault" then return "other" end
	if has_alife_info("kat_greh_sabaoth_psi") and not has_alife_info("kat_greh_sabaoth_psi_attack") then
		level.add_pp_effector("psi.ppe", 15000, false)
		level.add_cam_effector("camera_effects\\fatigue.anm", 15000, false, "")
		info_set_attack()
		task.stage = 3
	elseif has_alife_info("kat_greh_sabaoth_psi_attack") and not has_alife_info("kat_greh_sabaoth_psi_end") then
		level.add_pp_effector("psi.ppe", 15000, false)
		task.stage = 4
	else
		task.stage = 5
	end
end]])
function info_set_attack() info.kat_greh_sabaoth_psi_attack = true end

local objects, saved = {}, {}
level.object_by_id = function(id) return objects[id] or OBJ[id] end
local function object(id, kind)
	return {
		id = function() return id end, name = function() return kind .. "_" .. id end,
		section = function() return kind end, alive = function() return false end, _kind = kind,
		position = function() return vec3(6, 3, 9) end,
		set_bone_visible = function(self, bone, visible) self[bone] = visible end,
	}
end
function se_save_var(id, _, key, value)
	saved[id] = saved[id] or {}
	saved[id][key] = value
end
function se_load_var(id, _, key) return saved[id] and saved[id][key] end
local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for k, v in pairs(value) do copy[k] = clone(v) end
	return copy
end
dup_table = clone
ui_mutant_loot = { UIMutantLoot = {
	Loot = function(self, close)
		self.loot.mutant_part_dog_tail = nil
		if close then return ui_mutant_loot.UIMutantLoot.SetMutantState(self, false, objects[self.id]) end
	end,
	SetMutantState = function() coop.send_event("core.mloot_close", "", 0) end,
} }

fixture("immersive_skinning", [[
function getMutantType() return "dog" end
function getBoneTable() return { mutant_part_dog_tail = { { "tail", "tail_end" } } } end
function loadBones(obj) return se_load_var(obj:id(), nil, "legacy") or getBoneTable() end
function saveBones(obj, bones) se_save_var(obj:id(), nil, "legacy", bones) end
function switchBones(obj, bone, visible)
	if type(bone) == "table" then
		for _, name in ipairs(bone) do obj:set_bone_visible(name, visible, true) end
	else
		obj:set_bone_visible(bone, visible, true)
	end
end
function on_game_start()
	Loot = ui_mutant_loot.UIMutantLoot.Loot
	ui_mutant_loot.UIMutantLoot.Loot = function(self, ...)
		local obj = level.object_by_id(self.id)
		local had_tail = self.loot.mutant_part_dog_tail
		Loot(self, ...)
		local bones = loadBones(obj)
		if had_tail and not self.loot.mutant_part_dog_tail and bones.mutant_part_dog_tail then
			switchBones(obj, bones.mutant_part_dog_tail[1], false)
			saveBones(obj, nil)
		end
	end
end]])

-- Use the engine's existing corpse lock shape without depending on other world patches for this fixture.
local function corpse_core()
	local locks = {}
	local function on_mloot_close(_, from) return locks[from] end
	return { on_game_start = function() return on_mloot_close end, locks = locks }
end
coop_core_world_mloot = corpse_core()
coop_core_world_news = { in_world_scope = function(f, ...) return f(...) end }

local function binder(name, class, prefix, door)
	local cls = {}
	local m = setmetatable({ [class] = cls }, { __index = _G })
	_G[name] = m
	local function sounds_for(self)
		self.start_snd = m.sound_object(prefix .. "_start")
		self.idle_snd = m.sound_object(prefix .. "_hum")
		self.stop_snd = m.sound_object(prefix .. "_stop")
		self.down_snd = m.sound_object(prefix .. "_down")
	end
	function cls:__init() if door then sounds_for(self) end end
	function cls:net_spawn() if not door then sounds_for(self) end return true end
	function cls:anim_forward()
		self.start_snd:play_at_pos(self.object, self.object:position(), 0, 2)
		self.idle_snd:play_at_pos(self.object, self.object:position(), 5, 6)
		self.bridge_idle, self.is_idle = true, false
	end
	cls.anim_backward = cls.anim_forward
	function cls:anim_stop()
		self.stop_snd:play_at_pos(self.object, self.object:position(), 0, 2)
		self.bridge_idle, self.is_idle = false, true
	end
	function cls:animation_end_callback(ended)
		if door and not ended then return end
		local snd = door and self.stop_snd or self.down_snd
		snd:play_at_pos(self.object, self.object:position(), 0, 2)
		self.bridge_idle, self.is_idle = false, true
	end
	function cls:net_destroy() self.idle_snd:stop() end
	function cls:load() self.bridge_idle, self.is_idle = true, false end
	return cls
end
local bridge = binder("bind_red_forest_bridge", "bridge_binder", "bridge", false)
local door = binder("bind_door_labx8", "door_binder_labx8", "door", true)
for _, name in ipairs({ "actor_on_net_destroy", "monster_on_net_spawn", "monster_on_net_destroy" }) do AddScriptCallback(name) end
local adapter = coop_mods_core.mod("coop_world_fx_mods")
if adapter then adapter.on_game_start() end
immersive_skinning.on_game_start()

local function tick(ms)
	NOW = NOW + ms
	SendScriptCallback("actor_on_update")
end

local function packets(peer, source)
	local out = {}
	for _, event in ipairs(source or SENT) do
		if event.name:match("^mods%.fxm_") and (event.target == peer or event.target == -1) then out[#out + 1] = event end
	end
	return out
end

local function receive(events, map_name, from, fresh)
	local old, old_mode = map, MODE
	map, mirror, MODE = map_name, true, "client"
	if fresh then SendScriptCallback("actor_on_net_destroy") end
	for _, event in ipairs(events) do deliver(event, from or 0) end
	tick(0)
	map, mirror, MODE = old, false, old_mode
end

local function mechanism(cls, id)
	local obj = object(id, "mechanism")
	objects[id] = obj
	local b = setmetatable({ object = obj, start_delay = 0, idle_delay = 5000 }, { __index = cls })
	b:__init()
	b:net_spawn()
	return b
end

local function loot(id, close)
	ui_mutant_loot.UIMutantLoot.Loot({ id = id, loot = { mutant_part_dog_tail = { count = 1 } } }, close)
end

if mode == "hostplay" or mode == "srv_map" then
	-- m15:6
	local result = nta_utils.spawn_pulse(vec3(7, 6, 5))
	local pulse = packets(1)
	receive(pulse, forest)
	receive({}, forest, 0)
	NOW = NOW + 5500
	receive({}, forest)
	local light = lights[#lights]
	check(result == "stock pulse" and #pulse == 1 and #packets(4) == 1 and light and light.pos.x == 7 and light.enabled,
		"m15:6 NTA emits light at both ready viewers and preserves the original call")
	local before = #lights
	receive(pulse, "labx8")
	check(#lights == before and (mode == "hostplay" or #packets(2) == 0), "m15:6 pulse is confined to its map")
	late, SENT = true, {}
	tick(500)
	local late_pulse = packets(3)
	receive(late_pulse, forest, 0, true)
	light = lights[#lights]
	check(#late_pulse == 1 and light and light.enabled, "m15:6 a late viewer resumes the current light phase")
	late = false
	NOW = NOW + 5500
	receive({}, forest)
	check(light and light.lanim_brightness == 0.2, "m15:6 light advances to the flash phase")
	NOW = NOW + 500
	receive({}, forest)
	check(light and light.enabled == false, "m15:6 light switches off at the end")
end

if mode == "hostplay" or mode == "srv_map" then
	-- m31:9. The looter reports what the UI removed before the stock close releases the lock.
	SENT = {}
	local corpse = object(701, "monster")
	objects[701] = corpse
	coop_core_world_mloot.locks[701] = { peer = 1 }
	local old_mode = MODE
	mirror, MODE, SELF = true, "client", 1
	loot(701, true)
	mirror, MODE, SELF = false, old_mode, 0
	local req, close = SENT[1], SENT[2]
	check(req and req.name:match("^mods%.fxm_") and close and close.name == "core.mloot_close"
		and corpse.tail == nil, "m31:9 mirror requests counts before close and makes no random bone choice")
	local function request(event, payload, from)
		if mode == "srv_map" then payload._peer = from end
		coop_main.on_event(event.name, coop_main.encode(payload), mode == "srv_map" and 0 or from)
	end
	if req and req.name:match("^mods%.fxm_") then
		local payload = coop_main.decode(req.payload)
		request(req, payload, 2)
		local auth = coop_trust.status().fxm_skin_take
		check(auth and auth.failed == 1 and corpse.tail == nil, "m31:9 a request from outside the corpse lock is checked and has no effect")
		request(req, { i = 701, q = payload.q - 1, ["p:mutant_part_dog_tail"] = 1000 }, 1)
		local bounded = coop_trust.status().fxm_skin_take_counts
		check(bounded and bounded.failed == 1 and corpse.tail == nil, "m31:9 out-of-bounds counts are checked and discarded")
		request(req, payload, 1)
		local made = #packets(4)
		request(req, payload, 1)
		check(made > 0 and #packets(4) == made, "m31:9 a repeated operation cannot apply a second cut")
	end
	check(corpse.tail == false and corpse.tail_end == false, "m31:9 decider chooses the grouped bones from the confirmed corpse lock")
	local bone_packets = packets(4)
	objects[701] = nil
	receive(bone_packets, forest)
	local replica = object(701, "monster")
	objects[701] = replica
	receive({}, forest)
	check(replica.tail == false and replica.tail_end == false, "m31:9 observer applies the chosen bones when its carcass appears")
	late = true
	tick(500)
	check(#packets(3) > 0, "m31:9 late viewer gets the carcass state")
	SENT = {}
	SendScriptCallback("monster_on_net_destroy", corpse)
	local respawned = object(701, "monster")
	objects[701] = respawned
	SendScriptCallback("monster_on_net_spawn", respawned)
	check(respawned.tail == false and #packets(4) == 1, "m31:9 the authority rehydrates the saved cut on carcass respawn")

	-- s34:4
	late, SENT, sounds = false, {}, {}
	local b = mechanism(bridge, 801)
	b:anim_forward()
	local live = packets(1)
	receive(live, forest)
	local live_start = #sounds == 3 and sounds[3].path == "bridge_start"
	NOW = NOW + 5500
	receive({}, forest)
	check(live_start and #sounds == 4 and sounds[4].path == "bridge_hum", "s34:4 bridge starts and loops on an existing observer")
	late, SENT, sounds = true, {}, {}
	tick(600)
	receive(packets(3), forest, 0, true)
	check(#sounds == 1 and sounds[1].path == "bridge_hum", "s34:4 late viewer restores only the continuing hum")
	SENT = {}
	b:animation_end_callback(true)
	receive(packets(1), forest)
	check(sounds[1] and sounds[1].sound.stopped and sounds[#sounds].path == "bridge_down", "s34:4 bridge end stops the loop and plays its down cue")
	SENT, sounds = {}, {}
	local d = mechanism(door, 802)
	d:anim_backward()
	receive(packets(1), forest)
	SENT = {}
	d:animation_end_callback(false)
	check(#packets(1) == 0, "s34:4 door ignores a non-completing animation notification")
	d:anim_stop()
	receive(packets(1), forest)
	check(#sounds == 5 and sounds[#sounds].path == "door_stop", "s34:4 Lab X8 door relays its configured start and stop")
	SENT, sounds = {}, {}
	b:load()
	tick(500)
	receive(packets(1), forest, 0, true)
	check(#sounds == 1 and sounds[1].path == "bridge_hum", "s34:4 loading a moving bridge restores only its hum")
end

if mode == "srv_world" then
	SENT = {}
	local result = nta_utils.spawn_pulse(vec3(7, 6, 5))
	local pulse = packets(1)
	NOW = NOW + 5500
	receive(pulse, forest)
	NOW = NOW + 5500
	receive({}, forest)
	check(result == "stock pulse" and #pulse == 1 and #packets(2) == 0 and #lights == 1 and lights[1].enabled,
		"m15:6 a world quest pulse reaches the map viewers without drawing on the ghost")
end

if mode == "hostplay" or mode == "srv_world" then
	-- m26:4
	map, late, SENT, casts = hospital, false, {}, {}
	local task = {}
	info.kat_greh_sabaoth_psi = true
	task_status_functor.special_steps_for_lostzone_tasks(task, "lttz_ms_hospital_assault")
	local first = packets(1)
	local before = pp
	check(mode == "hostplay" and before == 1 or mode == "srv_world" and before == 0,
		"m26:4 only an authority with a playing actor presents a local effect")
	receive(first, "labx8")
	check(pp == before, "m26:4 story postprocess is scoped to the Hospital")
	receive(first, hospital)
	check(task.stage == 3 and pp == before + 1 and casts[1] and casts[1].name == "world.cfx"
		and casts[1].data.k == "cam", "m26:4 psi start sends postprocess and uses the world camera relay")
	local other_cam = false
	for _, cast in ipairs(casts) do if cast.peer == 2 then other_cam = true end end
	check(mode == "hostplay" or not other_cam, "m26:4 world server targets the Hospital peers")
	SENT = {}
	tick(500)
	task_status_functor.special_steps_for_lostzone_tasks(task, "lttz_ms_hospital_assault")
	before = pp
	receive(packets(1), hospital)
	check(task.stage == 4 and pp == before + 1, "m26:4 recurring stage re-enables the postprocess")
	late, SENT, casts = true, {}, {}
	tick(500)
	check(#packets(3) > 0 and #casts == 0, "m26:4 late join restores postprocess without replaying camera")
	SENT = {}
	local removed = pp_removed
	info.kat_greh_sabaoth_psi_end = true
	task_status_functor.special_steps_for_lostzone_tasks(task, "lttz_ms_hospital_assault")
	receive(packets(1), hospital)
	check(task.stage == 5 and pp_removed > removed and casts[1] and casts[1].data.k == "uncam",
		"m26:4 finish removes both effectors")
elseif mode == "none" then
	local corpse = object(701, "monster")
	objects[701] = corpse
	loot(701, false)
	local b = mechanism(bridge, 801)
	b:anim_forward()
	local r = nta_utils.spawn_pulse(vec3(7, 6, 5))
	info.kat_greh_sabaoth_psi = true
	task_status_functor.special_steps_for_lostzone_tasks({}, "lttz_ms_hospital_assault")
	check(#SENT == 0 and #casts == 0, "single player never emits a relay")
	check(r == "stock pulse" and #lights == 1 and #sounds == 2 and pp == 1 and corpse.tail == false,
		"single player uses all four original effect paths unchanged")
end

done("world_fx_mods " .. mode)
