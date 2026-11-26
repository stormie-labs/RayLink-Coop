-- Dev 57 G15-5. Stock scheme entry points over the real Core, routing, trust and punch scripts.
local modes = dofile("tests/lua/support/modes.lua")
dofile("tests/lua/support/harness_npc.lua")

local CUT, IDLE = "sr_cutscene@story", "sr_idle@wait"
local zone_id, npc_id, client_body, other_body = 120, 200, 501, 502
local bridge = 0x101

local function setup(M, set)
	local E = M.env
	E.modules = { stype_restrictor = 4 }
	E.IsStalker = function(obj) return obj._stalker == true end
	E.key_bindings = { kUSE = 11 }
	E.dik_to_bind = function(key) return key end
	E.game.hud_motion_allowed = function() return true end
	E.game.only_movekeys_allowed = function() return false end
	E.level.get_target_obj = function() return M.target end
	E.level.get_target_dist = function() return 1 end
	E.level.remove_cam_effector = function() M.camera_removed = true end
	E.game_object = { friend = 1 }
	E.game_relations = { get_npcs_relation = function(_, actor) return actor._enemy and 2 or 1 end }
	E.xr_effects = {
		actor_punch = function(actor) M.punched = actor:id() end,
		teleport_actor = function() M.teleports = (M.teleports or 0) + 1 end,
		disable_ui = function() M.locked = true end,
		enable_ui = function() M.locked = false end,
		stop_sr_cutscene = function(_, z) E.db.storage[z:id()].sr_cutscene.signals.cam_effector_stop = true end,
	}
	local cut = {}
	function cut:zone_enter()
		self.state, self.motion, self.ui_disabled = "run", {}, true
		E.xr_effects.teleport_actor(E.db.actor, self.object)
		E.xr_effects.disable_ui(E.db.actor)
	end
	function cut:reset_scheme()
		self.st.signals, self.motion = {}, nil
		self:zone_enter()
	end
	function cut:cutscene_callback()
		self.motion, self.ui_disabled = nil, false
		self.st.signals.cameff_end = true
		E.xr_effects.enable_ui(E.db.actor)
	end
	function cut:update()
		if self.motion and self.st.signals.cam_effector_stop then self:cutscene_callback() end
		E.xr_logic.try_switch_to_another_section(self.object, self.st, E.db.actor)
	end
	E.sr_cutscene = { action_cutscene = cut }
	local logic = {}
	E.xr_logic = logic
	function logic.activate_by_section(obj, _, section)
		local root = E.db.storage[obj:id()]
		root.active_section = section
		if section == CUT then
			root.active_scheme = "sr_cutscene"
			local action = root.sr_cutscene.cutscene_action
			action:reset_scheme()
		else
			root.active_scheme = nil
		end
	end
	function logic.switch_to_section(obj, ini, section)
		if not section or E.db.storage[obj:id()].active_section == section then return false end
		logic.activate_by_section(obj, ini, section)
		return true
	end
	function logic.pick_section_from_condlist(actor, obj, condlist)
		if type(condlist) ~= "table" then return condlist end
		for _, line in ipairs(condlist) do
			for _, f in ipairs(line[3] or {}) do E.xr_effects[f](actor, obj) end
			return line[1]
		end
	end
	function logic.try_switch_to_another_section(obj, state, actor)
		if state.signals and state.signals.cameff_end then M.advanced = (M.advanced or 0) + 1 end
		for _, c in ipairs(state.logic or {}) do
			if c.name == "on_actor_inside" or c.name == "on_actor_dist_le_nvis" then
				local hit = c.name == "on_actor_inside" and obj:inside(actor:position())
				if c.name == "on_actor_dist_le_nvis" then hit = actor:position():distance_to_sqr(obj:position()) <= c.v1^2 end
				if hit then return logic.switch_to_section(obj, state.ini, logic.pick_section_from_condlist(actor, obj, c.condlist)) end
			end
		end
		return false
	end
	function logic.determine_section_to_activate() return IDLE end
	function logic.initialize_obj(obj, root, loaded, actor, stype)
		root.stype, root.ini = stype, obj._ini
		local section = loaded and root.loaded_active_section or logic.determine_section_to_activate(obj, root.ini, "logic", actor)
		logic.activate_by_section(obj, root.ini, section)
	end
	function logic.save_obj() end
	E.state_mgr = { set_state = function(_, _, _, _, target) M.punch_look = target.look_object:id() end }
	M.punch_action = { f = E.xr_effects.actor_punch }
	E.state_mgr_animation_list = { animations = { punch = { into = { M.punch_action } } } }
	local hit = {}
	function hit:initialize()
		E.state_mgr.set_state(self.object, "punch", nil, nil, { look_object = E.db.actor })
	end
	E.xr_abuse = {
		action_abuse_hit = hit,
		add_abuse = function(obj, value)
			local manager = E.db.storage[obj:id()].abuse.abuse_manager
			if manager.enable then manager.abuse_value = manager.abuse_value + value * 2 end
		end,
	}
	E.xr_meet = { notify_on_use = function(obj)
		local s = E.db.storage[obj:id()].meet.meet_manager
		if s.use == "false" and s.abuse_mode == "true" and E.game_relations.get_npcs_relation(obj, E.db.actor) == 1 then
			E.xr_abuse.add_abuse(obj, 1)
		end
	end }
	local remark = {}
	E.xr_remark = {
		action_remark_activity = remark,
		init_target = function(_, target)
			if target == "story|actor" then return nil, E.db.actor:id(), true end
			return nil, 900, true
		end,
	}
	function remark:get_target()
		local pos, id, init = E.xr_remark.init_target(self.object, self.st.target)
		if init then return { look_object = E.level.object_by_id(id), look_position = pos } end
	end
	E.coop_npc_players = load_script(M, "coop_npc_players")
	E.coop_mode = load_script(M, "coop_mode")
	if set ~= "none" then
		local answers = setfenv(assert(loadfile("tests/lua/support/mode_" .. (set == "mirror" and "hostplay" or set) .. ".lua")), E)()
		if set == "mirror" then
			answers.leads_here = function() return false end
			answers.is_player_mirror = function() return true end
			answers.decider = function() return "other" end
		elseif set == "srv_map" then
			answers.where = function(peer) return (peer == 1 or M.second_here and peer == 2) and "here" or "away" end
			answers.decider = function(peer) return answers.where(peer) == "here" and "this" or "other" end
		end
		assert(E.coop_mode.install(answers))
	end
	E.coop_mods_core = load_script(M, "coop_mods_core")
	E.coop_trust = load_script(M, "coop_trust")
	E.coop_trust.reset_for_test({ default = "refuse" })
	E.coop_quests_punch = load_script(M, "coop_quests_punch")
	E.coop_quests_punch.on_game_start()
	E.coop_npc_logic = load_script(M, "coop_npc_logic")
	E.coop_npc_logic.on_game_start()
	M.fire("actor_on_first_update")
	if set == "hostplay" or set == "srv_map" then E.coop_npc_players.host_on = function() return true end end
