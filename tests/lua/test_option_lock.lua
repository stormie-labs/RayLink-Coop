-- Anomaly Coop temp test (W4 menu): option lock of coop_settings.script on a client (port of xrRazom's
-- xrr_ui_option_lock) and the classification of the co-op options page / MCM seed list. Not shipped.
dofile("tests/lua/support/menu_stubs.lua")

ROLE = "client"
coop = {
	is_active = function() return ROLE ~= "off" end,
	is_host = function() return ROLE == "host" end,
	is_client = function() return ROLE == "client" end,
	is_live = function() return ROLE ~= "off" end,
	send_event = function() return true end,
	stash_get = function() return nil end,
	stash_set = function() return true end,
	players = function() return {} end,
}
coop_main = { encode = function() return "" end, decode = function() return {} end, add_event_handler = function() end }
function ini_file(name) return ini_over(ROOT .. "configs/" .. name) end
-- luabind-like ini_file_ex class (methods looked up at call time)
ini_file_ex = {}
local ini_mt = { __index = function(_, k) return ini_file_ex[k] end }
function ini_file_ex.r_value(self, s, k, typ, def) return def end
function ini_file_ex.w_value() end
function ini_file_ex.save() end
axr_main = { config = setmetatable({}, ini_mt) }
CB = {}
function RegisterScriptCallback(n, f) CB[n] = f end
function SendScriptCallback() end
actor_menu = { set_msg = function() end }
db = {}

-- UIOptions stand-in: Reset_opt draws like the stock one (every control through self:Register, tracks in _Track)
local UIO = {}
function UIO.Register(self, ctrl, id) self.reg = self.reg or {}; self.reg[id] = ctrl end
function UIO.CacheValue() end
function UIO.Update() end
DRAWN = nil
function UIO.Reset_opt(self, tree, path, flags)
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
ui_options = { UIOptions = UIO }
local function new_dlg() return setmetatable({}, { __index = function(_, k) return UIO[k] end }) end

local s = load_module("coop_settings")
s.on_game_start()

print("== classification")
check(s.owner_of("options", "coop/coop_player/nick") == "player", "co-op page: player group is the player's")
check(s.owner_of("options", "coop/coop_player/host_port") == "player", "hosting port is the player's")
check(s.owner_of("options", "coop/coop_session/death_mode") == "host", "session rules are the host's")
check(s.owner_of("mcm", "drx_da/anomaly_density") == "host", "MCM seed: drx_da is the host's")
check(s.owner_of("mcm", "drx_da/debug_mode") == "player", "MCM seed: drx_da debug is the player's")
check(s.owner_of("mcm", "fftd/gen/show_distdur") == "player", "MCM seed: fftd UI key is the player's")
check(s.owner_of("mcm", "fftd/gen/cost_mult") == "host", "MCM seed: fftd rules are the host's")
check(s.owner_of("mcm", "auto_looter/delete_body") == "host", "auto_looter delete is the host's")
check(s.owner_of("mcm", "auto_looter/pickup_ammo") == "player", "auto_looter pickup is the player's")
check(s.owner_of("mcm", "body_health_system/TEXT_BASED_PATCH") == "player", "case-insensitive exact path")

print("== lock on a client")
local tree = { presets = { "p1" }, gr = {
	{ id = "slide", type = "slide" },
	{ id = "max_tasks", type = "track", val = 2 },
	{ id = "player_name", type = "input", val = 0 },
	{ id = "npc_loot", type = "check", val = 1 },
} }
local dlg = new_dlg()
dlg:Reset_opt(tree, "gameplay/general")
check(DRAWN.items[1] == "desc:st_coop_opt_locked_note", "note on top of a page with host-owned options")
check(DRAWN.presets == nil and tree.presets[1] == "p1", "presets hidden for the render, restored after")
check(#tree.gr == 4 and tree.gr[1].id == "slide", "shared tree restored")
check(dlg.reg["gameplay/general/max_tasks/1"].enabled == false and dlg._Track["gameplay/general/max_tasks"].ctrl.enabled == false,
	"host-owned track disabled")
check(dlg.reg["gameplay/general/npc_loot/1"].enabled == false, "host-owned check disabled")
check(dlg.reg["gameplay/general/player_name/1"].enabled == true, "player-owned option stays editable")
check(rawget(dlg, "Register") == UIO.Register, "Register shadow removed")
local co = { gr = { { id = "nick", type = "input" }, { id = "host_port", type = "input" } } }
dlg:Reset_opt(co, "coop/coop_player")
check(DRAWN.items[1] == "nick" and dlg.reg["coop/coop_player/nick/1"].enabled, "co-op player page: no lock")
local cs = { gr = { { id = "note", type = "desc", text = "st_coop_opt_session_note" }, { id = "friendly_fire", type = "check" } } }
dlg:Reset_opt(cs, "coop/coop_session")
check(DRAWN.items[1] == "desc:st_coop_opt_locked_note" and dlg.reg["coop/coop_session/friendly_fire/1"].enabled == false,
	"co-op session rules locked on a client")

print("== no lock outside a client session")
ROLE = "off"
CB.actor_on_update()
local dlg2 = new_dlg()
dlg2:Reset_opt(tree, "gameplay/general")
check(DRAWN.items[1] == "slide" and DRAWN.presets ~= nil and dlg2.reg["gameplay/general/max_tasks/1"].enabled,
	"session over: stock page")

print(string.format("%d passed, %d failed", PASSES, FAILS))
