-- Cross-map companion ownership and handoff in server mode.
local fixture = dofile("tests/lua/support/companion_levels.lua")
local stand, logic_env, last, ask = fixture.stand, fixture.logic_env, fixture.last, fixture.ask
local BRIDGE, CORDON = fixture.BRIDGE, fixture.CORDON

print("== hand over: refused for a player on another level, the map server decides by its table")
do
	local W = stand({ dedicated = true, far_no_avatar = true })
	local A, B = W.A, W.B
	local L = W.CK._leaders
	L()[300] = 500
	W.refresh()
	check(W.CA.dlg_can_hand(A.env.db.actor, W.comp_a) == true, "the leader is offered the hand-over")
	local text = W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "1" })
	check(text:find("st_coop_comp_refused_elsewhere", 1, true) and text:find("p2", 1, true),
		"a player of another level stays in the list and says so: " .. text)
	check(W.CA.dlg_slot(A.env.db.actor, W.comp_a, "d", "p", "", { "1" }) == true, "his line stays in the list")
	A.msgs = nil
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "1" })
	pump()
	check(L()[300] == 500, "the map server keeps the leader")
	check(last(A):find("st_coop_comp_refused_elsewhere", 1, true) and last(A):find("p2", 1, true), "the asker hears who and why: " .. last(A))
	check(W.CK._stats().lead_refused == 1, "the refusal is counted (coop_status)")
	NOW = NOW + 3001
	ask(A, { a = "give", i = 201, to = 2 })
	check(L()[300] == 500, "a client that skips its window gets the same answer: the map server decides")

	W.move(2, 1)
	W.proxy_b._pos = vec(6, 0, 0)
	W.refresh()
	check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "1" }) == "p2", "a player of his level: the nick")
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "1" })
	pump()
	check(L()[300] == 501, "the same player on the same level: the hand-over goes through")
	check(last(B):find("st_coop_comp_gave_you", 1, true) ~= nil, "the new leader is told")
end

print("== hand over on a map server's level, to the player on Cordon")
do
	local W = stand({ dedicated = true })
	local Mk, B = W.Mk, W.B
	local L = W.CM._leaders
	L()[400] = 501
	W.refresh()
	check(W.CB.dlg_slot_text(B.env.db.actor, W.comp2_b, "d", "p", "", { "1" }):find("st_coop_comp_refused_elsewhere", 1, true) ~= nil,
		"the player stands elsewhere: the line says so")
	B.msgs = nil
	W.CB.dlg_hand(B.env.db.actor, W.comp2_b, "d", "p", "", { "1" })
	pump()
	check(L()[400] == 501, "the map server keeps the leader")
	check(last(B):find("st_coop_comp_refused_elsewhere", 1, true) and last(B):find("p1", 1, true), "he hears who: " .. last(B))
end

print("== take: not from a leader who stands on another level")
do
	local W = stand({ dedicated = true, mk_knows_all = true })
	local Mk, B = W.Mk, W.B
	local L = W.CM._leaders
	L()[400] = 500 -- A leads it from l01_escape: it could not follow him
	Mk.se[301] = { companion_cannot_teleport = true }
	W.refresh()
	B.msgs = nil
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 500, "the map server keeps the leader")
	check(last(B):find("st_coop_comp_refused_elsewhere", 1, true) and last(B):find("p1", 1, true), "he hears who: " .. last(B))
	W.move(1, 2)
	W.proxy_a._pos = vec(5, 0, 0)
	W.refresh()
	NOW = NOW + 3001
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 501, "on one level he takes it")
	check(Mk.msgs == nil, "a map server has nobody of its own to tell")
end

print("== take: a player hears it too: a leader on another level is no squad of his own")
do
	local W = stand({ dedicated = true })
	local K, A = W.K, W.A
	local L = W.CK._leaders
	W.H.env.coop_npc_players.send("npc.comp_adopt", { s = 300, l = 501, p = 2, c = true }, CORDON)
	pump()
	W.refresh()
	A.msgs = nil
	W.CA.dlg_take(A.env.db.actor, W.comp_a)
	pump()
	check(L()[300] == 501, "the map server keeps the leader")
	check(last(A):find("st_coop_comp_refused_elsewhere", 1, true) and last(A):find("p2", 1, true), "he hears who: " .. last(A))
end

print("== take: a squad stays with its owner on another level")
do
	local W = stand({ dedicated = true })
	local B = W.B
	local L = W.CM._leaders
	W.H.env.coop_npc_players.send("npc.comp_adopt", { s = 400, l = 500, p = 1, c = true }, BRIDGE)
	pump()
	W.refresh()
	check(L()[400] == 500, "the owner from Cordon is known")
	B.msgs = nil
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 500, "the map server keeps the owner")
	check(last(B):find("st_coop_comp_refused_elsewhere", 1, true) and last(B):find("p1", 1, true), "he hears who: " .. last(B))
end

print("== take: a leader who left the game is no reason to wait")
do
	local W = stand({ dedicated = true })
	local B = W.B
	local L = W.CM._leaders
	L()[400] = 777 -- a character of nobody in the session
	W.refresh()
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 501, "it is his")
end

print("== a story NPC of a task: the same rule")
do
	local taker = 1
	local W
	W = stand({ dedicated = true, env = function(M)
		if M.peer ~= CORDON then return end
		M.env.coop_tasks = { reward_peer = function() return taker end, giving_npc = function() return nil end }
		M.env.xr_effects = {
			setup_companion_task = function(actor, npc, p)
				W.squad(310, 10, 211)
				M.env.axr_companions.companion_squads[310] = W.squads[310]
			end,
		}
	end })
	local H, A = W.K, W.A
	local L = W.CK._leaders
	W.story = H.add(make_obj(211, 7, 0, 0, { _name = "story" }))
	W.story_a = A.add(make_obj(211, 7, 0, 0, { _name = "story" }))
	H.env.xr_effects.setup_companion_task(H.env.db.actor, nil, { "310", "esc_smart" })
	W.refresh()
	check(L()[310] == 500, "(the taker leads it)")
	W.CA.dlg_hand(A.env.db.actor, W.story_a, "d", "p", "", { "1" })
	pump()
	check(L()[310] == 500 and last(A):find("st_coop_comp_refused_elsewhere", 1, true) ~= nil, "not to a player of another level")
