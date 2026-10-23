-- Anomaly Coop temp test (W4 menu): coop_menu_char.script - new character offer, choice window, host check and
-- kit. Real configs\items\settings\new_game_loadouts.ltx from anomaly-ref, engine/UI stand-ins. Not shipped.
-- Game settings patch T7 (docs/GAME_SETTINGS.md section 8): the faction is the world's, the client does not choose it;
-- the kit is bought from that faction's list only; join_spawn says where the new player appears.
dofile("tests/lua/support/menu_stubs.lua")
dofile("tests/lua/support/stubs.d/money.lua") -- install_money_stubs: coop.money_* of the host ledger (F2 T1)

XML_FILES["ui_mm_faction_select.xml"] = xml_paths(REF .. "configs/ui/ui_mm_faction_select_16.xml")
XML_FILES["ui_coop_menu_char.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_menu_char_16.xml") -- 16:9 pair of the stock _16
local own43 = xml_paths(ROOT .. "configs/ui/ui_coop_menu_char.xml")
local p43 = xml_paths(REF .. "configs/ui/ui_mm_faction_select.xml")

STRINGS = {}
for _, file in ipairs({ "st_coop_menu.xml", "st_coop_char_world.xml" }) do -- T7: the world's faction texts have their own table
	local fh = assert(io.open(ROOT .. "configs/text/eng/" .. file, "r"))
	local src = fh:read("*a")
	fh:close()
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
end
game = { translate_string = function(id) return STRINGS[id] or id end }
coop_menu = load_module("coop_menu") -- for tr()

-- configs
STOCK_STARTS = REF .. "configs/plugins/new_game_start_locations.ltx"
STARTS_FILE = STOCK_STARTS -- a test may point the start list at another file before it loads a fresh module
function ini_file(name)
	if name == "plugins\\new_game_start_locations.ltx" then -- protocol 8: the faction starts of the stock new game
		return ini_over(STARTS_FILE)
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

-- the stock stand-in window has no rectangle and there is no cursor: every window is at 10,20 - 78,41 and the cursor at
-- CURSOR_POS (T7: the hint of the faction button, which is off; the engine's IsCursorOverWindow is false for a button
-- that is off, CUIButton::Enable(false) clears it, so the window compares the rectangle with the cursor)
CURSOR_POS = { x = 500, y = 500 }
function GetCursorPosition() return CURSOR_POS end
local window0 = window
function window(path)
	local w = window0(path)
	function w:GetAbsoluteRect(r) r.x1, r.y1, r.x2, r.y2 = 10, 20, 78, 41 end
	return w
end

-- T7: the faction of the world as the host's chain reads it. WORLD = coop_game_settings.world_faction() (T4's Lua; the
-- table nil or the function nil = missing), API_WORLD = the engine's coop.game.world_faction() ("" = none), JOIN_SPAWN =
-- the running game's coop/coop_session/join_spawn (nil = not in the record).
WORLD, API_WORLD, JOIN_SPAWN = "bandit", "", nil
coop_game_settings = {
	world_faction = function() return WORLD end,
	value = function(src, path) if src == "o" and path == "coop/coop_session/join_spawn" then return JOIN_SPAWN end end,
}

