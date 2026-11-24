-- G8-3: exercise the original mod functions, installed through compat startup.
-- Removing one presence patch must reproduce its finding, including on a map server.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
local REF = "../anomaly-ref/unpacked/scripts/"
local FIXES = "temp/review/corpus/merged/"

local function read(path)
	local f = assert(io.open(path, "rb"), path)
	local s = f:read("*a"); f:close()
	return s
end

local function boot(name, packed)
	reset_world()
	NOW = 100000
	local M = machine(name == "none" and "single" or "host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local E = M.env
	E.coop.is_map_server = function() return name == "srv_map" end
	E.coop.is_dedicated = function() return name == "srv_world" end
	E.coop.life_of = function(id) return (M.life or {})[id] or "alive" end
	E.db.actor._pos = vec(1000)
	local a, b = M.add(make_obj(500, 10, 0, 0)), M.add(make_obj(501, 1000, 0, 0))
	for _, o in ipairs({ E.db.actor, a, b }) do o.game_vertex_id = function() return 1 end end
	if name == "srv_world" then M.objects[500], M.objects[501] = nil, nil end
	M.records = {
		[500] = { id = 500, position = vec(10), m_game_vertex_id = 1, alive = function() return true end },
		[501] = { id = 501, position = vec(1000), m_game_vertex_id = 1, alive = function() return true end },
	}
	E.alife_object = function(id) return M.records[id] end
	E.game_graph = function() return { vertex = function(_, id) return { level_id = function() return id end } end } end
	E.coop_mode = load_script(M, "coop_mode")
	modes.install(E.coop_mode, name)
	if not M.env.coop_trust then load_script(M, "coop_trust") end
	load_script(M, "coop_npc_players")
	load_script(M, "coop_mods_core")
	E.clsid = { online_offline_group_s = 90 }
	E.getFS = function() return { update_path = function(_, _, file)
		if packed then return "temp/g8_missing/" .. file end
		return (file == "aaaa_script_fixes_mp.script" and FIXES or REF) .. file
	end } end
	E.r_file_as_string = function(path)
		M.archive_reads = (M.archive_reads or 0) + 1
		return read(REF .. assert(path:match("([^/]+)$")))
	end
	local K = load_script(M, "coop_npc_compat")
	return M, E, K, a
end

-- Compile entire real function at its real source line, retaining the file locals
-- that compat's existing function rewriter must share with other mod callbacks.
local function original(K, m, path, header, prefix, ...)
	local body, line = assert(K.method_text(read(path), header))
	local chunk = assert(loadstring(string.rep("\n", line - 1) .. (prefix or "") .. body, "@" .. path))
	setfenv(chunk, m)
	chunk(...)
end

local function install(K, M)
	K.on_game_start()
	for _, line in ipairs(M.log) do check(not line:find("! ", 1, true), "startup has no error: " .. line) end
end

local function anomaly(name)
	local M, E, K, a = boot(name)
	local m = setmetatable({}, { __index = E }); E.aaaa_script_fixes_mp = m
	local zone = M.add(make_obj(20, 0, 0, 0))
	local monster = M.add(make_obj(30, 1, 0, 0))
	function zone:force_set_restrictor_type(n) self.kind = n end
	function monster:invalidate_restrictions() self.invalidated = (self.invalidated or 0) + 1 end
	local registry = { [20] = { radius = 20, last_pos = vec(0), entities = {} } }
	m.device = function() return { cam_pos = vec(1000) } end
	m.dup_table = function(t) local r = {}; for k, v in pairs(t) do r[k] = v end; return r end
	m.empty_table = function(t) for k in pairs(t) do t[k] = nil end end
	m.is_empty = function(t) return next(t) == nil end
	m.is_not_empty = function(t) return next(t) ~= nil end
	m.clamp = function(n, lo, hi) return math.min(hi, math.max(lo, n)) end
	m.get_object_by_id = E.level.object_by_id
	original(K, m, FIXES .. "aaaa_script_fixes_mp.script", "function anomaly_restrictor_update()",
		"local anomaly_restrictor_db, db_online_monsters = ...; local anomaly_restrictor_db_k, anomaly_restrictor_db_v; " ..
		"local anomaly_amount_per_update, anomaly_cycle_start_time, anomaly_restrictor_db_count = 2, nil, 0; ",
		registry, { [30] = monster })
	install(K, M)
	m.anomaly_restrictor_update()
	check((zone.kind == 2) == (name ~= "none" and name ~= "srv_world"), name .. ": u01 remote client activates anomaly avoidance outside camera")
	if name == "hostplay" or name == "srv_map" then
		M.life = { [500] = "down" }; m.anomaly_restrictor_update()
		check(registry[20].entities[30] == true, name .. ": u01 a downed living client still counts as present")
		M.life = nil
		monster._pos = vec(19); a._pos = vec(-160); E.coop_npc_players.invalidate()
		m.anomaly_restrictor_update()
		check(next(registry[20].entities) == nil, name .. ": u01 second camera filter retains its own 170m bound")
		a._pos = vec(-151); E.coop_npc_players.invalidate(); m.anomaly_restrictor_update()
		check(next(registry[20].entities) == nil, name .. ": u01 second camera bound is strict at 170m")
		a._pos = vec(10); monster._pos = vec(20); E.coop_npc_players.invalidate()
		m.anomaly_restrictor_update()
		check(next(registry[20].entities) == nil, name .. ": u01 keeps strict mutant-anomaly radius at 20m")
		monster._pos = vec(19.99); m.anomaly_restrictor_update()
		check(registry[20].entities[30] == true, name .. ": u01 inside both player and anomaly bounds restores restriction")
	end
	if name ~= "none" then
		a._pos = vec(1000); E.coop_npc_players.invalidate()
		m.anomaly_restrictor_update()
		check(next(registry[20].entities) == nil, name .. ": u01 removes restrictions after every player leaves")
		E.db.actor._pos = vec(0); a._alive = false; E.coop_npc_players.invalidate()
		m.anomaly_restrictor_update()
		check((next(registry[20].entities) ~= nil) == (name == "hostplay"), name .. ": u01 dead clients and server ghost do not count")
	else
		m.device = function() return { cam_pos = vec(0) } end
		m.anomaly_restrictor_update()
		check(registry[20].entities[30] == true, "none: u01 still follows camera rather than actor position")
	end
end

local function crows(name, packed)
	local M, E, K, a = boot(name, packed)
	local m = setmetatable({ crowkiller = {} }, { __index = E }); E.sr_crow_spawner = m
	local pos = vec(0)
	m.patrol = function() return { point = function() return pos end, level_vertex_id = function() return 1 end,
		game_vertex_id = function() return 1 end } end
	m.alife_create = function() M.spawned = (M.spawned or 0) + 1 end
	original(K, m, REF .. "sr_crow_spawner.script", "function crowkiller:check_for_spawn_new_crow()")
	install(K, M)
	if packed then check((M.archive_reads or 0) > 0, name .. ": crow rewrite reads packed stock source through VFS") end
	local spawner = setmetatable({ st = { path_table = { "crows" } }, spawn_points_idle = {} }, { __index = m.crowkiller })
	spawner:check_for_spawn_new_crow()
	check((M.spawned or 0) == ((name == "none" or name == "srv_world") and 1 or 0), name .. ": s39:7 crow cannot appear beside a remote client")
	if name ~= "none" and name ~= "srv_world" then
		check(spawner.spawn_points_idle.crows == nil, name .. ": rejected crow point does not consume cooldown")
		a._pos = vec(100); E.coop_npc_players.invalidate()
		spawner:check_for_spawn_new_crow()
		check(not M.spawned, name .. ": exactly 100m still prevents crow spawn")
		a._pos = vec(100.01); E.coop_npc_players.invalidate()
		spawner:check_for_spawn_new_crow()
		check(M.spawned == 1 and spawner.spawn_points_idle.crows == NOW + 10000, name .. ": outside 100m spawns once with original cooldown")
	end
end

local function target(name)
	local M, E, K, a = boot(name)
	E.task_functor, E.task_status_functor = {}, {}
	local squad = { id = 60, position = vec(0), m_game_vertex_id = 1, dist_to_actor = 1000,
		clsid = function() return 90 end, commander_id = function() return 61 end }
	M.records[61] = { id = 61, group_id = 60 }
	E.get_story_squad = function() return squad end
	E.get_object_squad = function(npc) if npc.group_id == squad.id then return squad end end
	E.axr_companions = { companion_squads = {} }
	local companions = load_script(M, "coop_npc_companions")
	local leaders = companions._leaders()
	local m = setmetatable({}, { __index = E }); E.tasks_faction_control = m
	local chunk = assert(loadstring(read(REF .. "tasks_faction_control.script"), "@tasks_faction_control.script"))
	setfenv(chunk, m); chunk()
	install(K, M)
	local task = { stage = 1, task_giver_id = 99 }
	local function result() return E.task_functor.simulation_task_target("hostage", "target", nil, task) end
	check(result() == (name == "none" and 60 or 99), name .. ": s40:6 nearby rescuer changes target to giver")
	check(squad.dist_to_actor == 1000, name .. ": task does not overwrite shared squad distance")
	local wrapped = E.task_functor.simulation_task_target
	K.on_game_start()
	check(E.task_functor.simulation_task_target == wrapped, name .. ": repeated startup leaves one faction-target wrapper")
	if name ~= "none" then
		M.life = { [500] = "down" }
		check(result() == 99, name .. ": downed living escort remains near the squad")
		M.life = nil
		-- The companion API returns 0 if stock owns the squad and no explicit leader is known.
		E.axr_companions.companion_squads[60] = squad
		check(result() == (name == "hostplay" and 60 or 99),
			name .. ": owner zero counts only when the process's actor is a player")
		leaders[60] = 501 -- known escort takes precedence over a nearer unrelated player
		check(result() == 60, name .. ": task follows escort participant rather than unrelated nearest player")
		leaders[60] = 500; a._pos = vec(50); M.records[500].position = vec(50); E.coop_npc_players.invalidate()
		check(result() == 99, name .. ": task exactly 50m switches to giver")
		a._alive = false; M.records[500].alive = function() return false end; E.coop_npc_players.invalidate()
		check(result() == 60, name .. ": dead escort body or record cannot satisfy task proximity")
		a._alive = true; M.records[500].alive = function() return true end
		M.records[500].m_game_vertex_id = 2; M.objects[500] = nil; E.coop_npc_players.invalidate()
		check(result() == 60, name .. ": escort on a different map cannot satisfy task proximity")
		E.axr_companions.companion_squads[60] = nil; squad.dist_to_actor = nil
		check(result() == 60, name .. ": no nearby player and no cached distance keeps squad target")
		task.stage = 0
		check(result() == 60, name .. ": stage zero keeps squad target")
	else
		squad.dist_to_actor = nil
		check(result() == 99, "none: absent cached distance retains original task target")
		task.stage = 0
		check(result() == 60, "none: stage zero retains original task target")
	end
end

-- R68 (spawnface): whether host_on ever turns on where the actor is a ghost was not seen live; the first switch-on there
-- writes one line, and no other process or frame writes it
local function host_on_line(name)
	local M, E, K = boot(name)
	install(K, M)
	for _ = 1, 3 do
		M.fire("actor_on_update")
		NOW = NOW + 1000
	end
	local n = 0
	for _, line in ipairs(M.log) do if line:find("host_on: on", 1, true) then n = n + 1 end end
	local ghost = name == "srv_map" or name == "srv_world"
	check(n == (ghost and 1 or 0), name .. ": host_on says once that it is on where the actor is no player")
end

for _, name in ipairs(modes.names()) do
	host_on_line(name)
	anomaly(name)
	crows(name)
	crows(name, true)
	target(name)
end
print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
