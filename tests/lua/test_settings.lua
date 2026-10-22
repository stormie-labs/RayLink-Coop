-- Anomaly Coop temp test: coop_settings.script host/client sync, overlay, refusals, stash, chunking (W3d).
-- Host and client run as two isolated "worlds" (own globals, own ini_file_ex class) in one LuaJIT state.
MODE = "host"
dofile("tests/lua/support/stubs.lua")
load_coop_main() -- real encode/decode
local ENCODE, DECODE = coop_main.encode, coop_main.decode
print("== settings")

-- luabind-like class: methods are looked up on the class at call time, so patched methods reach old instances
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
			v = v == nil and def or v == "true" or false
		elseif typ == 2 then
			v = tonumber(v) or def
		end
		self.cache[s .. "&" .. k] = v
		return v == nil and def or v
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
	return cls
end

local OPT_DEFS = {
	["gameplay/general/max_tasks"] = { val = 2, def = 2 },
	["gameplay/general/npc_loot_distance"] = { val = 2, def = 5 },
	["video/basic/fov"] = { val = 2, def = 75 },
	["alife/event/emission_state"] = { val = 1, def = true },
}
local MCM_DEFS = { ["my_mod/general/loot_mult"] = 1, ["my_mod/hud/show_icons"] = true, ["other_mod/drop_chance"] = 0.5,
	["my_mod/general/key_heal"] = 33 }

