-- Anomaly Coop: coop_ui.script inventory envelope button (give money; the amount list is coop_economy_money's, test_economy).
-- Stand-ins for ui_inventory, the cell properties box and coop_economy_money. Run: tools\test_lua.cmd ui_inventory
dofile("tests/lua/support/menu_stubs.lua")

XML_FILES["ui_coop_inventory.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_inventory.xml")
local p16 = xml_paths(ROOT .. "configs/ui/ui_coop_inventory_16.xml")
STRINGS = {}
for _, f in ipairs({ "st_coop_economy.xml", "st_coop_menu.xml" }) do
	local fh = assert(io.open(ROOT .. "configs/text/eng/" .. f, "r"))
	for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
	fh:close()
end
game = { translate_string = function(id) return STRINGS[id] or id end }
function GetCursorPosition() return { x = 1, y = 2 } end
EVENTS = {}
function CreateTimeEvent(a, b, d, f) EVENTS[#EVENTS + 1] = f end
local function run_events() local e = EVENTS; EVENTS = {}; for _, f in ipairs(e) do f() end end

ACTIVE, PLAYERS = false, {}
coop = {
	is_active = function() return ACTIVE end, is_host = function() return false end, is_live = function() return ACTIVE end,
	players = function() return PLAYERS end,
}
OPENED = {} -- the amount lists asked of coop_economy_money: { ui, peer }
coop_economy_money = { open_amounts = function(ui, peer) OPENED[#OPENED + 1] = { ui, peer } end }
RULE = true
coop_economy_core = { rule = function(k) if k == "money_transfer" then return RULE end end }
db = { actor = { money = function() return 1200 end } }

-- ui_inventory.UIInventory stand-in: a plain Lua class table, like luabind's class methods
local ORIG_CALLS = 0
local UIInventory = {}
UIInventory.__index = UIInventory
function UIInventory:UpdateCharacter() ORIG_CALLS = ORIG_CALLS + 1 end
ui_inventory = { UIInventory = UIInventory }
local function new_inventory(mode)
	local ui = setmetatable({ mode = mode, callbacks = {}, registered = {} }, UIInventory)
	ui.player_dialog = window("player")
	ui.player_money = window("player:money")
	ui.player_money.pos = { x = 140, y = 80 }
	ui.player_money.w, ui.player_money.h = 104, 22
	ui.item_props = { Reset = function(self, pos, actions, names, params) self.last = { actions = actions, names = names, params = params } end }
	function ui:Register(w, n) self.registered[n] = w end
	function ui:AddCallback(n, ev, f, obj) self.callbacks[n .. "#" .. ev] = { f = f, obj = obj } end
	return ui
end

load_module("coop_util")
local modes = dofile("tests/lua/support/modes.lua")
modes.live(load_module("coop_mode"), load_module)
local ui_mod = load_module("coop_ui")
ui_mod.on_game_start()
check(ui_inventory.UIInventory.UpdateCharacter ~= nil and ui_inventory.UIInventory.coop_ui_MoneyTo ~= nil, "UIInventory patched")
ui_mod.on_game_start()
local inv = new_inventory("inventory")
inv:UpdateCharacter()
check(ORIG_CALLS == 1, "patched once: the original runs once per call")
check(inv.coop_ui_money_btn == nil, "no session: no button (stock inventory)")

ACTIVE = true
PLAYERS = { { id = 0, nick = "Host", is_self = false }, { id = 1, nick = "Me", is_self = true } }
NOW = NOW + 1 -- coop_util reads the player list once a frame
inv:UpdateCharacter()
local btn = inv.coop_ui_money_btn
check(btn and btn.shown and #MISSING_PATHS == 0, "session: envelope button created from ui_coop_inventory.xml")
check(btn.pos.x == 140 + 104 + 3, "button right of the money readout")
local same = true
for p in pairs(XML_FILES["ui_coop_inventory.xml"]) do same = same and p16[p] == true end
for p in pairs(p16) do same = same and XML_FILES["ui_coop_inventory.xml"][p] == true end
check(same, "4:3 and 16:9 layouts have the same nodes")

-- one other player: coop_economy_money's amount list right away
click(inv, "coop_ui_give_money")
check(#OPENED == 1 and OPENED[1][1] == inv and OPENED[1][2] == 0 and inv.item_props.last == nil,
	"one player: the amount list of coop_economy_money for him at once")

-- two other players: choose the player first, the amounts open on the next update
PLAYERS[#PLAYERS + 1] = { id = 2, nick = "Bob", is_self = false }
NOW = NOW + 1
inv.item_props.last = nil
click(inv, "coop_ui_give_money")
local m = inv.item_props.last
check(m and #m.names == 2 and m.names[2] == "Give money to Bob..." and m.actions[1] == "coop_ui_MoneyTo" and #OPENED == 1,
	"two players: who first")
inv[m.actions[2]](inv, unpack(m.params[2]))
check(#OPENED == 1 and #EVENTS == 1, "amount list deferred (the box closes after an action)")
run_events()
check(#OPENED == 2 and OPENED[2][1] == inv and OPENED[2][2] == 2, "amounts for Bob")

-- hidden: other modes, transfers off, alone
local trade = new_inventory("trade")
trade:UpdateCharacter()
check(trade.coop_ui_money_btn == nil, "trade mode: no button")
RULE = false
inv:UpdateCharacter()
check(not inv.coop_ui_money_btn.shown, "money transfers off by the host: hidden")
RULE = true
PLAYERS = { { id = 1, nick = "Me", is_self = true } }
NOW = NOW + 1
inv:UpdateCharacter()
check(not inv.coop_ui_money_btn.shown, "alone: hidden")

print(string.format("%d passed, %d failed", PASSES, FAILS))