end

print("== a map server protects a squad whose leader already controls it")
do
	local W = stand({ dedicated = true })
	local H = W.K
	local ac = H.env.axr_companions
	W.CK._leaders()[300] = 500
	W.squad(310, 10, 211)
	ac.companion_squads[310] = W.squads[310]
	W.refresh()
	check(ac.companion_squad_can_teleport(W.squads[300]) == false, "a squad a client leads cannot be teleported by the stock group rule")
	check(ac.companion_squad_can_teleport(W.squads[310]) == true, "an unassigned squad uses the stock rule")
	H.se[211] = { companion_cannot_teleport = true }
	check(ac.companion_squad_can_teleport(W.squads[310]) == false, "the stock rule for the unassigned squad still reads the mark")
	H.se[211] = nil
	local asked = 0
	ac.companion_squad_can_teleport = function(squad) asked = asked + 1; return squad.id ~= 310 end -- Useful Idiots, loaded after us
	W.refresh()
	check(ac.companion_squad_can_teleport(W.squads[300]) == false, "over a patch that came later too")
	check(ac.companion_squad_can_teleport(W.squads[310]) == false and asked == 1, "the patch still decides for the unassigned squad")
	W.split = false
	check(ac.companion_squad_can_teleport(W.squads[300]) == true and asked == 2, "before the map table arrives: the stock rule")
end

