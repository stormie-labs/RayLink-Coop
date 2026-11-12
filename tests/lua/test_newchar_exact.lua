-- Anomaly Coop test (plan 2026-11-12 stage 5): the creator's character of a world staged from coop_new_world.ltx. The engine
-- (coop_join.cpp host_make_creator) passes exact = true to coop_menu_char.host_plan_character / host_make_character: no points check, exactly
-- the record's loadout (sections that do not exist skipped with a log line) with the ammo of its weapons, the record's money, his start map
-- when it is a start of the world's faction, the "new" mark cleared. Not shipped. Run: tools\test_lua.cmd newchar_exact
dofile("tests/lua/support/menu_stubs.lua")
dofile("tests/lua/support/stubs.d/money.lua")

game = { translate_string = function(id) return id end }
coop_menu = { tr = function(id) return id end }
function ini_file(name)
	if name == "plugins\\new_game_start_locations.ltx" then return ini_over(REF .. "configs/plugins/new_game_start_locations.ltx") end
	assert(name == "items\\settings\\new_game_loadouts.ltx", name)
	return ini_over(REF .. "configs/items/settings/new_game_loadouts.ltx")
end
ini_sys = ini_table({})
local WEAPONS = {
	wpn_pm = { ammo_class = "ammo_9x18_fmj", slot = 1 },
	wpn_ak74_old = { ammo_class = "ammo_5.45x39_fmj", slot = 2 },
	ammo_9x18_fmj = { box_size = 50 },
	["ammo_5.45x39_fmj"] = { box_size = 30 },
}
function ini_sys:section_exist(s) return s ~= "no_such_item" end
function ini_sys:r_string_ex(s, k) local w = WEAPONS[s]; local v = w and w[k]; return v ~= nil and tostring(v) or nil end
function ini_sys:r_float_ex(s, k) local w = WEAPONS[s]; return w and tonumber(w[k]) end

WORLD = "bandit"
coop_game_settings = { world_faction = function() return WORLD end, value = function() return nil end }
CREATOR = nil
coop_dedicated = { creator = function() return CREATOR end }

