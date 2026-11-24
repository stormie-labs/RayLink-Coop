-- Anomaly Coop (TZ R90): a player's trade window is the host's window. On a player's copy the Lua inventory window of Anomaly
-- (ui_inventory, G.A.M.M.A.'s copy) opens as on the host, and scripts\coop_trade_window.script turns its Sell, Buy and Donate into one
-- deal for the decider (coop.trade_deal): no transfer_item, no give_money on the copy. The decider prices such a deal with the
-- window's own formula under the player's character (host_price). Every other process keeps the stock window untouched.
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

-- utils_item / trade_manager: the profile's discount follows db.actor, so the decider's price shows whose identity it ran under
local CFG = { name = "items\\trade\\trade_generic.ltx" }
local MECH = "items\\trade\\trade_generic_mechanic.ltx"
local CFGS = { [CFG.name] = CFG, [MECH] = { name = MECH } }
TM = {}
SETUP_AS = {}
DISCOUNT = { [0] = 1, [500] = 0.5 }
ui_events = ui_events or { BUTTON_CLICKED = 17 }
PARTS = { prt_w_barrel_10 = 8250 } -- items\settings\part_prices.ltx [wpo_part_prices] (G.A.M.M.A.)
trade_manager = {
	get_trade_profile = function(id, k) local t = TM[id]; if k then return t and t[k] end return t end,
	get_trade_cfg = function(name) return CFGS[name] end,
	trade_init = function() end,
	setup_buy_sell_conditions = function(npc, id, config)
		SETUP_AS[#SETUP_AS + 1] = db.actor:id()
		TM[id].current_buy_condition = "buy_" .. db.actor:id()
		TM[id].current_sell_condition = "sell"
	end,
	get_buy_discount = function(id) return DISCOUNT[db.actor:id()] or 1 end,
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

-- a trade list of the window (utils_ui.UICellContainer): cells with stacks; every id of a stack is in indx_id. Its GetCellCost prices
-- with the get_item_cost utils_ui took when it loaded (utils_ui.script:93-94), not the one utils_item has now.
local function container(cells, mode, cfg)
	local cc = { indx_id = {}, cell = {}, trade_profile = { mode = mode, cfg = cfg or CFG.name, list = "l", discount = 1 } }
	local cell_cost = utils_item.get_item_cost
	for idx, it in ipairs(cells) do
		local ci = { ID = it[1]:id(), childs = {} }
		function ci:IsShown() return true end
		cc.indx_id[it[1]:id()] = idx
		for k = 2, #it do ci.childs[it[k]:id()] = 1; cc.indx_id[it[k]:id()] = idx end
		cc.cell[idx] = ci
	end
	function cc:GetCell_ID(id) local i = self.indx_id[id]; return i and self.cell[i] end
	function cc:GetCellCost(ci)
		local ids, sum = { [ci.ID] = true }, 0
		for id in pairs(ci.childs) do ids[id] = true end
		for id in pairs(ids) do
			local o = level.object_by_id(id)
			if o and utils_item.get_item_trade_status(o, self.trade_profile) == 4 then
				sum = sum + cell_cost(o, self.trade_profile)
			end
		end
		return sum
	end
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

	-- host_price: the decider's price of a Lua window's deal, under the player's character
	local _, char = spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = 500, kind = "stalker" })
	TM[trader:id()] = { cfg_ltx = CFG.name }
	local s1 = item("bandage", 500, 300)
	local s2 = item("bread", 500, 50)
	local b1 = item("vodka", trader:id(), 200)
	local real_actor = db.actor
	SETUP_AS = {}
	local sell_total, buy_total = tw.host_price(500, trader:id(), { s1:id(), s2:id() }, { b1:id() })
	check(sell_total == 175 and buy_total == 200, name .. ": host_price adds the window's prices up, the player's discount (" ..
		tostring(sell_total) .. ", " .. tostring(buy_total) .. ")")
	check(SETUP_AS[1] == 500 and db.actor == real_actor, name .. ": the trader's lists are set up as that player sees them, the actor comes back")
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
	check(r == nil and db.actor == real_actor, name .. ": a Lua error refuses the price, no fallback; the actor comes back")
	s1._cost_error = nil
	TM[trader:id()] = nil
	r = tw.host_price(500, trader:id(), { s1:id() }, {})
	check(r == nil, name .. ": a trader without a trade profile here gives no price")
	TM[trader:id()] = { cfg_ltx = CFG.name }
	check(tw.host_price(500, 4242, { s1:id() }, {}) == nil, name .. ": no trader here, no price")

	-- R90 review 2 and review of 2026-11-25: G.A.M.M.A.'s Weapon Parts Overhaul looks at the id of the item's owner. A part not held by
	-- the actor (id 0) goes at the mechanic's own sale price (a_wpo_parts.script:5-15), a weapon not held by the actor skips the check
	-- of its busted parts (:18-35, the test at :25). On the decider the player's character (500) holds what he sells: host_price prices
	-- the player's side as his own window does, where the actor holds it.
	local base_cost, base_status = utils_item.get_item_cost, utils_item.get_item_trade_status
	utils_item.get_item_cost = function(obj, profile)
		if profile.cfg == MECH and PARTS[obj:section()] and obj:parent() and obj:parent():id() ~= 0 then
			return profile.discount * PARTS[obj:section()]
		end
		return base_cost(obj, profile)
	end
	utils_item.get_item_trade_status = function(obj, profile)
		if not (obj and profile) then return end
		if not IsWeapon(obj) or (obj:parent() and obj:parent():id() ~= 0) then return base_status(obj, profile) end
		if obj._busted then return 2 end -- se_load_var(id, name, "parts"): a prt_w_ part under the threshold
		return base_status(obj, profile)
	end
	local _, mech = spawn("mechanic", vec3(1, 0, 1), nil, { kind = "stalker" })
	TM[mech:id()] = { cfg_ltx = MECH }
	local barrel = item("prt_w_barrel_10", 500, 1237) -- worn: 1237 RU with its wear, as the window prices it
	real_actor = db.actor
	local sold, why_sold = tw.host_price(500, mech:id(), { barrel:id() }, {})
	check(sold == 1237 * 0.5, name .. ": the decider prices a worn WPO part with its wear, as the player's window does, not at the " ..
		"mechanic's sale price (" .. tostring(sold) .. ", " .. tostring(why_sold) .. ")")
	check(barrel:parent():id() == 500 and db.actor == real_actor, name .. ": the part stays his character's, the actor comes back")
	-- review of 2026-11-25, nit 4: a game_object is luabind userdata whose methods check `self`; the item as the actor's must call them on
	-- the object itself, not on its wrapper
	do
		local proxy = newproxy(true)
		local wrong = 0
		getmetatable(proxy).__index = function(u, k)
			local v = barrel[k]
			if type(v) ~= "function" then return v end
			return function(self, ...)
				if self ~= u then wrong = wrong + 1; error("a game_object method called on another object", 2) end
				return v(barrel, ...)
			end
		end
		local base_object = level.object_by_id
		level.object_by_id = function(id) if id == barrel:id() then return proxy end return base_object(id) end
		local ok_u, sold_u, why_u = pcall(tw.host_price, 500, mech:id(), { barrel:id() }, {})
		level.object_by_id = base_object
		check(ok_u and wrong == 0 and sold_u == 1237 * 0.5, name .. ": a userdata item is priced through its own methods, with its " ..
			"wear (" .. tostring(ok_u) .. ", " .. tostring(sold_u) .. ", " .. tostring(why_u) .. ", wrong self " .. wrong .. ")")
	end
	local his = item("prt_w_barrel_10", mech:id(), 1237) -- the mechanic's own part: his price on both machines
	local _, bought = tw.host_price(500, mech:id(), {}, { his:id() })
	check(bought == 8250, name .. ": a part the mechanic sells goes at his price (" .. tostring(bought) .. ")")
	local ak = item("wpn_ak74", 500, 5000, { _kind = "weapon", _busted = true })
	local r_ak, w_ak = tw.host_price(500, trader:id(), { ak:id() }, {})
	check(r_ak == nil and type(w_ak) == "string", name .. ": a weapon with busted parts is not bought: the player's window would not " ..
		"offer it (" .. tostring(r_ak) .. ", " .. tostring(w_ak) .. ")")
	ak._busted = nil
	check(tw.host_price(500, trader:id(), { ak:id() }, {}) == 5000 * 0.5, name .. ": a weapon whose parts are whole is")
	local theirs = item("bread", trader:id(), 50)
	r, w = tw.host_price(500, trader:id(), { theirs:id() }, {})
	check(r == nil and type(w) == "string", name .. ": the player sells only what his character holds (" .. tostring(w) .. ")")
	SE[barrel:id()].parent_id = 0
	check(utils_item.get_item_cost(barrel, { cfg = MECH, discount = 1 }) == 1237, name .. ": the actor's own part costs its worn price")
	utils_item.get_item_cost, utils_item.get_item_trade_status = base_cost, base_status
	for _, o in ipairs({ barrel, his, ak, theirs }) do release_id(o:id()) end

	if name == "none" then
		done("trade window (" .. name .. ")")
		return
	end

	------------------------------------------------------------------------------------------------------- the player's machine
	modes.install(coop_mode, name, COPY)

	-- R90 review 1: G.A.M.M.A. binds Sell and Buy once, when the window is made at the first open of the inventory, long before the
	-- first trade; callbacks_gameobject has wrapped both before that. ready() comes with the trade, after the binding.
	UI = fresh_ui()
	gameobject_wraps(UI)
	trader._money, db.actor._money = 5000, 1000
	local early = window("inventory", trader) -- the player opened his inventory: UIInventory() bound the buttons now
	local stale_sell, stale_buy = bound(early, "sell"), bound(early, "buy")
	check(stale_sell == UI.TMode_Sell, name .. " copy: the window's Sell is bound to the class's function of that moment")
	ok, why = tw.ready() -- he talks to a trader: StartTrade -> lua_trade_window_allowed -> ready()
	check(ok == true, name .. " copy: ready() with a window made before it (" .. tostring(why) .. ")")
	check(bound(early, "sell") ~= stale_sell and bound(early, "buy") ~= stale_buy,
		name .. " copy: ready() binds the open window's Sell and Buy again")
	local e1 = item("medkit", 0, 100)
	local e2 = item("vodka", trader:id(), 300)
	window("trade", trader, { { e1 } }, { { e2 } }, early) -- TMode_Init: the same window, now with the trader
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

	-- Review of 2026-11-25: the decider prices the purchase above what the window showed. Refused, nothing paid; the window shows the
	-- decider's price then, and the next press of Buy agrees to it (the deal carries that price as the window's sum).
	trader._money, db.actor._money = 5000, 1000
	local n1 = item("medkit", 0, 100)
	local n2 = item("vodka", trader:id(), 300)
	gui = window("trade", trader, { { n1 } }, { { n2 } }, gui)
	gui:UpdateInfo(true)
	check(gui.npc_trade_price.text == "300 RU" and gui.player_trade_price.text == "100 RU",
		name .. " copy: the window shows its own prices (" .. gui.npc_trade_price.text .. ", " .. gui.player_trade_price.text .. ")")
	DEALS, MONEY_CALLS = {}, 0
	gui:TMode_Buy()
	check(#DEALS == 1 and DEALS[1].bs == 300, name .. " copy: Buy sends the 300 RU the window shows")
	tw.on_result(DEALS[1].seq, 10, 0, "the price is not the one shown", 0, 345)
	check(gui.npc_trade_price.text == "345 RU" and gui.npc_trade_buy.enabled == true,
		name .. " copy: a refusal for its price shows the decider's price under the list (" .. gui.npc_trade_price.text .. ")")
	check(gui.player_trade_price.text == "100 RU", name .. " copy: the other list keeps its own price")
	gui:UpdateInfo(true)
	check(gui.npc_trade_price.text == "345 RU", name .. " copy: and keeps showing it while the list stays the same")
	check(MONEY_CALLS == 0 and TRANSFERS == 0, name .. " copy: nothing moved here")
	db.actor._money = 320
	MSGBOX = nil
	gui:TMode_Buy()
	check(#DEALS == 1 and MSGBOX == "not_enough_money_actor", name .. " copy: the stock's money check counts the price the window shows now")
	db.actor._money = 1000
	gui:TMode_Buy()
	check(#DEALS == 2 and DEALS[2].bs == 345 and ids_of(DEALS[2].buy) == idset(n2),
		name .. " copy: the next press agrees to it: the deal carries the decider's price (" .. tostring(DEALS[2] and DEALS[2].bs) .. ")")
	tw.on_result(DEALS[2].seq, 0, -345, "ok")
	gui:UpdateInfo(true)
	check(gui.npc_trade_price.text == "300 RU", name .. " copy: after the deal the window counts by itself again")

	-- a sale the decider prices more than 1 RU (rounding) below what the window showed: refused, the window shows his price
	DEALS = {}
	gui:TMode_Sell()
	check(#DEALS == 1 and DEALS[1].ss == 100, name .. " copy: Sell sends the 100 RU the window shows")
	tw.on_result(DEALS[1].seq, 10, 0, "the price is not the one shown", 80, 0)
	check(gui.player_trade_price.text == "80 RU" and gui.npc_trade_price.text == "300 RU",
		name .. " copy: a sale refused for its price shows what the decider pays (" .. gui.player_trade_price.text .. ")")
	gui:TMode_Sell()
	check(#DEALS == 2 and DEALS[2].ss == 80, name .. " copy: the next press of Sell agrees to it")
	tw.on_result(DEALS[2].seq, 5, 0, "no money") -- refused for another reason: the price stays shown
	gui:UpdateInfo(true)
	check(gui.player_trade_price.text == "80 RU", name .. " copy: another refusal keeps the decider's price shown")

	-- another list is another price: the window counts it again by itself
	local n3 = item("bread", 0, 50)
	gui = window("trade", trader, { { n1 }, { n3 } }, { { n2 } }, gui)
	gui:UpdateInfo(true)
	check(gui.player_trade_price.text == "150 RU", name .. " copy: a changed list shows the window's own price (" .. gui.player_trade_price.text .. ")")
	DEALS = {}
	gui:TMode_Sell()
	check(#DEALS == 1 and DEALS[1].ss == 150, name .. " copy: and sells for it")
	tw.on_result(DEALS[1].seq, 10, 0, "the price is not the one shown", 120, 0)
	check(gui.player_trade_price.text == "120 RU", name .. " copy: refused again: the decider's price of this list")
	-- the window closes: the decider's prices are forgotten
	SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
	SendScriptCallback("GUI_on_hide", "UIInventory", "ui_inventory")
	gui = window("trade", trader, { { n1 }, { n3 } }, { { n2 } }, gui)
	gui:UpdateInfo(true)
	check(gui.player_trade_price.text == "150 RU", name .. " copy: a window opened again counts by itself")
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

	-- R90 review: the sums of a deal are the ones the window shows (GetCellCost with utils_ui's own get_item_cost), not the item prices
	-- added up again: a mod that replaced utils_item.get_item_cost after utils_ui loaded changes the item prices, not the window's sum
	local w1 = item("medkit", 0, 100)
	local w2 = item("bread", 0, 50)
	gui = window("trade", trader, { { w1, w2 } }, {}, gui)
	local base_cost = utils_item.get_item_cost
	utils_item.get_item_cost = function(obj, profile) return 2 * base_cost(obj, profile) end
	DEALS = {}
	gui:TMode_Sell()
	check(#DEALS == 1 and DEALS[1].ss == 150 and DEALS[1].sp[1] + DEALS[1].sp[2] == 300,
		name .. " copy: the deal carries the sum the window shows (" .. tostring(DEALS[1] and DEALS[1].ss) .. ")")
	utils_item.get_item_cost = base_cost
	tw.on_result(DEALS[1].seq, 5, 0, "no")

	-- R90 review 2: a worn WPO part sold to a mechanic. The actor owns it here (id 0): the window shows its worn price, and that sum
	-- goes with the deal; the decider's formula prices it at the mechanic's sale price (see host_price above), the decider pays the
	-- smaller sum (coop_trade_window_rules.h settle_side)
	utils_item.get_item_cost = function(obj, profile)
		if profile.cfg == MECH and PARTS[obj:section()] and obj:parent() and obj:parent():id() ~= 0 then
			return profile.discount * PARTS[obj:section()]
		end
		return base_cost(obj, profile)
	end
	local _, mech = spawn("mechanic", vec3(1, 0, 1), nil, { kind = "stalker" })
	mech._money = 50000
	local barrel = item("prt_w_barrel_10", 0, 1237)
	gui = window("trade", mech, { { barrel } }, {}, gui, MECH)
	DEALS = {}
	gui:TMode_Sell()
	check(#DEALS == 1 and ids_of(DEALS[1].sell) == idset(barrel) and DEALS[1].ss == 1237,
		name .. " copy: a worn WPO part goes for the 1237 RU the window shows (" .. tostring(DEALS[1] and DEALS[1].ss) .. ")")
	utils_item.get_item_cost = base_cost
	tw.on_result(DEALS[1].seq, 5, 0, "no")
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

-- coop_core_world hands the late profile to the window and lets it ask for one without a talk
do
	local fh = assert(io.open("gamedata/scripts/coop_core_world.script", "r"))
	local src = fh:read("*a")
	fh:close()
	check(src:find("module_of(\"coop_trade_window\")", 1, true) ~= nil and src:find("on_profile", 1, true) ~= nil,
		"coop_core_world: the profile from the decider reaches an open Lua trade window")
	check(src:find("\nfunction ask_trader(npc)", 1, true) ~= nil, "coop_core_world: ask_trader(npc) for a window opened without a talk")
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
	-- R90 review 1: the buttons are bound when the window is made; ready() binds them again
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
	-- review of 2026-11-25: the decider's price of a refused deal is shown through TMode_UpdatePrice, which UpdateInfo calls by name
	check(has(inv, "function UIInventory:TMode_UpdatePrice(ele_txt, ele_btn, bag)")
		and has(inv, 'self:TMode_UpdatePrice(self.player_trade_price, self.player_trade_sell, "actor_trade")')
		and has(inv, 'self:TMode_UpdatePrice(self.npc_trade_price, self.npc_trade_buy, "npc_trade")')
		and has(inv, 'ele_txt:SetText(tot_cost .. " RU")') and has(inv, "ele_btn:Enable( tot_cost > 0 )"),
		"G.A.M.M.A. ui_inventory: both prices are set by TMode_UpdatePrice from UpdateInfo")
	-- and Weapon Parts Overhaul looks at the id of the item's owner (host_price shows it the actor as the player's window does)
	local wpo = read("a_wpo_parts.script")
	check(has(wpo, "obj:parent() and obj:parent():id() ~= 0 then") and has(wpo, "local cost_final = discount * parts_list[sec]")
		and has(wpo, "(obj:parent() and obj:parent():id() ~= 0) then return GetStatus(obj, profile) end"),
		"G.A.M.M.A. a_wpo_parts: the part price and the busted-parts check depend on the owner's id")
end
print(string.format("%d passed, %d failed", PASSES, FAILS))