end

local function zone(M)
	local E = M.env
	local z = M.add(make_obj(zone_id, 20, 0, 0, { _radius = 2, _name = "story_zone",
		_ini = make_ini({ logic = { { "active", IDLE } },
			[IDLE] = { { "on_actor_inside", CUT .. " %+story_started =disable_ui%" } }, [CUT] = {} }) }))
	local cut = { logic = {}, signals = {}, enable_ui_on_end = true }
	local a = setmetatable({ object = z, st = cut }, { __index = E.sr_cutscene.action_cutscene })
	cut.cutscene_action = a
	local st = { object = z, stype = 4, ini = z._ini, active_section = IDLE, sr_cutscene = cut,
		logic = { { name = "on_actor_inside", condlist = { { CUT, {}, { "disable_ui" } } } } } }
	E.db.storage[zone_id], E.db.zone_by_name[z:name()] = st, z
	return z, st, a
end

local function stalker(M)
	local E = M.env
	local obj = M.add(make_obj(npc_id, 19, 0, 0, { _stalker = true }))
	local meet = { use = "false", abuse_mode = "true", a = { use = "false", abuse = "true" } }
	local abuse = { enable = true, abuse_value = 0 }
	local root = { object = obj, meet = { meet_manager = meet }, abuse = { abuse_manager = abuse } }
	E.db.storage[npc_id] = root
	return obj, root, abuse
end

