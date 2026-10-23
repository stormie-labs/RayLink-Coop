-- Anomaly Coop temp test (W4 menu): option lock of coop_settings.script on a client (port of xrRazom's
-- xrr_ui_option_lock) and the classification of the co-op options page / MCM seed list. Not shipped.
-- Game settings (T4): the host's side of the same classification (is_game_owned, Ruling GS-1) and the note of the main
-- menu; the host's lock in the game with a record is in test_game_settings.
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
IN_LEVEL = true
level = { present = function() return IN_LEVEL end }

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

-- Ruling GS-1: the game owns what the explicit host lists name; "host" only by default is the client's rule, not the game's
check(s.is_game_owned("mcm", "drx_da/anomaly_density") == true, "game-owned: a [mcm_host] prefix")
check(s.is_game_owned("mcm", "auto_looter/delete_body") == true, "game-owned: an exact [mcm_host] path")
check(s.is_game_owned("mcm", "some_new_addon/some_option") == false and s.owner_of("mcm", "some_new_addon/some_option") == "host",
	"not game-owned: an unknown addon (host for a client by default)")
check(s.is_game_owned("mcm", "my_mod/hud_damage_mult") == false and s.owner_of("mcm", "my_mod/hud_damage_mult") == "host",
	"not game-owned: host by a word of the path only")
check(s.is_game_owned("mcm", "drx_da/debug_mode") == false, "not game-owned: [mcm_player]")
check(s.is_game_owned("options", "gameplay/general/max_tasks") == true and s.is_game_owned("options", "video/weather/rain_period") == true
	and s.is_game_owned("options", "coop/coop_session/gather_radius") == true, "game-owned: the stock host groups and the co-op rules")
check(s.is_game_owned("options", "video/basic/fov") == false and s.is_game_owned("options", "gameplay/general/player_name") == false,
	"not game-owned: player options")

-- the cosmetic addons are the player's by an explicit list (Game settings T4: a client keeps its own shaders and animations),
-- Zone Customization Project is the host's by a list, with the exceptions that are only seen
check(s.owner_of("mcm", "ssfx_module/ssfx_wetness/ssfx_gloss/min_gloss_mcm") == "player" and s.is_game_owned("mcm", "ssfx_module/ssfx_ao/ssfx_ao/quality") == false,
	"cosmetic: Screen Space Shaders are the player's")
for _, path in ipairs({ "item_icon_info/cond_text/alt_artefact_pos", "targetID/deadID", "laser_settings/dist_bright", "fddar/anim_x",
	"liz_inex/inertia", "EFT_ADS/ads_speed", "oleh_sounds/volume_x", "varefined/varefined_main/enable_on_kill_shouts", "sidhud/radhealthshow",
	"scop/fov_x", "3d_scopes/opt", "beef_nvg/opt" }) do
	check(s.owner_of("mcm", path) == "player", "cosmetic: " .. path .. " is the player's")
end
check(s.owner_of("mcm", "SMR/smr_mutants/anything") == "host" and s.is_game_owned("mcm", "SMR/smr_mutants/anything") == true,
	"SMR/* is the game's by the list")
check(s.owner_of("mcm", "SMR/smr_loot/send_message") == "player" and s.owner_of("mcm", "SMR/smr_amain/smr_debug_log") == "player"
	and s.owner_of("mcm", "SMR/smr_amain/glitched_pda") == "player", "SMR: the options that are only seen stay the player's (exact beats the prefix)")
check(s.is_game_owned("mcm", "stealth/memory") == false and s.owner_of("mcm", "stealth/memory") == "host",
	"an addon nobody listed (stealth) is not touched: the host's by a word, not the game's")

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
	"session over, still in the world (no record of a game): stock page")

print("== the main menu of a machine with the co-op exe: a note, no lock")
IN_LEVEL = false
local dlg3 = new_dlg()
dlg3:Reset_opt(tree, "gameplay/general")
check(DRAWN.items[1] == "desc:st_coop_opt_machine_note" and DRAWN.presets ~= nil and dlg3.reg["gameplay/general/max_tasks/1"].enabled,
	"main menu: the page says these are the machine's defaults for new games, nothing is disabled")
check(#tree.gr == 4 and tree.gr[1].id == "slide", "shared tree restored")
local dlg4 = new_dlg()
dlg4:Reset_opt(co, "coop/coop_player")
check(DRAWN.items[1] == "nick", "main menu: the player's page has no note")
IN_LEVEL = true

print(string.format("%d passed, %d failed", PASSES, FAILS))
