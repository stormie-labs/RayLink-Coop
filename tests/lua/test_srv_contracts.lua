-- Dev 57 G16-5: real mode facade and squad brain over separate Lua environments.
local PASSES, FAILS = 0, 0
local function check(ok, name)
	if ok then PASSES = PASSES + 1 else FAILS = FAILS + 1 end
	print((ok and "  ok   " or "  FAIL ") .. name)
end

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, item in pairs(value) do out[key] = copy(item) end
	return out
end

local function machine(role, map, map_id)
	local env = setmetatable({}, { __index = _G })
	env._G = env
	local m = { env = env, now = 0, seconds = 10, rolls = 0, dismissed = 0, released = 0,
		callbacks = {}, shares = { up = {}, down = {} }, objects = {}, state = { game_object = {} } }
	local packets = {}
	local function load(name)
		local module = setmetatable({}, { __index = env })
		setfenv(assert(loadfile("gamedata/scripts/" .. name .. ".script")), module)()
		env[name] = module
		return module
	end
	local function fire(name, ...)
		for fn in pairs(m.callbacks[name] or {}) do fn(...) end
	end
	m.fire = fire
	function m.tick()
		m.now = m.now + 5000
		fire("actor_on_update")
	end
	function m.add(id, name, online)
		local object = { id = id, online = online, m_game_vertex_id = map_id, name = function() return name end }
		function object:switch_offline() self.online = false end
		m.objects[id] = object
		return object
	end
	function m.squad()
		local squad = m.add(42, "escort", true)
		function squad:clsid() return 1 end
		-- The engine iterator returns a member record as the first value.
		function squad:squad_members()
			local index = 0
			return function()
				index = index + 1
				local id = (m.members or { 43 })[index]
				return id and { id = id }
			end
		end
		function squad:commander_id() return 43 end
		m.add(43, "escort_member", true)
		return squad
	end
	env.coop = {
		is_active = function() return role ~= "none" end,
		is_host = function() return role == "srv_world" or role == "hostplay" end,
		is_dedicated = function() return role == "srv_world" end,
		is_map_server = function() return role == "srv_map" end,
		to_host_id = function(id) return id end, to_local_id = function(id) return id end,
		levels = {
			split = function() return role == "srv_world" or role == "srv_map" end,
			logic_bytes = function() return m.bytes or "" end,
			logic_put = function(bytes) m.bytes = bytes end,
			holder_of = function(id) return m.holder and (not m.member_holder or id == 43) and m.holder or nil end,
		},
	}
	env.marshal = {
		encode = function(t)
			packets[#packets + 1] = copy(t)
			return string.rep("x", #packets)
		end,
		decode = function(bytes) return copy(packets[#bytes] or m.incoming) end,
	}
	function m.send_mind(dest, id)
		m.bytes = ""
		env.coop_srv_levels_brain.logic_of(id)
		dest.incoming = env.marshal.decode(m.bytes)
		dest.bytes = string.rep("x", 257)
		dest.env.coop_srv_levels_brain.logic_in(id)
		return dest.incoming
	end
	env.printf = function() end
	env.RegisterScriptCallback = function(name, fn)
		m.callbacks[name] = m.callbacks[name] or {}
		m.callbacks[name][fn] = true
	end
	env.UnregisterScriptCallback = function(name, fn)
		if m.callbacks[name] then m.callbacks[name][fn] = nil end
	end
	env.CreateTimeEvent = function() m.stock_timer = true end
	env.RemoveTimeEvent = function() m.stock_timer = false end
	env.time_global = function() return m.now end
	env.clsid = { online_offline_group_s = 1 }
	env.SIMBOARD = { assign_squad_to_smart = function(_, squad, id) squad.smart_id = id end }
	env.alife_storage_manager = { get_state = function() return m.state end }
	env.game_graph = function()
		return { vertex = function(_, id) return { level_id = function() return id end } end }
	end
	local sim = {
		level_name = function(_, id) return id == map_id and map or "another_map" end,
		iterate_objects = function(_, fn) for id, object in pairs(m.objects) do if fn(object) then break end end end,
		set_switch_online = function(_, id, allowed) m.objects[id].switch_online_allowed = allowed end,
		set_switch_offline = function(_, id, allowed) m.objects[id].switch_offline_allowed = allowed end,
	}
	env.alife = function() return sim end
	env.alife_object = function(id) return m.objects[id] end
	env.level = { name = function() return map end }
	env.db = { actor = {}, storage = {} }
	env.xr_effects = { blacklisted_maps = {} }
	env.se_load_var = function(id) return m.objects[id] and m.objects[id].companion end
	env.se_save_var = function(id, _, key, value)
		if key == "companion" and m.objects[id] then m.objects[id].companion = value end
	end
	env.axr_companions = { companion_squads = {}, dismiss_special_squad = function(squad)
		m.dismissed = m.dismissed + 1
		env.axr_companions.companion_squads[squad.id] = nil
		if m.objects[43] then m.objects[43].companion = nil end
	end }
	env.utils_data = {
		CTime_from_table = function(t) return t.s end,
		CTime_to_table = function() return { Y = 2012, M = 7, D = 1, h = 0, m = 0, s = m.seconds, ms = 0 } end,
	}
	env.game = { get_game_time = function()
		return { diffSec = function(_, since) return m.seconds - since end }
	end }
	env.txr_paid_companions = { paid_companions = {} }
	local function on_game_load() env.CreateTimeEvent("cycle", "paid_companions", 10, function() end) end
	local function on_level_changing() end
	function env.txr_paid_companions.on_game_start()
		env.RegisterScriptCallback("on_game_load", on_game_load)
		env.RegisterScriptCallback("on_level_changing", on_level_changing)
	end
	function m.hire(period)
		env.axr_companions.companion_squads[42] = m.objects[42]
		m.objects[43].companion = true
		env.txr_paid_companions.paid_companions[42] = {
			members_id = { 43 }, join_time = env.utils_data.CTime_to_table(), guard_period = period,
		}
	end
	local function choose()
		if m.transitions then return end
		m.rolls = m.rolls + 1
		m.transitions = { level_changer_list = {} }
		for i = 2, 5 do m.transitions.level_changer_list["agr_level_changer_to_underground_" .. i] = i ~= 3 end
	end
	env.agroprom_underground_transition_randomizer = {
		randomize_transitions = choose,
		disable_transitions = choose,
		save_state = function(data) data.agr_ug_transitions = m.transitions end,
		load_state = function(data) m.transitions = copy(data.agr_ug_transitions) end,
	}
	function env.agroprom_underground_transition_randomizer.on_game_start()
		env.RegisterScriptCallback("actor_on_first_update", env.agroprom_underground_transition_randomizer.disable_transitions)
	end
	env.safe_release_manager = {
		release = function(object) m.pending = object.id end,
		execute_destroy_callback = function()
			if not m.pending then return end
			m.released, m.objects[m.pending], m.pending = m.released + 1, nil, nil
		end,
	}
	env.coop_trust = { pass = function(_, ok) m.trust = ok and "ok" or "bad"; return true end }
	-- the Core keeps the shares: coop_mode.share_up / share_down hand them to coop_quests_core
	env.coop_quests_core = {
		share_up = function(name, get, set) m.shares.up[name] = { get = get, set = set } end,
		share_down = function(name, get, set) m.shares.down[name] = { get = get, set = set } end,
	}
	function m.share(dir, dest, id)
		for name, row in pairs(m.shares[dir]) do
			local other = dest.shares[dir][name]
			local value = row.get()
			if other and value then other.set(copy(value), id) end
		end
	end
	function m.start(stock_first)
		load("coop_mode")
		local modes = dofile("tests/lua/support/modes.lua")
		modes.live(env.coop_mode, load)
		load("coop_mods_core")
		load("coop_util")
		load("coop_srv_roles")
		load("coop_srv_levels_brain")
		local function stock()
			env.txr_paid_companions.on_game_start()
			env.agroprom_underground_transition_randomizer.on_game_start()
		end
		if stock_first then stock() end
		local file = io.open("gamedata/scripts/coop_srv_contracts.script", "rb")
		if file then file:close(); load("coop_srv_contracts").on_game_start() end
		if not stock_first then stock() end
	end
	return m
end

local source = machine("srv_map", "l02_garbage", 2)
local world = machine("srv_world", "fake_start", 0)
local arrival = machine("srv_map", "l03_agroprom", 3)
source.start(true)
world.start(false)
arrival.start(false)
source.squad().smart_id = 51
world.squad().m_game_vertex_id = 2
world.objects[42].online = false
world.holder = 0x101
arrival.squad()
source.hire(172800)
source.fire("on_game_load")
check(not source.stock_timer, "s40:3 map server retires the stock timer after callback registration")
local mind = source.send_mind(world, 42)
check(mind ~= nil and mind.smart == 51 and world.objects[42].smart_id == 51, "s40:3 squad handoff keeps the original brain state")
check(mind ~= nil and type(mind.coop_paid_contract_v1) == "table", "s40:3 paid contract travels inside the squad handoff")
world.objects[42].m_game_vertex_id = 3
world.holder = 0x102
local saved = {}
world.fire("save_state", saved)
local row = saved.coop_paid_contracts_v1 and saved.coop_paid_contracts_v1[42]
check(row and row.members_id[1] == 43 and row.join_time.s == 10 and row.guard_period == 172800 and not row.ended,
	"s40:3 world saves members, hire time, paid period and active status")

local reloaded = machine("srv_world", "fake_start", 0)
reloaded.state = copy(saved)
reloaded.start(true)
reloaded.squad().m_game_vertex_id = 3
reloaded.holder = 0x102
reloaded.fire("load_state", copy(saved))
reloaded.send_mind(arrival, 42)
arrival.env.axr_companions.companion_squads[42] = arrival.objects[42]
arrival.objects[43].companion = true
reloaded.seconds = 86411
reloaded.tick()
reloaded.share("down", arrival)
arrival.tick()
check(arrival.dismissed == 0, "s40:3 a two-day hire survives the first day after reload")
reloaded.seconds = 172811
reloaded.tick()
reloaded.share("down", arrival)
arrival.tick()
reloaded.share("down", arrival)
arrival.tick()
check(arrival.dismissed == 1 and reloaded.dismissed == 0, "s40:3 destination authority dismisses the expired squad once")
local ended = {}
reloaded.fire("save_state", ended)
check(ended.coop_paid_contracts_v1 and ended.coop_paid_contracts_v1[42].ended, "s40:3 expiration survives another world save")
source.send_mind(reloaded, 42)
local replayed = {}
reloaded.fire("save_state", replayed)
check(replayed.coop_paid_contracts_v1 and replayed.coop_paid_contracts_v1[42].ended,
	"s40:3 an old active handoff cannot reopen an ended contract")

local reported = machine("srv_world", "fake_start", 0)
reported.start(true)
reported.squad().m_game_vertex_id = 2
reported.holder = 0x101
reported.member_holder = true
source.share("up", reported, 3)
check(reported.trust == "bad", "s40:3 the world validates a map report against its source level")
source.share("up", reported, 2)
local untransferred = {}
reported.fire("save_state", untransferred)
check(untransferred.coop_paid_contracts_v1 and untransferred.coop_paid_contracts_v1[42],
	"s40:3 world saves a hire even when the map holds the member before the squad")

local dismissed = machine("srv_map", "l02_garbage", 2)
dismissed.start(false)
dismissed.squad()
dismissed.hire(172800)
dismissed.env.axr_companions.dismiss_special_squad(dismissed.objects[42])
dismissed.env.axr_companions.companion_squads[42] = dismissed.objects[42] -- an unpaid recruit on the same map
dismissed.tick()
check(dismissed.dismissed == 1, "s40:3 a completed dismissal does not dismiss a later unpaid recruit on its map")
local unpaid = machine("srv_map", "l03_agroprom", 3)
unpaid.start(false)
unpaid.env.axr_companions.companion_squads[42] = unpaid.squad()
dismissed.send_mind(unpaid, 42)
unpaid.tick()
check(unpaid.dismissed == 0, "s40:3 a completed dismissal does not dismiss a later unpaid recruit after a handoff")

local underground = machine("srv_map", "l03u_agr_underground", 4)
underground.start(true)
arrival.fire("actor_on_first_update")
underground.fire("actor_on_first_update")
world.state.opened_routes = {}
world.tick()
world.tick()
world.share("down", arrival)
world.share("down", underground)
arrival.tick()
underground.tick()
for i = 1, 6 do
	arrival.add(50 + i, "agr_level_changer_to_underground_" .. i, i ~= 4)
	arrival.add(60 + i, "agr_space_restrictor_to_agr_ug_" .. i, true)
end
underground.add(70, "kat2_zone_buzz_0015", true)
underground.add(71, "agru_level_changer_to_agroprom_3", true)
arrival.tick()
underground.tick()
underground.tick()
check(world.rolls == 1 and arrival.rolls == 0 and underground.rolls == 0, "m32:6 only the world rolls one choice")
check(arrival.objects[51].online and arrival.objects[53].online and arrival.objects[63].online
	and not arrival.objects[52].online and not arrival.objects[56].online and not arrival.objects[66].online,
	"m32:6 Agroprom keeps the chosen and backup entries and closes the other entrances")
check(arrival.objects[54].switch_online_allowed == nil, "m32:6 the map waits until a late transition comes online")
arrival.objects[54].online = true
arrival.tick()
check(not arrival.objects[54].online and arrival.objects[54].switch_online_allowed == false,
	"m32:6 a late online entrance gets the world restriction")
check(underground.released == 1 and underground.objects[70] == nil and underground.objects[71].online,
	"m32:6 underground removes the anomaly and retains stock exits")
world.env.agroprom_underground_transition_randomizer.save_state(saved)
local restored_choice = machine("srv_world", "fake_start", 0)
restored_choice.start(true)
restored_choice.env.agroprom_underground_transition_randomizer.load_state(saved)
restored_choice.tick()
local restarted = machine("srv_map", "l03_agroprom", 3)
restarted.start(false)
restarted.add(52, "agr_level_changer_to_underground_2", true)
restarted.add(53, "agr_level_changer_to_underground_3", true)
restored_choice.share("down", restarted)
restarted.tick()
check(restored_choice.rolls == 0 and restarted.objects[53].online and not restarted.objects[52].online,
	"m32:6 saved choice is republished before the restored world's route table is ready")

for _, role in ipairs({ "none", "hostplay" }) do
	local game = machine(role, "l03_agroprom", 3)
	game.start(true)
	game.fire("on_game_load")
	game.fire("actor_on_first_update")
	check(game.stock_timer and game.rolls == 1 and next(game.shares.up) == nil and next(game.shares.down) == nil,
		role .. " retains the stock contract and transition callbacks")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
