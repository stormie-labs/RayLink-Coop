-- Anomaly Coop W10 / F2 T11 (not shipped): stub run of gamedata\scripts\coop_client_binders.script with fake binder classes.
-- The engine routes the methods it calls itself (configs\coop_route_binders.ltx [binder_host] / [binder_keep], C++
-- tests routes_binder_*); this script keeps only what the engine cannot see: the Lua sections of the same ltx.
-- The stubs read the SHIPPED gamedata\configs\coop_route_binders.ltx, so the lists the game uses are the ones tested.
-- Run: tools\test_lua.cmd binders
local SRC = "gamedata/scripts/coop_client_binders.script"
local LTX = "gamedata/configs/coop_route_binders.ltx"

local PASS, FAIL = 0, 0
local function check(cond, what)
	if cond then PASS = PASS + 1 else FAIL = FAIL + 1 print("  FAIL " .. what) end
end

-- The shipped ltx as an ordered list of sections: { name = "...", lines = { { key, value }, ... } }; ';' starts a comment.
local function read_ltx(path)
	local fh = assert(io.open(path, "rb"))
	local text = fh:read("*a")
	fh:close()
	local sections, cur = {}, nil
	for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
		local line = raw:gsub(";.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" then
			local name = line:match("^%[(.-)%]$")
			if name then
				cur = { name = name, lines = {} }
				sections[#sections + 1] = cur
			elseif cur then
				local k, v = line:match("^([^=]-)%s*=%s*(.*)$")
				if k then cur.lines[#cur.lines + 1] = { k, v } else cur.lines[#cur.lines + 1] = { line, "" } end
			end
		end
	end
	return sections
end
local SHIPPED = read_ltx(LTX)

local function section_of(sections, name)
	for _, s in ipairs(sections) do if s.name == name then return s end end
	return nil
end

-- one world = one Lua state of the game: engine globals + script modules
-- opts.ltx      a list of sections (as read_ltx) instead of the shipped file
-- opts.no_ltx   ini_file raises: the file cannot be read
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

	-- stock-like modules. faction / camp / heli: their update is the ENGINE's now (binder_host), the script must not touch it.
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

	-- classes the ENGINE guards now (binder_keep): their update is not the script's business, one throws
	W.keep = {}
	local function kept(mod, cname, bad)
		local c = class({ update = function(self, d)
			count(mod .. ".update")
			if bad then error(bad, 0) end
			return "stock"
		end })
		MODS[mod] = { [cname] = c }
		W.keep[mod] = c
		return c
	end
	kept("bind_stalker", "actor_binder", "boom in actor update")
	kept("bind_restrictor", "restrictor_binder")
	kept("bind_physic_object", "generic_physics_binder")
	kept("bind_item", "item_binder")
	kept("item_artefact", "artefact_binder")
	MODS.bind_container = { container_binder = class({ net_spawn = function() end }) }

	-- creature binders: update is the engine's business, death_callback is ours
	MODS.xr_motivator = { motivator_binder = class({
		update = function(self) count("motivator.update") end,
		death_callback = function(self, victim, who) count("motivator.death") error("nil who", 0) end,
		hit_callback = function(self, obj, amount) count("motivator.hit") return "hit" end,
		use_callback = function(self, obj, who) count("motivator.use") return "used" end,
	}) }
	W.motivator = MODS.xr_motivator.motivator_binder
	MODS.bind_monster = { generic_object_binder = class({
		death_callback = function(self, victim, who) count("monster.death") return "dead" end,
		hit_callback = function(self, obj, amount) count("monster.hit") end,
		use_callback = function(self, obj, who) count("monster.use") end,
	}) }
	W.monster = MODS.bind_monster.generic_object_binder

	-- coop_main with the status list
	MODS.coop_main = { print_status = function() count("main.print_status") W.logs[#W.logs + 1] = "[coop-lua] main status" end }

	local sections = opts.ltx or SHIPPED
	if opts.no_ltx then
		G.ini_file = function() error("ini not available") end
	else
		G.ini_file = function(name)
			if name ~= "coop_route_binders.ltx" then error("no such file " .. name) end
			local ini = {}
			function ini:section_exist(s) return section_of(sections, s) ~= nil end
			function ini:line_count(s) return #section_of(sections, s).lines end
			function ini:r_line(s, i, a, b) local l = section_of(sections, s).lines[i + 1] return true, l[1], l[2] or "" end
			return ini
		end
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
print("== 0. the shipped ltx: the Lua sections")
do
	local skip, fix, guard = section_of(SHIPPED, "binder_lua_skip"), section_of(SHIPPED, "binder_lua_fix"), section_of(SHIPPED, "binder_lua_guard")
	check(skip and #skip.lines == 2 and fix and #fix.lines == 1 and guard and #guard.lines == 2, "binder_lua_skip / fix / guard are there (2 / 1 / 2 lines)")
	check(section_of(SHIPPED, "binder_host") and #section_of(SHIPPED, "binder_host").lines == 3, "binder_host (engine) has the 3 W10 host-only updates")
	check(section_of(SHIPPED, "binder_keep") and #section_of(SHIPPED, "binder_keep").lines == 15, "binder_keep (engine) has the 15 W10 guarded updates")
end

-------------------------------------------------------------------------------
print("== 1. client: Lua patches land, behaviour")
do
	local W = new_world("client")
	local f0, c0, h0 = W.faction.update, W.camp.update, W.heli.update
	local z0, t0, b0, cr0 = W.zone.spawn_artefact_randomly, W.zone.turn_off, W.box.spawn_items, W.crow.update
	local keep0 = {}
	for mod, cls in pairs(W.keep) do keep0[mod] = cls.update end
	local mu0, md0, mh0, mm0 = W.motivator.update, W.motivator.death_callback, W.motivator.hit_callback, W.monster.death_callback
	local n = W.mod.install()
	-- 3 skipped methods + 1 fix + the death / hit / use callbacks of two creature binders (6); the engine has the other 18 of the 28
	check(n == 10, "install returns the number of Lua patches on a client: " .. tostring(n))
	check(W.zone.spawn_artefact_randomly ~= z0 and W.zone.turn_off ~= t0, "anomaly zone methods replaced")
	check(W.box.spawn_items ~= b0, "xr_box spawn_items replaced")
	check(W.crow.update ~= cr0, "crow update replaced")
	check(W.motivator.death_callback ~= md0 and W.motivator.hit_callback ~= mh0 and W.monster.death_callback ~= mm0, "creature callbacks replaced")

	-- F2 T11: what the engine routes is not touched here
	check(W.faction.update == f0 and W.camp.update == c0 and W.heli.update == h0, "faction / camp / heli update: left to the engine (binder_host)")
	local untouched = true
	for mod, cls in pairs(W.keep) do if cls.update ~= keep0[mod] then untouched = false end end
	check(untouched, "update of the kept classes (actor, restrictor, item ...): left to the engine (binder_keep)")
	check(W.motivator.update == mu0, "creature binder: update untouched (the engine suspends it)")
	W.calls = {}
	W.new(W.faction):update(100)
	check(W.calls["faction.update"] == 1 and not W.calls.base_update, "faction update is the stock one in Lua (the engine decides whether to call it)")
	local ai = W.new(W.keep.bind_stalker)
	check(not pcall(function() ai:update(1) end), "a Lua error in a kept update is the engine's to keep, not caught here")

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
	check(W.mod._state().skipped["bind_anomaly_zone.anomaly_zone_binder:spawn_artefact_randomly"] == 2, "zone: skipped calls counted (direct + through refresh)")

	-- crow: a dead crow is not released by the client; the timer is reset
	local cw = W.new(W.crow)
	cw.body_timer = 5
	W.calls = {}
	cw:update(1)
	check(W.calls["crow.update"] == 1 and not W.calls["crow.release"] and cw.body_timer == 0, "crow: no release on a client")

	-- guard: the callbacks the engine reaches through set_callback are called in pcall, errors are caught, counted, throttled
	W.calls = {}
	local mi = W.new(W.motivator)
	mi:update(1)
	check(W.calls["motivator.update"] == 1, "creature binder: update runs as before")
	local okd, errd = pcall(function() mi:death_callback({}, {}) end)
	check(okd and W.mod._state().errors["xr_motivator.motivator_binder:death_callback"] == 1, "creature binder: a Lua error in death_callback is caught on a client: " .. tostring(errd))
	for i = 2, 205 do mi:death_callback({}, {}) end
	check(W.mod._state().errors["xr_motivator.motivator_binder:death_callback"] == 205, "guard: 205 errors counted")
	check(logs_with(W, "lua error in xr_motivator.motivator_binder:death_callback") == 5, "guard: logged #1-3, #100, #200 only (got " .. logs_with(W, "lua error in xr_motivator") .. ")")
	check(mi:use_callback({}, {}) == nil and W.calls["motivator.use"] == 1, "creature binder: use_callback runs inside the guard")
	mi:hit_callback({}, 5)
	check(W.calls["motivator.hit"] == 1, "creature binder: hit_callback runs inside the guard")
	W.calls = {}
	W.new(W.monster):death_callback({}, {})
	check(W.calls["monster.death"] == 1, "monster binder: death_callback runs once through the guard")

	-- absent classes are tolerated and listed (all four Lua sections name classes that exist in this stub world)
	local st = W.mod._state()
	check(#st.absent == 0, "no class of the shipped Lua sections is missing in the stub world: " .. table.concat(st.absent, ","))

	-- idempotent
	local upd = W.zone.turn_off
	check(W.mod.install() == n and W.zone.turn_off == upd, "install twice: no double wrapping")

	-- status: coop_main.print_status now prints our block once
	W.logs = {}
	W.MODS.coop_main.print_status()
	check(logs_with(W, "[coop-binders] role client") == 1, "status: our summary line printed once through coop_main.print_status")
	check(logs_with(W, "main status") == 1, "status: coop_main's own lines still printed")
	W.logs = {}
	W.mod.print_status()
	check(logs_with(W, "[coop-binders] role client") == 1, "status: a direct call prints once")

	-- the session ends: the wrappers go back to the stock behaviour
	W.role = "single"
	W.calls = {}
	W.new(W.zone):spawn_artefact_randomly()
	check(W.calls["zone.spawn"] == 1, "after the session: artefact spawn is stock")
	W.new(W.box):spawn_items({}, {})
	check(W.calls["box.spawn_items"] == 1, "after the session: box loot is stock")
	local ok3 = pcall(function() W.new(W.motivator):death_callback({}, {}) end)
	check(not ok3 and W.new(W.monster):death_callback({}, {}) == "dead", "after the session: creature callbacks are stock (error propagates, value returned)")
	local cw2 = W.new(W.crow)
	cw2.body_timer = 5
	cw2:update(1)
	check(cw2.body_timer == 5, "after the session: the crow fix is off")
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
	W.new(W.zone):spawn_artefact_randomly()
	check(W.calls["zone.spawn"] == 1, role .. ": artefact spawn stays stock")
	check(not W.mod._state().installed, role .. ": not marked installed (a later client session may install)")
end

-------------------------------------------------------------------------------
print("== 3. a client whose role changes: host after install runs stock")
do
	local W = new_world("client")
	W.mod.install()
	W.role = "host"
	W.calls = {}
	W.new(W.box):spawn_items({}, {})
	check(W.calls["box.spawn_items"] == 1, "host: box loot stock")
	W.new(W.zone):turn_off()
	check(W.calls["zone.turn_off"] == 1, "host: zone turn_off stock")
	local ok = pcall(function() W.new(W.motivator):death_callback({}, {}) end)
	check(not ok, "host: the guard is off, a Lua error is the stock error")
end

-------------------------------------------------------------------------------
print("== 4. the Lua sections for mods, and an ltx that does not read")
do
	local W = new_world("client", { ltx = {
		{ name = "binder_lua_skip", lines = {
			{ "bind_mod.mod_binder", "spawn_loot, release_all" },
			{ "bind_gone.gone_binder", "spawn_loot" },
			{ "not a ref", "update" },
			{ "bind_mod.empty_binder", "" },
		} },
		{ name = "binder_lua_guard", lines = { { "bind_mod.other_binder", "update, death_callback" } } },
		{ name = "binder_lua_fix", lines = { { "bind_mod.mod_binder", "update" }, { "bind_crow.crow_binder", "update" } } },
		-- the engine's sections are not the script's business
		{ name = "binder_host", lines = { { "bind_mod.bind", "update" } } },
	} })
	local c = W.class({ update = function(self) W.count("mod.update") end, spawn_loot = function() W.count("mod.spawn") end,
		release_all = function() W.count("mod.release") end })
	local o = W.class({ update = function(self) error("mod fail", 0) end, death_callback = function(self) error("dead fail", 0) end })
	W.MODS.bind_mod = { mod_binder = c, other_binder = o, empty_binder = W.class({ update = function() end }) }
	local n = W.mod.install()
	W.calls = {}
	local i = W.new(c)
	i:update(1)
	i:spawn_loot()
	i:release_all()
	check(W.calls["mod.update"] == 1 and not W.calls["mod.spawn"] and not W.calls["mod.release"], "ltx: [binder_lua_skip] applied to a mod class, its other methods untouched")
	local ok = pcall(function() W.new(o):death_callback() end)
	check(ok and W.mod._state().errors["bind_mod.other_binder:death_callback"] == 1, "ltx: [binder_lua_guard] applied")
	local ok2 = pcall(function() W.new(o):update(1) end)
	check(ok2 and W.mod._state().errors["bind_mod.other_binder:update"] == 1, "ltx: every method of a guarded line is guarded")
	check(table.concat(W.mod._state().absent, ","):find("bind_gone.gone_binder", 1, true) ~= nil, "ltx: absent mod class listed")
	check(logs_with(W, "'not a ref' is not script.class") == 1, "ltx: a bad key is logged")
	check(logs_with(W, "bind_mod.empty_binder has no methods") == 1, "ltx: a line without methods is logged")
	check(logs_with(W, "no built-in fix for bind_mod.mod_binder:update") == 1, "ltx: a [binder_lua_fix] line without a built-in fix is logged, not applied")
	local cw = W.new(W.crow)
	cw.body_timer = 5
	cw:update(1)
	check(cw.body_timer == 0, "ltx: the built-in crow fix named by [binder_lua_fix]")
	check(n == 5, "ltx: 2 skipped + 2 guarded + 1 fix = " .. tostring(n))

	-- an ltx without the Lua sections: nothing to do
	local W1 = new_world("client", { ltx = { { name = "binder_host", lines = { { "bind_camp.bind", "update" } } } } })
	check(W1.mod.install() == 0, "ltx without Lua sections: no patch")
	check(W1.mod._state().installed, "ltx without Lua sections: installed all the same")

	-- an ltx that cannot be read costs nothing and says so once
	local W2 = new_world("client", { no_ltx = true })
	local z0 = W2.zone.spawn_artefact_randomly
	check(W2.mod.install() == 0, "no ltx: no Lua patch (the lists live in the file)")
	check(W2.zone.spawn_artefact_randomly == z0, "no ltx: nothing replaced")
	check(logs_with(W2, "coop_route_binders.ltx not read") == 1, "no ltx: logged once")
end

-------------------------------------------------------------------------------
print("== 5. derive copy (luabind class_rep): a subclass declared before the patch keeps the old method")
do
	local W = new_world("client")
	local sub = W.derive(W.zone, {})
	W.mod.install()
	W.calls = {}
	W.new(sub):spawn_artefact_randomly()
	check(W.calls["zone.spawn"] == 1, "subclass declared before the patch keeps a copy of the stock method (documented limit)")
	local late = W.derive(W.zone, {})
	W.calls = {}
	W.new(late):spawn_artefact_randomly()
	check(not W.calls["zone.spawn"], "subclass declared after the patch gets the patched method")
end

print(string.format("\nW10 / F2 T11 client binders stub run: %d passed, %d failed", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
