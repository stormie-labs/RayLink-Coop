-- Anomaly Coop messages test (docs/MESSAGES.md): the group's shared journal in every player's PDA feed.
--   * tasks (new / updated / complete / fail / reversed): one message per event per machine, the player who did it
--     named for the others ("player_b took a task"), the stock text for the one who did it;
--   * encyclopedia: an article another player opened is announced (not silent), a burst is summed up;
--   * achievements: the earner's nick in the toast of the others.
-- Three machines: host (peer 0, stalker_host), client A (peer 1, player_a), client B (peer 2, player_b).
-- Run: tools\test_lua.cmd messages
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_tasks", "coop_quests_news", "coop_quests_pda" }

-- ---------------------------------------------------------------- the real strings (eng, rus)
local function read_strings(lang)
	local fh = assert(io.open("gamedata/configs/text/" .. lang .. "/st_coop_news.xml", "rb"), "st_coop_news.xml " .. lang)
	local src = fh:read("*a")
	fh:close()
	local t = {}
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do t[id] = text end
	return t, src
end
local ENG, ENG_SRC = read_strings("eng")
local RUS, RUS_SRC = read_strings("rus")

-- the stock captions of news_manager.send_task (st_*.xml of the game), for the fallback line
local TR = setmetatable({ general_update_task = "Task updated", general_new_task = "New task" }, { __index = ENG })

local function exists(name)
	local fh = io.open("gamedata/scripts/" .. name .. ".script", "r")
	if fh then fh:close() end
	return fh ~= nil
end

