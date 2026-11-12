-- Anomaly Coop test (the operator of a world server changes the rules of the running world, plan 2026-11-12 s.2.4):
--   server: coop_game_settings.operator_set(key, raw, peer), called by coop_dedicated.cpp run_for for "coop_game_set <key> <raw>";
--   client: coop_settings.operator_set(key, value) sends the line, the options window routes an edit of a rule there, the answer
--   (coop_core_chat on_op_answer -> coop_settings.on_operator_answer) is shown; the line every catalog key/value makes passes the
--   rules of op::allowed (coop_operator.h). The stand-ins are those of test_game_settings.lua. Not shipped.
-- Run: tools\test_lua.cmd operator_settings
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
		return true
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
	coop_death_share = "100.00000", coop_split_levels = "1", coop_story_together = "1", coop_npc_finish_downed = "0",
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
load_script_file("coop_json_card")
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
section("the server: coop_game_settings.operator_set")
reset_disk()
fresh_machine()
local REC = make_record({})
check(gs.stage_new(REC) == true, "a world with its record")
gs.before_world_start("new", "")
first_update()
check(type(gs.operator_set) == "function", "coop_game_settings.operator_set is there")
SendScriptCallback("actor_on_update") -- coop_settings: the host's baseline
NOW = NOW + 5000
SendScriptCallback("actor_on_update")
local rev0 = gs.active().rev
OPTION_CHANGES = 0
SENT = {}
local ok, text = gs.operator_set("o|alife/event/emission_frequency", "48", 1)
check(ok == true and gs.value("o", "alife/event/emission_frequency") == "48", "a value of an option's list goes into the record")
check(type(text) == "string" and text:find("o|alife/event/emission_frequency", 1, true) and text:find("48", 1, true),
	"the answer names the key and the new value")
check(gs.active().rev == rev0 + 1, "the record's rev goes up: the change outlives a restart")
check(card_of(REC.id) and card_of(REC.id).values["o|alife/event/emission_frequency"] == "48", "the card has it at once")
check(OPTION_CHANGES >= 1, "the server's scripts hear on_option_change, as after a change of the host's")
NOW = NOW + 300
SendScriptCallback("actor_on_update")
local told = false
for _, s in ipairs(SENT) do
	if s.name == "coop_set" and s.payload:find("emission_frequency", 1, true) and s.payload:find("48", 1, true) then told = true end
end
check(told, "the players are told (coop_set delta)")

ok = gs.operator_set("c|coop_revive_health", "0.50", 1)
check(ok == true and gs.active().values["c|coop_revive_health"] == "0.5" and GAME.cvars and GAME.cvars.coop_revive_health == "0.5",
	"a console rule: canonical in the record and set in the engine's layer")
ok = gs.operator_set("c|coop_friendly_fire", "off", 1)
check(ok == true and gs.active().values["c|coop_friendly_fire"] == "0", "a console flag: 1 / 0")
ok = gs.operator_set("o|alife/event/emission_state", "FALSE", 1)
check(ok == true and gs.value("o", "alife/event/emission_state") == "false", "an option flag: true / false")

local function refused(key, raw, what)
	local before = gs.active().values[key]
	local rev = gs.active().rev
	local good, why = gs.operator_set(key, raw, 1)
	check(good == false and type(why) == "string" and why ~= "" and gs.active().values[key] == before and gs.active().rev == rev, what)
	return why or ""
end
local why = refused("o|gameplay/none", "1", "a key outside the catalog is refused")
check(not why:find("%", 1, true), "a reason is plain text")
refused("c|coop_death_mode", "hardcore", "a rule set when the world was created is refused")
refused("c|coop_world_server", "1", "the world's mode too")
refused("faction", "monolith", "and the world's faction")
refused("o|alife/event/emission_frequency", "37", "a number in the range but not a value of the list is refused")
refused("c|coop_bleedout", "abc", "a value that is no number is refused")
refused("o|coop/coop_session/join_spawn", "anywhere", "a word that is not in the list is refused")
refused("g|hit_power", "1", "a difficulty factor is not a catalog item: refused")
check(gs.operator_set(nil, nil, 1) == false, "nothing at all is refused, not an error")

-------------------------------------------------------------------------------
section("every catalog line passes op::allowed (coop_operator.h, mirrored)")
-- op::allowed for coop_game_set: 1..1024 bytes, no control character, DEL or ';', no blank at an end, single blanks, two words or
-- more, the key 1..128 characters of [A-Za-z0-9_.|/-]
local function allowed(line)
	if #line == 0 or #line > 1024 or line:sub(1, 1) == " " or line:sub(-1) == " " then return false end
	if line:find("[%z\1-\31\127;]") or line:find("  ", 1, true) then return false end
	local key, value = line:match("^coop_game_set ([^ ]+) (.+)$")
	if not key or #key > 128 or key:find("[^%w_%.|/%-]") then return false end
	return value ~= nil