-- Deliver the star's map-server replies with the world server as origin, as on the real wire.
local function dispatch()
	while #QUEUE > 0 do
		local msg = table.remove(QUEUE, 1)
		for peer, M in pairs(MACHINES) do
			if peer ~= msg.from and (peer == msg.target or msg.target == -1 and
				(msg.from ~= bridge or M.on_map == bridge)) then
				local sender = msg.from == bridge and peer ~= 0 and 0 or msg.from
				for _, f in ipairs(M.handlers[msg.name] or {}) do f(msg.payload, sender) end
			end
		end
	end
end

local function run_scene(set, second_map)
	reset_world()
	local server = set == "srv_map"
	local label = not server and set or set .. (second_map and " different maps" or " same map")
	local host = machine("host", server and bridge or 0, { [0] = 0, [1] = client_body, [2] = other_body })
	local world
	if server then
		host.env.coop.is_host = function() return false end
		host.env.coop.is_client = function() return true end
		host.env.coop.is_map_server = function() return true end
		host.env.coop.is_mirror = function() return false end
		world = machine("host", 0, { [1] = client_body, [2] = other_body })
		world.env.coop.is_dedicated = function() return true end
		world.env.coop.levels = { split = function() return true end,
			bridge_of_player = function(p) return p == 2 and second_map and 0x102 or bridge end }
		setup(world, "srv_world")
	end
	local client = machine("client", 1, { [1] = 0 })
	local other = machine("client", 2, { [2] = 0 })
	client.on_map, other.on_map = bridge, second_map and 0x102 or bridge
	host.second_here = not second_map
	if not second_map then host.add(make_obj(other_body, 25, 0, 0)) end
	client.to_host = function(id) return id == 0 and client_body or id end
	client.to_local = function(id) return id == client_body and 0 or id end
	host.env.db.actor._pos, client.env.db.actor._pos = vec(17.5, 0, 0), vec(20, 0, 0)
	local body = host.add(make_obj(client_body, 20, 0, 0))
	setup(host, set)
	setup(client, "mirror")
	setup(other, "mirror")
	local z, root, cut = zone(host)
	local _, _, other_cut = zone(other)
	host.env.xr_logic.try_switch_to_another_section(z, root, host.env.db.actor)
	dispatch()
	local _, client_root, client_cut = zone(client)
	client_root.loaded_active_section = CUT
	client.env.xr_logic.initialize_obj(client_cut.object, client_root, not second_map, client.env.db.actor, 4)
	dispatch()
	check(client.teleports == 1 and client.locked and not host.teleports and not other.teleports and not host.locked and not other.locked,
		label .. " s39:1 broadcast before bind plays only for the entering client")
	local initial = #sent_named(host, "npc.logic")
	client.env.coop.send_event("npc.logic_req", client.env.coop_main.encode({ i = zone_id }), 0)
	client.env.coop.send_event("npc.logic_req", client.env.coop_main.encode({}), 0)
	dispatch()
	local sections = sent_named(host, "npc.logic")
	local first = sections[1] and host.env.coop_main.decode(sections[1].payload) or {}
	local single = sections[initial + 1] and host.env.coop_main.decode(sections[initial + 1].payload) or {}
	local all = sections[initial + 2] and host.env.coop_main.decode(sections[initial + 2].payload) or {}
	check(single.q == first.q and all.q == first.q and first.a == tostring(client_body) and single.a == first.a
		and all.a == first.a and client.teleports == 1 and not other_cut.motion,
		label .. " s39:1 individual and full re-issues carry the roster without restarting")
	other.env.coop.send_event("mods.npc_scene_end", other.env.coop_main.encode({ i = zone_id, q = first.q or 1, peer = 1 }), 0)
	dispatch()
	cut:update()
	check(not host.advanced, label .. " s39:1 camera waits for the invited player")
	client_cut:cutscene_callback()
	client_cut:cutscene_callback()
	dispatch()
	cut:update()
	check(host.advanced == 1 and not client.locked and #sent_named(client, "mods.npc_scene_end") == 1,
		label .. " s39:1 client completion advances the authoritative scheme once")
	_, client_root, client_cut = zone(client)
	client.env.coop.send_event("npc.logic_req", client.env.coop_main.encode({ i = zone_id }), 0)
	dispatch()
	check(client.teleports == 1 and not client.locked,
		label .. " s39:1 an object rebind after completion never replays the camera")
	host.env.xr_logic.switch_to_section(z, z._ini, IDLE)
	host.env.xr_logic.try_switch_to_another_section(z, root, host.env.db.actor)
	dispatch()
	host.env.xr_effects.stop_sr_cutscene(host.env.db.actor, z)
	dispatch()
	client_cut:update()
	dispatch()
	cut:update()
	check(client.teleports == 2 and not client.locked and host.advanced == 2,
		label .. " s39:1 authoritative stop signal reaches the remote camera")

	local n, nr, abuse = stalker(host)
	local puppet = stalker(client)
	local ghost_copy, _, ghost_abuse
	if world then ghost_copy, _, ghost_abuse = stalker(world) end
	client.target = puppet
	for _ = 1, 3 do client.fire("on_key_press", client.env.key_bindings.kUSE) end
	dispatch()
	if abuse.abuse_value >= 5 then
		host.env.xr_abuse.action_abuse_hit.initialize({ object = n })
		host.punch_action.f(n)
		dispatch()
	end
	check(abuse.abuse_value == 6 and host.punch_look == client_body and client.punched == 0 and not host.punched and not other.punched,
		label .. " s42:4 three USE presses irritate the NPC and the animation punches their sender")
	if ghost_copy then check(ghost_abuse.abuse_value == 0, label .. " s42:4 world server performs no NPC action") end
	body._pos = vec(28, 0, 0)
	client.fire("on_key_press", client.env.key_bindings.kUSE)
	dispatch()
	body._pos, body._enemy = vec(20, 0, 0), true
	client.fire("on_key_press", client.env.key_bindings.kUSE)
	dispatch()
	body._enemy, nr.meet.meet_manager.a.abuse, nr.meet.meet_manager.abuse_mode = nil, "false", "false"
	client.fire("on_key_press", client.env.key_bindings.kUSE)
	dispatch()
	-- Stand b57h phantoms_server: a client's USE on a trader is a talk (stock [meet] use = true). The client asks at every
	-- USE of a living NPC stalker in reach: the NPC's [meet] lives on the map that runs it.
	NOW = NOW + 2000 -- the burst of mods.npc_abuse_use (6) went to the presses above
	local mm = nr.meet.meet_manager
	mm.use, mm.a.use, mm.a.abuse, mm.abuse_mode = "true", "true", "true", "true"
	client.fire("on_key_press", client.env.key_bindings.kUSE)
	dispatch()
	mm.use, mm.a.use = "false", "false"
	check(abuse.abuse_value == 6, label .. " s42:4 out-of-reach, hostile, disabled and talk uses do not add irritation")
	local checks = host.env.coop_trust.status()
	local failed = 0
	for name, c in pairs(checks) do
		if name:match("^npc_abuse_") and name ~= "npc_abuse_reach" then failed = failed + c.failed end
	end
	check(checks.npc_abuse_reach and checks.npc_abuse_reach.refused == 1 and failed == 0,
		label .. " s42:4 an honest use its NPC answers no to (hostile, abuse off, a talk) is no failed check")
	-- No honest client names a player's character: ask_abuse sends a living NPC stalker only.
	client.env.coop_mods_core.to_host("npc_abuse_use", { i = client_body })
	dispatch()
	checks = host.env.coop_trust.status()
	check(abuse.abuse_value == 6 and checks.npc_abuse_target and checks.npc_abuse_target.refused == 1,
		label .. " s42:4 the decider records a use of no NPC stalker through coop_trust")
	NOW = NOW + 2000
	local trust = host.env.coop_trust
	trust.reset_for_test({ default = "log" })
	host.env.coop.life_of = function(id) return id == client_body and "wounded" or "alive" end
	local logs = #host.log
	client.env.coop_mods_core.to_host("npc_abuse_use", { i = npc_id })
	dispatch()
	check(abuse.abuse_value == 6 and #host.log == logs and next(trust.status()) == nil,
		label .. " REP-TRUST: a downed requester causes no abuse or trust audit")
	client.env.coop.life_of = function() return "wounded" end
	local sent = #sent_named(client, "mods.npc_abuse_use")
	client.fire("on_key_press", client.env.key_bindings.kUSE)
	dispatch()
	check(#sent_named(client, "mods.npc_abuse_use") == sent, label .. " REP-TRUST: a downed client sends no USE")
	client.env.coop.life_of = function() return "dead" end
	client.fire("on_key_press", client.env.key_bindings.kUSE)
	dispatch()
	check(#sent_named(client, "mods.npc_abuse_use") == sent, label .. " REP-TRUST: a dead client sends no USE")
	host.env.coop.life_of, client.env.coop.life_of = function() return "alive" end, function() return "alive" end
	body._pos = vec(22.5, 0, 0)
	client.fire("on_key_press", client.env.key_bindings.kUSE)
	dispatch()
	local reach = trust.status().npc_abuse_reach
	check(abuse.abuse_value == 8 and reach and reach.failed == 0, label .. " REP-TRUST: USE passes at 2.5 m")
	body._pos = vec(27, 0, 0)
	trust.reset_for_test({ default = "refuse" })
	logs = #host.log
	client.fire("on_key_press", client.env.key_bindings.kUSE)
	dispatch()
	reach = trust.status().npc_abuse_reach
	check(abuse.abuse_value == 8 and reach and reach.refused == 1 and #host.log > logs,
		label .. " REP-TRUST: USE at 7 m is audited and refused")

	if not server then
		abuse.abuse_value = 0
		nr.meet.meet_manager.a.abuse, nr.meet.meet_manager.abuse_mode = "true", "true"
		host.env.db.actor._pos = vec(18, 0, 0)
		host.env.xr_meet.notify_on_use(n, host.env.db.actor)
		check(abuse.abuse_value == 2 and #sent_named(host, "mods.npc_abuse_use") == 0,
			label .. " s42:4 the host's own USE reaches the same decision once without a request")
	end

	nr.logic = { { name = "on_actor_dist_le_nvis", v1 = 0.1, condlist = "walker@delay" } }
	body._pos, host.env.db.actor._pos = vec(19, 0, 0), vec(19.5, 0, 0)
	host.env.xr_logic.try_switch_to_another_section(n, nr, host.env.db.actor)
	body._pos = vec(21, 0, 0)
	host.env.xr_logic.switch_to_section(n, nil, "remark@trigger")
	local r = setmetatable({ object = n, st = { target = "story|actor" } }, { __index = host.env.xr_remark.action_remark_activity })
	local target = r:get_target()
	local _, direct_id = host.env.xr_remark.init_target(n, "story|actor")
	check(target and target.look_object and target.look_object:id() == client_body and direct_id == client_body
		and host.env.coop_npc_logic.user_of(n) == client_body,
		label .. " s43:3 both remark entry points keep the client through a delayed switch")
	host.add(make_obj(900, 19, 0, 0))
	r.st.target = "story|other"
	check(r:get_target().look_object:id() == 900, label .. " s43:3 other story targets use stock")
	body._alive = false
	r.st.target = "story|actor"
	target = r:get_target()
	local fallback = target and target.look_object:id()
	check((not server and fallback == 0) or (server and second_map and fallback == nil)
		or (server and not second_map and fallback == other_body),
		label .. " s43:3 fallback uses the nearest living player, never a ghost")
end

for _, set in ipairs(modes.names()) do
	if set == "hostplay" then
		run_scene(set)
	elseif set == "srv_map" then
		run_scene(set, false)
		run_scene(set, true)
	elseif set == "srv_world" then
		reset_world()
		local world = machine("host", 0, { [1] = client_body })
		world.env.coop.is_dedicated = function() return true end
		setup(world, set)
		local z = zone(world)
		world.env.xr_logic.switch_to_section(z, z._ini, CUT)
		check(not world.teleports, set .. " s39:1 a world-server ghost never runs the camera")
	else
		reset_world()
		local sp = machine("single", 0, {})
		setup(sp, set)
		local z = zone(sp)
		local n, _, abuse = stalker(sp)
		sp.env.xr_logic.switch_to_section(z, z._ini, CUT)
		sp.env.xr_meet.notify_on_use(n, sp.env.db.actor)
		local _, id = sp.env.xr_remark.init_target(n, "story|actor")
		check(sp.teleports == 1 and sp.locked and abuse.abuse_value == 2 and id == 0 and #sp.sent == 0,
			"none: stock cutscene, abuse and remark are unchanged")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
