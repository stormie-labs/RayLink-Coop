-- World parity W4, sound M4, tasks X2 (coop_world_fx.script): what scripts on the host draw and play reaches the clients.
-- Run: tools\test_lua.cmd world_fx
dofile("tests/lua/support/harness_world.lua")
local modes = dofile("tests/lua/support/modes.lua")

-- A script of the machine, loaded the way CScriptStorage does (module table with __index to the globals).
local function fixture(M, name, src)
	local header = "local this = {} " .. name .. " = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. src, "@" .. name .. ".script"))
	setfenv(f, M.env)
	f()
	return M.env[name]
end

local PartMT = {}
PartMT.__index = PartMT
function PartMT:set_direction(d) self.dir = d end
function PartMT:play_at_pos(p) self.m.parts[#self.m.parts + 1] = { name = self.name, x = p.x, y = p.y, z = p.z, dir = self.dir } end
function PartMT:playing() return false end
function PartMT:stop() self.stopped = true end

local SndMT = {}
SndMT.__index = SndMT
function SndMT:play(obj, delay, flags) self.m.snds[#self.m.snds + 1] = { path = self.path, obj = obj, flat = flags == 1 } end
function SndMT:play_at_pos(obj, pos, delay, flags) self.m.snds[#self.m.snds + 1] = { path = self.path, obj = obj, pos = pos, flags = flags } end
function SndMT:play_no_feedback(obj, flags, delay, pos, vol, freq) self.m.snds[#self.m.snds + 1] = { path = self.path, obj = obj, flags = flags, nofb = true } end
function SndMT:playing() return false end

local function engine_fx(M)
	local E = M.env
	M.parts, M.snds, M.news = {}, {}, {}
	E.vector = vector
	E.particles_object = function(name) return setmetatable({ name = name, m = M }, PartMT) end
	local cls = setmetatable({ s2d = 1, s3d = 2, looped = 4 }, {
		__call = function(_, path) return setmetatable({ path = path, m = M }, SndMT) end,
	})
	E.sound_object = cls
	E.xr_sound = {
		cached = true,
		get_safe_sound_object = function(path) return setmetatable({ path = path, m = M }, SndMT) end,
	}
	E.wallmarks_manager = function()
		return { place = function(_, dir, pos, range, size, tex, obj, ttl)
			M.marks = M.marks or {}
			M.marks[#M.marks + 1] = { tex = tex, x = pos.x, dy = dir.y, size = size, obj = obj:id(), ttl = ttl }
		end }
	end
	E.level.add_pp_effector = function(n, id, loop) M.ppe = { n, id, loop } end
	E.level.remove_pp_effector = function(id) M.ppe_removed = id end
	E.level.vertex_id = function() return 77 end
	E.dynamic_news_helper = { send_tip = function(m) M.news[#M.news + 1] = m return true end }
	E.news_manager = { send_tip = function(a, id) M.news[#M.news + 1] = id return true end, other = "kept" }
	E.coop_core_world_news = { in_world_scope = function(f, ...)
		M.world_scope = (M.world_scope or 0) + 1
		return f(...)
	end }
	E.coop_mods_core = { mod = function(n) return E[n] end }
end

local function tick(H, C)
	NOW = NOW + 600
	H.fire("actor_on_update")
	if C then C.fire("actor_on_update") end
	world_pump()
end

local function stage()
	local H, C = world_pair()
	for _, M in ipairs({ H, C }) do
		if not M.env.coop_mode then
			modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
		end
		if not M.env.coop_trust then load_script(M, "coop_trust") end
	end
	engine_fx(H)
	engine_fx(C)
	local grok = [[
function hit(pos, dir)
	local fx = particles_object("hit_fx\\hit_metal_01")
	fx:set_direction(dir)
	fx:play_at_pos(pos)
	return fx
end]]
	local task = [[
function blast(pos, npc)
	local s = sound_object("new_tasks_addon\\boom")
	s:play_at_pos(db.actor, pos)
	s.volume = 0.4
	sound_object("new_tasks_addon\\scream"):play(db.actor, 0, sound_object.s2d)
	sound_object("new_tasks_addon\\own"):play_at_pos(npc, pos)
	sound_object("new_tasks_addon\\hum"):play_at_pos(db.actor, pos, 0, sound_object.s3d + sound_object.looped)
end
function safe(pos) xr_sound.get_safe_sound_object("anomaly\\rumble"):play_at_pos(db.actor, pos) end
function shake() level.add_cam_effector("camera_effects\\earthquake.anm", 3, true, "cb") end
function calm() level.remove_cam_effector(3) end
function fade() level.add_pp_effector("fade_in.ppe", 200, false) end
function vertex() return level.vertex_id() end
function tip() return dynamic_news_helper.send_tip("msg_1") end
function tip2() return news_manager.send_tip(db.actor, "id_1") end
function other() return news_manager.other end
function later() return function() return dynamic_news_helper.send_tip("msg_late") end end]]
	for _, M in ipairs({ H, C }) do
		fixture(M, "grok_bo", grok)
		fixture(M, "tasks_dead_night", task)
		fixture(M, "arszi_mutant_bleeding", [[
function drop(pos, monster) wallmarks_manager():place(vector():set(0, -1, 0), pos, 1, 0.2, "bloody_marks", monster, 30) end]])
		fixture(M, "nta_utils", [[
function teleport_visual()
	level.add_pp_effector("teleport.ppe", 2006, false)
	sound_object("affects\\tinnitus3a"):play_no_feedback(db.actor, sound_object.s2d, 0, vector(), 1.0, 1.0)
end]])
		fixture(M, "tasks_the_living_fire", [[
function earthquake_effect() level.add_cam_effector("camera_effects\\earthquake.anm", 3, true, "") end]])
		fixture(M, "tasks_mirage", [[
local anomaly_particles = particles_object("anomaly2\\bold_idle")
local anomaly_sound = xr_sound.get_safe_sound_object("anomaly\\gravi_rumble1")
function actor_on_update(pos)
	anomaly_particles:play_at_pos(pos)
	anomaly_sound:play_at_pos(db.actor, pos)
end]])
	end
	local cls = {}
	function cls:explode(se_obj, squad) self.m.exploded = se_obj end
	cls.m = H
	H.env.surge_manager = { CSurgeManager = cls }
	local FH, FC = load_script(H, "coop_world_fx"), load_script(C, "coop_world_fx")
	FH.on_game_start()
	FC.on_game_start()
	H.env.coop_npc_players.host_on = function() return true end
	return H, C, FH, FC
end

print("== particles")
do
	local H, C, FH = stage()
	local g = H.env.grok_bo
	g.hit(vec(1, 2, 3), vec(0, 1, 0))
	check(#H.parts == 1 and H.parts[1].dir ~= nil, "the host plays the mod's particle with its direction, as in stock")
	world_pump()
	check(#C.parts == 1 and C.parts[1].name == "hit_fx\\hit_metal_01" and C.parts[1].x == 1, "the client plays it at the same point")
	check(C.parts[1].dir and C.parts[1].dir.y == 1, "with the same direction")
	check(g.hit(vec(0, 0, 0), vec(0, 1, 0)).stopped == nil and g.hit(vec(0, 0, 0), vec(0, 1, 0)).playing() == false, "the stand-in answers like the object")

	world_pump()
	C.parts = {}
	g.hit(vec(900, 0, 0), vec(0, 1, 0))
	world_pump()
	check(#C.parts == 0, "too far from the client's character: not sent to it")

	-- a firefight: a burst passes, the flood does not
	H.parts, C.parts = {}, {}
	for i = 1, 200 do g.hit(vec(1, 0, 0), vec(0, 1, 0)) end
	world_pump()
	check(#H.parts == 200, "the host's own particles are never limited")
	check(#C.parts >= 20 and #C.parts <= 40, "the relay stays inside its limit (" .. #C.parts .. ")")
	NOW = NOW + 3000
	C.parts = {}
	g.hit(vec(1, 0, 0), vec(0, 1, 0))
	world_pump()
	check(#C.parts == 1, "the limit fills again with time")
end

print("== wallmarks")
do
	local H, C = stage()
	local m = H.add(make_obj(600, 1, 0, 0))
	C.add(make_obj(600, 1, 0, 0))
	H.env.arszi_mutant_bleeding.drop(vec(1, 0, 0), m)
	world_pump()
	check(H.marks and #H.marks == 1, "the host draws the drop")
	check(C.marks and C.marks[1].tex == "bloody_marks" and C.marks[1].obj == 600 and C.marks[1].ttl == 30 and C.marks[1].dy == -1, "and the client, on its copy of the mutant")
end

print("== sounds")
do
	local H, C = stage()
	local t = H.env.tasks_dead_night
	local npc = H.add(make_obj(700, 0, 0, 0))
	t.blast(vec(5, 0, 0), npc)
	check(#H.snds == 4, "every sound plays on the host")
	tick(H, C)
	local boom, scream = nil, nil
	for _, s in ipairs(C.snds) do
		if s.path:find("boom", 1, true) then boom = s end
		if s.path:find("scream", 1, true) then scream = s end
	end
	check(boom and boom.pos and boom.pos.x == 5, "a positional sound of the actor plays at that point on the client")
	check(scream and scream.flat, "a 2D sound of the actor stays 2D")
	check(#C.snds == 2, "a creature's own sound (the engine relays it) and a looped one stay out")

	C.snds = {}
	t.safe(vec(1, 0, 0))
	tick(H, C)
	check(#C.snds == 1 and C.snds[1].path == "anomaly\\rumble", "xr_sound.get_safe_sound_object of the script is relayed as well")

	-- the volume a script writes after play
	C.snds = {}
	local real_set = C.env.xr_sound.get_safe_sound_object
	local got = {}
	C.env.xr_sound.get_safe_sound_object = function(path)
		local o = real_set(path)
		got[path] = o
		return o
	end
	t.blast(vec(5, 0, 0), npc)
	tick(H, C)
	check(got["new_tasks_addon\\boom"] and got["new_tasks_addon\\boom"].volume == 0.4, "the volume written after play reaches the client")
end

print("== effectors and news")
do
	local H, C = stage()
	local t = H.env.tasks_dead_night
	t.shake()
	check(H.cam and H.cam[4] == "cb", "the host's effector runs with its callback")
	world_pump()
	check(C.cam and C.cam[1] == "camera_effects\\earthquake.anm" and C.cam[2] == 3 and C.cam[3] == true and C.cam[4] == "", "the client gets it without the callback")
	t.calm()
	world_pump()
	check(C.cam_removed == 3, "and its end")
	t.fade()
	world_pump()
	check(C.ppe and C.ppe[1] == "fade_in.ppe" and C.ppe[2] == 200, "a postprocess effector too")
	check(t.vertex() == 77, "the rest of level answers as before")
	t.tip()
	t.tip2()
	check(H.news[1] == "msg_1" and H.news[2] == "id_1", "tips show on the host")
	check(H.world_scope == 2, "and run in a world scope: core.news takes them to the clients")
	check(t.other() == "kept", "the rest of news_manager answers as before")
	t.later()()
	check(H.world_scope == 3, "a closure of the script (a delayed message) is covered as well")
end

print("== mute")
do
	local H, C = stage()
	H.env.nta_utils.teleport_visual()
	check(H.ppe and H.ppe[1] == "teleport.ppe", "teleport_visual runs on the host")
	tick(H, C)
	check(C.ppe == nil and #C.snds == 0, "and is not everybody's: it is the screen of the player who moves")
	H.env.tasks_the_living_fire.earthquake_effect()
	world_pump()
	check(H.cam ~= nil and C.cam == nil, "the Living Fire earthquake stays with coop_mods_nta's relay")
end

print("== mirage, emission")
do
	local H, C = stage()
	H.env.tasks_mirage.actor_on_update(vec(2, 0, 0))
	tick(H, C)
	check(#H.parts == 1 and #C.parts == 1 and C.parts[1].name == "anomaly2\\bold_idle", "the particle made at load is relayed")
	check(#C.snds == 1 and C.snds[1].path == "anomaly\\gravi_rumble1", "the sound made at load is relayed")

	local sm = H.env.surge_manager.CSurgeManager
	sm:explode({ position = vec(3, 0, 0) }, {})
	world_pump()
	check(H.exploded ~= nil, "explode runs on the host")
	check(#C.parts == 2 and C.parts[2].name:find("body_tear", 1, true), "the body tear is seen on the client")
	check(#C.snds == 2 and C.snds[2].path == "anomaly\\anomaly_body_tear_1", "and heard")
	sm:explode({ position = vec(3, 0, 0) }, nil)
	world_pump()
	check(#C.parts == 2, "no squad: a plain kill, nothing to show")
end

print("== emission flares: the smoke trail")
do
	local H, C = world_pair()
	for _, M in ipairs({ H, C }) do
		if not M.env.coop_mode then
			modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
		end
		if not M.env.coop_trust then load_script(M, "coop_trust") end
	end
	engine_fx(H)
	engine_fx(C)
	local flare = [[
signal_light_binder = {}
function signal_light_binder:launch() if self.flying then return false end self.flying = true return true end
function signal_light_binder:slow_fly() end
function signal_light_binder:stop_light() end
]]
	fixture(H, "bind_signal_light", flare)
	fixture(C, "bind_signal_light", flare)
	H.env.surge_manager, C.env.surge_manager = {}, {}
	local FH, FC = load_script(H, "coop_world_fx"), load_script(C, "coop_world_fx")
	FH.on_game_start()
	FC.on_game_start()
	H.env.coop_npc_players.host_on = function() return true end
	local trail = {}
	local copy = make_obj(900, 0, 50, 0)
	function copy:start_particles(name, bone) trail[#trail + 1] = "on " .. name .. " " .. bone end
	function copy:stop_particles(name, bone) trail[#trail + 1] = "off " .. name .. " " .. bone end
	C.add(copy)
	local cls = H.env.bind_signal_light.signal_light_binder
	local binder = setmetatable({ object = make_obj(900, 0, 50, 0) }, { __index = cls })
	check(binder:launch() == true, "the stock launch answers")
	world_pump()
	check(trail[1] == "on weapons\\light_signal link", "a client's copy of the flare smokes")
	check(binder:launch() == false, "a second launch of a flying flare")
	world_pump()
	check(#trail == 1, "...sends nothing")
	binder:slow_fly()
	world_pump()
	check(#trail == 2, "the second start of the trail, as in stock")
	binder:stop_light()
	binder:stop_light() -- the stock binder calls it every frame for 8 s
	world_pump()
	check(trail[3] == "off weapons\\light_signal link" and #trail == 3, "it goes out once")
	binder:slow_fly()
	world_pump()
	check(#trail == 3, "a flare that was never launched here sends nothing")
end

print("== alone, single player, client")
do
	local H, C, FH = stage()
	H.env.coop_npc_players.host_on = function() return false end
	H.env.grok_bo.hit(vec(1, 0, 0), vec(0, 1, 0))
	H.env.tasks_dead_night.tip()
	world_pump()
	check(#H.parts == 1 and H.casts == nil and H.world_scope == nil, "a host alone: stock calls, nothing sent")
	C.env.grok_bo.hit(vec(1, 0, 0), vec(0, 1, 0))
	C.env.tasks_dead_night.shake()
	check(#C.parts == 1 and C.casts == nil, "on a client the stand-ins are stock calls")
end

local MK = 0x101
local LEVEL_MK = 2

-- The map server as the engine has it: l_set refuses the session, l_broadcast takes the players of its level.
local function map_server()
	local K = machine("client", MK, { [MK] = 0, [1] = 500 })
	local E = K.env
	E.coop.is_map_server = function() return true end
	E.coop.is_mirror = function() return false end
	K.refused, K.casts = 0, {}
	E.coop.sync = {
		set = function()
			K.refused = K.refused + 1
			return false, "not allowed"
		end,
		get = function() return nil end,
		on = function() return true end,
		broadcast = function(name, args, opts)
			if K.cast_refusal then return false, K.cast_refusal end
			for _, v in pairs(args) do
				if type(v) == "table" then return false, "bad value" end -- to_value: no table in a table
			end
			K.casts[#K.casts + 1] = { name = name, args = args, opts = opts }
			return true, 1
		end,
	}
	if not K.env.coop_mode then
		modes.live(load_script(K, "coop_mode"), function(name) return load_script(K, name) end)
	end
	if not K.env.coop_trust then load_script(K, "coop_trust") end
	load_script(K, "coop_npc_players")
	return K
end

-- What Mk casts comes out on the client with from = 0, its events too: the world relays them, the player knows no other process.
local function deliver(K, C)
	local list = K.casts
	K.casts = {}
	for _, c in ipairs(list) do
		local fn = C.effects[c.name]
		if fn and (c.opts == nil or c.opts.to == nil or c.opts.to == C.peer) then fn(c.args, 0) end
	end
	for _, q in ipairs(QUEUE) do
		if q.from == MK then q.from = 0 end
	end
	pump()
	world_pump()
end

local function fired(M) M.fire("actor_on_update") end

print("== who fights a player on a map server's level")
do
	local function stage()
		local H, C = world_pair()
		for _, M in ipairs({ H, C }) do
			if not M.env.coop_mode then
				modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
			end
			if not M.env.coop_trust then load_script(M, "coop_trust") end
		end
		H.env.coop.is_dedicated = function() return true end
		H.env.coop.players = function() return { { id = 1, avatar_id = 500, level = LEVEL_MK } } end
		C.env.coop.players = function() return { { id = 1, avatar_id = 0, is_self = true, level = LEVEL_MK } } end
		C.env.coop.server_link = function() return { id = 0, plays = false } end
		C.env.coop.levels = { split = function() return true end }
		local K = map_server()
		for _, M in ipairs({ H, C, K }) do
			M.env.vector = vector
			M.env.xr_combat_ignore = { fighting_with_actor_npcs = {} }
		end
		local fighting = {}
		K.env.coop_npc_combat = { _state = function() return { fighting = fighting } end }
		K.add(make_obj(500, 0, 0, 0))
		for _, id in ipairs({ 700, 701 }) do
			K.add(make_obj(id, 10, 0, 0))
			C.add(make_obj(id, 10, 0, 0))
		end
		load_script(K, "coop_world_fight").on_game_start()
		local FC = load_script(C, "coop_world_fight")
		FC.on_game_start()
		K.env.coop_npc_players.invalidate()
		return H, C, K, fighting, FC
	end
	local function tick(K, C)
		NOW = NOW + 1100
		K.env.coop_npc_players.invalidate()
		fired(K)
		deliver(K, C)
		fired(C)
	end

	local H, C, K, fighting = stage()
	local ct = C.env.xr_combat_ignore.fighting_with_actor_npcs
	fighting[700] = { [500] = true }
	tick(K, C)
	check(ct[700] == true, "the NPC that fights him is in his table: the combat music starts")
	check(K.refused == 0, "the map server writes nothing the engine refuses")
	fighting[700], fighting[701] = nil, { [500] = true }
	tick(K, C)
	check(ct[700] == nil and ct[701] == true, "the table follows the map server's list")
	fighting[701] = nil
	tick(K, C)
	check(ct[701] == nil, "the fight is over: the table is empty")

	-- the world server's key of this player is from the level he left
	H.env.coop.sync.set("session", "world.fight.1", { 700 })
	tick(K, C)
	check(ct[700] == nil, "a key left on the world server by the level he came from is not read here")

	-- he left the level and came back with a new Lua state: he is told again
	fighting[700] = { [500] = true }
	tick(K, C)
	local player = K.objects[500]
	K.objects[500] = nil
	tick(K, C)
	K.objects[500] = player
	C.env.xr_combat_ignore.fighting_with_actor_npcs = {}
	local FC2 = load_script(C, "coop_world_fight")
	FC2.on_game_start()
	tick(K, C)
	check(C.env.xr_combat_ignore.fighting_with_actor_npcs[700] == true, "a player who came back hears the fight that goes on")

	-- a refusal is said, not swallowed
	K.cast_refusal = "too many"
	fighting[701] = { [500] = true }
	tick(K, C)
	local said = false
	for _, line in ipairs(K.log) do
		if line:find("too many", 1, true) then said = true end
	end
	check(said, "a list the engine refused is in the log")
	K.cast_refusal = nil

	-- A co-op player still reads the session key.
	local H2, C2 = world_pair()
	for _, M in ipairs({ H2, C2 }) do
		if not M.env.coop_mode then
			modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
		end
		if not M.env.coop_trust then load_script(M, "coop_trust") end
	end
	C2.env.vector = vector
	C2.env.xr_combat_ignore = { fighting_with_actor_npcs = {} }
	C2.add(make_obj(700, 10, 0, 0))
	load_script(C2, "coop_world_fight").on_game_start()
	H2.env.coop.sync.set("session", "world.fight.1", { 700 })
	NOW = NOW + 1100
	fired(C2)
	check(C2.env.xr_combat_ignore.fighting_with_actor_npcs[700] == true, "co-op reads the playing host's fight list")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
