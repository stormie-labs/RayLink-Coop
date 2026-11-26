-- Server (srv): coop_srv_tasks.script, the task code only a server runs (step S5, unit A-S5T; docs\MODES.md, the build 57 plan).
--   - co-op: none of it starts (coop_mode.when_srv never runs there);
--   - a world hurt by a give that died on a world server (builds 45-49): its dialog's info is taken back, once a world
--     (heal_once, tested in test_srv_far_tasks too);
--   - a map server's personal effects pass through the world server to the player's machine once; the map server sends them again
--     until the world server answers (was coop_tasks' coop_rep_map / coop_rep_map_ack, tested in test_tasks_sync);
--   - character 0 on a server is the world server's seat, which plays no character: its effects are nobody's, the map server drops
--     them at once instead of sending them up every second for good;
--   - the NPC a player on a map server's level talks to (coop_mode.facts_of, protocol 33);
--   - the player's sound, truce and offer goodwill, plus delivery of the task-end surge flag clear (level logic grants no player immunity);
--     the offer goodwill also on the map server that builds his offer (review A-REV-E-2 finding 1).
-- Real scripts over the quests harness: a world server (peer 0, -coop_dedicated), a player on a map server's level (peer 1, character
-- 500) and that map server (bridge 0x101). Run: tools\test_lua.cmd srv_tasks
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local SCRIPTS = { "coop_trust", "coop_quests_core", "coop_reward_group", "coop_tasks", "coop_quests_story",
	"coop_srv_quests_core", "coop_srv_tasks", "coop_srv_quests_story" }
local BRIDGE = 0x101

