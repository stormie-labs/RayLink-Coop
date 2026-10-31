-- Task rewards for the whole group (coop_share_rewards 2 and 3, coop_reward_group + coop_tasks) on a fake host + client:
-- a player who left gets his reward on his character in the host's save, a shared reward is split, a full one is what a
-- lone player would get, and the player who comes back is told once.
-- Run: tools\test_lua.cmd reward_group
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_reward_group", "coop_tasks", "coop_quests_news" }

local function setup_world(M)
	local e = M.env
	M.share = 0
	M.on_complete = {}
	M.ObjMT.money = function(self) return self._money or 0 end
	e.get_console = function()
		return { get_integer = function(_, name) return name == "coop_share_rewards" and M.share or 0 end }
	end
	e.ini_sys = { r_bool_ex = function(_, sec, key, def)
		if key == "quest_item" then return sec == "quest_doc" end
		return def
	end }
	-- the stock function takes a server object too: the harness gives one as a table around the object
	local create = e.alife_create_item
	e.alife_create_item = function(sec, obj, t)
		M.create_props = t
		return create(sec, type(obj) == "table" and obj._o or obj, t)
	end
	local callback = e.task_manager.task_callback
	e.task_manager.task_callback = function(tsk, state)
		if state ~= e.task.completed and M.on_fail then M.on_fail() end
		return callback(tsk, state)
	end
	e.xr_effects.multifetch_remove = function() M.actor:give_money(450) end -- tasks_multifetch pays on the host's actor
	-- tasks_fetch: the artefact out of its container and the container back to the player, the leftover uses a second later
	e.xr_effects.fetch_reward_and_remove = function()
		e.alife_create_item("af_a", M.actor)
		e.alife_create_item("lead_box", M.actor)
		e.CreateTimeEvent("fetch", "fetch", 1, function()
			e.alife_create_item("left_uses", M.actor)
			e.dialogs.relocate_money(M.actor, 300, "in")
			return true
		end)
	end
	M.msgs = {}
	e.actor_menu = { set_msg = function(_, text) M.msgs[#M.msgs + 1] = text end }
	e.game.translate_string = function(id) return id end -- no string table here: the English fallbacks
	M.feed = {}
	M.ObjMT.give_game_news = function(_, caption, text) M.feed[#M.feed + 1] = { caption = caption, text = text } end
	e.ui_item = { get_sec_name = function(sec) return "name of " .. sec end }
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do M.env[n].on_game_start() end
	fire(M, "actor_on_first_update")
end

print("== setup")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup_world(Hm)
setup_world(Cm)
local proxy = Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true })
local gone = Hm.new_obj(501, "coop_player_avatar", vec(9, 0, 0), { _stalker = true }) -- offline: only the server object is used
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Hm.members = { { id = 500, peer = 1, in_world = true }, { id = 501 } }
Hm.env.coop.members = function() return Hm.members end
local PAID = {} -- character id -> RU paid through coop.money_grant_to
Hm.env.coop.money_grant_to = function(id, n)
	if id == 500 or id == 501 then
		local cap = Hm.pay_cap
		local added = cap and math.min(cap, n) or n
		PAID[id] = (PAID[id] or 0) + added
		return added
	end
	return nil, "no character"
end
boot(Hm)
boot(Cm)

local function grants()
	local out = {}
	for _, c in ipairs(Hm.money_calls) do
		if c.fn == "money_grant" and c.ok then out[#out + 1] = { c.peer, c.n } end
	end
	return out
end

local function reward_events(kind, peer)
	local out = {}
	for _, s in ipairs(Hm.sent) do
		if s.name == "coop_trw" and s.target == peer and s.payload:find(kind, 1, true) then out[#out + 1] = s.payload end
	end
	return out
end

local N = 0
local function turn_in(peer, fn, state)
	N = N + 1
	local id = "task_" .. N
	Hm.tm.task_info[id] = { id = id, stage = 1 }
	Hm.on_complete[id] = fn
	Hm.env.coop_tasks.host_note(id, "finisher", peer)
	Hm.env.task_manager.task_callback({ get_id = function() return id end }, state or Hm.env.task.completed)
	pump()
	return id
end

local function pay(n) return function() Hm.env.dialogs.relocate_money(Hm.actor, n, "in") end end

local function give(sec, n)
	return function()
		for _ = 1, n do Hm.env.alife_create_item(sec, Hm.actor) end
		Hm.env.news_manager.relocate_item(Hm.actor, "in", sec, n)
	end
end

local function counts(sec) return Hm.count(Hm.actor, sec), Hm.count(proxy, sec), Hm.count(gone, sec) end

local function fresh()
	for _, o in ipairs({ Hm.actor, proxy, gone }) do o._inv = {} end
	Hm.actor._money = 0
	PAID = {}
	Hm.news = {}
	Hm.money_news = {}
	for i = #Hm.money_calls, 1, -1 do Hm.money_calls[i] = nil end
	for i = #Hm.sent, 1, -1 do Hm.sent[i] = nil end
end

-- ---------------------------------------------------------------- rules
print("== rules")
local R = Hm.env.coop_reward_group
local A, B, C = { id = 0, peer = 0 }, { id = 500, peer = 1 }, { id = 501 }
local plan = R.money_plan(1000, { A, B, C }, 1, false)
check(#plan == 3 and plan[1].n == 333 and plan[2].n == 334 and plan[3].n == 333, "1000 over three: the remainder to the one who turned it in")
local sum = 0
for _, e in ipairs(plan) do sum = sum + e.n end
check(sum == 1000, "the shares add up to the reward")
plan = R.money_plan(2, { A, B, C }, 1, false)
check(#plan == 2 and plan[1].m == A and plan[1].n == 0 or #plan == 1 and plan[1].m == B and plan[1].n == 2, "2 over three: no empty payment")
plan = R.money_plan(1000, { A, B, C }, 7, false)
check(plan[1].m == A and plan[1].n == 334, "nobody turned it in (a script): the remainder stays with the host")
plan = R.money_plan(900, { A, B, C }, 1, true)
check(#plan == 3 and plan[1].n == 900 and plan[2].n == 900 and plan[3].n == 900, "in full: everybody gets the whole sum")

-- ---------------------------------------------------------------- the two old modes
print("== mode 0: only the player who turned it in")
Hm.share = 0
fresh()
turn_in(1, function() pay(900)(); give("medkit", 1)() end)
check(Hm.actor:money() == 0 and #grants() == 1 and grants()[1][1] == 1 and grants()[1][2] == 900, "the money goes to him")
local h, c, g = counts("medkit")
check(h == 0 and c == 1 and g == 0, "the item goes to him")
check(next(PAID) == nil, "nothing for the absent player")

print("== mode 1: money split over the players in the game, the absent player has no share")
Hm.share = 1
fresh()
turn_in(1, function() pay(900)(); give("medkit", 1)() end)
check(Hm.actor:money() == 450 and grants()[1][2] == 450, "two shares")
check(next(PAID) == nil, "nothing for the absent player")
h, c, g = counts("medkit")
check(h == 0 and c == 1 and g == 0, "the item goes to the one who turned it in")

-- ---------------------------------------------------------------- everyone, in full
print("== mode 3: everyone gets the whole reward")
Hm.share = 3
fresh()
turn_in(1, function() pay(900)(); give("medkit", 2)() end)
check(Hm.actor:money() == 900, "the host: 900")
check(#grants() == 1 and grants()[1][1] == 1 and grants()[1][2] == 900, "the client: 900")
check(PAID[501] == 900, "the absent player: 900 on his character")
check(PAID[500] == nil, "the online client is not paid twice")
h, c, g = counts("medkit")
check(h == 2 and c == 2 and g == 2, "2 items for each, the absent player's on his character")
check(#reward_events("medkit", 1) == 1, "one item line for the client, not one per unit")
local lines = 0
for _, l in ipairs(Hm.news) do if l:find("medkit", 1, true) then lines = lines + 1 end end
check(lines == 1 and Hm.news[1] == "in:medkitx2", "one item line for the host, with the amount")

print("== mode 3: a quest item stays single")
fresh()
turn_in(1, function() give("quest_doc", 1)() end)
h, c, g = counts("quest_doc")
check(h == 0 and c == 1 and g == 0, "only the one who turned it in holds it")
check(#reward_events("quest_doc", 1) == 1, "and he sees the line")

print("== mode 3: a stock item is handed to the caller as it was")
fresh()
local returned
turn_in(1, function() returned = Hm.env.alife_create_item("medkit", Hm.actor, { cond = 0.5 }) end)
check(returned and returned._parent._id == 500, "the caller gets the item of the player who turned it in")
check(Hm.create_props and Hm.create_props.cond == 0.5, "the item's properties go along")

print("== mode 3: the host turns it in")
fresh()
turn_in(0, function() pay(300)(); give("bread", 1)() end)
h, c, g = counts("bread")
check(h == 1 and c == 1 and g == 1 and Hm.actor:money() == 300 and grants()[1][2] == 300 and PAID[501] == 300, "the same for everybody")

print("== mode 3: something not a reward of the actor stays as it is")
fresh()
local other = Hm.new_obj(600, "stash", vec(1, 0, 0))
turn_in(1, function() Hm.env.alife_create_item("medkit", other) end)
check(Hm.count(other, "medkit") == 1, "an item for another object lands there")
h, c, g = counts("medkit")
check(h == 0 and c == 0 and g == 0, "and is not copied")

print("== mode 3: a failed task gives nothing to anybody")
fresh()
Hm.on_fail = function() Hm.env.alife_create_item("medkit", Hm.actor) end
turn_in(1, nil, Hm.env.task.fail)
Hm.on_fail = nil
h, c, g = counts("medkit")
check(h + c + g == 1 and g == 0, "no copies for a failed task")

print("== mode 3: the player who turned it in left before the callback")
fresh()
Hm.players = { { id = 0, is_self = true, avatar_id = 0 } }
Hm.members = { { id = 500 }, { id = 501 } }
turn_in(1, function() pay(100)(); give("bread", 1)() end)
h, c, g = counts("bread")
check(h == 1 and c == 1 and g == 1, "the item reaches both absent characters and the host")
check(PAID[500] == 100 and PAID[501] == 100 and Hm.actor:money() == 100, "so does the money")
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Hm.members = { { id = 500, peer = 1, in_world = true }, { id = 501 } }
Hm.env.coop_reward_group.take(500) -- the note of that test

print("== mode 3: a payout the stock code makes on the host's actor")
fresh()
turn_in(1, function() Hm.env.xr_effects.multifetch_remove() end)
check(Hm.actor:money() == 450 and grants()[1][2] == 450 and PAID[501] == 450, "everybody gets 450 and the host is not paid twice")

print("== mode 3: a reward paid a second later")
fresh()
turn_in(1, function()
	Hm.env.CreateTimeEvent("late", "late", 1, function() give("bread", 1)(); pay(50)(); return true end)
end)
local t = table.remove(Hm.timers)
t.f()
pump()
h, c, g = counts("bread")
check(h == 1 and c == 1 and g == 1 and PAID[501] == 50, "it reaches the group too")
check(#reward_events("bread", 1) == 1, "with its line")

print("== mode 3: a fetch hands the player's own goods back, that is no reward")
fresh()
turn_in(1, function() Hm.env.xr_effects.fetch_reward_and_remove() end)
local fetch_timer = table.remove(Hm.timers)
fetch_timer.f()
pump()
h, c, g = counts("af_a")
check(h == 0 and c == 1 and g == 0, "the artefact goes back to him alone")
h, c, g = counts("lead_box")
check(h == 0 and c == 1 and g == 0, "and the container")
h, c, g = counts("left_uses")
check(h == 0 and c == 1 and g == 0, "and the leftover uses, a second later")
check(Hm.actor:money() == 300 and PAID[501] == 300, "the fetch's money is a reward all the same")

print("== mode 3: a client leaves during the delay of a reward")
fresh()
turn_in(1, function()
	Hm.env.CreateTimeEvent("late", "late", 1, function() pay(50)(); give("bread", 1)(); return true end)
end)
Hm.players = { { id = 0, is_self = true, avatar_id = 0 } }
Hm.members = { { id = 500 }, { id = 501 } }
t = table.remove(Hm.timers)
t.f()
pump()
check(PAID[500] == 50, "the money reaches his character")
local note = Hm.env.coop_reward_group.peek(500)
check(note and note.m == 50 and note.i.bread == 1, "and the note says so")
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Hm.members = { { id = 500, peer = 1, in_world = true }, { id = 501 } }
Hm.env.coop_reward_group.take(500)

-- ---------------------------------------------------------------- everyone, shared
print("== mode 2: the money is split over everybody who played")
Hm.share = 2
fresh()
turn_in(1, pay(1000))
check(Hm.actor:money() == 333, "the host: a third")
check(grants()[1][1] == 1 and grants()[1][2] == 334, "the client who turned it in: a third and the remainder")
check(PAID[501] == 333, "the absent player: a third")

print("== mode 2: items go by turns, also from one reward to the next")
fresh()
turn_in(1, give("medkit", 4))
h, c, g = counts("medkit")
check(h + c + g == 4 and h >= 1 and c >= 1 and g >= 1, "4 items over three players, none doubled in total")
check(math.max(h, c, g) == 2, "nobody gets two before everybody has one")
turn_in(1, give("medkit", 2))
local h2, c2, g2 = counts("medkit")
check(h2 == 2 and c2 == 2 and g2 == 2, "the next reward goes on from where the last stopped")
check(#reward_events("medkit", 1) >= 1, "the client sees a line for what he got")

print("== mode 2: a fetch's artefact stays with the one who turned it in, whose turn it is does not matter")
fresh()
turn_in(1, function() Hm.env.xr_effects.fetch_reward_and_remove() end)
fetch_timer = table.remove(Hm.timers)
fetch_timer.f()
pump()
h, c, g = counts("af_a")
check(c == 1 and h + g == 0, "the artefact")
h, c, g = counts("left_uses")
check(c == 1 and h + g == 0, "the leftover")

print("== mode 2: a player who holds nothing of the reward sees no line")
Hm.env.SendScriptCallback("load_state", {}) -- the turn starts over, with the host
fresh()
turn_in(1, give("bread", 1))
check(Hm.count(Hm.actor, "bread") == 1 and #reward_events("bread", 1) == 0, "the item went to the host, the client has no line")

-- ---------------------------------------------------------------- the player comes back
print("== the absent player's note")
Hm.env.coop_reward_group.take(501)
Hm.share = 3
fresh()
turn_in(1, function() pay(900)(); give("medkit", 2)() end)
turn_in(0, function() pay(100)(); give("bread", 1)() end)
local saved = {}
Hm.env.SendScriptCallback("save_state", saved)
check(type(saved.coop_reward_group) == "table", "kept in the host's save")
Hm.env.coop_reward_group.take(501)
Hm.env.SendScriptCallback("load_state", saved)

Hm.pay_cap = 10
turn_in(1, pay(100))
Hm.pay_cap = nil
local n = Hm.env.coop_reward_group.peek(501)
check(n and n.m == 1010 and n.c == 3, "1010 RU (what really came), 3 tasks")
check(n and n.i.medkit == 2 and n.i.bread == 1, "every item by name, across a save and a load")

Hm.members = { { id = 500, peer = 1, in_world = true }, { id = 501, peer = 2, in_world = true } }
fresh()
Hm.handlers.coop_tl_req("", 2)
pump()
local ev = reward_events("away", 2)
check(#ev == 1, "the note goes to him when his game asks for the tasks")
Hm.handlers.coop_tl_req("", 2)
pump()
check(#reward_events("away", 2) == 1, "only once")
Hm.handlers.coop_tl_req("", 1)
pump()
check(#reward_events("away", 1) == 0, "nothing for a player who was here")
check(Hm.env.coop_reward_group.peek(501) == nil, "the note is gone")

print("== the client shows the note")
Hm.members = { { id = 500, peer = 1, in_world = true }, { id = 501 } }
Hm.env.coop_reward_group.note(500, "m", 1500)
Hm.env.coop_reward_group.note_item(500, "medkit", 2)
Hm.env.coop_reward_group.note_item(500, "bread", 1)
Hm.env.coop_reward_group.note(500, "c", 1)
Hm.handlers.coop_tl_req("", 1)
pump()
check(Cm.msgs[#Cm.msgs] == "Rewards while you were away", "the line over the game says what happened")
local f = Cm.feed[#Cm.feed]
check(f and f.caption == "Rewards while you were away", "the PDA feed gets the message")
check(f and f.text:find("1500", 1, true) ~= nil, "with the money")
check(f and f.text:find("name of medkit x2", 1, true) ~= nil and f.text:find("name of bread x1", 1, true) ~= nil, "and every item by name, with its count: " .. tostring(f and f.text))
check(Hm.env.coop_reward_group.parse_items("medkit:2,bread:1").medkit == 2, "the list on the wire reads back")

print("== a long absence does not grow the note for ever")
for i = 1, 40 do Hm.env.coop_reward_group.note_item(501, "item_" .. i, 2) end
local long = Hm.env.coop_reward_group.peek(501)
local kinds = 0
for _ in pairs(long.i) do kinds = kinds + 1 end
check(kinds == 32 and long.x == 16, "32 names, the rest counted")
Hm.env.coop_reward_group.note_item(501, "item_1", 1)
check(long.i.item_1 == 3, "a known item still adds up")
Hm.env.coop_reward_group.take(501)

print("== a save from before the mode")
Hm.env.SendScriptCallback("load_state", {})
check(Hm.env.coop_reward_group.peek(501) == nil, "nothing to tell")

print("== without coop.members (an older exe) only the host is the group")
Hm.env.coop.members = nil
fresh()
turn_in(1, pay(70))
check(Hm.actor:money() == 70 and #grants() == 0, "no failure, the host keeps the reward")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
