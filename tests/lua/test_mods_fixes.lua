-- Anomaly Coop test (coop_mods_fixes.script): four FATAL Lua errors of G.A.M.M.A. scripts in a co-op build, each first
-- reproduced on the real GAMMA file (GAMMA_SCRIPTS, e.g. E:\RayLinkGames\GAMMA\game-dev\gamedata\scripts), then guarded.
--   V1 ui_options.cont_vid_mode   RL-MSYY-7HAC ...   V2 ssfx_weapons_dof:269   RL-8ARK-RYS6
--   V3 _g_patches:817 spairs      RL-K5WA-XMZZ       V4 tasks_guide:447        RL-WZND-SWZJ
-- Not shipped. Run: tools\test_lua.cmd mods_fixes
dofile("tests/lua/support/mod_source.lua")

PASSES, FAILS = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local BS = string.char(92)
local function gamma(name) return GAMMA_DIR .. BS .. name .. ".script" end
local STOCK_G = "D:" .. BS .. "Projects" .. BS .. "ForEverything" .. BS .. "anomaly-ref" .. BS .. "unpacked" .. BS .. "scripts" .. BS .. "_g.script"

local function read_all(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

for _, n in ipairs({ "ui_options", "ssfx_weapons_dof", "_g_patches", "tasks_guide" }) do
	assert(have_file(gamma(n)), "real GAMMA script required: " .. gamma(n) .. " (set GAMMA_SCRIPTS)")
end

-- stand-ins
LOG = {}
function printf(fmt, ...)
	local ok, s = pcall(string.format, fmt, ...)
	LOG[#LOG + 1] = ok and s or fmt
end
local function logged(pat)
	for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return l end end
	return nil
end
coop = {}
CLIENT = false
coop_mods_core = { is_client = function() return CLIENT end }
CALLBACKS = {}
local intercepts = { actor_on_update = {}, actor_on_first_update = {} }
local prio = 0
function RegisterScriptCallback(name, f)
	intercepts[name] = intercepts[name] or {}
	prio = prio + 1
	intercepts[name][f] = prio
end
function UnregisterScriptCallback(name, f) if intercepts[name] then intercepts[name][f] = nil end end
coop_route = { intercepts = function() return intercepts end }
function getFS()
	return { update_path = function(_, _, file) return GAMMA_DIR .. BS .. file end }
end

-- a module the way the engine loads it: its file run in a module table (line numbers kept)
local function load_real(name)
	local src = assert(read_all(gamma(name)))
	local f = assert(loadstring(src, "@" .. gamma(name)))
	local m = setmetatable({}, { __index = _G })
	_G[name] = m
	setfenv(f, m)
	f()
	return m
end

local function load_fixes()
	local f = loadfile("gamedata/scripts/coop_mods_fixes.script")
	if not f then -- without the fix (the RED run): every guard is missing
		local none = function() return false end
		coop_mods_fixes = { guard_options = none, guard_ssfx = none, guard_spairs = none, guard_guide = none, on_game_start = none }
		return coop_mods_fixes
	end
	local m = setmetatable({}, { __index = _G })
	setfenv(f, m)
	f()
	coop_mods_fixes = m
	return m
end

-------------------------------------------------------------------------------
print("== V1 ui_options.cont_vid_mode: an entry of game.get_resolutions() that is no '<w>x<h>'")
-------------------------------------------------------------------------------
function round_idp(num, idp)
	local mult = 10 ^ (idp or 0)
	return math.floor(num * mult + 0.5) / mult
end
string_find = string.find
function trim(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end
function string.gsplit(s, sep, plain)
	local start, done = 1, false
	return function()
		if done then return nil end
		local i, j = s:find(sep, start, plain)
		if not i then done = true return s:sub(start) end
		local piece = s:sub(start, i - 1)
		start = j + 1
		return piece
	end
end
assert(mod_chunk(STOCK_G, { "function str_explode(str, sep, plain)" }, "_G_stock", "return true"))
str_explode = _G_stock.str_explode
function exec(f, ...) return f(...) end
CONSOLE = { vid_mode = "1920x1080" }
function get_console_cmd(_, cmd) return CONSOLE[cmd] end
RES = "1280x720,1920x1080"
game = { get_resolutions = function() return RES end }
local UO = "ui_options"
ui_options = { UIOptions = {} }
assert(mod_chunk(gamma(UO), { "function cont_vid_mode()", "function UIOptions:GetContent(path, opt, v)" }, UO, "return true"))
local uo = ui_options
local stock_cont = uo.cont_vid_mode
local entry = { id = "resolution", type = "list", content = { stock_cont } }
uo.options = { { id = "video", sh = true, gr = { { id = "general", gr = { entry } } } } }
local function content() return uo.UIOptions.GetContent(uo.UIOptions, "video/general", "resolution", entry) end

local good = content()
check(#good == 2 and good[2][1] == "1920x1080" and good[2][2] == "1920 x 1080 (16:9)", "stock: a valid list")
for _, raw in ipairs({ "", "\1\2garbage,1920x1080" }) do
	RES = raw
	local ok, err = pcall(content)
	check(not ok and tostring(err):find("attempt to perform arithmetic on local 'w'", 1, true) ~= nil,
		"RED (stock): " .. string.format("%q", raw) .. " -> " .. tostring(err))
end

local F = load_fixes()
check(F.guard_options() == true and F.guard_options() == false, "the guard installs once")
check(uo.cont_vid_mode ~= stock_cont and entry.content[1] == uo.cont_vid_mode, "the global and the table built already use it")
RES = "1280x720,1920x1080"
local same = content()
check(#same == 2 and same[1][1] == good[1][1] and same[2][2] == good[2][2], "a valid list is the stock's")
RES = "\1\2garbage,1920x1080"
local ok, rows = pcall(content)
check(ok and #rows == 1 and rows[1][1] == "1920x1080" and rows[1][2] == "1920 x 1080 (16:9)", "GREEN: the valid entries")
RES = ""
ok, rows = pcall(content)
check(ok and #rows == 1 and rows[1][1] == "1920x1080", "GREEN: an empty list falls back to the current vid_mode")
check(logged("game.get_resolutions() =") ~= nil, "the log names the raw string: " .. tostring(logged("resolution list")))

-------------------------------------------------------------------------------
print("== V2 ssfx_weapons_dof: active slot 14 with no item")
-------------------------------------------------------------------------------
itms_manager = { actor_on_item_before_use = function() end }
function ini_file() return { r_float_ex = function() end } end
ssfx_weapons_dof_settings = { items_time = {}, wpn_reloadtime = {} }
ssfx_001_mcm = { ssfx_get_setting = function() return 0 end }
function time_global() return NOW end
NOW = 1000
actor_menu = { last_mode = 0 }
function IsWeapon() return false end
function IsMoveState() return false end
function get_console() return { execute = function() end } end
function exec_console_cmd() end
SLOT, ITEM = 14, nil
GET_STATE = 0
local item = { get_state = function() GET_STATE = GET_STATE + 1 return 0 end, section = function() return "device_pda_1" end }
db = { actor = {
	active_item = function() return ITEM end,
	active_slot = function() return SLOT end,
	active_detector = function() return nil end,
} }
local ssfx = load_real("ssfx_weapons_dof")
ssfx.on_game_start()
local function ssfx_update()
	NOW = NOW + 200
	for f in pairs(intercepts.actor_on_update) do f() end
end
local ok2, err2 = pcall(ssfx_update)
check(not ok2 and tostring(err2):find("ssfx_weapons_dof.script:269: attempt to index local 'itm'", 1, true) ~= nil,
	"RED (stock): " .. tostring(err2))
local before = 0
for _, v in pairs(intercepts.actor_on_update) do before = before + 1 end
check(F.guard_ssfx() == true and F.guard_ssfx() == false, "the guard installs once")
local after = 0
for _, v in pairs(intercepts.actor_on_update) do after = after + 1 end
check(before == after, "in place: no handler added or lost")
ok2, err2 = pcall(ssfx_update)
check(ok2, "GREEN: no error with slot 14 and no item: " .. tostring(err2))
check(logged("active slot 14 with no item") ~= nil, "said in the log")
SLOT, ITEM = 8, item
GET_STATE = 0
ok2, err2 = pcall(ssfx_update)
check(ok2 and GET_STATE == 1, "with the PDA in hand the original runs: " .. tostring(err2))

-------------------------------------------------------------------------------
print("== V3 _g_patches spairs of nil")
-------------------------------------------------------------------------------
do
	local src = assert(read_all(gamma("_g_patches"))):gsub("\r\n", "\n")
	local from = assert(src:find("_G.nil_func = function() return nil end", 1, true))
	local spairs_at = assert(src:find("_G.spairs = function(t, order)", from, true))
	local _, to = assert(src:find("\nend\n", spairs_at, true))
	local first = 1
	for _ in src:sub(1, from - 1):gmatch("\n") do first = first + 1 end
	local chunk = "local math_floor, table_insert, table_remove, table_concat = math.floor, table.insert, table.remove, table.concat" ..
		string.rep("\n", first - 1) .. src:sub(from, to)
	assert(loadstring(chunk, "@" .. gamma("_g_patches")))()
end
local order = function(t, a, b) return a < b end
local function loop(t)
	local n = 0
	for _ in spairs(t, order) do n = n + 1 end
	return n
end
check(loop({ b = 1, a = 2 }) == 2, "stock spairs iterates")
local ok3, err3 = pcall(loop, nil)
check(not ok3 and tostring(err3):find("_g_patches.script:817: bad argument #1 to 'pairs' (table expected, got nil)", 1, true) ~= nil,
	"RED (stock): " .. tostring(err3))
check(F.guard_spairs() == true and F.guard_spairs() == false, "the guard installs once")
check(loop({ b = 1, a = 2 }) == 2, "a table iterates as before")
CLIENT = false
ok3, err3 = pcall(loop, nil)
check(not ok3 and tostring(err3):find("_g_patches.script:817", 1, true) ~= nil, "host / single player: the stock error stays")
CLIENT = true
ok3, err3 = pcall(loop, nil)
check(ok3 and err3 == 0, "GREEN on a client: an empty loop: " .. tostring(err3))
check((logged("spairs(nil) from") or ""):find("test_mods_fixes.lua", 1, true) ~= nil, "the log names the caller: " .. tostring(logged("spairs(nil)")))
CLIENT = false

-------------------------------------------------------------------------------
print("== V4 tasks_guide companion preconditions with no squad")
-------------------------------------------------------------------------------
assert(mod_chunk(STOCK_G, { "function get_object_squad(object,caller)" }, "_G_stock", "return true"))
get_object_squad = _G_stock.get_object_squad
SE = {}
function alife() return { object = function(_, id) return SE[id] end } end
function alife_object(id) return SE[id] end
dialogs = { who_is_npc = function(a, b) return b end }
local function npc(id) return { id = function() return id end } end
local function squad(id, members)
	return { id = id, group_id = 65535, commander_id = function() return members[1] end,
		squad_members = function()
			local i = 0
			return function() i = i + 1 return members[i] and { id = members[i] } or nil end
		end }
end
local tg = load_real("tasks_guide")
-- the guide job: squad 300 with members 301, 302 (curr_guid is a local of the module: activate fills it the stock way)
SE[300] = squad(300, { 301, 302 })
SE[301] = { id = 301, group_id = 300 }
SE[302] = { id = 302, group_id = 65535 } -- a member of a squad from the wire, here
SE[401] = { id = 401, group_id = 400 }
SE[400] = squad(400, { 401 })
SE[501] = { id = 501, group_id = 65535 }
local curr = nil
for i = 1, 255 do
	local n, v = debug.getupvalue(tg.is_not_guider_companion, i)
	if n == nil then break end
	if n == "curr_guid" then curr = v end
end
assert(type(curr) == "table", "curr_guid upvalue")
curr.squad_id = 300
local stock_not, stock_is = tg.is_not_guider_companion, tg.is_guider_companion
check(stock_not(db.actor, npc(301)) == false and stock_is(db.actor, npc(301)) == true, "stock: the guide")
check(stock_not(db.actor, npc(401)) == true, "stock: another companion")
local ok4, err4 = pcall(stock_not, db.actor, npc(302))
check(not ok4 and tostring(err4):find("tasks_guide.script:447: attempt to index a nil value", 1, true) ~= nil,
	"RED (stock): " .. tostring(err4))
check(F.guard_guide() == true and F.guard_guide() == false, "the guard installs once")
check(tg.is_not_guider_companion(db.actor, npc(301)) == false and tg.is_guider_companion(db.actor, npc(301)) == true, "with a squad: the original")
check(tg.is_not_guider_companion(db.actor, npc(401)) == true and tg.is_guider_companion(db.actor, npc(401)) == false, "another squad: the original")
ok4, err4 = pcall(tg.is_not_guider_companion, db.actor, npc(302))
check(ok4 and err4 == false, "GREEN: an unbound member of the guide's squad is the guide: " .. tostring(err4))
check(tg.is_guider_companion(db.actor, npc(302)) == true, "is_guider_companion agrees")
check(tg.is_not_guider_companion(db.actor, npc(501)) == true and tg.is_guider_companion(db.actor, npc(501)) == false, "no squad, not the guide's")
curr.squad_id = nil
check(tg.is_not_guider_companion(db.actor, npc(501)) == true, "no guide job: not the guide")
check(logged("has no squad here") ~= nil, "said in the log")

-------------------------------------------------------------------------------
print("== V5 game_relations.reset_all_relations: the table is written by position in a list of another order")
-------------------------------------------------------------------------------
-- Live 2026-11-12: on a new world of the dedicated host the Clear Sky base killed itself. The stock reset reads a row of
-- [communities_relations] and gives its j-th value to the j-th name of factions_table_all, whose order is not the order
-- of the columns ("actor, bandit, dolg, ..." against "actor, monster, trader, army_npc, greh_npc, bandit, ..."): csky gets
-- monolith's value for itself, -2000. A single player's new game leaves fake_start at once and the table is read from
-- the config again; a world server stays there and hands the table to every map server and client.
local REF = "D:" .. BS .. "Projects" .. BS .. "ForEverything" .. BS .. "anomaly-ref" .. BS .. "unpacked" .. BS
local function read_ltx(path)
	local src = assert(read_all(path), "no " .. path)
	local sections, cur = {}, nil
	for line in (src .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		line = line:gsub(";.*$", "")
		local name = line:match("^%s*%[([^%]]+)%]")
		if name then
			cur = { keys = {}, list = {} }
			sections[name] = cur
		elseif cur then
			local k, v = line:match("^%s*([^=%s][^=]-)%s*=%s*(.-)%s*$")
			if k then
				cur.keys[k] = v
				cur.list[#cur.list + 1] = { k, v }
			else
				local only = line:match("^%s*(%S.-)%s*$")
				if only then
					cur.keys[only] = ""
					cur.list[#cur.list + 1] = { only, "" }
				end
			end
		end
	end
	local ini = {}
	function ini:r_string_ex(sec, k) return sections[sec] and sections[sec].keys[k] or nil end
	function ini:r_float_ex(sec, k) return tonumber(self:r_string_ex(sec, k) or "") end
	function ini:line_count(sec) return sections[sec] and #sections[sec].list or 0 end
	function ini:r_line(sec, i) local e = sections[sec].list[i + 1]; return true, e[1], e[2] end
	function ini:section_exist(sec) return sections[sec] ~= nil end
	return ini
end
local ltx_calls = 0
ini_file = function(name)
	ltx_calls = ltx_calls + 1
	return read_ltx(REF .. "configs" .. BS .. name)
end
str_explode = function(str, sep)
	local out = {}
	for part in (tostring(str) .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = (part:gsub("^%s+", ""):gsub("%s+$", "")) end
	return out
end
local REL = {}
relation_registry = { set_community_relation = function(a, b, v)
	REL[a] = REL[a] or {}
	REL[a][b] = v
end }
local gr_src = assert(read_all(REF .. "scripts" .. BS .. "game_relations.script"), "the stock game_relations.script is required")
local gr = setmetatable({}, { __index = _G })
game_relations = gr
setfenv(assert(loadstring(gr_src, "@game_relations.script")), gr)()

-- what the config says, read here by the names of its columns
local cfg = read_ltx(REF .. "configs" .. BS .. "creatures" .. BS .. "game_relations.ltx")
local columns = {}
do
	local i = 0
	for token in cfg:r_string_ex("game_relations", "communities"):gmatch("[^,%s]+") do
		i = i + 1
		if i % 2 == 1 then columns[#columns + 1] = token end
	end
end
local function config_value(from, to)
	local j
	for i, name in ipairs(columns) do if name == to then j = i end end
	local n = 0
	for v in cfg:r_string_ex("communities_relations", from):gmatch("[^,%s]+") do
		n = n + 1
		if n == j then return tonumber(v) end
	end
end
check(config_value("csky", "csky") == 300 and config_value("stalker", "stalker") == 300 and config_value("csky", "monolith") == -2000,
	"the config: Clear Sky and the loners are friends of their own, Clear Sky and Monolith are enemies")

gr.reset_all_relations()
check(REL.csky ~= nil and REL.csky.csky == -2000,
	"RED (stock): the reset makes Clear Sky an enemy of itself: " .. tostring(REL.csky and REL.csky.csky))

REL = {}
check(type(F.guard_relations) == "function", "the guard exists")
if type(F.guard_relations) == "function" then
	check(F.guard_relations() == true and F.guard_relations() == false, "the guard installs once")
	gr.reset_all_relations()
	check(REL.csky ~= nil and REL.csky.csky == 300, "GREEN: Clear Sky is a friend of itself again: " .. tostring(REL.csky and REL.csky.csky))
	local wrong, pairs_n = 0, 0
	for from, row in pairs(REL) do
		for to, v in pairs(row) do
			pairs_n = pairs_n + 1
			if v ~= config_value(from, to) then wrong = wrong + 1 end
		end
	end
	check(pairs_n == #columns * #columns and wrong == 0,
		string.format("every pair is the config's by the name of its column: %d pairs, %d wrong", pairs_n, wrong))
	check(logged("written by the names of the columns") ~= nil, "said once in the log")

	-- a co-op client's table is the host's: nothing is written there (the stock reset would ask the host for every pair)
	REL = {}
	coop_mods_core = { is_client = function() return true end }
	gr.reset_all_relations()
	check(next(REL) == nil, "on a co-op client the reset writes nothing")
	coop_mods_core = nil

	-- a config that cannot be read: the stock reset, as before
	REL = {}
	local real_ini = ini_file
	ini_file = function(name)
		if name:find("game_relations", 1, true) then return { r_string_ex = function() return nil end } end
		return real_ini(name)
	end
	local ok5 = pcall(gr.reset_all_relations)
	ini_file = real_ini
	check(ok5 and logged("could not be reset by name") ~= nil, "an unreadable config falls back to the stock reset and says so")
end

-------------------------------------------------------------------------------
print("== on_game_start")
-------------------------------------------------------------------------------
local F2 = load_fixes()
F2.on_game_start()
local n = 0
for _ in pairs(intercepts.actor_on_first_update) do n = n + 1 end
check(n >= 1, "the ssfx guard waits for the first update")

print(string.format("%d passed, %d failed", PASSES, FAILS))
