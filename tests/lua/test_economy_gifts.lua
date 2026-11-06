-- Anomaly Coop temp test (economy, gifts): the receiver of an item is told who gave it ("anna gave you: Medkit."), the
-- giver is not; a gift of money is told to the receiver through the stock tip (news_manager.send_tip) as well.
-- coop_economy_core / _money on a host and two clients with stub engines. Not shipped.
--   The giver's inventory action sends economy.gift { i = host id of the item } to the receiver; the receiver keeps it
--   pending and tells it only when the item is really in his inventory (the host may refuse the transfer).
dofile("tests/lua/support/harness_economy.lua")

local NAMES = { medkit = "Medkit", bandage = "Bandage", vodka = "Vodka", bread = "Bread", wpn_pm = "PM pistol",
	medkit_army = "Army medkit" }

local function stubs(W)
	local inv = {}
	function inv.InitProperties(self, obj, bag) end
	function inv.UpdateCharacter(self) end
	W.ui_inventory = { UIInventory = inv }
	W.GetCursorPosition = function() return { x = 0, y = 0 } end
	W.ui_item = { get_sec_name = function(sec) return NAMES[sec] end }
	-- every stock tip with the time it was sent and the actor it was sent to
	W.TIP_LOG = {}
	W.news_manager = { send_tip = function(actor, text)
		W.TIPS[#W.TIPS + 1] = text
		W.TIP_LOG[#W.TIP_LOG + 1] = { text = text, at = W.NOW, actor = actor }
	end }
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
	for _, W in pairs(WORLDS) do
		for _, n in ipairs({ "coop_economy_core", "coop_economy_money" }) do load_script(W, n) end
		for _, n in ipairs({ "coop_economy_core", "coop_economy_money" }) do
			if W[n].on_game_start then W[n].on_game_start() end
		end
	end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

-- local id of the character of player q in world W (0 = the actor of W)
local function avatar_in(W, q)
	if q == W.PEER then return 0 end
	return W.coop.avatar_of(q)
end

-- an item (same id in every world: only the pair 0 / proxy differs) in the inventory of player `owner`
local function put(id, section, owner, sections)
	for _, W in pairs(WORLDS) do
		add_item(W, id, sections and sections[W.PEER] or section, avatar_in(W, owner))
	end
end

-- the host applied the transfer: every world sees the item under the receiver's character
local function move(id, to, take)
	for _, W in pairs(WORLDS) do
		local parent = avatar_in(W, to)
		W.SE[id].parent_id = parent
		W.OBJ[id]._parent = parent
	end
	if take then fire(WORLDS[to], "actor_on_item_take", WORLDS[to].OBJ[id]) end
end

-- "Give to <nick>" in the inventory menu of machine W
local function give(W, id, to)
	local inv = setmetatable({ properties = {}, item_props = { Reset = function() end } }, { __index = W.ui_inventory.UIInventory })
	inv:InitProperties(W.OBJ[id], "actor_bag")
	for i = 1, 8 do
		if inv:coop_eco_NameGive(id, "actor_bag", "", i) == "Give to " .. PLAYERS[to].nick then
			inv:coop_eco_ActionGive(id, "actor_bag", "", i)
			return true
		end
	end
	return false
end

-- the item gift lines W was told
local function told(W)
	local out = {}
	for _, l in ipairs(W.TIP_LOG) do
		if l.text:find(" gave you: ", 1, true) then out[#out + 1] = l end
	end
	return out
end

local function gift_events(W)
	local out = {}
	for _, e in ipairs(W.SENT) do
		if e.name == "economy.gift" then out[#out + 1] = { target = e.target, t = CM_DECODE(e.payload) } end
	end
	return out
end

local function wait(W, ms, step)
	step = step or 250
	local done = 0
	while done < ms do
		tick(W, step)
		done = done + step
	end
end

-------------------------------------------------------------------------------
section("gift client -> client: the receiver is told, the giver is not")
do
	local H, A, B = setup(2)
	check(B.CB.actor_on_item_take and #B.CB.actor_on_item_take == 1, "the receiver listens to actor_on_item_take")
	put(860, "medkit", 1)
	check(give(A, 860, 2), "anna gives the medkit to boris from the menu")
	check(A.TRANSFERS and A.TRANSFERS[1][1] == 860 and A.TRANSFERS[1][2] == avatar_in(A, 2), "the engine transfer is asked for")
	local ev = gift_events(A)
	check(#ev == 1 and ev[1].target == 2 and ev[1].t.i == 860, "economy.gift { i = 860 } goes to boris (peer 2)")
	deliver_all()
	check(B.HANDLER_ERRORS == nil and #told(B) == 0, "the event alone tells nothing: the item is not here yet")
	move(860, 2, true)
	wait(B, 1500)
	local lines = told(B)
	check(#lines == 1 and lines[1].text == "anna gave you: Medkit.", "boris: 'anna gave you: Medkit.' (" .. tostring(lines[1] and lines[1].text) .. ")")
	check(lines[1] and lines[1].actor == B.db.actor, "through the stock tip, to boris's actor")
	wait(B, 5000)
	check(#told(B) == 1, "told once")
	wait(A, 5000)
	check(#told(A) == 0 and has(A.TIPS, "Medkit given to boris"), "the giver sees only his own 'given to' line")
	wait(H, 5000)
	check(#told(H) == 0 and #gift_events(H) == 0, "the host player is not told, sends nothing")
end

section("the item came before the event")
do
	local H, A, B = setup(2)
	put(861, "bandage", 1)
	give(A, 861, 2) -- the event is queued, not delivered yet
	move(861, 2, true) -- the item is here first: nothing pending, nothing told
	wait(B, 2000)
	check(#told(B) == 0, "an item without an event tells nothing")
	deliver_all()
	wait(B, 1500)
	local lines = told(B)
	check(#lines == 1 and lines[1].text == "anna gave you: Bandage.", "the event finds the item here: told")
end

section("the event came first, the item later without actor_on_item_take")
do
	local H, A, B = setup(2)
	put(862, "vodka", 1)
	give(A, 862, 2)
	deliver_all()
	wait(B, 3000)
	check(#told(B) == 0, "waiting for the item")
	move(862, 2, false) -- the inventory changed, but no callback came: the update finds it
	wait(B, 2000)
	local lines = told(B)
	check(#lines == 1 and lines[1].text == "anna gave you: Vodka.", "found by the update and told")
end

section("the host refused: the item never comes")
do
	local H, A, B = setup(2)
	put(863, "bread", 1)
	give(A, 863, 2)
	deliver_all()
	wait(B, 16000)
	check(#told(B) == 0 and B.HANDLER_ERRORS == nil, "nothing told while it does not come")
	-- the entry is gone after 15 s: an item that comes later (picked up from the floor) is not called a gift
	move(863, 2, true)
	wait(B, 3000)
	check(#told(B) == 0, "the pending gift expired after 15 s")
	-- a gift that comes within 15 s is told
	put(864, "bread", 1)
	give(A, 864, 2)
	deliver_all()
	wait(B, 14000)
	move(864, 2, true)
	wait(B, 1500)
	check(#told(B) == 1, "an item that comes within 15 s is told")
end

section("the host player as the receiver and as the giver")
do
	local H, A, B = setup(2)
	put(865, "vodka", 1)
	give(A, 865, 0)
	local ev = gift_events(A)
	check(#ev == 1 and ev[1].target == 0, "anna -> host: the event goes to peer 0")
	deliver_all()
	move(865, 0, true)
	wait(H, 1500)
	local lines = told(H)
	check(#lines == 1 and lines[1].text == "anna gave you: Vodka.", "the host player is told")
	check(#told(A) == 0 and #told(B) == 0, "nobody else")

	put(866, "bread", 0)
	check(give(H, 866, 1), "the host gives bread to anna")
	ev = gift_events(H)
	check(#ev == 1 and ev[1].target == 1 and ev[1].t.i == 866, "host -> anna: economy.gift to peer 1")
	deliver_all()
	move(866, 1, true)
	wait(A, 1500)
	lines = told(A)
	check(#lines == 1 and lines[1].text == "host gave you: Bread.", "anna: 'host gave you: Bread.'")
	check(#told(H) == 1 and #told(B) == 0, "the host is not told of his own gift")
end

section("the name is the receiver's own, not the packet's")
do
	local H, A, B = setup(2)
	put(867, "medkit", 1, { [2] = "medkit_army" })
	A.coop_economy_core.send("gift", { i = 867, n = "FAKE NAME", s = "wpn_pm" }, 2)
	deliver_all()
	move(867, 2, true)
	wait(B, 1500)
	local lines = told(B)
	check(#lines == 1 and lines[1].text == "anna gave you: Army medkit.", "the name of the item boris has")
	-- a section without a name: the section
	put(868, "strange_thing", 1)
	give(A, 868, 2)
	deliver_all()
	move(868, 2, true)
	wait(B, 1500)
	lines = told(B)
	check(#lines == 2 and lines[2].text == "anna gave you: strange_thing.", "no inventory name: the section")
end

section("items given within 1.5 s are one line")
do
	local H, A, B = setup(2)
	local secs = { "medkit", "bandage", "vodka", "bread", "wpn_pm" }
	for i, s in ipairs(secs) do put(869 + i, s, 1) end
	-- two items
	give(A, 870, 2) give(A, 871, 2)
	deliver_all()
	move(870, 2, true)
	tick(B, 300)
	move(871, 2, true)
	wait(B, 1500)
	local lines = told(B)
	check(#lines == 1 and lines[1].text == "anna gave you: Medkit, Bandage.", "two: one line (" .. tostring(lines[1] and lines[1].text) .. ")")
	wait(B, 3000)
	-- three items: no "more"
	for i = 1, 3 do put(880 + i, secs[i + 2], 1) give(A, 880 + i, 2) end
	deliver_all()
	for i = 1, 3 do move(880 + i, 2, true) end
	wait(B, 1500)
	lines = told(B)
	check(#lines == 2 and lines[2].text == "anna gave you: Vodka, Bread, PM pistol.", "three: all named")
	wait(B, 3000)
	-- five items: three names and the rest counted
	for i = 1, 5 do put(890 + i, secs[i], 1) give(A, 890 + i, 2) end
	deliver_all()
	for i = 1, 5 do move(890 + i, 2, true) end
	wait(B, 1500)
	lines = told(B)
	check(#lines == 3 and lines[3].text == "anna gave you: Medkit, Bandage, Vodka and 2 more.",
		"five: 'Medkit, Bandage, Vodka and 2 more' (" .. tostring(lines[3] and lines[3].text) .. ")")
	wait(B, 3000)
	-- two givers at once: a line each
	put(896, "medkit", 1) put(897, "vodka", 0)
	give(A, 896, 2) give(H, 897, 2)
	deliver_all()
	move(896, 2, true) move(897, 2, true)
	wait(B, 1500)
	lines = told(B)
	local got = {}
	for i = 4, #lines do got[lines[i].text] = true end
	check(#lines == 5 and got["anna gave you: Medkit."] and got["host gave you: Vodka."], "two givers: a line each")
end

section("a stream of gifts: at most one line per 1.5 s and giver")
do
	local H, A, B = setup(2)
	for i = 1, 40 do
		local id = 1000 + i
		put(id, "bandage", 1)
		give(A, id, 2)
		deliver_all()
		move(id, 2, true)
		tick(B, 150) -- 40 items in 6 s
	end
	wait(B, 3000)
	local lines = told(B)
	local ok_gap = true
	for i = 2, #lines do
		if lines[i].at - lines[i - 1].at < 1500 then ok_gap = false end
	end
	check(#lines >= 2 and #lines <= 6 and ok_gap, "lines at least 1.5 s apart (" .. #lines .. " lines for 40 items)")
	local counted = 0
	for _, l in ipairs(lines) do
		local names = select(2, l.text:gsub("Bandage", ""))
		local more = tonumber(l.text:match("and (%d+) more")) or 0
		counted = counted + names + more
	end
	check(counted == 40, "every item is in a line (" .. counted .. ")")
end

section("repeats, the pending limit")
do
	local H, A, B = setup(2)
	-- the same id again refreshes its entry (15 s from the last event)
	put(1100, "vodka", 1)
	give(A, 1100, 2)
	deliver_all()
	wait(B, 10000)
	A.coop_economy_core.send("gift", { i = 1100 }, 2)
	deliver_all()
	wait(B, 10000)
	move(1100, 2, true)
	wait(B, 1500)
	check(#told(B) == 1, "a repeated event refreshes the entry")
	-- the same id many times is one entry, one line
	put(1101, "bread", 1)
	for _ = 1, 10 do A.coop_economy_core.send("gift", { i = 1101 }, 2) end
	deliver_all()
	move(1101, 2, true)
	wait(B, 3000)
	local lines = told(B)
	check(#lines == 2 and lines[2].text == "anna gave you: Bread.", "ten events of one item: one line, one name")
	-- at most 32 pending: the oldest go first
	for i = 1, 40 do A.coop_economy_core.send("gift", { i = 1200 + i }, 2) end
	deliver_all()
	check(B.HANDLER_ERRORS == nil, "40 pending gifts are no error")
	put(1201, "medkit", 1) put(1240, "bandage", 1)
	move(1201, 2, true) move(1240, 2, true)
	wait(B, 1500)
	lines = told(B)
	check(#lines == 3 and lines[3].text == "anna gave you: Bandage.", "the newest is kept, the oldest (over 32) dropped")
end

section("garbage and strangers tell nothing")
do
	local H, A, B = setup(2)
	put(1300, "medkit", 2) -- boris has it already
	local n = #B.TIP_LOG
	for _, t in ipairs({ {}, { i = "x" }, { i = 0 }, { i = -1 }, { i = 65535 }, { i = 1e9 }, { i = 2.5 }, { i = "1e400" },
		{ i = true }, { x = 1300 }, { i = 502 } --[[ boris's own character, his actor (0) there ]] }) do
		A.coop_economy_core.send("gift", t, 2)
	end
	A.coop.send_event("economy.gift", "garbage;;==", 2)
	A.coop.send_event("economy.gift", "", 2)
	deliver_all()
	-- from nobody in the session, from boris himself, from a negative peer (the bus would not send these: straight into Lua)
	B.coop_main.on_event("economy.gift", CM_ENCODE({ i = 1300 }), 7)
	B.coop_main.on_event("economy.gift", CM_ENCODE({ i = 1300 }), 2)
	B.coop_main.on_event("economy.gift", CM_ENCODE({ i = 1300 }), -1)
	B.coop_main.on_event("economy.gift", nil, 1)
	wait(B, 3000)
	check(B.HANDLER_ERRORS == nil, "no handler error")
	check(#B.TIP_LOG == n, "nothing told")
	-- the callback with what the engine might pass
	for _, v in ipairs({ {}, { 1 }, { "x" }, { { id = function() error("boom") end } } }) do
		check(pcall(fire, B, "actor_on_item_take", unpack(v)), "actor_on_item_take with garbage is no error")
	end
	-- the host gets a gift of the host's actor id: refused too
	A.coop_economy_core.send("gift", { i = 0 }, 0)
	deliver_all()
	wait(H, 3000)
	check(H.HANDLER_ERRORS == nil and #told(H) == 0, "id 0 to the host: nothing")
end

section("the giver: a broken bus does not break the menu")
do
	local H, A, B = setup(2)
	put(1400, "medkit", 1)
	local send = A.coop.send_event
	A.coop.send_event = function() error("bus down") end
	check(pcall(give, A, 1400, 2), "the action does not throw")
	check(A.TRANSFERS and #A.TRANSFERS == 1 and has(A.TIPS, "Medkit given to boris"), "the transfer and the line still happen")
	A.coop.send_event = send
	-- a receiver who left between the menu and the click: the send fails quietly
	put(1401, "medkit", 1)
	local inv = setmetatable({ properties = {}, item_props = { Reset = function() end } }, { __index = A.ui_inventory.UIInventory })
	inv:InitProperties(A.OBJ[1401], "actor_bag")
	local gone = PLAYERS[2]
	PLAYERS[2] = nil
	check(pcall(inv.coop_eco_ActionGive, inv, 1401, "actor_bag", "", 2), "a receiver who left: no error")
	PLAYERS[2] = gone
	check(#gift_events(A) == 0, "nothing sent")
end

section("money: the receiver sees the gift through the stock tip, the giver does not")
do
	local H, A, B = setup(2)
	check(A.coop_economy_money.give_money(2, 500), "anna gives boris 500 RU")
	-- the engine's host ledger credits boris and tells his machine (coop_money.cpp fire_note on the receiver only)
	fire(B, "coop_money_note", "received", 1, 500)
	local got = nil
	for _, l in ipairs(B.TIP_LOG) do if l.text == "anna gave you 500 RU." then got = l end end
	check(got ~= nil and got.actor == B.db.actor, "boris: 'anna gave you 500 RU.' through news_manager.send_tip")
	check(#B.HUD == 0, "not the HUD fallback")
	local giver_told = false
	for _, l in ipairs(A.TIP_LOG) do if l.text:find("gave you", 1, true) then giver_told = true end end
	check(not giver_told and has(A.TIPS, "You gave 500 RU to boris"), "anna sees only 'You gave 500 RU to boris.'")
	check(#told(H) == 0 and not has(H.TIPS, "gave you"), "the host player, not part of it, sees nothing")
end

section("texts in both languages")
do
	local RU = {
		st_coop_eco_item_in = "%s \239\229\240\229\228\224\235 \226\224\236: %s.",
		st_coop_eco_item_in_more = "%s \232 \229\249\184 %d",
	}
	local EN = { st_coop_eco_item_in = "%s gave you: %s.", st_coop_eco_item_in_more = "%s and %d more" }
	for lang, want in pairs({ eng = EN, rus = RU }) do
		local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_economy.xml", "rb"))
		local xml = fh:read("*a")
		fh:close()
		for id, text in pairs(want) do
			local body = xml:match('<string id="' .. id .. '">%s*<text>(.-)</text>')
			check(body == text, lang .. " " .. id .. " = " .. tostring(body))
		end
		local crlf = select(2, xml:gsub("\r\n", ""))
		local lf = select(2, xml:gsub("\n", ""))
		check(crlf == lf and crlf > 0, lang .. ": CRLF line ends only")
		check(not xml:find("\208[\128-\191]") and not xml:find("\209[\128-\191]") or lang == "eng", lang .. ": no UTF-8 Cyrillic")
	end
end

section("single player and no engine: inert")
do
	local H = setup(0)
	H.ACTIVE = false
	put(1500, "medkit", 0)
	check(pcall(fire, H, "actor_on_item_take", H.OBJ[1500]), "item take outside a session")
	H.coop_main.on_event("economy.gift", CM_ENCODE({ i = 1500 }), 1)
	wait(H, 3000)
	check(#H.SENT == 0 and #H.TIP_LOG == 0 and H.HANDLER_ERRORS == nil, "nothing sent, nothing told")
	-- an exe without co-op: the script loads and on_game_start is quiet
	local W = make_world(5)
	PLAYERS[5] = { nick = "solo", proxy = 505 }
	stubs(W)
	W.coop = nil
	load_script(W, "coop_economy_core")
	load_script(W, "coop_economy_money")
	check(pcall(W.coop_economy_money.on_game_start), "on_game_start without the engine")
	check(W.CB.actor_on_item_take == nil and W.CB.actor_on_update == nil, "nothing registered")
	PLAYERS[5], WORLDS[5] = nil, nil
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