print("== a client leaves Cordon: his squad goes after him, the map server of his level takes it")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local L = W.CK._leaders
	W.H.env.coop_npc_players.send("npc.comp_adopt", { s = 300, l = 500, p = 1 }, CORDON)
	pump()
	W.refresh()
	Mk.add(make_obj(201, 1, 0, 0, { _name = "comp" }))
	W.K.objects[201] = nil
	W.K.se[201] = { companion = true }
	W.bodies[201] = { name = function() return "comp" end }
	W.move(1, 2)
	W.stale_place = true
	W.refresh() -- Cordon reports the departure.
	W.refresh() -- The world server tries the move on its next update.
	local body = W.bodies[500]
	check(H.teleported and H.teleported.id == 300 and H.teleported.pos == body.position
		and H.teleported.lvid == body.m_level_vertex_id and H.teleported.gvid == 20,
		"his squad is teleported to where he stands")
	check(L()[300] == nil and W.K.env.axr_companions.companion_squads[300] == nil, "it is no companion of this level any more")
	local adopts = sent_named(H, "npc.comp_adopt")
	local adopt = adopts[#adopts]
	local adopted = adopt and H.env.coop_npc_players.decode(adopt.payload)
	check(adopt and adopt.target == BRIDGE and adopted.s == 300 and adopted.l == 500 and adopted.p == 1,
		"the authority of his level takes it")
	check(W.CM._leaders()[300] == 500 and Mk.env.axr_companions.companion_squads[300] == W.squads[300], "the map server takes it")
	check(Mk.env.axr_companions.logic[201] ~= nil, "with the logic of a companion")
	W.refresh()
	check(W.CM._leaders()[300] == 500, "its copy of the squad's place comes later: the map server does not take it for a stranger meanwhile")

	local before = #sent_named(H, "npc.comp_req")
	W.A.env.coop_npc_players.send("npc.comp_req", {}, 0)
	pump()
	local requests = sent_named(H, "npc.comp_req")
	local passed = requests[before + 1]
	check(#requests == before + 1 and passed.target == BRIDGE and H.env.coop_npc_players.decode(passed.payload)._peer == 1,
		"the world server passes a request on with his peer")
end

print("== a squad that may not follow stays where it is, and keeps its leader")
do
	local W = stand({ dedicated = true })
	local H = W.K
	local L = W.CK._leaders
	W.H.env.coop_npc_players.send("npc.comp_adopt", { s = 300, l = 500, p = 1 }, CORDON)
	pump()
	W.refresh()
	H.se[201] = { companion_cannot_teleport = true }
	W.H.se[201] = H.se[201] -- the Fanatic (dialogs_escape), a task's squad
	W.move(1, 2)
	W.refresh()
	W.refresh()
	check(W.H.teleported == nil, "not teleported")
	check(L()[300] == 500 and H.env.axr_companions.companion_squads[300] ~= nil, "his entry stays, it is his when he comes back")
	check(W.CK.leader_of(W.comp) == nil, "it has no local leader while its owner is away")
	H.se[201], W.H.se[201] = nil, nil
	W.refresh()
	W.refresh()
	check(W.H.teleported and W.H.teleported.id == 300, "the mark gone, it goes after him")
end

print("== a client leaves a map server's level: it lets the squad go, the world server takes it")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	LM()[400] = 501
	W.refresh()
	W.online[301] = true
	W.proxy_b._alive = true
	W.move(2, 1)
	W.refresh()
	check(#Mk.env.coop.players() == 0, "(he was its only player: nobody is left in its session)")
	check(#sent_named(Mk, "npc.comp_follow") == 1, "the map server lets it go")
	check(LM()[400] == 501 and Mk.env.axr_companions.companion_squads[400] ~= nil, "and keeps its owner until the world server takes it")
	check(H.teleported == nil, "the world server waits: a member is online at the map server")
	W.online[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and H.teleported.gvid == 10, "then teleports it to his body")
	check(W.CK._leaders()[400] == 501 and W.K.env.axr_companions.companion_squads[400] == W.squads[400], "the destination map server takes it")
	check(LM()[400] == nil and Mk.env.axr_companions.companion_squads[400] == nil, "the map server forgets it then, no dismissal")
	check(Mk.dismissed == nil, "(no dismissal)")
end

print("== a map server nobody stands on, just loaded: it sorts the save's leaders out, once the map says the world is split")
do
	local W = stand({ dedicated = true })
	local Mk = W.Mk
	local LM = W.CM._leaders
	W.move(2, 1)
	W.refresh()
	Mk.env.coop.peer_of_avatar = function(id) return id == 500 and 1 or nil end -- A leads squad 300 on l01_escape: no squad to let go
	W.split = false -- no LevelMap yet: coop.levels.split() of a map server
	Mk.fire("load_state", { coop_npc_leaders = { [300] = 500 } })
	W.refresh()
	check(LM()[300] == 500, "(nothing is decided before the map came)")
	W.split = true
	W.refresh()
	check(LM()[300] == nil, "a squad of another level is not its own")
	check(#sent_named(Mk, "npc.comp_follow") == 0, "and it is not its to let go")
end

print("== a task's squad on a map server's level: the map server takes it, with the logic and the stock's marks")
do
	local TAKER
	local W = stand({ dedicated = true, env = function(M)
		M.env.coop_tasks = { reward_peer = function() return TAKER end, giving_npc = function() return nil end }
		local ac = M.env.axr_companions
		-- the stock (axr_companions.add_special_squad): only a member this process holds as a live NPC gets the marks
		function ac.add_special_squad(squad, special, cannot_teleport)
			ac.companion_squads[squad.id] = squad
			for k in squad:squad_members() do
				if M.env.level.object_by_id(k.id) then
					M.se[k.id] = { companion = true, companion_cannot_dismiss = true, companion_cannot_teleport = cannot_teleport }
				end
			end
		end
		M.env.xr_effects = { add_task_companion = function(actor, npc, p)
			ac.add_special_squad(W_squads[p[1]], p[2] == "true", p[3] == "true")
		end }
	end })
	W_squads = W.squads
	local H, Mk = W.H, W.Mk
	local ac = Mk.env.axr_companions
	ac.companion_squads[400] = nil
	W.comp2:disable_info_portion("npcx_is_companion")
	W.not_yet[400] = true
	W.bodies[301] = { name = function() return "comp2" end }
	TAKER = 2
	H.env.xr_effects.add_task_companion(H.env.db.actor, nil, { 400, "false", "true" })
	TAKER = nil
	pump()
	check(ac.companion_squads[400] == nil, "the squad is not on the map server yet: nothing to take")
	W.not_yet[400] = nil
	W.refresh()
	check(W.CM._leaders()[400] == 501 and ac.companion_squads[400] == W.squads[400], "it comes: the map server takes it, its leader the taker")
	check(ac.logic[301] ~= nil and ac.logic[301].cannot_dismiss == true, "the logic of a companion: he does not go back to his own walker")
	check(Mk.se[301] and Mk.se[301].companion == true and Mk.se[301].companion_cannot_dismiss == true
		and Mk.se[301].companion_cannot_teleport == true, "the stock's marks: the binder reads them when he comes online")
	check(H.se[301] and H.se[301].companion_cannot_dismiss == true and H.se[301].companion_cannot_teleport == true,
		"the world server's record has them too: the next word (follow_home) and the save read them there")
	check(W.CH._leaders()[400] == nil, "the world server does not lead it")
	check(H.env.axr_companions.companion_squads[400] ~= nil, "its table keeps the squad: task scripts ask it")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders and m.coop_npc_leaders[400] == 501, "the save has the leader at once")
	check(H.env.axr_companions.companion_squad_can_teleport(W.squads[400]) == false, "the world server protects the assigned squad from stock teleport")
	check(#H.env.axr_companions.list_actor_squad_by_id() == 0, "the world server's ghost has no squad list")
	W.refresh()
	check(H.teleported == nil and W.CM._leaders()[400] == 501, "with its leader on its level it stays")
	H.share.up.comp_leaders.set(Mk.share.up.comp_leaders.get(), 2)
	m = {}
	H.fire("save_state", m)
	check(H.env.axr_companions.companion_squads[400] ~= nil and m.coop_npc_leaders[400] == 501,
		"the map server's word that it took the squad leaves the task's row in the world server's table")

	print("-- with no ban on teleports in the task's call")
	W.CM._leaders()[400] = nil
	ac.companion_squads[400] = nil
	H.env.axr_companions.companion_squads[400] = nil
	H.se[301], Mk.se[301] = nil, nil
	W.refresh()
	TAKER = 2
	H.env.xr_effects.add_task_companion(H.env.db.actor, nil, { 400 })
	TAKER = nil
	pump()
	check(Mk.se[301].companion_cannot_dismiss == true and not Mk.se[301].companion_cannot_teleport, "it is an escort, and it may follow")

	print("-- Cordon gets the world server's companion marks")
	local H2 = W.K.env.axr_companions
	H2.companion_squads[300] = nil
	W.bodies[201] = { name = function() return "comp" end }
	W.K.se[201] = nil
	TAKER = 1
	H.env.xr_effects.add_task_companion(H.env.db.actor, nil, { 300 })
	TAKER = nil
	pump()
	check(W.K.se[201] and W.K.se[201].companion_cannot_dismiss == true, "the marks arrive on Cordon")
	check(W.CK._leaders()[300] == 500, "and its taker leads it")
end

print("== a companion a status functor writes into the stock table (tasks_agent_rescue): the taker leads it")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local ac = W.K.env.axr_companions
	local before = W.CK.squads_now()
	ac.companion_squads[310] = W.squad(310, 10, 211)
	check(W.CK.claim_since(before, 1) == 1 and W.CK._leaders()[310] == 500, "a squad of this level: its taker is its leader")
	ac.companion_squads[311] = W.squad(311, 10, 212)
	W.CK._leaders()[311] = 501
	check(W.CK.claim_since(before, 1) == 0 and W.CK._leaders()[311] == 501, "a wrapper of the stock claimed it already: it stays")
	before = W.CK.squads_now()
	ac, before = H.env.axr_companions, W.CH.squads_now()
	W.bodies[301] = { name = function() return "comp2" end }
	Mk.env.axr_companions.companion_squads[400] = nil
	ac.companion_squads[400] = W.squads[400]
	local sent = #sent_named(H, "npc.comp_adopt")
	W.CH.claim_since(before, 2)
	check(#sent_named(H, "npc.comp_adopt") == sent + 1, "a squad on a map server's level goes there")
	W.CH.claim_since(before, 2)
	check(#sent_named(H, "npc.comp_adopt") == sent + 1, "once")
	pump()
	check(W.CM._leaders()[400] == 501, "the map server leads it")
end

print("== a task lets go of a squad on a map server's level (Hidden Threat: the player left the station)")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local ac = H.env.axr_companions
	local before = W.CH.squads_now()
	Mk.env.axr_companions.companion_squads[400] = nil
	ac.companion_squads[400] = W.squads[400]
	W.CH.claim_since(before, 2)
	pump()
	check(W.CM._leaders()[400] == 501 and Mk.env.axr_companions.companion_squads[400] ~= nil, "(the map server leads it)")
	ac.dismiss_special_squad(W.squads[400])
	pump()
	check(H.dismissed == 400, "the stock runs on the world server")
	check(Mk.dismissed == 400 and Mk.env.axr_companions.companion_squads[400] == nil, "and on the map server, where the NPC is")
	check(W.CM._leaders()[400] == nil, "it has no leader there")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders == nil, "nor in the save")
	W.no_cordon = true -- last player left Cordon, so the record is offline
	ac.companion_squads[300] = W.squads[300]
	H.dismissed, Mk.dismissed = nil, nil
	local sent = #sent_named(H, "npc.comp_drop")
	ac.dismiss_special_squad(W.squads[300])
	check(H.dismissed == 300 and #sent_named(H, "npc.comp_drop") == sent, "an offline squad needs only the world server")
end

print("== a task dismisses a squad that stayed behind offline: the stock leaves the marks, the dismissal stands all the same")
do
	local W = stand({ dedicated = true })
	local H = W.K
	local L = W.CK._leaders
	local cs = H.env.axr_companions.companion_squads
	L()[300] = 500
	W.refresh()
	H.objects[201] = nil
	W.bodies[201] = { name = function() return "comp" end }
	H.se[201] = { companion = true, companion_cannot_dismiss = true, companion_cannot_teleport = true }
	W.move(1, 2)
	W.refresh()
	check(L()[300] == 500 and H.teleported == nil, "(it stays with its leader's entry)")
	H.env.axr_companions.dismiss_special_squad(W.squads[300])
	check(H.dismissed == 300 and L()[300] == nil, "the entry goes with it")
	W.refresh()
	check(cs[300] == nil, "the refresh does not bring it back")
	check(not H.se[201].companion and not H.se[201].companion_cannot_dismiss and not H.se[201].companion_cannot_teleport,
		"the marks are gone: the binder and the next load do not make it a companion again")
	local m = {}
	W.H.fire("save_state", m)
	check(m.coop_npc_leaders == nil, "nor is it in the save")
end

print("== a task dismisses a squad that waits for its teleport: it does not arrive after that")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	W.CM._leaders()[400] = 501
	W.refresh()
	W.online[301] = true
	W.move(2, 1)
	W.refresh()
	check(H.teleported == nil, "(a member is still online at the map server)")
	H.env.axr_companions.companion_squads[400] = W.squads[400]
	H.env.axr_companions.dismiss_special_squad(W.squads[400])
	W.online[301] = nil
	W.refresh()
	check(H.teleported == nil and W.CH._leaders()[400] == nil, "no teleport, no leader")
end

print("== a member online when the map server takes the squad, a companion of it already")
do
	local W = stand({ dedicated = true })
	local Mk = W.Mk
	W.CK._leaders()[300] = 500
	W.refresh()
	Mk.add(make_obj(201, 1, 0, 0, { _name = "comp", _info = { npcx_is_companion = true } }))
	W.K.objects[201] = nil
	W.move(1, 2)
	W.refresh()
	check(Mk.env.axr_companions.logic[201] == nil, "no second setup: it would reset his orders")
end

print("== the leaders of a map server's level: into the save, onto a new map server")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local up, down = "comp_leaders", "comp_leaders"
	check(Mk.share.up[up] ~= nil and H.share.down[down] ~= nil, "both tables are declared")
	local LM = W.CM._leaders
	LM()[400] = 501
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders and m.coop_npc_leaders[400] == 501, "a leader on the map server reaches the save")
	check(H.env.axr_companions.companion_squad_can_teleport(W.squads[400]) == false, "the world server knows it for somebody's")
	Mk.fire("load_state", { coop_npc_leaders = { [300] = 500, [400] = 501 } })
	W.refresh()
	check(LM()[300] == nil, "a map server keeps only the squads of its level")
	local row = Mk.share.up[up].get()
	check(row.l[400] == 501 and row.l[300] == nil, "and reports those")
	LM()[400] = nil
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders == nil, "dismissed there: gone from the save")

	LM()[400] = 501
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	LM()[400] = nil
	Mk.env.axr_companions.companion_squads[400] = nil
	W.comp2:disable_info_portion("npcx_is_companion")
	local given = H.share.down[down].get()
	Mk.share.down[down].set(given)
	check(LM()[400] == 501 and Mk.env.axr_companions.companion_squads[400] ~= nil, "a new map server gets the leaders of its level")
	check(Mk.env.axr_companions.logic[301] ~= nil, "and sets the logic up")
	LM()[400] = 500
	Mk.share.down[down].set(given)
	check(LM()[400] == 500, "the word counts once: what the map server changed since is newer")
end

print("== a squad stayed behind on a map now closed, and its leader moved to another map")
do
	local W = stand({ dedicated = true })
	W.no_server = true -- l02_garbage is what they left: no map server on it
	local H = W.H
	local cs = W.K.env.axr_companions.companion_squads
	cs[400] = false -- the stock's table of the save
	W.move(1, 1)
	H.fire("load_state", { coop_npc_leaders = { [400] = 500 } })
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and H.teleported.gvid == 10, "the world server teleports it to his body")
	check(W.CK._leaders()[400] == 500 and cs[400] == W.squads[400], "the level of arrival takes it, his leader keeps it")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[400] == 500, "the save has the leader, once")
	W.refresh()
	check(W.CK._leaders()[400] == 500, "it stays his")
end

print("== left behind and forbidden to teleport: it stays with its leader's entry, and the save keeps it")
do
	local W = stand({ dedicated = true })
	W.no_server = true
	local H = W.H
	H.se[301] = { companion_cannot_teleport = true }
	W.move(1, 1)
	H.fire("load_state", { coop_npc_leaders = { [400] = 500 } })
	W.refresh()
	W.refresh()
	check(H.teleported == nil, "not teleported")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[400] == 500, "the save has the leader")
	H.se[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400, "the mark gone, it goes after him")
end

print("== left behind, its leader's character back in the list a moment after the world: it goes all the same")
do
	local W = stand({ dedicated = true })
	W.no_server = true
	local H = W.H
	local away = true
	W.move(1, 1)
	local players, peer_of = H.env.coop.players, H.env.coop.peer_of_avatar
	H.env.coop.players = function()
		local list = players()
		for _, p in ipairs(list) do
			if away and p.id == 1 then p.avatar_id = nil end
		end
		return list
	end
	H.env.coop.peer_of_avatar = function(id)
		if away and id == 500 then return nil end
		return peer_of(id)
	end
	H.fire("load_state", { coop_npc_leaders = { [400] = 500 } })
	W.refresh()
	check(H.teleported == nil, "nobody to go to yet")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[400] == 500, "the save has the leader meanwhile")
	away = false
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and W.CK._leaders()[400] == 500, "he is back: his map server takes the squad")
end

