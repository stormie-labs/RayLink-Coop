-- Split levels, docs\SPLIT_LEVELS.md 7a: the form of an error that came back several times. A script passes "I lead this level" (a
-- map server, P.is_host()), the engine says no: on a map server coop.sync.set of the session or the world is refused, and
-- coop.sync.broadcast reaches only the players of its level. So every such call in the scripts has to say what it does on a map
-- server: its function names the role, branches on the map authority from the facade, or has a "-- Mk:" explanation. A
-- new call without one fails here. Run: tools\test_lua.cmd mk_sync_guard
local PASSES, FAILS = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return (s:gsub("\r\n", "\n"))
end

local function lines_of(src)
	local t = {}
	for line in (src .. "\n"):gmatch("(.-)\n") do t[#t + 1] = line end
	return t
end

-- The names a file gives coop.sync, and the local constants that hold a scope of the world.
local function sync_names(src)
	local names = { sync = true }
	for name in src:gmatch("local%s+([%w_]+)%s*=[^\n]-%.sync") do names[name] = true end
	return names
end

local function is_world_scope(src, arg)
	if arg:match('^"') or arg:match("^'") then
		local scope = arg:match("^[\"']([^\"']*)")
		return scope == "session" or scope == "world"
	end
	-- SCOPE, or SCOPE, KEY = "session", "x" on one line
	for line in src:gmatch("[^\n]+") do
		if line:match("^%s*local%s") and line:find(arg, 1, true) and (line:find('"session"', 1, true) or line:find('"world"', 1, true)) then
			return true
		end
	end
	return false
end

-- The sites of a script: { line = n, what = "set" | "broadcast", fn = top level function or "", guarded = bool }
local function sites_of(src)
	local names = sync_names(src)
	local lines = lines_of(src)
	local sites = {}
	local fn, fn_at = "", 1
	local function body(from)
		local out = {}
		for i = from, #lines do
			out[#out + 1] = lines[i]
			if i > from and lines[i]:match("^end") then break end
		end
		return table.concat(out, "\n")
	end
	for i, line in ipairs(lines) do
		local name = line:match("^local%s+function%s+([%w_%.:]+)") or line:match("^function%s+([%w_%.:]+)")
		if name then fn, fn_at = name, i end
		local code = line:gsub("%-%-.*$", "")
		for receiver, method, at in code:gmatch("([%w_]+)%.([%w_]+)%(()") do
			local first = code:sub(at):match("^%s*([^,]+)") or ""
			if names[receiver] and (method == "broadcast" or (method == "set" and is_world_scope(src, first))) then
				local text = body(fn_at)
				local prior = table.concat(lines, "\n", fn_at, i - 1)
				local facade_guard = prior:match("\n%s*if coop_mode%.leads_here%(%) and not coop_mode%.decides_world%(%) then return ")
					or prior:match("\n%s*if coop_mode%.leads_for_world_elsewhere%(%) then return ")
				local guarded = text:find("is_map_server", 1, true) ~= nil or text:find("is_world_server", 1, true) ~= nil or
					text:find("-- Mk:", 1, true) ~= nil or facade_guard ~= nil
				sites[#sites + 1] = { line = i, what = method, fn = fn, guarded = guarded }
			end
		end
	end
	return sites
end

-- A call whose guard is its caller, with the place that proves it.
local THROUGH_CALLER = {
	["coop_world_weather.script:sync_set"] = function(src)
		local tick = src:match("local function tick%(%)(.-)\nend")
		return tick and tick:find("if coop_mode.decides_world() then\n\t\tif wm then host_tick(wm) end\n\t\twet_host_tick()", 1, true) ~= nil
	end,
}

local function script_list()
	local names = {}
	local pipe = assert(io.popen("dir /b gamedata\\scripts\\coop_*.script 2>nul"))
	for line in pipe:lines() do
		line = line:gsub("\r", "")
		if line ~= "" then names[#names + 1] = line end
	end
	pipe:close()
	return names
end

print("== the scanner itself")
do
	local bad = [[
local api = rawget(_G, "coop")
local function tell(list)
	local s = api.sync
	s.set("session", "k", list)
end
function ping(sync)
	sync.broadcast("x", {})
end
]]
	local sites = sites_of(bad)
	check(#sites == 2, "it finds a session write and a broadcast (" .. #sites .. ")")
	check(sites[1] and not sites[1].guarded and sites[1].fn == "tell", "a call without a word about Mk is not guarded")
	check(sites[2] and not sites[2].guarded and sites[2].what == "broadcast", "a broadcast neither")
	local good = [[
local SCOPE, KEY = "session", "k"
local function tell(sync, list)
	if P.is_map_server() then return sync.broadcast("x", list, { to = 1 }) end
	return sync.set(SCOPE, KEY, list)
end
local function cast(sync)
	-- Mk: the engine sends it to the players of its level
	return sync.broadcast("y", {})
end
local function mine(sync) return sync.set("player", "k", 1) end
local function loops(sync, list)
	if coop_mode.leads_here() and not coop_mode.decides_world() then return tell_map(list) end
	return sync.set(SCOPE, KEY, list)
end
local function loops_asked(sync, list)
	if coop_mode.leads_for_world_elsewhere() then return tell_map(list) end
	return sync.set(SCOPE, KEY, list)
end
]]
	sites = sites_of(good)
	check(#sites == 5, "a scope in a constant counts, a player's scope does not (" .. #sites .. ")")
	check(sites[1].guarded and sites[2].guarded and sites[3].guarded, "a branch or a comment guards a call")
	check(sites[4].guarded, "a facade branch that returns before the world write guards it")
	check(sites[5].guarded, "so does the facade's own question for that branch")
end

print("== the scripts")
do
	local total, seen = 0, {}
	local list = script_list()
	check(#list > 50, "the scripts are found (" .. #list .. ")")
	for _, name in ipairs(list) do
		local src = read("gamedata/scripts/" .. name)
		for _, s in ipairs(src and sites_of(src) or {}) do
			total = total + 1
			local key = name .. ":" .. s.fn
			seen[key] = true
			local caller = THROUGH_CALLER[key]
			local ok = s.guarded or (caller ~= nil and caller(src))
			check(ok, string.format("%s:%d (%s, in %s) says what it does on a map server", name, s.line, s.what, s.fn))
		end
	end
	check(total >= 5, "the known calls are found (" .. total .. ")")
	check(seen["coop_world_weather.script:sync_set"] == true, "the weather's write is among them")
end

print("== the engine answers what the scripts expect")
do
	local api = read("engine/src/xrGame/coop/coop_sync_api.cpp") or ""
	local cast = api:match("int l_broadcast%(lua_State%* L%)(.-)\n}\n") or ""
	check(cast:find("sn::may_broadcast(client(), net::host())", 1, true) ~= nil, "l_broadcast asks the facade for level authority")
	check(cast:find("sn::cast_reaches(", 1, true) ~= nil, "a cast bound to a level asks where the player stands")
	check(api:find("g_level_out", 1, true) ~= nil and api:find("net::host_send(o.peer, o.type, o.payload, Lane::Reliable);\n\t\tg_level_out.pop_front();", 1, true) ~= nil,
		"a map server's cast goes down to its players, not to the world")

	local cp = read("engine/src/xrGame/coop/coop_checkpoints.cpp") or ""
	local change = cp:match("void host_on_level_change%(.-\n}\n") or ""
	check(change:find("checkpoint::rides_with_host(", 1, true) ~= nil, "the host's level change writes arrivals only for who rides with him")
	local story = cp:match("bool host_story%(.-\n}\n") or ""
	check(story:find("checkpoint::story_from(", 1, true) ~= nil and story:find("record_far(c, Kind::Story, kNoSource)", 1, true) ~= nil,
		"a story checkpoint of a player elsewhere comes from the record of his body")

	local surv = read("engine/src/xrGame/coop/coop_survival.cpp") or ""
	local rules = surv:match("death::Rules console_rules%(%)(.-)\n}\n") or ""
	check(rules:find("friendly_fire", 1, true) ~= nil and rules:find("finish_downed", 1, true) ~= nil, "the party's rules are read from the console of the world server")
	local map_rules = surv:match("void map_on_rules%(.-\n}\n") or surv:match("void on_rules_msg%(.-\n}\n") or ""
	check(map_rules:find("g_coop_friendly_fire", 1, true) ~= nil and map_rules:find("set_finish_downed", 1, true) ~= nil,
		"a map server takes them")
end

print("== server clients have no playing world host")
for _, name in ipairs({ "coop_world_fight", "coop_npc_effects", "coop_world_weather" }) do
	local src = read("gamedata/scripts/" .. name .. ".script") or ""
	check(src:find("group_travels()", 1, true) ~= nil and src:find("led_by_host_process", 1, true) == nil,
		name .. ": uses group travel policy for the host's shared effects")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
