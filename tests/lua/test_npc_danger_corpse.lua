-- Regression (dead-hook sweep, stand build 57): G.A.M.M.A.'s xr_danger keeps its corpse action in the file local
-- script_action_danger_corpse (xr_danger.script:620), and only the method action_danger:execute (:786) captures it.
-- action_danger is a luabind class: a userdata, which pairs() refuses (LuaJIT 2.0.4). coop_mods_core.find_local never
-- reached its methods, so the corpse rule of coop_npc_adapters (written 2026-10-27, build 40) was installed in no
-- session of any build: an NPC at the body of his squad mate killed by a player's character (a client's in Co-op,
-- anybody's in Server) never turned his squad on him. The stock action handles db.actor's kills only.
-- test_npc_native_compat's table class hid this.
-- The real script is loaded the game's way: CScriptStorage's header (local this), the unlocalizer of
-- unlocalizer_idiots.ltx (support\unlocalize.lua) and luabind's Lua classes as the engine's luabind builds them.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
local unlocalize = dofile("tests/lua/support/unlocalize.lua")
local AVATARS = { [0] = 0, [1] = 500, [2] = 501 }
local NAME = "script_action_danger_corpse"

local function readable(path)
	local fh = io.open(path, "rb")
	if fh then fh:close() end
	return fh ~= nil
end