-- engine / world stand-ins
MODE = "host"
SENT = {}
PLAYERS = {}
coop = {
	is_active = function() return true end,
	is_host = function() return MODE == "host" end,
	is_client = function() return MODE == "client" end,
	is_world_server = function() return MODE == "host" end, -- F3a T6: the roles of the engine today (old meanings):
	is_player = function() return true end, -- the host process is the world server and a player, a client a player
	players = function() return PLAYERS end,
	avatar_of = function(peer) for _, p in ipairs(PLAYERS) do if p.id == peer then return p.avatar_id end end end,
	send_event = function(name, payload, target) SENT[#SENT + 1] = { name = name, t = PAYLOADS[payload], to = target }
		return true end,
	-- protocol 8 (the join flow): the session as the menu sees it, leaving it, strings kept for the session
	session_info = function() return SESSION end,
	disconnect = function() DISCONNECTS = DISCONNECTS + 1; SESSION = { active = false, phase = "off" }; return true end,
	stash_set = function(k, v) STASH[k] = v; return true end,
	stash_get = function(k) return STASH[k] end,
	game = { world_faction = function() return API_WORLD end }, -- T2: coop.game
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
-- F3a T6: the host player and the world server are one process; the events between them are from / to node 0 (the internal
-- channel), so the test carries the events sent to 0 to the handlers, the way the channel does
local function pump()
	local rounds = 0
	while rounds < 20 do
		local took = false
		for i, e in ipairs(SENT) do
			if e.to == 0 then
				table.remove(SENT, i)
				local h = coop_main.handlers[e.name]
				if h then h(coop_main.encode(e.t), 0, e.name) end
				took = true
				break
			end
		end
		if not took then return end
		rounds = rounds + 1
	end
end

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
function utils_ui.UIInfoItem()
	local o = { shown = false }
	function o:Update() end
	function o:Show(b) self.shown = b end
	return o
end
HINT = nil -- the last text the hint window was asked for (nil = hidden)
function utils_ui.UIHint() return { Update = function(_, txt) HINT = txt end } end

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
check(last().t.reason == "busy",
	"the client's faction is not read: zombied is no reason to refuse (the world's is bandit; the offline proxy: try again)")
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old,wpn_mp133" }, 1)
check(last().t.reason == "points", "points checked with the host's tier")
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 1)
check(last().t.reason == "busy", "offline proxy: try again")
deliver("menu.new_character", { faction = "bandit" }, 7)
check(last().t.reason == "no_character", "unknown peer")
-- F3a T6: node 0 is the host player, whose event is the client's event and is answered like any client's
deliver("menu.new_character", { faction = "bandit" }, 0)
check(last().name == "menu.char_result" and last().to == 0 and last().t.ok == false and last().t.reason == "not_new",
	"from the host player (node 0): answered like a client's - not_new while the host's character is not marked new")
SENT[#SENT] = nil

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

print("== T7: the old event path takes the world's faction (legacy_event_uses_world_faction)")
WORLD = "stalker"
check(mc.read_kit("stalker", 1).buy.wpn_ak74_old == nil and mc.read_kit("bandit", 1).buy.wpn_ak74_old ~= nil,
	"the premise of the tests below: the old AK is in the bandit shop only")
PLAYERS[#PLAYERS + 1] = { id = 3, nick = "Third", avatar_id = 502, rtt = 20 }
CALLBACKS.se_stalker_on_spawn({ id = 502, section_name = function() return "coop_player_avatar" end,
	name = function() return "coop_player_avatar0502" end })
NPCS[502] = make_npc(502, { 801 })
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 3)
check(last().t.ok == false and last().t.reason == "items" and mc.is_new(502),
	"buy_only_world_kit: the bandit shop is not the stalker world's: refused 'items', the mark stays")
RELEASED, CREATED = {}, {}
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
deliver("menu.new_character", { faction = "monolith", buy = "" }, 3)
check(last().t.ok == true and last().t.faction == "stalker" and last().to == 3,
	"legacy_event_uses_world_faction: the host's answer names the world's faction, not the monolith the client sent")
check(NPCS[502].community == "stalker", "the proxy's community is the world's")
local legacy = {}
for _, c in ipairs(CREATED) do legacy[#legacy + 1] = c.sec end
local legacy_s = table.concat(legacy, ",")
check(legacy_s:find("novice_outfit", 1, true) and not legacy_s:find("trenchcoat_outfit", 1, true),
	"the kit is the stalker world's (" .. legacy_s .. ")")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].n == mc.faction_money("stalker") and MONEY_CALLS[1].peer == 3,
	"the money is the world faction's")
check(NEWS[#NEWS]:find("st_faction_stalker", 1, true) ~= nil, "the host's news names the world's faction")
WORLD = "bandit"

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
deliver("menu.char_offer", { eco = 1, points = 1000, nick = "Guest", faction = "bandit" }, 0)
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
check(gui.where.text == "", "in the world (not a join offer) the 'where you appear' line stays empty")
check(gui.color_icon.tcolor ~= nil, "colour square tinted with the player's colour")
local diff_nodes = {}
for p in pairs(XML_FILES["ui_coop_menu_char.xml"]) do if not own43[p] then diff_nodes[#diff_nodes + 1] = p end end
for p in pairs(own43) do if not XML_FILES["ui_coop_menu_char.xml"][p] then diff_nodes[#diff_nodes + 1] = p end end
check(#diff_nodes == 0, "4:3 and 16:9 co-op layouts have the same nodes (" .. table.concat(diff_nodes, ",") .. ")")
-- T7: the faction is the world's, nothing to pick; buy the AK
check(gui.faction == "bandit" and gui.registered.btn_faction.enabled == false and gui.access,
	"offer_faction_fixed: the window shows the offer's faction (bandit); the faction button is off")
check(gui.world.text == coop_menu.tr("st_coop_char_world_faction", "st_faction_bandit"),
	"the caption names the world's faction (" .. tostring(gui.world.text) .. ")")
check(gui.info.text == coop_menu.tr("st_coop_char_world_info", "host", "Guest"), "the info text does not ask for a faction")
click(gui, "btn_faction")
check(gui.access == true and gui.registered.btn_bandit == nil and gui.registered.btn_dolg == nil and gui.faction == "bandit",
	"popup_never_opens: a click on the faction button changes nothing")
gui:OnFactionSelect("dolg")
check(gui.faction == "bandit", "a faction select that does come (a stale callback) is ignored")
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
check(g2.faction == "stalker", "an offer with no faction (an old host): the window shows stalker, never an empty faction")
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

JOIN_SPAWN = "faction_start" -- the starts of the faction, as before join_spawn (the default is the host)
local plan = mc.host_plan_character(1, "bandit", "wpn_ak74_old")
check(plan.ok == true and plan.where == "start:car_park" and plan.gvid == 440 and plan.lvid == 436975
	and math.abs(plan.x - 106.27) < 1e-6 and math.abs(plan.y + 2.86) < 1e-6, "bandit: at the bandit start of the host's level")
check(plan.faction == "bandit" and plan.money == 1000, "the faction and its money")
local ignored = mc.host_plan_character(1, "zombied", "")
check(ignored.ok == true and ignored.faction == "bandit" and ignored.where == "start:car_park",
	"the faction the engine passes is not read (zombied): the plan is the world's")
check(mc.host_plan_character(1, "bandit", "wpn_ak74_old,wpn_mp133").reason == "points", "points of the host's tier")
check(mc.host_plan_character(1, "bandit", "wpn_pm").reason == "items", "the free kit cannot be bought")
local junk = mc.host_plan_character(1, 7, nil)
check(junk.ok == true and junk.faction == "bandit", "junk from the engine is not read either, and is not an error")

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
WORLD = "dolg"
local dolg = mc.host_plan_character(2, "dolg", "")
check(dolg.ok and dolg.where == "camp:esc_smart_terrain_2_12" and dolg.gvid == 454 and dolg.lvid == 5454
	and dolg.x == -200, "Duty, host on Cordon: the nearest Duty base of Cordon (not a lair, not another level or faction)")
SIMBOARD = nil
local alone = mc.host_plan_character(2, "dolg", "")
check(alone.ok and alone.where == nil and alone.gvid == nil, "nothing of the faction here: no point (next to the host)")
WORLD = "bandit"
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

print("== T7: the world's faction and where the new player appears (docs/GAME_SETTINGS.md section 8)")
-- the chain: coop_game_settings.world_faction() -> coop.game.world_faction() -> the host actor's community -> stalker
host_actor.character_community = function() return COMMUNITY end
COMMUNITY = "actor_monolith"
WORLD, API_WORLD = "dolg", "army"
check(mc.world_faction() == "dolg", "world_faction: the game settings' record first")
coop_game_settings.world_faction = nil
check(mc.world_faction() == "army", "no world_faction in the settings script (T4 not there): the engine's coop.game.world_faction")
local gs0 = coop_game_settings
coop_game_settings = nil
check(mc.world_faction() == "army", "no settings script at all: the same")
coop_game_settings = gs0
coop_game_settings.world_faction = function() return WORLD end
WORLD = nil
check(mc.world_faction() == "army", "the settings know none (nil): the engine's")
WORLD, API_WORLD = "zombied", "a b"
check(mc.world_faction() == "monolith", "names nobody may pick (zombied, a b) are passed over: the host actor's community")
API_WORLD = ""
WORLD = ""
check(mc.world_faction() == "monolith", "'' is none: the host actor's community without the actor_ prefix")
local coop_game0 = coop.game
coop.game = nil
check(mc.world_faction() == "monolith", "no coop.game in this engine: the community")
coop.game = coop_game0
COMMUNITY = "trader"
check(mc.world_faction() == "stalker", "nothing usable anywhere: stalker, as the engine's character_faction")
db.actor = nil
check(mc.world_faction() == "stalker", "no actor: stalker")
db.actor = host_actor
WORLD = "bandit"

-- host_plan_ignores_client_faction: a hostile client says monolith in a stalker world
WORLD, JOIN_SPAWN = "stalker", "faction_start"
local mono = mc.host_plan_character(1, "monolith", "wpn_svt40")
local stalker_plan = mc.host_plan_character(1, "stalker", "wpn_svt40")
check(mono.ok == true and mono.faction == "stalker" and mono.money == mc.faction_money("stalker"),
	"host_plan_ignores_client_faction: the plan is the stalker world's (faction and money)")
check(mono.where ~= nil and mono.where == stalker_plan.where and mono.gvid == stalker_plan.gvid,
	"... and so is the start: the same as when stalker is named")
check(mc.host_plan_character(1, "stalker", "wpn_ak74_old").reason == "items"
	and mc.host_plan_character(1, "bandit", "wpn_ak74_old").reason == "items",
	"buy_only_world_kit: a bandit shop item is refused in a stalker world, whoever is named")
check(mc.host_plan_character(1, "monolith", "wpn_svt40,wpn_svt40").reason == "items",
	"the stalker shop sells one SVT: two are refused")

-- join_spawn
local asked = {}
local host_start0 = mc.host_start
mc.host_start = function(f) asked[#asked + 1] = f; return host_start0(f) end
mc.host_plan_character(1, "monolith", "")
check(#asked == 1 and asked[1] == "stalker",
	"join_spawn_faction_start: the start is host_start(world faction), not the client's monolith (" .. table.concat(asked, ",") .. ")")
JOIN_SPAWN, asked = "host", {}
local at_host = mc.host_plan_character(1, "monolith", "")
check(at_host.ok == true and at_host.where == nil and at_host.x == nil and at_host.y == nil and at_host.z == nil
	and at_host.lvid == nil and at_host.gvid == nil and #asked == 0,
	"join_spawn_host_no_point: rule 'host': no point (the engine puts him next to the host), no start asked")
check(at_host.faction == "stalker" and at_host.money == mc.faction_money("stalker"), "... but the plan itself is the same")
JOIN_SPAWN, asked = "nowhere", {}
check(mc.host_plan_character(1, "monolith", "").where == nil and #asked == 0, "a value the rule does not know is 'host'")
JOIN_SPAWN, asked = nil, {}
check(mc.host_plan_character(1, "monolith", "").where == nil and #asked == 0, "no rule in the record, no option: 'host' (the default)")
-- the rule from the machine's option while no record answers (a game from before the record, the host's own settings)
axr_main.config:w_value("options", "coop/coop_session/join_spawn", "faction_start")
check(mc.join_spawn() == "faction_start" and mc.host_plan_character(1, "monolith", "").where ~= nil,
	"no record: the option coop/coop_session/join_spawn of the host's config (faction_start)")
JOIN_SPAWN = "host"
check(mc.join_spawn() == "host", "the record wins over the option")
axr_main.config:w_value("options", "coop/coop_session/join_spawn", nil)
JOIN_SPAWN = nil
check(mc.join_spawn() == "host", "option gone: host")
mc.host_start = host_start0
WORLD, JOIN_SPAWN = "bandit", "faction_start"

-- the offer the host sends inside the world carries the world's faction too
MODE = "host"
PLAYERS = { { id = 0, nick = "host", is_self = true, avatar_id = 0 }, { id = 1, nick = "Guest", avatar_id = 500, rtt = 20 } }
SE[500] = { coop_new_char = true }
SENT = {}
NOW = NOW + 200000
CALLBACKS.actor_on_update()
check(#SENT == 1 and SENT[1].name == "menu.char_offer" and SENT[1].t.faction == "bandit",
	"the old event offer names the world's faction")
SE[500] = {}

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
-- T7 host_make_uses_world_faction: the engine passes the faction it resolved, the Lua reads the world's itself
WORLD = "stalker"
RELEASED, CREATED = {}, {}
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
local ok_w, money_w = mc.host_make_character(1, 900, "monolith", "")
local made_w = {}
for _, c in ipairs(CREATED) do made_w[#made_w + 1] = c.sec end
local made_ws = table.concat(made_w, ",")
check(ok_w == true and money_w == mc.faction_money("stalker") and made_ws:find("novice_outfit", 1, true)
	and not made_ws:find("trenchcoat_outfit", 1, true),
	"host_make_uses_world_faction: the kit and the money are the stalker world's, not what was passed (" .. made_ws .. ")")
check(#MONEY_CALLS == 1 and MONEY_CALLS[1].n == mc.faction_money("stalker"), "the ledger gets the world faction's money")
check(NEWS[#NEWS]:find("st_faction_stalker", 1, true) ~= nil, "the news names the world's faction")
check(select(2, mc.host_make_character(1, 900, "bandit", "wpn_ak74_old")) == "items",
	"buy_only_world_kit: the bandit shop item in a stalker world is refused at the make step too")
WORLD = "bandit"
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
RELEASED, CREATED = {}, {}

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
-- the stock names of the start points (configs\text\<lang>\ui_st_faction_starts.xml)
STRINGS.ui_st_rookie_village = "Rookie Village (Cordon)"
STRINGS.ui_st_pole_stalker_village = "Khutorok (Meadow)"
check(mj.join_choice() == nil, "no choice before an offer")
check(mj.join_offer(2, 700, "l01_escape", "", 0, "stalker") == true, "the offer opens the window in the main menu (no actor)")
local gj = mj.GUI
check(gj and gj.shown and gj.points_left == 700, "window with the host's points")
check(gj.name.text == "Guest" and gj.info.text == coop_menu.tr("st_coop_char_world_info_join", "Boss", "Guest"),
	"the join text: the character is made when Done is pressed; it does not ask for a faction")
check(gj.faction == "stalker" and gj.registered.btn_faction.enabled == false
	and gj.world.text == coop_menu.tr("st_coop_char_world_faction", "st_faction_stalker"),
	"offer_faction_fixed: the faction of the offer, the faction button off, the caption says whose it is")
do
	local sk, free_set, foreign = mj.read_kit("stalker", 2), {}, 0
	for _, sec in ipairs(sk.free) do free_set[sec] = true end
	for _, ci in pairs(gj.CC.loadout.cell) do if not sk.buy[ci.section] then foreign = foreign + 1 end end
	for _, ci in pairs(gj.CC.inventory.cell) do if not free_set[ci.section] then foreign = foreign + 1 end end
	check(foreign == 0 and gj.CC.loadout.n > 0 and gj.CC.inventory.n > 0,
		"the lists are the world's kit only (stalker), nothing of another faction's")
end
check(gj.status.text:find(STRINGS.st_coop_char_ready_join, 1, true) ~= nil, "join hint in the status line")
check(gj.registered.btn_back.text == STRINGS.st_coop_char_btn_leave, "the second button leaves the session")
check(gj.box_map.texture == "ui_new_game_map_l01_escape" and gj.box_map.shown, "the host's level picture")
check(gj.where.text:find("You will appear at: ", 1, true) and gj.where.text:find("Rookie Village (Cordon)", 1, true),
	"stalker: the line says where, by the stock name of the start on Cordon")
check(gj.start.text == "", "the short start line is left to the 'where' line in a join offer")
click(gj, "btn_faction")
check(gj.faction == "stalker" and gj.access and gj.registered.btn_dolg == nil,
	"popup_never_opens: before the world too, the click changes nothing")
mj.join_offer(2, 700, "l01_escape", "", 0, "dolg") -- a world of Duty: the host's offer names it
check(gj.faction == "dolg" and gj.where.text:find(STRINGS.st_coop_char_where_camp_or_near, 1, true),
	"Duty: no Duty start on Cordon and the client does not know the camps: a camp there, or next to the host")
local camp_known0 = mj.camp_known
mj.camp_known = function(f, lvl) return f == "dolg" and lvl == "l01_escape" end
mj.join_offer(2, 700, "l01_escape", "", 0, "dolg")
check(gj.where.text:find(coop_menu.tr("st_coop_char_where_camp", "st_faction_dolg"), 1, true),
	"Duty with a camp known on Cordon: the base is on another map, the camp of the faction")
mj.camp_known = function() return false end
mj.join_offer(2, 700, "l01_escape", "", 0, "dolg")
check(gj.where.text:find(STRINGS.st_coop_char_where_near, 1, true), "Duty with no camp on Cordon: next to the host")
mj.camp_known = camp_known0
check(gj.world.text == coop_menu.tr("st_coop_char_world_faction", "st_faction_dolg") and gj.registered.btn_faction.enabled == false,
	"the caption follows the offer's faction, the button stays off")
mj.join_offer(2, 700, "l01_escape", "", 0, "zombied")
check(gj.faction == "stalker", "a faction nobody may pick in an offer (zombied): stalker, so the window never lists a kit it cannot buy")
mj.join_offer(2, 700, "l01_escape", "", 0, "dolg")
-- the hint of the button that is off: only while the cursor is on it
CURSOR_POS = { x = 30, y = 30 }
gj:Update()
check(HINT == STRINGS.st_coop_char_world_locked, "the cursor on the faction button: the hint says the world sets it (" .. tostring(HINT) .. ")")
CURSOR_POS = { x = 500, y = 500 }
gj:Update()
check(HINT == nil, "the cursor elsewhere: no hint")
-- Live 2026-10-23 (build 7, GAMMA): a mod's tooltip (zzz_craft_use_in_tooltip_mcm patches UIInfoItem:Update) needs a
-- loaded game and fails before the world. utils_ui's UICellContainer:Update asks the tooltip BEFORE it marks the cell
-- hovered (On_Hover), so no cell was ever hovered, no click reached On_CC_Mouse1 and the choice went out with 0 bought.
-- T7: the cells ask the window's stand-in (gj.tip), which asks gj.item_info at every call.
do
	local hovered, info_calls = 0, 0
	local real = {}
	for name, cc in pairs(gj.CC) do
		real[name] = cc.Update
		cc.Update = function(self, item_info)
			if item_info then item_info:Update(nil, "bandage", {}) end -- utils_ui: the tooltip first ...
			hovered = hovered + 1 -- ... then On_Hover
			return true
		end
	end
	local info0 = gj.item_info
	gj.item_info = { shown = true, Update = function() info_calls = info_calls + 1; error("attempt to index upvalue 'ini_craft' (a nil value)") end,
		Show = function(self, b) self.shown = b end }
	gj.item_info.shown = true -- the tooltip is on the screen when it fails
	local ok_upd, err_upd = pcall(gj.Update, gj)
	check(ok_upd, "a failing mod tooltip does not break the window's update (" .. tostring(err_upd) .. ")")
	check(gj.item_info.shown == false, "T7: the tooltip that failed is hidden, not left half-built on the screen")
	check(hovered >= 1, "the cells are still hovered without the tooltip: clicks reach On_CC_Mouse1 (" .. hovered .. ")")
	local calls = info_calls
	pcall(gj.Update, gj)
	check(info_calls == calls, "the failing tooltip is not asked again (no error every frame)")
	for name, cc in pairs(gj.CC) do cc.Update = real[name] end
	gj.item_info = info0
	gj.info_broken = nil
end

-- Build 9 (owner's log, 7 times): zzz_craft_use_in_tooltip_mcm replaces UIInfoItem:Update with a function that reads
-- ini_craft, which the mod fills in its on_game_start, never run in the main menu. The mod keeps the stock function as
-- og_info_item_update (a field of its module): before the world the window's tooltip uses it. With a world, or without
-- the mod, nothing changes.
do
	local calls = { stock = {}, mod = 0 }
	local info0 = gj.item_info
	local info = { shown = false, Show = function(self, b) self.shown = b end,
		Update = function() calls.mod = calls.mod + 1; error("attempt to index upvalue 'ini_craft' (a nil value)") end }
	gj.item_info, gj.info_broken = info, nil
	zzz_craft_use_in_tooltip_mcm = { og_info_item_update = function(self, obj, sec, flags)
		calls.stock[#calls.stock + 1] = { self = self, obj = obj, sec = sec, flags = flags }
	end }
	db.actor = nil
	local flags = { value = 5 }
	gj.tip:Update(nil, "bandage", flags)
	check(#calls.stock == 1 and calls.stock[1].self == info and calls.stock[1].sec == "bandage" and calls.stock[1].flags == flags
		and calls.mod == 0, "mod tooltip, no world: the stock Update runs on the window's UIInfoItem, the mod's is not called")
	gj.tip:Update()
	check(#calls.stock == 2 and calls.stock[2].sec == nil and calls.mod == 0,
		"... for the hide call too (no item under the cursor)")
	-- through the window's own Update, with a cell under the cursor
	local real = {}
	for name, cc in pairs(gj.CC) do
		real[name] = cc.Update
		cc.Update = function(self, item_info) item_info:Update(nil, "wpn_pm", {}); return true end
	end
	local n = #calls.stock
	pcall(gj.Update, gj)
	check(#calls.stock > n and calls.mod == 0 and not gj.info_broken, "the window's update: no error, the tooltip is not given up")
	for name, cc in pairs(gj.CC) do cc.Update = real[name] end
	-- with a world the mod's Update works (its on_game_start ran): the window asks it
	db.actor = { give_game_news = function() end }
	info.Update = function() calls.mod = calls.mod + 1 end
	local before = #calls.stock
	gj.tip:Update(nil, "bandage", {})
	check(calls.mod == 1 and #calls.stock == before, "mod tooltip, world loaded: the mod's Update is used (recipes in the tooltip)")
	-- the mod is not there, or an older one without the stock function kept: the tooltip itself
	db.actor = nil
	zzz_craft_use_in_tooltip_mcm = nil
	gj.tip:Update(nil, "bandage", {})
	check(calls.mod == 2 and #calls.stock == before, "no mod: the tooltip's own Update")
	zzz_craft_use_in_tooltip_mcm = {}
	gj.tip:Update(nil, "bandage", {})
	check(calls.mod == 3, "the mod without og_info_item_update: the tooltip's own Update")
	zzz_craft_use_in_tooltip_mcm = nil
	gj.item_info, gj.info_broken = info0, nil
	db.actor = nil
end
click(gj, "btn_start")
check(#SENT == 0, "no script event: the engine takes the choice")
local jf, jb = mj.join_choice()
check(jf == "dolg" and jb == "", "the engine gets faction and bought gear")
check(mj.join_choice() == nil, "taken once")
check(STASH.coop_char_joined == "dolg", "kept for the news in the world (the load rebuilds Lua)")
check(gj.btn_start.enabled == false and gj.status.text:find("Waiting for the host...", 1, true), "waiting for the world")
check(mj.join_offer(2, 700, "l01_escape", "points", 0, "dolg") == true, "refused: offered again")
check(gj.shown and gj.btn_start.enabled and gj.faction == "dolg"
	and gj.status.text:find(coop_menu.tr("st_coop_char_refused", STRINGS.st_coop_char_reason_points), 1, true),
	"the refusal shown, the choice kept, Done again")
gj:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(gj.shown, "Escape does not leave the session")
click(gj, "btn_faction")
gj:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(gj.shown and gj.access, "Escape after a click on the (off) faction button: still the window, still not leaving")
mj.join_offer(2, 700, "l01_escape", "", 1, "bandit") -- the host's game is in story mode
check(gj.where.text:find(STRINGS.st_coop_char_where_camp_or_near, 1, true) and not gj.where.text:find("car_park", 1, true),
	"story mode: the bandit start of story mode is elsewhere")
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
check(gj.where.text == "", "no level: nothing to say about the host's map")
click(gj, "btn_back")
check(not gj.shown and DISCONNECTS == 1, "Leave closes the window and the session")
SESSION = { active = true, phase = "receiving-world", nick = "Guest" }
mj.join_offer(2, 700, "l01_escape", "", 0)
SESSION = { active = false, phase = "off" }
NOW = NOW + 1000
gj:Update()
check(not gj.shown, "the session ended (kicked, host gone): the window closes")

print("== client: where the character appears (owner, live test 2026-10-23: Clear Sky came up in the rookie village)")
-- Until split levels (F3a) every player is on the host's map. GAMMA gives Clear Sky two starts: hidden_base on the Great
-- Swamps and rookie_village on Cordon; the host was on Cordon, so the village was used, and the window did not say so.
do
	local fh = assert(io.open(STOCK_STARTS, "r"))
	local stock_src = fh:read("*a")
	fh:close()
	local gamma_src, n_csky = stock_src:gsub("(%[csky_start_locations%][^\n]*\n)", "%1rookie_village = l01_escape\n")
	check(n_csky == 1, "GAMMA start list for the test: Clear Sky also starts in the rookie village")
	local out = assert(io.open("temp/menu_char_gamma_starts.ltx", "w"))
	out:write(gamma_src)
	out:close()
end
STARTS_FILE = "temp/menu_char_gamma_starts.ltx"
SESSION = { active = true, phase = "receiving-world", nick = "Guest" }
db.actor = nil
do
local mg = load_module("coop_menu_char")
mg.faction_starts("csky", false) -- the module reads the list on first use and keeps it
STARTS_FILE = STOCK_STARTS
STRINGS.ui_st_hidden_base = "Hidden Base (Great Swamps)"
STRINGS.ui_st_southern_checkpoint = "Southern Checkpoint (Cordon)"
STRINGS.k00_marsh = "Great Swamps"
STRINGS.l01_escape = "Cordon"
check(STRINGS.st_coop_char_where_start == "You will appear at: %s"
	and STRINGS.st_coop_char_where_near == "You will appear next to the host"
	and STRINGS.st_coop_char_where_camp:find("another map", 1, true) and STRINGS.st_coop_char_where_split,
	"the strings of the 'where' line are in the English table")

local starts_g = mg.faction_starts("csky", false)
check(#starts_g == 2 and starts_g[1].id == "rookie_village" and starts_g[2].id == "hidden_base",
	"the test list: Clear Sky has a start on Cordon and one on the Great Swamps")

-- the pure part: kind of the line, the starts it names
local kind, info = mg.start_preview("csky", "l01_escape", false)
check(kind == "start" and #info.here == 1 and info.here[1].id == "rookie_village"
	and #info.away == 1 and info.away[1].id == "hidden_base",
	"Clear Sky, host on Cordon: the rookie village here, the hidden base on another map")
kind, info = mg.start_preview("csky", "k00_marsh", false)
check(kind == "start" and #info.here == 1 and info.here[1].id == "hidden_base" and #info.away == 1,
	"Clear Sky, host on the Great Swamps: the hidden base")
check(mg.start_preview("dolg", "l01_escape", false, function() return nil end) == "camp_or_near",
	"no start here and the camps unknown: a camp or next to the host")
check(mg.start_preview("dolg", "l01_escape", false, function(f, l) return f == "dolg" and l == "l01_escape" end) == "camp",
	"no start here, a camp of the faction on the host's map")
check(mg.start_preview("dolg", "l01_escape", false, function() return false end) == "near",
	"no start here, no camp: next to the host")
check(mg.start_preview("nope", "l01_escape", false, function() return false end) == "near",
	"a faction with no start list at all: next to the host")
local asked
mg.start_preview("dolg", "l01_escape", false, function(f, l) asked = f .. "@" .. l end)
check(asked == "dolg@l01_escape", "the camp question names the faction and the host's map")

local main, note = mg.where_text("csky", "l01_escape", false)
check(main == "You will appear at: Rookie Village (Cordon)"
	and note == "For now all players are on the host's map. Your own map comes with the \"split maps\" update.",
	"Clear Sky on Cordon: the village by its stock name, and why not the faction's base")
main, note = mg.where_text("csky", "k00_marsh", false)
check(main == "You will appear at: Hidden Base (Great Swamps)" and note ~= nil,
	"Clear Sky on the Great Swamps: the base; the village of Cordon is the other map")
main, note = mg.where_text("stalker", "l01_escape", true)
check(main == "You will appear at: Rookie Village (Cordon)" and note == nil,
	"story mode lists one stalker start, all on the host's map: no note about other maps")
main, note = mg.where_text("army", "l01_escape", false)
check(main == "You will appear at: Southern Checkpoint (Cordon)" and note ~= nil,
	"Army on Cordon: the checkpoint; Agroprom is another map")
STRINGS.ui_st_hidden_base = nil
main = mg.where_text("csky", "k00_marsh", false)
check(main == "You will appear at: Great Swamps", "no stock name for the point: the name of its map")
STRINGS.k00_marsh = nil
main = mg.where_text("csky", "k00_marsh", false)
check(main == "You will appear at: k00_marsh", "no name for the map either: its code")
STRINGS.ui_st_hidden_base = "Hidden Base (Great Swamps)"
STRINGS.k00_marsh = "Great Swamps"
main, note = mg.where_text("dolg", "l01_escape", false, function() return true end)
check(main == "Your faction's base is on another map; you will appear at a st_faction_dolg camp on the host's map"
	and note == nil, "the camp text names the faction")
main = mg.where_text("dolg", "l01_escape", false, function() return false end)
check(main == "You will appear next to the host", "no start, no camp")
check(mg.where_text("csky", nil, false) == nil, "the host's map unknown: nothing to say")

-- the string tables: every id in both languages, CRLF kept, the Russian one in cp1251
for _, lang in ipairs({ "eng", "rus" }) do
	local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_menu.xml", "rb"))
	local src = fh:read("*a")
	fh:close()
	for _, id in ipairs({ "start", "camp", "near", "camp_or_near", "split" }) do
		check(src:find('<string id="st_coop_char_where_' .. id .. '">', 1, true) ~= nil, lang .. " has st_coop_char_where_" .. id)
	end
	check(src:find("\r\n", 1, true) ~= nil and not src:find("[^\r]\n"), lang .. " string table keeps CRLF line ends")
	check(not src:find("st_coop_char_start_faction", 1, true) and not src:find("st_coop_char_start_camp", 1, true),
		lang .. ": the strings of the old start line are gone")
	if lang == "rus" then
		check(src:find("\207\238\255\226\232\248\252\241\255: %s", 1, true) ~= nil, "rus: cp1251 bytes, not UTF-8 (Poyavish'sya: %s)")
	end
end

-- the window
check(mg.join_offer(2, 700, "l01_escape", "", 0, "stalker") == true, "the offer opens the window")
local gw = mg.GUI
mg.join_offer(2, 700, "l01_escape", "", 0, "csky")
check(gw.where.text:find("You will appear at: Rookie Village (Cordon)", 1, true)
	and gw.where.text:find("split maps", 1, true) and gw.where.text:find("host's map", 1, true),
	"window, Clear Sky on Cordon: the village and the split-maps note")
mg.join_offer(2, 700, "l01_escape", "", 0, "army")
check(gw.where.text:find("Southern Checkpoint (Cordon)", 1, true), "window, a faction with a start on the host's map")
mg.camp_known = function() return false end
mg.join_offer(2, 700, "l01_escape", "", 0, "dolg")
check(gw.where.text:find("You will appear next to the host", 1, true) and not gw.where.text:find("split maps", 1, true),
	"window, a faction with no start and no camp: next to the host")
mg.join_offer(2, 700, "k00_marsh", "", 0, "csky")
check(gw.where.text:find("Hidden Base (Great Swamps)", 1, true), "window, the offer names another host map: the base")
mg.join_closed("world")
end

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
-- T7: the faction of the answer is the offer's (the world's); the flag only asks for an unattended answer
check(ma.join_offer(1, 1700, "l01_escape", "", 0, "dolg") == true and ma.GUI == nil, "autochoose with a world faction: answered at once, no window")
local wf, wb = ma.join_choice()
check(wf == "dolg" and wb == "", "autochoose_uses_offer_faction: dolg (the offer's), not stalker (the flag's)")
check(STASH.coop_char_joined == "dolg", "... and the news in the world names it")
check(ma.join_offer(1, 1700, "l01_escape", "", 0, "zombied") == true and select(1, ma.join_choice()) == "stalker",
	"autochoose, the offer's faction is not one anybody may pick: the flag's")
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
	and gr.info.text == coop_menu.tr("st_coop_char_world_info_join", "Boss", "Guest"),
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
-- F3a T6: the world server offers the choice to the host player with the event a client's in-world offer is (node 0)
check(#SENT == 1 and SENT[1].name == "menu.char_offer" and SENT[1].to == 0 and SENT[1].t.renew == true
	and SENT[1].t.faction == "bandit" and SENT[1].t.points == 1000, "the world server offers it to the host player over menu.char_offer")
check(mh.GUI == nil, "... and opens no window itself")
pump()
local gh = mh.GUI
check(gh and gh.shown and gh.points_left == 1000 and gh.name.text == "Boss",
	"the window opens for the host: his tier's points, his nick")
check(#SENT == 0, "the offer was taken: no event is left")
check(gh.faction == "bandit" and gh.registered.btn_faction.enabled == false
	and gh.world.text == coop_menu.tr("st_coop_char_world_faction", "st_faction_bandit"),
	"the host's window shows the world's faction (bandit), nothing to pick")
local hidx
for i, ci in pairs(gh.CC.loadout.cell) do if ci.section == "wpn_ak74_old" then hidx = i end end
gh:On_CC_Mouse1("loadout", hidx)
check(table.concat(gh:Bought(), ",") == "wpn_ak74_old", "the host buys with his points")
MONEY_REFUSE = "no character"
click(gh, "btn_start")
check(#SENT == 1 and SENT[1].name == "menu.new_character" and SENT[1].to == 0 and #MONEY_CALLS == 0 and #CREATED == 0,
	"Done sends menu.new_character to node 0, the client's event; the player's branch gives nothing itself")
pump()
check(gh.shown and gh.status.text:find(coop_menu.tr("st_coop_char_refused", STRINGS.st_coop_char_reason_busy), 1, true),
	"the ledger refuses: the window stays with the reason")
check(#CREATED == 0 and #RELEASED == 0 and hactor.community == "stalker" and mh.is_new(0),
	"money first: a refusal touches nothing and keeps the mark")
MONEY_REFUSE = nil
for i = #MONEY_CALLS, 1, -1 do MONEY_CALLS[i] = nil end
ORDER = {}
click(gh, "btn_start")
pump()
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
pump()
check(gh.shown, "a new character again: the window")
NOW = NOW + 40000 -- he looks at it for a while
click(gh, "btn_back")
check(not gh.shown and NEWS[#NEWS]:find("again", 1, true), "Later closes it with the hint")
NOW = NOW + 30000
CALLBACKS.actor_on_update()
pump()
check(not gh.shown, "not before a minute")
NOW = NOW + 31000
CALLBACKS.actor_on_update()
pump()
check(gh.shown, "a minute after Later: the window again")
gh:Close()
local ml = load_module("coop_menu_char") -- a load: a fresh Lua state, the mark from the save
CALLBACKS = {}
ml.on_game_start()
NOW = NOW + 5000
CALLBACKS.actor_on_update()
pump()
check(ml.GUI and ml.GUI.shown, "after a load the window comes back for the marked host")
-- F3a T6: his choice is the client's event from node 0; the answer closes his window
deliver("menu.new_character", { faction = "dolg", buy = "" }, 0)
check(SENT[#SENT].name == "menu.char_result" and SENT[#SENT].t.ok == true and not ml.is_new(0), "... and his choice is taken")
pump()
check(not ml.GUI.shown, "... the answer closes his window")
check(hactor.community == "actor_bandit", "host_self_uses_world_faction: dolg (what was passed) is not read, the world's bandit is")
WORLD = "freedom"
hactor.community = "stalker"
ml.host_new_character()
pump()
check(ml.is_new(0) and ml.GUI.faction == "freedom", "the next new character of the host: the window shows the world's faction")
deliver("menu.new_character", { faction = "monolith", buy = "" }, 0)
pump()
check(hactor.community == "actor_freedom" and not ml.is_new(0),
	"host_self_uses_world_faction: monolith passed, the world's freedom given")
WORLD = "bandit"

-- -coop_autochoose (unattended runs): the host's choice is made at once, no window
CMDLINE = '"x.exe" -coop_host 27960 -coop_autochoose freedom'
local mq = load_module("coop_menu_char")
CALLBACKS = {}
mq.on_game_start()
RELEASED, CREATED = {}, {}
LOG = {}
CALLBACKS.coop_host_new_character()
pump() -- F3a T6: the offer goes to the host player, whose handler answers the flag with the client's event
check(not mq.is_new(0) and mq.GUI == nil and hactor.community == "actor_bandit" and #CREATED > 0,
	"-coop_autochoose: the host's new character at once, no window, in the world's faction (not the flag's freedom)")
check(log_count("test: offer answered at once with bandit (-coop_autochoose)") == 1, "... and that is in the log")
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
check(gb.info.text == coop_menu.tr("st_coop_char_world_info_bare"), "a bare offer: the window says why")
mc_b.join_offer(1, 0, "l01_escape", "", 0, "dolg")
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
WORLD = "freedom"
CALLBACKS.coop_host_new_character(0)
check(SENT[#SENT].name == "menu.char_offer" and SENT[#SENT].to == 0 and SENT[#SENT].t.bare == true and SENT[#SENT].t.points == 0,
	"the host's bare new character: the offer to the host player is bare (no points)")
pump()
check(mhb.is_new(0) and mhb.GUI and mhb.GUI.shown, "the host's bare new character: the window")
local ghb = mhb.GUI
check(ghb.points_left == 0 and ghb.CC.inventory.n == 0 and ghb.text_money.text == "0 RU",
	"the host's bare window: no kit, no points, no money")
check(ghb.faction == "freedom", "the host's bare window: the world's faction")
click(ghb, "btn_start")
pump()
check(not mhb.is_new(0) and not ghb.shown and hactor.community == "actor_freedom", "chosen: the faction")
WORLD = "bandit"
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
pump()
check(ml_b2.GUI and ml_b2.GUI.shown and ml_b2.GUI.points_left == 0, "after a load the host's window is still bare")
CREATED = {}
deliver("menu.new_character", { faction = "bandit", buy = "wpn_ak74_old" }, 0) -- F3a T6: the client's event from node 0
pump()
check(not ml_b2.is_new(0) and #CREATED == 0, "bare after the load too")
CALLBACKS.coop_host_new_character(1)
pump()
check(ml_b2.GUI.points_left == 1000, "coop_hardcore_new_kit on: the host's window offers the kit")
CREATED = {}
deliver("menu.new_character", { faction = "bandit", buy = "" }, 0)
pump()
check(not ml_b2.is_new(0) and #CREATED > 0, "... and gives it")
db.actor = nil
command_line = nil
STASH = {}

-- T7: the table of the world's faction texts: every id in both languages, CRLF kept, the Russian one in cp1251
print("== T7: string table st_coop_char_world.xml")
for _, lang in ipairs({ "eng", "rus" }) do
	local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_char_world.xml", "rb"))
	local src = fh:read("*a")
	fh:close()
	for _, id in ipairs({ "st_coop_char_world_faction", "st_coop_char_world_locked", "st_coop_char_world_info",
		"st_coop_char_world_info_join", "st_coop_char_world_info_bare" }) do
		check(src:find('<string id="' .. id .. '">', 1, true) ~= nil, lang .. " has " .. id)
	end
	check(src:find("\r\n", 1, true) ~= nil and not src:find("[^\r]\n"), lang .. " world table keeps CRLF line ends")
	check(src:find('<?xml version="1.0" encoding="windows-1251"?>', 1, true) == 1, lang .. " world table declares windows-1251")
	check(src:find("%s", 1, true) ~= nil, lang .. " world table keeps its %s")
	if lang == "rus" then
		check(src:find("\195\240\243\239\239\232\240\238\226\234\224 \236\232\240\224: %s", 1, true) ~= nil,
			"rus: cp1251 bytes, not UTF-8 (Gruppirovka mira: %s)")
		check(not src:find("\208\147", 1, true), "rus: no UTF-8 lead bytes")
	end
end
check(STRINGS.st_coop_char_world_faction == "World faction: %s. The host chose it when creating the game",
	"the eng caption names the faction and who chose it")

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
