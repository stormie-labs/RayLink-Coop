-- Anomaly Coop temp test (W4 menu): coop_menu_char.script - new character offer, choice window, host check and
-- kit. Real configs\items\settings\new_game_loadouts.ltx from anomaly-ref, engine/UI stand-ins. Not shipped.
dofile("tests/lua/support/menu_stubs.lua")
dofile("tests/lua/support/stubs.d/money.lua") -- install_money_stubs: coop.money_* of the host ledger (F2 T1)

XML_FILES["ui_mm_faction_select.xml"] = xml_paths(REF .. "configs/ui/ui_mm_faction_select_16.xml")
XML_FILES["ui_coop_menu_char.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_menu_char_16.xml") -- 16:9 pair of the stock _16
local own43 = xml_paths(ROOT .. "configs/ui/ui_coop_menu_char.xml")
local p43 = xml_paths(REF .. "configs/ui/ui_mm_faction_select.xml")

STRINGS = {}
do
	local fh = assert(io.open(ROOT .. "configs/text/eng/st_coop_menu.xml", "r"))
	local src = fh:read("*a")
	fh:close()
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
end
game = { translate_string = function(id) return STRINGS[id] or id end }
coop_menu = load_module("coop_menu") -- for tr()

-- configs
function ini_file(name)
	assert(name == "items\\settings\\new_game_loadouts.ltx", name)
	return ini_over(REF .. "configs/items/settings/new_game_loadouts.ltx")
end
ini_sys = ini_table({})
local WEAPONS = {
	wpn_pm = { ammo_class = "ammo_9x18_fmj, ammo_9x18_pmm", slot = 1 },
	wpn_fort = { ammo_class = "ammo_9x18_fmj", slot = 1 },
	wpn_svt40 = { ammo_class = "ammo_7.62x54_7h1", slot = 2 },
	wpn_ak74_old = { ammo_class = "ammo_5.45x39_fmj", slot = 2 },
	wpn_mp133 = { ammo_class = "ammo_12x70_buck", slot = 2 },
	wpn_knife = { slot = 0, animation_slot = 1 },
	ammo_9x18_fmj = { box_size = 50 },
	ammo_9x18_pmm = { box_size = 50 },
	["ammo_7.62x54_7h1"] = { box_size = 20 },
	["ammo_5.45x39_fmj"] = { box_size = 30 },
	ammo_12x70_buck = { box_size = 10 },
}
function ini_sys:section_exist(s) return s ~= "cash" end -- every item of the list exists except "cash"
function ini_sys:r_string_ex(s, k) local w = WEAPONS[s]; local v = w and w[k]; return v ~= nil and tostring(v) or nil end
function ini_sys:r_float_ex(s, k) local w = WEAPONS[s]; return w and tonumber(w[k]) end

