-- Anomaly Coop W10 (not shipped): stub run of gamedata\scripts\coop_client_binders.script with fake binder classes.
-- Run: tools\test_lua.cmd binders
local SRC = "gamedata/scripts/coop_client_binders.script"

local PASS, FAIL = 0, 0
local function check(cond, what)
	if cond then PASS = PASS + 1 else FAIL = FAIL + 1 print("  FAIL " .. what) end
end

-- one world = one Lua state of the game: engine globals + script modules
local function new_world(role, opts)
	opts = opts or {}
	local W = { logs = {}, calls = {}, role = role }
	local function count(k) W.calls[k] = (W.calls[k] or 0) + 1 end
	W.count = count

	local api
	if role ~= "noapi" then
		api = {
			is_client = function() return W.role == "client" end,
			is_host = function() return W.role == "host" end,
			is_active = function() return W.role ~= "single" end,
			is_live = function() return W.role == "client" or W.role == "host" end,
		}
	end

	local G = {}
	G._G = G
	G.coop = api
	G.printf = function(fmt, ...) W.logs[#W.logs + 1] = string.format(fmt, ...) end
	G.string, G.table, G.math, G.type, G.tostring, G.pairs, G.ipairs, G.pcall = string, table, math, type, tostring, pairs, ipairs, pcall
	G.rawget, G.rawequal, G.setmetatable, G.getmetatable, G.error, G.select, G.unpack = rawget, rawequal, setmetatable, getmetatable, error, select, unpack
	G.time_global = function() return 1000 end

	-- the engine's base class: object_binder.update is the C++ default
	G.object_binder = { update = function(self, delta) count("base_update") self.base_updated = (self.base_updated or 0) + 1 end }

	-- luabind-like class: methods live in the class table, `class "d" (base)` copies the base table
	local function class(t) t.__index = t return t end
	local function derive(base, t)
		local c = {}
		for k, v in pairs(base) do c[k] = v end
		for k, v in pairs(t) do c[k] = v end
		return class(c)
	end
	W.class, W.derive = class, derive
	local function new(cls) return setmetatable({ object = {} }, cls) end
	W.new = new

	local MODS = {}
	W.MODS = MODS
	setmetatable(G, { __index = function(_, k) return MODS[k] end })

	-- stock-like modules
	local function simple(name, cname, extra)
		local c = class(extra or {})
		MODS[name] = { [cname] = c }
		return c
	end
	W.faction = simple("bind_faction", "faction_binder", { update = function(self, d) count("faction.update") return 42 end })
	W.camp = simple("bind_camp", "camp_binder", { update = function(self, d) count("camp.update") end })
	W.heli = simple("bind_heli", "heli_binder", { update = function(self, d) count("heli.update") end })
	W.zone = class({
		update = function(self, d) count("zone.update") end,
		spawn_artefact_randomly = function(self) count("zone.spawn") return "spawned" end,
		turn_off = function(self) count("zone.turn_off") end,
		refresh = function(self) self:spawn_artefact_randomly() end,
	})
	MODS.bind_anomaly_zone = { anomaly_zone_binder = W.zone }
	W.box = class({ spawn_items = function(self, obj, who) count("box.spawn_items") return "loot" end })
	MODS.xr_box = { ph_item_box = W.box }
	W.crow = class({ update = function(self, d)
		count("crow.update")
		if self.body_timer ~= 0 and self.body_timer <= 1000 - 120000 then count("crow.release") end
	end })
	MODS.bind_crow = { crow_binder = W.crow }

	-- guarded classes: one that throws, the rest fine; some modules absent on purpose
	W.guard = {}
	local function guarded(mod, cname, bad)
		local c = class({ update = function(self, d)
			count(mod .. ".update")
			if bad then error(bad, 0) end
			return "stock"
		end })
		MODS[mod] = { [cname] = c }
		W.guard[mod] = c
		return c
	end
	guarded("bind_stalker", "actor_binder", "boom in actor update")
	guarded("bind_restrictor", "restrictor_binder")
	guarded("bind_physic_object", "generic_physics_binder")
	guarded("bind_item", "item_binder")
	guarded("item_artefact", "artefact_binder")
	-- absent: bind_car, bind_door_labx8, bind_red_forest_bridge, bind_signal_light, bind_dynamic_light,
	--         bind_dynamo_hand, gwr_worldweapon_binder, item_device
	-- a class without update (the method is simply not there)
	MODS.bind_container = { container_binder = class({ net_spawn = function() end }) }

	-- creature binders: update is the engine's business, death_callback is ours
	MODS.xr_motivator = { motivator_binder = class({
		update = function(self) count("motivator.update") end,
		death_callback = function(self, victim, who) count("motivator.death") error("nil who", 0) end,
		use_callback = function(self, obj, who) count("motivator.use") return "used" end,
	}) }
	W.motivator = MODS.xr_motivator.motivator_binder
	MODS.bind_monster = { generic_object_binder = class({
		death_callback = function(self, victim, who) count("monster.death") return "dead" end,
	}) }
	W.monster = MODS.bind_monster.generic_object_binder

	-- coop_main with the status list
	MODS.coop_main = { print_status = function() count("main.print_status") W.logs[#W.logs + 1] = "[coop-lua] main status" end }

	if opts.ltx then
		G.ini_file = function(name)
			if name ~= "coop_domains_binders.ltx" then error("no such file " .. name) end
			local sec = opts.ltx
			local ini = {}
			function ini:section_exist(s) return sec[s] ~= nil end
			function ini:line_count(s) return #sec[s] end
			function ini:r_line(s, i, a, b) local l = sec[s][i + 1] return true, l[1], l[2] or "" end
			return ini
		end
	else
		G.ini_file = function() error("ini not available") end
	end

	-- load the script as a module (env falls through to the engine globals)
	local fh = io.open(SRC, "rb")
	local f = assert(loadstring(fh:read("*a"), "@coop_client_binders.script"))
	fh:close()
	local env = setmetatable({}, { __index = G })
	setfenv(f, env)
	f()
	MODS.coop_client_binders = env
	W.mod = env
	W.G = G
	return W
end

local function logs_with(W, pat)
	local n = 0
	for _, l in ipairs(W.logs) do if l:find(pat, 1, true) then n = n + 1 end end
	return n
end

-------------------------------------------------------------------------------
print("== 1. client: patches land, behaviour")
do
	local W = new_world("client")
	local f0, c0, h0 = W.faction.update, W.camp.update, W.heli.update
	local z0, t0, b0, cr0 = W.zone.spawn_artefact_randomly, W.zone.turn_off, W.box.spawn_items, W.crow.update
	local n = W.mod.install()
	check(n > 0, "install returns the number of patches on a client: " .. tostring(n))
	check(W.faction.update ~= f0 and W.camp.update ~= c0 and W.heli.update ~= h0, "host-only update replaced")
	check(W.zone.spawn_artefact_randomly ~= z0 and W.zone.turn_off ~= t0, "anomaly zone methods replaced")
	check(W.box.spawn_items ~= b0, "xr_box spawn_items replaced")
	check(W.crow.update ~= cr0, "crow update replaced")

	-- host-only: the stock update does not run, the base update does, once
	local inst = W.new(W.faction)
	W.calls = {}
	W.faction.update(inst, 100)
	check(not W.calls["faction.update"] and W.calls.base_update == 1 and inst.base_updated == 1, "faction: stock update skipped, object_binder.update ran once")
	W.calls = {}
	W.new(W.camp):update(100)
	W.new(W.heli):update(100)
	check(not W.calls["camp.update"] and not W.calls["heli.update"] and W.calls.base_update == 2, "camp + heli: skipped (method call on an instance too)")

	-- partial: artefact spawn and release are no-ops, refresh (which calls spawn) is harmless
	W.calls = {}
	local zi = W.new(W.zone)
	local r = zi:spawn_artefact_randomly()
	zi:turn_off()
	zi:refresh()
	check(r == nil and not W.calls["zone.spawn"] and not W.calls["zone.turn_off"], "zone: spawn / turn_off do nothing on a client, refresh through the class too")
	zi:update(1)
	check(W.calls["zone.update"] == 1, "zone: update itself still stock")
	W.calls = {}
	local bx = W.new(W.box):spawn_items({}, {})
	check(bx == nil and not W.calls["box.spawn_items"], "xr_box: spawn_items skipped on a client")

	-- crow: a dead crow is not released by the client; the timer is reset
	local cw = W.new(W.crow)
	cw.body_timer = 5
	W.calls = {}
	cw:update(1)
	check(W.calls["crow.update"] == 1 and not W.calls["crow.release"] and cw.body_timer == 0, "crow: no release on a client")

	-- guard: errors are caught, counted, throttled
	local ai = W.new(W.guard.bind_stalker)
	local ok, err = pcall(function() ai:update(1) end)
	check(ok, "guard: the Lua error does not reach the engine: " .. tostring(err))
	check(W.mod._state().errors["bind_stalker.actor_binder:update"] == 1, "guard: counted")
	for i = 2, 205 do ai:update(1) end
	check(W.mod._state().errors["bind_stalker.actor_binder:update"] == 205, "guard: 205 errors counted")
	check(logs_with(W, "lua error in bind_stalker.actor_binder:update") == 5, "guard: logged #1-3, #100, #200 only (got " .. logs_with(W, "lua error in bind_stalker") .. ")")
	local it = W.new(W.guard.bind_item)
	W.calls = {}
	it:update(1)
	check(W.calls["bind_item.update"] == 1, "guard: a healthy update runs the stock code once")

	-- creature binders: the update is not touched, the callbacks are guarded on a client
	W.calls = {}
	local mi = W.new(W.motivator)
	mi:update(1)
	check(W.calls["motivator.update"] == 1, "creature binder: update untouched (the engine suspends it)")
	local okd, errd = pcall(function() mi:death_callback({}, {}) end)
	check(okd and W.mod._state().errors["xr_motivator.motivator_binder:death_callback"] == 1, "creature binder: a Lua error in death_callback is caught on a client: " .. tostring(errd))
	check(mi:use_callback({}, {}) == nil and W.calls["motivator.use"] == 1, "creature binder: use_callback runs inside the guard")
	W.calls = {}
	W.new(W.monster):death_callback({}, {})
	check(W.calls["monster.death"] == 1, "monster binder: death_callback runs once through the guard")

	-- absent classes are tolerated and listed
	local st = W.mod._state()
	local absent = table.concat(st.absent, ",")
	check(absent:find("bind_car.car_binder", 1, true) and absent:find("gwr_worldweapon_binder.gwr_wpn_m98_binder", 1, true), "absent mods listed: " .. absent)
	check(absent:find("bind_container.container_binder:update", 1, true), "class without update listed as such")

	-- idempotent
	local upd = W.camp.update
	check(W.mod.install() == n and W.camp.update == upd, "install twice: no double wrapping")

	-- status: coop_main.print_status now prints our block once
	W.logs = {}
	W.MODS.coop_main.print_status()
	check(logs_with(W, "[coop-binders] role client") == 1, "status: our summary line printed once through coop_main.print_status")
	check(logs_with(W, "main status") == 1, "status: coop_main's own lines still printed")
	-- coop_main later lists this module in STATUS_MODULES: still once
	W.logs = {}
	local hooked = W.MODS.coop_main.print_status
	W.MODS.coop_main.print_status = function() W.mod.print_status() end -- as the new prev would
	W.MODS.coop_main.print_status = hooked
	W.mod.print_status()
	check(logs_with(W, "[coop-binders] role client") == 1, "status: a direct call prints once")

	-- the session ends: the wrappers go back to the stock behaviour
	W.role = "single"
	W.calls = {}
	local rv = W.new(W.faction):update(1)
	check(W.calls["faction.update"] == 1 and rv == 42, "after the session: stock update, stock return value")
	W.new(W.zone):spawn_artefact_randomly()
	check(W.calls["zone.spawn"] == 1, "after the session: artefact spawn is stock")
	local ok2 = pcall(function() W.new(W.guard.bind_stalker):update(1) end)
	check(not ok2, "after the session: no guard, the error propagates as in the stock game")
	local ok3 = pcall(function() W.new(W.motivator):death_callback({}, {}) end)
	check(not ok3 and W.new(W.monster):death_callback({}, {}) == "dead", "after the session: creature callbacks are stock (error propagates, value returned)")
end

-------------------------------------------------------------------------------
print("== 1b. status hook with a coop_main that already lists the module")
do
	local W = new_world("client")
	-- coop_main.print_status prints every module of STATUS_MODULES, ours included
	W.MODS.coop_main.print_status = function() W.mod.print_status() end
	W.mod.install()
	W.logs = {}
	W.MODS.coop_main.print_status()
	check(logs_with(W, "[coop-binders] role client") == 1, "status: listed in STATUS_MODULES and hooked -> still one block (" .. logs_with(W, "[coop-binders] role client") .. ")")
end

-------------------------------------------------------------------------------
print("== 2. host and single player and an exe without co-op: nothing is patched")
for _, role in ipairs({ "host", "single", "noapi" }) do
	local W = new_world(role)
	local snapshot = {}
	for _, m in pairs(W.MODS) do
		if type(m) == "table" then
			for _, c in pairs(m) do
				if type(c) == "table" then
					for mk, mv in pairs(c) do if type(mv) == "function" then snapshot[#snapshot + 1] = { c, mk, mv } end end
				end
			end
		end
	end
	local before = #W.logs
	local n = W.mod.install()
	check(n == 0, role .. ": install returns 0")
	local changed = 0
	for _, s in ipairs(snapshot) do if s[1][s[2]] ~= s[3] then changed = changed + 1 end end
	check(changed == 0, role .. ": no class method replaced (" .. changed .. ")")
	check(#W.logs == before, role .. ": silent")
	W.calls = {}
	local rv = W.new(W.faction):update(1)
	check(rv == 42 and W.calls["faction.update"] == 1, role .. ": faction update stays stock")
	check(not W.mod._state().installed, role .. ": not marked installed (a later client session may install)")
end

-------------------------------------------------------------------------------
print("== 3. a client whose role changes: host after install runs stock")
do
	local W = new_world("client")
	W.mod.install()
	W.role = "host"
	W.calls = {}
	local rv = W.new(W.faction):update(1)
	check(rv == 42 and W.calls["faction.update"] == 1 and not W.calls.base_update, "host: faction update stock, base not called")
	W.new(W.box):spawn_items({}, {})
	check(W.calls["box.spawn_items"] == 1, "host: box loot stock")
	local ok = pcall(function() W.new(W.guard.bind_stalker):update(1) end)
	check(not ok, "host: the guard is off, a Lua error is the stock error")
end

-------------------------------------------------------------------------------
print("== 4. configs\\coop_domains_binders.ltx for mods")
do
	local W = new_world("client", { ltx = {
		host_update = { { "bind_mod.mod_binder" }, { "bind_gone.gone_binder" } },
		skip_methods = { { "bind_mod.mod_binder", "spawn_loot, release_all" } },
		guard_update = { { "bind_mod.other_binder" }, { "not a ref" } },
	} })
	local c = W.class({ update = function(self) W.count("mod.update") end, spawn_loot = function() W.count("mod.spawn") end,
		release_all = function() W.count("mod.release") end })
	local o = W.class({ update = function(self) error("mod fail", 0) end })
	W.MODS.bind_mod = { mod_binder = c, other_binder = o }
	W.mod.install()
	W.calls = {}
	local i = W.new(c)
	i:update(1)
	i:spawn_loot()
	i:release_all()
	check(not W.calls["mod.update"] and not W.calls["mod.spawn"] and not W.calls["mod.release"] and W.calls.base_update == 1, "ltx: host_update + skip_methods applied to a mod class")
	local ok = pcall(function() W.new(o):update(1) end)
	check(ok and W.mod._state().errors["bind_mod.other_binder:update"] == 1, "ltx: guard_update applied")
	check(table.concat(W.mod._state().absent, ","):find("bind_gone.gone_binder", 1, true) ~= nil, "ltx: absent mod class listed")

	-- an ltx that fails to read costs nothing
	local W2 = new_world("client")
	check(W2.mod.install() > 0, "no ltx: built-in policy still installed")
	local W3 = new_world("client", { ltx = { host_update = { { "bind_faction.faction_binder" } } } })
	W3.mod.install()
	W3.calls = {}
	W3.new(W3.faction):update(1)
	check(not W3.calls["faction.update"] and W3.calls.base_update == 1, "ltx duplicate of a built-in entry: wrapped once (base ran once)")
end

-------------------------------------------------------------------------------
print("== 5. derive copy (luabind class_rep): a subclass declared before the patch keeps the old method")
do
	local W = new_world("client")
	local sub = W.derive(W.faction, {})
	W.mod.install()
	W.calls = {}
	W.new(sub):update(1)
	check(W.calls["faction.update"] == 1, "subclass declared before the patch keeps a copy of the stock method (documented limit)")
	local late = W.derive(W.faction, {})
	W.calls = {}
	W.new(late):update(1)
	check(not W.calls["faction.update"], "subclass declared after the patch gets the patched method")
end

print(string.format("\nW10 client binders stub run: %d passed, %d failed", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
