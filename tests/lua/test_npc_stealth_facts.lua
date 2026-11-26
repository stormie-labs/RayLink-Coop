-- G13-1: exercise the NPC wrappers through the owner callbacks and the level request route.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

-- The active GAMMA script is available in the review checkout. This fixture keeps
-- the same inputs and private state for checkouts without the review corpus.
local visual_fixture = [[
local jacketmult, get_camo_k, pewpewmult = 1, 0, 0
local vision_memory, marked, actor_marked = {}, {}, 0
function get_visible_value(npc, who, dt, q, lum, vf, velocity, distance, object_distance)
	local camo = get_camo_k > 0 and velocity == 0 and object_distance >= 30
		and clamp(get_camo_k / 20 * (1 - object_distance * 0.01), 0.02, 1) or 1
	local cr, acc = IsMoveState("mcCrouch"), IsMoveState("mcAccel")
	local crouch = cr and stealth_mcm.get_config(acc and "low_crouch" or "crouch") or 1
	local weight = math.max(1, math.exp(db.actor:get_total_weight() / 100) * jacketmult
		* math.max(0.01, 1.1 - 0.02 * object_distance))
	actor_marked = marked[npc:id()] and 50000 or 0
	if npc:see(who) then vision_memory[npc:id()] = who:id() end
	return (33 * who:get_luminocity() * (distance - object_distance / 1.35) / distance + pewpewmult)
		* (1 + vf * velocity) * (distance - object_distance / 1.15) / distance * weight * crouch * camo * q * 2
		+ actor_marked
end
function slot_in_out()
	local item = db.actor:item_in_slot(7)
	local kind = item and ini_sys:r_string_ex(item:section(), "kind")
	jacketmult = ({ o_medium = 2, o_light = 1.35, o_heavy = 4.5, o_sci = 2 })[kind] or 1
	get_camo_k = item and ini_sys:r_float(item:section(), "npc_blindness_koeff") or 0
end
function npc_on_before_hit(npc, hit)
	if hit.draftsman:id() == db.actor:id() then marked[npc:id()] = true end
end
function actor_on_weapon_fired()
	local w = db.actor:active_item()
	if not w or not IsWeapon(w) or IsMelee(w) or w:weapon_is_silencer() then return end
	pewpewmult = 7
	CreateTimeEvent("xcvb", "wpn_fired_stop", 0.16, function() pewpewmult = 0 return true end)
end
function on_game_start()
	RegisterScriptCallback("actor_on_weapon_fired", actor_on_weapon_fired)
	RegisterScriptCallback("npc_on_before_hit", npc_on_before_hit)
end
]]

local visual_source = visual_fixture
local visual_corpus = io.open("temp/review/corpus/merged/visual_memory_manager.script", "r")
if visual_corpus then
	visual_source = visual_corpus:read("*a")
	visual_corpus:close()
end

local function model(M, id, section)
	return M.add(make_obj(id, 0, 0, 0, {
		_section = section,
		item_in_slot = function(self, slot) if slot == 7 then return self.outfit end end,
		get_total_weight = function() return 0 end,
		get_luminocity = function() return 1 end,
	}))
end

