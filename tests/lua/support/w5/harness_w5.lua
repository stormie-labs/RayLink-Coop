-- Anomaly Coop W5 temp harness (not shipped): ALL coop_*.script of every W4 group in one Lua world per
-- machine (host / client / single player), loaded the way the engine does it:
--   * every script is a module table with __index = _G (CScriptStorage file_header_old);
--   * an unknown global auto-loads gamedata\scripts\<name>.script on first access;
--   * axr_main.on_game_start: loop 1 touches every script alphabetically, loop 2 calls on_game_start;
--   * stock Anomaly scripts are stubs with their real shape (functions, tables, classes and methods parsed
--     from the stock files by gen_shapes.py), so wrappers find exactly what the game has;
--   * game objects only answer methods our engine exports (go_methods.lua, from script_game_object*.cpp):
--     calling anything else is reported, like the "attempt to call a nil value" a client would get.
-- Wrapper tracking: every stock function / class method keeps its original stub; diffs after each phase
-- tell who wrapped what and when; chain checks call the final function and count the original's calls.
HERE = "tests/lua/support/w5/"
ROOT = "gamedata/"
SCRIPTS = ROOT .. "scripts/"
dofile(HERE .. "stock_shapes.lua")
dofile(HERE .. "go_methods.lua")
dofile(HERE .. "coop_files.lua")
dofile("tests/lua/support/stubs.d/route.lua") -- F2 T10: install_route_stubs (coop.route over coop_native)

local IS_COOP = {}
for _, n in ipairs(COOP_FILES) do IS_COOP[n] = true end

FAILS, PASSES = 0, 0
function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		if VERBOSE then print("  ok   " .. what) end
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

ISSUES = {}
local issue_seen = {}
function issue(kind, text)
	local k = kind .. "|" .. text
	if issue_seen[k] then issue_seen[k] = issue_seen[k] + 1 return end
	issue_seen[k] = 1
	ISSUES[#ISSUES + 1] = { kind = kind, text = text }
end

NOW = 100000
QUEUE = {}
MACHINES = {}
local next_obj_id = 3000

local function where(level)
	local info = debug.getinfo(level or 3, "Sl")
	if not info then return "?" end
	local src = info.source or "?"
	local n = src:match("([^\\/]+)%.script$") or src:match("([^\\/]+)%.lua$") or src
	return n .. ":" .. tostring(info.currentline)
end

-- first coop_* frame on the stack (who called into the stub world)
local function coop_caller()
	for lvl = 3, 40 do
		local info = debug.getinfo(lvl, "Sl")
		if not info then break end
		local n = (info.source or ""):match("([^\\/]+)%.script$")
		if n and n ~= "coop_route" then return n .. ":" .. tostring(info.currentline) end -- the router shim sits between
	end
	return "?"
end
function script_of_fn(f)
	if type(f) ~= "function" then return "?" end
	local info = debug.getinfo(f, "S")
	local src = info and info.source or ""
	return src:match("([^\\/]+)%.script$") or (info.what == "C" and "[C]") or "harness"
end

-------------------------------------------------------------------------------
-- vectors
-------------------------------------------------------------------------------
local V = {}
V.__index = V
function V:set(x, y, z)
	if type(x) == "table" then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x or 0, y or 0, z or 0 end
	return self
end
function V:distance_to_sqr(o) local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z return dx * dx + dy * dy + dz * dz end
function V:distance_to(o) return math.sqrt(self:distance_to_sqr(o)) end
function V:distance_to_xz(o) local dx, dz = self.x - o.x, self.z - o.z return math.sqrt(dx * dx + dz * dz) end
function V:add(a, b, c) if type(a) == "table" then self.x, self.y, self.z = self.x + a.x, self.y + a.y, self.z + a.z else self.x, self.y, self.z = self.x + a, self.y + (b or a), self.z + (c or a) end return self end
function V:sub(a) self.x, self.y, self.z = self.x - a.x, self.y - a.y, self.z - a.z return self end
function V:mul(k) if type(k) == "table" then self.x, self.y, self.z = self.x * k.x, self.y * k.y, self.z * k.z else self.x, self.y, self.z = self.x * k, self.y * k, self.z * k end return self end
function V:normalize() local l = math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) if l > 0 then self:mul(1 / l) end return self end
function V:magnitude() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:getH() return 0 end
function V:set_length(l) return self:normalize():mul(l) end
function V:mad(a, b, c) if c then self.x = a.x + b.x * c self.y = a.y + b.y * c self.z = a.z + b.z * c else self.x = self.x + a.x * b self.y = self.y + a.y * b self.z = self.z + a.z * b end return self end
function V:dotproduct(o) return self.x * o.x + self.y * o.y + self.z * o.z end
local function vector() return setmetatable({ x = 0, y = 0, z = 0 }, V) end
local function vec(x, y, z) return vector():set(x, y, z) end