-- engine / world stand-ins
MODE = "host"
SENT = {}
PLAYERS = {}
coop = {
	is_active = function() return true end,
	is_host = function() return MODE == "host" end,
	is_client = function() return MODE == "client" end,
	players = function() return PLAYERS end,
	avatar_of = function(peer) for _, p in ipairs(PLAYERS) do if p.id == peer then return p.avatar_id end end end,
	send_event = function(name, payload, target) SENT[#SENT + 1] = { name = name, t = PAYLOADS[payload], to = target }
		return true end,
}
install_money_stubs(coop, { is_host = function() return MODE == "host" end }) -- calls go to MONEY_CALLS
PAYLOADS = {}
local pn = 0
coop_main = { handlers = {} }
function coop_main.encode(t) pn = pn + 1; local k = "p" .. pn; local c = {}; for a, b in pairs(t) do c[a] = b end; PAYLOADS[k] = c; return k end
function coop_main.decode(s) local c = {}; for a, b in pairs(PAYLOADS[s] or {}) do c[a] = b end; return c end
function coop_main.add_event_handler(n, f) coop_main.handlers[n] = f; return true end
local function deliver(name, t, from) coop_main.handlers[name](coop_main.encode(t), from, name) end

SE = {}
function se_save_var(id, name, var, val) SE[id] = SE[id] or {}; SE[id][var] = val end
function se_load_var(id, name, var) return SE[id] and SE[id][var] end
RELEASED, CREATED = {}, {}
function alife_release_id(id) RELEASED[#RELEASED + 1] = id end
function alife_create_item(sec, npc, t) CREATED[#CREATED + 1] = { sec = sec, parent = npc:id(), ammo = t and t.ammo }
	return { id = 9000 + #CREATED } end
local function make_npc(id, items)
	local n = { _id = id, items = items, community = "stalker" }
	function n:id() return self._id end
	function n:iterate_inventory(f, obj) for _, i in ipairs(self.items) do f(obj, { id = function() return i end }) end end
	function n:set_character_community(c) self.community = c end
	return n
end
NPCS = {}
level = { object_by_id = function(id) return NPCS[id] end, present = function() return true end }
ECO = 2
game_difficulties = { get_eco_factor = function(k) return k == "type" and ECO or nil end }
NEWS = {}
db = { actor = { give_game_news = function(self, cap, text) NEWS[#NEWS + 1] = text end } }
relation_registry = { community_relation = function() return 0 end }
axr_main = { config = config_stub() }
CALLBACKS = {}
function RegisterScriptCallback(n, f) CALLBACKS[n] = f end

-- utils_ui stand-ins (cell containers of the stock new game screen)
local function cell(sec, info)
	return { section = sec, flags = { info = info }, IsShown = function() return true end, CountChilds = function() return 0 end }
end
utils_ui = {}
function utils_ui.UICellContainer(id, owner)
	local cc = { ID = id, cell = {}, n = 0 }
	function cc:SetGridSpecs() end
	function cc:IsShown() return true end
	function cc:Reinit(t, tf) self.cell, self.n = {}, 0; for i, s in ipairs(t) do self.n = self.n + 1; self.cell[self.n] = cell(s, tf[i]) end end
	function cc:TransferItem(to, obj, sec)
		for i, ci in pairs(self.cell) do
			if ci.section == sec then
				self.cell[i] = nil
				to.n = to.n + 1
				local c2 = cell(sec, ci.flags.info)
				for k, v in pairs(ci.flags) do c2.flags[k] = v end
				to.cell[to.n] = c2
				return c2
			end
		end
	end
	function cc:Update() return false end
	function cc:OnKeyboard() end
	return cc
end
function utils_ui.UIInfoItem() return { Update = function() end } end
function utils_ui.UIHint() return { Update = function() end } end

local mc = load_module("coop_menu_char")
check(coop_main.handlers["menu.char_offer"] and coop_main.handlers["menu.new_character"]
	and coop_main.handlers["menu.char_result"], "event handlers registered at load")
mc.on_game_start()
check(CALLBACKS.se_stalker_on_spawn and CALLBACKS.actor_on_update, "callbacks registered")

print("== loadout")
local kit = mc.read_kit("stalker", 1)
local free = table.concat(kit.free, ",")
check(free:find("device_pda_1", 1, true) and free:find("wpn_pm", 1, true) and free:find("novice_outfit", 1, true)
	and not free:find("cash", 1, true), "free kit = value_1 false, inherited [shared], unknown sections skipped (" .. free .. ")")
check(kit.buy.wpn_svt40 and kit.buy.wpn_svt40.cost == 550 and kit.buy.wpn_svt40.count == 1, "buyable with points")
check(mc.read_kit("stalker", 2).buy.wpn_svt40 == nil, "value_4 limits the economy tier")
check(mc.read_kit("zombied", 1) == nil and mc.read_kit("nope", 1) == nil, "only selectable factions")
check(mc.budget(1) == 1000 and mc.budget(2) == 700 and mc.budget(3) == 400, "points per tier")
check(mc.faction_money("isg") == 3000 and mc.faction_money("greh") == 0, "money per faction")
local b = mc.read_kit("bandit", 1)
check(mc.check_buys(b, { "wpn_ak74_old" }, 700) == true, "buy within points")
check(select(2, mc.check_buys(b, { "wpn_ak74_old", "wpn_mp133" }, 700)) == "points", "over budget")
check(select(2, mc.check_buys(b, { "wpn_ak74_old", "wpn_ak74_old" }, 5000)) == "items", "more copies than listed")
check(select(2, mc.check_buys(b, { "wpn_pm" }, 5000)) == "items", "free item cannot be bought")
local ammo = mc.ammo_for({ "wpn_pm", "wpn_fort", "wpn_knife", "wpn_svt40" })
check(ammo.ammo_9x18_fmj == 100 and ammo["ammo_7.62x54_7h1"] == 40 and ammo.ammo_9x18_pmm == nil,
	"ammo like the stock new game (first ammo class, box or 2 boxes under 30)")

print("== host: new proxy, offer")
MODE = "host"
local se = { id = 500, section_name = function() return "coop_player_avatar" end, name = function() return "coop_player_avatar0500" end }
CALLBACKS.se_stalker_on_spawn(se)
check(mc.is_new(500), "a spawned proxy is new")
CALLBACKS.se_stalker_on_spawn({ id = 501, section_name = function() return "stalker_x" end, name = function() return "x" end })
check(not mc.is_new(501), "other stalkers are not marked")
PLAYERS = { { id = 0, nick = "host", is_self = true, avatar_id = 0 }, { id = 1, nick = "Guest", avatar_id = 500, rtt = 20 },
	{ id = 2, nick = "Old", avatar_id = 600, rtt = 20 } }
NOW = 200000
CALLBACKS.actor_on_update()
check(#SENT == 1 and SENT[1].name == "menu.char_offer" and SENT[1].to == 1 and SENT[1].t.eco == 2 and SENT[1].t.points == 700
	and SENT[1].t.nick == "Guest", "offer only to the new player, with the host's tier and points")
NOW = NOW + 3000
CALLBACKS.actor_on_update()
check(#SENT == 1, "no repeat before a minute")
NOW = NOW + 60000
CALLBACKS.actor_on_update()
check(#SENT == 2, "repeated after a minute while still new")

print("== host: checks")
ECO = 1 -- the host changed its economy tier: tier 1 items, 1000 points
local function last() return SENT[#SENT] end
deliver("menu.new_character", { faction = "stalker" }, 2)
check(last().name == "menu.char_result" and last().t.ok == false and last().t.reason == "not_new" and last().to == 2,
	"returning player keeps his character")
deliver("menu.new_character", { faction = "zombied" }, 1)
check(last().t.reason == "faction", "zombied refused")
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old,wpn_mp133" }, 1)
check(last().t.reason == "points", "points checked with the host's tier")
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 1)
check(last().t.reason == "busy", "offline proxy: try again")
deliver("menu.new_character", { faction = "bandit" }, 7)
check(last().t.reason == "no_character", "unknown peer")
local n_sent = #SENT
deliver("menu.new_character", { faction = "bandit" }, 0)
check(#SENT == n_sent, "from the host itself: ignored")

check(#MONEY_CALLS == 0, "refused choices set no money")

print("== host: apply")
NPCS[500] = make_npc(500, { 701, 702, 703 })
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 1)
local res = last().t
check(res.ok == true and res.faction == "bandit" and res.money == 1000 and last().to == 1, "accepted: faction and money")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].fn == "money_set" and MONEY_CALLS[1].peer == 1 and MONEY_CALLS[1].n == mc.faction_money("bandit")
	and MONEY_CALLS[1].ok, "new_character_money_on_host: coop.money_set(peer, faction money) on the host")
check(#RELEASED == 3 and RELEASED[1] == 701, "NPC supplies removed")
check(NPCS[500].community == "bandit", "proxy community = faction community")
local secs = {}
for _, c in ipairs(CREATED) do secs[#secs + 1] = c.sec .. (c.ammo and ("x" .. c.ammo) or "") end
local s = table.concat(secs, ",")
check(s:find("trenchcoat_outfit", 1, true) and s:find("wpn_ak74_old", 1, true) and s:find("ammo_5.45x39_fmjx30", 1, true)
	and s:find("ammo_9x18_fmjx50", 1, true) and not s:find("wpn_mp133", 1, true), "kit + bought + ammo spawned (" .. s .. ")")
check(CREATED[1].parent == 500, "items spawned into the proxy")
check(not mc.is_new(500), "mark cleared")
check(NEWS[#NEWS]:find("Guest", 1, true) ~= nil, "host news")
local before = #SENT
NOW = NOW + 120000
CALLBACKS.actor_on_update()
check(#SENT == before, "no more offers")
deliver("menu.new_character", { faction = "bandit" }, 1)
check(last().t.reason == "not_new", "second choice refused")
check(#MONEY_CALLS == 1, "no second money set")

print("== client: window")
MODE = "client"
SENT = {}
local CLIENT_MONEY = 4321
local CLIENT_GIVES = 0
db.actor = {
	give_game_news = function(self, cap, text) NEWS[#NEWS + 1] = text end,
	set_character_community = function(self, c) self.comm = c end,
	money = function() return CLIENT_MONEY end,
	give_money = function(self, d) CLIENT_GIVES = CLIENT_GIVES + 1; CLIENT_MONEY = CLIENT_MONEY + d end,
}
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end -- the host's calls are behind us
deliver("menu.char_offer", { eco = 1, points = 1000, nick = "Guest" }, 0)
local gui = mc.GUI
check(gui and gui.shown, "offer opens the window")
check(#MISSING_PATHS == 0, "xml paths exist in the stock 16:9 layout and ui_coop_menu_char.xml (" .. table.concat(MISSING_PATHS, ", ") .. ")")
local miss43 = {}
for p in pairs(XML_FILES["ui_mm_faction_select.xml"]) do end
for _, path in ipairs({ "main_dialog:frame_back", "main_dialog:box_map", "main_dialog:box_faction", "main_dialog:cont_inv", "main_dialog:cont_loadout",
	"main_dialog:btn_start", "main_dialog:btn_back", "main_dialog:btn_faction", "main_dialog:input_name",
	"main_dialog:popup_faction:scroll_faction", "main_dialog:popup_faction:btn_isg", "main_dialog:check_reset" }) do
	if not p43[path] then miss43[#miss43 + 1] = path end
end
check(#miss43 == 0, "same nodes in the 4:3 stock layout (" .. table.concat(miss43, ",") .. ")")
check(gui.name.text == "Guest" and gui.info.text:find("(Guest)", 1, true), "nick and info shown")
check(gui.points_left == 1000 and gui.text_money.text == "1000 RU", "points from the host, faction money")
check(gui.facts.text:find("Points for gear: %c[255,225,225,225]1000", 1, true) and gui.facts.text:find("1000 RU", 1, true)
	and gui.facts.text:find("Host:", 1, true), "facts: host, economy, points, faction money")
check(gui.status.text:find("Press Done", 1, true), "ready hint in the status line")
check(gui.start.text == "Start: next to the group" and gui.box_map.shown == false and gui.map_dim.shown == false,
	"no level picture without a known level")
check(gui.color_icon.tcolor ~= nil, "colour square tinted with the player's colour")
local diff_nodes = {}
for p in pairs(XML_FILES["ui_coop_menu_char.xml"]) do if not own43[p] then diff_nodes[#diff_nodes + 1] = p end end
for p in pairs(own43) do if not XML_FILES["ui_coop_menu_char.xml"][p] then diff_nodes[#diff_nodes + 1] = p end end
check(#diff_nodes == 0, "4:3 and 16:9 co-op layouts have the same nodes (" .. table.concat(diff_nodes, ",") .. ")")
-- pick bandit, buy the AK
click(gui, "btn_faction")
check(gui.access == false and gui.registered.btn_bandit ~= nil and gui.registered.btn_isg == nil, "popup: only unlocked factions")
click(gui, "btn_bandit")
check(gui.faction == "bandit" and gui.access, "bandit selected")
local idx
for i, ci in pairs(gui.CC.loadout.cell) do if ci.section == "wpn_ak74_old" then idx = i end end
gui:On_CC_Mouse1("loadout", idx)
check(gui.points_left == 450 and gui.points_used == 550, "bought: points moved")
for i, ci in pairs(gui.CC.loadout.cell) do if ci.section == "wpn_mp133" then idx = i end end
gui:On_CC_Mouse1("loadout", idx)
check(gui.points_left == 450, "cannot overspend")
check(table.concat(gui:Bought(), ",") == "wpn_ak74_old", "bought list")
click(gui, "btn_start")
check(SENT[1].name == "menu.new_character" and SENT[1].to == 0 and SENT[1].t.faction == "bandit"
	and SENT[1].t.buy == "wpn_ak74_old", "choice sent to the host")
check(gui.btn_start.enabled == false and gui.status.text:find("Waiting for the host...", 1, true), "waiting")
deliver("menu.char_offer", { eco = 1, points = 1000, nick = "Guest" }, 0)
check(gui.shown, "repeated offer while waiting changes nothing")
-- refused, then accepted
deliver("menu.char_result", { ok = false, reason = "points" }, 0)
check(gui.btn_start.enabled and gui.status.text:find("The host refused the choice: not enough points", 1, true), "refusal shown")
deliver("menu.char_result", { ok = true, faction = "bandit", money = 1000, items = 12 }, 0)
check(db.actor.comm == "actor_bandit", "client: actor_<faction>")
check(CLIENT_MONEY == 4321 and CLIENT_GIVES == 0 and #MONEY_CALLS == 0,
	"new_character_money_on_host: the client sets no money (no give_money, no ledger call): the host did")
check(not gui.shown and NEWS[#NEWS]:find("Your character", 1, true), "window closed, news")
deliver("menu.char_offer", { eco = 1, points = 1000, nick = "Guest" }, 0)
check(not gui.shown, "no window after the character is set up")
CLIENT_MONEY = 5
db.actor.comm = nil
deliver("menu.char_result", { ok = true, faction = "isg", money = 3000 }, 3)
check(CLIENT_MONEY == 5 and db.actor.comm == nil, "results from a non-host are ignored")

print("== client: later")
local mc2 = load_module("coop_menu_char")
mc2.on_game_start()
level.name = function() return "l01_escape" end
STRINGS.l01_escape = "Cordon"
deliver("menu.char_offer", { eco = 3, points = 400, nick = "Guest" }, 0)
local g2 = mc2.GUI
check(g2 and g2.shown and g2.points_left == 400, "fresh state: window with tier 3 points")
check(g2.box_map.texture == "ui_new_game_map_l01_escape" and g2.box_map.shown and g2.map_dim.shown
	and g2.start.text == "Start: Cordon, next to the group", "level picture and start line of the current level")
click(g2, "btn_back")
check(not g2.shown and NEWS[#NEWS]:find("again", 1, true), "Later closes with a hint")
deliver("menu.char_offer", { eco = 3, points = 400, nick = "Guest" }, 0)
check(g2.shown, "next offer opens it again")
g2:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(not g2.shown, "Escape = Later")
local saved_actor = db.actor
db.actor = nil
deliver("menu.char_offer", { eco = 3, points = 400, nick = "Guest" }, 0)
check(not g2.shown, "no actor yet: not shown")
db.actor = saved_actor
NOW = NOW + 5000
CALLBACKS.actor_on_update()
check(g2.shown, "client tick shows it once the actor exists")

-- string ids used by the script exist
local fh = assert(io.open(ROOT .. "scripts/coop_menu_char.script", "r"))
local src = fh:read("*a")
fh:close()
local absent = {}
for id in src:gmatch('"(st_coop_[%w_]+)"') do
	if id:sub(-1) ~= "_" and not STRINGS[id] then absent[#absent + 1] = id end
end
for _, r in ipairs({ "not_new", "faction", "items", "points", "no_character", "busy" }) do
	if not STRINGS["st_coop_char_reason_" .. r] then absent[#absent + 1] = r end
end
check(#absent == 0, "string ids exist (" .. table.concat(absent, ",") .. ")")

print(string.format("%d passed, %d failed", PASSES, FAILS))
