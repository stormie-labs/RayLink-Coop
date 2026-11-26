-- A player's trade window is the host's window. On a player's copy the Lua inventory window of Anomaly
-- (ui_inventory, G.A.M.M.A.'s copy) opens as on the host, and scripts\coop_trade_window.script turns its Sell, Buy and Donate into one
-- deal for the decider (coop.trade_deal): no transfer_item, no give_money on the copy. Every other process keeps the stock window
-- untouched. The deal goes at the sums the window shows; the decider counts the same formula as for itself (host_price: no
-- with_identity, the functions utils_ui sums with, WPO by any player's hands through coop_mods_wpo_holder), and a refusal for its
-- price (code 10) makes the window tell so (on the HUD when it is closed), take the trader's profile again and draw itself anew
-- without closing the trader's view; no price of the decider is kept, and a press goes only at the sum its label shows.
-- Runs under every answer set (tests\lua\support\modes.lua): the set as it is (the co-op host, the world server, a map server,
-- single player), and, but in "none", the set's player's machine (a co-op client, a server's player).
-- Run: tools\test_lua.cmd trade_window
local modes = dofile("tests/lua/support/modes.lua")
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
for _, n in ipairs(MODE_FILES) do load_script(n) end
load_script("coop_npc_players")
for _, n in ipairs({ "GUI_on_show", "GUI_on_hide", "game_object_on_net_destroy" }) do AddScriptCallback(n) end

-- items, money and the ruck on the stand-in objects
local GO = getmetatable(make_actor(vec3(0, 0, 0)))
MONEY_CALLS = 0
function GO:money() return self._money or 0 end
function GO:give_money(n) MONEY_CALLS = MONEY_CALLS + 1; self._money = (self._money or 0) + n end
function GO:name() return self._sec .. "_" .. self._id end
function GO:iterate_ruck(f, o)
	for id, se in pairs(SE) do if se.parent_id == self._id and OBJ[id] and not OBJ[id]._slot then f(o, OBJ[id]) end end
end
TRANSFERS = 0
local stock_transfer = GO.transfer_item
function GO:transfer_item(item, to) TRANSFERS = TRANSFERS + 1; return stock_transfer(self, item, to) end

-- the engine's half
DEALS, VIEWS = {}, {}
local SEQ = 0
local REFUSE = nil
local function engine_api()
	coop.trade_deal = function(trader, sell, buy, flags, sp, bp, ss, bs)
		if REFUSE then return 0, REFUSE end
		SEQ = SEQ + 1
		DEALS[#DEALS + 1] = { seq = SEQ, trader = trader, sell = sell, buy = buy, flags = flags, sp = sp, bp = bp, ss = ss, bs = bs }
		return SEQ
	end
	coop.search_window = function(id, kind) VIEWS[#VIEWS + 1] = { id = id or "none", kind = kind } end
end
engine_api()

-- utils_item / trade_manager: the lists are set up by whoever db.actor is (SETUP_AS); the discounts are constants, as in G.A.M.M.A.
local CFG = { name = "items\\trade\\trade_generic.ltx" }
local MECH = "items\\trade\\trade_generic_mechanic.ltx"
local CFGS = { [CFG.name] = CFG, [MECH] = { name = MECH } }
TM = {}
SETUP_AS = {}
BUY_DISCOUNT = 0.5
ui_events = ui_events or { BUTTON_CLICKED = 17 }
PARTS = { prt_w_barrel_10 = 8250 } -- items\settings\part_prices.ltx [wpo_part_prices] (G.A.M.M.A.)
-- what WPO reads of a weapon: its parts (se_load_var), the threshold of its MCM
PARTS_OF = {}
function se_load_var(id, name, key) return key == "parts" and PARTS_OF[id] or nil end
function IsItem(kind, sec) return false end
a_arti_jamming_mcm = { get_config = function(k) return k == "minpart" and 0.5 or nil end }
-- Weapon Parts Overhaul's shape (a_wpo_parts.script:1-38): two wrappers of utils_item in the namespace a_wpo_parts, each falling back
-- to the function it found (GetCost / GetStatus); loaded with the engine's header (CScriptStorage file_header_old). The adapter
-- coop_mods_wpo_holder is loaded anew with it (it installs once per Lua state, as in the game).
local WPO_SRC = [[
GetCost = utils_item.get_item_cost
function utils_item.get_item_cost(obj, profile)
	local sec = obj:section()
	if profile.cfg == "items\\trade\\trade_generic_mechanic.ltx" and PARTS[sec] and obj:parent() and obj:parent():id() ~= 0 then
		return profile.discount * PARTS[sec]
	end
	return GetCost(obj, profile)
end
GetStatus = utils_item.get_item_trade_status
function utils_item.get_item_trade_status(obj, profile)
	if not (obj and profile) then return end
	if not (IsWeapon(obj) and (not IsItem("fake_ammo_wpn", obj:section()))) or (obj:parent() and obj:parent():id() ~= 0) then
		return GetStatus(obj, profile)
	end
	local parts = se_load_var(obj:id(), obj:name(), "parts")
	if not parts then return GetStatus(obj, profile) end
	local threshold = a_arti_jamming_mcm.get_config("minpart")
	for k, v in pairs(parts) do
		if string.find(k, "prt_w_") and v < threshold then return 2 end
	end
	return GetStatus(obj, profile)
end
]]
local function load_wpo()
	load_script("coop_mods_wpo_holder").on_game_start() -- its install runs before every pricing (before_pricing)
	local f = assert(loadstring("local this = {} a_wpo_parts = this setmetatable(this, {__index = _G}) setfenv(1, this) " .. WPO_SRC,
		"@a_wpo_parts.script"))
	f()
end
trade_manager = {
	get_trade_profile = function(id, k) local t = TM[id]; if k then return t and t[k] end return t end,
	get_trade_cfg = function(name) return CFGS[name] end,
	trade_init = function() end,
	setup_buy_sell_conditions = function(npc, id, config)
		SETUP_AS[#SETUP_AS + 1] = db.actor:id()
		TM[id].current_buy_condition = "buy_" .. db.actor:id()
		TM[id].current_sell_condition = "sell"
	end,
	get_buy_discount = function(id) return BUY_DISCOUNT end,
	get_sell_discount = function(id) return 1 end,
}
utils_item = {
	get_item_trade_status = function(obj, profile)
		if not (profile and profile.cfg) then return nil end
		return obj._status or 4
	end,
	get_item_cost = function(obj, profile)
		if obj._cost_error then error("cost of " .. obj:name()) end
		return (obj._cost or 0) * (profile.discount or 1)
	end,
}

-- G.A.M.M.A.'s utils_ui: file locals of utils_item's two functions taken when it loads (utils_ui.script:93-94), and
-- UICellContainer:GetCellCost sums a cell with its captured functions even if utils_item changes.
local function load_utils_ui()
	local get_item_trade_status = utils_item.get_item_trade_status
	local get_item_cost = utils_item.get_item_cost
	local UICellContainer = {}
	UICellContainer.__index = UICellContainer
	function UICellContainer:GetCellCost(ci)
		if not (ci and ci:IsShown() and self.trade_profile) then return 0 end
		local t_id = { [ci.ID] = true }
		for id in pairs(ci.childs) do t_id[id] = true end
		local tot = 0
		for id in pairs(t_id) do
			local o = level.object_by_id(id)
			if o and get_item_trade_status(o, self.trade_profile) == 4 then tot = tot + get_item_cost(o, self.trade_profile) end
		end
		return tot
	end
	utils_ui = { UICellContainer = UICellContainer }
end
load_utils_ui()

-- Sets the upvalue `name` of f; returns what it held.
local function set_upvalue(f, name, v)
	for i = 1, 255 do
		local n, old = debug.getupvalue(f, i)
		if n == nil then return nil end
		if n == name then
			debug.setupvalue(f, i, v)
			return old
		end
	end
end

-- a trade list of the window (utils_ui.UICellContainer): cells with stacks; every id of a stack is in indx_id
local function container(cells, mode, cfg)
	local cc = setmetatable({ indx_id = {}, cell = {}, trade_profile = { mode = mode, cfg = cfg or CFG.name, list = "l", discount = 1 } },
		utils_ui.UICellContainer)
	for idx, it in ipairs(cells) do
		local ci = { ID = it[1]:id(), childs = {} }
		function ci:IsShown() return true end
		cc.indx_id[it[1]:id()] = idx
		for k = 2, #it do ci.childs[it[k]:id()] = 1; cc.indx_id[it[k]:id()] = idx end
		cc.cell[idx] = ci
	end
	function cc:GetCell_ID(id) local i = self.indx_id[id]; return i and self.cell[i] end
	return cc
end

-- a bag of the window (actor_trade_bag, npc_trade_bag): what TMode_ResetInventories fills
local function bag()
	local b = { indx_id = {} }
	function b:RemoveItem(obj) self.indx_id[obj:id()] = nil end
	return b
end

-- ui_inventory.UIInventory as G.A.M.M.A. has it: the stock buttons move items and money here. Both bodies begin as G.A.M.M.A.'s
-- (ui_inventory.script:2783-2790, 2835-2840): Print, then the partner, and nothing happens without one.
local C = {}
local function fresh_ui()
	C = { sell = 0, buy = 0, donate = 0, info = 0, refresh = 0, reset = 0, profile = 0, snd = 0, closed = 0 }
	local UI = {}
	UI.__index = UI
	function UI:Print(mark, fmt, ...) end
	-- the engine's CUIDialogWndEx::AddCallback: one binding a control and event, a new one replaces it (UIScriptWnd.cpp)
	function UI:AddCallback(name, ev, f, o)
		self._cb = self._cb or {}
		self._cb[name .. "#" .. tostring(ev)] = { f = f, o = o }
	end
	-- G.A.M.M.A.'s __init -> InitCallbacks (ui_inventory.script:313-314, 559-560): the buttons are bound once, when the window is
	-- made, to the functions of the class as they are at that moment
	function UI:InitCallbacks()
		self:AddCallback("sell", ui_events.BUTTON_CLICKED, self.TMode_Sell, self)
		self:AddCallback("buy", ui_events.BUTTON_CLICKED, self.TMode_Buy, self)
	end
	function UI:GetPartner() return self.npc_id and level.object_by_id(self.npc_id) end
	function UI:CheckItem(obj) if type(obj) == "number" then obj = level.object_by_id(obj) end return obj end
	function UI:On_Item_Exchange(from, to, obj) from:transfer_item(obj, to) end
	function UI:TMode_Sell()
		self:Print(nil, "TMode_Sell")
		local npc = self:GetPartner()
		if (not npc) then return end
		C.sell = C.sell + 1
		for id in pairs(self.CC["actor_trade"].indx_id) do self:On_Item_Exchange(db.actor, npc, level.object_by_id(id)) end
		db.actor:give_money(100)
		npc:give_money(-100)
	end
	function UI:TMode_Buy()
		self:Print(nil, "TMode_Buy")
		local npc = self:GetPartner()
		if (not npc) then return end
		C.buy = C.buy + 1
		for id in pairs(self.CC["npc_trade"].indx_id) do self:On_Item_Exchange(npc, db.actor, level.object_by_id(id)) end
		npc:give_money(100)
		db.actor:give_money(-100)
	end
	function UI:Action_Donate(obj, bag)
		C.donate = C.donate + 1
		obj = self:CheckItem(obj)
		self:On_Item_Exchange(db.actor, get_object_by_id(self.npc_id), obj)
	end
	function UI:TMode_RefreshInventories() C.refresh = C.refresh + 1 end
	-- the stock refills both bags with all the actor and the trader hold, the items in the trade lists too (ui_inventory.script:2638)
	function UI:TMode_ResetInventories(only_bags)
		C.reset = C.reset + 1; C.reset_bags = only_bags
		local npc = self:GetPartner()
		local a, b = self.CC["actor_trade_bag"], self.CC["npc_trade_bag"]
		a.indx_id, b.indx_id = {}, {}
		for id, se in pairs(SE) do
			if OBJ[id] and se.parent_id == db.actor:id() then a.indx_id[id] = true end
			if OBJ[id] and npc and se.parent_id == npc:id() then b.indx_id[id] = true end
		end
	end
	function UI:TMode_InitProfile(npc) C.profile = C.profile + 1 end
	-- G.A.M.M.A.'s TMode_UpdatePrice (ui_inventory.script:2765-2781): the sum of the list's cells, one floor, on its label and button
	function UI:TMode_UpdatePrice(ele_txt, ele_btn, bag)
		self:Print(nil, "TMode_UpdatePrice | bag: %s", bag)
		local cc = self.CC[bag]
		if not cc then return end
		local tot = 0
		for _, ci in pairs(cc.cell) do tot = tot + cc:GetCellCost(ci) end
		tot = math.floor(tot)
		ele_txt:SetText(tot .. " RU")
		ele_btn:Enable(tot > 0)
	end
	-- G.A.M.M.A.'s UpdateInfo (ui_inventory.script:1401-1436): in a trade window both prices are counted again
	function UI:UpdateInfo(go)
		C.info = C.info + 1; C.info_go = go
		if self.mode == "trade" and self.player_trade_price then
			self:TMode_UpdatePrice(self.player_trade_price, self.player_trade_sell, "actor_trade")
			self:TMode_UpdatePrice(self.npc_trade_price, self.npc_trade_buy, "npc_trade")
		end
	end
	function UI:PlaySND(s) C.snd = C.snd + 1 end
	function UI:IsShown() return self.shown == true end
	function UI:Close() C.closed = C.closed + 1; self.shown = false; SendScriptCallback("GUI_on_hide", "UIInventory", "ui_inventory") end
	ui_inventory = { UIInventory = UI, is_enabled = function() return true end }
	return UI
end

-- callbacks_gameobject.on_game_start (callbacks_gameobject.script:929-940): wraps Sell and Buy before any window exists
local function gameobject_wraps(UI)
	local sell, buy = UI.TMode_Sell, UI.TMode_Buy
	UI.TMode_Sell = function(self) self.on_sell_callback_flag = true; sell(self); self.on_sell_callback_flag = false end
	UI.TMode_Buy = function(self) self.on_buy_callback_flag = true; buy(self); self.on_buy_callback_flag = false end
end

-- The window: made as G.A.M.M.A. makes it (UIInventory() binds its buttons), or `reuse`d (ui_inventory.GUI lives from the first open
-- of the inventory on: TMode_Init only fills it for a trade).
local function window(mode, npc, sell_cells, buy_cells, reuse, cfg)
	local ui = reuse
	if not ui then
		ui = setmetatable({ shown = true, CC = {} }, ui_inventory.UIInventory)
		ui:InitCallbacks()
	end
	ui.mode, ui.npc_id, ui.shown = mode, npc:id(), true
	ui.CC["actor_trade"] = container(sell_cells or {}, 1, cfg)
	ui.CC["npc_trade"] = container(buy_cells or {}, 2, cfg)
	ui.CC["actor_trade_bag"] = bag()
	ui.CC["npc_trade_bag"] = bag()
	ui.message_box = {
		InitMessageBox = function() end,
		SetText = function(_, t) MSGBOX = t end,
		ShowDialog = function() end,
	}
	-- the price labels and the buttons under the two trade lists (ui_inventory.script:362, 396)
	local function label() return { text = "", SetText = function(self, t) self.text = t end } end
	local function button() return { Enable = function(self, on) self.enabled = on end } end
	ui.player_trade_price, ui.npc_trade_price = label(), label()
	ui.player_trade_sell, ui.npc_trade_buy = button(), button()
	ui_inventory.GUI = ui
	return ui
end

-- A press of a button of the window: the engine calls what the button is bound to (CUIDialogWndEx::SendMessage).
local function press(ui, name)
	local cb = ui._cb and ui._cb[name .. "#" .. tostring(ui_events.BUTTON_CLICKED)]
	if not cb then return false end
	cb.f(cb.o)
	return true
end

local function bound(ui, name)
	local cb = ui._cb and ui._cb[name .. "#" .. tostring(ui_events.BUTTON_CLICKED)]
	return cb and cb.f
end

local function item(sec, parent, cost, opts)
	local _, o = spawn(sec, vec3(0, 0, 0), parent, { kind = "item" })
	o._cost = cost
	for k, v in pairs(opts or {}) do o[k] = v end
	return o
end

local function ids_of(list)
	local t = {}
	for _, id in ipairs(list or {}) do t[#t + 1] = id end
	table.sort(t)
	return table.concat(t, ",")
end

local function idset(...)
	local t = {}
	for _, o in ipairs({ ... }) do t[#t + 1] = o:id() end
	table.sort(t)
	return table.concat(t, ",")
end

-- the game's updates for `ms`: the actor's update and the time events, every 50 ms
local function run(ms)
	local stop = NOW + ms
	repeat
		NOW = NOW + 50
		SendScriptCallback("actor_on_update")
		for k, e in pairs(TIMEEV) do
			if TIMEEV[k] == e and e.at <= NOW and e.f(unpack(e.p)) then TIMEEV[k] = nil end
		end
	until NOW >= stop
end

local COPY = {
	leads_here = function() return false end, decides_world = function() return false end,
	actor_is_player = function() return true end, is_player_mirror = function() return true end,
	where = function() return "here" end, decider = function() return "other" end,
}

-- loaded and started once, as axr_main does in a Lua state; each set below gets a fresh window class
local tw = load_script("coop_trade_window")
local settings = load_script("coop_settings") -- apply_factor_table tells an open trade window
tw.on_game_start()

modes.each(coop_mode, function(name)
	print("== trade window (" .. name .. ")")

	-------------------------------------------------------------------------------------------------- the process as the set says
	local UI = fresh_ui()
	local stock_sell, stock_buy, stock_donate = UI.TMode_Sell, UI.TMode_Buy, UI.Action_Donate
	local stock_print, stock_partner = UI.Print, UI.GetPartner
	local ok, why = tw.ready()
	check(ok == false and type(why) == "string", name .. ": this process is no player's copy, the adapter says no (" .. tostring(why) .. ")")
	check(UI.TMode_Sell == stock_sell and UI.TMode_Buy == stock_buy and UI.Action_Donate == stock_donate,
		name .. ": the stock buttons stay as they are")
	tw.on_game_start()
	check(UI.TMode_Sell == stock_sell and UI.TMode_Buy == stock_buy and UI.Print == stock_print and UI.GetPartner == stock_partner,
		name .. ": the game's start takes nothing either")

	local _, trader = spawn("trader", vec3(1, 0, 0), nil, { kind = "stalker" })
	trader._money = 5000
	db.actor._money = 1000
	local a1 = item("medkit", 0, 100)
	local gui = window("trade", trader, { { a1 } }, {})
	VIEWS = {}
	SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
	check(#VIEWS == 1 and VIEWS[1].id == trader:id() and VIEWS[1].kind == 3, name .. ": the Lua trade window tells the engine its trader")
	SendScriptCallback("GUI_on_hide", "UIInventory", "ui_inventory")
	check(#VIEWS == 2 and VIEWS[2].id == "none", name .. ": and its close")

	-- host_price computes the sums as for the decider itself, without with_identity. The lists are set up by this
	-- machine's own actor (the co-op host's; a map server's service actor, no player), the functions utils_ui sums with
	local _, char = spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = 500, kind = "stalker" })
	TM[trader:id()] = { cfg_ltx = CFG.name }
	local s1 = item("bandage", 500, 300)
	local s2 = item("bread", 500, 50)
	local b1 = item("vodka", trader:id(), 200)
	local real_actor = db.actor
	local identity_calls = 0
	local saved_identity = coop_npc_players.with_identity
	coop_npc_players.with_identity = function(...) identity_calls = identity_calls + 1; return saved_identity(...) end
	SETUP_AS = {}
	local sell_total, buy_total = tw.host_price(500, trader:id(), { s1:id(), s2:id() }, { b1:id() })
	check(sell_total == 175 and buy_total == 200, name .. ": host_price adds the window's prices up (" ..
		tostring(sell_total) .. ", " .. tostring(buy_total) .. ")")
	check(identity_calls == 0 and SETUP_AS[1] == real_actor:id() and db.actor == real_actor,
		name .. ": no stand-in for the player: the trader's lists are set up by this machine's own actor (" .. tostring(SETUP_AS[1]) .. ")")
	if name == "srv_map" then
		check(coop_mode.actor_is_player() == false and sell_total == 175,
			name .. ": a map server decides with its service actor, no player's, and counts the same sums")
	elseif name == "hostplay" then
		check(coop_mode.actor_is_player() == true and sell_total == 175, name .. ": the co-op host decides with its own actor")
	end
	-- the very functions the window sums with: a function utils_ui holds is what host_price counts with
	local cell_cost = utils_ui.UICellContainer.GetCellCost
	local held = set_upvalue(cell_cost, "get_item_cost", function(obj, profile) return 3 * utils_item.get_item_cost(obj, profile) end)
	local s3, b3 = tw.host_price(500, trader:id(), { s1:id(), s2:id() }, { b1:id() })
	check(s3 == 3 * 175 and b3 == 3 * 200, name .. ": host_price counts with utils_ui's get_item_cost, as the window's sum (" ..
		tostring(s3) .. ", " .. tostring(b3) .. ")")
	set_upvalue(cell_cost, "get_item_cost", held)
	local held_status = set_upvalue(cell_cost, "get_item_trade_status", function() return 2 end)
	local s4, w4 = tw.host_price(500, trader:id(), { s1:id() }, {})
	check(s4 == nil and type(w4) == "string", name .. ": and with utils_ui's get_item_trade_status (" .. tostring(w4) .. ")")
	set_upvalue(cell_cost, "get_item_trade_status", held_status)
	-- Keep counting with_identity calls through the WPO checks below.
	local none_s, none_b = tw.host_price(500, trader:id(), {}, {})
	check(none_s == 0 and none_b == 0, name .. ": empty lists cost nothing")
	s2._status = 2
	local r, w = tw.host_price(500, trader:id(), { s1:id(), s2:id() }, {})
	check(r == nil and type(w) == "string", name .. ": an item the trader does not take refuses the price (" .. tostring(w) .. ")")
	s2._status = nil
	b1._slot = true
	r, w = tw.host_price(500, trader:id(), {}, { b1:id() })
	check(r == nil and type(w) == "string", name .. ": an item the trader keeps on him is not for sale")
	b1._slot = nil
	s1._cost_error = true
	r, w = tw.host_price(500, trader:id(), { s1:id() }, {})
	check(r == nil and db.actor == real_actor, name .. ": a Lua error refuses the price, no fallback")
	s1._cost_error = nil
	TM[trader:id()] = nil
	r = tw.host_price(500, trader:id(), { s1:id() }, {})
	check(r == nil, name .. ": a trader without a trade profile here gives no price")
	TM[trader:id()] = { cfg_ltx = CFG.name }
	check(tw.host_price(500, 4242, { s1:id() }, {}) == nil, name .. ": no trader here, no price")
	local theirs = item("bread", trader:id(), 50)
	r, w = tw.host_price(500, trader:id(), { theirs:id() }, {})
	check(r == nil and type(w) == "string", name .. ": the player sells only what his character holds (" .. tostring(w) .. ")")

	-- G.A.M.M.A.'s Weapon Parts Overhaul checks the holder (a_wpo_parts.script:8 prices a part outside the actor at
	-- the mechanic's list, :25 a weapon not held by the actor skips its busted-parts check). coop_mods_wpo_holder makes it "any
	-- player's hands": on the decider the player's character holds what he sells, and the decider counts what his window shows.
	local base_cost, base_status = utils_item.get_item_cost, utils_item.get_item_trade_status
	load_wpo()
	load_utils_ui() -- G.A.M.M.A.'s order: a_wpo_parts before utils_ui, whose file locals are WPO's functions
	local _, mech = spawn("mechanic", vec3(1, 0, 1), nil, { kind = "stalker" })
	TM[mech:id()] = { cfg_ltx = MECH }
	local barrel = item("prt_w_barrel_10", 500, 1237) -- worn: 1237 RU with its wear, as the window prices it
	local sold, why_sold = tw.host_price(500, mech:id(), { barrel:id() }, {})
	check(sold == 1237 * 0.5, name .. ": the decider prices a player's worn WPO part with its wear, as the player's window does, not " ..
		"at the mechanic's list (" .. tostring(sold) .. ", " .. tostring(why_sold) .. ")")
	check(barrel:parent():id() == 500 and identity_calls == 0 and db.actor == real_actor,
		name .. ": the part stays his character's, nothing stands in for him (with_identity called " .. tostring(identity_calls) .. " times)")
	local his = item("prt_w_barrel_10", mech:id(), 1237) -- the mechanic's own part: his list on both machines
	local _, bought = tw.host_price(500, mech:id(), {}, { his:id() })
	check(bought == 8250, name .. ": a part the mechanic sells goes at his list (" .. tostring(bought) .. ")")
	local ak = item("wpn_ak74", 500, 5000, { _kind = "weapon" })
	PARTS_OF[ak:id()] = { prt_w_barrel_ak = 0.1 }
	local r_ak, w_ak = tw.host_price(500, trader:id(), { ak:id() }, {})
	check(r_ak == nil and type(w_ak) == "string", name .. ": a player's weapon with a busted part is not bought: his window would not " ..
		"offer it (" .. tostring(r_ak) .. ", " .. tostring(w_ak) .. ")")
	PARTS_OF[ak:id()] = { prt_w_barrel_ak = 0.9 }
	check(tw.host_price(500, trader:id(), { ak:id() }, {}) == 5000 * 0.5, name .. ": a weapon whose parts are whole is")
	-- The wrapper counts with_identity calls from all host_price cases, including WPO.
	check(identity_calls == 0 and db.actor == real_actor, name .. ": no host_price of the WPO path put anyone in for the player (" ..
		tostring(identity_calls) .. ")")
	coop_npc_players.with_identity = saved_identity
	-- the actor's own (id 0): WPO as it is, on every machine
	SE[barrel:id()].parent_id = 0
	check(utils_item.get_item_cost(barrel, { cfg = MECH, discount = 1 }) == 1237, name .. ": the actor's own part costs its worn price")
	SE[ak:id()].parent_id = 0
	PARTS_OF[ak:id()] = { prt_w_barrel_ak = 0.1 }
	check(utils_item.get_item_trade_status(ak, { cfg = CFG.name }) == 2, name .. ": the actor's busted weapon: WPO's status 2 as it is")
	PARTS_OF[ak:id()] = nil
	utils_item.get_item_cost, utils_item.get_item_trade_status = base_cost, base_status
	rawset(_G, "a_wpo_parts", nil)
	load_utils_ui()
	for _, o in ipairs({ barrel, his, ak, theirs }) do release_id(o:id()) end

	-- coop_settings can change the buy or sell factor while the window is open: the window copies the trader's
	-- discounts at open and reads the profile again on any process.
	local ECO = { buy = 1, sell = 1, goodwill = 1 }
	game_difficulties = {
		get_eco_factor = function(k) return ECO[k] end, set_eco_factor = function(k, v) ECO[k] = v end,
		get_game_factor = function() return nil end, set_game_factor = function() end,
	}
	local fw = window("trade", trader, { { a1 } }, {})
	C.profile = 0
	settings.apply_factor_table({ e = { goodwill = 2 } }, "test")
	check(C.profile == 0 and ECO.goodwill == 2, name .. ": another economy factor leaves the trade window as it is")
	settings.apply_factor_table({ e = { buy = 1.5 } }, "test")
	check(C.profile == 1 and ECO.buy == 1.5, name .. ": a new buy factor: the open trade window reads the trader's profile again")
	settings.apply_factor_table({ e = { sell = 0.8 } }, "test")
	check(C.profile == 2, name .. ": a new sell factor too")
	settings.apply_factor_table({ e = { sell = 0.8 } }, "test")
	check(C.profile == 2, name .. ": the same value again changes nothing")
	fw.mode = "inventory"
	settings.apply_factor_table({ e = { buy = 1 } }, "test")
	check(C.profile == 2 and ECO.buy == 1, name .. ": no trade window open: nothing to read")
	rawset(_G, "game_difficulties", nil)

	if name == "none" then
		done("trade window (" .. name .. ")")
		return
	end

	------------------------------------------------------------------------------------------------------- the player's machine
	modes.install(coop_mode, name, COPY)

	-- G.A.M.M.A. binds Sell and Buy when the inventory window first opens, before the
	-- first trade; callbacks_gameobject has wrapped both before that. ready() comes with the trade, after the binding.
	UI = fresh_ui()
	gameobject_wraps(UI)
	trader._money, db.actor._money = 5000, 1000
	local early = window("inventory", trader) -- UIInventory() binds the buttons when the player opens the inventory
	local stale_sell, stale_buy = bound(early, "sell"), bound(early, "buy")
	check(stale_sell == UI.TMode_Sell, name .. " copy: the window's Sell is bound to the class's function of that moment")
	ok, why = tw.ready() -- he talks to a trader: StartTrade -> lua_trade_window_allowed -> ready()
	check(ok == true, name .. " copy: ready() with a window made before it (" .. tostring(why) .. ")")
	check(bound(early, "sell") ~= stale_sell and bound(early, "buy") ~= stale_buy,
		name .. " copy: ready() binds the open window's Sell and Buy again")
	local e1 = item("medkit", 0, 100)
	local e2 = item("vodka", trader:id(), 300)
	window("trade", trader, { { e1 } }, { { e2 } }, early) -- TMode_Init opens the trader in the same window
	SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
	DEALS, TRANSFERS, MONEY_CALLS = {}, 0, 0
	press(early, "sell")
	check(#DEALS == 1 and ids_of(DEALS[1].sell) == idset(e1) and DEALS[1].flags == 2,
		name .. " copy: the Sell button of a window made before ready() sends one deal")
	check(MONEY_CALLS == 0 and TRANSFERS == 0 and C.sell == 0, name .. " copy: and moves no money and no item here")
	tw.on_result(DEALS[1].seq, 0, 100, "ok")
	press(early, "buy")
	check(#DEALS == 2 and ids_of(DEALS[2].buy) == idset(e2) and MONEY_CALLS == 0 and TRANSFERS == 0 and C.buy == 0,
		name .. " copy: the Buy button too")
	tw.on_result(DEALS[2].seq, 0, -300, "ok")

	-- defence in depth: a button still bound to the stock body (a binding nobody replaced, a mod calling it) moves nothing on a copy;
	-- the press becomes ours: one deal
	DEALS, TRANSFERS, MONEY_CALLS = {}, 0, 0
	stale_sell(early)
	check(#DEALS == 1 and ids_of(DEALS[1].sell) == idset(e1), name .. " copy: a press of the stock Sell becomes one deal")
	check(MONEY_CALLS == 0 and TRANSFERS == 0 and C.sell == 0, name .. " copy: and the stock body stops before items and money")
	check(early.on_sell_callback_flag == false, name .. " copy: callbacks_gameobject's wrapper ends as it began")
	check(early:GetPartner() == trader, name .. " copy: the window's partner answers again right after")
	tw.on_result(DEALS[1].seq, 0, 100, "ok")
	stale_buy(early)
	check(#DEALS == 2 and ids_of(DEALS[2].buy) == idset(e2) and MONEY_CALLS == 0 and TRANSFERS == 0 and C.buy == 0,
		name .. " copy: the stock Buy as well")
	tw.on_result(DEALS[2].seq, 0, -300, "ok")
	-- a body that prints and never asks for its partner: the next update forgets the drop
	DEALS = {}
	early:Print(nil, "TMode_Buy")
	run(50)
	check(early:GetPartner() == trader, name .. " copy: a drop nobody took is gone at the next update")
	tw.on_result(DEALS[1].seq, 0, -300, "ok")

	-- the open window's buttons cannot be bound again: the copy keeps the engine window
	early.AddCallback = function() error("no binding") end
	ok, why = tw.ready()
	check(ok == false, name .. " copy: Sell and Buy that cannot be bound again: the engine window (" .. tostring(why) .. ")")
	early.AddCallback = nil
	SendScriptCallback("GUI_on_hide", "UIInventory", "ui_inventory")
	run(6000)

	-- the game starts on a player's copy: the buttons are ours before any window is made, even without a trade
	UI = fresh_ui()
	gameobject_wraps(UI)
	local cg_sell = UI.TMode_Sell
	tw.on_game_start()
	check(UI.TMode_Sell ~= cg_sell, name .. " copy: the game's start takes the window's buttons")
	local g1 = item("medkit", 0, 100)
	local started = window("trade", trader, { { g1 } }, {})
	DEALS, TRANSFERS, MONEY_CALLS = {}, 0, 0
	press(started, "sell")
	check(#DEALS == 1 and MONEY_CALLS == 0 and TRANSFERS == 0 and C.sell == 0,
		name .. " copy: a window made after the start sends its Sell as one deal")
	tw.on_result(DEALS[1].seq, 0, 100, "ok")
	run(6000)

	UI = fresh_ui()
	stock_sell, stock_buy, stock_donate = UI.TMode_Sell, UI.TMode_Buy, UI.Action_Donate

	local saved = coop.trade_deal
	coop.trade_deal = nil
	ok, why = tw.ready()
	check(not ok and UI.TMode_Sell == stock_sell, name .. " copy: an exe without coop.trade_deal keeps the engine window (" .. tostring(why) .. ")")
	coop.trade_deal = saved
	local saved_ui = ui_inventory
	ui_inventory = nil
	ok, why = tw.ready()
	check(not ok, name .. " copy: no Lua inventory window, the engine window (" .. tostring(why) .. ")")
	ui_inventory = saved_ui

	ok, why = tw.ready()
	check(ok == true and UI.TMode_Sell ~= stock_sell and UI.TMode_Buy ~= stock_buy and UI.Action_Donate ~= stock_donate,
		name .. " copy: the adapter takes the trade buttons (" .. tostring(why) .. ")")
	local mine = UI.TMode_Sell
	check(tw.ready() == true and UI.TMode_Sell == mine, name .. " copy: asked again, nothing is wrapped twice")
	-- a mod replaces a button after us: the next window takes it again
	local later = UI.TMode_Buy
	UI.TMode_Buy = function(self) return later(self) end
	check(tw.ready() == true and UI.TMode_Buy ~= later, name .. " copy: a button a mod wrapped after us is taken again")

	-- the window opens
	trader._money, db.actor._money = 5000, 1000
	local m1 = item("medkit", 0, 100)
	local m2 = item("medkit", 0, 100)
	local junk = item("medkit", 0, 100, { _status = 2 }) -- too worn: the stock gives it away in the stack for nothing
	local v1 = item("vodka", trader:id(), 300)
	gui = window("trade", trader, { { m1, m2, junk } }, { { v1 } })
	VIEWS = {}
	SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
	check(#VIEWS == 1 and VIEWS[1].kind == 3, name .. " copy: the trader's window is told to the engine")

	-- Sell: one deal, the traded items of every stack, no local move of items or money
	DEALS, TRANSFERS, MONEY_CALLS = {}, 0, 0
	gui:TMode_Sell()
	local d = DEALS[1]
	check(#DEALS == 1 and d.trader == trader:id() and ids_of(d.sell) == idset(m1, m2) and #d.buy == 0 and d.flags == 2,
		name .. " copy: Sell sends one deal with the stack's tradable items, flag 2 (Lua prices)")
	check(d.sp and #d.sp == 2 and d.sp[1] == 100 and d.sp[2] == 100, name .. " copy: with the window's item prices")
	check(d.ss == 200 and d.bs == 0, name .. " copy: and the sums the window shows (" .. tostring(d.ss) .. ", " .. tostring(d.bs) .. ")")
	check(TRANSFERS == 0 and MONEY_CALLS == 0 and C.sell == 0, name .. " copy: nothing moves here, the stock Sell does not run")
	gui:TMode_Sell()
	gui:TMode_Buy()
	check(#DEALS == 1, name .. " copy: while the deal waits for the decider, Sell and Buy wait too")

	-- the decider accepts: the window follows the items as they arrive
	C.info, C.snd = 0, 0
	tw.on_result(d.seq, 0, 200, "ok")
	check(C.snd == 1 and C.info >= 1 and C.info_go == true, name .. " copy: an accepted deal plays the trade sound and refreshes the window")
	local info = C.info
	SE[m1:id()].parent_id, SE[m2:id()].parent_id = trader:id(), trader:id()
	run(600)
	check(C.info > info, name .. " copy: the window is refreshed when the items arrive")
	info = C.info
	run(6000)
	check(C.info == info, name .. " copy: and then left alone")

	-- Buy: one deal; the decider refuses it
	DEALS = {}
	gui:TMode_Buy()
	d = DEALS[1]
	check(#DEALS == 1 and #d.sell == 0 and ids_of(d.buy) == idset(v1) and d.flags == 2 and d.bp[1] == 300 and d.bs == 300 and d.ss == 0,
		name .. " copy: Buy sends one deal for the trader's items")
	check(TRANSFERS == 0 and MONEY_CALLS == 0 and C.buy == 0, name .. " copy: nothing moves here")
	info = C.info
	tw.on_result(d.seq, 5, 0, "no money")
	check(C.info > info, name .. " copy: a refusal refreshes the window from what is really here")
	gui:TMode_Buy()
	check(#DEALS == 2, name .. " copy: after the answer the button works again")
	tw.on_result(DEALS[2].seq, 0, -300, "ok")

	-- the stock's own money checks stay before anything is sent
	DEALS, MSGBOX = {}, nil
	db.actor._money = 100
	gui:TMode_Buy()
	check(#DEALS == 0 and MSGBOX == "not_enough_money_actor", name .. " copy: not enough money: the stock's message, nothing sent")
	trader._money = 10
	gui:TMode_Sell()
	check(#DEALS == 0 and MSGBOX == "not_enough_money_partner", name .. " copy: the trader cannot pay: the stock's message")
	trader._money, db.actor._money = 5000, 1000

	-- the engine refuses to send it
	REFUSE = "an item id is no id"
	gui:TMode_Buy()
	REFUSE = nil
	gui:TMode_Buy()
	check(#DEALS == 1, name .. " copy: a deal the engine did not take leaves nothing waiting")
	tw.on_result(DEALS[1].seq, 0, -300, "ok")

	-- no answer at all
	DEALS = {}
	gui:TMode_Buy()
	run(16000)
	gui:TMode_Buy()
	check(#DEALS == 2, name .. " copy: a deal without an answer for 15 s no longer holds the buttons")
	tw.on_result(DEALS[2].seq, 0, -300, "ok")
	tw.on_result(DEALS[1].seq, 0, -300, "ok") -- a late answer to a forgotten deal: nothing happens
	run(600)

	-- The decider counts a purchase above the shown sum beyond the tolerance: refuse for its price (code 10, the
	-- decider's sums in the tail, for the log). Nothing agrees to the decider's price: the window tells so, takes the trader's profile
	-- again at once and draws itself anew. The next press sends the sum the window shows. coop_trade.cpp
	-- host_send_trader_view sends the trader's money and item states before the answer. Keep the view open because
	-- closing it revokes the trading computer's permit, whose grant is taken once.
	trader._money, db.actor._money = 5000, 1000
	local n1 = item("medkit", 0, 100)
	local n2 = item("vodka", trader:id(), 300)
	gui = window("trade", trader, { { n1 } }, { { n2 } }, gui)
	SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
	gui:UpdateInfo(true)
	check(gui.npc_trade_price.text == "300 RU" and gui.player_trade_price.text == "100 RU",
		name .. " copy: the window shows its own prices (" .. gui.npc_trade_price.text .. ", " .. gui.player_trade_price.text .. ")")
	local world = coop_core_world_trader
	local saved_ask = world.ask_trader
	local ASKED = {}
	world.ask_trader = function(npc, now) ASKED[#ASKED + 1] = { id = npc:id(), now = now } end
	-- the lines on this machine's HUD (coop_mods_core.hud -> actor_menu.set_msg)
	local HUDS = {}
	local saved_set_msg = actor_menu.set_msg
	actor_menu.set_msg = function(_, text) HUDS[#HUDS + 1] = text end
	local STALE = "Trade failed: the prices in the window were out of date, the window is refreshed"
	DEALS, MONEY_CALLS, TRANSFERS, VIEWS, MSGBOX = {}, 0, 0, {}, nil
	C.profile, C.reset, C.info = 0, 0, 0
	gui:TMode_Buy()
	check(#DEALS == 1 and DEALS[1].bs == 300, name .. " copy: Buy sends the 300 RU the window shows")
	tw.on_result(DEALS[1].seq, 10, 0, "PriceChanged", 0, 345)
	check(MSGBOX == STALE, name .. " copy: a refusal for its price is told in the window (" .. tostring(MSGBOX) .. ")")
	check(#HUDS == 0, name .. " copy: with the window open only the window tells it: nothing on the HUD (" .. tostring(HUDS[1]) .. ")")
	check(#ASKED == 1 and ASKED[1].id == trader:id() and ASKED[1].now == true,
		name .. " copy: the trader's profile is asked for at once, past the gap of 15 s")
	check(C.profile == 1 and C.reset == 1 and C.info >= 1, name .. " copy: the window reads the trader's profile again and draws itself anew")
	check(#VIEWS == 0, name .. " copy: the trader's view is not closed (" .. tostring(VIEWS[1] and VIEWS[1].id) .. ")")
	gui:UpdateInfo(true)
	check(gui.npc_trade_price.text == "300 RU", name .. " copy: no price of the decider is kept: the window shows its own (" ..
		gui.npc_trade_price.text .. ")")
	gui:TMode_Buy()
	check(#DEALS == 2 and DEALS[2].bs == 300 and ids_of(DEALS[2].buy) == idset(n2),
		name .. " copy: the buttons work at once; the next press sends what the window shows, not the decider's 345")
	check(MONEY_CALLS == 0 and TRANSFERS == 0, name .. " copy: nothing moved here")
	tw.on_result(DEALS[2].seq, 0, -300, "ok")
	run(600)
	check(#VIEWS == 0, name .. " copy: and nothing opens the view again later")

	-- a sale refused for its price: the same
	DEALS, ASKED, VIEWS, HUDS, MSGBOX = {}, {}, {}, {}, nil
	gui:TMode_Sell()
	check(#DEALS == 1 and DEALS[1].ss == 100, name .. " copy: Sell sends the 100 RU the window shows")
	tw.on_result(DEALS[1].seq, 10, 0, "PriceChanged", 80, 0)
	check(#ASKED == 1 and ASKED[1].now == true and #VIEWS == 0 and MSGBOX == STALE and #HUDS == 0,
		name .. " copy: a sale refused for its price takes the trader's profile again, its view stays open")
	gui:TMode_Sell()
	check(#DEALS == 2 and DEALS[2].ss == 100, name .. " copy: and the next Sell sends the window's 100 RU at once")
	tw.on_result(DEALS[2].seq, 5, 0, "no money")

	-- Another player or the decider can send item state after G.A.M.M.A. draws the labels. If the price differs
	-- from the label at the press, redraw the window and send nothing. The next press sends the newly shown sum.
	DEALS = {}
	gui:UpdateInfo(true)
	n2._cost = 400 -- the trader's vodka: its new state came, the label still shows 300 RU
	C.info = 0
	gui:TMode_Buy()
	check(#DEALS == 0 and C.info >= 1 and gui.npc_trade_price.text == "400 RU",
		name .. " copy: a purchase whose sum moved since its label was drawn is not sent, the window shows the new sum (" ..
		gui.npc_trade_price.text .. ")")
	gui:TMode_Buy()
	check(#DEALS == 1 and DEALS[1].bs == 400, name .. " copy: the next press sends the 400 RU the label shows now")
	tw.on_result(DEALS[1].seq, 5, 0, "no money")
	DEALS = {}
	n1._cost = 150 -- the player's medkit, the same on the sale's side
	gui:TMode_Sell()
	check(#DEALS == 0 and gui.player_trade_price.text == "150 RU",
		name .. " copy: a sale whose sum moved since its label was drawn is not sent either (" .. gui.player_trade_price.text .. ")")
	gui:TMode_Sell()
	check(#DEALS == 1 and DEALS[1].ss == 150, name .. " copy: the next Sell sends the 150 RU the label shows now")
	tw.on_result(DEALS[1].seq, 5, 0, "no money")
	n1._cost, n2._cost = 100, 300
	gui:UpdateInfo(true)
	check(gui.npc_trade_price.text == "300 RU" and gui.player_trade_price.text == "100 RU",
		name .. " copy: watching the labels changes none of them: the window draws its own sums")
	-- Wear makes the list's only item untradable after the label is drawn. The press redraws the sum as 0 RU
	-- and sends no deal while the label still shows 300 RU.
	DEALS = {}
	n2._status = 2
	gui:TMode_Buy()
	check(#DEALS == 0 and gui.npc_trade_price.text == "0 RU",
		name .. " copy: a list whose items all became untradable is drawn anew (" .. gui.npc_trade_price.text .. "), nothing is sent")
	n2._status = nil
	gui:UpdateInfo(true)
	check(gui.npc_trade_price.text == "300 RU", name .. " copy: and drawn back when the item is tradable again")

	-- With the window closed, a price refusal appears once on the HUD (the engine is silent for Lua window deals).
	-- The closed view stays closed and no new view is requested.
	DEALS, VIEWS, ASKED, HUDS, MSGBOX = {}, {}, {}, {}, nil
	gui:TMode_Buy()
	gui:Close()
	local after_close = #VIEWS
	tw.on_result(DEALS[1].seq, 10, 0, "PriceChanged", 0, 345)
	check(#HUDS == 1 and HUDS[1] == STALE and MSGBOX == nil,
		name .. " copy: a refusal for its price after the window closed is one line on the HUD (" .. tostring(HUDS[1]) .. ", " ..
		#HUDS .. ")")
	check(#ASKED == 0, name .. " copy: a refusal for its price without a window asks for nothing")
	run(600)
	check(#VIEWS == after_close and VIEWS[after_close].id == "none", name .. " copy: a closed window's view stays closed")
	-- The window shows another trader when the refusal arrives: the same
	local _, trader3 = spawn("trader_three", vec3(4, 0, 0), nil, { kind = "stalker" })
	gui = window("trade", trader, { { n1 } }, { { n2 } }, gui)
	gui:UpdateInfo(true)
	DEALS, ASKED, HUDS, MSGBOX = {}, {}, {}, nil
	gui:TMode_Buy()
	window("trade", trader3, {}, {}, gui)
	tw.on_result(DEALS[1].seq, 10, 0, "PriceChanged", 0, 345)
	check(#HUDS == 1 and MSGBOX == nil and #ASKED == 0,
		name .. " copy: a refusal for its price while the window shows another trader is one line on the HUD too")

	-- A trading computer opens the window without talk: its view carries the decider's permit,
	-- whose grant is taken once). A refusal for its price keeps that view open, so the next deal in the window still goes.
	gui = window("trade", trader, { { n1 } }, { { n2 } }, gui)
	VIEWS, ASKED, DEALS, HUDS, MSGBOX = {}, {}, {}, {}, nil
	SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
	check(#VIEWS == 1 and VIEWS[1].id == trader:id() and VIEWS[1].kind == 3 and #ASKED == 1 and ASKED[1].now ~= true,
		name .. " copy: the computer's window opens its view and asks for the profile no talk brought")
	gui:UpdateInfo(true)
	gui:TMode_Buy()
	tw.on_result(DEALS[1].seq, 10, 0, "PriceChanged", 0, 345)
	run(600)
	check(#VIEWS == 1 and MSGBOX == STALE and #HUDS == 0,
		name .. " copy: after a refusal for its price the view with the computer's permit is neither closed nor opened again")
	gui:TMode_Buy()
	check(#DEALS == 2 and DEALS[2].bs == 300 and ids_of(DEALS[2].buy) == idset(n2),
		name .. " copy: and the next deal in that window goes")
	tw.on_result(DEALS[2].seq, 5, 0, "no money")
	world.ask_trader = saved_ask
	actor_menu.set_msg = saved_set_msg
	SendScriptCallback("GUI_on_hide", "UIInventory", "ui_inventory")
	run(6000)

	-- Donate: gifts of one moment go as one gift deal (Unusable Parts Handler gives every broken part away when the window opens)
	DEALS, TRANSFERS = {}, 0
	local p1 = item("part", 0, 10)
	local p2 = item("part", 0, 10)
	gui:Action_Donate(p1, "actor_trade_bag")
	gui:Action_Donate(p2:id(), "actor_trade_bag")
	gui:Action_Donate(p1, "actor_trade_bag")
	check(#DEALS == 0 and TRANSFERS == 0 and C.donate == 0, name .. " copy: Donate moves nothing here, the stock Donate does not run")
	run(50)
	check(#DEALS == 1 and DEALS[1].flags == 1 and ids_of(DEALS[1].sell) == idset(p1, p2) and #DEALS[1].buy == 0,
		name .. " copy: the gifts of one moment leave as one gift deal at the next update, each item once")
	gui:Action_Donate(p2, "actor_trade_bag")
	run(50)
	check(#DEALS == 2 and ids_of(DEALS[2].sell) == idset(p2), name .. " copy: a later gift is a deal of its own")
	gui:TMode_Buy()
	check(#DEALS == 3, name .. " copy: gifts waiting for their answer do not hold Buy")
	tw.on_result(DEALS[1].seq, 0, 0, "ok")
	tw.on_result(DEALS[2].seq, 0, 0, "ok")
	tw.on_result(DEALS[3].seq, 0, -300, "ok")
	run(6000)

	-- another mode of the same window: the stock
	local loot = window("loot", trader, {}, {})
	loot:Action_Donate(p1, "actor_bag")
	check(C.donate == 1, name .. " copy: outside a trade window the stock runs")
	ui_inventory.GUI = gui

	-- The deal's ids, item prices and sum use the functions the window sums with (utils_ui's
	-- file locals): a mod that replaced utils_item.get_item_cost after utils_ui loaded changes none of them
	local w1 = item("medkit", 0, 100)
	local w2 = item("bread", 0, 50)
	gui = window("trade", trader, { { w1, w2 } }, {}, gui)
	local base_cost, base_status = utils_item.get_item_cost, utils_item.get_item_trade_status
	utils_item.get_item_cost = function(obj, profile) return 2 * base_cost(obj, profile) end
	utils_item.get_item_trade_status = function() return 2 end
	DEALS = {}
	gui:TMode_Sell()
	check(#DEALS == 1 and DEALS[1].ss == 150 and DEALS[1].sp[1] + DEALS[1].sp[2] == 150 and ids_of(DEALS[1].sell) == idset(w1, w2),
		name .. " copy: the ids, the item prices and the sum of the deal are the window's (" .. tostring(DEALS[1] and DEALS[1].ss) .. ")")
	utils_item.get_item_cost, utils_item.get_item_trade_status = base_cost, base_status
	tw.on_result(DEALS[1].seq, 5, 0, "no")
	-- a function utils_ui holds is what the deal prices with
	local held = set_upvalue(utils_ui.UICellContainer.GetCellCost, "get_item_cost", function(obj, profile)
		return 2 * base_cost(obj, profile)
	end)
	gui:UpdateInfo(true) -- the window draws its labels with that function (lua_flow#3: a press sends only the sum its label shows)
	DEALS = {}
	gui:TMode_Sell()
	check(#DEALS == 1 and DEALS[1].ss == 300 and DEALS[1].sp[1] + DEALS[1].sp[2] == 300,
		name .. " copy: the window's own price function prices the deal and its sum alike")
	set_upvalue(utils_ui.UICellContainer.GetCellCost, "get_item_cost", held)
	tw.on_result(DEALS[1].seq, 5, 0, "no")

	-- a worn WPO part sold to a mechanic: the actor holds it here (id 0), the window shows its worn price, and that sum and that item
	-- price go with the deal; the decider counts the same (host_price above: the part in his character's hands)
	load_wpo()
	load_utils_ui()
	local _, mech = spawn("mechanic", vec3(1, 0, 1), nil, { kind = "stalker" })
	mech._money = 50000
	local barrel = item("prt_w_barrel_10", 0, 1237)
	gui = window("trade", mech, { { barrel } }, {}, gui, MECH)
	DEALS = {}
	gui:TMode_Sell()
	check(#DEALS == 1 and ids_of(DEALS[1].sell) == idset(barrel) and DEALS[1].ss == 1237 and DEALS[1].sp[1] == 1237,
		name .. " copy: a worn WPO part goes for the 1237 RU the window shows (" .. tostring(DEALS[1] and DEALS[1].ss) .. ")")
	tw.on_result(DEALS[1].seq, 5, 0, "no")
	utils_item.get_item_cost, utils_item.get_item_trade_status = base_cost, base_status
	rawset(_G, "a_wpo_parts", nil)
	load_utils_ui()
	gui = window("trade", trader, {}, {}, gui)

	-- the trader's profile came from the decider after the window opened: read again, and the items in the trade lists stay out of
	-- the bags, as after the stock's own reset of the bags (ui_inventory.script:2065-2090)
	local q1 = item("medkit", 0, 100)
	local q2 = item("bread", 0, 50)
	local q3 = item("vodka", trader:id(), 300)
	gui = window("trade", trader, { { q1 } }, { { q3 } }, gui)
	C.profile, C.reset = 0, 0
	tw.on_profile(trader)
	check(C.profile == 1 and C.reset == 1 and C.reset_bags == true, name .. " copy: a late profile is read again by the open window")
	local abag, nbag = gui.CC["actor_trade_bag"].indx_id, gui.CC["npc_trade_bag"].indx_id
	check(not abag[q1:id()] and abag[q2:id()] and not nbag[q3:id()] and gui.CC["actor_trade"].indx_id[q1:id()] ~= nil,
		name .. " copy: what is in a trade list is not in a bag too")
	local _, other = spawn("trader_two", vec3(3, 0, 0), nil, { kind = "stalker" })
	tw.on_profile(other)
	check(C.profile == 1, name .. " copy: another trader's profile changes nothing")

	-- the trader goes away while the window shows it
	SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
	C.closed = 0
	SendScriptCallback("game_object_on_net_destroy", other)
	check(C.closed == 0, name .. " copy: another object going away changes nothing")
	SendScriptCallback("game_object_on_net_destroy", trader)
	check(C.closed == 1 and not gui:IsShown(), name .. " copy: the window closes before its trader goes")

	-- the co-op host's own window again (the same Lua state, a host): the wrapped buttons run the stock
	modes.install(coop_mode, name)
	gui = window("trade", trader, { { m1 } }, { { v1 } })
	DEALS = {}
	gui:TMode_Sell()
	check(#DEALS == 0 and C.sell == 1, name .. ": a process that is no copy runs the stock Sell through the wrapper")
	gui:Action_Donate(p2, "actor_trade_bag")
	check(#DEALS == 0 and C.donate == 2, name .. ": and the stock Donate")
	MONEY_CALLS = 0
	press(gui, "buy")
	check(#DEALS == 0 and C.buy == 1 and MONEY_CALLS == 2, name .. ": its Buy button runs the stock Buy, money and all")
	check(gui:GetPartner() == trader, name .. ": and its partner is always there")

	done("trade window (" .. name .. ")")
end)

-- coop_core_world_trader hands the late profile to the window and lets it ask for one without a talk
do
	local fh = assert(io.open("gamedata/scripts/coop_core_world_trader.script", "r"))
	local src = fh:read("*a")
	fh:close()
	check(src:find("coop_util.module(\"coop_trade_window\")", 1, true) ~= nil and src:find("on_profile", 1, true) ~= nil,
		"coop_core_world_trader: the profile from the decider reaches an open Lua trade window")
	check(src:find("\nfunction ask_trader(npc, now)", 1, true) ~= nil and src:find("if not now and trader_asked[id]", 1, true) ~= nil,
		"coop_core_world_trader: ask_trader(npc, now) for a window opened without a talk, at once after a refusal for its price (TZ R92)")
	local sh = assert(io.open("gamedata/scripts/coop_settings.script", "r"))
	local settings_src = sh:read("*a")
	sh:close()
	check(settings_src:find('rawget(_G, "coop_trade_window")', 1, true) ~= nil and settings_src:find("window.on_factors", 1, true) ~= nil,
		"coop_settings: new buy/sell factors reach an open trade window (TZ R92, W6)")
	local th = assert(io.open("gamedata/scripts/coop_trade_window.script", "r"))
	local window_src = th:read("*a")
	th:close()
	check(window_src:find("with_identity(", 1, true) == nil and window_src:find("as_actors", 1, true) == nil
		and window_src:find("agreed", 1, true) == nil and window_src:find("guards.TMode_UpdatePrice", 1, true) == nil,
		"coop_trade_window: no stand-in for the player, no price of the decider kept or shown (TZ R92)")
	-- Weapon Parts Overhaul pricing also preserves the actor's identity.
	local hh = assert(io.open("gamedata/scripts/coop_mods_wpo_holder.script", "r"))
	local holder_src = hh:read("*a")
	hh:close()
	check(#holder_src > 500 and holder_src:find("with_identity(", 1, true) == nil and holder_src:find("as_actors", 1, true) == nil,
		"coop_mods_wpo_holder: no stand-in for the player either (TZ R92)")
	-- A price refusal keeps the trader's view open to preserve a trading computer's permit.
	check(window_src:find("REOPEN_MS", 1, true) == nil and window_src:find("api.search_window()\n\t\treopen", 1, true) == nil,
		"coop_trade_window: the trader's view is not closed and opened again after a refusal for its price")
end

-- what the adapter reads of G.A.M.M.A.'s real window (the stand's scripts, read only; tools\test_lua.cmd sets GAMMA_SCRIPTS)
do
	local dir = os.getenv("GAMMA_SCRIPTS")
	local function read(name)
		local fh = dir and io.open(dir .. "/" .. name, "r")
		if not fh then return "" end
		local text = fh:read("*a")
		fh:close()
		return text
	end
	local inv, cells = read("ui_inventory.script"), read("utils_ui.script")
	local function has(text, what) return text:find(what, 1, true) ~= nil end
	check(has(inv, "function UIInventory:TMode_Sell()") and has(inv, "function UIInventory:TMode_Buy()")
		and has(inv, "function UIInventory:Action_Donate(obj, bag)") and has(inv, "function UIInventory:On_Item_Exchange(npc_from, npc_to, obj)"),
		"G.A.M.M.A. ui_inventory: the four functions the adapter takes")
	check(has(inv, 'self.CC["actor_trade"]') and has(inv, 'self.CC["npc_trade"]') and has(inv, "cc:GetCellCost(ci)")
		and has(inv, "for id,idx in pairs(cc.indx_id) do") and has(inv, 'self.message_box:InitMessageBox("message_box_ok")'),
		"G.A.M.M.A. ui_inventory: the trade lists, their sums and the message box as the adapter reads them")
	check(has(inv, "function UIInventory:TMode_InitProfile(npc)") and has(inv, "function UIInventory:TMode_ResetInventories(only_bags)")
		and has(inv, "function UIInventory:UpdateInfo(go)") and has(inv, "function is_enabled()"),
		"G.A.M.M.A. ui_inventory: profile, lists and refresh")
	check(has(inv, 'discount      = trade_manager.get_buy_discount(id)') and has(inv, 'discount        = trade_manager.get_sell_discount(id)')
		and has(inv, '"current_buy_item_condition_factor"') and has(inv, '"current_sell_item_exponent"'),
		"G.A.M.M.A. ui_inventory: the profile host_price rebuilds (TMode_InitProfile)")
	check(has(cells, "function UICellContainer:GetCellCost(ci)") and has(cells, "function UICellContainer:GetCell_ID(id, only_indx)")
		and has(cells, "self.indx_id[id] = indx"), "G.A.M.M.A. utils_ui: the cell container the adapter reads")
	-- The window binds the buttons at creation; ready() binds them again.
	check(has(inv, 'self:AddCallback("sell", ui_events.BUTTON_CLICKED, self.TMode_Sell, self)')
		and has(inv, 'self:AddCallback("buy"  , ui_events.BUTTON_CLICKED, self.TMode_Buy, self)'),
		"G.A.M.M.A. ui_inventory: Sell and Buy are bound in InitCallbacks")
	-- the defence in depth leans on how both stock bodies begin: Print, then the partner, and nothing before a missing one returns
	local function body(text, head)
		local at = text:find(head, 1, true)
		if not at then return "" end
		local stop = text:find("\nfunction ", at + 1, true)
		return text:sub(at, stop or #text)
	end
	for _, f in ipairs({ "TMode_Sell", "TMode_Buy" }) do
		local b = body(inv, "function UIInventory:" .. f .. "()")
		local p = b:find('self:Print(nil, "' .. f .. '")', 1, true)
		local g = b:find("local npc = self:GetPartner()", 1, true)
		local r = b:find("if (not npc) then\n\t\treturn", 1, true)
		local x = b:find("self:On_Item_Exchange(", 1, true)
		local m = b:find("give_money(", 1, true)
		check(p and g and r and x and m and p < g and g < r and r < x and x < m and not b:sub(1, g):find("[%w_]+%(", (p or 1) + 30),
			"G.A.M.M.A. ui_inventory: " .. f .. " prints, then takes its partner and returns without one, before items and money")
	end
	-- on_profile copies the stock's clean-up after a reset of the bags
	check(has(inv, "self:TMode_ResetInventories(true)") and has(inv, "cc_a2:RemoveItem(obj)") and has(inv, "cc_b2:RemoveItem(obj)"),
		"G.A.M.M.A. ui_inventory: the bags lose what the trade lists hold after TMode_ResetInventories(true)")
	-- the sum a deal carries is TMode_UpdatePrice's (every cell's GetCellCost, one floor), which UpdateInfo calls by name
	check(has(inv, "function UIInventory:TMode_UpdatePrice(ele_txt, ele_btn, bag)")
		and has(inv, 'self:TMode_UpdatePrice(self.player_trade_price, self.player_trade_sell, "actor_trade")')
		and has(inv, 'self:TMode_UpdatePrice(self.npc_trade_price, self.npc_trade_buy, "npc_trade")')
		and has(inv, 'ele_txt:SetText(tot_cost .. " RU")') and has(inv, "ele_btn:Enable( tot_cost > 0 )"),
		"G.A.M.M.A. ui_inventory: both prices are set by TMode_UpdatePrice from UpdateInfo")
	-- host_price and the deal use the same utils_item functions captured by utils_ui's window formula.
	check(has(cells, "local get_item_trade_status = utils_item.get_item_trade_status")
		and has(cells, "local get_item_cost         = utils_item.get_item_cost")
		and has(cells, "if obj and (get_item_trade_status(obj, self.trade_profile) == 4) then")
		and has(cells, "tot_cost = tot_cost + get_item_cost(obj, self.trade_profile)"),
		"G.A.M.M.A. utils_ui: GetCellCost sums with its file locals get_item_cost / get_item_trade_status")
	-- and Weapon Parts Overhaul looks at the id of the item's owner (coop_mods_wpo_holder: any player's hands are the actor's)
	local wpo = read("a_wpo_parts.script")
	check(has(wpo, "obj:parent() and obj:parent():id() ~= 0 then") and has(wpo, "local cost_final = discount * parts_list[sec]")
		and has(wpo, "(obj:parent() and obj:parent():id() ~= 0) then return GetStatus(obj, profile) end")
		and has(wpo, "GetCost = utils_item.get_item_cost") and has(wpo, "GetStatus = utils_item.get_item_trade_status")
		and has(wpo, 'local parts = se_load_var(obj:id(), obj:name(), "parts")')
		and has(wpo, 'local threshold = a_arti_jamming_mcm.get_config("minpart")'),
		"G.A.M.M.A. a_wpo_parts: the part price and the busted-parts check depend on the owner's id, as the adapter reads them")
end
print(string.format("%d passed, %d failed", PASSES, FAILS))
