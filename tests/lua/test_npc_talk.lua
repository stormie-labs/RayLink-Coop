-- Anomaly Coop B8 (build 10): who may a client talk to? coop_npc_meet.talk_verdict / talk flags per client.
-- A client's puppets never run xr_meet, so the host decides for the client's character. The stock rules of
-- xr_meet.process_npc_usability (use = false: squad members that are not the commander, enemies, ...) are what the
-- host used; G.A.M.M.A. replaced that function by "every living, unhurt NPC talks" (fixtures/gamma_usability.lua), so
-- a GAMMA host talked to NPCs the client was told were mute (live test, build 10: renegade "Dimuha Knyaz").
-- The module learns which of the two the running game uses from the host's own NPCs (soft rules "ignored" / "stock").
-- Run: tools\test_lua.cmd npc_talk
dofile("tests/lua/support/harness_npc.lua")
local REF_STOCK = "../anomaly-ref/unpacked/scripts/xr_meet.script"
local FIXTURE_GAMMA = "tests/lua/fixtures/gamma_usability.lua"

local function pair()
	reset_world()
	NOW = 100000
	local H = machine("host", 0, { [0] = 0, [1] = 500 })
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	local function swap(id) if id == 0 then return 500 elseif id == 500 then return 0 end return id end
	C.to_host, C.to_local = swap, swap
	for _, M in ipairs({ H, C }) do
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
	end
	local proxy = H.add(make_obj(500, 10, 0, 0, { _name = "proxy1", _comm = "actor_csky" }))
	C.add(make_obj(500, 0, 0, 0, { _name = "host_avatar" }))
	return H, C, proxy
end

local function common(M)
	local E = M.env
	E.xr_logic = {
		pick_section_from_condlist = function(actor, npc, condlist)
			for _, c in ipairs(condlist or {}) do
				if not c.cond or c.cond(actor, npc) then return c.section end
			end
		end,
	}
	E.character_community = function(o) return o:character_community() end
	E.game_relations = {
		is_factions_enemies = function(a, b) return (M.enemies or {})[a .. "/" .. b] == true end,
	}
	E.game_object = { enemy = 2, friend = 0, neutral = 1 }
	E.IsWounded = function(o) return o._wounded == true end
	E.IsWeapon = function(o) return o and o._weapon == true end
	E.xr_corpse_detection = { is_under_corpse_detection = function() return false end }
	E.xr_help_wounded = { is_under_help_wounded = function() return false end }
	E.task_manager = { get_task_manager = function() return { task_info = {} } end }
	E.tasks_delivery = { is_delivery_task = function() return false end }
	E.state_mgr = { is_npc_in_combat = function() return false end, set_state = function() end, get_state = function() return "idle" end }
	E.xr_sound = { set_sound_play = function() end }
	E.xr_conditions = { actor_is_safemode = function() return "stock" end }
	E.xr_wounded = { unlock_medkit = function() end }
	E.dialogs = { who_is_npc = function(a, b) return a:id() == 0 and b or a end }
end

-- The real stock function, cut out of anomaly-ref's xr_meet.script.
local function stock_usability(env)
	local fh = assert(io.open(REF_STOCK, "r"), "anomaly-ref is missing: " .. REF_STOCK)
	local src = fh:read("*a")
	fh:close()
	local body = assert(src:match("(function process_npc_usability%(npc%).-)\nfunction on_game_start"), "stock function not found")
	local f = assert(loadstring("local " .. body .. "\nreturn process_npc_usability", "@stock_usability"))
	setfenv(f, env)
	return f()
end

local function gamma_usability(env)
	local f = assert(loadfile(FIXTURE_GAMMA))
	setfenv(f, env)
	return f()
end

local USE_CONDLIST = { { cond = function(who, npc) return npc._commander == true and not npc._enemy end, section = "true" }, { section = "false" } }

-- A host and a client with the chosen xr_meet.process_npc_usability, coop_npc_meet installed on both.
local function scene(kind)
	local H, C, proxy = pair()
	common(H)
	common(C)
	for _, M in ipairs({ H, C }) do
		local E = M.env
		E.xr_meet = {
			Cmeet_manager = { update = function() end, update_state = function() end, set_start_distance = function() end },
			evaluator_contact = { evaluate = function() return false end },
			action_meet_wait = { execute = function() end },
		}
		E.xr_meet.process_npc_usability = (kind == "gamma") and gamma_usability(E) or stock_usability(E)
	end
	local MH = load_script(H, "coop_npc_meet")
	local MC = load_script(C, "coop_npc_meet")
	MH.on_game_start()
	MC.on_game_start()
	NOW = NOW + 300
	H.fire("actor_on_update")
	return H, C, proxy, MH, MC
