--[[
	Anomaly Coop: the game's settings catalog as gamedata\configs\coop\game_schema.json, for the launcher's "new world" form.
	Run from the repository root with the test suite's Lua host:  tools\export_game_schema.cmd
	(= temp\lua\runlua.exe tools\export_game_schema.lua; runlua.exe passes no arguments, the knobs are environment variables:
	 COOP_SCHEMA_OUT   the output file (default gamedata/configs/coop/game_schema.json)
	 COOP_STOCK_TEXT   a folder with the stock string tables <lang>\st_mm_faction_select.xml (default: ..\anomaly-ref\unpacked\
	                   configs\text, then E:\RayLinkGames\GAMMA\game-dev\gamedata\configs\text))
	Loaded with EXPORT_GAME_SCHEMA_AS_LIBRARY = true it only returns its functions (tests\lua\test_game_schema_export.lua).

	What it reads, all of it as the game has it now:
	  coop_game_schema.script     the catalog: items(tab), kinds, values with their string ids, defaults, shown_if, needs_mcm
	  coop_newgame_modes.script   the tabs of the new game screen and the keys the stock controls of that screen carry
	  coop_dedicated.script       stage_new_world: what a world server keeps of a "<key>" = <raw> line of coop_new_world.ltx; a key it
	                              overrides (a world server's world is always of split levels) is no choice and is left out
	  coop_json_card.script       utf8(): cp1251 -> UTF-8
	  text\{rus,eng}\st_coop_game.xml, st_coop_newgame.xml and the stock st_mm_faction_select.xml (factions, presets)

	Format 1 (one JSON object, UTF-8 without BOM, keys in a fixed order, one array element per line):
	  format, factions [{id, title}], world {difficulty [{raw, label}], economy [...], defaults {story, routes, difficulty, economy}},
	  tabs [{id, title}], items [{key, tab, kind ("check" | "list"), title, hint ("" or {rus, eng}), default, options [{raw, label}],
	  shownIf {key, any} when the catalog has one}]; a check has two options, off then on. title / label = {rus, eng}.

	Fails (exit code 1, "export_game_schema: ERROR ...") when a string id has no text in a language, when an item has a kind the
	export does not know, when an option's raw value does not survive coop_game_schema.canon or the server's staging, or when a
	shown_if names a key that is not exported.
]]

local M = {}

M.OUT = os.getenv("COOP_SCHEMA_OUT") or "gamedata/configs/coop/game_schema.json"
M.LANGS = { "rus", "eng" }
M.REPO_TEXT = { "st_coop_game.xml", "st_coop_newgame.xml" }
M.STOCK_TEXT = "st_mm_faction_select.xml"
M.STOCK_DIRS = { os.getenv("COOP_STOCK_TEXT"), "../anomaly-ref/unpacked/configs/text", "E:/RayLinkGames/GAMMA/game-dev/gamedata/configs/text" }
M.NO_STOCK = "no stock string table"
-- The factions of the stock new game screen (ui_mm_faction_select.script UINewGame: table_faction, in the order of its grid
-- faction_cell, row by row). renegade, greh and isg are there only when [unlocked_factions] of the player's axr_options.ltx says so
-- (or a cheat word was typed): a launcher cannot know that, they are left out.
M.FACTIONS = { "stalker", "bandit", "csky", "dolg", "freedom", "killer", "army", "ecolog", "monolith" }

local format = string.format

-------------------------------------------------------------------------------
-- Files and the sealed environment of the game's scripts
-------------------------------------------------------------------------------
local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end
M.read_file = read_file

-- The scripts are loaded as the Lua tests load them: the standard library and nothing of the engine; every module is a global of
-- the others (CScriptStorage). The record's staging goes to a stand-in that keeps the last record.
function M.sandbox()
	local SAFE = {}
	for _, n in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset",
		"select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "string", "table", "math" }) do
		SAFE[n] = _G[n]
	end
	SAFE.os = { time = os.time, date = os.date, clock = os.clock }
	SAFE._G = SAFE
	SAFE.printf = function() end
	local box = { SAFE = SAFE }
	SAFE.coop_game_settings = {
		stage_new = function(r) box.staged = r; return true end,
		active = function() return nil end,
	}
	function box.load(name)
		local path = "gamedata/scripts/" .. name .. ".script"
		local src = read_file(path)
		if not src then error(path .. " is missing (run from the repository root)", 0) end
		local f, err = loadstring(src, "@" .. name .. ".script")
		if not f then error(err, 0) end
		local env = setmetatable({}, { __index = SAFE })
		setfenv(f, env)
		local ok, err2 = pcall(f)
		if not ok then error(name .. ".script does not load: " .. tostring(err2), 0) end
		SAFE[name] = env
		return env
	end
	return box
end

-------------------------------------------------------------------------------
-- Strings
-------------------------------------------------------------------------------
local ENTITY = { lt = "<", gt = ">", quot = "\"", apos = "'" }

-- { id = UTF-8 text } of a string table; comments are skipped, the first definition of an id wins, a cp1251 file is converted.
function M.parse_strings(text, utf8, into)
	into = into or {}
	local enc = text:match("^[^\n]-<%?xml[^>]-encoding%s*=%s*\"([^\"]+)\"")
	local is_utf8 = enc and enc:lower():gsub("[^%w]", "") == "utf8"
	text = text:gsub("<!%-%-.-%-%->", "")
	for id, body in text:gmatch("<string%s+id%s*=%s*\"([^\"]+)\"%s*>(.-)</string>") do
		if into[id] == nil then
			local t = body:match("<text>(.-)</text>") or ""
			if not is_utf8 then t = utf8(t) end
			t = t:gsub("&(%a+);", ENTITY):gsub("&amp;", "&")
			into[id] = t
		end
	end
	return into
end

-- tr(id) -> { rus = text, eng = text }; an id without a (non-empty) text in a language is an error.
function M.translator(tables)
	return function(id)
		local out = {}
		for _, lang in ipairs(M.LANGS) do
			local s = tables[lang] and tables[lang][id]
			if type(id) ~= "string" or s == nil or s == "" then
				error(format("the string '%s' has no text in %s", tostring(id), lang), 0)
			end
			out[lang] = s
		end
		return out
	end
end

-- The string tables of both languages: the mod's own files, then the stock file of the faction screen (the first folder that has it).
function M.load_strings(utf8)
	local tables = {}
	for _, lang in ipairs(M.LANGS) do
		local t = {}
		for _, name in ipairs(M.REPO_TEXT) do
			local path = "gamedata/configs/text/" .. lang .. "/" .. name
			local src = read_file(path)
			if not src then error(path .. " is missing", 0) end
			M.parse_strings(src, utf8, t)
		end
		local found
		for i = 1, #M.STOCK_DIRS + 1 do
			local dir = M.STOCK_DIRS[i]
			if dir then
				local src = read_file(dir .. "/" .. lang .. "/" .. M.STOCK_TEXT)
				if src then
					M.parse_strings(src, utf8, t)
					found = dir
					break
				end
			end
		end
		if not found then
			error(format("%s %s/%s in any of: %s (set COOP_STOCK_TEXT)", M.NO_STOCK, lang, M.STOCK_TEXT,
				table.concat({ M.STOCK_DIRS[1] or "", M.STOCK_DIRS[2] or "", M.STOCK_DIRS[3] or "" }, ", ")), 0)
		end
		tables[lang] = t
	end
	return tables
end

-------------------------------------------------------------------------------
-- JSON
-------------------------------------------------------------------------------
local NAMED = { ["\""] = "\\\"", ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

-- A UTF-8 string as a JSON string (control characters escaped, the rest as it is).
function M.json_string(s)
	return "\"" .. tostring(s):gsub("[%z\1-\31\"\\\127]", function(c)
		return NAMED[c] or format("\\u%04x", c:byte())
	end) .. "\""
end

-- An object with its keys in order: obj("a", 1, "b", 2). A nil value leaves the key out.
local function obj(...)
	local t, order = {}, {}
	for i = 1, select("#", ...), 2 do
		local k, v = select(i, ...)
		if v ~= nil then
			order[#order + 1] = k
			t[k] = v
		end
	end
	return setmetatable(t, { __order = order })
end
M.obj = obj

local function encode(v)
	local tv = type(v)
	if tv == "string" then return M.json_string(v) end
	if tv == "boolean" then return v and "true" or "false" end
	if tv == "number" then
		if v == math.floor(v) and math.abs(v) < 1e15 then return format("%d", v) end
		return format("%.14g", v)
	end
	if tv == "table" then
		local mt = getmetatable(v)
		local parts = {}
		if mt and mt.__order then
			for _, k in ipairs(mt.__order) do parts[#parts + 1] = M.json_string(k) .. ":" .. encode(v[k]) end
			return "{" .. table.concat(parts, ",") .. "}"
		end
		for i = 1, #v do parts[i] = encode(v[i]) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	error("cannot encode a " .. tv, 0)
end
M.encode = encode

local function label(t)
	return obj("rus", t.rus, "eng", t.eng)
end

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------
-- A raw value of the key that canon keeps as it is, or an error.
local function raw_of(sc, key, v, what)
	local raw = sc.to_raw(key, v)
	if raw == nil or sc.canon(key, raw) ~= raw then
		error(format("%s of %s: the value %s does not survive canon (to_raw %s, canon %s)", what, key, tostring(v), tostring(raw),
			tostring(raw ~= nil and sc.canon(key, raw) or nil)), 0)
	end
	return raw
end

-- The exported item of a catalog item: { key, tab, kind, title, hint, default, options = { {raw, label}, ... }, shownIf }.
-- tr(id) -> { rus, eng }. A check is off then on; a list keeps the catalog's order (the screen's).
function M.export_item(sc, it, tr)
	local key, kind = it.key, it.kind
	local entries
	if kind == "check" then
		local off, on
		for _, e in ipairs(it.values or {}) do
			if e[1] == false then off = e elseif e[1] == true then on = e end
		end
		if not (off and on and #it.values == 2) then error(format("%s: a check without exactly the values off / on", key), 0) end
		entries = { off, on }
	elseif kind == "list" then
		entries = {}
		for _, e in ipairs(it.values or {}) do
			if not e.extra then entries[#entries + 1] = e end
		end
		if #entries == 0 then error(format("%s: a list without values", key), 0) end
	else
		error(format("%s: the kind '%s' is not one the export knows (check, list)", key, tostring(kind)), 0)
	end
	local options, raws = {}, {}
	for i, e in ipairs(entries) do
		local raw = raw_of(sc, key, e[1], "an option")
		if raws[raw] then error(format("%s: the raw value %s twice", key, raw), 0) end
		raws[raw] = true
		if type(e[2]) ~= "string" then error(format("%s: the option %s has no string id", key, raw), 0) end
		options[i] = obj("raw", raw, "label", label(tr(e[2])))
	end
	if it.def == nil then error(format("%s: no default", key), 0) end
	local def = raw_of(sc, key, it.def, "the default")
	if not raws[def] then error(format("%s: the default %s is not one of the options", key, def), 0) end
	local shown
	if it.shown_if then
		local any = {}
		for i, v in ipairs(it.shown_if.any or {}) do any[i] = raw_of(sc, it.shown_if.key, v, "shown_if of " .. key) end
		shown = obj("key", it.shown_if.key, "any", any)
	end
	return obj("key", key, "tab", it.tab, "kind", kind, "title", label(tr(it.text)),
		"hint", it.note and label(tr(it.note)) or "", "default", def, "options", options, "shownIf", shown)
end

-- The screen's tabs and the keys of the stock controls, read from coop_newgame_modes.script (they are locals there).
function M.screen()
	local src = read_file("gamedata/scripts/coop_newgame_modes.script")
	if not src then error("gamedata/scripts/coop_newgame_modes.script is missing", 0) end
	local tabs_src = src:match("\nlocal TABS = (%b{})")
	local ext_src = src:match("\nlocal EXTERNAL = (%b{})")
	if not (tabs_src and ext_src) then error("coop_newgame_modes.script: no 'local TABS = {...}' or 'local EXTERNAL = {...}'", 0) end
	local tabs, external = {}, {}
	for t in tabs_src:gmatch("\"([%w_]+)\"") do tabs[#tabs + 1] = t end
	for k in ext_src:gmatch("%[\"([^\"]+)\"%]%s*=%s*true") do external[k] = true end
	if #tabs == 0 or next(external) == nil then error("coop_newgame_modes.script: TABS or EXTERNAL is empty", 0) end
	return tabs, external
end

-- What the record of a world server keeps of "<key>" = raw in [values] of coop_new_world.ltx (nil = dropped).
local function staged_value(box, ded, key, raw)
	box.staged = nil
	local ok, why = ded.stage_new_world("game_schema_export", { world = { faction = "stalker" }, values = { [key] = raw } })
	if not ok then error(format("stage_new_world refused %s = %s: %s", key, raw, tostring(why)), 0) end
	return box.staged and box.staged.values and box.staged.values[key]
end

-- Builds the whole object; returns it and the list of what was left out { {key, why}, ... }.
function M.build()
	local box = M.sandbox()
	local sc = box.load("coop_game_schema")
	box.load("coop_game_record")
	local ded = box.load("coop_dedicated")
	local card = box.load("coop_json_card")
	sc.reset_extras()
	local tr = M.translator(M.load_strings(card.utf8))
	local tabs, external = M.screen()
	local left = {}

	local factions = {}
	for i, id in ipairs(M.FACTIONS) do factions[i] = obj("id", id, "title", label(tr("st_faction_" .. id))) end

	local function presets(key)
		local it = sc.item(key)
		if not it then error("the catalog has no " .. key, 0) end
		local out = {}
		for i, e in ipairs(it.values) do out[i] = obj("raw", raw_of(sc, key, e[1], "a preset"), "label", label(tr(e[2]))) end
		return out
	end
	local function flag(key)
		local v = sc.default(key)
		if type(v) ~= "boolean" then error(key .. ": the default is not a flag", 0) end
		return v
	end
	local function preset_default(key)
		local v = sc.default(key)
		if type(v) ~= "number" then error(key .. ": the default is not a number", 0) end
		return v
	end
	local world = obj("difficulty", presets("w|difficulty"), "economy", presets("w|economy"),
		"defaults", obj("story", flag("w|story"), "routes", flag("w|routes"), "difficulty", preset_default("w|difficulty"),
			"economy", preset_default("w|economy")))

	-- the candidates, tab by tab in the screen's order
	local cand, forced = {}, {}
	for _, tab in ipairs(tabs) do
		for _, it in ipairs(sc.items(tab)) do
			if external[it.key] then
				-- the stock controls: factions / world above
			elseif it.needs_mcm then
				left[#left + 1] = { it.key, "needs the MCM addon " .. tostring(it.needs_mcm) .. ": the screen shows it only when the addon is installed" }
			elseif #(it.values or {}) == 0 then
				left[#left + 1] = { it.key, "no list of values" }
			else
				local x = M.export_item(sc, it, tr)
				-- what the world server keeps of each option: a key it overrides is no choice
				local kept_all, kept = true, {}
				for _, o in ipairs(x.options) do
					local v = staged_value(box, ded, x.key, o.raw)
					kept[#kept + 1] = tostring(v)
					if v ~= o.raw then kept_all = false end
				end
				if kept_all then
					cand[#cand + 1] = x
				else
					local fv = staged_value(box, ded, x.key, x.default)
					forced[x.key] = fv
					left[#left + 1] = { x.key, format("the world server overrides it: every value is stored as %s (coop_dedicated.stage_new_world)",
						tostring(fv)) }
				end
			end
		end
	end
	for _, tab in ipairs(sc.TABS or {}) do
		local on_screen = false
		for _, t in ipairs(tabs) do if t == tab then on_screen = true end end
		if not on_screen then
			for _, it in ipairs(sc.items(tab)) do
				if not external[it.key] then left[#left + 1] = { it.key, "the tab " .. tab .. " is not on the new game screen" } end
			end
		end
	end

	-- shown_if on a key the server overrides: always met (dropped) or never met (the item is left out)
	local exported, items = {}, {}
	for _, x in ipairs(cand) do exported[x.key] = true end
	for _, x in ipairs(cand) do
		local s = x.shownIf
		if s and forced[s.key] ~= nil then
			local met = false
			for _, v in ipairs(s.any) do if v == forced[s.key] then met = true end end
			if met then
				getmetatable(x).__order[#getmetatable(x).__order] = nil
				x.shownIf = nil
				items[#items + 1] = x
			else
				left[#left + 1] = { x.key, "shown only while " .. s.key .. " is not what the world server forces" }
			end
		elseif s and not exported[s.key] then
			error(format("%s: shown_if names %s, which is not exported", x.key, s.key), 0)
		else
			items[#items + 1] = x
		end
	end
	if #items == 0 then error("no items", 0) end

	local tab_list = {}
	for _, tab in ipairs(tabs) do
		local n = 0
		for _, x in ipairs(items) do if x.tab == tab then n = n + 1 end end
		if n > 0 then
			tab_list[#tab_list + 1] = obj("id", tab, "title", label(tr("st_coop_newgame_tab_" .. tab)))
		else
			left[#left + 1] = { "tab " .. tab, "no item to choose (a text page or only stock controls)" }
		end
	end

	return obj("format", 1, "factions", factions, "world", world, "tabs", tab_list, "items", items), left
end

-- The file's text: top-level keys and the world on their own lines, one array element per line.
function M.render(o)
	local function list(arr, indent)
		if #arr == 0 then return "[]" end
		local lines = {}
		for i, v in ipairs(arr) do lines[i] = indent .. "  " .. encode(v) end
		return "[\n" .. table.concat(lines, ",\n") .. "\n" .. indent .. "]"
	end
	local w = o.world
	return table.concat({
		"{",
		"  \"format\": " .. encode(o.format) .. ",",
		"  \"factions\": " .. list(o.factions, "  ") .. ",",
		"  \"world\": {",
		"    \"difficulty\": " .. list(w.difficulty, "    ") .. ",",
		"    \"economy\": " .. list(w.economy, "    ") .. ",",
		"    \"defaults\": " .. encode(w.defaults),
		"  },",
		"  \"tabs\": " .. list(o.tabs, "  ") .. ",",
		"  \"items\": " .. list(o.items, "  "),
		"}",
		"",
	}, "\n")
end

function M.generate()
	local o, left = M.build()
	return M.render(o), left, o
end

function M.main()
	local ok, text, left, o = pcall(M.generate)
	if not ok then
		print("export_game_schema: ERROR " .. tostring(text))
		os.exit(1)
	end
	local fh = io.open(M.OUT, "wb")
	if not fh then
		os.execute("mkdir \"" .. M.OUT:gsub("/[^/]*$", ""):gsub("/", "\\") .. "\" 2>nul")
		fh = io.open(M.OUT, "wb")
	end
	if not fh then
		print("export_game_schema: ERROR cannot write " .. M.OUT)
		os.exit(1)
	end
	fh:write(text)
	fh:close()
	print(format("export_game_schema: %s written: %d factions, %d tabs, %d items", M.OUT, #o.factions, #o.tabs, #o.items))
	for _, l in ipairs(left) do print("  left out " .. l[1] .. ": " .. l[2]) end
end

if rawget(_G, "EXPORT_GAME_SCHEMA_AS_LIBRARY") then return M end
M.main()
