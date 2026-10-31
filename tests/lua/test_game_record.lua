-- Anomaly Coop test (settings of a game, T1): the catalog gamedata\scripts\coop_game_schema.script and the record
-- gamedata\scripts\coop_game_record.script (docs\GAME_SETTINGS.md sections 3.3, 3.6, 3.7). Pure logic: both modules are
-- loaded into a sealed environment that has the Lua standard library and nothing of the engine, so a call to an engine
-- global fails here. The codec, the clock and the random numbers are stand-ins. Not shipped.
-- Run: tools\test_lua.cmd game_record
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

-- ------------------------------------------------------------------------------------------------ sealed loader
local SAFE = {}
for _, n in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset",
	"select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "string", "table", "math" }) do
	SAFE[n] = _G[n]
end
SAFE.os = { time = os.time, date = os.date, clock = os.clock }
SAFE._G = SAFE

-- loads gamedata\scripts\<name>.script like CScriptStorage: a module table whose globals are its own
local function load_module(name, extra)
	local fh = io.open("gamedata/scripts/" .. name .. ".script", "rb")
	if not fh then return nil, "gamedata/scripts/" .. name .. ".script is missing" end
	local src = fh:read("*a")
	fh:close()
	local f, err = loadstring(src, "@" .. name .. ".script")
	if not f then return nil, err end
	local env = {}
	for k, v in pairs(extra or {}) do env[k] = v end
	local this = setmetatable(env, { __index = SAFE })
	setfenv(f, this)
	local ok, err2 = pcall(f)
	if not ok then return nil, err2 end
	SAFE[name] = this
	return this
end

local schema, serr = load_module("coop_game_schema")
check(schema ~= nil, "coop_game_schema loads in the sealed environment" .. (serr and (": " .. tostring(serr)) or ""))
local rec, rerr = load_module("coop_game_record")
check(rec ~= nil, "coop_game_record loads in the sealed environment" .. (rerr and (": " .. tostring(rerr)) or ""))
if not (schema and rec) then finish() end