local function world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	M.stats, M.rank, M.rept = {}, 0, 0
	e.game_statistics = {
		increment_statistic = function(name) M.stats[#M.stats + 1] = name end,
		increment_rank = function(v) M.rank = M.rank + v end,
		increment_reputation = function(v) M.rept = M.rept + v end,
	}
	-- the stock of the four effects (xr_effects.script:159, :3199, :6207, xr_conditions.script:1348 of G.A.M.M.A.)
	M.sounds, M.surge_calls, M.ceasefire = {}, {}, {}
	e.xr_effects.play_sound_on_actor = function(actor, obj, p) M.sounds[#M.sounds + 1] = p[1] end
	e.xr_effects.actor_surge_immuned = function(actor, npc, p)
		M.surge_calls[#M.surge_calls + 1] = p[1]
		e.save_var(e.db.actor, "surge_immuned", p[1] == "true" or nil)
	end
	e.xr_effects.stalker_ceasefire = function() M.ceasefire[#M.ceasefire + 1] = e.get_actor_true_community() end
	e.xr_effects.drx_sl_change_factions = function(a, n, p) M.faction = p[1] end
	e.xr_effects.decrease_rep = function(a, n, p) e.game_statistics.increment_reputation(-tonumber(p[1])) end
	M.story_goodwill = {}
	e.xr_effects.dec_faction_goodwill_to_actor = function(a, _, p)
		M.story_goodwill[a:id()] = { faction = p[1], amount = tonumber(p[2]) }
	end
	e.get_actor_true_community = function() return "stalker" end -- the ghost's
	M.goodwill = { [0] = { freedom = 0 }, [500] = { freedom = 1200 } }
	e.relation_registry = { community_goodwill = function(comm, id) return (M.goodwill[id] or {})[comm] or 0 end }
	e.xr_conditions.is_faction_friend_to_actor = function(actor, npc, p)
		return e.relation_registry.community_goodwill(p[1], e.AC_ID) >= 1000
	end
	M.stock = {
		sound = e.xr_effects.play_sound_on_actor, surge = e.xr_effects.actor_surge_immuned,
		ceasefire = e.xr_effects.stalker_ceasefire, friend = e.xr_conditions.is_faction_friend_to_actor,
	}
	for _, id in ipairs({ "snd_t", "def_t", "cf_t", "talk_t", "task_fanat_training_1", "cs_task0_ambush_renegade_story",
		"cs_task0_ambush_renegade_story2" }) do M.ini[id] = {} end
end

local function boot(M)
	local function load(name) return load_script(M, name) end
	modes.live(load("coop_mode"), load)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		local m = M.env[n]
		if m and m.on_game_start then m.on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

local function drop_machine(M)
	for i = #MACHINES, 1, -1 do if MACHINES[i] == M then table.remove(MACHINES, i) end end
end

-------------------------------------------------------------------------------
print("== co-op: the server's task code never starts")
do
	local Co = machine("host", 0)
	world(Co)
	Co.players = { { id = 0, is_self = true, avatar_id = 0 } }
	Co.infos.fanat_training_start_done = true -- a dialog closed by its info, in a co-op world
	boot(Co)
	fire(Co, "actor_on_update")
	check(Co.env.coop_srv_tasks ~= nil, "(the script loads in the co-op process)")
	check(Co.handlers.coop_rep_map == nil and Co.handlers.coop_rep_map_ack == nil, "no map server's effects are taken in the co-op")
	check(Co.handlers.coop_talk_new == nil, "no map server's word of a new talk is taken in the co-op (A-REV-E-2 F5)")
	check(Co.handlers["quests.offer_up"] == nil, "no map server's offer record is taken in the co-op (A-REV-E-2 F4)")
	Co.env.coop_npc_meet = { talk_verdict = function() return true end }
	fire(Co, "actor_on_update")
	check(rawget(Co.env.coop_npc_meet, "_coop_srv_talk_up") == nil, "the co-op host's talk verdict is not watched by the server code")
	Co.env.coop_npc_meet = nil
	check(Co.env.xr_effects.play_sound_on_actor == Co.stock.sound and Co.env.xr_effects.actor_surge_immuned == Co.stock.surge
		and Co.env.xr_effects.stalker_ceasefire == Co.stock.ceasefire
		and Co.env.xr_conditions.is_faction_friend_to_actor == Co.stock.friend, "the four effects stay the stock's")
	check(Co.env.coop_mode.facts_of(1) == nil, "no remote dialogue facts in co-op")
	check(Co.infos.fanat_training_start_done == true and Co.env.db.storage[0].pstor.coop_lost_gives == nil,
		"no world is healed of lost gives in the co-op")
	drop_machine(Co)
end

-------------------------------------------------------------------------------
print("== setup: a world server, a player on a map server's level, that map server")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
local Ms = machine("client", BRIDGE)
world(Hm)
world(Cm)
world(Ms)
local partner_of = {}
local function levels(M)
	M.env.coop.levels = {
		split = function() return true end,
		my_level = function() return M == Hm and 1 or 2 end,
		level_of_player = function(peer) return peer == 1 and 2 or peer == 2 and 3 or nil end,
		bridge_of_player = function(peer) return peer == 1 and BRIDGE or nil end,
		map_servers = function() return { { bridge = BRIDGE, level = 2 } } end,
		talking = function(peer) return partner_of[peer] ~= nil end,
		talk_partner = function(peer) return partner_of[peer] end,
	}
end
levels(Hm); levels(Cm); levels(Ms)
Hm.env.coop.is_dedicated = function() return true end
Ms.env.coop.is_map_server = function() return true end
Hm.new_obj(500, "coop_player_avatar", vec(10, 0, 10), { _stalker = true })
Ms.new_obj(500, "coop_player_avatar", vec(10, 0, 10), { _stalker = true })
Hm.new_obj(777, "stalker_trader", vec(12, 0, 10), { _stalker = true })
Hm.players = { { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0, nick = "anna" } }
Ms.players = { { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
Hm.env.coop_faction = { faction_of_character = function(id) return id == 500 and "freedom" or nil end }
-- the world that has to be healed: the Fanat's dialog is closed, his training never was the group's (builds 45-49)
for _, m in ipairs({ Hm, Cm, Ms }) do m.ini.task_fanat_training_1 = {} end
Hm.infos.fanat_training_start_done = true
boot(Hm); boot(Cm); boot(Ms)
check(Hm.env.coop_srv_tasks ~= nil and Hm.handlers.coop_rep_map ~= nil, "(the world server takes the map servers' effects)")
check(Ms.handlers.coop_rep_map_ack ~= nil, "(the map server takes the world server's answers)")

print("== a story choice on the map affects the world server's player characters")
do
	Hm.new_obj(501, "coop_player_avatar", vec(20, 0, 20), { _stalker = true })
	Hm.players[2] = { id = 2, avatar_id = 501, nick = "boris" }
	-- the stock's shape: the map server names the choice by its condlist (R32 W7, coop_srv_quests_story)
	Ms.env.xr_logic.pick_section_from_condlist(nil, nil, stock_condlist("%=dec_faction_goodwill_to_actor(dolg:50)%"))
	pump()
	local change = Hm.story_goodwill[500]
	check(change and change.faction == "dolg" and change.amount == 50, "the world server applies the map's story choice to the player")
	local second = Hm.story_goodwill[501]
	check(second and second.faction == "dolg" and second.amount == 50, "the world server also applies the story choice to the player on another map")
	check(next(Ms.story_goodwill) == nil and Hm.story_goodwill[0] == nil, "neither server ghost gets the faction change")
	Hm.players[2] = nil
end

print("== story shares check the transport and envelope before decoding")
do
	local main = Hm.env.coop_main
	local decode, reads = main.decode, 0
	main.decode = function(payload) reads = reads + 1; return decode(payload) end
	local on_share = Hm.handlers["quests.share"]
	-- R32 W7: a share names its condlist (owner, section, info); the arguments are checked as before
	local ID = { owner = "700", section = "3:sr_7:fieldcond1:1", info = "" }
	local function share(t)
		for k, v in pairs(ID) do t[k] = v end
		return t
	end
	local good = main.encode(share({ f = "dec_faction_goodwill_to_actor", p1 = "dolg", p2 = "17" }))
	on_share(good, BRIDGE + 1)
	check(reads == 0, "an unregistered map sender does not enter the story decoder")
	on_share(good .. string.rep(";", 15801), BRIDGE)
	check(reads == 0, "an oversized story packet does not enter the decoder")
	local trust = Hm.env.coop_trust.status()
	check(trust.story_share_sender and trust.story_share_sender.failed == 1, "the story sender refusal reaches trust")
	check(trust.story_share_payload and trust.story_share_payload.failed == 1, "the story size refusal reaches trust")
	for i = 1, 8 do
		local packet = share({ f = "dec_faction_goodwill_to_actor", p1 = "dolg", p2 = "17" })
		packet["p" .. i] = i % 2 == 1 and string.rep("x", 257) or true
		on_share(main.encode(packet), BRIDGE)
	end
	on_share(main.encode(share({ f = "dec_faction_goodwill_to_actor", p1 = "dolg", p2 = "1e999" })), BRIDGE)
	trust = Hm.env.coop_trust.status()
	check(trust.story_share_payload and trust.story_share_payload.failed == 10, "all eight story arguments and numeric range reach trust")
	check(Hm.story_goodwill[500].amount == 50, "invalid story arguments never change the player's goodwill")
	on_share(good, BRIDGE)
	check(Hm.story_goodwill[500].amount == 17, "valid story arguments reach the player")
	on_share(main.encode({ f = "dec_faction_goodwill_to_actor", p1 = "dolg", p2 = "5" }), BRIDGE)
	check(Hm.story_goodwill[500].amount == 17, "a share without its condlist identity is refused (R32 W7)")
	on_share(main.encode(share({ f = "dec_faction_goodwill_to_actor", p1 = "dolg", p2 = "9" })), BRIDGE)
	check(Hm.story_goodwill[500].amount == 17, "the same condlist identity again is the same share: not applied twice (R32 W7)")
	main.decode = decode
end

-------------------------------------------------------------------------------
print("== a world hurt by a give that died: the info of the dialog is taken back, once (was coop_tasks)")
do
	fire(Hm, "actor_on_update")
	local pstor = Hm.env.db.storage[0].pstor
	check(pstor.coop_lost_gives == true and Hm.infos.fanat_training_start_done == nil,
		"the world server looked when it started: the Fanat offers his training again, the world keeps that it looked")
	local T = Hm.env.coop_srv_tasks
	Hm.infos.fanat_training_start_done = true
	Hm.infos.cs_story_task0_ambush_renegade_start = true -- "The Last Dawn": asked for ...
	Hm.infos.renegade_cs_story_squad_1_death = true -- ... and it ran: its squad is dead
	Hm.infos.cs_story_task0_ambush_renegade_done = true -- its second part: the phrase was said ...
	Hm.tm.task_info.cs_task0_ambush_renegade_story2 = { id = "cs_task0_ambush_renegade_story2", stage = 0, status = "selected" } -- ... and it is on
	Hm.engine_tasks.cs_task0_ambush_renegade_story2 = { state = "in", get_id = function() return "cs_task0_ambush_renegade_story2" end }
	check(T.heal_lost_gives() == 1, "one give that was lost")
	check(Hm.infos.fanat_training_start_done == nil, "the Fanat offers his training again")
	check(Hm.infos.cs_story_task0_ambush_renegade_start == true, "a task that ran is left alone")
	check(Hm.infos.cs_story_task0_ambush_renegade_done == true, "a task that is on is left alone")
	Hm.tm.task_info.cs_task0_ambush_renegade_story2, Hm.engine_tasks.cs_task0_ambush_renegade_story2 = nil, nil
	Hm.infos.cs_story_task0_ambush_renegade_done = nil
	-- what such a give left behind: the task object in the journal that is no task of the engine
	Hm.infos.fanat_training_start_done = true
	Hm.tm.task_info.task_fanat_training_1 = { id = "task_fanat_training_1", stage = 0, status = "selected" }
	check(T.heal_lost_gives() == 1, "a half-made task is a lost give too")
	check(Hm.tm.task_info.task_fanat_training_1 == nil and Hm.infos.fanat_training_start_done == nil,
		"the half-made task leaves the journal and its dialog offers it again")
	pstor.coop_lost_gives = nil -- a world of an older build
	Hm.infos.fanat_training_start_done = true
	T._test.heal_once()
	check(Hm.infos.fanat_training_start_done == nil and pstor.coop_lost_gives == true, "an older world is looked at once")
	Hm.infos.fanat_training_start_done = true
	T._test.heal_once()
	NOW = NOW + 1000
	fire(Hm, "actor_on_update")
	check(Hm.infos.fanat_training_start_done == true, "and not again in this world")
	Hm.infos.fanat_training_start_done = nil
	fire(Ms, "actor_on_update")
	fire(Cm, "actor_on_update")
	pump()
	check(Ms.env.db.storage[0].pstor.coop_lost_gives == nil and Cm.env.db.storage[0].pstor.coop_lost_gives == nil,
		"only the world server heals: not a map server, not a player's machine")
end

-------------------------------------------------------------------------------
print("== a map server's personal effects pass through the world server (was coop_tasks)")
do
	local before = Cm.rept
	Ms.env.coop_tasks.with_character(500, function() Ms.env.game_statistics.increment_reputation(-25) end)
	pump()
	check(Cm.rept == before - 25 and Ms.rept == 0 and Hm.rept == 0, "the map server's penalty reaches the player once, through the world server")
	local packet
	for _, message in ipairs(Ms.sent) do if message.name == "coop_rep_map" then packet = message.payload end end
	local function ack_count()
		local n = 0
		for _, m in ipairs(Hm.sent) do if m.name == "coop_rep_map_ack" then n = n + 1 end end
		return n
	end
	local acks = ack_count()
	if packet then Hm.handlers.coop_rep_map(packet, BRIDGE); pump() end
	check(acks > 0 and ack_count() == acks + 1 and Cm.rept == before - 25, "a duplicate is answered without a second application")
	if packet then Hm.handlers.coop_rep_map(packet, 1); pump() end
	check(Cm.rept == before - 25, "a player's machine cannot pass for a map server")
	if packet then Hm.handlers.coop_rep_map(packet, BRIDGE + 1); pump() end
	check(Cm.rept == before - 25 and ack_count() == acks + 1, "an unregistered bridge cannot apply an effect or get an ACK")
	local sender_check = Hm.env.coop_trust.status().task_map_effect_sender
	check(sender_check and sender_check.failed == 2, "both invalid senders reach coop_trust")
	local saved = {}
	Hm.env.coop_tasks.save_effects(saved)
	Hm.env.coop_tasks.load_effects(saved)
	if packet then Hm.handlers.coop_rep_map(packet, BRIDGE); pump() end
	check(Cm.rept == before - 25, "the duplicate check survives the world server's save and load")
	local pending = 0
	for _, list in pairs(Ms.env.coop_tasks_rewards.fx_pending()) do pending = pending + #list end
	check(pending == 0, "the world server's answer took it off the map server's list")
	-- inside a story condlist of the map server's level (was test_quests: "not swallowed by the shared story relay")
	local r0 = Cm.rept
	Ms.env.coop_tasks.with_character(500, function()
		Ms.env.xr_logic.pick_section_from_condlist(nil, nil, { src = "%=decrease_rep(20)%" })
	end)
	pump()
	check(Cm.rept == r0 - 20 and Ms.rept == 0, "a personal effect in a story condlist of a map server is not swallowed by the story relay")
	-- a faction change on the map server's level: the player's machine runs it
	Ms.env.coop_tasks.with_character(500, function() Ms.env.xr_effects.drx_sl_change_factions(Ms.actor, nil, { "freedom" }) end)
	pump()
	check(Cm.faction == "freedom" and Ms.faction == nil and Hm.faction == nil, "a personal faction change on a map server reaches his machine")
	-- the world server does not answer: the map server sends it again, once a second, until it does
	local queue = {}
	local stock_send = Ms.env.coop.send_event
	Ms.env.coop.send_event = function(name, payload, target)
		if name == "coop_rep_map" then queue[#queue + 1] = payload return true end
		return stock_send(name, payload, target)
	end
	Ms.env.coop_tasks.with_character(500, function() Ms.env.game_statistics.increment_rank(7) end)
	NOW = NOW + 1100
	fire(Ms, "actor_on_update")
	check(#queue == 2, "unanswered: sent again after a second (" .. #queue .. " sends)")
	Ms.env.coop.send_event = stock_send
	NOW = NOW + 1100
	fire(Ms, "actor_on_update")
	pump()
	check(Cm.rank == 7, "the repeat that got through: his rank, once (" .. Cm.rank .. ")")
	local n = 0
	for _, m in ipairs(Ms.sent) do if m.name == "coop_rep_map" then n = n + 1 end end
	NOW = NOW + 1100
	fire(Ms, "actor_on_update")
	local n2 = 0
	for _, m in ipairs(Ms.sent) do if m.name == "coop_rep_map" then n2 = n2 + 1 end end
	check(n2 == n, "answered: not sent again")
end

-------------------------------------------------------------------------------
print("== character 0 on a server: the world server's seat plays no character, its effects are nobody's")
do
	local function sends()
		local n = 0
		for _, m in ipairs(Ms.sent) do if m.name == "coop_rep_map" then n = n + 1 end end
		return n
	end
	local n0, h0, c0, m0 = sends(), Hm.rept, Cm.rept, Ms.rept
	Ms.env.coop_tasks.with_character(0, function() Ms.env.game_statistics.increment_reputation(-15) end)
	Ms.env.coop_tasks.with_character(0, function() Ms.env.xr_effects.drx_sl_change_factions(Ms.actor, nil, { "dolg" }) end)
	pump()
	check(sends() == n0, "the map server sends nothing up for character 0 (it went up and was dropped there, then sent again for good)")
	check(Hm.rept == h0 and Cm.rept == c0 and Ms.rept == m0 and Ms.faction == nil and Hm.faction == nil,
		"nobody's: not the map server's ghost, not the world server's, not a player")
	for _ = 1, 3 do NOW = NOW + 1100 fire(Ms, "actor_on_update") end
	check(sends() == n0, "and nothing waits on the map server's list for it")
	Hm.env.coop_tasks.with_character(0, function() Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" }) end)
	local hrank, mrank = Hm.rank, Ms.rank
	Hm.env.game_statistics.increment_rank(4)
	Ms.env.game_statistics.increment_rank(12)
	check(Hm.rank == hrank and Ms.rank == mrank, "rank with no recipient is discarded by both server ghosts")
	check(Hm.faction == nil, "the world server's own logic: no faction change of its ghost either")
	-- a seat 0 that plays a character (the facade says so): its effects are his, peer 0's
	Ms.env.coop_mode.seat_plays = function(peer) return peer == 0 or peer == 1 end
	Ms.env.coop_tasks.with_character(0, function() Ms.env.game_statistics.increment_reputation(-4) end)
	check(sends() == n0 + 1, "a seat 0 that plays: its character's effect goes up to it, as before")
	Ms.env.coop_mode.seat_plays = function(peer) return peer == 1 end
	pump()
end

-------------------------------------------------------------------------------
print("== reputation and rank with no recipient on a server ghost")
do
	local map_rept, map_rank = Ms.rept, Ms.rank
	Ms.env.game_statistics.increment_reputation(-33)
	Ms.env.game_statistics.increment_rank(12)
	pump()
	check(Ms.rept == map_rept and Ms.rank == map_rank, "the map server's ghost earns nobody's reputation or rank")
	local world_rept, world_rank = Hm.rept, Hm.rank
	Hm.env.game_statistics.increment_reputation(9)
	Hm.env.game_statistics.increment_rank(4)
	-- An older map server may still send its character-0 penalty. The world answers even when nobody owns it.
	local payload = Ms.env.coop_main.encode({ k = "stat", f = "rept", e = "legacy", q = 1, i = 0, n = -15 })
	local before = #Hm.sent
	Hm.handlers.coop_rep_map(payload, BRIDGE)
	pump()
	check(Hm.rept == world_rept and Hm.rank == world_rank, "the world server's ghost earns nothing from its own logic or a map's")
	local ack = Hm.sent[before + 1]
	check(ack and ack.name == "coop_rep_map_ack" and ack.payload == "1", "the world answers a legacy character-0 penalty")
end

-------------------------------------------------------------------------------
print("== the facade reports who the player talks to on a map server's level (protocol 33)")
do
	local T = Hm.env.coop_tasks
	local facts_of = Hm.env.coop_mode.facts_of
	check(Hm.env.coop_quests_core.part("talk") == nil, "the old talk part is no longer installed")
	partner_of[1] = 777
	check(facts_of(1).partner == 777, "his partner as his map server says (coop.levels.talk_partner)")
	check(not Hm.env.coop_tasks_requests.talk_vague(1) and Hm.env.coop_tasks_requests.spoke_to(1, 777) and not Hm.env.coop_tasks_requests.spoke_to(1, 778), "only the reported partner was spoken to")
	partner_of[1] = nil
	check(facts_of(1).partner == false and not Hm.env.coop_tasks_requests.talk_vague(1), "nobody is a definite answer")
	check(Hm.env.coop_tasks_requests.spoke_to(1, 777), "a confirmed talk stays recent after the dialog closes")
	NOW = NOW + 16000
	check(not Hm.env.coop_tasks_requests.spoke_to(1, 777), "the recent talk expires after fifteen seconds")
	for _, id in ipairs({ 0, 1.5, 65535 }) do
		partner_of[1] = id
		check(facts_of(1).partner == nil, "the facade drops invalid partner id " .. id)
		check(not Hm.env.coop_tasks_requests.talk_vague(1) and not Hm.env.coop_tasks_requests.spoke_to(1, 777), "an invalid partner is a definite rejection: " .. id)
	end
	partner_of[1] = 65534
	check(Hm.env.coop_tasks_requests.spoke_to(1, 65534), "the highest valid NPC id can be a partner")
	partner_of[1] = nil
	local read_partner = Hm.env.coop.levels.talk_partner
	Hm.env.coop.levels.talk_partner = nil
	Hm.env.coop.levels.talking = function() return true end
	check(Hm.env.coop_tasks_requests.talk_vague(1) and Hm.env.coop_tasks_requests.spoke_to(1, 777), "a missing partner callback falls back to the general dialog fact")
	local delivery = Hm.env.coop_quests_core.part("task_delivery")
	local binding_available = delivery.has_talk_partner
	delivery.has_talk_partner = function() error("no partner report") end
	local ok, vague, spoke = pcall(function() return Hm.env.coop_tasks_requests.talk_vague(1), Hm.env.coop_tasks_requests.spoke_to(1, 777) end)
	check(ok and vague and spoke, "a throwing partner callback still falls back to the general dialog fact")
	delivery.has_talk_partner = binding_available
	Hm.env.coop.levels.talk_partner = function() error("engine partner binding failed") end
	check(not Hm.env.coop_tasks_requests.talk_vague(1) and not Hm.env.coop_tasks_requests.spoke_to(1, 777), "a failed engine partner read stays a definite answer, as at HEAD")
	Hm.env.coop.levels.talk_partner = read_partner
	Hm.env.coop.levels.talking = function(peer) return partner_of[peer] ~= nil end
	check(Ms.env.coop_mode.facts_of(1) == nil and Cm.env.coop_mode.facts_of(1) == nil,
		"the map server and player read their local objects")
	-- An older engine gives the general dialog fact only.
	local Old = machine("host", 0x55)
	world(Old)
	Old.env.coop.is_dedicated = function() return true end
	Old.env.coop.levels = {
		split = function() return true end, my_level = function() return 1 end,
		level_of_player = function(peer) return peer == 1 and 2 or nil end,
		talking = function(peer) return peer == 1 end,
	}
	Old.players = { { id = 0x55, is_self = true, avatar_id = 0 } }
	boot(Old)
	local old_talk = Old.env.coop_mode.facts_of(1)
	check(old_talk and old_talk.partner == nil and old_talk.talking, "an older engine reports the general dialog fact only")
	check(Old.env.coop_tasks_requests.talk_vague(1) and Old.env.coop_tasks_requests.spoke_to(1, 777), "an older engine still accepts the general dialog fact")
	drop_machine(Old)
end

-------------------------------------------------------------------------------
print("== Server task effects and task-end surge cleanup")
do
	local function finish(id, f)
		Cm.tm:give_task(id, 777)
		pump()
		check(Hm.tm.task_info[id] ~= nil and Hm.env.coop_tasks.taker(id) == 1, "(" .. id .. ": he took it)")
		Hm.on_complete = Hm.on_complete or {}
		Hm.on_complete[id] = f
		Hm.env.task_manager.task_callback({ get_id = function() return id end }, Hm.env.task.completed)
		pump()
	end
	-- 1. play_sound_on_actor (lttz_ms: the teleport sound at a task's end): the ghost played it, nobody heard it
	finish("snd_t", function() Hm.env.xr_effects.play_sound_on_actor(Hm.actor, nil, { "gimlet_teleport" }) end)
	check(#Cm.sounds == 1 and Cm.sounds[1] == "gimlet_teleport" and #Hm.sounds == 0,
		"play_sound_on_actor: his machine plays it, not the world server's ghost")
	-- 2. Only test task-end delivery. The map's level logic does not grant the player immunity.
	Hm.env.db.storage[0].pstor.surge_immuned = true
	finish("def_t", function() Hm.env.xr_effects.actor_surge_immuned(Hm.actor, nil, { "false" }) end)
	check(#Cm.surge_calls == 1 and Cm.surge_calls[1] == "false" and Hm.env.db.storage[0].pstor.surge_immuned == true,
		"the player receives the task-end cleanup and the world server's flag stays set")
	-- 3. stalker_ceasefire (the scorcher off, lttz_ll): the truce with his faction, not the ghost's
	finish("cf_t", function() Hm.env.xr_effects.stalker_ceasefire(Hm.actor, nil, {}) end)
	check(Hm.ceasefire[1] == "freedom", "stalker_ceasefire: the world server runs it with his faction (" .. tostring(Hm.ceasefire[1]) .. ")")
	Hm.env.xr_effects.stalker_ceasefire(Hm.actor, nil, {})
	check(Hm.ceasefire[2] == "stalker" and Hm.env.get_actor_true_community() == "stalker",
		"outside a task's end: the stock's; the stock function is back")
	-- 4. is_faction_friend_to_actor in an offer the world server builds for him on his level (the far view's scope names him)
	local scope = nil
	Hm.env.coop_srv_quests_far = { in_scope = function() return scope end }
	local friend = Hm.env.xr_conditions.is_faction_friend_to_actor
	check(friend(Hm.actor, nil, { "freedom" }) == false, "outside his scope: the ghost's goodwill (0), as the stock")
	scope = { peer = 1, avatar = 500 }
	check(friend(Hm.actor, nil, { "freedom" }) == true, "in the scope of his level: his goodwill (1200)")
	check(Hm.env.AC_ID == 0, "AC_ID is back")
	scope = nil
	Hm.env.coop_srv_quests_far = nil
	-- 4b. Review A-REV-E-2 finding 1: since A-S5S-offer the map server of his level builds the offer, with no far scope and no
	-- reward scope; coop_quests_offer.requester() names him while it builds. The precondition reads his goodwill, not the ghost's.
	local req = nil
	Ms.env.coop_quests_offer = { requester = function() return req end }
	local mfriend = Ms.env.xr_conditions.is_faction_friend_to_actor
	check(mfriend ~= Ms.stock.friend, "(the map server wraps is_faction_friend_to_actor)")
	check(mfriend(Ms.actor, nil, { "freedom" }) == false, "map server, no offer being built: the ghost's goodwill (0), as the stock")
	req = 1
	check(mfriend(Ms.actor, nil, { "freedom" }) == true, "map server, his offer being built: his goodwill (1200), not the ghost's")
	check(Ms.env.AC_ID == 0, "AC_ID is back on the map server")
	for _, bad in ipairs({ 2, 0, 1.5, -1, 65536, "1" }) do
		req = bad
		check(mfriend(Ms.actor, nil, { "freedom" }) == false, "a requester with no character here (" .. tostring(bad) .. "): the ghost's")
	end
	req = function() error("requester failed") end
	Ms.env.coop_quests_offer = { requester = function() return req() end }
	check(mfriend(Ms.actor, nil, { "freedom" }) == false, "a requester that throws: the ghost's")
	Ms.env.coop_quests_offer = nil
	-- the world server keeps HEAD's answer: a requester while no far scope is open (its fallback over no scope) is the ghost's
	Hm.env.coop_quests_offer = { requester = function() return 1 end }
	check(friend(Hm.actor, nil, { "freedom" }) == false, "world server, a requester and no far scope: the ghost's goodwill, as before")
	Hm.env.coop_quests_offer = nil
	-- his machine runs its own calls as the stock
	check(Cm.env.xr_effects.play_sound_on_actor == Cm.stock.sound and Cm.env.xr_effects.stalker_ceasefire == Cm.stock.ceasefire,
		"a player's machine keeps the stock effects")
	-- a forwarded name his machine did not allow (an old world server) is not run
	local s0 = #Cm.sounds
	Cm.handlers.coop_trw("k=sfx;f=sstalker_ceasefire;q=n9999", 0)
	check(#Cm.ceasefire == 0 and #Cm.sounds == s0, "a forwarded effect his machine does not allow: not run")
end

print("== malformed map effects are refused before delivery or acknowledgement")
do
	local packet = { k = "stat", f = "rank", e = "bounds", q = 1, i = 500 }
	local cases = {
		{ f = "rank", n = false },
		{ f = "rept", n = "5" },
		{ f = "rept", n = 2 ^ 31 },
		{ f = "tasks_completed", r = 2 ^ 31 },
		{ f = "tasks_completed", p = "90" },
		{ f = "tasks_completed", p = -2 ^ 32 },
		{ f = "tasks_completed", t = 4 },
		{ f = "tasks_completed", t = string.rep("x", 129) },
		{ k = "fx", f = "play_sound_on_actor", p1 = true },
		{ k = "fx", f = "play_sound_on_actor", p1 = "sound", p2 = string.rep("x", 257) },
		{ k = "fx", f = "play_sound_on_actor", p1 = "sound", p3 = 4 },
		{ k = "fx", f = "play_sound_on_actor", p1 = "sound", p4 = string.rep("x", 257) },
		{ k = "fx", f = "actor_surge_immuned", p1 = "maybe" },
		{ k = "fx", f = "drx_sl_change_factions", p1 = "freedom\000extra" },
	}
	local sent = #Hm.sent
	local rank, rept, count, sounds = Cm.rank, Cm.rept, #Cm.stats, #Cm.sounds
	for i, fields in ipairs(cases) do
		local effect = {}
		for k, v in pairs(packet) do effect[k] = v end
		for k, v in pairs(fields) do effect[k] = v end
		effect.q = i
		Hm.handlers.coop_rep_map(Hm.env.coop_main.encode(effect), BRIDGE)
	end
	local trust = Hm.env.coop_trust.status().task_map_effect_payload
	check(trust and trust.failed == #cases, "each malformed effect reaches trust")
	check(#Hm.sent == sent, "no invalid effect is forwarded or acknowledged")
	pump()
	check(Cm.rank == rank and Cm.rept == rept and #Cm.stats == count and #Cm.sounds == sounds, "no invalid effect reaches the player")
	packet.n, packet.t = -0.5, string.rep("x", 128)
	Hm.handlers.coop_rep_map(Hm.env.coop_main.encode(packet), BRIDGE)
	pump()
	check(Cm.rank == rank - 0.5 and #Hm.sent == sent + 2, "a corrected retry forwards one fractional stat and is acknowledged")
end

-------------------------------------------------------------------------------
print("== one step per talk: the map server tells the world server each talk it grants (review A-REV-E-2 finding 5)")
do
	local T = Hm.env.coop_tasks
	local real = Hm.env.coop_tasks_requests.far_talk_new
	local heard = {}
	Hm.env.coop_tasks_requests.far_talk_new = function(p, n)
		heard[#heard + 1] = tostring(p) .. ":" .. tostring(n)
		if real then return real(p, n) end
	end
	local lock, allow, verdicts = {}, true, 0
	Ms.env.coop.talk_lock_of = function(peer) return lock[peer] end
	Ms.env.coop_npc_meet = { talk_verdict = function()
		verdicts = verdicts + 1
		if allow then return true end
		return false, "unwilling"
	end }
	NOW = NOW + 1100
	fire(Ms, "actor_on_update")
	local meet = Ms.env.coop_npc_meet
	check(rawget(meet, "_coop_srv_talk_up") == true, "(the map server watches the talks it grants)")
	local npc = Ms.new_obj(777, "stalker_trader", vec(12, 0, 10), { _stalker = true })
	local av = Ms.objects[500]
	local yes = meet.talk_verdict(npc, av)
	pump()
	check(yes == true and verdicts == 1, "the stock verdict still answers")
	check(#heard == 1 and heard[1] == "1:777", "a talk the map server grants him: the world server hears it (" .. tostring(heard[1]) .. ")")
	lock[1] = 777
	meet.talk_verdict(npc, av)
	pump()
	check(#heard == 1, "the lock he holds already, asked again: no new talk")
	lock[1] = nil
	allow = false
	local no, why = meet.talk_verdict(npc, av)
	pump()
	check(no == false and why == "unwilling" and #heard == 1, "a refused talk: the verdict as the stock's, no word")
	allow = true
	local other = Ms.new_obj(778, "stalker", vec(12, 0, 10), { _stalker = true })
	meet.talk_verdict(npc, other)
	pump()
	check(#heard == 1, "a talk of an NPC with an NPC (no player's character): no word")
	fire(Ms, "actor_on_update")
	meet.talk_verdict(npc, av)
	pump()
	check(#heard == 2, "the watch is installed once: one word per grant")
	check(Cm.handlers.coop_talk_new == nil and Ms.handlers.coop_talk_new == nil, "only the world server takes the word")
	check(rawget(Hm.env.coop_npc_meet or {}, "_coop_srv_talk_up") == nil, "the world server grants no lock of his and watches none")

	-- the world server: only the bridge of that player's map, a whole player and a whole NPC id
	local n = #heard
	Hm.handlers.coop_talk_new("1:777", 1)
	Hm.handlers.coop_talk_new("1:777", BRIDGE + 1)
	Hm.handlers.coop_talk_new("1:777", 0)
	local senders = Hm.env.coop_trust.status().task_talk_new_sender
	check(#heard == n and senders and senders.failed == 3, "a player, an unregistered bridge, peer 0: no word, each through coop_trust")
	for _, junk in ipairs({ "2:777", "1:0", "1:65535", "0:777", "65536:777", "1:777:1", "1:7.5", "x:777", "", "1:777\n",
		string.rep("1", 13), "%s%s%s:777" }) do
		Hm.handlers.coop_talk_new(junk, BRIDGE)
	end
	Hm.handlers.coop_talk_new(nil, BRIDGE)
	Hm.handlers.coop_talk_new(777, BRIDGE)
	local payloads = Hm.env.coop_trust.status().task_talk_new_payload
	check(#heard == n and payloads and payloads.failed == 14,
		"another player's (his map has no map server here), junk and out-of-range ids: no word, each through coop_trust")
	Hm.handlers.coop_talk_new("1:777", BRIDGE)
	check(#heard == n + 1 and heard[#heard] == "1:777", "the word of his map's bridge reaches the Core")
	-- these reports are dropped in every trust mode: the shipped settings say "refuse", so the [coop-trust] line says what happens
	-- (A-REV-E-2 finding 3's rule)
	local fh = io.open("gamedata/configs/mod_system_coop_trust.ltx", "r")
	local text = fh and fh:read("*a") or ""
	if fh then fh:close() end
	for _, name in ipairs({ "task_map_effect_sender", "task_map_effect_size", "task_map_effect_payload", "task_map_ack_sender",
		"task_map_ack_payload", "task_talk_new_sender", "task_talk_new_payload" }) do
		check(text:match("\n" .. name .. "%s*=%s*(%w+)") == "refuse", "the shipped policy refuses the dropped check " .. name)
	end
	Hm.env.coop_tasks_requests.far_talk_new = real
	Ms.env.coop_npc_meet, Ms.env.coop.talk_lock_of = nil, nil
end

-------------------------------------------------------------------------------
print("== the offers a map server makes reach the world server, which gives the task (review A-REV-E-2 finding 4)")
do
	for _, M in ipairs({ Hm, Ms, Cm }) do M.ini.as_t = {} end
	local wo = load_script(Hm, "coop_quests_offer")
	local mo = load_script(Ms, "coop_quests_offer")
	NOW = NOW + 1100
	fire(Ms, "actor_on_update")
	fire(Hm, "actor_on_update")
	check(rawget(mo, "_coop_srv_offers_up") == true and rawget(wo, "_coop_srv_offers_up") == nil,
		"(only the map server passes its offers up)")
	local vars = { as_t = { squad_id = 900, smart_id = 901 } }
	mo.note_offer(1, 777, "as_t", vars, 55)
	pump()
	check(mo.offers_of(1, "as_t") ~= nil, "the map server keeps its offer as before")
	local list, meta = wo.offers_of(1, "as_t")
	check(list and list[1].as_t and list[1].as_t.squad_id == 900 and meta[1].npc == 777 and meta[1].bt == 55,
		"the world server keeps the map server's offer as its own (offers_of judges his give there)")
	mo.forget_offers(1, 777)
	pump()
	check(wo.offers_of(1, "as_t") == nil and mo.offers_of(1, "as_t") == nil,
		"an offer the map server drops (a refusal: his machine makes that NPC's offers itself) is dropped on the world server too")
	-- only the bridge of that player's map; whole ids, a task this world knows, bounded vars
	local qc = Hm.env.coop_quests_core
	local function up(t, from) Hm.handlers["quests.offer_up"](Hm.env.coop_main.encode(t), from) end
	local function good(over)
		local t = { p = 1, n = 777, i = "as_t", v = qc.ser(vars), bt = 55 }
		for k, v in pairs(over or {}) do t[k] = v end
		return t
	end
	up(good(), 1)
	up(good(), BRIDGE + 1)
	up(good(), 0)
	local senders = Hm.env.coop_trust.status().task_offer_up_sender
	check(wo.offers_of(1, "as_t") == nil and senders and senders.failed == 3,
		"a player, an unregistered bridge, peer 0: nothing noted, each through coop_trust")
	local junk = { { p = 2 }, { p = 0 }, { p = 1.5 }, { n = 0 }, { n = 65535 }, { i = "unknown_task" }, { i = "as\001t" },
		{ bt = 1.5 }, { bt = 70000 }, { v = string.rep("x", qc.MAX_BLOB + 1) }, { v = "garbage" }, { f = 2 } }
	for _, over in ipairs(junk) do up(good(over), BRIDGE) end
	local payloads = Hm.env.coop_trust.status().task_offer_up_payload
	check(wo.offers_of(1, "as_t") == nil and wo.offers_of(2, "as_t") == nil and payloads and payloads.failed == #junk,
		"another player's (his map is not that bridge's), junk ids, an unknown task, bad vars: nothing noted, each through coop_trust")
	local plain = good()
	plain.bt = nil
	up(plain, BRIDGE)
	list, meta = wo.offers_of(1, "as_t")
	check(list and meta[1].npc == 777 and meta[1].bt == nil, "a well-formed record of his map's bridge is noted")
	up({ p = 1, n = 777, f = 1 }, BRIDGE)
	check(wo.offers_of(1, "as_t") == nil, "a well-formed forget of his map's bridge drops it")
	check(Cm.handlers["quests.offer_up"] == nil and Ms.handlers["quests.offer_up"] == nil, "only the world server takes offer records")
	local fh = io.open("gamedata/configs/mod_system_coop_trust.ltx", "r")
	local text = fh and fh:read("*a") or ""
	if fh then fh:close() end
	check(text:match("\ntask_offer_up_sender%s*=%s*(%w+)") == "refuse" and text:match("\ntask_offer_up_payload%s*=%s*(%w+)") == "refuse",
		"the shipped policy refuses the dropped offer records")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