end

-- An NPC of the host (id, commander or squad member) and its puppet on the client; meet manager as xr_meet leaves it.
local function npc_pair(H, C, id, opts)
	opts = opts or {}
	local npc = H.add(make_obj(id, 15, 0, 0, { _name = "npc" .. id, _commander = opts.commander == true }))
	local puppet = C.add(make_obj(id, 15, 0, 0, { _name = "npc" .. id }))
	H.env.db.storage[id] = { meet = { meet_manager = { use = opts.commander and "true" or "false",
		a = { use = USE_CONDLIST, trade_enable = { { section = "true" } }, meet_section = "nil" } } } }
	return npc, puppet
end

-- One update of every NPC by the host's binders (stock calls process_npc_usability), then the network.
local function round(H, npcs)
	NOW = NOW + 600
	H.fire("actor_on_update")
	for _, n in ipairs(npcs) do H.env.xr_meet.process_npc_usability(n) end
	pump()
end

-- ===================================================================================================================
print("== G.A.M.M.A.: the host talks to everybody, so does a client (squad members, an enemy faction)")
do
	local H, C, proxy, MH = scene("gamma")
	local npcs, puppets = {}, {}
	for i = 1, 4 do npcs[i], puppets[i] = npc_pair(H, C, 200 + i, { commander = false }) end
	local rc, puppet_c = npc_pair(H, C, 210, { commander = true })
	npcs[#npcs + 1], puppets[#puppets + 1] = rc, puppet_c
	for _ = 1, 3 do round(H, npcs) end

	check(npcs[1]._talk == true, "control: the GAMMA function left the host's NPC talkable (squad member)")
	local all = true
	for i = 1, 4 do all = all and puppets[i]._talk == true end
	check(all, "squad members that are not the commander: the client's puppet can talk (was: mute under the stock rules)")
	check(puppet_c._talk == true, "the commander too")
	check(MH._soft().mode == "ignored", "learned: the running xr_meet ignores the stock use rules")
	check(MH.talk_verdict(npcs[1], proxy) == true, "lock-time verdict for the client's character: allowed")
	MH.print_status()
	local said = false
	for _, line in ipairs(H.log) do if line:find("B8: stock use rules for clients: ignored", 1, true) then said = true end end
	check(said, "coop_status says which rules apply")

	-- an enemy faction alone is not a reason (the host would talk to him), the engine relation plus a fight is
	H.enemies = { ["csky/stalker"] = true }
	check(MH.talk_verdict(npcs[1], proxy) == true, "enemy faction, calm, relation not hostile: allowed (as for the host)")
	npcs[1]._rel = { [500] = 2 }
	check(MH.talk_verdict(npcs[1], proxy) == true, "hostile but calm: allowed (GAMMA lets the host talk)")
	npcs[1]._enemy = make_obj(900, 0, 0, 0)
	local ok, why = MH.talk_verdict(npcs[1], proxy)
	check(ok == false and why == "combat", "hostile to him and fighting: refused, reason combat")
	npcs[2]._enemy = make_obj(901, 0, 0, 0)
	ok, why = MH.talk_verdict(npcs[2], proxy)
	check(ok == true, "fighting a mutant but friendly to him: allowed")
	H.enemies = {}
end

-- ===================================================================================================================
print("== G.A.M.M.A.: wounded and zombified NPCs")
do
	local H, C, proxy, MH = scene("gamma")
	local npcs = {}
	for i = 1, 4 do npcs[i] = npc_pair(H, C, 200 + i) end
	for _ = 1, 3 do round(H, npcs) end
	check(MH._soft().mode == "ignored", "(learned)")

	local w = npcs[1]
	w._wounded = true
	H.env.db.storage[w:id()].wounded = { enable_talk = false }
	local ok, why = MH.talk_verdict(w, proxy)
	check(ok == false and why == "wounded", "wounded, talk not enabled by the wound manager: wounded")
	H.env.db.storage[w:id()].wounded = { enable_talk = true }
	check(MH.talk_verdict(w, proxy) == true, "wounded, enable_talk: allowed")
	w._rel = { [500] = 2 }
	ok, why = MH.talk_verdict(w, proxy)
	check(ok == false and why == "hostile", "wounded and hostile to him: hostile")
	H.env.db.storage[w:id()].victim_surrender = 500
	check(MH.talk_verdict(w, proxy) == true, "wounded, hostile, but surrendered to this player: allowed")
	H.env.db.storage[w:id()].victim_surrender = 0
	ok, why = MH.talk_verdict(w, proxy)
	check(ok == false and why == "hostile", "surrendered to the host's player, not to this one: hostile")

	local z = npcs[2]
	z._comm = "zombied"
	ok, why = MH.talk_verdict(z, proxy)
	check(ok == false and why == "unwilling", "zombified: refused")
end

-- ===================================================================================================================
print("== stock Anomaly: the stock use rules stay (squad member, enemy faction, fight)")
do
	local H, C, proxy, MH = scene("stock")
	local npcs, puppets = {}, {}
	for i = 1, 4 do npcs[i], puppets[i] = npc_pair(H, C, 200 + i, { commander = false }) end
	local cmd, cmd_puppet = npc_pair(H, C, 210, { commander = true })
	npcs[#npcs + 1] = cmd
	check(MH._soft().mode == nil, "nothing learned yet")
	for _ = 1, 3 do round(H, npcs) end
	check(npcs[1]._talk == false, "control: the stock function switched the host's NPC (squad member) off")
	check(MH._soft().mode == "stock", "learned: the running xr_meet applies the stock use rules (12 samples, no contradiction)")
	check(puppets[1]._talk == false and cmd_puppet._talk == true, "client: squad member mute, commander talkable (as for the host)")

	local ok, why = MH.talk_verdict(npcs[1], proxy)
	check(ok == false and why == "unwilling", "squad member: refused, reason unwilling")
	check(MH.talk_verdict(cmd, proxy) == true, "commander: allowed")
	H.enemies = { ["csky/stalker"] = true }
	ok, why = MH.talk_verdict(cmd, proxy)
	check(ok == false and why == "hostile", "enemy faction of the client's group: hostile")
	H.enemies = {}
	cmd._enemy = make_obj(900, 0, 0, 0)
	ok, why = MH.talk_verdict(cmd, proxy)
	check(ok == false and why == "combat", "commander in a fight: combat")
	cmd._enemy = nil
	check(MH.talk_verdict(cmd, proxy) == true, "fight over: allowed")
end

-- ===================================================================================================================
print("== learning: how many samples decide, what is no sample")
do
	local H, C, proxy, MH = scene("gamma")
	local a, b = npc_pair(H, C, 201), npc_pair(H, C, 202)
	round(H, { a, b })
	check(MH._soft().mode == nil and MH._soft().votes == 2, "two contradictions of the stock rules decide nothing yet")
	round(H, { a, b })
	check(MH._soft().mode == "ignored", "the third one does (and the counters start over)")

	local H2, C2, proxy2, MH2 = scene("stock")
	local plain = H2.add(make_obj(230, 15, 0, 0, { _name = "no_meet" }))
	H2.env.db.storage[230] = {}
	local fresh = npc_pair(H2, C2, 231)
	H2.env.db.storage[231].meet.meet_manager.use = nil -- the meet manager has not run yet: stock does nothing
	local hurt = npc_pair(H2, C2, 232)
	hurt._wounded = true
	H2.env.db.storage[232].wounded = { enable_talk = false }
	local cmd = npc_pair(H2, C2, 233, { commander = true })
	round(H2, { plain, fresh, hurt, cmd })
	check(MH2._soft().n == 0, "no meet manager, no cached use, wounded, use = true: none is a sample")
	check(MH2.talk_verdict(plain, proxy2) == true, "an NPC without a meet manager is not refused")
end

-- ===================================================================================================================
print("== safety: a modded condlist that raises must not refuse or break")
do
	local H, C, proxy, MH = scene("gamma")
	local npc = npc_pair(H, C, 201)
	H.env.db.storage[201].meet.meet_manager.a.use = { { cond = function() error("boom") end, section = "true" } }
	local ok, why = MH.talk_verdict(npc, proxy)
	check(ok == true and why == nil, "a failing rule lets the talk through (the engine still decides)")
	check(H.env.coop_npc_players.error_count("meet") >= 1, "and the error is counted")
	check(pcall(H.env.xr_meet.process_npc_usability, npc), "process_npc_usability survives it")
end

print(string.format("\nRESULT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("tests failed") end
