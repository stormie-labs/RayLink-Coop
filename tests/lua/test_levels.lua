-- Anomaly Coop test (split levels, F3a task 3): the gates of the levels, gamedata\scripts\coop_levels.script, over the table
-- gamedata\configs\coop_levels_together.ltx (docs\research\2026-10-24-story-levels-together.md section 5,
-- docs\plans\2026-10-24-f3a-split-levels.md sections 1.10 and 3).
-- The script is loaded into a sealed environment: the standard library and stand-ins for what it calls (the infoportions of
-- the actor, xr_logic.parse_condlist / pick_section_from_condlist for the `{+a -b} word, word` condlists of the table, an
-- ini over the real file, coop.levels.*, game.translate_string, level.name). A call to anything else fails here. The engine
-- side (coop.levels) is a recording stand-in: the script must also work without it (a build without split levels).
-- Not shipped. Run: tools\test_lua.cmd levels
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

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ------------------------------------------------------------------------------------------------ stand-ins
local SAFE = {}
for _, n in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset",
	"select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "string", "table", "math" }) do
	SAFE[n] = _G[n]
end

INFOS = {} -- infoportion -> true: what the actor has
NOW = 100000
LOGS = {}
SET = {} -- calls of coop.levels.set_gate: { level, gate, reason }
GATES = {} -- level -> what coop.levels.gate_of answers
PLAYER_LEVEL = {} -- player id -> level name
MY_LEVEL = "l01_escape" -- what coop.levels.my_level answers: a name or a game graph level id
LEVEL_NAMES = { [1] = "l01_escape", [2] = "l02_garbage", [7] = "l13u_warlab" } -- alife():level_name(id)
NO_ALIFE = false
STOCK_LEVEL = "k00_marsh" -- level.name()
CALLBACKS = {}
SET_FAILS = false
STRINGS = {
	l13u_warlab = "Warlab", l01_escape = "Cordon", l02_garbage = "Garbage",
	st_coop_levels_elsewhere = "On another map: %s",
	st_coop_levels_better_together = "%s: better together - %s",
	st_coop_together_warlab = "the finale",
}

local function logged(pat)
	for i = #LOGS, 1, -1 do
		if LOGS[i]:find(pat, 1, true) then return LOGS[i] end
	end
	return nil
end

local function count_logged(pat)
	local n = 0
	for _, l in ipairs(LOGS) do
		if l:find(pat, 1, true) then n = n + 1 end
	end
	return n
end

-- A table-backed ini with the calls the script uses: sections = { name = { {key, value}, ... } }
local function mini_ini(sections)
	local o = {}
	function o:section_exist(s) return sections[s] ~= nil end
	function o:line_count(s) return sections[s] and #sections[s] or 0 end
	function o:r_line(s, i) local kv = sections[s][i + 1]; return true, kv[1], kv[2] end
	function o:line_exist(s, k) for _, kv in ipairs(sections[s] or {}) do if kv[1] == k then return true end end return false end
	function o:r_string(s, k) for _, kv in ipairs(sections[s] or {}) do if kv[1] == k then return kv[2] end end end
	return o
end