-- The profile's xr_danger: the review corpus (merged by MO2 priority), else the stand the tests read (tools\test_lua.cmd).
local function gamma_script(file)
	local dirs = { "temp/review/corpus/merged/" }
	if os.getenv("GAMMA_SCRIPTS") then dirs[#dirs + 1] = os.getenv("GAMMA_SCRIPTS") .. "/" end
	dirs[#dirs + 1] = "E:/RayLinkGames/GAMMA/game-dev/gamedata/scripts/"
	for _, dir in ipairs(dirs) do
		if readable(dir .. file) then return dir .. file end
	end
	error("real G.A.M.M.A. " .. file .. " required (temp/review/corpus/merged or GAMMA_SCRIPTS)")
end

-- luabind's Lua classes (engine\src\3rd party\luabind\luabind\src\create_class.cpp, class_rep.cpp). A class is a userdata.
-- Reading a member gives the class' default table entry, a name it lacks raises "no static" (static_class_gettable);
-- writing one sets both tables (lua_settable_dispatcher); `class "x" (base)` copies the base's members (stage2); the
-- class goes to the caller's local `this` (the module), else to the globals (stage1). Calling a class makes an instance,
-- a userdata that reads its own table, then the class table (lua_class_gettable), and runs __init with a global super.
local function luabind(E)
	local reps = setmetatable({}, { __mode = "k" })
	local function rep(name, members)
		local p = newproxy(true)
		local c = { table = {}, default = {} }
		for k, v in pairs(members or {}) do c.table[k], c.default[k] = v, v end
		reps[p] = c
		local mt = getmetatable(p)
		mt.__index = function(_, k)
			local v = c.default[k]
			if v ~= nil then return v end
			error("no static '" .. tostring(k) .. "' in class '" .. name .. "'", 2)
		end
		mt.__newindex = function(_, k, v) c.table[k], c.default[k] = v, v end
		mt.__call = function(_, ...)
			local own = {}
			local obj = newproxy(true)
			local omt = getmetatable(obj)
			omt.__index = function(_, k)
				local v = own[k]
				if v == nil then v = c.table[k] end
				return v
			end
			omt.__newindex = function(_, k, v) own[k] = v end
			assert(type(c.table.__init) == "function", name .. ":__init is not defined")
			local had = rawget(E, "super")
			E.super = function() end -- the C++ base's constructor
			c.table.__init(obj, ...)
			E.super = had
			return obj
		end
		return p
	end
	E.class = function(name)
		local target = E
		for i = 1, 200 do
			local n, v = debug.getlocal(2, i)
			if n == nil then break end
			if n == "this" then
				if type(v) == "table" then target = v end
				break
			end
		end
		local p = rep(name)
		target[name] = p
		return function(base)
			local b = assert(reps[base], "expected class '" .. name .. "' to derive from or a newline")
			local c = reps[p]
			for k, v in pairs(b.table) do c.table[k] = v end
			for k, v in pairs(b.default) do c.default[k] = v end
		end
	end
	local noop = function() end
	E.action_base = rep("action_base", { initialize = noop, execute = noop, finalize = noop })
	E.property_evaluator = rep("property_evaluator", { evaluate = noop })
end

-- Engine stand-ins the script reads when it loads and when its action runs. Every effect goes to M.trace, in order.
local function engine(M)
	local E = M.env
	M.trace = {}
	local function trace(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		M.trace[#M.trace + 1] = table.concat(parts, " ")
	end
	M.note = trace
	-- danger_object.h (EDangerType, EDangerPerceiveType); script_game_object_script2.cpp (relations, path types)
	E.danger_object = { bullet_ricochet = 0, attack_sound = 1, entity_attacked = 2, entity_death = 3, entity_corpse = 4,
		attacked = 5, grenade = 6, enemy_sound = 7, visual = 0, sound = 1, hit = 2 }
	E.game_object = { friend = 0, neutral = 1, enemy = 2, game_path = 0, level_path = 1, patrol_path = 2, no_path = 3 }
	E.utils_data = { collect_section = function() return {} end }
	E.utils_obj = { send_to_nearest_accessible_vertex = function(npc, lvid) trace("vertex", npc:id(), lvid) return lvid end }
	E.state_mgr = {
		set_state = function(npc, state) trace("state", npc:id(), state) end,
		get_state = function() return "guard" end,
	}
	E.xr_sound = { set_sound_play = function(id, snd) trace("sound", id, snd) end }
	E.get_object_squad = function(npc)
		if not M.squad[npc:id()] then return nil end
		return { squad_members = function()
			local i = 0
			return function()
				i = i + 1
				local id = M.squad_ids[i]
				return id and { id = id } or nil
			end
		end }
	end
	luabind(E)
end

local function load_danger(M)
	local E = M.env
	local path = gamma_script("xr_danger.script")
	local fh = assert(io.open(path, "rb"))
	local src = unlocalize.source(fh:read("*a"), unlocalize.GAMMA.xr_danger)
	fh:close()
	-- CScriptStorage::load_buffer's header (file_header_old, script_storage.cpp): one line, so line numbers stay
	local header = "local function script_name() return \"xr_danger\" end local this = {} xr_danger= this "
		.. "setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. src, "@" .. path))
	setfenv(f, E)
	f()
	return E.xr_danger
end

local function stalker(M, id, x)
	local E = M.env
	local npc = M.add(make_obj(id, x, 0, 0))
	E.db.storage[id] = { object = npc }
	npc.force_set_goodwill = function(self, value, who) M.note("goodwill", self:id(), value, who:id()) end
	npc.make_object_visible_somewhen = function(self, who) M.note("visible", self:id(), who:id()) end
	npc.best_danger = function() return M.danger end
	npc.path_type = function() return E.game_object.level_path end
	npc.set_path_type = function(_, t) M.note("path", id, t) end
	return npc
end

-- set: an answer set of modes.lua; install: false = the pristine G.A.M.M.A. action, no co-op install at all
local function boot(set, install)
	reset_world()
	local M = machine(set == "none" and "single" or "host", 0, AVATARS)
	local E = M.env
	E.coop.is_map_server = function() return set == "srv_map" end
	E.coop.is_dedicated = function() return set == "srv_world" end
	E.story_objects = { object_id_by_story_id = { actor = 0 } }
	E.getFS = function() return { update_path = function() M.reads = (M.reads or 0) + 1; return "absent/packed.script" end,
		exist = function() return false end } end
	E.UnregisterScriptCallback = function(name, f)
		local list = M.callbacks[name] or {}
		for i = #list, 1, -1 do if list[i] == f then table.remove(list, i) end end
	end
	E.coop_main.callback_registered = function(name, f)
		for _, v in ipairs(M.callbacks[name] or {}) do if v == f then return true end end
		return false
	end
	engine(M)
	local X = load_danger(M)
	modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
	if not E.coop_trust then load_script(M, "coop_trust") end
	load_script(M, "coop_npc_players")
	load_script(M, "coop_mods_core")
	load_script(M, "coop_npc_adapters")
	local K
	if install then
		K = load_script(M, "coop_npc_compat")
		K.on_game_start()
		M.env.coop_npc_players.host_on = function() return true end
	end
	-- the squad at the body: 20 sees it, 21 is his squad mate; 30 is the body
	M.squad, M.squad_ids = { [20] = true, [21] = true }, { 20, 21 }
	local npc, mate = stalker(M, 20, 100), stalker(M, 21, 105)
	local body = M.add(make_obj(30, 140, 0, 0, { _alive = false }))
	E.db.storage[30], E.db.storage[0] = { object = body }, { object = E.db.actor }
	return M, E, X, K, npc, mate, body
end

-- One tick of the danger action of npc 20 at the body: the planner's instance (xr_danger.add_to_binder), its object set
-- by the engine. Stage 2 walks on to the body (stage 2, not there yet: no random choice), as in the game.
local function tick(M, X, npc, body, killer_id, dependent)
	M.trace = {}
	M.env.db.storage[30].death_by_id = killer_id
	M.danger = {
		object = function() return body end,
		type = function() return M.env.danger_object.entity_corpse end,
		dependent_object = function() return dependent end,
	}
	local st = { stage = 2, rnd = 10, lvid = 99 }
	local action = X.action_danger("danger", st)
	action.object = npc
	action:execute()
	return M.trace, st
end

local function has(trace, line)
	for _, l in ipairs(trace) do if l == line then return true end end
	return false
end

local function count(trace, prefix)
	local n = 0
	for _, l in ipairs(trace) do if l:sub(1, #prefix) == prefix then n = n + 1 end end
	return n
end

local function applied(K)
	for _, a in ipairs(K and K._applied() or {}) do if a == "native:danger_corpse" then return true end end
	return false
end

-- The game's shape of the script, which the fix must reach (and which find_local alone cannot).
do
	local M, E, X = boot("none", false)
	check(type(X.action_danger) == "userdata" and not pcall(pairs, X.action_danger),
		"G.A.M.M.A. xr_danger.action_danger is a luabind class: a userdata pairs() refuses")
	check(type(rawget(X, "is_danger")) == "function" and type(rawget(X, "bd_types")) == "table",
		"xr_danger is loaded with its unlocalizer (unlocalizer_idiots.ltx: is_danger, bd_types are module fields)")
	check(rawget(X, NAME) == nil and type(E.coop_mods_core.upvalue(X.action_danger.execute, NAME)) == "function",
		"the corpse action is a file local, captured by action_danger:execute")
	check(E.coop_mods_core.find_local(X, NAME) == nil, "find_local does not list luabind class methods (the cause)")
end

-- set -> what a player's character's kill does there. The world server runs no level (no NPC online, no planner): the
-- action never ticks there, but Core behaves alike, so its answer is checked too.
local function session_case(set)
	local M, E, X, K, npc, mate, body = boot(set, true)
	local proxy, other = M.add(make_obj(500, 160, 0, 0)), M.add(make_obj(501, 170, 0, 0))
	E.db.storage[500], E.db.storage[501] = { object = proxy }, { object = other }
	check(applied(K), set .. ": the native corpse rule is installed on G.A.M.M.A.'s luabind action_danger")
	check(not M.reads, set .. ": no module source reread")

	npc._sees[500] = true
	local trace = tick(M, X, npc, body, 500, nil)
	check(has(trace, "goodwill 20 -1000 500") and has(trace, "goodwill 21 -1000 500") and count(trace, "goodwill") == 2,
		set .. ": the NPC who sees the player's character at the body turns his squad on him (killer from death_by_id)")
	check(has(trace, "vertex 20 99") and has(trace, "state 20 assault") and count(trace, "state") == 1,
		set .. ": the stock stage-2 walk to the body runs once after the rule")

	npc._sees[501] = true
	trace = tick(M, X, npc, body, nil, other)
	check(has(trace, "goodwill 20 -1000 501") and has(trace, "goodwill 21 -1000 501") and count(trace, "goodwill") == 2,
		set .. ": the danger's dependent object (the killer) is blamed the same way")

	npc._sees[500] = false
	trace = tick(M, X, npc, body, 500, nil)
	check(count(trace, "goodwill") == 0 and count(trace, "state") == 1, set .. ": a killer the NPC does not see is not blamed")

	npc._sees[500], npc._rel = true, { [500] = E.game_object.friend }
	trace = tick(M, X, npc, body, 500, nil)
	check(has(trace, "visible 20 500") and count(trace, "goodwill") == 0, set .. ": a friend's kill only shows the NPC the killer")
	npc._rel = nil

	proxy._alive = false
	trace = tick(M, X, npc, body, 500, nil)
	check(count(trace, "goodwill") == 0 and count(trace, "visible") == 0, set .. ": a dead killer is not blamed")
	proxy._alive = true

	-- db.actor (the Co-op host; a server's ghost): the stock rule alone, not twice
	npc._sees[0] = true
	trace = tick(M, X, npc, body, 0, nil)
	check(has(trace, "goodwill 20 -1000 0") and has(trace, "goodwill 21 -1000 0") and count(trace, "goodwill") == 2,
		set .. ": db.actor's kill keeps the stock rule exactly once")

	M.set_session(false)
	npc._sees[500] = true
	trace = tick(M, X, npc, body, 500, nil)
	check(count(trace, "goodwill") == 0, set .. ": after the session the rule is off")
end

-- Single player: the installed action does exactly what the pristine G.A.M.M.A. action does.
local function single_case()
	local runs = {}
	for _, install in ipairs({ false, true }) do
		local M, E, X, K, npc, mate, body = boot("none", install)
		local stranger = M.add(make_obj(500, 160, 0, 0))
		E.db.storage[500] = { object = stranger }
		if install then check(applied(K), "single player: the corpse rule is installed (inert outside a session)") end
		local out = {}
		local function run(killer, dependent, sees, rel, alive)
			npc._sees[killer or 500] = sees
			npc._rel = rel and { [killer or 500] = rel } or nil
			stranger._alive = alive
			E.db.actor._alive = alive
			local trace, st = tick(M, X, npc, body, killer, dependent)
			out[#out + 1] = table.concat(trace, "; ") .. " | stage " .. st.stage .. " lvid " .. tostring(st.lvid)
		end
		run(0, nil, true)
		run(0, nil, true, E.game_object.friend)
		run(0, nil, false)
		run(0, nil, true, nil, false)
		run(500, nil, true)
		run(nil, stranger, true)
		runs[#runs + 1] = out
	end
	local same = #runs[1] == #runs[2]
	for i = 1, #runs[1] do same = same and runs[1][i] == runs[2][i] end
	check(same, "single player: every corpse case does exactly what the stock action does")
	check(runs[2][1]:find("goodwill 20 -1000 0", 1, true) ~= nil and runs[2][5]:find("goodwill", 1, true) == nil,
		"single player: the actor's kill turns the squad, an NPC's kill does not (stock)")
end

for _, set in ipairs(modes.names()) do
	if set == "none" then single_case() else session_case(set) end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
