-- Anomaly Coop test (settings of a game, T4): the host's side of docs\GAME_SETTINGS.md (3.2-3.5, 4.3, 5) - the active record
-- of gamedata\scripts\coop_game_settings.script, its values over the machine's (the ini_file_ex overlay of coop_settings),
-- the read-only lock of the host in the game (Ruling GS-1: only the explicit host lists), the record in the save and in the
-- card, the migration of an old save. The real scripts run over stand-ins for the engine: coop.game.*, marshal, io (a
-- virtual saves folder), getFS, alife_storage_manager, game_difficulties, level.present, axr_main.config. Not shipped.
-- Run: tools\test_lua.cmd game_settings
MODE = "host"
dofile("tests/lua/support/stubs.lua")
load_coop_main() -- the real encode / decode and event router

local function section(name) print("== " .. name) end

-------------------------------------------------------------------------------
-- Stand-ins
-------------------------------------------------------------------------------
-- the saves folder: a virtual disk behind io.open / os.remove / os.rename (the other paths are the real ones)
local SAVES = "SAVES/"
VFS, MTIME, READS = {}, {}, 0
local clock = 1000
local real_open, real_remove, real_rename = io.open, os.remove, os.rename
local function virtual(path) return type(path) == "string" and path:sub(1, #SAVES) == SAVES end
WRITE_FAIL = false
io.open = function(path, mode)
	if not virtual(path) then return real_open(path, mode) end
	mode = mode or "r"
	if mode:find("r", 1, true) then
		local data = VFS[path]
		if data == nil then return nil, "no such file" end
		READS = READS + 1
		return { read = function() return data end, close = function() end }
	end
	if WRITE_FAIL then return nil, "disk full" end
	local buf = {}
	local f = {}
	function f.write(self, s) buf[#buf + 1] = s; return self end
	function f.close()
		clock = clock + 1
		VFS[path], MTIME[path] = table.concat(buf), clock
	end
	return f
end
os.remove = function(path)
	if not virtual(path) then return real_remove(path) end
	if VFS[path] == nil then return nil, "no such file" end
	VFS[path] = nil
	return true
end
os.rename = function(from, to)
	if not virtual(from) then return real_rename(from, to) end
	if VFS[from] == nil or VFS[to] ~= nil then return nil, "cannot rename" end -- Windows: not over a file
	VFS[to], MTIME[to] = VFS[from], MTIME[from]
	VFS[from] = nil
	return true
end

FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
function bit_or(a, b) return a + b end
function getFS()
	return {
		update_path = function(_, alias) return alias == "$game_saves$" and SAVES or "" end,
		file_list_open_ex = function(_, alias, flags, mask)
			local pat = "^" .. mask:gsub("[%.%-%+%[%]%(%)%%%^%$]", "%%%0"):gsub("%*", ".*") .. "$"
			local names = {}
			for path in pairs(VFS) do
				local name = path:sub(#SAVES + 1)
				if name:find(pat) then names[#names + 1] = name end
			end
			table.sort(names)
			return {
				Size = function() return #names end,
				GetAt = function(_, i)
					local name = names[i + 1]
					return {
						NameFull = function() return name end,
						ModifDigitOnly = function() return MTIME[SAVES .. name] or 0 end,
						Size = function() return #VFS[SAVES .. name] end,
					}
				end,
			}
		end,
	}
end

-- marshal: a plain serializer (the game's is the C library of the same name)
local function ser(v)
	local t = type(v)
	if t == "table" then
		local parts = {}
		for k, x in pairs(v) do parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end
marshal = {
	encode = function(t) return "M1" .. ser(t) end,
	decode = function(s)
		assert(type(s) == "string" and s:sub(1, 2) == "M1", "not marshal data")
		return assert(loadstring("return " .. s:sub(3)))()
	end,
}

-- the engine's coop.game
GAME = { staged = nil, cvars = nil, cvar_calls = 0, faction = "", machine = {}, refused = {}, fail_take = false }
coop.game = {
	stage_new = function(payload, faction)
		if type(payload) ~= "string" or #payload == 0 or type(faction) ~= "string" or faction == "" then return false end
		GAME.staged = { payload = payload, faction = faction }
		return true
	end,
	take_new = function()
		if GAME.fail_take then error("take_new failed") end
		local s = GAME.staged
		GAME.staged = nil
		if s then return s.payload, s.faction end
		return nil, nil
	end,
	set_cvars = function(t)
		GAME.cvars, GAME.cvar_calls = t, GAME.cvar_calls + 1
		local n = 0
		for _ in pairs(t) do n = n + 1 end
		return n, GAME.refused
	end,
	release_cvars = function() return 0 end,
	machine_cvar = function(name) return GAME.machine[name] end,
	set_world_faction = function(f) GAME.faction = f; return true end,
	world_faction = function() return GAME.faction end,
}
SESSION = {}
coop.session_info = function() return SESSION end

-- the machine's console (get_console_cmd(0, name) is the Status string)
CONSOLE = {
	coop_friendly_fire = "1", coop_max_new_characters = "8", coop_share_rewards = "0", coop_death_mode = "checkpoint",
	coop_death_drop = "drop", coop_bleedout = "60.00000", coop_revive_health = "0.30000", coop_respawn_delay = "30.00000",
	coop_contusion = "10.00000", coop_death_money = "10.00000", coop_death_wear = "10.00000", coop_death_rank = "0.00000",
	coop_hardcore_new_kit = "0", coop_checkpoints_group = "1", coop_autosave_interval = "10", coop_autosave_count = "10",
	coop_death_share = "100.00000", coop_split_levels = "1", coop_story_together = "1",
}
function get_console_cmd(typ, name) return CONSOLE[name] or "" end

-- level.present
IN_LEVEL = true
level.present = function() return IN_LEVEL end

-- the actor
COMMUNITY, INFOS, GIVEN = "actor_dolg", {}, 0
function has_alife_info(id) return INFOS[id] == true end
function give_info() GIVEN = GIVEN + 1 end
db.actor = {
	character_community = function() return COMMUNITY end,
	character_name = function() return "Strelok" end,
	give_game_news = function(_, cap, text) NEWS[#NEWS + 1] = tostring(text) end,
	alive = function() return true end,
}
game.translate_string = function(id) return "<" .. id .. ">" end

-- axr_options.ltx: an ini_file_ex that looks its methods up on the class at call time (luabind), like test_settings
local function new_ini_class()
	local cls = {}
	local mt = { __index = function(_, k) return cls[k] end }
	function cls.new(data) return setmetatable({ data = data, cache = {}, saves = 0 }, mt) end
	function cls.r_value(self, s, k, typ, def)
		local c = self.cache[s .. "&" .. k]
		if c then return c end
		local sec = self.data[s]
		if not (sec and sec[k] ~= nil) then return def end
		local v = sec[k]
		if typ == 1 then
			v = v == "true"
		elseif typ == 2 then
			v = tonumber(v) or def
		end
		self.cache[s .. "&" .. k] = v
		return v
	end
	function cls.w_value(self, s, k, val)
		self.cache[s .. "&" .. k] = val
		self.data[s] = self.data[s] or {}
		self.data[s][k] = val ~= nil and tostring(val) or ""
	end
	function cls.save(self) self.saves = self.saves + 1 end
	function cls.collect_section(self, s)
		local t = {}
		for k, v in pairs(self.data[s] or {}) do t[k] = v end
		return t
	end
	function cls.line_exist(self, s, k) return self.data[s] ~= nil and self.data[s][k] ~= nil end
	function cls.r_string_ex(self, s, k) return self.data[s] and self.data[s][k] or nil end
	return cls
end
ini_file_ex = new_ini_class()
local MACHINE = {
	options = {
		["alife/event/emission_state"] = "true", ["alife/event/emission_frequency"] = "24",
		["gameplay/general/max_tasks"] = "5", ["coop/coop_session/gather_radius"] = "20", ["video/basic/fov"] = "65",
		["coop/coop_player/nick"] = "Strelok", ["alife/dynamic_news/message_duration"] = "7",
	},
	mcm = {
		["drx_da/anomaly_amount_modifier"] = "1.5", ["drx_da/debug_mode"] = "true", ["unknown_mod/opt"] = "7",
		["ssfx_wetness/size"] = "3",
	},
}
local CFG = ini_file_ex.new(MACHINE)
axr_main.config = CFG

-- difficulty
local FACTORS = { g = { type = 2, hit_power = 1.5, thirst = false }, e = { type = 2, buy = 1.2 } }
M_DATA = { diff_game = FACTORS.g, diff_eco = FACTORS.e, trader_buy_condition_override = 40 }
SETTER_CALLS = {}
game_difficulties = {
	get_game_factor = function(k) return FACTORS.g[k] end,
	get_eco_factor = function(k) return FACTORS.e[k] end,
	set_game_factor = function(k, v)
		if FACTORS.g[k] ~= v then give_info("diff_gameplay_flag_change") end
		FACTORS.g[k] = v
		SETTER_CALLS[#SETTER_CALLS + 1] = "g:" .. k
	end,
	set_eco_factor = function(k, v)
		if FACTORS.e[k] ~= v then give_info("diff_economy_flag_change") end
		FACTORS.e[k] = v
		SETTER_CALLS[#SETTER_CALLS + 1] = "e:" .. k
	end,
}

-- the save manager: what the engine calls (the wrapper of the real script is found at call time)
alife_storage_manager = {
	get_state = function() return M_DATA end,
	CALifeStorageManager_before_save = function(fname)
		SAVED_AS = fname
		SendScriptCallback("save_state", M_DATA)
		return "saved"
	end,
}
function save_game(fname) return alife_storage_manager.CALifeStorageManager_before_save(fname) end

-- a control of the stock window
function window()
	return { enabled = true, Enable = function(self, on) self.enabled = on and true or false end }
end

-- the stock windows (UIOptions, and the MCM window UI_MCM of the same shape): Reset_opt draws every control through
-- self:Register, the tracks are kept in _Track
DRAWN = nil
local function make_window_class()
	local cls = {}
	function cls.Register(self, ctrl, id) self.reg = self.reg or {}; self.reg[id] = ctrl end
	function cls.CacheValue(self, path, opt, value) self.cached = { path .. "/" .. opt, value } end
	function cls.Update() end
	function cls.Reset_opt(self, tree, path)
		DRAWN = { presets = tree.presets, items = {} }
		self._Track = {}
		for _, v in ipairs(tree.gr) do
			DRAWN.items[#DRAWN.items + 1] = v.type == "desc" and ("desc:" .. v.text) or v.id
			if v.type == "check" or v.type == "list" or v.type == "input" or v.type == "track" then
				local ctrl = window(path .. "/" .. v.id)
				self:Register(ctrl, path .. "/" .. v.id .. "/" .. 1)
				if v.type == "track" then self._Track[path .. "/" .. v.id] = { ctrl = window("t"), path = path } end
			end
		end
	end
	return cls
end
local UIO, MCMC = make_window_class(), make_window_class()
ui_options = { UIOptions = UIO }
MCM_SET = {}
ui_mcm = {
	UI_MCM = MCMC,
	get = function(id) return CFG:r_value("mcm", id, 0) end,
	set = function(id, v) MCM_SET[#MCM_SET + 1] = id; CFG:w_value("mcm", id, v); CFG:save() end,
}
local function new_dlg(cls)
	cls = cls or UIO
	return setmetatable({}, { __index = function(_, k) return cls[k] end })
end

-- callbacks the stock axr_main has and the router stub of stubs.lua lacks
for _, name in ipairs({ "save_state", "actor_on_first_update", "on_option_change" }) do AddScriptCallback(name) end
OPTION_CHANGES = 0
RegisterScriptCallback("on_option_change", function() OPTION_CHANGES = OPTION_CHANGES + 1 end)

-- the scripts under test (the engine's _G.__index loads the catalog and the record when the first one asks)
local sc = load_script_file("coop_game_schema")
local rc = load_script_file("coop_game_record")
local cs = load_script_file("coop_settings")
local gs = load_script_file("coop_game_settings")
load_script_file("coop_economy_core")
check(gs ~= nil and cs ~= nil and sc ~= nil and rc ~= nil, "the scripts load")
if not gs then
	print(string.format("%d passed, %d failed", PASSES, FAILS))
	os.exit(1)
end

cs.on_game_start()
gs.on_game_start()

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------
local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function count_c(values)
	local n = 0
	for k in pairs(values) do if k:find("^c|") then n = n + 1 end end
	return n
end

-- a record the way the new game screen makes it
local function make_record(extra, meta)
	local values = gs.defaults()
	for k, v in pairs(extra or {}) do values[k] = v end
	return rc.new(values, meta or { name = "Strelok", faction = "dolg",
		world = { story = true, routes = false, difficulty = 2, economy = 2 } })
end

-- a save of the game: <stem>.scoc holding the record as the save's block
local function put_save(stem, record, rest)
	local m = rest or {}
	if record then m.coop_game = rc.clone(record) end
	VFS[SAVES .. stem .. ".scoc"] = marshal.encode(m)
	MTIME[SAVES .. stem .. ".scoc"] = clock
end

local function put_card(record)
	VFS[SAVES .. record.id .. ".cgame"] = assert(rc.encode(record, marshal))
	MTIME[SAVES .. record.id .. ".cgame"] = clock
end

local function card_of(id)
	local data = VFS[SAVES .. id .. ".cgame"]
	return data and rc.decode(data, marshal)
end

local function reset_disk()
	VFS, MTIME = {}, {}
end

local function first_update()
	SendScriptCallback("actor_on_first_update", {}, 0)
end

local function fresh_machine()
	CFG.cache = {}
	MACHINE.options["alife/event/emission_frequency"] = "24"
	MACHINE.options["alife/event/emission_state"] = "true"
	MACHINE.mcm["drx_da/anomaly_amount_modifier"] = "1.5"
	MACHINE.mcm["unknown_mod/opt"] = "7"
	CFG.saves = 0
end

-------------------------------------------------------------------------------
section("classification: what the game owns (Ruling GS-1)")
check(cs.owner_of("mcm", "unknown_mod/opt") == "host" and cs.owner_of("mcm", "drx_da/anomaly_amount_modifier") == "host",
	"for a client both an unknown and a listed MCM option are the host's")
check(cs.is_game_owned("mcm", "drx_da/anomaly_amount_modifier") == true, "a listed [mcm_host] option belongs to the game")
check(cs.is_game_owned("mcm", "unknown_mod/opt") == false, "an MCM option that is the host's only by default does not (GS-1)")
check(cs.is_game_owned("mcm", "drx_da/debug_mode") == false, "[mcm_player] keys never")
check(cs.is_game_owned("options", "alife/event/emission_state") == true and cs.is_game_owned("options", "gameplay/general/max_tasks") == true,
	"the stock option groups of [options_host] belong to the game")
check(cs.is_game_owned("options", "coop/coop_session/gather_radius") == true, "the co-op rules belong to the game")
check(cs.is_game_owned("options", "video/basic/fov") == false and cs.is_game_owned("options", "coop/coop_player/nick") == false,
	"player options never")
check(cs.is_game_owned("o", "alife/event/emission_state") == true and cs.is_game_owned("m", "drx_da/anomaly_amount_modifier") == true,
	"the short sources o / m are accepted too")

-------------------------------------------------------------------------------
section("defaults: the machine's values plus the catalog's")
fresh_machine()
local D = gs.defaults()
check(count_c(D) == 19 and D["c|coop_bleedout"] == "60" and D["c|coop_revive_health"] == "0.3" and D["c|coop_death_share"] == "100",
	"the 19 console rules, canonical (the console prints 60.00000 / 0.30000)")
check(D["o|alife/event/emission_frequency"] == "24" and D["o|coop/coop_session/gather_radius"] == "20",
	"host options come from the machine")
check(D["o|coop/coop_session/travel_time"] == "true" and D["o|coop/coop_session/join_spawn"] == "faction_start",
	"a catalog option the machine lacks gets the catalog's default (join_spawn: at the faction's base since F3a)")
check(D["m|drx_da/anomaly_amount_modifier"] == "1.5", "a listed MCM option of the machine")
check(D["o|video/basic/fov"] == nil and D["o|coop/coop_player/nick"] == nil and D["m|drx_da/debug_mode"] == nil,
	"player options are not the game's")
check(D["m|unknown_mod/opt"] == nil, "an MCM option that is the host's only by default is not taken (GS-1)")
check(D["m|drx_da/artefacts_spawn_chance"] == nil, "an MCM catalog option the machine lacks is not invented")
GAME.machine.coop_bleedout = "90"
check(gs.defaults()["c|coop_bleedout"] == "90", "while a game value is set the machine's is the engine's remembered one")
GAME.machine.coop_bleedout = nil

-------------------------------------------------------------------------------
section("new_world_takes_pending")
reset_disk()
local REC1 = make_record({ ["o|alife/event/emission_frequency"] = "48" })
check(gs.stage_new(REC1) == true and GAME.staged and GAME.staged.faction == "dolg" and #GAME.staged.payload > 20,
	"stage_new hands the engine the encoded record and the world's faction")
check(gs.stage_new({ id = "x" }) == false, "a thing that is no record is not staged")
check(gs.active() == nil and gs.locked() == false, "nothing is active before the world starts")
gs.before_world_start("new", "")
local A = gs.active()
check(A and A.id == REC1.id and A.faction == "dolg" and A.world.difficulty == 2 and A.rev == 0, "the staged record is active")
check(GAME.staged == nil, "the engine's pending game was taken")
check(GAME.cvar_calls == 1 and count(GAME.cvars) == 19 and GAME.cvars.coop_death_mode == "checkpoint"
	and GAME.cvars.coop_bleedout == "60" and GAME.cvars.coop_friendly_fire == "1", "19 console values go to the engine (set_cvars)")
check(GAME.faction == "dolg" and gs.world_faction() == "dolg", "the world's faction is set")
check(gs.origin() == "new" and gs.running_id() == REC1.id and gs.locked() == true, "origin new, the running game, locked in a level")
check(gs.value("o", "alife/event/emission_frequency") == "48" and gs.value("o", "gameplay/none") == nil
	and gs.value("m", "drx_da/anomaly_amount_modifier") == "1.5", "value(): the record's raw value, nil when it is not there")
gs.put("o", "alife/event/emission_state", false)
check(gs.value("options", "alife/event/emission_state") == "false", "put(): the record takes a host-side write (a string, long names too)")
gs.put("o", "alife/event/emission_state", nil)
check(gs.value("o", "alife/event/emission_state") == nil, "put(nil) drops the key")

-- no staged game: a single-player new game
gs.before_world_start("new", "")
check(gs.active() == nil and gs.locked() == false and GAME.cvar_calls == 1, "a new game with nothing staged: nothing is active")
-- the engine's call must not throw
GAME.fail_take = true
check(pcall(gs.before_world_start, "new", ""), "a failing engine call does not throw")
GAME.fail_take = false
check(pcall(gs.before_world_start, "weird", nil), "an unknown mode does not throw")
-- a staged payload that is not a record
GAME.staged = { payload = "garbage", faction = "dolg" }
gs.before_world_start("new", "")
check(gs.active() == nil, "an unreadable staged game: the world starts with the machine's values")

-------------------------------------------------------------------------------
section("load_reads_block_and_card")
reset_disk()
local B1 = make_record({ ["c|coop_bleedout"] = "120" })
local B1c = rc.clone(B1)
B1.rev, B1c.rev = 1, 2
B1c.values["c|coop_bleedout"] = "90"
put_save("s1", B1)
put_card(B1c)
gs.before_world_start("load", "s1")
check(gs.active() and gs.active().rev == 2 and gs.active().values["c|coop_bleedout"] == "90" and gs.origin() == "card",
	"save rev 1, card rev 2: the card is active")
check(GAME.cvars.coop_bleedout == "90" and GAME.faction == "dolg", "its values and the world's faction go to the engine")
B1.rev = 2
put_save("s1", B1)
gs.before_world_start("load", "s1")
check(gs.active().values["c|coop_bleedout"] == "120" and gs.origin() == "save", "save rev 2, card rev 2: the save")
VFS[SAVES .. B1.id .. ".cgame"] = nil
gs.before_world_start("load", "S1")
check(gs.active() and gs.active().id == B1.id and gs.origin() == "save", "no card: the save (the name in any case)")
put_save("old", nil, { whatever = 1 })
gs.before_world_start("load", "old")
check(gs.active() == nil, "a save without a block: nothing is active")
gs.before_world_start("load", "missing")
check(gs.active() == nil, "no such save: nothing is active, no error")
VFS[SAVES .. "bad.scoc"] = "not marshal"
check(pcall(gs.before_world_start, "load", "bad") and gs.active() == nil, "an unreadable .scoc is not an error")
check(pcall(gs.before_world_start, "load", "..\\evil"), "a name with a path is passed over")

-------------------------------------------------------------------------------
section("overlay_record_then_machine")
reset_disk()
fresh_machine()
local REC2 = make_record({ ["o|alife/event/emission_frequency"] = "48" })
REC2.values["m|drx_da/anomaly_amount_modifier"] = nil
GAME.staged = { payload = assert(rc.encode(REC2, marshal)), faction = "dolg" }
gs.before_world_start("new", "")
check(CFG:r_value("options", "alife/event/emission_frequency", 2) == 48, "a key of the record reads the record's value (as a number)")
check(MACHINE.options["alife/event/emission_frequency"] == "24", "the machine's file is not touched")
check(CFG:r_value("options", "alife/event/emission_state", 1) == true, "a boolean of the record")
check(gs.active().values["m|drx_da/anomaly_amount_modifier"] == nil, "the MCM key is not in the record yet")
check(CFG:r_value("mcm", "drx_da/anomaly_amount_modifier", 2) == 1.5, "a key the record lacks reads the machine's value")
check(gs.active().values["m|drx_da/anomaly_amount_modifier"] == "1.5", "and joins the record")
MACHINE.mcm["drx_da/anomaly_amount_modifier"] = "9"
CFG.cache = {}
check(CFG:r_value("mcm", "drx_da/anomaly_amount_modifier", 2) == 1.5, "afterwards the record's value holds, not the machine's new one")
check(CFG:r_value("options", "video/basic/fov", 2) == 65 and gs.active().values["o|video/basic/fov"] == nil,
	"a player option reads the machine and stays out of the record")
check(CFG:r_value("mcm", "unknown_mod/opt", 2) == 7 and gs.active().values["m|unknown_mod/opt"] == nil,
	"an MCM option that is the host's only by default reads the machine and stays out of the record (GS-1)")
check(CFG:r_value("options", "alife/event/none", 2, 3) == 3 and gs.active().values["o|alife/event/none"] == nil,
	"a key neither the record nor the machine has: the caller's default, nothing recorded")
-- a key the machine has none of and a stock default is written for (ui_options.get)
CFG:w_value("options", "gameplay/general/npc_loot_distance", 15)
check(gs.active().values["o|gameplay/general/npc_loot_distance"] == "15" and MACHINE.options["gameplay/general/npc_loot_distance"] == nil,
	"the stock default write lands in the record")
MACHINE.mcm["drx_da/anomaly_amount_modifier"] = "1.5"

-------------------------------------------------------------------------------
section("host_write_goes_to_record")
CFG.saves = 0
CFG:w_value("options", "alife/event/emission_state", false)
CFG:save()
check(gs.active().values["o|alife/event/emission_state"] == "false", "a write of a game option goes to the record (a string)")
check(MACHINE.options["alife/event/emission_state"] == "true", "the file is not touched")
check(CFG.saves == 0, "save() after nothing but such writes is skipped")
check(CFG:r_value("options", "alife/event/emission_state", 1) == false, "and it reads back")
CFG:w_value("options", "video/basic/fov", 90)
CFG:save()
check(MACHINE.options["video/basic/fov"] == "90" and CFG.saves == 1, "a player option is written and saved as ever")
CFG:w_value("options", "alife/event/emission_state", true)
CFG:w_value("options", "video/basic/fov", 80)
CFG:save()
check(CFG.saves == 2, "a save after both kinds of write happens")
CFG:w_value("mcm", "unknown_mod/opt", "11")
CFG:save()
check(MACHINE.mcm["unknown_mod/opt"] == "11" and CFG.saves == 3, "an MCM option that is the host's only by default is written to the machine (GS-1)")
CFG:w_value("mcm", "drx_da/anomaly_amount_modifier", 2)
check(gs.active().values["m|drx_da/anomaly_amount_modifier"] == "2" and MACHINE.mcm["drx_da/anomaly_amount_modifier"] == "1.5",
	"a listed MCM option goes to the record")

-------------------------------------------------------------------------------
section("locked_only_in_level")
IN_LEVEL = false
check(gs.active() ~= nil and gs.locked() == false, "outside a level the record is not locked")
check(CFG:r_value("options", "alife/event/emission_frequency", 2) == 24, "and a read gives the machine's value")
CFG.saves = 0
CFG:w_value("options", "alife/event/emission_frequency", 6)
CFG:save()
check(MACHINE.options["alife/event/emission_frequency"] == "6" and CFG.saves == 1, "a write goes to the file")
MACHINE.options["alife/event/emission_frequency"] = "24"
CFG.cache = {}
IN_LEVEL = true
check(gs.locked() == true and CFG:r_value("options", "alife/event/emission_frequency", 2) == 48, "back in a level: the record again")

-------------------------------------------------------------------------------
section("client_noop")
MODE = "client"
gs.before_world_start("new", "")
check(gs.active() == nil and gs.locked() == false, "a client: before_world_start enables nothing")
GAME.staged = { payload = assert(rc.encode(REC2, marshal)), faction = "dolg" }
gs.before_world_start("new", "")
check(gs.active() == nil and GAME.staged ~= nil, "a client does not take the engine's pending game")
put_save("cl", REC2)
gs.before_world_start("load", "cl")
check(gs.active() == nil, "a client does not apply the record of the host's save")
M_DATA.coop_game = rc.clone(REC2)
SendScriptCallback("load_state", M_DATA)
check(gs.active() == nil, "load_state of a client does nothing")
SESSION = { pending_host = 27960 }
M_DATA.coop_game = nil
SendScriptCallback("load_state", M_DATA)
check(gs.active() == nil, "and does not migrate")
SESSION = {}
GAME.staged = nil
MODE = "host"

-------------------------------------------------------------------------------
section("save_state_writes_block_and_card")
reset_disk()
fresh_machine()
M_DATA = { diff_game = FACTORS.g, diff_eco = FACTORS.e, trader_buy_condition_override = 40 }
local REC3 = make_record({})
GAME.staged = { payload = assert(rc.encode(REC3, marshal)), faction = "dolg" }
gs.before_world_start("new", "")
check(card_of(REC3.id) == nil, "no card before the first save")
check(save_game("mysave.scop") == "saved" and SAVED_AS == "mysave.scop", "the wrapper of before_save passes the call on and returns")
local blk = M_DATA.coop_game
check(type(blk) == "table" and blk.id == REC3.id and blk.rev == 0 and blk.faction == "dolg" and blk.values["c|coop_death_mode"] == "checkpoint",
	"the block of the save holds the record")
check(blk.last_save == nil and blk.last_played == nil, "the block carries no card fields")
local C3 = card_of(REC3.id)
check(C3 and C3.id == REC3.id and C3.last_save == "mysave" and C3.last_played and C3.last_played ~= "" and C3.name == "Strelok",
	"the card holds it with the name of the save and the time")
check(blk.values["g|hit_power"] == nil, "the mirror of the difficulty comes at the first update, not before")
save_game("coop_auto_tmp.scop")
check(card_of(REC3.id).last_save == "mysave", "the temporary name of an autosave is not 'the last save'")
save_game("coop_auto_3.scop")
check(card_of(REC3.id).last_save == "coop_auto_3", "a slot of the autosaves is")
-- an edit from the menu made while the game runs survives the game's next save
local okE, whyE = gs.save_edits(REC3.id, { ["c|coop_bleedout"] = 120 })
check(okE == true, "save_edits writes the card of the running game" .. tostring(whyE))
save_game("mysave2.scop")
local C3b = card_of(REC3.id)
check(C3b.rev == 1 and C3b.values["c|coop_bleedout"] == "120" and C3b.last_save == "mysave2", "the next save keeps the menu's edit in the card")
check(M_DATA.coop_game.rev == 0 and M_DATA.coop_game.values["c|coop_bleedout"] == "60", "and the block shows what was in force")
-- single player without a record leaves the save alone
gs.before_world_start("new", "")
local M2 = { x = 1 }
SendScriptCallback("save_state", M2)
check(M2.coop_game == nil, "no record: m_data is not touched")
-- the disk is full: no error, the save goes on
gs.before_world_start("new", "")
GAME.staged = { payload = assert(rc.encode(make_record({}), marshal)), faction = "dolg" }
gs.before_world_start("new", "")
WRITE_FAIL = true
check(pcall(save_game, "full.scop") and M_DATA.coop_game ~= nil, "a card that cannot be written is not an error")
WRITE_FAIL = false

-------------------------------------------------------------------------------
section("factors_from_card_on_first_update")
reset_disk()
fresh_machine()
FACTORS.g.hit_power, FACTORS.g.thirst, FACTORS.e.buy = 1.5, false, 1.2
M_DATA = { diff_game = FACTORS.g, diff_eco = FACTORS.e, trader_buy_condition_override = 40 }
local F = make_record({})
F.rev = 1
F.values["g|hit_power"], F.values["g|thirst"] = 1.5, false
F.values["e|buy"], F.values["s|trader_buy_condition_override"] = 1.2, 40
local Fc = rc.clone(F)
Fc.rev = 2
Fc.values["g|hit_power"], Fc.values["e|buy"], Fc.values["s|trader_buy_condition_override"] = 2.5, 1.4, 55
put_save("f1", F)
put_card(Fc)
gs.before_world_start("load", "f1")
check(gs.origin() == "card", "the card of a menu edit is the active record")
SETTER_CALLS, GIVEN = {}, 0
SendScriptCallback("load_state", M_DATA)
check(#SETTER_CALLS == 0, "load_state sets nothing")
first_update()
check(FACTORS.g.hit_power == 2.5 and FACTORS.e.buy == 1.4 and M_DATA.trader_buy_condition_override == 55,
	"the edited factors are set at the first update (difficulty, economy, the save's other value)")
check(#SETTER_CALLS == 2 and not SETTER_CALLS[1]:find("thirst"), "only what differs, through the setters (" .. table.concat(SETTER_CALLS, ",") .. ")")
check(GIVEN == 0 and give_info ~= nil, "the info portion is muted while setting, and restored")
check(game_difficulties.set_game_factor("hit_power", 9) == nil and FACTORS.g.hit_power == 2.5, "in the game the host cannot set a factor by hand any more")
check(gs.active().values["g|hit_power"] == 2.5, "the record mirrors the live factor")

-- a save of the same game: the block is the truth, only the mirror is refreshed
reset_disk()
FACTORS.g.hit_power = 1.5
local G2 = make_record({})
G2.values["g|hit_power"] = 1.5
put_save("f2", G2)
gs.before_world_start("load", "f2")
SETTER_CALLS = {}
first_update()
check(#SETTER_CALLS == 0 and FACTORS.g.hit_power == 1.5, "a record from the save does not touch the factors")
check(gs.active().values["g|hit_power"] == 1.5 and gs.active().values["e|buy"] == 1.4 and gs.active().values["g|type"] == nil
	and gs.active().values["s|trader_buy_condition_override"] == 55, "the mirror takes the effective factors (not the preset type)")
-- the new game: the record has no factors until the stock code made them
reset_disk()
GAME.staged = { payload = assert(rc.encode(make_record({}), marshal)), faction = "dolg" }
gs.before_world_start("new", "")
FACTORS.g.hit_power = 1.7
first_update()
check(gs.active().values["g|hit_power"] == 1.7, "a new game: the preset's factors are mirrored at the first update")
check(gs.active().values["g|thirst"] == false and gs.active().values["e|buy"] ~= nil,
	"a new game: a factor that is false is mirrored (it is a value, not a missing one)")

-------------------------------------------------------------------------------
section("migration_coop_host_only")
reset_disk()
NEWS = {}
fresh_machine()
M_DATA = { diff_game = { type = 2, hit_power = 1.5 }, diff_eco = { type = 3, buy = 1.2 }, opened_routes = true }
INFOS = { story_mode_disabled = true }
COMMUNITY = "actor_freedom"
gs.before_world_start("load", "oldsave")
check(gs.active() == nil, "an old save has no record at the world start")
SESSION = {}
SendScriptCallback("load_state", M_DATA)
check(gs.active() == nil, "no sign of a co-op host (single player): nothing")
SESSION = { client = true }
MODE = "client"
SendScriptCallback("load_state", M_DATA)
MODE = "host"
check(gs.active() == nil, "a client session: nothing")
SESSION = { pending_host = 27960 }
local ACTOR = db.actor
db.actor = nil -- the world is loading: there is no actor yet
SendScriptCallback("load_state", M_DATA)
db.actor = ACTOR
local MG = gs.active()
check(MG and MG.migrated == true and MG.rev == 0 and gs.origin() == "migrated", "a co-op host's old save: a migrated record")
check(MG.world.story == false and MG.world.routes == true and MG.world.difficulty == 2 and MG.world.economy == 3,
	"the world's flags from the save (story_mode_disabled, opened_routes, diff_game.type, diff_eco.type)")
check(MG.values["o|alife/event/emission_frequency"] == "24" and MG.values["c|coop_death_mode"] == "checkpoint"
	and MG.values["m|drx_da/anomaly_amount_modifier"] == "1.5" and MG.values["g|hit_power"] == 1.5 and MG.values["e|buy"] == 1.2,
	"the machine's values and the save's factors")
check(MG.values["o|video/basic/fov"] == nil and MG.values["m|unknown_mod/opt"] == nil, "player options and default-host MCM are not taken")
check(MG.faction == nil and card_of(MG.id) == nil, "the faction and the card wait for the first update (the actor)")
NEWS = {}
first_update()
check(MG.faction == "freedom" and GAME.faction == "freedom", "the faction is the community of the host's actor, without 'actor_'")
check(card_of(MG.id) and card_of(MG.id).migrated == true and card_of(MG.id).faction == "freedom" and card_of(MG.id).name == "Strelok",
	"the card is written")
check(#NEWS == 1 and NEWS[1]:find("st_coop_game_migrated", 1, true), "the host gets one news item")
first_update()
check(#NEWS == 1, "only one")
save_game("m1.scop")
check(M_DATA.coop_game and M_DATA.coop_game.migrated == true and M_DATA.coop_game.id == MG.id, "the next save carries it")
-- the command line says host too; a pure single-player game on this exe is untouched
SESSION = {}
INFOS = {}
gs.before_world_start("load", "oldsave2")
M_DATA = { diff_game = {}, diff_eco = {} }
SendScriptCallback("load_state", M_DATA)
check(gs.active() == nil, "single player: nothing again")
command_line = function() return "xr_3da.exe -coop_host" end
SendScriptCallback("load_state", M_DATA)
check(gs.active() and gs.active().migrated == true, "-coop_host on the command line counts as a host")
command_line = nil
-- a block this version cannot read is not replaced by a migration
gs.before_world_start("load", "oldsave3")
SESSION = { host = true }
M_DATA = { coop_game = { v = 99, id = "x", values = {} }, diff_game = {}, diff_eco = {} }
SendScriptCallback("load_state", M_DATA)
check(gs.active() == nil and M_DATA.coop_game.v == 99, "a newer block is left alone")
SESSION = {}

-------------------------------------------------------------------------------
section("late enabling (the save was not read at the world start)")
reset_disk()
fresh_machine()
local L = make_record({ ["c|coop_bleedout"] = "150" })
M_DATA = { coop_game = rc.clone(L), diff_game = FACTORS.g, diff_eco = FACTORS.e }
gs.before_world_start("load", "latesave") -- no .scoc on the disk: the block comes with load_state
check(gs.active() == nil, "nothing active yet")
GAME.cvar_calls, OPTION_CHANGES = 0, 0
SendScriptCallback("load_state", M_DATA)
check(gs.active() and gs.active().id == L.id and gs.origin() == "save" and GAME.cvars and GAME.cvars.coop_bleedout == "150",
	"load_state switches the record on and sets the console values")
check(OPTION_CHANGES == 0, "on_option_change waits for the first update")
first_update()
check(OPTION_CHANGES == 1, "and is fired once after it")
first_update()
check(OPTION_CHANGES == 1, "only once")
-- the same game already active from the world start: nothing to do
put_save("early", L)
gs.before_world_start("load", "early")
GAME.cvar_calls, OPTION_CHANGES = 0, 0
SendScriptCallback("load_state", { coop_game = rc.clone(L) })
first_update()
check(GAME.cvar_calls == 0 and OPTION_CHANGES == 0, "the record of the world start is not switched on twice")
-- a card newer than the block, found late
reset_disk()
local L2c = rc.clone(L)
L2c.rev = 4
L2c.values["c|coop_bleedout"] = "30"
put_card(L2c)
gs.before_world_start("load", "latesave")
SendScriptCallback("load_state", { coop_game = rc.clone(L) })
check(gs.active().rev == 4 and gs.origin() == "card", "late: the card with the higher rev wins too")

-------------------------------------------------------------------------------
section("the games of the menu")
reset_disk()
fresh_machine()
local ga = make_record({}, { name = "Alpha", faction = "dolg", world = {} })
local gb = make_record({}, { name = "Beta", faction = "monolith", world = {} })
ga.last_played, gb.last_played, ga.last_save, gb.last_save = "2026-10-20 10:00", "2026-10-22 18:30", "a_save", "coop_auto_2"
gb.rev = 3
put_card(ga)
put_card(gb)
VFS[SAVES .. "junk.cgame"] = "not marshal"
VFS[SAVES .. "other.scop"] = "x"
local list = gs.list_games()
check(#list == 2 and list[1].id == gb.id and list[2].id == ga.id, "list_games: the cards, the latest game first")
check(list[1].name == "Beta" and list[1].faction == "monolith" and list[1].last_save == "coop_auto_2" and list[1].last_played == "2026-10-22 18:30"
	and list[1].created and list[1].rev == 3, "with name, faction, created, last_save, last_played")
check(gs.load_card(ga.id).name == "Alpha" and gs.load_card("nope") == nil and gs.load_card("../x") == nil and gs.load_card(nil) == nil,
	"load_card: by id; unknown or malformed ids give nil")
-- game_of_save: decoded once per name | time | size
put_save("sv1", ga)
READS = 0
local id1, r1 = gs.game_of_save("sv1")
check(id1 == ga.id and r1 and r1.name == "Alpha", "game_of_save: the id and the record of the save's block")
local reads1 = READS
local id1b = gs.game_of_save("sv1")
check(id1b == ga.id and READS == reads1, "the second ask is answered from the cache (no read)")
put_save("sv1", gb)
clock = clock + 1
MTIME[SAVES .. "sv1.scoc"] = clock
check(gs.game_of_save("sv1") == gb.id and READS > reads1, "a changed save is read again")
put_save("plain", nil, { x = 1 })
check(gs.game_of_save("plain") == nil and gs.game_of_save("nothere") == nil and gs.game_of_save("a/b") == nil, "no game: nil")

section("save_edits and take_machine")
local E0 = card_of(ga.id)
local ok1, why1 = gs.save_edits(ga.id, { ["c|coop_bleedout"] = 120, ["o|coop/coop_session/travel_time"] = false })
local E1 = card_of(ga.id)
check(ok1 == true and E1.rev == E0.rev + 1 and E1.values["c|coop_bleedout"] == "120" and E1.values["o|coop/coop_session/travel_time"] == "false",
	"save_edits: rev + 1, the values")
check(E1.last_save == "a_save" and E1.last_played == "2026-10-20 10:00" and E1.name == "Alpha", "the rest of the card stays")
local ok2, why2 = gs.save_edits(ga.id, { ["c|coop_death_mode"] = "hardcore" })
check(ok2 == false and tostring(why2):find("c|coop_death_mode", 1, true) and card_of(ga.id).rev == E1.rev,
	"a type of the world is refused, nothing is written (" .. tostring(why2) .. ")")
local ok2b = gs.save_edits(ga.id, { ["c|coop_bleedout"] = 120 })
check(ok2b == true and card_of(ga.id).rev == E1.rev, "the same value: unchanged, no new revision")
check(gs.save_edits("nope", { ["c|coop_bleedout"] = 60 }) == false, "no such game")
local ok2c = gs.save_edits(ga.id, { ["c|coop_bleedout"] = 5 })
check(ok2c == false and card_of(ga.id).values["c|coop_bleedout"] == "120", "a value out of range is refused")
-- take_machine
local TA = card_of(ga.id)
TA.values["o|something/old"] = "1"
TA.values["o|alife/event/emission_frequency"] = "99"
put_card(TA)
MACHINE.options["alife/event/emission_frequency"] = "12"
MACHINE.options["alife/general/new_page_opt"] = "5"
local okT, nT = gs.take_machine(ga.id)
local T1 = card_of(ga.id)
check(okT == true and nT and nT >= 1 and T1.rev == TA.rev + 1 and T1.values["o|alife/general/new_page_opt"] == "5"
	and T1.values["o|something/old"] == nil, "take_machine: the options outside the catalog are the machine's now, rev + 1")
check(T1.values["o|alife/event/emission_frequency"] == "99" and T1.machine_snapshot_at, "the catalog's values stay; the time of the snapshot")
check(gs.take_machine("nope") == false, "take_machine of an unknown game")
MACHINE.options["alife/general/new_page_opt"] = nil
MACHINE.options["alife/event/emission_frequency"] = "24"

section("ensure_record: a world without a record opened to partners")
reset_disk()
fresh_machine()
INFOS, COMMUNITY = {}, "actor_stalker"
M_DATA = { diff_game = { type = 1 }, diff_eco = { type = 1 } }
gs.before_world_start("new", "")
check(gs.active() == nil, "none")
IN_LEVEL = false
check(gs.ensure_record() == nil, "no level: no record")
IN_LEVEL = true
local eid = gs.ensure_record()
check(eid and gs.active() and gs.active().id == eid and gs.active().faction == "stalker" and card_of(eid), "a record from the machine's values, with a card")
check(gs.ensure_record() == eid, "asked again, the same one")

-------------------------------------------------------------------------------
section("snapshot_uses_record")
reset_disk()
fresh_machine()
local S1 = make_record({ ["o|alife/event/emission_frequency"] = "48" })
S1.values["m|drx_da/anomaly_amount_modifier"] = "2.5"
S1.values["o|gameplay/general/npc_loot_distance"] = "15"
GAME.staged = { payload = assert(rc.encode(S1, marshal)), faction = "dolg" }
gs.before_world_start("new", "")
SENT = {}
coop_main.on_event("coop_set_req", "", 1)
check(#SENT >= 1 and SENT[1].name == "coop_set" and SENT[1].target == 1, "the host answers a client's request")
local snap = {}
for _, e in ipairs(SENT) do
	for k, v in pairs(coop_main.decode(e.payload)) do snap[k] = v end
end
check(snap["o|alife/event/emission_frequency"] == "48" and MACHINE.options["alife/event/emission_frequency"] == "24",
	"the snapshot holds the record's value, not the file's")
check(snap["m|drx_da/anomaly_amount_modifier"] == "2.5" and snap["o|gameplay/general/npc_loot_distance"] == "15",
	"also a key the machine has another value of, or none")
check(snap["o|gameplay/general/max_tasks"] == "5" and snap["m|unknown_mod/opt"] == "7", "other host options (incl. the host-only-by-default MCM) from the machine")
check(snap["o|video/basic/fov"] == nil and snap["m|drx_da/debug_mode"] == nil, "no player options")
check(snap["g|hit_power"] ~= nil and snap["g|type"] == 2, "the difficulty factors, the preset type included, as before")

-------------------------------------------------------------------------------
section("lock_note_host_vs_client")
local PAGE = { presets = { "p1" }, gr = {
	{ id = "slide", type = "slide" },
	{ id = "max_tasks", type = "track", val = 2 },
	{ id = "player_name", type = "input", val = 0 },
	{ id = "npc_loot_distance", type = "check", val = 1 },
} }
local MCMPAGE = { presets = { "p2" }, gr = {
	{ id = "anomaly_amount_modifier", type = "track" },
	{ id = "debug_mode", type = "check" },
} }
-- the host in the game
local dlg = new_dlg()
dlg:Reset_opt(PAGE, "gameplay/general")
check(DRAWN.items[1] == "desc:st_coop_opt_game_note", "host in the game: the note says the game's settings set it")
check(DRAWN.presets == nil and PAGE.presets[1] == "p1" and #PAGE.gr == 4, "presets hidden for the render, the shared tree restored")
check(dlg.reg["gameplay/general/max_tasks/1"].enabled == false and dlg.reg["gameplay/general/npc_loot_distance/1"].enabled == false,
	"game options are disabled")
check(dlg.reg["gameplay/general/player_name/1"].enabled == true, "a player option stays editable")
local dm = new_dlg(MCMC)
dm:Reset_opt(MCMPAGE, "drx_da")
check(DRAWN.items[1] == "desc:st_coop_opt_game_note" and dm.reg["drx_da/anomaly_amount_modifier/1"].enabled == false,
	"a listed MCM option is locked for the host (the MCM window too)")
check(dm.reg["drx_da/debug_mode/1"].enabled == true, "a [mcm_player] key of the same addon stays open")
local dm2 = new_dlg(MCMC)
dm2:Reset_opt({ gr = { { id = "opt", type = "check" }, { id = "other_thing", type = "check" } } }, "unknown_mod")
check(DRAWN.items[1] == "opt" and dm2.reg["unknown_mod/opt/1"].enabled == true,
	"a page with only default-host MCM options: no note, no lock (GS-1)")
-- edits are refused
local menu = setmetatable({ pending = { SetText = function(_, t) end } }, { __index = UIO })
UIO.CacheValue(menu, "gameplay/general", "max_tasks", 9)
check(menu.cached and menu.cached[2] == nil and menu.coop_redraw == true, "the host's edit of a game option is not cached")
menu.coop_redraw = nil
UIO.CacheValue(menu, "video/basic", "fov", 100)
check(menu.cached and menu.cached[2] == 100, "a player option is cached")
MCM_SET = {}
ui_mcm.set("drx_da/anomaly_amount_modifier", 5)
ui_mcm.set("unknown_mod/opt", 5)
check(#MCM_SET == 1 and MCM_SET[1] == "unknown_mod/opt", "ui_mcm.set: refused for a listed option, passed for an unlisted one")
-- the same page for a client: everything the host owns (the mode flag is refreshed by the settings' update tick)
local function tick_settings()
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
end
MODE = "client"
tick_settings()
local dc = new_dlg()
dc:Reset_opt(PAGE, "gameplay/general")
check(DRAWN.items[1] == "desc:st_coop_opt_locked_note", "client: the old note, 'set by the host'")
local dcm = new_dlg(MCMC)
dcm:Reset_opt({ presets = { "p3" }, gr = { { id = "opt", type = "check" } } }, "unknown_mod")
check(dcm.reg["unknown_mod/opt/1"].enabled == false, "client: an unknown MCM option is locked, as ever")
MODE = "host"
tick_settings()
-- the main menu of a host: values of the machine, a note, nothing locked
IN_LEVEL = false
local dn = new_dlg()
dn:Reset_opt(PAGE, "gameplay/general")
check(DRAWN.items[1] == "desc:st_coop_opt_machine_note", "main menu: the note says these are the machine's defaults for new games")
check(DRAWN.presets ~= nil and dn.reg["gameplay/general/max_tasks/1"].enabled == true, "and nothing is locked, the presets stay")
local dn2 = new_dlg()
dn2:Reset_opt({ gr = { { id = "player_name", type = "input" } } }, "gameplay/general")
check(DRAWN.items[1] == "player_name", "a page without game options has no note")
menu.cached = nil
UIO.CacheValue(menu, "gameplay/general", "max_tasks", 9)
check(menu.cached and menu.cached[2] == 9, "main menu: edits go through")
IN_LEVEL = true

-------------------------------------------------------------------------------
section("rule_defaults_from_schema")
coop_menu_options = { build_page = function() error("the rules do not come from the options page any more") end }
local n = 0
for k, v in pairs(coop_economy_core.RULES) do
	n = n + 1
	check(cs.rule("economy/" .. k) == v, "rule economy/" .. k .. " = RULES default (" .. tostring(v) .. ")")
end
check(n == 11, "11 economy rules")
check(cs.rule("core/join_spawn") == "faction_start", "core rule join_spawn is at the faction's base (the catalog's default since F3a)")
check(cs.rule("economy/nope") == nil and cs.rule("core/client_quicksave") == nil and cs.rule("other/gather_radius") == nil and cs.rule(5) == nil,
	"unknown rules are nil")
gs.put("o", "coop/coop_session/gather_radius", "35")
cs.on_game_start()
SendScriptCallback("on_option_change")
NOW = NOW + 5000
check(cs.rule("economy/gather_radius") == 35, "a rule of the running game reads the record")
coop_menu_options = nil

-------------------------------------------------------------------------------
section("options_page_has_no_session_group")
ui_options.options = {}
function ui_options.init_opt_base() ui_options.options = { { id = "video" }, { id = "sound" } } end
local mo = load_script_file("coop_menu_options")
mo.install()
ui_options.init_opt_base()
local page
for _, t in ipairs(ui_options.options) do
	if t.id == "coop" then page = t end
end
check(page ~= nil, "the co-op page is there")
local groups = {}
for _, g in ipairs(page and page.gr or {}) do groups[#groups + 1] = g.id end
check(table.concat(groups, ",") == "coop_player", "only the player group is left (" .. table.concat(groups, ",") .. ")")
local cmds = {}
for _, g in ipairs(page and page.gr or {}) do
	for _, o in ipairs(g.gr) do
		if o.cmd and o.cmd ~= "coop_nick" and o.cmd:find("^coop_nametags") == nil then cmds[#cmds + 1] = o.cmd end
	end
end
check(#cmds == 0, "no console rule of the host is offered (" .. table.concat(cmds, ",") .. ")")
check(mo.share_entries == nil, "the helper of the removed share list is gone")

-------------------------------------------------------------------------------
section("strings")
local BS = string.char(92)
local function string_ids(lang)
	local ids = {}
	local pipe = io.popen("dir /b gamedata" .. BS .. "configs" .. BS .. "text" .. BS .. lang .. BS .. "*.xml 2>nul")
	for name in pipe:lines() do
		name = name:gsub("\r", "")
		local fh = io.open("gamedata/configs/text/" .. lang .. "/" .. name, "rb")
		if fh then
			local src = fh:read("*a")
			fh:close()
			for id in src:gmatch('<string%s+id="([^"]+)"') do ids[id] = (ids[id] or 0) + 1 end
		end
	end
	pipe:close()
	return ids
end
local need = sc.text_ids()
for _, id in ipairs({ "st_coop_opt_game_note", "st_coop_opt_machine_note", "st_coop_opt_locked_note", "st_coop_game_migrated",
	"st_coop_game_title", "st_coop_game_created_only", "st_coop_game_applies_on_load", "st_coop_game_applies_next_weather",
	"st_coop_game_saved", "st_coop_game_running", "st_coop_game_old_save", "st_coop_game_take_machine",
	"st_coop_game_take_machine_confirm", "st_coop_game_other_counts" }) do
	need[#need + 1] = id
end
for _, lang in ipairs({ "eng", "rus" }) do
	local have = string_ids(lang)
	local missing, dup = {}, {}
	for _, id in ipairs(need) do
		if not have[id] then missing[#missing + 1] = id end
	end
	for id, n in pairs(have) do
		if n > 1 and id:find("^st_coop_game_") then dup[#dup + 1] = id end
	end
	check(#need > 200 and #missing == 0, lang .. ": every id of the catalog and of the notes has a string (" .. #need .. " ids; missing: "
		.. table.concat(missing, ",") .. ")")
	check(#dup == 0, lang .. ": no id twice (" .. table.concat(dup, ",") .. ")")
end
-- the ids the two scripts name exist
for _, name in ipairs({ "coop_game_settings", "coop_settings" }) do
	local fh = assert(io.open("gamedata/scripts/" .. name .. ".script", "rb"))
	local src = fh:read("*a")
	fh:close()
	local have, absent = string_ids("eng"), {}
	for id in src:gmatch('"(st_coop_[%w_]+)"') do
		if id:sub(-1) ~= "_" and not have[id] then absent[#absent + 1] = id end
	end
	check(#absent == 0, name .. ": the string ids it names exist (" .. table.concat(absent, ",") .. ")")
end

-------------------------------------------------------------------------------
section("status")
check(type(gs.status_line()) == "string" and gs.status_line():find(S1.id, 1, true) ~= nil, "status_line names the game")
check(pcall(cs.print_status) and pcall(gs.print_status), "the status lines print")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