print("== a save with leaders of every level: each process keeps its own")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local saved = { coop_npc_leaders = { [300] = 500, [400] = 501 } }
	H.fire("load_state", saved)
	Mk.fire("load_state", saved)
	W.K.fire("load_state", saved)
	W.refresh()
	check(W.CK._leaders()[300] == 500 and W.CK._leaders()[400] == nil and next(W.CH._leaders()) == nil,
		"Cordon restores its own squads, the world service actor leads none")
	check(W.CM._leaders()[400] == 501 and W.CM._leaders()[300] == nil, "the map server those of its own")
	check(H.teleported == nil, "nobody takes a squad on another level for one left behind")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[300] == 500 and m.coop_npc_leaders[400] == 501, "the next save has them all")
end

print("== a new map server says nothing of its leaders before it sorted the save's out: the word goes on its own timer")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local saved = { coop_npc_leaders = { [300] = 500, [400] = 501 } }
	H.fire("load_state", saved)
	W.refresh()
	Mk.fire("load_state", saved)
	check(Mk.share.up.comp_leaders.get() == nil, "before the sort: nothing to tell, the leaders of every level are in its hands")
	W.refresh()
	local row = Mk.share.up.comp_leaders.get()
	check(row ~= nil and row.l[400] == 501 and row.l[300] == nil, "after it: those of its level")
	H.share.up.comp_leaders.set(row, 2)
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[300] == 500 and m.coop_npc_leaders[400] == 501, "the next save has them all")
end