-------------------------------------------------------------------------------
-- ini over real LTX (gamedata\configs, with #include ignored) or an empty one
-------------------------------------------------------------------------------
local function parse_ltx(path)
	local data, order = {}, {}
	local fh = io.open(path, "r")
	if not fh then return nil end
	local cur
	for line in fh:lines() do
		line = line:gsub(";.*$", "")
		local sec = line:match("^%s*%[([^%]]+)%]")
		if sec then
			cur = { keys = {}, vals = {} }
			data[sec] = cur
			order[#order + 1] = sec
		elseif cur then
			local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
			if not k then k, v = line:match("^%s*(.-)%s*$"), "" end
			if k and k ~= "" then
				cur.keys[#cur.keys + 1] = k
				cur.vals[k] = v
			end
		end
	end
	fh:close()
	return data, order
end

local function make_ini(data, order)
	data = data or {}
	order = order or {}
	local o = {}
	function o:section_exist(s) return data[s] ~= nil end
	function o:line_count(s) return data[s] and #data[s].keys or 0 end
	function o:r_line(s, i) local d = data[s]; local k = d.keys[i + 1]; return true, k, d.vals[k] end
	function o:r_line_ex(s, i) local d = data[s]; local k = d.keys[i + 1]; return true, k, d.vals[k] end
	function o:line_exist(s, k) return data[s] ~= nil and data[s].vals[k] ~= nil end
	function o:r_string(s, k) return data[s] and data[s].vals[k] end
	function o:r_string_ex(s, k, d) local v = data[s] and data[s].vals[k] if v == nil then return d end return v end
	function o:r_float_ex(s, k, d) local v = data[s] and tonumber(data[s].vals[k]) if v == nil then return d end return v end
	function o:r_u32(s, k) return tonumber(data[s] and data[s].vals[k]) or 0 end
	function o:r_s32(s, k) return tonumber(data[s] and data[s].vals[k]) or 0 end
	function o:r_float(s, k) return tonumber(data[s] and data[s].vals[k]) or 0 end
	function o:r_bool(s, k) local v = data[s] and data[s].vals[k] return v == "true" or v == "1" end
	function o:r_bool_ex(s, k, d) local v = data[s] and data[s].vals[k] if v == nil then return d end return v == "true" or v == "1" end
	function o:r_list(s, k) return {} end
	function o:section_count() return #order end
	function o:section_for_each(f)
		for _, s in ipairs(order) do
			local r = f(s)
			if type(r) ~= "boolean" then issue("luabind", "section_for_each functor returned " .. type(r) .. " (FATAL in game) at " .. coop_caller()) end
			if r then return end
		end
	end
	function o:set_override_names() end
	function o:w_string() end
	function o:save() end
	return o
end

local ini_cache = {}
local function ini_file(name)
	name = tostring(name):gsub("\\", "/")
	if ini_cache[name] == nil then
		local d, ord = parse_ltx(ROOT .. "configs/" .. name)
		ini_cache[name] = d and { d, ord } or false
	end
	local c = ini_cache[name]
	if c then return make_ini(c[1], c[2]) end
	return make_ini({}, {})
end

-------------------------------------------------------------------------------
-- callbacks (axr_main core, same structure as the shipped one: local intercepts + priority)
-------------------------------------------------------------------------------
local function make_axr(M)
	local intercepts = {}
	local next_index = {}
	-- the real callback list of the modded-exes axr_main (intercepts = { name = {}, ... })
	local fh = io.open("engine/gamedata/scripts/axr_main.script", "r")
	if fh then
		local src = fh:read("*a")
		fh:close()
		local body = src:match("local intercepts%s*=%s*(%b{})") or ""
		for n in body:gmatch("([%w_]+)%s*=%s*{}") do intercepts[n] = {} next_index[n] = 1 end
	end
	for _, n in ipairs({ "on_xml_read" }) do
		intercepts[n] = {}
		next_index[n] = 1
	end
	local am = {}
	function am.callback_add(name)
		if not intercepts[name] then
			intercepts[name] = {}
			next_index[name] = 1
		end
	end
	function am.callback_set(name, f)
		if f == nil then return end
		if intercepts[name] then
			intercepts[name][f] = next_index[name]
			next_index[name] = next_index[name] + 1
		else
			issue("callback", "RegisterScriptCallback of a callback that does not exist: '" .. tostring(name) .. "' from " .. coop_caller())
		end
	end
	function am.callback_unset(name, f)
		if intercepts[name] then intercepts[name][f] = nil end
	end
	function am.make_callback(name, ...)
		local t = intercepts[name]
		if not t then return end
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return t[a] < t[b] end)
		for _, fu in ipairs(keys) do
			if t[fu] then
				local f, self_ = fu, nil
				if type(fu) ~= "function" then f, self_ = fu[name], fu end
				if f then
					local ok, err
					if self_ then ok, err = pcall(f, self_, ...) else ok, err = pcall(f, ...) end
					if not ok then
						M.cb_errors[#M.cb_errors + 1] = { name = name, err = tostring(err), src = script_of_fn(type(fu) == "function" and fu or f) }
					end
				end
			end
		end
	end
	function am.count(name)
		local n = 0
		for _ in pairs(intercepts[name] or {}) do n = n + 1 end
		return n
	end
	function am.on_game_start() end
	return am
end

-------------------------------------------------------------------------------
-- game objects: only engine-exported methods exist
-------------------------------------------------------------------------------
local GO_IMPL = {}
local function go_index(M)
	return function(o, k)
		local impl = GO_IMPL[k]
		if impl ~= nil then return impl end
		if GO_PROPS[k] then
			if k == "health" or k == "power" or k == "psy_health" or k == "satiety" or k == "morale" then return 1 end
			if k == "radiation" or k == "bleeding" then return 0 end
			return nil
		end
		if GO_METHODS[k] then
			return function(self, ...)
				M.go_calls[k] = (M.go_calls[k] or 0) + 1
				return nil
			end
		end
		if type(k) == "string" and not k:match("^_") then
			issue("go_method", "game_object has no method/field '" .. k .. "' (read at " .. coop_caller() .. ")")
		end
		return nil
	end
end
function GO_IMPL:id() return self._id end
function GO_IMPL:section() return self._sec or "stalker" end
function GO_IMPL:name() return self._name or ((self._sec or "obj") .. self._id) end
function GO_IMPL:position() return vec(self._pos.x, self._pos.y, self._pos.z) end
function GO_IMPL:direction() return vec(0, 0, 1) end
function GO_IMPL:alive() return self._dead ~= true end
function GO_IMPL:clsid() return self._cls or 0 end
function GO_IMPL:level_vertex_id() return 7 end
function GO_IMPL:game_vertex_id() return 8 end
function GO_IMPL:parent() return self._parent end
function GO_IMPL:object(sec) for _, it in ipairs(self._inv) do if it._sec == sec then return it end end end
function GO_IMPL:iterate_inventory(f, x) local c = {} for i, it in ipairs(self._inv) do c[i] = it end for _, it in ipairs(c) do if f(x, it) == true then return end end end
function GO_IMPL:inventory_for_each(f) for _, it in ipairs(self._inv) do f(it) end end
function GO_IMPL:has_info(i) return self._M.infos[i] == true end
function GO_IMPL:dont_has_info(i) return self._M.infos[i] ~= true end
function GO_IMPL:give_info_portion(i) self._M.infos[i] = true return true end
function GO_IMPL:disable_info_portion(i) self._M.infos[i] = nil return true end
function GO_IMPL:money() return self._money or 0 end
function GO_IMPL:give_money(n) self._money = (self._money or 0) + n end
function GO_IMPL:character_community() return self._comm or "stalker" end
function GO_IMPL:character_name() return "Name" .. self._id end
function GO_IMPL:character_rank() return 0 end
function GO_IMPL:character_reputation() return 0 end
function GO_IMPL:character_icon() return "icon" end
function GO_IMPL:is_talking() return false end
function GO_IMPL:active_item() return nil end
function GO_IMPL:active_slot() return 0 end
function GO_IMPL:item_in_slot() return nil end
function GO_IMPL:condition() return 1 end
function GO_IMPL:get_ammo_in_magazine() return 0 end
function GO_IMPL:see() return false end
function GO_IMPL:relation() return 1 end
function GO_IMPL:general_goodwill() return 0 end
function GO_IMPL:best_enemy() return nil end
function GO_IMPL:get_task() return nil end
function GO_IMPL:is_inv_box_empty() return true end
function GO_IMPL:spawn_ini() return nil end
function GO_IMPL:weight() return 1 end
function GO_IMPL:get_current_outfit() return nil end
function GO_IMPL:get_total_weight() return 1 end
function GO_IMPL:max_health() return 1 end
function GO_IMPL:bone_position() return vec(self._pos.x, self._pos.y, self._pos.z) end
function GO_IMPL:center() return vec(self._pos.x, self._pos.y, self._pos.z) end
function GO_IMPL:is_actor() return self._id == 0 end
function GO_IMPL:is_stalker() return self._kind == "stalker" end
function GO_IMPL:is_monster() return self._kind == "monster" end
function GO_IMPL:get_visual_name() return "actors\\stalker" end
function GO_IMPL:profile_name() return "sim_default_stalker_0" end
function GO_IMPL:inside() return false end
function GO_IMPL:accessible() return true end
function GO_IMPL:get_physics_shell() return nil end
function GO_IMPL:get_inventory_box() return nil end
function GO_IMPL:get_artefact() return nil end
local COND = {}
function COND:BoosterForEach(f)
	local r = f(1, 60, 0.5)
	if type(r) ~= "boolean" then issue("luabind", "BoosterForEach functor returned " .. type(r) .. " (FATAL in game) at " .. coop_caller()) end
end
function COND:WoundForEach(f)
	local r = f({})
	if type(r) ~= "boolean" then issue("luabind", "WoundForEach functor returned " .. type(r) .. " (FATAL in game) at " .. coop_caller()) end
end
local COND_OK = {}
for w in ("AddHit AddWound ApplyBooster BleedingSpeed BloodSize BoostBleedingRestore BoostBurnImmunity BoostChemicalBurnImmunity BoostChemicalBurnProtection BoostExplImmunity BoostFireWoundImmunity BoostHpRestore BoostMaxWeight BoostPowerRestore BoostRadiationImmunity BoostRadiationProtection BoostRadiationRestore BoostShockImmunity BoostStrikeImmunity BoostTelepaticImmunity BoostTelepaticProtection BoostWoundImmunity ChangeAlcohol ChangeBleeding ChangeEntityMorale ChangeHealth ChangePower ChangePsyHealth ChangeRadiation ChangeSatiety ClearAllBoosters ClearWounds GetAlcohol GetBoneNum GetDestroy GetEntityMorale GetHealthLost GetMaxPower GetParticleBoneNum GetPsyBar GetRadiation IsCantSprint IsCantWalk IsCantWalkWeight IsLimping SatietyCritical SetBoneNum SetDestroy SetMaxPower SetParticleBoneNum SetPower SetPsyBar TotalSize TypeSize"):gmatch("%S+") do
	if COND[w] == nil then COND[w] = function() return nil end end
end
setmetatable(COND, { __index = function(_, k) issue("go_method", "CActorCondition has no method '" .. tostring(k) .. "' (at " .. coop_caller() .. ")") end })
function COND:ApplyBooster() end
function COND:BoostParameters() end
function COND:GetSatiety() return 1 end
function COND:GetPower() return 1 end
function COND:GetPsyHealth() return 1 end
local CACTOR = { conditions = function() return COND end, set_inventory_weight = function() end }
function GO_IMPL:cast_Actor() return self._id == 0 and CACTOR or nil end
function GO_IMPL:get_story_id() return nil end
function GO_IMPL:story_id() return 65535 end
function GO_IMPL:rank() return 0 end
function GO_IMPL:get_bone_id() return 0 end
function GO_IMPL:set_actor_position(p) self._pos = vec(p.x, p.y, p.z) end
function GO_IMPL:transfer_item(item, to)
	for i, it in ipairs(self._inv) do if it == item then table.remove(self._inv, i) to._inv[#to._inv + 1] = it it._parent = to return end end
end
function GO_IMPL:kill() self._dead = true self._M.kills = (self._M.kills or 0) + 1 end
function GO_IMPL:give_game_news() self._M.news = (self._M.news or 0) + 1 end
function GO_IMPL:give_talk_message2() end
function GO_IMPL:get_actor_relation_flags() return 0 end

local function new_obj(M, id, sec, kind, pos)
	local o = setmetatable({ _id = id, _sec = sec, _kind = kind, _pos = pos or vec(0, 0, 0), _inv = {}, _M = M }, M.GOMT)
	M.objects[id] = o
	return o
end

-------------------------------------------------------------------------------
-- stock module stubs with the real shape
-------------------------------------------------------------------------------
local BUILTINS = { "string", "table", "math", "pairs", "ipairs", "type", "tostring", "tonumber", "pcall", "xpcall",
	"error", "select", "unpack", "next", "rawget", "rawset", "rawequal", "setmetatable", "getmetatable", "setfenv",
	"getfenv", "loadstring", "debug", "assert", "coroutine", "bit", "collectgarbage", "jit" }

local function stub_fn(M, key)
	return function(...)
		M.calls[key] = (M.calls[key] or 0) + 1
		local r = M.ret[key]
		if type(r) == "function" then return r(...) end
		return r
	end
end

local function class_tbl(M, modname, cname, methods)
	local cls = {}
	for _, m in ipairs(methods) do
		local key = modname .. "." .. cname .. ":" .. m
		local f = stub_fn(M, key)
		cls[m] = f
		M.orig[key] = { tbl = cls, k = m, f = f }
	end
	cls.__index = cls
	setmetatable(cls, { __call = function(c, ...)
		local o = setmetatable({}, c)
		if c.__init then c.__init(o, ...) end
		return o
	end })
	return cls
end

local function make_stock(M, name, sh)
	local mod = setmetatable({}, { __index = M.env })
	rawset(M.env, name, mod)
	M.stock[name] = mod
	for _, f in ipairs(sh.f or {}) do
		local key = name .. "." .. f
		local fn = stub_fn(M, key)
		mod[f] = fn
		M.orig[key] = { tbl = mod, k = f, f = fn }
	end
	for tname, list in pairs(sh.t or {}) do
		local t = {}
		mod[tname] = t
		for _, f in ipairs(list) do
			local key = name .. "." .. tname .. "." .. f
			local fn = stub_fn(M, key)
			t[f] = fn
			M.orig[key] = { tbl = t, k = f, f = fn }
		end
	end
	for cname, c in pairs(sh.c or {}) do
		mod[cname] = class_tbl(M, name, cname, c.m or {})
	end
	local fix = M.stock_fix[name]
	if fix then
		fix(mod)
		for key, o in pairs(M.orig) do
			if o.tbl == mod and rawget(mod, o.k) ~= o.f then M.counted(mod, o.k, key) end
		end
	end
	return mod
end

-------------------------------------------------------------------------------
-- script loading (CScriptStorage)
-------------------------------------------------------------------------------
local src_cache = {}
local function read_src(name)
	if src_cache[name] == nil then
		local fh = io.open(SCRIPTS .. name .. ".script", "r")
		src_cache[name] = fh and fh:read("*a") or false
		if fh then fh:close() end
	end
	return src_cache[name]
end

function load_script(M, name)
	local src = read_src(name)
	if not src then return nil end
	local f, err = loadstring(src, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. name .. ".script")
	if not f then
		issue("load", name .. ": SYNTAX " .. tostring(err))
		return nil
	end
	local mod = setmetatable({}, { __index = M.env })
	rawset(M.env, name, mod)
	M.load_order[#M.load_order + 1] = name
	M.loading[#M.loading + 1] = name
	setfenv(f, mod)
	local ok, e = pcall(f)
	table.remove(M.loading)
	if not ok then
		issue("load", M.role .. " " .. name .. ": top-level error: " .. tostring(e))
	end
	return mod
end

-------------------------------------------------------------------------------
-- one machine
-------------------------------------------------------------------------------
-- role: "host" | "client" | "single" (exe with co-op, no session) | "noapi" (exe without co-op)
-- opts.w5 = true: the engine functions C1/C2 add in W5 exist
-- opts.mods = { name = true, ... }: third-party mod scripts that "exist" (chameleon modules)
function machine(role, peer, opts)
	opts = opts or {}
	local M = { role = role, peer = peer or 0, log = {}, sent = {}, calls = {}, ret = {}, orig = {}, stock = {},
		objects = {}, infos = {}, cb_errors = {}, go_calls = {}, load_order = {}, loading = {}, stock_fix = {},
		timers = {}, unique = {}, handlers_seen = {}, opts = opts }
	M.GOMT = { __index = go_index(M) }
	local E = {}
	M.env = E
	for _, k in ipairs(BUILTINS) do E[k] = _G[k] end
	E.os = { clock = os.clock, date = os.date, time = os.time, getenv = function() return nil end }
	E.io = { open = function() return nil end }
	E._G = E
	E.print = function() end

	-- every _g.script function exists as a stub global, a few with behaviour
	for _, f in ipairs(STOCK["_g"].f) do
		local key = "_g." .. f
		local fn = stub_fn(M, key)
		E[f] = fn
		M.orig[key] = { tbl = E, k = f, f = fn }
	end
	for cname, c in pairs(STOCK["_g"].c or {}) do E[cname] = class_tbl(M, "_g", cname, c.m or {}) end
	for tname, list in pairs(STOCK["_g"].t or {}) do
		E[tname] = E[tname] or {}
		for _, f in ipairs(list) do E[tname][f] = stub_fn(M, "_g." .. tname .. "." .. f) end
	end

	E.printf = function(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if VERBOSE then print("    [" .. role .. "] " .. line) end
	end
	E.printe = E.printf
	E.printdbg = function() end
	E.time_global = function() return NOW end
	E.strformat = string.format
	E.callstack = function() end
	E.empty_table = function(t) for k in pairs(t) do t[k] = nil end return t end
	E.is_empty = function(t) return t == nil or next(t) == nil end
	E.clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
	E.round = function(v) return math.floor(v + 0.5) end
	E.round_idp = function(v, n) local m = 10 ^ (n or 0) return math.floor(v * m + 0.5) / m end
	E.bit_or = function(a, b) return bit.bor(a, b) end
	E.bit_and = function(a, b) return bit.band(a, b) end
	E.FS = { FS_ListFiles = 1, FS_RootOnly = 2, FS_ListFolders = 4 }
	E.AC_ID = 0
	E.vector = vector
	E.vec = vec
	E.ini_file = ini_file
	E.ini_sys = make_ini({}, {})
	E.system_ini = function() return E.ini_sys end
	E.game_ini = function() return E.ini_sys end
	E.DIK_keys = setmetatable({}, { __index = function(_, k) return 200 end })
	E.key_bindings = setmetatable({}, { __index = function(_, k) return 300 end })
	E.ui_events = setmetatable({}, { __index = function(_, k) return 1 end })
	E.clsid = setmetatable({}, { __index = function(_, k) return 9 end })
	E.dik_to_bind = function() return 0 end
	E.bind_to_dik = function(a, b)
		if b == nil then issue("luabind", "bind_to_dik called with ONE argument (FATAL: luabind has no defaults) at " .. coop_caller()) end
		return 0
	end
	E.get_console = function() return { get_integer = function() return 0 end, get_float = function() return 0 end,
		get_bool = function() return false end, get_string = function() return "" end, execute = function() end } end
	E.exec_console_cmd = function() end
	E.device = function() return { time_continual = function() return NOW end, width = 1920, height = 1080, precache_frame = 0,
		frame = 1, fov = 75, cam_pos = vec(0, 0, 0), cam_dir = vec(0, 0, 1) } end
	E.getFS = function()
		return {
			exist = function(_, alias, fname)
				if not fname then return nil end
				local n = tostring(fname):match("^(.-)%.script$")
				if n and (IS_COOP[n] or STOCK[n] or (opts.mods and opts.mods[n])) then return true end
				return nil
			end,
			update_path = function(_, a, b) return tostring(a) .. tostring(b) end,
			file_list_open_ex = function(_, alias, flags, mask)
				local list = {}
				if alias == "$game_config$" and mask == "coop_domains_*.ltx" then
					for _, g in ipairs({ "core", "economy", "menu", "mods", "npc", "quests" }) do
						local fh = io.open(ROOT .. "configs/coop_domains_" .. g .. ".ltx", "r")
						if fh then fh:close() list[#list + 1] = "coop_domains_" .. g .. ".ltx" end
					end
				end
				return { Size = function() return #list end, GetAt = function(_, i)
					local nm = list[i + 1]
					return { NameFull = function() return nm end, NameShort = function() return nm end, Size = function() return 1 end }
				end }
			end,
		}
	end
	E.game = {
		translate_string = function(s) return tostring(s) end,
		get_game_time = function() return { diffSec = function() return 0 end, dateToString = function() return "" end,
			timeToString = function() return "" end, sub = function() end, add = function() end, setHMSms = function() end,
			get = function() return 2012, 5, 1, 12, 0, 0, 0 end } end,
		CTime = function() return { setHMSms = function() end, sub = function() end, add = function() end, diffSec = function() return 0 end } end,
		time = function() return NOW * 6 end,
		start_tutorial = function() end, has_active_tutorial = function() return false end,
		get_resolutions = function() return "" end,
		world2ui = function() return vec(0, 0, 0) end,
	}
	E.level = {
		object_by_id = function(id) return M.objects[id] end,
		name = function() return "l01_escape" end,
		present = function() return true end,
		get_time_factor = function() return 6 end,
		set_time_factor = function() end,
		get_time_hours = function() return 12 end,
		get_time_minutes = function() return 0 end,
		get_time_days = function() return 1 end,
		change_game_time = function() M.calls["level.change_game_time"] = (M.calls["level.change_game_time"] or 0) + 1 end,
		add_cam_effector = function() end, remove_cam_effector = function() end,
		add_pp_effector = function() end, remove_pp_effector = function() end,
		add_complex_effector = function() end, remove_complex_effector = function() end,
		enable_input = function() end, disable_input = function() end,
		map_add_object_spot = function() end, map_add_object_spot_ser = function() end, map_remove_object_spot = function() end,
		map_has_object_spot = function() return 0 end, map_change_spot_hint = function() end,
		get_target_obj = function() return nil end, get_target_dist = function() return 100 end,
		actor_moving_state = function() return 0 end,
		vertex_position = function() return vec(0, 0, 0) end,
		vertex_id = function() return 7 end,
		get_snd_volume = function() return 1 end, set_snd_volume = function() end,
		is_wfx_playing = function() return false end, get_weather = function() return "w" end,
		rain_factor = function() return 0 end,
		add_call = function(a, b) end, remove_call = function() end,
		show_indicators = function() end, hide_indicators_safe = function() end,
		get_game_difficulty = function() return 1 end,
		iterate_nearest = function() end,
		high_cover_in_direction = function() return 0 end, low_cover_in_direction = function() return 0 end,
		patrol_path_exists = function() return false end,
		get_bounding_volume = function() return { min = vec(0, 0, 0), max = vec(1, 1, 1) } end,
		set_weather = function() end, set_weather_fx = function() end, environment = function() return nil end,
		set_pp_effector_factor = function() end,
		get_view_entity = function() return M.actor end,
		game_id = function() return 1 end,
	}
	E.alife = function()
		return {
			object = function(_, id) return M.objects[id] and E.alife_object(id) end,
			level_name = function() return "l01_escape" end,
			actor = function() return E.alife_object(0) end,
			create = function() return nil end,
			release = function() end,
			story_object = function() return nil end,
			has_info = function(_, id, info) return M.infos[info] == true end,
			level_id = function() return 1 end,
			switch_distance = function() return 150 end,
			iterate_objects = function() end,
			set_switch_online = function() end, set_switch_offline = function() end,
			teleport_object = function() end,
		}
	end
	E.game_graph = function() return { vertex = function() return { level_id = function() return 1 end, game_point = function() return vec(0, 0, 0) end, level_vertex_id = function() return 7 end } end, valid_vertex_id = function() return true end } end
	E.alife_object = function(id)
		local o = M.objects[id]
		if not o then return nil end
		return { id = id, parent_id = o._parent and o._parent._id or 65535, position = o:position(), m_level_vertex_id = 7,
			m_game_vertex_id = 8, group_id = 65535, online = true, section_name = function() return o._sec end,
			name = function() return o:name() end, clsid = function() return 0 end, alive = function() return o._dead ~= true end,
			community = function() return o._comm or "stalker" end, character_name = function() return "N" end,
			profile_name = function() return "p" end, rank = function() return 0 end, commander_id = function() return 65535 end,
			squad_members = function() return function() return nil end end, smart_terrain_id = function() return 65535 end }
	end
	E.alife_create = function() M.world_spawns = (M.world_spawns or 0) + 1 return nil end
	E.alife_create_item = function() M.item_spawns = (M.item_spawns or 0) + 1 return nil end
	E.alife_release = function() end
	E.alife_release_id = function() end
	E.get_object_by_id = function(id) return M.objects[id] end
	E.has_alife_info = function(i) return M.infos[i] == true end
	E.give_info = function(i) M.infos[i] = true end
	E.disable_info = function(i) M.infos[i] = nil end
	E.load_var = function(o, k, d) return d end
	E.save_var = function() end
	E.se_load_var = function(id, n, k) return nil end
	E.se_save_var = function(id, n, k, v) M.calls["_g.se_save_var"] = (M.calls["_g.se_save_var"] or 0) + 1 end
	M.orig["_g.se_save_var"] = { tbl = E, k = "se_save_var", f = E.se_save_var }
	E.IsStalker = function(o) return type(o) == "table" and o._kind == "stalker" end
	E.IsMonster = function(o) return type(o) == "table" and o._kind == "monster" end
	E.IsInvbox = function(o) return type(o) == "table" and o._kind == "box" end
	E.IsWeapon = function() return false end
	E.IsItem = function() return false end
	E.IsArtefact = function() return false end
	E.IsOutfit = function() return false end
	E.IsAmmo = function() return false end
	E.IsTrader = function() return false end
	E.get_story_object = function(s) if s == "actor" then return E.db.actor end return nil end
	E.get_story_object_id = function() return nil end
	E.get_story_se_item = function() return nil end
	E.GetEvent = function(k) M.events_ = M.events_ or {} return M.events_[k] end
	E.SetEvent = function(k, v) M.events_ = M.events_ or {} M.events_[k] = v end
	E.ui_options = { get = function() return nil end, set = function() end, save = function() end }
	E.get_hud = function() return { AddDialogToRender = function() end, RemoveDialogToRender = function() end,
		GetCustomStatic = function() return nil end, AddCustomStatic = function() return nil end, RemoveCustomStatic = function() end,
		HideActorMenu = function() end, GetActorMenu = function() return nil end, UpdateActorMenu = function() end } end
	E.actor_menu = { get_last_mode = function() return 0 end, set_msg = function() end, set_fade_msg = function() end }
	E.utils_xml = { get_color = function() return 0 end }
	E.GetARGB = function() return 0 end
	E.Frect = function() return { set = function(self) return self end } end
	local function engine_base(nm)
		local b = setmetatable({}, { __index = function(_, k) return function() return nil end end })
		rawset(b, "__init", function() end)
		return b
	end
	for _, nm in ipairs({ "CUIScriptWnd", "CUIListBoxItem", "CUIListBoxItemMsgChain", "CUIWindow", "CUIStatic",
		"CUITextWnd", "CUIMessageBoxEx", "CUIScrollView", "CUIComboBox", "CUIEditBox", "CUICheckButton",
		"CUITrackBar", "CUI3tButton", "CUIMMShniaga", "object_binder", "CUIActorMenu" }) do
		E[nm] = engine_base(nm)
	end
	E.class = function(name)
		local env = getfenv(2)
		local cls = {}
		cls.__index = cls
		local function finish(base)
			setmetatable(cls, { __index = base, __call = function(c, ...)
				local o = setmetatable({}, c)
				if c.__init then c.__init(o, ...) end
				return o
			end })
		end
		finish(nil)
		rawset(env, name, cls)
		return finish
	end
	E.super = function() end
	E.CScriptXmlInit = function() return setmetatable({}, { __index = function() return function() return nil end end }) end
	E.sound_object = setmetatable({ s2d = 1, s3d = 0, looped = 2 }, { __call = function() return { play = function() end,
		play_at_pos = function() end, play_no_feedback = function() end, stop = function() end, playing = function() return false end,
		length = function() return 1000 end, volume = 1, attach_tail = function() end } end })
	E.particles_object = function() return { play_at_pos = function() end, stop = function() end, playing = function() return false end } end
	E.hit = function() return { type = 0, power = 0, impulse = 0, direction = vec(0, 0, 1), draftsman = nil } end
	E.hit_memory_manager = nil
	E.CTime = E.game.CTime
	E.patrol = function() return { count = function() return 1 end, point = function() return vec(0, 0, 0) end, level_vertex_id = function() return 7 end, game_vertex_id = function() return 8 end } end
	E.DIK_RETURN = 28
	E.GAME_VERSION = "1.5.3"
	E.USE_MARSHAL = true
	E.SIMBOARD = { smarts = {}, smarts_by_names = {}, squads = {} }
	E.task = { completed = 2, fail = 0, in_progress = 1, task_dummy = 0 }

	-- engine co-op API
	local session = role == "host" or role == "client"
	local avatars = role == "host" and { [0] = 0, [1] = 501 } or { [0] = 500, [1] = 0 }
	M.session = session
	if role ~= "noapi" then
		local api = {
			is_active = function() return M.session end,
			is_host = function() return M.session and role == "host" end,
			is_client = function() return M.session and role == "client" end,
			is_live = function() return M.session end,
			self_id = function() return M.peer end,
			players = function()
				if not M.session then return {} end
				return {
					{ id = 0, nick = "host", is_self = role == "host", avatar_id = avatars[0], rtt = 0 },
					{ id = 1, nick = "client", is_self = role == "client", avatar_id = avatars[1], rtt = 12 },
				}
			end,
			avatar_of = function(p) return avatars[p] end,
			peer_of_avatar = function(id) for p, av in pairs(avatars) do if av == id and av ~= 0 then return p end end end,
			to_host_id = function(id)
				if role ~= "client" then return id end
				if id == 0 then return 501 elseif id == 500 then return 0 end
				return id
			end,
			to_local_id = function(id)
				if role ~= "client" then return id end
				if id == 501 then return 0 elseif id == 0 then return 500 end
				return id
			end,
			send_event = function(name, payload, target)
				if type(name) ~= "string" or type(payload) ~= "string" then
					issue("net", "send_event with bad args name=" .. type(name) .. " payload=" .. type(payload) .. " at " .. coop_caller())
					return false, "bad args"
				end
				if #payload > 16384 then issue("net", "payload over 16 KiB: " .. name) return false, "too big" end
				M.sent[#M.sent + 1] = { name = name, payload = payload, target = target }
				QUEUE[#QUEUE + 1] = { from = M.peer, M = M, name = name, payload = payload, target = target }
				return true
			end,
			send_chat = function(t) return true end,
			stash_set = function(k, v) M.stash = M.stash or {} M.stash[k] = v return true end,
			stash_get = function(k) return M.stash and M.stash[k] end,
			session_info = function() return { phase = M.session and "live" or "off" } end,
		}
		if opts.w5 then
			api.life_of = function(id) return "alive" end
			api.bleed_left = function(id) return 0 end
			api.spot_is_local = function(t) return type(t) == "string" and t:sub(1, 5) == "coop_" end
			api.story_hold_infos = function(on) M.hold_infos = on == true return true end
			api.story_local_task = function(id, on) return true end
			api.player_safemode = function(p) return false end
		end
		install_route_stubs(api) -- F2 T10: coop.route answers by is_active / is_host above
		E.coop = api
	end

	-- callbacks, unique calls, time events
	local am = make_axr(M)
	M.axr = am
	E.axr_main = am
	M.stock.axr_main = am
	E.RegisterScriptCallback = function(n, f) E.axr_main.callback_set(n, f) end
	E.UnregisterScriptCallback = function(n, f) E.axr_main.callback_unset(n, f) end
	E.SendScriptCallback = function(n, ...) E.axr_main.make_callback(n, ...) end
	E.AddScriptCallback = function(n) E.axr_main.callback_add(n) end
	E.AddUniqueCall = function(f) M.unique[#M.unique + 1] = f end
	E.RemoveUniqueCall = function(f) for i = #M.unique, 1, -1 do if M.unique[i] == f then table.remove(M.unique, i) end end end
	E.CreateTimeEvent = function(ev, act, timer, f, ...)
		if type(f) ~= "function" then issue("timer", "CreateTimeEvent without a function (ev " .. tostring(ev) .. ") at " .. coop_caller()) return end
		M.timers[#M.timers + 1] = { ev = ev, act = act, at = NOW + (tonumber(timer) or 0) * 1000, f = f, p = { ... } }
	end
	E.RemoveTimeEvent = function(ev, act)
		for i = #M.timers, 1, -1 do if M.timers[i].ev == ev and M.timers[i].act == act then table.remove(M.timers, i) end end
	end
	E.ResetTimeEvent = function() end

	-- world: actor, the other player's character, an NPC, a box
	M.actor = new_obj(M, 0, "actor", "actor", vec(0, 0, 0))
	M.actor._comm = "actor_stalker"
	local other = role == "host" and 501 or 500
	if session then M.proxy = new_obj(M, other, "coop_player_avatar", "stalker", vec(3, 0, 0)) end
	M.npc = new_obj(M, 700, "stalker_npc", "stalker", vec(10, 0, 0))
	M.box = new_obj(M, 710, "inventory_box", "box", vec(2, 0, 0))
	M.mutant = new_obj(M, 720, "dog_weak", "monster", vec(15, 0, 0))
	E.db = { actor = M.actor, storage = { [0] = { pstor = {} }, [700] = { pstor = {} } }, zone_by_name = {}, OnlineStalkers = {},
		actor_inside_zones = {}, anomaly_by_name = {}, smart_terrain_by_id = {}, campfire_table_by_smart_names = {},
		add_obj = function() end, del_obj = function() end, script_ids = {}, storage_static = {} }
	M.orig["db.actor"] = { tbl = E.db, k = "actor", f = M.actor }

	-- stock modules that need behaviour on top of their shape
	M.stock_fix.alife_storage_manager = function(mod)
		mod.m_data = {}
		mod.CALifeStorageManager_load = function()
			mod.on_before_load_state()
			E.SendScriptCallback("load_state", mod.m_data)
		end
		mod.CALifeStorageManager_before_save = function()
			E.SendScriptCallback("save_state", mod.m_data)
		end
		mod.get_state = function() return mod.m_data end
	end
	M.stock_fix.xr_logic = function(mod)
		M.ret["xr_logic.parse_condlist"] = function(npc, sec, field, src) return { { section = tostring(src), infop_check = {}, infop_set = {} } } end
		M.ret["xr_logic.pick_section_from_condlist"] = function(actor, npc, cond)
			return type(cond) == "table" and cond[1] and cond[1].section or nil
		end
	end
	M.stock_fix.surge_manager = function(mod)
		local inst = setmetatable({ _state_loaded = true, started = false }, mod.CSurgeManager)
		mod.get_surge_manager = function() return inst end
		mod.SurgeManager = inst
		mod.is_started = function() return false end
	end
	M.stock_fix.psi_storm_manager = function(mod)
		local inst = setmetatable({ _state_loaded = true, started = false }, mod.CPsiStormManager)
		mod.get_psi_storm_manager = function() return inst end
		mod.is_started = function() return false end
	end
	M.stock_fix.task_manager = function(mod)
		local inst = setmetatable({ task_info = {} }, mod.CRandomTask)
		mod.get_task_manager = function() return inst end
		mod.task_ini = make_ini({}, {})
	end
	M.stock_fix.ui_options = function(mod)
		mod.get = function() return nil end
	end
	M.stock_fix.xr_sound = function(mod)
		mod.get_safe_sound_object = function() return E.sound_object() end
	end

	-- third-party mods: chameleon modules (any field is a stub function)
	M.fake_mod = function(name)
		local m = setmetatable({}, { __index = function(t, k)
			if type(k) ~= "string" then return nil end
			local f = stub_fn(M, name .. "." .. k)
			rawset(t, k, f)
			return f
		end })
		rawset(E, name, m)
		return m
	end

	-- functions the harness gives behaviour: the original is a counting shim around it
	local function counted(tbl, k, key)
		local impl = rawget(tbl, k)
		if type(impl) ~= "function" then return end
		local f = function(...)
			M.calls[key] = (M.calls[key] or 0) + 1
			local r = M.ret[key]
			if r ~= nil then if type(r) == "function" then return r(...) end return r end
			return impl(...)
		end
		rawset(tbl, k, f)
		M.orig[key] = { tbl = tbl, k = k, f = f }
	end
	for _, k in ipairs({ "CreateTimeEvent", "AddUniqueCall", "RemoveUniqueCall", "alife_create", "alife_create_item",
		"alife_release", "alife_release_id", "save_var", "load_var", "se_save_var", "se_load_var", "give_info", "disable_info",
		"has_alife_info", "get_story_object", "RegisterScriptCallback", "SendScriptCallback", "printf" }) do
		counted(E, k, "_g." .. k)
	end
	for _, k in ipairs({ "change_game_time", "add_cam_effector", "add_pp_effector", "object_by_id" }) do
		counted(E.level, k, "level." .. k)
	end
	M.counted = counted

	setmetatable(E, { __index = function(t, k)
		if type(k) ~= "string" then return nil end
		if IS_COOP[k] then return load_script(M, k) end
		if opts.mods and opts.mods[k] then return M.fake_mod(k) end
		local sh = STOCK[k]
		if sh and k ~= "_g" then return make_stock(M, k, sh) end
		return nil
	end })

	MACHINES[#MACHINES + 1] = M
	return M
end

-------------------------------------------------------------------------------
-- engine-like driving
-------------------------------------------------------------------------------
function pump()
	local guard = 0
	while #QUEUE > 0 and guard < 10000 do
		guard = guard + 1
		local e = table.remove(QUEUE, 1)
		for _, other in ipairs(MACHINES) do
			if other ~= e.M and other.session and other.alive_env then
				local to_it = (e.target == nil or e.target == -1) or (e.target == other.peer)
				if to_it then
					local cm = rawget(other.env, "coop_main")
					if cm and cm.on_event then
						local ok, err = pcall(cm.on_event, e.name, e.payload, e.from)
						if not ok then other.cb_errors[#other.cb_errors + 1] = { name = "on_event " .. e.name, err = tostring(err), src = "coop_main" } end
					end
				end
			end
		end
	end
end

function run_timers(M)
	local keep = {}
	local due = {}
	for _, t in ipairs(M.timers) do if t.at <= NOW then due[#due + 1] = t else keep[#keep + 1] = t end end
	M.timers = keep
	for _, t in ipairs(due) do
		local ok, r = pcall(t.f, unpack(t.p))
		if not ok then
			M.cb_errors[#M.cb_errors + 1] = { name = "time_event " .. tostring(t.ev), err = tostring(r), src = script_of_fn(t.f) }
		elseif r ~= true then
			t.at = NOW + 100
			M.timers[#M.timers + 1] = t
		end
	end
	for _, f in ipairs({ unpack(M.unique) }) do
		local ok, r = pcall(f)
		if not ok then M.cb_errors[#M.cb_errors + 1] = { name = "unique_call", err = tostring(r), src = script_of_fn(f) }
		elseif r == true then M.env.RemoveUniqueCall(f) end
	end
end

function fire(M, name, ...)
	M.env.SendScriptCallback(name, ...)
end

-- every function value of every stock module (and _G functions) -> key -> value
function snapshot(M)
	local s = {}
	for key, o in pairs(M.orig) do
		s[key] = rawget(o.tbl, o.k)
	end
	-- db.actor method shadowing (per-object table on luabind userdata)
	for k, v in pairs(M.actor) do
		if type(k) == "string" and not k:match("^_") then s["db.actor." .. k] = v end
	end
	s["db.actor"] = M.env.db.actor
	return s
end

-- diff two snapshots -> list of {key, by}
function diff(a, b, M)
	local out = {}
	for k, v in pairs(b) do
		local o = M and M.orig[k]
		local fresh = a[k] == nil and o and o.f == v -- a stock module built in this phase, untouched
		if a[k] ~= v and not fresh then out[#out + 1] = { key = k, by = type(v) == "function" and script_of_fn(v) or tostring(v) } end
	end
	for k, v in pairs(a) do
		if b[k] == nil and v ~= nil then out[#out + 1] = { key = k, by = "(removed)" } end
	end
	table.sort(out, function(x, y) return x.key < y.key end)
	return out
end

-- axr_main.on_game_start as the game does it, with a snapshot after every on_game_start
local AXR_IGNORE = { ["_g"] = true, class_registrator = true, game_registrator = true, ui_registrator = true,
	ce_new_attachable_item = true, ce_new_game_dm = true, sim_faction_brain_human = true, sim_faction_brain_mutant = true,
	ce_switcher = true, axr_main = true, lua_help = true, rx_gl = true }

function start_game(M)
	M.alive_env = true
	local names = {}
	for _, n in ipairs(COOP_FILES) do names[#names + 1] = n end
	for n in pairs(STOCK) do if not IS_COOP[n] then names[#names + 1] = n end end
	for n in pairs(M.opts.mods or {}) do names[#names + 1] = n end
	table.sort(names)
	M.wrap_log = {}
	local s0 = snapshot(M)
	-- loop 1: load all scripts
	local with_start = {}
	for _, n in ipairs(names) do
		if not AXR_IGNORE[n] then
			local before = #M.load_order
			local mod = M.env[n]
			if IS_COOP[n] then
				-- coop scripts that this one pulled in earlier than the alphabetical loop
				for i = before + 2, #M.load_order do
					M.early = M.early or {}
					M.early[#M.early + 1] = M.load_order[i] .. " (by " .. n .. ")"
				end
			end
			if type(mod) == "table" and rawget(mod, "on_game_start") then with_start[#with_start + 1] = n end
		end
	end
	local s1 = snapshot(M)
	for _, d in ipairs(diff(s0, s1, M)) do M.wrap_log[#M.wrap_log + 1] = { phase = "load", key = d.key, by = d.by } end
	-- loop 2: on_game_start
	local prev = s1
	for _, n in ipairs(with_start) do
		local mod = M.env[n]
		local ok, err = pcall(mod.on_game_start)
		if not ok then issue("start", M.role .. " " .. n .. ".on_game_start: " .. tostring(err)) end
		if IS_COOP[n] then
			local s = snapshot(M)
			for _, d in ipairs(diff(prev, s, M)) do M.wrap_log[#M.wrap_log + 1] = { phase = "on_game_start:" .. n, key = d.key, by = d.by } end
			prev = s
		end
	end
	M.after_start = prev
end

function first_update(M)
	local am = M.env.alife_storage_manager
	am.m_data = am.m_data or {}
	pcall(am.CALifeStorageManager_load)
	fire(M, "on_game_load")
	fire(M, "actor_on_reinit")
	local before = snapshot(M)
	fire(M, "actor_on_first_update")
	local after = snapshot(M)
	for _, d in ipairs(diff(before, after, M)) do M.wrap_log[#M.wrap_log + 1] = { phase = "actor_on_first_update", key = d.key, by = d.by } end
	M.after_first = after
end

function frames(M, n, step)
	for _ = 1, n do
		NOW = NOW + (step or 100)
		fire(M, "actor_on_update")
		run_timers(M)
	end
end

function all_frames(n, step)
	for _ = 1, n do
		NOW = NOW + (step or 100)
		for _, M in ipairs(MACHINES) do
			if M.alive_env then
				M.env.SendScriptCallback("actor_on_update")
				run_timers(M)
			end
		end
		pump()
	end
end

function log_lines(M, pat)
	local out = {}
	for _, l in ipairs(M.log) do if l:find(pat) then out[#out + 1] = l end end
	return out
end

H = { vec = vec, vector = vector, new_obj = new_obj, make_ini = make_ini }
