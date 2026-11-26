-- Anomaly Coop test: the Brain Scorcher for two sides (plan docs\plans\2026-11-16-storylines-per-faction.md section 4, stage 5):
-- gamedata\scripts\coop_srv_scorcher.script (coop_scorcher before step S4), its stock answers in gamedata\scripts\coop_conditions_stock.script,
-- gamedata\scripts\modxml_coop_scorcher.script, gamedata\configs\misc\task\tm_coop_scorcher.ltx
-- and the DLTX files gamedata\configs\scripts\**\mod_*_coop_scorcher.ltx merged over the stock logic files
-- (temp\stock_configs\configs\scripts\...) the way engine\src\xrCore\Xr_ini.cpp merges them (an ![section] overrides keys,
-- a [section] is new and must not exist in the base). Condlists are parsed and picked by the stock xr_logic code, copied below.
-- Machines: a world server, the map server of X10 and a player, each its own sealed copy of the script and of the Core's
-- coop_conditions_stock; the transport (the shares up/down, events) is played by the test. Step S4: the script starts
-- from coop_mode.when_srv (the machine's stand-in runs it in split mode only); in a group world and without co-op the stock
-- answers are coop_conditions_stock's. Not shipped. Run: tools\test_lua.cmd srv_scorcher
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
local function finish()
	print(string.format("%d passed, %d failed", PASSES, FAILS))
	os.exit(FAILS == 0 and 0 or 1)
end
local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end
local function section(name) print("== " .. name) end
string.trim = string.trim or function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local FLAG = "bar_deactivate_radar_done"

-------------------------------------------------------------------------------
-- The stock condlist parser and picker
-------------------------------------------------------------------------------
local STOCK_XR_LOGIC = [==[
-- temp/stock_scripts/scripts/xr_logic.script:6-10
local sign_add = "+" -- 1
local sign_sub = "-" -- 2
local sign_equ = "=" -- 3
local sign_neg = "!" -- 4
local sign_prb = "~" -- 5

-- temp/stock_scripts/scripts/xr_logic.script:365-499
function pick_section_from_condlist(obj, npc, condlist) -- New
	if not (condlist) then
		return ""
	end
	
	local npc_id = npc and (npc.id and type(npc.id) == "function" and npc:id() or npc.id)
	npc_id = npc_id == AC_ID and nil or npc_id -- we want only npc not actor
	local actor = db.actor 

	local sim = alife()	
	for i=1,#condlist do
		local cond = condlist[i]
		local infop_conditions_met = true
		
		if (cond[2]) then
			for j=1,#cond[2] do
				local infop = cond[2][j]
				if (infop[2] == 1) then
					if (infop[3]) then
						if (npc_id) then
							if not (npc:has_info(infop[1])) then 
								infop_conditions_met = false
								break
							end
						end
					else
						if (actor) then 
							if not (actor:has_info(infop[1])) then 
								infop_conditions_met = false
								break
							end
						else
						if not (sim:has_info(0,infop[1])) then
							infop_conditions_met = false
							break
						end
					end
					end
				elseif (infop[2] == 2) then 
					if (infop[3]) then
						if (npc_id) then 
							if (npc:has_info(infop[1])) then 
								infop_conditions_met = false
								break
							end
						end
					else
						if (actor) then 
							if (actor:has_info(infop[1])) then 
								infop_conditions_met = false
								break
							end
						else
						if (sim:has_info(0,infop[1])) then
							infop_conditions_met = false
							break
						end
					end
					end
				elseif (infop[2] == 3) then
					if not (xr_conditions[infop[1]]) then
						printf("pick_section_from_condlist xr_conditions fail! obj=%s functor=%s",npc and npc:name(),infop[1])
					elseif not xr_conditions[infop[1]](obj, npc, infop[3]) then
						infop_conditions_met = false
						break
					end
				elseif (infop[2] == 4) then
					if not (xr_conditions[infop[1]]) then
						printf("pick_section_from_condlist xr_conditions fail! obj=%s functor=%s",npc and npc:name(),infop[1])
					elseif xr_conditions[infop[1]](obj, npc, infop[3]) then
						infop_conditions_met = false
						break
					end
				elseif (infop[2] == 5) then 
					if (infop[3] and infop[3] < math.random(100)) then 
						infop_conditions_met = false
						break
					end
				end
			end 
		end
		
		if (infop_conditions_met) then 
			if (cond[3]) then 
				for j=1,#cond[3] do
					local infop = cond[3][j]
					if (infop[2] == 1) then 
						if (infop[3]) then
							if (npc_id) then
								if not (npc:has_info(infop[1])) then
									npc:give_info_portion(infop[1])
								end
							end
						else
							if (actor) then
								if not (actor:has_info(infop[1])) then
									actor:give_info_portion(infop[1])
								end
							else
							if not (sim:has_info(0,infop[1])) then 
								sim:give_info(0,infop[1])
							end
						end
						end
					elseif (infop[2] == 2) then 
						if (infop[3]) then
							if (npc_id) then
								if (npc:has_info(infop[1])) then
									npc:disable_info_portion(infop[1])
								end
							end
						else
							if (actor) then 
								if (actor:has_info(infop[1])) then
									actor:disable_info_portion(infop[1])
								end
							else
							if (sim:has_info(0,infop[1])) then 
								sim:disable_info(0,infop[1])
							end
						end
						end
					elseif (infop[2] == 3 or infop[2] == 4) then
						if not (xr_effects[infop[1]]) then
							printf("pick_section_from_condlist xr_effects fail! obj=%s functor=%s",npc and npc:name(),infop[1])
						end
						xr_effects[infop[1]](obj, npc, infop[3])
					end
				end
			end
			return cond[1] or ""
		end
	end
	return
end

-- temp/stock_scripts/scripts/xr_logic.script:629-632
function abort_syntax_error_in_cond(section,field,c)
	callstack()
	abort("section '%s': field '%s': syntax error in switch condition [%s]",section,field,c)
end

-- temp/stock_scripts/scripts/xr_logic.script:733-812
function extract_conditions(c,lst,n,index) -- New
	for sign,infop in c:gmatch("([=%-%+!~]+)([^=%-%+!~%s]+)") do
		if not (lst[n][index]) then
			lst[n][index] = {} -- because we don't want empty tables
		end
		if (sign == sign_add) then 
			table.insert(lst[n][index],{infop,1,(string.find(infop,"npcx_"))})
		elseif (sign == sign_sub) then
			table.insert(lst[n][index],{infop,2,(string.find(infop,"npcx_"))})
		elseif (sign == sign_equ or sign == sign_neg) then 
			a = string.find(infop,"(",1,true)
			if (a) then 
				b = string.find(infop,")",1,true)
				if (b) then 
					local params = infop:sub(a+1,b-1)
					infop = infop:sub(1,a-1) --.. infop:sub(b+1)
					local t
					for p in params:gmatch("%s*([^:]+)%s*") do
						if not (t) then 
							t = {}
						end 
						table.insert(t,tonumber(p) or p)
					end
					table.insert(lst[n][index],{infop,sign == sign_equ and 3 or 4,t})
				else
					abort_syntax_error_in_cond(section,field,c)
				end
			else
				table.insert(lst[n][index],{infop,sign == sign_equ and 3 or 4})
			end
		elseif (sign == sign_prb) then 
			table.insert(lst[n][index],{infop,5,tonumber(infop)})
		else 
			abort_syntax_error_in_cond(section,field,c)
		end
	end
end

local memoize_condlist = {} -- Because there are many condlist that are identical, they will have identical results
function parse_condlist(npc, section, field, src) -- New
	--if (src == nil or type(src) == "boolean") then
	if not (src and src ~= "") then 
		callstack()
		printe("!ERROR!! xr_logic.parse_condlist npc=%s section=%s field=%s src=%s",npc and npc:name(),section,field,src)
		return
	end
	
	if (memoize_condlist[src]) then 
		--printf("%s (%s:%s) | %s",npc and npc:name(),section,field,src)
		return memoize_condlist[src]
	end
	
	local lst = {}
	local n = 0
	for fld in src:gmatch("%s*([^,]+)%s*") do
		local a,b
		
		n = n + 1
		lst[n] = {}
		
		local a,b,c = string.find(fld, "{%s*(.*)%s*}")
		if (c) then
			fld = string.sub(fld,1,a-1) .. string.sub(fld,b+1)
			extract_conditions(c,lst,n,2)
		end
		
		a,b,c = string.find(fld, "%%%s*(.*)%s*%%")
		if (c) then
			fld = string.sub(fld,1,a-1) .. string.sub(fld,b+1)
			extract_conditions(c,lst,n,3)
		end
		
		fld = fld:trim()
		lst[n][1] = fld
	end
	
	memoize_condlist[src] = lst
	
	return lst
end
]==]

local XC, XE = {}, {}   -- xr_conditions / xr_effects of the parser's world
local EFFECTS = {}      -- names of the effects a pick ran
local PX = { db = { actor = nil }, alife = function() return nil end, xr_conditions = XC, xr_effects = XE,
	printf = function() end, printe = function() end, callstack = function() end,
	abort = function(...) error(string.format(...)) end }
setmetatable(PX, { __index = _G })
local chunk = assert(loadstring(STOCK_XR_LOGIC, "=stock xr_logic"))
setfenv(chunk, PX)
chunk()
local parse_condlist, pick = PX.parse_condlist, PX.pick_section_from_condlist

-- an actor of the parser's world
local INFOS = {}
local PACTOR = {
	has_info = function(_, n) return INFOS[n] == true end,
	give_info_portion = function(_, n) INFOS[n] = true end,
	disable_info_portion = function(_, n) INFOS[n] = nil end,
	id = function() return 0 end,
}
PX.db.actor = PACTOR
PX.AC_ID = 0
local STOCK_EFFECTS = { "play_sound_looped", "stop_sound_looped", "play_sound", "kill_npc", "spawn_object" }
for _, n in ipairs(STOCK_EFFECTS) do XE[n] = function() EFFECTS[#EFFECTS + 1] = n end end
XC.actor_has_item = function(a, n, p) return INFOS["item:" .. tostring(p and p[1])] == true end
XC.rad_pass_time = function() return true end

local function eval(src, infos)
	INFOS = {}
	for k, v in pairs(infos) do INFOS[k] = v end
	EFFECTS = {}
	local lst = parse_condlist(nil, "s", "f", src)
	local sect = pick(PACTOR, nil, lst)
	local fx = {}
	for k in pairs(INFOS) do if not infos[k] then fx[#fx + 1] = "+" .. k end end
	for k in pairs(infos) do if not INFOS[k] then fx[#fx + 1] = "-" .. k end end
	for _, e in ipairs(EFFECTS) do fx[#fx + 1] = "=" .. e end
	table.sort(fx)
	if sect == nil then sect = "<none>" end
	return tostring(sect), table.concat(fx, " ")
end

-------------------------------------------------------------------------------
-- ltx: the engine's DLTX merge (Xr_ini.cpp: StashCurrentSection 452-495, SortAndFilterSection 497-538: override keys win)
-------------------------------------------------------------------------------
local function parse_ltx(text)
	local secs, order, overrides, cur = {}, {}, {}, nil
	for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
		local line = raw:gsub("\r", "")
		local c = line:find(";", 1, true)
		local c2 = line:find("//", 1, true)
		if c2 and (not c or c2 < c) then c = c2 end
		if c then line = line:sub(1, c - 1) end
		line = line:trim()
		local over, name = line:match("^(!?)%[([^%]]+)%]")
		if name then
			cur = { name = name, keys = {}, over = over == "!" }
			if cur.over then overrides[#overrides + 1] = cur else
				if secs[name] then error("duplicate section " .. name) end
				secs[name] = cur
				order[#order + 1] = name
			end
		elseif cur and line ~= "" then
			local k, v = line:match("^([^=]-)%s*=%s*(.*)$")
			if k then cur.keys[k:trim()] = v:trim() else cur.keys[line] = "" end
		end
	end
	return secs, order, overrides
end

local function merged(stock_text, mod_text)
	local secs, order = parse_ltx(stock_text)
	local out = {}
	for n, s in pairs(secs) do
		out[n] = {}
		for k, v in pairs(s.keys) do out[n][k] = v end
	end
	if mod_text then
		local msecs, morder, movers = parse_ltx(mod_text)
		for _, n in ipairs(morder) do
			if out[n] then error("DLTX: duplicate section " .. n .. " not marked as an override") end
			out[n] = {}
			for k, v in pairs(msecs[n].keys) do out[n][k] = v end
		end
		for _, o in ipairs(movers) do
			if not out[o.name] then error("DLTX: override of a missing section " .. o.name) end
			for k, v in pairs(o.keys) do out[o.name][k] = v end
		end
	end
	return out
end

-- the outcomes of one section's switch lines: { key -> condlist src }
local SWITCH_KEYS = { "on_info", "on_game_timer", "on_signal", "on_press", "on_timer", "on_actor_inside", "on_actor_outside" }
local function switch_lines(sec)
	local out = {}
	for k, v in pairs(sec or {}) do
		local base = k:gsub("%d*$", "")
		for _, s in ipairs(SWITCH_KEYS) do
			if base == s then
				local src = v
				if base == "on_game_timer" or base == "on_timer" or base == "on_signal" then src = v:match("|%s*(.*)$") or v end
				out[k] = src
			end
		end
	end
	return out
end

-- every target a section can go to under the given infos; "" stays
local function targets(sections, name, infos)
	local list = {}
	local lines = switch_lines(sections[name])
	local keys = {}
	for k in pairs(lines) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local sect, fx = eval(lines[k], infos)
		list[#list + 1] = { key = k, sect = sect, fx = fx }
	end
	return list
end

local function cases()
	local out = {}
	for _, f in ipairs({ false, true }) do
		for _, item in ipairs({ false, true }) do
			local i = {}
			if f then i[FLAG] = true end
			if item then i["item:good_psy_helmet"] = true end
			out[#out + 1] = i
		end
	end
	return out
end

local function reach(sections, start)
	local seen, queue = { [start] = true }, { start }
	while #queue > 0 do
		local s = table.remove(queue, 1)
		for _, infos in ipairs(cases()) do
			for _, t in ipairs(targets(sections, s, infos)) do
				local to = t.sect
				if to ~= "" and to ~= "nil" and to ~= "<none>" and to ~= "true" and not seen[to] then
					seen[to] = true
					queue[#queue + 1] = to
				end
			end
		end
	end
	return seen
end

-------------------------------------------------------------------------------
-- Machines: sealed copies of coop_srv_scorcher.script and coop_conditions_stock.script
-------------------------------------------------------------------------------
local SCRIPT = assert(read_file("gamedata/scripts/coop_srv_scorcher.script"), "coop_srv_scorcher.script")
local STOCK = assert(read_file("gamedata/scripts/coop_conditions_stock.script"), "coop_conditions_stock.script")
local GAME_SEC = 0
local START_DAYS = 0
-- civil_from_days (H. Hinnant), the inverse of the script's day number, written here on its own
local function civil(z)
	z = z + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	if m <= 2 then y = y + 1 end
	return y, m, d
end
local function game_time()
	local s = GAME_SEC
	local days = START_DAYS + math.floor(s / 86400)
	local r = s % 86400
	return { get = function() local y, m, d = civil(days); return y, m, d, math.floor(r / 3600), math.floor(r % 3600 / 60), r % 60, 0 end }
end
-- 2012-05-30: a cooldown runs over a month's end
START_DAYS = 15490

local WIRE = {}
local function encode(t) WIRE[#WIRE + 1] = t; return "w" .. #WIRE end
local function decode(s) local n = tonumber(tostring(s):match("^w(%d+)$")); local t = n and WIRE[n]; if not t then return {} end
	local c = {} for k, v in pairs(t) do c[k] = v end return c end

local SENT = {}
-- opts (A-S4D): session = false: the engine's session is not up yet (no phase: no role, is_host false); dedicated = true: the
-- process was started with -coop_dedicated; saved = the table alife_storage_manager.get_state() gives (the save loaded before)
local function machine(role, mode, faction, opts)
	opts = opts or {}
	local m = { role = role, infos = {}, cbs = {}, cblist = {}, ups = {}, downs = {}, events = {}, storage = {}, objects = {}, switched = {},
		tasks = {}, msgs = {}, given = {}, srv_ran = 0, session = opts.session ~= false, dedicated = opts.dedicated, saved = opts.saved }
	local actor = {
		has_info = function(_, n) return m.infos[n] == true end,
		give_info_portion = function(_, n) m.infos[n] = true end,
		disable_info_portion = function(_, n) m.infos[n] = nil end,
		id = function() return 0 end,
		get_task = function(_, id) return m.tasks[id] end,
	}
	local api = nil
	if mode ~= "none" then
		api = {
			is_active = function() return m.session end,
			is_host = function() return m.session and (role == "world" or role == "map") end,
			is_map_server = function() return m.session and role == "map" end,
			is_client = function() return role == "client" end,
			is_dedicated = function() return m.dedicated == true end,
			levels = { split = function() return mode == "split" end },
			send_event = function(name, payload, target) SENT[#SENT + 1] = { name = name, payload = payload, target = target, from = m }; return true end,
		}
	end
	local env = {
		string = string, table = table, math = math, type = type, tostring = tostring, tonumber = tonumber, pairs = pairs,
		ipairs = ipairs, pcall = pcall, rawget = rawget, next = next, select = select, error = error, setmetatable = setmetatable,
		printf = function() end,
		time_global = function() return m.now or 0 end,
		game = { get_game_time = game_time, translate_string = function(s) return "T:" .. s end },
		db = { actor = actor, storage = m.storage },
		level = { object_by_id = function(id) return m.objects[id] end, name = function() return m.level end },
		xr_logic = { switch_to_section = function(obj, ini, sect) m.switched[#m.switched + 1] = { obj = obj, sect = sect }
			m.storage[obj.id].active_section = sect; return true end },
		task_manager = { get_task_manager = function() return { give_task = function(_, id, giver) m.given[#m.given + 1] = { id = id, giver = giver } end } end },
		xr_conditions = {}, xr_effects = {},
		-- the stock module's m_data: a fresh state's (no coop_scorcher) unless the save was loaded before (opts.saved)
		alife_storage_manager = { get_state = function() return m.saved or {} end },
		get_actor_true_community = function() return faction end,
		actor_menu = { set_msg = function(_, text) m.msgs[#m.msgs + 1] = text end },
		-- axr_main: every function registered for a name runs (m.cbs[name] runs them all); one taken out keeps its place as a no-op
		RegisterScriptCallback = function(n, f)
			local list = m.cblist[n] or {}
			m.cblist[n] = list
			list[#list + 1] = f
			m.cbs[n] = function(...) for _, g in ipairs(list) do g(...) end end
		end,
		UnregisterScriptCallback = function(n, f)
			for i, g in ipairs(m.cblist[n] or {}) do if g == f then m.cblist[n][i] = function() end end end
		end,
		coop = api,
		coop_main = { encode = encode, decode = decode, add_event_handler = function(n, f) m.events[n] = f end },
		-- the facade: the server layer answers in a split world (an active session with split levels), never in a group one
		coop_mode = {
			when_srv = function(fn)
				if mode == "split" then
					m.srv_ran = m.srv_ran + 1
					fn()
				end
				return true
			end,
			decides_world = function() return role == "world" and mode ~= "none" end,
			group_travels = function() return mode == "group" end,
			share_up = function(n, g, s) m.ups[n] = { get = g, set = s } return true end,
			share_down = function(n, g, s) m.downs[n] = { get = g, set = s } return true end,
		},
	}
	if mode ~= "none" then env.coop_faction = { split_mode = function() return mode == "split" end } end
	env._G = env
	-- the facade's two start helpers as coop_mode.script has them, over this machine's callbacks and save
	env.coop_mode.at_first_update = function(fn)
		local seen = false
		local function late()
			env.UnregisterScriptCallback("actor_on_update", late)
			if not seen then fn() end
		end
		env.RegisterScriptCallback("actor_on_first_update", function()
			seen = true
			fn()
		end)
		env.RegisterScriptCallback("actor_on_update", late)
	end
	env.coop_mode.late_load = function(load_state)
		local saved = env.alife_storage_manager.get_state()
		if type(saved) == "table" then load_state(saved) end
	end
	-- the helpers the script names, the real files in this machine's environment
	for _, name in ipairs({ "coop_util", "coop_srv_roles" }) do
		local hf = assert(loadfile("gamedata/scripts/" .. name .. ".script"))
		local henv = setmetatable({}, { __index = env })
		setfenv(hf, henv)
		hf()
		env[name] = henv
	end
	-- the Core's stock answers first (axr_main runs the scripts by name: coop_conditions_stock before coop_srv_scorcher)
	local cenv = setmetatable({}, { __index = env })
	local cf = assert(loadstring(STOCK, "=coop_conditions_stock.script"))
	setfenv(cf, cenv)
	cf()
	env.coop_conditions_stock = cenv
	cenv.on_game_start()
	local f = assert(loadstring(SCRIPT, "=coop_srv_scorcher.script"))
	setfenv(f, env)
	f()
	env.on_game_start()
	m.env, m.actor = env, actor
	return m
end

-- the shares: up from a map server (its level is the bridge's), down to it
local function up(map, world)
	local v = map.ups.scorcher and map.ups.scorcher.get()
	if v then world.ups.scorcher.set(v, map.level) end
end
local function down(world, map)
	local v = world.downs.scorcher.get()
	if v then map.downs.scorcher.set(v) end
end
local function deliver(world, client)
	for _, e in ipairs(SENT) do
		if e.from == world and e.name == "coop_scorch" and (e.target == -1 or e.target == 0) then client.events.coop_scorch(e.payload, 0) end
	end
end

-------------------------------------------------------------------------------
section("state machine on the world server")
-------------------------------------------------------------------------------
local W = machine("world", "split")
W.infos[FLAG] = true -- a Monolith world: the Scorcher starts off
check(W.env.state().on == false and W.env.state().flips == 0, "start: off (from the flag), no flips")
check(W.env.apply_flip(true) == true and W.env.state().on == true and not W.infos[FLAG], "off -> on: the flip counts, the flag is dropped")
check(W.env.apply_flip(false) == false and W.env._test.stats().refused == 1, "a flip inside the cooldown is refused")
GAME_SEC = W.env.COOLDOWN_SEC - 60
check(W.env.apply_flip(false) == false, "one minute before three game days: still refused (a month's end is crossed)")
GAME_SEC = W.env.COOLDOWN_SEC
check(W.env.apply_flip(false) == true and W.infos[FLAG] == true and W.env.state().flips == 2, "on -> off after three game days: the flag is back")
check(W.env.apply_flip(false) == false, "off -> off is no flip")
GAME_SEC = GAME_SEC + W.env.COOLDOWN_SEC
check(W.env.apply_flip(true) == true and not W.env.state().locked, "flip 3: not locked yet")
GAME_SEC = GAME_SEC + W.env.COOLDOWN_SEC
check(W.env.apply_flip(false) == true and W.env.state().locked == true and W.env.state().flips == 4, "flip 4 locks the switch")
GAME_SEC = GAME_SEC + 100 * W.env.COOLDOWN_SEC
check(W.env.apply_flip(true) == false and W.env.state().on == false, "locked: no flip ever again")
check(W.env.c_can_on() == false and W.env.c_can_off() == false and W.env.c_ready() == false and W.env.c_locked() == true, "locked: every condition refuses")
check(W.env.MAX_FLIPS == 4 and W.env.COOLDOWN_SEC == 259200, "the rules are named constants (4 flips, 3 game days)")

-------------------------------------------------------------------------------
section("save and load")
-------------------------------------------------------------------------------
local m_data = {}
W.cbs.save_state(m_data)
local W2 = machine("world", "split")
W2.cbs.load_state(m_data)
local s1, s2 = W.env.state(), W2.env.state()
check(s1.on == s2.on and s1.flips == s2.flips and s1.last == s2.last and s1.locked == s2.locked, "the state is kept over save / load")
local m_bad = { coop_scorcher = { on = "yes", flips = 99 } }
local W3 = machine("world", "split")
W3.cbs.load_state(m_bad)
check(W3.env.state().flips == 0, "a broken record in the save is not taken")
local C0 = machine("client", "split", "monolith")
C0.cbs.load_state(m_data)
check(C0.env.state().flips == 0, "a player's machine does not take the world's record from a save")
-- A-S4D: a world server (-coop_dedicated) loads its save before its session starts (the session comes after its world is up).
-- Its server layer answers from the start (coop_srv_mode), so the handler is in before the load, with no session yet.
check(s1.flips == 4 and s1.locked == true and s1.last ~= nil, "(the saved state has flips, the lock and the last flip)")
local function same(a, b) return a.on == b.on and a.flips == b.flips and a.last == b.last and a.locked == b.locked end
local Wpre = machine("world", "split", nil, { session = false, dedicated = true })
Wpre.cbs.load_state(m_data)
Wpre.session = true
check(same(Wpre.env.state(), s1), "the world server loads its save before its session: its flips, lock and last flip are kept")
local Wlate = machine("world", "split", nil, { saved = m_data })
check(same(Wlate.env.state(), s1), "a save loaded before when_srv ran: read from alife_storage_manager.get_state() then")
local Wfresh = machine("world", "split", nil, { session = false, dedicated = true, saved = {} })
check(Wfresh.env.state().flips == 0 and Wfresh.env.state().last == nil and not Wfresh.env.state().locked,
	"a fresh state's m_data at when_srv: nothing to take")
local Wbad = machine("world", "split", nil, { session = false, dedicated = true })
Wbad.cbs.load_state(m_bad)
check(Wbad.env.state().flips == 0, "before the session too, a broken record is not taken")
local Cpre = machine("client", "split", "monolith", { session = false, saved = m_data })
Cpre.cbs.load_state(m_data)
Cpre.session = true
check(Cpre.env.state().flips == 0, "a player's machine before its session takes nothing from a save, at when_srv or at the load")
local Mpre = machine("map", "split", nil, { session = false, saved = m_data })
Mpre.cbs.load_state(m_data)
Mpre.session = true
check(Mpre.env.state().flips == 0, "a map server takes nothing from a save either: the world sends its state down")

-------------------------------------------------------------------------------
section("map server, reports, forged words")
-------------------------------------------------------------------------------
GAME_SEC = 0
local Wd = machine("world", "split")
Wd.infos[FLAG] = true
local M = machine("map", "split")
M.level = "l10u_bunker"
down(Wd, M)
check(M.env.state().on == false and M.infos[FLAG] == true, "the map server takes the world's state and its own flag follows")
-- the switch on the map server: the condlist dropped the flag, then the effect
M.infos[FLAG] = nil
M.env.xr_effects.coop_scorcher_flipped(nil, nil, { "on" })
up(M, Wd)
check(Wd.env.state().on == true and Wd.env.state().flips == 1 and not Wd.infos[FLAG], "a flip of the X10 map server counts on the world")
up(M, Wd)
check(Wd.env.state().flips == 1, "the same report again changes nothing")
local Z = machine("map", "split")
Z.level = "zaton"
down(Wd, Z)
Z.env.xr_effects.coop_scorcher_flipped(nil, nil, { "off" })
GAME_SEC = 10 * Wd.env.COOLDOWN_SEC
up(Z, Wd)
check(Wd.env.state().on == true and Wd.env._test.stats().forged >= 1, "a report from another level's map server is ignored")
Wd.ups.scorcher.set({ on = false, base = 0 }, "l10u_bunker")
check(Wd.env.state().on == true, "a report made on an old state (base 0) is ignored")
Wd.ups.scorcher.set({ on = "off", base = 1 }, "l10u_bunker")
check(Wd.env.state().on == true, "a report of a wrong type is ignored")
local Cf = machine("client", "split", "freedom")
Cf.events.coop_scorch(encode({ on = false, flips = 0, locked = false }), 7)
check(Cf.env.state().flips == 0, "a player's machine takes no word from another peer than 0")
Wd.events.coop_scorch(encode({ on = false, flips = 3, locked = true }), 0x105)
check(Wd.env.state().flips == 1 and Wd.env.state().on == true, "the world takes no state from an event")
M.events.coop_scorch(encode({ on = false, flips = 3, locked = true }), 0)
check(M.env.state().flips == 1, "a map server takes no state from an event (only the share)")
-- refused report: the map server is put back
GAME_SEC = 10 * Wd.env.COOLDOWN_SEC + 10
down(Wd, M)
M.infos[FLAG] = true
M.env.xr_effects.coop_scorcher_flipped(nil, nil, { "off" })
Wd.env.apply_flip(false) -- the world's own switch was faster (same frame elsewhere)
up(M, Wd)
check(Wd.env.state().flips == 2, "two flips for one turn are not counted twice")
-- the map server re-arms the dead objects when the world says ON
GAME_SEC = 20 * Wd.env.COOLDOWN_SEC
Wd.env.apply_flip(true)
local ini = { section_exist = function() return true end }
M.storage[11] = { ini_filename = "scripts\\radar\\rad_psy_zone_1.ltx", ini = ini, active_section = nil }
M.storage[12] = { ini_filename = "scripts\\radar\\rad_antenna_particle_02.ltx", ini = ini, active_section = "sr_idle@nil" }
M.storage[13] = { ini_filename = "scripts\\radar\\rad_psy_zone_1.ltx", ini = ini, active_section = "sr_psy_antenna@bad_helmet" }
M.storage[14] = { ini_filename = "scripts\\bunker\\bunker_primary_switcher.ltx", ini = ini, active_section = "ph_button@rad_off" }
M.storage[15] = { ini_filename = "scripts\\bunker\\bun_krovosos_nest_logic.ltx", ini = ini, active_section = nil }
for id = 11, 15 do M.objects[id] = { id = id } end
down(Wd, M)
check(M.storage[11].active_section == "sr_psy_antenna@no_helmet" and M.storage[12].active_section == "sr_idle@check_switch",
	"ON: a field and an antenna saved dead are re-armed")
check(M.storage[13].active_section == "sr_psy_antenna@bad_helmet", "ON: a working field is left alone")
check(M.storage[14].active_section == "ph_button@rad_on", "ON: the switch shows the world's state")
check(M.storage[15].active_section == nil, "an irreversible file (the bloodsucker nest) is not touched")
check(not M.infos[FLAG], "ON: the map server's flag is dropped")
local G = machine("map", "group")
G.storage[11] = { ini_filename = "scripts\\radar\\rad_psy_zone_1.ltx", ini = ini, active_section = nil }
G.objects[11] = { id = 11 }
check(G.env.rearm() == 0 and G.storage[11].active_section == nil, "group world: nothing is re-armed")

-------------------------------------------------------------------------------
section("players' machines and the dialog conditions")
-------------------------------------------------------------------------------
GAME_SEC = 0
local Wp = machine("world", "split")
Wp.infos[FLAG] = true
Wp.now = 0
Wp.cbs.actor_on_update()
local Cm = machine("client", "split", "monolith")
local Cfr = machine("client", "split", "freedom")
SENT = {}
Wp.now = 100000
Wp.cbs.actor_on_update()
deliver(Wp, Cm)
deliver(Wp, Cfr)
check(Cm.env.state().on == false and Cm.env.c_actor_monolith() == true, "a Monolith player learns: off")
check(Cm.env.dlg_can_offer_on() == true, "Charon offers: Monolith, split, off, ready")
check(Cfr.env.dlg_can_offer_on() == false, "Charon does not offer to Freedom")
Cm.tasks[Cm.env.ON_TASK] = {}
check(Cm.env.dlg_can_offer_on() == false, "not while the task is held")
Cm.tasks[Cm.env.ON_TASK] = nil
Cm.env.dlg_give_on({ id = function() return 77 end }, Cm.actor)
check(#Cm.given == 1 and Cm.given[1].id == "coop_scorcher_on_task" and Cm.given[1].giver == 77, "the dialog's action gives the task with Charon as giver")
Wp.env.apply_flip(true)
SENT = {}
Wp.now = 300000
Wp.cbs.actor_on_update()
deliver(Wp, Cm)
check(Cm.env.dlg_can_offer_on() == false, "not while it is on")
GAME_SEC = Wp.env.COOLDOWN_SEC - 1
check(Wp.env.apply_flip(false) == false, "one second before the cooldown ends the world refuses")
GAME_SEC = Wp.env.COOLDOWN_SEC + 10
check(Wp.env.apply_flip(false) == true, "after it the flip counts")
SENT = {}
Wp.now = 600000
Wp.cbs.actor_on_update()
deliver(Wp, Cm)
deliver(Wp, Cfr)
check(Cm.env.dlg_can_offer_on() == false and Cfr.env.dlg_off_offer_ok() == false, "inside the cooldown neither side is offered")
GAME_SEC = 2 * Wp.env.COOLDOWN_SEC + 20
check(Cm.env.dlg_can_offer_on() == true and Cfr.env.dlg_off_offer_ok() == true, "after the cooldown both offers come back")
local Mono = machine("map", "split")
check(Mono.env.c_actor_monolith() == false, "a map server's actor is nobody, not Monolith")
local Dw = machine("world", "split", "monolith")
Dw.dedicated = true
check(Dw.env.c_actor_monolith() == false, "a dedicated world server's actor is nobody")

-------------------------------------------------------------------------------
section("every condition and effect outside split mode")
-------------------------------------------------------------------------------
GAME_SEC = 0
for _, mode in ipairs({ "group", "none" }) do
	local x = machine("world", mode, "monolith")
	local c = x.env.xr_conditions
	local fx = x.env.xr_effects
	check(c.coop_split_mode() == false and c.coop_scorcher_ready() == true and c.coop_scorcher_can_off() == true
		and c.coop_scorcher_can_on() == false and c.coop_scorcher_locked() == false and c.coop_actor_monolith() == false,
		mode .. ": the conditions answer the stock (not split, ready, can off, cannot on, not locked, nobody is Monolith)")
	local cs = x.env.coop_conditions_stock
	check(x.srv_ran == 0 and x.cbs.save_state == nil and x.cbs.actor_on_update == nil and next(x.events) == nil and next(x.ups) == nil,
		mode .. ": S4: nothing of the server's script ran (no when_srv, no callback, event or shared table)")
	check(c.coop_split_mode == rawget(c, "coop_split_mode") and debug.getinfo(c.coop_split_mode, "S").source == "=coop_conditions_stock.script"
		and debug.getinfo(fx.coop_scorcher_flipped, "S").source == "=coop_conditions_stock.script", mode .. ": S4: they are coop_conditions_stock's")
	check(cs.dlg_off_offer_ok() == true and cs.dlg_can_offer_on() == false and cs.dlg_give_on() == nil and #x.given == 0,
		mode .. ": S4: the dialogs' functions of coop_conditions_stock answer the stock")
	x.infos[FLAG] = nil
	fx.coop_scorcher_flipped(nil, nil, { "off" })
	fx.coop_scorcher_refused()
	fx.coop_scorcher_task_taken()
	fx.coop_scorcher_task_done()
	check(x.env.state().flips == 0 and #x.msgs == 0 and not x.infos[FLAG], mode .. ": the effects do nothing")
	check(x.env.dlg_off_offer_ok() == true and x.env.dlg_can_offer_on() == false, mode .. ": Sakharov offers as in the stock, Charon never")
	x.infos[FLAG] = true
	check(x.env.ending_ok("monolith") == true and x.env.ending_ok("freedom") == true, mode .. ": ending_ok is the stock rule (off) for every faction")
	check(cs.ending_ok("monolith") == true and cs.ending_ok("freedom") == true, mode .. ": S4: so is coop_conditions_stock's")
	x.infos[FLAG] = nil
	check(x.env.ending_ok("monolith") == false and x.env.ending_ok("stalker") == false, mode .. ": scorcher on: no ending for anybody")
	check(cs.ending_ok("monolith") == false and cs.ending_ok("stalker") == false, mode .. ": S4: the same in coop_conditions_stock")
end

-------------------------------------------------------------------------------
section("ending_ok in split mode")
-------------------------------------------------------------------------------
local E = machine("world", "split")
local Ecs = E.env.coop_conditions_stock
check(E.srv_ran == 1 and Ecs.ending_ok == E.env.ending_ok and Ecs.dlg_can_offer_on == E.env.dlg_can_offer_on
	and Ecs.dlg_give_on == E.env.dlg_give_on and Ecs.dlg_off_offer_ok == E.env.dlg_off_offer_ok
	and debug.getinfo(E.env.xr_conditions.coop_split_mode, "S").source == "=coop_srv_scorcher.script",
	"S4: split: the server's script put its condlist and dialog functions over the stock ones of coop_conditions_stock")
E.infos[FLAG] = true
check(E.env.ending_ok("monolith") == false and E.env.ending_ok("freedom") == true and E.env.ending_ok("dolg") == true, "off: every faction but Monolith")
E.env.apply_flip(true)
check(E.env.ending_ok("monolith") == true and E.env.ending_ok("freedom") == false, "on: Monolith only")

-------------------------------------------------------------------------------
section("the logic files: stock vs merged with the DLTX file")
-------------------------------------------------------------------------------
local STOCKDIR = "temp/stock_configs/configs/scripts/"
local GAMMADIR = "temp/gamma_ref/configs/scripts/"
local FILES = {
	"radar/rad_psy_zone_1.ltx", "radar/rad_psy_zone_2.ltx", "radar/rad_psy_zone_3.ltx", "radar/rad_psy_zone_8.ltx",
	"pripyat/pri_psy_zone_1.ltx", "stancia_1/aes1_psy_zone_1.ltx", "stancia_2/aes2_psy_zone_1.ltx", "bunker/bun_psi_radiotion_75.ltx",
	"radar/rad_antenna_particle_01.ltx", "radar/rad_antenna_particle_02.ltx", "radar/rad_antenna_particle_03.ltx", "radar/rad_antenna_particle_04.ltx",
	"radar/rad_sound_drone.ltx", "radar/rad_sound_thunder.ltx",
	"bunker/bun_space_restrictor_sound1.ltx", "bunker/bun_space_restrictor_sound1_0000.ltx", "bunker/bun_space_restrictor_sound1_0001.ltx",
	"bunker/bun_space_restrictor_sound1_0002.ltx", "bunker/bun_space_restrictor_sound1_0003.ltx", "bunker/bun_space_restrictor_sound1_0004.ltx",
	"bunker/bunker_primary_switcher.ltx",
}
local function mod_path(rel)
	local dir, stem = rel:match("^(.*)/([^/]+)%.ltx$")
	return "gamedata/configs/scripts/" .. dir .. "/mod_" .. stem .. "_coop_scorcher.ltx"
end
-- the mod's own conditions: what the world gives outside split mode, and absent (the script failed to load)
local OUTSIDE = { coop_split_mode = false, coop_scorcher_ready = true, coop_scorcher_can_off = true, coop_scorcher_can_on = false,
	coop_scorcher_locked = false, coop_actor_monolith = false }
local function set_conditions(t)
	for k in pairs(OUTSIDE) do XC[k] = nil end
	XE.coop_scorcher_flipped, XE.coop_scorcher_refused = nil, nil
	if t then
		for k, v in pairs(t) do XC[k] = function() return v end end
		XE.coop_scorcher_flipped = function() EFFECTS[#EFFECTS + 1] = "coop_scorcher_flipped" end
		XE.coop_scorcher_refused = function() EFFECTS[#EFFECTS + 1] = "coop_scorcher_refused" end
	end
end

local all_same, all_reach = true, true
for _, rel in ipairs(FILES) do
	local gamma = read_file(GAMMADIR .. rel)
	local stock_text = gamma or read_file(STOCKDIR .. rel)
	local mod_text = read_file(mod_path(rel))
	check(stock_text ~= nil and mod_text ~= nil, rel .. ": the stock file and the DLTX file exist")
	if stock_text and mod_text then
		check(not mod_text:find("\r", 1, true), rel .. ": the DLTX file has LF endings like the mod's other ltx")
		local ok, m = pcall(merged, stock_text, mod_text)
		check(ok, rel .. ": merges by the DLTX rules (" .. tostring(ok or m) .. ")")
		local s = merged(stock_text, nil)
		local start = s.logic and s.logic.active
		for _, conds in ipairs({ OUTSIDE, false }) do
			set_conditions(conds or nil)
			local label = conds and "outside split mode" or "with the mod's functions missing"
			local same = true
			for name in pairs(s) do
				for _, infos in ipairs(cases()) do
					local a, b = targets(s, name, infos), targets(m, name, infos)
					local ia = {}
					for _, t in ipairs(a) do ia[t.key] = t end
					for _, t in ipairs(b) do
						local st = ia[t.key]
						if st then
							if st.sect ~= t.sect or st.fx ~= t.fx then same = false; print("    " .. name .. "." .. t.key .. ": " .. st.sect .. "/" .. st.fx .. " vs " .. t.sect .. "/" .. t.fx) end
						elseif not ((t.sect == "" or t.sect == "<none>") and t.fx == "") then
							same = false; print("    new line " .. name .. "." .. t.key .. " moves to " .. t.sect .. " " .. t.fx)
						end
					end
				end
			end
			check(same, rel .. ": " .. label .. " every switch line gives the stock outcome, new lines do nothing")
			all_same = all_same and same
			local r1, r2 = reach(s, start), reach(m, start)
			local eq = true
			for k in pairs(r1) do eq = eq and r2[k] == true end
			for k in pairs(r2) do eq = eq and r1[k] == true end
			check(eq, rel .. ": " .. label .. " the reachable sections are the stock ones")
			all_reach = all_reach and eq
		end
		-- split mode: the new transitions
		set_conditions({ coop_split_mode = true, coop_scorcher_ready = true, coop_scorcher_can_off = true, coop_scorcher_can_on = true,
			coop_scorcher_locked = false, coop_actor_monolith = false })
		if rel:find("psy") or rel:find("psi") then
			local dead = s["sr_psy_antenna@no_helmet"].on_info2:match("}%s*(%S+)$")
			local t = targets(m, "sr_psy_antenna@no_helmet", { [FLAG] = true })
			local went = false
			for _, x in ipairs(t) do if x.key == "on_info2" then went = x.sect == "sr_idle@coop_scorcher_off" end end
			check(went, rel .. ": split, Scorcher off: the field waits in sr_idle@coop_scorcher_off instead of " .. tostring(dead))
			local back = targets(m, "sr_idle@coop_scorcher_off", {})
			check(back[1] and back[1].sect == "sr_psy_antenna@no_helmet", rel .. ": split, Scorcher on again: the field comes back")
			set_conditions({ coop_split_mode = true, coop_actor_monolith = true })
			local mono = targets(m, "sr_psy_antenna@no_helmet", {})
			local imm = false
			for _, x in ipairs(mono) do if x.key == "on_info3" then imm = x.sect == "sr_idle@coop_monolith" end end
			check(imm, rel .. ": split, a Monolith actor: the field goes idle (immunity)")
			set_conditions({ coop_split_mode = true, coop_actor_monolith = false })
			local un = targets(m, "sr_idle@coop_monolith", {})
			check(un[1] and un[1].sect == "sr_psy_antenna@no_helmet", rel .. ": split, not Monolith: the field works again")
		elseif rel:find("switcher") then
			local on = targets(m, "ph_button@rad_on", {})
			check(on[1].sect == "ph_button@rad_off" and on[1].fx == "+" .. FLAG .. " =coop_scorcher_flipped", rel .. ": split, ready: off, the flag and the flip")
			local off = targets(m, "ph_button@rad_off", { [FLAG] = true })
			check(off[1].sect == "ph_button@rad_on" and off[1].fx == "-" .. FLAG .. " =coop_scorcher_flipped", rel .. ": split, ready: the re-armed switch turns it on")
			set_conditions({ coop_split_mode = true, coop_scorcher_can_off = false, coop_scorcher_can_on = false })
			local r = targets(m, "ph_button@rad_on", {})
			check(r[1].sect == "" and r[1].fx == "=coop_scorcher_refused", rel .. ": split, cooldown or lock: the switch refuses and stays")
			r = targets(m, "ph_button@rad_off", { [FLAG] = true })
			check(r[1].sect == "" and r[1].fx == "=coop_scorcher_refused", rel .. ": split, cooldown or lock: the off switch refuses too")
		else
			local name = s["sr_idle@nil"] and "sr_idle@nil" or "sr_idle@off"
			local found = false
			for _, cand in ipairs({ "sr_idle@nil", "sr_idle@coop_scorcher_off" }) do
				if m[cand] then
					for _, x in ipairs(targets(m, cand, {})) do if x.sect == m.logic.active or x.sect == "sr_idle@on" or x.sect == "sr_idle@check_switch" then found = true end end
				end
			end
			check(found, rel .. ": split, Scorcher on again: the object leaves its dead section")
		end
	end
end
set_conditions(OUTSIDE)

-------------------------------------------------------------------------------
section("the 'on' task (stock task loader rules, task_objects.script:34-119) and the 'off' task's override")
-------------------------------------------------------------------------------
local TM = read_file("gamedata/configs/misc/task/tm_coop_scorcher.ltx")
check(TM ~= nil and not TM:find("\r", 1, true), "tm_coop_scorcher.ltx exists, LF endings")
local tsecs, _, tover = parse_ltx(TM or "")
local t = tsecs.coop_scorcher_on_task and tsecs.coop_scorcher_on_task.keys
check(t ~= nil, "section coop_scorcher_on_task")
check(not ("coop_scorcher_on_task"):match("^.+_task_%d") and not ("coop_scorcher_on_task"):match("^drx_sl_") and not ("coop_scorcher_on_task"):match("^simulation_task_"),
	"its id matches none of the task manager's random patterns (task_manager.ltx notes)")
check(t and t.title and t.descr and t.icon and tonumber(t.prior) and t.storyline == "true" and t.condlist_0 and t.target, "title, descr, icon, prior, storyline, target, condlist_0")
local okp = true
for _, k in ipairs({ "condlist_0", "condlist_1", "on_init", "on_complete" }) do
	local ok = pcall(parse_condlist, nil, "coop_scorcher_on_task", k, t and t[k] or "")
	okp = okp and ok and t and t[k] ~= nil
end
check(okp, "condlist_0/1, on_init, on_complete parse with the stock parser")
set_conditions(OUTSIDE)
check(eval(t.condlist_0, {}) == "complete" and eval(t.condlist_0, { [FLAG] = true }) == "<none>", "complete when the flag is dropped")
check(eval(t.condlist_1, {}) == "", "outside split: condlist_1 never fails")
set_conditions(nil)
check(eval(t.condlist_1, {}) == "", "with the function missing: condlist_1 never fails")
set_conditions({ coop_scorcher_locked = true })
check(eval(t.condlist_1, {}) == "fail", "locked: fails")
set_conditions(OUTSIDE)
local fxok = t.on_init:find("=coop_scorcher_task_taken", 1, true) and t.on_complete:find("=coop_scorcher_task_done", 1, true)
check(fxok, "on_init / on_complete call the module's effects")
local strings_rus = read_file("gamedata/configs/text/rus/st_coop_news.xml") or ""
local strings_eng = read_file("gamedata/configs/text/eng/st_coop_news.xml") or ""
local function has_string(id) return strings_rus:find('id="' .. id .. '"', 1, true) ~= nil and strings_eng:find('id="' .. id .. '"', 1, true) ~= nil end
check(has_string(t.title) and has_string(t.descr), "title and descr are in st_coop_news, both languages")
local radar = read_file("temp/stock_configs/configs/misc/task/tm_radar.ltx")
local rs = merged(radar, TM:gsub("%[coop_scorcher_on_task%].-\n\n", "", 1))
local off = rs.turn_off_brain_scorcher
check(off and off.condlist_0 == "{+" .. FLAG .. "} complete" and off.condlist_1 == "{!coop_scorcher_locked}, fail" and off.on_complete == "%=stalker_ceasefire()%",
	"turn_off_brain_scorcher: the stock keys stay, condlist_1 is added")
set_conditions(nil)
check(eval(off.condlist_1, {}) == "", "the off task outside the mod / with the function missing: never fails")
set_conditions({ coop_scorcher_locked = true })
check(eval(off.condlist_1, {}) == "fail", "the off task fails at the lock")
set_conditions(OUTSIDE)

-------------------------------------------------------------------------------
section("the dialogs (DXML)")
-------------------------------------------------------------------------------
local XS = assert(read_file("gamedata/scripts/modxml_coop_scorcher.script"))
-- a stand-in of the dxml object over the real file text: query("dialog[id=X]"), query("dialog[id=X] > precondition"), getText,
-- insertFromXMLString(text[, where, pos])
local function fake_xml(text)
	local o = { text = text, inserted = {} }
	function o:query(sel)
		local id, child = sel:match("^dialog%[id=([^%]]+)%]%s*>%s*(%w+)$")
		if not id then id = sel:match("^dialog%[id=([^%]]+)%]$") end
		if not id then return {} end
		local body = self.text:match('<dialog id="' .. id:gsub("%p", "%%%0") .. '">(.-)</dialog>')
		if not body then return {} end
		if not child then return { { id = id } } end
		local out = {}
		for v in body:gmatch("<" .. child .. ">(.-)</" .. child .. ">") do out[#out + 1] = { text = v } end
		return out
	end
	function o:getText(el) return el.text end
	function o:insertFromXMLString(s, where, pos)
		self.inserted[#self.inserted + 1] = { s = s, where = where, pos = pos }
		if where and where.id then
			local pat = '<dialog id="' .. where.id:gsub("%p", "%%%0") .. '">'
			self.text = self.text:gsub(pat, function(h) return h .. s end, 1)
		else
			self.text = self.text .. s
		end
	end
	return o
end
local xcbs = {}
local xenv = { string = string, table = table, ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
	rawget = function(t, k) if k == "coop" then return {} end return rawget(t, k) end,
	RegisterScriptCallback = function(n, f) xcbs[n] = f end }
xenv._G = xenv
local xf = assert(loadstring(XS, "=modxml_coop_scorcher.script"))
setfenv(xf, xenv)
xf()
xenv.on_xml_read()
check(xcbs.on_xml_read ~= nil and xcbs.on_specific_character_dialog_list ~= nil, "co-op exe: both callbacks are registered")
local DLG = read_file("temp/stock_configs/configs/gameplay/dialogs.xml")
local dx = fake_xml(DLG)
xcbs.on_xml_read([[gameplay\dialogs.xml]], dx)
check(#dx.inserted == 1 and dx.text:find('<dialog id="coop_scorcher_on_dialog">', 1, true) ~= nil, "the dialog is added to the real dialogs.xml")
xcbs.on_xml_read([[gameplay\dialogs.xml]], dx)
check(#dx.inserted == 1, "a second read adds nothing")
local d = xenv.DIALOG
local missing = {}
for id in d:gmatch("<text>(.-)</text>") do if not has_string(id) then missing[#missing + 1] = id end end
check(#missing == 0, "every phrase text is in st_coop_news, both languages (" .. table.concat(missing, ",") .. ")")
local probe = machine("client", "split", "monolith")
local fns_ok = true
local pcs = probe.env.coop_conditions_stock
for fn in d:gmatch("<precondition>coop_conditions_stock%.([%w_]+)</precondition>") do fns_ok = fns_ok and type(pcs[fn]) == "function" end
for fn in d:gmatch("<action>coop_conditions_stock%.([%w_]+)</action>") do fns_ok = fns_ok and type(pcs[fn]) == "function" end
check(fns_ok and d:find("coop_conditions_stock.dlg_can_offer_on", 1, true) and not d:find("coop_srv_", 1, true),
	"its precondition and action are coop_conditions_stock's (the Core names no server script)")
local YAN = read_file("temp/stock_configs/configs/gameplay/dialogs_yantar.xml")
local yx = fake_xml(YAN)
xcbs.on_xml_read([[gameplay\dialogs_yantar.xml]], yx)
local gated = 0
for _, id in ipairs({ "yan_stalker_sakharov_bad_psi_helmet", "yan_stalker_sakharov_good_psi_helmet" }) do
	for _, p in ipairs(yx:query("dialog[id=" .. id .. "] > precondition")) do if p.text == "coop_conditions_stock.dlg_off_offer_ok" then gated = gated + 1 end end
end
check(gated == 2, "Sakharov's two helmet dialogs (they give turn_off_brain_scorcher) get the gate")
xcbs.on_xml_read([[gameplay\dialogs_yantar.xml]], yx)
check(#yx.inserted == 2, "a second read gates nothing twice")
local list = { items = {} }
function list:has(id) for _, v in ipairs(self.items) do if v == id then return true end end return false end
function list:add_first(id) table.insert(self.items, 1, id) end
function list:add(id) self.items[#self.items + 1] = id end
xcbs.on_specific_character_dialog_list("lider_monolith_haron", list)
xcbs.on_specific_character_dialog_list("lider_monolith_haron", list)
xcbs.on_specific_character_dialog_list("yan_stalker_sakharov", list)
check(#list.items == 1 and list.items[1] == "coop_scorcher_on_dialog", "only Charon gets it, once")
local CH = read_file("temp/stock_configs/configs/gameplay/character_desc_pripyat.xml") or ""
check(CH:find('<specific_character id="lider_monolith_haron"', 1, true) ~= nil, "Charon's id is the real one (character_desc_pripyat.xml)")
local xenv2 = { rawget = function() return nil end, RegisterScriptCallback = function(n) xcbs["sp_" .. n] = true end }
xenv2._G = xenv2
local xf2 = assert(loadstring(XS, "=modxml_coop_scorcher.script"))
setfenv(xf2, xenv2)
xf2()
xenv2.on_xml_read()
check(next(xcbs) and not xcbs.sp_on_xml_read, "an exe without co-op: nothing is registered")

finish()
