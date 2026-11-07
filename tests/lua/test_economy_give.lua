-- Anomaly Coop temp test (economy, "give how many"): "Give to <player>" on an item of more than one unit opens the amount
-- window (icon, name, a slider 1..max with the number, one button "Give"; Esc or a click outside closes it without giving).
-- Units: rounds of ammo (one box is split, several boxes of the stack sum up), identical items of a stack (plain
-- transfers), multi-use items whole. The split box is made by the host (the level's authority): the giver takes the rounds
-- out of his own box at once and asks; the host checks and creates a box of N in the receiver's inventory, or refuses and
-- the giver's machine puts the rounds back. coop_economy_core / _money / _give on a host and two clients with stub engines.
-- Not shipped.
dofile("tests/lua/support/harness_economy.lua")

local NAMES = { ammo_9x19_fmj = "9x19 FMJ", ammo_545x39_bp = "5.45 BP", bandage = "Bandage", medkit = "Medkit",
	vodka = "Vodka", cigarettes = "Cigarettes" }
local BOX = { ammo_9x19_fmj = 50, ammo_545x39_bp = 60 }

local DIK = { DIK_ESCAPE = 1, DIK_RETURN = 28, DIK_NUMPADENTER = 156, DIK_LEFT = 203, DIK_RIGHT = 205, MOUSE_1 = 337,
	MOUSE_2 = 338 }
local UIE = { BUTTON_CLICKED = 17, WINDOW_KEY_PRESSED = 6 }

local function readfile(p)
	local fh = assert(io.open(p, "rb"))
	local s = fh:read("*a")
	fh:close()
	return s
end

-------------------------------------------------------------------------------
-- stand-ins: the inventory menu, the window controls, the host's alife
-------------------------------------------------------------------------------
local function ui_stubs(W)
	W.UI = { callbacks = {}, ctl = {}, cursor_over = true, shows = 0 }
	local function control(path)
		local c = { path = path, shown = true }
		function c:SetText(t) self.text = t end
		function c:GetText() return self.text end
		function c:TextControl() return self end
		function c:InitTexture(t) self.texture = t end
		function c:SetTextureRect(r) self.rect = r end
		function c:SetStretchTexture() end
		function c:SetWndSize(v) self.size = v end
		function c:SetWndPos(v) self.pos = v end
		function c:GetWndPos() return { x = 0, y = 0 } end
		function c:GetWidth() return 100 end
		function c:GetHeight() return 70 end
		function c:Show(b) self.shown = b end
		function c:Enable(b) self.enabled = b end
		function c:IsCursorOverWindow() return W.UI.cursor_over == true end
		function c:SetOptFBounds(a, b) self.lo, self.hi = a, b end
		function c:SetOptIBounds(a, b) self.lo, self.hi = a, b end
		function c:SetStep(s) self.step = s end
		function c:SetFValue(v) self.value = v end
		function c:SetIValue(v) self.value = v end
		function c:GetFValue() return self.value end
		function c:GetIValue() return math.floor(self.value) end
		function c:SetCurrentValue() end
		W.UI.ctl[path] = c
		return c
	end
	W.CScriptXmlInit = function()
		local x = {}
		function x:ParseFile(f) W.UI.xml = f end
		function x:InitStatic(p) return control(p) end
		function x:InitFrame(p) return control(p) end
		function x:InitTextWnd(p) return control(p) end
		function x:Init3tButton(p) W.UI.buttons = (W.UI.buttons or 0) + 1 return control(p) end
		function x:InitTrackBar(p) return control(p) end
		return x
	end
	W.class = function(name)
		local env = getfenv(2)
		return function(base)
			local c = {}
			c.__index = c
			setmetatable(c, { __index = base, __call = function(cls, ...)
				local o = setmetatable({}, cls)
				if cls.__init then cls.__init(o, ...) end
				return o
			end })
			env[name] = c
		end
	end
	W.super = function() end
	W.CUIScriptWnd = {
		SetWndRect = function() end, Enable = function() end, SetAutoDelete = function() end,
		Register = function(self, ctl, name) end,
		AddCallback = function(self, name, ev, f, obj) W.UI.callbacks[name] = function() f(obj) end end,
		ShowDialog = function(self) self._shown = true W.UI.shows = W.UI.shows + 1 end,
		HideDialog = function(self) self._shown = false end,
		IsShown = function(self) return self._shown == true end,
		OnKeyboard = function() return false end,
		Update = function() end,
	}
	W.Frect = function() return { set = function(self, a, b, c, d) self.x1, self.y1, self.x2, self.y2 = a, b, c, d return self end } end
	W.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	W.DIK_keys = DIK
	W.ui_events = UIE
	W.utils_xml = {
		get_item_axis = function(sec) return { x1 = 50, y1 = 100, x2 = 150, y2 = 150, w = 100, h = 50 } end,
		get_icons_texture = function(sec) return "ui\\ui_icon_equipment" end,
	}
	W.ini_sys = {
		line_exist = function(_, s, k) return k == "box_size" and BOX[s] ~= nil end,
		r_u32 = function(_, s, k) return BOX[s] end,
	}
end

local function stubs(W)
	local inv = {}
	function inv.InitProperties(self, obj, bag) end
	function inv.UpdateCharacter(self) end
	W.ui_inventory = { UIInventory = inv }
	W.GetCursorPosition = function() return { x = 0, y = 0 } end
	W.ui_item = { get_sec_name = function(sec) return NAMES[sec] end }
	W.TIP_LOG = {}
	W.news_manager = { send_tip = function(actor, text)
		W.TIPS[#W.TIPS + 1] = text
		W.TIP_LOG[#W.TIP_LOG + 1] = { text = text, at = W.NOW, actor = actor }
	end }
	W.STACK = {} -- cell id -> the other ids of that cell (ui_inventory cell childs)
	W.CREATED = {} -- alife_create_item calls here (the giver's own leftover box)
	W.alife_create_item = function(sec, owner, t)
		W.CREATED[#W.CREATED + 1] = { sec = sec, owner = owner == W.db.actor and 0 or owner, ammo = t and t.ammo }
	end
	W.db.actor.iterate_inventory = function(_, f, obj)
		local ids = {}
		for id, o in pairs(W.OBJ) do if o._parent == 0 then ids[#ids + 1] = id end end
		table.sort(ids)
		for _, id in ipairs(ids) do f(obj, W.OBJ[id]) end
	end
	ui_stubs(W)
end

local function avatar_in(W, q)
	if q == W.PEER then return 0 end
	return W.coop.avatar_of(q)
end

local function peer_of_hid(hid)
	if hid == 0 then return 0 end
	for p, info in pairs(PLAYERS) do if info.proxy == hid then return p end end
end

local BOXES_MADE = 0
local function host_alife(H)
	H.MADE = {}
	local base = H.alife
	H.alife = function()
		local sim = base()
		function sim.create_ammo(_, sec, pos, lv, gv, pid, num)
			if H.CREATE_FAILS then error("create_ammo failed") end
			BOXES_MADE = BOXES_MADE + 1
			local id = 4000 + BOXES_MADE
			local owner = peer_of_hid(pid)
			for _, W in pairs(WORLDS) do
				local o = add_item(W, id, sec, avatar_in(W, owner))
				o.ammo = num
			end
			H.MADE[#H.MADE + 1] = { id = id, sec = sec, parent = pid, n = num, owner = owner }
			return H.SE[id]
		end
		return sim
	end
end

local function setup(nclients)
	PLAYERS = { [0] = { nick = "host", proxy = 0 } }
	local nicks = { "anna", "boris" }
	for i = 1, nclients do PLAYERS[i] = { nick = nicks[i], proxy = 500 + i } end
	POS = {}
	for p in pairs(PLAYERS) do POS[p] = { x = p * 2, y = 0, z = 0 } end -- everybody within give_radius (5 m)
	QUEUE, WORLDS = {}, {}
	for p in pairs(PLAYERS) do
		local W = make_world(p)
		stubs(W)
		for q, info in pairs(PLAYERS) do
			local lid = (p == 0) and info.proxy or (info.proxy == 0 and PLAYERS[p].proxy or (info.proxy == PLAYERS[p].proxy and 0 or info.proxy))
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
	end
	host_alife(WORLDS[0])
	for _, W in pairs(WORLDS) do
		for _, n in ipairs({ "coop_economy_core", "coop_economy_money", "coop_economy_give" }) do load_script(W, n) end
		for _, n in ipairs({ "coop_economy_core", "coop_economy_money", "coop_economy_give" }) do
			if W[n].on_game_start then W[n].on_game_start() end
		end
	end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

-- an item (same id everywhere) in the inventory of player `owner`; ammo boxes get `count` rounds in every copy
local function put(id, section, owner, count)
	for _, W in pairs(WORLDS) do
		local o = add_item(W, id, section, avatar_in(W, owner))
		o.ammo = count or (BOX[section] and BOX[section]) or 0
		function o:ammo_get_count() return self.ammo end
		function o:ammo_box_size() return BOX[self._section] or 1 end
	end
end

-- the host applied a transfer: every world sees the item under the receiver's character
local function move(id, to, take)
	for _, W in pairs(WORLDS) do
		local parent = avatar_in(W, to)
		W.SE[id].parent_id = parent
		W.OBJ[id]._parent = parent
	end
	if take then fire(WORLDS[to], "actor_on_item_take", WORLDS[to].OBJ[id]) end
end

-- a box of the receiver's that the host made reaches his inventory
local function take_made(H, to)
	for _, m in ipairs(H.MADE) do fire(WORLDS[to], "actor_on_item_take", WORLDS[to].OBJ[m.id]) end
end

-- "Give to <nick>" in the inventory menu of W on item `id`; the window (if any) opens on the next update
local function menu(W, id, to)
	local inv = setmetatable({ properties = {}, item_props = { Reset = function() end }, CC = {
		actor_bag = { GetCell_ID = function(_, cid)
			local ch = {}
			for _, c in ipairs(W.STACK[cid] or {}) do ch[c] = true end
			return { ID = cid, childs = ch, HasChild = function() return next(ch) ~= nil end }
		end },
	} }, { __index = W.ui_inventory.UIInventory })
	inv:InitProperties(W.OBJ[id], "actor_bag")
	for i = 1, 8 do
		if inv:coop_eco_NameGive(id, "actor_bag", "", i) == "Give to " .. PLAYERS[to].nick then
			inv:coop_eco_ActionGive(id, "actor_bag", "coop_eco_ActionGive", i)
			run_time_events(W)
			return true
		end
	end
	return false
end

local function win(W) return W.coop_economy_give.window() end
local function track(W) return W.UI.ctl["coop_give:track"] end
local function number(W) return W.UI.ctl["coop_give:num"].text end
local function slide(W, v) track(W).value = v win(W):Update() end
local function key(W, dik) return win(W):OnKeyboard(dik, UIE.WINDOW_KEY_PRESSED) end
local function press_give(W) W.UI.callbacks.btn_give() end

-- menu, slider to n, Give
local function give_amount(W, id, to, n)
	if not menu(W, id, to) then return false end
	local w = win(W)
	if not w then return false end
	slide(W, n)
	press_give(W)
	return true
end

local function events(W, name)
	local out = {}
	for _, e in ipairs(W.SENT) do
		if e.name == "economy." .. name then out[#out + 1] = { target = e.target, t = CM_DECODE(e.payload) } end
	end
	return out
end

local function told(W)
	local out = {}
	for _, l in ipairs(W.TIP_LOG) do
		if l.text:find(" gave you: ", 1, true) then out[#out + 1] = l.text end
	end
	return out
end

local function wait(W, ms)
	local done = 0
	while done < ms do
		tick(W, 250)
		done = done + 250
	end
end

local function rounds_of(W, peer, section)
	local n = 0
	local av = avatar_in(W, peer)
	for _, o in pairs(W.OBJ) do
		if o._parent == av and o._section == section then n = n + (o.ammo or 0) end
	end
	return n
end

local function last_tip(W) return W.TIPS[#W.TIPS] end

-------------------------------------------------------------------------------
section("one unit: no window, the item goes at once as before")
do
	local H, A, B = setup(2)
	put(700, "medkit", 1)
	check(menu(A, 700, 2), "the menu entry 'Give to boris' is there")
	check(win(A) == nil, "no window for one item")
	check(A.TRANSFERS and #A.TRANSFERS == 1 and A.TRANSFERS[1][1] == 700, "given at once")
	local ev = events(A, "gift")
	check(#ev == 1 and ev[1].t.i == 700 and ev[1].t.u == nil, "the old economy.gift { i } (no units)")
	-- an ammo box of a single round: one unit
	put(701, "ammo_9x19_fmj", 1, 1)
	check(menu(A, 701, 2) and win(A) == nil and #A.TRANSFERS == 2, "a box of one round: no window, given at once")
	-- a multi-use item alone: whole, no window
	put(702, "cigarettes", 1)
	A.OBJ[702].uses = 3
	check(menu(A, 702, 2) and win(A) == nil and #A.TRANSFERS == 3, "a multi-use item alone: given whole at once")
end

section("the window: icon, name, slider 1..max with the number, one button")
do
	local H, A, B = setup(2)
	put(710, "ammo_9x19_fmj", 1, 30)
	check(menu(A, 710, 2), "menu")
	local w = win(A)
	check(w ~= nil and w:IsShown(), "a box of 30 rounds opens the window")
	check(A.UI.xml == "ui_coop_give.xml", "built from ui_coop_give.xml")
	check(#(A.TRANSFERS or {}) == 0 and #events(A, "give_part") == 0, "nothing given while it is open")
	local icon = A.UI.ctl["coop_give:icon"]
	check(icon and icon.texture == "ui\\ui_icon_equipment" and icon.rect and icon.rect.x1 == 50 and icon.rect.y2 == 150,
		"the item's icon from its section")
	check(A.UI.ctl["coop_give:name"].text == "9x19 FMJ", "the item's name")
	check(A.UI.ctl["coop_give:whom"].text == "To: boris", "the receiver")
	local t = track(A)
	check(t.lo == 1 and t.hi == 30 and t.step == 1, "slider 1..30, step 1 (" .. tostring(t.lo) .. ".." .. tostring(t.hi) .. ")")
	check(t.value == 30 and number(A) == "30 / 30", "starts at what the old menu gave: the whole box (" .. tostring(number(A)) .. ")")
	check(A.UI.buttons == 1 and A.UI.callbacks.btn_give ~= nil, "exactly one button, Give")
	slide(A, 12)
	check(number(A) == "12 / 30" and w.amount == 12, "the number follows the slider")
	slide(A, 0)
	check(w.amount == 1 and number(A) == "1 / 30" and t.value == 1, "below 1: 1")
	slide(A, 99)
	check(w.amount == 30 and t.value == 30, "above the max: the max")
	slide(A, 7.6)
	check(w.amount == 8 and t.value == 8, "a fraction rounds to the nearest round (" .. tostring(w.amount) .. ")")
	slide(A, 0 / 0)
	check(w.amount == 8, "NaN from the control changes nothing")
	key(A, DIK.DIK_LEFT)
	check(w.amount == 7 and t.value == 7 and number(A) == "7 / 30", "Left: one less")
	key(A, DIK.DIK_RIGHT) key(A, DIK.DIK_RIGHT)
	check(w.amount == 9, "Right: one more")
	slide(A, 1) key(A, DIK.DIK_LEFT)
	check(w.amount == 1, "Left at 1 stays 1")
	slide(A, 30) key(A, DIK.DIK_RIGHT)
	check(w.amount == 30, "Right at the max stays the max")
	-- a stack of items starts at 1 (the old menu gave one item of a stack)
	put(711, "bandage", 1) put(712, "bandage", 1) put(713, "bandage", 1)
	A.STACK[711] = { 712, 713 }
	key(A, DIK.DIK_ESCAPE)
	check(menu(A, 711, 2), "menu on a stack of 3 bandages")
	check(track(A).hi == 3 and track(A).value == 1 and number(A) == "1 / 3", "items: 1..3, starts at 1")
	check(A.UI.ctl["coop_give:name"].text == "Bandage", "the stack's name")
end

section("the window closes without giving: Esc, a click outside")
do
	local H, A, B = setup(2)
	put(720, "ammo_9x19_fmj", 1, 30)
	menu(A, 720, 2)
	slide(A, 10)
	check(key(A, DIK.DIK_ESCAPE) == true, "Esc is taken")
	check(win(A) == nil, "Esc: closed")
	check(#(A.TRANSFERS or {}) == 0 and #events(A, "give_part") == 0 and A.OBJ[720].ammo == 30, "Esc: nothing given")
	menu(A, 720, 2)
	A.UI.cursor_over = true
	key(A, DIK.MOUSE_1)
	check(win(A) ~= nil, "a click on the window keeps it open")
	A.UI.cursor_over = false
	key(A, DIK.MOUSE_1)
	check(win(A) == nil and A.OBJ[720].ammo == 30 and #events(A, "give_part") == 0, "a click outside: closed, nothing given")
	A.UI.cursor_over = true
	menu(A, 720, 2)
	A.UI.cursor_over = false
	key(A, DIK.MOUSE_2)
	check(win(A) == nil, "a right click outside closes it too")
	A.UI.cursor_over = true
	-- Enter gives like the button
	menu(A, 720, 2)
	slide(A, 30)
	key(A, DIK.DIK_RETURN)
	check(win(A) == nil and A.TRANSFERS and #A.TRANSFERS == 1, "Enter: given (the whole box) and closed")
end

section("rounds, one box: the giver keeps count-N, the host makes a box of N for the receiver")
do
	local H, A, B = setup(2)
	put(730, "ammo_9x19_fmj", 1, 30)
	check(give_amount(A, 730, 2, 12), "anna gives 12 of 30 rounds to boris")
	check(win(A) == nil, "the window closed")
	check(A.OBJ[730].ammo == 18, "anna's box: 18 at once (" .. tostring(A.OBJ[730].ammo) .. ")")
	check(#(A.TRANSFERS or {}) == 0, "no transfer: the box stays hers")
	local ev = events(A, "give_part")
	check(#ev == 1 and ev[1].target == 0, "one request to the host")
	local r = ev[1] and ev[1].t or {}
	check(r.i == 730 and r.n == 12 and r.k == 18 and r.p == 2 and type(r.q) == "number", "{ q, i = 730, n = 12, k = 18, p = 2 }")
	check(has(A.TIPS, "9x19 FMJ x12 given to boris"), "anna: '9x19 FMJ x12 given to boris.'")
	deliver_all()
	check(#H.MADE == 1 and H.MADE[1].sec == "ammo_9x19_fmj" and H.MADE[1].n == 12 and H.MADE[1].parent == 502,
		"the host made a box of 12 in boris's inventory")
	local g = events(H, "gift")
	check(#g == 1 and g[1].target == 2 and g[1].t.i == H.MADE[1].id and g[1].t.u == 12 and g[1].t.g == 1,
		"the host tells boris: economy.gift { i = new box, u = 12, g = anna }")
	local ans = events(H, "give_ans")
	check(#ans == 1 and ans[1].target == 1 and ans[1].t.o == 1, "anna gets the yes")
	take_made(H, 2)
	wait(B, 1500)
	local lines = told(B)
	check(#lines == 1 and lines[1] == "anna gave you: 9x19 FMJ x12.", "boris: 'anna gave you: 9x19 FMJ x12.' (" .. tostring(lines[1]) .. ")")
	check(rounds_of(H, 1, "ammo_9x19_fmj") == 30 and rounds_of(H, 2, "ammo_9x19_fmj") == 12,
		"host copies: anna's box still 30 until her state comes, boris 12")
	H.OBJ[730].ammo = A.OBJ[730].ammo -- her ItemState arrives
	check(rounds_of(H, 1, "ammo_9x19_fmj") + rounds_of(H, 2, "ammo_9x19_fmj") == 30, "30 rounds in the world, no more, no less")
	check(A.coop_economy_give.pending_count() == 0, "anna has nothing pending")
	wait(A, 3000)
	check(A.OBJ[730].ammo == 18 and #A.CREATED == 0, "the yes changes nothing more on anna")
end

section("rounds, all of one box: the box moves as before")
do
	local H, A, B = setup(2)
	put(740, "ammo_9x19_fmj", 1, 30)
	give_amount(A, 740, 2, 30)
	check(A.TRANSFERS and #A.TRANSFERS == 1 and A.TRANSFERS[1][1] == 740 and A.TRANSFERS[1][2] == avatar_in(A, 2), "one transfer of the box")
	check(#events(A, "give_part") == 0 and A.OBJ[740].ammo == 30, "no split")
	local g = events(A, "gift")
	check(#g == 1 and g[1].t.i == 740 and g[1].t.u == 30, "economy.gift { i = 740, u = 30 }")
	deliver_all()
	move(740, 2, true)
	wait(B, 1500)
	check(told(B)[1] == "anna gave you: 9x19 FMJ x30.", "boris: 'anna gave you: 9x19 FMJ x30.'")
end

section("rounds across the boxes of a stack: whole boxes first, one box split")
do
	local H, A, B = setup(2)
	put(750, "ammo_9x19_fmj", 1, 30) put(751, "ammo_9x19_fmj", 1, 30) put(752, "ammo_9x19_fmj", 1, 10)
	put(753, "ammo_9x19_fmj", 1, 0) -- an emptied box the host has not destroyed yet: no rounds, never touched
	A.STACK[750] = { 751, 752, 753 }
	menu(A, 750, 2)
	check(track(A).hi == 70 and track(A).value == 30, "the slider sums the stack: 1..70, starts at the clicked box (30)")
	slide(A, 45)
	press_give(A)
	local moved = {}
	for _, t in ipairs(A.TRANSFERS or {}) do moved[t[1]] = true end
	local parts = events(A, "give_part")
	check(#parts == 1, "one box split")
	local split = parts[1] and parts[1].t or {}
	local whole_rounds = 0
	for id in pairs(moved) do whole_rounds = whole_rounds + A.OBJ[id].ammo end
	check(whole_rounds + (split.n or 0) == 45, "whole boxes + split = 45 (" .. whole_rounds .. " + " .. tostring(split.n) .. ")")
	check(not moved[753] and A.OBJ[753].ammo == 0 and split.i ~= 753, "the empty box is not touched")
	check(not moved[split.i], "the split box is not also moved")
	check(moved[750] and moved[752] and split.i == 751 and split.n == 5 and A.OBJ[751].ammo == 25,
		"30 + 10 whole, 5 out of the other 30")
	check(has(A.TIPS, "9x19 FMJ x45 given to boris"), "one line for the giver: x45")
	deliver_all()
	for id in pairs(moved) do move(id, 2, true) end
	take_made(H, 2)
	wait(B, 1500)
	local lines = told(B)
	check(#lines == 1 and lines[1] == "anna gave you: 9x19 FMJ x45.", "boris: one line 'anna gave you: 9x19 FMJ x45.' (" .. tostring(lines[1]) .. ")")
	-- everything: every box moves, nothing split
	put(760, "ammo_545x39_bp", 1, 60) put(761, "ammo_545x39_bp", 1, 7)
	A.STACK[760] = { 761 }
	local before = #(A.TRANSFERS or {})
	give_amount(A, 760, 2, 67)
	check(#A.TRANSFERS == before + 2 and #events(A, "give_part") == 1, "67 of 67: two transfers, no new split")
end

section("identical items of a stack: N plain transfers, one line 'x N'")
do
	local H, A, B = setup(2)
	for i = 0, 4 do put(770 + i, "bandage", 1) end
	A.STACK[770] = { 771, 772, 773, 774 }
	give_amount(A, 770, 2, 3)
	check(A.TRANSFERS and #A.TRANSFERS == 3, "three transfers")
	local ids = {}
	for _, t in ipairs(A.TRANSFERS) do ids[t[1]] = true check(t[2] == avatar_in(A, 2), "to boris") end
	check(ids[770] and ids[771] and ids[772], "the clicked one first, then the stack in order")
	check(#events(A, "give_part") == 0, "no split of items")
	local g = events(A, "gift")
	check(#g == 3 and g[1].t.u == 1, "one economy.gift per item, u = 1")
	check(has(A.TIPS, "Bandage x3 given to boris"), "anna: 'Bandage x3 given to boris.'")
	deliver_all()
	for id in pairs(ids) do move(id, 2, true) end
	wait(B, 1500)
	check(told(B)[1] == "anna gave you: Bandage x3.", "boris: 'anna gave you: Bandage x3.' (" .. tostring(told(B)[1]) .. ")")
	-- multi-use items: whole items only
	put(780, "cigarettes", 1) put(781, "cigarettes", 1)
	A.OBJ[780].uses, A.OBJ[781].uses = 2, 3
	A.STACK[780] = { 781 }
	menu(A, 780, 2)
	check(track(A).hi == 2 and number(A) == "1 / 2", "two multi-use items: 1..2 items, not portions")
	key(A, DIK.DIK_ESCAPE)
end

-------------------------------------------------------------------------------
-- the host's checks: every refusal tells the giver why and gives the rounds back
-------------------------------------------------------------------------------
local function refused(W, why_text)
	for _, t in ipairs(W.TIPS) do
		if t:find("did not reach", 1, true) and t:find(why_text, 1, true) then return true end
	end
	return false
end

section("refused: the receiver walked away, left, the giver's box is not his")
do
	local H, A, B = setup(2)
	put(800, "ammo_9x19_fmj", 1, 30)
	give_amount(A, 800, 2, 10)
	check(A.OBJ[800].ammo == 20, "taken out: 20")
	POS[2] = { x = 40, y = 0, z = 0 } -- boris runs off before the host gets it
	deliver_all()
	check(#H.MADE == 0, "far: no box made")
	check(A.OBJ[800].ammo == 30, "far: anna's rounds are back (" .. A.OBJ[800].ammo .. ")")
	check(refused(A, "too far"), "far: anna is told why (" .. tostring(last_tip(A)) .. ")")
	check(A.coop_economy_give.pending_count() == 0, "nothing pending")
	POS[2] = { x = 4, y = 0, z = 0 }
	-- a little over the radius on the host (latency): still given
	H.NOW = H.NOW + 2100
	give_amount(A, 800, 2, 10)
	POS[2] = { x = 2 + 5 + 1, y = 0, z = 0 }
	deliver_all()
	check(#H.MADE == 1, "1 m over the radius at the host is within its slack")
	POS[2] = { x = 4, y = 0, z = 0 }
	-- the receiver left
	H.NOW = H.NOW + 2100
	give_amount(A, 800, 2, 5)
	local gone = PLAYERS[2]
	PLAYERS[2] = nil
	deliver_all()
	PLAYERS[2] = gone
	check(#H.MADE == 1 and A.OBJ[800].ammo == 20 and refused(A, "not in the game"), "left: nothing made, rounds back, told")
	-- the box is not the giver's on the host (moved, emptied and destroyed)
	H.NOW = H.NOW + 2100
	give_amount(A, 800, 2, 5)
	H.SE[800].parent_id = 65535
	deliver_all()
	check(#H.MADE == 1 and A.OBJ[800].ammo == 20 and refused(A, "box"), "not hers on the host: nothing made, rounds back")
	H.SE[800].parent_id = avatar_in(H, 1)
	H.NOW = H.NOW + 2100
	give_amount(A, 800, 2, 5)
	local se, obj = H.SE[800], H.OBJ[800]
	H.SE[800], H.OBJ[800] = nil, nil
	deliver_all()
	H.SE[800], H.OBJ[800] = se, obj
	check(#H.MADE == 1 and A.OBJ[800].ammo == 20 and refused(A, "box"), "gone on the host: nothing made, rounds back")
	-- the host cannot make the box
	H.NOW = H.NOW + 2100
	give_amount(A, 800, 2, 5)
	H.CREATE_FAILS = true
	deliver_all()
	H.CREATE_FAILS = nil
	check(#H.MADE == 1 and A.OBJ[800].ammo == 20 and refused(A, "could not"), "creation failed: rounds back")
	check(H.HANDLER_ERRORS == nil and A.HANDLER_ERRORS == nil, "no handler errors")
end

section("refused: bad requests, the rate")
do
	local H, A, B = setup(2)
	put(810, "ammo_9x19_fmj", 1, 50)
	put(811, "medkit", 1)
	put(812, "ammo_9x19_fmj", 2, 50) -- boris's
	local function ask(t)
		H.NOW = H.NOW + 2100 -- under the rate
		A.coop_economy_core.send("give_part", t, 0)
		deliver_all()
	end
	local function answer_of(q)
		for _, e in ipairs(events(H, "give_ans")) do if e.t.q == q then return e.t end end
	end
	local bad = {
		{ q = 1, i = 810, n = 0, k = 40, p = 2 }, { q = 2, i = 810, n = "x", k = 40, p = 2 }, { q = 3, i = 810, n = 5, k = 0, p = 2 },
		{ q = 4, i = 810, n = 5, k = 40, p = 1 }, { q = 5, i = 810, n = 5, k = 40, p = 9 }, { q = 6, i = 810, n = 1.5, k = 40, p = 2 },
		{ q = 7, i = 0, n = 5, k = 40, p = 2 }, { q = 8, i = 810, n = 1e9, k = 1, p = 2 },
	}
	for _, t in ipairs(bad) do ask(t) end
	for _, t in ipairs(bad) do
		local a = answer_of(t.q)
		check(a and a.o == 0 and type(a.w) == "string", "request " .. t.q .. " refused (" .. tostring(a and a.w) .. ")")
	end
	ask({ q = 20, i = 811, n = 1, k = 1, p = 2 })
	check(answer_of(20) and answer_of(20).w == "box", "not ammo: refused 'box'")
	ask({ q = 21, i = 812, n = 5, k = 40, p = 2 })
	check(answer_of(21) and answer_of(21).w == "box", "boris's box asked by anna: refused 'box'")
	ask({ q = 22, i = 810, n = 20, k = 40, p = 2 })
	check(answer_of(22) and answer_of(22).w == "count", "more than a box holds (20 + 40 > 50): refused 'count'")
	ask({})
	ask({ q = "x" })
	A.coop.send_event("economy.give_part", "garbage;;==", 0)
	deliver_all()
	check(#H.MADE == 0 and H.HANDLER_ERRORS == nil, "nothing made, no errors")
	check(#A.CREATED == 0 and A.OBJ[810].ammo == 50, "answers to requests anna never made change nothing on her")
	-- the same request twice is made once and answered once
	ask({ q = 30, i = 810, n = 5, k = 40, p = 2 })
	ask({ q = 30, i = 810, n = 5, k = 40, p = 2 })
	local n30 = 0
	for _, e in ipairs(events(H, "give_ans")) do if e.t.q == 30 then n30 = n30 + 1 end end
	check(#H.MADE == 1 and n30 == 1, "a repeated q: one box, one answer")
	-- from a peer that is not a player, from the host to itself
	H.coop_main.on_event("economy.give_part", CM_ENCODE({ q = 31, i = 810, n = 5, k = 40, p = 2 }), 7)
	H.coop_main.on_event("economy.give_part", CM_ENCODE({ q = 32, i = 810, n = 5, k = 40, p = 2 }), 0)
	H.coop_main.on_event("economy.give_part", CM_ENCODE({ q = 33, i = 810, n = 5, k = 40, p = 2 }), -1)
	check(#H.MADE == 1 and H.HANDLER_ERRORS == nil, "a stranger, the host's own event: nothing made")
	-- the rate: at most 4 in 2 s per giver
	H.NOW = H.NOW + 5000
	A.OBJ[810].ammo, H.OBJ[810].ammo = 50, 50
	for _ = 1, 6 do give_amount(A, 810, 2, 1) end
	check(A.OBJ[810].ammo == 44, "six gifts of 1 taken out at once")
	deliver_all()
	check(#H.MADE == 5, "four more made (" .. #H.MADE .. " in all)")
	check(A.OBJ[810].ammo == 46 and refused(A, "too many"), "two over the rate: back, told")
	H.NOW = H.NOW + 2500
	give_amount(A, 810, 2, 1)
	deliver_all()
	check(#H.MADE == 6, "after the window, given again")
end

section("the giver trusts only the host's answer, once")
do
	local H, A, B = setup(2)
	put(820, "ammo_9x19_fmj", 1, 30)
	give_amount(A, 820, 2, 10)
	local q = events(A, "give_part")[1].t.q
	QUEUE = {} -- anna's request never reaches the host: no answer from it
	-- boris forges a refusal for anna's request: from a client, not taken
	B.coop_economy_core.send("give_ans", { q = q, o = 0, w = "far" }, 1)
	check(#QUEUE == 1 and QUEUE[1].to == 1 and QUEUE[1].from == 2, "boris's forged answer is on its way to anna")
	deliver_all()
	check(A.OBJ[820].ammo == 20 and A.coop_economy_give.pending_count() == 1, "a client's answer is ignored")
	-- the host's refusal twice: the rounds come back once
	A.coop_main.on_event("economy.give_ans", CM_ENCODE({ q = q, o = 0, w = "far" }), 0)
	A.coop_main.on_event("economy.give_ans", CM_ENCODE({ q = q, o = 0, w = "far" }), 0)
	check(A.OBJ[820].ammo == 30, "back once (" .. A.OBJ[820].ammo .. ")")
	-- a yes for an unknown q, garbage
	A.coop_main.on_event("economy.give_ans", CM_ENCODE({ q = 999, o = 1 }), 0)
	A.coop_main.on_event("economy.give_ans", "garbage", 0)
	A.coop_main.on_event("economy.give_ans", CM_ENCODE({ q = q, o = 0, w = string.rep("z", 5000) }), 0)
	check(A.HANDLER_ERRORS == nil and A.OBJ[820].ammo == 30, "nothing changes, no error")
	-- no answer at all: the rounds are not given back on a timer (a late yes would double them)
	give_amount(A, 820, 2, 10)
	QUEUE = {}
	wait(A, 120000)
	check(A.OBJ[820].ammo == 20, "no answer: nothing comes back by itself")
end

-------------------------------------------------------------------------------
-- races
-------------------------------------------------------------------------------
section("races: two gifts out of one box, the giver shoots meanwhile, the box is gone, the receiver leaves")
do
	local H, A, B = setup(2)
	put(830, "ammo_9x19_fmj", 1, 30)
	give_amount(A, 830, 2, 10)
	give_amount(A, 830, 2, 10)
	check(A.OBJ[830].ammo == 10, "two gifts of 10 out of 30: 10 left at once")
	local parts = events(A, "give_part")
	check(#parts == 2 and parts[1].t.k == 20 and parts[2].t.k == 10 and parts[1].t.q ~= parts[2].t.q, "two requests, two q")
	-- the second slider max follows the box
	menu(A, 830, 2)
	check(track(A).hi == 10, "the next window's max is what is left (10)")
	key(A, DIK.DIK_ESCAPE)
	deliver_all()
	check(#H.MADE == 2 and H.MADE[1].n == 10 and H.MADE[2].n == 10, "two boxes of 10 for boris")
	H.OBJ[830].ammo = A.OBJ[830].ammo
	check(rounds_of(H, 1, "ammo_9x19_fmj") + rounds_of(H, 2, "ammo_9x19_fmj") == 30, "30 in all")

	-- the giver reloads from the box before the refusal comes: what comes back goes on top of what is left
	put(840, "ammo_9x19_fmj", 1, 30)
	give_amount(A, 840, 2, 12) -- 18 left
	A.OBJ[840].ammo = 3 -- a reload took 15
	POS[2] = { x = 40, y = 0, z = 0 }
	deliver_all()
	POS[2] = { x = 4, y = 0, z = 0 }
	check(A.OBJ[840].ammo == 15, "3 left + 12 back = 15 (" .. A.OBJ[840].ammo .. ")")
	-- the box was emptied meanwhile: the rounds go into another box of hers with room, the empty one is left alone
	H, A, B = setup(2)
	put(849, "ammo_9x19_fmj", 1, 0) -- another emptied box, first in her inventory
	put(850, "ammo_9x19_fmj", 1, 30) put(851, "ammo_9x19_fmj", 1, 45)
	give_amount(A, 850, 2, 20) -- 10 left
	A.OBJ[850].ammo = 0 -- reloaded to the last round: the host is about to destroy it
	POS[2] = { x = 40, y = 0, z = 0 }
	deliver_all()
	POS[2] = { x = 4, y = 0, z = 0 }
	check(A.OBJ[850].ammo == 0 and A.OBJ[849].ammo == 0, "boxes with no rounds (to be destroyed) get nothing")
	check(A.OBJ[851].ammo == 50 and #A.CREATED == 1 and A.CREATED[1].sec == "ammo_9x19_fmj" and A.CREATED[1].ammo == 15
		and A.CREATED[1].owner == 0, "5 fill the other box to 50, 15 in a new box of hers (" .. A.OBJ[851].ammo .. ", " ..
		tostring(A.CREATED[1] and A.CREATED[1].ammo) .. ")")
	-- the receiver leaves after the host made the box: it is his, in his inventory on the host
	H.NOW = H.NOW + 2100
	put(860, "ammo_9x19_fmj", 1, 30)
	local made = #H.MADE
	give_amount(A, 860, 2, 10)
	deliver_all()
	check(#H.MADE == made + 1 and H.MADE[#H.MADE].parent == 502, "made in boris's inventory")
	PLAYERS[2] = nil
	wait(H, 3000) wait(A, 3000)
	check(H.SE[H.MADE[#H.MADE].id].parent_id == 502 and A.OBJ[860].ammo == 20, "boris left: the box stays his, anna keeps 20")
end

-------------------------------------------------------------------------------
section("the host player gives and gets like any player")
do
	local H, A, B = setup(2)
	put(900, "ammo_9x19_fmj", 0, 30)
	check(give_amount(H, 900, 1, 10), "the host gives 10 of 30 to anna")
	check(H.OBJ[900].ammo == 20, "his box: 20")
	check(#events(H, "give_part") == 0, "no event to himself: the host decides at once")
	check(#H.MADE == 1 and H.MADE[1].parent == 501 and H.MADE[1].n == 10, "a box of 10 in anna's inventory")
	check(H.coop_economy_give.pending_count() == 0, "nothing pending")
	local g = events(H, "gift")
	check(#g == 1 and g[1].target == 1 and g[1].t.g == 0 and g[1].t.u == 10, "anna is told: g = 0 (host), u = 10")
	deliver_all()
	take_made(H, 1)
	wait(A, 1500)
	check(told(A)[1] == "host gave you: 9x19 FMJ x10.", "anna: 'host gave you: 9x19 FMJ x10.' (" .. tostring(told(A)[1]) .. ")")
	-- refused at once: the host's rounds come back at once (the host's own check of the distance comes first: the
	-- giver's machine is the authority, so only what the authority alone can find refuses here)
	H.CREATE_FAILS = true
	give_amount(H, 900, 1, 5)
	H.CREATE_FAILS = nil
	check(H.OBJ[900].ammo == 20 and refused(H, "could not") and #events(H, "give_ans") == 0, "host, box not made: back at once, told")
	POS[1] = { x = 40, y = 0, z = 0 }
	check(not menu(H, 900, 1), "anna far away: no menu entry for her")
	POS[1] = { x = 2, y = 0, z = 0 }
	-- anna gives to the host
	put(910, "ammo_9x19_fmj", 1, 30)
	give_amount(A, 910, 0, 8)
	deliver_all()
	local m = H.MADE[#H.MADE]
	check(m.parent == 0 and m.n == 8, "a box of 8 for the host's own actor")
	check(#events(H, "gift") == 1, "the host does not send an event to himself")
	take_made(H, 0)
	wait(H, 1500)
	local lines = told(H)
	check(#lines == 1 and lines[1] == "anna gave you: 9x19 FMJ x8.", "host: 'anna gave you: 9x19 FMJ x8.' (" .. tostring(lines[1]) .. ")")
end

section("the receiver: units only from the host, the old gift unchanged")
do
	local H, A, B = setup(2)
	put(920, "ammo_9x19_fmj", 2, 20)
	-- anna claims to be giving on behalf of the host (g) with units: g is only the host's word
	A.coop_economy_core.send("gift", { i = 920, u = 20, g = 0 }, 2)
	deliver_all()
	fire(B, "actor_on_item_take", B.OBJ[920])
	wait(B, 1500)
	check(told(B)[1] == "anna gave you: 9x19 FMJ x20.", "from a client g is ignored: anna named (" .. tostring(told(B)[1]) .. ")")
	put(921, "ammo_9x19_fmj", 2, 5)
	H.coop_economy_core.send("gift", { i = 921, u = "lots", g = 2 }, 2) -- the receiver himself as the giver
	H.coop_economy_core.send("gift", { i = 921, u = 5, g = 77 }, 2) -- nobody
	deliver_all()
	fire(B, "actor_on_item_take", B.OBJ[921])
	wait(B, 3000)
	check(#told(B) == 1 and B.HANDLER_ERRORS == nil, "the receiver or a stranger as g: nothing told")
end

section("texts in both languages, files")
do
	local EN = {
		st_coop_eco_give_btn = "Give", st_coop_eco_give_whom = "To: %s", st_coop_eco_item_count = "%s x%d",
		st_coop_eco_part_refused = "%s x%d did not reach %s: %s. The rounds are back.",
		st_coop_eco_part_why_far = "too far away", st_coop_eco_part_why_gone = "the player is not in the game",
		st_coop_eco_part_why_rate = "too many gifts at once", st_coop_eco_part_why_box = "the box is no longer yours on the host",
		st_coop_eco_part_why_count = "more rounds than a box holds", st_coop_eco_part_why_spawn = "the host could not make the box",
		st_coop_eco_part_why_bad = "a broken request", st_coop_eco_give_nothing = "There is nothing left to give.",
	}
	local RU = {
		st_coop_eco_give_btn = "\207\229\240\229\228\224\242\252", -- "Peredat" in cp1251
		st_coop_eco_give_to = "\207\229\240\229\228\224\242\252 %s", -- "Peredat %s" in cp1251
		st_coop_eco_item_count = "%s x%d",
	}
	for lang, want in pairs({ eng = EN, rus = RU }) do
		local xml = readfile(ROOT .. "configs/text/" .. lang .. "/st_coop_economy.xml")
		for id, text in pairs(want) do
			local body = xml:match('<string id="' .. id .. '">%s*<text>(.-)</text>')
			check(body == text, lang .. " " .. id .. " = " .. tostring(body))
		end
		local crlf = select(2, xml:gsub("\r\n", ""))
		local lf = select(2, xml:gsub("\n", ""))
		check(crlf == lf, lang .. ": CRLF throughout")
	end
	local rus = readfile(ROOT .. "configs/text/rus/st_coop_economy.xml")
	for id in pairs(EN) do
		check(rus:find('<string id="' .. id .. '">', 1, true) ~= nil, "rus has " .. id)
	end
	local ui = readfile(ROOT .. "configs/ui/ui_coop_give.xml")
	check(ui:find('encoding="windows-1251"', 1, true) ~= nil and not ui:find("[\128-\255]"), "ui_coop_give.xml: ASCII, cp1251 header")
	local buttons = 0
	for _ in ui:gmatch("<btn_") do buttons = buttons + 1 end
	check(buttons == 1 and ui:find("<btn_give", 1, true) ~= nil, "the window has one button: btn_give")
	for _, node in ipairs({ "<coop_give ", "<frame ", "<icon ", "<name ", "<whom ", "<track ", "<num " }) do
		check(ui:find(node, 1, true) ~= nil, "ui_coop_give.xml has " .. node)
	end
	check(not ui:find("cancel", 1, true) and not ui:find("half", 1, true), "no cancel, no quick buttons")
	local scr = readfile(ROOT .. "scripts/coop_economy_give.script")
	check(not scr:find("[\128-\255]") and select(2, scr:gsub("\r\n", "")) == select(2, scr:gsub("\n", "")), "coop_economy_give.script: ASCII, CRLF")
end

print(string.format("\n%d passed, %d failed", CHECKS - FAILS, FAILS))
os.exit(FAILS == 0 and 0 or 1)