-- ---------------------------------------------------------------- machines
local function setup(M, nick)
	local e = M.env
	M.nick = nick
	M.stock, M.feed, M.talk, M.sounds, M.tips = {}, {}, {}, {}, {}
	e.game = { translate_string = function(s) return TR[s] or s end, get_game_time = function() return NOW end }
	e.news_manager.send_task = function(a, typ, tsk)
		if M.fail_stock then error("No matching overload found, candidates: give_talk_message2") end
		M.stock[#M.stock + 1] = { typ = typ, title = tsk:get_title(), icon = tsk:get_icon_name(), id = tsk:get_id() }
	end
	e.news_manager.send_tip = function(a, text, ...) M.tips[#M.tips + 1] = text end
	M.treasure = {}
	e.news_manager.send_treasure = function(p) M.treasure[#M.treasure + 1] = p end
	e.treasure_manager = { caches = {}, set_random_stash = function(spot, hint, x, id)
		e.news_manager.send_treasure(0) -- stock: the spot is added, the line follows
		M.stash_spots = (M.stash_spots or 0) + 1
	end }
	e.xr_sound = { set_sound_play = function(id, snd) M.sounds[#M.sounds + 1] = snd end }
	e.utils_obj = { play_sound = function(snd) M.sounds[#M.sounds + 1] = snd end }
	M.actor.give_game_news = function(self, c, t, i, d, s) M.feed[#M.feed + 1] = { c = c, t = t, i = i, ms = s } end
	M.actor.give_talk_message2 = function(self, c, t, i, p) M.talk[#M.talk + 1] = { c = c, t = t, i = i } end
	e.coop.story_local_task = function() return true end

	-- the stock chain behind a given task: CGameTaskManager::GiveGameTaskToActor -> actor_on_task_callback -> send_task("new")
	local cls = e.task_manager.CRandomTask
	local give = cls.give_task
	cls.give_task = function(self, id, giver)
		give(self, id, giver)
		local et = M.engine_tasks[id]
		et.get_title = function() return "title_" .. id end
		et.get_icon_name = function() return "icon_" .. id end
		e.news_manager.send_task(M.actor, "new", et)
	end
	cls.set_task_cancelled = function(self, id)
		if self.task_info[id] then self.task_info[id].forced_status = "fail" self.task_info[id].cancelled_by_actor = true end
	end
	-- stock task_manager.task_callback sends "fail" itself
	local cb0 = e.task_manager.task_callback
	e.task_manager.task_callback = function(tsk, state)
		if state == e.task.fail then e.news_manager.send_task(M.actor, "fail", tsk) end
		return cb0(tsk, state)
	end
	for _, id in ipairs({ "nt_1", "nt_2", "nt_3", "nt_4", "nt_5", "nt_6", "nt_7", "nt_local" }) do M.ini[id] = {} end

	-- encyclopedia, achievements (as in test_quests.lua)
	local unl = {}
	M.ency_unl = unl
	e.ui_pda_encyclopedia_tab = {
		is_unlocked_article = function(s) return unl[s] == true end,
		is_unlocked_note = function(s) return unl[s] == true end,
		set_article = function() M.set_article = (M.set_article or 0) + 1 end,
		UpdateName = function(s) return s end,
		unlock_article = function(s)
			if unl[s] then return false end
			unl[s] = true
			e.ui_pda_encyclopedia_tab.set_article(s)
			e.actor_menu.set_notification()
			return true
		end,
		unlock_note = function(s)
			if unl[s] then return false end
			unl[s] = true
			e.actor_menu.set_notification()
			return true
		end,
	}
	e.actor_menu = { set_notification = function() M.notif = (M.notif or 0) + 1 end }
	M.achv = {}
	e.game_statistics = { has_actor_achievement = function(n) return M.achv[n] == true end }
	-- game_statistics.actor_on_achievement_earned: the toast of the earned achievement
	e.RegisterScriptCallback("actor_on_achievement_earned", function(n, msg)
		M.achv[n] = true
		if msg and msg ~= "" then e.news_manager.send_tip(M.actor, msg, nil, n, nil, nil) end
	end)
	e.game_achievements = {
		heavy_pockets_rewards = function()
			e.SendScriptCallback("actor_on_achievement_earned", "heavy_pockets", "st_achievement_1_unlock")
		end,
		iron_curtain_rewards = function()
			M.actor:give_money(40000)
			e.SendScriptCallback("actor_on_achievement_earned", "iron_curtain", "st_achievement_22_unlock")
		end,
	}
end

-- the engine of one machine checks the running tasks (CGameTaskManager::UpdateTasks)
local function engine_check(M)
	local e = M.env
	for id, t in pairs(M.engine_tasks) do
		if t.state == "in" then
			if e.task_manager.task_complete(id) then
				t.state = "done"
				e.news_manager.send_task(M.actor, "complete", t) -- bind_stalker_ext.actor_on_task_callback
				e.task_manager.task_callback(t, e.task.completed)
			elseif e.task_manager.task_fail(id) then
				t.state = "fail"
				e.task_manager.task_callback(t, e.task.fail)
			end
		end
	end
end

-- a client's engine applies the host's copy of a task (apply_record -> GiveGameTaskToActor -> actor_on_task_callback)
local function engine_apply_new(M, id)
	local et = { state = "in", get_id = function() return id end, get_title = function() return "title_" .. id end,
		get_icon_name = function() return "icon_" .. id end }
	M.engine_tasks[id] = et
	M.env.news_manager.send_task(M.actor, "new", et)
end

local function clear(...)
	for _, M in ipairs({ ... }) do M.stock, M.feed, M.talk, M.sounds, M.tips = {}, {}, {}, {}, {} end
end

local function sent_events(M, name)
	local n = 0
	for _, s in ipairs(M.sent) do if s.name == name then n = n + 1 end end
	return n
end

print("== setup")
local Hm = machine("host", 0)
local Am = machine("client", 1)
local Bm = machine("client", 2)
local ALL = { Hm, Am, Bm }
for _, M in ipairs(ALL) do
	M.env.task = { completed = 2, fail = 0 }
	setup(M, M == Hm and "stalker_host" or M == Am and "player_a" or "player_b")
end
Hm.new_obj(501, "coop_player_avatar", vec(4, 0, 0), { _stalker = true }) -- A's and B's characters on the host
Hm.new_obj(502, "coop_player_avatar", vec(6, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, nick = "stalker_host" }, { id = 1, nick = "player_a", avatar_id = 501 },
	{ id = 2, nick = "player_b", avatar_id = 502 } }
Am.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Am.new_obj(502, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Am.players = { { id = 0, nick = "stalker_host", avatar_id = 500 }, { id = 1, is_self = true, nick = "player_a" },
	{ id = 2, nick = "player_b", avatar_id = 502 } }
Bm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Bm.new_obj(501, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Bm.players = { { id = 0, nick = "stalker_host", avatar_id = 500 }, { id = 1, nick = "player_a", avatar_id = 501 },
	{ id = 2, is_self = true, nick = "player_b" } }

for _, M in ipairs(ALL) do
	for _, n in ipairs(SCRIPTS) do if exists(n) then load_script(M, n) end end
	for _, n in ipairs(SCRIPTS) do
		local mod = M.env[n]
		if type(mod) == "table" and mod.on_game_start then mod.on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

-- ---------------------------------------------------------------- strings
print("== strings")
do
	local need = { "st_coop_news_task_new_by", "st_coop_news_task_complete_by", "st_coop_news_task_fail_by",
		"st_coop_news_task_cancel_by", "st_coop_news_article_caption", "st_coop_news_article_by", "st_coop_news_articles_many" }
	local function count_s(s) local n = 0 for _ in s:gmatch("%%s") do n = n + 1 end return n end
	local missing, mismatch = {}, {}
	for _, id in ipairs(need) do
		if not (ENG[id] and RUS[id]) then
			missing[#missing + 1] = id
		elseif count_s(ENG[id]) ~= count_s(RUS[id]) then
			mismatch[#mismatch + 1] = id
		end
	end
	check(#missing == 0, "every message string exists in eng and rus" .. (#missing > 0 and (": " .. table.concat(missing, ",")) or ""))
	check(#mismatch == 0, "eng and rus have the same number of %s")
	check(ENG_SRC:find("windows-1251", 1, true) and RUS_SRC:find("windows-1251", 1, true) and not ENG_SRC:find("[^\r]\n")
		and not RUS_SRC:find("[^\r]\n"), "cp1251 header, CRLF line ends")
	check(ENG.st_coop_news_task_new_by == "%s took a task", "eng: nick first")
	check(exists("coop_quests_news"), "coop_quests_news.script exists")
end

-- ---------------------------------------------------------------- tasks: new
print("== a client takes a task: the others see who, the client sees the stock line")
Bm.env.task_manager.get_task_manager():give_task("nt_1", 700)
pump()
check(#Hm.stock == 0 and #Hm.feed == 1, "host: one line in the feed, no stock line (the nick variant replaces it)")
check(Hm.feed[1] and Hm.feed[1].c == "player_b took a task" and Hm.feed[1].t == "title_nt_1." and Hm.feed[1].i == "icon_nt_1",
	"host: caption names player_b, the text is the task title, the icon is the task's")
check(Hm.sounds[1] == "pda_task", "host: the stock PDA sound")
check(#Am.stock == 0 and #Am.feed == 1 and Am.feed[1].c == "player_b took a task" and Am.feed[1].t == "title_nt_1.",
	"client A: one line with player_b's nick")
check(#Bm.feed == 0 and #Bm.stock == 1 and Bm.stock[1].typ == "new" and Bm.stock[1].title == "title_nt_1"
	and Bm.stock[1].icon == "icon_nt_1" and Bm.stock[1].id == "nt_1", "client B: the stock \"new\" line for its own action, no nick")
check(Bm.sounds[1] == nil or Bm.sounds[1] ~= "x", "client B: sound is the stock function's job")
-- the client engines apply the host's copy: their stock callback fires send_task("new") again -> swallowed
engine_apply_new(Am, "nt_1")
engine_apply_new(Bm, "nt_1")
check(#Am.stock == 0 and #Am.feed == 1 and #Bm.stock == 1 and #Bm.feed == 0, "the engine's own callback on the copy adds nothing (no duplicates)")

print("== the host takes a task in its own dialog")
clear(Hm, Am, Bm)
Hm.talking = true
Hm.env.task_manager.get_task_manager():give_task("nt_2", 700)
Hm.talking = false
pump()
check(#Hm.stock == 1 and Hm.stock[1].typ == "new" and #Hm.feed == 0, "host: its own action, the stock line, no nick")
check(#Am.feed == 1 and Am.feed[1].c == "stalker_host took a task" and #Bm.feed == 1 and Bm.feed[1].c == "stalker_host took a task",
	"clients: the host is named")

print("== a task given by a script (nobody took it): nobody is named")
clear(Hm, Am, Bm)
Hm.env.task_manager.get_task_manager():give_task("nt_3", 700) -- not in a dialog, not a request
pump()
check(#Hm.stock == 1 and #Am.stock == 1 and #Bm.stock == 1 and #Hm.feed + #Am.feed + #Bm.feed == 0,
	"everybody gets the stock line, nobody is named")

print("== who caused an event: one rule for the lines and for any other report")
check(Hm.env.coop_tasks.news_actor("new", "nt_2") == 0, "a task given in the host's dialog: the host (0)")
check(Hm.env.coop_tasks.news_actor("new", "nt_1") == 2, "a task a client asked for: that client")
check(Hm.env.coop_tasks.news_actor("new", "nt_3") == nil, "a task a script gave: nobody")
check(Bm.env.coop_tasks.news_actor("new", "nt_1") == nil, "a client does not know (host only)")

-- ---------------------------------------------------------------- tasks: complete
print("== a client turns a task in")
clear(Hm, Am, Bm)
Bm.env.task_manager.get_task_manager():set_task_completed("nt_1")
pump()
engine_check(Hm)
pump()
check(#Hm.feed == 1 and Hm.feed[1].c == "player_b completed a task" and Hm.feed[1].t == "title_nt_1." and #Hm.stock == 0,
	"host: \"player_b completed a task\"")
check(#Am.feed == 1 and Am.feed[1].c == "player_b completed a task" and #Am.stock == 0, "client A: the same")
check(#Bm.stock == 1 and Bm.stock[1].typ == "complete" and #Bm.feed == 0, "client B: the stock \"complete\" line")
check(sent_events(Hm, "coop_tn") >= 1, "the host sent the news event")

print("== a script completes a task a client took: the taker is named for the others")
clear(Hm, Am, Bm)
Am.env.task_manager.get_task_manager():give_task("nt_4", 700)
pump()
clear(Hm, Am, Bm)
Hm.tm.task_info.nt_4.forced_status = "complete" -- the host's own check, no request
engine_check(Hm)
pump()
check(#Am.stock == 1 and Am.stock[1].typ == "complete" and #Am.feed == 0, "client A (the taker): the stock line")
check(#Hm.feed == 1 and Hm.feed[1].c == "player_a completed a task" and #Bm.feed == 1 and Bm.feed[1].c == "player_a completed a task",
	"the others: \"player_a completed a task\"")

print("== a script completes a task nobody took: nobody is named")
clear(Hm, Am, Bm)
Hm.env.task_manager.get_task_manager():give_task("nt_5", 700)
pump()
clear(Hm, Am, Bm)
Hm.tm.task_info.nt_5.forced_status = "complete"
engine_check(Hm)
pump()
check(#Hm.stock == 1 and #Am.stock == 1 and #Bm.stock == 1 and #Hm.feed + #Am.feed + #Bm.feed == 0, "stock lines, no nick")

-- ---------------------------------------------------------------- tasks: fail, cancel, updated, reversed
print("== fail and cancel")
clear(Hm, Am, Bm)
Hm.env.task_manager.get_task_manager():give_task("nt_6", 700)
pump()
clear(Hm, Am, Bm)
Hm.tm.task_info.nt_6.forced_status = "fail" -- a timer / condition of the task: nobody did it
engine_check(Hm)
pump()
check(#Hm.stock == 1 and Hm.stock[1].typ == "fail" and #Am.stock == 1 and Am.stock[1].typ == "fail" and #Bm.stock == 1
	and #Hm.feed + #Am.feed + #Bm.feed == 0, "failed by the task itself: the stock line everywhere, nobody named")

Am.env.task_manager.get_task_manager():give_task("nt_7", 700)
pump()
clear(Hm, Am, Bm)
Bm.env.task_manager.get_task_manager():set_task_cancelled("nt_7") -- B cancels A's task
pump()
engine_check(Hm)
pump()
check(#Hm.feed == 1 and Hm.feed[1].c == "player_b cancelled a task" and #Am.feed == 1 and Am.feed[1].c == "player_b cancelled a task",
	"cancelled by player_b: the host and A see \"player_b cancelled a task\"")
check(#Bm.stock == 1 and Bm.stock[1].typ == "fail" and #Bm.feed == 0, "player_b: the stock \"fail\" line")

print("== updated and reversed: the group's event, nobody named")
clear(Hm, Am, Bm)
local et = { get_id = function() return "nt_2" end, get_title = function() return "title_nt_2" end, get_icon_name = function() return nil end }
Hm.env.news_manager.send_task(Hm.actor, "updated", et)
Hm.env.news_manager.send_task(Hm.actor, "reversed", { get_id = function() return "nt_3" end, get_title = function() return "title_nt_3" end,
	get_icon_name = function() return "icon_nt_3" end })
pump()
check(#Hm.stock == 2 and #Am.stock == 2 and #Bm.stock == 2, "updated + reversed: two stock lines on every machine")
check(Am.stock[1] and Am.stock[1].typ == "updated" and Am.stock[1].title == "title_nt_2" and Am.stock[1].icon == nil
	and Am.stock[2].typ == "reversed" and Am.stock[2].icon == "icon_nt_3", "kind, title and icon are the host's")
Hm.env.news_manager.send_task(Hm.actor, "updated", et)
pump()
check(#Am.stock == 2, "the same update again within seconds: not repeated")

-- ---------------------------------------------------------------- tasks: what is left alone
print("== personal tasks, no session, strangers")
clear(Hm, Am, Bm)
Hm.env.coop_tasks.set_local_task("nt_local")
local local_tsk = { get_id = function() return "nt_local" end, get_title = function() return "mine" end, get_icon_name = function() return "i" end }
local ev0 = sent_events(Hm, "coop_tn")
Hm.env.news_manager.send_task(Hm.actor, "new", local_tsk)
pump()
check(#Hm.stock == 1 and sent_events(Hm, "coop_tn") == ev0 and #Am.stock == 0 and #Am.feed == 0, "a personal task: the stock line on its machine only")
Am.env.coop_tasks.set_local_task("nt_local")
Am.env.news_manager.send_task(Am.actor, "new", local_tsk)
check(#Am.stock == 1, "a personal task on a client is not swallowed")

do
	-- a message from a client is not the host's news
	clear(Hm, Am, Bm)
	Bm.env.coop.send_event("coop_tn", "k=sfail;i=snt_1;ti=sx", 0)
	pump()
	check(#Hm.stock + #Hm.feed == 0, "a client cannot send a task line to the host")
	-- no clients: nothing is sent
	local solo = Hm.players
	Hm.players = { { id = 0, is_self = true, nick = "stalker_host" } }
	local ev1 = sent_events(Hm, "coop_tn")
	Hm.env.news_manager.send_task(Hm.actor, "updated", { get_id = function() return "nt_6" end, get_title = function() return "t" end,
		get_icon_name = function() return nil end })
	check(#Hm.stock == 1 and sent_events(Hm, "coop_tn") == ev1, "the host alone: the stock line, no event")
	Hm.players = solo
end

print("== the stock function fails (a mod's override): the line is still shown")
NOW = NOW + 11000
clear(Hm, Am, Bm)
Am.fail_stock = true
Hm.env.news_manager.send_task(Hm.actor, "updated", { get_id = function() return "nt_1" end, get_title = function() return "title_nt_1" end,
	get_icon_name = function() return "icon_nt_1" end })
pump()
Am.fail_stock = nil
check(#Am.stock == 0 and #Am.feed == 1 and Am.feed[1].c == "Task updated" and Am.feed[1].t == "title_nt_1." and Am.feed[1].i == "icon_nt_1",
	"client A: the stock caption, the title and the icon, drawn by coop_quests_news")
check(#Bm.stock == 1 and #Bm.feed == 0, "client B, whose stock function works: the stock line")

print("== a flood of task lines is limited")
NOW = NOW + 11000
clear(Hm, Am, Bm)
for i = 1, 30 do
	Hm.env.news_manager.send_task(Hm.actor, "updated", { get_id = function() return "flood_" .. i end,
		get_title = function() return "t" end, get_icon_name = function() return nil end })
end
pump()
check(#Am.stock == 20 and #Bm.stock == 20, "the host sends 20 lines in 10 s, the clients show them")
check(#Hm.stock == 30, "the host's own screen is the stock one, not limited")

-- ---------------------------------------------------------------- encyclopedia
print("== encyclopedia: an article another player opened is announced")
clear(Hm, Am, Bm)
Bm.env.ui_pda_encyclopedia_tab.unlock_article("encyclopedia_x1")
pump()
check(Hm.ency_unl.encyclopedia_x1 and Am.ency_unl.encyclopedia_x1, "article unlocked on the host and on A (as before)")
check((Hm.set_article or 0) == 0 and (Am.set_article or 0) == 0, "the stock unlock stays silent (no stock news twice)")
check(#Hm.feed == 1 and Hm.feed[1].t == "New article: encyclopedia_x1 (opened by player_b)" and Hm.feed[1].c == "Encyclopedia",
	"host: \"New article: ... (opened by player_b)\"")
check(#Am.feed == 1 and Am.feed[1].t == "New article: encyclopedia_x1 (opened by player_b)", "client A: the same")
check(#Bm.feed == 0, "player_b, who opened it, gets the stock behaviour only")
check(Hm.sounds[1] == "device\\pda\\pda_guide_2", "the stock encyclopedia sound")

clear(Hm, Am, Bm)
Hm.env.ui_pda_encyclopedia_tab.unlock_article("encyclopedia_x2")
pump()
check(#Am.feed == 1 and Am.feed[1].t == "New article: encyclopedia_x2 (opened by stalker_host)" and #Bm.feed == 1
	and Bm.feed[1].t == "New article: encyclopedia_x2 (opened by stalker_host)" and #Hm.feed == 0, "the host's article: both clients, host named")

clear(Hm, Am, Bm)
Hm.env.ui_pda_encyclopedia_tab.unlock_article("encyclopedia_x2")
pump()
check(#Am.feed + #Bm.feed == 0, "an article already open: nothing")

clear(Hm, Am, Bm)
Hm.env.ui_pda_encyclopedia_tab.unlock_note("encyclopedia__notes_n1")
pump()
check(#Am.feed == 0 and (Am.notif or 0) >= 1, "a note keeps the stock note signal and gets no extra line")

print("== encyclopedia: a burst is summed up, loading is silent")
clear(Hm, Am, Bm)
NOW = NOW + 11000 -- a new window: the lines above used the last one
fire(Am, "actor_on_update")
fire(Hm, "actor_on_update")
for i = 1, 8 do Bm.env.ui_pda_encyclopedia_tab.unlock_article("encyclopedia_b" .. i) end
pump()
check(#Am.feed == 3 and #Hm.feed == 3, "at most 3 single lines in a burst")
NOW = NOW + 11000
fire(Am, "actor_on_update")
fire(Hm, "actor_on_update")
check(#Am.feed == 4 and Am.feed[4].t == "New articles: 5 (opened by the group)", "then one line with the rest")
fire(Am, "actor_on_update")
check(#Am.feed == 4, "the summary is shown once")
check(Am.ency_unl.encyclopedia_b8 == true, "all eight are unlocked")

clear(Hm, Am, Bm)
NOW = NOW + 20000
Am.env.coop.is_live = function() return false end -- the world of the host is still loading
Bm.env.ui_pda_encyclopedia_tab.unlock_article("encyclopedia_late1")
pump()
check(Am.ency_unl.encyclopedia_late1 == true and #Am.feed == 0, "applied while loading: silent, no spam at join")
Am.env.coop.is_live = function() return true end

-- ---------------------------------------------------------------- achievements
print("== achievements: the earner is named in the toast of the others")
clear(Hm, Am, Bm)
Bm.env.game_achievements.heavy_pockets_rewards()
pump()
check(Bm.tips[1] == "st_achievement_1_unlock", "the earner's own toast is unchanged")
check(Hm.tips[1] == "player_b: st_achievement_1_unlock" and Am.tips[1] == "player_b: st_achievement_1_unlock",
	"the host and A: the toast with player_b's nick")
check(#Hm.tips == 1 and #Am.tips == 1, "one toast each")
clear(Hm, Am, Bm)
Hm.env.news_manager.send_tip(Hm.actor, "another_tip")
check(Hm.tips[1] == "another_tip", "outside the achievement the tip function is the stock one again")

print("== achievement money: the earner sees the money line")
clear(Hm, Am, Bm)
Bm.money_news = {}
Am.money_news = {}
Bm.env.game_achievements.iron_curtain_rewards()
pump()
check(Bm.money_news[1] == "in:40000" and #Bm.money_news == 1, "player_b: one \"money received\" line with the 40000 the host paid")
check(#Am.money_news == 1 and Am.money_news[1] == "in:40000", "player_a, who gets the shared achievement and its money too, sees his own line")
check(Bm.tips[1] == "st_achievement_22_unlock" and Am.tips[1] == "player_b: st_achievement_22_unlock", "and the toast names him for the others")

print("== a stash revealed by a PDA message: the line is the reader's, not the host's")
clear(Hm, Am, Bm)
Hm.new_obj(900, "inventory_box", vec(1, 0, 0))
Bm.env.coop_quests_core.request_host_action("stash", { b = 900, s = "treasure", h = "hint" })
pump()
check(Hm.stash_spots == 1 and #Hm.treasure == 0, "host: the stash is revealed, the line is not shown on its screen")
check(#Bm.treasure == 1 and Bm.treasure[1] == 0 and #Am.treasure == 0, "player_b, who read the message, gets the line; A does not")
check(Hm.env.news_manager.send_treasure ~= nil and Hm.env.treasure_manager.set_random_stash ~= nil, "the stock functions are put back")
Hm.env.news_manager.send_treasure(1)
check(Hm.treasure[1] == 1, "the host's send_treasure is the stock one again")

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
