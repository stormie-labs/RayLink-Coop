-- G8-7: exercise the stock callbacks and the actual GAMMA override through the Lua router.
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/stubs.d/route.lua")
local modes = dofile("tests/lua/support/modes.lua")
local gamma = "temp/review/corpus/merged/"
local stock = "temp/stock_scripts/scripts/"

-- The engine's unlocalizer (engine\src\xrServerEntities\script_storage.cpp) as G.A.M.M.A. configures it for this script
-- (gamedata\configs\unlocalizers\xcv_phantoms_fix_unlocalizer.ltx): these locals become module fields before compiling.
local XCV_UNLOCAL = { enable_psi_hit = true, tmr = true, phantom_frequency = true, phantoms_appear_at = true,
	spawned_phantoms = true }
local function unlocalize(src)
	local out = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		local l = line:gsub("\r$", "")
		local rest = l:match("^local[ \t]+(.*)$")
		if rest and not rest:match("^function[ \t]") then
			local body = rest:gsub("%-%-.*$", "")
			local has_value = body:find("=", 1, true) ~= nil
			for v in (body:match("^([^=]*)") or ""):gmatch("[^,]+") do
				if XCV_UNLOCAL[v:match("^%s*(.-)%s*$")] then
					l = rest
					if not has_value then
						local code, comment = l:match("^(.-)(%-%-.*)$")
						l = code and (code .. "= nil " .. comment) or (l .. " = nil")
					end
					break
				end
			end
		end
		out[#out + 1] = l
	end
	return table.concat(out, "\n")
end

local function mod(E, path, name, transform)
	local module = setmetatable({}, { __index = E })
	E[name] = module
	if transform then
		local fh = assert(io.open(path .. name .. ".script", "rb"))
		local src = fh:read("*a")
		fh:close()
		setfenv(assert(loadstring(transform(src), "@" .. path .. name .. ".script")), module)()
	else
		setfenv(assert(loadfile(path .. name .. ".script")), module)()
	end
	return module
end

local function boot(set, avatars, answers)
	reset_world()
	local M = machine(set == "none" and "single" or "host", 0, avatars)
	local E = M.env
	E.coop.is_map_server = function() return set == "srv_map" end
	E.coop.is_dedicated = function() return set == "srv_world" end
	load_script(M, "coop_mode")
	modes.install(E.coop_mode, set, answers)
	install_route_stubs(E.coop)
	-- The native stand-in evaluates host routing with a bool. The facade independently answers who leads the map.
	local intercepts = {}
	E.axr_main = {
		callback_set = function(name, f)
			local list = intercepts[name]
			if not list[f] then list[f] = #M.callbacks[name] + 1 end
			M.callbacks[name][#M.callbacks[name] + 1] = f
		end,
		callback_unset = function(name, f)
			intercepts[name][f] = nil
			local list = M.callbacks[name]
			for i = #list, 1, -1 do if list[i] == f then table.remove(list, i) end end
		end,
	}
	E.RegisterScriptCallback = function(name, f) return E.axr_main.callback_set(name, f) end
	E.UnregisterScriptCallback = function(name, f) return E.axr_main.callback_unset(name, f) end
	for _, name in ipairs({ "npc_on_before_hit", "npc_on_update", "monster_on_update", "monster_on_before_hit",
		"actor_on_update", "actor_on_first_update", "actor_on_before_hit", "on_enemy_eval", "on_key_press",
		"save_state", "load_state", "coop_on_container_opened" }) do
		intercepts[name], M.callbacks[name] = {}, {}
	end
	E.coop_main.callback_registered = function(name, f)
		return intercepts[name][f] ~= nil or intercepts[name][E.coop_route.wrapper_of(name, f)] ~= nil
	end
	E.getFS = function()
		return {
			exist = function() return false end,
			update_path = function(_, _, name) return gamma .. name end,
		}
	end
	load_script(M, "coop_mods_core")
	load_script(M, "coop_npc_players")
	load_script(M, "coop_route").install()
	return M, E
end

local function silent_case(set, local_killer, split)
	local M, E = boot(set, { [0] = 0, [1] = 500, [2] = 501 }, split and {
		where = function(peer) return peer == 1 and "here" or "away" end,
	} or nil)
	local host = E.db.actor
	local proxy = M.add(make_obj(500, 102, 0, 0))
	local victim = M.add(make_obj(600, 100, 0, 0))
	local witness = M.add(make_obj(601, 104, 0, 0))
	local attacker = local_killer and host or proxy
	if local_killer then host._pos = vec(101, 0, 0) end
	attacker._active = M.add(make_obj(700, 0, 0, 0, { _section = "wpn_knife" }))
	E.level.rain_factor = function() return 0 end
	E.strformat = string.format
	E.VEC_Y = vec(0, 1, 0)
	E.game_relations = { is_factions_enemies = function() return false end }
	E.hit = setmetatable({
		light_burn = 1, burn = 2, strike = 3, shock = 4, wound = 5, radiation = 6,
		telepatic = 7, chemical_burn = 8, explosion = 9, fire_wound = 10,
	}, { __call = function(_, original) return { type = original and original.type } end })
	M.options = {
		["gameplay/silent_kills/sk_enabled"] = true,
		["gameplay/silent_kills/sk_all_melee_ok"] = true,
		["gameplay/silent_kills/sk_melee_enabled"] = true,
	}
	local sk = mod(E, stock, "gameplay_silent_kills")
	-- Exercise both startup orders across the cases.
	if local_killer then sk.on_game_start() end
	local world = load_script(M, "coop_npc_world")
	world.on_game_start()
	if not local_killer then sk.on_game_start() end
	M.env.coop_npc_players.host_on = function() return set == "hostplay" or set == "srv_map" end

	local case = set .. (local_killer and " host kill" or " proxy kill")
	local flags = { ret_value = true }
	M.fire("npc_on_before_hit", victim, { draftsman = attacker, type = E.hit.wound }, 0, flags)
	local saved = {}
	M.fire("save_state", saved)
	local registered = saved.stealth_kills and saved.stealth_kills.victims
	if set == "srv_world" then
		check(flags.ret_value and not victim._hits and not next(registered), case .. ": no map action")
		return
	end
	local id, expiry = next(registered)
	check(not flags.ret_value and #(victim._hits or {}) == 1, case .. ": one lethal hit")
	check(id == 600 and expiry == 30 and not next(registered, id), case .. ": one fresh registration in stock save state")
	victim._alive = false
	host._pos = vec(0, 0, 0)
	if split then
		M.add(make_obj(501, 101, 0, 0)) -- still represented locally while its player is away
		witness._sees = { [600] = true, [501] = true }
		M.fire("npc_on_update", witness)
		check(not witness._hits and registered[600] == expiry, case .. ": an away player cannot trigger suspicion")
	end
	witness._sees = { [600] = true, [500] = true }
	M.fire("npc_on_update", witness)
	if set == "none" then check(not witness._hits, case .. ": stock still requires the witness to see the actor") end
	if local_killer then
		host._pos = vec(101, 0, 0)
		witness._sees[0] = true
	end
	M.fire("npc_on_update", witness)
	local hits = witness._hits or {}
	check(#hits == 1 and hits[1].draftsman:id() == (set == "none" and 0 or 500) and hits[1].power == 0,
		case .. ": one suspicion reaction against the visible player")
	check(not next(registered), case .. ": reaction consumes the only record")
end

local function phantoms_case(set, scenario)
	local away = scenario == "split maps" or scenario == "empty map"
	local present = scenario ~= "empty map"
	local M, E = boot(set, { [0] = 0, [1] = 500, [2] = 501 }, away and {
		where = function(peer) return present and peer == 1 and "here" or "away" end,
	} or nil)
	local actor = E.db.actor
	if present then M.add(make_obj(500, 100, 0, 0)) end
	if set ~= "none" then M.add(make_obj(501, 200, 0, 0)) end
	E.math = setmetatable({ random = function(_, max) return max or 1 end }, { __index = math })
	local psy_table = { actor_psy_health = (not present or set == "srv_world") and 0 or 1 }
	E.arszi_psy = { get_ppe_intensity = function() return (1 - psy_table.actor_psy_health) * 0.5 end }
	E.coop_economy_mdata = {
		player_value = function(id) return { actor_psy_health = id == 500 and 0.8 or 1 } end,
	}
	local calls, released = {}, {}
	E.alife_object = function(id) return id == 88 and { online = false } or nil end
	E.alife_release_id = function(id) released[#released + 1] = id end
	local xcv = mod(E, gamma, "xcv_phantoms")
	mod(E, gamma, "xcv_phantoms_fix")
	local replacement = xcv.actor_on_update
	local source = debug.getinfo(replacement, "S").source
	check(source == "@" .. gamma .. "xcv_phantoms_fix.script" and E.coop_route.script_of(replacement) == "xcv_phantoms_fix",
		set .. "/" .. scenario .. ": the native script key comes from the actual override")
	xcv.spawn_xphantoms = function()
		calls[#calls + 1] = { id = E.db.actor:id(), x = E.db.actor:position().x }
	end
	if scenario == "rotation only" then
		-- Isolate route selection from the independent missing-locals error.
		xcv.phantom_frequency, xcv.phantoms_appear_at, xcv.spawned_phantoms = 10, 75, {}
	end
	xcv.on_game_start()
	local applied = {}
	load_script(M, "coop_npc_phantoms").install(E.coop_npc_players, applied)
	local label = set .. "/" .. scenario
	local routed = E.coop_route.handlers_of("actor_on_update", "xcv_phantoms_fix")
	check(#routed == 1 and routed[1] == xcv.actor_on_update, label .. ": one handler keeps the override's route")
	local function tick(delta)
		NOW = NOW + delta
		return pcall(M.fire, "actor_on_update")
	end
	if set == "none" then
		local ok, err = tick(1)
		check(not ok and tostring(err):find("phantom_frequency", 1, true) and #calls == 0,
			label .. ": single player retains the vendor callback and its original missing-field error")
		return
	end
	if set == "hostplay" then
		local ok = tick(1)
		check(ok and #calls == 0, label .. ": healthy host runs the first roll")
	end
	local ok, err = tick(10000)
	if scenario == "empty map" or set == "srv_world" then
		check(ok and #calls == 0 and not M.timers, label .. ": no callback effects for the ghost or another map")
		return
	end
	check(ok and #calls == 1 and calls[1].id == 500 and calls[1].x == 100,
		label .. ": the override rolls and spawns at the client with low psy health")
	if not ok or #calls ~= 1 or calls[1].id ~= 500 or calls[1].x ~= 100 then
		print("    spawn count", #calls, "actor", calls[1] and calls[1].id, "turn",
			E.coop_route._rotate_turn("xcv_phantoms_fix"), "error", err, "adapters", table.concat(applied, ","))
		for _, line in ipairs(M.log) do print(line) end
	end
	check(E.db.actor:id() == actor:id(), label .. ": player scope is restored")
	if scenario ~= "rotation only" then
		ok = tick(1)
		check(ok and #calls == 1, label .. ": the shared cooldown prevents another spawn")
		local timer = M.timers and M.timers[#M.timers]
		xcv.load_state({ spawned_phantoms = { [88] = true } })
		ok = timer and pcall(timer.f)
		check(ok and #released == 1 and released[1] == 88,
			label .. ": deferred cleanup reads the current private squad table after load")
	end
end

-- Regression 1 (build 57): the stand's xcv_phantoms is unlocalized, its settings are module fields. The override must run
-- as in build 56 in every process kind: no "cannot resolve" report, and in a session the roll still happens.
local function unlocalized_case(set)
	local M, E = boot(set, { [0] = 0, [1] = 500, [2] = 501 })
	M.add(make_obj(500, 100, 0, 0))
	if set ~= "none" then M.add(make_obj(501, 200, 0, 0)) end
	E.math = setmetatable({ random = function(_, max) return max or 1 end }, { __index = math })
	local psy_table = { actor_psy_health = set == "srv_world" and 0 or 1 }
	E.arszi_psy = { get_ppe_intensity = function() return (1 - psy_table.actor_psy_health) * 0.5 end }
	E.coop_economy_mdata = {
		player_value = function(id) return { actor_psy_health = id == 500 and 0.8 or 1 } end,
	}
	local calls = {}
	E.alife_object = function() return nil end
	E.alife_release_id = function() end
	local xcv = mod(E, gamma, "xcv_phantoms", unlocalize)
	mod(E, gamma, "xcv_phantoms_fix")
	local label = set .. "/unlocalized"
	check(type(rawget(xcv, "phantom_frequency")) == "number" and type(rawget(xcv, "spawned_phantoms")) == "table",
		label .. ": the settings are module fields, as the engine loads them")
	xcv.spawn_xphantoms = function()
		calls[#calls + 1] = { id = E.db.actor:id(), x = E.db.actor:position().x }
	end
	xcv.on_game_start()
	local applied = {}
	load_script(M, "coop_npc_phantoms").install(E.coop_npc_players, applied)
	local warned = false
	for _, line in ipairs(M.log) do
		if tostring(line):find("cannot resolve private XCV spawn settings", 1, true) then warned = true end
	end
	check(not warned, label .. ": no unresolved-settings report")
	local function tick(delta)
		NOW = NOW + delta
		return pcall(M.fire, "actor_on_update")
	end
	if set == "none" or set == "srv_world" then
		local ok = tick(10000)
		check(ok and #calls == 0, label .. ": the override runs without error and spawns nothing here")
		return
	end
	if set == "hostplay" then tick(1) end
	local ok = tick(10000)
	check(ok and #calls == 1 and calls[1].id == 500 and calls[1].x == 100,
		label .. ": the override rolls and spawns at the client with low psy health")
end

for _, set in ipairs(modes.names()) do
	unlocalized_case(set)
	if set == "hostplay" then
		silent_case(set, true)
		silent_case(set, false)
		phantoms_case(set, "rotation only")
		phantoms_case(set, "private parameters")
	elseif set == "srv_map" then
		silent_case(set, false)
		silent_case(set, false, true)
		phantoms_case(set, "same map")
		phantoms_case(set, "split maps")
		phantoms_case(set, "empty map")
	elseif set == "srv_world" then
		silent_case(set, false)
		phantoms_case(set, "world process")
	else
		silent_case(set, true)
		phantoms_case(set, "single player")
	end
end

print(string.format("\n%d passed, %d failed", PASSES, FAILS))
