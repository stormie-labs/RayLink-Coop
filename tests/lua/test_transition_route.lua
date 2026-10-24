-- Anomaly Coop, the stock route exits in a session with company (scripts\coop_transition_route.script, live test 2026-10-24:
-- "why does everything get darker when ONE player walks up; the second one is teleported to the first one"). A route
-- restrictor of sr_teleport_sections.ltx whose drop point lies in a level changer is that changer's exit while the player
-- stands in it: no fade, no teleport (ui_sr_teleport.msg_box_ui:OnMsgOk is left out), the engine learns the pair
-- (coop.transition_route) and its board counts him there. Alone, outside a session, a route inside the level, an unknown
-- route: the stock behaviour. The player's own machine also notices an entry the restrictor's logic does not fire (it fires
-- once for the group: a second player who walks in while the first stands there).
-- Engine stand-ins: coop.transition_route (a changer id when the group waits here and the point is in a changer), db.zone_by_name,
-- ini_file / patrol, txr_routes / mlr_utils / alife_storage_manager, the class ui_sr_teleport.msg_box_ui (its OnMsgOk records
-- the fade and the teleport). Run: tools\test_lua.cmd transition_route   (VERBOSE=1 for logs)
local ROOT = "gamedata/"

FAILS, PASSES = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local function readfile(p)
	local fh = io.open(p, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

-- ---------------------------------------------------------------- the route sections (as sr_teleport_sections.ltx)
local SECTIONS = {
	mar_space_restrictor_to_agroprom_1 = { path = "mar_space_restrictor_to_agroprom_drop", autosave = "true" },
	esc_space_restrictor_to_garbage_1 = { position = "120.5, 3.25, -44,1.57" },
	mar_teleport_from_base_to_north = { path = "mar_smart_terrain_5_12_teleport_walk" }, -- a route inside the level
	mar_broken_route = { hint = "nothing to go to" },
}
local PATROLS = {
	mar_space_restrictor_to_agroprom_drop = { x = 171.0, y = 7.5, z = 612.0 },
	mar_smart_terrain_5_12_teleport_walk = { x = -40.0, y = 1.0, z = 10.0 },
}

-- ---------------------------------------------------------------- one machine
local NOW = 100000
local function machine(opts)
	opts = opts or {}
	local M = { log = {}, cb = {}, asked = {}, scanned = {}, fx = {}, opened = opts.opened or false, active = opts.active ~= false,
		company = opts.company ~= false, known = opts.known or {}, defaults = opts.defaults or {}, errors = 0 }
	local env = setmetatable({}, { __index = function(_, k)
		local v = _G[k]
		if v == nil then
			UNKNOWN = UNKNOWN or {}
			UNKNOWN[k] = true
		end
		return v
	end })
	env._G = env
	M.env = env
	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if os.getenv("VERBOSE") then print("    " .. line) end
	end
	env.time_global = function() return NOW end
	env.RegisterScriptCallback = function(name, f)
		M.cb[name] = M.cb[name] or {}
		table.insert(M.cb[name], f)
	end
	-- the restrictors of the level, and where the actor is
	M.actor_at = { x = 0, y = 0, z = 0 }
	env.db = { actor = { position = function() return M.actor_at end }, zone_by_name = {} }
	function M.zone(id, name, box)
		local z = { box = box }
		function z:id() return id end
		function z:name() return name end
		function z:inside(p)
			if self.broken then error("the object is gone") end
			local b = self.box
			return p.x >= b[1] and p.x <= b[2] and p.z >= b[3] and p.z <= b[4]
		end
		env.db.zone_by_name[name] = z
		return z
	end
	env.get_object_story_id = function(id) return (opts.story or {})[id] end
	-- the stock data
	env.ini_file = function(file)
		M.ini_file = file
		local ini = {}
		function ini:section_exist(s) return SECTIONS[s] ~= nil end
		function ini:r_string_ex(s, k) return SECTIONS[s] and SECTIONS[s][k] or nil end
		return ini
	end
	env.patrol = function(name)
		local p = PATROLS[name]
		if not p then error("no such patrol path " .. tostring(name)) end
		return { point = function(_, i) return p end }
	end
	env.alife_storage_manager = { get_state = function() return { opened_routes = M.opened } end }
	env.txr_routes = { scan_route = function(name)
		M.scanned[#M.scanned + 1] = name
		return M.defaults[name] == true
	end }
	env.mlr_utils = { load_var = function(key) return M.known[(key:gsub("^routes_", ""))] end }
	-- the stock class: OnMsgOk fades the screen and moves the actor 3 s later
	local cls = {}
	cls.__index = cls
	function cls:OnMsgOk()
		M.fx[#M.fx + 1] = { what = "fade+teleport", name = self.name }
	end
	M.stock_ok = cls.OnMsgOk
	M.cls = cls
	env.ui_sr_teleport = { msg_box_ui = cls }
	-- the engine
	if opts.coop ~= false then
		env.coop = {
			is_active = function() return M.active end,
			transition_route = function(id, x, y, z)
				M.asked[#M.asked + 1] = { id = id, x = x, y = y, z = z }
				if M.engine_error then error("the engine is gone") end
				if not (M.active and M.company) then return nil end -- alone, single player: the stock route
				-- a changer around the agroprom drop and the garbage position; nothing at the base's walk (inside the level)
				if math.abs(x - 171.0) < 0.01 and math.abs(z - 612.0) < 0.01 then return 16600 end
				if math.abs(x - 120.5) < 0.01 and math.abs(z + 44) < 0.01 then return 16610 end
				return nil
			end,
		}
	end
	local src = readfile(ROOT .. "scripts/coop_transition_route.script")
	local mod = setmetatable({}, { __index = env })
	env.coop_transition_route = mod
	if src then
		local f, err = loadstring(src, "@coop_transition_route.script")
		if f then
			setfenv(f, mod)
			local ok, e = pcall(f)
			if not ok then print("  load error: " .. tostring(e)) end
		else
			print("  syntax error: " .. tostring(err))
		end
	else
		print("  the script is missing")
	end
	M.R = mod
	if rawget(mod, "on_game_start") then
		local ok, e = pcall(mod.on_game_start)
		if not ok then print("  on_game_start: " .. tostring(e)) end
	end
	return M
end

-- The stock effect on this machine: sr_teleport -> ui_sr_teleport.msg_box_ui(npc): __init names the route and, for a known
-- one, calls OnMsgOk (G.A.M.M.A.'s copy; stock Anomaly asks yes/no first).
local function walk_in(M, obj, name)
	local box = setmetatable({ obj = obj, name = name }, M.cls)
	box:OnMsgOk()
end

local function frames(M, ms)
	local t_end = NOW + (ms or 0)
	repeat
		for _, f in ipairs(M.cb.actor_on_update or {}) do f() end
		NOW = NOW + 16
	until NOW >= t_end
end

-- ================================================================ 1. the hook
print("== the hook")
local M = machine()
check(M.cls.OnMsgOk ~= M.stock_ok, "on_game_start wraps ui_sr_teleport.msg_box_ui.OnMsgOk")
check(M.ini_file == nil or M.ini_file == "sr_teleport_sections.ltx", "the route sections are the stock file")
local mar = M.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 })
walk_in(M, mar, "mar_space_restrictor_to_agroprom_1")
check(#M.fx == 0, "in a session with company: no fade, no teleport (the second player is not put on the first)")
check(#M.asked == 1 and M.asked[1].id == 812 and M.asked[1].x == 171.0 and M.asked[1].y == 7.5 and M.asked[1].z == 612.0,
	"the engine is asked with the restrictor and the first point of the route's path (its drop point)")
local esc = M.zone(901, "esc_space_restrictor_to_garbage_1", { 0, 10, 0, 10 })
walk_in(M, esc, "esc_space_restrictor_to_garbage_1")
check(#M.fx == 0 and M.asked[2] and M.asked[2].x == 120.5 and M.asked[2].y == 3.25 and M.asked[2].z == -44,
	"a route by position \"x, y, z, dir\": the same, the point parsed")
local base = M.zone(905, "mar_teleport_from_base_to_north", { 0, 1, 0, 1 })
walk_in(M, base, "mar_teleport_from_base_to_north")
check(#M.fx == 1 and M.fx[1].name == "mar_teleport_from_base_to_north", "a route inside the level (no changer at its point): the stock fade and teleport")
local broken = M.zone(906, "mar_broken_route", { 0, 1, 0, 1 })
walk_in(M, broken, "mar_broken_route")
check(#M.fx == 2 and #M.asked == 3, "a route with no drop point: stock, the engine is not asked")
walk_in(M, nil, nil)
check(#M.fx == 3, "no restrictor object: stock")

-- alone, outside a session, without the engine
local MA = machine({ company = false })
walk_in(MA, MA.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 }), "mar_space_restrictor_to_agroprom_1")
check(#MA.fx == 1, "the host alone (the engine says nil): the stock route, fade and teleport")
local MS = machine({ active = false })
walk_in(MS, MS.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 }), "mar_space_restrictor_to_agroprom_1")
check(#MS.fx == 1, "single player: stock")
local MX = machine({ coop = false })
check(MX.cls.OnMsgOk == MX.stock_ok, "an exe without co-op: nothing is wrapped")
walk_in(MX, MX.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 }), "mar_space_restrictor_to_agroprom_1")
check(#MX.fx == 1, "... and the route is the stock one")
local ME = machine()
ME.engine_error = true
walk_in(ME, ME.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 }), "mar_space_restrictor_to_agroprom_1")
check(#ME.fx == 1, "the engine call fails: the stock route, nothing raises")

-- ================================================================ 2. the entry the restrictor's logic does not fire
print("== the player's own entry")
-- The restrictor's logic (on_actor_inside = sr_idle@run %=sr_teleport%) is evaluated for the group: while the first player
-- stands in it, it stays in @run and a second player's entry fires nothing. His own machine notices it.
local MB = machine({ known = { mar_space_restrictor_to_agroprom_1 = true } })
local z = MB.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 })
MB.zone(77, "some_other_restrictor", { -1000, 1000, -1000, 1000 }) -- every restrictor of the level is in db.zone_by_name
frames(MB, 1000)
check(#MB.asked == 0, "away from the route: the engine is not asked")
MB.actor_at = { x = 170, y = 7, z = 600 }
frames(MB, 600)
check(#MB.asked == 1 and MB.asked[1].id == 812 and MB.asked[1].x == 171.0, "he walks in: the engine learns the route (once a quarter second at most)")
check(#MB.fx == 0, "... no fade, no teleport")
frames(MB, 3000)
check(#MB.asked == 1, "standing in it: asked once per entry")
MB.actor_at = { x = 150, y = 7, z = 600 }
frames(MB, 600)
MB.actor_at = { x = 170, y = 7, z = 600 }
frames(MB, 600)
check(#MB.asked == 2, "out and in again: asked again (the engine forgets its routes with a world or a new session)")
-- the route's knowledge is the stock one
local MU = machine()
MU.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 })
MU.actor_at = { x = 170, y = 7, z = 600 }
frames(MU, 600)
check(#MU.asked == 0, "a route this player does not know: the engine is not asked (the stock rejection is the restrictor's own)")
check(#MU.scanned == 1 and MU.scanned[1] == "mar_space_restrictor_to_agroprom_1", "... known is asked as the stock entry asks it (txr_routes.scan_route)")
local MD = machine({ defaults = { mar_space_restrictor_to_agroprom_1 = true } })
MD.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 })
MD.actor_at = { x = 170, y = 7, z = 600 }
frames(MD, 600)
check(#MD.asked == 1, "a route open by default (scan_route): known")
local MO = machine({ opened = true })
MO.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 })
MO.actor_at = { x = 170, y = 7, z = 600 }
frames(MO, 600)
check(#MO.asked == 1 and #MO.scanned == 0, "all routes opened (opened_routes): known without a scan")
-- a restrictor named by its id: its story id is the section (as msg_box_ui:__init)
local MI = machine({ known = { esc_space_restrictor_to_garbage_1 = true }, story = { [4242] = "esc_space_restrictor_to_garbage_1" } })
MI.zone(4242, "space_restrictor_4242", { 0, 10, 0, 10 })
MI.actor_at = { x = 5, y = 0, z = 5 }
frames(MI, 600)
check(#MI.asked == 1 and MI.asked[1].id == 4242 and MI.asked[1].x == 120.5, "a restrictor named by its id: its story id names the route")
-- a broken zone does not stop the others
local MK = machine({ known = { mar_space_restrictor_to_agroprom_1 = true } })
local bad = MK.zone(813, "mar_space_restrictor_to_escape_1", { 160, 180, 590, 605 })
SECTIONS.mar_space_restrictor_to_escape_1 = { path = "mar_space_restrictor_to_agroprom_drop" }
MK.known.mar_space_restrictor_to_escape_1 = true
MK.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 })
frames(MK, 6000) -- listed
bad.broken = true
MK.actor_at = { x = 170, y = 7, z = 600 }
frames(MK, 600)
local ids = {}
for _, a in ipairs(MK.asked) do ids[a.id] = true end
check(ids[812] and not ids[813], "a restrictor whose object is gone is skipped, the others still count")
SECTIONS.mar_space_restrictor_to_escape_1 = nil
-- no session: nothing scanned, nothing asked
local MN = machine({ active = false, known = { mar_space_restrictor_to_agroprom_1 = true } })
MN.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 })
MN.actor_at = { x = 170, y = 7, z = 600 }
frames(MN, 1000)
check(#MN.asked == 0 and #MN.scanned == 0, "no session: the stock world, nothing is asked")

-- ================================================================ 3. diagnostics, cost
print("== status")
M.R.print_status()
check(#M.log > 0 and M.log[#M.log]:find("route exits", 1, true) ~= nil, "print_status says what the routes did")
local MP = machine({ known = { mar_space_restrictor_to_agroprom_1 = true } })
for i = 1, 200 do MP.zone(10000 + i, "restrictor_" .. i, { 0, 1, 0, 1 }) end
MP.zone(812, "mar_space_restrictor_to_agroprom_1", { 160, 180, 590, 605 })
local t0 = os.clock()
frames(MP, 16 * 400)
local per_frame = (os.clock() - t0) * 1000 / 400
print(("  info %.4f ms per frame with 200 restrictors"):format(per_frame))
check(per_frame < 0.2, "a frame costs well under a fifth of a millisecond in the stubs (" .. string.format("%.4f", per_frame) .. " ms)")

-- ================================================================
local unk = {}
for k in pairs(UNKNOWN or {}) do unk[#unk + 1] = tostring(k) end
table.sort(unk)
check(#unk == 0, "no reads of undefined globals (" .. table.concat(unk, ", ") .. ")")
print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