local function boot(role, peer, avatars, answers, overrides)
	local M = machine(role, peer, avatars)
	local E = M.env
	-- Map servers own their NPCs and receive these requests from the world server.
	if answers == "srv_map" then
		E.coop.is_map_server = function() return true end
		E.coop.is_mirror = function() return false end
	end
	if answers == "srv_world" then E.coop.is_dedicated = function() return true end end
	M.move, M.stock, M.tilt, M.key = 1, {}, false, false
	E.db.actor = model(M, 0)
	E.coop.player_safemode = function(p) return M.stock[p] end
	E.level.actor_moving_state = function() return M.move end
	E.level.get_time_hours, E.level.get_time_minutes = function() return 12 end, function() return 0 end
	E.IsMoveState = function(state, compare_state)
		return bit.band(compare_state or E.level.actor_moving_state(), state == "mcCrouch" and 16 or 32) ~= 0
	end
	E.IsStalker = function() return true end
	E.IsMonster = function() return false end
	E.IsWeapon = function(item) return item.weapon == true end
	E.IsMelee = function(item) return item.melee == true end
	E.IsOutfit = function(item) return item and item.outfit_item == true end
	E.get_console_cmd = function() return "renderer_r1" end
	E.weather = { get_value_vector = function() return vec(0, 0, 0) end }
	E.camp_lum, E.level_weathers = { luminocity_inc = 0 }, {}
	E.clamp = function(value, low, high) return math.max(low, math.min(value, high)) end
	E.ini_sys = make_ini({
		camo = { { "kind", "o_light" }, { "npc_blindness_koeff", "10" } },
		heavy = { { "kind", "o_heavy" } },
	})
	E.ini_sys.r_float = E.ini_sys.r_float_ex
	local cfg = { crouch = 0.5, low_crouch = 0.25, velocity = 1, distance = 1, weight = 1, luminocity = 1, memory = 0 }
	E.stealth_mcm = { get_config = function(k) return cfg[k] end }
	E.weapon_cover_tilt = {
		is_tilt_enabled = function() return M.tilt end,
		is_tilt_key_pressed = function() return M.key end,
	}
	E.xr_conditions = { actor_is_safemode = function() return M.stock[peer] or (M.tilt and M.key) end }
	E.visual_memory_manager = setmetatable({}, { __index = E })
	local chunk = assert(loadstring(visual_source, "@visual_memory_manager.script"))
	setfenv(chunk, E.visual_memory_manager)()
	E.visual_memory_manager.on_game_start()

	local facade = load_script(M, "coop_mode")
	if answers ~= "none" then
		local chunk = assert(loadfile("tests/lua/support/mode_" .. answers .. ".lua"))
		local set = setfenv(chunk, E)()
		for k, v in pairs(overrides or {}) do set[k] = v end
		assert(facade.install(set))
	end
	load_script(M, "coop_mods_core")
	load_script(M, "coop_trust")
	load_script(M, "coop_npc_players")
	load_script(M, "coop_npc_adapters")
	local facts_file = io.open("gamedata/scripts/coop_npc_stealth_facts.script", "r")
	if facts_file then
		facts_file:close()
		load_script(M, "coop_npc_stealth_facts")
	end
	E.coop_main.callback_registered = function(name, f)
		for _, callback in ipairs(M.callbacks[name] or {}) do if callback == f then return true end end
		return false
	end
	load_script(M, "coop_npc_compat").on_game_start()
	-- The meeting wrapper starts after compat in the game's alphabetic startup.
	load_script(M, "coop_npc_meet").on_game_start()
	E.coop_npc_players.host_on = function() return true end
	return M
end

local function mirror(peer, avatars)
	return boot("client", peer, avatars, "hostplay", {
		leads_here = function() return false end,
		decider = function() return "other" end,
		is_player_mirror = function() return true end,
	})
end

local function outfit(M, id, name)
	local obj = model(M, id, name)
	obj.outfit_item = true
	return obj
end

local function gun(M, id, silenced, melee)
	local obj = model(M, id)
	obj.weapon, obj.melee = true, melee
	obj.weapon_is_silencer = function() return silenced end
	return obj
end

local function tick(ms, ...)
	NOW = NOW + ms
	for _, M in ipairs({ ... }) do M.fire("actor_on_update") end
	pump()
end

local function observe(M, npc, who, velocity, distance)
	return M.env.visual_memory_manager.get_visible_value(npc, who, 0.1, 0.25, 1, 1, velocity or 0, 100, distance or 40, 0)
end

local function fire(M, w)
	M.env.db.actor._active = w
	M.fire("actor_on_weapon_fired", M.env.db.actor, w)
	pump()
end

