-- R38 guard: every script that keeps a HUD window across frames is adapted in coop_hud_lifecycle or marked safe here.
--
-- CHUDManager::OnScreenResolutionChanged (engine HUDManager.cpp:664-691) deletes the main HUD, the PDA, the actor menu,
-- get_hud():GetWindow() and the messages with every window under them (UIGameCustom.cpp:277-283), builds new ones and sends
-- on_screen_resolution_changed. A Lua handle to an old window then points at freed memory (the crashes of 2026-11-21
-- 20:46). The rule lives in gamedata/scripts/coop_hud_lifecycle.script; this test is how it covers mods added later: it
-- reads the scripts of the stand (the G.A.M.M.A. profile, the stock scripts it does not override, ours) and lists every
-- script that keeps such a handle in a place that outlives the call:
--   main    a main window (ActorMenu.get_maingame / get_pda_menu / get_actor_menu / get_messages_menu,
--           get_hud():GetWindow / GetChild) stored in a file local, a global, a field or a table
--   anchor  a main window given to a call that makes windows under it (xml:InitStatic(node, <main>), Class(<main>, ...))
--   static  a CustomStatic (get_hud():GetCustomStatic / AddCustomStatic, or its :wnd()) stored the same way; it outlives
--           the rebuild but keeps the layout of the size it was made for
--   dialog  a dialog given to get_hud():AddDialogToRender; it outlives the rebuild (the render list is not cleared), its
--           children must not be made under a main window
-- A handle taken into a local of a function counts when that local is stored the same way or given to such a call later in
-- the function. A listed (script, kind) must be covered by an adapter (coop_hud_lifecycle.covered()) or by SAFE below,
-- with the reason it is safe. A new mod that keeps a HUD window fails here until it is adapted or marked.
-- Folders: GAMMA_SCRIPTS (tools\test_lua.cmd sets the stand), the stock scripts (STOCK_SCRIPTS, else
-- ../anomaly-ref/unpacked/scripts or temp/stock_scripts/scripts), and in this repository gamedata/scripts,
-- engine/gamedata/scripts and gamedata_gamma/scripts (they win over the same name on the stand).
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/mod_source.lua") -- GAMMA_DIR
local HUD = dofile("tests/lua/support/hud_fake.lua")
local BS = string.char(92)

-- (script, kind) -> why it is safe. Every entry was read in the script itself (lines of the stand, 2026-11-22).
local OWN_DIALOG = "its own dialog to render, its windows made under itself: UnLoad does not clear the render list "
	.. "(UIGameCustom.cpp:277-283, UIDialogHolder.cpp:125)"
local SAFE = {
	ab_move_notification = { static = "takes cs again right before every use (ab_move_notification.script:10-14)" },
	actor_status = { dialog = OWN_DIALOG },
	alq_hunger_hud = { dialog = OWN_DIALOG .. "; it also takes the panel down on on_screen_resolution_changed (173)" },
	axr_companions = { dialog = OWN_DIALOG },
	coop_core_chat = { dialog = OWN_DIALOG },
	coop_core_hud = { dialog = OWN_DIALOG .. "; it applies the minimap option to the new main HUD on the event (1003)" },
	coop_hud_arena = { dialog = OWN_DIALOG },
	coop_hud_compass = { dialog = OWN_DIALOG },
	coop_hud_glare = { dialog = OWN_DIALOG },
	coop_hud_netgraph = { dialog = OWN_DIALOG },
	coop_hud_ping = { dialog = OWN_DIALOG },
	coop_hud_revive = { dialog = OWN_DIALOG },
	coop_hud_transition = { dialog = OWN_DIALOG },
	coop_npc_companions_ui = { dialog = OWN_DIALOG },
	-- the registry itself: its sr_timer adapter gives sr_timer's st.timer the window of the new hud_timer
	coop_hud_lifecycle = { static = "the registry: rebuild_sr_timer stores the new hud_timer window into sr_timer's st.timer" },
	dynamic_emission_cover_mcm = { dialog = OWN_DIALOG },
	factionid_hud_mcm = { dialog = OWN_DIALOG .. "; it builds the panel again on on_screen_resolution_changed (145)" },
	hf_placement_hud = { dialog = OWN_DIALOG },
	item_artefact = { dialog = OWN_DIALOG },
	item_radio = { dialog = OWN_DIALOG },
	lua_help = { dialog = "not Lua: the stock list of the engine's exported classes, never run" },
	-- its labels on PDA map spots: CMapManager::ReloadSpots makes new spots and leaves the old ones allocated
	-- (map_location.cpp:97-160, LoadSpot without reload), so a label on an old spot is not drawn, not freed
	tasks_placeable_waypoints = { dialog = OWN_DIALOG .. "; its map spot labels outlive ReloadSpots (not freed)" },
	ui_sidhud_mcm = { dialog = OWN_DIALOG },
	utils_catspaw_hudmarks = {
		dialog = OWN_DIALOG,
		anchor = "init_hud_mark falls back to the main HUD only without args.anchor; its caller UIHUDMarker:__init passes "
			.. "the marker itself (utils_catspaw_hudmarks.script:691, 1082)",
	},
}

