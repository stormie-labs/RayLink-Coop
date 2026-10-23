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
	if name == "plugins\\new_game_start_locations.ltx" then -- protocol 8: the faction starts of the stock new game
		return ini_over(REF .. "configs/plugins/new_game_start_locations.ltx")
	end
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
	-- protocol 8 (the join flow): the session as the menu sees it, leaving it, strings kept for the session
	session_info = function() return SESSION end,
	disconnect = function() DISCONNECTS = DISCONNECTS + 1; SESSION = { active = false, phase = "off" }; return true end,
	stash_set = function(k, v) STASH[k] = v; return true end,
	stash_get = function(k) return STASH[k] end,
}
SESSION = { active = true, phase = "hosting" }
DISCONNECTS = 0
STASH = {}
MONEY_REFUSE = nil -- a reason makes the ledger stand-in refuse
ORDER = {} -- F2 T6b: what the host did to a new character, in order (money_set must come before the inventory is touched)
install_money_stubs(coop, { is_host = function() return MODE == "host" end, refuse = function() return MONEY_REFUSE end,
	on_call = function(fn) ORDER[#ORDER + 1] = fn end }) -- calls go to MONEY_CALLS
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
function alife_release_id(id) RELEASED[#RELEASED + 1] = id; ORDER[#ORDER + 1] = "release" end
function alife_create_item(sec, npc, t) -- a game object (in the world) or a server object (before the world)
	ORDER[#ORDER + 1] = "create"
	local parent = type(npc.id) == "function" and npc:id() or npc.id
	CREATED[#CREATED + 1] = { sec = sec, parent = parent, ammo = t and t.ammo }
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
ADDED_CALLBACKS = {}
function AddScriptCallback(n) ADDED_CALLBACKS[n] = true end -- F3 Task 10: coop_host_new_character, the engine's

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
-- the ledger refuses the money: the mark stays, so the player can try again; F2 T6b: the money is set BEFORE the
-- inventory is touched, so a refusal (and its retry) never wipes or doubles what the character carries
MONEY_REFUSE = "no character"
RELEASED, CREATED, ORDER = {}, {}, {}
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 1)
check(last().t.ok == false and last().t.reason == "busy" and last().to == 1, "money refused: the player is told to try again")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].fn == "money_set" and MONEY_CALLS[1].ok == false, "the refused call was money_set")
check(mc.is_new(500), "money refused: the new-character mark stays, so the retry is possible")
check(#RELEASED == 0 and #CREATED == 0 and NPCS[500].community == "stalker",
	"money refused: the inventory was not touched (nothing released, nothing created, same community)")
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 1)
check(#MONEY_CALLS == 2 and #RELEASED == 0 and #CREATED == 0 and mc.is_new(500), "the retry is refused the same way and still touches nothing")
MONEY_REFUSE = nil
-- the kit fails after the money was set (the NPC cannot list its items): the player is told to try again, the mark
-- stays, and the retry sets the same money again (a set, not an add)
local iterate = NPCS[500].iterate_inventory
NPCS[500].iterate_inventory = function() error("boom") end
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 1)
check(last().t.ok == false and last().t.reason == "busy" and mc.is_new(500), "kit failed: busy, the mark stays")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].ok and #CREATED == 0, "kit failed: the money was set first, nothing was created")
NPCS[500].iterate_inventory = iterate
RELEASED, CREATED, ORDER = {}, {}, {}
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 1)
check(ORDER[1] == "money_set" and ORDER[2] == "release" and ORDER[#ORDER] == "create",
	"money_set comes before the inventory is touched (" .. table.concat(ORDER, ",", 1, math.min(#ORDER, 3)) .. "...)")
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

-------------------------------------------------------------------------------
-- Protocol 8 (owner, live test 2026-10-23): a new key chooses faction and gear before the world, in the main menu;
-- the host makes the character at its faction's start with the kit and the money, then sends the world.
-------------------------------------------------------------------------------
print("== faction starts (stock new game list)")
local starts = mc.faction_starts("bandit", false)
local ids = {}
for _, st in ipairs(starts) do ids[#ids + 1] = st.id end
check(table.concat(ids, ",") == "northern_factory,car_park,container_warehouse,pole_bandit_base",
	"bandit starts outside story mode, commented lines skipped (" .. table.concat(ids, ",") .. ")")
local story = mc.faction_starts("bandit", true)
check(#story == 1 and story[1].id == "northern_factory" and story[1].image == "l04_darkvalley",
	"story mode: only the starts marked for it (ui_mm_faction_select LoadMap)")
local cp = starts[2]
check(cp.gvid == 440 and cp.lvid == 436975 and math.abs(cp.x - 106.27) < 1e-6 and math.abs(cp.z + 1.75) < 1e-6
	and cp.image == "l01_escape", "a start's point: lvid, gvid, x y z of its section")
check(#mc.faction_starts("nope", false) == 0, "no list: no starts")

-- the game graph of the test: the level of every start's vertex from its picture, but the Pole starts are on their own
-- level although their picture says Cordon (the host goes by the game graph)
GV_LEVEL = {}
for _, f in ipairs({ "army", "bandit", "csky", "dolg", "ecolog", "freedom", "killer", "stalker", "monolith", "greh", "isg",
	"renegade" }) do
	for _, st in ipairs(mc.faction_starts(f, false)) do GV_LEVEL[st.gvid] = st.image end
end
GV_LEVEL[5328], GV_LEVEL[5341] = "pole", "pole"
GV_LEVEL[1704] = "l05_bar"
local function level_of(gv) return GV_LEVEL[gv] end
local function first() return 1 end
local function last_of(n) return n end

local s1 = mc.start_for("bandit", { level = "l01_escape", level_of = level_of, story = false, pick = last_of })
check(s1 and s1.id == "car_park" and s1.where == "start:car_park" and s1.gvid == 440,
	"bandit, host on Cordon: the bandit start of Cordon (Pole is another level by its game vertex)")
local s2 = mc.start_for("stalker", { level = "l01_escape", level_of = level_of, story = false, pick = last_of })
check(s2 and s2.id == "rookie_village", "stalker, host on Cordon: the rookie village")
local camp_asked
local s3 = mc.start_for("dolg", { level = "l01_escape", level_of = level_of, story = false, pick = first,
	camp = function(f) camp_asked = f; return { id = "esc_smart_terrain_5_7", x = 1, y = 2, z = 3, lvid = 11, gvid = 12 } end })
check(camp_asked == "dolg" and s3 and s3.where == "camp:esc_smart_terrain_5_7" and s3.gvid == 12 and s3.lvid == 11,
	"no start of the faction on the host's level: a camp of the faction there")
check(mc.start_for("dolg", { level = "l01_escape", level_of = level_of, story = false, pick = first }) == nil,
	"no camp either: nil (the engine puts him next to the host)")
local s4 = mc.start_for("dolg", { level = nil, level_of = level_of, story = false, pick = last_of })
check(s4 and s4.id == "abandoned_village" and s4.where == "start:abandoned_village",
	"F3a (any level): the faction's own start, as the stock new game")
local picks = {}
local s5 = mc.start_for("killer", { level = nil, level_of = level_of, story = false,
	pick = function(n) picks[#picks + 1] = n; return 2 end })
check(picks[1] == 4 and #picks == 1 and s5.id == "construction_site", "one of the starts at random, like the stock default")

print("== host: plan and make a character before the world")
MODE = "host"
ECO = 1
function game_graph()
	return {
		valid_vertex_id = function(_, gv) return GV_LEVEL[gv] ~= nil end,
		vertex = function(_, gv) return { level_id = function() return GV_LEVEL[gv] end } end,
	}
end
INFOS = { story_mode_disabled = true }
function has_alife_info(i) return INFOS[i] == true end
local host_actor = {
	give_game_news = function(self, cap, text) NEWS[#NEWS + 1] = text end,
	game_vertex_id = function() return 454 end, -- Cordon, the rookie village
	position = function() return { x = -220, y = -20, z = -160 } end,
}
db.actor = host_actor
math.random = function(n) return n and 1 or 0.5 end

local plan = mc.host_plan_character(1, "bandit", "wpn_ak74_old")
check(plan.ok == true and plan.where == "start:car_park" and plan.gvid == 440 and plan.lvid == 436975
	and math.abs(plan.x - 106.27) < 1e-6 and math.abs(plan.y + 2.86) < 1e-6, "bandit: at the bandit start of the host's level")
check(plan.faction == "bandit" and plan.money == 1000, "the faction and its money")
local bad = mc.host_plan_character(1, "zombied", "")
check(bad.ok == false and bad.reason == "faction", "zombied refused")
check(mc.host_plan_character(1, "bandit", "wpn_ak74_old,wpn_mp133").reason == "points", "points of the host's tier")
check(mc.host_plan_character(1, "bandit", "wpn_pm").reason == "items", "the free kit cannot be bought")
check(mc.host_plan_character(1, 7, nil).reason == "faction", "junk from the engine is refused, not an error")

local function smart(name, gv, props, x, y, z)
	return { name = function() return name end, m_game_vertex_id = gv, m_level_vertex_id = 5000 + gv,
		position = { x = x, y = y, z = z }, props = props }
end
SIMBOARD = { smarts = {
	[1] = { smrt = smart("esc_smart_terrain_5_7", 454, { base = 1, dolg = 1 }, 100, 0, 100) },
	[2] = { smrt = smart("esc_smart_terrain_2_12", 454, { base = 1, dolg = 1 }, -200, -20, -150) },
	[3] = { smrt = smart("esc_smart_terrain_4_9", 454, { base = 0, dolg = 1 }, -219, -20, -161) },
	[4] = { smrt = smart("bar_dolg_general", 1704, { base = 1, dolg = 1 }, -220, -20, -160) },
	[5] = { smrt = smart("esc_smart_terrain_3_16", 454, { base = 1, army = 1, dolg = 0 }, -220, -20, -160) },
	[6] = { smrt = nil },
} }
local dolg = mc.host_plan_character(2, "dolg", "")
check(dolg.ok and dolg.where == "camp:esc_smart_terrain_2_12" and dolg.gvid == 454 and dolg.lvid == 5454
	and dolg.x == -200, "Duty, host on Cordon: the nearest Duty base of Cordon (not a lair, not another level or faction)")
SIMBOARD = nil
local alone = mc.host_plan_character(2, "dolg", "")
check(alone.ok and alone.where == nil and alone.gvid == nil, "nothing of the faction here: no point (next to the host)")
INFOS.story_mode_disabled = nil
local st_plan = mc.host_plan_character(1, "bandit", "")
check(st_plan.ok and st_plan.where == nil, "story mode: the bandit start of story mode is in Dark Valley: next to the host")
INFOS.story_mode_disabled = true
local t_eco, t_points, t_story = mc.join_terms()
check(t_eco == 1 and t_points == 1000 and t_story == false, "terms of the offer: the host's economy tier, its points, no story")
INFOS.story_mode_disabled = nil
check(select(3, mc.join_terms()) == true, "terms of the offer: story mode on")
INFOS.story_mode_disabled = true
db.actor = nil
local no_actor = mc.host_plan_character(1, "bandit", "")
check(no_actor.ok and no_actor.where == nil, "no actor (cannot happen on a host): no point")
db.actor = host_actor
MODE = "client"
check(mc.host_plan_character(1, "bandit", "").ok == false, "only a host plans")
MODE = "host"

SE_OBJ = {}
function alife_object(id) return SE_OBJ[id] end
SE_OBJ[900] = { id = 900, position = { x = 106.27, y = -2.86, z = -1.75 }, m_level_vertex_id = 436975, m_game_vertex_id = 440 }
CALLBACKS.se_stalker_on_spawn({ id = 900, section_name = function() return "coop_player_avatar" end,
	name = function() return "coop_player_avatar0900" end })
check(mc.is_new(900), "the engine's spawn marks it new")
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
RELEASED, CREATED = {}, {}
MONEY_REFUSE = "no character"
local ok0, why0 = mc.host_make_character(1, 900, "bandit", "wpn_ak74_old")
check(ok0 == false and why0 == "busy" and mc.is_new(900), "money refused: refused (the engine drops the character)")
MONEY_REFUSE = nil
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
RELEASED, CREATED = {}, {}
local news_before = #NEWS
local ok1, money1, given1 = mc.host_make_character(1, 900, "bandit", "wpn_ak74_old")
check(ok1 == true and money1 == 1000 and given1 == #CREATED and given1 > 3, "made: kit given (" .. tostring(given1) .. ")")
check(CREATED[1].parent == 900, "into the server object: the character is offline until its player loads the world")
local made = {}
for _, c in ipairs(CREATED) do made[#made + 1] = c.sec .. (c.ammo and ("x" .. c.ammo) or "") end
local made_s = table.concat(made, ",")
check(made_s:find("trenchcoat_outfit", 1, true) and made_s:find("wpn_ak74_old", 1, true)
	and made_s:find("ammo_5.45x39_fmjx30", 1, true), "faction kit + bought + ammo (" .. made_s .. ")")
check(#RELEASED == 0, "nothing released by Lua: the engine strips the profile's supplies before")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].fn == "money_set" and MONEY_CALLS[1].peer == 1 and MONEY_CALLS[1].n == 1000
	and MONEY_CALLS[1].ok, "the faction's money on the host ledger")
check(not mc.is_new(900), "not new: never offered in the world")
check(#NEWS == news_before + 1 and NEWS[#NEWS]:find("Guest", 1, true) ~= nil, "host news with the nick")
check(mc.host_make_character(1, 901, "bandit", "") == false, "no server object: refused")
check(select(2, mc.host_make_character(1, 900, "zombied", "")) == "faction", "the choice is checked again")

MC_HOOKS = {}
coop_mods_core = { on_new_character = function(peer) MC_HOOKS[#MC_HOOKS + 1] = peer end }
PLAYERS = { { id = 0, nick = "host", is_self = true, avatar_id = 0 }, { id = 1, nick = "Guest", avatar_id = 900, rtt = 20 } }
NPCS[900] = nil
local sent_before = #SENT
NOW = NOW + 5000
CALLBACKS.actor_on_update()
check(#MC_HOOKS == 0 and #SENT == sent_before, "still loading (offline): no hook yet, and no offer (not new)")
NPCS[900] = make_npc(900, {})
NOW = NOW + 5000
CALLBACKS.actor_on_update()
check(#MC_HOOKS == 1 and MC_HOOKS[1] == 1, "in the world: the mods' new character hook (starter magazines) once")
NOW = NOW + 5000
CALLBACKS.actor_on_update()
check(#MC_HOOKS == 1 and #SENT == sent_before, "only once")
coop_mods_core = nil

print("== client: the choice window before the world")
MODE = "client"
SENT = {}
NEWS = {}
SESSION = { active = true, phase = "receiving-world", nick = "Guest" }
PLAYERS = { { id = 1, nick = "Guest", is_self = true }, { id = 0, nick = "Boss" } }
db.actor = nil -- the main menu: no level
local mj = load_module("coop_menu_char")
check(mj.join_choice() == nil, "no choice before an offer")
check(mj.join_offer(2, 700, "l01_escape", "", 0) == true, "the offer opens the window in the main menu (no actor)")
local gj = mj.GUI
check(gj and gj.shown and gj.points_left == 700, "window with the host's points")
check(gj.name.text == "Guest" and gj.info.text == coop_menu.tr("st_coop_char_info_join", "Boss", "Guest"),
	"the join text: the character is made when Done is pressed")
check(gj.status.text:find(STRINGS.st_coop_char_ready_join, 1, true) ~= nil, "join hint in the status line")
check(gj.registered.btn_back.text == STRINGS.st_coop_char_btn_leave, "the second button leaves the session")
check(gj.box_map.texture == "ui_new_game_map_l01_escape" and gj.box_map.shown, "the host's level picture")
check(gj.start.text == coop_menu.tr("st_coop_char_start_faction", "Cordon"), "stalker: at the faction's start on Cordon")
click(gj, "btn_faction")
click(gj, "btn_dolg")
check(gj.start.text == coop_menu.tr("st_coop_char_start_camp", "Cordon"), "Duty: no Duty start on Cordon: a camp or the group")
click(gj, "btn_start")
check(#SENT == 0, "no script event: the engine takes the choice")
local jf, jb = mj.join_choice()
check(jf == "dolg" and jb == "", "the engine gets faction and bought gear")
check(mj.join_choice() == nil, "taken once")
check(STASH.coop_char_joined == "dolg", "kept for the news in the world (the load rebuilds Lua)")
check(gj.btn_start.enabled == false and gj.status.text:find("Waiting for the host...", 1, true), "waiting for the world")
check(mj.join_offer(2, 700, "l01_escape", "points", 0) == true, "refused: offered again")
check(gj.shown and gj.btn_start.enabled and gj.faction == "dolg"
	and gj.status.text:find(coop_menu.tr("st_coop_char_refused", STRINGS.st_coop_char_reason_points), 1, true),
	"the refusal shown, the choice kept, Done again")
gj:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(gj.shown, "Escape does not leave the session")
click(gj, "btn_faction")
gj:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(gj.shown and gj.access, "Escape closes the faction popup")
mj.join_offer(2, 700, "l01_escape", "", 1) -- the host's game is in story mode
click(gj, "btn_faction")
click(gj, "btn_bandit")
check(gj.start.text == coop_menu.tr("st_coop_char_start_camp", "Cordon"), "story mode: the bandit start of story mode is elsewhere")
mj.join_closed("world")
check(not gj.shown, "the world arrives: the window closes")
check(mj.join_choice() == nil, "nothing left to send")
mj.join_offer(2, 700, "l01_escape", "", 0)
SESSION.phase = "loading-world"
NOW = NOW + 1000
gj:Update()
check(not gj.shown, "the window follows the session (loading the world)")
SESSION = { active = true, phase = "receiving-world", nick = "Guest" }
mj.join_offer(2, 700, "", "", 0)
check(gj.shown and gj.start.text == STRINGS.st_coop_char_start_near and gj.box_map.shown == false, "no level: next to the group")
click(gj, "btn_back")
check(not gj.shown and DISCONNECTS == 1, "Leave closes the window and the session")
SESSION = { active = true, phase = "receiving-world", nick = "Guest" }
mj.join_offer(2, 700, "l01_escape", "", 0)
SESSION = { active = false, phase = "off" }
NOW = NOW + 1000
gj:Update()
check(not gj.shown, "the session ended (kicked, host gone): the window closes")

-- in the world after the load: a fresh Lua state; the choice made before the world is told once
local mw = load_module("coop_menu_char")
mw.on_game_start()
SESSION = { active = true, phase = "live", nick = "Guest" }
db.actor = { give_game_news = function(self, cap, text) NEWS[#NEWS + 1] = text end }
NOW = NOW + 5000
CALLBACKS.actor_on_update()
check(NEWS[#NEWS] == coop_menu.tr("st_coop_char_done", "st_faction_dolg") and STASH.coop_char_joined == nil,
	"in the world: news of the character chosen before it, once")
local n_news = #NEWS
NOW = NOW + 5000
CALLBACKS.actor_on_update()
check(#NEWS == n_news, "told once")

print("== client: -coop_autochoose and the log of every branch (night run 1, 2026-10-23)")
-- The engine (coop_join.cpp client_char_frame) passes the offer as it is on the wire: a first offer has refusal ""
-- (CharOfferMsg), never nil. Night run 1: `not refusal` was false for "", the automatic answer never came, the window
-- waited 10 min for nobody and the log said nothing.
STASH = {}
MODE = "client"
db.actor = nil -- the main menu
SESSION = { active = true, phase = "receiving-world", nick = "Guest" }
local function log_count(pat)
	local n = 0
	for _, l in ipairs(LOG) do if l:find(pat, 1, true) then n = n + 1 end end
	return n
end
CMDLINE = '"e:\\a\\bin_b\\anomalycoopdx11avx.exe" -fsltx fsgame_b.ltx -coop_connect 127.0.0.1:27960 -coop_autochoose stalker -coop_testplan f2w1_client'
function command_line() return CMDLINE end
local ma = load_module("coop_menu_char")
LOG = {}
check(ma.join_offer(1, 1700, "l01_escape", "", 0) == true, "autochoose: a first offer as the engine passes it (refusal \"\") is taken")
check(ma.GUI == nil, "autochoose: no window")
check(log_count("[coop-char] test: offer answered at once with stalker") == 1, "autochoose: the answer is in the log")
local af, ab = ma.join_choice()
check(af == "stalker" and ab == "", "autochoose: the engine gets stalker, nothing bought")
check(ma.join_choice() == nil, "autochoose: taken once")
check(ma.join_offer(1, 1700, "l01_escape", nil, 0) == true and select(1, ma.join_choice()) == "stalker",
	"autochoose: no refusal given at all (nil) is a first offer too")
LOG = {}
-- review of the fix, minor 1: "busy" is the host's fallback reason (its Lua failed for a moment); an unattended run
-- answers once more instead of sitting in the window until the host's 10-minute kick
check(ma.join_offer(1, 1700, "l01_escape", "busy", 0) == true and not (ma.GUI and ma.GUI.shown)
	and select(1, ma.join_choice()) == "stalker", "autochoose, host busy: answered once more, no window")
check(log_count("test: the host was busy, the automatic choice goes once more") == 1, "the retry is in the log")
check(ma.join_offer(1, 1700, "l01_escape", "busy", 0) == true, "autochoose refused by the host: the window opens")
check(ma.GUI and ma.GUI.shown and ma.join_choice() == nil, "autochoose refused: a player must choose")
check(log_count("the host refused the automatic choice (busy)") == 1, "autochoose refused: why the window opened is in the log")
check(log_count("choice window open") == 1, "the window that opened is in the log")
ma.join_offer(1, 1700, "l01_escape", "busy", 0)
check(log_count("the host refused the automatic choice") == 1 and log_count("choice window open") == 1
	and log_count("offer shown again in the open window") == 1, "the same offer again: one line, not two more")
ma.join_closed("world")
check(not ma.GUI.shown, "closed")
check(ma.join_offer(1, 1700, "l01_escape", "busy", 0) == true and not ma.GUI.shown
	and select(1, ma.join_choice()) == "stalker", "a new window cycle: one more retry for busy")
ma.join_closed("world")
LOG = {}
check(ma.join_offer(1, 1700, "l01_escape", "faction", 0) == true and ma.GUI.shown and ma.join_choice() == nil,
	"autochoose refused for a real reason: the window at once, no retry")
check(log_count("the host refused the automatic choice (faction)") == 1, "the reason is in the log")
ma.join_closed("world")
CMDLINE = '"x.exe" -coop_connect 127.0.0.1:27960 -coop_autochoose zombied'
LOG = {}
check(ma.join_offer(1, 1700, "l01_escape", "", 0) == true and ma.GUI.shown, "autochoose with a faction nobody may pick: the window")
check(log_count("-coop_autochoose zombied: not a faction a player can pick") == 1, "the bad faction is in the log")
ma.join_closed("world")
-- review of the fix, minor 2: a flag that gives no faction, or a command line the script cannot read, is not silent
CMDLINE = '"x.exe" -coop_connect 127.0.0.1:27960 -coop_autochoose'
LOG = {}
check(ma.join_offer(1, 1700, "l01_escape", "", 0) == true and ma.GUI.shown, "autochoose without a value: the window")
check(log_count("-coop_autochoose without a faction") == 1, "the empty flag is in the log")
ma.join_closed("world")
local saved_command_line = command_line
command_line = function() error("no command line") end
LOG = {}
check(ma.join_offer(1, 1700, "l01_escape", "", 0) == true and ma.GUI.shown, "unreadable command line: the window")
check(log_count("command_line() failed") == 1, "the unreadable command line is in the log")
command_line = saved_command_line
ma.join_closed("world")
CMDLINE = '"x.exe" -coop_connect 127.0.0.1:27960'
LOG = {}
check(ma.join_offer(1, 1700, "l01_escape", "", 0) == true and ma.GUI.shown and ma.join_choice() == nil,
	"no -coop_autochoose: the window opens and waits for the player")
check(log_count("choice window open") == 1, "a closed window starts the log over: open again is in the log")
ma.join_closed("world")

-- join_offer returns false: the engine calls it again every 500 ms; the reason is logged once, not every time
local real_window = ma.UICoopNewChar
ma.GUI = nil
ma.UICoopNewChar = function() error("no dialog holder") end
LOG = {}
local falses = 0
for _ = 1, 5 do if ma.join_offer(1, 1700, "l01_escape", "", 0) == false then falses = falses + 1 end end
check(falses == 5, "a window that cannot open: false every time (the engine tries again)")
check(log_count("new character window failed") == 1 and log_count("no dialog holder") == 1, "its error logged once")
ma.UICoopNewChar = real_window
check(ma.join_offer(1, 1700, "l01_escape", "", 0) == true and ma.GUI.shown, "the window opens once it can")
check(log_count("choice window open") == 1, "and that is in the log")
ma.join_closed("world")

-- a Lua state without the engine's coop namespace: false, and the log says why (once)
local saved_coop = coop
coop = nil
local mn = load_module("coop_menu_char")
coop = saved_coop
LOG = {}
check(mn.join_offer(1, 1700, "l01_escape", "", 0) == false and mn.join_offer(1, 1700, "l01_escape", "", 0) == false,
	"no coop namespace: false")
check(log_count("no coop namespace") == 1, "no coop namespace: logged once")
command_line = nil
STASH = {}

-------------------------------------------------------------------------------
-- F3 Task 10: hardcore - the player out of the run starts a new character
-------------------------------------------------------------------------------
print("== F3 Task 10: a client out of a hardcore run is sent the world again and chooses in the game")
-- The host retired his character (things in a stash, key gone) and sent him SessionReset: the client is still in the
-- level (an actor exists), the session is receiving the world, and the host's offer comes as for a new player.
MODE = "client"
STASH = {}
NEWS = {}
SESSION = { active = true, phase = "receiving-world", nick = "Guest" }
PLAYERS = { { id = 1, nick = "Guest", is_self = true }, { id = 0, nick = "Boss" } }
db.actor = { give_game_news = function(self, cap, text) NEWS[#NEWS + 1] = text end }
CMDLINE = '"x.exe" -coop_connect 127.0.0.1:27960 -coop_autochoose bandit'
function command_line() return CMDLINE end
local mr = load_module("coop_menu_char")
mr.on_game_start()
LOG = {}
check(mr.join_offer(2, 700, "l01_escape", "", 0) == true and mr.GUI == nil,
	"retired, in the level: -coop_autochoose answers the host's offer at once, no window")
local rf, rb = mr.join_choice()
check(rf == "bandit" and rb == "", "retired: the engine gets the automatic choice (CharChoice)")
check(STASH.coop_char_joined == "bandit", "retired: the news of the new character waits for the new world")
check(log_count("test: offer answered at once with bandit") == 1, "retired: the automatic answer is in the log")
mr.join_closed("world")
CMDLINE = '"x.exe" -coop_connect 127.0.0.1:27960'
check(mr.join_offer(2, 700, "l01_escape", "", 0) == true and mr.GUI and mr.GUI.shown,
	"retired, no -coop_autochoose: the window opens over the level (the actor exists, the offer is a join offer)")
local gr = mr.GUI
check(gr.registered.btn_back.text == STRINGS.st_coop_char_btn_leave
	and gr.info.text == coop_menu.tr("st_coop_char_info_join", "Boss", "Guest"),
	"retired: the join texts (the character is made when Done is pressed, Leave ends the session)")
click(gr, "btn_start")
check(select(1, mr.join_choice()) == "stalker", "retired: Done gives the choice to the engine")
SESSION.phase = "loading-world"
NOW = NOW + 1000
gr:Update()
check(not gr.shown, "retired: the window follows the session (the new world loads)")

print("== F3 Task 10: the host's own new character")
MODE = "host"
SESSION = { active = true, phase = "hosting" }
CMDLINE = '"x.exe" -coop_host 27960'
STASH = {}
CALLBACKS, ADDED_CALLBACKS = {}, {}
local mh = load_module("coop_menu_char")
mh.on_game_start()
check(ADDED_CALLBACKS.coop_host_new_character and CALLBACKS.coop_host_new_character == mh.host_new_character,
	"the engine's callback coop_host_new_character is added and taken")
local hactor = make_npc(0, { 4001, 4002 }) -- what he picked up after standing up (his things are in the stash)
hactor.give_game_news = function(self, cap, text) NEWS[#NEWS + 1] = text end
db.actor = hactor
NPCS[0] = hactor
PLAYERS = { { id = 0, nick = "Boss", is_self = true, avatar_id = 0 }, { id = 1, nick = "Guest", avatar_id = 900 } }
ECO = 1 -- the old AK is bought in tier 1 only
SE[0] = nil
SE_OBJ[0] = { id = 0 }
SENT, NEWS, ORDER = {}, {}, {}
RELEASED, CREATED = {}, {}
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
check(not mh.is_new(0), "a playing host is not new")
check(select(2, mh.host_choose_self("bandit", "")) == "not_new", "no choice for himself without the engine's callback")
check(#MONEY_CALLS == 0 and #CREATED == 0, "... and nothing given")
CALLBACKS.coop_host_new_character()
check(mh.is_new(0), "the callback marks the host's actor new (kept in the save)")
local gh = mh.GUI
check(gh and gh.shown and gh.points_left == 1000 and gh.name.text == "Boss",
	"the window opens for the host: his tier's points, his nick")
check(#SENT == 0, "no event: the host is his own authority")
click(gh, "btn_faction")
click(gh, "btn_bandit")
local hidx
for i, ci in pairs(gh.CC.loadout.cell) do if ci.section == "wpn_ak74_old" then hidx = i end end
gh:On_CC_Mouse1("loadout", hidx)
check(table.concat(gh:Bought(), ",") == "wpn_ak74_old", "the host buys with his points")
MONEY_REFUSE = "no character"
click(gh, "btn_start")
check(gh.shown and gh.status.text:find(coop_menu.tr("st_coop_char_refused", STRINGS.st_coop_char_reason_busy), 1, true),
	"the ledger refuses: the window stays with the reason")
check(#CREATED == 0 and #RELEASED == 0 and hactor.community == "stalker" and mh.is_new(0),
	"money first: a refusal touches nothing and keeps the mark")
MONEY_REFUSE = nil
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
ORDER = {}
click(gh, "btn_start")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].fn == "money_set" and MONEY_CALLS[1].peer == 0
	and MONEY_CALLS[1].n == mh.faction_money("bandit") and MONEY_CALLS[1].ok, "the faction's money on the host's ledger entry")
check(ORDER[1] == "money_set" and ORDER[#ORDER] == "create", "money before the kit")
check(#RELEASED == 0, "nothing of his released: his things are in the stash, what he picked up since stays")
check(hactor.community == "actor_bandit", "the actor's community is actor_<faction>")
local hmade = {}
for _, c in ipairs(CREATED) do hmade[#hmade + 1] = c.sec .. (c.ammo and ("x" .. c.ammo) or "") end
local hmade_s = table.concat(hmade, ",")
check(CREATED[1] and CREATED[1].parent == 0 and hmade_s:find("trenchcoat_outfit", 1, true)
	and hmade_s:find("wpn_ak74_old", 1, true) and hmade_s:find("ammo_5.45x39_fmjx30", 1, true),
	"the kit, the bought gun and its ammo into db.actor (" .. hmade_s .. ")")
check(not mh.is_new(0) and not gh.shown, "done: the mark cleared, the window closed")
check(NEWS[#NEWS] == coop_menu.tr("st_coop_char_done", "st_faction_bandit"), "the host is told his new character")
check(select(2, mh.host_choose_self("bandit", "")) == "not_new", "a second choice is refused")
NOW = NOW + 70000
CALLBACKS.actor_on_update()
check(not gh.shown, "the host tick offers nothing after it is done")

-- Later: the window comes back a minute after it, and after a load (the mark is in the save)
CALLBACKS.coop_host_new_character()
check(gh.shown, "a new character again: the window")
NOW = NOW + 40000 -- he looks at it for a while
click(gh, "btn_back")
check(not gh.shown and NEWS[#NEWS]:find("again", 1, true), "Later closes it with the hint")
NOW = NOW + 30000
CALLBACKS.actor_on_update()
check(not gh.shown, "not before a minute")
NOW = NOW + 31000
CALLBACKS.actor_on_update()
check(gh.shown, "a minute after Later: the window again")
gh:Close()
local ml = load_module("coop_menu_char") -- a load: a fresh Lua state, the mark from the save
CALLBACKS = {}
ml.on_game_start()
NOW = NOW + 5000
CALLBACKS.actor_on_update()
check(ml.GUI and ml.GUI.shown, "after a load the window comes back for the marked host")
check(ml.host_choose_self("dolg", "") == true and not ml.is_new(0), "... and his choice is taken")

-- -coop_autochoose (unattended runs): the host's choice is made at once, no window
CMDLINE = '"x.exe" -coop_host 27960 -coop_autochoose freedom'
local mq = load_module("coop_menu_char")
CALLBACKS = {}
mq.on_game_start()
RELEASED, CREATED = {}, {}
LOG = {}
CALLBACKS.coop_host_new_character()
check(not mq.is_new(0) and mq.GUI == nil and hactor.community == "actor_freedom" and #CREATED > 0,
	"-coop_autochoose: the host's new character at once, no window")
check(log_count("test: the host's new character freedom (-coop_autochoose): made") == 1, "... and that is in the log")
CMDLINE = '"x.exe" -coop_host 27960'
MODE = "client"
check(select(2, mq.host_choose_self("bandit", "")) == "busy", "only a host chooses for himself")
mq.host_new_character()
check(not mq.is_new(0), "the callback on a client does nothing")
db.actor = nil
MODE = "host"
command_line = nil
STASH = {}

print("== F3 Task 10 fix round 1, Ruling F3-10: the new character of a retired key starts with nothing")
MODE = "host"
SESSION = { active = true, phase = "hosting" }
CMDLINE = '"x.exe" -coop_host 27960'
function command_line() return CMDLINE end
CALLBACKS = {}
local mb = load_module("coop_menu_char")
mb.on_game_start()
-- a client's character made before the world: the engine passes kit = false (coop_hardcore_new_kit off)
SE_OBJ[910] = { id = 910 }
CALLBACKS.se_stalker_on_spawn({ id = 910, section_name = function() return "coop_player_avatar" end,
	name = function() return "coop_player_avatar0910" end })
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
RELEASED, CREATED, NEWS = {}, {}, {}
local okb, moneyb, givenb = mb.host_make_character(1, 910, "bandit", "wpn_ak74_old", false)
check(okb == true and moneyb == 0 and givenb == 0 and #CREATED == 0, "no kit: nothing is given, not even what he bought")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].fn == "money_set" and MONEY_CALLS[1].peer == 1 and MONEY_CALLS[1].n == 0
	and MONEY_CALLS[1].ok, "no faction money: his balance on the ledger is 0")
check(not mb.is_new(910) and SE[910].coop_new_char_hook == nil, "made: not new, and no mods' starter kit either")
SE_OBJ[911] = { id = 911 }
CALLBACKS.se_stalker_on_spawn({ id = 911, section_name = function() return "coop_player_avatar" end,
	name = function() return "coop_player_avatar0911" end })
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
CREATED = {}
local okk, moneyk, givenk = mb.host_make_character(1, 911, "bandit", "", true)
check(okk == true and moneyk == mb.faction_money("bandit") and givenk == #CREATED and givenk > 3
	and MONEY_CALLS[1].n == mb.faction_money("bandit"), "coop_hardcore_new_kit on: the kit and the money as a new player")

-- the client's window: the host offers 0 points for a bare character
MODE = "client"
SESSION = { active = true, phase = "receiving-world", nick = "Guest" }
PLAYERS = { { id = 1, nick = "Guest", is_self = true }, { id = 0, nick = "Boss" } }
CMDLINE = '"x.exe" -coop_connect 127.0.0.1:27960'
db.actor = { give_game_news = function(self, cap, text) NEWS[#NEWS + 1] = text end }
local mc_b = load_module("coop_menu_char")
check(mc_b.join_offer(1, 0, "l01_escape", "", 0) == true and mc_b.GUI and mc_b.GUI.shown, "a bare offer opens the window")
local gb = mc_b.GUI
check(gb.CC.inventory.n == 0 and gb.CC.loadout.n == 0 and gb.points_left == 0, "a bare offer: no kit, nothing to buy")
check(gb.text_money.text == "0 RU" and gb.facts.text:find("0 RU", 1, true), "a bare offer: no faction money")
check(gb.info.text == coop_menu.tr("st_coop_char_info_bare"), "a bare offer: the window says why")
click(gb, "btn_faction")
click(gb, "btn_dolg")
check(gb.CC.inventory.n == 0 and gb.text_money.text == "0 RU", "another faction: still nothing")
click(gb, "btn_start")
local bf, bb = mc_b.join_choice()
check(bf == "dolg" and bb == "", "Done: the faction only")
mc_b.join_closed("world")

-- the host himself: the engine's callback says kit 0
MODE = "host"
SESSION = { active = true, phase = "hosting" }
CMDLINE = '"x.exe" -coop_host 27960'
db.actor = hactor
hactor.community = "stalker"
SE[0] = nil
CALLBACKS = {}
local mhb = load_module("coop_menu_char")
mhb.on_game_start()
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
RELEASED, CREATED = {}, {}
CALLBACKS.coop_host_new_character(0)
check(mhb.is_new(0) and mhb.GUI and mhb.GUI.shown, "the host's bare new character: the window")
local ghb = mhb.GUI
check(ghb.points_left == 0 and ghb.CC.inventory.n == 0 and ghb.text_money.text == "0 RU",
	"the host's bare window: no kit, no points, no money")
click(ghb, "btn_faction")
click(ghb, "btn_freedom")
click(ghb, "btn_start")
check(not mhb.is_new(0) and not ghb.shown and hactor.community == "actor_freedom", "chosen: the faction")
check(#CREATED == 0 and #RELEASED == 0 and #MONEY_CALLS == 0, "nothing given, nothing taken, his money stays (0 since the engine)")
local ml_b = load_module("coop_menu_char") -- a load before he chose keeps it bare
CALLBACKS = {}
ml_b.on_game_start()
CALLBACKS.coop_host_new_character(0)
local ml_b2 = load_module("coop_menu_char")
CALLBACKS = {}
ml_b2.on_game_start()
NOW = NOW + 5000
CALLBACKS.actor_on_update()
check(ml_b2.GUI and ml_b2.GUI.shown and ml_b2.GUI.points_left == 0, "after a load the host's window is still bare")
CREATED = {}
check(ml_b2.host_choose_self("bandit", "wpn_ak74_old") == true and #CREATED == 0, "bare after the load too")
CALLBACKS.coop_host_new_character(1)
check(ml_b2.GUI.points_left == 1000, "coop_hardcore_new_kit on: the host's window offers the kit")
CREATED = {}
check(ml_b2.host_choose_self("bandit", "") == true and #CREATED > 0, "... and gives it")
db.actor = nil
command_line = nil
STASH = {}

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