print("== a map server just loaded: its squad's leader stands elsewhere and was never on it, the world server's owner table says who he is")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	W.move(1, 1)
	W.owners[1] = nil -- the world server's AvatarList reaches a map server after its WorldLoaded
	local saved = { coop_npc_leaders = { [400] = 500 } }
	H.fire("load_state", saved)
	Mk.fire("load_state", saved)
	W.refresh()
	Mk.share.down.comp_leaders.set(H.share.down.comp_leaders.get())
	W.refresh()
	check(W.CM._leaders()[400] == 500 and #sent_named(Mk, "npc.comp_follow") == 0,
		"(its session does not know him, the leaders' word names no seat: it waits)")
	W.owners[1] = 500
	W.refresh()
	check(W.CM._leaders()[400] == 500 and #sent_named(Mk, "npc.comp_follow") == 1,
		"the world's owner table names him: the map server lets it go, its owner kept until the world server takes it")
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and H.teleported.gvid == 10, "the world server teleports it to his body")
	check(W.CK._leaders()[400] == 500, "his level takes it")
	check(W.CM._leaders()[400] == nil, "the map server forgets it then")
end

print("== a squad recruited on a map server: the table of the save does not have it, the stock's mark does")
do
	local W = stand({ dedicated = true })
	local Mk = W.Mk
	local ac = Mk.env.axr_companions
	ac.companion_squads[400] = nil
	Mk.se[301] = { companion = true }
	Mk.fire("load_state", { coop_npc_leaders = { [400] = 501 } })
	W.refresh()
	check(W.CM._leaders()[400] == 501 and ac.companion_squads[400] == W.squads[400], "it keeps its leader and its place in the table")
	W.CM._leaders()[400] = 501
	ac.companion_squads[400] = nil
	Mk.se[301] = nil
	W.refresh()
	check(W.CM._leaders()[400] == nil, "no mark: a dismissed squad, the entry goes")
end

print("== a map server's companion with no living leader goes to the nearest player, not to the ghost")
do
	local W = stand({ dedicated = true, mk_knows_all = true })
	local Mk = W.Mk
	W.refresh()
	Mk.env.axr_beh.action_beh.execute({ object = W.comp2 })
	check(Mk.beh_actor == 501, "no leader at all: the player of the level")
	W.CM._leaders()[400] = 500 -- a leader who is not here, a squad that may not go
	Mk.se[301] = { companion_cannot_teleport = true }
	W.refresh()
	Mk.beh_actor = nil
	Mk.env.axr_beh.action_beh.execute({ object = W.comp2 })
	check(Mk.beh_actor == 501, "a leader on another level: the same")
	check(W.CM.follows(W.comp2):id() == 501, "follows answers that player")
	local alone = Mk.add(make_obj(302, 7, 0, 0, { _name = "stranger" }))
	check(W.CM.follows(alone) == nil, "an NPC of no squad of the group: nobody")
	Mk.env.axr_beh.action_beh.execute({ object = alone })
	check(Mk.beh_actor == 0, "stock for it")
	W.proxy_b._alive = false
	Mk.env.coop_npc_players.invalidate()
	Mk.beh_actor = nil
	Mk.env.axr_beh.action_beh.execute({ object = W.comp2 })
	check(Mk.beh_actor == 0, "nobody alive on the level: nothing to go to, stock")
