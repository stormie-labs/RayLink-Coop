-- Anomaly Coop: story blockers and levers of the mission audit of 2026-10-31 on a fake host + clients: code pads, lifts and
-- levers (deliver for ph_* logic), the tutorial loop of sr_sleep zones, Oasis, the AWR vise, the Wish Granter, Osoznanie,
-- the Red Forest bridge, Heart of Bureaucracy.
-- Run: tools\test_lua.cmd story_levers
dofile("tests/lua/support/harness_npc.lua")

-- A section that dies is one failed check, the others still run.
local function section(title, f)
	print(title)
	local ok, err = pcall(f)
	check(ok, title .. " ran to the end: " .. tostring(err))
end

local STYPE_ITEM = 2

-- Host numbering: host actor 0, proxies 500 (peer 1) and 501 (peer 2). On a client his own proxy and the host's actor swap.
local function world(n_clients)
	reset_world()
	local avatars = { [0] = 0, [1] = 500 }
	if n_clients == 2 then avatars[2] = 501 end
	local H = machine("host", 0, avatars)
	local list = { H }
	local function client(peer, own)
		local av = {}
		for p, id in pairs(avatars) do av[p] = id == own and 0 or (id == 0 and own or id) end
		local C = machine("client", peer, av)
		local function swap(id) if id == 0 then return own elseif id == own then return 0 end return id end
		C.to_host, C.to_local = swap, swap
		C.add(make_obj(own, 0, 0, 0, { _name = "host_avatar" }))
		list[#list + 1] = C
		return C
	end
	local C = client(1, 500)
	local D = n_clients == 2 and client(2, 501) or nil
	return H, C, D, list
end

-- ---------------------------------------------------------------- stock modules, in the shape the game has them
local function stock(M)
	local E = M.env
	M.fx_runs = {}
	E.modules = { stype_restrictor = 4 }
	E.utils_obj = { npc_in_zone = function(o, z) return o and z and z:inside(o:position()) end }
	local xl = {}
	E.xr_logic = xl
	function xl.switch_to_section(npc, ini, section)
		if section == "" or section == nil then return false end
		local st = E.db.storage[npc:id()]
		if st.active_section == section then return false end
		st.active_section = section ~= "nil" and section or nil
		return true
	end
	function xl.pick_section_from_condlist(actor, npc, condlist)
		for _, c in ipairs(condlist or {}) do
			if not c.cond or c.cond(actor, npc) then
				for _, fx in ipairs(c.fx or {}) do E.xr_effects[fx[1]](actor, npc, fx[2]) end
				return c.section
			end
		end
	end
	function xl.try_switch_to_another_section(npc, st, actor)
		for _, c in ipairs(st.logic or {}) do
			if c.name == "on_info" or c.name == "on_game_timer" or c.name == "on_timer" then
				if E.xr_logic.switch_to_section(npc, st.ini, E.xr_logic.pick_section_from_condlist(actor, npc, c.condlist)) then
					return true
				end
			end
		end
		return false
	end
	function xl.determine_section_to_activate(npc) return npc._active_default or "nil" end
	function xl.initialize_obj(obj, st, loaded, actor, stype)
		st.stype, st.ini, st.section_logic = stype, obj._ini, "logic"
		local s = loaded and st.loaded_active_section or "nil"
		st.active_section = s ~= "nil" and s or nil
		st.loaded_active_section, st.loaded_section_logic = nil, nil
	end
	function xl.save_obj() end
	function xl.parse_func_params(s)
		local t = {}
		for p in s:gmatch("[^:]+") do t[#t + 1] = tonumber(p) or p end
		return t
	end
	function xl.issue_event(npc, st, event_fn, ...)
		if not (st and st.actions) then return end
		for action, on in pairs(st.actions) do
			if on and action[event_fn] then action[event_fn](action, ...) end
		end
	end
	E.xr_effects = {}
	for _, n in ipairs({ "disable_ui", "disable_ui_only", "enable_ui", "kill_actor", "run_tutorial", "stop_tutorial", "teleport_actor",
		"sr_teleport" }) do
		E.xr_effects[n] = function(actor, npc, p)
			M.fx_runs[#M.fx_runs + 1] = n
			if n == "teleport_actor" then M.fx_args = p end
		end
	end
	-- stock: the offset from the position of `actor`, written to db.actor
	E.xr_effects.jup_teleport_actor = function(actor, npc)
		local p = actor:position()
		E.db.actor:set_actor_position(vec(p.x + 100, p.y, p.z))
		M.fx_runs[#M.fx_runs + 1] = "jup_teleport_actor"
	end
	E.game.has_active_tutorial = function() return M.tutorial == true end
	E.xr_conditions = {
		has_active_tutorial = function() return E.game.has_active_tutorial() end,
		actor_in_zone = function(actor, npc, p) return E.db.zone_by_name[p[1]]:inside(E.db.actor:position()) end,
		actor_inside_zone = function(actor, npc, p)
			for i = 1, #p do
				if E.db.actor_inside_zones[p[i]] then return true end
			end
			return false
		end,
	}
	-- bind_physic_object.script: the use callback in stock order
	E.bind_physic_object = { generic_physics_binder = {} }
	function E.bind_physic_object.generic_physics_binder.use_callback(self, obj, who)
		local st = self.st
		if st.active_section then xl.issue_event(self.object, st[st.active_scheme], "use_callback", obj, who) end
		E.SendScriptCallback("physic_object_on_use_callback", self.object, who)
	end
	-- ph_code.script
	local codepad = {}
	function codepad.use_callback(self) E.ui_numpad.start(self) end
	function codepad.OnNumberReceive(self, text)
		if tonumber(text) == self.st.code then M.codes_right = (M.codes_right or 0) + 1 end
	end
	E.ph_code = { codepad = codepad }
	E.ui_numpad = {}
	function E.ui_numpad.start(owner)
		E.ui_numpad.GUI = E.ui_numpad.GUI or { owner = owner }
		M.numpads = (M.numpads or 0) + 1
	end
	-- ph_idle.script
	M.idle_action = function(obj, scheme_st)
		return { object = obj, st = scheme_st, use_callback = function(self)
			E.xr_logic.switch_to_section(obj, scheme_st.ini, E.xr_logic.pick_section_from_condlist(E.db.actor, obj, scheme_st.on_use))
		end }
	end
end

local function use(M, obj, who)
	local E = M.env
	local B = E.bind_physic_object.generic_physics_binder
	B.use_callback({ object = obj, st = E.db.storage[obj:id()] }, obj, who)
end

-- A physics object with one active scheme whose action is `make(scheme_st)`.
local function ph_object(M, id, x, name, ini, section, scheme, scheme_st, make)
	local o = M.add(make_obj(id, x, 0, 0, { _name = name, _ini = make_ini(ini) }))
	scheme_st.ini = o._ini
	scheme_st.actions = { [make(o, scheme_st)] = true }
	M.env.db.storage[id] = { object = o, stype = STYPE_ITEM, ini = o._ini, active_section = section, active_scheme = scheme, [scheme] = scheme_st }
	return o
end

local function start_logic(H, C, D)
	local L = {}
	for i, M in ipairs({ H, C, D }) do
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
		L[i] = load_script(M, "coop_npc_logic")
		L[i].on_game_start()
		M.fire("actor_on_update")
	end
	return L[1], L[2], L[3]
end

local function ran(M, name)
	local n = 0
	for _, f in ipairs(M.fx_runs) do if f == name then n = n + 1 end end
	return n
end

-------------------------------------------------------------------------------
section("== item 1: code pads", function()
	local H, C = world()
	stock(H)
	stock(C)
	local proxy = H.add(make_obj(500, 2, 0, 0, { _name = "proxy" }))
	local LH = start_logic(H, C)
	local action = function(o, st) return setmetatable({ object = o, st = st }, { __index = H.env.ph_code.codepad }) end
	local PAD_INI = { logic = { { "active", "ph_code@lock" } }, ["ph_code@lock"] = { { "code", "1243" } } }
	local pad = ph_object(H, 600, 0, "dar_codelock1", PAD_INI, "ph_code@lock", "ph_code", { code = 1243 }, action)
	C.add(make_obj(600, 0, 0, 0, { _name = "dar_codelock1" }))
	QUEUE, H.sent = {}, {}

	use(H, pad, proxy)
	check((H.numpads or 0) == 0, "a client's press opens no window on the host")
	check(#sent_named(H, "npc.pad") == 1 and sent_named(H, "npc.pad")[1].target == 1, "the press goes back to the player who pressed")
	pump()
	check(C.numpads == 1, "the numpad opens on the client")
	local owner = C.env.ui_numpad.GUI.owner
	owner:OnNumberReceive("9999")
	pump()
	check((H.codes_right or 0) == 0, "a wrong code opens nothing")
	NOW = NOW + 1000
	owner:OnNumberReceive("1243")
	pump()
	check(H.codes_right == 1, "the right code reaches OnNumberReceive on the host")
	C.sent = {}
	owner:OnNumberReceive("")
	check(#sent_named(C, "npc.pad_code") == 0, "closing the window sends nothing")

	-- a window left by a stale owner: the next press answers to this pad
	C.env.ui_numpad.GUI.owner = { OnNumberReceive = function() error("stale owner") end }
	use(H, pad, proxy)
	pump()
	check(C.env.ui_numpad.GUI.owner == owner, "the stock singleton window gets our owner back")

	local function code(t) NOW = NOW + 1000; C.env.coop.send_event("npc.pad_code", C.env.coop_main.encode(t), 0); pump() end
	code({ i = 600, t = "1243x" })
	check(H.codes_right == 1, "host refuses a text that is not digits")
	code({ i = 600, t = "12431243124312" })
	check(H.codes_right == 1, "host refuses a text longer than the window allows")
	ph_object(H, 601, 1, "dar_codelock2", PAD_INI, "ph_code@lock", "ph_code", { code = 1243 }, action)
	code({ i = 601, t = "1243" })
	check(H.codes_right == 1, "host refuses a pad within reach that it did not offer")
	proxy._pos = vec(50, 0, 0)
	NOW = NOW + 1
	code({ i = 600, t = "1243" })
	check(H.codes_right == 1, "reach: the player walked away, the code is refused on the host")
	proxy._pos = vec(2, 0, 0)
	H.env.db.storage[600].active_scheme = "ph_idle"
	code({ i = 600, t = "1243" })
	check(H.codes_right == 1, "the pad is no pad any more: refused")
	H.env.db.storage[600].active_scheme = "ph_code"
	code({ i = 600, t = "1243" })
	check(H.codes_right == 2, "back in reach: accepted")
	C.env.coop.send_event("npc.pad_code", C.env.coop_main.encode({ i = 600, t = "1243" }), 0)
	pump()
	check(H.codes_right == 2, "one try a second: no guessing a code by flood")

	-- the host's own press is the stock window
	H.numpads = 0
	use(H, pad, H.env.db.actor)
	check(H.numpads == 1, "the host's own press opens the stock numpad on the host")
	check(LH.user_of(pad) == 0, "the object remembers who used it")
	use(H, H.objects[601], H.env.db.actor)
	check(H.env.ui_numpad.GUI.owner.object:id() == 601, "the host's second pad of a level does not answer to the first")
end)

-------------------------------------------------------------------------------
section("== items 4, L3: lifts and levers (ph_* logic)", function()
	local H, C = world()
	stock(H)
	stock(C)
	local proxy = H.add(make_obj(500, 302, 0, 0, { _name = "proxy" }))
	local LH = start_logic(H, C)
	H.env.xr_effects.run_postprocess = function(a, n, p) H.local_pp = (H.local_pp or 0) + 1 end
	C.env.xr_effects.run_postprocess = function() end
	H.env.xr_effects.stop_postprocess = function() H.local_stop = (H.local_stop or 0) + 1 end
	C.env.xr_effects.stop_postprocess = function() end
	C.env.level.remove_complex_effector = function(id) C.pp_removed = id end
	H.env.xr_effects.yan_gluk = function() H.gluk = (H.gluk or 0) + 1 end
	C.env.xr_effects.yan_gluk = function() C.gluk = (C.gluk or 0) + 1 end
	C.env.ini_sys = { section_exist = function() return true end }
	H.env.ini_sys = C.env.ini_sys
	for _, M in ipairs({ H, C }) do
		M.env.sound_theme = { theme = {} }
		M.env.xr_sound = { sound_table = {}, looped_sound = {} }
		M.env.bind_stalker_ext = {}
		M.env.arszi_psy = {}
		M.env.has_alife_info = function() return false end
		M.env.surge_manager, M.env.psi_storm_manager = {}, {}
		load_script(M, "coop_npc_effects").on_game_start()
		M.fire("actor_on_update")
	end
	local on_use = { { section = "ph_idle@teleport", fx = { { "disable_ui", {} }, { "run_postprocess", { "fade_in" } } } } }
	local LIFT_INI = {
		logic = { { "active", "ph_idle@open" } },
		["ph_idle@open"] = { { "on_use", "ph_idle@teleport %=disable_ui =run_postprocess(fade_in)%" } },
		["ph_idle@teleport"] = { { "on_game_timer", "20 | ph_idle@in %=run_postprocess(black:3009:true) =teleport_actor(lift_walk:lift_look)%" } },
	}
	local button = ph_object(H, 610, 300, "pri_b306_ph_button", LIFT_INI, "ph_idle@open", "ph_idle", { on_use = on_use }, H.idle_action)
	C.add(make_obj(610, 300, 0, 0, { _name = "pri_b306_ph_button" }))
	local delayed = {
		ini = button._ini,
		logic = { { name = "on_game_timer", condlist = { { section = "ph_idle@in",
			fx = { { "run_postprocess", { "black", 3009, "true" } }, { "teleport_actor", { "lift_walk", "lift_look" } } } } } } },
	}
	local wait = { ini = button._ini, logic = { { name = "on_game_timer", condlist = { { section = "ph_idle@out", fx = { { "enable_ui", {} } } } } } } }

	-- the client presses, the host is far away
	QUEUE, H.sent = {}, {}
	use(H, button, proxy)
	check(ran(H, "disable_ui") == 0, "press: the host's UI stays on")
	check((H.local_pp or 0) == 0, "press: the host's screen does not fade")
	local fx = sent_named(H, "npc.fx")
	check(#fx == 1 and fx[1].target == 1, "press: disable_ui goes to the presser")
	check(#sent_named(H, "npc.cfx") == 1 and sent_named(H, "npc.cfx")[1].target == 1, "press: the fade goes to the presser, not to everybody")
	pump()
	check(ran(C, "disable_ui") == 1, "press: the client runs disable_ui")

	check(LH.is_replicated(610) == true, "press: coop_economy_travel leaves this logic's teleport to us")
	-- the delayed section: no use callback on the stack, the press is remembered
	H.sent = {}
	H.env.xr_logic.try_switch_to_another_section(button, delayed, H.env.db.actor)
	check(ran(H, "teleport_actor") == 0, "delayed section: the host is not moved")
	pump()
	check(ran(C, "teleport_actor") == 1 and C.fx_args[1] == "lift_walk" and C.fx_args[2] == "lift_look", "delayed section: the presser is moved, the arguments arrive")
	-- stock changes the level inside this drop; here the board may wait for the others
	check(ran(C, "enable_ui") == 1 and C.pp_removed == 3009, "the rider does not wait at the exit blind and frozen")
	check((H.local_stop or 0) == 0, "the ride ends for the rider: the host's effectors stay")
	H.env.xr_logic.try_switch_to_another_section(button, wait, H.env.db.actor)
	pump()
	check(ran(C, "enable_ui") == 2 and ran(H, "enable_ui") == 2, "the stock enable_ui reaches the presser and runs on the host (an unlock)")

	-- a player within scene_radius of the presser rides along
	H.env.db.storage[610].active_section = "ph_idle@open"
	H.env.db.actor._pos = vec(310, 0, 0)
	H.fx_runs, C.fx_runs = {}, {}
	NOW = NOW + 1
	use(H, button, proxy)
	check(ran(H, "disable_ui") == 1, "the host beside the presser is part of the lift scene")
	H.env.xr_logic.try_switch_to_another_section(button, delayed, H.env.db.actor)
	check(ran(H, "teleport_actor") == 1, "the host beside the presser rides along")
	pump()
	check(ran(C, "teleport_actor") == 1, "and so does the presser")

	-- the host presses, the client is far: nothing for the client
	H.env.db.storage[610].active_section = "ph_idle@open"
	proxy._pos = vec(0, 0, 0)
	H.fx_runs, C.fx_runs, H.sent, QUEUE = {}, {}, {}, {}
	NOW = NOW + 1
	use(H, button, H.env.db.actor)
	check(ran(H, "disable_ui") == 1 and #sent_named(H, "npc.fx") == 0, "the host's own press: his effect, nobody else's")

	-- an effect of an object nobody pressed stays stock: the arrival chain at the bottom of the lift
	local arrival = H.add(make_obj(611, 0, 0, 0, { _name = "lx8_lift_button" }))
	H.env.db.storage[611] = { object = arrival, stype = STYPE_ITEM, active_section = "ph_idle@in" }
	H.fx_runs, H.sent = {}, {}
	check(LH.deliver("disable_ui", arrival, {}) == nil, "nobody pressed: deliver leaves it to stock")
	check(LH.audience_of(arrival) == nil, "nobody pressed: no audience")
	check(LH.is_replicated(611) == false, "nobody pressed: the group teleport of coop_economy_travel stays")

	-- L3: a lever that moves nobody: the presser alone, even with the host standing beside him
	proxy._pos = vec(400, 0, 0)
	H.env.db.actor._pos = vec(405, 0, 0)
	NOW = NOW + 1
	local VALVE_INI = {
		logic = { { "active", "ph_button@ready" } },
		["ph_button@ready"] = { { "on_press", "ph_button@unlocked %=disable_ui_only%" } },
		["ph_button@unlocked"] = { { "on_timer", "4000 | ph_button@locked %=enable_ui%" } },
	}
	local on_press = { { section = "ph_button@unlocked", fx = { { "disable_ui_only", {} } } } }
	local valve = ph_object(H, 620, 400, "zat_b57_ph_vintil", VALVE_INI, "ph_button@ready", "ph_button", { on_use = on_press }, H.idle_action)
	C.add(make_obj(620, 400, 0, 0, { _name = "zat_b57_ph_vintil" }))
	H.fx_runs, C.fx_runs, H.sent, QUEUE = {}, {}, {}, {}
	use(H, valve, proxy)
	check(ran(H, "disable_ui_only") == 0, "valve: the host keeps his UI, even beside the presser")
	pump()
	check(ran(C, "disable_ui_only") == 1, "valve: the presser's UI goes off for the turn")

	-- X-16 side switch: the gluk is the presser's
	local SWITCH_INI = { logic = { { "active", "ph_button@on" } }, ["ph_button@on"] = { { "on_press", "ph_button@deactivate %=yan_gluk%" } } }
	local on_gluk = { { section = "ph_button@deactivate", fx = { { "yan_gluk", {} } } } }
	local switch = ph_object(H, 621, 400, "yan_labx16_switcher1", SWITCH_INI, "ph_button@on", "ph_button", { on_use = on_gluk }, H.idle_action)
	C.add(make_obj(621, 400, 0, 0, { _name = "yan_labx16_switcher1" }))
	QUEUE, H.sent = {}, {}
	use(H, switch, proxy)
	check((H.gluk or 0) == 0, "switch: no gluk for the host")
	check(#sent_named(H, "npc.cfx") == 1 and sent_named(H, "npc.cfx")[1].target == 1, "switch: the gluk goes to the presser")
	pump()
	check(C.gluk == 1, "switch: the presser sees it")
	-- the host in a dialog does not swallow what a client's press shows
	H.env.db.actor._talking = true
	H.env.db.storage[621].active_section = "ph_button@on"
	H.sent = {}
	use(H, switch, proxy)
	H.env.db.actor._talking = false
	check(#sent_named(H, "npc.cfx") == 1, "a press by a client is relayed while the host talks")

	-- an NPC that uses a button: no player's press, the stock path
	local npc = H.add(make_obj(622, 400, 0, 0, { _name = "stalker" }))
	H.env.db.storage[620].active_section = "ph_button@ready"
	H.fx_runs = {}
	use(H, valve, npc)
	check(ran(H, "disable_ui_only") == 1 and H.env.db.storage[620].coop_press == nil and LH.user_of(valve) == nil, "an NPC's use is no press")

	-- session without clients: stock
	LH._set_host_on(false)
	H.env.db.storage[620].active_section = "ph_button@ready"
	H.fx_runs = {}
	use(H, valve, H.env.db.actor)
	check(ran(H, "disable_ui_only") == 1 and H.env.db.storage[620].coop_press == nil, "no clients: stock, no audience kept")
end)

-------------------------------------------------------------------------------
section("== item 5: the tutorial loop of sr_sleep zones", function()
	local H, C = world()
	stock(H)
	stock(C)
	local proxy = H.add(make_obj(500, 52, 0, 0, { _name = "proxy" }))
	start_logic(H, C)
	local SLEEP_INI = {
		logic = { { "active", "sr_idle@wait" } },
		["sr_idle@wait"] = { { "on_actor_inside", "sr_idle@run %=run_tutorial(tutorial_sleep)%" } },
		["sr_idle@run"] = { { "on_actor_outside", "sr_idle@wait %=stop_tutorial%" }, { "on_info2", "{!has_active_tutorial -sleep_active} sr_idle@wait %+x%" } },
	}
	local zone = H.add(make_obj(630, 50, 0, 0, { _name = "sleep_zone", _radius = 5, _ini = make_ini(SLEEP_INI) }))
	zone._alive = false
	H.env.db.zone_by_name.sleep_zone = zone
	H.env.db.storage[630] = { object = zone, loaded_active_section = "sr_idle@wait", loaded_section_logic = "logic" }
	H.env.xr_logic.initialize_obj(zone, H.env.db.storage[630], true, H.env.db.actor, 4)
	local st_wait = { ini = zone._ini, logic = { { name = "on_actor_inside", condlist = { { section = "sr_idle@run", fx = { { "run_tutorial", { "tutorial_sleep" } } } } } } } }
	local no_tutorial = function(a, n) return not H.env.xr_conditions.has_active_tutorial(a, n, {}) end
	local st_run = { ini = zone._ini, logic = { { name = "on_info", condlist = { { cond = no_tutorial, section = "sr_idle@wait" } } } } }
	local function pass()
		local st = H.env.db.storage[630].active_section == "sr_idle@run" and st_run or st_wait
		NOW = NOW + 1
		H.env.xr_logic.try_switch_to_another_section(zone, st, H.env.db.actor)
	end
	QUEUE, H.sent = {}, {}
	for _ = 1, 6 do pass() end
	check(#sent_named(H, "npc.fx") == 1, "a client in the zone gets the tutorial once, not on every pass")
	check(H.env.db.storage[630].active_section == "sr_idle@run", "the zone stays in its run section")
	proxy._pos = vec(200, 0, 0)
	NOW = NOW + 1
	check(no_tutorial(H.env.db.actor, zone), "outside any pick: the host's own state")
	pass()
	check(H.env.db.storage[630].active_section == "sr_idle@wait", "the client walks out: the section falls back")
	-- the host alone: stock
	H.env.db.actor._pos = vec(50, 0, 0)
	H.tutorial = true
	NOW = NOW + 1
	check(H.env.xr_conditions.has_active_tutorial(H.env.db.actor, zone, {}) == true, "the host's own tutorial still counts")
	H.tutorial = false
	check(H.env.xr_conditions.has_active_tutorial(H.env.db.actor, zone, {}) == false, "none running, no client: false")
end)

-------------------------------------------------------------------------------
section("== item 9: Oasis", function()
	local H, C = world()
	stock(H)
	stock(C)
	local proxy = H.add(make_obj(500, 1002, 0, 0, { _name = "proxy" }))
	start_logic(H, C)
	local OASIS_INI = {
		logic = { { "active", "sr_idle" } },
		sr_idle = { { "on_actor_in_zone2", "jup_b16_teleport | {-jup_b16_no_teleport} sr_idle@teleport %-jup_b16_show_particles%" } },
		["sr_idle@teleport"] = { { "on_info", "{-jup_b16_no_teleport} sr_idle %+jup_b16_go_particle =jup_teleport_actor%" } },
	}
	local sr = H.add(make_obj(640, 1000, 0, 0, { _name = "jup_b16_sr", _radius = 300, _ini = make_ini(OASIS_INI) }))
	sr._alive = false
	local inner = H.add(make_obj(641, 1000, 0, 0, { _name = "jup_b16_teleport", _radius = 5 }))
	H.env.db.zone_by_name.jup_b16_teleport = inner
	H.env.db.zone_by_name.jup_b16_sr = sr
	C.env.db.zone_by_name.jup_b16_teleport = C.add(make_obj(641, 1000, 0, 0, { _name = "jup_b16_teleport", _radius = 5 }))
	H.env.db.storage[640] = { object = sr, loaded_active_section = "sr_idle", loaded_section_logic = "logic" }
	H.env.xr_logic.initialize_obj(sr, H.env.db.storage[640], true, H.env.db.actor, 4)
	C.env.db.actor._pos = vec(1002, 0, 0)
	local in_zone = { ini = sr._ini, logic = { { name = "on_actor_in_zone", v1 = "jup_b16_teleport", condlist = { { section = "sr_idle@teleport" } } } } }
	local teleport = { ini = sr._ini, logic = { { name = "on_info", condlist = { { section = "sr_idle", fx = { { "jup_teleport_actor", {} } } } } } } }
	NOW = NOW + 1
	QUEUE, H.sent = {}, {}
	H.env.xr_logic.try_switch_to_another_section(sr, in_zone, H.env.db.actor)
	H.env.xr_logic.try_switch_to_another_section(sr, teleport, H.env.db.actor)
	check(H.env.db.actor:position().x == 0, "the host's actor is not shifted")
	check(ran(H, "jup_teleport_actor") == 0, "the effect does not run on the host")
	pump()
	check(C.env.db.actor:position().x == 1102, "the client is shifted from his own position")
	-- the host still sees him in the zone for a moment: a second pass of the restrictor
	H.env.db.storage[640].active_section = "sr_idle"
	NOW = NOW + 1
	H.env.xr_logic.try_switch_to_another_section(sr, in_zone, H.env.db.actor)
	H.env.xr_logic.try_switch_to_another_section(sr, teleport, H.env.db.actor)
	pump()
	check(C.env.db.actor:position().x == 1102, "a repeat from the host's late view does not shift him twice")
	-- the host in the zone moves himself
	proxy._pos = vec(0, 0, 0)
	H.env.db.actor._pos = vec(1001, 0, 0)
	H.env.db.storage[640].active_section = "sr_idle"
	NOW = NOW + 1
	H.env.xr_logic.try_switch_to_another_section(sr, in_zone, H.env.db.actor)
	H.env.xr_logic.try_switch_to_another_section(sr, teleport, H.env.db.actor)
	check(H.env.db.actor:position().x == 1101, "the host in the zone is moved as in stock")
end)

-------------------------------------------------------------------------------
section("== item 11: actor_inside_zone answers for any player", function()
	local H, C = world()
	stock(H)
	stock(C)
	local proxy = H.add(make_obj(500, 70, 0, 0, { _name = "proxy" }))
	start_logic(H, C)
	local z = H.add(make_obj(650, 70, 0, 0, { _name = "pas_b400_sr_hall_1", _radius = 5 }))
	H.env.db.zone_by_name.pas_b400_sr_hall_1 = z
	local xc = H.env.xr_conditions
	NOW = NOW + 1
	check(xc.actor_inside_zone(H.env.db.actor, nil, { "other_zone", "pas_b400_sr_hall_1" }) == true, "a proxy in one of the zones counts")
	proxy._pos = vec(0, 0, 0)
	NOW = NOW + 1
	check(xc.actor_inside_zone(H.env.db.actor, nil, { "pas_b400_sr_hall_1" }) == false, "nobody inside: false")
	H.env.db.actor_inside_zones.other_zone = true
	check(xc.actor_inside_zone(H.env.db.actor, nil, { "other_zone" }) == true, "the stock answer (a zone with a complex shape) stays")
	local real_inside = C.env.xr_conditions.actor_inside_zone
	C.env.db.actor_inside_zones.other_zone = true
	check(real_inside(C.env.db.actor, nil, { "other_zone" }) == true, "client: stock")
end)

-------------------------------------------------------------------------------
section("== L2: the AWR vise", function()
	local H, C = world()
	stock(H)
	stock(C)
	local proxy = H.add(make_obj(500, 1, 0, 0, { _name = "proxy" }))
	local function awr(M)
		local E = M.env
		E.bind_awr = {}
		function E.bind_awr.access() return M.awr_access end
		function E.bind_awr.physic_object_on_use_callback(obj, who)
			if E.bind_awr.access(obj) then M.awr_ui = who:id() end
		end
		E.RegisterScriptCallback("physic_object_on_use_callback", function(obj, who) return E.bind_awr.physic_object_on_use_callback(obj, who) end)
	end
	awr(H)
	awr(C)
	start_logic(H, C)
	local vise = H.add(make_obj(660, 0, 0, 0, { _name = "mar_awr_tiski_01" }))
	H.env.db.storage[660] = { object = vise, stype = STYPE_ITEM }
	C.add(make_obj(660, 0, 0, 0, { _name = "mar_awr_tiski_01" }))
	H.awr_access = true -- full_access ran on the host only: a client's own table says no
	QUEUE, H.sent = {}, {}
	use(H, vise, proxy)
	check(H.awr_ui == nil, "a client's press opens no workshop on the host")
	check(#sent_named(H, "npc.vise") == 1 and sent_named(H, "npc.vise")[1].target == 1, "the press goes back to the player who pressed")
	pump()
	check(C.awr_ui == 0, "the workshop opens on the client, for his own actor")
	check(C.env.bind_awr.access() == nil, "the client's access function is put back")
	H.awr_access = false
	C.awr_ui, H.sent, QUEUE = nil, {}, {}
	use(H, vise, proxy)
	check(#sent_named(H, "npc.vise") == 0, "no access on the host: nothing opens")
	H.env.bind_awr.access = function() error("a vise the mod does not list") end
	local ok_vise = pcall(use, H, vise, proxy)
	check(ok_vise and #sent_named(H, "npc.vise") == 0, "an error of access stays out of the host's use callback")
	H.env.bind_awr.access = function() return H.awr_access end
	H.awr_access = true
	use(H, vise, H.env.db.actor)
	check(H.awr_ui == 0, "the host's own press stays stock")
	local other = H.add(make_obj(661, 0, 0, 0, { _name = "some_box" }))
	H.env.db.storage[661] = { object = other, stype = STYPE_ITEM }
	H.sent, H.awr_ui = {}, nil
	use(H, other, proxy)
	check(#sent_named(H, "npc.vise") == 0, "any other object goes the stock way")
	local pairs_ = real_ini("coop_compat_awr.ltx")
	check(pairs_:r_string_ex("route_pairs", "time_event@bind_awr") == "owner", "the delayed window of bind_awr may run on a client")
end)

-------------------------------------------------------------------------------
-- The quests group on the harness: coop_quests_core plus what the test loads.
local function quests(M, names)
	local E = M.env
	E.coop_quests_core = load_script(M, "coop_quests_core")
	E.coop_quests_core.on_game_start()
	for _, n in ipairs(names) do
		local m = load_script(M, n)
		m.on_game_start()
	end
	M.fire("actor_on_first_update")
end

section("== item 10: the Red Forest bridge is the host's", function()
	local H, C = world()
	stock(H)
	stock(C)
	for _, M in ipairs({ H, C }) do
		M.env.xr_effects.bridge_down = function() M.bridge = "down" end
		M.env.xr_effects.bridge_up = function() M.bridge = "up" end
		M.env.xr_effects.bridge_stop = function() M.bridge = "stop" end
		quests(M, { "coop_quests_story" })
	end
	QUEUE = {}
	for _, name in ipairs({ "bridge_down", "bridge_stop", "bridge_up" }) do
		C.bridge = nil
		C.env.xr_effects[name]() -- the tutorial's key action
		check(C.bridge == nil, name .. ": the client's copy does not move on its own")
		pump()
		check(H.bridge == name:gsub("bridge_", ""), name .. ": the host's bridge moves")
	end
	H.bridge = nil
	H.env.xr_effects.bridge_down()
	check(H.bridge == "down", "the host's own key works as in stock")
end)

section("== item 11: the ISG squad of Crossfire comes from the host", function()
	local H, C = world()
	stock(H)
	stock(C)
	for _, M in ipairs({ H, C }) do
		M.env.dialogs_lostzone = { spawn_pass_hall_isg_companion_squad = function() M.squad = (M.squad or 0) + 1 end }
		quests(M, { "coop_quests_story" })
	end
	QUEUE = {}
	C.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad(nil, nil)
	check(C.squad == nil, "the client's dialog action makes nothing itself")
	pump()
	check(H.squad == 1, "the host makes the squad")
	H.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad(nil, nil)
	check(H.squad == 2, "the host's own dialog as in stock")
end)

-------------------------------------------------------------------------------
section("== item 2: the Wish Granter", function()
	local H, C = world()
	stock(H)
	stock(C)
	local proxy = H.add(make_obj(500, 1, 0, 0, { _name = "proxy" }))
	local function wish(M)
		local E = M.env
		M.msgs = {}
		E.actor_menu = { set_msg = function(_, text) M.msgs[#M.msgs + 1] = text end }
		E.give_info = function(i) E.db.actor:give_info_portion(i) end
		E.ui_dyn_msg_box = { multi_choice = function(list, ...) M.window = { list = list, names = { ... } } end }
		-- xr_effects.make_a_wish in stock shape: choice 1 ends the game with a Lua error
		E.xr_effects.make_a_wish = function(actor, npc, p)
			M.wish_runs = (M.wish_runs or 0) + 1
			local list = {}
			list[1] = function() error("WISH GRANTED", 2) end
			list[2] = function() M.wished = 2; E.give_info("actor_made_wish") end
			list[3] = function() M.wished = 3; E.give_info("actor_made_wish") end
			E.ui_dyn_msg_box.multi_choice(list, "st_wish_1", "st_wish_2", "st_wish_3", "st_wish_99")
		end
	end
	wish(H)
	wish(C)
	local LH = start_logic(H, C)
	quests(H, { "coop_quests_scenes" })
	quests(C, { "coop_quests_scenes" })
	local on_use = { { fx = { { "make_a_wish", {} } } } }
	local INI = { logic = { { "active", "ph_idle" } }, ph_idle = { { "on_use", "%=make_a_wish%" } } }
	local granter = ph_object(H, 670, 0, "sar_monolith", INI, "ph_idle", "ph_idle", { on_use = on_use }, H.idle_action)
	QUEUE, H.sent = {}, {}
	use(H, granter, proxy)
	check(H.wish_runs == 1, "the stock wish runs on the host (its infos and the list)")
	check(H.window == nil, "a client's press opens no window on the host")
	pump()
	check(C.window and #C.window.names == 4 and C.window.names[2] == "st_wish_2", "the window opens on the client with the host's list")
	C.window.list[2]()
	pump()
	check(H.wished == 2 and C.wished == nil, "the choice runs on the host")
	check(H.env.db.actor:has_info("actor_made_wish"), "the wish is made")
	C.window.list[3]()
	pump()
	check(H.wished == 2, "the wish is spent: a second answer does nothing")

	-- choice 1, by a client: no error on the host, everybody sees the end
	H.env.db.actor._info = {}
	use(H, granter, proxy)
	pump()
	QUEUE = {}
	C.window.list[1]()
	local ok, err = pcall(pump)
	check(ok, "choice 1 is no Lua error on the host: " .. tostring(err))
	check(H.env.db.actor:has_info("actor_made_wish"), "choice 1 spends the wish")
	check(#H.msgs == 1 and #C.msgs == 1 and H.msgs[1] == "st_zone_disappeared", "choice 1 is shown to every player")

	-- a press with no choice: "say nothing" has no action
	H.env.db.actor._info = {}
	use(H, granter, proxy)
	pump()
	C.window.list[4]()
	pump()
	check(not H.env.db.actor:has_info("actor_made_wish"), "say nothing: no wish")

	-- a peer that was not offered the window
	H.wished = nil
	use(H, granter, proxy)
	QUEUE = {}
	H.env.coop_quests_core.register_host_action("probe", function() end)
	local handler = H.handlers["quests.act"][1]
	handler(H.env.coop_main.encode({ a = "wish", c = 2 }), 7)
	check(H.wished == nil, "another player's answer is refused")

	-- the host's own press: his window, choice 1 harmless
	H.window = nil
	H.msgs, C.msgs = {}, {}
	H.env.db.actor._info = {}
	QUEUE = {}
	use(H, granter, H.env.db.actor)
	check(H.window and #H.window.names == 4, "the host's own press opens his window")
	local ok2 = pcall(H.window.list[1])
	pump()
	check(ok2 and #H.msgs == 1 and #C.msgs == 1, "choice 1 of the host: no error, shown to every player")
	check(LH ~= nil, "logic loaded")

	-- outside a session: stock
	H.set_session(false)
	H.window = nil
	H.env.xr_effects.make_a_wish(H.env.db.actor, granter, {})
	check(H.window ~= nil and not pcall(H.window.list[1]), "single player: stock, choice 1 is the stock error")
	H.set_session(true)
end)

-------------------------------------------------------------------------------
section("== item 3: refusing Osoznanie moves every player", function()
	local H, C, D, all = world(2)
	for _, M in ipairs(all) do stock(M) end
	H.add(make_obj(500, 1, 0, 0, { _name = "proxy1" }))
	H.add(make_obj(501, 2, 0, 0, { _name = "proxy2" }))
	C.add(make_obj(501, 2, 0, 0))
	D.add(make_obj(500, 1, 0, 0))
	start_logic(H, C, D)
	for _, M in ipairs(all) do
		M.env.level.patrol_path_exists = function(name) return not M.other_level end
		M.env.patrol = function(name)
			return { point = function()
				local v = vec(name == "warlab_jump_sar2_walk" and 900 or 905, 0, 0)
				v.sub = function() return { getH = function() return 1.5 end } end
				return v
			end }
		end
		M.env.db.actor.set_actor_direction = function(_, h) M.heading = h end
		M.env.dialogs_warlab = { osoznanie_decline = function(npc, actor)
			M.declined = true
			M.env.db.actor:give_info_portion("warlab_actor_teleported_to_sar2")
		end }
		quests(M, { "coop_quests_scenes" })
	end
	-- a client declines: his own dialog moves him, the others follow
	QUEUE = {}
	C.env.dialogs_warlab.osoznanie_decline(nil, nil)
	check(C.declined and ran(C, "teleport_actor") == 0, "the speaker's dialog moves him, as in stock")
	pump()
	check(H.env.db.actor:position().x == 900 and H.heading == -1.5, "the host follows, to the point and heading of the stock teleport")
	check(ran(H, "teleport_actor") == 0, "not through the effect: coop_economy_travel would take the players around him along")
	check(ran(D, "teleport_actor") == 1 and D.fx_args[1] == "warlab_jump_sar2_walk" and D.fx_args[2] == "warlab_jump_sar2_look", "the other client follows")
	check(ran(C, "teleport_actor") == 0 and C.env.db.actor:position().x == 0, "the speaker is not moved twice")
	-- the host declines
	for _, M in ipairs(all) do M.fx_runs = {} end
	NOW = NOW + 1
	H.env.dialogs_warlab.osoznanie_decline(nil, nil)
	pump()
	check(H.declined, "the host's own dialog moved him")
	check(ran(C, "teleport_actor") == 1 and ran(D, "teleport_actor") == 1, "both clients follow the host")

	-- respawned during the waves: back to the room the teleport leads to
	C.env.db.actor._info.warlab_actor_teleported_to_sar2 = true
	C.env.db.actor._pos = vec(5, 0, 0)
	QUEUE = {}
	C.fire("coop_respawned", "arrival", 0, 0, 0, 1)
	check(C.env.db.actor:position().x == 900 and #QUEUE == 0, "a player who respawns before the waves end is sent back, he alone")
	local function again(seq)
		C.env.db.actor._pos = vec(5, 0, 0)
		C.fire("coop_respawned", "arrival", 0, 0, 0, seq)
		return C.env.db.actor:position().x
	end
	C.other_level = true
	check(again(2) == 5, "respawned on another level: no path, no teleport")
	C.other_level = false
	C.env.db.actor._info.sar2_monolith_end = true
	check(again(3) == 5, "the waves are over: nothing")
	C.env.db.actor._info = {}
	check(again(4) == 5, "nobody declined: nothing")
end)

print(string.format("\nRESULT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("tests failed") end
