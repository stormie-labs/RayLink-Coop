-- Anomaly Coop test (R87, Core): the choice of a new game that never started is dropped at the next load
-- (gamedata\scripts\coop_newgame_leftover.script, called first in coop_game_settings.before_world_start).
--
-- The stock new game screen (ui_mm_faction_select UINewGame:OnStartGame) writes the choice to axr_options.ltx
-- [character_creation] and saves the file before the world exists; only the stock on_game_load reads and clears it, and
-- it runs at every net_spawn of the actor, a load too. A tester's Freedom new game crashed before it; the next load of a
-- bandit autosave became Freedom: name, group, money, a second kit on top of the inventory, a move to l07_military.
-- The stock on_game_load here is the real G.A.M.M.A. file (GAMMA_SCRIPTS, read only), run on stand-ins as
-- temp\r87\inv\probe_stock_leftover.lua does. A Core file: every check runs under every answer set of coop_mode
-- (hostplay, srv_world, srv_map, none; docs\MODES.md rule 9) and must give the same result. Not shipped.
-- Run: tools\test_lua.cmd newgame_leftover
MODE = "host"
dofile("tests/lua/support/stubs.lua")
dofile("tests/lua/support/mod_source.lua") -- GAMMA_DIR
local modes = dofile("tests/lua/support/modes.lua")
local BS = string.char(92)
local SEC = "character_creation"
local DROPPED = "[coop] new game: the choice of a new game that never started is dropped at this load"

-------------------------------------------------------------------------------
-- axr_options.ltx: ini_file_ex of _g.script (r_value typed and cached, w_value(nil) writes "" and caches nil). Methods are
-- looked up on the class at call time, as luabind does.
-------------------------------------------------------------------------------
local Ini = {}
local function make_class(without)
	local cls = {}
	for k, v in pairs(Ini) do if k ~= without then cls[k] = v end end
	return { __index = function(_, k) return cls[k] end }
end
function Ini.save(self) self.saves = self.saves + 1 end
function Ini.r_value(self, s, k, typ, def)
	local cache_result = self.cache[s .. "&" .. k]
	if cache_result then return cache_result end
	local sec = self.data[s]
	if not (sec and sec[k] ~= nil) then return def end
	local v = sec[k]
	if typ == 1 then
		v = v == nil and def or v == "true" or false
	elseif typ == 2 then
		v = tonumber(v) or def
	end
	self.cache[s .. "&" .. k] = v
	return v == nil and def or v
end
function Ini.w_value(self, s, k, val)
	self.cache[s .. "&" .. k] = val
	self.data[s] = self.data[s] or {}
	self.data[s][k] = val ~= nil and tostring(val) or ""
end
function Ini.collect_section(self, s)
	local t = {}
	for k, v in pairs(self.data[s] or {}) do t[k] = v end
	return t
end
function Ini.section_exist(self, s) return self.data[s] ~= nil end
function Ini.line_exist(self, s, k) return self.data[s] ~= nil and self.data[s][k] ~= nil end
function Ini.r_string_ex(self, s, k)
	local v = self.data[s] and self.data[s][k]
	if v == "" then return nil end -- CInifile::r_string of an empty value is nil
	return v
end
local FULL, NO_COLLECT = make_class(nil), make_class("collect_section")

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

-- a fresh axr_options.ltx in axr_main.config; cc = the [character_creation] lines (nil: no such section)
local function use_config(cc, mt)
	local data = { options = { ["video/basic/fov"] = "65" }, temp = { rspec_default = "true" } }
	if cc then data[SEC] = copy(cc) end
	local cfg = setmetatable({ data = data, cache = {}, saves = 0 }, mt or FULL)
	axr_main.config = cfg
	return cfg
end

-- What UINewGame:OnStartGame (GAMMA ui_mm_faction_select.script:1712-1733) writes for a Freedom start with nothing else
-- changed: every key, the empty ones as "" (w_value(nil)); lives "1" also without hardcore (:1717).
local FREEDOM = {
	new_game_difficulty = "1", new_game_economy = "1", new_game_economy_treasure = "1",
	new_game_hardcore_mode = "", new_game_hardcore_mode_lives = "1", new_game_hardcore_mode_regenerate = "",
	new_game_story_mode = "true", new_game_azazel_mode = "", new_game_survival_mode = "", new_game_campfire_mode = "",
	new_game_conditions_mode = "", new_game_opened_routes = "true", new_game_warfare = "", new_game_timer_mode = "",
	new_game_character_name = "Svobodovets_Fedya", new_game_faction = "freedom", new_game_icon = "ui_inGame2_freedom_1",
	new_game_loadout = "device_pda_1,bandage,svoboda_novice_outfit,helm_respirator_old,wpn_mp5,ammo_9x19_ap",
	new_game_map = "military_base", new_game_money = "5000",
}
local FREEDOM_SET = 12 -- the lines above that are not empty