end

print("== the logic of a companion: 'the actor' is its leader, the infos of a condlist the world's")
do
	local W = stand({ dedicated = true, env = logic_env })
	local H, Mk, A, B = W.K, W.Mk, W.A, W.B
	-- the logic reads the identity a mod set through coop_mods_core, which ships with it
	if not H.env.coop_mods_core then load_script(H, "coop_mods_core") end
	if not Mk.env.coop_mods_core then load_script(Mk, "coop_mods_core") end
	W.LH = load_script(H, "coop_npc_logic")
	W.LM = load_script(Mk, "coop_npc_logic")
	W.LH.on_game_start()
	W.LM.on_game_start()
	W.CK._leaders()[300] = 500
	W.refresh()
	local xl, xc = H.env.xr_logic, H.env.xr_conditions
	local seen
	xc.who = function(actor, npc) seen = { param = actor:id(), db = H.env.db.actor:id() }; return true end
	local function logic(condlist) return { ini = {}, logic = { { name = "on_info", condlist = condlist } } } end
	check(xl.try_switch_to_another_section(W.comp, logic({ { "beh@x", { { "who", 3 } } } }), H.env.db.actor) == true, "the stock switch runs")
	check(seen.param == 500 and seen.db == 500, "its functors get the leader, as parameter and as db.actor")
	check(H.switch_as == 500, "under his identity")
	check(H.env.db.actor:id() == 0, "the identity ends with it")
	local plain = H.add(make_obj(290, 7, 0, 0))
	seen = nil
	xl.try_switch_to_another_section(plain, logic({ { "x", { { "who", 3 } } } }), H.env.db.actor)
	check(seen.param == 0 and seen.db == 0, "an NPC of nobody: stock")

	H.env.db.actor:give_info_portion("world_flag")
	H.section = nil
	xl.try_switch_to_another_section(W.comp, logic({ { "beh@flag", { { "world_flag", 1 } } } }), H.env.db.actor)
	check(H.section == "beh@flag", "an info of the condlist is the world's: a proxy has none of them")
	H.section = nil
	xl.try_switch_to_another_section(W.comp, logic({ { "beh@no", { { "world_flag", 2 } } }, { "beh@second" } }), H.env.db.actor)
	check(H.section == "beh@second", "and its absence: the first line fails, the next one stands")
	W.comp:give_info_portion("npcx_x")
	H.section = nil
	xl.try_switch_to_another_section(W.comp, logic({ { "beh@own", { { "npcx_x", 1, 1 } } } }), H.env.db.actor)
	check(H.section == "beh@own", "an NPC's own flag stays his")

	-- beh_companion.ltx: on_info2 = {-force_started =dist_to_actor_le(3)} %+force_started =force_talk(true)%
	local talk = logic({ { "", { { "force_started", 2 }, { "dist_to_actor_le", 3, { 3 } } }, { { "force_started", 1 }, { "force_talk", 3, { "true" } } } } })
	W.move(2, 1)
	W.proxy_a._pos = vec(100, 0, 0)
	W.proxy_b._pos = vec(6, 0, 0) -- another player is near, the leader is far
	H.env.coop_npc_players.invalidate()
	local talks = {}
	A.env.db.actor.run_talk_dialog = function(self, npc, brk) talks[#talks + 1] = { npc = npc:id(), brk = brk } end
	xl.try_switch_to_another_section(W.comp, talk, H.env.db.actor)
	pump()
	check(#talks == 0 and not H.env.db.actor:has_info("force_started"), "dist_to_actor is measured from the leader, even with another player nearby")
	check(xc.dist_to_actor_le(H.env.db.actor, W.comp, { 3 }) == true, "[meet] and the rest, outside the scope: the nearest player")
	check(H.env.coop_npc_players.with_identity(W.proxy_a, xc.dist_to_actor_le, H.env.db.actor, W.comp, { 3 }) == false,
		"under the leader's identity, the check uses his position")
	check(H.env.coop_npc_players.with_identity(W.proxy_a, xc.dist_to_actor_ge, H.env.db.actor, W.comp, { 3 }) == true, "the same for ge")
	W.proxy_a._pos = vec(5, 0, 0)
	H.env.coop_npc_players.invalidate()
	xl.try_switch_to_another_section(W.comp, talk, H.env.db.actor)
	pump()
	check(#talks == 1 and talks[1].npc == 201 and talks[1].brk == true, "force_talk: the leader's machine opens the talk")
	check(H.stock_talk == nil, "not the host's")
	check(H.env.db.actor:has_info("force_started") and not W.proxy_a:has_info("force_started"), "the latch is the world's info, the proxy has none")
	xl.try_switch_to_another_section(W.comp, talk, H.env.db.actor)
	pump()
	check(#talks == 1, "it latches: once")

	H.env.save_var(H.env.db.actor, "task_target_anomaly", "anomaly_1")
	check(H.env.coop_npc_players.with_identity(W.proxy_a, xc.dist_to_task_target_anomaly_le, W.proxy_a, W.comp, { 15 }) == true,
		"dist_to_task_target_anomaly reads the actor's var under the identity too: the switch to beh@task_target_anomaly stands")

	-- a map server: the same, the nearest player for a companion with no leader
	W.move(2, 2)
	local xm = Mk.env.xr_logic
	local mtalk = logic({ { "", { { "dist_to_actor_le", 3, { 3 } } }, { { "force_talk", 3, { "false" } } } } })
	B.env.db.actor.run_talk_dialog = function(self, npc, brk) talks[#talks + 1] = { npc = npc:id(), brk = brk } end
	xm.try_switch_to_another_section(W.comp2, mtalk, Mk.env.db.actor)
	pump()
	check(#talks == 2 and talks[2].npc == 301 and talks[2].brk == false, "on a map server force_talk goes to the player it takes for its leader")
	check(Mk.stock_talk == nil, "the ghost talks to nobody")
end

print("== a squad cannot return to an old leader on another map")
do
	-- On a dedicated world, an old leader on a different map cannot take the squad back.
	local S = stand({ dedicated = true })
	S.K.env.coop.talk_recent = function() return true end
	S.move(2, 1)
	local companion = S.B.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	S.CK._leaders()[300] = 501
	S.refresh()
	S.B.env.dialogs_axr_companion.remove_companions_from_squad(S.B.env.db.actor, companion, "fanat_training_anomaly_reached", "1")
	pump()
	S.move(2, 2)
	S.refresh()
	S.A.env.dialogs_axr_companion.become_actor_companion(S.A.env.db.actor, S.comp_a, "x", "1")
	pump()
	check(S.CK._leaders()[300] == 500, "a player on the current map recruits it when the old leader is elsewhere")
end

print("== last leaders of a map server's level reach the save")
do
	local W = stand({ dedicated = true })
	local H, Mk, B = W.H, W.Mk, W.B
	W.CM._leaders()[400] = 501
	W.refresh()
	B.env.dialogs_axr_companion.remove_companions_from_squad(B.env.db.actor, W.comp2_b, "story_line", "1")
	pump()
	check(W.CM._leaders()[400] == nil, "the map server lets him go")
	H.share.up.comp_leaders.set(Mk.share.up.comp_leaders.get(), 2)
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_last_leaders and m.coop_npc_last_leaders[400] == 501, "the save has who it was")
end

print("== a client's own companions: the stock's list and Useful Idiots' answer from the authority's word, not the stock table")
do
	local NPCS = {}
	local function idiots(M)
		local NPC = {}
		function NPC.getCompanions() return {} end
		function NPC.getTargetCompanion() return nil end
		NPCS[M] = NPC
		M.env.package = { loaded = { ["illish.lib.npc"] = NPC } }
	end
	local W = stand({ dedicated = true, env = idiots })
	local H, A, B = W.K, W.A, W.B
	W.CK._leaders()[300] = 500
	W.refresh()
	A.env.axr_companions.companion_squads[300] = false -- loaded: the stock's rebuild (squad_on_first_update) is the host's
	local list = A.env.axr_companions.list_actor_squad_by_id()
	check(#list == 1 and list[1] == 201, "his companion is in his list without aiming at it")
	check(#B.env.axr_companions.list_actor_squad_by_id() == 0, "not in the list of a friend")
	local own = NPCS[A].getCompanions()
	check(#own == 1 and own[1]:id() == 201, "Useful Idiots' wheel and keys see it")
	check(#NPCS[B].getCompanions() == 0, "and not a friend's")
	check(#A.env.axr_companions.companion_squads == 0 and A.env.axr_companions.companion_squads[300] == false,
		"the client writes nothing into the stock table")
	W.CK._leaders()[300] = nil
	H.env.axr_companions.companion_squads[300] = nil
	W.refresh()
	check(#A.env.axr_companions.list_actor_squad_by_id() == 0 and #NPCS[A].getCompanions() == 0, "dismissed: gone from his list")
end

print("== a client leaves a map server's level, a friend stays by his squad: the map server keeps the owner until the world server takes it")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	W.move(1, 2)
	LM()[400] = 500
	W.refresh()
	W.online[301] = true -- B stands next to it: the engine keeps it online at the map server
	W.move(1, 1)
	W.refresh()
	W.refresh()
	check(H.teleported == nil, "(the world server waits: a member is online at the map server)")
	check(#sent_named(Mk, "npc.comp_follow") == 1, "the map server says it once")
	check(LM()[400] == 500 and Mk.env.axr_companions.companion_squads[400] ~= nil, "the map server keeps the owner meanwhile")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders and m.coop_npc_leaders[400] == 500, "a save meanwhile keeps the owner")
	W.online[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400, "offline: the world server teleports it to him")
	check(W.CK._leaders()[400] == 500, "his level takes it")
	check(LM()[400] == nil and Mk.env.axr_companions.companion_squads[400] == nil, "the map server lets it go then")
	check(Mk.dismissed == nil, "no dismissal on the way")
end

print("== the owner comes back before his squad left: it stays his on its level, the world server does not teleport it")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	W.move(1, 2)
	LM()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	W.refresh()
	W.move(1, 2)
	W.refresh()
	check(LM()[400] == 500, "the map server leads it again")
	W.online[301] = nil
	W.refresh()
	check(H.teleported == nil, "no teleport after all")
	check(W.CM.follows(W.comp2):id() == 500, "it follows him")
end

print("== a save with a squad on its way to its owner: after the load the way goes on")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	W.move(1, 2)
	LM()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	W.refresh()
	local m = {}
	H.fire("save_state", m)
	local saved = m.coop_npc_leaders
	check(saved and saved[400] == 500, "the save has its owner")
	H.fire("load_state", { coop_npc_leaders = saved })
	Mk.fire("load_state", { coop_npc_leaders = saved })
	W.refresh()
	W.online[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and W.CK._leaders()[400] == 500, "it reaches its owner")
end

print("== a pending squad a task dismisses: the map server that still holds it lets it go too")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	W.move(1, 2)
	W.CM._leaders()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	W.refresh()
	H.env.axr_companions.companion_squads[400] = W.squads[400]
	H.env.axr_companions.dismiss_special_squad(W.squads[400])
	pump()
	check(W.CM._leaders()[400] == nil and Mk.env.axr_companions.companion_squads[400] == nil, "gone there")
end

-- The engine's recall (coop_levels_xfer.cpp): the world server names the map server that holds a squad (holder_of), that map server takes
-- it offline whoever stands by it and pins it there (recall); the give-back is the engine's, here W.online goes nil by hand.
local function recall_engine(W)
	W.recalls = {}
	W.H.env.coop.levels.holder_of = function(id) return W.online[id] and BRIDGE or nil end
	W.Mk.env.coop.levels.recall = function(id, ms)
		W.recalls[#W.recalls + 1] = { id = id, ms = ms }
		return true
	end
end

print("== a friend stays by the squad: the world server recalls it once, and after the map server gave it back it teleports")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	recall_engine(W)
	W.move(1, 2)
	W.CM._leaders()[400] = 500
	W.refresh()
	W.online[301] = true -- B stands next to it: the engine keeps it online at the map server
	W.move(1, 1)
	W.refresh()
	W.refresh()
	check(H.teleported == nil, "(the world server waits: a member is online at the map server)")
	local asked = sent_named(H, "npc.comp_recall")
	check(#asked == 1 and asked[1].target == BRIDGE, "the world server asks the map server that holds it, once")
	check(#W.recalls == 1 and W.recalls[1].id == 400 and W.recalls[1].ms == nil, "the map server takes it offline and pins it")
	W.refresh()
	check(#sent_named(H, "npc.comp_recall") == 1 and #W.recalls == 1, "not again while it is on its way home")
	W.online[301] = nil -- the engine gave it back to the world server
	W.refresh()
	check(H.teleported and H.teleported.id == 400, "home: the world server teleports it to its owner")
	check(W.CK._leaders()[400] == 500, "his level takes it")
	check(#W.recalls == 2 and W.recalls[2].id == 400 and W.recalls[2].ms == 0, "the map server lifts its pin when the world server took it")
	check(W.CM._leaders()[400] == nil and Mk.dismissed == nil, "and forgets it, no dismissal")
end

print("== a recall nobody answers is asked again later, not every tick")
do
	local W = stand({ dedicated = true })
	local H = W.H
	recall_engine(W)
	W.Mk.env.coop.levels.recall = nil -- an old engine on the map server: the word is heard, nothing happens
	W.move(1, 2)
	W.CM._leaders()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	W.refresh()
	W.refresh()
	check(#sent_named(H, "npc.comp_recall") == 1, "asked once")
	for _ = 1, 4 do W.refresh() end
	check(#sent_named(H, "npc.comp_recall") == 1, "(not within 15 s)")
	for _ = 1, 3 do W.refresh() end
	check(#sent_named(H, "npc.comp_recall") == 2, "again after a while")
	check(H.teleported == nil, "and it waits as before")
end

print("== a squad that may not teleport any more is not recalled: the world server checks, the map server checks again")
do
	local W = stand({ dedicated = true })
	local H, Mk = W.H, W.Mk
	recall_engine(W)
	W.move(1, 2)
	W.CM._leaders()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	H.env.se_save_var(301, nil, "companion_cannot_teleport", true) -- a scripted scene took it after the map server let it go
	W.refresh()
	W.refresh()
	check(#sent_named(H, "npc.comp_recall") == 0 and #W.recalls == 0, "the world server does not ask")
	Mk.env.se_save_var(301, nil, "companion_cannot_teleport", true)
	H.env.coop_npc_players.send("npc.comp_recall", { s = 400 }, BRIDGE)
	pump()
	check(#W.recalls == 0, "the map server would not take it either")
end

print("== a recall is the world server's word only: a client's never reaches the engine")
do
	local W = stand({ dedicated = true })
	recall_engine(W)
	W.A.env.coop_npc_players.send("npc.comp_recall", { s = 400 }, BRIDGE)
	W.B.env.coop_npc_players.send("npc.comp_recall", { s = 400 }, -1)
	pump()
	check(#W.recalls == 0, "a player's word is not heard")
	W.H.env.coop_npc_players.send("npc.comp_recall", { s = 300 }, BRIDGE)
	pump()
	check(#W.recalls == 0, "nor one for a squad that is not a companion it let go")
end

print("== an old engine on the world server: no recall, it waits as before")
do
	local W = stand({ dedicated = true })
	local H = W.H
	W.move(1, 2)
	W.CM._leaders()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	W.refresh()
	W.refresh()
	check(#sent_named(H, "npc.comp_recall") == 0, "nothing asked")
	W.online[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400, "it goes when the friend walks away")
end

print("== the Fanatic (dialogs_escape): the stock marks him and sets the logic, no line of the table; a client said it: he is that client's")
do
	local function fanat(M)
		local E = M.env
		E.coop.talk_recent = function() return true end
		E.dialogs_escape = {
			set_esc_2_12_stalker_fanat_as_companion = function(a, b)
				local npc = E.dialogs.who_is_npc(a, b)
				local sq = E.get_object_squad(npc)
				for k in sq:squad_members() do
					E.se_save_var(k.id, nil, "companion", true)
					E.se_save_var(k.id, nil, "companion_cannot_dismiss", true)
					E.se_save_var(k.id, nil, "companion_cannot_teleport", true)
					E.axr_companions.setup_companion_logic(npc, nil, false, true)
				end
			end,
		}
	end
	local W = stand({ dedicated = true, env = fanat })
	local H, A = W.K, W.A
	H.env.axr_companions.companion_squads[300] = nil
	W.comp:disable_info_portion("npcx_is_companion")
	W.refresh()
	A.env.dialogs_escape.set_esc_2_12_stalker_fanat_as_companion(A.env.db.actor, W.comp_a)
	pump()
	check(H.env.axr_companions.companion_squads[300] == W.squads[300], "a companion of the group, as the stock makes him on the next load")
	check(W.CK._leaders()[300] == 500, "led by the client who said it")
	W.refresh()
	check(W.CK.follows(W.comp):id() == 500, "he follows that client")
	local list = A.env.axr_companions.list_actor_squad_by_id()
	check(#list == 1 and list[1] == 201, "in that client's list")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
