-- Round 5 (S2 of the round 4 review), Server: a counted quest effect a map server's own logic ran (its level's condlists) is noted
-- on the world server too. A client's ask of the same thing is decided on the world server (quests.act "fx", coop_quests_story
-- host_fx -> coop_quests_trust check_spawn), whose list never saw the map server's own run: a second copy could be asked for.
-- The map server passes the run on (coop_srv_quests_far, event far_qnote), the world server notes it as its own run, from a map
-- server only. Machines: the world server (peer 0), a client (peer 1), the map server of his level (peer 0x101).
-- Step S4: coop_srv_quests_far starts from coop_mode.when_srv: the world server is a dedicated one (its server layer answers) and
-- the map server is one; the client of this test is not a player of a server world (his machine never starts it).
-- Run: tools\test_lua.cmd srv_far_quest_spawns
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_trust", "coop_quests_core", "coop_quests_trust", "coop_srv_quests_far", "coop_quests_story" }
local BRIDGE = 0x101

local function world(M)
	local e = M.env
	-- the world server's map server: the one on BRIDGE
	e.coop.levels = { split = function() return false end, map_servers = function() return { { bridge = BRIDGE, level = 2 } } end }
	M.spawned = {}
	local POS = { drx_x8_documents = true, wpn_gauss_quest = true }
	e.xr_effects.spawn_item_at_pos = function(actor, npc, p)
		if POS[p[1]] then M.spawned[#M.spawned + 1] = p[1] end
	end
	M.made_fx = {}
	e.xr_effects.barrier_defense_first_spawn = function() M.made_fx.barrier = (M.made_fx.barrier or 0) + 1 end
	e.coop_npc_logic = { relay_to_all = function() end, user_of = function() return nil end }
end

local function boot(M)
	load_script(M, "coop_mode")
	load_script(M, "coop_hostplay_mode").on_game_start()
	load_script(M, "coop_srv_mode").on_game_start()
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		local m = M.env[n]
		if m.on_game_start then m.on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

local Hm = machine("host", 0)
local Cm = machine("client", 1)
local Ms = machine("client", BRIDGE)
Ms.env.coop.is_map_server = function() return true end
Hm.env.coop.is_dedicated = function() return true end -- the world server (-coop_dedicated): its server layer answers
world(Hm); world(Cm); world(Ms)
Hm.players = { { id = 0, is_self = true, avatar_id = 0, nick = "host" }, { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0, nick = "anna" } }
Ms.players = { { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
Hm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
boot(Hm); boot(Cm); boot(Ms)

local function trust_lines(name)
	local n = 0
	for _, l in ipairs(Hm.log) do
		if l:find("[coop-trust] ! " .. name .. ":", 1, true) then n = n + 1 end
	end
	return n
end
local function ask(t)
	Cm.env.coop_quests_core.request_host_action("fx", t)
	pump()
end

print("== Server: the map server's own run of a quest spawn is noted on the world server")
do
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_spawn_once = "refuse", quest_effect_once = "refuse" })
	Ms.env.xr_effects.spawn_item_at_pos(Ms.actor, nil, { "wpn_gauss_quest" }) -- its level's condlist
	check(#Ms.spawned == 1, "(the map server made the Gauss rifle on its level)")
	check(count_sent(Ms, "quests.far_qnote") == 1, "the map server passes its own run to the world server")
	pump()
	ask({ f = "spawn_item_at_pos", p1 = "wpn_gauss_quest" })
	check(#Hm.spawned == 0 and trust_lines("quest_spawn_once") == 1,
		"a client's ask of the same rifle on the world server: refused, made once for the world")
	local m = {}
	fire(Hm, "save_state", m)
	local listed = {}
	for _, k in ipairs(m.coop_quest_spawns or {}) do listed[k] = true end
	check(listed["spawn_item_at_pos:wpn_gauss_quest"] == true, "the world server's save keeps it")
	check(count_sent(Hm, "quests.far_qnote") == 0, "the world server passes nothing on")
end

print("== Server: a run of the map server for a running task of the world (the barrier's first wave)")
do
	Hm.tm.task_info.barrier_defense_monolith = { id = "barrier_defense_monolith", stage = 0 }
	Ms.env.xr_effects.barrier_defense_first_spawn(Ms.actor, nil, { "monolith" })
	pump()
	local made = Hm.made_fx.barrier or 0
	ask({ f = "barrier_defense_first_spawn", p1 = "monolith" })
	check((Hm.made_fx.barrier or 0) == made and trust_lines("quest_effect_once") == 1,
		"the wave the map server made for this run: a client's ask refused")
	Hm.tm.task_info.barrier_defense_monolith = nil
end

print("== only a map server is heard")
do
	Cm.env.coop_quests_core.send("far_qnote", { f = "spawn_item_at_pos", p1 = "drx_x8_documents" }, 0)
	pump()
	ask({ f = "spawn_item_at_pos", p1 = "drx_x8_documents" })
	check(Hm.spawned[#Hm.spawned] == "drx_x8_documents" and trust_lines("quest_spawn_once") == 1,
		"a client's own far_qnote notes nothing: the documents he asks for are made")
	Ms.env.coop_quests_core.send("far_qnote", { f = "spawn_item_at_pos", p1 = "junk_section" }, 0)
	pump()
	local m = {}
	fire(Hm, "save_state", m)
	local listed = {}
	for _, k in ipairs(m.coop_quest_spawns or {}) do listed[k] = true end
	check(listed["spawn_item_at_pos:junk_section"] == nil, "a section the effect cannot make is not kept, from a map server either")
	Hm.env.coop_trust.reset_for_test(nil)
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