local avatars = { [0] = 0, [1] = 500, [2] = 501 }
local function exercise(authority, one, two, who, other, label, local_second)
	local E, npc = authority.env, model(authority, 20)
	one.move, two.move = 16, 1
	tick(600, one, two, authority)
	local crouch = observe(authority, npc, who)
	local standing = observe(authority, npc, other)
	check(crouch < standing and crouch < observe(authority, npc, other, 1), label .. " m27:3 crouching owner vs running player")
	check(math.abs(crouch / standing - 0.5) < 0.001, label .. " m27:3 ordinary crouch multiplier")
	one.move = 48
	tick(100, one)
	check(math.abs(observe(authority, npc, who) / standing - 0.25) < 0.001, label .. " m27:3 low crouch compare_state")
	one.move = 1
	tick(600, one, two, authority)
	local baseline = observe(authority, npc, who)
	who.outfit = outfit(authority, 71, "camo")
	check(observe(authority, npc, who) < baseline, label .. " m27:2 stationary camo beyond 30 m")
	check(observe(authority, npc, who, 1) == observe(authority, npc, other, 1),
		label .. " m27:2 camo does not apply while moving")
	check(observe(authority, npc, who, 0, 29) == observe(authority, npc, other, 0, 29),
		label .. " m27:2 camo does not apply below 30 m")
	local camo = observe(authority, npc, who)
	other.outfit = outfit(authority, 72, "heavy")
	if local_second then E.visual_memory_manager.slot_in_out(other.outfit) end
	check(observe(authority, npc, who) == camo and observe(authority, npc, other) > baseline,
		label .. " m27:2 another player's heavy outfit affects that player only")
	who.outfit = nil
	check(observe(authority, npc, who) == baseline, label .. " m27:2 removing outfit restores baseline")

	local shooter_base = observe(authority, npc, who)
	local other_base = observe(authority, npc, other)
	fire(one, gun(one, 81, true))
	fire(one, gun(one, 82, false, true))
	check(observe(authority, npc, who) == shooter_base, label .. " m27:4 suppressed and melee shots do not count")
	fire(one, gun(one, 83, false))
	check(observe(authority, npc, who) > shooter_base and observe(authority, npc, other) == other_base,
		label .. " m27:4 unsuppressed shot affects only the shooter")
	tick(161)
	check(observe(authority, npc, who) == shooter_base, label .. " m27:4 shot expires on the map authority's clock")
	fire(two, gun(two, 84, false))
	check(observe(authority, npc, who) == shooter_base and observe(authority, npc, other) > other_base,
		label .. " m27:4 the other player's shot stays with that player")

	who._active, other._active = gun(authority, 85), gun(authority, 86)
	local safe = E.xr_conditions.actor_is_safemode
	local who_peer, other_peer = one.peer, two.peer
	authority.stock[who_peer], authority.stock[other_peer] = false, false
	one.tilt, one.key = true, false
	tick(600, one, two, authority)
	check(not safe(who, npc), label .. " m25:3 automatic tilt is not manual safemode")
	one.key = true
	tick(100, one)
	check(safe(who, npc) and not safe(other, npc), label .. " m25:3 only the manual WCT owner becomes safe")
	one.key, authority.stock[who_peer] = false, true
	tick(100, one)
	check(safe(who, npc), label .. " m25:3 stock safemode still counts after manual tilt is released")
	authority.stock[who_peer] = false
	check(not safe(who, npc), label .. " m25:3 releasing manual tilt clears the result")
	if local_second then
		two.tilt, two.key = true, true
		tick(100, two)
		check(safe(other, npc) and not safe(who, npc), label .. " m25:3 host's local WCT never leaks to the proxy")
		two.key = false
	end
	one.key, one.move = true, 48
	tick(600, one)
	check(safe(who, npc) and observe(authority, npc, who) < baseline, label .. " fresh facts enter NPC calculations")
	tick(1600, authority)
	check(not safe(who, npc) and observe(authority, npc, who) == baseline, label .. " stale motion and WCT expire")
	tick(600, one)
	authority.fire("load_state", {})
	one.fire("load_state", {})
	check(not safe(who, npc) and observe(authority, npc, who) == baseline, label .. " load clears transient facts")
	tick(1, one, authority)
	check(safe(who, npc) and observe(authority, npc, who) < baseline, label .. " first owner update after load republishes facts")

	-- The world can reload while a player and its map authority stay on the same map.
	one.fire("coop_on_world_leaving")
	authority.fire("coop_on_world_leaving")
	check(not safe(who, npc) and observe(authority, npc, who) == baseline, label .. " a world reload clears facts on a retained map")
	tick(1, one, authority)
	check(safe(who, npc) and observe(authority, npc, who) < baseline, label .. " owner refreshes facts after the world reload")

	authority.fire("npc_on_net_destroy", who)
	check(not safe(who, npc) and observe(authority, npc, who) == baseline, label .. " avatar removal invalidates facts immediately")
	tick(600, one, authority)
	-- A body removed from this map invalidates its state even when its peer returns promptly.
	authority.objects[who:id()] = nil
	-- Facts of a peer with no body here (his level change in flight: the stand, build 57, 2 of 74) are dropped in every
	-- mode: a guard, counted, with no "[coop-trust] !" line (honest play would write one per level change)
	local before = E.coop_trust.status().sf_player
	local failed, lines = before and before.failed or 0, #authority.log
	one.env.coop_mods_core.to_host("sf_wct", { manual = true })
	pump()
	local after, loud = E.coop_trust.status().sf_player, false
	for i = lines + 1, #authority.log do
		if tostring(authority.log[i]):find("! sf_player", 1, true) then loud = true end
	end
	check(after and after.failed > failed and not loud,
		label .. " facts of a peer with no body on this map are dropped and counted, with no trust line")
	tick(100, authority)
	authority.add(who)
	check(not safe(who, npc) and observe(authority, npc, who) == baseline, label .. " avatar exit clears facts before its return")

	local C = one.env.coop_mods_core
	C.to_host("sf_motion", { state = 32768, _peer = other_peer })
	C.to_host("sf_wct", { manual = "true", _peer = other_peer })
	pump()
	local trust = E.coop_trust.status()
	check(trust.sf_motion.failed == 1 and trust.sf_motion.refused == 0
		and trust.sf_wct.failed == 1 and trust.sf_wct.refused == 0
		and not safe(who, npc) and observe(authority, npc, who) == baseline, label .. " malformed facts are logged and neutralized")
	C.to_host("sf_wct", { manual = true, _peer = other_peer })
	pump()
	check(safe(who, npc) and not safe(other, npc), label .. " transport sender overrides a claimed peer")
	local claims = trust.sf_player.checked
	for _ = 1, 32 do C.to_host("sf_shot", {}) end
	pump()
	check(trust.sf_player.checked > claims and trust.sf_player.checked < claims + 32, label .. " shot reports are rate-limited")