PLAYERS = { { id = 0, nick = "server", is_self = true }, { id = 1, nick = "Strelok", avatar_id = 900 } }
coop = {
	is_active = function() return true end,
	is_host = function() return true end,
	is_world_server = function() return true end,
	is_player = function() return false end,
	is_dedicated = function() return true end,
	players = function() return PLAYERS end,
	send_event = function() return true end,
	game = { world_faction = function() return "" end },
}
install_money_stubs(coop, { is_host = function() return true end })
coop_main = { handlers = {} }
function coop_main.encode(t) return t end
function coop_main.decode(s) return s end
function coop_main.add_event_handler(n, f) coop_main.handlers[n] = f; return true end
SE = {}
function se_save_var(id, name, var, val) SE[id] = SE[id] or {}; SE[id][var] = val end
function se_load_var(id, name, var) return SE[id] and SE[id][var] end
CREATED = {}
function alife_create_item(sec, se, t) CREATED[#CREATED + 1] = { sec = sec, parent = se.id, ammo = t and t.ammo }; return { id = 9000 + #CREATED } end
SE_OBJ = { [900] = { id = 900 } }
function alife_object(id) return SE_OBJ[id] end
level = { object_by_id = function() return nil end, present = function() return false end }
ECO = 1
game_difficulties = { get_eco_factor = function(k) return k == "type" and ECO or nil end }
db = { actor = { give_game_news = function() end } }
function RegisterScriptCallback() end
function AddScriptCallback() end
axr_main = { config = config_stub() }

local mc = load_module("coop_menu_char")
local function reset()
	CREATED = {}
	for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
	SE[900] = { coop_new_char = true }
end
local function made()
	local t = {}
	for _, c in ipairs(CREATED) do t[#t + 1] = c.sec .. (c.ammo and ("x" .. c.ammo) or "") end
	return table.concat(t, ",")
end

print("== the plan: exactly his list, his money, his map")
-- an expensive list no points of the tier would buy: the creator chose it in the stock screen, the host does not count again
CREATOR = { loadout = { "wpn_ak74_old", "wpn_ak74_old", "wpn_pm", "no_such_item" }, money = 12345, map = "", bare = false, used = false }
local normal = mc.host_plan_character(1, "bandit", "wpn_ak74_old,wpn_ak74_old,wpn_pm")
check(normal.ok == false, "the same list through the window is refused (points or items): " .. tostring(normal.reason))
local plan = mc.host_plan_character(1, "bandit", "wpn_ak74_old,wpn_ak74_old,wpn_pm", true)
check(plan.ok == true and plan.faction == "bandit" and plan.money == 12345, "exact: accepted, the world's faction, the record's money")

local starts = mc.faction_starts("bandit", true)
check(#starts >= 1, "the bandit faction has starts in the stock list")
local wanted = starts[#starts]
CREATOR.map = wanted.id
local at = mc.host_plan_character(1, "bandit", "", true)
check(at.where == "start:" .. wanted.id and at.gvid == wanted.gvid and at.lvid == wanted.lvid, "his map is his start: " .. tostring(at.where))
CREATOR.map = "esc_no_such_start"
local other = mc.host_plan_character(1, "bandit", "", true)
check(other.ok == true and other.where ~= "start:esc_no_such_start", "a map that is not the faction's: the faction's usual start")
check(log_has("esc_no_such_start"), "and a log line says why")
CREATOR.map = ""

CREATOR = nil
local none = mc.host_plan_character(1, "bandit", "", true)
check(none.ok == false and log_has("no creator"), "exact without a creator in the record: refused with a log line")

print("== the character: the list, its ammo, the money, the mark")
CREATOR = { loadout = { "wpn_ak74_old", "wpn_pm", "no_such_item", "wpn_pm" }, money = 12345, map = "", bare = false, used = false }
reset()
local ok, money, given = mc.host_make_character(1, 900, "bandit", "wpn_ak74_old,wpn_pm,no_such_item,wpn_pm", true, true)
local s = made()
check(ok == true and money == 12345, "made, with the record's money")
check(s:sub(1, #"wpn_ak74_old,wpn_pm,wpn_pm,") == "wpn_ak74_old,wpn_pm,wpn_pm," and #CREATED == 5
	and s:find("ammo_5.45x39_fmjx", 1, true) and s:find("ammo_9x18_fmjx", 1, true),
	"exactly his list (every copy) and the ammo of its weapons, no faction kit: " .. s)
check(given == #CREATED, "the count of what was given")
check(not s:find("no_such_item", 1, true) and log_has("no_such_item"), "a section the game does not have is skipped with a log line")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].n == 12345 and MONEY_CALLS[1].peer == 1, "the ledger gets the record's money")
check(SE[900].coop_new_char == nil, "NEW_VAR cleared: never offered in the world")

print("== bare: nothing but the money")
CREATOR = { loadout = {}, money = 700, map = "", bare = true, used = false }
reset()
ok, money = mc.host_make_character(1, 900, "bandit", "", true, true)
check(ok == true and money == 700 and #CREATED == 0, "bare: no items, the record's money")
check(SE[900].coop_new_char == nil, "and no mark")

print("== a retired key stays bare, exact or not (F3-10)")
CREATOR = { loadout = { "wpn_pm" }, money = 700, map = "", bare = false, used = false }
reset()
ok, money = mc.host_make_character(1, 900, "bandit", "wpn_pm", false, true)
check(ok == true and money == 0 and #CREATED == 0, "kit false: nothing, money 0")

print("== the window's path is unchanged")
CREATOR = { loadout = { "wpn_ak74_old" }, money = 99999, map = "", bare = false, used = false }
reset()
ok, money = mc.host_make_character(1, 900, "bandit", "", true)
check(ok == true and money == mc.faction_money("bandit") and made():find("wpn_ak74_old", 1, true) == nil,
	"without exact: the faction's kit and money, not the record's")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