local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local function deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not deep_equal(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function contains(list, v)
	for _, x in ipairs(list) do
		if x == v then return true end
	end
	return false
end

local function sorted_keys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end
	table.sort(out)
	return out
end

-- ------------------------------------------------------------------------------------------------ catalog shape
local EXPECT_TABS = { "death", "party", "world", "difficulty", "saves", "other" }
check(deep_equal(schema.TABS, EXPECT_TABS), "TABS are death, party, world, difficulty, saves, other")

local EXPECT_COUNT = { death = 12, party = 17, world = 21, difficulty = 2, saves = 2, other = 0 }
for _, tab in ipairs(EXPECT_TABS) do
	check(#schema.items(tab) == EXPECT_COUNT[tab], "tab " .. tab .. " has " .. EXPECT_COUNT[tab] .. " items (docs 3.6)")
end
check(#schema.items("nope") == 0, "an unknown tab has no items")
check(#schema.keys() == 54, "54 catalog keys in all")
check(schema.item("c|nope") == nil and schema.item(nil) == nil, "an unknown key has no item")

do
	local seen_key, seen_id = {}, {}
	local bad = {}
	local RESERVED = { title = true, created_only = true, applies_on_load = true, applies_next_emission = true,
		applies_new_levels = true, applies_next_weather = true, saved = true, running = true, old_save = true,
		take_machine = true, take_machine_confirm = true, other_counts = true, migrated = true, on = true, off = true }
	local WHEN = { create = true, session = true }
	local APPLIES = { create = true, load = true, live = true, next = true }
	local UNITS = { s = true, min = true, m = true, h = true, pct = true, frac = true }
	for _, tab in ipairs(schema.TABS) do
		for _, it in ipairs(schema.items(tab)) do
			local why
			if seen_key[it.key] then why = "duplicate key" end
			seen_key[it.key] = true
			if seen_id[it.id] then why = why or "duplicate id " .. it.id end
			seen_id[it.id] = true
			if RESERVED[it.id] or it.id:find("^tab_") then why = why or "id " .. it.id .. " is a reserved string id" end
			if schema.item(it.key) ~= it then why = why or "item(key) is another item" end
			if it.tab ~= tab then why = why or "wrong tab" end
			if it.kind ~= "list" and it.kind ~= "check" then why = why or "kind " .. tostring(it.kind) end
			if not WHEN[it.when] then why = why or "when " .. tostring(it.when) end
			if not APPLIES[it.applies] then why = why or "applies " .. tostring(it.applies) end
			if it.text ~= "st_coop_game_" .. it.id then why = why or "text " .. tostring(it.text) end
			if it.unit ~= nil and not UNITS[it.unit] then why = why or "unit " .. tostring(it.unit) end
			if it.applies == "next" and it.note == nil and not it.key:find("alife_%a+_pop$") then
				why = why or "a next-event item without a hint"
			end
			if it.when == "create" and it.applies ~= "create" and it.key ~= "c|coop_death_mode" then
				why = why or "a create item that does not apply at creation"
			end
			if it.kind == "check" then
				if type(it.def) ~= "boolean" then why = why or "check default is not a boolean" end
				if not (#it.values == 2 and it.values[1][1] == true and it.values[2][1] == false) then
					why = why or "check values are not true / false"
				end
			elseif it.key ~= "faction" then
				if #it.values < 2 then why = why or "fewer than two values" end
				local tseen, found_def = {}, false
				for _, e in ipairs(it.values) do
					if type(e[1]) ~= type(it.values[1][1]) then why = why or "mixed value types" end
					if tseen[e[1]] then why = why or "duplicate value " .. tostring(e[1]) end
					tseen[e[1]] = true
					if type(e[2]) ~= "string" then why = why or "a value without a text id" end
					if e[1] == it.def then found_def = true end
					if it.range and type(e[1]) == "number" and (e[1] < it.range[1] or e[1] > it.range[2]) then
						why = why or "value " .. tostring(e[1]) .. " outside its range"
					end
				end
				if not found_def then why = why or "the default " .. tostring(it.def) .. " is not in the list" end
			end
			if it.shown_if and not schema.item(it.shown_if.key) then why = why or "shown_if of an unknown key" end
			if it.needs_mcm ~= nil and it.src ~= "m" then why = why or "needs_mcm on a non-MCM key" end
			if it.src == "m" and it.needs_mcm ~= "drx_da" then why = why or "an MCM item without its addon" end
			if why then bad[#bad + 1] = it.key .. ": " .. why end
		end
	end
	check(#bad == 0, "every item is well formed: unique key and id, kind, when, applies, text, a default that is in its list ("
		.. table.concat(bad, "; ") .. ")")
	check(schema.default("faction") == nil and schema.default("c|nope") == nil, "faction has no default, an unknown key neither")
	check(schema.default("c|coop_autosave_interval") == 10 and schema.default("o|coop/coop_session/sleep_rule") == "vote"
		and schema.default("o|alife/event/emission_state") == true and schema.default("w|routes") == false,
		"default(key) is the typed default (also false)")
end

do
	local inv = {}
	for _, tab in ipairs(schema.TABS) do
		for _, it in ipairs(schema.items(tab)) do inv[it.key] = it.tab end
	end
	check(inv["c|coop_death_mode"] == "death" and inv["c|coop_death_share"] == "death" and inv["c|coop_checkpoints_group"] == "death",
		"death tab holds the death rules")
	check(inv["o|coop/coop_session/join_spawn"] == "party" and inv["c|coop_max_new_characters"] == "party",
		"party tab holds the group rules and join_spawn")
	check(inv["faction"] == "world" and inv["w|story"] == "world" and inv["w|routes"] == "world"
		and inv["m|drx_da/disable_new_anomalies"] == "world", "world tab holds the faction, the flags and the anomaly settings")
	check(inv["w|difficulty"] == "difficulty" and inv["w|economy"] == "difficulty", "difficulty tab holds the two presets")
	check(inv["c|coop_autosave_interval"] == "saves" and inv["c|coop_autosave_count"] == "saves", "saves tab holds the autosave rules")
	local order = {}
	for _, it in ipairs(schema.items("death")) do order[#order + 1] = it.key end
	check(order[1] == "c|coop_death_mode" and order[2] == "c|coop_death_drop" and order[3] == "c|coop_death_share"
		and order[12] == "c|coop_checkpoints_group", "items come in the order of the table 3.6")
	local drx = schema.item("m|drx_da/anomaly_amount_modifier")
	check(drx.needs_mcm == "drx_da" and drx.applies == "next" and drx.note == "st_coop_game_applies_new_levels",
		"a mod item names its MCM addon and the hint")
	local em = schema.item("o|alife/event/emission_frequency")
	check(em.applies == "next" and em.note == "st_coop_game_applies_next_emission", "the emission frequency acts with the next emission")
	check(schema.item("o|alife/general/excl_dist").applies == "load" and schema.item("c|coop_friendly_fire").applies == "live",
		"excl_dist acts at load, a console rule on the fly")
	local share = schema.item("c|coop_death_share")
	check(share.shown_if.key == "c|coop_death_drop" and contains(share.shown_if.any, "drop") and contains(share.shown_if.any, "lose")
		and not contains(share.shown_if.any, "keep"), "the death share is shown for drop and lose")
	check(schema.item("c|coop_hardcore_new_kit").shown_if.any[1] == "hardcore", "the new kit is shown for hardcore")
	check(schema.item("w|difficulty").values[2][2] == "st_diff_2" and schema.item("w|economy").values[3][2] == "st_econ_3",
		"the presets use the stock strings")
end

-- ------------------------------------------------------------------------------------------------ schema_cvars_match_engine
-- The table of docs\GAME_SETTINGS.md 1.2 (rows 1..19, file GAME_SETTINGS.md lines 119-135 on 2026-10-23), name, kind, min,
-- max, default; the engine registration is in the comment. Rows 5 (keep) and 17 are the death-ux build 10, rows 18 and 19
-- the split-levels build of F3a (2026-10-24): not all in the engine yet.
local ENGINE = {
	{ "coop_friendly_fire", "int", 0, 1, 1 }, -- coop_console.cpp:177 CCC_Integer 0..1
	{ "coop_max_new_characters", "int", 1, 64, 8 }, -- coop_console.cpp:178, coop_limits.h:175-177 kNewCharacters*
	{ "coop_share_rewards", "int", 0, 3, 0 }, -- coop_story.cpp CCC_Integer 0..3
	{ "coop_death_mode", "token", nil, nil, "checkpoint", { "checkpoint", "hardcore", "rollback" } }, -- coop_survival.cpp:2562 CCC_Token
	{ "coop_death_drop", "token", nil, nil, "drop", { "drop", "corpse", "lose", "keep" } }, -- :2563, keep = build 10
	{ "coop_bleedout", "float", 10, 600, 60 }, -- coop_survival.cpp:2564 CCC_Float
	{ "coop_revive_health", "float", 0.05, 1, 0.3 }, -- :2565
	{ "coop_respawn_delay", "float", 0, 300, 30 }, -- :2566
	{ "coop_contusion", "float", 0, 60, 10 }, -- :2567
	{ "coop_death_money", "float", 0, 100, 10 }, -- :2568
	{ "coop_death_wear", "float", 0, 100, 10 }, -- :2569
	{ "coop_death_rank", "float", 0, 100, 0 }, -- :2570
	{ "coop_hardcore_new_kit", "int", 0, 1, 0 }, -- coop_death.cpp:1133 CCC_Integer 0..1
	{ "coop_checkpoints_group", "int", 0, 1, 1 }, -- coop_checkpoints.cpp:586 CCC_Integer 0..1
	{ "coop_autosave_interval", "int", 0, 120, 10 }, -- coop_autosave.cpp:533 CCC_Integer 0..120
	{ "coop_autosave_count", "int", 1, 50, 10 }, -- coop_autosave.cpp:534 CCC_Integer 1..50
	{ "coop_death_share", "float", 0, 200, 100 }, -- build 10: CCC_Float 0..200, default 100
	{ "coop_split_levels", "int", 0, 1, 1 }, -- F3a: CCC_Integer 0..1, on by default
	{ "coop_story_together", "int", 0, 1, 1 }, -- F3a: CCC_Integer 0..1, on by default
}

do
	check(#schema.CVARS == 19, "CVARS holds 19 names")
	local bad = {}
	for i, row in ipairs(ENGINE) do
		local name, kind, lo, hi, def, tokens = row[1], row[2], row[3], row[4], row[5], row[6]
		local cv = schema.CVAR[name]
		local why
		if schema.CVARS[i] ~= name then why = "CVARS[" .. i .. "] is " .. tostring(schema.CVARS[i]) end
		if not cv then
			why = why or "no CVAR entry"
		else
			if cv.kind ~= kind then why = why or "kind " .. tostring(cv.kind) end
			if cv.min ~= lo or cv.max ~= hi then why = why or "range " .. tostring(cv.min) .. ".." .. tostring(cv.max) end
			if cv.def ~= def then why = why or "default " .. tostring(cv.def) end
			if tokens and not deep_equal(cv.tokens, tokens) then why = why or "tokens" end
		end
		local it = schema.item("c|" .. name)
		if not it then
			why = why or "no catalog item"
		else
			if it.cvar ~= name then why = why or "item.cvar " .. tostring(it.cvar) end
			if lo ~= nil and (not it.range or it.range[1] ~= lo or it.range[2] ~= hi) then why = why or "item range" end
			for _, e in ipairs(it.values) do
				local v = e[1]
				if kind == "token" then
					if not contains(tokens, v) then why = why or "value " .. tostring(v) .. " is not a token" end
				elseif it.kind == "check" then
					if (v and 1 or 0) < lo or (v and 1 or 0) > hi then why = why or "check outside the range" end
				else
					if type(v) ~= "number" or v < lo or v > hi then why = why or "value " .. tostring(v) .. " outside " .. lo .. ".." .. hi end
					if kind == "int" and v ~= math.floor(v) then why = why or "value " .. tostring(v) .. " is not whole" end
				end
			end
			local want_def = def
			if it.kind == "check" then want_def = def ~= 0 end
			if it.def ~= want_def then why = why or "item default " .. tostring(it.def) end
		end
		if why then bad[#bad + 1] = name .. ": " .. why end
	end
	check(#bad == 0, "the 19 console variables match the table 1.2: names, order, ranges, defaults, values inside ("
		.. table.concat(bad, "; ") .. ")")
	local c_items = 0
	for _, k in ipairs(schema.keys()) do
		if k:find("^c|") then c_items = c_items + 1 end
	end
	check(c_items == 19, "all 19 console variables, and only they, are catalog items of source c")
	local tokens = schema.item("c|coop_death_drop").values
	check(tokens[1][1] == "drop" and tokens[4][1] == "keep", "death drop offers drop, corpse, lose, keep")
	local share = schema.item("c|coop_death_share").values
	check(#share == 4 and share[1][1] == 50 and share[4][1] == 200, "death share offers 50 / 100 / 150 / 200")
end

-- The engine source, where this tree has it: a range or a token that drifted away from the catalog is found here.
do
	local dir = "engine/src/xrGame/coop/"
	local files = { "coop_console.cpp", "coop_survival.cpp", "coop_death.cpp", "coop_checkpoints.cpp", "coop_autosave.cpp",
		"coop_story.cpp" }
	local found, bad, seen_files = 0, {}, 0
	for _, f in ipairs(files) do
		local src = read_file(dir .. f)
		if src then
			seen_files = seen_files + 1
			for kind, name, lo, hi in src:gmatch('CMD4%(CCC_(%a+),%s*"(coop_[%w_]+)",%s*&[%w_:]+,%s*(-?[%d%.]+)f?,%s*(-?[%d%.]+)f?%)') do
				local cv = schema.CVAR[name]
				if cv then
					found = found + 1
					local want_kind = kind == "Integer" and "int" or "float"
					if cv.kind ~= want_kind or math.abs(cv.min - tonumber(lo)) > 1e-9 or math.abs(cv.max - tonumber(hi)) > 1e-9 then
						bad[#bad + 1] = name .. " is " .. kind .. " " .. lo .. ".." .. hi .. " in " .. f
					end
				end
			end
			for _, tk in ipairs({ { "g_death_mode_tokens", "coop_death_mode" }, { "g_death_drop_tokens", "coop_death_drop" } }) do
				local block = src:match("xr_token%s+" .. tk[1] .. "%[%]%s*=%s*(%b{})")
				if block then
					local cv = schema.CVAR[tk[2]]
					for t in block:gmatch('{%s*"([%w_]+)"') do
						if not (contains(cv.tokens, t) or (cv.aliases and cv.aliases[t])) then
							bad[#bad + 1] = tk[2] .. ": the engine token " .. t .. " is unknown to the catalog"
						end
					end
				end
			end
		end
	end
	local lim = read_file(dir .. "../../xrCoop/coop_limits.h")
	if lim then
		local lo = tonumber(lim:match("kNewCharactersMin%s*=%s*(%d+)"))
		local hi = tonumber(lim:match("kNewCharactersMax%s*=%s*(%d+)"))
		local cv = schema.CVAR.coop_max_new_characters
		if lo ~= cv.min or hi ~= cv.max then bad[#bad + 1] = "coop_max_new_characters is " .. tostring(lo) .. ".." .. tostring(hi) .. " in coop_limits.h" end
	end
	if seen_files == 0 then
		print("  note: the engine sources are not here, the catalog is checked against the table 1.2 only")
	else
		check(found >= 13, "the parser read the numeric registrations of the engine (" .. found .. " of 13 or more)")
		check(#bad == 0, "the engine's ranges and tokens agree with the catalog (" .. table.concat(bad, "; ") .. ")")
	end
end

-- ------------------------------------------------------------------------------------------------ schema_party_defaults_match_rules
do
	local core, cerr = load_module("coop_economy_core", { printf = function() end })
	check(core ~= nil and type(core.RULES) == "table", "coop_economy_core loads with stubs" .. (cerr and (": " .. tostring(cerr)) or ""))
	if core and core.RULES then
		local bad, n = {}, 0
		for id, def in pairs(core.RULES) do
			n = n + 1
			local it = schema.item("o|coop/coop_session/" .. id)
			if not it then
				bad[#bad + 1] = id .. ": not in the catalog"
			else
				if it.def ~= def then bad[#bad + 1] = id .. ": default " .. tostring(it.def) .. " is not " .. tostring(def) end
				if type(it.def) ~= type(def) then bad[#bad + 1] = id .. ": type" end
				if (type(def) == "boolean") ~= (it.kind == "check") then bad[#bad + 1] = id .. ": kind" end
			end
		end
		check(n == 11, "coop_economy_core.RULES has the 11 rules of docs 1.3")
		check(#bad == 0, "every economy rule is a catalog item with the rule's own default (" .. table.concat(bad, "; ") .. ")")
		local extra = {}
		for _, k in ipairs(schema.keys()) do
			local id = k:match("^o|coop/coop_session/(.+)$")
			if id and core.RULES[id] == nil and id ~= "join_spawn" then extra[#extra + 1] = id end
		end
		check(#extra == 0, "no other session rule in the catalog than RULES and join_spawn (" .. table.concat(extra, ",") .. ")")
		check(schema.item("o|coop/coop_session/join_spawn").def == "faction_start", "join_spawn is at the faction's base by default (F3a, docs 8.2)")
	end
end

-- ------------------------------------------------------------------------------------------------ schema_create_only
do
	local expect = { ["faction"] = true, ["w|story"] = true, ["w|routes"] = true, ["w|difficulty"] = true,
		["w|economy"] = true, ["c|coop_death_mode"] = true }
	local got, all_new = {}, true
	for _, k in ipairs(schema.keys()) do
		if not schema.editable(k, true) then got[k] = true end
		if not schema.editable(k, false) then all_new = false end
	end
	check(deep_equal(got, expect), "editable(k, true) is false for exactly faction, w|story, w|routes, w|difficulty, w|economy, c|coop_death_mode")
	check(all_new, "everything can be chosen while the game is created")
	check(schema.editable("g|hit_power", true) and schema.editable("e|buy", true) and schema.editable("s|trader_buy_condition_override", true),
		"the factors can be edited on an existing game")
	check(not schema.editable("g|hit_power", false), "and are set by the presets at creation")
	check(not schema.editable("o|gameplay/silent_kills/foo", true) and not schema.editable("c|coop_nick", true) and not schema.editable(nil, true),
		"other keys are not edited here")
end

-- ------------------------------------------------------------------------------------------------ normalize
do
	local I = "c|coop_autosave_interval"
	check(schema.normalize(I, "10") == 10 and schema.normalize(I, 10) == 10, "a value of the list comes back typed")
	local before = #schema.item(I).values
	check(schema.normalize(I, "15") == 15, "normalize(autosave interval, \"15\") is 15")
	local e15
	for _, e in ipairs(schema.item(I).values) do
		if e[1] == 15 then e15 = e end
	end
	check(e15 ~= nil, "and 15 is an item of the list afterwards")
	-- 15 is one of the catalog's own values (docs 3.6 tab 5); a value that is not: 25
	check(#schema.item(I).values == before and not (e15 and e15.extra), "15 was in the list already: no extra entry")
	check(schema.normalize(I, "25") == 25, "25 is valid for 0..120")
	local vals = schema.item(I).values
	local pos25, pos30, pos0
	for i, e in ipairs(vals) do
		if e[1] == 25 then pos25 = i end
		if e[1] == 30 then pos30 = i end
		if e[1] == 0 then pos0 = i end
	end
	check(pos25 ~= nil and vals[pos25].extra == true and vals[pos25][2] == nil, "and it is added as an extra entry without a text")
	check(#vals == before + 1 and pos25 == pos30 - 1 and pos0 == #vals, "in order of value, and off stays last")
	check(schema.normalize(I, "25") == 25 and #schema.item(I).values == before + 1, "asked again: no second entry")
	check(schema.normalize(I, "110") == 110 and schema.normalize(I, "90") == 90, "values up to 120 are kept")
	check(schema.item(I).values[#schema.item(I).values][1] == 0, "off is last after more extras")
	check(schema.normalize(I, "abc") == nil and schema.normalize(I, "") == nil and schema.normalize(I, nil) == nil,
		"abc, an empty string and nil are invalid")
	check(schema.normalize(I, "121") == nil and schema.normalize(I, "-1") == nil, "out of range is invalid")
	check(schema.normalize(I, "10.5") == nil, "a console integer takes whole numbers only")
	check(schema.normalize(I, "0x10") == nil and schema.normalize(I, "1e400") == nil, "hex and infinity are invalid")
	check(schema.normalize("c|nope", "1") == nil, "an unknown key is invalid")
	schema.reset_extras()
	local extras = 0
	for _, e in ipairs(schema.item(I).values) do
		if e.extra then extras = extras + 1 end
	end
	check(extras == 0 and #schema.item(I).values == before, "reset_extras removes them")

	-- floats: the console prints them with trailing digits; they are matched to the list
	check(schema.normalize("c|coop_revive_health", "0.300000") == 0.3, "0.300000 is the list's 0.3")
	check(schema.normalize("c|coop_revive_health", "0.35") == 0.35 and schema.normalize("c|coop_revive_health", "0.04") == nil,
		"0.35 is kept, 0.04 is below the engine's 0.05")
	check(schema.normalize("c|coop_death_share", "250") == nil and schema.normalize("c|coop_death_share", "175") == 175,
		"the death share goes up to 200")
	-- tokens
	check(schema.normalize("c|coop_death_mode", "Hardcore") == "hardcore" and schema.normalize("c|coop_death_mode", "respawn") == "checkpoint"
		and schema.normalize("c|coop_death_mode", "respawn_keep") == "checkpoint", "death mode: case ignored, the old names mean checkpoint")
	check(schema.normalize("c|coop_death_mode", "weird") == nil and schema.normalize("c|coop_death_drop", "keep") == "keep",
		"an unknown token is invalid, keep is a token")
	-- flags
	check(schema.normalize("c|coop_friendly_fire", "1") == true and schema.normalize("c|coop_friendly_fire", "0") == false
		and schema.normalize("c|coop_friendly_fire", "2") == nil, "a console flag: 1 / 0")
	check(schema.normalize("o|alife/general/dynamic_anomalies", "true") == true and schema.normalize("o|alife/general/dynamic_anomalies", "false") == false
		and schema.normalize("o|alife/general/dynamic_anomalies", "maybe") == nil, "an option flag: true / false")
	-- rules of a session
	check(schema.normalize("o|coop/coop_session/gather_radius", "25") == 25 and schema.normalize("o|coop/coop_session/gather_radius", "4") == nil
		and schema.normalize("o|coop/coop_session/gather_radius", "101") == nil, "gather radius 5..100")
	schema.reset_extras()
	check(schema.normalize("o|coop/coop_session/sleep_rule", "gather") == "gather" and schema.normalize("o|coop/coop_session/sleep_rule", "nap") == nil,
		"a string rule takes the listed names only")
	check(schema.normalize("o|alife/event/emission_frequency", "36") == 36, "an emission frequency that is not in the list is kept")
	check(schema.normalize("o|alife/event/emission_fate", "explode") == "explode" and schema.normalize("o|alife/event/psi_storm_fate", "explode") == nil,
		"emission and psi storm have their own fates")
	-- the world
	check(schema.normalize("faction", "stalker") == "stalker" and schema.normalize("faction", "a b") == nil
		and schema.normalize("faction", "") == nil and schema.normalize("faction", string.rep("a", 65)) == nil,
		"a faction is a protocol name: letters, digits, _ . -, up to 64")
	check(schema.normalize("w|difficulty", "3") == 3 and schema.normalize("w|difficulty", "4") == nil, "difficulty preset 1..3")
	check(schema.normalize("w|story", true) == true, "a typed value is accepted too")
	schema.reset_extras()
end

-- ------------------------------------------------------------------------------------------------ to_raw / canon
do
	check(schema.to_raw("c|coop_friendly_fire", true) == "1" and schema.to_raw("c|coop_friendly_fire", false) == "0",
		"a console flag is 1 / 0")
	check(schema.to_raw("o|alife/general/heli_spawn", true) == "true" and schema.to_raw("m|drx_da/disable_new_anomalies", false) == "false",
		"an option flag is true / false")
	check(schema.to_raw("c|coop_revive_health", 0.3) == "0.3" and schema.to_raw("c|coop_autosave_interval", 15) == "15"
		and schema.to_raw("o|coop/coop_session/max_money_transfer", 1000000) == "1000000", "numbers are short and plain")
	check(schema.to_raw("c|coop_death_drop", "keep") == "keep" and schema.to_raw("c|coop_death_drop", "nope") == nil
		and schema.to_raw("c|coop_autosave_interval", 500) == nil and schema.to_raw("c|nope", 1) == nil, "invalid values have no raw form")
	check(schema.canon("c|coop_revive_health", "0.300000") == "0.3" and schema.canon("c|coop_death_mode", "respawn") == "checkpoint"
		and schema.canon("c|coop_friendly_fire", "ON") == "1" and schema.canon("o|alife/general/heli_spawn", "1") == "true",
		"canon makes one form of a raw value")
	check(schema.canon("o|some/unknown", "  x ") == "x" and schema.canon("c|coop_autosave_interval", "huge") == "huge",
		"an unknown key or an invalid value is only trimmed")
	local ok = true
	for _, k in ipairs(schema.keys()) do
		local it = schema.item(k)
		if k ~= "faction" then
			for _, e in ipairs(it.values) do
				local raw = schema.to_raw(k, e[1])
				if raw == nil or schema.normalize(k, raw) ~= e[1] then ok = false end
			end
		end
	end
	check(ok, "every value of every list survives to_raw and normalize")
	local p, q = schema.parse_key("o|alife/event/emission_state")
	check(p == "o" and q == "alife/event/emission_state" and schema.parse_key("faction") == nil, "parse_key splits a key")
end

-- ------------------------------------------------------------------------------------------------ text ids
do
	local ids = schema.text_ids()
	local seen, sorted, shape = {}, true, true
	for i, id in ipairs(ids) do
		if seen[id] then shape = false end
		seen[id] = true
		if i > 1 and ids[i - 1] >= id then sorted = false end
		if not id:find("^st_coop_game_[%w_]+$") then shape = false end
	end
	check(sorted and shape and #ids > 150, "text_ids: sorted, unique, plain ids (" .. #ids .. ")")
	check(seen["st_coop_game_tab_death"] and seen["st_coop_game_tab_other"] and seen["st_coop_game_on"] and seen["st_coop_game_off"]
		and seen["st_coop_game_death_mode"] and seen["st_coop_game_death_mode_hardcore"] and seen["st_coop_game_revive_health_0_75"]
		and seen["st_coop_game_applies_next_emission"] and seen["st_coop_game_applies_new_levels"]
		and seen["st_coop_game_emission_fate_turn_to_zombie"] and seen["st_coop_game_autosave_interval_0"],
		"it names the tabs, the items, their values and the hints")
	check(not seen["st_diff_1"] and not seen["st_econ_2"], "the stock strings are not in it")
	-- an id that two different values or items would share is a bug (the generated ones)
	local owner, clash = {}, {}
	for _, tab in ipairs(schema.TABS) do
		for _, it in ipairs(schema.items(tab)) do
			local function own(id, what)
				if id:find("^st_coop_game_") and id ~= "st_coop_game_on" and id ~= "st_coop_game_off" then
					if owner[id] and owner[id] ~= what then clash[#clash + 1] = id end
					owner[id] = what
				end
			end
			own(it.text, it.key)
			for _, e in ipairs(it.values) do own(e[2], it.key .. "=" .. tostring(e[1])) end
		end
	end
	check(#clash == 0, "no two items or values share a string id (" .. table.concat(clash, ",") .. ")")
end

-- ------------------------------------------------------------------------------------------------ record: new
local function make_env(t, r)
	return { now = function() return t end, rand = function(lo, hi) return r end }
end

local META = { name = "Strelok", faction = "stalker", world = { story = true, routes = false, difficulty = 2, economy = 3 } }
local VALUES = { ["c|coop_death_mode"] = "hardcore", ["o|coop/coop_session/gather_radius"] = "20", ["g|hit_power"] = 1.5 }
local T0 = 1792000000 -- 2026-10-14

do
	local a = rec.new(VALUES, META, make_env(T0, 0x1234))
	local b = rec.new(VALUES, META, make_env(T0, 0x1235))
	local c = rec.new(VALUES, META, make_env(T0, 0x1234))
	check(a.id ~= b.id, "two new() with the same time and another random number have different ids")
	check(a.id == c.id, "and the same time and number give the same id (nothing hidden)")
	check(a.id:find("^%x%x%x%x%x%x%x%x%-%x%x%x%x$") ~= nil, "id looks like 65190f3a-9c41")
	check(a.rev == 0 and a.v == 1 and a.migrated == nil, "rev is 0, the format version 1, not migrated")
	check(a.name == "Strelok" and a.faction == "stalker", "name and faction are the meta's")
	check(a.world.story == true and a.world.routes == false and a.world.difficulty == 2 and a.world.economy == 3, "the world flags are the meta's")
	check(type(a.created) == "string" and a.created:find("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$") ~= nil, "created is a date and a time")
	check(deep_equal(a.values, VALUES) and a.values ~= VALUES, "values are a copy of the argument")
	VALUES["c|coop_death_mode"] = "checkpoint"
	check(a.values["c|coop_death_mode"] == "hardcore", "a later change of the argument does not reach the record")
	VALUES["c|coop_death_mode"] = "hardcore"
	local d = rec.new({ ["o|a/b"] = { 1 }, ["o|f"] = print, [5] = "x", ["o|ok"] = "y" }, nil, make_env(T0, 1))
	check(deep_equal(d.values, { ["o|ok"] = "y" }), "only string keys with a string, number or boolean value are kept")
	check(d.world.story == true and d.world.routes == false and d.world.difficulty == 1 and d.world.economy == 1 and d.name == "" and d.faction == nil,
		"no meta: the catalog's world defaults, no name, no faction")
	local e = rec.new(nil, META, nil)
	check(e.rev == 0 and type(e.id) == "string", "without an environment it uses the system clock and random numbers")
end

-- ------------------------------------------------------------------------------------------------ record: merge
do
	local save = rec.new({}, META, make_env(T0, 1))
	local card = rec.clone(save)
	save.rev, card.rev = 1, 3
	local r, which = rec.merge(save, card)
	check(r == card and which == "card", "merge: a card of rev 3 beats a save of rev 1")
	card.rev = 1
	r, which = rec.merge(save, card)
	check(r == save and which == "save", "equal revisions: the save")
	r, which = rec.merge(save, nil)
	check(r == save and which == "save", "no card: the save")
	card.rev = 0
	save.rev = 2
	r, which = rec.merge(save, card)
	check(r == save and which == "save", "an older card: the save")
	r, which = rec.merge(nil, card)
	check(r == card and which == "card", "no block in the save: the card")
	r, which = rec.merge(nil, nil)
	check(r == nil and which == nil, "neither: nothing")
	save.rev = nil
	card.rev = 1
	r, which = rec.merge(save, card)
	check(which == "card", "a missing rev counts as 0")
	r, which = rec.merge("junk", 5)
	check(r == nil and which == nil, "values that are not tables are no records")
end

-- ------------------------------------------------------------------------------------------------ record: from_machine
local CONSOLE = {
	coop_friendly_fire = "1", coop_max_new_characters = "8", coop_share_rewards = "0", coop_death_mode = "respawn",
	coop_death_drop = "drop", coop_bleedout = "60.00000", coop_revive_health = "0.300000", coop_respawn_delay = "30.00000",
	coop_contusion = "10.00000", coop_death_money = "10.00000", coop_death_wear = "10.00000", coop_death_rank = "0.00000",
	coop_hardcore_new_kit = "0", coop_checkpoints_group = "1", coop_autosave_interval = "15", coop_autosave_count = "10",
	coop_death_share = "100.00000", coop_split_levels = "1", coop_story_together = "1", coop_nick = "Bob", fov = "67",
}

local function make_reader()
	local asked = {}
	return {
		asked = asked,
		section = function(src)
			if src == "o" then
				return {
					["alife/event/emission_frequency"] = "48", ["coop/coop_session/gather_radius"] = "25",
					["coop/coop_player/nick"] = "Bob", ["coop/coop_player/party_hud"] = "true", ["video/fov"] = "70",
					["video/weather/clear_period"] = "5", ["gameplay/general/player_name"] = "Bob",
					["alife/general/heli_spawn"] = true,
				}
			end
			return { ["drx_da/anomaly_amount_modifier"] = "1.5", ["unknown_mod/option"] = "true", ["ssfx_hud/color"] = "9" }
		end,
		-- coop_settings.owner_of: the explicit lists and the words, the unknown MCM is the host's
		owner = function(src, path)
			if path:find("^video/weather/") then return "host" end
			if path:find("^video/") or path:find("^coop/coop_player/") or path == "gameplay/general/player_name" then return "player" end
			if path:find("^ssfx_hud/") then return "player" end
			return "host"
		end,
		console = function(name)
			asked[#asked + 1] = name
			return CONSOLE[name]
		end,
		factors = function()
			return { g = { hit_power = 1.5, notify_geiger = true, type = 2 }, e = { buy = 1.2, type = 2 },
				s = { trader_buy_condition_override = 0 } }
		end,
	}
end

do
	local reader = make_reader()
	local v, problems = rec.from_machine(reader)
	check(v["o|alife/event/emission_frequency"] == "48" and v["o|coop/coop_session/gather_radius"] == "25"
		and v["o|video/weather/clear_period"] == "5", "host options are taken, a path of video/weather too")
	check(v["o|coop/coop_player/nick"] == nil and v["o|coop/coop_player/party_hud"] == nil and v["o|video/fov"] == nil
		and v["o|gameplay/general/player_name"] == nil, "the player's keys (coop/coop_player/*, video/*) are not")
	check(v["m|drx_da/anomaly_amount_modifier"] == "1.5" and v["m|unknown_mod/option"] == "true", "an MCM key, also an unknown one, is the host's")
	check(v["m|ssfx_hud/color"] == nil, "an MCM key that the classifier gives to the player is not")
	check(v["o|alife/general/heli_spawn"] == "true", "a boolean from the section is kept as a string")
	local c = 0
	for k in pairs(v) do
		if k:find("^c|") then c = c + 1 end
	end
	check(c == 19 and #reader.asked == 19, "the console: the 19 names, and only they are asked")
	check(v["c|coop_nick"] == nil and v["c|fov"] == nil, "no other console variable")
	check(v["c|coop_death_mode"] == "checkpoint" and v["c|coop_revive_health"] == "0.3" and v["c|coop_bleedout"] == "60"
		and v["c|coop_autosave_interval"] == "15" and v["c|coop_death_share"] == "100", "console values come in the canonical form")
	check(v["g|hit_power"] == 1.5 and v["g|notify_geiger"] == true and v["e|buy"] == 1.2 and v["s|trader_buy_condition_override"] == 0
		and v["g|type"] == 2, "factors and the save's values keep their types")
	check(problems == nil or #problems == 0, "no problems")

	-- a classifier that is wrong must not let the player's group in
	local lax = make_reader()
	lax.owner = function() return "host" end
	local v2 = rec.from_machine(lax)
	check(v2["o|coop/coop_player/nick"] == nil, "coop/coop_player/* never enters, whatever the classifier says")

	-- a console variable that does not exist yet is left out
	local partial = make_reader()
	partial.console = function(name) if name ~= "coop_death_share" then return CONSOLE[name] end end
	local v3 = rec.from_machine(partial)
	check(v3["c|coop_death_share"] == nil and v3["c|coop_death_mode"] == "checkpoint", "a missing console variable is not in the values")

	-- broken readers
	local bad = make_reader()
	bad.section = function(src) error("axr is not readable") end
	local v4, p4 = rec.from_machine(bad)
	check(v4["c|coop_death_mode"] == "checkpoint" and type(p4) == "table" and #p4 >= 1, "a failing section is a problem, the rest is taken")
	local noowner = make_reader()
	noowner.owner = nil
	local v5, p5 = rec.from_machine(noowner)
	check(v5["o|alife/event/emission_frequency"] == nil and v5["m|unknown_mod/option"] == nil and #p5 >= 1, "no owner function: no option is taken")
	local v6 = rec.from_machine(nil)
	check(next(v6) == nil, "no reader: nothing")
end

-- ------------------------------------------------------------------------------------------------ record: take_machine
do
	local r = rec.new({
		["c|coop_death_drop"] = "corpse", ["o|alife/general/excl_dist"] = "50", ["m|drx_da/anomaly_amount_modifier"] = "2",
		["o|gameplay/silent_kills/enabled"] = "true", ["m|zcp/abc"] = "5", ["g|hit_power"] = 2, ["s|trader_buy_condition_override"] = 7,
	}, META, make_env(T0, 9))
	r.rev = 4
	local fresh = {
		["c|coop_death_drop"] = "drop", ["o|alife/general/excl_dist"] = "0", ["m|drx_da/anomaly_amount_modifier"] = "3",
		["o|gameplay/silent_kills/enabled"] = "false", ["m|new_mod/y"] = "7", ["g|hit_power"] = 1, ["o|coop/coop_session/gather_radius"] = "30",
	}
	local out, n = rec.take_machine(r, fresh)
	check(out ~= r and r.values["o|gameplay/silent_kills/enabled"] == "true", "take_machine returns a new record, the old one is as it was")
	check(out.values["c|coop_death_drop"] == "corpse" and out.values["o|alife/general/excl_dist"] == "50"
		and out.values["m|drx_da/anomaly_amount_modifier"] == "2", "the catalog keys keep the game's values")
	check(out.values["o|coop/coop_session/gather_radius"] == nil, "even when the game had none, a catalog key is not taken from the machine")
	check(out.values["o|gameplay/silent_kills/enabled"] == "false" and out.values["m|new_mod/y"] == "7", "the other options are the machine's now")
	check(out.values["m|zcp/abc"] == nil, "and one that the machine no longer has is gone")
	check(out.values["g|hit_power"] == 2 and out.values["s|trader_buy_condition_override"] == 7, "factors are the game's own")
	check(n == 2, "n counts the options taken (" .. tostring(n) .. ")")
	check(out.id == r.id and out.rev == 4 and out.faction == "stalker" and out.name == "Strelok" and out.world.economy == 3,
		"identity, revision and world do not change (the caller raises the revision)")
	local again, n2 = rec.take_machine(out, fresh)
	check(deep_equal(again.values, out.values) and n2 == 2, "taking twice changes nothing")
	local empty = rec.take_machine(r, {})
	check(empty.values["o|gameplay/silent_kills/enabled"] == nil and empty.values["c|coop_death_drop"] == "corpse", "an empty machine clears the others only")
end

-- ------------------------------------------------------------------------------------------------ record: diff / apply
do
	local a = rec.new({ ["c|coop_revive_health"] = "0.3", ["c|coop_friendly_fire"] = "1", ["o|alife/general/heli_spawn"] = "true",
		["o|x/y"] = "1", ["g|hit_power"] = 1.5, ["o|only/in/a"] = "z" }, META, make_env(T0, 3))
	local b = rec.clone(a)
	check(next(rec.diff(a, b)) == nil, "diff of equal records is empty")
	b.values["c|coop_revive_health"] = "0.300000" -- the same value, written differently
	b.values["c|coop_friendly_fire"] = "ON"
	b.values["o|alife/general/heli_spawn"] = "1"
	check(next(rec.diff(a, b)) == nil, "the same value in another form is not a difference")
	b.values["c|coop_revive_health"] = "0.5"
	b.values["o|x/y"] = "2"
	b.values["g|hit_power"] = 2
	b.values["m|new/key"] = "k"
	b.values["o|only/in/a"] = nil
	local d = rec.diff(a, b)
	check(d["c|coop_revive_health"] == "0.5" and d["o|x/y"] == "2" and d["g|hit_power"] == 2 and d["m|new/key"] == "k",
		"diff gives the new values by key: changed and added")
	check(d["c|coop_friendly_fire"] == nil and d["o|only/in/a"] == nil, "and nothing for equal or for removed keys")
	check(next(rec.diff(a.values, a.values)) == nil and rec.diff(a.values, b.values)["o|x/y"] == "2", "plain value tables work too")
	check(next(rec.diff(nil, nil)) == nil, "no tables: empty")

	local changes = { ["c|coop_revive_health"] = 0.5, ["o|coop/coop_session/travel_time"] = false, ["g|hit_power"] = 2.5,
		["c|coop_death_mode"] = "checkpoint", ["faction"] = "monolith", ["c|coop_autosave_interval"] = 500, ["w|story"] = false,
		["m|a/b"] = 5, ["x|zzz"] = true }
	local out, refused, n = rec.apply(a, changes)
	check(out ~= a and a.rev == 0 and a.values["c|coop_revive_health"] == "0.3", "apply returns a new record, the old one is as it was")
	check(out.values["c|coop_revive_health"] == "0.5" and out.values["o|coop/coop_session/travel_time"] == "false"
		and out.values["g|hit_power"] == 2.5 and out.values["m|a/b"] == nil and out.values["x|zzz"] == nil,
		"typed changes are written in the raw form, the factor as it is")
	check(contains(refused, "m|a/b") and contains(refused, "x|zzz"), "an option outside the catalog and an unknown source are refused")
	check(contains(refused, "c|coop_death_mode") and contains(refused, "faction") and contains(refused, "w|story"),
		"a type of the world is refused: death mode, faction, the flags")
	check(contains(refused, "c|coop_autosave_interval"), "an invalid value is refused as well")
	check(out.rev == 1 and n == 3, "the revision goes up by one (" .. tostring(out.rev) .. "), 3 values changed (" .. tostring(n) .. ")")
	local same, r2, n2 = rec.apply(a, { ["c|coop_revive_health"] = 0.3 })
	check(same.rev == 0 and n2 == 0 and #r2 == 0, "a change that changes nothing keeps the revision")
end

-- ------------------------------------------------------------------------------------------------ record: encode / decode
local function ser(v)
	local t = type(v)
	if t == "table" then
		local parts = {}
		for _, k in ipairs(sorted_keys(v)) do parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(v[k]) end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end
local STUB = {
	encode = function(t) return ser(t) end,
	decode = function(s)
		local f = assert(loadstring("return " .. s))
		setfenv(f, {})
		return f()
	end,
}

do
	local r = rec.new(VALUES, META, make_env(T0, 0x0abc))
	r.rev = 3
	r.migrated = true
	r.last_save = "coop_auto_1"
	r.last_played = "2026-10-23 20:00"
	r.machine_snapshot_at = "2026-10-23 19:55"
	local s = rec.encode(r, STUB)
	check(type(s) == "string" and #s > 20, "encode gives a string")
	local back = rec.decode(s, STUB)
	check(back ~= nil and deep_equal(back, r), "decode(encode(record)) is the record, card fields included")
	check(back.values["g|hit_power"] == 1.5 and back.world.economy == 3 and back.rev == 3 and back.migrated == true, "types survive")

	local junk = rec.new({ ["o|ok"] = "1" }, META, make_env(T0, 7))
	junk.values["o|fn"] = print
	junk.values["o|tab"] = { 1 }
	junk.extra_field = "from the future"
	local s2 = rec.encode(junk, STUB)
	check(not s2:find("function", 1, true) and not s2:find("from the future", 1, true), "encode writes the known fields and plain values only")

	check(rec.decode("garbage {{", STUB) == nil, "a string that does not decode is no record")
	check(rec.decode(nil, STUB) == nil and rec.decode(s, nil) == nil and rec.decode(s, {}) == nil, "no string or no codec: nothing")
	local function with(patch)
		local t = STUB.decode(s)
		patch(t)
		return STUB.encode(t)
	end
	check(rec.decode(with(function(t) t.id = nil end), STUB) == nil, "a record without an id is rejected")
	check(rec.decode(with(function(t) t.values = "x" end), STUB) == nil, "a record without values is rejected")
	check(rec.decode(with(function(t) t.v = nil end), STUB) == nil and rec.decode(with(function(t) t.v = 2 end), STUB) == nil,
		"a record without a version, or of a newer format, is rejected")
	local odd = rec.decode(with(function(t) t.rev = -4; t.world = "x"; t.values["o|fn"] = {}; t.name = 5 end), STUB)
	check(odd ~= nil and odd.rev == 0 and next(odd.world) == nil and odd.values["o|fn"] == nil and odd.name == "",
		"odd fields are cleaned: a negative rev is 0, a bad world is empty, a table value is dropped")
	local failing = { encode = function() error("boom") end, decode = function() error("boom") end }
	check(rec.encode(r, failing) == nil and rec.decode(s, failing) == nil, "a failing codec gives nil, not an error")
	check(rec.encode("x", STUB) == nil and rec.encode(r, nil) == nil, "encode of a non-record or without a codec gives nil")
end

-- ------------------------------------------------------------------------------------------------ purity
do
	for _, name in ipairs({ "coop_game_schema", "coop_game_record" }) do
		local src = read_file("gamedata/scripts/" .. name .. ".script") or ""
		local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
		local hits = {}
		for _, bad in ipairs({ "printf", "exec_console_cmd", "get_console_cmd", "time_global", "level%.", "coop%.", "marshal", "ini_file",
			"alife_storage_manager", "axr_main", "game%.translate_string", "io%.", "os%.execute" }) do
			if code:find("%f[%w_]" .. bad) then hits[#hits + 1] = bad end
		end
		check(#hits == 0, name .. " does not mention the engine (" .. table.concat(hits, ",") .. ")")
	end
end

print("== title and at (co-op window, docs\\plans\\2026-10-30-coop-chronicle-menu.md)")
do
	local codec = STUB
	local env = { now = function() return 1000 end, rand = function() return 1 end, date = function() return "2026-10-29 20:31" end }
	local r = rec.new({}, { name = "Stalker", title = "With Kent" }, env)
	check(r.title == "With Kent" and r.name == "Stalker", "a new record keeps the title apart from the character's name")
	local plain = rec.new({}, { name = "Stalker" }, env)
	check(plain.title == nil, "no title: none (the window names the game by its date)")
	local c = rec.clone(r)
	check(c.title == "With Kent", "clone keeps the title")
	local back = rec.decode(rec.encode(r, codec), codec)
	check(back and back.title == "With Kent", "encode and decode keep the title")
	check(rec.merge(r, nil).title == "With Kent", "merge keeps the title")
	local long = rec.new({}, { title = string.rep("x", 500) }, env)
	check(#rec.decode(rec.encode(long, codec), codec).title <= 64, "a title has a limit in the file")
	r.at = { level = "k00_marsh", game_time = "15/03/2012 07:05", real_time = 1000, players = { "stormie", "kent" }, junk = 1 }
	local d = rec.decode(rec.encode(r, codec), codec)
	check(d.at and d.at.level == "k00_marsh" and d.at.game_time == "15/03/2012 07:05" and d.at.real_time == 1000, "where and when a save was made comes through")
	check(d.at.players[2] == "kent" and d.at.junk == nil, "the players too, and nothing else")
	local cl = rec.clone(r)
	check(cl.at ~= r.at and cl.at.players ~= r.at.players and cl.at.players[1] == "stormie", "a clone has its own copy")
	r.at = { players = "x", level = 5 }
	check(rec.decode(rec.encode(r, codec), codec).at == nil, "an `at` with nothing usable in it is dropped")
	r.at = "junk"
	check(rec.decode(rec.encode(r, codec), codec).at == nil, "and one that is no table")
end

finish()