end

for _, set in ipairs(modes.names()) do
	reset_world()
	if set == "hostplay" then
		local host = boot("host", 0, avatars, set)
		local one = mirror(1, avatars)
		local who = model(host, 500)
		exercise(host, one, host, who, host.env.db.actor, "Co-op", true)
	elseif set == "srv_map" then
		local first, second = 257, 258
		local split = false
		local function route(peer)
			return split and peer == 2 and second or first
		end
		boot("host", 0, avatars, "srv_world", {
			level_request = function(_, payload, from)
				local cm = MACHINES[0].env.coop_main
				local t = cm.decode(payload)
				t._peer = from
				return "pass", route(from), cm.encode(t)
			end,
		})
		local function map(peer)
			return boot("client", peer, avatars, set, {
				where = function(p) return p ~= 0 and route(p) == peer and "here" or "away" end,
				decider = function(p) return p == 0 and "nobody" or (route(p) == peer and "this" or "other") end,
			})
		end
		local A, B = map(first), map(second)
		local one, two = mirror(1, avatars), mirror(2, avatars)
		exercise(A, one, two, model(A, 500), model(A, 501), "Server same map", false)
		split = true
		local a_npc, b_npc = model(A, 20), model(B, 20)
		local a_who, old_who, b_who = A.objects[500], A.objects[501], model(B, 501)
		local before_a = observe(A, a_npc, a_who)
		local before_b = observe(B, b_npc, b_who)
		fire(two, gun(two, 87, false))
		check(observe(B, b_npc, b_who) > before_b and observe(A, a_npc, a_who) == before_a,
			"Server two maps: a shot reaches only the shooter's map authority")
		A.stock[2], B.stock[2] = false, false
		two.tilt, two.key = true, true
		tick(600, two, A, B)
		check(B.env.xr_conditions.actor_is_safemode(b_who, b_npc) and not A.env.xr_conditions.actor_is_safemode(old_who, a_npc),
			"Server two maps: WCT is effective only on the player's current map")
	elseif set == "srv_world" then
		local world, one = boot("host", 0, avatars, set), mirror(1, avatars)
		tick(600, one, world)
		fire(one, gun(one, 81, false))
		local requests = { "mods.sf_motion", "mods.sf_wct", "mods.sf_shot" }
		for _, name in ipairs(requests) do
			local sent = sent_named(world, name)
			check(#sent == 1 and sent[1].target == 257 and world.env.coop_main.decode(sent[1].payload)._peer == 1,
				"World server forwards " .. name .. " with the transport sender")
		end
		check(next(world.env.coop_trust.status()) == nil, "world server leaves NPC facts to the map authority")
	else
		local single = boot("single", 0, {}, set)
		local E, npc = single.env, model(single, 20)
		local who = E.db.actor
		who.outfit = outfit(single, 71, "camo")
		E.visual_memory_manager.slot_in_out(who.outfit)
		local previous = observe(single, npc, who)
		single.move, single.tilt, single.key = 48, true, true
		tick(600, single)
		check(observe(single, npc, who) < previous and E.xr_conditions.actor_is_safemode(who, npc),
			"Single player keeps stock costume, movement and local WCT")
		previous = observe(single, npc, who)
		fire(single, gun(single, 81, false))
		check(observe(single, npc, who) > previous and #single.sent == 0, "Single player keeps stock shot and sends no events")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
