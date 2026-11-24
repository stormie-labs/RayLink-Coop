-- SafeSpawn arrival on the side that decides (coop_npc_presence.script, Core): an arrival that comes before the
-- player's body is up there is held until it is, for a bounded time, and only then judged (RayLink-Reports #1821:
-- "npc_presence_arrival: peer 1 has no usable arrival on this map", the enemies at his arrival were never hidden).
-- Runs under every answer set (docs\MODES.md section 10).
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local verb = "mods.npc_presence_arrived"

local level_id = 2
local function pos(x) return vec3(x, 0, 0) end
function game_graph() return { valid_vertex_id = function(_, id) return id >= 0 end,
	vertex = function(_, id) return { level_id = function() return id end } end } end
local function body(id, x, map)
	local se, obj = spawn("body", pos(x), nil, { id = id, kind = "stalker" })
	se.m_game_vertex_id = map
	se._kind = "stalker"
	function se:name() return "body_" .. id end
	function se:move_offline(value)
		if value == nil then return self.moves ~= false end
		self.moves = value
	end
	function se:alive() return obj:alive() end
	function obj:game_vertex_id() return map end
	return obj
end

local function run(mode)
	MODE = mode == "none" and "sp" or "host"
	SELF = mode == "srv_map" and 257 or 0
	OBJ, SE, SENT, LOG, db.storage = {}, {}, {}, {}, {}
	local host = body(0, mode == "hostplay" and 115 or 0, level_id)
	local client = body(500, 4, level_id)
	local friend = body(501, 6, level_id) -- near the rival too: a late protection of his would show
	db.actor = host
	local rows = { { id = 1, avatar_id = 500, level = level_id }, { id = 2, avatar_id = 501, level = level_id } }
	if mode == "hostplay" then rows[#rows + 1] = { id = 0, avatar_id = 0, is_self = true } end
	coop.players = function() return rows end
	coop.is_map_server = function() return mode == "srv_map" end
	coop.is_dedicated = function() return mode == "srv_world" end
	coop.avatar_of = function(id)
		for _, row in ipairs(rows) do if row.id == id then return row.avatar_id end end
	end
	coop.life_of = function(id) return OBJ[id] and OBJ[id]:alive() and "alive" or "dead" end
	coop.levels = {
		split = function() return mode == "srv_map" or mode == "srv_world" end,
		my_level = function() return level_id end,
		level_of_player = function() return level_id end,
	}
	-- the player who is still loading: "joining" in every set that has players on its map
	local joining = {}
	local facade = load_script("coop_mode")
	local overrides = nil
	if mode == "hostplay" then
		overrides = { where = function(peer) return joining[peer] and "joining" or "here" end }
	elseif mode == "srv_map" then
		overrides = {
			where = function(peer)
				if joining[peer] then return "joining" end
				return (peer == 1 or peer == 2) and "here" or "away"
			end,
			decider = function(peer) return (peer == 1 or peer == 2) and "this" or "other" end,
		}
	end
	modes.install(facade, mode, overrides)
	load_script("coop_main").on_game_start()
	load_script("coop_mods_core")
	load_script("coop_npc_players")
	load_script("coop_trust")
	for _, callback in ipairs({ "actor_on_first_update", "actor_on_update", "on_level_changing", "save_state", "load_state" }) do
		AddScriptCallback(callback)
	end
	local original_calls = 0
	local function original() original_calls = original_calls + 1; return "stock" end
	xr_conditions = { distance_to_obj_le = original, distance_to_obj_ge = original,
		dist_to_story_obj_le = original, dist_to_story_obj_ge = original }
	sr_monster = { fake_monster = { update = original } }
	xr_effects = { pri_a28_check_zones = original }
	safespawn = { perform_silo = original, get_config = function(key) return ({ radius = 5, duration = 10 })[key] end }
	game_object = { enemy = 2 }
	-- a hostile stalker 1 m from the client's arrival, hostile to both players
	local rival = body(600, 5, level_id)
	db.storage[600] = { object = rival }
	function rival:relation(who) return (who:id() == 500 or who:id() == 501) and game_object.enemy or 1 end
	function rival:set_enemy() end
	function rival:set_npc_position(p) self._pos = vector():set(p) end
	SE[600].can_switch_online = function(self, value) self.blocked = not value end
	load_script("coop_npc_presence").on_game_start()

	local function check_mode(result, case) check(result, mode .. " " .. case) end
	local function deliver_arrival(peer, id, map)
		local t = { id = id, map = map }
		if mode == "srv_map" then t._peer = peer; peer = 0 end
		deliver({ name = verb, payload = coop_main.encode(t) }, peer)
	end
	local function advance(ms)
		NOW = NOW + ms
		SendScriptCallback("actor_on_update")
	end
	local refused = function() return log_has("npc_presence_arrival") ~= nil end

	if mode == "none" then
		-- single player: the stock SafeSpawn runs, nothing is announced or held
		safespawn.perform_silo()
		SendScriptCallback("actor_on_first_update")
		advance(1000)
		advance(20000)
		check_mode(original_calls == 1 and sent_count(verb) == 0 and not SE[600].blocked and not refused(),
			"single player keeps the stock SafeSpawn")
		return
	end
	if mode == "srv_world" then
		-- the world server leads no map: it passes the arrival to the map server of the player's map and keeps nothing
		joining[1] = true
		deliver_arrival(1, 1, level_id)
		local req, msg = sent(verb)
		advance(20000)
		check_mode(req and tonumber(req._peer) == 1 and msg.target == 257 and not SE[600].blocked and not refused(),
			"the world server relays the arrival and holds none")
		return
	end

	-- 1. the arrival comes while the player is still joining: held, not refused
	joining[1] = true
	deliver_arrival(1, 1, level_id)
	check_mode(not SE[600].blocked and not refused(), "an arrival of a joining player is held, not refused")
	advance(500)
	-- 2. he is in the world, his body is not up here yet: still held
	joining[1] = nil
	OBJ[500] = nil
	advance(500)
	check_mode(not SE[600].blocked and not refused(), "an arrival waits for the body to come up")
	-- 3. the body stands: the held arrival hides the enemies around it, once, with no refusal
	OBJ[500] = client
	advance(100)
	check_mode(SE[600].blocked == true and not refused(), "the held arrival hides the enemies once the body stands")
	-- the same operation again 5 s later: it ran already, so the hiding keeps the deadline of its one run (10 s after
	-- the body stood), not a new one 10 s after the repeat
	advance(5000)
	deliver_arrival(1, 1, level_id)
	advance(4900)
	check_mode(SE[600].blocked == true, "the enemies stay hidden inside the window")
	advance(100)
	check_mode(SE[600].blocked == false, "a later repeat of the held arrival does not lengthen the hiding")
	-- once more while his body is not up (it went offline): an operation that ran is neither held nor refused
	OBJ[500] = nil
	deliver_arrival(1, 1, level_id)
	advance(10500)
	OBJ[500] = client
	advance(100)
	check_mode(not SE[600].blocked and not refused(), "a repeat of an arrival that ran is neither held nor refused")
	-- 4. a body that never comes up: the arrival is refused after the bounded wait, by the line that says why
	LOG = {}
	OBJ[501] = nil
	deliver_arrival(2, 2, level_id)
	advance(9000)
	check_mode(not refused(), "a held arrival is not refused inside its wait")
	advance(1500)
	check_mode(log_has("npc_presence_arrival: peer 2 (here) has no standing body here 10 s after his arrival") ~= nil and
		not SE[600].blocked, "a held arrival whose body never comes up is refused after the wait")
	OBJ[501] = friend
	advance(100)
	check_mode(not SE[600].blocked, "a refused arrival is gone")
	-- 5. a player who leaves the session inside the wait: an honest disconnect is no refused claim in [coop-trust], so
	-- his held arrival is dropped with no line, at once (it does not run on a body that comes up with a later row)
	LOG = {}
	OBJ[501] = nil
	deliver_arrival(2, 3, level_id)
	advance(500)
	local gone = table.remove(rows, 2)
	advance(11000)
	check_mode(not refused() and not SE[600].blocked, "a held arrival of a player who left the session is not refused")
	table.insert(rows, 2, gone)
	deliver_arrival(2, 4, level_id)
	advance(500)
	table.remove(rows, 2)
	advance(100)
	table.insert(rows, 2, gone)
	OBJ[501] = friend
	advance(100)
	check_mode(not SE[600].blocked and not refused(), "a held arrival is dropped once its player has left the session")
	-- 6. a standing body on another map: the claim is wrong now, refused at once (nothing to wait for)
	LOG = {}
	deliver_arrival(1, 3, 3)
	check_mode(refused() and not SE[600].blocked, "a standing body on another map is refused at once")
	-- 7. a map change drops a held arrival: it was made for the world that goes
	LOG = {}
	OBJ[500] = nil
	deliver_arrival(1, 4, level_id)
	SendScriptCallback("on_level_changing")
	OBJ[500] = client
	advance(100)
	advance(11000)
	check_mode(not SE[600].blocked and not refused(), "a map change drops a held arrival")
end

for _, name in ipairs(modes.names()) do run(name) end
done("npc_presence_arrival")