local function make_world(role, options, mcm, factors)
	local W = setmetatable({}, { __index = _G })
	W._G = W
	W.ROLE = role
	W.LIVE = true
	W.NOW = 100000
	W.SENT, W.STASH, W.handlers, W.cbs, W.CMDS = {}, {}, {}, {}, {}
	W.coop = {
		is_active = function() return W.ROLE ~= "off" end,
		is_host = function() return W.ROLE == "host" end,
		is_client = function() return W.ROLE == "client" end,
		is_live = function() return W.ROLE ~= "off" and W.LIVE end,
		players = function()
			return { { id = 0, nick = "host", is_self = role == "host" }, { id = 1, nick = "cl", is_self = role == "client" } }
		end,
		send_event = function(name, payload, target)
			if #payload > 16384 then return false, "payload is larger than 16 KiB" end
			W.SENT[#W.SENT + 1] = { name = name, payload = payload, target = target }
			return true
		end,
		stash_set = function(k, v) W.STASH[k] = v; return true end,
		stash_get = function(k) return W.STASH[k] end,
	}
	W.coop_main = {
		encode = ENCODE, decode = DECODE,
		add_event_handler = function(n, f) W.handlers[n] = f end,
	}
	W.time_global = function() return W.NOW end
	W.RegisterScriptCallback = function(n, f) W.cbs[n] = W.cbs[n] or {}; table.insert(W.cbs[n], f) end
	W.SendScriptCallback = function(n, ...)
		W.FIRED = (W.FIRED or 0) + (n == "on_option_change" and 1 or 0)
		for _, f in ipairs(W.cbs[n] or {}) do f(...) end
	end
	W.actor_menu = { set_msg = function(_, t) W.MSG = t end }
	W.db = { actor = {} }
	W.ini_file_ex = new_ini_class()
	W.axr_main = { config = W.ini_file_ex.new({ options = options, mcm = mcm }) }
	local cfg = W.axr_main.config
	W.ui_options = {
		get = function(id)
			local v = OPT_DEFS[id]
			local value = cfg:r_value("options", id, v and v.val)
			if value ~= nil then return value end
			value = v and v.def
			cfg:w_value("options", id, value)
			cfg:save()
			return value
		end,
		set = function(id, value) cfg:w_value("options", id, value); cfg:save() end,
		check_opt_table = function(id) return OPT_DEFS[id] ~= nil end,
		get_opt_table = function(id) return OPT_DEFS[id] or {} end,
	}
	local UIO = {}
	function UIO.CacheValue(self, path, opt, value, v) self.cached = { path .. "/" .. opt, value } end
	function UIO.Update(self) self.updates = (self.updates or 0) + 1 end
	function UIO.Reset_opt(self, tree, path) self.redraws = (self.redraws or 0) + 1 end
	W.ui_options.UIOptions = UIO
	W.new_menu = function()
		local o = { last_curr_tree = {}, last_path = "gameplay/general" }
		o.pending = { SetText = function(_, t) o.hint = t end }
		return setmetatable(o, { __index = function(_, k) return UIO[k] end })
	end
	W.ui_mcm = {
		get = function(id)
			local def = MCM_DEFS[id]
			local typ = type(def) == "boolean" and 1 or type(def) == "number" and 2 or 0
			local v = cfg:r_value("mcm", id, typ)
			if v == nil then return def end
			return v
		end,
		set = function(id, v) cfg:w_value("mcm", id, v) end,
	}
	W.GIVE = 0
	W.give_info = function() W.GIVE = W.GIVE + 1 end
	local gameplay, eco = factors.g, factors.e
	W.game_difficulties = {
		get_game_factor = function(k) return gameplay[k] end,
		get_eco_factor = function(k) return eco[k] end,
		set_game_factor = function(k, v)
			if gameplay[k] ~= v then W.give_info("diff_gameplay_flag_change") end
			gameplay[k] = v
			W.CMDS[#W.CMDS + 1] = "g:" .. k
		end,
		set_eco_factor = function(k, v)
			if eco[k] ~= v then W.give_info("diff_economy_flag_change") end
			eco[k] = v
			W.CMDS[#W.CMDS + 1] = "e:" .. k
		end,
	}
	W.STATE = { diff_game = { addon_factor = true }, diff_eco = {}, trader_buy_condition_override = factors.tbco }
	W.alife_storage_manager = { get_state = function() return W.STATE end }
	return W
end

local function load_module(W, name)
	local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "r"))
	local src = fh:read("*a")
	fh:close()
	local header = 'local this = {} ' .. name .. ' = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	local f = assert(loadstring(header .. src, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. name .. ".script"))
	setfenv(f, W)
	f()
	return W[name]
end

-- deliver events sent by `from_w` (peer id from_id) to `to_w`, for those addressed to to_id
local function deliver(from_w, from_id, to_w, to_id)
	local n = 0
	local list = from_w.SENT
	from_w.SENT = {}
	for _, e in ipairs(list) do
		if e.target == -1 or e.target == to_id then
			local h = to_w.handlers[e.name]
			if h then h(e.payload, from_id, e.name) end
			n = n + 1
		end
	end
	return n
end

local function tick(W, ms)
	W.NOW = W.NOW + (ms or 300)
	for _, f in ipairs(W.cbs["actor_on_update"] or {}) do f() end
end

-- host world
local H = make_world("host",
	{ ["gameplay/general/max_tasks"] = "5", ["video/basic/fov"] = "80", ["alife/event/emission_state"] = "false" },
	{ ["my_mod/general/loot_mult"] = "2", ["my_mod/hud/show_icons"] = "true", ["unknown_mod/opt"] = "x",
		["my_mod/general/key_heal"] = "44" },
	{ g = { type = 2, hit_power = 2, thirst = false, addon_factor = 7 }, e = { type = 2, buy = 1.5 }, tbco = 40 })
-- client world (its own axr_options.ltx)
local Cl = make_world("client",
	{ ["gameplay/general/max_tasks"] = "2", ["video/basic/fov"] = "65", ["gameplay/general/npc_loot_distance"] = "10",
		["alife/event/emission_state"] = "true" },
	{ ["my_mod/general/loot_mult"] = "1", ["my_mod/hud/show_icons"] = "false", ["other_mod/drop_chance"] = "0.3",
		["my_mod/general/key_heal"] = "55" },
	{ g = { type = 1, hit_power = 1, thirst = true }, e = { type = 1, buy = 1 } })

local hs = load_module(H, "coop_settings")
local cs = load_module(Cl, "coop_settings")
hs.on_game_start()
cs.on_game_start()

-- classification
check(hs.owner_of("options", "gameplay/general/max_tasks") == "host", "stock gameplay option is host-owned")
check(hs.owner_of("options", "gameplay/general/player_name") == "player", "player name stays per player")
check(hs.owner_of("options", "video/basic/fov") == "player", "video option is per player")
check(hs.owner_of("options", "video/weather/rain_period") == "host", "weather generation is host-owned")
check(hs.owner_of("options", "control/general/mouse_sens") == "player", "controls are per player")
check(hs.owner_of("mcm", "my_mod/general/loot_mult") == "host", "MCM loot multiplier is host-owned (word)")
check(hs.owner_of("mcm", "my_mod/hud/show_icons") == "player", "MCM hud option is per player (word)")
check(hs.owner_of("mcm", "unknown_mod/opt") == "host", "unknown MCM option defaults to host")
check(hs.owner_of("mcm", "my_mod/general/key_heal") == "player", "MCM key binding is per player even with a gameplay word")
check(hs.owner_of("mcm", "my_mod/hud_damage_mult") == "host", "gameplay word wins over a cosmetic word")
check(hs.owner_of("mcm", "aim_assist/ai_aim") == "host", "short word must match a whole word (ai)")
check(hs.owner_of("mcm", "x/aim_hud") == "player", "'ai' does not match 'aim'")

-- before the snapshot the client uses its own values; writes of host-owned keys are already refused
check(Cl.ui_options.get("gameplay/general/max_tasks") == 2, "client reads own value before the host's arrive")
Cl.ui_options.set("gameplay/general/max_tasks", 9)
check(Cl.axr_main.config.data.options["gameplay/general/max_tasks"] == "2", "client cannot write a host-owned option")
check(Cl.axr_main.config.saves == 0, "save after a dropped write is skipped")
Cl.ui_options.set("video/basic/fov", 90)
check(Cl.axr_main.config.data.options["video/basic/fov"] == "90" and Cl.axr_main.config.saves == 1,
	"client writes and saves its own cosmetic option")

-- client asks, host answers with the full snapshot
tick(Cl)
check(#Cl.SENT == 1 and Cl.SENT[1].name == "coop_set_req" and Cl.SENT[1].target == 0, "client asks for host settings")
deliver(Cl, 1, H, 0)
check(#H.SENT >= 1 and H.SENT[1].name == "coop_set" and H.SENT[1].target == 1, "host answers the asking client")
local first = DECODE(H.SENT[1].payload)
check(first._t == "full" and first["o|gameplay/general/max_tasks"] == "5" and first["o|video/basic/fov"] == nil,
	"full snapshot holds host-owned stock options only")
check(first["m|my_mod/hud/show_icons"] == nil and first["m|my_mod/general/key_heal"] == nil and
	first["m|unknown_mod/opt"] == "x", "full snapshot holds host-owned MCM options only")
check(first["g|hit_power"] == 2 and first["e|buy"] == 1.5 and first["g|thirst"] == false and first["g|addon_factor"] == 7,
	"difficulty factors (incl. addon keys from the save) are in the snapshot")
Cl.FIRED = 0
deliver(H, 0, Cl, 1)

check(Cl.ui_options.get("gameplay/general/max_tasks") == 5, "client reads the host's stock option")
check(Cl.ui_options.get("video/basic/fov") == 90, "client keeps its own cosmetic option")
check(Cl.ui_options.get("alife/event/emission_state") == false, "boolean host option converted")
check(Cl.ui_options.get("gameplay/general/npc_loot_distance") == 5, "host-owned key absent on host -> stock default, not own 10")
check(Cl.ui_mcm.get("my_mod/general/loot_mult") == 2, "client reads the host's MCM option")
check(Cl.ui_mcm.get("my_mod/hud/show_icons") == false, "client keeps its own cosmetic MCM option")
check(Cl.ui_mcm.get("other_mod/drop_chance") == 0.5, "host-owned MCM key absent on host -> addon default, not own 0.3")
check(Cl.ui_mcm.get("my_mod/general/key_heal") == 55, "client keeps its own MCM key binding")
check(Cl.axr_main.config.data.options["gameplay/general/max_tasks"] == "2", "client's axr_options.ltx is untouched")
check(Cl.game_difficulties.get_game_factor("hit_power") == 2 and Cl.game_difficulties.get_eco_factor("buy") == 1.5
	and Cl.game_difficulties.get_game_factor("thirst") == false, "client difficulty factors follow the host")
check(Cl.CMDS[1] == "g:type", "difficulty type is applied first")
check(Cl.STATE.trader_buy_condition_override == 40, "trader buy condition (save storage) follows the host")
check(Cl.GIVE == 0, "no info portion given on the client while applying")
check(Cl.give_info ~= nil and Cl.FIRED == 1, "give_info restored, on_option_change fired once")
check(Cl.STASH.coop_settings ~= nil, "host settings stashed for level loads")

-- client edits are refused
check(Cl.game_difficulties.set_game_factor("hit_power", 3) == nil and Cl.game_difficulties.get_game_factor("hit_power") == 2,
	"client cannot change a difficulty factor")
local menu = Cl.new_menu()
Cl.ui_options.UIOptions.CacheValue(menu, "gameplay/general", "max_tasks", 7, {})
check(menu.cached[2] == nil and menu.coop_redraw == true, "options menu: host-owned edit not cached")
Cl.ui_options.UIOptions.Update(menu)
check(menu.redraws == 1 and menu.hint and menu.hint:find("set by the host"), "options menu redrawn with a hint")
Cl.ui_options.UIOptions.CacheValue(menu, "video/basic", "fov", 100, {})
check(menu.cached[2] == 100, "options menu: cosmetic edit cached normally")
Cl.ui_mcm.set("my_mod/general/loot_mult", 9)
check(Cl.axr_main.config.data.mcm["my_mod/general/loot_mult"] == "1", "ui_mcm.set of host-owned refused")

-- host changes options: delta
H.axr_main.config:w_value("options", "gameplay/general/max_tasks", 8)
H.axr_main.config:w_value("mcm", "unknown_mod/opt", nil)
H.axr_main.config.data.mcm["unknown_mod/opt"] = nil
H.axr_main.config:w_value("options", "video/basic/fov", 95) -- cosmetic: no delta for it
H.SendScriptCallback("on_option_change")
tick(H)
check(#H.SENT == 1 and H.SENT[1].target == -1, "host broadcasts a delta")
local d = DECODE(H.SENT[1].payload)
check(d._t == "delta" and d["o|gameplay/general/max_tasks"] == "8" and d["x|m|unknown_mod/opt"] == true
	and d["o|video/basic/fov"] == nil, "delta content: change + removal, no cosmetic")
Cl.FIRED = 0
deliver(H, 0, Cl, 1)
check(Cl.ui_options.get("gameplay/general/max_tasks") == 8, "client follows the host's change")
check(Cl.FIRED == 1, "on_option_change fired on the client after the delta")
tick(H, 4000)
check(#H.SENT == 0, "no delta when nothing changed")

-- level load: a new Lua state on the client restores from the stash before any network message
local C2 = make_world("client", { ["gameplay/general/max_tasks"] = "2" }, {}, { g = {}, e = {} })
C2.STASH = Cl.STASH
local cs2 = load_module(C2, "coop_settings")
check(C2.ui_options.get("gameplay/general/max_tasks") == 8, "stash restores the host's values at load time")
cs2.on_game_start()
tick(C2)
check(C2.game_difficulties.get_game_factor("hit_power") == 2, "stashed difficulty applied on the first update")

-- session ends: own values are back
Cl.ROLE = "off"
Cl.FIRED = 0
tick(Cl)
check(Cl.ui_options.get("gameplay/general/max_tasks") == 2, "after the session the client's own value is back")
check(Cl.FIRED == 1, "on_option_change fired when the session ended")

-- chunking: a big MCM set is split below 16 KiB and reassembled
local big = {}
for i = 1, 3000 do big[string.format("big_mod/page_%d/loot_value_%d", i % 7, i)] = tostring(i * 1.5) end
local H3 = make_world("host", {}, big, { g = { hit_power = 1 }, e = {} })
local C3 = make_world("client", {}, {}, { g = {}, e = {} })
local hs3 = load_module(H3, "coop_settings")
load_module(C3, "coop_settings")
hs3.on_game_start()
C3.coop_settings.on_game_start()
tick(C3)
deliver(C3, 1, H3, 0)
local maxlen, chunks = 0, #H3.SENT
for _, e in ipairs(H3.SENT) do if #e.payload > maxlen then maxlen = #e.payload end end
check(chunks > 1 and maxlen <= 15100, string.format("big snapshot split into %d chunks, largest %d bytes", chunks, maxlen))
deliver(H3, 0, C3, 1)

check(C3.coop_settings.host_value("mcm", "big_mod/page_3/loot_value_10") == "15", "all chunks applied")
local n = 0
for k in pairs(big) do if C3.coop_settings.host_value("mcm", k) == big[k] then n = n + 1 end end
check(n == 3000, "3000 of 3000 MCM values arrived")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