end
local bad = {}
for _, key in ipairs(sc.keys()) do
	if sc.editable(key, true) then
		for _, e in ipairs(sc.item(key).values) do
			local raw = sc.to_raw(key, e[1])
			if not (raw and allowed("coop_game_set " .. key .. " " .. raw)) then bad[#bad + 1] = key .. "=" .. tostring(raw) end
			local good = gs.operator_set(key, raw, 1)
			if not good then bad[#bad + 1] = "server:" .. key .. "=" .. tostring(raw) end
		end
	end
end
check(#bad == 0, "every value of every rule the operator may change is a line the server takes (" .. table.concat(bad, " ") .. ")")

-------------------------------------------------------------------------------
section("the operator: coop_settings.operator_set and the options window")
OPS, OP_RESULT = {}, true
coop.operator_command = function(line)
	OPS[#OPS + 1] = line
	if OP_RESULT == true then return true end
	return false, OP_RESULT
end
RIGHTS = true
coop.has_host_rights = function() return RIGHTS end
MODE = "client"
NOW = NOW + 1000
SendScriptCallback("actor_on_update") -- coop_settings sees the client
check(type(cs.operator_set) == "function" and cs.is_operator() == true, "the operator is known")
ok = cs.operator_set("o|alife/event/emission_frequency", 96)
check(ok == true and OPS[#OPS] == "coop_game_set o|alife/event/emission_frequency 96", "a rule goes to the server as its line")
ok = cs.operator_set("c|coop_revive_health", 0.75)
check(ok == true and OPS[#OPS] == "coop_game_set c|coop_revive_health 0.75", "canonical raw text")
ok = cs.operator_set("o|alife/event/emission_state", true)
check(ok == true and OPS[#OPS] == "coop_game_set o|alife/event/emission_state true", "a flag")
local n = #OPS
ok, why = cs.operator_set("c|coop_death_mode", "hardcore")
check(ok == false and #OPS == n, "a rule of the world's creation is not even sent")
ok = cs.operator_set("o|alife/event/emission_frequency", 37)
check(ok == false and #OPS == n, "nor a value outside the list")
ok = cs.operator_set("o|alife/event/emission_frequency", "48;quit")
check(ok == false and #OPS == n, "nor a text that is no value")
OP_RESULT = "not the operator"
ok, why = cs.operator_set("o|alife/event/emission_frequency", 48)
check(ok == false and why == "not the operator", "the engine's refusal comes back")
OP_RESULT = true
RIGHTS = false
n = #OPS
ok = cs.operator_set("o|alife/event/emission_frequency", 48)
check(ok == false and #OPS == n and cs.is_operator() == false, "a client without the rights sends nothing")
RIGHTS = true

-- the options window: an edit of a rule of the catalog goes to the server, the window keeps the value it had
local dlg = new_dlg(UIO)
n = #OPS
dlg:CacheValue("alife/event", "emission_frequency", 12, nil)
check(OPS[#OPS] == "coop_game_set o|alife/event/emission_frequency 12", "the options window: the edit goes to the server")
check(dlg.cached and dlg.cached[2] == nil, "and is not taken here until the server's settings come back")
n = #OPS
dlg:CacheValue("gameplay/general", "max_tasks", 7, nil)
check(#OPS == n and dlg.cached[2] == nil, "a host-owned option that is not a rule of the catalog stays refused")
RIGHTS = false
dlg:CacheValue("alife/event", "emission_frequency", 48, nil)
check(#OPS == n and dlg.cached[2] == nil, "a client without the rights: refused as before")
RIGHTS = true

-- the answer
LOG = {}
check(cs.on_operator_answer(false, { "! [coop] coop_game_set: refused: not a value of o|alife/event/emission_frequency" }) == true,
	"the answer to a change is taken")
local said = table.concat(LOG, "\n")
check(said:find("not a value of", 1, true) ~= nil, "a refusal is shown with its reason")
LOG = {}
cs.on_operator_answer(true, { "[coop] coop_game_set: o|alife/event/emission_frequency = 12" })
check(table.concat(LOG, "\n"):find("= 12", 1, true) ~= nil, "a change is shown as the server's")
MODE = "host"
coop.has_host_rights, coop.operator_command = nil, nil

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