-- the file after an ordinary new game: the stock cleared every key it applied, "lives 1" stays (snapshot 40b235c9)
local AFTER_NEW_GAME = copy(FREEDOM)
for k in pairs(AFTER_NEW_GAME) do AFTER_NEW_GAME[k] = "" end
AFTER_NEW_GAME.new_game_hardcore_mode_lives = "1"

local function all_empty(cfg)
	for k, v in pairs(cfg.data[SEC] or {}) do
		if k:sub(1, 9) == "new_game_" and v ~= "" then return false, k .. "=" .. v end
	end
	return true
end

local function clear_log() for i = #LOG, 1, -1 do LOG[i] = nil end end
local function log_count(text)
	local n = 0
	for _, line in ipairs(LOG) do if line:find(text, 1, true) then n = n + 1 end end
	return n
end
local function log_index(text)
	for i, line in ipairs(LOG) do if line:find(text, 1, true) then return i end end
	return nil
end

-------------------------------------------------------------------------------
-- The engine's coop.* for these checks
-------------------------------------------------------------------------------
SESSION = {}
coop.session_info = function() return SESSION end
DEDICATED, DEDICATED_NEW = false, false
coop.is_dedicated = function() return DEDICATED end
coop.dedicated_new_world = function() return DEDICATED_NEW end