-------------------------------------------------------------------------------
-- the files
-------------------------------------------------------------------------------
local function list_dir(dir)
	local names = {}
	local pipe = io.popen('dir /b /a-d "' .. dir .. BS .. '*.script" 2>nul')
	if not pipe then return names end
	for line in pipe:lines() do
		line = line:gsub("\r", "")
		local name = line:match("^(.+)%.script$")
		if name then names[#names + 1] = name end
	end
	pipe:close()
	return names
end

local function first_dir(probe, ...)
	for i = 1, select("#", ...) do
		local d = select(i, ...)
		if d and d ~= "" and have_file(d .. BS .. probe) then return d end
	end
	return nil
end

local STOCK_DIR = first_dir("sr_timer.script", os.getenv("STOCK_SCRIPTS"),
	".." .. BS .. "anomaly-ref" .. BS .. "unpacked" .. BS .. "scripts", "temp" .. BS .. "stock_scripts" .. BS .. "scripts")
local GAMMA_OK = have_file(GAMMA_DIR .. BS .. "ui_hud_dotmarks.script")
check(GAMMA_OK, "the G.A.M.M.A. scripts are readable: " .. tostring(GAMMA_DIR))
check(STOCK_DIR ~= nil, "the stock scripts are readable (STOCK_SCRIPTS, ../anomaly-ref/unpacked/scripts or temp/stock_scripts/scripts)")

-- name -> path; the first folder that has a name wins
local ROOTS = {
	"gamedata" .. BS .. "scripts",
	"engine" .. BS .. "gamedata" .. BS .. "scripts",
	"gamedata_gamma" .. BS .. "scripts",
	GAMMA_OK and GAMMA_DIR or nil,
	STOCK_DIR,
}
local FILES, NAMES = {}, {}
for i = 1, 5 do
	local dir = ROOTS[i]
	if dir then
		for _, name in ipairs(list_dir(dir)) do
			local key = name:lower()
			if not FILES[key] then
				FILES[key] = dir .. BS .. name .. ".script"
				NAMES[#NAMES + 1] = key
			end
		end
	end
end
table.sort(NAMES)

-------------------------------------------------------------------------------
-- the scanner
-------------------------------------------------------------------------------
-- Comments and string contents out, line breaks kept (line numbers stay the file's).
local function strip(src)
	local out, i, n = {}, 1, #src
	local function blank(s) return (s:gsub("[^\n]", "")) end
	while i <= n do
		local c = src:sub(i, i)
		if c == "-" and src:sub(i + 1, i + 1) == "-" then
			local lvl = src:match("^%[(=*)%[", i + 2)
			if lvl then
				local close = "]" .. lvl .. "]"
				local e = src:find(close, i + 2, true)
				out[#out + 1] = blank(src:sub(i, e and (e + #close - 1) or n))
				i = e and (e + #close) or (n + 1)
			else
				local e = src:find("\n", i, true)
				i = e or (n + 1)
			end
		elseif c == "[" and src:match("^%[=*%[", i) then
			local lvl = src:match("^%[(=*)%[", i)
			local close = "]" .. lvl .. "]"
			local e = src:find(close, i, true)
			out[#out + 1] = '""' .. blank(src:sub(i, e and (e + #close - 1) or n))
			i = e and (e + #close) or (n + 1)
		elseif c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = src:sub(j, j)
				if d == "\\" then j = j + 2
				elseif d == c or d == "\n" then break
				else j = j + 1 end
			end
			out[#out + 1] = c .. c
			i = j + 1
		else
			local j = src:find("[%-%[\"']", i + 1) or (n + 1)
			out[#out + 1] = src:sub(i, j - 1)
			i = j
		end
	end
	return table.concat(out)
end

local MAIN = {
	"ActorMenu%s*%.%s*get_maingame%s*%(%s*%)",
	"ActorMenu%s*%.%s*get_pda_menu%s*%(%s*%)",
	"ActorMenu%s*%.%s*get_actor_menu%s*%(%s*%)",
	"ActorMenu%s*%.%s*get_messages_menu%s*%(%s*%)",
	":%s*GetWindow%s*%(%s*%)",
	"get_hud%s*%(%s*%)%s*:%s*GetChild%s*%b()",
}
local STATIC = {
	":%s*GetCustomStatic%s*%b()",
	":%s*AddCustomStatic%s*%b()",
}
local DIALOG = "AddDialogToRender%s*%("

-- The assignment a position on a line is the right side of: its left side, or nil.
local function lhs_before(line, pos)
	local before = line:sub(1, pos - 1)
	local cut
	for p = #before, 1, -1 do
		local c = before:sub(p, p)
		if c == "=" then
			local prev, nxt = before:sub(p - 1, p - 1), before:sub(p + 1, p + 1)
			if nxt ~= "=" and prev ~= "=" and prev ~= "~" and prev ~= "<" and prev ~= ">" then
				cut = p
				break
			end
		end
	end
	if not cut then return nil end
	local lhs = before:sub(1, cut - 1)
	-- the statement starts after the last keyword that opens one on this line
	lhs = lhs:gsub("^.*%f[%w_]function%f[^%w_]%s*[%w_%.:]*%s*%b()", "")
	lhs = lhs:gsub("^.*%f[%w_]then%f[^%w_]", ""):gsub("^.*%f[%w_]do%f[^%w_]", ""):gsub("^.*%f[%w_]else%f[^%w_]", "")
	lhs = lhs:gsub("^.*;", "")
	-- several statements on one line: the target is what follows the last call before the `=`
	local tail = lhs:match("%)%s+([^%)]+)$")
	if tail and tail:match("^[%w_%.%[%]\"' ,]+$") then lhs = tail end
	return lhs
end

-- Is the position inside the argument list of a call (not the receiver of a method call)?
local function in_call_args(line, pos)
	local depth = 0
	for p = pos - 1, 1, -1 do
		local c = line:sub(p, p)
		if c == ")" then depth = depth + 1
		elseif c == "(" then
			if depth == 0 then
				local callee = line:sub(1, p - 1):match("([%w_%.:]+)%s*$")
				if callee and not callee:match("^if$") and not callee:match("^and$") and not callee:match("^or$")
					and not callee:match("^not$") and not callee:match("^return$") then
					return callee
				end
				return nil
			end
			depth = depth - 1
		end
	end
	return nil
end

-- A call that makes windows under its argument: xml:Init*, AttachChild, a class (capitalised) constructor.
local NOT_A_CLASS = { SendScriptCallback = true, RegisterScriptCallback = true, UnregisterScriptCallback = true,
	CreateTimeEvent = true, RemoveTimeEvent = true, AddUniqueCall = true }
local function makes_windows(callee)
	if not callee then return false end
	local last = callee:match("([%w_]+)$") or callee
	if last:match("^Init") or last == "AttachChild" then return true end
	if callee:find(":", 1, true) then return false end -- a method of something (Show, SetText, ...)
	return last:match("^[A-Z]") ~= nil and not last:match("^Get") and not NOT_A_CLASS[last]
end

-- What follows a source on the line: .field, [key], :method(...), (...). Returns the number of steps, whether the last one
-- is a call and its name. The result of a method is a value (a text, a position), except the ones that give a window.
local WINDOW_RESULT = { wnd = true, TextControl = true, GetChild = true, GetWindow = true }
local function chain_after(line, e)
	local pos, steps, last_call, last_name = e + 1, 0, false, nil
	while true do
		local s, f, name = line:find("^%s*%.%s*([%w_]+)", pos)
		if s then
			pos, steps, last_call, last_name = f + 1, steps + 1, false, name
		else
			s, f, name = line:find("^%s*:%s*([%w_]+)%s*%b()", pos)
			if s then
				pos, steps, last_call, last_name = f + 1, steps + 1, true, name
			else
				s, f = line:find("^%s*%b()", pos)
				if s then
					pos, steps, last_call = f + 1, steps + 1, true
				else
					s, f = line:find("^%s*%b[]", pos)
					if not s then break end
					pos, steps, last_call = f + 1, steps + 1, false
				end
			end
		end
	end
	return steps, last_call, last_name
end

local function file_locals(lines)
	local top, inner = {}, {}
	for _, line in ipairs(lines) do
		local indent, names = line:match("^(%s*)local%s+([%w_,%s]+)")
		if names and not line:match("^%s*local%s+function") then
			for nm in names:gmatch("[%w_]+") do
				if indent == "" then top[nm] = true else inner[nm] = true end
			end
		end
	end
	return top, inner
end

-- Does a left side keep the value past the call? (a field, an index, a file local or a global)
local function keeps(lhs, top, inner, at_top)
	lhs = lhs:gsub("^%s+", ""):gsub("%s+$", "")
	local is_local = lhs:match("^local%s+") ~= nil
	if is_local then return at_top end
	for target in lhs:gmatch("[^,]+") do
		target = target:gsub("^%s+", ""):gsub("%s+$", "")
		if target:find("[%.%[:]") then return true end
		if target:match("^[%w_]+$") and (top[target] or not inner[target]) then return true end
	end
	return false
end

local function local_name(lhs)
	return lhs and lhs:match("^%s*local%s+([%w_]+)")
end

-- The rest of the function a line is in: the lines after it up to one that ends a top-level function.
local function rest_of_function(lines, i)
	local j = i + 1
	return function()
		if j > #lines then return nil end
		local line = lines[j]
		if line:match("^end") or line:match("^function") or line:match("^local%s+function") then return nil end
		j = j + 1
		return j - 1, line
	end
end

local function scan(src)
	local lines = {}
	for line in (strip(src) .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = (line:gsub("\r$", "")) end
	local top, inner = file_locals(lines)
	local found = {} -- kind -> { line, code }
	local function add(kind, i)
		if not found[kind] then found[kind] = { line = i, code = lines[i]:gsub("^%s+", "") } end
	end
	local function judge(kind, i, s, e)
		local line = lines[i]
		-- a file-level statement: no indentation and no function opened before it on the line
		local at_top = not line:match("^%s") and not line:sub(1, s - 1):find("%f[%w_]function%f[^%w_]")
		local steps, last_call, last_name = chain_after(line, e)
		if steps > 0 and last_call and not WINDOW_RESULT[last_name] then return end -- a value it gave, not a window
		local lhs = lhs_before(line, s)
		local callee = in_call_args(line, s)
		if callee and makes_windows(callee) and kind == "main" then
			add("anchor", i)
			return
		end
		if lhs and not callee then
			if keeps(lhs, top, inner, at_top) then
				add(kind, i)
				return
			end
			local name = local_name(lhs)
			if name then
				for j, later in rest_of_function(lines, i) do
					local p = later:find("%f[%w_]" .. name .. "%f[^%w_]")
					while p do
						local l2 = lhs_before(later, p)
						local c2 = in_call_args(later, p)
						local after = later:sub(p + #name):match("^%s*(.)")
						local whole = after ~= "." and after ~= ":" and after ~= "[" -- the window itself, not a part of it
						if whole and c2 and makes_windows(c2) and kind == "main" then add("anchor", j) return end
						if whole and l2 and not c2 and keeps(l2, top, inner, false) then
							add(kind, j)
							return
						end
						p = later:find("%f[%w_]" .. name .. "%f[^%w_]", p + #name)
					end
				end
			end
		end
	end
	for i, line in ipairs(lines) do
		for _, pat in ipairs(MAIN) do
			local s, e = line:find(pat)
			while s do
				judge("main", i, s, e)
				s, e = line:find(pat, e + 1)
			end
		end
		for _, pat in ipairs(STATIC) do
			local s, e = line:find(pat)
			while s do
				judge("static", i, s, e)
				s, e = line:find(pat, e + 1)
			end
		end
		if line:find(DIALOG) then add("dialog", i) end
	end
	return found
end

-------------------------------------------------------------------------------
-- the check
-------------------------------------------------------------------------------
reset_world()
local M = machine("single", 0, {})
HUD.install(M.env)
M.env.coop_mode = load_script(M, "coop_mode")
M.env.coop_mods_core = load_script(M, "coop_mods_core")
local life = load_script(M, "coop_hud_lifecycle")
local covered = life and type(life.covered) == "function" and life.covered() or {}
check(life ~= nil and type(life.covered) == "function", "coop_hud_lifecycle lists the scripts its adapters cover")

local holders, kinds_seen = 0, 0
local flagged = {}
local not_lua = {}
for _, name in ipairs(NAMES) do
	local src = HUD.read(FILES[name])
	-- a file that is not Lua is never run (lua_help.script lists the engine's classes); it is scanned all the same
	if src and not loadstring(src, "=" .. name) then not_lua[#not_lua + 1] = name end
	if src then
		local found = scan(src)
		for kind, at in pairs(found) do
			kinds_seen = kinds_seen + 1
			flagged[name] = flagged[name] or {}
			flagged[name][kind] = at
		end
	end
end

local sorted = {}
for name in pairs(flagged) do sorted[#sorted + 1] = name end
table.sort(sorted)
local unknown = 0
for _, name in ipairs(sorted) do
	holders = holders + 1
	local kinds = {}
	for kind in pairs(flagged[name]) do kinds[#kinds + 1] = kind end
	table.sort(kinds)
	for _, kind in ipairs(kinds) do
		local at = flagged[name][kind]
		local by = covered[name] and covered[name][kind]
		local why = SAFE[name] and SAFE[name][kind]
		local where = FILES[name] .. ":" .. at.line .. ": " .. at.code
		if by then
			print(string.format("  adapted  %-34s %-7s by %s  (%s)", name, kind, by, where))
		elseif why then
			print(string.format("  safe     %-34s %-7s %s", name, kind, why))
		else
			unknown = unknown + 1
			check(false, string.format("%s keeps a HUD window (%s, %s): adapt it in coop_hud_lifecycle or mark it safe in %s",
				name, kind, where, "tests/lua/test_hud_holders_scan.lua"))
		end
	end
end
check(unknown == 0, string.format("every HUD holder is adapted or marked safe (%d scripts, %d kinds, %d files read)",
	holders, kinds_seen, #NAMES))
print("  not Lua (the game cannot run them; scanned as text): " .. (#not_lua > 0 and table.concat(not_lua, ", ") or "none"))

-- every adapted script is still one the scan finds (an adapter for a script that no longer keeps a window is a note)
for name, kinds in pairs(covered) do
	for kind in pairs(kinds) do
		if not (flagged[name] and flagged[name][kind]) then
			print(string.format("  note: %s (%s) is adapted but the scan does not find it on this stand", name, kind))
		end
	end
end
for name, kinds in pairs(SAFE) do
	for kind in pairs(kinds) do
		if not (flagged[name] and flagged[name][kind]) then
			print(string.format("  note: %s (%s) is marked safe but the scan does not find it on this stand", name, kind))
		end
	end
end

-- the scanner itself: what it must see and what it must leave
local probe = scan([[
local cached = nil
local kept_static
function a()
	cached = ActorMenu.get_maingame()
end
function c(self, xml)
	self.wnd = xml:InitStatic("x", ActorMenu.get_maingame())
end
function d()
	local h = get_hud()
	h:AddCustomStatic("x", true)
	kept_static = h:GetCustomStatic("x"):wnd()
end
-- cached = ActorMenu.get_maingame() in a comment
]])
check(probe.main and probe.main.line == 4, "scanner: a main window kept in a file local (a) is found")
check(probe.anchor and probe.anchor.line == 7, "scanner: a window made under the main HUD (c) is found")
check(probe.static and probe.static.line == 12, "scanner: a CustomStatic window kept in a file local (d) is found")
local quiet = scan([[
function b()
	local m = ActorMenu.get_maingame()
	if m then m.UIZoneMap.disabled = true end
end
function e()
	local s = get_hud():GetCustomStatic("y")
	if s then s:wnd():TextControl():SetText("t") end
end
local function g() return ActorMenu.get_pda_menu():IsShown() end
function h(info)
	info.saved = ActorMenu.get_maingame().m_ui_hud_states.m_fire_mode:GetText()
	local maingameui = ActorMenu.get_maingame()
	maingameui.UIMotionIcon:Show(maingameui.UIZoneMap.disabled == false)
end
-- x = ActorMenu.get_maingame()
local t = "ActorMenu.get_maingame()"
]])
check(next(quiet) == nil, "scanner: uses inside a function, comments and strings are not holders")
local through_local = scan([[
function f()
	local m = ActorMenu.get_maingame()
	self.anchor = m
end
]])
check(through_local.main and through_local.main.line == 3, "scanner: a main window kept through a local of the function is found")
local more = scan([[
function show(args)
	return UITimedPrompt(ActorMenu.get_maingame(), args)
end
function keep(self)
	self.help = ActorMenu.get_maingame().UIStaticQuickHelp
end
]])
check(more.anchor and more.anchor.line == 2, "scanner: a class made under the main HUD is found")
check(more.main and more.main.line == 5, "scanner: a child window of the main HUD kept in a field is found")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS > 0 and 1 or 0)