-- The ini of a real ltx file: [section] lines and `key = value` lines, `;` starts a comment (as the engine reads it).
local function parse_ltx(text)
	local sections, cur = {}, nil
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = trim((line:gsub("\r", ""):gsub(";.*$", "")))
		local name = line:match("^%[([^%]]+)%]$")
		if name then
			cur = {}
			sections[name] = cur
		elseif line ~= "" and cur then
			local k, v = line:match("^([^=]-)%s*=%s*(.*)$")
			if k then cur[#cur + 1] = { trim(k), trim(v) } else cur[#cur + 1] = { line, "" } end
		end
	end
	return sections
end

local LTX_TEXT = read_file("gamedata/configs/coop_levels_together.ltx")
local SHIPPED = LTX_TEXT and parse_ltx(LTX_TEXT) or nil

-- xr_logic over the `{+a -b} word, {+c} word, word` shape of the table, the way the stock one reads it: the first entry whose
-- infoportion checks hold gives its word. `{=name}` (a function call) is an unknown function here: the stock one aborts.
local xr_logic = {
	parse_condlist = function(npc, section, field, src)
		if not (src and src ~= "") then return nil end -- the stock one prints an error and returns nothing
		local lst = {}
		for fld in src:gmatch("%s*([^,]+)%s*") do
			local cond = { checks = {} }
			local a, b, c = fld:find("{%s*(.*)%s*}")
			if c then
				fld = fld:sub(1, a - 1) .. fld:sub(b + 1)
				for sign, nm in c:gmatch("([%+%-])([%w_]+)") do cond.checks[#cond.checks + 1] = { nm, sign == "+" } end
				for fn in c:gmatch("=([%w_]+)") do cond.fn = fn end
			end
			cond.section = trim(fld)
			lst[#lst + 1] = cond
		end
		return lst
	end,
	pick_section_from_condlist = function(obj, npc, condlist)
		if not condlist then return "" end
		for _, cond in ipairs(condlist) do
			if cond.fn then error("xr_conditions." .. cond.fn .. " is not a function") end
			local ok = true
			for _, ck in ipairs(cond.checks) do
				if (INFOS[ck[1]] == true) ~= ck[2] then ok = false break end
			end
			if ok then return cond.section end
		end
		return ""
	end,
}

local DB = { actor = { has_info = function(self, nm) return INFOS[nm] == true end } }
local OVERRIDE = nil -- an ini object to hand out instead of the shipped file

-- the engine's side of coop.levels
local function make_coop(o)
	o = o or {}
	local c = {
		is_active = function() return o.active ~= false end,
		is_host = function() return o.host ~= false end,
	}
	if o.world_server ~= nil then c.is_world_server = function() return o.world_server end end
	if not o.no_levels then
		c.levels = {
			set_gate = function(lvl, g, reason)
				SET[#SET + 1] = { lvl, g, reason }
				if SET_FAILS then error("set_gate boom") end
			end,
			gate_of = function(lvl)
				if GATES[lvl] == "error" then error("gate_of boom") end
				return GATES[lvl]
			end,
			my_level = function() return MY_LEVEL end,
			level_of_player = function(id) return PLAYER_LEVEL[id] end,
		}
		if o.levels then
			for k, v in pairs(o.levels) do c.levels[k] = v end
		end
	end
	return c
end

local function reset_world()
	INFOS, SET, LOGS, GATES, PLAYER_LEVEL, CALLBACKS = {}, {}, {}, {}, {}, {}
	NOW = 100000
	MY_LEVEL = "l01_escape"
	NO_ALIFE = false
	SET_FAILS = false
	OVERRIDE = nil
	DB.actor = { has_info = function(self, nm) return INFOS[nm] == true end }
end

-- loads gamedata\scripts\coop_levels.script like CScriptStorage: a module table whose globals are its own
local function load_levels(coop_opts)
	local fh = io.open("gamedata/scripts/coop_levels.script", "rb")
	if not fh then return nil, "gamedata/scripts/coop_levels.script is missing" end
	local src = fh:read("*a")
	fh:close()
	local f, err = loadstring(src, "@coop_levels.script")
	if not f then return nil, err end
	local env = {}
	env._G = env
	env.printf = function(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		LOGS[#LOGS + 1] = ok and line or tostring(fmt)
	end
	env.time_global = function() return NOW end
	env.db = DB
	env.xr_logic = xr_logic
	env.ini_file = function(name)
		if OVERRIDE then return OVERRIDE end
		if name ~= "coop_levels_together.ltx" or not SHIPPED then error("no such ini: " .. tostring(name)) end
		return mini_ini(SHIPPED)
	end
	env.alife = function()
		if NO_ALIFE then return nil end
		return { level_name = function(self, id) return LEVEL_NAMES[id] end }
	end
	env.game = { translate_string = function(id) return STRINGS[id] or id end }
	env.level = { name = function() return STOCK_LEVEL end }
	env.RegisterScriptCallback = function(name, fn) CALLBACKS[name] = fn end
	if coop_opts ~= false then env.coop = make_coop(coop_opts) end
	local mod = setmetatable(env, { __index = SAFE })
	setfenv(f, mod)
	local ok, err2 = pcall(f)
	if not ok then return nil, err2 end
	return mod
end

local RULES = { "l13u_warlab", "l12u_sarcofag", "l10u_bunker", "l08u_brainlab", "l12u_control_monolith", "labx8", "l04u_labx18",
	"jupiter_underground", "pripyat", "l13_generators", "l11_hospital" }

local function set_of(lvl)
	for i = #SET, 1, -1 do
		if SET[i][1] == lvl then return SET[i] end
	end
	return nil
end

-- the gate word and the reason of the last set_gate call for the level (nil, nil when there was none)
local function given(lvl)
	local c = set_of(lvl)
	if not c then return nil, nil end
	return c[2], c[3]
end

-- ------------------------------------------------------------------------------------------------
print("== the table")
check(LTX_TEXT ~= nil, "configs\\coop_levels_together.ltx exists")
if not LTX_TEXT then finish() end
check(LTX_TEXT:find("\r\n", 1, true) ~= nil and not LTX_TEXT:gsub("\r\n", ""):find("\n", 1, true), "the ltx has CRLF line ends only")
check(not LTX_TEXT:find("[\128-\255]"), "the ltx is plain ASCII (so it is valid cp1251 too)")
check(SHIPPED.coop_levels_together ~= nil and SHIPPED.coop_levels_together_reason ~= nil, "both sections are there")

local mod, merr = load_levels()
check(mod ~= nil, "coop_levels loads in the sealed environment" .. (merr and (": " .. tostring(merr)) or ""))
if not mod then finish() end

local listed = mod.levels()
check(#listed == 11, "eleven levels are listed (" .. #listed .. ")")
local same = #listed == #RULES
for i, n in ipairs(RULES) do
	if listed[i] ~= n then same = false end
end
check(same, "the levels of the research, in its order (" .. table.concat(listed, ",") .. ")")

local plain = true
for _, kv in ipairs(SHIPPED.coop_levels_together) do
	if not kv[2]:find("^[%s%w_%+%-{},]+$") then plain = false end
end
check(plain, "every condlist of the table is of the shape the stand-in reads: {+a -b} word, word")

-- the strings the table names
local function ids_of(lang)
	local have = {}
	for _, file in ipairs({ "st_coop_levels.xml", "st_coop_game.xml" }) do
		local src = read_file("gamedata/configs/text/" .. lang .. "/" .. file)
		for id in (src or ""):gmatch('<string%s+id="([^"]+)"') do have[id] = (have[id] or 0) + 1 end
	end
	return have
end
local HAVE = { eng = ids_of("eng"), rus = ids_of("rus") }
local reasons_ok, missing = true, {}
for _, lvl in ipairs(RULES) do
	local id = mod.reason(lvl)
	if not (id and id:find("^st_coop_together_[%w_]+$")) then reasons_ok = false end
	for lang, have in pairs(HAVE) do
		if not (id and have[id] == 1) then missing[#missing + 1] = lang .. ":" .. lvl end
	end
end
check(reasons_ok, "each listed level has a reason: a string id st_coop_together_*")
check(#missing == 0, "each reason is defined once in eng and rus (" .. table.concat(missing, ",") .. ")")
check(mod.reason("l01_escape") == nil and mod.reason(nil) == nil, "a level that is not listed has no reason")

-- ------------------------------------------------------------------------------------------------
print("== the three story levels: together while the story is on")
reset_world()
mod = load_levels()
local TOGETHER_3 = { l13u_warlab = "warlab_deactivate_generators_done", l12u_sarcofag = "actor_made_wish",
	l10u_bunker = "bar_deactivate_radar_done" }
for lvl, done in pairs(TOGETHER_3) do
	reset_world()
	check(mod.evaluate_level(lvl) == "together", lvl .. ": together")
	INFOS[done] = true
	check(mod.evaluate_level(lvl) == "free", lvl .. ": free once " .. done .. " (the one-time scene is behind)")
	INFOS[done] = nil
	INFOS.story_mode_disabled = true
	check(mod.evaluate_level(lvl) == "free", lvl .. ": free when the story is off (story_mode_disabled)")
end

print("== Warlab")
reset_world()
check(mod.evaluate_level("l13u_warlab") == "together", "Warlab, the story on, the generators not off: together")
INFOS.warlab_deactivate_generators_done = true
INFOS.actor_made_wish = true
check(mod.evaluate_level("l13u_warlab") == "free", "Warlab after the generators: free")
check(mod.evaluate_level("l12u_sarcofag") == "free", "the Sarcophagus after the wish: free")
check(mod.evaluate_level("l10u_bunker") == "together", "X-10 does not care for either: still together")
check(mod.reason("l13u_warlab") == "st_coop_together_warlab", "Warlab: the reason string")

print("== better together")
local SUGGEST = { "l12u_control_monolith", "labx8", "l04u_labx18", "jupiter_underground" }
for _, lvl in ipairs(SUGGEST) do
	reset_world()
	check(mod.evaluate_level(lvl) == "suggest", lvl .. ": suggest")
	INFOS.story_mode_disabled = true
	check(mod.evaluate_level(lvl) == "free", lvl .. ": free when the story is off")
end
reset_world()
check(mod.evaluate_level("l08u_brainlab") == "suggest", "X-16: suggest")
INFOS.yan_labx16_switcher_primary_off = true
check(mod.evaluate_level("l08u_brainlab") == "free", "X-16 after the switch: free")

print("== the window of Pripyat")
reset_world()
check(mod.evaluate_level("pripyat") == "free", "Pripyat is free in general")
INFOS.operation_afterglow_jupiter_final = true
check(mod.evaluate_level("pripyat") == "suggest", "Pripyat in the final of Operation Afterglow: suggest")
INFOS.lttz_oa_loose_ends_done = true
check(mod.evaluate_level("pripyat") == "free", "Pripyat after the finale: free again")
INFOS.lttz_oa_loose_ends_done = nil
INFOS.story_mode_disabled = true
check(mod.evaluate_level("pripyat") == "free", "Pripyat in the final with the story off: free")

print("== the windows of Mortal Sin")
reset_world()
check(mod.evaluate_level("l13_generators") == "free" and mod.evaluate_level("l11_hospital") == "free", "the Generators and the Hospital are free in general")
INFOS.lttz_ms_heart_zone_started = true
check(mod.evaluate_level("l13_generators") == "suggest", "the Generators in the endgame: suggest")
INFOS.mortal_sin_endgame = true
check(mod.evaluate_level("l13_generators") == "free", "the Generators after the endgame: free")
INFOS.lttz_ms_hospital_assault_started = true
check(mod.evaluate_level("l11_hospital") == "free", "the Hospital assault, the heart zone already started: free")
INFOS.lttz_ms_heart_zone_started = nil
check(mod.evaluate_level("l11_hospital") == "suggest", "the Hospital assault window: suggest")

print("== story_mode_disabled")
reset_world()
for _, kv in ipairs({ "operation_afterglow_jupiter_final", "lttz_ms_heart_zone_started", "lttz_ms_hospital_assault_started" }) do
	INFOS[kv] = true
end
INFOS.story_mode_disabled = true
local all_free = true
for _, lvl in ipairs(RULES) do
	if mod.evaluate_level(lvl) ~= "free" then all_free = false end
end
check(all_free, "with the story off every listed level is free")
check(mod.evaluate_level("l01_escape") == "free" and mod.evaluate_level("") == "free" and mod.evaluate_level(nil) == "free",
	"a level that is not listed, an empty name, no name: free")

-- ------------------------------------------------------------------------------------------------
print("== evaluate() gives the gates to the engine when they change")
reset_world()
mod = load_levels()
check(mod.evaluate() == 11, "the first evaluation hands over every listed level (11)")
check(#SET == 11, "set_gate was called eleven times (" .. #SET .. ")")
local w = set_of("l13u_warlab")
check(w and w[2] == "together" and w[3] == "st_coop_together_warlab", "Warlab: together and its reason")
local p = set_of("pripyat")
check(p and p[2] == "free", "Pripyat: free")
local g_x16, r_x16 = given("l08u_brainlab")
check(g_x16 == "suggest" and r_x16 == "st_coop_together_brainlab", "X-16: suggest and its reason")

SET = {}
check(mod.evaluate() == 0 and #SET == 0, "nothing changed: nothing is handed over")
INFOS.actor_made_wish = true
check(mod.evaluate() == 1 and #SET == 1, "a new infoportion: only the level that changed")
check(SET[1] and SET[1][1] == "l12u_sarcofag" and SET[1][2] == "free" and SET[1][3] == "st_coop_together_sarcofag", "the Sarcophagus is free now, with its reason")
SET = {}
INFOS.operation_afterglow_jupiter_final = true
INFOS.lttz_ms_heart_zone_started = true
check(mod.evaluate() == 2 and given("pripyat") == "suggest" and given("l13_generators") == "suggest", "two windows open at once: two calls")
SET = {}
check(mod.evaluate(true) == 11 and #SET == 11, "evaluate(true) hands over all again")
SET = {}
mod.reset()
check(mod.evaluate() == 11 and #SET == 11, "reset() forgets what was handed over (a new world): all again")

print("== a hand-over that fails is tried again")
reset_world()
mod = load_levels()
SET_FAILS = true
check(mod.evaluate() == 0, "set_gate raises: nothing counts as handed over, no error")
check(logged("set_gate") ~= nil, "the failure is logged")
SET_FAILS = false
SET = {}
check(mod.evaluate() == 11, "the next evaluation hands everything over")

print("== who evaluates")
reset_world()
mod = load_levels({ host = false })
check(mod.evaluate() == 0 and #SET == 0, "a client does not hand over gates (the world server does)")
mod = load_levels({ active = false })
check(mod.evaluate() == 0 and #SET == 0, "no session: nothing is handed over")
mod = load_levels({ host = true, world_server = false })
check(mod.evaluate() == 0 and #SET == 0, "is_world_server says no: nothing (it wins over is_host)")
mod = load_levels({ host = false, world_server = true })
check(mod.evaluate() == 11, "is_world_server says yes: the gates are handed over")
reset_world()
mod = load_levels()
DB.actor = nil
check(mod.evaluate() == 0 and #SET == 0, "no actor (between worlds): nothing")
DB.actor = { has_info = function(self, nm) return INFOS[nm] == true end }
check(mod.evaluate() == 11, "the actor is back: the gates are handed over")

-- ------------------------------------------------------------------------------------------------
print("== a crooked table")
reset_world()
mod = load_levels()
OVERRIDE = mini_ini({
	coop_levels_together = {
		{ "good", "{+x} free, together" },
		{ "bad_word", "banana" },
		{ "bad_brace", "{+story_mode_disabled free, together" },
		{ "bad_fn", "{=boom} together, free" },
		{ "bad_empty", "" },
		{ "bad name!", "together" },
		{ "Mixed_Case", "suggest" },
	},
	coop_levels_together_reason = { { "good", "st_coop_together_warlab" }, { "bad_word", "" } },
})
mod.reload(OVERRIDE)
local ok_eval, n_eval = pcall(mod.evaluate)
check(ok_eval, "evaluate() does not raise on a crooked table")
check(mod.evaluate_level("good") == "together", "a good line still works")
INFOS.x = true
check(mod.evaluate_level("good") == "free", "...and follows the infoportions")
INFOS.x = nil
check(mod.evaluate_level("bad_word") == "free", "a word that is not a gate: free")
check(mod.evaluate_level("bad_brace") == "free", "unbalanced braces: free")
check(mod.evaluate_level("bad_fn") == "free", "a condlist that raises: free")
check(logged("bad_word") ~= nil and logged("bad_fn") ~= nil, "the crooked ones are logged")
local ls = mod.levels()
local has = {}
for _, n in ipairs(ls) do has[n] = true end
check(has.good and has.bad_word and has.bad_brace and has.bad_fn and not has.bad_empty and not has["bad name!"],
	"an empty line and a name that is not an id are not listed")
check(has.mixed_case, "level names are read lower case")
SET = {}
mod.reset()
LOGS = {}
mod.evaluate()
local n1 = #LOGS
mod.evaluate(true)
check(count_logged("bad_word") <= 1 and #LOGS == n1, "a crooked line is reported once, not every second")
check(given("bad_word") == "free" and given("bad_fn") == "free" and given("good") == "together",
	"the engine gets free for the crooked ones")
local _, r_good = given("good")
local _, r_bad = given("bad_word")
check(r_good == "st_coop_together_warlab" and r_bad == "", "the reason, or an empty string")

reset_world()
mod = load_levels()
OVERRIDE = nil
mod.reload(mini_ini({}))
check(#mod.levels() == 0 and mod.evaluate() == 0, "an ini without the sections: no levels, nothing handed over")
-- a missing file: ini_file raises
SHIPPED_BACKUP, SHIPPED = SHIPPED, nil
mod = load_levels()
check(pcall(mod.levels) and #mod.levels() == 0, "the file is missing: no levels, no error")
check(logged("coop_levels_together.ltx") ~= nil, "the missing file is logged")
SHIPPED = SHIPPED_BACKUP

-- ------------------------------------------------------------------------------------------------
print("== callbacks: once a second and on a new infoportion")
reset_world()
mod = load_levels()
mod.on_game_start()
check(CALLBACKS.actor_on_update and CALLBACKS.actor_on_first_update and CALLBACKS.actor_on_info_callback,
	"on_game_start: update, first update and info portion callbacks")
NOW = 100000
CALLBACKS.actor_on_update()
check(#SET == 11, "the first update evaluates")
SET = {}
INFOS.actor_made_wish = true
NOW = 100500
CALLBACKS.actor_on_update()
check(#SET == 0, "within a second it does not")
NOW = 101000
CALLBACKS.actor_on_update()
check(#SET == 1 and SET[1] and SET[1][1] == "l12u_sarcofag", "a second after the last evaluation it does")
SET = {}
INFOS.bar_deactivate_radar_done = true
NOW = 101100
CALLBACKS.actor_on_info_callback(nil, "bar_deactivate_radar_done")
CALLBACKS.actor_on_update()
check(#SET == 1 and SET[1] and SET[1][1] == "l10u_bunker" and SET[1][2] == "free", "a new infoportion does not wait for the second")
SET = {}
CALLBACKS.actor_on_update()
check(#SET == 0, "...and only once")
NOW = 101200
CALLBACKS.actor_on_first_update()
check(#SET == 11, "a new level: the first update hands all the gates over again")
SET = {}
INFOS.story_mode_disabled = true
NOW = 500 -- the clock started over (a loaded game): it does not stall until the old time comes again
CALLBACKS.actor_on_update()
NOW = 1500
CALLBACKS.actor_on_update()
check(#SET > 0, "the clock that goes back does not stop the evaluation for good")

reset_world()
mod = load_levels({ host = false })
mod.on_game_start()
CALLBACKS.actor_on_update()
CALLBACKS.actor_on_info_callback(nil, "x")
CALLBACKS.actor_on_first_update()
check(#SET == 0, "on a client the callbacks hand over nothing")

reset_world()
mod = load_levels(false)
check(pcall(mod.on_game_start) and next(CALLBACKS) == nil, "without the engine namespace on_game_start registers nothing, no error")

-- ------------------------------------------------------------------------------------------------
print("== gate(): what the engine says, free when it says nothing")
reset_world()
mod = load_levels()
GATES.l13u_warlab = "together"
GATES.labx8 = "suggest"
GATES.pripyat = "free"
check(mod.gate("l13u_warlab") == "together" and mod.gate("labx8") == "suggest" and mod.gate("pripyat") == "free",
	"the three words come back")
GATES.a, GATES.b, GATES.c = 2, 1, 0
check(mod.gate("a") == "together" and mod.gate("b") == "suggest" and mod.gate("c") == "free", "the numbers of the wire enum too")
GATES.d, GATES.e, GATES.f, GATES.g = "banana", 7, true, "error"
check(mod.gate("d") == "free" and mod.gate("e") == "free" and mod.gate("f") == "free" and mod.gate("g") == "free",
	"anything else, and an engine that raises: free")
check(mod.gate("unknown") == "free" and mod.gate(nil) == "free" and mod.gate("") == "free", "an unknown level, no level: free")

print("== no coop.levels (a build without split levels)")
for _, opts in ipairs({ false, { no_levels = true } }) do
	reset_world()
	mod = load_levels(opts)
	local label = opts == false and "no coop namespace" or "coop without levels"
	check(mod ~= nil, label .. ": loads")
	check(mod.gate("l13u_warlab") == "free", label .. ": gate() is free")
	check(mod.evaluate_level("l13u_warlab") == "free", label .. ": evaluate_level() is free")
	check(mod.evaluate() == 0, label .. ": evaluate() hands over nothing")
	check(pcall(mod.on_game_start) and pcall(mod.reset) and pcall(mod.reload), label .. ": on_game_start, reset and reload do not raise")
	check(mod.elsewhere(2) == false and mod.elsewhere("l02_garbage") == false and mod.elsewhere_text(2) == "",
		label .. ": nobody is elsewhere")
	check(mod.name("l13u_warlab") == "Warlab" and mod.name() == STOCK_LEVEL and mod.notice("l13u_warlab") == "",
		label .. ": name() falls back to level.name(), no notice")
end

-- ------------------------------------------------------------------------------------------------
print("== name(), elsewhere(), notice()")
reset_world()
mod = load_levels()
check(mod.name("l13u_warlab") == "Warlab" and mod.name("l99_unknown") == "l99_unknown", "name: the translated level, or its id")
check(mod.name() == "Cordon", "name() is the level of the local player (coop.levels.my_level)")
check(mod.name("") == "" and mod.name(5) == "", "name: not a level")

PLAYER_LEVEL[2] = "l02_garbage"
PLAYER_LEVEL[3] = "l01_escape"
check(mod.elsewhere(2) == true, "player 2 is on another level")
check(mod.elsewhere(3) == false, "player 3 is on my level")
check(mod.elsewhere(4) == false, "a player the engine does not know is not elsewhere")
check(mod.elsewhere("l02_garbage") == true and mod.elsewhere("l01_escape") == false, "a level name works too")
check(mod.elsewhere(nil) == false and mod.elsewhere("") == false, "nobody, nothing: no")
check(mod.elsewhere_text(2) == "On another map: Garbage", "the line of the HUD: \"" .. mod.elsewhere_text(2) .. "\"")
check(mod.elsewhere_text(3) == "" and mod.elsewhere_text(4) == "", "...and nothing for my own level")
mod = load_levels({ levels = { my_level = false } })
check(pcall(mod.name) , "my_level that is not a function: name() still answers")

GATES.l13u_warlab = "together"
GATES.labx8 = "suggest"
reset_world()
mod = load_levels()
GATES.l13u_warlab = "together"
GATES.labx8 = "suggest"
check(mod.notice("l13u_warlab") == "Warlab: better together - the finale", "notice: \"" .. mod.notice("l13u_warlab") .. "\"")
check(mod.notice("labx8") ~= "" and mod.notice("pripyat") == "" and mod.notice(nil) == "", "notice: only for a level that is not free")

-- ------------------------------------------------------------------------------------------------
print("== the engine answers with game graph level ids")
reset_world()
mod = load_levels()
MY_LEVEL = 1
PLAYER_LEVEL[2] = 2
PLAYER_LEVEL[3] = 1
PLAYER_LEVEL[4] = 99 -- an id the game graph does not know
check(mod.name() == "Cordon", "name(): my_level() is an id, the name comes from alife():level_name")
check(mod.elsewhere(2) == true and mod.elsewhere(3) == false and mod.elsewhere(4) == false, "elsewhere: ids are compared by name; an unknown id is nobody")
check(mod.elsewhere_text(2) == "On another map: Garbage", "elsewhere_text: the name of the other level")
check(mod.name(7) == "Warlab" and mod.name(99) == "" and mod.name(0.5) == "", "name(id): the translated name; an unknown id gives nothing")
GATES.l13u_warlab = "together"
check(mod.gate(7) == "together" and mod.gate(99) == "free", "gate(id): asked of the engine by name")
check(mod.reason(7) == "st_coop_together_warlab" and mod.evaluate_level(7) == "together", "reason(id), evaluate_level(id)")
NO_ALIFE = true
check(mod.name(7) == "" and mod.gate(7) == "free" and mod.name() == STOCK_LEVEL and mod.elsewhere(2) == false,
	"between worlds (no alife): an id is nothing, the stock level.name() answers for my own level")
NO_ALIFE = false

-- ------------------------------------------------------------------------------------------------
print("== the strings of the script")
local src = read_file("gamedata/scripts/coop_levels.script")
local used = {}
for id in src:gmatch('"(st_coop_[%w_]+)"') do
	if id:sub(-1) ~= "_" then used[id] = true end
end
local absent = {}
for id in pairs(used) do
	for lang, have in pairs(HAVE) do
		if have[id] ~= 1 then absent[#absent + 1] = lang .. ":" .. id end
	end
end
table.sort(absent)
check(next(used) ~= nil and #absent == 0, "every st_coop_ id the script names is defined once in eng and rus (" .. table.concat(absent, ",") .. ")")
local rus = read_file("gamedata/configs/text/rus/st_coop_levels.xml") or ""
local eng = read_file("gamedata/configs/text/eng/st_coop_levels.xml") or ""
check(rus:find("[\192-\255]") ~= nil and not eng:find("[\128-\255]"), "the Russian file is cp1251 text, the English one is ASCII")
check(rus:find('encoding="windows-1251"', 1, true) ~= nil and eng:find('encoding="windows-1251"', 1, true) ~= nil, "both files declare windows-1251")

finish()