-------------------------------------------------------------------------------
-- The real stock on_game_load and actor_on_first_update of G.A.M.M.A. (ui_mm_faction_select.script, the file up to the
-- end of its on_game_start), on stand-ins of the engine, as temp\r87\inv\probe_stock_leftover.lua runs it
-------------------------------------------------------------------------------
local STOCK_PATH = GAMMA_DIR .. BS .. "ui_mm_faction_select.script"
local fh = assert(io.open(STOCK_PATH, "rb"), "real GAMMA ui_mm_faction_select.script required (GAMMA_SCRIPTS)")
local STOCK_TEXT = fh:read("*a")
fh:close()
local cut = assert(STOCK_TEXT:find("function on_game_start%(%)"), "stock on_game_start not found")
local STOCK_CHUNK = STOCK_TEXT:sub(1, STOCK_TEXT:find("\nend", cut, true) + 4)
-- new_game_start_locations.ltx: military_base (Freedom's start, l07_military)
local STARTS = { military_base = { lvid = 274912, gvid = 2092, x = -18.02, y = -2.46, z = -31.74 } }
local BANDIT_KIT = { "bandit_novice_outfit", "helm_respirator", "wpn_bm16", "wpn_pm", "bandage", "device_pda_1" }

-- who: "bandit" (the loaded autosave of a bandit) or "fresh" (the actor of a new world on fake_start)
local function run_stock(cfg, who)
	local w = {
		name = who == "bandit" and "Bandit_Vasya" or "",
		profile = who == "bandit" and "actor_bandit" or "",
		community = who == "bandit" and "actor_bandit" or "actor_stalker",
		money = who == "bandit" and 1234 or 0,
		inventory = who == "bandit" and copy(BANDIT_KIT) or {},
		m_data = who == "bandit" and { default_faction = "bandit", diff_game = { type = 3 }, diff_eco = { type = 3 } } or {},
	}
	local se_actor = {}
	function se_actor:set_character_name(n) w.name = n end
	function se_actor:set_profile_name(n) w.profile = n end
	local actor = {}
	function actor:set_character_community(c) w.community = c end
	function actor:money() return w.money end
	function actor:give_money(d) w.money = w.money + d end
	local callbacks = {}
	local sys = { wpn_mp5 = { ammo_class = "ammo_9x19_fmj,ammo_9x19_ap", slot = 2, box_size = 30 } }
	local env = setmetatable({
		ini_file = function() return { r_float_ex = function() return 1 end, r_bool_ex = function() return false end,
			r_string_ex = function() return nil end } end,
		axr_main = { config = cfg }, USE_MARSHAL = true, GAME_VERSION = "1.5.3",
		alife = function() return { actor = function() return se_actor end } end,
		alife_storage_manager = { get_state = function() return w.m_data end },
		db = { actor = actor, actor_binder = {} },
		has_alife_info = function() return false end, give_info = function() end,
		game_relations = { set_factions_community = function() end }, save_var = function() end,
		xr_effects = { drx_sl_setup_questlines = function(_, _, p) w.m_data.questlines_for = p[1] end },
		utils_obj = { get_communities_list = function() return { "bandit", "freedom" } end },
		relation_registry = { set_community_goodwill = function() w.m_data.goodwill_reset = true end },
		mlr_utils = { load_var = function() return "bandit" end, save_var = function() end },
		ini_sys = { section_exist = function() return true end,
			r_string_ex = function(_, s, k) local t = sys[s]; return t and t[k] end,
			r_float_ex = function(_, s, k) local t = sys[s]; return t and t[k] end },
		alife_create_item = function(sec) w.inventory[#w.inventory + 1] = sec; return { id = #w.inventory } end,
		str_explode = function(s, sep) local out = {}; for p in s:gmatch("[^" .. sep .. "]+") do out[#out + 1] = p end; return out end,
		printdbg = function() end, printf = function() end,
		vector = function() return { set = function(_, x, y, z) return { x = x, y = y, z = z } end } end,
		VEC_ZERO = {}, warfare_options = { options = {} },
		ChangeLevel = function(pos, lvid, gvid) w.changed = { lvid = lvid, gvid = gvid } end,
		RegisterScriptCallback = function(name, fn) callbacks[name] = fn end,
		patrol = function() return nil end,
	}, { __index = _G })
	local fn = assert(loadstring(STOCK_CHUNK, "=ui_mm_faction_select(stock)"))
	setfenv(fn, env)
	fn()
	env.on_game_start()
	for i = 1, 60 do
		local name = debug.getupvalue(callbacks.on_game_load, i)
		if not name then break end
		if name == "ini_map" then
			debug.setupvalue(callbacks.on_game_load, i, { r_float_ex = function(_, s, k) return STARTS[s] and STARTS[s][k] end })
		end
	end
	callbacks.on_game_load({}) -- bind_stalker_ext sends it at EVERY net_spawn of the actor, a load too
	callbacks.actor_on_first_update({}, 0)
	return w
end

local function count_like(list, pat)
	local n = 0
	for _, s in ipairs(list) do if s:find(pat) then n = n + 1 end end
	return n
end

-- the loaded bandit as the save has him: nothing of the Freedom choice landed on him
local function bandit_unchanged(w, tag)
	check(w.name == "Bandit_Vasya", tag .. ": the bandit keeps his name (" .. tostring(w.name) .. ")")
	check(w.community == "actor_bandit" and w.profile == "actor_bandit" and w.m_data.default_faction == "bandit",
		tag .. ": the bandit keeps his group (" .. tostring(w.community) .. ")")
	check(w.money == 1234, tag .. ": the bandit keeps his money (" .. tostring(w.money) .. ")")
	check(#w.inventory == #BANDIT_KIT and count_like(w.inventory, "outfit") == 1 and count_like(w.inventory, "^helm_") == 1,
		tag .. ": no second kit in the inventory (" .. table.concat(w.inventory, ",") .. ")")
	check(w.changed == nil, tag .. ": no move to another map at the first update")
	check(w.m_data.diff_game.type == 3 and w.m_data.diff_eco.type == 3 and w.m_data.opened_routes == nil,
		tag .. ": the save keeps its difficulty, economy and routes")
	check(w.m_data.questlines_for == nil and w.m_data.goodwill_reset == nil, tag .. ": no storyline set up again, no goodwill reset")
end

-------------------------------------------------------------------------------
-- The scripts under test
-------------------------------------------------------------------------------
load_script_file("coop_game_schema")
load_script_file("coop_game_record")
local cm = load_script_file("coop_mode")
-- the module under test: until it exists the hook has nothing to call (RED: the stock applies the leftover)
local have_lo, lo = pcall(load_script_file, "coop_newgame_leftover")
if not have_lo then
	print("  (coop_newgame_leftover.script is not there: " .. tostring(lo) .. ")")
	lo = nil
end
local gs = load_script_file("coop_game_settings")
local sd = load_script_file("coop_srv_dedicated")
check(gs ~= nil and sd ~= nil and cm ~= nil, "the scripts load")
check(lo ~= nil and type(lo.on_world_start) == "function", "coop_newgame_leftover.on_world_start is there")

local function scenarios(set)
	local function section(name) print("== [" .. set .. "] " .. name) end
	MODE, SESSION, DEDICATED, DEDICATED_NEW = "host", {}, false, false

	section("(a) load + a Freedom choice of a crashed new game: dropped before the stock on_game_load")
	local cfg = use_config(FREEDOM)
	clear_log()
	gs.before_world_start("load", "bandit_vasya - autosave")
	local ok, left = all_empty(cfg)
	check(ok, "a: every new_game_* line is empty (" .. tostring(left) .. ")")
	check(cfg.saves == 1, "a: axr_options.ltx saved once (" .. cfg.saves .. ")")
	check(log_count("[coop] new game:") == 1, "a: one journal line")
	check(log_count(DROPPED .. " (faction freedom, name Svobodovets_Fedya, " .. FREEDOM_SET .. " key(s))") == 1,
		"a: the line names the faction, the name and the number of keys")
	check(cfg.data.options["video/basic/fov"] == "65" and cfg.data.temp.rspec_default == "true", "a: other sections untouched")
	local w = run_stock(cfg, "bandit")
	bandit_unchanged(w, "a")
	check(cfg.saves == 1, "a: the stock has nothing left to save")
	check(log_count("! before_world_start") == 0, "a: the hook raised nothing")

	section("(a, co-op host) the Co-op window has a host pending: the modes go too")
	SESSION = { pending_host = 27960 }
	local host = copy(FREEDOM)
	host.new_game_survival_mode, host.new_game_hardcore_mode, host.new_game_hardcore_mode_lives = "true", "true", "3"
	cfg = use_config(host)
	clear_log()
	gs.before_world_start("load", "coop_auto_1")
	ok, left = all_empty(cfg)
	check(ok, "a-host: the name, the group and the modes are dropped (" .. tostring(left) .. ")")
	check(cfg.saves == 1 and log_count(DROPPED .. " (faction freedom, name Svobodovets_Fedya, 14 key(s))") == 1,
		"a-host: one save, one line with 14 keys")
	SESSION = {}

	section("(b) new: the choice is the new world's, the stock applies it")
	cfg = use_config(FREEDOM)
	clear_log()
	gs.before_world_start("new", "all")
	local same = true
	for k, v in pairs(FREEDOM) do if cfg.data[SEC][k] ~= v then same = false end end
	check(same, "b: no line of the choice touched")
	check(cfg.saves == 0 and log_count("[coop] new game:") == 0, "b: no save, no journal line")
	w = run_stock(cfg, "fresh")
	check(w.name == "Svobodovets Fedya" and w.community == "actor_freedom" and w.profile == "actor_freedom",
		"b: the new character gets the chosen name and group")
	check(w.money == 5000 and count_like(w.inventory, "outfit") == 1 and count_like(w.inventory, "^helm_") == 1,
		"b: the chosen money and kit")
	check(w.changed and w.changed.gvid == 2092 and w.changed.lvid == 274912, "b: the move to the chosen start (military_base)")
	check(w.m_data.questlines_for == "freedom", "b: the storyline of the chosen group")
	check(cfg.saves == 1, "b: the stock cleared the keys and saved")
	-- treasure_manager clears economy_treasure in memory without a save (treasure_manager.script:266-268), in an order
	-- against the stock's save nobody fixes: here it has not run, the file keeps it, as on the unlucky order
	section("(b) the level change after that new game is a load: nothing to drop")
	clear_log()
	gs.before_world_start("load", "svobodovets_fedya - autosave")
	check(cfg.saves == 1 and log_count("[coop] new game:") == 0, "b: no save, no journal line at the level change")
	check(cfg.data[SEC].new_game_hardcore_mode_lives == "1", "b: lives 1 (written without hardcore) stays as it is")
	check(cfg.data[SEC].new_game_economy_treasure == "1", "b: economy_treasure that treasure_manager did not save stays")

	section("(c) load without a choice")
	cfg = use_config(nil)
	clear_log()
	gs.before_world_start("load", "bandit_vasya - autosave")
	check(cfg.saves == 0 and log_count("[coop] new game:") == 0, "c: no section: no save, no line")
	check(cfg.data[SEC] == nil, "c: no section: none is made")
	local empty = copy(FREEDOM)
	for k in pairs(empty) do empty[k] = "" end
	cfg = use_config(empty)
	gs.before_world_start("load", "bandit_vasya - autosave")
	check(cfg.saves == 0 and log_count("[coop] new game:") == 0, "c: empty lines: no save, no line")

	section("(d) only lives (and regenerate) without hardcore: inert, left alone")
	cfg = use_config(AFTER_NEW_GAME)
	clear_log()
	gs.before_world_start("load", "bandit_vasya - autosave")
	check(cfg.saves == 0 and log_count("[coop] new game:") == 0, "d: lives 1: no save, no line")
	check(cfg.data[SEC].new_game_hardcore_mode_lives == "1", "d: lives 1 stays")
	cfg = use_config({ new_game_hardcore_mode_lives = "2", new_game_hardcore_mode_regenerate = "120", new_game_hardcore_mode = "" })
	gs.before_world_start("load", "bandit_vasya - autosave")
	check(cfg.saves == 0 and log_count("[coop] new game:") == 0, "d: lives 2 + regenerate 120: no save, no line")
	check(cfg.data[SEC].new_game_hardcore_mode_regenerate == "120", "d: regenerate stays")
	local unsaved = copy(AFTER_NEW_GAME)
	unsaved.new_game_economy_treasure = "1"
	cfg = use_config(unsaved)
	gs.before_world_start("load", "bandit_vasya - autosave")
	check(cfg.saves == 0 and log_count("[coop] new game:") == 0 and cfg.data[SEC].new_game_economy_treasure == "1",
		"d: lives 1 + economy_treasure 1 (treasure_manager's unsaved clear): no save, no line, left alone")

	section("(e) a leftover without a group: difficulty, economy, routes")
	cfg = use_config({ new_game_difficulty = "2", new_game_economy = "1", new_game_opened_routes = "true",
		new_game_hardcore_mode_lives = "1", new_game_faction = "", new_game_character_name = "" })
	clear_log()
	gs.before_world_start("load", "bandit_vasya - autosave")
	ok, left = all_empty(cfg)
	check(ok, "e: dropped (" .. tostring(left) .. ")")
	check(cfg.saves == 1 and log_count(DROPPED .. " (faction none, name none, 4 key(s))") == 1, "e: one save, one line")
	bandit_unchanged(run_stock(cfg, "bandit"), "e")
	for _, one in ipairs({
		{ new_game_survival_mode = "true" }, { new_game_timer_mode = "5" }, { new_game_economy = "2" },
		{ new_game_soulslike_mode = "true" }, { new_game_test = "true" }, { new_game_icon = "ui_inGame2_freedom_1" },
		{ new_game_money = "5000" }, { new_game_map = "military_base" }, { new_game_loadout = "wpn_mp5" },
	}) do
		local key = next(one)
		cfg = use_config(one)
		gs.before_world_start("load", "bandit_vasya - autosave")
		check(cfg.data[SEC][key] == "" and cfg.saves == 1, "e: " .. key .. " alone is a leftover")
	end
	-- G.A.M.M.A.'s r_value reads "1", "yes" and "on" as a flag that is on (_g_patches.script): the stock would apply them
	for _, v in ipairs({ "1", "yes", "on" }) do
		cfg = use_config({ new_game_survival_mode = v })
		gs.before_world_start("load", "bandit_vasya - autosave")
		check(cfg.data[SEC].new_game_survival_mode == "" and cfg.saves == 1, "e: survival_mode = " .. v .. " is a leftover")
	end
	for _, one in ipairs({ { new_game_opened_routes = "false" }, { new_game_difficulty = "x" }, { new_game_economy_treasure = "2" },
		{ new_game_story_mode = "TRUE" } }) do
		local key = next(one)
		cfg = use_config(one)
		gs.before_world_start("load", "bandit_vasya - autosave")
		check(cfg.data[SEC][key] == one[key] and cfg.saves == 0, "e: " .. key .. " = " .. one[key] .. " is no choice")
	end

	section("(f) the cache of ini_file_ex: a read after the drop gives the file's empty value")
	cfg = use_config(FREEDOM)
	check(cfg:r_value(SEC, "new_game_faction", 3) == "freedom" and cfg:r_value(SEC, "new_game_story_mode", 1) == true
		and cfg:r_value(SEC, "new_game_money", 2) == 5000, "f: the old values are in the cache")
	gs.before_world_start("load", "bandit_vasya - autosave")
	check(cfg:r_value(SEC, "new_game_faction", 3) == "", "f: faction reads \"\"")
	check(cfg:r_value(SEC, "new_game_character_name", 3) == "", "f: name reads \"\"")
	check(cfg:r_value(SEC, "new_game_story_mode", 1) == false, "f: story mode reads false")
	check(cfg:r_value(SEC, "new_game_money", 2) == nil, "f: money reads no number")
	cfg = use_config(FREEDOM, NO_COLLECT)
	gs.before_world_start("load", "bandit_vasya - autosave")
	ok, left = all_empty(cfg)
	check(ok and cfg.saves == 1, "f: a config without collect_section is read line by line (" .. tostring(left) .. ")")

	section("(g) a co-op client: its own leftover is dropped when the host's world loads")
	MODE = "client"
	cfg = use_config(FREEDOM)
	clear_log()
	gs.before_world_start("load", "coop_client")
	ok, left = all_empty(cfg)
	check(ok and cfg.saves == 1, "g: the client's leftover is dropped (" .. tostring(left) .. ")")
	local i_drop, i_client = log_index(DROPPED), log_index("a client: the game's settings come from the host")
	check(i_drop ~= nil and i_client ~= nil and i_drop < i_client, "g: dropped first, then the client's return as before")
	if lo then
		local real = lo.on_world_start
		lo.on_world_start = function() error("boom") end
		clear_log()
		gs.before_world_start("load", "coop_client")
		lo.on_world_start = real
		check(log_index("a client: the game's settings come from the host") ~= nil and log_count("! before_world_start") == 0,
			"g: a failure of the check does not stop the hook")
	end
	MODE = "host"

	section("(h) the world server: a new world from new_world_settings as before; a load drops the player's leftover")
	DEDICATED, DEDICATED_NEW = true, true
	cfg = use_config(AFTER_NEW_GAME)
	clear_log()
	gs.before_world_start("new", "all")
	check(cfg.saves == 0 and log_count("[coop] new game:") == 0, "h: new: no save, no line")
	check(sd.new_world_settings() == true, "h: new_world_settings runs")
	local d = cfg.data[SEC]
	check(d.new_game_faction == "stalker" and d.new_game_character_name == "server" and d.new_game_difficulty == "1"
		and d.new_game_economy == "1" and d.new_game_economy_treasure == "1" and d.new_game_story_mode == "true",
		"h: the new world's keys are written")
	check(d.new_game_map == "" and d.new_game_test == "" and d.new_game_money == "" and d.new_game_loadout == "",
		"h: map, test, money and kit stay out")
	w = run_stock(cfg, "fresh")
	check(w.name == "server" and w.community == "actor_stalker" and w.changed == nil and #w.inventory == 0,
		"h: the ghost is 'server', a stalker, stays on fake_start, no kit")
	DEDICATED_NEW = false
	cfg = use_config(FREEDOM)
	gs.before_world_start("load", "world_1")
	ok, left = all_empty(cfg)
	check(ok and cfg.saves == 1, "h: -coop_load: the player's leftover in the shared file is dropped (" .. tostring(left) .. ")")
	DEDICATED = false

	section("(i) axr_main reached the ordinary way: loaded by _G.__index at the hook")
	if lo then
		local real = rawget(_G, "axr_main")
		local cfg2 = use_config(FREEDOM)
		rawset(_G, "axr_main", nil)
		local loads = 0
		local old_mt = getmetatable(_G)
		setmetatable(_G, { __index = function(t, k)
			if k == "axr_main" then
				loads = loads + 1
				rawset(t, k, real)
				return real
			end
			return nil
		end })
		local n = lo.on_world_start("load")
		setmetatable(_G, old_mt)
		rawset(_G, "axr_main", real)
		check(loads == 1 and n == FREEDOM_SET and cfg2.saves == 1, "i: axr_main loaded on demand, " .. tostring(n) .. " key(s) dropped")
		axr_main.config = nil
		check(lo.on_world_start("load") == 0, "i: no config: nothing to do")
		check(lo.on_world_start("new") == 0 and lo.on_world_start(nil) == 0, "i: anything but a load: nothing to do")
	end
end

modes.each(cm, function(name) scenarios(name) end)

print(string.format("%d passed, %d failed", PASSES, FAILS))
